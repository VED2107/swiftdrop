@Timeout(Duration(minutes: 5))
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;
import 'package:swiftdrop_core/engine.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Real files, real TCP over loopback, real receiving folder.
late Directory tmp;

Future<File> writeFile(String path, int size, int seed) async {
  final f = File(path);
  await f.parent.create(recursive: true);
  final sink = f.openWrite();
  const chunk = 4 << 20;
  for (var at = 0; at < size; at += chunk) {
    sink.add(bytesOf(at + chunk < size ? chunk : size - at, seed + at ~/ chunk));
  }
  await sink.close();
  return f;
}

Future<String> digestOf(String path) async => (await crypto.sha256.bind(File(path).openRead()).first).toString();

class Rig {
  Rig._(this.listener, this.receiver, this.dest);
  final TcpListener listener;
  final Receiver receiver;
  final String dest;
  final links = <TcpLink>[];

  static Future<Rig> start(String dest, {DuplicatePolicy policy = DuplicatePolicy.keepBoth}) async {
    final listener = await TcpListener.bind(address: InternetAddress.loopbackIPv4);
    final receiver = Receiver(ReceiverOptions(
      sinks: IoSinkFactory(dest),
      state: IoStateStore(p.join(dest, '.swiftdrop', 'state')),
      duplicates: () => policy,
      accept: (_) async => true,
    ));
    final rig = Rig._(listener, receiver, dest);
    listener.links.listen((l) {
      rig.links.add(l);
      receiver.serve(l);
    });
    return rig;
  }

  Future<TcpLink> dial() => TcpLink.dial(InternetAddress.loopbackIPv4.address, listener.port);
}

TransferJob job(EngineTransport t, List<FileSource> files) => TransferJob(JobOptions(
      transport: t,
      files: files,
      direction: Direction.toPeer,
      label: 'disk',
      controller: desktopController,
      sampleInterval: const Duration(milliseconds: 200),
    ));

