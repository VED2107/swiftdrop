import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:swiftdrop_core/engine.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';
import 'package:test/test.dart';

/// Replays tests/vectors/protocol-v1.json (written by the TypeScript implementation) and
/// requires byte-identical / decision-identical results from the Dart port.
final Map<String, Object?> v = jsonDecode(File('../../tests/vectors/protocol-v1.json').readAsStringSync()) as Map<String, Object?>;

/// Same generator as `patternBytes` in tests/vectors/generate.ts.
Uint8List pattern(int seed, int length) {
  final out = Uint8List(length);
  var x = seed & 0xFFFFFFFF;
  if (x == 0) x = 1;
  for (var i = 0; i < length; i++) {
    x ^= (x << 13) & 0xFFFFFFFF;
    x ^= x >>> 17;
    x ^= (x << 5) & 0xFFFFFFFF;
    out[i] = x & 0xff;
  }
  return out;
}

List<Map<String, Object?>> list(Object? o) => (o as List<Object?>).cast<Map<String, Object?>>();

void main() {
  test('block size', () => expect(v['blockSize'], blockSize));

  group('hashing', () {
    for (final algo in IntegrityAlgo.values) {
      test(algo.wire, () {
        final h = blockHasher(algo);
        for (final c in list((v['hashes'] as Map)[algo.wire])) {
          final digests = h.hashBlocks(pattern(c['seed'] as int, c['length'] as int), blockSize);
          expect(bytesToBase64Url(digests), c['blocks'], reason: 'len ${c['length']}');
          expect(h.root(digests), c['root'], reason: 'len ${c['length']}');
        }
      });
    }
  });

  test('base64url', () {
    for (final c in list(v['base64url'])) {
      final bytes = pattern(c['seed'] as int, c['length'] as int);
      expect(bytesToBase64Url(bytes), c['text']);
      expect(base64UrlToBytes(c['text'] as String), bytes);
    }
  });

  test('bitsets', () {
    for (final c in list(v['bitsets'])) {
      final b = Bitset(c['size'] as int);
      for (final i in (c['set'] as List).cast<int>()) {
        b.set(i);
      }
      expect(b.toBase64(), c['base64']);
      expect(b.count, c['count']);
      expect(b.complete, c['complete']);
      expect(b.missingRuns().map((r) => [r.$1, r.$2]).toList(), c['missingRuns']);
      final back = Bitset.fromBase64(c['size'] as int, c['base64'] as String);
      expect(back.count, c['count']);
    }
  });

  test('batch frames', () {
    final h = blockHasher(IntegrityAlgo.xxh64);
    for (final c in list(v['batchFrames'])) {
      final files = list(c['files']);
      final datas = [for (final f in files) pattern(f['seed'] as int, f['length'] as int)];
      final header = encodeBatchHeader([
        for (var i = 0; i < files.length; i++)
          BatchEntry(id: files[i]['id'] as String, size: datas[i].length, hash: bytesToBase64Url(h.hashBlocks(datas[i], blockSize))),
      ]);
      final frame = BytesBuilder(copy: false)..add(header);
      for (final d in datas) {
        frame.add(d);
      }
      final bytes = frame.toBytes();
      expect(bytesToBase64Url(bytes), c['frame']);
      final decoded = decodeBatch(bytes);
      expect(decoded.files.map((f) => f.id), files.map((f) => f['id']));
      expect(decoded.payload.length, datas.fold<int>(0, (s, d) => s + d.length));
    }
  });

  test('sanitising', () {
    final s = v['sanitize'] as Map<String, Object?>;
    for (final c in list(s['fileNames'])) {
      expect(sanitizeFileName(c['input'] as String), c['output'], reason: jsonEncode(c['input']));
    }
    for (final c in list(s['relDirs'])) {
      expect(sanitizeRelativeDir(c['input'] as String), c['output'], reason: jsonEncode(c['input']));
    }
    for (final c in list(s['numbered'])) {
      expect(numberedName(c['name'] as String, c['n'] as int), c['output']);
    }
  });

  test('formatting', () {
    final f = v['format'] as Map<String, Object?>;
    for (final c in list(f['bytes'])) {
      expect(formatBytes(c['value'] as num), c['output']);
    }
    for (final c in list(f['rates'])) {
      expect(formatRate(c['value'] as num), c['output']);
    }
    for (final c in list(f['durations'])) {
      expect(formatDuration(c['value'] as num), c['output']);
    }
  });

  group('controller decisions', () {
    for (final c in list(v['controllers'])) {
      test(c['config'] as String, () {
        final ctrl = AdaptiveController(c['config'] == 'desktop' ? desktopController : mobileController);
        final samples = list(c['samples']);
        final decisions = list(c['decisions']);
        for (var i = 0; i < samples.length; i++) {
          final s = samples[i];
          final d = ctrl.update(ControllerSample(
            throughput: (s['throughput'] as num).toDouble(),
            avgLatencyMs: (s['avgLatencyMs'] as num).toDouble(),
            completed: s['completed'] as int,
            errors: s['errors'] as int,
            serverLoad: (s['serverLoad'] as num).toDouble(),
          ));
          expect([d.streams, d.blocksPerChunk, d.reason.wire], [decisions[i]['streams'], decisions[i]['blocksPerChunk'], decisions[i]['reason']],
              reason: 'sample $i');
        }
      });
    }
  });

  test('planner trace', () {
    final scenario = list(v['planners']).single;
    final files = list(scenario['files']);
    final p = Planner([for (final f in files) (id: f['id'] as String, size: f['size'] as int)], blockSize);
    final items = <WorkItem>[];
    var step = 0;
    for (final op in list(scenario['ops'])) {
      final why = 'op ${step++} ${op['op']}';
      switch (op['op']) {
        case 'applyStatus':
          p.applyStatus(TransferStatus.fromJson(op['status'] as Map<String, Object?>));
          items.clear();
        case 'next':
          final item = p.next(op['blocksPerChunk'] as int);
          if (item != null) items.add(item);
          expect(describe(item), op['result'], reason: why);
        case 'ack':
          expect(p.ack(items[op['item'] as int]).map((f) => f.id).toList(), op['completed'], reason: why);
        case 'release':
          p.release(items[op['item'] as int]);
        case 'resetFile':
          p.resetFile(p.files.firstWhere((f) => f.id == op['file']));
      }
      if (op.containsKey('finished')) expect(p.finished, op['finished'], reason: why);
    }
  });

  test('manifests parse to the Zod output', () {
    for (final c in list(v['manifests'])) {
      final m = Manifest.fromJson(c['input'] as Map<String, Object?>);
      expect(m.toJson(), c['parsed']);
    }
  });
}

Map<String, Object?>? describe(WorkItem? item) => switch (item) {
      null => null,
      CompleteItem(:final file) => {'kind': 'complete', 'file': file.id},
      BlocksItem(:final file, :final start, :final count) => {'kind': 'blocks', 'file': file.id, 'start': start, 'count': count},
      BatchItem(:final files, :final bytes) => {'kind': 'batch', 'files': [for (final f in files) f.id], 'bytes': bytes},
    };
