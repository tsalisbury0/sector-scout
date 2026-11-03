import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

/// The release tag that named this build (`v1.0.2-beta`).
///
/// Bumped alongside pubspec.yaml's version at every release. The checker uses
/// it to recognise **this** build in the release list, so it never offers a
/// reinstall of itself, and to know this build is a beta — the stable of the
/// same version numbers is then still offered as an update, since moving off
/// the prerelease matters even when the numbers match.
const String kBuildTag = 'v1.0.2-beta';

/// The version string of this build, used where Android's versionName is not
/// reachable (the desktop has no platform to ask).
const String kVersionText = '1.0.2';

/// Where releases are listed. The repo is public, so this reads without a
/// token: the unauthenticated 60-queries-an-hour cap suits a once-per-launch
/// check easily.
const String kReleasesUrl =
    'https://api.github.com/repos/tsalisbury0/sector-scout/releases?per_page=10';

/// Which updates exist and what is happening with them, published on
/// [UpdateChecker.update] for the banner and the settings row.
sealed class UpdatePhase {
  const UpdatePhase();
}

/// A check is on its way.
class UpdateChecking extends UpdatePhase {
  const UpdateChecking();
}

/// Something newer than this build could be installed.
class UpdateAvailable extends UpdatePhase {
  const UpdateAvailable(this.info);

  final UpdateInfo info;
}

/// The APK is coming down.
class UpdateDownloading extends UpdatePhase {
  const UpdateDownloading(this.info, this.percent);

  final UpdateInfo info;
  final int percent;
}

/// The APK sits in the app's storage, ready for the package installer.
class UpdateReady extends UpdatePhase {
  const UpdateReady(this.info, this.apkPath);

  final UpdateInfo info;
  final String apkPath;
}

/// The check or the download failed; the banner explains and retries.
class UpdateFailed extends UpdatePhase {
  const UpdateFailed(this.message);

  final String message;
}

/// One release from GitHub, reduced to what an updater needs.
class UpdateInfo {
  const UpdateInfo({
    required this.tag,
    required this.title,
    required this.prerelease,
    required this.major,
    required this.minor,
    required this.patch,
    required this.pageUrl,
    required this.apkUrl,
    required this.windowsUrl,
  });

  final String tag;
  final String title;
  final bool prerelease;
  final int major;
  final int minor;
  final int patch;
  final String pageUrl;

  /// The APK asset on the release, when there is one.
  final String? apkUrl;

  /// The Windows app zip, when there is one.
  final String? windowsUrl;

  /// `1.0.2` with a beta marker, for display.
  String get versionText =>
      '$major.$minor.$patch${prerelease ? ' (beta)' : ''}';

  /// Upward sort order of `a.b.c`.
  int get order => ((major * 100) + minor) * 100 + patch;
}

class UpdateChecker {
  UpdateChecker._();

  static const _channel = MethodChannel('cell_tower/monitor');

  /// The live phase of the whole feature. Null means "quiet": no check yet, up
  /// to date, or nothing that needs the user's eye.
  static final ValueNotifier<UpdatePhase?> update = ValueNotifier(null);

  /// Whether prereleases are offered. On by default? Off: a checker that
  /// starts offering betas to everyone buries stable builds.
  static final ValueNotifier<bool> betas = ValueNotifier(false);

  static String _skipTag = '';

  /// Wakes the service up: reads what the user last chose, then checks once.
  /// A failure here is fine — the banner shows it and a check can be redone.
  static Future<void> start() async {
    try {
      final file = await _prefFile();
      if (file != null && file.existsSync()) {
        final raw = jsonDecode(file.readAsStringSync());
        if (raw is Map<String, Object?>) {
          betas.value = raw['beta'] == true;
          if (raw['skip'] is String) _skipTag = raw['skip'] as String;
        }
      }
    } catch (_) {
      // No preferences yet behave like a fresh install: defaults stand.
    }
    unawaited(refresh());
  }

