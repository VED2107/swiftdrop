import 'package:unorm_dart/unorm_dart.dart' as unorm;

/// Filename and path sanitising. Port of `packages/shared/src/sanitize.ts`: everything a
/// remote peer sends is hostile. Names are NFC-normalised, separators / control / bidi
/// characters replaced, Windows reserved names escaped, lengths capped; relative paths
/// become safe segments (no `..`, no roots).

final _invalid = RegExp(r'[\u0000-\u001f\u007f<>:"/\\|?*\u200e\u200f\u202a-\u202e\u2066-\u2069]', unicode: true);
final _reserved = RegExp(r'^(con|prn|aux|nul|com[0-9¹²³]|lpt[0-9¹²³])(\..*)?$', caseSensitive: false);
final _trailingDotsSpaces = RegExp(r'[. ]+$');
final _onlyDots = RegExp(r'^\.+$');
final _separators = RegExp(r'[\\/]+');
const _maxNameLength = 180;
const _maxSegments = 32;

String extname(String name) {
  final dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(dot) : '';
}

String sanitizeFileName(String input, [String fallback = 'file']) {
  var name = unorm.nfc(input).replaceAll(_invalid, '_').trim();
  name = name.replaceAll(_trailingDotsSpaces, '');
  if (name.isEmpty || _onlyDots.hasMatch(name)) name = fallback;
  if (_reserved.hasMatch(name)) name = '_$name';
  if (name.length > _maxNameLength) {
    var ext = extname(name);
    if (ext.length > 16) ext = ext.substring(0, 16);
    name = name.substring(0, _maxNameLength - ext.length) + ext;
  }
  return name;
}

/// Splits a peer-supplied relative directory into safe segments. Never returns `..`.
List<String> sanitizeRelativeDir(String? input) {
  if (input == null || input.isEmpty) return const [];
  final segments = <String>[];
  for (final raw in input.split(_separators)) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty || trimmed == '.' || trimmed == '..') continue;
    segments.add(sanitizeFileName(trimmed, 'folder'));
    if (segments.length >= _maxSegments) break;
  }
  return segments;
}

/// `IMG_001.jpg` → `IMG_001 (2).jpg`
String numberedName(String name, int n) {
  final ext = extname(name);
  final base = ext.isEmpty ? name : name.substring(0, name.length - ext.length);
  return '$base ($n)$ext';
}
