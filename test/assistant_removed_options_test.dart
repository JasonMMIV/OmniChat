// Contract test for the advanced options removed from the project (assistant)
// settings page on 2026-10: 溫度 / Top-p / 上下文訊息數量 / 最大 Token 數 / 串流輸出.
//
// The model fields and their JSON keys stay (backup + third-party importer
// shape compatibility) but `Assistant.fromJson` must always yield the default,
// so values persisted by an older build cannot keep acting invisibly.
// `thinkingBudget` is deliberately excluded: the chat page's reasoning control
// still writes it and must survive a restart.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/models/assistant.dart';

void main() {
  group('Assistant removed advanced options', () {
    test('legacy persisted values reset to defaults on load', () {
      final a = Assistant.fromJson({
        'id': 'a',
        'name': 'A',
        'temperature': 1.7,
        'topP': 0.9,
        'maxTokens': 42,
        'streamOutput': false,
        'contextMessageSize': 8,
        'limitContextMessages': true,
      });

      expect(a.temperature, isNull, reason: 'temperature no longer configurable');
      expect(a.topP, isNull, reason: 'top-p no longer configurable');
      expect(a.maxTokens, isNull, reason: 'max tokens no longer configurable');
      expect(a.streamOutput, isTrue, reason: 'streaming falls back to on');
      expect(a.contextMessageSize, 64);
      expect(a.limitContextMessages, isFalse, reason: 'history trim stays off');
    });

    test('entries without the keys load the same defaults', () {
      final a = Assistant.fromJson({'id': 'a', 'name': 'A'});

      expect(a.temperature, isNull);
      expect(a.topP, isNull);
      expect(a.maxTokens, isNull);
      expect(a.streamOutput, isTrue);
      expect(a.contextMessageSize, 64);
      expect(a.limitContextMessages, isFalse);
    });

    test('thinkingBudget still round-trips (chat page reasoning control)', () {
      final a = Assistant.fromJson({
        'id': 'a',
        'name': 'A',
        'thinkingBudget': 32000,
      });

      expect(a.thinkingBudget, 32000);
      expect(a.copyWith(thinkingBudget: 0).thinkingBudget, 0);
      expect(a.copyWith(clearThinkingBudget: true).thinkingBudget, isNull);
    });

    test('new assistants carry no sampling overrides', () {
      const a = Assistant(id: 'a', name: 'A');

      expect(a.temperature, isNull);
      expect(a.topP, isNull);
      expect(a.maxTokens, isNull);
      expect(a.streamOutput, isTrue);
      expect(a.limitContextMessages, isFalse);
    });
  });
}
