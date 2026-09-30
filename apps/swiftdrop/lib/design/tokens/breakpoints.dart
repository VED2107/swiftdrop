import 'package:flutter/widgets.dart';

/// Layout classes by window width (logical px), never by device type. A phone in landscape
/// or a narrow desktop window gets the layout that fits, not the one its OS suggests.
enum SdLayout {
  phone,
  tablet,
  smallDesktop,
  desktop,
  largeDesktop;

  static SdLayout forWidth(double w) {
    if (w < 600) return phone;
    if (w < 905) return tablet;
    if (w < 1240) return smallDesktop;
    if (w < 1600) return desktop;
    return largeDesktop;
  }

  static SdLayout of(BuildContext context) => forWidth(MediaQuery.sizeOf(context).width);

  bool get isPhone => this == phone;
  bool get hasSidebar => index >= smallDesktop.index;
  bool get sidebarExpanded => index >= desktop.index;
}

abstract final class SdWindow {
  /// Smallest desktop window the layouts are designed for.
  static const minSize = Size(720, 540);
}
