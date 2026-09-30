import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:swiftdrop_core/runtime.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';
import 'package:swiftdrop_core/testing.dart';

import 'app/app.dart';
import 'app/providers.dart';
import 'app/settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // SWIFTDROP_PROFILE=name keeps a separate identity, device list and download folder, so
  // two instances can run side by side on one computer (development and testing).
  final profile = Platform.environment['SWIFTDROP_PROFILE'];
  final base = await getApplicationSupportDirectory();
  final support = profile == null || profile.isEmpty ? base : Directory(p.join(base.path, 'profiles', profile));
  await support.create(recursive: true);
  final settingsFile = SettingsFile(p.join(support.path, 'settings.json'));
  final settings = settingsFile.load();

  EngineHost? engine;
  Object? engineError;
  if (!demoMode) {
    final downloads = settings.downloadDir ?? await _defaultDownloads(profile);
    try {
      engine = await EngineHost.spawn(EngineConfig(
        dataDir: p.join(support.path, 'engine'),
        downloadDir: downloads,
        name: _deviceName(),
        kind: _deviceKind(),
        platform: _platform(),
        mobile: Platform.isAndroid || Platform.isIOS,
        lanes: Platform.isAndroid || Platform.isIOS ? 2 : 4,
      ));
      await engine.setDuplicates(settings.duplicates);
    } catch (e) {
      engineError = e;
      debugPrint('SwiftDrop engine failed to start: $e');
    }
    if (settings.downloadDir == null) settingsFile.save(settings.copyWith(downloadDir: downloads));
  }

  runApp(ProviderScope(
    overrides: [
      settingsFileProvider.overrideWithValue(settingsFile),
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
    child: SwiftDropApp(engineError: engineError),
  ));
}

/// Downloads/SwiftDrop on desktop; the app's Documents/SwiftDrop on phones (visible in
/// Files on iOS once file sharing is enabled in Phase 6).
Future<String> _defaultDownloads(String? profile) async {
  Directory? base;
  try {
    base = await getDownloadsDirectory();
  } catch (_) {}
  base ??= await getApplicationDocumentsDirectory();
  return p.join(base.path, profile == null || profile.isEmpty ? 'SwiftDrop' : 'SwiftDrop ($profile)');
}

String _deviceName() {
  final profile = Platform.environment['SWIFTDROP_PROFILE'];
  if (profile != null && profile.isNotEmpty) return profile;
  if (Platform.isIOS) return 'iPhone';
  if (Platform.isAndroid) return 'Android phone';
  final host = Platform.localHostname;
  return host.isEmpty ? 'This computer' : host;
}

DeviceKind _deviceKind() => Platform.isIOS || Platform.isAndroid ? DeviceKind.phone : (Platform.isMacOS ? DeviceKind.laptop : DeviceKind.desktop);

DevicePlatform _platform() => switch (Platform.operatingSystem) {
      'ios' => DevicePlatform.ios,
      'android' => DevicePlatform.android,
      'windows' => DevicePlatform.windows,
      'macos' => DevicePlatform.macos,
      'linux' => DevicePlatform.linux,
      _ => DevicePlatform.unknown,
    };
