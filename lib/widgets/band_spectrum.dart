import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/band_tables.dart';
import '../models/band_widths.dart';
import '../models/cell_snapshot.dart';
import '../services/app_settings.dart';
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

/// The block a band occupies on the uplink, or null when it has none.
///
/// A supplemental downlink pairs nothing here, and the bands whose uplink is
/// narrower than their downlink (66, 70, n66) are clamped to their uplink's own
/// top edge instead of being drawn past it. A TDD band shares one block, so its
/// uplink block is its downlink block.
BandBlock? bandUplinkBlock(int band, {required bool is5g}) {
  if (band <= 0) return null;
  final plan = is5g ? nrBandPlans[band] : lteBandPlans[band];
  if (plan == null || plan.ulLow == null) return null;
  final step = is5g ? 0.005 : 0.1;
  var high = plan.ulLow! + (plan.last - plan.first + 1) * step;
  final top = plan.ulHigh;
  if (top != null && high > top) high = top;
  return BandBlock(band: band, low: plan.ulLow!, high: high, is5g: is5g);
}

/// Every MFBI alias of the reported band, wherever in that band the channel
/// [low]–[high] sits.
///
/// A frequency is not only one band, but only its MFBI aliases are the same
/// spectrum. 2115 MHz sits inside band 66's 2110–2200 block, and also inside
/// band 4's 2110–2155 and band 10's 2110–2170 — all three pair a 400 MHz duplex
/// spacing, so the channel really is all three. That stays true at 2175 MHz,
/// past the end of bands 4 and 10: the rails are the numbering the spectrum
/// carries, not just the part of it this channel overlaps. Band 65 overlaps
/// band 66's downlink while pairing a different uplink, and band 9 overlaps
/// band 3 without sharing its uplink: those are other bands, not aliases, and
/// the graph does not claim the channel belongs to them.
List<BandBlock> bandsCovering(
  double low,
  double high, {
  required bool is5g,
  int? reported,
  bool uplink = false,
}) {
  final plans = is5g ? nrBandPlans : lteBandPlans;
  final reportedPlan = reported == null ? null : plans[reported];
  final reportedBlock = reported == null
      ? null
      : (uplink
            ? bandUplinkBlock(reported, is5g: is5g)
            : bandBlock(reported, is5g: is5g));
  final blocks = <BandBlock>[];
  for (final band in plans.keys) {
    final block = uplink
        ? bandUplinkBlock(band, is5g: is5g)
        : bandBlock(band, is5g: is5g);
    if (block == null) continue;
    if (reportedPlan == null || reportedBlock == null) {
      // No reported band to be an alias of, so only what the channel touches
      // is drawn.
      if (block.high <= low || block.low >= high) continue;
    } else if (!_mfbiCompatible(reported!, reportedPlan, band, plans[band]) ||
        block.high <= reportedBlock.low ||
        block.low >= reportedBlock.high) {
      // An alias is the same licensed spectrum, so its rail stays wherever
      // inside the reported band the channel sits — 2175 MHz is band 66 only,
      // but bands 4 and 10 are what that spectrum is numbered elsewhere.
      continue;
    }
    blocks.add(block);
  }
  // Narrowest first, widest last: the rails stack outward from the band that
  // fits tightest to the one that covers everything, so the nesting reads
  // top to bottom instead of jumping around.
  blocks.sort((a, b) {
    final byWidth = a.width.compareTo(b.width);
    return byWidth != 0 ? byWidth : a.band.compareTo(b.band);
  });
  return blocks;
}

