import 'package:cell_tower_monitor/desktop/desktop_config.dart';
import 'package:cell_tower_monitor/screens/desktop_home.dart';
import 'package:cell_tower_monitor/services/lan_discovery.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the desktop window starts empty and offers to watch a phone',
      (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: DesktopHome(config: DesktopConfig())));

    expect(find.text('Sector Scout'), findsOneWidget);
    expect(find.text('Desktop'), findsOneWidget);
    expect(find.text('No phones yet'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Watch phone'), findsOneWidget);
    expect(find.text('Scan'), findsOneWidget);
    expect(find.byIcon(Icons.cell_tower_rounded), findsOneWidget);

    // Stops the poll timer so the test leaves nothing pending.
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('watching a phone asks for its address', (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: DesktopHome(config: DesktopConfig())));

    await tester.tap(find.widgetWithText(FilledButton, 'Watch phone'));
    await tester.pumpAndSettle();

    expect(find.text('Watch a phone'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.textContaining('A bare IP uses port 41729'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
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

  testWidgets('the custom source is edited and then served',
      (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: DesktopHome(config: DesktopConfig(scenarioId: 'custom')),
    ));

    expect(find.textContaining('Custom · B30 anchor + n5'), findsOneWidget);

    await tester.tap(find.byTooltip('Edit the custom source'));
    await tester.pumpAndSettle();
    expect(find.text('Custom source'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('custom-lte-band')), '41');
    await tester.tap(find.text('Serve this'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Custom · B41 anchor + n5'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
