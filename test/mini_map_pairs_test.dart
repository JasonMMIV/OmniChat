import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/models/chat_message.dart';
import 'package:OmniChat/features/home/utils/mini_map_pairs.dart';

ChatMessage _message(String id, String role, String content) {
  return ChatMessage(
    id: id,
    role: role,
    content: content,
    conversationId: 'c1',
  );
}

void main() {
  group('miniMapToOneLine', () {
    test('strips thinking blocks, media markers, newlines and extra spaces', () {
      const input =
          '  before <think>hidden</think> mid\n[image:a.png] [file:b.pdf] after  ';
      expect(miniMapToOneLine(input), 'before mid after');
    });

    test('is case-insensitive for thinking tags', () {
      expect(miniMapToOneLine('a<THOUGHT>x</THOUGHT>b'), 'ab');
    });

    test('keeps plain text unchanged', () {
      expect(miniMapToOneLine('hello world'), 'hello world');
    });
  });

  group('buildMiniMapPairs', () {
    test('pairs a user with the following assistant', () {
      final pairs = buildMiniMapPairs([
        _message('u1', 'user', 'hi'),
        _message('a1', 'assistant', 'hello'),
      ]);

      expect(pairs, hasLength(1));
      expect(pairs.single.user?.id, 'u1');
      expect(pairs.single.assistant?.id, 'a1');
    });

    test('keeps a trailing user without an assistant', () {
      final pairs = buildMiniMapPairs([_message('u1', 'user', 'hi')]);

      expect(pairs, hasLength(1));
      expect(pairs.single.user?.id, 'u1');
      expect(pairs.single.assistant, isNull);
    });

    test('keeps orphan assistants and ignores system/tool messages', () {
      final pairs = buildMiniMapPairs([
        _message('a1', 'assistant', 'hello'),
        _message('s1', 'system', 'system'),
        _message('t1', 'tool', 'tool'),
      ]);

      expect(pairs, hasLength(1));
      expect(pairs.single.user, isNull);
      expect(pairs.single.assistant?.id, 'a1');
    });

    test('flushes a pending user when another user arrives', () {
      final pairs = buildMiniMapPairs([
        _message('u1', 'user', 'one'),
        _message('u2', 'user', 'two'),
        _message('a1', 'assistant', 'answer'),
      ]);

      expect(pairs.map((pair) => pair.user?.id), ['u1', 'u2']);
      expect(pairs.last.assistant?.id, 'a1');
    });
  });
}
