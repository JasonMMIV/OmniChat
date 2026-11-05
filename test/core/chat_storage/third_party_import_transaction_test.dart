import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/models/backup.dart';
import 'package:OmniChat/core/models/chat_message.dart';
import 'package:OmniChat/core/models/conversation.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/backup/chatbox_importer.dart';
import 'package:OmniChat/core/services/backup/cherry_importer.dart';
import 'package:OmniChat/core/services/chat/chat_service.dart';
import 'package:OmniChat/core/services/chat/storage/chat_backup_restorer.dart';
import 'package:OmniChat/core/services/chat/storage/chat_database_files.dart';

/// Phase 1c acceptance tests (docs/transactional_backup_restore_plan.md §3):
/// third-party overwrite imports run through the transactional
/// staging/publish path — no `clearAllData()` — and a failure leaves the
/// previous conversations, uploads and prefs in place.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() async {
    ChatBackupRestorer.debugFailAfterConversations = 0;
    CherryImporter.debugFailOnMaterialize = false;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await Hive.close();
    directory = await Directory.systemTemp.createTemp(
      'omnichat_third_party_import_',
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
    CherryImporter.debugFailOnMaterialize = false;
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

  SettingsProvider makeSettings() {
    final settings = SettingsProvider();
    addTearDown(settings.dispose);
    return settings;
  }

  Future<void> seedConversations(ChatService service) async {
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

  Future<void> stagingLeftovers() async {
    final leftovers = directory
        .listSync()
        .whereType<Directory>()
        .where(
          (dir) => p.basename(dir.path).startsWith('restore_staging_'),
        )
        .toList();
    expect(leftovers, isEmpty);
  }

  Map<String, dynamic> chatboxTextMessage(String id, String role, String text) {
    return <String, dynamic>{
      'id': id,
      'role': role,
      'contentParts': <dynamic>[
        <String, dynamic>{'type': 'text', 'text': text},
      ],
      'timestamp': 1700000000000,
    };
  }

  Map<String, dynamic> chatboxExport({
    required List<Map<String, dynamic>> sessions,
    Map<String, dynamic> providers = const <String, dynamic>{},
  }) {
    return <String, dynamic>{
      '__exported_at': '2026-01-01T00:00:00.000Z',
      'chat-sessions-list': <dynamic>[
        for (final session in sessions)
          <String, dynamic>{'id': session['id'], 'name': session['name']},
      ],
      for (final session in sessions)
        'session:${session['id']}': <String, dynamic>{
          'messages': session['messages'],
          'threads': const <dynamic>[],
          'settings': session['settings'] ?? const <String, dynamic>{},
        },
      'settings': <String, dynamic>{'providers': providers},
    };
  }

  Map<String, dynamic> cherryExport({
    List<dynamic> providers = const <dynamic>[],
    List<dynamic> assistants = const <dynamic>[],
    List<dynamic> topics = const <dynamic>[],
    List<dynamic> files = const <dynamic>[],
  }) {
    return <String, dynamic>{
      'version': 2,
      'localStorage': <String, dynamic>{
        'persist:cherry-studio': jsonEncode(<String, dynamic>{
          'assistants': jsonEncode(<String, dynamic>{'assistants': assistants}),
          'llm': jsonEncode(<String, dynamic>{'providers': providers}),
        }),
      },
      'indexedDB': <String, dynamic>{
        'topics': topics,
        'message_blocks': const <dynamic>[],
        'files': files,
      },
    };
  }

  group('Chatbox overwrite (transactional)', () {
    test('replaces live chats and writes prefs after the commit', () async {
      final service = await readyService();
      await seedConversations(service);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'assistants_v1',
        jsonEncode(<dynamic>[
          <String, dynamic>{'id': 'local-assistant', 'name': 'Local'},
        ]),
      );

      final export = chatboxExport(
        sessions: <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'session-1',
            'name': 'First',
            'messages': <dynamic>[
              chatboxTextMessage('m1', 'user', 'hello'),
              chatboxTextMessage('m2', 'assistant', 'hi there'),
            ],
          },
          <String, dynamic>{
            'id': 'session-2',
            'name': 'Second',
            'messages': <dynamic>[
              chatboxTextMessage('m3', 'user', 'second chat'),
            ],
          },
        ],
        providers: <String, dynamic>{
          'openai': <String, dynamic>{
            'apiKey': 'sk-test',
            'apiHost': 'api.openai.com',
          },
        },
      );
      final file = File(p.join(directory.path, 'chatbox.json'));
      await file.writeAsString(jsonEncode(export));

      final result = await ChatboxImporter.importFromChatbox(
        file: file,
        mode: RestoreMode.overwrite,
        settings: makeSettings(),
        chatService: service,
      );

      expect(result.conversations, 2);
      expect(result.messages, 3);
      expect(result.assistants, 2);
      expect(result.providers, 1);
      expect(
        service
            .getAllConversations()
            .map((conversation) => conversation.id),
        containsAll(<String>['chatbox_default_session-1', 'chatbox_default_session-2']),
      );
      expect(
        service
            .getAllConversations()
            .map((conversation) => conversation.id),
        isNot(contains('keep')),
      );
      await service.ensureConversationLoaded('chatbox_default_session-1');
      expect(service.getMessages('chatbox_default_session-1'), hasLength(2));

      final assistants = jsonDecode(prefs.getString('assistants_v1')!) as List;
      expect(
        assistants.map((a) => a['id']),
        containsAll(<String>['session-1', 'session-2']),
      );
      expect(
        assistants.map((a) => a['id']),
        isNot(contains('local-assistant')),
      );
      final providers =
          jsonDecode(prefs.getString('provider_configs_v1')!) as Map;
      expect(providers.keys, contains('openai'));
      final tags = jsonDecode(prefs.getString('assistant_tags_v1')!) as List;
      expect(tags.map((t) => t['name']), contains('Chatbox'));

      final files = ChatDatabaseFiles(directory);
      expect(await files.restoreJournal.exists(), isFalse);
      expect(await files.restoring.exists(), isFalse);
      await stagingLeftovers();
    });

    test('a failed import leaves chats and prefs untouched', () async {
      final service = await readyService();
      await seedConversations(service);
      final prefs = await SharedPreferences.getInstance();
      const localAssistants =
          '[{"id":"local-assistant","name":"Local","systemPrompt":"local prompt"}]';
      await prefs.setString('assistants_v1', localAssistants);

      final export = chatboxExport(
        sessions: <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'session-1',
            'name': 'First',
            'messages': <dynamic>[
              chatboxTextMessage('m1', 'user', 'hello'),
            ],
          },
          <String, dynamic>{
            'id': 'session-2',
            'name': 'Second',
            'messages': <dynamic>[
              chatboxTextMessage('m2', 'user', 'second'),
            ],
          },
        ],
      );
      final file = File(p.join(directory.path, 'chatbox.json'));
      await file.writeAsString(jsonEncode(export));
      ChatBackupRestorer.debugFailAfterConversations = 1;

      await expectLater(
        ChatboxImporter.importFromChatbox(
          file: file,
          mode: RestoreMode.overwrite,
          settings: makeSettings(),
          chatService: service,
        ),
        throwsA(isA<ChatRestoreException>()),
      );

      expect(service.initialized, isTrue);
      expect(service.getAllConversations().single.id, 'keep');
      expect(prefs.getString('assistants_v1'), localAssistants);
      expect(await prefs.getString('provider_configs_v1'), isNull);

      final files = ChatDatabaseFiles(directory);
      expect(await files.restoreJournal.exists(), isFalse);
      expect(await files.restoring.exists(), isFalse);
      await stagingLeftovers();
    });

    test('an export without chat history throws and changes nothing',
        () async {
      final service = await readyService();
      await seedConversations(service);
      final prefs = await SharedPreferences.getInstance();
      const localAssistants = '[{"id":"local-assistant","name":"Local"}]';
      await prefs.setString('assistants_v1', localAssistants);

      final export = <String, dynamic>{
        'settings': <String, dynamic>{
          'providers': <String, dynamic>{
            'openai': <String, dynamic>{'apiKey': 'sk-test'},
          },
        },
      };
      final file = File(p.join(directory.path, 'chatbox.json'));
      await file.writeAsString(jsonEncode(export));

      await expectLater(
        ChatboxImporter.importFromChatbox(
          file: file,
          mode: RestoreMode.overwrite,
          settings: makeSettings(),
          chatService: service,
        ),
        throwsA(isA<ChatboxImportException>()),
      );

      expect(service.getAllConversations().single.id, 'keep');
      expect(prefs.getString('assistants_v1'), localAssistants);
      await stagingLeftovers();
    });

    test('merge keeps dedup semantics and existing data', () async {
      final service = await readyService();
      await service.restoreConversation(
        Conversation(id: 'chatbox_default_session-1', title: 'Existing'),
        <ChatMessage>[
          ChatMessage(
            id: 'm1',
            role: 'user',
            content: 'already there',
            conversationId: 'chatbox_default_session-1',
          ),
        ],
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'assistants_v1',
        jsonEncode(<dynamic>[
          <String, dynamic>{
            'id': 'session-1',
            'name': 'Local Name',
            'systemPrompt': 'local prompt',
          },
        ]),
      );

      final export = chatboxExport(
        sessions: <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'session-1',
            'name': 'Remote Name',
            'messages': <dynamic>[
              chatboxTextMessage('m1', 'user', 'already there'),
              chatboxTextMessage('m2', 'user', 'new message'),
            ],
            'settings': <String, dynamic>{
              'provider': 'openai',
              'modelId': 'gpt-test',
            },
          },
        ],
      );
      final file = File(p.join(directory.path, 'chatbox.json'));
      await file.writeAsString(jsonEncode(export));

      final result = await ChatboxImporter.importFromChatbox(
        file: file,
        mode: RestoreMode.merge,
        settings: makeSettings(),
        chatService: service,
      );

      expect(result.conversations, 0);
      expect(result.messages, 1);
      await service.ensureConversationLoaded('chatbox_default_session-1');
      expect(
        service
            .getMessages('chatbox_default_session-1')
            .map((m) => m.id),
        <String>['m1', 'm2'],
      );

      final assistants = jsonDecode(prefs.getString('assistants_v1')!) as List;
      expect(assistants, hasLength(1));
      final assistant = assistants.first as Map;
      expect(assistant['name'], 'Local Name');
      expect(assistant['systemPrompt'], 'local prompt');
      expect(assistant['chatModelProvider'], 'openai');
      expect(assistant['chatModelId'], 'gpt-test');
    });
  });

  group('Cherry overwrite (transactional)', () {
    Map<String, dynamic> cherryFile({String content = 'file body'}) {
      return <String, dynamic>{
        'id': 'file-1',
        'origin_name': 'hello.txt',
        'type': 'text/plain',
        'content': content,
      };
    }

    Map<String, dynamic> cherryTopic() {
      return <String, dynamic>{
        'id': 'topic-1',
        'messages': <dynamic>[
          <String, dynamic>{
            'id': 'cm1',
            'role': 'user',
            'content': 'see attachment',
            'createdAt': '2026-01-01T00:00:00.000Z',
            'files': <dynamic>[
              <String, dynamic>{
                'id': 'file-1',
                'origin_name': 'hello.txt',
                'type': 'text/plain',
              },
            ],
          },
        ],
      };
    }

    test('replaces chats and swaps staged uploads', () async {
      final service = await readyService();
      await seedConversations(service);
      // Match AppDirectories' path construction ('${root.path}/upload') so
      // the content marker comparison is byte-identical.
      final uploadDir = Directory('${directory.path}/upload');
      await uploadDir.create(recursive: true);
      await File(p.join(uploadDir.path, 'old.txt')).writeAsString('old');

      final export = cherryExport(
        providers: <dynamic>[
          <String, dynamic>{
            'id': 'prov-1',
            'type': 'openai',
            'name': 'Prov',
            'apiKey': 'k',
            'models': <dynamic>[],
          },
        ],
        assistants: <dynamic>[
          <String, dynamic>{
            'id': 'assistant-1',
            'name': 'Assistant',
            'prompt': 'be nice',
          },
        ],
        topics: <dynamic>[cherryTopic()],
        files: <dynamic>[cherryFile()],
      );
      final file = File(p.join(directory.path, 'cherry.json'));
      await file.writeAsString(jsonEncode(export));

      final result = await CherryImporter.importFromCherryStudio(
        file: file,
        mode: RestoreMode.overwrite,
        settings: makeSettings(),
        chatService: service,
      );

      expect(result.conversations, 1);
      expect(result.messages, 1);
      expect(result.files, 1);
      expect(
        service.getAllConversations().map((c) => c.id),
        <String>['topic-1'],
      );
      await service.ensureConversationLoaded('topic-1');
      final message = service.getMessages('topic-1').single;
      final materialized = p.join(uploadDir.path, 'cherry_file-1_hello.txt');
      expect(message.content, contains(materialized));
      expect(await File(materialized).readAsString(), 'file body');
      expect(await File(p.join(uploadDir.path, 'old.txt')).exists(), isFalse);

      final prefs = await SharedPreferences.getInstance();
      final providers =
          jsonDecode(prefs.getString('provider_configs_v1')!) as Map;
      expect(providers.keys, contains('prov-1'));
      final assistants = jsonDecode(prefs.getString('assistants_v1')!) as List;
      expect(assistants.map((a) => a['id']), contains('assistant-1'));

      final files = ChatDatabaseFiles(directory);
      expect(await files.restoreJournal.exists(), isFalse);
      expect(await files.restoring.exists(), isFalse);
      await stagingLeftovers();
    });

    test('a materialize failure leaves live DB and uploads untouched',
        () async {
      final service = await readyService();
      await seedConversations(service);
      // Match AppDirectories' path construction ('${root.path}/upload') so
      // the content marker comparison is byte-identical.
      final uploadDir = Directory('${directory.path}/upload');
      await uploadDir.create(recursive: true);
      await File(p.join(uploadDir.path, 'old.txt')).writeAsString('old');
      final prefs = await SharedPreferences.getInstance();

      final export = cherryExport(
        topics: <dynamic>[cherryTopic()],
        files: <dynamic>[cherryFile()],
      );
      final file = File(p.join(directory.path, 'cherry.json'));
      await file.writeAsString(jsonEncode(export));
      CherryImporter.debugFailOnMaterialize = true;

      await expectLater(
        CherryImporter.importFromCherryStudio(
          file: file,
          mode: RestoreMode.overwrite,
          settings: makeSettings(),
          chatService: service,
        ),
        throwsA(isA<FileSystemException>()),
      );

      expect(service.getAllConversations().single.id, 'keep');
      expect(await File(p.join(uploadDir.path, 'old.txt')).readAsString(),
          'old');
      expect(
        await File(p.join(uploadDir.path, 'cherry_file-1_hello.txt')).exists(),
        isFalse,
      );
      expect(await prefs.getString('provider_configs_v1'), isNull);
      expect(await prefs.getString('assistants_v1'), isNull);

      final files = ChatDatabaseFiles(directory);
      expect(await files.restoreJournal.exists(), isFalse);
      await stagingLeftovers();
    });

    test('merge keeps existing messages and materializes files', () async {
      final service = await readyService();
      await service.restoreConversation(
        Conversation(id: 'topic-1', title: 'Existing'),
        <ChatMessage>[
          ChatMessage(
            id: 'cm1',
            role: 'user',
            content: 'already there',
            conversationId: 'topic-1',
          ),
        ],
      );
      final uploadDir = Directory('${directory.path}/upload');
      await uploadDir.create(recursive: true);

      final export = cherryExport(
        topics: <dynamic>[
          <String, dynamic>{
            'id': 'topic-1',
            'messages': <dynamic>[
              <String, dynamic>{
                'id': 'cm1',
                'role': 'user',
                'content': 'already there',
                'createdAt': '2026-01-01T00:00:00.000Z',
              },
              <String, dynamic>{
                'id': 'cm2',
                'role': 'user',
                'content': 'new message',
                'createdAt': '2026-01-02T00:00:00.000Z',
                'files': <dynamic>[
                  <String, dynamic>{
                    'id': 'file-1',
                    'origin_name': 'hello.txt',
                    'type': 'text/plain',
                  },
                ],
              },
            ],
          },
        ],
        files: <dynamic>[cherryFile()],
      );
      final file = File(p.join(directory.path, 'cherry.json'));
      await file.writeAsString(jsonEncode(export));

      final result = await CherryImporter.importFromCherryStudio(
        file: file,
        mode: RestoreMode.merge,
        settings: makeSettings(),
        chatService: service,
      );

      expect(result.conversations, 0);
      expect(result.messages, 1);
      expect(result.files, 1);
      await service.ensureConversationLoaded('topic-1');
      expect(
        service.getMessages('topic-1').map((m) => m.id),
        <String>['cm1', 'cm2'],
      );
      expect(
        await File(
          p.join(uploadDir.path, 'cherry_file-1_hello.txt'),
        ).readAsString(),
        'file body',
      );
    });
  });
}
