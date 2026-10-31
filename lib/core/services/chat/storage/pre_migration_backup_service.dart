import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;

import '../../../models/workspace_config.dart';
import 'chat_maintenance_lock.dart';
import 'database_installation_gate.dart';
import 'hive_chat_storage.dart';

class PreMigrationBackupException implements Exception {
  const PreMigrationBackupException(this.message);

  final String message;

  @override
  String toString() => 'PreMigrationBackupException: $message';
}

class PreMigrationBackupResult {
  const PreMigrationBackupResult({
    required this.archive,
    required this.manifest,
    required this.sourceBytes,
  });

  final File archive;
  final Map<String, dynamic> manifest;
  final int sourceBytes;
}

/// §8.2.2 pre-migration backup.
///
/// The archive is a disaster-recovery copy, not the normal in-app backup: it
/// contains the raw Hive box files plus a streamed `chats.json` rendered from
/// a **staging copy**, so the original Hive files remain byte-identical and
/// the migration can still use them. Every source is hashed before it is
/// added, the temp archive is flushed, and the finished zip is reopened and
/// checked before the atomic rename.
class PreMigrationBackupService {
  PreMigrationBackupService({
    required this.directory,
    required this.appVersion,
  });

  final Directory directory;
  final String appVersion;

  static const int formatVersion = 1;
  static const String format = 'omnichat.pre-migration-backup';

  Future<PreMigrationBackupResult> create({
    required Directory destination,
    void Function(String stage)? onProgress,
  }) async {
    final lock = await ChatMaintenanceLock.acquire(
      directory,
      purpose: 'pre-migration-backup',
    );
    try {
      return await _createLocked(destination, onProgress);
    } finally {
      await lock.release();
    }
  }

