import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/providers/settings_provider.dart';
import '../../../core/services/dev/dev_preview_tools.dart';
import '../../../core/services/file/file_tool_service.dart';
import '../../../core/services/shell/android/android_sandbox_service.dart';
import '../../../core/services/shell/android/android_shell_service.dart';
import '../../../core/services/shell/shell_run_service.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_switch.dart';
import '../tools/tool_presentation.dart';
import '../widgets/workspace_disk_usage_card.dart';
import 'android_shell_page.dart';

/// One row of the workspace tools switchboard.
class _WorkspaceToolEntry {
  const _WorkspaceToolEntry({required this.name, required this.description});

  factory _WorkspaceToolEntry.fromDefinition(Map<String, dynamic> def) {
    final function = def['function'] as Map;
    return _WorkspaceToolEntry(
      name: (function['name'] ?? '').toString(),
      description: (function['description'] ?? '').toString(),
    );
  }

  final String name;

  /// Model-facing schema description — only a fallback for a tool that has no
  /// localized summary yet.
  final String description;
}

/// Global tool switchboard for the workspace: the 17 built-in file tools,
/// the live-preview console reader and the platform shell tool(s) — desktop
/// `shell_run` and/or Android `shell_exec` — each with its own toggle, plus
/// the two global permission switches (files outside the workspace, shell
/// commands).
///
/// Rows are grouped by what the tool does and titled with localized names.
///
/// Reachable from the workspace menu even while the workspace is disabled.
/// The planning (write_todos) and ask_user switches moved to the Add-ons
/// menu on 2026-11-10 — they are conversation-level tools, not workspace
/// tools. File tools still require the workspace switch.
class WorkspaceToolsPage extends StatelessWidget {
  const WorkspaceToolsPage({super.key, this.workspacePath});

  /// Current conversation workspace, used by the P3-4 disk usage card. The
  /// page stays usable without it (the card is simply omitted).
  final String? workspacePath;

