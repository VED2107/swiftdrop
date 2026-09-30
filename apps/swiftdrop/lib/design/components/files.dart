import 'dart:io';

import 'package:flutter/material.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';

import '../icons/sd_icons.dart';
import '../materials/liquid_glass.dart';
import '../motion/appear.dart';
import '../tokens/colors.dart';
import '../tokens/materials.dart';
import '../tokens/radius.dart';
import '../tokens/spacing.dart';
import '../tokens/typography.dart';
import 'pressable.dart';

/// What the file views need to know about one picked item.
class FileItemView {
  const FileItemView({required this.name, required this.size, required this.type, this.path, this.folderFiles});
  final String name;
  final int size;
  final String type;

  /// Local path, for thumbnails.
  final String? path;

  /// Set for a folder: how many files it holds.
  final int? folderFiles;

  bool get isFolder => folderFiles != null;
  bool get isImage => !isFolder && type.startsWith('image/') && !type.contains('heic') && !type.contains('heif');
  bool get isVisual => type.startsWith('image/') || type.startsWith('video/');
}

/// A photo edge to edge (decoded at display size, off the UI thread), or a clean file
/// glyph on glass for everything else.
class FileThumbnail extends StatelessWidget {
  const FileThumbnail({super.key, required this.item, this.size = 96});
  final FileItemView item;
  final double size;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final radius = SdRadius.all(SdRadius.row);
    if (item.isImage && item.path != null) {
      return ClipRSuperellipse(
        borderRadius: radius,
        child: Image.file(
          File(item.path!),
          width: size,
          height: size,
          fit: BoxFit.cover,
          cacheWidth: (size * dpr).round(),
          filterQuality: FilterQuality.medium,
          errorBuilder: (_, _, _) => _glyph(context),
          frameBuilder: (context, child, frame, sync) => sync || frame != null ? Appear(child: child) : _glyph(context),
        ),
      );
    }
    return _glyph(context);
  }

  Widget _glyph(BuildContext context) => SizedBox.square(
        dimension: size,
        child: DecoratedBox(
          decoration: ShapeDecoration(
            gradient: const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0x1AFFFFFF), Color(0x0AFFFFFF)]),
            shape: RoundedSuperellipseBorder(borderRadius: SdRadius.all(SdRadius.row), side: const BorderSide(color: SdColors.hairline)),
          ),
          child: Icon(item.isFolder ? SdIcons.folder : SdIcons.file(item.type, item.name), size: size * 0.34, color: SdColors.text2),
        ),
      );
}

/// A file in a list: glyph, name, size (tabular), optional remove.
class FileGlassRow extends StatelessWidget {
  const FileGlassRow({super.key, required this.item, this.onRemove});
  final FileItemView item;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final t = context.sdText;
    final detail = item.isFolder ? '${plural(item.folderFiles!, 'file')} · ${formatBytes(item.size)}' : formatBytes(item.size);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: SdSpace.s3, vertical: SdSpace.s2),
      child: Row(children: [
        FileThumbnail(item: item, size: 44),
        const SizedBox(width: SdSpace.s3),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(item.name, style: t.body, maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(detail, style: t.numericSmall),
          ]),
        ),
        if (onRemove != null)
          Pressable(
            onPressed: onRemove,
            semanticLabel: 'Remove ${item.name}',
            focusRadius: SdRadius.pill,
            haptic: false,
            child: const SizedBox.square(dimension: SdSpace.touch, child: Icon(SdIcons.close, size: 18, color: SdColors.text3)),
          ),
      ]),
    );
  }
}

/// Photos and videos as an edge-to-edge grid; documents as rows; each group on its own
/// quiet glass. [onRemove] lets the person take something back out.
class FileCollection extends StatelessWidget {
  const FileCollection({super.key, required this.items, this.onRemove, this.columns = 4});
  final List<FileItemView> items;
  final void Function(int index)? onRemove;
  final int columns;

  @override
  Widget build(BuildContext context) {
    final t = context.sdText;
    final visual = [for (var i = 0; i < items.length; i++) if (items[i].isVisual) i];
    final other = [for (var i = 0; i < items.length; i++) if (!items[i].isVisual) i];
    final shownVisual = visual.take(columns * 3).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (visual.isNotEmpty) ...[
        Text('Photos and videos · ${formatCount(visual.length)}', style: t.caption),
        const SizedBox(height: SdSpace.s2),
        LiquidGlass(
          level: GlassLevel.regular,
          padding: const EdgeInsets.all(SdSpace.s2),
          child: LayoutBuilder(builder: (context, c) {
            final cell = (c.maxWidth - SdSpace.s2 * (columns - 1)) / columns;
            return Wrap(spacing: SdSpace.s2, runSpacing: SdSpace.s2, children: [
              for (final i in shownVisual)
                Stack(children: [
                  FileThumbnail(item: items[i], size: cell),
                  if (onRemove != null)
                    Positioned(
                      top: 4,
                      right: 4,
                      child: Pressable(
                        onPressed: () => onRemove!(i),
                        semanticLabel: 'Remove ${items[i].name}',
                        focusRadius: SdRadius.pill,
                        haptic: false,
                        child: Container(
                          width: 26,
                          height: 26,
                          decoration: const BoxDecoration(color: SdColors.scrim, shape: BoxShape.circle),
                          child: const Icon(SdIcons.close, size: 14, color: SdColors.text),
                        ),
                      ),
                    ),
                ]),
              if (visual.length > shownVisual.length)
                SizedBox.square(
                  dimension: cell,
                  child: Center(child: Text('+${formatCount(visual.length - shownVisual.length)}', style: t.numeric)),
                ),
            ]);
          }),
        ),
        const SizedBox(height: SdSpace.s5),
      ],
      if (other.isNotEmpty) ...[
        Text('Files · ${formatCount(other.length)}', style: t.caption),
        const SizedBox(height: SdSpace.s2),
        LiquidGlass(
          level: GlassLevel.regular,
          child: Column(children: [
            for (var k = 0; k < other.length && k < 60; k++) ...[
              if (k > 0) const Divider(height: 1, thickness: 1, indent: 68, color: SdColors.hairline),
              FileGlassRow(item: items[other[k]], onRemove: onRemove == null ? null : () => onRemove!(other[k])),
            ],
            if (other.length > 60)
              Padding(
                padding: const EdgeInsets.all(SdSpace.s3),
                child: Text('and ${formatCount(other.length - 60)} more', style: t.caption),
              ),
          ]),
        ),
      ],
    ]);
  }
}
