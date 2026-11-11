import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';

import '../../../core/models/chat_input_data.dart';
import '../../../core/models/assistant.dart';
import '../../../core/models/answer_review.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/api/native_input_policy.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/mcp_provider.dart';
import '../../../core/providers/quick_phrase_provider.dart';
import '../../../core/providers/instruction_injection_provider.dart';
import '../../../core/providers/skills_provider.dart';
import '../../../core/providers/ai_team_provider.dart';
import '../../../core/services/api/builtin_tools.dart';
import '../../../core/services/chat/ask_user_models.dart';
import '../../../core/services/chat/todo_models.dart';
import '../../../desktop/desktop_context_menu.dart';
import '../services/context_usage_service.dart';
import '../utils/model_display_helper.dart';
import 'chat_input_bar.dart';
import 'model_icon.dart';

/// Callback for checking if a model supports tool calling.
typedef IsToolModelCallback = bool Function(String providerKey, String modelId);

/// Callback for checking if a model supports reasoning.
typedef IsReasoningModelCallback = bool Function(
  String providerKey,
  String modelId,
);

/// Callback for checking if reasoning is enabled.
typedef IsReasoningEnabledCallback = bool Function(int? budget);

/// Widget that wraps ChatInputBar with all the necessary logic and callbacks.
///
/// This widget extracts the _buildChatInputBar logic from HomePageState
/// to reduce coupling and improve maintainability.
class ChatInputSection extends StatelessWidget {
  const ChatInputSection({
    super.key,
    required this.inputBarKey,
    required this.inputFocus,
    required this.inputController,
    required this.mediaController,
    required this.isTablet,
    required this.isLoading,
    required this.isToolModel,
    required this.isReasoningModel,
    required this.isReasoningEnabled,
    this.onMore,
    this.onSelectModel,
    this.onLongPressSelectModel,
    this.onOpenAddons,
    this.onLongPressAddons,
    this.onOpenSearch,
    this.onConfigureReasoning,
    this.onSend,
    this.onStop,
    this.onQuickPhrase,
    this.onLongPressQuickPhrase,
    this.onToggleOcr,
    this.onPickCamera,
    this.onPickPhotos,
    this.onUploadFiles,
    this.onToggleInstructionInjection,
    this.onOpenSkills,
    this.onLongPressInstruction,
    this.onVoiceChat,
    this.onToggleAiTeam,
    this.onClearContext,
    this.onCompressContext,
    this.onOpenContextManagement,
    this.onRefreshContextUsage,
    this.contextUsage,
    this.isDictating = false,
    this.dictationPaused = false,
    this.onStartDictation,
    this.onStopDictation,
    this.onToggleDictationPause,
    this.onConfirmDictation,
    this.isEditing = false,
    this.onCancelEdit,
  });

  final GlobalKey inputBarKey;
  final FocusNode inputFocus;
  final TextEditingController inputController;
  final ChatInputBarController mediaController;
  final bool isTablet;
  final bool isLoading;

  // Model capability checkers
  final IsToolModelCallback isToolModel;
  final IsReasoningModelCallback isReasoningModel;
  final IsReasoningEnabledCallback isReasoningEnabled;

  // Callbacks
  final void Function(List<DesktopContextMenuItem> overflowItems)? onMore;
  final VoidCallback? onSelectModel;
  final VoidCallback? onLongPressSelectModel;
  final VoidCallback? onOpenAddons;
  final VoidCallback? onLongPressAddons;
  final VoidCallback? onOpenSearch;
  final VoidCallback? onConfigureReasoning;
  final ValueChanged<ChatInputData>? onSend;
  final VoidCallback? onStop;
  final VoidCallback? onQuickPhrase;
  final VoidCallback? onLongPressQuickPhrase;
  final VoidCallback? onToggleOcr;
  final VoidCallback? onPickCamera;
  final VoidCallback? onPickPhotos;
  final VoidCallback? onUploadFiles;
  final VoidCallback? onToggleInstructionInjection;
  final VoidCallback? onOpenSkills;
  final VoidCallback? onLongPressInstruction;
  final VoidCallback? onVoiceChat;
  final VoidCallback? onToggleAiTeam;
  final VoidCallback? onClearContext;
  final VoidCallback? onCompressContext;

  /// Opens the mobile context-management sheet when the pinned usage ring is
  /// tapped. Null keeps the anchored menu fallback.
  final VoidCallback? onOpenContextManagement;

  /// Recomputes the usage snapshot before the desktop anchored menu opens.
  final VoidCallback? onRefreshContextUsage;

