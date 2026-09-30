import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:swiftdrop/design/design.dart';

import 'helpers.dart';

void main() {
  group('phone', () {
    testWidgets('home shows the honest empty state and both actions', (tester) async {
      await pumpApp(tester);
      expect(find.text('SwiftDrop'), findsOneWidget);
      expect(find.text('No devices nearby yet'), findsOneWidget);
      expect(find.text('Send files'), findsOneWidget);
      expect(find.text('Receive'), findsOneWidget);
      for (final label in ['Home', 'Transfers', 'Devices', 'Settings']) {
        expect(find.text(label), findsOneWidget);
      }
    });

    testWidgets('tabs switch sections; the dock only sits on Home', (tester) async {
      await pumpApp(tester);
      await tester.tap(find.text('Transfers'));
      await tester.pumpAndSettle();
      expect(find.text('No transfers yet'), findsOneWidget);
      expect(find.text('Send files'), findsNothing);

      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      expect(find.text('Glass'), findsOneWidget);
    });

    testWidgets('one real blur on screen: the navigation panel', (tester) async {
      await pumpApp(tester, demo: true);
      expect(GlassBudget.instance.active.value, 1);
    });

    testWidgets('demo devices render; the connected one says how', (tester) async {
      await pumpApp(tester, demo: true);
      expect(find.text("Ved's iPhone"), findsWidgets);
      expect(find.text('Direct · Local network'), findsOneWidget);
    });
  });

  group('desktop', () {
    testWidgets('sidebar with labels and shortcuts', (tester) async {
      await pumpApp(tester, size: desktop);
      expect(find.text('Ctrl 1'), findsOneWidget);
      expect(find.text('Home'), findsOneWidget);
      // Actions sit beside the title, not in a dock.
      expect(find.text('Send files'), findsOneWidget);
    });

    testWidgets('Ctrl+2 goes to Transfers, Ctrl+, to Settings', (tester) async {
      await pumpApp(tester, size: desktop);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.text('No transfers yet'), findsOneWidget);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.comma);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.text('Motion'), findsOneWidget);
    });

    testWidgets('narrow desktop collapses the sidebar to icons', (tester) async {
      await pumpApp(tester, size: const Size(1000, 800));
      expect(find.text('Ctrl 1'), findsNothing);
      expect(find.byType(GlassNavigation), findsOneWidget);
    });
  });

  testWidgets('glass setting switches the material everywhere', (tester) async {
    await pumpApp(tester, route: '/settings');
    expect(find.byType(BackdropFilter), findsOneWidget);
    await tester.tap(find.text('Off'));
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsNothing);
    expect(GlassBudget.instance.active.value, 0);
  });
}
