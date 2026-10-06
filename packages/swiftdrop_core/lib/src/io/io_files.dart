import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../platform/files.dart';
import '../protocol/errors.dart';
import '../util/random.dart';
import '../util/sanitize.dart';

/// `dart:io` implementations of the file boundaries: desktop today, and anywhere a real
/// path exists (Android app storage, iOS Documents / security-scoped URLs).
/// Reads and writes are positional through [RandomAccessFile]; nothing loads whole files.
///
/// File calls are synchronous on purpose. Measured on Windows (AOT, tool/io_variants.dart
/// and the 10k-file benchmark): each async file call carries milliseconds of overhead
/// (async `writeFrom` of 1 MiB: 10 MB/s; sync: ~3 GB/s), which made small files crawl at
/// ~220 files/s. These classes run on the engine / receiver isolates, never the UI's, so
/// a short blocking call costs nothing visible.

/// Serialises operations on one handle (seek + read/write must not interleave).
class _Lock {
  Future<void> _tail = Future.value();
  Future<T> run<T>(Future<T> Function() op) {
    final result = _tail.then((_) => op());
    _tail = result.then((_) {}, onError: (_) {});
    return result;
  }
}

class IoFileSource implements FileSource {
  IoFileSource._(this.path, this.id, this.name, this.relDir, this.size, this.type, this.lastModified);

  /// Reads metadata now; [open] re-checks it so a file edited after picking is refused
  /// rather than sent under stale metadata.
  factory IoFileSource(String path, {String relDir = '', String? id, String? type}) {
    final st = File(path).statSync();
    if (st.type != FileSystemEntityType.file) throw ArgumentError.value(path, 'path', 'not a file');
    return IoFileSource._(path, id ?? 'f_${randomId(12)}', p.basename(path), relDir, st.size, type ?? mimeFor(path),
        st.modified.millisecondsSinceEpoch);
  }

  /// Every file under [dir], with relative folders starting at the folder's own name.
  static List<IoFileSource> folder(String dir) {
    final root = Directory(dir);
    final base = p.basename(p.normalize(dir));
    final out = <IoFileSource>[];
    for (final e in root.listSync(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final rel = p.relative(p.dirname(e.path), from: root.path);
      out.add(IoFileSource(e.path, relDir: rel == '.' ? base : p.posix.joinAll([base, ...p.split(rel)])));
    }
    return out;
  }

  final String path;
  @override
  final String id;
  @override
  final String name;
  @override
  final String relDir;
  @override
  final int size;
  @override
  final String type;
  @override
  final int lastModified;

  @override
  Future<ByteReader> open() async {
    final f = File(path);
    final st = f.statSync();
    if (st.type != FileSystemEntityType.file || st.size != size || st.modified.millisecondsSinceEpoch != lastModified) {
      throw ProtocolException(ErrorCode.sourceChanged, path);
    }
    return _IoReader(f.openSync());
  }
}

class _IoReader implements ByteReader {
  _IoReader(this._raf);
  final RandomAccessFile _raf;
  final _lock = _Lock();

  @override
  Future<Uint8List> read(int position, int length) => _lock.run(() async {
        _raf.setPositionSync(position);
        final buf = Uint8List(length);
        var got = 0;
        while (got < length) {
          final n = _raf.readIntoSync(buf, got, length);
          if (n <= 0) break;
          got += n;
        }
        return got == length ? buf : Uint8List.sublistView(buf, 0, got);
      });

  @override
  Future<void> close() => _lock.run(() async => _raf.closeSync());
}

/// Receives into a real folder:
///   `<root>/.swiftdrop/<transferId>/<fileId>.part`   data, written positionally
///   `<root>/<relDir>/<name>`                          final file, renamed into place
class IoSinkFactory implements SinkFactory {
  IoSinkFactory(this.root);

  /// Destination folder (e.g. Downloads/SwiftDrop).
  final String root;
  final _naming = _Lock();

  /// Names chosen by [finish] whose rename hasn't landed yet: nobody else may take them.
  final _reserved = <String>{};

  /// The partial file of one received file (also read by [PublishingSinkFactory]).
  String partPath(String transferId, String fileId) => _part(transferId, fileId);

