import 'dart:convert';
import 'dart:io';

import 'package:cell_tower_monitor/services/remote_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// The peer payload, exactly as the native bridge builds it.
Map<Object?, Object?> _payload() => {
      'permissionGranted': true,
      'locationEnabled': true,
      'timestamp': 1730000000000,
      'deviceModel': 'samsung SM-S931U',
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
              'level': 3,
              'tac': 45055,
              'bands': [71],
              'arfcn': 68611,
              'mcc': '310',
              'mnc': '410',
            },
          ],
        },
      ],
    };

/// Serves one canned response and records the path it was asked for.
class _Peer {
  late HttpServer _server;
  final List<String> paths = [];

  int get port => _server.port;

  Uri get uri => Uri.parse('http://127.0.0.1:$port');

  Future<void> start({
    int status = 200,
    String body = '',
    String contentType = 'application/json',
  }) async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      paths.add(request.uri.path);
      request.response
        ..statusCode = status
        ..headers.contentType = ContentType.parse(contentType)
        ..write(body);
      await request.response.close();
    });
  }

  Future<void> stop() => _server.close(force: true);
}

void main() {
  group('normalizeRemote', () {
    test('accepts a bare host and adds the default port', () {
      expect(
        normalizeRemote('10.1.1.47').toString(),
        'http://10.1.1.47:8080',
      );
    });

    test('keeps an explicit port and drops any path', () {
      expect(
        normalizeRemote('http://10.1.1.47:8081/snapshot').toString(),
        'http://10.1.1.47:8081',
      );
      expect(
        normalizeRemote(' 10.1.1.47:9000/ ').toString(),
        'http://10.1.1.47:9000',
      );
    });

    test('rejects empty and non-http input', () {
      expect(() => normalizeRemote('   '), throwsA(isA<RemoteException>()));
      expect(
        () => normalizeRemote('ftp://10.1.1.47'),
        throwsA(isA<RemoteException>()),
      );
      expect(() => normalizeRemote('http://'), throwsA(isA<RemoteException>()));
    });
  });

  group('RemoteClient', () {
    late _Peer peer;
    late RemoteClient client;

    setUp(() async {
      peer = _Peer();
      await peer.start(body: jsonEncode(_payload()));
      client = RemoteClient(peer.uri);
    });

    tearDown(() async {
      client.dispose();
      await peer.stop();
    });

    test('reads the peer snapshot through the normal parser', () async {
      final snapshot = await client.fetch();

      expect(peer.paths, ['/snapshot']);
      expect(snapshot.deviceModel, 'samsung SM-S931U');
      expect(snapshot.permissionGranted, isTrue);
      expect(snapshot.activeSims, hasLength(1));

      final sim = snapshot.primary!;
      expect(sim.carrierName, 'Test Mobile');
      expect(sim.serving?.pci, 76);
      // Same bar scale as a local reading.
      expect(sim.serving?.bars, 3);
    });

    test('always asks for /snapshot whatever path the user typed', () async {
      final withPath = RemoteClient(
        normalizeRemote('http://127.0.0.1:${peer.port}/index.html'),
      );
      addTearDown(withPath.dispose);

      await withPath.fetch();
      expect(peer.paths, ['/snapshot']);
    });
  });

  group('RemoteClient errors', () {
    test('explains a peer that has not read a cell yet (503)', () async {
      final peer = _Peer();
      await peer.start(status: 503, body: 'waiting');
      final client = RemoteClient(peer.uri);
      addTearDown(() async {
        client.dispose();
        await peer.stop();
      });

      await expectLater(
        client.fetch(),
        throwsA(
          isA<RemoteException>().having(
            (e) => e.message,
            'message',
            contains('not produced a reading'),
          ),
        ),
      );
    });

    test('rejects a non-JSON answer', () async {
      final peer = _Peer();
      await peer.start(body: '<html>nope</html>', contentType: 'text/html');
      final client = RemoteClient(peer.uri);
      addTearDown(() async {
        client.dispose();
        await peer.stop();
      });

      await expectLater(
        client.fetch(),
        throwsA(
          isA<RemoteException>().having(
            (e) => e.message,
            'message',
            contains('did not return cell-tower JSON'),
          ),
        ),
      );
    });

    test('reports the status code for an unexpected answer', () async {
      final peer = _Peer();
      await peer.start(status: 404, body: '{}');
      final client = RemoteClient(peer.uri);
      addTearDown(() async {
        client.dispose();
        await peer.stop();
      });

      await expectLater(
        client.fetch(),
        throwsA(
          isA<RemoteException>().having(
            (e) => e.message,
            'message',
            contains('HTTP 404'),
          ),
        ),
      );
    });

    test('explains an unreachable address', () async {
      // Bind and immediately close to get a port nothing is listening on.
      final free = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = free.port;
      await free.close();

      final client = RemoteClient(Uri.parse('http://127.0.0.1:$port'));
      addTearDown(client.dispose);

      await expectLater(
        client.fetch(),
        throwsA(
          isA<RemoteException>().having(
            (e) => e.message,
            'message',
            contains('Could not reach 127.0.0.1'),
          ),
        ),
      );
    });
  });
}
