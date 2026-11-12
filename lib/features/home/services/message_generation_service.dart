import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../../core/models/assistant.dart';
import '../../../core/models/chat_input_data.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/conversation.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/providers/model_provider.dart';
import '../../../core/providers/skills_provider.dart';
import '../../../core/services/agent/compaction/compaction_trigger.dart';
import '../../../core/services/agent/subagent.dart';
import 'context_usage_service.dart';
import '../../../core/services/api/chat_stream_chunk.dart' show ToolCallHandler;
import '../../../core/services/api/learned_context_windows.dart';
import '../../../core/services/api/native_input_policy.dart';
import '../../../core/services/api/tool_result_images.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/chat/chat_turn_service.dart';
import '../../../core/services/chat/todo_models.dart';
import '../../../core/services/chat/todo_projection.dart';
import '../../../core/services/chat/todo_v1_migration.dart';
import '../../../core/services/logging/flutter_logger.dart';
import '../../../core/services/mcp/mcp_tool_prompts.dart';
import '../../../core/services/skills/skill_invocations.dart';
import '../../../core/services/skills/skill_service.dart';
import '../../../core/services/workspace/workspace_file_map.dart';
import '../../../core/services/workspace/workspace_resolver.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../utils/assistant_regex.dart';
import '../../../core/models/assistant_regex.dart';
import '../controllers/stream_controller.dart' as stream_ctrl;
import '../controllers/generation_controller.dart';
import 'file_workspace_prompt.dart';
import 'message_builder_service.dart';
import 'tool_handler_service.dart';

/// Callback types for UI updates from MessageGenerationService
typedef OnMessagesChanged = void Function();
typedef OnConversationLoadingChanged = void Function(
  String conversationId,
  bool loading,
);
typedef OnScrollToBottom = void Function();
typedef OnShowError = void Function(String message);
typedef OnShowWarning = void Function(String message);
typedef OnHapticFeedback = void Function();

/// Result of preparing a message generation
class PreparedGeneration {
  final List<Map<String, dynamic>> apiMessages;
  final List<Map<String, dynamic>> toolDefs;

  /// P1-4 id-aware contract (see [ToolCallHandler]).
  final ToolCallHandler? onToolCall;
  final bool hasBuiltInSearch;
  final List<String> lastUserImagePaths;

  /// Stage 2: workspace-bound policy for send-time tool-result images.
  final ToolImagePolicy? toolImagePolicy;

  PreparedGeneration({
    required this.apiMessages,
    required this.toolDefs,
    this.onToolCall,
    required this.hasBuiltInSearch,
    required this.lastUserImagePaths,
    this.toolImagePolicy,
  });
}

/// Service for handling message generation orchestration.
///
/// This service coordinates:
/// - Message creation (user + assistant placeholder)
/// - API message preparation with all injections
/// - Stream execution and management
/// - Reasoning state initialization
///
/// UI updates are communicated through callbacks to maintain separation.
class MessageGenerationService {
  MessageGenerationService({
    required this.chatService,
    required this.messageBuilderService,
    required this.generationController,
    required this.streamController,
    required this.contextProvider,
  });

  final ChatService chatService;
  final MessageBuilderService messageBuilderService;
  final GenerationController generationController;
  final stream_ctrl.StreamController streamController;
  final BuildContext contextProvider;

  // Callbacks for UI updates (set by home_page)
  OnMessagesChanged? onMessagesChanged;
  OnConversationLoadingChanged? onConversationLoadingChanged;
  OnScrollToBottom? onScrollToBottom;
  OnShowError? onShowError;
  OnShowWarning? onShowWarning;
  OnHapticFeedback? onHapticFeedback;

  /// Check if reasoning is enabled for given budget
  bool isReasoningEnabled(int? budget) {
    if (budget == null) return true;
    if (budget == -1) return true;
    return budget >= 1024;
  }

