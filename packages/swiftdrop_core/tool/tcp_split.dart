// Measurement scratch tool; kept for reproducing docs/BENCHMARKS.md.
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:swiftdrop_core/engine.dart';

const total = 1 << 30;

Future<void> _plainCounter(SendPort reply) async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  reply.send(s.port);
  await for (final c in s) {
    var got = 0;
    c.listen((d) {
      got += d.length;
      if (got >= total) c.add([1]);
    });
  }
}

Future<void> _linkCounter(SendPort reply) async {
  final l = await TcpListener.bind(address: InternetAddress.loopbackIPv4);
  reply.send(l.port);
  await for (final link in l.links) {
    var got = 0;
    link.data.listen((f) {
      got += f.bytes.length;
      if (got >= total - (total ~/ (1 << 20)) * 0) {}
      if (got >= total) link.sendChunk(1, 0, Uint8List(1));
    });
  }
}

Future<int> spawn(void Function(SendPort) fn) async {
  final p = ReceivePort();
  await Isolate.spawn(fn, p.sendPort);
  return await p.first as int;
}

Future<void> main() async {
  final buf = Uint8List(1 << 20);
  // sender = TcpLink, receiver = plain byte counter (no parsing)
  var port = await spawn(_plainCounter);
  var link = await TcpLink.dial('127.0.0.1', port);
  var ack = Completer<void>();
  final raw = await Socket.connect('127.0.0.1', port); // unused; keeps symmetry
  raw.destroy();
  // plain counter replies with a raw byte, which TcpLink would treat as a frame; detect via bytesReceived
  var sw = Stopwatch()..start();
  for (var i = 0; i < total ~/ buf.length; i++) {
    await link.sendChunk(1, 0, buf);
  }
  while (link.bytesReceived == 0) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  print('TcpLink sender -> plain counter: ${(total / sw.elapsedMicroseconds).toStringAsFixed(0)} MB/s');
  // sender = plain Socket writing framed data, receiver = TcpLink parser
  port = await spawn(_linkCounter);
  final s = await Socket.connect('127.0.0.1', port);
  s.setOption(SocketOption.tcpNoDelay, true);
  final header = Uint8List(13);
  ByteData.sublistView(header)
    ..setUint32(0, 9 + buf.length)
    ..setUint8(4, 2)
    ..setUint32(5, 1)
    ..setUint32(9, 0);
  final got = s.first;
  sw = Stopwatch()..start();
  for (var i = 0; i < total ~/ buf.length; i++) {
    s.add(header);
    s.add(buf);
    if (i % 8 == 7) await s.flush();
  }
  await s.flush();
  await got;
  print('plain framed sender -> TcpLink parser: ${(total / sw.elapsedMicroseconds).toStringAsFixed(0)} MB/s');
  ack.complete();
  exit(0);
}
