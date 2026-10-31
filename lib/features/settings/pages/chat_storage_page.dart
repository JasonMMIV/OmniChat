import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/chat/storage/chat_storage.dart';
import '../../../core/services/chat/storage/chat_storage_info_service.dart';
import '../../../core/services/chat/storage/legacy_retirement_service.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tile_button.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../theme/app_font_weights.dart';
import '../../../utils/app_directories.dart';

/// Read-only chat storage diagnostics plus the guarded legacy cleanup flow
/// (§9.8). The page never talks to the database directly; every mutation goes
/// through [ChatService] or [LegacyRetirementService].
class ChatStoragePage extends StatefulWidget {
  const ChatStoragePage({super.key});

  @override
  State<ChatStoragePage> createState() => _ChatStoragePageState();
}

class _ChatStoragePageState extends State<ChatStoragePage> {
  ChatStorageInfo? _info;
  bool _loading = false;
  bool _busy = false;
  String? _importStage;
  String _appVersion = 'unknown';
  Directory? _directory;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<String> _readAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return '${info.version}+${info.buildNumber}';
    } catch (_) {
      return 'unknown';
    }
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final directory = await AppDirectories.getAppDataDirectory();
      final version = await _readAppVersion();
      final info = await ChatStorageInfoService.inspect(appVersion: version);
      if (!mounted) return;
      setState(() {
        _directory = directory;
        _appVersion = version;
        _info = info;
      });
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: e.toString(),
        type: NotificationType.error,
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  LegacyRetirementService? _retirementService() {
    final directory = _directory;
    if (directory == null) return null;
    return LegacyRetirementService(
      directory: directory,
      appVersion: _appVersion,
    );
  }

  Future<void> _run(Future<void> Function() action, {String? success}) async {
    if (!mounted || _busy) return;
    setState(() => _busy = true);
    try {
      await action();
      if (!mounted) return;
      if (success != null) {
        showAppSnackBar(
          context,
          message: success,
          type: NotificationType.success,
        );
      }
      await _load();
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: e.toString(),
        type: NotificationType.error,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportLegacy() async {
    final info = _info;
    final service = _retirementService();
    if (info == null || service == null || !info.retirement.hasLegacyFiles) {
      return;
    }
    final l10n = AppLocalizations.of(context)!;

    String? chosen;
    try {
      chosen = await FilePicker.platform.getDirectoryPath(
        dialogTitle: l10n.chatStorageExportLegacy,
      );
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: e.toString(),
        type: NotificationType.error,
      );
      return;
    }
    if (chosen == null || chosen.trim().isEmpty) return;

    final now = DateTime.now();
    final stamp =
        '${now.year}${_two(now.month)}${_two(now.day)}-'
        '${_two(now.hour)}${_two(now.minute)}${_two(now.second)}';
    var target = Directory(p.join(chosen, 'omnichat-legacy-chat-$stamp'));
    var suffix = 1;
    while (await target.exists()) {
      target = Directory(
        p.join(chosen, 'omnichat-legacy-chat-$stamp-${suffix++}'),
      );
    }

    final targetPath = target.path;
    await _run(
      () => service.exportToDirectory(target),
      success: l10n.chatStorageExportSuccess(targetPath),
    );
  }

  String _importStageLabel(String stage, AppLocalizations l10n) {
    switch (stage) {
      case 'merging':
        return l10n.chatStorageImportStageMerging;
      case 'verifying':
        return l10n.chatStorageImportStageVerifying;
      case 'validating':
      case 'importing-messages':
      case 'importing-conversations':
      case 'importing-tool-events':
      case 'importing-workspaces':
        return l10n.chatStorageImportStageReading;
      default:
        return l10n.chatStorageImportStagePreparing;
    }
  }

  Future<void> _importLegacy() async {
    final info = _info;
    if (info == null || _busy) return;
    final chatService = context.read<ChatService>();
    if (chatService.backend != ChatStorageBackend.sqlite ||
        !info.sqliteExists) {
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return AlertDialog(
          title: Text(l10n.chatStorageImportLegacyTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.chatStorageImportLegacyBody,
                style: TextStyle(
                  fontSize: 13.5,
                  height: 1.45,
                  color: cs.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.fromLTRB(11, 9, 11, 9),
                decoration: BoxDecoration(
                  color: cs.errorContainer.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  l10n.chatStorageImportLegacyWarning,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.4,
                    color: cs.onSurface,
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(l10n.homePageCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(l10n.chatStorageImportLegacyConfirm),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) return;
    final hadSentinel = info.legacyImportDisabled;

    setState(() {
      _busy = true;
      _importStage = l10n.chatStorageImportStagePreparing;
    });
    try {
      final report = await chatService.reimportLegacyHive(
        onProgress: (stage) {
          if (!mounted) return;
          setState(() => _importStage = _importStageLabel(stage, l10n));
        },
      );
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: l10n.chatStorageImportLegacyDone(
          report.importedConversations,
          report.importedMessages,
          report.conflicts,
        ),
        type: NotificationType.success,
      );
      if (hadSentinel && !report.sentinelRemoved) {
        showAppSnackBar(
          context,
          message: l10n.chatStorageImportLegacyLockRemains,
          type: NotificationType.warning,
        );
      }
      await _load();
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: e.toString(),
        type: NotificationType.error,
      );
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _importStage = null;
        });
      }
    }
  }

  Future<void> _deleteLegacy() async {
    final info = _info;
    final service = _retirementService();
    if (info == null || service == null) return;
    final retirement = info.retirement;
    final canDiscard = retirement.canDiscardNeverMigrated;
    final canDelete =
        retirement.canDelete ||
        ((retirement.canDeleteAfterExport || canDiscard) &&
            retirement.hasValidExport);
    if (!canDelete) return;

    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(l10n.chatStorageDeleteConfirm),
          content: Text(
            canDiscard
                ? '${l10n.chatStorageDeleteWarning}\n\n'
                      '${l10n.chatStorageDiscardNeverMigratedWarning}'
                : l10n.chatStorageDeleteWarning,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(l10n.homePageCancel),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(ctx).colorScheme.error,
              ),
              child: Text(l10n.homePageDelete),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;

    await _run(
      () => service.delete(
        confirmed: true,
        discardNeverMigrated: canDiscard,
        expectedArtifacts: retirement.artifacts,
      ),
      success: l10n.chatStorageCleanupDone,
    );
  }

  Future<void> _resumeCleanup() async {
    final service = _retirementService();
    if (service == null) return;
    final l10n = AppLocalizations.of(context)!;
    await _run(service.resume, success: l10n.chatStorageCleanupDone);
  }

  Future<void> _resetCompletedMarker() async {
    final info = _info;
    final service = _retirementService();
    if (info == null || service == null) return;
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(l10n.chatStorageResetMarker),
          content: Text(l10n.chatStorageResetMarkerWarning),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(l10n.homePageCancel),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(l10n.homePageConfirm),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;

    await _run(service.resetCompletedMarker);
  }

  Future<void> _optimize() async {
    final info = _info;
    if (info == null || !info.sqliteExists) return;
    // Capture the provider before the dialog: the page may be popped while
    // the dialog is open.
    final chatService = context.read<ChatService>();
    if (chatService.backend != ChatStorageBackend.sqlite) return;
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(l10n.chatStorageOptimize),
          content: Text(l10n.chatStorageOptimizeWarning),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(l10n.homePageCancel),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(l10n.homePageConfirm),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;

    await _run(
      chatService.optimizeChatDatabase,
      success: l10n.chatStorageOptimizeDone,
    );
  }

  static String _two(int value) => value.toString().padLeft(2, '0');

  String _fmtBytes(int bytes) {
    const kb = 1024;
    const mb = kb * 1024;
    const gb = mb * 1024;
    if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(2)} GB';
    if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(2)} MB';
    if (bytes >= kb) return '${(bytes / kb).toStringAsFixed(1)} KB';
    return '$bytes B';
  }

  String _fmtDate(DateTime? value) {
    if (value == null) return '-';
    final local = value.toLocal();
    return '${local.year}-${_two(local.month)}-${_two(local.day)} '
        '${_two(local.hour)}:${_two(local.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final info = _info;
    final sqliteActive =
        context.select<ChatService, ChatStorageBackend?>(
          (service) => service.backend,
        ) ==
        ChatStorageBackend.sqlite;
    final fallbackReason = context.select<ChatService, String?>((service) {
      final status = service.storageInitStatus;
      return status.isLegacyFallback
          ? (status.message ?? '').trim().isEmpty
                ? null
                : status.message
          : null;
    });

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: l10n.settingsPageBackButton,
          icon: const Icon(Lucide.ArrowLeft, size: 22),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(l10n.chatStoragePageTitle),
        actions: [
          IconButton(
            tooltip: l10n.storageSpaceRefreshTooltip,
            onPressed: _loading || _busy ? null : _load,
            icon: _loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Lucide.RefreshCw, size: 20),
          ),
        ],
      ),
      body: info == null
          ? Center(
              child: _loading
                  ? const CircularProgressIndicator()
                  : Text(
                      l10n.storageSpaceLoadFailed,
                      style: TextStyle(color: cs.onSurface.withOpacity(0.7)),
                    ),
            )
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                  children: [
                    if (fallbackReason != null) ...[
                      _buildFallbackCard(context, l10n, fallbackReason),
                      const SizedBox(height: 12),
                    ],
                    _buildSqliteCard(context, l10n, info),
                    const SizedBox(height: 12),
                    _buildLegacyCard(context, l10n, info, sqliteActive),
                    const SizedBox(height: 12),
                    _buildMaintenanceCard(context, l10n, info, sqliteActive),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildFallbackCard(
    BuildContext context,
    AppLocalizations l10n,
    String? reason,
  ) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
      decoration: BoxDecoration(
        color: cs.errorContainer.withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.error.withValues(alpha: 0.16)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Lucide.MessageCircleWarning, size: 18, color: cs.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.chatStorageFallbackTitle,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: AppFontWeights.emphasis,
                    color: cs.onSurface,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            l10n.chatStorageFallbackBody,
            style: TextStyle(
              fontSize: 12.5,
              height: 1.45,
              color: cs.onSurfaceVariant,
            ),
          ),
          if (reason != null) ...[
            const SizedBox(height: 8),
            SelectableText(
              reason,
              maxLines: 5,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.4,
                color: cs.onSurfaceVariant.withValues(alpha: 0.9),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSqliteCard(
    BuildContext context,
    AppLocalizations l10n,
    ChatStorageInfo info,
  ) {
    final cs = Theme.of(context).colorScheme;
    final source = [
      if (info.schemaVersion != null) 'v${info.schemaVersion}',
      if (info.source != null) info.source!,
      if (info.migrationState != null) info.migrationState!,
    ].join(' · ');

    return _SectionCard(
      title: l10n.chatStorageSqliteSection,
      children: [
        _InfoRow(
          label: l10n.chatStorageDatabaseSize,
          value: _fmtBytes(info.databaseBytes),
        ),
        _InfoRow(
          label: l10n.chatStorageWalSize,
          value: _fmtBytes(info.walBytes),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _CountChip(
              icon: Lucide.MessagesSquare,
              label: l10n.chatStorageConversationsCount(info.conversations),
            ),
            _CountChip(
              icon: Lucide.MessageCircle,
              label: l10n.chatStorageMessagesCount(info.messages),
            ),
            _CountChip(
              icon: Lucide.Wrench,
              label: l10n.chatStoragePartsCount(info.parts),
            ),
          ],
        ),
        if (source.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(
            source,
            style: TextStyle(
              fontSize: 11.5,
              color: cs.onSurface.withOpacity(0.55),
            ),
          ),
        ],
        if (info.legacyImportDisabled) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                Lucide.Shield,
                size: 14,
                color: cs.onSurface.withOpacity(0.6),
              ),
              const SizedBox(width: 6),
              Text(
                l10n.chatStorageLegacyImportDisabled,
                style: TextStyle(
                  fontSize: 12,
                  color: cs.onSurface.withOpacity(0.65),
                ),
              ),
            ],
          ),
        ],
        if (info.error != null) ...[
          const SizedBox(height: 10),
          Text(info.error!, style: TextStyle(fontSize: 12, color: cs.error)),
        ],
      ],
    );
  }

  Widget _buildLegacyCard(
    BuildContext context,
    AppLocalizations l10n,
    ChatStorageInfo info,
    bool sqliteActive,
  ) {
    final cs = Theme.of(context).colorScheme;
    final retirement = info.retirement;
    final hasFiles = retirement.hasLegacyFiles;
    final canDelete =
        retirement.canDelete ||
        ((retirement.canDeleteAfterExport ||
                retirement.canDiscardNeverMigrated) &&
            retirement.hasValidExport);

    final List<Widget> status = [];
    if (retirement.state == LegacyRetirementState.completed) {
      status.add(
        Text(
          l10n.chatStorageCleanupCompleted(_fmtDate(retirement.completedAtUtc)),
          style: TextStyle(
            fontSize: 12.5,
            color: cs.onSurface.withOpacity(0.7),
          ),
        ),
      );
    } else if (retirement.state == LegacyRetirementState.deleting) {
      status.add(
        Text(
          l10n.chatStorageCleanupInterrupted,
          style: TextStyle(fontSize: 12.5, color: cs.error),
        ),
      );
    } else if (hasFiles && retirement.blockReason != null) {
      status.add(
        Text(
          l10n.chatStorageBlocked(retirement.blockReason!),
          style: TextStyle(
            fontSize: 12.5,
            color: cs.onSurface.withOpacity(0.7),
          ),
        ),
      );
    }
    if (hasFiles && retirement.hasValidExport) {
      status.add(
        Row(
          children: [
            Icon(Lucide.CheckCircle, size: 14, color: cs.primary),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                l10n.chatStorageExportValid,
                style: TextStyle(fontSize: 12.5, color: cs.primary),
              ),
            ),
          ],
        ),
      );
    }

    return _SectionCard(
      title: l10n.chatStorageLegacySection,
      children: [
        if (!hasFiles)
          Text(
            l10n.chatStorageNoLegacyFiles,
            style: TextStyle(
              fontSize: 12.5,
              color: cs.onSurface.withOpacity(0.7),
            ),
          )
        else ...[
          _InfoRow(
            label: l10n.storageSpaceTotalLabel,
            value:
                '${_fmtBytes(retirement.totalBytes)} · '
                '${l10n.storageSpaceFilesCount(retirement.artifacts.length)}',
          ),
          const SizedBox(height: 8),
          for (final artifact in retirement.artifacts.take(6))
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  Icon(
                    Lucide.FileText,
                    size: 13,
                    color: cs.onSurface.withOpacity(0.5),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      artifact.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurface.withOpacity(0.7),
                      ),
                    ),
                  ),
                  Text(
                    _fmtBytes(artifact.sizeBytes),
                    style: TextStyle(
                      fontSize: 11.5,
                      color: cs.onSurface.withOpacity(0.55),
                    ),
                  ),
                ],
              ),
            ),
          if (retirement.artifacts.length > 6)
            Text(
              '…',
              style: TextStyle(
                fontSize: 12,
                color: cs.onSurface.withOpacity(0.55),
              ),
            ),
        ],
        if (_importStage != null) ...[
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              minHeight: 4,
              backgroundColor: cs.surfaceContainerHighest,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _importStage!,
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
        ],
        if (status.isNotEmpty) ...[const SizedBox(height: 8), ...status],
        if (hasFiles || retirement.canResume) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              if (hasFiles)
                IosTileButton(
                  label: l10n.chatStorageImportLegacy,
                  icon: Lucide.Import2,
                  backgroundColor: cs.primary,
                  enabled:
                      !_busy &&
                      sqliteActive &&
                      info.sqliteExists &&
                      retirement.state != LegacyRetirementState.deleting,
                  onTap: _importLegacy,
                ),
              if (hasFiles)
                IosTileButton(
                  label: l10n.chatStorageExportLegacy,
                  icon: Lucide.Download,
                  backgroundColor: cs.primary,
                  enabled: !_busy,
                  onTap: _exportLegacy,
                ),
              if (retirement.canResume)
                IosTileButton(
                  label: l10n.chatStorageResumeCleanup,
                  icon: Lucide.RotateCcw,
                  backgroundColor: cs.primary,
                  enabled: !_busy,
                  onTap: _resumeCleanup,
                ),
              if (retirement.state != LegacyRetirementState.completed)
                IosTileButton(
                  label: l10n.chatStorageDeleteLegacy,
                  icon: Lucide.Trash2,
                  backgroundColor: cs.error,
                  enabled: !_busy && canDelete,
                  onTap: _deleteLegacy,
                ),
              if (retirement.state == LegacyRetirementState.completed &&
                  hasFiles)
                IosTileButton(
                  label: l10n.chatStorageResetMarker,
                  icon: Lucide.RotateCcw,
                  backgroundColor: cs.primary,
                  enabled: !_busy,
                  onTap: _resetCompletedMarker,
                ),
            ],
          ),
          if (hasFiles &&
              !canDelete &&
              !retirement.hasValidExport &&
              (retirement.canDeleteAfterExport ||
                  retirement.canDiscardNeverMigrated) &&
              retirement.state != LegacyRetirementState.completed) ...[
            const SizedBox(height: 8),
            Text(
              l10n.chatStorageExportRequired,
              style: TextStyle(
                fontSize: 12,
                color: cs.onSurface.withOpacity(0.6),
              ),
            ),
          ],
        ],
      ],
    );
  }

  Widget _buildMaintenanceCard(
    BuildContext context,
    AppLocalizations l10n,
    ChatStorageInfo info,
    bool sqliteActive,
  ) {
    final cs = Theme.of(context).colorScheme;
    return _SectionCard(
      title: l10n.chatStorageMaintenanceSection,
      children: [
        Text(
          l10n.chatStorageOptimizeWarning,
          style: TextStyle(
            fontSize: 12.5,
            color: cs.onSurface.withOpacity(0.65),
          ),
        ),
        const SizedBox(height: 12),
        IosTileButton(
          label: l10n.chatStorageOptimize,
          icon: Lucide.Database,
          backgroundColor: cs.primary,
          enabled: !_busy && info.sqliteExists && sqliteActive,
          onTap: _optimize,
        ),
      ],
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: isDark ? Colors.white10 : Colors.white.withOpacity(0.96),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: cs.outlineVariant.withOpacity(isDark ? 0.08 : 0.06),
          width: 0.6,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: cs.onSurface.withOpacity(0.9),
            ),
          ),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                color: cs.onSurface.withOpacity(0.65),
              ),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: cs.onSurface.withOpacity(0.85),
            ),
          ),
        ],
      ),
    );
  }
}

class _CountChip extends StatelessWidget {
  const _CountChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: cs.onSurface.withOpacity(0.04),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: cs.onSurface.withOpacity(0.08)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12.5, color: cs.onSurface.withOpacity(0.6)),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              color: cs.onSurface.withOpacity(0.75),
            ),
          ),
        ],
      ),
    );
  }
}
