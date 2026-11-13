import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../../../core/models/workspace_config.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';

Future<String?> _pickWorkspaceFolder(BuildContext context) async {
  final l10n = AppLocalizations.of(context)!;
  if (Platform.isAndroid) {
    try {
      await Permission.manageExternalStorage.request();
    } catch (_) {}
  }
  final selected = await FilePicker.platform.getDirectoryPath(
    dialogTitle: l10n.workspaceSelectFolderDialogTitle,
  );
  final value = selected?.trim();
  return value == null || value.isEmpty ? null : value;
}

String workspaceDefaultDirectoryLabel(
  AppLocalizations l10n,
  WorkspaceConfig config,
) {
  return switch (config.mode) {
    WorkspaceMode.disabled => l10n.workspaceDoNotUse,
    WorkspaceMode.appPrivate => l10n.workspaceDefaultDirectoryPrivate,
    WorkspaceMode.useDefault => l10n.workspaceDefaultDirectoryPrivate,
    WorkspaceMode.custom => config.path ?? l10n.workspaceChooseFolder,
    WorkspaceMode.inheritProject => l10n.workspaceDefaultDirectoryPrivate,
  };
}

/// Short label of a conversation-level workspace config for the workspace
/// menu subtitle (app-private directory, custom path, default directory, or
/// project inheritance).
String workspaceModeLabel(AppLocalizations l10n, WorkspaceConfig? config) {
  return switch (config?.mode) {
    WorkspaceMode.custom => config?.path ?? l10n.workspaceChooseFolder,
    WorkspaceMode.appPrivate => l10n.workspaceUseAppPrivateDirectory,
    WorkspaceMode.useDefault => l10n.workspaceUseDefaultDirectory,
    WorkspaceMode.disabled => l10n.workspaceDoNotUse,
    _ => l10n.workspaceUseProjectDirectory,
  };
}

Future<void> showDefaultWorkspaceDirectoryDialog(BuildContext context) async {
  final isDesktop =
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.linux;
  final child = const _DefaultWorkspaceDirectorySheet();
  if (isDesktop) {
    await showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        // The sheet only rounds its top corners (bottom-sheet styling); clip
        // the centered dialog to the same radius so all four corners match.
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: child,
        ),
      ),
    );
  } else {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => child,
    );
  }
}

/// Conversation-level workspace directory picker opened from the workspace
/// menu's "Workspace directory" entry: choose the app-private directory, the
/// default directory, the project directory, or a custom folder. `disabled`
/// is intentionally not offered here — the menu's enable toggle owns that
/// state. The global default directory is configured from Settings.
Future<WorkspaceConfig?> showConversationWorkspaceModeSheet(
  BuildContext context, {
  required WorkspaceConfig initial,
}) {
  final l10n = AppLocalizations.of(context)!;
  final isDesktop =
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.linux;
  if (isDesktop) {
    return showDialog<WorkspaceConfig>(
      context: context,
      builder: (_) => Dialog(
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: _WorkspaceModeSheet(
            title: l10n.workspaceDirectoryMenu,
            initial: initial,
            allowInherit: true,
            allowDisabled: false,
          ),
        ),
      ),
    );
  }
  return showModalBottomSheet<WorkspaceConfig>(
    context: context,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (_) => _WorkspaceModeSheet(
      title: l10n.workspaceDirectoryMenu,
      initial: initial,
      allowInherit: true,
      allowDisabled: false,
    ),
  );
}

Future<WorkspaceConfig?> showProjectWorkspaceSettingsSheet(
  BuildContext context, {
  required WorkspaceConfig initial,
}) async {
  final l10n = AppLocalizations.of(context)!;
  return showModalBottomSheet<WorkspaceConfig>(
    context: context,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (_) => _WorkspaceModeSheet(
      title: l10n.workspaceTitle,
      initial: initial,
      allowInherit: false,
    ),
  );
}

