@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:swiftdrop_core/engine.dart';
import 'package:swiftdrop_core/runtime.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Phones without the app: the engine runtime hosts the browser client's API, so an
/// iPhone's Safari pairs by QR, uploads with the same requests it makes to the Node PC
/// server, and downloads what this device offers. Driven here with real HTTP.
late Directory tmp;
late EngineRuntime rt;
late String base;
final http = HttpClient();

Future<(int, Map<String, Object?>)> call(String method, String path, {Object? json, String? token, Map<String, String> headers = const {}}) async {
  final req = await http.openUrl(method, Uri.parse('$base$path'));
  if (token != null) req.headers.set('authorization', 'Bearer $token');
  headers.forEach(req.headers.set);
  if (json != null) {
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode(json));
  }
  final res = await req.close();
  final text = await utf8.decodeStream(res);
  return (res.statusCode, text.isEmpty ? <String, Object?>{} : jsonDecode(text) as Map<String, Object?>);
}

/// Scan the QR, wait for approval on this device, get the bearer token.
Future<String> pair(String name, {String installId = 'install-id-0123456789'}) async {
  final token = rt.endpoint!.web!.token;
  final joins = rt.joins.firstWhere((j) => j.any((x) => x.deviceName == name));
  final (s, r) = await call('POST', '/api/join', json: {'token': token, 'deviceName': name, 'installId': installId});
  expect(s, 202);
  final join = (await joins).firstWhere((x) => x.deviceName == name);
  expect(join.viaCode, isFalse);
  final (s1, pending) = await call('GET', '/api/join/${r['requestId']}');
  expect((s1, pending['status']), (200, 'pending'));
  await rt.resolveJoin(join.id, true);
  final (_, done) = await call('GET', '/api/join/${r['requestId']}');
  expect(done['status'], 'approved');
  return done['token']! as String;
}

