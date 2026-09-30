import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../platform/files.dart';
import '../protocol/batch.dart';
import '../protocol/constants.dart';
import '../protocol/errors.dart';
import '../protocol/types.dart';
import '../transport/link.dart';
import '../util/base64url.dart';
import '../util/bitset.dart';
import '../util/hashing.dart';
import '../util/sanitize.dart';

/// The receiving device. Port of `packages/peer/src/receiver.ts` with the disk rules of
/// the PC store (`apps/server/src/store.ts`): every block digest is checked before it
/// counts, batch frames are verified whole, a file is complete only when the sender's root
/// matches ours, bitmaps make any drop resumable, and verified files move into place
/// atomically with the receiver's duplicate policy. Bytes are written at their offset as
/// each request arrives; bodies in reassembly are capped, never gathered per file.

class IncomingFile {
  const IncomingFile({required this.id, required this.name, required this.relDir, required this.size, required this.type});
  final String id;
  final String name;
  final String relDir;
  final int size;
  final String type;
}

/// A transfer waiting for the person on this device.
class IncomingManifest {
  const IncomingManifest({required this.transferId, required this.label, required this.files, required this.totalBytes, this.peerId});
  final String transferId;
  final String label;
  final List<IncomingFile> files;
  final int totalBytes;

  /// Who sent it (from the link's hello), when known.
  final String? peerId;
}

class ReceivedFile {
  ReceivedFile({
    required this.id,
    required this.name,
    required this.relDir,
    required this.size,
    required this.type,
    required this.lastModified,
    required this.state,
    required this.received,
    this.digests,
    this.replace = false,
    this.finalName,
  });

  final String id;
  final String name;
  final List<String> relDir;
  final int size;
  final String type;
  final int lastModified;
  FileState state;
  Bitset received;
  Uint8List? digests;

  /// Replace an existing file of the same name instead of numbering.
  bool replace;
  String? finalName;
}

class ReceivedTransfer {
  ReceivedTransfer({
    required this.id,
    required this.label,
    required this.integrity,
    required this.createdAt,
    required this.files,
    this.peerId,
  })  : byId = {for (final f in files) f.id: f},
        bytesTotal = files.fold(0, (s, f) => s + f.size);

  final String id;
  final String label;
  final IntegrityAlgo integrity;
  final int createdAt;
  final List<ReceivedFile> files;
  final Map<String, ReceivedFile> byId;
  final int bytesTotal;
  final String? peerId;
  int bytesDone = 0;
  int filesDone = 0;
  int filesVerified = 0;
  bool get finished => files.every((f) => f.state == FileState.complete || f.state == FileState.skipped);
}

class ReceiverOptions {
  ReceiverOptions({
    required this.sinks,
    required this.accept,
    this.state,
    this.maxFileSize,
    DuplicatePolicy Function()? duplicates,
    this.onProgress,
    this.onComplete,
    this.onForget,
  }) : duplicates = duplicates ?? (() => DuplicatePolicy.keepBoth);

  final SinkFactory sinks;
  final StateStore? state;

  /// A person decides. Resolve false to decline. Called once per new transfer.
  final Future<bool> Function(IncomingManifest offer) accept;
  final int? maxFileSize;
  final DuplicatePolicy Function() duplicates;
  final void Function(ReceivedTransfer t)? onProgress;
  final void Function(ReceivedTransfer t)? onComplete;
  final void Function(String transferId)? onForget;
}

const int _maxBody = (maxBlocksPerChunk * blockSize > batchTargetBytes ? maxBlocksPerChunk * blockSize : batchTargetBytes) + (2 << 20);

/// Bodies in reassembly across all pipelined requests on one link.
const int maxReassemblyBytes = 96 << 20;

class Receiver {
  Receiver(this.opts);

  final ReceiverOptions opts;
  final _transfers = <String, ReceivedTransfer>{};
  final _sinks = <String, Future<FileSink>>{};
  final _persistTimers = <String, Timer>{};
  final _deciding = <String, Future<bool>>{};

  ReceivedTransfer? get(String transferId) => _transfers[transferId];
  Iterable<ReceivedTransfer> get transfers => _transfers.values;

