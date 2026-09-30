// Measurement scratch tool; kept for reproducing docs/BENCHMARKS.md.
// ignore_for_file: curly_braces_in_flow_control_structures, avoid_print
import 'dart:io';
import 'dart:typed_data';

Future<void> main() async {
  final data = Uint8List(512 << 20);
  for (var i = 0; i < data.length; i += 4096) data[i] = i & 0xff;
  final dir = await Directory.systemTemp.createTemp('sd_io_');
  Future<void> run(String name, Future<void> Function(File f) body) async {
    final f = File('${dir.path}/$name.bin');
    final sw = Stopwatch()..start();
    await body(f);
    print('$name: ${(data.length / sw.elapsedMicroseconds).toStringAsFixed(0)} MB/s');
    await f.delete();
  }
  for (final chunk in [1 << 20, 4 << 20, 16 << 20]) {
    await run('async writeFrom ${chunk >> 20}MiB', (f) async {
      final r = await f.open(mode: FileMode.write);
      for (var at = 0; at < data.length; at += chunk) await r.writeFrom(data, at, at + chunk);
      await r.close();
    });
    await run('sync writeFromSync ${chunk >> 20}MiB', (f) async {
      final r = f.openSync(mode: FileMode.write);
      for (var at = 0; at < data.length; at += chunk) r.writeFromSync(data, at, at + chunk);
      r.closeSync();
    });
    await run('async setPosition+writeFrom ${chunk >> 20}MiB', (f) async {
      final r = await f.open(mode: FileMode.append);
      for (var at = 0; at < data.length; at += chunk) { await r.setPosition(at); await r.writeFrom(data, at, at + chunk); }
      await r.close();
    });
  }
  await run('IOSink openWrite 16MiB adds', (f) async {
    final s = f.openWrite();
    for (var at = 0; at < data.length; at += 16 << 20) s.add(Uint8List.sublistView(data, at, at + (16 << 20)));
    await s.close();
  });
  for (final chunk in [1 << 20, 16 << 20]) {
    final f = File('${dir.path}/r.bin')..writeAsBytesSync(data);
    var sw = Stopwatch()..start();
    final r = await f.open();
    final buf = Uint8List(chunk);
    for (var at = 0; at < data.length; at += chunk) { await r.setPosition(at); await r.readInto(buf); }
    await r.close();
    print('async readInto ${chunk >> 20}MiB: ${(data.length / sw.elapsedMicroseconds).toStringAsFixed(0)} MB/s');
    sw = Stopwatch()..start();
    final rs = f.openSync();
    for (var at = 0; at < data.length; at += chunk) { rs.setPositionSync(at); rs.readIntoSync(buf); }
    rs.closeSync();
    print('sync readIntoSync ${chunk >> 20}MiB: ${(data.length / sw.elapsedMicroseconds).toStringAsFixed(0)} MB/s');
  }
  await dir.delete(recursive: true);
}
