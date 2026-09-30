import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:swiftdrop/design/design.dart';

import 'helpers.dart';

void main() {
  testWidgets('surface and card levels never blur the backdrop', (tester) async {
    await tester.pumpWidget(harness(const Column(mainAxisSize: MainAxisSize.min, children: [
      LiquidGlass(level: GlassLevel.regular, child: SizedBox(width: 100, height: 40)),
      LiquidGlass(level: GlassLevel.elevated, child: SizedBox(width: 100, height: 40)),
    ])));
    expect(find.byType(BackdropFilter), findsNothing);
    expect(GlassBudget.instance.active.value, 0);
  });

  testWidgets('floating and sheet levels blur, and count against the budget', (tester) async {
    await tester.pumpWidget(harness(const Column(mainAxisSize: MainAxisSize.min, children: [
      LiquidGlass(level: GlassLevel.floating, child: SizedBox(width: 100, height: 40)),
      LiquidGlass(level: GlassLevel.sheet, child: SizedBox(width: 100, height: 40)),
    ])));
    expect(find.byType(BackdropFilter), findsNWidgets(2));
    expect(GlassBudget.instance.active.value, 2);
    await tester.pumpWidget(const SizedBox());
    expect(GlassBudget.instance.active.value, 0);
  });

  testWidgets('a third visible blur is reported as an error', (tester) async {
    await tester.pumpWidget(harness(const Column(mainAxisSize: MainAxisSize.min, children: [
      LiquidGlass(level: GlassLevel.floating, child: SizedBox(width: 100, height: 20)),
      LiquidGlass(level: GlassLevel.floating, child: SizedBox(width: 100, height: 20)),
      LiquidGlass(level: GlassLevel.sheet, child: SizedBox(width: 100, height: 20)),
    ])));
    expect(tester.takeException(), isA<FlutterError>());
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('blur behind an offstage route or tab does not count', (tester) async {
    await tester.pumpWidget(harness(const TickerMode(
      enabled: false,
      child: LiquidGlass(level: GlassLevel.floating, child: SizedBox(width: 100, height: 40)),
    )));
    expect(GlassBudget.instance.active.value, 0);
  });

  testWidgets('subtle and off modes drop the blur', (tester) async {
    for (final mode in [GlassMode.subtle, GlassMode.off]) {
      await tester.pumpWidget(harness(
        const LiquidGlass(level: GlassLevel.sheet, child: SizedBox(width: 100, height: 40)),
        glass: mode,
      ));
      expect(find.byType(BackdropFilter), findsNothing, reason: mode.name);
    }
    expect(GlassBudget.instance.active.value, 0);
  });

  testWidgets('a sheet over the phone shell stays within budget', (tester) async {
    await pumpApp(tester, demo: true, route: '/gallery');
    await tester.scrollUntilVisible(find.text('Open sheet'), 200);
    await tester.ensureVisible(find.text('Open sheet'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open sheet'));
    await tester.pumpAndSettle();
    expect(find.text('Confirm this code matches'), findsOneWidget);
    expect(GlassBudget.instance.active.value, lessThanOrEqualTo(SdMaterials.blurBudget));
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(find.text('Confirm this code matches'), findsNothing);
  });

  test('glass levels step up in lift', () {
    final fills = GlassLevel.values.map((l) => SdMaterials.spec(l, GlassMode.full).fillTop.a).toList();
    for (var i = 1; i < fills.length; i++) {
      expect(fills[i], greaterThan(fills[i - 1]));
    }
  });
}
