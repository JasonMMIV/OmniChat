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

Future<WorkspaceConfig?> showProjectWorkspaceSettingsSheet(
  BuildContext context, {
  required WorkspaceConfig initial,
}) async {
  return showModalBottomSheet<WorkspaceConfig>(
    context: context,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (_) => _WorkspaceModeSheet(initial: initial, allowInherit: false),
  );
}

class _DefaultWorkspaceDirectorySheet extends StatelessWidget {
  const _DefaultWorkspaceDirectorySheet();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final settings = context.watch<SettingsProvider>();
    final configured = settings.defaultWorkspacePath;
    final displayPath = configured ?? l10n.workspaceDefaultDirectoryPrivate;

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
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                displayPath,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: cs.onSurface.withOpacity(0.68),
                ),
              ),
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Lucide.FolderCode),
                title: Text(l10n.workspaceChooseFolder),
                onTap: () async {
                  final selected = await _pickWorkspaceFolder(context);
                  if (selected != null && context.mounted) {
                    await context
                        .read<SettingsProvider>()
                        .setDefaultWorkspacePath(selected);
                  }
                },
              ),
              if (configured != null)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Lucide.RotateCcw),
                  title: Text(l10n.workspaceDefaultDirectoryReset),
                  onTap: () => context
                      .read<SettingsProvider>()
                      .setDefaultWorkspacePath(null),
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
    required this.initial,
    required this.allowInherit,
  });

  final WorkspaceConfig initial;
  final bool allowInherit;

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

    Widget option({
      required IconData icon,
      required String title,
      required WorkspaceConfig value,
      String? detail,
    }) {
      final selected = initial == value;
      return ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon),
        title: Text(title),
        subtitle: detail == null ? null : Text(detail),
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
                l10n.workspaceTitle,
                style: const TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              option(
                icon: Lucide.CircleX,
                title: l10n.workspaceDoNotUse,
                value: const WorkspaceConfig.disabled(),
              ),
              option(
                icon: Lucide.Folder,
                title: l10n.workspaceUseDefaultDirectory,
                value: const WorkspaceConfig.useDefault(),
              ),
              if (allowInherit)
                option(
                  icon: Lucide.Folder,
                  title: l10n.workspaceUseProjectDirectory,
                  value: const WorkspaceConfig.inheritProject(),
                ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Lucide.FolderCode),
                title: Text(l10n.workspaceChooseFolder),
                subtitle: initial.mode == WorkspaceMode.custom
                    ? Text(
                        initial.path ?? '',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
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