  /// Serve one link. Several links over time (reconnects) share this receiver's state.
  void serve(Link link, {String? peerId}) {
    final bodies = <int, ({RequestMessage req, Uint8List buf, int got})>{};
    final aborted = <int>{};
    var reassembling = 0;

    void release(int id) {
      final b = bodies.remove(id);
      if (b != null) reassembling -= b.buf.length;
    }

    void respond(int id, Future<Object?> Function() work) {
      work().then((result) {
        if (!aborted.contains(id) && link.isOpen) link.sendControl(ResponseMessage.ok(id, result)).ignore();
      }, onError: (Object err) {
        final code = err is ProtocolException ? err.code.wire : 'SERVER';
        if (!aborted.contains(id) && link.isOpen) link.sendControl(ResponseMessage.error(id, code)).ignore();
      });
    }

    final controlSub = link.control.listen((m) {
      switch (m) {
        case AbortMessage(:final id):
          aborted.add(id);
          release(id);
        case RequestMessage(:final id, :final op, :final args, :final bodyLength):
          final len = bodyLength ?? 0;
          if (len > 0) {
            if (len > _maxBody || reassembling + len > maxReassemblyBytes) {
              link.sendControl(ResponseMessage.error(id, ErrorCode.tooLarge.wire)).ignore();
              aborted.add(id);
              return;
            }
            reassembling += len;
            bodies[id] = (req: m, buf: Uint8List(len), got: 0);
            return;
          }
          respond(id, () => handle(op, args, Uint8List(0), peerId: peerId));
        default:
          break;
      }
    });

    final dataSub = link.data.listen((f) {
      final b = bodies[f.requestId];
      if (b == null) return; // aborted or rejected
      if (f.offset + f.bytes.length > b.buf.length) {
        release(f.requestId);
        link.sendControl(ResponseMessage.error(f.requestId, ErrorCode.badFrame.wire)).ignore();
        return;
      }
      b.buf.setRange(f.offset, f.offset + f.bytes.length, f.bytes);
      final got = b.got + f.bytes.length;
      if (got < b.buf.length) {
        bodies[f.requestId] = (req: b.req, buf: b.buf, got: got);
        return;
      }
      release(f.requestId);
      respond(f.requestId, () => handle(b.req.op, b.req.args, b.buf, peerId: peerId));
    });

    link.closed.then((_) {
      controlSub.cancel();
      dataSub.cancel();
      bodies.clear();
    });
  }

  /// Drop a transfer and all its bookkeeping (cancel, decline after the fact).
  Future<void> forget(String transferId) async {
    final t = _transfers.remove(transferId);
    if (t != null) {
      for (final f in t.files) {
        await _closeSink(t, f);
      }
    }
    _persistTimers.remove(transferId)?.cancel();
    await opts.sinks.remove(transferId);
    await opts.state?.remove(transferId);
    opts.onForget?.call(transferId);
  }

  // ---------------------------------------------------------------------------

  /// One protocol request (what [serve] does per request). Lane isolates call this through
  /// their coordinator, so every connection shares this receiver's single state.
  Future<Object?> handle(String op, Object? args, Uint8List body, {String? peerId}) async {
    final a = (args is Map<String, Object?>) ? args : const <String, Object?>{};
    switch (op) {
      case 'ping':
        return const <String, Object?>{};
      case 'create':
        final Manifest manifest;
        try {
          manifest = Manifest.fromJson(a);
        } on ProtocolException {
          rethrow;
        } catch (_) {
          throw ProtocolException(ErrorCode.badRequest, 'bad manifest');
        }
        return _create(manifest, peerId);
      case 'status':
        return _status(await _need(a['transferId'])).toJson();
      case 'blocks':
        await _writeBlocks(await _need(a['transferId']), '${a['fileId']}', (a['start'] as num?)?.toInt() ?? -1, body, '${a['hashes'] ?? ''}');
        return const {'load': 0};
      case 'batch':
        await _writeBatch(await _need(a['transferId']), body);
        return const {'load': 0};
      case 'complete':
        return {'finalName': await _complete(await _need(a['transferId']), '${a['fileId']}', '${a['root'] ?? ''}')};
      case 'cancel':
        final t = await _find('${a['transferId']}');
        if (t != null) await forget(t.id);
        return const <String, Object?>{};
      default:
        throw ProtocolException(ErrorCode.badRequest, 'unknown op $op');
    }
  }

