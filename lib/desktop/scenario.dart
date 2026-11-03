import 'dart:math';

import '../models/band_tables.dart';

/// gNB ID length per operator, the same rule the app uses to split an NCI.
int gnbBitsFor(String plmn) {
  const att = {'310-410', '310-150', '310-170', '310-380', '313-100'};
  if (att.contains(plmn)) return 26;
  if (plmn == '310-260' || plmn == '312-190') return 24;
  return 22;
}

/// One cell in a served payload, in the shape the phone's own JSON uses.
class ScenarioCell {
  const ScenarioCell({
    required this.tech,
    this.registered = true,
    this.band,
    this.arfcn,
    this.dbm = -90,
    this.pci = 100,
    this.tac,
    this.enb,
    this.gnb,
    this.sector,
    this.anonymous = false,
  });

  final String tech; // 'LTE' or 'NR'
  final bool registered;
  final int? band;
  final int? arfcn;
  final int dbm;
  final int pci;
  final int? tac;
  final int? enb;
  final int? gnb;
  final int? sector;

  /// True for a cell a modem reports with no PLMN at all: a neighbour, or a
  /// supplemental downlink that is not moving data yet.
  final bool anonymous;

  bool get isNr => tech == 'NR';

  /// The 28-bit ECI for LTE, or the 36-bit NCI for NR, packed from the site
  /// identity the way the operator's gNB width expects.
  String? cellIdFor(String? mcc, String? mnc) {
    if (isNr) {
      if (gnb == null) return null; // NSA legs carry no NCI on real radios
      final shift = 36 - gnbBitsFor('$mcc-$mnc');
      return ((gnb! << shift) | (sector ?? 0)).toString();
    }
    if (enb == null) return null;
    return ((enb! << 8) | (sector ?? 0)).toString();
  }

  Map<String, Object?> toMap(String? mcc, String? mnc, int drift) => {
        'type': tech,
        'registered': registered,
        'cellId': cellIdFor(mcc, mnc),
        'tac': tac,
        'pci': pci,
        'mcc': anonymous ? null : mcc,
        'mnc': anonymous ? null : mnc,
        'dbm': dbm + drift,
        'level': 3,
        'arfcn': arfcn,
        'bands': [if (band != null && band! > 0) band!],
        'rsrp': dbm + drift,
        'rsrq': null,
        'sinr': null,
        'timingAdvance': null,
      };
}

/// One SIM's worth of cells.
class ScenarioSim {
  const ScenarioSim({
    required this.carrierName,
    required this.mcc,
    required this.mnc,
    required this.override,
    required this.cells,
    this.slotIndex = 0,
  });

  final String carrierName;
  final String mcc;
  final String mnc;

  /// `NONE`, `LTE_CA`, `LTE_ADVANCED_PRO`, `NR_NSA`, `NR_SA` or `NR_ADVANCED`.
  final String override;
  final List<ScenarioCell> cells;
  final int slotIndex;

  String get plmn => '$mcc-$mnc';

  Map<String, Object?> toMap(int drift) => {
        'slotIndex': slotIndex,
        'subscriptionId': slotIndex + 1,
        'carrierName': carrierName,
        'isDefault': slotIndex == 0,
        'simState': 'READY',
        'networkTypeName': override.contains('NR') ? 'NR' : 'LTE',
        'overrideNetworkType': override,
        'plmn': plmn,
        'cells': [for (final cell in cells) cell.toMap(mcc, mnc, drift)],
      };
}

/// A complete test reading the desktop can serve on 41729.
class Scenario {
  const Scenario({required this.id, required this.name, required this.sims});

  final String id;
  final String name;
  final List<ScenarioSim> sims;

  Map<String, Object?> payload({int drift = 0}) => {
        'permissionGranted': true,
        'locationEnabled': true,
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'deviceModel': 'Sector Scout Desktop (test source)',
        'cellCount': sims.fold<int>(0, (count, sim) => count + sim.cells.length),
        'sims': [for (final sim in sims) sim.toMap(drift)],
      };

