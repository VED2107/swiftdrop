import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';

import '../../app/providers.dart';
import '../../app/updates.dart';
import '../../design/design.dart';

/// Checks for a newer release a few seconds after launch (once per run), if the person
/// allows it. Wrap the app in this.
class AutoUpdateCheck extends ConsumerStatefulWidget {
  const AutoUpdateCheck({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<AutoUpdateCheck> createState() => _AutoUpdateCheckState();
}

class _AutoUpdateCheckState extends ConsumerState<AutoUpdateCheck> {
  @override
  void initState() {
    super.initState();
    Future<void>.delayed(const Duration(seconds: 4), () {
      if (!mounted) return;
      if (ref.read(settingsProvider).autoUpdate && ref.read(updaterProvider) is! InertUpdater) {
        ref.read(updateProvider.notifier).check(silent: true);
      }
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Home: a quiet banner when a newer version is published. Closing it hides that version
/// until the next one; Settings always shows the latest.
class UpdateBanner extends ConsumerWidget {
  const UpdateBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final u = ref.watch(updateProvider);
    if (!u.showBanner) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: SdSpace.s5),
      child: InlineBanner(
        tone: BannerTone.success,
        icon: SdIcons.download,
        actionBelow: true,
        title: 'SwiftDrop ${u.info!.version} is ready',
        message: 'You have ${u.current}. See what changed, then update.',
        action: Row(mainAxisSize: MainAxisSize.min, children: [
          GlassButton(label: 'Not now', kind: GlassButtonKind.quiet, compact: true, onPressed: ref.read(updateProvider.notifier).dismissBanner),
          GlassButton(label: 'Update', kind: GlassButtonKind.secondary, compact: true, onPressed: () => showUpdateSheet(context)),
        ]),
      ),
    );
  }
}

Future<void> showUpdateSheet(BuildContext context) => showGlassSheet<void>(
      context,
      semanticLabel: 'Update SwiftDrop',
      builder: (_) => const _UpdateSheet(),
    );

class _UpdateSheet extends ConsumerWidget {
  const _UpdateSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.sdText;
    final u = ref.watch(updateProvider);
    final info = u.info;
    final ctl = ref.read(updateProvider.notifier);
    if (info == null) {
      return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('You’re up to date', style: t.title),
        const SizedBox(height: SdSpace.s2),
        Text('SwiftDrop ${u.current} is the latest version.', style: t.caption),
        const SizedBox(height: SdSpace.s5),
        PrimaryAction(label: 'Done', expand: true, onPressed: () => Navigator.of(context).pop()),
      ]);
    }
    final busy = u.stage == UpdateStage.downloading;
    final size = info.size == null ? '' : ' · ${formatBytes(info.size!)}';
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('SwiftDrop ${info.version}', style: t.title),
      const SizedBox(height: 2),
      Text('You have ${u.current}$size', style: t.caption),
      if (info.notes.isNotEmpty) ...[
        const SizedBox(height: SdSpace.s4),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 220),
          child: SingleChildScrollView(child: Text(_plain(info.notes), style: t.body)),
        ),
      ],
      const SizedBox(height: SdSpace.s5),
      if (busy) ...[
        ProgressGlass(value: u.progress, semanticsLabel: 'Downloading the update'),
        const SizedBox(height: SdSpace.s2),
        Text('Downloading ${(u.progress * 100).round()}%', style: t.caption),
      ] else ...[
        if (u.stage == UpdateStage.needsPermission)
          const Padding(
            padding: EdgeInsets.only(bottom: SdSpace.s3),
            child: InlineBanner(
              tone: BannerTone.warning,
              icon: SdIcons.failed,
              title: 'Allow installs from SwiftDrop',
              message: 'Android asks once. Turn it on in the page that just opened, come back, and tap Install again.',
            ),
          ),
        if (u.stage == UpdateStage.failed)
          const Padding(
            padding: EdgeInsets.only(bottom: SdSpace.s3),
            child: InlineBanner(
              tone: BannerTone.warning,
              icon: SdIcons.failed,
              title: 'The update didn’t download',
              message: 'Check your internet connection and try again. Nothing was changed.',
            ),
          ),
        if (info.installable)
          PrimaryAction(
            label: u.stage == UpdateStage.needsPermission ? 'Install' : 'Download and install',
            icon: SdIcons.download,
            expand: true,
            onPressed: ctl.install,
          )
        else
          PrimaryAction(label: 'Open release page', expand: true, onPressed: () => _openPage(info.pageUrl)),
        const SizedBox(height: SdSpace.s2),
        GlassButton(label: 'Later', kind: GlassButtonKind.quiet, expand: true, onPressed: () => Navigator.of(context).pop()),
      ],
    ]);
  }

  /// Release notes are Markdown; show them as calm plain text.
  static String _plain(String md) {
    final out = <String>[];
    for (var line in md.split('\n')) {
      line = line.trimRight().replaceFirst(RegExp(r'^#{1,6}\s*'), '').replaceAll('**', '').replaceAll('`', '');
      line = line.replaceFirst(RegExp(r'^\s*[-*]\s+'), '• ');
      out.add(line);
    }
    return out.join('\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }

  static Future<void> _openPage(String url) async {
    try {
      if (Platform.isWindows) {
        await Process.start('cmd', ['/c', 'start', '', url], mode: ProcessStartMode.detached);
      } else if (Platform.isMacOS) {
        await Process.start('open', [url]);
      } else if (Platform.isLinux) {
        await Process.start('xdg-open', [url]);
      }
    } catch (_) {}
  }
}

/// Settings rows: running version, latest version with its action, and the automatic check.
List<Widget> updateRows(BuildContext context, WidgetRef ref, {required bool auto, required ValueChanged<bool> onAuto}) {
  final u = ref.watch(updateProvider);
  final ctl = ref.read(updateProvider.notifier);
  final (String detail, Widget? action) = switch (u.stage) {
    UpdateStage.checking => ('Checking…', null),
    UpdateStage.available || UpdateStage.needsPermission || UpdateStage.failed when u.info != null => (
        '${u.info!.version} is available',
        GlassButton(label: 'Update', kind: GlassButtonKind.secondary, compact: true, onPressed: () => showUpdateSheet(context)),
      ),
    UpdateStage.downloading => ('Downloading ${(u.progress * 100).round()}%', null),
    UpdateStage.upToDate => ('${u.current}, you’re up to date', GlassButton(label: 'Check', kind: GlassButtonKind.quiet, compact: true, onPressed: ctl.check)),
    UpdateStage.failed => ('Couldn’t reach GitHub. Check your connection.', GlassButton(label: 'Try again', kind: GlassButtonKind.quiet, compact: true, onPressed: ctl.check)),
    _ => ('Not checked yet', GlassButton(label: 'Check', kind: GlassButtonKind.quiet, compact: true, onPressed: ctl.check)),
  };
  return [
    SettingsRow(title: 'Version', icon: SdIcons.info, detail: u.current.isEmpty ? 'Unknown' : u.current),
    SettingsRow(title: 'Latest version', icon: SdIcons.download, detail: detail, trailing: action),
    SettingsRow(
      title: 'Check for updates automatically',
      detail: 'Asks GitHub for the newest version number when the app opens. Nothing about you, your device or your files is sent.',
      trailing: GlassSwitch(value: auto, onChanged: onAuto, label: 'Check for updates automatically'),
    ),
  ];
}
