import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:swiftdrop_core/runtime.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';
import 'package:swiftdrop_core/testing.dart';

import 'app/app.dart';
import 'app/platform.dart';
import 'app/providers.dart';
import 'app/settings.dart';
import 'app/updates.dart';
import 'app/web_assets.dart';
import 'screens/settings/update_ui.dart';
import 'design/haptics.dart';

/// Shown to browser guests (`/api/info`) and in About.
const appVersion = String.fromEnvironment(
  'SWIFTDROP_VERSION',
  defaultValue: '1.1.0',
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // SWIFTDROP_PROFILE=name keeps a separate identity, device list and download folder, so
  // two instances can run side by side on one computer (development and testing).
  final profile = Platform.environment['SWIFTDROP_PROFILE'];
  final base = await getApplicationSupportDirectory();
  final support = profile == null || profile.isEmpty
      ? base
      : Directory(p.join(base.path, 'profiles', profile));
  await support.create(recursive: true);
  final settingsFile = SettingsFile(p.join(support.path, 'settings.json'));
  var settings = settingsFile.load();
  Haptics.enabled = settings.haptics;
  if (PlatformLink.available) Haptics.nativeEffect = PlatformLink.haptic;

  EngineHost? engine;
  Object? engineError;
  if (!demoMode) {
    // Android: files are received into private staging, then published to the Gallery or the
    // chosen folder. The chosen folder's grant can disappear (revoked, storage removed).
    final bridge = PlatformLink.start(onNetworkChanged: () => engine?.networkChanged().ignore());
    if (bridge != null && settings.saveTreeUri != null && !await PlatformLink.folderGranted(settings.saveTreeUri!)) {
      settings = settings.copyWith(clearSaveTree: true);
      settingsFile.save(settings);
    }
    final downloads = bridge != null
        ? p.join(support.path, 'staging')
        : (settings.downloadDir ?? await _defaultDownloads(profile));
    // Phones without the app (an iPhone) pair by QR and use the bundled browser client.
    final webRoot = await extractWebClient(support.path)
        .catchError((Object _) => null);
    try {
      engine = await EngineHost.spawn(
        EngineConfig(
          dataDir: p.join(support.path, 'engine'),
          downloadDir: downloads,
          name: _deviceName(),
          kind: _deviceKind(),
          platform: _platform(),
          mobile: Platform.isAndroid || Platform.isIOS,
          lanes: Platform.isAndroid || Platform.isIOS ? 2 : 4,
          webRoot: webRoot,
          version: appVersion,
          bridge: bridge?.sendPort,
          stagingDir: bridge == null ? null : downloads,
          destination: settings.destination,
          debugNet: kDebugMode || const bool.fromEnvironment('SWIFTDROP_NETLOG'),
        ),
      );
      await engine.setDuplicates(settings.duplicates);
    } catch (e) {
      engineError = e;
      debugPrint('SwiftDrop engine failed to start: $e');
    }
    if (bridge == null && settings.downloadDir == null) {
      settingsFile.save(settings.copyWith(downloadDir: downloads));
    }
  }

  final version = await PackageInfo.fromPlatform().then((i) => i.version, onError: (_) => appVersion);
  final canUpdate = !demoMode && (Platform.isAndroid || Platform.isWindows);

  runApp(
    ProviderScope(
      overrides: [
        settingsFileProvider.overrideWithValue(settingsFile),
        appVersionProvider.overrideWithValue(version),
        if (canUpdate) updaterProvider.overrideWithValue(GithubUpdater()),
        if (engine != null) ...[
          engineProvider.overrideWithValue(engine),
          deviceDirectoryProvider.overrideWithValue(engine),
          transferServiceProvider.overrideWithValue(engine.transferService),
          transferHistoryProvider.overrideWithValue(engine.history),
        ],
        if (demoMode) ...[
          deviceDirectoryProvider.overrideWithValue(DemoDeviceDirectory()),
          transferServiceProvider.overrideWithValue(DemoTransferService()),
          transferHistoryProvider.overrideWithValue(DemoTransferHistory()),
        ],
      ],
      child: AutoUpdateCheck(child: SwiftDropApp(engineError: engineError)),
    ),
  );
}

/// Downloads/SwiftDrop on desktop; the app's Documents/SwiftDrop on phones (visible in
/// Files on iOS once file sharing is enabled in Phase 6).
Future<String> _defaultDownloads(String? profile) async {
  Directory? base;
  try {
    base = await getDownloadsDirectory();
  } catch (_) {}
  base ??= await getApplicationDocumentsDirectory();
  return p.join(
    base.path,
    profile == null || profile.isEmpty ? 'SwiftDrop' : 'SwiftDrop ($profile)',
  );
}

String _deviceName() {
  final profile = Platform.environment['SWIFTDROP_PROFILE'];
  if (profile != null && profile.isNotEmpty) return profile;
  if (Platform.isIOS) return 'iPhone';
  if (Platform.isAndroid) return 'Android phone';
  final host = Platform.localHostname;
  return host.isEmpty ? 'This computer' : host;
}

DeviceKind _deviceKind() => Platform.isIOS || Platform.isAndroid
    ? DeviceKind.phone
    : (Platform.isMacOS ? DeviceKind.laptop : DeviceKind.desktop);

DevicePlatform _platform() => switch (Platform.operatingSystem) {
  'ios' => DevicePlatform.ios,
  'android' => DevicePlatform.android,
  'windows' => DevicePlatform.windows,
  'macos' => DevicePlatform.macos,
  'linux' => DevicePlatform.linux,
  _ => DevicePlatform.unknown,
};
