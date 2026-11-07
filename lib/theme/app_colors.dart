import 'package:flutter/material.dart';

/// Small dark palette shared by the widgets, so the RF dashboard looks
/// consistent without a full design system.
class AppColors {
  const AppColors._();

  static const Color background = Color(0xFF08090B);
  static const Color surface = Color(0xFF101215);
  static const Color surfaceAlt = Color(0xFF0B0D10);
  static const Color border = Color(0xFF23262B);
  static const Color track = Color(0xFF26292E);
  static const Color textPrimary = Color(0xFFE8EAED);
  static const Color textMuted = Color(0xFF8A9098);
  static const Color accent = Color(0xFF4FC08D);

  /// One corner radius for every panel. Panels are framed, not rounded off: a
  /// 20-plus radius on a bordered box is what made the page read as a set of
  /// floating cards instead of a readout.
  static const double radius = 4;

  /// Satellite (NTN) marker: deliberately not the green that means 5G.
  static const Color satellite = Color(0xFF60A5FA);
  static const Color warning = Color(0xFFFBBF24);
  static const Color danger = Color(0xFFF87171);

  /// Colour for a 0-5 bar reading.
  ///
  /// Only three inks: the accent while the link is usable, amber when it is
  /// weak, red when it is barely there. The old scale walked through lime as
  /// well, which read as decoration rather than a warning.
  static Color forBars(int bars) => switch (bars) {
        >= 3 => accent,
        2 => warning,
        1 => danger,
        _ => const Color(0xFF5A6069),
      };
}

const TextStyle monospace = TextStyle(
  fontFamily: 'monospace',
  fontFeatures: [FontFeature.tabularFigures()],
);
