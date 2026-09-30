import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'frames.dart';
import 'link.dart';
import 'path.dart';

/// Native LAN link: kernel TCP through `dart:io` [Socket]. Each peer frame (control or
/// data, see frames.dart) travels as `u32 BE length | frame`. Data frames carry up to
/// [maxFrameBytes] (1 MiB: no 64 KiB SCTP limit here).
///
/// Why [Socket] and not RawSocket: measured on Windows loopback (tool/tcp_variants.dart,
/// AOT), a RawSocket write loop tops out at ~209 MB/s while Socket's IOSink moves ~887 MB/s.
///
/// Backpressure: writes are serialised through one chain; after every [flushEvery] bytes
/// the chain awaits `flush()`, so at most about that much is buffered in the socket and
/// [sendChunk] callers wait instead of queueing unboundedly. Payloads are added straight
/// from the caller's buffer. Control frames join the same ordered chain.
///
/// Phase 3: plain TCP, no TLS or peer authentication yet (docs/FLUTTER_MIGRATION.md §15).

/// Upper bound for any single frame on the wire (a 100,000-file manifest fits).
const maxControlFrameBytes = 32 << 20;

class TcpLink implements Link {
  TcpLink._(this._socket) {
    _socket.setOption(SocketOption.tcpNoDelay, true);
    _sub = _socket.listen(_onData, onError: (Object _) => _shutdown(), onDone: _shutdown, cancelOnError: true);
    _socket.done.then((_) => _shutdown(), onError: (Object _) => _shutdown());
    _path = LinkPath(
      kind: classifyAddresses(_socket.address.address, _socket.remoteAddress.address),
      link: LinkKind.tcp,
      localAddress: _socket.address.address,
      remoteAddress: _socket.remoteAddress.address,
    );
  }

  /// Connects to a listening device.
  static Future<TcpLink> dial(String host, int port, {Duration timeout = const Duration(seconds: 5)}) async =>
      TcpLink._(await Socket.connect(host, port, timeout: timeout));

  /// Wraps an accepted connection (see [TcpListener]).
  factory TcpLink.accepted(Socket socket) => TcpLink._(socket);

  final Socket _socket;
  late final StreamSubscription<Uint8List> _sub;

  /// Safety valve: wait for the socket to drain after this many unflushed bytes. Normal
  /// flow control is the engine's in-flight budget (every queued byte belongs to a request
  /// it counts), so this rarely triggers. Measured: flushing every 4 MiB drained the pipe
  /// to empty each time and capped a 16 MiB-request pipeline near 300 MB/s.
  final int flushEvery = 64 << 20;
  @override
  final int maxFrameBytes = 1 << 20;
  late final LinkPath _path;

  Future<void> _chain = Future.value();
  int _unflushed = 0;
  bool _closed = false;
  final _closedC = Completer<void>();
  final _control = StreamController<ControlMessage>.broadcast(sync: true);
  final _data = StreamController<DataFrame>.broadcast(sync: true);

  // incoming: 4-byte length + 1-byte type (+ 8-byte data header), then the body
  final _head = Uint8List(dataHeaderBytes + 4);
  int _headGot = 0;
  int _frameLen = 0;
  Uint8List? _controlBuf;
  int _controlGot = 0;
  int _dataReq = 0;
  int _dataOffset = 0;
  int _dataLeft = 0;

  int bytesSent = 0;
  int bytesReceived = 0;

