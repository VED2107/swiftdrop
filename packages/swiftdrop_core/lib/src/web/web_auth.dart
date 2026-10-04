import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../protocol/errors.dart';
import '../util/base64url.dart';
import '../util/random.dart';

/// Pairing and authentication for browser guests (an iPhone's Safari). Port of
/// `apps/server/src/auth.ts`, same rules:
///
/// - The app shows a pairing token (QR, 128-bit) and a 6-character code (typed fallback).
///   Both expire and rotate after every successful pairing.
/// - A join creates a pending request; nothing is granted until the person at this device
///   approves it.
/// - Approved browsers get a 256-bit bearer token. Only its SHA-256 is stored.
/// - Code guessing is rate-limited per address and globally.
class WebPairing {
  const WebPairing({required this.token, required this.code, required this.expiresAt});
  final String token;
  final String code;
  final int expiresAt;
}

enum JoinStatus { pending, approved, denied }

class WebJoin {
  WebJoin({required this.id, required this.deviceName, required this.via, required this.ip, required this.createdAt, this.installHash, this.returning = false});
  final String id;
  final String deviceName;
  final String via; // "qr" | "code"
  final String ip;
  final int createdAt;
  final String? installHash;
  final bool returning;
  JoinStatus status = JoinStatus.pending;
  String? deviceToken;
  String? deviceId;
}

class WebDevice {
  WebDevice({required this.id, required this.name, required this.tokenHash, required this.pairedAt, required this.lastSeen, this.installHash});
  final String id;
  String name;
  String tokenHash;
  final int pairedAt;
  int lastSeen;
  String? installHash;

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'tokenHash': tokenHash,
        'pairedAt': pairedAt,
        'lastSeen': lastSeen,
        if (installHash != null) 'installHash': installHash,
      };

  static WebDevice fromJson(Map<String, Object?> j) => WebDevice(
        id: j['id']! as String,
        name: j['name']! as String,
        tokenHash: j['tokenHash']! as String,
        pairedAt: (j['pairedAt']! as num).toInt(),
        lastSeen: (j['lastSeen']! as num).toInt(),
        installHash: j['installHash'] as String?,
      );
}

const _codeAlphabet = '23456789ABCDEFGHJKMNPQRSTUVWXYZ';
const _joinTtlMs = 2 * 60 * 1000;

class WebAuth {
  WebAuth(this.stateDir, {this.pairingTtl = const Duration(minutes: 10), this.deviceIdleTtl = const Duration(days: 30)}) {
    _secret = _loadSecret();
    _loadDevices();
  }

  final String stateDir;
  final Duration pairingTtl;
  final Duration deviceIdleTtl;
  late final List<int> _secret;
  WebPairing? _pairing;
  final _joins = <String, WebJoin>{};
  final _devices = <String, WebDevice>{};
  final _byTokenHash = <String, WebDevice>{};
  final _limiter = _RateLimiter();
  final _online = <String, int>{};

  int get _now => DateTime.now().millisecondsSinceEpoch;

  WebPairing currentPairing() {
    final p = _pairing;
    if (p == null || p.expiresAt <= _now) return rotatePairing();
    return p;
  }

  WebPairing rotatePairing() {
    final code = StringBuffer();
    final limit = 256 - (256 % _codeAlphabet.length);
    while (code.length < 6) {
      for (final b in randomBytes(12)) {
        if (b < limit && code.length < 6) code.write(_codeAlphabet[b % _codeAlphabet.length]);
      }
    }
    return _pairing = WebPairing(token: bytesToBase64Url(randomBytes(16)), code: code.toString(), expiresAt: _now + pairingTtl.inMilliseconds);
  }

  WebJoin requestJoin({String? token, String? code, required String deviceName, String? installId, required String ip}) {
    _limiter.hit('join:$ip', 20, 60000);
    final p = _pairing;
    final now = _now;
    final String via;
    if (token != null && token.isNotEmpty) {
      if (p == null || p.expiresAt <= now || !_safeEqual(token, p.token)) {
        _limiter.hit('fail:$ip', 8, 60000);
        throw ProtocolException(ErrorCode.pairingExpired);
      }
      via = 'qr';
    } else if (code != null && code.isNotEmpty) {
      _limiter.hit('code:$ip', 6, 60000);
      _limiter.hit('code:*', 30, 60000);
      final c = code.toUpperCase().replaceAll(RegExp('[^A-Z0-9]'), '');
      if (p == null || p.expiresAt <= now || !_safeEqual(c, p.code)) throw ProtocolException(ErrorCode.pairingExpired);
      via = 'code';
    } else {
      throw ProtocolException(ErrorCode.badRequest);
    }
    _gcJoins();
    var name = deviceName.replaceAll(_controlChars, '');
    if (name.length > 64) name = name.substring(0, 64);
    if (name.isEmpty) name = 'Device';
    for (final j in _joins.values) {
      if (j.ip == ip && j.deviceName == name && j.status == JoinStatus.pending) return j;
    }
    if (_joins.values.where((j) => j.ip == ip && j.status == JoinStatus.pending).length >= 3) {
      throw ProtocolException(ErrorCode.rateLimited);
    }
    final installHash = installId != null && RegExp(r'^[A-Za-z0-9_-]{16,64}$').hasMatch(installId) ? _sha256('install:$installId') : null;
    final previous = _sameDevice(installHash, name);
    final join = WebJoin(
      id: randomId(16),
      deviceName: previous?.name ?? name,
      via: via,
      ip: ip,
      createdAt: now,
      installHash: installHash,
      returning: previous != null,
    );
    _joins[join.id] = join;
    return join;
  }

