import 'path.dart';

/// Which of this device's addresses another device can actually reach, and in what order
/// to try theirs. Pure functions; the platform layer supplies the facts (see
/// `NetBridge.kt`): on a phone the interface *name* alone can't tell a Wi-Fi link from the
/// mobile-data link (CGNAT addresses look private) or from the hotspot the phone hosts.

enum NetKind { wifi, ethernet, hotspot, cellular, vpn, other }

class NetIface {
  const NetIface({required this.name, required this.address, this.prefix = 24, this.kind = NetKind.other, this.multicast = true});

  final String name;
  final String address;

  /// Subnet prefix length (24 when the platform can't tell).
  final int prefix;
  final NetKind kind;
  final bool multicast;

  factory NetIface.fromMap(Map<Object?, Object?> m) => NetIface(
        name: '${m['name']}',
        address: '${m['address']}',
        prefix: (m['prefix'] as num?)?.toInt() ?? 24,
        kind: NetKind.values.asNameMap()['${m['kind']}'] ?? NetKind.other,
        multicast: m['multicast'] != false,
      );

  @override
  String toString() => '$name $address/$prefix ${kind.name}';
}

/// Interface kind from its name alone (desktop, iOS, or a phone whose platform layer
/// didn't answer).
NetKind kindFromName(String name) {
  final n = name.toLowerCase();
  if (RegExp(r'^(rmnet|ccmni|pdp_ip|ppp|wwan|usb\d|v4-rmnet|r_rmnet)').hasMatch(n)) return NetKind.cellular;
  if (RegExp(r'^(tun|tap|utun|ipsec|wg|tailscale|zt)').hasMatch(n) || n.contains('vpn')) return NetKind.vpn;
  if (RegExp(r'^(ap\d|swlan|softap|rndis|bnep|bridge\d)').hasMatch(n)) return NetKind.hotspot;
  if (n.contains('wi-fi') || n.contains('wlan') || n.contains('wireless') || RegExp(r'^wl').hasMatch(n)) return NetKind.wifi;
  if (RegExp(r'^en\d').hasMatch(n)) return NetKind.wifi; // Apple: en0 is Wi-Fi
  if (n.contains('ethernet') || RegExp(r'^(eth|enp|eno|ens)').hasMatch(n)) return NetKind.ethernet;
  return NetKind.other;
}

bool _virtual(NetIface i) {
  final n = i.name.toLowerCase();
  return n.contains('vethernet') ||
      n.contains('virtual') ||
      n.contains('vmware') ||
      n.contains('docker') ||
      n.contains('veth') ||
      n.contains('wsl') ||
      n.contains('hyper-v') ||
      n.startsWith('br-') ||
      i.address.startsWith('192.168.56.'); // VirtualBox host-only
}

/// Addresses another device on the same network could dial, best first. Mobile-data and
/// VPN links are never offered: their private-looking addresses are unreachable from the
/// Wi-Fi or hotspot the other phone is on, and putting one first in the QR is exactly how a
/// hotspot pairing fails.
List<NetIface> reachable(Iterable<NetIface> all) {
  final seen = <String>{};
  final out = <(int, NetIface)>[];
  for (final i in all) {
    if (i.kind == NetKind.cellular || i.kind == NetKind.vpn) continue;
    if (!isLocalAddress(i.address) || i.address.startsWith('127.') || i.address.startsWith('169.254.')) continue;
    if (!seen.add(i.address)) continue;
    final rank = (_virtual(i) ? 4 : 0) + switch (i.kind) { NetKind.wifi || NetKind.hotspot => 0, NetKind.ethernet => 1, _ => 2 };
    out.add((rank, i));
  }
  out.sort((a, b) => a.$1.compareTo(b.$1)); // stable: the platform's own order breaks ties
  return [for (final e in out) e.$2];
}

String kindLabel(NetIface i) => switch (i.kind) {
      NetKind.wifi => 'Wi-Fi',
      NetKind.hotspot => 'Hotspot',
      NetKind.ethernet => 'Ethernet',
      _ => i.name,
    };

int? _v4(String a) {
  final m = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$').firstMatch(a);
  if (m == null) return null;
  var v = 0;
  for (var k = 1; k <= 4; k++) {
    final b = int.parse(m.group(k)!);
    if (b > 255) return null;
    v = (v << 8) | b;
  }
  return v;
}

bool sameSubnet(String a, String b, int prefix) {
  final x = _v4(a);
  final y = _v4(b);
  if (x == null || y == null || prefix < 1 || prefix > 32) return false;
  final mask = prefix == 32 ? 0xFFFFFFFF : (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF;
  return (x & mask) == (y & mask);
}

/// Another device's candidate addresses in the order to try them: those on one of our own
/// subnets first (they are certainly the shared network), the rest after, original order
/// kept within each group.
List<String> orderCandidates(List<String> candidates, List<NetIface> mine) {
  bool shared(String c) => mine.any((i) => sameSubnet(c, i.address, i.prefix));
  return [...candidates.where(shared), ...candidates.where((c) => !shared(c))];
}

/// `[NET]` diagnostics for debugging a pairing. Off unless the app turns it on; addresses
/// are never logged in release builds.
bool netDebug = false;
void Function(String line) netLogSink = (_) {};

void netLog(String line) {
  if (netDebug) netLogSink('[NET] $line');
}
