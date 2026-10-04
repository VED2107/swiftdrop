import 'package:swiftdrop_core/swiftdrop_core.dart';

/// The one connection code this device shows as a QR, for every kind of guest.
///
/// When the browser host is running it is an `http://` link to it, so an iPhone (no app)
/// opens SwiftDrop in Safari straight from the Camera; the fragment also carries this
/// device's app address (`a`), name (`n`) and id (`d`), so another SwiftDrop app scanning
/// the same code connects natively. The fragment never leaves the scanning device.
/// Without the browser host it falls back to the app-only `swiftdrop://connect` form.
/// No file data here; the browser token `p` is single-use and still needs approval.
String connectUri(LocalEndpoint e, {String? address}) {
  final host = address ?? (e.addresses.isEmpty ? null : e.addresses.first);
  final appAddress = host == null ? (e.primary ?? '') : '$host:${e.port}';
  final web = e.web;
  if (web != null && host != null) {
    final extra = Uri(
      queryParameters: {
        'v': '$connectCodeVersion',
        'a': appAddress,
        'n': e.name,
        'd': e.deviceId,
      },
    ).query;
    return '${web.url(host)}&$extra';
  }
  final q = {
    'v': '$connectCodeVersion',
    'a': appAddress,
    'n': e.name,
    'd': e.deviceId,
  };
  return Uri(
    scheme: 'swiftdrop',
    host: 'connect',
    queryParameters: q,
  ).toString();
}

/// Highest connection-code version this build understands (`v` in the QR).
const connectCodeVersion = 1;

enum ScanProblem {
  /// Not a SwiftDrop code at all.
  notSwiftDrop,

  /// A SwiftDrop code from a newer version.
  unsupportedVersion,

  /// A browser phone-to-phone (/p2p/) code: a WebRTC offer the app can't answer.
  browserOnly,
}

/// What a scanned QR asks for: an app address to connect to, or why it can't be used.
class ScannedCode {
  const ScannedCode.ok(String this.address, {this.name}) : problem = null;
  const ScannedCode.bad(ScanProblem this.problem)
      : address = null,
        name = null;

  final String? address;
  final String? name;
  final ScanProblem? problem;
}

final _hostPort = RegExp(r'^(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9.\-]+)(:\d{1,5})?$');

/// Reads a camera-scanned code strictly: unlike [parseConnectInput], free text that
/// isn't a SwiftDrop code is rejected instead of being dialled as an address.
/// Codes without `v` come from SwiftDrop 0.3 and are read as version 1.
ScannedCode readScannedCode(String raw) {
  final s = raw.trim();
  Map<String, String>? params;
  if (s.startsWith('swiftdrop:')) {
    params = Uri.tryParse(s)?.queryParameters;
  } else if (s.startsWith('http://') || s.startsWith('https://')) {
    final uri = Uri.tryParse(s);
    if (uri == null) return const ScannedCode.bad(ScanProblem.notSwiftDrop);
    final f = Uri.splitQueryString(uri.fragment);
    if (!f.containsKey('a') && (f.containsKey('o') || f.containsKey('r'))) {
      return const ScannedCode.bad(ScanProblem.browserOnly);
    }
    params = f;
  } else if (_hostPort.firstMatch(s)?.group(2) != null) {
    // A bare `host:port` (someone made a QR of the address): the port makes it unambiguous.
    return ScannedCode.ok(s);
  }
  if (params == null) return const ScannedCode.bad(ScanProblem.notSwiftDrop);
  final v = int.tryParse(params['v'] ?? '1');
  if (v == null) return const ScannedCode.bad(ScanProblem.notSwiftDrop);
  if (v > connectCodeVersion) {
    return const ScannedCode.bad(ScanProblem.unsupportedVersion);
  }
  final a = params['a'];
  if (a == null || !_hostPort.hasMatch(a)) {
    return const ScannedCode.bad(ScanProblem.notSwiftDrop);
  }
  final n = params['n'];
  return ScannedCode.ok(a, name: n == null || n.isEmpty ? null : n);
}

/// Accepts `192.168.1.20:47800`, `192.168.1.20` (default port), a `swiftdrop://connect`
/// code, or the `http://…/#p=…&a=…` link another SwiftDrop device shows as its QR.
String? parseConnectInput(String input) {
  final s = input.trim();
  if (s.isEmpty) return null;
  if (s.startsWith('swiftdrop:')) {
    final a = Uri.tryParse(s)?.queryParameters['a'];
    return a == null || a.isEmpty ? null : a;
  }
  if (s.startsWith('http://') || s.startsWith('https://')) {
    final uri = Uri.tryParse(s);
    if (uri == null) return null;
    final a = Uri.splitQueryString(uri.fragment)['a'];
    return a == null || a.isEmpty ? null : a;
  }
  return s;
}
