import 'dart:convert';
import 'dart:io';

import 'package:cell_tower_monitor/desktop/desktop_config.dart';
import 'package:cell_tower_monitor/desktop/scenario.dart';
import 'package:cell_tower_monitor/desktop/test_source.dart';
import 'package:cell_tower_monitor/models/band_tables.dart';
import 'package:cell_tower_monitor/models/cell_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

CellSnapshot _read(Scenario scenario) => CellSnapshot.fromMap(
      jsonDecode(jsonEncode(scenario.payload())) as Map<Object?, Object?>,
    );

void main() {
  group('test-source presets', () {
    test('T-Mobile n41 parses as one SA NR cell on the channel we sent', () {
      final snapshot = _read(Scenario.byId('tmo-n41')!);
      final sim = snapshot.sims.single;
      final cell = sim.nrServing!;

      expect(sim.overrideNetworkType, 'NR_SA');
      expect(cell.tech, CellTech.nr);
      expect(cell.arfcn, 519000);
      expect(cell.bands, contains(38));
      expect(cell.plmn, '310-260');
      // 519000 on the NR raster is 2595 MHz, inside n41.
      expect(cell.frequencyMhz, closeTo(2595, 0.01));
      expect(cell.gnb, 1053255);
      expect(cell.sector, 312);
    });

    test('a channel with no band still names n71', () {
      final snapshot = _read(Scenario.byId('tmo-n71')!);
      final cell = snapshot.sims.single.nrServing!;

      expect(cell.bands, isEmpty);
      expect(cell.arfcn, 126270);
      expect(cell.bandLabel, 'n71');
      expect(cell.frequencyMhz, closeTo(631.35, 0.01));
    });

    test('the AT&T anchor and its leg read as NSA, with no NCI on the leg', () {
      final snapshot = _read(Scenario.byId('att-nsa')!);
      final sim = snapshot.sims.single;

      expect(sim.lteServing, isNotNull);
      expect(sim.nrServing, isNotNull);
      expect(sim.nrServing!.cellId, isNull);
      // eNB 245029 is the pair the app's AT&T offset was measured from.
      expect(sim.lteServing!.enb, 245029);
      expect(sim.nsaGnbEstimate, 12295029);
    });

    test('Anterix is served on the band 8 raster the modem reports', () {
      final cell = _read(Scenario.byId('anterix-b106')!).sims.single.lteServing!;

      expect(cell.tech, CellTech.lte);
      expect(cell.bands, contains(8));
      expect(cell.arfcn, 3580);
      expect(cell.plmn, '313-700');
      expect(cell.enb, 12345);
      expect(cell.sector, 7);
    });

    test('the dual-SIM preset carries two SIMs with their own cells', () {
      final snapshot = _read(Scenario.byId('dual-sim')!);

      expect(snapshot.sims, hasLength(2));
      expect(snapshot.sims[0].lteServing!.plmn, '310-260');
      expect(snapshot.sims[1].lteServing!.plmn, '311-480');
      expect(snapshot.sims[1].slotIndex, 1);
    });
  });

  group('the custom source', () {
    test('keeps the band, channel and level it is given', () {
      final sim = _read(
        const CustomSource(
          carrierName: 'TestNet',
          mcc: '001',
          mnc: '01',
          override: 'NONE',
          lte: CustomCarrier(
            band: 41,
            arfcn: 40490,
            dbm: -77,
            site: 30722,
            sector: 36,
            pci: 76,
            tac: 12345,
          ),
          nr: [],
        ).build(),
      ).sims.single;
      final cell = sim.lteServing!;

      expect(cell.bands, contains(41));
      expect(cell.arfcn, 40490);
      expect(cell.plmn, '001-01');
      expect(cell.dbm, inInclusiveRange(-79, -75));
    });

    test('an NSA leg is sent without an NCI, so only the estimate names it', () {
      // The estimate is the app's own AT&T/Dish offset, so it needs the PLMN
      // that mapping belongs to; the page's default network is AT&T.
      final sim = _read(const CustomSource().build()).sims.single;

      expect(sim.overrideNetworkType, 'NR_NSA');
      expect(sim.lteServing!.bands, contains(30));
      expect(sim.nrServing, isNotNull);
      expect(sim.nrServing!.cellId, isNull);
      expect(sim.nsaGnbEstimate, 12080722);
    });

    test('a custom NSA leg on another carrier carries no gNB at all', () {
      final sim = _read(
        const CustomSource(mcc: '310', mnc: '260').build(),
      ).sims.single;

      expect(sim.nrServing!.cellId, isNull);
      expect(sim.nsaGnbEstimate, isNull);
    });

    test('an SA source sends the NR carrier alone, with its NCI', () {
      final sim = _read(
        const CustomSource(
          override: 'NR_SA',
          nr: [
            CustomCarrier(
              band: 41,
              arfcn: 519000,
              dbm: -88,
              site: 1053255,
              sector: 312,
              pci: 42,
              tac: 12345,
            ),
          ],
        ).build(),
      ).sims.single;

      expect(sim.lteServing, isNull);
      expect(sim.nrServing!.arfcn, 519000);
      expect(sim.nrServing!.cellId, isNotNull);
      expect(sim.nrServing!.gnb, 1053255);
    });

    test('switching the NR leg off drops the override with it', () {
      const source = CustomSource(override: 'NR_NSA', nr: []);

      expect(source.wireOverride, 'NONE');
      expect(source.summary, 'B30 anchor');
      expect(_read(source.build()).sims.single.nrServing, isNull);
    });

    test('a B29 layer is aggregated as a supplemental downlink', () {
      final sim = _read(
        const CustomSource(
          override: 'LTE_CA',
          lte: CustomCarrier(
            band: 2,
            arfcn: 700,
            dbm: -95,
            site: 245029,
            sector: 36,
            pci: 61,
            tac: 25601,
          ),
          lteLayers: [CustomCarrier(band: 29, arfcn: 9660, dbm: -110, pci: 200)],
          nr: [],
        ).build(),
      ).sims.single;

      expect(sim.cells, hasLength(2));
      final layer = sim.cells[1];
      // No identity and no PLMN: that is how a modem hands over an SDL.
      expect(layer.registered, isFalse);
      expect(layer.cellId, isNull);
      expect(layer.mcc, isNull);
      expect(layer.isBand29, isTrue);
      expect(sim.lteSecondaries, hasLength(1));
      expect(sim.lteAggregated, isTrue);
    });

    test('a lone millimetre-wave carrier is not sent at all', () {
      const source = CustomSource(
        override: 'NR_SA',
        lte: CustomCarrier(enabled: false, band: 30),
        nr: [CustomCarrier(band: 260, arfcn: 2079167, pci: 5)],
      );

      expect(source.servedNr, isEmpty);
      expect(source.summary, 'n260 (mmWave, not sent)');
      expect(_read(source.build()).sims.single.cells, isEmpty);
    });

    test('two NR carriers are served together under SA', () {
      const source = CustomSource(
        override: 'NR_SA',
        nr: [
          CustomCarrier(
            band: 41,
            arfcn: 519000,
            site: 1053255,
            sector: 312,
            pci: 42,
            tac: 12345,
          ),
          CustomCarrier(
            band: 77,
            arfcn: 650000,
            site: 1053255,
            sector: 313,
            pci: 43,
            tac: 12345,
          ),
        ],
      );
      final sim = _read(source.build()).sims.single;

      expect(source.summary, 'n41 + n77');
      expect(sim.cells, hasLength(2));
      expect(sim.cells.every((cell) => cell.cellId != null), isTrue);
      expect(sim.overrideNetworkType, 'NR_SA');
    });

    test('neighbours are served with a PCI and a band, and nothing else', () {
      const source = CustomSource(
        neighbours: CustomNeighbours(count: 3, band: 2),
      );
      final sim = _read(source.build()).sims.single;

      expect(source.summary, 'B30 anchor + n5 + 3 neighbours');
      expect(sim.neighbours, hasLength(3));
      for (final cell in sim.neighbours) {
        expect(cell.registered, isFalse);
        expect(cell.cellId, isNull);
        expect(cell.mcc, isNull);
        expect(cell.tac, isNull);
        expect(cell.bands, contains(2));
      }
      // Each one a different site, stair-stepped down from the anchor.
      expect(sim.neighbours.map((cell) => cell.pci).toSet(), hasLength(3));
    });

    test('NSA carries one NR leg, SA aggregates up to five', () {
      const legs = [
        CustomCarrier(band: 5, arfcn: 176300, site: 1053255, sector: 1),
        CustomCarrier(band: 41, arfcn: 519000, site: 1053255, sector: 2),
      ];
      const nsa = CustomSource(override: 'NR_NSA', nr: legs);
      const sa = CustomSource(override: 'NR_SA', nr: legs);

      expect(nsa.maxNr, 1);
      expect(nsa.servedNr, hasLength(1));
      expect(sa.maxNr, 5);
      expect(sa.servedNr, hasLength(2));
      expect(_read(sa.build()).sims.single.cells, hasLength(2));
    });

    test('the advanced flavours are one wire value split by the anchor', () {
      const anchored = CustomSource(override: 'NR_ADVANCED');
      const standalone = CustomSource(
        override: 'NR_ADVANCED',
        lte: CustomCarrier(enabled: false, band: 30),
      );
      final pair = _read(anchored.build()).sims.single;
      final alone = _read(standalone.build()).sims.single;

      expect(anchored.wireOverride, 'NR_ADVANCED');
      expect(pair.nrServing!.cellId, isNull);
      expect(pair.nsaGnbEstimate, isNotNull);
      expect(standalone.wireOverride, 'NR_ADVANCED');
      expect(alone.lteServing, isNull);
      expect(alone.nrServing!.cellId, isNotNull);
    });

    test('a PCI outside what a radio can report is clamped', () {
      final lte = _read(
        const CustomSource(
          override: 'NONE',
          lte: CustomCarrier(band: 2, arfcn: 700, pci: 900),
          nr: [],
        ).build(),
      ).sims.single.lteServing!;
      final nr = _read(
        const CustomSource(
          override: 'NR_SA',
          lte: CustomCarrier(enabled: false, band: 30),
          nr: [CustomCarrier(band: 41, arfcn: 519000, pci: 1200)],
        ).build(),
      ).sims.single.nrServing!;

      expect(lte.pci, 503);
      expect(nr.pci, 1007);
    });

    test('a blank identity still serves a valid cell', () {
      final lte = _read(
        const CustomSource(
          override: 'NONE',
          lte: CustomCarrier(band: 2, arfcn: 700),
          nr: [],
        ).build(),
      ).sims.single.lteServing!;
      final nr = _read(
        const CustomSource(
          override: 'NR_SA',
          lte: CustomCarrier(enabled: false, band: 30),
          nr: [CustomCarrier(band: 41, arfcn: 519000)],
        ).build(),
      ).sims.single.nrServing!;

      expect(lte.cellId, '7864964');
      expect(lte.enb, 30722);
      expect(nr.cellId, '12590807089');
    });

    test('the level follows the level being served', () {
      final cell = _read(
        const CustomSource(
          override: 'NONE',
          lte: CustomCarrier(band: 2, arfcn: 700, dbm: -104),
          nr: [],
        ).build(),
      ).sims.single.lteServing!;

      // -104 dBm sits low on the platform's own 0-4 scale.
      expect(cell.level, inInclusiveRange(1, 2));
    });

    test('a frequency and its channel convert both ways', () {
      expect(lteMhz(9820, 30), closeTo(2355, 1));
      expect(lteEarfcn(lteMhz(9820, 30), 30), 9820);
      expect(nrArfcn(channelMhz(true, 5, 176300)), 176300);
      expect(channelOf(false, 30, null), isNull);
    });

    test('the editor starts on the middle of a band it knows', () {
      final channel = defaultChannel(41, false)!;

      expect(channel, inInclusiveRange(lteBandPlans[41]!.first, lteBandPlans[41]!.last));
      expect(defaultChannel(9999, false), isNull);
    });

    test('reads the console own saved file, and writes it back the same', () {
      final raw = <String, Object?>{
        'plmn': '310410',
        'override': 'NR_NSA',
        'lte': {
          'band': 2,
          'arfcn': 700,
          'dbm': -95,
          'enb': 245029,
          'sector': 36,
          'pci': 61,
          'tac': 25601,
          'enabled': true,
        },
        'lte_layers': [
          {'band': 29, 'arfcn': 9660, 'dbm': -110, 'pci': 200, 'enabled': true},
        ],
        'nr': [
          {'band': 5, 'arfcn': 173800, 'dbm': -102, 'pci': 220, 'enabled': true},
        ],
        'neighbours': {'count': 4, 'band': 2, 'enabled': true},
      };

      final source = CustomSource.fromJson(raw);

      expect(source.mcc, '310');
      expect(source.mnc, '410');
      expect(source.lte!.site, 245029);
      expect(source.lteLayers.single.band, 29);
      expect(source.nr.single.arfcn, 173800);
      expect(source.neighbours.count, 4);
      expect(source.summary, 'B2 anchor + B29 SDL + n5 + 4 neighbours');

      final reloaded = CustomSource.fromJson(
        jsonDecode(jsonEncode(source.toJson())) as Map<Object?, Object?>,
      );
      expect(reloaded.summary, source.summary);
      expect(reloaded.lte!.pci, 61);
      expect(reloaded.neighbours.band, 2);
    });
  });

  group('the desktop config', () {
    test('remembers the watched phones and the whole custom source', () async {
      final directory = await Directory.systemTemp.createTemp('sector-scout-config');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}${Platform.pathSeparator}desktop.json');

      final saved = DesktopConfig(
        phones: ['10.1.1.47:41729'],
        scenarioId: 'custom',
        corrections: false,
        custom: const CustomSource(
          mcc: '001',
          mnc: '01',
          override: 'LTE_CA',
          lte: CustomCarrier(band: 41, arfcn: 40490, dbm: -77, site: 30722),
          lteLayers: [CustomCarrier(band: 29, arfcn: 9660, pci: 200)],
          nr: [],
          neighbours: CustomNeighbours(count: 2, band: 4),
        ),
      );
      await saved.save(file);

      final loaded = DesktopConfig.load(file);
      expect(loaded.phones, ['10.1.1.47:41729']);
      expect(loaded.scenarioId, 'custom');
      expect(loaded.custom.mcc, '001');
      expect(loaded.custom.lte!.band, 41);
      expect(loaded.custom.lte!.dbm, -77);
      expect(loaded.custom.lteLayers.single.band, 29);
      expect(loaded.custom.neighbours.count, 2);
      expect(loaded.custom.override, 'LTE_CA');
      expect(loaded.corrections, isFalse);
    });

    test('reads the phone objects and scenario name the console wrote', () async {
      final directory = await Directory.systemTemp.createTemp('sector-scout-console');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}${Platform.pathSeparator}desktop.json');

      await file.writeAsString(jsonEncode({
        'port': 41729,
        'scenario': 'T-Mobile n41 SA',
        'corrections': false,
        'phones': [
          {
            'url': 'http://10.1.1.47:41729',
            'name': 'samsung SM-S931U',
            'transport': 'wifi',
            'address': '',
          },
        ],
      }));

      final loaded = DesktopConfig.load(file);
      expect(loaded.phones, ['http://10.1.1.47:41729']);
      expect(loaded.corrections, isFalse);
      // A name this build does not know is kept, and matched to its preset.
      expect(loaded.scenarioId, 'T-Mobile n41 SA');
    });
  });

  group('test source', () {
    test('serves a snapshot a phone client can read, and /health', () async {
      final source = DesktopTestSource(
        scenario: Scenario.byId('att-nsa'),
        preferredPort: 0,
      );
      addTearDown(source.stop);

      expect(await source.start(), isNull, reason: 'should bind an ephemeral port');

      final client = HttpClient();
      addTearDown(client.close);

      final snapshotRequest =
          await client.getUrl(Uri.parse('http://127.0.0.1:${source.port}/snapshot'));
      final snapshotResponse = await snapshotRequest.close();
      expect(snapshotResponse.statusCode, 200);
      final body = await snapshotResponse.transform(utf8.decoder).join();
      final parsed = CellSnapshot.fromMap(
        jsonDecode(body) as Map<Object?, Object?>,
      );
      expect(parsed.deviceModel, contains('test source'));
      expect(parsed.sims.single.nrServing, isNotNull);

      final healthRequest =
          await client.getUrl(Uri.parse('http://127.0.0.1:${source.port}/health'));
      final healthResponse = await healthRequest.close();
      expect(healthResponse.statusCode, 200);
      final health = jsonDecode(
        await healthResponse.transform(utf8.decoder).join(),
      ) as Map<Object?, Object?>;
      expect(health['ok'], isTrue);
      expect(health['port'], source.port);
    });
  });
}
