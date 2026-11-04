import 'package:flutter/services.dart';

/// What the privileged reader is doing, as the native side reports it.
///
/// `ready` means a Shizuku user service is bound as the shell user and the
/// carrier rows are live. Everything else is a reason it is not, and each one
/// has its own next step on the Settings page.
enum CarrierDetailState {
  notInstalled,
  notRunning,
  unsupported,
  noPermission,
  starting,
  ready,
  unknown,
}

/// The state plus who is answering it.
class CarrierDetailStatus {
  const CarrierDetailStatus({required this.state, this.uid, this.error});

  factory CarrierDetailStatus.fromMap(Map<Object?, Object?> map) {
    final uid = map['uid'];
    return CarrierDetailStatus(
      state: _parse(map['state']),
      uid: uid is num ? uid.toInt() : null,
      error: map['error']?.toString(),
    );
  }

  final CarrierDetailState state;

  /// The UID the reader runs as: 2000 over adb, 0 over root. Null unless bound.
  final int? uid;

  /// The last native failure, when there was one.
  final String? error;

  bool get isReady => state == CarrierDetailState.ready;

  String get label => switch (state) {
    CarrierDetailState.ready => uid == 0
        ? 'Live, as root. Every aggregated carrier and its width is being read.'
        : 'Live, as the adb shell user. Every aggregated carrier and its '
              'width is being read.',
    CarrierDetailState.starting => 'Starting the reader…',
    CarrierDetailState.noPermission =>
      'Shizuku is running, but has not granted this app access yet.',
    CarrierDetailState.notRunning =>
      'Shizuku is installed but not running. Start it once over adb, or from '
          'wireless debugging.',
    CarrierDetailState.notInstalled =>
      'Shizuku is not installed. It needs no root, but has to be started once '
          'from a computer, or from Android 11’s wireless debugging.',
    CarrierDetailState.unsupported =>
      'This Shizuku is older than v11, which is where the reader lives.',
    CarrierDetailState.unknown => error ?? 'Carrier detail is unavailable.',
  };

  /// The button for this state: the one action that moves it forward.
  String get actionLabel => switch (state) {
    CarrierDetailState.notInstalled => 'Get Shizuku',
    CarrierDetailState.noPermission => 'Grant',
    CarrierDetailState.notRunning => 'Open',
    CarrierDetailState.ready => 'Refresh',
    _ => 'Check',
  };

  static CarrierDetailState _parse(Object? value) => switch (value) {
    'not_installed' => CarrierDetailState.notInstalled,
    'not_running' => CarrierDetailState.notRunning,
    'unsupported' => CarrierDetailState.unsupported,
    'no_permission' => CarrierDetailState.noPermission,
    'starting' => CarrierDetailState.starting,
    'ready' => CarrierDetailState.ready,
    _ => CarrierDetailState.unknown,
  };
}

/// Dart side of `PrivilegedRadio.kt`.
///
/// Every call answers even on a device with no Shizuku at all: the native side
/// reports a state instead of throwing, so the Settings page can always say
/// why the carrier rows are missing.
class CarrierDetailService {
  static const MethodChannel _method = MethodChannel('cell_tower/monitor');

  /// Where a user without Shizuku starts. Opened in the browser, not by the
  /// app: the reader itself never leaves the phone.
  static const String shizukuDownload = 'https://shizuku.rikka.app/download/';

  Future<CarrierDetailStatus> status() async {
    try {
      final map = await _method.invokeMethod<Map<Object?, Object?>>(
        'carrierDetailStatus',
      );
      return CarrierDetailStatus.fromMap(map ?? const {});
    } on PlatformException {
      return const CarrierDetailStatus(state: CarrierDetailState.unknown);
    } on MissingPluginException {
      return const CarrierDetailStatus(
        state: CarrierDetailState.unknown,
        error: 'This build has no native bridge.',
      );
    }
  }

  /// Asks Shizuku's own dialog for the grant.
  Future<CarrierDetailStatus> request() async {
    try {
      final map = await _method.invokeMethod<Map<Object?, Object?>>(
        'carrierDetailRequest',
      );
      return CarrierDetailStatus.fromMap(map ?? const {});
    } on PlatformException {
      return const CarrierDetailStatus(state: CarrierDetailState.unknown);
    } on MissingPluginException {
      return const CarrierDetailStatus(
        state: CarrierDetailState.unknown,
        error: 'This build has no native bridge.',
      );
    }
  }

  /// Brings Shizuku's own app to the front, which is how it is started.
  Future<bool> openShizuku() async {
    try {
      return await _method.invokeMethod<bool>('carrierDetailOpen') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
