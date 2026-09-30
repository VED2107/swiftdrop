// Screenshot tool (not part of `flutter test`): renders real screens with real fonts at
// every supported window class, for design review.
//
//   flutter test test_screens --dart-define=SCREENS_OUT=C:\path\to\folder
//
// Windows only as written (loads Segoe UI and the Tabler icon font from local paths).
// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';

import '../test/helpers.dart';

const out = String.fromEnvironment('SCREENS_OUT');

Future<void> loadFont(String family, List<String> files) async {
  final l = FontLoader(family);
  for (final f in files) {
    if (File(f).existsSync()) l.addFont(Future.value(ByteData.sublistView(File(f).readAsBytesSync())));
  }
  await l.load();
}

Future<void> shot(WidgetTester tester, String name, Size size) async {
  final view = tester.binding.renderViews.first;
  await tester.runAsync(() async {
    final layer = view.debugLayer! as OffsetLayer;
    final img = await layer.toImage(Offset.zero & size);
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    File('$out/$name-${size.width.toInt()}x${size.height.toInt()}.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

void main() {
  setUpAll(() async {
    final pub = '${Platform.environment['LOCALAPPDATA']}/Pub/Cache/hosted/pub.dev';
    // Tests run as Android: its system family is Roboto. Segoe stands in so text is legible.
    await loadFont('Roboto', [r'C:\Windows\Fonts\segoeui.ttf', r'C:\Windows\Fonts\seguisb.ttf', r'C:\Windows\Fonts\segoeuib.ttf']);
    await loadFont('packages/flutter_tabler_icons/tabler-icons', ['$pub/flutter_tabler_icons-1.43.0/assets/fonts/tabler-icons.ttf']);
  });

  final sizes = const String.fromEnvironment('SIZES') == 'all' ? allSizes : [phone, desktop];

  for (final size in sizes) {
    testWidgets('screens at $size', (tester) async {
      if (out.isEmpty) return;
      for (final (name, route) in [
        ('home', '/'),
        ('devices', '/devices'),
        ('settings', '/settings'),
        ('p2p', '/pair?p2p=1'),
        ('receive', '/receive'),
        ('transfers', '/transfers'),
      ]) {
        await pumpApp(tester, size: size, demo: true, route: route);
        await shot(tester, name, size);
      }
      final fake = FakeTransfers()..push([snap(TransferPhase.running)]);
      await pumpApp(tester, size: size, transfers: fake, route: '/transfer/tr_test');
      await shot(tester, 'transfer-running', size);
      fake.push([snap(TransferPhase.reconnecting)]);
      await tester.pumpAndSettle();
      await shot(tester, 'transfer-interrupted', size);
      fake.push([snap(TransferPhase.complete, done: 1800000000)]);
      await tester.pumpAndSettle();
      await shot(tester, 'transfer-complete', size);

      final inc = FakeTransfers();
      await pumpApp(tester, size: size, transfers: inc, route: '/');
      inc.offer([
        const IncomingOffer(
          transferId: 'tr_in',
          from: Device(id: 'm', name: 'MacBook Pro', kind: DeviceKind.laptop, platform: DevicePlatform.macos, status: DeviceStatus.connected),
          fileCount: 24,
          totalBytes: 1800000000,
          sampleNames: ['DCIM/IMG_0001.HEIC', 'DCIM/IMG_0002.HEIC', 'Trip/itinerary.pdf'],
        ),
      ]);
      await tester.pumpAndSettle();
      await shot(tester, 'incoming', size);
    });
  }
}
