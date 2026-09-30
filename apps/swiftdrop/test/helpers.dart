import 'dart:async';

import 'package:flutter/material.dart' show Theme;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:swiftdrop/app/app.dart';
import 'package:swiftdrop/app/providers.dart';
import 'package:swiftdrop/design/design.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';
import 'package:swiftdrop_core/testing.dart';

const phone = Size(390, 844);
const bigPhone = Size(430, 932);
const tablet = Size(768, 1024);
const smallDesktop = Size(1200, 800);
const desktop = Size(1440, 900);
const allSizes = [phone, bigPhone, tablet, smallDesktop, desktop];

/// A transfer service a test drives by hand: push snapshots and offers, record calls.
class FakeTransfers implements TransferService {
  final _out = StreamController<List<TransferSnapshot>>.broadcast();
  final _offers = StreamController<List<IncomingOffer>>.broadcast();
  List<TransferSnapshot> current = const [];
  List<IncomingOffer> offers = const [];
  final calls = <String>[];

  void push(List<TransferSnapshot> list) {
    current = list;
    _out.add(list);
  }

  void offer(List<IncomingOffer> list) {
    offers = list;
    _offers.add(list);
  }

  @override
  Stream<List<TransferSnapshot>> watch() async* {
    yield current;
    yield* _out.stream;
  }

  @override
  Stream<List<IncomingOffer>> incoming() async* {
    yield offers;
    yield* _offers.stream;
  }

  @override
  Future<String> send(String deviceId, List<SendItem> items) async {
    calls.add('send $deviceId ${items.length}');
    return 'tr_test';
  }

  @override
  Future<void> accept(String id) async {
    calls.add('accept $id');
    offer(const []);
  }

  @override
  Future<void> decline(String id) async {
    calls.add('decline $id');
    offer(const []);
  }

  @override
  Future<void> pause(String id) async => calls.add('pause $id');
  @override
  Future<void> resume(String id) async => calls.add('resume $id');
  @override
  Future<void> cancel(String id) async => calls.add('cancel $id');
  @override
  Future<void> dismiss(String id) async => calls.add('dismiss $id');
}

TransferSnapshot snap(TransferPhase phase, {int done = 1240000000, TransferRole role = TransferRole.sending, int verified = 24}) => TransferSnapshot(
      transferId: 'tr_test',
      role: role,
      peerId: 'demo-iphone',
      peerName: "Ved's iPhone",
      peerKind: DeviceKind.phone,
      phase: phase,
      bytesDone: done,
      bytesTotal: 1800000000,
      filesDone: phase == TransferPhase.complete ? 24 : 16,
      filesTotal: 24,
      filesVerified: phase == TransferPhase.complete ? verified : 16,
      speed: phase == TransferPhase.running ? 94e6 : 0,
      etaSeconds: phase == TransferPhase.running ? 42 : null,
      path: const LinkPath(kind: PathKind.local, link: LinkKind.tcp),
      startedAt: DateTime(2026, 9, 30),
      label: '24 files',
    );

/// Pumps the whole app at [size]. Reduce Motion is on so the environment doesn't tick
/// forever and `pumpAndSettle` can settle.
Future<void> pumpApp(
  WidgetTester tester, {
  Size size = phone,
  bool demo = false,
  String route = '/',
  FakeTransfers? transfers,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  // A fresh app every time: otherwise the previous app's state (and router) is reused.
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(ProviderScope(
    overrides: [
      if (demo || transfers != null) ...[
        deviceDirectoryProvider.overrideWithValue(DemoDeviceDirectory()),
        transferHistoryProvider.overrideWithValue(DemoTransferHistory()),
      ],
      if (transfers != null) transferServiceProvider.overrideWithValue(transfers),
      if (demo && transfers == null) transferServiceProvider.overrideWithValue(DemoTransferService(autoStart: false)),
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
