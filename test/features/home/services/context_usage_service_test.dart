// Context usage service unit tests (docs/context_usage_ring_plan.md v2).
//
// Pins the computeContextUsage contract: buildApiMessages-mirroring slicing
// (truncate → collapse → compact split), measured baseline + completion +
// trailing delta, staleness rules (boundary / truncate / model identity) and
// the AnyBuff token text format.

import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/core/models/chat_message.dart';
import 'package:OmniChat/core/services/chat/storage/chat_storage.dart';
import 'package:OmniChat/features/home/services/context_usage_service.dart';

ChatMessage msg(
  String id, {
  required String role,
  String content = '',
  String? modelId,
  String? providerId,
  int? promptTokens,
  int? completionTokens,
  bool isStreaming = false,
  String? groupId,
  int version = 0,
}) {
  return ChatMessage(
    id: id,
    role: role,
    content: content,
    conversationId: 'conv',
    modelId: modelId,
    providerId: providerId,
    promptTokens: promptTokens,
    completionTokens: completionTokens,
    isStreaming: isStreaming,
    groupId: groupId,
    version: version,
  );
}

/// Newest version per group unless [selections] says otherwise (same shape as
/// MessageBuilderService.collapseVersions).
List<ChatMessage> collapse(
  List<ChatMessage> items,
  Map<String, int> selections,
) {
  final byGroup = <String, List<ChatMessage>>{};
  final order = <String>[];
  for (final m in items) {
    final gid = m.groupId ?? m.id;
    if (!byGroup.containsKey(gid)) order.add(gid);
    byGroup.putIfAbsent(gid, () => []).add(m);
  }
  final out = <ChatMessage>[];
  for (final gid in order) {
    final versions = byGroup[gid]!
      ..sort((a, b) => a.version.compareTo(b.version));
    final sel = selections[gid];
    out.add((sel != null && sel >= 0 && sel < versions.length)
        ? versions[sel]
        : versions.last);
  }
  return out;
}

