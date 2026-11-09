// Agent-loop driver (IMPORT_PLAN_COWORK.md P0-2).
//
// The connection layer between the pure kernel
// (`lib/core/services/agent/agent_loop.dart`) and the existing transport +
// UI pipeline:
//
//   - `sendRound` is a single-round `ChatApiService.sendMessageStream` call —
//     one transport request per kernel round, tools surfaced but NOT executed
//     by the transport.
//   - the kernel executes tools via the injected legacy handler
//     (`(name, args) => String`, the same contract `chat_actions` uses
//     today) and composes the follow-up messages.
//   - kernel events are re-mapped onto the `Stream<ChatStreamChunk>` shape
//     the existing UI pipeline consumes (`_handleStreamData`): transport
//     chunks pass through untouched (content / reasoning / usage / retry
//     status / toolCalls), synthetic tool-result chunks (kernel
//     `emitCalls`) update tool cards exactly as before, and the run's end
//     becomes a terminal `isDone` chunk.
//
// P0-3: the `agent_loop_v1` kill-switch has been retired and the legacy
// transport tool loops are gone — this driver is the only generation path.
// The transport is now strictly one request per call: it parses the response,
// surfaces tool calls (with the provider's reasoning-echo extras) and returns.
// Every provider was parity-verified before the loops were removed (OpenAI
// chat-completions incl. Responses and the no-DONE fallback, Claude thinking
// echo and pause_turn/server-tool continuation, Gemini thought signatures, and
// Neuralwatt on the OpenAI wire).
//
// Answer Review v1 (docs/answer_review_plan.md): the driver now also owns the
// post-finish review phase. Every transport terminal (tool rounds included)
// is held back (hold-latest) instead of forwarded; after the kernel reports
// `finished`, the captured last-round draft is reviewed by the same model and
// — only on a REVISE verdict — rewritten once. The UI still observes exactly
// one terminal `isDone`, whose usage is the main run plus the review/revision
// subset. With the review off, the released terminal is behaviorally
// identical to today's pass-through (single-round runs byte-for-byte).

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math' as math;

import '../../models/answer_review.dart';
import '../../models/token_usage.dart';
import '../../providers/settings_provider.dart';
import 'agent_loop.dart';
import 'answer_review.dart';
import '../api/chat_api_service.dart';

