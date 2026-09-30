import '../platform/system.dart';
import '../protocol/errors.dart';
import '../transport/link.dart';

/// Application-level models: what the app shows, independent of Flutter and of how the
/// engine works inside. Immutable; services emit fresh instances.

enum DeviceStatus {
  /// Seen on the network, not connected.
  available,
  connecting,
  connected,

  /// Known (paired before) but not seen right now.
  offline,
}

class Device {
  const Device({
    required this.id,
    required this.name,
    required this.kind,
    required this.platform,
    required this.status,
    this.path,
    this.trusted = false,
    this.lastUsed,
  });

  final String id;
  final String name;
  final DeviceKind kind;
  final DevicePlatform platform;
  final DeviceStatus status;

  /// Set while connected.
  final LinkPath? path;

  /// Paired before: reconnects authenticate by pinned certificate, no prompt.
  final bool trusted;
  final DateTime? lastUsed;

  Device copyWith({String? name, DeviceStatus? status, LinkPath? path, bool? trusted, DateTime? lastUsed}) => Device(
        id: id,
        name: name ?? this.name,
        kind: kind,
        platform: platform,
        status: status ?? this.status,
        path: path ?? this.path,
        trusted: trusted ?? this.trusted,
        lastUsed: lastUsed ?? this.lastUsed,
      );
}

enum TransferRole { sending, receiving }

enum TransferPhase {
  /// Manifest sent; the person on the other device hasn't answered.
  awaitingAcceptance,
  preparing,
  running,
  paused,

  /// Link dropped; progress is kept and the engine is trying to reconnect.
  reconnecting,
  complete,
  failed,
  cancelled,
  declined;

  bool get isFinished => this == complete || this == failed || this == cancelled || this == declined;
}

/// One transfer as the UI sees it. Published by the engine at a bounded rate (≤ 10 Hz),
/// never per chunk.
class TransferSnapshot {
  const TransferSnapshot({
    required this.transferId,
    required this.role,
    required this.peerId,
    required this.peerName,
    required this.peerKind,
    required this.phase,
    required this.bytesDone,
    required this.bytesTotal,
    required this.filesDone,
    required this.filesTotal,
    this.filesVerified = 0,
    this.speed = 0,
    this.etaSeconds,
    this.path,
    this.error,
    required this.startedAt,
  });

  final String transferId;
  final TransferRole role;
  final String peerId;
  final String peerName;
  final DeviceKind peerKind;
  final TransferPhase phase;
  final int bytesDone;
  final int bytesTotal;
  final int filesDone;
  final int filesTotal;

  /// Files whose root digest matched on the receiver.
  final int filesVerified;

  /// Measured bytes/s, 0 when unknown. Never estimated or invented.
  final double speed;
  final double? etaSeconds;
  final LinkPath? path;
  final ErrorCode? error;
  final DateTime startedAt;

  double get fraction => bytesTotal == 0 ? (phase == TransferPhase.complete ? 1 : 0) : bytesDone / bytesTotal;
  bool get verified => phase == TransferPhase.complete && filesVerified == filesTotal;
}

/// A transfer the person on this device has to accept or decline.
class IncomingOffer {
  const IncomingOffer({
    required this.transferId,
    required this.from,
    required this.fileCount,
    required this.totalBytes,
    required this.sampleNames,
    this.freeBytes,
  });

  final String transferId;
  final Device from;
  final int fileCount;
  final int totalBytes;

  /// First few names, for the sheet. Never file contents.
  final List<String> sampleNames;

  /// Free space where the files would land, when known.
  final int? freeBytes;
  bool get fits => freeBytes == null || freeBytes! >= totalBytes;
}

enum TransferOutcome { completed, failed, cancelled, declined }

/// History entry. Metadata only, never file contents.
class TransferRecord {
  const TransferRecord({
    required this.transferId,
    required this.role,
    required this.peerName,
    required this.peerKind,
    required this.fileCount,
    required this.totalBytes,
    required this.startedAt,
    required this.finishedAt,
    required this.outcome,
    required this.verified,
    this.averageSpeed,
    this.location,
  });

  final String transferId;
  final TransferRole role;
  final String peerName;
  final DeviceKind peerKind;
  final int fileCount;
  final int totalBytes;
  final DateTime startedAt;
  final DateTime finishedAt;
  final TransferOutcome outcome;
  final bool verified;

  /// Measured average, bytes/s.
  final double? averageSpeed;

  /// Where received files were saved (folder path or platform location), for "Show".
  final String? location;

  Duration get duration => finishedAt.difference(startedAt);
}
