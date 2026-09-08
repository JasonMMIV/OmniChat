// P1-3 Todo list service — deepseek `tool-todo` data model
// (IMPORT_PLAN_COWORK.md P1-3).
//
// Hive box `todo_v1`, key = conversationId, value = JSON-encoded list of
// `{content, status}` items. Whole-snapshot writes (last-write-wins), no id,
// no priority — replay-safe by construction. Todo data is conversation data:
// it follows the normal conversation sync rules (NOT in `_localOnlyKeys`).
//
// `write_todos` is a log-only tool: its tool event still lands through the
// normal tool flow (card placement + backup for free), but the event is
// excluded from §3.11 replay and L0/L1 compaction — the current snapshot is
// injected at a stable system-prompt position instead.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

const String todoToolName = 'write_todos';

const String todoStatusPending = 'pending';
const String todoStatusInProgress = 'in_progress';
const String todoStatusCompleted = 'completed';

class TodoItem {
  final String content;
  final String status; // pending | in_progress | completed

  const TodoItem({required this.content, required this.status});

  bool get isCompleted => status == todoStatusCompleted;
  bool get isInProgress => status == todoStatusInProgress;

  Map<String, dynamic> toJson() => {'content': content, 'status': status};

  factory TodoItem.fromJson(Map<String, dynamic> json) => TodoItem(
        content: (json['content'] ?? '').toString(),
        status: _validStatus(json['status']?.toString()),
      );

  static String _validStatus(String? raw) {
    switch (raw) {
      case todoStatusInProgress:
        return todoStatusInProgress;
      case todoStatusCompleted:
        return todoStatusCompleted;
      default:
        return todoStatusPending;
    }
  }
}

/// Normalize the model's `todos` argument into items. Caps the list (deepseek
/// tool-todo keeps plans small), defaults missing statuses to pending.
List<TodoItem> normalizeTodoItems(dynamic raw, {int maxItems = 50}) {
  if (raw is! List) return const <TodoItem>[];
  final out = <TodoItem>[];
  for (final item in raw) {
    if (out.length >= maxItems) break;
    if (item is! Map) continue;
    final content = (item['content'] ?? item['task'] ?? '').toString().trim();
    if (content.isEmpty) continue;
    out.add(TodoItem(
      content: content,
      status: TodoItem._validStatus(item['status']?.toString()),
    ));
  }
  return out;
}

/// Render the snapshot injected at the system-prompt tail (stable format,
/// cache-prefix friendly).
String renderTodoSnapshot(List<TodoItem> todos) {
  if (todos.isEmpty) return '';
  final lines = <String>[
    '<current_todo_list>',
    for (final t in todos)
      '${t.isCompleted ? '[x]' : t.isInProgress ? '[~]' : '[ ]'} ${t.content}',
    '</current_todo_list>',
  ];
  return lines.join('\n');
}

class TodoService extends ChangeNotifier {
  static const String boxName = 'todo_v1';

  Box? _box;
  bool _initialized = false;

  final Map<String, List<TodoItem>> _cache = <String, List<TodoItem>>{};

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    _initialized = true;
    _box = await Hive.openBox(boxName);
  }

  /// Current snapshot for a conversation (empty when none).
  Future<List<TodoItem>> getTodos(String conversationId) async {
    await _ensureInitialized();
    final cached = _cache[conversationId];
    if (cached != null) return cached;
    final raw = _box?.get(conversationId);
    if (raw is! String || raw.isEmpty) {
      _cache[conversationId] = const <TodoItem>[];
      return const <TodoItem>[];
    }
    try {
      final decoded = jsonDecode(raw);
      final items = normalizeTodoItems(decoded);
      _cache[conversationId] = items;
      return items;
    } catch (_) {
      _cache[conversationId] = const <TodoItem>[];
      return const <TodoItem>[];
    }
  }

  /// Synchronous cache read (populated after the first [getTodos] / write).
  List<TodoItem> peek(String conversationId) {
    final cached = _cache[conversationId];
    if (cached != null) return cached;
    return const <TodoItem>[];
  }

  /// Whether [conversationId] has ever had a plan snapshot written. Used by
  /// the compaction layer to skip a redundant todo lookup for conversations
  /// that never used the plan tool.
  bool hasEverHadTodos(String conversationId) =>
      _cache.containsKey(conversationId);

  /// Whole-snapshot write (last-write-wins).
  Future<void> setTodos(String conversationId, List<TodoItem> todos) async {
    await _ensureInitialized();
    _cache[conversationId] = List.unmodifiable(todos);
    await _box?.put(
      conversationId,
      todos.isEmpty ? '' : jsonEncode([for (final t in todos) t.toJson()]),
    );
    notifyListeners();
  }

  /// Remove a conversation's plan (conversation deletion cleanup).
  Future<void> clearForConversation(String conversationId) async {
    await _ensureInitialized();
    _cache.remove(conversationId);
    await _box?.delete(conversationId);
    notifyListeners();
  }

  /// Test seam.
  @visibleForTesting
  Future<void> debugReset() async {
    await _ensureInitialized();
    _cache.clear();
    await _box?.clear();
    notifyListeners();
  }
}
