import 'package:flutter/material.dart';

import '../materials/liquid_glass.dart';
import '../tokens/colors.dart';
import '../tokens/materials.dart';
import '../tokens/radius.dart';
import '../tokens/typography.dart';
import 'pressable.dart';

/// Segmented choice on card glass; the selected segment lifts to a brighter fill.
/// Changes apply instantly (no animation): it's a setting, not a moment.
class SegmentedGlass<T> extends StatelessWidget {
  const SegmentedGlass({super.key, required this.label, required this.value, required this.options, required this.onChanged});

  final String label;
  final T value;
  final Map<T, String> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = context.sdText;
    return Semantics(
      container: true,
      label: label,
      child: LiquidGlass(
        level: GlassLevel.elevated,
        radius: SdRadius.row,
        padding: const EdgeInsets.all(3),
        child: Row(children: [
          for (final e in options.entries)
            Expanded(
              child: Semantics(
                selected: e.key == value,
                inMutuallyExclusiveGroup: true,
                child: Pressable(
                  onPressed: () => onChanged(e.key),
                  semanticLabel: e.value,
                  focusRadius: SdRadius.chip,
                  haptic: false,
                  child: ExcludeSemantics(
                    child: DecoratedBox(
                      decoration: ShapeDecoration(
                        color: e.key == value ? SdColors.hairlineStrong : const Color(0x00000000),
                        shape: RoundedSuperellipseBorder(borderRadius: SdRadius.all(SdRadius.chip + 2)),
                      ),
                      child: SizedBox(
                        height: 38,
                        child: Center(
                          child: Text(
                            e.value,
                            style: t.label.copyWith(color: e.key == value ? SdColors.text : SdColors.text2),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}
