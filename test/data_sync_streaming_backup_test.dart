import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/models/backup.dart';
import 'package:OmniChat/core/models/chat_message.dart';
import 'package:OmniChat/core/models/conversation.dart';
import 'package:OmniChat/core/models/file_record.dart';
import 'package:OmniChat/core/models/message_usage.dart';
import 'package:OmniChat/core/models/workspace_config.dart';
import 'package:OmniChat/core/services/backup/backup_preflight.dart';
import 'package:OmniChat/core/services/backup/data_sync.dart';
import 'package:OmniChat/core/services/chat/chat_service.dart';
import 'package:OmniChat/core/services/chat/storage/hive_chat_storage.dart';
import 'package:OmniChat/core/services/chat/storage/sqlite_chat_storage.dart';

Future<File> _writeRestoreZip(
  Directory directory, {
  String? uploadName,
  String? uploadContent,
  bool emptyUploadDirectory = false,
  MessageUsage? usage,
  String role = 'user',
}) async {
  final conversation = Conversation(
    id: 'restore-chat',
    title: 'Restored chat',
    createdAt: DateTime.utc(2026, 1, 1),
    updatedAt: DateTime.utc(2026, 1, 2),
  );
  final message = ChatMessage(
    id: 'restore-message',
    role: role,
    content: 'hello from backup',
    conversationId: conversation.id,
    timestamp: DateTime.utc(2026, 1, 1),
    usageMetaJson: usage == null ? null : jsonEncode(usage.toJson()),
  );
  final chats = <String, dynamic>{
    'version': 3,
    'conversations': <dynamic>[conversation.toJson()],
    'messages': <dynamic>[message.toJson()],
    'toolEvents': <String, dynamic>{},
    'geminiThoughtSigs': <String, dynamic>{},
    'fileRecords': <String, dynamic>{},
    'workspaces': <String, dynamic>{},
    'workspaceBindings': <String, dynamic>{},
  };
  final chatsBytes = utf8.encode(jsonEncode(chats));
  final archive = Archive()
    ..addFile(ArchiveFile('chats.json', chatsBytes.length, chatsBytes));
  if (uploadName != null && uploadContent != null) {
    final uploadBytes = utf8.encode(uploadContent);
    archive.addFile(
      ArchiveFile('upload/$uploadName', uploadBytes.length, uploadBytes),
    );
  } else if (emptyUploadDirectory) {
    archive.addFile(ArchiveFile('upload/', 0, <int>[])..isFile = false);
  }
  final backup = File(p.join(directory.path, 'restore.zip'));
  await backup.writeAsBytes(ZipEncoder().encode(archive));
  return backup;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory appDir;
  late Directory tempDir;
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() async {
    await Hive.close();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    appDir = await Directory.systemTemp.createTemp('omnichat_data_sync_app_');
    tempDir = await Directory.systemTemp.createTemp('omnichat_data_sync_tmp_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
          switch (call.method) {
            case 'getTemporaryDirectory':
              return tempDir.path;
            case 'getApplicationSupportDirectory':
            case 'getApplicationDocumentsDirectory':
              return appDir.path;
          }
          return null;
        });
    if (!Hive.isAdapterRegistered(0)) {
      Hive.registerAdapter(ChatMessageAdapter());
    }
    if (!Hive.isAdapterRegistered(1)) {
      Hive.registerAdapter(ConversationAdapter());
    }
    Hive.init(appDir.path);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    await Hive.close();
    for (final dir in <Directory>[appDir, tempDir]) {
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  });

  test('prepareBackupFile streams the v3 chats shape into the zip', () async {
    final conversations = await Hive.openBox<Conversation>(
      'conversations',
      path: appDir.path,
    );
    final messages = await Hive.openBox<ChatMessage>(
      'messages',
      path: appDir.path,
    );
    final toolEvents = await Hive.openBox('tool_events_v1', path: appDir.path);
    final fileRecords = await Hive.openBox(
      'message_file_records_v1',
      path: appDir.path,
    );
    final workspaceBindings = await Hive.openBox(
      'conversation_workspace_bindings_v2',
      path: appDir.path,
    );

    final conversation = Conversation(
      id: 'chat-1',
      title: 'Streamed backup',
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
      reasoningText: 'think',
      usageMetaJson: jsonEncode(
        const MessageUsage(costUsd: 0.0041, billingSource: 'balance').toJson(),
      ),
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

    final service = ChatService(storage: HiveChatStorage(directory: appDir));
    addTearDown(service.close);
    await service.init();
    await service.setGeminiThoughtSignature('a', 'thought-signature');

    final sync = DataSync(chatService: service);
    final zipFile = await sync.prepareBackupFile(
      const WebDavConfig(includeChats: true, includeFiles: false),
    );

    final archive = ZipDecoder().decodeBytes(await zipFile.readAsBytes());
    final names = archive.files.map((f) => f.name).toSet();
    expect(names, contains('settings.json'));
    expect(names, contains('chats.json'));

    final chats =
        jsonDecode(utf8.decode(archive.find('chats.json')!.content))
            as Map<String, dynamic>;
    expect(chats['version'], 3);
    expect((chats['conversations'] as List).single['id'], 'chat-1');
    expect((chats['messages'] as List), hasLength(2));
    final exportedAssistant =
        (chats['messages'] as List).firstWhere(
              (message) => (message as Map)['id'] == 'a',
            )
            as Map;
    expect(exportedAssistant['usageMeta']['costUsd'], 0.0041);
    expect(exportedAssistant['usageMeta']['billingSource'], 'balance');
    expect((chats['toolEvents'] as Map)['a'], hasLength(1));
    expect((chats['geminiThoughtSigs'] as Map)['a'], 'thought-signature');
    expect((chats['workspaces'] as Map)['chat-1'], '/tmp/workspace');
    expect((chats['workspaceBindings'] as Map)['chat-1']['mode'], 'custom');
    expect((chats['fileRecords'] as Map)['a'], hasLength(1));

    // The streamed chats temp file must not outlive the archive build.
    final leftovers = tempDir.listSync().whereType<File>().where(
      (f) => p.basename(f.path).startsWith('omnichat_chats_'),
    );
    expect(leftovers, isEmpty);
  });

  test('WebDAV backup streams a complete zip with Content-Length', () async {
    // flutter_test installs a mock HttpClient that answers every request with
    // 400. This test needs a real loopback server, so remove the override for
    // its duration and restore it afterwards.
    final previousOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = previousOverrides);

    final service = ChatService(storage: HiveChatStorage(directory: appDir));
    addTearDown(service.close);
    await service.init();

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var putBody = <int>[];
    var putContentLength = -1;
    server.listen((request) async {
      if (request.method == 'PROPFIND') {
        request.response.statusCode = 207;
        await request.response.close();
        return;
      }
      if (request.method == 'PUT') {
        putContentLength = request.contentLength;
        putBody = await request.fold<List<int>>(<int>[], (all, chunk) {
          all.addAll(chunk);
          return all;
        });
        request.response.statusCode = 201;
        await request.response.close();
        return;
      }
      request.response.statusCode = 405;
      await request.response.close();
    });

    final sync = DataSync(chatService: service);
    await sync.backupToWebDav(
      WebDavConfig(
        url: 'http://${server.address.address}:${server.port}',
        includeChats: false,
        includeFiles: false,
      ),
    );

    expect(putContentLength, putBody.length);
    final archive = ZipDecoder().decodeBytes(putBody);
    expect(archive.files.map((f) => f.name), contains('settings.json'));
  });

  test('includeChats false omits chats.json', () async {
    final service = ChatService(storage: HiveChatStorage(directory: appDir));
    addTearDown(service.close);
    await service.init();

    final sync = DataSync(chatService: service);
    final zipFile = await sync.prepareBackupFile(
      const WebDavConfig(includeChats: false, includeFiles: false),
    );
    final archive = ZipDecoder().decodeBytes(await zipFile.readAsBytes());
    final names = archive.files.map((f) => f.name).toSet();
    expect(names, contains('settings.json'));
    expect(names, isNot(contains('chats.json')));
  });

  test('restore with includeFiles false preserves local uploads', () async {
    final uploadDir = Directory(p.join(appDir.path, 'upload'));
    await uploadDir.create(recursive: true);
    final localUpload = File(p.join(uploadDir.path, 'keep.txt'));
    await localUpload.writeAsString('local-only');

    final backup = await _writeRestoreZip(tempDir);

    final storage = SqliteChatStorage(
      directory: appDir,
      appVersion: 'test',
      background: false,
    );
    final service = ChatService(storage: storage);
    addTearDown(service.close);
    await service.init();

    final result = await DataSync(chatService: service).restoreFromLocalFile(
      backup,
      const WebDavConfig(includeFiles: false),
      mode: RestoreMode.overwrite,
      restoreSettings: false,
    );

    expect(result, isNotNull);
    expect(result!.settingsApplied, isTrue);
    expect(await localUpload.exists(), isTrue);
    expect(await localUpload.readAsString(), 'local-only');
    expect(service.getAllConversations().single.id, 'restore-chat');
    expect(
      service.getMessages('restore-chat').single.content,
      'hello from backup',
    );
  });

  test('restore preserves OpenCode usage metadata', () async {
    const usage = MessageUsage(
      costUsd: 0.0041,
      listCostUsd: 0.005,
      billingSource: 'balance',
      inputTokens: 13,
      outputTokens: 10,
    );
    final backup = await _writeRestoreZip(
      tempDir,
      usage: usage,
      role: 'assistant',
    );
    final storage = SqliteChatStorage(
      directory: appDir,
      appVersion: 'test',
      background: false,
    );
    final service = ChatService(storage: storage);
    addTearDown(service.close);
    await service.init();

    await DataSync(chatService: service).restoreFromLocalFile(
      backup,
      const WebDavConfig(includeFiles: false),
      mode: RestoreMode.overwrite,
      restoreSettings: false,
    );

    final restored = service.getMessages('restore-chat').single;
    expect(restored.usageMeta?.costUsd, 0.0041);
    expect(restored.usageMeta?.billingSource, 'balance');
  });

  test('restore with files replaces uploads from the archive', () async {
    final uploadDir = Directory(p.join(appDir.path, 'upload'));
    await uploadDir.create(recursive: true);
    final staleUpload = File(p.join(uploadDir.path, 'stale.txt'));
    await staleUpload.writeAsString('delete me');

    final backup = await _writeRestoreZip(
      tempDir,
      uploadName: 'from-backup.txt',
      uploadContent: 'restored upload',
    );
    final storage = SqliteChatStorage(
      directory: appDir,
      appVersion: 'test',
      background: false,
    );
    final service = ChatService(storage: storage);
    addTearDown(service.close);
    await service.init();

    await DataSync(chatService: service).restoreFromLocalFile(
      backup,
      const WebDavConfig(includeFiles: true),
      mode: RestoreMode.overwrite,
      restoreSettings: false,
    );

    expect(await staleUpload.exists(), isFalse);
    expect(
      await File(p.join(uploadDir.path, 'from-backup.txt')).readAsString(),
      'restored upload',
    );
  });

  test(
    'restore with files but no upload directory preserves uploads',
    () async {
      final uploadDir = Directory(p.join(appDir.path, 'upload'));
      await uploadDir.create(recursive: true);
      final localUpload = File(p.join(uploadDir.path, 'keep.txt'));
      await localUpload.writeAsString('keep me');

      final backup = await _writeRestoreZip(tempDir);
      final storage = SqliteChatStorage(
        directory: appDir,
        appVersion: 'test',
        background: false,
      );
      final service = ChatService(storage: storage);
      addTearDown(service.close);
      await service.init();

      await DataSync(chatService: service).restoreFromLocalFile(
        backup,
        const WebDavConfig(includeFiles: true),
        mode: RestoreMode.overwrite,
        restoreSettings: false,
      );

      expect(await localUpload.exists(), isTrue);
      expect(await localUpload.readAsString(), 'keep me');
    },
  );

  test(
    'restore with files but only an empty upload directory preserves uploads',
    () async {
      final uploadDir = Directory(p.join(appDir.path, 'upload'));
      await uploadDir.create(recursive: true);
      final localUpload = File(p.join(uploadDir.path, 'keep.txt'));
      await localUpload.writeAsString('keep me too');

      final backup = await _writeRestoreZip(
        tempDir,
        emptyUploadDirectory: true,
      );
      final storage = SqliteChatStorage(
        directory: appDir,
        appVersion: 'test',
        background: false,
      );
      final service = ChatService(storage: storage);
      addTearDown(service.close);
      await service.init();

      await DataSync(chatService: service).restoreFromLocalFile(
        backup,
        const WebDavConfig(includeFiles: true),
        mode: RestoreMode.overwrite,
        restoreSettings: false,
      );

      expect(await localUpload.exists(), isTrue);
      expect(await localUpload.readAsString(), 'keep me too');
    },
  );

  test('prepareBackupFile fails with a structured list when a referenced '
      'upload file is missing', () async {
    final storage = SqliteChatStorage(
      directory: appDir,
      appVersion: 'test',
      background: false,
    );
    final service = ChatService(storage: storage);
    addTearDown(service.close);
    await service.init();

    final missingPath = p.join(appDir.path, 'upload', 'ghost.png');
    await service.restoreConversation(
      Conversation(id: 'chat-refs', title: 'Refs'),
      <ChatMessage>[
        ChatMessage(
          id: 'ref-message',
          role: 'user',
          content: 'look [image:$missingPath]',
          conversationId: 'chat-refs',
        ),
      ],
    );

    final sync = DataSync(chatService: service);
    await expectLater(
      sync.prepareBackupFile(
        const WebDavConfig(includeChats: true, includeFiles: true),
      ),
      throwsA(
        isA<BackupPreflightException>().having(
          (error) => error.toString(),
          'message',
          contains(missingPath),
        ),
      ),
    );

    // The failed backup must not leave a partial zip behind.
    final leftovers = tempDir.listSync().whereType<File>().where(
      (f) => p.basename(f.path).startsWith('omnichat_backup_'),
    );
    expect(leftovers, isEmpty);
  });

  test('prepareBackupFile succeeds when referenced uploads exist and outside '
      'references do not fail', () async {
    final storage = SqliteChatStorage(
      directory: appDir,
      appVersion: 'test',
      background: false,
    );
    final service = ChatService(storage: storage);
    addTearDown(service.close);
    await service.init();

    final uploadDir = Directory(p.join(appDir.path, 'upload'));
    await uploadDir.create(recursive: true);
    final attached = File(p.join(uploadDir.path, 'present.png'));
    await attached.writeAsString('png-bytes');
    final outsidePath = p.join(p.dirname(appDir.path), 'outside.png');

    await service.restoreConversation(
      Conversation(id: 'chat-refs', title: 'Refs'),
      <ChatMessage>[
        ChatMessage(
          id: 'ref-message',
          role: 'user',
          content: 'a [image:${attached.path}] b ![x]($outsidePath)',
          conversationId: 'chat-refs',
        ),
      ],
    );

    final sync = DataSync(chatService: service);
    final zipFile = await sync.prepareBackupFile(
      const WebDavConfig(includeChats: true, includeFiles: true),
    );

    final archive = ZipDecoder().decodeBytes(await zipFile.readAsBytes());
    expect(archive.files.map((f) => f.name), contains('upload/present.png'));
  });
}
