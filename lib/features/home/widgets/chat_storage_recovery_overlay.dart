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

/// Observes only the recovery-relevant slice of [ChatService] so the chat
/// surface does not rebuild on ordinary message notifications.
class ChatStorageRecoveryHost extends StatelessWidget {
  const ChatStorageRecoveryHost({
    super.key,
    this.onRestoreBackup,
    this.onRebuildFromHive,
    this.onReset,
    this.onContinueLegacy,
  });

  final Future<bool> Function()? onRestoreBackup;
  final Future<void> Function()? onRebuildFromHive;
  final Future<void> Function()? onReset;
  final Future<void> Function()? onContinueLegacy;

  @override
  Widget build(BuildContext context) {
    final status = context.select<ChatService, ChatStorageInitStatus>(
      (service) => service.storageInitStatus,
    );
    final hasLegacyHive = context.select<ChatService, bool>(
      (service) => service.legacyHiveAvailable,
    );
    return ChatStorageRecoveryOverlay(
      status: status,
      hasLegacyHive: hasLegacyHive,
      onRestoreBackup: onRestoreBackup,
      onRebuildFromHive: onRebuildFromHive,
      onReset: onReset,
      onContinueLegacy: onContinueLegacy,
    );
  }
}

/// Blocking decision surface for `ChatStorageGateStage.needsRestoreOrReset`.
///
/// No destructive action runs before a confirmation, and a failed restore keeps
/// this surface visible instead of uncovering an empty database.
class ChatStorageRecoveryOverlay extends StatefulWidget {
  const ChatStorageRecoveryOverlay({
    super.key,
    required this.status,
    required this.hasLegacyHive,
    this.onRestoreBackup,
    this.onRebuildFromHive,
    this.onReset,
    this.onContinueLegacy,
  });

  final ChatStorageInitStatus status;
  final bool hasLegacyHive;
  final Future<bool> Function()? onRestoreBackup;
  final Future<void> Function()? onRebuildFromHive;
  final Future<void> Function()? onReset;
  final Future<void> Function()? onContinueLegacy;

  @override
  State<ChatStorageRecoveryOverlay> createState() =>
      _ChatStorageRecoveryOverlayState();
}

