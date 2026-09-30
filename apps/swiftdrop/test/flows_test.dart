import 'package:flutter_test/flutter_test.dart';
import 'package:swiftdrop/design/design.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';

import 'helpers.dart';

/// The transfer flows, driven by a hand-controlled service: what the person sees in each
/// state, and that their taps reach the engine.
void main() {
  group('transfer screen', () {
    testWidgets('running: who, which way, how far, how fast; pause reaches the engine', (tester) async {
      final fake = FakeTransfers()..push([snap(TransferPhase.running)]);
      await pumpApp(tester, transfers: fake, route: '/transfer/tr_test');
      expect(find.text('Sending'), findsOneWidget);
      expect(find.text("to Ved's iPhone"), findsOneWidget);
      expect(find.text('1.24 GB'), findsOneWidget);
      expect(find.text('of 1.80 GB'), findsOneWidget);
      expect(find.text('94.0 MB/s'), findsOneWidget);
      expect(find.text('42s'), findsOneWidget);
      expect(find.text('Direct · Local network'), findsOneWidget);
      expect(find.byType(TransferVisual), findsOneWidget);
      await tester.tap(find.text('Pause'));
      expect(fake.calls, contains('pause tr_test'));
    });

    testWidgets('interrupted: reassuring, progress kept; restored: says so', (tester) async {
      final fake = FakeTransfers()..push([snap(TransferPhase.reconnecting)]);
      await pumpApp(tester, transfers: fake, route: '/transfer/tr_test');
      expect(find.text('Connection interrupted'), findsOneWidget);
      expect(find.text('Your transfer is safe'), findsOneWidget);
      expect(find.textContaining('1.2 GB already transferred and kept'), findsOneWidget);
      fake.push([snap(TransferPhase.running, done: 1300000000)]);
      await tester.pumpAndSettle();
      expect(find.text('Connection restored'), findsOneWidget);
      expect(find.textContaining('Resumed from 1.3 GB'), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(find.text('Connection restored'), findsNothing);
    });

    testWidgets('paused: resume from where it stopped', (tester) async {
      final fake = FakeTransfers()..push([snap(TransferPhase.paused)]);
      await pumpApp(tester, transfers: fake, route: '/transfer/tr_test');
      await tester.tap(find.text('Resume from 1.2 GB'));
      expect(fake.calls, contains('resume tr_test'));
    });

    testWidgets('complete: the mark, the totals, verified, done dismisses', (tester) async {
      final fake = FakeTransfers()..push([snap(TransferPhase.complete, done: 1800000000)]);
      await pumpApp(tester, transfers: fake, route: '/transfer/tr_test');
      expect(find.text('Transfer complete'), findsOneWidget);
      expect(find.byType(CompletionMark), findsOneWidget);
      expect(find.text('1.80 GB'), findsOneWidget);
      expect(find.textContaining('Verified'), findsOneWidget);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(fake.calls, contains('dismiss tr_test'));
    });

    testWidgets('declined: plain words, nothing sent', (tester) async {
      final fake = FakeTransfers()..push([snap(TransferPhase.declined, done: 0)]);
      await pumpApp(tester, transfers: fake, route: '/transfer/tr_test');
      expect(find.text("Ved's iPhone declined"), findsOneWidget);
      expect(find.text('Nothing was sent.'), findsOneWidget);
    });
  });

  testWidgets('incoming transfer: a sheet wherever you are; Accept reaches the engine and opens the transfer', (tester) async {
    final fake = FakeTransfers();
    await pumpApp(tester, transfers: fake, route: '/devices');
    fake.offer([
      const IncomingOffer(
        transferId: 'tr_in',
        from: Device(id: 'demo-mac', name: 'MacBook Pro', kind: DeviceKind.laptop, platform: DevicePlatform.macos, status: DeviceStatus.connected),
        fileCount: 24,
        totalBytes: 1800000000,
        sampleNames: ['DCIM/IMG_0001.HEIC', 'DCIM/IMG_0002.HEIC'],
      ),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('Incoming transfer'), findsOneWidget);
    expect(find.text('MacBook Pro'), findsWidgets);
    expect(find.text('24 files'), findsOneWidget);
    expect(find.text('and 22 more'), findsOneWidget);
    expect(GlassBudget.instance.active.value, lessThanOrEqualTo(SdMaterials.blurBudget));
    await tester.tap(find.text('Accept'));
    await tester.pumpAndSettle();
    expect(fake.calls, contains('accept tr_in'));
    expect(find.text('Incoming transfer'), findsNothing);
  });

  testWidgets('pairing: code and address shown; entering a bad address explains itself', (tester) async {
    await pumpApp(tester, demo: true, route: '/pair?p2p=1');
    expect(find.text('Phone to Phone'), findsOneWidget);
    expect(find.text('Direct transfer. No computer needed.'), findsOneWidget);
    expect(find.byType(QrCodeGlassContainer), findsOneWidget);
    expect(find.text('192.168.1.20:47800'), findsOneWidget);
    await tester.tap(find.text('Enter code'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Enter the address shown on the other device'), findsOneWidget);
  });

  testWidgets('send review without files offers to choose; with no device, to connect one', (tester) async {
    await pumpApp(tester, route: '/send');
    expect(find.text('Send to'), findsOneWidget);
    expect(find.text('Connect a device first'), findsOneWidget);
    expect(find.text('Nothing selected'), findsOneWidget);
    expect(find.text('Choose files'), findsOneWidget);
    expect(GlassBudget.instance.active.value, lessThanOrEqualTo(SdMaterials.blurBudget));
  });
}
