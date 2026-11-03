import 'dart:math' as math;

import 'band_filters.dart';
import 'band_tables.dart';

/// Radio access technology reported by the modem.
enum CellTech {
  nr('NR', '5G NR'),
  lte('LTE', '4G LTE'),
  wcdma('WCDMA', '3G UMTS'),
  gsm('GSM', '2G GSM'),
  cdma('CDMA', 'CDMA'),
  tdscdma('TDSCDMA', '3G TD-SCDMA'),
  unknown('', 'Unknown');

  const CellTech(this.raw, this.label);

  final String raw;
  final String label;

  bool get is5g => this == CellTech.nr;

  static CellTech parse(Object? value) {
    for (final tech in values) {
      if (tech.raw == value) return tech;
    }
    return CellTech.unknown;
  }
}

/// Which part of the 3.3–4.2 GHz block a 5G carrier occupies.
///
/// These are not 3GPP bands but deployment blocks the operator names, and the
/// boundaries are drawn by frequency because n77 covers the whole span while
/// n48 (CBRS) is carved out of its middle:
///
/// - 3300–3550 MHz — **n77 DoD** (the 3.45 GHz federal band)
/// - 3550–3700 MHz — **n48 CBRS** (shared, lightly licensed)
/// - 3700–4200 MHz — **n77 C-Band**
enum NrCarrier {
  n5,
  dodLower,
  n77,
  cbrs,
  unknown,
}

/// One cell the modem currently knows about (serving cell or neighbour).
class CellTower {
  const CellTower({
    required this.tech,
    required this.registered,
    this.cellId,
    this.tac,
    this.pci,
    this.mcc,
    this.mnc,
    this.dbm,
    this.level,
    this.arfcn,
    this.asu,
    this.rsrp,
    this.rsrq,
    this.sinr,
    this.timingAdvance,
    this.bands = const [],
    this.channelHeld = false,
  });

  factory CellTower.fromMap(Map<Object?, Object?> map) {
    return CellTower(
      tech: CellTech.parse(map['type']),
      registered: map['registered'] == true,
      cellId: _string(map['cellId']),
      tac: _int(map['tac']),
      pci: _int(map['pci']),
      mcc: _string(map['mcc']),
      mnc: _string(map['mnc']),
      dbm: _int(map['dbm']),
      level: _int(map['level']),
      arfcn: _int(map['arfcn']),
      asu: _int(map['asu']),
      rsrp: _int(map['rsrp']),
      rsrq: _int(map['rsrq']),
      sinr: _int(map['sinr']),
      timingAdvance: _int(map['timingAdvance']),
      // -1 is the platform's BAND_UNKNOWN, not a band: some firmwares report it
      // whenever they cannot place the carrier, and it would otherwise print
      // as `n-1`.
      bands: (map['bands'] as List<Object?>? ?? const [])
          .map(_int)
          .whereType<int>()
          .where((band) => band > 0)
          .toList(),
      channelHeld: map['heldChannel'] == true,
    );
  }

  final CellTech tech;
  final bool registered;

  /// NCI (5G) or the LTE/GSM/WCDMA cell identity, as reported by the modem.
  final String? cellId;

  /// Tracking area code (LTE/NR) or location area code (2G/3G).
  final int? tac;
  final int? pci;
  final String? mcc;
  final String? mnc;

  /// Raw signal strength in dBm (RSSI on 2G, RSRP on 4G/5G).
  final int? dbm;

  /// Platform signal level, 0-4, exactly what the status-bar icon uses.
  final int? level;

  /// EARFCN / NR-ARFCN / UARFCN / ARFCN, depending on the technology.
  final int? arfcn;
  final int? asu;
  final int? rsrp;
  final int? rsrq;
  final int? sinr;
  final int? timingAdvance;
  final List<int> bands;

  /// True when [arfcn] is the last channel the radio reported rather than a
  /// fresh reading: the modem dropped the number while still serving this
  /// cell. Shown as such instead of silently pretending it was just read.
  final bool channelHeld;

  int get bars => SignalQuality.barsFor(
        dbm: dbm,
        level: level,
        boostDbm: SignalQuality.boostFor(plmn),
      );

  int? get _numericCellId => int.tryParse(cellId ?? '');

  /// AT&T network codes. Their NR gNB IDs are 26 bits, and the LTE/NR sector
  /// plans below are AT&T-specific. FirstNet runs the same 26-bit IDs.
  static const Set<String> _attPlmns = {
    '310-410', // AT&T
    '310-150', // AT&T (Cricket)
    '310-170', // AT&T
    '310-380', // AT&T
    '313-100', // AT&T FirstNet
  };

  bool get isAtt => _attPlmns.contains(plmn);

  /// T-Mobile network codes. Their NR gNB IDs are 24 bits, not the 22-bit
  /// default — T-911 rides the same RAN.
  static const Set<String> _tmobilePlmns = {
    '310-260', // T-Mobile
    '312-190', // T-911 (T-Mobile MVNO)
  };

  bool get isTmobile => _tmobilePlmns.contains(plmn);

  /// LTE splits its 28-bit E-UTRAN Cell Identity into eNB (top 20 bits) and
  /// sector / cell-within-eNB (bottom 8 bits). Shown in decimal.
  int? get enb {
    final id = _numericCellId;
    return tech == CellTech.lte && id != null ? id >> 8 : null;
  }

  /// AT&T small cells / DAS use these eNB ranges, where the low byte is not a
  /// macro-sector number. The NSA gNB estimate is keyed to the macro plan, so
  /// those sites are left alone rather than given a wrong gNB.
  static const List<String> _attUnmappedEnbPrefixes = [
    '240',
    '241',
    '242',
    '243',
    '246',
    '248',
    '249',
  ];

