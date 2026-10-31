import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/chat/storage/chat_storage_startup_status.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../theme/app_font_weights.dart';

/// Blocking startup surface for the one-time chat-storage cutover (§9.6).
///
/// Chat widgets must never call `getMessages`/`getToolEvents` before the gate
/// finishes. This overlay is the visual contract for that rule: it stays above
/// the home layout while the database is checked, migrated, validated, and
/// opened, then disappears. A failure keeps the surface visible with the
/// diagnostic and a retry action; nothing has been deleted at that point.
class ChatStorageStartupOverlay extends StatelessWidget {
  const ChatStorageStartupOverlay({super.key, this.onRetry});

  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) {
    final status = context.select<ChatService, ChatStorageInitStatus>(
      (service) => service.storageInitStatus,
    );
    final initializing = context.select<ChatService, bool>(
      (service) => service.initializing,
    );
    final showInitializing =
        initializing && status.phase == ChatStorageInitPhase.idle;
    if (!showInitializing && !status.isBusy && !status.hasFailed) {
      return const SizedBox.shrink();
    }

    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final panelColor = isDark ? const Color(0xFF171719) : cs.surface;

    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {},
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: ColoredBox(
            color: cs.scrim.withValues(alpha: isDark ? 0.62 : 0.34),
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: Material(
                    color: panelColor,
                    borderRadius: BorderRadius.circular(24),
                    clipBehavior: Clip.antiAlias,
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                          color: cs.outlineVariant.withValues(alpha: 0.24),
                        ),
                      ),
                      padding: const EdgeInsets.fromLTRB(24, 22, 24, 20),
                      child: status.hasFailed
                          ? _FailedState(
                              status: status,
                              l10n: l10n,
                              onRetry: onRetry,
                            )
                          : _ProgressState(status: status, l10n: l10n),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ProgressState extends StatelessWidget {
  const _ProgressState({required this.status, required this.l10n});

  final ChatStorageInitStatus status;
  final AppLocalizations l10n;

  String get _stageLabel {
    switch (status.stage) {
      case 'checking':
        return l10n.chatStorageStartupChecking;
      case 'backing-up':
      case 'copying-hive':
      case 'exporting-json':
      case 'verifying-backup':
        return l10n.chatStorageStartupBackingUp;
      case 'opening-hive':
        return l10n.chatStorageStartupOpeningHive;
      case 'importing-tool-events':
        return l10n.chatStorageStartupImportingToolEvents;
      case 'importing-workspaces':
        return l10n.chatStorageStartupImportingWorkspaces;
      case 'importing-messages':
      case 'importing-conversations':
      case 'migrating':
        return l10n.chatStorageStartupImportingMessages;
      case 'validating':
        return l10n.chatStorageStartupValidating;
      case 'opening':
        return l10n.chatStorageStartupOpening;
      default:
        return status.phase == ChatStorageInitPhase.validating
            ? l10n.chatStorageStartupValidating
            : l10n.chatStorageStartupChecking;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    cs.primary.withValues(alpha: 0.95),
                    cs.tertiary.withValues(alpha: 0.85),
                  ],
                ),
              ),
              child: const Icon(Lucide.Database, size: 21, color: Colors.white),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.chatStorageStartupTitle,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: AppFontWeights.emphasis,
                      color: cs.onSurface,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    l10n.chatStorageStartupSubtitle,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.35,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            minHeight: 5,
            backgroundColor: cs.surfaceContainerHighest.withValues(alpha: 0.7),
            valueColor: AlwaysStoppedAnimation<Color>(cs.primary),
          ),
        ),
        const SizedBox(height: 13),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          layoutBuilder: (current, previous) => Stack(
            alignment: Alignment.centerLeft,
            children: [...previous, if (current != null) current],
          ),
          child: Row(
            key: ValueKey(_stageLabel),
            children: [
              Icon(Lucide.Loader, size: 15, color: cs.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _stageLabel,
                  style: TextStyle(
                    fontSize: 13.5,
                    height: 1.35,
                    fontWeight: AppFontWeights.medium,
                    color: cs.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (status.hasCounts) ...[
          const SizedBox(height: 14),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              _Pill(
                icon: Lucide.MessageCircle,
                label: l10n.chatStorageStartupCounts(
                  status.conversations ?? 0,
                  status.messages ?? 0,
                ),
              ),
              if ((status.quarantined ?? 0) > 0)
                _Pill(
                  icon: Lucide.MessageCircleWarning,
                  label: l10n.chatStorageStartupQuarantine(
                    status.quarantined ?? 0,
                  ),
                  warning: true,
                ),
            ],
          ),
        ],
        const SizedBox(height: 18),
        Text(
          l10n.chatStorageStartupInitialHint,
          style: TextStyle(
            fontSize: 12,
            height: 1.4,
            color: cs.onSurfaceVariant.withValues(alpha: 0.9),
          ),
        ),
      ],
    );
  }
}

class _FailedState extends StatelessWidget {
  const _FailedState({
    required this.status,
    required this.l10n,
    required this.onRetry,
  });

  final ChatStorageInitStatus status;
  final AppLocalizations l10n;
  final Future<void> Function()? onRetry;

  Future<void> _retry() async {
    // `init()` rethrows when the Hive fallback also fails. The service already
    // recorded that failure in the status, so keep the retry future settled and
    // never leak an unhandled zone error from a button tap.
    try {
      await onRetry?.call();
    } catch (_) {}
  }

  Future<void> _copyDiagnostics(BuildContext context) async {
    final details =
        '${status.message ?? 'Chat storage initialization failed.'}\n'
        'phase=${status.phase.name}\n'
        'stage=${status.stage ?? '-'}';
    await Clipboard.setData(ClipboardData(text: details));
    if (!context.mounted) return;
    showAppSnackBar(
      context,
      message: l10n.chatStorageStartupDiagnosticsCopied,
      type: NotificationType.success,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: cs.errorContainer.withValues(alpha: 0.7),
          ),
          child: Icon(Lucide.MessageCircleWarning, size: 21, color: cs.error),
        ),
        const SizedBox(height: 16),
        Text(
          l10n.chatStorageStartupFailedTitle,
          style: TextStyle(
            fontSize: 19,
            fontWeight: AppFontWeights.emphasis,
            color: cs.onSurface,
          ),
        ),
        const SizedBox(height: 7),
        Text(
          l10n.chatStorageStartupFailedBody,
          style: TextStyle(
            fontSize: 13,
            height: 1.45,
            color: cs.onSurfaceVariant,
          ),
        ),
        if ((status.message ?? '').trim().isNotEmpty) ...[
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: cs.outlineVariant.withValues(alpha: 0.2),
              ),
            ),
            child: SelectableText(
              status.message!.trim(),
              maxLines: 6,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.4,
                fontFamily: 'monospace',
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
        ],
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _copyDiagnostics(context),
                icon: const Icon(Lucide.Copy, size: 16),
                label: Text(l10n.chatStorageStartupCopyDiagnostics),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.icon(
                onPressed: status.canRetry && onRetry != null
                    ? () {
                        unawaited(_retry());
                      }
                    : null,
                icon: const Icon(Lucide.RefreshCw, size: 16),
                label: Text(l10n.chatStorageStartupRetry),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.label, this.warning = false});

  final IconData icon;
  final String label;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = warning ? cs.error : cs.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: (warning ? cs.errorContainer : cs.surfaceContainerHighest)
            .withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: AppFontWeights.medium,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
