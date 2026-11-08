/// Answer Review v1 — mode enum shared by settings, services and the UI
/// (`docs/answer_review_plan.md` §4.1).
///
/// Kept in `core/models` (pure Dart, no Flutter imports) so both
/// [SettingsProvider] and the agent-layer service can depend on it without
/// creating a `SettingsProvider → service` import cycle.
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
