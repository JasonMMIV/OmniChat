// 過程收褶 (process folding, 2026-10-05): the process-group end stamp is a
// persisted ChatMessage field (Hive field 20) because the group header's
// elapsed timer must still show the real span after a reload — freezing at
// `reasoningFinishedAt` would rewind a message whose tools ran long after its
// thinking stopped. These tests pin the persistence contract: JSON
// round-trip (conversation export/import shares toJson/fromJson), copyWith,
// and the legacy-null default.
import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/core/models/chat_message.dart';

void main() {
  group('ChatMessage.processFinishedAt', () {
    final base = ChatMessage(
      role: 'assistant',
      content: 'answer',
      conversationId: 'c1',
    );

    test('defaults to null (legacy rows have no process stamp)', () {
      expect(base.processFinishedAt, isNull);
      expect(base.toJson()['processFinishedAt'], isNull);
      expect(ChatMessage.fromJson(base.toJson()).processFinishedAt, isNull);
    });

    test('round-trips through toJson/fromJson', () {
      final stamp = DateTime.utc(2026, 10, 5, 9, 0, 12);
      final message = base.copyWith(
        reasoningStartAt: DateTime.utc(2026, 10, 5, 9),
        reasoningFinishedAt: DateTime.utc(2026, 10, 5, 9, 0, 2),
        processFinishedAt: stamp,
      );

      final restored = ChatMessage.fromJson(message.toJson());
      expect(restored.processFinishedAt, stamp);
      // The thinking end keeps its own meaning — the two must not collapse.
      expect(restored.reasoningFinishedAt, DateTime.utc(2026, 10, 5, 9, 0, 2));
      expect(
        restored.processFinishedAt!.isAfter(restored.reasoningFinishedAt!),
        isTrue,
      );
    });

    test('copyWith keeps the existing stamp when the argument is omitted', () {
      final stamp = DateTime.utc(2026, 10, 5, 9, 0, 12);
      final message = base.copyWith(processFinishedAt: stamp);
      expect(message.copyWith(content: 'edited').processFinishedAt, stamp);
    });
  });

  group('ChatMessage.processStartedAt', () {
    final base = ChatMessage(
      role: 'assistant',
      content: 'answer',
      conversationId: 'c1',
    );

    test('defaults to null (legacy rows have no process start)', () {
      expect(base.processStartedAt, isNull);
      expect(ChatMessage.fromJson(base.toJson()).processStartedAt, isNull);
    });

    test('a tool-only turn round-trips a start with no reasoning timestamps', () {
      final stamp = DateTime.utc(2026, 10, 5, 8, 59, 30);
      final message = base.copyWith(processStartedAt: stamp);
      final restored = ChatMessage.fromJson(message.toJson());
      expect(restored.processStartedAt, stamp);
      expect(restored.reasoningStartAt, isNull);
      expect(restored.reasoningText, isNull);
    });
  });
}