/// Loop driver: owns the kernel instance, the transport binding and the tool
/// execution adapter. Stateless per run — a fresh [run] call drives a fresh
/// kernel loop.
class AgentOrchestrator {
  /// Drive one agent run and re-emit the kernel's events as the chunk stream
  /// the existing UI / persistence pipeline consumes.
  ///
  /// [messages] are the initial OpenAI-neutral messages. [sendRound] issues
  /// exactly one transport request per call. [onToolCall] executes a single
  /// tool (legacy `(name, args)` contract). [options] / [hooks] are passed
  /// through to the kernel; hooks let callers observe round boundaries (soft
  /// budget, Phase-1 approval pause/resume, compression triggers).
  ///
  /// The stream ends with a single terminal `isDone` chunk carrying the run's
  /// cumulative token usage; when the kernel stops early (max steps / budget
  /// / hook veto) the same terminal chunk is emitted so the UI finalizes the
  /// message bubble as it does today.
  ///
  /// [answerReview] enables the post-finish review phase (Answer Review v1).
  /// [reviewSendRound] is a test seam replacing the review / revision
  /// transport binding; when null the real [sendRoundImpl] is used with the
  /// review parameter contract (text-only, `_review` request id, sanitized
  /// extra body).
  Stream<ChatStreamChunk> run({
    required ProviderConfig config,
    required String modelId,
    required List<Map<String, dynamic>> messages,
    List<String>? userImagePaths,
    int? thinkingBudget,
    double? temperature,
    double? topP,
    int? maxTokens,
    List<Map<String, dynamic>>? tools,
    ToolCallHandler? onToolCall,
    Map<String, String>? extraHeaders,
    Map<String, dynamic>? extraBody,
    bool webFetchEnabled = true,
    required bool streamOutput,
    required String requestId,
    String? sessionId,
    String? imageAspectRatio,
    AgentLoopOptions options = const AgentLoopOptions(),
    AgentLoopHooks hooks = const AgentLoopHooks(),
    AnswerReviewConfig answerReview = const AnswerReviewConfig.off(),
    Future<Stream<ChatStreamChunk>> Function(
      List<Map<String, dynamic>> messages,
    )?
    reviewSendRound,
    Future<Stream<ChatStreamChunk>> Function(
      List<Map<String, dynamic>> messages,
    )?
    sendRound,
  }) async* {
    assert(
      onToolCall != null || tools == null || tools.isEmpty,
      'tools require an onToolCall handler: the kernel would otherwise feed '
      'empty tool results back to the model.',
    );
    final toolHandler = onToolCall ?? noopToolHandler;
    final round =
        sendRound ??
        ((msgs) => sendRoundImpl(
          config: config,
          modelId: modelId,
          messages: msgs,
          userImagePaths: userImagePaths,
          thinkingBudget: thinkingBudget,
          temperature: temperature,
          topP: topP,
          maxTokens: maxTokens,
          tools: tools,
          extraHeaders: extraHeaders,
          extraBody: extraBody,
          webFetchEnabled: webFetchEnabled,
          streamOutput: streamOutput,
          requestId: requestId,
          sessionId: sessionId,
          imageAspectRatio: imageAspectRatio,
        ));

    // Internal review/revision transport binding (§10.3): text-only, the
    // `_review` request-id suffix (cancelStreaming cancels it), images are
    // NOT re-sent (they already travelled with the main run), and the extra
    // body is sanitized of every tool / stream / request-shape override.
    Future<Stream<ChatStreamChunk>> reviewRound({
      required List<Map<String, dynamic>> reviewMessages,
      required bool stream,
      int? maxTokensOverride,
    }) async {
      final injected = reviewSendRound;
      if (injected != null) return injected(reviewMessages);
      return sendRoundImpl(
        config: config,
        modelId: modelId,
        messages: reviewMessages,
        userImagePaths: null,
        imageAspectRatio: null,
        thinkingBudget: thinkingBudget,
        temperature: temperature,
        topP: topP,
        maxTokens: maxTokensOverride,
        tools: null,
        extraHeaders: extraHeaders,
        extraBody: sanitizeReviewExtraBody(extraBody),
        webFetchEnabled: false,
        streamOutput: stream,
        requestId: '${requestId}_review',
        sessionId: sessionId,
      );
    }

    // Answer Review v1 bookkeeping: the last round's draft (tool-round
    // preambles are dropped), the held transport terminal (hold-latest) and
    // the review/revision usage subset folded into the final terminal.
    final draft = StringBuffer();
    ChatStreamChunk? heldTerminal;
    var reviewUsage = const TokenUsage();

    // Driver-side per-round usage total: a round's real total is the MAX
    // usage-carrying chunk of that round (every transport reports cumulative
    // per-round usage — Gemini even repeats it on every delta, where the
    // kernel's additive `tokensUsed` over-counts). Rounds are summed. This
    // feeds the terminal's base total (§8.4) without inheriting the kernel's
    // per-chunk additive quirk.
    var roundMaxUsageTotal = 0;
    var usageAcrossRounds = 0;

    await for (final event in runAgentLoop(
      messages: messages,
      sendRound: round,
      // id-aware contract: the kernel's AgentToolCall carries the provider
      // call id; handlers key per-call side effects off it (approval event
      // ids).
      onToolCall: (call) =>
          toolHandler(call.name, call.arguments, toolCallId: call.toolCallId),
      options: options,
      hooks: hooks,
    )) {
      switch (event) {
        case AgentStreamEvent(:final chunk):
          if (chunk.errorKind != null) {
            // L1 retry in the main run: the attempt is re-issued and the
            // whole answer regenerates, so the draft restarts blank (§5.3).
            draft.clear();
            heldTerminal = null;
            roundMaxUsageTotal = 0;
          }
          // Per-round usage max (see the comment above usageAcrossRounds).
          final roundTotal = chunk.usage?.totalTokens ?? chunk.totalTokens;
          if (roundTotal > roundMaxUsageTotal) roundMaxUsageTotal = roundTotal;
          if (chunk.isDone) {
            // Answer Review v1: EVERY transport terminal (tool rounds
            // included) is held back and the next one overwrites it
            // (hold-latest). The UI used to swallow tool-round terminals via
            // the hasLoadingTool guard; holding them here is equivalent and
            // lets the driver release exactly ONE terminal. The terminal's
            // text still reaches the UI through a content-only chunk (usage
            // keeps riding the held terminal).
            if (chunk.content.isNotEmpty) {
              draft.write(chunk.content);
              yield ChatStreamChunk(
                content: chunk.content,
                reasoning: chunk.reasoning,
                isDone: false,
                totalTokens: 0,
              );
            }
            heldTerminal = chunk.copyWith(content: '');
          } else {
            if (chunk.content.isNotEmpty) draft.write(chunk.content);
            yield chunk;
          }
        case AgentToolExecutedEvent():
          // The kernel already re-emits a synthetic toolResults chunk for the
          // UI (options.emitCalls); nothing to do here.
          break;
        case AgentRoundFinishedEvent():
          // Tool-round boundary: the preamble is not the final answer —
          // restart the draft from blank (§5.2 invariant 4) and bank the
          // round's usage total.
          draft.clear();
          usageAcrossRounds += roundMaxUsageTotal;
          roundMaxUsageTotal = 0;
        case AgentRunFinishedEvent(
          :final reason,
          :final messages,
          :final executedCallCount,
          :final tokensUsed,
        ):
          if (reason != AgentRunStopReason.finished) {
            // Early stop: the transport never emitted a terminal chunk for
            // the final round, so synthesize one so the UI finalizes the
            // message exactly as on normal completion. Any held tool-round
            // terminal is discarded — early stops are never reviewed
            // (§5.2 invariant 1). P0-5: max-steps / token-budget stops are
            // surfaced to the user via a localized footnote (ADR-A4
            // soft-gate semantics); hook vetoes (approval pause) carry no
            // reason — the approval card is the user-facing surface.
            heldTerminal = null;
            yield ChatStreamChunk(
              content: '',
              isDone: true,
              totalTokens: tokensUsed,
              softStopReason: switch (reason) {
                AgentRunStopReason.maxStepsReached => 'max_steps',
                AgentRunStopReason.tokenBudgetReached => 'token_budget',
                _ => null,
              },
            );
            return;
          }

          if (heldTerminal == null) {
            // Anomalous: the transport never delivered a terminal for the
            // final round. Synthesize one so the bubble still finalizes and
            // skip the review entirely.
            yield ChatStreamChunk(
              content: '',
              isDone: true,
              totalTokens: tokensUsed,
            );
            return;
          }

          // Base total for the released terminal (§8.4): the run's true
          // cumulative, measured max-per-round (see usageAcrossRounds above).
          // The kernel's additive `tokensUsed` is only accurate when each
          // round emits a single usage chunk; transports that repeat the
          // cumulative usage on every delta (Gemini / Claude merges) would
          // inflate it N× — prefer the per-round max sum and fall back to the
          // kernel value only when nothing was observed at all.
          final observedTotal = usageAcrossRounds + roundMaxUsageTotal;
          final baseTokensUsed = observedTotal > 0 ? observedTotal : tokensUsed;

          final draftText = draft.toString();
          if (!answerReview.enabled ||
              !shouldReviewDraft(
                mode: answerReview.mode,
                draft: draftText,
                executedCallCount: executedCallCount,
              )) {
            developer.log(
              'answer_review.skip reason='
              '${!answerReview.enabled ? answerReview.mode.value : (draftText.trim().isEmpty ? 'empty' : 'gate')}',
              name: 'answer_review',
            );
            yield _releaseHeldTerminal(
              held: heldTerminal,
              tokensUsed: baseTokensUsed,
              reviewUsage: reviewUsage,
              reviewed: false,
            );
            return;
          }

          developer.log(
            'answer_review.start mode=${answerReview.mode.value} '
            'executedCalls=$executedCallCount draftChars=${draftText.length}',
            name: 'answer_review',
          );

          // --- Review call (fail-open; §5.1) ---
          final reviewStartedAt = DateTime.now();
          final draftChars = draftText.length;
          yield ChatStreamChunk(
            content: '',
            isDone: false,
            totalTokens: 0,
            reviewPhase: kReviewPhaseReviewing,
            reviewReport: AnswerReviewReport(
              phase: AnswerReviewPhase.reviewing,
              draftChars: draftChars,
              startedAtMs: reviewStartedAt.millisecondsSinceEpoch,
            ),
          );
          final reviewWatch = Stopwatch()..start();
          final reviewCollected = await _collectRound(
            reviewRound(
              reviewMessages: buildReviewTurn(
                working: messages,
                draft: draftText,
              ),
              stream: false,
              // No verdict cap by default: always-thinking models bill
              // reasoning against `max_tokens` (Agnes burned 1200 tokens on
              // thinking and returned an empty body). A configured cap still
              // wins when set. Reasoning effort is intentionally inherited
              // from the main run (quality over cost).
              maxTokensOverride: answerReview.maxReviewTokens,
            ),
            timeout: answerReview.reviewTimeout,
          );
          reviewUsage = reviewUsage.sum(reviewCollected.resolvedUsage);
          reviewWatch.stop();
          final reviewMs = reviewWatch.elapsedMilliseconds;

          final reviewOutcome = _verdictFromCollected(reviewCollected);
          if (reviewOutcome == null) {
            // Timeout / transport error / empty response: keep the draft and
            // close with a non-reviewed terminal (§3.2 outcome 3). The card
            // still gets a `reviewed` event so the user sees WHY the review
            // did not complete.
            final report = AnswerReviewReport(
              phase: AnswerReviewPhase.failedOpen,
              parsed: false,
              issues: const <ReviewIssue>[],
              reviewed: false,
              failReason: reviewCollected.failureReason ?? 'error',
              reviewMs: reviewMs,
              reviewTokens: _usageTotal(reviewCollected.resolvedUsage),
              modelId: modelId,
              draftChars: draftChars,
              startedAtMs: reviewStartedAt.millisecondsSinceEpoch,
              finishedAtMs: DateTime.now().millisecondsSinceEpoch,
            );
            yield ChatStreamChunk(
              content: '',
              isDone: false,
              totalTokens: 0,
              reviewPhase: kReviewPhaseReviewed,
              reviewReport: report,
            );
            yield _releaseHeldTerminal(
              held: heldTerminal,
              tokensUsed: baseTokensUsed,
              reviewUsage: reviewUsage,
              reviewed: false,
              reviewReport: report,
            );
            return;
          }
          final verdict = reviewOutcome.verdict;
          var blockers = 0;
          var majors = 0;
          for (final issue in verdict.issues) {
            if (issue.severity == 'blocker') {
              blockers++;
            } else if (issue.severity == 'major') {
              majors++;
            }
          }
          developer.log(
            'answer_review.verdict verdict=${verdict.verdict} '
            'issues=${verdict.issues.length} blockers=$blockers '
            'majors=$majors latencyMs=${reviewWatch.elapsedMilliseconds} '
            'tokens=${reviewCollected.resolvedUsage.totalTokens}',
            name: 'answer_review',
          );

          if (!verdict.isRevise) {
            // PASS: release the draft untouched. `reviewed` is only true when
            // the verdict JSON actually parsed — a malformed (fail-open PASS)
            // response never completed the review (§8.1). A malformed body
            // is reported as `failed_open/malformed`, not as an ordinary
            // PASS, so the card does not claim a review it never completed.
            final completed = reviewOutcome.completed;
            final report = AnswerReviewReport(
              phase: completed
                  ? AnswerReviewPhase.passed
                  : AnswerReviewPhase.failedOpen,
              verdict: completed ? verdict.verdict : null,
              parsed: verdict.parsed,
              issues: verdict.issues,
              reviewed: completed,
              failReason: completed ? null : 'malformed',
              reviewMs: reviewMs,
              reviewTokens: _usageTotal(reviewCollected.resolvedUsage),
              modelId: modelId,
              draftChars: draftChars,
              startedAtMs: reviewStartedAt.millisecondsSinceEpoch,
              finishedAtMs: DateTime.now().millisecondsSinceEpoch,
            );
            yield ChatStreamChunk(
              content: '',
              isDone: false,
              totalTokens: 0,
              reviewPhase: kReviewPhaseReviewed,
              reviewReport: report,
            );
            yield _releaseHeldTerminal(
              held: heldTerminal,
              tokensUsed: baseTokensUsed,
              reviewUsage: reviewUsage,
              reviewed: completed,
              reviewReport: report,
            );
            return;
          }

          // --- Revision call (text-only stream; at most once; §5.2) ---
          final revisingReport = AnswerReviewReport(
            phase: AnswerReviewPhase.revising,
            verdict: verdict.verdict,
            parsed: verdict.parsed,
            issues: verdict.issues,
            reviewed: false,
            reviewMs: reviewMs,
            reviewTokens: _usageTotal(reviewCollected.resolvedUsage),
            modelId: modelId,
            draftChars: draftChars,
            startedAtMs: reviewStartedAt.millisecondsSinceEpoch,
          );
          yield ChatStreamChunk(
            content: '',
            isDone: false,
            totalTokens: 0,
            reviewPhase: kReviewPhaseReviewed,
            reviewReport: revisingReport,
          );
          final revisionWatch = Stopwatch()..start();
          yield ChatStreamChunk(
            content: '',
            isDone: false,
            totalTokens: 0,
            reviewPhase: kReviewPhaseRevising,
            reviewReport: revisingReport,
          );
          final revisionCollected = _CollectedRound();
          var revisionFailed = false;
          try {
            final revisionStream = _withDeadline(
              await reviewRound(
                reviewMessages: buildRevisionTurn(
                  working: messages,
                  draft: draftText,
                  issuesJson: verdict.blockingIssuesJson(),
                ),
                stream: true,
                // The revision rewrites the full answer — it keeps the main
                // run's output budget, not the short verdict cap.
                maxTokensOverride: maxTokens,
              ),
              timeout: answerReview.reviewTimeout,
            );
            await for (final chunk in revisionStream) {
              revisionCollected.add(chunk);
              if (chunk.errorKind != null) {
                // L1 retry inside the revision round: drop the status chunk
                // and clear the half-revised text from the UI without
                // touching the main run's usage / tool cards (§5.3).
                yield ChatStreamChunk(
                  content: '',
                  isDone: false,
                  totalTokens: 0,
                  replaceContent: true,
                );
              } else if (chunk.isDone) {
                // The revision's own terminal is never forwarded — the
                // driver composes the single final terminal (§5.2 invariant
                // 2).
              } else if (chunk.content.isNotEmpty) {
                // Text-only forwarding: the revision round's reasoning echo
                // must NOT append onto the main run's finished thinking
                // timeline.
                yield ChatStreamChunk(
                  content: chunk.content,
                  isDone: false,
                  totalTokens: 0,
                );
              }
            }
          } on TimeoutException {
            revisionCollected.errored = true;
            revisionFailed = true;
          } catch (_) {
            revisionCollected.errored = true;
            revisionFailed = true;
          }
          reviewUsage = reviewUsage.sum(revisionCollected.resolvedUsage);
          revisionWatch.stop();
          final revisionMs = revisionWatch.elapsedMilliseconds;
          // The revision turn declares no tools. Some models still emit raw
          // tool-call markup (DeepSeek DSML, <tool_call>, …) when they want a
          // tool; accepting it would replace the answer with markup.
          final revisionProducedToolCall = containsToolCallMarkup(
            revisionCollected.content,
          );
          final revisionFailReason = revisionProducedToolCall
              ? 'revision_tool_call'
              : 'revision_failed';

          if (revisionFailed ||
              !revisionCollected.ok ||
              revisionProducedToolCall) {
            // Fail-open: revision errored / timed out / came back empty /
            // truncated. Restore the original draft via a replace-content
            // chunk, then close with a non-reviewed terminal (§8.3 D.4).
            developer.log(
              'answer_review.fail_open reason='
              '${revisionProducedToolCall ? 'revision_tool_call' : 'revision'} '
              'sawTerminal=${revisionCollected.sawTerminal} '
              'chars=${revisionCollected.content.trim().length}',
              name: 'answer_review',
            );
            developer.log(
              'answer_review.revision ok=false',
              name: 'answer_review',
            );
            final report = revisingReport.copyWith(
              phase: AnswerReviewPhase.revisionFailed,
              reviewed: false,
              failReason: revisionFailReason,
              revisionMs: revisionMs,
              reviewTokens: _usageTotal(reviewUsage),
              finishedAtMs: DateTime.now().millisecondsSinceEpoch,
            );
            yield ChatStreamChunk(
              content: '',
              isDone: false,
              totalTokens: 0,
              reviewPhase: kReviewPhaseRevisionFailed,
              reviewReport: report,
            );
            yield ChatStreamChunk(
              content: draftText,
              isDone: false,
              totalTokens: 0,
              replaceContent: true,
            );
            yield _releaseHeldTerminal(
              held: heldTerminal,
              tokensUsed: baseTokensUsed,
              reviewUsage: reviewUsage,
              reviewed: false,
              reviewReport: report,
            );
            return;
          }

          developer.log(
            'answer_review.revision ok=true chars='
            '${revisionCollected.content.trim().length}',
            name: 'answer_review',
          );
          final report = revisingReport.copyWith(
            phase: AnswerReviewPhase.revised,
            reviewed: true,
            revisionMs: revisionMs,
            reviewTokens: _usageTotal(reviewUsage),
            finishedAtMs: DateTime.now().millisecondsSinceEpoch,
          );
          yield _releaseHeldTerminal(
            held: heldTerminal,
            tokensUsed: baseTokensUsed,
            reviewUsage: reviewUsage,
            reviewed: true,
            reviewReport: report,
          );
          return;
      }
    }
  }

