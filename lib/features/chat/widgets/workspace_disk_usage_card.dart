import 'package:flutter/material.dart';

import '../../../core/services/file/workspace_disk_usage.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';

/// Compact "how much is in this workspace" card for the Workspace Tools page.
class WorkspaceDiskUsageCard extends StatefulWidget {
  const WorkspaceDiskUsageCard({
    super.key,
    required this.workspacePath,
    this.loadUsage,
  });

  final String? workspacePath;

  /// Test seam; production uses [WorkspaceDiskUsageService.measure].
  final Future<WorkspaceDiskUsage?> Function(String workspacePath)? loadUsage;

  @override
  State<WorkspaceDiskUsageCard> createState() => _WorkspaceDiskUsageCardState();
}

class _WorkspaceDiskUsageCardState extends State<WorkspaceDiskUsageCard> {
  Future<WorkspaceDiskUsage?>? _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(WorkspaceDiskUsageCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.workspacePath != widget.workspacePath) {
      setState(_load);
    }
  }

  void _load() {
    final path = widget.workspacePath?.trim();
    if (path == null || path.isEmpty) {
      _future = null;
      return;
    }
    final loader = widget.loadUsage;
    _future = loader != null
        ? loader(path)
        : WorkspaceDiskUsageService.measure(path);
  }

  @override
  Widget build(BuildContext context) {
    final path = widget.workspacePath?.trim();
    if (path == null || path.isEmpty) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.38),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              Lucide.HardDrive,
              size: 20,
              color: cs.onSurface.withValues(alpha: 0.72),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: FutureBuilder<WorkspaceDiskUsage?>(
              future: _future,
              builder: (context, snapshot) {
                final usage = snapshot.data;
                final loading =
                    snapshot.connectionState == ConnectionState.waiting;
                final summary = loading
                    ? l10n.workspaceDiskUsageLoading
                    : usage == null
                    ? l10n.workspaceDiskUsageError
                    : l10n.workspaceDiskUsageSummary(
                        formatWorkspaceBytes(usage.totalBytes),
                        usage.fileCount,
                      );
                final detail = usage != null && usage.truncated
                    ? l10n.workspaceDiskUsagePartial(usage.scannedEntryCount)
                    : l10n.workspaceDiskUsageHint;

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.workspaceDiskUsageTitle,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: cs.onSurface.withValues(alpha: 0.72),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      summary,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      detail,
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.35,
                        color: cs.onSurface.withValues(alpha: 0.55),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          IconButton(
            tooltip: l10n.workspaceDiskUsageRefresh,
            onPressed: () => setState(_load),
            icon: const Icon(Lucide.RefreshCw, size: 18),
          ),
        ],
      ),
    );
  }
}
