import 'dart:convert';

import 'package:cell_tower_monitor/services/ble_desktop.dart';
import 'package:cell_tower_monitor/services/remote_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// The frames a phone answers with, split the way `BleShare.kt` splits them.
List<List<int>> _frames(String json, int chunkSize) {
  final bytes = utf8.encode(json);
  final total = (bytes.length + chunkSize - 1) ~/ chunkSize;
  return [
    for (var index = 0; index < total; index++)
      [
        index,
        total,
        ...bytes.skip(index * chunkSize).take(chunkSize),
      ],
  ];
}

void main() {
  test('the chunks reassemble into the payload the phone served', () {
    final json = jsonEncode({
      'permissionGranted': true,
      'sims': [
        for (var index = 0; index < 40; index++) {'cellId': '245710'},
      ],
    });
    final reader = BleChunkReader();
    for (final frame in _frames(json, 480)) {
      if (reader.add(frame)) break;
    }

    expect(reader.totalChunks, 2);
    expect(utf8.decode(reader.bytes!), json);
  });

  test('a chunk that arrives twice is a replaced reading, not a payload', () {
    final frames = _frames(jsonEncode({'a': 'x' * 900}), 480);
    final reader = BleChunkReader();
    expect(reader.add(frames[0]), isFalse);

    // The phone rewinds its cursor when the reading it shares changes, so the
    // first chunk coming round again means the rest no longer belongs to it.
    expect(() => reader.add(frames[0]), throwsA(isA<RemoteException>()));
    expect(reader.bytes, isNull);
  });

  test('a share with no reading yet is not a payload', () {
    final reader = BleChunkReader();
    expect(reader.add(const [0, 0]), isFalse);
    expect(reader.complete, isFalse);
    expect(reader.bytes, isNull);
  });
}
