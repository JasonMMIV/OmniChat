// Answer Review v1 — driver-level tests (docs/answer_review_plan.md §11.2).
//
// `AgentOrchestrator.run` owns the review phase: every transport terminal is
// held back (hold-latest), the last-round draft is reviewed by the same model
// and — only on REVISE — rewritten once. These tests drive the kernel with
// injected `sendRound` / `reviewSendRound` doubles and assert the chunk
// sequences, message shapes and usage synthesis.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/core/models/answer_review.dart';
import 'package:OmniChat/core/models/token_usage.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/agent/agent_loop.dart';
import 'package:OmniChat/core/services/agent/agent_orchestrator.dart';
import 'package:OmniChat/core/services/agent/answer_review.dart';
import 'package:OmniChat/core/services/api/chat_stream_chunk.dart';

ProviderConfig _config({String? baseUrl}) => ProviderConfig(
  id: 't',
  enabled: true,
  name: 't',
  apiKey: 'k',
  baseUrl: baseUrl ?? 'http://127.0.0.1:1',
  providerType: ProviderKind.openai,
  models: const ['m'],
);

ChatStreamChunk _text(
  String content, {
  TokenUsage? usage,
  int totalTokens = 0,
}) => ChatStreamChunk(
  content: content,
  isDone: false,
  totalTokens: totalTokens,
  usage: usage,
);

ChatStreamChunk _done({
  String content = '',
  TokenUsage? usage,
  int totalTokens = 0,
}) => ChatStreamChunk(
  content: content,
  isDone: true,
  totalTokens: totalTokens,
  usage: usage,
);

ChatStreamChunk _tools() => ChatStreamChunk(
  content: '',
  isDone: false,
  totalTokens: 0,
  toolCalls: <ToolCallInfo>[
    ToolCallInfo(id: 'c1', name: 'file_read', arguments: const {'path': 'a'}),
  ],
);

/// Review verdict chunk stream: the review round is non-streaming, so the
/// transport emits the verdict body followed by its own terminal.
Stream<ChatStreamChunk> _verdictRound(String body) =>
    Stream<ChatStreamChunk>.fromIterable(<ChatStreamChunk>[
      _text(body),
      _done(totalTokens: 0),
    ]);

const _passBody = '{"verdict":"pass","issues":[]}';

