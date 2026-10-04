import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';

import '../../app/connect_code.dart';
import '../../app/providers.dart';
import '../../app/shell.dart';
import '../../design/design.dart';
import '../receive/universal_qr.dart';
import '../screen_frame.dart';

enum _Mode { scan, show, enter }

/// Connect a device (and, framed from Home, "Phone to phone"): this device on one side,
/// the other on the other, and the direct link that appears between them.
///
/// Show my code: this device's QR + address; the other device connects to it.
/// Scan receiver QR (phones): read the code the receiver shows and connect to it once.
/// Enter code: type or paste the address the other device shows.
/// Secure pairing with a confirmation code arrives in Phase 7 (docs/FLUTTER_MIGRATION.md §15).
class PairScreen extends ConsumerStatefulWidget {
  const PairScreen({super.key, this.phoneToPhone = false});
  final bool phoneToPhone;

  @override
  ConsumerState<PairScreen> createState() => _PairScreenState();
}

class _PairScreenState extends ConsumerState<PairScreen> {
  late _Mode _mode = (Platform.isAndroid || Platform.isIOS)
      ? _Mode.scan
      : _Mode.show;
  final _address = TextEditingController();
  String? _error;
  bool _connecting = false;
  String? _connectingTo;
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

  static bool _isLive(Device d) =>
      d.status == DeviceStatus.connected || d.status == DeviceStatus.busy;

  /// Upper bound on one connect attempt (TCP dial per lane + hello), so the screen
  /// never sits on "Connecting…" indefinitely.
  static const _connectTimeout = Duration(seconds: 20);

  /// Typed or pasted address (Enter code).
  Future<bool> _connect() async {
    final addr = parseConnectInput(_address.text);
    if (addr == null) {
      setState(
        () => _error = 'Enter the address shown on the other device, like 192.168.1.20:47800.',
      );
      return false;
    }
    return _dial(addr);
  }

  /// Scanned receiver QR, already validated by [readScannedCode].
  Future<bool> _connectScanned(ScannedCode code) =>
      _dial(code.address!, peerName: code.name);

