import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:swiftdrop/design/design.dart';

import 'helpers.dart';

/// The clay console shell: Home is one instrument (this device, the rail, the destination,
/// the red Send key), sections switch from the navigation, nothing ever blurs.
void main() {
  group('phone', () {
    testWidgets('home answers what, who and what now; honest when nothing is around', (tester) async {
      await pumpApp(tester);
      expect(find.text('SwiftDrop'), findsOneWidget);
      expect(find.text('Nobody nearby yet'), findsOneWidget);
      expect(find.text('No one yet'), findsOneWidget);
      expect(find.text('SEND'), findsOneWidget);
      expect(find.text('Receive'), findsOneWidget);
      for (final label in ['Home', 'Transfers', 'Devices', 'Settings']) {
        expect(find.text(label), findsOneWidget);
      }
    });

    testWidgets('tabs switch sections; the Send key lives on Home', (tester) async {
      await pumpApp(tester);
      await tester.tap(find.text('Transfers'));
      await tester.pumpAndSettle();
      expect(find.text('No transfers yet'), findsOneWidget);
      expect(find.text('SEND'), findsNothing);
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      expect(find.text('Motion'), findsOneWidget);
      expect(find.text('Glass'), findsNothing);
    });

    testWidgets('no surface blurs on Home', (tester) async {
      await pumpApp(tester, demo: true);
      expect(find.byType(BackdropFilter), findsNothing);
      expect(GlassBudget.instance.active.value, 0);
    });

    testWidgets('devices render with state in words; the connected one says how', (tester) async {
      await pumpApp(tester, demo: true);
      expect(find.text("Ved's iPhone"), findsWidgets);
      await tester.tap(find.text('Devices'));
      await tester.pumpAndSettle();
      expect(find.text('Direct · Local network'), findsWidgets);
      expect(find.text('Ready'), findsWidgets);
    });
  });

  group('desktop', () {
    testWidgets('sidebar with labels and shortcuts, receive panel beside the console', (tester) async {
      await pumpApp(tester, size: desktop, demo: true);
      expect(find.text('Ctrl 1'), findsOneWidget);
      expect(find.text('SEND'), findsOneWidget);
      expect(find.text('Visible as This PC'), findsOneWidget);
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

  testWidgets('high contrast keeps every surface solid', (tester) async {
    await pumpApp(tester, route: '/settings');
    expect(find.byType(BackdropFilter), findsNothing);
    await tester.ensureVisible(find.text('On'));
    await tester.tap(find.text('On'));
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('every section and flow lays out without overflow at all five sizes', (tester) async {
    for (final size in allSizes) {
      for (final route in ['/', '/transfers', '/devices', '/settings', '/pair', '/pair?p2p=1', '/receive', '/send']) {
        await pumpApp(tester, size: size, demo: true, route: route);
        expect(tester.takeException(), isNull, reason: '$route at ${size.width}x${size.height}');
      }
    }
  });
}
