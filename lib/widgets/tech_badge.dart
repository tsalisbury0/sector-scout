import 'package:flutter/material.dart';

import '../models/cell_snapshot.dart';
import '../theme/app_colors.dart';

/// AT&T (including FirstNet), which shows 5G+ for NR Advanced.
const Set<String> _attPlmns = {
  '310410',
  '310150',
  '310170',
  '310380',
  '313100',
};
const String _tMobile = '310260';
const String _verizon = '311480';

/// The carrier-style label for the current network: **LTE**, **LTE+**, **5GE**,
/// **5G**, **5G+**, **5GUC** or **5GUW**.
///
/// This is the same rule the pinned notification draws its icon with
/// (`SignalIcon.kt`), so the card and the shade never disagree: 5G is only
/// claimed when an NR cell is attached to the slot, because Samsung keeps
/// reporting `NR_NSA` for a while after the 5G leg has gone.
String? techBadgeLabel({
  required String? tech,
  required String override,
  required String? plmn,
  required bool nrAttached,
  bool aggregated = false,
}) {
  final codes = plmn?.replaceAll('-', '');
  if (nrAttached) {
    if (override == 'NR_ADVANCED') {
      if (codes != null && _attPlmns.contains(codes)) return '5G+';
      if (codes == _tMobile) return '5GUC';
      if (codes == _verizon) return '5GUW';
      // NR Advanced on a network with no house style.
      return '5G';
    }
    return '5G';
  }
  if (tech != 'LTE') return null;
  // LTE-Advanced, which the display info reports as aggregation or as
  // Advanced Pro. AT&T (FirstNet included) sells the latter as **5GE**;
  // everywhere else both read **LTE+**, because aggregation is the whole
  // story there. Note this is still an LTE radio — 5GE is a brand name, not a
  // 5G connection.
  if (override == 'LTE_ADVANCED_PRO') {
    return codes != null && _attPlmns.contains(codes) ? '5GE' : 'LTE+';
  }
  // Any second carrier is LTE-Advanced, whether or not the platform's own
  // override says so: another registered LTE cell, or a supplemental
  // downlink, which a radio only reports while it is aggregating it. This is
  // what lets an NSA slot whose 5G leg has gone read LTE+ while a B29 is
  // still under it.
  if (aggregated || override == 'LTE_CA') return 'LTE+';
  return 'LTE';
}

/// The badge for a SIM slot, or null when it has none to show.
///
/// An NSA slot whose NR leg has gone reports `LTE`, and that is what it gets:
/// the badge describes the radio actually serving the slot, while the mode chip
/// beside it keeps the platform's word for the connection. Hiding the badge
/// there used to leave the header with no technology label at all.
///
/// A network the operator list tags `lteM` reads **LTE-M** instead of `LTE`.
/// Android reports an eMTC carrier as plain LTE — it has no LTE-M network type
/// — so the tag is the only way to say which radio the slot is really using.
///
/// A satellite slot shows [SatelliteTag] in this badge's place — the header
/// picks one or the other, never both, since `SAT` and `LTE` describe different
/// things (the path, and the radio).
String? badgeForSim(SimReading sim) {
  final primary = sim.lteServing ?? sim.serving ?? sim.nrServing;
  final label = techBadgeLabel(
    tech: primary?.tech.raw,
    override: sim.overrideNetworkType,
    plmn: primary?.plmn,
    nrAttached: sim.nrServing != null,
    aggregated: sim.lteAggregated,
  );
  // An eMTC carrier is an LTE radio and nothing more, so the tag wins over the
  // aggregation marker — which Android would otherwise report on the same
  // cell. A 5G label is left alone.
  if (label != null && !label.startsWith('5G') && sim.isLteM) return 'LTE-M';
  return label;
}

/// `SAT`, for a satellite (NTN) link.
///
/// Plain text, no box: it is a marker beside the carrier name, not a technology
/// chip, and it takes the place of [TechBadge] rather than standing beside it,
/// so the header never claims both `SAT` and `LTE` for the same link.
class SatelliteTag extends StatelessWidget {
  const SatelliteTag({super.key});

  @override
  Widget build(BuildContext context) => const Text(
        'SAT',
        style: TextStyle(
          fontSize: 11,
          height: 1.1,
          fontWeight: FontWeight.w800,
          letterSpacing: 1,
          color: AppColors.satellite,
        ),
      );
}

/// The label above, drawn the way the carriers write it.
///
/// Plain text, no box: it is a caption for the card rather than a second chip,
/// so it reads as part of the header instead of competing with the mode chip.
class TechBadge extends StatelessWidget {
  const TechBadge({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    // 5GE is AT&T's name for LTE-Advanced Pro, not NR, so it keeps the LTE ink:
    // the label is the carrier's word, the colour is the radio's.
    final fiveG = label.startsWith('5G') && label != '5GE';
    return Text(
      label,
      style: TextStyle(
        fontSize: 11.5,
        height: 1.1,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.6,
        color: fiveG ? AppColors.accent : AppColors.textMuted,
      ),
    );
  }
}
