import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'dart:ui' as ui;
import 'dart:math' as math;
import 'package:flutter/services.dart';
import '../../../core/services/haptics.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';
import 'dart:io';
import 'package:open_filex/open_filex.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
// import 'package:easy_image_viewer/easy_image_viewer.dart';
import 'dart:convert';
import 'package:characters/characters.dart';
import '../pages/image_viewer_page.dart';
import '../pages/html_preview_page.dart';
import '../../../utils/markdown_preview_html.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/file_record.dart';
import '../../../icons/lucide_adapter.dart';
// import '../../../theme/design_tokens.dart';
import '../../../core/providers/user_provider.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/workspace/workspace_resolver.dart';
import '../../../core/providers/assistant_provider.dart';
import 'package:intl/intl.dart';
import '../../../utils/sandbox_path_resolver.dart';
import '../../../utils/avatar_cache.dart';
import '../../../utils/assistant_regex.dart';
import '../../../core/models/assistant.dart';
import '../../../core/providers/tts_provider.dart';
import '../../../shared/widgets/markdown_with_highlight.dart';
import '../../../shared/widgets/snackbar.dart';
import 'ai_team_proposals_section.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../l10n/app_localizations.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/providers/model_provider.dart';
import '../../../core/models/assistant_regex.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../desktop/desktop_context_menu.dart';
import '../../../desktop/menu_anchor.dart';
import '../../../desktop/html_preview_dialog.dart';
import '../widgets/workspace_file_browser.dart';
import '../../../shared/widgets/emoji_text.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:super_clipboard/super_clipboard.dart';

final RegExp _urlSchemeRe = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:');

Uri? _tryNormalizeExternalUri(String raw) {
  var u = raw.trim();
  if (u.isEmpty) return null;

  // Handle JSON-ish values like `"example.com"` defensively.
  if ((u.startsWith('"') && u.endsWith('"')) ||
      (u.startsWith("'") && u.endsWith("'"))) {
    u = u.substring(1, u.length - 1).trim();
    if (u.isEmpty) return null;
  }

  if (u.startsWith('//')) {
    u = 'https:$u';
  } else if (!_urlSchemeRe.hasMatch(u)) {
    u = 'https://$u';
  }

  return Uri.tryParse(u);
}

class ChatMessageWidget extends StatefulWidget {
  final ChatMessage message;
  final Widget? modelIcon;
  final bool showModelIcon;
  // Assistant identity override
  final bool useAssistantAvatar;
  final String? assistantName;
  final String? assistantAvatar; // path/url/emoji; null => use initial
  final bool showUserAvatar;
  final bool showTokenStats;
  final VoidCallback? onRegenerate;
  final VoidCallback? onResend;
  final VoidCallback? onCopy;
  final VoidCallback? onTranslate;
  final VoidCallback? onSpeak;
  final VoidCallback? onMore;
  final VoidCallback? onEdit; // user: edit
  final VoidCallback? onDelete; // user: delete
  // Optional version switcher (branch) UI controls
  final int? versionIndex; // zero-based
  final int? versionCount;
  final VoidCallback? onPrevVersion;
  final VoidCallback? onNextVersion;
  // Optional reasoning UI props (for reasoning-capable models)
  final String? reasoningText;
  final bool reasoningExpanded;
  final bool reasoningLoading;
  final DateTime? reasoningStartAt;
  final DateTime? reasoningFinishedAt;
  final VoidCallback? onToggleReasoning;
  // For multiple reasoning segments
  final List<ReasoningSegment>? reasoningSegments;
  // Optional translation UI props
  final bool translationExpanded;
  final VoidCallback? onToggleTranslation;
  // MCP tool calls/results mixed-in cards
  final List<ToolUIPart>? toolParts;
  // Hide streaming dots when pinned globally
  final bool hideStreamingIndicator;

  const ChatMessageWidget({
    super.key,
    required this.message,
    this.modelIcon,
    this.showModelIcon = true,
    this.useAssistantAvatar = false,
    this.assistantName,
    this.assistantAvatar,
    this.showUserAvatar = true,
    this.showTokenStats = true,
    this.onRegenerate,
    this.onResend,
    this.onCopy,
    this.onTranslate,
    this.onSpeak,
    this.onMore,
    this.onEdit,
    this.onDelete,
    this.versionIndex,
    this.versionCount,
    this.onPrevVersion,
    this.onNextVersion,
    this.reasoningText,
    this.reasoningExpanded = false,
    this.reasoningLoading = false,
    this.reasoningStartAt,
    this.reasoningFinishedAt,
    this.onToggleReasoning,
    this.reasoningSegments,
    this.translationExpanded = true,
    this.onToggleTranslation,
    this.toolParts,
    this.hideStreamingIndicator = false,
  });

  @override
  State<ChatMessageWidget> createState() => _ChatMessageWidgetState();
}

class _ChatMessageWidgetState extends State<ChatMessageWidget> {
  // Match vendor inline thinking blocks: <think>...</think> or <thought>...</thought> (or until end)
  static final RegExp THINKING_REGEX = RegExp(
    r"<(?:think|thought)>([\s\S]*?)(?:</(?:think|thought)>|$)",
    dotAll: true,
  );
  final DateFormat _dateFormat = DateFormat('yyyy-MM-dd HH:mm:ss');
  final ScrollController _reasoningScroll = ScrollController();
  bool _tickActive = false;
  // Local expand state for inline <think> card (defaults to expanded)
  bool? _inlineThinkExpanded;
  bool _inlineThinkManuallyToggled = false;
  bool _inlineThinkWasLoading = false;
  // User message context menu state
  final GlobalKey _userBubbleKey = GlobalKey();
  OverlayEntry? _userMenuOverlay;
  bool _userMenuActive = false; // for bubble highlight/scale
  // Desktop anchored menus for bottom action buttons
  final GlobalKey _moreBtnKey1 = GlobalKey();
  final GlobalKey _translateBtnKey1 = GlobalKey();
  final GlobalKey _moreBtnKey2 = GlobalKey();
  final GlobalKey _translateBtnKey2 = GlobalKey();
  // ValueNotifier for reasoning animation tick - avoids full widget rebuild
  final ValueNotifier<int> _reasoningTick = ValueNotifier<int>(0);
  late final Ticker _ticker = Ticker((_) {
    if (mounted && _tickActive) {
      _reasoningTick.value++; // Only notify reasoning section, not full rebuild
    }
  });

  @override
  void initState() {
    super.initState();
    _syncTicker();

    // Determine initial state for inline <think> card BEFORE first paint to avoid
    // post-frame size changes that can cause list scroll jitter/snapping.
    try {
      // Check whether this message is using inline <think> content
      final extracted = THINKING_REGEX
          .allMatches(widget.message.content)
          .map((m) => (m.group(1) ?? '').trim())
          .where((s) => s.isNotEmpty)
          .join('\n\n');
      final usingInlineThink =
          (widget.reasoningText == null || widget.reasoningText!.isEmpty) &&
          extracted.isNotEmpty;
      final loading =
          usingInlineThink &&
          widget.message.isStreaming &&
          !widget.message.content.contains('</think>');

      // Persist last loading state for later checks
      _inlineThinkWasLoading = loading;

      if (usingInlineThink && _inlineThinkExpanded == null) {
        final autoCollapse = context
            .read<SettingsProvider>()
            .autoCollapseThinking;
        // While loading we default to expanded; once finished honor auto-collapse.
        _inlineThinkExpanded = loading
            ? true
            : !autoCollapse
            ? true
            : false;
      }
    } catch (_) {
      // If anything fails here, fall back to later update logic.
    }
  }

  @override
  void didUpdateWidget(covariant ChatMessageWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTicker();
    // Auto-collapse when inline <think> transitions from loading -> finished
    _applyAutoCollapseInlineThinkIfFinished(oldWidget: oldWidget);
  }

  void _applyAutoCollapseInlineThinkIfFinished({ChatMessageWidget? oldWidget}) {
    if (!mounted) return;
    // Determine if using inline <think>
    final newExtracted = THINKING_REGEX
        .allMatches(widget.message.content)
        .map((m) => (m.group(1) ?? '').trim())
        .where((s) => s.isNotEmpty)
        .join('\n\n');
    final usingInlineThinkNew =
        (widget.reasoningText == null || widget.reasoningText!.isEmpty) &&
        newExtracted.isNotEmpty;
    final loadingNew =
        usingInlineThinkNew &&
        widget.message.isStreaming &&
        !widget.message.content.contains('</think>');

    bool loadingOld = false;
    if (oldWidget != null) {
      final oldExtracted = THINKING_REGEX
          .allMatches(oldWidget.message.content)
          .map((m) => (m.group(1) ?? '').trim())
          .where((s) => s.isNotEmpty)
          .join('\n\n');
      final usingInlineThinkOld =
          (oldWidget.reasoningText == null ||
              oldWidget.reasoningText!.isEmpty) &&
          oldExtracted.isNotEmpty;
      loadingOld =
          usingInlineThinkOld &&
          oldWidget.message.isStreaming &&
          !oldWidget.message.content.contains('</think>');
    }

    // Persist last loading to assist other checks
    _inlineThinkWasLoading = loadingNew;

    final autoCollapse = context.read<SettingsProvider>().autoCollapseThinking;

    // If finished now (not loading), inline think is used, and auto-collapse is on
    // Only collapse when user hasn't manually toggled; also if we don't yet have a chosen state.
    final finishedNow = usingInlineThinkNew && !loadingNew;
    final justFinished = oldWidget != null
        ? (loadingOld && finishedNow)
        : finishedNow;

    if (autoCollapse && finishedNow && justFinished) {
      if (!_inlineThinkManuallyToggled || _inlineThinkExpanded == null) {
        if (mounted) setState(() => _inlineThinkExpanded = false);
        return;
      }
    }

    // On first mount where already finished and no user choice yet, honor autoCollapse
    if (oldWidget == null &&
        usingInlineThinkNew &&
        !loadingNew &&
        _inlineThinkExpanded == null) {
      if (autoCollapse) {
        if (mounted) setState(() => _inlineThinkExpanded = false);
      } else {
        if (mounted) setState(() => _inlineThinkExpanded = true);
      }
    }
  }

  void _syncTicker() {
    final loading =
        widget.reasoningStartAt != null && widget.reasoningFinishedAt == null;
    _tickActive = loading;
    if (loading) {
      if (!_ticker.isActive) _ticker.start();
    } else {
      if (_ticker.isActive) _ticker.stop();
    }
  }

  Future<void> _copyFormattedText(String text) async {
    try {
      final html = md.markdownToHtml(
        text,
        extensionSet: md.ExtensionSet.gitHubFlavored,
      );
      final item = DataWriterItem();
      item.add(Formats.htmlText(html));
      item.add(Formats.plainText(text));
      await SystemClipboard.instance?.write([item]);
    } catch (e) {
      // Fallback to purely plain text if super_clipboard fails
      await Clipboard.setData(ClipboardData(text: text));
    }
  }

  String _assistantNameFallback() {
    try {
      final chat = context.read<ChatService>();
      final convo = chat.getConversation(widget.message.conversationId);
      final aId = convo?.assistantId;
      if (aId != null && aId.isNotEmpty) {
        final ap = context.read<AssistantProvider>();
        final a = ap.getById(aId);
        final name = a?.name.trim();
        if (name != null && name.isNotEmpty) return name;
      }
    } catch (_) {}
    return 'AI Assistant';
  }

  Assistant? _assistantForMessage() {
    try {
      final chat = context.read<ChatService>();
      final convo = chat.getConversation(widget.message.conversationId);
      final aId = convo?.assistantId;
      if (aId == null || aId.isEmpty) return null;
      final ap = context.watch<AssistantProvider>();
      return ap.getById(aId);
    } catch (_) {
      return null;
    }
  }

  String _resolveModelDisplayName(SettingsProvider settings) {
    final modelId = widget.message.modelId;
    if (modelId == null || modelId.trim().isEmpty) {
      // Prefer assistant's name when model id is missing (e.g., preset assistant messages)
      return _assistantNameFallback();
    }

    final providerId = widget.message.providerId;
    String baseId = modelId;
    if (providerId != null && providerId.isNotEmpty) {
      try {
        final cfg = settings.getProviderConfig(providerId);
        final ov = cfg.modelOverrides[modelId] as Map?;
        if (ov != null) {
          final name = (ov['name'] as String?)?.trim();
          if (name != null && name.isNotEmpty) {
            return name;
          }
          final apiId = (ov['apiModelId'] ?? ov['api_model_id'])
              ?.toString()
              .trim();
          if (apiId != null && apiId.isNotEmpty) {
            baseId = apiId;
          }
        }
      } catch (_) {
        // ignore lookup failures; fall through to inferred name.
      }
    }

    final inferred = ModelRegistry.infer(
      ModelInfo(id: baseId, displayName: baseId),
    );
    final fallback = inferred.displayName.trim();
    return fallback.isNotEmpty ? fallback : baseId;
  }

