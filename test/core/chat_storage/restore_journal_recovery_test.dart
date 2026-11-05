import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/core/models/chat_message.dart';
import 'package:OmniChat/core/models/conversation.dart';
import 'package:OmniChat/core/services/chat/storage/app_database.dart';
import 'package:OmniChat/core/services/chat/storage/chat_database_files.dart';
import 'package:OmniChat/core/services/chat/storage/chat_repository.dart';
import 'package:OmniChat/core/services/chat/storage/restore_journal.dart';
import 'package:OmniChat/core/services/chat/storage/restore_journal_recovery.dart';

void main() {
  late Directory directory;
  late ChatDatabaseFiles files;
  late RestoreJournalRecovery recovery;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'omnichat_restore_recovery_',
    );
    files = ChatDatabaseFiles(directory);
    recovery = RestoreJournalRecovery(
      directory: directory,
      appVersion: 'test',
    );
  });

  tearDown(() async {
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
        await repo.restoreConversation(conversation, const <ChatMessage>[]);
      }
      await db.checkpointAndTruncate();
    } finally {
      await db.close();
    }
    await files.deleteSidecars(file);
  }

  test('no journal is a no-op', () async {
    final result = await recovery.recoverIfNeeded();
    expect(result.resolved, isTrue);
    expect(result.failClosed, isFalse);
  });

  test('a corrupt journal fails closed and deletes nothing', () async {
    await createDatabase(
      files.database,
      databaseId: 'db-old',
      publishId: 'publish-old',
    );
    await files.restoreJournal.writeAsString('{broken');

    final result = await recovery.recoverIfNeeded();

    expect(result.failClosed, isTrue);
    expect(await files.restoreJournal.exists(), isTrue);
    expect((await probeDatabase(files.database)).databaseId, 'db-old');
  });

  test('files swapped before publish are rolled back to the old directories',
      () async {
    await createDatabase(
      files.database,
      databaseId: 'db-old',
      publishId: 'publish-old',
    );
    final liveUpload = Directory('${directory.path}/upload');
    final previousUpload = Directory(
      '${directory.path}/.previous-restore-restore-files/upload',
    );
    final stagingUpload = Directory(
      '${directory.path}/restore_staging_restore-files/upload',
    );
    await liveUpload.create(recursive: true);
    await File('${liveUpload.path}/new.txt').writeAsString('new');
    await previousUpload.create(recursive: true);
    await File('${previousUpload.path}/old.txt').writeAsString('old');
    await stagingUpload.create(recursive: true);

    final journal = await RestoreJournal.begin(
      files: files,
      restoreId: 'restore-files',
      archiveHash: 'hash',
      publishId: 'publish-new',
      stagingDatabaseId: 'db-old',
    );
    await journal.setFileEntries(<String, RestoreJournalEntry>{
      'upload': RestoreJournalEntry(
        livePath: liveUpload.path,
        stagingPath: stagingUpload.path,
        previousPath: previousUpload.path,
        staged: true,
        swapped: true,
      ),
    });
    await journal.updateStage(RestoreJournal.stageFilesSwapped);

    final result = await recovery.recoverIfNeeded();

    expect(result.failClosed, isFalse, reason: result.message);
    expect(await File('${liveUpload.path}/old.txt').exists(), isTrue);
    expect(await File('${liveUpload.path}/new.txt').exists(), isFalse);
    expect(await previousUpload.exists(), isFalse);
    expect(await stagingUpload.exists(), isFalse);
    expect(await files.restoreJournal.exists(), isFalse);
    expect((await probeDatabase(files.database)).databaseId, 'db-old');
  });

  test('a committed target finishes cleanup without touching the new database',
      () async {
    await createDatabase(
      files.previous,
      databaseId: 'db-old',
      publishId: 'publish-old',
    );
    await createDatabase(
      files.database,
      databaseId: 'db-new',
      publishId: 'publish-new',
      conversations: <Conversation>[
        Conversation(id: 'c1', title: 'Restored'),
      ],
    );
    final journal = await RestoreJournal.begin(
      files: files,
      restoreId: 'restore-committed',
      archiveHash: 'hash',
      publishId: 'publish-new',
      stagingDatabaseId: 'db-new',
    );
    await journal.notePublished(
      preservedPath: files.previous.path,
      preservedDatabaseId: 'db-old',
    );
    await journal.updateStage(RestoreJournal.stageDbPublished);

    final result = await recovery.recoverIfNeeded();

    expect(result.failClosed, isFalse, reason: result.message);
    expect(await files.restoreJournal.exists(), isFalse);
    expect(await files.previous.exists(), isFalse);
    final target = await probeDatabase(files.database);
    expect(target.publishId, 'publish-new');
    expect(target.databaseId, 'db-new');
  });

  test('rolling back reinstates only the identity-matching preserved family',
      () async {
    await createDatabase(
      files.previous,
      databaseId: 'db-old',
      publishId: 'publish-old',
    );
    await files.database.writeAsBytes(List<int>.filled(128, 7));

    final journal = await RestoreJournal.begin(
      files: files,
      restoreId: 'restore-rollback',
      archiveHash: 'hash',
      publishId: 'publish-new',
      stagingDatabaseId: 'db-new',
    );
    await journal.notePublished(
      preservedPath: files.previous.path,
      preservedDatabaseId: 'db-old',
    );
    await journal.updateStage(RestoreJournal.stageRollingBack);

    final result = await recovery.recoverIfNeeded();

    expect(result.failClosed, isFalse, reason: result.message);
    expect(await files.restoreJournal.exists(), isFalse);
    final target = await probeDatabase(files.database);
    expect(target.readable, isTrue);
    expect(target.databaseId, 'db-old');
    expect(target.publishId, 'publish-old');
    expect(
      await File('${files.database.path}.failed-restore-restore-rollback')
          .exists(),
      isTrue,
    );
  });

  test('rollback fails closed when the preserved identity does not match',
      () async {
    await createDatabase(
      files.previous,
      databaseId: 'unrelated-db',
      publishId: 'publish-old',
    );
    await files.database.writeAsBytes(List<int>.filled(128, 7));

    final journal = await RestoreJournal.begin(
      files: files,
      restoreId: 'restore-bad-id',
      archiveHash: 'hash',
      publishId: 'publish-new',
      stagingDatabaseId: 'db-new',
    );
    await journal.notePublished(
      preservedPath: files.previous.path,
      preservedDatabaseId: 'db-old',
    );
    await journal.updateStage(RestoreJournal.stageRollingBack);

    final result = await recovery.recoverIfNeeded();

    expect(result.failClosed, isTrue);
    expect(await files.restoreJournal.exists(), isTrue);
    expect(await files.previous.exists(), isTrue);
    expect(await files.database.exists(), isTrue);
  });

  test('a committed restore fails closed when the preserved identity is unknown',
      () async {
    await createDatabase(
      files.previous,
      databaseId: 'unrelated-db',
      publishId: 'publish-old',
    );
    await createDatabase(
      files.database,
      databaseId: 'db-new',
      publishId: 'publish-new',
    );

    final journal = await RestoreJournal.begin(
      files: files,
      restoreId: 'restore-unknown-preserved',
      archiveHash: 'hash',
      publishId: 'publish-new',
      stagingDatabaseId: 'db-new',
    );
    await journal.notePublished(
      preservedPath: files.previous.path,
      preservedDatabaseId: 'db-old',
    );
    await journal.updateStage(RestoreJournal.stageDbPublished);

    final result = await recovery.recoverIfNeeded();

    expect(result.failClosed, isTrue);
    expect(await files.restoreJournal.exists(), isTrue);
    expect(await files.previous.exists(), isTrue);
    expect((await probeDatabase(files.database)).publishId, 'publish-new');
  });
}
