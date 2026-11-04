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

  /// Radio-quality rows for a slot: one block per leg of an NSA pair, then the
  /// component carriers when the Shizuku reader is bound.
  static List<MapEntry<String, String>> qualityEntries(SimReading sim) {
    final lte = sim.lteServing;
    final nr = sim.nrServing;

    final List<MapEntry<String, String>> quality;
    if (sim.isNsa && lte != null && nr != null) {
      quality = [...qualityFor(lte, 'LTE'), ...qualityFor(nr, 'NR')];
    } else {
      final cell = sim.serving;
      quality = cell == null ? const [] : qualityFor(cell, null);
    }
    return [...quality, ...carrierEntries(sim)];
  }

  /// The aggregation rows: each carrier's band and width, then the total.
  ///
  /// Empty unless the privileged reader answered, which is why these rows
  /// appear and disappear with Shizuku instead of showing dashes: without it
  /// the app has no width to report, and a blank row would claim otherwise.
  static List<MapEntry<String, String>> carrierEntries(SimReading sim) {
    if (sim.carriers.isEmpty) return const [];
    final entries = <MapEntry<String, String>>[];
    if (sim.carriers.isNotEmpty) {
      final widths = sim.carriers
          .map((carrier) => shortMhz(carrier.bandwidthMhz))
          .join(' + ');
      entries.add(
        MapEntry(
          sim.carriers.length == 1 ? 'Bandwidth' : 'Bandwidth (CA)',
          sim.carriers.length == 1
              ? '$widths MHz'
              : '$widths = ${shortMhz(sim.aggregatedBandwidthMhz)} MHz',
        ),
      );
      entries.add(
        MapEntry(
          'Carriers',
          sim.carriers
              .map(
                (carrier) =>
                    '${carrier.bandLabel ?? '?'} '
                    '${shortMhz(carrier.bandwidthMhz)} MHz',
              )
              .join(' · '),
        ),
      );
    }
    return entries;
  }

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