  /// Single-round transport binding: one `sendMessageStream` call (tools
  /// surfaced, never executed here).
  Future<Stream<ChatStreamChunk>> sendRoundImpl({
    required ProviderConfig config,
    required String modelId,
    required List<Map<String, dynamic>> messages,
    List<String>? userImagePaths,
    int? thinkingBudget,
    double? temperature,
    double? topP,
    int? maxTokens,
    List<Map<String, dynamic>>? tools,
    Map<String, String>? extraHeaders,
    Map<String, dynamic>? extraBody,
    bool webFetchEnabled = true,
    required bool streamOutput,
    required String requestId,
    String? sessionId,
    String? imageAspectRatio,
  }) async {
    return ChatApiService.sendMessageStream(
      config: config,
      modelId: modelId,
      messages: messages,
      userImagePaths: userImagePaths,
      thinkingBudget: thinkingBudget,
      temperature: temperature,
      topP: topP,
      maxTokens: maxTokens,
      tools: tools,
      extraHeaders: extraHeaders,
      extraBody: extraBody,
      webFetchEnabled: webFetchEnabled,
      stream: streamOutput,
      requestId: requestId,
      sessionId: sessionId,
      imageAspectRatio: imageAspectRatio,
    );
  }
}

/// Collect one internal (review / revision) transport round into a content +
/// usage snapshot. The returned future resolves when the stream completes or
/// errors. When [timeout] is set, the wall-clock deadline cancels the inner
/// subscription first and then resolves with a timed-out snapshot so the
/// provider request cannot keep burning tokens in the background (§5.1
/// timeout semantics). `null` means no deadline.
Future<_CollectedRound> _collectRound(
  Future<Stream<ChatStreamChunk>> roundFuture, {
  Duration? timeout,
}) async {
  final completer = Completer<_CollectedRound>();
  final collected = _CollectedRound();
  StreamSubscription<ChatStreamChunk>? sub;
  try {
    sub = (await roundFuture).listen(
      collected.add,
      onError: (Object e) {
        collected.errored = true;
        if (!completer.isCompleted) completer.complete(collected);
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete(collected);
      },
      cancelOnError: true,
    );
  } catch (e) {
    // The transport call itself threw (request build / connect failure).
    collected.errored = true;
    return collected;
  }
  if (timeout == null) return completer.future;
  return completer.future.timeout(
    timeout,
    onTimeout: () async {
      await sub?.cancel();
      collected.errored = true;
      collected.timedOut = true;
      return collected;
    },
  );
}

