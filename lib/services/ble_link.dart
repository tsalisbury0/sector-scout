import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/cell_snapshot.dart';
import 'remote_client.dart';

/// True where the native Bluetooth bridge exists.
bool get bleSupported => !kIsWeb && Platform.isAndroid;

/// A nearby phone advertising its reading over Bluetooth.
class BlePeer {
  const BlePeer({
    required this.address,
    required this.name,
    required this.rssi,
  });

  final String address;

  /// The peer's Bluetooth name, which is its phone model on most devices.
  final String name;

  final int rssi;

  /// What the picker shows: the name, or the address when the peer hides it.
  String get label => name.isEmpty ? address : name;

  factory BlePeer.fromMap(Map<Object?, Object?> map) => BlePeer(
        address: map['address']?.toString() ?? '',
        name: map['name']?.toString() ?? '',
        rssi: (map['rssi'] as num?)?.toInt() ?? 0,
      );
}

/// Turns this phone into a Bluetooth advertiser, so a peer with no Wi-Fi can
/// still read the reading.
///
/// The native side owns the GATT server; this only starts it and pushes the
/// same JSON the LAN endpoint serves.
class BleShareLink {
  static const MethodChannel _method = MethodChannel('cell_tower/monitor');

  bool get isSupported => bleSupported;

  /// Name the other phone sees in its Bluetooth list.
  String? name;

  /// Starts advertising. The error text is ready for the UI.
  Future<BleShareStart> start() async {
    if (!isSupported) {
      return const BleShareStart(false, null, 'Bluetooth sharing is Android only.');
    }
    final missing = await _ensureGranted(
      const [Permission.bluetoothAdvertise, Permission.bluetoothConnect],
      'Bluetooth access is needed to share this reading.',
    );
    if (missing != null) return BleShareStart(false, null, missing);

    try {
      final raw = await _method
          .invokeMethod<Map<Object?, Object?>>('bleShareStart');
      final started = raw?['ok'] == true;
      name = raw?['name']?.toString();
      return BleShareStart(
        started,
        name,
        raw?['error']?.toString(),
      );
    } on PlatformException catch (error) {
      return BleShareStart(
        false,
        null,
        error.message ?? 'Android would not start Bluetooth sharing.',
      );
    } on MissingPluginException {
      return const BleShareStart(
        false,
        null,
        'This build has no Bluetooth bridge.',
      );
    }
  }

  /// Hands the newest reading to the advertiser. Silent when not sharing.
  Future<void> update(CellSnapshot snapshot) async {
    if (!isSupported) return;
    try {
      await _method.invokeMethod<bool>(
        'bleShareUpdate',
        {'json': encodeSnapshot(snapshot)},
      );
    } on PlatformException {
      // The next update replaces this one anyway.
    } on MissingPluginException {
      // Nothing advertising in this build.
    }
  }

  Future<void> stop() async {
    if (!isSupported) return;
    try {
      await _method.invokeMethod<bool>('bleShareStop');
    } on PlatformException {
      // Stopped is the desired state either way.
    } on MissingPluginException {
      // Nothing to stop.
    }
  }

