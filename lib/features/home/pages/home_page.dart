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
import '../../../core/providers/ai_team_provider.dart';
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
import '../../../desktop/desktop_context_menu.dart';
import '../../chat/widgets/bottom_tools_sheet.dart';
import '../../chat/widgets/reasoning_budget_sheet.dart';
import '../../chat/widgets/context_management_sheet.dart';
import '../../../shared/widgets/loading_dialog_card.dart';
import '../../../shared/widgets/ios_form_text_field.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../theme/app_font_weights.dart';
import '../controllers/home_view_model.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../icons/lucide_adapter.dart';
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
import '../../ai_team/pages/ai_team_page.dart';
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
      onToggleAiTeam: _openAiTeamSettings,
      onClearContext: _controller.clearContext,
      onCompressContext: _handleDesktopCompressContext,
      isDictating: _controller.isDictating,
      onStartDictation: _controller.startDictation,
      onStopDictation: _controller.stopDictation,
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

  Future<void> _openReasoningSettings() async {
    if (PlatformUtils.isDesktop) {
      await showDesktopReasoningBudgetPopover(context, anchorKey: _inputBarKey);
    } else {
      await showReasoningBudgetSheet(context);
    }
  }

  Future<void> _showQuickPhraseMenu() async {
    final ap = context.read<AssistantProvider>();
    final provider = context.read<QuickPhraseProvider>();
    final assistant = ap.currentAssistant;
    final phrases = [
      ...provider.globalPhrases,
      if (assistant != null) ...provider.getForAssistant(assistant.id),
    ];

    if (PlatformUtils.isDesktop) {
      final selected = await showDesktopQuickPhrasePopover(
        context,
        anchorKey: _inputBarKey,
        phrases: phrases,
      );
      if (selected != null) {
        _controller.handleQuickPhraseSelection(selected);
      }
    } else {
      final RenderBox? box = _inputBarKey.currentContext?.findRenderObject() as RenderBox?;
      final Offset position = box?.localToGlobal(Offset.zero) ?? Offset.zero;

      final selected = await showQuickPhraseMenu(
        context: context,
        phrases: phrases,
        position: position,
      );
      if (selected != null) {
        _controller.handleQuickPhraseSelection(selected);
      }
    }
  }

  void _openInstructionInjectionPopover() async {
    final ap = context.read<AssistantProvider>();
    final assistantId = ap.currentAssistant?.id;
    final provider = context.read<InstructionInjectionProvider>();
    if (provider.items.isEmpty) {
        await provider.initialize();
    }
    final items = provider.items;

    if (PlatformUtils.isDesktop) {
      showDesktopInstructionInjectionPopover(
        context,
        anchorKey: _inputBarKey,
        items: items,
        assistantId: assistantId,
      );
    } else {
      showInstructionInjectionSheet(context, assistantId: assistantId);
    }
  }

  void _showLearningPromptSheet() {
    showLearningPromptSheet(context);
  }

  void _openAiTeamSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const AiTeamPage()),
    );
  }

  void _toggleTools(List<DesktopContextMenuItem>? overflowItems) {
    if (PlatformUtils.isDesktop) {
      // Desktop usually doesn't have this 'More' sheet the same way
    } else {
      final a = context.read<AssistantProvider>().currentAssistant;
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (ctx) => BottomToolsSheet(
          overflowItems: overflowItems,
          onCamera: _controller.onPickCamera,
          onPhotos: _controller.onPickPhotos,
          onUpload: _controller.onPickFiles,
          onClear: () async {
            await Navigator.of(ctx).maybePop();
            _showContextManagementSheet();
          },
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
      await _controller.deleteMessage(message: message, byGroup: byGroup);
    }
  }

  void _showContextManagementSheet() async {
    final cs = Theme.of(context).colorScheme;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: cs.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          top: false,
          child: ContextManagementSheet(
            clearLabel: _controller.clearContextLabel(),
            onCompress: () async {
              await Navigator.of(ctx).maybePop();
              if (!mounted) return;
              await _showCompressContextOptions();
            },
            onClear: () async {
              Navigator.of(ctx).maybePop();
              await _controller.clearContext();
            },
          ),
        );
      },
    );
  }

  void _handleDesktopCompressContext() async {
    await _showCompressContextOptions();
  }

  Future<void> _showCompressContextOptions() async {
    final options = await showDialog<CompressContextOptions>(
      context: context,
      barrierDismissible: true,
      builder: (_) => const _CompressContextOptionsDialog(),
    );
    if (options == null || !mounted) return;

    final l10n = AppLocalizations.of(context)!;
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => LoadingDialogCard(label: l10n.compressingContext),
      ),
    );

    String? error;
    try {
      error = await _controller.compressContext(options: options);
    } catch (e) {
      error = e.toString();
    } finally {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).maybePop();
      }
    }
    if (error != null && mounted) {
      showAppSnackBar(
        context,
        message: _compressContextErrorMessage(l10n, error),
        type: NotificationType.error,
        duration: const Duration(seconds: 6),
      );
    }
  }
}

String _compressContextErrorMessage(AppLocalizations l10n, String error) {
  return switch (error) {
    'no_messages' => l10n.compressContextNoMessages,
    'no_conversation' => l10n.compressContextNoConversation,
    'no_model' => l10n.compressContextNoModel,
    'empty_summary' => l10n.compressContextEmptySummary,
    _ => '${l10n.compressContextFailed}: $error',
  };
}

