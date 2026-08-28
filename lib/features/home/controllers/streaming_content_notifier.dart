import 'package:flutter/foundation.dart';

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
      );
    }
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
      );
    }
  }

  /// Update reasoning content for a streaming message.
  void updateReasoning(String messageId, {
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
      );
    }
  }

  /// Notify that tool parts have been updated.
  /// Uses a version counter to trigger rebuild without copying tool data.
  void notifyToolPartsUpdated(String messageId) {
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
      );
    }
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
      );
    }
  }

  /// Remove notifier when streaming is complete.
  void removeNotifier(String messageId) {
    final notifier = _notifiers.remove(messageId);
    notifier?.dispose();
  }

  /// Clear all notifiers (e.g., when switching conversations).
  void clear() {
    for (final notifier in _notifiers.values) {
      notifier.dispose();
    }
    _notifiers.clear();
  }

  /// Dispose all resources.
  void dispose() {
    clear();
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
          retryStatus == other.retryStatus;

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
      retryStatus.hashCode;
}
