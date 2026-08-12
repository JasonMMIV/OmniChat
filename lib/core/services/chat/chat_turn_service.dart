import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../models/assistant.dart';
import '../../models/chat_message.dart';
import '../../models/conversation.dart';
import '../../providers/model_provider.dart';
import '../../providers/settings_provider.dart';
import '../api/chat_api_service.dart';
import '../search/search_tool_service.dart';
import 'chat_service.dart';
import 'prompt_transformer.dart';

/// 已準備好的單一 LLM turn 請求（context、system prompt、search tool 皆已組裝）。
class ChatTurnRequest {
  ChatTurnRequest({
    required this.config,
    required this.modelId,
    required this.apiMessages,
    required this.thinkingBudget,
    this.temperature,
    this.topP,
    this.maxTokens,
    required this.toolDefs,
    this.onToolCall,
  });

  final ProviderConfig config;
  final String modelId;
  final List<Map<String, dynamic>> apiMessages;
  final int? thinkingBudget;
  final double? temperature;
  final double? topP;
  final int? maxTokens;
  final List<Map<String, dynamic>> toolDefs;
  final Future<String> Function(String name, Map<String, dynamic> args)?
      onToolCall;
}

/// 進行中 LLM turn 的控制 handle。
///
/// 對應現行 voice chat 的 `_streamSub` / `_streamDone` 取消模式：pause / cleanup
/// 呼叫 [cancel]；[done] 保證在最終 DB flush 完成後 complete（含 cancel 路徑，
/// 確保 assistant message 以 `isStreaming: false` 收尾）。
class ChatTurnHandle {
  ChatTurnHandle._(this.assistantMessageId, this._service);

  final ChatTurnService _service;
  final String assistantMessageId;

  final Completer<void> _done = Completer<void>();
  StreamSubscription<ChatStreamChunk>? _sub;
  Timer? _persistTimer;
  // 節流寫入串列（FIFO）：每次寫入都串接在前一次之後，確保「最終 flush
  // （isStreaming: false）」必定是最後一次寫入（last-write-wins），
  // 杜絕「節流寫入晚於最終 flush」導致訊息卡在 isStreaming: true 的競態。
  Future<void> _persistInFlight = Future<void>.value();
  String _fullContent = '';
  bool _finished = false;

  /// 累積的完整回應內容。
  String get fullContent => _fullContent;

  /// 在 stream 自然結束 / 錯誤 / [cancel] 後 complete（最終 DB 寫入已完成）。
  Future<void> get done => _done.future;

  /// 取消 stream 並確保 DB 收尾（`isStreaming: false`）。
  Future<void> cancel() async {
    await _sub?.cancel();
    _sub = null;
    await _finish();
  }

  void _appendChunk(String delta) {
    _fullContent += delta;
  }

  /// 3.2-5：Streaming 持久化節流 — 以 300ms 計時器 batch `updateMessage`，
  /// 避免逐 chunk 寫 DB（長回應 DB 寫入次數顯著下降）。
  void _schedulePersist() {
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 300), () async {
      _persistTimer = null;
      // 若已進入最終 flush（_finished），直接跳過：_finish 保證以
      // isStreaming: false 寫入最終狀態，避免與最終寫入競態。
      if (_finished) return;
      _persistInFlight = _persistInFlight.then(
        (_) => _service._persist(this, isStreaming: true),
      );
      await _persistInFlight;
    });
  }

  Future<void> _finish() async {
    if (_finished) return;
    _finished = true;
    _persistTimer?.cancel();
    _persistTimer = null;
    // 依序寫入：等所有已排程的節流寫入完成後，才寫最終 flush（isStreaming: false）。
    _persistInFlight = _persistInFlight.then(
      (_) => _service._persist(this, isStreaming: false),
    );
    await _persistInFlight;
    if (!_done.isCompleted) _done.complete();
  }
}

/// 共用 LLM 送訊服務（Phase 3 任務 3.2）。
///
/// 職責：
/// 1. Context 組裝：truncateIndex 裁切、版本收斂（collapseVersions）、過濾空內容。
/// 2. System prompt placeholder 注入（PromptTransformer）。
/// 3. Search tool 注入（含 hasBuiltInSearch 判定）。
/// 4. 呼叫 [ChatApiService.sendMessageStream]，回傳統一包裝（stream + cancel
///    handle + onChunk 回調），支援 voice chat 的 `_streamSub` / `_streamDone`
///    取消模式。
/// 5. Streaming 持久化節流（見 [ChatTurnHandle._schedulePersist]）。
class ChatTurnService {
  ChatTurnService({required this.chatService});