  /// Makes sure the partial file exists (an empty file never got a write).
  void ensurePart(String transferId, String fileId) {
    final part = _part(transferId, fileId);
    if (!File(part).existsSync()) {
      _mkdirs(_partDir(transferId));
      File(part).createSync();
    }
  }

  String get _stateRoot => p.join(root, '.swiftdrop');
  String _partDir(String t) => p.join(_stateRoot, t);
  String _part(String t, String f) => p.join(_partDir(t), '$f.part');

  final _madeDirs = <String>{};

  void _mkdirs(String dir) {
    if (_madeDirs.contains(dir)) return;
    Directory(dir).createSync(recursive: true);
    _madeDirs.add(dir);
  }

  @override
  Future<FileSink> open(String transferId, String fileId, int size) async {
    _mkdirs(_partDir(transferId));
    // append mode creates the file without truncating it (resume keeps earlier blocks);
    // writes still go where setPosition points.
    return _IoSink(File(_part(transferId, fileId)).openSync(mode: FileMode.append));
  }

  @override
  Future<void> writeWhole(String transferId, String fileId, Uint8List bytes) async {
    _mkdirs(_partDir(transferId));
    final raf = File(_part(transferId, fileId)).openSync(mode: FileMode.write);
    if (bytes.isNotEmpty) raf.writeFromSync(bytes);
    raf.closeSync();
  }

  @override
  Future<void> discard(String transferId, String fileId) async {
    final f = File(_part(transferId, fileId));
    if (f.existsSync()) f.deleteSync();
  }

  @override
  Future<bool> exists(List<String> relDir, String name) async => File(_safeJoin([...relDir, name])).existsSync();

  @override
  Future<String> finish(String transferId, String fileId,
      {required List<String> relDir, required String name, required int lastModified, required bool replace}) async {
    // Pick the final name under the lock and reserve it until the rename lands.
    final part = _part(transferId, fileId);
    final target = await _naming.run(() async {
      if (!File(part).existsSync()) {
        _mkdirs(_partDir(transferId));
        File(part).createSync();
      }
      bool taken(String t) => _reserved.contains(t) || File(t).existsSync();
      var target = _safeJoin([...relDir, name]);
      if (!replace && taken(target)) {
        for (var n = 2;; n++) {
          if (n > 9999) throw ProtocolException(ErrorCode.diskWrite, 'no free name');
          target = _safeJoin([...relDir, numberedName(name, n)]);
          if (!taken(target)) break;
        }
      }
      if (replace && File(target).existsSync()) File(target).deleteSync();
      _reserved.add(target);
      return target;
    });
    try {
      _mkdirs(p.dirname(target));
      final moved = File(part).renameSync(target);
      if (lastModified > 0) {
        try {
          moved.setLastModifiedSync(DateTime.fromMillisecondsSinceEpoch(lastModified));
        } catch (_) {
          // not fatal: some filesystems refuse
        }
      }
    } finally {
      _reserved.remove(target);
    }
    return p.relative(target, from: root).replaceAll(r'\', '/');
  }

  @override
  Future<void> remove(String transferId) async {
    _madeDirs.clear();
    final d = Directory(_partDir(transferId));
    if (await d.exists()) await d.delete(recursive: true);
    final s = Directory(_stateRoot);
    try {
      if (await s.exists() && await s.list().isEmpty) await s.delete();
    } catch (_) {}
  }

  @override
  Future<int?> freeSpace() async => null; // dart:io can't tell; the platform layer can (Phase 4+)

  /// Final path inside [root]; refuses anything that would escape it.
  String _safeJoin(List<String> segments) {
    final target = p.normalize(p.join(root, p.joinAll(segments)));
    final base = p.normalize(root);
    if (!p.isWithin(base, target)) throw ProtocolException(ErrorCode.forbidden, 'path escapes destination');
    return target;
  }
}

/// Writes are synchronous on purpose. Measured on Windows (AOT, tool/io_variants.dart):
/// async `RandomAccessFile.writeFrom` costs ~10 ms per call (10 MB/s at 1 MiB, 160 MB/s at
/// 16 MiB) while `writeFromSync` runs at ~3 GB/s into the page cache. The engine runs in
/// its own isolate, so a short blocking write never touches the UI.
class _IoSink implements FileSink {
  _IoSink(this._raf);
  final RandomAccessFile _raf;
  final _lock = _Lock();

