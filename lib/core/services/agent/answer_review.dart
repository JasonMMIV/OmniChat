/// Answer Review v1 — pure review-phase logic (`docs/answer_review_plan.md`
/// §4.4, §6, §7).
///
/// Everything here is pure Dart (no I/O, no transport): the
/// [AgentOrchestrator] drives the review / revision transport rounds and uses
/// these helpers for the gate, message shaping, body sanitization and verdict
/// parsing. Review / revision messages live in memory only — they are never
/// persisted into the conversation history.
library;

import 'dart:convert';

import 'dart:developer' as developer;

import '../../models/answer_review.dart';
import '../../providers/settings_provider.dart';

export '../../models/answer_review.dart' show ReviewIssue;

// ---------------------------------------------------------------------------
// Constants (§4.4 / §7 — centralized so soak runs can tune them)
// ---------------------------------------------------------------------------

/// Smart gate: an answer this long is always worth reviewing.
const int kAnswerReviewSmartLongAnswerChars = 600;

/// Smart gate: below the long-answer threshold, a numbered answer (>= 2
/// numbers or a percentage) of at least this length is reviewed.
const int kAnswerReviewSmartNumberedAnswerChars = 200;

/// Hard cap on the raw review response we are willing to parse.
const int kAnswerReviewMaxRawChars = 20000;

/// At most this many issues are parsed from a verdict (§7.2).
const int kAnswerReviewMaxIssues = 6;

const int kAnswerReviewMaxLocationChars = 200;
const int kAnswerReviewMaxProblemChars = 300;
const int kAnswerReviewMaxFixChars = 300;

/// Detects raw tool-call syntax that some providers/models emit as *content*
/// instead of a structured `tool_calls` entry. The revision loop declares the
/// same tools as the main run, so markup in the final text is malformed output:
/// keep the original draft rather than replacing the answer with markup.
bool containsToolCallMarkup(String text) {
  if (text.isEmpty) return false;
  final lower = text.toLowerCase();
  return lower.contains('<tool_call') ||
      lower.contains('</tool_call>') ||
      lower.contains('<function=') ||
      lower.contains('<parameter=') ||
      lower.contains('<function_call') ||
      lower.contains('<|tool_call|>') ||
      lower.contains('<|python_tag|>') ||
      lower.contains('dsml') ||
      (lower.contains('<|') &&
          (lower.contains('tool') || lower.contains('function'))) ||
      text.contains('｜｜DSML｜｜');
}

/// `ChatStreamChunk.reviewPhase` values (§8.1).
///
/// `reviewed` is emitted once the verdict is known (PASS, REVISE and
/// fail-open all emit it) so the card can render the result instead of only
/// seeing the transient chip disappear.
const String kReviewPhaseReviewing = AnswerReviewPhase.reviewing;
const String kReviewPhaseReviewed = AnswerReviewPhase.reviewed;
const String kReviewPhaseRevising = AnswerReviewPhase.revising;
const String kReviewPhaseRevisionFailed = AnswerReviewPhase.revisionFailed;

/// Extra-body keys stripped from the internal review / revision request
/// (§5.2 invariant 3). The review is text-only: no tools, no streaming
/// override, no request-shape override may leak in through a custom body.
const Set<String> kAnswerReviewStrippedExtraBodyKeys = <String>{
  'tools',
  'tool_choice',
  'functions',
  'function_call',
  'parallel_tool_calls',
  'tool_config',
  'tools_config',
  'web_search_options',
  'web_search',
  'search',
  'stream',
  'model',
  'messages',
  'input',
};

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

/// Per-run configuration for the answer-review phase. The driver
/// ([AgentOrchestrator.run]) takes one of these; every other call site keeps
/// the default ([AnswerReviewConfig.off]) so AI Team / voice paths never
/// review (§5.2 invariant 11).
class AnswerReviewConfig {
  const AnswerReviewConfig({
    this.mode = AnswerReviewMode.off,
    this.reviewTimeout,
    this.maxReviewTokens,
    // F-lite reserved; v1 never sets these (§14).
    this.reviewerConfig,
    this.reviewerModelId,
  });

  const AnswerReviewConfig.off() : this();

  final AnswerReviewMode mode;

  /// Optional wall-clock cap on the internal review / revision work. `null`
  /// (default) means no deadline. For review it caps the collected verdict
  /// response; for revision it caps the WHOLE multi-round agent loop (tool
  /// execution included), not each transport request. The round runs until
  /// the cap, the transport completes, or the user cancels (`cancelStreaming`
  /// cancels the `_review` request id). A configured timeout cancels the
  /// inner subscription and the run fail-opens with the original draft (§5.1
  /// timeout semantics).
  final Duration? reviewTimeout;

