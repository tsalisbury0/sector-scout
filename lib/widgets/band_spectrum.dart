import 'package:flutter/material.dart';

import '../models/band_tables.dart';
import '../models/cell_snapshot.dart';
import '../theme/app_colors.dart';

/// A band's downlink block, in MHz.
class BandBlock {
  const BandBlock({
    required this.band,
    required this.low,
    required this.high,
    required this.is5g,
  });

  final int band;
  final double low;
  final double high;
  final bool is5g;

  String get label => bandName(band, is5g: is5g);
  double get width => high - low;
}

/// The block a band occupies on the downlink, from the same tables the app
/// decodes a channel with. Null when the app has no plan for the band.
///
/// LTE channels are 100 kHz apart and NR ones 5 kHz apart, so a band's width is
/// its channel count on that raster — 900 channels is band 66's 90 MHz and n41's
/// 38800 is its 194 MHz.
BandBlock? bandBlock(int band, {required bool is5g}) {
  if (band <= 0) return null;
  final plan = is5g ? nrBandPlans[band] : lteBandPlans[band];
  if (plan == null) return null;
  final step = is5g ? 0.005 : 0.1;
  return BandBlock(
    band: band,
    low: plan.dlLow,
    high: plan.dlLow + (plan.last - plan.first + 1) * step,
    is5g: is5g,
  );
}

/// Every band of the same technology whose downlink block covers [low]–[high],
/// the band the radio reported first.
///
/// A frequency is never only one band. 2115 MHz sits inside band 4's
/// 2110–2155 block, band 10's 2110–2170 and band 66's 2110–2200, so a graph
/// that drew one boundary would be picking one of three correct answers without
/// saying so. The reported band leads, the rest follow narrowest first, which is
/// also the order that makes the nesting visible.
List<BandBlock> bandsCovering(
  double low,
  double high, {
  required bool is5g,
  int? reported,
}) {
  final plans = is5g ? nrBandPlans : lteBandPlans;
  final blocks = <BandBlock>[];
  for (final band in plans.keys) {
    final block = bandBlock(band, is5g: is5g);
    if (block == null) continue;
    if (block.high <= low || block.low >= high) continue;
    blocks.add(block);
  }
  blocks.sort((a, b) {
    final aReported = a.band == reported ? 0 : 1;
    final bReported = b.band == reported ? 0 : 1;
    if (aReported != bReported) return aReported - bReported;
    final byWidth = a.width.compareTo(b.width);
    return byWidth != 0 ? byWidth : a.band.compareTo(b.band);
  });
  return blocks;
}

/// One carrier placed on the dial: where it sits, how wide, and the band block
/// that puts it there.
class SpectrumCarrier {
  const SpectrumCarrier({
    required this.carrier,
    required this.centerMhz,
    required this.block,
  });

  final RadioCarrier carrier;
  final double centerMhz;
  final BandBlock block;

  double get bandwidthMhz => carrier.bandwidthMhz;
  double get lowMhz => centerMhz - bandwidthMhz / 2;
  double get highMhz => centerMhz + bandwidthMhz / 2;
  bool get is5g => block.is5g;
}

/// A carrier placed on the dial, or null when nothing can say where it sits.
///
/// The width is the reader's own `bw`, and the frequency comes from the cell the
/// reader matched to that carrier. A carrier whose cell the scan never saw is
/// left out rather than drawn at a guessed frequency: the graph's whole job is
/// to put the mask where the carrier actually is.
SpectrumCarrier? placeCarrier(SimReading sim, RadioCarrier carrier) {
  if (carrier.bandwidthKhz <= 0) return null;
  final cell = sim.carrierCell(carrier);
  final center = cell?.downlinkMhz;
  if (center == null) return null;
  final is5g = carrier.tech == CellTech.nr;
  final cellBandsList = cell == null ? const <int>[] : cellBands(cell);
  final band = carrier.band > 0
      ? carrier.band
      : (cellBandsList.isEmpty ? 0 : cellBandsList.first);
  final block = bandBlock(band, is5g: is5g);
  if (block == null) return null;
  return SpectrumCarrier(carrier: carrier, centerMhz: center, block: block);
}

