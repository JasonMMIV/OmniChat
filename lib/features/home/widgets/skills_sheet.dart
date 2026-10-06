// Mobile bottom-sheet skills menu (PLAN_AGENT_SKILLS.md §8.4) — the sheet
// counterpart of the desktop popover. Returns the picked skill.

import 'package:flutter/material.dart';

import '../../../core/models/skill.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';

Future<SkillDefinition?> showSkillsSheet(
  BuildContext context, {
  required List<SkillDefinition> skills,
}) {
  final cs = Theme.of(context).colorScheme;
  return showModalBottomSheet<SkillDefinition>(
    context: context,
    backgroundColor: cs.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) {
      final l10n = AppLocalizations.of(ctx)!;
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 12),
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: cs.onSurface.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                l10n.skillsTitle,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                itemCount: skills.length,
                itemBuilder: (ctx, index) {
                  final s = skills[index];
                  final scopeLabel = s.scope == SkillScope.project
                      ? l10n.skillScopeProject
                      : l10n.skillScopeGlobal;
                  return ListTile(
                    dense: true,
                    leading: Icon(
                      Lucide.WandSparkles,
                      size: 18,
                      color: cs.primary,
                    ),
                    title: Text(
                      s.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w500),
                    ),
                    subtitle: Text(
                      s.description,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurface.withOpacity(0.7),
                      ),
                    ),
                    trailing: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: cs.primary.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        scopeLabel,
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.primary.withOpacity(0.85),
                        ),
                      ),
                    ),
                    onTap: () => Navigator.of(ctx).pop(s),
                  );
                },
              ),
            ),
          ],
        ),
      );
    },
  );
}
