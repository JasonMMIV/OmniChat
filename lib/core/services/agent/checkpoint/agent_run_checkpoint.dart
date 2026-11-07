import 'dart:convert';

/// P2-1: durable-before-dispatch checkpoint for an in-flight agent run.
///
/// This is deliberately a small, JSON-serializable snapshot rather than a
/// second copy of the conversation. The conversation + persisted tool events
/// remain the authoritative replay source; the checkpoint only tells the app
/// that a run crossed a durable boundary and what it was waiting on.
const String agentRunCheckpointSchemaVersionKey = 'schemaVersion';

/// The run is still dispatching rounds. Kept after a hard process kill so the
/// next launch can offer a resume.
const String agentRunPhaseRunning = 'running';

/// The run paused on an approval / ask_user card. The card is the user-facing
/// surface; the checkpoint is kept until the card is resolved.
const String agentRunPhasePaused = 'paused';

/// The request failed after at least one round was persisted. The user may
/// resume from the last completed boundary.
const String agentRunPhaseInterrupted = 'interrupted';

/// The kernel stopped at a soft gate (`max_steps` / `token_budget`).
const String agentRunPhaseSoftStopped = 'soft_stopped';

const Set<String> _knownPhases = <String>{
  agentRunPhaseRunning,
  agentRunPhasePaused,
  agentRunPhaseInterrupted,
  agentRunPhaseSoftStopped,
};

/// Minimal write/delete surface for the durable run journal.
///
/// The Hive-backed [AgentRunCheckpointStore] implements this in production;
/// tests can use an in-memory fake without touching Hive.
abstract interface class AgentRunCheckpointSink {
  Future<void> save(AgentRunCheckpoint checkpoint);
  Future<void> delete(String conversationId);
}

/// A tool call that is still waiting for the user.
class AgentRunPendingTool {
  const AgentRunPendingTool({
    required this.id,
    required this.name,
    required this.kind,
  });

  /// `approval` or `ask_user`.
  final String kind;
  final String id;
  final String name;

  bool get isApproval => kind == 'approval';
  bool get isAskUser => kind == 'ask_user';

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'kind': kind,
  };

  static AgentRunPendingTool? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = (raw['id'] ?? '').toString().trim();
    if (id.isEmpty) return null;
    final kind = (raw['kind'] ?? '').toString() == 'ask_user'
        ? 'ask_user'
        : 'approval';
    return AgentRunPendingTool(
      id: id,
      name: (raw['name'] ?? '').toString(),
      kind: kind,
    );
  }
}

/// Snapshot of one agent run at a durable boundary.
class AgentRunCheckpoint {
  AgentRunCheckpoint({
    required this.conversationId,
    required this.assistantMessageId,
    required this.stepIndex,
    required this.tokensSoFar,
    required this.phase,
    required this.updatedAtMs,
    this.pendingTools = const <AgentRunPendingTool>[],
    this.softStopReason,
    this.runId,
  });

  final String conversationId;
  final String assistantMessageId;

  /// Last durable round index. Reserved for P2-2/P3-3 task surfaces; resume
  /// currently replays the persisted conversation rather than a kernel step.
  final int stepIndex;

  /// Cumulative kernel token usage at the boundary. Budget metadata only;
  /// never use it as a prompt-size estimate (P1-2 mid-run compaction).
  final int tokensSoFar;

  final String phase;
  final int updatedAtMs;
  final List<AgentRunPendingTool> pendingTools;

  /// Soft-gate reason (`max_steps` / `token_budget`); reserved for the task
  /// list and richer banner copy.
  final String? softStopReason;

  /// In-process run identity used by the run fence. Optional so checkpoints
  /// written before this field was added still decode.
  final String? runId;

  bool get hasPendingUserAction => pendingTools.isNotEmpty;

  DateTime get updatedAt =>
      DateTime.fromMillisecondsSinceEpoch(updatedAtMs, isUtc: false);

  AgentRunCheckpoint copyWith({
    String? conversationId,
    String? assistantMessageId,
    int? stepIndex,
    int? tokensSoFar,
    String? phase,
    int? updatedAtMs,
    List<AgentRunPendingTool>? pendingTools,
    String? softStopReason,
    bool clearSoftStopReason = false,
    String? runId,
  }) {
    return AgentRunCheckpoint(
      conversationId: conversationId ?? this.conversationId,
      assistantMessageId: assistantMessageId ?? this.assistantMessageId,
      stepIndex: stepIndex ?? this.stepIndex,
      tokensSoFar: tokensSoFar ?? this.tokensSoFar,
      phase: phase ?? this.phase,
      updatedAtMs: updatedAtMs ?? this.updatedAtMs,
      pendingTools: pendingTools ?? this.pendingTools,
      softStopReason: clearSoftStopReason
          ? null
          : (softStopReason ?? this.softStopReason),
      runId: runId ?? this.runId,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    agentRunCheckpointSchemaVersionKey: 1,
    'conversationId': conversationId,
    'assistantMessageId': assistantMessageId,
    'stepIndex': stepIndex,
    'tokensSoFar': tokensSoFar,
    'phase': phase,
    'updatedAtMs': updatedAtMs,
    'pendingTools': <Map<String, dynamic>>[
      for (final tool in pendingTools) tool.toJson(),
    ],
    if (softStopReason != null) 'softStopReason': softStopReason,
    if (runId != null) 'runId': runId,
  };

  String encode() => jsonEncode(toJson());

  /// Strict enough to reject corrupt/partial rows, permissive enough to keep
  /// old checkpoints after a schema field is added.
  static AgentRunCheckpoint? tryDecode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final conversationId = (decoded['conversationId'] ?? '')
          .toString()
          .trim();
      final assistantMessageId = (decoded['assistantMessageId'] ?? '')
          .toString()
          .trim();
      if (conversationId.isEmpty || assistantMessageId.isEmpty) return null;
      final stepIndex = _nonNegativeInt(decoded['stepIndex']);
      final tokensSoFar = _nonNegativeInt(decoded['tokensSoFar']);
      final updatedAtMs = _nonNegativeInt(decoded['updatedAtMs']);
      if (stepIndex == null || tokensSoFar == null || updatedAtMs == null) {
        return null;
      }
      if (updatedAtMs <= 0) return null;
      final phaseRaw = (decoded['phase'] ?? '').toString();
      final phase = _knownPhases.contains(phaseRaw)
          ? phaseRaw
          : agentRunPhaseInterrupted;
      final pendingRaw = decoded['pendingTools'];
      final pending = <AgentRunPendingTool>[
        if (pendingRaw is List)
          for (final item in pendingRaw)
            if (AgentRunPendingTool.tryParse(item) case final tool?) tool,
      ];
      final softStopReason = (decoded['softStopReason'] ?? '').toString();
      final runIdRaw = (decoded['runId'] ?? '').toString().trim();
      return AgentRunCheckpoint(
        conversationId: conversationId,
        assistantMessageId: assistantMessageId,
        stepIndex: stepIndex,
        tokensSoFar: tokensSoFar,
        phase: phase,
        updatedAtMs: updatedAtMs,
        pendingTools: List.unmodifiable(pending),
        softStopReason: softStopReason.isEmpty ? null : softStopReason,
        runId: runIdRaw.isEmpty ? null : runIdRaw,
      );
    } catch (_) {
      return null;
    }
  }

  static int? _nonNegativeInt(Object? raw) {
    final value = raw is int ? raw : int.tryParse(raw?.toString() ?? '');
    if (value == null || value < 0) return null;
    return value;
  }
}
