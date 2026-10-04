import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../protocol/constants.dart';
import '../protocol/errors.dart';
import '../util/sanitize.dart';
import 'web_auth.dart';
import 'zip.dart';

/// Serves SwiftDrop's browser client to phones without the app (an iPhone's Safari) and
/// answers the guest half of the PC server's API, so the same web client works against
/// this app on Windows or Android exactly as it does against the Node server:
///
///   GET  /api/ping, /api/info               reachability, who am I
///   POST /api/join, GET /api/join/:id        pairing (approved on this device)
///   PATCH /api/device                        a phone renames itself
///   POST /api/transfers, GET/DELETE …/:id    phone → this device (the engine's receiver)
///   PUT  …/files/:id/blocks/:n, POST …/batch, POST …/files/:id/complete
///   GET  /api/offers, POST …/:id/ticket      this device → phone
///   GET  /api/offers/:id/files/:id, …/zip    downloads (ranges; ZIP with exact length)
///   WS   /api/events                         offers + pong (control plane only)
///
/// Host-only routes don't exist here: this device's own UI is native. Requests from a
/// browser on this same machine are guests like any other.
///
/// File bytes go phone → here over plain HTTP on the LAN, verified per block by the
/// receiver; no cloud, no relay.
class WebOfferFile {
  const WebOfferFile({required this.id, required this.name, required this.relDir, required this.size, required this.type, required this.path, required this.modified});
  final String id;
  final String name;
  final String relDir;
  final int size;
  final String type;
  final String path;
  final DateTime modified;

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'relDir': relDir, 'size': size, 'type': type};
}

class WebOffer {
  WebOffer({required this.transferId, required this.label, required this.files, int? createdAt}) : createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch;
  final String transferId;
  final String label;
  final int createdAt;
  final List<WebOfferFile> files;
  int get totalBytes => files.fold(0, (s, f) => s + f.size);

  Map<String, Object?> toJson() => {'transferId': transferId, 'label': label, 'createdAt': createdAt, 'totalBytes': totalBytes, 'files': [for (final f in files) f.toJson()]};
}

/// What the host runtime plugs in.
class WebHostDelegate {
  const WebHostDelegate({required this.receive, this.onJoin, this.onDevices, this.onDownload, this.folderName});

  /// An engine receiver call (`create`, `status`, `blocks`, `batch`, `complete`, `cancel`)
  /// on behalf of a paired browser.
  final Future<Object?> Function(String op, Map<String, Object?> args, Uint8List body, WebDevice device) receive;

  /// A browser asks to pair; approve or deny with [WebHost.resolveJoin].
  final void Function(WebJoin join)? onJoin;

  /// Paired devices or their online state changed.
  final void Function()? onDevices;

  /// Download progress of an offer (bytes sent so far of [total]).
  final void Function(WebOffer offer, int sent, int total, WebDevice? device)? onDownload;

  /// Folder name (never the full path) shown to the phone.
  final String Function()? folderName;
}

class WebHost {
  WebHost._(this.auth, this.webRoot, this.delegate, this.version, this._server);

  static const defaultPort = 8787;
  static const _wsSubprotocol = 'swiftdrop.v1';
  static const _wsAuthPrefix = 'auth.';
  static const _maxManifestJson = 8 << 20;
  static const _csp = "default-src 'self'; img-src 'self' blob: data:; media-src 'self' blob:; style-src 'self' 'unsafe-inline'; font-src 'self'; "
      "connect-src 'self' ws: wss:; worker-src 'self' blob:; script-src 'self' 'wasm-unsafe-eval'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'";

  final WebAuth auth;

  /// Built web client (`apps/web/dist`): index.html + assets.
  final String webRoot;
  final WebHostDelegate delegate;
  final String version;
  final HttpServer _server;
  final _offers = <String, WebOffer>{};
  final _clients = <_Client>{};
  final _dlEmit = <String, int>{};

  int get port => _server.port;

  static Future<WebHost> start({
    required WebAuth auth,
    required String webRoot,
    required WebHostDelegate delegate,
    String version = '0.0.0',
    int port = defaultPort,
    InternetAddress? address,
  }) async {
    final bind = address ?? InternetAddress.anyIPv4;
    HttpServer server;
    try {
      server = await HttpServer.bind(bind, port);
    } on SocketException {
      server = await HttpServer.bind(bind, 0);
    }
    server.autoCompress = false;
    server.idleTimeout = const Duration(seconds: 30);
    final host = WebHost._(auth, webRoot, delegate, version, server);
    server.listen(host._handle, onError: (_) {});
    return host;
  }

