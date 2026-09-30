// Measurement scratch tool; kept for reproducing docs/BENCHMARKS.md.
// ignore_for_file: curly_braces_in_flow_control_structures, avoid_print
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:swiftdrop_core/engine.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';

const total = 1 << 30;

/// Receiver in another isolate: counts bytes, replies when all arrived.
Future<int> startCounter(bool raw) async {
  final port = ReceivePort();
  await Isolate.spawn(_counter, (port.sendPort, raw));
  return await port.first as int;
}

Future<void> _counter((SendPort, bool) args) async {
  final (reply, raw) = args;
  if (raw) {
    final l = await TcpListener.bind(address: InternetAddress.loopbackIPv4);
    reply.send(l.port);
    await for (final link in l.links) {
      var got = 0;
      link.data.listen((f) {
        got += f.bytes.length;
        if (got >= total) link.sendControl(const ResponseMessage.ok(1));
      });
    }
  } else {
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
}

Future<void> main() async {
  final buf = Uint8List(1 << 20);
  // 1: TcpLink (RawSocket), frames of 1 MiB
  var port = await startCounter(true);
  var link = await TcpLink.dial('127.0.0.1', port);
  final done = link.control.first;
  var sw = Stopwatch()..start();
  for (var i = 0; i < total ~/ buf.length; i++) {
    await link.sendChunk(1, 0, buf);
  }
  await done;
  print('TcpLink (RawSocket) 1 MiB frames: ${(total / sw.elapsedMicroseconds).toStringAsFixed(0)} MB/s');
  // 2: dart:io Socket (IOSink), 1 MiB adds with flush every 8 MiB
  port = await startCounter(false);
  final s = await Socket.connect('127.0.0.1', port);
  s.setOption(SocketOption.tcpNoDelay, true);
  final ack = s.first;
  sw = Stopwatch()..start();
  for (var i = 0; i < total ~/ buf.length; i++) {
    s.add(buf);
    if (i % 8 == 7) await s.flush();
  }
  await s.flush();
  await ack;
  print('Socket (IOSink) 1 MiB adds: ${(total / sw.elapsedMicroseconds).toStringAsFixed(0)} MB/s');
  exit(0);
}