  /// True when this LTE eNB sits on AT&T's macro-cell plan (not small cell/DAS).
  bool get _attSectorPlanApplies {
    final site = enb;
    if (site == null) return false;
    final text = site.toString();
    return !_attUnmappedEnbPrefixes.any((prefix) => text.startsWith(prefix));
  }

  /// 5G NR packs the same idea into the 36-bit NCI: a gNB ID on the left and
  /// the cell (sector) inside that gNB on the right. 3GPP lets each operator
  /// choose the gNB ID length, so it has to come from the PLMN:
  ///
  /// - **AT&T: 26-bit gNB + 10-bit sector.** gNB 12295710 / sector 49 comes out
  ///   of NCI 12590807089; splitting that NCI at 24 bits instead yields 3073927
  ///   and sector 2097, which is the wrong tower number.
  /// - **T-Mobile: 24-bit gNB + 12-bit sector.** NCI 4314132792 is gNB
  ///   1053255 / sector 312 on T-Mobile's own maps; splitting it at 22 bits
  ///   yields 263313 / 12600, which is that same NCI read on the wrong raster.
  /// - **Everyone else: 22-bit gNB + 14-bit sector.** Confirmed against live
  ///   Verizon readings, where the 22-bit split matches the operator's maps.
  int get _gnbBits => isAtt
      ? 26
      : isTmobile
          ? 24
          : 22;

  /// gNB ID in decimal (5G only). Together with [sector] it rebuilds the NCI:
  /// `gnb << (36 - gnbBits) | sector`.
  int? get gnb {
    final id = _numericCellId;
    if (tech != CellTech.nr || id == null || id <= 0) return null;
    return id >> (36 - _gnbBits);
  }

  /// Cell within the eNB (LTE, 8 bits) or within the gNB (5G), in decimal.
  int? get sector {
    final id = _numericCellId;
    if (id == null) return null;
    return switch (tech) {
      CellTech.lte => id & 0xFF,
      CellTech.nr => id & ((1 << (36 - _gnbBits)) - 1),
      _ => null,
    };
  }

  /// NR-ARFCN to centre frequency in MHz, using the 3GPP global raster.
  double? get frequencyMhz {
    final channel = arfcn;
    if (tech != CellTech.nr || channel == null || channel <= 0) return null;
    if (channel < 600000) return channel * 0.005;
    if (channel <= 2016666) return 3000 + (channel - 600000) * 0.015;
    return 24250.08 + (channel - 2016667) * 0.06;
  }

  /// NR carrier block, inferred from the ARFCN (preferred) or the band.
  NrCarrier get nrCarrier {
    if (tech != CellTech.nr) return NrCarrier.unknown;
    final mhz = frequencyMhz;
    if (mhz != null) {
      if (mhz >= 869 && mhz <= 894) return NrCarrier.n5;
      if (mhz >= 3300 && mhz < 3550) return NrCarrier.dodLower;
      if (mhz >= 3550 && mhz < 3700) return NrCarrier.cbrs;
      if (mhz >= 3700 && mhz <= 4200) return NrCarrier.n77;
    }
    if (bands.contains(5)) return NrCarrier.n5;
    // Band n77 alone cannot separate DoD, CBRS from C-band.
    return NrCarrier.unknown;
  }

  String? get nrCarrierLabel => switch (nrCarrier) {
        NrCarrier.n5 => 'n5',
        NrCarrier.dodLower => 'n77 DoD',
        NrCarrier.cbrs => 'n48 CBRS',
        NrCarrier.n77 => 'n77 C-Band',
        NrCarrier.unknown => null,
      };

  /// True when the carrier sits in the CBRS block, 3550–3700 MHz.
  ///
  /// n77 spans 3300–4200 MHz and therefore *contains* CBRS, so a modem that
  /// reports the wider band is right about the band and still wrong about the
  /// deployment: this span is n48. The frequency decides, the band follows.
  bool get isCbrsFrequency {
    if (!BandFilters.cbrs) return false;
    final mhz = frequencyMhz;
    return tech == CellTech.nr && mhz != null && mhz >= 3550 && mhz < 3700;
  }

  /// Bands T-Mobile deploys where the modem can name a narrower 3GPP band
  /// instead, and the ARFCN window that makes the wider band the answer.
  ///
  /// NR does not signal the band over the air: the modem works it out from the
  /// NR-ARFCN. Each pair below overlaps in spectrum *and* on the raster — the
  /// reported band's whole ARFCN block sits inside the real one's — so a
  /// carrier in the shared window comes back as the narrow band:
  ///
  /// - **n38 → n41.** n38 is 2570–2620 MHz (ARFCN 514000–524999), n41 is
  ///   2496–2690 (499200–537999). T-Mobile runs n41 across the block and no
  ///   n38 at all.
  /// - **n2 → n25.** n2 is 1930–1990 MHz (386000–398999), n25 is 1930–1995
  ///   (386000–399999). T-Mobile's PCS carrier is n25, including the G block
  ///   at the top that only n25 covers.
  static const List<_NrRecode> _tmobileNrRecodes = [
    _NrRecode(reported: 38, actual: 41, first: 499200, last: 537999),
    _NrRecode(reported: 2, actual: 25, first: 386000, last: 399999),
  ];

