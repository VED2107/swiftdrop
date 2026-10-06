import 'dart:async';
import 'dart:isolate';

import '../platform/destination.dart';
import '../platform/files.dart';
import '../protocol/errors.dart';
import '../services/models.dart';
import '../services/services.dart';
import '../transport/engine_transport.dart';
import 'engine_runtime.dart';

/// Runs [EngineRuntime] in its own isolate and exposes it to the app as the three
/// application services. Everything that touches sockets and files happens over there;
/// this side only holds the latest published values (≤ 10 transfer updates/s).
class EngineHost implements DeviceDirectory {
  EngineHost._(this._isolate, this._commands, this._events);

  static Future<EngineHost> spawn(EngineConfig config) async {
    final events = ReceivePort();
    final ready = Completer<SendPort>();
    final startError = Completer<Object>();
    late final EngineHost host;
    events.listen((m) {
      if (m is SendPort) {
        ready.complete(m);
      } else if (m is (String, Object?)) {
        if (m.$1 == 'fatal' && !ready.isCompleted) {
          startError.complete(m.$2 ?? 'engine failed to start');
        } else if (ready.isCompleted) {
          host._onEvent(m.$1, m.$2);
        }
      }
    });
    final iso = await Isolate.spawn(_engineMain, (events.sendPort, config), debugName: 'swiftdrop-engine', errorsAreFatal: false);
    final commands = await Future.any([ready.future, startError.future.then<SendPort>((e) => throw StateError('$e'))]);
    host = EngineHost._(iso, commands, events);
    return host;
  }

  final Isolate _isolate;
  final SendPort _commands;
  final ReceivePort _events;
  final _replies = <int, Completer<Object?>>{};
  int _next = 1;

  final _devices = _Latest<List<Device>>(const []);
  final _endpoint = _Latest<LocalEndpoint?>(null);
  final _transfers = _Latest<List<TransferSnapshot>>(const []);
  final _offers = _Latest<List<IncomingOffer>>(const []);
  final _history = _Latest<List<TransferRecord>>(const []);
  final _joins = _Latest<List<BrowserJoin>>(const []);

  void _onEvent(String topic, Object? value) {
    switch (topic) {
      case 'reply':
        final (id, ok, v) = value! as (int, bool, Object?);
        final c = _replies.remove(id);
        if (c == null) return;
        ok ? c.complete(v) : c.completeError(TransportException(ErrorCode.fromWire(v as String?)));
      case 'devices':
        _devices.set(value! as List<Device>);
      case 'endpoint':
        _endpoint.set(value as LocalEndpoint?);
      case 'transfers':
        _transfers.set(value! as List<TransferSnapshot>);
      case 'offers':
        _offers.set(value! as List<IncomingOffer>);
      case 'history':
        _history.set(value! as List<TransferRecord>);
      case 'joins':
        _joins.set(value! as List<BrowserJoin>);
    }
  }

  Future<T> _call<T>(String method, [List<Object?> args = const []]) {
    final id = _next++;
    final c = Completer<Object?>();
    _replies[id] = c;
    _commands.send((id, method, args));
    return c.future.then((v) => v as T);
  }

  // DeviceDirectory
  @override
  Stream<List<Device>> watch() => _devices.stream;
  @override
  Stream<LocalEndpoint?> endpoint() => _endpoint.stream;
  @override
  Future<Device> connect(String address) => _call('connect', [address]);
  @override
  Future<Device> connectAny(List<String> addresses, {String? deviceId}) => _call('connectAny', [addresses, deviceId]);
  @override
  Future<void> rename(String deviceId, String name) => _call('rename', [deviceId, name]);
  @override
  Future<void> forget(String deviceId) => _call('forget', [deviceId]);

  // Transfers and history (exposed through [transferService] and [history])
  Stream<List<TransferSnapshot>> transfers() => _transfers.stream;
  Stream<List<IncomingOffer>> incoming() => _offers.stream;
  Future<String> send(String deviceId, List<SendItem> items) => _call('send', [deviceId, items]);
  Future<void> accept(String transferId) => _call('accept', [transferId]);
  Future<void> decline(String transferId) => _call('decline', [transferId]);
  Future<void> pause(String transferId) => _call('pause', [transferId]);
  Future<void> resume(String transferId) => _call('resume', [transferId]);
  Future<void> cancel(String transferId) => _call('cancel', [transferId]);
  Future<void> dismiss(String transferId) => _call('dismiss', [transferId]);

  // TransferHistory
  Stream<List<TransferRecord>> records() => _history.stream;
  Future<void> remove(String transferId) => _call('removeHistory', [transferId]);
  Future<void> clear() => _call('clearHistory');

  // Browser guests (phones without the app)
  Stream<List<BrowserJoin>> joins() => _joins.stream;
  Future<void> resolveJoin(String id, bool approve) => _call('resolveJoin', [id, approve]);
  Future<void> rotateWebPairing() => _call('rotateWebPairing');

  // Settings
  Future<void> setName(String name) => _call('setName', [name]);
  Future<void> setDuplicates(DuplicatePolicy policy) => _call('setDuplicates', [policy]);
  Future<void> setDownloadDir(String dir) => _call('setDownloadDir', [dir]);
  Future<void> networkChanged() => _call('networkChanged');
  Future<String> diagnostics() => _call('diagnostics');
  Future<void> setDestination(SaveDestination d) => _call('setDestination', [d]);

