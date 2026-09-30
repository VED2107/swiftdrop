import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../protocol/constants.dart';
import '../protocol/errors.dart';
import '../protocol/types.dart';
import 'engine_transport.dart';
import 'link.dart';
import 'peer_rpc.dart';
import 'tcp_link.dart';

/// Parallel TCP connections ("lanes"), each driven by its own isolate.
///
/// Why: measured on Windows loopback (tool/multi_conn.dart, AOT, 2 GiB) one Dart socket
/// carries ~276 MB/s while its isolate sits ~90% idle: the limit is per-socket I/O round
/// trips, not CPU. 2 / 4 / 8 connections on separate isolates: 406 / 502 / 533 MB/s.
/// Real Wi-Fi is measured in Phase 8; the lane count is a setting, not an assumption.
///
/// Sender: the job stays on its isolate (plans, reads, hashes, tracks progress);
/// [LaneTransport] runs control RPCs on the primary connection and spreads request
/// bodies across the primary and the lane isolates by least outstanding work.
///
/// Receiver: [LaneReceiver] binds one port shared by several isolates (the OS hands each
/// connection to one of them). Each isolate reassembles its requests and forwards complete
/// bodies to the coordinator isolate, where the single [Receiver] verifies, writes and
/// owns all transfer state. Protocol frames are unchanged: a lane is just another peer
/// connection, so a single-connection peer interoperates.

// ---------------------------------------------------------------------------
// Sender

class LaneTransport implements EngineTransport {
  LaneTransport._(this.host, this.port, this.laneCount, this.onConnected);

  /// Connects the primary link (control + data) and starts [lanes] - 1 extra lane isolates.
  static Future<LaneTransport> dial(
    String host,
    int port, {
    int lanes = 4,
    Future<void> Function(PeerRpc primary)? onConnected,
  }) async {
    final t = LaneTransport._(host, port, lanes < 1 ? 1 : lanes, onConnected);
    await t._connectPrimary();
    for (var i = 1; i < t.laneCount; i++) {
      t._lanes.add(await _SenderLane.spawn(host, port));
    }
    return t;
  }

  final String host;
  final int port;
  final int laneCount;
  final Future<void> Function(PeerRpc primary)? onConnected;
  final PeerRpc primary = PeerRpc();
  final _lanes = <_SenderLane>[];
  int _primaryOutstanding = 0;
  bool _closed = false;

  bool get connected => primary.connected;
  LinkPath? get path => primary.link?.path;

  Future<void> _connectPrimary() async {
    final link = await TcpLink.dial(host, port);
    primary.attach(link);
    await onConnected?.call(primary);
  }

  /// Reconnects the primary link if it dropped. The engine's reconnect loop calls [ping],
  /// so a Wi-Fi blip heals by itself once the other device is reachable again.
  Future<void> _ensurePrimary() async {
    if (_closed) throw TransportException(ErrorCode.cancelled);
    if (primary.connected) return;
    try {
      await _connectPrimary();
    } on SocketException catch (e) {
      throw TransportException(ErrorCode.network, e.message);
    }
  }

  @override
  Future<CreateResult> create(Manifest manifest) async {
    await _ensurePrimary();
    return primary.create(manifest);
  }

  @override
  Future<TransferStatus> status(String transferId) async {
    await _ensurePrimary();
    return primary.status(transferId);
  }

  @override
  Future<void> ping() async {
    await _ensurePrimary();
    await primary.ping();
  }

  @override
  Future<String> complete(String transferId, String fileId, String root) => primary.complete(transferId, fileId, root);

  @override
  Future<void> cancel(String transferId) => primary.cancel(transferId);

  @override
  Future<ReceiverLoad> putBlocks(String transferId, String fileId, int startBlock, Uint8List body, Uint8List digests, CancelToken cancel) =>
      _route(body.length, () => primary.putBlocks(transferId, fileId, startBlock, body, digests, cancel),
          (lane) => lane.call(_LaneOp(0, 'blocks', transferId, fileId, startBlock, TransferableTypedData.fromList([body]), digests), cancel));

  @override
  Future<ReceiverLoad> putBatch(String transferId, Uint8List frame, CancelToken cancel) => _route(frame.length,
      () => primary.putBatch(transferId, frame, cancel),
      (lane) => lane.call(_LaneOp(0, 'batch', transferId, '', 0, TransferableTypedData.fromList([frame]), null), cancel));