  @override
  Future<void> write(int position, Uint8List bytes) => _lock.run(() async {
        _raf.setPositionSync(position);
        _raf.writeFromSync(bytes);
      });

  @override
  // No flush: an fsync per file halved small-file throughput (tool/small_files.dart). The
  // OS writes the data back; resume state never counts a block before its digest
  // matched, and a lost tail after a power cut shows up as a root mismatch → resent.
  Future<void> close() => _lock.run(() async => _raf.closeSync());
}

/// Resume state as `<dir>/<id>.json`, written atomically (temp file + rename).
class IoStateStore implements StateStore {
  IoStateStore(this.dir);
  final String dir;

  File _file(String id) => File(p.join(dir, '$id.json'));

  @override
  Future<String?> load(String transferId) async {
    final f = _file(transferId);
    return await f.exists() ? f.readAsString() : null;
  }

  @override
  Future<void> save(String transferId, String json) async {
    await Directory(dir).create(recursive: true);
    final tmp = File(p.join(dir, '$transferId.json.${randomId(6)}.tmp'));
    await tmp.writeAsString(json, flush: true);
    await tmp.rename(_file(transferId).path);
  }

  @override
  Future<void> remove(String transferId) async {
    final f = _file(transferId);
    if (await f.exists()) await f.delete();
    try {
      final d = Directory(dir);
      if (await d.exists() && await d.list().isEmpty) await d.delete();
    } catch (_) {}
  }

  @override
  Future<List<String>> list() async {
    final d = Directory(dir);
    if (!await d.exists()) return const [];
    return [
      await for (final e in d.list())
        if (e is File && e.path.endsWith('.json')) p.basenameWithoutExtension(e.path),
    ];
  }
}

const _mime = {
  '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png', '.gif': 'image/gif', '.webp': 'image/webp',
  '.heic': 'image/heic', '.heif': 'image/heif', '.avif': 'image/avif', '.bmp': 'image/bmp', '.tif': 'image/tiff',
  '.tiff': 'image/tiff', '.dng': 'image/x-adobe-dng', '.raw': 'image/x-raw',
  '.mp4': 'video/mp4', '.mov': 'video/quicktime', '.m4v': 'video/x-m4v', '.mkv': 'video/x-matroska', '.webm': 'video/webm',
  '.avi': 'video/x-msvideo', '.mp3': 'audio/mpeg', '.m4a': 'audio/mp4', '.wav': 'audio/wav', '.flac': 'audio/flac',
  '.aac': 'audio/aac', '.ogg': 'audio/ogg', '.opus': 'audio/opus', '.wma': 'audio/x-ms-wma', '.3gp': 'video/3gpp',
  '.mpg': 'video/mpeg', '.mpeg': 'video/mpeg', '.wmv': 'video/x-ms-wmv', '.flv': 'video/x-flv',
  '.jxl': 'image/jxl', '.cr2': 'image/x-canon-cr2', '.nef': 'image/x-nikon-nef', '.arw': 'image/x-sony-arw', '.pdf': 'application/pdf', '.zip': 'application/zip', '.7z': 'application/x-7z-compressed',
  '.rar': 'application/vnd.rar', '.gz': 'application/gzip', '.tar': 'application/x-tar', '.txt': 'text/plain',
  '.md': 'text/markdown', '.csv': 'text/csv', '.json': 'application/json', '.doc': 'application/msword',
  '.docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  '.xls': 'application/vnd.ms-excel', '.xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  '.ppt': 'application/vnd.ms-powerpoint',
  '.pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  '.key': 'application/vnd.apple.keynote', '.pages': 'application/vnd.apple.pages', '.apk': 'application/vnd.android.package-archive',
  '.dmg': 'application/x-apple-diskimage', '.exe': 'application/vnd.microsoft.portable-executable', '.iso': 'application/x-iso9660-image',
};

String mimeFor(String path) => _mime[p.extension(path).toLowerCase()] ?? '';