  Future<Map<String, Object?>> _create(Manifest input, String? peerId) async {
    if (input.direction != Direction.toPeer) throw ProtocolException(ErrorCode.forbidden);
    final existing = await _find(input.transferId);
    if (existing != null) {
      if (existing.files.length != input.files.length || input.files.any((f) => existing.byId[f.id]?.size != f.size)) {
        throw ProtocolException(ErrorCode.badRequest, 'manifest changed');
      }
      return {'status': _status(existing).toJson()};
    }
    final max = opts.maxFileSize;
    if (max != null && input.files.any((f) => f.size > max)) throw ProtocolException(ErrorCode.tooLarge);
    if (input.files.map((f) => f.id).toSet().length != input.files.length) {
      throw ProtocolException(ErrorCode.badRequest, 'duplicate file id');
    }

    final files = [
      for (final f in input.files)
        ReceivedFile(
          id: f.id,
          name: sanitizeFileName(f.name),
          relDir: sanitizeRelativeDir(f.relDir),
          size: f.size,
          type: f.type.length > 255 ? f.type.substring(0, 255) : f.type,
          lastModified: f.lastModified,
          state: FileState.fresh,
          received: Bitset((f.size + blockSize - 1) ~/ blockSize),
        ),
    ];
    final offer = IncomingManifest(
      transferId: input.transferId,
      label: input.label.length > 200 ? input.label.substring(0, 200) : input.label,
      files: [for (final f in files) IncomingFile(id: f.id, name: f.name, relDir: f.relDir.join('/'), size: f.size, type: f.type)],
      totalBytes: files.fold(0, (s, f) => s + f.size),
      peerId: peerId,
    );
    final free = await opts.sinks.freeSpace();
    if (free != null && free < offer.totalBytes) throw ProtocolException(ErrorCode.diskFull);

    // A sender retrying create while the person is still deciding must not ask twice.
    final decision = _deciding.putIfAbsent(input.transferId, () => opts.accept(offer));
    final bool ok;
    try {
      ok = await decision;
    } finally {
      _deciding.remove(input.transferId);
    }
    if (!ok) throw ProtocolException(ErrorCode.declined);
    final raced = _transfers[input.transferId];
    if (raced != null) return {'status': _status(raced).toJson()};

    final policy = opts.duplicates();
    for (final f in files) {
      if (policy == DuplicatePolicy.keepBoth) break;
      if (await opts.sinks.exists(f.relDir, f.name)) {
        if (policy == DuplicatePolicy.skip) {
          f.state = FileState.skipped;
        } else {
          f.replace = true;
        }
      }
    }

    final t = ReceivedTransfer(
      id: input.transferId,
      label: offer.label,
      integrity: input.integrity,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      files: files,
      peerId: peerId,
    );
    _transfers[t.id] = t;
    await _persist(t);
    opts.onProgress?.call(t);
    return {'status': _status(t).toJson()};
  }

  TransferStatus _status(ReceivedTransfer t) => TransferStatus(
        transferId: t.id,
        blockSize: blockSize,
        integrity: t.integrity,
        files: [
          for (final f in t.files)
            FileStatus(
              id: f.id,
              state: f.state,
              received: f.state == FileState.partial ? f.received.toBase64() : null,
              finalName: f.state == FileState.complete ? (f.finalName ?? [...f.relDir, f.name].join('/')) : null,
            ),
        ],
      );

  Future<void> _writeBlocks(ReceivedTransfer t, String fileId, int start, Uint8List body, String hashesB64) async {
    final f = t.byId[fileId];
    if (f == null) throw ProtocolException(ErrorCode.notFound);
    if (f.state == FileState.complete || f.state == FileState.skipped) return;
    final blocks = f.received.size;
    if (start < 0 || start >= blocks) throw ProtocolException(ErrorCode.badRequest, 'block out of range');
    final count = (body.length + blockSize - 1) ~/ blockSize;
    final from = start * blockSize;
    if (count < 1 || count > maxBlocksPerChunk) throw ProtocolException(ErrorCode.badRequest, 'bad block count');
    final end = (start + count) * blockSize < f.size ? (start + count) * blockSize : f.size;
    if (body.length != end - from) throw ProtocolException(ErrorCode.badRequest, 'body length does not match block range');
    final hasher = blockHasher(t.integrity);
    final Uint8List claimed;
    try {
      claimed = base64UrlToBytes(hashesB64);
    } catch (_) {
      throw ProtocolException(ErrorCode.badRequest, 'bad block hashes');
    }
    if (claimed.length != count * hasher.length) throw ProtocolException(ErrorCode.badRequest, 'missing block hashes');
    final actual = hasher.hashBlocks(body, blockSize);
    if (!bytesEqual(actual, claimed)) throw ProtocolException(ErrorCode.integrity);
    try {
      await (await _sink(t, f)).write(from, body);
    } catch (err) {
      throw _storageError(err);
    }
    final digests = f.digests ??= Uint8List(blocks * hasher.length);
    digests.setRange(start * hasher.length, start * hasher.length + actual.length, actual);
    var fresh = 0;
    for (var i = 0; i < count; i++) {
      if (f.received.set(start + i)) fresh++;
    }
    if (f.state == FileState.fresh) f.state = FileState.partial;
    t.bytesDone += fresh == count ? body.length : (body.length * fresh / count).round();
    _touch(t);
  }

