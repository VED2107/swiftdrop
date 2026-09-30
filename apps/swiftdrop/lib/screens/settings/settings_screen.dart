import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../design/design.dart';
import '../screen_frame.dart';

/// Settings. Phase 2 carries Appearance (it drives the material system) and About; the
/// Transfer, Connection and Privacy sections arrive with the features they configure.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(appearanceProvider);
    final settings = ref.read(appearanceProvider.notifier);
    return ScreenFrame(
      title: 'Settings',
      children: [
        const SectionHeader('Appearance'),
        LiquidGlass(
          level: GlassLevel.surface,
          padding: const EdgeInsets.all(SdSpace.s4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _Choice<GlassMode>(
              title: 'Glass',
              help: 'Subtle drops the background blur; Off uses solid surfaces.',
              value: prefs.glass,
              options: const {GlassMode.full: 'Full', GlassMode.subtle: 'Subtle', GlassMode.off: 'Off'},
              onChanged: settings.setGlass,
            ),
            const Padding(padding: EdgeInsets.symmetric(vertical: SdSpace.s4), child: Divider(height: 1, color: SdColors.hairline)),
            _Choice<MotionPreference>(
              title: 'Motion',
              help: 'Reduced keeps fades and drops movement. System follows your device setting.',
              value: prefs.motion,
              options: const {MotionPreference.system: 'System', MotionPreference.reduced: 'Reduced', MotionPreference.full: 'Full'},
              onChanged: settings.setMotion,
            ),
          ]),
        ),
        const SectionHeader('About'),
        LiquidGlass(
          level: GlassLevel.surface,
          padding: const EdgeInsets.all(SdSpace.s4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('SwiftDrop', style: context.sdText.bodyStrong),
            const SizedBox(height: 2),
            Text('Moves files directly between your devices. Nothing passes through a server.', style: context.sdText.caption),
            if (kDebugMode) ...[
              const SizedBox(height: SdSpace.s4),
              SecondaryAction(label: 'Design gallery', compact: true, onPressed: () => context.push(Routes.gallery)),
            ],
          ]),
        ),
      ],
    );
  }
}

/// A labelled setting with its help line and a segmented control.
class _Choice<T> extends StatelessWidget {
  const _Choice({required this.title, required this.help, required this.value, required this.options, required this.onChanged});
  final String title;
  final String help;
  final T value;
  final Map<T, String> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = context.sdText;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(title, style: t.bodyStrong),
      const SizedBox(height: 2),
      Text(help, style: t.caption),
      const SizedBox(height: SdSpace.s3),
      SegmentedGlass<T>(label: title, value: value, options: options, onChanged: onChanged),
    ]);
  }
}
