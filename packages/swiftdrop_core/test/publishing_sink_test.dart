import 'dart:io';
import 'dart:typed_data';

import 'package:swiftdrop_core/engine.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';
import 'package:test/test.dart';

/// Stands in for the Kotlin side: records calls, copies the staged file like the real
/// publisher does and refuses nothing.
class _FakeBridge implements PlatformBridge {
  final calls = <(String, Map<String, Object?>)>[];
  final published = <String, Uint8List>{};
  bool failPublish = false;

  @override
  Future<Object?> call(String method, [Map<String, Object?> args = const {}]) async {
    calls.add((method, args));
    switch (method) {
      case 'publish':
        if (failPublish) throw BridgeException('write', 'boom');
        final key = '${args['target']}/${(args['relDir'] as List).join('/')}/${args['name']}';
        published[key] = File(args['path']! as String).readAsBytesSync();
        return {'display': key};
      case 'exists':
        return false;
      case 'freeSpace':
        return 1 << 40;
    }
    return null;
  }
}

void main() {
  late Directory tmp;
  late _FakeBridge bridge;
  late PublishingSinkFactory sinks;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sd_pub');
    bridge = _FakeBridge();
    sinks = PublishingSinkFactory(stagingRoot: tmp.path, bridge: bridge);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<String> receive(String name, List<int> bytes, {List<String> relDir = const []}) async {
    final sink = await sinks.open('t1', 'f_$name', bytes.length);
    await sink.write(0, Uint8List.fromList(bytes));
    await sink.close();
    return sinks.finish('t1', 'f_$name', relDir: relDir, name: name, lastModified: 1700000000000, replace: false);
  }

  test('images, videos and audio go to the gallery; documents to Downloads', () async {
    expect(await receive('IMG_1234.jpg', [1, 2, 3]), 'gallery//IMG_1234.jpg');
    expect(await receive('clip.mp4', [4]), 'gallery//clip.mp4');
    expect(await receive('song.flac', [5]), 'gallery//song.flac');
    expect(await receive('report.pdf', [6]), 'downloads//report.pdf');
    expect(await receive('app.apk', [7]), 'downloads//app.apk');
    expect(bridge.published['gallery//IMG_1234.jpg'], [1, 2, 3]);
  });

  test('a chosen folder takes documents, media still goes to the gallery', () async {
    sinks.destination = const SaveDestination(treeUri: 'content://tree/x', treeName: 'SwiftDrop');
    expect(await receive('a.docx', [1]), 'tree//a.docx');
    expect(await receive('b.png', [2]), 'gallery//b.png');
    sinks.destination = const SaveDestination(mediaToGallery: false, treeUri: 'content://tree/x');
    expect(await receive('c.png', [3]), 'tree//c.png');
  });

  test('folders keep their structure', () async {
    expect(await receive('p.jpg', [1], relDir: ['Trip', 'Day1']), 'gallery/Trip/Day1/p.jpg');
  });

  test('staging file is removed after publishing, kept when publishing fails', () async {
    await receive('x.zip', [1, 2]);
    expect(Directory('${tmp.path}/.swiftdrop/t1').listSync().whereType<File>(), isEmpty);
    bridge.failPublish = true;
    await expectLater(receive('y.zip', [3]), throwsA(isA<ProtocolException>()));
    expect(File('${tmp.path}/.swiftdrop/t1/f_y.zip.part').existsSync(), isTrue);
  });

  test('a zero-byte file still publishes', () async {
    sinks = PublishingSinkFactory(stagingRoot: tmp.path, bridge: bridge);
    final name = await sinks.finish('t2', 'f0', relDir: const [], name: 'empty.txt', lastModified: 0, replace: false);
    expect(name, 'downloads//empty.txt');
    expect(bridge.published[name], isEmpty);
  });

  test('free space comes from the platform', () async => expect(await sinks.freeSpace(), 1 << 40));
}
