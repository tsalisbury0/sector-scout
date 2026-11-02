import 'dart:convert';
import 'dart:io';

import 'package:cell_tower_monitor/models/cell_snapshot.dart';
import 'package:cell_tower_monitor/services/lan_server.dart';
import 'package:flutter_test/flutter_test.dart';

CellSnapshot _snapshot() => CellSnapshot.fromMap({
      'permissionGranted': true,
      'locationEnabled': true,
      'timestamp': 1730000000000,
      'deviceModel': 'test phone',
      'sims': [
        {
          'slotIndex': 0,
          'subscriptionId': 1,
          'carrierName': 'Test Mobile',
          'isDefault': true,
          'simState': 'READY',
          'networkTypeName': 'LTE',
          'cells': [
            {
              'type': 'LTE',
              'registered': true,
              'cellId': '6879550',
              'pci': 76,
              'dbm': -99,
              'bands': [71],
              'arfcn': 68611,
              'mcc': '310',
              'mnc': '410',
            },
          ],
        },
      ],
    });

Future<String> _get(int port, String path) async {
  final client = HttpClient();
  try {
    final request = await client.get('127.0.0.1', port, path);
    final response = await request.close();
    expect(response.statusCode, 200, reason: path);
    return await response.transform(utf8.decoder).join();
  } finally {
    client.close(force: true);
  }
}

void main() {
  group('LAN sharing', () {
    late LanSharingServer server;

    setUp(() {
      // An ephemeral port: the suite starts and stops this server many times,
      // and Windows will not hand back one fixed port that quickly. The fixed
      // port itself is pinned by its own test below.
      server = LanSharingServer(port: 0);
    });

    tearDown(() async {
      await server.stop();
    });

    test('serves the native payload as JSON', () async {
      await server.start(snapshot: _snapshot());

      final body = await _get(server.port!, '/snapshot');
      final json = jsonDecode(body) as Map<String, Object?>;

      expect(json['deviceModel'], 'test phone');
      final sims = json['sims'] as List<Object?>;
      expect(sims, hasLength(1));
      final sim = sims.single as Map<Object?, Object?>;
      expect(sim['carrierName'], 'Test Mobile');
      // The exact shape the app itself parses: a second phone can render it.
      final cell = (sim['cells'] as List<Object?>).single as Map<Object?, Object?>;
      expect(cell['cellId'], '6879550');
      expect(cell['bands'], [71]);
    });

    test('serves a dashboard and a health check', () async {
      await server.start(snapshot: _snapshot());

      final html = await _get(server.port!, '/');
      expect(html, contains('Sector Scout'));
      // The page polls the rendered live region, which the server builds from
      // the same model the app's cards read.
      expect(html, contains('/view'));

      // The live region carries the app's own row labels, not a second
      // rendering of the payload.
      final view = await _get(server.port!, '/view');
      expect(view, contains('eNB (dec)'));
      expect(view, contains('Radio quality'));
      expect(view, isNot(contains('<html')));

      final health = jsonDecode(await _get(server.port!, '/health'));
      expect((health as Map<String, Object?>)['ok'], isTrue);
    });

    test('API-only mode serves JSON at the root and never HTML', () async {
      server.serveDashboard = false;
      await server.start(snapshot: _snapshot());

      final root = await _get(server.port!, '/');
      expect(root.trimLeft(), startsWith('{'));
      final json = jsonDecode(root) as Map<String, Object?>;
      expect(json['deviceModel'], 'test phone');

      final index = await _get(server.port!, '/index.html');
      expect(index.trimLeft(), startsWith('{'));
      expect(index.contains('<html'), isFalse);

      // The snapshot endpoint is unchanged by the mode.
      final snapshot = jsonDecode(await _get(server.port!, '/snapshot'));
      expect((snapshot as Map<String, Object?>)['deviceModel'], 'test phone');

      final health = jsonDecode(await _get(server.port!, '/health'))
          as Map<String, Object?>;
      expect(health['dashboard'], isFalse);
    });

    test('flipping the dashboard back on serves HTML again', () async {
      server.serveDashboard = false;
      await server.start(snapshot: _snapshot());
      expect((await _get(server.port!, '/')).trimLeft(), startsWith('{'));

      server.serveDashboard = true;
      final html = await _get(server.port!, '/');
      expect(html, contains('<html'));
      expect(html, contains('Sector Scout'));
    });

    test('answers before the first reading with 503', () async {
      await server.start();
      final client = HttpClient();
      final request = await client.get('127.0.0.1', server.port!, '/snapshot');
      final response = await request.close();
      expect(response.statusCode, HttpStatus.serviceUnavailable);
      await response.drain<void>();
      client.close(force: true);
    });

    test('stop closes the port', () async {
      await server.start(snapshot: _snapshot());
      final port = server.port!;
      await server.stop();
      expect(server.isRunning, isFalse);
      expect(server.port, isNull);

      final client = HttpClient();
      await expectLater(
        client.get('127.0.0.1', port, '/health').then((r) => r.close()),
        throwsA(isA<SocketException>()),
      );
      client.close(force: true);
    });

    test('binds the one share port and reports a usable URL', () async {
      // The desktop test source uses this same port, and running it next to the
      // suite is a normal setup — so the pin is checked only when the port is
      // actually free on this machine. A skip here means something else holds
      // it, never that the app stopped binding it.
      if (!await _portIsFree(LanSharingServer.sharePort)) {
        markTestSkipped(
          'port 41729 is held by another listener (the desktop source?), so it '
          'cannot be bound here',
        );
        return;
      }
      final pinned = LanSharingServer();
      addTearDown(pinned.stop);
      final uri = await pinned.start(snapshot: _snapshot());
      // Fixed rather than "first free": a network scan has to know which port
      // to knock on, so the app cannot drift onto 8081 from run to run.
      expect(uri.port, LanSharingServer.sharePort);
      expect(uri.host, isNotEmpty);
      expect(uri.toString(), startsWith('http://'));
    });
  });
}

/// Whether [port] can be bound right now, used to keep the pinned-port test
/// honest on a machine that is also running the desktop console.
Future<bool> _portIsFree(int port) async {
  try {
    final probe = await ServerSocket.bind(InternetAddress.anyIPv4, port);
    await probe.close();
    return true;
  } on SocketException {
    return false;
  }
}