  /// P1-2: rough chars/3 token estimate of a raw message INCLUDING its tool
  /// events (args + result bodies) — the tail budget in the trigger walk
  /// must account for what the replayed neutral messages will weigh.
  int _estimateRawMessageTokens(ChatMessage m) {
    // Shared with the context ring: storage fails closed for tool bodies that
    // were never loaded, so both estimators degrade to the message alone
    // instead of drifting apart.
    return estimateChatMessageTokensSafe(
      m,
      readToolEvents: chatService.getToolEvents,
    );
  }

  /// Prepare API messages with all injections applied.
  Future<PreparedGeneration> prepareApiMessagesWithInjections({
    required List<ChatMessage> messages,
    required String assistantMessageId,
    required Map<String, int> versionSelections,
    required Conversation? currentConversation,
    required SettingsProvider settings,
    required Assistant? assistant,
    required String? assistantId,
    required String providerKey,
    required String modelId,
    // AI Team (and any other multi-model fan-out) must not use the selected
    // model's native-input capability for every proposer (plan §7 F10).
    bool enableNativeInputs = true,
  }) async {
    // Tool replay reads full events synchronously. The timeline only preloads
    // summaries, so fetch the full bodies for this slice before assembly
    // (including the token estimate below).
    await chatService.ensureToolEventsLoaded(messages.map((m) => m.id));

    // P1-2 trigger evaluation (assembly-time projection, ADR-A6): if the
    // measured usage of the last completed assistant turn is over the
    // model's trigger(W), move the compaction marker so the older history
    // becomes a deterministic mechanical summary at assembly time.
    var conversation = currentConversation;

    // Captured before any await (use_build_context_synchronously guard).
    final l10n = AppLocalizations.of(contextProvider);

    // Resolve the effective workspace BEFORE buildApiMessages so the file
    // tools and the workspace prompt agree. `write_todos` is independent of
    // this decision (Phase 3-4); its gate is the planning switch + model
    // tool support, shared with the compaction knowledge block (§2.3.1).
    final workspaceResolution = currentConversation == null
        ? null
        : await WorkspaceResolver.resolve(
            conversation: currentConversation,
            project: assistant,
            conversationConfig: chatService.getConversationWorkspaceConfig(
              currentConversation.id,
            ),
            defaultConfig: settings.defaultWorkspaceConfig,
          );
    final workspacePath = workspaceResolution?.path;

    // P1-3 (plan §2.1/§2.3): the latest successful `write_todos` conversation
    // event is the single source of truth. The projection replaces the old
    // TodoService Hive read; the injection gate shares the exact predicate
    // that registers the tool, so a disabled workspace/toggle/model can no
    // longer surface a plan the model cannot update.
    final supportsTools = ChatTurnService.isToolModel(
      settings,
      providerKey,
      modelId,
    );
    var hasWriteTodos = false;
    try {
      hasWriteTodos = ToolHandlerService.hasWriteTodosEnabled(
        settings,
        supportsTools: supportsTools,
      );
    } catch (_) {}

    TodoState? todoState;
    if (settings.todoEventProjectionV1) {
      try {
        final activeMessages = messageBuilderService.collapseVersions(
          messages,
          versionSelections,
        );
        final eventsByMessageId = <String, List<Map<String, dynamic>>>{
          for (final m in activeMessages) m.id: chatService.getToolEvents(m.id),
        };
        todoState = projectTodoState(
          activeMessages: activeMessages,
          eventsByMessageId: eventsByMessageId,
          onDebugLog: (message) =>
              FlutterLogger.log(message, tag: 'todo-projection'),
        );
      } catch (e) {
        FlutterLogger.log('todo projection failed: $e', tag: 'todo-projection');
      }
    }
    if (todoState == null && conversation != null) {
      // §2.5.3: conversations the one-time migration could not attach (no
      // assistant message on the branch) keep a read-only `todo_v1` entry
      // until one exists; the projection falls back to it.
      try {
        final legacy = await TodoV1Migration.legacyItemsFor(conversation.id);
        if (legacy != null && legacy.isNotEmpty) {
          todoState = TodoState(items: legacy, hasExplicitState: true);
        }
      } catch (_) {}
    }
    final todoNextAction = hasWriteTodos ? todoNextActionOf(todoState) : null;
    final todoSummary = hasWriteTodos
        ? buildTodoCompactionSummary(todoState)
        : null;

    if (settings.autoCompactionV1 && conversation != null) {
      final conv = conversation;
      int? measured;
      for (var i = messages.length - 1; i >= 0; i--) {
        final m = messages[i];
        if (m.role == 'assistant' && (m.promptTokens ?? 0) > 0) {
          measured = m.promptTokens;
          break;
        }
      }
      final learned = await LearnedContextWindows.lookup(providerKey, modelId);
      final catalogCfg = settings.getProviderConfig(providerKey);
      // Explicit user configuration (Token limits fields) wins over the
      // learned window / catalog reserve (compaction plan §5).
      final userOv = catalogCfg.modelOverrides[modelId];
      final trigger = evaluatePrepTimeCompaction(
        messages: messages,
        measuredPromptTokens: measured,
        modelId: modelId,
        learnedWindowTokens: learned,
        providerId: catalogCfg.catalogProviderId,
        host: catalogCfg.catalogHost,
        userContextWindow: ModelRegistry.parseIntOverride(
          userOv?['contextWindow'],
        ),
        userMaxOutput: ModelRegistry.parseIntOverride(userOv?['maxOutput']),
        estimateMessageTokens: _estimateRawMessageTokens,
        hasToolEvents: (m) => chatService.getToolEvents(m.id).isNotEmpty,
      );
      if (trigger.shouldCompact &&
          trigger.boundaryIndex > conv.compactBeforeIndex) {
        await chatService.setCompactBeforeIndex(conv.id, trigger.boundaryIndex);
        conversation = conv.copyWith(compactBeforeIndex: trigger.boundaryIndex);
      }
    }

    // Build API messages
    final apiMessages = messageBuilderService.buildApiMessages(
      messages: messages,
      versionSelections: versionSelections,
      currentConversation: conversation,
      includeToolMessages: settings.replayToolResults,
      enableAutoCompaction: settings.autoCompactionV1,
      compactionNextAction: todoNextAction,
      compactionTodoSummary: todoSummary,
      includeGeminiThoughtSignatures: _isGoogleProviderKey(
        settings,
        providerKey,
      ),
    );

    // Process user messages (documents, OCR, templates). Native audio/PDF
    // parts are resolved here so the transport only appends prebuilt parts
    // (the size guard / base64 work happens exactly once per request).
    final nativePolicy = enableNativeInputs
        ? resolveNativeInputPolicy(settings, providerKey, modelId)
        : NativeInputPolicy.disabled;
    final lastUserImagePaths = await messageBuilderService
        .processUserMessagesForApi(
          apiMessages,
          settings,
          assistant,
          nativePolicy: nativePolicy,
        );

    // Inject the assistant system prompt. The `[File Workspace]` block is
    // appended after toolDefs are built so it only mentions tools that are
    // actually advertised in this request.
    messageBuilderService.injectSystemPrompt(apiMessages, assistant, modelId);
    await messageBuilderService.injectMemoryAndRecentChats(
      apiMessages,
      assistant,
      currentConversationId: currentConversation?.id,
      settings: settings,
      supportsTools: supportsTools,
    );

    final hasBuiltInSearch = messageBuilderService.hasGeminiBuiltInTools(
      settings,
      providerKey,
      modelId,
    );

    messageBuilderService.injectSearchPrompt(
      apiMessages,
      settings,
      hasBuiltInSearch,
    );
    await messageBuilderService.injectInstructionPrompts(
      apiMessages,
      assistantId,
    );

    // Warm the skills global root BEFORE both skill consumers: `/skill`
    // resolution below reads `cachedGlobalRoot`, and the sync scan inside
    // buildToolDefinitions needs it too. On a cold start (provider init not
    // finished) a null cache would wrongly report every skill as missing.
    // Also creates the dir on desktop first-use.
    try {
      await SkillService.globalSkillsRoot();
    } catch (_) {}

    // Keep the input-bar skills button hint fresh: its gate reads
    // `SkillsProvider.hasAnyKnownSkills`, and the project-skill hint used to
    // update only when the menu opened — which itself needed a visible
    // button, so project-only setups (no global skills) never got a menu
    // entry. Assembly time is the first moment the conversation workspace is
    // known (PLAN_AGENT_SKILLS.md §2.3) — best-effort, never breaks assembly.
    try {
      if (contextProvider.mounted) {
        contextProvider.read<SkillsProvider>().noteProjectSkills(workspacePath);
      }
    } catch (_) {}

    // Agent Skills: resolve `/skill <name>` tokens in user messages. Works
    // in BOTH preload modes — the user-invocation path is independent of the
    // `skill` tool (PLAN_AGENT_SKILLS.md §6.2/§6.3). The invoked skill's
    // content rides the SAME user message (user-turn delivery — a system
    // append made models process the token-stripped remnant as a plain
    // request and never start the skill; 2026-10-06 hands-on fix). Pure
    // function over the in-memory assembly; Hive history is never
    // rewritten.
    try {
      final resolution = SkillInvocations.resolveInMessages(
        apiMessages,
        loadSkill: (name) => SkillService.loadSkillByName(
          name,
          workspacePath: workspacePath,
          globalRoot: SkillService.cachedGlobalRoot,
        ),
      );
      if (resolution.failedNames.isNotEmpty) {
        final firstName = resolution.failedNames.first;
        final warning =
            l10n?.skillInvocationFailed(firstName) ??
            'Skill "$firstName" is not installed.';
        // Nothing in the app assigns `onShowWarning` (home_page_controller
        // never wires the callbacks), so a misspelled skill name used to fail
        // completely silently — the exact confusion the `/skill` badge was
        // added to remove. Fall back to a direct snackbar.
        if (onShowWarning != null) {
          onShowWarning!(warning);
        } else if (contextProvider.mounted) {
          showAppSnackBar(
            contextProvider,
            message: warning,
            type: NotificationType.warning,
          );
        }
      }
    } catch (_) {}

    // Apply context limit and inline images
    messageBuilderService.applyContextLimit(apiMessages, assistant);
    await messageBuilderService.inlineLocalImages(apiMessages);

    final toolDefs = generationController.buildToolDefinitions(
      settings,
      assistant,
      providerKey,
      modelId,
      hasBuiltInSearch,
      workspaceEnabled: workspaceResolution?.enabled ?? false,
      workspacePath: workspacePath,
    );

    // The workspace prompt is rendered from the real toolDefs: disabled tools
    // are not advertised, and file_grep / file_view_image /
    // get_console_errors / shell_run are included when offered. It lands after
    // the memory/search/instruction blocks because this is the first point
    // where toolDefs are final; it still precedes the MCP tool policy and the
    // workspace file map.
    final workspacePrompt = buildFileWorkspacePrompt(workspacePath, toolDefs);
    if (workspacePrompt != null) {
      messageBuilderService.appendToSystemMessage(apiMessages, workspacePrompt);
    }

    // Tool usage policies (e.g. `illustrate`) — same-source with toolDefs:
    // inject only when the tool is really advertised in this request. Gemini
    // native built-ins are the documented exception: chat_api_service strips
    // function declarations AFTER assembly, so `forRequest` gates them too.
    final toolPrompt = McpToolPrompts.forRequest(
      defs: toolDefs,
      hasBuiltInSearch: hasBuiltInSearch,
    );
    if (toolPrompt != null) {
      messageBuilderService.appendToSystemMessage(apiMessages, toolPrompt);
    }

    // P2-6 L3 (plan §2.9): workspace file map — a fixed-position tail of the
    // system message listing the tree so the model does not have to discover
    // it through file_list round-trips (or guess paths). Rendered only from
    // stable tree facts (paths + sizes), so an unchanged workspace keeps the
    // system prefix byte-identical across turns. Gated on the SAME predicate
    // that registers the file tools (§2.3.1 doctrine): `file_list` must
    // actually be advertised in this request.
    if (workspacePath != null &&
        (workspaceResolution?.enabled ?? false) &&
        toolDefs.any((def) {
          try {
            return ((def['function'] as Map)['name'] ?? '').toString() ==
                'file_list';
          } catch (_) {
            return false;
          }
        })) {
      try {
        // Files the agent wrote this conversation (FileRecord persistence)
        // get the `agent-written` marker in the map. Collapse to the active
        // version set first — unselected versions must not vote. Recent-
        // window capped: agent-written files are recent by nature, and a
        // full-timeline per-message sqlite query would tax the every-send
        // assembly path on long conversations.
        final activeMessages = messageBuilderService.collapseVersions(
          messages,
          versionSelections,
        );
        final recentMessages = activeMessages.length > 200
            ? activeMessages.sublist(activeMessages.length - 200)
            : activeMessages;
        final toolWrittenPaths = <String>[];
        for (final m in recentMessages) {
          try {
            for (final record in chatService.getMessageFileRecords(m.id)) {
              toolWrittenPaths.add(record.path);
            }
          } catch (_) {}
        }
        final fileMap = await WorkspaceFileMap.build(
          workspacePath: workspacePath,
          toolWrittenAbsolutePaths: toolWrittenPaths,
        );
        if (fileMap.isNotEmpty) {
          messageBuilderService.appendToSystemMessage(apiMessages, fileMap);
        }
      } catch (e) {
        // The map is a navigation aid only — never break assembly over it.
        FlutterLogger.log(
          'workspace file map failed: $e',
          tag: 'workspace-map',
        );
      }
    }

    // §2.3.1: the predicate and the actual tool list must agree. Log any
    // drift and trust the tool list (it is what the model really receives).
    final toolHasTodo = toolDefs.any((def) {
      try {
        return ((def['function'] as Map)['name'] ?? '').toString() ==
            todoToolName;
      } catch (_) {
        return false;
      }
    });
    if (toolHasTodo != hasWriteTodos) {
      FlutterLogger.log(
        'write_todos gating drift: predicate=$hasWriteTodos '
        'toolDefs=$toolHasTodo',
        tag: 'todo-projection',
      );
    }
    if (shouldAppendTodoStatePair(
      toolHasTodo: toolHasTodo,
      hasBuiltInSearch: hasBuiltInSearch,
      state: todoState,
    )) {
      try {
        appendTodoStatePair(apiMessages, todoState!);
      } catch (e) {
        FlutterLogger.log(
          'appendTodoStatePair failed: $e',
          tag: 'todo-projection',
        );
      }
    }

    final onToolCall = toolDefs.isNotEmpty
        ? generationController.buildToolCallHandler(
            settings,
            assistant,
            conversationId: currentConversation?.id,
            messageId: assistantMessageId,
            workspacePath: workspacePath,
            // P2-3: `spawn_subagent` inherits the generation snapshot — the
            // same provider/model, the tools actually advertised here, and
            // the assistant's custom headers/body + output cap (a helper
            // request must be indistinguishable from the parent on the wire).
            subagentContext: SubagentLaunchConfig(
              providerKey: providerKey,
              modelId: modelId,
              tools: toolDefs,
              extraHeaders: generationController.buildCustomHeaders(assistant),
              extraBody: generationController.buildCustomBody(assistant),
              maxTokens: assistant?.maxTokens,
            ),
          )
        : null;

    // Test doubles may not implement every SettingsProvider getter.
    var sendToolImages = true;
    try {
      sendToolImages = settings.sendToolImages;
    } catch (_) {}
    return PreparedGeneration(
      apiMessages: apiMessages,
      toolDefs: toolDefs,
      onToolCall: onToolCall,
      hasBuiltInSearch: hasBuiltInSearch,
      lastUserImagePaths: lastUserImagePaths,
      toolImagePolicy: ToolImagePolicy(
        workspaceRoot: workspacePath,
        enabled: sendToolImages,
      ),
    );
  }

