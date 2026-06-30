import 'dart:async';
import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import '../../../core/models/ai_team_config.dart';
import '../../../core/models/chat_input_data.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/conversation.dart';
import '../../../core/models/token_usage.dart';
import '../../../core/providers/ai_team_provider.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/api/chat_api_service.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../../utils/assistant_regex.dart';
import '../../../core/models/assistant_regex.dart';
import '../../../utils/markdown_media_sanitizer.dart';
import '../services/message_generation_service.dart';
import 'chat_controller.dart';
import 'generation_controller.dart';
import 'stream_controller.dart' as stream_ctrl;

/// Result of a send/regenerate action.
class ChatActionResult {
  final bool success;
  final String? errorMessage;
  final ChatMessage? assistantMessage;

  ChatActionResult({
    required this.success,
    this.errorMessage,
    this.assistantMessage,
  });

  factory ChatActionResult.success(ChatMessage assistantMessage) =>
      ChatActionResult(success: true, assistantMessage: assistantMessage);

  factory ChatActionResult.error(String message) =>
      ChatActionResult(success: false, errorMessage: message);

  factory ChatActionResult.noModel() =>
      ChatActionResult(success: false, errorMessage: 'no_model');
}

/// Actions class for chat operations (send, regenerate, cancel, streaming).
///
/// This class contains ONLY business logic, NO UI operations.
/// It operates on messages, calls services/streams, and returns results.
/// UI layer is responsible for handling snackbars, scrolling, animations, etc.
///
/// Key responsibilities:
/// - Send new messages
/// - Regenerate existing messages
/// - Cancel streaming
/// - Handle stream chunks (reasoning, tools, content)
/// - Manage streaming state
class ChatActions {
  ChatActions({
    required this.chatService,
    required this.chatController,
    required this.streamController,
    required this.generationController,
    required this.messageGenerationService,
    required this.contextProvider,
  });

  final ChatService chatService;
  final ChatController chatController;
  final stream_ctrl.StreamController streamController;
  final GenerationController generationController;
  final MessageGenerationService messageGenerationService;
  final BuildContext contextProvider;

  // ============================================================================
  // Callbacks for UI updates (set by HomeViewModel)
  // ============================================================================

  /// Called when messages list is updated.
  VoidCallback? onMessagesChanged;

  /// Called when conversation loading state changes.
  void Function(String conversationId, bool loading)? onLoadingChanged;

  /// Called when stream content is updated (for throttled updates).
  void Function(String messageId, String content, int totalTokens)?
      onContentUpdated;

  /// Called when an error occurs during streaming.
  void Function(String error)? onStreamError;

  /// Called when stream finishes and title may need to be generated.
  void Function(String conversationId)? onMaybeGenerateTitle;

  /// Called when summary may need to be generated (every N messages).
  void Function(String conversationId)? onMaybeGenerateSummary;

  /// Called to schedule inline image sanitization.
  void Function(String messageId, String content, {bool immediate})?
      onScheduleImageSanitize;

  /// Called when streaming finishes.
  VoidCallback? onStreamFinished;

  // ============================================================================
  // Private Helpers
  // ============================================================================

  List<ChatMessage> get _messages => chatController.messages;
  Map<String, int> get _versionSelections => chatController.versionSelections;
  Conversation? get _currentConversation => chatController.currentConversation;
  Set<String> get _loadingConversationIds =>
      chatController.loadingConversationIds;
  Map<String, StreamSubscription<dynamic>> get _conversationStreams =>
      chatController.conversationStreams;

  /// Pending AI Team proposals JSON (messageId → JSON string) awaiting persistence after aggregator finishes.
  final Map<String, String> _aiTeamPendingProposals = {};

  /// Current AI Team proposer stream subscription (local, NOT in _conversationStreams per K1)
  StreamSubscription<ChatStreamChunk>? _aiTeamProposerSub;

  /// Whether AI Team is currently in proposal phase (for cancel handling)
  bool _aiTeamInProposalPhase = false;

  /// Cancellation flag for AI Team proposal loop
  bool _aiTeamCancelled = false;

  /// Cancellation signal completer for AI Team proposer (R1: prevents deadlock on cancel)
  Completer<void>? _aiTeamCancelCompleter;

  void _setConversationLoading(String conversationId, bool loading) {
    chatController.setConversationLoading(conversationId, loading);
    onLoadingChanged?.call(conversationId, loading);
  }

  bool _isReasoningModel(String providerKey, String modelId) {
    return generationController.isReasoningModel(providerKey, modelId);
  }

  bool _isReasoningEnabled(int? budget) {
    return messageGenerationService.isReasoningEnabled(budget);
  }

  /// Transform raw content using assistant regexes.
  String _transformAssistantContent(stream_ctrl.StreamingState state,
      [String? raw]) {
    return applyAssistantRegexes(
      raw ?? state.fullContentRaw,
      assistant: state.ctx.assistant,
      scope: AssistantRegexScope.assistant,
      visual: false,
    );
  }

  // ============================================================================
  // Send Message
  // ============================================================================

