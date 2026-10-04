import '../protocol/constants.dart';
import '../protocol/types.dart';
import '../util/bitset.dart';

/// Decides what to send next. Port of `packages/transfer-engine/src/planner.ts`.
///
/// Large files are cut into block ranges on demand (range = the controller's current chunk
/// size); small files are packed into batch frames. Every block is missing, claimed (in
/// flight) or acked; failures release claims; nothing acked is ever re-sent.

enum PlanState { pending, complete, skipped, failed }

class PlanFile {
  PlanFile(this.index, this.id, this.size, int blockSize)
      : blocks = (size + blockSize - 1) ~/ blockSize,
        small = size <= smallFileMax {
    acked = Bitset(blocks);
    claimed = Bitset(blocks);
  }

  final int index;
  final String id;
  final int size;
  final int blocks;
  final bool small;
  PlanState state = PlanState.pending;
  late Bitset acked;
  late Bitset claimed;

  /// scan position for the next unclaimed block
  int cursor = 0;

  /// integrity failures on this file; network failures don't count
  int strikes = 0;
  bool inBatch = false;
  bool completing = false;
  String? finalName;
}

sealed class WorkItem {
  const WorkItem();
}

final class CompleteItem extends WorkItem {
  const CompleteItem(this.file);
  final PlanFile file;
}

final class BlocksItem extends WorkItem {
  const BlocksItem(this.file, this.start, this.count);
  final PlanFile file;
  final int start;
  final int count;
}

final class BatchItem extends WorkItem {
  const BatchItem(this.files, this.bytes);
  final List<PlanFile> files;
  final int bytes;
}

class Planner {
  Planner(List<({String id, int size})> files, this.blockSize)
      : files = [for (var i = 0; i < files.length; i++) PlanFile(i, files[i].id, files[i].size, blockSize)] {
    for (final f in this.files) {
      (f.small ? _smallOrder : _largeOrder).add(f.index);
    }
  }

  final int blockSize;
  final List<PlanFile> files;
  int _largeCursor = 0;
  int _smallCursor = 0;
  bool _flip = false;
  final List<int> _largeOrder = [];
  final List<int> _smallOrder = [];
  List<PlanFile> _toComplete = [];

  /// Adopt the receiver's view (fresh create or resume after reconnect). Drops all claims.
  void applyStatus(TransferStatus status) {
    final byId = {for (final s in status.files) s.id: s};
    for (final f in files) {
      final s = byId[f.id];
      f.claimed = Bitset(f.blocks);
      f.cursor = 0;
      f.inBatch = false;
      f.completing = false;
      if (s == null) continue;
      if (s.finalName != null) f.finalName = s.finalName;
      if (s.state == FileState.complete) {
        f.state = PlanState.complete;
        f.acked = Bitset.full(f.blocks);
      } else if (s.state == FileState.skipped) {
        f.state = PlanState.skipped;
      } else if (f.state != PlanState.failed) {
        f.state = PlanState.pending;
        f.acked = s.state == FileState.partial && s.received != null
            ? Bitset.fromBase64(f.blocks, s.received!)
            : Bitset(f.blocks);
      }
      for (var i = 0; i < f.blocks; i++) {
        if (f.acked.has(i)) f.claimed.set(i);
      }
    }
    _largeCursor = 0;
    _smallCursor = 0;
    _toComplete = files.where((f) => f.state == PlanState.pending && !f.small && f.acked.complete).toList();
  }

  static const _firstBatchFiles = 4;
  var _batchesIssued = 0;

  WorkItem? next(int blocksPerChunk) {
    if (_toComplete.isNotEmpty) {
      final done = _toComplete.removeAt(0);
      done.completing = true;
      return CompleteItem(done);
    }
    // Alternate so a folder of mixed sizes shows progress on both fronts.
    _flip = !_flip;
    final first = _flip ? _nextBatch(blocksPerChunk) : _nextRange(blocksPerChunk);
    if (first != null) return first;
    return _flip ? _nextRange(blocksPerChunk) : _nextBatch(blocksPerChunk);
  }

  WorkItem? _nextRange(int blocksPerChunk) {
    for (var k = _largeCursor; k < _largeOrder.length; k++) {
      final f = files[_largeOrder[k]];
      if (f.state != PlanState.pending) {
        if (k == _largeCursor) _largeCursor++;
        continue;
      }
      while (f.cursor < f.blocks && f.claimed.has(f.cursor)) {
        f.cursor++;
      }
      if (f.cursor >= f.blocks) continue; // fully claimed, waiting on acks
      final start = f.cursor;
      var count = 0;
      while (count < blocksPerChunk && start + count < f.blocks && !f.claimed.has(start + count)) {
        f.claimed.set(start + count);
        count++;
      }
      f.cursor = start + count;
      return BlocksItem(f, start, count);
    }
    return null;
  }

