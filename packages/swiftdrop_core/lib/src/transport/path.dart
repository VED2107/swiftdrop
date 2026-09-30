import 'link.dart';

/// Only claim "local network" when the addresses prove it. Port of the address rules in
/// `packages/peer/src/path.ts`: RFC 1918, link-local, loopback, IPv6 ULA / link-local and
/// mDNS names count as local; anything else is merely direct.
PathKind classifyAddresses(String local, String remote) =>
    isLocalAddress(local) && isLocalAddress(remote) ? PathKind.local : PathKind.p2p;

final _v4 = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$');
final _ula = RegExp(r'^f[cd][0-9a-f]{2}:');
final _linkLocal6 = RegExp(r'^fe[89ab][0-9a-f]:');

bool isLocalAddress(String addr) {
  var a = addr.trim().toLowerCase();
  if (a.startsWith('[') && a.endsWith(']')) a = a.substring(1, a.length - 1);
  final pct = a.indexOf('%'); // zone id
  if (pct >= 0) a = a.substring(0, pct);
  if (a.isEmpty) return false;
  if (a.endsWith('.local')) return true;
  final m = _v4.firstMatch(a.startsWith('::ffff:') ? a.substring(7) : a);
  if (m != null) {
    final p = int.parse(m.group(1)!);
    final q = int.parse(m.group(2)!);
    return p == 10 || p == 127 || (p == 172 && q >= 16 && q <= 31) || (p == 192 && q == 168) || (p == 169 && q == 254);
  }
  if (a.contains(':')) return a == '::1' || _ula.hasMatch(a) || _linkLocal6.hasMatch(a);
  return false;
}
