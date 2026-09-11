import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/workspace_config.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/workspace/workspace_resolver.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_switch.dart';
import '../pages/workspace_tools_page.dart';
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
            defaultConfig: context
                .read<SettingsProvider>()
                .defaultWorkspaceConfig,
          );
    if (!mounted) return;
    setState(() {
      _resolution = resolution;
      _workspacePath = resolution.path;
      _loading = false;
    });
  }

  /// Master enable/disable toggle for this conversation's workspace. The
  /// sheet stays open so the directory/tools/files entries appear or
  /// disappear in place; ChatService remembers the prior directory choice
  /// inside the disabled config and restores it when re-enabled.
  Future<void> _toggleWorkspace(bool enable) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _chatService.setConversationWorkspaceEnabled(
        widget.conversationId,
        enable,
      );
      await _loadWorkspace();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setWorkspaceConfig(WorkspaceConfig config) async {
    await _chatService.setConversationWorkspaceConfig(
      widget.conversationId,
      config,
    );
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _openDirectorySheet() async {
    if (_busy) return;
    final initial =
        _chatService.getConversationWorkspaceConfig(
          widget.conversationId,
        ) ??
        const WorkspaceConfig.inheritProject();
    final result = await showConversationWorkspaceModeSheet(
      context,
      initial: initial,
    );
    if (result == null || !mounted) return;
    await _setWorkspaceConfig(result);
  }

  Future<void> _openToolsPage() async {
    final navigator = Navigator.of(context);
    Navigator.of(context).pop();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    await navigator.push(
      MaterialPageRoute(builder: (_) => const WorkspaceToolsPage()),
    );
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
    final isDesktop =
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux;
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final resolution = _resolution;
    final enabled = resolution?.enabled == true;
    final pathLabel = enabled
        ? (resolution!.path ?? '')
        : l10n.workspaceDisabledHint;
    final conversationConfig = _chatService.getConversationWorkspaceConfig(
      widget.conversationId,
    );
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
                  if (!isDesktop) ...[
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
                  ],
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
                  // Master switch: enable or disable the workspace for this
                  // conversation.
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _busy
                        ? null
                        : () => _toggleWorkspace(!enabled),
                    child: Row(
                      children: [
                        Icon(
                          Lucide.Folder,
                          size: 20,
                          color: cs.onSurface.withOpacity(0.75),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            l10n.workspaceEnableToggle,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        IosSwitch(
                          value: enabled,
                          onChanged: _busy ? null : _toggleWorkspace,
                        ),
                      ],
                    ),
                  ),
                  // Directory, tools and files entries only exist while
                  // the workspace is enabled.
                  if (enabled) ...[
                    const SizedBox(height: 8),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Lucide.FolderOpen),
                      title: Text(l10n.workspaceDirectoryMenu),
                      subtitle: Text(
                        workspaceModeLabel(l10n, conversationConfig),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: const Icon(Lucide.ChevronRight),
                      onTap: _busy ? null : _openDirectorySheet,
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Lucide.Wrench),
                      title: Text(l10n.workspaceToolsMenu),
                      trailing: const Icon(Lucide.ChevronRight),
                      onTap: _busy ? null : _openToolsPage,
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Lucide.FileText),
                      title: Text(l10n.workspaceFiles),
                      onTap: _openBrowser,
                    ),
                  ],
                ],
              ),
      ),
    );

    return Material(
      color: cs.surface,
      borderRadius: isDesktop
          ? BorderRadius.circular(16)
          : const BorderRadius.vertical(top: Radius.circular(22)),
      child: content,
    );
  }
}
