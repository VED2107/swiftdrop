@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:swiftdrop_core/runtime.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Two complete engines, each in its own isolate, talking over loopback TCP lanes:
/// the path the app uses end to end.
late Directory tmp;

Future<EngineHost> engine(String name, {int lanes = 2}) => EngineHost.spawn(EngineConfig(
      dataDir: p.join(tmp.path, name, 'data'),
      downloadDir: p.join(tmp.path, name, 'Downloads'),
      name: name,
      kind: DeviceKind.laptop,
      platform: DevicePlatform.windows,
      port: 0,
      lanes: lanes,
      bindAddress: '127.0.0.1',
    ));

Future<T> until<T>(Stream<T> s, bool Function(T v) ok) => s.firstWhere(ok).timeout(const Duration(seconds: 60));

void main() {
  setUp(() async => tmp = await Directory.systemTemp.createTemp('sd_rt_'));
  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('connect by address, send, the other side accepts, both keep history', () async {
    final a = await engine('Laptop A');
    final b = await engine('Desk B');
    final src = p.join(tmp.path, 'files');
    await Directory(p.join(src, 'Trip')).create(recursive: true);
    await File(p.join(src, 'video.mov')).writeAsBytes(bytesOf(5 * 1024 * 1024 + 11, 3));
    for (var i = 0; i < 20; i++) {
      await File(p.join(src, 'Trip', 'IMG_$i.jpg')).writeAsBytes(bytesOf(9000 + i, 50 + i));
    }

    final bEnd = await until(b.endpoint(), (e) => e != null);
    final peer = await a.connect('127.0.0.1:${bEnd!.port}');
    expect(peer.name, 'Desk B');
    expect(peer.kind, DeviceKind.laptop);
    // B learned who connected (hello), so its offer can name the sender.
    await until(b.watch(), (d) => d.any((x) => x.name == 'Laptop A'));

    final id = await a.transferService.send(peer.id, [SendItem.file(p.join(src, 'video.mov')), SendItem.folder(p.join(src, 'Trip'))]);
    final offers = await until(b.transferService.incoming(), (o) => o.isNotEmpty);
    expect(offers.single.from.name, 'Laptop A');
    expect(offers.single.fileCount, 21);
    await b.transferService.accept(offers.single.transferId);

    final done = await until(a.transferService.watch(), (l) => l.any((t) => t.transferId == id && t.phase.isFinished));
    expect(done.firstWhere((t) => t.transferId == id).phase, TransferPhase.complete);
    final bDone = await until(b.transferService.watch(), (l) => l.any((t) => t.transferId == id && t.phase == TransferPhase.complete));
    final recv = bDone.firstWhere((t) => t.transferId == id);
    expect(recv.bytesDone, recv.bytesTotal);
    expect(recv.filesVerified, 21);

    final got = File(p.join(tmp.path, 'Desk B', 'Downloads', 'video.mov'));
    expect(sameBytes(await got.readAsBytes(), await File(p.join(src, 'video.mov')).readAsBytes()), isTrue);
    expect(File(p.join(tmp.path, 'Desk B', 'Downloads', 'Trip', 'IMG_19.jpg')).existsSync(), isTrue);

    final aHist = await until(a.history.watch(), (h) => h.isNotEmpty);
    expect(aHist.first.outcome, TransferOutcome.completed);
    expect(aHist.first.peerName, 'Desk B');
    final bHist = await until(b.history.watch(), (h) => h.isNotEmpty);
    expect(bHist.first.role, TransferRole.receiving);
    expect(bHist.first.verified, isTrue);

    await a.shutdown();
    await b.shutdown();

    // Known devices and history survive a restart.
    final a2 = await engine('Laptop A');
    final known = await until(a2.watch(), (d) => d.isNotEmpty);
    expect(known.single.name, 'Desk B');
    expect(known.single.status, DeviceStatus.offline);
    expect((await until(a2.history.watch(), (h) => h.isNotEmpty)).first.peerName, 'Desk B');
    await a2.shutdown();
  });

  test('declining tells the sender plainly', () async {
    final a = await engine('A', lanes: 1);
    final b = await engine('B', lanes: 1);
    final f = File(p.join(tmp.path, 'x.bin'))..writeAsBytesSync(bytesOf(4000));
    final bEnd = await until(b.endpoint(), (e) => e != null);
    final peer = await a.connect('127.0.0.1:${bEnd!.port}');
    final id = await a.transferService.send(peer.id, [SendItem.file(f.path)]);
    final offers = await until(b.transferService.incoming(), (o) => o.isNotEmpty);
    await b.transferService.decline(offers.single.transferId);
    final list = await until(a.transferService.watch(), (l) => l.any((t) => t.transferId == id && t.phase.isFinished));
    expect(list.firstWhere((t) => t.transferId == id).phase, TransferPhase.declined);
    expect(Directory(p.join(tmp.path, 'B', 'Downloads')).listSync(), isEmpty);
    await a.shutdown();
    await b.shutdown();
  });

  test('a bad address is a plain error', () async {
    final a = await engine('A', lanes: 1);
    await expectLater(a.connect('not an address'), throwsA(isA<TransportException>()));
    await a.shutdown();
  });
}
