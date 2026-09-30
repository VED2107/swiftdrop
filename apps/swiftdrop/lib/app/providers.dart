import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:swiftdrop_core/runtime.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';

import '../design/design.dart';
import 'picking.dart';
import 'settings.dart';

/// Application state. Riverpod wires the engine's services to widgets and holds UI-level
/// state (preferences, the current selection). It contains no networking or transfer
/// logic: that lives in `swiftdrop_core`, in the engine isolate.

/// The running engine, when there is one (null in widget tests and demo builds).
final engineProvider = Provider<EngineHost?>((ref) => null);

final deviceDirectoryProvider = Provider<DeviceDirectory>((ref) => IdleDeviceDirectory());
final transferServiceProvider = Provider<TransferService>((ref) => IdleTransferService());
final transferHistoryProvider = Provider<TransferHistory>((ref) => IdleTransferHistory());

final devicesProvider = StreamProvider<List<Device>>((ref) => ref.watch(deviceDirectoryProvider).watch());
final endpointProvider = StreamProvider<LocalEndpoint?>((ref) => ref.watch(deviceDirectoryProvider).endpoint());
final transfersProvider = StreamProvider<List<TransferSnapshot>>((ref) => ref.watch(transferServiceProvider).watch());
final incomingProvider = StreamProvider<List<IncomingOffer>>((ref) => ref.watch(transferServiceProvider).incoming());
final historyProvider = StreamProvider<List<TransferRecord>>((ref) => ref.watch(transferHistoryProvider).watch());

/// One transfer by id (the transfer screen watches only this).
final transferProvider = Provider.family<TransferSnapshot?, String>((ref, id) {
  final list = ref.watch(transfersProvider).value ?? const [];
  for (final t in list) {
    if (t.transferId == id) return t;
  }
  return null;
});

/// True in builds started with `--dart-define=SWIFTDROP_DEMO=true`: scripted devices and
/// transfers for design work. Invented numbers, so never in a release.
const demoMode = bool.fromEnvironment('SWIFTDROP_DEMO');

// ---------------------------------------------------------------------------
// Preferences

final settingsFileProvider = Provider<SettingsFile>((ref) => SettingsFile(null));

class SettingsController extends Notifier<AppSettings> {
  @override
  AppSettings build() => ref.watch(settingsFileProvider).load();

  void _set(AppSettings s) {
    state = s;
    ref.read(settingsFileProvider).save(s);
  }

  void setGlass(GlassMode v) => _set(state.copyWith(glass: v));
  void setMotion(MotionPreference v) => _set(state.copyWith(motion: v));
  void setContrast(ContrastPreference v) => _set(state.copyWith(contrast: v));
  void setNotify(bool v) => _set(state.copyWith(notifyIncoming: v));

  Future<void> setDuplicates(DuplicatePolicy v) async {
    await ref.read(engineProvider)?.setDuplicates(v);
    _set(state.copyWith(duplicates: v));
  }

  /// Throws when the engine refuses (something is being received right now).
  Future<void> setDownloadDir(String dir) async {
    await ref.read(engineProvider)?.setDownloadDir(dir);
    _set(state.copyWith(downloadDir: dir));
  }
}

final settingsProvider = NotifierProvider<SettingsController, AppSettings>(SettingsController.new);

/// The folder received files go to (resolved at startup; changes with the setting).
final downloadDirProvider = Provider<String?>((ref) => ref.watch(settingsProvider).downloadDir);

// ---------------------------------------------------------------------------
// Environment: what the background expresses, derived from real state only.

/// Set while a screen is actively waiting for a device (pairing).
class SearchingController extends Notifier<int> {
  @override
  int build() => 0;
  void enter() {
    if (ref.mounted) state++;
  }

  /// Called from a screen's dispose (deferred); the app may be shutting down by then.
  void leave() {
    if (ref.mounted) state = state > 0 ? state - 1 : 0;
  }
}

final searchingProvider = NotifierProvider<SearchingController, int>(SearchingController.new);

/// Counts transfers that reached "complete" while the app watched (the bloom's trigger).
class CompletionCounter extends Notifier<int> {
  final _seen = <String>{};

  @override
  int build() {
    ref.listen(transfersProvider, (_, next) {
      for (final t in next.value ?? const <TransferSnapshot>[]) {
        if (t.phase == TransferPhase.complete && _seen.add(t.transferId)) state++;
      }
    });
    return 0;
  }
}

final completionsProvider = NotifierProvider<CompletionCounter, int>(CompletionCounter.new);

final environmentProvider = Provider<({EnvironmentState state, double energy})>((ref) {
  final transfers = ref.watch(transfersProvider).value ?? const [];
  final running = transfers.where((t) => t.phase == TransferPhase.running).toList();
  if (running.isNotEmpty) {
    final speed = running.fold<double>(0, (s, t) => s + t.speed);
    return (state: EnvironmentState.transferring, energy: (speed / 120e6).clamp(0.0, 1.0));
  }
  if (ref.watch(searchingProvider) > 0) return (state: EnvironmentState.searching, energy: 0.0);
  final devices = ref.watch(devicesProvider).value ?? const [];
  if (devices.any((d) => d.status == DeviceStatus.connected || d.status == DeviceStatus.busy)) {
    return (state: EnvironmentState.connected, energy: 0.0);
  }
  return (state: EnvironmentState.idle, energy: 0.0);
});

// ---------------------------------------------------------------------------
// The send flow's selection

class SendSelection {
  const SendSelection({this.items = const [], this.deviceId});
  final List<PickedItem> items;
  final String? deviceId;

  int get totalBytes => items.fold(0, (s, i) => s + i.view.size);
  int get fileCount => items.fold(0, (s, i) => s + (i.view.folderFiles ?? 1));
  bool get isEmpty => items.isEmpty;
}

class SelectionController extends Notifier<SendSelection> {
  @override
  SendSelection build() => const SendSelection();

  void add(List<PickedItem> items) {
    final known = {for (final i in state.items) i.send.path};
    state = SendSelection(items: [...state.items, ...items.where((i) => known.add(i.send.path))], deviceId: state.deviceId);
  }

  void removeAt(int index) => state = SendSelection(items: [...state.items]..removeAt(index), deviceId: state.deviceId);
  void target(String? deviceId) => state = SendSelection(items: state.items, deviceId: deviceId);
  void clear() => state = const SendSelection();
}

final selectionProvider = NotifierProvider<SelectionController, SendSelection>(SelectionController.new);
