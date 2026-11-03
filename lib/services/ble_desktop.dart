import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:win_ble/win_ble.dart';
// WinServer, which hands out the path of the bundled BleServer.exe, is not
// exported by the barrel.
import 'package:win_ble/win_file.dart';

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

/// The phone's Bluetooth share, read from Windows.
///
/// Windows gets no Bluetooth from the phone's own bridge, so the desktop talks
/// to the GATT server the app advertises through `win_ble`, a WinRT bridge.
/// The UUIDs and the chunked read are `BleShare.kt`'s, so the two ends cannot
/// drift apart: every read answers `[index, total, ...bytes]`, and writing to
/// the reset characteristic rewinds this client to the first chunk.
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
  static const Duration chunkTimeout = Duration(seconds: 6);

  /// A payload never spans more than 255 chunks, and a read that stopped
  /// halfway must not loop forever.
  static const int readLimit = 96;

  static bool _ready = false;

  static Future<void> _ensureReady() async {
    if (_ready) return;
    await WinBle.initialize(serverPath: await WinServer.path());
    _ready = true;
  }

  /// Phones advertising the share, strongest first.
  static Future<List<BleDesktopPeer>> scan() async {
    if (!Platform.isWindows) {
      throw const RemoteException(
        'Bluetooth watching is only available in the Windows build.',
      );
    }
    try {
      await _ensureReady();
    } on Object catch (error) {
      throw RemoteException('Bluetooth is not available here: $error');
    }

    final found = <String, BleDesktopPeer>{};
    final subscription = WinBle.scanStream.listen((device) {
      final uuids = device.serviceUuids
          .map((uuid) => uuid.toString().toLowerCase())
          .where((uuid) => uuid.contains(serviceUuid));
      if (uuids.isEmpty) return;
      found[device.address] = BleDesktopPeer(
        address: device.address,
        name: device.name.trim(),
        rssi: int.tryParse(device.rssi) ?? -999,
      );
    });
    try {
      WinBle.startScanning();
      await Future<void>.delayed(scanWindow);
    } finally {
      WinBle.stopScanning();
      await subscription.cancel();
    }
    return found.values.toList()..sort((a, b) => b.rssi.compareTo(a.rssi));
  }

  /// One phone's reading over GATT — the same JSON `/snapshot` serves.
  static Future<CellSnapshot> read(String address) async {
    if (!Platform.isWindows) {
      throw const RemoteException(
        'Bluetooth watching is only available in the Windows build.',
      );
    }
    await _ensureReady();
    await WinBle.connect(address).timeout(connectTimeout);
    try {
      final services = await WinBle.discoverServices(address, forceRefresh: true)
          .timeout(connectTimeout);
      final sharing = services
          .map((service) => service.toLowerCase())
          .any((service) => service.contains(serviceUuid));
      // A phone that restarted its share still advertises for a while after
      // its GATT server has closed, and a Windows discovery can come back
      // empty on the first try. Say which of the two it looks like.
      if (!sharing) {
        throw const RemoteException(
          'Connected, but the phone returned no share service — is Bluetooth '
          'sharing still on?',
        );
      }

      // Rewind this link's cursor: the phone advances it per client, so a read
      // that stopped halfway would otherwise resume mid-payload.
      try {
        await WinBle.write(
          address: address,
          service: serviceUuid,
          characteristic: resetUuid,
          data: Uint8List.fromList(const [0]),
          writeWithResponse: true,
        );
      } on Object {
        // A phone that refuses the reset still serves from wherever its cursor
        // is; the index in every chunk puts the pieces back in order.
      }

      final chunks = <int, List<int>>{};
      var total = 0;
      for (var attempt = 0; attempt < readLimit; attempt++) {
        final raw = await WinBle.read(
          address: address,
          serviceId: serviceUuid,
          characteristicId: dataUuid,
        ).timeout(chunkTimeout);
        if (raw.length < 3) break;
        final index = raw[0];
        total = raw[1];
        chunks[index] = raw.sublist(2);
        if (chunks.length >= total) break;
      }

      final bytes = <int>[
        for (var index = 0; index < total; index++) ...?chunks[index],
      ];
      if (bytes.isEmpty) {
        throw const RemoteException('the phone returned no reading');
      }
      return decodeSnapshot(utf8.decode(bytes, allowMalformed: true));
    } finally {
      try {
        await WinBle.disconnect(address);
      } on Object {
        // Dropping a link that is already gone is not a failure.
      }
    }
  }
}
