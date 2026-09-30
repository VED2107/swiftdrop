import 'dart:async';
import 'dart:typed_data';

import '../platform/files.dart';
import '../protocol/batch.dart';
import '../protocol/constants.dart';
import '../protocol/errors.dart';
import '../protocol/types.dart';
import '../transport/engine_transport.dart';
import '../util/base64url.dart';
import '../util/bitset.dart';
import '../util/hashing.dart';
import '../util/random.dart';
import 'controller.dart';
import 'planner.dart';
import 'speed_meter.dart';

/// One transfer: a set of files moving to one receiver. Port of
/// `packages/transfer-engine/src/job.ts`, same scheduler, read-ahead, memory budget,
/// reconnect loop and error policy. Reads go through [FileSource] positional readers, so a
/// file is never held whole; at most `memoryBudget` bytes are read and in flight.
/// Nothing here renders or reports per chunk: callers poll [snapshot] on their own clock.

enum JobState { queued, preparing, awaitingDecision, running, paused, reconnecting, complete, failed, cancelled }

typedef ConflictResolver = Future<Map<String, ConflictPolicy>?> Function(List<Conflict> conflicts);

class JobOptions {
  JobOptions({
    required this.transport,
    required this.files,
    required this.direction,
    this.label = '',
    this.transferId,
    this.integrity = IntegrityAlgo.xxh64,
    this.onConflict,
    this.resolveConflicts,
    this.controller = desktopController,
    this.sampleInterval = const Duration(seconds: 1),
    this.maxOpenReaders = 8,
    double Function()? now,
  }) : now = now ?? _monotonicMs;

  final EngineTransport transport;
  final List<FileSource> files;
  final Direction direction;
  final String label;
  final String? transferId;
  final IntegrityAlgo integrity;
  final ConflictPolicy? onConflict;
  final ConflictResolver? resolveConflicts;
  final ControllerConfig controller;
  final Duration sampleInterval;
  final int maxOpenReaders;
  final double Function() now;
}

class JobSnapshot {
  const JobSnapshot({
    required this.transferId,
    required this.label,
    required this.state,
    required this.errorCode,
    required this.bytesDone,
    required this.bytesTotal,
    required this.filesDone,
    required this.filesSkipped,
    required this.filesFailed,
    required this.filesTotal,
    required this.speed,
    required this.average,
    required this.peak,
    required this.etaSeconds,
    required this.streams,
    required this.chunkBytes,
    required this.inflight,
    required this.retries,
    required this.reconnects,
    required this.elapsedSeconds,
  });

  final String transferId;
  final String label;
  final JobState state;
  final ErrorCode? errorCode;
  final int bytesDone;
  final int bytesTotal;
  final int filesDone;
  final int filesSkipped;
  final int filesFailed;
  final int filesTotal;

  /// Measured bytes/s over the rolling window.
  final double speed;
  final double average;
  final double peak;

  /// Infinity when unknown.
  final double etaSeconds;
  final int streams;
  final int chunkBytes;
  final int inflight;
  final int retries;
  final int reconnects;
  final double elapsedSeconds;
}

/// Where time and bytes go; also proves the memory bound in tests.
class JobTelemetry {
  double readMs = 0;
  double hashMs = 0;
  double frameMs = 0;
  double networkMs = 0;
  double completeMs = 0;
  int requests = 0;
  int wireBytes = 0;
  int inflightBytes = 0;
  int peakInflightBytes = 0;
}

class _Flight {
  _Flight(this.item, this.startedAt, this.bytes);
  final WorkItem item;
  final CancelToken cancel = CancelToken();
  final double startedAt;
  final int bytes;
  bool intentional = false;
}

sealed class _Prepared {}

class _PreparedBlocks extends _Prepared {
  _PreparedBlocks(this.body, this.digests);
  final Uint8List body;
  final Uint8List digests;
}

class _PreparedBatch extends _Prepared {
  _PreparedBatch(this.frame);
  final Uint8List frame;
}

class _Ahead {
  _Ahead(this.item, this.bytes, this.data);
  final WorkItem item;
  final int bytes;
  final Future<_Prepared>? data;
}

class _HashStore {
  _HashStore(int blocks, int len)
      : digests = Uint8List(blocks * len),
        known = Bitset(blocks);
  final Uint8List digests;
  final Bitset known;
}