/// Whether two bands are the same spectrum under different numbers — an MFBI
/// alias — rather than two bands that merely overlap.
///
/// The duplex spacing is what decides it: band 66, 4 and 10 all sit 400 MHz
/// above their uplink, so one channel is all three. Band 65 sits 190 MHz above
/// its own, which makes it a different band however much of the downlink it
/// shares.
bool _mfbiCompatible(
  int reportedBand,
  BandPlan? reported,
  int candidateBand,
  BandPlan? candidate,
) {
  if (reported == null || candidate == null) return false;
  if (reported.isTdd != candidate.isTdd) return false;
  if (reported.isDlOnly != candidate.isDlOnly) return false;
  // Band 106 and band 8 are configured as MFBI aliases on the utility
  // network's SIBs even though their duplex spacing differs (39 vs 45 MHz):
  // the relationship is published, not derivable from the blocks.
  final pair = {reportedBand, candidateBand};
  if (pair.contains(8) && pair.contains(106) && pair.length == 2) {
    return true;
  }
  final a = reported.uplinkOffset;
  final b = candidate.uplinkOffset;
  if (a == null || b == null) return false;
  return (a - b).abs() < 0.001;
}

/// One carrier placed on the dial: where it sits, how wide, the band block that
/// puts it there, and the role the radio is giving it.
class SpectrumCarrier {
  SpectrumCarrier({
    required this.carrier,
    required this.centerMhz,
    required this.block,
    this.role = 'CA',
    this.uplinkMhz,
    this.uplinkBlock,
    this.widthMhz,
    this.levelDbm,
    this.shiftMhz = 0,
  });

  final RadioCarrier carrier;

  /// Downlink centre, or the uplink centre on a copy drawn as the uplink.
  final double centerMhz;

  /// The band block for the direction this copy is drawn in.
  final BandBlock block;

  /// `PCC`, `SDL`, `CA`, `CA 2` or `5G` — what the layer is doing in the
  /// aggregate, which is what the selector buttons are labelled with.
  String role;

  /// Uplink centre from the matched cell, or null when the band pairs none.
  final double? uplinkMhz;

  /// The uplink block of the same band, when the band has one.
  final BandBlock? uplinkBlock;

  /// The width to draw when it is not the modem's own `bw`.
  ///
  /// Band 106 is one case: the modem reports the band's 5 MHz block while the
  /// utility network runs 3 MHz at 938.0 MHz and 1.4 MHz elsewhere, and a mask
  /// drawn 5 MHz wide would claim spectrum the carrier does not occupy. Band 30
  /// with the RB-limited setting on is the other: 7 MHz of its 10 MHz downlink.
  final double? widthMhz;

  /// How far the drawn downlink mask sits from [centerMhz].
  ///
  /// Band 30's RB limit trims the bottom of the licensed block, so the mask
  /// keeps the block's top edge instead of staying centred on the channel.
  final double shiftMhz;

  /// The received level of the cell feeding this carrier, in dBm — the height
  /// the downlink mask is drawn at.
  final int? levelDbm;

  /// Where the mask is centred: the channel's own centre unless the band's
  /// drawn downlink is pinned to one edge of it.
  double get maskCenterMhz => centerMhz + shiftMhz;

  double get bandwidthMhz => widthMhz ?? carrier.bandwidthMhz;
  double get lowMhz => maskCenterMhz - bandwidthMhz / 2;
  double get highMhz => maskCenterMhz + bandwidthMhz / 2;
  bool get is5g => block.is5g;

  /// A TDD layer has one block for both directions, so its downlink and uplink
  /// graphs would be the same chart twice. It gets one, labelled as both.
  bool get isTdd {
    final uplink = uplinkMhz;
    return uplink != null && (uplink - centerMhz).abs() < 0.005;
  }

  /// The same carrier re-centred on its uplink, for the uplink graph.
  ///
  /// Band 30's narrower mask is a downlink limit; the uplink keeps the modem's
  /// own width, so it is drawn without one.
  SpectrumCarrier asUplink() => SpectrumCarrier(
    carrier: carrier,
    centerMhz: uplinkMhz!,
    block: uplinkBlock!,
    role: role,
    widthMhz: block.band == 30 ? null : widthMhz,
    levelDbm: levelDbm,
  );

