import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../../logging/flutter_logger.dart';
import 'agent_run_checkpoint.dart';

/// Device-local durable store for P2-1 agent run checkpoints.
///
/// This box is intentionally **not** part of conversation sync/backup: it is
/// a crash-recovery journal for this installation only. Conversation rows and
/// tool events remain the source of truth; a corrupt checkpoint is deleted so
/// it can never wedge startup.
///
/// The write path and fence run on every agent loop boundary; the read
/// surface (latest/listAll) currently has no UI consumer — the planned
/// background-task inbox (P2-2) is its future reader, so do not remove it
/// as dead code.
class AgentRunCheckpointStore implements AgentRunCheckpointSink {
  AgentRunCheckpointStore({String boxName = defaultBoxName})
    : _boxName = boxName;

  static final AgentRunCheckpointStore instance = AgentRunCheckpointStore();

  static const String defaultBoxName = 'agent_runs_v1';

  final String _boxName;
  Box<dynamic>? _box;
  Future<Box<dynamic>>? _opening;

  String get boxName => _boxName;

  Future<Box<dynamic>> _ensureBox() async {
    final existing = _box;
    if (existing != null && existing.isOpen) return existing;

    final opening = _opening;
    if (opening != null) return opening;

    final future = Hive.openBox<dynamic>(_boxName);
    _opening = future;
    try {
      final box = await future;
      _box = box;
      return box;
    } finally {
      _opening = null;
    }
  }

  /// Persist a checkpoint and wait for Hive's disk flush. The flush is the
  /// durable-before-dispatch guarantee: the model request must not start
  /// before this future completes.
  Future<void> save(AgentRunCheckpoint checkpoint) async {
    final box = await _ensureBox();
    await box.put(checkpoint.conversationId, checkpoint.encode());
    await box.flush();
  }

  Future<AgentRunCheckpoint?> load(String conversationId) async {
    final box = await _ensureBox();
    final raw = box.get(conversationId);
    if (raw is! String) {
      if (raw != null) {
        await box.delete(conversationId);
        await box.flush();
      }
      return null;
    }
    final checkpoint = AgentRunCheckpoint.tryDecode(raw);
    if (checkpoint == null) {
      await box.delete(conversationId);
      await box.flush();
      FlutterLogger.log(
        'Discarded corrupt agent-run checkpoint for $conversationId.',
        tag: 'agent-checkpoint',
      );
    }
    return checkpoint;
  }

  /// All actionable checkpoints, newest first. Corrupt rows are swept as they
  /// are encountered, exactly like [latest].
  Future<List<AgentRunCheckpoint>> listAll() async {
    final box = await _ensureBox();
    final checkpoints = <AgentRunCheckpoint>[];
    var deleted = false;
    for (final key in box.keys.toList()) {
      if (key is! String) {
        await box.delete(key);
        deleted = true;
        continue;
      }
      final raw = box.get(key);
      final checkpoint = raw is String
          ? AgentRunCheckpoint.tryDecode(raw)
          : null;
      if (checkpoint == null) {
        await box.delete(key);
        deleted = true;
        if (raw != null) {
          FlutterLogger.log(
            'Discarded corrupt agent-run checkpoint for $key.',
            tag: 'agent-checkpoint',
          );
        }
        continue;
      }
      checkpoints.add(checkpoint);
    }
    if (deleted) await box.flush();
    checkpoints.sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
    return checkpoints;
  }

  /// Newest actionable checkpoint across all conversations.
  Future<AgentRunCheckpoint?> latest() async {
    final checkpoints = await listAll();
    return checkpoints.isEmpty ? null : checkpoints.first;
  }

  Future<void> delete(String conversationId) async {
    final box = await _ensureBox();
    if (!box.containsKey(conversationId)) return;
    await box.delete(conversationId);
    await box.flush();
  }

  Future<void> clearAll() async {
    final box = await _ensureBox();
    if (box.isEmpty) return;
    await box.clear();
    await box.flush();
  }

  @visibleForTesting
  Future<void> debugReset() async {
    final box = await _ensureBox();
    await box.clear();
    await box.flush();
  }

  @visibleForTesting
  Future<void> close() async {
    final box = _box;
    _box = null;
    try {
      await box?.close();
    } catch (_) {}
  }
}