  /// Create user message from input data.
  Future<ChatMessage> createUserMessage({
    required String conversationId,
    required ChatInputData input,
    required Assistant? assistant,
  }) async {
    final content = input.text.trim();
    final imageMarkers = input.imagePaths.map((p) => '\n[image:$p]').join();
    final docMarkers = input.documents
        .map((d) => '\n[file:${d.path}|${d.fileName}|${d.mime}]')
        .join();

    final processedUserText = applyAssistantRegexes(
      content,
      assistant: assistant,
      scope: AssistantRegexScope.user,
      visual: false,
    );

    return chatService.addMessage(
      conversationId: conversationId,
      role: 'user',
      content: processedUserText + imageMarkers + docMarkers,
    );
  }

  /// Create assistant message placeholder.
  Future<ChatMessage> createAssistantPlaceholder({
    required String conversationId,
    required String modelId,
    required String providerKey,
    String? groupId,
    int version = 0,
  }) async {
    return chatService.addMessage(
      conversationId: conversationId,
      role: 'assistant',
      content: '',
      modelId: modelId,
      providerId: providerKey,
      isStreaming: true,
      groupId: groupId,
      version: version,
    );
  }

  /// Initialize reasoning state for a message if reasoning is enabled.
  Future<void> initializeReasoningState({
    required String messageId,
    required bool enableReasoning,
  }) async {
    if (enableReasoning) {
      final rd = stream_ctrl.ReasoningData();
      streamController.reasoning[messageId] = rd;
      await chatService.updateMessage(
        messageId,
        reasoningStartAt: DateTime.now(),
      );
    }
  }