  /// `PCC B2` — the one line a selector button carries.
  String get buttonLabel => '$role ${block.label}';
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
  final drawn = drawnDownlinkWidth(
    band: band,
    centerMhz: center,
    is5g: is5g,
    reportedMhz: carrier.bandwidthMhz,
  );
  return SpectrumCarrier(
    carrier: carrier,
    centerMhz: center,
    block: block,
    role: _roleFor(sim, carrier, cell),
    uplinkMhz: cell?.uplinkMhz,
    uplinkBlock: bandUplinkBlock(band, is5g: is5g),
    widthMhz: drawn?.width,
    shiftMhz: drawn?.shift ?? 0,
    // The same level the Carriers card prints, not the RSRP beside it: the two
    // differ by a few dB on most radios, and a graph that disagreed with the
    // number directly above it read as the wrong cell.
    levelDbm: cell?.dbm,
  );
}

/// What a layer is doing: the anchor, a supplemental downlink, or one of the
/// aggregated carriers. An NR layer names itself.
String _roleFor(SimReading sim, RadioCarrier carrier, CellTower? cell) {
  // A downlink with no uplink is a supplemental one: band 29's whole block, or
  // the 2180–2200 tail of 66 whose uplink would sit above 1780.
  if (cell != null && cell.uplinkMhz == null) return 'SDL';
  if (carrier.tech == CellTech.nr) return '5G';
  if (lteBandPlans[carrier.band]?.isDlOnly ?? false) return 'SDL';
  final serving = sim.lteServing;
  if (cell != null && serving != null && _sameCell(cell, serving)) {
    return 'PCC';
  }
  return 'CA';
}

/// The same cell, compared by identity first and by what it broadcasts second:
/// the scan and the carrier match can hand back different copies of one cell.
bool _sameCell(CellTower a, CellTower b) {
  if (identical(a, b)) return true;
  if (a.pci == null || a.pci != b.pci) return false;
  if (a.tech != b.tech) return false;
  final adl = a.downlinkMhz;
  final bdl = b.downlinkMhz;
  if (adl == null || bdl == null) return a.bandLabel == b.bandLabel;
  return (adl - bdl).abs() < 0.01;
}

