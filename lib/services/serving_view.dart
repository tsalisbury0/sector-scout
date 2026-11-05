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
    SimReading? sim,
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
    if (bandwidthFor(cell, sim) case final bandwidth?) {
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

  /// The component carriers, one row each, in the order the radio reports
  /// them.
  ///
  /// Every carrier gets its own row even when two of them are on the same band:
  /// intra-band aggregation is two carriers on one band, and collapsing them by
  /// band would report the pair as one. Empty unless the privileged reader
  /// answered, which is why the card appears and disappears with Shizuku.
  static List<CarrierRow> carrierRows(SimReading sim) => [
    for (final carrier in sim.carriers)
      CarrierRow(
        carrier: carrier,
        tech: _techLabel(carrier.tech),
        cell: sim.reportedCellFor(carrier),
      ),
  ];

  /// The totals the card closes with: the whole aggregate, and the NR share of
  /// it when the link is not NR-only already.
  static List<MapEntry<String, String>> carrierTotals(SimReading sim) {
    if (sim.carriers.isEmpty) return const [];
    final entries = <MapEntry<String, String>>[
      MapEntry('Aggregate', '${shortMhz(sim.aggregatedBandwidthMhz)} MHz'),
    ];
    final nr = sim.nrCarriers;
    if (nr.isNotEmpty && nr.length != sim.carriers.length) {
      final khz = nr.fold(0, (sum, carrier) => sum + carrier.bandwidthKhz);
      entries.add(MapEntry('NR aggregate', '${shortMhz(khz / 1000)} MHz'));
    }
    return entries;
  }

  /// How wide the carrier [cell] sits on, when the reader named it.
  ///
  /// One carrier per cell is decided once for the whole slot, in
  /// [SimReading.carrierCells], so no two carriers can claim the same cell or
  /// the same frequency. That is what used to make a width vanish: with two
  /// carriers on one band and no PCI to separate them, neither match was
  /// unique, so both cards dropped the row while CA was being reported.
  static String? bandwidthFor(CellTower cell, SimReading? sim) {
    final match = sim?.carrierFor(cell);
    return match == null ? null : '${shortMhz(match.bandwidthMhz)} MHz';
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

/// One component carrier, described the way a neighbour row is.
///
/// The aggregation card and the neighbour list are two answers about the same
/// radios, so they are drawn the same way: a technology chip, the band, and the
/// cells' own readings — but only the readings that exist. A carrier config
/// names a band and a width, never a cell, so the identity and the level come
/// from [cell], which is filled only when the radio reported a PCI and the scan
/// lists that same PCI. A carrier with no PCI — which is every LTE carrier this
/// S25 reports — shows its band and width and nothing else; naming the
/// strongest cell on the band would be a guess dressed as a measurement.
class CarrierRow {
  const CarrierRow({required this.carrier, required this.tech, this.cell});

  final RadioCarrier carrier;

  /// `LTE` / `NR`, the chip a neighbour row carries.
  final String tech;

  /// The cell the scan reported under this carrier's own PCI.
  final CellTower? cell;

  /// `B66`, or null when the modem named no band.
  String? get band => carrier.bandLabel;

  /// `PCI 148`, or null when nothing in the scan carries this carrier's PCI.
  String? get pci => cell == null ? null : 'PCI ${carrier.pci}';

  int? get dbm => cell?.dbm;

  /// `↓ 2175 · ↑ 1775 MHz`, only from a matched cell.
  String? get frequency =>
      cell == null ? null : ServingView.neighbourFrequency(cell!);

  /// `10 MHz` — the one thing only the privileged reader can say.
  String get width => '${ServingView.shortMhz(carrier.bandwidthMhz)} MHz';
}