const _maxStrikes = 5;

class TransferJob {
  TransferJob(JobOptions opts)
      : _opts = opts,
        id = opts.transferId ?? 'tr_${_randomId()}',
        label = opts.label,
        direction = opts.direction,
        files = opts.files,
        bytesTotal = opts.files.fold(0, (s, f) => s + f.size),
        _controller = AdaptiveController(opts.controller),
        _planner = Planner([for (final f in opts.files) (id: f.id, size: f.size)], blockSize),
        _meter = SpeedMeter(now: opts.now),
        _fileMeter = SpeedMeter(now: opts.now),
        _hasher = blockHasher(opts.integrity);

  final String id;
  final String label;
  final Direction direction;
  final List<FileSource> files;
  final int bytesTotal;

  final JobOptions _opts;
  final AdaptiveController _controller;
  final Planner _planner;
  final SpeedMeter _meter;
  final SpeedMeter _fileMeter;
  final BlockHasher _hasher;
  final _flights = <_Flight>{};
  _Ahead? _ahead;
  final _hashes = <int, _HashStore>{};
  final _listeners = <void Function()>[];
  final _readers = <int, Future<ByteReader>>{};
  final telemetry = JobTelemetry();

  JobState _state = JobState.queued;
  ErrorCode? _errorCode;
  int _bytesDone = 0;
  int _filesDone = 0;
  int _filesSkipped = 0;
  int _retries = 0;
  int _reconnects = 0;
  int _consecutiveServerErrors = 0;
  bool _reconnectLoop = false;

  Timer? _sampleTimer;
  double _sampleStart = 0;
  int _sampleBytes = 0;
  double _sampleLatencySum = 0;
  int _sampleLatencyCount = 0;
  int _sampleErrors = 0;
  double _sampleLoad = 0;

  final _done = Completer<void>();
  Future<void> get done => _done.future;
  JobState get state => _state;
  EngineTransport get _transport => _opts.transport;

  /// Called on every state change (not per chunk).
  void Function() onChange(void Function() fn) {
    _listeners.add(fn);
    return () => _listeners.remove(fn);
  }

  Future<void> start() async {
    if (_state != JobState.queued) return;
    _setState(JobState.preparing);
    try {
      final status = await _negotiate();
      if (status == null) return;
      _adopt(status);
      _run();
    } catch (err) {
      _handleFatal(err);
    }
  }

  void pause() {
    if (_state != JobState.running && _state != JobState.reconnecting) return;
    _abortAll();
    _meter.stop();
    _fileMeter.stop();
    _stopSampling();
    _setState(JobState.paused);
  }

  void resume() {
    if (_state != JobState.paused && _state != JobState.failed) return;
    _errorCode = null;
    unawaited(_reconnect(false));
  }

  Future<void> cancel() async {
    if (_state == JobState.complete || _state == JobState.cancelled) return;
    _abortAll();
    _stopSampling();
    _meter.stop();
    _setState(JobState.cancelled);
    _finishDone();
    try {
      await _transport.cancel(id);
    } catch (_) {
      // receiver may already be gone
    }
  }

  /// Re-queue files that exhausted their retries.
  void retryFailed() {
    var any = false;
    for (final f in _planner.files) {
      if (f.state == PlanState.failed) {
        f.strikes = 0;
        _planner.resetFile(f);
        any = true;
      }
    }
    if (any && (_state == JobState.failed || _state == JobState.paused)) {
      _errorCode = null;
      unawaited(_reconnect(false));
    }
  }

  JobSnapshot snapshot() {
    final running = _state == JobState.running;
    final speed = running ? _meter.rate() : 0.0;
    final average = _meter.average();
    final remaining = bytesTotal - _bytesDone < 0 ? 0 : bytesTotal - _bytesDone;
    final basis = speed > 0 ? speed * 0.7 + average * 0.3 : average;
    return JobSnapshot(
      transferId: id,
      label: label,
      state: _state,
      errorCode: _errorCode,
      bytesDone: _bytesDone,
      bytesTotal: bytesTotal,
      filesDone: _filesDone,
      filesSkipped: _filesSkipped,
      filesFailed: _planner.files.where((f) => f.state == PlanState.failed).length,
      filesTotal: files.length,
      speed: speed,
      average: average,
      peak: _meter.peak,
      etaSeconds: remaining == 0 ? 0 : (basis > 0 ? remaining / basis : double.infinity),
      streams: _controller.streams,
      chunkBytes: _controller.blocksPerChunk * blockSize,
      inflight: _flights.length,
      retries: _retries,
      reconnects: _reconnects,
      elapsedSeconds: _meter.activeSeconds,
    );
  }

