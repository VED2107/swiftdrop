import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../engine/controller.dart';
import '../engine/job.dart';
import '../engine/receiver.dart';
import '../engine/speed_meter.dart';
import '../io/io_files.dart';
import '../platform/files.dart';
import '../platform/system.dart';
import '../protocol/errors.dart';
import '../protocol/types.dart';
import '../services/models.dart';
import '../services/services.dart';
import '../transport/engine_transport.dart';
import '../transport/lanes.dart';
import '../transport/link.dart';
import '../transport/path.dart';
import '../util/random.dart';

/// Everything the app's transfer side does, in one pure-Dart object: the listener (with
/// receive lanes), known devices, outgoing jobs (with send lanes), the receiver, and
/// history. It runs inside the engine isolate (see [EngineHost]); tests drive it directly.
///
/// UI traffic is bounded at the source: transfer snapshots are published at most
/// [snapshotInterval] apart (10/s), never per chunk.
class EngineConfig {
  const EngineConfig({
    required this.dataDir,
    required this.downloadDir,
    required this.name,
    this.kind = DeviceKind.desktop,
    this.platform = DevicePlatform.unknown,
    this.port = defaultPort,
    this.lanes = 4,
    this.mobile = false,
    this.bindAddress,
  });

  static const defaultPort = 47800;

  /// Private app data: identity, known devices, history, resume state.
  final String dataDir;

  /// Where received files land.
  final String downloadDir;
  final String name;
  final DeviceKind kind;
  final DevicePlatform platform;

  /// Preferred listening port; falls back to any free port when taken.
  final int port;

  /// Parallel connections per peer (docs/BENCHMARKS.md).
  final int lanes;
  final bool mobile;

  /// Tests bind loopback; the app binds every IPv4 interface.
  final String? bindAddress;
}

class EngineRuntime {
  EngineRuntime._(this.config);

  static const snapshotInterval = Duration(milliseconds: 100);

  static Future<EngineRuntime> start(EngineConfig config) async {
    final r = EngineRuntime._(config);
    await r._start();
    return r;
  }

  final EngineConfig config;
  late String deviceId;
  late String name;

  // outputs (latest value is kept so late listeners get it)
  final _devicesOut = StreamController<List<Device>>.broadcast();
  final _endpointOut = StreamController<LocalEndpoint?>.broadcast();
  final _transfersOut = StreamController<List<TransferSnapshot>>.broadcast();
  final _offersOut = StreamController<List<IncomingOffer>>.broadcast();
  final _historyOut = StreamController<List<TransferRecord>>.broadcast();
  Stream<List<Device>> get devices => _devicesOut.stream;
  Stream<LocalEndpoint?> get endpointStream => _endpointOut.stream;
  Stream<List<TransferSnapshot>> get transfers => _transfersOut.stream;
  Stream<List<IncomingOffer>> get offers => _offersOut.stream;
  Stream<List<TransferRecord>> get history => _historyOut.stream;

  LocalEndpoint? endpoint;
  final _devices = <String, Device>{};
  final _transports = <String, LaneTransport>{};
  final _connectedPeers = <int, String>{}; // receiver connection id → device id
  final _jobs = <String, _Outgoing>{};
  final _incoming = <String, _Incoming>{};
  final _pendingOffers = <String, (IncomingOffer, Completer<bool>)>{};
  final _dismissed = <String>{};
  var _history = <TransferRecord>[];

  late Receiver _receiver;
  DuplicatePolicy duplicates = DuplicatePolicy.keepBoth;
  late String downloadDir = config.downloadDir;
  late final LaneReceiver _listener;
  Timer? _ticker;
  bool _dirty = true;

  String get _devicesFile => p.join(config.dataDir, 'devices.json');
  String get _historyFile => p.join(config.dataDir, 'history.json');
  String get _identityFile => p.join(config.dataDir, 'identity.json');

  ControllerConfig get _controller => lanedController(config.mobile ? mobileController : desktopController, config.lanes);

  // -------------------------------------------------------------------------
  // lifecycle

