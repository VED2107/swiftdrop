import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../engine/controller.dart';
import '../engine/job.dart';
import '../engine/receiver.dart';
import '../engine/speed_meter.dart';
import '../io/io_files.dart';
import '../io/publishing_sink.dart';
import '../platform/bridge.dart';
import '../platform/destination.dart';
import '../platform/io_kind.dart';
import '../platform/files.dart';
import '../platform/system.dart';
import '../protocol/errors.dart';
import '../protocol/types.dart';
import '../services/models.dart';
import '../services/services.dart';
import '../transport/engine_transport.dart';
import '../transport/lanes.dart';
import '../transport/net_ifaces.dart';
import '../transport/link.dart';
import '../transport/path.dart';
import '../util/random.dart';
import '../web/web_auth.dart';
import '../web/web_host.dart';

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
    this.webRoot,
    this.webPort = WebHost.defaultPort,
    this.version = '0.0.0',
    this.bridge,
    this.stagingDir,
    this.destination = SaveDestination.standard,
    this.debugNet = false,
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

  /// The built web client (`apps/web/dist`). Set: phones without the app (an iPhone's
  /// Safari) can pair by QR and send/receive through it. Null: no browser access.
  final String? webRoot;
  final int webPort;
  final String version;

  /// Phones: the UI isolate's platform bridge (see [BridgeHost]). Set, received files are
  /// staged privately and published to the public media library / a chosen folder.
  final SendPort? bridge;

  /// Private staging folder for partial files when [bridge] is set.
  final String? stagingDir;
  final SaveDestination destination;

  /// Logs the network path (interfaces, candidates, selected address) with `[NET]`.
  final bool debugNet;
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
  final _joinsOut = StreamController<List<BrowserJoin>>.broadcast();
  Stream<List<BrowserJoin>> get joins => _joinsOut.stream;
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
  late SaveDestination destination = config.destination;
  PublishingSinkFactory? _publisher;
  late final PlatformBridge? bridge = config.bridge == null ? null : PortBridge(config.bridge!);
  late final LaneReceiver _listener;
  WebHost? _web;
  final _webOut = <String, _WebOutgoing>{};
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
    if (config.bridge == null) await Directory(downloadDir).create(recursive: true);
    netDebug = config.debugNet;
    if (netDebug) netLogSink = print;
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
    if (config.webRoot != null) {
      _web = await WebHost.start(
        auth: WebAuth(p.join(config.dataDir, 'web')),
        webRoot: config.webRoot!,
        version: config.version,
        port: config.webPort,
        address: bind,
        delegate: WebHostDelegate(
          receive: (op, args, body, d) => _receiver.handle(op, args, body, peerId: _syncWebDevice(d).id),
          onJoin: (_) => _publishJoins(),
          onDevices: _syncWebDevices,
          onDownload: _onWebDownload,
          folderName: () => p.basename(downloadDir),
        ),
      );
      _syncWebDevices();
    }
    _nets = await _localAddresses(bridge, onRaw: (r) => _ifaces = r);
    _refreshEndpoint();
    _ticker = Timer.periodic(snapshotInterval, (_) => _publishTransfers());
    // Networks come and go (hotspot dropped, Wi-Fi joined): the QR must follow them.
    _netTimer = Timer.periodic(const Duration(seconds: 4), (_) => _pollNetworks());
    _publishDevices();
    _publishHistory();
  }

  SinkFactory _makeSinks() {
    final b = bridge;
    if (b == null) return IoSinkFactory(downloadDir);
    return _publisher = PublishingSinkFactory(
      stagingRoot: config.stagingDir ?? p.join(config.dataDir, 'staging'),
      bridge: b,
      destination: destination,
    );
  }

  /// Where received files are shown to be (a folder path, or the phone's chosen place).
  String get locationLabel => config.bridge == null ? downloadDir : (destination.treeName ?? 'Downloads/SwiftDrop');

  /// (media-library files, other files) of a received transfer, phones only.
  (int, int) _savedCounts(ReceivedTransfer? t) {
    if (t == null || config.bridge == null) return (0, 0);
    var media = 0;
    var other = 0;
    for (final f in t.files) {
      if (f.state != FileState.complete) continue;
      destination.targetFor(kindForMime(mimeFor(f.name))) == SaveTarget.gallery ? media++ : other++;
    }
    return (media, other);
  }

  Receiver _makeReceiver() => Receiver(ReceiverOptions(
        sinks: _makeSinks(),
        state: IoStateStore(p.join(config.dataDir, 'incoming')),
        accept: _askToAccept,
        duplicates: () => duplicates,
        onProgress: _onReceiveProgress,
        onComplete: _onReceiveComplete,
        onForget: _onReceiveForgotten,
        // Browser guests upload with the PC server's direction (phone -> host).
        directions: {Direction.toPeer, if (config.webRoot != null) Direction.toHost},
      ));

  /// This device's name as others see it.
  Future<void> setName(String value) async {
    name = _cleanName(value);
    await _writeJson(_identityFile, {'deviceId': deviceId, 'name': name});
    _refreshEndpoint();
  }

  void _refreshEndpoint() {
    endpoint = LocalEndpoint(
      deviceId: deviceId,
      name: name,
      addresses: [for (final n in _nets) n.$1],
      labels: {for (final n in _nets) n.$1: n.$2},
      port: _listener.port,
      web: _browserAccess(),
    );
    _endpointOut.add(endpoint);
  }

  List<(String, String)> _nets = const [];
  List<NetIface> _ifaces = const [];
  Timer? _netTimer;
  bool _polling = false;

  Future<void> _pollNetworks() async {
    if (_polling) return;
    _polling = true;
    try {
      final now = await _localAddresses(bridge, onRaw: (r) => _ifaces = r);
      final same = now.length == _nets.length && [for (var i = 0; i < now.length; i++) now[i] == _nets[i]].every((x) => x);
      if (!same) {
        _nets = now;
        _refreshEndpoint();
      }
    } finally {
      _polling = false;
    }
  }

  Future<void> setDuplicates(DuplicatePolicy policy) async => duplicates = policy;

  /// Phones: where media and other files are saved. Refused while receiving, like
  /// [setDownloadDir] (a half-received transfer must finish where it started).
  Future<void> setDestination(SaveDestination d) async {
    if (_incoming.values.any((i) => i.finishedAt == null)) {
      throw TransportException(ErrorCode.forbidden, 'receiving');
    }
    destination = d;
    _publisher?.destination = d;
  }

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
    _netTimer?.cancel();
    for (final j in _jobs.values) {
      j.job.pause();
    }
    for (final t in _transports.values) {
      await t.close();
    }
    await _receiver.flush();
    await _listener.close();
    await _web?.close();
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
    if (m.peerId != null && m.peerId!.startsWith('web:')) {
      // A browser this device approved at pairing: its uploads go straight in, like the
      // PC server's (the person chose the files on the phone in front of them).
      final from = _devices[m.peerId]!;
      _incoming[m.transferId] ??= _Incoming(m.transferId, from, m.totalBytes, m.files.length, DateTime.now(), _label(m.files.length, m.label));
      _dirty = true;
      return Future.value(true);
    }
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
      location: locationLabel,
      savedMedia: _savedCounts(t).$1,
      savedOther: _savedCounts(t).$2,
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

  /// Connects to one device that may be reachable at several addresses (a QR lists every
  /// network the other device is on). Candidates on one of our own subnets go first; the
  /// rest follow 250 ms apart, so a wrong guess (a mobile-data address, an address on a
  /// network we aren't on) costs nothing. The first one that accepts a TCP connection and,
  /// when [deviceId] is known, answers with that device's id, wins.
  Future<Device> connectAny(List<String> addresses, {String? deviceId}) async {
    final parsed = <(String, int)>[];
    for (final a in addresses) {
      final (h, p) = _parseAddress(a);
      if (!parsed.any((x) => x.$1 == h && x.$2 == p)) parsed.add((h, p));
    }
    final hosts = orderCandidates([for (final c in parsed) c.$1], _ifaces);
    final ordered = [for (final h in hosts) parsed.firstWhere((c) => c.$1 == h)];
    netLog('connectAny candidates=${ordered.map((c) => '${c.$1}:${c.$2}').join(', ')} mine=${_ifaces.map((i) => '$i').join(', ')}');
    if (ordered.length == 1) return connect(_joinHostPort(ordered.first.$1, ordered.first.$2));
    Object? lastError;
    await for (final hit in _probe(ordered)) {
      try {
        final d = await connect(hit);
        if (deviceId != null && !d.id.startsWith('addr:') && d.id != deviceId) {
          netLog('wrong device at $hit, trying the next address');
          await _transports.remove(d.id)?.close();
          _devices.remove(d.id);
          continue;
        }
        netLog('connected via $hit path=${d.path?.kind.name}');
        return d;
      } catch (e) {
        lastError = e;
      }
    }
    if (lastError is TransportException) throw lastError;
    throw TransportException(ErrorCode.network, 'no address answered');
  }

  /// Addresses that accept a TCP connection, in the order they answered. Attempts start
  /// 250 ms apart in [ordered] order; each gives up after 4 s.
  Stream<String> _probe(List<(String, int)> ordered) {
    late final StreamController<String> out;
    var left = ordered.length;
    var stopped = false;
    out = StreamController<String>(onCancel: () => stopped = true);
    for (var i = 0; i < ordered.length; i++) {
      final (host, port) = ordered[i];
      Future<void>.delayed(Duration(milliseconds: 250 * i), () async {
        if (!stopped) {
          try {
            final s = await Socket.connect(host, port, timeout: const Duration(seconds: 4));
            s.destroy();
            netLog('probe $host:$port ok');
            if (!stopped) out.add(_joinHostPort(host, port));
          } catch (e) {
            netLog('probe $host:$port failed: $e');
          }
        }
        if (--left == 0) await out.close();
      });
    }
    return out.stream;
  }

  /// The network changed (Wi-Fi joined or lost, hotspot toggled, VPN up or down): refresh
  /// the addresses in the QR now instead of at the next 4 s poll.
  Future<void> networkChanged() async {
    netLog('network changed');
    await _pollNetworks();
  }

  /// Plain-text network picture for "Network details" in Settings and bug reports.
  Future<String> diagnostics() async {
    await _pollNetworks();
    final b = StringBuffer('Port ${_listener.port}\n');
    b.writeln('Offered in the QR:');
    for (final n in _nets) {
      b.writeln('  ${n.$1} (${n.$2})');
    }
    if (_nets.isEmpty) b.writeln('  none: not on a Wi-Fi network or hotspot');
    b.writeln('Interfaces seen:');
    for (final i in _ifaces) {
      b.writeln('  $i');
    }
    for (final d in _devices.values) {
      final t = _transports[d.id];
      if (t == null || !t.connected) continue;
      final p = t.path;
      b.writeln('Connected to ${d.name}: ${p?.link.name} ${p?.localAddress ?? '?'} -> ${p?.remoteAddress ?? '?'} (${p?.kind.name})');
    }
    return b.toString();
  }

  Future<String> send(String deviceId, List<SendItem> items) async {
    if (deviceId.startsWith('web:')) return _offerToBrowser(deviceId, items);
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
    final w = _webOut[id];
    if (w != null) {
      _web?.removeOffer(id);
      w.finishedAt ??= DateTime.now();
      w.cancelled = true;
      _dirty = true;
      return;
    }
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
    final w = _webOut[id];
    if (w != null && w.finishedAt != null) {
      _webOut.remove(id);
      _web?.removeOffer(id);
    }
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
    if (id.startsWith('web:')) _web?.forget(id.substring(4));
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
  // browser guests (phones without the app)

  BrowserAccess? _browserAccess() {
    final w = _web;
    if (w == null) return null;
    final pr = w.auth.currentPairing();
    return BrowserAccess(port: w.port, token: pr.token, code: pr.code, expiresAt: DateTime.fromMillisecondsSinceEpoch(pr.expiresAt));
  }

  /// A fresh QR and code (the old ones stop working).
  Future<void> rotateWebPairing() async {
    _web?.auth.rotatePairing();
    _refreshEndpoint();
  }

  Future<void> resolveJoin(String id, bool approve) async {
    final w = _web;
    if (w == null) return;
    w.resolveJoin(id, approve);
    _publishJoins();
    _refreshEndpoint(); // approving spends the QR on screen
  }

  void _publishJoins() {
    final w = _web;
    _joinsOut.add(w == null
        ? const []
        : [
            for (final j in w.auth.pendingJoins) BrowserJoin(id: j.id, deviceName: j.deviceName, viaCode: j.via == 'code', returning: j.returning),
          ]);
  }

  Device _syncWebDevice(WebDevice d) {
    final id = 'web:${d.id}';
    final online = _web?.auth.isOnline(d.id) ?? false;
    final n = d.name.toLowerCase();
    final platform = n.contains('iphone') || n.contains('ipad')
        ? DevicePlatform.ios
        : (n.contains('android') ? DevicePlatform.android : DevicePlatform.web);
    final busy = _devices[id]?.status == DeviceStatus.busy;
    final dev = Device(
      id: id,
      name: d.name,
      kind: n.contains('ipad') ? DeviceKind.tablet : DeviceKind.phone,
      platform: platform,
      // A browser can only receive while its page is open: closed means offline, not
      // "available", so only devices that are really there are offered as destinations.
      status: busy ? DeviceStatus.busy : (online ? DeviceStatus.connected : DeviceStatus.offline),
      path: const LinkPath(kind: PathKind.local, link: LinkKind.http),
      trusted: true,
      lastUsed: DateTime.fromMillisecondsSinceEpoch(d.lastSeen),
    );
    _devices[id] = dev;
    return dev;
  }

  void _syncWebDevices() {
    final w = _web;
    if (w == null) return;
    final ids = <String>{};
    for (final d in w.auth.devices) {
      ids.add(_syncWebDevice(d).id);
    }
    _devices.removeWhere((id, _) => id.startsWith('web:') && !ids.contains(id));
    _publishDevices();
  }

  Future<String> _offerToBrowser(String deviceId, List<SendItem> items) async {
    final w = _web;
    final device = _devices[deviceId];
    if (w == null || device == null) throw TransportException(ErrorCode.notFound, 'unknown device');
    final sources = <IoFileSource>[
      for (final item in items) ...(item.folder ? IoFileSource.folder(item.path) : [IoFileSource(item.path)]),
    ];
    if (sources.isEmpty) throw TransportException(ErrorCode.badRequest, 'nothing to send');
    final label = items.length == 1 ? p.basename(items.single.path) : _label(sources.length, '');
    final offer = WebOffer(
      transferId: 'of_${randomId(12)}',
      label: label,
      files: [
        for (final s in sources)
          WebOfferFile(id: s.id, name: s.name, relDir: s.relDir, size: s.size, type: s.type, path: s.path, modified: DateTime.fromMillisecondsSinceEpoch(s.lastModified)),
      ],
    );
    w.addOffer(offer);
    _webOut[offer.transferId] = _WebOutgoing(offer, device, DateTime.now());
    _dirty = true;
    return offer.transferId;
  }

  void _onWebDownload(WebOffer o, int sent, int total, WebDevice? who) {
    final w = _webOut[o.transferId];
    if (w == null) return;
    // A ZIP and single files are different byte streams; progress follows the newest one.
    if (sent < w.lastSent) w.lastSent = 0;
    final delta = sent - w.lastSent;
    if (delta > 0) w.meter.add(delta);
    w.meter.start();
    w.lastSent = sent;
    w.sent = sent;
    w.total = total;
    if (sent >= total && w.finishedAt == null && (total >= o.totalBytes || o.files.length == 1)) {
      w.finishedAt = DateTime.now();
      w.meter.stop();
      _record(TransferRecord(
        transferId: o.transferId,
        role: TransferRole.sending,
        peerName: w.device.name,
        peerKind: w.device.kind,
        fileCount: o.files.length,
        totalBytes: o.totalBytes,
        startedAt: w.startedAt,
        finishedAt: w.finishedAt!,
        outcome: TransferOutcome.completed,
        verified: false, // HTTP download: the browser has no block digests to check
        averageSpeed: w.meter.average(),
      ));
    }
    _dirty = true;
  }

  TransferSnapshot _webSnapshot(_WebOutgoing w) {
    final total = w.total > 0 ? w.total : w.offer.totalBytes;
    final speed = w.finishedAt == null ? w.meter.rate() : 0.0;
    return TransferSnapshot(
      transferId: w.offer.transferId,
      role: TransferRole.sending,
      peerId: w.device.id,
      peerName: _devices[w.device.id]?.name ?? w.device.name,
      peerKind: w.device.kind,
      phase: w.cancelled
          ? TransferPhase.cancelled
          : (w.finishedAt != null ? TransferPhase.complete : (w.sent == 0 ? TransferPhase.awaitingAcceptance : TransferPhase.running)),
      bytesDone: w.sent,
      bytesTotal: total,
      filesDone: w.finishedAt != null ? w.offer.files.length : 0,
      filesTotal: w.offer.files.length,
      filesVerified: 0,
      speed: speed,
      etaSeconds: speed > 0 ? (total - w.sent) / speed : null,
      path: const LinkPath(kind: PathKind.local, link: LinkKind.http),
      startedAt: w.startedAt,
      label: w.offer.label,
    );
  }

  // -------------------------------------------------------------------------
  // publishing

  void _publishTransfers() {
    final active = _jobs.values.any((o) => o.finishedAt == null) ||
        _incoming.values.any((i) => i.finishedAt == null) ||
        _webOut.values.any((w) => w.finishedAt == null && w.sent > 0);
    if (!_dirty && !active) return;
    _dirty = false;
    final list = <TransferSnapshot>[
      for (final o in _jobs.values)
        if (!_dismissed.contains(o.job.id)) _outgoingSnapshot(o),
      for (final i in _incoming.values)
        if (!_dismissed.contains(i.id)) _incomingSnapshot(i),
      for (final w in _webOut.values)
        if (!_dismissed.contains(w.offer.transferId)) _webSnapshot(w),
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
      location: locationLabel,
      savedMedia: _savedCounts(t).$1,
      savedOther: _savedCounts(t).$2,
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
    _publishJoins();
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
        // Browser guests live in the web pairing store, not here.
        for (final d in _devices.values.where((d) => !d.id.startsWith('web:')))
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
              savedMedia: (j['savedMedia'] as num?)?.toInt() ?? 0,
              savedOther: (j['savedOther'] as num?)?.toInt() ?? 0,
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
            'savedMedia': r.savedMedia,
            'savedOther': r.savedOther,
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

class _WebOutgoing {
  _WebOutgoing(this.offer, this.device, this.startedAt);
  final WebOffer offer;
  final Device device;
  final DateTime startedAt;
  final meter = SpeedMeter(now: () => DateTime.now().microsecondsSinceEpoch / 1000);
  int sent = 0;
  int lastSent = 0;
  int total = 0;
  DateTime? finishedAt;
  bool cancelled = false;
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

/// Private IPv4 addresses of this machine with a label each, best first, as reachable from
/// another device on the same network. On phones the platform layer says which link is
/// Wi-Fi, hotspot, mobile data or VPN (see `NetBridge.kt`); elsewhere names decide.
/// Windows keeps a disconnected adapter's last address (a dropped hotspot still shows
/// 172.20.10.x), so those adapters are skipped there.
Future<List<(String, String)>> _localAddresses(PlatformBridge? bridge, {void Function(List<NetIface>)? onRaw}) async {
  try {
    var all = <NetIface>[];
    if (bridge != null) {
      try {
        final raw = await bridge.call('interfaces');
        if (raw is List) all = [for (final m in raw) if (m is Map) NetIface.fromMap(m)];
      } catch (_) {}
    }
    if (all.isEmpty) {
      final down = Platform.isWindows ? await _windowsDisconnected() : const <String>{};
      for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
        if (down.contains(i.name.toLowerCase())) continue;
        for (final a in i.addresses) {
          all.add(NetIface(name: i.name, address: a.address, kind: kindFromName(i.name)));
        }
      }
    }
    onRaw?.call(all);
    final ranked = reachable(all);
    netLog('interfaces=${all.map((i) => '$i').join(', ')} -> offered=${ranked.map((i) => i.address).join(', ')}');
    return [for (final i in ranked) (i.address, kindLabel(i))];
  } catch (_) {
    return const [];
  }
}

/// Lower-cased names of adapters Windows reports as disconnected.
Future<Set<String>> _windowsDisconnected() async {
  try {
    final r = await Process.run('netsh', ['interface', 'ipv4', 'show', 'interfaces']);
    final out = <String>{};
    for (final line in const LineSplitter().convert(r.stdout as String)) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length < 5 || int.tryParse(parts[0]) == null) continue;
      if (parts[3].toLowerCase() == 'disconnected') out.add(parts.sublist(4).join(' ').toLowerCase());
    }
    return out;
  } catch (_) {
    return const {};
  }
}
