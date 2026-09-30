import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../design/design.dart';
import 'providers.dart';
import 'router.dart';

class SwiftDropApp extends ConsumerStatefulWidget {
  const SwiftDropApp({super.key, this.initialLocation = Routes.home});
  final String initialLocation;

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
      builder: (context, child) => _Environment(child: child ?? const SizedBox.shrink()),
    );
  }
}

/// Resolves appearance (settings + OS accessibility flags + transfer activity) once for
/// the whole tree, then paints the environment under every route.
class _Environment extends ConsumerWidget {
  const _Environment({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(appearanceProvider);
    final appearance = SdAppearance.resolve(
      context,
      glass: prefs.glass,
      motion: prefs.motion,
      transferActive: ref.watch(transferActiveProvider),
    );
    return SdAppearanceScope(
      appearance: appearance,
      // Sibling glass surfaces share one backdrop read.
      child: BackdropGroup(child: AmbientBackground(child: child)),
    );
  }
}
