import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/models/chat_message.dart';
import 'package:OmniChat/features/home/services/context_usage_service.dart';

void main() {
  test('helper tokens stay out of the context ring', () {
    final measured = ChatMessage(
      id: 'a1',
      role: 'assistant',
      content: 'answer',
      conversationId: 'c1',
      modelId: 'm1',
      providerId: 'p1',
      promptTokens: 1000,
      completionTokens: 100,
      totalTokens: 5000,
      // The message-level total includes helper usage, but the ring must use
      // the measured prompt baseline only.
    );

    final snapshot = computeContextUsage(
      rawMessages: [measured],
      versionSelections: const {},
      truncateIndex: 0,
      compactBeforeIndex: 0,
      enableAutoCompaction: true,
      learnedWindowTokens: 10000,
      catalogWindowTokens: 10000,
      userWindowTokens: null,
      currentModelId: 'm1',
      currentProviderKey: 'p1',
      streamingMessageId: null,
      collapseVersions: (items, selections) => items,
      estimateMessageTokens: (_) => 0,
      estimateCompactedHeadTokens: (_) => 0,
    );

    expect(snapshot.measured, isTrue);
    expect(snapshot.usedTokens, 1100);
    expect(snapshot.usedTokens, isNot(5000));
    expect(snapshot.maxTokens, 10000);
  });
}