  WorkItem? _nextBatch(int blocksPerChunk) {
    final byChunk = (blocksPerChunk < 1 ? 1 : blocksPerChunk) * blockSize;
    final limit = batchTargetBytes < byChunk ? batchTargetBytes : byChunk;
    // Slow start, as in the TypeScript planner: the first batches carry 4, 8, 16, ... files
    // so the first bytes go out after one small read, not after the whole first frame.
    final ramp = _firstBatchFiles << (_batchesIssued < 16 ? _batchesIssued : 16);
    final maxFiles = ramp < batchMaxFiles ? ramp : batchMaxFiles;
    final picked = <PlanFile>[];
    var bytes = 0;
    for (var k = _smallCursor; k < _smallOrder.length; k++) {
      final f = files[_smallOrder[k]];
      if (f.state != PlanState.pending || f.inBatch) {
        if (k == _smallCursor && f.state != PlanState.pending) _smallCursor++;
        continue;
      }
      if (picked.isNotEmpty && (bytes + f.size > limit || picked.length >= maxFiles)) break;
      f.inBatch = true;
      picked.add(f);
      bytes += f.size;
    }
    if (picked.isEmpty) return null;
    _batchesIssued++;
    return BatchItem(picked, bytes);
  }

  /// Request succeeded. Returns files that just became complete (batches) or ready to confirm.
  List<PlanFile> ack(WorkItem item) {
    switch (item) {
      case CompleteItem(:final file):
        file.completing = false;
        file.state = PlanState.complete;
        return [file];
      case BatchItem(:final files):
        for (final f in files) {
          f.inBatch = false;
          f.state = PlanState.complete;
          for (var i = 0; i < f.blocks; i++) {
            f.acked.set(i);
          }
        }
        return files;
      case BlocksItem(:final file, :final start, :final count):
        for (var i = start; i < start + count; i++) {
          file.acked.set(i);
        }
        if (file.acked.complete && !file.completing && !_toComplete.contains(file)) {
          _toComplete.add(file);
          return [file];
        }
        return const [];
    }
  }

  /// Request failed: make its blocks available again.
  void release(WorkItem item) {
    switch (item) {
      case CompleteItem(:final file):
        file.completing = false;
        if (file.state == PlanState.pending) _toComplete.add(file);
      case BatchItem(:final files):
        for (final f in files) {
          f.inBatch = false;
        }
        var min = _smallCursor;
        for (final f in files) {
          final pos = _smallOrder.indexOf(f.index);
          if (pos < min) min = pos;
        }
        _smallCursor = min;
      case BlocksItem(:final file, :final start, :final count):
        final fresh = Bitset(file.blocks);
        for (var i = 0; i < file.blocks; i++) {
          final inItem = i >= start && i < start + count;
          if (file.claimed.has(i) && (!inItem || file.acked.has(i))) fresh.set(i);
        }
        file.claimed = fresh;
        if (start < file.cursor) file.cursor = start;
        final pos = _largeOrder.indexOf(file.index);
        if (pos >= 0 && pos < _largeCursor) _largeCursor = pos;
    }
  }

  /// Receiver rejected the whole file (e.g. root mismatch): start it over.
  void resetFile(PlanFile f) {
    _toComplete = _toComplete.where((x) => x != f).toList();
    f.completing = false;
    f.acked = Bitset(f.blocks);
    f.claimed = Bitset(f.blocks);
    f.cursor = 0;
    f.state = PlanState.pending;
    final order = f.small ? _smallOrder : _largeOrder;
    final pos = order.indexOf(f.index);
    if (f.small) {
      if (pos < _smallCursor) _smallCursor = pos;
    } else {
      if (pos < _largeCursor) _largeCursor = pos;
    }
  }

  bool get finished => _toComplete.isEmpty && files.every((f) => f.state != PlanState.pending);

  int ackedBytes(PlanFile f) {
    if (f.state == PlanState.complete) return f.size;
    if (f.blocks == 0) return 0;
    var n = f.acked.count * blockSize;
    if (f.acked.has(f.blocks - 1)) n -= f.blocks * blockSize - f.size;
    return n;
  }
}