/// Wrap a stream with a wall-clock deadline: on timeout the inner
/// subscription is cancelled and a [TimeoutException] surfaces to the
/// `await for` consumer. Used by the revision round, whose deltas stream
/// through while the deadline still applies to the whole response.
Stream<ChatStreamChunk> _withDeadline(
  Stream<ChatStreamChunk> source, {
  required Duration? timeout,
}) {
  // No deadline configured: forward the source untouched.
  if (timeout == null) return source;
  late StreamController<ChatStreamChunk> controller;
  StreamSubscription<ChatStreamChunk>? sub;
  Timer? timer;
  controller = StreamController<ChatStreamChunk>(
    onListen: () {
      timer = Timer(timeout, () async {
        await sub?.cancel();
        controller.addError(
          TimeoutException('answer_review deadline', timeout),
        );
        await controller.close();
      });
      sub = source.listen(
        controller.add,
        onError: controller.addError,
        onDone: () {
          timer?.cancel();
          controller.close();
        },
        cancelOnError: true,
      );
    },
    onPause: () => sub?.pause(),
    onResume: () => sub?.resume(),
    onCancel: () {
      timer?.cancel();
      return sub?.cancel();
    },
  );
  return controller.stream;
}

/// Interpret a collected review round as a verdict, or null for a fail-open
/// (timeout / transport error / empty body). A malformed body parses as a
/// PASS verdict inside [parseReviewVerdict] (§7.4) but still reports
/// `completed: false`, so the released terminal keeps `reviewed: false`
/// (§8.1: reviewed means the review ran to completion).
({ReviewVerdict verdict, bool completed})? _verdictFromCollected(
  _CollectedRound collected,
) {
  if (collected.timedOut) {
    developer.log(
      'answer_review.fail_open reason=timeout',
      name: 'answer_review',
    );
    return null;
  }
  if (collected.errored) {
    developer.log(
      'answer_review.fail_open reason=error',
      name: 'answer_review',
    );
    return null;
  }
  if (!collected.sawTerminal || collected.content.trim().isEmpty) {
    developer.log(
      'answer_review.fail_open reason=empty',
      name: 'answer_review',
    );
    return null;
  }
  final verdict = parseReviewVerdict(collected.content);
  if (!verdict.parsed) {
    developer.log(
      'answer_review.fail_open reason=parse rawLength=${collected.content.length}',
      name: 'answer_review',
    );
  }
  return (verdict: verdict, completed: verdict.parsed);
}