  @override
  Widget build(BuildContext context) {
    // Android Shell install/remove changes `shell_exec` availability. Listen
    // to the process-wide sandbox service so returning from the install page
    // shows the new status pill, shell permission row and shell tool row
    // immediately (a popped route does not rebuild the page below it).
    return ListenableBuilder(
      listenable: AndroidSandboxService.instance,
      builder: (context, _) {
        final l10n = AppLocalizations.of(context)!;
        final cs = Theme.of(context).colorScheme;
        final settings = context.watch<SettingsProvider>();

        final entries = <_WorkspaceToolEntry>[
          // File tools in definition order — the definitions are the canonical
          // name/description source, so the list can never drift from what the
          // LLM is actually offered.
          for (final def in FileToolService.getToolDefinitions())
            _WorkspaceToolEntry.fromDefinition(def),
          _WorkspaceToolEntry.fromDefinition(
            DevPreviewTools.getConsoleErrorsDefinition(),
          ),
          if (ShellRunService.isPlatformSupported)
            _WorkspaceToolEntry.fromDefinition(
              ShellRunService.getToolDefinition(),
            ),
          if (AndroidShellService.isToolAvailable)
            _WorkspaceToolEntry.fromDefinition(
              AndroidShellService.getToolDefinition(),
            ),
        ];

        return Scaffold(
          appBar: AppBar(title: Text(l10n.workspaceToolsTitle)),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              children: [
                if (workspacePath != null &&
                    workspacePath!.trim().isNotEmpty) ...[
                  WorkspaceDiskUsageCard(workspacePath: workspacePath),
                  const SizedBox(height: 12),
                ],
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
                  child: Text(
                    l10n.workspaceToolsDescription,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.4,
                      color: cs.onSurface.withValues(alpha: 0.62),
                    ),
                  ),
                ),
                // Android Shell used to live only in Settings, which made it
                // undiscoverable: before installation there is no shell row
                // anywhere on this page. Surface the install entry here, with
                // live status, so the tool switchboard explains the missing
                // shell instead of silently omitting it (2026-11-14).
                if (AndroidShellService.isPlatformSupported) ...[
                  _AndroidShellTile(
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const AndroidShellPage(),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 12),
                ],
                _sectionLabel(context, l10n.workspacePermissionsTitle),
                _permissionRow(
                  context,
                  icon: Lucide.FolderOpen,
                  title: l10n.workspaceFilesOutsideAllowAllTitle,
                  subtitle: l10n.workspaceFilesOutsideAllowAllSubtitle,
                  value: settings.fileOutsideWorkspaceAllowAllV1,
                  onChanged: settings.setFileOutsideWorkspaceAllowAllV1,
                ),
                if (ShellRunService.isPlatformSupported ||
                    AndroidShellService.isToolAvailable)
                  _permissionRow(
                    context,
                    icon: Lucide.Terminal,
                    title: l10n.workspaceShellAllowAllTitle,
                    subtitle: l10n.workspaceShellAllowAllSubtitle,
                    value: settings.shellAllowAllV1,
                    onChanged: settings.setShellAllowAllV1,
                  ),
                for (final group in WorkspaceToolGroup.values)
                  if (entries.any(
                    (entry) => workspaceToolGroup(entry.name) == group,
                  )) ...[
                    _sectionHeader(
                      context,
                      workspaceToolGroupLabel(l10n, group),
                      workspaceToolGroupDescription(l10n, group),
                    ),
                    for (final entry in entries.where(
                      (entry) => workspaceToolGroup(entry.name) == group,
                    ))
                      _toolRow(context, l10n, settings, entry),
                  ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Android PRoot shell install entry on the Tools page: always visible on
/// Android (before installation too) with the current install state.
class _AndroidShellTile extends StatelessWidget {
  const _AndroidShellTile({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final service = AndroidSandboxService.instance;
    final status = service.status;
    final installing = service.isInstalling;

    // Fixed accents (instead of theme roles) so the 11px status text keeps
    // enough contrast in both themes: #22C55E on a light tint does not.
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final readyColor = isDark
        ? const Color(0xFF22C55E)
        : const Color(0xFF15803D);
    final repairColor = isDark
        ? const Color(0xFFFBBF24)
        : const Color(0xFFB45309);

    // Installed but not runnable (PRoot rejected, rootfs damaged) needs a
    // repair, not a fresh install — the install page already offers Repair.
    final needsRepair =
        status.supported && status.rootfsInstalled && !status.ready;

    final statusLabel = installing
        ? l10n.androidShellStatusInstalling
        : !status.supported
        ? l10n.androidShellStatusUnsupported
        : status.ready
        ? l10n.androidShellStatusReady
        : needsRepair
        ? l10n.androidShellStatusNeedsRepair
        : l10n.androidShellStatusNotInstalled;
    final Color accent;
    if (installing) {
      accent = cs.primary;
    } else if (!status.supported) {
      accent = cs.error;
    } else if (status.ready) {
      accent = readyColor;
    } else if (needsRepair) {
      accent = repairColor;
    } else {
      accent = cs.primary;
    }

    return Material(
      color: cs.surfaceContainerHighest.withValues(alpha: 0.35),
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
          child: Row(
            children: [
              Icon(Lucide.Terminal, size: 20, color: accent),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.androidShellTitle,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      l10n.androidShellEnvironmentSubtitle,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.35,
                        color: cs.onSurface.withValues(alpha: 0.55),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: accent.withValues(alpha: 0.35),
                        ),
                      ),
                      child: Text(
                        statusLabel,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: accent,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Icon(
                Lucide.ChevronRight,
                size: 16,
                color: cs.onSurface.withValues(alpha: 0.45),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Widget _toolRow(
  BuildContext context,
  AppLocalizations l10n,
  SettingsProvider settings,
  _WorkspaceToolEntry entry,
) {
  final cs = Theme.of(context).colorScheme;
  final displayName = toolDisplayName(l10n, entry.name);
  // A tool with no localized summary yet (newly added built-in) falls back to
  // the English schema sentence, so it stays usable until the ARB entries
  // land. `test/tool_presentation_test.dart` catches that case.
  var detail = toolShortDescription(l10n, entry.name);
  if (detail == null && displayName == entry.name) {
    detail = _firstSentence(entry.description);
  }

  return ListTile(
    key: ValueKey('workspace-tool-${entry.name}'),
    contentPadding: EdgeInsets.zero,
    leading: Icon(toolIcon(entry.name), size: 20, color: cs.primary),
    title: Text(
      displayName,
      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
    ),
    subtitle: detail == null
        ? null
        : Text(
            detail,
            style: TextStyle(
              fontSize: 12,
              height: 1.35,
              color: cs.onSurface.withValues(alpha: 0.55),
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
    trailing: IosSwitch(
      value: settings.isWorkspaceToolEnabled(entry.name),
      onChanged: (v) => settings.setWorkspaceToolEnabled(entry.name, v),
    ),
  );
}

Widget _sectionLabel(BuildContext context, String text) {
  final cs = Theme.of(context).colorScheme;
  return Padding(
    padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
    child: Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.6,
        color: cs.onSurface.withValues(alpha: 0.5),
      ),
    ),
  );
}

/// Group heading plus a one-line explanation of what the group does.
Widget _sectionHeader(BuildContext context, String title, String description) {
  final cs = Theme.of(context).colorScheme;
  return Padding(
    padding: const EdgeInsets.fromLTRB(4, 14, 4, 2),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title.toUpperCase(),
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
            color: cs.onSurface.withValues(alpha: 0.5),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          description,
          style: TextStyle(
            fontSize: 11.5,
            height: 1.35,
            color: cs.onSurface.withValues(alpha: 0.42),
          ),
        ),
      ],
    ),
  );
}

Widget _permissionRow(
  BuildContext context, {
  required IconData icon,
  required String title,
  required String subtitle,
  required bool value,
  required ValueChanged<bool> onChanged,
}) {
  final cs = Theme.of(context).colorScheme;
  return Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(12, 2, 8, 2),
        leading: Icon(icon, size: 20, color: cs.primary),
        title: Text(
          title,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          subtitle,
          style: TextStyle(
            fontSize: 12,
            height: 1.35,
            color: cs.onSurface.withValues(alpha: 0.55),
          ),
        ),
        trailing: IosSwitch(value: value, onChanged: onChanged),
      ),
    ),
  );
}

/// First sentence of a built-in tool description (the raw descriptions are
/// English; only used for a tool without a localized summary yet).
String _firstSentence(String description) {
  final text = description.trim();
  if (text.isEmpty) return text;
  final end = text.indexOf(RegExp(r'[.!?](\s|$)'));
  return end < 0 ? text : text.substring(0, end + 1);
}
