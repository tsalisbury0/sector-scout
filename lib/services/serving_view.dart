import '../models/cell_snapshot.dart';
import 'carrier_names.dart';

/// The rows a serving-cell card shows, built once for every surface.
///
/// The Flutter cards and the LAN dashboard both render these, so a field added
/// here shows up in both and the browser page can never quietly fall behind the
/// app. Everything is text already: no widget, no units left to the caller.
class ServingView {
  const ServingView._();

  /// Operator brand for a slot, looked up from the PLMN it is registered on.
  ///
  /// The SIM's own name is the fallback: it is what the card carries, which on
  /// a roaming or MVNO SIM is not the network the cell belongs to.
  static String carrierName(SimReading sim) {
    final plmn =
        sim.serving?.plmn ?? sim.lteServing?.plmn ?? sim.nrServing?.plmn;
    final simName = sim.carrierName.isEmpty ? sim.label : sim.carrierName;
    return CarrierNames.resolve(plmn, simName);
  }

  /// One serving cell as label/value rows, in the order the cards show them.
  static List<MapEntry<String, String>> entries(
    CellTower cell, {
    int? gnbEstimate,
    String? fallbackPlmn,
    List<RadioCarrier> carriers = const [],
  }) {
    final entries = <MapEntry<String, String>>[];

    if (cell.tech == CellTech.lte) {
      // eNB + sector instead of the raw 28-bit CI. Sectors are numbers only —
      // no operator naming on LTE.
      //
      // A supplemental downlink has no ECI, so it gets neither row instead of
      // a pair of dashes: there is no site to decode, not a site we failed to.
      if (!cell.isSecondaryLte) {
        entries.add(MapEntry('eNB (dec)', cell.enb?.toString() ?? '—'));
        entries.add(MapEntry('Sector (dec)', cell.sector?.toString() ?? '—'));
      }
    } else if (cell.tech == CellTech.nr) {
      // gNB instead of the raw 36-bit NCI. The sector only exists when the
      // radio reports the NCI — NSA legs hide it, and the app does not invent a
      // sector number for those.
      final estimated = cell.gnb == null && gnbEstimate != null;
      final gnb = cell.gnb ?? gnbEstimate;
      entries.add(
        MapEntry(
          estimated ? 'gNB (est.)' : 'gNB (dec)',
          gnb?.toString() ?? '—',
        ),
      );
      if (!estimated) {
        final sector = cell.sector;
        if (sector != null) {
          entries.add(MapEntry('Sector (dec)', sector.toString()));
        }
      }
      if (cell.cellIdHex != null) {
        entries.add(MapEntry('NCI (hex)', cell.cellIdHex!));
      }
    } else {
      entries.add(MapEntry('Cell ID', cell.cellId ?? '—'));
    }

    // A supplemental downlink has no tracking area of its own — it belongs to
    // the primary cell's — so the secondary card carries the PCI alone.
    if (!cell.isSecondaryLte) {
      entries.add(MapEntry(cell.tacLabel, cell.tac?.toString() ?? '—'));
    }
    entries.add(MapEntry(cell.pciLabel, cell.pci?.toString() ?? '—'));
    if (cell.bandLabel != null) {
      // T-Mobile's n41 is often named n38 by the modem, because the two bands
      // share ARFCNs in this block. Say that the label was corrected, rather
      // than showing a different band than the radio reported without a word.
      entries.add(
        MapEntry(
          'Band',
          cell.bandReconciled
              ? '${cell.bandLabel!} '
                    '(modem: ${bandName(cell.reportedBand!, is5g: true)})'
              : cell.bandLabel!,
        ),
      );
    }
    // The width of *this* carrier, when the privileged reader named it. The
    // band list on a cell says nothing about how wide the carrier is, so
    // without the reader the row is absent rather than guessed.
    if (bandwidthFor(cell, carriers) case final bandwidth?) {
      entries.add(MapEntry('Bandwidth', bandwidth));
    }
    // Band 106's build shows its own channel numbers rather than the band-8
    // raster the modem happens to report. A held channel is marked as such: the
    // modem stopped reporting it, and the same cell is still served.
    final channel = cell.displayedArfcn;
    entries.add(
      MapEntry(
        'ARFCN',
        channel == null
            ? '—'
            : cell.channelHeld
            ? '$channel (last known)'
            : channel.toString(),
      ),
    );
    if (cell.tech == CellTech.nr && cell.nrCarrierLabel != null) {
      entries.add(MapEntry('NR carrier', cell.nrCarrierLabel!));
    }
    if (cell.isTdd) {
      // TDD uses one band in both directions, so a single row instead of an
      // identical downlink/uplink pair.
      entries.add(MapEntry('Downlink/Uplink', cell.downlinkLabel!));
    } else {
      if (cell.downlinkLabel != null) {
        entries.add(MapEntry('Downlink', cell.downlinkLabel!));
      }
      if (cell.uplinkLabel != null) {
        entries.add(MapEntry('Uplink', cell.uplinkLabel!));
      }
    }
    if (cell.plmn case final plmn?) {
      entries.add(MapEntry('PLMN', plmn));
    } else if (fallbackPlmn != null) {
      // A supplemental downlink only carries MCC/MNC while it is actually
      // passing data, so the network the main carrier is registered on is the
      // answer for the rest of the time — marked, because the cell did not say
      // it.
      entries.add(MapEntry('PLMN', '$fallbackPlmn (from primary cell)'));
    }
    if (SignalQuality.distanceFromTimingAdvance(cell.timingAdvance)
        case final distance?) {
      entries.add(MapEntry('Distance (TA)', distance));
    }
    return entries;
  }