  Future<void> _writeBatch(ReceivedTransfer t, Uint8List frame) async {
    final batch = decodeBatch(frame);
    final hasher = blockHasher(t.integrity);
    final work = <(ReceivedFile, Uint8List)>[];
    var offset = 0;
    for (final e in batch.files) {
      final f = t.byId[e.id];
      final data = Uint8List.sublistView(batch.payload, offset, offset + e.size);
      offset += e.size;
      if (f == null) throw ProtocolException(ErrorCode.notFound);
      if (f.size != e.size) throw ProtocolException(ErrorCode.badRequest, 'size mismatch');
      if (f.state == FileState.complete || f.state == FileState.skipped) continue;
      if (bytesToBase64Url(hasher.hashBlocks(data, blockSize)) != e.hash) throw ProtocolException(ErrorCode.integrity);
      work.add((f, data));
    }
    try {
      // Small files land concurrently (the sink may spread them over worker isolates).
      await Future.wait([for (final (f, data) in work) opts.sinks.writeWhole(t.id, f.id, data)]);
      final names = await Future.wait([
        for (final (f, _) in work)
          opts.sinks.finish(t.id, f.id, relDir: f.relDir, name: f.name, lastModified: f.lastModified, replace: f.replace),
      ]);
      for (var i = 0; i < work.length; i++) {
        work[i].$1.finalName = names[i];
      }
    } catch (err) {
      throw _storageError(err);
    }
    for (final (f, _) in work) {
      f.received = Bitset.full(f.received.size);
      f.state = FileState.complete;
      f.digests = null;
      t.bytesDone += f.size;
      t.filesDone++;
      t.filesVerified++;
    }
    _touch(t);
    await _checkDone(t);
  }

  Future<String> _complete(ReceivedTransfer t, String fileId, String root) async {
    final f = t.byId[fileId];
    if (f == null) throw ProtocolException(ErrorCode.notFound);
    if (f.state == FileState.complete || f.state == FileState.skipped) return f.finalName ?? [...f.relDir, f.name].join('/');
    if (!f.received.complete) throw ProtocolException(ErrorCode.incomplete);
    final hasher = blockHasher(t.integrity);
    if (hasher.root(f.digests ?? Uint8List(0)) != root) {
      await _closeSink(t, f);
      await opts.sinks.discard(t.id, f.id);
      t.bytesDone -= f.size;
      f.received = Bitset(f.received.size);
      f.digests = null;
      f.state = FileState.fresh;
      _touch(t);
      throw ProtocolException(ErrorCode.integrity);
    }
    await _closeSink(t, f);
    try {
      f.finalName = await opts.sinks.finish(t.id, f.id, relDir: f.relDir, name: f.name, lastModified: f.lastModified, replace: f.replace);
    } catch (err) {
      throw _storageError(err);
    }
    f.state = FileState.complete;
    f.digests = null;
    t.filesDone++;
    t.filesVerified++;
    _touch(t);
    await _checkDone(t);
    return f.finalName!;
  }

  Future<void> _checkDone(ReceivedTransfer t) async {
    if (!t.finished) return;
    // Every file is in its final place: only the record in memory remains, so a late
    // status/complete from the sender still gets an answer. No bookkeeping on disk.
    _persistTimers.remove(t.id)?.cancel();
    await opts.state?.remove(t.id);
    await opts.sinks.remove(t.id);
    opts.onComplete?.call(t);
  }

  Future<ReceivedTransfer> _need(Object? id) async {
    final t = await _find('$id');
    if (t == null) throw ProtocolException(ErrorCode.notFound);
    return t;
  }

  Future<ReceivedTransfer?> _find(String id) async {
    final live = _transfers[id];
    if (live != null) return live;
    final String? raw;
    try {
      raw = await opts.state?.load(id);
    } catch (_) {
      return null;
    }
    if (raw == null) return null;
    try {
      final t = _revive(jsonDecode(raw) as Map<String, Object?>);
      _transfers[t.id] = t;
      return t;
    } catch (_) {
      return null;
    }
  }

