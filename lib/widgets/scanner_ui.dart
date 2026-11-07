import 'package:flutter/material.dart';

import '../models/cell_snapshot.dart';
import '../theme/app_colors.dart';
import 'note_help.dart';
import 'signal_bars.dart';
import 'tech_badge.dart';

/// The phone's readout, drawn as an instrument rather than a stack of cards.
///
/// The page is one reading: a large level figure with its meter beside it, a
/// strip that switches which block of numbers is on screen, and rows that line
/// their values up on a dotted leader. Nothing here is a floating card — panels
/// are separated by hairlines so the eye follows the numbers, not the boxes.

/// The legs a slot's header draws, in order, with the caption each one carries
/// once the slot has more than one.
///
/// Shared with the caller that records the history, so a trace is kept for
/// exactly the figures that are on screen: the LTE anchor, the NR secondary and
/// any SDL layer.
List<(String, CellTower)> headerLegs(SimReading sim) {
  final lte = sim.lteServing;
  final nr = sim.nrServing;
  final serving = sim.serving;
  return [
    if (sim.isNsa && lte != null && nr != null) ...[
      ('LTE anchor', lte),
      ('5G NR', nr),
    ] else if (serving != null)
      (sim.isSa ? '5G NR' : 'LTE', serving),
    for (var i = 0; i < sim.lteSecondaries.length; i++)
      (
        sim.lteSecondaries.length == 1 ? 'LTE SDL' : 'LTE SDL ${i + 1}',
        sim.lteSecondaries[i],
      ),
  ];
}

/// One SIM's current serving reading.
///
/// An NSA pair reads as two stacked figures, each with its own meter; SA and
/// LTE read as one. A single radio carries no caption, because the mode line in
/// the header already says what it is — only a pair needs the legs named.
class SimHeaderCard extends StatelessWidget {
  const SimHeaderCard({
    super.key,
    required this.sim,
    required this.dual,
    required this.capturedAt,
    this.carrierName,
    this.traces,
  });

  final SimReading sim;
  final bool dual;
  final DateTime capturedAt;

  /// Brand resolved from the PLMN; falls back to the SIM's own name.
  final String? carrierName;

  /// Recent levels of every leg, oldest first, keyed by the caption
  /// [headerLegs] gives that leg, so each figure can carry its own trend.
  /// Null when no history is kept.
  final Map<String, List<int?>>? traces;

