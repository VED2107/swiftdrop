import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';

import '../design/design.dart';

/// Application state. Riverpod wires services to the UI and holds UI-level preferences;
/// it contains no networking or transfer logic. Services come from `swiftdrop_core` and are
/// swapped per build (idle today, real per platform phase, demo behind a flag).

final deviceDirectoryProvider = Provider<DeviceDirectory>((ref) => IdleDeviceDirectory());
final transferServiceProvider = Provider<TransferService>((ref) => IdleTransferService());
final transferHistoryProvider = Provider<TransferHistory>((ref) => IdleTransferHistory());

final devicesProvider = StreamProvider<List<Device>>((ref) => ref.watch(deviceDirectoryProvider).watch());
final transfersProvider = StreamProvider<List<TransferSnapshot>>((ref) => ref.watch(transferServiceProvider).watch());
final incomingProvider = StreamProvider<List<IncomingOffer>>((ref) => ref.watch(transferServiceProvider).incoming());
final historyProvider = StreamProvider<List<TransferRecord>>((ref) => ref.watch(transferHistoryProvider).watch());

/// Any transfer moving right now: gives the environment its extra energy.
final transferActiveProvider = Provider<bool>((ref) {
  final list = ref.watch(transfersProvider).value ?? const [];
  return list.any((t) => t.phase == TransferPhase.running || t.phase == TransferPhase.preparing);
});

/// True in builds started with `--dart-define=SWIFTDROP_DEMO=true`: scripted devices and
/// transfers for design work. Invented numbers, so never in a release.
const demoMode = bool.fromEnvironment('SWIFTDROP_DEMO');

class AppearancePrefs {
  const AppearancePrefs({this.glass = GlassMode.full, this.motion = MotionPreference.system});
  final GlassMode glass;
  final MotionPreference motion;
  AppearancePrefs copyWith({GlassMode? glass, MotionPreference? motion}) =>
      AppearancePrefs(glass: glass ?? this.glass, motion: motion ?? this.motion);
}

/// Settings > Appearance. In memory for now; persisted with the settings store in Phase 4.
class AppearanceSettings extends Notifier<AppearancePrefs> {
  @override
  AppearancePrefs build() => const AppearancePrefs();

  void setGlass(GlassMode mode) => state = state.copyWith(glass: mode);
  void setMotion(MotionPreference pref) => state = state.copyWith(motion: pref);
}

final appearanceProvider = NotifierProvider<AppearanceSettings, AppearancePrefs>(AppearanceSettings.new);
