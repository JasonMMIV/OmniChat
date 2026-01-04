import 'dart:async';
import 'dart:io' show File;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_animate/flutter_animate.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:provider/provider.dart';
import '../../../l10n/app_localizations.dart';
import '../../../main.dart';
import '../../../shared/widgets/interactive_drawer.dart';
import '../../../shared/responsive/breakpoints.dart';
import '../../../theme/design_tokens.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/quick_phrase_provider.dart';
import '../../../core/providers/instruction_injection_provider.dart';
import '../../../core/models/chat_input_data.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/services/android_process_text.dart';
import '../../../utils/sandbox_path_resolver.dart';
import '../../../utils/platform_utils.dart';
import '../../../desktop/search_provider_popover.dart';
import '../../../desktop/reasoning_budget_popover.dart';
import '../../../desktop/mcp_servers_popover.dart';
import '../../../desktop/mini_map_popover.dart';
import '../../../desktop/quick_phrase_popover.dart';
import '../../../desktop/instruction_injection_popover.dart';
import '../../chat/widgets/bottom_tools_sheet.dart';
import '../../chat/widgets/reasoning_budget_sheet.dart';
import '../../search/widgets/search_settings_sheet.dart';
import '../../model/widgets/model_select_sheet.dart';
import '../../mcp/pages/mcp_page.dart';
import '../../provider/pages/providers_page.dart';
import '../../assistant/widgets/mcp_assistant_sheet.dart';
import '../../quick_phrase/pages/quick_phrases_page.dart';
import '../../quick_phrase/widgets/quick_phrase_menu.dart';
import '../widgets/chat_input_bar.dart';
import '../widgets/mini_map_sheet.dart';
import '../widgets/instruction_injection_sheet.dart';
import '../widgets/learning_prompt_sheet.dart';
import '../widgets/scroll_nav_buttons.dart';
import '../widgets/selection_toolbar.dart';
import '../widgets/message_list_view.dart';
import '../widgets/chat_input_section.dart';
import '../utils/model_display_helper.dart';
import '../utils/chat_layout_constants.dart';
import '../controllers/home_page_controller.dart';
import 'home_mobile_layout.dart';
import 'home_desktop_layout.dart';