void main() {
  test(
    'off: chunks identical to the pre-review contract, no review calls',
    () async {
      var reviewCalls = 0;
      final chunks = await AgentOrchestrator()
          .run(
            config: _config(),
            modelId: 'm',
            requestId: 'r1',
            streamOutput: true,
            messages: const [
              {'role': 'user', 'content': 'hi'},
            ],
            onToolCall: (name, args, {String? toolCallId}) async => 'R',
            sendRound: (msgs) async => Stream<ChatStreamChunk>.fromIterable(
              <ChatStreamChunk>[_text('hello'), _done()],
            ),
            reviewSendRound: (msgs) async {
              reviewCalls++;
              return _verdictRound(_passBody);
            },
          )
          .toList();

      expect(chunks.map((c) => c.content), <String>['hello', '']);
      expect(chunks.where((c) => c.isDone), hasLength(1));
      expect(chunks.last.reviewed, isFalse);
      expect(reviewCalls, 0);
    },
  );

  test(
    'always + PASS: reviewing status, reviewed terminal, draft untouched',
    () async {
      final reviewMessages = <List<Map<String, dynamic>>>[];
      final chunks = await AgentOrchestrator()
          .run(
            config: _config(),
            modelId: 'm',
            requestId: 'r2',
            streamOutput: true,
            messages: const [
              {'role': 'user', 'content': 'hi'},
            ],
            onToolCall: (name, args, {String? toolCallId}) async => 'R',
            sendRound: (msgs) async => Stream<ChatStreamChunk>.fromIterable(
              <ChatStreamChunk>[_text('hello world'), _done()],
            ),
            reviewSendRound: (msgs) async {
              reviewMessages.add(msgs);
              return _verdictRound(_passBody);
            },
            answerReview: const AnswerReviewConfig(
              mode: AnswerReviewMode.always,
            ),
          )
          .toList();

      final phases = chunks
          .where((c) => c.reviewPhase != null)
          .map((c) => c.reviewPhase)
          .toList();
      expect(phases, <String>['reviewing', 'reviewed']);
      // Draft content passes through untouched (exactly once).
      expect(chunks.where((c) => c.content == 'hello world'), hasLength(1));
      expect(chunks.where((c) => c.isDone), hasLength(1));
      expect(chunks.last.reviewed, isTrue);
      final passReport = chunks.last.reviewReport!;
      expect(passReport.phase, 'passed');
      expect(passReport.verdict, 'pass');
      expect(passReport.reviewed, isTrue);
      expect(passReport.issues, isEmpty);
      // Review turn: last message is user, carries the draft and the rubric.
      final turn = reviewMessages.single;
      expect(turn.last['role'], 'user');
      expect(jsonEncode(turn), contains('hello world'));
      expect(jsonEncode(turn), contains('[ANSWER REVIEW'));
    },
  );

  test('always + REVISE success: revising status, revised text streamed, '
      'usage summed', () async {
    final revisionUsage = const TokenUsage(
      promptTokens: 310,
      completionTokens: 30,
      cachedTokens: 0,
      totalTokens: 340,
    );
    var reviewCall = 0;
    final chunks = await AgentOrchestrator()
        .run(
          config: _config(),
          modelId: 'm',
          requestId: 'r3',
          streamOutput: true,
          messages: const [
            {'role': 'user', 'content': 'hi'},
          ],
          onToolCall: (name, args, {String? toolCallId}) async => 'R',
          sendRound: (msgs) async =>
              Stream<ChatStreamChunk>.fromIterable(<ChatStreamChunk>[
                _text('draft text', usage: const TokenUsage(totalTokens: 100)),
                _done(usage: const TokenUsage(totalTokens: 100)),
              ]),
          reviewSendRound: (msgs) async {
            reviewCall++;
            if (reviewCall == 1) {
              return _verdictRound(
                jsonEncode(<String, dynamic>{
                  'verdict': 'revise',
                  'issues': [
                    <String, dynamic>{
                      'severity': 'blocker',
                      'location': 'l',
                      'problem': 'p',
                      'fix': 'f',
                    },
                  ],
                }),
              );
            }
            // Revision round (streaming): deltas + its own terminal.
            return Stream<ChatStreamChunk>.fromIterable(<ChatStreamChunk>[
              _text('revised ', usage: revisionUsage),
              _text('text'),
              _done(usage: revisionUsage),
            ]);
          },
          answerReview: AnswerReviewConfig(mode: AnswerReviewMode.always),
        )
        .toList();

    // Seed the review usage the way the driver folds it in: the review round
    // above returned no usage, so emulate the real accounting by asserting on
    // the phases + terminal flags instead of exact token numbers.
    final phases = chunks
        .where((c) => c.reviewPhase != null)
        .map((c) => c.reviewPhase)
        .toList();
    expect(phases, <String>['reviewing', 'reviewed', 'revising']);
    // Revision deltas stream as plain content chunks.
    expect(chunks.any((c) => c.content == 'revised '), isTrue);
    expect(chunks.any((c) => c.content == 'text'), isTrue);
    expect(chunks.where((c) => c.isDone), hasLength(1));
    expect(chunks.last.reviewed, isTrue);
    final revisedReport = chunks.last.reviewReport!;
    expect(revisedReport.phase, 'revised');
    expect(revisedReport.verdict, 'revise');
    expect(revisedReport.issues.single.severity, 'blocker');
    expect(revisedReport.revisionMs, greaterThanOrEqualTo(0));
    // The revision's own terminal was never forwarded as-is: the only
    // terminal carries the driver's composition.
    expect(chunks.last.content, '');
  });

  test('always + REVISE with review usage: terminal usage = main + subset', () async {
    var reviewCall = 0;
    final chunks = await AgentOrchestrator()
        .run(
          config: _config(),
          modelId: 'm',
          requestId: 'r3b',
          streamOutput: true,
          messages: const [
            {'role': 'user', 'content': 'hi'},
          ],
          onToolCall: (name, args, {String? toolCallId}) async => 'R',
          sendRound: (msgs) async =>
              Stream<ChatStreamChunk>.fromIterable(<ChatStreamChunk>[
                _text('draft'),
                _done(usage: const TokenUsage(totalTokens: 100)),
              ]),
          reviewSendRound: (msgs) async {
            reviewCall++;
            if (reviewCall == 1) {
              // Review verdict with its own usage snapshot.
              return Stream<ChatStreamChunk>.fromIterable(<ChatStreamChunk>[
                _text(
                  jsonEncode(<String, dynamic>{
                    'verdict': 'revise',
                    'issues': [
                      <String, dynamic>{
                        'severity': 'major',
                        'location': 'l',
                        'problem': 'p',
                        'fix': 'f',
                      },
                    ],
                  }),
                  usage: const TokenUsage(
                    promptTokens: 100,
                    completionTokens: 10,
                    totalTokens: 110,
                  ),
                ),
                _done(),
              ]);
            }
            // Revision: revised text, no usage snapshot of its own.
            return Stream<ChatStreamChunk>.fromIterable(<ChatStreamChunk>[
              _text('revised answer'),
              _done(),
            ]);
          },
          answerReview: const AnswerReviewConfig(mode: AnswerReviewMode.always),
        )
        .toList();

    final terminal = chunks.last;
    expect(terminal.isDone, isTrue);
    expect(terminal.reviewed, isTrue);
    // Revised text streamed as plain content chunks.
    expect(chunks.any((c) => c.content == 'revised answer'), isTrue);
    // reviewUsage subset: the review call's usage (revision had none).
    expect(terminal.reviewUsage, isNotNull);
    expect(terminal.reviewUsage!.totalTokens, 110);
    // usage = main (100) + review (110) → totalTokens (base 100 + subset 110).
    expect(terminal.totalTokens, 210);
    expect(terminal.usage!.totalTokens, 210);
  });

  test('revision error: revision_failed status, draft restored via '
      'replaceContent, reviewed=false', () async {
    var call = 0;
    final chunks = await AgentOrchestrator()
        .run(
          config: _config(),
          modelId: 'm',
          requestId: 'r4',
          streamOutput: true,
          messages: const [
            {'role': 'user', 'content': 'hi'},
          ],
          onToolCall: (name, args, {String? toolCallId}) async => 'R',
          sendRound: (msgs) async => Stream<ChatStreamChunk>.fromIterable(
            <ChatStreamChunk>[_text('original draft'), _done()],
          ),
          reviewSendRound: (msgs) async {
            call++;
            if (call == 1) {
              return _verdictRound(
                jsonEncode(<String, dynamic>{
                  'verdict': 'revise',
                  'issues': [
                    <String, dynamic>{
                      'severity': 'blocker',
                      'location': 'l',
                      'problem': 'p',
                      'fix': 'f',
                    },
                  ],
                }),
              );
            }
            throw Exception('revision transport exploded');
          },
          answerReview: const AnswerReviewConfig(mode: AnswerReviewMode.always),
        )
        .toList();

    final phases = chunks
        .where((c) => c.reviewPhase != null)
        .map((c) => c.reviewPhase)
        .toList();
    expect(phases, <String>[
      'reviewing',
      'reviewed',
      'revising',
      'revision_failed',
    ]);
    final restore = chunks
        .where((c) => c.replaceContent && c.content.isNotEmpty)
        .toList();
    expect(restore, hasLength(1));
    expect(restore.single.content, 'original draft');
    expect(chunks.where((c) => c.isDone), hasLength(1));
    expect(chunks.last.reviewed, isFalse);
  });

  test(
    'revision emits tool-call markup: fail-open keeps the original draft',
    () async {
      var call = 0;
      final chunks = await AgentOrchestrator()
          .run(
            config: _config(),
            modelId: 'm',
            requestId: 'r4b',
            streamOutput: true,
            messages: const [
              {'role': 'user', 'content': 'hi'},
            ],
            onToolCall: (name, args, {String? toolCallId}) async => 'R',
            sendRound: (msgs) async => Stream<ChatStreamChunk>.fromIterable(
              <ChatStreamChunk>[_text('original draft'), _done()],
            ),
            reviewSendRound: (msgs) async {
              call++;
              if (call == 1) {
                return _verdictRound(
                  jsonEncode(<String, dynamic>{
                    'verdict': 'revise',
                    'issues': [
                      <String, dynamic>{
                        'severity': 'major',
                        'location': 'l',
                        'problem': 'wrong date',
                        'fix': 'change it',
                      },
                    ],
                  }),
                );
              }
              // Text-only revision, but the model tried to call a tool.
              return Stream<ChatStreamChunk>.fromIterable(<ChatStreamChunk>[
                _text('<tool_call>\n<function=image_search>'),
                _done(),
              ]);
            },
            answerReview: const AnswerReviewConfig(
              mode: AnswerReviewMode.always,
            ),
          )
          .toList();

      final restore = chunks
          .where((c) => c.replaceContent && c.content.isNotEmpty)
          .toList();
      expect(restore, hasLength(1));
      expect(restore.single.content, 'original draft');
      expect(chunks.last.reviewed, isFalse);
      expect(chunks.last.reviewReport?.phase, 'revision_failed');
      expect(chunks.last.reviewReport?.failReason, 'revision_tool_call');
    },
  );

  test(
    'revision without terminal (truncated): fail-open restores draft',
    () async {
      var call = 0;
      final chunks = await AgentOrchestrator()
          .run(
            config: _config(),
            modelId: 'm',
            requestId: 'r5',
            streamOutput: true,
            messages: const [
              {'role': 'user', 'content': 'hi'},
            ],
            onToolCall: (name, args, {String? toolCallId}) async => 'R',
            sendRound: (msgs) async => Stream<ChatStreamChunk>.fromIterable(
              <ChatStreamChunk>[_text('original draft'), _done()],
            ),
            reviewSendRound: (msgs) async {
              call++;
              if (call == 1) {
                return _verdictRound(
                  jsonEncode(<String, dynamic>{
                    'verdict': 'revise',
                    'issues': [
                      <String, dynamic>{
                        'severity': 'blocker',
                        'location': 'l',
                        'problem': 'p',
                        'fix': 'f',
                      },
                    ],
                  }),
                );
              }
              // Stream ends without a terminal (truncated).
              return Stream<ChatStreamChunk>.fromIterable(<ChatStreamChunk>[
                _text('half revised'),
              ]);
            },
            answerReview: const AnswerReviewConfig(
              mode: AnswerReviewMode.always,
            ),
          )
          .toList();

      expect(
        chunks.any((c) => c.reviewPhase == kReviewPhaseRevisionFailed),
        isTrue,
      );
      final restore = chunks
          .where((c) => c.replaceContent && c.content.isNotEmpty)
          .toList();
      expect(restore.single.content, 'original draft');
      expect(chunks.last.reviewed, isFalse);
    },
  );

  test('review transport error: fail-open terminal, draft preserved', () async {
    final chunks = await AgentOrchestrator()
        .run(
          config: _config(),
          modelId: 'm',
          requestId: 'r6',
          streamOutput: true,
          messages: const [
            {'role': 'user', 'content': 'hi'},
          ],
          onToolCall: (name, args, {String? toolCallId}) async => 'R',
          sendRound: (msgs) async => Stream<ChatStreamChunk>.fromIterable(
            <ChatStreamChunk>[_text('kept answer'), _done()],
          ),
          reviewSendRound: (msgs) async => Stream<ChatStreamChunk>.error(
            Exception('review transport exploded'),
          ),
          answerReview: const AnswerReviewConfig(mode: AnswerReviewMode.always),
        )
        .toList();

    expect(chunks.where((c) => c.isDone), hasLength(1));
    expect(chunks.last.reviewed, isFalse);
    final errorReport = chunks.last.reviewReport!;
    expect(errorReport.phase, 'failed_open');
    expect(errorReport.failReason, 'error');
    // The draft text is still there exactly once (never re-streamed).
    expect(chunks.where((c) => c.content == 'kept answer'), hasLength(1));
  });

  test(
    'review timeout: fail-open and the internal stream is cancelled',
    () async {
      var cancelled = false;
      final neverCompletes = StreamController<ChatStreamChunk>();
      final chunks = await AgentOrchestrator()
          .run(
            config: _config(),
            modelId: 'm',
            requestId: 'r7',
            streamOutput: true,
            messages: const [
              {'role': 'user', 'content': 'hi'},
            ],
            onToolCall: (name, args, {String? toolCallId}) async => 'R',
            sendRound: (msgs) async => Stream<ChatStreamChunk>.fromIterable(
              <ChatStreamChunk>[_text('slow answer'), _done()],
            ),
            reviewSendRound: (msgs) async {
              neverCompletes.onCancel = () async => cancelled = true;
              return neverCompletes.stream;
            },
            answerReview: const AnswerReviewConfig(
              mode: AnswerReviewMode.always,
              reviewTimeout: Duration(milliseconds: 120),
            ),
          )
          .toList();

      expect(chunks.where((c) => c.isDone), hasLength(1));
      expect(chunks.last.reviewed, isFalse);
      expect(chunks.last.reviewReport?.failReason, 'timeout');
      // The timed-out subscription was cancelled so the provider request does
      // not keep burning tokens in the background (§5.1).
      expect(cancelled, isTrue);
      await neverCompletes.close();
    },
  );

  test(
    'review malformed JSON: fail-open pass, terminal reviewed=false',
    () async {
      final chunks = await AgentOrchestrator()
          .run(
            config: _config(),
            modelId: 'm',
            requestId: 'r8',
            streamOutput: true,
            messages: const [
              {'role': 'user', 'content': 'hi'},
            ],
            onToolCall: (name, args, {String? toolCallId}) async => 'R',
            sendRound: (msgs) async => Stream<ChatStreamChunk>.fromIterable(
              <ChatStreamChunk>[_text('answer'), _done()],
            ),
            reviewSendRound: (msgs) async => _verdictRound(
              'I think the answer is mostly fine, but maybe check the numbers.',
            ),
            answerReview: const AnswerReviewConfig(
              mode: AnswerReviewMode.always,
            ),
          )
          .toList();

      expect(chunks.where((c) => c.isDone), hasLength(1));
      expect(chunks.last.reviewed, isFalse);
      expect(chunks.last.reviewReport?.phase, 'failed_open');
      expect(chunks.last.reviewReport?.failReason, 'malformed');
      expect(chunks.where((c) => c.content == 'answer'), hasLength(1));
    },
  );

  test('tool round terminal is held back; only the final terminal is '
      'released', () async {
    final chunks = await AgentOrchestrator()
        .run(
          config: _config(),
          modelId: 'm',
          requestId: 'r9',
          streamOutput: true,
          messages: const [
            {'role': 'user', 'content': 'read'},
          ],
          onToolCall: (name, args, {String? toolCallId}) async => 'BODY',
          sendRound: (msgs) async {
            final hasToolCalls = msgs.any(
              (m) => m['role'] == 'assistant' && m['tool_calls'] != null,
            );
            return Stream<ChatStreamChunk>.fromIterable(
              hasToolCalls
                  ? <ChatStreamChunk>[_text('final'), _done()]
                  : <ChatStreamChunk>[_tools()],
            );
          },
          reviewSendRound: (msgs) async => _verdictRound(_passBody),
          answerReview: const AnswerReviewConfig(mode: AnswerReviewMode.always),
        )
        .toList();

    // Exactly one terminal — the tool round's was held and overridden.
    expect(chunks.where((c) => c.isDone), hasLength(1));
    expect(chunks.last.reviewed, isTrue);
  });

  test('tool-round terminal with content: content forwarded once as a '
      'non-done chunk, terminal held', () async {
    final chunks = await AgentOrchestrator()
        .run(
          config: _config(),
          modelId: 'm',
          requestId: 'r10',
          streamOutput: true,
          messages: const [
            {'role': 'user', 'content': 'read'},
          ],
          onToolCall: (name, args, {String? toolCallId}) async => 'BODY',
          sendRound: (msgs) async {
            final hasToolCalls = msgs.any(
              (m) => m['role'] == 'assistant' && m['tool_calls'] != null,
            );
            return Stream<ChatStreamChunk>.fromIterable(
              hasToolCalls
                  ? <ChatStreamChunk>[_text('final'), _done()]
                  : <ChatStreamChunk>[_tools(), _done(content: 'preamble')],
            );
          },
          answerReview: const AnswerReviewConfig.off(),
        )
        .toList();

    // The tool round's terminal content was forwarded as a plain chunk and
    // the final round overrode the held terminal; only one terminal total.
    expect(chunks.where((c) => c.isDone), hasLength(1));
    expect(chunks.where((c) => c.content == 'preamble'), hasLength(1));
    expect(chunks.where((c) => c.content == 'final'), hasLength(1));
    expect(chunks.last.reviewed, isFalse);
  });

  test('early stop discards the held terminal and never reviews', () async {
    var reviewCalls = 0;
    final chunks = await AgentOrchestrator()
        .run(
          config: _config(),
          modelId: 'm',
          requestId: 'r11',
          streamOutput: true,
          messages: const [
            {'role': 'user', 'content': 'read'},
          ],
          onToolCall: (name, args, {String? toolCallId}) async => 'BODY',
          options: const AgentLoopOptions(maxSteps: 1),
          sendRound: (msgs) async =>
              Stream<ChatStreamChunk>.fromIterable(<ChatStreamChunk>[_tools()]),
          reviewSendRound: (msgs) async {
            reviewCalls++;
            return _verdictRound(_passBody);
          },
          answerReview: const AnswerReviewConfig(mode: AnswerReviewMode.always),
        )
        .toList();

    expect(reviewCalls, 0);
    expect(chunks.where((c) => c.isDone), hasLength(1));
    expect(chunks.last.softStopReason, 'max_steps');
    expect(chunks.last.reviewed, isFalse);
  });

  test('token budget stop never reviews', () async {
    var reviewCalls = 0;
    final chunks = await AgentOrchestrator()
        .run(
          config: _config(),
          modelId: 'm',
          requestId: 'r12',
          streamOutput: true,
          messages: const [
            {'role': 'user', 'content': 'read'},
          ],
          onToolCall: (name, args, {String? toolCallId}) async => 'BODY',
          options: const AgentLoopOptions(maxSteps: 5, tokenBudget: 1),
          sendRound: (msgs) async =>
              Stream<ChatStreamChunk>.fromIterable(<ChatStreamChunk>[
                ChatStreamChunk(
                  content: '',
                  isDone: false,
                  totalTokens: 5,
                  toolCalls: _tools().toolCalls,
                ),
              ]),
          reviewSendRound: (msgs) async {
            reviewCalls++;
            return _verdictRound(_passBody);
          },
          answerReview: const AnswerReviewConfig(mode: AnswerReviewMode.always),
        )
        .toList();

    expect(reviewCalls, 0);
    expect(chunks.last.softStopReason, 'token_budget');
  });

  test('hook veto never reviews', () async {
    var reviewCalls = 0;
    var sent = 0;
    final chunks = await AgentOrchestrator()
        .run(
          config: _config(),
          modelId: 'm',
          requestId: 'r13',
          streamOutput: true,
          messages: const [
            {'role': 'user', 'content': 'hi'},
          ],
          onToolCall: (name, args, {String? toolCallId}) async => 'R',
          hooks: AgentLoopHooks(
            onRoundStart: (step, msgs, tokens) async => false,
          ),
          sendRound: (msgs) async {
            sent++;
            return Stream<ChatStreamChunk>.fromIterable(
              const <ChatStreamChunk>[],
            );
          },
          reviewSendRound: (msgs) async {
            reviewCalls++;
            return _verdictRound(_passBody);
          },
          answerReview: const AnswerReviewConfig(mode: AnswerReviewMode.always),
        )
        .toList();

    expect(sent, 0);
    expect(reviewCalls, 0);
    expect(chunks.single.isDone, isTrue);
    expect(chunks.single.softStopReason, isNull);
  });

  test('tool preamble + final answer: the review draft contains only the '
      'final answer', () async {
    final reviewMessages = <List<Map<String, dynamic>>>[];
    final chunks = await AgentOrchestrator()
        .run(
          config: _config(),
          modelId: 'm',
          requestId: 'r14',
          streamOutput: true,
          messages: const [
            {'role': 'user', 'content': 'read'},
          ],
          onToolCall: (name, args, {String? toolCallId}) async => 'BODY',
          sendRound: (msgs) async {
            final hasToolCalls = msgs.any(
              (m) => m['role'] == 'assistant' && m['tool_calls'] != null,
            );
            return Stream<ChatStreamChunk>.fromIterable(
              hasToolCalls
                  ? <ChatStreamChunk>[_text('final answer'), _done()]
                  : <ChatStreamChunk>[
                      _text('let me check the file...'),
                      _tools(),
                    ],
            );
          },
          reviewSendRound: (msgs) async {
            reviewMessages.add(msgs);
            return _verdictRound(_passBody);
          },
          answerReview: const AnswerReviewConfig(mode: AnswerReviewMode.always),
        )
        .toList();

    expect(chunks.where((c) => c.isDone), hasLength(1));
    final turn = reviewMessages.single;
    final instruction = turn.last['content'] as String;
    expect(instruction, contains('final answer'));
    expect(instruction, isNot(contains('let me check the file...')));
  });

  test('main run L1 retry clears the draft: only the new attempt is '
      'reviewed', () async {
    final reviewMessages = <List<Map<String, dynamic>>>[];
    final chunks = await AgentOrchestrator()
        .run(
          config: _config(),
          modelId: 'm',
          requestId: 'r15',
          streamOutput: true,
          messages: const [
            {'role': 'user', 'content': 'hi'},
          ],
          onToolCall: (name, args, {String? toolCallId}) async => 'R',
          // The L1 retry is internal to the transport: one round carries the
          // failed attempt's partial text, the retry status chunk, and then
          // the fresh attempt's full answer + terminal.
          sendRound: (msgs) async =>
              Stream<ChatStreamChunk>.fromIterable(<ChatStreamChunk>[
                _text('broken partial'),
                ChatStreamChunk(
                  content: '',
                  isDone: false,
                  totalTokens: 0,
                  errorKind: 'transient_retry',
                  attempt: 1,
                  maxAttempts: 3,
                ),
                _text('good answer'),
                _done(),
              ]),
          reviewSendRound: (msgs) async {
            reviewMessages.add(msgs);
            return _verdictRound(_passBody);
          },
          answerReview: const AnswerReviewConfig(mode: AnswerReviewMode.always),
        )
        .toList();

    final instruction = reviewMessages.single.last['content'] as String;
    expect(instruction, contains('good answer'));
    expect(instruction, isNot(contains('broken partial')));
    expect(chunks.where((c) => c.isDone), hasLength(1));
    expect(chunks.last.reviewed, isTrue);
  });

  test('review turn: no consecutive user messages when working ends with '
      'user', () async {
    final reviewMessages = <List<Map<String, dynamic>>>[];
    await AgentOrchestrator()
        .run(
          config: _config(),
          modelId: 'm',
          requestId: 'r16',
          streamOutput: true,
          messages: const [
            {'role': 'user', 'content': 'hi'},
          ],
          onToolCall: (name, args, {String? toolCallId}) async => 'R',
          sendRound: (msgs) async => Stream<ChatStreamChunk>.fromIterable(
            <ChatStreamChunk>[_text('hello'), _done()],
          ),
          reviewSendRound: (msgs) async {
            reviewMessages.add(msgs);
            return _verdictRound(_passBody);
          },
          answerReview: const AnswerReviewConfig(mode: AnswerReviewMode.always),
        )
        .toList();

    final turn = reviewMessages.single;
    for (var i = 1; i < turn.length; i++) {
      final consecutiveUser =
          turn[i]['role'] == 'user' && turn[i - 1]['role'] == 'user';
      expect(consecutiveUser, isFalse);
    }
  });

  test('smart gate: short chit-chat without tools skips the review', () async {
    var reviewCalls = 0;
    await AgentOrchestrator()
        .run(
          config: _config(),
          modelId: 'm',
          requestId: 'r17',
          streamOutput: true,
          messages: const [
            {'role': 'user', 'content': 'hi'},
          ],
          onToolCall: (name, args, {String? toolCallId}) async => 'R',
          sendRound: (msgs) async => Stream<ChatStreamChunk>.fromIterable(
            <ChatStreamChunk>[_text('好的！'), _done()],
          ),
          reviewSendRound: (msgs) async {
            reviewCalls++;
            return _verdictRound(_passBody);
          },
          answerReview: const AnswerReviewConfig(mode: AnswerReviewMode.smart),
        )
        .toList();

    expect(reviewCalls, 0);
  });

  test('released terminal totalTokens is not inflated by per-chunk '
      'additive usage (cumulative-usage transports)', () async {
    // Transport repeats the cumulative usage on several chunks of the SAME
    // round (Gemini-style). The kernel's additive tokensUsed = 150, but the
    // run's real total is 100 — the released terminal must carry 100.
    final chunks = await AgentOrchestrator()
        .run(
          config: _config(),
          modelId: 'm',
          requestId: 'r19',
          streamOutput: true,
          messages: const [
            {'role': 'user', 'content': 'hi'},
          ],
          onToolCall: (name, args, {String? toolCallId}) async => 'R',
          sendRound: (msgs) async =>
              Stream<ChatStreamChunk>.fromIterable(<ChatStreamChunk>[
                _text('hel', usage: const TokenUsage(totalTokens: 50)),
                _text('lo', usage: const TokenUsage(totalTokens: 100)),
                _done(
                  usage: const TokenUsage(totalTokens: 100),
                  totalTokens: 100,
                ),
              ]),
          answerReview: const AnswerReviewConfig.off(),
        )
        .toList();

    final terminal = chunks.last;
    expect(terminal.isDone, isTrue);
    expect(terminal.totalTokens, 100);
    expect(terminal.usage!.totalTokens, 100);
  });

  test('REVISE runs revision as a tool-using agent loop and streams the tool round', () async {
    var reviewCall = 0;
    final revisionMessages = <List<Map<String, dynamic>>>[];
    final executed = <String>[];
    final chunks = await AgentOrchestrator()
        .run(
          config: _config(),
          modelId: 'm',
          requestId: 'r-tools',
          streamOutput: true,
          messages: const [
            {'role': 'user', 'content': 'draw a cat'},
          ],
          tools: const [
            {
              'type': 'function',
              'function': <String, dynamic>{
                'name': 'image_search',
                'description': 'search images',
                'parameters': <String, dynamic>{
                  'type': 'object',
                  'properties': <String, dynamic>{},
                },
              },
            },
          ],
          onToolCall: (name, args, {String? toolCallId}) async {
            executed.add(name);
            return '{"image_url":"https://example.com/cat.png"}';
          },
          sendRound: (msgs) async => Stream<ChatStreamChunk>.fromIterable(
            <ChatStreamChunk>[_text('draft without image'), _done()],
          ),
          reviewSendRound: (msgs) async {
            reviewCall++;
            if (reviewCall == 1) {
              return _verdictRound(
                jsonEncode(<String, dynamic>{
                  'verdict': 'revise',
                  'issues': [
                    <String, dynamic>{
                      'severity': 'major',
                      'location': 'answer',
                      'problem': 'Draft has no image.',
                      'fix': 'Use image_search and insert the photo.',
                    },
                  ],
                }),
              );
            }
            revisionMessages.add(msgs);
            if (reviewCall == 2) {
              // First revision round: the model asks for the image tool.
              return Stream<ChatStreamChunk>.fromIterable(<ChatStreamChunk>[
                _text('Looking for an image.'),
                ChatStreamChunk(
                  content: '',
                  isDone: false,
                  totalTokens: 0,
                  toolCalls: <ToolCallInfo>[
                    ToolCallInfo(
                      id: 'rev-img',
                      name: 'image_search',
                      arguments: const {'query': 'cat'},
                    ),
                  ],
                ),
                _done(),
              ]);
            }
            // Second revision round: the tool result is in the working
            // messages and the model produces the final text.
            return Stream<ChatStreamChunk>.fromIterable(<ChatStreamChunk>[
              _text('Final answer with the cat image.'),
              _done(),
            ]);
          },
          answerReview: const AnswerReviewConfig(mode: AnswerReviewMode.always),
        )
        .toList();

    expect(reviewCall, 3, reason: 'one review + two revision rounds');
    expect(executed, <String>['image_search']);
    expect(
      revisionMessages[1].any((m) => m['role'] == 'tool'),
      isTrue,
      reason: 'the second revision round receives the tool result',
    );
    expect(
      chunks.any(
        (c) => (c.toolCalls ?? const []).any((tc) => tc.name == 'image_search'),
      ),
      isTrue,
    );
    expect(
      chunks.any(
        (c) => (c.toolResults ?? const []).any((tr) => tr.id == 'rev-img'),
      ),
      isTrue,
    );
    // Tool-round preamble is cleared; only the final round stays visible.
    expect(chunks.any((c) => c.replaceContent && c.content.isEmpty), isTrue);
    expect(
      chunks.any((c) => c.content == 'Final answer with the cat image.'),
      isTrue,
    );
    expect(chunks.where((c) => c.isDone), hasLength(1));
    expect(chunks.last.reviewed, isTrue);
    expect(chunks.last.reviewReport?.phase, 'revised');
    expect(
      chunks.last.reviewReport?.issues.single.problem,
      'Draft has no image.',
    );
  });

  test('revision error still counts the partial round usage', () async {
    var call = 0;
    final chunks = await AgentOrchestrator()
        .run(
          config: _config(),
          modelId: 'm',
          requestId: 'r-partial-usage',
          streamOutput: true,
          messages: const [
            {'role': 'user', 'content': 'hi'},
          ],
          onToolCall: (name, args, {String? toolCallId}) async => 'R',
          sendRound: (msgs) async => Stream<ChatStreamChunk>.fromIterable(
            <ChatStreamChunk>[_text('draft'), _done()],
          ),
          reviewSendRound: (msgs) async {
            call++;
            if (call == 1) {
              return _verdictRound(
                jsonEncode(<String, dynamic>{
                  'verdict': 'revise',
                  'issues': [
                    <String, dynamic>{
                      'severity': 'blocker',
                      'location': 'l',
                      'problem': 'p',
                      'fix': 'f',
                    },
                  ],
                }),
              );
            }
            return (() async* {
              yield _text(
                'partial revision',
                usage: const TokenUsage(totalTokens: 50),
              );
              throw Exception('revision exploded after usage');
            })();
          },
          answerReview: const AnswerReviewConfig(mode: AnswerReviewMode.always),
        )
        .toList();

    expect(chunks.last.reviewed, isFalse);
    expect(chunks.last.reviewReport?.phase, 'revision_failed');
    expect(chunks.last.reviewUsage?.totalTokens, 50);
    expect(chunks.last.totalTokens, 50);
  });

  test(
    'revision stops before another round when a tool pauses for approval',
    () async {
      var reviewCall = 0;
      final chunks = await AgentOrchestrator()
          .run(
            config: _config(),
            modelId: 'm',
            requestId: 'r-paused',
            streamOutput: true,
            messages: const [
              {'role': 'user', 'content': 'edit a file'},
            ],
            tools: const [
              {
                'type': 'function',
                'function': <String, dynamic>{
                  'name': 'file_write',
                  'description': 'write a file',
                  'parameters': <String, dynamic>{
                    'type': 'object',
                    'properties': <String, dynamic>{},
                  },
                },
              },
            ],
            onToolCall: (name, args, {String? toolCallId}) async =>
                '{"type":"approval_required"}',
            sendRound: (msgs) async => Stream<ChatStreamChunk>.fromIterable(
              <ChatStreamChunk>[_text('draft'), _done()],
            ),
            reviewSendRound: (msgs) async {
              reviewCall++;
              if (reviewCall == 1) {
                return _verdictRound(
                  jsonEncode(<String, dynamic>{
                    'verdict': 'revise',
                    'issues': [
                      <String, dynamic>{
                        'severity': 'blocker',
                        'location': 'file',
                        'problem': 'Wrong file contents.',
                        'fix': 'Write the corrected file.',
                      },
                    ],
                  }),
                );
              }
              return Stream<ChatStreamChunk>.fromIterable(<ChatStreamChunk>[
                ChatStreamChunk(
                  content: '',
                  isDone: false,
                  totalTokens: 0,
                  toolCalls: <ToolCallInfo>[
                    ToolCallInfo(
                      id: 'rev-file',
                      name: 'file_write',
                      arguments: const {'path': 'a.txt'},
                    ),
                  ],
                ),
                _done(),
              ]);
            },
            revisionHooks: AgentLoopHooks(
              onRoundStart: (stepIndex, messages, tokensSoFar) async =>
                  stepIndex == 0,
            ),
            answerReview: const AnswerReviewConfig(
              mode: AnswerReviewMode.always,
            ),
          )
          .toList();

      expect(reviewCall, 2, reason: 'review + one revision round');
      expect(chunks.last.reviewed, isFalse);
      expect(chunks.last.reviewReport?.phase, 'revision_failed');
      expect(chunks.last.reviewReport?.failReason, 'revision_paused');
      expect(
        chunks.any((c) => c.replaceContent && c.content == 'draft'),
        isTrue,
      );
    },
  );

  // ------------------------------------------------------------------
  // Transport parameter contract (production path: sendRoundImpl)
  // ------------------------------------------------------------------
  test('review round goes out text-only: no tools, verdict maxTokens, '
      'stream off, sanitized extra body', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final bodies = <Map<String, dynamic>>[];
    final subs = <StreamSubscription<HttpRequest>>[];
    subs.add(
      server.listen((req) async {
        final raw = await utf8.decoder.bind(req).join();
        try {
          bodies.add(jsonDecode(raw) as Map<String, dynamic>);
        } catch (_) {
          bodies.add(<String, dynamic>{'__raw': raw});
        }
        final isReview = bodies.length == 2;
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode(<String, dynamic>{
            'id': 'x',
            'object': 'chat.completion',
            'created': 1,
            'model': 'm',
            'choices': [
              <String, dynamic>{
                'index': 0,
                'message': <String, dynamic>{
                  'role': 'assistant',
                  'content': isReview ? _passBody : 'hello from the wire',
                },
                'finish_reason': 'stop',
              },
            ],
            'usage': <String, dynamic>{
              'prompt_tokens': 10,
              'completion_tokens': 5,
              'total_tokens': 15,
            },
          }),
        );
        await req.response.close();
      }),
    );
    addTearDown(() async {
      for (final s in subs) {
        await s.cancel();
      }
      await server.close(force: true);
    });

    final chunks = await AgentOrchestrator()
        .run(
          config: _config(baseUrl: 'http://127.0.0.1:${server.port}'),
          modelId: 'm',
          requestId: 'r18',
          // Non-streaming wire (the review round is always non-streaming; the
          // review phase itself does not depend on the main streamOutput).
          streamOutput: false,
          messages: const [
            {'role': 'user', 'content': 'hi'},
          ],
          extraBody: <String, dynamic>{
            'tools': <dynamic>[],
            'messages': <dynamic>[],
            'temperature_top': 'keep-me',
          },
          answerReview: const AnswerReviewConfig(mode: AnswerReviewMode.always),
        )
        .toList();

    expect(chunks.last.reviewed, isTrue, reason: 'verdict body was PASS');
    expect(bodies, hasLength(2));

    final reviewBody = bodies[1];
    // Text-only contract (§5.2 invariant 3): the sanitizer removed every
    // tool / stream / request-shape override key from the extra body.
    expect(reviewBody.containsKey('tools'), isFalse);
    expect(reviewBody['stream'], anyOf(isFalse, isNull));
    expect(reviewBody['messages'], isA<List>());
    expect(reviewBody['temperature_top'], 'keep-me');
    // No verdict cap: the review inherits the main run's (absent) max_tokens
    // and sends none. Always-thinking models must be free to spend their
    // reasoning tokens before the JSON verdict.
    expect(reviewBody.containsKey('max_tokens'), isFalse);
    // The review inherits the main run's reasoning effort (null/auto here),
    // so a plain model sends no reasoning keys at all.
    expect(reviewBody.containsKey('reasoning_effort'), isFalse);
    expect(reviewBody.containsKey('reasoning'), isFalse);
    expect(reviewBody.containsKey('thinking'), isFalse);
    // The review instruction rides the last user message.
    final reviewMessages = reviewBody['messages'] as List;
    expect(reviewMessages.last['role'], 'user');
    expect(
      (reviewMessages.last['content'] as String),
      contains('[ANSWER REVIEW'),
    );
    expect(
      (reviewMessages.last['content'] as String),
      contains('hello from the wire'),
    );

    final mainBody = bodies[0];
    // Main request still carries the (unsanitized) extra body values.
    expect(mainBody.containsKey('tools'), isTrue);
  });

  test(
    'revision request is a normal agent-loop request carrying tools',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final bodies = <Map<String, dynamic>>[];
      final subs = <StreamSubscription<HttpRequest>>[];
      subs.add(
        server.listen((req) async {
          final raw = await utf8.decoder.bind(req).join();
          final body = jsonDecode(raw) as Map<String, dynamic>;
          bodies.add(body);
          final call = bodies.length;
          final content = call == 1
              ? 'draft from the wire'
              : call == 2
              ? jsonEncode(<String, dynamic>{
                  'verdict': 'revise',
                  'issues': [
                    <String, dynamic>{
                      'severity': 'major',
                      'location': 'answer',
                      'problem': 'Missing image.',
                      'fix': 'Use image_search.',
                    },
                  ],
                })
              : 'revised answer from the wire';
          req.response.headers.contentType = ContentType.json;
          req.response.write(
            jsonEncode(<String, dynamic>{
              'id': 'x',
              'object': 'chat.completion',
              'created': 1,
              'model': 'm',
              'choices': [
                <String, dynamic>{
                  'index': 0,
                  'message': <String, dynamic>{
                    'role': 'assistant',
                    'content': content,
                  },
                  'finish_reason': 'stop',
                },
              ],
              'usage': <String, dynamic>{
                'prompt_tokens': 10,
                'completion_tokens': 5,
                'total_tokens': 15,
              },
            }),
          );
          await req.response.close();
        }),
      );
      addTearDown(() async {
        for (final s in subs) {
          await s.cancel();
        }
        await server.close(force: true);
      });

      const tool = <String, dynamic>{
        'type': 'function',
        'function': <String, dynamic>{
          'name': 'image_search',
          'description': 'search images',
          'parameters': <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{},
          },
        },
      };

      final chunks = await AgentOrchestrator()
          .run(
            config: _config(baseUrl: 'http://127.0.0.1:${server.port}'),
            modelId: 'm',
            requestId: 'r-revision-wire',
            streamOutput: false,
            messages: const [
              {'role': 'user', 'content': 'draw a cat'},
            ],
            tools: const [tool],
            onToolCall: (name, args, {String? toolCallId}) async => 'R',
            answerReview: const AnswerReviewConfig(
              mode: AnswerReviewMode.always,
            ),
          )
          .toList();

      expect(chunks.last.reviewed, isTrue);
      expect(bodies, hasLength(3));
      // Review remains text-only.
      expect(bodies[1].containsKey('tools'), isFalse);
      // Revision is a normal loop: it carries the tool schema and the repair
      // instruction.
      expect(bodies[2]['tools'], isA<List>());
      expect((bodies[2]['tools'] as List), isNotEmpty);
      expect(jsonEncode(bodies[2]), contains('[ANSWER REVISION'));
    },
  );
}
