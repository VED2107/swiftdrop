import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../protocol/errors.dart';
import '../protocol/types.dart';
import '../transport/engine_transport.dart';
import '../protocol/constants.dart';
import '../util/base64url.dart';

/// The engine's transport over the browser-guest HTTP API: what the web client speaks to
/// the Node PC server and to [WebHost]. Port of `HttpTransport` in
/// `packages/transfer-engine/src/transport.ts`. Used by tests (a real job against the
/// host, byte-for-byte the requests Safari makes) and by the app to send to a PC that
/// runs the Node server.
class HttpEngineTransport implements EngineTransport {
  HttpEngineTransport(String baseUrl, {this.token, HttpClient? client})
      : _base = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl,
        _client = client ?? (HttpClient()..maxConnectionsPerHost = 6);

  final String _base;
  final String? token;
  final HttpClient _client;

  @override
  Future<CreateResult> create(Manifest manifest) async {
    final (status, body) = await _send('POST', '/api/transfers', json: manifest.toJson(), allow409: true);
    final j = jsonDecode(utf8.decode(body)) as Map<String, Object?>;
    if (status == 409) {
      return Conflicts([for (final c in j['conflicts']! as List<Object?>) Conflict.fromJson(c! as Map<String, Object?>)]);
    }
    return Created(TransferStatus.fromJson(j));
  }

  @override
  Future<TransferStatus> status(String transferId) async {
    final (_, body) = await _send('GET', '/api/transfers/$transferId');
    return TransferStatus.fromJson(jsonDecode(utf8.decode(body)) as Map<String, Object?>);
  }

  @override
  Future<ReceiverLoad> putBlocks(String transferId, String fileId, int startBlock, Uint8List body, Uint8List digests, CancelToken cancel) async {
    await _send('PUT', '/api/transfers/$transferId/files/$fileId/blocks/$startBlock',
        bytes: body, headers: {'x-sd-hashes': bytesToBase64Url(digests)}, cancel: cancel);
    return const ReceiverLoad(0);
  }

  @override
  Future<ReceiverLoad> putBatch(String transferId, Uint8List frame, CancelToken cancel) async {
    await _send('POST', '/api/transfers/$transferId/batch', bytes: frame, cancel: cancel);
    return const ReceiverLoad(0);
  }

  @override
  Future<String> complete(String transferId, String fileId, String root) async {
    final (_, body) = await _send('POST', '/api/transfers/$transferId/files/$fileId/complete', json: {'root': root});
    return (jsonDecode(utf8.decode(body)) as Map<String, Object?>)['finalName']! as String;
  }

  @override
  Future<void> cancel(String transferId) async {
    await _send('DELETE', '/api/transfers/$transferId');
  }

  @override
  Future<void> ping() async {
    await _send('GET', '/api/ping');
  }

  void close() => _client.close(force: true);

  Future<(int, Uint8List)> _send(
    String method,
    String path, {
    Object? json,
    Uint8List? bytes,
    Map<String, String> headers = const {},
    bool allow409 = false,
    CancelToken? cancel,
  }) async {
    if (cancel?.isCancelled ?? false) throw TransportException(ErrorCode.cancelled);
    HttpClientRequest? req;
    try {
      req = await _client.openUrl(method, Uri.parse('$_base$path'));
      req.headers.set('x-sd-protocol', '$protocolVersion');
      if (token != null) req.headers.set('authorization', 'Bearer $token');
      headers.forEach(req.headers.set);
      final payload = json != null ? utf8.encode(jsonEncode(json)) : bytes;
      if (json != null) req.headers.contentType = ContentType.json;
      if (bytes != null) req.headers.contentType = ContentType.binary;
      if (payload != null) {
        req.contentLength = payload.length;
        req.add(payload);
      }
      final pending = req;
      unawaited(cancel?.whenCancelled.then((_) => pending.abort()));
      final res = await req.close();
      final b = BytesBuilder(copy: false);
      await for (final c in res) {
        b.add(c);
      }
      final body = b.takeBytes();
      if (res.statusCode < 300 || (allow409 && res.statusCode == 409)) return (res.statusCode, body);
      var code = res.statusCode == 401 ? ErrorCode.unauthorized : (res.statusCode == 404 ? ErrorCode.notFound : ErrorCode.server);
      try {
        code = ErrorCode.fromWire((jsonDecode(utf8.decode(body)) as Map<String, Object?>)['code'] as String?);
      } catch (_) {}
      throw TransportException(code);
    } on TransportException {
      rethrow;
    } catch (e) {
      if (cancel?.isCancelled ?? false) throw TransportException(ErrorCode.cancelled);
      throw TransportException(ErrorCode.network, '$e');
    }
  }
}
