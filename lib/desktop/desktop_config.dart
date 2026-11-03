import 'dart:convert';
import 'dart:io';

import 'scenario.dart';

/// What the desktop remembers between runs: the phones being watched and the
/// scenario the test source serves, in the same `%APPDATA%\Sector Scout` folder
/// the Python console used.
class DesktopConfig {
  DesktopConfig({
    List<String>? phones,
    this.scenarioId = 'tmo-n41',
    CustomSource? custom,
  })  : phones = [...?phones],
        custom = custom ?? const CustomSource();

  final List<String> phones;
  String scenarioId;

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
          if (entry is String && entry.trim().isNotEmpty) phones.add(entry.trim());
        }
      }
      final scenario = decoded['scenario'];
      return DesktopConfig(
        phones: phones,
        scenarioId: scenario is String && scenario.isNotEmpty ? scenario : 'tmo-n41',
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
          'phones': phones,
          'scenario': scenarioId,
          'custom': custom.toJson(),
        }),
      );
    } on Object {
      // A read-only profile or no permission: the session still works.
    }
  }
}
