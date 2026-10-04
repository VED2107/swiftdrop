import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';

import '../../app/picking.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../design/design.dart';
import '../screen_frame.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  String? _folderError;

  Future<void> _changeFolder() async {
    final dir = await getDirectoryPath(confirmButtonText: 'Save here');
    if (dir == null) return;
    try {
      await ref.read(settingsProvider.notifier).setDownloadDir(dir);
      setState(() => _folderError = null);
    } on TransportException {
      setState(() => _folderError = 'Finish or cancel the transfer that’s arriving, then change the folder.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(settingsProvider);
    final settings = ref.read(settingsProvider.notifier);
    final ep = ref.watch(endpointProvider).value;
    final engine = ref.watch(engineProvider);
    final desktop = !(Platform.isAndroid || Platform.isIOS);

    return ScreenFrame(
      title: 'Settings',
      maxWidth: 720,
      children: [
        SettingsGroup(
          title: 'Transfer',
          footer: _folderError,
          children: [
            SettingsRow(
              title: 'Save received files to',
              icon: SdIcons.folder,
              detail: prefs.downloadDir ?? 'Downloads',
              trailing: desktop
                  ? Row(mainAxisSize: MainAxisSize.min, children: [
                      if (prefs.downloadDir != null)
                        GlassButton(label: 'Show', kind: GlassButtonKind.quiet, compact: true, onPressed: () => revealFolder(prefs.downloadDir!)),
                      GlassButton(label: 'Change', kind: GlassButtonKind.secondary, compact: true, onPressed: _changeFolder),
                    ])
                  : null,
            ),
            SettingsRow(
              title: 'When a file already exists',
              icon: SdIcons.copy,
              below: SegmentedGlass<DuplicatePolicy>(
                label: 'When a file already exists',
                value: prefs.duplicates,
                options: const {DuplicatePolicy.keepBoth: 'Keep both', DuplicatePolicy.replace: 'Replace', DuplicatePolicy.skip: 'Skip'},
                onChanged: settings.setDuplicates,
              ),
            ),
          ],
        ),
        SettingsGroup(
          title: 'Connection',
          footer: 'Transfers stay on your local network. There’s no account and no server in between.',
          children: [
            SettingsRow(
              title: 'This device',
              icon: SdIcons.device(desktop ? DeviceKind.desktop : DeviceKind.phone),
              detail: ep == null ? 'Starting…' : 'Visible as ${ep.name}',
              onTap: engine == null || ep == null
                  ? null
                  : () async {
                      final name = await showRenameSheet(context, title: 'Name this device', current: ep.name);
                      if (name != null) await engine.setName(name);
                    },
            ),
            SettingsRow(title: 'Address', icon: SdIcons.local, detail: ep?.primary ?? 'Not on a network'),
            SettingsRow(title: 'Connect a device', icon: SdIcons.connect, onTap: () => context.push(Routes.pair)),
          ],
        ),
        SettingsGroup(
          title: 'Appearance',
          children: [
            SettingsRow(
              title: 'Motion',
              detail: 'Reduced keeps fades and drops movement. System follows your device.',
              below: SegmentedGlass<MotionPreference>(
                label: 'Motion',
                value: prefs.motion,
                options: const {MotionPreference.system: 'System', MotionPreference.reduced: 'Reduced', MotionPreference.full: 'Full'},
                onChanged: settings.setMotion,
              ),
            ),
            SettingsRow(
              title: 'High contrast',
              detail: 'Stronger edges and text. On automatically when your device asks for it.',
              below: SegmentedGlass<ContrastPreference>(
                label: 'High contrast',
                value: prefs.contrast,
                options: const {ContrastPreference.system: 'System', ContrastPreference.high: 'On'},
                onChanged: settings.setContrast,
              ),
            ),
          ],
        ),
        const SettingsGroup(
          title: 'Privacy',
          children: [
            SettingsRow(
              title: 'Who can reach this device',
              icon: SdIcons.visibility,
              detail: 'Devices on your network that know its address. Nothing is received without your Accept.',
            ),
            SettingsRow(
              title: 'Your files',
              icon: SdIcons.privacy,
              detail: 'Sent directly between your devices and checked block by block. SwiftDrop keeps no copies and collects no data.',
            ),
          ],
        ),
        SettingsGroup(
          title: 'Notifications',
          children: [
            SettingsRow(
              title: 'Sound for incoming transfers',
              icon: SdIcons.notifications,
              detail: 'Plays when another device asks to send you files.',
              trailing: GlassSwitch(value: prefs.notifyIncoming, onChanged: settings.setNotify, label: 'Sound for incoming transfers'),
            ),
          ],
        ),
        SettingsGroup(
          title: 'About',
          children: [
            const SettingsRow(title: 'SwiftDrop', detail: 'Version 0.3.0 (preview)'),
            SettingsRow(title: 'Open-source licenses', onTap: () => showLicensePage(context: context, applicationName: 'SwiftDrop')),
          ],
        ),
      ],
    );
  }
}
