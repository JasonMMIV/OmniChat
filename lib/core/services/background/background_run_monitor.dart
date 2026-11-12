/// P2-2 background long-run monitor
/// (docs/Cowork剩餘項目實作計畫.md §2.5).
///
/// Tracks which conversations are currently generating so the desktop tray and
/// the Android completion notification can show a truthful status even when
/// the chat page is not visible. Deliberately Flutter-free: the UI/platform
/// presentation lives in `background_run_presentation.dart`, the state machine
/// here is unit-testable.
///
/// Lifecycle:
/// ```
/// idle ──begin──▶ running ──finish──▶ ready | failed | stopped
///                    ▲                        │
///                    └────────begin───────────┘
/// ```
/// Concurrent generations are allowed (AI Team / background conversations):
/// the phase only leaves `running` once every active run finished. Failures and
/// stops are recorded while the run is still active (`markFailed` /
/// `markStopped`) and surface as the final phase, because the caller learns
/// about them before it clears the loading flag.
library;

import 'dart:async';

/// Phase of the most recent generation.
enum BackgroundRunPhase { idle, running, ready, failed, stopped }

/// Immutable view of the monitor state. Equality is value-based so the
/// presentation layer can skip redundant tray rebuilds.
class BackgroundRunSnapshot {
  const BackgroundRunSnapshot({
    this.phase = BackgroundRunPhase.idle,
    this.activeConversationIds = const <String>{},
    this.activeTitle,
    this.activeTitledConversationId,
    this.lastConversationId,
    this.lastTitle,
  });

  final BackgroundRunPhase phase;

  /// Conversations currently generating (insertion order = start order).
  final Set<String> activeConversationIds;

  /// Title of the first active conversation with a known title, if any.
  final String? activeTitle;

  /// Conversation that [activeTitle] belongs to. Kept alongside the title so
  /// a status label and its click target can never point at different chats.
  final String? activeTitledConversationId;

  /// Conversation of the most recently finished run (ready / failed / stopped).
  final String? lastConversationId;
  final String? lastTitle;

  bool get isRunning => activeConversationIds.isNotEmpty;

  int get activeCount => activeConversationIds.length;

  bool get hasFinishedRun => lastConversationId != null;

  /// Title to render for the status, trimmed; null when unknown/empty.
  String? get displayTitle {
    final t = (lastTitle ?? '').trim();
    return t.isEmpty ? null : t;
  }

  /// Conversation a status click should open. While running this prefers the
  /// conversation the displayed title came from; when every active run has no
  /// title yet it falls back to start order.
  String? get openConversationId {
    if (isRunning) {
      final titled = activeTitledConversationId;
      if (titled != null && activeConversationIds.contains(titled)) {
        return titled;
      }
      return activeConversationIds.isEmpty ? null : activeConversationIds.first;
    }
    return lastConversationId;
  }

  String? get openConversationTitle => isRunning ? activeTitle : displayTitle;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BackgroundRunSnapshot &&
          other.phase == phase &&
          other.lastConversationId == lastConversationId &&
          other.lastTitle == lastTitle &&
          other.activeTitle == activeTitle &&
          other.activeTitledConversationId == activeTitledConversationId &&
          other.activeConversationIds.length == activeConversationIds.length &&
          other.activeConversationIds.containsAll(activeConversationIds);

  @override
  int get hashCode => Object.hash(
    phase,
    activeConversationIds.length,
    activeTitle,
    activeTitledConversationId,
    lastConversationId,
    lastTitle,
  );

  @override
  String toString() =>
      'BackgroundRunSnapshot(phase: $phase, active: '
      '${activeConversationIds.length}, last: $lastConversationId)';
}

/// Process-wide generation tracker. A singleton because generations outlive a
/// single chat page (they keep running while the user navigates away) and the
/// tray/notification presenters are app-scoped.
class BackgroundRunMonitor {
  BackgroundRunMonitor._();

  static final BackgroundRunMonitor instance = BackgroundRunMonitor._();

  final Map<String, String> _active = <String, String>{};
  final Set<String> _failed = <String>{};
  final Set<String> _stopped = <String>{};
  String? _lastConversationId;
  String? _lastTitle;
  BackgroundRunPhase _phase = BackgroundRunPhase.idle;

  final StreamController<BackgroundRunSnapshot> _changes =
      StreamController<BackgroundRunSnapshot>.broadcast();
  final StreamController<String> _openRequests =
      StreamController<String>.broadcast();

  BackgroundRunSnapshot? _lastEmitted;

