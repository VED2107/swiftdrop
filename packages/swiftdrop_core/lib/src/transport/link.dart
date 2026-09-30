import 'dart:typed_data';

/// The byte link between two devices: TCP+TLS on a LAN, a WebRTC DataChannel, or an
/// in-memory pair in tests. Dart counterpart of `PhoneTransport` in
/// `packages/peer/src/channel.ts`. It knows nothing about files, manifests or the engine.
///
/// Wire frames (identical meaning on every link):
///   0x01 | UTF-8 JSON                      control
///   0x02 | u32 reqId | u32 offset | bytes  body bytes of request `reqId` at `offset`
/// Stream links (TCP) prefix each frame with a u32 length; message links don't need to.
abstract interface class Link {
  /// Completes once frames can flow.
  Future<void> connect();

  /// Small JSON messages. Never queued behind data frames.
  Future<void> sendControl(ControlMessage message);

  /// Body bytes of a request. Completes only when the link has room (backpressure):
  /// callers can never queue unboundedly.
  Future<void> sendChunk(int requestId, int offset, Uint8List bytes);

  Stream<ControlMessage> get control;
  Stream<DataFrame> get data;

  /// Largest body slice one data frame carries.
  int get maxFrameBytes;
  bool get isOpen;

  /// Completes when the link closes, for any reason.
  Future<void> get closed;

  /// What the connection is proven to be. Drives the "Direct · Local network" badge.
  LinkPath get path;

  Future<void> close();
}

class DataFrame {
  const DataFrame(this.requestId, this.offset, this.bytes);
  final int requestId;
  final int offset;
  final Uint8List bytes;
}

/// Control messages: request/response RPC plus fire-and-forget notifications.
sealed class ControlMessage {
  const ControlMessage();
}

final class RequestMessage extends ControlMessage {
  const RequestMessage({required this.id, required this.op, this.args, this.bodyLength});
  final int id;
  final String op;
  final Object? args;

  /// Bytes of body that follow as data frames, when the request carries data.
  final int? bodyLength;
}

final class ResponseMessage extends ControlMessage {
  const ResponseMessage.ok(this.id, [this.result]) : errorCode = null;
  const ResponseMessage.error(this.id, String this.errorCode) : result = null;
  final int id;
  final Object? result;

  /// Wire error code when the request failed.
  final String? errorCode;
  bool get ok => errorCode == null;
}

final class AbortMessage extends ControlMessage {
  const AbortMessage(this.id);
  final int id;
}

/// Protocol v1.1 notifications (`hello`, `done`, `pause`). Old peers ignore them.
final class NoticeMessage extends ControlMessage {
  const NoticeMessage(this.kind, [this.args]);
  final String kind;
  final Object? args;
}

enum PathKind {
  /// Not relayed, and both endpoints are private, link-local or mDNS addresses.
  local,

  /// Not relayed, but the addresses don't prove a shared network.
  p2p,

  /// Through a relay. SwiftDrop configures none; shown for completeness.
  relayed,
  unknown,
}

enum LinkKind { tcp, webrtc, http, memory }

class LinkPath {
  const LinkPath({required this.kind, required this.link, this.localAddress, this.remoteAddress, this.rtt});
  static const unknown = LinkPath(kind: PathKind.unknown, link: LinkKind.memory);

  final PathKind kind;
  final LinkKind link;
  final String? localAddress;
  final String? remoteAddress;
  final Duration? rtt;
}