/// Compose the single final terminal from the held transport terminal
/// (§8.4): usage = (held.usage ?? zero) + reviewUsage (additive `sum`),
/// totalTokens = max(held.totalTokens, kernel cumulative) + reviewUsage.total
/// (prompt + completion fallback). [reviewUsage] rides along as the
/// display-only subset — the UI must not add it a second time.
ChatStreamChunk _releaseHeldTerminal({
  required ChatStreamChunk held,
  required int tokensUsed,
  required TokenUsage reviewUsage,
  required bool reviewed,
  AnswerReviewReport? reviewReport,
}) {
  final reviewTotal = reviewUsage.totalTokens > 0
      ? reviewUsage.totalTokens
      : reviewUsage.promptTokens + reviewUsage.completionTokens;
  final hasReviewUsage =
      reviewTotal > 0 ||
      reviewUsage.cachedTokens > 0 ||
      reviewUsage.messageUsage != null;
  final baseTotal = math.max(held.totalTokens, tokensUsed);
  final TokenUsage? usage = (held.usage == null && !hasReviewUsage)
      ? held.usage
      : (held.usage ?? const TokenUsage()).sum(reviewUsage);
  return held.copyWith(
    isDone: true,
    totalTokens: baseTotal + reviewTotal,
    usage: usage,
    reviewed: reviewed,
    reviewUsage: hasReviewUsage ? reviewUsage : null,
    reviewReport: reviewReport,
  );
}

