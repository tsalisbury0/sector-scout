import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:universal_ble/universal_ble.dart';

import '../models/cell_snapshot.dart';
import 'ble_link.dart';
import 'remote_client.dart';

/// A nearby phone advertising its reading over Bluetooth.
class BleDesktopPeer {
  const BleDesktopPeer({
    required this.address,
    required this.name,
    required this.rssi,
  });

  final String address;
  final String name;

  /// Signal strength in dBm, parsed from the advertisement.
  final int rssi;

  /// What the picker shows: the name, or the address when the peer hides it.
  String get label => name.isEmpty ? address : name;
}

/// Reassembles the chunks the phone answers with.
///
/// Each frame is `[index, total, ...bytes]` and the phone keeps one cursor per
/// client, so the frames of one payload arrive in order. A chunk that arrives
/// twice cannot belong to the same payload — a phone that clears its cursors on
/// every new reading starts the sequence again — and keeping it would splice two
/// readings into JSON nothing can parse.
class BleChunkReader {
  final Map<int, List<int>> _pieces = <int, List<int>>{};
  int _total = 0;

  /// Frames taken so far, how many the phone says the payload has, and how big
  /// the last frame was — the first thing to check when a read keeps failing.
  int get chunkCount => _pieces.length;
  int get totalChunks => _total;
  int lastFrameBytes = 0;

  bool get complete => _total > 0 && _pieces.length >= _total;

  /// Takes one frame, answering true when the whole payload is in hand.
  bool add(List<int> frame) {
    lastFrameBytes = frame.length;
    if (frame.length < 3) return false;
    // Masked because a bridge may hand the frame back as signed bytes, which
    // would turn a chunk count into a negative number.
    final index = frame[0] & 0xFF;
    final total = frame[1] & 0xFF;
    if (total == 0 || index >= total) return false;
    if (_pieces.containsKey(index)) {
      throw const RemoteException('the phone replaced its reading mid-read');
    }
    _total = total;
    _pieces[index] = frame.sublist(2);
    return complete;
  }

  /// The payload, or null while chunks are still missing.
  Uint8List? get bytes {
    if (!complete) return null;
    return Uint8List.fromList([
      for (var index = 0; index < _total; index++) ...?_pieces[index],
    ]);
  }
}

/// The phone's Bluetooth share, read from Windows.
///
/// Windows gets no Bluetooth from the phone's own bridge, so the desktop talks
/// to the GATT server the app advertises through `universal_ble`, whose Windows
/// backend reads with `BluetoothCacheMode::Uncached`. The packager `win_ble`
/// reads through copied this out first: its server called the cache-backed
/// `ReadValueAsync()`, so every read answered the same first chunk no matter
/// what the phone had, and a chunked payload could never be reassembled.
///
/// The UUIDs and the chunked read are `BleShare.kt`'s, so the two ends cannot
/// drift apart: every read answers `[index, total, ...bytes]`, and writing to
/// the reset characteristic rewinds this client to the first chunk.
///
/// Two reads never run at once. The phone holds a single cursor per client and
/// every read rewinds it, so a second read started on top of the first takes
/// that one's chunks: the poll timer is free to tick as often as it likes, and
/// the reads still arrive one at a time.
class BleDesktop {
  BleDesktop._();

  /// Service every sharing phone advertises. Only this app advertises it, so
  /// the watches and beacons around it are not candidates.
  static const String serviceUuid = 'd3a4e1b0-6c2f-4b8a-9f10-5e7c3a2b1d00';

  /// Read repeatedly to receive the payload.
  static const String dataUuid = 'd3a4e1b0-6c2f-4b8a-9f10-5e7c3a2b1d01';

  /// Write anything to rewind this client to the first chunk.
  static const String resetUuid = 'd3a4e1b0-6c2f-4b8a-9f10-5e7c3a2b1d02';

  static const Duration scanWindow = Duration(seconds: 6);
  static const Duration connectTimeout = Duration(seconds: 20);
  static const Duration chunkTimeout = Duration(seconds: 5);

  /// A payload never spans more than 255 chunks, and a read that stopped
  /// halfway must not loop forever.
  static const int readLimit = 400;

  /// How many times one payload may restart under a read before it is called a
  /// failure, and how long one poll may spend on it. A phone that replaces its
  /// reading every couple of seconds sends a pass back to the first chunk, and a
  /// pass only gets through when an attempt lands inside one update window.
  static const int payloadRestarts = 16;
  static const Duration payloadBudget = Duration(seconds: 10);

  /// A read that mixes two payloads is retried, because the next one starts
  /// from a fresh link and a fresh cursor.
  static const int readAttempts = 2;

  /// A link left alone this long is dropped rather than trusted: Android closes
  /// the GATT server when the phone sleeps, and Windows keeps the handle open
  /// as if it had not.
  static const Duration linkIdle = Duration(seconds: 45);

  /// The queue that keeps one read at a time.
  static Future<void> _queue = Future<void>.value();

  static final Set<String> _open = <String>{};
  static final Map<String, DateTime> _usedAt = <String, DateTime>{};

