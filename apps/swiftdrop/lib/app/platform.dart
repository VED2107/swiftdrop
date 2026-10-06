import 'dart:io';

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';

/// The Android platform layer (`MainActivity.kt`): where received files are saved and what
/// the network looks like. The engine runs in its own isolate and cannot hold a
/// MethodChannel, so its calls arrive through a [BridgeHost] and are relayed here.
/// Everywhere else this is inert: desktop receives straight into a folder, iOS keeps the
/// app's Documents folder.
class PlatformLink {
  PlatformLink._();

  static const _channel = MethodChannel('app.swiftdrop/platform');
  static BridgeHost? _host;
  static void Function()? _onNetworkChanged;

  static bool get available => Platform.isAndroid;

  /// Starts relaying engine calls. Returns what the engine needs to reach this side, or
  /// null off Android.
  static BridgeHost? start({void Function()? onNetworkChanged}) {
    if (!available) return null;
    _onNetworkChanged = onNetworkChanged;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'networkChanged') _onNetworkChanged?.call();
      return null;
    });
    _host ??= BridgeHost(_relay);
    _channel.invokeMethod<void>('watchNetwork').ignore();
    return _host;
  }

  static void setNetworkListener(void Function()? f) => _onNetworkChanged = f;

  static int? _sdk;
  static Future<bool>? _legacyPermission;

  static Future<Object?> _relay(String method, Map<String, Object?> args) async {
    try {
      if (method == 'publish') {
        if (!await ensureStoragePermission()) throw BridgeException('permission', 'Storage permission denied');
      }
      return await _channel.invokeMethod<Object?>(method, args);
    } on PlatformException catch (e) {
      throw BridgeException(e.code, e.message);
    }
  }

  /// Android 7-9 need a storage permission to write into Pictures/Movies/Downloads;
  /// Android 10+ saves through MediaStore and the folder picker with no permission at all.
  static Future<bool> ensureStoragePermission() async {
    final sdk = _sdk ??= await _channel.invokeMethod<int>('sdkInt') ?? 99;
    if (sdk >= 29) return true;
    return _legacyPermission ??= Permission.storage.request().then((s) => s.isGranted);
  }

  /// A folder the person picks once. The grant is persisted by Android (survives restarts).
  /// Null when they back out.
  static Future<({String uri, String name})?> pickFolder() async {
    final r = await _channel.invokeMapMethod<String, Object?>('pickFolder');
    if (r == null) return null;
    return (uri: r['uri']! as String, name: r['name'] as String? ?? 'Chosen folder');
  }

  /// Whether the chosen folder is still writable (the person can revoke it in system
  /// settings, or remove the storage it lives on).
  static Future<bool> folderGranted(String uri) async =>
      await _channel.invokeMethod<bool>('folderGranted', {'uri': uri}) ?? false;

  static Future<void> releaseFolder(String uri) => _channel.invokeMethod<void>('releaseFolder', {'uri': uri});

  /// `gallery`, `downloads` or `folder` (with [uri]): can something on this phone open it?
  static Future<bool> canOpen(String what, {String? uri}) async {
    if (!available) return false;
    try {
      return await _channel.invokeMethod<bool>('canOpen', {'what': what, 'uri': uri}) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> open(String what, {String? uri}) async {
    try {
      return await _channel.invokeMethod<bool>('open', {'what': what, 'uri': uri}) ?? false;
    } catch (_) {
      return false;
    }
  }
}