  @override
  Future<void> connect() async {
    if (_closed) throw const SocketException('link closed');
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
  LinkPath get path => _path;

  @override
  Future<void> sendControl(ControlMessage message) {
    final frame = encodeControl(message);
    return _write([_lengthPrefix(frame.length), frame]);
  }

  @override
  Future<void> sendChunk(int requestId, int offset, Uint8List bytes) {
    // The whole body in one write-chain step: frames of one request go out back to back.
    final parts = <Uint8List>[];
    for (var at = 0; at < bytes.length; at += maxFrameBytes) {
      final end = at + maxFrameBytes < bytes.length ? at + maxFrameBytes : bytes.length;
      parts
        ..add(_lengthPrefix(dataHeaderBytes + end - at))
        ..add(encodeDataHeader(requestId, offset + at))
        ..add(Uint8List.sublistView(bytes, at, end));
    }
    return _write(parts);
  }

  /// Appends to the ordered write chain; completes once the bytes are handed to the socket
  /// (and, every [flushEvery] bytes, once the socket has drained them).
  Future<void> _write(List<Uint8List> parts) {
    if (_closed) return Future.error(const SocketException('link closed'));
    final op = _chain.then((_) async {
      if (_closed) throw const SocketException('link closed');
      for (final part in parts) {
        _socket.add(part);
        _unflushed += part.length;
        bytesSent += part.length;
      }
      if (_unflushed >= flushEvery) {
        _unflushed = 0;
        await _socket.flush();
      }
    });
    _chain = op.catchError((Object _) {});
    return op;
  }

  static Uint8List _lengthPrefix(int n) {
    final b = Uint8List(4);
    ByteData.sublistView(b).setUint32(0, n);
    return b;
  }

  /// Streaming frame reader. Control frames are gathered into one small buffer; data
  /// payloads are forwarded as views of the socket's own chunks (a frame split across
  /// chunks arrives as several [DataFrame]s with increasing offsets), so the link copies
  /// nothing: the receiver copies each piece once, straight into the request body.
  /// Listeners must consume [DataFrame.bytes] synchronously (the receiver does).
  /// Measured: a queue-and-copy reader capped at ~250 MB/s; see docs/BENCHMARKS.md.
  void _onData(Uint8List chunk) {
    bytesReceived += chunk.length;
    var at = 0;
    while (at < chunk.length && !_closed) {
      if (_dataLeft > 0) {
        final n = chunk.length - at < _dataLeft ? chunk.length - at : _dataLeft;
        _data.add(DataFrame(_dataReq, _dataOffset, Uint8List.sublistView(chunk, at, at + n)));
        _dataOffset += n;
        _dataLeft -= n;
        at += n;
        continue;
      }
      final ctrl = _controlBuf;
      if (ctrl != null) {
        final n = chunk.length - at < ctrl.length - _controlGot ? chunk.length - at : ctrl.length - _controlGot;
        ctrl.setRange(_controlGot, _controlGot + n, Uint8List.sublistView(chunk, at, at + n));
        _controlGot += n;
        at += n;
        if (_controlGot == ctrl.length) {
          _controlBuf = null;
          final decoded = decodeFrame(ctrl);
          if (decoded is ControlMessage) _control.add(decoded);
        }
        continue;
      }
      // Frame header: length (4) + type (1), and for data frames reqId + offset (8).
      final want = _headGot < 5 ? 5 : 4 + dataHeaderBytes;
      final n = chunk.length - at < want - _headGot ? chunk.length - at : want - _headGot;
      _head.setRange(_headGot, _headGot + n, Uint8List.sublistView(chunk, at, at + n));
      _headGot += n;
      at += n;
      if (_headGot < 5) continue;
      if (_headGot == 5) {
        _frameLen = ByteData.sublistView(_head).getUint32(0);
        // Manifests of very large folders are the biggest control frames (~150 B per file).
        if (_frameLen < 1 || _frameLen > maxControlFrameBytes) {
          _shutdown(); // not a SwiftDrop peer, or a corrupted stream
          return;
        }
        if (_head[4] == frameControl) {
          _headGot = 0;
          _controlBuf = Uint8List(_frameLen)..[0] = frameControl;
          _controlGot = 1;
          if (_frameLen == 1) _controlBuf = null;
          continue;
        }
        if (_head[4] != frameData || _frameLen < dataHeaderBytes) {
          _shutdown();
          return;
        }
        continue; // need the rest of the data header
      }
      if (_headGot < 4 + dataHeaderBytes) continue;
      final v = ByteData.sublistView(_head);
      _dataReq = v.getUint32(5);
      _dataOffset = v.getUint32(9);
      _dataLeft = _frameLen - dataHeaderBytes;
      _headGot = 0;
    }
  }

  @override
  Future<void> close() async {
    // Let queued frames (e.g. a final response) go out before closing.
    try {
      await _chain.timeout(const Duration(seconds: 2));
      await _socket.flush().timeout(const Duration(seconds: 2));
    } catch (_) {}
    _shutdown();
  }

  /// Hard drop without flushing (tests: simulated network failure).
  void kill() {
    _socket.destroy();
    _shutdown();
  }

  void _shutdown() {
    if (_closed) return;
    _closed = true;
    _sub.cancel();
    try {
      _socket.destroy();
    } catch (_) {}
    _closedC.complete();
    _control.close();
    _data.close();
  }
}

/// Accepts incoming device connections on a TCP port (0 = any free port).
class TcpListener {
  TcpListener._(this._server);

  static Future<TcpListener> bind({int port = 0, Object? address}) async =>
      TcpListener._(await ServerSocket.bind(address ?? InternetAddress.anyIPv4, port));

  final ServerSocket _server;
  int get port => _server.port;

  Stream<TcpLink> get links => _server.map(TcpLink.accepted);

  Future<void> close() => _server.close();
}
