import 'package:cell_tower_monitor/models/cell_snapshot.dart';
import 'package:cell_tower_monitor/services/carrier_names.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CarrierNames.parse', () {
    test('maps PLMN to the brand, falling back to the operator name', () {
      final table = CarrierNames.parse('''
        [
          {"mcc":"310","mnc":"410","brand":"AT&T","operator":"AT&T Mobility"},
          {"mcc":"310","mnc":"260","operator":"T-Mobile USA"},
          {"mcc":"313","mnc":"100","brand":"FirstNet","operator":"AT&T FirstNet"}
        ]
      ''');

      expect(table['310-410'], 'AT&T');
      // No brand: the operator field is used.
      expect(table['310-260'], 'T-Mobile USA');
      expect(table['313-100'], 'FirstNet');
    });

    test('keeps the first entry for a PLMN, so MVNOs do not win', () {
      final table = CarrierNames.parse('''
        [
          {"mcc":"310","mnc":"150","brand":"AT&T","operator":"AT&T Mobility"},
          {"mcc":"310","mnc":"150","brand":"Cricket","operator":"Cricket Wireless"}
        ]
      ''');

      expect(table['310-150'], 'AT&T');
    });

    test('accepts either MNC width', () {
      final table = CarrierNames.parse('''
        [
          {"mcc":"310","mnc":"26","brand":"T-Mobile"},
          {"mcc":"234","mnc":"030","brand":"EE"}
        ]
      ''');

      expect(table['310-26'], 'T-Mobile');
      expect(table['310-026'], 'T-Mobile');
      expect(table['234-030'], 'EE');
      expect(table['234-30'], 'EE');
    });

    test('skips entries with no usable name or PLMN', () {
      final table = CarrierNames.parse('''
        [
          {"mcc":"310","mnc":"999"},
          {"mcc":"","mnc":"410","brand":"Broken"},
          {"mcc":"311","mnc":"480","brand":"   "}
        ]
      ''');

      expect(table, isEmpty);
    });

    test('survives junk instead of throwing', () {
      expect(CarrierNames.parse('not json'), isEmpty);
      expect(CarrierNames.parse('{"mcc":"310"}'), isEmpty);
      expect(CarrierNames.parse('[]'), isEmpty);
    });
  });

  group('CarrierNames.parse map shape', () {
    test('accepts a flat PLMN to brand map', () {
      final table = CarrierNames.parse('''
        {
          "310-260": "T-Mobile",
          "310410": "AT&T",
          "313-700": {"brand": "Ameren"},
          "311-480": "   "
        }
      ''');

      expect(table['310-260'], 'T-Mobile');
      // Written without the dash, normalised to the app's form.
      expect(table['310-410'], 'AT&T');
      expect(table['313-700'], 'Ameren');
      expect(table.containsKey('311-480'), isFalse);
    });
  });

  group('CarrierNames satellite offsets', () {
    test('parses the list file exactly as written in the repo', () {
      // The file the app fetches, verbatim. Every entry must resolve — the
      // 3-digit MNCs (830, 570, 780, 190) are the ones most easily dropped.
      final table = CarrierNames.parseTable('''
[
  { "mcc": "310", "mnc": "410", "brand": "AT&T" },
  { "mcc": "310", "mnc": "260", "brand": "T-Mobile" },
  { "mcc": "311", "mnc": "480", "brand": "Verizon" },
  { "mcc": "311", "mnc": "970", "brand": "Big River" },
  { "mcc": "313", "mnc": "100", "brand": "FirstNet" },
  { "mcc": "313", "mnc": "700", "brand": "Ameren" },
  { "mcc": "310", "mnc": "830", "brand": "T-Satellite" },
  { "mcc": "311", "mnc": "570", "brand": "Mediacom" },
  { "mcc": "313", "mnc": "780", "brand": "Windstream" },
  { "mcc": "312", "mnc": "190", "brand": "T-911" }
]
      ''');

      expect(table.names, {
        '310-410': 'AT&T',
        '310-260': 'T-Mobile',
        '311-480': 'Verizon',
        '311-970': 'Big River',
        '313-100': 'FirstNet',
        '313-700': 'Ameren',
        '310-830': 'T-Satellite',
        '311-570': 'Mediacom',
        '313-780': 'Windstream',
        '312-190': 'T-911',
      });
      // Nothing in this file is flagged, so nothing is boosted.
      expect(table.boosts, isEmpty);
    });

    test('accepts a satellite boost on its own, without labelling the link SAT', () {
      final table = CarrierNames.parseTable('''
[
  { "mcc": "313", "mnc": "700", "brand": "Ameren", "boost": 15 },
  { "mcc": "312", "mnc": "190", "brand": "T-911", "boost": 20 },
  { "mcc": "310", "mnc": "410", "brand": "AT&T" }
]
      ''');

      expect(table.names['313-700'], 'Ameren');
      expect(table.names['312-190'], 'T-911');
      // A boost is a bar-count tweak, not a satellite link; only the flags
      // entry is a satellite path.
      expect(table.boosts['313-700'], 15);
      expect(table.boosts['312-190'], 20);
      // Neither entry carries the flag, so neither claims a satellite link.
      expect(table.satellites, isEmpty);
      expect(table.satellites.contains('313-700'), isFalse);
    });

    test('accepts a plain brand plus a satellite flag on its own', () {
      final table = CarrierNames.parseTable('''
[
  { "mcc": "310", "mnc": "260", "brand": "T-Mobile", "satellite": true },
  { "mcc": "310", "mnc": "410", "brand": "AT&T" }
]
      ''');

      expect(table.names['310-260'], 'T-Mobile');
      expect(table.boosts['310-260'], kDefaultSatelliteBoost);
      expect(table.satellites, {'310-260'});
    });

    test('reads the lteM tag from either shape', () {
      final list = CarrierNames.parseTable('''
[
  { "mcc": "313", "mnc": "700", "brand": "Ameren", "lteM": true },
  { "mcc": "310", "mnc": "410", "brand": "AT&T" }
]
      ''');
      final map = CarrierNames.parseTable('''
        {
          "313-700": {"brand": "Ameren", "lte_m": true},
          "310-260": "T-Mobile"
        }
      ''');

      expect(list.lteMs, {'313-700'});
      expect(map.lteMs, {'313-700'});
      // A tag is not a bars offset and not a satellite claim.
      expect(list.boosts, isEmpty);
      expect(list.satellites, isEmpty);
    });

    test('lteM can travel with a boost on the same entry', () {
      final table = CarrierNames.parseTable('''
[
  { "mcc": "313", "mnc": "700", "brand": "Ameren", "boost": 15, "lteM": true }
]
      ''');

      expect(table.boosts['313-700'], 15);
      expect(table.lteMs, {'313-700'});
      expect(table.satellites, isEmpty);
    });

    test('a satellite flag plus an explicit boost keeps the explicit value', () {
      final table = CarrierNames.parseTable('''
[
  { "mcc": "311", "mnc": "570", "brand": "Mediacom", "satellite": true, "boost": 18 }
]
      ''');

      expect(table.names['311-570'], 'Mediacom');
      expect(table.boosts['311-570'], 18);
      expect(table.satellites, {'311-570'});
    });

    test('the same list shape carries the satellite setting', () {
      final table = CarrierNames.parseTable('''
[
  { "mcc": "310", "mnc": "830", "brand": "T-Satellite", "satellite": true },
  { "mcc": "312", "mnc": "190", "brand": "T-911", "boost": 20 },
  { "mcc": "310", "mnc": "410", "brand": "AT&T" }
]
      ''');

      expect(table.names['310-830'], 'T-Satellite');
      expect(table.boosts['310-830'], kDefaultSatelliteBoost);
      expect(table.boosts['312-190'], 20);
      expect(table.boosts.containsKey('310-410'), isFalse);
    });

    test('reads satellite / boost beside a PLMN', () {
      final table = CarrierNames.parseTable('''
        {
          "310-260": "T-Mobile",
          "310-830": {"brand": "T-Satellite", "satellite": true},
          "312-190": {"brand": "T-911", "boost": 24},
          "311-970": {"brand": "Big River"}
        }
      ''');

      expect(table.names['310-830'], 'T-Satellite');
      // `satellite: true` means the default offset; `boost` sets it exactly.
      expect(table.boosts['310-830'], kDefaultSatelliteBoost);
      expect(table.boosts['312-190'], 24);
      // A plain terrestrial entry carries no offset.
      expect(table.boosts.containsKey('310-260'), isFalse);
      expect(table.boosts.containsKey('311-970'), isFalse);
    });

    test('a boost alone does not flag the PLMN as satellite', () {
      final table = CarrierNames.parseTable('''
        [
          { "mcc": "313", "mnc": "700", "brand": "Ameren", "boost": 15 },
          { "mcc": "310", "mnc": "830", "brand": "T-Satellite", "satellite": true },
          { "mcc": "310", "mnc": "410", "brand": "AT&T" }
        ]
      ''');

      expect(table.boosts['313-700'], 15);
      expect(table.satellites, {'310-830'});
      expect(table.satellites.contains('313-700'), isFalse);
      expect(table.satellites.contains('310-410'), isFalse);
    });

    test('carries the offset through the list shape too', () {
      final table = CarrierNames.parseTable('''
        [
          {"mcc":"310","mnc":"830","brand":"T-Satellite","satellite":true}
        ]
      ''');

      expect(table.names['310-830'], 'T-Satellite');
      expect(table.boosts['310-830'], kDefaultSatelliteBoost);
    });

  });

  group('CarrierNames source', () {
    test('reads the list from the repo, not from the app', () {
      // The list is the user's GitHub file; the app ships no table of its own.
      expect(
        CarrierNames.urls,
        contains(
          'https://raw.githubusercontent.com/tsalisbury0/private_plmn/main/plmns.json',
        ),
      );
      // Nothing is resolved until a list is seeded or fetched.
      expect(CarrierNames.isLoaded, isFalse);
      expect(CarrierNames.operatorFor('310-410'), isNull);
      expect(CarrierNames.resolve('310-410', 'SIM 1'), 'SIM 1');
    });

    test('a seeded list resolves and is handed on as a table', () {
      CarrierNames.seed({
        '310-410': 'AT&T',
        '313-700': 'Ameren',
      });

      expect(CarrierNames.isLoaded, isTrue);
      expect(CarrierNames.resolve('310-410', 'SIM 1'), 'AT&T');
      expect(CarrierNames.resolve('313-700', 'SIM 1'), 'Ameren');
      expect(CarrierNames.table.length, 2);

      // Anything not in the list keeps the SIM's own name.
      expect(CarrierNames.operatorFor('999-999'), isNull);
      expect(CarrierNames.resolve('999-999', 'SIM 2'), 'SIM 2');
      expect(CarrierNames.resolve(null, 'SIM 2'), 'SIM 2');
    });
  });

  // Last, because seeding is process-wide and the groups above assume nothing
  // has been loaded yet.
  group('CarrierNames satellite offsets', () {
    test('seeding applies the offsets to the bar scale', () {
      CarrierNames.seed(
        {'310-830': 'T-Satellite', '310-410': 'AT&T'},
        boosts: {'310-830': 20},
      );
      addTearDown(() => SignalQuality.setBoosts(const {}));

      expect(CarrierNames.boosts, {'310-830': 20});
      expect(SignalQuality.boostFor('310-830'), 20);
      expect(SignalQuality.boostFor('310-410'), 0);
    });
  });

  group('fiveG and nrBits tags', () {
    test('reads the NR Advanced label and the gNB split from either shape', () {
      final list = CarrierNames.parseTable('''
[
  { "mcc": "310", "mnc": "410", "brand": "AT&T", "fiveG": "5G+", "nrBits": "26/10" },
  { "mcc": "310", "mnc": "260", "brand": "T-Mobile", "fiveG": "5GUC", "nrBits": 24 },
  { "mcc": "530", "mnc": "05", "brand": "Spark NZ", "fiveG": "5G NZ" }
]
      ''');
      final map = CarrierNames.parseTable('''
        {
          "310-410": {"brand": "AT&T", "fiveG": "5G+", "nrBits": "26 / 10"}
        }
      ''');

      expect(list.fiveGs['310-410'], '5G+');
      // The split is written gNB/sector; the model keeps the gNB width.
      expect(list.nrBits['310-410'], 26);
      expect(list.nrBits['310-260'], 24, reason: 'a bare width still reads');
      expect(map.nrBits['310-410'], 26, reason: 'spaces around the slash are fine');
      expect(list.fiveGs['310-260'], '5GUC');
      // The zero-padded MNC reads too, since the modem and the list disagree.
      expect(list.fiveGs['530-05'], '5G NZ');
      expect(list.fiveGs['530-005'], '5G NZ');
      expect(map.fiveGs['310-410'], '5G+');
      // A badge tag is not a bars offset, a satellite claim, or an LTE-M flag.
      expect(list.boosts, isEmpty);
      expect(list.satellites, isEmpty);
      expect(list.lteMs, isEmpty);
    });

    test('an implausible width or a split that misses 36 is ignored', () {
      final table = CarrierNames.parseTable('''
        {
          "310-410": {"brand": "AT&T", "nrBits": 4},
          "310-260": {"brand": "T-Mobile", "nrBits": 40},
          "311-480": {"brand": "Verizon", "nrBits": "24/11"},
          "311-970": {"brand": "Big River", "nrBits": "4/32"}
        }
      ''');

      expect(table.nrBits, isEmpty);
    });

    test('the tags reach the model through seed', () {
      CarrierNames.seed(
        {'310-410': 'AT&T'},
        fiveGs: {'310-410': '5G+'},
        nrBits: {'310-410': 24},
      );
      addTearDown(() {
        SignalQuality.setFiveGs(const {});
        SignalQuality.setNrBits(const {});
      });

      // Both spellings resolve: the badge works on compact codes, the cells
      // carry the PLMN with the dash.
      expect(SignalQuality.fiveGFor('310410'), '5G+');
      expect(SignalQuality.fiveGFor('310-410'), '5G+');
      expect(SignalQuality.nrBitsFor('310410'), 24);
      expect(SignalQuality.nrBitsFor('310-260'), isNull);
    });
  });
}
