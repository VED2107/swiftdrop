import 'dart:convert';
import 'dart:io';

import 'package:swiftdrop_core/swiftdrop_core.dart';

import '../design/design.dart';

/// The person's preferences. Persisted as a small JSON file in the app's support folder.
class AppSettings {
  const AppSettings({
    this.glass = GlassMode.full,
    this.motion = MotionPreference.system,
    this.contrast = ContrastPreference.system,
    this.duplicates = DuplicatePolicy.keepBoth,
    this.notifyIncoming = true,
    this.downloadDir,
    this.mediaToGallery = true,
    this.haptics = true,
    this.autoUpdate = true,
    this.saveTreeUri,
    this.saveTreeName,
  });

  final GlassMode glass;
  final MotionPreference motion;
  final ContrastPreference contrast;
  final DuplicatePolicy duplicates;
  final bool notifyIncoming;

  /// Where received files land; null = the platform default.
  final String? downloadDir;

  /// Android: photos, videos and music go to the Gallery / Music library.
  final bool mediaToGallery;

  /// Touch feedback on phones.
  final bool haptics;

  /// Ask GitHub for the newest version when the app opens.
  final bool autoUpdate;

  /// Android: the folder the person chose for everything else (null = Downloads/SwiftDrop).
  final String? saveTreeUri;
  final String? saveTreeName;

  SaveDestination get destination => SaveDestination(mediaToGallery: mediaToGallery, treeUri: saveTreeUri, treeName: saveTreeName);

  AppSettings copyWith({
    GlassMode? glass,
    MotionPreference? motion,
    ContrastPreference? contrast,
    DuplicatePolicy? duplicates,
    bool? notifyIncoming,
    String? downloadDir,
    bool? mediaToGallery,
    bool? haptics,
    bool? autoUpdate,
    String? saveTreeUri,
    String? saveTreeName,
    bool clearSaveTree = false,
  }) =>
      AppSettings(
        glass: glass ?? this.glass,
        motion: motion ?? this.motion,
        contrast: contrast ?? this.contrast,
        duplicates: duplicates ?? this.duplicates,
        notifyIncoming: notifyIncoming ?? this.notifyIncoming,
        downloadDir: downloadDir ?? this.downloadDir,
        mediaToGallery: mediaToGallery ?? this.mediaToGallery,
        haptics: haptics ?? this.haptics,
        autoUpdate: autoUpdate ?? this.autoUpdate,
        saveTreeUri: clearSaveTree ? null : (saveTreeUri ?? this.saveTreeUri),
        saveTreeName: clearSaveTree ? null : (saveTreeName ?? this.saveTreeName),
      );

  Map<String, Object?> toJson() => {
        'glass': glass.name,
        'motion': motion.name,
        'contrast': contrast.name,
        'duplicates': duplicates.name,
        'notifyIncoming': notifyIncoming,
        'downloadDir': downloadDir,
        'mediaToGallery': mediaToGallery,
        'haptics': haptics,
        'autoUpdate': autoUpdate,
        'saveTreeUri': saveTreeUri,
        'saveTreeName': saveTreeName,
      };

  factory AppSettings.fromJson(Map<String, Object?> j) => AppSettings(
        glass: GlassMode.values.asNameMap()[j['glass']] ?? GlassMode.full,
        motion: MotionPreference.values.asNameMap()[j['motion']] ?? MotionPreference.system,
        contrast: ContrastPreference.values.asNameMap()[j['contrast']] ?? ContrastPreference.system,
        duplicates: DuplicatePolicy.values.asNameMap()[j['duplicates']] ?? DuplicatePolicy.keepBoth,
        notifyIncoming: j['notifyIncoming'] != false,
        downloadDir: j['downloadDir'] as String?,
        mediaToGallery: j['mediaToGallery'] != false,
        haptics: j['haptics'] != false,
        autoUpdate: j['autoUpdate'] != false,
        saveTreeUri: j['saveTreeUri'] as String?,
        saveTreeName: j['saveTreeName'] as String?,
      );
}

/// Loads and saves [AppSettings]. A missing or unreadable file means defaults.
class SettingsFile {
  SettingsFile(this.path);
  final String? path;

  AppSettings load() {
    final p = path;
    if (p == null) return const AppSettings();
    try {
      return AppSettings.fromJson(jsonDecode(File(p).readAsStringSync()) as Map<String, Object?>);
    } catch (_) {
      return const AppSettings();
    }
  }

  void save(AppSettings s) {
    final p = path;
    if (p == null) return;
    try {
      final tmp = File('$p.tmp');
      tmp.writeAsStringSync(jsonEncode(s.toJson()), flush: true);
      tmp.renameSync(p);
    } catch (_) {
      // Preferences are a convenience; never block the app on them.
    }
  }
}
