import 'dart:io';

import 'package:test/test.dart';

/// The core must stay pure Dart: no Flutter, no state-management library. The engine
/// runs in a background isolate and under `dart test`; either import would break that.
void main() {
  test('lib/ imports neither Flutter nor Riverpod', () {
    final banned = RegExp(r'''import\s+['"]package:(flutter|flutter_riverpod|riverpod|hooks_riverpod)/''');
    final offenders = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (f.path.endsWith('.dart') && banned.hasMatch(f.readAsStringSync())) offenders.add(f.path);
    }
    expect(offenders, isEmpty);
  });

  test('pubspec depends on no Flutter SDK package', () {
    expect(File('pubspec.yaml').readAsStringSync(), isNot(contains('sdk: flutter')));
  });
}