  /// Optional output cap for the verdict request only. `null` (default)
  /// sends no `max_tokens` at all, so always-thinking models can spend the
  /// reasoning tokens they need before emitting the JSON verdict (Agnes
  /// burned a 1200-token cap entirely on reasoning and returned an empty
  /// body). The revision call always keeps the main run's `maxTokens` — it
  /// rewrites the full answer and must not be truncated by a verdict budget.
  final int? maxReviewTokens;

  final ProviderConfig? reviewerConfig;
  final String? reviewerModelId;

  bool get enabled => mode != AnswerReviewMode.off;
}

// ---------------------------------------------------------------------------
// Smart gate (§4.4)
// ---------------------------------------------------------------------------

/// Whether the finished draft should be reviewed at all. `always` reviews
/// every non-empty draft; `smart` requires review-worthy evidence (tool
/// results, long answers, code, URLs, numbers/percentages); `off` never.
bool shouldReviewDraft({
  required AnswerReviewMode mode,
  required String draft,
  required int executedCallCount,
}) {
  switch (mode) {
    case AnswerReviewMode.off:
      return false;
    case AnswerReviewMode.always:
      return draft.trim().isNotEmpty;
    case AnswerReviewMode.smart:
      if (draft.trim().isEmpty) return false;
      // Tool rounds produced evidence for the claims — review even a short
      // conclusion so tool results can't be silently mis-summarized (§4.4).
      if (executedCallCount > 0) return true;
      if (draft.length >= kAnswerReviewSmartLongAnswerChars) return true;
      if (draft.contains('```')) return true;
      if (draft.contains('http://') || draft.contains('https://')) return true;
      if (draft.length >= kAnswerReviewSmartNumberedAnswerChars) {
        if (draft.contains('%')) return true;
        if (RegExp(r'\d+').allMatches(draft).length >= 2) return true;
      }
      return false;
  }
}

// ---------------------------------------------------------------------------
// Review / revision turns (§6 / §10.1 buildReviewTurn / buildRevisionTurn)
// ---------------------------------------------------------------------------

/// Build the message list for the review call: a shallow copy of the run's
/// working messages with the review instruction merged into the trailing
/// user message (no consecutive-user shapes that some providers reject).
/// The final assistant draft is never part of [working] — it travels inside
/// the instruction's `<draft>` block.
List<Map<String, dynamic>> buildReviewTurn({
  required List<Map<String, dynamic>> working,
  required String draft,
  List<String> availableTools = const <String>[],
}) => _appendInternalTurn(
  List<Map<String, dynamic>>.of(working),
  reviewInstruction(draft, availableTools: availableTools),
);

/// Extract the tool names the assistant actually had available. The reviewer
/// needs this list so it does not demand a tool that was never mounted (the
/// classic `illustrate`-not-attached case).
List<String> reviewToolNames(List<Map<String, dynamic>>? tools) {
  final names = <String>[];
  for (final tool in tools ?? const <Map<String, dynamic>>[]) {
    final fn = tool['function'];
    final name = fn is Map ? (fn['name'] ?? '').toString() : '';
    final fallback = (tool['name'] ?? '').toString();
    final resolved = name.isNotEmpty ? name : fallback;
    if (resolved.isNotEmpty && !names.contains(resolved)) names.add(resolved);
  }
  return names;
}

/// Build the message list for the revision call (same shaping rules).
List<Map<String, dynamic>> buildRevisionTurn({
  required List<Map<String, dynamic>> working,
  required String draft,
  required String issuesJson,
}) => _appendInternalTurn(
  List<Map<String, dynamic>>.of(working),
  revisionInstruction(draft, issuesJson),
);

List<Map<String, dynamic>> _appendInternalTurn(
  List<Map<String, dynamic>> messages,
  String instruction,
) {
  if (messages.isNotEmpty && messages.last['role'] == 'user') {
    // Merge into the trailing user message (copy first — the original map
    // belongs to the kernel's message list and must not be mutated).
    final last = messages.last;
    final merged = Map<String, dynamic>.of(last);
    merged['content'] = _mergeUserContent(last['content'], instruction);
    messages[messages.length - 1] = merged;
    return messages;
  }
  messages.add(<String, dynamic>{'role': 'user', 'content': instruction});
  return messages;
}