/// Carriers that can share one chart.
///
/// Two of them belong together when their channel blocks touch, so an
/// aggregated 2115 + 2145 pair draws as one graph while a band 2 anchor and an
/// n41 leg — hundreds of MHz apart — get a chart each.
List<List<SpectrumCarrier>> clusterCarriers(List<SpectrumCarrier> carriers) {
  final ordered = [...carriers]..sort((a, b) => a.lowMhz.compareTo(b.lowMhz));
  final clusters = <List<SpectrumCarrier>>[];
  for (final carrier in ordered) {
    List<SpectrumCarrier>? home;
    for (final cluster in clusters) {
      if (cluster.any((member) => _together(member, carrier))) {
        home = cluster;
        break;
      }
    }
    if (home != null) {
      home.add(carrier);
    } else {
      clusters.add([carrier]);
    }
  }
  return clusters;
}

/// Whether two carriers belong on one chart: the same band, or blocks and
/// channels that overlap. Two 10 MHz carriers on band 66 are 30 MHz apart and
/// still share the block the chart is drawn on.
bool _together(SpectrumCarrier a, SpectrumCarrier b) {
  if (a.block.band == b.block.band && a.is5g == b.is5g) return true;
  if (a.block.low < b.block.high && b.block.low < a.block.high) return true;
  return a.lowMhz <= b.highMhz && b.lowMhz <= a.highMhz;
}

/// The spectrum each carrier is sitting in, with the LTE transmit mask across
/// its channel and every band block that channel falls inside.
///
/// Only the privileged reader names a carrier's band and width, so this is the
/// one place the app can draw a carrier where it really is: a 10 MHz band 66
/// channel at 2115 MHz is a tenth of band 66's block, a fifth of band 4's, and
/// the same channel is also inside band 10.
class BandSpectrum extends StatelessWidget {
  const BandSpectrum({super.key, required this.sim});

  final SimReading sim;

  @override
  Widget build(BuildContext context) {
    final carriers = <SpectrumCarrier>[
      for (final carrier in sim.carriers)
        ?placeCarrier(sim, carrier),
    ];
    if (carriers.isEmpty) return const SizedBox.shrink();

    final clusters = clusterCarriers(carriers);
    return Column(
      children: [
        for (var i = 0; i < clusters.length; i++) ...[
          if (i > 0) const SizedBox(height: 10),
          _SpectrumPanel(carriers: clusters[i]),
        ],
      ],
    );
  }
}

class _SpectrumPanel extends StatelessWidget {
  const _SpectrumPanel({required this.carriers});

  final List<SpectrumCarrier> carriers;

  /// Six rows is what fits before the rails outgrow the plot they explain.
  static const int _maxBands = 6;

  @override
  Widget build(BuildContext context) {
    final bands = <BandBlock>[];
    for (final carrier in carriers) {
      for (final band in bandsCovering(
        carrier.lowMhz,
        carrier.highMhz,
        is5g: carrier.is5g,
        reported: carrier.block.band,
      )) {
        final known = bands.any(
          (seen) => seen.band == band.band && seen.is5g == band.is5g,
        );
        if (!known && bands.length < _maxBands) bands.add(band);
      }
    }
    if (bands.isEmpty) bands.add(carriers.first.block);

    var low = bands.first.low;
    var high = bands.first.high;
    var carrierLow = carriers.first.lowMhz;
    var carrierHigh = carriers.first.highMhz;
    for (final band in bands) {
      if (band.low < low) low = band.low;
      if (band.high > high) high = band.high;
    }
    for (final carrier in carriers) {
      if (carrier.lowMhz < carrierLow) carrierLow = carrier.lowMhz;
      if (carrier.highMhz > carrierHigh) carrierHigh = carrier.highMhz;
    }
    if (carrierLow < low) low = carrierLow;
    if (carrierHigh > high) high = carrierHigh;

    final margin = (high - low) * 0.02;
    const plotHeight = 96.0;
    const bandRow = 14.0;
    const axisHeight = 20.0;
    final height = plotHeight + 8 + bands.length * bandRow + axisHeight;

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(AppColors.radius),
      ),
      padding: const EdgeInsets.fromLTRB(8, 10, 10, 6),
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: CustomPaint(
          painter: _SpectrumPainter(
            carriers: carriers,
            bands: bands,
            low: low - margin,
            high: high + margin,
            plotHeight: plotHeight,
            bandRow: bandRow,
            axisHeight: axisHeight,
          ),
        ),
      ),
    );
  }
}