class _DefaultWorkspaceDirectorySheet extends StatelessWidget {
  const _DefaultWorkspaceDirectorySheet();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final settings = context.watch<SettingsProvider>();
    final current = settings.defaultWorkspaceConfig;
    // Legacy `use_default` at the global level also means the app-private
    // directory. Treat both as the same selected option so existing installs
    // still show a checkmark after the explicit app-private mode was added.
    final appPrivateSelected =
        current.mode == WorkspaceMode.appPrivate ||
        current.mode == WorkspaceMode.useDefault;
    // Match the dialog scale used elsewhere in the app.
    const optionTitleStyle = TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w500,
    );
    final optionSubtitleStyle = TextStyle(
      fontSize: 12,
      color: cs.onSurface.withValues(alpha: 0.65),
    );

    Widget option({
      required IconData icon,
      required String title,
      required WorkspaceConfig value,
      bool? selected,
    }) {
      final isSelected = selected ?? current == value;
      return ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon, size: 20),
        title: Text(title, style: optionTitleStyle),
        trailing: isSelected ? Icon(Lucide.Check, color: cs.primary) : null,
        onTap: () async {
          await context.read<SettingsProvider>().setDefaultWorkspaceConfig(
            value,
          );
          if (context.mounted) Navigator.of(context).pop();
        },
      );
    }

    return Material(
      color: cs.surface,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.workspaceDefaultDirectorySettings,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                workspaceDefaultDirectoryLabel(l10n, current),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: cs.onSurface.withOpacity(0.68),
                ),
              ),
              const SizedBox(height: 12),
              option(
                icon: Lucide.CircleX,
                title: l10n.workspaceDoNotUse,
                value: const WorkspaceConfig.disabled(),
              ),
              option(
                icon: Lucide.Folder,
                title: l10n.workspaceUseAppPrivateDirectory,
                value: const WorkspaceConfig.appPrivate(),
                selected: appPrivateSelected,
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Lucide.FolderCode, size: 20),
                title: Text(
                  l10n.workspaceChooseFolder,
                  style: optionTitleStyle,
                ),
                subtitle: current.mode == WorkspaceMode.custom
                    ? Text(
                        current.path ?? '',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: optionSubtitleStyle,
                      )
                    : null,
                trailing: current.mode == WorkspaceMode.custom
                    ? Icon(Lucide.Check, color: cs.primary)
                    : null,
                onTap: () async {
                  final selected = await _pickWorkspaceFolder(context);
                  if (selected != null && context.mounted) {
                    await context
                        .read<SettingsProvider>()
                        .setDefaultWorkspaceConfig(
                          WorkspaceConfig.custom(selected),
                        );
                    if (context.mounted) Navigator.of(context).pop();
                  }
                },
              ),
              const SizedBox(height: 4),
              Text(
                l10n.workspaceDefaultDirectoryDescription,
                style: TextStyle(
                  fontSize: 12,
                  color: cs.onSurface.withOpacity(0.62),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WorkspaceModeSheet extends StatelessWidget {
  const _WorkspaceModeSheet({
    required this.title,
    required this.initial,
    required this.allowInherit,
    this.allowDisabled = true,
  });

  /// Sheet heading ("Workspace directory" for the conversation flow,
  /// "Workspace" for the project-level flow).
  final String title;

  /// The workspace mode chosen before opening this sheet.
  final WorkspaceConfig initial;

  /// Whether the project-inheritance option is offered.
  final bool allowInherit;

  /// Whether the "do not use workspace" option is offered (project-level
  /// config only; the conversation flow owns disable via its toggle).
  final bool allowDisabled;

  Future<void> _chooseCustom(BuildContext context) async {
    final selected = await _pickWorkspaceFolder(context);
    if (selected != null && context.mounted) {
      Navigator.of(context).pop(WorkspaceConfig.custom(selected));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    const optionTitleStyle = TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w500,
    );
    final optionSubtitleStyle = TextStyle(
      fontSize: 12,
      color: cs.onSurface.withValues(alpha: 0.65),
    );

    Widget option({
      required IconData icon,
      required String label,
      required WorkspaceConfig value,
    }) {
      final selected = initial == value;
      return ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon, size: 20),
        title: Text(label, style: optionTitleStyle),
        trailing: selected ? Icon(Lucide.Check, color: cs.primary) : null,
        onTap: () => Navigator.of(context).pop(value),
      );
    }

    return Material(
      color: cs.surface,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              if (allowDisabled)
                option(
                  icon: Lucide.CircleX,
                  label: l10n.workspaceDoNotUse,
                  value: const WorkspaceConfig.disabled(),
                ),
              option(
                icon: Lucide.Folder,
                label: l10n.workspaceUseAppPrivateDirectory,
                value: const WorkspaceConfig.appPrivate(),
              ),
              option(
                icon: Lucide.Folder,
                label: l10n.workspaceUseDefaultDirectory,
                value: const WorkspaceConfig.useDefault(),
              ),
              if (allowInherit)
                option(
                  icon: Lucide.Folder,
                  label: l10n.workspaceUseProjectDirectory,
                  value: const WorkspaceConfig.inheritProject(),
                ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Lucide.FolderCode, size: 20),
                title: Text(
                  l10n.workspaceChooseFolder,
                  style: optionTitleStyle,
                ),
                subtitle: initial.mode == WorkspaceMode.custom
                    ? Text(
                        initial.path ?? '',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: optionSubtitleStyle,
                      )
                    : null,
                trailing: initial.mode == WorkspaceMode.custom
                    ? Icon(Lucide.Check, color: cs.primary)
                    : null,
                onTap: () => _chooseCustom(context),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
