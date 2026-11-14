import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/services/shell/android/android_sandbox_service.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';

/// P2-5: Android PRoot shell install/repair/remove surface.
///
/// The page is deliberately explicit about the contract: foreground only, one
/// command at a time, not a security sandbox, and shared-storage workspaces do
/// not support executable bits or symlinks.
class AndroidShellPage extends StatefulWidget {
  const AndroidShellPage({super.key});

  @override
  State<AndroidShellPage> createState() => _AndroidShellPageState();
}

class _AndroidShellPageState extends State<AndroidShellPage> {
  AndroidSandboxService get _service => AndroidSandboxService.instance;

  StreamSubscription<AndroidSandboxProgress>? _progressSub;
  String _stage = '';
  int _percent = 0;
  bool _working = false;
  int? _exactRootfsBytes;
  bool _loadingUsage = false;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onService);
    _progressSub = _service.progress.listen((progress) {
      if (!mounted) return;
      setState(() {
        if (progress.stage.isNotEmpty && progress.stage != 'progress') {
          _stage = progress.stage;
        }
        if (progress.percent > 0) _percent = progress.percent;
      });
    });
    _service.refresh();
  }

  @override
  void dispose() {
    _service.removeListener(_onService);
    _progressSub?.cancel();
    super.dispose();
  }

  void _onService() {
    if (!mounted) return;
    setState(() {});
    if (_service.status.ready && _exactRootfsBytes == null) {
      _loadExactUsage();
    }
  }

  Future<void> _loadExactUsage() async {
    if (_loadingUsage) return;
    _loadingUsage = true;
    try {
      final usage = await _service.diskUsage();
      final bytes = usage['rootfsBytes'];
      if (mounted && bytes is num) {
        setState(() => _exactRootfsBytes = bytes.toInt());
      }
    } finally {
      _loadingUsage = false;
    }
  }

  Future<void> _install() async {
    if (_working) return;
    setState(() {
      _working = true;
      _stage = 'verify';
      _percent = 0;
    });
    try {
      await _service.install();
      if (!mounted) return;
      setState(() {
        _working = false;
        _exactRootfsBytes = null;
      });
      _loadExactUsage();
    } on AndroidSandboxException catch (error) {
      if (!mounted) return;
      setState(() => _working = false);
      final l10n = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.androidShellInstallFailed(error.message))),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _working = false);
      final l10n = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.androidShellInstallFailed('$error'))),
      );
    }
  }

  Future<void> _cancelInstall() async {
    await _service.cancelInstall();
    if (mounted) {
      setState(() {
        _working = false;
        _stage = '';
        _percent = 0;
      });
    }
  }

  Future<void> _remove() async {
    if (_working) return;
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.androidShellRemoveTitle),
        content: Text(l10n.androidShellRemoveMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.homePageCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.androidShellRemoveConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _working = true);
    try {
      await _service.remove();
      if (mounted) setState(() => _exactRootfsBytes = null);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.androidShellInstallFailed('$error'))),
      );
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 MB';
    const kb = 1024;
    const mb = kb * 1024;
    const gb = mb * 1024;
    if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(2)} GB';
    if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
    return '${(bytes / kb).toStringAsFixed(0)} KB';
  }

  String _stageLabel(AppLocalizations l10n) {
    switch (_stage) {
      case 'verify':
        return l10n.androidShellStageVerify;
      case 'extract':
        return l10n.androidShellStageExtract;
      case 'patch':
        return l10n.androidShellStagePatch;
      case 'activate':
        return l10n.androidShellStageActivate;
      case 'ready':
        return l10n.androidShellStageReady;
      default:
        return l10n.androidShellInstalling;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final status = _service.status;
    final installing = _working || _service.isInstalling;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.androidShellPageTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          _StatusCard(
            status: status,
            rootfsBytes: _exactRootfsBytes ?? status.rootfsBytes,
            installing: installing,
            stageLabel: _stageLabel(l10n),
            percent: _percent,
            formatBytes: _formatBytes,
          ),
          const SizedBox(height: 12),
          if (!status.supported)
            _NoticeCard(
              icon: Lucide.CircleAlert,
              title: l10n.androidShellStatusUnsupported,
              body: l10n.androidShellUnsupportedBody,
            )
          else
            _ActionCard(
              installed: status.rootfsInstalled,
              installing: installing,
              onInstall: _install,
              onCancel: _cancelInstall,
              onRemove: _remove,
            ),
          const SizedBox(height: 12),
          _NoticeCard(
            icon: Lucide.Terminal,
            title: l10n.androidShellForegroundOnly,
            body: l10n.androidShellForegroundOnlyBody,
          ),
          const SizedBox(height: 8),
          _NoticeCard(
            icon: Lucide.Info,
            title: l10n.androidShellNotSandbox,
            body: l10n.androidShellNotSandboxBody,
          ),
          const SizedBox(height: 8),
          _NoticeCard(
            icon: Lucide.HardDrive,
            title: l10n.androidShellExternal,
            body: l10n.androidShellExternalBody,
          ),
          const SizedBox(height: 8),
          _NoticeCard(
            icon: Lucide.Package,
            title: l10n.androidShellLicenses,
            body: l10n.androidShellLicensesBody,
          ),
          if (_service.lastError != null) ...[
            const SizedBox(height: 12),
            Text(
              _service.lastError!,
              style: TextStyle(fontSize: 12, color: cs.error),
            ),
          ],
        ],
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.status,
    required this.rootfsBytes,
    required this.installing,
    required this.stageLabel,
    required this.percent,
    required this.formatBytes,
  });

  final AndroidSandboxStatus status;
  final int rootfsBytes;
  final bool installing;
  final String stageLabel;
  final int percent;
  final String Function(int) formatBytes;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final ready = status.ready;
    final needsRepair =
        status.supported && status.rootfsInstalled && !status.ready;
    final title = installing
        ? l10n.androidShellInstalling
        : ready
        ? l10n.androidShellStatusReady
        : !status.supported
        ? l10n.androidShellStatusUnsupported
        : needsRepair
        ? l10n.androidShellStatusNeedsRepair
        : l10n.androidShellStatusNotInstalled;
    // Match the Tools-page tile: light-theme accents are darkened so the
    // status color stays legible on light surfaces.
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final readyColor = isDark
        ? const Color(0xFF22C55E)
        : const Color(0xFF15803D);
    final repairColor = isDark
        ? const Color(0xFFFBBF24)
        : const Color(0xFFB45309);
    final Color accent = ready
        ? readyColor
        : !status.supported
        ? cs.error
        : needsRepair
        ? repairColor
        : cs.primary;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.onSurface.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.onSurface.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Lucide.Terminal, size: 20, color: accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: cs.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      status.rootfsVersion ?? status.reason ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (installing) ...[
            const SizedBox(height: 14),
            LinearProgressIndicator(
              value: percent <= 0 ? null : (percent / 100).clamp(0.0, 1.0),
              minHeight: 6,
              borderRadius: BorderRadius.circular(999),
            ),
            const SizedBox(height: 6),
            Text(
              '$stageLabel${percent > 0 ? ' · $percent%' : ''}',
              style: TextStyle(
                fontSize: 12,
                color: cs.onSurface.withValues(alpha: 0.65),
              ),
            ),
          ],
          if (ready) ...[
            const SizedBox(height: 14),
            _MetricRow(
              label: l10n.androidShellDiskUsage,
              value: formatBytes(rootfsBytes),
            ),
            const SizedBox(height: 6),
            _MetricRow(
              label: l10n.androidShellFreeSpace,
              value: formatBytes(status.freeBytes),
            ),
            if (status.installedAt != null) ...[
              const SizedBox(height: 6),
              _MetricRow(
                label: l10n.androidShellVersion,
                value: status.installedAt!,
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _MetricRow extends StatelessWidget {
  const _MetricRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              color: cs.onSurface.withValues(alpha: 0.65),
            ),
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: cs.onSurface.withValues(alpha: 0.9),
          ),
        ),
      ],
    );
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({
    required this.installed,
    required this.installing,
    required this.onInstall,
    required this.onCancel,
    required this.onRemove,
  });

  final bool installed;
  final bool installing;
  final VoidCallback onInstall;
  final VoidCallback onCancel;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        if (installing)
          FilledButton.icon(
            onPressed: onCancel,
            icon: const Icon(Lucide.Square, size: 16),
            label: Text(l10n.androidShellCancel),
          )
        else
          FilledButton.icon(
            onPressed: onInstall,
            icon: Icon(
              installed ? Lucide.RefreshCw : Lucide.Download,
              size: 16,
            ),
            label: Text(
              installed ? l10n.androidShellRepair : l10n.androidShellInstall,
            ),
          ),
        if (installed && !installing)
          OutlinedButton.icon(
            onPressed: onRemove,
            icon: const Icon(Lucide.Trash2, size: 16),
            label: Text(l10n.androidShellRemove),
            style: OutlinedButton.styleFrom(foregroundColor: cs.error),
          ),
      ],
    );
  }
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: cs.onSurface.withValues(alpha: 0.02),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.onSurface.withValues(alpha: 0.07)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: cs.onSurface.withValues(alpha: 0.7)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface.withValues(alpha: 0.88),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  body,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.35,
                    color: cs.onSurface.withValues(alpha: 0.62),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
