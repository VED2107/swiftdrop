import 'dart:typed_data';

import 'package:swiftdrop_core/engine.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';

/// Deterministic bytes for test files.
Uint8List bytesOf(int n, [int seed = 1]) {
  final out = Uint8List(n);
  var x = (seed * 2654435761) & 0xFFFFFFFF;
  if (x == 0) x = 1;
  for (var i = 0; i < n; i++) {
    x ^= (x << 13) & 0xFFFFFFFF;
    x ^= x >>> 17;
    x ^= (x << 5) & 0xFFFFFFFF;
    out[i] = x & 255;
  }
  return out;
}

var _n = 0;

class MemorySource implements FileSource {
  MemorySource(this.name, this.data, {this.relDir = ''}) : id = 'f_${(++_n).toString().padLeft(6, '0')}';
  @override
  final String id;
  @override
  final String name;
  @override
  final String relDir;
  final Uint8List data;
  int reads = 0;
  int bytesRead = 0;
  @override
  int get size => data.length;
  @override
  String get type => 'application/octet-stream';
  @override
  int get lastModified => 1700000000000;

  @override
  Future<ByteReader> open() async => _MemReader(this);
}

class _MemReader implements ByteReader {
  _MemReader(this.src);
  final MemorySource src;
  @override
  Future<Uint8List> read(int position, int length) async {
    src.reads++;
    src.bytesRead += length;
    final end = position + length < src.data.length ? position + length : src.data.length;
    return Uint8List.fromList(Uint8List.sublistView(src.data, position, end));
  }

  @override
  Future<void> close() async {}
}

class MemorySinks implements SinkFactory {
  final parts = <String, Uint8List>{};
  final finals = <String, Uint8List>{};
  final existing = <String>{};

  @override
  Future<FileSink> open(String transferId, String fileId, int size) async {
    final k = '$transferId/$fileId';
    var buf = parts[k];
    if (buf == null || buf.length != size) parts[k] = buf = Uint8List(size);
    final target = buf;
    return _MemSink(target);
  }

  @override
  Future<void> writeWhole(String transferId, String fileId, Uint8List bytes) async => parts['$transferId/$fileId'] = Uint8List.fromList(bytes);

  @override
  Future<void> discard(String transferId, String fileId) async => parts.remove('$transferId/$fileId');

  @override
  Future<bool> exists(List<String> relDir, String name) async => existing.contains([...relDir, name].join('/'));

  @override
  Future<String> finish(String transferId, String fileId,
      {required List<String> relDir, required String name, required int lastModified, required bool replace}) async {
    var path = [...relDir, name].join('/');
    if (!replace) {
      for (var n = 2; existing.contains(path) || finals.containsKey(path); n++) {
        path = [...relDir, numberedName(name, n)].join('/');
      }
    }
    finals[path] = parts.remove('$transferId/$fileId') ?? Uint8List(0);
    existing.add(path);
    return path;
  }

  @override
  Future<void> remove(String transferId) async => parts.removeWhere((k, _) => k.startsWith('$transferId/'));

  @override
  Future<int?> freeSpace() async => null;
}

class _MemSink implements FileSink {
  _MemSink(this.buf);
  final Uint8List buf;
  @override
  Future<void> write(int position, Uint8List bytes) async => buf.setRange(position, position + bytes.length, bytes);
  @override
  Future<void> close() async {}
}

class MemoryState implements StateStore {
  final data = <String, String>{};
  @override
  Future<String?> load(String transferId) async => data[transferId];
  @override
  Future<void> save(String transferId, String json) async => data[transferId] = json;
  @override
  Future<void> remove(String transferId) async => data.remove(transferId);
  @override
  Future<List<String>> list() async => data.keys.toList();
}

bool sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
