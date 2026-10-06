import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:swiftdrop/app/connect_code.dart';
import 'package:swiftdrop/app/updates.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';

class _FakeUpdater implements Updater {
  _FakeUpdater(this.info, {this.fail = false});
  final UpdateInfo? info;
  final bool fail;
  int downloads = 0;
  InstallStart start = InstallStart.started;

  @override
  Future<UpdateInfo?> check(String current) async {
    if (fail) throw StateError('offline');
    return info;
  }

  @override
  Future<String> download(UpdateInfo info, void Function(double fraction) onProgress) async {
    downloads++;
    onProgress(0.5);
    onProgress(1);
    return 'C:/tmp/${info.assetName}';
  }

  @override
  Future<InstallStart> install(String path) async => start;
}

Map<String, Object?> release(String tag, {bool draft = false, bool pre = false, List<Map<String, Object?>>? assets}) => {
      'tag_name': tag,
      'draft': draft,
      'prerelease': pre,
      'body': '## What changed\n- Faster\n- **Fixes**',
      'html_url': 'https://github.com/VED2107/swiftdrop/releases/tag/$tag',
      'assets': assets ??
          [
            {'name': 'SwiftDrop-1.1.0.apk', 'browser_download_url': 'https://x/apk', 'size': 100, 'digest': 'sha256:ABCDEF'},
            {'name': 'SwiftDrop-Setup-1.1.0.exe', 'browser_download_url': 'https://x/exe', 'size': 50},
          ],
    };

void main() {
  group('version order', () {
    test('compares numerically, not as text', () {
      expect(isNewerVersion('1.10.0', '1.9.0'), isTrue);
      expect(isNewerVersion('1.2.0', '1.10.0'), isFalse);
      expect(isNewerVersion('1.0.1', '1.0.0'), isTrue);
      expect(isNewerVersion('2.0', '1.9.9'), isTrue);
    });
    test('equal, older, tags with v, build numbers and pre-releases', () {
      expect(isNewerVersion('1.0.0', '1.0.0'), isFalse);
      expect(isNewerVersion('v1.1.0', '1.0.0+100'), isTrue);
      expect(isNewerVersion('1.0.0', '1.0.0+999'), isFalse);
      expect(isNewerVersion('1.1.0-beta.1', '1.1.0'), isFalse);
      expect(isNewerVersion('1.1.0', '1.1.0-beta.1'), isTrue);
    });
  });

  group('reading a GitHub release', () {
    test('picks the APK on Android and the Setup.exe on Windows', () {
      final a = GithubUpdater.parseRelease(release('v1.1.0'), '1.0.0', 'android')!;
      expect(a.version, '1.1.0');
      expect(a.assetName, 'SwiftDrop-1.1.0.apk');
      expect(a.size, 100);
      expect(a.sha256, 'abcdef');
      final w = GithubUpdater.parseRelease(release('v1.1.0'), '1.0.0', 'windows')!;
      expect(w.assetName, 'SwiftDrop-Setup-1.1.0.exe');
      expect(w.sha256, isNull);
    });
    test('other platforms get the release page, not an installer', () {
      final m = GithubUpdater.parseRelease(release('v1.1.0'), '1.0.0', 'macos')!;
      expect(m.installable, isFalse);
      expect(m.pageUrl, contains('/releases/tag/v1.1.0'));
    });
    test('nothing for the same version, drafts and pre-releases', () {
      expect(GithubUpdater.parseRelease(release('v1.0.0'), '1.0.0', 'android'), isNull);
      expect(GithubUpdater.parseRelease(release('v2.0.0', draft: true), '1.0.0', 'android'), isNull);
      expect(GithubUpdater.parseRelease(release('v2.0.0', pre: true), '1.0.0', 'android'), isNull);
    });
  });

  group('the update flow', () {
    ProviderContainer container(Updater u) => ProviderContainer(overrides: [
          updaterProvider.overrideWithValue(u),
          appVersionProvider.overrideWithValue('1.0.0'),
        ]);

    test('check finds a newer version, then installing downloads once and hands over', () async {
      final info = GithubUpdater.parseRelease(release('v1.1.0'), '1.0.0', 'android')!;
      final u = _FakeUpdater(info);
      final c = container(u);
      addTearDown(c.dispose);
      await c.read(updateProvider.notifier).check();
      expect(c.read(updateProvider).stage, UpdateStage.available);
      expect(c.read(updateProvider).showBanner, isTrue);
      await c.read(updateProvider.notifier).install();
      expect(c.read(updateProvider).stage, UpdateStage.ready);
      expect(u.downloads, 1);
    });

    test('up to date, and a failed manual check says so while a silent one stays quiet', () async {
      final c = container(_FakeUpdater(null));
      addTearDown(c.dispose);
      await c.read(updateProvider.notifier).check();
      expect(c.read(updateProvider).stage, UpdateStage.upToDate);

      final off = container(_FakeUpdater(null, fail: true));
      addTearDown(off.dispose);
      await off.read(updateProvider.notifier).check(silent: true);
      expect(off.read(updateProvider).stage, UpdateStage.idle);
      await off.read(updateProvider.notifier).check();
      expect(off.read(updateProvider).stage, UpdateStage.failed);
    });

    test('Android asks for install permission once; closing the banner hides that version only', () async {
      final info = GithubUpdater.parseRelease(release('v1.1.0'), '1.0.0', 'android')!;
      final u = _FakeUpdater(info)..start = InstallStart.needsPermission;
      final c = container(u);
      addTearDown(c.dispose);
      final n = c.read(updateProvider.notifier);
      await n.check();
      await n.install();
      expect(c.read(updateProvider).stage, UpdateStage.needsPermission);
      n.dismissBanner();
      expect(c.read(updateProvider).showBanner, isFalse);
    });
  });

  group('connection code with several networks', () {
    const ep = LocalEndpoint(deviceId: 'd_abc', name: 'Pixel', addresses: ['192.168.43.1', '192.168.1.8', '10.0.0.4'], port: 47800);

    test('lists every other address and the scanner reads them back', () {
      final code = connectUri(ep);
      expect(code, contains('a=192.168.43.1%3A47800'));
      final read = readScannedCode(code);
      expect(read.address, '192.168.43.1:47800');
      expect(read.alternates, ['192.168.1.8:47800', '10.0.0.4:47800']);
      expect(read.deviceId, 'd_abc');
      expect(read.allAddresses.length, 3);
    });

    test('an older code with a single address still reads', () {
      final read = readScannedCode('swiftdrop://connect?v=1&a=192.168.1.20%3A47800&n=Laptop');
      expect(read.address, '192.168.1.20:47800');
      expect(read.alternates, isEmpty);
    });
  });
}