void main() {
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('sd_web_');
    final web = Directory(p.join(tmp.path, 'web'))..createSync();
    File(p.join(web.path, 'index.html')).writeAsStringSync('<!doctype html><title>SwiftDrop</title>');
    rt = await EngineRuntime.start(EngineConfig(
      dataDir: p.join(tmp.path, 'data'),
      downloadDir: p.join(tmp.path, 'Downloads'),
      name: 'Desk',
      port: 0,
      bindAddress: '127.0.0.1',
      webRoot: web.path,
      webPort: 0,
    ));
    base = 'http://127.0.0.1:${rt.endpoint!.web!.port}';
  });
  tearDown(() async {
    await rt.stop();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('serves the web client with a strict CSP; the API refuses strangers', () async {
    final req = await http.getUrl(Uri.parse('$base/'));
    final res = await req.close();
    expect(res.statusCode, 200);
    expect(await utf8.decodeStream(res), contains('SwiftDrop'));
    expect(res.headers.value('content-security-policy'), contains("default-src 'self'"));
    final (s, info) = await call('GET', '/api/info');
    expect((s, info['role']), (200, null));
    expect((await call('GET', '/api/offers')).$1, 401);
    expect((await call('POST', '/api/join', json: {'token': 'wrong-token-value', 'deviceName': 'x'})).$1, 410);
    expect(rt.endpoint!.web!.url('192.168.1.5'), startsWith('http://192.168.1.5:'));
  });

  test('pairing needs approval on this device; the QR is spent afterwards; denial is final', () async {
    // Broadcast stream: listen before the approval that emits the new device.
    final listed = rt.devices.firstWhere((d) => d.any((x) => x.id.startsWith('web:')));
    final token = await pair('iPhone');
    final (s, info) = await call('GET', '/api/info', token: token);
    expect((s, info['role'], info['deviceName']), (200, 'guest', 'iPhone'));
    final devices = await listed;
    final phone = devices.firstWhere((x) => x.id.startsWith('web:'));
    expect((phone.name, phone.platform, phone.path?.link), ('iPhone', DevicePlatform.ios, LinkKind.http));

    // The token in the QR rotated with the approval.
    final old = token;
    expect(rt.endpoint!.web!.token, isNot(old));

    final fresh = rt.endpoint!.web!.token;
    final joins = rt.joins.firstWhere((j) => j.any((x) => x.deviceName == 'Pixel'));
    final (_, r) = await call('POST', '/api/join', json: {'token': fresh, 'deviceName': 'Pixel'});
    await rt.resolveJoin((await joins).single.id, false);
    expect((await call('GET', '/api/join/${r['requestId']}')).$2['status'], 'denied');
  });

  test('an iPhone uploads through HTTP exactly as to the PC server: verified, on disk, in history', () async {
    final recorded = rt.history.firstWhere((h) => h.isNotEmpty);
    final token = await pair('iPhone');
    final big = bytesOf(6 * 1024 * 1024 + 123, 7);
    final files = <FileSource>[
      MemorySource('IMG_0001.HEIC', big),
      for (var i = 0; i < 40; i++) MemorySource('photo_$i.jpg', bytesOf(5000 + i, 30 + i), relDir: 'Camera'),
    ];
    final transport = HttpEngineTransport(base, token: token);
    final job = TransferJob(JobOptions(transport: transport, files: files, direction: Direction.toHost, label: '41 photos'));
    await job.start();
    await job.done;
    expect(job.snapshot().state, JobState.complete);
    transport.close();

    final got = await File(p.join(tmp.path, 'Downloads', 'IMG_0001.HEIC')).readAsBytes();
    expect(sameBytes(got, big), isTrue);
    expect(File(p.join(tmp.path, 'Downloads', 'Camera', 'photo_39.jpg')).lengthSync(), 5039);

    final hist = await recorded.timeout(const Duration(seconds: 10));
    expect((hist.first.role, hist.first.peerName, hist.first.verified), (TransferRole.receiving, 'iPhone', true));
  });

  test('offers to a browser: list, ticketed ranged download, ZIP with exact length, progress to complete', () async {
    final listed = rt.devices.firstWhere((d) => d.any((x) => x.id.startsWith('web:')));
    final token = await pair('iPhone');
    final phone = (await listed).firstWhere((x) => x.id.startsWith('web:'));
    final src = Directory(p.join(tmp.path, 'out'))..createSync();
    final a = File(p.join(src.path, 'report.pdf'))..writeAsBytesSync(bytesOf(300000, 3));
    final b = File(p.join(src.path, 'clip.mov'))..writeAsBytesSync(bytesOf(2 * 1024 * 1024 + 5, 4));
    final id = await rt.send(phone.id, [SendItem.file(a.path), SendItem.file(b.path)]);

    final (_, list) = await call('GET', '/api/offers', token: token);
    final offer = (list['offers']! as List).single as Map<String, Object?>;
    expect((offer['transferId'], offer['totalBytes']), (id, 300000 + 2 * 1024 * 1024 + 5));
    final files = (offer['files']! as List).cast<Map<String, Object?>>();

    // Safari navigates (no headers): it needs a ticket.
    final fileId = files.firstWhere((f) => f['name'] == 'clip.mov')['id'];
    expect((await (await http.getUrl(Uri.parse('$base/api/offers/$id/files/$fileId'))).close()).statusCode, 401);
    final (_, t) = await call('POST', '/api/offers/$id/ticket', token: token);
    final ticket = t['ticket'];
    final ranged = await http.getUrl(Uri.parse('$base/api/offers/$id/files/$fileId?ticket=$ticket'));
    ranged.headers.set('range', 'bytes=100-199');
    final rr = await ranged.close();
    expect(rr.statusCode, 206);
    final part = await rr.fold<List<int>>([], (acc, c) => acc..addAll(c));
    expect(sameBytes(Uint8List.fromList(part), Uint8List.sublistView(b.readAsBytesSync(), 100, 200)), isTrue);

    final zr = await (await http.getUrl(Uri.parse('$base/api/offers/$id/zip?ticket=$ticket'))).close();
    expect(zr.statusCode, 200);
    final zip = await zr.fold<List<int>>([], (acc, c) => acc..addAll(c));
    expect(zip.length, zr.contentLength);
    expect(zip.sublist(0, 4), [0x50, 0x4b, 0x03, 0x04]);

    final done = await rt.transfers.firstWhere((l) => l.any((x) => x.transferId == id && x.phase == TransferPhase.complete)).timeout(const Duration(seconds: 10));
    expect(done.firstWhere((x) => x.transferId == id).peerName, 'iPhone');
  });

  test('events socket: authenticated by subprotocol, pushes offers, answers ping', () async {
    final token = await pair('iPhone');
    final ws = await WebSocket.connect('${base.replaceFirst('http', 'ws')}/api/events', protocols: ['swiftdrop.v1', 'auth.$token']);
    final msgs = ws.map((m) => jsonDecode(m as String) as Map<String, Object?>).asBroadcastStream();
    expect((await msgs.first)['t'], 'hello');
    ws.add(jsonEncode({'t': 'ping', 'n': 42}));
    expect(await msgs.firstWhere((m) => m['t'] == 'pong').then((m) => m['n']), 42);
    await ws.close();
    await expectLater(WebSocket.connect('${base.replaceFirst('http', 'ws')}/api/events', protocols: ['swiftdrop.v1', 'auth.nope']), throwsA(isA<WebSocketException>()));
  });
}