/// Every placed carrier, roles filled in.
///
/// The anchor is the carrier matched to the serving cell. When the reader names
/// no PCI and the match falls back to a band, an anchor can be missed; the first
/// LTE carrier then takes the role, so the buttons always lead with a PCC.
/// Aggregated layers are numbered when there is more than one, since two buttons
/// both reading `CA B66` would say nothing about which is which.
List<SpectrumCarrier> spectrumCarriers(SimReading sim) {
  final placed = <SpectrumCarrier>[
    for (final carrier in sim.carriers) ?placeCarrier(sim, carrier),
  ];
  // Band 106 does not need the privileged reader: one serving cell on the
  // utility network is the whole carrier, so the spectrum stays available
  // when Shizuku is off and there are no component carriers to list.
  if (placed.isEmpty) {
    final cell = sim.lteServing;
    final center = cell?.downlinkMhz;
    final block = bandBlock(106, is5g: false);
    if (cell != null &&
        cell.sharedBands?.contains(106) == true &&
        block != null &&
        center != null) {
      placed.add(
        SpectrumCarrier(
          carrier: const RadioCarrier(
            tech: CellTech.lte,
            band: 106,
            bandwidthKhz: 3000,
          ),
          centerMhz: center,
          block: block,
          role: 'PCC',
          uplinkMhz: cell.uplinkMhz,
          uplinkBlock: bandUplinkBlock(106, is5g: false),
          widthMhz: drawnDownlinkWidth(
            band: 106,
            centerMhz: center,
            is5g: false,
            reportedMhz: 3.0,
          )?.width,
          levelDbm: cell.dbm,
        ),
      );
    }
  }
  if (!placed.any((carrier) => carrier.role == 'PCC')) {
    for (final carrier in placed) {
      if (carrier.carrier.tech == CellTech.lte && carrier.role != 'SDL') {
        carrier.role = 'PCC';
        break;
      }
    }
  }
  final secondaries = placed.where((carrier) => carrier.role == 'CA').length;
  if (secondaries > 1) {
    var number = 1;
    for (final carrier in placed) {
      if (carrier.role == 'CA') carrier.role = 'CA ${number++}';
    }
  }
  return placed;
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

/// The spectrum page: one button per component carrier, the chart for the layer
/// selected, and its uplink directly below.
///
/// Only the privileged reader names a carrier's band and width, so this is the
/// one place the app can draw a carrier where it really is: a 10 MHz band 66
/// channel at 2115 MHz is a tenth of band 66's block, a fifth of band 4's, and
/// the same channel is also inside band 10. The uplink chart puts the same
/// carrier on its transmit frequency, scaled to the transmit power when the
/// radio reports one.
class BandSpectrum extends StatefulWidget {
  const BandSpectrum({super.key, required this.sim});

  final SimReading sim;

  @override
  State<BandSpectrum> createState() => _BandSpectrumState();
}

class _BandSpectrumState extends State<BandSpectrum> {
  int _selected = 0;

  @override
  void didUpdateWidget(covariant BandSpectrum oldWidget) {
    super.didUpdateWidget(oldWidget);
    final count = spectrumCarriers(widget.sim).length;
    if (_selected >= count) _selected = count == 0 ? 0 : count - 1;
  }

  @override
  Widget build(BuildContext context) {
    final carriers = spectrumCarriers(widget.sim);
    if (carriers.isEmpty) return const SizedBox.shrink();

    final selected = carriers[_selected.clamp(0, carriers.length - 1)];
    final clusters = clusterCarriers(carriers);
    final cluster = clusters.firstWhere(
      (members) => members.contains(selected),
      orElse: () => <SpectrumCarrier>[selected],
    );
    // TDD shares its block, so the downlink chart already is the uplink one.
    final tdd = selected.isTdd;
    // Only the anchor gets an uplink chart: a secondary carrier's transmit
    // mask is not something any public API reports, so drawing one would be a
    // guess dressed as a measurement.
    final canUplink =
        !tdd &&
        (selected.role == 'PCC' || selected.role == '5G') &&
        selected.uplinkMhz != null &&
        selected.uplinkBlock != null;
    // The uplink mask belongs to the data connection, not to the traffic: an
    // idle link still sends its signalling, so the mask stays while mobile data
    // is in use and only goes away when there is no connection to draw.
    final dataInUse = widget.sim.dataInUse;
    final txPower = selected.carrier.txPowerDbm;
    final inverse = AppSettings.uplinkInverse;
    final maxTx = maxUplinkDbm(selected.block.band, is5g: selected.is5g);
    final peak = uplinkPeakDbm(
      levelDbm: selected.levelDbm,
      txPowerDbm: txPower,
      inverse: inverse,
      maxDbm: maxTx,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _CarrierSelector(
          carriers: carriers,
          selected: carriers.indexOf(selected),
          onSelected: (index) => setState(() => _selected = index),
        ),
        const SizedBox(height: 10),
        _SpectrumPanel(
          carriers: cluster,
          title: tdd ? 'TDD · DL and UL' : 'Downlink',
          summary: selected,
        ),
        if (!tdd && dataInUse) ...[
          const SizedBox(height: 10),
          if (!canUplink)
            _UplinkAbsentNote(
              message: selected.role.startsWith('CA')
                  ? 'An aggregated layer has no uplink mask here: the uplink '
                        'is drawn for the anchor only.'
                  : 'This layer is a supplemental downlink: its downlink '
                        'has no uplink to pair, so there is no transmit '
                        'spectrum to draw.',
            )
          else
            _SpectrumPanel(
              carriers: [selected.asUplink()],
              uplink: true,
              uplinkPeakDbm: peak,
              uplinkCeilingDbm: maxTx.toDouble(),
              summary: selected,
              // The level is already the header's STRENGTH; naming it again
              // here is what pushed the caption into the numbers.
              title: inverse
                  ? 'Uplink · calculated'
                  : txPower == null
                  ? 'Uplink · no TX read'
                  : 'Uplink · TX $txPower dBm',
            ),
        ],
      ],
    );
  }
}