  /// A phone cannot tell you which advanced mode it holds, so the presets show
  /// the states that are otherwise hard to reach: an unlisted band, an NSA leg
  /// with no identity, a downlink-only aggregation, and two SIMs at once.
  static const List<Scenario> presets = [
    Scenario(
      id: 'tmo-n41',
      name: 'T-Mobile n41 (SA, modem says n38)',
      sims: [
        ScenarioSim(
          carrierName: 'T-Mobile',
          mcc: '310',
          mnc: '260',
          override: 'NR_SA',
          cells: [
            ScenarioCell(
              tech: 'NR',
              band: 38,
              arfcn: 519000,
              dbm: -88,
              pci: 42,
              gnb: 1053255,
              sector: 312,
              tac: 12345,
            ),
          ],
        ),
      ],
    ),
    Scenario(
      id: 'tmo-n71',
      name: 'T-Mobile n71 (band unknown)',
      sims: [
        ScenarioSim(
          carrierName: 'T-Mobile',
          mcc: '310',
          mnc: '260',
          override: 'NR_SA',
          cells: [
            ScenarioCell(
              tech: 'NR',
              arfcn: 126270, // 631.35 MHz: only n71 owns this channel
              dbm: -104,
              pci: 311,
              gnb: 1053255,
              sector: 12,
            ),
          ],
        ),
      ],
    ),
    Scenario(
      id: 'att-nsa',
      name: 'AT&T 5G NSA (anchor + NR leg)',
      sims: [
        ScenarioSim(
          carrierName: 'AT&T',
          mcc: '310',
          mnc: '410',
          override: 'NR_NSA',
          cells: [
            ScenarioCell(
              tech: 'LTE',
              band: 2,
              arfcn: 700,
              dbm: -95,
              pci: 61,
              tac: 25601,
              enb: 245029,
              sector: 36,
            ),
            // No gNB: an NSA leg really is served without an NCI, which is
            // what makes the app show `gNB (est.)`.
            ScenarioCell(
              tech: 'NR',
              band: 5,
              arfcn: 173800,
              dbm: -102,
              pci: 220,
            ),
          ],
        ),
      ],
    ),
    Scenario(
      id: 'anterix-b106',
      name: 'Anterix B106 (LTE-M)',
      sims: [
        ScenarioSim(
          carrierName: 'Ameren',
          mcc: '313',
          mnc: '700',
          override: 'NONE',
          cells: [
            ScenarioCell(
              tech: 'LTE',
              band: 8,
              arfcn: 3580,
              dbm: -92,
              pci: 71,
              tac: 4101,
              enb: 12345,
              sector: 7,
            ),
          ],
        ),
      ],
    ),
    Scenario(
      id: 'dual-sim',
      name: 'Dual SIM (T-Mobile + Verizon)',
      sims: [
        ScenarioSim(
          carrierName: 'T-Mobile',
          mcc: '310',
          mnc: '260',
          override: 'LTE_CA',
          cells: [
            ScenarioCell(
              tech: 'LTE',
              band: 41,
              arfcn: 40490,
              dbm: -87,
              pci: 133,
              tac: 12345,
              enb: 30722,
              sector: 36,
            ),
          ],
        ),
        ScenarioSim(
          carrierName: 'Verizon',
          mcc: '311',
          mnc: '480',
          override: 'LTE_CA',
          slotIndex: 1,
          cells: [
            ScenarioCell(
              tech: 'LTE',
              band: 13,
              arfcn: 5230,
              dbm: -101,
              pci: 22,
              tac: 4201,
              enb: 195007,
              sector: 3,
            ),
          ],
        ),
      ],
    ),
  ];

  static Scenario? byId(String id) {
    for (final scenario in presets) {
      if (scenario.id == id) return scenario;
    }
    return null;
  }

  /// Jitters the level so the bars and the "read Ns ago" line visibly move.
  static int drift(Random random) => random.nextInt(5) - 2;
}

