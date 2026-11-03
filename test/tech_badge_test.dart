import 'package:cell_tower_monitor/models/cell_snapshot.dart';
import 'package:cell_tower_monitor/services/carrier_names.dart';
import 'package:cell_tower_monitor/widgets/tech_badge.dart';
import 'package:flutter_test/flutter_test.dart';

SimReading _sim({
  required String override,
  required List<CellTower> cells,
  String nrState = '',
}) =>
    SimReading.fromMap({
      'slotIndex': 1,
      'subscriptionId': 2,
      'carrierName': 'AT&T',
      'isDefault': false,
      'simState': 'READY',
      'networkTypeName': 'LTE',
      'overrideNetworkType': override,
      'nrState': nrState,
      'cells': [
        for (final cell in cells)
          {
            'type': cell.tech.raw,
            'registered': cell.registered,
            'dbm': cell.dbm,
            'mcc': cell.mcc,
            'mnc': cell.mnc,
          },
      ],
    });

CellTower _cell(
  String type, {
  int dbm = -95,
  String mcc = '310',
  String mnc = '410',
}) =>
    CellTower.fromMap({
      'type': type,
      'registered': true,
      'dbm': dbm,
      'mcc': mcc,
      'mnc': mnc,
    });

void main() {
  group('satellite', () {
    test('the technology label never carries a SAT prefix', () {
      // SAT is its own marker: one names the path, the other the radio, and the
      // header shows one of them rather than stacking both into one string.
      expect(
        techBadgeLabel(
          tech: 'LTE',
          override: 'NONE',
          plmn: '312-190',
          nrAttached: false,
        ),
        'LTE',
      );
      expect(
        techBadgeLabel(
          tech: 'LTE',
          override: 'NR_NSA',
          plmn: '310-830',
          nrAttached: true,
        ),
        '5G',
      );
    });

    test('a satellite PLMN is recognised from the slot', () {
      final satellite = _sim(
        override: 'NONE',
        cells: [_cell('LTE', mcc: '312', mnc: '190')],
      );
      final terrestrial = _sim(override: 'NONE', cells: [_cell('LTE')]);

      expect(satellite.isSatellite, isTrue);
      expect(terrestrial.isSatellite, isFalse);
      // The technology label still exists for the slot; the header just shows
      // SAT in its place, which the widget test below pins.
      expect(badgeForSim(satellite), 'LTE');
      expect(badgeForSim(terrestrial), 'LTE');
    });
  });

  group('badgeForSim', () {
    test('an NSA slot with only its LTE anchor shows LTE', () {
      // The platform still says NR_NSA after the 5G leg has gone. The badge
      // describes the radio that is serving, so it says LTE rather than
      // disappearing and leaving the header with no technology label.
      final sim = _sim(override: 'NR_NSA', cells: [_cell('LTE')]);

      expect(sim.modeLabel, '5G NSA');
      expect(sim.nrServing, isNull);
      expect(badgeForSim(sim), 'LTE');
    });

    test('an NSA slot with both legs attached shows 5G', () {
      final sim = _sim(override: 'NR_NSA', cells: [_cell('LTE'), _cell('NR')]);

      expect(badgeForSim(sim), '5G');
    });

    test('NR connected without an NR cell still shows 5G', () {
      // NZ Samsungs keep the NR cell out of CellInfo while the platform's own
      // NR state says the leg is CONNECTED. The badge takes the platform's
      // word; the meter still reads the LTE anchor.
      final sim = _sim(
        override: 'NR_NSA',
        cells: [_cell('LTE')],
        nrState: 'CONNECTED',
      );

      expect(sim.nrServing, isNull);
      expect(sim.nrConnected, isTrue);
      expect(badgeForSim(sim), '5G');
    });

    test('an LTE-only slot shows LTE', () {
      expect(badgeForSim(_sim(override: 'NONE', cells: [_cell('LTE')])), 'LTE');
    });
  });

  group('LTE-Advanced', () {
    test('aggregation reads LTE+ on any network', () {
      for (final plmn in ['310-410', '310-260', '311-480']) {
        expect(
          techBadgeLabel(
            tech: 'LTE',
            override: 'LTE_CA',
            plmn: plmn,
            nrAttached: false,
          ),
          'LTE+',
        );
      }
    });

    test('Advanced Pro reads 5GE on AT&T and FirstNet only', () {
      for (final plmn in ['310-410', '313-100']) {
        expect(
          techBadgeLabel(
            tech: 'LTE',
            override: 'LTE_ADVANCED_PRO',
            plmn: plmn,
            nrAttached: false,
          ),
          '5GE',
        );
      }
      // Everywhere else it stays an LTE-Advanced marker, not a 5G one.
      for (final plmn in ['310-260', '311-480']) {
        expect(
          techBadgeLabel(
            tech: 'LTE',
            override: 'LTE_ADVANCED_PRO',
            plmn: plmn,
            nrAttached: false,
          ),
          'LTE+',
        );
      }
    });

    test('an attached 5G carrier outranks the LTE-Advanced marker', () {
      expect(
        techBadgeLabel(
          tech: 'LTE',
          override: 'LTE_ADVANCED_PRO',
          plmn: '310-410',
          nrAttached: true,
        ),
        '5G',
      );
    });
  });

  group('LTE-M', () {
    test('a network the list tags lteM reads LTE-M', () {
      // Android reports an eMTC carrier as plain LTE, so the operator list's
      // tag is the only thing that can say otherwise.
      CarrierNames.seed(
        {'313-700': 'Ameren'},
        lteMs: {'313-700'},
      );
      addTearDown(() => SignalQuality.setLteMs(const {}));

      final sim = _sim(
        override: 'NONE',
        cells: [_cell('LTE', mcc: '313', mnc: '700')],
      );

      expect(sim.isLteM, isTrue);
      expect(sim.modeLabel, '4G LTE-M');
      expect(badgeForSim(sim), 'LTE-M');
    });

    test('a network without the tag still reads LTE', () {
      CarrierNames.seed(
        {'310-410': 'AT&T'},
        lteMs: {'313-700'},
      );
      addTearDown(() => SignalQuality.setLteMs(const {}));

      final sim = _sim(override: 'NONE', cells: [_cell('LTE')]);

      expect(sim.isLteM, isFalse);
      expect(sim.modeLabel, '4G LTE');
      expect(badgeForSim(sim), 'LTE');
    });
  });

  group('techBadgeLabel', () {
    test('LTE with no 5G leg reads LTE', () {
      expect(
        techBadgeLabel(
          tech: 'LTE',
          override: 'NONE',
          plmn: '310-410',
          nrAttached: false,
        ),
        'LTE',
      );
    });

    test('a hidden NR leg does not claim 5G', () {
      // Samsung keeps reporting NR_NSA after the 5G leg has gone.
      expect(
        techBadgeLabel(
          tech: 'LTE',
          override: 'NR_NSA',
          plmn: '310-410',
          nrAttached: false,
        ),
        'LTE',
      );
    });

    test('an attached NR carrier with no house style reads 5G', () {
      expect(
        techBadgeLabel(
          tech: 'LTE',
          override: 'NR_NSA',
          plmn: '310-410',
          nrAttached: true,
        ),
        '5G',
      );
      expect(
        techBadgeLabel(
          tech: 'NR',
          override: 'NONE',
          plmn: '310-410',
          nrAttached: true,
        ),
        '5G',
      );
    });

    test('NR Advanced uses each carrier own label', () {
      String label(String plmn) => techBadgeLabel(
            tech: 'LTE',
            override: 'NR_ADVANCED',
            plmn: plmn,
            nrAttached: true,
          )!;

      expect(label('310-410'), '5G+'); // AT&T
      expect(label('313-100'), '5G+'); // FirstNet
      expect(label('310-260'), '5GUC'); // T-Mobile
      expect(label('311-480'), '5GUW'); // Verizon
      expect(label('311-970'), '5G'); // Big River has no house style
    });

    test('NR Advanced still needs an NR cell', () {
      expect(
        techBadgeLabel(
          tech: 'LTE',
          override: 'NR_ADVANCED',
          plmn: '310-410',
          nrAttached: false,
        ),
        'LTE',
      );
    });

    test('no served cell has no badge', () {
      expect(
        techBadgeLabel(
          tech: null,
          override: 'NONE',
          plmn: null,
          nrAttached: false,
        ),
        isNull,
      );
    });
  });
  group('LTE+ from a second carrier', () {
    SimReading reading(String override, List<Map<String, Object?>> cells) =>
        SimReading.fromMap({
          'slotIndex': 0,
          'subscriptionId': 1,
          'carrierName': 'Ameren',
          'isDefault': true,
          'simState': 'READY',
          'networkTypeName': 'LTE',
          'overrideNetworkType': override,
          'cells': cells,
        });

    Map<String, Object?> cell(
      String type, {
      int? arfcn,
      List<int> bands = const [],
      bool registered = true,
      int dbm = -100,
      String mcc = '313',
      String mnc = '700',
    }) =>
        {
          'type': type,
          'registered': registered,
          'arfcn': arfcn,
          'bands': bands,
          'dbm': dbm,
          'pci': 42,
          'mcc': mcc,
          'mnc': mnc,
        };

    test('an NSA slot with no NR cell reads LTE+ while a B29 is under it', () {
      // The platform still says NR_NSA, but no NR cell came back: the 5G leg
      // has gone. A band 29 supplemental downlink cannot exist on its own, so
      // its presence is proof the LTE side is aggregating — which is LTE+.
      final sim = reading('NR_NSA', [
        cell('LTE', arfcn: 5330, bands: const [14], dbm: -99),
        cell(
          'LTE',
          arfcn: 9700,
          bands: const [29],
          registered: false,
          dbm: -111,
        ),
      ]);

      expect(sim.nrServing, isNull);
      expect(sim.isNsa, isTrue);
      expect(sim.lteAggregated, isTrue);
      expect(badgeForSim(sim), 'LTE+');
    });

    test('every downlink-only band counts, not just 29', () {
      for (final band in [29, 32, 67, 69, 75, 76]) {
        final sim = reading('NONE', [
          cell('LTE', arfcn: 5330, bands: const [14]),
          cell('LTE', bands: [band], registered: false),
        ]);
        expect(sim.lteAggregated, isTrue, reason: 'B$band has no uplink');
        expect(badgeForSim(sim), 'LTE+', reason: 'B$band is aggregation');
      }
    });

    test('a second registered carrier reads LTE+ with no override', () {
      final sim = reading('NONE', [
        cell('LTE', arfcn: 5330, bands: const [14]),
        cell('LTE', arfcn: 5230, bands: const [13]),
      ]);
      expect(sim.lteSecondaries, hasLength(1));
      expect(badgeForSim(sim), 'LTE+');
    });

    test('one carrier with nothing under it stays LTE', () {
      final sim = reading('NR_NSA', [
        cell('LTE', arfcn: 5330, bands: const [14]),
      ]);
      expect(sim.lteAggregated, isFalse);
      expect(badgeForSim(sim), 'LTE');
    });
  });
}