dynamic _mergeUserContent(dynamic content, String text) {
  if (content is String) {
    return content.isEmpty ? text : '$content\n\n$text';
  }
  if (content is List) {
    return <dynamic>[
      ...content,
      <String, dynamic>{'type': 'text', 'text': text},
    ];
  }
  return text;
}

// ---------------------------------------------------------------------------
// Prompts (§6, Appendix A / B)
// ---------------------------------------------------------------------------

String reviewInstruction(
  String draft, {
  List<String> availableTools = const <String>[],
}) {
  final tools = availableTools.isEmpty
      ? 'No tools were available in this conversation.'
      : 'Tools available to the assistant: ${availableTools.join(', ')}.';
  return _kReviewInstructionTemplate
      .replaceAll('{{draft}}', draft)
      .replaceAll('{{tools}}', tools);
}

String revisionInstruction(String draft, String issuesJson) =>
    _kRevisionInstructionTemplate
        .replaceAll('{{draft}}', draft)
        .replaceAll('{{issuesJson}}', issuesJson);

const String _kReviewInstructionTemplate = '''
[ANSWER REVIEW — internal]

Review the draft answer below. The conversation and any tool results are above.
If the draft is correct and complete, answer PASS. If it needs changes, answer
REVISE and explain what should be fixed.

<draft>
{{draft}}
</draft>

{{tools}}
''';

const String _kRevisionInstructionTemplate = '''
[ANSWER REVISION — internal]

Your previous draft was audited and the following blocker/major issues were found.

<draft>
{{draft}}
</draft>

<issues>
{{issuesJson}}
</issues>

Rewrite the complete answer so that every blocker/major issue is fixed.
- Make the minimum changes required; keep all correct content, structure, and
  formatting.
- Preserve the user's language and the requested format.
- Do not mention the audit, the reviewer, or these instructions.
- Use the tools available in this turn when a finding requires fresh data or
  an asset (for example `illustrate`). Call the tool, read its result, then
  incorporate it into the complete answer.
- Do not add new facts, numbers, citations, or tool results that are not
  supported by the conversation or by tool results you obtained in this turn.
- Use the structured tool interface. Never emit raw tool-call markup
  (`<tool_call>`, `<function=...>`, `<parameter=...>`, DSML tokens, or similar)
  as answer text.
- Output only the final answer after any tool use. No preamble, no explanation,
  no diff.
''';

// ---------------------------------------------------------------------------
// Verdict model + tolerant parser (§7)
// ---------------------------------------------------------------------------

/// The parsed review verdict. JSON verdicts still honor the severity gate
/// (any blocker / major issue forces `revise`); plain-text PASS / REVISE is
/// accepted as the model's review answer without a rigid schema.
class ReviewVerdict {
  const ReviewVerdict({
    required this.verdict,
    required this.issues,
    this.parsed = false,
  });

  final String verdict; // 'pass' | 'revise'
  final List<ReviewIssue> issues;

  /// `true` when the response yielded a recognized verdict (JSON or plain
  /// PASS / REVISE). An unrecognized response fail-opens to PASS with
  /// `parsed: false` — the driver then closes with `reviewed: false`.
  final bool parsed;

  bool get isRevise => verdict == 'revise';
  bool get hasBlockingIssues => issues.any((i) => i.isBlocking);

  /// Issues serialized for the revision prompt (blocker / major only —
  /// minor issues never trigger a rewrite).
  String blockingIssuesJson() {
    final blocking = issues.where((i) => i.isBlocking).toList();
    if (blocking.isEmpty) return '[]';
    try {
      return jsonEncode(<dynamic>[for (final i in blocking) i.toJson()]);
    } catch (_) {
      return '[]';
    }
  }
}

