import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:swiftdrop/design/design.dart';

import 'helpers.dart';

/// "Clay console": every surface is matte molded clay. Nothing blurs the backdrop, at any
/// level or appearance setting, so the blur budget always reads zero.
void main() {
  testWidgets('no surface level ever blurs the backdrop', (tester) async {
    await tester.pumpWidget(harness(const Column(mainAxisSize: MainAxisSize.min, children: [
      LiquidGlass(level: GlassLevel.regular, child: SizedBox(width: 100, height: 30)),
      LiquidGlass(level: GlassLevel.elevated, child: SizedBox(width: 100, height: 30)),
      LiquidGlass(level: GlassLevel.floating, child: SizedBox(width: 100, height: 30)),
      LiquidGlass(level: GlassLevel.sheet, child: SizedBox(width: 100, height: 30)),
    ])));
    expect(find.byType(BackdropFilter), findsNothing);
    expect(GlassBudget.instance.active.value, 0);
  });

  testWidgets('appearance settings never bring a blur back', (tester) async {
    for (final mode in GlassMode.values) {
      await tester.pumpWidget(harness(
        const LiquidGlass(level: GlassLevel.sheet, child: SizedBox(width: 100, height: 40)),
        glass: mode,
      ));
      expect(find.byType(BackdropFilter), findsNothing, reason: mode.name);
    }
    expect(GlassBudget.instance.active.value, 0);
  });

  testWidgets('a sheet over the phone shell opens and closes', (tester) async {
    await pumpApp(tester, demo: true, route: '/gallery');
    await tester.scrollUntilVisible(find.text('Open sheet'), 200);
    await tester.ensureVisible(find.text('Open sheet'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open sheet'));
    await tester.pumpAndSettle();
    expect(find.text('Confirm this code matches'), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(find.text('Confirm this code matches'), findsNothing);
  });
}