/// One button per layer, so a four-carrier aggregate is read one chart at a
/// time instead of as a wall of lines.
class _CarrierSelector extends StatelessWidget {
  const _CarrierSelector({
    required this.carriers,
    required this.selected,
    required this.onSelected,
  });

  final List<SpectrumCarrier> carriers;
  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (var i = 0; i < carriers.length; i++)
          _CarrierButton(
            label: carriers[i].buttonLabel,
            active: i == selected,
            onTap: () => onSelected(i),
          ),
      ],
    );
  }
}

class _CarrierButton extends StatelessWidget {
  const _CarrierButton({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: active
          ? AppColors.accent.withValues(alpha: 0.18)
          : AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(4),
        side: BorderSide(color: active ? AppColors.accent : AppColors.border),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 10,
              letterSpacing: 0.6,
              fontWeight: FontWeight.w600,
              color: active ? AppColors.accent : AppColors.textMuted,
            ),
          ),
        ),
      ),
    );
  }
}

/// The highest transmit power a band's power class allows, in dBm.
///
/// Power class 3 is 23 dBm and is the default everywhere. HPUE raises it:
/// class 2's 26 dBm on LTE 40 and 41 and on n78, class 1.5's 29 dBm on n41,
/// n77 and n79, and class 1's 31 dBm on band 14, public safety's uplink. The
/// uplink chart's top is this ceiling, so band 14 has room its 23 dBm
/// neighbour does not.
const Map<int, int> _lteMaxUplinkDbm = {14: 31, 40: 26, 41: 26};
const Map<int, int> _nrMaxUplinkDbm = {41: 29, 77: 29, 78: 26, 79: 29};

int maxUplinkDbm(int band, {bool is5g = false}) =>
    (is5g ? _nrMaxUplinkDbm[band] : _lteMaxUplinkDbm[band]) ?? 23;

/// The transmit level the uplink mask is drawn at, in dBm.
///
/// Without [inverse] it is the power the radio reports, or [maxDbm] when it
/// reports none — which is every public Android API. With the setting on, it is
/// the mirror of the downlink: a link heard at -20 dBm needs almost nothing
/// back and one at -140 dBm needs everything. The mask never falls below a
/// quarter of the chart, so the inverse stays a readable reading rather than a
/// mask that collapses into the axis.
double uplinkPeakDbm({
  required int? levelDbm,
  required int? txPowerDbm,
  required bool inverse,
  required int maxDbm,
}) {
  final ceiling = maxDbm.toDouble();
  final reported = (txPowerDbm ?? maxDbm).clamp(0, maxDbm).toDouble();
  if (!inverse || levelDbm == null) return reported;
  // How weak the downlink is, 0 (strong) to 1 (barely there). The first 60 dB
  // above -100 only move the mask half way: a phone can turn its power well
  // down before the link is marginal, so the uplink should not chase every dB
  // of a good signal. The last 40 dB move the rest, because below -100 each
  // one is a dB the transmitter has to make up.
  final db = levelDbm.clamp(-140, -40).toDouble();
  final weakness = db >= -100
      ? (-40 - db) / 60 * 0.5
      : 0.5 + (-100 - db) / 40 * 0.5;
  return ceiling * (0.25 + 0.75 * weakness);
}

