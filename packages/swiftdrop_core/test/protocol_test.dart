import 'dart:io';

import 'package:swiftdrop_core/swiftdrop_core.dart';
import 'package:test/test.dart';

/// Until the Phase 3 vectors exist, the TS protocol source itself is the reference.
final _tsProtocol = File('../protocol/src/index.ts').readAsStringSync();

void main() {
  group('matches packages/protocol (TypeScript)', () {
    test('error codes: same set, same order', () {
      final m = RegExp(r'ERROR_CODES = \[([^\]]+)\]').firstMatch(_tsProtocol)!;
      final ts = RegExp(r'"([A-Z_]+)"').allMatches(m.group(1)!).map((x) => x.group(1)).toList();
      expect(ErrorCode.values.map((c) => c.wire).toList(), ts);
    });

    test('constants', () {
      int tsConst(String name) {
        final m = RegExp('export const $name = ([^;]+);').firstMatch(_tsProtocol)!;
        final expr = m.group(1)!.split('//').first.trim().replaceAll('_', '');
        final shift = RegExp(r'^(?:\()?(\d+) << (\d+)\)?$').firstMatch(expr);
        if (shift != null) return int.parse(shift.group(1)!) << int.parse(shift.group(2)!);
        final mul = RegExp(r'^(\d+) \* (\d+)$').firstMatch(expr);
        if (mul != null) return int.parse(mul.group(1)!) * int.parse(mul.group(2)!);
        return int.parse(expr.replaceAll(' as const', ''));
      }

      expect(protocolVersion, tsConst('PROTOCOL_VERSION'));
      expect(blockSize, tsConst('BLOCK_SIZE'));
      expect(maxBlocksPerChunk, tsConst('MAX_BLOCKS_PER_CHUNK'));
      expect(smallFileMax, tsConst('SMALL_FILE_MAX'));
      expect(batchTargetBytes, tsConst('BATCH_TARGET_BYTES'));
      expect(batchMaxFiles, tsConst('BATCH_MAX_FILES'));
      expect(maxFilesPerTransfer, tsConst('MAX_FILES_PER_TRANSFER'));
    });

    test('direction values', () {
      expect(_tsProtocol, contains('z.enum(["to-host", "to-guest", "to-peer"])'));
      expect(Direction.values.map((d) => d.wire), ['to-host', 'to-guest', 'to-peer']);
    });
  });

  group('wire types', () {
    test('manifest round-trips through the TS JSON shape', () {
      final json = {
        'protocol': 1,
        'transferId': 'tr_abcdef',
        'direction': 'to-peer',
        'label': 'Photos',
        'integrity': 'xxh64',
        'onConflict': 'keep-both',
        'decisions': {'f_000001': 'skip'},
        'bench': false,
        'files': [
          {'id': 'f_000001', 'name': 'IMG_0001.HEIC', 'relDir': 'DCIM/100APPLE', 'size': 2400000, 'type': 'image/heic', 'lastModified': 1759200000000},
        ],
      };
      final m = Manifest.fromJson(json);
      expect(m.decisions['f_000001'], ConflictPolicy.skip);
      expect(m.totalBytes, 2400000);
      expect(m.toJson(), json);
    });

    test('defaults match the Zod defaults', () {
      final m = Manifest.fromJson({
        'protocol': 1,
        'transferId': 'tr_abcdef',
        'direction': 'to-host',
        'files': [
          {'id': 'f_000001', 'name': 'a.txt', 'size': 0},
        ],
      });
      expect(m.integrity, IntegrityAlgo.xxh64);
      expect(m.onConflict, ConflictPolicy.ask);
      expect(m.files.single.relDir, '');
    });

    test('rejects bad ids, empty manifests and other protocol versions', () {
      Map<String, Object?> base() => {
            'protocol': 1,
            'transferId': 'tr_abcdef',
            'direction': 'to-peer',
            'files': [
              {'id': 'f_000001', 'name': 'a', 'size': 1},
            ],
          };
      expect(() => Manifest.fromJson({...base(), 'transferId': 'x/y'}), throwsA(isA<ProtocolException>()));
      expect(() => Manifest.fromJson({...base(), 'files': <Object>[]}), throwsA(isA<ProtocolException>()));
      expect(() => Manifest.fromJson({...base(), 'protocol': 2}), throwsA(isA<ProtocolException>()));
    });

    test('unknown error codes degrade to SERVER', () {
      expect(ErrorCode.fromWire('SOMETHING_NEW'), ErrorCode.server);
      expect(ErrorCode.fromWire('DISK_FULL'), ErrorCode.diskFull);
      for (final c in ErrorCode.values) {
        expect(userMessages[c], isNotEmpty);
      }
    });
  });
}
