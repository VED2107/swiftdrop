import 'dart:async';
import 'dart:typed_data';

import '../protocol/errors.dart';
import '../protocol/types.dart';
import '../util/base64url.dart';
import 'engine_transport.dart';
import 'link.dart';

/// The engine's [EngineTransport] over a device-to-device [Link]. Port of
/// `packages/peer/src/peer-transport.ts`: every call is one RPC (control request, body as
/// data frames on the same ordered link, then the receiver's response); the engine's
/// parallel streams become pipelined requests.
///
/// The link can be swapped with [attach] after a drop: pending calls fail with NETWORK,
/// the engine pings until a new link is attached, asks for status and sends what's missing.
class PeerRpc implements EngineTransport {
  PeerRpc([Link? link]) {
    if (link != null) attach(link);
  }

  Link? _link;
  int _nextId = 1;
  final _pending = <int, Completer<Object?>>{};
  StreamSubscription<ControlMessage>? _sub;

  bool get connected => _link?.isOpen ?? false;
  Link? get link => _link;

  void attach(Link link) {
    _sub?.cancel();
    _link = link;
    _sub = link.control.listen(_onControl);
    link.closed.then((_) {
      if (!identical(_link, link)) return;
      _link = null;
      _failAll();
    });
  }

  @override
  Future<CreateResult> create(Manifest manifest) async {
    // No timeout: waits for a person on the other device to tap Accept.
    final r = await _call('create', manifest.toJson()) as Map<String, Object?>;
    if (r['conflicts'] is List) {
      return Conflicts([for (final c in r['conflicts'] as List) Conflict.fromJson(c as Map<String, Object?>)]);
    }
    return Created(TransferStatus.fromJson(r['status'] as Map<String, Object?>));
  }

  @override
  Future<TransferStatus> status(String transferId) async =>
      TransferStatus.fromJson(await _call('status', {'transferId': transferId}, timeout: const Duration(seconds: 15)) as Map<String, Object?>);

  @override
  Future<ReceiverLoad> putBlocks(String transferId, String fileId, int startBlock, Uint8List body, Uint8List digests, CancelToken cancel) async {
    final r = await _call('blocks', {'transferId': transferId, 'fileId': fileId, 'start': startBlock, 'hashes': bytesToBase64Url(digests)},
        body: body, cancel: cancel);
    return ReceiverLoad(((r as Map?)?['load'] as num?)?.toDouble() ?? 0);
  }

  @override
  Future<ReceiverLoad> putBatch(String transferId, Uint8List frame, CancelToken cancel) async {
    final r = await _call('batch', {'transferId': transferId}, body: frame, cancel: cancel);
    return ReceiverLoad(((r as Map?)?['load'] as num?)?.toDouble() ?? 0);
  }

  @override
  Future<String> complete(String transferId, String fileId, String root) async {
    final r = await _call('complete', {'transferId': transferId, 'fileId': fileId, 'root': root}) as Map<String, Object?>;
    return r['finalName'] as String;
  }

  @override
  Future<void> cancel(String transferId) => _call('cancel', {'transferId': transferId}, timeout: const Duration(seconds: 5));

  @override
  Future<void> ping() => _call('ping', const <String, Object?>{}, timeout: const Duration(seconds: 5));

  /// A request outside the engine's vocabulary (v1.1 `hello`). Old peers answer
  /// BAD_REQUEST, which callers treat as "no identity offered".
  Future<Object?> request(String op, Object? args, {Duration timeout = const Duration(seconds: 10)}) =>
      _call(op, args, timeout: timeout);

  /// Fire-and-forget notice (hello, done, pause).
  Future<void> notify(String kind, [Object? args]) async {
    final link = _link;
    if (link == null || !link.isOpen) return;
    await link.sendControl(NoticeMessage(kind, args));
  }

  // ---------------------------------------------------------------------------

  Future<Object?> _call(String op, Object? args, {Uint8List? body, CancelToken? cancel, Duration? timeout}) async {
    final link = _link;
    if (link == null || !link.isOpen) throw TransportException(ErrorCode.network, 'not connected');
    if (cancel?.isCancelled ?? false) throw TransportException(ErrorCode.cancelled);
    final id = _nextId++;
    final done = Completer<Object?>();
    _pending[id] = done;
    // The response (or a failure) can arrive while the body is still being sent, before
    // anything awaits it; mark it handled now so it never surfaces as an uncaught error.
    done.future.ignore();
    Timer? timer;
    if (timeout != null) timer = Timer(timeout, () => _settle(id, TransportException(ErrorCode.network, '$op timed out')));
    cancel?.whenCancelled.then((_) {
      if (!_pending.containsKey(id)) return;
      link.sendControl(AbortMessage(id)).ignore();
      _settle(id, TransportException(ErrorCode.cancelled));
    });
    try {
      await link.sendControl(RequestMessage(id: id, op: op, args: args, bodyLength: body?.length));
      if (body != null && body.isNotEmpty) await link.sendChunk(id, 0, body);
    } catch (_) {
      _settle(id, TransportException(ErrorCode.network, 'link closed while sending'));
    }
    try {
      return await done.future;
    } finally {
      timer?.cancel();
    }
  }

  void _onControl(ControlMessage m) {
    if (m is! ResponseMessage) return;
    final p = _pending.remove(m.id);
    if (p == null) return;
    if (m.ok) {
      p.complete(m.result);
    } else {
      p.completeError(TransportException(ErrorCode.fromWire(m.errorCode)));
    }
  }

  void _settle(int id, Object err) {
    final p = _pending.remove(id);
    if (p != null && !p.isCompleted) p.completeError(err);
  }

  void _failAll() {
    for (final id in _pending.keys.toList()) {
      _settle(id, TransportException(ErrorCode.network, 'link closed'));
    }
  }
}