  /// The correction this cell needs, if any. T-Mobile's PLMNs only: an
  /// n38 in Europe or an n2 on another carrier is the real band.
  _NrRecode? get _nrRecode {
    if (!BandFilters.tmobileBands) return null;
    if (tech != CellTech.nr || !isTmobile || bands.length != 1) return null;
    final channel = arfcn;
    if (channel == null) return null;
    for (final recode in _tmobileNrRecodes) {
      if (recode.reported == bands.first &&
          channel >= recode.first &&
          channel <= recode.last) {
        return recode;
      }
    }
    return null;
  }

  /// True when the band the modem named was replaced by the band it really is.
  bool get bandReconciled => _nrRecode != null;

  /// The modem's own band number when [bandReconciled], for the `(modem: n38)`
  /// note; null when the app is showing what the radio reported.
  int? get reportedBand => _nrRecode?.reported;

  /// Band the readings are interpreted with: the first one the modem listed
  /// (corrected where the raster is ambiguous), or — when the modem reports
  /// none — the one its EARFCN falls in.
  int? get _primaryBand {
    if (_nrRecode case final recode?) return recode.actual;
    if (bands.contains(77) && isCbrsFrequency) return 48;
    if (bands.isNotEmpty) return bands.first;
    return tech == CellTech.nr ? nrArfcnBand : earfcnBand;
  }

  /// True when [bandLabel] was worked out from the channel rather than read
  /// from the modem. Several Samsung build/modem combinations (the A10e on
  /// Android 11 among them) return a valid EARFCN with an empty band list, so
  /// the frequency rows would otherwise disappear even though the radio knows
  /// exactly where it is.
  bool get bandInferred =>
      bands.isEmpty && (tech == CellTech.nr ? nrArfcnBand : earfcnBand) != null;

  /// NR bands this app could infer from a channel before the table was whole.
  ///
  /// The full table overlaps by design — n2 sits inside n25, n38 inside n41,
  /// n5 inside n26, n71 inside n105 — so a channel alone often fits more than
  /// one band. These are the bands an earlier build resolved, and they keep
  /// priority: a band added since can identify a carrier none of them claims,
  /// but it can never take one of them over. That is what keeps the A15's n71
  /// reading n71 now that n105 (which covers the same MHz) is in the table.
  static const Set<int> _firstWaveNrBands = {
    1, 2, 3, 5, 7, 8, 12, 13, 14, 20, 25, 26, 28, 30, 38, 41, 48, 66, 70, 71,
    77, 78, 79, 260, 261,
  };

  /// NR band whose ARFCN block contains this cell's channel, or null.
  ///
  /// Null covers two cases: the channel belongs to no band in the table, or it
  /// belongs to more than one and the channel alone cannot choose. A unique
  /// match is what a firmware reporting BAND_UNKNOWN leaves to work with — the
  /// A15 does exactly that on its 631.35 MHz n71 carrier (ARFCN 126270).
  int? get nrArfcnBand {
    if (tech != CellTech.nr) return null;
    final channel = arfcn;
    if (channel == null || channel <= 0) return null;
    final claims = [
      for (final entry in nrBandPlans.entries)
        if (channel >= entry.value.first && channel <= entry.value.last)
          entry.key,
    ];
    if (claims.isEmpty) return null;
    final established = claims.where(_firstWaveNrBands.contains).toList();
    final pool = established.isEmpty ? claims : established;
    return pool.length == 1 ? pool.single : null;
  }

  /// LTE band whose downlink block contains this EARFCN.
  ///
  /// 3GPP gives each band its own EARFCN range on the shared 0.1 MHz raster, so
  /// the ranges never overlap and one lookup identifies the band. Band 106 is
  /// the exception: its build numbers the 900 MHz carrier on its own raster
  /// (see [b106FirstEarfcn]), so that window is checked first.
  int? get earfcnBand {
    if (tech != CellTech.lte) return null;
    final channel = arfcn;
    if (channel == null || channel <= 0) return null;
    if (channel >= b106FirstEarfcn && channel <= b106LastEarfcn) return 106;
    for (final entry in lteBandPlans.entries) {
      final plan = entry.value;
      if (channel >= plan.first && channel <= plan.last) return entry.key;
    }
    return null;
  }

  /// LTE band 106: the 900 MHz LMR/utility band, 935–940 MHz down and
  /// 896–901 MHz up (39 MHz duplex), EARFCN 134292–134341.
  static const int b106FirstEarfcn = 134292;
  static const int b106LastEarfcn = 134341;
  static const double _b106DlLow = 935;
  static const double _b106UlLow = 896;

  /// PLMN of the utility network that numbers its 900 MHz carrier B106.
  ///
  /// The alias is keyed to the network, not to the band number: a band-8 cell
  /// belonging to anyone else still reads B8, and any other band this network
  /// happens to run reads as itself.
  static const String b106Plmn = '313-700';

  /// True when this cell is that network's 900 MHz carrier.
  ///
  /// The band has to agree when the modem names one, but this device often
  /// names none at all — on Android 11, and again after its band lock is
  /// changed — so an unbanded cell on this PLMN still counts as B106. A cell
  /// whose channel places it in another band does not.
  bool get _isB106 {
    if (!kA10eBandAlias || tech != CellTech.lte || plmn != b106Plmn) {
      return false;
    }
    final band = _primaryBand;
    return band == null || band == 8 || band == 106;
  }

  /// This cell's channel number on band 106's raster, or null when the modem
  /// has not reported one.
  ///
  /// Band 8 numbers the same carrier 3450–3799, so both rasters are accepted
  /// and re-expressed on band 106's.
  int? get _b106Channel {
    final channel = arfcn;
    if (!_isB106 || channel == null || channel <= 0) return null;
    if (channel >= b106FirstEarfcn && channel <= b106LastEarfcn) return channel;
    final plan = lteBandPlans[8];
    if (plan == null || channel < plan.first || channel > plan.last) {
      return null;
    }
    final dl = plan.dlLow + 0.1 * (channel - plan.first);
    final renumbered = b106FirstEarfcn + ((dl - _b106DlLow) * 10).round();
    // Only when the carrier really sits inside band 106's block.
    return renumbered >= b106FirstEarfcn && renumbered <= b106LastEarfcn
        ? renumbered
        : null;
  }