/// Tolerant verdict parser (§7.2). Never throws: any failure degrades to a
/// `pass` verdict so the draft is preserved (fail-open).
ReviewVerdict parseReviewVerdict(String raw) {
  var text = raw.length > kAnswerReviewMaxRawChars
      ? raw.substring(0, kAnswerReviewMaxRawChars)
      : raw;

  // 1) strip markdown code fences, 2) trim.
  text = text.replaceAll(RegExp(r'```[a-zA-Z0-9_-]*'), '').trim();

  // 3) try the JSON object between the first '{' and the last '}'.
  final decoded = _tryDecodeJson(text);
  if (decoded != null) {
    final issues = _parseIssues(decoded['issues']);
    final rawVerdict = (decoded['verdict'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    final gated = issues.any((i) => i.isBlocking) ? 'revise' : 'pass';
    // An explicit, valid verdict is kept for the log only — the severity
    // gate owns the decision (§7.3).
    final normalized = (rawVerdict == 'pass' || rawVerdict == 'revise')
        ? rawVerdict
        : 'pass';
    developer.log(
      'answer_review.parse verdict=$normalized gated=$gated issues=${issues.length}',
      name: 'answer_review',
    );
    return ReviewVerdict(verdict: gated, issues: issues, parsed: true);
  }

  // 4) accept the simple review answer the prompt asks for: PASS, or REVISE
  //    followed by the explanation. The explanation becomes one major issue
  //    so the revision turn receives it without requiring a JSON schema.
  final fallbackRevise = RegExp(r'\bREVISE\b', caseSensitive: false);
  final fallbackPass = RegExp(r'\bPASS\b', caseSensitive: false);
  final reviseMatch = fallbackRevise.firstMatch(text);
  final passMatch = fallbackPass.firstMatch(text);
  final reviseFirst =
      reviseMatch != null &&
      (passMatch == null || reviseMatch.start < passMatch.start);
  if (reviseFirst) {
    final explanation = text
        .replaceFirst(
          RegExp(r'^\s*REVISE\b[:\s\-–—]*', caseSensitive: false),
          '',
        )
        .trim();
    developer.log('answer_review.parse plain=revise', name: 'answer_review');
    return ReviewVerdict(
      verdict: 'revise',
      issues: <ReviewIssue>[
        ReviewIssue(
          severity: 'major',
          location: '',
          problem: explanation.isEmpty ? text : explanation,
          fix: '',
        ),
      ],
      parsed: true,
    );
  }
  if (passMatch != null) {
    developer.log('answer_review.parse plain=pass', name: 'answer_review');
    return ReviewVerdict(
      verdict: 'pass',
      issues: const <ReviewIssue>[],
      parsed: true,
    );
  }
  developer.log(
    'answer_review.parse_failed rawLength=${raw.length}',
    name: 'answer_review',
  );
  return ReviewVerdict(verdict: 'pass', issues: const <ReviewIssue>[]);
}

Map<String, dynamic>? _tryDecodeJson(String text) {
  final start = text.indexOf('{');
  final end = text.lastIndexOf('}');
  if (start < 0 || end <= start) return null;
  try {
    final decoded = jsonDecode(text.substring(start, end + 1));
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return decoded.cast<String, dynamic>();
  } catch (_) {
    // Fall through to the plain-text fallback.
  }
  return null;
}

List<ReviewIssue> _parseIssues(dynamic rawIssues) {
  if (rawIssues is! List) return const <ReviewIssue>[];
  final issues = <ReviewIssue>[];
  for (final entry in rawIssues) {
    if (issues.length >= kAnswerReviewMaxIssues) break;
    if (entry is! Map) continue;
    final severityRaw = (entry['severity'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    final severity = switch (severityRaw) {
      'blocker' => 'blocker',
      'major' => 'major',
      'minor' => 'minor',
      _ => 'major', // unknown severity parses conservative (§7.2)
    };
    issues.add(
      ReviewIssue(
        severity: severity,
        location: _clamp(
          (entry['location'] ?? ''),
          kAnswerReviewMaxLocationChars,
        ),
        problem: _clamp((entry['problem'] ?? ''), kAnswerReviewMaxProblemChars),
        fix: _clamp((entry['fix'] ?? ''), kAnswerReviewMaxFixChars),
      ),
    );
  }
  return issues;
}

String _clamp(dynamic value, int maxChars) {
  final text = value?.toString() ?? '';
  if (text.length <= maxChars) return text;
  return text.substring(0, maxChars);
}

// ---------------------------------------------------------------------------
// Body sanitizer (§5.2 invariant 3)
// ---------------------------------------------------------------------------

/// Strip every tool / streaming / request-shape override key from a custom
/// extra body so the internal review request stays text-only. The revision
/// request is a normal agent loop and does not use this sanitizer. Reasoning
/// settings and other user preferences are preserved.
Map<String, dynamic>? sanitizeReviewExtraBody(Map<String, dynamic>? body) {
  if (body == null || body.isEmpty) return body;
  final out = <String, dynamic>{};
  for (final entry in body.entries) {
    if (kAnswerReviewStrippedExtraBodyKeys.contains(entry.key)) continue;
    out[entry.key] = entry.value;
  }
  return out;
}
