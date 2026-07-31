import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../theme/design_tokens.dart';

class ChatSelectionDeleteBar extends StatelessWidget {
  const ChatSelectionDeleteBar({
    super.key,
    required this.hasMultiVersionSelection,
    required this.onDeleteCurrentVersions,
    required this.onDeleteAllVersions,
  });

  final bool hasMultiVersionSelection;
  final VoidCallback onDeleteCurrentVersions;
  final VoidCallback onDeleteAllVersions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final l10n = AppLocalizations.of(context)!;

    final background = isDark
        ? cs.surfaceContainerHighest.withValues(alpha: 0.88)
        : cs.surface.withValues(alpha: 0.94);
    final border = isDark
        ? cs.outlineVariant.withValues(alpha: 0.24)
        : cs.outlineVariant.withValues(alpha: 0.36);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: border, width: 0.8),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.28 : 0.08),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: SafeArea(
              top: false,
              bottom: false,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final compact = constraints.maxWidth < 380;
                  if (!hasMultiVersionSelection) {
                    return SizedBox(
                      width: double.infinity,
                      child: _DeleteButton(
                        icon: Lucide.Trash2,
                        label: l10n.chatMessageWidgetDeleteConfirmDelete,
                        color: cs.error,
                        onTap: onDeleteCurrentVersions,
                        dense: compact,
                      ),
                    );
                  }

                  return Row(
                    children: [
                      Expanded(
                        child: _DeleteButton(
                          icon: Lucide.Trash2,
                          label: l10n.chatMessageWidgetDeleteConfirmDelete,
                          color: cs.error,
                          onTap: onDeleteCurrentVersions,
                          dense: compact,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _DeleteButton(
                          icon: Lucide.Trash,
                          label: l10n.messageMoreSheetDeleteAllVersions,
                          color: cs.error,
                          onTap: onDeleteAllVersions,
                          dense: compact,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DeleteButton extends StatelessWidget {
  const _DeleteButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
    required this.dense,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = Color.alphaBlend(
      (isDark ? Colors.white : Colors.black).withOpacity(0.04),
      color.withOpacity(isDark ? 0.18 : 0.14),
    );

    return IosCardPress(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      baseColor: bg,
      pressedBlendStrength: isDark ? 0.20 : 0.16,
      pressedScale: 0.98,
      padding: dense
          ? const EdgeInsets.symmetric(horizontal: 8, vertical: 10)
          : const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: dense ? 16 : 18, color: color),
            SizedBox(width: dense ? 4 : 6),
            Text(
              label,
              style: TextStyle(
                fontSize: dense ? 13 : 14,
                fontWeight: FontWeight.w500,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