  /// Send a new message and start generating assistant response.
  ///
  /// Returns [ChatActionResult] with success status and the assistant message.
  /// UI is responsible for:
  /// - Adding messages to the list (user + assistant)
  /// - Showing snackbars on errors
  /// - Scrolling to bottom
  /// - Haptic feedback
  Future<ChatActionResult> sendMessage({
    required ChatInputData input,
    required Conversation conversation,
  }) async {
    final content = input.text.trim();
    if (content.isEmpty &&
        input.imagePaths.isEmpty &&
        input.documents.isEmpty) {
      return ChatActionResult.error('empty_input');
    }

    final settings = contextProvider.read<SettingsProvider>();
    final assistant = contextProvider.read<AssistantProvider>().currentAssistant;
    final assistantId = assistant?.id;
    final modelConfig =
        messageGenerationService.getModelConfig(settings, assistant);

    if (modelConfig.providerKey == null || modelConfig.modelId == null) {
      return ChatActionResult.noModel();
    }
    final providerKey = modelConfig.providerKey!;
    final modelId = modelConfig.modelId!;

    // AI Team: if enabled and aggregator specified, override model (K2 fix)
    final aiTeam = contextProvider.read<AiTeamProvider>();
    final aiTeamConfig = aiTeam.config;
    String effProviderKey = providerKey;
    String effModelId = modelId;
    if (aiTeam.enabled && aiTeamConfig.aggregator != null) {
      effProviderKey = aiTeamConfig.aggregator!.providerKey;
      effModelId = aiTeamConfig.aggregator!.modelId;
    }

    // Create user message
    final userMessage = await messageGenerationService.createUserMessage(
      conversationId: conversation.id,
      input: input,
      assistant: assistant,
    );
    _messages.add(userMessage);
    onMessagesChanged?.call();

    _setConversationLoading(conversation.id, true);

    // Create assistant message placeholder (K2: use effective model)
    final assistantMessage =
        await messageGenerationService.createAssistantPlaceholder(
      conversationId: conversation.id,
      modelId: effModelId,
      providerKey: effProviderKey,
    );

    // Pre-create streaming notifier BEFORE adding message to list
    // so that MessageListView can detect it's streaming on first render
    streamController.markStreamingStarted(assistantMessage.id);

    _messages.add(assistantMessage);
    onMessagesChanged?.call();

    // Reset tool parts and initialize reasoning
    streamController.toolParts.remove(assistantMessage.id);
    final supportsReasoning = _isReasoningModel(effProviderKey, effModelId);
    final enableReasoning = supportsReasoning &&
        _isReasoningEnabled(assistant?.thinkingBudget ?? settings.thinkingBudget);
    await messageGenerationService.initializeReasoningState(
        messageId: assistantMessage.id, enableReasoning: enableReasoning);

    // Prepare API messages
    final prepared =
        await messageGenerationService.prepareApiMessagesWithInjections(
      messages: _messages,
      versionSelections: _versionSelections,
      currentConversation: conversation,
      settings: settings,
      assistant: assistant,
      assistantId: assistantId,
      providerKey: effProviderKey,
      modelId: effModelId,
    );

    // Build user image paths
    final userImagePaths = messageGenerationService.buildUserImagePaths(
      input: input,
      lastUserImagePaths: prepared.lastUserImagePaths,
      settings: settings,
    );

    // Execute generation
    final ctx = messageGenerationService.buildGenerationContext(
      assistantMessage: assistantMessage,
      prepared: prepared,
      userImagePaths: userImagePaths,
      providerKey: effProviderKey,
      modelId: effModelId,
      assistant: assistant,
      settings: settings,
      supportsReasoning: supportsReasoning,
      enableReasoning: enableReasoning,
      generateTitleOnFinish: true,
    );

    if (aiTeam.enabled && aiTeam.hasProposers) {
      unawaited(_executeAiTeamGeneration(ctx, aiTeamConfig));
    } else {
      await _executeGeneration(ctx);
    }
    return ChatActionResult.success(assistantMessage);
  }

  // ============================================================================
  // Regenerate Message
  // ============================================================================

  /// Regenerate response at a specific message.
  ///
  /// Returns [ChatActionResult] with success status and the new assistant message.
  /// UI is responsible for:
  /// - Removing trailing messages from the list
  /// - Adding new assistant placeholder
  /// - Showing snackbars on errors
  /// - Haptic feedback
  Future<ChatActionResult> regenerateAtMessage({
    required ChatMessage message,
    required Conversation conversation,
    bool assistantAsNewReply = false,
  }) async {
    await cancelStreaming(conversation);

    final idx = _messages.indexWhere((m) => m.id == message.id);
    if (idx < 0) {
      return ChatActionResult.error('message_not_found');
    }

    // Calculate versioning using service
    final versioning = messageGenerationService.calculateRegenerationVersioning(
      message: message,
      messages: _messages,
      assistantAsNewReply: assistantAsNewReply,
    );
    if (versioning.lastKeep < 0) {
      return ChatActionResult.error('invalid_versioning');
    }

    // Remove trailing messages - returns list of removed IDs for UI cleanup
    final removeIds = await messageGenerationService.removeTrailingMessages(
      messages: _messages,
      lastKeep: versioning.lastKeep,
      targetGroupId: versioning.targetGroupId,
    );
    if (removeIds.isNotEmpty) {
      _messages.removeWhere((m) => removeIds.contains(m.id));
      onMessagesChanged?.call();
    }

    // Get model config
    final settings = contextProvider.read<SettingsProvider>();
    final assistant = contextProvider.read<AssistantProvider>().currentAssistant;
    final assistantId = assistant?.id;
    final modelConfig =
        messageGenerationService.getModelConfig(settings, assistant);

    if (modelConfig.providerKey == null || modelConfig.modelId == null) {
      return ChatActionResult.noModel();
    }
    final providerKey = modelConfig.providerKey!;
    final modelId = modelConfig.modelId!;

    // AI Team: if enabled and aggregator specified, override model (K2 fix, R6)
    final aiTeam = contextProvider.read<AiTeamProvider>();
    final aiTeamConfig = aiTeam.config;
    String effProviderKey = providerKey;
    String effModelId = modelId;
    if (aiTeam.enabled && aiTeamConfig.aggregator != null) {
      effProviderKey = aiTeamConfig.aggregator!.providerKey;
      effModelId = aiTeamConfig.aggregator!.modelId;
    }

    // Create assistant message placeholder (new version)
    final assistantMessage =
        await messageGenerationService.createAssistantPlaceholder(
      conversationId: conversation.id,
      modelId: effModelId,
      providerKey: effProviderKey,
      groupId: versioning.targetGroupId,
      version: versioning.nextVersion,
    );

    // Pre-create streaming notifier BEFORE adding message to list
    // so that MessageListView can detect it's streaming on first render
    streamController.markStreamingStarted(assistantMessage.id);

    // Persist version selection
    final gid = assistantMessage.groupId ?? assistantMessage.id;
    _versionSelections[gid] = assistantMessage.version;
    await chatService.setSelectedVersion(
        conversation.id, gid, assistantMessage.version);

    _messages.add(assistantMessage);
    onMessagesChanged?.call();

    _setConversationLoading(conversation.id, true);

    // Initialize reasoning
    final supportsReasoning = _isReasoningModel(effProviderKey, effModelId);
    final enableReasoning = supportsReasoning &&
        _isReasoningEnabled(assistant?.thinkingBudget ?? settings.thinkingBudget);
    await messageGenerationService.initializeReasoningState(
        messageId: assistantMessage.id, enableReasoning: enableReasoning);

    // Prepare API messages
    final prepared =
        await messageGenerationService.prepareApiMessagesWithInjections(
      messages: _messages,
      versionSelections: _versionSelections,
      currentConversation: conversation,
      settings: settings,
      assistant: assistant,
      assistantId: assistantId,
      providerKey: effProviderKey,
      modelId: effModelId,
    );

    // Build user image paths
    final userImagePaths = messageGenerationService.buildUserImagePaths(
      input: null,
      lastUserImagePaths: prepared.lastUserImagePaths,
      settings: settings,
    );

    // Execute generation
    final ctx = messageGenerationService.buildGenerationContext(
      assistantMessage: assistantMessage,
      prepared: prepared,
      userImagePaths: userImagePaths,
      providerKey: effProviderKey,
      modelId: effModelId,
      assistant: assistant,
      settings: settings,
      supportsReasoning: supportsReasoning,
      enableReasoning: enableReasoning,
      generateTitleOnFinish: false,
    );

    if (aiTeam.enabled && aiTeam.hasProposers) {
      unawaited(_executeAiTeamGeneration(ctx, aiTeamConfig));
    } else {
      await _executeGeneration(ctx);
    }
    return ChatActionResult.success(assistantMessage);
  }

