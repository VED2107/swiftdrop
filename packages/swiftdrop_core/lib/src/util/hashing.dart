import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../protocol/types.dart';

/// Per-block integrity, identical to `packages/crypto` (hash-wasm): digests of each block
/// concatenated, and a per-file root = digest of the digest list, as lowercase hex.
abstract interface class BlockHasher {
  IntegrityAlgo get algo;

  /// Digest length in bytes.
  int get length;

  /// Hashes [data] in [blockSize] slices; an empty input still yields one digest.
  Uint8List hashBlocks(Uint8List data, int blockSize);
  String root(Uint8List blockHashes);
}

BlockHasher blockHasher(IntegrityAlgo algo) => switch (algo) {
      IntegrityAlgo.xxh64 => const _Xxh64Hasher(),
      IntegrityAlgo.sha256 => const _Sha256Hasher(),
    };

abstract class _HasherBase implements BlockHasher {
  const _HasherBase();

  Uint8List digest(Uint8List data);

  @override
  Uint8List hashBlocks(Uint8List data, int blockSize) {
    final count = data.isEmpty ? 1 : (data.length + blockSize - 1) ~/ blockSize;
    final out = Uint8List(count * length);
    for (var i = 0; i < count; i++) {
      final from = i * blockSize;
      final to = from + blockSize < data.length ? from + blockSize : data.length;
      out.setRange(i * length, (i + 1) * length, digest(Uint8List.sublistView(data, from, to)));
    }
    return out;
  }

  @override
  String root(Uint8List blockHashes) => toHex(digest(blockHashes));
}

class _Xxh64Hasher extends _HasherBase {
  const _Xxh64Hasher();
  @override
  IntegrityAlgo get algo => IntegrityAlgo.xxh64;
  @override
  int get length => 8;
  @override
  Uint8List digest(Uint8List data) {
    final h = xxh64(data);
    final out = Uint8List(8);
    ByteData.sublistView(out).setUint64(0, h, Endian.big); // canonical form
    return out;
  }
}

class _Sha256Hasher extends _HasherBase {
  const _Sha256Hasher();
  @override
  IntegrityAlgo get algo => IntegrityAlgo.sha256;
  @override
  int get length => 32;
  @override
  Uint8List digest(Uint8List data) => Uint8List.fromList(crypto.sha256.convert(data).bytes);
}

String toHex(List<int> bytes) {
  const digits = '0123456789abcdef';
  final out = StringBuffer();
  for (final b in bytes) {
    out
      ..write(digits[b >> 4])
      ..write(digits[b & 15]);
  }
  return out.toString();
}

// ---------------------------------------------------------------------------
// XXH64 (seed 0). Dart's native ints are 64-bit two's complement: + and * wrap mod 2^64,
// `>>>` is the logical shift, so the reference algorithm maps over directly.

const int _p1 = 0x9E3779B185EBCA87;
const int _p2 = 0xC2B2AE3D27D4EB4F;
const int _p3 = 0x165667B19E3779F9;
const int _p4 = 0x85EBCA77C2B2AE63;
const int _p5 = 0x27D4EB2F165667C5;

int _rotl(int x, int r) => (x << r) | (x >>> (64 - r));

int _round(int acc, int input) {
  acc += input * _p2;
  acc = _rotl(acc, 31);
  return acc * _p1;
}

int _merge(int acc, int val) {
  acc ^= _round(0, val);
  return acc * _p1 + _p4;
}

int xxh64(Uint8List data) {
  final bd = ByteData.sublistView(data);
  final len = data.length;
  var i = 0;
  int h;
  if (len >= 32) {
    var v1 = _p1 + _p2;
    var v2 = _p2;
    var v3 = 0;
    var v4 = -_p1;
    final limit = len - 32;
    while (i <= limit) {
      v1 = _round(v1, bd.getUint64(i, Endian.little));
      v2 = _round(v2, bd.getUint64(i + 8, Endian.little));
      v3 = _round(v3, bd.getUint64(i + 16, Endian.little));
      v4 = _round(v4, bd.getUint64(i + 24, Endian.little));
      i += 32;
    }
    h = _rotl(v1, 1) + _rotl(v2, 7) + _rotl(v3, 12) + _rotl(v4, 18);
    h = _merge(h, v1);
    h = _merge(h, v2);
    h = _merge(h, v3);
    h = _merge(h, v4);
  } else {
    h = _p5;
  }
  h += len;
  while (i + 8 <= len) {
    h ^= _round(0, bd.getUint64(i, Endian.little));
    h = _rotl(h, 27) * _p1 + _p4;
    i += 8;
  }
  if (i + 4 <= len) {
    h ^= bd.getUint32(i, Endian.little) * _p1;
    h = _rotl(h, 23) * _p2 + _p3;
    i += 4;
  }
  while (i < len) {
    h ^= data[i] * _p5;
    h = _rotl(h, 11) * _p1;
    i++;
  }
  h ^= h >>> 33;
  h *= _p2;
  h ^= h >>> 29;
  h *= _p3;
  h ^= h >>> 32;
  return h;
}

/// Constant-time-ish equality for digests.
bool bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
