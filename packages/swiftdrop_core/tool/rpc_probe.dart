// Measurement scratch tool; kept for reproducing docs/BENCHMARKS.md.
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:swiftdrop_core/engine.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';

/// Pipelined request/response over TcpLink: N requests of S MiB in flight, receiver
/// reassembles each body (like the Receiver) and replies. No hashing, no disk.
Future<void> _server(SendPort reply) async {
  final l = await TcpListener.bind(address: InternetAddress.loopbackIPv4);
  reply.send(l.port);
  await for (final link in l.links) {
    final bodies = <int, (Uint8List, int)>{};
    final pool = <int, List<Uint8List>>{};
    link.control.listen((m) {
      if (m is RequestMessage && (m.bodyLength ?? 0) > 0) {
        final free = pool[m.bodyLength!];
        bodies[m.id] = (free != null && free.isNotEmpty ? free.removeLast() : Uint8List(m.bodyLength!), 0);
      }
    });
    link.data.listen((f) {
      final (buf, got) = bodies[f.requestId]!;
      buf.setRange(f.offset, f.offset + f.bytes.length, f.bytes);
      final g = got + f.bytes.length;
      if (g == buf.length) {
        bodies.remove(f.requestId);
        (pool[buf.length] ??= []).add(buf);
        link.sendControl(ResponseMessage.ok(f.requestId, const {'load': 0}));
      } else {
        bodies[f.requestId] = (buf, g);
      }
    });
  }
}

Future<void> main(List<String> args) async {
  final p = ReceivePort();
  await Isolate.spawn(_server, p.sendPort);
  final port = await p.first as int;
  for (final (inflight, mib) in [(1, 16), (3, 16), (5, 16), (5, 4), (8, 4), (12, 1)]) {
    final link = await TcpLink.dial('127.0.0.1', port);
    final pending = <int, Completer<void>>{};
    link.control.listen((m) {
      if (m is ResponseMessage) pending.remove(m.id)?.complete();
    });
    final body = Uint8List(mib << 20);
    var next = 1;
    const total = 1 << 30;
    final n = total ~/ body.length;
    final sw = Stopwatch()..start();
    var sent = 0;
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
    await Future.wait([for (var i = 0; i < inflight; i++) worker()]);
    print('in flight $inflight x $mib MiB: ${(total / sw.elapsedMicroseconds).toStringAsFixed(0)} MB/s');
    await link.close();
  }
  exit(0);
}
