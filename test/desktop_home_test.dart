import 'package:cell_tower_monitor/desktop/desktop_config.dart';
import 'package:cell_tower_monitor/screens/desktop_home.dart';
import 'package:cell_tower_monitor/services/lan_discovery.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the console opens on the phones tab with an add row',
      (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: DesktopHome(config: DesktopConfig())));

    expect(find.text('Sector Scout'), findsOneWidget);
    expect(find.text('Desktop console'), findsOneWidget);
    expect(find.text('Phones'), findsOneWidget);
    // Two: the tab, and the bar's own label inside the tab.
    expect(find.text('Test source'), findsWidgets);
    expect(find.widgetWithText(FilledButton, 'Add phone'), findsOneWidget);
    expect(find.text('Scan'), findsOneWidget);
    expect(
      find.widgetWithText(OutlinedButton, 'Scan Bluetooth'),
      findsOneWidget,
    );
    expect(find.text('No phones yet'), findsOneWidget);
    expect(find.textContaining('0/0 phones answering'), findsOneWidget);
    expect(find.text('Display corrections'), findsOneWidget);

    // Stops the poll timer so the test leaves nothing pending.
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('an address typed into the bar is watched', (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: DesktopHome(config: DesktopConfig())));

    await tester.enterText(find.byKey(const Key('phone-address')), '10.1.1.47');
    await tester.tap(find.widgetWithText(FilledButton, 'Add phone'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(find.text('10.1.1.47'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Remove'), findsOneWidget);
    expect(find.textContaining('0/1 phones answering'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('an empty address is refused rather than added',
      (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: DesktopHome(config: DesktopConfig())));

    await tester.tap(find.widgetWithText(FilledButton, 'Add phone'));
    await tester.pump();

    expect(find.text('Enter a phone address first.'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Scan adds every phone that answered on the share port',
      (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: DesktopHome(
        config: DesktopConfig(),
        scan: () async => const [
          LanPeer(host: '10.1.1.47', port: 41729),
          LanPeer(host: '10.1.1.52', port: 41729),
        ],
      ),
    ));

    await tester.tap(find.text('Scan'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 20));

    expect(find.text('10.1.1.47:41729'), findsOneWidget);
    expect(find.text('10.1.1.52:41729'), findsOneWidget);
    expect(find.textContaining('added 2'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a silent sweep says so instead of looking stuck',
      (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: DesktopHome(config: DesktopConfig(), scan: () async => const []),
    ));

    await tester.tap(find.text('Scan'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(
      find.textContaining('No phone answered on port 41729'),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the custom source is edited on its own page and then served',
      (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: DesktopHome(config: DesktopConfig(scenarioId: 'custom')),
    ));

    await tester.tap(find.text('Test source').first);
    await tester.pump();

    expect(find.textContaining('Custom · B30 anchor + n5'), findsOneWidget);

    await tester.tap(find.byTooltip('Edit the custom source'));
    await tester.pumpAndSettle();

    // A page, not a dialog: it has its own route and the whole editor on it.
    expect(find.text('Custom source'), findsOneWidget);
    expect(find.text('Serving: B30 anchor + n5'), findsOneWidget);
    expect(find.byKey(const Key('custom-anchor-band')), findsOneWidget);

    await tester.enterText(find.byKey(const Key('custom-anchor-band')), 'B41');
    await tester.pump();

    expect(find.text('Serving: B41 anchor + n5'), findsOneWidget);

    await tester.tap(find.text('Serve this'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Custom · B41 anchor + n5'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('an edit reaches the source before the page is served',
      (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: DesktopHome(config: DesktopConfig(scenarioId: 'custom')),
    ));

    await tester.tap(find.text('Test source').first);
    await tester.pump();
    await tester.tap(find.byTooltip('Edit the custom source'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('custom-anchor-band')), 'B41');
    await tester.pump();

    // Back out without "Serve this": the edit was already applied live.
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.textContaining('Custom · B41 anchor + n5'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
