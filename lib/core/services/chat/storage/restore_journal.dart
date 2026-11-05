import 'dart:io';

import 'chat_database_files.dart';

/// A restore journal that cannot be parsed. Callers must fail closed: no file
/// is deleted and no progress is guessed.
class RestoreJournalCorruptException implements Exception {
  const RestoreJournalCorruptException(this.message);

  final String message;

  @override
  String toString() => 'RestoreJournalCorruptException: $message';
}

/// Per-directory file swap state. Paths are absolute so recovery never has to
/// re-derive the app data location.
class RestoreJournalEntry {
  const RestoreJournalEntry({
    required this.livePath,
    required this.stagingPath,
    required this.previousPath,
    this.staged = false,
    this.swapped = false,
    this.rolledBack = false,
  });

  final String livePath;
  final String stagingPath;
  final String previousPath;
  final bool staged;
  final bool swapped;
  final bool rolledBack;

  RestoreJournalEntry copyWith({
    bool? staged,
    bool? swapped,
    bool? rolledBack,
  }) {
    return RestoreJournalEntry(
      livePath: livePath,
      stagingPath: stagingPath,
      previousPath: previousPath,
      staged: staged ?? this.staged,
      swapped: swapped ?? this.swapped,
      rolledBack: rolledBack ?? this.rolledBack,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'live': livePath,
    'staging': stagingPath,
    'previous': previousPath,
    'staged': staged,
    'swapped': swapped,
    'rolledBack': rolledBack,
  };

  factory RestoreJournalEntry.fromJson(Map<String, dynamic> json) {
    final live = json['live']?.toString() ?? '';
    final staging = json['staging']?.toString() ?? '';
    final previous = json['previous']?.toString() ?? '';
    if (live.isEmpty || staging.isEmpty || previous.isEmpty) {
      throw const RestoreJournalCorruptException(
        'A restore journal file entry is missing its paths.',
      );
    }
    return RestoreJournalEntry(
      livePath: live,
      stagingPath: staging,
      previousPath: previous,
      staged: json['staged'] == true,
      swapped: json['swapped'] == true,
      rolledBack: json['rolledBack'] == true,
    );
  }
}

/// Durable record of a transactional restore (§2.2), written with
/// [ChatDatabaseFiles.writeJsonAtomically] on every transition.
///
/// The stage is a hint, never the sole truth: recovery probes the live target's
/// `publish_id`/`database_id`, the journal's recorded preserved family, and the
/// file markers before completing or rolling back.
class RestoreJournal {
  RestoreJournal._(this.files, this._data);

  final ChatDatabaseFiles files;
  final Map<String, dynamic> _data;

  static const int formatVersion = 1;

  static const String stageStaged = 'staged';
  static const String stageFilesStaged = 'files-staged';
  static const String stageFilesSwapped = 'files-swapped';
  static const String stageDbPublished = 'db-published';
  static const String stageLiveVerified = 'live-verified';
  static const String stageSettingsApplied = 'settings-applied';
  static const String stageDone = 'done';

  /// The publisher could not decide whether the new database is live. Every
  /// file is retained for the next startup/overlay.
  static const String stagePublishUnresolved = 'publish-unresolved';

  /// The commit point was crossed but verification failed; DB and files must
  /// be rolled back together.
  static const String stageRollingBack = 'rolling-back';

  static const Set<String> knownStages = <String>{
    stageStaged,
    stageFilesStaged,
    stageFilesSwapped,
    stageDbPublished,
    stageLiveVerified,
    stageSettingsApplied,
    stageDone,
    stagePublishUnresolved,
    stageRollingBack,
  };

  String get restoreId => _data['restoreId']?.toString() ?? '';
  String get archiveHash => _data['archiveHash']?.toString() ?? '';
  String get publishId => _data['publishId']?.toString() ?? '';
  String get stagingDatabaseId =>
      _data['stagingDatabaseId']?.toString() ?? '';
  String get stage => _data['stage']?.toString() ?? '';
  String? get preservedPath {
    final value = _data['preservedPath']?.toString();
    return value == null || value.isEmpty ? null : value;
  }

  String? get preservedDatabaseId {
    final value = _data['preservedDatabaseId']?.toString();
    return value == null || value.isEmpty ? null : value;
  }

  String? get settingsSnapshotPath {
    final value = _data['settingsSnapshotPath']?.toString();
    return value == null || value.isEmpty ? null : value;
  }

  String? get settingsPendingPath {
    final value = _data['settingsPendingPath']?.toString();
    return value == null || value.isEmpty ? null : value;
  }

  bool get isBeforeCommit =>
      stage == stageStaged ||
      stage == stageFilesStaged ||
      stage == stageFilesSwapped;

  bool get isAfterCommit =>
      stage == stageDbPublished ||
      stage == stageLiveVerified ||
      stage == stageSettingsApplied ||
      stage == stageDone;

  Map<String, RestoreJournalEntry> get fileEntries {
    final raw = _data['fileSwapPaths'];
    if (raw is! Map) return const <String, RestoreJournalEntry>{};
    final result = <String, RestoreJournalEntry>{};
    for (final entry in raw.entries) {
      final value = entry.value;
      if (value is Map) {
        result[entry.key.toString()] = RestoreJournalEntry.fromJson(
          value.cast<String, dynamic>(),
        );
      }
    }
    return result;
  }

  Map<String, dynamic> toJson() => Map<String, dynamic>.from(_data);

