import 'package:flutter/foundation.dart';

import '../../../core/models/answer_review.dart';

/// Lightweight notifier for streaming message content updates.
///
/// This class provides a way to update streaming message content without
/// triggering a full page rebuild. Instead of using ChangeNotifier.notifyListeners()
/// which causes the entire HomePage to rebuild, this uses ValueNotifier
/// so only the specific message widget that's listening will rebuild.
///
/// Usage:
/// 1. StreamController updates content via updateContent()
/// 2. ChatMessageWidget uses ValueListenableBuilder to listen to contentNotifier
/// 3. Only the streaming message widget rebuilds, not the entire page
class StreamingContentNotifier {
  /// Map of message ID to its content notifier.
  /// Each streaming message has its own ValueNotifier<String>.
  final Map<String, ValueNotifier<StreamingContentData>> _notifiers =
      <String, ValueNotifier<StreamingContentData>>{};

  /// Guards against calls after [dispose] (async stream callbacks can still
  /// fire once the page is gone).
  bool _disposed = false;

  /// Conversation-wide revision counter for tool-part changes.
  ///
  /// The todo dock is no longer tied to a streaming message: it has to keep
  /// reflecting the conversation's latest plan while the run is idle. Widgets
  /// that derive state from the shared `toolParts` map listen to this counter
  /// and rebuild on every tool call/result (including user clears appended
  /// outside a run).
  final ValueNotifier<int> toolRevision = ValueNotifier<int>(0);

  /// Get or create a notifier for a message.
  ValueNotifier<StreamingContentData> getNotifier(String messageId) {
    return _notifiers.putIfAbsent(
      messageId,
      () => ValueNotifier<StreamingContentData>(
        const StreamingContentData(content: '', totalTokens: 0),
      ),
    );
  }

  /// Check if a notifier exists for a message.
  bool hasNotifier(String messageId) => _notifiers.containsKey(messageId);

  /// Update content for a streaming message.
  /// This will only notify the specific widget listening to this message's notifier.
  void updateContent(String messageId, String content, int totalTokens) {
    final notifier = _notifiers[messageId];
    if (notifier != null) {
      final current = notifier.value;
      notifier.value = StreamingContentData(
        content: content,
        totalTokens: totalTokens,
        reasoningText: current.reasoningText,
        reasoningStartAt: current.reasoningStartAt,
        reasoningFinishedAt: current.reasoningFinishedAt,
        toolPartsVersion: current.toolPartsVersion,
        uiVersion: current.uiVersion,
        aiTeamProposalsJson: current.aiTeamProposalsJson,
        retryStatus: current.retryStatus,
        reviewPhase: current.reviewPhase,
        reviewReport: current.reviewReport,
        reviewDraft: current.reviewDraft,
      );
    }
  }

  /// Update the Answer Review v1 phase indicator (`reviewing` /
  /// `revising` / `revision_failed`, or `null` to clear it). The bubble
  /// renders an inline pill above the streamed content — same mechanism as
  /// [updateRetryStatus].
  void updateReviewPhase(String messageId, String? phase) {
    final notifier = _notifiers[messageId];
    if (notifier != null) {
      final current = notifier.value;
      notifier.value = StreamingContentData(
        content: current.content,
        totalTokens: current.totalTokens,
        reasoningText: current.reasoningText,
        reasoningStartAt: current.reasoningStartAt,
        reasoningFinishedAt: current.reasoningFinishedAt,
        toolPartsVersion: current.toolPartsVersion,
        uiVersion: current.uiVersion,
        aiTeamProposalsJson: current.aiTeamProposalsJson,
        retryStatus: current.retryStatus,
        reviewPhase: phase,
        reviewReport: current.reviewReport,
        reviewDraft: current.reviewDraft,
      );
    }
  }

  /// Update the whole live review card in one notification: phase, report and
  /// the draft snapshot. Called only on phase/report changes, never per token.
  void updateAnswerReview(
    String messageId, {
    String? phase,
    AnswerReviewReport? report,
    String? draft,
    bool clearPhase = false,
  }) {
    final notifier = _notifiers[messageId];
    if (notifier == null) return;
    final current = notifier.value;
    notifier.value = StreamingContentData(
      content: current.content,
      totalTokens: current.totalTokens,
      reasoningText: current.reasoningText,
      reasoningStartAt: current.reasoningStartAt,
      reasoningFinishedAt: current.reasoningFinishedAt,
      toolPartsVersion: current.toolPartsVersion,
      uiVersion: current.uiVersion,
      aiTeamProposalsJson: current.aiTeamProposalsJson,
      retryStatus: current.retryStatus,
      reviewPhase: clearPhase ? null : (phase ?? current.reviewPhase),
      reviewReport: report ?? current.reviewReport,
      reviewDraft: draft ?? current.reviewDraft,
    );
  }

