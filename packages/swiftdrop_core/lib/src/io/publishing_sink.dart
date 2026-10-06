import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../platform/bridge.dart';
import '../platform/destination.dart';
import '../platform/files.dart';
import '../platform/io_kind.dart';
import '../protocol/errors.dart';
import 'io_files.dart';

/// Receiving for phones where the final home is a public location the app can't rename
/// into (Android MediaStore / Storage Access Framework):
///
///   network → `<staging>/.swiftdrop/<tid>/<fid>.part` (positional writes, resumable)
///           → root digest verified by the receiver
///           → [finish]: the platform layer streams the verified file into its public place
///           → staging file deleted
///
/// Incomplete data never reaches the public place: the platform entry is only published
/// once its bytes are all in. Staging is private app storage and holds one file at a time
/// beyond the transfer's own `.part` files.
class PublishingSinkFactory implements SinkFactory {
  PublishingSinkFactory({required String stagingRoot, required this.bridge, this.destination = SaveDestination.standard})
      : _staging = IoSinkFactory(stagingRoot);

  final PlatformBridge bridge;
  final IoSinkFactory _staging;

  /// Changeable between transfers.
  SaveDestination destination;

  @override
  Future<FileSink> open(String transferId, String fileId, int size) => _staging.open(transferId, fileId, size);

  @override
  Future<void> writeWhole(String transferId, String fileId, Uint8List bytes) => _staging.writeWhole(transferId, fileId, bytes);

  @override
  Future<void> discard(String transferId, String fileId) => _staging.discard(transferId, fileId);

  Map<String, Object?> _where(List<String> relDir, String name) {
    final mime = mimeFor(name);
    final kind = kindForMime(mime);
    return {
      'relDir': relDir,
      'name': name,
      'mime': mime,
      'kind': kind.name,
      'target': destination.targetFor(kind).name,
      'tree': destination.treeUri,
    };
  }

  @override
  Future<bool> exists(List<String> relDir, String name) async =>
      await bridge.call('exists', _where(relDir, name)) == true;

  @override
  Future<String> finish(
    String transferId,
    String fileId, {
    required List<String> relDir,
    required String name,
    required int lastModified,
    required bool replace,
  }) async {
    _staging.ensurePart(transferId, fileId);
    final part = _staging.partPath(transferId, fileId);
    final Object? result;
    try {
      result = await bridge.call('publish', {
        ..._where(relDir, name),
        'path': part,
        'lastModified': lastModified,
        'replace': replace,
      });
    } on BridgeException catch (e) {
      throw ProtocolException(e.code == 'noSpace' ? ErrorCode.diskFull : ErrorCode.diskWrite, e.message);
    }
    try {
      File(part).deleteSync();
    } catch (_) {}
    return '${(result as Map)['display']}';
  }

  @override
  Future<void> remove(String transferId) => _staging.remove(transferId);

  @override
  Future<int?> freeSpace() async {
    try {
      final v = await bridge.call('freeSpace');
      return v is int ? v : null;
    } catch (_) {
      return null;
    }
  }
}

/// Deletes leftovers of finished or abandoned transfers' staging (best effort).
Future<void> clearStaging(String stagingRoot) async {
  final d = Directory(p.join(stagingRoot, '.swiftdrop'));
  if (await d.exists()) await d.delete(recursive: true);
}
