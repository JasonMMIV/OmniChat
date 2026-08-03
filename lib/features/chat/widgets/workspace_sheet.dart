import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../../../core/models/workspace_config.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/workspace/workspace_resolver.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import 'workspace_file_browser.dart';
import 'workspace_settings_dialog.dart';

Future<void> showWorkspaceSheet(
  BuildContext context, {
  required String conversationId,
}) async {
  final isDesktop =
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.linux;
  final child = WorkspaceSheet(conversationId: conversationId);
  if (isDesktop) {
    await showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
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

class WorkspaceSheet extends StatefulWidget {
  const WorkspaceSheet({super.key, required this.conversationId});

  final String conversationId;

  @override
  State<WorkspaceSheet> createState() => _WorkspaceSheetState();
}

class _WorkspaceSheetState extends State<WorkspaceSheet> {
  String? _workspacePath;
  WorkspaceResolution? _resolution;
  bool _loading = true;
  bool _busy = false;

  ChatService get _chatService => context.read<ChatService>();

  @override
  void initState() {
    super.initState();
    _loadWorkspace();
  }

  Future<void> _loadWorkspace() async {
    final service = context.read<ChatService>();
    final conversation = service.getConversation(widget.conversationId);
    final assistantProvider = context.read<AssistantProvider>();
    final project = conversation?.assistantId == null
        ? assistantProvider.currentAssistant
        : assistantProvider.getById(conversation!.assistantId!);
    final resolution = conversation == null
        ? const WorkspaceResolution(
            source: WorkspaceSource.disabled,
            path: null,
          )
        : await WorkspaceResolver.resolve(
            conversation: conversation,
            project: project,
            conversationConfig: service.getConversationWorkspaceConfig(
              widget.conversationId,
            ),
            defaultPath: context.read<SettingsProvider>().defaultWorkspacePath,
          );
    if (!mounted) return;
    setState(() {
      _resolution = resolution;
      _workspacePath = resolution.path;
      _loading = false;
    });
  }

  Future<void> _pickFolder() async {
    if (_busy) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() => _busy = true);
    try {
      if (Platform.isAndroid) {
        // Permission handler opens Android's all-files-access settings when
        // supported. The picker is still attempted if the user declines.
        try {
          await Permission.manageExternalStorage.request();
        } catch (_) {}
      }
      final selected = await FilePicker.platform.getDirectoryPath(
        dialogTitle: l10n.workspaceSelectFolderDialogTitle,
      );
      if (selected != null && selected.trim().isNotEmpty) {
        await _chatService.setConversationWorkspace(
          widget.conversationId,
          selected,
        );
        await _loadWorkspace();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setWorkspaceConfig(WorkspaceConfig config) async {
    await _chatService.setConversationWorkspaceConfig(
      widget.conversationId,
      config,
    );
    await _loadWorkspace();
  }

  Future<void> _openBrowser() async {
    final path = _workspacePath;
    if (path == null || _resolution?.enabled != true) return;
    final navigator = Navigator.of(context);
    final isDesktop =
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux;
    Navigator.of(context).pop();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    if (isDesktop) {
      await showDialog<void>(
        context: navigator.context,
        builder: (_) => Dialog(
          child: SizedBox(
            width: 560,
            height: 620,
            child: WorkspaceFileBrowser(workspacePath: path),
          ),
        ),
      );
    } else {
      await navigator.push(
        MaterialPageRoute(
          builder: (_) => WorkspaceFileBrowser(workspacePath: path),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final resolution = _resolution;
    final pathLabel = resolution?.enabled == true
        ? (resolution!.path ?? '')
        : l10n.workspaceDoNotUse;
    final content = SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: _loading
            ? const SizedBox(
                height: 180,
                child: Center(child: CircularProgressIndicator()),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 38,
                      height: 4,
                      decoration: BoxDecoration(
                        color: cs.onSurface.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    l10n.workspaceTitle,
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    pathLabel,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: cs.onSurface.withOpacity(0.65),
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 12),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Lucide.CircleX),
                    title: Text(l10n.workspaceDoNotUse),
                    onTap: () =>
                        _setWorkspaceConfig(const WorkspaceConfig.disabled()),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Lucide.Folder),
                    title: Text(l10n.workspaceUseDefaultDirectory),
                    onTap: () =>
                        _setWorkspaceConfig(const WorkspaceConfig.useDefault()),
                    trailing: IconButton(
                      tooltip: l10n.workspaceDefaultDirectorySettings,
                      icon: const Icon(Lucide.Settings2),
                      onPressed: () async {
                        await showDefaultWorkspaceDirectoryDialog(context);
                        if (mounted) await _loadWorkspace();
                      },
                    ),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Lucide.Folder),
                    title: Text(l10n.workspaceUseProjectDirectory),
                    onTap: () => _setWorkspaceConfig(
                      const WorkspaceConfig.inheritProject(),
                    ),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Lucide.FolderCode),
                    title: Text(l10n.workspaceChooseFolder),
                    onTap: _busy ? null : _pickFolder,
                    trailing: _busy
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : null,
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Lucide.FileText),
                    title: Text(l10n.workspaceFiles),
                    onTap: resolution?.enabled == true ? _openBrowser : null,
                  ),
                ],
              ),
      ),
    );

    return Material(
      color: cs.surface,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
      child: content,
    );
  }
}