  /// Update the L1 retry status indicator. The bubble reads
  /// [StreamingContentData.retryStatus] and renders an inline
  /// "重試中… 1/3" placeholder above the streamed content so the
  /// user can see retries are happening — relying on top snackbars
  /// alone is fragile because the terminal error snackbar fires
  /// ~7 seconds later and visually replaces the retry toast.
  ///
  /// Pass `null` to clear the indicator once the new attempt starts
  /// streaming real content.
  void updateRetryStatus(String messageId, RetryStatus? status) {
    final notifier = _notifiers[messageId];
    if (notifier != null) {
      final current = notifier.value;
      notifier.value = StreamingContentData(
        content: current.content,
        totalTokens: current.totalTokens,
        reasoningText: current.reasoningText,
        reasoningStartAt: current.reasoningStartAt,
        reasoningFinishedAt: current.reasoningFinishedAt,
        toolPartsVersion: current.toolPartsVersion,
        uiVersion: current.uiVersion,
        aiTeamProposalsJson: current.aiTeamProposalsJson,
        retryStatus: status,
        reviewPhase: current.reviewPhase,
        reviewReport: current.reviewReport,
        reviewDraft: current.reviewDraft,
      );
    }
  }

  /// Update reasoning content for a streaming message.
  void updateReasoning(
    String messageId, {
    String? reasoningText,
    DateTime? reasoningStartAt,
    DateTime? reasoningFinishedAt,
  }) {
    final notifier = _notifiers[messageId];
    if (notifier != null) {
      final current = notifier.value;
      notifier.value = StreamingContentData(
        content: current.content,
        totalTokens: current.totalTokens,
        reasoningText: reasoningText ?? current.reasoningText,
        reasoningStartAt: reasoningStartAt ?? current.reasoningStartAt,
        reasoningFinishedAt: reasoningFinishedAt ?? current.reasoningFinishedAt,
        toolPartsVersion: current.toolPartsVersion,
        uiVersion: current.uiVersion,
        aiTeamProposalsJson: current.aiTeamProposalsJson,
        retryStatus: current.retryStatus,
        reviewPhase: current.reviewPhase,
        reviewReport: current.reviewReport,
        reviewDraft: current.reviewDraft,
      );
    }
  }

  /// Notify that tool parts have been updated.
  /// Uses a version counter to trigger rebuild without copying tool data.
  ///
  /// [toolRevision] is bumped even when no per-message notifier exists: the
  /// todo dock derives its state from the shared `toolParts` map and must
  /// rebuild for user-initiated clears appended to an idle conversation.
  void notifyToolPartsUpdated(String messageId) {
    if (_disposed) return;
    final notifier = _notifiers[messageId];
    if (notifier != null) {
      final current = notifier.value;
      notifier.value = StreamingContentData(
        content: current.content,
        totalTokens: current.totalTokens,
        reasoningText: current.reasoningText,
        reasoningStartAt: current.reasoningStartAt,
        reasoningFinishedAt: current.reasoningFinishedAt,
        toolPartsVersion: current.toolPartsVersion + 1,
        uiVersion: current.uiVersion,
        aiTeamProposalsJson: current.aiTeamProposalsJson,
        retryStatus: current.retryStatus,
        reviewPhase: current.reviewPhase,
        reviewReport: current.reviewReport,
        reviewDraft: current.reviewDraft,
      );
    }
    toolRevision.value++;
  }

  /// Force a rebuild of the streaming message widget.
  /// Used when external state like reasoning expanded changes.
  void forceRebuild(String messageId) {
    final notifier = _notifiers[messageId];
    if (notifier != null) {
      final current = notifier.value;
      notifier.value = StreamingContentData(
        content: current.content,
        totalTokens: current.totalTokens,
        reasoningText: current.reasoningText,
        reasoningStartAt: current.reasoningStartAt,
        reasoningFinishedAt: current.reasoningFinishedAt,
        toolPartsVersion: current.toolPartsVersion,
        uiVersion: current.uiVersion + 1,
        aiTeamProposalsJson: current.aiTeamProposalsJson,
        retryStatus: current.retryStatus,
        reviewPhase: current.reviewPhase,
        reviewReport: current.reviewReport,
        reviewDraft: current.reviewDraft,
      );
    }
  }

