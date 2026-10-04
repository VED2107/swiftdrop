import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// The browser client bundled into the app (scripts/sync-web-assets.mjs), extracted once
/// per build into app support so the engine can serve it from disk to phones without the
/// app. Returns null when this build carries no web client (tests, unsynced checkouts).
Future<String?> extractWebClient(String supportDir) async {
  final String manifest;
  try {
    manifest = await rootBundle.loadString('assets/web/manifest.txt');
  } catch (_) {
    return null;
  }
  final lines = manifest.split('\n').where((l) => l.trim().isNotEmpty).toList();
  if (lines.length < 2) return null;
  final target = Directory(p.join(supportDir, 'web', lines.first));
  final done = File(p.join(target.path, '.complete'));
  if (done.existsSync()) return target.path;
  for (final rel in lines.skip(1)) {
    final data = await rootBundle.load('assets/web/$rel');
    final f = File(p.joinAll([target.path, ...rel.split('/')]));
    await f.parent.create(recursive: true);
    await f.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
  }
  await done.writeAsString(lines.first);
  // Older builds' copies are dead weight.
  for (final e in Directory(p.join(supportDir, 'web')).listSync()) {
    if (e is Directory && p.basename(e.path) != lines.first) {
      try {
        e.deleteSync(recursive: true);
      } catch (_) {}
    }
  }
  return target.path;
}
