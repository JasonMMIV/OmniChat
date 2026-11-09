/// Per-run state machine for the Answer Review v1 stream phases
/// (`docs/answer_review_plan.md` §9.1, `docs/answer_review_cards_plan.md` §3).
///
/// Pure Dart and unit-testable. One instance lives on [StreamingState]
/// (`stream_controller.dart`) for the duration of a single generation run.
library;

import '../../../core/models/answer_review.dart';

class AnswerReviewStreamState {
  /// `null` | `reviewing` | `reviewed` | `revising` | `passed` |
  /// `revised` | `failed_open` | `revision_failed` | `cancelled` |
  /// `interrupted`.
  String? phase;

  /// `true` when the final answer was reviewed and applied (parsed PASS or a
  /// successful revision). Memory-only; the persisted report is authoritative.
  bool reviewed = false;

  /// Review + revision tokens (the terminal's `reviewUsage` subset).
  int reviewTokens = 0;

  /// The draft captured at `reviewing` time. The revision clears the visible
  /// content, so this is the only copy the card can show while revising.
  String? draft;

  /// Latest report emitted by the orchestrator (or synthesized locally).
  AnswerReviewReport? report;

  DateTime? reviewStartedAt;
  DateTime? revisionStartedAt;

  String? _draftBackup;
  bool _restoreConsumed = false;

  bool get isRevising => phase == AnswerReviewPhase.revising;

  /// `true` when the user cancelled / the stream errored mid-revision and
  /// the original draft must be restored before persistence.
  bool get needsDraftRestore => isRevising && _draftBackup != null;

  /// The best draft available for the card: the `reviewing` snapshot, or the
  /// revision backup if the snapshot was somehow absent.
  String? get draftForCard => draft ?? _draftBackup;

  void beginReviewing({
    String? draft,
    DateTime? at,
    AnswerReviewReport? report,
  }) {
    phase = AnswerReviewPhase.reviewing;
    if (draft != null) this.draft = draft;
    if (at != null) reviewStartedAt = at;
    if (report != null) this.report = report;
  }

  /// Apply a report emitted by the orchestrator. It may be a transient phase
  /// (`revising`) or a terminal one (`passed` / `failed_open`).
  void applyReport(AnswerReviewReport report) {
    this.report = report;
    phase = report.phase;
    reviewed = report.reviewed;
    if (report.reviewTokens > 0) reviewTokens = report.reviewTokens;
    if (report.startedAtMs != null && reviewStartedAt == null) {
      reviewStartedAt = DateTime.fromMillisecondsSinceEpoch(
        report.startedAtMs!,
      );
    }
  }

  /// Enter the revision phase, backing up the draft that is currently on
  /// screen. Re-entering (defensive retry) never overwrites the ORIGINAL
  /// draft — the restore path must always bring back what the user saw.
  void beginRevision(String draft) {
    _draftBackup ??= draft;
    _restoreConsumed = false;
    this.draft ??= draft;
    phase = AnswerReviewPhase.revising;
    revisionStartedAt ??= DateTime.now();
  }

  void markRevisionFailed([AnswerReviewReport? report]) {
    if (report != null) {
      applyReport(report);
    } else {
      phase = AnswerReviewPhase.revisionFailed;
    }
  }

  void markCancelled() {
    phase = AnswerReviewPhase.cancelled;
    report = (report ?? const AnswerReviewReport()).copyWith(
      phase: AnswerReviewPhase.cancelled,
      reviewed: false,
      failReason: 'cancelled',
      finishedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  void markInterrupted() {
    phase = AnswerReviewPhase.interrupted;
    report = (report ?? const AnswerReviewReport()).copyWith(
      phase: AnswerReviewPhase.interrupted,
      reviewed: false,
      failReason: 'interrupted',
      finishedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// Consume the backed-up draft for a restore; the backup is cleared so the
  /// restore runs exactly once.
  String takeDraftForRestore() {
    if (_restoreConsumed) return '';
    _restoreConsumed = true;
    final value = _draftBackup ?? draft ?? '';
    _draftBackup = null;
    phase = AnswerReviewPhase.revisionFailed;
    return value;
  }

  /// Terminal arrived: fold the outcome in and drop any backup. The normal
  /// terminal already carries the final content, so no restore is needed.
  void finish({
    required bool reviewed,
    int reviewTokens = 0,
    AnswerReviewReport? report,
    String? finalPhase,
  }) {
    phase = null;
    this.reviewed = reviewed;
    if (reviewTokens > 0) this.reviewTokens = reviewTokens;
    if (report != null) this.report = report;
    if (finalPhase != null && this.report != null) {
      this.report = this.report!.copyWith(
        phase: finalPhase,
        reviewed: reviewed,
        reviewTokens: this.reviewTokens,
        finishedAtMs: DateTime.now().millisecondsSinceEpoch,
      );
    }
    _draftBackup = null;
  }
}