  /// Least outstanding bytes wins; ties go to the primary (no cross-isolate copy).
  Future<ReceiverLoad> _route(int bytes, Future<ReceiverLoad> Function() onPrimary, Future<ReceiverLoad> Function(_SenderLane) onLane) async {
    _SenderLane? best;
    var bestLoad = _primaryOutstanding;
    for (final l in _lanes) {
      if (l.outstanding < bestLoad) {
        best = l;
        bestLoad = l.outstanding;
      }
    }
    if (best == null) {
      _primaryOutstanding += bytes;
      try {
        return await onPrimary();
      } finally {
        _primaryOutstanding -= bytes;
      }
    }
    final lane = best;
    lane.outstanding += bytes;
    try {
      return await onLane(lane);
    } finally {
      lane.outstanding -= bytes;
    }
  }

  Future<void> close() async {
    _closed = true;
    for (final l in _lanes) {
      l.close();
    }
    _lanes.clear();
    await primary.link?.close();
  }
}

class _LaneOp {
  const _LaneOp(this.id, this.kind, this.transferId, this.fileId, this.start, this.body, this.digests);
  final int id;
  final String kind;
  final String transferId;
  final String fileId;
  final int start;
  final TransferableTypedData body;
  final Uint8List? digests;

  _LaneOp withId(int id) => _LaneOp(id, kind, transferId, fileId, start, body, digests);
}

class _SenderLane {
  _SenderLane._(this._isolate, this._commands, this._replies) {
    _replies.listen((m) {
      final (id, ok, value) = m as (int, bool, Object?);
      final c = _pending.remove(id);
      if (c == null) return;
      if (ok) {
        c.complete(ReceiverLoad((value as num?)?.toDouble() ?? 0));
      } else {
        c.completeError(TransportException(ErrorCode.fromWire(value as String?)));
      }
    });
  }

  static Future<_SenderLane> spawn(String host, int port) async {
    final replies = ReceivePort();
    final ready = Completer<SendPort>();
    final sub = replies.listen((m) {
      if (m is SendPort && !ready.isCompleted) ready.complete(m);
    });
    final iso = await Isolate.spawn(_senderLaneMain, (replies.sendPort, host, port), debugName: 'swiftdrop-lane');
    final commands = await ready.future;
    await sub.cancel();
    final again = ReceivePort();
    commands.send(again.sendPort);
    replies.close();
    return _SenderLane._(iso, commands, again);
  }

  final Isolate _isolate;
  final SendPort _commands;
  final ReceivePort _replies;
  final _pending = <int, Completer<ReceiverLoad>>{};
  int _next = 1;
  int outstanding = 0;

  Future<ReceiverLoad> call(_LaneOp op, CancelToken cancel) {
    final id = _next++;
    final c = Completer<ReceiverLoad>();
    _pending[id] = c;
    c.future.ignore();
    _commands.send(op.withId(id));
    cancel.whenCancelled.then((_) {
      if (_pending.containsKey(id)) {
        _commands.send(('abort', id));
        _pending.remove(id)?.completeError(TransportException(ErrorCode.cancelled));
      }
    });
    return c.future;
  }

  void close() {
    _commands.send('close');
    for (final c in _pending.values) {
      c.completeError(TransportException(ErrorCode.network, 'lane closed'));
    }
    _pending.clear();
    _replies.close();
    _isolate.kill(priority: Isolate.beforeNextEvent);
  }
}

Future<void> _senderLaneMain((SendPort, String, int) args) async {
  final (first, host, port) = args;
  final inbox = ReceivePort();
  first.send(inbox.sendPort);
  SendPort? out;
  PeerRpc? rpc;
  Future<PeerRpc>? dialing;
  final cancels = <int, CancelToken>{};

  Future<PeerRpc> ensure() {
    final r = rpc;
    if (r != null && r.connected) return Future.value(r);
    return dialing ??= () async {
      try {
        final link = await TcpLink.dial(host, port);
        return rpc = PeerRpc(link);
      } finally {
        dialing = null;
      }
    }();
  }

  await for (final m in inbox) {
    if (m is SendPort) {
      out = m;
      continue;
    }
    if (m == 'close') {
      await rpc?.link?.close();
      inbox.close();
      break;
    }
    if (m is (String, int)) {
      cancels.remove(m.$2)?.cancel();
      continue;
    }
    final op = m as _LaneOp;
    final token = CancelToken();
    cancels[op.id] = token;
    () async {
      try {
        final r = await ensure();
        final body = op.body.materialize().asUint8List();
        final load = op.kind == 'blocks'
            ? await r.putBlocks(op.transferId, op.fileId, op.start, body, op.digests!, token)
            : await r.putBatch(op.transferId, body, token);
        out?.send((op.id, true, load.value));
      } on TransportException catch (e) {
        out?.send((op.id, false, e.code.wire));
      } on SocketException {
        out?.send((op.id, false, ErrorCode.network.wire));
      } catch (e) {
        out?.send((op.id, false, ErrorCode.server.wire));
      } finally {
        cancels.remove(op.id);
      }
    }();
  }
}

