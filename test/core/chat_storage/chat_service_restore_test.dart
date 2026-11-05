import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/models/chat_message.dart';
import 'package:OmniChat/core/models/conversation.dart';
import 'package:OmniChat/core/services/chat/chat_service.dart';
import 'package:OmniChat/core/services/chat/storage/chat_backup_restorer.dart';
import 'package:OmniChat/core/services/chat/storage/chat_database_files.dart';
import 'package:OmniChat/core/services/chat/storage/chat_storage_startup_status.dart';
import 'package:OmniChat/core/services/chat/storage/database_family_publisher.dart';
import 'package:OmniChat/core/services/chat/storage/file_restore_stager.dart';
import 'package:OmniChat/core/services/chat/storage/settings_snapshot.dart';
import 'package:OmniChat/core/services/chat/storage/restore_journal.dart';

Future<File> writeArchive(
  Directory directory,
  List<Conversation> conversations,
  List<ChatMessage> messages, {
  Map<String, dynamic>? settings,
  Map<String, String> files = const <String, String>{},
}) async {
  final archive = Archive();
  final chatsBytes = utf8.encode(
    jsonEncode(<String, dynamic>{
      'version': 3,
      'conversations': conversations.map((c) => c.toJson()).toList(),
      'messages': messages.map((m) => m.toJson()).toList(),
      'toolEvents': <String, dynamic>{},
      'geminiThoughtSigs': <String, dynamic>{},
      'workspaceBindings': <String, dynamic>{},
      'fileRecords': <String, dynamic>{},
    }),
  );
  archive.addFile(ArchiveFile('chats.json', chatsBytes.length, chatsBytes));
  if (settings != null) {
    final settingsBytes = utf8.encode(jsonEncode(settings));
    archive.addFile(
      ArchiveFile('settings.json', settingsBytes.length, settingsBytes),
    );
  }
  for (final entry in files.entries) {
    final fileBytes = utf8.encode(entry.value);
    archive.addFile(ArchiveFile(entry.key, fileBytes.length, fileBytes));
  }
  final bytes = ZipEncoder().encode(archive)!;
  final file = File('${directory.path}/restore_input.zip');
  await file.writeAsBytes(bytes);
  return file;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() async {
    ChatBackupRestorer.debugFailAfterConversations = 0;
    FileRestoreStager.debugFailOnFileCopy = false;
    SettingsSnapshot.debugFailOnApply = false;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await Hive.close();
    directory = await Directory.systemTemp.createTemp(
      'omnichat_chat_restore_',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
          if (call.method == 'getApplicationSupportDirectory' ||
              call.method == 'getApplicationDocumentsDirectory') {
            return directory.path;
          }
          return null;
        });
    if (!Hive.isAdapterRegistered(0)) {
      Hive.registerAdapter(ChatMessageAdapter());
    }
    if (!Hive.isAdapterRegistered(1)) {
      Hive.registerAdapter(ConversationAdapter());
    }
    Hive.init(directory.path);
  });

  tearDown(() async {
    ChatBackupRestorer.debugFailAfterConversations = 0;
    ChatBackupRestorer.debugAfterPublishFailure = null;
    DatabaseFamilyPublisher.debugFailOnPublish = false;
    DatabaseFamilyPublisher.debugForceFailClosedRecovery = false;
    FileRestoreStager.debugFailOnFileCopy = false;
    SettingsSnapshot.debugFailOnApply = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    await Hive.close();
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  Future<ChatService> readyService() async {
    final service = ChatService();
    addTearDown(service.close);
    await service.init();
    return service;
  }

  Future<void> seed(ChatService service) async {
    await service.restoreConversation(
      Conversation(id: 'keep', title: 'Keep me'),
      <ChatMessage>[
        ChatMessage(
          id: 'keep-message',
          role: 'user',
          content: 'existing content',
          conversationId: 'keep',
        ),
      ],
    );
  }

  test('restore publishes a staging database and keeps the receipt identity',
      () async {
    final service = await readyService();
    await seed(service);
    final files = ChatDatabaseFiles(directory);
    final receiptBefore = await files.readJson(files.installationReceipt);
    expect(receiptBefore, isNotNull);

    final archive = await writeArchive(
      directory,
      <Conversation>[
        Conversation(id: 'c1', title: 'One'),
        Conversation(id: 'c2', title: 'Two'),
      ],
      <ChatMessage>[
        ChatMessage(
          id: 'm1',
          role: 'user',
          content: 'hello',
          conversationId: 'c1',
        ),
        ChatMessage(
          id: 'm2',
          role: 'assistant',
          content: 'world',
          conversationId: 'c2',
        ),
      ],
    );

    final result = await service.restoreChatBackup(archive);

    expect(result.restoredConversations, 2);
    expect(result.restoredMessages, 2);
    expect(result.filesRestored, isFalse);
    expect(result.settingsApplied, isTrue);
    expect(service.storageInitStatus.phase, ChatStorageInitPhase.ready);
    expect(service.backend, isNotNull);
    expect(
      service.getAllConversations().map((conversation) => conversation.id),
      containsAll(<String>['c1', 'c2']),
    );
    expect(
      service.getAllConversations().map((conversation) => conversation.id),
      isNot(contains('keep')),
    );
    await service.ensureConversationLoaded('c1');
    expect(service.getMessages('c1').single.content, 'hello');

    final receiptAfter = await files.readJson(files.installationReceipt);
    expect(
      receiptAfter!['databaseId'],
      receiptBefore!['databaseId'],
      reason: 'the installation receipt and database identity must agree',
    );
    expect(await files.restoreJournal.exists(), isFalse);
    expect(await files.restoring.exists(), isFalse);
    expect(await files.previous.exists(), isFalse);
  });

  test('a failed staging import leaves the live chats untouched', () async {
    final service = await readyService();
    await seed(service);
    final files = ChatDatabaseFiles(directory);
    final before = await probeDatabase(files.database);

    final archive = await writeArchive(
      directory,
      <Conversation>[
        Conversation(id: 'c1', title: 'One'),
        Conversation(id: 'c2', title: 'Two'),
      ],
      <ChatMessage>[
        ChatMessage(
          id: 'm1',
          role: 'user',
          content: 'hello',
          conversationId: 'c1',
        ),
        ChatMessage(
          id: 'm2',
          role: 'user',
          content: 'world',
          conversationId: 'c2',
        ),
      ],
    );
    ChatBackupRestorer.debugFailAfterConversations = 1;

    await expectLater(
      service.restoreChatBackup(archive),
      throwsA(isA<ChatRestoreException>()),
    );

    expect(service.initialized, isTrue);
    expect(
      service.getAllConversations().map((conversation) => conversation.id),
      <String>['keep'],
    );
    expect(service.getMessages('keep').single.content, 'existing content');
    expect(await files.restoreJournal.exists(), isFalse);
    expect(await files.restoring.exists(), isFalse);
    final after = await probeDatabase(files.database);
    expect(after.databaseId, before.databaseId);
    expect(after.publishId, before.publishId);
  });

  test('an unresolved publish keeps the journal and every recovery file',
      () async {
    final service = await readyService();
    await seed(service);
    final files = ChatDatabaseFiles(directory);
    final archive = await writeArchive(
      directory,
      <Conversation>[Conversation(id: 'c1', title: 'One')],
      <ChatMessage>[
        ChatMessage(
          id: 'm1',
          role: 'user',
          content: 'hello',
          conversationId: 'c1',
        ),
      ],
    );
    DatabaseFamilyPublisher.debugFailOnPublish = true;
    ChatBackupRestorer.debugAfterPublishFailure = () {
      DatabaseFamilyPublisher.debugForceFailClosedRecovery = true;
    };

    await expectLater(
      service.restoreChatBackup(archive),
      throwsA(isA<ChatRestoreException>()),
    );

    expect(await files.restoreJournal.exists(), isTrue);
    expect(await files.publishIntent.exists(), isTrue);
    expect(await files.restoring.exists(), isTrue);
    expect(await files.previous.exists(), isTrue);
    final journal = (await RestoreJournal.read(files))!;
    expect(journal.stage, RestoreJournal.stagePublishUnresolved);
    expect(service.storageInitStatus.phase, ChatStorageInitPhase.failed);
    expect(service.initialized, isFalse);
  });

  test('a file copy failure keeps the live uploads and database', () async {
    final service = await readyService();
    await seed(service);
    final files = ChatDatabaseFiles(directory);
    final before = await probeDatabase(files.database);
    final liveUpload = Directory('${directory.path}/upload');
    await liveUpload.create(recursive: true);
    final localUpload = File('${liveUpload.path}/local.txt');
    await localUpload.writeAsString('local-only');
    final archive = await writeArchive(
      directory,
      <Conversation>[Conversation(id: 'c1', title: 'One')],
      <ChatMessage>[
        ChatMessage(
          id: 'm1',
          role: 'user',
          content: 'hello',
          conversationId: 'c1',
        ),
      ],
      files: <String, String>{'upload/from-backup.txt': 'restored'},
    );
    FileRestoreStager.debugFailOnFileCopy = true;

    await expectLater(
      service.restoreChatBackup(archive, includeFiles: true),
      throwsA(isA<ChatRestoreException>()),
    );

    expect(await localUpload.readAsString(), 'local-only');
    expect(
      await File('${liveUpload.path}/from-backup.txt').exists(),
      isFalse,
    );
    expect(await files.restoreJournal.exists(), isFalse);
    expect(await files.restoring.exists(), isFalse);
    final after = await probeDatabase(files.database);
    expect(after.publishId, before.publishId);
    expect(service.getAllConversations().single.id, 'keep');
  });

  test('a settings failure is partial success without rolling back chats',
      () async {
    final service = await readyService();
    await seed(service);
    final files = ChatDatabaseFiles(directory);
    final archive = await writeArchive(
      directory,
      <Conversation>[Conversation(id: 'c1', title: 'One')],
      <ChatMessage>[
        ChatMessage(
          id: 'm1',
          role: 'user',
          content: 'hello',
          conversationId: 'c1',
        ),
      ],
      settings: <String, dynamic>{'restored_key': 'restored_value'},
    );
    SettingsSnapshot.debugFailOnApply = true;

    final result = await service.restoreChatBackup(
      archive,
      restoreSettings: true,
    );

    expect(result.settingsApplied, isFalse);
    expect(result.settingsError, contains('settings'));
    expect(service.getAllConversations().single.id, 'c1');
    expect(await files.restoreSettingsPending.exists(), isTrue);
    expect(await files.restoreSettingsSnapshot.exists(), isFalse);
    expect(await files.restoreJournal.exists(), isFalse);
  });

  test('a corrupt archive never touches the live database', () async {
    final service = await readyService();
    await seed(service);
    final files = ChatDatabaseFiles(directory);
    final before = await probeDatabase(files.database);
    final corrupt = File('${directory.path}/corrupt.zip');
    await corrupt.writeAsBytes(List<int>.filled(256, 9));

    await expectLater(
      service.restoreChatBackup(corrupt),
      throwsA(isA<ChatRestoreException>()),
    );

    expect(service.initialized, isTrue);
    expect(
      service.getAllConversations().map((conversation) => conversation.id),
      <String>['keep'],
    );
    expect(await files.restoreJournal.exists(), isFalse);
    final after = await probeDatabase(files.database);
    expect(after.databaseId, before.databaseId);
    expect(after.publishId, before.publishId);
  });
}
