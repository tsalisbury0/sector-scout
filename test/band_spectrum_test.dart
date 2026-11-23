import 'package:cell_tower_monitor/models/band_filters.dart';
import 'package:cell_tower_monitor/models/cell_snapshot.dart';
import 'package:cell_tower_monitor/services/app_settings.dart';
import 'package:cell_tower_monitor/widgets/band_spectrum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// AT&T LTE on band 66, 10 MHz at 2115 MHz — the user's own example.
SimReading _band66({int earfcn = 66486, int bandwidthKhz = 10000}) =>
    SimReading.fromMap(<Object?, Object?>{
      'slotIndex': 0,
      'simState': 'READY',
      'dataOnMobile': true,
      'dataState': 2,
      'dataActivity': 3,

      'carriers': <Object?>[
        <Object?, Object?>{'net': 13, 'band': 66, 'bw': bandwidthKhz},
      ],
      'cells': <Object?>[
        <Object?, Object?>{
          'type': 'LTE',
          'registered': true,
          'pci': 148,
          'arfcn': earfcn,
          'bands': <Object?>[66],
          'mcc': '310',
          'mnc': '410',
          'dbm': -89,
        },
      ],
    });

SpectrumCarrier _carrier(int band, double centerMhz, {int khz = 10000}) =>
    SpectrumCarrier(
      carrier: RadioCarrier(tech: CellTech.lte, band: band, bandwidthKhz: khz),
      centerMhz: centerMhz,
      block: bandBlock(band, is5g: false)!,
    );

