// Measurement scratch tool; kept for reproducing docs/BENCHMARKS.md.
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:swiftdrop_core/engine.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';

/// k TCP connections carrying 1 GiB of pipelined 4 MiB requests between them.
/// Receiver side: every connection served on its own isolate (serverIsolates) or all on one.
Future<void> _serve((SendPort, int) a) async {
  final (reply, _) = a;
  final l = await TcpListener.bind(address: InternetAddress.loopbackIPv4);
  reply.send(l.port);
  await for (final link in l.links) {
    _handle(link);
  }
}

void _handle(TcpLink link) {
  final bodies = <int, (Uint8List, int)>{};
  link.control.listen((m) {
    if (m is RequestMessage && (m.bodyLength ?? 0) > 0) bodies[m.id] = (Uint8List(m.bodyLength!), 0);
  });
  link.data.listen((f) {
    final (buf, got) = bodies[f.requestId]!;
    buf.setRange(f.offset, f.offset + f.bytes.length, f.bytes);
    final g = got + f.bytes.length;
    if (g == buf.length) {
      bodies.remove(f.requestId);
      link.sendControl(ResponseMessage.ok(f.requestId, const {'load': 0}));
    } else {
      bodies[f.requestId] = (buf, g);
    }
  });
}

/// One sending connection, run in its own isolate: pushes `bytes` as 4 MiB requests.
Future<int> _send((int, int) a) async {
  final (port, bytes) = a;
  final link = await TcpLink.dial('127.0.0.1', port);
  final pending = <int, Completer<void>>{};
  link.control.listen((m) {
    if (m is ResponseMessage) pending.remove(m.id)?.complete();
  });
  final body = Uint8List(4 << 20);
  var next = 1, sent = 0;
  final n = bytes ~/ body.length;
  Future<void> worker() async {
    while (sent < n) {
      sent++;
      final id = next++;
      final c = Completer<void>();
      pending[id] = c;
      await link.sendControl(RequestMessage(id: id, op: 'blocks', bodyLength: body.length));
      await link.sendChunk(id, 0, body);
      await c.future;
    }
  }
  await Future.wait([for (var i = 0; i < 4; i++) worker()]);
  await link.close();
  return bytes;
}

Future<void> main() async {
  const total = 2 << 30;
  for (final k in [1, 2, 4, 8]) {
    // receiver: k isolates, each with its own listener; sender: k isolates, one connection each
    final ports = <int>[];
    for (var i = 0; i < k; i++) {
      final p = ReceivePort();
      await Isolate.spawn(_serve, (p.sendPort, i));
      ports.add(await p.first as int);
    }
    final sw = Stopwatch()..start();
    await Future.wait([for (final port in ports) Isolate.run(() => _send((port, total ~/ k)))]);
    print('$k connection(s), one isolate per connection each side: ${(total / sw.elapsedMicroseconds).toStringAsFixed(0)} MB/s');
  }
  exit(0);
}