  /// Context usage ring source (null = feature off / not wired).
  final ValueListenable<ContextUsageSnapshot?>? contextUsage;

  final bool isDictating;
  final bool dictationPaused;
  final VoidCallback? onStartDictation;
  final VoidCallback? onStopDictation;
  final VoidCallback? onToggleDictationPause;
  final VoidCallback? onConfirmDictation;
  final bool isEditing;
  final VoidCallback? onCancelEdit;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final ap = context.watch<AssistantProvider>();
    final a = ap.currentAssistant;
    final assistantId = a?.id;

    // Use unified helper to get model identifiers
    final modelIds = getActiveModelIds(settings, assistant: a);
    final pk = modelIds.providerKey;
    final mid = modelIds.modelId;

    // Enforce model capabilities: disable MCP selection if model doesn't support tools
    _enforceModelCapabilities(context, settings, ap, a, pk, mid);

    // Compute whether built-in search is active
    final builtinSearchActive = _isBuiltinSearchActive(settings, a, pk, mid);

    final isDesktop = _isDesktopPlatform(context);
    final aiTeamProvider = context.watch<AiTeamProvider>();
    final aiTeamEnabled = aiTeamProvider.enabled;
    // Policy resolution is not free (config lookup + catalog inference); only
    // run it when an audio attachment is actually in the composer.
    var audioInputSupported = true;
    if (mediaController.hasAudioAttachments && pk != null && mid != null) {
      try {
        audioInputSupported =
            resolveNativeInputPolicy(settings, pk, mid).nativeAudio &&
            nativeInputsEnabledForAiTeam(
              aiTeamEnabled: aiTeamEnabled,
              hasProposers: aiTeamProvider.hasProposers,
            );
      } catch (_) {
        // Unknown capability must not paint every audio chip as unsupported.
        audioInputSupported = true;
      }
    }

