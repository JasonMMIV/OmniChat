// One-time `todo_v1` migration + read-only legacy fallback
// (docs/write_todos_improvement_plan.md §2.5.3 / §8).
//
// Until this release the plan snapshot also lived in the Hive box `todo_v1`
// (keyed by conversation id) — a second source of truth that was missing from
// backups, forks and deletes. The conversation tool events are the single
// source of truth now; this module moves the remaining box data over:
//
// 1. Conversation already has a successful `write_todos` event → the event
//    wins, the box entry is dropped.
// 2. No event, items non-empty → a completed `write_todos` part is appended
//    to the last assistant message of the active branch
//    (`metadata.origin = 'todo_v1_migration'`). The part is non-replayable
//    (`kNonReplayableToolNames`), so no dangling tool call is ever produced.
// 3. No assistant message on the branch → the box entry is KEPT and the
//    projection falls back to a read-only box read until one exists.
//
// The migration is idempotent, runs once (`todo_v1_migrated_v1`), and never
// blocks startup: failures are logged, the fallback keeps plans visible.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../logging/flutter_logger.dart';
import '../../models/chat_message.dart';
import 'chat_service.dart';
import 'todo_models.dart';

class TodoV1Migration {
  TodoV1Migration._();

  static const String boxName = 'todo_v1';
  static const String migratedPrefsKey = 'todo_v1_migrated_v1';
  static const String originMigration = 'todo_v1_migration';

  static Box<dynamic>? _legacyBox;
  static bool _boxUnavailable = false;

  /// Opens the legacy box read-only-ish (we only delete migrated keys).
  /// Returns false when the box file does not exist or cannot be opened —
  /// both are non-fatal (nothing to migrate / nothing to fall back to).
  static Future<bool> _openLegacyBox(String? appDataDirPath) async {
    if (_legacyBox != null && _legacyBox!.isOpen) return true;
    if (_boxUnavailable) return false;
    try {
      if (appDataDirPath != null && appDataDirPath.isNotEmpty) {
        final file = File(
          '$appDataDirPath${Platform.pathSeparator}$boxName.hive',
        );
        if (!file.existsSync()) {
          // Never had a todo box — mark migrated so we do not re-check.
          _boxUnavailable = true;
          return false;
        }
      }
      _legacyBox = await Hive.openBox<dynamic>(boxName);
      return true;
    } catch (e) {
      FlutterLogger.log(
        'todo_v1 box unavailable (non-fatal): $e',
        tag: 'todo-migration',
      );
      _boxUnavailable = true;
      return false;
    }
  }

  /// Runs the one-time migration against the real chat service.
  /// Idempotent; never throws.
  static Future<void> run({
    required ChatService chatService,
    required SharedPreferences prefs,
    String? appDataDirPath,
  }) {
    return runWith(
      prefs: prefs,
      appDataDirPath: appDataDirPath,
      hasCompletedEvent: chatService.hasCompletedTodoEvent,
      lastActiveAssistantMessageId: (conversationId) =>
          lastActiveAssistantMessageId(
        chatService.getMessages(conversationId),
        chatService.getConversation(conversationId)?.versionSelections ??
            const <String, int>{},
      ),
      appendEvent: chatService.upsertToolEvent,
    );
  }

