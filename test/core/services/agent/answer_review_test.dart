// Answer Review v1 — pure logic tests (docs/answer_review_plan.md §11.1).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/core/models/answer_review.dart';
import 'package:OmniChat/core/models/message_usage.dart';
import 'package:OmniChat/core/models/token_usage.dart';
import 'package:OmniChat/core/services/agent/answer_review.dart';

Map<String, dynamic> _issue(
  String severity, {
  String location = 'p1',
  String problem = 'wrong',
  String fix = 'fix it',
}) => <String, dynamic>{
  'severity': severity,
  'location': location,
  'problem': problem,
  'fix': fix,
};

void main() {
  // ------------------------------------------------------------------
  // AnswerReviewModeCodec
  // ------------------------------------------------------------------
  group('AnswerReviewModeCodec', () {
    test('parses the three persisted values', () {
      expect(AnswerReviewModeCodec.fromValue('off'), AnswerReviewMode.off);
      expect(AnswerReviewModeCodec.fromValue('smart'), AnswerReviewMode.smart);
      expect(
        AnswerReviewModeCodec.fromValue('always'),
        AnswerReviewMode.always,
      );
    });

    test('null / unknown values fall back to off', () {
      expect(AnswerReviewModeCodec.fromValue(null), AnswerReviewMode.off);
      expect(AnswerReviewModeCodec.fromValue('bogus'), AnswerReviewMode.off);
      expect(AnswerReviewModeCodec.fromValue(''), AnswerReviewMode.off);
    });

    test('round-trips through value', () {
      for (final mode in AnswerReviewMode.values) {
        expect(AnswerReviewModeCodec.fromValue(mode.value), mode);
      }
    });
  });

  // ------------------------------------------------------------------
  // Smart gate
  // ------------------------------------------------------------------
  group('shouldReviewDraft', () {
    test('off never reviews', () {
      expect(
        shouldReviewDraft(
          mode: AnswerReviewMode.off,
          draft: 'a' * 5000,
          executedCallCount: 5,
        ),
        isFalse,
      );
    });

    test('always reviews any non-empty draft, skips empty', () {
      expect(
        shouldReviewDraft(
          mode: AnswerReviewMode.always,
          draft: 'ok',
          executedCallCount: 0,
        ),
        isTrue,
      );
      expect(
        shouldReviewDraft(
          mode: AnswerReviewMode.always,
          draft: '   \n  ',
          executedCallCount: 3,
        ),
        isFalse,
      );
    });

    test('smart triggers on tool results', () {
      expect(
        shouldReviewDraft(
          mode: AnswerReviewMode.smart,
          draft: 'ok',
          executedCallCount: 1,
        ),
        isTrue,
      );
    });

    test('smart triggers on long answers', () {
      expect(
        shouldReviewDraft(
          mode: AnswerReviewMode.smart,
          draft: 'a' * 600,
          executedCallCount: 0,
        ),
        isTrue,
      );
      expect(
        shouldReviewDraft(
          mode: AnswerReviewMode.smart,
          draft: 'a' * 599,
          executedCallCount: 0,
        ),
        isFalse,
      );
    });

    test('smart triggers on code fences, URLs and percentages', () {
      final prefix = 'a' * 200;
      expect(
        shouldReviewDraft(
          mode: AnswerReviewMode.smart,
          draft: '```dart\nx\n```',
          executedCallCount: 0,
        ),
        isTrue,
      );
      expect(
        shouldReviewDraft(
          mode: AnswerReviewMode.smart,
          draft: 'see https://example.com/docs',
          executedCallCount: 0,
        ),
        isTrue,
      );
      expect(
        shouldReviewDraft(
          mode: AnswerReviewMode.smart,
          draft: '$prefix growth 50%',
          executedCallCount: 0,
        ),
        isTrue,
      );
      expect(
        shouldReviewDraft(
          mode: AnswerReviewMode.smart,
          draft: '$prefix with 12 and 34 numbers',
          executedCallCount: 0,
        ),
        isTrue,
      );
    });

    test('smart skips short greetings and pure tone replies', () {
      expect(
        shouldReviewDraft(
          mode: AnswerReviewMode.smart,
          draft: '好的！',
          executedCallCount: 0,
        ),
        isFalse,
      );
      expect(
        shouldReviewDraft(
          mode: AnswerReviewMode.smart,
          draft: '哈哈，这真是太棒了！！！',
          executedCallCount: 0,
        ),
        isFalse,
      );
    });
  });

  // ------------------------------------------------------------------
  // Verdict parser
  // ------------------------------------------------------------------
  group('parseReviewVerdict', () {
    test('pure JSON pass', () {
      final v = parseReviewVerdict('{"verdict":"pass","issues":[]}');
      expect(v.verdict, 'pass');
      expect(v.issues, isEmpty);
      expect(v.parsed, isTrue);
    });

    test('pure JSON revise with blocker', () {
      final v = parseReviewVerdict(
        jsonEncode(<String, dynamic>{
          'verdict': 'revise',
          'issues': [_issue('blocker')],
        }),
      );
      expect(v.verdict, 'revise');
      expect(v.hasBlockingIssues, isTrue);
      expect(v.blockingIssuesJson(), contains('blocker'));
    });

    test('code-fenced JSON parses', () {
      final v = parseReviewVerdict(
        '```json\n{"verdict":"revise","issues":[{"severity":"major","location":"l","problem":"p","fix":"f"}]}\n```',
      );
      expect(v.verdict, 'revise');
      expect(v.issues.single.severity, 'major');
    });

    test('JSON embedded in prose parses', () {
      final v = parseReviewVerdict(
        'Here is my review:\n{"verdict":"pass","issues":[]}\nThanks.',
      );
      expect(v.verdict, 'pass');
      expect(v.parsed, isTrue);
    });

    test('severity gate: pass verdict with blocker revises', () {
      final v = parseReviewVerdict(
        jsonEncode(<String, dynamic>{
          'verdict': 'pass',
          'issues': [_issue('blocker')],
        }),
      );
      expect(v.verdict, 'revise');
    });

    test('severity gate: revise verdict with minor-only passes', () {
      final v = parseReviewVerdict(
        jsonEncode(<String, dynamic>{
          'verdict': 'revise',
          'issues': [_issue('minor')],
        }),
      );
      expect(v.verdict, 'pass');
      expect(v.issues, hasLength(1));
    });

    test('tool-dependent finding is dropped (revision cannot call tools)', () {
      final v = parseReviewVerdict(
        jsonEncode(<String, dynamic>{
          'verdict': 'revise',
          'issues': [
            _issue(
              'major',
              problem: 'Draft has no image.',
              fix: 'Use image_search and insert the photo.',
            ),
          ],
        }),
      );
      expect(v.verdict, 'pass');
      expect(v.issues, isEmpty);
    });
    test('Chinese image_search finding is dropped', () {
      final v = parseReviewVerdict(
        jsonEncode(<String, dynamic>{
          'verdict': 'revise',
          'issues': [
            _issue(
              'major',
              problem: '草稿全篇沒有任何圖片。',
              fix: '使用 image_search 取得照片並插入 1–2 張圖片。',
            ),
          ],
        }),
      );
      expect(v.verdict, 'pass');
      expect(v.issues, isEmpty);
    });

    test(
      'tool-dependent finding is dropped but text findings still revise',
      () {
        final v = parseReviewVerdict(
          jsonEncode(<String, dynamic>{
            'verdict': 'revise',
            'issues': [
              _issue(
                'major',
                problem: 'Missing image.',
                fix: 'Call image_search.',
              ),
              _issue(
                'major',
                problem: 'Wrong date.',
                fix: 'Change 2020 to 2021.',
              ),
            ],
          }),
        );
        expect(v.verdict, 'revise');
        expect(v.issues, hasLength(1));
        expect(v.issues.single.problem, 'Wrong date.');
      },
    );

    test('plain-text REVISE without issues stays pass (fail-open)', () {
      final v = parseReviewVerdict('I would REVISE this answer.');
      expect(v.verdict, 'pass');
      expect(v.issues, isEmpty);
      expect(v.parsed, isFalse);
    });

    test('malformed text fails open as pass', () {
      final v = parseReviewVerdict(
        'I think the answer is mostly fine, but maybe check the numbers.',
      );
      expect(v.verdict, 'pass');
      expect(v.parsed, isFalse);
    });

    test('unknown severity parses conservative as major', () {
      final v = parseReviewVerdict(
        jsonEncode(<String, dynamic>{
          'verdict': 'revise',
          'issues': [_issue('catastrophic')],
        }),
      );
      expect(v.issues.single.severity, 'major');
      expect(v.verdict, 'revise');
    });

    test('issues are capped at 6 and fields truncated', () {
      final issues = List.generate(
        9,
        (i) => _issue('blocker', location: 'l' * 400, problem: 'p' * 400),
      );
      final v = parseReviewVerdict(
        jsonEncode(<String, dynamic>{'verdict': 'revise', 'issues': issues}),
      );
      expect(v.issues, hasLength(6));
      expect(v.issues.first.location.length, kAnswerReviewMaxLocationChars);
      expect(v.issues.first.problem.length, kAnswerReviewMaxProblemChars);
    });

    test('huge raw responses are truncated before parsing', () {
      final huge =
          '{"verdict":"pass","issues":[]}${'x' * (kAnswerReviewMaxRawChars + 500)}';
      final v = parseReviewVerdict(huge);
      // Truncation keeps the leading JSON object parseable.
      expect(v.verdict, 'pass');
      expect(v.parsed, isTrue);
    });
  });

  group('containsToolCallMarkup', () {
    test('detects DeepSeek DSML and tagged tool-call syntax', () {
      expect(
        containsToolCallMarkup(
          '<｜｜DSML｜｜ calls>\n<｜｜DSML｜｜ invoke name="image_search">',
        ),
        isTrue,
      );
      expect(
        containsToolCallMarkup('<tool_call>\n<function=image_search>'),
        isTrue,
      );
      expect(containsToolCallMarkup('regular answer text'), isFalse);
      expect(containsToolCallMarkup(''), isFalse);
    });
  });

  // ------------------------------------------------------------------
  // Turn builders
  // ------------------------------------------------------------------
  group('buildReviewTurn / buildRevisionTurn', () {
    test('merges into a trailing user message (String content)', () {
      final working = <Map<String, dynamic>>[
        <String, dynamic>{'role': 'system', 'content': 'sys'},
        <String, dynamic>{'role': 'user', 'content': 'question'},
      ];
      final turn = buildReviewTurn(working: working, draft: 'my draft');
      expect(turn, hasLength(2));
      // No consecutive user messages: instruction merged into the last one.
      expect(turn.last['role'], 'user');
      expect(turn.last['content'], contains('question'));
      expect(turn.last['content'], contains('[ANSWER REVIEW'));
      expect(turn.last['content'], contains('<draft>\nmy draft\n</draft>'));
      // The original working list is untouched.
      expect(working.last['content'], 'question');
    });

    test('merges into a trailing user message (List content)', () {
      final working = <Map<String, dynamic>>[
        <String, dynamic>{
          'role': 'user',
          'content': <Map<String, dynamic>>[
            <String, dynamic>{'type': 'text', 'text': 'look at this'},
            <String, dynamic>{
              'type': 'image_url',
              'image_url': <String, dynamic>{'url': 'file:///x.png'},
            },
          ],
        },
      ];
      final turn = buildReviewTurn(working: working, draft: 'draft');
      final content = turn.last['content'] as List;
      expect(content, hasLength(3));
      expect((content.last as Map)['type'], 'text');
      expect(
        ((content.last as Map)['text'] as String),
        contains('[ANSWER REVIEW'),
      );
      expect((content.first as Map)['type'], 'text');
    });

    test('appends a user message after a tool result', () {
      final working = <Map<String, dynamic>>[
        <String, dynamic>{'role': 'user', 'content': 'q'},
        <String, dynamic>{
          'role': 'tool',
          'tool_call_id': 'c1',
          'content': 'result',
        },
      ];
      final turn = buildReviewTurn(working: working, draft: 'd');
      expect(turn, hasLength(3));
      expect(turn.last['role'], 'user');
      expect(turn.last['content'], contains('[ANSWER REVIEW'));
    });

    test('empty working list gets a fresh user message', () {
      final turn = buildReviewTurn(
        working: <Map<String, dynamic>>[],
        draft: 'd',
      );
      expect(turn, hasLength(1));
      expect(turn.single['role'], 'user');
    });

    test('revision turn carries draft and issues JSON', () {
      final turn = buildRevisionTurn(
        working: <Map<String, dynamic>>[],
        draft: 'my draft',
        issuesJson: '[{"severity":"blocker"}]',
      );
      final text = turn.single['content'] as String;
      expect(text, contains('[ANSWER REVISION'));
      expect(text, contains('<draft>\nmy draft\n</draft>'));
      expect(text, contains('[{"severity":"blocker"}]'));
    });
  });

  // ------------------------------------------------------------------
  // Extra-body sanitizer
  // ------------------------------------------------------------------
  group('sanitizeReviewExtraBody', () {
    test('strips tool / stream / request-shape keys, keeps reasoning', () {
      final out = sanitizeReviewExtraBody(<String, dynamic>{
        'tools': <dynamic>[],
        'tool_choice': 'auto',
        'stream': true,
        'model': 'should-not-override',
        'messages': <dynamic>[],
        'input': 'x',
        'reasoning_effort': 'high',
        'custom_field': 42,
      });
      expect(out, isNotNull);
      expect(out!.keys, <String>{'reasoning_effort', 'custom_field'});
      expect(out['reasoning_effort'], 'high');
    });

    test('null stays null', () {
      expect(sanitizeReviewExtraBody(null), isNull);
    });

    test('fully-stripped body yields an empty map', () {
      final out = sanitizeReviewExtraBody(<String, dynamic>{'stream': true});
      expect(out, isNotNull);
      expect(out, isEmpty);
    });
  });

  // ------------------------------------------------------------------
  // TokenUsage.sum
  // ------------------------------------------------------------------
  group('TokenUsage.sum', () {
    test('adds every column and accumulates message usage costs', () {
      const a = TokenUsage(
        promptTokens: 100,
        completionTokens: 50,
        cachedTokens: 10,
        totalTokens: 150,
        messageUsage: MessageUsage(costUsd: 0.01, inputTokens: 100),
      );
      const b = TokenUsage(
        promptTokens: 30,
        completionTokens: 20,
        cachedTokens: 5,
        totalTokens: 50,
        messageUsage: MessageUsage(costUsd: 0.02, inputTokens: 30),
      );
      final s = a.sum(b);
      expect(s.promptTokens, 130);
      expect(s.completionTokens, 70);
      expect(s.cachedTokens, 15);
      expect(s.totalTokens, 200);
      expect(s.messageUsage!.costUsd, closeTo(0.03, 1e-9));
      expect(s.messageUsage!.inputTokens, 130);
    });

    test('zero total falls back to prompt + completion', () {
      const a = TokenUsage(promptTokens: 10, completionTokens: 5);
      const b = TokenUsage(promptTokens: 1, completionTokens: 2);
      expect(a.sum(b).totalTokens, 18);
    });

    test('zero + zero stays zero and keeps null messageUsage', () {
      const a = TokenUsage();
      const b = TokenUsage();
      final s = a.sum(b);
      expect(s.totalTokens, 0);
      expect(s.messageUsage, isNull);
    });
  });
}
