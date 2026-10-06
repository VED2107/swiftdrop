// Sends files to a running SwiftDrop app (a phone, an emulator behind `adb forward`):
//   dart run tool/send_to.dart 127.0.0.1:47800 file1 [file2 ...]
// Prints progress and throughput; exits non-zero unless the receiver verified everything.
import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:swiftdrop_core/runtime.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('usage: send_to <host:port> <file|folder>...');
    exit(64);
  }
  final tmp = await Directory.systemTemp.createTemp('sd_send_');
  final rt = await EngineRuntime.start(EngineConfig(
    dataDir: p.join(tmp.path, 'data'),
    downloadDir: p.join(tmp.path, 'in'),
    name: 'Test sender',
    port: 0,
    lanes: 2,
    bindAddress: '127.0.0.1',
  ));
  final dev = await rt.connect(args.first);
  print('connected to ${dev.name} (${dev.platform.name})');
  final items = [
    for (final a in args.skip(1))
      FileSystemEntity.isDirectorySync(a) ? SendItem.folder(a) : SendItem.file(a),
  ];
  final sw = Stopwatch()..start();
  final id = await rt.send(dev.id, items);
  final done = Completer<TransferSnapshot>();
  rt.transfers.listen((l) {
    for (final t in l) {
      if (t.transferId != id) continue;
      if (t.phase.isFinished && !done.isCompleted) done.complete(t);
    }
  });
  final t = await done.future.timeout(const Duration(minutes: 30));
  sw.stop();
  final mb = t.bytesTotal / 1e6;
  print('${t.phase.name}: ${t.filesDone}/${t.filesTotal} files, verified ${t.filesVerified}, '
      '${mb.toStringAsFixed(1)} MB in ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)} s '
      '(${(mb / (sw.elapsedMilliseconds / 1000)).toStringAsFixed(1)} MB/s)');
  await rt.stop();
  await tmp.delete(recursive: true);
  exit(t.phase == TransferPhase.complete && t.verified ? 0 : 1);
}
