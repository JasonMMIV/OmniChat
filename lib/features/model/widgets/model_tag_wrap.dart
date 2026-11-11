// Model tag chips shared by the model picker and the provider detail page.
//
// Keeping one implementation matters for the context-window chip: both
// surfaces resolve token limits through `ModelInfo.contextWindow`, and the
// two copies used to drift apart.
library;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../core/providers/model_provider.dart';
import '../../../core/utils/token_format.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import 'modality_badge.dart';

/// Type / modality / ability / context-window chips for one model row.
Widget modelTagWrap(BuildContext context, ModelInfo m) {
  final cs = Theme.of(context).colorScheme;
  final l10n = AppLocalizations.of(context)!;
  final isDark = Theme.of(context).brightness == Brightness.dark;
  List<Widget> chips = [];
  // type tag
  chips.add(
    Container(
      decoration: BoxDecoration(
        color: isDark
            ? cs.primary.withOpacity(0.25)
            : cs.primary.withOpacity(0.15),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: cs.primary.withOpacity(0.2), width: 0.5),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      child: Text(
        m.type == ModelType.chat
            ? l10n.modelSelectSheetChatType
            : l10n.modelSelectSheetEmbeddingType,
        style: TextStyle(
          fontSize: 11,
          color: isDark ? cs.primary : cs.primary.withOpacity(0.9),
          fontWeight: FontWeight.w500,
        ),
      ),
    ),
  );
  // modality tag capsule with icons
  chips.add(
    Container(
      decoration: BoxDecoration(
        color: isDark
            ? cs.tertiary.withOpacity(0.25)
            : cs.tertiary.withOpacity(0.15),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: cs.tertiary.withOpacity(0.2), width: 0.5),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final mod in m.input)
            Padding(
              padding: const EdgeInsets.only(right: 2),
              child: Icon(
                modalityIcon(mod),
                size: 12,
                color: isDark ? cs.tertiary : cs.tertiary.withOpacity(0.9),
              ),
            ),
          Icon(
            Lucide.ChevronRight,
            size: 12,
            color: isDark ? cs.tertiary : cs.tertiary.withOpacity(0.9),
          ),
          for (final mod in m.output)
            Padding(
              padding: const EdgeInsets.only(left: 2),
              child: Icon(
                modalityIcon(mod),
                size: 12,
                color: isDark ? cs.tertiary : cs.tertiary.withOpacity(0.9),
              ),
            ),
        ],
      ),
    ),
  );
  // abilities capsules (icon-only)
  for (final ab in m.abilities) {
    if (ab == ModelAbility.tool) {
      chips.add(
        Container(
          decoration: BoxDecoration(
            color: isDark
                ? cs.primary.withOpacity(0.25)
                : cs.primary.withOpacity(0.15),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: cs.primary.withOpacity(0.2), width: 0.5),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          child: Icon(
            Lucide.Hammer,
            size: 12,
            color: isDark ? cs.primary : cs.primary.withOpacity(0.9),
          ),
        ),
      );
    } else if (ab == ModelAbility.reasoning) {
      chips.add(
        Container(
          decoration: BoxDecoration(
            color: isDark
                ? cs.secondary.withOpacity(0.3)
                : cs.secondary.withOpacity(0.18),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: cs.secondary.withOpacity(0.25),
              width: 0.5,
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          child: SvgPicture.asset(
            'assets/icons/deepthink.svg',
            width: 12,
            height: 12,
            colorFilter: ColorFilter.mode(
              isDark ? cs.secondary : cs.secondary.withOpacity(0.9),
              BlendMode.srcIn,
            ),
          ),
        ),
      );
    }
  }
  // Context-window chip (Kelivo ModelTagWrap parity): plain neutral pill,
  // only when the model has a declared window.
  final contextWindow = m.contextWindow;
  if (contextWindow != null) {
    chips.add(
      Container(
        decoration: BoxDecoration(
          color: isDark
              ? cs.onSurface.withOpacity(0.12)
              : cs.onSurface.withOpacity(0.08),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: cs.onSurface.withOpacity(0.16), width: 0.5),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Text(
          formatTokenCount(contextWindow),
          style: TextStyle(
            fontSize: 11,
            color: cs.onSurface.withOpacity(isDark ? 0.86 : 0.78),
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
  return Wrap(
    spacing: 6,
    runSpacing: 6,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: chips,
  );
}
