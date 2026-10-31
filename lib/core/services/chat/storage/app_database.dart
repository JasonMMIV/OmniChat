import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

part 'app_database.g.dart';

/// Initial SQLite schema version. Only bump together with a real migration in
/// `AppDatabase.migration` and a new entry in [publishedChatSchemaVersions].
const int currentChatSchemaVersion = 1;

/// Schema versions that have actually shipped. A database at any other
/// version is never opened by a normal (live) connection.
const Set<int> publishedChatSchemaVersions = <int>{currentChatSchemaVersion};

/// Thrown when a live connection sees a schema it must not migrate or open
/// implicitly. The installation gate owns upgrades, downgrades fail closed.
class ChatSchemaAdmissionException implements Exception {
  const ChatSchemaAdmissionException(this.message, {this.userVersion});

  final String message;
  final int? userVersion;

  @override
  String toString() => 'ChatSchemaAdmissionException: $message';
}

@DataClassName('ConversationRow')
@TableIndex(name: 'idx_conversations_updated_at', columns: {#updatedAtMs})
@TableIndex(
  name: 'idx_conversations_assistant_updated',
  columns: {#assistantId, #updatedAtMs},
)
class ConversationRows extends Table {
  @override
  String get tableName => 'conversations';

  TextColumn get id => text().named('id')();
  TextColumn get title => text().named('title')();
  IntColumn get createdAtMs => integer().named('created_at')();
  IntColumn get updatedAtMs => integer().named('updated_at')();
  TextColumn get assistantId => text().named('assistant_id').nullable()();
  BoolColumn get isPinned =>
      boolean().named('is_pinned').withDefault(const Constant(false))();
  IntColumn get truncateIndex =>
      integer().named('truncate_index').withDefault(const Constant(-1))();
  IntColumn get compactBeforeIndex =>
      integer().named('compact_before_index').withDefault(const Constant(-1))();
  TextColumn get summary => text().named('summary').nullable()();
  IntColumn get lastSummarizedMessageCount => integer()
      .named('last_summarized_message_count')
      .withDefault(const Constant(0))();
  TextColumn get mcpServerIdsJson => text()
      .named('mcp_server_ids_json')
      .withDefault(const Constant('[]'))();
  TextColumn get versionSelectionsJson => text()
      .named('version_selections_json')
      .withDefault(const Constant('{}'))();
  BoolColumn get isRecovered =>
      boolean().named('is_recovered').withDefault(const Constant(false))();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

@DataClassName('MessageRow')
@TableIndex(
  name: 'idx_messages_conversation_ordinal',
  unique: true,
  columns: {#conversationId, #ordinal},
)
@TableIndex(
  name: 'idx_messages_group_version',
  columns: {#conversationId, #groupId, #version},
)
@TableIndex(name: 'idx_messages_streaming', columns: {#isStreaming})
class MessageRows extends Table {
  @override
  String get tableName => 'messages';

  TextColumn get id => text().named('id')();
  TextColumn get conversationId => text()
      .named('conversation_id')
      .references(ConversationRows, #id, onDelete: KeyAction.cascade)();
  IntColumn get ordinal => integer().named('ordinal')();
  TextColumn get role => text().named('role')();
  TextColumn get content => text().named('content')();
  IntColumn get timestampMs => integer().named('timestamp')();
  TextColumn get modelId => text().named('model_id').nullable()();
  TextColumn get providerId => text().named('provider_id').nullable()();
  IntColumn get totalTokens => integer().named('total_tokens').nullable()();
  IntColumn get promptTokens => integer().named('prompt_tokens').nullable()();
  IntColumn get completionTokens =>
      integer().named('completion_tokens').nullable()();
  IntColumn get cachedTokens => integer().named('cached_tokens').nullable()();
  BoolColumn get isStreaming =>
      boolean().named('is_streaming').withDefault(const Constant(false))();
  TextColumn get reasoningText => text().named('reasoning_text').nullable()();
  IntColumn get reasoningStartAtMs =>
      integer().named('reasoning_start_at').nullable()();
  IntColumn get reasoningFinishedAtMs =>
      integer().named('reasoning_finished_at').nullable()();
  TextColumn get translation => text().named('translation').nullable()();
  TextColumn get reasoningSegmentsJson =>
      text().named('reasoning_segments_json').nullable()();
  TextColumn get groupId => text().named('group_id').nullable()();
  IntColumn get version => integer().named('version').withDefault(const Constant(0))();
  TextColumn get aiTeamProposalsJson =>
      text().named('ai_team_proposals_json').nullable()();
  IntColumn get processStartedAtMs =>
      integer().named('process_started_at').nullable()();
  IntColumn get processFinishedAtMs =>
      integer().named('process_finished_at').nullable()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};

  @override
  List<String> get customConstraints => const <String>[
    'UNIQUE (conversation_id, ordinal)',
  ];
}

@DataClassName('MessagePartRow')
@TableIndex(
  name: 'uidx_message_parts_message_ordinal',
  unique: true,
  columns: {#messageId, #ordinal},
)
@TableIndex(
  name: 'idx_message_parts_tool_call',
  columns: {#messageId, #toolCallId},
)
@TableIndex(
  name: 'idx_message_parts_tool_name',
  columns: {#messageId, #toolName, #ordinal},
)
class MessageParts extends Table {
  @override
  String get tableName => 'message_parts';

  IntColumn get partId =>
      integer().named('part_id').autoIncrement()();
  TextColumn get messageId => text()
      .named('message_id')
      .references(MessageRows, #id, onDelete: KeyAction.cascade)();
  IntColumn get ordinal => integer().named('ordinal')();
  TextColumn get kind => text().named('kind')();
  TextColumn get toolCallId => text().named('tool_call_id').nullable()();
  TextColumn get toolName => text().named('tool_name').nullable()();
  TextColumn get argumentsJson => text().named('arguments_json').nullable()();
  TextColumn get content => text().named('content').nullable()();
  TextColumn get status => text()
      .named('status')
      .withDefault(const Constant('pending'))();
  TextColumn get approvalState =>
      text().named('approval_state').nullable()();
  TextColumn get metadataJson => text().named('metadata_json').nullable()();
  IntColumn get createdAtMs => integer().named('created_at')();
  IntColumn get updatedAtMs => integer().named('updated_at')();

  @override
  List<String> get customConstraints => const <String>[
    'CHECK (status IN (\'pending\', \'completed\', \'interrupted\', \'denied\'))',
    'CHECK (status <> \'completed\' OR content IS NOT NULL)',
  ];
}

@DataClassName('ProviderArtifactRow')
class ProviderArtifacts extends Table {
  @override
  String get tableName => 'provider_artifacts';

  TextColumn get messageId => text()
      .named('message_id')
      .references(MessageRows, #id, onDelete: KeyAction.cascade)();
  TextColumn get kind => text().named('kind')();
  TextColumn get payload => text().named('payload')();
  IntColumn get createdAtMs => integer().named('created_at')();
  IntColumn get updatedAtMs => integer().named('updated_at')();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{messageId, kind};
}

@DataClassName('MessageFileRecordRow')
@TableIndex(
  name: 'idx_message_file_records_message',
  columns: {#messageId, #ordinal},
)
class MessageFileRecords extends Table {
  @override
  String get tableName => 'message_file_records';

  IntColumn get id => integer().named('id').autoIncrement()();
  TextColumn get messageId => text()
      .named('message_id')
      .references(MessageRows, #id, onDelete: KeyAction.cascade)();
  IntColumn get ordinal => integer().named('ordinal')();
  TextColumn get path => text().named('path')();
  TextColumn get fileName => text().named('file_name').nullable()();
  IntColumn get sizeBytes =>
      integer().named('size_bytes').withDefault(const Constant(0))();
  IntColumn get createdAtMs => integer().named('created_at')();

  @override
  List<String> get customConstraints => const <String>[
    'UNIQUE (message_id, path)',
  ];
}

@DataClassName('ConversationWorkspaceBindingRow')
class ConversationWorkspaceBindings extends Table {
  @override
  String get tableName => 'conversation_workspace_bindings';

  TextColumn get conversationId => text().named('conversation_id').references(
        ConversationRows,
        #id,
        onDelete: KeyAction.cascade,
      )();
  TextColumn get configJson => text().named('config_json')();
  IntColumn get updatedAtMs => integer().named('updated_at')();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{conversationId};
}

@DataClassName('MigrationMetaRow')
class MigrationMeta extends Table {
  @override
  String get tableName => 'migration_meta';

  TextColumn get key => text().named('key')();
  TextColumn get value => text().named('value')();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{key};
}

@DataClassName('LegacyQuarantineRow')
class LegacyQuarantine extends Table {
  @override
  String get tableName => 'legacy_quarantine';

  IntColumn get id => integer().named('id').autoIncrement()();
  TextColumn get sourceBox => text().named('source_box')();
  TextColumn get sourceKey => text().named('source_key').nullable()();
  TextColumn get payloadJson => text().named('payload_json').nullable()();
  TextColumn get payloadSha256 =>
      text().named('payload_sha256').nullable()();
  TextColumn get error => text().named('error')();
  IntColumn get createdAtMs => integer().named('created_at')();
}

@DriftDatabase(
  tables: [
    ConversationRows,
    MessageRows,
    MessageParts,
    ProviderArtifacts,
    MessageFileRecords,
    ConversationWorkspaceBindings,
    MigrationMeta,
    LegacyQuarantine,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.executor);

  @override
  int get schemaVersion => currentChatSchemaVersion;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
        },
        // Live connections never migrate. The DatabaseInstallationGate applies
        // published version steps against a working copy before publishing.
        onUpgrade: (m, from, to) async {
          throw ChatSchemaAdmissionException(
            'Implicit schema upgrade from $from to $to refused; '
            'run the installation gate first.',
            userVersion: from,
          );
        },
        // Downgrades are rejected by beforeOpen (and by the installation gate)
        // without deleting or recreating anything.
        beforeOpen: (details) async {
          await customStatement('PRAGMA foreign_keys = ON');
          if (details.wasCreated) return;
          final versionRow =
              await customSelect('PRAGMA user_version').getSingle();
          final version = versionRow.data.values.first as int?;
          if (version != currentChatSchemaVersion) {
            throw ChatSchemaAdmissionException(
              'Live connection refused schema $version; '
              'expected $currentChatSchemaVersion.',
              userVersion: version,
            );
          }
        },
      );

  /// Opens the chat database. [background] keeps SQLite work off the Flutter
  /// UI isolate in the app; tests may use the foreground executor.
  static AppDatabase open(
    File file, {
    bool background = true,
    bool synchronousFull = false,
    bool logStatements = false,
  }) {
    final setup = _pragmaSetup(synchronousFull: synchronousFull);
    final executor = background
        ? NativeDatabase.createInBackground(
            file,
            setup: setup,
            logStatements: logStatements,
          )
        : NativeDatabase(
            file,
            setup: setup,
            logStatements: logStatements,
          );
    return AppDatabase(executor);
  }

  static AppDatabase inMemory({bool synchronousFull = false}) {
    return AppDatabase(
      NativeDatabase.memory(
        setup: _pragmaSetup(synchronousFull: synchronousFull),
      ),
    );
  }

  static DatabaseSetup _pragmaSetup({required bool synchronousFull}) {
    return (db) {
      db.execute('PRAGMA journal_mode = WAL');
      db.execute('PRAGMA foreign_keys = ON');
      db.execute('PRAGMA busy_timeout = 5000');
      db.execute(
        'PRAGMA synchronous = ${synchronousFull ? 'FULL' : 'NORMAL'}',
      );
    };
  }

  static const Set<String> _requiredTables = <String>{
    'conversations',
    'messages',
    'message_parts',
    'provider_artifacts',
    'message_file_records',
    'conversation_workspace_bindings',
    'migration_meta',
    'legacy_quarantine',
  };

  /// Runs the startup verification: user_version, required tables, foreign
  /// keys, and integrity. A database carrying the current user_version but
  /// missing tables must never be admitted as healthy.
  Future<void> verifyHealthy() async {
    final versionRow = await customSelect('PRAGMA user_version').getSingle();
    final version = versionRow.data.values.first as int?;
    if (version != currentChatSchemaVersion) {
      throw ChatSchemaAdmissionException(
        'Database schema is $version, expected $currentChatSchemaVersion.',
        userVersion: version,
      );
    }
    final tableRows = await customSelect(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    ).get();
    final tableNames = <String>{
      for (final row in tableRows)
        if (row.data['name'] != null) row.data['name'].toString(),
    };
    final missing = _requiredTables.difference(tableNames);
    if (missing.isNotEmpty) {
      throw ChatSchemaAdmissionException(
        'Missing required tables: ${missing.join(', ')}.',
        userVersion: version,
      );
    }
    final integrity =
        await customSelect('PRAGMA integrity_check').getSingle();
    final integrityResult = integrity.data.values.first?.toString();
    if (integrityResult != 'ok') {
      throw ChatSchemaAdmissionException(
        'integrity_check failed: $integrityResult',
        userVersion: version,
      );
    }
    final fkRows = await customSelect('PRAGMA foreign_key_check').get();
    if (fkRows.isNotEmpty) {
      throw ChatSchemaAdmissionException(
        'foreign_key_check reported ${fkRows.length} row(s).',
        userVersion: version,
      );
    }
  }

  Future<int> readUserVersion() async {
    final row = await customSelect('PRAGMA user_version').getSingle();
    return (row.data.values.first as int?) ?? 0;
  }

  /// Checkpoints and (best effort) truncates the WAL so a database family can
  /// be moved/renamed as a unit.
  Future<void> checkpointAndTruncate() async {
    await customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
  }
}
