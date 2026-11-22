import 'package:flutter/services.dart';

import '../models/band_filters.dart';

/// Stores the Settings page's band-filter switches.
///
/// They are kept in Android's own preferences rather than in Dart state because
/// the pinned notification is drawn by a Kotlin service with no Flutter engine:
/// the service has to be able to read the same flags without talking to the app.
class AppSettings {
  static const MethodChannel _method = MethodChannel('cell_tower/monitor');

  ///
  /// Whether the Shizuku reader runs at all.
  ///
  /// On unless it was switched off: it is what the carrier rows exist for, and
  /// it does nothing on a phone without Shizuku.
  static bool carrierDetail = true;

  /// Whether the uplink spectrum mask mirrors the downlink level instead of
  /// sitting at a transmit power the platform almost never reports.
  ///
  /// Off unless switched on: it is a reading of the link, not a measurement of
  /// the transmitter, so the plain graph is what a fresh install shows.
  static bool uplinkInverse = false;

  /// Reads the stored switches into [BandFilters], before the first frame.
  static Future<void> load() async {
    try {
      final raw =
          await _method.invokeMethod<Map<Object?, Object?>>('settingsGet');
      if (raw == null) return;
      // Anything missing keeps the default, so an upgrade from a build without
      // settings behaves like a fresh install.
      BandFilters.tmobileBands = raw['tmobileBands'] != false;
      BandFilters.cbrs = raw['cbrs'] != false;
      // Off unless it was switched on: the alias is opt-in, so a phone that
      // installs this build fresh keeps the 3GPP numbering.
      BandFilters.anterixB106 = raw['anterixB106'] == true;
      AppSettings.carrierDetail = raw['carrierDetail'] != false;
      AppSettings.uplinkInverse = raw['uplinkInverse'] == true;
    } on PlatformException {
      // Nothing stored yet; the defaults stand.
    } on MissingPluginException {
      // Not Android, or a test: the defaults stand.
    }
  }

  static Future<void> setTmobileBands(bool value) async {
    BandFilters.tmobileBands = value;
    await _store('tmobileBands', value);
  }

  static Future<void> setCbrs(bool value) async {
    BandFilters.cbrs = value;
    await _store('cbrs', value);
  }

  static Future<void> setAnterixB106(bool value) async {
    BandFilters.anterixB106 = value;
    await _store('anterixB106', value);
  }

  /// Stops or starts the Shizuku reader. The native side is told separately:
  /// this only records the choice, and the reader is what acts on it.
  static Future<void> setCarrierDetail(bool value) async {
    carrierDetail = value;
    await _store('carrierDetail', value);
  }

  /// Mirrors the uplink mask on the downlink level, or stops doing so.
  static Future<void> setUplinkInverse(bool value) async {
    uplinkInverse = value;
    await _store('uplinkInverse', value);
  }

  static Future<void> _store(String key, bool value) async {
    try {
      await _method
          .invokeMethod<bool>('settingsSet', {'key': key, 'value': value});
    } on PlatformException {
      // The switch still applies to this session; it just will not persist.
    } on MissingPluginException {
      // Same: in-memory only outside the Android build.
    }
  }
}