  /// Build GenerationContext for streaming.
  stream_ctrl.GenerationContext buildGenerationContext({
    required ChatMessage assistantMessage,
    required PreparedGeneration prepared,
    required List<String> userImagePaths,
    required String providerKey,
    required String modelId,
    required Assistant? assistant,
    required SettingsProvider settings,
    required bool supportsReasoning,
    required bool enableReasoning,
    required bool generateTitleOnFinish,
  }) {
    return stream_ctrl.GenerationContext(
      assistantMessage: assistantMessage,
      apiMessages: prepared.apiMessages,
      userImagePaths: userImagePaths,
      providerKey: providerKey,
      modelId: modelId,
      assistant: assistant,
      settings: settings,
      config: settings.getProviderConfig(providerKey),
      toolDefs: prepared.toolDefs,
      onToolCall: prepared.onToolCall,
      extraHeaders: generationController.buildCustomHeaders(assistant),
      extraBody: generationController.buildCustomBody(assistant),
      supportsReasoning: supportsReasoning,
      enableReasoning: enableReasoning,
      streamOutput: assistant?.streamOutput ?? true,
      generateTitleOnFinish: generateTitleOnFinish,
      toolImagePolicy: prepared.toolImagePolicy,
    );
  }

  /// Whether the target provider uses the Google Gemini wire. Thought
  /// signatures must only travel back to the provider that produced them.
  bool _isGoogleProviderKey(SettingsProvider settings, String providerKey) {
    final cfg = settings.getProviderConfig(providerKey);
    return ProviderConfig.classify(cfg.id, explicitType: cfg.providerType) ==
        ProviderKind.google;
  }

