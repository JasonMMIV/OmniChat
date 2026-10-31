import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:OmniChat/core/models/chat_message.dart';
import 'package:OmniChat/core/models/conversation.dart';
import 'package:OmniChat/core/services/chat/storage/app_database.dart';
import 'package:OmniChat/core/services/chat/storage/chat_database_files.dart';
import 'package:OmniChat/core/services/chat/storage/chat_repository.dart';
import 'package:OmniChat/core/services/chat/storage/legacy_hive_importer.dart';
import 'package:OmniChat/core/services/chat/storage/message_part_codec.dart';

void main() {
  late Directory directory;
  late ChatDatabaseFiles files;

  setUp(() async {
    await Hive.close();
    directory = await Directory.systemTemp.createTemp('omnichat_import_');
    files = ChatDatabaseFiles(directory);
    if (!Hive.isAdapterRegistered(0)) {
      Hive.registerAdapter(ChatMessageAdapter());
    }
    if (!Hive.isAdapterRegistered(1)) {
      Hive.registerAdapter(ConversationAdapter());
    }
    Hive.init(directory.path);
  });

  tearDown(() async {
    await Hive.close();
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  Future<void> writeFullLegacyData() async {
    final conversations = await Hive.openBox<Conversation>(
      'conversations',
      path: directory.path,
    );
    final messages = await Hive.openBox<ChatMessage>(
      'messages',
      path: directory.path,
    );
    final toolEvents = await Hive.openBox(
      'tool_events_v1',
      path: directory.path,
    );
    final fileRecords = await Hive.openBox(
      'message_file_records_v1',
      path: directory.path,
    );
    final workspaceV2 = await Hive.openBox(
      'conversation_workspace_bindings_v2',
      path: directory.path,
    );
    final workspaceV1 = await Hive.openBox(
      'conversation_workspaces_v1',
      path: directory.path,
    );

    final user = ChatMessage(
      id: 'user-1',
      role: 'user',
      content: 'hello 😀',
      conversationId: 'chat-1',
      timestamp: DateTime.utc(2026, 1, 1, 10),
    );
    final assistant = ChatMessage(
      id: 'assistant-1',
      role: 'assistant',
      content: 'answer',
      conversationId: 'chat-1',
      timestamp: DateTime.utc(2026, 1, 1, 11),
      modelId: 'model-1',
      providerId: 'provider-1',
      totalTokens: 12,
      promptTokens: 5,
      completionTokens: 7,
      cachedTokens: 2,
      reasoningText: 'think',
      reasoningStartAt: DateTime.utc(2026, 1, 1, 10, 59),
      reasoningFinishedAt: DateTime.utc(2026, 1, 1, 11, 1),
      processStartedAt: DateTime.utc(2026, 1, 1, 10, 58),
      processFinishedAt: DateTime.utc(2026, 1, 1, 11, 2),
      translation: 'translated',
      reasoningSegmentsJson: '[{"text":"think"}]',
      aiTeamProposalsJson: '[{"model":"m"}]',
      groupId: 'group-1',
      version: 0,
      isStreaming: true,
    );
    final secondUser = ChatMessage(
      id: 'user-2',
      role: 'user',
      content: 'second chat',
      conversationId: 'chat-2',
      timestamp: DateTime.utc(2026, 1, 3),
    );
    final orphan = ChatMessage(
      id: 'orphan-1',
      role: 'user',
      content: 'orphan text',
      conversationId: 'missing-chat',
      timestamp: DateTime.utc(2026, 1, 4),
    );

    await conversations.put(
      'chat-1',
      Conversation(
        id: 'chat-1',
        title: 'Main',
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 2),
        messageIds: [user.id, assistant.id],
        isPinned: true,
        mcpServerIds: const ['mcp-1'],
        summary: 'summary text',
        lastSummarizedMessageCount: 2,
        truncateIndex: -1,
        compactBeforeIndex: -1,
      ),
    );
    await conversations.put(
      'chat-2',
      Conversation(id: 'chat-2', title: 'Second', messageIds: [secondUser.id]),
    );
    await messages.putAll({
      user.id: user,
      assistant.id: assistant,
      secondUser.id: secondUser,
      orphan.id: orphan,
    });

    final largeFileRead = 'x' * 8192;
    await toolEvents.put('assistant-1', <dynamic>[
      {
        'id': 'c1',
        'name': 'web_fetch',
        'arguments': {'url': 'https://example.com'},
        'content': 'PAGE',
        'approvalState': 'auto',
        'webFetchSource': 'Local',
        'customFutureKey': {'nested': true},
      },
      {
        'id': 'c2',
        'name': 'file_write',
        'arguments': {'path': 'a.txt'},
        'content': '{"requested_at":1}',
        'approvalState': 'pending',
      },
      {
        'id': 'c3',
        'name': 'file_write',
        'arguments': {'path': 'a.txt'},
        'content': '{"denied":true}',
        'approvalState': 'denied',
      },
      {
        'id': 'c4',
        'name': 'file_read',
        'arguments': {'path': 'b.txt'},
        'content': null,
        'approvalState': 'approved',
      },
      {
        'id': 'c5',
        'name': 'ask_user',
        'arguments': {'question': 'ok?'},
        'content': 'yes',
        'approvalState': 'answered',
      },
      {
        'id': 'c6',
        'name': 'file_read',
        'arguments': {'path': 'c.txt'},
        'content': null,
        'approvalState': 'auto',
      },
      {
        'id': 'c7',
        'name': 'file_read',
        'arguments': {'path': 'd.txt'},
        'content': '',
        'approvalState': 'auto',
      },
      {
        'id': 'c1',
        'name': 'web_fetch',
        'arguments': {'url': 'https://example.com/dup'},
        'content': 'DUP',
        'approvalState': 'auto',
      },
      {
        'id': 'c8',
        'name': 'file_read',
        'arguments': {'path': 'large.txt'},
        'content': largeFileRead,
        'approvalState': 'auto',
      },
      {
        'id': 'c9',
        'name': 'weird_tool',
        'arguments': 'not-a-map',
        'content': null,
        'approvalState': 'unknown-state',
      },
      'not-a-map',
    ]);
    await toolEvents.put('sig_assistant-1', 'sig-value');
    await toolEvents.put('ghost-message', [
      {
        'id': 'g1',
        'name': 'tool',
        'arguments': <String, dynamic>{},
        'content': 'ghost',
      },
    ]);
    await fileRecords.put('assistant-1', [
      {
        'path': '/files/notes.md',
        'fileName': 'notes.md',
        'sizeBytes': 3,
        'createdAt': DateTime.utc(2026, 1, 1).toIso8601String(),
      },
      {
        'path': '/files/notes.md',
        'fileName': 'notes.md',
        'sizeBytes': 3,
        'createdAt': DateTime.utc(2026, 1, 1).toIso8601String(),
      },
      {
        'path': '/files/report.pdf',
        'fileName': 'report.pdf',
        'sizeBytes': 10,
        'createdAt': DateTime.utc(2026, 1, 1).toIso8601String(),
      },
    ]);
    await workspaceV2.put('chat-1', const {'mode': 'custom', 'path': 'C:/ws'});
    await workspaceV1.put('chat-1', 'C:/legacy-ignored');
    await workspaceV1.put('chat-2', 'C:/legacy-2');

    await Hive.close();
  }

  LegacyHiveImporter importer({int? seed}) {
    return LegacyHiveImporter(
      hiveDirectory: directory,
      files: files,
      appVersion: 'test',
      validationSeed: seed ?? 7,
      backupChoice: 'skipped',
    );
  }

  test(
    'imports conversations, parts, artifacts, records and workspaces',
    () async {
      await writeFullLegacyData();

      final result = await importer().run();
      expect(result.state, 'complete_with_issues');
      expect(result.quarantineCount, 2);
      expect(result.validationMode, 'full');
      expect(await files.database.exists(), isTrue);
      expect(await files.migrationReceipt.exists(), isTrue);

      final probe = await probeDatabase(files.database);
      expect(probe.source, 'hive');
      expect(probe.state, 'complete_with_issues');
      expect(probe.userVersion, 1);
      expect(probe.publishId, isNotEmpty);
      expect(probe.migrationComplete, isTrue);

      final db = AppDatabase.open(files.database, background: false);
      final repo = ChatRepository(db);
      try {
        final counts = await repo.counts();
        expect(counts.conversations, 3);
        expect(counts.messages, 4);
        expect(counts.parts, 10);
        expect(counts.providerArtifacts, 1);
        expect(counts.fileRecords, 2);
        expect(counts.workspaceBindings, 2);
        expect(counts.quarantined, 2);

        final conversations = await repo.listConversations();
        final main = conversations.firstWhere((c) => c.id == 'chat-1');
        expect(main.title, 'Main');
        expect(main.messageIds, ['user-1', 'assistant-1']);
        expect(main.isPinned, isTrue);
        expect(main.summary, 'summary text');
        expect(main.mcpServerIds, ['mcp-1']);
        expect(
          main.updatedAt.millisecondsSinceEpoch,
          DateTime.utc(2026, 1, 2).millisecondsSinceEpoch,
        );

        final messages = await repo.getMessages('chat-1');
        expect(messages.first.content, 'hello 😀');
        final assistant = messages.last;
        expect(assistant.isStreaming, isFalse);
        expect(assistant.reasoningText, 'think');
        expect(assistant.modelId, 'model-1');
        expect(assistant.totalTokens, 12);
        expect(assistant.processStartedAt, isNotNull);
        expect(assistant.translation, 'translated');
        expect(assistant.reasoningSegmentsJson, '[{"text":"think"}]');
        expect(assistant.aiTeamProposalsJson, '[{"model":"m"}]');

        final parts = await repo.partsForMessage('assistant-1');
        expect(parts, hasLength(10));
        expect(parts.map((p) => p.ordinal), List.generate(10, (i) => i));
        expect(parts[0].toolCallId, 'c1');
        expect(parts[0].content, 'PAGE');
        expect(parts[0].status, kPartStatusCompleted);
        expect(parts[0].metadataJson, contains('webFetchSource'));
        expect(parts[0].metadataJson, contains('customFutureKey'));
        expect(parts[1].status, kPartStatusPending);
        expect(parts[1].approvalState, kApprovalPending);
        expect(parts[1].content, '{"requested_at":1}');
        expect(parts[2].status, kPartStatusDenied);
        expect(parts[3].status, kPartStatusInterrupted);
        expect(parts[4].status, kPartStatusCompleted);
        expect(parts[5].status, kPartStatusInterrupted);
        expect(parts[6].status, kPartStatusCompleted);
        expect(parts[6].content, '');
        expect(parts[7].toolCallId, 'c1');
        expect(parts[7].content, 'DUP');
        expect(parts[8].content, hasLength(8192));
        expect(parts[9].approvalState, kApprovalAuto);
        expect(parts[9].status, kPartStatusInterrupted);
        expect(parts[9].metadataJson, contains('legacyArguments'));

        expect(
          await repo.getProviderArtifact(
            'assistant-1',
            kGeminiThoughtSignatureKind,
          ),
          'sig-value',
        );
        final records = await repo.getFileRecords('assistant-1');
        expect(records.map((r) => r.path), [
          '/files/notes.md',
          '/files/report.pdf',
        ]);

        expect((await repo.getWorkspaceBinding('chat-1'))?.path, 'C:/ws');
        expect((await repo.getWorkspaceBinding('chat-2'))?.path, 'C:/legacy-2');

        final recoveredRows = await db.select(db.conversationRows).get();
        final recovered = recoveredRows.firstWhere(
          (row) => row.id == 'missing-chat',
        );
        expect(recovered.isRecovered, isTrue);
        expect(recovered.title, 'Recovered messages');
        final recoveredMessages = await repo.getMessages('missing-chat');
        expect(recoveredMessages.single.content, 'orphan text');

        // Tool event replay shape is preserved for model/facade callers.
        final events = await repo.getToolEvents('assistant-1');
        expect(events, hasLength(10));
        expect(events.first['arguments'], {'url': 'https://example.com'});
        expect(events.first['webFetchSource'], 'Local');
        expect(events.first['content'], 'PAGE');
      } finally {
        await db.close();
      }

      // Hive is retained untouched.
      expect(
        await File('${directory.path}/conversations.hive').exists(),
        isTrue,
      );
      expect(
        await File('${directory.path}/tool_events_v1.hive').exists(),
        isTrue,
      );
    },
  );

  test('invalid indices fail validation without publishing', () async {
    final conversations = await Hive.openBox<Conversation>(
      'conversations',
      path: directory.path,
    );
    final messages = await Hive.openBox<ChatMessage>(
      'messages',
      path: directory.path,
    );
    final conversation = Conversation(
      id: 'chat-bad',
      title: 'Bad',
      messageIds: const ['u'],
      truncateIndex: 99,
    );
    final user = ChatMessage(
      id: 'u',
      role: 'user',
      content: 'hi',
      conversationId: 'chat-bad',
    );
    await conversations.put(conversation.id, conversation);
    await messages.put(user.id, user);
    await Hive.close();

    await expectLater(
      importer().run(),
      throwsA(
        isA<LegacyMigrationException>().having(
          (e) => e.validationFailures.join(' '),
          'validation failures',
          contains('invalid truncate/compact indices'),
        ),
      ),
    );
    expect(await files.database.exists(), isFalse);
    expect(await files.migrating.exists(), isTrue);
    expect(await File('${directory.path}/conversations.hive').exists(), isTrue);
  });

  test('a second import refuses to overwrite a published database', () async {
    final conversations = await Hive.openBox<Conversation>(
      'conversations',
      path: directory.path,
    );
    final messages = await Hive.openBox<ChatMessage>(
      'messages',
      path: directory.path,
    );
    final conversation = Conversation(
      id: 'chat-1',
      title: 'Only',
      messageIds: const ['u'],
    );
    final user = ChatMessage(
      id: 'u',
      role: 'user',
      content: 'hi',
      conversationId: 'chat-1',
    );
    await conversations.put(conversation.id, conversation);
    await messages.put(user.id, user);
    await Hive.close();

    final first = await importer().run();
    final firstPublishId = first.targetProbe.publishId;
    expect(first.state, 'complete_clean');

    await expectLater(
      importer().run(),
      throwsA(
        isA<LegacyMigrationException>().having(
          (e) => e.message,
          'message',
          contains('refusing to import Hive'),
        ),
      ),
    );
    final probe = await probeDatabase(files.database);
    expect(probe.publishId, firstPublishId);
  });

  test(
    'a stale temp database is discarded and import restarts from Hive',
    () async {
      final conversations = await Hive.openBox<Conversation>(
        'conversations',
        path: directory.path,
      );
      final messages = await Hive.openBox<ChatMessage>(
        'messages',
        path: directory.path,
      );
      final conversation = Conversation(
        id: 'chat-1',
        title: 'Only',
        messageIds: const ['u'],
      );
      final user = ChatMessage(
        id: 'u',
        role: 'user',
        content: 'hi',
        conversationId: 'chat-1',
      );
      await conversations.put(conversation.id, conversation);
      await messages.put(user.id, user);
      await Hive.close();

      await files.migrating.writeAsBytes(
        List<int>.generate(1024, (i) => i % 251),
      );

      final result = await importer().run();
      expect(result.state, 'complete_clean');
      expect(await files.migrating.exists(), isFalse);
      expect(await files.database.exists(), isTrue);
    },
  );

  test(
    'a corrupt Hive box fails once and leaks no uncaught async error',
    () async {
      await Hive.close();
      final corrupt = File(
        '${directory.path}${Platform.pathSeparator}messages.hive',
      );
      await corrupt.writeAsBytes(<int>[0xff, 0x00, 0x13, 0x37, 0x42]);

      final uncaught = <Object>[];
      Object? failure;
      await runZonedGuarded(() async {
        try {
          await importer().run();
        } catch (error) {
          failure = error;
        }
      }, (error, stackTrace) => uncaught.add(error));
      // Give Hive's internal open completer one turn to surface any duplicate.
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(failure, isA<LegacyMigrationException>());
      expect(
        (failure! as LegacyMigrationException).message,
        contains('Cannot open Hive box messages'),
      );
      expect(uncaught, isEmpty);
      expect(await files.database.exists(), isFalse);
      expect(await corrupt.length(), 5);
    },
  );
}
