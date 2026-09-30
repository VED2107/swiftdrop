// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

const total = 1 << 30;

Future<void> _sender(int port) async {
  final s = await Socket.connect('127.0.0.1', port);
  final buf = Uint8List((1 << 20) + 13);
  for (var i = 0; i < total ~/ (1 << 20); i++) {
    s.add(buf);
    if (i % 8 == 7) await s.flush();
  }
  await s.flush();
  await s.close();
}

Future<void> main() async {
  final srv = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  await Isolate.spawn(_sender, srv.port);
  final c = await srv.first;
  var chunks = 0, bytes = 0, maxChunk = 0;
  final sizes = <int, int>{};
  final sw = Stopwatch()..start();
  await for (final d in c) {
    chunks++;
    bytes += d.length;
    if (d.length > maxChunk) maxChunk = d.length;
    final bucket = d.length < 1024 ? 0 : (d.length < 65536 ? 1 : 2);
    sizes[bucket] = (sizes[bucket] ?? 0) + 1;
  }
  print('chunks $chunks, avg ${bytes ~/ chunks} B, max $maxChunk, <1K ${sizes[0]} <64K ${sizes[1]} >=64K ${sizes[2]}, ${(bytes / sw.elapsedMicroseconds).toStringAsFixed(0)} MB/s');
  exit(0);
}
