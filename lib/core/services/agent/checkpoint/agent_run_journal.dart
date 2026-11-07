import '../../logging/flutter_logger.dart';
import 'agent_run_checkpoint.dart';

/// Result of resolving the authoritative pending tool events for a run.
///
/// "Unknown" is deliberately distinct from "known empty": a storage read
/// failure must never look like "there is no approval card", otherwise the
/// terminal classifier could delete a paused run or resume without the user's
/// decision.
class AgentRunPendingSnapshot {
  AgentRunPendingSnapshot.known(List<AgentRunPendingTool> tools)
    : tools = List<AgentRunPendingTool>.unmodifiable(tools),
      isKnown = true;

  const AgentRunPendingSnapshot.unknown()
    : tools = const <AgentRunPendingTool>[],
      isKnown = false;

  final List<AgentRunPendingTool> tools;
  final bool isKnown;

  bool get hasPending => tools.isNotEmpty;
}

int _runSequence = 0;

String _newRunId() =>
    '${DateTime.now().microsecondsSinceEpoch}-${_runSequence++}';

/// In-process fence for one run per conversation.
///
/// The checkpoint box is keyed by conversation id, so a late write from an old
/// stream (or its terminal handler) could overwrite a newer run's boundary.
/// Journals claim a run id at construction; every write/clear first checks that
/// the id is still current. The fence is process-local by design: after a
/// restart there is only one candidate checkpoint per conversation.
class AgentRunFence {
  static final AgentRunFence instance = AgentRunFence();

  final Map<String, String> _active = <String, String>{};

  String begin(String conversationId, [String? runId]) {
    final id = runId ?? _newRunId();
    _active[conversationId] = id;
    return id;
  }

  bool isCurrent(String conversationId, String runId) =>
      _active[conversationId] == runId;

  void end(String conversationId, String runId) {
    if (isCurrent(conversationId, runId)) _active.remove(conversationId);
  }

  bool cancel(String conversationId) => _active.remove(conversationId) != null;
}

/// Durable-before-dispatch journal for one agent run.
///
/// The conversation + persisted tool events remain the authoritative replay
/// source; this journal only records that a run crossed a durable boundary and
/// what it was waiting on. Responsibilities:
///
/// - write the checkpoint before a round is dispatched (`onRoundStart`);
/// - mirror approval / ask_user pauses immediately (`onToolResults`);
/// - classify the terminal state (`onError` / `onDone`);
/// - fence stale writes from an older run in the same conversation;
/// - degrade to a session-disabled journal on the first write failure instead
///   of failing the whole generation (the journal is crash insurance, not a
///   prerequisite for talking to the model).
class AgentRunJournal {
  AgentRunJournal({
    required AgentRunCheckpointSink store,
    required this.conversationId,
    required this.assistantMessageId,
    required Future<AgentRunPendingSnapshot> Function() resolvePending,
    AgentRunFence? fence,
    DateTime Function()? clock,
    String? runId,
  }) : _store = store,
       _resolvePending = resolvePending,
       _fence = fence ?? AgentRunFence.instance,
       _clock = clock ?? DateTime.now,
       runId = runId ?? _newRunId() {
    _fence.begin(conversationId, this.runId);
  }

  final AgentRunCheckpointSink _store;
  final Future<AgentRunPendingSnapshot> Function() _resolvePending;
  final AgentRunFence _fence;
  final DateTime Function() _clock;

  final String conversationId;
  final String assistantMessageId;
  final String runId;

  int stepIndex = 0;
  int tokensSoFar = 0;
  List<AgentRunPendingTool> pendingTools = const <AgentRunPendingTool>[];

  bool _written = false;
  bool _disabled = false;
  bool _ended = false;
  bool _staleLogged = false;
  bool _unknownLogged = false;

  /// Whether at least one checkpoint write reached the sink.
  bool get hasWritten => _written;

  /// Whether this session's journal was disabled after a write failure.
  bool get disabled => _disabled;

  /// Whether a terminal classifier already ran (idempotency guard).
  bool get isEnded => _ended;

  /// Pre-dispatch boundary. Returns false when an unresolved approval /
  /// ask_user card must pause the run before any further model call.
  ///
  /// The save is awaited: the caller (the kernel) must not dispatch the round
  /// before the checkpoint is durable. A save failure disables the journal but
  /// does not fail the run.
  Future<bool> onRoundStart(int step, int tokensSoFar) async {
    if (_ended) return false;
    this.stepIndex = step;
    this.tokensSoFar = tokensSoFar;

    if (step > 0) {
      final resolved = await _safeResolve();
      if (resolved.isKnown) pendingTools = resolved.tools;
      // Unknown keeps the last known pending list: pausing on a known card is
      // safer than sending an unapproved tool call.
      final pending = resolved.isKnown ? resolved.tools : pendingTools;
      if (pending.isNotEmpty) {
        await _save(phase: agentRunPhasePaused, pendingOverride: pending);
        return false;
      }
    }

    await _save(phase: agentRunPhaseRunning);
    return true;
  }

  /// Round boundary after every tool call of the round executed and the
  /// follow-up messages were appended.
  Future<void> onRoundEnd(int step) async {
    if (_ended) return;
    stepIndex = step + 1;

    final resolved = await _safeResolve();
    if (!resolved.isKnown) {
      // Keep the previous checkpoint rather than overwriting a pause with an
      // empty guess.
      _logUnknown();
      return;
    }
    pendingTools = resolved.tools;
    await _save(
      phase: resolved.hasPending ? agentRunPhasePaused : agentRunPhaseRunning,
      pendingOverride: resolved.tools,
    );
  }

