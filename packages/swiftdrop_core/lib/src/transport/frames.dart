import 'dart:convert';
import 'dart:typed_data';

import 'link.dart';

/// Peer wire frames, identical to `packages/peer/src/channel.ts`:
///   0x01 | UTF-8 JSON                      control
///   0x02 | u32 reqId | u32 offset | bytes  body bytes (big-endian header)
/// Control JSON keys match the TS `ControlMessage` union exactly, so a Dart peer and the
/// browser peer understand each other. Notices (`t: "note"`) are v1.1; old peers ignore them.

const int frameControl = 1;
const int frameData = 2;
const int dataHeaderBytes = 9;

Map<String, Object?> controlToJson(ControlMessage m) => switch (m) {
      RequestMessage(:final id, :final op, :final args, :final bodyLength) => {
          't': 'req',
          'id': id,
          'op': op,
          'args': ?args,
          'len': ?bodyLength,
        },
      ResponseMessage(:final id, :final ok, :final result, :final errorCode) =>
        ok ? {'t': 'res', 'id': id, 'ok': true, 'result': ?result} : {'t': 'res', 'id': id, 'ok': false, 'code': errorCode},
      AbortMessage(:final id) => {'t': 'abort', 'id': id},
      NoticeMessage(:final kind, :final args) => {'t': 'note', 'kind': kind, 'args': ?args},
    };

ControlMessage? controlFromJson(Map<String, Object?> j) {
  final id = j['id'];
  switch (j['t']) {
    case 'req':
      if (id is! int || j['op'] is! String) return null;
      return RequestMessage(id: id, op: j['op'] as String, args: j['args'], bodyLength: (j['len'] as num?)?.toInt());
    case 'res':
      if (id is! int) return null;
      return j['ok'] == true ? ResponseMessage.ok(id, j['result']) : ResponseMessage.error(id, (j['code'] as String?) ?? 'SERVER');
    case 'abort':
      return id is int ? AbortMessage(id) : null;
    case 'note':
      return j['kind'] is String ? NoticeMessage(j['kind'] as String, j['args']) : null;
  }
  return null;
}

Uint8List encodeControl(ControlMessage m) {
  final json = utf8.encode(jsonEncode(controlToJson(m)));
  final out = Uint8List(1 + json.length);
  out[0] = frameControl;
  out.setRange(1, out.length, json);
  return out;
}

Uint8List encodeDataHeader(int requestId, int offset) {
  final h = Uint8List(dataHeaderBytes);
  final v = ByteData.sublistView(h);
  h[0] = frameData;
  v.setUint32(1, requestId);
  v.setUint32(5, offset);
  return h;
}

/// Decodes one frame; returns null for anything malformed (dropped, like the TS link).
Object? decodeFrame(Uint8List frame) {
  if (frame.isEmpty) return null;
  if (frame[0] == frameControl) {
    try {
      final j = jsonDecode(utf8.decode(Uint8List.sublistView(frame, 1)));
      return j is Map<String, Object?> ? controlFromJson(j) : null;
    } catch (_) {
      return null;
    }
  }
  if (frame[0] == frameData && frame.length >= dataHeaderBytes) {
    final v = ByteData.sublistView(frame);
    return DataFrame(v.getUint32(1), v.getUint32(5), Uint8List.sublistView(frame, dataHeaderBytes));
  }
  return null;
}
