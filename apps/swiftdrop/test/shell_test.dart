import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:swiftdrop/design/design.dart';

import 'helpers.dart';

void main() {
  group('phone', () {
    testWidgets('home answers what, who and what now; honest when nothing is around', (tester) async {
      await pumpApp(tester);
      expect(find.text('SwiftDrop'), findsOneWidget);
      expect(find.text('Send anything. Directly.'), findsOneWidget);
      expect(find.text('No devices yet'), findsOneWidget);
      expect(find.text('Phone to phone'), findsOneWidget);
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

    testWidgets('one real blur on Home: the navigation panel', (tester) async {
      await pumpApp(tester, demo: true);
      expect(GlassBudget.instance.active.value, 1);
    });

    testWidgets('devices render with state in words; the connected one says how', (tester) async {
      await pumpApp(tester, demo: true);
      expect(find.text("Ved's iPhone"), findsWidgets);
      expect(find.text('Direct · Local network'), findsWidgets);
      expect(find.text('Ready'), findsWidgets);
    });
  });

  group('desktop', () {
    testWidgets('sidebar with labels and shortcuts, receive panel beside the content', (tester) async {
      await pumpApp(tester, size: desktop, demo: true);
      expect(find.text('Ctrl 1'), findsOneWidget);
      expect(find.text('Send files'), findsOneWidget);
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

  testWidgets('glass setting switches the material everywhere; high contrast turns blur off', (tester) async {
    await pumpApp(tester, route: '/settings');
    expect(find.byType(BackdropFilter), findsOneWidget);
    await tester.ensureVisible(find.text('Off'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Off'));
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsNothing);
    await tester.tap(find.text('Full').first);
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsOneWidget);
    await tester.ensureVisible(find.text('On'));
    await tester.tap(find.text('On'));
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsNothing, reason: 'high contrast forces solid surfaces');
    expect(GlassBudget.instance.active.value, 0);
  });

  testWidgets('every section and flow lays out without overflow at all five sizes', (tester) async {
    for (final size in allSizes) {
      for (final route in ['/', '/transfers', '/devices', '/settings', '/pair', '/pair?p2p=1', '/receive', '/send']) {
        await pumpApp(tester, size: size, demo: true, route: route);
        expect(tester.takeException(), isNull, reason: '$route at ${size.width}x${size.height}');
        expect(GlassBudget.instance.active.value, lessThanOrEqualTo(SdMaterials.blurBudget), reason: '$route at $size');
      }
    }
  });
}