  final ChatService chatService;

  /// 3.2-1：Context 組裝 — truncateIndex 裁切 → 版本收斂 → 過濾空內容 → API messages。
  List<Map<String, dynamic>> buildApiMessages({
    required Conversation conversation,
    required List<ChatMessage> messages,
    required Map<String, int> versionSelections,
  }) {
    final tIndex = conversation.truncateIndex;
    final List<ChatMessage> sourceAll = (tIndex >= 0 &&
            tIndex < messages.length)
        ? messages.sublist(tIndex)
        : List<ChatMessage>.of(messages);

    final List<ChatMessage> source = _collapseVersions(
      sourceAll,
      versionSelections,
    );

    // 注意：map literal 必須明確標註 <String, dynamic>{...}，否則執行期型別會是
    // _Map<String, String>（literal 值都是 String），而後續 prepareTurnRequest 的
    // apiMessages.insert(0, {'role':'system', ...}) 會因靜態型別 List<Map<String,
    // dynamic>> 被推斷為 _Map<String, dynamic>，insert 時拋出
    // 「'_Map<String, dynamic>' is not a subtype of 'Map<String, String>'」的
    // 執行期型別錯誤（Phase 3 回歸，v1.10.1 的 var 推斷不會觸發）。
    return source
        .where((m) => m.content.isNotEmpty)
        .map((m) => <String, dynamic>{
          'role': m.role == 'assistant' ? 'assistant' : 'user',
          'content': m.content,
        })
        .toList();
  }

  /// 3.2-2/3：組裝完整請求（system prompt 注入 + search tool 注入）。
  ChatTurnRequest prepareTurnRequest({
    required Conversation conversation,
    required List<ChatMessage> messages,
    required Map<String, int> versionSelections,
    required String providerKey,
    required String modelId,
    required SettingsProvider settings,
    required Assistant? assistant,
    required BuildContext context,
    required String userNickname,
  }) {
    var apiMessages = buildApiMessages(
      conversation: conversation,
      messages: messages,
      versionSelections: versionSelections,
    );

    // 注入 system prompt（placeholder 替換）
    if ((assistant?.systemPrompt.trim().isNotEmpty ?? false)) {
      final vars = PromptTransformer.buildPlaceholders(
        context: context,
        assistant: assistant!,
        modelId: modelId,
        modelName: modelId,
        userNickname: userNickname,
      );
      final sys = PromptTransformer.replacePlaceholders(
        assistant.systemPrompt,
        vars,
      );
      apiMessages.insert(0, {'role': 'system', 'content': sys});
    }

    final supportsTools = isToolModel(settings, providerKey, modelId);
    final hasBuiltInSearch = _hasBuiltInSearch(providerKey, modelId);

    final List<Map<String, dynamic>> toolDefs = <Map<String, dynamic>>[];
    Future<String> Function(String, Map<String, dynamic>)? onToolCall;

    if (settings.searchEnabled && !hasBuiltInSearch) {
      final prompt = SearchToolService.getSystemPrompt();
      if (apiMessages.isNotEmpty && apiMessages.first['role'] == 'system') {
        apiMessages[0]['content'] =
            '${apiMessages[0]['content'] ?? ''}\n\n$prompt';
      } else {
        apiMessages.insert(0, {'role': 'system', 'content': prompt});
      }
    }

    if (settings.searchEnabled && !hasBuiltInSearch && supportsTools) {
      toolDefs.add(SearchToolService.getToolDefinition());
    }

    if (toolDefs.isNotEmpty) {
      onToolCall = (name, args) async {
        if (name == SearchToolService.toolName && settings.searchEnabled) {
          final q = (args['query'] ?? '').toString();
          return await SearchToolService.executeSearch(q, settings);
        }
        return '';
      };
    }

    return ChatTurnRequest(
      config: settings.getProviderConfig(providerKey),
      modelId: modelId,
      apiMessages: apiMessages,
      thinkingBudget: assistant?.thinkingBudget ?? settings.thinkingBudget,
      temperature: assistant?.temperature,
      topP: assistant?.topP,
      maxTokens: assistant?.maxTokens,
      toolDefs: toolDefs,
      onToolCall: onToolCall,
    );
  }