  /// Get current model and provider from assistant or global settings.
  ({String? providerKey, String? modelId}) getModelConfig(
    SettingsProvider settings,
    Assistant? assistant,
  ) {
    return (
      providerKey:
          assistant?.chatModelProvider ?? settings.currentModelProvider,
      modelId: assistant?.chatModelId ?? settings.currentModelId,
    );
  }

  /// Calculate version info for regeneration.
  ({String? targetGroupId, int nextVersion, int lastKeep})
  calculateRegenerationVersioning({
    required ChatMessage message,
    required List<ChatMessage> messages,
    required bool assistantAsNewReply,
  }) {
    final idx = messages.indexWhere((m) => m.id == message.id);
    if (idx < 0) {
      return (targetGroupId: null, nextVersion: 0, lastKeep: -1);
    }

    String? targetGroupId;
    int nextVersion = 0;
    int lastKeep;

    if (message.role == 'assistant') {
      lastKeep = idx;
      if (assistantAsNewReply) {
        targetGroupId = null;
        nextVersion = 0;
      } else {
        targetGroupId = message.groupId ?? message.id;
        int maxVer = -1;
        for (final m in messages) {
          final gid = (m.groupId ?? m.id);
          if (gid == targetGroupId) {
            if (m.version > maxVer) maxVer = m.version;
          }
        }
        nextVersion = maxVer + 1;
      }
    } else {
      // User message
      final userGroupId = message.groupId ?? message.id;
      int userFirst = -1;
      for (int i = 0; i < messages.length; i++) {
        final gid0 = (messages[i].groupId ?? messages[i].id);
        if (gid0 == userGroupId) {
          userFirst = i;
          break;
        }
      }
      if (userFirst < 0) userFirst = idx;

      int aid = -1;
      for (int i = userFirst + 1; i < messages.length; i++) {
        if (messages[i].role == 'assistant') {
          aid = i;
          break;
        }
      }

      if (aid >= 0) {
        lastKeep = aid;
        targetGroupId = messages[aid].groupId ?? messages[aid].id;
        int maxVer = -1;
        for (final m in messages) {
          final gid = (m.groupId ?? m.id);
          if (gid == targetGroupId) {
            if (m.version > maxVer) maxVer = m.version;
          }
        }
        nextVersion = maxVer + 1;
      } else {
        lastKeep = userFirst;
        targetGroupId = null;
        nextVersion = 0;
      }
    }

    return (
      targetGroupId: targetGroupId,
      nextVersion: nextVersion,
      lastKeep: lastKeep,
    );
  }

