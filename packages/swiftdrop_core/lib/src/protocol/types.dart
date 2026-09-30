import 'constants.dart';
import 'errors.dart';

/// Wire types of protocol v1, with the same JSON shapes as the Zod schemas in
/// `packages/protocol`. Only the shapes live here; engine behaviour is ported in Phase 3.

enum Direction {
  /// phone -> PC server (browser guest path)
  toHost('to-host'),
  /// PC server -> phone
  toGuest('to-guest'),
  /// device -> device, direct
  toPeer('to-peer');

  const Direction(this.wire);
  final String wire;
  static Direction fromWire(String s) => _byWire(values, s, (v) => v.wire);
}

enum IntegrityAlgo {
  xxh64('xxh64'),
  sha256('sha256');

  const IntegrityAlgo(this.wire);
  final String wire;
  static IntegrityAlgo fromWire(String s) => _byWire(values, s, (v) => v.wire);
}

enum ConflictPolicy {
  ask('ask'),
  replace('replace'),
  skip('skip'),
  keepBoth('keep-both');

  const ConflictPolicy(this.wire);
  final String wire;
  static ConflictPolicy fromWire(String s) => _byWire(values, s, (v) => v.wire);
}

enum FileState {
  fresh('new'),
  partial('partial'),
  complete('complete'),
  skipped('skipped');

  const FileState(this.wire);
  final String wire;
  static FileState fromWire(String s) => _byWire(values, s, (v) => v.wire);
}

final _id = RegExp(r'^[A-Za-z0-9_-]{6,64}$');

String _checkId(String v, String field) {
  if (!_id.hasMatch(v)) throw ProtocolException(ErrorCode.badRequest, 'bad $field');
  return v;
}

class FileEntry {
  FileEntry({
    required String id,
    required this.name,
    this.relDir = '',
    required this.size,
    this.type = '',
    this.lastModified = 0,
  }) : id = _checkId(id, 'file id') {
    if (name.isEmpty || name.length > 1024) throw ProtocolException(ErrorCode.badRequest, 'bad name');
    if (size < 0) throw ProtocolException(ErrorCode.badRequest, 'bad size');
  }

  final String id;
  final String name;
  final String relDir;
  final int size;
  final String type;
  final int lastModified;

  Map<String, Object?> toJson() =>
      {'id': id, 'name': name, 'relDir': relDir, 'size': size, 'type': type, 'lastModified': lastModified};

  factory FileEntry.fromJson(Map<String, Object?> j) => FileEntry(
        id: j['id'] as String,
        name: j['name'] as String,
        relDir: (j['relDir'] as String?) ?? '',
        size: (j['size'] as num).toInt(),
        type: (j['type'] as String?) ?? '',
        lastModified: (j['lastModified'] as num?)?.toInt() ?? 0,
      );
}

/// `CreateTransfer` in the TS code: the manifest, sent once per transfer.
class Manifest {
  Manifest({
    required String transferId,
    required this.direction,
    this.label = '',
    this.integrity = IntegrityAlgo.xxh64,
    this.onConflict = ConflictPolicy.ask,
    this.decisions = const {},
    this.bench = false,
    required this.files,
  }) : transferId = _checkId(transferId, 'transfer id') {
    if (files.isEmpty || files.length > maxFilesPerTransfer) {
      throw ProtocolException(ErrorCode.badRequest, 'bad file count');
    }
  }

  final String transferId;
  final Direction direction;
  final String label;
  final IntegrityAlgo integrity;
  final ConflictPolicy onConflict;
  final Map<String, ConflictPolicy> decisions;
  final bool bench;
  final List<FileEntry> files;

  int get totalBytes => files.fold(0, (s, f) => s + f.size);

  Map<String, Object?> toJson() => {
        'protocol': protocolVersion,
        'transferId': transferId,
        'direction': direction.wire,
        'label': label,
        'integrity': integrity.wire,
        'onConflict': onConflict.wire,
        'decisions': {for (final e in decisions.entries) e.key: e.value.wire},
        'bench': bench,
        'files': [for (final f in files) f.toJson()],
      };

  factory Manifest.fromJson(Map<String, Object?> j) {
    if (j['protocol'] != protocolVersion) throw ProtocolException(ErrorCode.badRequest, 'protocol version');
    final decisions = (j['decisions'] as Map<String, Object?>?) ?? const {};
    return Manifest(
      transferId: j['transferId'] as String,
      direction: Direction.fromWire(j['direction'] as String),
      label: (j['label'] as String?) ?? '',
      integrity: IntegrityAlgo.fromWire((j['integrity'] as String?) ?? 'xxh64'),
      onConflict: ConflictPolicy.fromWire((j['onConflict'] as String?) ?? 'ask'),
      decisions: {for (final e in decisions.entries) e.key: ConflictPolicy.fromWire(e.value as String)},
      bench: (j['bench'] as bool?) ?? false,
      files: [for (final f in j['files'] as List<Object?>) FileEntry.fromJson(f as Map<String, Object?>)],
    );
  }
}

class FileStatus {
  const FileStatus({required this.id, required this.state, this.received, this.finalName});
  final String id;
  final FileState state;

  /// base64 bitmap of received blocks when [state] is partial.
  final String? received;
  final String? finalName;

  Map<String, Object?> toJson() => {
        'id': id,
        'state': state.wire,
        if (received != null) 'received': received,
        if (finalName != null) 'finalName': finalName,
      };

  factory FileStatus.fromJson(Map<String, Object?> j) => FileStatus(
        id: j['id'] as String,
        state: FileState.fromWire(j['state'] as String),
        received: j['received'] as String?,
        finalName: j['finalName'] as String?,
      );
}

class TransferStatus {
  const TransferStatus({required this.transferId, required this.blockSize, required this.integrity, required this.files});
  final String transferId;
  final int blockSize;
  final IntegrityAlgo integrity;
  final List<FileStatus> files;

  Map<String, Object?> toJson() => {
        'transferId': transferId,
        'blockSize': blockSize,
        'integrity': integrity.wire,
        'files': [for (final f in files) f.toJson()],
      };

  factory TransferStatus.fromJson(Map<String, Object?> j) => TransferStatus(
        transferId: j['transferId'] as String,
        blockSize: (j['blockSize'] as num).toInt(),
        integrity: IntegrityAlgo.fromWire(j['integrity'] as String),
        files: [for (final f in j['files'] as List<Object?>) FileStatus.fromJson(f as Map<String, Object?>)],
      );
}

class Conflict {
  const Conflict({required this.id, required this.name, required this.size, required this.existingSize});
  final String id;
  final String name;
  final int size;
  final int existingSize;

  factory Conflict.fromJson(Map<String, Object?> j) => Conflict(
        id: j['id'] as String,
        name: j['name'] as String,
        size: (j['size'] as num).toInt(),
        existingSize: (j['existingSize'] as num).toInt(),
      );
}

/// Result of opening a transfer: the receiver's per-file state, or name clashes to resolve.
sealed class CreateResult {
  const CreateResult();
}

final class Created extends CreateResult {
  const Created(this.status);
  final TransferStatus status;
}

final class Conflicts extends CreateResult {
  const Conflicts(this.conflicts);
  final List<Conflict> conflicts;
}

T _byWire<T>(List<T> values, String s, String Function(T) wire) {
  for (final v in values) {
    if (wire(v) == s) return v;
  }
  throw ProtocolException(ErrorCode.badRequest, 'unknown value "$s"');
}