  Future<PreMigrationBackupResult> _createLocked(
    Directory destination,
    void Function(String stage)? onProgress,
  ) async {
    final artifacts = await _inventory();
    if (artifacts.isEmpty) {
      throw const PreMigrationBackupException(
        'No legacy chat files are available to back up.',
      );
    }
    if (!await destination.exists()) {
      await destination.create(recursive: true);
    }

    final tempDirectory = await Directory.systemTemp.createTemp(
      'omnichat_pre_migration_',
    );
    final timestamp = _timestamp(DateTime.now());
    final target = await _uniqueTarget(destination, timestamp);
    final partial = File('${target.path}.part');

    final zip = ZipFileEncoder();
    var zipClosed = false;
    try {
      final manifestArtifacts = <Map<String, dynamic>>[];
      zip.create(partial.path);
      var totalBytes = 0;

      onProgress?.call('copying-hive');
      for (final source in artifacts) {
        final stat = await source.stat();
        final digest = await sha256.bind(source.openRead()).first;
        totalBytes += stat.size;
        manifestArtifacts.add(<String, dynamic>{
          'name': p.basename(source.path),
          'sizeBytes': stat.size,
          'modifiedAtMs': stat.modified.millisecondsSinceEpoch,
          'sha256': digest.toString(),
        });
        await zip.addFile(
          source,
          'hive/${p.basename(source.path)}',
          ZipFileEncoder.store,
        );
      }

      // Hive is opened only on a staging copy. Some legacy open paths repair
      // sandbox paths/workspace bindings; applying that to the original would
      // violate the "Hive is byte-identical until retirement" contract.
      onProgress?.call('exporting-json');
      final staging = Directory(p.join(tempDirectory.path, 'hive'));
      await staging.create(recursive: true);
      for (final source in artifacts) {
        await source.copy(p.join(staging.path, p.basename(source.path)));
      }

      final chatJson = File(p.join(tempDirectory.path, 'chats.json'));
      final counts = await _writeChatsJson(staging, chatJson);
      await zip.addFile(chatJson, 'chats.json', ZipFileEncoder.store);

      final manifest = <String, dynamic>{
        'format': format,
        'version': formatVersion,
        'createdAtUtc': DateTime.now().toUtc().toIso8601String(),
        'appVersion': appVersion,
        'source': 'hive',
        'chatJson': 'chats.json',
        'chatCounts': counts,
        'sourceBytes': totalBytes,
        'artifacts': manifestArtifacts,
      };
      final manifestFile = File(p.join(tempDirectory.path, 'manifest.json'));
      await manifestFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(manifest),
        flush: true,
      );
      await zip.addFile(manifestFile, 'manifest.json', ZipFileEncoder.store);
      await zip.close();
      zipClosed = true;

      onProgress?.call('verifying-backup');
      await _verifyArchive(partial, manifestArtifacts);

      await partial.rename(target.path);
      return PreMigrationBackupResult(
        archive: target,
        manifest: manifest,
        sourceBytes: totalBytes,
      );
    } catch (error) {
      // A failure before `zip.close()` (for example the live-box guard) still
      // holds the partial file on Windows. Close the encoder before cleanup.
      if (!zipClosed) {
        try {
          await zip.close();
        } catch (_) {}
      }
      try {
        if (await partial.exists()) await partial.delete();
      } catch (_) {}
      if (error is PreMigrationBackupException) rethrow;
      throw PreMigrationBackupException('$error');
    } finally {
      try {
        if (await tempDirectory.exists()) {
          await tempDirectory.delete(recursive: true);
        }
      } catch (_) {}
    }
  }

  Future<List<File>> _inventory() async {
    final result = <File>[];
    // Lock companions are not data and would be rewritten by Hive on open.
    for (final file in chatHiveFiles(directory)) {
      if (!file.path.endsWith('.hive')) continue;
      final link = await FileSystemEntity.isLink(file.path);
      final stat = await file.stat();
      if (link || stat.type != FileSystemEntityType.file) {
        throw PreMigrationBackupException(
          'Legacy artifact ${p.basename(file.path)} is not a regular file.',
        );
      }
      result.add(file);
    }
    result.sort((a, b) => a.path.compareTo(b.path));
    return result;
  }

  Future<File> _uniqueTarget(Directory destination, String timestamp) async {
    var target = File(
      p.join(destination.path, 'omnichat-pre-migration-$timestamp.zip'),
    );
    var suffix = 1;
    while (await target.exists()) {
      target = File(
        p.join(
          destination.path,
          'omnichat-pre-migration-$timestamp-${suffix++}.zip',
        ),
      );
    }
    return target;
  }

  String _timestamp(DateTime value) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${value.year}${two(value.month)}${two(value.day)}-'
        '${two(value.hour)}${two(value.minute)}${two(value.second)}';
  }

  Future<Map<String, int>> _writeChatsJson(
    Directory staging,
    File output,
  ) async {
    // Hive's box registry is process-global and keyed by box name. If a live
    // fallback already holds these boxes, opening the staging path would bind
    // to the real files (and dispose would close the live backend). Never run
    // the export in that state; the next launch can retry safely.
    const boxNames = <String>[
      HiveChatStorage.conversationsBoxName,
      HiveChatStorage.messagesBoxName,
      HiveChatStorage.toolEventsBoxName,
      HiveChatStorage.conversationWorkspacesBoxName,
      HiveChatStorage.conversationWorkspaceBindingsBoxName,
      HiveChatStorage.messageFileRecordsBoxName,
    ];
    for (final name in boxNames) {
      if (Hive.isBoxOpen(name)) {
        throw PreMigrationBackupException(
          'The legacy chat store is currently open. Restart OmniChat to '
          'create the pre-migration backup safely.',
        );
      }
    }

    final storage = HiveChatStorage(directory: staging);
    try {
      await storage.initialize();
      final conversations = storage.listConversations();
      final toolEvents = <String, List<Map<String, dynamic>>>{};
      final signatures = <String, String>{};
      final fileRecords = <String, List<Map<String, dynamic>>>{};
      final workspaces = <String, String>{};
      final workspaceBindings = <String, Map<String, dynamic>>{};
      var messageCount = 0;
      var toolEventCount = 0;
      var fileRecordCount = 0;
      var signatureCount = 0;

      for (final conversation in conversations) {
        final config = storage.getWorkspaceConfig(conversation.id);
        if (config != null && config.mode != WorkspaceMode.inheritProject) {
          workspaceBindings[conversation.id] = config.toJson();
          if (config.mode == WorkspaceMode.custom && config.path != null) {
            workspaces[conversation.id] = config.path!;
          }
        }
        for (final message in storage.getMessages(conversation.id)) {
          messageCount++;
          if (message.role == 'assistant') {
            final events = storage.getToolEvents(message.id);
            if (events.isNotEmpty) {
              toolEvents[message.id] = events;
              toolEventCount += events.length;
            }
            final signature = storage.getGeminiThoughtSignature(message.id);
            if (signature != null && signature.isNotEmpty) {
              signatures[message.id] = signature;
              signatureCount++;
            }
          }
          final records = storage.getFileRecords(message.id);
          if (records.isNotEmpty) {
            fileRecords[message.id] = records
                .map((record) => record.toJson())
                .toList(growable: false);
            fileRecordCount += records.length;
          }
        }
      }

      final sink = output.openWrite();
      try {
        sink.write('{"version":3,"conversations":[');
        _writeJsonList(sink, conversations.map((c) => c.toJson()));
        sink.write('],"messages":[');
        _writeJsonList(
          sink,
          conversations.expand(
            (c) => storage.getMessages(c.id).map((m) => m.toJson()),
          ),
        );
        sink.write('],"toolEvents":');
        _writeJsonMapList(sink, toolEvents);
        sink.write(',"geminiThoughtSigs":');
        sink.write(jsonEncode(signatures));
        sink.write(',"fileRecords":');
        _writeJsonMapList(sink, fileRecords);
        sink.write(',"workspaces":');
        sink.write(jsonEncode(workspaces));
        sink.write(',"workspaceBindings":');
        sink.write(jsonEncode(workspaceBindings));
        sink.write('}');
        await sink.flush();
      } finally {
        await sink.close();
      }

      return <String, int>{
        'conversations': conversations.length,
        'messages': messageCount,
        'toolEvents': toolEventCount,
        'fileRecords': fileRecordCount,
        'signatures': signatureCount,
      };
    } finally {
      await storage.dispose();
      // Restore the process-global Hive home path after the staging export.
      Hive.init(directory.path);
    }
  }

  void _writeJsonList(StringSink sink, Iterable<Object?> values) {
    var first = true;
    for (final value in values) {
      if (!first) sink.write(',');
      first = false;
      sink.write(jsonEncode(value));
    }
  }

  void _writeJsonMapList(
    StringSink sink,
    Map<String, List<Map<String, dynamic>>> values,
  ) {
    sink.write('{');
    var first = true;
    for (final entry in values.entries) {
      if (!first) sink.write(',');
      first = false;
      sink.write(jsonEncode(entry.key));
      sink.write(':');
      sink.write(jsonEncode(entry.value));
    }
    sink.write('}');
  }

  Future<void> _verifyArchive(
    File archiveFile,
    List<Map<String, dynamic>> artifacts,
  ) async {
    final input = InputFileStream(archiveFile.path);
    try {
      final archive = ZipDecoder().decodeStream(input);
      final names = archive.files.map((f) => f.name).toSet();
      for (final artifact in artifacts) {
        final name = artifact['name'] as String;
        final entry = archive.find('hive/$name');
        if (entry == null || !entry.isFile) {
          throw PreMigrationBackupException(
            'Backup verification failed: hive/$name is missing.',
          );
        }
        final expected = artifact['sizeBytes'] as int;
        if (entry.size != expected) {
          throw PreMigrationBackupException(
            'Backup verification failed: hive/$name size changed.',
          );
        }
      }
      if (!names.contains('chats.json') || !names.contains('manifest.json')) {
        throw const PreMigrationBackupException(
          'Backup verification failed: chats.json or manifest.json is missing.',
        );
      }
      final chatEntry = archive.find('chats.json');
      if (chatEntry == null || chatEntry.size == 0) {
        throw const PreMigrationBackupException(
          'Backup verification failed: chats.json is empty.',
        );
      }
      final manifestEntry = archive.find('manifest.json');
      if (manifestEntry == null || manifestEntry.size == 0) {
        throw const PreMigrationBackupException(
          'Backup verification failed: manifest.json is empty.',
        );
      }
      final decoded = jsonDecode(utf8.decode(manifestEntry.content));
      if (decoded is! Map || decoded['format'] != format) {
        throw const PreMigrationBackupException(
          'Backup verification failed: manifest.json is invalid.',
        );
      }
    } finally {
      await input.close();
    }
  }
}