  /// Phones advertising the share, strongest first.
  static Future<List<BleDesktopPeer>> scan() async {
    if (!Platform.isWindows) {
      throw const RemoteException(
        'Bluetooth watching is only available in the Windows build.',
      );
    }

    final found = <String, BleDesktopPeer>{};
    final subscription = UniversalBle.scanStream.listen((device) {
      if (!device.services.contains(serviceUuid)) return;
      found[device.deviceId] = BleDesktopPeer(
        address: device.deviceId,
        name: (device.name ?? '').trim(),
        rssi: device.rssi ?? -999,
      );
    });
    try {
      await UniversalBle.startScan(
        scanFilter: ScanFilter(withServices: const [serviceUuid]),
      );
      await Future<void>.delayed(scanWindow);
    } finally {
      await UniversalBle.stopScan();
      await subscription.cancel();
    }
    return found.values.toList()..sort((a, b) => b.rssi.compareTo(a.rssi));
  }

  /// One phone's reading over GATT — the same JSON `/snapshot` serves.
  static Future<CellSnapshot> read(String address) {
    if (!Platform.isWindows) {
      return Future<CellSnapshot>.error(
        const RemoteException(
          'Bluetooth watching is only available in the Windows build.',
        ),
      );
    }
    final result = _queue.then((_) => _read(address));
    // The queue runs the next read whether this one answered or not.
    _queue = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  static Future<CellSnapshot> _read(String address) async {
    Object? lastError;
    for (var attempt = 0; attempt < readAttempts; attempt++) {
      try {
        await _openLink(address);

        // Rewind this link's cursor: the phone advances it per client, so a
        // read that stopped halfway would otherwise resume mid-payload.
        await UniversalBle.write(
          address,
          serviceUuid,
          resetUuid,
          Uint8List.fromList(const [0]),
          timeout: chunkTimeout,
        );

        final reader = await _payload(address);
        final bytes = reader.bytes;
        if (bytes == null) {
          throw RemoteException(
            'the phone stopped part-way through the reading '
            '(${reader.chunkCount} of ${reader.totalChunks} chunks, '
            '${reader.lastFrameBytes}-byte frames)',
          );
        }
        final snapshot = decodeSnapshot(
          utf8.decode(bytes, allowMalformed: true),
        );
        _usedAt[address] = DateTime.now();
        return snapshot;
      } on _NoShare {
        await _closeLink(address);
        throw const RemoteException(
          'Connected, but the phone returned no share service — is Bluetooth '
          'sharing still on?',
        );
      } on Object catch (error) {
        lastError = error;
        await _closeLink(address);
        if (attempt + 1 < readAttempts) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
      }
    }
    throw lastError is RemoteException
        ? lastError
        : RemoteException('$lastError');
  }

  /// Opens the link, or keeps the one already open.
  static Future<void> _openLink(String address) async {
    final used = _usedAt[address];
    final stale =
        used == null || DateTime.now().difference(used) > linkIdle;
    if (_open.contains(address) && !stale) return;
    if (_open.contains(address)) await _closeLink(address);

    await UniversalBle.connect(address, timeout: connectTimeout);
    _open.add(address);

    final services = await UniversalBle.discoverServices(
      address,
      timeout: connectTimeout,
    );
    final sharing = services.any((service) => service.uuid == serviceUuid);
    // A phone that restarted its share still advertises for a while after its
    // GATT server has closed. Say which of the two it looks like.
    if (!sharing) throw const _NoShare();
    _usedAt[address] = DateTime.now();
  }

  static Future<BleChunkReader> _payload(String address) async {
    final deadline = DateTime.now().add(payloadBudget);
    var reader = BleChunkReader();
    var restarts = 0;
    for (var read = 0; read < readLimit; read++) {
      if (DateTime.now().isAfter(deadline)) break;
      final raw = await UniversalBle.read(
        address,
        serviceUuid,
        dataUuid,
        timeout: chunkTimeout,
      );
      if (raw.isEmpty) break;
      // Two bytes is an empty share: index 0 of 0.
      if (raw.length < 3) break;
      try {
        if (reader.add(raw)) return reader;
      } on RemoteException {
        // The reading under this pass changed. Start the payload again rather
        // than hand back bytes from two of them.
        restarts++;
        if (restarts > payloadRestarts || DateTime.now().isAfter(deadline)) {
          throw RemoteException(
            'the phone replaced its reading mid-read every time '
            '(${reader.lastFrameBytes}-byte frames, '
            '${reader.chunkCount} of ${reader.totalChunks} chunks)',
          );
        }
        reader = BleChunkReader();
        await UniversalBle.write(
          address,
          serviceUuid,
          resetUuid,
          Uint8List.fromList(const [0]),
          timeout: chunkTimeout,
        );
      }
    }
    return reader;
  }

  static Future<void> _closeLink(String address) async {
    _open.remove(address);
    _usedAt.remove(address);
    try {
      await UniversalBle.disconnect(address, timeout: const Duration(seconds: 5));
    } on Object {
      // Dropping a link that is already gone is not a failure.
    }
  }
}

/// The phone advertises the share but has no GATT server behind it.
class _NoShare implements Exception {
  const _NoShare();
}