  // ============================================================================
  // Cancel Streaming
  // ============================================================================

  /// Cancel the active streaming for the current conversation.
  Future<void> cancelStreaming(Conversation? conversation) async {
    final cid = conversation?.id;
    if (cid == null) return;

    // AI Team: cancel proposer phase if active (I3 + R1: complete cancel completer before cancel)
    if (_aiTeamInProposalPhase) {
      _aiTeamCancelled = true;
      if (_aiTeamCancelCompleter != null && !_aiTeamCancelCompleter!.isCompleted) {
        _aiTeamCancelCompleter!.complete();
      }
      await _aiTeamProposerSub?.cancel();
      _aiTeamProposerSub = null;
      // Also cancel the underlying HTTP request for the proposer stream
      ChatApiService.cancelRequest('${cid}_proposer');
    }

    // Cancel active stream for current conversation only
    final sub = _conversationStreams.remove(cid);
    await sub?.cancel();
    ChatApiService.cancelRequest(cid);

    // Find the latest assistant streaming message within current conversation and mark it finished
    ChatMessage? streaming;
    for (var i = _messages.length - 1; i >= 0; i--) {
      final m = _messages[i];
      if (m.role == 'assistant' && m.isStreaming) {
        streaming = m;
        break;
      }
    }
    if (streaming != null) {
      // Mark streaming as ended to allow UI rebuilds again
      streamController.markStreamingEnded(streaming.id);

      // R3: persist pending AI Team proposals during aggregator phase
      final pendingProposals = _aiTeamPendingProposals.remove(streaming.id);

      await chatService.updateMessage(
        streaming.id,
        content: streaming.content,
        isStreaming: false,
        totalTokens: streaming.totalTokens,
        aiTeamProposalsJson: pendingProposals,
      );

      final idx = _messages.indexWhere((m) => m.id == streaming!.id);
      if (idx != -1) {
        _messages[idx] = _messages[idx].copyWith(
          isStreaming: false,
          aiTeamProposalsJson: pendingProposals,
        );
        onMessagesChanged?.call();
      }
      _setConversationLoading(cid, false);

      // Use unified reasoning completion method
      await streamController.finishReasoningAndPersist(
        streaming.id,
        updateReasoningInDb: (
          String messageId, {
          String? reasoningText,
          DateTime? reasoningFinishedAt,
          String? reasoningSegmentsJson,
        }) async {
          await chatService.updateMessage(
            messageId,
            reasoningText: reasoningText,
            reasoningFinishedAt: reasoningFinishedAt,
            reasoningSegmentsJson: reasoningSegmentsJson,
          );
        },
      );

      // If streaming output included inline base64 images, sanitize them even on manual cancel
      onScheduleImageSanitize?.call(streaming.id, streaming.content,
          immediate: true);
    } else {
      _setConversationLoading(cid, false);
    }
  }

  // ============================================================================
  // Stream Execution
  // ============================================================================

  /// Execute generation with the given context.
  Future<void> _executeGeneration(stream_ctrl.GenerationContext ctx) async {
    final state = stream_ctrl.StreamingState(ctx);
    final assistant = ctx.assistant;
    final conversationId = state.conversationId;

    // Mark this message as actively streaming to suppress UI rebuilds
    streamController.markStreamingStarted(state.messageId);

    try {
      final stream = ChatApiService.sendMessageStream(
        config: ctx.config,
        modelId: ctx.modelId,
        messages: ctx.apiMessages,
        userImagePaths: ctx.userImagePaths,
        thinkingBudget: assistant?.thinkingBudget ?? ctx.settings.thinkingBudget,
        temperature: assistant?.temperature,
        topP: assistant?.topP,
        maxTokens: assistant?.maxTokens,
        tools: ctx.toolDefs.isEmpty ? null : ctx.toolDefs,
        onToolCall: ctx.onToolCall,
        extraHeaders: ctx.extraHeaders,
        extraBody: ctx.extraBody,
        stream: ctx.streamOutput,
        requestId: conversationId,
      );

      await _conversationStreams[conversationId]?.cancel();
      late final StreamSubscription<ChatStreamChunk> sub;
      sub = stream.listen(
        null,
        onError: (e) {
          unawaited(_guardStreamTask(
            () => _handleStreamError(e, state),
            state,
            routeToStreamError: false,
          ));
        },
        onDone: () {
          unawaited(_guardStreamTask(
            () => _handleStreamDone(state),
            state,
          ));
        },
        cancelOnError: true,
      );
      sub.onData((chunk) {
        sub.pause();
        unawaited(_handleStreamData(chunk, state, sub));
      });
      _conversationStreams[conversationId] = sub;
    } catch (e) {
      await _handleStreamError(e, state);
    }
  }

