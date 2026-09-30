import 'dart:convert';
import 'dart:typed_data';

import 'constants.dart';
import 'errors.dart';

/// Batch frame: `[u32 LE headerLength][header JSON utf8][file bytes concatenated]`.
/// Many small files in one request. Byte-identical to `encodeBatchHeader`/`decodeBatch`.

class BatchEntry {
  const BatchEntry({required this.id, required this.size, required this.hash});
  final String id;
  final int size;

  /// base64url of the file's block digests.
  final String hash;

  Map<String, Object?> toJson() => {'id': id, 'size': size, 'hash': hash};
}

Uint8List encodeBatchHeader(List<BatchEntry> files) {
  final json = utf8.encode(jsonEncode({'files': [for (final f in files) f.toJson()]}));
  final out = Uint8List(4 + json.length);
  ByteData.sublistView(out).setUint32(0, json.length, Endian.little);
  out.setRange(4, out.length, json);
  return out;
}

class DecodedBatch {
  const DecodedBatch(this.files, this.payload);
  final List<BatchEntry> files;
  final Uint8List payload;
}

DecodedBatch decodeBatch(Uint8List frame) {
  if (frame.length < 4) throw ProtocolException(ErrorCode.badFrame, 'frame too short');
  final len = ByteData.sublistView(frame, 0, 4).getUint32(0, Endian.little);
  if (len > 1 << 20 || 4 + len > frame.length) throw ProtocolException(ErrorCode.badFrame, 'bad header length');
  final List<BatchEntry> files;
  try {
    final header = jsonDecode(utf8.decode(Uint8List.sublistView(frame, 4, 4 + len))) as Map<String, Object?>;
    files = [
      for (final f in header['files'] as List<Object?>)
        BatchEntry(
          id: (f as Map<String, Object?>)['id'] as String,
          size: (f['size'] as num).toInt(),
          hash: f['hash'] as String,
        ),
    ];
  } catch (_) {
    throw ProtocolException(ErrorCode.badFrame, 'bad header');
  }
  if (files.isEmpty || files.length > batchMaxFiles || files.any((f) => f.size < 0)) {
    throw ProtocolException(ErrorCode.badFrame, 'bad header');
  }
  final payload = Uint8List.sublistView(frame, 4 + len);
  final expected = files.fold<int>(0, (s, f) => s + f.size);
  if (expected != payload.length) throw ProtocolException(ErrorCode.badFrame, 'payload size mismatch');
  return DecodedBatch(files, payload);
}
