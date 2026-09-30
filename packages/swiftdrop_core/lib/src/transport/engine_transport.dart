import 'dart:async';
import 'dart:typed_data';

import '../protocol/errors.dart';
import '../protocol/types.dart';

/// What the transfer engine needs from the network. Dart counterpart of `Transport` in
/// `packages/transfer-engine/src/transport.ts`.
///
/// Implementations (Phase 3+):
///  - `PeerRpc`: this interface as RPC over any [Link] (TCP, WebRTC, memory)
///  - `HttpTransport`: against the existing Node server on a PC
abstract interface class EngineTransport {
  /// Sends the manifest. For a peer, completes after the person there taps Accept.
  Future<CreateResult> create(Manifest manifest);

  /// Receiver's per-file state and bitmaps: the basis of every resume.
  Future<TransferStatus> status(String transferId);

  /// 1..16 contiguous blocks starting at [startBlock], with their concatenated digests.
  Future<ReceiverLoad> putBlocks(
    String transferId,
    String fileId,
    int startBlock,
    Uint8List body,
    Uint8List digests,
    CancelToken cancel,
  );

  /// A batch frame of small files: `[u32 LE headerLen][JSON header][bytes…]`.
  Future<ReceiverLoad> putBatch(String transferId, Uint8List frame, CancelToken cancel);

  /// Per-file root digest. Returns the name the receiver stored the file under.
  Future<String> complete(String transferId, String fileId, String root);

  Future<void> cancel(String transferId);

  /// Reachability probe used by the reconnect loop.
  Future<void> ping();
}

/// Receiver disk pressure 0..1, a backpressure hint for the controller.
extension type const ReceiverLoad(double value) {}

class TransportException implements Exception {
  TransportException(this.code, [this.detail]);
  final ErrorCode code;
  final String? detail;
  String get userMessage => userMessages[code]!;

  @override
  String toString() => 'TransportException(${code.wire}${detail == null ? '' : ': $detail'})';
}

/// Cooperative cancellation for one in-flight request.
class CancelToken {
  final _completer = Completer<void>();
  bool get isCancelled => _completer.isCompleted;
  Future<void> get whenCancelled => _completer.future;
  void cancel() {
    if (!_completer.isCompleted) _completer.complete();
  }
}
