import 'dart:convert';
import 'dart:typed_data';

/// Unpadded base64url, as `bytesToBase64Url` in `packages/crypto`.
String bytesToBase64Url(List<int> bytes) {
  final s = base64Url.encode(bytes);
  final pad = s.indexOf('=');
  return pad < 0 ? s : s.substring(0, pad);
}

/// Accepts padded or unpadded base64url, and standard `+`/`/` too (like the TS decoder).
Uint8List base64UrlToBytes(String s) {
  final clean = s.replaceAll('=', '').replaceAll('+', '-').replaceAll('/', '_');
  if (clean.length % 4 == 1) throw const FormatException('invalid base64');
  return base64Url.decode(base64Url.normalize(clean));
}