  /// Migration core over narrow seams so the rules are unit-testable without
  /// a platform-channel ChatService.
  @visibleForTesting
  static Future<void> runWith({
    required SharedPreferences prefs,
    String? appDataDirPath,
    required Future<bool> Function(String conversationId) hasCompletedEvent,
    required String? Function(String conversationId)
        lastActiveAssistantMessageId,
    required Future<void> Function(
      String assistantMessageId, {
      required String id,
      required String name,
      required Map<String, dynamic> arguments,
      String? content,
      Map<String, dynamic>? extras,
    })
        appendEvent,
  }) async {
    if (prefs.getBool(migratedPrefsKey) ?? false) return;
    try {
      if (!await _openLegacyBox(appDataDirPath)) {
        await prefs.setBool(migratedPrefsKey, true);
        return;
      }
      final box = _legacyBox!;
      for (final key in box.keys.toList()) {
        final conversationId = key.toString();
        if (conversationId.isEmpty) continue;
        try {
          final raw = box.get(key);
          final rawText = raw is String ? raw : '';
          if (rawText.trim().isEmpty) {
            await box.delete(key);
            continue;
          }
          Object? decoded;
          try {
            decoded = jsonDecode(rawText);
          } catch (_) {
            decoded = null;
          }
          // Read path: salvage every valid item out of a partially corrupt
          // box entry instead of discarding the whole plan.
          final parse = parseTodoListInput(decoded, dropInvalidItems: true);
          if (!parse.isValid || parse.items.isEmpty) {
            // Nothing restorable (empty or corrupt) — drop the entry.
            await box.delete(key);
            continue;
          }

          // Rule 1: a successful event on the conversation wins.
          if (await hasCompletedEvent(conversationId)) {
            await box.delete(key);
            continue;
          }

          // Rule 2: synthesize a completed tool part on the last assistant
          // message of the active branch (collapseVersions semantics).
          final targetId = lastActiveAssistantMessageId(conversationId);
          if (targetId == null) {
            // Rule 3: keep the entry; the projection falls back to it.
            continue;
          }
          final items = parse.items;
          await appendEvent(
            targetId,
            id: todoStateHashId(items, seed: conversationId),
            name: todoToolName,
            arguments: <String, dynamic>{
              'todos': <Map<String, dynamic>>[
                for (final item in items) item.toJson(),
              ],
            },
            content: buildTodoResultContent(
              items: items,
              changed: false,
              cleared: false,
              includeItems: true,
              notice: 'Plan restored from a previous app version.',
            ),
            extras: <String, dynamic>{'origin': originMigration},
          );
          await box.delete(key);
          FlutterLogger.log(
            'todo_v1 migration: restored plan for $conversationId',
            tag: 'todo-migration',
          );
        } catch (e) {
          FlutterLogger.log(
            'todo_v1 migration: entry $conversationId failed (kept): $e',
            tag: 'todo-migration',
          );
        }
      }
      await prefs.setBool(migratedPrefsKey, true);
    } catch (e) {
      // Never block startup on migration problems.
      FlutterLogger.log(
        'todo_v1 migration failed (non-fatal): $e',
        tag: 'todo-migration',
      );
    }
  }

  /// Clears the static legacy-box cache between tests.
  @visibleForTesting
  static Future<void> debugReset() async {
    try {
      if (_legacyBox != null && _legacyBox!.isOpen) {
        await _legacyBox!.close();
      }
    } catch (_) {}
    _legacyBox = null;
    _boxUnavailable = false;
  }

  /// Read-only fallback for conversations the migration could not attach
  /// (§2.5.3 rule 3): no assistant message existed on the branch. Returns
  /// null when the box is unavailable or the conversation has no legacy
  /// snapshot. The fallback disappears once the conversation gains an
  /// assistant message and the migration can synthesize the event.
  static Future<List<TodoItem>?> legacyItemsFor(String conversationId) async {
    if (_boxUnavailable) return null;
    try {
      if (!await _openLegacyBox(null)) return null;
      final raw = _legacyBox?.get(conversationId);
      final rawText = raw is String ? raw : '';
      if (rawText.trim().isEmpty) return null;
      Object? decoded;
      try {
        decoded = jsonDecode(rawText);
      } catch (_) {
        return null;
      }
      final parse = parseTodoListInput(decoded, dropInvalidItems: true);
      if (!parse.isValid || parse.items.isEmpty) return null;
      return parse.items;
    } catch (e) {
      FlutterLogger.log(
        'todo_v1 fallback read failed (non-fatal): $e',
        tag: 'todo-migration',
      );
      return null;
    }
  }

  /// Removes one conversation's legacy entry (best-effort delete cleanup —
  /// conversation data must not outlive its conversation anywhere).
  static Future<void> dropConversation(String conversationId) async {
    if (_boxUnavailable || _legacyBox == null) return;
    try {
      if (!_legacyBox!.isOpen) return;
      await _legacyBox!.delete(conversationId);
    } catch (_) {}
  }

  /// The last assistant message of the ACTIVE branch — same grouping and
  /// selection semantics as `MessageBuilderService.collapseVersions`
  /// (group by `groupId ?? id`, selected version or newest). Kept local so
  /// the core migration does not depend on the feature-layer builder.
  @visibleForTesting
  static String? lastActiveAssistantMessageId(
    List<ChatMessage> messages,
    Map<String, int> versionSelections,
  ) {
    final byGroup = <String, List<ChatMessage>>{};
    final order = <String>[];
    for (final m in messages) {
      final gid = (m.groupId ?? m.id);
      final list = byGroup.putIfAbsent(gid, () {
        order.add(gid);
        return <ChatMessage>[];
      });
      list.add(m);
    }
    String? lastAssistantId;
    for (final gid in order) {
      final versions = byGroup[gid]!
        ..sort((a, b) => a.version.compareTo(b.version));
      final sel = versionSelections[gid];
      final idx = (sel != null && sel >= 0 && sel < versions.length)
          ? sel
          : versions.length - 1;
      final message = versions[idx];
      if (message.role == 'assistant') lastAssistantId = message.id;
    }
    return lastAssistantId;
  }
}
