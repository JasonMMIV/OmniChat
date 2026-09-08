// P1-3 ask_user + write_todos unit tests (IMPORT_PLAN_COWORK.md P1-3).
//
// Covers the pure-Dart data discipline ported from kelivo
// `ask_user_input_v0`: argument normalization limits, the structured answer
// payload, the pending/answer content protocol, and the todo snapshot
// normalization/rendering used by the plan card and system-prompt injection.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/services/chat/ask_user_models.dart';
import 'package:OmniChat/core/services/chat/todo_service.dart';

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

  group('write_todos normalization', () {
    test('normalizes statuses and drops empty content', () {
      final todos = normalizeTodoItems([
        {'content': 'Step one', 'status': 'in_progress'},
        {'content': 'Step two', 'status': 'completed'},
        {'content': 'Step three', 'status': 'bogus'},
        {'content': '   ', 'status': 'pending'},
        {'task': 'alias task', 'status': 'pending'},
      ]);
      expect(todos.length, equals(4));
      expect(todos[0].isInProgress, isTrue);
      expect(todos[1].isCompleted, isTrue);
      expect(todos[2].status, equals(todoStatusPending));
      expect(todos[3].content, equals('alias task'));
    });

    test('caps list at maxItems and ignores non-maps', () {
      final todos = normalizeTodoItems([
        for (var i = 0; i < 60; i++) {'content': 't$i', 'status': 'pending'},
        'nope',
      ], maxItems: 50);
      expect(todos.length, equals(50));
    });

    test('invalid input yields empty list', () {
      expect(normalizeTodoItems(null), isEmpty);
      expect(normalizeTodoItems('x'), isEmpty);
    });
  });

  group('todo snapshot rendering', () {
    test('renders stable marker format', () {
      final todos = normalizeTodoItems([
        {'content': 'A', 'status': 'completed'},
        {'content': 'B', 'status': 'in_progress'},
        {'content': 'C', 'status': 'pending'},
      ]);
      final out = renderTodoSnapshot(todos);
      expect(out, contains('[x] A'));
      expect(out, contains('[~] B'));
      expect(out, contains('[ ] C'));
      expect(out, contains('<current_todo_list>'));
      expect(out, contains('</current_todo_list>'));
    });

    test('empty list renders empty string', () {
      expect(renderTodoSnapshot(const []), isEmpty);
    });
  });
}