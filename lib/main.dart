import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/desktop_home.dart';
import 'screens/home_screen.dart';
import 'services/app_settings.dart';
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
      ),
      home: _isDesktop ? const DesktopHome() : const HomeScreen(),
    );
  }
}
