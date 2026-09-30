import 'dart:async';

import '../protocol/errors.dart';
import '../transport/engine_transport.dart';
import 'models.dart';
import 'services.dart';

/// Services for a build with no discovery or engine wired yet (Phase 2). They report the
/// truth: nobody nearby, nothing transferring. Real implementations replace them per
/// platform phase; demo data lives in `package:swiftdrop_core/testing.dart`, never here.

class IdleDeviceDirectory implements DeviceDirectory {
  @override
  Stream<List<Device>> watch() => Stream.value(const []);

  @override
  Stream<LocalEndpoint?> endpoint() => Stream.value(null);

  @override
  Future<Device> connect(String address) => Future.error(TransportException(ErrorCode.network, 'no transport available'));

  @override
  Future<void> rename(String deviceId, String name) async {}

  @override
  Future<void> forget(String deviceId) async {}
}

class IdleTransferService implements TransferService {
  @override
  Stream<List<TransferSnapshot>> watch() => Stream.value(const []);

  @override
  Stream<List<IncomingOffer>> incoming() => Stream.value(const []);

  @override
  Future<String> send(String deviceId, List<SendItem> items) =>
      Future.error(TransportException(ErrorCode.network, 'no transport available yet'));

  @override
  Future<void> accept(String transferId) async {}
  @override
  Future<void> decline(String transferId) async {}
  @override
  Future<void> pause(String transferId) async {}
  @override
  Future<void> resume(String transferId) async {}
  @override
  Future<void> cancel(String transferId) async {}
  @override
  Future<void> dismiss(String transferId) async {}
}

class IdleTransferHistory implements TransferHistory {
  @override
  Stream<List<TransferRecord>> watch() => Stream.value(const []);
  @override
  Future<void> remove(String transferId) async {}
  @override
  Future<void> clear() async {}
}