void main() {
  group('band blocks', () {
    test('band 66 spans 2110 to 2200 and band 4 stops at 2155', () {
      final b66 = bandBlock(66, is5g: false)!;
      final b4 = bandBlock(4, is5g: false)!;
      expect(b66.low, 2110);
      expect(b66.high, 2200);
      expect(b4.high, 2155);
      expect(b66.label, 'B66');
    });

    test('an NR band uses the 5 kHz raster', () {
      final n41 = bandBlock(41, is5g: true)!;
      expect(n41.low, 2496);
      expect(n41.high, closeTo(2690, 0.01));
    });
  });

  group('bands covering a carrier', () {
    test('band 66 lists its MFBI aliases 4 and 10, not 65 or 1', () {
      final bands = bandsCovering(
        2110,
        2120,
        is5g: false,
        reported: 66,
      ).map((band) => band.band).toList();
      expect(bands, <int>[4, 10, 66], reason: 'narrowest first');
      expect(bands, isNot(contains(65)));
      expect(bands, isNot(contains(1)));
      expect(bands, isNot(contains(9)));
    });

    test('band 106 and band 8 are MFBI aliases', () {
      final bands = bandsCovering(
        936.5,
        939.5,
        is5g: false,
        reported: 106,
      ).map((band) => band.band).toList();
      expect(bands, <int>[106, 8], reason: 'narrowest first');
    });

    test('band 2 lists band 25, not band 1 or 3', () {
      final bands = bandsCovering(
        1930,
        1940,
        is5g: false,
        reported: 2,
      ).map((band) => band.band).toList();
      expect(bands.first, 2);
      expect(bands, contains(25));
      expect(bands, isNot(contains(1)));
      expect(bands, isNot(contains(3)));
    });

    test('the aliases stay while the channel sits past their blocks', () {
      // 2175 MHz is inside band 66 only: band 4 stops at 2155 and band 10 at
      // 2170. They are still what that spectrum is numbered elsewhere.
      final bands = bandsCovering(
        2170,
        2180,
        is5g: false,
        reported: 66,
      ).map((band) => band.band).toList();
      expect(bands, <int>[4, 10, 66], reason: 'narrowest first');
    });

    test('the rest are ordered narrowest first, so they nest', () {
      final widths = bandsCovering(
        2110,
        2120,
        is5g: false,
        reported: 66,
      ).skip(1).map((band) => band.width).toList();
      final sorted = [...widths]..sort();
      expect(widths, sorted);
    });
  });

  group('placing carriers', () {
    test('a band 66 carrier at 2115 MHz sits on a 10 MHz channel', () {
      final sim = _band66();
      final placed = placeCarrier(sim, sim.carriers.single)!;
      expect(placed.centerMhz, closeTo(2115, 0.01));
      expect(placed.lowMhz, closeTo(2110, 0.01));
      expect(placed.highMhz, closeTo(2120, 0.01));
      expect(placed.block.band, 66);
    });

    test('the anchor names itself and knows its uplink', () {
      final sim = _band66();
      final placed = placeCarrier(sim, sim.carriers.single)!;
      expect(placed.role, 'PCC');
      // Band 66 pairs 2110–2200 down with 1710–1780 up on the same channel
      // offset, so 2115 down is 400 MHz below it, at 1715 up.
      expect(placed.uplinkMhz, closeTo(1715, 0.01));
      expect(placed.uplinkBlock!.low, 1710);
      expect(placed.uplinkBlock!.high, 1780);
      expect(placed.buttonLabel, 'PCC B66');
    });

    test('a supplemental downlink is an SDL layer with no uplink', () {
      final sim = SimReading.fromMap(<Object?, Object?>{
        'slotIndex': 0,
        'carriers': <Object?>[
          <Object?, Object?>{'net': 13, 'band': 29, 'bw': 10000},
        ],
        'cells': <Object?>[
          <Object?, Object?>{
            'type': 'LTE',
            'registered': true,
            'pci': 300,
            'arfcn': 9710,
            'bands': <Object?>[29],
            'dbm': -95,
          },
        ],
      });
      final placed = placeCarrier(sim, sim.carriers.single)!;
      expect(placed.role, 'SDL');
      expect(placed.uplinkMhz, isNull);
      expect(placed.uplinkBlock, isNull);
    });

    test('aggregated layers are numbered so the buttons differ', () {
      final sim = SimReading.fromMap(<Object?, Object?>{
        'slotIndex': 0,
        'carriers': <Object?>[
          <Object?, Object?>{'net': 13, 'band': 66, 'bw': 10000, 'pci': 148},
          <Object?, Object?>{'net': 13, 'band': 66, 'bw': 10000, 'pci': 149},
        ],
        'cells': <Object?>[
          <Object?, Object?>{
            'type': 'LTE',
            'registered': true,
            'pci': 148,
            'arfcn': 66486,
            'bands': <Object?>[66],
            'dbm': -89,
          },
          <Object?, Object?>{
            'type': 'LTE',
            'registered': false,
            'pci': 149,
            'arfcn': 66786,
            'bands': <Object?>[66],
            'dbm': -101,
          },
        ],
      });
      final placed = spectrumCarriers(sim);
      expect(placed.map((carrier) => carrier.role), ['PCC', 'CA']);
    });

    test('a placed layer uses the level the Carriers card prints', () {
      final sim = SimReading.fromMap(<Object?, Object?>{
        'slotIndex': 0,
        'carriers': <Object?>[
          <Object?, Object?>{'net': 13, 'band': 66, 'bw': 10000},
        ],
        'cells': <Object?>[
          <Object?, Object?>{
            'type': 'LTE',
            'registered': true,
            'pci': 148,
            'arfcn': 66486,
            'bands': <Object?>[66],
            // The card prints dbm; rsrp is a different reading and the graph
            // has to agree with the card, not with the other number.
            'dbm': -106,
            'rsrp': -103,
          },
        ],
      });
      final placed = placeCarrier(sim, sim.carriers.single)!;
      expect(placed.levelDbm, -106);
    });

    test('band 106 draws 3 MHz at 938.0 and 1.4 MHz elsewhere', () {
      SimReading b106(int arfcn) => SimReading.fromMap(<Object?, Object?>{
        'slotIndex': 0,
        'carriers': <Object?>[
          <Object?, Object?>{'net': 13, 'band': 106, 'bw': 5000},
        ],
        'cells': <Object?>[
          <Object?, Object?>{
            'type': 'LTE',
            'registered': true,
            'pci': 11,
            'arfcn': arfcn,
            'bands': <Object?>[106],
            'dbm': -88,
          },
        ],
      });
      // 70656 is band 106's first channel at 935 MHz, so 70686 is 938.0.
      final at938 = b106(70686);
      final placed = placeCarrier(at938, at938.carriers.single)!;
      expect(placed.centerMhz, closeTo(938.0, 0.005));
      expect(placed.bandwidthMhz, 3.0);

      final elsewhere = b106(70660);
      expect(
        placeCarrier(elsewhere, elsewhere.carriers.single)!.bandwidthMhz,
        1.4,
      );
    });

    test('band 30 draws its RB-limited downlink at the top of the block', () {
      SimReading b30() => SimReading.fromMap(<Object?, Object?>{
        'slotIndex': 0,
        'carriers': <Object?>[
          <Object?, Object?>{'net': 13, 'band': 30, 'bw': 10000},
        ],
        'cells': <Object?>[
          <Object?, Object?>{
            'type': 'LTE',
            'registered': true,
            'pci': 20,
            'arfcn': 9820,
            'bands': <Object?>[30],
            'dbm': -100,
          },
        ],
      });
      // 9820 is 2355: band 30's 10 MHz downlink, 2350–2360.
      final plain = b30();
      expect(placeCarrier(plain, plain.carriers.single)!.bandwidthMhz, 10);

      AppSettings.b30RbLimited = true;
      addTearDown(() => AppSettings.b30RbLimited = false);
      final narrowSim = b30();
      final narrow = placeCarrier(narrowSim, narrowSim.carriers.single)!;
      expect(narrow.bandwidthMhz, 7);
      expect(narrow.lowMhz, closeTo(2353, 0.01));
      expect(narrow.highMhz, closeTo(2360, 0.01));
      // The mask keeps the block's top edge rather than its centre.
      expect(narrow.maskCenterMhz, closeTo(2356.5, 0.01));
      // Only the downlink is limited: the uplink keeps its 10 MHz channel.
      expect(narrow.asUplink().bandwidthMhz, 10);
      expect(narrow.asUplink().shiftMhz, 0);
    });

    test('the inverse uplink mirrors the downlink and keeps a quarter', () {
      // Strong downlink: the mask may fall no further than a quarter.
      expect(
        uplinkPeakDbm(
          levelDbm: -20,
          txPowerDbm: null,
          inverse: true,
          maxDbm: 23,
        ),
        closeTo(5.75, 0.01),
      );
      // Halfway down the dial the mask is only halfway up, so a usable
      // signal does not pin the transmitter to its ceiling.
      expect(
        uplinkPeakDbm(
          levelDbm: -100,
          txPowerDbm: null,
          inverse: true,
          maxDbm: 23,
        ),
        closeTo(14.375, 0.01),
      );
      // Weak downlink: transmit at the band's ceiling.
      expect(
        uplinkPeakDbm(
          levelDbm: -140,
          txPowerDbm: null,
          inverse: true,
          maxDbm: 23,
        ),
        closeTo(23, 0.01),
      );
      // Off, the reported power wins.
      expect(
        uplinkPeakDbm(
          levelDbm: -60,
          txPowerDbm: 12,
          inverse: false,
          maxDbm: 23,
        ),
        12,
      );
    });

    test('power-class ceilings follow the band', () {
      expect(maxUplinkDbm(2), 23);
      expect(maxUplinkDbm(41), 26);
      expect(maxUplinkDbm(14), 31);
      expect(maxUplinkDbm(41, is5g: true), 29);
      expect(maxUplinkDbm(78, is5g: true), 26);
    });

    test('band 106 is placed from the serving cell without carriers', () {
      BandFilters.anterixB106 = true;
      addTearDown(() => BandFilters.anterixB106 = false);
      final sim = SimReading.fromMap(<Object?, Object?>{
        'slotIndex': 0,
        'cells': <Object?>[
          <Object?, Object?>{
            'type': 'LTE',
            'registered': true,
            'pci': 42,
            'arfcn': 3580,
            'bands': <Object?>[8],
            'mcc': '313',
            'mnc': '700',
            'dbm': -95,
          },
        ],
      });
      final carriers = spectrumCarriers(sim);
      expect(carriers, hasLength(1));
      expect(carriers.single.block.band, 106);
      expect(carriers.single.centerMhz, closeTo(938.0, 0.001));
      expect(carriers.single.bandwidthMhz, 3.0);
    });

    test('a TDD layer has one block for both directions', () {
      final sim = SimReading.fromMap(<Object?, Object?>{
        'slotIndex': 0,
        'carriers': <Object?>[
          <Object?, Object?>{'net': 13, 'band': 41, 'bw': 20000},
        ],
        'cells': <Object?>[
          <Object?, Object?>{
            'type': 'LTE',
            'registered': true,
            'pci': 220,
            'arfcn': 40000,
            'bands': <Object?>[41],
            'dbm': -92,
          },
        ],
      });
      final placed = placeCarrier(sim, sim.carriers.single)!;
      expect(placed.isTdd, isTrue);
      expect(placed.uplinkMhz, closeTo(placed.centerMhz, 0.005));
    });

    test('a carrier no cell can place is left off the graph', () {
      final sim = SimReading.fromMap(<Object?, Object?>{
        'slotIndex': 0,
        'carriers': <Object?>[
          <Object?, Object?>{'net': 13, 'band': 66, 'bw': 10000},
        ],
      });
      expect(placeCarrier(sim, sim.carriers.single), isNull);
    });
  });

  group('chart grouping', () {
    test('two carriers on the same band share one chart', () {
      final clusters = clusterCarriers([
        _carrier(66, 2115),
        _carrier(66, 2145),
      ]);
      expect(clusters, hasLength(1));
      expect(clusters.single, hasLength(2));
    });

    test('a band 2 anchor and an n41 leg get a chart each', () {
      final clusters = clusterCarriers([_carrier(2, 1960), _carrier(66, 2115)]);
      expect(clusters, hasLength(2));
    });
  });

  testWidgets('the graph draws a mask for a privileged band 66 carrier', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: BandSpectrum(sim: _band66())),
        ),
      ),
    );
    expect(find.byType(CustomPaint), findsWidgets);
    // The selector names the anchor, and the uplink is drawn below it.
    expect(find.text('PCC B66'), findsOneWidget);
    expect(find.text('DOWNLINK'), findsOneWidget);
    expect(find.textContaining('UPLINK'), findsOneWidget);
  });

  testWidgets('the uplink mask follows mobile data, not the traffic', (
    tester,
  ) async {
    SimReading sim({required bool mobile}) =>
        SimReading.fromMap(<Object?, Object?>{
          'slotIndex': 0,
          'simState': 'READY',
          'dataOnMobile': mobile,
          'dataState': 2,
          'dataActivity': 0,
          'carriers': <Object?>[
            <Object?, Object?>{'net': 13, 'band': 66, 'bw': 10000},
          ],
          'cells': <Object?>[
            <Object?, Object?>{
              'type': 'LTE',
              'registered': true,
              'pci': 148,
              'arfcn': 66486,
              'bands': <Object?>[66],
              'dbm': -89,
            },
          ],
        });
    Future<void> pump(SimReading reading) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: BandSpectrum(sim: reading)),
        ),
      ),
    );
    // Idle but connected: signalling still goes up, so the mask stays.
    await pump(sim(mobile: true));
    expect(find.text('DOWNLINK'), findsOneWidget);
    expect(find.textContaining('UPLINK'), findsOneWidget);
    // On Wi-Fi the mobile connection is not the one in use: no mask.
    await pump(sim(mobile: false));
    expect(find.textContaining('UPLINK'), findsNothing);
  });

  testWidgets('a TDD layer drawn once, labelled as both directions', (
    tester,
  ) async {
    final sim = SimReading.fromMap(<Object?, Object?>{
      'slotIndex': 0,
      'carriers': <Object?>[
        <Object?, Object?>{'net': 13, 'band': 41, 'bw': 20000},
      ],
      'cells': <Object?>[
        <Object?, Object?>{
          'type': 'LTE',
          'registered': true,
          'pci': 220,
          'arfcn': 40000,
          'bands': <Object?>[41],
          'dbm': -92,
        },
      ],
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: BandSpectrum(sim: sim)),
        ),
      ),
    );
    expect(find.text('TDD · DL AND UL'), findsOneWidget);
    expect(find.textContaining('UPLINK · TX'), findsNothing);
  });

  testWidgets('an aggregated layer points at the anchor for its uplink', (
    tester,
  ) async {
    final sim = SimReading.fromMap(<Object?, Object?>{
      'slotIndex': 0,
      'dataOnMobile': true,
      'dataState': 2,
      'dataActivity': 3,
      'carriers': <Object?>[
        <Object?, Object?>{'net': 13, 'band': 2, 'bw': 10000, 'pci': 100},
        <Object?, Object?>{'net': 19, 'band': 66, 'bw': 10000, 'pci': 148},
      ],
      'cells': <Object?>[
        <Object?, Object?>{
          'type': 'LTE',
          'registered': true,
          'pci': 100,
          'arfcn': 900,
          'bands': <Object?>[2],
          'dbm': -95,
        },
        <Object?, Object?>{
          'type': 'LTE',
          'registered': false,
          'pci': 148,
          'arfcn': 66486,
          'bands': <Object?>[66],
          'dbm': -101,
        },
      ],
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: BandSpectrum(sim: sim)),
        ),
      ),
    );
    await tester.tap(find.text('CA B66'));
    await tester.pump();
    expect(find.textContaining('anchor only'), findsOneWidget);
  });

  testWidgets('a supplemental downlink says it has no uplink', (tester) async {
    final sim = SimReading.fromMap(<Object?, Object?>{
      'slotIndex': 0,
      'dataOnMobile': true,
      'dataState': 2,
      'dataActivity': 3,
      'carriers': <Object?>[
        <Object?, Object?>{'net': 13, 'band': 29, 'bw': 10000},
      ],
      'cells': <Object?>[
        <Object?, Object?>{
          'type': 'LTE',
          'registered': true,
          'pci': 300,
          'arfcn': 9710,
          'bands': <Object?>[29],
          'dbm': -95,
        },
      ],
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: BandSpectrum(sim: sim)),
        ),
      ),
    );
    expect(find.text('SDL B29'), findsOneWidget);
    expect(find.textContaining('pairs no uplink'), findsOneWidget);
  });
}
