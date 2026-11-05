import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/core/models/chat_message.dart';
import 'package:OmniChat/core/models/conversation.dart';
import 'package:OmniChat/core/models/file_record.dart';
import 'package:OmniChat/core/models/workspace_config.dart';
import 'package:OmniChat/core/services/chat/storage/app_database.dart';
import 'package:OmniChat/core/services/chat/storage/chat_backup_restorer.dart';
import 'package:OmniChat/core/services/chat/storage/chat_database_files.dart';
import 'package:OmniChat/core/services/chat/storage/chat_repository.dart';
import 'package:OmniChat/core/services/chat/storage/database_family_publisher.dart';
import 'package:OmniChat/core/services/chat/storage/database_installation_gate.dart';

Map<String, dynamic> chatsJson({
  required List<Conversation> conversations,
  required List<ChatMessage> messages,
  Map<String, List<Map<String, dynamic>>> toolEvents =
      const <String, List<Map<String, dynamic>>>{},
  Map<String, String> signatures = const <String, String>{},
  Map<String, Map<String, dynamic>> bindings =
      const <String, Map<String, dynamic>>{},
  Map<String, List<Map<String, dynamic>>> fileRecords =
      const <String, List<Map<String, dynamic>>>{},
}) {
  return <String, dynamic>{
    'version': 3,
    'conversations': conversations.map((c) => c.toJson()).toList(),
    'messages': messages.map((m) => m.toJson()).toList(),
    'toolEvents': toolEvents,
    'geminiThoughtSigs': signatures,
    'workspaceBindings': bindings,
    'fileRecords': fileRecords,
  };
}

