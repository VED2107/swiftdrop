import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../design/design.dart';
import 'providers.dart';
import 'router.dart';
import 'shell.dart';

class SwiftDropApp extends ConsumerStatefulWidget {
  const SwiftDropApp({super.key, this.initialLocation = Routes.home, this.engineError});
  final String initialLocation;

  /// Set when the transfer engine couldn't start (shown on Home, in plain words).
  final Object? engineError;

  @override
  ConsumerState<SwiftDropApp> createState() => _SwiftDropAppState();
}

class _SwiftDropAppState extends ConsumerState<SwiftDropApp> {
  late final GoRouter _router = buildRouter(initialLocation: widget.initialLocation);

  @override
  void dispose() {
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'SwiftDrop',
      debugShowCheckedModeBanner: false,
      theme: sdTheme(),
      routerConfig: _router,
      builder: (context, child) => _Environment(engineError: widget.engineError, child: child ?? const SizedBox.shrink()),
    );
  }
}

/// Resolves appearance once for the whole tree (settings + OS accessibility flags +
/// product state), then paints the environment under every route.
class _Environment extends ConsumerWidget {
  const _Environment({required this.child, this.engineError});
  final Widget child;
  final Object? engineError;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(settingsProvider);
    final env = ref.watch(environmentProvider);
    final appearance = SdAppearance.resolve(
      context,
      glass: prefs.glass,
      motion: prefs.motion,
      contrast: prefs.contrast,
      environment: env.state,
      energy: env.energy,
      completions: ref.watch(completionsProvider),
    );
    return EngineStatus(
      error: engineError,
      child: SdAppearanceScope(
        appearance: appearance,
        // Sibling glass surfaces share one backdrop read.
        child: BackdropGroup(child: AmbientBackground(child: GlobalLayer(child: child))),
      ),
    );
  }
}

/// Makes the engine's startup error available to screens.
class EngineStatus extends InheritedWidget {
  const EngineStatus({super.key, required this.error, required super.child});
  final Object? error;

  static Object? of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<EngineStatus>()?.error;

  @override
  bool updateShouldNotify(EngineStatus old) => old.error != error;
}
