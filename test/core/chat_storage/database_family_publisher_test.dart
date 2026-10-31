import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:OmniChat/core/services/chat/storage/app_database.dart';
import 'package:OmniChat/core/services/chat/storage/chat_database_files.dart';
import 'package:OmniChat/core/services/chat/storage/chat_repository.dart';
import 'package:OmniChat/core/services/chat/storage/database_family_publisher.dart';

void main() {
  late Directory directory;
  late ChatDatabaseFiles files;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('omnichat_publish_');
    files = ChatDatabaseFiles(directory);
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
    String state = 'complete_clean',
  }) async {
    await files.deleteFamily(file);
    final db = AppDatabase.open(
      file,
      background: false,
      synchronousFull: true,
    );
    try {
      await db.verifyHealthy();
      await ChatRepository(db).putMigrationMeta(<String, String>{
        'database_id': databaseId,
        'publish_id': publishId,
        'source': 'hive',
        'state': state,
        'installed_schema_version': '$currentChatSchemaVersion',
        'installed_by_app_version': 'test',
        'quarantine_count': '0',
      });
      await db.checkpointAndTruncate();
    } finally {
      await db.close();
    }
    await files.deleteSidecars(file);
  }

  Future<void> writeIntent({
    required String publishId,
    required String tempDatabaseId,
    String? previousDatabaseId,
    int? previousSchemaVersion,
    int? previousSizeBytes,
    String? previousSha256,
    String stage = 'prepared',
  }) {
    return files.writeJsonAtomically(files.publishIntent, <String, dynamic>{
      'format': 1,
      'operation': 'migrate',
      'tempPath': files.migrating.path,
      'targetPath': files.database.path,
      'previousPath': files.previous.path,
      'publishId': publishId,
      'tempDatabaseId': tempDatabaseId,
      'targetDatabaseId': null,
      'previousDatabaseId': previousDatabaseId,
      'previousSchemaVersion': previousSchemaVersion,
      'previousSizeBytes': previousSizeBytes,
      'previousSha256': previousSha256,
      'targetSchemaVersion': currentChatSchemaVersion,
      'tempSizeBytes': null,
      'tempSha256': null,
      'stage': stage,
      'createdAtUtc': DateTime.now().toUtc().toIso8601String(),
      'updatedAtUtc': DateTime.now().toUtc().toIso8601String(),
      'appVersion': 'test',
    });
  }

  test('publishing preserves the old family as .previous', () async {
    await createDatabase(
      files.database,
      databaseId: 'old-db',
      publishId: 'old-publish',
    );
    await createDatabase(
      files.migrating,
      databaseId: 'new-db',
      publishId: 'new-publish',
    );

    final publisher = DatabaseFamilyPublisher(files, appVersion: 'test');
    final outcome = await publisher.publish(
      temp: files.migrating,
      operation: 'migrate',
    );

    expect(outcome.success, isTrue, reason: outcome.error);
    expect(await files.publishIntent.exists(), isFalse);
    expect(await files.migrating.exists(), isFalse);
    expect(await files.previous.exists(), isTrue);

    final target = await probeDatabase(files.database);
    expect(target.databaseId, 'new-db');
    expect(target.publishId, 'new-publish');
    final previous = await probeDatabase(files.previous);
    expect(previous.databaseId, 'old-db');
  });

  test('recovery completes a prepared publish with a valid temp', () async {
    await createDatabase(
      files.database,
      databaseId: 'old-db',
      publishId: 'old-publish',
    );
    await createDatabase(
      files.migrating,
      databaseId: 'new-db',
      publishId: 'new-publish',
    );
    await writeIntent(
      publishId: 'new-publish',
      tempDatabaseId: 'new-db',
      previousDatabaseId: 'old-db',
    );

    final publisher = DatabaseFamilyPublisher(files, appVersion: 'test');
    final recovery = await publisher.recoverIfNeeded();
    expect(recovery.resolved, isTrue, reason: recovery.message);
    expect(recovery.failClosed, isFalse);
    expect(await files.publishIntent.exists(), isFalse);
    expect(await files.previous.exists(), isTrue);

    final target = await probeDatabase(files.database);
    expect(target.publishId, 'new-publish');
    expect((await probeDatabase(files.previous)).databaseId, 'old-db');
  });

  test('recovery keeps an intact target when the temp is corrupt', () async {
    await createDatabase(
      files.database,
      databaseId: 'old-db',
      publishId: 'old-publish',
    );
    await files.migrating.writeAsBytes(List<int>.filled(128, 9));
    await writeIntent(
      publishId: 'new-publish',
      tempDatabaseId: 'new-db',
      previousDatabaseId: 'old-db',
    );

    final publisher = DatabaseFamilyPublisher(files, appVersion: 'test');
    final recovery = await publisher.recoverIfNeeded();
    expect(recovery.resolved, isTrue, reason: recovery.message);
    expect(recovery.restartRequired, isTrue);
    expect(await files.migrating.exists(), isFalse);
    expect(await files.publishIntent.exists(), isFalse);

    final target = await probeDatabase(files.database);
    expect(target.databaseId, 'old-db');
    expect(target.publishId, 'old-publish');
  });

  test('recovery treats a target matching neither id as split-brain', () async {
    await createDatabase(
      files.database,
      databaseId: 'unrelated-db',
      publishId: 'unrelated-publish',
    );
    await createDatabase(
      files.migrating,
      databaseId: 'new-db',
      publishId: 'new-publish',
    );
    await writeIntent(
      publishId: 'new-publish',
      tempDatabaseId: 'new-db',
      previousDatabaseId: 'old-db',
    );

    final publisher = DatabaseFamilyPublisher(files, appVersion: 'test');
    final recovery = await publisher.recoverIfNeeded();
    expect(recovery.failClosed, isTrue);
    expect(await files.database.exists(), isTrue);
    expect(await files.migrating.exists(), isTrue);
    expect(await files.publishIntent.exists(), isTrue);
    expect(
      (await probeDatabase(files.database)).databaseId,
      'unrelated-db',
    );
  });

  test('recovery removes the temp when the target already carries the publish id',
      () async {
    await createDatabase(
      files.database,
      databaseId: 'new-db',
      publishId: 'new-publish',
    );
    await createDatabase(
      files.migrating,
      databaseId: 'new-db',
      publishId: 'new-publish',
    );
    await writeIntent(
      publishId: 'new-publish',
      tempDatabaseId: 'new-db',
      previousDatabaseId: 'old-db',
    );

    final publisher = DatabaseFamilyPublisher(files, appVersion: 'test');
    final recovery = await publisher.recoverIfNeeded();
    expect(recovery.resolved, isTrue, reason: recovery.message);
    expect(await files.migrating.exists(), isFalse);
    expect(await files.publishIntent.exists(), isFalse);
    expect(await files.database.exists(), isTrue);
  });

  test('publishing over a corrupt target quarantines it and completes',
      () async {
    await files.database.writeAsBytes(List<int>.filled(128, 9));
    await createDatabase(
      files.migrating,
      databaseId: 'new-db',
      publishId: 'new-publish',
    );

    final publisher = DatabaseFamilyPublisher(files, appVersion: 'test');
    final outcome = await publisher.publish(
      temp: files.migrating,
      operation: 'migrate',
    );

    expect(outcome.success, isTrue, reason: outcome.error);
    expect((await probeDatabase(files.database)).databaseId, 'new-db');
    expect(await files.previous.exists(), isFalse);
    final quarantined = await directory
        .list()
        .where((entry) => entry.path.contains('.corrupt-'))
        .toList();
    expect(quarantined, isNotEmpty);
  });

  test('publishing never attaches orphan target sidecars to the new database',
      () async {
    await files.wal.writeAsBytes(List<int>.filled(64, 7));
    await files.shm.writeAsBytes(List<int>.filled(64, 7));
    await createDatabase(
      files.migrating,
      databaseId: 'new-db',
      publishId: 'new-publish',
    );

    final publisher = DatabaseFamilyPublisher(files, appVersion: 'test');
    final outcome = await publisher.publish(
      temp: files.migrating,
      operation: 'migrate',
    );

    expect(outcome.success, isTrue, reason: outcome.error);
    expect(await files.wal.exists(), isFalse);
    expect(await files.shm.exists(), isFalse);
    expect((await probeDatabase(files.database)).databaseId, 'new-db');
    final quarantined = await directory
        .list()
        .where((entry) => entry.path.contains('.orphan-'))
        .toList();
    expect(quarantined, isNotEmpty);
  });

  test('recovery does not restore a .previous that no longer matches',
      () async {
    await createDatabase(
      files.previous,
      databaseId: 'old-db',
      publishId: 'old-publish',
    );
    await writeIntent(
      publishId: 'new-publish',
      tempDatabaseId: 'new-db',
      previousDatabaseId: 'old-db',
      previousSchemaVersion: 1,
      previousSizeBytes: await files.previous.length(),
      previousSha256: 'not-the-recorded-hash',
    );

    final publisher = DatabaseFamilyPublisher(files, appVersion: 'test');
    final recovery = await publisher.recoverIfNeeded();

    expect(recovery.failClosed, isTrue);
    expect(await files.previous.exists(), isTrue);
    expect(await files.database.exists(), isFalse);
    expect(await files.publishIntent.exists(), isTrue);
  });

  test('recovery refuses to replace a newer target schema', () async {
    final handle = sqlite3.open(files.database.path);
    handle.execute('CREATE TABLE unrelated (id INTEGER PRIMARY KEY)');
    handle.execute('PRAGMA user_version = 99');
    handle.close();
    await createDatabase(
      files.migrating,
      databaseId: 'new-db',
      publishId: 'new-publish',
    );
    await writeIntent(
      publishId: 'new-publish',
      tempDatabaseId: 'new-db',
    );

    final publisher = DatabaseFamilyPublisher(files, appVersion: 'test');
    final recovery = await publisher.recoverIfNeeded();

    expect(recovery.failClosed, isTrue);
    expect(recovery.message, contains('never been published'));
    expect((await probeDatabase(files.database)).userVersion, 99);
    expect(await files.migrating.exists(), isTrue);
    expect(await files.publishIntent.exists(), isTrue);
  });

  test('refuses to publish a temp without identity or completion', () async {
    await createDatabase(
      files.migrating,
      databaseId: '',
      publishId: '',
      state: 'importing',
    );

    final publisher = DatabaseFamilyPublisher(files, appVersion: 'test');
    final outcome = await publisher.publish(
      temp: files.migrating,
      operation: 'migrate',
    );
    expect(outcome.success, isFalse);
    expect(await files.publishIntent.exists(), isFalse);
    expect(await files.database.exists(), isFalse);
  });

  test('a malformed publish intent fails closed without deletion', () async {
    await createDatabase(
      files.database,
      databaseId: 'old-db',
      publishId: 'old-publish',
    );
    await files.publishIntent.writeAsString('{not-json');

    final publisher = DatabaseFamilyPublisher(files, appVersion: 'test');
    final recovery = await publisher.recoverIfNeeded();
    expect(recovery.failClosed, isTrue);
    expect(await files.database.exists(), isTrue);
    expect(await files.publishIntent.exists(), isTrue);
  });
}
