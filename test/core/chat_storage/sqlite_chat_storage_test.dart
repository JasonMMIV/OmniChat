import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/models/chat_message.dart';
import 'package:OmniChat/core/models/conversation.dart';
import 'package:OmniChat/core/models/workspace_config.dart';
import 'package:OmniChat/core/services/chat/chat_service.dart';
import 'package:OmniChat/core/services/chat/storage/chat_storage.dart';
import 'package:OmniChat/core/services/chat/storage/message_part_codec.dart';
import 'package:OmniChat/core/services/chat/storage/sqlite_chat_storage.dart';

ChatMessage _message(
  String id,
  String role,
  String content,
  String conversationId, {
  String? groupId,
  int version = 0,
  bool isStreaming = false,
}) {
  return ChatMessage(
    id: id,
    role: role,
    content: content,
    conversationId: conversationId,
    groupId: groupId,
    version: version,
    isStreaming: isStreaming,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late SqliteChatStorage storage;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'omnichat_sqlite_storage_',
    );
    storage = SqliteChatStorage(
      directory: directory,
      appVersion: 'test',
      background: false,
    );
    await storage.initialize();
  });

  tearDown(() async {
    await storage.dispose();
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  test('persists conversations, message order, and tool events', () async {
    await storage.putConversation(
      Conversation(id: 'c1', title: 'Chat', createdAt: DateTime(2026)),
    );
    await storage.appendMessage(_message('m1', 'user', 'hi', 'c1'));
    await storage.appendMessage(_message('m2', 'assistant', 'hello', 'c1'));
    await storage.upsertToolEvent(
      'm2',
      id: 'call_1',
      name: 'file_read',
      arguments: const {'path': 'a.txt'},
      content: 'body',
    );

    expect(storage.getConversation('c1')!.messageIds, <String>['m1', 'm2']);
    expect(storage.getMessages('c1').map((m) => m.id), <String>['m1', 'm2']);
    expect(storage.getToolEvents('m2').single['content'], 'body');

    await storage.dispose();
    storage = SqliteChatStorage(
      directory: directory,
      appVersion: 'test',
      background: false,
    );
    await storage.initialize();

    expect(
      () => storage.getMessages('c1'),
      throwsA(isA<ChatStorageNotLoadedException>()),
    );
    expect(
      () => storage.getToolEvents('m2'),
      throwsA(isA<ChatStorageNotLoadedException>()),
    );
    await storage.ensureConversationLoaded('c1');
    expect(storage.getMessages('c1').map((m) => m.id), <String>['m1', 'm2']);
    final summary = storage.getToolPartSummaries('m2').single;
    expect(summary.status, kPartStatusCompleted);
    expect(summary.contentLoaded, isFalse);
    expect(summary.contentLengthChars, 4);
    expect(
      () => storage.getToolEvents('m2'),
      throwsA(isA<ChatStorageNotLoadedException>()),
    );
    await storage.ensureToolEventsLoaded(['m2']);
    final events = storage.getToolEvents('m2');
    expect(events, hasLength(1));
    expect(events.single['id'], 'call_1');
    expect(events.single['name'], 'file_read');
    expect(events.single['arguments'], const {'path': 'a.txt'});
  });

  test(
    'derives part status from approval state, never content alone',
    () async {
      await storage.putConversation(
        Conversation(id: 'c1', title: 'Chat', createdAt: DateTime(2026)),
      );
      await storage.appendMessage(_message('m1', 'assistant', '', 'c1'));

      await storage.upsertToolEvent(
        'm1',
        id: 'call_pending',
        name: 'file_write',
        arguments: const {'path': 'out.txt'},
        content: '{"type":"approval_required"}',
        approvalState: kApprovalPending,
      );
      expect(
        (await storage.repository.partsForMessage('m1')).single.status,
        kPartStatusPending,
      );

      await storage.setToolEventApprovalState(
        'm1',
        id: 'call_pending',
        approvalState: kApprovalApproved,
        content: 'written',
      );
      final part = (await storage.repository.partsForMessage('m1')).single;
      expect(part.status, kPartStatusCompleted);
      expect(part.content, 'written');
      expect(
        storage.getToolEvents('m1').single['approvalState'],
        kApprovalApproved,
      );

      await storage.setToolEventApprovalState(
        'm1',
        id: 'call_pending',
        approvalState: kApprovalDenied,
        content: '{"type":"approval_denied"}',
      );
      expect(
        (await storage.repository.partsForMessage('m1')).single.status,
        kPartStatusDenied,
      );
    },
  );

  test(
    'live setToolEvents keeps pending placeholders; restored is interrupted',
    () async {
      await storage.putConversation(
        Conversation(id: 'c1', title: 'Chat', createdAt: DateTime(2026)),
      );
      await storage.appendMessage(
        _message('m1', 'assistant', '', 'c1', isStreaming: true),
      );

      await storage.setToolEvents('m1', [
        {
          'id': 'call_1',
          'name': 'file_read',
          'arguments': const {'path': 'a.txt'},
          'content': null,
        },
      ]);
      expect(
        (await storage.repository.partsForMessage('m1')).single.status,
        kPartStatusPending,
      );

      await storage.updateMessage('m1', isStreaming: false);
      await storage.setToolEvents('m1', [
        {
          'id': 'call_1',
          'name': 'file_read',
          'arguments': const {'path': 'a.txt'},
          'content': null,
        },
      ]);
      expect(
        (await storage.repository.partsForMessage('m1')).single.status,
        kPartStatusInterrupted,
      );
    },
  );
  test(
    'summaries keep bodies lazy and eager only for cards/approvals',
    () async {
      await storage.putConversation(
        Conversation(id: 'c1', title: 'Chat', createdAt: DateTime(2026)),
      );
      await storage.appendMessage(_message('m1', 'assistant', '', 'c1'));
      await storage.upsertToolEvent(
        'm1',
        id: 'read',
        name: 'file_read',
        arguments: const {'path': 'a.txt'},
        content: 'body',
        extras: const {'webFetchSource': 'Local'},
      );
      await storage.upsertToolEvent(
        'm1',
        id: 'write',
        name: 'file_write',
        arguments: const {'path': 'b.txt'},
        content: '{"type":"approval_required","tool":"file_write"}',
        approvalState: kApprovalPending,
      );
      await storage.upsertToolEvent(
        'm1',
        id: 'ask',
        name: 'ask_user',
        arguments: const {
          'questions': [
            {
              'id': 'q1',
              'question': 'Pick one',
              'options': ['A', 'B'],
            },
          ],
        },
        content: '{"type":"ask_user_answer","answers":[]}',
      );
      await storage.upsertToolEvent(
        'm1',
        id: 'todo',
        name: 'write_todos',
        arguments: const {
          'todos': [
            {'content': 'step', 'status': 'pending'},
          ],
        },
        content: 'ok',
      );
      await storage.upsertToolEvent(
        'm1',
        id: 'search',
        name: 'search_web',
        arguments: const {'query': 'flutter'},
        content:
            '{"items":[{"id":"1","title":"A","url":"https://a"},'
            '{"id":"2","title":"B","url":"https://b"}]}',
        extras: const {'searchProvider': 'tavily'},
      );

      // Reopen so summaries come from the summary SQL path, not the write cache.
      await storage.dispose();
      storage = SqliteChatStorage(
        directory: directory,
        appVersion: 'test',
        background: false,
      );
      await storage.initialize();
      expect(
        () => storage.getToolPartSummaries('m1'),
        throwsA(isA<ChatStorageNotLoadedException>()),
      );
      await storage.ensureConversationLoaded('c1');

      final summaries = storage.getToolPartSummaries('m1');
      expect(summaries, hasLength(5));
      final read = summaries.firstWhere((s) => s.toolCallId == 'read');
      expect(read.contentLoaded, isFalse);
      expect(read.contentLengthChars, 4);
      expect(read.eagerArgumentsJson, isNull);
      expect(read.webFetchSource, 'Local');

      final write = summaries.firstWhere((s) => s.toolCallId == 'write');
      expect(write.status, kPartStatusPending);
      expect(write.contentLoaded, isTrue);
      expect(write.eagerArgumentsJson, contains('b.txt'));

      final ask = summaries.firstWhere((s) => s.toolCallId == 'ask');
      expect(ask.status, kPartStatusCompleted);
      expect(ask.contentLoaded, isTrue);
      expect(ask.eagerArgumentsJson, contains('Pick one'));

      final todo = summaries.firstWhere((s) => s.toolCallId == 'todo');
      expect(todo.contentLoaded, isFalse);
      expect(todo.eagerArgumentsJson, contains('step'));

      final search = summaries.firstWhere((s) => s.toolCallId == 'search');
      expect(search.searchProvider, 'tavily');
      expect(search.contentLoaded, isFalse);

      // Loading one detail does not mark the whole event list loaded.
      expect(
        () => storage.getToolEvents('m1'),
        throwsA(isA<ChatStorageNotLoadedException>()),
      );
      final detail = await storage.loadToolEventDetail(
        assistantMessageId: 'm1',
        toolCallId: 'read',
      );
      expect(detail!['content'], 'body');
      expect(detail['arguments'], const {'path': 'a.txt'});
      expect(
        () => storage.getToolEvents('m1'),
        throwsA(isA<ChatStorageNotLoadedException>()),
      );

      final citations = await storage.getSearchCitations('m1');
      expect(citations, hasLength(2));
      expect(citations.first['url'], 'https://a');
    },
  );

  test(
    'setToolEvents keeps part ids stable across streaming updates',
    () async {
      await storage.putConversation(
        Conversation(id: 'c1', title: 'Chat', createdAt: DateTime(2026)),
      );
      await storage.appendMessage(
        _message('m1', 'assistant', '', 'c1', isStreaming: true),
      );
      await storage.setToolEvents('m1', [
        {
          'id': 'call_1',
          'name': 'file_read',
          'arguments': const {'path': 'a'},
          'content': null,
        },
      ]);
      final first = (await storage.repository.partsForMessage('m1')).single;
      expect(first.status, kPartStatusPending);

      await storage.setToolEvents('m1', [
        {
          'id': 'call_1',
          'name': 'file_read',
          'arguments': const {'path': 'a'},
          'content': 'body',
        },
        {
          'id': 'call_2',
          'name': 'file_write',
          'arguments': const {'path': 'b'},
          'content': null,
        },
      ]);
      final parts = await storage.repository.partsForMessage('m1');
      expect(parts, hasLength(2));
      expect(parts.first.partId, first.partId);
      expect(parts.first.status, kPartStatusCompleted);
      expect(parts.first.content, 'body');
      expect(parts.last.partId, isNot(first.partId));
      expect(parts.last.status, kPartStatusPending);
    },
  );

  test(
    'delete version renumbers and retargets the selection (R1/R2)',
    () async {
      await storage.putConversation(
        Conversation(id: 'c1', title: 'Chat', createdAt: DateTime(2026)),
      );
      await storage.appendMessage(
        _message('m1', 'user', 'v0', 'c1', groupId: 'g1', version: 0),
      );
      await storage.appendMessage(_message('m2', 'assistant', 'reply', 'c1'));
      await storage.appendMessage(
        _message('m3', 'user', 'v1', 'c1', groupId: 'g1', version: 1),
      );
      await storage.setVersionSelections('c1', {'g1': 1});

      expect(await storage.deleteMessage('m3'), isTrue);

      final conversation = storage.getConversation('c1')!;
      expect(conversation.messageIds, <String>['m1', 'm2']);
      expect(conversation.versionSelections['g1'], 0);
      expect(storage.getMessages('c1').map((m) => m.id), <String>['m1', 'm2']);
      expect((await storage.repository.invalidConversationIndexes()), isEmpty);
    },
  );

  test(
    'fork clones tool parts and makes the new conversation readable',
    () async {
      await storage.putConversation(
        Conversation(id: 'c1', title: 'Chat', createdAt: DateTime(2026)),
      );
      final user = _message('m1', 'user', 'read a.txt', 'c1');
      final assistant = _message('m2', 'assistant', 'done', 'c1');
      await storage.appendMessage(user);
      await storage.appendMessage(assistant);
      await storage.upsertToolEvent(
        'm2',
        id: 'call_1',
        name: 'file_read',
        arguments: const {'path': 'a.txt'},
        content: 'contents',
      );

      final forked = await storage.forkConversation(
        title: 'Fork',
        assistantId: null,
        sourceMessages: [user, assistant],
      );
      expect(forked.messageIds, hasLength(2));
      final cloned = storage
          .getMessages(forked.id)
          .firstWhere((m) => m.role == 'assistant');
      expect(storage.getToolPartSummaries(cloned.id), hasLength(1));
      await storage.ensureToolEventsLoaded([cloned.id]);
      expect(storage.getToolEvents(cloned.id), hasLength(1));
      expect(storage.getToolEvents(cloned.id).single['content'], 'contents');
    },
  );

  test('clearAllChatRows does not write the legacy-import sentinel', () async {
    final service = ChatService(storage: storage);
    await service.init();
    addTearDown(service.close);

    await service.createConversation(title: 'Restore target');
    final conversation = service.getAllConversations().single;
    await service.addMessage(
      conversationId: conversation.id,
      role: 'user',
      content: 'old',
    );

    await service.clearAllChatRows();

    expect(service.getAllConversations(), isEmpty);
    expect(service.getMessages(conversation.id), isEmpty);
    expect(
      await File('${directory.path}/chat_v2.legacy_import_disabled').exists(),
      isFalse,
    );
    expect(await File('${directory.path}/chat_v2.sqlite').exists(), isTrue);
  });

  test('facade clearAllData follows the reset marker flow (§8.10)', () async {
    final service = ChatService(storage: storage);
    await service.init();
    addTearDown(service.close);

    await service.createConversation(title: 'Doomed');
    final conversation = service.getAllConversations().single;
    await service.addMessage(
      conversationId: conversation.id,
      role: 'user',
      content: 'gone',
    );
    expect(service.getMessages(conversation.id), hasLength(1));

    await service.clearAllData();

    expect(service.getAllConversations(), isEmpty);
    expect(service.getMessages(conversation.id), isEmpty);
    final receipt = await directory
        .list()
        .map((e) => e.uri.pathSegments.last)
        .toList();
    expect(receipt, contains('chat_v2.legacy_import_disabled'));
    expect(receipt, isNot(contains('chat_v2.reset')));
  });

  test(
    'facade promotes a draft on first message and bounds file_read',
    () async {
      final service = ChatService(storage: storage);
      await service.init();
      expect(service.backend, ChatStorageBackend.sqlite);

      final draft = await service.createDraftConversation(title: 'Draft');
      expect(service.getConversation(draft.id), isNotNull);
      expect(service.getMessages(draft.id), isEmpty);

      final message = await service.addMessage(
        conversationId: draft.id,
        role: 'assistant',
        content: '',
      );
      expect(service.getConversation(draft.id)!.messageIds, <String>[
        message.id,
      ]);
      expect(service.getMessages(draft.id).single.id, message.id);

      // A draft workspace choice is memory-only until promotion, then joined to
      // the persisted conversation (SQLite has a FK on the binding).
      final draftWithWorkspace = await service.createDraftConversation(
        title: 'Workspace draft',
      );
      await service.setConversationWorkspaceConfig(
        draftWithWorkspace.id,
        const WorkspaceConfig.custom('/tmp/ws'),
      );
      expect(
        service.getConversationWorkspaceConfig(draftWithWorkspace.id)?.path,
        '/tmp/ws',
      );
      await service.addMessage(
        conversationId: draftWithWorkspace.id,
        role: 'user',
        content: 'go',
      );
      expect(
        service.getConversationWorkspaceConfig(draftWithWorkspace.id)?.path,
        '/tmp/ws',
      );

      final longContent =
          'x' * (ChatService.maxPersistedFileReadResultChars + 100);
      await service.upsertToolEvent(
        message.id,
        id: 'call_read',
        name: 'file_read',
        arguments: const {'path': 'big.txt'},
        content: longContent,
      );
      final stored =
          service.getToolEvents(message.id).single['content'] as String;
      expect(
        stored.length,
        lessThanOrEqualTo(ChatService.maxPersistedFileReadResultChars),
      );
      expect(stored, contains('persisted preview'));
    },
  );

  test('attachment content query stays narrow', () async {
    await storage.putConversation(
      Conversation(id: 'c1', title: 'Attachments', createdAt: DateTime(2026)),
    );
    await storage.appendMessage(
      _message('m1', 'user', '[image:/tmp/a.png]', 'c1'),
    );
    await storage.appendMessage(_message('m2', 'user', 'plain text', 'c1'));
    await storage.appendMessage(
      _message(
        'm3',
        'assistant',
        '[file:/tmp/b.pdf|b.pdf|application/pdf]',
        'c1',
      ),
    );

    expect(await storage.attachmentBearingMessageContents(), hasLength(2));
  });
}
