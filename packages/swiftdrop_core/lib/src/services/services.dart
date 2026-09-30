import '../platform/files.dart';
import 'models.dart';

/// Application services: the only API the app layer (Riverpod) talks to. Behind them sit
/// discovery, pairing, the engine and the transports; none of that leaks through here.

abstract interface class DeviceDirectory {
  /// Nearby, connected and remembered devices, re-emitted on every change.
  Stream<List<Device>> watch();
  Future<void> rename(String deviceId, String name);

  /// Removes trust: the next connection needs pairing again.
  Future<void> forget(String deviceId);
}

abstract interface class TransferService {
  /// Active and recently finished transfers.
  Stream<List<TransferSnapshot>> watch();

  /// Transfers waiting for this device's decision.
  Stream<List<IncomingOffer>> incoming();

  /// Starts sending; returns the transfer id. The receiver still has to accept.
  Future<String> send(String deviceId, List<FileSource> files);
  Future<void> accept(String transferId);
  Future<void> decline(String transferId);
  Future<void> pause(String transferId);
  Future<void> resume(String transferId);
  Future<void> cancel(String transferId);
}

abstract interface class TransferHistory {
  /// Newest first.
  Stream<List<TransferRecord>> watch();
  Future<void> remove(String transferId);
  Future<void> clear();
}
