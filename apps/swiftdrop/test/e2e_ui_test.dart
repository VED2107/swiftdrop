@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:swiftdrop/app/app.dart';
import 'package:swiftdrop/app/picking.dart';
import 'package:swiftdrop/app/providers.dart';
import 'package:swiftdrop_core/runtime.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';

import 'helpers.dart';

/// The first real end-to-end path through the app: two real engines (each in its own
/// isolate, real TCP lanes, real files), and the real screens driving one of them.
void main() {
  testWidgets('connect by address, send from the UI, the other side accepts, the UI shows complete', (tester) async {
    tester.view.physicalSize = phone;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);

    late Directory tmp;
    late EngineHost a;
    late EngineHost b;
    late String src;
    late LocalEndpoint bEnd;
    await tester.runAsync(() async {
      tmp = await Directory.systemTemp.createTemp('sd_e2e_ui_');
      EngineConfig cfg(String name) => EngineConfig(
            dataDir: p.join(tmp.path, name, 'data'),
            downloadDir: p.join(tmp.path, name, 'Downloads'),
            name: name,
            port: 0,
            lanes: 2,
            bindAddress: '127.0.0.1',
          );
      a = await EngineHost.spawn(cfg('Laptop A'));
      b = await EngineHost.spawn(cfg('Desk B'));
      src = p.join(tmp.path, 'photo.raw');
      File(src).writeAsBytesSync(List.generate(3 * 1024 * 1024 + 17, (i) => (i * 31) & 0xff));
      bEnd = (await b.endpoint().firstWhere((e) => e != null))!;
      // The other device accepts whatever arrives.
      b.transferService.incoming().listen((offers) {
        for (final o in offers) {
          b.transferService.accept(o.transferId);
        }
      });
    });

    await tester.pumpWidget(ProviderScope(
      overrides: [
        engineProvider.overrideWithValue(a),
        deviceDirectoryProvider.overrideWithValue(a),
        transferServiceProvider.overrideWithValue(a.transferService),
        transferHistoryProvider.overrideWithValue(a.history),
      ],
      child: const SwiftDropApp(initialLocation: '/pair'),
    ));

    Future<void> settleUntil(Finder f) async {
      for (var i = 0; i < 300 && f.evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(f, findsWidgets);
    }

    // Connect by typing the other device's address.
    await settleUntil(find.text('Enter code'));
    await tester.tap(find.text('Enter code'));
    await tester.pump();
    await tester.enterText(find.byType(EditableText), '127.0.0.1:${bEnd.port}');
    await tester.tap(find.text('Connect'));
    await settleUntil(find.text('Send files to Desk B'));

    // Choose a file (what the picker returns), then review and send from the UI.
    final container = ProviderScope.containerOf(tester.element(find.byType(SwiftDropApp)));
    late List<PickedItem> picked;
    await tester.runAsync(() async => picked = await describePaths([src]));
    container.read(selectionProvider.notifier).add(picked);
    await tester.tap(find.text('Send files to Desk B'));
    await settleUntil(find.text('Send 3.1 MB'));
    await tester.tap(find.text('Send 3.1 MB'));

    // The transfer screen follows the real engine to completion.
    await settleUntil(find.text('Transfer complete'));
    expect(find.textContaining('Verified'), findsOneWidget);

    await tester.runAsync(() async {
      final got = File(p.join(tmp.path, 'Desk B', 'Downloads', 'photo.raw'));
      expect(await got.length(), await File(src).length());
      expect(await got.readAsBytes(), await File(src).readAsBytes());
      await a.shutdown();
      await b.shutdown();
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });
    await tester.pumpWidget(const SizedBox());
  });
}