  /// The channel number to show.
  ///
  /// The A10e build re-expresses its band-8 EARFCN on band 106's raster, so
  /// 3580 (938.0 MHz on band 8) is shown as 134322 (938.0 MHz on band 106)
  /// instead of mixing the two numbering schemes.
  int? get displayedArfcn {
    final channel = arfcn;
    if (channel == null) return null;
    if (!_isB106) return channel;
    return _b106Channel ?? channel;
  }

  /// The utility network's own raster for band 106, used for a channel the
  /// modem reported on it rather than one re-numbered from band 8.
  double? get _b106OwnMhz {
    final channel = arfcn;
    if (channel == null) return null;
    if (channel < b106FirstEarfcn || channel > b106LastEarfcn) return null;
    return _b106DlLow + 0.1 * (channel - b106FirstEarfcn);
  }

  /// Downlink centre frequency in MHz.
  ///
  /// Every band in [lteBandPlans] / [nrBandPlans] is priced the same way: the
  /// channel's distance from the bottom of the band's block times 0.1 MHz (LTE)
  /// or the global NR raster (NR). A channel outside its band's block is not
  /// priced at all — the modem gave numbers that disagree, and inventing a
  /// frequency for them would be worse than an empty row.
  double? get downlinkMhz {
    final channel = arfcn;
    if (channel == null || channel <= 0) return null;
    if (tech == CellTech.nr) return frequencyMhz;
    if (tech != CellTech.lte) return null;
    if (_isB106) {
      final renumbered = _b106Channel;
      // No channel at all means the modem has not placed the carrier, so the
      // frequency rows stay empty rather than borrowing another site's.
      if (renumbered != null) {
        return _b106DlLow + 0.1 * (renumbered - b106FirstEarfcn);
      }
    }
    // A channel already numbered on band 106's own raster — by this build or by
    // a peer sharing its reading — needs no conversion.
    if (_primaryBand == 106) {
      if (_b106OwnMhz case final mhz?) return mhz;
    }
    final plan = lteBandPlans[_primaryBand];
    if (plan == null) return null;
    if (channel < plan.first || channel > plan.last) return null;
    return plan.dlLow + 0.1 * (channel - plan.first);
  }

  /// Uplink centre frequency in MHz, or null when the band does not pair one
  /// (LTE band 29 is downlink-only, and an unknown band means no guess).
  ///
  /// The uplink is priced from its own block, and clamped to it: bands 66 and
  /// 70 (and NR n66) have a narrower uplink than downlink, so the top of the
  /// band pairs with a frequency the block no longer contains.
  double? get uplinkMhz {
    final dl = downlinkMhz;
    if (dl == null) return null;
    if (tech == CellTech.nr) {
      final plan = nrBandPlans[_primaryBand];
      final offset = plan?.uplinkOffset;
      if (plan == null || offset == null) return null;
      final high = plan.ulHigh;
      return high == null ? dl + offset : math.min(dl + offset, high);
    }
    // Band 106 sits 39 MHz below its downlink, whatever raster the channel
    // number came in on.
    if (_isB106) return dl - (_b106DlLow - _b106UlLow);
    final plan = lteBandPlans[_primaryBand];
    if (plan == null || plan.isDlOnly) return null;
    if (plan.isTdd) return dl;
    final channel = arfcn;
    if (channel == null || channel < plan.first || channel > plan.last) {
      // The only channels outside a band's own window are band 106's: the
      // sharing build numbers that carrier on its own raster.
      if (_primaryBand == 106) {
        final own = _b106OwnMhz;
        if (own != null) return own - (_b106DlLow - _b106UlLow);
      }
      return null;
    }
    final ul = plan.ulLow! + 0.1 * (channel - plan.first);
    final high = plan.ulHigh;
    return high == null ? ul : math.min(ul, high);
  }

  /// LTE band 29 — the 700 MHz supplemental downlink.
  ///
  /// It is downlink-only (the band pairs no uplink at all) and is deployed as
  /// a secondary component of carrier aggregation, never on its own. The radio
  /// therefore reports it with a PCI, a band and a channel but no ECI: there is
  /// no eNB and no sector to decode, which is exactly how CellMapper draws it —
  /// the carrier attached, with no site identity against it.
  bool get isBand29 => tech == CellTech.lte && _primaryBand == 29;

  /// An LTE band with a downlink and no uplink at all.
  ///
  /// 3GPP defines six of them (29, 32, 67, 69, 75 and 76). The band table
  /// carries each band's duplex mode, so the rule is its `isDlOnly` rather
  /// than a hard-coded 29. Such a carrier never serves on its own: a radio
  /// only reports one while it is aggregating it under a primary.
  bool get isSdlLte =>
      tech == CellTech.lte && (lteBandPlans[_primaryBand]?.isDlOnly ?? false);

  /// An LTE carrier that can only ever be a secondary — a supplemental
  /// downlink.
  bool get isSecondaryLte => isSdlLte;

  /// TDD carriers share one band for both directions, so they have a single
  /// frequency rather than a downlink/uplink pair.
  bool get isTdd {
    final dl = downlinkMhz;
    final ul = uplinkMhz;
    return dl != null && ul != null && (ul - dl).abs() < 0.005;
  }