  // ============================================================================
  // AI Team (Mixture of Agents) Execution
  // ============================================================================

  /// Execute AI Team generation: run proposers sequentially, then aggregate.
  Future<void> _executeAiTeamGeneration(
    stream_ctrl.GenerationContext ctx,
    AiTeamConfig aiTeamConfig,
  ) async {
    final conversationId = ctx.assistantMessage.conversationId;
    final messageId = ctx.assistantMessage.id;
    final baseApiMessages = ctx.apiMessages;
    final l10n = AppLocalizations.of(contextProvider)!;

    // Resolve effective prompts: l10n default or user-customized
    final effectiveProposalPrompt = aiTeamConfig.useDefaultProposalPrompt
        ? l10n.aiTeamDefaultProposalPrompt
        : aiTeamConfig.proposalSystemPrompt;
    final effectiveAggregatorPrompt = aiTeamConfig.useDefaultAggregatorPrompt
        ? l10n.aiTeamDefaultAggregatorPrompt
        : aiTeamConfig.aggregatorSystemPrompt;

    _aiTeamCancelled = false;
    _aiTeamInProposalPhase = true;

    // Run proposers sequentially (D2)
    final List<Map<String, dynamic>> proposals = [];
    final activeProposers = aiTeamConfig.activeProposers;
    final totalProposers = activeProposers.length;

    for (var idx = 0; idx < totalProposers; idx++) {
      final slot = activeProposers[idx];
      if (_aiTeamCancelled) break;

      // Push progress text to streaming UI
      final progressText = l10n.aiTeamProposalInProgress(idx + 1, totalProposers);
      streamController.streamingContentNotifier.updateContent(
        messageId, progressText, 0,
      );

      final propMessages =
          _cloneForProposer(baseApiMessages, effectiveProposalPrompt);
      final propConfig = ctx.settings.getProviderConfig(slot.providerKey);

      // Check if proposer model supports reasoning
      final propSupportsReasoning =
          _isReasoningModel(slot.providerKey, slot.modelId);
      final propBudget = propSupportsReasoning
          ? (ctx.assistant?.thinkingBudget ?? ctx.settings.thinkingBudget)
          : 0;

      Map<String, dynamic> proposerResult;
      try {
        proposerResult = await _runProposerSilent(
          conversationId: conversationId,
          config: propConfig,
          modelId: slot.modelId,
          apiMessages: propMessages,
          userImagePaths: ctx.userImagePaths,
          thinkingBudget: propBudget,
          temperature: ctx.assistant?.temperature,
          topP: ctx.assistant?.topP,
          maxTokens: ctx.assistant?.maxTokens,
          tools: ctx.toolDefs.isEmpty ? null : ctx.toolDefs,
          onToolCall: ctx.onToolCall,
          extraHeaders: ctx.extraHeaders,
          extraBody: ctx.extraBody,
          streamOutput: ctx.streamOutput,
        );
      } catch (e) {
        // I1: Per-proposer error — skip, continue
        proposerResult = {
          'content': '',
          'reasoning': '',
          'toolCalls': <Map<String, dynamic>>[],
        };
      }

      proposals.add({
        'providerKey': slot.providerKey,
        'modelId': slot.modelId,
        'content': proposerResult['content'] as String? ?? '',
        'reasoning': proposerResult['reasoning'] as String? ?? '',
        'toolCalls': proposerResult['toolCalls'] as List<dynamic>? ?? const [],
      });

      // Push partial proposals to streaming UI for real-time display
      final partialJson = jsonEncode(proposals);
      streamController.streamingContentNotifier.updateProposals(messageId, partialJson);
      await chatService.updateMessageSilent(messageId, aiTeamProposalsJson: partialJson);
      final mIdx = _messages.indexWhere((m) => m.id == messageId);
      if (mIdx != -1) {
        _messages[mIdx] = _messages[mIdx].copyWith(aiTeamProposalsJson: partialJson);
      }
    }

    _aiTeamInProposalPhase = false;

    // Clear progress text before aggregator starts
    streamController.streamingContentNotifier.updateContent(
      messageId, '', 0,
    );

    // If cancelled or all proposals empty, show stopped
    if (_aiTeamCancelled ||
        proposals.every((p) => (p['content'] as String).isEmpty)) {
      await _handleAiTeamStopped(ctx.assistantMessage, proposals);
      return;
    }

    // Build aggregator apiMessages with proposals injected (I2)
    final aggMessages = _buildAggregatorMessages(
        baseApiMessages, proposals, effectiveAggregatorPrompt, l10n.aiTeamAggregatorUserPrompt);

    // Store pending proposals for persistence after aggregator finishes
    _aiTeamPendingProposals[messageId] = jsonEncode(proposals);

    // Build aggregator context (no tools for aggregator, clean slate)
    final aggCtx = stream_ctrl.GenerationContext(
      assistantMessage: ctx.assistantMessage,
      apiMessages: aggMessages,
      userImagePaths: ctx.userImagePaths,
      providerKey: ctx.providerKey,
      modelId: ctx.modelId,
      assistant: ctx.assistant,
      settings: ctx.settings,
      config: ctx.config,
      toolDefs: const [],
      onToolCall: null,
      extraHeaders: ctx.extraHeaders,
      extraBody: ctx.extraBody,
      supportsReasoning: ctx.supportsReasoning,
      enableReasoning: ctx.enableReasoning,
      streamOutput: ctx.streamOutput,
      generateTitleOnFinish: ctx.generateTitleOnFinish,
    );

    // Execute aggregator generation (standard flow, subscription registered in _conversationStreams per K1)
    await _executeGeneration(aggCtx);
  }

