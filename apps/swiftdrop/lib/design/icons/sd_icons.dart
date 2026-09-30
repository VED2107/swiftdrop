// Tabler's constants use snake_case names.
// ignore_for_file: constant_identifier_names
import 'package:flutter/widgets.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';

/// One icon family (Tabler: font glyphs, one stroke weight), outline for chrome, filled
/// for the selected tab. Nothing outside `lib/design/` imports an icon package directly.
/// Why Tabler: see docs/FLUTTER_MIGRATION.md, "Phase 2 dependency decisions".
abstract final class SdIcons {
  static const home = TablerIcons.home;
  static const homeSelected = TablerIcons.home_filled;
  static const transfers = TablerIcons.arrows_transfer_up_down;
  static const transfersSelected = TablerIcons.arrows_transfer_up_down;
  static const devices = TablerIcons.devices;
  static const devicesSelected = TablerIcons.devices;
  static const settings = TablerIcons.settings;
  static const settingsSelected = TablerIcons.settings_filled;

  static const send = TablerIcons.plus;
  static const receive = TablerIcons.download;
  static const check = TablerIcons.check;
  static const qr = TablerIcons.qrcode;
  static const local = TablerIcons.wifi;
  static const offline = TablerIcons.wifi_off;
  static const retry = TablerIcons.refresh;
  static const cancelled = TablerIcons.x;
  static const failed = TablerIcons.alert_circle;
  static const tune = TablerIcons.adjustments_horizontal;

  static IconData device(DeviceKind kind) => switch (kind) {
        DeviceKind.phone => TablerIcons.device_mobile,
        DeviceKind.tablet => TablerIcons.device_tablet,
        DeviceKind.laptop => TablerIcons.device_laptop,
        DeviceKind.desktop => TablerIcons.device_desktop,
        DeviceKind.unknown => TablerIcons.device_unknown,
      };
}

/// Human names for platforms, used under device names.
String platformLabel(DevicePlatform p, DeviceKind kind) => switch (p) {
      DevicePlatform.ios => kind == DeviceKind.tablet ? 'iPad' : 'iPhone',
      DevicePlatform.android => kind == DeviceKind.tablet ? 'Android tablet' : 'Android',
      DevicePlatform.windows => 'Windows',
      DevicePlatform.macos => 'Mac',
      DevicePlatform.linux => 'Linux',
      DevicePlatform.web => 'Browser',
      DevicePlatform.unknown => 'Device',
    };
