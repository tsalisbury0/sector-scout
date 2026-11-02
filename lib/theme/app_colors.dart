import 'package:flutter/material.dart';

/// Small dark palette shared by the widgets, so the RF dashboard looks
/// consistent without a full design system.
class AppColors {
  const AppColors._();

  static const Color background = Color(0xFF070A0F);
  static const Color surface = Color(0xFF111823);
  static const Color surfaceAlt = Color(0xFF0D1420);
  static const Color border = Color(0xFF1E293B);
  static const Color track = Color(0xFF1F2937);
  static const Color textPrimary = Color(0xFFF1F5F9);
  static const Color textMuted = Color(0xFF94A3B8);
  static const Color accent = Color(0xFF34D399);

  /// Satellite (NTN) marker: deliberately not the green that means 5G.
  static const Color satellite = Color(0xFF60A5FA);
  static const Color warning = Color(0xFFFBBF24);
  static const Color danger = Color(0xFFF87171);

  /// Colour for a 0-5 bar reading.
  static Color forBars(int bars) => switch (bars) {
        >= 4 => accent,
        3 => const Color(0xFFA3E635),
        2 => warning,
        1 => danger,
        _ => const Color(0xFF6B7280),
      };
}

const TextStyle monospace = TextStyle(
  fontFamily: 'monospace',
  fontFeatures: [FontFeature.tabularFigures()],
);