  /// Run a single proposer silently (no UI push), return map with content/reasoning/toolCalls.
  /// R1: Uses Future.any to race stream completion vs cancel signal to prevent deadlock.
  Future<Map<String, dynamic>> _runProposerSilent({
    required String conversationId,
    required dynamic config,
    required String modelId,
    required List<Map<String, dynamic>> apiMessages,
    required List<String> userImagePaths,
    required int thinkingBudget,
    double? temperature,
    double? topP,
    int? maxTokens,
    List<Map<String, dynamic>>? tools,
    Future<String> Function(String, Map<String, dynamic>)? onToolCall,
    Map<String, String>? extraHeaders,
    Map<String, dynamic>? extraBody,
    required bool streamOutput,
  }) async {
    final completer = Completer<Map<String, dynamic>>();
    final buffer = StringBuffer();
    final reasoningBuffer = StringBuffer();
    final toolCallsList = <Map<String, dynamic>>[];
    final toolResultsMap = <String, String>{};
    _aiTeamCancelCompleter = Completer<void>();

    final stream = ChatApiService.sendMessageStream(
      config: config,
      modelId: modelId,
      messages: apiMessages,
      userImagePaths: userImagePaths,
      thinkingBudget: thinkingBudget,
      temperature: temperature,
      topP: topP,
      maxTokens: maxTokens,
      tools: tools,
      onToolCall: onToolCall,
      extraHeaders: extraHeaders,
      extraBody: extraBody,
      stream: streamOutput,
      requestId: '${conversationId}_proposer',
    );

    final proposerSub = stream.listen(
      (chunk) {
        if (chunk.content.isNotEmpty) {
          buffer.write(chunk.content);
        }
        if ((chunk.reasoning ?? '').isNotEmpty) {
          reasoningBuffer.write(chunk.reasoning);
        }
        if ((chunk.toolCalls ?? const []).isNotEmpty) {
          for (final tc in chunk.toolCalls!) {
            toolCallsList.add({
              'id': tc.id,
              'name': tc.name,
              'arguments': tc.arguments,
            });
          }
        }
        if ((chunk.toolResults ?? const []).isNotEmpty) {
          for (final tr in chunk.toolResults!) {
            final result = tr.content;
            // Truncate very long tool results to avoid storage bloat
            toolResultsMap[tr.id] = result.length > 2000
                ? '${result.substring(0, 2000)}…'
                : result;
          }
        }
      },
      onError: (e) {
        if (!completer.isCompleted) {
          completer.completeError(e);
        }
      },
      onDone: () {
        if (!completer.isCompleted) {
          // Merge tool results into tool calls
          for (final tc in toolCallsList) {
            final id = tc['id'] as String?;
            if (id != null && toolResultsMap.containsKey(id)) {
              tc['result'] = toolResultsMap[id];
            }
          }
          completer.complete({
            'content': buffer.toString(),
            'reasoning': reasoningBuffer.toString(),
            'toolCalls': toolCallsList,
          });
        }
      },
      cancelOnError: true,
    );
    _aiTeamProposerSub = proposerSub;

    // R1: Race stream completion vs cancel signal to prevent deadlock
    try {
      final result = await Future.any([
        completer.future,
        _aiTeamCancelCompleter!.future.then((_) => {
              'content': '',
              'reasoning': '',
              'toolCalls': <Map<String, dynamic>>[],
            }),
      ]);
      return result;
    } finally {
      await proposerSub.cancel();
      _aiTeamProposerSub = null;
    }
  }

  /// Clone apiMessages and append proposal system prompt to existing system message (K3).
  List<Map<String, dynamic>> _cloneForProposer(
    List<Map<String, dynamic>> apiMessages,
    String proposalSystemPrompt,
  ) {
    final cloned = apiMessages
        .map((m) => Map<String, dynamic>.from(m))
        .toList(growable: true);

    if (cloned.isNotEmpty && cloned[0]['role'] == 'system') {
      final existingSystem = cloned[0]['content'] as String? ?? '';
      cloned[0] = Map<String, dynamic>.from(cloned[0]);
      cloned[0]['content'] = '$existingSystem\n\n=====\n$proposalSystemPrompt';
    } else {
      cloned.insert(0, {'role': 'system', 'content': proposalSystemPrompt});
    }

    return cloned;
  }

  /// Build aggregator apiMessages: append aggregator prompt + inject proposals (I2).
  /// R4: If a user message exists, insert proposals after it; otherwise append to end.
  /// Fix: Append a trailing user message after proposals so the last role is 'user'.
  /// This is required by Mistral API which rejects assistant as the last message.
  List<Map<String, dynamic>> _buildAggregatorMessages(
    List<Map<String, dynamic>> baseApiMessages,
    List<Map<String, dynamic>> proposals,
    String aggregatorSystemPrompt,
    String aggregatorUserPrompt,
  ) {
    final cloned = baseApiMessages
        .map((m) => Map<String, dynamic>.from(m))
        .toList(growable: true);

    // K3: Append aggregatorSystemPrompt to existing system message
    if (cloned.isNotEmpty && cloned[0]['role'] == 'system') {
      final existingSystem = cloned[0]['content'] as String? ?? '';
      cloned[0] = Map<String, dynamic>.from(cloned[0]);
      cloned[0]['content'] =
          '$existingSystem\n\n=====\n$aggregatorSystemPrompt';
    } else {
      cloned.insert(
          0, {'role': 'system', 'content': aggregatorSystemPrompt});
    }

    // I2: Insert proposals as assistant messages after the last user message
    int lastUserIdx = -1;
    for (var i = cloned.length - 1; i >= 0; i--) {
      if (cloned[i]['role'] == 'user') {
        lastUserIdx = i;
        break;
      }
    }

    final proposalMessages = <Map<String, dynamic>>[];
    for (var i = 0; i < proposals.length; i++) {
      final p = proposals[i];
      final content = p['content'] as String? ?? '';
      if (content.isEmpty) continue;
      final providerKey = p['providerKey'] as String? ?? '';
      final modelId = p['modelId'] as String? ?? '';
      proposalMessages.add({
        'role': 'assistant',
        'content': '=== Proposal ${i + 1} ($providerKey/$modelId) ===\n$content',
      });
    }

    if (proposalMessages.isNotEmpty) {
      if (lastUserIdx >= 0) {
        cloned.insertAll(lastUserIdx + 1, proposalMessages);
      } else {
        cloned.addAll(proposalMessages);
      }
      // Append a trailing user message so the last role is 'user'.
      // Required by Mistral API which rejects assistant as the last message.
      cloned.add({'role': 'user', 'content': aggregatorUserPrompt});
    }

    return cloned;
  }

