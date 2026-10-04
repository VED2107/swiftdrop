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
    final extra = Uri(queryParameters: {'a': appAddress, 'n': e.name, 'd': e.deviceId}).query;
    return '${web.url(host)}&$extra';
  }
  final q = {'a': appAddress, 'n': e.name, 'd': e.deviceId};
  return Uri(scheme: 'swiftdrop', host: 'connect', queryParameters: q).toString();
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
