import 'package:flutter/material.dart';

/// Horizontally scrollable container for block math.
///
/// The vertical padding must live INSIDE the scroll viewport: the viewport's
/// clip is what cuts tall glyph overpaint (fractions, integrals, roots). With
/// the padding outside, the viewport height equals the math layout height and
/// any ink that paints outside layout bounds is clipped. Moving the padding
/// inside grows the viewport by the padding, giving glyphs breathing room
/// while horizontal overflow remains scrollable (upstream kelivo `2df8153`,
/// plan §3.9).
///
/// This widget is shared on purpose: the legacy `LatexBlockScrollableMd` and
/// the future modern `blockLatexBuilder` both delegate here, so the clipping
/// fix and its pixel test survive the pipeline migration.
class ScrollableBlockMath extends StatelessWidget {
  const ScrollableBlockMath({super.key, required this.child, this.verticalPadding = 6});

  final Widget child;
  final double verticalPadding;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // A math block can be laid out inside an intrinsic/unbounded row (for
        // example a BlockMd wrapper in a test harness). A horizontal viewport
        // and minWidth: infinity are invalid there; render the child directly
        // instead of crashing the whole message.
        if (!constraints.hasBoundedWidth) {
          return Padding(
            padding: EdgeInsets.symmetric(vertical: verticalPadding),
            child: Center(child: SelectionContainer.disabled(child: child)),
          );
        }
        return SelectionContainer.disabled(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            primary: false,
            clipBehavior: Clip.hardEdge,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: constraints.maxWidth),
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: verticalPadding),
                child: Center(child: child),
              ),
            ),
          ),
        );
      },
    );
  }
}