  WebJoin resolveJoin(String id, bool approve) {
    final join = _joins[id];
    if (join == null || join.status != JoinStatus.pending) throw ProtocolException(ErrorCode.notFound);
    if (!approve) {
      join.status = JoinStatus.denied;
      return join;
    }
    final token = bytesToBase64Url(randomBytes(32));
    final previous = _sameDevice(join.installHash, join.deviceName);
    final WebDevice device;
    if (previous != null) {
      // Same browser pairing again: one entry, fresh token, old one revoked.
      _byTokenHash.remove(previous.tokenHash);
      previous.tokenHash = _sha256(token);
      previous.lastSeen = _now;
      if (join.installHash != null) previous.installHash = join.installHash;
      device = previous;
    } else {
      device = WebDevice(id: 'dv_${randomId(12)}', name: _uniqueName(join.deviceName), tokenHash: _sha256(token), pairedAt: _now, lastSeen: _now, installHash: join.installHash);
    }
    _devices[device.id] = device;
    _byTokenHash[device.tokenHash] = device;
    join
      ..status = JoinStatus.approved
      ..deviceToken = token
      ..deviceId = device.id;
    rotatePairing(); // the QR on screen is now spent
    _saveDevices();
    return join;
  }

  /// The guest polls this; the token is handed over exactly once.
  Map<String, Object?> pollJoin(String id, String ip) {
    _limiter.hit('poll:$ip', 240, 60000);
    final join = _joins[id];
    if (join == null || _now - join.createdAt > _joinTtlMs) throw ProtocolException(ErrorCode.pairingExpired);
    if (join.status == JoinStatus.approved && join.deviceToken != null) {
      _joins.remove(id);
      return {'status': 'approved', 'token': join.deviceToken, 'deviceId': join.deviceId};
    }
    if (join.status == JoinStatus.denied) _joins.remove(id);
    return {'status': join.status.name};
  }

  List<WebJoin> get pendingJoins {
    _gcJoins();
    return [for (final j in _joins.values) if (j.status == JoinStatus.pending) j];
  }

  WebDevice? authenticate(String? bearer) {
    if (bearer == null || bearer.isEmpty) return null;
    final d = _byTokenHash[_sha256(bearer)];
    if (d == null) return null;
    final now = _now;
    if (now - d.lastSeen > deviceIdleTtl.inMilliseconds) {
      forget(d.id);
      return null;
    }
    if (now - d.lastSeen > 60000) {
      d.lastSeen = now;
      _saveDevices();
    }
    return d;
  }

  WebDevice rename(String deviceId, String raw) {
    final d = _devices[deviceId];
    if (d == null) throw ProtocolException(ErrorCode.notFound);
    final name = cleanDeviceName(raw);
    if (name.isEmpty) throw ProtocolException(ErrorCode.badRequest, 'empty name');
    if (_nameTaken(name, d.id)) throw ProtocolException(ErrorCode.nameTaken);
    d.name = name;
    _saveDevices();
    return d;
  }

  void forget(String deviceId) {
    final d = _devices.remove(deviceId);
    if (d == null) return;
    _byTokenHash.remove(d.tokenHash);
    _saveDevices();
  }

  void setOnline(String deviceId, int delta) {
    final n = (_online[deviceId] ?? 0) + delta;
    if (n <= 0) {
      _online.remove(deviceId);
    } else {
      _online[deviceId] = n;
    }
  }

  bool isOnline(String deviceId) => _online.containsKey(deviceId);
  WebDevice? device(String id) => _devices[id];
  List<WebDevice> get devices => _devices.values.toList()..sort((a, b) => b.pairedAt.compareTo(a.pairedAt));

  /// Short-lived capability for plain-navigation downloads (Safari can't add headers).
  String signTicket(String scope, {Duration ttl = const Duration(minutes: 15)}) {
    final exp = _now + ttl.inMilliseconds;
    return '$exp.${bytesToBase64Url(Hmac(sha256, _secret).convert(utf8.encode('$scope|$exp')).bytes)}';
  }

