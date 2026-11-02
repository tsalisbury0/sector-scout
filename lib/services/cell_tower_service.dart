import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/cell_snapshot.dart';

/// Dart side of the Kotlin bridge in `android/.../CellSnapshot.kt`.
class CellTowerService {
  static const MethodChannel _method = MethodChannel('cell_tower/monitor');
  static const EventChannel _events = EventChannel('cell_tower/stream');

  /// True only where the native channels actually exist.
  bool get isSupported => !kIsWeb && Platform.isAndroid;

  /// One-shot read. Used for the first paint and the pull-to-refresh gesture.
  Future<CellSnapshot> snapshot() async {
    if (!isSupported) {
      throw const CellTowerException(
        'Cell tower data is only available in the Android build.',
      );
    }
    try {
      final raw = await _method.invokeMethod<Map<Object?, Object?>>('snapshot');
      if (raw == null) {
        throw const CellTowerException('The modem returned no data.');
      }
      return CellSnapshot.fromMap(raw);
    } on PlatformException catch (error) {
      throw CellTowerException(
        error.message ?? 'Reading cell info failed (${error.code}).',
      );
    } on MissingPluginException {
      throw const CellTowerException(
        'Native cell-info bridge is missing from this build.',
      );
    }
  }

  /// Live updates, coalesced by the native layer (~2 s worst case).
  Stream<CellSnapshot> watch() {
    return _events.receiveBroadcastStream().map((event) {
      return CellSnapshot.fromMap(event as Map<Object?, Object?>);
    }).handleError((Object error) {
      if (error is PlatformException) {
        throw CellTowerException(
          error.message ?? 'Live signal stream failed (${error.code}).',
        );
      }
      throw CellTowerException('Live signal stream failed: $error');
    });
  }
}

class CellTowerException implements Exception {
  const CellTowerException(this.message);

  final String message;

  @override
  String toString() => message;
}
