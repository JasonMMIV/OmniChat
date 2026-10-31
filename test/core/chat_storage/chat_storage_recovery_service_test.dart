import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/services/chat/storage/app_database.dart';
import 'package:OmniChat/core/services/chat/storage/chat_database_files.dart';
import 'package:OmniChat/core/services/chat/storage/chat_storage_recovery_service.dart';
import 'package:OmniChat/core/services/chat/storage/database_installation_gate.dart';

void main() {
  late Directory directory;
  late ChatDatabaseFiles files;
  late ChatStorageRecoveryService recovery;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('omnichat_recovery_');
    files = ChatDatabaseFiles(directory);
    recovery = ChatStorageRecoveryService(
      directory: directory,
      appVersion: 'test',
    );
  });

  tearDown(() async {
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  Future<void> seedRecordedMissingInstallation() async {
    await files
        .writeJsonAtomically(files.installationReceipt, <String, dynamic>{
          'format': 1,
          'version': 1,
          'databaseId': 'lost-database',
          'schemaVersion': currentChatSchemaVersion,
          'source': 'hive',
          'state': 'complete_clean',
          'installedAtUtc': DateTime.now().toUtc().toIso8601String(),
          'appVersion': 'test',
        });
  }

  test('reset creates a fresh reset database and preserves Hive', () async {
    await seedRecordedMissingInstallation();
    final hiveFile = File('${directory.path}/messages.hive');
    await hiveFile.writeAsBytes(<int>[0xde, 0xad, 0xbe, 0xef]);
    final before = await hiveFile.readAsBytes();

    await recovery.resetToFreshDatabase();

    expect(await files.database.exists(), isTrue);
    expect(await files.legacyImportDisabled.exists(), isTrue);
    expect(await hiveFile.readAsBytes(), before);
    expect(await files.resetMarker.exists(), isFalse);

    final admitted = await DatabaseInstallationGate(
      directory: directory,
      appVersion: 'test',
    ).ensureReady();
    expect(admitted.state, ChatInstallationState.ready);
    expect(admitted.source, 'reset');
  });

  test('rebuild clears SQLite markers so Hive migration can run', () async {
    await seedRecordedMissingInstallation();
    await files.writeJsonAtomically(
      files.legacyImportDisabled,
      <String, dynamic>{'format': 1, 'reason': 'reset'},
    );
    final hiveFile = File('${directory.path}/conversations.hive');
    await hiveFile.writeAsBytes(<int>[1, 2, 3]);
    final before = await hiveFile.readAsBytes();

    expect(recovery.hasLegacyHive, isTrue);
    await recovery.clearForLegacyImport();

    expect(await files.installationReceipt.exists(), isFalse);
    expect(await files.legacyImportDisabled.exists(), isFalse);
    expect(await files.database.exists(), isFalse);
    expect(await hiveFile.readAsBytes(), before);

    final admitted = await DatabaseInstallationGate(
      directory: directory,
      appVersion: 'test',
    ).ensureReady();
    expect(admitted.state, ChatInstallationState.needsMigration);
  });

  test('rebuild may replace an empty reset database', () async {
    await seedRecordedMissingInstallation();
    await File('${directory.path}/conversations.hive').writeAsBytes(<int>[1]);
    await recovery.resetToFreshDatabase();
    expect(await files.database.exists(), isTrue);

    await recovery.clearForLegacyImport();

    expect(await files.database.exists(), isFalse);
    final admitted = await DatabaseInstallationGate(
      directory: directory,
      appVersion: 'test',
    ).ensureReady();
    expect(admitted.state, ChatInstallationState.needsMigration);
  });

  test('rebuild refuses to destroy a database that reappeared', () async {
    await seedRecordedMissingInstallation();
    await File('${directory.path}/conversations.hive').writeAsBytes(<int>[1]);
    await File('${directory.path}/chat_v2.sqlite').writeAsBytes(<int>[1]);

    await expectLater(
      recovery.clearForLegacyImport(),
      throwsA(isA<ChatStorageRecoveryException>()),
    );
    expect(await files.database.exists(), isTrue);
  });

  test(
    'backup validation accepts chats.json and rejects other archives',
    () async {
      final good = File('${directory.path}/good.zip');
      final goodZip = ZipFileEncoder()..create(good.path);
      final chats = utf8.encode('{"version":3,"conversations":[]}');
      goodZip.addArchiveFile(ArchiveFile('chats.json', chats.length, chats));
      await goodZip.close();
      await recovery.validateBackup(good);

      final settingsOnly = File('${directory.path}/settings-only.zip');
      final settingsZip = ZipFileEncoder()..create(settingsOnly.path);
      final settings = utf8.encode('{"theme":"dark"}');
      settingsZip.addArchiveFile(
        ArchiveFile('settings.json', settings.length, settings),
      );
      await settingsZip.close();
      await expectLater(
        recovery.validateBackup(settingsOnly),
        throwsA(isA<ChatStorageRecoveryException>()),
      );

      final corrupt = File('${directory.path}/corrupt.zip');
      await corrupt.writeAsBytes(<int>[1, 2, 3]);
      await expectLater(
        recovery.validateBackup(corrupt),
        throwsA(isA<ChatStorageRecoveryException>()),
      );

      final malformed = File('${directory.path}/malformed.zip');
      final malformedZip = ZipFileEncoder()..create(malformed.path);
      final badChats = utf8.encode('{not-json');
      malformedZip.addArchiveFile(
        ArchiveFile('chats.json', badChats.length, badChats),
      );
      await malformedZip.close();
      await expectLater(
        recovery.validateBackup(malformed),
        throwsA(isA<ChatStorageRecoveryException>()),
      );
    },
  );
}