  /// Handle AI Team stopped (cancelled or all proposals failed).
  /// R5: Persists partial proposals if any non-empty content exists.
  Future<void> _handleAiTeamStopped(
    ChatMessage assistantMessage,
    List<Map<String, dynamic>> proposals,
  ) async {
    const l10nReason = 'AI Team stopped';

    // R5: Persist partial proposals if any non-empty
    String? proposalsJson;
    final hasNonEmpty =
        proposals.any((p) => (p['content'] as String).isNotEmpty);
    if (hasNonEmpty) {
      proposalsJson = jsonEncode(proposals);
    }
    _aiTeamPendingProposals.remove(assistantMessage.id);

    streamController.markStreamingEnded(assistantMessage.id);
    await chatService.updateMessage(
      assistantMessage.id,
      content: l10nReason,
      isStreaming: false,
      aiTeamProposalsJson: proposalsJson,
    );

    final idx = _messages.indexWhere((m) => m.id == assistantMessage.id);
    if (idx != -1) {
      _messages[idx] = _messages[idx].copyWith(
        content: l10nReason,
        isStreaming: false,
        aiTeamProposalsJson: proposalsJson,
      );
      onMessagesChanged?.call();
    }
    _setConversationLoading(assistantMessage.conversationId, false);
    onStreamFinished?.call();
  }

  Future<void> _handleStreamData(
    ChatStreamChunk chunk,
    stream_ctrl.StreamingState state,
    StreamSubscription<ChatStreamChunk> sub,
  ) async {
    try {
      await _handleStreamChunk(chunk, state);
    } catch (e) {
      await _guardStreamTask(
        () => _handleStreamError(e, state),
        state,
        routeToStreamError: false,
      );
    } finally {
      try {
        sub.resume();
      } catch (_) {}
    }
  }

  Future<void> _guardStreamTask(
    Future<void> Function() task,
    stream_ctrl.StreamingState state, {
    bool routeToStreamError = true,
  }) async {
    try {
      await task();
    } catch (e) {
      if (!routeToStreamError) return;
      try {
        await _handleStreamError(e, state);
      } catch (_) {}
    }
  }

  // ============================================================================
  // Stream Chunk Handlers
  // ============================================================================

  /// Dispatch stream chunk to appropriate handler.
  Future<void> _handleStreamChunk(
      ChatStreamChunk chunk, stream_ctrl.StreamingState state) async {
    final chunkContent = chunk.content.isNotEmpty
        ? streamController.captureGeminiThoughtSignature(
            chunk.content, state.messageId)
        : '';

    // Handle reasoning
    if ((chunk.reasoning ?? '').isNotEmpty && state.ctx.supportsReasoning) {
      await _handleReasoningChunk(chunk, state);
    }

    // Handle tool calls
    if ((chunk.toolCalls ?? const []).isNotEmpty) {
      await _handleToolCallsChunk(chunk, state);
    }

    // Handle tool results
    if ((chunk.toolResults ?? const []).isNotEmpty) {
      await _handleToolResultsChunk(chunk, state);
    }

    // Handle finish or content
    if (chunk.isDone) {
      await _handleStreamFinish(chunk, state, chunkContent);
    } else {
      await _handleContentChunk(chunk, state, chunkContent);
    }
  }

  /// Handle reasoning chunk from stream.
  Future<void> _handleReasoningChunk(
      ChatStreamChunk chunk, stream_ctrl.StreamingState state) async {
    await streamController.handleReasoningChunk(
      chunk,
      state,
      updateReasoningInDb: (
        String messageId, {
        String? reasoningText,
        DateTime? reasoningStartAt,
        String? reasoningSegmentsJson,
      }) async {
        // Use silent update during streaming to avoid UI rebuilds
        await chatService.updateMessageSilent(
          messageId,
          reasoningText: reasoningText,
          reasoningStartAt: reasoningStartAt,
          reasoningSegmentsJson: reasoningSegmentsJson,
        );
      },
    );
  }

  /// Handle tool calls chunk from stream.
  Future<void> _handleToolCallsChunk(
      ChatStreamChunk chunk, stream_ctrl.StreamingState state) async {
    await streamController.handleToolCallsChunk(
      chunk,
      state,
      updateReasoningSegmentsInDb: (String messageId, String json) async {
        // Use silent update during streaming to avoid UI rebuilds
        await chatService.updateMessageSilent(messageId, reasoningSegmentsJson: json);
      },
      setToolEventsInDb:
          (String messageId, List<Map<String, dynamic>> events) async {
        await chatService.setToolEvents(messageId, events);
      },
      getToolEventsFromDb: (String messageId) =>
          chatService.getToolEvents(messageId),
    );
  }

  /// Handle tool results chunk from stream.
  Future<void> _handleToolResultsChunk(
      ChatStreamChunk chunk, stream_ctrl.StreamingState state) async {
    await streamController.handleToolResultsChunk(
      chunk,
      state,
      upsertToolEventInDb: (
        String messageId, {
        required String id,
        required String name,
        required Map<String, dynamic> arguments,
        String? content,
      }) async {
        await chatService.upsertToolEvent(
          messageId,
          id: id,
          name: name,
          arguments: arguments,
          content: content,
        );
      },
    );
  }