  Future<void> _start() async {
    await Directory(config.dataDir).create(recursive: true);
    await Directory(downloadDir).create(recursive: true);
    await _loadIdentity();
    await _loadDevices();
    await _loadHistory();

    _receiver = _makeReceiver();

    final bind = config.bindAddress == null ? InternetAddress.anyIPv4 : InternetAddress(config.bindAddress!);
    try {
      _listener = await _listen(bind, config.port);
    } on SocketException {
      _listener = await _listen(bind, 0); // preferred port taken (e.g. a second instance)
    }
    endpoint = LocalEndpoint(deviceId: deviceId, name: name, addresses: await _localAddresses(), port: _listener.port);
    _endpointOut.add(endpoint);
    _ticker = Timer.periodic(snapshotInterval, (_) => _publishTransfers());
    _publishDevices();
    _publishHistory();
  }

  Receiver _makeReceiver() => Receiver(ReceiverOptions(
        sinks: IoSinkFactory(downloadDir),
        state: IoStateStore(p.join(config.dataDir, 'incoming')),
        accept: _askToAccept,
        duplicates: () => duplicates,
        onProgress: _onReceiveProgress,
        onComplete: _onReceiveComplete,
        onForget: _onReceiveForgotten,
      ));

  /// This device's name as others see it.
  Future<void> setName(String value) async {
    name = _cleanName(value);
    await _writeJson(_identityFile, {'deviceId': deviceId, 'name': name});
    endpoint = LocalEndpoint(deviceId: deviceId, name: name, addresses: endpoint?.addresses ?? const [], port: _listener.port);
    _endpointOut.add(endpoint);
  }

  Future<void> setDuplicates(DuplicatePolicy policy) async => duplicates = policy;

  /// Where received files land. Refused while something is being received (its partial
  /// data and resume state belong to the current folder).
  Future<void> setDownloadDir(String dir) async {
    if (_incoming.values.any((i) => i.finishedAt == null)) {
      throw TransportException(ErrorCode.forbidden, 'receiving');
    }
    await Directory(dir).create(recursive: true);
    downloadDir = dir;
    _receiver = _makeReceiver();
  }

  Future<LaneReceiver> _listen(InternetAddress bind, int port) => LaneReceiver.start(
        onRequest: _onRequest,
        onClosed: _onConnectionClosed,
        port: port,
        address: bind,
        lanes: config.lanes,
      );

  Future<void> stop() async {
    _ticker?.cancel();
    for (final j in _jobs.values) {
      j.job.pause();
    }
    for (final t in _transports.values) {
      await t.close();
    }
    await _receiver.flush();
    await _listener.close();
  }

  // -------------------------------------------------------------------------
  // incoming connections

  Future<Object?> _onRequest(String op, Object? args, Uint8List body, ConnectionInfo c) async {
    if (op == 'hello') {
      final peer = _peerFromHello(args, c.remoteAddress);
      if (peer != null) _connectedPeers[c.id] = peer.id;
      return _hello();
    }
    final peerId = _connectedPeers[c.id];
    return _receiver.handle(op, args, body, peerId: peerId);
  }

  void _onConnectionClosed(ConnectionInfo c) {
    final id = _connectedPeers.remove(c.id);
    if (id == null || _connectedPeers.containsValue(id)) return;
    final d = _devices[id];
    if (d != null && _transports[id]?.connected != true) {
      _devices[id] = d.copyWith(status: DeviceStatus.available);
      _publishDevices();
    }
  }

  Map<String, Object?> _hello() => {
        'v': 1,
        'deviceId': deviceId,
        'name': name,
        'kind': config.kind.name,
        'platform': config.platform.name,
        'port': _listener.port,
      };