  /// Flips the beta channel, remembers it and re-checks, since the same list
  /// answers differently with the channel open.
  static Future<void> setBetas(bool value) async {
    betas.value = value;
    await _save();
    unawaited(refresh());
  }

  /// Stops offering the update currently on screen (until a newer release
  /// comes out of course).
  static Future<void> skip() async {
    final phase = update.value;
    if (phase is UpdateAvailable) {
      _skipTag = phase.info.tag;
      await _save();
      update.value = null;
    }
  }

  /// Asks GitHub what is out, and updates [update] with the answer.
  static Future<void> refresh() async {
    update.value = const UpdateChecking();
    try {
      final releases = await _releases();
      final current = _tripleOf(await currentVersion());
      _Release? best;
      for (final release in releases) {
        if (betas.value == false && release.prerelease) continue;
        if (release.tag == kBuildTag || release.tag == _skipTag) continue;
        // Same version numbers of this build's release is this build under
        // another angle (or an alias) — never offer it.
        if (release.order == current.order &&
            release.prerelease == current.prerelease) {
          continue;
        }
        if (best == null ||
            release.order > best.order ||
            (release.order == best.order && best.prerelease && !release.prerelease)) {
          best = release;
        }
      }
      if (best == null) {
        update.value = null;
        return;
      }
      // A newer number is always an offer. The same numbers are one only when
      // this build is a beta and the release is its stable — moving off the
      // prerelease matters even without a number change.
      final newer = best.order > current.order ||
          (best.order == current.order && best.prerelease == false && _isBetaBuild());
      update.value = newer ? UpdateAvailable(best) : null;
    } catch (error) {
      update.value = UpdateFailed('Update check failed: $error');
    }
  }

  /// Runs the update: on Android the APK is downloaded and handed to the
  /// package installer; the desktop jumps to the release page, where the new
  /// folder zip waits (a portable exe can only be replaced while stopped).
  static Future<void> install(UpdateInfo info) async {
    final apkUrl = info.apkUrl;
    if (apkUrl == null) {
      // Desktop, or a release without an APK: the release page is the way in.
      unawaited(launchUrl(
        Uri.parse(info.pageUrl),
        mode: LaunchMode.externalApplication,
      ));
      update.value = null;
      return;
    }
    try {
      final dir = await getApplicationSupportDirectory();
      final apk =
          File('${dir.path}${Platform.pathSeparator}sector-scout-${info.tag}.apk');
      update.value = UpdateDownloading(info, 0);
      await _download(apkUrl, apk, info);
      update.value = UpdateReady(info, apk.path);
    } catch (error) {
      update.value = UpdateFailed('Download failed: $error');
    }
  }

  /// Hands a downloaded APK to the package installer. `false` means the user
  /// was sent to grant "install unknown apps" first and should tap again.
  static Future<bool> installApk(String path) async {
    return await _channel.invokeMethod<bool>('installApk', {'path': path}) ??
        false;
  }

  /// The version name of this build. Android knows it exactly; elsewhere the
  /// constant stands.
  static Future<String> currentVersion() async {
    try {
      final name = await _channel.invokeMethod<String>('appVersion');
      if (name != null && name.isNotEmpty) return name;
    } on PlatformException {
      // The channel exists but stopped answering: fall back below.
    } on MissingPluginException {
      // Not Android: the constant stands.
    }
    return kVersionText;
  }

  static bool _isBetaBuild() => kBuildTag.contains('-');

  /// The feature's own little preferences file, kept next to the app.
  static Future<File?> _prefFile() async {
    try {
      final dir = await getApplicationSupportDirectory();
      return File('${dir.path}${Platform.pathSeparator}updates.json');
    } catch (_) {
      return null;
    }
  }

  static Future<void> _save() async {
    final file = await _prefFile();
    if (file == null) return;
    try {
      await file.writeAsString(jsonEncode({'beta': betas.value, 'skip': _skipTag}));
    } catch (_) {
      // The choice holds for this run even if the disk said no.
    }
  }

