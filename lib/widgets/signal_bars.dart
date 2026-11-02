import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// The familiar five-bar signal meter, animated as the reading changes.
class SignalBars extends StatelessWidget {
  const SignalBars({
    super.key,
    required this.bars,
    this.height = 56,
    this.barWidth = 10,
    this.gap = 5,
    this.color,
  });

  /// Number of filled bars, 0-5.
  final int bars;
  final double height;
  final double barWidth;
  final double gap;

  /// Override the automatic colour (used for the dimmed empty state).
  final Color? color;

  /// Relative heights, shortest first.
  static const List<double> _fractions = [0.3, 0.46, 0.62, 0.8, 1.0];

  @override
  Widget build(BuildContext context) {
    final active = color ?? AppColors.forBars(bars);
    final filled = bars.clamp(0, _fractions.length);

    return Semantics(
      label: 'Signal strength: $filled of ${_fractions.length} bars',
      child: SizedBox(
        height: height,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (var i = 0; i < _fractions.length; i++)
              Padding(
                padding: EdgeInsets.only(
                  right: i == _fractions.length - 1 ? 0 : gap,
                ),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOutCubic,
                  width: barWidth,
                  height: height * _fractions[i],
                  decoration: BoxDecoration(
                    color: i < filled ? active : AppColors.track,
                    borderRadius: BorderRadius.circular(barWidth / 2),
                    boxShadow: i < filled
                        ? [
                            BoxShadow(
                              color: active.withValues(alpha: 0.35),
                              blurRadius: 10,
                              spreadRadius: -2,
                            ),
                          ]
                        : null,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
