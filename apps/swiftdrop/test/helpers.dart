import 'package:flutter/material.dart' show Theme;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:swiftdrop/app/app.dart';
import 'package:swiftdrop/app/providers.dart';
import 'package:swiftdrop/design/design.dart';
import 'package:swiftdrop_core/testing.dart';

const phone = Size(390, 844);
const desktop = Size(1440, 900);

/// Pumps the whole app at [size]. Reduce Motion is on so the ambient environment doesn't
/// tick forever and `pumpAndSettle` can settle.
Future<void> pumpApp(WidgetTester tester, {Size size = phone, bool demo = false, String route = '/'}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      if (demo) ...[
        deviceDirectoryProvider.overrideWithValue(DemoDeviceDirectory()),
        transferServiceProvider.overrideWithValue(DemoTransferService(autoStart: false)),
        transferHistoryProvider.overrideWithValue(DemoTransferHistory()),
      ],
    ],
    child: SwiftDropApp(initialLocation: route),
  ));
  await tester.pumpAndSettle();
}

/// Wraps a single component in the theme + appearance it expects.
Widget harness(Widget child, {GlassMode glass = GlassMode.full}) => MediaQuery(
      data: const MediaQueryData(size: Size(800, 600), disableAnimations: true),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Theme(
          data: sdTheme(),
          child: SdAppearanceScope(
            appearance: SdAppearance(glass: glass, reduceMotion: true),
            child: BackdropGroup(child: Center(child: child)),
          ),
        ),
      ),
    );
