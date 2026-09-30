import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:swiftdrop_core/engine.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';

/// Native (Dart) engine benchmarks. Same methodology as tests/performance: sender and
/// receiver in separate processes, real files on disk, JSON results.
///
///   dart compile exe bin/bench.dart -o build/bench.exe
///   build/bench.exe primitives                        hashing + disk read/write in isolation
///   build/bench.exe loopback --mb 1024 [--small 10000] one process sends to another over TCP
///   build/bench.exe receive --port N --dest DIR       (spawned by loopback)
Future<void> main(List<String> args) async {
  final cmd = args.isEmpty ? 'primitives' : args.first;
  final opts = _parse(args.skip(1).toList());
  switch (cmd) {
    case 'primitives':
      await primitives();
    case 'loopback':
      await loopback(int.parse(opts['mb'] ?? '1024'), int.parse(opts['small'] ?? '0'), opts['integrity'] ?? 'xxh64', opts['out'], sink: opts['sink'] ?? 'disk', opts: opts);
    case 'receive':
      await receive(int.parse(opts['port']!), opts['dest']!, sink: opts['sink'] ?? 'disk', lanes: int.parse(opts['lanes'] ?? '1'));
    default:
      stderr.writeln('unknown command $cmd');
      exitCode = 2;
  }
}

Map<String, String> _parse(List<String> a) => {
      for (var i = 0; i + 1 < a.length; i += 2)
        if (a[i].startsWith('--')) a[i].substring(2): a[i + 1],
    };

double mbps(int bytes, Duration d) => bytes / d.inMicroseconds;

Future<void> primitives() async {
  final data = Uint8List(256 << 20);
  for (var i = 0; i < data.length; i += 4096) {
    data[i] = i & 0xff;
  }
  final out = <String, Object>{};
  for (final algo in IntegrityAlgo.values) {
    final h = blockHasher(algo);
    h.hashBlocks(Uint8List.sublistView(data, 0, 16 << 20), blockSize); // warm up
    final sw = Stopwatch()..start();
    h.hashBlocks(data, blockSize);
    out['hash_${algo.wire}_MBps'] = mbps(data.length, sw.elapsed).round();
  }
  final tmp = await Directory.systemTemp.createTemp('sd_bench_');
  final f = File(p.join(tmp.path, 'w.bin'));
  var sw = Stopwatch()..start();
  final raf = await f.open(mode: FileMode.write);
  for (var at = 0; at < data.length; at += 16 << 20) {
    await raf.writeFrom(data, at, at + (16 << 20));
  }
  await raf.flush();
  await raf.close();
  out['disk_write_16MiB_chunks_MBps'] = mbps(data.length, sw.elapsed).round();
  sw = Stopwatch()..start();
  final r = await f.open();
  final buf = Uint8List(16 << 20);
  for (var at = 0; at < data.length; at += buf.length) {
    await r.setPosition(at);
    await r.readInto(buf);
  }
  await r.close();
  out['disk_read_16MiB_chunks_MBps'] = mbps(data.length, sw.elapsed).round();
  await tmp.delete(recursive: true);
  stdout.writeln(const JsonEncoder.withIndent(' ').convert(out));
}

Future<void> receive(int port, String dest, {String sink = 'disk', int lanes = 1}) async {
  final receiver = Receiver(ReceiverOptions(sinks: sink == 'null' ? NullSinks() : IoSinkFactory(dest), accept: (_) async => true, duplicates: () => DuplicatePolicy.replace));
  final lanesRx = await LaneReceiver.start(
    onRequest: (op, args, body, c) => receiver.handle(op, args, body),
    port: port,
    address: InternetAddress.loopbackIPv4,
    lanes: lanes,
  );
  stdout.writeln('ready ${lanesRx.port}');
  final probe = LoopProbe();
  await stdin.drain<void>(); // parent closes stdin to stop us
  stdout.writeln('busy ${probe.stop().toStringAsFixed(2)}');
  stdout.writeln('rss ${ProcessInfo.maxRss >> 20}');
  await stdout.flush();
  await lanesRx.close();
  exit(0);
}