  Device? _peerFromHello(Object? args, String remoteAddress) {
    if (args is! Map) return null;
    final id = args['deviceId'];
    if (id is! String || id.isEmpty || id == deviceId) return null;
    final port = (args['port'] as num?)?.toInt();
    final kind = DeviceKind.values.asNameMap()['${args['kind']}'] ?? DeviceKind.unknown;
    final platform = DevicePlatform.values.asNameMap()['${args['platform']}'] ?? DevicePlatform.unknown;
    final existing = _devices[id];
    final address = port != null && remoteAddress.isNotEmpty ? _joinHostPort(remoteAddress, port) : existing?.address;
    final d = Device(
      id: id,
      name: existing?.name ?? _cleanName('${args['name'] ?? 'Device'}'),
      kind: kind,
      platform: platform,
      status: DeviceStatus.connected,
      path: LinkPath(kind: classifyAddresses(remoteAddress, remoteAddress), link: LinkKind.tcp, remoteAddress: remoteAddress),
      trusted: false,
      lastUsed: DateTime.now(),
      address: address,
    );
    _devices[id] = d;
    _saveDevices();
    _publishDevices();
    return d;
  }

  // -------------------------------------------------------------------------
  // receiving

  Future<bool> _askToAccept(IncomingManifest m) {
    final from = (m.peerId != null ? _devices[m.peerId] : null) ??
        Device(id: 'unknown', name: 'Unknown device', kind: DeviceKind.unknown, platform: DevicePlatform.unknown, status: DeviceStatus.connected);
    final offer = IncomingOffer(
      transferId: m.transferId,
      from: from,
      fileCount: m.files.length,
      totalBytes: m.totalBytes,
      sampleNames: [for (final f in m.files.take(6)) f.relDir.isEmpty ? f.name : '${f.relDir}/${f.name}'],
    );
    final decision = Completer<bool>();
    _pendingOffers[m.transferId] = (offer, decision);
    _publishOffers();
    // Nobody answered: decline, the sender is told plainly.
    final timeout = Timer(const Duration(minutes: 5), () {
      if (!decision.isCompleted) decision.complete(false);
    });
    return decision.future.whenComplete(() {
      timeout.cancel();
      _pendingOffers.remove(m.transferId);
      _publishOffers();
      if (_incoming[m.transferId] == null) {
        _incoming[m.transferId] = _Incoming(m.transferId, from, m.totalBytes, m.files.length, DateTime.now(), _label(m.files.length, m.label));
      }
    });
  }

  Future<void> accept(String transferId) async => _pendingOffers[transferId]?.$2.complete(true);

  Future<void> decline(String transferId) async {
    final pending = _pendingOffers[transferId];
    if (pending == null) return;
    pending.$2.complete(false);
    _incoming.remove(transferId);
  }

  void _onReceiveProgress(ReceivedTransfer t) {
    final i = _incoming[t.id];
    if (i == null) return;
    final delta = t.bytesDone - i.lastBytes;
    if (delta > 0) i.meter.add(delta);
    i.meter.start();
    i.lastBytes = t.bytesDone;
    i.received = t;
    _dirty = true;
  }

  void _onReceiveComplete(ReceivedTransfer t) {
    final i = _incoming[t.id];
    if (i == null) return;
    i.received = t;
    i.finishedAt = DateTime.now();
    i.meter.stop();
    _record(TransferRecord(
      transferId: t.id,
      role: TransferRole.receiving,
      peerName: i.from.name,
      peerKind: i.from.kind,
      fileCount: t.files.length,
      totalBytes: t.bytesTotal,
      startedAt: i.startedAt,
      finishedAt: i.finishedAt!,
      outcome: TransferOutcome.completed,
      verified: t.filesVerified == t.files.where((f) => f.state != FileState.skipped).length,
      averageSpeed: i.meter.average(),
      location: downloadDir,
    ));
    _dirty = true;
  }

  void _onReceiveForgotten(String transferId) {
    final i = _incoming[transferId];
    if (i == null || i.finishedAt != null) return;
    i.cancelled = true;
    i.finishedAt = DateTime.now();
    _record(TransferRecord(
      transferId: transferId,
      role: TransferRole.receiving,
      peerName: i.from.name,
      peerKind: i.from.kind,
      fileCount: i.files,
      totalBytes: i.bytesTotal,
      startedAt: i.startedAt,
      finishedAt: i.finishedAt!,
      outcome: TransferOutcome.cancelled,
      verified: false,
    ));
    _dirty = true;
  }

