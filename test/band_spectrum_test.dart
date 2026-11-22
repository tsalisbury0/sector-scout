import 'package:cell_tower_monitor/models/cell_snapshot.dart';
import 'package:cell_tower_monitor/widgets/band_spectrum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// AT&T LTE on band 66, 10 MHz at 2115 MHz — the user's own example.
SimReading _band66({int earfcn = 66486, int bandwidthKhz = 10000}) =>
    SimReading.fromMap(<Object?, Object?>{
      'slotIndex': 0,
      'simState': 'READY',
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
      carrier: RadioCarrier(
        tech: CellTech.lte,
        band: band,
        bandwidthKhz: khz,
      ),
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
    test('a 2110–2120 channel is inside bands 4, 10, 65 and 66', () {
      final bands = bandsCovering(
        2110,
        2120,
        is5g: false,
        reported: 66,
      ).map((band) => band.band).toList();
      expect(bands.first, 66, reason: 'the reported band leads');
      expect(bands, containsAll(<int>[4, 10, 66]));
      expect(bands, isNot(contains(2)));
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
      final clusters = clusterCarriers([
        _carrier(2, 1960),
        _carrier(66, 2115),
      ]);
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
  });
}