  /// Handle content chunk from stream (non-done).
  Future<void> _handleContentChunk(ChatStreamChunk chunk,
      stream_ctrl.StreamingState state, String chunkContent) async {
    final messageId = state.messageId;
    final conversationId = state.conversationId;

    state.fullContentRaw += chunkContent;
    if (chunk.totalTokens > 0) {
      state.totalTokens = chunk.totalTokens;
    }
    if (chunk.usage != null) {
      state.usage = (state.usage ?? const TokenUsage()).merge(chunk.usage!);
      state.totalTokens = state.usage!.totalTokens;
    }

    String streamingProcessed = _transformAssistantContent(state);
    if (streamingProcessed.contains('data:image') &&
        streamingProcessed.contains('base64,')) {
      try {
        final sanitized = await MarkdownMediaSanitizer.replaceInlineBase64Images(
            streamingProcessed);
        if (sanitized != streamingProcessed) {
          streamingProcessed = sanitized;
          state.fullContentRaw = sanitized;
        }
      } catch (e) {
        // ignore
      }
    }
    onScheduleImageSanitize?.call(messageId, streamingProcessed,
        immediate: true);
    // Use silent update to avoid triggering ChatService.notifyListeners()
    // which would cause side_drawer and other widgets to rebuild
    await chatService.updateMessageSilent(
      messageId,
      content: streamingProcessed,
      totalTokens: state.totalTokens,
    );

    if (state.ctx.streamOutput &&
        _currentConversation?.id == conversationId) {
      final index = _messages.indexWhere((m) => m.id == messageId);
      if (index != -1) {
        _messages[index] = _messages[index].copyWith(
          content: streamingProcessed,
          totalTokens: state.totalTokens,
        );
        // NOTE: Do NOT call onMessagesChanged here!
        // Streaming content updates are handled by StreamingContentNotifier
        // via ValueListenableBuilder, which only rebuilds the streaming message widget.
        // Calling onMessagesChanged would trigger a full page rebuild and cause lag.
      }
    }

    // End reasoning when content starts
    if (state.ctx.streamOutput && chunkContent.isNotEmpty) {
      await _finishReasoningOnContent(state);
    }

    // Schedule throttled UI update via StreamController
    if (state.ctx.streamOutput) {
      streamController.scheduleThrottledUpdate(
        messageId,
        conversationId,
        streamingProcessed,
        totalTokens: state.totalTokens,
        updateMessageInList: (id, content, tokens) {
          onContentUpdated?.call(id, content, tokens);
        },
      );
    }
  }

  /// Finish reasoning segment when content starts arriving.
  Future<void> _finishReasoningOnContent(
      stream_ctrl.StreamingState state) async {
    await streamController.finishReasoningAndPersist(
      state.messageId,
      updateReasoningInDb: (
        String messageId, {
        String? reasoningText,
        DateTime? reasoningFinishedAt,
        String? reasoningSegmentsJson,
      }) async {
        // Use silent update during streaming to avoid UI rebuilds
        await chatService.updateMessageSilent(
          messageId,
          reasoningText: reasoningText,
          reasoningFinishedAt: reasoningFinishedAt,
          reasoningSegmentsJson: reasoningSegmentsJson,
        );
      },
    );
  }

  /// Handle stream finish (isDone == true).
  Future<void> _handleStreamFinish(ChatStreamChunk chunk,
      stream_ctrl.StreamingState state, String chunkContent) async {
    final messageId = state.messageId;
    final conversationId = state.conversationId;

    if (chunkContent.isNotEmpty) {
      state.fullContentRaw += chunkContent;
    }

    // Don't finish if tools are still loading
    final hasLoadingTool =
        (streamController.toolParts[messageId]?.any((p) => p.loading) ?? false);
    if (hasLoadingTool) {
      return;
    }

    if (chunk.totalTokens > 0) {
      state.totalTokens = chunk.totalTokens;
    }
    if (chunk.usage != null) {
      state.usage = (state.usage ?? const TokenUsage()).merge(chunk.usage!);
      state.totalTokens = state.usage!.totalTokens;
    }

    await _finishStreaming(state);

    // Notify for background notification if needed
    onStreamFinished?.call();

    // Handle buffered reasoning for non-streaming mode
    if (!state.ctx.streamOutput && state.bufferedReasoning.isNotEmpty) {
      final now = DateTime.now();
      final startAt = state.reasoningStartAt ?? now;
      await chatService.updateMessage(
        messageId,
        reasoningText: state.bufferedReasoning,
        reasoningStartAt: startAt,
        reasoningFinishedAt: now,
      );
      final autoCollapse =
          contextProvider.read<SettingsProvider>().autoCollapseThinking;
      streamController.reasoning[messageId] = stream_ctrl.ReasoningData()
        ..text = state.bufferedReasoning
        ..startAt = startAt
        ..finishedAt = now
        ..expanded = !autoCollapse;
    }

    await _conversationStreams.remove(conversationId)?.cancel();

    // Ensure reasoning is finished
    final r = streamController.reasoning[messageId];
    if (r != null && r.finishedAt == null) {
      r.finishedAt = DateTime.now();
      await chatService.updateMessage(
        messageId,
        reasoningText: r.text,
        reasoningFinishedAt: r.finishedAt,
      );
    }
  }