  String? get downlinkLabel =>
      downlinkMhz == null ? null : '${downlinkMhz!.toStringAsFixed(2)} MHz';

  String? get uplinkLabel =>
      uplinkMhz == null ? null : '${uplinkMhz!.toStringAsFixed(2)} MHz';

  String get tacLabel => switch (tech) {
        CellTech.gsm || CellTech.wcdma || CellTech.tdscdma => 'LAC',
        _ => 'TAC',
      };

  String get pciLabel => switch (tech) {
        CellTech.gsm => 'BSIC',
        CellTech.wcdma || CellTech.tdscdma => 'PSC',
        CellTech.cdma => 'SID',
        _ => 'PCI',
      };

  /// PLMN as MCC-MNC, e.g. 310-260.
  String? get plmn {
    if (mcc == null || mnc == null) return null;
    return '$mcc-$mnc';
  }

  String? get cellIdHex {
    final value = _numericCellId;
    if (value == null || value <= 0) return null;
    final hex = value.toRadixString(16).toUpperCase();
    return '0x${hex.padLeft(4, '0')}';
  }

  /// Band numbers to publish to another phone, when they differ from the ones
  /// the modem reported.
  ///
  /// The A10e's carrier is band 106 in its network's numbering, and a peer
  /// parses that JSON with its own model — so the re-code has to travel with
  /// the data instead of staying in this build.
  List<int>? get sharedBands => _isB106 ? const [106] : null;

  String? get bandLabel {
    // The utility network's numbering follows its PLMN, so it survives a modem
    // that reports neither a band nor a channel.
    if (_isB106) return bandName(106);
    if (bands.isEmpty) {
      // The channel alone identifies the band when the modem omits it (or
      // reports -1): unique on the LTE EARFCN raster, and unique on the NR
      // raster only where no two bands share the window.
      final inferred = tech == CellTech.nr ? nrArfcnBand : earfcnBand;
      return inferred == null
          ? null
          : bandName(inferred, is5g: tech.is5g);
    }
    return bands
        .map(
          (b) => bandName(
            _nrRecode?.actual ?? (b == 77 && isCbrsFrequency ? 48 : b),
            is5g: tech.is5g,
          ),
        )
        .join(', ');
  }

  bool get hasQualityDetails => rsrp != null || rsrq != null || sinr != null;
}

/// The utility network's 900 MHz carrier is reported as **B106**, label and
/// plan both.
///
/// That network's engineers number the carrier 106 rather than 8, with its
/// uplink 6 MHz higher than band 8's (EARFCN 3580 = 938.0 down / 899.0 up).
/// Whether the app uses their numbering is the **Anterix B106** switch on the
/// Settings page; it applies to [CellTower.b106Plmn] only, and every other
/// network keeps its 3GPP label.
bool get kA10eBandAlias => BandFilters.anterixB106;

/// Label for one band, e.g. `B71` or `n77`.
String bandName(int band, {bool is5g = false}) => '${is5g ? 'n' : 'B'}$band';

/// One correction to the modem's NR band indicator.
///
/// [reported] is what the modem names, [actual] the band the network really
/// runs; [first]–[last] is the NR-ARFCN window in which the reported band is
/// the wrong answer (the shared window, since the reported band's block is
/// contained in the real one's).
class _NrRecode {
  const _NrRecode({
    required this.reported,
    required this.actual,
    required this.first,
    required this.last,
  });

  final int reported;
  final int actual;
  final int first;
  final int last;
}

/// One LTE band on the 3GPP EARFCN raster.
/// How the 5G layer is attached.
enum NetworkMode { nsa, sa, lte, legacy, unknown }

/// Everything read from one SIM slot.
class SimReading {
  const SimReading({
    required this.slotIndex,
    required this.subscriptionId,
    required this.carrierName,
    required this.isDefault,
    required this.simState,
    required this.networkTypeName,
    required this.cells,
    this.overrideNetworkType = 'NONE',
    this.nrState = '',
    this.nrSignal = false,
  });

  factory SimReading.fromMap(Map<Object?, Object?> map) {
    final rawCells = map['cells'] as List<Object?>? ?? const [];
    return SimReading(
      slotIndex: _int(map['slotIndex']) ?? 0,
      subscriptionId: _int(map['subscriptionId']) ?? -1,
      carrierName: _string(map['carrierName']) ?? '',
      isDefault: map['isDefault'] == true,
      simState: _string(map['simState']) ?? 'UNKNOWN',
      networkTypeName: _string(map['networkTypeName']) ?? 'Unknown',
      cells: rawCells
          .whereType<Map<Object?, Object?>>()
          .map(CellTower.fromMap)
          .toList(),
      overrideNetworkType: _string(map['overrideNetworkType']) ?? 'NONE',
      nrState: _string(map['nrState']) ?? '',
      nrSignal: map['nrConnected'] == true,
    );
  }

  final int slotIndex;
  final int subscriptionId;
  final String carrierName;
  final bool isDefault;
  final String simState;
  final String networkTypeName;
  final List<CellTower> cells;

  /// `TelephonyDisplayInfo.overrideNetworkType`, the value behind the
  /// status-bar 5G / 5G+ indicator: NR_SA, NR_NSA, NR_NSA_MMWAVE, LTE_CA…
  final String overrideNetworkType;

  /// `TelephonyManager.getNrState()`: `NONE`, `RESTRICTED`, `NOT_RESTRICTED`,
  /// `CONNECTED`, or empty when the platform will not answer.
  ///
  /// Some modems — Samsung on Spark NZ among them — keep the NR cell out of
  /// `getAllCellInfo()` while the platform's own NR state says the leg is
  /// **CONNECTED**, so this is the only evidence that 5G is really up.
  final String nrState;