  @override
  Widget build(BuildContext context) {
    final nr = sim.nrServing;
    final badge = badgeForSim(sim);
    final name =
        carrierName ?? (sim.carrierName.isEmpty ? sim.label : sim.carrierName);

    final legs = headerLegs(sim);
    // Green only while the NR leg is really up: the platform keeps saying NSA
    // for a while after the carrier has gone.
    final attached = (sim.isNsa && nr != null) || sim.nrConnected;
    // A copy of each list, so every painter is handed a different instance each
    // build and repaints as the live history grows; the same list would look
    // unchanged to it.
    final traces = this.traces == null
        ? null
        : {
            for (final entry in this.traces!.entries)
              entry.key: List<int?>.of(entry.value),
          };


    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(
          top: BorderSide(color: AppColors.border),
          bottom: BorderSide(color: AppColors.border),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Flexible(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              if (sim.isSatellite) ...[
                const SizedBox(width: 7),
                const SatelliteTag(),
              ] else if (badge != null) ...[
                const SizedBox(width: 7),
                TechBadge(label: badge),
              ],
              if (dual) ...[
                const SizedBox(width: 7),
                _SlotTag(label: sim.label),
              ],
              const Spacer(),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    sim.modeLabel,
                    style: TextStyle(
                      fontSize: 9.5,
                      letterSpacing: 0.9,
                      fontWeight: FontWeight.w600,
                      // A slot whose 5G leg is down for a VoLTE call is not
                      // lit, however the platform still labels it.
                      color: attached && !sim.nsaReleasedForCall
                          ? AppColors.accent
                          : AppColors.textMuted,
                    ),
                  ),
                  const SizedBox(width: 2),
                  NoteHelp(_modeNote(sim), label: 'Network mode'),
                  // The voice path follows the help, so the row reads as one
                  // line: what the link is, then what is carrying voice.
                  _ImsLine(sim: sim),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          for (var i = 0; i < legs.length; i++) ...[
            if (i > 0)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 7),
                child: Divider(
                  height: 1,
                  thickness: 1,
                  color: AppColors.border,
                ),
              ),
            _LegReadout(
              // A single leg needs no caption; a pair does.
              label: legs.length > 1 ? legs[i].$1 : null,
              cell: legs[i].$2,
            ),
            // Each leg traces the reading printed directly above it, and holds
            // its own range: an anchor at -107 and a secondary at -117 do not
            // share one, and a footer range under the lower figure would read
            // as that figure's.
            if ((traces?[legs[i].$1]?.length ?? 0) > 1) ...[
              const SizedBox(height: 7),
              TrendSparkline(
                samples: traces![legs[i].$1]!,
                color: AppColors.forBars(legs[i].$2.bars),
              ),
              if (_held(traces[legs[i].$1]) case final held?)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(
                    'HOLD ${held.$1}…${held.$2}',
                    style: monospace.copyWith(
                      fontSize: 9,
                      color: AppColors.textMuted,
                    ),
                  ),
                ),
            ],
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              Text(
                _clock(capturedAt),
                style: monospace.copyWith(
                  fontSize: 9.5,
                  color: AppColors.textMuted,
                ),
              ),
              const Spacer(),
              Text(
                '${sim.cells.length} cell${sim.cells.length == 1 ? '' : 's'}',
                style: monospace.copyWith(
                  fontSize: 9.5,
                  color: AppColors.textMuted,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One radio's level: the figure first, the meter to its right.
class _LegReadout extends StatelessWidget {
  const _LegReadout({required this.label, required this.cell});

  /// Null when the slot runs a single radio.
  final String? label;
  final CellTower cell;

  @override
  Widget build(BuildContext context) {
    final bars = cell.bars;
    final color = AppColors.forBars(bars);
    final label = this.label;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (label != null) ...[
                Text(
                  label.toUpperCase(),
                  style: const TextStyle(
                    fontSize: 8.5,
                    letterSpacing: 1,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textMuted,
                  ),
                ),
                const SizedBox(height: 3),
              ],
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    cell.dbm?.toString() ?? '—',
                    style: monospace.copyWith(
                      fontSize: 38,
                      height: 1,
                      color: color,
                    ),
                  ),
                  const SizedBox(width: 5),
                  const Text(
                    'dBm',
                    style: TextStyle(fontSize: 10, color: AppColors.textMuted),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            SignalBars(bars: bars, height: 34, barWidth: 6, gap: 3),
            const SizedBox(height: 3),
            Text(
              SignalQuality.label(bars),
              style: TextStyle(fontSize: 10, color: color),
            ),
          ],
        ),
      ],
    );
  }
}

class _SlotTag extends StatelessWidget {
  const _SlotTag({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: const TextStyle(
        fontSize: 9,
        letterSpacing: 0.4,
        color: AppColors.textMuted,
      ),
    );
  }
}

/// The strip that switches which block of the reading is on screen.
class ScannerTabs extends StatelessWidget {
  const ScannerTabs({
    super.key,
    required this.tabs,
    required this.index,
    required this.onTap,
  });

