import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/cell_snapshot.dart';

/// Your operator list, on your GitHub.
///
/// The app fetches this once per run and caches the result on the device (the
/// pinned notification reads the same cache). Override it at build time if the
/// file moves:
///
/// ```bash
/// flutter build apk --release \
///   --dart-define=CARRIER_NAMES_URL=https://raw.githubusercontent.com/<you>/<repo>/main/plmns.json
/// ```
///
/// There is no list compiled into the app: if the file has never been fetched,
/// the cards show the SIM's own name.
///
/// Besides a name, an entry may carry the tags that describe how that network
/// reads on the cards:
///
/// ```json
/// {
///   "310-260": { "brand": "T-Mobile", "fiveG": "5GUC", "nrBits": 24 },
///   "310-830": { "brand": "T-Satellite", "satellite": true },
///   "312-190": { "brand": "T-911", "boost": 20 },
///   "313-700": { "brand": "Ameren", "boost": 15, "lteM": true }
/// }
/// ```
///
/// `satellite: true` marks a satellite link (the card shows `SAT`) and implies
/// the default 20 dB. `boost` sets the dB explicitly, on its own, without
/// claiming the link is satellite. `lteM: true` says the network runs LTE-M /
/// eMTC, which the card shows as `LTE-M` — Android reports an eMTC carrier as
/// plain LTE, so the list is the only place that can say otherwise.
///
/// `fiveG` is the badge the network draws for NR Advanced — `5G+` at AT&T,
/// `5GUC` at T-Mobile, `5GUW` at Verizon, or its own word elsewhere. The
/// built-in styles stay as a fallback, so an untagged entry reads exactly as
/// it always did. `nrBits` is the gNB ID width inside the 36-bit NCI, which
/// splits an NR cell into gNB and sector: AT&T runs 26, T-Mobile 24, most
/// others 22. A tag beats those defaults, so a network that picked a
/// different split needs no release.
const String kCarrierNamesUrl = String.fromEnvironment('CARRIER_NAMES_URL');

/// The satellite bars offset when an entry is only flagged `satellite`.
const double kDefaultSatelliteBoost = 20;

/// One parsed operator list: the names, the per-PLMN bars offsets, and the
/// PLMNs the list flags as satellite links.
class CarrierTable {
  const CarrierTable({
    this.names = const {},
    this.boosts = const {},
    this.satellites = const {},
    this.lteMs = const {},
    this.fiveGs = const {},
    this.nrBits = const {},
  });

  final Map<String, String> names;
  final Map<String, double> boosts;

  /// PLMNs flagged `satellite: true` — the ones the card marks `SAT`.
  final Set<String> satellites;

  /// PLMNs flagged `lteM: true` — the ones the card reads as **LTE-M**.
  final Set<String> lteMs;

  /// PLMNs carrying `fiveG`: the label the badge shows on NR Advanced.
  ///
  /// The three US brands are built into the app, but they are not the only
  /// networks that style NR Advanced, and a brand that renames its badge
  /// should not need a release to say so. An entry here wins over the
  /// built-in style, in the card and in the pinned notification.
  final Map<String, String> fiveGs;

  /// PLMNs carrying `nrBits`: the gNB ID width inside the 36-bit NCI.
  ///
  /// 3GPP lets each operator choose the split, so it cannot be derived from
  /// the NCI. AT&T runs 26 bits, T-Mobile 24, and most others 22; a network
  /// that picked something else — or changes it — says so here instead of
  /// waiting for a build.
  final Map<String, int> nrBits;

  bool get isEmpty => names.isEmpty;
}

/// Turns a PLMN into the operator's name.
///
/// The name on the SIM is only what the card carries — often an MVNO, a roaming
/// partner, or a stale localisation. The PLMN the modem is registered on is
/// matched against the list instead, so 310-410 reads as AT&T regardless of
/// which SIM is inserted.
class CarrierNames {
  CarrierNames._();