  /// True when the platform reported an NR signal part without a cell
  /// (`nrConnected` in the payload: the NR state is connected, or
  /// `SignalStrength` carried an NR component).
  final bool nrSignal;

  /// True when the platform says the NR leg is connected, cell or no cell.
  bool get nrConnected => nrState == 'CONNECTED' || nrSignal;

  String get label => 'SIM ${slotIndex + 1}';

  bool get hasSim => simState == 'READY';

  CellTower? _registeredTech(CellTech tech) {
    for (final cell in cells) {
      if (cell.registered && cell.tech == tech) return cell;
    }
    return null;
  }

  /// LTE anchor of an NSA pair, or the primary LTE carrier.
  ///
  /// A band 29 carrier is never the anchor: it has no cell identity and exists
  /// only alongside a primary, so it is passed over here and surfaced through
  /// [lteSecondaries] instead. If it is somehow the only registered LTE cell it
  /// is still returned, rather than the slot looking empty.
  CellTower? get lteServing {
    CellTower? fallback;
    for (final cell in cells) {
      if (!cell.registered || cell.tech != CellTech.lte) continue;
      if (cell.isSecondaryLte) {
        fallback ??= cell;
        continue;
      }
      return cell;
    }
    return fallback;
  }

  /// Additional LTE carriers aggregated under the primary.
  ///
  /// Two shapes arrive here. A carrier-aggregation layer is marked registered
  /// by the radio and carries its own identity, so every registered LTE cell
  /// apart from the anchor belongs here. Band 29 is the awkward one: during
  /// 2+29 CA on an S25 the modem reported *three* band 29 cells at 719.5 MHz —
  /// none of them registered, none with a cell identity, none with a band — so
  /// only the platform flag separates one aggregated carrier from two
  /// same-frequency neighbours. When the modem does mark one as registered that
  /// is the secondary; otherwise the strongest is taken, since an aggregated
  /// carrier has to be the one the phone can actually hear best, and the rest
  /// stay in the neighbour list rather than being called attached.
  List<CellTower> get lteSecondaries {
    final primary = lteServing;
    final candidates = cells
        .where(
          (cell) =>
              cell.tech == CellTech.lte &&
              cell != primary &&
              (cell.isSecondaryLte || cell.registered),
        )
        .toList();
    if (candidates.isEmpty) return const [];
    final registered = candidates.where((cell) => cell.registered).toList();
    if (registered.isNotEmpty) return registered;
    final supplemental = candidates
        .where((cell) => cell.isSecondaryLte)
        .toList();
    if (supplemental.isEmpty) return const [];
    final strongest = supplemental.reduce(
      (a, b) => (b.dbm ?? -140) > (a.dbm ?? -140) ? b : a,
    );
    return [strongest];
  }

  /// True when the LTE side is carrying more than one carrier.
  ///
  /// A second registered LTE cell is aggregation. So is any supplemental
  /// downlink, which is why an NSA slot whose 5G leg has quietly gone — the
  /// platform still says `NR_NSA`, no NR cell is reported — reads **LTE+**
  /// as soon as a B29 is underneath: a downlink-only carrier cannot be there
  /// unless it is aggregated. The platform's own CA overrides count too, for
  /// radios that aggregate without exposing the second carrier.
  bool get lteAggregated =>
      lteSecondaries.isNotEmpty ||
      overrideNetworkType == 'LTE_CA' ||
      overrideNetworkType == 'LTE_ADVANCED_PRO';

  /// PLMN of the cell this slot is actually registered on — the main carrier.
  ///
  /// Band 29's supplemental downlink carries MCC/MNC only while it is moving
  /// data, so anything that has to name the network for it takes the anchor's
  /// PLMN rather than the SIM's: on an MVNO the card can read `310-150` while
  /// the cell the phone is attached to belongs to `310-410`.
  String? get registeredPlmn =>
      lteServing?.plmn ?? nrServing?.plmn ?? serving?.plmn;

  /// 5G cell: standalone, or the secondary leg of NSA.
  CellTower? get nrServing => _registeredTech(CellTech.nr);

  CellTower? get serving {
    final nr = nrServing;
    if (nr != null) return nr;
    final lte = lteServing;
    if (lte != null) return lte;
    for (final cell in cells) {
      if (cell.registered) return cell;
    }
    return cells.isEmpty ? null : cells.first;
  }

  /// True when the serving PLMN is a satellite (NTN) network.
  ///
  /// This is the list's `satellite` flag, not its bars offset: an entry may
  /// lift its bars (`boost`) without claiming a satellite link — Ameren's
  /// private LTE does exactly that.
  bool get isSatellite => SignalQuality.isSatellite(serving?.plmn);

  /// True when the operator list tags the serving network as **LTE-M**.
  ///
  /// Android has no LTE-M network type: an eMTC carrier comes back as plain
  /// `LTE` with no way to tell from the cell identity, so this comes from the
  /// list's `lteM` flag on that PLMN.
  bool get isLteM => SignalQuality.isLteM(serving?.plmn);

  /// AT&T runs 26-bit gNB IDs, and in this market the gNB stays a fixed
  /// distance from the co-located LTE eNB (eNB 245029 -> gNB 12295029, the
  /// pair that pinned this down). Only used when the radio hides the NR
  /// identity — Samsung does exactly that while NSA is up.
  static const int attGnbOffset = 12050000;

  bool get _attAnchor {
    final cell = lteServing;
    if (cell == null || !cell.isAtt) return false;
    // Small-cell/DAS eNB ranges do not follow the macro plan, so the offset
    // must not be applied to them either.
    return cell._attSectorPlanApplies;
  }

