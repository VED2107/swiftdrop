import 'dart:async';
import 'dart:isolate';

/// A call into the platform layer (Kotlin / Swift) from the engine isolate. The engine
/// stays pure Dart: the app owns the real MethodChannel on the UI isolate and serves
/// these calls through a [BridgeHost]; the engine isolate only holds a [PortBridge].
abstract interface class PlatformBridge {
  Future<Object?> call(String method, [Map<String, Object?> args = const {}]);
}

class BridgeException implements Exception {
  BridgeException(this.code, [this.message]);
  final String code;
  final String? message;

  @override
  String toString() => 'BridgeException($code${message == null ? '' : ': $message'})';
}

typedef BridgeHandler = Future<Object?> Function(String method, Map<String, Object?> args);

/// UI-isolate side: answers engine calls with [handler].
class BridgeHost {
  BridgeHost(this.handler) {
    _port.listen((m) async {
      final (SendPort reply, String method, Map<String, Object?> args) = m as (SendPort, String, Map<String, Object?>);
      try {
        reply.send((true, await handler(method, args)));
      } on BridgeException catch (e) {
        reply.send((false, '${e.code}|${e.message ?? ''}'));
      } catch (e) {
        reply.send((false, 'error|$e'));
      }
    });
  }

  final BridgeHandler handler;
  final _port = ReceivePort('swiftdrop-bridge');

  /// Hand this to the engine (it crosses the isolate boundary).
  SendPort get sendPort => _port.sendPort;

  void close() => _port.close();
}

/// Engine-isolate side.
class PortBridge implements PlatformBridge {
  PortBridge(this._host);
  final SendPort _host;

  @override
  Future<Object?> call(String method, [Map<String, Object?> args = const {}]) {
    final reply = ReceivePort();
    final done = Completer<Object?>();
    reply.listen((m) {
      final (bool ok, Object? v) = m as (bool, Object?);
      reply.close();
      if (ok) {
        done.complete(v);
      } else {
        final s = '$v';
        final i = s.indexOf('|');
        done.completeError(BridgeException(i < 0 ? 'error' : s.substring(0, i), i < 0 ? s : s.substring(i + 1)));
      }
    });
    _host.send((reply.sendPort, method, args));
    return done.future;
  }
}
