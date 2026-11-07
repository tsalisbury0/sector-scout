import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/desktop_home.dart';
import 'screens/home_screen.dart';
import 'services/app_settings.dart';
import 'services/carrier_names.dart';
import 'services/update_checker.dart';
import 'theme/app_colors.dart';

bool get _isDesktop =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The band switches decide how the first frame labels a cell, so they are
  // read before the app is built rather than flipping the labels a moment in.
  // The band switches live in Android's preferences, read over a channel
  // that does not exist on a desktop, so the defaults stand there.
  try {
    await AppSettings.load();
  } catch (_) {
    // No native side (Windows, Linux, macOS).
  }
  // Portrait only: the dashboard is a single column, and rotating the phone
  // mid-read (or while it is being screenshotted) only relayouts it.
  if (!_isDesktop) {
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
    ]);
  }
  // Draw behind the system bars so the dark theme reaches the screen edges.
  if (!_isDesktop) {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: AppColors.background,
      systemNavigationBarIconBrightness: Brightness.light,
      systemNavigationBarDividerColor: Colors.transparent,
    ));
  }
  if (_isDesktop) {
    // The desk reads the same operator list the phone does, so a served reading
    // is named the way the phone names it. A failed fetch just leaves the name
    // the payload carried.
    unawaited(CarrierNames.load().catchError((_) => false));
  }
  // What is out on GitHub, checked on the way in so the banner is settled
  // before the window is really on screen. Failures park on the banner.
  unawaited(UpdateChecker.start());
  runApp(const CellTowerApp());
}

class CellTowerApp extends StatelessWidget {
  const CellTowerApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.accent,
      brightness: Brightness.dark,
    ).copyWith(surface: AppColors.surface);

    return MaterialApp(
      title: 'Sector Scout',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: AppColors.background,
        appBarTheme: const AppBarTheme(
          backgroundColor: AppColors.background,
          surfaceTintColor: Colors.transparent,
          foregroundColor: AppColors.textPrimary,
        ),
        textTheme: ThemeData.dark().textTheme.apply(
              bodyColor: AppColors.textPrimary,
              displayColor: AppColors.textPrimary,
            ),
        // Every framed surface shares one small radius, so buttons, dialogs
        // and panels line up instead of each carrying its own curve.
        dialogTheme: DialogThemeData(
          backgroundColor: AppColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppColors.radius),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppColors.radius),
            ),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppColors.radius),
            ),
          ),
        ),
        dividerTheme: const DividerThemeData(
          color: AppColors.border,
          space: 1,
          thickness: 1,
        ),
      ),
      home: _isDesktop ? const DesktopHome() : const HomeScreen(),
    );
  }
}
