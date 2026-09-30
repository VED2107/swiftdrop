import 'dart:async';
import 'dart:typed_data';

import 'package:swiftdrop_core/engine.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Sender ⇄ receiver over an in-memory link: the Dart counterpart of
/// packages/peer/src/peer.test.ts, same scenarios.

class Setup {
  Setup({Future<bool> Function(IncomingManifest o)? accept, DuplicatePolicy policy = DuplicatePolicy.keepBoth})
      : _accept = accept ?? ((_) async => true),
        _policy = policy // ignore: prefer_initializing_formals
  {
    receiver = Receiver(ReceiverOptions(
      sinks: sinks,
      state: state,
      duplicates: () => _policy,
      accept: (o) {
        offers.add(o);
        return _accept(o);
      },
    ));
  }

  final Future<bool> Function(IncomingManifest o) _accept;
  final DuplicatePolicy _policy;
  final sinks = MemorySinks();
  final state = MemoryState();
  final offers = <IncomingManifest>[];
  late Receiver receiver;

  MemoryLink connect({int highWater = 256 << 10}) {
    final (a, b) = MemoryLink.pair(highWater: highWater);
    receiver.serve(b);
    return a;
  }
}

TransferJob job(EngineTransport t, List<FileSource> files, {ControllerConfig controller = peerController}) => TransferJob(JobOptions(
      transport: t,
      files: files,
      direction: Direction.toPeer,
      label: 'Holiday',
      controller: controller,
      sampleInterval: const Duration(milliseconds: 50),
    ));

