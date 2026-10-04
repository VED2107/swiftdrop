import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Streaming ZIP writer, STORE only (photos and videos are already compressed). ZIP64 when
/// any size or offset crosses 4 GiB. Port of `apps/server/src/zip.ts`.
///
/// Entries are stored and sizes known up front, so the exact archive length is computable
/// before the first byte: Safari gets a Content-Length and shows real progress. CRCs are
/// computed while streaming and written in data descriptors.
class ZipEntry {
  const ZipEntry({required this.name, required this.path, required this.size, required this.mtime});

  /// Forward-slash relative path, already sanitised.
  final String name;
  final String path;
  final int size;
  final DateTime mtime;
}

const int _u32 = 0xffffffff;

class _Planned {
  _Planned(this.entry, this.name, this.offset, this.zip64);
  final ZipEntry entry;
  final List<int> name;
  final int offset;
  final bool zip64;
  int crc = 0;
}

(List<_Planned>, int) _plan(List<ZipEntry> entries) {
  var offset = 0;
  final planned = <_Planned>[];
  for (final e in entries) {
    final name = utf8.encode(e.name);
    final zip64 = e.size >= _u32 || offset >= _u32;
    planned.add(_Planned(e, name, offset, zip64));
    offset += 30 + name.length + (zip64 ? 20 : 0) + e.size + (zip64 ? 24 : 16);
  }
  return (planned, offset);
}

int _centralSize(_Planned p) => 46 + p.name.length + ((p.zip64 || p.offset >= _u32) ? 28 : 0);

int zipLength(List<ZipEntry> entries) {
  final (planned, dataEnd) = _plan(entries);
  final cd = planned.fold(0, (s, p) => s + _centralSize(p));
  final needs64 = dataEnd >= _u32 || planned.length >= 0xffff || planned.any((p) => p.zip64);
  return dataEnd + cd + (needs64 ? 56 + 20 : 0) + 22;
}

