import 'dart:async';
import 'dart:math' as math;

import '../platform/files.dart';
import '../platform/system.dart';
import '../transport/link.dart';
import '../services/models.dart';
import '../services/services.dart';

/// Scripted services for UI development and widget tests. Every number here is made up:
/// the app only uses these behind the `SWIFTDROP_DEMO` flag, never in a release build
/// (product rule: speeds on screen come from live measurement only).

const _local = LinkPath(kind: PathKind.local, link: LinkKind.tcp, localAddress: '192.168.1.20', remoteAddress: '192.168.1.31');

final demoDevices = <Device>[
  Device(
    id: 'demo-iphone',
    name: "Ved's iPhone",
    kind: DeviceKind.phone,
    platform: DevicePlatform.ios,
    status: DeviceStatus.connected,
    path: _local,
    trusted: true,
    lastUsed: DateTime(2026, 9, 30, 9, 12),
  ),
  const Device(
    id: 'demo-mac',
    name: 'MacBook Pro',
    kind: DeviceKind.laptop,
    platform: DevicePlatform.macos,
    status: DeviceStatus.available,
    trusted: true,
  ),
  const Device(
    id: 'demo-pixel',
    name: 'Pixel 9',
    kind: DeviceKind.phone,
    platform: DevicePlatform.android,
    status: DeviceStatus.available,
  ),
  Device(
    id: 'demo-pc',
    name: 'Windows PC',
    kind: DeviceKind.desktop,
    platform: DevicePlatform.windows,
    status: DeviceStatus.offline,
    trusted: true,
    lastUsed: DateTime(2026, 9, 28, 18, 40),
  ),
];

class DemoDeviceDirectory implements DeviceDirectory {
  DemoDeviceDirectory([List<Device>? devices]) : _devices = [...(devices ?? demoDevices)];
  final List<Device> _devices;
  final _out = StreamController<List<Device>>.broadcast();

  @override
  Stream<List<Device>> watch() async* {
    yield List.unmodifiable(_devices);
    yield* _out.stream;
  }

  @override
  Future<void> rename(String deviceId, String name) async {
    final i = _devices.indexWhere((d) => d.id == deviceId);
    if (i < 0) return;
    _devices[i] = _devices[i].copyWith(name: name);
    _out.add(List.unmodifiable(_devices));
  }

  @override
  Future<void> forget(String deviceId) async {
    _devices.removeWhere((d) => d.id == deviceId);
    _out.add(List.unmodifiable(_devices));
  }
}

/// One scripted transfer that loops: sending 24 files / 1.8 GB to "Ved's iPhone".
class DemoTransferService implements TransferService {
  DemoTransferService({this.tick = const Duration(milliseconds: 100), this.autoStart = true}) {
    if (autoStart) _start('demo-transfer-1');
  }

  final Duration tick;
  final bool autoStart;
  final _out = StreamController<List<TransferSnapshot>>.broadcast();
  final _offers = StreamController<List<IncomingOffer>>.broadcast();
  final Map<String, TransferSnapshot> _transfers = {};
  Timer? _timer;
  int _n = 0;

  static const _total = 1800 * 1000 * 1000;

  void _start(String id) {
    _transfers[id] = TransferSnapshot(
      transferId: id,
      role: TransferRole.sending,
      peerId: 'demo-iphone',
      peerName: "Ved's iPhone",
      peerKind: DeviceKind.phone,
      phase: TransferPhase.running,
      bytesDone: 0,
      bytesTotal: _total,
      filesDone: 0,
      filesTotal: 24,
      path: _local,
      startedAt: DateTime.now(),
    );
    _timer ??= Timer.periodic(tick, (_) => _step());
  }

  void _step() {
    _n++;
    for (final t in _transfers.values.toList()) {
      if (t.phase != TransferPhase.running) continue;
      // A wobbly ~90 MB/s, so the UI's number handling gets exercised.
      final speed = 90e6 + 8e6 * math.sin(_n / 7);
      final done = math.min(_total, t.bytesDone + (speed * tick.inMicroseconds / 1e6).round());
      final files = (24 * done / _total).floor();
      _transfers[t.transferId] = TransferSnapshot(
        transferId: t.transferId,
        role: t.role,
        peerId: t.peerId,
        peerName: t.peerName,
        peerKind: t.peerKind,
        phase: done >= _total ? TransferPhase.complete : TransferPhase.running,
        bytesDone: done,
        bytesTotal: _total,
        filesDone: files,
        filesTotal: 24,
        filesVerified: files,
        speed: speed,
        etaSeconds: (_total - done) / speed,
        path: t.path,
        startedAt: t.startedAt,
      );
    }
    _emit();
  }

