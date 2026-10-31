import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/services/chat/storage/app_database.dart';
import 'package:OmniChat/core/services/chat/storage/chat_database_files.dart';
import 'package:OmniChat/core/services/chat/storage/chat_repository.dart';
import 'package:OmniChat/core/services/chat/storage/legacy_retirement_service.dart';

void main() {
  late Directory directory;
  late ChatDatabaseFiles files;
  late LegacyRetirementService service;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('omnichat_retirement_');
    files = ChatDatabaseFiles(directory);
    service = LegacyRetirementService(directory: directory, appVersion: 'test');
  });

  tearDown(() async {
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  Future<void> createDatabase({
    String source = 'hive',
    String state = 'complete_clean',
    int quarantine = 0,
  }) async {
    final db = AppDatabase.open(files.database, background: false);
    try {
      await ChatRepository(db).putMigrationMeta({
        'database_id': 'db-1',
        'source': source,
        'state': state,
        'installed_schema_version': '$currentChatSchemaVersion',
        'installed_by_app_version': 'test',
        'quarantine_count': '$quarantine',
      });
      await db.checkpointAndTruncate();
    } finally {
      await db.close();
    }
  }

  Future<void> createLegacyFiles() async {
    await File(
      '${directory.path}/conversations.hive',
    ).writeAsString('conversations');
    await File('${directory.path}/messages.hive').writeAsString('messages');
    await File(
      '${directory.path}/tool_events_v1.hive',
    ).writeAsString('tool-events');
    await File(
      '${directory.path}/tool_events_v1.hive.lock',
    ).writeAsString('lock');
  }

  test('a clean Hive migration can be exported and deleted', () async {
    await createDatabase();
    await createLegacyFiles();

    final status = await service.inspect();
    expect(status.state, LegacyRetirementState.none);
    expect(status.canDelete, isTrue);
    expect(status.requiresExport, isFalse);
    expect(status.artifacts, hasLength(4));
    expect(status.totalBytes, greaterThan(0));

    final exportDir = await Directory(
      '${directory.path}/export',
    ).create(recursive: true);
    final manifest = await service.exportToDirectory(exportDir);
    expect(await manifest.exists(), isTrue);
    expect((await service.inspect()).hasValidExport, isTrue);
    final decoded = jsonDecode(await manifest.readAsString()) as Map;
    expect(decoded['databaseId'], 'db-1');
    expect((decoded['artifacts'] as List), hasLength(4));
    for (final entry in decoded['artifacts'] as List) {
      final map = entry as Map;
      final exported = File('${exportDir.path}/${map['name']}');
      expect(await exported.exists(), isTrue);
      final digest = await sha256.bind(exported.openRead()).first;
      expect(digest.toString(), map['sha256']);
    }

    final after = await service.delete(confirmed: true);
    expect(after.state, LegacyRetirementState.completed);
    expect(await File('${directory.path}/messages.hive').exists(), isFalse);
    expect(
      await File('${directory.path}/tool_events_v1.hive.lock').exists(),
      isFalse,
    );
    expect(await files.legacyRetirement.exists(), isTrue);
    expect(await files.database.exists(), isTrue);
  });

  test('complete_with_issues requires an export before deletion', () async {
    await createDatabase(state: 'complete_with_issues', quarantine: 1);
    await createLegacyFiles();

    final status = await service.inspect();
    expect(status.canDelete, isFalse);
    expect(status.canDeleteAfterExport, isTrue);
    expect(status.requiresExport, isTrue);
    expect(status.quarantineCount, 1);

    await expectLater(
      service.delete(confirmed: true),
      throwsA(isA<LegacyRetirementException>()),
    );
    expect(await File('${directory.path}/messages.hive').exists(), isTrue);

    final exportDir = await Directory(
      '${directory.path}/export',
    ).create(recursive: true);
    await service.exportToDirectory(exportDir);
    expect((await service.inspect()).hasValidExport, isTrue);

    await expectLater(service.delete(confirmed: true), completes);
    expect(await File('${directory.path}/messages.hive').exists(), isFalse);
  });

  test('a changed file aborts a resumed cleanup without deleting it', () async {
    await createLegacyFiles();
    final file = File('${directory.path}/messages.hive');
    final stat = await file.stat();
    await files.writeJsonAtomically(files.legacyRetirement, {
      'format': LegacyRetirementService.markerFormatName,
      'version': LegacyRetirementService.markerFormat,
      'state': 'deleting',
      'requestedAtUtc': DateTime.now().toUtc().toIso8601String(),
      'databaseId': 'db-1',
      'artifacts': [
        {
          'name': 'messages.hive',
          'sizeBytes': stat.size + 1,
          'modifiedAtMs': stat.modified.millisecondsSinceEpoch,
          'sha256': (await sha256.bind(file.openRead()).first).toString(),
        },
      ],
    });
    await createDatabase();

    final status = await service.inspect();
    expect(status.state, LegacyRetirementState.deleting);
    expect(status.canResume, isTrue);
    await expectLater(
      service.resume(),
      throwsA(isA<LegacyRetirementException>()),
    );
    expect(await file.exists(), isTrue);
    final marker = await files.readJson(files.legacyRetirement);
    expect(marker?['state'], 'deleting');
  });

  test('a tampered export receipt is rejected', () async {
    await createDatabase();
    await createLegacyFiles();
    final exportDir = await Directory(
      '${directory.path}/export',
    ).create(recursive: true);
    await service.exportToDirectory(exportDir);
    final receipt = await files.readJson(files.legacyExportReceipt);
    expect(receipt, isNotNull);
    receipt!['format'] = 'other';
    await files.writeJsonAtomically(files.legacyExportReceipt, receipt);

    expect((await service.inspect()).hasValidExport, isFalse);
  });

  test(
    'content that preserves size and mtime still fails the export hash check',
    () async {
      await createDatabase(state: 'complete_with_issues', quarantine: 1);
      await createLegacyFiles();
      final exportDir = await Directory(
        '${directory.path}/export',
      ).create(recursive: true);
      await service.exportToDirectory(exportDir);

      final file = File('${directory.path}/tool_events_v1.hive');
      final stat = await file.stat();
      final original = await file.readAsString();
      // Same byte length, different content.
      await file.writeAsString(
        original.toUpperCase() == original
            ? original.toLowerCase()
            : original.toUpperCase(),
      );
      await file.setLastModified(stat.modified);

      // Size/mtime still match, so the shallow receipt check passes.
      final status = await service.inspect();
      expect(status.hasValidExport, isTrue);

      // The delete path hashes the source and rejects the mismatched export.
      await expectLater(
        service.delete(confirmed: true),
        throwsA(isA<LegacyRetirementException>()),
      );
      expect(await file.exists(), isTrue);
    },
  );

  test('a file added after the confirmed inventory aborts cleanup', () async {
    await createDatabase();
    await createLegacyFiles();
    final confirmed = (await service.inspect()).artifacts;

    await File(
      '${directory.path}/message_file_records_v1.hive',
    ).writeAsString('late');
    await expectLater(
      service.delete(confirmed: true, expectedArtifacts: confirmed),
      throwsA(isA<LegacyRetirementException>()),
    );
    expect(await File('${directory.path}/messages.hive').exists(), isTrue);
    expect(
      await File('${directory.path}/message_file_records_v1.hive').exists(),
      isTrue,
    );
  });

  test('a completed marker can be reset when new files appear', () async {
    await createLegacyFiles();
    await files.writeJsonAtomically(files.legacyRetirement, {
      'format': LegacyRetirementService.markerFormatName,
      'version': LegacyRetirementService.markerFormat,
      'state': 'completed',
      'requestedAtUtc': DateTime.now().toUtc().toIso8601String(),
      'completedAtUtc': DateTime.now().toUtc().toIso8601String(),
      'databaseId': 'db-1',
      'artifacts': <Object>[],
    });
    await createDatabase();

    final status = await service.inspect();
    expect(status.state, LegacyRetirementState.completed);
    expect(status.canDelete, isFalse);

    await service.resetCompletedMarker();
    final next = await service.inspect();
    expect(next.state, LegacyRetirementState.none);
    expect(next.canDelete, isTrue);
    expect(await File('${directory.path}/messages.hive').exists(), isTrue);
  });

  test('a malformed marker fails closed', () async {
    await createDatabase();
    await createLegacyFiles();
    await File(files.legacyRetirement.path).writeAsString('{not json');

    final status = await service.inspect();
    expect(status.error, isNotNull);
    expect(status.canDelete, isFalse);
    expect(status.canResume, isFalse);
    await expectLater(
      service.delete(confirmed: true),
      throwsA(isA<LegacyRetirementException>()),
    );
    expect(await File('${directory.path}/messages.hive').exists(), isTrue);
  });

  test(
    'never-imported files need export and the explicit discard flag',
    () async {
      await createDatabase(source: 'reset');
      await createLegacyFiles();

      final status = await service.inspect();
      expect(status.canDelete, isFalse);
      expect(status.canDiscardNeverMigrated, isTrue);
      expect(status.requiresExport, isTrue);

      await expectLater(
        service.delete(confirmed: true, discardNeverMigrated: true),
        throwsA(isA<LegacyRetirementException>()),
      );
      final exportDir = await Directory(
        '${directory.path}/export',
      ).create(recursive: true);
      await service.exportToDirectory(exportDir);
      await expectLater(
        service.delete(confirmed: true, discardNeverMigrated: true),
        completes,
      );
      expect(await File('${directory.path}/messages.hive').exists(), isFalse);
    },
  );

  test('a missing database refuses cleanup', () async {
    await createLegacyFiles();
    final status = await service.inspect();
    expect(status.canDelete, isFalse);
    expect(status.canDiscardNeverMigrated, isFalse);
    expect(status.blockReason, isNotNull);
    await expectLater(
      service.delete(confirmed: true),
      throwsA(isA<LegacyRetirementException>()),
    );
    expect(await File('${directory.path}/messages.hive').exists(), isTrue);
  });
}
