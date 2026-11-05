import 'package:flutter/material.dart';

import '../../../core/models/message_usage.dart';
import '../../../l10n/app_localizations.dart';
import '../../../utils/usd_format.dart';

Future<void> showMessageUsageSheet(BuildContext context, MessageUsage usage) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => MessageUsageSheet(usage: usage),
  );
}

class MessageUsageSheet extends StatelessWidget {
  const MessageUsageSheet({super.key, required this.usage});

  final MessageUsage usage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final l10n = AppLocalizations.of(context);
    final primary = _primaryCost(usage, l10n);
    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: cs.onSurface.withOpacity(0.18),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Icon(Icons.receipt_long_outlined, color: cs.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      l10n?.messageUsageTitle ?? 'Usage & cost',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).closeButtonTooltip,
                  ),
                ],
              ),
              if (primary != null) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: cs.primaryContainer.withOpacity(0.55),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          primary.label,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: cs.onPrimaryContainer.withOpacity(0.8),
                          ),
                        ),
                      ),
                      Text(
                        primary.value,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          color: cs.onPrimaryContainer,
                          fontWeight: FontWeight.w700,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 20),
              _SectionTitle(text: l10n?.messageUsageTokens ?? 'Tokens'),
              _UsageRow(
                label: l10n?.messageUsageInputTokens ?? 'Input',
                value: '${usage.inputTokens}',
              ),
              _UsageRow(
                label: l10n?.messageUsageOutputTokens ?? 'Output',
                value: '${usage.outputTokens}',
              ),
              if (usage.reasoningTokens > 0)
                _UsageRow(
                  label: l10n?.messageUsageReasoningTokens ?? 'Reasoning',
                  value: '${usage.reasoningTokens}',
                ),
              if (usage.cacheReadTokens > 0)
                _UsageRow(
                  label: l10n?.messageUsageCacheReadTokens ?? 'Cache read',
                  value: '${usage.cacheReadTokens}',
                ),
              if (usage.cacheWrite5mTokens > 0)
                _UsageRow(
                  label:
                      l10n?.messageUsageCacheWrite5mTokens ?? 'Cache write 5m',
                  value: '${usage.cacheWrite5mTokens}',
                ),
              if (usage.cacheWrite1hTokens > 0)
                _UsageRow(
                  label:
                      l10n?.messageUsageCacheWrite1hTokens ?? 'Cache write 1h',
                  value: '${usage.cacheWrite1hTokens}',
                ),
              const SizedBox(height: 18),
              _SectionTitle(text: l10n?.messageUsageCostSection ?? 'Cost'),
              if (usage.costUsd != null)
                _UsageRow(
                  label: l10n?.messageUsageCost ?? 'Charged',
                  value: formatUsd(usage.costUsd) ?? '',
                ),
              if (usage.listCostUsd != null)
                _UsageRow(
                  label: l10n?.messageUsageListCost ?? 'List price',
                  value: formatUsd(usage.listCostUsd) ?? '',
                ),
              if (usage.allowanceUsd != null)
                _UsageRow(
                  label: l10n?.messageUsageAllowance ?? 'Go allowance',
                  value: formatUsd(usage.allowanceUsd) ?? '',
                ),
              if (usage.billingSource != null)
                _UsageRow(
                  label: l10n?.messageUsageBillingSource ?? 'Billing',
                  value: usage.billingSource!,
                ),
              if (usage.estimated)
                _UsageRow(
                  label: l10n?.messageUsageEstimated ?? 'Estimated',
                  value: '✓',
                ),
            ],
          ),
        ),
      ),
    );
  }

  _PrimaryCost? _primaryCost(MessageUsage usage, AppLocalizations? l10n) {
    final source = (usage.billingSource ?? '').toLowerCase();
    if (source == 'free') {
      return _PrimaryCost(l10n?.messageUsageFree ?? 'Free', r'$0');
    }
    if (source == 'go' || source == 'go-plus') {
      final allowance = usage.allowanceUsd;
      if (allowance != null && allowance > 0) {
        return _PrimaryCost(
          l10n?.messageUsageAllowance ?? 'Go allowance',
          formatUsd(allowance) ?? '',
        );
      }
      final list = formatUsd(usage.listCostUsd ?? usage.costUsd);
      if (list != null) {
        return _PrimaryCost(l10n?.messageUsageListCost ?? 'List price', list);
      }
      return null;
    }
    final cost = formatUsd(usage.costUsd ?? usage.listCostUsd);
    if (cost == null) return null;
    return _PrimaryCost(
      usage.estimated
          ? (l10n?.messageUsageEstimated ?? 'Estimated')
          : (l10n?.messageUsageCost ?? 'Charged'),
      usage.estimated ? '≈$cost' : cost,
    );
  }
}

class _PrimaryCost {
  const _PrimaryCost(this.label, this.value);

  final String label;
  final String value;
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onSurface.withOpacity(0.58),
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

class _UsageRow extends StatelessWidget {
  const _UsageRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: cs.onSurface.withOpacity(0.72),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