  Future<bool> _dial(String addr, {String? peerName}) async {
    setState(() {
      _connecting = true;
      _connectingTo = peerName;
      _error = null;
    });
    debugPrint('[PAIR] role=sender dialing peer=${_redact(addr)}');
    try {
      final d = await ref
          .read(deviceDirectoryProvider)
          .connect(addr)
          .timeout(_connectTimeout);
      if (mounted) setState(() => _found = d);
      HapticFeedback.mediumImpact();
      debugPrint('[PAIR] ready peer=${_redact(d.id)} path=${d.path == null ? "?" : pathLabel(d.path)}');
      return true;
    } on TimeoutException {
      debugPrint('[PAIR] connect timed out');
      if (mounted) {
        setState(
          () => _error = 'It didn’t answer. Check that SwiftDrop is open there and both are on the same Wi-Fi or hotspot.',
        );
      }
      return false;
    } on TransportException catch (e) {
      debugPrint('[PAIR] connect failed code=${e.code.name}');
      if (mounted) {
        setState(
          () => _error = switch (e.code) {
            ErrorCode.badRequest => 'That doesn’t look like an address. It’s shown on the other device, like 192.168.1.20:47800.',
            _ => 'Couldn’t reach that device. Check that SwiftDrop is open there and both are on the same Wi-Fi or hotspot.',
          },
        );
      }
      return false;
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  /// Logs keep only a short prefix of addresses and ids.
  static String _redact(String s) => s.length > 8 ? '${s.substring(0, 8)}…' : s;

  @override
  Widget build(BuildContext context) {
    final t = context.sdText;
    final ep = ref.watch(endpointProvider).value;
    final loaded = ref.watch(devicesProvider).value;
    final devices = loaded ?? const <Device>[];
    if (loaded != null) {
      _baseline ??= {
        for (final d in loaded)
          if (_isLive(d)) d.id,
      };
    }
    // Someone connected to us while this screen was open.
    final base = _baseline;
    final arrived = base == null
        ? null
        : devices.where((d) => _isLive(d) && !base.contains(d.id)).firstOrNull;
    final peer = _found ?? arrived;
    final phone = Platform.isAndroid || Platform.isIOS;

    return ScreenFrame(
      title: widget.phoneToPhone ? 'Phone to Phone' : 'Connect a device',
      subtitle: widget.phoneToPhone
          ? 'Direct transfer. No computer needed.'
          : 'Directly, over your Wi-Fi or hotspot.',
      maxWidth: 620,
      children: [
        const SizedBox(height: SdSpace.s6),
        _LinkDiagram(
          self: (
            name: ep?.name ?? 'This device',
            kind: phone ? DeviceKind.phone : DeviceKind.desktop,
          ),
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
            options: {
              if (phone) _Mode.scan: 'Scan receiver QR',
              _Mode.show: 'Show my code',
              _Mode.enter: 'Enter code',
            },
            onChanged: (m) => setState(() => _mode = m),
          ),
          const SizedBox(height: SdSpace.s6),
          if (_mode == _Mode.scan)
            _ScanCode(
              connecting: _connecting,
              connectingTo: _connectingTo,
              error: _error,
              onCode: _connectScanned,
            )
          else if (_mode == _Mode.show)
            _ShowCode(endpoint: ep)
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
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
                PrimaryAction(
                  label: _connecting ? 'Connecting…' : 'Connect',
                  icon: SdIcons.connect,
                  expand: true,
                  onPressed: _connecting ? null : _connect,
                ),
              ],
            ),
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

/// The receiver-QR scanner. One camera controller for the widget's whole life, driven
/// only from here (autoStart off): permission, app lifecycle and "a code was read" all
/// go through [_sync], so the camera never runs twice, never runs off-screen, and a code
/// is acted on exactly once until the person asks to scan again.
class _ScanCode extends StatefulWidget {
  const _ScanCode({
    required this.onCode,
    required this.connecting,
    this.connectingTo,
    this.error,
  });
  final Future<bool> Function(ScannedCode code) onCode;
  final bool connecting;
  final String? connectingTo;
  final String? error;

  @override
  State<_ScanCode> createState() => _ScanCodeState();
}

class _ScanCodeState extends State<_ScanCode> with WidgetsBindingObserver {
  final _controller = MobileScannerController(
    autoStart: false,
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [BarcodeFormat.qrCode],
  );
  PermissionStatus? _permission;
  bool _foreground = true;

  /// A code was read: the camera stays off until [_scanAgain] (or it connected).
  bool _held = false;
  ScanProblem? _problem;

  /// The system permission sheet pauses the activity; its resume must not re-check.
  bool _requesting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkPermission(request: true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_controller.dispose());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      // Back from Settings (or the lock screen): permission may have changed.
      if (!_requesting) _checkPermission();
    } else {
      _sync();
    }
  }

  Future<void> _checkPermission({bool request = false}) async {
    var status = await Permission.camera.status;
    if (request && status.isDenied) {
      _requesting = true;
      debugPrint('[PERMISSION] camera requesting');
      try {
        status = await Permission.camera.request();
      } finally {
        _requesting = false;
      }
    }
    debugPrint('[PERMISSION] camera ${status.name}');
    if (!mounted) return;
    setState(() => _permission = status);
    // The preview widget mounts on this frame; start the camera after it.
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  /// Runs the camera exactly when it should run, and stops it otherwise.
  Future<void> _sync() async {
    if (!mounted) return;
    final want = _foreground && !_held && (_permission?.isGranted ?? false);
    final v = _controller.value;
    try {
      if (want && !v.isRunning && !v.isStarting) {
        await _controller.start();
        debugPrint('[QR] scanner started');
      } else if (!want && (v.isRunning || v.isStarting)) {
        await _controller.stop();
        debugPrint('[QR] scanner stopped');
      }
    } on MobileScannerException catch (e) {
      // Start/stop raced a lifecycle change; the next change re-syncs.
      debugPrint('[QR] scanner ${e.errorCode.name}');
    }
  }

  void _onDetect(BarcodeCapture capture) {
    if (_held || widget.connecting) return;
    final raw = capture.barcodes
        .map((b) => b.rawValue)
        .whereType<String>()
        .where((s) => s.trim().isNotEmpty)
        .firstOrNull;
    if (raw == null) return;
    // Hold before anything async: a second frame of the same code is ignored.
    _held = true;
    unawaited(_sync());
    final code = readScannedCode(raw);
    if (code.problem != null) {
      debugPrint('[QR] rejected ${code.problem!.name} len=${raw.length}');
      HapticFeedback.heavyImpact();
      setState(() => _problem = code.problem);
      return;
    }
    debugPrint('[QR] decoded v$connectCodeVersion');
    HapticFeedback.selectionClick();
    setState(() => _problem = null);
    // On success the pair screen swaps this widget for "Connected"; on failure the
    // camera stays held and the error offers Scan again.
    widget.onCode(code);
  }

  void _scanAgain() {
    setState(() {
      _held = false;
      _problem = null;
    });
    _sync();
  }

  static String _problemTitle(ScanProblem p) => switch (p) {
    ScanProblem.notSwiftDrop => 'This isn’t a SwiftDrop QR code.',
    ScanProblem.unsupportedVersion => 'Unsupported SwiftDrop version.',
    ScanProblem.browserOnly => 'This is a browser code.',
  };

  static String _problemMessage(ScanProblem p) => switch (p) {
    ScanProblem.notSwiftDrop => 'Scan the code shown under Receive on the other device.',
    ScanProblem.unsupportedVersion => 'The other device has a newer SwiftDrop. Update this app, then scan again.',
    ScanProblem.browserOnly => 'It comes from SwiftDrop in a browser (phone to phone). Open it with this phone’s Camera or browser instead.',
  };

  @override
  Widget build(BuildContext context) {
    final t = context.sdText;
    final status = _permission;
    if (status == null) {
      return const EmptyState(
        icon: SdIcons.scan,
        title: 'Checking camera',
        message: 'SwiftDrop needs the camera to scan the receiver QR code.',
      );
    }
    if (!status.isGranted) {
      final permanently = status.isPermanentlyDenied || status.isRestricted;
      return EmptyState(
        icon: SdIcons.offline,
        title: permanently ? 'Camera access is disabled' : 'Camera permission needed',
        message: permanently
            ? 'Turn on camera access for SwiftDrop in Settings. Scanning resumes when you come back.'
            : 'Allow camera access to scan the receiver QR code.',
        action: permanently
            ? PrimaryAction(
                label: 'Open Settings',
                icon: SdIcons.settings,
                onPressed: openAppSettings,
              )
            : PrimaryAction(
                label: 'Allow camera',
                icon: SdIcons.scan,
                onPressed: () => _checkPermission(request: true),
              ),
      );
    }

    final problem = _problem;
    final failed = _held && !widget.connecting && (problem != null || widget.error != null);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AspectRatio(
          aspectRatio: 1,
          child: ClipRRect(
            borderRadius: SdRadius.all(SdRadius.card),
            child: Stack(
              fit: StackFit.expand,
              children: [
                MobileScanner(
                  controller: _controller,
                  onDetect: _onDetect,
                  errorBuilder: (context, error) => ColoredBox(
                    color: SdColors.scrim,
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(SdSpace.s5),
                        child: Text(
                          'The camera couldn’t start (${error.errorCode.name}). Close other apps using it and scan again.',
                          style: t.caption,
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  ),
                ),
                IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(color: SdColors.hairlineStrong, width: 1),
                      borderRadius: SdRadius.all(SdRadius.card),
                    ),
                  ),
                ),
                if (widget.connecting || failed)
                  ColoredBox(
                    color: SdColors.scrim,
                    child: Center(
                      child: Appear(
                        child: LiquidGlass(
                          level: GlassLevel.elevated,
                          padding: const EdgeInsets.all(SdSpace.s4),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                widget.connecting ? SdIcons.connect : SdIcons.failed,
                                size: 18,
                                color: widget.connecting ? SdColors.redOnDark : SdColors.text2,
                              ),
                              const SizedBox(width: SdSpace.s2),
                              Flexible(
                                child: Text(
                                  widget.connecting
                                      ? 'Connecting to ${widget.connectingTo ?? 'the receiver'}…'
                                      : 'Not connected',
                                  style: t.bodyStrong,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: SdSpace.s4),
        Text('Scan receiver QR', style: t.bodyStrong, textAlign: TextAlign.center),
        const SizedBox(height: SdSpace.s1),
        Text(
          'Align the QR shown under Receive on the other device inside the frame.',
          style: t.caption,
          textAlign: TextAlign.center,
        ),
        if (failed) ...[
          const SizedBox(height: SdSpace.s4),
          InlineBanner(
            tone: BannerTone.warning,
            icon: SdIcons.failed,
            title: problem != null ? _problemTitle(problem) : 'Couldn’t connect to this device.',
            message: problem != null ? _problemMessage(problem) : widget.error,
          ),
          const SizedBox(height: SdSpace.s4),
          PrimaryAction(
            label: 'Scan again',
            icon: SdIcons.scan,
            expand: true,
            onPressed: _scanAgain,
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
    final ep = endpoint;
    if (ep == null || ep.primary == null) {
      return const EmptyState(
        icon: SdIcons.offline,
        title: 'Not on a network yet',
        message: 'Join a Wi-Fi network or turn on a hotspot. Your code appears here as soon as this device has an address.',
      );
    }
    return Column(
      children: [
        UniversalQr(endpoint: ep),
        const SizedBox(height: SdSpace.s4),
        const _Waiting(),
      ],
    );
  }
}

/// "Waiting for connection…" with a slow breathing mark (static under Reduce Motion).
class _Waiting extends StatefulWidget {
  const _Waiting();

  @override
  State<_Waiting> createState() => _WaitingState();
}

class _WaitingState extends State<_Waiting>
    with SingleTickerProviderStateMixin {
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
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FadeTransition(
            opacity: Tween(
              begin: 0.3,
              end: 1.0,
            ).animate(CurvedAnimation(parent: _c, curve: SdMotion.easeInOut)),
            child: const Icon(SdIcons.local, size: 16, color: SdColors.text2),
          ),
          const SizedBox(width: SdSpace.s2),
          Text('Waiting for connection…', style: context.sdText.caption),
        ],
      ),
    );
  }
}

/// This device and the other one, and the link between them.
class _LinkDiagram extends StatelessWidget {
  const _LinkDiagram({
    required this.self,
    required this.peer,
    required this.phones,
  });
  final ({String name, DeviceKind kind}) self;
  final Device? peer;
  final bool phones;

  @override
  Widget build(BuildContext context) {
    final t = context.sdText;
    final live = peer != null;
    Widget end(String name, DeviceKind kind, {bool dim = false}) => SizedBox(
      width: 110,
      child: Column(
        children: [
          DeviceGlyph(kind: kind, size: 64, live: live, dim: dim),
          const SizedBox(height: SdSpace.s2),
          Text(
            name,
            style: t.caption.copyWith(
              color: dim ? SdColors.text3 : SdColors.text,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
    return Semantics(
      label: live ? 'Connected to ${peer!.name}' : 'Not connected yet',
      child: ExcludeSemantics(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            end(self.name, self.kind),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 31),
                child: Column(
                  children: [
                    AnimatedContainer(
                      duration: SdMotion.page,
                      height: 2,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: live
                              ? [
                                  SdColors.red.withValues(alpha: 0.4),
                                  SdColors.red,
                                  SdColors.red.withValues(alpha: 0.4),
                                ]
                              : const [
                                  SdColors.hairline,
                                  SdColors.hairlineStrong,
                                  SdColors.hairline,
                                ],
                        ),
                      ),
                    ),
                    const SizedBox(height: SdSpace.s2),
                    Text(
                      live ? pathLabel(peer!.path) : 'Direct',
                      style: t.caption.copyWith(
                        color: live ? SdColors.redOnDark : SdColors.text3,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (peer != null)
              end(peer!.name, peer!.kind)
            else
              end(
                phones ? 'Other phone' : 'Other device',
                phones ? DeviceKind.phone : DeviceKind.unknown,
                dim: true,
              ),
          ],
        ),
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Connected',
              style: t.caption.copyWith(color: SdColors.redOnDark),
            ),
            const SizedBox(height: SdSpace.s1),
            Text(device.name, style: t.title),
            Text(pathLabel(device.path), style: t.caption),
            const SizedBox(height: SdSpace.s5),
            PrimaryAction(
              label: 'Send files to ${device.name}',
              icon: SdIcons.upload,
              expand: true,
              onPressed: () => startSend(context, ref, deviceId: device.id),
            ),
            const SizedBox(height: SdSpace.s2),
            GlassButton(
              label: 'Done',
              kind: GlassButtonKind.quiet,
              expand: true,
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ],
        ),
      ),
    );
  }
}