/// Middle of a band's channel window, so an editor starts somewhere valid.
int? defaultChannel(int band, bool nr) {
  final plan = nr ? nrBandPlans[band] : lteBandPlans[band];
  if (plan == null) return null;
  return (plan.first + plan.last) ~/ 2;
}

/// How many extra LTE carriers can be aggregated under the anchor. Real phones
/// carry two or three; the ceiling keeps the editor a row per layer.
const int maxLteLayers = 4;

/// How many NR legs one source can carry.
const int maxNrCarriers = 5;

/// How many neighbour cells the source will report. A real scan on a Samsung
/// hands over five or six; the ceiling keeps the list a list.
const int maxNeighbours = 12;

/// FR2, the millimetre-wave bands. A modem cannot sit on one standalone: mmWave
/// is only ever a secondary of NR CA, so a lone FR2 carrier is not a state a
/// phone can be in.
const Set<int> fr2Bands = {257, 258, 259, 260, 261, 262};

/// The override values the payload may carry.
const Set<String> customOverrides = {
  'NONE',
  'LTE_CA',
  'LTE_ADVANCED_PRO',
  'NR_NSA',
  'NR_SA',
};

/// The overrides that mean the payload carries LTE and nothing else.
const Set<String> lteOnlyOverrides = {'NONE', 'LTE_CA', 'LTE_ADVANCED_PRO'};

int? _asInt(Object? value, int? fallback) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim()) ?? fallback;
  return fallback;
}

/// `n5`, `B30`, `band 5` and `5` all mean band 5.
int? parseBandLabel(String text) {
  var cleaned = text.trim();
  for (final prefix in const ['band', 'Band', 'BAND', 'B', 'b', 'N', 'n']) {
    if (cleaned.startsWith(prefix) && cleaned.length > prefix.length) {
      cleaned = cleaned.substring(prefix.length);
      break;
    }
  }
  return int.tryParse(cleaned.trim());
}

/// One editable carrier: the LTE anchor, a carrier aggregated under it, or an
/// NR leg. The identity fields are the site the carrier looks like, so a real
/// reading can be reproduced rather than approximated.
class CustomCarrier {
  const CustomCarrier({
    this.enabled = true,
    this.band,
    this.arfcn,
    this.dbm = -100,
    this.site,
    this.sector,
    this.pci,
    this.tac,
  });

  final bool enabled;
  final int? band;

  /// EARFCN on LTE, NR-ARFCN on NR. Null falls back to the middle of the band.
  final int? arfcn;
  final int dbm;

  /// eNB (LTE) or gNB (NR). Null leaves the cell with no identity at all.
  final int? site;
  final int? sector;
  final int? pci;
  final int? tac;

  bool get hasBand => (band ?? 0) > 0;

  static const Object _keep = Object();

  CustomCarrier copyWith({
    bool? enabled,
    Object? band = _keep,
    Object? arfcn = _keep,
    int? dbm,
    Object? site = _keep,
    Object? sector = _keep,
    Object? pci = _keep,
    Object? tac = _keep,
  }) =>
      CustomCarrier(
        enabled: enabled ?? this.enabled,
        band: identical(band, _keep) ? this.band : band as int?,
        arfcn: identical(arfcn, _keep) ? this.arfcn : arfcn as int?,
        dbm: dbm ?? this.dbm,
        site: identical(site, _keep) ? this.site : site as int?,
        sector: identical(sector, _keep) ? this.sector : sector as int?,
        pci: identical(pci, _keep) ? this.pci : pci as int?,
        tac: identical(tac, _keep) ? this.tac : tac as int?,
      );

  Map<String, Object?> toJson({required bool nr}) {
    final siteKey = nr ? 'gnb' : 'enb';
    return {
      'enabled': enabled,
      'band': band,
      'arfcn': arfcn,
      'dbm': dbm,
      siteKey: site,
      'sector': sector,
      'pci': pci,
      'tac': tac,
    };
  }

