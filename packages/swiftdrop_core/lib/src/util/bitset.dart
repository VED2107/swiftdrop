import 'dart:convert';
import 'dart:typed_data';

/// Compact bitmap of received blocks, serialised as standard (padded) base64 for the resume
/// handshake. Port of `packages/shared/src/bitset.ts`.
class Bitset {
  Bitset(this.size, [List<int>? bytes]) : _bits = Uint8List((size + 7) >> 3) {
    if (bytes == null) return;
    final n = bytes.length < _bits.length ? bytes.length : _bits.length;
    _bits.setRange(0, n, bytes);
    final tail = size % 8;
    if (tail != 0 && _bits.isNotEmpty) _bits[_bits.length - 1] &= (1 << tail) - 1;
    for (final b in _bits) {
      _count += _popcount(b);
    }
  }

  factory Bitset.full(int size) {
    final b = Bitset(size);
    for (var i = 0; i < size; i++) {
      b.set(i);
    }
    return b;
  }

  factory Bitset.fromBase64(int size, String b64) => Bitset(size, base64.decode(b64));

  final int size;
  final Uint8List _bits;
  int _count = 0;

  bool has(int i) => (_bits[i >> 3] & (1 << (i & 7))) != 0;

  /// Returns true when the bit was newly set.
  bool set(int i) {
    if (i < 0 || i >= size || has(i)) return false;
    _bits[i >> 3] |= 1 << (i & 7);
    _count++;
    return true;
  }

  int get count => _count;
  bool get complete => _count == size;

  /// Contiguous runs of missing indices as (start, endExclusive).
  List<(int, int)> missingRuns() {
    final runs = <(int, int)>[];
    var start = -1;
    for (var i = 0; i < size; i++) {
      final missing = !has(i);
      if (missing && start < 0) start = i;
      if (!missing && start >= 0) {
        runs.add((start, i));
        start = -1;
      }
    }
    if (start >= 0) runs.add((start, size));
    return runs;
  }

  String toBase64() => base64.encode(_bits);

  Bitset copy() => Bitset(size, _bits);

  static int _popcount(int b) {
    b = b - ((b >> 1) & 0x55);
    b = (b & 0x33) + ((b >> 2) & 0x33);
    return (b + (b >> 4)) & 0x0f;
  }
}