/// A layer with no uplink mask to draw, said plainly rather than as an empty
/// box.
class _UplinkAbsentNote extends StatelessWidget {
  const _UplinkAbsentNote({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(AppColors.radius),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Text(
        message,
        style: const TextStyle(fontSize: 10.5, color: AppColors.textMuted),
      ),
    );
  }
}

/// One labelled number in a panel's header, two lines tall so three of them
/// fit beside the chart's name.
class _PanelStat extends StatelessWidget {
  const _PanelStat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 6.5,
            letterSpacing: 0.7,
            fontWeight: FontWeight.w600,
            color: AppColors.textMuted,
          ),
        ),
        const SizedBox(height: 1),
        Text(
          value,
          style: monospace.copyWith(
            fontSize: 8.5,
            color: AppColors.textPrimary,
          ),
        ),
      ],
    );
  }
}

/// 2110 → "2110", 2112.5 → "2112.5".
String _formatMhz(double mhz) {
  final rounded = double.parse(mhz.toStringAsFixed(1));
  return rounded == rounded.roundToDouble()
      ? rounded.toStringAsFixed(0)
      : rounded.toStringAsFixed(1);
}

class _SpectrumPanel extends StatelessWidget {
  const _SpectrumPanel({
    required this.carriers,
    this.uplink = false,
    this.uplinkPeakDbm,
    this.uplinkCeilingDbm = 23,
    this.title,
    this.summary,
  });

  final List<SpectrumCarrier> carriers;
  final bool uplink;
  final double? uplinkPeakDbm;
  final double uplinkCeilingDbm;
  final String? title;