  // -------------------------------------------------------------------------
  // devices and sending

  Future<Device> connect(String address) async {
    final (host, port) = _parseAddress(address);
    final existing = _devices.values.where((d) => d.address == _joinHostPort(host, port)).firstOrNull;
    if (existing != null && _transports[existing.id]?.connected == true) return existing;
    Device? device;
    final LaneTransport transport;
    try {
      transport = await LaneTransport.dial(host, port, lanes: config.lanes, onConnected: (rpc) async {
        try {
          final reply = await rpc.request('hello', _hello());
          device = _peerFromHello(reply, host);
        } on TransportException {
          // An older peer without hello: still usable, just unnamed.
        }
      });
    } on SocketException catch (e) {
      throw TransportException(ErrorCode.network, e.message);
    }
    final d = device ??
        Device(
          id: 'addr:${_joinHostPort(host, port)}',
          name: host,
          kind: DeviceKind.unknown,
          platform: DevicePlatform.unknown,
          status: DeviceStatus.connected,
          address: _joinHostPort(host, port),
        );
    final old = _transports[d.id];
    if (old != null && !identical(old, transport)) await old.close();
    _transports[d.id] = transport;
    _devices[d.id] = d.copyWith(status: DeviceStatus.connected, path: transport.path, lastUsed: DateTime.now());
    _saveDevices();
    _publishDevices();
    return _devices[d.id]!;
  }

  Future<String> send(String deviceId, List<SendItem> items) async {
    var device = _devices[deviceId];
    if (device == null) throw TransportException(ErrorCode.notFound, 'unknown device');
    if (_transports[deviceId]?.connected != true) {
      if (device.address == null) throw TransportException(ErrorCode.network, 'no address');
      device = await connect(device.address!);
    }
    final transport = _transports[device.id]!;
    final files = <FileSource>[];
    for (final item in items) {
      if (item.folder) {
        files.addAll(IoFileSource.folder(item.path));
      } else {
        files.add(IoFileSource(item.path));
      }
    }
    if (files.isEmpty) throw TransportException(ErrorCode.badRequest, 'nothing to send');
    final label = items.length == 1 && items.single.folder ? p.basename(items.single.path) : _label(files.length, '');
    final job = TransferJob(JobOptions(
      transport: transport,
      files: files,
      direction: Direction.toPeer,
      label: label,
      controller: _controller,
    ));
    final out = _Outgoing(job, device, DateTime.now(), label);
    _jobs[job.id] = out;
    job.onChange(() => _dirty = true);
    unawaited(job.start());
    unawaited(job.done.then((_) => _onJobDone(out)));
    _dirty = true;
    return job.id;
  }

  void _onJobDone(_Outgoing o) {
    final s = o.job.snapshot();
    o.finishedAt = DateTime.now();
    _record(TransferRecord(
      transferId: o.job.id,
      role: TransferRole.sending,
      peerName: o.device.name,
      peerKind: o.device.kind,
      fileCount: o.job.files.length,
      totalBytes: o.job.bytesTotal,
      startedAt: o.startedAt,
      finishedAt: o.finishedAt!,
      outcome: switch (s.state) {
        JobState.complete => TransferOutcome.completed,
        JobState.cancelled => TransferOutcome.cancelled,
        _ => s.errorCode == ErrorCode.declined ? TransferOutcome.declined : TransferOutcome.failed,
      },
      verified: s.state == JobState.complete && s.filesFailed == 0,
      averageSpeed: s.average > 0 ? s.average : null,
    ));
    _dirty = true;
  }

  Future<void> pause(String id) async => _jobs[id]?.job.pause();
  Future<void> resume(String id) async => _jobs[id]?.job.resume();

  Future<void> cancel(String id) async {
    final o = _jobs[id];
    if (o != null) return o.job.cancel();
    if (_incoming.containsKey(id)) await _receiver.forget(id);
  }

