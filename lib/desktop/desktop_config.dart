import 'dart:convert';
import 'dart:io';

import 'scenario.dart';

/// What the desktop remembers between runs: the phones being watched, the
/// scenario the test source serves and the band switches, in the same
/// `%APPDATA%\Sector Scout` folder the Python console used.
class DesktopConfig {
  DesktopConfig({
    List<String>? phones,
    this.scenarioId = 'tmo-n41',
    this.corrections = true,
    CustomSource? custom,
  })  : phones = [...?phones],
        custom = custom ?? const CustomSource();

  final List<String> phones;
  String scenarioId;

  /// The console's "Display corrections" switch: the band corrections the app
  /// applies to what it draws (n38 → n41, CBRS n77 → n48).
  bool corrections;

  /// What the editor last built, kept even while a preset is selected so
  /// switching back does not lose the bands that were typed in.
  CustomSource custom;

  static File defaultFile() {
    final appData = Platform.environment['APPDATA'] ??
        Platform.environment['HOME'] ??
        Directory.current.path;
    final separator = Platform.pathSeparator;
    return File('$appData${separator}Sector Scout${separator}desktop.json');
  }

  static DesktopConfig load([File? file]) {
    final target = file ?? defaultFile();
    try {
      if (!target.existsSync()) return DesktopConfig();
      final decoded = jsonDecode(target.readAsStringSync());
      if (decoded is! Map<Object?, Object?>) return DesktopConfig();
      final phones = <String>[];
      final raw = decoded['phones'];
      if (raw is List<Object?>) {
        for (final entry in raw) {
          // The console saved an object per phone (`url`, `name`,
          // `transport`); this build saves the address alone. Both are read, so
          // switching between the two apps does not lose the list.
          if (entry is String && entry.trim().isNotEmpty) {
            phones.add(entry.trim());
          } else if (entry is Map<Object?, Object?>) {
            // The console wrote a Bluetooth phone's transport beside its
            // address, so read that shape too.
            if (entry['transport'] == 'ble') {
              final address = entry['address'];
              if (address is String && address.trim().isNotEmpty) {
                phones.add('ble:${address.trim()}');
              }
              continue;
            }
            final url = entry['url'];
            if (url is String && url.trim().isNotEmpty) phones.add(url.trim());
          }
        }
      }
      final scenario = decoded['scenario'];
      return DesktopConfig(
        phones: phones,
        scenarioId:
            scenario is String && scenario.isNotEmpty ? scenario : 'tmo-n41',
        corrections: decoded['corrections'] != false,
        custom: CustomSource.fromJson(decoded['custom']),
      );
    } on Object {
      // A corrupt file must not stop the app from opening.
      return DesktopConfig();
    }
  }

  Future<void> save([File? file]) async {
    final target = file ?? defaultFile();
    try {
      await target.parent.create(recursive: true);
      await target.writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'scenario': scenarioId,
          'corrections': corrections,
          'custom': custom.toJson(),
          'phones': phones,
        }),
      );
    } on Object {
      // A read-only profile or no permission: the session still works.
    }
  }
}
