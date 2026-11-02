import 'package:cell_tower_monitor/screens/desktop_home.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the desktop window starts empty and offers to watch a phone',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: DesktopHome()));

    expect(find.text('Sector Scout'), findsOneWidget);
    expect(find.text('Desktop'), findsOneWidget);
    expect(find.text('No phones yet'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Watch phone'), findsOneWidget);
    expect(find.byIcon(Icons.cell_tower_rounded), findsOneWidget);

    // Stops the poll timer so the test leaves nothing pending.
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('watching a phone asks for its address', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: DesktopHome()));

    await tester.tap(find.widgetWithText(FilledButton, 'Watch phone'));
    await tester.pumpAndSettle();

    expect(find.text('Watch a phone'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.textContaining('A bare IP uses port 41729'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