void main() {
  final toolEvents = <String, List<Map<String, dynamic>>>{};

  ContextUsageSnapshot compute({
    required List<ChatMessage> messages,
    int truncateIndex = -1,
    int compactBeforeIndex = -1,
    bool autoCompaction = true,
    int? learned,
    int? catalog,
    int? userWindow,
    String modelId = 'model-a',
    String providerKey = 'prov-a',
    String? streamingId,
    Map<String, int> selections = const <String, int>{},
    int Function(List<ChatMessage> head)? headEstimate,
  }) {
    return computeContextUsage(
      rawMessages: messages,
      versionSelections: selections,
      truncateIndex: truncateIndex,
      compactBeforeIndex: compactBeforeIndex,
      enableAutoCompaction: autoCompaction,
      learnedWindowTokens: learned,
      catalogWindowTokens: catalog,
      userWindowTokens: userWindow,
      currentModelId: modelId,
      currentProviderKey: providerKey,
      streamingMessageId: streamingId,
      collapseVersions: collapse,
      estimateMessageTokens: (m) => estimateChatMessageTokens(
        m,
        toolEvents: toolEvents[m.id] ?? const <Map<String, dynamic>>[],
      ),
      estimateCompactedHeadTokens: headEstimate ?? ((head) => 0),
    );
  }

  test('window precedence: learned > catalog > unknown', () {
    final messages = [msg('u1', role: 'user', content: 'a' * 300)];
    expect(
      compute(messages: messages, learned: 200000, catalog: 128000).maxTokens,
      200000,
    );
    expect(
      compute(messages: messages, learned: null, catalog: 128000).maxTokens,
      128000,
    );
    final unknown = compute(messages: messages, learned: 0, catalog: null);
    expect(unknown.maxTokens, isNull);
    expect(unknown.hasWindow, isFalse);
  });

  test('window precedence: user override beats learned and catalog', () {
    final messages = [msg('u1', role: 'user', content: 'a' * 300)];
    expect(
      compute(
        messages: messages,
        userWindow: 123456,
        learned: 200000,
        catalog: 128000,
      ).maxTokens,
      123456,
    );
    // An explicit user window fills in even with no learned value.
    expect(
      compute(messages: messages, userWindow: 64000, catalog: 128000)
          .maxTokens,
      64000,
    );
    // Non-positive values are ignored — the chain falls through.
    expect(
      compute(
        messages: messages,
        userWindow: 0,
        learned: 200000,
        catalog: 128000,
      ).maxTokens,
      200000,
    );
  });

  test('estimate path sums messages (chars/3)', () {
    final messages = [
      msg('u1', role: 'user', content: 'a' * 300),
      msg('a1', role: 'assistant', content: 'b' * 300),
    ];
    final s = compute(messages: messages, learned: 200000);
    expect(s.usedTokens, 200);
    expect(s.measured, isFalse);
    expect(s.estimated, isTrue);
  });

  test('empty conversation with known window → 0 used', () {
    final s = compute(messages: const [], learned: 200000);
    expect(s.usedTokens, 0);
    expect(s.hasWindow, isTrue);
  });

  test('truncateIndex == length slices to empty (cleared context)', () {
    final messages = [
      msg('u1', role: 'user', content: 'a' * 300),
      msg('a1', role: 'assistant', content: 'b' * 300),
    ];
    final s = compute(
      messages: messages,
      truncateIndex: messages.length,
      learned: 200000,
    );
    expect(s.usedTokens, 0);
  });

  test('invalid truncateIndex (> length) falls back to full history', () {
    final messages = [msg('u1', role: 'user', content: 'a' * 300)];
    final s = compute(messages: messages, truncateIndex: 99, learned: 200000);
    expect(s.usedTokens, 100);
  });

  test('compactBeforeIndex replaces the head with the summary estimate', () {
    final messages = [
      msg('u1', role: 'user', content: 'a' * 300),
      msg('a1', role: 'assistant', content: 'b' * 300),
      msg('u2', role: 'user', content: 'c' * 300),
      msg('a2', role: 'assistant', content: 'd' * 300),
    ];
    final s = compute(
      messages: messages,
      compactBeforeIndex: 2,
      learned: 200000,
      headEstimate: (head) => 77,
    );
    expect(s.usedTokens, 77 + 200);
    expect(s.measured, isFalse);
  });

  test('autoCompaction=false ignores the boundary', () {
    final messages = [
      msg('u1', role: 'user', content: 'a' * 300),
      msg('a1', role: 'assistant', content: 'b' * 300),
      msg('u2', role: 'user', content: 'c' * 300),
      msg('a2', role: 'assistant', content: 'd' * 300),
    ];
    final s = compute(
      messages: messages,
      compactBeforeIndex: 2,
      autoCompaction: false,
      learned: 200000,
      headEstimate: (head) => 77,
    );
    expect(s.usedTokens, 400);
  });

  test('measured baseline + exact completion + trailing estimate', () {
    final messages = [
      msg('u1', role: 'user', content: 'a' * 300),
      msg(
        'a1',
        role: 'assistant',
        content: 'b' * 600,
        modelId: 'model-a',
        providerId: 'prov-a',
        promptTokens: 5000,
        completionTokens: 1200,
      ),
      msg('u2', role: 'user', content: 'c' * 300),
    ];
    final s = compute(messages: messages, learned: 200000);
    expect(s.usedTokens, 5000 + 1200 + 100);
    expect(s.measured, isTrue);
    expect(s.estimated, isTrue);
  });

  test('exact measured with nothing after → no ≈', () {
    final messages = [
      msg('u1', role: 'user', content: 'a' * 300),
      msg(
        'a1',
        role: 'assistant',
        content: 'b' * 600,
        modelId: 'model-a',
        providerId: 'prov-a',
        promptTokens: 5000,
        completionTokens: 1200,
      ),
    ];
    final s = compute(messages: messages, learned: 200000);
    expect(s.usedTokens, 6200);
    expect(s.measured, isTrue);
    expect(s.estimated, isFalse);
  });

  test('completionTokens missing → completion estimated from content', () {
    final messages = [
      msg(
        'a1',
        role: 'assistant',
        content: 'b' * 600,
        modelId: 'model-a',
        providerId: 'prov-a',
        promptTokens: 5000,
      ),
    ];
    final s = compute(messages: messages, learned: 200000);
    expect(s.usedTokens, 5000 + 200);
    expect(s.estimated, isTrue);
  });

  test('measured before the compact boundary is stale → estimate path', () {
    final messages = [
      msg('u1', role: 'user', content: 'a' * 300),
      msg(
        'a1',
        role: 'assistant',
        content: 'b' * 300,
        modelId: 'model-a',
        providerId: 'prov-a',
        promptTokens: 5000,
        completionTokens: 100,
      ),
      msg('u2', role: 'user', content: 'c' * 300),
      msg('a2', role: 'assistant', content: 'd' * 300),
    ];
    final s = compute(
      messages: messages,
      compactBeforeIndex: 2,
      learned: 200000,
      headEstimate: (head) => 77,
    );
    expect(s.usedTokens, 77 + 200);
    expect(s.measured, isFalse);
  });

  test('measured before truncateIndex is stale → estimate path', () {
    final messages = [
      msg('u1', role: 'user', content: 'a' * 300),
      msg(
        'a1',
        role: 'assistant',
        content: 'b' * 300,
        modelId: 'model-a',
        providerId: 'prov-a',
        promptTokens: 5000,
        completionTokens: 100,
      ),
      msg('u2', role: 'user', content: 'c' * 300),
    ];
    final s = compute(messages: messages, truncateIndex: 2, learned: 200000);
    expect(s.usedTokens, 100);
    expect(s.measured, isFalse);
  });

  test('measured from another model/provider is rejected', () {
    final base = [
      msg('u1', role: 'user', content: 'a' * 300),
      msg(
        'a1',
        role: 'assistant',
        content: 'b' * 300,
        modelId: 'model-a',
        providerId: 'prov-a',
        promptTokens: 5000,
        completionTokens: 100,
      ),
    ];
    expect(
      compute(messages: base, learned: 200000, modelId: 'model-b').measured,
      isFalse,
    );
    expect(
      compute(messages: base, learned: 200000, providerKey: 'prov-b').measured,
      isFalse,
    );
    // Legacy rows without identity are rejected too (conservative).
    final legacy = [
      msg('u1', role: 'user', content: 'a' * 300),
      msg('a1', role: 'assistant', content: 'b' * 300, promptTokens: 5000),
    ];
    expect(compute(messages: legacy, learned: 200000).measured, isFalse);
  });

  test('in-flight streaming assistant is excluded from the delta', () {
    final messages = [
      msg('u1', role: 'user', content: 'a' * 300),
      msg(
        'a1',
        role: 'assistant',
        content: 'b' * 300,
        modelId: 'model-a',
        providerId: 'prov-a',
        promptTokens: 5000,
        completionTokens: 1200,
      ),
      msg('u2', role: 'user', content: 'c' * 300),
      msg(
        'a2',
        role: 'assistant',
        content: 'partial',
        modelId: 'model-a',
        providerId: 'prov-a',
        isStreaming: true,
      ),
    ];
    final s = compute(
      messages: messages,
      learned: 200000,
      streamingId: 'a2',
    );
    expect(s.usedTokens, 5000 + 1200 + 100);
    expect(s.estimated, isTrue);
  });

  test('version collapse picks the selected version after the raw slice', () {
    final messages = [
      msg('v0', role: 'user', content: 'a' * 300, groupId: 'g1', version: 0),
      msg('v1', role: 'user', content: 'b' * 600, groupId: 'g1', version: 1),
    ];
    expect(
      compute(messages: messages, selections: {'g1': 1}, learned: 200000)
          .usedTokens,
      200,
    );
    expect(
      compute(messages: messages, selections: {'g1': 0}, learned: 200000)
          .usedTokens,
      100,
    );
  });

  test('estimateChatMessageTokens counts tool events', () {
    final m = msg('a1', role: 'assistant', content: 'a' * 300);
    expect(estimateChatMessageTokens(m, toolEvents: const []), 100);
    final withTools = estimateChatMessageTokens(m, toolEvents: [
      {'arguments': <String, dynamic>{'x': 'y' * 300}, 'content': 'r' * 300},
    ]);
    expect(withTools, greaterThan(100));
  });

  test('estimateChatMessageTokensSafe tolerates unloaded tool bodies', () {
    final m = msg('a1', role: 'assistant', content: 'a' * 300);
    // SQLite storage fails closed for messages whose tool bodies were never
    // loaded. After a model switch the ring estimates EVERY message, so this
    // must degrade to the message alone instead of aborting the refresh
    // (which also left the context-sheet button dead on Android).
    final tokens = estimateChatMessageTokensSafe(
      m,
      readToolEvents: (_) =>
          throw const ChatStorageNotLoadedException('tool events'),
    );
    expect(tokens, estimateChatMessageTokens(m, toolEvents: const []));

    // Loaded bodies are used when the reader succeeds.
    final loaded = estimateChatMessageTokensSafe(
      m,
      readToolEvents: (_) => [
        {'arguments': <String, dynamic>{'x': 'y' * 300}, 'content': 'r' * 300},
      ],
    );
    expect(loaded, greaterThan(tokens));

    // Replay disabled → the reader is never consulted.
    expect(estimateChatMessageTokensSafe(m, readToolEvents: null), tokens);
  });

  test('compactTokenText matches AnyBuff formatTokens', () {
    expect(compactTokenText(999), '999');
    expect(compactTokenText(1000), '1.0k');
    expect(compactTokenText(12345), '12.3k');
    expect(compactTokenText(999999), '1000.0k');
    expect(compactTokenText(1000000), '1.0M');
    expect(compactTokenText(1234567), '1.2M');
  });

  test('snapshot ratio clamps for the ring but not the badge', () {
    const over = ContextUsageSnapshot(
      usedTokens: 300000,
      maxTokens: 200000,
      measured: true,
      estimated: false,
    );
    expect(over.rawRatio, 1.5);
    expect(over.ratio, 1.0);
    expect(over.displayPercent, 150);

    const under = ContextUsageSnapshot(
      usedTokens: 250000,
      maxTokens: 200000,
      measured: true,
      estimated: false,
    );
    expect(under.displayPercent, 125);
  });

  test('contextUsageResultIsCurrent guards epoch/conversation/model', () {
    const key = (providerKey: 'prov-a', modelId: 'model-a');
    const otherKey = (providerKey: 'prov-a', modelId: 'model-b');

    // Current.
    expect(
      contextUsageResultIsCurrent(
        epoch: 1,
        currentEpoch: 1,
        currentConversationId: 'conv-1',
        resultConversationId: 'conv-1',
        currentModelKey: key,
        resultModelKey: key,
      ),
      isTrue,
    );
    // Stale epoch (a newer refresh already started).
    expect(
      contextUsageResultIsCurrent(
        epoch: 1,
        currentEpoch: 2,
        currentConversationId: 'conv-1',
        resultConversationId: 'conv-1',
        currentModelKey: key,
        resultModelKey: key,
      ),
      isFalse,
    );
    // Conversation switched during the lookup.
    expect(
      contextUsageResultIsCurrent(
        epoch: 1,
        currentEpoch: 1,
        currentConversationId: 'conv-2',
        resultConversationId: 'conv-1',
        currentModelKey: key,
        resultModelKey: key,
      ),
      isFalse,
    );
    // No conversation anymore.
    expect(
      contextUsageResultIsCurrent(
        epoch: 1,
        currentEpoch: 1,
        currentConversationId: null,
        resultConversationId: 'conv-1',
        currentModelKey: key,
        resultModelKey: key,
      ),
      isFalse,
    );
    // Model switched during the lookup.
    expect(
      contextUsageResultIsCurrent(
        epoch: 1,
        currentEpoch: 1,
        currentConversationId: 'conv-1',
        resultConversationId: 'conv-1',
        currentModelKey: otherKey,
        resultModelKey: key,
      ),
      isFalse,
    );
    // Effective model disappeared.
    expect(
      contextUsageResultIsCurrent(
        epoch: 1,
        currentEpoch: 1,
        currentConversationId: 'conv-1',
        resultConversationId: 'conv-1',
        currentModelKey: null,
        resultModelKey: key,
      ),
      isFalse,
    );
  });

  test('snapshot equality drives ValueNotifier notifications', () {
    const a = ContextUsageSnapshot(
      usedTokens: 100,
      maxTokens: 200,
      measured: true,
      estimated: false,
    );
    const b = ContextUsageSnapshot(
      usedTokens: 100,
      maxTokens: 200,
      measured: true,
      estimated: false,
    );
    const c = ContextUsageSnapshot(
      usedTokens: 100,
      maxTokens: 300,
      measured: true,
      estimated: false,
    );
    expect(a, equals(b));
    expect(a, isNot(equals(c)));
  });
}
