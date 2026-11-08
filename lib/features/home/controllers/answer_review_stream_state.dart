/// Per-run state machine for the Answer Review v1 stream phases
/// (docs/answer_review_plan.md §9.1).
///
/// Pure Dart and unit-testable. One instance lives on [StreamingState]
/// (`stream_controller.dart`) for the duration of a single generation run.
class AnswerReviewStreamState {
  /// `null` | `reviewing` | `revising` | `revision_failed`.
  String? phase;

  /// `true` when the final answer was reviewed and applied (parsed PASS or a
  /// successful revision). Memory-only; never persisted.
  bool reviewed = false;

  /// Review + revision tokens (the terminal's `reviewUsage` subset).
  /// Memory-only; the UI must not re-add it to the terminal usage.
  int reviewTokens = 0;

  String? _draftBackup;

  bool get isRevising => phase == 'revising';

  /// `true` when the user cancelled / the stream errored mid-revision and
  /// the original draft must be restored before persistence.
  bool get needsDraftRestore => isRevising && _draftBackup != null;

  void beginReviewing() => phase = 'reviewing';

  /// Enter the revision phase, backing up the draft that is currently on
  /// screen. Re-entering (defensive retry) never overwrites the ORIGINAL
  /// draft — the restore path must always bring back what the user saw.
  void beginRevision(String draft) {
    _draftBackup ??= draft;
    phase = 'revising';
  }

  void markRevisionFailed() => phase = 'revision_failed';

  /// Consume the backed-up draft for a restore; the backup is cleared so the
  /// restore runs exactly once.
  String takeDraftForRestore() {
    final draft = _draftBackup ?? '';
    _draftBackup = null;
    phase = 'revision_failed';
    return draft;
  }

  /// Terminal arrived: fold the outcome in and drop any backup. The normal
  /// terminal already carries the final content, so no restore is needed.
  void finish({required bool reviewed, int reviewTokens = 0}) {
    phase = null;
    this.reviewed = reviewed;
    this.reviewTokens = reviewTokens;
    _draftBackup = null;
  }
}