/// Display-only total for a review/revision usage snapshot. Providers that
/// only populate prompt/completion leave `totalTokens` at zero.
int _usageTotal(TokenUsage usage) => usage.totalTokens > 0
    ? usage.totalTokens
    : usage.promptTokens + usage.completionTokens;

/// Accumulator for one internal round: content, the LAST usage snapshot (or
/// the largest per-chunk total when a provider omits structured usage) and
/// the terminal / error flags. Streaming usage snapshots are never summed
/// chunk-by-chunk (§5.2 invariant 9).
class _CollectedRound {
  final StringBuffer _content = StringBuffer();
  TokenUsage _usage = const TokenUsage();
  int _maxTotal = 0;
  bool sawTerminal = false;
  bool errored = false;
  bool timedOut = false;

  void add(ChatStreamChunk chunk) {
    if (chunk.errorKind != null) {
      // L1 retry inside the internal round: the attempt re-issues the whole
      // request, so the previously collected text restarts from blank (§5.3).
      _content.clear();
      return;
    }
    if (chunk.content.isNotEmpty) _content.write(chunk.content);
    if (chunk.usage != null) _usage = chunk.usage!;
    if (chunk.totalTokens > _maxTotal) _maxTotal = chunk.totalTokens;
    if (chunk.isDone) sawTerminal = true;
  }

