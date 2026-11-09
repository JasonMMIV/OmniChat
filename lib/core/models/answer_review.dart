/// Answer Review v1 — models shared by settings, services, persistence and
/// the UI (`docs/answer_review_plan.md`, `docs/answer_review_cards_plan.md`).
///
/// Kept in `core/models` (pure Dart, no Flutter imports) so both
/// [SettingsProvider] and the agent-layer service can depend on it without
/// creating a `SettingsProvider → service` import cycle.
library;

/// Answer-review mode persisted as `answer_review_v1`.
enum AnswerReviewMode {
  /// Never review (default). Zero extra requests, zero UI change.
  off,

  /// Review only "review-worthy" drafts (tool results, long answers, code,
  /// numbers or URLs — see the smart gate in
  /// `lib/core/services/agent/answer_review.dart`).
  smart,

  /// Review every non-empty final answer.
  always,
}

/// Codec for the persisted `answer_review_v1` string. Unknown / null values
/// always fall back to [AnswerReviewMode.off] (fail-safe default).
extension AnswerReviewModeCodec on AnswerReviewMode {
  static AnswerReviewMode fromValue(String? value) => switch (value) {
    'smart' => AnswerReviewMode.smart,
    'always' => AnswerReviewMode.always,
    _ => AnswerReviewMode.off,
  };

  String get value => switch (this) {
    AnswerReviewMode.off => 'off',
    AnswerReviewMode.smart => 'smart',
    AnswerReviewMode.always => 'always',
  };
}

// ---------------------------------------------------------------------------
// Phase constants
// ---------------------------------------------------------------------------

/// All states a review card can show. The transient transport phases
/// (`reviewing` / `revising` / `reviewed` / `revision_failed`) come from
/// `ChatStreamChunk.reviewPhase`; the terminal phases are stored in the
/// report so a reloaded card renders the final state.
abstract final class AnswerReviewPhase {
  static const String reviewing = 'reviewing';
  static const String reviewed = 'reviewed';
  static const String revising = 'revising';
  static const String passed = 'passed';
  static const String revised = 'revised';
  static const String failedOpen = 'failed_open';
  static const String revisionFailed = 'revision_failed';
  static const String cancelled = 'cancelled';
  static const String interrupted = 'interrupted';

  static const Set<String> terminal = <String>{
    passed,
    revised,
    failedOpen,
    revisionFailed,
    cancelled,
    interrupted,
  };
}

/// `message_parts.kind` for the per-message review row.
const String kAnswerReviewPartKind = 'answer_review';

// ---------------------------------------------------------------------------
// Review issue
// ---------------------------------------------------------------------------

/// One review issue. [severity] is one of `blocker` / `major` / `minor`
/// (unknown severities parse as `major` — conservative).
class ReviewIssue {
  const ReviewIssue({
    required this.severity,
    required this.location,
    required this.problem,
    required this.fix,
  });

  final String severity;
  final String location;
  final String problem;
  final String fix;

  bool get isBlocking => severity == 'blocker' || severity == 'major';

  /// A finding that can only be fixed by calling a tool (for example
  /// "add an image_search result"). The review/revision turn is text-only, so
  /// such findings are dropped instead of triggering a rewrite that would
  /// end in tool-call markup.
  bool get requiresToolCall {
    final text = '$problem $fix'.toLowerCase();
    return text.contains('image_search') ||
        text.contains('image search') ||
        text.contains('tool call') ||
        text.contains('tool_call') ||
        text.contains('call the tool') ||
        text.contains('use the tool') ||
        text.contains('missing image') ||
        text.contains('add an image') ||
        text.contains('insert an image') ||
        text.contains('插入圖') ||
        text.contains('插入图') ||
        text.contains('缺少圖') ||
        text.contains('缺少图') ||
        text.contains('沒有圖') ||
        text.contains('没有图');
  }

  int get severityRank => switch (severity) {
    'blocker' => 0,
    'major' => 1,
    _ => 2,
  };

  Map<String, dynamic> toJson() => <String, dynamic>{
    'severity': severity,
    'location': location,
    'problem': problem,
    'fix': fix,
  };

  factory ReviewIssue.fromJson(Map<String, dynamic> json) => ReviewIssue(
    severity: (json['severity'] ?? 'major').toString(),
    location: (json['location'] ?? '').toString(),
    problem: (json['problem'] ?? '').toString(),
    fix: (json['fix'] ?? '').toString(),
  );
}

// ---------------------------------------------------------------------------
// Report
// ---------------------------------------------------------------------------

/// One complete review outcome, persisted as the `metadata_json` of a
/// `message_parts.kind='answer_review'` row. It is deliberately a value
/// object: the live state machine mutates a copy and writes the whole report.
class AnswerReviewReport {
  const AnswerReviewReport({
    this.schemaVersion = 1,
    this.phase = AnswerReviewPhase.reviewing,
    this.verdict,
    this.parsed = false,
    this.issues = const <ReviewIssue>[],
    this.reviewed = false,
    this.failReason,
    this.reviewMs = 0,
    this.revisionMs = 0,
    this.reviewTokens = 0,
    this.modelId,
    this.draftChars = 0,
    this.draftTruncated = false,
    this.startedAtMs,
    this.finishedAtMs,
  });

  final int schemaVersion;
  final String phase;

