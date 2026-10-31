import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/core/models/chat_message.dart';
import 'package:OmniChat/core/models/conversation.dart';
import 'package:OmniChat/core/models/file_record.dart';
import 'package:OmniChat/core/models/workspace_config.dart';
import 'package:OmniChat/core/services/chat/storage/app_database.dart';
import 'package:OmniChat/core/services/chat/storage/chat_repository.dart';
import 'package:OmniChat/core/services/chat/storage/message_part_codec.dart';

void main() {
  late AppDatabase db;
  late ChatRepository repo;

  setUp(() {
    db = AppDatabase.inMemory();
    repo = ChatRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<Conversation> createConversation({String title = 'Chat'}) async {
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
    String role = 'user',
    String content = 'hi',
    String? groupId,
    int version = 0,
    bool isStreaming = false,
  }) {
    return repo.appendMessage(
      ChatMessage(
        role: role,
        content: content,
        conversationId: conversationId,
        timestamp: DateTime(2026, 1, 1),
        groupId: groupId,
        version: version,
        isStreaming: isStreaming,
      ),
    );
  }

  test('creates schema, preserves conversation metadata and message order',
      () async {
    final conversation = Conversation(
      title: 'Trip',
      assistantId: 'assistant-1',
      isPinned: true,
      truncateIndex: 1,
      compactBeforeIndex: 0,
      summary: 'summary',
      lastSummarizedMessageCount: 4,
      mcpServerIds: const ['mcp-a', 'mcp-b'],
      versionSelections: const {'g': 2},
    );
    await repo.upsertConversation(conversation);

    final first = await addMessage(conversation.id, content: 'one');
    final second = await addMessage(
      conversation.id,
      role: 'assistant',
      content: 'two',
    );

    final loaded = await repo.getConversation(conversation.id);
    expect(loaded, isNotNull);
    expect(loaded!.messageIds, [first.id, second.id]);
    expect(loaded.title, 'Trip');
    expect(loaded.assistantId, 'assistant-1');
    expect(loaded.isPinned, isTrue);
    expect(loaded.truncateIndex, 1);
    expect(loaded.compactBeforeIndex, 0);
    expect(loaded.summary, 'summary');
    expect(loaded.lastSummarizedMessageCount, 4);
    expect(loaded.mcpServerIds, ['mcp-a', 'mcp-b']);
    expect(loaded.versionSelections, {'g': 2});

    final messages = await repo.getMessages(conversation.id);
    expect(messages.map((m) => m.content), ['one', 'two']);
  });

  test('upserts by tool call id and updates one row only', () async {
    final conversation = await createConversation();
    final assistant = await addMessage(conversation.id, role: 'assistant');

    final part = await repo.upsertToolEvent(
      assistantMessageId: assistant.id,
      id: 'call-1',
      name: 'web_fetch',
      arguments: {'url': 'https://example.com'},
      content: 'first result',
      extras: {'webFetchSource': 'Local'},
    );
    await repo.upsertToolEvent(
      assistantMessageId: assistant.id,
      id: 'call-1',
      name: 'web_fetch',
      arguments: {'url': 'https://example.com'},
      content: 'second result',
    );

    final rows = await repo.partsForMessage(assistant.id);
    expect(rows, hasLength(1));
    expect(rows.single.partId, part.partId);
    expect(rows.single.content, 'second result');
    expect(rows.single.status, kPartStatusCompleted);
    expect(rows.single.metadataJson, contains('webFetchSource'));
  });

  test('empty-id placeholder is upgraded in place by a later id-aware result',
      () async {
    final conversation = await createConversation();
    final assistant = await addMessage(conversation.id, role: 'assistant');

    final placeholder = await repo.upsertToolEvent(
      assistantMessageId: assistant.id,
      id: '',
      name: 'file_read',
      arguments: <String, dynamic>{},
    );
    expect(placeholder.status, kPartStatusPending);

    await repo.upsertToolEvent(
      assistantMessageId: assistant.id,
      id: 'call-9',
      name: 'file_read',
      arguments: <String, dynamic>{},
      content: 'body',
    );
    final rows = await repo.partsForMessage(assistant.id);
    expect(rows, hasLength(1));
    expect(rows.single.partId, placeholder.partId);
    expect(rows.single.toolCallId, 'call-9');
    expect(rows.single.status, kPartStatusCompleted);
  });

  test('empty-id fallback never reuses interrupted or denied rows', () async {
    final conversation = await createConversation();
    final assistant = await addMessage(conversation.id, role: 'assistant');

    final placeholder = await repo.upsertToolEvent(
      assistantMessageId: assistant.id,
      id: '',
      name: 'file_read',
      arguments: <String, dynamic>{},
    );
    // Simulate a crash/stop that left an interrupted, no-id placeholder.
    await (db.update(db.messageParts)
          ..where((t) => t.partId.equals(placeholder.partId)))
        .write(
      const MessagePartsCompanion(status: Value(kPartStatusInterrupted)),
    );
    final interrupted = await repo.partsForMessage(assistant.id);
    expect(interrupted.single.status, kPartStatusInterrupted);

    await repo.upsertToolEvent(
      assistantMessageId: assistant.id,
      id: '',
      name: 'file_read',
      arguments: <String, dynamic>{},
      content: 'new result',
    );
    final rows = await repo.partsForMessage(assistant.id);
    expect(rows, hasLength(2));
    expect(rows.first.status, kPartStatusInterrupted);
    expect(rows.last.status, kPartStatusCompleted);
  });

  test('approval transitions keep pending JSON out of completed', () async {
    final conversation = await createConversation();
    final assistant = await addMessage(conversation.id, role: 'assistant');

    await repo.upsertToolEvent(
      assistantMessageId: assistant.id,
      id: 'call-approval',
      name: 'file_write',
      arguments: {'path': 'a.txt'},
      content: '{"requested_at": 1}',
      approvalState: kApprovalPending,
    );
    var rows = await repo.partsForMessage(assistant.id);
    expect(rows.single.status, kPartStatusPending);

    await repo.setToolEventApprovalState(
      assistantMessageId: assistant.id,
      id: 'call-approval',
      approvalState: kApprovalDenied,
      content: '{"denied": true}',
    );
    rows = await repo.partsForMessage(assistant.id);
    expect(rows.single.status, kPartStatusDenied);
    expect(rows.single.approvalState, kApprovalDenied);

    await repo.setToolEventApprovalState(
      assistantMessageId: assistant.id,
      id: 'call-approval',
      approvalState: kApprovalApproved,
      content: 'written',
    );
    rows = await repo.partsForMessage(assistant.id);
    expect(rows.single.status, kPartStatusCompleted);
  });

  test('summaries never carry completed bodies but eager-load approvals',
      () async {
    final conversation = await createConversation();
    final assistant = await addMessage(conversation.id, role: 'assistant');

    await repo.upsertToolEvent(
      assistantMessageId: assistant.id,
      id: 'call-done',
      name: 'file_read',
      arguments: {'path': 'big.txt', 'start_index': 0},
      content: 'x' * 5000,
    );
    await repo.upsertToolEvent(
      assistantMessageId: assistant.id,
      id: 'call-pending',
      name: 'file_write',
      arguments: {'path': 'a.txt'},
      content: '{"requested_at": 42}',
      approvalState: kApprovalPending,
    );

    final summaries = await repo.getToolPartSummaries(assistant.id);
    expect(summaries, hasLength(2));
    expect(summaries.first.status, kPartStatusCompleted);
    expect(summaries.first.eagerContent, isNull);
    expect(summaries.first.contentLoaded, isFalse);
    expect(summaries.first.contentLengthChars, 5000);
    expect(summaries.first.argumentsPreview, contains('big.txt'));
    expect(summaries.last.status, kPartStatusPending);
    expect(summaries.last.eagerContent, '{"requested_at": 42}');
    expect(summaries.last.contentLoaded, isTrue);

    final batchSummaries =
        await repo.getToolPartSummariesForMessages([assistant.id]);
    expect(batchSummaries, hasLength(2));
    expect(batchSummaries.first.eagerContent, isNull);
    expect(batchSummaries.last.eagerContent, '{"requested_at": 42}');

    final detail = await repo.loadToolEventDetail(
      assistantMessageId: assistant.id,
      toolCallId: 'call-done',
    );
    expect(detail, isNotNull);
    expect((detail!['content'] as String).length, 5000);
    expect(detail['arguments'], {'path': 'big.txt', 'start_index': 0});
  });

  test('deleting one version moves the replacement into the slot and clamps',
      () async {
    final conversation = await createConversation();
    final user0 = await addMessage(
      conversation.id,
      content: 'v0',
      groupId: 'group',
      version: 0,
    );
    final assistant = await addMessage(conversation.id, role: 'assistant');
    final user1 = await addMessage(
      conversation.id,
      content: 'v1',
      groupId: 'group',
      version: 1,
    );
    await repo.setConversationIndexes(
      conversation.id,
      truncateIndex: 3,
      compactBeforeIndex: 2,
    );

    expect(await repo.deleteMessage(user0.id), isTrue);

    final messages = await repo.getMessages(conversation.id);
    expect(messages.map((m) => m.id), [user1.id, assistant.id]);
    final loaded = await repo.getConversation(conversation.id);
    expect(loaded!.truncateIndex, 2);
    expect(loaded.compactBeforeIndex, 1);

    // Ordinals are contiguous after the two-phase renumber.
    final rows = await db.select(db.messageRows).get();
    final ordinals = rows.map((row) => row.ordinal).toList()..sort();
    expect(ordinals, [0, 1]);
  });

  test('deleting a conversation cascades to parts, artifacts, records, '
      'and workspace binding', () async {
    final conversation = await createConversation();
    final assistant = await addMessage(conversation.id, role: 'assistant');
    await repo.upsertToolEvent(
      assistantMessageId: assistant.id,
      id: 'call',
      name: 'tool',
      arguments: <String, dynamic>{},
      content: 'result',
    );
    await repo.setProviderArtifact(
      assistant.id,
      kGeminiThoughtSignatureKind,
      'sig',
    );
    await repo.upsertFileRecord(
      assistant.id,
      FileRecord(
        path: '/tmp/a.txt',
        fileName: 'a.txt',
        sizeBytes: 3,
        createdAt: DateTime(2026, 1, 1),
      ),
    );
    await repo.setWorkspaceBinding(
      conversation.id,
      const WorkspaceConfig.custom('/workspace'),
    );

    await repo.deleteConversation(conversation.id);

    final counts = await repo.counts();
    expect(counts.conversations, 0);
    expect(counts.messages, 0);
    expect(counts.parts, 0);
    expect(counts.providerArtifacts, 0);
    expect(counts.fileRecords, 0);
    expect(counts.workspaceBindings, 0);
  });

  test('fork clones messages, parts, artifacts, records and workspace',
      () async {
    final source = Conversation(
      title: 'Source',
      versionSelections: const {'g': 1},
    );
    await repo.upsertConversation(source);
    final user = await addMessage(source.id, content: 'question');
    final assistant = await addMessage(source.id, role: 'assistant');
    await repo.upsertToolEvent(
      assistantMessageId: assistant.id,
      id: 'call',
      name: 'web_search',
      arguments: {'q': 'x'},
      content: 'result',
    );
    await repo.setProviderArtifact(
      assistant.id,
      kGeminiThoughtSignatureKind,
      'sig-value',
    );
    await repo.upsertFileRecord(
      assistant.id,
      FileRecord(
        path: '/tmp/report.pdf',
        fileName: 'report.pdf',
        sizeBytes: 10,
        createdAt: DateTime(2026, 1, 1),
      ),
    );
    await repo.setWorkspaceBinding(
      source.id,
      const WorkspaceConfig.custom('/source-workspace'),
    );

    final fork = await repo.forkConversation(
      title: 'Fork',
      assistantId: null,
      sourceMessages: [user, assistant],
      versionSelections: const {'g': 1},
    );

    final forkMessages = await repo.getMessages(fork.id);
    expect(forkMessages, hasLength(2));
    expect(fork.messageIds, forkMessages.map((message) => message.id));
    expect(forkMessages.first.id, isNot(user.id));
    final forkAssistant =
        forkMessages.firstWhere((message) => message.role == 'assistant');

    final parts = await repo.partsForMessage(forkAssistant.id);
    expect(parts, hasLength(1));
    expect(parts.single.content, 'result');
    expect(parts.single.toolCallId, 'call');
    expect(
      await repo.getProviderArtifact(
        forkAssistant.id,
        kGeminiThoughtSignatureKind,
      ),
      'sig-value',
    );
    final records = await repo.getFileRecords(forkAssistant.id);
    expect(records.single.fileName, 'report.pdf');
    final binding = await repo.getWorkspaceBinding(fork.id);
    expect(binding?.path, '/source-workspace');
    expect(fork.versionSelections, {'g': 1});
  });

  test('stale streaming repair clears messages and only no-result parts',
      () async {
    final conversation = await createConversation();
    final assistant = await addMessage(
      conversation.id,
      role: 'assistant',
      isStreaming: true,
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    Future<void> insertPart({
      required int ordinal,
      required String status,
      String? approval,
      String? content,
    }) {
      return db.into(db.messageParts).insert(
            MessagePartsCompanion.insert(
              messageId: assistant.id,
              ordinal: ordinal,
              kind: kToolPartKind,
              toolName: const Value('tool'),
              content: Value(content),
              status: Value(status),
              approvalState: Value(approval),
              createdAtMs: now,
              updatedAtMs: now,
            ),
          );
    }

    await insertPart(
      ordinal: 0,
      status: kPartStatusPending,
      approval: kApprovalPending,
    );
    await insertPart(
      ordinal: 1,
      status: kPartStatusDenied,
      approval: kApprovalDenied,
    );
    await insertPart(
      ordinal: 2,
      status: kPartStatusPending,
      approval: kApprovalApproved,
    );
    await insertPart(ordinal: 3, status: kPartStatusPending);

    final repaired = await repo.repairStaleStreaming();
    expect(repaired.messages, 1);
    expect(repaired.parts, 2);

    final message = await repo.getMessage(assistant.id);
    expect(message!.isStreaming, isFalse);
    final rows = await repo.partsForMessage(assistant.id);
    expect(rows[0].status, kPartStatusPending);
    expect(rows[1].status, kPartStatusDenied);
    expect(rows[2].status, kPartStatusInterrupted);
    expect(rows[3].status, kPartStatusInterrupted);
  });

  test('migration metadata and quarantine round-trip', () async {
    await repo.putMigrationMeta({'state': 'complete_clean', 'source': 'hive'});
    final meta = await repo.readMigrationMeta();
    expect(meta['state'], 'complete_clean');
    expect(meta['source'], 'hive');

    await repo.insertQuarantine(
      sourceBox: 'tool_events_v1',
      sourceKey: 'missing',
      payloadJson: '{"x":1}',
      payloadSha256: 'abc',
      error: 'missing parent',
    );
    expect(await repo.quarantineCount(), 1);
    final rows = await repo.readQuarantine();
    expect(rows.single.sourceKey, 'missing');
    expect(rows.single.payloadSha256, 'abc');
  });
}
