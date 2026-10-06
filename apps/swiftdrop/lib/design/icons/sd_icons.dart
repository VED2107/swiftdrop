// Tabler's constants use snake_case names.
// ignore_for_file: constant_identifier_names
import 'package:flutter/widgets.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';

/// One icon family (Tabler: font glyphs, one stroke weight), outline for chrome, filled
/// for the selected tab. Nothing outside `lib/design/` imports an icon package directly.
/// Why Tabler: docs/FLUTTER_MIGRATION.md §14.1.
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
  static const upload = TablerIcons.upload;
  static const receive = TablerIcons.download;
  static const sendUp = TablerIcons.arrow_up;
  static const receiveDown = TablerIcons.arrow_down;
  static const phone = TablerIcons.device_mobile;
  static const check = TablerIcons.check;
  static const verified = TablerIcons.circle_check;
  static const qr = TablerIcons.qrcode;
  static const scan = TablerIcons.scan;
  static const local = TablerIcons.wifi;
  static const offline = TablerIcons.wifi_off;
  static const connect = TablerIcons.plug_connected;
  static const disconnected = TablerIcons.plug_connected_x;
  static const direct = TablerIcons.arrows_left_right;
  static const retry = TablerIcons.refresh;
  static const cancelled = TablerIcons.x;
  static const close = TablerIcons.x;
  static const failed = TablerIcons.alert_triangle;
  static const info = TablerIcons.info_circle;
  static const download = TablerIcons.download;
  static const tune = TablerIcons.adjustments_horizontal;
  static const pause = TablerIcons.player_pause;
  static const play = TablerIcons.player_play;
  static const rename = TablerIcons.pencil;
  static const forget = TablerIcons.trash;
  static const more = TablerIcons.dots;
  static const chevron = TablerIcons.chevron_right;
  static const back = TablerIcons.arrow_left;
  static const copy = TablerIcons.copy;
  static const folder = TablerIcons.folder;
  static const openFolder = TablerIcons.folder_open;
  static const drop = TablerIcons.drag_drop;
  static const keyboard = TablerIcons.keyboard;
  static const privacy = TablerIcons.lock;
  static const notifications = TablerIcons.bell;
  static const haptics = TablerIcons.device_mobile_vibration;
  static const visibility = TablerIcons.eye;

  static IconData device(DeviceKind kind) => switch (kind) {
        DeviceKind.phone => TablerIcons.device_mobile,
        DeviceKind.tablet => TablerIcons.device_tablet,
        DeviceKind.laptop => TablerIcons.device_laptop,
        DeviceKind.desktop => TablerIcons.device_desktop,
        DeviceKind.unknown => TablerIcons.device_unknown,
      };

  /// File-type glyph from a MIME type or name.
  static IconData file(String type, String name) {
    final n = name.toLowerCase();
    if (type.startsWith('image/')) return TablerIcons.photo;
    if (type.startsWith('video/')) return TablerIcons.movie;
    if (type.startsWith('audio/')) return TablerIcons.music;
    if (type == 'application/pdf' || n.endsWith('.pdf')) return TablerIcons.file_type_pdf;
    if (type.contains('zip') || type.contains('compressed') || type.contains('tar') || n.endsWith('.rar') || n.endsWith('.7z')) {
      return TablerIcons.file_zip;
    }
    if (type.startsWith('text/') || n.endsWith('.doc') || n.endsWith('.docx') || n.endsWith('.md')) return TablerIcons.file_text;
    return TablerIcons.file;
  }
}

/// Human names for platforms, used under device names.
String platformLabel(DevicePlatform p, DeviceKind kind) => switch (p) {
      DevicePlatform.ios => kind == DeviceKind.tablet ? 'iPad' : 'iPhone',
      DevicePlatform.android => kind == DeviceKind.tablet ? 'Android tablet' : 'Android',
      DevicePlatform.windows => 'Windows',
      DevicePlatform.macos => 'Mac',
      DevicePlatform.linux => 'Linux',
      DevicePlatform.web => 'Browser',
      DevicePlatform.unknown => switch (kind) {
          DeviceKind.phone => 'Phone',
          DeviceKind.tablet => 'Tablet',
          DeviceKind.laptop => 'Laptop',
          DeviceKind.desktop => 'Computer',
          DeviceKind.unknown => 'Device',
        },
    };
