import 'package:flutter/material.dart';

import '../../../core/models/chat_message.dart';
import '../../../l10n/app_localizations.dart';
import 'message_stats_text.dart';
import 'message_usage_sheet.dart';

/// The small stats line under a message bubble.
///
/// Extracted from [ChatMessageWidget] so the cost summary, tappable underline
/// and usage-sheet entry can be tested without a full chat page fixture.
class MessageStatsLine extends StatelessWidget {
  const MessageStatsLine({super.key, required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final summary = buildUsageSummary(
      message.usageMeta,
      freeLabel: l10n?.messageUsageFree ?? 'Free',
      allowanceLabel: l10n?.messageUsageAllowance ?? 'Go allowance',
      listPriceLabel: l10n?.messageUsageListCost ?? 'List price',
    );
    final text = buildMessageStatsText(message, usageSummary: summary);
    final usage = message.usageMeta;
    final style = TextStyle(
      fontSize: 11,
      color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
    );
    if (usage == null) return Text(text, style: style);
    return Tooltip(
      message: text,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => showMessageUsageSheet(context, usage),
        child: Text(
          text,
          style: style.copyWith(
            decoration: TextDecoration.underline,
            decorationColor: Theme.of(
              context,
            ).colorScheme.onSurface.withOpacity(0.25),
          ),
        ),
      ),
    );
  }
}