void main() {
  test('moves large, small, empty and nested files byte-for-byte after the receiver accepts', () async {
    final s = Setup();
    final link = s.connect();
    final big = bytesOf(6 * blockSize + 777, 1);
    final smalls = [for (var i = 0; i < 40; i++) MemorySource('IMG_$i.JPG', bytesOf(3000 + i * 11, 10 + i), relDir: 'DCIM')];
    final files = <FileSource>[MemorySource('clip.mov', big), MemorySource('empty.txt', Uint8List(0)), ...smalls];
    final j = job(PeerRpc(link), files);
    await j.start();
    await j.done;
    expect(j.snapshot().state, JobState.complete);
    expect(s.offers, hasLength(1));
    expect(s.offers.single.totalBytes, j.bytesTotal);
    final t = s.receiver.get(j.id)!;
    expect(t.filesDone, files.length);
    expect(sameBytes(s.sinks.finals['clip.mov']!, big), isTrue);
    expect(sameBytes(s.sinks.finals['DCIM/IMG_7.JPG']!, bytesOf(3000 + 7 * 11, 17)), isTrue);
    expect(s.sinks.finals['empty.txt'], isEmpty);
    expect(t.byId[smalls[0].id]!.finalName, 'DCIM/IMG_0.JPG');
    expect(s.state.data, isEmpty, reason: 'no bookkeeping left once every file is in place');
  });

  test('stops with DECLINED when the person on the other device says no', () async {
    final s = Setup(accept: (_) async => false);
    final j = job(PeerRpc(s.connect()), [MemorySource('a.bin', bytesOf(1000))]);
    await j.start();
    await j.done;
    expect(j.snapshot().state, JobState.failed);
    expect(j.snapshot().errorCode, ErrorCode.declined);
    expect(s.sinks.finals, isEmpty);
  });

  test('detects a block damaged in flight and resends it', () async {
    final s = Setup();
    final link = s.connect();
    var damaged = false;
    // Corrupt one data frame of the receiver's side of the pair.
    final (a, b) = MemoryLink.pair();
    s.receiver.serve(b);
    a.tamper = (f) {
      if (damaged || f.bytes.length < 1000) return f.bytes;
      damaged = true;
      final copy = Uint8List.fromList(f.bytes);
      copy[10] ^= 0xff;
      return copy;
    };
    await link.close();
    final big = bytesOf(3 * blockSize, 5);
    final j = job(PeerRpc(a), [MemorySource('video.mp4', big)]);
    await j.start();
    await j.done;
    expect(damaged, isTrue);
    expect(j.snapshot().state, JobState.complete);
    expect(j.snapshot().retries, greaterThan(0));
    expect(sameBytes(s.sinks.finals['video.mp4']!, big), isTrue);
  });

  test('survives the link dropping: a new link resumes and only missing blocks are sent', () async {
    final s = Setup();
    final rpc = PeerRpc(s.connect());
    final src = MemorySource('long.bin', bytesOf(24 * blockSize, 9));
    final j = job(rpc, [src]);
    unawaited(j.start());
    // Drop once about a third has been acknowledged.
    while (j.snapshot().bytesDone < 8 * blockSize) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    (rpc.link! as MemoryLink).dropBoth();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(j.state, JobState.reconnecting);
    final readBeforeResume = src.bytesRead;
    rpc.attach(s.connect());
    await j.done;
    expect(j.snapshot().state, JobState.complete);
    expect(j.snapshot().reconnects, 1);
    expect(sameBytes(s.sinks.finals['long.bin']!, src.data), isTrue);
    // After resume the sender reads what's missing plus a local re-hash of what the
    // receiver already had (for the root), never a second full send of acked blocks.
    expect(src.bytesRead - readBeforeResume, lessThan(2 * src.size));
  });

  test('keeps the send buffer bounded on a slow link (backpressure)', () async {
    final s = Setup();
    final (a, b) = MemoryLink.pair(highWater: 256 << 10, bytesPerTick: 16 << 10);
    s.receiver.serve(b);
    final j = job(PeerRpc(a), [MemorySource('x.bin', bytesOf(4 * blockSize, 3))]);
    await j.start();
    await j.done;
    expect(j.snapshot().state, JobState.complete);
    expect(a.peakBuffered, lessThanOrEqualTo((256 << 10) + (64 << 10) + 1024));
    expect(j.telemetry.peakInflightBytes, lessThanOrEqualTo(peerController.memoryBudget));
  });

  test('resumes on a restarted receiver from its saved state', () async {
    final s = Setup();
    final rpc = PeerRpc(s.connect());
    final src = MemorySource('movie.mkv', bytesOf(12 * blockSize, 4));
    final j = job(rpc, [src]);
    unawaited(j.start());
    while (j.snapshot().bytesDone < 4 * blockSize) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    (rpc.link! as MemoryLink).dropBoth();
    await s.receiver.flush();
    // "App restart": a fresh receiver over the same storage and state.
    final restarted = Receiver(ReceiverOptions(sinks: s.sinks, state: s.state, accept: (_) async => fail('must not ask again')));
    final (a, b) = MemoryLink.pair();
    restarted.serve(b);
    rpc.attach(a);
    await j.done;
    expect(j.snapshot().state, JobState.complete);
    expect(sameBytes(s.sinks.finals['movie.mkv']!, src.data), isTrue);
  });

  test('cancel stops the sender and clears the receiver', () async {
    final s = Setup();
    final j = job(PeerRpc(s.connect()), [MemorySource('big.bin', bytesOf(20 * blockSize, 2))]);
    unawaited(j.start());
    while (j.snapshot().bytesDone < 2 * blockSize) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    await j.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(j.state, JobState.cancelled);
    expect(s.receiver.get(j.id), isNull);
    expect(s.sinks.parts, isEmpty);
    expect(s.sinks.finals, isEmpty);
  });

  group('duplicate names', () {
    Future<Setup> send(DuplicatePolicy policy) async {
      final s = Setup(policy: policy);
      s.sinks.existing.addAll(['report.pdf', 'big.bin']);
      final j = job(PeerRpc(s.connect()), [MemorySource('report.pdf', bytesOf(5000, 1)), MemorySource('big.bin', bytesOf(blockSize + 5, 2))]);
      await j.start();
      await j.done;
      expect(j.snapshot().state, JobState.complete);
      return s;
    }

    test('keep both numbers the new copy', () async {
      final s = await send(DuplicatePolicy.keepBoth);
      expect(s.sinks.finals.keys, containsAll(['report (2).pdf', 'big (2).bin']));
    });
    test('replace takes the name', () async {
      final s = await send(DuplicatePolicy.replace);
      expect(s.sinks.finals.keys, containsAll(['report.pdf', 'big.bin']));
    });
    test('skip leaves the existing file alone', () async {
      final s = await send(DuplicatePolicy.skip);
      expect(s.sinks.finals, isEmpty);
    });
  });

  test('a file that changes on disk after picking is refused, not sent stale', () async {
    final s = Setup();
    final changing = _ChangedSource();
    final j = job(PeerRpc(s.connect()), [changing]);
    await j.start();
    await j.done;
    expect(j.snapshot().state, JobState.failed);
    expect(j.snapshot().errorCode, ErrorCode.sourceChanged);
  });
}

class _ChangedSource implements FileSource {
  @override
  String get id => 'f_changed';
  @override
  String get name => 'draft.docx';
  @override
  String get relDir => '';
  @override
  int get size => 2 * blockSize;
  @override
  String get type => '';
  @override
  int get lastModified => 1;
  @override
  Future<ByteReader> open() => Future.error(ProtocolException(ErrorCode.sourceChanged));
}
