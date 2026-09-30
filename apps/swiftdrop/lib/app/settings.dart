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
  });

  final GlassMode glass;
  final MotionPreference motion;
  final ContrastPreference contrast;
  final DuplicatePolicy duplicates;
  final bool notifyIncoming;

  /// Where received files land; null = the platform default.
  final String? downloadDir;

  AppSettings copyWith({
    GlassMode? glass,
    MotionPreference? motion,
    ContrastPreference? contrast,
    DuplicatePolicy? duplicates,
    bool? notifyIncoming,
    String? downloadDir,
  }) =>
      AppSettings(
        glass: glass ?? this.glass,
        motion: motion ?? this.motion,
        contrast: contrast ?? this.contrast,
        duplicates: duplicates ?? this.duplicates,
        notifyIncoming: notifyIncoming ?? this.notifyIncoming,
        downloadDir: downloadDir ?? this.downloadDir,
      );

  Map<String, Object?> toJson() => {
        'glass': glass.name,
        'motion': motion.name,
        'contrast': contrast.name,
        'duplicates': duplicates.name,
        'notifyIncoming': notifyIncoming,
        'downloadDir': downloadDir,
      };

  factory AppSettings.fromJson(Map<String, Object?> j) => AppSettings(
        glass: GlassMode.values.asNameMap()[j['glass']] ?? GlassMode.full,
        motion: MotionPreference.values.asNameMap()[j['motion']] ?? MotionPreference.system,
        contrast: ContrastPreference.values.asNameMap()[j['contrast']] ?? ContrastPreference.system,
        duplicates: DuplicatePolicy.values.asNameMap()[j['duplicates']] ?? DuplicatePolicy.keepBoth,
        notifyIncoming: j['notifyIncoming'] != false,
        downloadDir: j['downloadDir'] as String?,
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