  /// Name the receiver stored a file under, once complete.
  String? finalName(int index) => _planner.files[index].finalName;

  // ---------------------------------------------------------------------------

  Future<TransferStatus?> _negotiate() async {
    Manifest manifest({ConflictPolicy? policy, Map<String, ConflictPolicy> decisions = const {}}) => Manifest(
          transferId: id,
          direction: direction,
          label: label,
          integrity: _hasher.algo,
          onConflict: policy ?? _opts.onConflict ?? (_opts.resolveConflicts != null ? ConflictPolicy.ask : ConflictPolicy.keepBoth),
          decisions: decisions,
          files: [
            for (final f in files)
              FileEntry(id: f.id, name: f.name, relDir: f.relDir, size: f.size, type: f.type, lastModified: f.lastModified < 0 ? 0 : f.lastModified),
          ],
        );
    final first = await _transport.create(manifest());
    switch (first) {
      case Created(:final status):
        return status;
      case Conflicts(:final conflicts):
        _setState(JobState.awaitingDecision);
        final decisions = await _opts.resolveConflicts!(conflicts);
        if (decisions == null) {
          await cancel();
          return null;
        }
        final second = await _transport.create(manifest(policy: ConflictPolicy.keepBoth, decisions: decisions));
        if (second is Created) return second.status;
        throw TransportException(ErrorCode.badRequest);
    }
  }

  void _adopt(TransferStatus status) {
    _planner.applyStatus(status);
    _bytesDone = 0;
    _filesDone = 0;
    _filesSkipped = 0;
    for (final f in _planner.files) {
      if (f.state == PlanState.skipped) {
        _filesSkipped++;
      } else {
        _bytesDone += _planner.ackedBytes(f);
        if (f.state == PlanState.complete) _filesDone++;
      }
    }
  }

  void _run() {
    _setState(JobState.running);
    _meter.start();
    _fileMeter.start();
    _startSampling();
    _pump();
  }

  void _pump() {
    if (_state != JobState.running) return;
    while (_flights.length < _controller.streams) {
      final ahead = _ahead;
      if (ahead != null) {
        _ahead = null;
        telemetry.inflightBytes -= ahead.bytes; // _launch counts it again as a flight
        _launch(ahead.item, ahead.data);
        continue;
      }
      final item = _planner.next(_controller.blocksPerChunk);
      if (item == null) break;
      _launch(item);
    }
    _readAhead();
    if (_flights.isEmpty && _ahead == null && _planner.finished) _finish();
  }

  void _readAhead() {
    if (_ahead != null || _state != JobState.running || _flights.length < _controller.streams) return;
    final cfg = _controller.config;
    if (telemetry.inflightBytes + _controller.blocksPerChunk * cfg.blockSize > cfg.memoryBudget) return;
    final item = _planner.next(_controller.blocksPerChunk);
    if (item == null) return;
    final bytes = _itemBytes(item);
    final data = item is CompleteItem ? null : _prepare(item);
    data?.ignore(); // surfaces when the item is launched
    _ahead = _Ahead(item, bytes, data);
    _addInflight(bytes);
  }

  void _dropAhead() {
    final a = _ahead;
    if (a == null) return;
    _planner.release(a.item);
    telemetry.inflightBytes -= a.bytes;
    _ahead = null;
  }

  void _addInflight(int bytes) {
    telemetry.inflightBytes += bytes;
    if (telemetry.inflightBytes > telemetry.peakInflightBytes) telemetry.peakInflightBytes = telemetry.inflightBytes;
  }

  void _launch(WorkItem item, [Future<_Prepared>? data]) {
    final flight = _Flight(item, _opts.now(), _itemBytes(item));
    _flights.add(flight);
    _addInflight(flight.bytes);
    _execute(flight, data).catchError((Object err) => _onFlightError(flight, err)).whenComplete(() {
      _flights.remove(flight);
      telemetry.inflightBytes -= flight.bytes;
      _pump();
    });
  }