  /// The carrier the header's numbers describe, when the panel is showing a
  /// cluster and not every mask in it is the selected one.
  final SpectrumCarrier? summary;

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
        uplink: uplink,
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
    final caption = title;
    final statsMhz = summary == null
        ? null
        : (uplink ? summary!.uplinkMhz : summary!.centerMhz);
    final statsLevel = summary == null
        ? null
        : (uplink
              ? (uplinkPeakDbm ?? uplinkCeilingDbm)
              : summary!.levelDbm);
    // The uplink copy is drawn at its own width — band 30's 7 MHz limit is a
    // downlink one — so the panel must not repeat the downlink's number.
    final statsWidth = summary == null
        ? null
        : (uplink ? carriers.first.bandwidthMhz : summary!.bandwidthMhz);

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(AppColors.radius),
      ),
      padding: const EdgeInsets.fromLTRB(8, 10, 10, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (caption != null)
            Padding(
              padding: const EdgeInsets.only(left: 26, right: 2, bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Text(
                      caption.toUpperCase(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 8.5,
                        letterSpacing: 1,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ),
                  if (summary != null) ...[
                    const SizedBox(width: 10),
                    _PanelStat(
                      label: 'STRENGTH',
                      value: statsLevel == null
                          ? '\u2014'
                          : '${statsLevel.round()} dBm',
                    ),
                    const SizedBox(width: 9),
                    _PanelStat(
                      label: 'FREQ',
                      value: statsMhz == null
                          ? '\u2014'
                          : '${_formatMhz(statsMhz)} MHz',
                    ),
                    const SizedBox(width: 9),
                    _PanelStat(
                      label: 'BW',
                      value: statsWidth == null
                          ? '\u2014'
                          : '${_formatMhz(statsWidth)} MHz',
                    ),
                  ],
                ],
              ),
            ),
          SizedBox(
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
                uplink: uplink,
                uplinkPeakDbm: uplinkPeakDbm,
                uplinkCeilingDbm: uplinkCeilingDbm,
              ),
            ),
          ),
        ],
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
    required this.uplink,
    this.uplinkPeakDbm,
    this.uplinkCeilingDbm = 23,
  });

  final List<SpectrumCarrier> carriers;
  final List<BandBlock> bands;
  final double low;
  final double high;
  final double plotHeight;
  final double bandRow;
  final double axisHeight;

  /// Both graphs are drawn in dBm. The downlink mask's top is the RSRP of the
  /// cell feeding it, so a strong carrier draws a tall block and a weak one a
  /// short block; the uplink's top is the transmit power.
  final bool uplink;
  final double? uplinkPeakDbm;

  /// The top of the uplink scale: the band's power-class ceiling in dBm.
  final double uplinkCeilingDbm;

  static const double _gutter = 26;
  static const double _top = 8;

  static const Color _grid = Color(0x14FFFFFF);

  double get _ceilingDb => uplink ? uplinkCeilingDbm : -40;
  double get _floorDb => uplink ? 0 : -140;
  List<double> get _ticks => uplink
      ? <double>[
          uplinkCeilingDbm,
          uplinkCeilingDbm * 2 / 3,
          uplinkCeilingDbm / 3,
          0,
        ]
      : const <double>[-40, -73, -107, -140];

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
    for (final db in _ticks) {
      canvas.drawLine(Offset(left, y(db)), Offset(right, y(db)), grid);
      _text(
        canvas,
        db.toInt().toString(),
        Offset(1, y(db) - 4),
        size: 8,
        color: AppColors.textMuted,
      );
    }

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
      // The last tick and the unit caption share the right edge; drawing both
      // printed them on top of each other.
      if (tick > right - 30) continue;
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
  ///
  /// The mask is squared off — it holds its power across almost the whole
  /// channel and falls within a fraction of a megahertz at each edge — and it
  /// is open at the bottom. Three sides, not a box: the mask is a level above
  /// the noise floor, not a filled rectangle, and a bottom stroke claimed an
  /// edge the spectrum does not have.
  ///
  /// The top is the carrier's own level: the RSRP of its cell on the downlink,
  /// and the transmit power on the uplink. That is what makes the height mean
  /// something at a glance.
  void _carrier(
    Canvas canvas,
    SpectrumCarrier carrier,
    double Function(double) x,
    double Function(double) y,
    double bottom,
  ) {
    final centre = carrier.maskCenterMhz;
    final half = carrier.bandwidthMhz / 2;
    final inset = math.max(0.15, carrier.bandwidthMhz * 0.02);
    final foot = math.max(0.3, carrier.bandwidthMhz * 0.03);
    final peak = uplink
        ? (uplinkPeakDbm ?? uplinkCeilingDbm)
        : (carrier.levelDbm ?? -100).clamp(-140, -40).toDouble();
    final mask = Path()
      ..moveTo(x(centre - half - foot), y(_floorDb))
      ..lineTo(x(centre - half + inset), y(peak))
      ..lineTo(x(centre + half - inset), y(peak))
      ..lineTo(x(centre + half + foot), y(_floorDb));
    final fill = Path.from(mask)..close();

    canvas.drawPath(
      fill,
      Paint()
        ..color = AppColors.accent.withValues(alpha: 0.20)
        ..style = PaintingStyle.fill,
    );
    // The three sides: up, across, down. No fourth line along the floor.
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
      Offset(x(carrier.lowMhz), y(peak)),
      Offset(x(carrier.lowMhz), bottom),
    );
    _dash(
      canvas,
      Offset(x(carrier.highMhz), y(peak)),
      Offset(x(carrier.highMhz), bottom),
    );

    final arrow = uplink ? '\u2191' : '\u2193';
    // Just the band: the strength, frequency and width live in the header, and
    // the long green line used to run off the side of the page here.
    final label = '$arrow ${carrier.block.label}';
    _text(
      canvas,
      label,
      Offset(x(centre) - _measure(label, 8.5) / 2, bottom - 11),
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
      text: TextSpan(
        text: value,
        style: TextStyle(fontSize: size, height: 1),
      ),
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
      old.bands != bands ||
      old.uplink != uplink ||
      old.uplinkPeakDbm != uplinkPeakDbm ||
      old.uplinkCeilingDbm != uplinkCeilingDbm;
}