  /// Finish streaming and persist final state.
  Future<void> _finishStreaming(stream_ctrl.StreamingState state,
      {bool generateTitle = true}) async {
    final messageId = state.messageId;
    final conversationId = state.conversationId;

    // Mark streaming as ended to allow UI rebuilds again
    streamController.markStreamingEnded(messageId);

    // Clean up stream throttle timer and flush final content
    streamController.cleanupTimers(messageId);

    final shouldGenerateTitle =
        generateTitle && state.ctx.generateTitleOnFinish && !state.titleQueued;
    if (state.finishHandled) {
      if (shouldGenerateTitle) {
        state.titleQueued = true;
        onMaybeGenerateTitle?.call(conversationId);
      }
      return;
    }
    state.finishHandled = true;
    if (shouldGenerateTitle) {
      state.titleQueued = true;
    }

    // Replace extremely long inline base64 images with local files to avoid jank
    final processedContent = _transformAssistantContent(state);
    final sanitizedContent =
        await MarkdownMediaSanitizer.replaceInlineBase64Images(processedContent);
    // Extract pending AI Team proposals for persistence
    final pendingProposals = _aiTeamPendingProposals.remove(messageId);
    await chatService.updateMessage(
      messageId,
      content: sanitizedContent,
      totalTokens: state.totalTokens,
      isStreaming: false,
      aiTeamProposalsJson: pendingProposals,
    );

    final index = _messages.indexWhere((m) => m.id == messageId);
    if (index != -1) {
      _messages[index] = _messages[index].copyWith(
        content: sanitizedContent,
        totalTokens: state.totalTokens,
        isStreaming: false,
        aiTeamProposalsJson: pendingProposals,
      );
      onMessagesChanged?.call();
    }
    _setConversationLoading(conversationId, false);

    // Use unified reasoning completion method
    await streamController.finishReasoningAndPersist(
      messageId,
      updateReasoningInDb: (
        String messageId, {
        String? reasoningText,
        DateTime? reasoningFinishedAt,
        String? reasoningSegmentsJson,
      }) async {
        await chatService.updateMessage(
          messageId,
          reasoningText: reasoningText,
          reasoningFinishedAt: reasoningFinishedAt,
          reasoningSegmentsJson: reasoningSegmentsJson,
        );
      },
    );

    if (shouldGenerateTitle) {
      onMaybeGenerateTitle?.call(conversationId);
    }

    // Trigger summary generation check (actual logic in HomeViewModel)
    onMaybeGenerateSummary?.call(conversationId);
  }

  /// Handle stream error.
  Future<void> _handleStreamError(
      dynamic e, stream_ctrl.StreamingState state) async {
    final messageId = state.messageId;
    final conversationId = state.conversationId;
    final errorText = e.toString();

    // Mark streaming as ended to allow UI rebuilds again
    streamController.markStreamingEnded(messageId);

    streamController.cleanupTimers(messageId);
    final rawContent =
        state.fullContentRaw.isNotEmpty ? state.fullContentRaw : errorText;
    final processed = _transformAssistantContent(state, rawContent);
    // Let UI provide the localized error message
    final displayContent = processed.isNotEmpty ? processed : errorText;
    // R2: Persist pending AI Team proposals on error
    final pendingProposals = _aiTeamPendingProposals.remove(messageId);
    await chatService.updateMessage(
      messageId,
      content: displayContent,
      totalTokens: state.totalTokens,
      isStreaming: false,
      aiTeamProposalsJson: pendingProposals,
    );

    final index = _messages.indexWhere((m) => m.id == messageId);
    if (index != -1) {
      _messages[index] = _messages[index].copyWith(
        content: displayContent,
        isStreaming: false,
        totalTokens: state.totalTokens,
        aiTeamProposalsJson: pendingProposals,
      );
      onMessagesChanged?.call();
    }
    _setConversationLoading(conversationId, false);

    // Use unified reasoning completion method on error
    await streamController.finishReasoningAndPersist(
      messageId,
      updateReasoningInDb: (
        String messageId, {
        String? reasoningText,
        DateTime? reasoningFinishedAt,
        String? reasoningSegmentsJson,
      }) async {
        await chatService.updateMessage(
          messageId,
          reasoningText: reasoningText,
          reasoningFinishedAt: reasoningFinishedAt,
          reasoningSegmentsJson: reasoningSegmentsJson,
        );
      },
    );

    await _conversationStreams.remove(conversationId)?.cancel();
    onStreamError?.call(errorText);
    onStreamFinished?.call();
  }

  /// Handle stream done callback.
  Future<void> _handleStreamDone(stream_ctrl.StreamingState state) async {
    final conversationId = state.conversationId;

    // Ensure streaming is marked as ended
    streamController.markStreamingEnded(state.messageId);

    streamController.cleanupTimers(state.messageId);
    if (_loadingConversationIds.contains(conversationId)) {
      await _finishStreaming(state,
          generateTitle: state.ctx.generateTitleOnFinish);
    }
    onStreamFinished?.call();
    await _conversationStreams.remove(conversationId)?.cancel();
  }

  // ============================================================================
  // Flush Progress (for switching conversations)
  // ============================================================================

  /// Persist latest in-flight assistant message content and reasoning.
  Future<void> flushConversationProgress(Conversation? conversation) async {
    final cid = conversation?.id;
    if (cid == null || _messages.isEmpty) return;

    // Find the latest streaming assistant message in the current conversation
    ChatMessage? streaming;
    for (var i = _messages.length - 1; i >= 0; i--) {
      final m = _messages[i];
      if (m.role == 'assistant' && m.isStreaming && m.conversationId == cid) {
        streaming = m;
        break;
      }
    }
    if (streaming == null) return;

    // Use the UI-side content snapshot (may be ahead of last persisted chunk)
    String latestContent = streaming.content;
    // Also capture reasoning progress if tracked in-memory
    final r = streamController.reasoning[streaming.id];
    final segs = streamController.reasoningSegments[streaming.id];

    try {
      await chatService.updateMessage(
        streaming.id,
        content: latestContent,
        totalTokens: streaming.totalTokens,
        // Do not flip isStreaming here; just flush progress
      );
      if (r != null) {
        await chatService.updateMessage(
          streaming.id,
          reasoningText: r.text,
          reasoningStartAt: r.startAt ?? DateTime.now(),
          // keep finishedAt as-is (may be null while thinking)
        );
      }
      if (segs != null && segs.isNotEmpty) {
        await chatService.updateMessage(
          streaming.id,
          reasoningSegmentsJson: streamController.serializeReasoningSegments(segs),
        );
      }
      // Ensure any inline data URLs get converted even if the user navigates away mid-stream
      onScheduleImageSanitize?.call(streaming.id, latestContent,
          immediate: true);
    } catch (_) {}
  }
}
