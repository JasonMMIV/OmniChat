import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:characters/characters.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import '../../../icons/lucide_adapter.dart';
import 'package:provider/provider.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/api/chat_api_service.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/models/chat_item.dart';
import '../../../core/models/conversation.dart';
import '../../../core/providers/user_provider.dart';

import '../../settings/pages/settings_page.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/update_provider.dart';
import '../../../core/models/assistant.dart';
import '../../assistant/pages/assistant_settings_edit_page.dart';
import '../../chat/pages/chat_history_page.dart';
import '../../../desktop/chat_history_dialog.dart';
import 'package:flutter/services.dart';
import 'dart:io' show File;
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:url_launcher/url_launcher.dart';
import 'package:intl/intl.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/snackbar.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:animations/animations.dart';
import '../../../utils/sandbox_path_resolver.dart';
import '../../../utils/avatar_cache.dart';
import 'dart:ui' as ui;
import '../../../shared/widgets/ios_tactile.dart';
import '../../../core/services/haptics.dart';
import '../../../desktop/desktop_context_menu.dart';
import '../../../desktop/menu_anchor.dart';
import '../../../shared/widgets/emoji_text.dart';
import '../../../core/providers/tag_provider.dart';
import '../../assistant/pages/tags_manager_page.dart';
import '../../assistant/widgets/tags_manager_dialog.dart';
import '../../assistant/widgets/assistant_select_sheet.dart';
import '../../../desktop/hotkeys/sidebar_tab_bus.dart';
import 'dart:async';

class SideDrawer extends StatefulWidget {
  const SideDrawer({
    super.key,
    required this.userName,
    required this.assistantName,
    this.onSelectConversation,
    this.onNewConversation,
    this.closePickerTicker,
    this.loadingConversationIds = const <String>{},
    this.embedded = false,
    this.embeddedWidth,
    this.showBottomBar = true,
  });

  final String userName;
  final String assistantName;
  final FutureOr<void> Function(String id, {bool closeDrawer})? onSelectConversation;
  final FutureOr<void> Function({bool closeDrawer})? onNewConversation;
  final ValueNotifier<int>? closePickerTicker;
  final Set<String> loadingConversationIds;
  final bool embedded; // when true, render as a fixed side panel instead of a Drawer
  final double? embeddedWidth; // optional explicit width for embedded mode
  final bool showBottomBar; // desktop can hide this bottom area

  @override
  State<SideDrawer> createState() => _SideDrawerState();
}

class _SideDrawerState extends State<SideDrawer> with TickerProviderStateMixin {
  bool get _isDesktop => defaultTargetPlatform == TargetPlatform.macOS || defaultTargetPlatform == TargetPlatform.windows || defaultTargetPlatform == TargetPlatform.linux;
  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  final GlobalKey _assistantTileKey = GlobalKey();
  OverlayEntry? _assistantPickerEntry;
  ValueNotifier<int>? _closeTicker;
  final ScrollController _listController = ScrollController();
  final Set<String> _expandedAssistantIds = {};
  final Set<String> _collapsedTags = {};