  Future<FileSink> _sink(ReceivedTransfer t, ReceivedFile f) {
    final key = '${t.id}/${f.id}';
    final existing = _sinks[key];
    if (existing != null) return existing;
    final s = opts.sinks.open(t.id, f.id, f.size);
    _sinks[key] = s;
    s.catchError((Object _) {
      _sinks.remove(key);
      return s;
    }).ignore();
    return s;
  }

  Future<void> _closeSink(ReceivedTransfer t, ReceivedFile f) async {
    final s = _sinks.remove('${t.id}/${f.id}');
    if (s == null) return;
    await (await s).close();
  }

  void _touch(ReceivedTransfer t) {
    opts.onProgress?.call(t);
    if (opts.state == null || _persistTimers.containsKey(t.id)) return;
    _persistTimers[t.id] = Timer(const Duration(seconds: 1), () {
      _persistTimers.remove(t.id);
      _persist(t).ignore();
    });
  }

  /// Persist resume state now (debounced saves happen automatically).
  Future<void> flush() async {
    for (final id in _persistTimers.keys.toList()) {
      _persistTimers.remove(id)?.cancel();
      final t = _transfers[id];
      if (t != null) await _persist(t);
    }
  }

  Future<void> _persist(ReceivedTransfer t) async {
    final store = opts.state;
    if (store == null || !_transfers.containsKey(t.id) || t.finished) return;
    await store.save(
      t.id,
      jsonEncode({
        'v': 1,
        'id': t.id,
        'label': t.label,
        'integrity': t.integrity.wire,
        'createdAt': t.createdAt,
        'peerId': ?t.peerId,
        'files': [
          for (final f in t.files)
            {
              'id': f.id,
              'name': f.name,
              'relDir': f.relDir,
              'size': f.size,
              'type': f.type,
              'lastModified': f.lastModified,
              'state': f.state.wire,
              if (f.replace) 'replace': true,
              'finalName': ?f.finalName,
              if (f.state == FileState.partial) ...{
                'received': f.received.toBase64(),
                if (f.digests != null) 'digests': bytesToBase64Url(f.digests!),
              },
            },
        ],
      }),
    );
  }

  ReceivedTransfer _revive(Map<String, Object?> p) {
    if (p['v'] != 1) throw const FormatException('unknown state version');
    final integrity = IntegrityAlgo.fromWire(p['integrity'] as String);
    final len = blockHasher(integrity).length;
    final files = [
      for (final raw in p['files'] as List<Object?>)
        () {
          final pf = raw as Map<String, Object?>;
          final size = (pf['size'] as num).toInt();
          final blocks = (size + blockSize - 1) ~/ blockSize;
          final state = FileState.fromWire(pf['state'] as String);
          Uint8List? digests;
          if (pf['digests'] is String) {
            digests = Uint8List(blocks * len);
            final d = base64UrlToBytes(pf['digests'] as String);
            digests.setRange(0, d.length < digests.length ? d.length : digests.length, d);
          }
          return ReceivedFile(
            id: pf['id'] as String,
            name: sanitizeFileName(pf['name'] as String),
            relDir: [for (final s in pf['relDir'] as List<Object?>) sanitizeFileName(s as String, 'folder')],
            size: size,
            type: (pf['type'] as String?) ?? '',
            lastModified: (pf['lastModified'] as num?)?.toInt() ?? 0,
            state: state,
            received: state == FileState.complete
                ? Bitset.full(blocks)
                : (pf['received'] is String ? Bitset.fromBase64(blocks, pf['received'] as String) : Bitset(blocks)),
            digests: digests,
            replace: pf['replace'] == true,
            finalName: pf['finalName'] as String?,
          );
        }(),
    ];
    final t = ReceivedTransfer(
      id: p['id'] as String,
      label: (p['label'] as String?) ?? '',
      integrity: integrity,
      createdAt: (p['createdAt'] as num?)?.toInt() ?? 0,
      files: files,
      peerId: p['peerId'] as String?,
    );
    for (final f in files) {
      if (f.state == FileState.complete) {
        t.bytesDone += f.size;
        t.filesDone++;
        t.filesVerified++;
      } else if (f.state == FileState.partial) {
        final got = f.received.count * blockSize;
        t.bytesDone += got < f.size ? got : f.size;
      }
    }
    return t;
  }
}

ProtocolException _storageError(Object err) {
  if (err is ProtocolException) return err;
  final text = '$err'.toLowerCase();
  if (text.contains('no space') || text.contains('disk full') || text.contains('errno = 28') || text.contains('errno = 112')) {
    return ProtocolException(ErrorCode.diskFull);
  }
  return ProtocolException(ErrorCode.diskWrite, '$err');
}