  /// One saved row, with anything missing filled from [fallback]. A cleared box
  /// stays cleared: the identity is then left out of the payload.
  factory CustomCarrier.fromJson(
    Object? raw,
    CustomCarrier fallback, {
    required bool nr,
  }) {
    if (raw is! Map<Object?, Object?>) return fallback;
    return CustomCarrier(
      enabled: raw['enabled'] != false,
      band: _asInt(raw['band'], fallback.band),
      arfcn: _asInt(raw['arfcn'], fallback.arfcn),
      dbm: _asInt(raw['dbm'], fallback.dbm) ?? fallback.dbm,
      site: _asInt(raw[nr ? 'gnb' : 'enb'], fallback.site),
      sector: _asInt(raw['sector'], fallback.sector),
      pci: _asInt(raw['pci'], fallback.pci),
      tac: _asInt(raw['tac'], fallback.tac),
    );
  }
}

/// Cells heard but not serving, kept as a count and a band because a neighbour
/// carries nothing else a phone reads: no PLMN, no identity, no TAC.
class CustomNeighbours {
  const CustomNeighbours({this.enabled = true, this.count = 0, this.band = 2});

  final bool enabled;
  final int count;
  final int band;

  CustomNeighbours copyWith({bool? enabled, int? count, int? band}) =>
      CustomNeighbours(
        enabled: enabled ?? this.enabled,
        count: count ?? this.count,
        band: band ?? this.band,
      );

  Map<String, Object?> toJson() => {
        'enabled': enabled,
        'count': count,
        'band': band,
      };

  factory CustomNeighbours.fromJson(Object? raw) {
    const defaults = CustomNeighbours();
    if (raw is! Map<Object?, Object?>) return defaults;
    final count = _asInt(raw['count'], defaults.count) ?? defaults.count;
    final band = _asInt(raw['band'], defaults.band) ?? defaults.band;
    return CustomNeighbours(
      enabled: raw['enabled'] != false,
      count: count.clamp(0, maxNeighbours).toInt(),
      band: band > 0 ? band : defaults.band,
    );
  }
}

/// The custom source the editor page builds.
///
/// Nothing here is a preset: the network, the anchor, every aggregated carrier
/// and every NR leg come from the fields, so `B30 anchor + n5`, `n41` alone and
/// `B2 anchor + B29 SDL + n5 + n77` are one code path. The override only
/// decides which of those carriers is sent.
class CustomSource {
  const CustomSource({
    this.carrierName = 'AT&T',
    this.mcc = '310',
    this.mnc = '410',
    this.override = 'NR_NSA',
    this.lte = const CustomCarrier(
      band: 30,
      arfcn: 9820,
      dbm: -104,
      site: 30722,
      sector: 36,
      pci: 76,
      tac: 12345,
    ),
    this.lteLayers = const [],
    this.nr = const [
      CustomCarrier(band: 5, arfcn: 176300, dbm: -98, pci: 512),
    ],
    this.neighbours = const CustomNeighbours(),
  });

  final String carrierName;
  final String mcc;
  final String mnc;

  /// One of [customOverrides].
  final String override;

  /// The LTE anchor, switched on or off.
  final CustomCarrier? lte;

  /// Carriers aggregated under the anchor: a band 29 supplemental downlink, or
  /// another band as a CA layer.
  final List<CustomCarrier> lteLayers;

  /// The NR legs. Under NSA they are served without an identity.
  final List<CustomCarrier> nr;

  final CustomNeighbours neighbours;

  String get plmn => '$mcc$mnc';

  bool get isNrSa => override == 'NR_SA';
  bool get isNsa => override == 'NR_NSA';
  bool get isLteOnly => lteOnlyOverrides.contains(override);

  /// The anchor that reaches the payload. Standalone has no LTE at all, so the
  /// anchor is held back rather than served as a second primary.
  CustomCarrier? get anchor {
    final row = lte;
    if (row == null || !row.enabled || !row.hasBand) return null;
    if (isNrSa) return null;
    return row;
  }

