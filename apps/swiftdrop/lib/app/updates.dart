import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Updates, without an app store: the app asks GitHub Releases for the newest version
/// number, shows what changed, downloads the installer for this platform, checks it, and
/// hands it to the system installer. The only thing sent is an anonymous HTTPS request for
/// the release list; no identifier, no device name, nothing about files or transfers.

/// A published release that is newer than the running app.
class UpdateInfo {
  const UpdateInfo({required this.version, required this.notes, required this.pageUrl, this.assetName, this.assetUrl, this.size, this.sha256});

  final String version;
  final String notes;

  /// The release page, for platforms that update by hand.
  final String pageUrl;

  /// The installer for this platform (APK on Android, Setup.exe on Windows); null elsewhere.
  final String? assetName;
  final String? assetUrl;
  final int? size;

  /// Hex digest GitHub computes for the asset, when it reports one.
  final String? sha256;

  bool get installable => assetUrl != null;
}

/// True when [candidate] is a higher version than [current] (`1.2.0` > `1.10.0` is false;
/// a leading `v` and a `+build` suffix are ignored, a pre-release suffix counts as lower).
bool isNewerVersion(String candidate, String current) {
  List<int> parts(String v) {
    final core = v.trim().replaceFirst(RegExp(r'^[vV]'), '').split('+').first.split('-').first;
    return [for (final s in core.split('.')) int.tryParse(s) ?? 0];
  }

  final a = parts(candidate);
  final b = parts(current);
  for (var i = 0; i < 3; i++) {
    final x = i < a.length ? a[i] : 0;
    final y = i < b.length ? b[i] : 0;
    if (x != y) return x > y;
  }
  final aPre = candidate.contains('-');
  final bPre = current.contains('-');
  return !aPre && bPre;
}

enum InstallStart { started, needsPermission, unsupported }

/// The slow, side-effecting half: network and installer. Replaced in tests.
abstract class Updater {
  /// The newest published release for this platform if it is newer than [current].
  Future<UpdateInfo?> check(String current);

  /// Downloads the installer, verified against the size and digest GitHub reports.
  Future<String> download(UpdateInfo info, void Function(double fraction) onProgress);

  Future<InstallStart> install(String path);
}

class InertUpdater implements Updater {
  const InertUpdater();
  @override
  Future<UpdateInfo?> check(String current) async => null;
  @override
  Future<String> download(UpdateInfo info, void Function(double fraction) onProgress) => Future.error(StateError('no updater'));
  @override
  Future<InstallStart> install(String path) async => InstallStart.unsupported;
}

/// Inno Setup switches for an in-app upgrade: no wizard, no dialogs, close the running app.
const windowsInstallerArgs = ['/SILENT', '/SUPPRESSMSGBOXES', '/CLOSEAPPLICATIONS', '/NORESTART'];

class GithubUpdater implements Updater {
  GithubUpdater({this.repo = 'VED2107/swiftdrop', this.platform});

  final String repo;
  static const _channel = MethodChannel('app.swiftdrop/platform');
  final String? platform;

  String get _platform => platform ?? Platform.operatingSystem;

