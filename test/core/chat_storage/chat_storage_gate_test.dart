import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:OmniChat/core/models/chat_message.dart';
import 'package:OmniChat/core/models/conversation.dart';
import 'package:OmniChat/core/services/chat/storage/app_database.dart';
import 'package:OmniChat/core/services/chat/storage/chat_database_files.dart';
import 'package:OmniChat/core/services/chat/storage/chat_repository.dart';
import 'package:OmniChat/core/services/chat/storage/chat_storage_gate.dart';

void main() {
  late Directory directory;
  late ChatDatabaseFiles files;

  setUp(() async {
    await Hive.close();
    directory = await Directory.systemTemp.createTemp('omnichat_storage_gate_');
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

  ChatStorageGate gate() =>
      ChatStorageGate(directory: directory, appVersion: 'test');

  test('fresh install is ready without migration', () async {
    final result = await gate().ensureReady();
    expect(result.stage, ChatStorageGateStage.ready);
    expect(result.sqliteReady, isTrue);
    expect(result.migration, isNull);
  });

  test('Hive-only data is migrated and admitted', () async {
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

    final result = await gate().ensureReady();
    expect(result.stage, ChatStorageGateStage.migrated);
    expect(result.sqliteReady, isTrue);
    expect(result.migration?.state, 'complete_clean');
    expect(await files.installationReceipt.exists(), isTrue);
    expect(await files.migrationReceipt.exists(), isTrue);

    final db = AppDatabase.open(files.database, background: false);
    try {
      final counts = await ChatRepository(db).counts();
      expect(counts.conversations, 1);
      expect(counts.messages, 1);
    } finally {
      await db.close();
    }
  });

  test('a pre-migration backup is created before Hive is imported', () async {
    final conversations = await Hive.openBox<Conversation>(
      'conversations',
      path: directory.path,
    );
    final messages = await Hive.openBox<ChatMessage>(
      'messages',
      path: directory.path,
    );
    await conversations.put(
      'chat-1',
      Conversation(id: 'chat-1', title: 'Only', messageIds: const ['u']),
    );
    await messages.put(
      'u',
      ChatMessage(
        id: 'u',
        role: 'user',
        content: 'hi',
        conversationId: 'chat-1',
      ),
    );
    await Hive.close();

    final backupDirectory = await Directory.systemTemp.createTemp(
      'omnichat_pre_migration_backup_',
    );
    addTearDown(() async {
      if (await backupDirectory.exists()) {
        await backupDirectory.delete(recursive: true);
      }
    });
    var prompted = 0;

    final result = await ChatStorageGate(
      directory: directory,
      appVersion: 'test',
      backupPrompt: () async {
        prompted++;
        return ChatMigrationBackupDecision.backup(backupDirectory);
      },
    ).ensureReady();

    expect(prompted, 1);
    expect(result.stage, ChatStorageGateStage.migrated);
    expect(result.sqliteReady, isTrue);
    expect(result.migration?.receipt['backup'], 'completed');
    final artifact = result.migration?.receipt['backupArtifact'] as String?;
    expect(artifact, isNotNull);
    expect(await File(artifact!).exists(), isTrue);
    expect(await backupDirectory.list().length, 1);
  });

  test('an explicit skip is recorded before migration', () async {
    final conversations = await Hive.openBox<Conversation>(
      'conversations',
      path: directory.path,
    );
    await conversations.put(
      'chat-1',
      Conversation(id: 'chat-1', title: 'Only', messageIds: const []),
    );
    await Hive.close();

    final result = await ChatStorageGate(
      directory: directory,
      appVersion: 'test',
      backupPrompt: () async => const ChatMigrationBackupDecision.skip(),
      requireBackupPrompt: true,
    ).ensureReady();

    expect(result.stage, ChatStorageGateStage.migrated);
    expect(result.migration?.receipt['backup'], 'skipped');
    expect(result.migration?.receipt['backupArtifact'], isNull);
  });

  test('cancelling the backup aborts before the temp database', () async {
    final conversations = await Hive.openBox<Conversation>(
      'conversations',
      path: directory.path,
    );
    await conversations.put(
      'chat-1',
      Conversation(id: 'chat-1', title: 'Only', messageIds: const []),
    );
    await Hive.close();

    final result = await ChatStorageGate(
      directory: directory,
      appVersion: 'test',
      backupPrompt: () async => const ChatMigrationBackupDecision.cancel(),
      requireBackupPrompt: true,
    ).ensureReady();

    expect(result.stage, ChatStorageGateStage.failed);
    expect(await files.database.exists(), isFalse);
    expect(await files.migrating.exists(), isFalse);
    expect(await File('${directory.path}/conversations.hive').exists(), isTrue);
  });

  test(
    'production gates refuse to migrate without a backup decision',
    () async {
      final conversations = await Hive.openBox<Conversation>(
        'conversations',
        path: directory.path,
      );
      await conversations.put(
        'chat-1',
        Conversation(id: 'chat-1', title: 'Only', messageIds: const []),
      );
      await Hive.close();

      final result = await ChatStorageGate(
        directory: directory,
        appVersion: 'test',
        requireBackupPrompt: true,
      ).ensureReady();

      expect(result.stage, ChatStorageGateStage.failed);
      expect(result.message, contains('backup decision is required'));
      expect(await files.database.exists(), isFalse);
    },
  );

  test('a validation failure stays on Hive and does not publish', () async {
    final conversations = await Hive.openBox<Conversation>(
      'conversations',
      path: directory.path,
    );
    await conversations.put(
      'chat-bad',
      Conversation(
        id: 'chat-bad',
        title: 'Bad',
        messageIds: const ['missing'],
        truncateIndex: 50,
      ),
    );
    await Hive.close();

    final result = await gate().ensureReady();
    expect(result.stage, ChatStorageGateStage.failed);
    expect(result.sqliteReady, isFalse);
    expect(await files.database.exists(), isFalse);
    expect(await File('${directory.path}/conversations.hive').exists(), isTrue);
  });
}