class _CompressContextOptionsDialog extends StatefulWidget {
  const _CompressContextOptionsDialog();

  @override
  State<_CompressContextOptionsDialog> createState() =>
      _CompressContextOptionsDialogState();
}

class _CompressContextOptionsDialogState
    extends State<_CompressContextOptionsDialog> {
  CompressContextLimitMode _mode = CompressContextLimitMode.start;
  late final TextEditingController _maxCharsController;
  String? _error;

  @override
  void initState() {
    super.initState();
    _maxCharsController = TextEditingController(
      text: CompressContextOptions.defaultMaxChars.toString(),
    );
  }

  @override
  void dispose() {
    _maxCharsController.dispose();
    super.dispose();
  }

  void _submit() {
    int? maxChars;
    if (_mode != CompressContextLimitMode.unlimited) {
      maxChars = int.tryParse(_maxCharsController.text.trim());
      if (maxChars == null || maxChars <= 0) {
        setState(() {
          _error = AppLocalizations.of(context)!.compressContextInvalidLimit;
        });
        return;
      }
    }

    Navigator.of(
      context,
    ).pop(CompressContextOptions(mode: _mode, maxChars: maxChars));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final panelColor = isDark ? const Color(0xFF1C1C1E) : cs.surface;
    final constrainedWidth = MediaQuery.of(
      context,
    ).size.width.clamp(0.0, 420.0).toDouble();

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      backgroundColor: Colors.transparent,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: constrainedWidth),
        child: Material(
          color: panelColor,
          borderRadius: BorderRadius.circular(18),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(Lucide.package2, size: 20, color: cs.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        l10n.compressContextOptionsTitle,
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: AppFontWeights.emphasis,
                          color: cs.onSurface,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  l10n.compressContextOptionsDesc,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.35,
                    color: cs.onSurface.withValues(alpha: 0.62),
                  ),
                ),
                const SizedBox(height: 16),
                _CompressModeSegmented(
                  mode: _mode,
                  onChanged: (mode) {
                    setState(() {
                      _mode = mode;
                      _error = null;
                    });
                  },
                ),
                if (_mode != CompressContextLimitMode.unlimited) ...[
                  const SizedBox(height: 10),
                  IosFormTextField(
                    label: l10n.compressContextMaxCharsLabel,
                    controller: _maxCharsController,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.done,
                    selectAllOnFocus: true,
                    fieldWidth: 120,
                    onChanged: (_) {
                      if (_error != null) setState(() => _error = null);
                    },
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    _error!,
                    style: TextStyle(
                      fontSize: 12,
                      color: cs.error,
                      fontWeight: AppFontWeights.medium,
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: _DialogActionButton(
                        label: l10n.homePageCancel,
                        onTap: () => Navigator.of(context).maybePop(),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _DialogActionButton(
                        label: l10n.compressContextStartButton,
                        primary: true,
                        onTap: _submit,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CompressModeSegmented extends StatelessWidget {
  const _CompressModeSegmented({required this.mode, required this.onChanged});

  final CompressContextLimitMode mode;
  final ValueChanged<CompressContextLimitMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Row(
      children: [
        Expanded(
          child: _SegmentButton(
            label: l10n.compressContextKeepStart,
            selected: mode == CompressContextLimitMode.start,
            onTap: () => onChanged(CompressContextLimitMode.start),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _SegmentButton(
            label: l10n.compressContextKeepRecent,
            selected: mode == CompressContextLimitMode.recent,
            onTap: () => onChanged(CompressContextLimitMode.recent),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _SegmentButton(
            label: l10n.compressContextUnlimited,
            selected: mode == CompressContextLimitMode.unlimited,
            onTap: () => onChanged(CompressContextLimitMode.unlimited),
          ),
        ),
      ],
    );
  }
}

class _SegmentButton extends StatelessWidget {
  const _SegmentButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final selectedBg = isDark
        ? cs.primary.withValues(alpha: 0.22)
        : cs.primary.withValues(alpha: 0.12);
    final baseBg = isDark ? Colors.white10 : const Color(0xFFF2F3F5);

    return IosCardPress(
      baseColor: selected ? selectedBg : baseBg,
      borderRadius: BorderRadius.circular(10),
      pressedScale: 0.98,
      onTap: onTap,
      haptics: false,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      child: Center(
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 13,
            fontWeight: AppFontWeights.emphasis,
            color: selected ? cs.primary : cs.onSurface.withValues(alpha: 0.78),
          ),
        ),
      ),
    );
  }
}

class _DialogActionButton extends StatelessWidget {
  const _DialogActionButton({
    required this.label,
    required this.onTap,
    this.primary = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final base = primary
        ? cs.primary
        : (isDark ? Colors.white10 : const Color(0xFFF2F3F5));

    return IosCardPress(
      baseColor: base,
      borderRadius: BorderRadius.circular(11),
      pressedScale: 0.98,
      onTap: onTap,
      haptics: false,
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 14,
            fontWeight: AppFontWeights.emphasis,
            color: primary ? cs.onPrimary : cs.onSurface,
          ),
        ),
      ),
    );
  }
}