  @override
  Future<UpdateInfo?> check(String current) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client.getUrl(Uri.parse('https://api.github.com/repos/$repo/releases/latest'));
      req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      req.headers.set(HttpHeaders.userAgentHeader, 'SwiftDrop-update-check');
      final res = await req.close().timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) {
        await res.drain<void>();
        throw HttpException('release list answered ${res.statusCode}');
      }
      final json = jsonDecode(await res.transform(utf8.decoder).join()) as Map<String, Object?>;
      return parseRelease(json, current, _platform);
    } finally {
      client.close(force: true);
    }
  }

  /// Reads a GitHub release document. Public so tests cover the parsing without a network.
  static UpdateInfo? parseRelease(Map<String, Object?> json, String current, String platform) {
    if (json['draft'] == true || json['prerelease'] == true) return null;
    final tag = '${json['tag_name'] ?? ''}'.replaceFirst(RegExp(r'^[vV]'), '');
    if (tag.isEmpty || !isNewerVersion(tag, current)) return null;
    Map<String, Object?>? asset;
    final wanted = switch (platform) {
      'android' => (String n) => n.toLowerCase().endsWith('.apk'),
      'windows' => (String n) => n.toLowerCase().endsWith('.exe') && n.toLowerCase().contains('setup'),
      _ => (String n) => false,
    };
    for (final a in (json['assets'] as List? ?? const [])) {
      if (a is Map<String, Object?> && wanted('${a['name']}')) {
        asset = a;
        break;
      }
    }
    final digest = '${asset?['digest'] ?? ''}';
    return UpdateInfo(
      version: tag,
      notes: '${json['body'] ?? ''}'.trim(),
      pageUrl: '${json['html_url'] ?? 'https://github.com/VED2107/swiftdrop/releases/latest'}',
      assetName: asset == null ? null : '${asset['name']}',
      assetUrl: asset == null ? null : '${asset['browser_download_url']}',
      size: (asset?['size'] as num?)?.toInt(),
      sha256: digest.startsWith('sha256:') ? digest.substring(7).toLowerCase() : null,
    );
  }

  @override
  Future<String> download(UpdateInfo info, void Function(double fraction) onProgress) async {
    final dir = Directory(p.join((await getTemporaryDirectory()).path, 'updates'));
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    dir.createSync(recursive: true);
    final target = File(p.join(dir.path, info.assetName!));
    final part = File('${target.path}.part');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.getUrl(Uri.parse(info.assetUrl!));
      req.headers.set(HttpHeaders.userAgentHeader, 'SwiftDrop-update');
      final res = await req.close();
      if (res.statusCode != 200) {
        await res.drain<void>();
        throw HttpException('download answered ${res.statusCode}');
      }
      final total = res.contentLength > 0 ? res.contentLength : (info.size ?? 0);
      final sink = part.openWrite();
      var got = 0;
      var lastTick = 0;
      try {
        await for (final chunk in res.timeout(const Duration(seconds: 30))) {
          sink.add(chunk);
          got += chunk.length;
          final now = DateTime.now().millisecondsSinceEpoch;
          if (total > 0 && now - lastTick > 120) {
            lastTick = now;
            onProgress((got / total).clamp(0.0, 1.0));
          }
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (info.size != null && got != info.size) throw const FileSystemException('download is incomplete');
      final expected = info.sha256;
      if (expected != null && (await sha256.bind(part.openRead()).first).toString() != expected) {
        throw const FileSystemException('download does not match the published checksum');
      }
      await part.rename(target.path);
      onProgress(1);
      return target.path;
    } catch (_) {
      if (part.existsSync()) part.deleteSync();
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<InstallStart> install(String path) async {
    if (_platform == 'android') {
      final r = await _channel.invokeMethod<String>('installApk', {'path': path});
      return switch (r) {
        'started' => InstallStart.started,
        'needsPermission' => InstallStart.needsPermission,
        _ => InstallStart.unsupported,
      };
    }
    if (_platform == 'windows') {
      // Same installer as a first install, run silently over the existing one (same AppId):
      // it closes this app, replaces the files and starts the new version. `start` lets
      // Windows raise its own elevation prompt when the existing install is per-machine.
      await Process.start('cmd', ['/c', 'start', '', path, ...windowsInstallerArgs], mode: ProcessStartMode.detached);
      return InstallStart.started;
    }
    return InstallStart.unsupported;
  }
}

enum UpdateStage { idle, checking, upToDate, available, downloading, ready, needsPermission, failed }

class UpdateState {
  const UpdateState({this.stage = UpdateStage.idle, this.current = '', this.info, this.progress = 0, this.checkedAt, this.dismissed});
  final UpdateStage stage;
  final String current;
  final UpdateInfo? info;
  final double progress;
  final DateTime? checkedAt;

  /// The version whose banner the person closed.
  final String? dismissed;

  bool get available => info != null && stage != UpdateStage.upToDate;
  bool get showBanner => available && dismissed != info!.version && stage != UpdateStage.failed;

  UpdateState copyWith({UpdateStage? stage, String? current, UpdateInfo? info, bool clearInfo = false, double? progress, DateTime? checkedAt, String? dismissed}) => UpdateState(
        stage: stage ?? this.stage,
        current: current ?? this.current,
        info: clearInfo ? null : (info ?? this.info),
        progress: progress ?? this.progress,
        checkedAt: checkedAt ?? this.checkedAt,
        dismissed: dismissed ?? this.dismissed,
      );
}

final updaterProvider = Provider<Updater>((ref) => const InertUpdater());

/// The running app's version (`1.1.0`), set at startup from the platform.
final appVersionProvider = Provider<String>((ref) => '0.0.0');

class UpdateController extends Notifier<UpdateState> {
  String? _path;

  @override
  UpdateState build() => UpdateState(current: ref.watch(appVersionProvider));

  /// Asks GitHub. Quiet on failure when [silent] (the automatic check at launch).
  Future<void> check({bool silent = false}) async {
    if (state.stage == UpdateStage.checking || state.stage == UpdateStage.downloading) return;
    state = state.copyWith(stage: UpdateStage.checking);
    try {
      final info = await ref.read(updaterProvider).check(state.current);
      state = info == null
          ? state.copyWith(stage: UpdateStage.upToDate, clearInfo: true, checkedAt: DateTime.now())
          : state.copyWith(stage: UpdateStage.available, info: info, checkedAt: DateTime.now());
    } catch (_) {
      state = state.copyWith(stage: silent ? UpdateStage.idle : UpdateStage.failed);
    }
  }

  /// Downloads (once) and opens the installer.
  Future<void> install() async {
    final info = state.info;
    if (info == null || !info.installable) return;
    final updater = ref.read(updaterProvider);
    try {
      if (_path == null || !File(_path!).existsSync()) {
        state = state.copyWith(stage: UpdateStage.downloading, progress: 0);
        _path = await updater.download(info, (f) => state = state.copyWith(progress: f));
      }
      state = state.copyWith(stage: UpdateStage.ready, progress: 1);
      final started = await updater.install(_path!);
      if (started == InstallStart.needsPermission) state = state.copyWith(stage: UpdateStage.needsPermission);
    } catch (_) {
      _path = null;
      state = state.copyWith(stage: UpdateStage.failed);
    }
  }

  void dismissBanner() {
    final v = state.info?.version;
    if (v != null) state = state.copyWith(dismissed: v);
  }
}

final updateProvider = NotifierProvider<UpdateController, UpdateState>(UpdateController.new);