  Future<void> close() async {
    for (final c in _clients.toList()) {
      await c.ws.close();
    }
    await _server.close(force: true);
  }

  /// The link a phone's camera opens, for a given LAN address of this device.
  String pairUrl(String address) => 'http://$address:$port/#p=${auth.currentPairing().token}';
  String manualUrl(String address) => 'http://$address:$port';

  void resolveJoin(String id, bool approve) {
    auth.resolveJoin(id, approve);
    if (approve) delegate.onDevices?.call();
  }

  void forget(String deviceId) {
    auth.forget(deviceId);
    for (final c in _clients.where((c) => c.deviceId == deviceId).toList()) {
      unawaited(c.ws.close(4001, 'forgotten'));
    }
    delegate.onDevices?.call();
  }

  // ---- offers (this device -> phones) ---------------------------------------------

  List<WebOffer> get offers => _offers.values.toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  void addOffer(WebOffer offer) {
    _offers[offer.transferId] = offer;
    _broadcast({'t': 'offers', 'offers': [for (final o in offers) o.toJson()]});
  }

  void removeOffer(String transferId) {
    if (_offers.remove(transferId) == null) return;
    _broadcast({'t': 'offers', 'offers': [for (final o in offers) o.toJson()]});
  }

  // ---------------------------------------------------------------------------

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    try {
      if (path == '/api/events') return await _events(req);
      if (!path.startsWith('/api/')) return await _static(req, path);
      if (req.method != 'GET' && req.method != 'HEAD' && !_originOk(req)) throw ProtocolException(ErrorCode.forbidden, 'bad origin');
      await _api(req, path);
    } catch (e) {
      final code = e is ProtocolException ? e.code : ErrorCode.server;
      final status = switch (code) {
        ErrorCode.unauthorized => 401,
        ErrorCode.forbidden => 403,
        ErrorCode.notFound => 404,
        ErrorCode.pairingExpired => 410,
        ErrorCode.rateLimited => 429,
        ErrorCode.tooLarge => 413,
        ErrorCode.badRequest || ErrorCode.badFrame || ErrorCode.integrity || ErrorCode.incomplete || ErrorCode.nameTaken => 400,
        ErrorCode.diskFull => 507,
        _ => 500,
      };
      try {
        _json(req.response, status, {'code': code.wire});
      } catch (_) {
        // headers already sent (a stream broke mid-download)
        await req.response.close().catchError((_) {});
      }
    }
  }

  bool _originOk(HttpRequest req) {
    final origin = req.headers.value('origin');
    if (origin == null) return true;
    return origin == 'http://${req.headers.value('host')}';
  }

  WebDevice? _who(HttpRequest req) {
    final a = req.headers.value('authorization');
    if (a == null || !a.startsWith('Bearer ')) return null;
    return auth.authenticate(a.substring(7).trim());
  }

  WebDevice _need(HttpRequest req) => _who(req) ?? (throw ProtocolException(ErrorCode.unauthorized));

  String _ip(HttpRequest req) => req.connectionInfo?.remoteAddress.address ?? '';

  Future<void> _api(HttpRequest req, String path) async {
    final seg = path.substring(5).split('/'); // after "/api/"
    final m = req.method == 'HEAD' ? 'GET' : req.method;
    final res = req.response;

    switch ((m, seg)) {
      case ('GET', ['ping']):
        res.statusCode = 204;
        return res.close();
      case ('GET', ['info']):
        final d = _who(req);
        return _json(res, 200, {
          'role': d == null ? null : 'guest',
          'deviceId': d?.id,
          'deviceName': d?.name,
          'folderName': d == null ? null : delegate.folderName?.call(),
          'version': version,
          'protocol': protocolVersion,
        });
      case ('POST', ['join']):
        final body = await _readJson(req, 4096);
        final join = auth.requestJoin(
          token: body['token'] as String?,
          code: body['code'] as String?,
          deviceName: '${body['deviceName'] ?? ''}',
          installId: body['installId'] as String?,
          ip: _ip(req),
        );
        delegate.onJoin?.call(join);
        return _json(res, 202, {'requestId': join.id});
      case ('GET', ['join', final id]):
        return _json(res, 200, auth.pollJoin(id, _ip(req)));
      case ('PATCH', ['device']):
        final d = _need(req);
        final body = await _readJson(req, 1024);
        final renamed = auth.rename(d.id, '${body['name'] ?? ''}');
        delegate.onDevices?.call();
        return _json(res, 200, {'id': renamed.id, 'name': renamed.name, 'online': auth.isOnline(renamed.id), 'pairedAt': renamed.pairedAt});
      case ('GET', ['stats']):
        _need(req);
        return _json(res, 200, {'cpuUserMs': 0, 'cpuSystemMs': 0, 'rss': ProcessInfo.currentRss, 'writeLoad': 0});

      // phone -> this device
      case ('POST', ['transfers']):
        final d = _need(req);
        final manifest = await _readJson(req, _maxManifestJson);
        if (manifest['direction'] != 'to-host' && manifest['bench'] != true) throw ProtocolException(ErrorCode.forbidden);
        final r = await delegate.receive('create', manifest, Uint8List(0), d);
        final status = r is Map ? r['status'] : null;
        return _json(res, 200, status ?? r);
      case ('GET', ['transfers', final id]):
        final d = _need(req);
        return _json(res, 200, await delegate.receive('status', {'transferId': id}, Uint8List(0), d));
      case ('PUT', ['transfers', final id, 'files', final fileId, 'blocks', final n]):
        final d = _need(req);
        final start = int.tryParse(n) ?? (throw ProtocolException(ErrorCode.badRequest));
        final body = await _readBody(req, maxBlocksPerChunk * blockSize);
        await delegate.receive('blocks', {'transferId': id, 'fileId': fileId, 'start': start, 'hashes': req.headers.value('x-sd-hashes') ?? ''}, body, d);
        res.statusCode = 204;
        res.headers.set('x-sd-load', '0.00');
        return res.close();
      case ('POST', ['transfers', final id, 'batch']):
        final d = _need(req);
        final body = await _readBody(req, batchTargetBytes + (2 << 20));
        await delegate.receive('batch', {'transferId': id}, body, d);
        res.statusCode = 204;
        res.headers.set('x-sd-load', '0.00');
        return res.close();
      case ('POST', ['transfers', final id, 'files', final fileId, 'complete']):
        final d = _need(req);
        final body = await _readJson(req, 1024);
        return _json(res, 200, await delegate.receive('complete', {'transferId': id, 'fileId': fileId, 'root': body['root']}, Uint8List(0), d));
      case ('DELETE', ['transfers', final id]):
        final d = _need(req);
        if (_offers.containsKey(id)) {
          // A phone dismissing an offer it doesn't want: hide it for everyone.
          removeOffer(id);
        } else {
          await delegate.receive('cancel', {'transferId': id}, Uint8List(0), d);
        }
        return _json(res, 200, {'ok': true});

      // this device -> phone
      case ('GET', ['offers']):
        _need(req);
        return _json(res, 200, {'offers': [for (final o in offers) o.toJson()]});
      case ('POST', ['offers', final id, 'ticket']):
        _need(req);
        if (!_offers.containsKey(id)) throw ProtocolException(ErrorCode.notFound);
        return _json(res, 200, {'ticket': auth.signTicket('offer:$id')});
      case ('GET', ['offers', final id, 'files', final fileId]):
        final d = _offerAccess(req, id);
        final o = _offers[id]!;
        final f = o.files.firstWhere((f) => f.id == fileId, orElse: () => throw ProtocolException(ErrorCode.notFound));
        return _sendFile(req, o, f, d);
      case ('GET', ['offers', final id, 'zip']):
        final d = _offerAccess(req, id);
        return _sendZip(req, _offers[id]!, d);
    }
    throw ProtocolException(ErrorCode.notFound);
  }

  /// A paired browser (bearer) or a ticket from one (Safari navigations can't add headers).
  WebDevice? _offerAccess(HttpRequest req, String id) {
    if (!_offers.containsKey(id)) throw ProtocolException(ErrorCode.notFound);
    final d = _who(req);
    if (d != null) return d;
    if (!auth.verifyTicket('offer:$id', req.uri.queryParameters['ticket'])) throw ProtocolException(ErrorCode.unauthorized);
    return null;
  }

  Future<void> _sendFile(HttpRequest req, WebOffer o, WebOfferFile f, WebDevice? d) async {
    final res = req.response;
    final file = File(f.path);
    final size = file.lengthSync();
    if (size != f.size) throw ProtocolException(ErrorCode.sourceChanged);
    final range = _parseRange(req.headers.value('range'), size);
    res.headers
      ..set('content-type', _safeMime(f.type))
      ..set('content-disposition', _disposition(f.name))
      ..set('accept-ranges', 'bytes')
      ..set('cache-control', 'no-store');
    if (range == _invalid) {
      res.statusCode = 416;
      res.headers.set('content-range', 'bytes */$size');
      return res.close();
    }
    final (start, end) = range ?? (0, size - 1);
    res.contentLength = size == 0 ? 0 : end - start + 1;
    if (range != null) {
      res.statusCode = 206;
      res.headers.set('content-range', 'bytes $start-$end/$size');
    }
    if (req.method == 'HEAD' || size == 0) return res.close();
    var sent = start;
    await res.addStream(file.openRead(start, end + 1).map((c) {
      sent += c.length;
      _progress(o, sent, size, d);
      return c;
    }));
    await res.close();
  }

  Future<void> _sendZip(HttpRequest req, WebOffer o, WebDevice? d) async {
    final res = req.response;
    final used = <String>{};
    final entries = <ZipEntry>[];
    for (final f in o.files) {
      final st = File(f.path).statSync();
      if (st.type != FileSystemEntityType.file || st.size != f.size) throw ProtocolException(ErrorCode.sourceChanged);
      var name = [if (f.relDir.isNotEmpty) f.relDir, f.name].join('/');
      for (var n = 2; used.contains(name.toLowerCase()); n++) {
        final dot = f.name.lastIndexOf('.');
        name = dot > 0 ? '${f.name.substring(0, dot)} ($n)${f.name.substring(dot)}' : '${f.name} ($n)';
      }
      used.add(name.toLowerCase());
      entries.add(ZipEntry(name: name, path: f.path, size: f.size, mtime: f.modified));
    }
    final total = zipLength(entries);
    res.headers
      ..set('content-type', 'application/zip')
      ..set('content-disposition', _disposition('${sanitizeFileName(o.label.isEmpty ? 'SwiftDrop' : o.label)}.zip'))
      ..set('cache-control', 'no-store');
    res.contentLength = total;
    if (req.method == 'HEAD') return res.close();
    var sent = 0;
    await writeZip(entries, res, onBytes: (n) {
      sent += n;
      _progress(o, sent, total, d);
    });
    await res.close();
  }

  void _progress(WebOffer o, int sent, int total, WebDevice? d) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (sent < total && now - (_dlEmit[o.transferId] ?? 0) < 250) return;
    _dlEmit[o.transferId] = now;
    delegate.onDownload?.call(o, sent, total, d);
  }

  // ---- events ------------------------------------------------------------------

  Future<void> _events(HttpRequest req) async {
    if (!WebSocketTransformer.isUpgradeRequest(req)) throw ProtocolException(ErrorCode.badRequest);
    final protocols = (req.headers.value('sec-websocket-protocol') ?? '').split(',').map((s) => s.trim()).toList();
    if (!protocols.contains(_wsSubprotocol)) throw ProtocolException(ErrorCode.badRequest);
    final token = protocols.firstWhere((s) => s.startsWith(_wsAuthPrefix), orElse: () => '');
    final d = token.isEmpty ? null : auth.authenticate(token.substring(_wsAuthPrefix.length));
    if (d == null) throw ProtocolException(ErrorCode.unauthorized);
    final ws = await WebSocketTransformer.upgrade(req, protocolSelector: (_) => _wsSubprotocol);
    final c = _Client(ws, d.id);
    _clients.add(c);
    auth.setOnline(d.id, 1);
    delegate.onDevices?.call();
    void send(Map<String, Object?> e) => ws.add(jsonEncode(e));
    send({'t': 'hello', 'role': 'guest', 'deviceId': d.id});
    send({'t': 'offers', 'offers': [for (final o in offers) o.toJson()]});
    ws.listen(
      (raw) {
        if (raw is! String || raw.length > 4096) return;
        try {
          final msg = jsonDecode(raw);
          if (msg is Map && msg['t'] == 'ping' && msg['n'] is num) send({'t': 'pong', 'n': msg['n']});
        } catch (_) {
          // junk
        }
      },
      onDone: () {
        _clients.remove(c);
        auth.setOnline(d.id, -1);
        delegate.onDevices?.call();
      },
      onError: (_) {},
      cancelOnError: true,
    );
  }

  void _broadcast(Map<String, Object?> e) {
    final payload = jsonEncode(e);
    for (final c in _clients) {
      c.ws.add(payload);
    }
  }

  // ---- static web client --------------------------------------------------------

  Future<void> _static(HttpRequest req, String path) async {
    if (req.method != 'GET' && req.method != 'HEAD') throw ProtocolException(ErrorCode.notFound);
    final root = p.normalize(p.absolute(webRoot));
    var rel = Uri.decodeComponent(path);
    if (rel == '/' || rel.isEmpty) rel = '/index.html';
    var file = File(p.normalize(p.join(root, rel.substring(1))));
    if (!p.isWithin(root, file.path) || !file.existsSync()) file = File(p.join(root, 'index.html'));
    if (!file.existsSync()) {
      req.response.statusCode = 503;
      req.response.headers.contentType = ContentType.text;
      req.response.write('SwiftDrop web client is missing from this build.');
      return req.response.close();
    }
    final res = req.response;
    final immutable = file.path.contains('${p.separator}assets${p.separator}');
    res.headers
      ..set('content-type', _mimeFor(file.path))
      ..set('cache-control', immutable ? 'public, max-age=31536000, immutable' : 'no-cache')
      ..set('content-security-policy', _csp)
      ..set('x-frame-options', 'DENY')
      ..set('x-content-type-options', 'nosniff')
      ..set('referrer-policy', 'no-referrer');
    res.contentLength = file.lengthSync();
    if (req.method == 'HEAD') return res.close();
    await res.addStream(file.openRead());
    await res.close();
  }

  // ---- helpers ------------------------------------------------------------------

  void _json(HttpResponse res, int status, Object? body) {
    res.statusCode = status;
    res.headers
      ..contentType = ContentType.json
      ..set('cache-control', 'no-store');
    res.write(jsonEncode(body));
    unawaited(res.close().catchError((_) {}));
  }

  Future<Uint8List> _readBody(HttpRequest req, int max) async {
    final declared = req.contentLength;
    if (declared > max) throw ProtocolException(ErrorCode.tooLarge);
    final b = BytesBuilder(copy: false);
    await for (final chunk in req) {
      b.add(chunk);
      if (b.length > max) throw ProtocolException(ErrorCode.tooLarge);
    }
    return b.takeBytes();
  }

  Future<Map<String, Object?>> _readJson(HttpRequest req, int max) async {
    final bytes = await _readBody(req, max);
    try {
      final v = jsonDecode(utf8.decode(bytes));
      if (v is Map<String, Object?>) return v;
    } catch (_) {
      // fall through
    }
    throw ProtocolException(ErrorCode.badRequest, 'bad json');
  }
}