void main() {
  setUp(() async => tmp = await Directory.systemTemp.createTemp('sd_tcp_'));
  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('large file, a folder of small files and an empty file arrive intact; memory stays bounded', () async {
    const bigSize = 256 << 20;
    final src = p.join(tmp.path, 'src');
    final big = await writeFile(p.join(src, 'movie.mov'), bigSize, 7);
    for (var i = 0; i < 300; i++) {
      await writeFile(p.join(src, 'Album', i.isEven ? 'a' : 'b', 'IMG_$i.JPG'), 2000 + i * 37, 100 + i);
    }
    await File(p.join(src, 'empty.txt')).writeAsBytes(const []);
    final rig = await Rig.start(p.join(tmp.path, 'dest'));
    final files = <FileSource>[IoFileSource(big.path), ...IoFileSource.folder(p.join(src, 'Album')), IoFileSource(p.join(src, 'empty.txt'))];

    final rssBefore = ProcessInfo.currentRss;
    var rssPeak = rssBefore;
    final sampler = Timer.periodic(const Duration(milliseconds: 25), (_) {
      final r = ProcessInfo.currentRss;
      if (r > rssPeak) rssPeak = r;
    });
    final sw = Stopwatch()..start();
    final j = job(PeerRpc(await rig.dial()), files);
    await j.start();
    await j.done;
    sw.stop();
    sampler.cancel();

    expect(j.snapshot().state, JobState.complete, reason: '${j.snapshot().errorCode}');
    expect(await digestOf(p.join(rig.dest, 'movie.mov')), await digestOf(big.path));
    expect(await File(p.join(rig.dest, 'Album', 'a', 'IMG_0.JPG')).readAsBytes(), await File(p.join(src, 'Album', 'a', 'IMG_0.JPG')).readAsBytes());
    expect(await File(p.join(rig.dest, 'Album', 'b', 'IMG_299.JPG')).length(), 2000 + 299 * 37);
    expect(await File(p.join(rig.dest, 'empty.txt')).length(), 0);
    expect((await File(p.join(rig.dest, 'movie.mov')).lastModified()).millisecondsSinceEpoch ~/ 1000,
        (await big.lastModified()).millisecondsSinceEpoch ~/ 1000);
    expect(Directory(p.join(rig.dest, '.swiftdrop')).existsSync(), isFalse, reason: 'bookkeeping removed when done');
    // Both ends run in this process: sender budget (128 MiB) + receiver reassembly cap
    // (96 MiB) bound the growth, independent of the 256 MiB file.
    final growth = rssPeak - rssBefore;
    expect(j.telemetry.peakInflightBytes, lessThanOrEqualTo(desktopController.memoryBudget));
    expect(growth, lessThan(320 << 20), reason: 'RSS grew ${growth >> 20} MiB');
    print('loopback TCP, disk to disk (test run, JIT, both ends in one isolate): '
        '${(j.bytesTotal / sw.elapsedMicroseconds).toStringAsFixed(1)} MB/s, '
        'peak in flight ${j.telemetry.peakInflightBytes >> 20} MiB, RSS +${growth >> 20} MiB');
    await rig.listener.close();
  });

  test('a dropped connection resumes on a new one and the file is intact', () async {
    final src = await writeFile(p.join(tmp.path, 'src', 'backup.zip'), 96 << 20, 3);
    final rig = await Rig.start(p.join(tmp.path, 'dest'));
    final rpc = PeerRpc(await rig.dial());
    final j = job(rpc, [IoFileSource(src.path)]);
    unawaited(j.start());
    while (j.snapshot().bytesDone < 24 << 20) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    (rpc.link! as TcpLink).kill();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(j.state, JobState.reconnecting);
    rpc.attach(await rig.dial());
    await j.done;
    expect(j.snapshot().state, JobState.complete);
    expect(await digestOf(p.join(rig.dest, 'backup.zip')), await digestOf(src.path));
    await rig.listener.close();
  });

  test('existing names: keep both numbers the new copy, replace overwrites', () async {
    final dest = p.join(tmp.path, 'dest');
    await writeFile(p.join(dest, 'report.pdf'), 10, 1);
    final src = await writeFile(p.join(tmp.path, 'src', 'report.pdf'), 5000, 2);

    final keep = await Rig.start(dest);
    final j1 = job(PeerRpc(await keep.dial()), [IoFileSource(src.path)]);
    await j1.start();
    await j1.done;
    expect(await File(p.join(dest, 'report.pdf')).length(), 10);
    expect(await File(p.join(dest, 'report (2).pdf')).length(), 5000);
    await keep.listener.close();

    final replace = await Rig.start(dest, policy: DuplicatePolicy.replace);
    final j2 = job(PeerRpc(await replace.dial()), [IoFileSource(src.path)]);
    await j2.start();
    await j2.done;
    expect(await File(p.join(dest, 'report.pdf')).length(), 5000);
    await replace.listener.close();
  });

  test('a peer can never write outside the destination', () async {
    final rig = await Rig.start(p.join(tmp.path, 'dest'));
    final evil = MemorySource('../../escape.txt', bytesOf(100), relDir: '../../..');
    final j = job(PeerRpc(await rig.dial()), [evil]);
    await j.start();
    await j.done;
    expect(j.snapshot().state, JobState.complete);
    expect(File(p.join(tmp.path, 'escape.txt')).existsSync(), isFalse);
    expect(File(p.join(rig.dest, '.._.._escape.txt')).existsSync() || File(p.join(rig.dest, '_.._escape.txt')).existsSync() ||
        Directory(rig.dest).listSync().whereType<File>().isNotEmpty, isTrue);
    await rig.listener.close();
  });

  group('lanes (parallel connections on isolates)', () {
    Future<(LaneReceiver, Receiver, String)> startLanes(String dest, int lanes) async {
      final receiver = Receiver(ReceiverOptions(
        sinks: IoSinkFactory(dest),
        state: IoStateStore(p.join(dest, '.swiftdrop', 'state')),
        accept: (_) async => true,
      ));
      final rx = await LaneReceiver.start(
        onRequest: (op, args, body, c) => receiver.handle(op, args, body),
        address: InternetAddress.loopbackIPv4,
        lanes: lanes,
      );
      return (rx, receiver, dest);
    }

    test('4 lanes carry a large file and a folder intact', () async {
      final src = p.join(tmp.path, 'src');
      final big = await writeFile(p.join(src, 'disk.img'), 160 << 20, 11);
      for (var i = 0; i < 120; i++) {
        await writeFile(p.join(src, 'Docs', 'n$i.txt'), 700 + i * 13, 300 + i);
      }
      final (rx, _, dest) = await startLanes(p.join(tmp.path, 'dest'), 4);
      final t = await LaneTransport.dial(InternetAddress.loopbackIPv4.address, rx.port, lanes: 4);
      final j = TransferJob(JobOptions(
        transport: t,
        files: [IoFileSource(big.path), ...IoFileSource.folder(p.join(src, 'Docs'))],
        direction: Direction.toPeer,
        controller: lanedController(desktopController, 4),
      ));
      await j.start();
      await j.done;
      expect(j.snapshot().state, JobState.complete, reason: '${j.snapshot().errorCode}');
      expect(await digestOf(p.join(dest, 'disk.img')), await digestOf(big.path));
      expect(await File(p.join(dest, 'Docs', 'n119.txt')).length(), 700 + 119 * 13);
      expect(rx.connections.length, greaterThanOrEqualTo(1));
      expect(j.telemetry.peakInflightBytes, lessThanOrEqualTo(desktopController.memoryBudget));
      await t.close();
      await rx.close();
    });

    test('a dropped primary connection heals by itself and the transfer resumes', () async {
      final src = await writeFile(p.join(tmp.path, 'src', 'photos.zip'), 96 << 20, 21);
      final (rx, _, dest) = await startLanes(p.join(tmp.path, 'dest'), 2);
      final t = await LaneTransport.dial(InternetAddress.loopbackIPv4.address, rx.port, lanes: 2);
      final j = TransferJob(JobOptions(transport: t, files: [IoFileSource(src.path)], direction: Direction.toPeer));
      unawaited(j.start());
      while (j.snapshot().bytesDone < 20 << 20) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      (t.primary.link! as TcpLink).kill();
      await j.done;
      expect(j.snapshot().state, JobState.complete);
      expect(j.snapshot().reconnects, greaterThanOrEqualTo(1));
      expect(await digestOf(p.join(dest, 'photos.zip')), await digestOf(src.path));
      await t.close();
      await rx.close();
    });
  });

  test('frames: the TCP codec round-trips control and data', () {
    final ctrl = encodeControl(const RequestMessage(id: 7, op: 'blocks', args: {'transferId': 'tr_abcdef'}, bodyLength: 10));
    final back = decodeFrame(ctrl)! as RequestMessage;
    expect([back.id, back.op, back.bodyLength], [7, 'blocks', 10]);
    final header = encodeDataHeader(7, 65536);
    final data = decodeFrame(Uint8List.fromList([...header, 1, 2, 3]))! as DataFrame;
    expect([data.requestId, data.offset, data.bytes], [7, 65536, [1, 2, 3]]);
  });
}
