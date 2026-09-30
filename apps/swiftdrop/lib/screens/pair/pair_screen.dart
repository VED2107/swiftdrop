import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';

import '../../app/connect_code.dart';
import '../../app/providers.dart';
import '../../app/shell.dart';
import '../../design/design.dart';
import '../screen_frame.dart';

enum _Mode { show, enter }

/// Connect a device (and, framed from Home, "Phone to phone"): this device on one side,
/// the other on the other, and the direct link that appears between them.
///
/// Show my code: this device's QR + address; the other device connects to it.
/// Enter code: type or paste the address the other device shows.
/// Scanning with the camera arrives with the mobile phases; secure pairing with a
/// confirmation code arrives in Phase 7 (docs/FLUTTER_MIGRATION.md §15).
class PairScreen extends ConsumerStatefulWidget {
  const PairScreen({super.key, this.phoneToPhone = false});
  final bool phoneToPhone;

  @override
  ConsumerState<PairScreen> createState() => _PairScreenState();
}

class _PairScreenState extends ConsumerState<PairScreen> {
  _Mode _mode = _Mode.show;
  final _address = TextEditingController();
  String? _error;
  bool _connecting = false;
  Device? _found;
  /// Devices already connected when the list first loaded: not "found" by this screen.
  Set<String>? _baseline;
  late final SearchingController _searching;

  @override
  void initState() {
    super.initState();
    _searching = ref.read(searchingProvider.notifier);
    // The environment breathes while we wait for the other device.
    WidgetsBinding.instance.addPostFrameCallback((_) => _searching.enter());
  }

  @override
  void dispose() {
    // Providers can't change while the tree is being torn down: defer by a microtask.
    final searching = _searching;
    Future.microtask(searching.leave);
    _address.dispose();
    super.dispose();
  }

  static bool _isLive(Device d) => d.status == DeviceStatus.connected || d.status == DeviceStatus.busy;

  Future<void> _connect() async {
    final addr = parseConnectInput(_address.text);
    if (addr == null) {
      setState(() => _error = 'Enter the address shown on the other device, like 192.168.1.20:47800.');
      return;
    }
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      final d = await ref.read(deviceDirectoryProvider).connect(addr);
      if (mounted) setState(() => _found = d);
      HapticFeedback.mediumImpact();
    } on TransportException catch (e) {
      if (!mounted) return;
      setState(() => _error = switch (e.code) {
            ErrorCode.badRequest => 'That doesn’t look like an address. It’s shown on the other device, like 192.168.1.20:47800.',
            _ => 'Couldn’t reach that device. Check that SwiftDrop is open there and both are on the same Wi-Fi or hotspot.',
          });
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.sdText;
    final ep = ref.watch(endpointProvider).value;
    final loaded = ref.watch(devicesProvider).value;
    final devices = loaded ?? const <Device>[];
    if (loaded != null) _baseline ??= {for (final d in loaded) if (_isLive(d)) d.id};
    // Someone connected to us while this screen was open.
    final base = _baseline;
    final arrived = base == null ? null : devices.where((d) => _isLive(d) && !base.contains(d.id)).firstOrNull;
    final peer = _found ?? arrived;
    final phone = Platform.isAndroid || Platform.isIOS;

    return ScreenFrame(
      title: widget.phoneToPhone ? 'Phone to Phone' : 'Connect a device',
      subtitle: widget.phoneToPhone ? 'Direct transfer. No computer needed.' : 'Directly, over your Wi-Fi or hotspot.',
      maxWidth: 620,
      children: [
        const SizedBox(height: SdSpace.s6),
        _LinkDiagram(
          self: (name: ep?.name ?? 'This device', kind: phone ? DeviceKind.phone : DeviceKind.desktop),
          peer: peer,
          phones: widget.phoneToPhone,
        ),
        const SizedBox(height: SdSpace.s6),
        if (peer != null)
          _Found(device: peer)
        else ...[
          SegmentedGlass<_Mode>(
            label: 'How to connect',
            value: _mode,
            options: const {_Mode.show: 'Show my code', _Mode.enter: 'Enter code'},
            onChanged: (m) => setState(() => _mode = m),
          ),
          const SizedBox(height: SdSpace.s6),
          if (_mode == _Mode.show)
            _ShowCode(endpoint: ep)
          else
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              GlassTextField(
                label: 'Address of the other device',
                hint: '192.168.1.20:47800',
                controller: _address,
                keyboardType: TextInputType.url,
                monospaceDigits: true,
                autofocus: !phone,
                error: _error,
                help: 'Shown on the other device under Receive, next to its code.',
                onSubmitted: (_) => _connect(),
              ),
              const SizedBox(height: SdSpace.s5),
              PrimaryAction(label: _connecting ? 'Connecting…' : 'Connect', icon: SdIcons.connect, expand: true, onPressed: _connecting ? null : _connect),
            ]),
          const SizedBox(height: SdSpace.s6),
          Text(
            'Nothing passes through the internet: devices talk to each other directly. Anyone who connects still needs you to accept each transfer.',
            style: t.caption,
          ),
        ],
      ],
    );
  }
}