  /// Radio-quality rows for a slot: one block per leg of an NSA pair.
  static List<MapEntry<String, String>> qualityEntries(SimReading sim) {
    final lte = sim.lteServing;
    final nr = sim.nrServing;

    if (sim.isNsa && lte != null && nr != null) {
      return [...qualityFor(lte, 'LTE'), ...qualityFor(nr, 'NR')];
    }
    final cell = sim.serving;
    return cell == null ? const [] : qualityFor(cell, null);
  }

  /// The carrier-aggregation card: one row per component carrier, then the
  /// totals.
  ///
  /// Empty unless the privileged reader answered, which is why the card
  /// appears and disappears with Shizuku instead of showing dashes: without it
  /// the app has no width to report, and a blank row would claim otherwise.
  static List<MapEntry<String, String>> carrierEntries(SimReading sim) {
    if (sim.carriers.isEmpty) return const [];
    final entries = <MapEntry<String, String>>[
      for (final carrier in sim.carriers)
        MapEntry(
          '${carrier.bandLabel ?? '?'} · ${_techLabel(carrier.tech)}',
          _carrierValue(carrier, sim),
        ),
      MapEntry('Aggregate', '${shortMhz(sim.aggregatedBandwidthMhz)} MHz'),
    ];
    // The NR side on its own, which is what a 5G reading is judged on; only
    // worth a row when the link is not NR-only already.
    final nr = sim.nrCarriers;
    if (nr.isNotEmpty && nr.length != sim.carriers.length) {
      final khz = nr.fold(0, (sum, carrier) => sum + carrier.bandwidthKhz);
      entries.add(MapEntry('NR aggregate', '${shortMhz(khz / 1000)} MHz'));
    }
    return entries;
  }

  /// A carrier row: its width, then the cell it is coming from — frequency and
  /// level — when the modem names a PCI that matches one of the cells heard.
  static String _carrierValue(RadioCarrier carrier, SimReading sim) {
    final parts = <String>['${shortMhz(carrier.bandwidthMhz)} MHz'];
    final cell = carrierCell(carrier, sim);
    if (cell?.downlinkMhz case final mhz?) {
      parts.add('${mhz.toStringAsFixed(0)} MHz');
    }
    if (cell?.dbm case final dbm?) parts.add('$dbm dBm');
    return parts.join(' · ');
  }

  /// The cell [carrier] is being received from.
  ///
  /// A carrier config names a band and a width but never a cell, so the PCI it
  /// does report is the only exact handle — and it is the same PCI the scan
  /// lists for that cell. Without one, the strongest cell heard on that band
  /// stands in, since a carrier has to be one the phone can hear at all.
  static CellTower? carrierCell(RadioCarrier carrier, SimReading sim) {
    final pci = carrier.pci;
    if (pci != null && pci > 0) {
      for (final cell in sim.cells) {
        if (cell.tech == carrier.tech && cell.pci == pci) return cell;
      }
    }
    if (carrier.band <= 0) return null;
    CellTower? best;
    for (final cell in sim.cells) {
      if (cell.tech != carrier.tech) continue;
      if (!cellBands(cell).contains(carrier.band)) continue;
      if (cell.downlinkMhz == null) continue;
      if (best == null || (cell.dbm ?? -200) > (best.dbm ?? -200)) best = cell;
    }
    return best;
  }