  int _itemBytes(WorkItem item) => switch (item) {
        BatchItem(:final bytes) => bytes,
        CompleteItem() => 0,
        BlocksItem(:final file, :final start, :final count) =>
          ((start + count) * blockSize < files[file.index].size ? (start + count) * blockSize : files[file.index].size) - start * blockSize,
      };

  Future<ByteReader> _reader(int index) {
    final existing = _readers[index];
    if (existing != null) return existing;
    if (_readers.length >= _opts.maxOpenReaders) {
      // Close the oldest idle reader; files are read front to back, so it's rarely needed again.
      final oldest = _readers.keys.first;
      final r = _readers.remove(oldest)!;
      r.then((x) => x.close()).ignore();
    }
    final opened = files[index].open();
    _readers[index] = opened;
    opened.ignore();
    return opened;
  }

  Future<void> _closeReaders() async {
    final all = _readers.values.toList();
    _readers.clear();
    for (final r in all) {
      try {
        await (await r).close();
      } catch (_) {}
    }
  }

  /// Read + hash (+ frame) a request body. No network.
  Future<_Prepared> _prepare(WorkItem item) async {
    final tel = telemetry;
    switch (item) {
      case BlocksItem(:final file, :final start, :final count):
        final src = files[file.index];
        final from = start * blockSize;
        final to = (start + count) * blockSize < src.size ? (start + count) * blockSize : src.size;
        var t = _opts.now();
        final body = await (await _reader(file.index)).read(from, to - from);
        if (body.length != to - from) throw ProtocolException(ErrorCode.sourceChanged, 'short read');
        var t2 = _opts.now();
        tel.readMs += t2 - t;
        final digests = _hasher.hashBlocks(body, blockSize);
        _storeHashes(file, start, digests);
        tel.hashMs += _opts.now() - t2;
        return _PreparedBlocks(body, digests);
      case BatchItem(:final files, :final bytes):
        var t = _opts.now();
        final buffers = await Future.wait([
          for (final f in files) this.files[f.index].open().then((r) async {
            try {
              return await r.read(0, f.size);
            } finally {
              await r.close();
            }
          }),
        ]);
        var t2 = _opts.now();
        tel.readMs += t2 - t;
        final entries = <BatchEntry>[];
        for (var i = 0; i < files.length; i++) {
          if (buffers[i].length != files[i].size) throw ProtocolException(ErrorCode.sourceChanged, 'short read');
          entries.add(BatchEntry(id: files[i].id, size: buffers[i].length, hash: bytesToBase64Url(_hasher.hashBlocks(buffers[i], blockSize))));
        }
        t = _opts.now();
        tel.hashMs += t - t2;
        final header = encodeBatchHeader(entries);
        // One contiguous body (measured: many-part bodies arrive several times slower).
        final frame = Uint8List(header.length + bytes);
        frame.setRange(0, header.length, header);
        var at = header.length;
        for (final b in buffers) {
          frame.setRange(at, at + b.length, b);
          at += b.length;
        }
        tel.frameMs += _opts.now() - t;
        return _PreparedBatch(frame);
      case CompleteItem():
        throw StateError('nothing to prepare');
    }
  }

  Future<void> _execute(_Flight flight, Future<_Prepared>? ready) async {
    final item = flight.item;
    if (item is CompleteItem) {
      final t0 = _opts.now();
      await _completeFile(item);
      telemetry.completeMs += _opts.now() - t0;
      return;
    }
    final p = await (ready ?? _prepare(item));
    if (flight.cancel.isCancelled) throw TransportException(ErrorCode.cancelled);
    final t = _opts.now();
    switch (p) {
      case _PreparedBlocks(:final body, :final digests):
        final b = item as BlocksItem;
        final load = await _transport.putBlocks(id, b.file.id, b.start, body, digests, flight.cancel);
        final t2 = _opts.now();
        telemetry.networkMs += t2 - t;
        telemetry.wireBytes += body.length + digests.length;
        _recordSuccess(body.length, t2 - t, load.value);
        _planner.ack(item);
      case _PreparedBatch(:final frame):
        final batch = item as BatchItem;
        final load = await _transport.putBatch(id, frame, flight.cancel);
        final t2 = _opts.now();
        telemetry.networkMs += t2 - t;
        telemetry.wireBytes += frame.length;
        _recordSuccess(batch.bytes, t2 - t, load.value);
        _planner.ack(item);
        _filesDone += batch.files.length;
        _fileMeter.add(batch.files.length);
    }
  }

