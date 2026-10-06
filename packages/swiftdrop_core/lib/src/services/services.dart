import 'models.dart';

/// Application services: the only API the app layer (Riverpod) talks to. Behind them sit
/// discovery, pairing, the engine and the transports; none of that leaks through here.

/// Something picked to send. Plain data (it crosses into the engine isolate).
class SendItem {
  const SendItem.file(this.path) : folder = false;
  const SendItem.folder(this.path) : folder = true;

  /// Filesystem path (desktop; on mobile a path the platform layer resolved).
  final String path;

  /// A folder is sent with its structure (relative paths preserved).
  final bool folder;
}

/// How other devices reach this one (shown on the Receive screen, encoded in the QR).
class LocalEndpoint {
  const LocalEndpoint({required this.deviceId, required this.name, required this.addresses, required this.port, this.web, this.labels = const {}});
  final String deviceId;
  final String name;

  /// Private LAN addresses of connected interfaces, best first.
  final List<String> addresses;

  /// Interface name per address ("Wi-Fi", "Ethernet"), so a person can pick the network
  /// the other device is on when this one has several.
  final Map<String, String> labels;
  final int port;

  /// Browser access for phones without the app (an iPhone's Camera opens the link).
  final BrowserAccess? web;

  /// What the other device types or scans: `192.168.1.20:47800`.
  String? get primary => addresses.isEmpty ? null : '${addresses.first}:$port';
}

/// How a phone without the app pairs: scan the QR (`url`) or type the code at `manual`.
class BrowserAccess {
  const BrowserAccess({required this.port, required this.token, required this.code, required this.expiresAt});
  final int port;
  final String token;
  final String code;
  final DateTime expiresAt;

  String url(String address) => 'http://$address:$port/#p=$token';
  String manual(String address) => 'http://$address:$port';
}

/// A browser asking to pair; nothing is granted until this device approves.
class BrowserJoin {
  const BrowserJoin({required this.id, required this.deviceName, required this.viaCode, required this.returning});
  final String id;
  final String deviceName;

  /// Typed the short code rather than scanning the QR.
  final bool viaCode;

  /// This browser was paired before (approving refreshes it).
  final bool returning;
}

abstract interface class DeviceDirectory {
  /// Nearby, connected and remembered devices, re-emitted on every change.
  Stream<List<Device>> watch();

  /// This device as others see it; null until the listener is up.
  Stream<LocalEndpoint?> endpoint();

  /// Connects to a device by address (`host:port`), remembers it, returns it.
  Future<Device> connect(String address);

  /// Connects to a device known by several addresses (every network its QR listed): the
  /// first that answers, and answers as [deviceId] when given, wins.
  Future<Device> connectAny(List<String> addresses, {String? deviceId});
  Future<void> rename(String deviceId, String name);

  /// Removes it from known devices (and trust, once pairing exists).
  Future<void> forget(String deviceId);
}

abstract interface class TransferService {
  /// Active and recently finished transfers.
  Stream<List<TransferSnapshot>> watch();

  /// Transfers waiting for this device's decision.
  Stream<List<IncomingOffer>> incoming();

  /// Starts sending; returns the transfer id. The receiver still has to accept.
  Future<String> send(String deviceId, List<SendItem> items);
  Future<void> accept(String transferId);
  Future<void> decline(String transferId);
  Future<void> pause(String transferId);
  Future<void> resume(String transferId);
  Future<void> cancel(String transferId);

  /// Drop a finished transfer from the live list (it stays in history).
  Future<void> dismiss(String transferId);
}

abstract interface class TransferHistory {
  /// Newest first.
  Stream<List<TransferRecord>> watch();
  Future<void> remove(String transferId);
  Future<void> clear();
}