    return ChatInputBar(
      key: inputBarKey,
      onMore: onMore,
      searchEnabled: settings.searchEnabled || builtinSearchActive,
      onToggleSearch: (enabled) {
        context.read<SettingsProvider>().setSearchEnabled(enabled);
      },
      onSelectModel: onSelectModel,
      onLongPressSelectModel: onLongPressSelectModel,
      onOpenAddons: onOpenAddons,
      onLongPressAddons: onLongPressAddons,
      onStop: onStop,
      modelIcon: (settings.showModelIcon && pk != null && mid != null)
          ? CurrentModelIcon(
              providerKey: pk,
              modelId: mid,
              size: 38,
              withBackground: true,
              backgroundColor: Colors.transparent,
            )
          : null,
      focusNode: inputFocus,
      controller: inputController,
      mediaController: mediaController,
      onConfigureReasoning: onConfigureReasoning,
      reasoningActive: isReasoningEnabled(
        (context.watch<AssistantProvider>().currentAssistant?.thinkingBudget) ??
            settings.thinkingBudget,
      ),
      supportsReasoning: (pk != null && mid != null)
          ? isReasoningModel(pk, mid)
          : false,
      onOpenSearch: onOpenSearch,
      onSend: onSend,
      loading: isLoading,
      // Add-ons (MCP servers / built-in tools / advanced features) is always
      // shown; the highlight is on when anything inside the menu is enabled.
      addonsActive: _isAddonsActive(context, a, settings),
      showQuickPhraseButton: _hasQuickPhrases(context, a),
      onQuickPhrase: onQuickPhrase,
      onLongPressQuickPhrase: onLongPressQuickPhrase,
      // OCR button: show on desktop for mobile layout, always check settings for tablet layout
      showOcrButton: isTablet
          ? (settings.ocrModelProvider != null && settings.ocrModelId != null)
          : (isDesktop &&
                settings.ocrModelProvider != null &&
                settings.ocrModelId != null),
      ocrActive: settings.ocrEnabled,
      onToggleOcr: onToggleOcr,
      isDictating: isDictating,
      dictationPaused: dictationPaused,
      onStartDictation: onStartDictation,
      onStopDictation: onStopDictation,
      onToggleDictationPause: onToggleDictationPause,
      // Tablet-specific parameters
      onPickCamera: isTablet ? (isDesktop ? null : onPickCamera) : null,
      onPickPhotos: isTablet ? (isDesktop ? null : onPickPhotos) : null,
      onUploadFiles: isTablet ? onUploadFiles : null,
      onToggleInstructionInjection: isTablet
          ? onToggleInstructionInjection
          : null,
      // Agent Skills button: shown whenever at least one skill is known
      // (global scan + last-known project skills). Since 2026-10-06 it also
      // participates in the narrow/mobile action layout (no longer
      // tablet/desktop only) — inline when it fits, otherwise collected into
      // the overflow ("+") menu/sheet.
      onOpenSkills: context.watch<SkillsProvider>().hasAnyKnownSkills
          ? onOpenSkills
          : null,
      onLongPressInstruction: isTablet ? onLongPressInstruction : null,
      onVoiceChat: onVoiceChat,
      instructionInjectionActive: isTablet
          ? context
                .watch<InstructionInjectionProvider>()
                .activeIdsFor(assistantId)
                .isNotEmpty
          : false,
      onToggleAiTeam: onToggleAiTeam,
      aiTeamActive: aiTeamEnabled,
      audioInputSupported: audioInputSupported,
      showMoreButton: !isTablet,
      onClearContext: onClearContext,
      onCompressContext: onCompressContext,
      onOpenContextManagement: onOpenContextManagement,
      onRefreshContextUsage: onRefreshContextUsage,
      contextUsage: contextUsage,
      isEditing: isEditing,
      onCancelEdit: onCancelEdit,
    );
  }

  bool _isDesktopPlatform(BuildContext context) {
    final platform = Theme.of(context).platform;
    return platform == TargetPlatform.macOS ||
        platform == TargetPlatform.windows ||
        platform == TargetPlatform.linux;
  }

  void _enforceModelCapabilities(
    BuildContext context,
    SettingsProvider settings,
    AssistantProvider ap,
    Assistant? a,
    String? pk,
    String? mid,
  ) {
    if (pk == null || mid == null) return;

    final supportsTools = isToolModel(pk, mid);
    if (!supportsTools && (a?.mcpServerIds.isNotEmpty ?? false)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final aa = ap.currentAssistant;
        if (aa != null && aa.mcpServerIds.isNotEmpty) {
          ap.updateAssistant(aa.copyWith(mcpServerIds: const <String>[]));
        }
      });
    }

    final supportsReasoning = isReasoningModel(pk, mid);
    if (!supportsReasoning && a != null) {
      final enabledNow = isReasoningEnabled(
        a.thinkingBudget ?? settings.thinkingBudget,
      );
      if (enabledNow) {
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          final aa = ap.currentAssistant;
          if (aa != null) {
            await ap.updateAssistant(aa.copyWith(thinkingBudget: 0));
          }
        });
      }
    }
  }

  bool _isBuiltinSearchActive(
    SettingsProvider settings,
    Assistant? a,
    String? pk,
    String? mid,
  ) {
    final cfg = getActiveProviderConfig(settings, assistant: a);
    if (cfg == null || mid == null) return false;

    final isGemini = cfg.providerType == ProviderKind.google;
    final isClaude = cfg.providerType == ProviderKind.claude;
    final isOpenAIResponses =
        cfg.providerType == ProviderKind.openai && (cfg.useResponseApi == true);

    if (isGemini || isClaude || isOpenAIResponses) {
      final rawOv = cfg.modelOverrides[mid];
      final ov = rawOv is Map ? rawOv : null;
      final builtIns = BuiltInToolNames.parseAndNormalize(ov?['builtInTools']);
      return builtIns.contains(BuiltInToolNames.search);
    }
    return false;
  }

  /// Add-ons highlight: at least one capability in the menu is on — an MCP
  /// server selected for the active assistant, a built-in tool (write_todos /
  /// ask_user), or a Self-Review mode other than off.
  bool _isAddonsActive(
    BuildContext context,
    Assistant? a,
    SettingsProvider settings,
  ) {
    final builtInOn =
        (settings.planningEnabled &&
            settings.isWorkspaceToolEnabled(todoToolName)) ||
        settings.isWorkspaceToolEnabled(askUserToolName);
    final advancedOn = settings.answerReviewMode != AnswerReviewMode.off;
    return _isMcpActive(context, a) || builtInOn || advancedOn;
  }

  bool _isMcpActive(BuildContext context, Assistant? a) {
    final connected = context.watch<McpProvider>().connectedServers;
    final selected = a?.mcpServerIds ?? const <String>[];
    if (selected.isEmpty || connected.isEmpty) return false;
    return connected.any((s) => selected.contains(s.id));
  }

  bool _hasQuickPhrases(BuildContext context, Assistant? a) {
    final quickPhraseProvider = context.watch<QuickPhraseProvider>();
    final globalCount = quickPhraseProvider.globalPhrases.length;
    final assistantCount = a != null
        ? quickPhraseProvider.getForAssistant(a.id).length
        : 0;
    return (globalCount + assistantCount) > 0;
  }
}
