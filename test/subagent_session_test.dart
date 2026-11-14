import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/services/agent/subagent_session_store.dart';

void main() {
  SubagentSession session(
    String id,
    String conversationId, {
    String profileId = 'general',
  }) => SubagentSession(
    id: id,
    conversationId: conversationId,
    profileId: profileId,
    messages: [
      {'role': 'system', 'content': 'sys'},
      {'role': 'user', 'content': 'Task:\n$id'},
    ],
  );

  group('SubagentSessionStore (P1-3)', () {
    test('put/get returns the session for its own conversation only', () {
      final store = SubagentSessionStore();
      store.put(session('s1', 'c1'));
      expect(store.get('s1', 'c1')?.id, 's1');
      expect(store.get('s1', 'c2'), isNull);
      expect(store.get('', 'c1'), isNull);
    });

    test('LRU evicts the oldest entry beyond the ceiling', () {
      final store = SubagentSessionStore(maxEntries: 2);
      store.put(session('a', 'c'));
      store.put(session('b', 'c'));
      expect(store.get('a', 'c'), isNotNull); // touch a
      store.put(session('d', 'c'));
      expect(store.get('b', 'c'), isNull);
      expect(store.get('a', 'c'), isNotNull);
      expect(store.get('d', 'c'), isNotNull);
    });

    test('TTL expires idle sessions on access', () {
      var now = DateTime(2026, 1, 1, 12);
      final store = SubagentSessionStore(
        ttl: const Duration(minutes: 30),
        clock: () => now,
      );
      store.put(session('s', 'c'));
      now = now.add(const Duration(minutes: 29));
      expect(store.get('s', 'c'), isNotNull);
      now = now.add(const Duration(minutes: 2));
      expect(store.get('s', 'c'), isNull);
      expect(store.length, 0);
    });

    test('clearConversation drops only that conversation', () {
      final store = SubagentSessionStore();
      store.put(session('a', 'c1'));
      store.put(session('b', 'c2'));
      store.clearConversation('c1');
      expect(store.get('a', 'c1'), isNull);
      expect(store.get('b', 'c2'), isNotNull);
    });

    test('a resume keeps the stored transcript and profile id', () {
      final store = SubagentSessionStore();
      store.put(session('s', 'c', profileId: 'explore'));
      final stored = store.get('s', 'c')!;
      expect(stored.profileId, 'explore');
      expect(stored.messages, hasLength(2));
      expect(stored.messages.first['role'], 'system');
    });
  });
}
