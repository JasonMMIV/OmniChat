import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;

import 'package:OmniChat/core/models/chat_message.dart';
import 'package:OmniChat/core/models/conversation.dart';
import 'package:OmniChat/core/models/file_record.dart';
import 'package:OmniChat/core/models/workspace_config.dart';
import 'package:OmniChat/core/services/chat/storage/chat_database_files.dart';
import 'package:OmniChat/core/services/chat/storage/pre_migration_backup_service.dart';

void main() {
  late Directory directory;
  late Directory destination;

  setUp(() async {
    await Hive.close();
    directory = await Directory.systemTemp.createTemp('omnichat_backup_src_');
    destination = await Directory.systemTemp.createTemp('omnichat_backup_dst_');
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
    for (final dir in <Directory>[directory, destination]) {
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  });

  Future<void> writeLegacyData() async {
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

    final conversation = Conversation(
      id: 'chat-1',
      title: 'Backup me',
      messageIds: const ['u', 'a'],
    );
    final user = ChatMessage(
      id: 'u',
      role: 'user',
      content: 'hello',
      conversationId: 'chat-1',
    );
    final assistant = ChatMessage(
      id: 'a',
      role: 'assistant',
      content: 'world',
      conversationId: 'chat-1',
    );
    await conversations.put(conversation.id, conversation);
    await messages.putAll(<String, ChatMessage>{
      user.id: user,
      assistant.id: assistant,
    });
    await toolEvents.put('a', <dynamic>[
      <String, dynamic>{
        'id': 'call-1',
        'name': 'file_read',
        'arguments': <String, dynamic>{'path': 'a.txt'},
        'content': 'body',
      },
    ]);
    await fileRecords.put('a', <dynamic>[
      FileRecord(
        path: '/tmp/a.txt',
        fileName: 'a.txt',
        sizeBytes: 4,
        createdAt: DateTime.utc(2026, 1, 1),
      ).toJson(),
    ]);
    await workspaceBindings.put(
      'chat-1',
      WorkspaceConfig.custom('/tmp/workspace').toJson(),
    );
    await Hive.close();
  }

  test(
    'writes raw Hive files, streamed chats.json, manifest and hashes',
    () async {
      await writeLegacyData();
      final sourceHash = sha256
          .convert(
            await File(p.join(directory.path, 'messages.hive')).readAsBytes(),
          )
          .toString();

      final service = PreMigrationBackupService(
        directory: directory,
        appVersion: '1.2.3',
      );
      final result = await service.create(destination: destination);

      expect(await result.archive.exists(), isTrue);
      expect(result.sourceBytes, greaterThan(0));
      expect(result.manifest['format'], 'omnichat.pre-migration-backup');
      expect(result.manifest['appVersion'], '1.2.3');

      final archive = ZipDecoder().decodeBytes(
        await result.archive.readAsBytes(),
      );
      final names = archive.files.map((f) => f.name).toSet();
      expect(names, contains('hive/messages.hive'));
      expect(names, contains('hive/conversations.hive'));
      expect(names, contains('chats.json'));
      expect(names, contains('manifest.json'));

      final chatJson =
          jsonDecode(utf8.decode(archive.find('chats.json')!.content))
              as Map<String, dynamic>;
      expect(chatJson['version'], 3);
      expect((chatJson['conversations'] as List), hasLength(1));
      expect((chatJson['messages'] as List), hasLength(2));
      expect((chatJson['toolEvents'] as Map)['a'], hasLength(1));
      expect((chatJson['fileRecords'] as Map)['a'], hasLength(1));
      expect((chatJson['workspaces'] as Map)['chat-1'], '/tmp/workspace');

      final manifest =
          jsonDecode(utf8.decode(archive.find('manifest.json')!.content))
              as Map<String, dynamic>;
      final artifacts = (manifest['artifacts'] as List).cast<Map>();
      final messagesArtifact = artifacts.singleWhere(
        (artifact) => artifact['name'] == 'messages.hive',
      );
      expect(messagesArtifact['sha256'], sourceHash);
      expect((manifest['chatCounts'] as Map)['messages'], 2);

      // The original Hive source must stay byte-identical.
      expect(
        await File(p.join(directory.path, 'messages.hive')).readAsBytes(),
        isNotEmpty,
      );
      expect(
        sha256
            .convert(
              await File(p.join(directory.path, 'messages.hive')).readAsBytes(),
            )
            .toString(),
        sourceHash,
      );
      expect(await ChatDatabaseFiles(directory).database.exists(), isFalse);
    },
  );

  test('a conversation with no messages is a valid backup', () async {
    final conversations = await Hive.openBox<Conversation>(
      'conversations',
      path: directory.path,
    );
    await conversations.put(
      'empty-chat',
      Conversation(id: 'empty-chat', title: 'Empty', messageIds: const []),
    );
    await Hive.close();

    final service = PreMigrationBackupService(
      directory: directory,
      appVersion: '1.2.3',
    );
    final result = await service.create(destination: destination);
    expect(await result.archive.exists(), isTrue);
    expect((result.manifest['chatCounts'] as Map)['messages'], 0);
    expect((result.manifest['chatCounts'] as Map)['conversations'], 1);
  });

  test('refuses to export while the live chat boxes are open', () async {
    await writeLegacyData();
    final liveBox = await Hive.openBox<Conversation>(
      'conversations',
      path: directory.path,
    );
    final source = File(p.join(directory.path, 'messages.hive'));
    final before = sha256.convert(await source.readAsBytes()).toString();

    final service = PreMigrationBackupService(
      directory: directory,
      appVersion: '1.2.3',
    );
    await expectLater(
      service.create(destination: destination),
      throwsA(
        isA<PreMigrationBackupException>().having(
          (e) => e.message,
          'message',
          contains('currently open'),
        ),
      ),
    );

    expect(sha256.convert(await source.readAsBytes()).toString(), before);
    expect(await destination.list().isEmpty, isTrue);
    await liveBox.close();
  });

  test('refuses to create an archive without legacy chat files', () async {
    await Hive.close();
    final service = PreMigrationBackupService(
      directory: directory,
      appVersion: '1.2.3',
    );
    await expectLater(
      service.create(destination: destination),
      throwsA(isA<PreMigrationBackupException>()),
    );
    expect(await destination.list().isEmpty, isTrue);
  });
}