  Future<bool> isRunning() async {
    if (!isSupported) return false;
    try {
      final raw =
          await _method.invokeMethod<Map<Object?, Object?>>('bleShareStatus');
      name = raw?['name']?.toString() ?? name;
      return raw?['running'] == true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}

/// What happened when the advertiser was switched on.
class BleShareStart {
  const BleShareStart(this.ok, this.name, this.error);

  final bool ok;
  final String? name;
  final String? error;
}

/// Reads another phone's reading over Bluetooth.
///
/// Shape mirrors [RemoteClient] so the screen can poll either transport with
/// the same code: [connect] once, then [fetch] until [dispose].
class BleClient {
  BleClient(this.peer);

  static const MethodChannel _method = MethodChannel('cell_tower/monitor');

  final BlePeer peer;

  /// Connects and confirms the peer exposes the service, returning the name
  /// it answered with (null when it hides one).
  Future<String?> connect() async {
    if (!bleSupported) {
      throw const RemoteException(
        'Bluetooth watching is only available in the Android build.',
      );
    }
    final missing = await _ensureGranted(
      const [Permission.bluetoothScan, Permission.bluetoothConnect],
      'Bluetooth access is needed to read the other phone.',
    );
    if (missing != null) throw RemoteException(missing);

    final Map<Object?, Object?>? raw;
    try {
      raw = await _method.invokeMethod<Map<Object?, Object?>>(
        'bleOpen',
        {'address': peer.address},
      );
    } on PlatformException catch (error) {
      throw RemoteException(
        error.message ?? 'Could not connect over Bluetooth.',
      );
    } on MissingPluginException {
      throw const RemoteException('This build has no Bluetooth bridge.');
    }

    final error = raw?['error']?.toString();
    if (error != null && error.isNotEmpty) throw RemoteException(error);

    final name = raw?['name']?.toString().trim();
    return (name == null || name.isEmpty) ? null : name;
  }

  /// The peer's reading, or null when it has not produced one yet.
  ///
  /// Bluetooth reads fail for ordinary reasons (a paused advertisement, a
  /// dropped link), so a failure is reported as null and the next poll retries
  /// instead of tearing the view down.
  Future<CellSnapshot?> fetch() async {
    String? body;
    try {
      body = await _method.invokeMethod<String>('bleRead');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
    if (body == null || body.isEmpty) return null;
    return decodeSnapshot(body);
  }

  void dispose() {
    if (!bleSupported) return;
    _method.invokeMethod<bool>('bleClose').catchError((Object _) => false);
  }

  /// Phones currently advertising, strongest first.
  static Future<List<BlePeer>> scan() async {
    if (!kIsWeb && Platform.isAndroid) {
      final missing = await _ensureGranted(
        const [Permission.bluetoothScan, Permission.bluetoothConnect],
        'Bluetooth access is needed to find the other phone.',
      );
      if (missing != null) throw RemoteException(missing);
    } else {
      throw const RemoteException(
        'Bluetooth watching is only available in the Android build.',
      );
    }

    final List<Object?>? raw;
    try {
      raw = await _method.invokeMethod<List<Object?>>('bleScan');
    } on PlatformException catch (error) {
      throw RemoteException(error.message ?? 'Scanning over Bluetooth failed.');
    } on MissingPluginException {
      throw const RemoteException('This build has no Bluetooth bridge.');
    }

    return (raw ?? const [])
        .whereType<Map<Object?, Object?>>()
        .map(BlePeer.fromMap)
        .where((peer) => peer.address.isNotEmpty)
        .toList();
  }
}

/// The JSON one phone sends another — the same payload the LAN endpoint
/// serves, so a Bluetooth reader parses it with the app's normal parser.
String encodeSnapshot(CellSnapshot snapshot) =>
    jsonEncode(snapshot.toJsonMap());

/// Parses a peer's payload, with the same error the LAN client gives.
CellSnapshot decodeSnapshot(String body) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException {
    throw const RemoteException('That phone sent JSON this app cannot read.');
  }
  if (decoded is! Map<Object?, Object?>) {
    throw const RemoteException('Unexpected response shape from that phone.');
  }
  try {
    return CellSnapshot.fromMap(decoded);
  } on Object {
    throw const RemoteException(
      'That phone sent data this build cannot read. Update both apps.',
    );
  }
}

/// Asks for whatever is missing, returning a message when it was refused.
Future<String?> _ensureGranted(
  List<Permission> permissions,
  String message,
) async {
  for (final permission in permissions) {
    if (await permission.isGranted) continue;
    final status = await permission.request();
    if (!status.isGranted && !status.isLimited) return message;
  }
  return null;
}
