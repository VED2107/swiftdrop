// Measurement scratch tool; kept for reproducing docs/BENCHMARKS.md.
// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:typed_data';

import 'package:swiftdrop_core/engine.dart';

Future<void> main() async {
  final dir = await Directory.systemTemp.createTemp('sd_small_');
  final data = Uint8List(50000);
  const n = 2000;
  Future<void> time(String name, Future<void> Function(int i) op) async {
    final sw = Stopwatch()..start();
    for (var i = 0; i < n; i++) {
      await op(i);
    }
    print('$name: ${(n / (sw.elapsedMicroseconds / 1e6)).toStringAsFixed(0)} files/s');
  }

  await time('writeAsBytesSync only', (i) async => File('${dir.path}/a$i.bin').writeAsBytesSync(data));
  await time('open append + write + close', (i) async {
    final r = File('${dir.path}/b$i.part').openSync(mode: FileMode.append);
    r.writeFromSync(data);
    r.closeSync();
  });
  await time('+ flushSync', (i) async {
    final r = File('${dir.path}/c$i.part').openSync(mode: FileMode.append);
    r.writeFromSync(data);
    r.flushSync();
    r.closeSync();
  });
  await time('renameSync', (i) async => File('${dir.path}/b$i.part').renameSync('${dir.path}/b$i.bin'));
  await time('setLastModifiedSync', (i) async => File('${dir.path}/b$i.bin').setLastModifiedSync(DateTime(2024)));
  await time('existsSync x2', (i) async {
    File('${dir.path}/z$i.bin').existsSync();
    File('${dir.path}/b$i.bin').existsSync();
  });
  final sinks = IoSinkFactory('${dir.path}/dest');
  await time('IoSinkFactory full path', (i) async {
    final s = await sinks.open('tr_x', 'f$i', data.length);
    await s.write(0, data);
    await s.close();
    await sinks.finish('tr_x', 'f$i', relDir: ['d${i % 16}'], name: 'f$i.bin', lastModified: 1700000000000, replace: false);
  });
  // A FileWorkers isolate pool (write + rename) measured 472 / 486 / 493 / 515 files/s with
  // 1 / 2 / 4 / 8 workers: no scaling, so it was removed (docs/BENCHMARKS.md).
  await dir.delete(recursive: true);
}
