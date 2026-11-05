import 'package:cell_tower_monitor/models/band_filters.dart';
import 'package:cell_tower_monitor/models/cell_snapshot.dart';
import 'package:cell_tower_monitor/screens/home_screen.dart';
import 'package:cell_tower_monitor/theme/app_colors.dart';
import 'package:cell_tower_monitor/widgets/signal_bars.dart';
import 'package:cell_tower_monitor/widgets/tech_badge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<Object?, Object?> _cell({
  required String type,
  required bool registered,
  String? cellId,
  int? dbm,
  int? level,
  int? tac,
  int? pci,
  String? mcc,
  String? mnc,
  List<int> bands = const [],
  int? arfcn,
  int? rsrp,
  int? rsrq,
  int? sinr,
  bool heldChannel = false,
}) =>
    {
      'type': type,
      'registered': registered,
      'cellId': cellId,
      'dbm': dbm,
      'level': level,
      'tac': tac,
      'pci': pci,
      'mcc': mcc,
      'mnc': mnc,
      'bands': bands,
      'arfcn': arfcn,
      'rsrp': rsrp,
      'rsrq': rsrq,
      'sinr': sinr,
      if (heldChannel) 'heldChannel': true,
    };

Map<Object?, Object?> _dualSimPayload() => {
      'permissionGranted': true,
      'locationEnabled': true,
      'timestamp': 1730000000000,
      'deviceModel': 'samsung SM-S931U',
      'sims': [
        {
          'slotIndex': 0,
          'subscriptionId': 1,
          'carrierName': 'T-Mobile',
          'isDefault': true,
          'simState': 'READY',
          'networkTypeName': '5G NR',
          'cells': [
            // NSA: registered LTE anchor + registered NR secondary.
            _cell(
              type: 'LTE',
              registered: true,
              cellId: '6879550',
              dbm: -102,
              level: 2,
              tac: 45055,
              pci: 76,
              mcc: '310',
              mnc: '260',
              bands: [71],
              arfcn: 68611,
              rsrp: -102,
              rsrq: -12,
              sinr: 3,
            ),
            _cell(
              type: 'NR',
              registered: true,
              cellId: '1149015425',
              dbm: -92,
              level: 3,
              tac: 45055,
              pci: 512,
              mcc: '310',
              mnc: '260',
              bands: [41],
              arfcn: 632628,
              rsrp: -92,
              rsrq: -11,
              sinr: 7,
            ),
            _cell(
              type: 'LTE',
              registered: false,
              dbm: -118,
              level: 1,
              pci: 203,
              bands: [66],
            ),
          ],
        },
        {
          'slotIndex': 1,
          'subscriptionId': 2,
          'carrierName': 'Vodafone',
          'isDefault': false,
          'simState': 'READY',
          'networkTypeName': '4G LTE',
          'cells': [
            _cell(
              type: 'LTE',
              registered: true,
              cellId: '16777216',
              dbm: -78,
              level: 4,
              tac: 1201,
              pci: 12,
              mcc: '234',
              mnc: '15',
              bands: [20],
            ),
          ],
        },
      ],
    };