  /// Current state.
  BackgroundRunSnapshot get snapshot {
    final titledId = _firstKnownTitleId();
    return BackgroundRunSnapshot(
      phase: _phase,
      activeConversationIds: Set<String>.unmodifiable(_active.keys),
      activeTitle: titledId == null ? null : _active[titledId]?.trim(),
      activeTitledConversationId: titledId,
      lastConversationId: _lastConversationId,
      lastTitle: _lastTitle,
    );
  }

  /// Emits whenever [snapshot] changes (value-based; duplicates suppressed).
  Stream<BackgroundRunSnapshot> get changes => _changes.stream;

  /// Conversation-open requests from a tray click or a notification tap.
  /// The chat page listens and switches to the requested conversation. This is
  /// a broadcast stream without replay: a request raised while the page is
  /// disposed is dropped (the next foreground interaction re-establishes it).
  Stream<String> get openRequests => _openRequests.stream;

  String? _firstKnownTitleId() {
    for (final entry in _active.entries) {
      if (entry.value.trim().isNotEmpty) return entry.key;
    }
    return null;
  }

  /// A generation started for [conversationId]. Idempotent while it runs, but
  /// a title that arrives on a repeated call still refreshes the snapshot.
  void begin({required String conversationId, String? title}) {
    final id = conversationId.trim();
    if (id.isEmpty) return;
    final nextTitle = (title ?? '').trim();
    final wasActive = _active.containsKey(id);
    final previousTitle = _active[id];
    _active[id] = nextTitle;
    _failed.remove(id);
    _stopped.remove(id);
    if (wasActive && _phase == BackgroundRunPhase.running) {
      if (previousTitle != nextTitle) _emit();
      return;
    }
    _phase = BackgroundRunPhase.running;
    _emit();
  }

  /// The generation's stream failed. Recorded until [finish] so the terminal
  /// phase becomes `failed`; ignored for unknown runs and for runs the user
  /// already stopped (a late cancel-related error must not turn "stopped" into
  /// "failed" and fire a failure notification).
  void markFailed(String conversationId) {
    final id = conversationId.trim();
    if (!_active.containsKey(id) || _stopped.contains(id)) return;
    _failed.add(id);
  }

  /// The user stopped the generation. Same contract as [markFailed], reporting
  /// `stopped` instead of `ready`. The first terminal signal wins: a stop after
  /// a recorded failure keeps `failed`.
  void markStopped(String conversationId) {
    final id = conversationId.trim();
    if (!_active.containsKey(id) || _failed.contains(id)) return;
    _stopped.add(id);
  }

  /// The generation reached a terminal state (success by default). Unknown
  /// runs are ignored so a stray `loading = false` cannot fabricate a result.
  void finish(String conversationId) {
    final id = conversationId.trim();
    if (!_active.containsKey(id)) return;
    final title = _active.remove(id);
    final failed = _failed.remove(id);
    final stopped = _stopped.remove(id);
    _lastConversationId = id;
    _lastTitle = title;
    if (_active.isNotEmpty) {
      _phase = BackgroundRunPhase.running;
    } else if (failed) {
      _phase = BackgroundRunPhase.failed;
    } else if (stopped) {
      _phase = BackgroundRunPhase.stopped;
    } else {
      _phase = BackgroundRunPhase.ready;
    }
    _emit();
  }

  /// A tray item / notification was activated for [conversationId].
  void requestOpen(String conversationId) {
    final id = conversationId.trim();
    if (id.isEmpty) return;
    _openRequests.add(id);
  }

  /// Drops a terminal status once the user acknowledged it (clicked the tray
  /// status row). Active runs are left untouched, so acknowledging during a
  /// generation cannot hide a still-running run.
  void acknowledgeTerminal() {
    if (_active.isNotEmpty || _phase == BackgroundRunPhase.idle) return;
    _lastConversationId = null;
    _lastTitle = null;
    _phase = BackgroundRunPhase.idle;
    _emit();
  }

  /// Clears all state (tests only; production paths overwrite the status when
  /// the next run begins or the process restarts).
  void reset() {
    _active.clear();
    _failed.clear();
    _stopped.clear();
    _lastConversationId = null;
    _lastTitle = null;
    _phase = BackgroundRunPhase.idle;
    _emit(force: true);
  }

  void _emit({bool force = false}) {
    final next = snapshot;
    if (!force && next == _lastEmitted) return;
    _lastEmitted = next;
    if (!_changes.isClosed) _changes.add(next);
  }
}
