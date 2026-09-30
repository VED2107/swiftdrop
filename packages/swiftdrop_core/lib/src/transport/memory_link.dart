import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'frames.dart';
import 'link.dart';

/// Two connected in-memory [Link]s for tests. Frames are delivered asynchronously in
/// order, with a bounded "wire": each side has [bytesPerTick] of capacity per event-loop
/// turn, so backpressure really engages. [dropBoth] simulates a network drop; [tamper]
/// lets a test corrupt data frames in flight.
class MemoryLink implements Link {
  MemoryLink._(this._highWater, this._bytesPerTick, this.maxFrameBytes);

  static (MemoryLink, MemoryLink) pair({int highWater = 1 << 20, int bytesPerTick = 256 << 10, int maxFrameBytes = 64 << 10}) {
    final a = MemoryLink._(highWater, bytesPerTick, maxFrameBytes);
    final b = MemoryLink._(highWater, bytesPerTick, maxFrameBytes);
    a._peer = b;
    b._peer = a;
    return (a, b);
  }

  late MemoryLink _peer;
  final int _highWater;
  final int _bytesPerTick;
  @override
  final int maxFrameBytes;

  final _queue = ListQueue<Uint8List>();
  int _buffered = 0;
  bool _draining = false;
  bool _closed = false;
  final _drainWaiters = <Completer<void>>[];
  final _control = StreamController<ControlMessage>.broadcast(sync: true);
  final _data = StreamController<DataFrame>.broadcast(sync: true);
  final _closedC = Completer<void>();

  /// Highest buffered byte count seen after a send: proves backpressure holds.
  int peakBuffered = 0;

  /// Test hook: may replace a data frame's bytes before delivery.
  Uint8List Function(DataFrame f)? tamper;

  int get buffered => _buffered;

  @override
  Future<void> connect() async {
    if (_closed) throw StateError('link closed');
  }

  @override
  bool get isOpen => !_closed;

  @override
  Future<void> get closed => _closedC.future;

  @override
  Stream<ControlMessage> get control => _control.stream;

  @override
  Stream<DataFrame> get data => _data.stream;

  @override
  LinkPath get path => const LinkPath(kind: PathKind.local, link: LinkKind.memory);

  @override
  Future<void> sendControl(ControlMessage message) async => _push(encodeControl(message));

  @override
  Future<void> sendChunk(int requestId, int offset, Uint8List bytes) async {
    for (var at = 0; at < bytes.length; at += maxFrameBytes) {
      final end = at + maxFrameBytes < bytes.length ? at + maxFrameBytes : bytes.length;
      final size = dataHeaderBytes + end - at;
      while (_buffered + size > _highWater && _buffered > 0) {
        final w = Completer<void>();
        _drainWaiters.add(w);
        await w.future;
        if (_closed) throw StateError('link closed');
      }
      final frame = Uint8List(size)
        ..setRange(0, dataHeaderBytes, encodeDataHeader(requestId, offset + at))
        ..setRange(dataHeaderBytes, size, bytes, at);
      _push(frame);
    }
  }

  void _push(Uint8List frame) {
    if (_closed) throw StateError('link closed');
    _queue.add(frame);
    _buffered += frame.length;
    if (_buffered > peakBuffered) peakBuffered = _buffered;
    if (!_draining) {
      _draining = true;
      Timer.run(_drain);
    }
  }

  void _drain() {
    var budget = _bytesPerTick;
    while (_queue.isNotEmpty && budget > 0 && !_closed) {
      final frame = _queue.removeFirst();
      _buffered -= frame.length;
      budget -= frame.length;
      _peer._deliver(frame, tamper);
    }
    if (_buffered <= _highWater ~/ 4) {
      for (final w in _drainWaiters) {
        w.complete();
      }
      _drainWaiters.clear();
    }
    if (_queue.isNotEmpty && !_closed) {
      Timer.run(_drain);
    } else {
      _draining = false;
    }
  }

  void _deliver(Uint8List frame, Uint8List Function(DataFrame f)? tamper) {
    if (_closed) return;
    final decoded = decodeFrame(frame);
    if (decoded is ControlMessage) {
      _control.add(decoded);
    } else if (decoded is DataFrame) {
      _data.add(tamper == null ? decoded : DataFrame(decoded.requestId, decoded.offset, tamper(decoded)));
    }
  }

  @override
  Future<void> close() async => _shutdown();

  /// Both ends go down at once, like a Wi-Fi drop.
  void dropBoth() {
    _shutdown();
    _peer._shutdown();
  }

  void _shutdown() {
    if (_closed) return;
    _closed = true;
    _queue.clear();
    _buffered = 0;
    for (final w in _drainWaiters) {
      w.complete();
    }
    _drainWaiters.clear();
    _closedC.complete();
    _control.close();
    _data.close();
    if (!_peer._closed) _peer._shutdown();
  }
}
