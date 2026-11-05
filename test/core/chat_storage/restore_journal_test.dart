import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/core/services/chat/storage/chat_database_files.dart';
import 'package:OmniChat/core/services/chat/storage/restore_journal.dart';

void main() {
  late Directory directory;
  late ChatDatabaseFiles files;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'omnichat_restore_journal_',
    );
    files = ChatDatabaseFiles(directory);
  });

  tearDown(() async {
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  test('journal round-trips every commit stage atomically', () async {
    final journal = await RestoreJournal.begin(
      files: files,
      restoreId: 'restore-1',
      archiveHash: 'archive-hash',
      publishId: 'publish-1',
      stagingDatabaseId: 'db-1',
    );
    expect(await files.restoreJournal.exists(), isTrue);
    expect(journal.stage, RestoreJournal.stageStaged);

    await journal.setFileEntries(<String, RestoreJournalEntry>{
      'upload': RestoreJournalEntry(
        livePath: '${directory.path}/upload',
        stagingPath: '${directory.path}/restore_staging_restore-1/upload',
        previousPath: '${directory.path}/.previous-restore-restore-1/upload',
        staged: true,
      ),
    });
    await journal.markFileSwapped('upload');
    await journal.notePublished(
      preservedPath: '${directory.path}/chat_v2.sqlite.previous',
      preservedDatabaseId: 'old-db',
    );
    await journal.updateStage(RestoreJournal.stageDbPublished);
    await journal.updateStage(RestoreJournal.stageLiveVerified);
    await journal.updateStage(RestoreJournal.stageSettingsApplied);
    await journal.done();

    final reopened = (await RestoreJournal.read(files))!;
    expect(reopened.restoreId, 'restore-1');
    expect(reopened.publishId, 'publish-1');
    expect(reopened.stagingDatabaseId, 'db-1');
    expect(reopened.preservedPath, endsWith('chat_v2.sqlite.previous'));
    expect(reopened.preservedDatabaseId, 'old-db');
    expect(reopened.stage, RestoreJournal.stageDone);
    expect(reopened.fileEntries['upload']!.staged, isTrue);
    expect(reopened.fileEntries['upload']!.swapped, isTrue);

    await reopened.markFileRolledBack('upload');
    final rolledBack = (await RestoreJournal.read(files))!;
    expect(rolledBack.fileEntries['upload']!.rolledBack, isTrue);

    await rolledBack.discard();
    expect(await files.restoreJournal.exists(), isFalse);
    expect(await RestoreJournal.read(files), isNull);
  });

  test('a malformed journal fails closed and is never deleted', () async {
    await files.restoreJournal.writeAsString('{not-json');
    await expectLater(
      RestoreJournal.read(files),
      throwsA(isA<RestoreJournalCorruptException>()),
    );
    expect(await files.restoreJournal.exists(), isTrue);
  });

  test('an unknown stage fails closed', () async {
    await files.writeJsonAtomically(files.restoreJournal, <String, dynamic>{
      'format': 1,
      'restoreId': 'restore-1',
      'publishId': 'publish-1',
      'stagingDatabaseId': 'db-1',
      'stage': 'mystery-stage',
    });
    await expectLater(
      RestoreJournal.read(files),
      throwsA(isA<RestoreJournalCorruptException>()),
    );
    expect(await files.restoreJournal.exists(), isTrue);
  });

  test('file entries without paths are rejected', () async {
    await files.writeJsonAtomically(files.restoreJournal, <String, dynamic>{
      'format': 1,
      'restoreId': 'restore-1',
      'publishId': 'publish-1',
      'stagingDatabaseId': 'db-1',
      'stage': RestoreJournal.stageStaged,
      'fileSwapPaths': <String, dynamic>{
        'upload': <String, dynamic>{'live': '', 'staging': '', 'previous': ''},
      },
    });
    await expectLater(
      RestoreJournal.read(files),
      throwsA(isA<RestoreJournalCorruptException>()),
    );
  });

  test('journal JSON is written with the documented identity fields', () async {
    await RestoreJournal.begin(
      files: files,
      restoreId: 'restore-2',
      archiveHash: 'hash-2',
      publishId: 'publish-2',
      stagingDatabaseId: 'db-2',
    );
    final raw = jsonDecode(await files.restoreJournal.readAsString())
        as Map<String, dynamic>;
    expect(raw['format'], RestoreJournal.formatVersion);
    expect(raw['restoreId'], 'restore-2');
    expect(raw['archiveHash'], 'hash-2');
    expect(raw['publishId'], 'publish-2');
    expect(raw['stagingDatabaseId'], 'db-2');
    expect(raw['stage'], RestoreJournal.stageStaged);
    expect(raw['createdAtUtc'], isNotNull);
  });
}