/// Writes the archive to [out]. [onBytes] sees every chunk length (download progress).
Future<void> writeZip(List<ZipEntry> entries, IOSink out, {void Function(int n)? onBytes}) async {
  final (planned, dataEnd) = _plan(entries);
  Future<void> write(List<int> b) async {
    onBytes?.call(b.length);
    out.add(b);
    await out.flush();
  }

  for (final p in planned) {
    final (dosTime, dosDate) = _dos(p.entry.mtime);
    final h = _Buf(30 + p.name.length + (p.zip64 ? 20 : 0))
      ..u32(0x04034b50)
      ..u16(p.zip64 ? 45 : 20)
      ..u16(0x0808) // data descriptor + UTF-8 names
      ..u16(0) // stored
      ..u16(dosTime)
      ..u16(dosDate)
      ..u32(0)
      ..u32(p.zip64 ? _u32 : 0)
      ..u32(p.zip64 ? _u32 : 0)
      ..u16(p.name.length)
      ..u16(p.zip64 ? 20 : 0)
      ..bytes(p.name);
    if (p.zip64) {
      h
        ..u16(0x0001)
        ..u16(16)
        ..u64(0)
        ..u64(0); // real sizes are in the descriptor
    }
    await write(h.done());

    var crc = 0;
    var seen = 0;
    final raf = File(p.entry.path).openSync();
    try {
      final buf = Uint8List(1 << 20);
      for (;;) {
        final n = raf.readIntoSync(buf);
        if (n <= 0) break;
        final chunk = Uint8List.fromList(Uint8List.sublistView(buf, 0, n));
        crc = crc32(chunk, crc);
        seen += n;
        await write(chunk);
      }
    } finally {
      raf.closeSync();
    }
    if (seen != p.entry.size) throw StateError('size changed while zipping ${p.entry.name}');
    p.crc = crc;

    final d = _Buf(p.zip64 ? 24 : 16)
      ..u32(0x08074b50)
      ..u32(p.crc);
    if (p.zip64) {
      d
        ..u64(p.entry.size)
        ..u64(p.entry.size);
    } else {
      d
        ..u32(p.entry.size)
        ..u32(p.entry.size);
    }
    await write(d.done());
  }

  var cdSize = 0;
  for (final p in planned) {
    final (dosTime, dosDate) = _dos(p.entry.mtime);
    final needs64 = p.zip64 || p.offset >= _u32;
    final c = _Buf(46 + p.name.length + (needs64 ? 28 : 0))
      ..u32(0x02014b50)
      ..u16(0x033f)
      ..u16(needs64 ? 45 : 20)
      ..u16(0x0808)
      ..u16(0)
      ..u16(dosTime)
      ..u16(dosDate)
      ..u32(p.crc)
      ..u32(needs64 ? _u32 : p.entry.size)
      ..u32(needs64 ? _u32 : p.entry.size)
      ..u16(p.name.length)
      ..u16(needs64 ? 28 : 0)
      ..u16(0)
      ..u16(0)
      ..u16(0)
      ..u32((0x81a4 << 16) & 0xffffffff) // regular file, 0644
      ..u32(needs64 ? _u32 : p.offset)
      ..bytes(p.name);
    if (needs64) {
      c
        ..u16(0x0001)
        ..u16(24)
        ..u64(p.entry.size)
        ..u64(p.entry.size)
        ..u64(p.offset);
    }
    final rec = c.done();
    cdSize += rec.length;
    await write(rec);
  }

  final count = planned.length;
  final needs64 = dataEnd >= _u32 || count >= 0xffff || planned.any((p) => p.zip64);
  if (needs64) {
    final z = _Buf(76)
      ..u32(0x06064b50)
      ..u64(44)
      ..u16(45)
      ..u16(45)
      ..u32(0)
      ..u32(0)
      ..u64(count)
      ..u64(count)
      ..u64(cdSize)
      ..u64(dataEnd)
      ..u32(0x07064b50)
      ..u32(0)
      ..u64(dataEnd + cdSize)
      ..u32(1);
    await write(z.done());
  }
  final e = _Buf(22)
    ..u32(0x06054b50)
    ..u16(0)
    ..u16(0)
    ..u16(count < 0xffff ? count : 0xffff)
    ..u16(count < 0xffff ? count : 0xffff)
    ..u32(cdSize < _u32 ? cdSize : _u32)
    ..u32(needs64 ? _u32 : dataEnd)
    ..u16(0);
  await write(e.done());
}

(int, int) _dos(DateTime d) {
  final year = d.year < 1980 ? 1980 : d.year;
  return ((d.hour << 11) | (d.minute << 5) | (d.second >> 1), ((year - 1980) << 9) | (d.month << 5) | d.day);
}

class _Buf {
  _Buf(int size) : _b = Uint8List(size) {
    _v = ByteData.view(_b.buffer);
  }
  final Uint8List _b;
  late final ByteData _v;
  int _o = 0;
  void u16(int v) {
    _v.setUint16(_o, v, Endian.little);
    _o += 2;
  }

  void u32(int v) {
    _v.setUint32(_o, v & 0xffffffff, Endian.little);
    _o += 4;
  }

  void u64(int v) {
    _v.setUint32(_o, v & 0xffffffff, Endian.little);
    _v.setUint32(_o + 4, (v >> 32) & 0xffffffff, Endian.little);
    _o += 8;
  }

  void bytes(List<int> b) {
    _b.setAll(_o, b);
    _o += b.length;
  }

  Uint8List done() => _b;
}

final Uint32List _table = () {
  final t = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1;
    }
    t[n] = c;
  }
  return t;
}();

/// CRC-32 (IEEE), continuing from [prev].
int crc32(Uint8List buf, [int prev = 0]) {
  var c = (~prev) & 0xffffffff;
  for (var i = 0; i < buf.length; i++) {
    c = _table[(c ^ buf[i]) & 0xff] ^ (c >> 8);
  }
  return (~c) & 0xffffffff;
}
