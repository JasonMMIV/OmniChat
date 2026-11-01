import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:OmniChat/core/models/chat_message.dart';
import 'package:OmniChat/core/models/conversation.dart';
import 'package:OmniChat/core/services/chat/chat_service.dart';
import 'package:OmniChat/core/services/chat/storage/chat_database_files.dart';
import 'package:OmniChat/core/services/chat/storage/chat_storage.dart';
import 'package:OmniChat/core/services/chat/storage/chat_storage_gate.dart';
import 'package:OmniChat/core/services/chat/storage/chat_storage_startup_status.dart';
import 'package:OmniChat/core/services/chat/storage/message_part_codec.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() async {
    await Hive.close();
    directory = await Directory.systemTemp.createTemp('omnichat_cutover_');
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
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    await Hive.close();
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  test('ChatService migrates a Hive-only install and reads SQLite', () async {
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

    final conversation = Conversation(
      id: 'chat-1',
      title: 'Migrated',
      messageIds: const ['u', 'a'],
    );
    final user = ChatMessage(
      id: 'u',
      role: 'user',
      content: 'read a.txt',
      conversationId: 'chat-1',
    );
    final assistant = ChatMessage(
      id: 'a',
      role: 'assistant',
      content: 'done',
      conversationId: 'chat-1',
    );
    await conversations.put(conversation.id, conversation);
    await messages.put(user.id, user);
    await messages.put(assistant.id, assistant);
    await toolEvents.put('a', [
      {
        'id': 'call_1',
        'name': 'file_read',
        'arguments': <String, dynamic>{'path': 'a.txt'},
        'content': 'file body',
      },
    ]);
    await Hive.close();

    final backupDirectory = await Directory.systemTemp.createTemp(
      'omnichat_cutover_backup_',
    );
    addTearDown(() async {
      if (await backupDirectory.exists()) {
        await backupDirectory.delete(recursive: true);
      }
    });

    final service = ChatService();
    final phases = <ChatStorageInitPhase>{};
    final migrationEvents = <String>[];
    ChatStorageInitStatus? openingStatus;
    var preparingCount = 0;
    service.addListener(() {
      final status = service.storageInitStatus;
      final phase = status.phase;
      phases.add(phase);
      if (phase == ChatStorageInitPhase.preparing) preparingCount++;
      if (phase == ChatStorageInitPhase.opening) openingStatus = status;
    });
    // Concurrent callers must join one gate/importer run; the first caller
    // supplies the backup prompt before the gate opens Hive.
    await Future.wait(<Future<void>>[
      service.init(
        backupPrompt: () async =>
            ChatMigrationBackupDecision.backup(backupDirectory),
        onMigrationStarted: () async => migrationEvents.add('start'),
        onMigrationFinished: () async => migrationEvents.add('finish'),
      ),
      service.init(),
    ]);
    addTearDown(service.close);

    expect(preparingCount, 1);
    expect(migrationEvents, <String>['start', 'finish']);
    expect(
      service.storageGateResult?.migration?.receipt['backup'],
      'completed',
    );

    expect(
      phases,
      containsAll(<ChatStorageInitPhase>[
        ChatStorageInitPhase.preparing,
        ChatStorageInitPhase.checking,
        ChatStorageInitPhase.migrating,
        ChatStorageInitPhase.validating,
        ChatStorageInitPhase.opening,
        ChatStorageInitPhase.ready,
      ]),
    );
    expect(openingStatus, isNotNull);
    expect(openingStatus!.hasCounts, isTrue);
    expect(openingStatus!.stage, 'opening');
    expect(openingStatus!.cutoverStarted, isTrue);
    expect(service.storageInitStatus.canRetry, isFalse);
    expect(service.backend, ChatStorageBackend.sqlite);
    expect(service.getAllConversations(), hasLength(1));
    expect(
      () => service.getMessages('chat-1'),
      throwsA(isA<ChatStorageNotLoadedException>()),
    );
    await service.ensureConversationLoaded('chat-1');
    expect(service.getMessages('chat-1'), hasLength(2));
    expect(
      () => service.getToolEvents('a'),
      throwsA(isA<ChatStorageNotLoadedException>()),
    );

    final summary = service.getToolPartSummaries('a').single;
    expect(summary.status, kPartStatusCompleted);
    expect(summary.contentLoaded, isFalse);
    expect(
      () => service.getToolEvents('a'),
      throwsA(isA<ChatStorageNotLoadedException>()),
    );

    await service.ensureToolEventsLoaded(['a']);
    final event = service.getToolEvents('a').single;
    expect(event['id'], 'call_1');
    expect(event['content'], 'file body');

    // Hive is untouched as the legacy/export source.
    expect(await File('${directory.path}/conversations.hive').exists(), isTrue);
    expect(
      await File('${directory.path}/tool_events_v1.hive').exists(),
      isTrue,
    );
    expect(await File('${directory.path}/chat_v2.sqlite').exists(), isTrue);
  });

  test(
    'fresh and already-ready SQLite installs do not signal migration',
    () async {
      final events = <String>[];
      final first = ChatService();
      ChatStorageInitStatus? freshOpeningStatus;
      first.addListener(() {
        final status = first.storageInitStatus;
        if (status.phase == ChatStorageInitPhase.opening) {
          freshOpeningStatus = status;
        }
      });
      await first.init(
        onMigrationStarted: () async => events.add('start'),
        onMigrationFinished: () async => events.add('finish'),
      );
      expect(freshOpeningStatus, isNotNull);
      expect(freshOpeningStatus!.hasCounts, isFalse);
      expect(freshOpeningStatus!.cutoverStarted, isFalse);
      expect(first.storageInitStatus.phase, ChatStorageInitPhase.ready);
      expect(first.backend, ChatStorageBackend.sqlite);
      expect(events, isEmpty);
      await first.close();

      final second = ChatService();
      addTearDown(second.close);
      await second.init(
        onMigrationStarted: () async => events.add('start'),
        onMigrationFinished: () async => events.add('finish'),
      );

      expect(second.storageInitStatus.phase, ChatStorageInitPhase.ready);
      expect(second.backend, ChatStorageBackend.sqlite);
      expect(events, isEmpty);
    },
  );
  test('a recorded missing database pauses for explicit recovery', () async {
    final files = ChatDatabaseFiles(directory);
    await files
        .writeJsonAtomically(files.installationReceipt, <String, dynamic>{
          'format': 1,
          'version': 1,
          'databaseId': 'lost-database',
          'schemaVersion': 1,
          'source': 'hive',
          'state': 'complete_clean',
          'installedAtUtc': DateTime.now().toUtc().toIso8601String(),
          'appVersion': 'test',
        });
    final hiveFile = File('${directory.path}/messages.hive');
    await hiveFile.writeAsBytes(<int>[0xde, 0xad, 0xbe, 0xef]);
    final hiveBefore = await hiveFile.readAsBytes();

    final service = ChatService();
    addTearDown(service.close);
    Object? failure;
    try {
      await service.init();
    } catch (error) {
      failure = error;
    }

    expect(failure, isA<ChatStorageRestoreRequiredException>());
    expect(
      service.storageInitStatus.phase,
      ChatStorageInitPhase.restoreRequired,
    );
    expect(service.needsRestoreOrReset, isTrue);
    expect(service.legacyHiveAvailable, isTrue);

    await service.resetChatStorage();

    expect(service.storageInitStatus.phase, ChatStorageInitPhase.ready);
    expect(service.backend, ChatStorageBackend.sqlite);
    expect(await files.legacyImportDisabled.exists(), isTrue);
    expect(await hiveFile.readAsBytes(), hiveBefore);
  });
  test(
    'transient gate failure becomes failed retry without selecting Hive',
    () async {
      final conversations = await Hive.openBox<Conversation>(
        'conversations',
        path: directory.path,
      );
      await conversations.put(
        'legacy-cancel',
        Conversation(id: 'legacy-cancel', title: 'Cancel migration'),
      );
      await Hive.close();

      final service = ChatService();
      addTearDown(service.close);
      await expectLater(
        service.init(
          backupPrompt: () async => const ChatMigrationBackupDecision.cancel(),
        ),
        throwsA(isA<ChatStorageUnavailableException>()),
      );

      expect(service.storageInitStatus.phase, ChatStorageInitPhase.failed);
      expect(service.storageInitStatus.canRetry, isTrue);
      expect(service.backend, isNull);
      expect(await ChatDatabaseFiles(directory).database.exists(), isFalse);
    },
  );

  test(
    'migration failure enters recovery instead of falling back to Hive',
    () async {
      await Hive.close();
      final corrupt = File(
        '${directory.path}${Platform.pathSeparator}messages.hive',
      );
      await corrupt.writeAsBytes(<int>[0xff, 0x00, 0x13, 0x37, 0x42]);

      final events = <String>[];
      final service = ChatService();
      addTearDown(service.close);
      await expectLater(
        service.init(
          backupPrompt: () async => const ChatMigrationBackupDecision.skip(),
          onMigrationStarted: () async => events.add('start'),
          onMigrationFinished: () async => events.add('finish'),
        ),
        throwsA(isA<ChatStorageRestoreRequiredException>()),
      );

      expect(events, <String>['start', 'finish']);
      expect(
        service.storageInitStatus.phase,
        ChatStorageInitPhase.restoreRequired,
      );
      expect(service.storageInitStatus.canRetry, isTrue);
      expect(service.backend, isNull);
    },
  );
}