Future<File> writeArchive(
  Directory directory,
  Map<String, dynamic> chats, {
  Map<String, dynamic>? settings,
  Map<String, String> files = const <String, String>{},
  bool includeChats = true,
}) async {
  final archive = Archive();
  void add(String name, List<int> bytes) {
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  if (includeChats) {
    add('chats.json', utf8.encode(jsonEncode(chats)));
  }
  if (settings != null) {
    add('settings.json', utf8.encode(jsonEncode(settings)));
  }
  for (final entry in files.entries) {
    add(entry.key, utf8.encode(entry.value));
  }
  final bytes = ZipEncoder().encode(archive)!;
  final file = File('${directory.path}/omnichat_backup.zip');
  await file.writeAsBytes(bytes);
  return file;
}

void main() {
  late Directory directory;
  late ChatDatabaseFiles files;
  late ChatBackupRestorer restorer;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'omnichat_backup_restorer_',
    );
    files = ChatDatabaseFiles(directory);
    restorer = ChatBackupRestorer(
      directory: directory,
      appVersion: 'test',
    );
    ChatBackupRestorer.debugFailAfterConversations = 0;
    ChatBackupRestorer.debugAfterPublishFailure = null;
    DatabaseFamilyPublisher.debugFailOnPublish = false;
    DatabaseFamilyPublisher.debugForceFailClosedRecovery = false;
  });

  tearDown(() async {
    ChatBackupRestorer.debugFailAfterConversations = 0;
    ChatBackupRestorer.debugAfterPublishFailure = null;
    DatabaseFamilyPublisher.debugFailOnPublish = false;
    DatabaseFamilyPublisher.debugForceFailClosedRecovery = false;
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  Future<void> createDatabase(
    File file, {
    required String databaseId,
    required String publishId,
    List<Conversation> conversations = const <Conversation>[],
  }) async {
    await files.deleteFamily(file);
    final db = AppDatabase.open(
      file,
      background: false,
      synchronousFull: true,
    );
    try {
      await db.verifyHealthy();
      final repo = ChatRepository(db);
      await repo.putMigrationMeta(<String, String>{
        'database_id': databaseId,
        'publish_id': publishId,
        'source': 'fresh',
        'state': 'complete_clean',
        'installed_schema_version': '$currentChatSchemaVersion',
        'installed_by_app_version': 'test',
        'quarantine_count': '0',
      });
      for (final conversation in conversations) {
        await repo.restoreConversation(
          conversation,
          const <ChatMessage>[],
        );
      }
      await db.checkpointAndTruncate();
    } finally {
      await db.close();
    }
    await files.deleteSidecars(file);
  }

  ChatMessage message(String id, String conversationId, String content) {
    return ChatMessage(
      id: id,
      role: 'user',
      content: content,
      conversationId: conversationId,
    );
  }

  test('parses a complete payload and normalizes orphan references', () async {
    final conversations = <Conversation>[
      Conversation(id: 'c1', title: 'One'),
      Conversation(id: 'c2', title: 'Two'),
    ];
    final messages = <ChatMessage>[
      message('m1', 'c1', 'hello'),
      message('m2', 'c2', 'world'),
    ];
    final archive = await writeArchive(
      directory,
      chatsJson(
        conversations: conversations,
        messages: messages,
        toolEvents: <String, List<Map<String, dynamic>>>{
          'm2': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'call_1',
              'name': 'file_read',
              'arguments': <String, dynamic>{'path': 'a.txt'},
              'content': 'body',
            },
          ],
          // Unknown message: dropped rather than failing the whole restore.
          'orphan-message': <Map<String, dynamic>>[
            <String, dynamic>{'id': 'call_x', 'name': 'noop'},
          ],
        },
        signatures: <String, String>{'m2': 'sig-1', 'missing': 'sig-x'},
        bindings: <String, Map<String, dynamic>>{
          'c1': WorkspaceConfig.custom('/tmp/ws').toJson(),
          'missing': WorkspaceConfig.custom('/tmp/other').toJson(),
        },
        fileRecords: <String, List<Map<String, dynamic>>>{
          'm1': <Map<String, dynamic>>[
            FileRecord(
              path: '/tmp/upload/a.txt',
              fileName: 'a.txt',
              sizeBytes: 3,
              createdAt: DateTime.utc(2026, 1, 1),
            ).toJson(),
          ],
          'missing': <Map<String, dynamic>>[],
        },
      ),
      settings: <String, dynamic>{'some_key': 'some_value'},
    );

    final payload = await restorer.parseAndValidate(archive);

    expect(payload.conversations, hasLength(2));
    expect(payload.messageCount, 2);
    expect(payload.partCount, 1);
    expect(payload.signatureCount, 1);
    expect(payload.workspaceBindingCount, 1);
    expect(payload.fileRecordCount, 1);
    expect(payload.settings?['some_key'], 'some_value');
    expect(payload.archiveSha256, hasLength(64));
  });

  test('rejects an orphan message before any staging work', () async {
    final archive = await writeArchive(
      directory,
      chatsJson(
        conversations: <Conversation>[
          Conversation(id: 'c1', title: 'One'),
        ],
        messages: <ChatMessage>[message('m1', 'missing', 'orphan')],
      ),
    );

    await expectLater(
      restorer.parseAndValidate(archive),
      throwsA(
        isA<ChatRestoreException>().having(
          (error) => error.message,
          'message',
          contains('conversation is missing'),
        ),
      ),
    );
    expect(await files.restoring.exists(), isFalse);
    expect(await files.database.exists(), isFalse);
  });

  test('builds and verifies a staging database with every row family', () async {
    final conversations = <Conversation>[
      Conversation(id: 'c1', title: 'One'),
    ];
    final messages = <ChatMessage>[
      message('m1', 'c1', 'hello'),
      message('m2', 'c1', 'world'),
    ];
    final archive = await writeArchive(
      directory,
      chatsJson(
        conversations: conversations,
        messages: messages,
        toolEvents: <String, List<Map<String, dynamic>>>{
          'm2': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'call_1',
              'name': 'file_read',
              'arguments': <String, dynamic>{'path': 'a.txt'},
              'content': 'body',
            },
          ],
        },
        signatures: <String, String>{'m2': 'sig-1'},
        bindings: <String, Map<String, dynamic>>{
          'c1': WorkspaceConfig.custom('/tmp/ws').toJson(),
        },
        fileRecords: <String, List<Map<String, dynamic>>>{
          'm1': <Map<String, dynamic>>[
            FileRecord(
              path: '/tmp/upload/a.txt',
              fileName: 'a.txt',
              sizeBytes: 3,
              createdAt: DateTime.utc(2026, 1, 1),
            ).toJson(),
          ],
        },
      ),
    );

    final payload = await restorer.parseAndValidate(archive);
    final counts = await restorer.buildStagingDatabase(
      payload: payload,
      databaseId: 'db-1',
      publishId: 'publish-1',
    );

    expect(counts.conversations, 1);
    expect(counts.messages, 2);
    expect(counts.parts, 1);
    expect(counts.providerArtifacts, 1);
    expect(counts.fileRecords, 1);
    expect(counts.workspaceBindings, 1);
    expect(counts.quarantined, 0);

    final probe = await probeDatabase(files.restoring);
    expect(probe.readable, isTrue);
    expect(probe.databaseId, 'db-1');
    expect(probe.publishId, 'publish-1');
    expect(probe.source, 'restore');
    expect(probe.state, 'complete_clean');
  });

  test('an injected row failure removes staging and never touches the target',
      () async {
    await createDatabase(
      files.database,
      databaseId: 'db-old',
      publishId: 'publish-old',
    );
    final before = await probeDatabase(files.database);
    final archive = await writeArchive(
      directory,
      chatsJson(
        conversations: <Conversation>[
          Conversation(id: 'c1', title: 'One'),
          Conversation(id: 'c2', title: 'Two'),
        ],
        messages: <ChatMessage>[
          message('m1', 'c1', 'hello'),
          message('m2', 'c2', 'world'),
        ],
      ),
    );
    final payload = await restorer.parseAndValidate(archive);
    ChatBackupRestorer.debugFailAfterConversations = 1;

    await expectLater(
      restorer.buildStagingDatabase(
        payload: payload,
        databaseId: 'db-old',
        publishId: 'publish-new',
      ),
      throwsA(isA<ChatRestoreException>()),
    );

    final after = await probeDatabase(files.database);
    expect(after.databaseId, before.databaseId);
    expect(after.publishId, before.publishId);
    expect(await files.restoring.exists(), isFalse);
  });

  test('publish preserves the old family and records its identity', () async {
    await createDatabase(
      files.database,
      databaseId: 'db-old',
      publishId: 'publish-old',
    );
    final archive = await writeArchive(
      directory,
      chatsJson(
        conversations: <Conversation>[
          Conversation(id: 'c1', title: 'One'),
        ],
        messages: <ChatMessage>[message('m1', 'c1', 'hello')],
      ),
    );
    final payload = await restorer.parseAndValidate(archive);
    await restorer.buildStagingDatabase(
      payload: payload,
      databaseId: 'db-old',
      publishId: 'publish-new',
    );

    final outcome = await restorer.publishStaging();

    expect(outcome.success, isTrue, reason: outcome.error);
    expect(outcome.publishId, 'publish-new');
    expect(outcome.previousDatabaseId, 'db-old');
    expect(outcome.previousPath, files.previous.path);
    expect((await probeDatabase(files.database)).databaseId, 'db-old');
    expect((await probeDatabase(files.database)).publishId, 'publish-new');
  });

  test('publisher recovery completes an injected publish failure', () async {
    await createDatabase(
      files.database,
      databaseId: 'db-old',
      publishId: 'publish-old',
    );
    final archive = await writeArchive(
      directory,
      chatsJson(
        conversations: <Conversation>[
          Conversation(id: 'c1', title: 'One'),
        ],
        messages: <ChatMessage>[message('m1', 'c1', 'hello')],
      ),
    );
    final payload = await restorer.parseAndValidate(archive);
    await restorer.buildStagingDatabase(
      payload: payload,
      databaseId: 'db-old',
      publishId: 'publish-new',
    );
    DatabaseFamilyPublisher.debugFailOnPublish = true;

    final outcome = await restorer.publishStaging();
    expect(outcome.success, isFalse);
    expect(await files.publishIntent.exists(), isTrue);
    expect(await files.database.exists(), isFalse);

    final publisher = DatabaseFamilyPublisher(files, appVersion: 'test');
    final recovery = await publisher.recoverIfNeeded();
    expect(recovery.failClosed, isFalse, reason: recovery.message);
    expect(recovery.resolved, isTrue);
    expect(await files.publishIntent.exists(), isFalse);
    final target = await probeDatabase(files.database);
    expect(target.publishId, 'publish-new');
    expect((await probeDatabase(files.previous)).databaseId, 'db-old');
  });

  test('restoring into an existing receipt reuses its database identity',
      () async {
    await createDatabase(
      files.database,
      databaseId: 'receipt-db',
      publishId: 'publish-old',
    );
    await files.writeJsonAtomically(
      files.installationReceipt,
      <String, dynamic>{
        'format': 1,
        'version': 1,
        'databaseId': 'receipt-db',
        'schemaVersion': currentChatSchemaVersion,
        'source': 'fresh',
        'state': 'complete_clean',
        'installedAtUtc': DateTime.now().toUtc().toIso8601String(),
        'appVersion': 'test',
      },
    );
    final archive = await writeArchive(
      directory,
      chatsJson(
        conversations: <Conversation>[
          Conversation(id: 'c1', title: 'One'),
        ],
        messages: <ChatMessage>[message('m1', 'c1', 'hello')],
      ),
    );

    final payload = await restorer.parseAndValidate(archive);
    final databaseId = await restorer.resolveDatabaseId();
    expect(databaseId, 'receipt-db');
    await restorer.buildStagingDatabase(
      payload: payload,
      databaseId: databaseId,
      publishId: 'publish-new',
    );
    final outcome = await restorer.publishStaging();
    expect(outcome.success, isTrue, reason: outcome.error);

    final target = await probeDatabase(files.database);
    expect(target.databaseId, 'receipt-db');
    expect(target.publishId, 'publish-new');

    final admission = await DatabaseInstallationGate(
      directory: directory,
      appVersion: 'test',
    ).ensureReady();
    expect(admission.isReady, isTrue, reason: admission.message);
    expect(admission.probe?.databaseId, 'receipt-db');
    expect(await files.previous.exists(), isFalse);
  });

  test('a pre-existing .previous never becomes the rollback family',
      () async {
    await createDatabase(
      files.previous,
      databaseId: 'db-old',
      publishId: 'publish-ancient',
    );
    await createDatabase(
      files.database,
      databaseId: 'db-old',
      publishId: 'publish-old',
    );
    final oldTarget = await probeDatabase(files.database);
    final archive = await writeArchive(
      directory,
      chatsJson(
        conversations: <Conversation>[
          Conversation(id: 'c1', title: 'One'),
        ],
        messages: <ChatMessage>[message('m1', 'c1', 'hello')],
      ),
    );
    final payload = await restorer.parseAndValidate(archive);
    await restorer.buildStagingDatabase(
      payload: payload,
      databaseId: 'db-old',
      publishId: 'publish-new',
    );

    final outcome = await restorer.publishStaging();

    expect(outcome.success, isTrue, reason: outcome.error);
    expect(outcome.previousPath, isNull);
    expect(outcome.replacedPath, endsWith('.replaced-publish-new'));
    expect((await probeDatabase(files.previous)).publishId, 'publish-ancient');

    final resolved = await restorer.resolvePreservedFamily(
      oldTarget,
      'publish-new',
    );
    expect(resolved.path, endsWith('.replaced-publish-new'));
    expect(resolved.databaseId, 'db-old');
  });

  test('containsChats distinguishes chat backups from settings-only archives',
      () async {
    final chats = await writeArchive(
      directory,
      chatsJson(
        conversations: <Conversation>[
          Conversation(id: 'c1', title: 'One'),
        ],
        messages: <ChatMessage>[message('m1', 'c1', 'hello')],
      ),
    );
    expect(await ChatBackupRestorer.containsChats(chats), isTrue);

    final settingsOnly = await writeArchive(
      directory,
      <String, dynamic>{},
      settings: <String, dynamic>{'k': 'v'},
      includeChats: false,
    );
    expect(await ChatBackupRestorer.containsChats(settingsOnly), isFalse);
  });
}