  /// Where the list lives, in the order tried. The build-time override wins;
  /// the repo paths are the conventional file names, so renaming the file to
  /// any of them keeps working without a rebuild.
  static List<String> get urls => [
        if (kCarrierNamesUrl.isNotEmpty) kCarrierNamesUrl,
        'https://raw.githubusercontent.com/tsalisbury0/sector-scout/main/plmns.json',
        'https://raw.githubusercontent.com/tsalisbury0/private_plmn/main/plmns.json',
        'https://raw.githubusercontent.com/tsalisbury0/private_plmn/main/carriers.json',
      ];

  /// The URL the list came from, for the UI and the README.
  static String get sourceUrl => urls.first;

  static Map<String, String>? _byPlmn;
  static Map<String, double> _boosts = const {};
  static Set<String> _satellites = const {};
  static Set<String> _lteMs = const {};
  static Map<String, String> _fiveGs = const {};
  static Map<String, int> _nrBits = const {};
  static Future<bool>? _loading;
  static bool _remoteLoaded = false;

  /// True once a list is ready to resolve — from the network or the cache.
  static bool get isLoaded => _byPlmn != null;

  /// Number of PLMN keys available.
  static int get count => _byPlmn?.length ?? 0;

  /// Seeds the table from the copy stored on the device, so names are right on
  /// the first frame and stay right offline.
  static void seed(
    Map<String, String> table, {
    Map<String, double> boosts = const {},
    Set<String> satellites = const {},
    Set<String> lteMs = const {},
    Map<String, String> fiveGs = const {},
    Map<String, int> nrBits = const {},
  }) {
    if (table.isEmpty) return;
    _byPlmn = Map<String, String>.from(table);
    _boosts = Map<String, double>.from(boosts);
    _satellites = Set<String>.from(satellites);
    _lteMs = Set<String>.from(lteMs);
    _fiveGs = Map<String, String>.from(fiveGs);
    _nrBits = Map<String, int>.from(nrBits);
    SignalQuality.setBoosts(_boosts);
    SignalQuality.setSatellites(_satellites);
    SignalQuality.setLteMs(_lteMs);
    SignalQuality.setFiveGs(_fiveGs);
    SignalQuality.setNrBits(_nrBits);
  }

  /// Fetches the list. Concurrent callers share one request, and a failed
  /// attempt is not cached, so a later call retries.
  static Future<bool> load({HttpClient? client}) {
    if (_remoteLoaded) return Future.value(true);
    return _loading ??= _fetch(client).whenComplete(() => _loading = null);
  }

  static Future<bool> _fetch(HttpClient? client) async {
    for (final url in urls) {
      final parsed = await _fetchOne(url, client);
      if (parsed.isEmpty) continue;
      _byPlmn = parsed.names;
      _boosts = parsed.boosts;
      _satellites = parsed.satellites;
      _lteMs = parsed.lteMs;
      _fiveGs = parsed.fiveGs;
      _nrBits = parsed.nrBits;
      SignalQuality.setBoosts(_boosts);
      SignalQuality.setSatellites(_satellites);
      SignalQuality.setLteMs(_lteMs);
      SignalQuality.setFiveGs(_fiveGs);
      SignalQuality.setNrBits(_nrBits);
      _remoteLoaded = true;
      return true;
    }
    return false;
  }

