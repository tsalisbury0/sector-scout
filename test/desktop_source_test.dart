import 'dart:convert';
import 'dart:io';

import 'package:cell_tower_monitor/desktop/scenario.dart';
import 'package:cell_tower_monitor/desktop/test_source.dart';
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

    test('a custom scenario keeps the band and level it is given', () {
      final scenario = Scenario.custom(
        carrierName: 'TestNet',
        mcc: '001',
        mnc: '01',
        band: 41,
        arfcn: 40490,
        dbm: -77,
      );
      final cell = _read(scenario).sims.single.lteServing!;

      expect(cell.bands, contains(41));
      expect(cell.arfcn, 40490);
      expect(cell.plmn, '001-01');
      expect(cell.dbm, inInclusiveRange(-79, -75));
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
      expect(await healthResponse.transform(utf8.decoder).join(), '{"ok":true}');
    });
  });
}
