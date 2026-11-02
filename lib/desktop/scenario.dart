import 'dart:math';

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
        'mcc': mcc,
        'mnc': mnc,
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

  /// A single-carrier reading built from the fields the editor exposes.
  factory Scenario.custom({
    required String carrierName,
    required String mcc,
    required String mnc,
    required int band,
    int? arfcn,
    int dbm = -90,
    String override = 'NONE',
    bool nr = false,
  }) {
    final inferred = arfcn ?? _defaultChannel(band, nr);
    return Scenario(
      id: 'custom',
      name: 'Custom',
      sims: [
        ScenarioSim(
          carrierName: carrierName,
          mcc: mcc,
          mnc: mnc,
          override: override,
          cells: [
            ScenarioCell(
              tech: nr ? 'NR' : 'LTE',
              band: band,
              arfcn: inferred,
              dbm: dbm,
              pci: 100,
              tac: 12345,
              enb: nr ? null : 30722,
              gnb: nr ? 1053255 : null,
              sector: 36,
            ),
          ],
        ),
      ],
    );
  }

  /// Middle of the band's channel window, so the editor starts somewhere valid.
  static int? _defaultChannel(int band, bool nr) {
    const lteChannels = {2: 700, 4: 2200, 5: 2450, 12: 5100, 13: 5230, 41: 40490, 66: 66436, 71: 68586};
    const nrChannels = {5: 173800, 41: 519000, 71: 126270, 77: 650000, 78: 640000};
    return (nr ? nrChannels : lteChannels)[band];
  }

  static Scenario? byId(String id) {
    for (final scenario in presets) {
      if (scenario.id == id) return scenario;
    }
    return null;
  }

  /// Jitters the level so the bars and the "read Ns ago" line visibly move.
  static int drift(Random random) => random.nextInt(5) - 2;
}