class _ChatStorageRecoveryOverlayState
    extends State<ChatStorageRecoveryOverlay> {
  String? _busyLabel;
  String? _error;

  bool get _busy => _busyLabel != null;

  Future<void> _run(String label, Future<bool> Function() action) async {
    if (_busy) return;
    final previousError = _error;
    setState(() {
      _busyLabel = label;
      _error = null;
    });
    try {
      final performed = await action();
      if (mounted) {
        // Cancelling a picker is not a successful recovery. Restore the old
        // diagnostic so an already-reset database cannot uncover itself.
        setState(() => _error = performed ? null : previousError);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _busyLabel = null);
      }
    }
  }

  Future<bool> _confirm({
    required String title,
    required String body,
    required String action,
    bool destructive = false,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(l10n.chatStorageRecoveryCancel),
            ),
            FilledButton(
              style: destructive
                  ? FilledButton.styleFrom(
                      backgroundColor: cs.error,
                      foregroundColor: cs.onError,
                    )
                  : null,
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(action),
            ),
          ],
        );
      },
    );
    return result == true;
  }

  Future<void> _restore() async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await _confirm(
      title: l10n.chatStorageRecoveryConfirmRestoreTitle,
      body: l10n.chatStorageRecoveryConfirmRestoreBody,
      action: l10n.chatStorageRecoveryRestore,
    );
    if (!ok || !mounted) return;
    await _run(l10n.chatStorageRecoveryRestoring, widget.onRestoreBackup!);
  }

  Future<void> _rebuild() async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await _confirm(
      title: l10n.chatStorageRecoveryConfirmRebuildTitle,
      body: l10n.chatStorageRecoveryConfirmRebuildBody,
      action: l10n.chatStorageRecoveryRebuild,
    );
    if (!ok || !mounted) return;
    await _run(l10n.chatStorageRecoveryRebuilding, () async {
      await widget.onRebuildFromHive!();
      return true;
    });
  }

  Future<void> _reset() async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await _confirm(
      title: l10n.chatStorageRecoveryConfirmResetTitle,
      body: l10n.chatStorageRecoveryConfirmResetBody,
      action: l10n.chatStorageRecoveryReset,
      destructive: true,
    );
    if (!ok || !mounted) return;
    await _run(l10n.chatStorageRecoveryResetting, () async {
      await widget.onReset!();
      return true;
    });
  }

  Future<void> _continueLegacy() async {
    final l10n = AppLocalizations.of(context)!;
    await _run(l10n.chatStorageRecoveryOpeningLegacy, () async {
      await widget.onContinueLegacy!();
      return true;
    });
  }

  Future<void> _copyDiagnostics() async {
    final l10n = AppLocalizations.of(context)!;
    final details =
        'phase=${widget.status.phase.name}\n'
        'message=${widget.status.message ?? '-'}\n'
        'legacyHive=${widget.hasLegacyHive}\n'
        'error=${_error ?? '-'}';
    await Clipboard.setData(ClipboardData(text: details));
    if (!mounted) return;
    showAppSnackBar(
      context,
      message: l10n.chatStorageStartupDiagnosticsCopied,
      type: NotificationType.success,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.status.isRestoreRequired && !_busy && _error == null) {
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
            color: cs.scrim.withValues(alpha: isDark ? 0.66 : 0.38),
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 24,
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
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
                      padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _Header(
                            l10n: l10n,
                            body: _error == null
                                ? l10n.chatStorageRecoveryBody
                                : l10n.chatStorageRecoveryFailedBody,
                            onCopyDiagnostics: _copyDiagnostics,
                          ),
                          const SizedBox(height: 16),
                          if ((widget.status.message ?? '').trim().isNotEmpty)
                            _DiagnosticBox(
                              message: widget.status.message!.trim(),
                            ),
                          if (_error != null) ...[
                            const SizedBox(height: 12),
                            _ErrorBox(
                              title: l10n.chatStorageRecoveryErrorTitle,
                              message: _error!,
                            ),
                          ],
                          if (_busy) ...[
                            const SizedBox(height: 16),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(999),
                              child: LinearProgressIndicator(
                                minHeight: 4,
                                backgroundColor: cs.surfaceContainerHighest,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  cs.primary,
                                ),
                              ),
                            ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                Icon(
                                  Lucide.Loader,
                                  size: 15,
                                  color: cs.primary,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    _busyLabel!,
                                    style: TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: AppFontWeights.medium,
                                      color: cs.onSurface,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                          const SizedBox(height: 18),
                          AbsorbPointer(
                            absorbing: _busy,
                            child: Opacity(
                              opacity: _busy ? 0.55 : 1,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  if (widget.onRestoreBackup != null)
                                    _ActionCard(
                                      icon: Lucide.Upload,
                                      title: l10n.chatStorageRecoveryRestore,
                                      hint: l10n.chatStorageRecoveryRestoreHint,
                                      recommended: true,
                                      onTap: _restore,
                                    ),
                                  if (widget.hasLegacyHive &&
                                      widget.onRebuildFromHive != null) ...[
                                    const SizedBox(height: 10),
                                    _ActionCard(
                                      icon: Lucide.History,
                                      title: l10n.chatStorageRecoveryRebuild,
                                      hint: l10n.chatStorageRecoveryRebuildHint,
                                      onTap: _rebuild,
                                    ),
                                  ],
                                  if (widget.onReset != null) ...[
                                    const SizedBox(height: 10),
                                    _ActionCard(
                                      icon: Lucide.Trash2,
                                      title: l10n.chatStorageRecoveryReset,
                                      hint: l10n.chatStorageRecoveryResetHint,
                                      destructive: true,
                                      onTap: _reset,
                                    ),
                                  ],
                                  if (widget.status.isRestoreRequired &&
                                      widget.onContinueLegacy != null) ...[
                                    const SizedBox(height: 8),
                                    TextButton.icon(
                                      onPressed: _continueLegacy,
                                      icon: const Icon(
                                        Lucide.HardDrive,
                                        size: 16,
                                      ),
                                      label: Text(
                                        l10n.chatStorageRecoveryContinueLegacy,
                                      ),
                                    ),
                                    Text(
                                      l10n.chatStorageRecoveryContinueLegacyHint,
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        fontSize: 11.5,
                                        height: 1.35,
                                        color: cs.onSurfaceVariant,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
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

class _Header extends StatelessWidget {
  const _Header({
    required this.l10n,
    required this.body,
    required this.onCopyDiagnostics,
  });

  final AppLocalizations l10n;
  final String body;
  final VoidCallback onCopyDiagnostics;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
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
                cs.error.withValues(alpha: 0.95),
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
                l10n.chatStorageRecoveryTitle,
                style: TextStyle(
                  fontSize: 18.5,
                  fontWeight: AppFontWeights.emphasis,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                body,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.4,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: l10n.chatStorageStartupCopyDiagnostics,
          onPressed: onCopyDiagnostics,
          icon: Icon(Lucide.Copy, size: 17, color: cs.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _DiagnosticBox extends StatelessWidget {
  const _DiagnosticBox({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.2)),
      ),
      child: SelectableText(
        message,
        maxLines: 5,
        style: TextStyle(
          fontSize: 11.5,
          height: 1.4,
          fontFamily: 'monospace',
          color: cs.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: cs.errorContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.error.withValues(alpha: 0.28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 12,
              fontWeight: AppFontWeights.emphasis,
              color: cs.error,
            ),
          ),
          const SizedBox(height: 4),
          SelectableText(
            message,
            maxLines: 6,
            style: TextStyle(
              fontSize: 11.5,
              height: 1.4,
              color: cs.onErrorContainer,
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({
    required this.icon,
    required this.title,
    required this.hint,
    required this.onTap,
    this.recommended = false,
    this.destructive = false,
  });

  final IconData icon;
  final String title;
  final String hint;
  final VoidCallback onTap;
  final bool recommended;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final accent = destructive ? cs.error : cs.primary;
    final background = recommended
        ? cs.primaryContainer.withValues(alpha: 0.4)
        : destructive
        ? cs.errorContainer.withValues(alpha: 0.28)
        : cs.surfaceContainerHighest.withValues(alpha: 0.5);

    return Material(
      color: background,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(13, 12, 13, 12),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 18, color: accent),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: AppFontWeights.emphasis,
                              color: destructive ? cs.error : cs.onSurface,
                            ),
                          ),
                        ),
                        if (recommended) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: cs.primary.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              '★',
                              style: TextStyle(fontSize: 10, color: cs.primary),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      hint,
                      style: TextStyle(
                        fontSize: 11.5,
                        height: 1.35,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Icon(
                Lucide.RefreshCw,
                size: 15,
                color: accent.withValues(alpha: 0.85),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