  @override
  void initState() {
    super.initState();
    _attachCloseTicker(widget.closePickerTicker);
    _searchController.addListener(() {
      if (_query != _searchController.text) {
        setState(() => _query = _searchController.text);
      }
    });
    
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final currentAssistantId = context.read<AssistantProvider>().currentAssistantId;
      if (currentAssistantId != null) {
        setState(() {
          _expandedAssistantIds.add(currentAssistantId);
        });
      }
    });
  }

  void _showChatMenu(BuildContext context, ChatItem chat, {Offset? anchor}) async {
    final l10n = AppLocalizations.of(context)!;
    final chatService = context.read<ChatService>();
    final isPinned = chatService.getConversation(chat.id)?.isPinned ?? false;
    final isDesktop = defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux;

    if (isDesktop) {
      // Desktop: glass anchored menu near cursor/button
      Offset pos = anchor ?? DesktopMenuAnchor.positionOrCenter(context);
      await showDesktopContextMenuAt(
        context,
        globalPosition: pos,
        items: [
          DesktopContextMenuItem(
            icon: Lucide.Edit,
            label: l10n.sideDrawerMenuRename,
            onTap: () async { await _renameChat(context, chat); },
          ),
          DesktopContextMenuItem(
            icon: Lucide.Pin,
            label: isPinned ? l10n.sideDrawerMenuUnpin : l10n.sideDrawerMenuPin,
            onTap: () async { await chatService.togglePinConversation(chat.id); },
          ),
          DesktopContextMenuItem(
            icon: Lucide.RefreshCw,
            label: l10n.sideDrawerMenuRegenerateTitle,
            onTap: () async { await _regenerateTitle(context, chat.id); },
          ),
          DesktopContextMenuItem(
            icon: Lucide.Shuffle,
            label: l10n.sideDrawerMenuMoveTo,
            onTap: () async {
              final conv = chatService.getConversation(chat.id);
              final movingCurrent = chatService.currentConversationId == chat.id;
              // Pre-compute next recent conversation for current assistant
              String? nextId;
              try {
                final ap = context.read<AssistantProvider>();
                final currentAid = ap.currentAssistantId;
                if (currentAid != null) {
                  final all = chatService.getAllConversations();
                  final candidates = all
                      .where((c) => c.assistantId == currentAid && c.id != chat.id)
                      .toList()
                    ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
                  if (candidates.isNotEmpty) nextId = candidates.first.id;
                }
              } catch (_) {}
              final targetId = await showAssistantMoveSelector(context, excludeAssistantId: conv?.assistantId);
              if (targetId != null) {
                await chatService.moveConversationToAssistant(conversationId: chat.id, assistantId: targetId);
                if (movingCurrent || chatService.currentConversationId == null) {
                  final closeDrawer = !context.read<SettingsProvider>().keepSidebarOpenOnTopicTap;
                  if (nextId != null) {
                    widget.onSelectConversation?.call(nextId!, closeDrawer: closeDrawer);
                  } else {
                    widget.onNewConversation?.call(closeDrawer: closeDrawer);
                  }
                }
              }
            },
          ),
          DesktopContextMenuItem(
            icon: Lucide.Trash2,
            label: l10n.sideDrawerMenuDelete,
            danger: true,
            onTap: () async {
              final confirmed = await _confirmDeleteConversation(context, chat);
              if (!confirmed) return;
              final deletingCurrent = chatService.currentConversationId == chat.id;
              final nextId = _nextRecentConversation(chatService, chat.id);
              await chatService.deleteConversation(chat.id);
              showAppSnackBar(
                context,
                message: l10n.sideDrawerDeleteSnackbar(chat.title),
                type: NotificationType.success,
                duration: const Duration(seconds: 3),
              );
              _handlePostDeleteNavigation(chatService: chatService, deletingCurrent: deletingCurrent, nextConversationId: nextId);
              Navigator.of(context).maybePop();
            },
          ),
        ],
      );
      return;
    }

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        final maxH = MediaQuery.sizeOf(ctx).height * 0.8;
        Widget row({required IconData icon, required String label, Color? color, required Future<void> Function() action}) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: SizedBox(
              height: 48,
              child: IosCardPress(
                borderRadius: BorderRadius.circular(14),
                baseColor: cs.surface,
                duration: const Duration(milliseconds: 260),
                onTap: () async {
                  Haptics.light();
                  Navigator.of(ctx).pop();
                  await Future<void>.delayed(const Duration(milliseconds: 10));
                  await action();
                },
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    Icon(icon, size: 20, color: color ?? cs.onSurface),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        label,
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: color ?? cs.onSurface),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }
        return SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxH),
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: cs.onSurface.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    row(
                      icon: Lucide.Edit,
                      label: l10n.sideDrawerMenuRename,
                      action: () async { _renameChat(context, chat); },
                    ),
                    row(
                      icon: Lucide.Pin,
                      label: isPinned ? l10n.sideDrawerMenuUnpin : l10n.sideDrawerMenuPin,
                      action: () async { await chatService.togglePinConversation(chat.id); },
                    ),
                    row(
                      icon: Lucide.RefreshCw,
                      label: l10n.sideDrawerMenuRegenerateTitle,
                      action: () async { await _regenerateTitle(context, chat.id); },
                    ),
                    row(
                      icon: Lucide.Shuffle,
                      label: l10n.sideDrawerMenuMoveTo,
                      action: () async {
                        final conv = chatService.getConversation(chat.id);
                        final movingCurrent = chatService.currentConversationId == chat.id;
                        // Pre-compute next recent conversation for current assistant
                        String? nextId;
                        try {
                          final ap = context.read<AssistantProvider>();
                          final currentAid = ap.currentAssistantId;
                          if (currentAid != null) {
                            final all = chatService.getAllConversations();
                            final candidates = all
                                .where((c) => c.assistantId == currentAid && c.id != chat.id)
                                .toList()
                              ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
                            if (candidates.isNotEmpty) nextId = candidates.first.id;
                          }
                        } catch (_) {}
                        final targetId = await showAssistantMoveSelector(context, excludeAssistantId: conv?.assistantId);
                        if (targetId != null) {
                          await chatService.moveConversationToAssistant(conversationId: chat.id, assistantId: targetId);
                          if (movingCurrent || chatService.currentConversationId == null) {
                            final closeDrawer = !context.read<SettingsProvider>().keepSidebarOpenOnTopicTap;
                            if (nextId != null) {
                              widget.onSelectConversation?.call(nextId!, closeDrawer: closeDrawer);
                            } else {
                              widget.onNewConversation?.call(closeDrawer: closeDrawer);
                            }
                          }
                        }
                      },
                    ),
                    row(
                      icon: Lucide.Trash,
                      label: l10n.sideDrawerMenuDelete,
                      color: Colors.redAccent,
                      action: () async {
                        final confirmed = await _confirmDeleteConversation(context, chat);
                        if (!confirmed) return;
                        final deletingCurrent = chatService.currentConversationId == chat.id;
                        final nextId = _nextRecentConversation(chatService, chat.id);
                        await chatService.deleteConversation(chat.id);
                        showAppSnackBar(
                          context,
                          message: l10n.sideDrawerDeleteSnackbar(chat.title),
                          type: NotificationType.success,
                          duration: const Duration(seconds: 3),
                        );
                        _handlePostDeleteNavigation(chatService: chatService, deletingCurrent: deletingCurrent, nextConversationId: nextId);
                        Navigator.of(context).maybePop();
                      },
                    ),
                    const SizedBox(height: 4),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  String? _nextRecentConversation(ChatService chatService, String excludeId) {
    try {
      final ap = context.read<AssistantProvider>();
      final currentAid = ap.currentAssistantId;
      if (currentAid == null) return null;
      final candidates = chatService
          .getAllConversations()
          .where((c) => c.assistantId == currentAid && c.id != excludeId)
          .toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      if (candidates.isEmpty) return null;
      return candidates.first.id;
    } catch (_) {
      return null;
    }
  }

  void _handlePostDeleteNavigation({
    required ChatService chatService,
    required bool deletingCurrent,
    required String? nextConversationId,
  }) {
    if (!(deletingCurrent || chatService.currentConversationId == null)) return;
    final closeDrawer = !context.read<SettingsProvider>().keepSidebarOpenOnTopicTap;
    final preferNewChat = context.read<SettingsProvider>().newChatAfterDelete;
    if (preferNewChat && widget.onNewConversation != null) {
      widget.onNewConversation!.call(closeDrawer: closeDrawer);
      return;
    }
    if (!preferNewChat && nextConversationId != null) {
      widget.onSelectConversation?.call(nextConversationId, closeDrawer: closeDrawer);
      return;
    }
    if (widget.onNewConversation != null) {
      widget.onNewConversation!.call(closeDrawer: closeDrawer);
      return;
    }
    if (nextConversationId != null) {
      widget.onSelectConversation?.call(nextConversationId, closeDrawer: closeDrawer);
    }
  }

  Future<void> _renameChat(BuildContext context, ChatItem chat) async {
    final controller = TextEditingController(text: chat.title);
    final l10n = AppLocalizations.of(context)!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(l10n.sideDrawerMenuRename),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              hintText: l10n.sideDrawerRenameHint,
            ),
            onSubmitted: (_) => Navigator.of(ctx).pop(true),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(l10n.sideDrawerCancel),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(l10n.sideDrawerOK),
            ),
          ],
        );
      },
    );
    if (ok == true) {
      await context.read<ChatService>().renameConversation(chat.id, controller.text.trim());
    }
  }

  Future<bool> _confirmDeleteConversation(BuildContext context, ChatItem chat) async {

    final l10n = AppLocalizations.of(context)!;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.sideDrawerDeleteConfirmTitle),
        content: Text(l10n.sideDrawerDeleteConfirmContent(chat.title)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.chatMessageWidgetRegenerateConfirmCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              l10n.chatMessageWidgetDeleteConfirmDelete,
              style: const TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
    return confirm ?? false;
  }


  Future<void> _regenerateTitle(BuildContext context, String conversationId) async {
    final settings = context.read<SettingsProvider>();
    final chatService = context.read<ChatService>();
    final convo = chatService.getConversation(conversationId);
    if (convo == null) return;
    // Decide model
    final provKey = settings.titleModelProvider ?? settings.currentModelProvider;
    final mdlId = settings.titleModelId ?? settings.currentModelId;
    if (provKey == null || mdlId == null) return;
    final cfg = settings.getProviderConfig(provKey);
    // Content
    final msgs = chatService.getMessages(conversationId);
    final joined = msgs.where((m) => m.content.isNotEmpty).map((m) => '${m.role == 'assistant' ? 'Assistant' : 'User'}: ${m.content}').join('\n\n');
    final content = joined.length > 3000 ? joined.substring(0, 3000) : joined;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final prompt = settings.titlePrompt.replaceAll('{locale}', locale).replaceAll('{content}', content);
    try {
      final assistant = convo.assistantId != null ? context.read<AssistantProvider>().getById(convo.assistantId!) : null;
      final title = (await ChatApiService.generateText(
        config: cfg,
        modelId: mdlId,
        prompt: prompt,
        thinkingBudget: settings.titleGenerationThinkingBudgetFor(assistant?.thinkingBudget),
      )).trim();

      if (title.isNotEmpty) {
        await chatService.renameConversation(conversationId, title);
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _assistantPickerEntry?.remove();
    _assistantPickerEntry = null;
    _closeTicker?.removeListener(_handleCloseTick);
    _searchController.dispose();
    _listController.dispose();
    super.dispose();
  }

  @override
  void deactivate() {
    super.deactivate();
  }

  @override
  void didUpdateWidget(covariant SideDrawer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.closePickerTicker != widget.closePickerTicker) {
      _attachCloseTicker(widget.closePickerTicker);
    }
  }

  void _attachCloseTicker(ValueNotifier<int>? ticker) {
    if (_closeTicker == ticker) return;
    _closeTicker?.removeListener(_handleCloseTick);
    _closeTicker = ticker;
    _closeTicker?.addListener(_handleCloseTick);
  }

  void _handleCloseTick() {
  }


  String _greeting(BuildContext context) {
    final hour = DateTime.now().hour;
    final l10n = AppLocalizations.of(context)!;
    if (hour < 11) return l10n.sideDrawerGreetingMorning;
    if (hour < 13) return l10n.sideDrawerGreetingNoon;
    if (hour < 18) return l10n.sideDrawerGreetingAfternoon;
    return l10n.sideDrawerGreetingEvening;
  }

  String _dateLabel(BuildContext context, DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final aDay = DateTime(date.year, date.month, date.day);
    final diff = today.difference(aDay).inDays;
    final l10n = AppLocalizations.of(context)!;
    if (diff == 0) return l10n.sideDrawerDateToday;
    if (diff == 1) return l10n.sideDrawerDateYesterday;
    final sameYear = now.year == date.year;
    final pattern = sameYear ? l10n.sideDrawerDateShortPattern : l10n.sideDrawerDateFullPattern;
    final fmt = DateFormat(pattern);
    return fmt.format(date);
  }

  List<_ChatGroup> _groupByDate(BuildContext context, List<ChatItem> source) {
    final items = [...source];
    // group by day (truncate time)
    final map = <DateTime, List<ChatItem>>{};
    for (final c in items) {
      final d = DateTime(c.created.year, c.created.month, c.created.day);
      map.putIfAbsent(d, () => []).add(c);
    }
    // sort groups by date desc (recent first)
    final keys = map.keys.toList()
      ..sort((a, b) => b.compareTo(a));
    return [
      for (final k in keys)
        _ChatGroup(
          label: _dateLabel(context, k),
          items: (map[k]!..sort((a, b) => b.created.compareTo(a.created)))!,
        )
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final l10n = AppLocalizations.of(context)!;
    final textBase = isDark ? Colors.white : Colors.black; // 纯黑（白天），夜间自动适配
    final chatService = context.watch<ChatService>();
    final ap = context.watch<AssistantProvider>();


    // Avatar renderer: emoji / url / file / default initial
    Widget avatarWidget(String name, UserProvider up, {double size = 40}) {
      final type = up.avatarType;
      final value = up.avatarValue;
      if (type == 'emoji' && value != null && value.isNotEmpty) {
        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: cs.primary.withOpacity(0.15),
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: EmojiText(
            value,
            fontSize: size * 0.5,
            optimizeEmojiAlign: true,
          ),
        );
      }
      if (type == 'url' && value != null && value.isNotEmpty) {
        return FutureBuilder<String?>(
          future: AvatarCache.getPath(value),
          builder: (ctx, snap) {
            final p = snap.data;
            if (p != null && File(p).existsSync()) {
              return ClipOval(
                child: Image(
                  image: FileImage(File(p)),
                  width: size,
                  height: size,
                  fit: BoxFit.cover,
                ),
              );
            }
            return ClipOval(
              child: Image.network(
                value,
                width: size,
                height: size,
                fit: BoxFit.cover,
                errorBuilder: (c, e, s) => Container(
                  width: size,
                  height: size,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: cs.primary.withOpacity(0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Text('?', style: TextStyle(color: cs.primary, fontSize: size * 0.42, fontWeight: FontWeight.w700)),
                ),
              ),
            );
          },
        );
      }
      if (type == 'file' && value != null && value.isNotEmpty && !kIsWeb) {
        final fixed = SandboxPathResolver.fix(value);
        final f = File(fixed);
        if (f.existsSync()) {
          return ClipOval(
            child: Image(
              image: FileImage(f),
              width: size,
              height: size,
              fit: BoxFit.cover,
            ),
          );
        }
      }
      // default: initial
      final letter = name.isNotEmpty ? name.characters.first : '?';
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: cs.primary.withOpacity(0.15),
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Text(
          letter,
          style: TextStyle(
            color: cs.primary,
            fontSize: size * 0.42,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    }

    // Desktop-only: enable tabs for embedded sidebar when requested
    const bool _assistOnly = false;
    const bool _topicsOnly = false;
    const bool _useTabs = false;

    final inner = SafeArea(
      child: Stack(
        children: [
            // Main column content
            Column(
              children: [
            // Fixed header + search
            Padding(
              padding: EdgeInsets.fromLTRB(16, _isDesktop ? 10 : 4, 16, 0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 1. 搜索框 + 历史按钮（固定头部）
                  if (_isDesktop)
                    // 桌面端
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 240),
                        switchInCurve: Curves.easeOutCubic,
                        switchOutCurve: Curves.easeInCubic,
                        transitionBuilder: (child, anim) => FadeTransition(opacity: anim, child: child),
                        child: Row(
                          key: ValueKey<String>(AppLocalizations.of(context)!.sideDrawerSearchHint),
                          children: [
                          Expanded(
                            child: TextField(
                              controller: _searchController,
                              decoration: InputDecoration(
                                hintText: AppLocalizations.of(context)!.sideDrawerSearchHint,
                                filled: true,
                                fillColor: isDark ? Colors.white10 : Colors.grey.shade200.withOpacity(0.80),
                                isDense: true,
                                isCollapsed: true,
                                prefixIcon: Padding(
                                  padding: const EdgeInsets.only(left: 10, right: 4),
                                  child: Icon(
                                    Lucide.Search,
                                    size: 16,
                                    color: textBase.withOpacity(0.6),
                                  ),
                                ),
                                prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
                                suffixIcon: Padding(
                                  padding: const EdgeInsets.only(right: 6),
                                  child: IosIconButton(
                                    size: 20,
                                    color: textBase,
                                    icon: Lucide.History,
                                    padding: const EdgeInsets.all(4),
                                    onTap: () async {
                                      final selectedId = await showChatHistoryDesktopDialog(context);
                                      if (selectedId != null && selectedId.isNotEmpty) {
                                        final closeDrawer = !context.read<SettingsProvider>().keepSidebarOpenOnTopicTap;
                                        widget.onSelectConversation?.call(selectedId, closeDrawer: closeDrawer);
                                      }
                                    },
                                  ),
                                ),
                                suffixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 11,
                                ),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(14),
                                  borderSide: const BorderSide(color: Colors.transparent),
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(14),
                                  borderSide: const BorderSide(color: Colors.transparent),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(14),
                                  borderSide: const BorderSide(color: Colors.transparent),
                                ),
                              ),
                              textAlignVertical: TextAlignVertical.center,
                              style: TextStyle(color: textBase, fontSize: 14),
                            ),
                          ),
                        ],
                      ),
                      ),
                    )
                  else
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _searchController,
                            decoration: InputDecoration(
                              hintText: AppLocalizations.of(context)!.sideDrawerSearchHint,
                              filled: true,
                              fillColor: isDark ? Colors.white10 : Colors.grey.shade200.withOpacity(0.80),
                              isDense: true,
                              isCollapsed: true,
                              prefixIcon: Padding(
                                padding: const EdgeInsets.only(left: 10, right: 4),
                                child: Icon(
                                  Lucide.Search,
                                  size: 16,
                                  color: textBase.withOpacity(0.6),
                                ),
                              ),
                              prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 10,
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(16),
                                borderSide: const BorderSide(color: Colors.transparent),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(16),
                                borderSide: const BorderSide(color: Colors.transparent),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(16),
                                borderSide: const BorderSide(color: Colors.transparent),
                              ),
                            ),
                            textAlignVertical: TextAlignVertical.center,
                            style: TextStyle(color: textBase, fontSize: 14),
                          ),
                        ),
                        const SizedBox(width: 8),
                        // 历史按钮（圆形，无水波纹）
                        SizedBox(
                          width: 44,
                          height: 44,
                          child: Center(
                            child: IosIconButton(
                              size: 24,
                              color: textBase,
                              icon: Lucide.History,
                              padding: const EdgeInsets.all(6),
                              onTap: () async {
                                  final selectedId = await Navigator.of(context).push<String>(
                                    MaterialPageRoute(builder: (_) => const ChatHistoryPage()),
                                  );
                                if (selectedId != null && selectedId.isNotEmpty) {
                                  final closeDrawer = !context.read<SettingsProvider>().keepSidebarOpenOnTopicTap;
                                  widget.onSelectConversation?.call(selectedId, closeDrawer: closeDrawer);
                                }
                              },
                            ),
                          ),
                        ),
                      ],
                    ),

                  SizedBox(height: _isDesktop ? 8 : 12),
                ],
              ),
            ),

            // Scrollable area below header
            Expanded(
              child: ListView(
                controller: _listController,
                padding: const EdgeInsets.fromLTRB(10, 4, 10, 16),
                children: [
                  _buildFolderTreeList(context),
                ],
              ),
            ),

            if (widget.showBottomBar) Container(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              decoration: BoxDecoration(
                color: widget.embedded ? Colors.transparent : cs.surface,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      const SizedBox(width: 6),
                      // 用户头像（可点击更换）—移除水波纹
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _editAvatar(context),
                        child: avatarWidget(
                          widget.userName,
                          context.watch<UserProvider>(),
                          size: 40,
                        ),
                      ),
                      const SizedBox(width: 20),
                      // 用户名称（可点击编辑，垂直居中）
                      Expanded(
                        child: IosCardPress(
                          borderRadius: BorderRadius.circular(6),
                          baseColor: Colors.transparent,
                          onTap: () => _editUserName(context),
                          padding: const EdgeInsets.symmetric(horizontal: 0),
                          child: SizedBox(
                            height: 45,
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                widget.userName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: _isDesktop ? 14 : 16,
                                  fontWeight: FontWeight.w700,
                                  color: textBase,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // 设置按钮（圆形，无水波纹）
                      SizedBox(
                        width: 45,
                        height: 45,
                        child: Center(
                          child: IosIconButton(
                            size: 26,
                            color: textBase,
                            icon: Lucide.Settings,
                            padding: const EdgeInsets.all(8),
                            onTap: () {
                              Navigator.of(context).push(
                                MaterialPageRoute(builder: (_) => const SettingsPage()),
                              );
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
              ],
            ),

            // iOS-style blur/fade effect above user area
            if (!widget.embedded)
              Positioned(
                left: 0,
                right: 0,
                bottom: 62, // Approximate height of user area
                child: IgnorePointer(
                  child: Container(
                    height: 20,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          cs.surface.withOpacity(0.0),
                          cs.surface.withOpacity(0.8),
                          cs.surface.withOpacity(1.0),
                        ],
                        stops: const [0.0, 0.6, 1.0],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );

    if (widget.embedded) {
      return ClipRect(
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 6, sigmaY: 6),
          child: Material(
            color: cs.surface.withOpacity(0.60),
            child: SizedBox(
              width: widget.embeddedWidth ?? 300,
              child: inner,
            ),
          ),
        ),
      );
    }

    return Drawer(
      backgroundColor: cs.surface,
      width: MediaQuery.sizeOf(context).width,
      child: inner,
    );
  }

  void _handleToggleAssistant(String assistantId) {
    setState(() {
      if (_expandedAssistantIds.contains(assistantId)) {
        _expandedAssistantIds.remove(assistantId);
      } else {
        _expandedAssistantIds.clear();
        _expandedAssistantIds.add(assistantId);
      }
    });
  }

  Future<void> _handleNewConversationForAssistant(BuildContext context, Assistant assistant) async {
    final sp = context.read<SettingsProvider>();
    final closeDrawer = !sp.keepSidebarOpenOnTopicTap;
    await context.read<AssistantProvider>().setCurrentAssistant(assistant.id);
    setState(() {
      _expandedAssistantIds.clear();
      _expandedAssistantIds.add(assistant.id);
    });
    widget.onNewConversation?.call(closeDrawer: closeDrawer);
  }

  Future<void> _handleNewProject() async {
    final name = await _promptNewProjectName(context);
    if (name == null || name.trim().isEmpty || !mounted) return;
    final ap = context.read<AssistantProvider>();
    final id = await ap.addAssistant(name: name.trim(), context: context);
    if (!mounted) return;
    await ap.setCurrentAssistant(id);
    if (!mounted) return;
    setState(() {
      _expandedAssistantIds.clear();
      _expandedAssistantIds.add(id);
    });
  }

  Future<String?> _promptNewProjectName(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final controller = TextEditingController();
    if (_isDesktop) {
      return showDialog<String>(
        context: context,
        barrierDismissible: true,
        builder: (ctx) => Dialog(
          backgroundColor: cs.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 8, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          l10n.sideDrawerNewProject,
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                        ),
                      ),
                      IosIconButton(
                        size: 18,
                        color: cs.onSurface,
                        icon: Lucide.X,
                        padding: const EdgeInsets.all(6),
                        onTap: () => Navigator.of(ctx).pop(),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: controller,
                        autofocus: true,
                        decoration: InputDecoration(
                          hintText: l10n.assistantSettingsAddSheetHint,
                          filled: true,
                          fillColor: isDark ? Colors.white10 : const Color(0xFFF2F3F5),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: Colors.transparent),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: Colors.transparent),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: cs.primary.withOpacity(0.4)),
                          ),
                        ),
                        onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: () => Navigator.of(ctx).pop(),
                            child: Text(l10n.assistantSettingsAddSheetCancel),
                          ),
                          const SizedBox(width: 8),
                          TextButton(
                            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
                            child: Text(
                              l10n.assistantSettingsAddSheetSave,
                              style: TextStyle(color: cs.primary, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    // Mobile: bottom sheet (matches app convention)
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: cs.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        final bottomInset = MediaQuery.of(ctx).viewInsets.bottom;
        return SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.only(left: 16, right: 16, top: 12, bottom: bottomInset + 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: cs.onSurface.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Center(
                  child: Text(
                    l10n.sideDrawerNewProject,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: l10n.assistantSettingsAddSheetHint,
                    filled: true,
                    fillColor: isDark ? Colors.white10 : const Color(0xFFF2F3F5),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: cs.outlineVariant.withOpacity(0.4)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: cs.outlineVariant.withOpacity(0.4)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: cs.primary.withOpacity(0.5)),
                    ),
                  ),
                  onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        child: Text(l10n.assistantSettingsAddSheetCancel),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
                        child: Text(l10n.assistantSettingsAddSheetSave),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _openAssistantSettings(String id) {
    final isDesktop = defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux;
    if (isDesktop) {
      // Use desktop modal dialog for assistant editing on desktop
      showAssistantDesktopDialog(context, assistantId: id);
      return;
    }
    // Fallback to mobile edit page on non-desktop platforms
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => AssistantSettingsEditPage(assistantId: id)),
    );
  }

}

extension on _SideDrawerState {
  Future<void> _showAssistantItemMenuDesktop(Assistant a, Offset globalPosition) async {
    if (!_isDesktop) return;
    final l10n = AppLocalizations.of(context)!;
    final tp = context.read<TagProvider>();
    final hasTag = tp.tagOfAssistant(a.id) != null;
    await showDesktopContextMenuAt(
      context,
      globalPosition: globalPosition,
      items: [
        DesktopContextMenuItem(
          icon: Lucide.Pencil,
          label: l10n.assistantTagsContextMenuEditAssistant,
          onTap: () => _openAssistantSettings(a.id),
        ),
        if (hasTag)
          DesktopContextMenuItem(
            icon: Lucide.Eraser,
            label: l10n.assistantTagsClearTag,
            onTap: () async {
              await context.read<TagProvider>().unassignAssistant(a.id);
            },
          ),
        DesktopContextMenuItem(
          icon: Lucide.Bookmark,
          label: l10n.assistantTagsContextMenuManageTags,
          onTap: () async {
            await showAssistantTagsManagerDialog(context, assistantId: a.id);
          },
        ),
        DesktopContextMenuItem(
          icon: Lucide.Trash2,
          label: l10n.assistantTagsContextMenuDeleteAssistant,
          danger: true,
          onTap: () async {
            final confirmed = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: Text(l10n.assistantSettingsDeleteDialogTitle),
                content: Text(l10n.assistantSettingsDeleteDialogContent),
                actions: [
                  TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(l10n.assistantSettingsDeleteDialogCancel)),
                  TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(l10n.assistantSettingsDeleteDialogConfirm)),
                ],
              ),
            );
            if (confirmed != true) return;
            final ok = await context.read<AssistantProvider>().deleteAssistant(a.id);
            if (!ok) {
              showAppSnackBar(context, message: l10n.assistantSettingsAtLeastOneAssistantRequired, type: NotificationType.warning);
            } else {
              try { await context.read<TagProvider>().unassignAssistant(a.id); } catch (_) {}
            }
          },
        ),
      ],
    );
  }

  Future<void> _showAssistantItemMenuMobile(Assistant a) async {
    if (_isDesktop) return;
    final l10n = AppLocalizations.of(context)!;
    final tp = context.read<TagProvider>();
    final hasTag = tp.tagOfAssistant(a.id) != null;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: false,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        Widget row(String text, IconData icon, VoidCallback onTap, {bool danger = false}) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: SizedBox(
              height: 48,
              child: IosCardPress(
                borderRadius: BorderRadius.circular(14),
                baseColor: cs.surface,
                duration: const Duration(milliseconds: 220),
                onTap: () {
                  Navigator.of(ctx).pop();
                  onTap();
                },
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    Icon(icon, size: 18, color: danger ? cs.error : cs.primary),
                    const SizedBox(width: 10),
                    Expanded(child: Text(text, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500))),
                  ],
                ),
              ),
            ),
          );
        }
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                row(l10n.assistantTagsContextMenuEditAssistant, Lucide.Pencil, () => _openAssistantSettings(a.id)),
                if (hasTag)
                  row(l10n.assistantTagsClearTag, Lucide.Eraser, () async {
                    await context.read<TagProvider>().unassignAssistant(a.id);
                  }),
                row(l10n.assistantTagsContextMenuManageTags, Lucide.Bookmark, () async {
                  // Navigate to manage tags page
                  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => TagsManagerPage(assistantId: a.id)));
                }),
                row(l10n.assistantTagsContextMenuDeleteAssistant, Lucide.Trash2, () async {
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (ctx2) => AlertDialog(
                      title: Text(l10n.assistantSettingsDeleteDialogTitle),
                      content: Text(l10n.assistantSettingsDeleteDialogContent),
                      actions: [
                        TextButton(onPressed: () => Navigator.of(ctx2).pop(false), child: Text(l10n.assistantSettingsDeleteDialogCancel)),
                        TextButton(onPressed: () => Navigator.of(ctx2).pop(true), child: Text(l10n.assistantSettingsDeleteDialogConfirm)),
                      ],
                    ),
                  );
                  if (confirmed != true) return;
                  final ok = await context.read<AssistantProvider>().deleteAssistant(a.id);
                  if (!ok) {
                    showAppSnackBar(context, message: l10n.assistantSettingsAtLeastOneAssistantRequired, type: NotificationType.warning);
                  } else {
                    try { await context.read<TagProvider>().unassignAssistant(a.id); } catch (_) {}
                  }
                }, danger: true),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _editAvatar(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        final maxH = MediaQuery.sizeOf(ctx).height * 0.8;
        Widget row(String text, VoidCallback onTap) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: SizedBox(
              height: 48,
              child: IosCardPress(
                borderRadius: BorderRadius.circular(14),
                baseColor: cs.surface,
                duration: const Duration(milliseconds: 260),
                onTap: () async {
                  Haptics.light();
                  Navigator.of(ctx).pop();
                  await Future<void>.delayed(const Duration(milliseconds: 10));
                  onTap();
                },
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(text, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                ),
              ),
            ),
          );
        }
        return SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxH),
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: cs.onSurface.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    row(l10n.sideDrawerChooseImage, () async { await _pickLocalImage(context); }),
                    row(l10n.sideDrawerChooseEmoji, () async {
                      final emoji = await _pickEmoji(context);
                      if (emoji != null) {
                        await context.read<UserProvider>().setAvatarEmoji(emoji);
                      }
                    }),
                    row(l10n.sideDrawerEnterLink, () async { await _inputAvatarUrl(context); }),
                    row(l10n.sideDrawerReset, () async { await context.read<UserProvider>().resetAvatar(); }),
                    const SizedBox(height: 4),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<String?> _pickEmoji(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    // Provide input to allow any emoji via system emoji keyboard,
    // plus a large set of quick picks for convenience.
    final controller = TextEditingController();
    String value = '';
    bool validGrapheme(String s) {
      final trimmed = s.characters.take(1).toString().trim();
      return trimmed.isNotEmpty && trimmed == s.trim();
    }
    final List<String> quick = const [
      '😀','😁','😂','🤣','😃','😄','😅','😊','😍','😘','😗','😙','😚','🙂','🤗','🤩','🫶','🤝','👍','👎','👋','🙏','💪','🔥','✨','🌟','💡','🎉','🎊','🎈','🌈','☀️','🌙','⭐','⚡','☁️','❄️','🌧️','🍎','🍊','🍋','🍉','🍇','🍓','🍒','🍑','🥭','🍍','🥝','🍅','🥕','🌽','🍞','🧀','🍔','🍟','🍕','🌮','🌯','🍣','🍜','🍰','🍪','🍩','🍫','🍻','☕','🧋','🥤','⚽','🏀','🏈','🎾','🏐','🎮','🎧','🎸','🎹','🎺','📚','✏️','💼','💻','🖥️','📱','🛩️','✈️','🚗','🚕','🚙','🚌','🚀','🛰️','🧠','🫀','💊','🩺','🐶','🐱','🐭','🐹','🐰','🦊','🐻','🐼','🐨','🐯','🦁','🐮','🐷','🐸','🐵'
    ];
    return showDialog<String>(
      context: context,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return StatefulBuilder(builder: (ctx, setLocal) {
          // Revert to non-scrollable dialog but cap grid height
          // based on available height when keyboard is visible.
          final size = MediaQuery.sizeOf(ctx);
          final viewInsets = MediaQuery.viewInsetsOf(ctx);
          final avail = size.height - viewInsets.bottom;
          final double gridHeight = (avail * 0.28).clamp(120.0, 220.0);
          return AlertDialog(
            scrollable: true,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            backgroundColor: cs.surface,
            title: Text(l10n.sideDrawerEmojiDialogTitle),
            content: SizedBox(
              width: 360,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color: cs.primary.withOpacity(0.08),
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: EmojiText(
                      value.isEmpty ? '🙂' : value.characters.take(1).toString(),
                      fontSize: 40,
                      optimizeEmojiAlign: true,
                      nudge: Offset.zero, // mobile/desktop picker preview: no extra nudge
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: controller,
                    autofocus: true,
                    onChanged: (v) => setLocal(() => value = v),
                    onSubmitted: (_) {
                      if (validGrapheme(value)) Navigator.of(ctx).pop(value.characters.take(1).toString());
                    },
                    decoration: InputDecoration(
                      hintText: l10n.sideDrawerEmojiDialogHint,
                      filled: true,
                      fillColor: Theme.of(ctx).brightness == Brightness.dark ? Colors.white10 : const Color(0xFFF2F3F5),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: Colors.transparent),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: Colors.transparent),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: cs.primary.withOpacity(0.4)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: gridHeight,
                    child: GridView.builder(
                      shrinkWrap: true,
                      padding: EdgeInsets.zero,
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 8,
                        mainAxisSpacing: 8,
                        crossAxisSpacing: 8,
                      ),
                      itemCount: quick.length,
                      itemBuilder: (c, i) {
                        final e = quick[i];
                        return InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () => Navigator.of(ctx).pop(e),
                          child: Container(
                            decoration: BoxDecoration(
                              color: cs.primary.withOpacity(0.08),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            alignment: Alignment.center,
                            child: EmojiText(
                              e,
                              fontSize: 20,
                              optimizeEmojiAlign: true,
                              nudge: Offset.zero, // picker grid: no extra nudge
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: Text(l10n.sideDrawerCancel),
              ),
              TextButton(
                onPressed: validGrapheme(value) ? () => Navigator.of(ctx).pop(value.characters.take(1).toString()) : null,
                child: Text(
                  l10n.sideDrawerSave,
                  style: TextStyle(
                    color: validGrapheme(value) ? cs.primary : cs.onSurface.withOpacity(0.38),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          );
        });
      },
    );
  }

  Future<void> _inputAvatarUrl(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        bool valid(String s) => s.trim().startsWith('http://') || s.trim().startsWith('https://');
        String value = '';
        return StatefulBuilder(builder: (ctx, setLocal) {
          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            backgroundColor: cs.surface,
            title: Text(l10n.sideDrawerImageUrlDialogTitle),
            content: TextField(
              controller: controller,
              autofocus: true,
              decoration: InputDecoration(
                hintText: l10n.sideDrawerImageUrlDialogHint,
                filled: true,
                fillColor: Theme.of(ctx).brightness == Brightness.dark ? Colors.white10 : const Color(0xFFF2F3F5),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.transparent),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.transparent),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: cs.primary.withOpacity(0.4)),
                ),
              ),
              onChanged: (v) => setLocal(() => value = v),
              onSubmitted: (_) {
                if (valid(value)) Navigator.of(ctx).pop(true);
              },
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: Text(l10n.sideDrawerCancel),
              ),
              TextButton(
                onPressed: valid(value) ? () => Navigator.of(ctx).pop(true) : null,
                child: Text(
                  l10n.sideDrawerSave,
                  style: TextStyle(
                    color: valid(value) ? cs.primary : cs.onSurface.withOpacity(0.38),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          );
        });
      },
    );
    if (ok == true) {
      final url = controller.text.trim();
      if (url.isNotEmpty) {
        await context.read<UserProvider>().setAvatarUrl(url);
      }
    }
  }

  Future<void> _pickLocalImage(BuildContext context) async {
    if (kIsWeb) {
      await _inputAvatarUrl(context);
      return;
    }
    try {
      final picker = ImagePicker();
      final XFile? file = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1024,
        imageQuality: 90,
      );
      if (!mounted) return;
      if (file != null) {
        await context.read<UserProvider>().setAvatarFilePath(file.path);
        return;
      }
    } on PlatformException catch (e) {
      // Gracefully degrade when plugin channel isn't available or permission denied.
      if (!mounted) return;
      final l10n = AppLocalizations.of(context)!;
      showAppSnackBar(
        context,
        message: l10n.sideDrawerGalleryOpenError,
        type: NotificationType.error,
      );
      await _inputAvatarUrl(context);
      return;
    } catch (_) {
      if (!mounted) return;
      final l10n = AppLocalizations.of(context)!;
      showAppSnackBar(
        context,
        message: l10n.sideDrawerGeneralImageError,
        type: NotificationType.error,
      );
      await _inputAvatarUrl(context);
      return;
    }
  }
  Future<void> _editUserName(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final initial = widget.userName;
    final controller = TextEditingController(text: initial);
    const maxLen = 24;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        final isDark = Theme.of(ctx).brightness == Brightness.dark;
        String value = controller.text;
        bool valid(String v) => v.trim().isNotEmpty && v.trim() != initial;
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              backgroundColor: cs.surface,
              title: Text(l10n.sideDrawerSetNicknameTitle),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 4),
                  TextField(
                    controller: controller,
                    autofocus: true,
                    maxLength: maxLen,
                    textInputAction: TextInputAction.done,
                    onChanged: (v) => setLocal(() => value = v),
                    onSubmitted: (_) {
                      if (valid(value)) Navigator.of(ctx).pop(true);
                    },
                    decoration: InputDecoration(
                      labelText: l10n.sideDrawerNicknameLabel,
                      hintText: l10n.sideDrawerNicknameHint,
                      filled: true,
                      fillColor: isDark ? Colors.white10 : const Color(0xFFF2F3F5),
                      counterText: '',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: Colors.transparent),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: Colors.transparent),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: cs.primary.withOpacity(0.4)),
                      ),
                    ),
                    style: TextStyle(fontSize: 15, color: Theme.of(ctx).textTheme.bodyMedium?.color),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      '${value.trim().length}/$maxLen',
                      style: TextStyle(color: cs.onSurface.withOpacity(0.45), fontSize: 12),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: Text(l10n.sideDrawerCancel),
                ),
                TextButton(
                  onPressed: valid(value) ? () => Navigator.of(ctx).pop(true) : null,
                  child: Text(
                    l10n.sideDrawerSave,
                    style: TextStyle(
                      color: valid(value) ? cs.primary : cs.onSurface.withOpacity(0.38),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  if (ok == true) {
      final text = controller.text.trim();
      if (text.isNotEmpty) {
        await context.read<UserProvider>().setName(text);
      }
    }
  }

  Widget _buildFolderTreeList(BuildContext context) {
    final ap = context.watch<AssistantProvider>();
    final tp = context.watch<TagProvider>();
    final chatService = context.watch<ChatService>();
    final showChatListDate = context.watch<SettingsProvider>().showChatListDate;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textBase = isDark ? Colors.white : Colors.black;

    // Filter conversations for the current query (if any)
    final allConvos = chatService.getAllConversations();
    final hasQuery = _query.trim().isNotEmpty;
    final q = _query.toLowerCase();
    
    // Build list of assistants
    List<Assistant> assistants = ap.assistants;
    if (hasQuery) {
      final matchingConvoAssistantIds = allConvos
          .where((c) => c.title.toLowerCase().contains(q) && c.assistantId != null)
          .map((c) => c.assistantId!)
          .toSet();
      assistants = assistants.where((a) => a.name.toLowerCase().contains(q) || matchingConvoAssistantIds.contains(a.id)).toList();
    }

    final tags = tp.tags;
    final ungrouped = assistants.where((a) => tp.tagOfAssistant(a.id) == null).toList();
    final groupedByTag = <String, List<Assistant>>{};
    for (final t in tags) {
      final list = assistants.where((a) => tp.tagOfAssistant(a.id) == t.id).toList();
      if (list.isNotEmpty) groupedByTag[t.id] = list;
    }

    final children = <Widget>[];

    // New Project button: first item of the project list (scrolls with it)
    children.add(
      Padding(
        padding: const EdgeInsets.only(bottom: _sideDrawerTileGap),
        child: _NewProjectButton(
          label: AppLocalizations.of(context)!.sideDrawerNewProject,
          onTap: _handleNewProject,
        ),
      ),
    );

    // Helper to build a single assistant + its conversations if expanded
    Widget buildAssistantNode(Assistant a) {
      final isExpanded = _expandedAssistantIds.contains(a.id) || hasQuery;
      final isCurrent = ap.currentAssistantId == a.id;
      
      final convos = allConvos.where((c) => c.assistantId == a.id).toList();
      final filteredConvos = hasQuery ? convos.where((c) => c.title.toLowerCase().contains(q)).toList() : convos;

      Widget _buildChatTile(ChatItem chatItem) {
        return _ChatTile(
          chat: chatItem,
          loading: widget.loadingConversationIds.contains(chatItem.id),
          selected: chatService.currentConversationId == chatItem.id,
          onTap: () {
            final closeDrawer = !context.read<SettingsProvider>().keepSidebarOpenOnTopicTap;
            ap.setCurrentAssistant(a.id);
            widget.onSelectConversation?.call(chatItem.id, closeDrawer: closeDrawer);
          },
          onLongPress: () => _showChatMenu(context, chatItem),
          onSecondaryTap: (pos) => _showChatMenu(context, chatItem, anchor: pos),
          textColor: textBase,
        );
      }

      final convosWidgets = <Widget>[];
      if (isExpanded && filteredConvos.isNotEmpty) {
        final convosItems = filteredConvos.map((c) => ChatItem(id: c.id, title: c.title, created: c.updatedAt)).toList();
        final pinnedList = convosItems
            .where((c) => (chatService.getConversation(c.id)?.isPinned ?? false))
            .toList()
          ..sort((a, b) => b.created.compareTo(a.created));
        final rest = convosItems
            .where((c) => !(chatService.getConversation(c.id)?.isPinned ?? false))
            .toList();
        final groups = _groupByDate(context, rest);

        if (pinnedList.isNotEmpty) {
          convosWidgets.add(
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 6, 0, 6),
              child: Text(
                AppLocalizations.of(context)!.sideDrawerPinnedLabel,
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.primary),
              ),
            ),
          );
          convosWidgets.addAll(pinnedList.map(_buildChatTile));
        }

        for (final group in groups) {
          if (showChatListDate) {
            convosWidgets.add(
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 6, 0, 6),
                child: Text(
                  group.label,
                  textAlign: TextAlign.left,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.primary),
                ),
              ),
            );
          }
          convosWidgets.addAll(group.items.map(_buildChatTile));
        }
      }

      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: _sideDrawerTileGap),
            child: _AssistantFolderTile(
              name: a.name,
              textColor: textBase,
              embedded: widget.embedded,
              isCurrent: isCurrent,
              isExpanded: isExpanded,
              onTap: () {
                if (hasQuery) {
                  // Ignore toggling when searching
                } else {
                  _handleToggleAssistant(a.id);
                }
              },
              onNewChat: () => _handleNewConversationForAssistant(context, a),
              onEditTap: () => _openAssistantSettings(a.id),
              onLongPress: () => _showAssistantItemMenuMobile(a),
              onSecondaryTapDown: (pos) => _showAssistantItemMenuDesktop(a, pos),
            ),
          ),
          if (isExpanded && convosWidgets.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: convosWidgets,
              ),
            ),
        ],
      );
    }

    if (ungrouped.isNotEmpty) {
      children.addAll(ungrouped.map(buildAssistantNode));
    }

    for (final t in tags) {
      final list = groupedByTag[t.id];
      if (list == null || list.isEmpty) continue;
      final collapsed = _collapsedTags.contains(t.id);
      children.add(
        _GroupHeader(
          title: t.name,
          collapsed: collapsed,
          onToggle: () {
            setState(() {
              if (collapsed) {
                _collapsedTags.remove(t.id);
              } else {
                _collapsedTags.add(t.id);
              }
            });
          },
        ),
      );
      if (!collapsed) {
        children.addAll(list.map(buildAssistantNode));
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}

/// Vertical gap between list items in the sidebar (projects & conversations).
const double _sideDrawerTileGap = 4;

class _ChatGroup {
  final String label;
  final List<ChatItem> items;
  _ChatGroup({required this.label, required this.items});
}

class _ChatTile extends StatefulWidget {
  const _ChatTile({
    required this.chat,
    required this.textColor,
    this.onTap,
    this.onLongPress,
    this.onSecondaryTap,
    this.selected = false,
    this.loading = false,
  });

  final ChatItem chat;
  final Color textColor;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final void Function(Offset globalPosition)? onSecondaryTap;
  final bool selected;
  final bool loading;

  @override
  State<_ChatTile> createState() => _ChatTileState();
}

class _ChatTileState extends State<_ChatTile> {
  bool _hovered = false;
  bool get _isDesktop => defaultTargetPlatform == TargetPlatform.macOS || defaultTargetPlatform == TargetPlatform.windows || defaultTargetPlatform == TargetPlatform.linux;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final embedded = context.findAncestorWidgetOfExactType<SideDrawer>()?.embedded ?? false;
    final Color tileColor;
    if (embedded) {
      // In tablet embedded mode, keep selected highlight, others transparent
      tileColor = widget.selected ? cs.primary.withOpacity(0.16) : Colors.transparent;
    } else {
      tileColor = widget.selected ? cs.primary.withOpacity(0.12) : cs.surface;
    }
    final base = _isDesktop && !widget.selected && _hovered
        ? (embedded ? cs.primary.withOpacity(0.08) : cs.surface.withOpacity(0.9))
        : tileColor;
    final double _vGap = _sideDrawerTileGap;
    return Padding(
      padding: EdgeInsets.only(bottom: _vGap),
      child: GestureDetector(
        onSecondaryTapDown: (details) {
          if (_isDesktop) {
            widget.onSecondaryTap?.call(details.globalPosition);
          }
        },
        onLongPress: () {
          if (_isDesktop) return;
          widget.onLongPress?.call();
        },
        child: MouseRegion(
          onEnter: (_) { if (_isDesktop) setState(() => _hovered = true); },
          onExit: (_) { if (_isDesktop) setState(() => _hovered = false); },
          cursor: _isDesktop ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: IosCardPress(
          baseColor: base,
          borderRadius: BorderRadius.circular(16),
          haptics: false,
          onTap: widget.onTap,
          onLongPress: _isDesktop ? null : widget.onLongPress,
          padding: EdgeInsets.fromLTRB(_isDesktop ? 14 : 14, _isDesktop ? 9 : 10, 8, _isDesktop ? 9 : 10),
          child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.chat.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: _isDesktop ? 14 : 15,
                      color: widget.textColor,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ),
                if (widget.loading) ...[
                  const SizedBox(width: 8),
                  _LoadingDot(),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LoadingDot extends StatefulWidget {
  @override
  State<_LoadingDot> createState() => _LoadingDotState();
}

class _LoadingDotState extends State<_LoadingDot> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat(reverse: true);
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return FadeTransition(
      opacity: _anim,
      child: Container(
        width: 9,
        height: 9,
        decoration: BoxDecoration(color: cs.primary, shape: BoxShape.circle),
      ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.title, required this.collapsed, required this.onToggle});
  final String title;
  final bool collapsed;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textBase = cs.onSurface;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            AnimatedRotation(
              turns: collapsed ? 0.0 : 0.25, // right -> down
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              child: Icon(
                Lucide.ChevronRight,
                size: 16,
                color: textBase.withOpacity(0.7),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: textBase),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NewProjectButton extends StatefulWidget {
  const _NewProjectButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  State<_NewProjectButton> createState() => _NewProjectButtonState();
}

class _NewProjectButtonState extends State<_NewProjectButton> {
  bool _hovered = false;

  bool get _isDesktop =>
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final Color bg = _hovered
        ? (isDark ? Colors.white.withOpacity(0.10) : Colors.black.withOpacity(0.06))
        : cs.primary.withOpacity(0.10);
    return MouseRegion(
      onEnter: (_) {
        if (_isDesktop) setState(() => _hovered = true);
      },
      onExit: (_) {
        if (_isDesktop) setState(() => _hovered = false);
      },
      cursor: _isDesktop ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: cs.primary.withOpacity(0.25)),
          ),
          child: Row(
            children: [
              Icon(Lucide.FolderPlus, size: 18, color: cs.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: cs.primary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AssistantFolderTile extends StatefulWidget {
  final String name;
  final Color textColor;
  final bool embedded;
  final bool isCurrent;
  final bool isExpanded;
  final VoidCallback onTap;
  final VoidCallback onNewChat;
  final VoidCallback onEditTap;
  final VoidCallback onLongPress;
  final void Function(Offset) onSecondaryTapDown;

  const _AssistantFolderTile({
    Key? key,
    required this.name,
    required this.textColor,
    this.embedded = false,
    this.isCurrent = false,
    this.isExpanded = false,
    required this.onTap,
    required this.onNewChat,
    required this.onEditTap,
    required this.onLongPress,
    required this.onSecondaryTapDown,
  }) : super(key: key);

  @override
  State<_AssistantFolderTile> createState() => _AssistantFolderTileState();
}

class _AssistantFolderTileState extends State<_AssistantFolderTile> {
  bool _hovered = false;
  
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDesktop = defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux;
        
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: isDesktop ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onSecondaryTapDown: (details) => widget.onSecondaryTapDown(details.globalPosition),
        child: IosCardPress(
          baseColor: widget.isCurrent 
              ? cs.primary.withOpacity(0.08)
              : (_hovered ? cs.surface.withOpacity(0.8) : Colors.transparent),
          borderRadius: BorderRadius.circular(12),
          onTap: widget.onTap,
          onLongPress: isDesktop ? null : widget.onLongPress,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            children: [
              Icon(
                widget.isExpanded ? Lucide.FolderOpen : Lucide.Folder,
                size: 20,
                color: widget.isCurrent ? cs.primary : cs.onSurface.withOpacity(0.7),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  widget.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: widget.isCurrent ? FontWeight.w600 : FontWeight.w500,
                    color: widget.textColor,
                  ),
                ),
              ),
              if (_hovered || !isDesktop)
                IosIconButton(
                  icon: Lucide.Plus,
                  size: 18,
                  padding: const EdgeInsets.all(4),
                  onTap: widget.onNewChat,
                )
              else
                AnimatedRotation(
                  turns: widget.isExpanded ? 0.25 : 0.0,
                  duration: const Duration(milliseconds: 200),
                  child: Icon(
                    Lucide.ChevronRight,
                    size: 16,
                    color: widget.textColor.withOpacity(0.5),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