  Future<void> dismiss(String id) async {
    _dismissed.add(id);
    final o = _jobs[id];
    if (o != null && o.finishedAt != null) _jobs.remove(id);
    final i = _incoming[id];
    if (i != null && i.finishedAt != null) _incoming.remove(id);
    _dirty = true;
  }

  Future<void> rename(String id, String newName) async {
    final d = _devices[id];
    if (d == null) return;
    _devices[id] = d.copyWith(name: _cleanName(newName));
    _saveDevices();
    _publishDevices();
  }

  Future<void> forget(String id) async {
    _devices.remove(id);
    await _transports.remove(id)?.close();
    _saveDevices();
    _publishDevices();
  }

  Future<void> removeHistory(String id) async {
    _history.removeWhere((r) => r.transferId == id);
    _saveHistory();
    _publishHistory();
  }

  Future<void> clearHistory() async {
    _history = [];
    _saveHistory();
    _publishHistory();
  }

  // -------------------------------------------------------------------------
  // publishing

  void _publishTransfers() {
    final active = _jobs.values.any((o) => o.finishedAt == null) || _incoming.values.any((i) => i.finishedAt == null);
    if (!_dirty && !active) return;
    _dirty = false;
    final list = <TransferSnapshot>[
      for (final o in _jobs.values)
        if (!_dismissed.contains(o.job.id)) _outgoingSnapshot(o),
      for (final i in _incoming.values)
        if (!_dismissed.contains(i.id)) _incomingSnapshot(i),
    ];
    list.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    _transfersOut.add(list);
    _refreshBusy();
  }

  TransferSnapshot _outgoingSnapshot(_Outgoing o) {
    final s = o.job.snapshot();
    return TransferSnapshot(
      transferId: o.job.id,
      role: TransferRole.sending,
      peerId: o.device.id,
      peerName: _devices[o.device.id]?.name ?? o.device.name,
      peerKind: o.device.kind,
      phase: switch (s.state) {
        JobState.queued || JobState.preparing || JobState.awaitingDecision => TransferPhase.awaitingAcceptance,
        JobState.running => TransferPhase.running,
        JobState.paused => TransferPhase.paused,
        JobState.reconnecting => TransferPhase.reconnecting,
        JobState.complete => TransferPhase.complete,
        JobState.cancelled => TransferPhase.cancelled,
        JobState.failed => s.errorCode == ErrorCode.declined ? TransferPhase.declined : TransferPhase.failed,
      },
      bytesDone: s.bytesDone,
      bytesTotal: s.bytesTotal,
      filesDone: s.filesDone,
      filesTotal: s.filesTotal,
      filesVerified: s.filesDone,
      speed: s.speed,
      etaSeconds: s.etaSeconds.isFinite ? s.etaSeconds : null,
      path: _transports[o.device.id]?.path,
      error: s.errorCode,
      startedAt: o.startedAt,
      label: o.label,
    );
  }

  TransferSnapshot _incomingSnapshot(_Incoming i) {
    final t = i.received;
    final done = t?.bytesDone ?? 0;
    final speed = i.finishedAt == null ? i.meter.rate() : 0.0;
    final avg = i.meter.average();
    final basis = speed > 0 ? speed * 0.7 + avg * 0.3 : avg;
    return TransferSnapshot(
      transferId: i.id,
      role: TransferRole.receiving,
      peerId: i.from.id,
      peerName: i.from.name,
      peerKind: i.from.kind,
      phase: i.cancelled
          ? TransferPhase.cancelled
          : (t != null && t.finished ? TransferPhase.complete : (t == null ? TransferPhase.awaitingAcceptance : TransferPhase.running)),
      bytesDone: done,
      bytesTotal: i.bytesTotal,
      filesDone: t?.filesDone ?? 0,
      filesTotal: i.files,
      filesVerified: t?.filesVerified ?? 0,
      speed: speed,
      etaSeconds: basis > 0 ? (i.bytesTotal - done) / basis : null,
      startedAt: i.startedAt,
      label: i.label,
      location: downloadDir,
    );
  }