Future<void> loopback(int mb, int small, String integrity, String? outPath, {String sink = 'disk', Map<String, String> opts = const {}}) async {
  final tmp = await Directory.systemTemp.createTemp('sd_loop_');
  final src = p.join(tmp.path, 'src');
  final dest = p.join(tmp.path, 'dest');
  await Directory(src).create(recursive: true);
  final files = <FileSource>[];
  if (mb > 0) {
    final f = File(p.join(src, 'big.bin'));
    final sink = f.openWrite();
    final chunk = Uint8List(8 << 20);
    for (var i = 0; i < chunk.length; i++) {
      chunk[i] = (i * 31 + (i >> 9)) & 0xff;
    }
    for (var i = 0; i < mb ~/ 8; i++) {
      chunk[0] = i & 0xff;
      sink.add(chunk);
    }
    await sink.close();
    files.add(IoFileSource(f.path));
  }
  for (var i = 0; i < small; i++) {
    final f = File(p.join(src, 'small', 'd${i % 16}', 'f$i.bin'));
    await f.parent.create(recursive: true);
    await f.writeAsBytes(Uint8List(50 * 1000)..[0] = i & 0xff);
  }
  if (small > 0) files.addAll(IoFileSource.folder(p.join(src, 'small')));

  final exe = Platform.resolvedExecutable;
  final script = Platform.script.toFilePath();
  final isAot = !exe.toLowerCase().contains('dart');
  final child = await Process.start(exe, [if (!isAot) script, 'receive', '--port', '0', '--dest', dest, '--sink', sink, '--lanes', opts['lanes'] ?? '1']);
  final seen = <String>[];
  final waiters = <(String, Completer<String>)>[];
  child.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((l) {
    seen.add(l);
    for (final w in waiters.where((w) => l.startsWith(w.$1)).toList()) {
      waiters.remove(w);
      w.$2.complete(l);
    }
  });
  child.stderr.transform(utf8.decoder).listen(stderr.write);
  Future<String> line(String prefix) {
    final hit = seen.where((l) => l.startsWith(prefix));
    if (hit.isNotEmpty) return Future.value(hit.first);
    final c = Completer<String>();
    waiters.add((prefix, c));
    return c.future;
  }

  final port = int.parse((await line('ready ')).substring(6));

  final lanes = int.parse(opts['lanes'] ?? '1');
  final transport = await LaneTransport.dial(InternetAddress.loopbackIPv4.address, port, lanes: lanes);
  final job = TransferJob(JobOptions(
    transport: transport,
    files: files,
    direction: Direction.toPeer,
    integrity: IntegrityAlgo.fromWire(integrity),
    controller: switch (opts['controller']) {
      'small' => desktopController.copyWith(maxStreams: 16, maxBlocks: 2, initialBlocks: 1),
      'one' => desktopController.copyWith(maxStreams: 16, maxBlocks: 1, initialBlocks: 1),
      _ => lanedController(desktopController, lanes),
    },
  ));
  final rssBefore = ProcessInfo.currentRss;
  final probe = LoopProbe();
  final sw = Stopwatch()..start();
  await job.start();
  await job.done;
  sw.stop();
  final senderBusy = probe.stop();
  final snap = job.snapshot();
  final rssLine = line('rss ');
  await child.stdin.close();
  final receiverRss = int.parse((await rssLine).substring(4));
  final receiverBusy = (await line('busy ')).substring(5);
  await transport.close();
  final t = job.telemetry;
  final result = {
    'engine': 'dart ${Platform.version.split(' ').first} ${isAot ? 'AOT' : 'JIT'}',
    'os': Platform.operatingSystemVersion,
    'transport': 'TCP loopback, lanes: $lanes',
    'receiverSink': sink,
    'integrity': integrity,
    'bytes': job.bytesTotal,
    'files': files.length,
    'state': snap.state.name,
    'seconds': sw.elapsedMicroseconds / 1e6,
    'MBps': mbps(job.bytesTotal, sw.elapsed).round(),
    'filesPerSecond': (files.length / (sw.elapsedMicroseconds / 1e6)).round(),
    'streamsSettled': snap.streams,
    'chunkMiB': snap.chunkBytes >> 20,
    'senderPeakInflightMiB': t.peakInflightBytes >> 20,
    'senderRssMiB': ProcessInfo.maxRss >> 20,
    'senderRssGrowthMiB': (ProcessInfo.maxRss - rssBefore) >> 20,
    'receiverPeakRssMiB': receiverRss,
    'senderLoopBusy': senderBusy.toStringAsFixed(2),
    'receiverLoopBusy (includes idle wait before/after)': receiverBusy,
    'senderStageMs': {'read': t.readMs.round(), 'hash': t.hashMs.round(), 'frame': t.frameMs.round(), 'network+receiver': t.networkMs.round()},
  };
  final json = const JsonEncoder.withIndent(' ').convert(result);
  stdout.writeln(json);
  if (outPath != null) await File(outPath).writeAsString('$json\n');
  await tmp.delete(recursive: true);
}

/// Receiver storage that discards: separates network + engine cost from disk cost.
class NullSinks implements SinkFactory {
  @override
  Future<FileSink> open(String transferId, String fileId, int size) async => _NullSink();
  @override
  Future<void> writeWhole(String transferId, String fileId, Uint8List bytes) async {}
  @override
  Future<void> discard(String transferId, String fileId) async {}
  @override
  Future<bool> exists(List<String> relDir, String name) async => false;
  @override
  Future<String> finish(String transferId, String fileId,
          {required List<String> relDir, required String name, required int lastModified, required bool replace}) async =>
      name;
  @override
  Future<void> remove(String transferId) async {}
  @override
  Future<int?> freeSpace() async => null;
}

class _NullSink implements FileSink {
  @override
  Future<void> write(int position, Uint8List bytes) async {}
  @override
  Future<void> close() async {}
}

/// Estimates how busy this isolate's event loop is: a 5 ms timer's lateness adds up to
/// the time the loop was occupied with other work.
class LoopProbe {
  LoopProbe() {
    _last = _sw.elapsedMicroseconds;
    _t = Timer.periodic(const Duration(milliseconds: 5), (_) {
      final now = _sw.elapsedMicroseconds;
      final late = now - _last - 5000;
      if (late > 0) _busyUs += late;
      _last = now;
    });
  }
  final _sw = Stopwatch()..start();
  late int _last;
  int _busyUs = 0;
  late final Timer _t;
  double stop() {
    _t.cancel();
    return _busyUs / _sw.elapsedMicroseconds;
  }
}
