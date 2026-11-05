import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/cell_snapshot.dart';
import 'carrier_names.dart';

/// Dart side of `SignalStatusService.kt`: a foreground service that keeps the
/// serving cell pinned in the notification shade.
///
/// The lines are drawn natively, so the notification keeps updating with the
/// app closed — Dart only switches it on and off.
class SignalNotification {
  static const MethodChannel _method = MethodChannel('cell_tower/monitor');

  bool get isSupported => !kIsWeb && Platform.isAndroid;

  /// True when the user has left it switched on (it survives app restarts).
  Future<bool> isOn() async {
    if (!isSupported) return false;
    try {
      final raw =
          await _method.invokeMethod<Map<Object?, Object?>>('notificationStatus');
      return raw?['enabled'] == true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Asks for notification permission where Android requires it, then pins the
  /// notification. Returns false with a reason when it could not be shown.
  Future<SignalNotificationOutcome> enable() async {
    if (!isSupported) {
      return const SignalNotificationOutcome(
        false,
        'The pinned notification is Android only.',
      );
    }
    // Android 13+ needs an explicit grant; older releases report granted.
    final status = await Permission.notification.request();
    if (!status.isGranted && !status.isLimited) {
      return const SignalNotificationOutcome(
        false,
        'Notifications are blocked — allow them for this app to pin the signal.',
      );
    }
    try {
      final started = await _method.invokeMethod<bool>(
        'notificationStart',
        notificationStartArguments(),
      );
      return started == true
          ? const SignalNotificationOutcome(true, null)
          : const SignalNotificationOutcome(
              false,
              'Android would not start the notification service.',
            );
    } on PlatformException catch (error) {
      return SignalNotificationOutcome(
        false,
        error.message ?? 'Could not start the notification service.',
      );
    }
  }

  /// The arguments that start the service, in a form the method codec accepts.
  ///
  /// The tag sets are Lists rather than the Sets the operator list is parsed
  /// into: the platform codec cannot encode a Set, and an unencodable argument
  /// throws inside `invokeMethod` before Kotlin is ever called, which made the
  /// switch appear to do nothing at all.
  @visibleForTesting
  Map<String, Object?> notificationStartArguments() => {
        // The A10e build re-codes its carrier as B106; the native summary needs
        // to know, or the notification would contradict the app.
        'aliasB106': kA10eBandAlias,
        'satellitePlmns': CarrierNames.satellites.toList(),
        'lteMPlmns': CarrierNames.lteMs.toList(),
      };

  /// Hands the operator list to the native notification.
  ///
  /// The service draws its lines itself, so it cannot read Dart's list; it
  /// keeps this copy. It has no built-in table, so before the first push it
  /// falls back to the SIM's own name.
  Future<void> pushCarrierNames(Map<String, String> table) async {
    if (!isSupported) return;
    try {
      await _method.invokeMethod<bool>('carrierNames', table);
    } on PlatformException {
      // The native bundled list stays in use.
    } on MissingPluginException {
      // Nothing to hand it to in this build.
    }
  }

  /// Hands the list's bars offsets and its `satellite` / `lteM` tags to the
  /// notification, which draws itself and therefore cannot read Dart's list.
  ///
  /// The tags travel with the names so a phone that starts offline still counts
  /// a satellite link's bars the way the list does, marks it `SAT`, and reads an
  /// `lteM` network as **LTE-M** instead of plain LTE.
  Future<void> pushCarrierFlags(
    Map<String, double> boosts,
    Set<String> satellites,
    Set<String> lteMs, {
    Map<String, String> fiveGs = const {},
  }) async {
    if (!isSupported) return;
    try {
      await _method.invokeMethod<bool>('carrierBoosts', boosts);
      // Same reason as in [enable]: Sets do not survive the method codec.
      await _method.invokeMethod<bool>('carrierSatellites', satellites.toList());
      await _method.invokeMethod<bool>('carrierLteMs', lteMs.toList());
      if (fiveGs.isNotEmpty) {
        await _method.invokeMethod<bool>('carrierFiveG', fiveGs);
      }
    } on PlatformException {
      // Nothing cached; the next fetch seeds it again.
    } on MissingPluginException {
      // Nothing to hand it to in this build.
    }
  }

  /// The satellite bars offsets stored with the cached list, empty if none.
  Future<Map<String, double>> cachedCarrierBoosts() async {
    if (!isSupported) return const {};
    try {
      final raw = await _method
          .invokeMethod<Map<Object?, Object?>>('carrierBoostsCached');
      if (raw == null) return const {};
      return {
        for (final entry in raw.entries)
          if (entry.key != null && entry.value is num)
            entry.key.toString(): (entry.value as num).toDouble(),
      };
    } on PlatformException {
      return const {};
    } on MissingPluginException {
      return const {};
    }
  }

  /// The operator list the service last stored on the device.
  ///
  /// Used to seed the app before a fetch, so a phone with no network still
  /// names networks the way the list does.
  Future<Map<String, String>> cachedCarrierNames() async {
    if (!isSupported) return const {};
    try {
      final raw = await _method
          .invokeMethod<Map<Object?, Object?>>('carrierNamesCached');
      if (raw == null) return const {};
      return {
        for (final entry in raw.entries)
          if (entry.key != null && entry.value != null)
            entry.key.toString(): entry.value.toString(),
      };
    } on PlatformException {
      return const {};
    } on MissingPluginException {
      return const {};
    }
  }

  Future<void> disable() async {
    if (!isSupported) return;
    try {
      await _method.invokeMethod<bool>('notificationStop');
    } on PlatformException {
      // Nothing to do: the service being gone is the desired state.
    }
  }

  /// True when Android may not freeze this app in the background.
  ///
  /// A foreground service keeps the notification pinned, but Doze and OEM
  /// battery managers still freeze a backgrounded app, which leaves the shade
  /// showing a reading from minutes ago.
  Future<bool> backgroundExempt() async {
    if (!isSupported) return true;
    try {
      return await _method.invokeMethod<bool>('backgroundExempt') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Opens the system prompt that exempts this app from battery optimisation.
  /// False when no such screen would open.
  Future<bool> requestBackgroundExemption() async {
    if (!isSupported) return false;
    try {
      return await _method.invokeMethod<bool>('backgroundExemptRequest') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}

/// Whether the notification is pinned now, and why not when it isn't.
class SignalNotificationOutcome {
  const SignalNotificationOutcome(this.on, this.message);

  final bool on;
  final String? message;
}
