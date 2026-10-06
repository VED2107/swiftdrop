@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:swiftdrop_core/runtime.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';
import 'package:test/test.dart';

NetIface wifi(String a, {int prefix = 24, String name = 'wlan0'}) => NetIface(name: name, address: a, prefix: prefix, kind: NetKind.wifi);

void main() {
  group('which addresses are offered', () {
    test('mobile data and VPN are never offered; hotspot and Wi-Fi are', () {
      final out = reachable([
        const NetIface(name: 'rmnet_data0', address: '10.52.3.9', kind: NetKind.cellular),
        const NetIface(name: 'tun0', address: '10.8.0.2', kind: NetKind.vpn),
        const NetIface(name: 'ap0', address: '192.168.43.1', kind: NetKind.hotspot),
        wifi('192.168.1.20'),
      ]);
      expect(out.map((i) => i.address), ['192.168.43.1', '192.168.1.20']);
    });

    test('a hotspot owner with mobile data first in the list still leads with the hotspot', () {
      // The reported failure: both private-looking, the CGNAT one came first in the QR.
      final out = reachable([
        const NetIface(name: 'rmnet_data1', address: '100.72.14.5', kind: NetKind.cellular),
        const NetIface(name: 'rmnet_data2', address: '10.11.12.13', kind: NetKind.cellular),
        const NetIface(name: 'swlan0', address: '10.50.7.1', kind: NetKind.hotspot),
      ]);
      expect(out.map((i) => i.address), ['10.50.7.1']);
    });

    test('names classify when the platform says nothing', () {
      expect(kindFromName('rmnet_data0'), NetKind.cellular);
      expect(kindFromName('pdp_ip0'), NetKind.cellular);
      expect(kindFromName('ap0'), NetKind.hotspot);
      expect(kindFromName('swlan0'), NetKind.hotspot);
      expect(kindFromName('bridge100'), NetKind.hotspot);
      expect(kindFromName('wlan0'), NetKind.wifi);
      expect(kindFromName('en0'), NetKind.wifi);
      expect(kindFromName('Wi-Fi'), NetKind.wifi);
      expect(kindFromName('Ethernet 2'), NetKind.ethernet);
      expect(kindFromName('enp3s0'), NetKind.ethernet);
      expect(kindFromName('tun0'), NetKind.vpn);
    });

    test('virtual adapters rank last, link-local and loopback are dropped', () {
      final out = reachable([
        const NetIface(name: 'vEthernet (WSL)', address: '172.28.0.1', kind: NetKind.ethernet),
        const NetIface(name: 'Ethernet', address: '192.168.1.7', kind: NetKind.ethernet),
        const NetIface(name: 'lo', address: '127.0.0.1'),
        const NetIface(name: 'eth1', address: '169.254.3.3', kind: NetKind.ethernet),
      ]);
      expect(out.map((i) => i.address), ['192.168.1.7', '172.28.0.1']);
    });

    test('public addresses are not offered as local', () {
      expect(reachable([wifi('8.8.4.4')]), isEmpty);
    });
  });

  group('trying the other device\'s addresses', () {
    test('candidates on our own subnet go first', () {
      final mine = [wifi('192.168.43.2')];
      expect(orderCandidates(['10.0.0.5', '192.168.43.1', '172.16.0.9'], mine), ['192.168.43.1', '10.0.0.5', '172.16.0.9']);
    });

    test('subnet maths honours the prefix', () {
      expect(sameSubnet('192.168.1.5', '192.168.1.200', 24), isTrue);
      expect(sameSubnet('192.168.1.5', '192.168.2.5', 24), isFalse);
      expect(sameSubnet('192.168.1.5', '192.168.2.5', 16), isTrue);
      expect(sameSubnet('bad', '1.2.3.4', 24), isFalse);
    });
  });

  group('connectAny', () {
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('sd_net_'));
    tearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    Future<EngineHost> engine(String name) => EngineHost.spawn(EngineConfig(
          dataDir: p.join(tmp.path, name, 'data'),
          downloadDir: p.join(tmp.path, name, 'Downloads'),
          name: name,
          port: 0,
          lanes: 1,
          bindAddress: '127.0.0.1',
        ));

    test('skips addresses nobody answers on and lands on the one that works', () async {
      final a = await engine('A');
      final b = await engine('B');
      addTearDown(() async {
        await a.shutdown();
        await b.shutdown();
      });
      final bEnd = await b.endpoint().firstWhere((e) => e != null).timeout(const Duration(seconds: 20));
      // 192.0.2.x is TEST-NET-1: never routable, so the dial just never answers.
      final d = await a.connectAny(['192.0.2.7:${bEnd!.port}', '127.0.0.1:${bEnd.port}'], deviceId: bEnd.deviceId);
      expect(d.name, 'B');
      expect(d.id, bEnd.deviceId);
    });

    test('refuses an address that answers as a different device', () async {
      final a = await engine('A');
      final b = await engine('B');
      addTearDown(() async {
        await a.shutdown();
        await b.shutdown();
      });
      final bEnd = await b.endpoint().firstWhere((e) => e != null).timeout(const Duration(seconds: 20));
      await expectLater(
        a.connectAny(['127.0.0.1:${bEnd!.port}', '127.0.0.2:${bEnd.port}'], deviceId: 'd_someone_else'),
        throwsA(isA<TransportException>()),
      );
    });
  });
}
