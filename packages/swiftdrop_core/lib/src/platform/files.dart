import 'dart:typed_data';

/// Platform file boundaries. The engine reads sources and writes sinks positionally and
/// never holds a whole file. Implementations live in the platform layer:
///  - desktop: `dart:io` RandomAccessFile on real paths (no upload hop, ever)
///  - Android: content:// URIs opened as file descriptors (Photo Picker, SAF), MediaStore
///  - iOS: security-scoped URLs, PHPicker file representations, Documents / Photos

/// A file chosen to send. Metadata is read once at pick time; [open] re-checks it.
abstract interface class FileSource {
  String get id;
  String get name;

  /// Relative folder inside a picked folder, `/`-separated; empty for loose files.
  String get relDir;
  int get size;

  /// MIME type when the platform knows it.
  String get type;

  /// Milliseconds since epoch; 0 when unknown.
  int get lastModified;

  /// Opens for positional reads. Throws `ProtocolException(sourceChanged)` when the
  /// file's size or modification time no longer match the metadata above.
  Future<ByteReader> open();
}

abstract interface class ByteReader {
  /// Reads exactly [length] bytes at [position] into a fresh buffer (short only at EOF).
  Future<Uint8List> read(int position, int length);
  Future<void> close();
}

/// Where one received file's bytes go. Positional writes, possibly concurrent for
/// different ranges.
abstract interface class FileSink {
  Future<void> write(int position, Uint8List bytes);

  /// Flush and release; the data must be durable afterwards.
  Future<void> close();
}

/// Receiving storage. Mirrors `SinkFactory` in `packages/peer/src/receiver.ts`, plus
/// the final placement step that the PC store does with an atomic rename.
abstract interface class SinkFactory {
  Future<FileSink> open(String transferId, String fileId, int size);

  /// Root digest mismatch: throw this file's bytes away and start over.
  Future<void> discard(String transferId, String fileId);

  /// Move a verified file to its final place. Returns the name it was stored under
  /// (may differ from [name] when keeping both copies of a duplicate).
  Future<String> finish(
    String transferId,
    String fileId, {
    required String name,
    required String relDir,
    required String type,
    required int lastModified,
  });

  /// Drop everything of a transfer (cancel / decline).
  Future<void> remove(String transferId);

  /// Bytes available for new files, or null when the platform can't tell.
  Future<int?> freeSpace();
}

/// Resume state (bitmaps + block digests) that survives app restarts.
abstract interface class StateStore {
  Future<String?> load(String transferId);

  /// Must be atomic: a crash mid-save leaves the previous state readable.
  Future<void> save(String transferId, String json);
  Future<void> remove(String transferId);
  Future<List<String>> list();
}
