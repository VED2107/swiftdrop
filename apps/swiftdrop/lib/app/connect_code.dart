import 'package:swiftdrop_core/swiftdrop_core.dart';

/// The connection code shown as a QR and typed or pasted on the other device.
/// Connection information only: an address, a name, a device id. Never file data, never
/// a secret (Phase 7 adds a one-time pairing secret and certificate fingerprint here).
String connectUri(LocalEndpoint e) {
  final q = {'a': e.primary ?? '', 'n': e.name, 'd': e.deviceId};
  return Uri(scheme: 'swiftdrop', host: 'connect', queryParameters: q).toString();
}

/// Accepts `192.168.1.20:47800`, `192.168.1.20` (default port) or a full connect code.
String? parseConnectInput(String input) {
  final s = input.trim();
  if (s.isEmpty) return null;
  if (s.startsWith('swiftdrop:')) {
    final a = Uri.tryParse(s)?.queryParameters['a'];
    return a == null || a.isEmpty ? null : a;
  }
  return s;
}