  void _refreshBusy() {
    final busy = <String>{
      for (final o in _jobs.values)
        if (o.finishedAt == null) o.device.id,
      for (final i in _incoming.values)
        if (i.finishedAt == null) i.from.id,
    };
    var changed = false;
    _devices.updateAll((id, d) {
      final want = busy.contains(id)
          ? DeviceStatus.busy
          : (d.status == DeviceStatus.busy ? DeviceStatus.connected : d.status);
      if (want == d.status) return d;
      changed = true;
      return d.copyWith(status: want);
    });
    if (changed) _publishDevices();
  }

  void _publishDevices() {
    final list = _devices.values.toList()
      ..sort((a, b) {
        final s = a.status.index.compareTo(b.status.index);
        return s != 0 ? s : a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    _devicesOut.add(list);
  }

  /// Re-sends every current value (a new host just attached).
  void publishAll() {
    _endpointOut.add(endpoint);
    _publishDevices();
    _publishOffers();
    _publishHistory();
    _dirty = true;
    _publishTransfers();
  }

  void _publishOffers() => _offersOut.add([for (final o in _pendingOffers.values) o.$1]);
  void _publishHistory() => _historyOut.add(List.unmodifiable(_history));

  void _record(TransferRecord r) {
    _history.removeWhere((x) => x.transferId == r.transferId);
    _history.insert(0, r);
    if (_history.length > 500) _history = _history.sublist(0, 500);
    _saveHistory();
    _publishHistory();
  }

  // -------------------------------------------------------------------------
  // persistence (small JSON files, atomic writes)

  Future<void> _loadIdentity() async {
    try {
      final j = jsonDecode(await File(_identityFile).readAsString()) as Map<String, Object?>;
      deviceId = j['deviceId'] as String;
      name = (j['name'] as String?) ?? config.name;
    } catch (_) {
      deviceId = 'd_${randomId(20)}';
      name = config.name;
      await _writeJson(_identityFile, {'deviceId': deviceId, 'name': name});
    }
  }

  Future<void> _loadDevices() async {
    try {
      final list = jsonDecode(await File(_devicesFile).readAsString()) as List<Object?>;
      for (final raw in list) {
        final j = raw as Map<String, Object?>;
        final d = Device(
          id: j['id'] as String,
          name: j['name'] as String,
          kind: DeviceKind.values.asNameMap()[j['kind']] ?? DeviceKind.unknown,
          platform: DevicePlatform.values.asNameMap()[j['platform']] ?? DevicePlatform.unknown,
          status: DeviceStatus.offline,
          address: j['address'] as String?,
          lastUsed: j['lastUsed'] is int ? DateTime.fromMillisecondsSinceEpoch(j['lastUsed'] as int) : null,
        );
        _devices[d.id] = d;
      }
    } catch (_) {}
  }

  void _saveDevices() => _writeJson(_devicesFile, [
        for (final d in _devices.values)
          {
            'id': d.id,
            'name': d.name,
            'kind': d.kind.name,
            'platform': d.platform.name,
            'address': d.address,
            'lastUsed': d.lastUsed?.millisecondsSinceEpoch,
          },
      ]).ignore();

  Future<void> _loadHistory() async {
    try {
      final list = jsonDecode(await File(_historyFile).readAsString()) as List<Object?>;
      _history = [
        for (final raw in list)
          () {
            final j = raw as Map<String, Object?>;
            return TransferRecord(
              transferId: j['id'] as String,
              role: j['role'] == 'receiving' ? TransferRole.receiving : TransferRole.sending,
              peerName: j['peer'] as String,
              peerKind: DeviceKind.values.asNameMap()[j['kind']] ?? DeviceKind.unknown,
              fileCount: j['files'] as int,
              totalBytes: j['bytes'] as int,
              startedAt: DateTime.fromMillisecondsSinceEpoch(j['started'] as int),
              finishedAt: DateTime.fromMillisecondsSinceEpoch(j['finished'] as int),
              outcome: TransferOutcome.values.asNameMap()[j['outcome']] ?? TransferOutcome.failed,
              verified: j['verified'] == true,
              averageSpeed: (j['speed'] as num?)?.toDouble(),
              location: j['location'] as String?,
            );
          }(),
      ];
    } catch (_) {}
  }

  void _saveHistory() => _writeJson(_historyFile, [
        for (final r in _history)
          {
            'id': r.transferId,
            'role': r.role.name,
            'peer': r.peerName,
            'kind': r.peerKind.name,
            'files': r.fileCount,
            'bytes': r.totalBytes,
            'started': r.startedAt.millisecondsSinceEpoch,
            'finished': r.finishedAt.millisecondsSinceEpoch,
            'outcome': r.outcome.name,
            'verified': r.verified,
            'speed': r.averageSpeed,
            'location': r.location,
          },
      ]).ignore();

  Future<void> _writeJson(String path, Object value) async {
    final tmp = File('$path.${randomId(6)}.tmp');
    await tmp.writeAsString(jsonEncode(value), flush: true);
    await tmp.rename(path);
  }
}

class _Outgoing {
  _Outgoing(this.job, this.device, this.startedAt, this.label);
  final TransferJob job;
  final Device device;
  final DateTime startedAt;
  final String label;
  DateTime? finishedAt;
}

class _Incoming {
  _Incoming(this.id, this.from, this.bytesTotal, this.files, this.startedAt, this.label);
  final String id;
  final Device from;
  final int bytesTotal;
  final int files;
  final DateTime startedAt;
  final String label;
  final meter = SpeedMeter(now: () => DateTime.now().microsecondsSinceEpoch / 1000);
  ReceivedTransfer? received;
  int lastBytes = 0;
  DateTime? finishedAt;
  bool cancelled = false;
}

String _label(int files, String label) => label.isNotEmpty ? label : (files == 1 ? '1 file' : '$files files');

String _cleanName(String s) {
  final t = String.fromCharCodes(s.codeUnits.where((c) => c >= 32 && c != 127)).trim();
  return t.isEmpty ? 'Device' : (t.length > 40 ? t.substring(0, 40) : t);
}

String _joinHostPort(String host, int port) => host.contains(':') ? '[$host]:$port' : '$host:$port';

(String, int) _parseAddress(String address) {
  final a = address.trim();
  final v6 = RegExp(r'^\[([^\]]+)\]:(\d+)$').firstMatch(a);
  if (v6 != null) return (v6.group(1)!, int.parse(v6.group(2)!));
  final i = a.lastIndexOf(':');
  if (i > 0 && !a.substring(0, i).contains(':')) {
    final port = int.tryParse(a.substring(i + 1));
    if (port != null && port > 0 && port < 65536) return (a.substring(0, i), port);
  }
  if (a.isNotEmpty && !a.contains(' ')) return (a, EngineConfig.defaultPort);
  throw TransportException(ErrorCode.badRequest, 'Enter an address like 192.168.1.20:47800');
}

/// Private IPv4 addresses of this machine, best first (Wi-Fi/Ethernet over virtual ones).
Future<List<String>> _localAddresses() async {
  try {
    final ifaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
    final scored = <(int, String)>[];
    for (final i in ifaces) {
      final n = i.name.toLowerCase();
      final virtual = n.contains('vethernet') || n.contains('virtual') || n.contains('vmware') || n.contains('docker') || n.contains('wsl') || n.contains('hyper-v');
      for (final a in i.addresses) {
        if (a.isLoopback || !isLocalAddress(a.address) || a.address.startsWith('169.254.')) continue;
        final wifi = n.contains('wi-fi') || n.contains('wlan') || n.contains('wireless') || n.startsWith('en') || n.startsWith('wl');
        scored.add(((virtual ? 2 : 0) + (wifi ? 0 : 1), a.address));
      }
    }
    scored.sort((a, b) => a.$1.compareTo(b.$1));
    return [for (final s in scored) s.$2];
  } catch (_) {
    return const [];
  }
}