  static Future<RestoreJournal> begin({
    required ChatDatabaseFiles files,
    required String restoreId,
    required String archiveHash,
    required String publishId,
    required String stagingDatabaseId,
  }) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final journal = RestoreJournal._(files, <String, dynamic>{
      'format': formatVersion,
      'restoreId': restoreId,
      'archiveHash': archiveHash,
      'publishId': publishId,
      'stagingDatabaseId': stagingDatabaseId,
      'preservedPath': null,
      'preservedDatabaseId': null,
      'stage': stageStaged,
      'fileSwapPaths': <String, dynamic>{},
      'settingsSnapshotPath': null,
      'settingsPendingPath': null,
      'createdAtUtc': now,
      'updatedAtUtc': now,
    });
    await journal._write();
    return journal;
  }

  /// Reads a journal. Returns null when none exists, throws
  /// [RestoreJournalCorruptException] when it exists but cannot be trusted.
  static Future<RestoreJournal?> read(ChatDatabaseFiles files) async {
    final file = files.restoreJournal;
    if (!await file.exists()) return null;
    final data = await files.readJson(file);
    if (data == null) {
      throw const RestoreJournalCorruptException(
        'The restore journal is not valid JSON.',
      );
    }
    for (final key in const <String>[
      'restoreId',
      'publishId',
      'stagingDatabaseId',
      'stage',
    ]) {
      final value = data[key]?.toString() ?? '';
      if (value.isEmpty) {
        throw RestoreJournalCorruptException(
          'The restore journal is missing "$key".',
        );
      }
    }
    final stage = data['stage'].toString();
    if (!knownStages.contains(stage)) {
      throw RestoreJournalCorruptException(
        'The restore journal has an unknown stage "$stage".',
      );
    }
    final rawEntries = data['fileSwapPaths'];
    if (rawEntries != null && rawEntries is! Map) {
      throw const RestoreJournalCorruptException(
        'The restore journal has an invalid file swap map.',
      );
    }
    final journal = RestoreJournal._(files, data);
    // Validate every per-directory entry now, so a corrupt journal fails
    // closed before recovery starts renaming directories.
    Map<String, RestoreJournalEntry> entries;
    try {
      entries = journal.fileEntries;
    } catch (error) {
      throw RestoreJournalCorruptException(
        'The restore journal has an invalid file swap entry: $error',
      );
    }
    if (rawEntries is Map && entries.length != rawEntries.length) {
      throw const RestoreJournalCorruptException(
        'The restore journal has an invalid file swap entry.',
      );
    }
    return journal;
  }

  Future<void> updateStage(String stage, {Map<String, dynamic>? extra}) async {
    if (!knownStages.contains(stage)) {
      throw ArgumentError.value(stage, 'stage');
    }
    _data['stage'] = stage;
    if (extra != null) _data.addAll(extra);
    await _write();
  }

  Future<void> setFileEntries(
    Map<String, RestoreJournalEntry> entries,
  ) async {
    _data['fileSwapPaths'] = <String, dynamic>{
      for (final entry in entries.entries) entry.key: entry.value.toJson(),
    };
    await _write();
  }

  Future<void> markFileSwapped(String name) async {
    _updateEntry(name, (entry) => entry.copyWith(swapped: true));
    await _write();
  }

  Future<void> markFileRolledBack(String name) async {
    _updateEntry(name, (entry) => entry.copyWith(rolledBack: true));
    await _write();
  }

  void _updateEntry(
    String name,
    RestoreJournalEntry Function(RestoreJournalEntry) update,
  ) {
    final raw = _data['fileSwapPaths'];
    if (raw is! Map) return;
    final value = raw[name];
    if (value is! Map) return;
    raw[name] = update(
      RestoreJournalEntry.fromJson(value.cast<String, dynamic>()),
    ).toJson();
  }

  Future<void> notePublished({
    required String? preservedPath,
    required String? preservedDatabaseId,
  }) async {
    _data['preservedPath'] = preservedPath;
    _data['preservedDatabaseId'] = preservedDatabaseId;
    _data['publishedAtUtc'] = DateTime.now().toUtc().toIso8601String();
    await _write();
  }

  Future<void> noteSettingsFiles({
    required String? snapshotPath,
    required String? pendingPath,
  }) async {
    _data['settingsSnapshotPath'] = snapshotPath;
    _data['settingsPendingPath'] = pendingPath;
    await _write();
  }

  Future<void> done() async {
    _data['stage'] = stageDone;
    await _write();
  }

  Future<void> discard() async {
    try {
      if (await files.restoreJournal.exists()) {
        await files.restoreJournal.delete();
      }
    } catch (error) {
      // Leaving the journal in place is fail-closed: the next startup will
      // finish or roll back again instead of guessing.
      throw RestoreJournalCorruptException(
        'The restore journal could not be removed: $error',
      );
    }
  }

  Future<void> _write() async {
    _data['updatedAtUtc'] = DateTime.now().toUtc().toIso8601String();
    await files.writeJsonAtomically(files.restoreJournal, _data);
  }
}

/// Best-effort logging-safe summary. Never includes message content.
String restoreJournalSummary(RestoreJournal journal) {
  return 'restoreId=${journal.restoreId} stage=${journal.stage} '
      'publishId=${journal.publishId}';
}

/// True when the journal file exists. Used by the installation gate to keep
/// recovery material until the restore is resolved.
Future<bool> hasRestoreJournal(ChatDatabaseFiles files) =>
    files.restoreJournal.exists();

/// Convenience for tests and diagnostics.
Future<File> restoreJournalFile(ChatDatabaseFiles files) async =>
    files.restoreJournal;