  /// Update AI Team proposals JSON for a streaming message.
  /// Used during the proposal phase to show proposals in real-time as each proposer completes.
  void updateProposals(String messageId, String? proposalsJson) {
    final notifier = _notifiers[messageId];
    if (notifier != null) {
      final current = notifier.value;
      notifier.value = StreamingContentData(
        content: current.content,
        totalTokens: current.totalTokens,
        reasoningText: current.reasoningText,
        reasoningStartAt: current.reasoningStartAt,
        reasoningFinishedAt: current.reasoningFinishedAt,
        toolPartsVersion: current.toolPartsVersion,
        uiVersion: current.uiVersion,
        aiTeamProposalsJson: proposalsJson,
        retryStatus: current.retryStatus,
        reviewPhase: current.reviewPhase,
        reviewReport: current.reviewReport,
        reviewDraft: current.reviewDraft,
      );
    }
  }

  /// Remove notifier when streaming is complete.
  void removeNotifier(String messageId) {
    final notifier = _notifiers.remove(messageId);
    notifier?.dispose();
  }

  /// Clear all notifiers (e.g., when switching conversations).
  ///
  /// Bumps [toolRevision] so the idle todo dock re-derives from the newly
  /// loaded conversation instead of keeping the previous plan on screen.
  void clear() {
    if (_disposed) return;
    for (final notifier in _notifiers.values) {
      notifier.dispose();
    }
    _notifiers.clear();
    toolRevision.value++;
  }

  /// Dispose all resources.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final notifier in _notifiers.values) {
      notifier.dispose();
    }
    _notifiers.clear();
    toolRevision.dispose();
  }
}

/// Status of the L1 retry loop, surfaced to the streaming message
/// bubble so the user can see when a retry is in flight. The bubble
/// reads this via [StreamingContentData.retryStatus].
@immutable
class RetryStatus {
  const RetryStatus({
    required this.attempt,
    required this.maxAttempts,
    required this.isSilentInterrupt,
  });

  /// 1-based retry number (1 = first retry, 2 = second, etc.).
  final int attempt;

  /// Total allowed retries (== [StreamRetryConfig.maxRetriesPerMessage]).
  final int maxAttempts;

  /// `true` if the retry was triggered by a silent stream
  /// interruption (proxy killed the SSE body), `false` for
  /// transient network / 5xx / 408 / 429 errors.
  final bool isSilentInterrupt;
}

/// Data class for streaming content.
@immutable
class StreamingContentData {
  const StreamingContentData({
    required this.content,
    required this.totalTokens,
    this.reasoningText,
    this.reasoningStartAt,
    this.reasoningFinishedAt,
    this.toolPartsVersion = 0,
    this.uiVersion = 0,
    this.aiTeamProposalsJson,
    this.retryStatus,
    this.reviewPhase,
    this.reviewReport,
    this.reviewDraft,
  });

  final String content;
  final int totalTokens;
  final String? reasoningText;
  final DateTime? reasoningStartAt;
  final DateTime? reasoningFinishedAt;

  /// Version counter for tool parts updates. Incrementing this triggers rebuild.
  final int toolPartsVersion;

  /// Version counter for UI state changes (e.g., reasoning expanded toggle).
  final int uiVersion;

  /// AI Team proposals JSON for real-time display during proposal phase.
  final String? aiTeamProposalsJson;

  /// L1 retry status; `null` when no retry is in flight (first
  /// attempt, or post-retry success).
  final RetryStatus? retryStatus;

  /// Answer Review v1 phase; `null` when no review card is showing
  /// (`reviewing` / `reviewed` / `revising` / `revision_failed` otherwise).
  final String? reviewPhase;

  /// Latest live review report (verdict/issues/timings).
  final AnswerReviewReport? reviewReport;

  /// Draft snapshot captured at `reviewing`; the card needs it while the
  /// revision is clearing the visible answer.
  final String? reviewDraft;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StreamingContentData &&
          runtimeType == other.runtimeType &&
          content == other.content &&
          totalTokens == other.totalTokens &&
          reasoningText == other.reasoningText &&
          reasoningStartAt == other.reasoningStartAt &&
          reasoningFinishedAt == other.reasoningFinishedAt &&
          toolPartsVersion == other.toolPartsVersion &&
          uiVersion == other.uiVersion &&
          aiTeamProposalsJson == other.aiTeamProposalsJson &&
          retryStatus == other.retryStatus &&
          reviewPhase == other.reviewPhase &&
          reviewReport == other.reviewReport &&
          reviewDraft == other.reviewDraft;

  @override
  int get hashCode =>
      content.hashCode ^
      totalTokens.hashCode ^
      reasoningText.hashCode ^
      reasoningStartAt.hashCode ^
      reasoningFinishedAt.hashCode ^
      toolPartsVersion.hashCode ^
      uiVersion.hashCode ^
      aiTeamProposalsJson.hashCode ^
      retryStatus.hashCode ^
      reviewPhase.hashCode ^
      reviewReport.hashCode ^
      reviewDraft.hashCode;
}
