import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../tokens/colors.dart';
import '../tokens/radius.dart';
import '../tokens/typography.dart';

/// The app theme. Dark only for now (the environment is designed dark); tokens are split
/// so a light theme can be added without touching components.
ThemeData sdTheme({TargetPlatform? platform}) {
  final p = platform ?? defaultTargetPlatform;
  // Platform-correct system font family (SF on Apple, Roboto, Segoe UI, …).
  final base = Typography.material2021(platform: p).white;
  final text = SdTextStyles.from(base.bodyLarge!);

  final scheme = const ColorScheme.dark(
    surface: SdColors.ground,
    onSurface: SdColors.text,
    onSurfaceVariant: SdColors.text2,
    primary: SdColors.red,
    onPrimary: SdColors.onRed,
    secondary: SdColors.redOnDark,
    error: SdColors.redOnDark,
    outline: SdColors.hairlineStrong,
    outlineVariant: SdColors.hairline,
  );

  return ThemeData(
    useMaterial3: true,
    platform: p,
    brightness: Brightness.dark,
    colorScheme: scheme,
    // The environment paints the background; scaffolds stay transparent over it.
    scaffoldBackgroundColor: const Color(0x00000000),
    canvasColor: SdColors.ground,
    typography: Typography.material2021(platform: p),
    textTheme: base.copyWith(
      displaySmall: text.display,
      titleLarge: text.title,
      titleMedium: text.section,
      bodyLarge: text.body,
      bodyMedium: text.body,
      bodySmall: text.caption,
      labelLarge: text.label,
    ),
    extensions: [text],
    splashFactory: NoSplash.splashFactory,
    highlightColor: const Color(0x00000000),
    hoverColor: const Color(0x0DFFFFFF),
    focusColor: SdColors.redGlow,
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: SdColors.red,
      selectionColor: SdColors.red.withValues(alpha: 0.35),
      selectionHandleColor: SdColors.red,
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStateProperty.all(const Color(0x33FFFFFF)),
      radius: const Radius.circular(SdRadius.pill),
      thickness: WidgetStateProperty.all(6),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: const Color(0xFF26262B), borderRadius: SdRadius.all(SdRadius.chip)),
      textStyle: text.caption.copyWith(color: SdColors.text),
      waitDuration: const Duration(milliseconds: 500),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
      TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
      TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
    }),
  );
}