  /// `pass` | `revise` | null (review did not produce a verdict).
  final String? verdict;

  /// Whether the verdict JSON actually decoded. A malformed body fail-opens
  /// to PASS with `parsed == false`; the card must say "審查未完成".
  final bool parsed;

  final List<ReviewIssue> issues;

  /// True when the final answer was actually applied (parsed PASS or a
  /// successful revision).
  final bool reviewed;

  /// `timeout` / `error` / `empty` / `malformed` / `revision_failed` /
  /// `revision_tool_call`.
  final String? failReason;

  final int reviewMs;
  final int revisionMs;
  final int reviewTokens;
  final String? modelId;
  final int draftChars;
  final bool draftTruncated;
  final int? startedAtMs;
  final int? finishedAtMs;

  bool get isTerminal => AnswerReviewPhase.terminal.contains(phase);
  bool get isRevise => verdict == 'revise';
  bool get hasIssues => issues.isNotEmpty;

  List<ReviewIssue> get sortedIssues {
    final copy = List<ReviewIssue>.of(issues);
    copy.sort((a, b) => a.severityRank.compareTo(b.severityRank));
    return copy;
  }

  int get blockerCount => issues.where((i) => i.severity == 'blocker').length;
  int get majorCount => issues.where((i) => i.severity == 'major').length;
  int get minorCount => issues.where((i) => i.severity == 'minor').length;

  AnswerReviewReport copyWith({
    int? schemaVersion,
    String? phase,
    String? verdict,
    bool? parsed,
    List<ReviewIssue>? issues,
    bool? reviewed,
    String? failReason,
    int? reviewMs,
    int? revisionMs,
    int? reviewTokens,
    String? modelId,
    int? draftChars,
    bool? draftTruncated,
    int? startedAtMs,
    int? finishedAtMs,
  }) {
    return AnswerReviewReport(
      schemaVersion: schemaVersion ?? this.schemaVersion,
      phase: phase ?? this.phase,
      verdict: verdict ?? this.verdict,
      parsed: parsed ?? this.parsed,
      issues: issues ?? this.issues,
      reviewed: reviewed ?? this.reviewed,
      failReason: failReason ?? this.failReason,
      reviewMs: reviewMs ?? this.reviewMs,
      revisionMs: revisionMs ?? this.revisionMs,
      reviewTokens: reviewTokens ?? this.reviewTokens,
      modelId: modelId ?? this.modelId,
      draftChars: draftChars ?? this.draftChars,
      draftTruncated: draftTruncated ?? this.draftTruncated,
      startedAtMs: startedAtMs ?? this.startedAtMs,
      finishedAtMs: finishedAtMs ?? this.finishedAtMs,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'schemaVersion': schemaVersion,
    'phase': phase,
    if (verdict != null) 'verdict': verdict,
    'parsed': parsed,
    'issues': <dynamic>[for (final issue in issues) issue.toJson()],
    'reviewed': reviewed,
    if (failReason != null) 'failReason': failReason,
    'reviewMs': reviewMs,
    'revisionMs': revisionMs,
    'reviewTokens': reviewTokens,
    if (modelId != null) 'modelId': modelId,
    'draftChars': draftChars,
    'draftTruncated': draftTruncated,
    if (startedAtMs != null) 'startedAtMs': startedAtMs,
    if (finishedAtMs != null) 'finishedAtMs': finishedAtMs,
  };

  factory AnswerReviewReport.fromJson(Map<String, dynamic> json) {
    final rawIssues = json['issues'];
    final issues = <ReviewIssue>[];
    if (rawIssues is List) {
      for (final raw in rawIssues) {
        if (raw is Map) {
          issues.add(ReviewIssue.fromJson(raw.cast<String, dynamic>()));
        }
      }
    }
    return AnswerReviewReport(
      schemaVersion: _int(json['schemaVersion'], 1),
      phase: (json['phase'] ?? AnswerReviewPhase.interrupted).toString(),
      verdict: json['verdict']?.toString(),
      parsed: json['parsed'] == true,
      issues: issues,
      reviewed: json['reviewed'] == true,
      failReason: json['failReason']?.toString(),
      reviewMs: _int(json['reviewMs'], 0),
      revisionMs: _int(json['revisionMs'], 0),
      reviewTokens: _int(json['reviewTokens'], 0),
      modelId: json['modelId']?.toString(),
      draftChars: _int(json['draftChars'], 0),
      draftTruncated: json['draftTruncated'] == true,
      startedAtMs: _nullableInt(json['startedAtMs']),
      finishedAtMs: _nullableInt(json['finishedAtMs']),
    );
  }

  static int _int(Object? value, int fallback) {
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? fallback;
  }

  static int? _nullableInt(Object? value) {
    if (value == null) return null;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString());
  }
}

/// The persisted view of one review: the report plus the full draft captured
/// at `reviewing` time. New rows store the complete draft; [report.draftTruncated]
/// is only true on legacy rows written before the cap was removed.
class AnswerReviewRecord {
  const AnswerReviewRecord({
    required this.report,
    this.draft,
    this.partId,
    this.status = 'completed',
  });

  final AnswerReviewReport report;
  final String? draft;
  final int? partId;
  final String status;

  bool get interrupted => status == 'interrupted';
  bool get pending => status == 'pending';
}