  void _recordSuccess(int bytes, double latency, double load) {
    _bytesDone += bytes;
    _meter.add(bytes);
    _sampleBytes += bytes;
    _sampleLatencySum += latency;
    _sampleLatencyCount++;
    if (load > _sampleLoad) _sampleLoad = load;
    _consecutiveServerErrors = 0;
    telemetry.requests++;
  }

  _HashStore _store(PlanFile f) => _hashes.putIfAbsent(f.index, () => _HashStore(f.blocks, _hasher.length));

  void _storeHashes(PlanFile f, int start, Uint8List digests) {
    final len = _hasher.length;
    final store = _store(f);
    store.digests.setRange(start * len, start * len + digests.length, digests);
    for (var i = 0; i < digests.length ~/ len; i++) {
      store.known.set(start + i);
    }
  }

  Future<void> _completeFile(CompleteItem item) async {
    final f = item.file;
    final store = _store(f);
    // Blocks sent in an earlier session: hash them locally so the root covers the whole file.
    if (!store.known.complete) {
      final src = files[f.index];
      for (final (a, b) in store.known.missingRuns()) {
        for (var i = a; i < b; i += maxBlocksPerChunk) {
          final end = i + maxBlocksPerChunk < b ? i + maxBlocksPerChunk : b;
          final to = end * blockSize < src.size ? end * blockSize : src.size;
          final buf = await (await _reader(f.index)).read(i * blockSize, to - i * blockSize);
          _storeHashes(f, i, _hasher.hashBlocks(buf, blockSize));
        }
      }
    }
    try {
      f.finalName = await _transport.complete(id, f.id, _hasher.root(store.digests));
      _planner.ack(item);
      _filesDone++;
      _fileMeter.add(1);
      _hashes.remove(f.index);
      _readers.remove(f.index)?.then((r) => r.close()).ignore();
    } on TransportException catch (err) {
      if (err.code == ErrorCode.integrity) {
        // The receiver's copy doesn't match (the file changed since an earlier session, or
        // a block went bad on disk). It discarded its copy: start this file over.
        _bytesDone -= _planner.ackedBytes(f);
        _hashes.remove(f.index);
        _planner.resetFile(f);
        if (++f.strikes >= _maxStrikes) f.state = PlanState.failed;
        return;
      }
      rethrow;
    }
  }

  void _onFlightError(_Flight flight, Object err) {
    final item = flight.item;
    _planner.release(item);
    if (flight.intentional) return;

    final code = switch (err) {
      TransportException(:final code) => code,
      ProtocolException(:final code) => code,
      _ => ErrorCode.server,
    };
    if (code == ErrorCode.cancelled) return;
    _retries++;
    _sampleErrors++;

    switch (code) {
      case ErrorCode.network:
        unawaited(_reconnect(true));
      case ErrorCode.incomplete:
        unawaited(_reconnect(false));
      case ErrorCode.integrity || ErrorCode.badFrame:
        _strike(item);
      case ErrorCode.unauthorized || ErrorCode.forbidden || ErrorCode.notFound || ErrorCode.tooLarge || ErrorCode.declined:
        _fail(code);
      case ErrorCode.sourceChanged:
        _fail(code);
      case ErrorCode.diskFull || ErrorCode.diskWrite:
        _pauseWithError(code);
      default:
        _strike(item);
        if (++_consecutiveServerErrors >= 8) _pauseWithError(code);
    }
  }

  void _strike(WorkItem item) {
    final targets = switch (item) {
      BatchItem(:final files) => files,
      BlocksItem(:final file) => [file],
      CompleteItem(:final file) => [file],
    };
    for (final f in targets) {
      if (++f.strikes >= _maxStrikes) f.state = PlanState.failed;
    }
  }