  /// The release list, sorted oldest-last by GitHub itself.
  static Future<List<_Release>> _releases() async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(kReleasesUrl));
      request.headers.set(HttpHeaders.userAgentHeader, 'sector-scout-update');
      request.headers
          .set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != 200) {
        throw 'GitHub answered ${response.statusCode}';
      }
      return (jsonDecode(body) as List)
          .whereType<Map<String, Object?>>()
          .where((release) => release['draft'] != true)
          .map(_Release.json)
          .toList();
    } finally {
      client.close();
    }
  }

  static Future<void> _download(
    String url,
    File apk,
    UpdateInfo info,
  ) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl('GET', Uri.parse(url));
      request.headers.set(HttpHeaders.userAgentHeader, 'sector-scout-update');
      final response = await request.close();
      if (response.statusCode != 200) {
        throw 'GitHub answered ${response.statusCode}';
      }
      final total = response.contentLength ?? -1;
      final sink = apk.openWrite();
      var got = 0;
      var shown = -1;
      try {
        await for (final chunk in response) {
          got += chunk.length;
          sink.add(chunk);
          if (total > 0) {
            final percent = (got * 100 ~/ total);
            // Repaint the banner in steps of five, not per chunk.
            if (percent ~/ 5 != shown ~/ 5 && shown != percent) {
              shown = percent;
              update.value = UpdateDownloading(info, percent);
            }
          }
        }
      } finally {
        await sink.flush();
        await sink.close();
      }
    } finally {
      client.close();
    }
  }
}

/// Internal release shape: the JSON as parsed, plus the derived [info].
class _Release extends UpdateInfo {
  _Release.json(Map<String, Object?> release)
      : super(
          tag: release['tag_name'] as String? ?? '',
          title: release['name'] as String? ?? (release['tag_name'] as String? ?? ''),
          prerelease: release['prerelease'] == true,
          major: _parts(release, 0),
          minor: _parts(release, 1),
          patch: _parts(release, 2),
          pageUrl: release['html_url'] as String? ?? '',
          apkUrl: _asset(release, (name) => name.toLowerCase().endsWith('.apk')),
          windowsUrl: _asset(
            release,
            (name) {
              final lower = name.toLowerCase();
              return lower.contains('windows') && lower.endsWith('.zip');
            },
          ),
        );

  static int _parts(Map<String, Object?> release, int index) {
    final tag = release['tag_name'] as String? ?? '';
    final numbers = tag
        .replaceFirst(RegExp('^v'), '')
        .split(RegExp('[-+]'))
        .first
        .split('.');
    return index < numbers.length ? int.tryParse(numbers[index]) ?? 0 : 0;
  }

  static String? _asset(Map<String, Object?> release, bool Function(String) test) {
    final assets = release['assets'];
    if (assets is! List) return null;
    for (final asset in assets.whereType<Map<String, Object?>>()) {
      final name = asset['name'];
      final url = asset['browser_download_url'];
      if (name is String && url is String && test(name)) return url;
    }
    return null;
  }
}

/// A version string like `1.0.2` or `1.0.2-beta` reduced to its numbers plus
/// whether it is a prerelease.
class _Version {
  const _Version(this.order, this.prerelease);

  final int order;
  final bool prerelease;
}

_Version _tripleOf(String text) {
  final parts = text
      .replaceFirst(RegExp('^v'), '')
      .split(RegExp('[-+]'));
  final numbers = parts.first.split('.');
  final order =
      ((int.tryParse(numbers[0]) ?? 0) * 100 +
              (numbers.length > 1 ? int.tryParse(numbers[1]) ?? 0 : 0)) *
          100 +
          (numbers.length > 2 ? int.tryParse(numbers[2]) ?? 0 : 0);
  return _Version(order, parts.length > 1 && parts[1].isNotEmpty);
}
