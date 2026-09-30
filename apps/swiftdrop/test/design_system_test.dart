import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:swiftdrop/design/design.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';

import 'helpers.dart';

void main() {
  test('screens and app layer use tokens, never raw visual values', () {
    final raw = <RegExp, String>{
      RegExp(r'Color\(0x'): 'colour literal',
      RegExp(r'Duration\((milliseconds|microseconds)'): 'animation duration',
      RegExp(r'fontSize:'): 'font size',
      RegExp(r'BorderRadius\.circular\('): 'radius',
      RegExp(r'ImageFilter'): 'filter',
      RegExp(r"package:flutter_tabler_icons"): 'icon package (use SdIcons)',
    };
    final offenders = <String>[];
    for (final dir in ['lib/screens', 'lib/app']) {
      for (final f in Directory(dir).listSync(recursive: true).whereType<File>()) {
        final src = f.readAsStringSync();
        for (final e in raw.entries) {
          if (e.key.hasMatch(src)) offenders.add('${f.path}: ${e.value}');
        }
      }
    }
    expect(offenders, isEmpty);
  });

  test('breakpoints', () {
    expect(SdLayout.forWidth(390), SdLayout.phone);
    expect(SdLayout.forWidth(700), SdLayout.tablet);
    expect(SdLayout.forWidth(1000), SdLayout.smallDesktop);
    expect(SdLayout.forWidth(1440), SdLayout.desktop);
    expect(SdLayout.forWidth(1800), SdLayout.largeDesktop);
  });

  test('text contrast on the environment', () {
    // Worst case: the brightest glass fill over the ground.
    final surface = Color.alphaBlend(SdMaterials.spec(GlassLevel.sheet, GlassMode.full).fill, SdColors.ground);
    double contrast(Color fg, Color bg) {
      final a = Color.alphaBlend(fg, bg).computeLuminance(), b = bg.computeLuminance();
      return (a > b ? a + 0.05 : b + 0.05) / (a > b ? b + 0.05 : a + 0.05);
    }

    expect(contrast(SdColors.text, surface), greaterThan(7));
    expect(contrast(SdColors.text2, surface), greaterThan(4.5));
    expect(contrast(SdColors.text3, SdColors.ground), greaterThan(3)); // large/secondary only
    expect(contrast(SdColors.redOnDark, surface), greaterThan(4.5));
    expect(contrast(SdColors.onRed, SdColors.red), greaterThan(4.5));
  });

  testWidgets('numbers use tabular figures', (tester) async {
    await tester.pumpWidget(harness(Builder(builder: (context) {
      final t = context.sdText;
      for (final s in [t.numericHero, t.numeric, t.numericSmall]) {
        expect(s.fontFeatures, contains(const FontFeature.tabularFigures()));
      }
      return const SizedBox();
    })));
  });

  testWidgets('buttons meet the touch target and press with feedback', (tester) async {
    var taps = 0;
    await tester.pumpWidget(harness(PrimaryAction(label: 'Send', compact: true, onPressed: () => taps++)));
    final size = tester.getSize(find.byType(PrimaryAction));
    expect(size.height, greaterThanOrEqualTo(SdSpace.touch));
    await tester.tap(find.text('Send'));
    expect(taps, 1);
  });

  testWidgets('device card reads as one sentence to screen readers', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(harness(const SizedBox(
      width: 200,
      child: DeviceGlassCard(
        device: Device(id: 'x', name: 'MacBook Pro', kind: DeviceKind.laptop, platform: DevicePlatform.macos, status: DeviceStatus.available),
      ),
    )));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('MacBook Pro, Mac, available'), findsOneWidget);
    handle.dispose();
  });
}
