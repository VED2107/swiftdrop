import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';

import '../../app/picking.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../design/design.dart';
import '../screen_frame.dart';

/// Review before sending: where it goes, what goes, how much. One primary action in a
/// floating dock: Send 1.8 GB.
class SendScreen extends ConsumerStatefulWidget {
  const SendScreen({super.key});

  @override
  ConsumerState<SendScreen> createState() => _SendScreenState();
}

class _SendScreenState extends ConsumerState<SendScreen> {
  bool _sending = false;
  String? _error;

  Future<void> _add({bool folder = false}) async {
    final items = folder ? await pickFolder() : await pickFiles();
    ref.read(selectionProvider.notifier).add(items);
  }

  Future<void> _send(Device target) async {
    final sel = ref.read(selectionProvider);
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final id = await ref.read(transferServiceProvider).send(target.id, [for (final i in sel.items) i.send]);
      ref.read(selectionProvider.notifier).clear();
      if (mounted) context.pushReplacement(Routes.transfer(id));
    } on TransportException catch (e) {
      setState(() => _error = e.code == ErrorCode.network
          ? 'Couldn’t reach ${target.name}. Check that SwiftDrop is open there and you’re on the same network.'
          : e.userMessage);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.sdText;
    final sel = ref.watch(selectionProvider);
    final devices = ref.watch(devicesProvider).value ?? const <Device>[];
    final reachable = devices.where((d) => d.status != DeviceStatus.offline || d.address != null).toList();
    final target = devices.where((d) => d.id == sel.deviceId).firstOrNull ??
        devices.where((d) => d.status == DeviceStatus.connected || d.status == DeviceStatus.busy).firstOrNull;
    final layout = SdLayout.of(context);
    final columns = layout.isPhone ? 4 : (layout == SdLayout.tablet ? 5 : 6);

    final dock = LiquidGlass(
      level: GlassLevel.floating,
      padding: const EdgeInsets.all(SdSpace.s2),
      child: Row(children: [
        Expanded(
          child: PrimaryAction(
            label: sel.isEmpty ? 'Choose files' : (_sending ? 'Starting…' : 'Send ${formatBytes(sel.totalBytes)}'),
            icon: SdIcons.upload,
            expand: true,
            onPressed: sel.isEmpty ? _add : (target == null || _sending ? null : () => _send(target)),
          ),
        ),
      ]),
    );

    return Stack(children: [
      Positioned.fill(
        child: MediaQuery(
          data: MediaQuery.of(context).copyWith(padding: MediaQuery.paddingOf(context).copyWith(bottom: 96 + MediaQuery.paddingOf(context).bottom)),
          child: ScreenFrame(
            title: 'Send to',
            maxWidth: 820,
            children: [
              const SizedBox(height: SdSpace.s4),
              if (reachable.isEmpty)
                EmptyState(
                  icon: SdIcons.connect,
                  title: 'Connect a device first',
                  message: 'Files go directly to another device running SwiftDrop. Connect to it with its address.',
                  action: SecondaryAction(label: 'Connect a device', icon: SdIcons.connect, onPressed: () => context.push(Routes.pair)),
                )
              else
                _TargetPicker(devices: reachable, selected: target?.id, onSelect: (id) => ref.read(selectionProvider.notifier).target(id)),
              const SizedBox(height: SdSpace.s6),
              Semantics(
                liveRegion: true,
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.end,
                  alignment: WrapAlignment.spaceBetween,
                  spacing: SdSpace.s3,
                  runSpacing: SdSpace.s2,
                  children: [
                    Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
                      Text(plural(sel.fileCount, 'file'), style: t.numeric),
                      const SizedBox(width: SdSpace.s3),
                      Text(formatBytes(sel.totalBytes), style: t.numeric.copyWith(color: SdColors.text2)),
                    ]),
                    GlassButton(label: 'Add files', icon: SdIcons.send, kind: GlassButtonKind.quiet, compact: true, onPressed: _add),
                    GlassButton(label: 'Add folder', icon: SdIcons.folder, kind: GlassButtonKind.quiet, compact: true, onPressed: () => _add(folder: true)),
                  ],
                ),
              ),
              const SizedBox(height: SdSpace.s4),
              if (_error != null) ...[
                InlineBanner(tone: BannerTone.warning, icon: SdIcons.failed, title: 'Not sent', message: _error),
                const SizedBox(height: SdSpace.s4),
              ],
              if (sel.isEmpty)
                const EmptyState(icon: SdIcons.upload, title: 'Nothing selected', message: 'Choose files or a folder, or drop them onto this window.')
              else
                FileCollection(
                  items: [for (final i in sel.items) i.view],
                  columns: columns,
                  onRemove: (i) => ref.read(selectionProvider.notifier).removeAt(i),
                ),
            ],
          ),
        ),
      ),
      Positioned(
        left: SdSpace.s3,
        right: SdSpace.s3,
        bottom: SdSpace.s3 + MediaQuery.paddingOf(context).bottom,
        child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 520), child: dock)),
      ),
    ]);
  }
}

/// Where the files go: the connected device first, others one tap away.
class _TargetPicker extends StatelessWidget {
  const _TargetPicker({required this.devices, required this.selected, required this.onSelect});
  final List<Device> devices;
  final String? selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final t = context.sdText;
    return Wrap(spacing: SdSpace.s3, runSpacing: SdSpace.s3, children: [
      for (final d in devices)
        Semantics(
          selected: d.id == selected,
          child: Pressable(
            onPressed: () => onSelect(d.id),
            semanticLabel: d.name,
            focusRadius: SdRadius.row,
            haptic: false,
            child: LiquidGlass(
              level: GlassLevel.elevated,
              interactive: true,
              radius: SdRadius.row,
              tint: d.id == selected ? SdColors.red : null,
              tintStrength: 0.14,
              padding: const EdgeInsets.fromLTRB(SdSpace.s3, SdSpace.s3, SdSpace.s4, SdSpace.s3),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                DeviceGlyph(kind: d.kind, size: 36, live: d.id == selected),
                const SizedBox(width: SdSpace.s3),
                Flexible(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text(d.name, style: t.bodyStrong, maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(deviceStatus(d).label, style: t.caption, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ]),
                ),
              ]),
            ),
          ),
        ),
    ]);
  }
}