  bool verifyTicket(String scope, String? ticket) {
    if (ticket == null) return false;
    final parts = ticket.split('.');
    if (parts.length != 2) return false;
    final exp = int.tryParse(parts[0]);
    if (exp == null || exp < _now) return false;
    final expected = Hmac(sha256, _secret).convert(utf8.encode('$scope|$exp')).bytes;
    final List<int> got;
    try {
      got = base64UrlToBytes(parts[1]);
    } on FormatException {
      return false;
    }
    if (got.length != expected.length) return false;
    var diff = 0;
    for (var i = 0; i < got.length; i++) {
      diff |= got[i] ^ expected[i];
    }
    return diff == 0;
  }

  void checkRate(String key, int max, int windowMs) => _limiter.hit(key, max, windowMs);

  // ---------------------------------------------------------------------------

  WebDevice? _byInstall(String hash) {
    for (final d in _devices.values) {
      if (d.installHash == hash) return d;
    }
    return null;
  }

  bool _nameTaken(String name, [String? exceptId]) {
    final k = name.toLowerCase();
    return _devices.values.any((d) => d.id != exceptId && d.name.toLowerCase() == k);
  }

  /// The paired browser this join comes from. By install id first. Safari keeps that id
  /// per origin, and the origin includes this device's address, so the same iPhone gets a
  /// new id whenever this device changes network (hotspot ↔ router). Then an entry with
  /// the same name that isn't connected right now is taken to be it: one "iPhone" that
  /// re-pairs, instead of "iPhone 2", "iPhone 3". Two phones online at once stay apart.
  WebDevice? _sameDevice(String? installHash, String name) {
    final byInstall = installHash == null ? null : _byInstall(installHash);
    if (byInstall != null) return byInstall;
    final k = name.toLowerCase();
    final idle = _now - _sameNameIdleMs;
    final matches = _devices.values.where((d) => d.name.toLowerCase() == k && d.lastSeen < idle).toList()
      ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    return matches.firstOrNull;
  }

  /// lastSeen is refreshed at most once a minute while a browser is active.
  static const _sameNameIdleMs = 3 * 60 * 1000;

  String _uniqueName(String base) {
    if (!_nameTaken(base)) return base;
    for (var n = 2;; n++) {
      final c = '${base.length > 36 ? base.substring(0, 36) : base} $n';
      if (!_nameTaken(c)) return c;
    }
  }

  void _gcJoins() {
    final now = _now;
    _joins.removeWhere((_, j) => now - j.createdAt > _joinTtlMs);
  }

  List<int> _loadSecret() {
    final f = File(p.join(stateDir, 'web-secret'));
    try {
      final b = base64UrlToBytes(f.readAsStringSync().trim());
      if (b.length >= 32) return b;
    } catch (_) {
      // first run
    }
    final b = randomBytes(32);
    Directory(stateDir).createSync(recursive: true);
    f.writeAsStringSync(bytesToBase64Url(b));
    return b;
  }

  void _loadDevices() {
    try {
      final list = jsonDecode(File(p.join(stateDir, 'web-devices.json')).readAsStringSync()) as List<Object?>;
      for (final raw in list) {
        final d = WebDevice.fromJson(raw! as Map<String, Object?>);
        if (_now - d.lastSeen > deviceIdleTtl.inMilliseconds) continue;
        _devices[d.id] = d;
        _byTokenHash[d.tokenHash] = d;
      }
    } catch (_) {
      // none yet
    }
  }

  void _saveDevices() {
    Directory(stateDir).createSync(recursive: true);
    final path = p.join(stateDir, 'web-devices.json');
    File('$path.tmp').writeAsStringSync(jsonEncode([for (final d in _devices.values) d.toJson()]));
    File('$path.tmp').renameSync(path);
  }
}

String cleanDeviceName(String s) {
  final t = s.replaceAll(_hiddenChars, '').replaceAll(RegExp(r'\s+'), ' ').trim();
  return t.length > 40 ? t.substring(0, 40) : t;
}

String _sha256(String s) => sha256.convert(utf8.encode(s)).toString();

bool _safeEqual(String a, String b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}

class _RateLimiter {
  final _hits = <String, (int, int)>{};

  void hit(String key, int max, int windowMs) {
    final now = DateTime.now().millisecondsSinceEpoch;
    var h = _hits[key];
    if (h == null || h.$2 <= now) {
      h = (0, now + windowMs);
      if (_hits.length > 5000) _hits.removeWhere((_, v) => v.$2 <= now);
    }
    h = (h.$1 + 1, h.$2);
    _hits[key] = h;
    if (h.$1 > max) throw ProtocolException(ErrorCode.rateLimited);
  }
}

String _cc(int c) => String.fromCharCode(c);

/// C0 controls and DEL.
final _controlChars = RegExp('[${_cc(0)}-${_cc(0x1f)}${_cc(0x7f)}]');

/// Controls plus bidi overrides/isolates (names must not reorder surrounding text).
final _hiddenChars = RegExp('[${_cc(0)}-${_cc(0x1f)}${_cc(0x7f)}${_cc(0x202a)}-${_cc(0x202e)}${_cc(0x2066)}-${_cc(0x2069)}]');