  /// Aggregated carriers need an anchor to aggregate under.
  List<CustomCarrier> get servedLteLayers {
    if (anchor == null) return const [];
    final rows = [
      for (final row in lteLayers)
        if (row.enabled && row.hasBand) row,
    ];
    return rows.take(maxLteLayers).toList();
  }

  /// Every NR leg that is switched on, before the override has its say.
  List<CustomCarrier> get switchedOnNr {
    final rows = [
      for (final row in nr)
        if (row.enabled && row.hasBand) row,
    ];
    return rows.take(maxNrCarriers).toList();
  }

  /// The NR legs that reach the payload.
  ///
  /// One rule is applied here rather than in the editor, so the summary and the
  /// payload can never disagree: with no LTE anchor a lone FR2 carrier is
  /// dropped, because mmWave without CA is not a state any modem reports.
  List<CustomCarrier> get servedNr {
    if (isLteOnly) return const [];
    final rows = switchedOnNr;
    if (anchor == null &&
        rows.length == 1 &&
        fr2Bands.contains(rows.first.band)) {
      return const [];
    }
    return rows;
  }

  bool get sendsLte => anchor != null;
  bool get sendsNr => servedNr.isNotEmpty;

  /// What goes on the wire: a source with no NR leg cannot claim NR.
  String get wireOverride {
    if (sendsNr) return override;
    // An LTE-only source may still claim aggregation, but nothing that names
    // NR: the payload carries no NR cell to back it up.
    if (sendsLte && (override == 'LTE_CA' || override == 'LTE_ADVANCED_PRO')) {
      return override;
    }
    return 'NONE';
  }

  /// The carriers the payload actually carries, in order — the console's own
  /// read-back, built from what is served rather than from the editor's rows.
  String get summary {
    final parts = <String>[];
    final lteRow = anchor;
    if (lteRow != null) parts.add('B${lteRow.band} anchor');
    for (final layer in servedLteLayers) {
      parts.add(layer.band == 29 ? 'B${layer.band} SDL' : 'B${layer.band} CA');
    }
    for (final leg in servedNr) {
      parts.add('n${leg.band}');
    }
    if (servedNr.isEmpty && lteRow == null) {
      for (final leg in switchedOnNr) {
        parts.add('n${leg.band} (mmWave, not sent)');
      }
    }
    if (neighbours.enabled && neighbours.count > 0) {
      parts.add('${neighbours.count} neighbours');
    }
    return parts.isEmpty ? 'no carriers' : parts.join(' + ');
  }

  Map<String, Object?> toJson() => {
        'plmn': plmn,
        'carrier': carrierName,
        'override': override,
        'lte': lte?.toJson(nr: false),
        'lte_layers': [for (final row in lteLayers) row.toJson(nr: false)],
        'nr': [for (final row in nr) row.toJson(nr: true)],
        'neighbours': neighbours.toJson(),
      };

  /// Tolerant on purpose: a half-written file must not stop the page from
  /// opening, and every field falls back to the console's own default.
  factory CustomSource.fromJson(Object? raw) {
    const defaults = CustomSource();
    if (raw is! Map<Object?, Object?>) return defaults;

    String text(String key, String fallback) {
      final value = raw[key];
      return value is String && value.trim().isNotEmpty
          ? value.trim()
          : fallback;
    }

    var mcc = defaults.mcc;
    var mnc = defaults.mnc;
    final plmn = raw['plmn'];
    if (plmn is String) {
      final digits = plmn.replaceAll(RegExp('[^0-9]'), '');
      if (digits.length >= 5) {
        mcc = digits.substring(0, 3);
        mnc = digits.substring(3);
      }
    }

    final lte = raw.containsKey('lte')
        ? CustomCarrier.fromJson(raw['lte'], defaults.lte!, nr: false)
        : defaults.lte;

    final layers = <CustomCarrier>[];
    final rawLayers = raw['lte_layers'];
    if (rawLayers is List<Object?>) {
      for (final entry in rawLayers.take(maxLteLayers)) {
        layers.add(CustomCarrier.fromJson(entry, defaults.lte!, nr: false));
      }
    }

    final nrRows = <CustomCarrier>[];
    final rawNr = raw['nr'];
    if (rawNr is List<Object?>) {
      for (final entry in rawNr.take(maxNrCarriers)) {
        nrRows.add(CustomCarrier.fromJson(entry, defaults.nr.first, nr: true));
      }
    } else {
      nrRows.addAll(defaults.nr);
    }

    // The phone sends one NR_ADVANCED value for both flavours, so what tells
    // them apart is the anchor: NSA keeps it, SA drops it.
    final label = text('override', defaults.override);
    var override = customOverrides.contains(label) ? label : defaults.override;
    if (label == 'NR_ADVANCED') {
      override = (lte != null && lte.enabled && lte.hasBand) ? 'NR_NSA' : 'NR_SA';
    }

    return CustomSource(
      carrierName: text('carrier', defaults.carrierName),
      mcc: mcc,
      mnc: mnc,
      override: override,
      lte: lte,
      lteLayers: layers,
      nr: nrRows,
      neighbours: CustomNeighbours.fromJson(raw['neighbours']),
    );
  }

