import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:OmniChat/core/services/chat/storage/chat_database_files.dart';
import 'package:OmniChat/core/services/chat/storage/database_installation_gate.dart';

void main() {
  late Directory directory;
  late ChatDatabaseFiles files;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('omnichat_gate_');
    files = ChatDatabaseFiles(directory);
  });

  tearDown(() async {
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  Future<ChatInstallationResult> runGate() {
    return DatabaseInstallationGate(
      directory: directory,
      appVersion: 'test',
    ).ensureReady();
  }

  test('fresh install creates meta and survives a second launch', () async {
    final first = await runGate();
    expect(first.state, ChatInstallationState.ready);
    expect(first.source, 'fresh');
    expect(await files.database.exists(), isTrue);
    expect(await files.installationReceipt.exists(), isTrue);

    final probe = await probeDatabase(files.database);
    expect(probe.source, 'fresh');
    expect(probe.state, 'complete_clean');
    expect(probe.userVersion, 1);
    expect(probe.databaseId, isNotEmpty);

    final second = await runGate();
    expect(second.state, ChatInstallationState.ready);
    expect(second.source, 'fresh');
  });

  test('Hive files with no database report needsMigration', () async {
    await File('${directory.path}/messages.hive').writeAsBytes([1, 2, 3]);

    final result = await runGate();
    expect(result.state, ChatInstallationState.needsMigration);
    expect(await files.database.exists(), isFalse);
  });

  test('zero-byte database without a receipt and with Hive starts migration',
      () async {
    await File('${directory.path}/conversations.hive').writeAsBytes([1]);
    await files.database.writeAsBytes(const <int>[]);

    final result = await runGate();
    expect(result.state, ChatInstallationState.needsMigration);
    expect(await files.database.exists(), isFalse);
  });

  test('zero-byte database after an installation fails closed', () async {
    final fresh = await runGate();
    expect(fresh.state, ChatInstallationState.ready);
    await files.database.writeAsBytes(const <int>[]);

    final result = await runGate();
    expect(result.state, ChatInstallationState.failClosed);
    expect(await files.database.exists(), isTrue);
  });

  test('missing database with an installation receipt is not recreated',
      () async {
    final fresh = await runGate();
    expect(fresh.state, ChatInstallationState.ready);
    await files.database.delete();
    await files.deleteSidecars(files.database);

    final result = await runGate();
    expect(result.state, ChatInstallationState.needsRestoreOrReset);
    expect(await files.database.exists(), isFalse);
  });

  test('newer schema fails closed and keeps the file', () async {
    final handle = sqlite3.open(files.database.path);
    handle.execute('CREATE TABLE unrelated (id INTEGER PRIMARY KEY)');
    handle.execute('PRAGMA user_version = 99');
    handle.close();

    final result = await runGate();
    expect(result.state, ChatInstallationState.failClosed);
    expect(result.message, contains('newer'));
    expect(await files.database.exists(), isTrue);

    final probe = await probeDatabase(files.database);
    expect(probe.userVersion, 99);
  });

  test('unpublished schema version fails closed without deletion', () async {
    final handle = sqlite3.open(files.database.path);
    handle.execute('CREATE TABLE unrelated (id INTEGER PRIMARY KEY)');
    handle.execute('PRAGMA user_version = 0');
    handle.close();

    final result = await runGate();
    expect(result.state, ChatInstallationState.failClosed);
    expect(result.message, contains('never shipped'));
    expect(await files.database.exists(), isTrue);
  });

  test('legacy import disabled + Hive + no database creates a reset DB',
      () async {
    await File('${directory.path}/messages.hive').writeAsBytes([1]);
    await files.writeJsonAtomically(files.legacyImportDisabled, {
      'format': 1,
      'reason': 'reset',
    });

    final result = await runGate();
    expect(result.state, ChatInstallationState.ready);
    expect(result.source, 'reset');
    expect(await files.legacyImportDisabled.exists(), isTrue);
    final probe = await probeDatabase(files.database);
    expect(probe.source, 'reset');
  });

  test('reset marker wipes SQLite but never Hive, then disables import',
      () async {
    await File('${directory.path}/messages.hive').writeAsBytes([7, 7, 7]);
    await File('${directory.path}/conversations.hive').writeAsBytes([8]);
    await files.resetMarker.writeAsString('reset');
    // A stale published database is removed by the explicit reset.
    final handle = sqlite3.open(files.database.path);
    handle.execute('CREATE TABLE stale (id INTEGER PRIMARY KEY)');
    handle.close();

    final result = await runGate();
    expect(result.state, ChatInstallationState.ready);
    expect(result.source, 'reset');
    expect(await files.resetMarker.exists(), isFalse);
    expect(await files.legacyImportDisabled.exists(), isTrue);
    expect(await File('${directory.path}/messages.hive').exists(), isTrue);
    expect(await File('${directory.path}/conversations.hive').exists(), isTrue);
    final probe = await probeDatabase(files.database);
    expect(probe.source, 'reset');
  });

  test('current schema with missing tables fails closed', () async {
    final handle = sqlite3.open(files.database.path);
    handle.execute('PRAGMA user_version = 1');
    handle.execute(
      'CREATE TABLE migration_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
    );
    handle.execute(
      'INSERT INTO migration_meta (key, value) VALUES '
      "('database_id', 'partial'), ('source', 'reset'), "
      "('state', 'complete_clean')",
    );
    handle.close();

    final result = await runGate();
    expect(result.state, ChatInstallationState.failClosed);
    expect(result.message, contains('Missing required tables'));
    expect(await files.database.exists(), isTrue);
  });

  test('legacy import disabled + database without identity fails closed',
      () async {
    await files.writeJsonAtomically(files.legacyImportDisabled, {
      'format': 1,
      'reason': 'reset',
    });
    final first = await runGate();
    expect(first.state, ChatInstallationState.ready);

    final handle = sqlite3.open(files.database.path);
    handle.execute(
      "UPDATE migration_meta SET value = '' WHERE key = 'database_id'",
    );
    handle.close();

    final result = await runGate();
    expect(result.state, ChatInstallationState.failClosed);
    expect(result.message, contains('installation metadata'));
    expect(await files.database.exists(), isTrue);
  });

  test('reset recovery recreates a post-reset database without identity',
      () async {
    await files.writeJsonAtomically(files.legacyImportDisabled, {
      'format': 1,
      'reason': 'reset',
    });
    final first = await runGate();
    expect(first.state, ChatInstallationState.ready);
    expect(first.source, 'reset');

    final handle = sqlite3.open(files.database.path);
    handle.execute(
      "UPDATE migration_meta SET value = '' WHERE key = 'database_id'",
    );
    handle.close();
    await files.resetMarker.writeAsString('reset');

    final result = await runGate();
    expect(result.state, ChatInstallationState.ready);
    expect(result.source, 'reset');
    final probe = await probeDatabase(files.database);
    expect(probe.databaseId, isNotEmpty);
    expect(await files.resetMarker.exists(), isFalse);
    expect(await files.legacyImportDisabled.exists(), isTrue);
  });

  test('sidecar/database identity mismatch fails closed', () async {
    final fresh = await runGate();
    expect(fresh.state, ChatInstallationState.ready);
    final receipt = await files.readJson(files.installationReceipt);
    receipt!['databaseId'] = 'someone-else';
    await files.writeJsonAtomically(files.installationReceipt, receipt);

    final result = await runGate();
    expect(result.state, ChatInstallationState.failClosed);
    expect(result.message, contains('disagree'));
  });

  test('a malformed installation receipt fails closed', () async {
    await files.installationReceipt.writeAsString('{not-json');
    final result = await runGate();
    expect(result.state, ChatInstallationState.failClosed);
    expect(await files.database.exists(), isFalse);
  });
}