void main() {
  group('dual SIM + NSA', () {
    test('reads both slots and detects NSA on the 5G SIM', () {
      final snapshot = CellSnapshot.fromMap(_dualSimPayload());

      expect(snapshot.isDualSim, isTrue);
      expect(snapshot.activeSims.map((s) => s.label), ['SIM 1', 'SIM 2']);
      expect(snapshot.cellCount, 4);

      final first = snapshot.activeSims.first;
      expect(first.carrierName, 'T-Mobile');
      expect(first.isNsa, isTrue);
      expect(first.modeLabel, '5G NSA');
      expect(first.lteServing!.dbm, -102);
      expect(first.nrServing!.dbm, -92);
      expect(first.serving!.tech, CellTech.nr);

      final second = snapshot.activeSims[1];
      expect(second.isNsa, isFalse);
      expect(second.modeLabel, '4G LTE');
      expect(second.nrServing, isNull);
    });

    test('splits the LTE cell identity into eNB and sector in decimal', () {
      final lte = CellSnapshot.fromMap(_dualSimPayload()).activeSims.first.lteServing!;

      expect(lte.enb, 26873);
      expect(lte.sector, 62);
      // 26873 * 256 + 62 == 6879550
      expect(lte.enb! * 256 + lte.sector!, 6879550);

      final nr = CellSnapshot.fromMap(_dualSimPayload()).activeSims.first.nrServing!;
      expect(nr.enb, isNull, reason: 'eNB only applies to LTE');
    });

    test('decodes the NR NCI into gNB and sector in decimal', () {
      // AT&T runs 26-bit gNB IDs with a 10-bit sector: gNB 12295710, sector 49
      // is NCI 12590807089. Splitting that at 24 bits gives 3073927 instead.
      final att = CellTower.fromMap({
        'type': 'NR',
        'registered': true,
        'cellId': '12590807089',
        'mcc': '310',
        'mnc': '410',
      });
      expect(att.gnb, 12295710);
      expect(att.sector, 49);
      expect(att.gnb! * 1024 + att.sector!, 12590807089);

      // The old 24/12 split must not come back.
      expect(12590807089 >> 12, 3073927);

      // T-Mobile runs 24-bit gNB IDs with a 12-bit sector: gNB 1053255,
      // sector 312 is NCI 4314132792. Read at 22 bits it comes out as
      // 263313 / 12600, a tower number that does not exist on their maps.
      final tmo = CellTower.fromMap({
        'type': 'NR',
        'registered': true,
        'cellId': '4314132792',
        'mcc': '310',
        'mnc': '260',
      });
      expect(tmo.gnb, 1053255);
      expect(tmo.sector, 312);
      expect(tmo.gnb! * 4096 + tmo.sector!, 4314132792);
      expect(4314132792 >> 14, 263313, reason: 'the 22-bit split is wrong');

      // The 22-bit default still applies to operators that use it.
      final vzw = CellTower.fromMap({
        'type': 'NR',
        'registered': true,
        'cellId': '${260000 * 16384 + 5}',
        'mcc': '311',
        'mnc': '480',
      });
      expect(vzw.gnb, 260000);
      expect(vzw.sector, 5);
    });

    test('an nrBits tag sets the NCI split before the built-in brands', () {
      // The operator list can name a split this build does not know, and can
      // change one without a release: 24 bits must win over AT&T's 26.
      SignalQuality.setNrBits(const {'310-410': 24});
      addTearDown(() => SignalQuality.setNrBits(const {}));

      final att = CellTower.fromMap({
        'type': 'NR',
        'registered': true,
        'cellId': '12590807089',
        'mcc': '310',
        'mnc': '410',
      });
      expect(att.gnb, 12590807089 >> 12);
      expect(att.sector, 12590807089 & ((1 << 12) - 1));
    });

    test('reads a T-Mobile n38 indicator as n41', () {
      CellTower nr({
        required String mcc,
        required String mnc,
        required int arfcn,
        int band = 38,
      }) =>
          CellTower.fromMap({
            'type': 'NR',
            'registered': true,
            'arfcn': arfcn,
            'bands': [band],
            'mcc': mcc,
            'mnc': mnc,
          });

      // 2606.55 MHz is NREF 521310: inside n38's 514000–524999 and n41's
      // 499200–537999. T-Mobile runs n41 across the block and no n38.
      final tmo = nr(mcc: '310', mnc: '260', arfcn: 521310);
      expect(tmo.bandReconciled, isTrue);
      expect(tmo.bandLabel, 'n41');
      expect(tmo.downlinkMhz, closeTo(2606.55, 0.005));
      expect(tmo.isTdd, isTrue, reason: 'n41 pairs one band for both ways');

      // A European n38 is a real n38, whatever the ARFCN overlap says.
      final europe = nr(mcc: '262', mnc: '01', arfcn: 521310);
      expect(europe.bandReconciled, isFalse);
      expect(europe.bandLabel, 'n38');

      // Outside n41's range there is nothing to correct.
      final elsewhere = nr(mcc: '310', mnc: '260', arfcn: 540000);
      expect(elsewhere.bandReconciled, isFalse);
      expect(elsewhere.bandLabel, 'n38');

      expect(tmo.reportedBand, 38, reason: 'the note names the modem band');
    });

    test('reads a T-Mobile n2 indicator as n25', () {
      CellTower nr(String mcc, String mnc, int arfcn, int band) =>
          CellTower.fromMap({
            'type': 'NR',
            'registered': true,
            'arfcn': arfcn,
            'bands': [band],
            'mcc': mcc,
            'mnc': mnc,
          });

      // n2 (1930–1990 MHz, ARFCN 386000–398999) sits entirely inside n25
      // (1930–1995, 386000–399999). T-Mobile's PCS carrier is n25.
      final tmo = nr('310', '260', 390000, 2);
      expect(tmo.bandReconciled, isTrue);
      expect(tmo.bandLabel, 'n25');
      expect(tmo.reportedBand, 2);
      // n25 is FDD, so the pair is still shown separately.
      expect(tmo.isTdd, isFalse);
      expect(tmo.downlinkMhz, closeTo(1950.0, 0.005));
      expect(tmo.uplinkMhz, closeTo(1870.0, 0.005));

      // The same indicator on another carrier is the real n2.
      final att = nr('310', '410', 390000, 2);
      expect(att.bandReconciled, isFalse);
      expect(att.bandLabel, 'n2');

      // An ARFCN outside n25's window is left alone rather than corrected.
      final odd = nr('310', '260', 400000, 2);
      expect(odd.bandReconciled, isFalse);
      expect(odd.bandLabel, 'n2');
    });

    test('names n71 when the modem reports band -1', () {
      final cell = CellTower.fromMap({
        'type': 'NR',
        'registered': true,
        'arfcn': 126270,
        'bands': [-1],
        'mcc': '310',
        'mnc': '260',
      });

      // -1 is BAND_UNKNOWN, not a band number.
      expect(cell.bands, isEmpty);
      expect(cell.bandInferred, isTrue);
      expect(cell.bandLabel, 'n71');
      expect(cell.downlinkMhz, closeTo(631.35, 0.005));
      expect(cell.uplinkMhz, closeTo(677.35, 0.005),
          reason: 'n71 is FDD, 46 MHz above its downlink');

      // A channel two bands share has no single answer, so it stays unnamed.
      final shared = CellTower.fromMap({
        'type': 'NR',
        'registered': true,
        'arfcn': 390000,
        'bands': [-1],
        'mcc': '310',
        'mnc': '260',
      });
      expect(shared.bandLabel, isNull);
    });

    test('the band corrections can be switched off', () {
      CellTower nr(int arfcn, List<int> bands) => CellTower.fromMap({
            'type': 'NR',
            'registered': true,
            'arfcn': arfcn,
            'bands': bands,
            'mcc': '310',
            'mnc': '260',
          });

      final narrow = nr(521310, const [38]); // T-Mobile n41 named n38
      final cbrs = nr(640000, const [77]); // CBRS named n77
      final unknown = nr(126270, const [-1]); // n71, band unknown

      expect(narrow.bandLabel, 'n41');
      expect(cbrs.bandLabel, 'n48');
      expect(unknown.bandLabel, 'n71');

      BandFilters.tmobileBands = false;
      expect(narrow.bandLabel, 'n38');

      BandFilters.cbrs = false;
      expect(cbrs.bandLabel, 'n77');

      // Naming a band from the channel is a fallback, not a correction, so it
      // has no switch and keeps working with both corrections off.
      expect(unknown.bandLabel, 'n71');

      // The next test must start from the defaults, not from these switches.
      BandFilters.reset();
      expect(narrow.bandLabel, 'n41');
      expect(cbrs.bandLabel, 'n48');
      expect(unknown.bandLabel, 'n71');
    });

    test('uses the requested 10 dBm bar steps on both RATs', () {
      final sim = CellSnapshot.fromMap(_dualSimPayload()).activeSims.first;
      expect(sim.lteServing!.bars, 3, reason: '-102 dBm is 3 bars');
      expect(sim.nrServing!.bars, 4, reason: '-92 dBm is 4 bars');
      expect(sim.neighbours.single.bars, 1, reason: '-118 dBm is 1 bar');
    });
  });

  group('AT&T sector plan', () {
    CellTower lte(
      int enb,
      int sector, {
      String mcc = '310',
      String mnc = '410',
      int? arfcn,
      List<int> bands = const [],
    }) =>
        CellTower.fromMap({
          'type': 'LTE',
          'registered': true,
          'cellId': '${enb * 256 + sector}',
          'mcc': mcc,
          'mnc': mnc,
          'arfcn': arfcn,
          'bands': bands,
        });

    CellTower nr(
      int sector, {
      int? arfcn,
      List<int> bands = const [],
      String mnc = '410',
    }) {
      // AT&T: 26-bit gNB, 10-bit sector.
      const gnb = 12295029;
      return CellTower.fromMap({
        'type': 'NR',
        'registered': true,
        'cellId': '${gnb * 1024 + sector}',
        'mcc': '310',
        'mnc': mnc,
        'bands': bands,
        'arfcn': arfcn,
      });
    }

    test('keeps LTE sectors numeric — no operator naming', () {
      for (final value in [1, 2, 5, 228]) {
        final cell = lte(245970, value);
        expect(cell.sector, value);
      }
    });

    test('keeps NR sectors numeric too — naming was dropped', () {
      // The Alpha/Beta/Gamma map is gone: whatever the carrier, the sector is
      // just the number the NCI carries.
      for (final value in [25, 49, 73]) {
        final cell = nr(value, arfcn: 176910, bands: const [5]);
        expect(cell.sector, value);
      }
    });

    test('identifies the NR carrier and centre frequency', () {
      expect(nr(25, arfcn: 176910, bands: const [5]).nrCarrier,
          NrCarrier.n5);
      expect(nr(25, arfcn: 176910).downlinkLabel, '884.55 MHz');

      expect(nr(26, arfcn: 632064).nrCarrier, NrCarrier.dodLower);
      expect(nr(26, arfcn: 632064).downlinkLabel, '3480.96 MHz');

      expect(nr(27, arfcn: 658080).nrCarrier, NrCarrier.n77);
      expect(nr(27, arfcn: 658080).downlinkLabel, '3871.20 MHz');

      // 3531.36 MHz is still inside the DoD block (3300–3550), not CBRS.
      expect(nr(26, arfcn: 635424).nrCarrier, NrCarrier.dodLower);
      expect(nr(26, arfcn: 635424).downlinkLabel, '3531.36 MHz');
    });

    test('splits DoD, CBRS and C-Band by frequency', () {
      // 3480.96 MHz, 3600.00 MHz and 3871.20 MHz fall in the three blocks.
      final dod = nr(26, arfcn: 632064, bands: const [77]);
      expect(dod.nrCarrierLabel, 'n77 DoD');
      expect(dod.bandLabel, 'n77');

      final cbrs = nr(26, arfcn: 640000, bands: const [77]);
      expect(cbrs.nrCarrierLabel, 'n48 CBRS');
      expect(cbrs.downlinkLabel, '3600.00 MHz');
      expect(cbrs.isCbrsFrequency, isTrue);
      // n77 contains CBRS, so a modem naming n77 here is corrected to n48.
      expect(cbrs.bandLabel, 'n48');

      final cband = nr(27, arfcn: 658080, bands: const [77]);
      expect(cband.nrCarrierLabel, 'n77 C-Band');
      expect(cband.bandLabel, 'n77');
      expect(cband.isCbrsFrequency, isFalse);

      // An n48 carrier is named from its own band, CBRS or not.
      expect(nr(30, arfcn: 640000, bands: const [48]).bandLabel, 'n48');
    });

    test('leaves the carrier unknown when only band n77 is known', () {
      final cell = nr(51, bands: const [77]);
      expect(cell.nrCarrier, NrCarrier.unknown);
      expect(cell.sector, 51);
    });

    test('converts an LTE EARFCN to downlink and uplink', () {
      // Band 66: downlink 2110-2200, uplink 1710-1780 (400 MHz below).
      final b66 = lte(245710, 228, arfcn: 67086, bands: const [66]);
      expect(b66.downlinkLabel, '2175.00 MHz');
      expect(b66.uplinkLabel, '1775.00 MHz');

      // Band 2: 80 MHz between the directions.
      final b2 = lte(245029, 12, arfcn: 700, bands: const [2]);
      expect(b2.downlinkLabel, '1940.00 MHz');
      expect(b2.uplinkLabel, '1860.00 MHz');

      // Band 13 is reverse duplex — the uplink sits *above* the downlink.
      final b13 = lte(245029, 12, arfcn: 5220, bands: const [13]);
      expect(b13.downlinkLabel, '750.00 MHz');
      expect(b13.uplinkLabel, '781.00 MHz');

      // Band 41 is TDD: one carrier both ways.
      final b41 = lte(245029, 12, arfcn: 40000, bands: const [41]);
      expect(b41.downlinkLabel, '2531.00 MHz');
      expect(b41.uplinkLabel, '2531.00 MHz');

      // Band 29 is downlink-only, so there is no uplink to report.
      final b29 = lte(245029, 12, arfcn: 9700, bands: const [29]);
      expect(b29.downlinkLabel, '721.00 MHz');
      expect(b29.uplinkLabel, isNull);
    });

    test('converts an NR ARFCN to downlink and uplink', () {
      final n5 = nr(25, arfcn: 176910, bands: const [5]);
      expect(n5.downlinkLabel, '884.55 MHz');
      expect(n5.uplinkLabel, '839.55 MHz');

      // n71 downlink 617-652, uplink 663-698 — here the uplink is higher.
      final n71 = nr(25, arfcn: 124000, bands: const [71]);
      expect(n71.downlinkLabel, '620.00 MHz');
      expect(n71.uplinkLabel, '666.00 MHz');

      // n77 is TDD, so both directions share the carrier.
      final n77 = nr(27, arfcn: 658080, bands: const [77]);
      expect(n77.downlinkLabel, '3871.20 MHz');
      expect(n77.uplinkLabel, '3871.20 MHz');
    });

    test('reports no frequency without an ARFCN or a known band', () {
      expect(lte(245029, 12).downlinkMhz, isNull);
      expect(nr(27).downlinkMhz, isNull);
      // 500 MHz sits in no NR band, so there is no uplink block to pair with —
      // the downlink is still priced on the global raster.
      expect(nr(27, arfcn: 100000).uplinkMhz, isNull,
          reason: 'no band, no uplink');
      expect(nr(27, arfcn: 100000).bandLabel, isNull);
    });

    test('works out the LTE band from the EARFCN when the modem omits it', () {
      // Several Samsung build/modem pairs (the A10e on Android 11 among them)
      // report a valid EARFCN with an empty band list. The 3GPP raster still
      // identifies the band, so the frequency rows do not have to disappear.
      final b8 = lte(245029, 62, arfcn: 3580);
      expect(b8.bands, isEmpty);
      expect(b8.bandInferred, isTrue);
      // AT&T's band 8 stays band 8 in both builds: the B106 re-code belongs to
      // the utility network's PLMN, not to the band number.
      expect(b8.bandLabel, 'B8');
      expect(b8.downlinkLabel, '938.00 MHz');
      expect(b8.uplinkLabel, '893.00 MHz');

      final b71 = lte(245029, 62, arfcn: 68611);
      expect(b71.bandLabel, 'B71');
      expect(b71.downlinkLabel, '619.50 MHz');
      expect(b71.uplinkLabel, '665.50 MHz');

      // A band the modem did report always wins over the raster.
      final reported = lte(245029, 62, arfcn: 68611, bands: const [71]);
      expect(reported.bandInferred, isFalse);
      expect(reported.bandLabel, 'B71');

      // Every band in the 3GPP table is now in the raster, so an EARFCN once
      // left unnamed is named: 4000 is band 9 at 1864.90 MHz.
      final b9 = lte(245029, 62, arfcn: 4000);
      expect(b9.bandLabel, 'B9');
      expect(b9.downlinkLabel, '1864.90 MHz');
      expect(b9.uplinkLabel, '1769.90 MHz');

      // A channel outside every band is still left alone rather than guessed.
      expect(lte(245029, 62, arfcn: 72000).bandLabel, isNull);
      expect(lte(245029, 62, arfcn: 72000).downlinkMhz, isNull);

      // The NR raster is global, so the band comes from the ARFCN block: the
      // C-band channel the old table mis-filed under n77's window is n77.
      expect(nr(27, arfcn: 658080).nrArfcnBand, 77);
      expect(nr(27, arfcn: 658080).bandLabel, 'n77');
      expect(nr(27, arfcn: 658080).downlinkLabel, '3871.20 MHz');

      // An ARFCN in none of them stays unnamed.
      expect(nr(27, arfcn: 100000).nrArfcnBand, isNull);
      expect(nr(27, arfcn: 100000).bandLabel, isNull);
    });

    test('the A10e build re-codes its own network to B106', () {
      // Band 106: 935–940 down, 896–901 up, 39 MHz duplex.
      expect(bandName(106), 'B106');

      // The band-8 channel number is re-expressed on band 106's raster, and the
      // uplink follows band 106's 39 MHz duplex instead of band 8's 35 MHz.
      final cell = lte(245029, 62, mcc: '313', mnc: '700', arfcn: 3580);
      expect(cell.downlinkLabel, '938.00 MHz');
      if (kA10eBandAlias) {
        expect(cell.bandLabel, 'B106');
        expect(cell.uplinkLabel, '899.00 MHz');
        expect(cell.displayedArfcn, 134322);
      } else {
        expect(cell.bandLabel, 'B8');
        expect(cell.uplinkLabel, '893.00 MHz');
        expect(cell.displayedArfcn, 3580);
      }

      // A channel already on band 106's raster reads the same way.
      final native = lte(245029, 62, mcc: '313', mnc: '700', arfcn: 134322);
      expect(native.displayedArfcn, 134322);
      if (kA10eBandAlias) {
        expect(native.bandLabel, 'B106');
        expect(native.downlinkLabel, '938.00 MHz');
        expect(native.uplinkLabel, '899.00 MHz');
      } else {
        // The normal build keeps the 3GPP band, which is already 106 here.
        expect(native.bandLabel, 'B106');
        expect(native.downlinkLabel, '938.00 MHz');
        expect(native.uplinkLabel, '899.00 MHz');
      }

      // The plan follows the channel number, not just one carrier.
      final higher = lte(245029, 62, mcc: '313', mnc: '700', arfcn: 3590);
      expect(higher.downlinkLabel, '939.00 MHz');
      expect(higher.uplinkLabel, kA10eBandAlias ? '900.00 MHz' : '894.00 MHz');
      expect(higher.displayedArfcn, kA10eBandAlias ? 134332 : 3590);
    });

    test('the re-code follows the PLMN, not the band number', () {
      // A band-8 cell on any other network keeps its 3GPP label in both builds.
      final foreign = lte(245029, 62, mcc: '310', mnc: '260', arfcn: 3580);
      expect(foreign.bandLabel, 'B8');
      expect(foreign.uplinkLabel, '893.00 MHz');
      expect(foreign.displayedArfcn, 3580);

      // A different band on the utility network reads as itself, so the build
      // still shows whatever the modem is actually camped on after a re-lock.
      final otherBand =
          lte(195007, 11, mcc: '313', mnc: '700', arfcn: 700, bands: const [2]);
      expect(otherBand.bandLabel, 'B2');
      expect(otherBand.downlinkLabel, '1940.00 MHz');
      final otherBandInferred =
          lte(195007, 11, mcc: '313', mnc: '700', arfcn: 700);
      expect(otherBandInferred.bandLabel, 'B2');

      // After the band lock the modem can report the cell with no channel and
      // no band list at all. The PLMN still identifies the network, so the
      // band row stays — but frequencies are left blank rather than guessed.
      final unbanded = lte(195007, 11, mcc: '313', mnc: '700');
      expect(unbanded.arfcn, isNull);
      expect(unbanded.displayedArfcn, isNull);
      expect(unbanded.bandLabel, kA10eBandAlias ? 'B106' : isNull);
      expect(unbanded.downlinkMhz, isNull);
      expect(unbanded.uplinkMhz, isNull);
    });

    test('the Anterix B106 switch applies without a rebuild', () {
      final cell = lte(245029, 62, mcc: '313', mnc: '700', arfcn: 3580);

      // Off by default: the band 8 the modem reports, on band 8's raster.
      expect(cell.bandLabel, 'B8');
      expect(cell.displayedArfcn, 3580);

      BandFilters.anterixB106 = true;
      addTearDown(BandFilters.reset);

      // Same object, same reading: only the numbering changed.
      expect(cell.bandLabel, 'B106');
      expect(cell.displayedArfcn, 134322);
      expect(cell.uplinkLabel, '899.00 MHz');
      expect(cell.sharedBands, const [106],
          reason: 'a remote phone is told the numbering too');
    });

    test('publishes its own numbering over the LAN', () {
      final snapshot = CellSnapshot.fromMap({
        'permissionGranted': true,
        'locationEnabled': true,
        'timestamp': 1730000000000,
        'deviceModel': 'samsung SM-A102U',
        'sims': [
          {
            'slotIndex': 0,
            'subscriptionId': 1,
            'carrierName': 'Ameren',
            'isDefault': true,
            'simState': 'READY',
            'networkTypeName': 'LTE',
            'cells': [
              _cell(
                type: 'LTE',
                registered: true,
                cellId: '${195007 * 256 + 11}',
                pci: 61,
                dbm: -101,
                mcc: '313',
                mnc: '700',
                arfcn: 3580,
              ),
            ],
          },
        ],
      });

      final sharedSim =
          (snapshot.toJsonMap()['sims'] as List<Object?>).single
              as Map<Object?, Object?>;
      final cell =
          (sharedSim['cells'] as List<Object?>).single as Map<Object?, Object?>;
      expect(sharedSim['carrierName'], 'Ameren');

      if (kA10eBandAlias) {
        // A peer has no re-code of its own, so it is sent the numbers this
        // phone shows: band 106 on band 106's raster.
        expect(cell['bands'], [106]);
        expect(cell['arfcn'], 134322);
      } else {
        // The normal build numbers this carrier 8, and publishes that.
        expect(cell['bands'], isEmpty);
        expect(cell['arfcn'], 3580);
      }

      // Whatever the sender wrote, a B106 cell is readable by every build —
      // that is what makes the shared payload render on the other phone.
      final peer = CellTower.fromMap({
        ...cell,
        'bands': const [106],
        'arfcn': 134322,
      });
      expect(peer.bandLabel, 'B106');
      expect(peer.downlinkLabel, '938.00 MHz');
      expect(peer.uplinkLabel, '899.00 MHz');
    });

    test('marks a channel the modem stopped reporting', () {
      // The native side holds the last channel a served cell reported, so a
      // band-lock change that drops mEarfcn does not blank the ARFCN and
      // frequency rows while the same cell is still served.
      final held = CellTower.fromMap(_cell(
        type: 'LTE',
        registered: true,
        cellId: '${195007 * 256 + 11}',
        pci: 61,
        dbm: -101,
        mcc: '313',
        mnc: '700',
        arfcn: 3580,
        heldChannel: true,
      ));
      expect(held.channelHeld, isTrue);
      expect(held.displayedArfcn, kA10eBandAlias ? 134322 : 3580);
      expect(held.downlinkMhz, closeTo(938.0, 0.001));
      expect(held.uplinkMhz, closeTo(kA10eBandAlias ? 899.0 : 893.0, 0.001));

      // A channel the modem did report is not marked as held.
      expect(lte(245029, 62, arfcn: 3580).channelHeld, isFalse);
    });

    test('marks TDD carriers so the card can show one frequency', () {
      // Band 41 and n77 run one carrier for both directions.
      expect(lte(245029, 62, arfcn: 40000, bands: const [41]).isTdd, isTrue);
      expect(nr(27, arfcn: 658080, bands: const [77]).isTdd, isTrue);

      // FDD pairs keep their two rows.
      expect(lte(245029, 62, arfcn: 68611, bands: const [71]).isTdd, isFalse);
      expect(nr(25, arfcn: 176910, bands: const [5]).isTdd, isFalse);

      // Downlink-only band 29 has no uplink to pair with.
      expect(lte(245029, 62, arfcn: 9700, bands: const [29]).isTdd, isFalse);
    });
  });

  group('NSA gNB estimate', () {
    Map<Object?, Object?> payload({
      required String mnc,
      String? nci,
      int enb = 245029,
      int sector = 12,
      int? arfcn = 658080,
      List<int> bands = const [77],
    }) =>
        {
          'sims': [
            {
              'slotIndex': 0,
              'subscriptionId': 1,
              'carrierName': mnc == '410' ? 'AT&T' : 'T-Mobile',
              'isDefault': true,
              'simState': 'READY',
              'overrideNetworkType': 'NR_NSA',
              'cells': [
                // eNB 245029, sector 12 (Beta6) by default.
                _cell(
                  type: 'LTE',
                  registered: true,
                  cellId: '${enb * 256 + sector}',
                  mcc: '310',
                  mnc: mnc,
                  pci: 195,
                  bands: const [2],
                ),
                _cell(
                  type: 'NR',
                  registered: true,
                  cellId: nci,
                  mcc: '310',
                  mnc: mnc,
                  pci: 341,
                  bands: bands,
                  arfcn: arfcn,
                ),
              ],
            },
          ],
        };

    test('derives the AT&T gNB from the anchor when the NCI is masked', () {
      final sim = CellSnapshot.fromMap(payload(mnc: '410')).activeSims.single;

      expect(sim.isNsa, isTrue);
      expect(sim.nrServing!.cellId, isNull, reason: 'radio withholds it');
      expect(sim.lteServing!.enb, 245029);
      expect(sim.lteServing!.sector, 12);
      expect(sim.nsaGnbEstimate, 12295029);
      expect(sim.nrServing!.sector, isNull,
          reason: 'no NCI means no sector, and NSA never guesses one');
    });

    test('estimates the gNB on every carrier, including Dish upper DoD', () {
      final n5 = CellSnapshot.fromMap(
        payload(mnc: '410', arfcn: 176910, bands: const [5]),
      ).activeSims.single;
      expect(n5.nsaGnbEstimate, 12295029);

      final dod = CellSnapshot.fromMap(
        payload(mnc: '410', arfcn: 632064),
      ).activeSims.single;
      expect(dod.nsaGnbEstimate, 12295029);

      final dish = CellSnapshot.fromMap(
        payload(mnc: '410', arfcn: 635424),
      ).activeSims.single;
      expect(dish.nsaGnbEstimate, 12295029,
          reason: 'the gNB offset is carrier-independent');
    });

    test('ignores the unmapped AT&T small-cell eNB ranges', () {
      for (final prefix in ['240', '241', '242', '243', '246', '248', '249']) {
        final sim = CellSnapshot.fromMap(
          payload(mnc: '410', enb: int.parse('${prefix}029')),
        ).activeSims.single;
        expect(sim.nsaGnbEstimate, isNull, reason: 'eNB ${prefix}xxx');
      }
    });

    test('does not invent a gNB for other operators', () {
      final sim = CellSnapshot.fromMap(payload(mnc: '260')).activeSims.single;
      expect(sim.nsaGnbEstimate, isNull, reason: 'only AT&T is mapped');
    });

    test('prefers the reported NCI over the estimate', () {
      // NCI 12590109697 == 12295029 << 10 | 1.
      final sim = CellSnapshot
          .fromMap(payload(mnc: '410', nci: '12590109697'))
          .activeSims
          .single;
      expect(sim.nrServing!.gnb, 12295029);
      expect(sim.nsaGnbEstimate, isNull, reason: 'no guess needed');
    });
  });

  group('LTE band 29 secondary', () {
    /// A primary LTE cell plus a band 29 supplemental downlink.
    ///
    /// The SDL arrives the way a modem actually reports it: a PCI, a band and
    /// a channel, no ECI, and — on this fleet — no registered flag either, even
    /// though it can only be listed because it is aggregated.
    CellSnapshot payload({
      bool b29Registered = false,
      List<int>? b29Bands = const [29],
      int? b29Arfcn = 9700,
      String mnc = '410',
    }) =>
        CellSnapshot.fromMap({
          'sims': [
            {
              'slotIndex': 0,
              'subscriptionId': 1,
              'carrierName': 'AT&T',
              'isDefault': true,
              'simState': 'READY',
              'networkTypeName': 'LTE',
              'overrideNetworkType': 'LTE_CA',
              'cells': [
                _cell(
                  type: 'LTE',
                  registered: true,
                  cellId: '${245029 * 256 + 12}',
                  mcc: '310',
                  mnc: mnc,
                  pci: 195,
                  bands: const [2],
                  arfcn: 700,
                ),
                _cell(
                  type: 'LTE',
                  registered: b29Registered,
                  cellId: null,
                  mcc: '310',
                  mnc: mnc,
                  pci: 470,
                  bands: b29Bands ?? const [],
                  arfcn: b29Arfcn,
                ),
              ],
            },
          ],
        });

    test('a heard band 29 carrier counts as attached, not as a neighbour', () {
      final sim = payload().activeSims.single;

      expect(sim.lteServing!.enb, 245029, reason: 'the anchor stays the anchor');
      expect(sim.lteSecondaries, hasLength(1));
      expect(sim.lteSecondaries.single.bandLabel, 'B29');
      expect(sim.neighbours, isEmpty,
          reason: 'an SDL only reports once it is carrying traffic');
    });

    test('the registered flag does not change where it is listed', () {
      final sim = payload(b29Registered: true).activeSims.single;
      expect(sim.lteServing!.enb, 245029);
      expect(sim.lteSecondaries.single.bandLabel, 'B29');
      expect(sim.neighbours, isEmpty);
    });

    test('has no eNB, no sector and no uplink', () {
      final cell = payload().activeSims.single.lteSecondaries.single;
      expect(cell.enb, isNull);
      expect(cell.sector, isNull);
      expect(cell.downlinkLabel, '721.00 MHz');
      expect(cell.uplinkLabel, isNull, reason: 'the band has no uplink');
      expect(cell.isTdd, isFalse);
    });

    test('is recognised from the channel when the modem names no band', () {
      final sim = payload(b29Bands: null, b29Arfcn: 9700).activeSims.single;
      expect(sim.lteSecondaries.single.isBand29, isTrue);
      expect(sim.lteSecondaries.single.bandInferred, isTrue);
    });

    test('leaves the reporting mode alone — it is still LTE', () {
      final sim = payload().activeSims.single;
      expect(sim.mode, NetworkMode.lte);
      expect(sim.isNsa, isFalse);
      expect(sim.isSa, isFalse);
    });

    test('arrives with no MCC/MNC until it is carrying data', () {
      // What the modem actually hands over while the carrier is idle: a PCI, a
      // band and a channel, with no PLMN and a TAC of 0.
      final sim = CellSnapshot.fromMap({
        'sims': [
          {
            'slotIndex': 0,
            'subscriptionId': 1,
            'carrierName': 'AT&T',
            'isDefault': true,
            'simState': 'READY',
            'networkTypeName': 'LTE',
            'cells': [
              _cell(type: 'LTE', registered: true, cellId: '${245029 * 256 + 12}',
                  pci: 195, bands: const [2], arfcn: 700, mcc: '310', mnc: '410'),
              _cell(type: 'LTE', registered: false, pci: 386, bands: const [29],
                  arfcn: 9685, tac: 0),
            ],
          },
        ],
      }).activeSims.single;

      final sdl = sim.lteSecondaries.single;
      expect(sdl.isBand29, isTrue);
      expect(sdl.plmn, isNull, reason: 'no MCC/MNC while it is idle');
      expect(sdl.enb, isNull);
      expect(sdl.pci, 386);
      expect(sdl.downlinkLabel, '719.50 MHz');
      expect(sim.lteServing!.plmn, '310-410', reason: 'the anchor still names it');
    });

    test('a band 29 cell alone in the slot is still reported', () {
      // Nothing registered at all: the SDL is the only thing the radio handed
      // over, and dropping it would leave the slot looking empty.
      final sim = CellSnapshot.fromMap({
        'sims': [
          {
            'slotIndex': 0,
            'subscriptionId': 1,
            'carrierName': 'AT&T',
            'isDefault': true,
            'simState': 'READY',
            'networkTypeName': 'LTE',
            'cells': [
              _cell(type: 'LTE', registered: true, pci: 470, bands: const [29],
                  arfcn: 9700, mcc: '310', mnc: '410'),
            ],
          },
        ],
      }).activeSims.single;

      expect(sim.lteServing!.isBand29, isTrue);
      expect(sim.lteSecondaries, isEmpty, reason: 'it is not a second cell');
    });
  });

  group('LTE carrier aggregation', () {
    /// A B2 anchor with a second registered carrier on another band, the way
    /// the desktop test source serves an extra LTE layer.
    CellSnapshot payload() => CellSnapshot.fromMap({
          'sims': [
            {
              'slotIndex': 0,
              'subscriptionId': 1,
              'carrierName': 'AT&T',
              'isDefault': true,
              'simState': 'READY',
              'networkTypeName': 'LTE',
              'overrideNetworkType': 'LTE_CA',
              'cells': [
                _cell(type: 'LTE', registered: true, cellId: '${245029 * 256 + 12}',
                    pci: 195, bands: const [2], arfcn: 700, mcc: '310', mnc: '410'),
                _cell(type: 'LTE', registered: true, cellId: '${245029 * 256 + 13}',
                    pci: 196, bands: const [66], arfcn: 66786, mcc: '310',
                    mnc: '410'),
              ],
            },
          ],
        });

    test('a second registered carrier is a secondary, not a neighbour', () {
      final sim = payload().activeSims.single;

      expect(sim.lteServing!.bandLabel, 'B2', reason: 'the first is the anchor');
      expect(sim.lteSecondaries, hasLength(1));
      expect(sim.lteSecondaries.single.bandLabel, 'B66');
      expect(sim.neighbours, isEmpty);
    });

    test('a CA layer keeps the eNB and sector band 29 cannot have', () {
      final layer = payload().activeSims.single.lteSecondaries.single;
      expect(layer.enb, 245029);
      expect(layer.sector, 13);
      expect(layer.isSecondaryLte, isFalse, reason: 'not the SDL case');
    });
  });

  group('standalone 5G', () {
    test('NR without an LTE anchor is SA', () {
      final snapshot = CellSnapshot.fromMap({
        'sims': [
          {
            'slotIndex': 0,
            'carrierName': 'Test',
            'isDefault': true,
            'simState': 'READY',
            'cells': [
              _cell(type: 'NR', registered: true, cellId: '99', dbm: -88),
            ],
          },
        ],
      });

      final sim = snapshot.activeSims.single;
      expect(sim.isSa, isTrue);
      expect(sim.isNsa, isFalse);
      expect(sim.modeLabel, '5G SA');
      expect(sim.serving!.tech, CellTech.nr);
    });

    test('platform override marks NSA even when the NR leg is hidden', () {
      final snapshot = CellSnapshot.fromMap({
        'sims': [
          {
            'slotIndex': 0,
            'carrierName': 'AT&T',
            'isDefault': true,
            'simState': 'READY',
            'overrideNetworkType': 'NR_NSA',
            'cells': [
              _cell(type: 'LTE', registered: true, dbm: -100, pci: 475, bands: [30]),
            ],
          },
        ],
      });

      final sim = snapshot.activeSims.single;
      expect(sim.isNsa, isTrue);
      expect(sim.modeLabel, '5G NSA');
      expect(sim.nrServing, isNull, reason: 'radio did not expose the NR cell');
    });

    test('NR_ADVANCED override with only an NR leg is standalone 5G', () {
      final snapshot = CellSnapshot.fromMap({
        'sims': [
          {
            'slotIndex': 0,
            'isDefault': true,
            'simState': 'READY',
            'overrideNetworkType': 'NR_ADVANCED',
            'cells': [_cell(type: 'NR', registered: true, dbm: -90)],
          },
        ],
      });

      final sim = snapshot.activeSims.single;
      expect(sim.isSa, isTrue);
      expect(sim.isNsa, isFalse);
      expect(sim.modeLabel, '5G SA');
    });

    test('no NR at all resolves to LTE', () {
      final snapshot = CellSnapshot.fromMap({
        'sims': [
          {
            'slotIndex': 0,
            'isDefault': true,
            'simState': 'READY',
            'cells': [_cell(type: 'LTE', registered: true, dbm: -95)],
          },
        ],
      });

      final sim = snapshot.activeSims.single;
      expect(sim.mode, NetworkMode.lte);
      expect(sim.modeLabel, '4G LTE');
    });
  });

  group('SignalQuality', () {
    test('follows the 5 / 4 / 3 / 2 / 1 / 0 dBm bands', () {
      expect(SignalQuality.barsFor(dbm: -50), 5);
      expect(SignalQuality.barsFor(dbm: -84), 5);
      expect(SignalQuality.barsFor(dbm: -85), 4);
      expect(SignalQuality.barsFor(dbm: -94), 4);
      expect(SignalQuality.barsFor(dbm: -95), 3);
      expect(SignalQuality.barsFor(dbm: -104), 3);
      expect(SignalQuality.barsFor(dbm: -105), 2);
      expect(SignalQuality.barsFor(dbm: -114), 2);
      expect(SignalQuality.barsFor(dbm: -115), 1);
      expect(SignalQuality.barsFor(dbm: -124), 1);
      expect(SignalQuality.barsFor(dbm: -125), 0);
      expect(SignalQuality.barsFor(dbm: -140), 0);
    });

    test('a satellite PLMN counts its bars 20 dB higher', () {
      // The threshold table the satellites use, expressed as the boost the
      // operator list carries: the level is raised before it is counted.
      SignalQuality.setBoosts({'310-830': 20});
      addTearDown(() => SignalQuality.setBoosts(const {}));

      const satellite = '310-830';
      expect(SignalQuality.boostFor(satellite), 20);
      expect(SignalQuality.boostFor('310-260'), 0);
      expect(SignalQuality.boostFor(null), 0);

      int bars(int dbm) =>
          SignalQuality.barsFor(dbm: dbm, boostDbm: SignalQuality.boostFor(satellite));

      expect(bars(-100), 5); // above -104
      expect(bars(-104), 5);
      expect(bars(-105), 4); // -114 .. -105
      expect(bars(-114), 4);
      expect(bars(-115), 3); // -124 .. -115
      expect(bars(-124), 3);
      expect(bars(-125), 2); // -134 .. -125
      expect(bars(-134), 2);
      expect(bars(-135), 1); // -144 .. -135
      expect(bars(-144), 1);
      expect(bars(-145), 0);
    });

    test('the SpaceX satellite PLMNs are boosted with no list at all', () {
      SignalQuality.setBoosts(const {});

      // T-Satellite and T-911 are direct-to-cell satellite networks, so their
      // bars are on the satellite scale even before the list is fetched.
      expect(SignalQuality.isSatellite('310-830'), isTrue);
      expect(SignalQuality.isSatellite('312-190'), isTrue);
      expect(SignalQuality.isSatellite('310-410'), isFalse);
      expect(SignalQuality.isSatellite(null), isFalse);

      CellTower cell(String mnc, int dbm) => CellTower.fromMap(
            _cell(type: 'LTE', registered: true, dbm: dbm, mcc: '312', mnc: mnc),
          );

      // -123 dBm is 3 bars on the satellite scale (-124 .. -115), not the
      // single bar it counts as on the terrestrial one.
      expect(cell('190', -123).bars, 3);
      expect(cell('190', -140).bars, 1);
      // The same level on a terrestrial network is still counted as it was.
      expect(cell('410', -123).bars, 1);
      expect(cell('410', -140).bars, 0);
    });

    test('a boost alone lifts the bars without claiming a satellite link', () {
      // Ameren's private LTE is terrestrial; it asks for a higher bar scale but
      // must keep the LTE badge, not turn into SAT.
      SignalQuality.setBoosts({'313-700': 15});
      addTearDown(() {
        SignalQuality.setBoosts(const {});
        SignalQuality.setSatellites(const {});
      });

      expect(SignalQuality.boostFor('313-700'), 15);
      expect(SignalQuality.isSatellite('313-700'), isFalse);

      final sim = CellSnapshot.fromMap({
        'sims': [
          {
            'slotIndex': 0,
            'carrierName': 'Ameren',
            'isDefault': true,
            'simState': 'READY',
            'cells': [
              _cell(type: 'LTE', registered: true, dbm: -102, mcc: '313', mnc: '700'),
            ],
          },
        ],
      }).activeSims.single;

      expect(sim.isSatellite, isFalse);
      // -102 + 15 = -87: four bars, from a level that counts as three.
      expect(sim.serving!.bars, 4);
      expect(SignalQuality.barsFor(dbm: -102), 3);
    });

    test('only the satellite flag marks a link SAT, not the offset', () {
      SignalQuality.setSatellites({'310-830'});
      addTearDown(() => SignalQuality.setSatellites(const {}));

      expect(SignalQuality.isSatellite('310-830'), isTrue);
      expect(SignalQuality.isSatellite('313-700'), isFalse);
      expect(SignalQuality.isSatellite(null), isFalse);
    });

    test('an entry in the list overrides the satellite default', () {
      SignalQuality.setBoosts({'310-830': 24});
      addTearDown(() => SignalQuality.setBoosts(const {}));

      expect(SignalQuality.boostFor('310-830'), 24);
      // The other satellite PLMN keeps falling back to the default.
      expect(SignalQuality.boostFor('312-190'), 20);
    });

    test('the boost only reaches the bars of that PLMN', () {
      SignalQuality.setBoosts({'310-830': 20});
      addTearDown(() => SignalQuality.setBoosts(const {}));

      final satellite = CellTower.fromMap(
        _cell(type: 'LTE', registered: true, dbm: -140, mcc: '310', mnc: '830'),
      );
      final terrestrial = CellTower.fromMap(
        _cell(type: 'LTE', registered: true, dbm: -140, mcc: '310', mnc: '410'),
      );

      expect(satellite.bars, 1);
      expect(terrestrial.bars, 0);
      // The readout keeps the figure the modem reported.
      expect(satellite.dbm, -140);
    });

    test('falls back to the platform level when dBm is missing', () {
      expect(SignalQuality.barsFor(level: 2), 3);
      expect(SignalQuality.barsFor(level: 4), 5);
      expect(SignalQuality.barsFor(), 0);
      expect(SignalQuality.label(0), 'No signal');
      expect(SignalQuality.distanceFromTimingAdvance(10), '~780 m');
    });
  });

  group('problems', () {
    test('reports a missing SIM per slot', () {
      final snapshot = CellSnapshot.fromMap({
        'sims': [
          {'slotIndex': 1, 'simState': 'ABSENT', 'cells': []},
        ],
      });
      final sim = snapshot.sims.single;
      expect(sim.hasSim, isFalse);
      expect(sim.problem(locationEnabled: true), contains('No SIM card'));
    });

    test('explains location being off', () {
      final snapshot = CellSnapshot.fromMap(
        {..._dualSimPayload(), 'locationEnabled': false},
      );
      expect(
        snapshot.activeSims.first.problem(locationEnabled: false),
        contains('Location services are off'),
      );
    });
  });

  test('tolerates a payload with no sims key', () {
    final snapshot = CellSnapshot.fromMap({});
    expect(snapshot.sims, isEmpty);
    expect(snapshot.cellCount, 0);
    expect(snapshot.hasSim, isFalse);
  });

  group('SimHeaderCard', () {
    Future<void> pumpCard(
      WidgetTester tester,
      SimReading sim, {
      bool dual = true,
    }) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SimHeaderCard(
              sim: sim,
              dual: dual,
              capturedAt: DateTime(2026, 1, 2, 3, 4, 5),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('NSA renders one meter for LTE and one for NR', (tester) async {
      await pumpCard(tester, CellSnapshot.fromMap(_dualSimPayload()).activeSims.first);

      expect(find.text('LTE ANCHOR'), findsOneWidget);
      expect(find.text('5G NR'), findsOneWidget);
      expect(find.text('5G NSA'), findsOneWidget);
      // Two independent bar meters, one per leg.
      expect(find.byType(SignalBars), findsNWidgets(2));
      expect(find.text('-102'), findsOneWidget);
      expect(find.text('-92'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'no overflow at 360dp');
    });

    testWidgets('shows the carrier name resolved from the PLMN', (tester) async {
      final sim =
          CellSnapshot.fromMap(_dualSimPayload()).activeSims.first;
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SimHeaderCard(
              sim: sim,
              dual: true,
              capturedAt: DateTime(2026, 1, 2, 3, 4, 5),
              carrierName: 'AT&T',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The resolved brand replaces the SIM's own name (T-Mobile in the fixture).
      expect(find.text('AT&T'), findsOneWidget);
      expect(find.text('T-Mobile'), findsNothing);
    });

    testWidgets('the technology sits right of the name, outside a chip',
        (tester) async {
      await pumpCard(
        tester,
        CellSnapshot.fromMap(_dualSimPayload()).activeSims.first,
      );

      // NSA pair: a 5G badge beside the name, the mode chip on the far right.
      expect(find.text('5G'), findsOneWidget);
      expect(find.text('5G NSA'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('5G')).dx,
        greaterThan(tester.getTopLeft(find.text('T-Mobile')).dx),
        reason: 'the technology reads after the carrier name',
      );
      // Plain text, not a box: the mode chip is the only chip in the header.
      expect(
        find.descendant(
          of: find.byType(TechBadge),
          matching: find.byType(Container),
        ),
        findsNothing,
      );
    });

    testWidgets('a satellite slot shows SAT instead of the technology',
        (tester) async {
      final sim = CellSnapshot.fromMap({
        'sims': [
          {
            'slotIndex': 0,
            'carrierName': 'T-Satellite',
            'isDefault': true,
            'simState': 'READY',
            'cells': [
              _cell(
                type: 'LTE',
                registered: true,
                dbm: -140,
                mcc: '310',
                mnc: '830',
              ),
            ],
          },
        ],
      }).activeSims.single;

      await pumpCard(tester, sim, dual: false);

      expect(find.text('SAT'), findsOneWidget);
      // Never both: the technology label is replaced, not prefixed.
      expect(find.text('LTE'), findsNothing);
      expect(find.byType(TechBadge), findsNothing);
      expect(
        tester.getTopLeft(find.text('SAT')).dx,
        greaterThan(tester.getTopLeft(find.text('T-Satellite')).dx),
      );
      // -140 dBm is one bar on the satellite scale, not none.
      expect(find.text('Very weak'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'no overflow at 360dp');
    });

    testWidgets('SA uses the single NR meter', (tester) async {
      final sim = CellSnapshot.fromMap({
        'sims': [
          {
            'slotIndex': 0,
            'carrierName': 'Standalone',
            'isDefault': true,
            'simState': 'READY',
            'cells': [
              _cell(type: 'NR', registered: true, cellId: '99', dbm: -88, level: 3),
            ],
          },
        ],
      }).activeSims.single;

      await pumpCard(tester, sim, dual: false);

      expect(find.text('5G SA'), findsOneWidget);
      expect(find.text('LTE ANCHOR'), findsNothing);
      expect(find.byType(SignalBars), findsOneWidget);
      expect(find.text('-88'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a SpaceX satellite cell draws the satellite bars', (
      tester,
    ) async {
      SimReading sim(String mnc) => CellSnapshot.fromMap({
            'sims': [
              {
                'slotIndex': 0,
                'carrierName': 'T-911',
                'isDefault': true,
                'simState': 'READY',
                'cells': [
                  _cell(
                    type: 'LTE',
                    registered: true,
                    dbm: -123,
                    mcc: '312',
                    mnc: mnc,
                  ),
                ],
              },
            ],
          }).activeSims.single;

      SignalQuality.setBoosts(const {});
      await pumpCard(tester, sim('190'), dual: false);

      // -123 dBm is 3 bars on the satellite scale and 1 on the terrestrial one.
      expect(
        tester.widget<SignalBars>(find.byType(SignalBars)).bars,
        3,
        reason: 'T-911 counts on the satellite scale',
      );
      // The readout still shows what the modem reported.
      expect(find.text('-123'), findsOneWidget);

      await pumpCard(tester, sim('410'), dual: false);
      expect(tester.widget<SignalBars>(find.byType(SignalBars)).bars, 1);
    });
  });

  testWidgets('SignalBars fills the requested number of bars', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SignalBars(bars: 3, height: 60)),
      ),
    );

    final containers = tester
        .widgetList<AnimatedContainer>(find.byType(AnimatedContainer))
        .toList();
    expect(containers, hasLength(5));

    final colours = containers
        .map((c) => (c.decoration! as BoxDecoration).color)
        .toList();
    expect(colours.take(3), everyElement(AppColors.forBars(3)));
    expect(colours.skip(3), everyElement(AppColors.track));
  });

  group('the whole 3GPP band table', () {
    CellTower cell({
      required String type,
      int? arfcn,
      List<int> bands = const [],
      String mcc = '310',
      String mnc = '260',
    }) =>
        CellTower.fromMap({
          'type': type,
          'registered': true,
          'arfcn': arfcn,
          'bands': bands,
          'mcc': mcc,
          'mnc': mnc,
        });

    test('prices LTE bands that were not in the old hand-written table', () {
      // Band 42: TDD 3400-3600 MHz, EARFCN 41590-43589.
      final b42 = cell(type: 'LTE', arfcn: 42590, bands: const [42]);
      expect(b42.downlinkLabel, '3500.00 MHz');
      expect(b42.uplinkLabel, '3500.00 MHz');
      expect(b42.isTdd, isTrue);

      // Band 24 pairs an uplink *above* its downlink (1626.5-1660.5).
      final b24 = cell(type: 'LTE', arfcn: 7900, bands: const [24]);
      expect(b24.downlinkLabel, '1545.00 MHz');
      expect(b24.uplinkLabel, '1646.50 MHz');
    });

    test('clamps an uplink to its own block on the asymmetric bands', () {
      // Band 66 carries 90 MHz down but only 70 MHz up, so the top of the
      // band has no paired uplink frequency above 1780.
      final top = cell(type: 'LTE', arfcn: 67335, bands: const [66]);
      expect(top.downlinkLabel, '2199.90 MHz');
      expect(top.uplinkLabel, '1780.00 MHz');

      final low = cell(type: 'LTE', arfcn: 66436, bands: const [66]);
      expect(low.downlinkLabel, '2110.00 MHz');
      expect(low.uplinkLabel, '1710.00 MHz');

      final nr66 = cell(type: 'NR', arfcn: 438000, bands: const [66]);
      expect(nr66.downlinkLabel, '2190.00 MHz');
      expect(nr66.uplinkLabel, '1780.00 MHz');
    });

    test('names an NR band from a channel none of the old bands claimed', () {
      // n40 is 2300-2400 MHz (ARFCN 460000-480000); 2380 MHz is above n30's
      // 2360 stop, so n40 is the only band that claims it.
      final n40 = cell(type: 'NR', arfcn: 476000);
      expect(n40.bandInferred, isTrue);
      expect(n40.bandLabel, 'n40');
      expect(n40.downlinkLabel, '2380.00 MHz');
      expect(n40.uplinkLabel, '2380.00 MHz');
    });

    test('still refuses to choose between bands that share a window', () {
      // n77 (3300-4200) and n78 (3300-3800) both contain 3500 MHz, and n96
      // and n102 both contain 6000 — a channel alone cannot pick one.
      expect(cell(type: 'NR', arfcn: 640000).bandLabel, isNull);
      expect(cell(type: 'NR', arfcn: 800000).bandLabel, isNull);
      // n5 and n26 overlap too, and both were always in the table.
      expect(cell(type: 'NR', arfcn: 176300).bandLabel, isNull);
    });

    test('reads band 106 on its own 3GPP raster as well as the A10e one', () {
      // 3GPP numbers band 106 at EARFCN 70656-70705: 70686 is 938.00 MHz.
      final standard = cell(
        type: 'LTE',
        arfcn: 70686,
        bands: const [106],
        mcc: '313',
        mnc: '700',
      );
      expect(standard.downlinkLabel, '938.00 MHz');
      expect(standard.uplinkLabel, '899.00 MHz');

      BandFilters.anterixB106 = true;
      addTearDown(BandFilters.reset);
      // With the alias on, the same reading still prices the same carrier.
      expect(standard.downlinkLabel, '938.00 MHz');
      expect(standard.uplinkLabel, '899.00 MHz');
      expect(standard.displayedArfcn, 70686);
    });
  });
}