  /// gNB estimated from the LTE anchor, or null when the real one is known,
  /// the deployment is not AT&T, or no anchor is registered.
  int? get nsaGnbEstimate {
    final anchor = lteServing;
    final nr = nrServing;
    if (anchor == null || nr == null || nr.gnb != null) return null;
    final enb = anchor.enb;
    if (enb == null || !_attAnchor) return null;
    return enb + attGnbOffset;
  }

  bool get _overrideNsa => overrideNetworkType.startsWith('NR_NSA');

  /// NSA: 5G is carried under an LTE anchor. Trust the platform's override
  /// first — OEM radios often hide the NR leg from `getAllCellInfo()`.
  bool get isNsa => _overrideNsa || (nrServing != null && lteServing != null);

  /// SA: 5G on its own, with no LTE anchor registered.
  bool get isSa => !_overrideNsa && nrServing != null && lteServing == null;

  NetworkMode get mode {
    if (_overrideNsa) return NetworkMode.nsa;
    if (nrServing != null && lteServing != null) return NetworkMode.nsa;
    if (nrServing != null) return NetworkMode.sa;
    final cell = serving;
    if (cell == null) return NetworkMode.unknown;
    return switch (cell.tech) {
      CellTech.lte => NetworkMode.lte,
      CellTech.unknown => NetworkMode.unknown,
      CellTech.nr => NetworkMode.sa,
      _ => NetworkMode.legacy,
    };
  }

  String get modeLabel => switch (mode) {
        NetworkMode.nsa => '5G NSA',
        NetworkMode.sa => '5G SA',
        // It is still an LTE radio; only the label changes, and only for a
        // network the operator list tags.
        NetworkMode.lte => isLteM ? '4G LTE-M' : '4G LTE',
        NetworkMode.legacy => serving?.tech.label ?? networkTypeName,
        NetworkMode.unknown => networkTypeName,
      };

  /// Cells heard but not serving.
  ///
  /// The carriers [lteSecondaries] claims are left out — the ones the phone is
  /// aggregating are not neighbours — while the other B29 cells on the same
  /// channel stay here, because that is what they are: candidates heard, not
  /// carriers in use.
  List<CellTower> get neighbours {
    final secondaries = lteSecondaries;
    return cells
        .where((cell) =>
            !cell.registered && !secondaries.contains(cell))
        .toList();
  }

  /// Best explanation for an empty reading on this SIM, or null when fine.
  String? problem({required bool locationEnabled}) {
    if (!hasSim) return 'No SIM card in this slot ($simState).';
    if (!locationEnabled) {
      return 'Location services are off. Android hides cell towers from apps '
          'until location is enabled.';
    }
    if (cells.isEmpty) {
      return 'This SIM reported no cells. Try again outdoors, or toggle '
          'airplane mode to force a fresh scan.';
    }
    return null;
  }
}

/// Everything the native side returned in one poll.
class CellSnapshot {
  const CellSnapshot({
    required this.sims,
    required this.permissionGranted,
    required this.locationEnabled,
    required this.capturedAt,
    this.deviceModel = '',
    this.raw = const {},
  });

  factory CellSnapshot.fromMap(Map<Object?, Object?> map) {
    final rawSims = map['sims'] as List<Object?>? ?? const [];
    return CellSnapshot(
      sims: rawSims
          .whereType<Map<Object?, Object?>>()
          .map(SimReading.fromMap)
          .toList(),
      permissionGranted: map['permissionGranted'] == true,
      locationEnabled: map['locationEnabled'] == true,
      capturedAt: DateTime.fromMillisecondsSinceEpoch(
        _int(map['timestamp']) ?? DateTime.now().millisecondsSinceEpoch,
      ),
      deviceModel: _string(map['deviceModel']) ?? '',
      raw: map,
    );
  }

  final List<SimReading> sims;
  final bool permissionGranted;
  final bool locationEnabled;
  final DateTime capturedAt;
  final String deviceModel;

  int get cellCount => sims.fold(0, (sum, sim) => sum + sim.cells.length);

  /// SIMs that are present and ready, in slot order.
  List<SimReading> get activeSims =>
      sims.where((sim) => sim.hasSim).toList()..sort(
          (a, b) => a.slotIndex.compareTo(b.slotIndex));

  SimReading? get primary {
    for (final sim in sims) {
      if (sim.isDefault) return sim;
    }
    return sims.isEmpty ? null : sims.first;
  }

  bool get hasSim => sims.any((sim) => sim.hasSim);

  bool get isDualSim => activeSims.length > 1;

  /// The payload exactly as the native side produced it.
  final Map<Object?, Object?> raw;

  /// JSON body served over the LAN, addressed by another phone.
  ///
  /// Cells go out as this build reads them: the A10e publishes its 900 MHz
  /// carrier as band 106 with band 106's channel number, so the peer's parser —
  /// which has no re-code of its own — renders the same tower numbering this
  /// phone shows instead of B8 / 3580 / 893.
  Map<Object?, Object?> toJsonMap() {
    final rawSims = raw['sims'];
    if (rawSims is! List) return raw;
    return {
      ...raw,
      'sims': [
        for (final sim in rawSims)
          if (sim is Map<Object?, Object?>)
            {...sim, 'cells': _sharedCells(sim['cells'])}
          else
            sim,
      ],
    };
  }

  List<Object?> _sharedCells(Object? cells) {
    if (cells is! List) return const [];
    return [
      for (final cell in cells)
        if (cell is Map<Object?, Object?>) _sharedCell(cell) else cell,
    ];
  }