class _SpectrumPainter extends CustomPainter {
  _SpectrumPainter({
    required this.carriers,
    required this.bands,
    required this.low,
    required this.high,
    required this.plotHeight,
    required this.bandRow,
    required this.axisHeight,
  });

  final List<SpectrumCarrier> carriers;
  final List<BandBlock> bands;
  final double low;
  final double high;
  final double plotHeight;
  final double bandRow;
  final double axisHeight;

  static const double _gutter = 26;
  static const double _top = 8;
  static const double _floorDb = -60;
  static const double _ceilingDb = 5;

  /// The out-of-band floor an LTE carrier has to stay under.
  static const double _limitDb = -45;

  static const Color _grid = Color(0x14FFFFFF);

  @override
  void paint(Canvas canvas, Size size) {
    final left = _gutter;
    final right = size.width;
    double x(double mhz) => left + (mhz - low) / (high - low) * (right - left);
    double y(double db) =>
        _top + (_ceilingDb - db) / (_ceilingDb - _floorDb) * plotHeight;
    final bottom = _top + plotHeight;

    final grid = Paint()
      ..color = _grid
      ..strokeWidth = 1;
    for (final db in const <double>[0, -20, -40, -60]) {
      canvas.drawLine(Offset(left, y(db)), Offset(right, y(db)), grid);
      _text(
        canvas,
        db.toInt().toString(),
        Offset(1, y(db) - 4),
        size: 8,
        color: AppColors.textMuted,
      );
    }

    // The emission limit, which is what the mask is shaped against.
    _dash(canvas, Offset(left, y(_limitDb)), Offset(right, y(_limitDb)));
    _text(
      canvas,
      '\u221245 dBc',
      Offset(right - 34, y(_limitDb) - 9),
      size: 8,
      color: AppColors.textMuted,
    );

    for (final carrier in carriers) {
      _carrier(canvas, carrier, x, y, bottom);
    }

    var rowTop = bottom + 8;
    for (final band in bands) {
      final active = carriers.any(
        (carrier) =>
            carrier.block.band == band.band && carrier.is5g == band.is5g,
      );
      final rect = Rect.fromLTRB(
        x(band.low),
        rowTop,
        x(band.high),
        rowTop + bandRow - 3,
      );
      final shape = RRect.fromRectAndRadius(rect, const Radius.circular(2));
      final ink = active ? AppColors.accent : AppColors.textMuted;
      canvas.drawRRect(
        shape,
        Paint()
          ..color = active
              ? AppColors.accent.withValues(alpha: 0.18)
              : AppColors.border.withValues(alpha: 0.55),
      );
      canvas.drawRRect(
        shape,
        Paint()
          ..color = active ? AppColors.accent : AppColors.border
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
      _text(
        canvas,
        band.label,
        Offset(rect.left + 4, rect.top + 3),
        size: 8.5,
        color: ink,
        bold: true,
      );
      final span = '${_mhz(band.low)}\u2013${_mhz(band.high)}';
      final spanWidth = _measure(span, 8);
      if (rect.width > spanWidth + 34) {
        _text(
          canvas,
          span,
          Offset(rect.right - spanWidth - 4, rect.top + 3.5),
          size: 8,
          color: AppColors.textMuted,
        );
      }
      rowTop += bandRow;
    }

    // The dial itself: ticks on the same raster as the blocks above.
    final step = _tickStep(high - low);
    for (var mhz = (low / step).ceil() * step; mhz <= high; mhz += step) {
      final tick = x(mhz);
      canvas.drawLine(Offset(tick, rowTop), Offset(tick, rowTop + 3), grid);
      _text(
        canvas,
        _mhz(mhz),
        Offset(tick - 9, rowTop + 4),
        size: 8,
        color: AppColors.textMuted,
      );
    }
    _text(
      canvas,
      'MHz',
      Offset(right - 22, rowTop + 4),
      size: 8,
      color: AppColors.textMuted,
    );
  }

  /// One carrier: the mask across its channel, its edges, and where other
  /// carriers in the same chart sit relative to it.
  void _carrier(
    Canvas canvas,
    SpectrumCarrier carrier,
    double Function(double) x,
    double Function(double) y,
    double bottom,
  ) {
    final occupied = carrier.bandwidthMhz * 0.45;
    final shoulder = carrier.bandwidthMhz / 2 + 2;
    final mask = Path()
      ..addPolygon([
        Offset(x(carrier.centerMhz - shoulder), y(_limitDb)),
        Offset(x(carrier.centerMhz - occupied), y(0)),
        Offset(x(carrier.centerMhz + occupied), y(0)),
        Offset(x(carrier.centerMhz + shoulder), y(_limitDb)),
      ], true);

    canvas.drawPath(
      mask,
      Paint()
        ..color = AppColors.accent.withValues(alpha: 0.20)
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      mask,
      Paint()
        ..color = AppColors.accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );

    // The channel edges, which are the carrier's width on the dial.
    _dash(
      canvas,
      Offset(x(carrier.lowMhz), y(_limitDb)),
      Offset(x(carrier.lowMhz), bottom),
    );
    _dash(
      canvas,
      Offset(x(carrier.highMhz), y(_limitDb)),
      Offset(x(carrier.highMhz), bottom),
    );

    final label =
        '${carrier.block.label} \u00b7 ${_mhz(carrier.centerMhz)} MHz '
        '\u00b7 ${_mhz(carrier.bandwidthMhz)} MHz';
    _text(
      canvas,
      label,
      Offset(x(carrier.centerMhz) - _measure(label, 8.5) / 2, bottom - 11),
      size: 8.5,
      color: AppColors.accent,
      bold: true,
    );
  }

  void _dash(Canvas canvas, Offset from, Offset to) {
    final paint = Paint()
      ..color = AppColors.textMuted.withValues(alpha: 0.45)
      ..strokeWidth = 1;
    const dash = 3.0;
    const gap = 3.0;
    final length = (to - from).distance;
    if (length <= 0) return;
    final step = (to - from) / length;
    for (var travelled = 0.0; travelled < length; travelled += dash + gap) {
      final start = from + step * travelled;
      final end = from + step * (travelled + dash).clamp(0, length);
      canvas.drawLine(start, end, paint);
    }
  }

  double _measure(String value, double size) {
    final painter = TextPainter(
      text: TextSpan(text: value, style: TextStyle(fontSize: size, height: 1)),
      textDirection: TextDirection.ltr,
    )..layout();
    return painter.width;
  }

  void _text(
    Canvas canvas,
    String value,
    Offset at, {
    required double size,
    required Color color,
    bool bold = false,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: value,
        style: TextStyle(
          fontSize: size,
          height: 1,
          color: color,
          fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
          letterSpacing: 0.2,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, at);
  }

  /// 2110 → "2110", 2112.5 → "2112.5".
  static String _mhz(double mhz) {
    final rounded = double.parse(mhz.toStringAsFixed(1));
    return rounded == rounded.roundToDouble()
        ? rounded.toStringAsFixed(0)
        : rounded.toStringAsFixed(1);
  }

  /// A tick spacing that fits a phone's width at both 50 and 700 MHz.
  static double _tickStep(double span) {
    if (span <= 6) return 1;
    if (span <= 16) return 2;
    if (span <= 40) return 5;
    if (span <= 110) return 10;
    if (span <= 260) return 50;
    return 100;
  }

  @override
  bool shouldRepaint(covariant _SpectrumPainter old) =>
      old.low != low ||
      old.high != high ||
      old.plotHeight != plotHeight ||
      old.carriers != carriers ||
      old.bands != bands;
}
