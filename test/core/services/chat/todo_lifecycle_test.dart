// todo lifecycle tests (docs/write_todos_improvement_plan.md §2.5 / §5).
//
// Once the projection reads conversation events, backup/restore, delete and
// fork are correct by construction: the events are conversation data. These
// tests pin the remaining seams:
// - the one-time todo_v1 migration rules (event wins / synthesize / keep),
// - the read-only fallback for conversations without an assistant message,
// - eager write_todos content on restored summaries (no eternal spinner),
// - hasCompletedTodoEvent / getLatestTodoEvent on the SQLite repository.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/models/chat_message.dart';
import 'package:OmniChat/core/models/conversation.dart';
import 'package:OmniChat/core/services/chat/storage/app_database.dart';
import 'package:OmniChat/core/services/chat/storage/chat_repository.dart';
import 'package:OmniChat/core/services/chat/todo_models.dart';
import 'package:OmniChat/core/services/chat/todo_v1_migration.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory hiveDir;
  late AppDatabase db;
  late ChatRepository repo;
  Box<dynamic>? box;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    hiveDir = await Directory.systemTemp.createTemp('todo_migration_test');
    Hive.init(hiveDir.path);
    await TodoV1Migration.debugReset();
    db = AppDatabase.inMemory();
    repo = ChatRepository(db);
    box = await Hive.openBox<dynamic>(TodoV1Migration.boxName);
  });

  tearDown(() async {
    await db.close();
    try {
      await Hive.deleteBoxFromDisk(TodoV1Migration.boxName);
    } catch (_) {}
    await TodoV1Migration.debugReset();
    try {
      await hiveDir.delete(recursive: true);
    } catch (_) {}
  });

  Future<Conversation> createConversation(String title) async {
    final conversation = Conversation(
      title: title,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 2),
    );
    await repo.upsertConversation(conversation);
    return conversation;
  }

  Future<ChatMessage> addMessage(
    String conversationId, {
    String role = 'assistant',
    String content = '',
    String? groupId,
    int version = 0,
  }) {
    return repo.appendMessage(
      ChatMessage(
        role: role,
        content: content,
        conversationId: conversationId,
        timestamp: DateTime(2026, 1, 1),
        groupId: groupId,
        version: version,
      ),
    );
  }

  Future<void> putBoxEntry(String conversationId, Object? value) async {
    await box!.put(conversationId, value == null ? '' : jsonEncode(value));
  }

  group('todo_v1 one-time migration (§2.5.3)', () {
    test('rule 1: a successful event wins; the box entry is dropped', () async {
      final conversation = await createConversation('A');
      final message = await addMessage(conversation.id);
      await repo.upsertToolEvent(
        assistantMessageId: message.id,
        id: 'call_1',
        name: todoToolName,
        arguments: {
          'todos': [
            {'content': 'from event', 'status': 'pending'},
          ],
        },
        content: buildTodoResultContent(
          items: const [
            TodoItem(content: 'from event', status: todoStatusPending),
          ],
          changed: true,
          cleared: false,
        ),
      );
      await putBoxEntry(conversation.id, [
        {'content': 'from box', 'status': 'pending'},
      ]);

      final prefs = await SharedPreferences.getInstance();
      await TodoV1Migration.runWith(
        prefs: prefs,
        appDataDirPath: null,
        hasCompletedEvent: repo.hasCompletedTodoEvent,
        lastActiveAssistantMessageId: (_) => null,
        appendEvent: (
          messageId, {
          required id,
          required name,
          required arguments,
          content,
          approvalState,
          extras,
        }) async {},
      );

      expect(box!.get(conversation.id), isNull);
      // The event part is untouched.
      final events = await repo.getToolEvents(message.id);
      expect(
        (events.single['arguments'] as Map)['todos'].single['content'],
        'from event',
      );
    });

    test('rule 2: no event + assistant message → synthesized part', () async {
      final conversation = await createConversation('B');
      final message = await addMessage(conversation.id, content: 'reply');
      await putBoxEntry(conversation.id, [
        {'content': 'from box', 'status': 'in_progress'},
      ]);

      final prefs = await SharedPreferences.getInstance();
      await TodoV1Migration.runWith(
        prefs: prefs,
        appDataDirPath: null,
        hasCompletedEvent: repo.hasCompletedTodoEvent,
        lastActiveAssistantMessageId: (_) => message.id,
        appendEvent:
            (
              messageId, {
              required id,
              required name,
              required arguments,
              content,
              approvalState,
              extras,
            }) => repo.upsertToolEvent(
              assistantMessageId: messageId,
              id: id,
              name: name,
              arguments: arguments,
              content: content,
              approvalState: approvalState,
              extras: extras,
            ),
      );

      expect(box!.get(conversation.id), isNull);
      expect(await repo.hasCompletedTodoEvent(conversation.id), isTrue);
      final latest = await repo.getLatestTodoEvent(conversation.id);
      expect(latest, isNotNull);
      final snapshot = parseTodoSnapshotContent(latest!['content'] as String);
      expect(snapshot, isNotNull);
      expect(snapshot!.items.single.content, 'from box');
      expect(snapshot.items.single.isInProgress, isTrue);
      expect(snapshot.notice, isNotNull);
      // origin metadata rides the part (flattened into the event map).
      final events = await repo.getToolEvents(message.id);
      expect(events.single['origin'], TodoV1Migration.originMigration);
    });

    test(
      'rule 3: no assistant message → entry kept, fallback readable',
      () async {
        final conversation = await createConversation('C');
        await addMessage(conversation.id, role: 'user', content: 'hi');
        await putBoxEntry(conversation.id, [
          {'content': 'kept plan', 'status': 'pending'},
        ]);

        final prefs = await SharedPreferences.getInstance();
        await TodoV1Migration.runWith(
          prefs: prefs,
          appDataDirPath: null,
          hasCompletedEvent: repo.hasCompletedTodoEvent,
          lastActiveAssistantMessageId: (_) => null,
          appendEvent: (
            messageId, {
            required id,
            required name,
            required arguments,
            content,
            approvalState,
            extras,
          }) async {},
        );

        expect(box!.get(conversation.id), isNotNull);
        final fallback = await TodoV1Migration.legacyItemsFor(conversation.id);
        expect(fallback, isNotNull);
        expect(fallback!.single.content, 'kept plan');
      },
    );

    test('empty / corrupt box entries are dropped', () async {
      await putBoxEntry('conv-empty', '');
      await putBoxEntry('conv-corrupt', 'not json{');
      await putBoxEntry('conv-invalid', [
        {'content': '   ', 'status': 'pending'},
      ]);

      final prefs = await SharedPreferences.getInstance();
      await TodoV1Migration.runWith(
        prefs: prefs,
        appDataDirPath: null,
        hasCompletedEvent: repo.hasCompletedTodoEvent,
        lastActiveAssistantMessageId: (_) => null,
        appendEvent: (
          messageId, {
          required id,
          required name,
          required arguments,
          content,
          approvalState,
          extras,
        }) async {},
      );

      expect(box!.get('conv-empty'), isNull);
      expect(box!.get('conv-corrupt'), isNull);
      expect(box!.get('conv-invalid'), isNull);
    });

    test('migration runs once (idempotent marker)', () async {
      final conversation = await createConversation('D');
      final message = await addMessage(conversation.id);
      await putBoxEntry(conversation.id, [
        {'content': 'plan', 'status': 'pending'},
      ]);

      final prefs = await SharedPreferences.getInstance();
      var appendCalls = 0;
      Future<void> append(
        String messageId, {
        required String id,
        required String name,
        required Map<String, dynamic> arguments,
        String? content,
        String? approvalState,
        Map<String, dynamic>? extras,
      }) async {
        appendCalls++;
      }

      await TodoV1Migration.runWith(
        prefs: prefs,
        appDataDirPath: null,
        hasCompletedEvent: repo.hasCompletedTodoEvent,
        lastActiveAssistantMessageId: (_) => message.id,
        appendEvent: append,
      );
      expect(box!.get(conversation.id), isNull);
      expect(appendCalls, 1);
      expect(prefs.getBool(TodoV1Migration.migratedPrefsKey), isTrue);

      // A late box write is NOT migrated again (marker set).
      await putBoxEntry(conversation.id, [
        {'content': 'late plan', 'status': 'pending'},
      ]);
      await TodoV1Migration.runWith(
        prefs: prefs,
        appDataDirPath: null,
        hasCompletedEvent: repo.hasCompletedTodoEvent,
        lastActiveAssistantMessageId: (_) => message.id,
        appendEvent: append,
      );
      expect(
        box!.get(conversation.id),
        isNotNull,
        reason: 'marker prevents a second migration pass',
      );
      expect(appendCalls, 1);
    });

    test('version selection picks the active branch target', () {
      final v0 = ChatMessage(
        id: 'm0',
        role: 'assistant',
        content: '',
        conversationId: 'c',
        timestamp: DateTime(2026, 1, 1),
        groupId: 'g1',
        version: 0,
      );
      final v1 = ChatMessage(
        id: 'm1',
        role: 'assistant',
        content: '',
        conversationId: 'c',
        timestamp: DateTime(2026, 1, 1),
        groupId: 'g1',
        version: 1,
      );
      // Default (no selections) → newest version.
      expect(TodoV1Migration.lastActiveAssistantMessageId([v0, v1], {}), 'm1');
      // Selected version 0 → m0.
      expect(
        TodoV1Migration.lastActiveAssistantMessageId([v0, v1], {'g1': 0}),
        'm0',
      );
      // A user message is never a target.
      final user = ChatMessage(
        id: 'u1',
        role: 'user',
        content: 'hi',
        conversationId: 'c',
        timestamp: DateTime(2026, 1, 1),
      );
      expect(TodoV1Migration.lastActiveAssistantMessageId([user], {}), isNull);
    });
  });

  group('repository contracts (§2.5.1)', () {
    test('eager summary includes write_todos content and arguments', () async {
      final conversation = await createConversation('E');
      final message = await addMessage(conversation.id);
      await repo.upsertToolEvent(
        assistantMessageId: message.id,
        id: 'call_1',
        name: todoToolName,
        arguments: {
          'todos': [
            {'content': 'A', 'status': 'completed'},
          ],
        },
        content: buildTodoResultContent(
          items: const [TodoItem(content: 'A', status: todoStatusCompleted)],
          changed: true,
          cleared: false,
        ),
      );

      final summaries = await repo.getToolPartSummaries(message.id);
      expect(
        summaries.single.eagerContent,
        isNotNull,
        reason: 'restored completed cards must not spin forever',
      );
      expect(summaries.single.eagerArgumentsJson, isNotNull);
      expect(summaries.single.contentLoaded, isTrue);
    });

    test(
      'getLatestTodoEvent returns the newest write_todos part (any status)',
      () async {
        final conversation = await createConversation('F');
        final message = await addMessage(conversation.id);
        await repo.upsertToolEvent(
          assistantMessageId: message.id,
          id: 'call_1',
          name: todoToolName,
          arguments: {
            'todos': [
              {'content': 'old', 'status': 'pending'},
            ],
          },
          content: buildTodoResultContent(
            items: const [TodoItem(content: 'old', status: todoStatusPending)],
            changed: true,
            cleared: false,
          ),
        );
        await repo.upsertToolEvent(
          assistantMessageId: message.id,
          id: 'call_2',
          name: todoToolName,
          arguments: {
            'todos': [
              {'content': 'new', 'status': 'in_progress'},
            ],
          },
          content: buildTodoResultContent(
            items: const [
              TodoItem(content: 'new', status: todoStatusInProgress),
            ],
            changed: true,
            cleared: false,
          ),
        );

        final latest = await repo.getLatestTodoEvent(conversation.id);
        expect(latest, isNotNull);
        expect(latest!['id'], 'call_2');
        final snapshot = parseTodoSnapshotContent(latest['content'] as String);
        expect(snapshot!.items.single.content, 'new');
      },
    );

    test('fork copies write_todos parts; delete leaves no orphan', () async {
      final conversation = await createConversation('G');
      final message = await addMessage(conversation.id);
      await repo.upsertToolEvent(
        assistantMessageId: message.id,
        id: 'call_1',
        name: todoToolName,
        arguments: {
          'todos': [
            {'content': 'plan', 'status': 'pending'},
          ],
        },
        content: buildTodoResultContent(
          items: const [TodoItem(content: 'plan', status: todoStatusPending)],
          changed: true,
          cleared: false,
        ),
      );
      expect(await repo.hasCompletedTodoEvent(conversation.id), isTrue);

      final sourceMessages = await repo.getMessages(conversation.id);
      final fork = await repo.forkConversation(
        title: 'G fork',
        assistantId: null,
        sourceMessages: sourceMessages,
      );

      expect(
        await repo.hasCompletedTodoEvent(fork.id),
        isTrue,
        reason: 'fork carries the plan',
      );

      await repo.deleteConversation(conversation.id);
      expect(
        await repo.hasCompletedTodoEvent(conversation.id),
        isFalse,
        reason: 'delete cascades the parts',
      );
    });

    test('user_clear appends a completed part and keeps its origin', () async {
      final conversation = await createConversation('H');
      final message = await addMessage(conversation.id);
      await repo.upsertToolEvent(
        assistantMessageId: message.id,
        id: 'call_1',
        name: todoToolName,
        arguments: {
          'todos': [
            {'content': 'plan', 'status': 'pending'},
          ],
        },
        content: buildTodoResultContent(
          items: const [TodoItem(content: 'plan', status: todoStatusPending)],
          changed: true,
          cleared: false,
        ),
      );

      // Phase 3-2: the user clear is a real write_todos event, not UI-only.
      const clearArguments = <String, dynamic>{'todos': <dynamic>[]};
      await repo.upsertToolEvent(
        assistantMessageId: message.id,
        id: 'user_clear_1',
        name: todoToolName,
        arguments: clearArguments,
        content: buildTodoResultContent(
          items: const <TodoItem>[],
          changed: true,
          cleared: true,
        ),
        extras: const <String, dynamic>{'origin': 'user_clear'},
      );

      final events = await repo.getToolEvents(message.id);
      final clear = events.last;
      expect(clear['id'], 'user_clear_1');
      expect(clear['origin'], 'user_clear');
      final snapshot = parseTodoSnapshotContent(clear['content'] as String);
      expect(snapshot, isNotNull);
      expect(snapshot!.cleared, isTrue);
      expect(snapshot.items, isEmpty);

      final latest = await repo.getLatestTodoEvent(conversation.id);
      expect(latest!['id'], 'user_clear_1');
    });
  });
}