  /// 3.2-4：啟動 turn — 送 stream + 節流持久化。
  ///
  /// [onChunk] 每個 chunk 回呼（供 UI 即時更新字幕）；[onError] 在 stream
  /// 錯誤 / 建立失敗時回呼。回傳的 [ChatTurnHandle] 支援 [ChatTurnHandle.cancel]
  /// 取消（pause / cleanup 使用）。
  ChatTurnHandle startTurn({
    required ChatTurnRequest request,
    required String assistantMessageId,
    void Function(String fullContent)? onChunk,
    void Function(String error)? onError,
  }) {
    final handle = ChatTurnHandle._(assistantMessageId, this);
    // 安全網：若 _run 因任何原因失敗（理論上不會），確保 handle.done 仍會完成，
    // 避免呼叫端（voice chat 的 _sendToLLM）卡在 await handle.done。
    unawaited(
      _run(handle, request, onChunk, onError).catchError((Object e) async {
        onError?.call(e.toString());
        await handle._finish();
      }),
    );
    return handle;
  }

  Future<void> _run(
    ChatTurnHandle handle,
    ChatTurnRequest request,
    void Function(String fullContent)? onChunk,
    void Function(String error)? onError,
  ) async {
    // sendMessageStream 是 async*：呼叫本身不會同步丟錯，錯誤皆由 stream
    // onError 處理，因此不需 try/catch 包覆。
    final stream = ChatApiService.sendMessageStream(
      config: request.config,
      modelId: request.modelId,
      messages: request.apiMessages,
      userImagePaths: const [],
      thinkingBudget: request.thinkingBudget,
      temperature: request.temperature,
      topP: request.topP,
      maxTokens: request.maxTokens,
      tools: request.toolDefs.isEmpty ? null : request.toolDefs,
      onToolCall: request.onToolCall,
      extraHeaders: null,
      extraBody: null,
      stream: true,
      imageAspectRatio: null,
    );
    handle._sub = stream.listen(
      (chunk) {
        handle._appendChunk(chunk.content);
        onChunk?.call(handle.fullContent);
        handle._schedulePersist();
      },
      onError: (Object e) {
        onError?.call(e.toString());
        unawaited(handle._finish());
      },
      onDone: () {
        unawaited(handle._finish());
      },
      cancelOnError: true,
    );
  }

  Future<void> _persist(
    ChatTurnHandle handle, {
    required bool isStreaming,
  }) async {
    try {
      await chatService.updateMessage(
        handle.assistantMessageId,
        content: handle.fullContent,
        isStreaming: isStreaming,
      );
    } catch (_) {
      // 忽略：持久化失敗不中斷 stream
    }
  }

  /// 模型是否支援 tool calling（modelOverrides 優先，其次 ModelRegistry.infer）。
  static bool isToolModel(
    SettingsProvider settings,
    String providerKey,
    String modelId,
  ) {
    final cfg = settings.getProviderConfig(providerKey);
    final ov = cfg.modelOverrides[modelId] as Map?;
    if (ov != null) {
      final abilities =
          (ov['abilities'] as List?)?.map((e) => e.toString()).toList() ??
              const <String>[];
      if (abilities.map((e) => e.toLowerCase()).contains('tool')) return true;
    }
    final inferred = ModelRegistry.infer(
      ModelInfo(id: modelId, displayName: modelId),
    );
    return inferred.abilities.contains(ModelAbility.tool);
  }

  /// Gemini 內建搜尋判定（集中單一 helper，自 voice_chat_screen 搬移）。
  ///
  /// TODO: 改為查 ModelRegistry.infer abilities（需先定義「builtInSearch」能力，
  /// 避免把 tool 能力誤判為內建搜尋）。
  static bool _hasBuiltInSearch(String providerKey, String modelId) {
    return providerKey == 'google' &&
        (modelId.contains('1.5') || modelId.contains('gemini-pro'));
  }

  /// 版本收斂：同一 groupId 的訊息只保留使用者選定（或最後）版本。
  List<ChatMessage> _collapseVersions(
    List<ChatMessage> items,
    Map<String, int> versionSelections,
  ) {
    final Map<String, List<ChatMessage>> byGroup = <String, List<ChatMessage>>{};
    final List<String> order = <String>[];
    for (final m in items) {
      final gid = (m.groupId ?? m.id);
      final list = byGroup.putIfAbsent(gid, () {
        order.add(gid);
        return <ChatMessage>[];
      });
      list.add(m);
    }
    for (final e in byGroup.entries) {
      e.value.sort((a, b) => a.version.compareTo(b.version));
    }
    final out = <ChatMessage>[];
    for (final gid in order) {
      final vers = byGroup[gid]!;
      final sel = versionSelections[gid];
      final idx = (sel != null && sel >= 0 && sel < vers.length)
          ? sel
          : (vers.length - 1);
      out.add(vers[idx]);
    }
    return out;
  }
}