  void _emit() => _out.add(List.unmodifiable(_transfers.values));

  /// Test hook: show an incoming offer.
  void offer(IncomingOffer offer) => _offers.add([offer]);

  @override
  Stream<List<TransferSnapshot>> watch() async* {
    yield List.unmodifiable(_transfers.values);
    yield* _out.stream;
  }

  @override
  Stream<List<IncomingOffer>> incoming() async* {
    yield const [];
    yield* _offers.stream;
  }

  @override
  Future<String> send(String deviceId, List<FileSource> files) async {
    final id = 'demo-transfer-${_transfers.length + 1}';
    _start(id);
    return id;
  }

  @override
  Future<void> accept(String transferId) async => _offers.add(const []);

  @override
  Future<void> decline(String transferId) async => _offers.add(const []);

  @override
  Future<void> pause(String transferId) async => _set(transferId, TransferPhase.paused);

  @override
  Future<void> resume(String transferId) async => _set(transferId, TransferPhase.running);

  @override
  Future<void> cancel(String transferId) async => _set(transferId, TransferPhase.cancelled);

  void _set(String id, TransferPhase phase) {
    final t = _transfers[id];
    if (t == null) return;
    _transfers[id] = TransferSnapshot(
      transferId: t.transferId,
      role: t.role,
      peerId: t.peerId,
      peerName: t.peerName,
      peerKind: t.peerKind,
      phase: phase,
      bytesDone: t.bytesDone,
      bytesTotal: t.bytesTotal,
      filesDone: t.filesDone,
      filesTotal: t.filesTotal,
      filesVerified: t.filesVerified,
      path: t.path,
      startedAt: t.startedAt,
    );
    _emit();
  }

  Future<void> dispose() async {
    _timer?.cancel();
    await _out.close();
    await _offers.close();
  }
}

class DemoTransferHistory implements TransferHistory {
  DemoTransferHistory() : _records = _seed();
  final List<TransferRecord> _records;
  final _out = StreamController<List<TransferRecord>>.broadcast();

  static List<TransferRecord> _seed() {
    final now = DateTime.now();
    TransferRecord r(String id, int daysAgo, TransferRole role, String peer, DeviceKind kind, int files, int bytes,
            TransferOutcome outcome, double? speed) =>
        TransferRecord(
          transferId: id,
          role: role,
          peerName: peer,
          peerKind: kind,
          fileCount: files,
          totalBytes: bytes,
          startedAt: now.subtract(Duration(days: daysAgo, minutes: 3)),
          finishedAt: now.subtract(Duration(days: daysAgo)),
          outcome: outcome,
          verified: outcome == TransferOutcome.completed,
          averageSpeed: speed,
        );
    return [
      r('demo-h1', 0, TransferRole.sending, 'MacBook Pro', DeviceKind.laptop, 24, 1800000000, TransferOutcome.completed, 94e6),
      r('demo-h2', 0, TransferRole.receiving, 'Pixel 9', DeviceKind.phone, 312, 1240000000, TransferOutcome.completed, 61e6),
      r('demo-h3', 1, TransferRole.sending, 'Windows PC', DeviceKind.desktop, 3, 48200000, TransferOutcome.cancelled, null),
      r('demo-h4', 6, TransferRole.receiving, "Ved's iPhone", DeviceKind.phone, 1, 5300000000, TransferOutcome.completed, 88e6),
    ];
  }

  @override
  Stream<List<TransferRecord>> watch() async* {
    yield List.unmodifiable(_records);
    yield* _out.stream;
  }

  @override
  Future<void> remove(String transferId) async {
    _records.removeWhere((r) => r.transferId == transferId);
    _out.add(List.unmodifiable(_records));
  }

  @override
  Future<void> clear() async {
    _records.clear();
    _out.add(const []);
  }
}