  String get content => _content.toString();

  TokenUsage get resolvedUsage {
    if (_usage.totalTokens > 0 ||
        _usage.promptTokens > 0 ||
        _usage.completionTokens > 0 ||
        _usage.messageUsage != null) {
      return _usage;
    }
    if (_maxTotal > 0) return TokenUsage(totalTokens: _maxTotal);
    return const TokenUsage();
  }

  /// A revision succeeded only when the stream completed with a terminal and
  /// produced a non-empty answer; anything else fail-opens back to the draft.
  bool get ok => sawTerminal && !errored && content.trim().isNotEmpty;

  /// Why a review/revision round did not produce a usable body (§8.3).
  String? get failureReason {
    if (timedOut) return 'timeout';
    if (errored) return 'error';
    if (!sawTerminal || content.trim().isEmpty) return 'empty';
    return null;
  }
}

/// Fallback tool handler used when a caller has no real handler: surfaces a
/// structured error to the model instead of crashing the run.
Future<String> noopToolHandler(
  String name,
  Map<String, dynamic> args, {
  String? toolCallId,
}) async => jsonEncode(<String, dynamic>{
  'type': 'tool_error',
  'error': 'execution_error',
  'message': 'Tool "$name" is not available in this context.',
  'tool': name,
  'instruction': 'The tool execution failed unexpectedly. You may try again with different parameters or inform the user about the issue.',
});
