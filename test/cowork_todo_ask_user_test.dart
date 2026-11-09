// P1-3 ask_user unit tests (IMPORT_PLAN_COWORK.md P1-3).
//
// Covers the pure-Dart data discipline ported from kelivo
// `ask_user_input_v0`: argument normalization limits and the structured
// answer / pending content protocol. The `write_todos` parser / projection /
// card coverage moved to test/core/services/chat/todo_parser_test.dart,
// todo_projection_test.dart and test/features/chat/widgets/
// todo_plan_card_test.dart (docs/write_todos_improvement_plan.md).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/services/chat/ask_user_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('ask_user normalization', () {
    test('caps questions at 4 and options at 4', () {
      final raw = [
        for (var i = 1; i <= 6; i++)
          {
            'question': 'Q$i',
            'kind': 'single',
            'options': [for (var j = 1; j <= 6; j++) 'opt$j'],
          },
      ];
      final questions = normalizeAskUserQuestions(raw);
      expect(questions.length, equals(askUserMaxQuestions));
      for (final q in questions) {
        expect(q.options.length, equals(askUserMaxOptions));
      }
    });

    test('drops empties and reindexes ids q1..qN', () {
      final questions = normalizeAskUserQuestions([
        {'question': '   ', 'kind': 'single', 'options': ['a']},
        {'question': 'Keep me', 'kind': 'multi', 'options': ['a', 'b']},
        'not-a-map',
      ]);
      expect(questions.length, equals(1));
      expect(questions[0].id, equals('q1'));
      expect(questions[0].kind, equals('multi'));
    });

    test('invalid input yields empty list', () {
      expect(normalizeAskUserQuestions(null), isEmpty);
      expect(normalizeAskUserQuestions('x'), isEmpty);
    });
  });

  group('ask_user content protocol', () {
    test('pending content round-trips questions', () {
      final questions = normalizeAskUserQuestions([
        {'question': 'Which stack?', 'kind': 'single', 'options': ['A', 'B']},
      ]);
      final json = buildAskUserPendingContent(questions);
      final parsed = parseAskUserContent(json);
      expect(parsed, isNotNull);
      expect(parsed!['type'], equals(askUserPendingType));
      final restored = questionsFromPendingContent(parsed!);
      expect(restored.length, equals(1));
      expect(restored[0].question, equals('Which stack?'));
      expect(restored[0].options, equals(['A', 'B']));
    });

    test('answer content round-trips entries', () {
      final answers = [
        AskUserAnswerEntry(
          id: 'q1',
          question: 'Which stack?',
          selected: ['A'],
          other: '',
          skipped: false,
        ),
        AskUserAnswerEntry(
          id: 'q2',
          question: 'Skip me?',
          selected: const [],
          other: '',
          skipped: true,
        ),
      ];
      final json = buildAskUserAnswerContent(answers);
      final parsed = parseAskUserContent(json);
      expect(parsed, isNotNull);
      expect(parsed!['type'], equals(askUserAnswerType));
      final restored = answersFromAnswerContent(parsed!);
      expect(restored.length, equals(2));
      expect(restored[0].toDisplayText(), equals('A'));
      expect(restored[1].skipped, isTrue);
      expect(restored[1].toDisplayText(), equals('(skipped)'));
    });

    test('non-ask_user content parses to null', () {
      expect(parseAskUserContent(null), isNull);
      expect(parseAskUserContent(''), isNull);
      expect(parseAskUserContent('{"type":"other"}'), isNull);
      expect(parseAskUserContent('not json'), isNull);
    });
  });
}