  int _estimateTokens(String text) {
    if (text.isEmpty) return 0;
    int cjkCount = 0;
    int otherCharCount = 0;
    for (final char in text.runes) {
      if ((char >= 0x4E00 && char <= 0x9FFF) ||
          (char >= 0x3400 && char <= 0x4DBF) ||
          (char >= 0x3000 && char <= 0x303F) ||
          (char >= 0xFF00 && char <= 0xFFEF)) {
        cjkCount++;
      } else {
        otherCharCount++;
      }
    }
    return cjkCount + (otherCharCount / 4).ceil();
  }

  String _buildStatsText(ChatMessage message) {
    final int tokens;
    final bool isEstimated;
    if (message.totalTokens != null && message.totalTokens! > 0) {
      tokens = message.totalTokens!;
      isEstimated = false;
    } else {
      final fullText = message.content + (message.reasoningText ?? '');
      tokens = _estimateTokens(fullText);
      isEstimated = true;
    }

    final tokenStr = isEstimated ? '~$tokens tokens' : '$tokens tokens';
    final charCount = message.content.length;
    if (charCount > 0) {
      return '$tokenStr · $charCount 字';
    }
    return tokenStr;
  }

  @override
  void dispose() {
    try {
      _userMenuOverlay?.remove();
    } catch (_) {}
    _userMenuOverlay = null;
    _ticker.dispose();
    _reasoningTick.dispose();
    _reasoningScroll.dispose();
    super.dispose();
  }

  void _removeUserMenuOverlay() {
    try {
      _userMenuOverlay?.remove();
    } catch (_) {}
    _userMenuOverlay = null;
    if (mounted && _userMenuActive) setState(() => _userMenuActive = false);
  }