  Future<void> _reconnect(bool isDrop) async {
    if (_reconnectLoop || _state == JobState.cancelled || _state == JobState.complete) return;
    _reconnectLoop = true;
    if (isDrop) _reconnects++;
    _abortAll();
    _meter.stop();
    _fileMeter.stop();
    _stopSampling();
    _setState(JobState.reconnecting);
    var delay = 400;
    try {
      while (_state == JobState.reconnecting) {
        try {
          while (_flights.isNotEmpty) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          await _transport.ping();
          final status = await _transport.status(id);
          if (_state != JobState.reconnecting) return;
          _adopt(status);
          _run();
          return;
        } on TransportException catch (err) {
          if (err.code == ErrorCode.notFound || err.code == ErrorCode.unauthorized) {
            _fail(err.code);
            return;
          }
        } catch (_) {
          // anything else: keep trying
        }
        await Future<void>.delayed(Duration(milliseconds: delay));
        delay = delay * 2 > 5000 ? 5000 : delay * 2;
        _emit(); // lets the UI refresh "still trying"
      }
    } finally {
      _reconnectLoop = false;
    }
  }

  void _abortAll() {
    _dropAhead();
    for (final f in _flights) {
      f.intentional = true;
      f.cancel.cancel();
    }
  }

  void _finish() {
    _stopSampling();
    _meter.stop();
    _fileMeter.stop();
    final failed = _planner.files.any((f) => f.state == PlanState.failed);
    if (failed) {
      _errorCode = ErrorCode.integrity;
      _setState(JobState.failed);
    } else {
      _setState(JobState.complete);
    }
    _finishDone();
  }

  void _fail(ErrorCode code) {
    _abortAll();
    _stopSampling();
    _meter.stop();
    _errorCode = code;
    _setState(JobState.failed);
    _finishDone();
  }

  void _pauseWithError(ErrorCode code) {
    _errorCode = code;
    pause();
  }

  void _handleFatal(Object err) {
    final code = switch (err) {
      TransportException(:final code) => code,
      ProtocolException(:final code) => code,
      _ => ErrorCode.server,
    };
    if (code == ErrorCode.network) {
      unawaited(_reconnectFromScratch());
      return;
    }
    _fail(code);
  }

  Future<void> _reconnectFromScratch() async {
    _setState(JobState.reconnecting);
    var delay = 500;
    while (_state == JobState.reconnecting) {
      await Future<void>.delayed(Duration(milliseconds: delay));
      delay = delay * 2 > 5000 ? 5000 : delay * 2;
      try {
        final status = await _negotiate();
        if (status == null) return;
        _adopt(status);
        _run();
        return;
      } on TransportException catch (err) {
        if (err.code != ErrorCode.network) return _fail(err.code);
      } catch (_) {
        return _fail(ErrorCode.server);
      }
    }
  }

  void _startSampling() {
    _stopSampling();
    _sampleStart = _opts.now();
    _sampleTimer = Timer.periodic(_opts.sampleInterval, (_) => _sample());
  }

  void _stopSampling() {
    _sampleTimer?.cancel();
    _sampleTimer = null;
  }

  void _sample() {
    if (_state != JobState.running) return;
    final t = _opts.now();
    final dt = t - _sampleStart < 1 ? 1.0 : t - _sampleStart;
    final before = _controller.streams;
    final d = _controller.update(ControllerSample(
      throughput: _sampleBytes * 1000 / dt,
      avgLatencyMs: _sampleLatencyCount > 0 ? _sampleLatencySum / _sampleLatencyCount : 0,
      completed: _sampleLatencyCount,
      errors: _sampleErrors,
      serverLoad: _sampleLoad,
    ));
    _sampleStart = t;
    _sampleBytes = 0;
    _sampleLatencySum = 0;
    _sampleLatencyCount = 0;
    _sampleErrors = 0;
    _sampleLoad = 0;
    if (d.streams > before) _pump();
  }

  void _finishDone() {
    unawaited(_closeReaders());
    if (!_done.isCompleted) _done.complete();
  }

  void _setState(JobState s) {
    if (_state == s) return;
    _state = s;
    _emit();
  }

  void _emit() {
    for (final fn in List.of(_listeners)) {
      fn();
    }
  }
}

final _clock = Stopwatch()..start();
double _monotonicMs() => _clock.elapsedMicroseconds / 1000;

String _randomId() => randomId(16);
