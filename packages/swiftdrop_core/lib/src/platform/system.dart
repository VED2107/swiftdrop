/// Platform boundaries that aren't files: discovery, identity, lifecycle, notifications.
/// Pure interfaces; the Flutter platform layer implements them per OS.
library;

enum DeviceKind { phone, tablet, laptop, desktop, unknown }

enum DevicePlatform { ios, android, windows, macos, linux, web, unknown }

/// This install's identity. The key pair lives in the platform keystore
/// (Keychain / Android Keystore / DPAPI / libsecret) and never leaves it.
class LocalIdentity {
  const LocalIdentity({
    required this.deviceId,
    required this.displayName,
    required this.kind,
    required this.platform,
    required this.certificateFingerprint,
  });

  /// SHA-256 of the public key, hex.
  final String deviceId;
  final String displayName;
  final DeviceKind kind;
  final DevicePlatform platform;

  /// SHA-256 of the TLS certificate, pinned by peers after pairing.
  final String certificateFingerprint;
}

abstract interface class IdentityStore {
  /// Creates the key pair and certificate on first use.
  Future<LocalIdentity> load();
  Future<LocalIdentity> rename(String displayName);
}

/// What a device publishes on the local network (DNS-SD TXT record). No file data, no
/// secrets: anyone on the network can read it.
class Advertisement {
  const Advertisement({
    required this.deviceId,
    required this.displayName,
    required this.kind,
    required this.platform,
    required this.port,
    this.protocolVersion = 1,
  });

  final String deviceId;
  final String displayName;
  final DeviceKind kind;
  final DevicePlatform platform;
  final int port;
  final int protocolVersion;
}

class DiscoveredPeer {
  const DiscoveredPeer({required this.advertisement, required this.addresses, required this.lastSeen});
  final Advertisement advertisement;

  /// Resolved addresses, tried in parallel when connecting.
  final List<String> addresses;
  final DateTime lastSeen;
}

enum DiscoveryAvailability {
  available,

  /// iOS local-network permission denied, Avahi missing on Linux, etc.
  permissionDenied,
  unsupported,
}

/// mDNS / Bonjour / NSD / DNS-SD. Never a cloud service.
abstract interface class Discovery {
  Future<DiscoveryAvailability> availability();

  /// Starts advertising this device; stop by calling the returned function.
  Future<Future<void> Function()> advertise(Advertisement ad);

  /// Current set of peers, re-emitted on every change. Excludes this device.
  Stream<List<DiscoveredPeer>> browse();
}

/// Keeps a transfer running while the app isn't in front, where the OS allows it:
/// Android user-initiated job / foreground service, iOS background task (short),
/// desktop always. [begin] never throws; an unsupported platform returns a no-op lease.
abstract interface class BackgroundExecution {
  Future<BackgroundLease> begin({required String transferId, required String title});
}

abstract interface class BackgroundLease {
  /// Progress for the system surface (notification, Live Activity), 0..1.
  void update(double progress, {String? detail});
  Future<void> end();
}

abstract interface class Notifications {
  Future<void> incomingTransfer({required String transferId, required String from, required String summary});
  Future<void> transferFinished({required String transferId, required String summary, required bool ok});
  Future<void> cancel(String transferId);
}