  Scenario build() {
    final cells = <ScenarioCell>[];
    final lteRow = anchor;
    final anchorPci = lteRow?.pci ?? 76;
    final anchorDbm = lteRow?.dbm ?? -100;

    if (lteRow != null) {
      cells.add(
        ScenarioCell(
          tech: 'LTE',
          band: lteRow.band,
          arfcn: lteRow.arfcn ?? defaultChannel(lteRow.band!, false),
          dbm: lteRow.dbm,
          pci: anchorPci,
          tac: lteRow.tac,
          enb: lteRow.site,
          sector: lteRow.sector,
        ),
      );
      for (final layer in servedLteLayers) {
        // Band 29 is a supplemental downlink: it arrives with no cell identity,
        // no TAC and no PLMN, which is what tells it apart from the anchor.
        final supplemental = layer.band == 29;
        cells.add(
          ScenarioCell(
            tech: 'LTE',
            registered: !supplemental,
            anonymous: supplemental,
            band: layer.band,
            arfcn: layer.arfcn ?? defaultChannel(layer.band!, false),
            dbm: layer.dbm,
            pci: layer.pci ?? (anchorPci + 40) % 504,
            tac: supplemental ? null : layer.tac,
            enb: supplemental ? null : layer.site,
            sector: supplemental ? null : layer.sector,
          ),
        );
      }
    }

    // Under an LTE anchor the 5G leg arrives without its identity — no NCI, so
    // no sector, and no TAC either. Sending one would hide the app's estimate
    // path behind a number no phone would report.
    final nsa = isNsa;
    for (final leg in servedNr) {
      cells.add(
        ScenarioCell(
          tech: 'NR',
          band: leg.band,
          arfcn: leg.arfcn ?? defaultChannel(leg.band!, true),
          dbm: leg.dbm,
          pci: leg.pci ?? 512,
          tac: nsa ? null : leg.tac,
          gnb: nsa ? null : leg.site,
          sector: nsa ? null : leg.sector,
        ),
      );
    }

    if (neighbours.enabled && neighbours.count > 0) {
      final count = neighbours.count.clamp(0, maxNeighbours).toInt();
      for (var index = 0; index < count; index++) {
        cells.add(
          ScenarioCell(
            tech: 'LTE',
            registered: false,
            anonymous: true,
            band: neighbours.band,
            arfcn: defaultChannel(neighbours.band, false),
            dbm: anchorDbm - 6 - 4 * index,
            pci: (anchorPci + 40 * (index + 1)) % 504,
          ),
        );
      }
    }

    return Scenario(
      id: 'custom',
      name: 'Custom ($summary)',
      sims: [
        ScenarioSim(
          carrierName: carrierName.isEmpty ? '$mcc-$mnc' : carrierName,
          mcc: mcc,
          mnc: mnc,
          override: wireOverride,
          cells: cells,
        ),
      ],
    );
  }
}