  /// One cell as a peer should read it: its band list and channel replaced when
  /// this build numbers them differently from the modem.
  Map<Object?, Object?> _sharedCell(Map<Object?, Object?> cell) {
    final parsed = CellTower.fromMap(cell);
    final bands = parsed.sharedBands;
    final arfcn = parsed.displayedArfcn;
    if (bands == null && arfcn == parsed.arfcn) return cell;
    return {
      ...cell,
      'bands': ?bands,
      'arfcn': ?arfcn,
    };
  }
}

/// Turns dBm into a 0-5 bar count and a plain-language verdict.
class SignalQuality {
  const SignalQuality._();

  static const int maxBars = 5;

  /// Bar scale requested for both LTE and NR:
  ///
  ///   >= -84        5 bars
  ///   -94 .. -85    4 bars
  ///   -104 .. -95   3 bars
  ///   -114 .. -105  2 bars
  ///   -124 .. -115  1 bar
  ///   below -124    0 bars
  ///
  /// [boostDbm] raises the level before it is counted, which is how a
  /// satellite link gets its own scale — see [boostFor].
  static int barsFor({int? dbm, int? level, double boostDbm = 0}) {
    if (dbm == null) {
      return level == null ? 0 : (level + 1).clamp(0, maxBars);
    }
    final value = (dbm + boostDbm).round();
    if (value >= -84) return 5;
    if (value >= -94) return 4;
    if (value >= -104) return 3;
    if (value >= -114) return 2;
    if (value >= -124) return 1;
    return 0;
  }

  /// Extra dB added to a satellite (NTN) link before it is counted into bars.
  ///
  /// A satellite cell reaches the phone far weaker than a terrestrial one at
  /// the same usable quality, so the operator list on GitHub can carry a
  /// `boost` (in dB) next to a PLMN. Only the bar count uses the raised level:
  /// the dBm readout stays the raw figure the modem reported, so the card never
  /// claims a signal the radio did not see.
  ///
  /// With the 20 dB the list defaults to, this reproduces the satellite scale
  /// exactly — 5 bars above -104, then 4 at -114..-105, 3 at -124..-115, 2 at
  /// -134..-125, 1 at -144..-135:
  ///
  ///   -104 - (-105) -> -84 .. -85 -> 5 bars
  ///   -144 - (-144) -> -124       -> 1 bar
  static Map<String, double> _boosts = const {};

  /// PLMNs the operator list flags with `satellite: true`.
  static Set<String> _satellites = const {};

  /// PLMNs the operator list flags with `lteM: true`.
  static Set<String> _lteMs = const {};

  /// PLMNs that are SpaceX direct-to-cell satellite carriers, and therefore
  /// always count their bars on the satellite scale.
  ///
  /// These are facts about the network rather than names, so they do not have
  /// to wait for the operator list to catch up — a phone that has never
  /// fetched the file still shows a satellite link's bars correctly. An entry
  /// in the list with its own `boost` (or `satellite`) takes precedence.
  static const Map<String, double> satelliteBoostDefaults = {
    '310-830': 20, // T-Satellite
    '312-190': 20, // T-911
  };

  /// Replaces the per-PLMN boost table (the operator list owns it).
  static void setBoosts(Map<String, double> boosts) {
    _boosts = Map<String, double>.unmodifiable(boosts);
  }

  /// Replaces the set of PLMNs the list flags `satellite`.
  static void setSatellites(Set<String> plmns) {
    _satellites = Set<String>.unmodifiable(plmns);
  }

  /// Replaces the set of PLMNs the list flags `lteM`.
  static void setLteMs(Set<String> plmns) {
    _lteMs = Set<String>.unmodifiable(plmns);
  }

  /// The table in use, keyed by `310-830` style PLMN.
  static Map<String, double> get boosts => _boosts;

  /// True for a PLMN that the list, or [satelliteBoostDefaults], flags as
  /// satellite.
  ///
  /// A `boost` on its own does not make a network satellite: it only lifts the
  /// bars, which a terrestrial network may want for its own reasons.
  static bool isSatellite(String? plmn) {
    if (plmn == null) return false;
    return _satellites.contains(plmn) ||
        satelliteBoostDefaults.containsKey(plmn);
  }

  /// True for a PLMN the operator list tags `lteM`.
  ///
  /// Nothing about the cell identifies LTE-M, so unlike [isSatellite] there is
  /// no built-in default: a network only reads **LTE-M** when the list says so.
  static bool isLteM(String? plmn) {
    if (plmn == null) return false;
    return _lteMs.contains(plmn);
  }

  static double boostFor(String? plmn) {
    if (plmn == null) return 0;
    final listed = _boosts[plmn];
    if (listed != null) return listed;
    return satelliteBoostDefaults[plmn] ?? 0;
  }

  static String label(int bars) => switch (bars) {
        >= 5 => 'Excellent',
        4 => 'Good',
        3 => 'Fair',
        2 => 'Weak',
        1 => 'Very weak',
        _ => 'No signal',
      };

  /// Rough distance estimate from LTE timing advance (1 TA step ~ 78 m).
  static String? distanceFromTimingAdvance(int? ta) {
    if (ta == null || ta <= 0) return null;
    final metres = ta * 78;
    if (metres < 1000) return '~${metres.clamp(78, 999)} m';
    return '~${(metres / 1000).toStringAsFixed(1)} km';
  }

  /// Bar count as a 0-1 fraction, useful for layout maths.
  static double fraction(int bars) => math.max(0.0, bars / maxBars);
}

int? _int(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

String? _string(Object? value) {
  if (value == null) return null;
  final text = value.toString().trim();
  return text.isEmpty ? null : text;
}
