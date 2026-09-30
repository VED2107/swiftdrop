import 'dart:io';
import 'dart:isolate';

import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;
import 'package:swiftdrop_core/engine.dart' show mimeFor;
import 'package:swiftdrop_core/swiftdrop_core.dart';

import '../design/design.dart';

/// One thing picked to send: what the engine needs (a path) and what the review screen
/// shows (name, size, type, folder file count).
class PickedItem {
  const PickedItem(this.send, this.view);
  final SendItem send;
  final FileItemView view;
}

/// Native pickers return real paths on desktop, so files are read in place (no copy, no
/// upload hop). On mobile `file_selector` may hand back a cached copy; the own platform
/// plugin replaces it in the mobile phases (docs/FLUTTER_MIGRATION.md §7).
Future<List<PickedItem>> pickFiles() async {
  final files = await openFiles();
  return describePaths([for (final f in files) f.path]);
}

Future<List<PickedItem>> pickFolder() async {
  final dir = await getDirectoryPath();
  if (dir == null) return const [];
  return describePaths([dir]);
}

/// Describes dropped or picked paths. Folder sizes are summed off the UI thread.
Future<List<PickedItem>> describePaths(List<String> paths) async {
  final out = <PickedItem>[];
  for (final path in paths) {
    final type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.directory) {
      final (count, bytes) = await Isolate.run(() => _folderSize(path));
      if (count == 0) continue;
      out.add(PickedItem(SendItem.folder(path), FileItemView(name: p.basename(path), size: bytes, type: '', path: path, folderFiles: count)));
    } else if (type == FileSystemEntityType.file) {
      out.add(PickedItem(SendItem.file(path), FileItemView(name: p.basename(path), size: File(path).lengthSync(), type: mimeFor(path), path: path)));
    }
  }
  return out;
}

(int, int) _folderSize(String dir) {
  var count = 0;
  var bytes = 0;
  for (final e in Directory(dir).listSync(recursive: true, followLinks: false)) {
    if (e is File) {
      count++;
      bytes += e.lengthSync();
    }
  }
  return (count, bytes);
}

/// Opens a folder in the system file manager (desktop). Returns false where unsupported.
Future<bool> revealFolder(String path) async {
  try {
    if (Platform.isWindows) {
      await Process.start('explorer.exe', [path]);
    } else if (Platform.isMacOS) {
      await Process.start('open', [path]);
    } else if (Platform.isLinux) {
      await Process.start('xdg-open', [path]);
    } else {
      return false;
    }
    return true;
  } catch (_) {
    return false;
  }
}