import '../../chat/voice_chat_provider.dart';
import '../../../features/voice_chat/pages/voice_chat_screen.dart' hide VoiceChatState;

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with SingleTickerProviderStateMixin, RouteAware, WidgetsBindingObserver {
  // ============================================================================
  // UI Controllers (owned by State for lifecycle management)
  // ============================================================================

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final InteractiveDrawerController _drawerController = InteractiveDrawerController();
  final ValueNotifier<int> _assistantPickerCloseTick = ValueNotifier<int>(0);
  final FocusNode _inputFocus = FocusNode();
  final TextEditingController _inputController = TextEditingController();
  final ChatInputBarController _mediaController = ChatInputBarController();
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _inputBarKey = GlobalKey();
  StreamSubscription<String>? _processTextSub;

  // ============================================================================
  // Page Controller (manages all business logic and state)
  // ============================================================================

  late HomePageController _controller;
  VoiceChatProvider? _voiceChatProvider;

  // ============================================================================
  // Lifecycle
  // ============================================================================

  @override
  void initState() {
    super.initState();
    try { WidgetsBinding.instance.addObserver(this); } catch (_) {}

    _controller = HomePageController(
      context: context,
      vsync: this,
      scaffoldKey: _scaffoldKey,
      inputBarKey: _inputBarKey,
      inputFocus: _inputFocus,
      inputController: _inputController,
      mediaController: _mediaController,
      scrollController: _scrollController,
    );

    _controller.addListener(_onControllerChanged);
    _drawerController.addListener(_onDrawerValueChanged);

    _controller.initChat();
    _initProcessText();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _controller.measureInputBar();
      // Initialize voice chat provider listener
      _voiceChatProvider = context.read<VoiceChatProvider>();
      _voiceChatProvider?.addListener(_onVoiceChatStateChanged);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) {
      routeObserver.subscribe(this, route);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _controller.onAppLifecycleStateChanged(state);
  }

  @override
  void didPushNext() {
    _controller.onDidPushNext();
  }

  @override
  void didPopNext() {
    _controller.onDidPopNext();
  }

  @override
  void dispose() {
    try { WidgetsBinding.instance.removeObserver(this); } catch (_) {}
    _voiceChatProvider?.removeListener(_onVoiceChatStateChanged);
    _processTextSub?.cancel();
    _controller.removeListener(_onControllerChanged);
    _drawerController.removeListener(_onDrawerValueChanged);
    _inputFocus.dispose();
    _inputController.dispose();
    _scrollController.dispose();
    _controller.dispose();
    routeObserver.unsubscribe(this);
    super.dispose();
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  void _onDrawerValueChanged() {
    _controller.onDrawerValueChanged(_drawerController.value);
    // Close assistant picker when drawer closes
    if (_drawerController.value < 0.95) {
      final sp = context.read<SettingsProvider>();
      if (!sp.keepAssistantListExpandedOnSidebarClose) {
        _assistantPickerCloseTick.value++;
      }
    }
  }

  void _initProcessText() {
    if (!PlatformUtils.isAndroid) return;
    AndroidProcessText.ensureInitialized();
    _processTextSub = AndroidProcessText.stream.listen(_handleProcessText);
    AndroidProcessText.getInitialText().then((text) {
      if (text != null) {
        _handleProcessText(text);
      }
    });
  }

  void _handleProcessText(String text) {
    if (!mounted) return;
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final current = _inputController.text;
    final selection = _inputController.selection;
    final start = (selection.start >= 0 && selection.start <= current.length)
        ? selection.start
        : current.length;
    final end = (selection.end >= 0 && selection.end <= current.length && selection.end >= start)
        ? selection.end
        : start;
    final next = current.replaceRange(start, end, trimmed);
    _inputController.value = _inputController.value.copyWith(
      text: next,
      selection: TextSelection.collapsed(offset: start + trimmed.length),
      composing: TextRange.empty,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _controller.forceScrollToBottomSoon(animate: false);
      _inputFocus.requestFocus();
    });
  }

  // Voice Chat Logic
  void _onVoiceChatStateChanged() {
    if (!mounted) return;
    if (_voiceChatProvider!.state == VoiceChatState.idle && _voiceChatProvider!.lastWords.isNotEmpty) {
      final lastWords = _voiceChatProvider!.lastWords;
      _voiceChatProvider!.clearLastWords();
      _controller.sendMessage(ChatInputData(text: lastWords));
    }
  }

  void _startVoiceChat() async {
    if (_controller.currentConversation == null) {
      await _controller.createNewConversationAnimated();
    }
    // Navigate to the voice chat screen
    Navigator.of(context).push(
      MaterialPageRoute(builder: (context) => VoiceChatScreen()),
    );
  }

  // ============================================================================
  // Build Methods
  // ============================================================================

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final cs = Theme.of(context).colorScheme;
    final settings = context.watch<SettingsProvider>();
    final assistant = context.watch<AssistantProvider>().currentAssistant;

    final modelInfo = getModelDisplayInfo(settings, assistant: assistant);

    final title = ((_controller.currentConversation?.title ?? '').trim().isNotEmpty)
        ? _controller.currentConversation!.title
        : _controller.titleForLocale();

    if (width >= AppBreakpoints.tablet) {
      return _buildTabletLayout(
        context,
        title: title,
        providerName: modelInfo.providerName,
        modelDisplay: modelInfo.modelDisplay,
        cs: cs,
      );
    }

    return _buildMobileLayout(
      context,
      title: title,
      providerName: modelInfo.providerName,
      modelDisplay: modelInfo.modelDisplay,
      cs: cs,
    );
  }

  Widget _buildMobileLayout(
    BuildContext context, {
    required String title,
    required String? providerName,
    required String? modelDisplay,
    required ColorScheme cs,
  }) {
    return HomeMobileScaffold(
      scaffoldKey: _scaffoldKey,
      drawerController: _drawerController,
      assistantPickerCloseTick: _assistantPickerCloseTick,
      loadingConversationIds: _controller.loadingConversationIds,
      title: title,
      providerName: providerName,
      modelDisplay: modelDisplay,
      onToggleDrawer: () => _drawerController.toggle(),
      onDismissKeyboard: _controller.dismissKeyboard,
      onSelectConversation: (id) {
        _controller.switchConversationAnimated(id);
      },
      onNewConversation: () async {
        await _controller.createNewConversationAnimated();
      },
      onOpenMiniMap: () async {
        final collapsed = _controller.collapseVersions(_controller.messages);
        String? selectedId;
        if (PlatformUtils.isDesktop) {
          selectedId = await showDesktopMiniMapPopover(context, anchorKey: _inputBarKey, messages: collapsed);
        } else {
          selectedId = await showMiniMapSheet(context, collapsed);
        }
        if (!mounted) return;
        if (selectedId != null && selectedId.isNotEmpty) {
          await _controller.scrollToMessageId(selectedId);
        }
      },
      onCreateNewConversation: () async {
        await _controller.createNewConversationAnimated();
        if (mounted) {
          _controller.forceScrollToBottomSoon(animate: false);
        }
      },
      onSelectModel: () => showModelSelectSheet(context),
      onVoiceChat: _startVoiceChat,
      body: _wrapWithDropTarget(_buildMobileBody(context, cs)),
    );
  }

  Widget _buildMobileBody(BuildContext context, ColorScheme cs) {
    return Stack(
      children: [
        // Background
        _buildChatBackground(context, cs),
        // Main content
        Padding(
          padding: EdgeInsets.only(top: kToolbarHeight + MediaQuery.paddingOf(context).top),
          child: Column(
            children: [
              Expanded(
                child: Builder(
                  builder: (context) {
                    final content = KeyedSubtree(
                      key: ValueKey<String>(_controller.currentConversation?.id ?? 'none'),
                      child: _buildMessageListView(
                        context,
                        dividerPadding: const EdgeInsets.symmetric(vertical: 10, horizontal: AppSpacing.md),
                      ),
                    );
                    final isAndroid = Theme.of(context).platform == TargetPlatform.android;
                    Widget w = content;
                    if (!isAndroid) {
                      w = w
                          .animate(key: ValueKey('mob_body_'+(_controller.currentConversation?.id ?? 'none')))
                          .fadeIn(duration: 200.ms, curve: Curves.easeOutCubic);
                      w = FadeTransition(opacity: _controller.convoFade, child: w);
                    }
                    return w;
                  },
                ),
              ),
              // Input bar
              NotificationListener<SizeChangedLayoutNotification>(
                onNotification: (n) {
                  WidgetsBinding.instance.addPostFrameCallback((_) => _controller.measureInputBar());
                  return false;
                },
                child: SizeChangedLayoutNotifier(
                  child: Builder(
                    builder: (context) => _buildChatInputBar(context, isTablet: false),
                  ),
                ),
              ),
            ],
          ),
        ),
        // Selection toolbar overlay
        _buildSelectionToolbarOverlay(),
        // Scroll navigation buttons
        _buildScrollButtons(),
      ],
    );
  }

  Widget _buildTabletLayout(
    BuildContext context, {
    required String title,
    required String? providerName,
    required String? modelDisplay,
    required ColorScheme cs,
  }) {
    _controller.initDesktopUi();

    return HomeDesktopScaffold(
      scaffoldKey: _scaffoldKey,
      assistantPickerCloseTick: _assistantPickerCloseTick,
      loadingConversationIds: _controller.loadingConversationIds,
      title: title,
      providerName: providerName,
      modelDisplay: modelDisplay,
      tabletSidebarOpen: _controller.tabletSidebarOpen,
      rightSidebarOpen: _controller.rightSidebarOpen,
      embeddedSidebarWidth: _controller.embeddedSidebarWidth,
      rightSidebarWidth: _controller.rightSidebarWidth,
      sidebarMinWidth: HomePageController.sidebarMinWidth,
      sidebarMaxWidth: HomePageController.sidebarMaxWidth,
      onToggleSidebar: _controller.toggleTabletSidebar,
      onToggleRightSidebar: _controller.toggleRightSidebar,
      onSelectConversation: (id) {
        _controller.switchConversationAnimated(id);
      },
      onNewConversation: () async {
        await _controller.createNewConversationAnimated();
      },
      onCreateNewConversation: () async {
        await _controller.createNewConversationAnimated();
        if (mounted) _controller.forceScrollToBottomSoon(animate: false);
      },
      onSelectModel: () => showModelSelectSheet(context),
      onSidebarWidthChanged: _controller.updateSidebarWidth,
      onSidebarWidthChangeEnd: _controller.saveSidebarWidth,
      onRightSidebarWidthChanged: _controller.updateRightSidebarWidth,
      onRightSidebarWidthChangeEnd: _controller.saveRightSidebarWidth,
      buildAssistantBackground: _buildAssistantBackground,
      onVoiceChat: _startVoiceChat,
      body: _wrapWithDropTarget(_buildTabletBody(context, cs)),
    );
  }

  Widget _buildTabletBody(BuildContext context, ColorScheme cs) {
    return Stack(
      children: [
        Padding(
          padding: EdgeInsets.only(top: kToolbarHeight + MediaQuery.paddingOf(context).top),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: FadeTransition(
                  opacity: _controller.convoFade,
                  child: KeyedSubtree(
                    key: ValueKey<String>(_controller.currentConversation?.id ?? 'none'),
                    child: _buildMessageListView(
                      context,
                      dividerPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                    ),
                  ).animate(key: ValueKey('tab_body_'+(_controller.currentConversation?.id ?? 'none')))
                   .fadeIn(duration: 200.ms, curve: Curves.easeOutCubic),
                ),
              ),
              NotificationListener<SizeChangedLayoutNotification>(
                onNotification: (n) {
                  WidgetsBinding.instance.addPostFrameCallback((_) => _controller.measureInputBar());
                  return false;
                },
                child: SizeChangedLayoutNotifier(
                  child: Builder(
                    builder: (context) {
                      Widget input = _buildChatInputBar(context, isTablet: true);
                      input = Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(
                            maxWidth: ChatLayoutConstants.maxInputWidth,
                          ),
                          child: input,
                        ),
                      );
                      return input;
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
        _buildSelectionToolbarOverlay(),
        _buildScrollButtons(),
      ],
    );
  }

  // ============================================================================
  // UI Component Builders
  // ============================================================================

  Widget _buildChatBackground(BuildContext context, ColorScheme cs) {
    return Builder(
      builder: (context) {
        final bg = context.watch<AssistantProvider>().currentAssistant?.background;
        final maskStrength = context.watch<SettingsProvider>().chatBackgroundMaskStrength;
        if (bg == null || bg.trim().isEmpty) return const SizedBox.shrink();
        ImageProvider provider;
        if (bg.startsWith('http')) {
          provider = NetworkImage(bg);
        } else {
          final localPath = SandboxPathResolver.fix(bg);
          final file = File(localPath);
          if (!file.existsSync()) return const SizedBox.shrink();
          provider = FileImage(file);
        }
        return Positioned.fill(
          child: Stack(
            children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    image: DecorationImage(
                      image: provider,
                      fit: BoxFit.cover,
                      colorFilter: ColorFilter.mode(Colors.black.withOpacity(0.04), BlendMode.srcATop),
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: () {
                          final top = (0.20 * maskStrength).clamp(0.0, 1.0);
                          final bottom = (0.50 * maskStrength).clamp(0.0, 1.0);
                          return [
                            cs.background.withOpacity(top),
                            cs.background.withOpacity(bottom),
                          ];
                        }(),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildAssistantBackground(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final assistant = context.watch<AssistantProvider>().currentAssistant;
    final bgRaw = (assistant?.background ?? '').trim();
    Widget? bg;
    if (bgRaw.isNotEmpty) {
      if (bgRaw.startsWith('http')) {
        bg = Image.network(bgRaw, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const SizedBox.shrink());
      } else {
        try {
          final fixed = SandboxPathResolver.fix(bgRaw);
          final f = File(fixed);
          if (f.existsSync()) {
            bg = Image(image: FileImage(f), fit: BoxFit.cover);
          }
        } catch (_) {}
      }
    }
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: cs.background),
          if (bg != null) Opacity(opacity: 0.9, child: bg),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  cs.background.withOpacity(0.08),
                  cs.background.withOpacity(0.36),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageListView(
    BuildContext context, {
    required EdgeInsetsGeometry dividerPadding,
  }) {
    return MessageListView(
      scrollController: _scrollController,
      messages: _controller.messages,
      versionSelections: _controller.versionSelections,
      currentConversation: _controller.currentConversation,
      messageKeys: _controller.messageKeys,
      reasoning: _controller.reasoning,
      reasoningSegments: _controller.reasoningSegments,
      toolParts: _controller.toolParts,
      translations: _buildTranslationUiStates(),
      selecting: _controller.selecting,
      selectedItems: _controller.selectedItems,
      dividerPadding: dividerPadding,
      streamingContentNotifier: _controller.streamingContentNotifier,
      onVersionChange: (groupId, version) async {
        await _controller.setSelectedVersion(groupId, version);
      },
      onRegenerateMessage: (message) => _controller.regenerateAtMessage(message),
      onResendMessage: (message) => _controller.regenerateAtMessage(message),
      onTranslateMessage: (message) => _controller.translateMessage(message),
      onEditMessage: (message) => _controller.editMessage(message),
      onDeleteMessage: (message, byGroup) => _handleDeleteMessage(context, message, byGroup),
      onForkConversation: (message) => _controller.forkConversation(message),
      onShareMessage: (index, messages) => _controller.shareMessage(index, messages),
      onSpeakMessage: (message) => _controller.speakMessage(message),
      onToggleSelection: (messageId, selected) {
        _controller.toggleSelection(messageId, selected);
      },
      onToggleReasoning: (messageId) {
        _controller.toggleReasoning(messageId);
      },
      onToggleTranslation: (messageId) {
        _controller.toggleTranslation(messageId);
      },
      onToggleReasoningSegment: (messageId, segmentIndex) {
        _controller.toggleReasoningSegment(messageId, segmentIndex);
      },
    );
  }

  Widget _buildChatInputBar(BuildContext context, {required bool isTablet}) {
    return ChatInputSection(
      inputBarKey: _inputBarKey,
      inputFocus: _inputFocus,
      inputController: _inputController,
      mediaController: _mediaController,
      isTablet: isTablet,
      isLoading: _controller.isCurrentConversationLoading,
      isToolModel: _controller.isToolModel,
      isReasoningModel: _controller.isReasoningModel,
      isReasoningEnabled: _controller.isReasoningEnabled,
      onMore: _toggleTools,
      onSelectModel: () => showModelSelectSheet(context),
      onLongPressSelectModel: () {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const ProvidersPage()),
        );
      },
      onOpenMcp: () {
        final a = context.read<AssistantProvider>().currentAssistant;
        if (a != null) {
          if (PlatformUtils.isDesktop) {
            showDesktopMcpServersPopover(context, anchorKey: _inputBarKey, assistantId: a.id);
          } else {
            showAssistantMcpSheet(context, assistantId: a.id);
          }
        }
      },
      onLongPressMcp: () {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const McpPage()),
        );
      },
      onOpenSearch: _openSearchSettings,
      onConfigureReasoning: () async {
        final assistant = context.read<AssistantProvider>().currentAssistant;
        if (assistant != null) {
          if (assistant.thinkingBudget != null) {
            context.read<SettingsProvider>().setThinkingBudget(assistant.thinkingBudget);
          }
          await _openReasoningSettings();
          final chosen = context.read<SettingsProvider>().thinkingBudget;
          await context.read<AssistantProvider>().updateAssistant(
            assistant.copyWith(thinkingBudget: chosen),
          );
        }
      },
      onSend: (data) {
        _controller.sendMessage(data);
        _inputController.clear();
        if (PlatformUtils.isMobile) {
          _controller.dismissKeyboard();
        } else {
          _inputFocus.requestFocus();
        }
      },
      onStop: _controller.cancelStreaming,
      onQuickPhrase: _showQuickPhraseMenu,
      onLongPressQuickPhrase: () {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const QuickPhrasesPage()),
        );
      },
      onToggleOcr: () async {
        final sp = context.read<SettingsProvider>();
        await sp.setOcrEnabled(!sp.ocrEnabled);
      },
      onOpenMiniMap: () async {
        final collapsed = _controller.collapseVersions(_controller.messages);
        String? selectedId;
        if (PlatformUtils.isDesktop) {
          selectedId = await showDesktopMiniMapPopover(context, anchorKey: _inputBarKey, messages: collapsed);
        } else {
          selectedId = await showMiniMapSheet(context, collapsed);
        }
        if (!mounted) return;
        if (selectedId != null && selectedId.isNotEmpty) {
          await _controller.scrollToMessageId(selectedId);
        }
      },
      onPickCamera: _controller.onPickCamera,
      onPickPhotos: _controller.onPickPhotos,
      onUploadFiles: _controller.onPickFiles,
      onToggleLearningMode: _openInstructionInjectionPopover,
      onLongPressLearning: _showLearningPromptSheet,
      onClearContext: _controller.clearContext,
    );
  }

  Widget _buildSelectionToolbarOverlay() {
    return Align(
      alignment: Alignment.bottomCenter,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 122),
          child: AnimatedSelectionBar(
            visible: _controller.selecting,
            child: SelectionToolbar(
              onCancel: _controller.cancelSelection,
              onConfirm: _controller.confirmSelection,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildScrollButtons() {
    return Builder(builder: (context) {
      final showSetting = context.watch<SettingsProvider>().showMessageNavButtons;
      if (!showSetting || _controller.messages.isEmpty) return const SizedBox.shrink();
      return ScrollNavButtonsPanel(
        visible: _controller.scrollCtrl.showNavButtons,
        bottomOffset: _controller.inputBarHeight + 12,
        onScrollToTop: _controller.scrollToTop,
        onPreviousMessage: _controller.jumpToPreviousQuestion,
        onNextMessage: _controller.jumpToNextQuestion,
        onScrollToBottom: _controller.forceScrollToBottom,
      );
    });
  }

  Widget _wrapWithDropTarget(Widget child) {
    if (!_controller.isDesktopPlatform) return child;
    return DropTarget(
      onDragEntered: (_) {
        _controller.setDragHovering(true);
      },
      onDragExited: (_) {
        _controller.setDragHovering(false);
      },
      onDragDone: (details) async {
        _controller.setDragHovering(false);
        try {
          final files = details.files;
          await _controller.onFilesDroppedDesktop(files);
        } catch (_) {}
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          child,
          if (_controller.isDragHovering)
            IgnorePointer(
              child: Container(
                color: Colors.black.withOpacity(0.12),
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface.withOpacity(0.95),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Theme.of(context).colorScheme.primary.withOpacity(0.4), width: 2),
                    ),
                    child: Text(
                      AppLocalizations.of(context)!.homePageDropToUpload,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ============================================================================
  // Helpers
  // ============================================================================

  void _openSearchSettings() {
    if (PlatformUtils.isDesktop) {
      showDesktopSearchProviderPopover(context, anchorKey: _inputBarKey);
    } else {
      showSearchSettingsSheet(context);
    }
  }

  void _openReasoningSettings() {
    if (PlatformUtils.isDesktop) {
      showDesktopReasoningBudgetPopover(context, anchorKey: _inputBarKey);
    } else {
      showReasoningBudgetSheet(context);
    }
  }

  void _showQuickPhraseMenu() {
    if (PlatformUtils.isDesktop) {
      showDesktopQuickPhrasePopover(context, anchorKey: _inputBarKey);
    } else {
      final a = context.read<AssistantProvider>().currentAssistant;
      final provider = context.read<QuickPhraseProvider>();
      final phrases = [
        ...provider.globalPhrases,
        if (a != null) ...provider.getForAssistant(a.id),
      ];
      
      final RenderBox? box = _inputBarKey.currentContext?.findRenderObject() as RenderBox?;
      final Offset position = box?.localToGlobal(Offset.zero) ?? Offset.zero;

      showQuickPhraseMenu(
        context: context,
        phrases: phrases,
        position: position,
        onSelected: (p) => _controller.handleQuickPhraseSelection(p),
      );
    }
  }

  void _openInstructionInjectionPopover() {
    if (PlatformUtils.isDesktop) {
      showDesktopInstructionInjectionPopover(context, anchorKey: _inputBarKey);
    } else {
      showInstructionInjectionSheet(context);
    }
  }

  void _showLearningPromptSheet() {
    showLearningPromptSheet(context);
  }

  void _toggleTools() {
    if (PlatformUtils.isDesktop) {
      // Desktop usually doesn't have this 'More' sheet the same way
    } else {
      final a = context.read<AssistantProvider>().currentAssistant;
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (ctx) => BottomToolsSheet(
          onCamera: _controller.onPickCamera,
          onPhotos: _controller.onPickPhotos,
          onUpload: _controller.onPickFiles,
          onClear: _controller.clearContext,
          clearLabel: _controller.clearContextLabel(),
          assistantId: a?.id,
        ),
      );
    }
  }

  Map<String, TranslationUiState> _buildTranslationUiStates() {
    // Map controller translation data to UI states
    return _controller.translations.map((key, value) {
      return MapEntry(
        key,
        TranslationUiState(
          expanded: value.expanded,
          onToggle: () => _controller.toggleTranslation(key),
        ),
      );
    });
  }

  Future<void> _handleDeleteMessage(BuildContext context, ChatMessage message, Map<String, List<ChatMessage>> byGroup) async {
    final l10n = AppLocalizations.of(context)!;
    // Confirm dialog
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.homePageDeleteMessage),
        content: Text(l10n.homePageDeleteMessageConfirm),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l10n.homePageCancel)),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(l10n.homePageDelete),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await _controller.deleteMessage(message, byGroup: byGroup);
    }
  }
}