  /// Every band the cell's identity mentions, its own first.
  ///
  /// A cell reporting band 29 alongside band 2 is describing its aggregation
  /// layers, so matching a carrier has to consider the whole list — matching
  /// only the first entry is what let a B29 layer take the anchor's width away.
  static List<int> cellBands(CellTower cell) {
    final bands = <int>[];
    final own = cell.tech == CellTech.nr ? cell.nrArfcnBand : cell.earfcnBand;
    if (own != null) bands.add(own);
    bands.addAll(cell.bands);
    return bands.toSet().toList();
  }

  /// How wide the carrier [cell] sits on, when the reader named it.
  ///
  /// PCI is the identity that survives aggregation: once a B29 layer or an NR
  /// leg attaches, the cell's band list stops describing only the anchor, but
  /// PCI still names the same radio. Band is the fallback, and a lone carrier
  /// of the technology the last one — an NSA leg usually hides its band, and
  /// then that single NR carrier is the answer.
  static String? bandwidthFor(CellTower cell, List<RadioCarrier> carriers) {
    final same = carriers.where((carrier) => carrier.tech == cell.tech).toList();
    final match = matchCarrier(cell, same);
    return match == null ? null : '${shortMhz(match.bandwidthMhz)} MHz';
  }

  /// The carrier that *is* [cell], out of the ones on its technology.
  static RadioCarrier? matchCarrier(CellTower cell, List<RadioCarrier> same) {
    if (same.isEmpty) return null;
    final pci = cell.pci;
    if (pci != null && pci > 0) {
      final byPci = same.where((carrier) => carrier.pci == pci).toList();
      if (byPci.length == 1) return byPci.single;
    }
    for (final band in cellBands(cell)) {
      final byBand = same.where((carrier) => carrier.band == band).toList();
      if (byBand.length == 1) return byBand.single;
    }
    return same.length == 1 ? same.single : null;
  }

  static String _techLabel(CellTech tech) => switch (tech) {
    CellTech.nr => 'NR',
    CellTech.lte => 'LTE',
    CellTech.unknown => '?',
    _ => tech.raw,
  };

  static List<MapEntry<String, String>> qualityFor(
    CellTower cell,
    String? prefix,
  ) {
    String label(String name) => prefix == null ? name : '$prefix $name';
    return [
      if (cell.rsrp != null) MapEntry(label('RSRP'), '${cell.rsrp} dBm'),
      if (cell.rsrq != null) MapEntry(label('RSRQ'), '${cell.rsrq} dB'),
      if (cell.sinr != null) MapEntry(label('SINR'), '${cell.sinr} dB'),
      if (cell.asu != null) MapEntry(label('ASU'), '${cell.asu}'),
      MapEntry(label('Platform level'), '${cell.level ?? 0} / 4'),
    ];
  }

  /// 2175.00 → 2175, 3871.20 → 3871.2 — short enough for a neighbour row, and
  /// for a carrier width (`20000 kHz` → `20`).
  static String shortMhz(double mhz) {
    final text = mhz.toStringAsFixed(2);
    if (text.endsWith('.00')) return text.substring(0, text.length - 3);
    if (text.endsWith('0')) return text.substring(0, text.length - 1);
    return text;
  }

  /// The compact ↓ / ↑ line a neighbour row carries, or null with no frequency.
  static String? neighbourFrequency(CellTower cell) {
    final downlink = cell.downlinkMhz;
    final uplink = cell.uplinkMhz;
    if (downlink == null) return null;
    if (uplink == null) return '↓ ${shortMhz(downlink)} MHz';
    if (uplink == downlink) return '↓↑ ${shortMhz(downlink)} MHz';
    return '↓ ${shortMhz(downlink)} · ↑ ${shortMhz(uplink)} MHz';
  }
}