  /// Views with the right `watch()` for each interface.
  late final TransferService transferService = _TransferView(this);
  late final TransferHistory history = _HistoryView(this);

  Future<void> shutdown() async {
    try {
      await _call<void>('stop').timeout(const Duration(seconds: 3));
    } catch (_) {}
    _isolate.kill(priority: Isolate.beforeNextEvent);
    _events.close();
  }
}

class _TransferView implements TransferService {
  _TransferView(this.h);
  final EngineHost h;
  @override
  Stream<List<TransferSnapshot>> watch() => h.transfers();
  @override
  Stream<List<IncomingOffer>> incoming() => h.incoming();
  @override
  Future<String> send(String deviceId, List<SendItem> items) => h.send(deviceId, items);
  @override
  Future<void> accept(String transferId) => h.accept(transferId);
  @override
  Future<void> decline(String transferId) => h.decline(transferId);
  @override
  Future<void> pause(String transferId) => h.pause(transferId);
  @override
  Future<void> resume(String transferId) => h.resume(transferId);
  @override
  Future<void> cancel(String transferId) => h.cancel(transferId);
  @override
  Future<void> dismiss(String transferId) => h.dismiss(transferId);
}

class _HistoryView implements TransferHistory {
  _HistoryView(this.h);
  final EngineHost h;
  @override
  Stream<List<TransferRecord>> watch() => h.records();
  @override
  Future<void> remove(String transferId) => h.remove(transferId);
  @override
  Future<void> clear() => h.clear();
}

/// A value stream that replays the latest value to each new listener.
class _Latest<T> {
  _Latest(this.value);
  T value;
  final _c = StreamController<T>.broadcast();
  void set(T v) {
    value = v;
    _c.add(v);
  }

  Stream<T> get stream async* {
    yield value;
    yield* _c.stream;
  }
}

Future<void> _engineMain((SendPort, EngineConfig) args) async {
  final (out, config) = args;
  final EngineRuntime rt;
  try {
    rt = await EngineRuntime.start(config);
  } catch (e) {
    out.send(('fatal', '$e'));
    return;
  }
  final inbox = ReceivePort();
  rt.devices.listen((v) => out.send(('devices', v)));
  rt.endpointStream.listen((v) => out.send(('endpoint', v)));
  rt.transfers.listen((v) => out.send(('transfers', v)));
  rt.offers.listen((v) => out.send(('offers', v)));
  rt.history.listen((v) => out.send(('history', v)));
  rt.joins.listen((v) => out.send(('joins', v)));
  out.send(inbox.sendPort);
  // Initial state for the host.
  out.send(('endpoint', rt.endpoint));
  rt.publishAll();

  await for (final m in inbox) {
    final (id, method, a) = m as (int, String, List<Object?>);
    Future<Object?> run() async {
      final Future<Object?> f = switch (method) {
          'connect' => rt.connect(a[0]! as String),
          'rename' => rt.rename(a[0]! as String, a[1]! as String).then<Object?>((_) => null),
          'forget' => rt.forget(a[0]! as String).then<Object?>((_) => null),
          'send' => rt.send(a[0]! as String, (a[1]! as List).cast<SendItem>()),
          'accept' => rt.accept(a[0]! as String).then<Object?>((_) => null),
          'decline' => rt.decline(a[0]! as String).then<Object?>((_) => null),
          'pause' => rt.pause(a[0]! as String).then<Object?>((_) => null),
          'resume' => rt.resume(a[0]! as String).then<Object?>((_) => null),
          'cancel' => rt.cancel(a[0]! as String).then<Object?>((_) => null),
          'dismiss' => rt.dismiss(a[0]! as String).then<Object?>((_) => null),
          'removeHistory' => rt.removeHistory(a[0]! as String).then<Object?>((_) => null),
          'clearHistory' => rt.clearHistory().then<Object?>((_) => null),
          'stop' => rt.stop().then<Object?>((_) => null),
          'setName' => rt.setName(a[0]! as String).then<Object?>((_) => null),
          'setDuplicates' => rt.setDuplicates(a[0]! as DuplicatePolicy).then<Object?>((_) => null),
          'connectAny' => rt.connectAny((a[0]! as List).cast<String>(), deviceId: a[1] as String?),
          'networkChanged' => rt.networkChanged().then<Object?>((_) => null),
          'diagnostics' => rt.diagnostics(),
          'setDestination' => rt.setDestination(a[0]! as SaveDestination).then<Object?>((_) => null),
          'setDownloadDir' => rt.setDownloadDir(a[0]! as String).then<Object?>((_) => null),
          'resolveJoin' => rt.resolveJoin(a[0]! as String, a[1]! as bool).then<Object?>((_) => null),
          'rotateWebPairing' => rt.rotateWebPairing().then<Object?>((_) => null),
          _ => Future<Object?>.error(TransportException(ErrorCode.badRequest, 'unknown $method')),
        };
      return f;
    }
    run().then(
      (v) => out.send(('reply', (id, true, v))),
      onError: (Object e) => out.send((
        'reply',
        (id, false, e is TransportException ? e.code.wire : (e is ProtocolException ? e.code.wire : ErrorCode.server.wire)),
      )),
    );
  }
}