  /// Tool-result boundary. Writes immediately only when a pending card appears
  /// (or a previously pending card was resolved); ordinary results are batched
  /// into [onRoundEnd] so a tool-heavy round does not flush once per call.
  Future<void> onToolResults() async {
    if (_ended) return;
    final resolved = await _safeResolve();
    if (!resolved.isKnown) {
      _logUnknown();
      return;
    }

    final previous = pendingTools;
    pendingTools = resolved.tools;
    if (resolved.hasPending) {
      // Several tool results can arrive after an approval in the same round;
      // only the first one needs to persist the pause.
      if (!_samePending(previous, resolved.tools)) {
        await _save(
          phase: agentRunPhasePaused,
          pendingOverride: resolved.tools,
        );
      }
    } else if (previous.isNotEmpty) {
      await _save(phase: agentRunPhaseRunning);
    }
  }

  bool _samePending(List<AgentRunPendingTool> a, List<AgentRunPendingTool> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id ||
          a[i].kind != b[i].kind ||
          a[i].name != b[i].name) {
        return false;
      }
    }
    return true;
  }

  /// Stream error terminal. Keeps the last known pending list; an unknown read
  /// does not erase a checkpoint that was already written.
  Future<void> onError() async {
    if (_ended) return;
    if (!_written && !_disabled) {
      // The run failed before its first durable boundary; there is no row of
      // this run's own to classify (and an older row must not be overwritten).
      _release();
      return;
    }
    final resolved = await _safeResolve();
    if (resolved.isKnown) {
      pendingTools = resolved.tools;
    } else {
      _logUnknown();
    }

    if (_written || resolved.isKnown) {
      await _save(
        phase: agentRunPhaseInterrupted,
        pendingOverride: pendingTools,
      );
    }
    _release();
  }

  /// Stream done terminal.
  ///
  /// - soft gate: keep a resumable checkpoint;
  /// - pending card: keep the pause checkpoint until the user resolves it;
  /// - ordinary completion: remove the journal entry;
  /// - unknown pending state: keep the existing row instead of deleting it.
  Future<void> onDone({String? softStopReason}) async {
    if (_ended) return;
    if (!_written && !_disabled) {
      _release();
      return;
    }
    final resolved = await _safeResolve();
    if (resolved.isKnown) pendingTools = resolved.tools;

    if ((softStopReason ?? '').isNotEmpty) {
      await _save(
        phase: agentRunPhaseSoftStopped,
        pendingOverride: pendingTools,
        softStopReason: softStopReason,
      );
    } else if (resolved.isKnown && pendingTools.isNotEmpty) {
      await _save(phase: agentRunPhasePaused, pendingOverride: pendingTools);
    } else if (resolved.isKnown) {
      await clear();
      return;
    } else if (pendingTools.isNotEmpty) {
      await _save(phase: agentRunPhasePaused, pendingOverride: pendingTools);
    } else {
      _logUnknown();
    }
    _release();
  }

  /// Remove the journal row, but only if this run still owns the conversation.
  Future<void> clear() async {
    if (_ended) return;
    final owns = _fence.isCurrent(conversationId, runId);
    _release();
    if (!owns) return;
    try {
      await _store.delete(conversationId);
    } catch (e) {
      FlutterLogger.log(
        'Agent-run checkpoint cleanup failed: $e',
        tag: 'agent-checkpoint',
      );
    }
  }

  void _release() {
    _ended = true;
    _fence.end(conversationId, runId);
  }

  Future<bool> _save({
    required String phase,
    List<AgentRunPendingTool>? pendingOverride,
    String? softStopReason,
  }) async {
    if (_ended || _disabled) return false;
    if (!_fence.isCurrent(conversationId, runId)) {
      if (!_staleLogged) {
        _staleLogged = true;
        FlutterLogger.log(
          'Discarded a stale agent-run checkpoint write for $conversationId.',
          tag: 'agent-checkpoint',
        );
      }
      return false;
    }

    try {
      await _store.save(
        AgentRunCheckpoint(
          conversationId: conversationId,
          assistantMessageId: assistantMessageId,
          stepIndex: stepIndex,
          tokensSoFar: tokensSoFar,
          phase: phase,
          updatedAtMs: _clock().millisecondsSinceEpoch,
          pendingTools: pendingOverride ?? pendingTools,
          softStopReason: softStopReason,
          runId: runId,
        ),
      );
      _written = true;
      return true;
    } catch (e) {
      _disabled = true;
      FlutterLogger.log(
        'Agent-run journal disabled for this session after a write failure: $e',
        tag: 'agent-checkpoint',
      );
      return false;
    }
  }

  Future<AgentRunPendingSnapshot> _safeResolve() async {
    try {
      return await _resolvePending();
    } catch (e) {
      _logUnknown(e);
      return const AgentRunPendingSnapshot.unknown();
    }
  }

  void _logUnknown([Object? error]) {
    if (_unknownLogged) return;
    _unknownLogged = true;
    FlutterLogger.log(
      'Agent-run pending tool state is unknown'
      '${error == null ? '' : ': $error'}',
      tag: 'agent-checkpoint',
    );
  }
}