  void _showUserContextMenu() {
    // Haptic feedback (optional)
    try {
      Haptics.light();
    } catch (_) {}

    final box = _userBubbleKey.currentContext?.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(context);
    final overlayBox = overlay?.context.findRenderObject() as RenderBox?;
    if (box == null || overlayBox == null || overlay == null) return;

    final bubbleTopLeft = box.localToGlobal(Offset.zero, ancestor: overlayBox);
    final bubbleSize = box.size;
    final screenSize = overlayBox.size;
    final insets = MediaQuery.paddingOf(context); // status bar / gesture insets
    final safeLeft = insets.left + 12;
    final safeRight = insets.right + 12;
    final safeTop = insets.top + 12;
    final safeBottom = insets.bottom + 12;

    const double menuWidth = 220; // compact width
    const double estMenuHeight = 140; // ~ 3 rows
    const double gap = 10; // space between bubble and menu

    // Horizontal placement: align menu's right edge to bubble's right edge,
    // and clamp into safe area for better reachability on long messages.
    final double bubbleRight = bubbleTopLeft.dx + bubbleSize.width;
    double x = bubbleRight - menuWidth;
    final double minX = safeLeft;
    final double maxX = screenSize.width - safeRight - menuWidth;
    if (x < minX) x = minX;
    if (x > maxX) x = maxX;

    // Decide above vs below using safe area
    final availableAbove = bubbleTopLeft.dy - gap - safeTop;
    final availableBelow =
        (screenSize.height - safeBottom) -
        (bubbleTopLeft.dy + bubbleSize.height + gap);
    final bool canPlaceAbove = availableAbove >= estMenuHeight;
    final bool canPlaceBelow = availableBelow >= estMenuHeight;

    bool placeAbove;
    if (canPlaceAbove) {
      placeAbove = true;
    } else if (canPlaceBelow) {
      placeAbove = false;
    } else {
      // Fallback: choose the side with more space
      placeAbove = availableAbove > availableBelow;
    }

    double y = placeAbove
        ? (bubbleTopLeft.dy - estMenuHeight - gap)
        : (bubbleTopLeft.dy + bubbleSize.height + gap);

    // Clamp vertically to remain fully visible within safe area
    final double minY = safeTop;
    final double maxY = screenSize.height - safeBottom - estMenuHeight;
    if (y < minY) y = minY;
    if (y > maxY) y = maxY;

    if (mounted) setState(() => _userMenuActive = true);
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final l10n = AppLocalizations.of(context)!;

    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'context-menu',
      barrierColor: Colors.black.withOpacity(0.08),
      pageBuilder: (ctx, _, __) {
        return Stack(
          children: [
            // Positioned popup
            Positioned(
              left: x,
              top: y,
              width: menuWidth,
              child: _AnimatedPopup(
                child: DecoratedBox(
                  // Draw border outside the clipped/blurred content to avoid corner clipping
                  decoration: ShapeDecoration(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                      side: BorderSide(
                        color: isDark
                            ? Colors.white.withOpacity(0.08)
                            : cs.outlineVariant.withOpacity(0.2),
                        width: 1,
                      ),
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: BackdropFilter(
                      filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: isDark
                              ? const Color(0xFF1C1C1E).withOpacity(0.66)
                              : Colors.white.withOpacity(0.66),
                        ),
                        child: Material(
                          color: Colors.transparent,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _MenuItem(
                                icon: Lucide.Copy,
                                label: l10n.shareProviderSheetCopyButton,
                                onTap: () async {
                                  Navigator.of(ctx).pop();
                                  if (widget.onCopy != null) {
                                    widget.onCopy!.call();
                                  } else {
                                    await _copyFormattedText(
                                      widget.message.content,
                                    );
                                    if (mounted) {
                                      showAppSnackBar(
                                        context,
                                        message: l10n
                                            .chatMessageWidgetCopiedToClipboard,
                                        type: NotificationType.success,
                                      );
                                    }
                                  }
                                },
                              ),
                              _MenuItem(
                                icon: Lucide.Pencil,
                                label: l10n.messageMoreSheetEdit,
                                onTap: () {
                                  Navigator.of(ctx).pop();
                                  (widget.onEdit ?? widget.onMore)?.call();
                                },
                              ),
                              _MenuItem(
                                icon: Lucide.Trash2,
                                danger: true,
                                label: l10n.messageMoreSheetDelete,
                                onTap: () {
                                  Navigator.of(ctx).pop();
                                  (widget.onDelete ?? widget.onMore)?.call();
                                },
                              ),
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
      },
    ).whenComplete(() {
      if (mounted) setState(() => _userMenuActive = false);
    });
  }

  Widget _buildUserAvatar(UserProvider userProvider, ColorScheme cs) {
    Widget avatarContent;

    if (userProvider.avatarType == 'emoji' &&
        userProvider.avatarValue != null) {
      final bool isIOS = defaultTargetPlatform == TargetPlatform.iOS;
      final double fs = 18;
      final Offset? nudge = isIOS ? Offset(fs * 0.065, fs * -0.05) : null;
      avatarContent = Center(
        child: EmojiText(
          userProvider.avatarValue!,
          fontSize: fs,
          optimizeEmojiAlign: true,
          nudge: nudge,
        ),
      );
    } else if (userProvider.avatarType == 'url' &&
        userProvider.avatarValue != null) {
      final url = userProvider.avatarValue!;
      avatarContent = FutureBuilder<String?>(
        future: AvatarCache.getPath(url),
        builder: (ctx, snap) {
          final p = snap.data;
          if (p != null && File(p).existsSync()) {
            return ClipOval(
              child: Image.file(
                File(p),
                width: 32,
                height: 32,
                fit: BoxFit.cover,
              ),
            );
          }
          return ClipOval(
            child: Image.network(
              url,
              width: 32,
              height: 32,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) =>
                  Icon(Lucide.User, size: 18, color: cs.primary),
            ),
          );
        },
      );
    } else if (userProvider.avatarType == 'file' &&
        userProvider.avatarValue != null) {
      final fixed = SandboxPathResolver.fix(userProvider.avatarValue!);
      final f = File(fixed);
      if (f.existsSync()) {
        avatarContent = ClipOval(
          child: Image.file(f, width: 32, height: 32, fit: BoxFit.cover),
        );
      } else {
        avatarContent = Icon(Lucide.User, size: 18, color: cs.primary);
      }
    } else {
      avatarContent = Icon(Lucide.User, size: 18, color: cs.primary);
    }

    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: cs.primary.withOpacity(0.1),
        shape: BoxShape.circle,
      ),
      child: avatarContent,
    );
  }

  Widget _buildToolMessage() {
    // Parse JSON payload embedded in tool message content
    String toolName = 'tool';
    Map<String, dynamic> args = const {};
    String result = '';
    try {
      final obj = jsonDecode(widget.message.content) as Map<String, dynamic>;
      toolName = (obj['tool'] ?? 'tool').toString();
      final a = obj['arguments'];
      if (a is Map<String, dynamic>) args = a;
      result = (obj['result'] ?? '').toString();
    } catch (_) {}

    final part = ToolUIPart(
      id: widget.message.id,
      toolName: toolName,
      arguments: args,
      content: result,
      loading: false,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: _ToolCallItem(part: part),
    );
  }

  Widget _buildUserMessage() {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final userProvider = context.watch<UserProvider>();
    final l10n = AppLocalizations.of(context)!;
    final settings = context.watch<SettingsProvider>();
    final parsed = _parseUserContent(widget.message.content);
    final assistant = _assistantForMessage();
    final visualText = applyAssistantRegexes(
      parsed.text,
      assistant: assistant,
      scope: AssistantRegexScope.user,
      visual: true,
    );
    final showUserActions = settings.showUserMessageActions;
    final showVersionSwitcher = (widget.versionCount ?? 1) > 1;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // Header: User info and avatar
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (settings.showUserNameTimestamp || widget.showTokenStats)
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (settings.showUserNameTimestamp)
                        Text(
                          userProvider.name,
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: cs.onSurface.withOpacity(0.7),
                          ),
                        ),
                      Builder(
                        builder: (context) {
                          final List<Widget> wrapChildren = [];
                          if (settings.showUserNameTimestamp) {
                            wrapChildren.add(
                              Text(
                                _dateFormat.format(widget.message.timestamp),
                                style: TextStyle(
                                  fontSize: 11,
                                  color: cs.onSurface.withOpacity(0.5),
                                ),
                              ),
                            );
                          }
                          if (widget.showTokenStats) {
                            wrapChildren.add(
                              Text(
                                _buildStatsText(widget.message),
                                style: TextStyle(
                                  fontSize: 11,
                                  color: cs.onSurface.withOpacity(0.5),
                                ),
                              ),
                            );
                          }
                          return wrapChildren.isNotEmpty
                              ? Wrap(
                                  alignment: WrapAlignment.end,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  spacing: 8,
                                  runSpacing: 2,
                                  children: wrapChildren,
                                )
                              : const SizedBox.shrink();
                        },
                      ),
                    ],
                  ),
                ),
              if (widget.showUserAvatar) ...[
                const SizedBox(width: 8),
                // User avatar
                _buildUserAvatar(userProvider, cs),
              ],
            ],
          ),
          const SizedBox(height: 8),
          // Message content (context menu: long-press on mobile, right-click on desktop)
          GestureDetector(
            onLongPressStart: (_) {
              final isDesktop =
                  defaultTargetPlatform == TargetPlatform.macOS ||
                  defaultTargetPlatform == TargetPlatform.windows ||
                  defaultTargetPlatform == TargetPlatform.linux;
              if (isDesktop) return; // Desktop uses right-click menu
              _showUserContextMenu();
            },
            onSecondaryTapDown: (details) {
              final isDesktop =
                  defaultTargetPlatform == TargetPlatform.macOS ||
                  defaultTargetPlatform == TargetPlatform.windows ||
                  defaultTargetPlatform == TargetPlatform.linux;
              if (!isDesktop) return; // Mobile keeps long-press
              _showUserContextMenuAt(details.globalPosition);
            },
            behavior: HitTestBehavior.translucent,
            child: Container(
              key: _userBubbleKey,
              constraints: BoxConstraints(
                maxWidth: MediaQuery.sizeOf(context).width * 0.75,
              ),
              child: _buildBubbleContainer(
                context: context,
                isUser: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (visualText.isNotEmpty)
                      Builder(
                        builder: (context) {
                          final bool isDesktop =
                              defaultTargetPlatform == TargetPlatform.macOS ||
                              defaultTargetPlatform == TargetPlatform.windows ||
                              defaultTargetPlatform == TargetPlatform.linux;
                          final double baseUser = isDesktop ? 14.0 : 15.5;

                          Widget content;
                          if (settings.enableUserMarkdown) {
                            content = DefaultTextStyle.merge(
                              style: TextStyle(
                                fontSize: baseUser,
                                height: 1.45,
                              ),
                              child: MarkdownWithCodeHighlight(
                                text: visualText,
                                baseStyle: TextStyle(
                                  fontSize: baseUser,
                                  height: 1.45,
                                ),
                              ),
                            );
                          } else {
                            content = Text(
                              visualText,
                              style: TextStyle(
                                fontSize:
                                    baseUser, // slightly smaller on desktop for readability
                                height: 1.4,
                                color: cs.onSurface,
                              ),
                            );
                          }

                          // Enable desktop selection/copy for user messages (bypassed on Windows to prevent flutter_windows.dll 0xc0000005 crashes)
                          return isDesktop
                              ? SelectionArea(
                                  key: ValueKey('user_${widget.message.id}'),
                                  child: content,
                                )
                              : content;
                        },
                      ),
                    if (parsed.images.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Builder(
                        builder: (context) {
                          final imgs = parsed.images;
                          return Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: imgs.asMap().entries.map((entry) {
                              final idx = entry.key;
                              final p = entry.value;
                              return Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  onTap: () {
                                    Navigator.of(context).push(
                                      PageRouteBuilder(
                                        pageBuilder: (_, __, ___) =>
                                            ImageViewerPage(
                                              images: imgs,
                                              initialIndex: idx,
                                            ),
                                        transitionDuration: const Duration(
                                          milliseconds: 360,
                                        ),
                                        reverseTransitionDuration:
                                            const Duration(milliseconds: 280),
                                        transitionsBuilder:
                                            (context, anim, sec, child) {
                                              final curved = CurvedAnimation(
                                                parent: anim,
                                                curve: Curves.easeOutCubic,
                                                reverseCurve:
                                                    Curves.easeInCubic,
                                              );
                                              return FadeTransition(
                                                opacity: curved,
                                                child: SlideTransition(
                                                  position: Tween<Offset>(
                                                    begin: const Offset(
                                                      0,
                                                      0.02,
                                                    ), // subtle upward drift
                                                    end: Offset.zero,
                                                  ).animate(curved),
                                                  child: child,
                                                ),
                                              );
                                            },
                                      ),
                                    );
                                  },
                                  borderRadius: BorderRadius.circular(8),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: Hero(
                                      tag: 'img:$p',
                                      child: Image.file(
                                        File(SandboxPathResolver.fix(p)),
                                        width: 96,
                                        height: 96,
                                        fit: BoxFit.cover,
                                        errorBuilder: (_, __, ___) => Container(
                                          width: 96,
                                          height: 96,
                                          color: Colors.black12,
                                          child: const Icon(Icons.broken_image),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            }).toList(),
                          );
                        },
                      ),
                    ],
                    if (parsed.docs.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: parsed.docs.map((d) {
                          return Material(
                            color: Colors.transparent,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(10),
                              overlayColor: MaterialStateProperty.resolveWith(
                                (states) => cs.primary.withOpacity(
                                  states.contains(MaterialState.pressed)
                                      ? 0.14
                                      : 0.08,
                                ),
                              ),
                              splashColor: cs.primary.withOpacity(0.18),
                              onTap: () async {
                                try {
                                  final fixed = SandboxPathResolver.fix(d.path);
                                  final f = File(fixed);
                                  if (!(await f.exists())) {
                                    showAppSnackBar(
                                      context,
                                      message: l10n
                                          .chatMessageWidgetFileNotFound(
                                            d.fileName,
                                          ),
                                      type: NotificationType.error,
                                    );
                                    return;
                                  }
                                  final res = await OpenFilex.open(
                                    fixed,
                                    type: d.mime,
                                  );
                                  if (res.type != ResultType.done) {
                                    showAppSnackBar(
                                      context,
                                      message: l10n
                                          .chatMessageWidgetCannotOpenFile(
                                            res.message ?? res.type.toString(),
                                          ),
                                      type: NotificationType.error,
                                    );
                                  }
                                } catch (e) {
                                  showAppSnackBar(
                                    context,
                                    message: l10n
                                        .chatMessageWidgetOpenFileError(
                                          e.toString(),
                                        ),
                                    type: NotificationType.error,
                                  );
                                }
                              },
                              child: Ink(
                                decoration: BoxDecoration(
                                  color: isDark ? Colors.white12 : cs.surface,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 8,
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(
                                        Icons.insert_drive_file,
                                        size: 16,
                                      ),
                                      const SizedBox(width: 6),
                                      ConstrainedBox(
                                        constraints: const BoxConstraints(
                                          maxWidth: 180,
                                        ),
                                        child: Text(
                                          d.fileName,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (showUserActions || showVersionSwitcher) ...[
            SizedBox(height: showUserActions ? 8 : 6),
            Align(
              alignment: Alignment.centerRight,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.sizeOf(context).width * 0.75,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (showUserActions) ...[
                      SizedBox(
                        width: 28,
                        height: 28,
                        child: Center(
                          child: IosIconButton(
                            size: 16,
                            padding: EdgeInsets.all(4),
                            icon: Lucide.Copy,
                            color: cs.onSurface.withOpacity(0.9),
                            onTap:
                                widget.onCopy ??
                                () async {
                                  await _copyFormattedText(
                                    widget.message.content,
                                  );
                                  if (mounted) {
                                    showAppSnackBar(
                                      context,
                                      message: l10n
                                          .chatMessageWidgetCopiedToClipboard,
                                      type: NotificationType.success,
                                    );
                                  }
                                },
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      SizedBox(
                        width: 28,
                        height: 28,
                        child: Center(
                          child: IosIconButton(
                            size: 16,
                            padding: EdgeInsets.all(4),
                            icon: Lucide.RefreshCw,
                            color: cs.onSurface.withOpacity(0.9),
                            onTap: widget.onResend,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      if (widget.onEdit != null) ...[
                        SizedBox(
                          width: 28,
                          height: 28,
                          child: Center(
                            child: IosIconButton(
                              size: 16,
                              padding: EdgeInsets.all(4),
                              icon: Lucide.Pencil,
                              color: cs.onSurface.withOpacity(0.9),
                              onTap: widget.onEdit,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                      ],
                      SizedBox(
                        width: 28,
                        height: 28,
                        child: Center(
                          child: GestureDetector(
                            key: _moreBtnKey1,
                            onTapDown: (d) {
                              final isDesktop =
                                  defaultTargetPlatform ==
                                      TargetPlatform.macOS ||
                                  defaultTargetPlatform ==
                                      TargetPlatform.windows ||
                                  defaultTargetPlatform == TargetPlatform.linux;
                              if (isDesktop) {
                                try {
                                  DesktopMenuAnchor.setPosition(
                                    d.globalPosition,
                                  );
                                } catch (_) {}
                              }
                            },
                            onTap: () {
                              final isDesktop =
                                  defaultTargetPlatform ==
                                      TargetPlatform.macOS ||
                                  defaultTargetPlatform ==
                                      TargetPlatform.windows ||
                                  defaultTargetPlatform == TargetPlatform.linux;
                              if (isDesktop) {
                                _setAnchorFromKey(_moreBtnKey1);
                              }
                              widget.onMore?.call();
                            },
                            child: IosIconButton(
                              size: 16,
                              padding: EdgeInsets.all(4),
                              icon: Lucide.Ellipsis,
                              color: cs.onSurface.withOpacity(0.9),
                              onTap: null,
                            ),
                          ),
                        ),
                      ),
                    ],
                    if (showVersionSwitcher) ...[
                      if (showUserActions) const SizedBox(width: 6),
                      _BranchSelector(
                        index: widget.versionIndex ?? 0,
                        total: widget.versionCount ?? 1,
                        onPrev: widget.onPrevVersion,
                        onNext: widget.onNextVersion,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _showUserContextMenuAt(Offset globalPosition) async {
    final l10n = AppLocalizations.of(context)!;
    // Haptic feedback
    try {
      Haptics.light();
    } catch (_) {}
    await showDesktopContextMenuAt(
      context,
      globalPosition: globalPosition,
      items: [
        DesktopContextMenuItem(
          icon: Lucide.Copy,
          label: l10n.shareProviderSheetCopyButton,
          onTap: () async {
            if (widget.onCopy != null) {
              widget.onCopy!.call();
            } else {
              await _copyFormattedText(widget.message.content);
              if (mounted) {
                showAppSnackBar(
                  context,
                  message: l10n.chatMessageWidgetCopiedToClipboard,
                  type: NotificationType.success,
                );
              }
            }
          },
        ),
        DesktopContextMenuItem(
          icon: Lucide.Pencil,
          label: l10n.messageMoreSheetEdit,
          onTap: () => (widget.onEdit ?? widget.onMore)?.call(),
        ),
        DesktopContextMenuItem(
          icon: Lucide.Trash2,
          label: l10n.messageMoreSheetDelete,
          danger: true,
          onTap: () => (widget.onDelete ?? widget.onMore)?.call(),
        ),
      ],
    );
  }

  void _setAnchorFromKey(GlobalKey key) {
    final rb = key.currentContext?.findRenderObject() as RenderBox?;
    if (rb == null) return;
    try {
      final center = rb.localToGlobal(
        Offset(rb.size.width / 2, rb.size.height),
      );
      DesktopMenuAnchor.setPosition(center);
    } catch (_) {}
  }

  Widget _buildBubbleContainer({
    required BuildContext context,
    required bool isUser,
    required Widget child,
  }) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final style = context.watch<SettingsProvider>().chatMessageBackgroundStyle;
    BorderRadius radius = BorderRadius.circular(16);
    switch (style) {
      case ChatMessageBackgroundStyle.frosted:
        return ClipRRect(
          borderRadius: radius,
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: isDark
                    ? const Color(0xFF1C1C1E).withOpacity(0.66)
                    : Colors.white.withOpacity(0.66),
                borderRadius: radius,
                border: Border.all(
                  color: cs.outlineVariant.withOpacity(0.14),
                  width: 0.8,
                ),
              ),
              child: Padding(padding: const EdgeInsets.all(12), child: child),
            ),
          ),
        );
      case ChatMessageBackgroundStyle.solid:
        return Container(
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1C1C1E) : Colors.white,
            borderRadius: radius,
            border: Border.all(
              color: cs.outlineVariant.withOpacity(0.16),
              width: 0.8,
            ),
          ),
          padding: const EdgeInsets.all(12),
          child: child,
        );
      case ChatMessageBackgroundStyle.defaultStyle:
      default:
        // Default: keep original visual — user has a tinted bubble; assistant is bare
        if (isUser) {
          return Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isDark
                  ? cs.primary.withOpacity(0.15)
                  : cs.primary.withOpacity(0.08),
              borderRadius: radius,
            ),
            child: child,
          );
        }
        return child;
    }
  }

  Widget _buildAssistantBubbleContainer({
    required BuildContext context,
    required Widget child,
  }) {
    // Reuse same styles, but flag as non-user for default fallthrough
    return _buildBubbleContainer(context: context, isUser: false, child: child);
  }

  List<FileRecord> _messageFileRecords() {
    return context.watch<ChatService>().getMessageFileRecords(
      widget.message.id,
    );
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Future<void> _showFileInFolder(FileRecord record) async {
    final l10n = AppLocalizations.of(context)!;
    final file = File(record.path);
    if (!await file.exists()) {
      if (mounted)
        showAppSnackBar(
          context,
          message: l10n.chatMessageWidgetFileNotFound(record.fileName),
          type: NotificationType.error,
        );
      return;
    }
    if (Platform.isWindows) {
      await Process.run('explorer', [
        '/select,',
        record.path.replaceAll('/', '\\'),
      ]);
      return;
    }
    if (Platform.isMacOS) {
      await Process.run('open', ['-R', record.path]);
      return;
    }
    if (Platform.isLinux) {
      await Process.run('xdg-open', [file.parent.path]);
      return;
    }

    final chatService = context.read<ChatService>();
    final conversation = chatService.getConversation(
      widget.message.conversationId,
    );
    final assistantProvider = context.read<AssistantProvider>();
    final assistant = conversation?.assistantId == null
        ? assistantProvider.currentAssistant
        : assistantProvider.getById(conversation!.assistantId!);
    final workspace = conversation == null
        ? null
        : (await WorkspaceResolver.resolve(
            conversation: conversation,
            project: assistant,
            conversationConfig: chatService.getConversationWorkspaceConfig(
              conversation.id,
            ),
            defaultConfig: context
                .read<SettingsProvider>()
                .defaultWorkspaceConfig,
          )).path;
    if (workspace == null || workspace.trim().isEmpty) return;
    if (!mounted) return;
    final relativeDirectory = p.relative(file.parent.path, from: workspace);
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WorkspaceFileBrowser(
          workspacePath: workspace,
          initialRelativePath: relativeDirectory == '.'
              ? ''
              : relativeDirectory,
        ),
      ),
    );
  }

  Future<void> _openFileExternally(FileRecord record) async {
    final l10n = AppLocalizations.of(context)!;
    final result = await OpenFilex.open(record.path);
    if (!mounted || result.type == ResultType.done) return;
    showAppSnackBar(
      context,
      message: l10n.chatMessageWidgetCannotOpenFile(result.message),
      type: NotificationType.error,
    );
  }

  Future<void> _downloadFile(FileRecord record) async {
    final l10n = AppLocalizations.of(context)!;
    final file = File(record.path);
    if (!await file.exists()) {
      if (mounted)
        showAppSnackBar(
          context,
          message: l10n.chatMessageWidgetFileNotFound(record.fileName),
          type: NotificationType.error,
        );
      return;
    }
    try {
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        final savePath = await FilePicker.platform.saveFile(
          dialogTitle: l10n.backupPageExportToFile,
          fileName: record.fileName,
        );
        if (savePath == null) return;
        await File(savePath).parent.create(recursive: true);
        await file.copy(savePath);
      } else {
        await Share.shareXFiles([XFile(record.path)], text: record.fileName);
      }
      if (mounted) {
        showAppSnackBar(
          context,
          message: l10n.messageExportSheetExportedAs(record.fileName),
          type: NotificationType.success,
        );
      }
    } catch (e) {
      if (mounted)
        showAppSnackBar(
          context,
          message: l10n.messageExportSheetExportFailed('$e'),
          type: NotificationType.error,
        );
    }
  }

  Future<void> _showFileActions(FileRecord record) async {
    final l10n = AppLocalizations.of(context)!;
    final isDesktop =
        Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    final items = <DesktopContextMenuItem>[
      DesktopContextMenuItem(
        icon: Lucide.FolderOpen,
        label: l10n.chatMessageWidgetShowInFolder,
        onTap: () => _showFileInFolder(record),
      ),
      DesktopContextMenuItem(
        icon: Lucide.ExternalLink,
        label: l10n.chatMessageWidgetOpenExternally,
        onTap: () => _openFileExternally(record),
      ),
      DesktopContextMenuItem(
        icon: Lucide.Download,
        label: l10n.chatMessageWidgetDownload,
        onTap: () => _downloadFile(record),
      ),
    ];
    if (isDesktop) {
      await showDesktopContextMenuAt(
        context,
        globalPosition: DesktopMenuAnchor.positionOrCenter(context),
        items: items,
      );
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final item in items)
              ListTile(
                leading: item.icon == null ? null : Icon(item.icon),
                title: Text(item.label),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  item.onTap?.call();
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _previewFile(FileRecord record) async {
    final l10n = AppLocalizations.of(context)!;
    final fixed = SandboxPathResolver.fix(record.path);
    final file = File(fixed);
    if (!await file.exists()) {
      if (mounted) {
        showAppSnackBar(
          context,
          message: l10n.chatMessageWidgetFileNotFound(record.fileName),
          type: NotificationType.error,
        );
      }
      return;
    }
    final ext = _fileExtension(record.fileName);
    if (_previewableImageExts.contains(ext)) {
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ImageViewerPage(images: [fixed], initialIndex: 0),
        ),
      );
      return;
    }
    if (_previewableTextExts.contains(ext)) {
      try {
        final length = await file.length();
        if (length > _previewMaxTextBytes) {
          await _openFileExternally(record);
          return;
        }
        final content = await file.readAsString();
        if (!mounted) return;
        await _pushTextPreview(content, ext);
        return;
      } catch (_) {
        // Reading as text failed (e.g. binary or encoding); fall back to the
        // system default app so the user can still open the file.
        if (!mounted) return;
        await _openFileExternally(record);
        return;
      }
    }
    await _openFileExternally(record);
  }

  Future<void> _pushTextPreview(String content, String ext) async {
    String html;
    var isXml = false;
    if (ext == 'md' || ext == 'markdown') {
      html = await MarkdownPreviewHtmlBuilder.buildFromMarkdown(
        context,
        content,
      );
    } else if (ext == 'xml' || ext == 'svg') {
      html = content;
      isXml = true;
    } else if (ext == 'html' || ext == 'htm') {
      html = content;
    } else {
      html =
          '<pre style="white-space: pre-wrap; word-break: break-word;">'
          '${_escapeHtml(content)}</pre>';
    }
    if (!mounted) return;
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      await showHtmlPreviewDesktopDialog(context, html: html, isXml: isXml);
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => HtmlPreviewPage(html: html, isXml: isXml),
      ),
    );
  }

  static const Set<String> _previewableImageExts = {
    'png',
    'jpg',
    'jpeg',
    'gif',
    'webp',
    'bmp',
  };

  static const Set<String> _previewableTextExts = {
    'md',
    'markdown',
    'txt',
    'text',
    'json',
    'csv',
    'tsv',
    'html',
    'htm',
    'xml',
    'svg',
    'yaml',
    'yml',
    'log',
    'ini',
    'conf',
    'cfg',
    'toml',
    'css',
    'js',
    'jsx',
    'ts',
    'tsx',
    'py',
    'dart',
    'java',
    'c',
    'cpp',
    'h',
    'hpp',
    'go',
    'rs',
    'sh',
    'bat',
    'ps1',
    'sql',
    'php',
    'rb',
    'kt',
    'swift',
  };

  static const int _previewMaxTextBytes = 2 * 1024 * 1024;

  String _fileExtension(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot <= 0 || dot == fileName.length - 1) return '';
    return fileName.substring(dot + 1).toLowerCase();
  }

  String _escapeHtml(String input) {
    return input
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
  }

  Widget _buildFileCardsSection(List<FileRecord> records) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: records.map((record) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: IosCardPress(
              borderRadius: BorderRadius.circular(12),
              baseColor: cs.primaryContainer.withOpacity(0.24),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              onTap: () => _previewFile(record),
              child: Row(
                children: [
                  Icon(Lucide.FileText, size: 20, color: cs.primary),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          record.fileName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _formatFileSize(record.sizeBytes),
                          style: TextStyle(
                            fontSize: 12,
                            color: cs.onSurface.withOpacity(0.6),
                          ),
                        ),
                      ],
                    ),
                  ),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (d) {
                      if (Platform.isWindows ||
                          Platform.isLinux ||
                          Platform.isMacOS) {
                        DesktopMenuAnchor.setPosition(d.globalPosition);
                      }
                    },
                    onTap: () => _showFileActions(record),
                    child: IosIconButton(
                      size: 18,
                      padding: const EdgeInsets.all(4),
                      minSize: 32,
                      icon: Lucide.MoreVertical,
                      color: cs.onSurface.withOpacity(0.55),
                      semanticLabel: AppLocalizations.of(
                        context,
                      )!.chatMessageWidgetFileActions,
                      onTap: null,
                    ),
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  _ParsedUserContent _parseUserContent(String raw) {
    final imgRe = RegExp(r"\[image:(.+?)\]");
    final fileRe = RegExp(r"\[file:(.+?)\|(.+?)\|(.+?)\]");
    final images = <String>[];
    final docs = <_DocRef>[];
    final buffer = StringBuffer();
    int idx = 0;
    while (idx < raw.length) {
      final m1 = imgRe.matchAsPrefix(raw, idx);
      final m2 = fileRe.matchAsPrefix(raw, idx);
      if (m1 != null) {
        final p = m1.group(1)?.trim();
        if (p != null && p.isNotEmpty) images.add(p);
        idx = m1.end;
        continue;
      }
      if (m2 != null) {
        final path = m2.group(1)?.trim() ?? '';
        final name = m2.group(2)?.trim() ?? 'file';
        final mime = m2.group(3)?.trim() ?? 'text/plain';
        docs.add(_DocRef(path: path, fileName: name, mime: mime));
        idx = m2.end;
        continue;
      }
      buffer.write(raw[idx]);
      idx++;
    }
    return _ParsedUserContent(buffer.toString().trim(), images, docs);
  }

  Widget _buildAssistantMessage() {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final settings = context.watch<SettingsProvider>();
    final assistant = _assistantForMessage();

    // Extract vendor inline <think>...</think> content (if present)
    final extractedThinking = THINKING_REGEX
        .allMatches(widget.message.content)
        .map((m) => (m.group(1) ?? '').trim())
        .where((s) => s.isNotEmpty)
        .join('\n\n');
    // Remove all <think> blocks from the visible assistant content
    final contentWithoutThink = extractedThinking.isNotEmpty
        ? widget.message.content.replaceAll(THINKING_REGEX, '').trim()
        : widget.message.content;
    final visualContent = applyAssistantRegexes(
      contentWithoutThink,
      assistant: assistant,
      scope: AssistantRegexScope.assistant,
      visual: true,
    );
    final visualTranslation = widget.message.translation != null
        ? applyAssistantRegexes(
            widget.message.translation!,
            assistant: assistant,
            scope: AssistantRegexScope.assistant,
            visual: true,
          )
        : null;
    final translationText = visualTranslation ?? widget.message.translation;
    final bool hasTranslation =
        (translationText != null && translationText.isNotEmpty);
    final bool isTranslating =
        translationText == l10n.chatMessageWidgetTranslating;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: Model info and time
          Row(
            children: [
              if (widget.useAssistantAvatar) ...[
                _buildAssistantAvatar(cs),
                const SizedBox(width: 8),
              ] else if (widget.showModelIcon) ...[
                widget.modelIcon ??
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: cs.secondary.withOpacity(0.1),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(Lucide.Bot, size: 18, color: cs.secondary),
                    ),
                const SizedBox(width: 8),
              ],
              if (settings.showModelNameTimestamp || widget.showTokenStats)
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (settings.showModelNameTimestamp)
                        Text(
                          widget.useAssistantAvatar
                              ? (widget.assistantName?.trim().isNotEmpty == true
                                    ? widget.assistantName!.trim()
                                    : 'Assistant')
                              : _resolveModelDisplayName(settings),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: cs.onSurface.withOpacity(0.7),
                          ),
                        ),
                      Builder(
                        builder: (context) {
                          final List<Widget> wrapChildren = [];
                          if (settings.showModelNameTimestamp) {
                            wrapChildren.add(
                              Text(
                                _dateFormat.format(widget.message.timestamp),
                                style: TextStyle(
                                  fontSize: 11,
                                  color: cs.onSurface.withOpacity(0.5),
                                ),
                              ),
                            );
                          }
                          if (widget.showTokenStats) {
                            wrapChildren.add(
                              Text(
                                _buildStatsText(widget.message),
                                style: TextStyle(
                                  fontSize: 11,
                                  color: cs.onSurface.withOpacity(0.5),
                                ),
                              ),
                            );
                          }
                          return wrapChildren.isNotEmpty
                              ? Wrap(
                                  alignment: WrapAlignment.start,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  spacing: 8,
                                  runSpacing: 2,
                                  children: wrapChildren,
                                )
                              : const SizedBox.shrink();
                        },
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          // AI Team proposals section (collapsible, "最終回答") — shown BEFORE reasoning
          if (widget.message.aiTeamProposalsJson != null &&
              widget.message.aiTeamProposalsJson!.isNotEmpty) ...[
            AiTeamProposalsSection(
              data: widget.message.aiTeamProposalsJson!,
              isStreaming: widget.message.isStreaming,
            ),
            const SizedBox(height: 4),
          ],
          // Mixed reasoning and tool sections
          if (widget.reasoningSegments != null &&
              widget.reasoningSegments!.isNotEmpty) ...[
            // Build mixed content using tool index ranges carried by segments
            ...() {
              final List<Widget> mixedContent = [];
              final tools = widget.toolParts ?? const <ToolUIPart>[];
              final segments = widget.reasoningSegments!;

              for (int i = 0; i < segments.length; i++) {
                final seg = segments[i];

                // Add the reasoning segment (if any text) — hidden when
                // “Show Thinking Cards” is off
                if (settings.showThinkingCards && seg.text.isNotEmpty) {
                  mixedContent.add(
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: _ReasoningSection(
                        text: seg.text,
                        expanded: seg.expanded,
                        loading: seg.loading,
                        startAt: seg.startAt,
                        finishedAt: seg.finishedAt,
                        isParentStreaming: widget.message.isStreaming,
                        onToggle: seg.onToggle,
                      ),
                    ),
                  );
                }

                // Determine tool range mapped to this segment: [start, end)
                int start = seg.toolStartIndex;
                final int end = (i < segments.length - 1)
                    ? segments[i + 1].toolStartIndex
                    : tools.length;

                // Clamp to bounds and ensure non-decreasing
                if (start < 0) start = 0;
                if (start > tools.length) start = tools.length;
                final int clampedEnd = end.clamp(start, tools.length);

                for (int k = start; k < clampedEnd; k++) {
                  // Hide builtin_search tool cards; citations still appear via bottom summary card 隐藏内置搜索工具卡片
                  if (tools[k].toolName == 'builtin_search') continue;
                  // “Show Tool Cards” off hides tool-use cards
                  if (!settings.showToolCards) continue;
                  mixedContent.add(
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: _ToolCallItem(part: tools[k]),
                    ),
                  );
                }
              }

              if (mixedContent.isNotEmpty) {
                mixedContent.add(const SizedBox(height: 10));
              }

              return mixedContent;
            }(),
          ] else ...[
            // Fallback to old behavior if no reasoning segments
            // Reasoning preview (if provided) — also support inline <think> blocks
            ...() {
              final hasProvidedReasoning =
                  (widget.reasoningText != null &&
                      widget.reasoningText!.isNotEmpty) ||
                  widget.reasoningLoading;
              final effectiveReasoningText =
                  (widget.reasoningText != null &&
                      widget.reasoningText!.isNotEmpty)
                  ? widget.reasoningText!
                  : extractedThinking;
              final shouldShowReasoning =
                  hasProvidedReasoning || effectiveReasoningText.isNotEmpty;
              if (!settings.showThinkingCards ||
                  !shouldShowReasoning) {
                return const <Widget>[];
              }

              // If using inline <think>, expand by default and treat as loading when streaming until </think> appears
              final usingInlineThink =
                  (widget.reasoningText == null ||
                      widget.reasoningText!.isEmpty) &&
                  extractedThinking.isNotEmpty;
              final effectiveExpanded = usingInlineThink
                  ? (_inlineThinkExpanded ?? true)
                  : widget.reasoningExpanded;
              final collapsedNow =
                  usingInlineThink && (_inlineThinkExpanded == false);
              final effectiveLoading = usingInlineThink
                  ? (widget.message.isStreaming &&
                        !widget.message.content.contains('</think>') &&
                        !collapsedNow)
                  : (widget.reasoningFinishedAt == null);

              return <Widget>[
                _ReasoningSection(
                  text: effectiveReasoningText,
                  expanded: effectiveExpanded,
                  loading: effectiveLoading,
                  startAt: usingInlineThink ? null : widget.reasoningStartAt,
                  finishedAt: usingInlineThink
                      ? null
                      : widget.reasoningFinishedAt,
                  isParentStreaming: widget.message.isStreaming,
                  onToggle: usingInlineThink
                      ? () => setState(() {
                          _inlineThinkExpanded =
                              !(_inlineThinkExpanded ?? true);
                          _inlineThinkManuallyToggled = true;
                        })
                      : widget.onToggleReasoning,
                ),
                const SizedBox(height: 4),
              ];
            }(),
            // Tool call placeholders before content 隐藏内置搜索工具卡片
            if (settings.showToolCards &&
                (widget.toolParts ?? const <ToolUIPart>[])
                    .where((p) => p.toolName != 'builtin_search')
                    .isNotEmpty) ...[
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: widget.toolParts!
                    .where((p) => p.toolName != 'builtin_search') // 隐藏内置搜索工具卡片
                    .map(
                      (p) => Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: _ToolCallItem(part: p),
                      ),
                    )
                    .toList(),
              ),
              const SizedBox(height: 10),
            ] else ...[
              if ((settings.showThinkingCards &&
                      ((widget.reasoningText != null &&
                              widget.reasoningText!.isNotEmpty) ||
                          widget.reasoningLoading ||
                          extractedThinking.isNotEmpty)) ||
                  (widget.message.aiTeamProposalsJson != null &&
                      widget.message.aiTeamProposalsJson!.isNotEmpty))
                const SizedBox(height: 10),
            ],
          ],
          // Message content with markdown support (fill available width)
          Container(
            width: double.infinity,
            child: _buildAssistantBubbleContainer(
              context: context,
              child: (widget.message.isStreaming && visualContent.isEmpty)
                  ? Align(
                      alignment: Alignment.centerLeft,
                      child: Semantics(
                        label: l10n.chatMessageWidgetThinking,
                        child: widget.hideStreamingIndicator
                            ? const SizedBox(height: 16)
                            : const LoadingIndicator(),
                      ),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Builder(
                          builder: (context) {
                            final bool isDesktop =
                                defaultTargetPlatform == TargetPlatform.macOS ||
                                defaultTargetPlatform ==
                                    TargetPlatform.windows ||
                                defaultTargetPlatform == TargetPlatform.linux;
                            final double baseAssistant = isDesktop
                                ? 14.0
                                : 15.7;
                            final contentWidget = DefaultTextStyle.merge(
                              style: TextStyle(
                                fontSize: baseAssistant,
                                height: 1.5,
                              ),
                              child: MarkdownWithCodeHighlight(
                                text: visualContent,
                                onCitationTap: (id) => _handleCitationTap(id),
                                baseStyle: TextStyle(
                                  fontSize: baseAssistant,
                                  height: 1.5,
                                ),
                                isStreaming: widget.message.isStreaming,
                              ),
                            );
                            return RepaintBoundary(
                              child: widget.message.isStreaming
                                  ? contentWidget
                                  : SelectionArea(
                                      key: ValueKey(
                                        'assistant_${widget.message.id}',
                                      ),
                                      child: contentWidget,
                                    ),
                            );
                          },
                        ),
                        // Inline sources removed; show a summary card at bottom instead
                        if (widget.message.isStreaming)
                          Padding(
                            padding: const EdgeInsets.only(left: 4),
                            child: widget.hideStreamingIndicator
                                ? const SizedBox(height: 16)
                                : const LoadingIndicator(),
                          ),
                        // Translation section (collapsible)
                        if (hasTranslation) ...[
                          const SizedBox(height: 12),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              // Match reasoning section background; no border
                              color: Theme.of(context)
                                  .colorScheme
                                  .primaryContainer
                                  .withOpacity(
                                    Theme.of(context).brightness ==
                                            Brightness.dark
                                        ? 0.25
                                        : 0.30,
                                  ),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: AnimatedSize(
                              duration: const Duration(milliseconds: 300),
                              curve: const Cubic(0.2, 0.8, 0.2, 1),
                              alignment: Alignment.topCenter,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  IosCardPress(
                                    onTap: widget.onToggleTranslation,
                                    borderRadius: BorderRadius.circular(12),
                                    baseColor: Colors.transparent,
                                    pressedBlendStrength: 0.12,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 8,
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(
                                          Lucide.Languages,
                                          size: 16,
                                          color: cs.secondary,
                                        ),
                                        const SizedBox(width: 6),
                                        Text(
                                          l10n.chatMessageWidgetTranslation,
                                          style: TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w700,
                                            color: cs.secondary,
                                          ),
                                        ),
                                        const Spacer(),
                                        Icon(
                                          widget.translationExpanded
                                              ? Lucide.ChevronDown
                                              : Lucide.ChevronRight,
                                          size: 18,
                                          color: cs.secondary,
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (widget.translationExpanded) ...[
                                    const SizedBox(height: 8),
                                    if (isTranslating)
                                      Padding(
                                        padding: const EdgeInsets.fromLTRB(
                                          8,
                                          2,
                                          8,
                                          6,
                                        ),
                                        child: Row(
                                          children: [
                                            const LoadingIndicator(),
                                            const SizedBox(width: 8),
                                            Builder(
                                              builder: (context) {
                                                final bool isDesktop =
                                                    defaultTargetPlatform ==
                                                        TargetPlatform.macOS ||
                                                    defaultTargetPlatform ==
                                                        TargetPlatform
                                                            .windows ||
                                                    defaultTargetPlatform ==
                                                        TargetPlatform.linux;
                                                return Text(
                                                  l10n.chatMessageWidgetTranslating,
                                                  style: TextStyle(
                                                    fontSize: isDesktop
                                                        ? 14.0
                                                        : 15.5,
                                                    color: cs.onSurface
                                                        .withOpacity(0.5),
                                                    fontStyle: FontStyle.italic,
                                                  ),
                                                );
                                              },
                                            ),
                                          ],
                                        ),
                                      )
                                    else
                                      Padding(
                                        padding: const EdgeInsets.fromLTRB(
                                          8,
                                          2,
                                          8,
                                          6,
                                        ),
                                        child: RepaintBoundary(
                                          child: Builder(
                                            builder: (context) {
                                              final bool isDesktop =
                                                  defaultTargetPlatform ==
                                                      TargetPlatform.macOS ||
                                                  defaultTargetPlatform ==
                                                      TargetPlatform.windows ||
                                                  defaultTargetPlatform ==
                                                      TargetPlatform.linux;
                                              final double baseTranslation =
                                                  isDesktop ? 14.0 : 15.5;
                                              final bool translationInProgress =
                                                  translationText ==
                                                  AppLocalizations.of(
                                                    context,
                                                  )!.chatMessageWidgetTranslating;
                                              final translationWidget =
                                                  DefaultTextStyle.merge(
                                                    style: TextStyle(
                                                      fontSize: baseTranslation,
                                                      height: 1.4,
                                                    ),
                                                    child: MarkdownWithCodeHighlight(
                                                      text: translationText!,
                                                      onCitationTap: (id) =>
                                                          _handleCitationTap(
                                                            id,
                                                          ),
                                                      baseStyle: TextStyle(
                                                        fontSize:
                                                            baseTranslation,
                                                        height: 1.4,
                                                      ),
                                                      isStreaming:
                                                          widget
                                                              .message
                                                              .isStreaming ||
                                                          translationInProgress,
                                                    ),
                                                  );
                                              return (widget
                                                          .message
                                                          .isStreaming ||
                                                      translationInProgress)
                                                  ? translationWidget
                                                  : SelectionArea(
                                                      key: ValueKey(
                                                        'translation_${widget.message.id}',
                                                      ),
                                                      child: translationWidget,
                                                    );
                                            },
                                          ),
                                        ),
                                      ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
            ),
          ),
          if (_messageFileRecords().isNotEmpty)
            _buildFileCardsSection(_messageFileRecords()),
          // Sources summary card (tap to open full citations)
          if (_allSearchItems().isNotEmpty) ...[
            const SizedBox(height: 8),
            _SourcesSummaryCard(
              count: _allSearchItems().length,
              items: _allSearchItems(),
              onTap: () => _showCitationsSheet(_allSearchItems()),
            ),
          ],
          // Action buttons (hidden while generating)
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, anim) => SizeTransition(
              sizeFactor: anim,
              axisAlignment: -1,
              child: FadeTransition(opacity: anim, child: child),
            ),
            child: widget.message.isStreaming
                ? const SizedBox.shrink()
                : Padding(
                    key: const ValueKey('assistant-actions'),
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 28,
                          height: 28,
                          child: Center(
                            child: IosIconButton(
                              size: 16,
                              padding: EdgeInsets.all(4),
                              icon: Lucide.Copy,
                              color: cs.onSurface.withOpacity(0.9),
                              onTap:
                                  widget.onCopy ??
                                  () async {
                                    await _copyFormattedText(
                                      widget.message.content,
                                    );
                                    if (mounted) {
                                      showAppSnackBar(
                                        context,
                                        message: l10n
                                            .chatMessageWidgetCopiedToClipboard,
                                        type: NotificationType.success,
                                      );
                                    }
                                  },
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        SizedBox(
                          width: 28,
                          height: 28,
                          child: Center(
                            child: IosIconButton(
                              size: 16,
                              padding: EdgeInsets.all(4),
                              icon: Lucide.RefreshCw,
                              color: cs.onSurface.withOpacity(0.9),
                              onTap: widget.onRegenerate,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Consumer<TtsProvider>(
                          builder: (context, tts, _) {
                            final ttsActive = tts.playbackState.isActive;
                            return SizedBox(
                              width: 28,
                              height: 28,
                              child: Center(
                                child: IosIconButton(
                                  size: 16,
                                  padding: EdgeInsets.all(4),
                                  onTap: widget.onSpeak,
                                  color: cs.onSurface.withOpacity(0.9),
                                  builder: (color) => AnimatedSwitcher(
                                    duration: const Duration(milliseconds: 200),
                                    transitionBuilder: (child, anim) =>
                                        ScaleTransition(
                                          scale: anim,
                                          child: FadeTransition(
                                            opacity: anim,
                                            child: child,
                                          ),
                                        ),
                                    child: Icon(
                                      ttsActive
                                          ? Lucide.CircleStop
                                          : Lucide.Volume2,
                                      key: ValueKey(
                                        ttsActive ? 'stop' : 'speak',
                                      ),
                                      size: 16,
                                      color: color,
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                        const SizedBox(width: 6),
                        SizedBox(
                          width: 28,
                          height: 28,
                          child: Center(
                            child: GestureDetector(
                              key: _translateBtnKey2,
                              onTapDown: (d) {
                                final isDesktop =
                                    defaultTargetPlatform ==
                                        TargetPlatform.macOS ||
                                    defaultTargetPlatform ==
                                        TargetPlatform.windows ||
                                    defaultTargetPlatform ==
                                        TargetPlatform.linux;
                                if (isDesktop) {
                                  try {
                                    DesktopMenuAnchor.setPosition(
                                      d.globalPosition,
                                    );
                                  } catch (_) {}
                                }
                              },
                              onTap: () {
                                final isDesktop =
                                    defaultTargetPlatform ==
                                        TargetPlatform.macOS ||
                                    defaultTargetPlatform ==
                                        TargetPlatform.windows ||
                                    defaultTargetPlatform ==
                                        TargetPlatform.linux;
                                if (isDesktop) {
                                  _setAnchorFromKey(_translateBtnKey2);
                                }
                                widget.onTranslate?.call();
                              },
                              child: IosIconButton(
                                size: 16,
                                padding: EdgeInsets.all(4),
                                icon: Lucide.Languages,
                                color: cs.onSurface.withOpacity(0.9),
                                onTap: null,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        SizedBox(
                          width: 28,
                          height: 28,
                          child: Center(
                            child: GestureDetector(
                              key: _moreBtnKey2,
                              onTapDown: (d) {
                                final isDesktop =
                                    defaultTargetPlatform ==
                                        TargetPlatform.macOS ||
                                    defaultTargetPlatform ==
                                        TargetPlatform.windows ||
                                    defaultTargetPlatform ==
                                        TargetPlatform.linux;
                                if (isDesktop) {
                                  try {
                                    DesktopMenuAnchor.setPosition(
                                      d.globalPosition,
                                    );
                                  } catch (_) {}
                                }
                              },
                              onTap: () {
                                final isDesktop =
                                    defaultTargetPlatform ==
                                        TargetPlatform.macOS ||
                                    defaultTargetPlatform ==
                                        TargetPlatform.windows ||
                                    defaultTargetPlatform ==
                                        TargetPlatform.linux;
                                if (isDesktop) {
                                  _setAnchorFromKey(_moreBtnKey2);
                                }
                                widget.onMore?.call();
                              },
                              child: IosIconButton(
                                size: 16,
                                padding: EdgeInsets.all(4),
                                icon: Lucide.Ellipsis,
                                color: cs.onSurface.withOpacity(0.9),
                                onTap: null,
                              ),
                            ),
                          ),
                        ),
                        if ((widget.versionCount ?? 1) > 1) ...[
                          const SizedBox(width: 6),
                          _BranchSelector(
                            index: widget.versionIndex ?? 0,
                            total: widget.versionCount ?? 1,
                            onPrev: widget.onPrevVersion,
                            onNext: widget.onNextVersion,
                          ),
                        ],
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  // Try resolve citation id -> url from all search_web/builtin_search tool results of this assistant message
  void _handleCitationTap(String id) async {
    final l10n = AppLocalizations.of(context)!;
    final items = _allSearchItems();
    Map<String, dynamic>? match = items
        .cast<Map<String, dynamic>?>()
        .firstWhere(
          (e) => (e?['id']?.toString() ?? '') == id,
          orElse: () => null,
        );

    // Fallbacks for models that don't strictly follow "index:id":
    // 1) If id is actually an index number, match by item.index.
    // 2) If id itself looks like a URL, open it directly.
    String? url = match?['url']?.toString();
    if (url == null || url.isEmpty) {
      final idx = int.tryParse(id.trim());
      if (idx != null) {
        match = items.cast<Map<String, dynamic>?>().firstWhere(
          (e) => (e?['index']?.toString() ?? '') == idx.toString(),
          orElse: () => null,
        );
        url = match?['url']?.toString();
      }
    }
    if ((url == null || url.isEmpty) &&
        (id.contains('/') || id.contains('.'))) {
      url = id;
    }

    if (url == null || url.isEmpty) {
      if (context.mounted) {
        showAppSnackBar(
          context,
          message: l10n.chatMessageWidgetCitationNotFound,
          type: NotificationType.warning,
        );
      }
      return;
    }
    try {
      final uri = _tryNormalizeExternalUri(url);
      if (uri == null) {
        if (!context.mounted) return;
        showAppSnackBar(
          context,
          message: l10n.chatMessageWidgetOpenLinkError,
          type: NotificationType.error,
        );
        return;
      }
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && context.mounted) {
        showAppSnackBar(
          context,
          message: l10n.chatMessageWidgetCannotOpenUrl(uri.toString()),
          type: NotificationType.error,
        );
      }
    } catch (_) {
      if (context.mounted) {
        showAppSnackBar(
          context,
          message: l10n.chatMessageWidgetOpenLinkError,
          type: NotificationType.error,
        );
      }
    }
  }

  // Extract items from all search_web or builtin_search tool results for this assistant message
  List<Map<String, dynamic>> _allSearchItems() {
    final parts = widget.toolParts ?? const <ToolUIPart>[];
    if (parts.isEmpty) return const <Map<String, dynamic>>[];

    final out = <Map<String, dynamic>>[];
    final seen = <String>{};

    for (int i = parts.length - 1; i >= 0; i--) {
      final p = parts[i];
      if ((p.toolName != 'search_web' && p.toolName != 'builtin_search') ||
          (p.content?.isNotEmpty ?? false) == false) {
        continue;
      }
      try {
        final obj = jsonDecode(p.content!) as Map<String, dynamic>;
        final arr = obj['items'] as List? ?? const <dynamic>[];
        for (final it in arr) {
          if (it is! Map) continue;
          final m = it.cast<String, dynamic>();
          final key = (m['id'] ?? m['url'] ?? '').toString();
          if (key.isNotEmpty) {
            if (!seen.add(key)) continue;
          }
          out.add(m);
        }
      } catch (_) {}
    }
    return out;
  }

  void _showCitationsSheet(List<Map<String, dynamic>> items) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final bool isDesktop =
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux;

    if (isDesktop) {
      showDialog<void>(
        context: context,
        barrierDismissible: true,
        builder: (ctx) {
          return Dialog(
            elevation: 12,
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 24,
              vertical: 24,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minWidth: 380,
                maxWidth: 460,
                maxHeight: 360,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Material(
                  color: cs.surface,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Header
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                        child: Row(
                          children: [
                            Icon(Lucide.BookOpen, size: 18, color: cs.primary),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                l10n.chatMessageWidgetCitationsTitle(
                                  items.length,
                                ),
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            Tooltip(
                              message: l10n.mcpPageClose,
                              child: IconButton(
                                icon: Icon(
                                  Lucide.X,
                                  size: 18,
                                  color: cs.onSurface.withOpacity(0.75),
                                ),
                                onPressed: () => Navigator.of(ctx).maybePop(),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 4),
                      // Body
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                          child: SingleChildScrollView(
                            child: Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  for (int i = 0; i < items.length; i++)
                                    _SourceRow(
                                      index: (items[i]['index'] ?? (i + 1))
                                          .toString(),
                                      title: (items[i]['title'] ?? '')
                                          .toString(),
                                      url: (items[i]['url'] ?? '').toString(),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      );
      return;
    }

    // Mobile: keep bottom sheet
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: cs.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        final bottomInset = MediaQuery.viewInsetsOf(ctx).bottom;
        return SafeArea(
          child: FractionallySizedBox(
            heightFactor: 0.5,
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, bottomInset + 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Lucide.BookOpen, size: 18, color: cs.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          l10n.chatMessageWidgetCitationsTitle(items.length),
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: SingleChildScrollView(
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (int i = 0; i < items.length; i++)
                              _SourceRow(
                                index: (items[i]['index'] ?? (i + 1))
                                    .toString(),
                                title: (items[i]['title'] ?? '').toString(),
                                url: (items[i]['url'] ?? '').toString(),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildAssistantAvatar(ColorScheme cs) {
    final av = (widget.assistantAvatar ?? '').trim();
    if (av.isNotEmpty) {
      if (av.startsWith('http')) {
        return FutureBuilder<String?>(
          future: AvatarCache.getPath(av),
          builder: (ctx, snap) {
            final p = snap.data;
            if (p != null && File(p).existsSync()) {
              return ClipOval(
                child: Image.file(
                  File(p),
                  width: 32,
                  height: 32,
                  fit: BoxFit.cover,
                ),
              );
            }
            return ClipOval(
              child: Image.network(
                av,
                width: 32,
                height: 32,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _assistantInitial(cs),
              ),
            );
          },
        );
      }
      if (av.startsWith('/') || av.contains(':')) {
        final fixed = SandboxPathResolver.fix(av);
        final f = File(fixed);
        if (f.existsSync()) {
          return ClipOval(
            child: Image.file(f, width: 32, height: 32, fit: BoxFit.cover),
          );
        }
        return _assistantInitial(cs);
      }
      // treat as emoji or single char label
      final bool isIOS = defaultTargetPlatform == TargetPlatform.iOS;
      final double fs = 18;
      final Offset? nudge = isIOS ? Offset(fs * 0.065, fs * -0.05) : null;
      return Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: cs.primary.withOpacity(0.1),
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: EmojiText(
          av.characters.take(1).toString(),
          fontSize: fs,
          optimizeEmojiAlign: true,
          nudge: nudge,
        ),
      );
    }
    return _assistantInitial(cs);
  }

  Widget _assistantInitial(ColorScheme cs) {
    final name = (widget.assistantName ?? '').trim();
    final ch = name.isNotEmpty ? name.characters.first.toUpperCase() : 'A';
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: cs.primary.withOpacity(0.1),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        ch,
        style: TextStyle(color: cs.primary, fontWeight: FontWeight.w700),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    if (widget.message.role == 'user') return _buildUserMessage();
    if (widget.message.role == 'tool') {
      return settings.showToolCards
          ? _buildToolMessage()
          : const SizedBox.shrink();
    }
    return _buildAssistantMessage();
  }
}

class _AnimatedPopup extends StatefulWidget {
  const _AnimatedPopup({required this.child});
  final Widget child;

  @override
  State<_AnimatedPopup> createState() => _AnimatedPopupState();
}

class _AnimatedPopupState extends State<_AnimatedPopup> {
  double _opacity = 0.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _opacity = 1.0;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOutCubic,
      opacity: _opacity,
      child: widget.child,
    );
  }
}

class _MenuItem extends StatelessWidget {
  const _MenuItem({
    required this.icon,
    required this.label,
    this.onTap,
    this.danger = false,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fg = danger ? Colors.red.shade600 : cs.onSurface;
    final ic = danger ? Colors.red.shade600 : cs.onSurface.withOpacity(0.9);
    // iOS-style press effect: no ripple. Use transparent base and a subtle
    // pressed blend inside the blurred/glass menu container.
    return IosCardPress(
      borderRadius: BorderRadius.zero,
      baseColor: Colors.transparent,
      onTap: () {
        try {
          Haptics.light();
        } catch (_) {}
        onTap?.call();
      },
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.centerLeft,
        child: Row(
          children: [
            Icon(icon, size: 18, color: ic),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 14.5,
                  color: fg,
                  decoration: TextDecoration.none,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BranchSelector extends StatelessWidget {
  const _BranchSelector({
    required this.index,
    required this.total,
    this.onPrev,
    this.onNext,
  });
  final int index; // zero-based
  final int total;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final canPrev = index > 0;
    final canNext = index < total - 1;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 28,
          height: 28,
          child: Center(
            child: IosIconButton(
              size: 16,
              enabled: canPrev,
              color: cs.onSurface,
              icon: Lucide.ChevronLeft,
              onTap: canPrev ? onPrev : null,
            ),
          ),
        ),
        SizedBox(
          width: 28,
          height: 28,
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                '${index + 1}/$total',
                style: TextStyle(
                  fontSize: 12,
                  color: cs.onSurface.withOpacity(0.8),
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 1,
                softWrap: false,
              ),
            ),
          ),
        ),
        SizedBox(
          width: 28,
          height: 28,
          child: Center(
            child: IosIconButton(
              size: 16,
              enabled: canNext,
              color: cs.onSurface,
              icon: Lucide.ChevronRight,
              onTap: canNext ? onNext : null,
            ),
          ),
        ),
      ],
    );
  }
}

// Pulsing 3-dot loading indicator for chat thinking states (shared)
class LoadingIndicator extends StatefulWidget {
  const LoadingIndicator({super.key});
  @override
  State<LoadingIndicator> createState() => _LoadingIndicatorState();
}

class _LoadingIndicatorState extends State<LoadingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1100),
      vsync: this,
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  double _dotValue(int index) {
    final phase = (_controller.value - index * 0.22) * 2 * math.pi;
    return (math.sin(phase) + 1) / 2; // 0 -> 1 wave
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final base = cs.primary;

    return SizedBox(
      height: 16,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(3, (i) {
              final wave = _dotValue(i);
              final double scale = 0.85 + 0.15 * wave; // subtle breathing
              final double opacity = 0.45 + 0.45 * wave;
              return Padding(
                padding: EdgeInsets.only(right: i == 2 ? 0 : 6),
                child: Transform.scale(
                  scale: scale,
                  child: Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: base.withOpacity(opacity),
                    ),
                  ),
                ),
              );
            }),
          );
        },
      ),
    );
  }
}

class _ParsedUserContent {
  final String text;
  final List<String> images;
  final List<_DocRef> docs;
  _ParsedUserContent(this.text, this.images, this.docs);
}

class _DocRef {
  final String path;
  final String fileName;
  final String mime;
  _DocRef({required this.path, required this.fileName, required this.mime});
}

// UI data for MCP tool calls/results
class ToolUIPart {
  final String id;
  final String toolName;
  final Map<String, dynamic> arguments;
  final String? content; // null means still loading/result not yet available
  final bool loading;
  const ToolUIPart({
    required this.id,
    required this.toolName,
    required this.arguments,
    this.content,
    this.loading = false,
  });
}

// Data for a reasoning segment (for mixed display)
class ReasoningSegment {
  final String text;
  final bool expanded;
  final bool loading;
  final DateTime? startAt;
  final DateTime? finishedAt;
  final VoidCallback? onToggle;
  // Index of the first tool call that occurs after this segment starts.
  final int toolStartIndex;

  const ReasoningSegment({
    required this.text,
    required this.expanded,
    required this.loading,
    this.startAt,
    this.finishedAt,
    this.onToggle,
    this.toolStartIndex = 0,
  });
}

class _ToolCallItem extends StatelessWidget {
  const _ToolCallItem({required this.part});
  final ToolUIPart part;

  IconData _iconFor(String name) {
    switch (name) {
      case 'create_memory':
        return Lucide.bookHeart;
      case 'edit_memory':
        return Lucide.bookHeart;
      case 'delete_memory':
        return Lucide.bookDashed;
      case 'search_web':
        return Lucide.Earth;
      case 'builtin_search':
        return Lucide.Search;
      default:
        return Lucide.Wrench;
    }
  }

  String _titleFor(
    BuildContext context,
    String name,
    Map<String, dynamic> args, {
    required bool isResult,
  }) {
    final l10n = AppLocalizations.of(context)!;
    switch (name) {
      case 'create_memory':
        return l10n.chatMessageWidgetCreateMemory;
      case 'edit_memory':
        return l10n.chatMessageWidgetEditMemory;
      case 'delete_memory':
        return l10n.chatMessageWidgetDeleteMemory;
      case 'search_web':
        final q = (args['query'] ?? '').toString();
        return l10n.chatMessageWidgetWebSearch(q);
      case 'builtin_search':
        return l10n.chatMessageWidgetBuiltinSearch;
      default:
        return isResult
            ? l10n.chatMessageWidgetToolResult(name)
            : l10n.chatMessageWidgetToolCall(name);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardTextColor =
        isDark ? const Color(0xFF9E9EA4) : const Color(0xFF7E7F83);

    return IosCardPress(
      borderRadius: BorderRadius.circular(10),
      baseColor: Colors.transparent,
      pressedScale: 1.0,
      duration: const Duration(milliseconds: 260),
      onTap: () => _showDetail(context),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          part.loading
              ? SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(cardTextColor),
                  ),
                )
              : SizedBox(
                  width: 18,
                  height: 18,
                  child: Center(
                    child: Icon(
                      _iconFor(part.toolName),
                      size: 18,
                      color: cardTextColor,
                    ),
                  ),
                ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _titleFor(
                    context,
                    part.toolName,
                    part.arguments,
                    isResult: !part.loading,
                  ),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.normal,
                    color: cardTextColor,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showDetail(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final argsPretty = const JsonEncoder.withIndent(
      '  ',
    ).convert(part.arguments);
    final resultText = (part.content ?? '').isNotEmpty
        ? part.content!
        : l10n.chatMessageWidgetNoResultYet;

    final bool isDesktop =
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux;

    if (isDesktop) {
      showDialog<void>(
        context: context,
        barrierDismissible: true,
        builder: (ctx) {
          return Dialog(
            elevation: 12,
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 24,
              vertical: 24,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minWidth: 360,
                maxWidth: 560,
                maxHeight: 560,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Material(
                  color: cs.surface,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Header
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                        child: Row(
                          children: [
                            Icon(
                              _iconFor(part.toolName),
                              size: 18,
                              color: cs.primary,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _titleFor(
                                  context,
                                  part.toolName,
                                  part.arguments,
                                  isResult: !part.loading,
                                ),
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Tooltip(
                              message: l10n.mcpPageClose,
                              child: IconButton(
                                icon: Icon(
                                  Lucide.X,
                                  size: 18,
                                  color: cs.onSurface.withOpacity(0.75),
                                ),
                                onPressed: () => Navigator.of(ctx).maybePop(),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 4),
                      // Body
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                          child: SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  l10n.chatMessageWidgetArguments,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: cs.onSurface.withOpacity(0.6),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color:
                                        Theme.of(context).brightness ==
                                            Brightness.dark
                                        ? Colors.white10
                                        : const Color(0xFFF7F7F9),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color: cs.outlineVariant.withOpacity(0.2),
                                    ),
                                  ),
                                  child: SelectableText(
                                    argsPretty,
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  l10n.chatMessageWidgetResult,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: cs.onSurface.withOpacity(0.6),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color:
                                        Theme.of(context).brightness ==
                                            Brightness.dark
                                        ? Colors.white10
                                        : const Color(0xFFF7F7F9),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color: cs.outlineVariant.withOpacity(0.2),
                                    ),
                                  ),
                                  child: SelectableText(
                                    resultText,
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      );
      return;
    }

    // Mobile: bottom sheet remains
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: cs.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        final bottomInset = MediaQuery.viewInsetsOf(ctx).bottom;
        return SafeArea(
          child: FractionallySizedBox(
            heightFactor: 0.6,
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, bottomInset + 20),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          _iconFor(part.toolName),
                          size: 18,
                          color: cs.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _titleFor(
                              context,
                              part.toolName,
                              part.arguments,
                              isResult: !part.loading,
                            ),
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      l10n.chatMessageWidgetArguments,
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurface.withOpacity(0.6),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Theme.of(context).brightness == Brightness.dark
                            ? Colors.white10
                            : const Color(0xFFF7F7F9),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: cs.outlineVariant.withOpacity(0.2),
                        ),
                      ),
                      child: SelectableText(
                        argsPretty,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      l10n.chatMessageWidgetResult,
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurface.withOpacity(0.6),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Theme.of(context).brightness == Brightness.dark
                            ? Colors.white10
                            : const Color(0xFFF7F7F9),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: cs.outlineVariant.withOpacity(0.2),
                        ),
                      ),
                      child: SelectableText(
                        resultText,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SourcesList extends StatelessWidget {
  const _SourcesList({required this.items});
  final List<Map<String, dynamic>> items;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    if (items.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant.withOpacity(0.2)),
      ),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              l10n.chatMessageWidgetCitationsTitle(items.length),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: cs.onSurface.withOpacity(0.75),
              ),
            ),
          ),
          for (int i = 0; i < items.length; i++)
            _SourceRow(
              index: (items[i]['index'] ?? (i + 1)).toString(),
              title: (items[i]['title'] ?? '').toString(),
              url: (items[i]['url'] ?? '').toString(),
            ),
        ],
      ),
    );
  }
}

class _SourceRow extends StatelessWidget {
  const _SourceRow({
    required this.index,
    required this.title,
    required this.url,
  });
  final String index;
  final String title;
  final String url;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final domain = _tryNormalizeExternalUri(url)?.host ?? url;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: IosCardPress(
        onTap: () async {
          try {
            final uri = _tryNormalizeExternalUri(url);
            if (uri != null) {
              await launchUrl(uri, mode: LaunchMode.externalApplication);
            }
          } catch (_) {}
        },
        borderRadius: BorderRadius.circular(12),
        baseColor: isDark
            ? cs.surfaceContainerHigh.withValues(alpha: 0.5)
            : cs.surfaceContainer,
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.1)
              : Colors.black.withValues(alpha: 0.05),
          width: 0.5,
        ),
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: _SourceFavicon(domain: domain),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title.isNotEmpty ? title : url,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: cs.onSurface.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          index,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: cs.onSurface.withValues(alpha: 0.6),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          domain,
                          style: TextStyle(
                            fontSize: 12,
                            color: cs.onSurface.withValues(alpha: 0.5),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
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
    );
  }
}

class _SourcesSummaryCard extends StatelessWidget {
  const _SourcesSummaryCard({
    required this.count,
    required this.items,
    required this.onTap,
  });

  final int count;
  final List<Map<String, dynamic>> items;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final label = l10n.chatMessageWidgetCitationsCount(count);
    final isDark = theme.brightness == Brightness.dark;

    return IosCardPress(
      borderRadius: BorderRadius.circular(20),
      border: Border.all(
        color: isDark
            ? Colors.white.withOpacity(0.16)
            : Colors.black.withOpacity(0.10),
        width: 0.8,
      ),
      baseColor: Colors.transparent,
      pressedScale: 1.0,
      duration: const Duration(milliseconds: 260),
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 18),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _SourceFaviconStack(items: items),
            const SizedBox(width: 6),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.clip,
              style: TextStyle(
                fontSize: 12,
                height: 1,
                fontWeight: FontWeight.w600,
                color: cs.onSurface.withOpacity(isDark ? 0.90 : 0.86),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SourceFaviconStack extends StatelessWidget {
  const _SourceFaviconStack({required this.items});

  final List<Map<String, dynamic>> items;

  static const double _iconSize = 16;
  static const double _slotSize = 18;
  static const double _overlapStep = 11;
  static const int _maxIcons = 3;

  @override
  Widget build(BuildContext context) {
    final domains = _domains();
    if (domains.isEmpty) {
      return const _SourceFaviconFallback(size: _slotSize);
    }

    return SizedBox(
      width: _slotSize + (domains.length - 1) * _overlapStep,
      height: _slotSize,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (var i = 0; i < domains.length; i++)
            PositionedDirectional(
              start: i * _overlapStep,
              top: 1,
              child: _SourceFavicon(domain: domains[i]),
            ),
        ],
      ),
    );
  }

  List<String> _domains() {
    final seen = <String>{};
    final domains = <String>[];
    for (final item in items) {
      final url = (item['url'] ?? '').toString();
      final host = _tryNormalizeExternalUri(url)?.host ?? '';
      if (host.isEmpty || !seen.add(host)) {
        continue;
      }
      domains.add(host);
      if (domains.length == _maxIcons) {
        break;
      }
    }
    return domains;
  }
}

class _SourceFavicon extends StatelessWidget {
  const _SourceFavicon({required this.domain});

  final String domain;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final borderColor = isDark ? Colors.black.withOpacity(0.40) : Colors.white;

    return Container(
      width: _SourceFaviconStack._iconSize,
      height: _SourceFaviconStack._iconSize,
      decoration: BoxDecoration(
        color: isDark ? cs.surfaceContainerHigh : cs.surface,
        shape: BoxShape.circle,
        border: Border.all(color: borderColor, width: 0.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: Image.network(
        'https://favicone.com/$domain',
        width: _SourceFaviconStack._iconSize,
        height: _SourceFaviconStack._iconSize,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) =>
            const _SourceFaviconFallback(size: _SourceFaviconStack._iconSize),
      ),
    );
  }
}

class _SourceFaviconFallback extends StatelessWidget {
  const _SourceFaviconFallback({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      width: size,
      height: size,
      child: Icon(
        Lucide.Globe,
        size: size * 0.72,
        color: cs.onSurface.withOpacity(0.52),
      ),
    );
  }
}

/// Context menu for reasoning text selection with "Select All" and "Copy".
class _TextContextMenu extends StatelessWidget {
  const _TextContextMenu({required this.state});
  final SelectableRegionState state;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final l10n = AppLocalizations.of(context)!;
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: state.contextMenuAnchors,
      buttonItems: [
        ContextMenuButtonItem(
          type: ContextMenuButtonType.selectAll,
          onPressed: () {
            state.selectAll();
          },
        ),
        ContextMenuButtonItem(
          type: ContextMenuButtonType.copy,
          onPressed: () {
            state.copySelection(SelectionChangedCause.toolbar);
          },
        ),
      ],
    );
  }
}

class _ReasoningSection extends StatefulWidget {
  const _ReasoningSection({
    required this.text,
    required this.expanded,
    required this.loading,
    required this.startAt,
    required this.finishedAt,
    required this.isParentStreaming,
    this.onToggle,
  });

  final String text;
  final bool expanded;
  final bool loading;
  final DateTime? startAt;
  final DateTime? finishedAt;
  final bool isParentStreaming;
  final VoidCallback? onToggle;

  @override
  State<_ReasoningSection> createState() => _ReasoningSectionState();
}

class _ReasoningSectionState extends State<_ReasoningSection>
    with SingleTickerProviderStateMixin {
  // Use ValueNotifier to only update elapsed time display, not rebuild entire widget
  final ValueNotifier<int> _elapsedTick = ValueNotifier<int>(0);
  late final Ticker _ticker = Ticker((_) {
    if (mounted) _elapsedTick.value++;
  });
  final ScrollController _scroll = ScrollController();
  bool _hasOverflow = false;

  String _sanitize(String s) {
    return s.replaceAll('\r', '').trim();
  }

  String _elapsed() {
    final start = widget.startAt;
    if (start == null) return '';
    final end = widget.finishedAt ?? DateTime.now();
    final ms = end.difference(start).inMilliseconds;
    return '(${(ms / 1000).toStringAsFixed(1)}s)';
  }

  @override
  void initState() {
    super.initState();
    if (widget.loading) _ticker.start();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkOverflow();
      if (widget.loading && _scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  void didUpdateWidget(covariant _ReasoningSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.loading && widget.finishedAt == null) {
      if (!_ticker.isActive) _ticker.start();
    } else {
      if (_ticker.isActive) _ticker.stop();
    }
    if (widget.loading) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkOverflow());
  }

  @override
  void dispose() {
    _ticker.dispose();
    _elapsedTick.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _checkOverflow() {
    if (!_scroll.hasClients) return;
    final over = _scroll.position.maxScrollExtent > 0.5;
    if (over != _hasOverflow && mounted) setState(() => _hasOverflow = over);
  }

  String _sanitizedeepthink(String s) {
    // 统一换行
    s = s.replaceAll('\r\n', '\n');

    // 去掉首尾零宽字符（模型有时会插入）
    s = s
        .replaceAll(RegExp(r'^[\u200B\u200C\u200D\uFEFF]+'), '')
        .replaceAll(RegExp(r'[\u200B\u200C\u200D\uFEFF]+$'), '');

    // 去掉**开头**的纯空白行
    s = s.replaceFirst(RegExp(r'^\s*\n+'), '');

    // 去掉**结尾**的纯空白行
    s = s.replaceFirst(RegExp(r'\n+\s*$'), '');

    return s;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final l10n = AppLocalizations.of(context)!;
    final settings = context.watch<SettingsProvider>();
    final loading = widget.loading;
    final cardTextColor =
        isDark ? const Color(0xFF9E9EA4) : const Color(0xFF7E7F83);

    final curve = const Cubic(0.2, 0.8, 0.2, 1);

    // Build a compact header with optional scrolling preview when loading
    Widget header = IosCardPress(
      borderRadius: BorderRadius.circular(10),
      baseColor: Colors.transparent,
      pressedScale: 1.0,
      duration: const Duration(milliseconds: 220),
      onTap: widget.onToggle,
      padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 0),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(
          children: [
            SvgPicture.asset(
              'assets/icons/deepthink.svg',
              width: 18,
              height: 18,
              colorFilter: ColorFilter.mode(cardTextColor, BlendMode.srcIn),
            ),
            const SizedBox(width: 8),
            _Shimmer(
              enabled: loading,
              child: Text(
                l10n.chatMessageWidgetDeepThinking,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.normal,
                  color: cardTextColor,
                ),
              ),
            ),
            const SizedBox(width: 8),
            if (widget.startAt != null)
              ValueListenableBuilder<int>(
                valueListenable: _elapsedTick,
                builder: (context, _, __) => _Shimmer(
                  enabled: loading,
                  child: Text(
                    _elapsed(),
                    style: TextStyle(
                      fontSize: 13,
                      color: cardTextColor.withValues(alpha: 0.9),
                    ),
                  ),
                ),
              ),
            // No header marquee; content area handles scrolling when loading
            const Spacer(),
            AnimatedRotation(
              turns: widget.expanded ? 0.25 : 0.0, // right -> down
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeInOutCubic,
              child: Icon(Lucide.ChevronRight, size: 18, color: cardTextColor),
            ),
          ],
        ),
      ),
    );

    // 抽公共样式，继承当前 DefaultTextStyle（从而继承正确的颜色）
    final TextStyle baseStyle = DefaultTextStyle.of(
      context,
    ).style.copyWith(fontSize: 12.5, height: 1.32, color: cardTextColor);

    const StrutStyle baseStrut = StrutStyle(
      forceStrutHeight: true,
      fontSize: 12.5,
      height: 1.32,
      leading: 0,
    );

    const TextHeightBehavior baseTHB = TextHeightBehavior(
      applyHeightToFirstAscent: false,
      applyHeightToLastDescent: false,
      leadingDistribution: TextLeadingDistribution.proportional,
    );

    final bool isLoading = loading;
    final display = _sanitize(widget.text);

    // 未加载：不要再指定 color: fg，让它继承和"加载中"相同的颜色
    Widget _reasoningContent(String text) {
      if (settings.enableReasoningMarkdown) {
        final contentWidget = RepaintBoundary(
          child: MarkdownWithCodeHighlight(
            text: text.isNotEmpty ? text : '…',
            baseStyle: baseStyle,
            isStreaming: widget.loading || widget.isParentStreaming,
          ),
        );
        return (widget.loading || widget.isParentStreaming)
            ? contentWidget
            : SelectionArea(
                contextMenuBuilder: (context, selectableRegionState) {
                  return _TextContextMenu(state: selectableRegionState);
                },
                child: contentWidget,
              );
      }
      final contentWidget = Text(
        text.isNotEmpty ? text : '…',
        style: baseStyle,
        strutStyle: baseStrut,
        textHeightBehavior: baseTHB,
      );
      return (widget.loading || widget.isParentStreaming)
          ? contentWidget
          : SelectionArea(
              contextMenuBuilder: (context, selectableRegionState) {
                return _TextContextMenu(state: selectableRegionState);
              },
              child: contentWidget,
            );
    }

    Widget body = Padding(
      padding: const EdgeInsets.fromLTRB(4, 2, 4, 4),
      child: _reasoningContent(display),
    );

    if (isLoading && !widget.expanded) {
      body = Padding(
        padding: const EdgeInsets.fromLTRB(4, 2, 4, 4),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 80),
          child: _hasOverflow
              ? ShaderMask(
                  shaderCallback: (rect) {
                    final h = rect.height;
                    const double topFade = 12.0;
                    const double bottomFade = 28.0;
                    final double sTop = (topFade / h).clamp(0.0, 1.0);
                    final double sBot = (1.0 - bottomFade / h).clamp(0.0, 1.0);
                    return LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: const [
                        Color(0x00FFFFFF),
                        Color(0xFFFFFFFF),
                        Color(0xFFFFFFFF),
                        Color(0x00FFFFFF),
                      ],
                      stops: [0.0, sTop, sBot, 1.0],
                    ).createShader(rect);
                  },
                  blendMode: BlendMode.dstIn,
                  child: NotificationListener<ScrollUpdateNotification>(
                    onNotification: (_) {
                      WidgetsBinding.instance.addPostFrameCallback(
                        (_) => _checkOverflow(),
                      );
                      return false;
                    },
                    child: SingleChildScrollView(
                      controller: _scroll,
                      physics: const BouncingScrollPhysics(),
                      child: _reasoningContent(display),
                    ),
                  ),
                )
              : SingleChildScrollView(
                  controller: _scroll,
                  physics: const NeverScrollableScrollPhysics(),
                  child: _reasoningContent(display),
                ),
        ),
      );
    }

    // Enable long-press text selection in reasoning body
    // body = SelectionArea(child: body);

    return AnimatedSize(
      duration: const Duration(milliseconds: 300),
      curve: curve,
      alignment: Alignment.topCenter,
      child: Container(
        width: double.infinity,
        decoration: const BoxDecoration(
          color: Colors.transparent,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [header, if (widget.expanded || isLoading) body],
          ),
        ),
      ),
    );
  }
}

// Lightweight shimmer effect without external dependency
class _Shimmer extends StatefulWidget {
  final Widget child;
  final bool enabled;
  const _Shimmer({required this.child, this.enabled = false});

  @override
  State<_Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<_Shimmer> with TickerProviderStateMixin {
  late AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    if (widget.enabled) _c.repeat();
  }

  @override
  void didUpdateWidget(covariant _Shimmer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled && !_c.isAnimating) _c.repeat();
    if (!widget.enabled && _c.isAnimating) _c.stop();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        final t = _c.value; // 0..1
        return ShaderMask(
          shaderCallback: (rect) {
            final width = rect.width;
            final gradientWidth = width * 0.4;
            final dx = (width + gradientWidth) * t - gradientWidth;
            final shaderRect = Rect.fromLTWH(
              -dx,
              0,
              width + gradientWidth * 2,
              rect.height,
            );
            return LinearGradient(
              colors: [
                Colors.white.withOpacity(0.0),
                Colors.white.withOpacity(0.35),
                Colors.white.withOpacity(0.0),
              ],
              stops: const [0.0, 0.5, 1.0],
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
            ).createShader(shaderRect);
          },
          blendMode: BlendMode.srcATop,
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

// Simple marquee that bounces horizontally if text exceeds maxWidth
class _Marquee extends StatefulWidget {
  final String text;
  final TextStyle style;
  final double maxWidth;
  final Duration duration;
  const _Marquee({
    required this.text,
    required this.style,
    this.maxWidth = 160,
    this.duration = const Duration(milliseconds: 3000),
  });

  @override
  State<_Marquee> createState() => _MarqueeState();
}

class _MarqueeState extends State<_Marquee>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.duration,
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  double _measure(String text, TextStyle style) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      maxLines: 1,
      textDirection: ui.TextDirection.ltr,
      textScaleFactor: MediaQuery.textScaleFactorOf(context),
    )..layout();
    return tp.width;
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.maxWidth;
    final textWidth = _measure(widget.text, widget.style);
    final needScroll = textWidth > w;
    final gap = 32.0;
    final loopWidth = textWidth + gap;
    return SizedBox(
      width: w,
      height: (widget.style.fontSize ?? 13) * 1.35,
      child: ClipRect(
        child: needScroll
            ? AnimatedBuilder(
                animation: _c,
                builder: (context, _) {
                  final t = Curves.linear.transform(_c.value);
                  final dx = -loopWidth * t;
                  return ShaderMask(
                    shaderCallback: (rect) {
                      return const LinearGradient(
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                        colors: [
                          Color(0x00FFFFFF),
                          Color(0xFFFFFFFF),
                          Color(0xFFFFFFFF),
                          Color(0x00FFFFFF),
                        ],
                        stops: [0.0, 0.07, 0.93, 1.0],
                      ).createShader(rect);
                    },
                    blendMode: BlendMode.dstIn,
                    child: Transform.translate(
                      offset: Offset(dx, 0),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.text,
                            style: widget.style,
                            maxLines: 1,
                            softWrap: false,
                          ),
                          SizedBox(width: gap),
                          Text(
                            widget.text,
                            style: widget.style,
                            maxLines: 1,
                            softWrap: false,
                          ),
                        ],
                      ),
                    ),
                  );
                },
              )
            : Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  widget.text,
                  style: widget.style,
                  maxLines: 1,
                  softWrap: false,
                ),
              ),
      ),
    );
  }
}