  static Future<CarrierTable> _fetchOne(String url, HttpClient? client) async {
    final http = client ?? HttpClient();
    http.connectionTimeout = const Duration(seconds: 6);
    try {
      final request = await http
          .getUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 8));
      final response =
          await request.close().timeout(const Duration(seconds: 8));
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return const CarrierTable();
      }
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 15));
      return parseTable(body);
    } on Object {
      return const CarrierTable();
    } finally {
      if (client == null) http.close(force: true);
    }
  }

  /// The names only, for callers that do not care about the satellite offsets.
  static Map<String, String> parse(String body) => parseTable(body).names;

  /// Builds the lookup from raw JSON — exposed so the shape is testable
  /// without touching the network.
  ///
  /// Accepts either a list of `{mcc, mnc, brand|operator|name}` objects or a
  /// flat map of `"310-260": "T-Mobile"`. A value may also be an object with
  /// `brand` plus `satellite: true` / `boost: <dB>`.
  static CarrierTable parseTable(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      return const CarrierTable();
    }

    final names = <String, String>{};
    final boosts = <String, double>{};
    final satellites = <String>{};
    final lteMs = <String>{};
    final fiveGLabels = <String, String>{};
    final nrBitTable = <String, int>{};

    void add(
      String plmn,
      String brand,
      double boost, {
      bool satellite = false,
      bool lteM = false,
      String? fiveG,
      int? nrBits,
    }) {
      // The first entry for a PLMN wins: the list is ordered with the primary
      // network first, and later ones are usually MVNOs on the same codes.
      if (names.containsKey(plmn)) return;
      names[plmn] = brand;
      if (boost > 0) boosts[plmn] = boost;
      if (satellite) satellites.add(plmn);
      if (lteM) lteMs.add(plmn);
      if (fiveG != null && fiveG.isNotEmpty) fiveGLabels[plmn] = fiveG;
      if (nrBits != null) nrBitTable[plmn] = nrBits;
    }

    if (decoded is Map) {
      for (final entry in decoded.entries) {
        final key = _normalisePlmn(entry.key.toString());
        if (key == null) continue;
        final value = entry.value;
        if (value is Map) {
          final brand = (value['brand'] ?? value['operator'] ?? value['name'])
                  ?.toString()
                  .trim() ??
              '';
          if (brand.isEmpty) continue;
          add(
            key,
            brand,
            _boostOf(value),
            satellite: _satelliteFlagOf(value),
            lteM: _lteMFlagOf(value),
            fiveG: _fiveGOf(value),
            nrBits: _nrBitsOf(value),
          );
          continue;
        }
        final brand = value?.toString().trim() ?? '';
        if (brand.isEmpty) continue;
        add(key, brand, 0);
      }
      return CarrierTable(
        names: names,
        boosts: boosts,
        satellites: satellites,
        lteMs: lteMs,
        fiveGs: fiveGLabels,
        nrBits: nrBitTable,
      );
    }
    if (decoded is! List) return const CarrierTable();

    for (final entry in decoded) {
      if (entry is! Map) continue;
      final mcc = entry['mcc']?.toString().trim() ?? '';
      final mnc = entry['mnc']?.toString().trim() ?? '';
      if (mcc.isEmpty || mnc.isEmpty) continue;
      final brand = (entry['brand'] ?? entry['operator'] ?? entry['name'])
          ?.toString()
          .trim();
      if (brand == null || brand.isEmpty) continue;

      final boost = _boostOf(entry);
      final satellite = _satelliteFlagOf(entry);
      final lteM = _lteMFlagOf(entry);
      final fiveG = _fiveGOf(entry);
      final nrBits = _nrBitsOf(entry);
      add('$mcc-$mnc', brand, boost,
          satellite: satellite, lteM: lteM, fiveG: fiveG, nrBits: nrBits);
      // Accept either MNC width, since the modem and the list disagree on
      // zero-padding (310-26 vs 310-026).
      if (mnc.length == 2) {
        add('$mcc-0$mnc', brand, boost,
            satellite: satellite, lteM: lteM, fiveG: fiveG, nrBits: nrBits);
      } else if (mnc.length == 3 && mnc.startsWith('0')) {
        add('$mcc-${mnc.substring(1)}', brand, boost,
            satellite: satellite, lteM: lteM, fiveG: fiveG, nrBits: nrBits);
      }
    }
    return CarrierTable(
      names: names,
      boosts: boosts,
      satellites: satellites,
      lteMs: lteMs,
      fiveGs: fiveGLabels,
      nrBits: nrBitTable,
    );
  }

  /// The satellite bars offset an entry carries, in dB; 0 for a normal cell.
  static double _boostOf(Map<Object?, Object?> entry) {
    final raw = entry['boost'] ?? entry['boostDbm'] ?? entry['barsBoost'];
    final parsed = raw is num
        ? raw.toDouble()
        : double.tryParse(raw?.toString().trim() ?? '');
    if (parsed != null) return parsed;
    return _satelliteFlagOf(entry) ? kDefaultSatelliteBoost : 0;
  }

  /// True for an entry marked `satellite: true` — the link itself is a
  /// satellite path, which the card marks `SAT`.
  ///
  /// A `boost` alone is not enough: it only lifts the bars, and a terrestrial
  /// network may want that for its own reasons (313-700 does, on private LTE).
  static bool _satelliteFlagOf(Map<Object?, Object?> entry) {
    final raw = entry['satellite'];
    if (raw is bool) return raw;
    return raw?.toString().trim().toLowerCase() == 'true';
  }

  /// True for an entry marked `lteM: true` (or `lte_m` / `ltem`) — the network
  /// runs LTE-M / eMTC, which Android reports as plain LTE.
  static bool _lteMFlagOf(Map<Object?, Object?> entry) {
    final raw = entry['lteM'] ?? entry['lte_m'] ?? entry['ltem'];
    if (raw is bool) return raw;
    return raw?.toString().trim().toLowerCase() == 'true';
  }

  /// The `fiveG` label an entry carries, or null when it names none.
  ///
  /// This is the badge NR Advanced draws: `5G+`, `5GUC`, `5GUW`, or whatever
  /// a network calls its own. It only applies while the platform says NR
  /// Advanced, so a plain 5G leg still reads `5G`.
  static String? _fiveGOf(Map<Object?, Object?> entry) {
    final raw = entry['fiveG'] ?? entry['5g'] ?? entry['fiveGLabel'];
    final text = raw?.toString().trim() ?? '';
    return text.isEmpty ? null : text;
  }

  /// The gNB ID width an entry carries (`nrBits`), or null.
  ///
  /// A width outside 10–30 is a typo, not a split: the NCI is 36 bits, so a
  /// gNB narrower than 10 leaves no room for a sector and a 31-bit one would
  /// make the sector a single bit.
  static int? _nrBitsOf(Map<Object?, Object?> entry) {
    final raw = entry['nrBits'] ?? entry['gnbBits'] ?? entry['bitSplit'];
    final value = raw is num
        ? raw.toInt()
        : int.tryParse(raw?.toString().trim() ?? '');
    if (value == null || value < 10 || value > 30) return null;
    return value;
  }

  /// `310260` / `310-260` / ` 310 - 260 ` → `310-260`.
  static String? _normalisePlmn(String raw) {
    final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length < 5 || digits.length > 6) return null;
    return '${digits.substring(0, 3)}-${digits.substring(3)}';
  }

  /// The list currently in use, for handing to the native notification, which
  /// keeps running with the app closed and therefore needs its own copy.
  static Map<String, String> get table =>
      Map<String, String>.unmodifiable(_byPlmn ?? const {});

  /// The satellite offsets in use, for handing to the notification cache.
  static Map<String, double> get boosts =>
      Map<String, double>.unmodifiable(_boosts);

  /// The `fiveG` labels in use, for handing to the notification cache.
  static Map<String, String> get fiveGs =>
      Map<String, String>.unmodifiable(_fiveGs);

  /// The `nrBits` splits in use, so the desktop can decode the same NCI.
  static Map<String, int> get nrBits =>
      Map<String, int>.unmodifiable(_nrBits);

  /// The PLMNs flagged `satellite`, for handing to the notification.
  static Set<String> get satellites =>
      Set<String>.unmodifiable(_satellites);

  /// The PLMNs flagged `lteM`, for handing to the notification.
  static Set<String> get lteMs => Set<String>.unmodifiable(_lteMs);

  /// Brand for a PLMN like `310-410`, or null when unknown.
  static String? operatorFor(String? plmn) {
    final table = _byPlmn;
    if (table == null || plmn == null || plmn.isEmpty) return null;
    return table[plmn];
  }

  /// Best name for a slot: the registered network's brand, else [fallback].
  static String resolve(String? plmn, String fallback) =>
      operatorFor(plmn) ?? fallback;
}