class _Client {
  _Client(this.ws, this.deviceId);
  final WebSocket ws;
  final String deviceId;
}

const _invalid = (-1, -1);

(int, int)? _parseRange(String? h, int size) {
  if (h == null) return null;
  final m = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(h.trim());
  if (m == null) return null;
  final a = m.group(1)!, b = m.group(2)!;
  if (a.isEmpty && b.isEmpty) return _invalid;
  int start, end;
  if (a.isEmpty) {
    final n = int.parse(b);
    if (n == 0) return _invalid;
    start = size - n < 0 ? 0 : size - n;
    end = size - 1;
  } else {
    start = int.parse(a);
    end = b.isEmpty ? size - 1 : int.parse(b);
    if (end >= size) end = size - 1;
  }
  if (start > end || start >= size) return _invalid;
  return (start, end);
}

String _disposition(String name) {
  final ascii = name.replaceAll(RegExp(r'[^\x20-\x7e]'), '_').replaceAll('"', "'");
  return 'attachment; filename="$ascii"; filename*=UTF-8\'\'${Uri.encodeComponent(name)}';
}

/// Never let a download be rendered as active content in the browser.
String _safeMime(String type) {
  final t = type.toLowerCase();
  if (t.isEmpty || t.contains('html') || t.contains('xml') || t.contains('javascript') || t.contains('svg')) return 'application/octet-stream';
  return t;
}

String _mimeFor(String path) => switch (p.extension(path).toLowerCase()) {
      '.html' => 'text/html; charset=utf-8',
      '.js' => 'text/javascript; charset=utf-8',
      '.css' => 'text/css; charset=utf-8',
      '.svg' => 'image/svg+xml',
      '.png' => 'image/png',
      '.ico' => 'image/x-icon',
      '.webmanifest' => 'application/manifest+json',
      '.woff2' => 'font/woff2',
      '.woff' => 'font/woff',
      '.json' => 'application/json',
      '.wasm' => 'application/wasm',
      _ => 'application/octet-stream',
    };
