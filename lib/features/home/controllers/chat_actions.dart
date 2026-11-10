import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../../core/models/ai_team_config.dart';
import '../../../core/models/answer_review.dart';
import '../../../core/models/assistant.dart';
import '../../../core/models/chat_input_data.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/conversation.dart';
import '../../../core/models/token_usage.dart';
import '../../../core/providers/ai_team_provider.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/api/chat_api_service.dart';
import '../../../core/services/api/learned_context_windows.dart';
import '../../../core/services/api/native_input_policy.dart';
import '../../../core/services/api/opencode.dart';
import '../../../core/services/api/opencode_errors.dart';
import '../../../core/services/api/transient_stream_error.dart';
import '../../../core/services/auth/oauth_errors.dart';
import '../../../core/services/auth/oauth_failure.dart';
import '../../../core/services/auth/oauth_recovery_registry.dart';
import '../../../core/services/auth/provider_oauth_service.dart';
import '../../../core/services/agent/approval.dart';
import '../../../core/services/agent/compaction/midrun_compactor.dart';
import '../../../core/services/shell/shell_policy.dart';
import '../../../core/services/shell/shell_run_service.dart';
import '../../../core/services/chat/ask_user_models.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/chat/storage/message_part_codec.dart';
import '../../../core/services/chat/todo_models.dart';
import '../../../core/services/chat/todo_projection.dart';
import '../../../core/services/chat/todo_v1_migration.dart';
import '../../../core/services/workspace/workspace_resolver.dart';
import '../../../l10n/app_localizations.dart';
import '../../../utils/assistant_regex.dart';
import '../../../core/models/assistant_regex.dart';
import '../../../utils/markdown_media_sanitizer.dart';
import '../../../core/services/agent/agent_orchestrator.dart';
import '../../../core/services/agent/answer_review.dart';
import '../../../core/services/agent/checkpoint/agent_run_checkpoint.dart';
import '../../../core/services/agent/checkpoint/agent_run_checkpoint_store.dart';
import '../../../core/services/agent/checkpoint/agent_run_journal.dart';
import '../../../core/services/logging/flutter_logger.dart';
import '../services/attachment_modality_gate.dart';
import '../services/message_generation_service.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../chat/widgets/chat_message_widget.dart';
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
    ProviderOAuthService? oauthService,
    OAuthRecoveryRegistry? oauthRecoveryRegistry,
    AgentRunCheckpointStore? checkpointStore,
    AgentRunFence? runFence,
  }) : oauthService = oauthService ?? ProviderOAuthService.instance,
       oauthRecoveryRegistry =
           oauthRecoveryRegistry ?? OAuthRecoveryRegistry.instance,
       _checkpointStore = checkpointStore ?? AgentRunCheckpointStore.instance,
       _runFence = runFence ?? AgentRunFence.instance;

  final ChatService chatService;
  final ChatController chatController;
  final stream_ctrl.StreamController streamController;
  final GenerationController generationController;
  final MessageGenerationService messageGenerationService;
  final BuildContext contextProvider;
  final AgentRunCheckpointStore _checkpointStore;
  final AgentRunFence _runFence;

  /// Subscription-account state and per-message auth failures (plan M4).
  /// Injected in tests; defaults to the app-wide singletons in production.
  final ProviderOAuthService oauthService;
  final OAuthRecoveryRegistry oauthRecoveryRegistry;

  /// P0-2/P0-3 agent-loop driver: the only generation path (the transport is
  /// single-round). Stateless per run.
  final AgentOrchestrator _agentOrchestrator = AgentOrchestrator();

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

  /// Called when the L1 retry loop is about to reissue a request after a
  /// transient network failure or silent stream interruption. The UI uses
  /// this to display a "正在重試 X/3…" info snackbar.
  ///
  /// [conversationId] identifies the conversation the retry belongs to,
  /// so the UI can ignore retries for conversations the user has since
  /// navigated away from.
  ///
  /// [errorKind] is one of `'transient_retry'` (network-level failure) or
  /// `'silent_interrupt_retry'` (SSE body ended without a finish marker).
  void Function(
    int attempt,
    int maxAttempts,
    String errorKind,
    String conversationId,
  )?
  onStreamRetry;

  /// Called when stream finishes and title may need to be generated.
  void Function(String conversationId)? onMaybeGenerateTitle;

  /// Called when summary may need to be generated (every N messages).
  void Function(String conversationId)? onMaybeGenerateSummary;

  /// Called to schedule inline image sanitization.
  void Function(String messageId, String content, {bool immediate})?
  onScheduleImageSanitize;

  /// Called when streaming finishes.
  VoidCallback? onStreamFinished;

  /// Called after a durable agent-run checkpoint is written or cleared, so
  /// the UI can refresh the resume banner without waiting for a restart.
  VoidCallback? onRunCheckpointChanged;

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

  /// P1-1: one in-flight decision per tool call. Tool execution can take
  /// minutes (`shell_run`); without this lock a second tap re-runs the command
  /// and starts a competing continuation (2026-11-10 Windows report).
  final Set<String> _approvalResolutionsInFlight = <String>{};

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
  String _transformAssistantContent(
    stream_ctrl.StreamingState state, [
    String? raw,
  ]) {
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
    final assistantProvider = contextProvider.read<AssistantProvider>();
    final assistant = conversation.assistantId == null
        ? assistantProvider.currentAssistant
        : assistantProvider.getById(conversation.assistantId!);
    final assistantId = assistant?.id;
    final modelConfig = messageGenerationService.getModelConfig(
      settings,
      assistant,
    );

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

    // AI Team fan-out cannot use one selected model's native capability for
    // every proposer (§7 F10).
    final nativeInputsEnabled = nativeInputsEnabledForAiTeam(
      aiTeamEnabled: aiTeam.enabled,
      hasProposers: aiTeam.hasProposers,
    );

    // Attachment modality gate (multimodal plan C1): warn up front when the
    // selected model has no audio input. The card is kept in the message; the
    // assembler omits the audio part (no mojibake, no provider 400).
    try {
      final gateInfo = ChatApiService.effectiveModelInfo(
        settings.getProviderConfig(effProviderKey),
        effModelId,
      );
      final nativePolicy = resolveNativeInputPolicy(
        settings,
        effProviderKey,
        effModelId,
      );
      final unsupportedAudio = AttachmentModalityGate.unsupported(
        input.documents,
        gateInfo,
        nativeAudioEnabled: nativePolicy.nativeAudio && nativeInputsEnabled,
      );
      if (unsupportedAudio.isNotEmpty) {
        final l10n = AppLocalizations.of(contextProvider);
        if (l10n != null) {
          showAppSnackBar(
            contextProvider,
            message: l10n.unsupportedAttachmentStripped(
              unsupportedAudio.length,
            ),
            type: NotificationType.warning,
          );
        }
      }
    } catch (_) {}

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
    final assistantMessage = await messageGenerationService
        .createAssistantPlaceholder(
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
    final enableReasoning =
        supportsReasoning &&
        _isReasoningEnabled(
          assistant?.thinkingBudget ?? settings.thinkingBudget,
        );
    await messageGenerationService.initializeReasoningState(
      messageId: assistantMessage.id,
      enableReasoning: enableReasoning,
    );

    // Prepare API messages
    final prepared = await messageGenerationService
        .prepareApiMessagesWithInjections(
          messages: _messages,
          assistantMessageId: assistantMessage.id,
          versionSelections: _versionSelections,
          currentConversation: conversation,
          settings: settings,
          assistant: assistant,
          assistantId: assistantId,
          providerKey: effProviderKey,
          modelId: effModelId,
          enableNativeInputs: nativeInputsEnabled,
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
  // P1-3 ask_user Resume (kelivo `ask_user_input_v0` semantics)
  // ============================================================================

  /// Resume generation after the user answers (or skips) an `ask_user`
  /// decision card. The pending tool event (call + arguments persisted,
  /// content only carrying the pending marker) is the natural checkpoint:
  /// resume = upsert the answer JSON as the event content, then start a new
  /// assistant message whose context replays the answered tool result.
  ///
  /// Returns the new assistant message, or null when the event is missing,
  /// already answered, or the conversation/model is unavailable.
  Future<ChatMessage?> resumeAfterAskUserAnswer(
    String conversationId,
    String assistantMessageId,
    String toolCallId,
    Map<String, dynamic> answerPayload,
  ) async {
    final conv = _currentConversation;
    if (conv == null || conv.id != conversationId) return null;
    if (_loadingConversationIds.contains(conversationId)) return null;
    // The timeline preloads summaries only; this resume path reads the full
    // events (questions/answers), so load them first.
    await chatService.ensureToolEventsLoaded([assistantMessageId]);
    final settings = contextProvider.read<SettingsProvider>();
    final assistantProvider = contextProvider.read<AssistantProvider>();
    final assistant = conv.assistantId == null
        ? assistantProvider.currentAssistant
        : assistantProvider.getById(conv.assistantId!);
    final modelConfig = messageGenerationService.getModelConfig(
      settings,
      assistant,
    );
    if (modelConfig.providerKey == null || modelConfig.modelId == null) {
      return null;
    }

    // 1. Persist the answer as the tool event content (checkpoint complete).
    //    Preserve the original arguments (the questions) from the event.
    final answerJson = jsonEncode(answerPayload);
    Map<String, dynamic> originalArgs = const <String, dynamic>{};
    try {
      for (final e in chatService.getToolEvents(assistantMessageId)) {
        if ((e['id']?.toString() ?? '') == toolCallId) {
          final a = e['arguments'];
          if (a is Map) {
            originalArgs = a.map((k, v) => MapEntry(k.toString(), v));
          }
          break;
        }
      }
    } catch (_) {}
    try {
      await chatService.upsertToolEvent(
        assistantMessageId,
        id: toolCallId,
        name: askUserToolName,
        arguments: originalArgs,
        content: answerJson,
      );
    } catch (_) {
      return null;
    }

    // 2. Refresh the in-memory tool part so the card flips to Answered.
    final parts = List<ToolUIPart>.of(
      streamController.toolParts[assistantMessageId] ?? const [],
    );
    final pIdx = parts.indexWhere((p) => p.id == toolCallId);
    if (pIdx >= 0) {
      parts[pIdx] = ToolUIPart(
        id: parts[pIdx].id,
        toolName: parts[pIdx].toolName,
        arguments: parts[pIdx].arguments,
        content: answerJson,
        loading: false,
        contentLoaded: true,
        status: kPartStatusCompleted,
        searchProvider: parts[pIdx].searchProvider,
        searchFallbackFrom: parts[pIdx].searchFallbackFrom,
        webFetchSource: parts[pIdx].webFetchSource,
        diffAdded: parts[pIdx].diffAdded,
        diffRemoved: parts[pIdx].diffRemoved,
        diffText: parts[pIdx].diffText,
        imagePath: parts[pIdx].imagePath,
      );
      streamController.toolParts[assistantMessageId] = parts;
      streamController.streamingContentNotifier.notifyToolPartsUpdated(
        assistantMessageId,
      );
    }

    // 3. Continue with a new assistant message (kelivo semantics: the
    // answered tool result replays into the next turn's context).
    final assistantMessage = await messageGenerationService
        .createAssistantPlaceholder(
          conversationId: conversationId,
          modelId: modelConfig.modelId!,
          providerKey: modelConfig.providerKey!,
        );
    streamController.markStreamingStarted(assistantMessage.id);
    _messages.add(assistantMessage);
    onMessagesChanged?.call();
    _setConversationLoading(conversationId, true);

    final supportsReasoning = _isReasoningModel(
      modelConfig.providerKey!,
      modelConfig.modelId!,
    );
    final enableReasoning =
        supportsReasoning &&
        _isReasoningEnabled(
          assistant?.thinkingBudget ?? settings.thinkingBudget,
        );
    await messageGenerationService.initializeReasoningState(
      messageId: assistantMessage.id,
      enableReasoning: enableReasoning,
    );

    final prepared = await messageGenerationService
        .prepareApiMessagesWithInjections(
          messages: _messages,
          assistantMessageId: assistantMessage.id,
          versionSelections: _versionSelections,
          currentConversation: conv,
          settings: settings,
          assistant: assistant,
          assistantId: assistant?.id,
          providerKey: modelConfig.providerKey!,
          modelId: modelConfig.modelId!,
        );

    final userImagePaths = messageGenerationService.buildUserImagePaths(
      input: null,
      lastUserImagePaths: prepared.lastUserImagePaths,
      settings: settings,
    );

    final ctx = messageGenerationService.buildGenerationContext(
      assistantMessage: assistantMessage,
      prepared: prepared,
      userImagePaths: userImagePaths,
      providerKey: modelConfig.providerKey!,
      modelId: modelConfig.modelId!,
      assistant: assistant,
      settings: settings,
      supportsReasoning: supportsReasoning,
      enableReasoning: enableReasoning,
      generateTitleOnFinish: false,
    );

    await _executeGeneration(ctx);
    return assistantMessage;
  }

  // ============================================================================
  // P1-1 Approval Resume (ADR-A5: approval = loop pause, not blocking)
  // ==========================================================================

  /// Resolve an approval decision and continue the run.
  ///
  /// One-shot (2026-11-10): only a still-pending event can be resolved, and a
  /// per-call in-flight lock prevents a second tap from re-executing the tool
  /// while it runs.
  ///
  /// [approve] = execute the pending call once and feed its real result to
  /// the model; deny = feed the structured denial JSON (ask_user answers are
  /// dispatched to [resumeAfterAskUserAnswer] before reaching here).
  /// [alwaysAllow] additionally records the `workspace-out:{resolvedPath}`
  /// override so future calls to the same concrete out-of-workspace path
  /// skip the card (persisted, not in _localOnlyKeys).
  Future<ChatMessage?> resolveApproval(
    String conversationId,
    String assistantMessageId,
    String toolCallId, {
    required bool approve,
    bool alwaysAllow = false,
  }) async {
    final conv = _currentConversation;
    if (conv == null || conv.id != conversationId) return null;

    // P1-1 (2026-11-10): one decision per pending call. A shell command may
    // run for minutes; without this lock a second tap re-executes it and
    // starts a competing continuation (Windows report).
    final decisionKey = '$assistantMessageId::$toolCallId';
    if (!_approvalResolutionsInFlight.add(decisionKey)) {
      // A second tap while the decision is in flight: keep the card's
      // executing state visible (it can be lost across a rebuild) and drop
      // the duplicate before it can execute the tool again.
      if (approve) {
        _setApprovalExecuting(assistantMessageId, toolCallId, true);
      }
      return null;
    }

    try {
      return await _resolveApprovalUnlocked(
        conversationId,
        assistantMessageId,
        toolCallId,
        approve: approve,
        alwaysAllow: alwaysAllow,
      );
    } catch (error) {
      FlutterLogger.log(
        'Approval decision failed for $toolCallId: $error',
        tag: 'approval',
      );
      _notifyApprovalProblem(
        _l10n?.approvalResolveUnavailable ??
            'The approval request is no longer available.',
      );
      return null;
    } finally {
      if (approve) {
        _setApprovalExecuting(assistantMessageId, toolCallId, false);
      }
      _approvalResolutionsInFlight.remove(decisionKey);
    }
  }

  /// The decision body: validates the pending event, executes (or denies) the
  /// call exactly once, persists the outcome and resumes generation.
  Future<ChatMessage?> _resolveApprovalUnlocked(
    String conversationId,
    String assistantMessageId,
    String toolCallId, {
    required bool approve,
    bool alwaysAllow = false,
  }) async {
    final conv = _currentConversation;
    if (conv == null || conv.id != conversationId) return null;
    // The pending card can render a moment before the paused run writes its
    // terminal and clears the loading flag. Waiting briefly lets the first
    // tap land instead of being dropped silently.
    if (_loadingConversationIds.contains(conversationId) &&
        !await _awaitConversationIdle(conversationId)) {
      _notifyApprovalProblem(
        _l10n?.approvalResolveBusy ??
            'A reply is still being generated. Try again in a moment.',
      );
      return null;
    }

    // The timeline preloads summaries only; approval needs the full event.
    await chatService.ensureToolEventsLoaded([assistantMessageId]);

    // Locate the pending event. A no-id part cannot address one specific
    // event, so it goes straight to the unique-pending fallback below.
    final events = chatService.getToolEvents(assistantMessageId);
    Map<String, dynamic>? event;
    if (toolCallId.trim().isNotEmpty) {
      for (final e in events) {
        if ((e['id']?.toString() ?? '') == toolCallId) {
          event = e;
          break;
        }
      }
    }
    if (event != null && !isApprovalPendingEvent(event)) {
      _notifyApprovalProblem(
        _l10n?.approvalAlreadyResolved ?? 'This approval has already been handled. Ask the model to run the step again if needed.',
      );
      return null;
    }
    if (event == null) {
      final part = _toolPart(assistantMessageId, toolCallId);
      event = findApprovalDecisionEvent(
        events,
        toolCallId: toolCallId,
        toolName: part?.toolName,
        arguments: part?.arguments,
      );
    }
    if (event == null) {
      _notifyApprovalProblem(
        _l10n?.approvalResolveUnavailable ?? 'The approval request could not be found. Ask the model to run the step again.',
      );
      return null;
    }
    // The persisted id can differ from the UI part id when a provider omitted
    // or rewrote it; every write must target the event we actually found.
    final eventId = (event['id'] ?? '').toString().trim();
    final name = (event['name'] ?? '').toString();
    final argsRaw = event['arguments'];
    final args = argsRaw is Map
        ? argsRaw.map((k, v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};

    // P1-1 timeout (CLI v4 §三.3): a Pending card older than the approval
    // window resolves to the approval_timeout JSON — the tool is NOT
    // executed even on a late approve; the model must ask again.
    final pendingPayload = parseApprovalContent(event['content']?.toString());
    final timeoutWindow = name == ShellRunService.toolName
        ? shellApprovalPendingTimeout
        : null;
    if (isApprovalTimedOut(
      pendingPayload?['requested_at'],
      timeout: timeoutWindow,
    )) {
      final timeoutJson = buildApprovalTimeoutContent(toolName: name);
      _notifyApprovalProblem(
        _l10n?.approvalTimedOutNotice ??
            'This approval timed out, so the tool was not executed.',
      );
      final updated = await chatService.setToolEventApprovalState(
        assistantMessageId,
        id: eventId,
        approvalState: approvalStateDenied,
        content: timeoutJson,
      );
      if (!updated) {
        _notifyApprovalProblem(
          _l10n?.approvalResolveUnavailable ??
              'The approval request is no longer available.',
        );
        return null;
      }
      _refreshToolPart(
        assistantMessageId,
        toolCallId,
        content: timeoutJson,
        status: kPartStatusDenied,
      );
      return _continueAfterApproval(
        conv: conv,
        answeredAssistantMessageId: assistantMessageId,
      );
    }

    // Feedback before the (possibly multi-minute) execution: hide the
    // buttons and show progress. Only a confirmed pending event gets here,
    // so a stale card can never flash "approved — running".
    if (approve) {
      _setApprovalExecuting(assistantMessageId, toolCallId, true);
    }

    // "Always allow": persist the out-of-workspace override key derived from
    // the pending payload so future calls to the same concrete resolved path
    // skip the card (the policy snapshot reads it back on the next run).
    if (alwaysAllow && approve) {
      try {
        final settings = contextProvider.read<SettingsProvider>();
        if (name == ShellRunService.toolName) {
          // P1-6: shell "always allow" writes every program of the command
          // back into the developer-mode allowlist (compound commands add
          // each segment's program).
          for (final program in ShellPolicy.programsIn(
            (args['command'] ?? '').toString(),
          )) {
            await settings.addShellAllowlistEntry(program);
          }
        } else {
          final resolvedPath = pendingPayload?['resolved_path']?.toString();
          if (resolvedPath != null && resolvedPath.trim().isNotEmpty) {
            await settings.addApprovalAlwaysAllowed(
              'workspace-out:$resolvedPath',
            );
          }
        }
      } catch (_) {}
    }

    // Deny: record the denial and continue with the denial JSON as the
    // tool result (the model can adjust course instead of blindly retrying).
    if (!approve) {
      final denialJson = buildApprovalDeniedContent(toolName: name);
      final updated = await chatService.setToolEventApprovalState(
        assistantMessageId,
        id: eventId,
        approvalState: approvalStateDenied,
        content: denialJson,
      );
      if (!updated) {
        _notifyApprovalProblem(
          _l10n?.approvalResolveUnavailable ??
              'The approval request is no longer available.',
        );
        return null;
      }
      _refreshToolPart(
        assistantMessageId,
        toolCallId,
        content: denialJson,
        status: kPartStatusDenied,
      );
      return _continueAfterApproval(
        conv: conv,
        answeredAssistantMessageId: assistantMessageId,
      );
    }

    // Approve: execute the tool once (the checkpoint was the pending event;
    // the side effect happens exactly here), then persist the real result.
    // When the pending payload carries an out-of-workspace path, hand it to
    // the handler so the call skips re-classification and the executor runs
    // against the concrete path the user approved (ADR-A8).
    final outsideWorkspace = pendingPayload?['outside_workspace'] == true;
    final approvedPath = pendingPayload?['resolved_path']?.toString();
    final handler = generationController.buildToolCallHandler(
      contextProvider.read<SettingsProvider>(),
      _assistantForConversation(conv),
      conversationId: conversationId,
      messageId: assistantMessageId,
      workspacePath: await _workspacePathFor(conv),
      approvedResolvedPath:
          (outsideWorkspace && (approvedPath ?? '').isNotEmpty)
          ? approvedPath
          : null,
      approvedShellCommand: name == ShellRunService.toolName
          ? (args['command'] ?? '').toString()
          : null,
    );
    String result;
    try {
      result =
          await handler?.call(name, args, toolCallId: eventId) ??
          jsonEncode(<String, dynamic>{
            'type': 'tool_error',
            'error': 'execution_error',
            'message': 'Tool handler unavailable.',
            'tool': name,
          });
    } catch (e) {
      result = jsonEncode(<String, dynamic>{
        'type': 'tool_error',
        'error': 'execution_error',
        'message': e.toString(),
        'tool': name,
      });
    }
    final updated = await chatService.setToolEventApprovalState(
      assistantMessageId,
      id: eventId,
      approvalState: approvalStateApproved,
      content: result,
    );
    if (!updated) {
      _notifyApprovalProblem(
        _l10n?.approvalResolveUnavailable ??
            'The approval request is no longer available.',
      );
      return null;
    }
    _refreshToolPart(assistantMessageId, toolCallId, content: result);
    return _continueAfterApproval(
      conv: conv,
      answeredAssistantMessageId: assistantMessageId,
    );
  }

  /// Shared continuation after an approval decision: create a new assistant
  /// message whose context replays the resolved tool event (same mechanism
  /// as the P1-3 ask_user resume).
  Future<ChatMessage?> _continueAfterApproval({
    required Conversation conv,
    required String answeredAssistantMessageId,
  }) async {
    final settings = contextProvider.read<SettingsProvider>();
    final assistant = _assistantForConversation(conv);
    final modelConfig = messageGenerationService.getModelConfig(
      settings,
      assistant,
    );
    if (modelConfig.providerKey == null || modelConfig.modelId == null) {
      return null;
    }
    final assistantMessage = await messageGenerationService
        .createAssistantPlaceholder(
          conversationId: conv.id,
          modelId: modelConfig.modelId!,
          providerKey: modelConfig.providerKey!,
        );
    streamController.markStreamingStarted(assistantMessage.id);
    _messages.add(assistantMessage);
    onMessagesChanged?.call();
    _setConversationLoading(conv.id, true);

    final supportsReasoning = _isReasoningModel(
      modelConfig.providerKey!,
      modelConfig.modelId!,
    );
    final enableReasoning =
        supportsReasoning &&
        _isReasoningEnabled(
          assistant?.thinkingBudget ?? settings.thinkingBudget,
        );
    await messageGenerationService.initializeReasoningState(
      messageId: assistantMessage.id,
      enableReasoning: enableReasoning,
    );

    final prepared = await messageGenerationService
        .prepareApiMessagesWithInjections(
          messages: _messages,
          assistantMessageId: assistantMessage.id,
          versionSelections: _versionSelections,
          currentConversation: conv,
          settings: settings,
          assistant: assistant,
          assistantId: assistant?.id,
          providerKey: modelConfig.providerKey!,
          modelId: modelConfig.modelId!,
        );

    final userImagePaths = messageGenerationService.buildUserImagePaths(
      input: null,
      lastUserImagePaths: prepared.lastUserImagePaths,
      settings: settings,
    );

    final ctx = messageGenerationService.buildGenerationContext(
      assistantMessage: assistantMessage,
      prepared: prepared,
      userImagePaths: userImagePaths,
      providerKey: modelConfig.providerKey!,
      modelId: modelConfig.modelId!,
      assistant: assistant,
      settings: settings,
      supportsReasoning: supportsReasoning,
      enableReasoning: enableReasoning,
      generateTitleOnFinish: false,
    );

    await _executeGeneration(ctx);
    return assistantMessage;
  }

  void _refreshToolPart(
    String messageId,
    String toolCallId, {
    required String content,
    String status = kPartStatusCompleted,
  }) {
    final parts = List<ToolUIPart>.of(
      streamController.toolParts[messageId] ?? const [],
    );
    final idx = parts.indexWhere((p) => p.id == toolCallId);
    if (idx < 0) return;
    parts[idx] = parts[idx].copyWith(
      content: content,
      contentLength: content.length,
      loading: false,
      contentLoaded: true,
      status: status,
      approvalExecuting: false,
    );
    streamController.toolParts[messageId] = parts;
    streamController.streamingContentNotifier.notifyToolPartsUpdated(messageId);
  }

  /// Localized copy for approval failures; null outside a localized tree
  /// (test doubles / early startup).
  AppLocalizations? get _l10n => AppLocalizations.of(contextProvider);

  /// Surface a failed decision instead of the historical silent no-op.
  void _notifyApprovalProblem(String message) {
    if (message.trim().isEmpty) return;
    // Feedback is best-effort: an unmounted/early context must never turn a
    // failed decision into an exception.
    try {
      showAppSnackBar(
        contextProvider,
        message: message,
        type: NotificationType.warning,
      );
    } catch (_) {}
  }

  /// Wait briefly for the paused run's terminal to clear [conversationId]'s
  /// loading flag. Returns false when another generation is still active.
  Future<bool> _awaitConversationIdle(String conversationId) async {
    for (var attempt = 0; attempt < 20; attempt++) {
      if (!_loadingConversationIds.contains(conversationId)) return true;
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    return !_loadingConversationIds.contains(conversationId);
  }

  ToolUIPart? _toolPart(String messageId, String toolCallId) {
    final parts = streamController.toolParts[messageId];
    if (parts == null) return null;
    for (final part in parts) {
      if (part.id == toolCallId) return part;
    }
    return null;
  }

  /// Show/hide the card's "approved — running" state without touching the
  /// persisted event (the result write owns the real lifecycle).
  void _setApprovalExecuting(
    String messageId,
    String toolCallId,
    bool executing,
  ) {
    final parts = List<ToolUIPart>.of(
      streamController.toolParts[messageId] ?? const [],
    );
    final idx = parts.indexWhere((p) => p.id == toolCallId);
    if (idx < 0 || parts[idx].approvalExecuting == executing) return;
    parts[idx] = parts[idx].copyWith(approvalExecuting: executing);
    streamController.toolParts[messageId] = parts;
    streamController.streamingContentNotifier.notifyToolPartsUpdated(messageId);
    // The paused message is not streaming, so the streaming notifier alone
    // does not repaint its cards; a full list rebuild makes the executing
    // state visible immediately.
    onMessagesChanged?.call();
  }

  Assistant? _assistantForConversation(Conversation conv) {
    final assistantProvider = contextProvider.read<AssistantProvider>();
    return conv.assistantId == null
        ? assistantProvider.currentAssistant
        : assistantProvider.getById(conv.assistantId!);
  }

  Future<String?> _workspacePathFor(Conversation conv) async {
    try {
      final settings = contextProvider.read<SettingsProvider>();
      final assistant = _assistantForConversation(conv);
      final resolved = await WorkspaceResolver.resolve(
        conversation: conv,
        project: assistant,
        conversationConfig: chatService.getConversationWorkspaceConfig(conv.id),
        defaultConfig: settings.defaultWorkspaceConfig,
      );
      return resolved.enabled ? resolved.path : null;
    } catch (_) {
      return null;
    }
  }

  // ============================================================================
  // Regenerate Message
  // ============================================================================

  /// Project the raw message list into the regeneration context.
  ///
  /// Keeps `[0, lastKeep]` verbatim, then adds every message of
  /// [targetGroupId]'s version group (the assistant versions, so version
  /// collapsing downstream can pick the new placeholder).
  ///
  /// Phase-1 fix (2026-09-11): [versionSelections] must be passed so each
  /// version group projects to its *selected* version. Collapsing to the
  /// newest version per group was correct when a regeneration only ever
  /// appended fresh versions, but edit-and-resend creates the new user
  /// version BEFORE calling this — a newest-wins projection resurrects the
  /// pre-edit user text (and any follow-up messages of that stale branch),
  /// so the model regenerated an answer to the OLD question. The call site
  /// sets the selection to the new version (in-memory + Hive) before this
  /// projection is assembled, so selected == newest-in-list here; groups
  /// with no entry fall back to the newest version (unchanged legacy
  /// behavior).
  @visibleForTesting
  static List<ChatMessage> projectMessagesForRegenerationContext({
    required List<ChatMessage> messages,
    required int lastKeep,
    required String? targetGroupId,
    Map<String, int> versionSelections = const <String, int>{},
  }) {
    if (lastKeep < 0) return [...messages];
    // Group [0, lastKeep] by groupId, preserving order (a group is
    // contiguous in practice; the whole list — placeholder included — is
    // then projected with the same collapse, so the [targetGroupId] slice
    // and the appended placeholder can never desync).
    final groupOrder = <String>[];
    final groupIndex = <String, int>{};
    for (int i = 0; i <= lastKeep && i < messages.length; i++) {
      final g = (messages[i].groupId ?? messages[i].id);
      if (!groupIndex.containsKey(g)) {
        groupIndex[g] = groupOrder.length;
        groupOrder.add(g);
      }
    }
    if (targetGroupId != null && !groupIndex.containsKey(targetGroupId)) {
      groupIndex[targetGroupId] = groupOrder.length;
      groupOrder.add(targetGroupId);
    }

    final groups = <String, List<ChatMessage>>{};
    for (final m in messages) {
      final g = (m.groupId ?? m.id);
      if (!groupIndex.containsKey(g)) continue;
      groups.putIfAbsent(g, () => <ChatMessage>[]).add(m);
    }

    // Collapse each kept group to its selected version (newest when no
    // selection is recorded), keeping original order.
    ChatMessage pick(List<ChatMessage> vers) {
      vers.sort((a, b) => a.version.compareTo(b.version));
      final gid = (vers.first.groupId ?? vers.first.id);
      final sel = versionSelections[gid];
      if (sel != null && sel >= 0 && sel < vers.length) return vers[sel];
      return vers.last;
    }

    final projected = <ChatMessage>[];
    for (final g in groupOrder) {
      final vers = groups[g];
      if (vers == null || vers.isEmpty) continue;
      projected.add(pick(vers));
    }

    return projected;
  }

  @visibleForTesting
  static List<ChatMessage> buildRegenerationMessages({
    required List<ChatMessage> messages,
    required int lastKeep,
    required String? targetGroupId,
    required ChatMessage assistantPlaceholder,
    Map<String, int> versionSelections = const <String, int>{},
  }) {
    return <ChatMessage>[
      ...projectMessagesForRegenerationContext(
        messages: messages,
        lastKeep: lastKeep,
        targetGroupId: targetGroupId,
        versionSelections: versionSelections,
      ),
      assistantPlaceholder,
    ];
  }

  /// Regenerate response at a specific message.
  ///
  /// Returns [ChatActionResult] with success status and the new assistant message.
  /// UI is responsible for:
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

    // Get model config
    final settings = contextProvider.read<SettingsProvider>();
    final assistantProvider = contextProvider.read<AssistantProvider>();
    final assistant = conversation.assistantId == null
        ? assistantProvider.currentAssistant
        : assistantProvider.getById(conversation.assistantId!);
    final assistantId = assistant?.id;
    final modelConfig = messageGenerationService.getModelConfig(
      settings,
      assistant,
    );

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
    final nativeInputsEnabled = nativeInputsEnabledForAiTeam(
      aiTeamEnabled: aiTeam.enabled,
      hasProposers: aiTeam.hasProposers,
    );

    // Create assistant message placeholder (new version)
    final assistantMessage = await messageGenerationService
        .createAssistantPlaceholder(
          conversationId: conversation.id,
          modelId: effModelId,
          providerKey: effProviderKey,
          groupId: versioning.targetGroupId,
          version: versioning.nextVersion,
        );

    final regenerationMessages = ChatActions.buildRegenerationMessages(
      messages: _messages,
      lastKeep: versioning.lastKeep,
      targetGroupId: versioning.targetGroupId,
      assistantPlaceholder: assistantMessage,
      // Phase-1 fix: project version groups to the SELECTED version so the
      // edit-and-resend context carries the edited text (the selection was
      // just set to the new version below) instead of the pre-edit version.
      versionSelections: _versionSelections,
    );

    // Pre-create streaming notifier BEFORE adding message to list
    // so that MessageListView can detect it's streaming on first render
    streamController.markStreamingStarted(assistantMessage.id);

    // Persist version selection
    final gid = assistantMessage.groupId ?? assistantMessage.id;
    _versionSelections[gid] = assistantMessage.version;
    await chatService.setSelectedVersion(
      conversation.id,
      gid,
      assistantMessage.version,
    );

    _messages.add(assistantMessage);
    onMessagesChanged?.call();

    _setConversationLoading(conversation.id, true);

    // Initialize reasoning
    final supportsReasoning = _isReasoningModel(effProviderKey, effModelId);
    final enableReasoning =
        supportsReasoning &&
        _isReasoningEnabled(
          assistant?.thinkingBudget ?? settings.thinkingBudget,
        );
    await messageGenerationService.initializeReasoningState(
      messageId: assistantMessage.id,
      enableReasoning: enableReasoning,
    );

    // Prepare API messages
    final prepared = await messageGenerationService
        .prepareApiMessagesWithInjections(
          messages: regenerationMessages,
          assistantMessageId: assistantMessage.id,

          versionSelections: _versionSelections,
          currentConversation: conversation,
          settings: settings,
          assistant: assistant,
          assistantId: assistantId,
          providerKey: effProviderKey,
          modelId: effModelId,
          enableNativeInputs: nativeInputsEnabled,
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
  // Current plan (Phase 3)
  // ============================================================================

  /// Projects the current plan from the active conversation branch. Used by
  /// the plan sheet; no local todo store is involved.
  Future<TodoState?> currentTodoPlan() async {
    final conversation = _currentConversation;
    if (conversation == null) return null;
    try {
      return (await _resolveCurrentTodoPlan(conversation)).state;
    } catch (e) {
      FlutterLogger.log('currentTodoPlan failed: $e', tag: 'todo-plan');
      return null;
    }
  }

  /// Single projection seam shared by the sheet and the clear action. Honors
  /// `todoEventProjectionV1` exactly like generation: when the kill switch is
  /// off, only the read-only `todo_v1` fallback is consulted, so the sheet
  /// can never show a plan the model does not see.
  Future<
    ({TodoState? state, bool fromLegacy, List<ChatMessage> activeMessages})
  >
  _resolveCurrentTodoPlan(Conversation conversation) async {
    final activeMessages = messageGenerationService.messageBuilderService
        .collapseVersions(_messages, _versionSelections);
    final settings = contextProvider.read<SettingsProvider>();
    if (settings.todoEventProjectionV1 && activeMessages.isNotEmpty) {
      await chatService.ensureToolEventsLoaded(activeMessages.map((m) => m.id));
      final eventsByMessageId = <String, List<Map<String, dynamic>>>{
        for (final message in activeMessages)
          message.id: chatService.getToolEvents(message.id),
      };
      final projected = projectTodoState(
        activeMessages: activeMessages,
        eventsByMessageId: eventsByMessageId,
      );
      if (projected != null) {
        return (
          state: projected,
          fromLegacy: false,
          activeMessages: activeMessages,
        );
      }
    }

    // §2.5.3: conversations the one-time migration could not attach keep a
    // read-only `todo_v1` fallback until an assistant message exists.
    final legacy = await TodoV1Migration.legacyItemsFor(conversation.id);
    if (legacy != null && legacy.isNotEmpty) {
      return (
        state: TodoState(items: legacy, hasExplicitState: true),
        fromLegacy: true,
        activeMessages: activeMessages,
      );
    }
    return (state: null, fromLegacy: false, activeMessages: activeMessages);
  }

  /// User-initiated clear (Phase 3-2): appends a successful
  /// `write_todos(todos: [])` tool part with `origin=user_clear` to the
  /// active branch. The conversation event remains the single source of
  /// truth — never a UI-only flag. `write_todos` is non-replayable, so the
  /// appended part cannot produce a dangling tool call.
  Future<bool> clearTodoPlan() async {
    final conversation = _currentConversation;
    if (conversation == null) return false;
    // Never append mid-run: the stream's result-chunk handler replaces the
    // in-memory tool list with its own snapshot, which could hide the clear.
    if (_loadingConversationIds.contains(conversation.id)) return false;
    try {
      final resolved = await _resolveCurrentTodoPlan(conversation);
      final state = resolved.state;
      if (state == null) return false;

      if (resolved.fromLegacy) {
        // Legacy-only fallback (a box entry the migration could not attach
        // because the branch has no assistant message): clearing is a
        // best-effort delete of that read-only entry, not a new store write.
        await TodoV1Migration.dropConversation(conversation.id);
        onMessagesChanged?.call();
        return true;
      }
      // Already cleared → nothing to do.
      if (state.items.isEmpty) return false;

      ChatMessage? target;
      for (final message in resolved.activeMessages.reversed) {
        if (message.role == 'assistant') {
          target = message;
          break;
        }
      }
      // A projected plan always came from an assistant event.
      if (target == null) return false;

      const arguments = <String, dynamic>{'todos': <dynamic>[]};
      final content = buildTodoResultContent(
        items: const <TodoItem>[],
        changed: true,
        cleared: true,
      );
      final toolCallId = 'user_clear_${DateTime.now().microsecondsSinceEpoch}';
      await chatService.upsertToolEvent(
        target.id,
        id: toolCallId,
        name: todoToolName,
        arguments: arguments,
        content: content,
        approvalState: kApprovalAuto,
        extras: const <String, dynamic>{'origin': 'user_clear'},
      );
      streamController.appendCompletedToolPart(
        target.id,
        id: toolCallId,
        toolName: todoToolName,
        arguments: arguments,
        content: content,
      );
      onMessagesChanged?.call();
      return true;
    } catch (e) {
      FlutterLogger.log('clearTodoPlan failed: $e', tag: 'todo-clear');
      return false;
    }
  }

  // ============================================================================
  // Cancel Streaming
  // ============================================================================

  /// Cancel the active streaming for the current conversation.
  Future<void> cancelStreaming(Conversation? conversation) async {
    final cid = conversation?.id;
    if (cid == null) return;

    // P2-1: a deliberate stop is not a resumable interruption. Invalidate
    // the run fence first so a late journal write cannot recreate the row
    // after it is deleted below. Only delete the row when there was actually
    // active work: `regenerateAtMessage` calls this first, and a paused run
    // must not be wiped by an unrelated regenerate tap.
    var hadActiveWork = _runFence.cancel(cid);

    // A foreground shell command is part of the generation: stopping it must
    // terminate the process tree immediately, not wait for its timeout.
    generationController.cancelActiveShellRuns();

    // AI Team: cancel proposer phase if active (I3 + R1: complete cancel completer before cancel)
    if (_aiTeamInProposalPhase) {
      _aiTeamCancelled = true;
      hadActiveWork = true;
      if (_aiTeamCancelCompleter != null &&
          !_aiTeamCancelCompleter!.isCompleted) {
        _aiTeamCancelCompleter!.complete();
      }
      await _aiTeamProposerSub?.cancel();
      _aiTeamProposerSub = null;
      // Also cancel the underlying HTTP request for the proposer stream
      ChatApiService.cancelRequest('${cid}_proposer');
    }

    // Cancel active stream for current conversation only
    final sub = _conversationStreams.remove(cid);
    if (sub != null) hadActiveWork = true;
    await sub?.cancel();
    ChatApiService.cancelRequest(cid);
    // Answer Review v1: the internal review / revision round runs under a
    // `${cid}_review` request id (mirrors the `${cid}_proposer` convention)
    // so a deliberate stop also aborts the in-flight review request.
    ChatApiService.cancelRequest('${cid}_review');

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

      // Answer Review v1: a deliberate stop closes the card as cancelled and
      // keeps the draft. This runs before the content write below so the
      // persisted message still carries the original answer.
      final activeState = _activeStreamStates[streaming.id];
      if (activeState != null) {
        await _finalizeReviewOnAbort(activeState, cancelled: true);
      }

      // R3: persist pending AI Team proposals during aggregator phase
      final pendingProposals = _aiTeamPendingProposals.remove(streaming.id);
      final usageMeta = streaming.usageMeta;

      await chatService.updateMessage(
        streaming.id,
        content: streaming.content,
        isStreaming: false,
        totalTokens: streaming.totalTokens,
        aiTeamProposalsJson: pendingProposals,
        usageMeta: usageMeta,
      );

      final idx = _messages.indexWhere((m) => m.id == streaming!.id);
      if (idx != -1) {
        _messages[idx] = _messages[idx].copyWith(
          isStreaming: false,
          totalTokens: streaming.totalTokens,
          aiTeamProposalsJson: pendingProposals,
          usageMetaJson: usageMeta == null
              ? _messages[idx].usageMetaJson
              : jsonEncode(usageMeta.toJson()),
        );
        onMessagesChanged?.call();
      }
      _setConversationLoading(cid, false);

      // Use unified reasoning completion method
      await streamController.finishReasoningAndPersist(
        streaming.id,
        updateReasoningInDb:
            (
              String messageId, {
              String? reasoningText,
              DateTime? reasoningFinishedAt,
              DateTime? processFinishedAt,
              DateTime? processStartedAt,
              String? reasoningSegmentsJson,
            }) async {
              await chatService.updateMessage(
                messageId,
                reasoningText: reasoningText,
                reasoningFinishedAt: reasoningFinishedAt,
                processFinishedAt: processFinishedAt,
                processStartedAt: processStartedAt,
                reasoningSegmentsJson: reasoningSegmentsJson,
              );
            },
      );

      // If streaming output included inline base64 images, sanitize them even on manual cancel
      onScheduleImageSanitize?.call(
        streaming.id,
        streaming.content,
        immediate: true,
      );
    } else {
      _setConversationLoading(cid, false);
    }

    // Delete only after the stream was asked to stop; the fence above makes
    // any in-flight terminal handler a no-op.
    if (hadActiveWork) {
      await _clearRunCheckpointBestEffort(cid);
      onRunCheckpointChanged?.call();
    }
  }

  // ============================================================================
  // Stream Execution
  // ============================================================================

  /// Phase-1 kernel hooks (IMPORT_PLAN_COWORK.md P0-2/P0-3): the policy the
  /// kernel consults at round boundaries. Built fresh per run so the run
  /// always sees the settings/approval snapshot of its own start (generation
  /// 中 UI 變更不影響已建立的 handler — CLI v4 §四.2 semantics).
  ///
  /// `onRoundStart` duties (plan P0-2 「hooks.onRoundStart 實作」):
  /// 1. **Approval / ask_user pause judgment** — when the previous round left
  ///    an unresolved Pending tool event (approval card not yet decided, or
  ///    an ask_user card not yet answered), veto the round so the run pauses
  ///    (ADR-A5: Pending → break → user resolves → resume via [resumeRun]).
  ///    The veto is a clean stop: no request is sent, tools already executed
  ///    stay executed, and the synthesized terminal chunk has no
  ///    softStopReason — the card is the user-facing surface.
  /// 2. **Mid-run compaction re-evaluation** (P1-2) — the prep-time trigger
  ///    only runs before a run starts; a long loop can still cross the
  ///    trigger mid-flight. The hook estimates the next prompt (measured
  ///    `usage.promptTokens` vs working-list estimate) and compacts the
  ///    working list in place (projection only, ADR-A6) when it fires. The
  ///    kernel's cumulative `tokensSoFar` is reserved for the token budget.
  /// P2-1: unresolved approval / ask_user tool events for [assistantMessageId].
  /// The events are the authoritative pause source; the journal only mirrors
  /// them as a durable breadcrumb for future recovery surfaces (P2-2).
  ///
  /// Throws when the events are not loaded; [_resolvePendingTools] turns that
  /// into an explicit "unknown" result instead of a misleading empty list
  /// (which would look like "no pending tools" and could clear a pause).
  List<AgentRunPendingTool> _pendingToolsFromEvents(String assistantMessageId) {
    final out = <AgentRunPendingTool>[];
    final seen = <String>{};
    for (final e in chatService.getToolEvents(assistantMessageId)) {
      final id = (e['id'] ?? '').toString().trim();
      if (id.isEmpty || !seen.add(id)) continue;
      final name = (e['name'] ?? '').toString();
      final approvalState = (e['approvalState'] ?? '').toString();
      if (approvalState == approvalStatePending) {
        out.add(AgentRunPendingTool(id: id, name: name, kind: 'approval'));
        continue;
      }
      // ask_user cards created before an answer upsert the content: the
      // pending content JSON is the marker (the state field is absent for
      // legacy events).
      final parsedAsk = parseAskUserContent(e['content']?.toString());
      if (parsedAsk != null && parsedAsk['type'] == askUserPendingType) {
        out.add(AgentRunPendingTool(id: id, name: name, kind: 'ask_user'));
      }
    }
    return out;
  }

  /// Resolve the authoritative pending state, loading lazy tool events first.
  /// A read failure is "unknown", never "none": terminal classification must
  /// keep the existing checkpoint rather than delete a paused run.
  Future<AgentRunPendingSnapshot> _resolvePendingTools(
    String assistantMessageId,
  ) async {
    try {
      await chatService.ensureToolEventsLoaded([assistantMessageId]);
      return AgentRunPendingSnapshot.known(
        _pendingToolsFromEvents(assistantMessageId),
      );
    } catch (e) {
      FlutterLogger.log(
        'Could not read pending tool state for $assistantMessageId: $e',
        tag: 'agent-checkpoint',
      );
      return const AgentRunPendingSnapshot.unknown();
    }
  }

  Future<void> _clearRunCheckpointBestEffort(String conversationId) async {
    try {
      await _checkpointStore.delete(conversationId);
    } catch (e) {
      FlutterLogger.log(
        'Agent-run checkpoint cleanup failed: $e',
        tag: 'agent-checkpoint',
      );
    }
  }

  Future<stream_ctrl.AgentLoopHooks> _buildPhase1Hooks(
    stream_ctrl.StreamingState state,
  ) async {
    final ctx = state.ctx;
    final assistantMessageId = ctx.assistantMessage.id;
    final journal = state.agentJournal ??= AgentRunJournal(
      store: _checkpointStore,
      conversationId: state.conversationId,
      assistantMessageId: assistantMessageId,
      resolvePending: () => _resolvePendingTools(assistantMessageId),
      fence: _runFence,
    );

    return stream_ctrl.AgentLoopHooks(
      onRoundStart: (stepIndex, messages, tokensSoFar) async {
        // P2-1: this must finish before the round is dispatched. The journal
        // is the durable boundary; a write failure disables it for the rest
        // of the session instead of failing the generation.
        final shouldContinue = await journal.onRoundStart(
          stepIndex,
          tokensSoFar,
        );
        if (!shouldContinue) return false;

        // Duty 2 — mid-run compaction (P1-2). Step 0 was already evaluated
        // by the prep-time trigger; re-evaluating it here would duplicate
        // the projection. Use the prompt-size estimate, never the kernel's
        // cumulative token counter (that counter is a budget signal).
        if (stepIndex > 0) {
          try {
            final learned = await LearnedContextWindows.lookup(
              ctx.providerKey,
              ctx.modelId,
            );
            final catalogCfg = ctx.settings.getProviderConfig(ctx.providerKey);
            final compacted = maybeApplyMidRunCompaction(
              messages,
              measuredPromptTokens: state.agentPromptTokens,
              enabled: ctx.settings.autoCompactionV1,
              modelId: ctx.modelId,
              learnedWindowTokens: learned,
              providerId: catalogCfg.catalogProviderId,
              host: catalogCfg.catalogHost,
            );
            if (compacted) {
              // The measured max belongs to the pre-compaction prompt;
              // keeping it would re-trigger the same projection every round.
              // The next boundary re-estimates from the compacted list.
              state.agentPromptTokens = 0;
            }
          } catch (_) {
            // Compaction is a best-effort projection; never veto the run.
          }
        }
        return true;
      },
      onRoundEnd: (stepIndex, executed) => journal.onRoundEnd(stepIndex),
    );
  }

  /// Revision-loop policy hooks. The revision is a normal agent loop, but it
  /// must not overwrite the main run's checkpoint journal (the main loop has
  /// already finished). Only the approval pause is shared: a tool that lands
  /// in Pending stops the loop before another request, the pending call is
  /// denied (so it cannot execute later for an abandoned revision), and the
  /// driver fail-opens to the original draft.
  stream_ctrl.AgentLoopHooks _buildRevisionHooks(
    stream_ctrl.StreamingState state,
  ) {
    return stream_ctrl.AgentLoopHooks(
      onRoundStart: (stepIndex, messages, tokensSoFar) async {
        if (stepIndex == 0) return true;
        final pending = await _resolvePendingTools(state.messageId);
        // Unknown is not "none": a revision must not dispatch another round
        // while a pending card may still be unresolved.
        if (!pending.isKnown) return false;
        if (!pending.hasPending) return true;
        // The revision is abandoned (the driver fail-opens to the original
        // draft). Deny the pending calls now instead of leaving live approval
        // cards whose approval would execute side effects for a revision that
        // no longer exists.
        for (final tool in pending.tools.where((t) => t.kind == 'approval')) {
          final content = buildApprovalAbortedContent(toolName: tool.name);
          try {
            await chatService.setToolEventApprovalState(
              state.messageId,
              id: tool.id,
              approvalState: approvalStateDenied,
              content: content,
            );
            _refreshToolPart(
              state.messageId,
              tool.id,
              content: content,
              status: kPartStatusDenied,
            );
          } catch (_) {}
        }
        return false;
      },
    );
  }

  /// P0-3 `resumeRun` facade (ADR-A5): re-enter generation from a paused
  /// checkpoint without re-asking the model. The resolved tool result already
  /// lives in the persisted tool events (the approval/answer upsert is the
  /// checkpoint), so the fresh assistant message simply replays the
  /// conversation with the resolved event included — the same mechanism the
  /// approval and ask_user resume paths use today. The facade is kept as the
  /// single resume entry point (its dispatch contract is locked by
  /// approval_lifecycle_test); the timeline card paths call [resolveApproval]
  /// and [resumeAfterAskUserAnswer] directly.
  Future<ChatMessage?> resumeRun(
    String conversationId, {
    String? assistantMessageId,
    String? toolCallId,
    bool approve = false,
    bool alwaysAllow = false,
    Map<String, dynamic>? answerPayload,
  }) async {
    // Never start a second placeholder/request for a conversation that is
    // already generating.
    if (_loadingConversationIds.contains(conversationId)) return null;

    // Dispatch on the pause kind: an approval pending resolves through the
    // approval path; an ask_user pending resolves through the answer path.
    // A bare resume (no toolCallId) just continues generation.
    if (toolCallId != null &&
        assistantMessageId != null &&
        answerPayload != null) {
      final event = _toolEvent(assistantMessageId, toolCallId);
      final content = event?['content']?.toString();
      final isAskUser =
          (event?['name']?.toString() ?? '') == askUserToolName ||
          parseAskUserContent(content)?['type'] == askUserPendingType;
      if (isAskUser) {
        return resumeAfterAskUserAnswer(
          conversationId,
          assistantMessageId,
          toolCallId,
          answerPayload,
        );
      }
      return resolveApproval(
        conversationId,
        assistantMessageId,
        toolCallId,
        approve: approve,
        alwaysAllow: alwaysAllow,
      );
    }
    if (toolCallId != null && assistantMessageId != null) {
      return resolveApproval(
        conversationId,
        assistantMessageId,
        toolCallId,
        approve: approve,
        alwaysAllow: alwaysAllow,
      );
    }
    // Bare resume: continue the paused conversation with a fresh assistant
    // message (same continuation as the resume paths, no tool to resolve).
    final conv = _currentConversation;
    if (conv == null || conv.id != conversationId) return null;
    return _continueAfterApproval(
      conv: conv,
      answeredAssistantMessageId: assistantMessageId ?? '',
    );
  }

  /// Look up a persisted tool event by id.
  Map<String, dynamic>? _toolEvent(String assistantMessageId, String id) {
    try {
      for (final e in chatService.getToolEvents(assistantMessageId)) {
        if ((e['id']?.toString() ?? '') == id) return e;
      }
    } catch (_) {}
    return null;
  }

  /// Live [StreamingState]s by assistant message id. The cancel path needs
  /// the review state to close a card that was interrupted mid-review.
  final Map<String, stream_ctrl.StreamingState> _activeStreamStates =
      <String, stream_ctrl.StreamingState>{};

  /// Execute generation with the given context.
  Future<void> _executeGeneration(
    stream_ctrl.GenerationContext ctx, {
    // Answer Review v1 (docs/answer_review_plan.md): the AI Team aggregator
    // passes `false` — proposals must never be reviewed (§5.2 invariant 11).
    bool enableAnswerReview = true,
  }) async {
    final state = stream_ctrl.StreamingState(ctx);
    _activeStreamStates[state.messageId] = state;
    // Review is streaming-chat-only (§5.2 invariant 12): non-streaming runs
    // and the opt-out callers keep the off config.
    final answerReview = (enableAnswerReview && ctx.streamOutput)
        ? AnswerReviewConfig(mode: ctx.settings.answerReviewMode)
        : const AnswerReviewConfig.off();
    final assistant = ctx.assistant;
    final conversationId = state.conversationId;

    // Mark this message as actively streaming to suppress UI rebuilds
    streamController.markStreamingStarted(state.messageId);

    try {
      // P0-3: generation always runs through the agent-loop kernel driver.
      // The `agent_loop_v1` kill-switch was retired once the kernel path
      // soaked; the transport no longer owns tool execution or follow-ups.
      final stream = _agentOrchestrator.run(
        config: ctx.config,
        modelId: ctx.modelId,
        messages: ctx.apiMessages,
        userImagePaths: ctx.userImagePaths,
        thinkingBudget:
            assistant?.thinkingBudget ?? ctx.settings.thinkingBudget,
        temperature: assistant?.temperature,
        topP: assistant?.topP,
        maxTokens: assistant?.maxTokens,
        tools: ctx.toolDefs.isEmpty ? null : ctx.toolDefs,
        onToolCall: ctx.onToolCall,
        hooks: await _buildPhase1Hooks(state),
        revisionHooks: _buildRevisionHooks(state),
        extraHeaders: ctx.extraHeaders,
        extraBody: ctx.extraBody,
        webFetchEnabled: ctx.settings.webFetchEnabled,
        streamOutput: ctx.streamOutput,
        requestId: conversationId,
        sessionId: conversationId,
        imageAspectRatio: ctx.settings.imageAspectRatio,
        answerReview: answerReview,
      );

      await _conversationStreams[conversationId]?.cancel();
      late final StreamSubscription<ChatStreamChunk> sub;
      sub = stream.listen(
        null,
        onError: (e) {
          unawaited(
            _guardStreamTask(
              () => _handleStreamError(e, state),
              state,
              routeToStreamError: false,
            ),
          );
        },
        onDone: () {
          unawaited(_guardStreamTask(() => _handleStreamDone(state), state));
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

    final isChain = aiTeamConfig.mode == AiTeamMode.chain;

    // Resolve effective prompts: l10n default or user-customized
    final effectiveProposalPrompt = aiTeamConfig.useDefaultProposalPrompt
        ? l10n.aiTeamDefaultProposalPrompt
        : aiTeamConfig.proposalSystemPrompt;
    final effectiveAggregatorPrompt = aiTeamConfig.useDefaultAggregatorPrompt
        ? l10n.aiTeamDefaultAggregatorPrompt
        : aiTeamConfig.aggregatorSystemPrompt;

    final effectiveChainProposerPrompt =
        aiTeamConfig.useDefaultChainProposerPrompt
        ? AiTeamConfigDefaults.defaultChainProposerPrompt
        : aiTeamConfig.chainProposerSystemPrompt;
    final effectiveChainCriticPrompt = aiTeamConfig.useDefaultChainCriticPrompt
        ? AiTeamConfigDefaults.defaultChainCriticPrompt
        : aiTeamConfig.chainCriticSystemPrompt;
    final effectiveChainAggregatorPrompt =
        aiTeamConfig.useDefaultChainAggregatorPrompt
        ? AiTeamConfigDefaults.defaultChainAggregatorPrompt
        : aiTeamConfig.chainAggregatorSystemPrompt;

    _aiTeamCancelled = false;
    _aiTeamInProposalPhase = true;

    // Throttle timestamp for reasoning updates during proposer streaming
    DateTime? lastReasoningUpdate;

    // Run proposers sequentially
    final List<Map<String, dynamic>> proposals = [];
    final activeChainModels = isChain ? aiTeamConfig.activeChainModels : [];
    final activeProposers = isChain
        ? activeChainModels
        : aiTeamConfig.activeProposers;
    final totalSteps = activeProposers.length;

    for (var idx = 0; idx < totalSteps; idx++) {
      final slot = activeProposers[idx];
      if (_aiTeamCancelled) break;

      // Labeling and Progress Text
      String label;
      String progressText;
      if (isChain) {
        if (idx == 0) {
          label = l10n.aiTeamProposerModels;
          progressText = l10n.aiTeamProposalInProgress(1, 1);
        } else {
          label = l10n.aiTeamCriticLabel(idx);
          try {
            progressText = l10n.aiTeamCriticInProgress(idx, totalSteps - 1);
          } catch (_) {
            progressText = 'AI Team running… Critic $idx/${totalSteps - 1}';
          }
        }
      } else {
        label = l10n.aiTeamProposalLabel(idx + 1);
        progressText = l10n.aiTeamProposalInProgress(idx + 1, totalSteps);
      }

      // Push progress text to streaming UI
      streamController.streamingContentNotifier.updateContent(
        messageId,
        progressText,
        0,
      );
      // Sync pending stream content so the throttle timer doesn't overwrite with stale data
      // from a previous proposer
      streamController.setPendingStreamContent(messageId, progressText);

      // Build message list for this step
      List<Map<String, dynamic>> stepMessages;
      if (isChain) {
        if (idx == 0) {
          stepMessages = _cloneForProposer(
            baseApiMessages,
            effectiveChainProposerPrompt,
          );
        } else {
          stepMessages = _buildChainCriticMessages(
            baseApiMessages,
            proposals,
            effectiveChainCriticPrompt,
          );
        }
      } else {
        stepMessages = _cloneForProposer(
          baseApiMessages,
          effectiveProposalPrompt,
        );
      }

      final propConfig = ctx.settings.getProviderConfig(slot.providerKey);

      // Check if proposer model supports reasoning
      final propSupportsReasoning = _isReasoningModel(
        slot.providerKey,
        slot.modelId,
      );
      final propBudget = propSupportsReasoning
          ? (ctx.assistant?.thinkingBudget ?? ctx.settings.thinkingBudget)
          : 0;

      Map<String, dynamic> proposerResult;
      try {
        proposerResult = await _runProposerSilent(
          conversationId: conversationId,
          config: propConfig,
          modelId: slot.modelId,
          apiMessages: stepMessages,
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
          onPartialContent: ctx.streamOutput
              ? (content, reasoning, reasoningStartAt) {
                  // Push streaming content to main content area (throttled 60ms)
                  streamController.scheduleThrottledUpdate(
                    messageId,
                    conversationId,
                    content,
                    totalTokens: 0,
                    updateMessageInList: (id, c, tokens) {
                      onContentUpdated?.call(id, c, tokens);
                    },
                  );
                  // Push reasoning (throttled to ~60ms)
                  if (reasoning.isNotEmpty) {
                    final now = DateTime.now();
                    if (lastReasoningUpdate == null ||
                        now.difference(lastReasoningUpdate!) >=
                            const Duration(milliseconds: 60)) {
                      lastReasoningUpdate = now;
                      streamController.streamingContentNotifier.updateReasoning(
                        messageId,
                        reasoningText: reasoning,
                        reasoningStartAt: reasoningStartAt,
                      );
                    }
                  }
                }
              : null,
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
        'label': label,
      });

      // Push partial proposals to streaming UI for real-time display
      final partialJson = jsonEncode(proposals);
      streamController.streamingContentNotifier.updateProposals(
        messageId,
        partialJson,
      );
      await chatService.updateMessageSilent(
        messageId,
        aiTeamProposalsJson: partialJson,
      );
      final mIdx = _messages.indexWhere((m) => m.id == messageId);
      if (mIdx != -1) {
        _messages[mIdx] = _messages[mIdx].copyWith(
          aiTeamProposalsJson: partialJson,
        );
      }
    }

    _aiTeamInProposalPhase = false;

    // Clear progress text before aggregator starts
    streamController.streamingContentNotifier.updateContent(messageId, '', 0);
    // Clear pending stream content so throttle timer doesn't push stale proposer content
    streamController.setPendingStreamContent(messageId, '');

    // If cancelled or all proposals empty, show stopped
    if (_aiTeamCancelled ||
        proposals.every((p) => (p['content'] as String).isEmpty)) {
      await _handleAiTeamStopped(ctx.assistantMessage, proposals);
      return;
    }

    // Build aggregator apiMessages with proposals injected
    final aggMessages = isChain
        ? _buildChainAggregatorMessages(
            baseApiMessages,
            proposals,
            effectiveChainCriticPrompt,
            effectiveChainAggregatorPrompt,
          )
        : _buildAggregatorMessages(
            baseApiMessages,
            proposals,
            effectiveAggregatorPrompt,
            l10n.aiTeamAggregatorUserPrompt,
          );

    // Store pending proposals for persistence after aggregator finishes
    _aiTeamPendingProposals[messageId] = jsonEncode(proposals);

    // Build aggregator context (aggregator can also use tools)
    final aggCtx = stream_ctrl.GenerationContext(
      assistantMessage: ctx.assistantMessage,
      apiMessages: aggMessages,
      userImagePaths: ctx.userImagePaths,
      providerKey: ctx.providerKey,
      modelId: ctx.modelId,
      assistant: ctx.assistant,
      settings: ctx.settings,
      config: ctx.config,
      toolDefs: ctx.toolDefs,
      onToolCall: ctx.onToolCall,
      extraHeaders: ctx.extraHeaders,
      extraBody: ctx.extraBody,
      supportsReasoning: ctx.supportsReasoning,
      enableReasoning: ctx.enableReasoning,
      streamOutput: ctx.streamOutput,
      generateTitleOnFinish: ctx.generateTitleOnFinish,
    );

    // Execute aggregator generation (standard flow, subscription registered in _conversationStreams per K1)
    await _executeGeneration(aggCtx, enableAnswerReview: false);
  }

  /// Run a single proposer silently (no UI push), return map with content/reasoning/toolCalls.
  /// R1: Uses Future.any to race stream completion vs cancel signal to prevent deadlock.
  /// [onPartialContent]: optional callback fired (unthrottled) on each chunk with current
  /// buffered content and reasoning. The caller is responsible for throttling UI updates.
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
    ToolCallHandler? onToolCall,
    Map<String, String>? extraHeaders,
    Map<String, dynamic>? extraBody,
    required bool streamOutput,
    void Function(String content, String reasoning, DateTime? reasoningStartAt)?
    onPartialContent,
  }) async {
    final completer = Completer<Map<String, dynamic>>();
    final buffer = StringBuffer();
    final reasoningBuffer = StringBuffer();
    final toolCallsList = <Map<String, dynamic>>[];
    final toolResultsMap = <String, String>{};
    _aiTeamCancelCompleter = Completer<void>();
    DateTime? reasoningStartAt;

    // P0-3: proposers run through the kernel driver; the transport is
    // single-round only and no longer executes tools itself.
    final stream = _agentOrchestrator.run(
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
      streamOutput: streamOutput,
      requestId: '${conversationId}_proposer',
      sessionId: conversationId,
    );

    final proposerSub = stream.listen(
      (chunk) {
        if (chunk.content.isNotEmpty) {
          buffer.write(chunk.content);
        }
        if ((chunk.reasoning ?? '').isNotEmpty) {
          reasoningBuffer.write(chunk.reasoning);
          reasoningStartAt ??= DateTime.now();
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
        // Push partial content to caller for real-time UI display
        if (onPartialContent != null &&
            (buffer.isNotEmpty || reasoningBuffer.isNotEmpty)) {
          onPartialContent(
            buffer.toString(),
            reasoningBuffer.toString(),
            reasoningStartAt,
          );
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
        _aiTeamCancelCompleter!.future.then(
          (_) => {
            'content': '',
            'reasoning': '',
            'toolCalls': <Map<String, dynamic>>[],
          },
        ),
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
      cloned.insert(0, {'role': 'system', 'content': aggregatorSystemPrompt});
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
        'content':
            '=== Proposal ${i + 1} ($providerKey/$modelId) ===\n$content',
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

  /// Build chain critic messages: append proposer output and preceding critic outputs
  /// separated by the self-audit critic prompt.
  List<Map<String, dynamic>> _buildChainCriticMessages(
    List<Map<String, dynamic>> baseApiMessages,
    List<Map<String, dynamic>> proposals,
    String criticPrompt,
  ) {
    final cloned = baseApiMessages
        .map((m) => Map<String, dynamic>.from(m))
        .toList(growable: true);

    for (var i = 0; i < proposals.length; i++) {
      final p = proposals[i];
      final content = p['content'] as String? ?? '';
      if (content.trim().isEmpty) continue;
      cloned.add({'role': 'assistant', 'content': content});
      cloned.add({'role': 'user', 'content': criticPrompt});
    }

    return cloned;
  }

  /// Build chain aggregator messages: append proposer + critic outputs and final synthesis prompt.
  List<Map<String, dynamic>> _buildChainAggregatorMessages(
    List<Map<String, dynamic>> baseApiMessages,
    List<Map<String, dynamic>> proposals,
    String criticPrompt,
    String aggregatorPrompt,
  ) {
    final cloned = baseApiMessages
        .map((m) => Map<String, dynamic>.from(m))
        .toList(growable: true);

    final validProposals = proposals
        .where((p) => (p['content'] as String? ?? '').trim().isNotEmpty)
        .toList(growable: false);

    for (var i = 0; i < validProposals.length; i++) {
      final p = validProposals[i];
      final content = p['content'] as String? ?? '';
      cloned.add({'role': 'assistant', 'content': content});
      if (i < validProposals.length - 1) {
        cloned.add({'role': 'user', 'content': criticPrompt});
      }
    }

    cloned.add({'role': 'user', 'content': aggregatorPrompt});

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
    final hasNonEmpty = proposals.any(
      (p) => (p['content'] as String).isNotEmpty,
    );
    if (hasNonEmpty) {
      proposalsJson = jsonEncode(proposals);
    }
    _aiTeamPendingProposals.remove(assistantMessage.id);

    streamController.markStreamingEnded(assistantMessage.id);
    // Cancel the proposer-phase throttle timer to prevent it from
    // overwriting message.content after cancel (Bug Fix 2)
    streamController.cleanupTimers(assistantMessage.id);
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
    ChatStreamChunk chunk,
    stream_ctrl.StreamingState state,
  ) async {
    // Retry / silent-interrupt status chunk. Surfaces a "正在重試 1/3…"
    // snackbar to the user, and clears any partial content the previous
    // attempt had pushed to the UI so the new attempt's content starts
    // from a blank slate (avoids the "double text" visual glitch when
    // the second attempt streams overlapping content).
    if (chunk.errorKind != null && chunk.attempt != null) {
      // Stash the retry attempt on StreamingState so the message
      // bubble can render a live "重試中… 1/3" indicator alongside
      // (or in lieu of) the snackbar. Snackbars are easy to miss
      // when the terminal error replaces them within seconds.
      state.retryAttempt = chunk.attempt;
      state.retriesExhausted = false;
      // Push the retry status to the streaming notifier *before*
      // clearing the partial content, so the message bubble can
      // briefly show the indicator plus a faint preview of the
      // previous attempt's content (this is intentional — it makes
      // it obvious to the user that the system already tried once).
      streamController.streamingContentNotifier.updateRetryStatus(
        state.messageId,
        stream_ctrl.RetryStatus(
          attempt: chunk.attempt!,
          maxAttempts: chunk.maxAttempts ?? 3,
          isSilentInterrupt: chunk.errorKind == 'silent_interrupt_retry',
        ),
      );
      onStreamRetry?.call(
        chunk.attempt!,
        chunk.maxAttempts ?? 3,
        chunk.errorKind!,
        state.conversationId,
      );
      _resetStreamForRetry(state);
      return;
    }

    // Answer Review v1 status chunk (reviewing / revising /
    // revision_failed). Routed away from the content accumulator — status
    // chunks never carry content (§9.3).
    if (chunk.reviewPhase != null) {
      await _handleReviewPhaseChunk(chunk, state);
      return;
    }

    final chunkContent = chunk.content.isNotEmpty
        ? streamController.captureGeminiThoughtSignature(
            chunk.content,
            state.messageId,
          )
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

    // P0-5: a soft stop (max steps / token budget) surfaces as a localized
    // footnote on the finished bubble so the user understands the run ended
    // by policy, not by failure, and can continue with another message.
    if ((chunk.softStopReason ?? '').isNotEmpty) {
      state.softStopReason = chunk.softStopReason;
    }

    // Handle finish or content
    if (chunk.isDone) {
      await _handleStreamFinish(chunk, state, chunkContent);
    } else {
      await _handleContentChunk(chunk, state, chunkContent);
    }
  }

  /// Answer Review v1 status chunk handler (§9.3): switches the review
  /// card and, on `revising`, backs up + clears the on-screen draft.
  /// Usage / totalTokens / tool cards are intentionally untouched.
  Future<void> _handleReviewPhaseChunk(
    ChatStreamChunk chunk,
    stream_ctrl.StreamingState state,
  ) async {
    final phase = chunk.reviewPhase!;
    final messageId = state.messageId;
    final notifier = streamController.streamingContentNotifier;
    switch (phase) {
      case kReviewPhaseReviewing:
        final draft = _transformAssistantContent(state);
        state.answerReview.beginReviewing(
          draft: draft,
          at: DateTime.now(),
          report: chunk.reviewReport,
        );
        notifier.updateAnswerReview(
          messageId,
          phase: AnswerReviewPhase.reviewing,
          report: chunk.reviewReport,
          draft: draft,
        );
        await _persistAnswerReview(
          state,
          status: kPartStatusPending,
          report: chunk.reviewReport ?? const AnswerReviewReport(),
          draft: draft,
        );
        break;
      case kReviewPhaseReviewed:
        final report = chunk.reviewReport ?? state.answerReview.report;
        if (report == null) break;
        state.answerReview.applyReport(report);
        notifier.updateAnswerReview(
          messageId,
          phase: report.phase,
          report: report,
          draft: state.answerReview.draftForCard,
        );
        await _persistAnswerReview(
          state,
          status: _reviewStatusForPhase(report.phase),
          report: report,
        );
        break;
      case kReviewPhaseRevising:
        // Back up the draft BEFORE anything clears it so a cancel / error
        // mid-revision can restore what the user saw.
        state.answerReview.beginRevision(state.fullContentRaw);
        // The revised text replaces the draft: a signature captured from the
        // draft no longer matches the new text, and the throttle timer must
        // not race with the revision's content writes.
        streamController.clearGeminiThoughtSignature(messageId);
        streamController.cancelThrottleTimer(messageId);
        state.fullContentRaw = '';
        final revisingReport = (chunk.reviewReport ?? state.answerReview.report)
            ?.copyWith(phase: AnswerReviewPhase.revising, reviewed: false);
        if (revisingReport != null) {
          state.answerReview.applyReport(revisingReport);
          notifier.updateAnswerReview(
            messageId,
            phase: AnswerReviewPhase.revising,
            report: revisingReport,
            draft: state.answerReview.draftForCard,
          );
          await _persistAnswerReview(
            state,
            status: kPartStatusPending,
            report: revisingReport,
          );
        }
        // DB and `_messages` keep the draft during the revision (§9.4): a
        // cancel or crash must never lose the original answer in favor of a
        // half-revised stream. Only the live notifier shows the revision.
        notifier.updateContent(messageId, '', state.totalTokens);
        break;
      case kReviewPhaseRevisionFailed:
        final report = chunk.reviewReport ?? state.answerReview.report;
        state.answerReview.markRevisionFailed(report);
        notifier.updateAnswerReview(
          messageId,
          phase: AnswerReviewPhase.revisionFailed,
          report: report,
          draft: state.answerReview.draftForCard,
        );
        if (report != null) {
          await _persistAnswerReview(
            state,
            status: kPartStatusInterrupted,
            report: report,
          );
        }
        break;
    }
  }

  String _reviewStatusForPhase(String phase) => switch (phase) {
    AnswerReviewPhase.passed ||
    AnswerReviewPhase.revised => kPartStatusCompleted,
    AnswerReviewPhase.reviewing ||
    AnswerReviewPhase.revising => kPartStatusPending,
    _ => kPartStatusInterrupted,
  };

  /// Best-effort persistence for the review card. A failure must never block
  /// the answer from finishing; the live card remains usable.
  Future<void> _persistAnswerReview(
    stream_ctrl.StreamingState state, {
    required String status,
    required AnswerReviewReport report,
    String? draft,
  }) async {
    try {
      await chatService.upsertAnswerReview(
        messageId: state.messageId,
        report: report,
        status: status,
        draft: draft,
      );
      final record = chatService.getAnswerReview(state.messageId);
      if (record != null) {
        streamController.setAnswerReview(state.messageId, record);
      }
    } catch (e) {
      FlutterLogger.log(
        'answer_review.persist_failed messageId=${state.messageId} error=$e',
        tag: 'answer_review',
      );
    }
  }

  /// Close a review card whose run was cancelled / errored / lost its
  /// terminal. Persists `interrupted` and clears the live phase without
  /// touching the answer content (the caller owns the draft restore).
  Future<void> _finalizeReviewOnAbort(
    stream_ctrl.StreamingState state, {
    required bool cancelled,
  }) async {
    final existing = state.answerReview.report;
    if (state.answerReview.phase == null && existing == null) {
      _activeStreamStates.remove(state.messageId);
      return;
    }
    // A late error/onDone/cancel must never downgrade a review that already
    // reached a terminal phase (the answer was delivered and persisted).
    if (existing?.isTerminal == true) {
      _activeStreamStates.remove(state.messageId);
      return;
    }

    final restoredAfterRevision =
        !cancelled &&
        state.answerReview.phase == AnswerReviewPhase.revisionFailed;
    if (cancelled) {
      state.answerReview.markCancelled();
    } else if (restoredAfterRevision && existing != null) {
      // The stream ended after `takeDraftForRestore()`: keep the semantic
      // "revision failed, original kept" state instead of a generic abort.
      state.answerReview.applyReport(
        existing.copyWith(
          phase: AnswerReviewPhase.revisionFailed,
          reviewed: false,
          failReason: existing.failReason ?? 'revision_failed',
          finishedAtMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    } else {
      state.answerReview.markInterrupted();
    }
    final report = state.answerReview.report;
    if (report != null) {
      await _persistAnswerReview(
        state,
        status: kPartStatusInterrupted,
        report: report,
        draft: state.answerReview.draftForCard,
      );
      streamController.streamingContentNotifier.updateAnswerReview(
        state.messageId,
        clearPhase: true,
        report: report,
        draft: state.answerReview.draftForCard,
      );
    }
    _activeStreamStates.remove(state.messageId);
  }

  /// Restore the backed-up draft when a run ends (done / error) mid-revision
  /// (§9.6). The normal terminal path clears the backup via `finish()` and
  /// needs no restore.
  void _restoreReviewDraftIfNeeded(stream_ctrl.StreamingState state) {
    if (!state.answerReview.needsDraftRestore) return;
    final draft = state.answerReview.takeDraftForRestore();
    state.fullContentRaw = draft;
    // Display the processed form (assistant regexes), keep the raw text in
    // `fullContentRaw` — `_finishStreaming` re-processes it for persistence.
    streamController.streamingContentNotifier.updateContent(
      state.messageId,
      _transformAssistantContent(state, draft),
      state.totalTokens,
    );
  }

  /// Reset the streaming UI / throttle state in preparation for a fresh
  /// L1 retry attempt. Called when a `transient_retry` /
  /// `silent_interrupt_retry` status chunk arrives so the next attempt's
  /// content appears on a blank bubble instead of being appended to the
  /// already-streamed text (which would look like duplicated output).
  ///
  /// Does NOT touch reasoning / tool state — those are scoped to a
  /// single attempt's response and will be re-emitted by the new
  /// attempt if the model decides to use them again.
  void _resetStreamForRetry(stream_ctrl.StreamingState state) {
    final messageId = state.messageId;
    // The retry regenerates the whole answer; a signature captured from the
    // failed attempt no longer matches the new text and must not be replayed.
    streamController.clearGeminiThoughtSignature(messageId);
    state.fullContentRaw = '';
    state.totalTokens = 0;
    state.usage = null;
    // Cancel the throttle timer for this message so the next attempt
    // re-creates it. Leaving the old timer running would race with the
    // new attempt's content writes.
    streamController.cancelThrottleTimer(messageId);
    // Push the empty state to the UI immediately so the bubble clears
    // before the new attempt's chunks start arriving.
    streamController.streamingContentNotifier.updateContent(messageId, '', 0);
  }

  /// Handle reasoning chunk from stream.
  Future<void> _handleReasoningChunk(
    ChatStreamChunk chunk,
    stream_ctrl.StreamingState state,
  ) async {
    await streamController.handleReasoningChunk(
      chunk,
      state,
      updateReasoningInDb:
          (
            String messageId, {
            String? reasoningText,
            DateTime? reasoningStartAt,
            DateTime? processStartedAt,
            String? reasoningSegmentsJson,
          }) async {
            // Use silent update during streaming to avoid UI rebuilds
            await chatService.updateMessageSilent(
              messageId,
              reasoningText: reasoningText,
              reasoningStartAt: reasoningStartAt,
              processStartedAt: processStartedAt,
              reasoningSegmentsJson: reasoningSegmentsJson,
            );
          },
    );
  }

  /// Handle tool calls chunk from stream.
  Future<void> _handleToolCallsChunk(
    ChatStreamChunk chunk,
    stream_ctrl.StreamingState state,
  ) async {
    await streamController.handleToolCallsChunk(
      chunk,
      state,
      // 過程收褶: a tool call can open the turn (tool-only models, tool-first
      // agent loops), so the process start anchor is persisted from here too.
      updateReasoningInDb:
          (String messageId, {DateTime? processStartedAt}) async {
            await chatService.updateMessageSilent(
              messageId,
              processStartedAt: processStartedAt,
            );
          },
      updateReasoningSegmentsInDb: (String messageId, String json) async {
        // Use silent update during streaming to avoid UI rebuilds
        await chatService.updateMessageSilent(
          messageId,
          reasoningSegmentsJson: json,
        );
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
    ChatStreamChunk chunk,
    stream_ctrl.StreamingState state,
  ) async {
    await streamController.handleToolResultsChunk(
      chunk,
      state,
      upsertToolEventInDb:
          (
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
              // P1-3 (2026-09-11): reasoning-echo fields are persisted at
              // tool-CALL time — stream_controller.handleToolCallsChunk
              // writes the round's assistantExtras onto the placeholder
              // event — and survive this result upsert through
              // ChatService.upsertToolEvent's existing-extras merge
              // (preservedToolEventExtraKeys). Tool-RESULT chunks never
              // carry assistantExtras; the v1.8 attempt read them here,
              // which was dead code and never persisted anything.
            );
          },
      // 過程收褶: persist the process-group end stamp when the last tool
      // result of a round closes the group (frozen header timer).
      updateReasoningInDb:
          (String messageId, {DateTime? processFinishedAt}) async {
            await chatService.updateMessageSilent(
              messageId,
              processFinishedAt: processFinishedAt,
            );
          },
      // UI-only extras (search provider trace) hydrate the live tool card.
      getToolEventsFromDb: (String messageId) =>
          chatService.getToolEvents(messageId),
    );
    // The tool event write completed inside the callback above; only now is
    // the tool-result boundary durable enough to advance the journal. The
    // journal writes immediately only when a pending card appears (or is
    // resolved); ordinary results are batched into onRoundEnd so a tool-heavy
    // round does not flush the box once per call.
    await state.agentJournal?.onToolResults();
  }

  /// Handle content chunk from stream (non-done).
  Future<void> _handleContentChunk(
    ChatStreamChunk chunk,
    stream_ctrl.StreamingState state,
    String chunkContent,
  ) async {
    final messageId = state.messageId;
    final conversationId = state.conversationId;

    // Answer Review v1 (§9.4): while any review phase is active — revising,
    // and also the post-`revision_failed` draft restore — the DB and
    // `_messages` keep the original draft; only `fullContentRaw` and the
    // live notifier advance. A cancel / crash mid-revision therefore always
    // persists the draft, never a half-revised answer.
    final reviewPhaseActive = state.answerReview.phase != null;

    if (chunk.replaceContent) {
      // Fail-open draft restore (or defensive whole-text replacement):
      // replace instead of append, and reset the signature / throttle state
      // so the restored text is not polluted by revision-era captures.
      state.fullContentRaw = chunkContent;
      streamController.clearGeminiThoughtSignature(state.messageId);
      streamController.cancelThrottleTimer(state.messageId);
    } else {
      state.fullContentRaw += chunkContent;
    }
    // Clear the retry indicator as soon as the new attempt starts
    // streaming real content. Otherwise the "重試中… 1/3" badge would
    // persist on top of the response, confusing the user.
    if (state.retryAttempt != null) {
      state.retryAttempt = null;
      streamController.streamingContentNotifier.updateRetryStatus(
        messageId,
        null,
      );
    }
    if (chunk.totalTokens > 0) {
      state.totalTokens = chunk.totalTokens;
    }
    if (chunk.usage != null) {
      state.usage = (state.usage ?? const TokenUsage()).merge(chunk.usage!);
      state.totalTokens = state.usage!.totalTokens;
      final promptTokens = chunk.usage!.promptTokens;
      if (promptTokens > state.agentPromptTokens) {
        state.agentPromptTokens = promptTokens;
      }
      final usageMeta = chunk.usage!.toMessageUsage();
      if (usageMeta != null && !reviewPhaseActive) {
        final index = _messages.indexWhere((m) => m.id == state.messageId);
        if (index != -1) {
          _messages[index] = _messages[index].copyWith(
            usageMetaJson: jsonEncode(usageMeta.toJson()),
          );
        }
      }
    }

    String streamingProcessed = _transformAssistantContent(state);
    if (!reviewPhaseActive) {
      if (streamingProcessed.contains('data:image') &&
          streamingProcessed.contains('base64,')) {
        try {
          final sanitized =
              await MarkdownMediaSanitizer.replaceInlineBase64Images(
                streamingProcessed,
              );
          if (sanitized != streamingProcessed) {
            streamingProcessed = sanitized;
            state.fullContentRaw = sanitized;
          }
        } catch (e) {
          // ignore
        }
      }
      onScheduleImageSanitize?.call(
        messageId,
        streamingProcessed,
        immediate: true,
      );
      // Use silent update to avoid triggering ChatService.notifyListeners()
      // which would cause side_drawer and other widgets to rebuild
      await chatService.updateMessageSilent(
        messageId,
        content: streamingProcessed,
        totalTokens: state.totalTokens,
        promptTokens: state.usage?.promptTokens,
        completionTokens: state.usage?.completionTokens,
        cachedTokens: state.usage?.cachedTokens,
      );

      if (state.ctx.streamOutput &&
          _currentConversation?.id == conversationId) {
        final index = _messages.indexWhere((m) => m.id == messageId);
        if (index != -1) {
          _messages[index] = _messages[index].copyWith(
            content: streamingProcessed,
            totalTokens: state.totalTokens,
            promptTokens: state.usage?.promptTokens,
            completionTokens: state.usage?.completionTokens,
            cachedTokens: state.usage?.cachedTokens,
          );
          // NOTE: Do NOT call onMessagesChanged here!
          // Streaming content updates are handled by StreamingContentNotifier
          // via ValueListenableBuilder, which only rebuilds the streaming message widget.
          // Calling onMessagesChanged would trigger a full page rebuild and cause lag.
        }
      }
    }

    // End reasoning when content starts (never during the review phases —
    // the reasoning timeline belongs to the main run, not the rewrite).
    if (state.ctx.streamOutput &&
        chunkContent.isNotEmpty &&
        !reviewPhaseActive) {
      await _finishReasoningOnContent(state);
    }

    // Schedule throttled UI update via StreamController
    if (state.ctx.streamOutput) {
      if (reviewPhaseActive) {
        // Live notifier only: no throttle timer, no `onContentUpdated`
        // (conversation-list) writes during the revision (§9.4).
        streamController.streamingContentNotifier.updateContent(
          messageId,
          streamingProcessed,
          state.totalTokens,
        );
      } else {
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
  }

  /// Finish reasoning segment when content starts arriving.
  Future<void> _finishReasoningOnContent(
    stream_ctrl.StreamingState state,
  ) async {
    await streamController.finishReasoningAndPersist(
      state.messageId,
      updateReasoningInDb:
          (
            String messageId, {
            String? reasoningText,
            DateTime? reasoningFinishedAt,
            DateTime? processFinishedAt,
            DateTime? processStartedAt,
            String? reasoningSegmentsJson,
          }) async {
            // Use silent update during streaming to avoid UI rebuilds
            await chatService.updateMessageSilent(
              messageId,
              reasoningText: reasoningText,
              reasoningFinishedAt: reasoningFinishedAt,
              processFinishedAt: processFinishedAt,
              processStartedAt: processStartedAt,
              reasoningSegmentsJson: reasoningSegmentsJson,
            );
          },
    );
  }

  /// Handle stream finish (isDone == true).
  Future<void> _handleStreamFinish(
    ChatStreamChunk chunk,
    stream_ctrl.StreamingState state,
    String chunkContent,
  ) async {
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

    final terminalTotal = chunk.totalTokens;
    if (terminalTotal > 0) {
      state.totalTokens = math.max(state.totalTokens, terminalTotal);
    }
    if (chunk.usage != null) {
      state.usage = (state.usage ?? const TokenUsage()).merge(chunk.usage!);
      // TokenUsage.merge() recomputes totalTokens as prompt + completion.
      // The driver's terminal carries the multi-round cumulative (and, with
      // the answer review, the review-summed usage) — keep the largest of
      // the observed values instead of letting the merge shrink it (§9.5).
      state.totalTokens = math.max(
        math.max(state.totalTokens, terminalTotal),
        state.usage!.totalTokens,
      );
      final promptTokens = chunk.usage!.promptTokens;
      if (promptTokens > state.agentPromptTokens) {
        state.agentPromptTokens = promptTokens;
      }
      final usageMeta = chunk.usage!.toMessageUsage();
      if (usageMeta != null) {
        final index = _messages.indexWhere((m) => m.id == state.messageId);
        if (index != -1) {
          _messages[index] = _messages[index].copyWith(
            usageMetaJson: jsonEncode(usageMeta.toJson()),
          );
        }
      }
    }

    // Answer Review v1 (§9.5): fold the terminal's review outcome in and
    // persist the final card before the live state is torn down.
    // `reviewUsage` is the additive subset of `chunk.usage` — recorded for
    // display only, never re-added.
    final finalReport = chunk.reviewReport ?? state.answerReview.report;
    final normalizedReport =
        finalReport != null &&
            !AnswerReviewPhase.terminal.contains(finalReport.phase)
        ? finalReport.copyWith(
            phase: AnswerReviewPhase.interrupted,
            reviewed: false,
            failReason: finalReport.failReason ?? 'interrupted',
            finishedAtMs: DateTime.now().millisecondsSinceEpoch,
          )
        : finalReport;
    state.answerReview.finish(
      reviewed: chunk.reviewed,
      reviewTokens: chunk.reviewUsage?.totalTokens ?? 0,
      report: normalizedReport,
      finalPhase: normalizedReport?.phase,
    );
    state.reviewTokens = chunk.reviewUsage?.totalTokens ?? 0;
    if (normalizedReport != null) {
      await _persistAnswerReview(
        state,
        status: _reviewStatusForPhase(normalizedReport.phase),
        report: normalizedReport,
        draft: state.answerReview.draftForCard,
      );
      streamController.streamingContentNotifier.updateAnswerReview(
        messageId,
        clearPhase: true,
        report: normalizedReport,
        draft: state.answerReview.draftForCard,
      );
    } else {
      streamController.streamingContentNotifier.updateReviewPhase(
        messageId,
        null,
      );
    }
    _activeStreamStates.remove(messageId);

    await _finishStreaming(state);
    await _finishRunJournal(state);

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
      final autoCollapse = contextProvider
          .read<SettingsProvider>()
          .autoCollapseThinking;
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
  Future<void> _finishStreaming(
    stream_ctrl.StreamingState state, {
    bool generateTitle = true,
  }) async {
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
    // P0-5: append the localized soft-stop footnote (max steps / token
    // budget) to the persisted bubble so the stop reason outlives the
    // session — same convention as the streamInterruptedNote on errors.
    var sanitizedContent =
        await MarkdownMediaSanitizer.replaceInlineBase64Images(
          processedContent,
        );
    final softStop = state.softStopReason;
    if (softStop != null && softStop.isNotEmpty) {
      final l10n = AppLocalizations.of(contextProvider);
      final note = softStop == 'max_steps'
          ? (l10n?.softStopMaxStepsNote ??
                'The run reached its step limit and stopped; send a message to continue.')
          : (l10n?.softStopTokenBudgetNote ??
                'The run reached its token budget and stopped; send a message to continue.');
      if (sanitizedContent.isNotEmpty) {
        sanitizedContent = '$sanitizedContent\n\n$note';
      } else {
        sanitizedContent = note;
      }
    }
    // Extract pending AI Team proposals for persistence
    final pendingProposals = _aiTeamPendingProposals.remove(messageId);
    final usageMeta = state.usage?.toMessageUsage();
    await chatService.updateMessage(
      messageId,
      content: sanitizedContent,
      totalTokens: state.totalTokens,
      promptTokens: state.usage?.promptTokens,
      completionTokens: state.usage?.completionTokens,
      cachedTokens: state.usage?.cachedTokens,
      isStreaming: false,
      aiTeamProposalsJson: pendingProposals,
      usageMeta: usageMeta,
    );

    final index = _messages.indexWhere((m) => m.id == messageId);
    if (index != -1) {
      _messages[index] = _messages[index].copyWith(
        content: sanitizedContent,
        totalTokens: state.totalTokens,
        promptTokens: state.usage?.promptTokens,
        completionTokens: state.usage?.completionTokens,
        cachedTokens: state.usage?.cachedTokens,
        isStreaming: false,
        aiTeamProposalsJson: pendingProposals,
        usageMetaJson: usageMeta == null
            ? _messages[index].usageMetaJson
            : jsonEncode(usageMeta.toJson()),
      );
      onMessagesChanged?.call();
    }
    _setConversationLoading(conversationId, false);

    // Use unified reasoning completion method
    await streamController.finishReasoningAndPersist(
      messageId,
      updateReasoningInDb:
          (
            String messageId, {
            String? reasoningText,
            DateTime? reasoningFinishedAt,
            DateTime? processFinishedAt,
            DateTime? processStartedAt,
            String? reasoningSegmentsJson,
          }) async {
            await chatService.updateMessage(
              messageId,
              reasoningText: reasoningText,
              reasoningFinishedAt: reasoningFinishedAt,
              processFinishedAt: processFinishedAt,
              processStartedAt: processStartedAt,
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
  ///
  /// Preserves the partial content the user has already seen when a
  /// transient / silent-interrupt error has exhausted its retry budget:
  /// instead of overwriting the assistant bubble with the raw error
  /// string, we keep [StreamingState.fullContentRaw] and append a short
  /// note explaining why the stream stopped. For terminal (4xx, auth,
  /// parse) errors with no prior content, the legacy behaviour of
  /// showing the raw error text is preserved.
  Future<void> _handleStreamError(
    dynamic e,
    stream_ctrl.StreamingState state,
  ) async {
    final messageId = state.messageId;
    final conversationId = state.conversationId;
    final l10n = AppLocalizations.of(contextProvider);
    // Only an auth failure of this account may turn the turn into the recovery
    // flow. The classifier also covers the second-401 shape, which the wrapper
    // returns after marking the account (the transport then throws HttpException
    // rather than OAuthException) — see oauth_failure.dart (plan C3).
    final bool oauthLoginRequired = isOAuthLoginRequiredFailure(
      config: state.ctx.config,
      error: e,
      accountFlagged: oauthService.isLoginRequired(state.ctx.config.id),
    );
    // Never dump raw OAuth text (English, provider-shaped) into the bubble:
    // the recovery card under the message owns the sign-in UX (plan M4/C16).
    final String oauthNotice =
        l10n?.oauthChatRecoveryNotice ??
        'This turn stopped because the account needed to sign in again.';
    final bool oauthDisabled = e is OAuthDisabledException;
    final bool isOpenCode = isOpenCodeBaseUrl(state.ctx.config.baseUrl);
    final OpenCodeErrorKind openCodeErrorKind = isOpenCode
        ? classifyOpenCodeError(e)
        : OpenCodeErrorKind.none;
    final String? openCodeNotice = switch (openCodeErrorKind) {
      OpenCodeErrorKind.missingSession => l10n?.openCodeErrorMissingSession,
      OpenCodeErrorKind.freeTier => l10n?.openCodeErrorFreeTier,
      OpenCodeErrorKind.insufficientBalance =>
        l10n?.openCodeErrorInsufficientBalance,
      OpenCodeErrorKind.protocolUnsupported =>
        l10n?.openCodeErrorProtocolUnsupported,
      OpenCodeErrorKind.none => null,
    };
    final errorText = oauthLoginRequired
        ? oauthNotice
        : oauthDisabled
        ? (l10n?.oauthDisabledNotice ?? e.toString())
        : (openCodeNotice ?? e.toString());
    final isRetriesExhausted =
        e is TransientStreamError && e.isRetriesExhausted;

    // Answer Review v1 (§9.6): restore the backed-up draft BEFORE the error
    // message is composed so the note is appended to the original answer,
    // not to a half-revised stream.
    _restoreReviewDraftIfNeeded(state);
    await _finalizeReviewOnAbort(state, cancelled: false);

    // Mark streaming as ended to allow UI rebuilds again
    streamController.markStreamingEnded(messageId);

    streamController.cleanupTimers(messageId);

    // Decide what to write into the message bubble. When the L1 retry
    // budget was spent and we have partial content, keep it; otherwise
    // fall back to the legacy behaviour (rawContent or errorText).
    final String displayContent;
    if (oauthLoginRequired) {
      // Both the message bubble and the card are driven by the failure; the
      // registry is keyed by message id and drives the card independently of
      // the (localizable) notice text.
      oauthRecoveryRegistry.markFailed(messageId);
      // Partial output is still billed and visible, so keep it and append the
      // recovery note; the card below the message carries the action.
      final partial = state.fullContentRaw.trimRight();
      displayContent = partial.isEmpty
          ? oauthNotice
          : '$partial\n\n$oauthNotice';
    } else if (state.fullContentRaw.isNotEmpty && isRetriesExhausted) {
      // When retries are exhausted, the error is guaranteed to be a
      // [TransientStreamError] (the only path that flips
      // [isRetriesExhausted] to true).
      final attempts = (e as TransientStreamError).attempts;
      // Localised note via the ARB key. Fall back to a hard-coded
      // string if the ARB lookup fails (e.g. context has been
      // disposed by the time the error fires).
      final note = l10n != null
          ? '\n\n${l10n.streamInterruptedNote(attempts)}'
          : '\n\n(Connection interrupted after $attempts retries)';
      displayContent = state.fullContentRaw + note;
    } else {
      final rawContent = state.fullContentRaw.isNotEmpty
          ? state.fullContentRaw
          : errorText;
      final processed = _transformAssistantContent(state, rawContent);
      displayContent = processed.isNotEmpty ? processed : errorText;
    }

    // R2: Persist pending AI Team proposals on error
    final pendingProposals = _aiTeamPendingProposals.remove(messageId);
    final usageMeta = state.usage?.toMessageUsage();
    await chatService.updateMessage(
      messageId,
      content: displayContent,
      totalTokens: state.totalTokens,
      isStreaming: false,
      aiTeamProposalsJson: pendingProposals,
      usageMeta: usageMeta,
    );

    final index = _messages.indexWhere((m) => m.id == messageId);
    if (index != -1) {
      _messages[index] = _messages[index].copyWith(
        content: displayContent,
        isStreaming: false,
        totalTokens: state.totalTokens,
        aiTeamProposalsJson: pendingProposals,
        usageMetaJson: usageMeta == null
            ? _messages[index].usageMetaJson
            : jsonEncode(usageMeta.toJson()),
      );
      onMessagesChanged?.call();
    }
    _setConversationLoading(conversationId, false);

    // Use unified reasoning completion method on error
    await streamController.finishReasoningAndPersist(
      messageId,
      updateReasoningInDb:
          (
            String messageId, {
            String? reasoningText,
            DateTime? reasoningFinishedAt,
            DateTime? processFinishedAt,
            DateTime? processStartedAt,
            String? reasoningSegmentsJson,
          }) async {
            await chatService.updateMessage(
              messageId,
              reasoningText: reasoningText,
              reasoningFinishedAt: reasoningFinishedAt,
              processFinishedAt: processFinishedAt,
              processStartedAt: processStartedAt,
              reasoningSegmentsJson: reasoningSegmentsJson,
            );
          },
    );

    final journal = state.agentJournal;
    if (journal != null && !journal.isEnded) {
      await journal.onError();
      onRunCheckpointChanged?.call();
    }

    await _conversationStreams.remove(conversationId)?.cancel();
    onStreamError?.call(errorText);
    onStreamFinished?.call();
  }

  /// Classify the run's terminal state exactly once.
  ///
  /// Called from both the terminal-chunk path (`_handleStreamFinish`, which
  /// cancels the subscription before the stream's own `onDone` can fire) and
  /// the stream `onDone` path. The journal's ended flag makes the second call
  /// a no-op.
  Future<void> _finishRunJournal(stream_ctrl.StreamingState state) async {
    final journal = state.agentJournal;
    if (journal == null || journal.isEnded) return;
    await journal.onDone(softStopReason: state.softStopReason);
    onRunCheckpointChanged?.call();
  }

  /// Handle stream done callback.
  Future<void> _handleStreamDone(stream_ctrl.StreamingState state) async {
    final conversationId = state.conversationId;

    // Answer Review v1 (§9.6): a stream that ended mid-revision (e.g. the
    // driver never released its terminal) restores the backed-up draft so
    // `_finishStreaming` below persists the original answer.
    _restoreReviewDraftIfNeeded(state);
    if (!state.finishHandled &&
        _activeStreamStates.containsKey(state.messageId)) {
      await _finalizeReviewOnAbort(state, cancelled: false);
    }

    // Ensure streaming is marked as ended
    streamController.markStreamingEnded(state.messageId);

    streamController.cleanupTimers(state.messageId);
    if (_loadingConversationIds.contains(conversationId)) {
      await _finishStreaming(
        state,
        generateTitle: state.ctx.generateTitleOnFinish,
      );
    }

    // P2-1 terminal classification. This also runs from _handleStreamFinish
    // because that path cancels the subscription before `onDone` can fire;
    // the journal is idempotent via its ended flag.
    await _finishRunJournal(state);

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
          reasoningSegmentsJson: streamController.serializeReasoningSegments(
            segs,
          ),
        );
      }
      // Ensure any inline data URLs get converted even if the user navigates away mid-stream
      onScheduleImageSanitize?.call(
        streaming.id,
        latestContent,
        immediate: true,
      );
    } catch (_) {}
  }
}
