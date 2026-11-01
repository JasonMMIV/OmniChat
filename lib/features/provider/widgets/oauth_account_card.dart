// Modified for OmniChat on 2026-11-01. See THIRD_PARTY_NOTICES.md.
//
// Account card for the OAuth detail page: identity, plan, and usage windows.
// Usage lives only on this page (plan Q4) — never in the sidebar or the model
// picker.

import 'package:flutter/material.dart';

import '../../../core/models/provider_oauth.dart';
import '../../../l10n/app_localizations.dart';

class OAuthAccountCard extends StatelessWidget {
  const OAuthAccountCard({
    super.key,
    required this.provider,
    required this.credentials,
    this.usage,
    this.usageLoading = false,
    this.loginRequired = false,
    this.details = true,
  });

  final OAuthProvider provider;
  final ProviderOAuthCredentials? credentials;
  final OAuthUsage? usage;
  final bool usageLoading;
  final bool loginRequired;
  final bool details;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final creds = credentials;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final windows = usage?.windows ?? const <OAuthUsageWindow>[];
    final shown = details ? windows : windows.take(2).toList();
    // Never render the previous session's usage after sign-out / a failed
    // re-auth; the card must match the badge above it.
    final showUsage = creds != null && !loginRequired;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? Colors.white10 : const Color(0xFFF7F7F9),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outlineVariant.withOpacity(0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: cs.primary.withOpacity(0.15),
                child: Icon(
                  switch (provider) {
                    OAuthProvider.claude => Icons.auto_awesome,
                    OAuthProvider.grok => Icons.bolt,
                    OAuthProvider.kimi => Icons.memory,
                    OAuthProvider.chatgpt => Icons.account_circle_outlined,
                  },
                  size: 20,
                  color: cs.primary,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      creds?.email?.isNotEmpty == true
                          ? creds!.email!
                          : (creds?.accountId?.isNotEmpty == true
                                ? creds!.accountId!
                                : l10n.oauthSignedIn),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _subtitle(l10n),
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurface.withOpacity(0.65),
                      ),
                    ),
                  ],
                ),
              ),
              if (creds != null && !loginRequired)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.green.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    l10n.oauthConnected,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Colors.green,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                )
              else
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.orange.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    loginRequired
                        ? l10n.oauthLoginRequired
                        : l10n.oauthNotSignedIn,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Colors.orange,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
          if (showUsage && usageLoading) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(minHeight: 2),
          ] else if (showUsage && shown.isNotEmpty) ...[
            const SizedBox(height: 14),
            for (final window in shown) ...[
              _UsageBar(window: window, details: details),
              const SizedBox(height: 10),
            ],
          ],
          if (showUsage && details && usage?.extraSpentUsd != null) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                Text(
                  l10n.oauthUsageExtra,
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurface.withOpacity(0.7),
                  ),
                ),
                const Spacer(),
                Text(
                  '\$${usage!.extraSpentUsd!.toStringAsFixed(2)}',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  String _subtitle(AppLocalizations l10n) {
    final plan = credentials?.planType?.trim();
    if (plan != null && plan.isNotEmpty) {
      return '${l10n.oauthPlanLabel}: $plan';
    }
    return switch (provider) {
      OAuthProvider.claude => l10n.oauthClaudeAccount,
      OAuthProvider.grok => l10n.oauthGrokAccount,
      OAuthProvider.kimi => l10n.oauthKimiAccount,
      OAuthProvider.chatgpt => l10n.oauthChatGptAccount,
    };
  }
}

class _UsageBar extends StatelessWidget {
  const _UsageBar({required this.window, required this.details});

  final OAuthUsageWindow window;
  final bool details;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final percent = window.percent.clamp(0, 100).toDouble();
    final warn = window.isWarning;
    final color = warn ? Colors.red : cs.primary;
    final reset = window.resetsAt;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                usageWindowLabel(l10n, window),
                style: const TextStyle(fontSize: 12),
              ),
            ),
            Text(
              '${window.percent.round()}%',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: warn ? Colors.red : cs.onSurface,
              ),
            ),
          ],
        ),
        const SizedBox(height: 5),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: percent / 100,
            minHeight: 6,
            backgroundColor: cs.outlineVariant.withOpacity(0.25),
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
        ),
        if (details && reset != null) ...[
          const SizedBox(height: 4),
          Text(
            l10n.oauthUsageResets(_formatReset(reset)),
            style: TextStyle(
              fontSize: 11,
              color: cs.onSurface.withOpacity(0.55),
            ),
          ),
        ],
      ],
    );
  }

  String _formatReset(DateTime utc) {
    final local = utc.toLocal();
    final now = DateTime.now();
    final sameDay =
        local.year == now.year &&
        local.month == now.month &&
        local.day == now.day;
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    if (sameDay) return '$hh:$mm';
    return '${local.month}/${local.day} $hh:$mm';
  }
}

/// Localized title for a usage window. Unknown provider kinds fall back to the
/// provider-supplied label or the raw key so a new backend shape still renders.
String usageWindowLabel(AppLocalizations l10n, OAuthUsageWindow window) {
  final label = window.label?.trim();
  switch (window.kind) {
    case 'session':
    case 'five_hour':
      return l10n.oauthUsageSession;
    case 'monthly':
      return l10n.oauthUsageMonthly;
    case 'usage':
      return l10n.oauthUsageWindow;
    case 'weekly':
    case 'seven_day':
    case 'weekly_all':
      return l10n.oauthUsageWeekly;
    case 'weekly_scoped':
      if (label != null && label.isNotEmpty) return label;
      return l10n.oauthUsageScoped;
    case 'extra':
      return l10n.oauthUsageExtra;
    default:
      if (label != null && label.isNotEmpty) return label;
      return window.kind;
  }
}