// ---------------------------------------------------------------------------
// Receiver

/// Handles one protocol request (coordinator side). `peer` is what the connection's
/// hello said, when it said anything.
typedef RequestHandler = Future<Object?> Function(String op, Object? args, Uint8List body, ConnectionInfo connection);

/// What the receiver knows about one incoming connection.
class ConnectionInfo {
  ConnectionInfo(this.id, this.remoteAddress);
  final int id;
  final String remoteAddress;

  /// From the connection's `hello` notice, if any.
  Map<String, Object?>? hello;
}

class LaneReceiver {
  LaneReceiver._(this._server, this.port, this.onRequest, this.onNotice, this.onClosed);

  /// Binds [port] (0 = any) on [address] and serves it from this isolate plus
  /// [lanes] - 1 lane isolates sharing the socket.
  static Future<LaneReceiver> start({
    required RequestHandler onRequest,
    void Function(ConnectionInfo c, String kind, Object? args)? onNotice,
    void Function(ConnectionInfo c)? onClosed,
    int port = 0,
    Object? address,
    int lanes = 4,
  }) async {
    final addr = address ?? InternetAddress.anyIPv4;
    final server = await ServerSocket.bind(addr, port, shared: true);
    final r = LaneReceiver._(server, server.port, onRequest, onNotice, onClosed);
    server.listen((s) => r._serveLocal(TcpLink.accepted(s)));
    for (var i = 1; i < lanes; i++) {
      await r._spawnLane(addr is InternetAddress ? addr.address : '$addr', server.port);
    }
    return r;
  }

  final ServerSocket _server;
  final int port;
  final RequestHandler onRequest;
  final void Function(ConnectionInfo c, String kind, Object? args)? onNotice;
  final void Function(ConnectionInfo c)? onClosed;
  final _connections = <int, ConnectionInfo>{};
  final _isolates = <Isolate>[];
  final _lanePorts = <SendPort>[];
  final _inbox = ReceivePort();
  StreamSubscription<Object?>? _inboxSub;
  int _nextConn = 1;

  Iterable<ConnectionInfo> get connections => _connections.values;

  void _serveLocal(TcpLink link) {
    final c = ConnectionInfo(_nextConn++, link.path.remoteAddress ?? '');
    _connections[c.id] = c;
    _pumpConnection(
      link,
      handle: (op, args, body) => onRequest(op, args, body, c),
      notice: (kind, args) {
        if (kind == 'hello' && args is Map<String, Object?>) c.hello = args;
        onNotice?.call(c, kind, args);
      },
    );
    link.closed.then((_) {
      _connections.remove(c.id);
      onClosed?.call(c);
    });
  }

  Future<void> _spawnLane(String address, int port) async {
    _inboxSub ??= _inbox.listen(_onLaneMessage);
    final iso = await Isolate.spawn(_receiverLaneMain, (_inbox.sendPort, address, port, _lanePorts.length), debugName: 'swiftdrop-recv-lane');
    _isolates.add(iso);
    // The lane announces its command port first.
    _lanePorts.add(await _laneReady.stream.first);
  }

  final _laneReady = StreamController<SendPort>.broadcast();

  void _onLaneMessage(Object? m) {
    if (m is SendPort) {
      _laneReady.add(m);
      return;
    }
    final msg = m as List<Object?>;
    final lane = msg[1] as int;
    final connKey = (msg[2] as int) * 1000 + lane + 1000000; // unique across lanes
    switch (msg[0]) {
      case 'open':
        _connections[connKey] = ConnectionInfo(connKey, msg[3] as String);
      case 'note':
        final c = _connections[connKey];
        if (c == null) return;
        if (msg[3] == 'hello' && msg[4] is Map) c.hello = (msg[4] as Map).cast<String, Object?>();
        onNotice?.call(c, msg[3] as String, msg[4]);
      case 'closed':
        final c = _connections.remove(connKey);
        if (c != null) onClosed?.call(c);
      case 'req':
        final c = _connections[connKey] ?? ConnectionInfo(connKey, '');
        final reqId = msg[3] as int;
        final body = msg[6] is TransferableTypedData ? (msg[6] as TransferableTypedData).materialize().asUint8List() : Uint8List(0);
        onRequest(msg[4] as String, msg[5], body, c).then(
          (result) => _lanePorts[lane].send(['res', msg[2], reqId, true, result]),
          onError: (Object e) => _lanePorts[lane].send(['res', msg[2], reqId, false, e is ProtocolException ? e.code.wire : 'SERVER']),
        );
    }
  }