class _ShowCode extends StatelessWidget {
  const _ShowCode({required this.endpoint});
  final LocalEndpoint? endpoint;

  @override
  Widget build(BuildContext context) {
    final t = context.sdText;
    final ep = endpoint;
    if (ep == null || ep.primary == null) {
      return const EmptyState(
        icon: SdIcons.offline,
        title: 'Not on a network yet',
        message: 'Join a Wi-Fi network or turn on a hotspot. Your code appears here as soon as this device has an address.',
      );
    }
    return Column(children: [
      Text('Scan this code with the other device', style: t.bodyStrong, textAlign: TextAlign.center),
      const SizedBox(height: SdSpace.s1),
      Text('or enter its address there', style: t.caption, textAlign: TextAlign.center),
      const SizedBox(height: SdSpace.s4),
      QrCodeGlassContainer(data: connectUri(ep)),
      const SizedBox(height: SdSpace.s4),
      SelectableText(ep.primary!, style: t.numeric, textAlign: TextAlign.center),
      const SizedBox(height: SdSpace.s4),
      const _Waiting(),
    ]);
  }
}

/// "Waiting for connection…" with a slow breathing mark (static under Reduce Motion).
class _Waiting extends StatefulWidget {
  const _Waiting();

  @override
  State<_Waiting> createState() => _WaitingState();
}

class _WaitingState extends State<_Waiting> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: SdMotion.breath);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (SdAppearance.of(context).reduceMotion) {
      _c.value = 1;
    } else {
      _c.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        FadeTransition(
          opacity: Tween(begin: 0.3, end: 1.0).animate(CurvedAnimation(parent: _c, curve: SdMotion.easeInOut)),
          child: const Icon(SdIcons.local, size: 16, color: SdColors.text2),
        ),
        const SizedBox(width: SdSpace.s2),
        Text('Waiting for connection…', style: context.sdText.caption),
      ]),
    );
  }
}

/// This device and the other one, and the link between them.
class _LinkDiagram extends StatelessWidget {
  const _LinkDiagram({required this.self, required this.peer, required this.phones});
  final ({String name, DeviceKind kind}) self;
  final Device? peer;
  final bool phones;

  @override
  Widget build(BuildContext context) {
    final t = context.sdText;
    final live = peer != null;
    Widget end(String name, DeviceKind kind, {bool dim = false}) => SizedBox(
          width: 110,
          child: Column(children: [
            DeviceGlyph(kind: kind, size: 64, live: live, dim: dim),
            const SizedBox(height: SdSpace.s2),
            Text(name, style: t.caption.copyWith(color: dim ? SdColors.text3 : SdColors.text), maxLines: 1, overflow: TextOverflow.ellipsis),
          ]),
        );
    return Semantics(
      label: live ? 'Connected to ${peer!.name}' : 'Not connected yet',
      child: ExcludeSemantics(
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          end(self.name, self.kind),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 31),
              child: Column(children: [
                AnimatedContainer(
                  duration: SdMotion.page,
                  height: 2,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: live ? [SdColors.red.withValues(alpha: 0.4), SdColors.red, SdColors.red.withValues(alpha: 0.4)] : const [SdColors.hairline, SdColors.hairlineStrong, SdColors.hairline]),
                  ),
                ),
                const SizedBox(height: SdSpace.s2),
                Text(live ? pathLabel(peer!.path) : 'Direct', style: t.caption.copyWith(color: live ? SdColors.redOnDark : SdColors.text3)),
              ]),
            ),
          ),
          if (peer != null) end(peer!.name, peer!.kind) else end(phones ? 'Other phone' : 'Other device', phones ? DeviceKind.phone : DeviceKind.unknown, dim: true),
        ]),
      ),
    );
  }
}

class _Found extends ConsumerWidget {
  const _Found({required this.device});
  final Device device;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.sdText;
    return Appear(
      child: LiquidGlass(
        level: GlassLevel.elevated,
        tint: SdColors.red,
        padding: const EdgeInsets.all(SdSpace.s5),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Connected', style: t.caption.copyWith(color: SdColors.redOnDark)),
          const SizedBox(height: SdSpace.s1),
          Text(device.name, style: t.title),
          Text(pathLabel(device.path), style: t.caption),
          const SizedBox(height: SdSpace.s5),
          PrimaryAction(label: 'Send files to ${device.name}', icon: SdIcons.upload, expand: true, onPressed: () => startSend(context, ref, deviceId: device.id)),
          const SizedBox(height: SdSpace.s2),
          GlassButton(label: 'Done', kind: GlassButtonKind.quiet, expand: true, onPressed: () => Navigator.of(context).maybePop()),
        ]),
      ),
    );
  }
}