  final List<String> tabs;
  final int index;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var i = 0; i < tabs.length; i++)
            Padding(
              padding: EdgeInsets.only(left: i == 0 ? 0 : 20),
              child: InkWell(
                onTap: () => onTap(i),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        tabs[i].toUpperCase(),
                        style: TextStyle(
                          fontSize: 10,
                          letterSpacing: 1,
                          fontWeight: FontWeight.w600,
                          color: i == index
                              ? AppColors.textPrimary
                              : AppColors.textMuted,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Container(
                        height: 2,
                        width: 20,
                        color: i == index
                            ? AppColors.accent
                            : Colors.transparent,
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A section caption with the hairline running out to the right.
class ScannerSection extends StatelessWidget {
  const ScannerSection(this.title, {super.key, this.note});

  final String title;

  /// The explanation behind this section's circled question mark.
  final String? note;

  @override
  Widget build(BuildContext context) {
    final note = this.note;
    return Row(
      children: [
        Text(
          title.toUpperCase(),
          style: const TextStyle(
            fontSize: 9.5,
            letterSpacing: 1,
            fontWeight: FontWeight.w600,
            color: AppColors.textMuted,
          ),
        ),
        const SizedBox(width: 8),
        const Expanded(
          child: Divider(height: 1, thickness: 1, color: AppColors.border),
        ),
        if (note != null) ...[
          const SizedBox(width: 6),
          NoteHelp(note, label: title),
        ],
      ],
    );
  }
}

/// Label-on-the-left, value-on-the-right rows joined by a dotted leader.
class ScannerRows extends StatelessWidget {
  const ScannerRows({super.key, required this.entries});

  final List<MapEntry<String, String>> entries;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();
    return Column(
      children: [
        for (final entry in entries)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Text(
                  entry.key,
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: AppColors.textMuted,
                  ),
                ),
                const SizedBox(width: 8),
                const Expanded(child: _DottedLeader()),
                const SizedBox(width: 8),
                Text(
                  entry.value,
                  style: monospace.copyWith(
                    fontSize: 12,
                    color: AppColors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// The leader itself: a dashed rule, drawn rather than dotted with text.
class _DottedLeader extends StatelessWidget {
  const _DottedLeader();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(double.infinity, 1),
      painter: const _LeaderPainter(),
    );
  }
}

class _LeaderPainter extends CustomPainter {
  const _LeaderPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppColors.border
      ..strokeWidth = 1;
    for (var x = 0.0; x < size.width; x += 4) {
      canvas.drawLine(Offset(x, 0.5), Offset(x + 1.5, 0.5), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// The lowest and highest level heard this session.
(int, int)? _held(List<int?>? trace) {
  if (trace == null) return null;
  int? low;
  int? high;
  for (final sample in trace) {
    if (sample == null) continue;
    if (low == null || sample < low) low = sample;
    if (high == null || sample > high) high = sample;
  }
  if (low == null || high == null) return null;
  return (low, high);
}

/// The level over the last minute or so, scaled to its own range.
///
/// The window is never narrower than 12 dB, so a link that barely moves draws a
/// flat line instead of magnifying a couple of dB of noise into a cliff.
class TrendSparkline extends StatelessWidget {
  const TrendSparkline({
    super.key,
    required this.samples,
    required this.color,
    this.height = 26,
  });

  /// Oldest first; a null is a gap where nothing was heard.
  final List<int?> samples;
  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _TracePainter(samples: samples, color: color),
      ),
    );
  }
}

class _TracePainter extends CustomPainter {
  _TracePainter({required this.samples, required this.color});

  final List<int?> samples;
  final Color color;

  static const Color _grid = Color(0x14FFFFFF);

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.length < 2) return;
    var low = 1 << 20;
    var high = -(1 << 20);
    for (final sample in samples) {
      if (sample == null) continue;
      if (sample < low) low = sample;
      if (sample > high) high = sample;
    }
    if (low > high) return;
    final span = (high - low) < 12 ? 12.0 : (high - low).toDouble();
    final top = (high + low) / 2 - span / 2;
    double y(int dbm) => size.height - ((dbm - top) / span) * size.height;
    double x(int index) => index * size.width / (samples.length - 1);

    canvas.drawLine(
      Offset(0, size.height - 0.5),
      Offset(size.width, size.height - 0.5),
      Paint()
        ..color = _grid
        ..strokeWidth = 1,
    );

    final line = Path();
    var started = false;
    for (var i = 0; i < samples.length; i++) {
      final sample = samples[i];
      if (sample == null) {
        started = false;
        continue;
      }
      if (!started) {
        line.moveTo(x(i), y(sample));
        started = true;
      } else {
        line.lineTo(x(i), y(sample));
      }
    }
    canvas.drawPath(
      line,
      Paint()
        ..color = color
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round,
    );

    // The newest reading, marked so the eye lands on it first.
    for (var i = samples.length - 1; i >= 0; i--) {
      final sample = samples[i];
      if (sample == null) continue;
      canvas.drawRect(
        Rect.fromLTWH(x(i) - 1.5, y(sample) - 1.5, 3, 3),
        Paint()..color = color,
      );
      break;
    }
  }

  @override
  bool shouldRepaint(covariant _TracePainter oldDelegate) =>
      oldDelegate.samples != samples || oldDelegate.color != color;
}

/// The aggregated downlink drawn to scale: one segment per component carrier,
/// each as wide as its share of the total.
///
/// Only the privileged reader exposes component carriers, so this is the one
/// view that says at a glance whether the link is a single 10 MHz layer or a
/// hundred-megahertz pile-up.
class AggregationBar extends StatelessWidget {
  const AggregationBar({super.key, required this.carriers, this.height = 18});

  final List<RadioCarrier> carriers;
  final double height;

  static const Color _nr = Color(0x594FC08D);
  static const Color _nrAlt = Color(0x2E4FC08D);
  static const Color _lte = Color(0x3D8A9098);
  static const Color _lteAlt = Color(0x248A9098);

  @override
  Widget build(BuildContext context) {
    final total = carriers.fold<int>(
      0,
      (sum, carrier) => sum + carrier.bandwidthKhz,
    );
    if (carriers.isEmpty || total <= 0) return const SizedBox.shrink();

    var nrSeen = false;
    var lteSeen = false;
    final segments = <Widget>[];
    for (final carrier in carriers) {
      final isNr = carrier.tech == CellTech.nr;
      final Color fill;
      if (isNr) {
        fill = nrSeen ? _nrAlt : _nr;
        nrSeen = true;
      } else {
        fill = lteSeen ? _lteAlt : _lte;
        lteSeen = true;
      }
      final share = carrier.bandwidthKhz / total;
      segments.add(
        Expanded(
          flex: carrier.bandwidthKhz <= 0 ? 1 : carrier.bandwidthKhz,
          child: Container(
            height: height,
            color: fill,
            alignment: Alignment.center,
            child: share < 0.16
                ? null
                : Text(
                    carrier.bandLabel ?? (isNr ? 'NR' : 'LTE'),
                    maxLines: 1,
                    style: const TextStyle(
                      fontSize: 8,
                      letterSpacing: 0.5,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
          ),
        ),
      );
    }

    return Row(
      children: [
        for (var i = 0; i < segments.length; i++) ...[
          if (i > 0) const SizedBox(width: 1),
          segments[i],
        ],
      ],
    );
  }
}

/// The one path carrying voice: VoLTE, VoNR, Wi-Fi calling, or CS.
///
/// One, never a list. A phone registers a single voice path, and the carrier
/// bundle's own flags are capability rather than use — a network that offers
/// both VoLTE and Wi-Fi calling sets both, which is why drawing them together
/// read as if the slot were on both at once. The accent marks a path that a
/// call is up on; idle, the registered path stays muted.
class _ImsLine extends StatelessWidget {
  const _ImsLine({required this.sim});

  final SimReading sim;

  @override
  Widget build(BuildContext context) {
    final path = sim.ims.activeLabel ?? (sim.inCall ? sim.voiceLabel : null);
    if (path == null) return const SizedBox.shrink();
    // Lit only while a call is up, and lit properly: a soft halo behind the
    // label is the one glow on the page, so it reads as "in use now" rather
    // than as another static caption.
    final live = sim.inCall;

    return Padding(
      padding: const EdgeInsets.only(left: 5),
      child: Text(
        // Written the way the carriers write it: VoLTE, VoNR, VoWiFi. The mode
        // chip beside it is the machine's word, this one is the network's.
        path,
        style: TextStyle(
          fontSize: 10.5,
          height: 1.1,
          letterSpacing: 0.3,
          fontWeight: FontWeight.w700,
          color: live ? AppColors.accent : AppColors.textMuted,
          shadows: live
              ? const [
                  Shadow(color: Color(0xB34FC08D), blurRadius: 8),
                  Shadow(color: Color(0x664FC08D), blurRadius: 14),
                ]
              : null,
        ),
      ),
    );
  }
}

/// What the mode chip means, including why it drops to LTE during a call.
String _modeNote(SimReading sim) {
  final mode = switch (sim.mode) {
    NetworkMode.nsa =>
      '5G NSA is a 5G carrier running under the LTE anchor, so the slot has two '
          'legs to report. ',
    NetworkMode.sa => '5G SA is 5G on its own, with no LTE anchor under it. ',
    _ => '',
  };
  final offered = [
    if (sim.ims.volte) 'VoLTE',
    if (sim.ims.vonr) 'VoNR',
    if (sim.ims.vowifi) 'VoWiFi',
  ];
  final capability = offered.isEmpty
      ? ''
      : ' The network offers ${offered.join(', ')}, but only one carries voice '
            'at a time: the small label beside the mode names the one actually '
            'registered.';
  final now = sim.nsaReleasedForCall
      ? ' A VoLTE call is up on LTE now, so the 5G leg is gone until it ends.'
      : '';
  return '$mode'
      '5G NSA is unavailable during VoLTE calls: the secondary carrier is given '
      'up while the call is on LTE, and the platform keeps reporting NR_NSA for '
      'a while after, so the chip drops back to 4G LTE for the duration.'
      '$capability$now';
}

String _clock(DateTime time) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
}