  /// Remove trailing messages after regeneration cut point.
  Future<List<String>> removeTrailingMessages({
    required List<ChatMessage> messages,
    required int lastKeep,
    required String? targetGroupId,
  }) async {
    if (lastKeep >= messages.length - 1) {
      return const [];
    }

    // Collect groups that appear at or before lastKeep
    final keepGroups = <String>{};
    for (int i = 0; i <= lastKeep && i < messages.length; i++) {
      final g = (messages[i].groupId ?? messages[i].id);
      keepGroups.add(g);
    }
    if (targetGroupId != null) keepGroups.add(targetGroupId);

    final trailing = messages.sublist(lastKeep + 1);
    final removeIds = <String>[];
    for (final m in trailing) {
      final gid = (m.groupId ?? m.id);
      final shouldKeep = keepGroups.contains(gid);
      if (!shouldKeep) removeIds.add(m.id);
    }

    for (final id in removeIds) {
      try {
        await chatService.deleteMessage(id);
      } catch (_) {}
      streamController.reasoning.remove(id);
      streamController.toolParts.remove(id);
      streamController.reasoningSegments.remove(id);
    }

    return removeIds;
  }

  /// Build user image paths considering OCR mode.
  List<String> buildUserImagePaths({
    required ChatInputData? input,
    required List<String> lastUserImagePaths,
    required SettingsProvider settings,
  }) {
    final bool ocrActive =
        settings.ocrEnabled &&
        settings.ocrModelProvider != null &&
        settings.ocrModelId != null;

    if (ocrActive) {
      return const <String>[];
    }

    if (input != null) {
      final currentVideoPaths = <String>[
        for (final d in input.documents)
          if (d.mime.toLowerCase().startsWith('video/')) d.path,
      ];
      return <String>[...input.imagePaths, ...currentVideoPaths];
    }

    return lastUserImagePaths;
  }
}