  Future<void> close() async {
    await _server.close();
    for (final p in _lanePorts) {
      p.send(['close']);
    }
    for (final i in _isolates) {
      i.kill(priority: Isolate.beforeNextEvent);
    }
    await _inboxSub?.cancel();
    _inbox.close();
  }
}

/// Reassembles request bodies on one connection and hands complete requests to [handle].
/// Same limits as the single-connection receiver.
void _pumpConnection(
  Link link, {
  required Future<Object?> Function(String op, Object? args, Uint8List body) handle,
  required void Function(String kind, Object? args) notice,
}) {
  final bodies = <int, ({RequestMessage req, Uint8List buf, int got})>{};
  final aborted = <int>{};
  var reassembling = 0;
  const maxBody = maxBlocksPerChunk * blockSize + (2 << 20);
  const maxReassembly = 96 << 20;

  void respond(int id, Future<Object?> work) {
    work.then((result) {
      if (!aborted.contains(id) && link.isOpen) link.sendControl(ResponseMessage.ok(id, result)).ignore();
    }, onError: (Object err) {
      final code = err is ProtocolException ? err.code.wire : (err is String ? err : 'SERVER');
      if (!aborted.contains(id) && link.isOpen) link.sendControl(ResponseMessage.error(id, code)).ignore();
    });
  }

  final cs = link.control.listen((m) {
    switch (m) {
      case AbortMessage(:final id):
        aborted.add(id);
        final b = bodies.remove(id);
        if (b != null) reassembling -= b.buf.length;
      case NoticeMessage(:final kind, :final args):
        notice(kind, args);
      case RequestMessage(:final id, :final op, :final args, :final bodyLength):
        final len = bodyLength ?? 0;
        if (len > 0) {
          if (len > maxBody || reassembling + len > maxReassembly) {
            link.sendControl(ResponseMessage.error(id, ErrorCode.tooLarge.wire)).ignore();
            aborted.add(id);
            return;
          }
          reassembling += len;
          bodies[id] = (req: m, buf: Uint8List(len), got: 0);
          return;
        }
        respond(id, handle(op, args, Uint8List(0)));
      default:
        break;
    }
  });
  final ds = link.data.listen((f) {
    final b = bodies[f.requestId];
    if (b == null) return;
    if (f.offset + f.bytes.length > b.buf.length) {
      bodies.remove(f.requestId);
      reassembling -= b.buf.length;
      link.sendControl(ResponseMessage.error(f.requestId, ErrorCode.badFrame.wire)).ignore();
      return;
    }
    b.buf.setRange(f.offset, f.offset + f.bytes.length, f.bytes);
    final got = b.got + f.bytes.length;
    if (got < b.buf.length) {
      bodies[f.requestId] = (req: b.req, buf: b.buf, got: got);
      return;
    }
    bodies.remove(f.requestId);
    reassembling -= b.buf.length;
    respond(f.requestId, handle(b.req.op, b.req.args, b.buf));
  });
  link.closed.then((_) {
    cs.cancel();
    ds.cancel();
    bodies.clear();
  });
}

Future<void> _receiverLaneMain((SendPort, String, int, int) args) async {
  final (coordinator, address, port, lane) = args;
  final inbox = ReceivePort();
  coordinator.send(inbox.sendPort);
  final server = await ServerSocket.bind(address, port, shared: true);
  final pending = <(int, int), Completer<Object?>>{};
  var nextConn = 1;
  server.listen((s) {
    final link = TcpLink.accepted(s);
    final conn = nextConn++;
    var nextReq = 1;
    coordinator.send(['open', lane, conn, link.path.remoteAddress ?? '']);
    _pumpConnection(
      link,
      handle: (op, args, body) {
        final id = nextReq++;
        final c = Completer<Object?>();
        pending[(conn, id)] = c;
        coordinator.send(['req', lane, conn, id, op, args, if (body.isEmpty) null else TransferableTypedData.fromList([body])]);
        return c.future;
      },
      notice: (kind, a) => coordinator.send(['note', lane, conn, kind, a]),
    );
    link.closed.then((_) => coordinator.send(['closed', lane, conn]));
  });
  await for (final m in inbox) {
    final msg = m as List<Object?>;
    if (msg[0] == 'close') {
      await server.close();
      inbox.close();
      break;
    }
    // ['res', conn, id, ok, result|code]
    final c = pending.remove((msg[1] as int, msg[2] as int));
    if (c == null) continue;
    if (msg[3] == true) {
      c.complete(msg[4]);
    } else {
      c.completeError(msg[4] as String);
    }
  }
}
