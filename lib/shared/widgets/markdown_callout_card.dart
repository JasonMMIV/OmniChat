import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:gpt_markdown/custom_widgets/markdown_config.dart' show GptMarkdownConfig;

import '../../icons/lucide_adapter.dart';
import '../../l10n/app_localizations.dart';
import '../markdown/markdown_alert.dart';
import '../markdown/markdown_alert_style.dart';

/// Shared card for GitHub alerts and `:::note`-style directives.
///
/// The title is treated as chrome: it is excluded from selection so
/// SelectCopy / manual selection cannot mix a synthetic label into the
/// message body. The body keeps the normal markdown pipeline, including
/// lists, links, code and math.
class MarkdownCalloutCard extends StatelessWidget {
  const MarkdownCalloutCard({super.key, required this.kind, required this.body, required this.config, this.title});

  final MarkdownAlertKind kind;
  final String? title;
  final String body;
  final GptMarkdownConfig config;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final l10n = AppLocalizations.of(context);
    final colors = markdownAlertColors(kind, cs);
    final icon = switch (kind) {
      MarkdownAlertKind.note => Lucide.Info,
      MarkdownAlertKind.tip => Lucide.Lightbulb,
      MarkdownAlertKind.important => Lucide.BadgeInfo,
      MarkdownAlertKind.warning => Lucide.TriangleAlert,
      MarkdownAlertKind.caution => Lucide.OctagonAlert,
    };
    final fallbackTitle = switch (kind) {
      MarkdownAlertKind.note => l10n?.markdownAlertNoteTitle ?? 'Note',
      MarkdownAlertKind.tip => l10n?.markdownAlertTipTitle ?? 'Tip',
      MarkdownAlertKind.important => l10n?.markdownAlertImportantTitle ?? 'Important',
      MarkdownAlertKind.warning => l10n?.markdownAlertWarningTitle ?? 'Warning',
      MarkdownAlertKind.caution => l10n?.markdownAlertCautionTitle ?? 'Caution',
    };
    final resolvedTitle = (title == null || title!.trim().isEmpty) ? fallbackTitle : title!.trim();
    final baseStyle = config.style ?? Theme.of(context).textTheme.bodyMedium ?? const TextStyle();
    final bodyWidget = body.trim().isEmpty
        ? null
        : config.getRich(TextSpan(children: MarkdownComponent.generate(context, body, config, true)));

    return Directionality(
      textDirection: config.textDirection,
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color: colors.background(isDark: isDark),
          borderRadius: BorderRadius.circular(12),
          border: Border(left: BorderSide(color: colors.accent, width: 3)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectionContainer.disabled(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 15, color: colors.accent),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        resolvedTitle,
                        style: baseStyle.copyWith(
                          color: colors.title,
                          fontWeight: FontWeight.w700,
                          fontSize: (baseStyle.fontSize ?? 15.5) * 0.94,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (bodyWidget != null) ...[const SizedBox(height: 6), bodyWidget],
            ],
          ),
        ),
      ),
    );
  }
}
