import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:OmniChat/core/models/chat_message.dart';
import 'package:OmniChat/core/models/conversation.dart';
import 'package:OmniChat/core/models/file_record.dart';
import 'package:OmniChat/core/models/workspace_config.dart';
import 'package:OmniChat/core/services/chat/storage/chat_database_files.dart';
import 'package:OmniChat/core/services/chat/storage/database_installation_gate.dart';
import 'package:OmniChat/core/services/chat/storage/legacy_reimport_service.dart';
import 'package:OmniChat/core/services/chat/storage/sqlite_chat_storage.dart';

void main() {
  late Directory directory;
  late ChatDatabaseFiles files;
  late SqliteChatStorage storage;

  setUpAll(() {
    // The destination and the staging database are deliberately different
    // AppDatabase instances (different files) in this test.
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });

  tearDownAll(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = false;
  });

  setUp(() async {
    await Hive.close();
    directory = await Directory.systemTemp.createTemp('omnichat_reimport_');
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
    try {
      await storage.dispose();
    } catch (_) {}
    await Hive.close();
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  test(
    'merges missing conversations/messages and keeps existing conflicts',
    () async {
      // Create a fresh live SQLite database with one existing conversation.
      await DatabaseInstallationGate(
        directory: directory,
        appVersion: 'test',
      ).ensureReady();
      storage = SqliteChatStorage(directory: directory, appVersion: 'test');
      await storage.initialize();

      final live = Conversation(
        id: 'live-1',
        title: 'Existing chat',
        messageIds: const ['live-u', 'live-a'],
      );
      await storage.putConversation(live);
      await storage.appendMessage(
        ChatMessage(
          id: 'live-u',
          role: 'user',
          content: 'same prompt',
          conversationId: 'live-1',
        ),
      );
      await storage.appendMessage(
        ChatMessage(
          id: 'live-a',
          role: 'assistant',
          content: 'newer answer',
          conversationId: 'live-1',
        ),
      );
      await storage.dispose();

      // Write a legacy Hive snapshot that overlaps live-a and adds new rows.
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
      final workspaceBindings = await Hive.openBox(
        'conversation_workspace_bindings_v2',
        path: directory.path,
      );

      await conversations.putAll(<String, Conversation>{
        'live-1': Conversation(
          id: 'live-1',
          title: 'Legacy copy',
          messageIds: const ['live-u', 'live-a', 'legacy-extra'],
        ),
        'legacy-1': Conversation(
          id: 'legacy-1',
          title: 'Legacy only',
          messageIds: const ['legacy-u', 'legacy-a'],
        ),
      });
      await messages.putAll(<String, ChatMessage>{
        'live-u': ChatMessage(
          id: 'live-u',
          role: 'user',
          content: 'same prompt',
          conversationId: 'live-1',
        ),
        'live-a': ChatMessage(
          id: 'live-a',
          role: 'assistant',
          content: 'older answer',
          conversationId: 'live-1',
        ),
        'legacy-extra': ChatMessage(
          id: 'legacy-extra',
          role: 'user',
          content: 'message added by legacy',
          conversationId: 'live-1',
        ),
        'legacy-u': ChatMessage(
          id: 'legacy-u',
          role: 'user',
          content: 'legacy question',
          conversationId: 'legacy-1',
        ),
        'legacy-a': ChatMessage(
          id: 'legacy-a',
          role: 'assistant',
          content: 'legacy answer',
          conversationId: 'legacy-1',
        ),
      });
      await toolEvents.put('legacy-a', <dynamic>[
        <String, dynamic>{
          'id': 'call-1',
          'name': 'file_read',
          'arguments': <String, dynamic>{'path': 'legacy.txt'},
          'content': 'legacy tool result',
        },
      ]);
      await toolEvents.put('sig_legacy-a', 'legacy-signature');
      await fileRecords.put('legacy-a', <dynamic>[
        FileRecord(
          path: '/tmp/legacy.txt',
          fileName: 'legacy.txt',
          sizeBytes: 12,
          createdAt: DateTime.utc(2026, 1, 1),
        ).toJson(),
      ]);
      await workspaceBindings.put(
        'legacy-1',
        WorkspaceConfig.custom('/tmp/legacy-workspace').toJson(),
      );
      await Hive.close();

      await files.writeJsonAtomically(
        files.legacyImportDisabled,
        <String, dynamic>{'format': 1},
      );
      final hiveBytesBefore = await File(
        '${directory.path}/messages.hive',
      ).readAsBytes();

      storage = SqliteChatStorage(directory: directory, appVersion: 'test');
      await storage.initialize();
      final report = await LegacyReimportService(
        directory: directory,
        appVersion: 'test',
        destination: storage,
      ).run();

      expect(report.importedConversations, 1);
      expect(report.importedMessages, 3);
      expect(report.existingMessages, 2);
      expect(report.conflicts, 1);
      expect(report.sentinelRemoved, isTrue);
      expect(await files.legacyImportDisabled.exists(), isFalse);

      expect(storage.getConversation('legacy-1')?.title, 'Legacy only');
      await storage.ensureConversationLoaded('legacy-1');
      await storage.ensureConversationLoaded('live-1');
      expect(storage.getMessages('legacy-1'), hasLength(2));
      expect(storage.getMessages('live-1'), hasLength(3));
      expect(
        storage
            .getMessages('live-1')
            .firstWhere((m) => m.id == 'live-a')
            .content,
        'newer answer',
      );
      expect(
        storage
            .getMessages('live-1')
            .firstWhere((m) => m.id == 'legacy-extra')
            .content,
        'message added by legacy',
      );

      await storage.ensureToolEventsLoaded(['legacy-a']);
      final event = storage.getToolEvents('legacy-a').single;
      expect(event['id'], 'call-1');
      expect(storage.getGeminiThoughtSignature('legacy-a'), 'legacy-signature');
      expect(storage.getFileRecords('legacy-a').single.fileName, 'legacy.txt');
      expect(
        storage.getWorkspaceConfig('legacy-1')?.path,
        '/tmp/legacy-workspace',
      );

      expect(
        await File('${directory.path}/messages.hive').readAsBytes(),
        hiveBytesBefore,
      );

      // The merge is idempotent: a second run adds nothing and keeps conflicts
      // as existing data.
      final second = await LegacyReimportService(
        directory: directory,
        appVersion: 'test',
        destination: storage,
      ).run();
      expect(second.importedConversations, 0);
      expect(second.importedMessages, 0);
      expect(second.existingConversations, 2);
      expect(second.existingMessages, 5);
      expect(second.conflicts, 1);
      expect(second.sentinelRemoved, isFalse);
    },
  );
}
