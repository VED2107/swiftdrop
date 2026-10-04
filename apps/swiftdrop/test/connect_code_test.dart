import 'package:flutter_test/flutter_test.dart';
import 'package:swiftdrop/app/connect_code.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';

void main() {
  test('connectUri uses the browser host when web access is available', () {
    final endpoint = LocalEndpoint(
      deviceId: 'dev-1',
      name: 'Android phone',
      addresses: const ['192.168.1.20'],
      port: 47800,
      web: BrowserAccess(
        port: 8787,
        token: 'pair-token',
        code: '123456',
        expiresAt: DateTime(2026, 10, 4),
      ),
    );

    final uri = connectUri(endpoint);

    expect(uri, startsWith('http://192.168.1.20:8787/#p=pair-token&'));
    expect(parseConnectInput(uri), '192.168.1.20:47800');
  });

  test(
    'connectUri keeps native app fallback when browser host is unavailable',
    () {
      const endpoint = LocalEndpoint(
        deviceId: 'dev-1',
        name: 'Android phone',
        addresses: ['192.168.1.20'],
        port: 47800,
      );

      final uri = connectUri(endpoint);

      expect(uri, startsWith('swiftdrop://connect?'));
      expect(parseConnectInput(uri), '192.168.1.20:47800');
    },
  );

  group('readScannedCode', () {
    test('reads the app QR (browser link) and its name', () {
      final code = readScannedCode(
        'http://192.168.1.20:8787/#p=tok&v=1&a=192.168.1.20%3A47800&n=Ved%27s+PC&d=dev-1',
      );
      expect(code.problem, isNull);
      expect(code.address, '192.168.1.20:47800');
      expect(code.name, "Ved's PC");
    });

    test('round-trips every code connectUri produces', () {
      final endpoint = LocalEndpoint(
        deviceId: 'dev-1',
        name: 'Pixel & co',
        addresses: const ['10.0.0.5'],
        port: 47800,
        web: BrowserAccess(port: 8787, token: 't', code: '1', expiresAt: DateTime(2026)),
      );
      final code = readScannedCode(connectUri(endpoint));
      expect(code.address, '10.0.0.5:47800');
      expect(code.name, 'Pixel & co');
      final native = readScannedCode(connectUri(const LocalEndpoint(deviceId: 'dev-1', name: 'Pixel', addresses: ['10.0.0.5'], port: 47800)));
      expect(native.address, '10.0.0.5:47800');
    });

    test('accepts 0.3 codes without a version', () {
      expect(readScannedCode('swiftdrop://connect?a=10.0.0.5%3A47800').address, '10.0.0.5:47800');
    });

    test('accepts a bare host:port', () {
      expect(readScannedCode('192.168.1.20:47800').address, '192.168.1.20:47800');
    });

    test('rejects codes that are not SwiftDrop', () {
      for (final raw in ['hello', 'https://example.com', 'https://example.com/#a=', 'WIFI:S:home;T:WPA;P:x;;', 'swiftdrop://connect?a=bad%20host']) {
        expect(readScannedCode(raw).problem, ScanProblem.notSwiftDrop, reason: raw);
      }
    });

    test('rejects a newer version', () {
      expect(readScannedCode('swiftdrop://connect?v=2&a=10.0.0.5%3A47800').problem, ScanProblem.unsupportedVersion);
    });

    test('recognises browser phone-to-phone codes', () {
      expect(readScannedCode('https://swiftdrop.app/p2p/#o=Dabc_123&k=0123456789abcdefghijkl').problem, ScanProblem.browserOnly);
    });
  });
}
