/// In-memory per-conversation turn queue (v1: no persistence, like Anybuff).
///
/// [QueuedMessage] snapshots [ChatInputData] at enqueue time; dispatch re-runs
/// the normal send pipeline, which rebakes the prompt. The store holds every
/// piece of mutable queue state (FIFO, pause, single-flight, cooldown, failure
/// streak) as pure Dart so the controller only wires side effects.
///
/// A restart clears the queue (v1 ruling, R9).
library;

import '../../../models/chat_input_data.dart';

/// One queued composer submission.
class QueuedMessage {
  const QueuedMessage({
    required this.id,
    required this.conversationId,
    required this.input,
    required this.createdAt,
  });

  final String id;
  final String conversationId;

  /// Snapshot of the composer at enqueue time (text + attachments).
  final ChatInputData input;

  final DateTime createdAt;

  QueuedMessage copyWith({ChatInputData? input}) => QueuedMessage(
    id: id,
    conversationId: conversationId,
    input: input ?? this.input,
    createdAt: createdAt,
  );
}

/// Pure in-memory queue store keyed by conversation id.
class TurnQueueStore {
  TurnQueueStore({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  /// Dispatch failures tolerated for the same item before the queue pauses.
  static const int pauseAfterConsecutiveFailures = 2;

  /// Delay before retrying a failed dispatch (R10).
  static const Duration failureCooldown = Duration(milliseconds: 1500);

  final DateTime Function() _clock;

  final Map<String, List<QueuedMessage>> _queues =
      <String, List<QueuedMessage>>{};
  final Set<String> _paused = <String>{};
  final Set<String> _inFlight = <String>{};
  final Map<String, DateTime> _cooldownUntil = <String, DateTime>{};
  final Map<String, int> _failureStreak = <String, int>{};
  final Map<String, String> _lastFailedId = <String, String>{};

  int _idCounter = 0;

  /// New unique id for a queued item (timestamp + counter, no uuid dependency).
  String nextId() => 'queue_${_clock().microsecondsSinceEpoch}_${++_idCounter}';

  // ---------------------------------------------------------------------------
  // FIFO operations
  // ---------------------------------------------------------------------------

  List<QueuedMessage> queueFor(String conversationId) =>
      List<QueuedMessage>.unmodifiable(
        _queues[conversationId] ?? const <QueuedMessage>[],
      );

  /// Conversation ids that currently hold queued items (prune/cleanup).
  Iterable<String> get trackedConversationIds => _queues.keys;

  bool hasItems(String conversationId) =>
      (_queues[conversationId] ?? const <QueuedMessage>[]).isNotEmpty;

  int countFor(String conversationId) =>
      _queues[conversationId]?.length ?? 0;

  void enqueue(QueuedMessage message) {
    _queues.putIfAbsent(message.conversationId, () => <QueuedMessage>[]).add(
      message,
    );
  }

  /// Removes and returns the item with [id], or null when it is gone.
  QueuedMessage? remove(String conversationId, String id) {
    final queue = _queues[conversationId];
    if (queue == null) return null;
    final index = queue.indexWhere((m) => m.id == id);
    if (index < 0) return null;
    final removed = queue.removeAt(index);
    if (queue.isEmpty) _queues.remove(conversationId);
    return removed;
  }

  /// Replaces an item's input snapshot (dock text edit; attachments stay
  /// untouched per the v1 ruling).
  bool updateInput(String conversationId, String id, ChatInputData input) {
    final queue = _queues[conversationId];
    if (queue == null) return false;
    final index = queue.indexWhere((m) => m.id == id);
    if (index < 0) return false;
    queue[index] = queue[index].copyWith(input: input);
    return true;
  }

  /// Moves the item to the front ("移到最前").
  bool promote(String conversationId, String id) => moveItem(conversationId, id, 0);

  /// Moves the item to [newIndex] (clamped). Reserved for future dock
  /// ordering; the v1 dock exposes promote instead.
  bool moveItem(String conversationId, String id, int newIndex) {
    final queue = _queues[conversationId];
    if (queue == null) return false;
    final index = queue.indexWhere((m) => m.id == id);
    if (index < 0) return false;
    if (newIndex < 0) newIndex = 0;
    if (newIndex >= queue.length) newIndex = queue.length - 1;
    if (index == newIndex) return true;
    final item = queue.removeAt(index);
    queue.insert(newIndex, item);
    return true;
  }

  /// Puts [message] back at the head (dispatch failure fallback).
  void requeueHead(String conversationId, QueuedMessage message) {
    _queues.removeWhere((cid, queue) {
      if (cid != conversationId) return false;
      queue.removeWhere((m) => m.id == message.id);
      return queue.isEmpty;
    });
    _queues
        .putIfAbsent(conversationId, () => <QueuedMessage>[])
        .insert(0, message);
  }

  /// Block-prepends [messages] ahead of the current head while preserving the
  /// FIFO order of both lists (steering leftovers, §3.1).
  void prependAll(String conversationId, List<QueuedMessage> messages) {
    if (messages.isEmpty) return;
    final queue = _queues.putIfAbsent(
      conversationId,
      () => <QueuedMessage>[],
    );
    queue.insertAll(0, messages);
  }

  // ---------------------------------------------------------------------------
  // Pause / resume
  // ---------------------------------------------------------------------------

  bool isPaused(String conversationId) => _paused.contains(conversationId);

  void pause(String conversationId) => _paused.add(conversationId);

  void resume(String conversationId) {
    _paused.remove(conversationId);
    _cooldownUntil.remove(conversationId);
    _failureStreak.remove(conversationId);
    _lastFailedId.remove(conversationId);
  }

  // ---------------------------------------------------------------------------
  // Single-flight dispatch
  // ---------------------------------------------------------------------------

  bool isInFlight(String conversationId) => _inFlight.contains(conversationId);

  /// Claims the dispatch slot; false when another dispatch is already running.
  bool tryBeginDispatch(String conversationId) =>
      _inFlight.add(conversationId);

  void endDispatch(String conversationId) => _inFlight.remove(conversationId);

  // ---------------------------------------------------------------------------
  // Failure cooldown (R10)
  // ---------------------------------------------------------------------------

  bool isCoolingDown(String conversationId, [DateTime? now]) {
    final until = _cooldownUntil[conversationId];
    if (until == null) return false;
    return (now ?? _clock()).isBefore(until);
  }

  DateTime? cooldownUntil(String conversationId) =>
      _cooldownUntil[conversationId];

  void markCooldown(
    String conversationId, [
    Duration duration = failureCooldown,
  ]) {
    _cooldownUntil[conversationId] = _clock().add(duration);
  }

  void clearCooldown(String conversationId) {
    _cooldownUntil.remove(conversationId);
  }

  /// Records a dispatch failure for [messageId]; returns true when the queue
  /// must pause (the same item failed [pauseAfterConsecutiveFailures] times in
  /// a row).
  bool registerFailure(String conversationId, String messageId) {
    if (_lastFailedId[conversationId] == messageId) {
      _failureStreak[conversationId] =
          (_failureStreak[conversationId] ?? 1) + 1;
    } else {
      _lastFailedId[conversationId] = messageId;
      _failureStreak[conversationId] = 1;
    }
    return (_failureStreak[conversationId] ?? 0) >=
        pauseAfterConsecutiveFailures;
  }

  /// Clears the streak after a successful dispatch.
  void resetFailure(String conversationId) {
    _failureStreak.remove(conversationId);
    _lastFailedId.remove(conversationId);
  }

  // ---------------------------------------------------------------------------
  // Cleanup
  // ---------------------------------------------------------------------------

  /// Drops every piece of state for [conversationId] (conversation deleted /
  /// clear-all).
  void clearConversation(String conversationId) {
    _queues.remove(conversationId);
    _paused.remove(conversationId);
    _cooldownUntil.remove(conversationId);
    _failureStreak.remove(conversationId);
    _lastFailedId.remove(conversationId);
  }
}
