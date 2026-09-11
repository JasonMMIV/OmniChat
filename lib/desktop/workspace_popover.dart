import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/models/workspace_config.dart';
import '../core/providers/assistant_provider.dart';
import '../core/providers/settings_provider.dart';
import '../core/services/chat/chat_service.dart';
import '../core/services/workspace/workspace_resolver.dart';
import '../features/chat/pages/workspace_tools_page.dart';
import '../features/chat/widgets/workspace_file_browser.dart';
import '../features/chat/widgets/workspace_settings_dialog.dart';
import '../icons/lucide_adapter.dart';
import '../l10n/app_localizations.dart';
import '../shared/widgets/ios_switch.dart';

Future<void> showDesktopWorkspacePopover(
  BuildContext context, {
  required GlobalKey anchorKey,
  required String conversationId,
}) async {
  final overlay = Overlay.of(context);
  if (overlay == null) return;
  final keyContext = anchorKey.currentContext;
  if (keyContext == null) return;

  final box = keyContext.findRenderObject() as RenderBox?;
  if (box == null) return;
  final offset = box.localToGlobal(Offset.zero);
  final size = box.size;
  final anchorRect = Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height);

  final completer = Completer<void>();

  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (ctx) => _WorkspacePopover(
      anchorRect: anchorRect,
      conversationId: conversationId,
      onClose: () {
        try {
          entry.remove();
        } catch (_) {}
        if (!completer.isCompleted) completer.complete();
      },
    ),
  );
  overlay.insert(entry);
  return completer.future;
}

class _WorkspacePopover extends StatefulWidget {
  const _WorkspacePopover({
    required this.anchorRect,
    required this.conversationId,
    required this.onClose,
  });

  final Rect anchorRect;
  final String conversationId;
  final VoidCallback onClose;

  @override
  State<_WorkspacePopover> createState() => _WorkspacePopoverState();
}

class _WorkspacePopoverState extends State<_WorkspacePopover>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fadeIn;
  late final Animation<double> _slideY;
  bool _closing = false;

  String? _workspacePath;
  WorkspaceResolution? _resolution;
  bool _loading = true;
  bool _busy = false;

  ChatService get _chatService => context.read<ChatService>();

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
    final curve = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    );
    _fadeIn = curve;
    _slideY = Tween<double>(begin: 16.0, end: 0.0).animate(curve);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await _controller.forward();
      } catch (_) {}
    });
    _loadWorkspace();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
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

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    try {
      await _controller.reverse();
    } catch (_) {}
    if (mounted) widget.onClose();
  }

  /// Master enable/disable toggle for this conversation's workspace. The
  /// popover stays open so the directory/tools/files entries appear or
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
    if (mounted) await _close();
  }

  Future<void> _openDirectorySheet() async {
    if (_closing || _busy) return;
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
    if (_closing) return;
    // Capture the navigator before _close(): closing removes the popover's
    // OverlayEntry, which unmounts this State (same pattern as _openBrowser).
    final navigator = Navigator.of(context);
    await _close();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    await navigator.push(
      MaterialPageRoute(builder: (_) => const WorkspaceToolsPage()),
    );
  }

  Future<void> _openBrowser() async {
    if (_closing) return;
    final path = _workspacePath;
    if (path == null || _resolution?.enabled != true) return;
    // Capture the navigator before _close(): closing removes the popover's
    // OverlayEntry, which unmounts this State, so `mounted`/`context` are no
    // longer usable for pushing the file browser dialog afterwards.
    final navigator = Navigator.of(context);
    await _close();
    await Future<void>.delayed(const Duration(milliseconds: 80));
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
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.of(context).size;
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

    final width = 380.0.clamp(280.0, screen.width - 24.0);
    final top = (widget.anchorRect.bottom + 6.0).clamp(0.0, screen.height - 100.0);
    final maxHeight = (screen.height - top - 24.0).clamp(200.0, 560.0);
    final right = (screen.width - widget.anchorRect.right - 4.0)
        .clamp(12.0, screen.width - width - 12.0);

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _close,
          ),
        ),
        Positioned(
          right: right,
          top: top,
          width: width,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: FadeTransition(
              opacity: _fadeIn,
              child: AnimatedBuilder(
                animation: _slideY,
                builder: (context, child) => Transform.translate(
                  offset: Offset(0, -_slideY.value),
                  child: child,
                ),
                child: _GlassPanel(
                  borderRadius: BorderRadius.circular(14),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                    child: _loading
                        ? const SizedBox(
                            height: 180,
                            child: Center(child: CircularProgressIndicator()),
                          )
                        : SingleChildScrollView(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  l10n.workspaceTitle,
                                  style: const TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w700,
                                  ),
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
                                // Master switch: enable or disable the
                                // workspace for this conversation.
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
                                        onChanged: _busy
                                            ? null
                                            : _toggleWorkspace,
                                      ),
                                    ],
                                  ),
                                ),
                                // Directory, tools and files entries only
                                // exist while the workspace is enabled.
                                if (enabled) ...[
                                  const SizedBox(height: 8),
                                  ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    leading: const Icon(Lucide.FolderOpen),
                                    title: Text(
                                      l10n.workspaceDirectoryMenu,
                                    ),
                                    subtitle: Text(
                                      workspaceModeLabel(
                                        l10n,
                                        conversationConfig,
                                      ),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    trailing: const Icon(
                                      Lucide.ChevronRight,
                                    ),
                                    onTap: _busy ? null : _openDirectorySheet,
                                  ),
                                  ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    leading: const Icon(Lucide.Wrench),
                                    title: Text(l10n.workspaceToolsMenu),
                                    trailing: const Icon(
                                      Lucide.ChevronRight,
                                    ),
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
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _GlassPanel extends StatelessWidget {
  const _GlassPanel({required this.child, this.borderRadius});

  final Widget child;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final r = borderRadius ?? BorderRadius.circular(14);
    return ClipRRect(
      borderRadius: r,
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: (isDark ? const Color(0xFF1E2026) : Colors.white)
                .withOpacity(isDark ? 0.88 : 0.94),
            borderRadius: r,
            border: Border.all(
              color: isDark
                  ? Colors.white.withOpacity(0.10)
                  : Colors.black.withOpacity(0.08),
              width: 0.8,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(isDark ? 0.40 : 0.12),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Material(
            type: MaterialType.transparency,
            child: child,
          ),
        ),
      ),
    );
  }
}
