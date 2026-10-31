// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_database.dart';

// ignore_for_file: type=lint
class $ConversationRowsTable extends ConversationRows
    with TableInfo<$ConversationRowsTable, ConversationRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ConversationRowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtMsMeta = const VerificationMeta(
    'createdAtMs',
  );
  @override
  late final GeneratedColumn<int> createdAtMs = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMsMeta = const VerificationMeta(
    'updatedAtMs',
  );
  @override
  late final GeneratedColumn<int> updatedAtMs = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _assistantIdMeta = const VerificationMeta(
    'assistantId',
  );
  @override
  late final GeneratedColumn<String> assistantId = GeneratedColumn<String>(
    'assistant_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _isPinnedMeta = const VerificationMeta(
    'isPinned',
  );
  @override
  late final GeneratedColumn<bool> isPinned = GeneratedColumn<bool>(
    'is_pinned',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_pinned" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _truncateIndexMeta = const VerificationMeta(
    'truncateIndex',
  );
  @override
  late final GeneratedColumn<int> truncateIndex = GeneratedColumn<int>(
    'truncate_index',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(-1),
  );
  static const VerificationMeta _compactBeforeIndexMeta =
      const VerificationMeta('compactBeforeIndex');
  @override
  late final GeneratedColumn<int> compactBeforeIndex = GeneratedColumn<int>(
    'compact_before_index',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(-1),
  );
  static const VerificationMeta _summaryMeta = const VerificationMeta(
    'summary',
  );
  @override
  late final GeneratedColumn<String> summary = GeneratedColumn<String>(
    'summary',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _lastSummarizedMessageCountMeta =
      const VerificationMeta('lastSummarizedMessageCount');
  @override
  late final GeneratedColumn<int> lastSummarizedMessageCount =
      GeneratedColumn<int>(
        'last_summarized_message_count',
        aliasedName,
        false,
        type: DriftSqlType.int,
        requiredDuringInsert: false,
        defaultValue: const Constant(0),
      );
  static const VerificationMeta _mcpServerIdsJsonMeta = const VerificationMeta(
    'mcpServerIdsJson',
  );
  @override
  late final GeneratedColumn<String> mcpServerIdsJson = GeneratedColumn<String>(
    'mcp_server_ids_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('[]'),
  );
  static const VerificationMeta _versionSelectionsJsonMeta =
      const VerificationMeta('versionSelectionsJson');
  @override
  late final GeneratedColumn<String> versionSelectionsJson =
      GeneratedColumn<String>(
        'version_selections_json',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
        defaultValue: const Constant('{}'),
      );
  static const VerificationMeta _isRecoveredMeta = const VerificationMeta(
    'isRecovered',
  );
  @override
  late final GeneratedColumn<bool> isRecovered = GeneratedColumn<bool>(
    'is_recovered',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_recovered" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    title,
    createdAtMs,
    updatedAtMs,
    assistantId,
    isPinned,
    truncateIndex,
    compactBeforeIndex,
    summary,
    lastSummarizedMessageCount,
    mcpServerIdsJson,
    versionSelectionsJson,
    isRecovered,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'conversations';
  @override
  VerificationContext validateIntegrity(
    Insertable<ConversationRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMsMeta,
        createdAtMs.isAcceptableOrUnknown(
          data['created_at']!,
          _createdAtMsMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_createdAtMsMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMsMeta,
        updatedAtMs.isAcceptableOrUnknown(
          data['updated_at']!,
          _updatedAtMsMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMsMeta);
    }
    if (data.containsKey('assistant_id')) {
      context.handle(
        _assistantIdMeta,
        assistantId.isAcceptableOrUnknown(
          data['assistant_id']!,
          _assistantIdMeta,
        ),
      );
    }
    if (data.containsKey('is_pinned')) {
      context.handle(
        _isPinnedMeta,
        isPinned.isAcceptableOrUnknown(data['is_pinned']!, _isPinnedMeta),
      );
    }
    if (data.containsKey('truncate_index')) {
      context.handle(
        _truncateIndexMeta,
        truncateIndex.isAcceptableOrUnknown(
          data['truncate_index']!,
          _truncateIndexMeta,
        ),
      );
    }
    if (data.containsKey('compact_before_index')) {
      context.handle(
        _compactBeforeIndexMeta,
        compactBeforeIndex.isAcceptableOrUnknown(
          data['compact_before_index']!,
          _compactBeforeIndexMeta,
        ),
      );
    }
    if (data.containsKey('summary')) {
      context.handle(
        _summaryMeta,
        summary.isAcceptableOrUnknown(data['summary']!, _summaryMeta),
      );
    }
    if (data.containsKey('last_summarized_message_count')) {
      context.handle(
        _lastSummarizedMessageCountMeta,
        lastSummarizedMessageCount.isAcceptableOrUnknown(
          data['last_summarized_message_count']!,
          _lastSummarizedMessageCountMeta,
        ),
      );
    }
    if (data.containsKey('mcp_server_ids_json')) {
      context.handle(
        _mcpServerIdsJsonMeta,
        mcpServerIdsJson.isAcceptableOrUnknown(
          data['mcp_server_ids_json']!,
          _mcpServerIdsJsonMeta,
        ),
      );
    }
    if (data.containsKey('version_selections_json')) {
      context.handle(
        _versionSelectionsJsonMeta,
        versionSelectionsJson.isAcceptableOrUnknown(
          data['version_selections_json']!,
          _versionSelectionsJsonMeta,
        ),
      );
    }
    if (data.containsKey('is_recovered')) {
      context.handle(
        _isRecoveredMeta,
        isRecovered.isAcceptableOrUnknown(
          data['is_recovered']!,
          _isRecoveredMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ConversationRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ConversationRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      createdAtMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAtMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
      assistantId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}assistant_id'],
      ),
      isPinned: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_pinned'],
      )!,
      truncateIndex: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}truncate_index'],
      )!,
      compactBeforeIndex: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}compact_before_index'],
      )!,
      summary: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}summary'],
      ),
      lastSummarizedMessageCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_summarized_message_count'],
      )!,
      mcpServerIdsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}mcp_server_ids_json'],
      )!,
      versionSelectionsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}version_selections_json'],
      )!,
      isRecovered: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_recovered'],
      )!,
    );
  }

  @override
  $ConversationRowsTable createAlias(String alias) {
    return $ConversationRowsTable(attachedDatabase, alias);
  }
}

class ConversationRow extends DataClass implements Insertable<ConversationRow> {
  final String id;
  final String title;
  final int createdAtMs;
  final int updatedAtMs;
  final String? assistantId;
  final bool isPinned;
  final int truncateIndex;
  final int compactBeforeIndex;
  final String? summary;
  final int lastSummarizedMessageCount;
  final String mcpServerIdsJson;
  final String versionSelectionsJson;
  final bool isRecovered;
  const ConversationRow({
    required this.id,
    required this.title,
    required this.createdAtMs,
    required this.updatedAtMs,
    this.assistantId,
    required this.isPinned,
    required this.truncateIndex,
    required this.compactBeforeIndex,
    this.summary,
    required this.lastSummarizedMessageCount,
    required this.mcpServerIdsJson,
    required this.versionSelectionsJson,
    required this.isRecovered,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['title'] = Variable<String>(title);
    map['created_at'] = Variable<int>(createdAtMs);
    map['updated_at'] = Variable<int>(updatedAtMs);
    if (!nullToAbsent || assistantId != null) {
      map['assistant_id'] = Variable<String>(assistantId);
    }
    map['is_pinned'] = Variable<bool>(isPinned);
    map['truncate_index'] = Variable<int>(truncateIndex);
    map['compact_before_index'] = Variable<int>(compactBeforeIndex);
    if (!nullToAbsent || summary != null) {
      map['summary'] = Variable<String>(summary);
    }
    map['last_summarized_message_count'] = Variable<int>(
      lastSummarizedMessageCount,
    );
    map['mcp_server_ids_json'] = Variable<String>(mcpServerIdsJson);
    map['version_selections_json'] = Variable<String>(versionSelectionsJson);
    map['is_recovered'] = Variable<bool>(isRecovered);
    return map;
  }

  ConversationRowsCompanion toCompanion(bool nullToAbsent) {
    return ConversationRowsCompanion(
      id: Value(id),
      title: Value(title),
      createdAtMs: Value(createdAtMs),
      updatedAtMs: Value(updatedAtMs),
      assistantId: assistantId == null && nullToAbsent
          ? const Value.absent()
          : Value(assistantId),
      isPinned: Value(isPinned),
      truncateIndex: Value(truncateIndex),
      compactBeforeIndex: Value(compactBeforeIndex),
      summary: summary == null && nullToAbsent
          ? const Value.absent()
          : Value(summary),
      lastSummarizedMessageCount: Value(lastSummarizedMessageCount),
      mcpServerIdsJson: Value(mcpServerIdsJson),
      versionSelectionsJson: Value(versionSelectionsJson),
      isRecovered: Value(isRecovered),
    );
  }

  factory ConversationRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ConversationRow(
      id: serializer.fromJson<String>(json['id']),
      title: serializer.fromJson<String>(json['title']),
      createdAtMs: serializer.fromJson<int>(json['createdAtMs']),
      updatedAtMs: serializer.fromJson<int>(json['updatedAtMs']),
      assistantId: serializer.fromJson<String?>(json['assistantId']),
      isPinned: serializer.fromJson<bool>(json['isPinned']),
      truncateIndex: serializer.fromJson<int>(json['truncateIndex']),
      compactBeforeIndex: serializer.fromJson<int>(json['compactBeforeIndex']),
      summary: serializer.fromJson<String?>(json['summary']),
      lastSummarizedMessageCount: serializer.fromJson<int>(
        json['lastSummarizedMessageCount'],
      ),
      mcpServerIdsJson: serializer.fromJson<String>(json['mcpServerIdsJson']),
      versionSelectionsJson: serializer.fromJson<String>(
        json['versionSelectionsJson'],
      ),
      isRecovered: serializer.fromJson<bool>(json['isRecovered']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'title': serializer.toJson<String>(title),
      'createdAtMs': serializer.toJson<int>(createdAtMs),
      'updatedAtMs': serializer.toJson<int>(updatedAtMs),
      'assistantId': serializer.toJson<String?>(assistantId),
      'isPinned': serializer.toJson<bool>(isPinned),
      'truncateIndex': serializer.toJson<int>(truncateIndex),
      'compactBeforeIndex': serializer.toJson<int>(compactBeforeIndex),
      'summary': serializer.toJson<String?>(summary),
      'lastSummarizedMessageCount': serializer.toJson<int>(
        lastSummarizedMessageCount,
      ),
      'mcpServerIdsJson': serializer.toJson<String>(mcpServerIdsJson),
      'versionSelectionsJson': serializer.toJson<String>(versionSelectionsJson),
      'isRecovered': serializer.toJson<bool>(isRecovered),
    };
  }

  ConversationRow copyWith({
    String? id,
    String? title,
    int? createdAtMs,
    int? updatedAtMs,
    Value<String?> assistantId = const Value.absent(),
    bool? isPinned,
    int? truncateIndex,
    int? compactBeforeIndex,
    Value<String?> summary = const Value.absent(),
    int? lastSummarizedMessageCount,
    String? mcpServerIdsJson,
    String? versionSelectionsJson,
    bool? isRecovered,
  }) => ConversationRow(
    id: id ?? this.id,
    title: title ?? this.title,
    createdAtMs: createdAtMs ?? this.createdAtMs,
    updatedAtMs: updatedAtMs ?? this.updatedAtMs,
    assistantId: assistantId.present ? assistantId.value : this.assistantId,
    isPinned: isPinned ?? this.isPinned,
    truncateIndex: truncateIndex ?? this.truncateIndex,
    compactBeforeIndex: compactBeforeIndex ?? this.compactBeforeIndex,
    summary: summary.present ? summary.value : this.summary,
    lastSummarizedMessageCount:
        lastSummarizedMessageCount ?? this.lastSummarizedMessageCount,
    mcpServerIdsJson: mcpServerIdsJson ?? this.mcpServerIdsJson,
    versionSelectionsJson: versionSelectionsJson ?? this.versionSelectionsJson,
    isRecovered: isRecovered ?? this.isRecovered,
  );
  ConversationRow copyWithCompanion(ConversationRowsCompanion data) {
    return ConversationRow(
      id: data.id.present ? data.id.value : this.id,
      title: data.title.present ? data.title.value : this.title,
      createdAtMs: data.createdAtMs.present
          ? data.createdAtMs.value
          : this.createdAtMs,
      updatedAtMs: data.updatedAtMs.present
          ? data.updatedAtMs.value
          : this.updatedAtMs,
      assistantId: data.assistantId.present
          ? data.assistantId.value
          : this.assistantId,
      isPinned: data.isPinned.present ? data.isPinned.value : this.isPinned,
      truncateIndex: data.truncateIndex.present
          ? data.truncateIndex.value
          : this.truncateIndex,
      compactBeforeIndex: data.compactBeforeIndex.present
          ? data.compactBeforeIndex.value
          : this.compactBeforeIndex,
      summary: data.summary.present ? data.summary.value : this.summary,
      lastSummarizedMessageCount: data.lastSummarizedMessageCount.present
          ? data.lastSummarizedMessageCount.value
          : this.lastSummarizedMessageCount,
      mcpServerIdsJson: data.mcpServerIdsJson.present
          ? data.mcpServerIdsJson.value
          : this.mcpServerIdsJson,
      versionSelectionsJson: data.versionSelectionsJson.present
          ? data.versionSelectionsJson.value
          : this.versionSelectionsJson,
      isRecovered: data.isRecovered.present
          ? data.isRecovered.value
          : this.isRecovered,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ConversationRow(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('createdAtMs: $createdAtMs, ')
          ..write('updatedAtMs: $updatedAtMs, ')
          ..write('assistantId: $assistantId, ')
          ..write('isPinned: $isPinned, ')
          ..write('truncateIndex: $truncateIndex, ')
          ..write('compactBeforeIndex: $compactBeforeIndex, ')
          ..write('summary: $summary, ')
          ..write('lastSummarizedMessageCount: $lastSummarizedMessageCount, ')
          ..write('mcpServerIdsJson: $mcpServerIdsJson, ')
          ..write('versionSelectionsJson: $versionSelectionsJson, ')
          ..write('isRecovered: $isRecovered')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    title,
    createdAtMs,
    updatedAtMs,
    assistantId,
    isPinned,
    truncateIndex,
    compactBeforeIndex,
    summary,
    lastSummarizedMessageCount,
    mcpServerIdsJson,
    versionSelectionsJson,
    isRecovered,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ConversationRow &&
          other.id == this.id &&
          other.title == this.title &&
          other.createdAtMs == this.createdAtMs &&
          other.updatedAtMs == this.updatedAtMs &&
          other.assistantId == this.assistantId &&
          other.isPinned == this.isPinned &&
          other.truncateIndex == this.truncateIndex &&
          other.compactBeforeIndex == this.compactBeforeIndex &&
          other.summary == this.summary &&
          other.lastSummarizedMessageCount == this.lastSummarizedMessageCount &&
          other.mcpServerIdsJson == this.mcpServerIdsJson &&
          other.versionSelectionsJson == this.versionSelectionsJson &&
          other.isRecovered == this.isRecovered);
}

class ConversationRowsCompanion extends UpdateCompanion<ConversationRow> {
  final Value<String> id;
  final Value<String> title;
  final Value<int> createdAtMs;
  final Value<int> updatedAtMs;
  final Value<String?> assistantId;
  final Value<bool> isPinned;
  final Value<int> truncateIndex;
  final Value<int> compactBeforeIndex;
  final Value<String?> summary;
  final Value<int> lastSummarizedMessageCount;
  final Value<String> mcpServerIdsJson;
  final Value<String> versionSelectionsJson;
  final Value<bool> isRecovered;
  final Value<int> rowid;
  const ConversationRowsCompanion({
    this.id = const Value.absent(),
    this.title = const Value.absent(),
    this.createdAtMs = const Value.absent(),
    this.updatedAtMs = const Value.absent(),
    this.assistantId = const Value.absent(),
    this.isPinned = const Value.absent(),
    this.truncateIndex = const Value.absent(),
    this.compactBeforeIndex = const Value.absent(),
    this.summary = const Value.absent(),
    this.lastSummarizedMessageCount = const Value.absent(),
    this.mcpServerIdsJson = const Value.absent(),
    this.versionSelectionsJson = const Value.absent(),
    this.isRecovered = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ConversationRowsCompanion.insert({
    required String id,
    required String title,
    required int createdAtMs,
    required int updatedAtMs,
    this.assistantId = const Value.absent(),
    this.isPinned = const Value.absent(),
    this.truncateIndex = const Value.absent(),
    this.compactBeforeIndex = const Value.absent(),
    this.summary = const Value.absent(),
    this.lastSummarizedMessageCount = const Value.absent(),
    this.mcpServerIdsJson = const Value.absent(),
    this.versionSelectionsJson = const Value.absent(),
    this.isRecovered = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       title = Value(title),
       createdAtMs = Value(createdAtMs),
       updatedAtMs = Value(updatedAtMs);
  static Insertable<ConversationRow> custom({
    Expression<String>? id,
    Expression<String>? title,
    Expression<int>? createdAtMs,
    Expression<int>? updatedAtMs,
    Expression<String>? assistantId,
    Expression<bool>? isPinned,
    Expression<int>? truncateIndex,
    Expression<int>? compactBeforeIndex,
    Expression<String>? summary,
    Expression<int>? lastSummarizedMessageCount,
    Expression<String>? mcpServerIdsJson,
    Expression<String>? versionSelectionsJson,
    Expression<bool>? isRecovered,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (title != null) 'title': title,
      if (createdAtMs != null) 'created_at': createdAtMs,
      if (updatedAtMs != null) 'updated_at': updatedAtMs,
      if (assistantId != null) 'assistant_id': assistantId,
      if (isPinned != null) 'is_pinned': isPinned,
      if (truncateIndex != null) 'truncate_index': truncateIndex,
      if (compactBeforeIndex != null)
        'compact_before_index': compactBeforeIndex,
      if (summary != null) 'summary': summary,
      if (lastSummarizedMessageCount != null)
        'last_summarized_message_count': lastSummarizedMessageCount,
      if (mcpServerIdsJson != null) 'mcp_server_ids_json': mcpServerIdsJson,
      if (versionSelectionsJson != null)
        'version_selections_json': versionSelectionsJson,
      if (isRecovered != null) 'is_recovered': isRecovered,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ConversationRowsCompanion copyWith({
    Value<String>? id,
    Value<String>? title,
    Value<int>? createdAtMs,
    Value<int>? updatedAtMs,
    Value<String?>? assistantId,
    Value<bool>? isPinned,
    Value<int>? truncateIndex,
    Value<int>? compactBeforeIndex,
    Value<String?>? summary,
    Value<int>? lastSummarizedMessageCount,
    Value<String>? mcpServerIdsJson,
    Value<String>? versionSelectionsJson,
    Value<bool>? isRecovered,
    Value<int>? rowid,
  }) {
    return ConversationRowsCompanion(
      id: id ?? this.id,
      title: title ?? this.title,
      createdAtMs: createdAtMs ?? this.createdAtMs,
      updatedAtMs: updatedAtMs ?? this.updatedAtMs,
      assistantId: assistantId ?? this.assistantId,
      isPinned: isPinned ?? this.isPinned,
      truncateIndex: truncateIndex ?? this.truncateIndex,
      compactBeforeIndex: compactBeforeIndex ?? this.compactBeforeIndex,
      summary: summary ?? this.summary,
      lastSummarizedMessageCount:
          lastSummarizedMessageCount ?? this.lastSummarizedMessageCount,
      mcpServerIdsJson: mcpServerIdsJson ?? this.mcpServerIdsJson,
      versionSelectionsJson:
          versionSelectionsJson ?? this.versionSelectionsJson,
      isRecovered: isRecovered ?? this.isRecovered,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (createdAtMs.present) {
      map['created_at'] = Variable<int>(createdAtMs.value);
    }
    if (updatedAtMs.present) {
      map['updated_at'] = Variable<int>(updatedAtMs.value);
    }
    if (assistantId.present) {
      map['assistant_id'] = Variable<String>(assistantId.value);
    }
    if (isPinned.present) {
      map['is_pinned'] = Variable<bool>(isPinned.value);
    }
    if (truncateIndex.present) {
      map['truncate_index'] = Variable<int>(truncateIndex.value);
    }
    if (compactBeforeIndex.present) {
      map['compact_before_index'] = Variable<int>(compactBeforeIndex.value);
    }
    if (summary.present) {
      map['summary'] = Variable<String>(summary.value);
    }
    if (lastSummarizedMessageCount.present) {
      map['last_summarized_message_count'] = Variable<int>(
        lastSummarizedMessageCount.value,
      );
    }
    if (mcpServerIdsJson.present) {
      map['mcp_server_ids_json'] = Variable<String>(mcpServerIdsJson.value);
    }
    if (versionSelectionsJson.present) {
      map['version_selections_json'] = Variable<String>(
        versionSelectionsJson.value,
      );
    }
    if (isRecovered.present) {
      map['is_recovered'] = Variable<bool>(isRecovered.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ConversationRowsCompanion(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('createdAtMs: $createdAtMs, ')
          ..write('updatedAtMs: $updatedAtMs, ')
          ..write('assistantId: $assistantId, ')
          ..write('isPinned: $isPinned, ')
          ..write('truncateIndex: $truncateIndex, ')
          ..write('compactBeforeIndex: $compactBeforeIndex, ')
          ..write('summary: $summary, ')
          ..write('lastSummarizedMessageCount: $lastSummarizedMessageCount, ')
          ..write('mcpServerIdsJson: $mcpServerIdsJson, ')
          ..write('versionSelectionsJson: $versionSelectionsJson, ')
          ..write('isRecovered: $isRecovered, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $MessageRowsTable extends MessageRows
    with TableInfo<$MessageRowsTable, MessageRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MessageRowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _conversationIdMeta = const VerificationMeta(
    'conversationId',
  );
  @override
  late final GeneratedColumn<String> conversationId = GeneratedColumn<String>(
    'conversation_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES conversations (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _ordinalMeta = const VerificationMeta(
    'ordinal',
  );
  @override
  late final GeneratedColumn<int> ordinal = GeneratedColumn<int>(
    'ordinal',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _roleMeta = const VerificationMeta('role');
  @override
  late final GeneratedColumn<String> role = GeneratedColumn<String>(
    'role',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _contentMeta = const VerificationMeta(
    'content',
  );
  @override
  late final GeneratedColumn<String> content = GeneratedColumn<String>(
    'content',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _timestampMsMeta = const VerificationMeta(
    'timestampMs',
  );
  @override
  late final GeneratedColumn<int> timestampMs = GeneratedColumn<int>(
    'timestamp',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _modelIdMeta = const VerificationMeta(
    'modelId',
  );
  @override
  late final GeneratedColumn<String> modelId = GeneratedColumn<String>(
    'model_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _providerIdMeta = const VerificationMeta(
    'providerId',
  );
  @override
  late final GeneratedColumn<String> providerId = GeneratedColumn<String>(
    'provider_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _totalTokensMeta = const VerificationMeta(
    'totalTokens',
  );
  @override
  late final GeneratedColumn<int> totalTokens = GeneratedColumn<int>(
    'total_tokens',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _promptTokensMeta = const VerificationMeta(
    'promptTokens',
  );
  @override
  late final GeneratedColumn<int> promptTokens = GeneratedColumn<int>(
    'prompt_tokens',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _completionTokensMeta = const VerificationMeta(
    'completionTokens',
  );
  @override
  late final GeneratedColumn<int> completionTokens = GeneratedColumn<int>(
    'completion_tokens',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _cachedTokensMeta = const VerificationMeta(
    'cachedTokens',
  );
  @override
  late final GeneratedColumn<int> cachedTokens = GeneratedColumn<int>(
    'cached_tokens',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _isStreamingMeta = const VerificationMeta(
    'isStreaming',
  );
  @override
  late final GeneratedColumn<bool> isStreaming = GeneratedColumn<bool>(
    'is_streaming',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_streaming" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _reasoningTextMeta = const VerificationMeta(
    'reasoningText',
  );
  @override
  late final GeneratedColumn<String> reasoningText = GeneratedColumn<String>(
    'reasoning_text',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _reasoningStartAtMsMeta =
      const VerificationMeta('reasoningStartAtMs');
  @override
  late final GeneratedColumn<int> reasoningStartAtMs = GeneratedColumn<int>(
    'reasoning_start_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _reasoningFinishedAtMsMeta =
      const VerificationMeta('reasoningFinishedAtMs');
  @override
  late final GeneratedColumn<int> reasoningFinishedAtMs = GeneratedColumn<int>(
    'reasoning_finished_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _translationMeta = const VerificationMeta(
    'translation',
  );
  @override
  late final GeneratedColumn<String> translation = GeneratedColumn<String>(
    'translation',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _reasoningSegmentsJsonMeta =
      const VerificationMeta('reasoningSegmentsJson');
  @override
  late final GeneratedColumn<String> reasoningSegmentsJson =
      GeneratedColumn<String>(
        'reasoning_segments_json',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _groupIdMeta = const VerificationMeta(
    'groupId',
  );
  @override
  late final GeneratedColumn<String> groupId = GeneratedColumn<String>(
    'group_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _versionMeta = const VerificationMeta(
    'version',
  );
  @override
  late final GeneratedColumn<int> version = GeneratedColumn<int>(
    'version',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _aiTeamProposalsJsonMeta =
      const VerificationMeta('aiTeamProposalsJson');
  @override
  late final GeneratedColumn<String> aiTeamProposalsJson =
      GeneratedColumn<String>(
        'ai_team_proposals_json',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _processStartedAtMsMeta =
      const VerificationMeta('processStartedAtMs');
  @override
  late final GeneratedColumn<int> processStartedAtMs = GeneratedColumn<int>(
    'process_started_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _processFinishedAtMsMeta =
      const VerificationMeta('processFinishedAtMs');
  @override
  late final GeneratedColumn<int> processFinishedAtMs = GeneratedColumn<int>(
    'process_finished_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    conversationId,
    ordinal,
    role,
    content,
    timestampMs,
    modelId,
    providerId,
    totalTokens,
    promptTokens,
    completionTokens,
    cachedTokens,
    isStreaming,
    reasoningText,
    reasoningStartAtMs,
    reasoningFinishedAtMs,
    translation,
    reasoningSegmentsJson,
    groupId,
    version,
    aiTeamProposalsJson,
    processStartedAtMs,
    processFinishedAtMs,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'messages';
  @override
  VerificationContext validateIntegrity(
    Insertable<MessageRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('conversation_id')) {
      context.handle(
        _conversationIdMeta,
        conversationId.isAcceptableOrUnknown(
          data['conversation_id']!,
          _conversationIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_conversationIdMeta);
    }
    if (data.containsKey('ordinal')) {
      context.handle(
        _ordinalMeta,
        ordinal.isAcceptableOrUnknown(data['ordinal']!, _ordinalMeta),
      );
    } else if (isInserting) {
      context.missing(_ordinalMeta);
    }
    if (data.containsKey('role')) {
      context.handle(
        _roleMeta,
        role.isAcceptableOrUnknown(data['role']!, _roleMeta),
      );
    } else if (isInserting) {
      context.missing(_roleMeta);
    }
    if (data.containsKey('content')) {
      context.handle(
        _contentMeta,
        content.isAcceptableOrUnknown(data['content']!, _contentMeta),
      );
    } else if (isInserting) {
      context.missing(_contentMeta);
    }
    if (data.containsKey('timestamp')) {
      context.handle(
        _timestampMsMeta,
        timestampMs.isAcceptableOrUnknown(data['timestamp']!, _timestampMsMeta),
      );
    } else if (isInserting) {
      context.missing(_timestampMsMeta);
    }
    if (data.containsKey('model_id')) {
      context.handle(
        _modelIdMeta,
        modelId.isAcceptableOrUnknown(data['model_id']!, _modelIdMeta),
      );
    }
    if (data.containsKey('provider_id')) {
      context.handle(
        _providerIdMeta,
        providerId.isAcceptableOrUnknown(data['provider_id']!, _providerIdMeta),
      );
    }
    if (data.containsKey('total_tokens')) {
      context.handle(
        _totalTokensMeta,
        totalTokens.isAcceptableOrUnknown(
          data['total_tokens']!,
          _totalTokensMeta,
        ),
      );
    }
    if (data.containsKey('prompt_tokens')) {
      context.handle(
        _promptTokensMeta,
        promptTokens.isAcceptableOrUnknown(
          data['prompt_tokens']!,
          _promptTokensMeta,
        ),
      );
    }
    if (data.containsKey('completion_tokens')) {
      context.handle(
        _completionTokensMeta,
        completionTokens.isAcceptableOrUnknown(
          data['completion_tokens']!,
          _completionTokensMeta,
        ),
      );
    }
    if (data.containsKey('cached_tokens')) {
      context.handle(
        _cachedTokensMeta,
        cachedTokens.isAcceptableOrUnknown(
          data['cached_tokens']!,
          _cachedTokensMeta,
        ),
      );
    }
    if (data.containsKey('is_streaming')) {
      context.handle(
        _isStreamingMeta,
        isStreaming.isAcceptableOrUnknown(
          data['is_streaming']!,
          _isStreamingMeta,
        ),
      );
    }
    if (data.containsKey('reasoning_text')) {
      context.handle(
        _reasoningTextMeta,
        reasoningText.isAcceptableOrUnknown(
          data['reasoning_text']!,
          _reasoningTextMeta,
        ),
      );
    }
    if (data.containsKey('reasoning_start_at')) {
      context.handle(
        _reasoningStartAtMsMeta,
        reasoningStartAtMs.isAcceptableOrUnknown(
          data['reasoning_start_at']!,
          _reasoningStartAtMsMeta,
        ),
      );
    }
    if (data.containsKey('reasoning_finished_at')) {
      context.handle(
        _reasoningFinishedAtMsMeta,
        reasoningFinishedAtMs.isAcceptableOrUnknown(
          data['reasoning_finished_at']!,
          _reasoningFinishedAtMsMeta,
        ),
      );
    }
    if (data.containsKey('translation')) {
      context.handle(
        _translationMeta,
        translation.isAcceptableOrUnknown(
          data['translation']!,
          _translationMeta,
        ),
      );
    }
    if (data.containsKey('reasoning_segments_json')) {
      context.handle(
        _reasoningSegmentsJsonMeta,
        reasoningSegmentsJson.isAcceptableOrUnknown(
          data['reasoning_segments_json']!,
          _reasoningSegmentsJsonMeta,
        ),
      );
    }
    if (data.containsKey('group_id')) {
      context.handle(
        _groupIdMeta,
        groupId.isAcceptableOrUnknown(data['group_id']!, _groupIdMeta),
      );
    }
    if (data.containsKey('version')) {
      context.handle(
        _versionMeta,
        version.isAcceptableOrUnknown(data['version']!, _versionMeta),
      );
    }
    if (data.containsKey('ai_team_proposals_json')) {
      context.handle(
        _aiTeamProposalsJsonMeta,
        aiTeamProposalsJson.isAcceptableOrUnknown(
          data['ai_team_proposals_json']!,
          _aiTeamProposalsJsonMeta,
        ),
      );
    }
    if (data.containsKey('process_started_at')) {
      context.handle(
        _processStartedAtMsMeta,
        processStartedAtMs.isAcceptableOrUnknown(
          data['process_started_at']!,
          _processStartedAtMsMeta,
        ),
      );
    }
    if (data.containsKey('process_finished_at')) {
      context.handle(
        _processFinishedAtMsMeta,
        processFinishedAtMs.isAcceptableOrUnknown(
          data['process_finished_at']!,
          _processFinishedAtMsMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  MessageRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MessageRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      conversationId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}conversation_id'],
      )!,
      ordinal: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}ordinal'],
      )!,
      role: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}role'],
      )!,
      content: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}content'],
      )!,
      timestampMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}timestamp'],
      )!,
      modelId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}model_id'],
      ),
      providerId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}provider_id'],
      ),
      totalTokens: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}total_tokens'],
      ),
      promptTokens: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}prompt_tokens'],
      ),
      completionTokens: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}completion_tokens'],
      ),
      cachedTokens: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}cached_tokens'],
      ),
      isStreaming: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_streaming'],
      )!,
      reasoningText: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}reasoning_text'],
      ),
      reasoningStartAtMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}reasoning_start_at'],
      ),
      reasoningFinishedAtMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}reasoning_finished_at'],
      ),
      translation: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}translation'],
      ),
      reasoningSegmentsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}reasoning_segments_json'],
      ),
      groupId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}group_id'],
      ),
      version: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}version'],
      )!,
      aiTeamProposalsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}ai_team_proposals_json'],
      ),
      processStartedAtMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}process_started_at'],
      ),
      processFinishedAtMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}process_finished_at'],
      ),
    );
  }

  @override
  $MessageRowsTable createAlias(String alias) {
    return $MessageRowsTable(attachedDatabase, alias);
  }
}

class MessageRow extends DataClass implements Insertable<MessageRow> {
  final String id;
  final String conversationId;
  final int ordinal;
  final String role;
  final String content;
  final int timestampMs;
  final String? modelId;
  final String? providerId;
  final int? totalTokens;
  final int? promptTokens;
  final int? completionTokens;
  final int? cachedTokens;
  final bool isStreaming;
  final String? reasoningText;
  final int? reasoningStartAtMs;
  final int? reasoningFinishedAtMs;
  final String? translation;
  final String? reasoningSegmentsJson;
  final String? groupId;
  final int version;
  final String? aiTeamProposalsJson;
  final int? processStartedAtMs;
  final int? processFinishedAtMs;
  const MessageRow({
    required this.id,
    required this.conversationId,
    required this.ordinal,
    required this.role,
    required this.content,
    required this.timestampMs,
    this.modelId,
    this.providerId,
    this.totalTokens,
    this.promptTokens,
    this.completionTokens,
    this.cachedTokens,
    required this.isStreaming,
    this.reasoningText,
    this.reasoningStartAtMs,
    this.reasoningFinishedAtMs,
    this.translation,
    this.reasoningSegmentsJson,
    this.groupId,
    required this.version,
    this.aiTeamProposalsJson,
    this.processStartedAtMs,
    this.processFinishedAtMs,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['conversation_id'] = Variable<String>(conversationId);
    map['ordinal'] = Variable<int>(ordinal);
    map['role'] = Variable<String>(role);
    map['content'] = Variable<String>(content);
    map['timestamp'] = Variable<int>(timestampMs);
    if (!nullToAbsent || modelId != null) {
      map['model_id'] = Variable<String>(modelId);
    }
    if (!nullToAbsent || providerId != null) {
      map['provider_id'] = Variable<String>(providerId);
    }
    if (!nullToAbsent || totalTokens != null) {
      map['total_tokens'] = Variable<int>(totalTokens);
    }
    if (!nullToAbsent || promptTokens != null) {
      map['prompt_tokens'] = Variable<int>(promptTokens);
    }
    if (!nullToAbsent || completionTokens != null) {
      map['completion_tokens'] = Variable<int>(completionTokens);
    }
    if (!nullToAbsent || cachedTokens != null) {
      map['cached_tokens'] = Variable<int>(cachedTokens);
    }
    map['is_streaming'] = Variable<bool>(isStreaming);
    if (!nullToAbsent || reasoningText != null) {
      map['reasoning_text'] = Variable<String>(reasoningText);
    }
    if (!nullToAbsent || reasoningStartAtMs != null) {
      map['reasoning_start_at'] = Variable<int>(reasoningStartAtMs);
    }
    if (!nullToAbsent || reasoningFinishedAtMs != null) {
      map['reasoning_finished_at'] = Variable<int>(reasoningFinishedAtMs);
    }
    if (!nullToAbsent || translation != null) {
      map['translation'] = Variable<String>(translation);
    }
    if (!nullToAbsent || reasoningSegmentsJson != null) {
      map['reasoning_segments_json'] = Variable<String>(reasoningSegmentsJson);
    }
    if (!nullToAbsent || groupId != null) {
      map['group_id'] = Variable<String>(groupId);
    }
    map['version'] = Variable<int>(version);
    if (!nullToAbsent || aiTeamProposalsJson != null) {
      map['ai_team_proposals_json'] = Variable<String>(aiTeamProposalsJson);
    }
    if (!nullToAbsent || processStartedAtMs != null) {
      map['process_started_at'] = Variable<int>(processStartedAtMs);
    }
    if (!nullToAbsent || processFinishedAtMs != null) {
      map['process_finished_at'] = Variable<int>(processFinishedAtMs);
    }
    return map;
  }

  MessageRowsCompanion toCompanion(bool nullToAbsent) {
    return MessageRowsCompanion(
      id: Value(id),
      conversationId: Value(conversationId),
      ordinal: Value(ordinal),
      role: Value(role),
      content: Value(content),
      timestampMs: Value(timestampMs),
      modelId: modelId == null && nullToAbsent
          ? const Value.absent()
          : Value(modelId),
      providerId: providerId == null && nullToAbsent
          ? const Value.absent()
          : Value(providerId),
      totalTokens: totalTokens == null && nullToAbsent
          ? const Value.absent()
          : Value(totalTokens),
      promptTokens: promptTokens == null && nullToAbsent
          ? const Value.absent()
          : Value(promptTokens),
      completionTokens: completionTokens == null && nullToAbsent
          ? const Value.absent()
          : Value(completionTokens),
      cachedTokens: cachedTokens == null && nullToAbsent
          ? const Value.absent()
          : Value(cachedTokens),
      isStreaming: Value(isStreaming),
      reasoningText: reasoningText == null && nullToAbsent
          ? const Value.absent()
          : Value(reasoningText),
      reasoningStartAtMs: reasoningStartAtMs == null && nullToAbsent
          ? const Value.absent()
          : Value(reasoningStartAtMs),
      reasoningFinishedAtMs: reasoningFinishedAtMs == null && nullToAbsent
          ? const Value.absent()
          : Value(reasoningFinishedAtMs),
      translation: translation == null && nullToAbsent
          ? const Value.absent()
          : Value(translation),
      reasoningSegmentsJson: reasoningSegmentsJson == null && nullToAbsent
          ? const Value.absent()
          : Value(reasoningSegmentsJson),
      groupId: groupId == null && nullToAbsent
          ? const Value.absent()
          : Value(groupId),
      version: Value(version),
      aiTeamProposalsJson: aiTeamProposalsJson == null && nullToAbsent
          ? const Value.absent()
          : Value(aiTeamProposalsJson),
      processStartedAtMs: processStartedAtMs == null && nullToAbsent
          ? const Value.absent()
          : Value(processStartedAtMs),
      processFinishedAtMs: processFinishedAtMs == null && nullToAbsent
          ? const Value.absent()
          : Value(processFinishedAtMs),
    );
  }

  factory MessageRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MessageRow(
      id: serializer.fromJson<String>(json['id']),
      conversationId: serializer.fromJson<String>(json['conversationId']),
      ordinal: serializer.fromJson<int>(json['ordinal']),
      role: serializer.fromJson<String>(json['role']),
      content: serializer.fromJson<String>(json['content']),
      timestampMs: serializer.fromJson<int>(json['timestampMs']),
      modelId: serializer.fromJson<String?>(json['modelId']),
      providerId: serializer.fromJson<String?>(json['providerId']),
      totalTokens: serializer.fromJson<int?>(json['totalTokens']),
      promptTokens: serializer.fromJson<int?>(json['promptTokens']),
      completionTokens: serializer.fromJson<int?>(json['completionTokens']),
      cachedTokens: serializer.fromJson<int?>(json['cachedTokens']),
      isStreaming: serializer.fromJson<bool>(json['isStreaming']),
      reasoningText: serializer.fromJson<String?>(json['reasoningText']),
      reasoningStartAtMs: serializer.fromJson<int?>(json['reasoningStartAtMs']),
      reasoningFinishedAtMs: serializer.fromJson<int?>(
        json['reasoningFinishedAtMs'],
      ),
      translation: serializer.fromJson<String?>(json['translation']),
      reasoningSegmentsJson: serializer.fromJson<String?>(
        json['reasoningSegmentsJson'],
      ),
      groupId: serializer.fromJson<String?>(json['groupId']),
      version: serializer.fromJson<int>(json['version']),
      aiTeamProposalsJson: serializer.fromJson<String?>(
        json['aiTeamProposalsJson'],
      ),
      processStartedAtMs: serializer.fromJson<int?>(json['processStartedAtMs']),
      processFinishedAtMs: serializer.fromJson<int?>(
        json['processFinishedAtMs'],
      ),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'conversationId': serializer.toJson<String>(conversationId),
      'ordinal': serializer.toJson<int>(ordinal),
      'role': serializer.toJson<String>(role),
      'content': serializer.toJson<String>(content),
      'timestampMs': serializer.toJson<int>(timestampMs),
      'modelId': serializer.toJson<String?>(modelId),
      'providerId': serializer.toJson<String?>(providerId),
      'totalTokens': serializer.toJson<int?>(totalTokens),
      'promptTokens': serializer.toJson<int?>(promptTokens),
      'completionTokens': serializer.toJson<int?>(completionTokens),
      'cachedTokens': serializer.toJson<int?>(cachedTokens),
      'isStreaming': serializer.toJson<bool>(isStreaming),
      'reasoningText': serializer.toJson<String?>(reasoningText),
      'reasoningStartAtMs': serializer.toJson<int?>(reasoningStartAtMs),
      'reasoningFinishedAtMs': serializer.toJson<int?>(reasoningFinishedAtMs),
      'translation': serializer.toJson<String?>(translation),
      'reasoningSegmentsJson': serializer.toJson<String?>(
        reasoningSegmentsJson,
      ),
      'groupId': serializer.toJson<String?>(groupId),
      'version': serializer.toJson<int>(version),
      'aiTeamProposalsJson': serializer.toJson<String?>(aiTeamProposalsJson),
      'processStartedAtMs': serializer.toJson<int?>(processStartedAtMs),
      'processFinishedAtMs': serializer.toJson<int?>(processFinishedAtMs),
    };
  }

  MessageRow copyWith({
    String? id,
    String? conversationId,
    int? ordinal,
    String? role,
    String? content,
    int? timestampMs,
    Value<String?> modelId = const Value.absent(),
    Value<String?> providerId = const Value.absent(),
    Value<int?> totalTokens = const Value.absent(),
    Value<int?> promptTokens = const Value.absent(),
    Value<int?> completionTokens = const Value.absent(),
    Value<int?> cachedTokens = const Value.absent(),
    bool? isStreaming,
    Value<String?> reasoningText = const Value.absent(),
    Value<int?> reasoningStartAtMs = const Value.absent(),
    Value<int?> reasoningFinishedAtMs = const Value.absent(),
    Value<String?> translation = const Value.absent(),
    Value<String?> reasoningSegmentsJson = const Value.absent(),
    Value<String?> groupId = const Value.absent(),
    int? version,
    Value<String?> aiTeamProposalsJson = const Value.absent(),
    Value<int?> processStartedAtMs = const Value.absent(),
    Value<int?> processFinishedAtMs = const Value.absent(),
  }) => MessageRow(
    id: id ?? this.id,
    conversationId: conversationId ?? this.conversationId,
    ordinal: ordinal ?? this.ordinal,
    role: role ?? this.role,
    content: content ?? this.content,
    timestampMs: timestampMs ?? this.timestampMs,
    modelId: modelId.present ? modelId.value : this.modelId,
    providerId: providerId.present ? providerId.value : this.providerId,
    totalTokens: totalTokens.present ? totalTokens.value : this.totalTokens,
    promptTokens: promptTokens.present ? promptTokens.value : this.promptTokens,
    completionTokens: completionTokens.present
        ? completionTokens.value
        : this.completionTokens,
    cachedTokens: cachedTokens.present ? cachedTokens.value : this.cachedTokens,
    isStreaming: isStreaming ?? this.isStreaming,
    reasoningText: reasoningText.present
        ? reasoningText.value
        : this.reasoningText,
    reasoningStartAtMs: reasoningStartAtMs.present
        ? reasoningStartAtMs.value
        : this.reasoningStartAtMs,
    reasoningFinishedAtMs: reasoningFinishedAtMs.present
        ? reasoningFinishedAtMs.value
        : this.reasoningFinishedAtMs,
    translation: translation.present ? translation.value : this.translation,
    reasoningSegmentsJson: reasoningSegmentsJson.present
        ? reasoningSegmentsJson.value
        : this.reasoningSegmentsJson,
    groupId: groupId.present ? groupId.value : this.groupId,
    version: version ?? this.version,
    aiTeamProposalsJson: aiTeamProposalsJson.present
        ? aiTeamProposalsJson.value
        : this.aiTeamProposalsJson,
    processStartedAtMs: processStartedAtMs.present
        ? processStartedAtMs.value
        : this.processStartedAtMs,
    processFinishedAtMs: processFinishedAtMs.present
        ? processFinishedAtMs.value
        : this.processFinishedAtMs,
  );
  MessageRow copyWithCompanion(MessageRowsCompanion data) {
    return MessageRow(
      id: data.id.present ? data.id.value : this.id,
      conversationId: data.conversationId.present
          ? data.conversationId.value
          : this.conversationId,
      ordinal: data.ordinal.present ? data.ordinal.value : this.ordinal,
      role: data.role.present ? data.role.value : this.role,
      content: data.content.present ? data.content.value : this.content,
      timestampMs: data.timestampMs.present
          ? data.timestampMs.value
          : this.timestampMs,
      modelId: data.modelId.present ? data.modelId.value : this.modelId,
      providerId: data.providerId.present
          ? data.providerId.value
          : this.providerId,
      totalTokens: data.totalTokens.present
          ? data.totalTokens.value
          : this.totalTokens,
      promptTokens: data.promptTokens.present
          ? data.promptTokens.value
          : this.promptTokens,
      completionTokens: data.completionTokens.present
          ? data.completionTokens.value
          : this.completionTokens,
      cachedTokens: data.cachedTokens.present
          ? data.cachedTokens.value
          : this.cachedTokens,
      isStreaming: data.isStreaming.present
          ? data.isStreaming.value
          : this.isStreaming,
      reasoningText: data.reasoningText.present
          ? data.reasoningText.value
          : this.reasoningText,
      reasoningStartAtMs: data.reasoningStartAtMs.present
          ? data.reasoningStartAtMs.value
          : this.reasoningStartAtMs,
      reasoningFinishedAtMs: data.reasoningFinishedAtMs.present
          ? data.reasoningFinishedAtMs.value
          : this.reasoningFinishedAtMs,
      translation: data.translation.present
          ? data.translation.value
          : this.translation,
      reasoningSegmentsJson: data.reasoningSegmentsJson.present
          ? data.reasoningSegmentsJson.value
          : this.reasoningSegmentsJson,
      groupId: data.groupId.present ? data.groupId.value : this.groupId,
      version: data.version.present ? data.version.value : this.version,
      aiTeamProposalsJson: data.aiTeamProposalsJson.present
          ? data.aiTeamProposalsJson.value
          : this.aiTeamProposalsJson,
      processStartedAtMs: data.processStartedAtMs.present
          ? data.processStartedAtMs.value
          : this.processStartedAtMs,
      processFinishedAtMs: data.processFinishedAtMs.present
          ? data.processFinishedAtMs.value
          : this.processFinishedAtMs,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MessageRow(')
          ..write('id: $id, ')
          ..write('conversationId: $conversationId, ')
          ..write('ordinal: $ordinal, ')
          ..write('role: $role, ')
          ..write('content: $content, ')
          ..write('timestampMs: $timestampMs, ')
          ..write('modelId: $modelId, ')
          ..write('providerId: $providerId, ')
          ..write('totalTokens: $totalTokens, ')
          ..write('promptTokens: $promptTokens, ')
          ..write('completionTokens: $completionTokens, ')
          ..write('cachedTokens: $cachedTokens, ')
          ..write('isStreaming: $isStreaming, ')
          ..write('reasoningText: $reasoningText, ')
          ..write('reasoningStartAtMs: $reasoningStartAtMs, ')
          ..write('reasoningFinishedAtMs: $reasoningFinishedAtMs, ')
          ..write('translation: $translation, ')
          ..write('reasoningSegmentsJson: $reasoningSegmentsJson, ')
          ..write('groupId: $groupId, ')
          ..write('version: $version, ')
          ..write('aiTeamProposalsJson: $aiTeamProposalsJson, ')
          ..write('processStartedAtMs: $processStartedAtMs, ')
          ..write('processFinishedAtMs: $processFinishedAtMs')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
    id,
    conversationId,
    ordinal,
    role,
    content,
    timestampMs,
    modelId,
    providerId,
    totalTokens,
    promptTokens,
    completionTokens,
    cachedTokens,
    isStreaming,
    reasoningText,
    reasoningStartAtMs,
    reasoningFinishedAtMs,
    translation,
    reasoningSegmentsJson,
    groupId,
    version,
    aiTeamProposalsJson,
    processStartedAtMs,
    processFinishedAtMs,
  ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MessageRow &&
          other.id == this.id &&
          other.conversationId == this.conversationId &&
          other.ordinal == this.ordinal &&
          other.role == this.role &&
          other.content == this.content &&
          other.timestampMs == this.timestampMs &&
          other.modelId == this.modelId &&
          other.providerId == this.providerId &&
          other.totalTokens == this.totalTokens &&
          other.promptTokens == this.promptTokens &&
          other.completionTokens == this.completionTokens &&
          other.cachedTokens == this.cachedTokens &&
          other.isStreaming == this.isStreaming &&
          other.reasoningText == this.reasoningText &&
          other.reasoningStartAtMs == this.reasoningStartAtMs &&
          other.reasoningFinishedAtMs == this.reasoningFinishedAtMs &&
          other.translation == this.translation &&
          other.reasoningSegmentsJson == this.reasoningSegmentsJson &&
          other.groupId == this.groupId &&
          other.version == this.version &&
          other.aiTeamProposalsJson == this.aiTeamProposalsJson &&
          other.processStartedAtMs == this.processStartedAtMs &&
          other.processFinishedAtMs == this.processFinishedAtMs);
}

class MessageRowsCompanion extends UpdateCompanion<MessageRow> {
  final Value<String> id;
  final Value<String> conversationId;
  final Value<int> ordinal;
  final Value<String> role;
  final Value<String> content;
  final Value<int> timestampMs;
  final Value<String?> modelId;
  final Value<String?> providerId;
  final Value<int?> totalTokens;
  final Value<int?> promptTokens;
  final Value<int?> completionTokens;
  final Value<int?> cachedTokens;
  final Value<bool> isStreaming;
  final Value<String?> reasoningText;
  final Value<int?> reasoningStartAtMs;
  final Value<int?> reasoningFinishedAtMs;
  final Value<String?> translation;
  final Value<String?> reasoningSegmentsJson;
  final Value<String?> groupId;
  final Value<int> version;
  final Value<String?> aiTeamProposalsJson;
  final Value<int?> processStartedAtMs;
  final Value<int?> processFinishedAtMs;
  final Value<int> rowid;
  const MessageRowsCompanion({
    this.id = const Value.absent(),
    this.conversationId = const Value.absent(),
    this.ordinal = const Value.absent(),
    this.role = const Value.absent(),
    this.content = const Value.absent(),
    this.timestampMs = const Value.absent(),
    this.modelId = const Value.absent(),
    this.providerId = const Value.absent(),
    this.totalTokens = const Value.absent(),
    this.promptTokens = const Value.absent(),
    this.completionTokens = const Value.absent(),
    this.cachedTokens = const Value.absent(),
    this.isStreaming = const Value.absent(),
    this.reasoningText = const Value.absent(),
    this.reasoningStartAtMs = const Value.absent(),
    this.reasoningFinishedAtMs = const Value.absent(),
    this.translation = const Value.absent(),
    this.reasoningSegmentsJson = const Value.absent(),
    this.groupId = const Value.absent(),
    this.version = const Value.absent(),
    this.aiTeamProposalsJson = const Value.absent(),
    this.processStartedAtMs = const Value.absent(),
    this.processFinishedAtMs = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MessageRowsCompanion.insert({
    required String id,
    required String conversationId,
    required int ordinal,
    required String role,
    required String content,
    required int timestampMs,
    this.modelId = const Value.absent(),
    this.providerId = const Value.absent(),
    this.totalTokens = const Value.absent(),
    this.promptTokens = const Value.absent(),
    this.completionTokens = const Value.absent(),
    this.cachedTokens = const Value.absent(),
    this.isStreaming = const Value.absent(),
    this.reasoningText = const Value.absent(),
    this.reasoningStartAtMs = const Value.absent(),
    this.reasoningFinishedAtMs = const Value.absent(),
    this.translation = const Value.absent(),
    this.reasoningSegmentsJson = const Value.absent(),
    this.groupId = const Value.absent(),
    this.version = const Value.absent(),
    this.aiTeamProposalsJson = const Value.absent(),
    this.processStartedAtMs = const Value.absent(),
    this.processFinishedAtMs = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       conversationId = Value(conversationId),
       ordinal = Value(ordinal),
       role = Value(role),
       content = Value(content),
       timestampMs = Value(timestampMs);
  static Insertable<MessageRow> custom({
    Expression<String>? id,
    Expression<String>? conversationId,
    Expression<int>? ordinal,
    Expression<String>? role,
    Expression<String>? content,
    Expression<int>? timestampMs,
    Expression<String>? modelId,
    Expression<String>? providerId,
    Expression<int>? totalTokens,
    Expression<int>? promptTokens,
    Expression<int>? completionTokens,
    Expression<int>? cachedTokens,
    Expression<bool>? isStreaming,
    Expression<String>? reasoningText,
    Expression<int>? reasoningStartAtMs,
    Expression<int>? reasoningFinishedAtMs,
    Expression<String>? translation,
    Expression<String>? reasoningSegmentsJson,
    Expression<String>? groupId,
    Expression<int>? version,
    Expression<String>? aiTeamProposalsJson,
    Expression<int>? processStartedAtMs,
    Expression<int>? processFinishedAtMs,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (conversationId != null) 'conversation_id': conversationId,
      if (ordinal != null) 'ordinal': ordinal,
      if (role != null) 'role': role,
      if (content != null) 'content': content,
      if (timestampMs != null) 'timestamp': timestampMs,
      if (modelId != null) 'model_id': modelId,
      if (providerId != null) 'provider_id': providerId,
      if (totalTokens != null) 'total_tokens': totalTokens,
      if (promptTokens != null) 'prompt_tokens': promptTokens,
      if (completionTokens != null) 'completion_tokens': completionTokens,
      if (cachedTokens != null) 'cached_tokens': cachedTokens,
      if (isStreaming != null) 'is_streaming': isStreaming,
      if (reasoningText != null) 'reasoning_text': reasoningText,
      if (reasoningStartAtMs != null) 'reasoning_start_at': reasoningStartAtMs,
      if (reasoningFinishedAtMs != null)
        'reasoning_finished_at': reasoningFinishedAtMs,
      if (translation != null) 'translation': translation,
      if (reasoningSegmentsJson != null)
        'reasoning_segments_json': reasoningSegmentsJson,
      if (groupId != null) 'group_id': groupId,
      if (version != null) 'version': version,
      if (aiTeamProposalsJson != null)
        'ai_team_proposals_json': aiTeamProposalsJson,
      if (processStartedAtMs != null) 'process_started_at': processStartedAtMs,
      if (processFinishedAtMs != null)
        'process_finished_at': processFinishedAtMs,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MessageRowsCompanion copyWith({
    Value<String>? id,
    Value<String>? conversationId,
    Value<int>? ordinal,
    Value<String>? role,
    Value<String>? content,
    Value<int>? timestampMs,
    Value<String?>? modelId,
    Value<String?>? providerId,
    Value<int?>? totalTokens,
    Value<int?>? promptTokens,
    Value<int?>? completionTokens,
    Value<int?>? cachedTokens,
    Value<bool>? isStreaming,
    Value<String?>? reasoningText,
    Value<int?>? reasoningStartAtMs,
    Value<int?>? reasoningFinishedAtMs,
    Value<String?>? translation,
    Value<String?>? reasoningSegmentsJson,
    Value<String?>? groupId,
    Value<int>? version,
    Value<String?>? aiTeamProposalsJson,
    Value<int?>? processStartedAtMs,
    Value<int?>? processFinishedAtMs,
    Value<int>? rowid,
  }) {
    return MessageRowsCompanion(
      id: id ?? this.id,
      conversationId: conversationId ?? this.conversationId,
      ordinal: ordinal ?? this.ordinal,
      role: role ?? this.role,
      content: content ?? this.content,
      timestampMs: timestampMs ?? this.timestampMs,
      modelId: modelId ?? this.modelId,
      providerId: providerId ?? this.providerId,
      totalTokens: totalTokens ?? this.totalTokens,
      promptTokens: promptTokens ?? this.promptTokens,
      completionTokens: completionTokens ?? this.completionTokens,
      cachedTokens: cachedTokens ?? this.cachedTokens,
      isStreaming: isStreaming ?? this.isStreaming,
      reasoningText: reasoningText ?? this.reasoningText,
      reasoningStartAtMs: reasoningStartAtMs ?? this.reasoningStartAtMs,
      reasoningFinishedAtMs:
          reasoningFinishedAtMs ?? this.reasoningFinishedAtMs,
      translation: translation ?? this.translation,
      reasoningSegmentsJson:
          reasoningSegmentsJson ?? this.reasoningSegmentsJson,
      groupId: groupId ?? this.groupId,
      version: version ?? this.version,
      aiTeamProposalsJson: aiTeamProposalsJson ?? this.aiTeamProposalsJson,
      processStartedAtMs: processStartedAtMs ?? this.processStartedAtMs,
      processFinishedAtMs: processFinishedAtMs ?? this.processFinishedAtMs,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (conversationId.present) {
      map['conversation_id'] = Variable<String>(conversationId.value);
    }
    if (ordinal.present) {
      map['ordinal'] = Variable<int>(ordinal.value);
    }
    if (role.present) {
      map['role'] = Variable<String>(role.value);
    }
    if (content.present) {
      map['content'] = Variable<String>(content.value);
    }
    if (timestampMs.present) {
      map['timestamp'] = Variable<int>(timestampMs.value);
    }
    if (modelId.present) {
      map['model_id'] = Variable<String>(modelId.value);
    }
    if (providerId.present) {
      map['provider_id'] = Variable<String>(providerId.value);
    }
    if (totalTokens.present) {
      map['total_tokens'] = Variable<int>(totalTokens.value);
    }
    if (promptTokens.present) {
      map['prompt_tokens'] = Variable<int>(promptTokens.value);
    }
    if (completionTokens.present) {
      map['completion_tokens'] = Variable<int>(completionTokens.value);
    }
    if (cachedTokens.present) {
      map['cached_tokens'] = Variable<int>(cachedTokens.value);
    }
    if (isStreaming.present) {
      map['is_streaming'] = Variable<bool>(isStreaming.value);
    }
    if (reasoningText.present) {
      map['reasoning_text'] = Variable<String>(reasoningText.value);
    }
    if (reasoningStartAtMs.present) {
      map['reasoning_start_at'] = Variable<int>(reasoningStartAtMs.value);
    }
    if (reasoningFinishedAtMs.present) {
      map['reasoning_finished_at'] = Variable<int>(reasoningFinishedAtMs.value);
    }
    if (translation.present) {
      map['translation'] = Variable<String>(translation.value);
    }
    if (reasoningSegmentsJson.present) {
      map['reasoning_segments_json'] = Variable<String>(
        reasoningSegmentsJson.value,
      );
    }
    if (groupId.present) {
      map['group_id'] = Variable<String>(groupId.value);
    }
    if (version.present) {
      map['version'] = Variable<int>(version.value);
    }
    if (aiTeamProposalsJson.present) {
      map['ai_team_proposals_json'] = Variable<String>(
        aiTeamProposalsJson.value,
      );
    }
    if (processStartedAtMs.present) {
      map['process_started_at'] = Variable<int>(processStartedAtMs.value);
    }
    if (processFinishedAtMs.present) {
      map['process_finished_at'] = Variable<int>(processFinishedAtMs.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MessageRowsCompanion(')
          ..write('id: $id, ')
          ..write('conversationId: $conversationId, ')
          ..write('ordinal: $ordinal, ')
          ..write('role: $role, ')
          ..write('content: $content, ')
          ..write('timestampMs: $timestampMs, ')
          ..write('modelId: $modelId, ')
          ..write('providerId: $providerId, ')
          ..write('totalTokens: $totalTokens, ')
          ..write('promptTokens: $promptTokens, ')
          ..write('completionTokens: $completionTokens, ')
          ..write('cachedTokens: $cachedTokens, ')
          ..write('isStreaming: $isStreaming, ')
          ..write('reasoningText: $reasoningText, ')
          ..write('reasoningStartAtMs: $reasoningStartAtMs, ')
          ..write('reasoningFinishedAtMs: $reasoningFinishedAtMs, ')
          ..write('translation: $translation, ')
          ..write('reasoningSegmentsJson: $reasoningSegmentsJson, ')
          ..write('groupId: $groupId, ')
          ..write('version: $version, ')
          ..write('aiTeamProposalsJson: $aiTeamProposalsJson, ')
          ..write('processStartedAtMs: $processStartedAtMs, ')
          ..write('processFinishedAtMs: $processFinishedAtMs, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $MessagePartsTable extends MessageParts
    with TableInfo<$MessagePartsTable, MessagePartRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MessagePartsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _partIdMeta = const VerificationMeta('partId');
  @override
  late final GeneratedColumn<int> partId = GeneratedColumn<int>(
    'part_id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _messageIdMeta = const VerificationMeta(
    'messageId',
  );
  @override
  late final GeneratedColumn<String> messageId = GeneratedColumn<String>(
    'message_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES messages (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _ordinalMeta = const VerificationMeta(
    'ordinal',
  );
  @override
  late final GeneratedColumn<int> ordinal = GeneratedColumn<int>(
    'ordinal',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
    'kind',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _toolCallIdMeta = const VerificationMeta(
    'toolCallId',
  );
  @override
  late final GeneratedColumn<String> toolCallId = GeneratedColumn<String>(
    'tool_call_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _toolNameMeta = const VerificationMeta(
    'toolName',
  );
  @override
  late final GeneratedColumn<String> toolName = GeneratedColumn<String>(
    'tool_name',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _argumentsJsonMeta = const VerificationMeta(
    'argumentsJson',
  );
  @override
  late final GeneratedColumn<String> argumentsJson = GeneratedColumn<String>(
    'arguments_json',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _contentMeta = const VerificationMeta(
    'content',
  );
  @override
  late final GeneratedColumn<String> content = GeneratedColumn<String>(
    'content',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('pending'),
  );
  static const VerificationMeta _approvalStateMeta = const VerificationMeta(
    'approvalState',
  );
  @override
  late final GeneratedColumn<String> approvalState = GeneratedColumn<String>(
    'approval_state',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _metadataJsonMeta = const VerificationMeta(
    'metadataJson',
  );
  @override
  late final GeneratedColumn<String> metadataJson = GeneratedColumn<String>(
    'metadata_json',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMsMeta = const VerificationMeta(
    'createdAtMs',
  );
  @override
  late final GeneratedColumn<int> createdAtMs = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMsMeta = const VerificationMeta(
    'updatedAtMs',
  );
  @override
  late final GeneratedColumn<int> updatedAtMs = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    partId,
    messageId,
    ordinal,
    kind,
    toolCallId,
    toolName,
    argumentsJson,
    content,
    status,
    approvalState,
    metadataJson,
    createdAtMs,
    updatedAtMs,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'message_parts';
  @override
  VerificationContext validateIntegrity(
    Insertable<MessagePartRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('part_id')) {
      context.handle(
        _partIdMeta,
        partId.isAcceptableOrUnknown(data['part_id']!, _partIdMeta),
      );
    }
    if (data.containsKey('message_id')) {
      context.handle(
        _messageIdMeta,
        messageId.isAcceptableOrUnknown(data['message_id']!, _messageIdMeta),
      );
    } else if (isInserting) {
      context.missing(_messageIdMeta);
    }
    if (data.containsKey('ordinal')) {
      context.handle(
        _ordinalMeta,
        ordinal.isAcceptableOrUnknown(data['ordinal']!, _ordinalMeta),
      );
    } else if (isInserting) {
      context.missing(_ordinalMeta);
    }
    if (data.containsKey('kind')) {
      context.handle(
        _kindMeta,
        kind.isAcceptableOrUnknown(data['kind']!, _kindMeta),
      );
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('tool_call_id')) {
      context.handle(
        _toolCallIdMeta,
        toolCallId.isAcceptableOrUnknown(
          data['tool_call_id']!,
          _toolCallIdMeta,
        ),
      );
    }
    if (data.containsKey('tool_name')) {
      context.handle(
        _toolNameMeta,
        toolName.isAcceptableOrUnknown(data['tool_name']!, _toolNameMeta),
      );
    }
    if (data.containsKey('arguments_json')) {
      context.handle(
        _argumentsJsonMeta,
        argumentsJson.isAcceptableOrUnknown(
          data['arguments_json']!,
          _argumentsJsonMeta,
        ),
      );
    }
    if (data.containsKey('content')) {
      context.handle(
        _contentMeta,
        content.isAcceptableOrUnknown(data['content']!, _contentMeta),
      );
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    }
    if (data.containsKey('approval_state')) {
      context.handle(
        _approvalStateMeta,
        approvalState.isAcceptableOrUnknown(
          data['approval_state']!,
          _approvalStateMeta,
        ),
      );
    }
    if (data.containsKey('metadata_json')) {
      context.handle(
        _metadataJsonMeta,
        metadataJson.isAcceptableOrUnknown(
          data['metadata_json']!,
          _metadataJsonMeta,
        ),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMsMeta,
        createdAtMs.isAcceptableOrUnknown(
          data['created_at']!,
          _createdAtMsMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_createdAtMsMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMsMeta,
        updatedAtMs.isAcceptableOrUnknown(
          data['updated_at']!,
          _updatedAtMsMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMsMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {partId};
  @override
  MessagePartRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MessagePartRow(
      partId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}part_id'],
      )!,
      messageId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}message_id'],
      )!,
      ordinal: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}ordinal'],
      )!,
      kind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}kind'],
      )!,
      toolCallId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tool_call_id'],
      ),
      toolName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tool_name'],
      ),
      argumentsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}arguments_json'],
      ),
      content: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}content'],
      ),
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      approvalState: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}approval_state'],
      ),
      metadataJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}metadata_json'],
      ),
      createdAtMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAtMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $MessagePartsTable createAlias(String alias) {
    return $MessagePartsTable(attachedDatabase, alias);
  }
}

class MessagePartRow extends DataClass implements Insertable<MessagePartRow> {
  final int partId;
  final String messageId;
  final int ordinal;
  final String kind;
  final String? toolCallId;
  final String? toolName;
  final String? argumentsJson;
  final String? content;
  final String status;
  final String? approvalState;
  final String? metadataJson;
  final int createdAtMs;
  final int updatedAtMs;
  const MessagePartRow({
    required this.partId,
    required this.messageId,
    required this.ordinal,
    required this.kind,
    this.toolCallId,
    this.toolName,
    this.argumentsJson,
    this.content,
    required this.status,
    this.approvalState,
    this.metadataJson,
    required this.createdAtMs,
    required this.updatedAtMs,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['part_id'] = Variable<int>(partId);
    map['message_id'] = Variable<String>(messageId);
    map['ordinal'] = Variable<int>(ordinal);
    map['kind'] = Variable<String>(kind);
    if (!nullToAbsent || toolCallId != null) {
      map['tool_call_id'] = Variable<String>(toolCallId);
    }
    if (!nullToAbsent || toolName != null) {
      map['tool_name'] = Variable<String>(toolName);
    }
    if (!nullToAbsent || argumentsJson != null) {
      map['arguments_json'] = Variable<String>(argumentsJson);
    }
    if (!nullToAbsent || content != null) {
      map['content'] = Variable<String>(content);
    }
    map['status'] = Variable<String>(status);
    if (!nullToAbsent || approvalState != null) {
      map['approval_state'] = Variable<String>(approvalState);
    }
    if (!nullToAbsent || metadataJson != null) {
      map['metadata_json'] = Variable<String>(metadataJson);
    }
    map['created_at'] = Variable<int>(createdAtMs);
    map['updated_at'] = Variable<int>(updatedAtMs);
    return map;
  }

  MessagePartsCompanion toCompanion(bool nullToAbsent) {
    return MessagePartsCompanion(
      partId: Value(partId),
      messageId: Value(messageId),
      ordinal: Value(ordinal),
      kind: Value(kind),
      toolCallId: toolCallId == null && nullToAbsent
          ? const Value.absent()
          : Value(toolCallId),
      toolName: toolName == null && nullToAbsent
          ? const Value.absent()
          : Value(toolName),
      argumentsJson: argumentsJson == null && nullToAbsent
          ? const Value.absent()
          : Value(argumentsJson),
      content: content == null && nullToAbsent
          ? const Value.absent()
          : Value(content),
      status: Value(status),
      approvalState: approvalState == null && nullToAbsent
          ? const Value.absent()
          : Value(approvalState),
      metadataJson: metadataJson == null && nullToAbsent
          ? const Value.absent()
          : Value(metadataJson),
      createdAtMs: Value(createdAtMs),
      updatedAtMs: Value(updatedAtMs),
    );
  }

  factory MessagePartRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MessagePartRow(
      partId: serializer.fromJson<int>(json['partId']),
      messageId: serializer.fromJson<String>(json['messageId']),
      ordinal: serializer.fromJson<int>(json['ordinal']),
      kind: serializer.fromJson<String>(json['kind']),
      toolCallId: serializer.fromJson<String?>(json['toolCallId']),
      toolName: serializer.fromJson<String?>(json['toolName']),
      argumentsJson: serializer.fromJson<String?>(json['argumentsJson']),
      content: serializer.fromJson<String?>(json['content']),
      status: serializer.fromJson<String>(json['status']),
      approvalState: serializer.fromJson<String?>(json['approvalState']),
      metadataJson: serializer.fromJson<String?>(json['metadataJson']),
      createdAtMs: serializer.fromJson<int>(json['createdAtMs']),
      updatedAtMs: serializer.fromJson<int>(json['updatedAtMs']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'partId': serializer.toJson<int>(partId),
      'messageId': serializer.toJson<String>(messageId),
      'ordinal': serializer.toJson<int>(ordinal),
      'kind': serializer.toJson<String>(kind),
      'toolCallId': serializer.toJson<String?>(toolCallId),
      'toolName': serializer.toJson<String?>(toolName),
      'argumentsJson': serializer.toJson<String?>(argumentsJson),
      'content': serializer.toJson<String?>(content),
      'status': serializer.toJson<String>(status),
      'approvalState': serializer.toJson<String?>(approvalState),
      'metadataJson': serializer.toJson<String?>(metadataJson),
      'createdAtMs': serializer.toJson<int>(createdAtMs),
      'updatedAtMs': serializer.toJson<int>(updatedAtMs),
    };
  }

  MessagePartRow copyWith({
    int? partId,
    String? messageId,
    int? ordinal,
    String? kind,
    Value<String?> toolCallId = const Value.absent(),
    Value<String?> toolName = const Value.absent(),
    Value<String?> argumentsJson = const Value.absent(),
    Value<String?> content = const Value.absent(),
    String? status,
    Value<String?> approvalState = const Value.absent(),
    Value<String?> metadataJson = const Value.absent(),
    int? createdAtMs,
    int? updatedAtMs,
  }) => MessagePartRow(
    partId: partId ?? this.partId,
    messageId: messageId ?? this.messageId,
    ordinal: ordinal ?? this.ordinal,
    kind: kind ?? this.kind,
    toolCallId: toolCallId.present ? toolCallId.value : this.toolCallId,
    toolName: toolName.present ? toolName.value : this.toolName,
    argumentsJson: argumentsJson.present
        ? argumentsJson.value
        : this.argumentsJson,
    content: content.present ? content.value : this.content,
    status: status ?? this.status,
    approvalState: approvalState.present
        ? approvalState.value
        : this.approvalState,
    metadataJson: metadataJson.present ? metadataJson.value : this.metadataJson,
    createdAtMs: createdAtMs ?? this.createdAtMs,
    updatedAtMs: updatedAtMs ?? this.updatedAtMs,
  );
  MessagePartRow copyWithCompanion(MessagePartsCompanion data) {
    return MessagePartRow(
      partId: data.partId.present ? data.partId.value : this.partId,
      messageId: data.messageId.present ? data.messageId.value : this.messageId,
      ordinal: data.ordinal.present ? data.ordinal.value : this.ordinal,
      kind: data.kind.present ? data.kind.value : this.kind,
      toolCallId: data.toolCallId.present
          ? data.toolCallId.value
          : this.toolCallId,
      toolName: data.toolName.present ? data.toolName.value : this.toolName,
      argumentsJson: data.argumentsJson.present
          ? data.argumentsJson.value
          : this.argumentsJson,
      content: data.content.present ? data.content.value : this.content,
      status: data.status.present ? data.status.value : this.status,
      approvalState: data.approvalState.present
          ? data.approvalState.value
          : this.approvalState,
      metadataJson: data.metadataJson.present
          ? data.metadataJson.value
          : this.metadataJson,
      createdAtMs: data.createdAtMs.present
          ? data.createdAtMs.value
          : this.createdAtMs,
      updatedAtMs: data.updatedAtMs.present
          ? data.updatedAtMs.value
          : this.updatedAtMs,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MessagePartRow(')
          ..write('partId: $partId, ')
          ..write('messageId: $messageId, ')
          ..write('ordinal: $ordinal, ')
          ..write('kind: $kind, ')
          ..write('toolCallId: $toolCallId, ')
          ..write('toolName: $toolName, ')
          ..write('argumentsJson: $argumentsJson, ')
          ..write('content: $content, ')
          ..write('status: $status, ')
          ..write('approvalState: $approvalState, ')
          ..write('metadataJson: $metadataJson, ')
          ..write('createdAtMs: $createdAtMs, ')
          ..write('updatedAtMs: $updatedAtMs')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    partId,
    messageId,
    ordinal,
    kind,
    toolCallId,
    toolName,
    argumentsJson,
    content,
    status,
    approvalState,
    metadataJson,
    createdAtMs,
    updatedAtMs,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MessagePartRow &&
          other.partId == this.partId &&
          other.messageId == this.messageId &&
          other.ordinal == this.ordinal &&
          other.kind == this.kind &&
          other.toolCallId == this.toolCallId &&
          other.toolName == this.toolName &&
          other.argumentsJson == this.argumentsJson &&
          other.content == this.content &&
          other.status == this.status &&
          other.approvalState == this.approvalState &&
          other.metadataJson == this.metadataJson &&
          other.createdAtMs == this.createdAtMs &&
          other.updatedAtMs == this.updatedAtMs);
}

class MessagePartsCompanion extends UpdateCompanion<MessagePartRow> {
  final Value<int> partId;
  final Value<String> messageId;
  final Value<int> ordinal;
  final Value<String> kind;
  final Value<String?> toolCallId;
  final Value<String?> toolName;
  final Value<String?> argumentsJson;
  final Value<String?> content;
  final Value<String> status;
  final Value<String?> approvalState;
  final Value<String?> metadataJson;
  final Value<int> createdAtMs;
  final Value<int> updatedAtMs;
  const MessagePartsCompanion({
    this.partId = const Value.absent(),
    this.messageId = const Value.absent(),
    this.ordinal = const Value.absent(),
    this.kind = const Value.absent(),
    this.toolCallId = const Value.absent(),
    this.toolName = const Value.absent(),
    this.argumentsJson = const Value.absent(),
    this.content = const Value.absent(),
    this.status = const Value.absent(),
    this.approvalState = const Value.absent(),
    this.metadataJson = const Value.absent(),
    this.createdAtMs = const Value.absent(),
    this.updatedAtMs = const Value.absent(),
  });
  MessagePartsCompanion.insert({
    this.partId = const Value.absent(),
    required String messageId,
    required int ordinal,
    required String kind,
    this.toolCallId = const Value.absent(),
    this.toolName = const Value.absent(),
    this.argumentsJson = const Value.absent(),
    this.content = const Value.absent(),
    this.status = const Value.absent(),
    this.approvalState = const Value.absent(),
    this.metadataJson = const Value.absent(),
    required int createdAtMs,
    required int updatedAtMs,
  }) : messageId = Value(messageId),
       ordinal = Value(ordinal),
       kind = Value(kind),
       createdAtMs = Value(createdAtMs),
       updatedAtMs = Value(updatedAtMs);
  static Insertable<MessagePartRow> custom({
    Expression<int>? partId,
    Expression<String>? messageId,
    Expression<int>? ordinal,
    Expression<String>? kind,
    Expression<String>? toolCallId,
    Expression<String>? toolName,
    Expression<String>? argumentsJson,
    Expression<String>? content,
    Expression<String>? status,
    Expression<String>? approvalState,
    Expression<String>? metadataJson,
    Expression<int>? createdAtMs,
    Expression<int>? updatedAtMs,
  }) {
    return RawValuesInsertable({
      if (partId != null) 'part_id': partId,
      if (messageId != null) 'message_id': messageId,
      if (ordinal != null) 'ordinal': ordinal,
      if (kind != null) 'kind': kind,
      if (toolCallId != null) 'tool_call_id': toolCallId,
      if (toolName != null) 'tool_name': toolName,
      if (argumentsJson != null) 'arguments_json': argumentsJson,
      if (content != null) 'content': content,
      if (status != null) 'status': status,
      if (approvalState != null) 'approval_state': approvalState,
      if (metadataJson != null) 'metadata_json': metadataJson,
      if (createdAtMs != null) 'created_at': createdAtMs,
      if (updatedAtMs != null) 'updated_at': updatedAtMs,
    });
  }

  MessagePartsCompanion copyWith({
    Value<int>? partId,
    Value<String>? messageId,
    Value<int>? ordinal,
    Value<String>? kind,
    Value<String?>? toolCallId,
    Value<String?>? toolName,
    Value<String?>? argumentsJson,
    Value<String?>? content,
    Value<String>? status,
    Value<String?>? approvalState,
    Value<String?>? metadataJson,
    Value<int>? createdAtMs,
    Value<int>? updatedAtMs,
  }) {
    return MessagePartsCompanion(
      partId: partId ?? this.partId,
      messageId: messageId ?? this.messageId,
      ordinal: ordinal ?? this.ordinal,
      kind: kind ?? this.kind,
      toolCallId: toolCallId ?? this.toolCallId,
      toolName: toolName ?? this.toolName,
      argumentsJson: argumentsJson ?? this.argumentsJson,
      content: content ?? this.content,
      status: status ?? this.status,
      approvalState: approvalState ?? this.approvalState,
      metadataJson: metadataJson ?? this.metadataJson,
      createdAtMs: createdAtMs ?? this.createdAtMs,
      updatedAtMs: updatedAtMs ?? this.updatedAtMs,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (partId.present) {
      map['part_id'] = Variable<int>(partId.value);
    }
    if (messageId.present) {
      map['message_id'] = Variable<String>(messageId.value);
    }
    if (ordinal.present) {
      map['ordinal'] = Variable<int>(ordinal.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (toolCallId.present) {
      map['tool_call_id'] = Variable<String>(toolCallId.value);
    }
    if (toolName.present) {
      map['tool_name'] = Variable<String>(toolName.value);
    }
    if (argumentsJson.present) {
      map['arguments_json'] = Variable<String>(argumentsJson.value);
    }
    if (content.present) {
      map['content'] = Variable<String>(content.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (approvalState.present) {
      map['approval_state'] = Variable<String>(approvalState.value);
    }
    if (metadataJson.present) {
      map['metadata_json'] = Variable<String>(metadataJson.value);
    }
    if (createdAtMs.present) {
      map['created_at'] = Variable<int>(createdAtMs.value);
    }
    if (updatedAtMs.present) {
      map['updated_at'] = Variable<int>(updatedAtMs.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MessagePartsCompanion(')
          ..write('partId: $partId, ')
          ..write('messageId: $messageId, ')
          ..write('ordinal: $ordinal, ')
          ..write('kind: $kind, ')
          ..write('toolCallId: $toolCallId, ')
          ..write('toolName: $toolName, ')
          ..write('argumentsJson: $argumentsJson, ')
          ..write('content: $content, ')
          ..write('status: $status, ')
          ..write('approvalState: $approvalState, ')
          ..write('metadataJson: $metadataJson, ')
          ..write('createdAtMs: $createdAtMs, ')
          ..write('updatedAtMs: $updatedAtMs')
          ..write(')'))
        .toString();
  }
}

class $ProviderArtifactsTable extends ProviderArtifacts
    with TableInfo<$ProviderArtifactsTable, ProviderArtifactRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ProviderArtifactsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _messageIdMeta = const VerificationMeta(
    'messageId',
  );
  @override
  late final GeneratedColumn<String> messageId = GeneratedColumn<String>(
    'message_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES messages (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
    'kind',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _payloadMeta = const VerificationMeta(
    'payload',
  );
  @override
  late final GeneratedColumn<String> payload = GeneratedColumn<String>(
    'payload',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtMsMeta = const VerificationMeta(
    'createdAtMs',
  );
  @override
  late final GeneratedColumn<int> createdAtMs = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMsMeta = const VerificationMeta(
    'updatedAtMs',
  );
  @override
  late final GeneratedColumn<int> updatedAtMs = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    messageId,
    kind,
    payload,
    createdAtMs,
    updatedAtMs,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'provider_artifacts';
  @override
  VerificationContext validateIntegrity(
    Insertable<ProviderArtifactRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('message_id')) {
      context.handle(
        _messageIdMeta,
        messageId.isAcceptableOrUnknown(data['message_id']!, _messageIdMeta),
      );
    } else if (isInserting) {
      context.missing(_messageIdMeta);
    }
    if (data.containsKey('kind')) {
      context.handle(
        _kindMeta,
        kind.isAcceptableOrUnknown(data['kind']!, _kindMeta),
      );
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('payload')) {
      context.handle(
        _payloadMeta,
        payload.isAcceptableOrUnknown(data['payload']!, _payloadMeta),
      );
    } else if (isInserting) {
      context.missing(_payloadMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMsMeta,
        createdAtMs.isAcceptableOrUnknown(
          data['created_at']!,
          _createdAtMsMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_createdAtMsMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMsMeta,
        updatedAtMs.isAcceptableOrUnknown(
          data['updated_at']!,
          _updatedAtMsMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMsMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {messageId, kind};
  @override
  ProviderArtifactRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ProviderArtifactRow(
      messageId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}message_id'],
      )!,
      kind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}kind'],
      )!,
      payload: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}payload'],
      )!,
      createdAtMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAtMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $ProviderArtifactsTable createAlias(String alias) {
    return $ProviderArtifactsTable(attachedDatabase, alias);
  }
}

class ProviderArtifactRow extends DataClass
    implements Insertable<ProviderArtifactRow> {
  final String messageId;
  final String kind;
  final String payload;
  final int createdAtMs;
  final int updatedAtMs;
  const ProviderArtifactRow({
    required this.messageId,
    required this.kind,
    required this.payload,
    required this.createdAtMs,
    required this.updatedAtMs,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['message_id'] = Variable<String>(messageId);
    map['kind'] = Variable<String>(kind);
    map['payload'] = Variable<String>(payload);
    map['created_at'] = Variable<int>(createdAtMs);
    map['updated_at'] = Variable<int>(updatedAtMs);
    return map;
  }

  ProviderArtifactsCompanion toCompanion(bool nullToAbsent) {
    return ProviderArtifactsCompanion(
      messageId: Value(messageId),
      kind: Value(kind),
      payload: Value(payload),
      createdAtMs: Value(createdAtMs),
      updatedAtMs: Value(updatedAtMs),
    );
  }

  factory ProviderArtifactRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ProviderArtifactRow(
      messageId: serializer.fromJson<String>(json['messageId']),
      kind: serializer.fromJson<String>(json['kind']),
      payload: serializer.fromJson<String>(json['payload']),
      createdAtMs: serializer.fromJson<int>(json['createdAtMs']),
      updatedAtMs: serializer.fromJson<int>(json['updatedAtMs']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'messageId': serializer.toJson<String>(messageId),
      'kind': serializer.toJson<String>(kind),
      'payload': serializer.toJson<String>(payload),
      'createdAtMs': serializer.toJson<int>(createdAtMs),
      'updatedAtMs': serializer.toJson<int>(updatedAtMs),
    };
  }

  ProviderArtifactRow copyWith({
    String? messageId,
    String? kind,
    String? payload,
    int? createdAtMs,
    int? updatedAtMs,
  }) => ProviderArtifactRow(
    messageId: messageId ?? this.messageId,
    kind: kind ?? this.kind,
    payload: payload ?? this.payload,
    createdAtMs: createdAtMs ?? this.createdAtMs,
    updatedAtMs: updatedAtMs ?? this.updatedAtMs,
  );
  ProviderArtifactRow copyWithCompanion(ProviderArtifactsCompanion data) {
    return ProviderArtifactRow(
      messageId: data.messageId.present ? data.messageId.value : this.messageId,
      kind: data.kind.present ? data.kind.value : this.kind,
      payload: data.payload.present ? data.payload.value : this.payload,
      createdAtMs: data.createdAtMs.present
          ? data.createdAtMs.value
          : this.createdAtMs,
      updatedAtMs: data.updatedAtMs.present
          ? data.updatedAtMs.value
          : this.updatedAtMs,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ProviderArtifactRow(')
          ..write('messageId: $messageId, ')
          ..write('kind: $kind, ')
          ..write('payload: $payload, ')
          ..write('createdAtMs: $createdAtMs, ')
          ..write('updatedAtMs: $updatedAtMs')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(messageId, kind, payload, createdAtMs, updatedAtMs);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ProviderArtifactRow &&
          other.messageId == this.messageId &&
          other.kind == this.kind &&
          other.payload == this.payload &&
          other.createdAtMs == this.createdAtMs &&
          other.updatedAtMs == this.updatedAtMs);
}

class ProviderArtifactsCompanion extends UpdateCompanion<ProviderArtifactRow> {
  final Value<String> messageId;
  final Value<String> kind;
  final Value<String> payload;
  final Value<int> createdAtMs;
  final Value<int> updatedAtMs;
  final Value<int> rowid;
  const ProviderArtifactsCompanion({
    this.messageId = const Value.absent(),
    this.kind = const Value.absent(),
    this.payload = const Value.absent(),
    this.createdAtMs = const Value.absent(),
    this.updatedAtMs = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ProviderArtifactsCompanion.insert({
    required String messageId,
    required String kind,
    required String payload,
    required int createdAtMs,
    required int updatedAtMs,
    this.rowid = const Value.absent(),
  }) : messageId = Value(messageId),
       kind = Value(kind),
       payload = Value(payload),
       createdAtMs = Value(createdAtMs),
       updatedAtMs = Value(updatedAtMs);
  static Insertable<ProviderArtifactRow> custom({
    Expression<String>? messageId,
    Expression<String>? kind,
    Expression<String>? payload,
    Expression<int>? createdAtMs,
    Expression<int>? updatedAtMs,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (messageId != null) 'message_id': messageId,
      if (kind != null) 'kind': kind,
      if (payload != null) 'payload': payload,
      if (createdAtMs != null) 'created_at': createdAtMs,
      if (updatedAtMs != null) 'updated_at': updatedAtMs,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ProviderArtifactsCompanion copyWith({
    Value<String>? messageId,
    Value<String>? kind,
    Value<String>? payload,
    Value<int>? createdAtMs,
    Value<int>? updatedAtMs,
    Value<int>? rowid,
  }) {
    return ProviderArtifactsCompanion(
      messageId: messageId ?? this.messageId,
      kind: kind ?? this.kind,
      payload: payload ?? this.payload,
      createdAtMs: createdAtMs ?? this.createdAtMs,
      updatedAtMs: updatedAtMs ?? this.updatedAtMs,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (messageId.present) {
      map['message_id'] = Variable<String>(messageId.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (payload.present) {
      map['payload'] = Variable<String>(payload.value);
    }
    if (createdAtMs.present) {
      map['created_at'] = Variable<int>(createdAtMs.value);
    }
    if (updatedAtMs.present) {
      map['updated_at'] = Variable<int>(updatedAtMs.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ProviderArtifactsCompanion(')
          ..write('messageId: $messageId, ')
          ..write('kind: $kind, ')
          ..write('payload: $payload, ')
          ..write('createdAtMs: $createdAtMs, ')
          ..write('updatedAtMs: $updatedAtMs, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $MessageFileRecordsTable extends MessageFileRecords
    with TableInfo<$MessageFileRecordsTable, MessageFileRecordRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MessageFileRecordsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _messageIdMeta = const VerificationMeta(
    'messageId',
  );
  @override
  late final GeneratedColumn<String> messageId = GeneratedColumn<String>(
    'message_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES messages (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _ordinalMeta = const VerificationMeta(
    'ordinal',
  );
  @override
  late final GeneratedColumn<int> ordinal = GeneratedColumn<int>(
    'ordinal',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _pathMeta = const VerificationMeta('path');
  @override
  late final GeneratedColumn<String> path = GeneratedColumn<String>(
    'path',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _fileNameMeta = const VerificationMeta(
    'fileName',
  );
  @override
  late final GeneratedColumn<String> fileName = GeneratedColumn<String>(
    'file_name',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _sizeBytesMeta = const VerificationMeta(
    'sizeBytes',
  );
  @override
  late final GeneratedColumn<int> sizeBytes = GeneratedColumn<int>(
    'size_bytes',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _createdAtMsMeta = const VerificationMeta(
    'createdAtMs',
  );
  @override
  late final GeneratedColumn<int> createdAtMs = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    messageId,
    ordinal,
    path,
    fileName,
    sizeBytes,
    createdAtMs,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'message_file_records';
  @override
  VerificationContext validateIntegrity(
    Insertable<MessageFileRecordRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('message_id')) {
      context.handle(
        _messageIdMeta,
        messageId.isAcceptableOrUnknown(data['message_id']!, _messageIdMeta),
      );
    } else if (isInserting) {
      context.missing(_messageIdMeta);
    }
    if (data.containsKey('ordinal')) {
      context.handle(
        _ordinalMeta,
        ordinal.isAcceptableOrUnknown(data['ordinal']!, _ordinalMeta),
      );
    } else if (isInserting) {
      context.missing(_ordinalMeta);
    }
    if (data.containsKey('path')) {
      context.handle(
        _pathMeta,
        path.isAcceptableOrUnknown(data['path']!, _pathMeta),
      );
    } else if (isInserting) {
      context.missing(_pathMeta);
    }
    if (data.containsKey('file_name')) {
      context.handle(
        _fileNameMeta,
        fileName.isAcceptableOrUnknown(data['file_name']!, _fileNameMeta),
      );
    }
    if (data.containsKey('size_bytes')) {
      context.handle(
        _sizeBytesMeta,
        sizeBytes.isAcceptableOrUnknown(data['size_bytes']!, _sizeBytesMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMsMeta,
        createdAtMs.isAcceptableOrUnknown(
          data['created_at']!,
          _createdAtMsMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_createdAtMsMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  MessageFileRecordRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MessageFileRecordRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      messageId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}message_id'],
      )!,
      ordinal: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}ordinal'],
      )!,
      path: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}path'],
      )!,
      fileName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}file_name'],
      ),
      sizeBytes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}size_bytes'],
      )!,
      createdAtMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $MessageFileRecordsTable createAlias(String alias) {
    return $MessageFileRecordsTable(attachedDatabase, alias);
  }
}

class MessageFileRecordRow extends DataClass
    implements Insertable<MessageFileRecordRow> {
  final int id;
  final String messageId;
  final int ordinal;
  final String path;
  final String? fileName;
  final int sizeBytes;
  final int createdAtMs;
  const MessageFileRecordRow({
    required this.id,
    required this.messageId,
    required this.ordinal,
    required this.path,
    this.fileName,
    required this.sizeBytes,
    required this.createdAtMs,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['message_id'] = Variable<String>(messageId);
    map['ordinal'] = Variable<int>(ordinal);
    map['path'] = Variable<String>(path);
    if (!nullToAbsent || fileName != null) {
      map['file_name'] = Variable<String>(fileName);
    }
    map['size_bytes'] = Variable<int>(sizeBytes);
    map['created_at'] = Variable<int>(createdAtMs);
    return map;
  }

  MessageFileRecordsCompanion toCompanion(bool nullToAbsent) {
    return MessageFileRecordsCompanion(
      id: Value(id),
      messageId: Value(messageId),
      ordinal: Value(ordinal),
      path: Value(path),
      fileName: fileName == null && nullToAbsent
          ? const Value.absent()
          : Value(fileName),
      sizeBytes: Value(sizeBytes),
      createdAtMs: Value(createdAtMs),
    );
  }

  factory MessageFileRecordRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MessageFileRecordRow(
      id: serializer.fromJson<int>(json['id']),
      messageId: serializer.fromJson<String>(json['messageId']),
      ordinal: serializer.fromJson<int>(json['ordinal']),
      path: serializer.fromJson<String>(json['path']),
      fileName: serializer.fromJson<String?>(json['fileName']),
      sizeBytes: serializer.fromJson<int>(json['sizeBytes']),
      createdAtMs: serializer.fromJson<int>(json['createdAtMs']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'messageId': serializer.toJson<String>(messageId),
      'ordinal': serializer.toJson<int>(ordinal),
      'path': serializer.toJson<String>(path),
      'fileName': serializer.toJson<String?>(fileName),
      'sizeBytes': serializer.toJson<int>(sizeBytes),
      'createdAtMs': serializer.toJson<int>(createdAtMs),
    };
  }

  MessageFileRecordRow copyWith({
    int? id,
    String? messageId,
    int? ordinal,
    String? path,
    Value<String?> fileName = const Value.absent(),
    int? sizeBytes,
    int? createdAtMs,
  }) => MessageFileRecordRow(
    id: id ?? this.id,
    messageId: messageId ?? this.messageId,
    ordinal: ordinal ?? this.ordinal,
    path: path ?? this.path,
    fileName: fileName.present ? fileName.value : this.fileName,
    sizeBytes: sizeBytes ?? this.sizeBytes,
    createdAtMs: createdAtMs ?? this.createdAtMs,
  );
  MessageFileRecordRow copyWithCompanion(MessageFileRecordsCompanion data) {
    return MessageFileRecordRow(
      id: data.id.present ? data.id.value : this.id,
      messageId: data.messageId.present ? data.messageId.value : this.messageId,
      ordinal: data.ordinal.present ? data.ordinal.value : this.ordinal,
      path: data.path.present ? data.path.value : this.path,
      fileName: data.fileName.present ? data.fileName.value : this.fileName,
      sizeBytes: data.sizeBytes.present ? data.sizeBytes.value : this.sizeBytes,
      createdAtMs: data.createdAtMs.present
          ? data.createdAtMs.value
          : this.createdAtMs,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MessageFileRecordRow(')
          ..write('id: $id, ')
          ..write('messageId: $messageId, ')
          ..write('ordinal: $ordinal, ')
          ..write('path: $path, ')
          ..write('fileName: $fileName, ')
          ..write('sizeBytes: $sizeBytes, ')
          ..write('createdAtMs: $createdAtMs')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    messageId,
    ordinal,
    path,
    fileName,
    sizeBytes,
    createdAtMs,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MessageFileRecordRow &&
          other.id == this.id &&
          other.messageId == this.messageId &&
          other.ordinal == this.ordinal &&
          other.path == this.path &&
          other.fileName == this.fileName &&
          other.sizeBytes == this.sizeBytes &&
          other.createdAtMs == this.createdAtMs);
}

class MessageFileRecordsCompanion
    extends UpdateCompanion<MessageFileRecordRow> {
  final Value<int> id;
  final Value<String> messageId;
  final Value<int> ordinal;
  final Value<String> path;
  final Value<String?> fileName;
  final Value<int> sizeBytes;
  final Value<int> createdAtMs;
  const MessageFileRecordsCompanion({
    this.id = const Value.absent(),
    this.messageId = const Value.absent(),
    this.ordinal = const Value.absent(),
    this.path = const Value.absent(),
    this.fileName = const Value.absent(),
    this.sizeBytes = const Value.absent(),
    this.createdAtMs = const Value.absent(),
  });
  MessageFileRecordsCompanion.insert({
    this.id = const Value.absent(),
    required String messageId,
    required int ordinal,
    required String path,
    this.fileName = const Value.absent(),
    this.sizeBytes = const Value.absent(),
    required int createdAtMs,
  }) : messageId = Value(messageId),
       ordinal = Value(ordinal),
       path = Value(path),
       createdAtMs = Value(createdAtMs);
  static Insertable<MessageFileRecordRow> custom({
    Expression<int>? id,
    Expression<String>? messageId,
    Expression<int>? ordinal,
    Expression<String>? path,
    Expression<String>? fileName,
    Expression<int>? sizeBytes,
    Expression<int>? createdAtMs,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (messageId != null) 'message_id': messageId,
      if (ordinal != null) 'ordinal': ordinal,
      if (path != null) 'path': path,
      if (fileName != null) 'file_name': fileName,
      if (sizeBytes != null) 'size_bytes': sizeBytes,
      if (createdAtMs != null) 'created_at': createdAtMs,
    });
  }

  MessageFileRecordsCompanion copyWith({
    Value<int>? id,
    Value<String>? messageId,
    Value<int>? ordinal,
    Value<String>? path,
    Value<String?>? fileName,
    Value<int>? sizeBytes,
    Value<int>? createdAtMs,
  }) {
    return MessageFileRecordsCompanion(
      id: id ?? this.id,
      messageId: messageId ?? this.messageId,
      ordinal: ordinal ?? this.ordinal,
      path: path ?? this.path,
      fileName: fileName ?? this.fileName,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      createdAtMs: createdAtMs ?? this.createdAtMs,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (messageId.present) {
      map['message_id'] = Variable<String>(messageId.value);
    }
    if (ordinal.present) {
      map['ordinal'] = Variable<int>(ordinal.value);
    }
    if (path.present) {
      map['path'] = Variable<String>(path.value);
    }
    if (fileName.present) {
      map['file_name'] = Variable<String>(fileName.value);
    }
    if (sizeBytes.present) {
      map['size_bytes'] = Variable<int>(sizeBytes.value);
    }
    if (createdAtMs.present) {
      map['created_at'] = Variable<int>(createdAtMs.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MessageFileRecordsCompanion(')
          ..write('id: $id, ')
          ..write('messageId: $messageId, ')
          ..write('ordinal: $ordinal, ')
          ..write('path: $path, ')
          ..write('fileName: $fileName, ')
          ..write('sizeBytes: $sizeBytes, ')
          ..write('createdAtMs: $createdAtMs')
          ..write(')'))
        .toString();
  }
}

class $ConversationWorkspaceBindingsTable extends ConversationWorkspaceBindings
    with
        TableInfo<
          $ConversationWorkspaceBindingsTable,
          ConversationWorkspaceBindingRow
        > {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ConversationWorkspaceBindingsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _conversationIdMeta = const VerificationMeta(
    'conversationId',
  );
  @override
  late final GeneratedColumn<String> conversationId = GeneratedColumn<String>(
    'conversation_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES conversations (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _configJsonMeta = const VerificationMeta(
    'configJson',
  );
  @override
  late final GeneratedColumn<String> configJson = GeneratedColumn<String>(
    'config_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMsMeta = const VerificationMeta(
    'updatedAtMs',
  );
  @override
  late final GeneratedColumn<int> updatedAtMs = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    conversationId,
    configJson,
    updatedAtMs,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'conversation_workspace_bindings';
  @override
  VerificationContext validateIntegrity(
    Insertable<ConversationWorkspaceBindingRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('conversation_id')) {
      context.handle(
        _conversationIdMeta,
        conversationId.isAcceptableOrUnknown(
          data['conversation_id']!,
          _conversationIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_conversationIdMeta);
    }
    if (data.containsKey('config_json')) {
      context.handle(
        _configJsonMeta,
        configJson.isAcceptableOrUnknown(data['config_json']!, _configJsonMeta),
      );
    } else if (isInserting) {
      context.missing(_configJsonMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMsMeta,
        updatedAtMs.isAcceptableOrUnknown(
          data['updated_at']!,
          _updatedAtMsMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMsMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {conversationId};
  @override
  ConversationWorkspaceBindingRow map(
    Map<String, dynamic> data, {
    String? tablePrefix,
  }) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ConversationWorkspaceBindingRow(
      conversationId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}conversation_id'],
      )!,
      configJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}config_json'],
      )!,
      updatedAtMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $ConversationWorkspaceBindingsTable createAlias(String alias) {
    return $ConversationWorkspaceBindingsTable(attachedDatabase, alias);
  }
}

class ConversationWorkspaceBindingRow extends DataClass
    implements Insertable<ConversationWorkspaceBindingRow> {
  final String conversationId;
  final String configJson;
  final int updatedAtMs;
  const ConversationWorkspaceBindingRow({
    required this.conversationId,
    required this.configJson,
    required this.updatedAtMs,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['conversation_id'] = Variable<String>(conversationId);
    map['config_json'] = Variable<String>(configJson);
    map['updated_at'] = Variable<int>(updatedAtMs);
    return map;
  }

  ConversationWorkspaceBindingsCompanion toCompanion(bool nullToAbsent) {
    return ConversationWorkspaceBindingsCompanion(
      conversationId: Value(conversationId),
      configJson: Value(configJson),
      updatedAtMs: Value(updatedAtMs),
    );
  }

  factory ConversationWorkspaceBindingRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ConversationWorkspaceBindingRow(
      conversationId: serializer.fromJson<String>(json['conversationId']),
      configJson: serializer.fromJson<String>(json['configJson']),
      updatedAtMs: serializer.fromJson<int>(json['updatedAtMs']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'conversationId': serializer.toJson<String>(conversationId),
      'configJson': serializer.toJson<String>(configJson),
      'updatedAtMs': serializer.toJson<int>(updatedAtMs),
    };
  }

  ConversationWorkspaceBindingRow copyWith({
    String? conversationId,
    String? configJson,
    int? updatedAtMs,
  }) => ConversationWorkspaceBindingRow(
    conversationId: conversationId ?? this.conversationId,
    configJson: configJson ?? this.configJson,
    updatedAtMs: updatedAtMs ?? this.updatedAtMs,
  );
  ConversationWorkspaceBindingRow copyWithCompanion(
    ConversationWorkspaceBindingsCompanion data,
  ) {
    return ConversationWorkspaceBindingRow(
      conversationId: data.conversationId.present
          ? data.conversationId.value
          : this.conversationId,
      configJson: data.configJson.present
          ? data.configJson.value
          : this.configJson,
      updatedAtMs: data.updatedAtMs.present
          ? data.updatedAtMs.value
          : this.updatedAtMs,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ConversationWorkspaceBindingRow(')
          ..write('conversationId: $conversationId, ')
          ..write('configJson: $configJson, ')
          ..write('updatedAtMs: $updatedAtMs')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(conversationId, configJson, updatedAtMs);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ConversationWorkspaceBindingRow &&
          other.conversationId == this.conversationId &&
          other.configJson == this.configJson &&
          other.updatedAtMs == this.updatedAtMs);
}

class ConversationWorkspaceBindingsCompanion
    extends UpdateCompanion<ConversationWorkspaceBindingRow> {
  final Value<String> conversationId;
  final Value<String> configJson;
  final Value<int> updatedAtMs;
  final Value<int> rowid;
  const ConversationWorkspaceBindingsCompanion({
    this.conversationId = const Value.absent(),
    this.configJson = const Value.absent(),
    this.updatedAtMs = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ConversationWorkspaceBindingsCompanion.insert({
    required String conversationId,
    required String configJson,
    required int updatedAtMs,
    this.rowid = const Value.absent(),
  }) : conversationId = Value(conversationId),
       configJson = Value(configJson),
       updatedAtMs = Value(updatedAtMs);
  static Insertable<ConversationWorkspaceBindingRow> custom({
    Expression<String>? conversationId,
    Expression<String>? configJson,
    Expression<int>? updatedAtMs,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (conversationId != null) 'conversation_id': conversationId,
      if (configJson != null) 'config_json': configJson,
      if (updatedAtMs != null) 'updated_at': updatedAtMs,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ConversationWorkspaceBindingsCompanion copyWith({
    Value<String>? conversationId,
    Value<String>? configJson,
    Value<int>? updatedAtMs,
    Value<int>? rowid,
  }) {
    return ConversationWorkspaceBindingsCompanion(
      conversationId: conversationId ?? this.conversationId,
      configJson: configJson ?? this.configJson,
      updatedAtMs: updatedAtMs ?? this.updatedAtMs,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (conversationId.present) {
      map['conversation_id'] = Variable<String>(conversationId.value);
    }
    if (configJson.present) {
      map['config_json'] = Variable<String>(configJson.value);
    }
    if (updatedAtMs.present) {
      map['updated_at'] = Variable<int>(updatedAtMs.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ConversationWorkspaceBindingsCompanion(')
          ..write('conversationId: $conversationId, ')
          ..write('configJson: $configJson, ')
          ..write('updatedAtMs: $updatedAtMs, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $MigrationMetaTable extends MigrationMeta
    with TableInfo<$MigrationMetaTable, MigrationMetaRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MigrationMetaTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
    'value',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [key, value];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'migration_meta';
  @override
  VerificationContext validateIntegrity(
    Insertable<MigrationMetaRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
        _keyMeta,
        key.isAcceptableOrUnknown(data['key']!, _keyMeta),
      );
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
        _valueMeta,
        value.isAcceptableOrUnknown(data['value']!, _valueMeta),
      );
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  MigrationMetaRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MigrationMetaRow(
      key: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key'],
      )!,
      value: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}value'],
      )!,
    );
  }

  @override
  $MigrationMetaTable createAlias(String alias) {
    return $MigrationMetaTable(attachedDatabase, alias);
  }
}

class MigrationMetaRow extends DataClass
    implements Insertable<MigrationMetaRow> {
  final String key;
  final String value;
  const MigrationMetaRow({required this.key, required this.value});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    return map;
  }

  MigrationMetaCompanion toCompanion(bool nullToAbsent) {
    return MigrationMetaCompanion(key: Value(key), value: Value(value));
  }

  factory MigrationMetaRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MigrationMetaRow(
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<String>(json['value']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'value': serializer.toJson<String>(value),
    };
  }

  MigrationMetaRow copyWith({String? key, String? value}) =>
      MigrationMetaRow(key: key ?? this.key, value: value ?? this.value);
  MigrationMetaRow copyWithCompanion(MigrationMetaCompanion data) {
    return MigrationMetaRow(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MigrationMetaRow(')
          ..write('key: $key, ')
          ..write('value: $value')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, value);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MigrationMetaRow &&
          other.key == this.key &&
          other.value == this.value);
}

class MigrationMetaCompanion extends UpdateCompanion<MigrationMetaRow> {
  final Value<String> key;
  final Value<String> value;
  final Value<int> rowid;
  const MigrationMetaCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MigrationMetaCompanion.insert({
    required String key,
    required String value,
    this.rowid = const Value.absent(),
  }) : key = Value(key),
       value = Value(value);
  static Insertable<MigrationMetaRow> custom({
    Expression<String>? key,
    Expression<String>? value,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MigrationMetaCompanion copyWith({
    Value<String>? key,
    Value<String>? value,
    Value<int>? rowid,
  }) {
    return MigrationMetaCompanion(
      key: key ?? this.key,
      value: value ?? this.value,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MigrationMetaCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LegacyQuarantineTable extends LegacyQuarantine
    with TableInfo<$LegacyQuarantineTable, LegacyQuarantineRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LegacyQuarantineTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _sourceBoxMeta = const VerificationMeta(
    'sourceBox',
  );
  @override
  late final GeneratedColumn<String> sourceBox = GeneratedColumn<String>(
    'source_box',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sourceKeyMeta = const VerificationMeta(
    'sourceKey',
  );
  @override
  late final GeneratedColumn<String> sourceKey = GeneratedColumn<String>(
    'source_key',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _payloadJsonMeta = const VerificationMeta(
    'payloadJson',
  );
  @override
  late final GeneratedColumn<String> payloadJson = GeneratedColumn<String>(
    'payload_json',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _payloadSha256Meta = const VerificationMeta(
    'payloadSha256',
  );
  @override
  late final GeneratedColumn<String> payloadSha256 = GeneratedColumn<String>(
    'payload_sha256',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _errorMeta = const VerificationMeta('error');
  @override
  late final GeneratedColumn<String> error = GeneratedColumn<String>(
    'error',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtMsMeta = const VerificationMeta(
    'createdAtMs',
  );
  @override
  late final GeneratedColumn<int> createdAtMs = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    sourceBox,
    sourceKey,
    payloadJson,
    payloadSha256,
    error,
    createdAtMs,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'legacy_quarantine';
  @override
  VerificationContext validateIntegrity(
    Insertable<LegacyQuarantineRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('source_box')) {
      context.handle(
        _sourceBoxMeta,
        sourceBox.isAcceptableOrUnknown(data['source_box']!, _sourceBoxMeta),
      );
    } else if (isInserting) {
      context.missing(_sourceBoxMeta);
    }
    if (data.containsKey('source_key')) {
      context.handle(
        _sourceKeyMeta,
        sourceKey.isAcceptableOrUnknown(data['source_key']!, _sourceKeyMeta),
      );
    }
    if (data.containsKey('payload_json')) {
      context.handle(
        _payloadJsonMeta,
        payloadJson.isAcceptableOrUnknown(
          data['payload_json']!,
          _payloadJsonMeta,
        ),
      );
    }
    if (data.containsKey('payload_sha256')) {
      context.handle(
        _payloadSha256Meta,
        payloadSha256.isAcceptableOrUnknown(
          data['payload_sha256']!,
          _payloadSha256Meta,
        ),
      );
    }
    if (data.containsKey('error')) {
      context.handle(
        _errorMeta,
        error.isAcceptableOrUnknown(data['error']!, _errorMeta),
      );
    } else if (isInserting) {
      context.missing(_errorMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMsMeta,
        createdAtMs.isAcceptableOrUnknown(
          data['created_at']!,
          _createdAtMsMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_createdAtMsMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  LegacyQuarantineRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LegacyQuarantineRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      sourceBox: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source_box'],
      )!,
      sourceKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source_key'],
      ),
      payloadJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}payload_json'],
      ),
      payloadSha256: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}payload_sha256'],
      ),
      error: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}error'],
      )!,
      createdAtMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $LegacyQuarantineTable createAlias(String alias) {
    return $LegacyQuarantineTable(attachedDatabase, alias);
  }
}

class LegacyQuarantineRow extends DataClass
    implements Insertable<LegacyQuarantineRow> {
  final int id;
  final String sourceBox;
  final String? sourceKey;
  final String? payloadJson;
  final String? payloadSha256;
  final String error;
  final int createdAtMs;
  const LegacyQuarantineRow({
    required this.id,
    required this.sourceBox,
    this.sourceKey,
    this.payloadJson,
    this.payloadSha256,
    required this.error,
    required this.createdAtMs,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['source_box'] = Variable<String>(sourceBox);
    if (!nullToAbsent || sourceKey != null) {
      map['source_key'] = Variable<String>(sourceKey);
    }
    if (!nullToAbsent || payloadJson != null) {
      map['payload_json'] = Variable<String>(payloadJson);
    }
    if (!nullToAbsent || payloadSha256 != null) {
      map['payload_sha256'] = Variable<String>(payloadSha256);
    }
    map['error'] = Variable<String>(error);
    map['created_at'] = Variable<int>(createdAtMs);
    return map;
  }

  LegacyQuarantineCompanion toCompanion(bool nullToAbsent) {
    return LegacyQuarantineCompanion(
      id: Value(id),
      sourceBox: Value(sourceBox),
      sourceKey: sourceKey == null && nullToAbsent
          ? const Value.absent()
          : Value(sourceKey),
      payloadJson: payloadJson == null && nullToAbsent
          ? const Value.absent()
          : Value(payloadJson),
      payloadSha256: payloadSha256 == null && nullToAbsent
          ? const Value.absent()
          : Value(payloadSha256),
      error: Value(error),
      createdAtMs: Value(createdAtMs),
    );
  }

  factory LegacyQuarantineRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LegacyQuarantineRow(
      id: serializer.fromJson<int>(json['id']),
      sourceBox: serializer.fromJson<String>(json['sourceBox']),
      sourceKey: serializer.fromJson<String?>(json['sourceKey']),
      payloadJson: serializer.fromJson<String?>(json['payloadJson']),
      payloadSha256: serializer.fromJson<String?>(json['payloadSha256']),
      error: serializer.fromJson<String>(json['error']),
      createdAtMs: serializer.fromJson<int>(json['createdAtMs']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'sourceBox': serializer.toJson<String>(sourceBox),
      'sourceKey': serializer.toJson<String?>(sourceKey),
      'payloadJson': serializer.toJson<String?>(payloadJson),
      'payloadSha256': serializer.toJson<String?>(payloadSha256),
      'error': serializer.toJson<String>(error),
      'createdAtMs': serializer.toJson<int>(createdAtMs),
    };
  }

  LegacyQuarantineRow copyWith({
    int? id,
    String? sourceBox,
    Value<String?> sourceKey = const Value.absent(),
    Value<String?> payloadJson = const Value.absent(),
    Value<String?> payloadSha256 = const Value.absent(),
    String? error,
    int? createdAtMs,
  }) => LegacyQuarantineRow(
    id: id ?? this.id,
    sourceBox: sourceBox ?? this.sourceBox,
    sourceKey: sourceKey.present ? sourceKey.value : this.sourceKey,
    payloadJson: payloadJson.present ? payloadJson.value : this.payloadJson,
    payloadSha256: payloadSha256.present
        ? payloadSha256.value
        : this.payloadSha256,
    error: error ?? this.error,
    createdAtMs: createdAtMs ?? this.createdAtMs,
  );
  LegacyQuarantineRow copyWithCompanion(LegacyQuarantineCompanion data) {
    return LegacyQuarantineRow(
      id: data.id.present ? data.id.value : this.id,
      sourceBox: data.sourceBox.present ? data.sourceBox.value : this.sourceBox,
      sourceKey: data.sourceKey.present ? data.sourceKey.value : this.sourceKey,
      payloadJson: data.payloadJson.present
          ? data.payloadJson.value
          : this.payloadJson,
      payloadSha256: data.payloadSha256.present
          ? data.payloadSha256.value
          : this.payloadSha256,
      error: data.error.present ? data.error.value : this.error,
      createdAtMs: data.createdAtMs.present
          ? data.createdAtMs.value
          : this.createdAtMs,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LegacyQuarantineRow(')
          ..write('id: $id, ')
          ..write('sourceBox: $sourceBox, ')
          ..write('sourceKey: $sourceKey, ')
          ..write('payloadJson: $payloadJson, ')
          ..write('payloadSha256: $payloadSha256, ')
          ..write('error: $error, ')
          ..write('createdAtMs: $createdAtMs')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    sourceBox,
    sourceKey,
    payloadJson,
    payloadSha256,
    error,
    createdAtMs,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LegacyQuarantineRow &&
          other.id == this.id &&
          other.sourceBox == this.sourceBox &&
          other.sourceKey == this.sourceKey &&
          other.payloadJson == this.payloadJson &&
          other.payloadSha256 == this.payloadSha256 &&
          other.error == this.error &&
          other.createdAtMs == this.createdAtMs);
}

class LegacyQuarantineCompanion extends UpdateCompanion<LegacyQuarantineRow> {
  final Value<int> id;
  final Value<String> sourceBox;
  final Value<String?> sourceKey;
  final Value<String?> payloadJson;
  final Value<String?> payloadSha256;
  final Value<String> error;
  final Value<int> createdAtMs;
  const LegacyQuarantineCompanion({
    this.id = const Value.absent(),
    this.sourceBox = const Value.absent(),
    this.sourceKey = const Value.absent(),
    this.payloadJson = const Value.absent(),
    this.payloadSha256 = const Value.absent(),
    this.error = const Value.absent(),
    this.createdAtMs = const Value.absent(),
  });
  LegacyQuarantineCompanion.insert({
    this.id = const Value.absent(),
    required String sourceBox,
    this.sourceKey = const Value.absent(),
    this.payloadJson = const Value.absent(),
    this.payloadSha256 = const Value.absent(),
    required String error,
    required int createdAtMs,
  }) : sourceBox = Value(sourceBox),
       error = Value(error),
       createdAtMs = Value(createdAtMs);
  static Insertable<LegacyQuarantineRow> custom({
    Expression<int>? id,
    Expression<String>? sourceBox,
    Expression<String>? sourceKey,
    Expression<String>? payloadJson,
    Expression<String>? payloadSha256,
    Expression<String>? error,
    Expression<int>? createdAtMs,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (sourceBox != null) 'source_box': sourceBox,
      if (sourceKey != null) 'source_key': sourceKey,
      if (payloadJson != null) 'payload_json': payloadJson,
      if (payloadSha256 != null) 'payload_sha256': payloadSha256,
      if (error != null) 'error': error,
      if (createdAtMs != null) 'created_at': createdAtMs,
    });
  }

  LegacyQuarantineCompanion copyWith({
    Value<int>? id,
    Value<String>? sourceBox,
    Value<String?>? sourceKey,
    Value<String?>? payloadJson,
    Value<String?>? payloadSha256,
    Value<String>? error,
    Value<int>? createdAtMs,
  }) {
    return LegacyQuarantineCompanion(
      id: id ?? this.id,
      sourceBox: sourceBox ?? this.sourceBox,
      sourceKey: sourceKey ?? this.sourceKey,
      payloadJson: payloadJson ?? this.payloadJson,
      payloadSha256: payloadSha256 ?? this.payloadSha256,
      error: error ?? this.error,
      createdAtMs: createdAtMs ?? this.createdAtMs,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (sourceBox.present) {
      map['source_box'] = Variable<String>(sourceBox.value);
    }
    if (sourceKey.present) {
      map['source_key'] = Variable<String>(sourceKey.value);
    }
    if (payloadJson.present) {
      map['payload_json'] = Variable<String>(payloadJson.value);
    }
    if (payloadSha256.present) {
      map['payload_sha256'] = Variable<String>(payloadSha256.value);
    }
    if (error.present) {
      map['error'] = Variable<String>(error.value);
    }
    if (createdAtMs.present) {
      map['created_at'] = Variable<int>(createdAtMs.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LegacyQuarantineCompanion(')
          ..write('id: $id, ')
          ..write('sourceBox: $sourceBox, ')
          ..write('sourceKey: $sourceKey, ')
          ..write('payloadJson: $payloadJson, ')
          ..write('payloadSha256: $payloadSha256, ')
          ..write('error: $error, ')
          ..write('createdAtMs: $createdAtMs')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $ConversationRowsTable conversationRows = $ConversationRowsTable(
    this,
  );
  late final $MessageRowsTable messageRows = $MessageRowsTable(this);
  late final $MessagePartsTable messageParts = $MessagePartsTable(this);
  late final $ProviderArtifactsTable providerArtifacts =
      $ProviderArtifactsTable(this);
  late final $MessageFileRecordsTable messageFileRecords =
      $MessageFileRecordsTable(this);
  late final $ConversationWorkspaceBindingsTable conversationWorkspaceBindings =
      $ConversationWorkspaceBindingsTable(this);
  late final $MigrationMetaTable migrationMeta = $MigrationMetaTable(this);
  late final $LegacyQuarantineTable legacyQuarantine = $LegacyQuarantineTable(
    this,
  );
  late final Index idxConversationsUpdatedAt = Index(
    'idx_conversations_updated_at',
    'CREATE INDEX idx_conversations_updated_at ON conversations (updated_at)',
  );
  late final Index idxConversationsAssistantUpdated = Index(
    'idx_conversations_assistant_updated',
    'CREATE INDEX idx_conversations_assistant_updated ON conversations (assistant_id, updated_at)',
  );
  late final Index idxMessagesConversationOrdinal = Index(
    'idx_messages_conversation_ordinal',
    'CREATE UNIQUE INDEX idx_messages_conversation_ordinal ON messages (conversation_id, ordinal)',
  );
  late final Index idxMessagesGroupVersion = Index(
    'idx_messages_group_version',
    'CREATE INDEX idx_messages_group_version ON messages (conversation_id, group_id, version)',
  );
  late final Index idxMessagesStreaming = Index(
    'idx_messages_streaming',
    'CREATE INDEX idx_messages_streaming ON messages (is_streaming)',
  );
  late final Index uidxMessagePartsMessageOrdinal = Index(
    'uidx_message_parts_message_ordinal',
    'CREATE UNIQUE INDEX uidx_message_parts_message_ordinal ON message_parts (message_id, ordinal)',
  );
  late final Index idxMessagePartsToolCall = Index(
    'idx_message_parts_tool_call',
    'CREATE INDEX idx_message_parts_tool_call ON message_parts (message_id, tool_call_id)',
  );
  late final Index idxMessagePartsToolName = Index(
    'idx_message_parts_tool_name',
    'CREATE INDEX idx_message_parts_tool_name ON message_parts (message_id, tool_name, ordinal)',
  );
  late final Index idxMessageFileRecordsMessage = Index(
    'idx_message_file_records_message',
    'CREATE INDEX idx_message_file_records_message ON message_file_records (message_id, ordinal)',
  );
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    conversationRows,
    messageRows,
    messageParts,
    providerArtifacts,
    messageFileRecords,
    conversationWorkspaceBindings,
    migrationMeta,
    legacyQuarantine,
    idxConversationsUpdatedAt,
    idxConversationsAssistantUpdated,
    idxMessagesConversationOrdinal,
    idxMessagesGroupVersion,
    idxMessagesStreaming,
    uidxMessagePartsMessageOrdinal,
    idxMessagePartsToolCall,
    idxMessagePartsToolName,
    idxMessageFileRecordsMessage,
  ];
  @override
  StreamQueryUpdateRules get streamUpdateRules => const StreamQueryUpdateRules([
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'conversations',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('messages', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'messages',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('message_parts', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'messages',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('provider_artifacts', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'messages',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('message_file_records', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'conversations',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [
        TableUpdate('conversation_workspace_bindings', kind: UpdateKind.delete),
      ],
    ),
  ]);
}

typedef $$ConversationRowsTableCreateCompanionBuilder =
    ConversationRowsCompanion Function({
      required String id,
      required String title,
      required int createdAtMs,
      required int updatedAtMs,
      Value<String?> assistantId,
      Value<bool> isPinned,
      Value<int> truncateIndex,
      Value<int> compactBeforeIndex,
      Value<String?> summary,
      Value<int> lastSummarizedMessageCount,
      Value<String> mcpServerIdsJson,
      Value<String> versionSelectionsJson,
      Value<bool> isRecovered,
      Value<int> rowid,
    });
typedef $$ConversationRowsTableUpdateCompanionBuilder =
    ConversationRowsCompanion Function({
      Value<String> id,
      Value<String> title,
      Value<int> createdAtMs,
      Value<int> updatedAtMs,
      Value<String?> assistantId,
      Value<bool> isPinned,
      Value<int> truncateIndex,
      Value<int> compactBeforeIndex,
      Value<String?> summary,
      Value<int> lastSummarizedMessageCount,
      Value<String> mcpServerIdsJson,
      Value<String> versionSelectionsJson,
      Value<bool> isRecovered,
      Value<int> rowid,
    });

final class $$ConversationRowsTableReferences
    extends
        BaseReferences<_$AppDatabase, $ConversationRowsTable, ConversationRow> {
  $$ConversationRowsTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static MultiTypedResultKey<$MessageRowsTable, List<MessageRow>>
  _messageRowsRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.messageRows,
    aliasName: 'conversations__id__messages__conversation_id',
  );

  $$MessageRowsTableProcessedTableManager get messageRowsRefs {
    final manager = $$MessageRowsTableTableManager(
      $_db,
      $_db.messageRows,
    ).filter((f) => f.conversationId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_messageRowsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<
    $ConversationWorkspaceBindingsTable,
    List<ConversationWorkspaceBindingRow>
  >
  _conversationWorkspaceBindingsRefsTable(
    _$AppDatabase db,
  ) => MultiTypedResultKey.fromTable(
    db.conversationWorkspaceBindings,
    aliasName:
        'conversations__id__conversation_workspace_bindings__conversation_id',
  );

  $$ConversationWorkspaceBindingsTableProcessedTableManager
  get conversationWorkspaceBindingsRefs {
    final manager = $$ConversationWorkspaceBindingsTableTableManager(
      $_db,
      $_db.conversationWorkspaceBindings,
    ).filter((f) => f.conversationId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(
      _conversationWorkspaceBindingsRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$ConversationRowsTableFilterComposer
    extends Composer<_$AppDatabase, $ConversationRowsTable> {
  $$ConversationRowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAtMs => $composableBuilder(
    column: $table.createdAtMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAtMs => $composableBuilder(
    column: $table.updatedAtMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get assistantId => $composableBuilder(
    column: $table.assistantId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isPinned => $composableBuilder(
    column: $table.isPinned,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get truncateIndex => $composableBuilder(
    column: $table.truncateIndex,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get compactBeforeIndex => $composableBuilder(
    column: $table.compactBeforeIndex,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get summary => $composableBuilder(
    column: $table.summary,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastSummarizedMessageCount => $composableBuilder(
    column: $table.lastSummarizedMessageCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get mcpServerIdsJson => $composableBuilder(
    column: $table.mcpServerIdsJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get versionSelectionsJson => $composableBuilder(
    column: $table.versionSelectionsJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isRecovered => $composableBuilder(
    column: $table.isRecovered,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> messageRowsRefs(
    Expression<bool> Function($$MessageRowsTableFilterComposer f) f,
  ) {
    final $$MessageRowsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.messageRows,
      getReferencedColumn: (t) => t.conversationId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MessageRowsTableFilterComposer(
            $db: $db,
            $table: $db.messageRows,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> conversationWorkspaceBindingsRefs(
    Expression<bool> Function(
      $$ConversationWorkspaceBindingsTableFilterComposer f,
    )
    f,
  ) {
    final $$ConversationWorkspaceBindingsTableFilterComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.id,
          referencedTable: $db.conversationWorkspaceBindings,
          getReferencedColumn: (t) => t.conversationId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$ConversationWorkspaceBindingsTableFilterComposer(
                $db: $db,
                $table: $db.conversationWorkspaceBindings,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }
}

class $$ConversationRowsTableOrderingComposer
    extends Composer<_$AppDatabase, $ConversationRowsTable> {
  $$ConversationRowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAtMs => $composableBuilder(
    column: $table.createdAtMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAtMs => $composableBuilder(
    column: $table.updatedAtMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get assistantId => $composableBuilder(
    column: $table.assistantId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isPinned => $composableBuilder(
    column: $table.isPinned,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get truncateIndex => $composableBuilder(
    column: $table.truncateIndex,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get compactBeforeIndex => $composableBuilder(
    column: $table.compactBeforeIndex,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get summary => $composableBuilder(
    column: $table.summary,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastSummarizedMessageCount => $composableBuilder(
    column: $table.lastSummarizedMessageCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get mcpServerIdsJson => $composableBuilder(
    column: $table.mcpServerIdsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get versionSelectionsJson => $composableBuilder(
    column: $table.versionSelectionsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isRecovered => $composableBuilder(
    column: $table.isRecovered,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ConversationRowsTableAnnotationComposer
    extends Composer<_$AppDatabase, $ConversationRowsTable> {
  $$ConversationRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<int> get createdAtMs => $composableBuilder(
    column: $table.createdAtMs,
    builder: (column) => column,
  );

  GeneratedColumn<int> get updatedAtMs => $composableBuilder(
    column: $table.updatedAtMs,
    builder: (column) => column,
  );

  GeneratedColumn<String> get assistantId => $composableBuilder(
    column: $table.assistantId,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get isPinned =>
      $composableBuilder(column: $table.isPinned, builder: (column) => column);

  GeneratedColumn<int> get truncateIndex => $composableBuilder(
    column: $table.truncateIndex,
    builder: (column) => column,
  );

  GeneratedColumn<int> get compactBeforeIndex => $composableBuilder(
    column: $table.compactBeforeIndex,
    builder: (column) => column,
  );

  GeneratedColumn<String> get summary =>
      $composableBuilder(column: $table.summary, builder: (column) => column);

  GeneratedColumn<int> get lastSummarizedMessageCount => $composableBuilder(
    column: $table.lastSummarizedMessageCount,
    builder: (column) => column,
  );

  GeneratedColumn<String> get mcpServerIdsJson => $composableBuilder(
    column: $table.mcpServerIdsJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get versionSelectionsJson => $composableBuilder(
    column: $table.versionSelectionsJson,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get isRecovered => $composableBuilder(
    column: $table.isRecovered,
    builder: (column) => column,
  );

  Expression<T> messageRowsRefs<T extends Object>(
    Expression<T> Function($$MessageRowsTableAnnotationComposer a) f,
  ) {
    final $$MessageRowsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.messageRows,
      getReferencedColumn: (t) => t.conversationId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MessageRowsTableAnnotationComposer(
            $db: $db,
            $table: $db.messageRows,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> conversationWorkspaceBindingsRefs<T extends Object>(
    Expression<T> Function(
      $$ConversationWorkspaceBindingsTableAnnotationComposer a,
    )
    f,
  ) {
    final $$ConversationWorkspaceBindingsTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.id,
          referencedTable: $db.conversationWorkspaceBindings,
          getReferencedColumn: (t) => t.conversationId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$ConversationWorkspaceBindingsTableAnnotationComposer(
                $db: $db,
                $table: $db.conversationWorkspaceBindings,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }
}

class $$ConversationRowsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ConversationRowsTable,
          ConversationRow,
          $$ConversationRowsTableFilterComposer,
          $$ConversationRowsTableOrderingComposer,
          $$ConversationRowsTableAnnotationComposer,
          $$ConversationRowsTableCreateCompanionBuilder,
          $$ConversationRowsTableUpdateCompanionBuilder,
          (ConversationRow, $$ConversationRowsTableReferences),
          ConversationRow,
          PrefetchHooks Function({
            bool messageRowsRefs,
            bool conversationWorkspaceBindingsRefs,
          })
        > {
  $$ConversationRowsTableTableManager(
    _$AppDatabase db,
    $ConversationRowsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ConversationRowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ConversationRowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ConversationRowsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<int> createdAtMs = const Value.absent(),
                Value<int> updatedAtMs = const Value.absent(),
                Value<String?> assistantId = const Value.absent(),
                Value<bool> isPinned = const Value.absent(),
                Value<int> truncateIndex = const Value.absent(),
                Value<int> compactBeforeIndex = const Value.absent(),
                Value<String?> summary = const Value.absent(),
                Value<int> lastSummarizedMessageCount = const Value.absent(),
                Value<String> mcpServerIdsJson = const Value.absent(),
                Value<String> versionSelectionsJson = const Value.absent(),
                Value<bool> isRecovered = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ConversationRowsCompanion(
                id: id,
                title: title,
                createdAtMs: createdAtMs,
                updatedAtMs: updatedAtMs,
                assistantId: assistantId,
                isPinned: isPinned,
                truncateIndex: truncateIndex,
                compactBeforeIndex: compactBeforeIndex,
                summary: summary,
                lastSummarizedMessageCount: lastSummarizedMessageCount,
                mcpServerIdsJson: mcpServerIdsJson,
                versionSelectionsJson: versionSelectionsJson,
                isRecovered: isRecovered,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String title,
                required int createdAtMs,
                required int updatedAtMs,
                Value<String?> assistantId = const Value.absent(),
                Value<bool> isPinned = const Value.absent(),
                Value<int> truncateIndex = const Value.absent(),
                Value<int> compactBeforeIndex = const Value.absent(),
                Value<String?> summary = const Value.absent(),
                Value<int> lastSummarizedMessageCount = const Value.absent(),
                Value<String> mcpServerIdsJson = const Value.absent(),
                Value<String> versionSelectionsJson = const Value.absent(),
                Value<bool> isRecovered = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ConversationRowsCompanion.insert(
                id: id,
                title: title,
                createdAtMs: createdAtMs,
                updatedAtMs: updatedAtMs,
                assistantId: assistantId,
                isPinned: isPinned,
                truncateIndex: truncateIndex,
                compactBeforeIndex: compactBeforeIndex,
                summary: summary,
                lastSummarizedMessageCount: lastSummarizedMessageCount,
                mcpServerIdsJson: mcpServerIdsJson,
                versionSelectionsJson: versionSelectionsJson,
                isRecovered: isRecovered,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ConversationRowsTable, ConversationRow>(table),
                  $$ConversationRowsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback:
              ({
                messageRowsRefs = false,
                conversationWorkspaceBindingsRefs = false,
              }) {
                return PrefetchHooks(
                  db: db,
                  explicitlyWatchedTables: [
                    if (messageRowsRefs) db.messageRows,
                    if (conversationWorkspaceBindingsRefs)
                      db.conversationWorkspaceBindings,
                  ],
                  addJoins: null,
                  getPrefetchedDataCallback: (items) async {
                    return [
                      if (messageRowsRefs)
                        await $_getPrefetchedDataByColumns<
                          ConversationRow,
                          $ConversationRowsTable,
                          MessageRow,
                          $MessageRowsTable
                        >(
                          currentTable: table,
                          referencedTable: $$ConversationRowsTableReferences
                              ._messageRowsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$ConversationRowsTableReferences(
                                db,
                                table,
                                p0,
                              ).messageRowsRefs,
                          currentColumn: 'id',
                          referencedColumn: 'conversation_id',
                          typedResults: items,
                        ),
                      if (conversationWorkspaceBindingsRefs)
                        await $_getPrefetchedDataByColumns<
                          ConversationRow,
                          $ConversationRowsTable,
                          ConversationWorkspaceBindingRow,
                          $ConversationWorkspaceBindingsTable
                        >(
                          currentTable: table,
                          referencedTable: $$ConversationRowsTableReferences
                              ._conversationWorkspaceBindingsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$ConversationRowsTableReferences(
                                db,
                                table,
                                p0,
                              ).conversationWorkspaceBindingsRefs,
                          currentColumn: 'id',
                          referencedColumn: 'conversation_id',
                          typedResults: items,
                        ),
                    ];
                  },
                );
              },
        ),
      );
}

typedef $$ConversationRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ConversationRowsTable,
      ConversationRow,
      $$ConversationRowsTableFilterComposer,
      $$ConversationRowsTableOrderingComposer,
      $$ConversationRowsTableAnnotationComposer,
      $$ConversationRowsTableCreateCompanionBuilder,
      $$ConversationRowsTableUpdateCompanionBuilder,
      (ConversationRow, $$ConversationRowsTableReferences),
      ConversationRow,
      PrefetchHooks Function({
        bool messageRowsRefs,
        bool conversationWorkspaceBindingsRefs,
      })
    >;
typedef $$MessageRowsTableCreateCompanionBuilder =
    MessageRowsCompanion Function({
      required String id,
      required String conversationId,
      required int ordinal,
      required String role,
      required String content,
      required int timestampMs,
      Value<String?> modelId,
      Value<String?> providerId,
      Value<int?> totalTokens,
      Value<int?> promptTokens,
      Value<int?> completionTokens,
      Value<int?> cachedTokens,
      Value<bool> isStreaming,
      Value<String?> reasoningText,
      Value<int?> reasoningStartAtMs,
      Value<int?> reasoningFinishedAtMs,
      Value<String?> translation,
      Value<String?> reasoningSegmentsJson,
      Value<String?> groupId,
      Value<int> version,
      Value<String?> aiTeamProposalsJson,
      Value<int?> processStartedAtMs,
      Value<int?> processFinishedAtMs,
      Value<int> rowid,
    });
typedef $$MessageRowsTableUpdateCompanionBuilder =
    MessageRowsCompanion Function({
      Value<String> id,
      Value<String> conversationId,
      Value<int> ordinal,
      Value<String> role,
      Value<String> content,
      Value<int> timestampMs,
      Value<String?> modelId,
      Value<String?> providerId,
      Value<int?> totalTokens,
      Value<int?> promptTokens,
      Value<int?> completionTokens,
      Value<int?> cachedTokens,
      Value<bool> isStreaming,
      Value<String?> reasoningText,
      Value<int?> reasoningStartAtMs,
      Value<int?> reasoningFinishedAtMs,
      Value<String?> translation,
      Value<String?> reasoningSegmentsJson,
      Value<String?> groupId,
      Value<int> version,
      Value<String?> aiTeamProposalsJson,
      Value<int?> processStartedAtMs,
      Value<int?> processFinishedAtMs,
      Value<int> rowid,
    });

final class $$MessageRowsTableReferences
    extends BaseReferences<_$AppDatabase, $MessageRowsTable, MessageRow> {
  $$MessageRowsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $ConversationRowsTable _conversationIdTable(_$AppDatabase db) => db
      .conversationRows
      .createAlias('messages__conversation_id__conversations__id');

  $$ConversationRowsTableProcessedTableManager get conversationId {
    final $_column = $_itemColumn<String>('conversation_id')!;

    final manager = $$ConversationRowsTableTableManager(
      $_db,
      $_db.conversationRows,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_conversationIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static MultiTypedResultKey<$MessagePartsTable, List<MessagePartRow>>
  _messagePartsRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.messageParts,
    aliasName: 'messages__id__message_parts__message_id',
  );

  $$MessagePartsTableProcessedTableManager get messagePartsRefs {
    final manager = $$MessagePartsTableTableManager(
      $_db,
      $_db.messageParts,
    ).filter((f) => f.messageId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_messagePartsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$ProviderArtifactsTable, List<ProviderArtifactRow>>
  _providerArtifactsRefsTable(_$AppDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.providerArtifacts,
        aliasName: 'messages__id__provider_artifacts__message_id',
      );

  $$ProviderArtifactsTableProcessedTableManager get providerArtifactsRefs {
    final manager = $$ProviderArtifactsTableTableManager(
      $_db,
      $_db.providerArtifacts,
    ).filter((f) => f.messageId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(
      _providerArtifactsRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<
    $MessageFileRecordsTable,
    List<MessageFileRecordRow>
  >
  _messageFileRecordsRefsTable(_$AppDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.messageFileRecords,
        aliasName: 'messages__id__message_file_records__message_id',
      );

  $$MessageFileRecordsTableProcessedTableManager get messageFileRecordsRefs {
    final manager = $$MessageFileRecordsTableTableManager(
      $_db,
      $_db.messageFileRecords,
    ).filter((f) => f.messageId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(
      _messageFileRecordsRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$MessageRowsTableFilterComposer
    extends Composer<_$AppDatabase, $MessageRowsTable> {
  $$MessageRowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get ordinal => $composableBuilder(
    column: $table.ordinal,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get role => $composableBuilder(
    column: $table.role,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get content => $composableBuilder(
    column: $table.content,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get timestampMs => $composableBuilder(
    column: $table.timestampMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get modelId => $composableBuilder(
    column: $table.modelId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get providerId => $composableBuilder(
    column: $table.providerId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get totalTokens => $composableBuilder(
    column: $table.totalTokens,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get promptTokens => $composableBuilder(
    column: $table.promptTokens,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get completionTokens => $composableBuilder(
    column: $table.completionTokens,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get cachedTokens => $composableBuilder(
    column: $table.cachedTokens,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isStreaming => $composableBuilder(
    column: $table.isStreaming,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get reasoningText => $composableBuilder(
    column: $table.reasoningText,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get reasoningStartAtMs => $composableBuilder(
    column: $table.reasoningStartAtMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get reasoningFinishedAtMs => $composableBuilder(
    column: $table.reasoningFinishedAtMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get translation => $composableBuilder(
    column: $table.translation,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get reasoningSegmentsJson => $composableBuilder(
    column: $table.reasoningSegmentsJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get groupId => $composableBuilder(
    column: $table.groupId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get version => $composableBuilder(
    column: $table.version,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get aiTeamProposalsJson => $composableBuilder(
    column: $table.aiTeamProposalsJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get processStartedAtMs => $composableBuilder(
    column: $table.processStartedAtMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get processFinishedAtMs => $composableBuilder(
    column: $table.processFinishedAtMs,
    builder: (column) => ColumnFilters(column),
  );

  $$ConversationRowsTableFilterComposer get conversationId {
    final $$ConversationRowsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.conversationId,
      referencedTable: $db.conversationRows,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ConversationRowsTableFilterComposer(
            $db: $db,
            $table: $db.conversationRows,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<bool> messagePartsRefs(
    Expression<bool> Function($$MessagePartsTableFilterComposer f) f,
  ) {
    final $$MessagePartsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.messageParts,
      getReferencedColumn: (t) => t.messageId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MessagePartsTableFilterComposer(
            $db: $db,
            $table: $db.messageParts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> providerArtifactsRefs(
    Expression<bool> Function($$ProviderArtifactsTableFilterComposer f) f,
  ) {
    final $$ProviderArtifactsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.providerArtifacts,
      getReferencedColumn: (t) => t.messageId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ProviderArtifactsTableFilterComposer(
            $db: $db,
            $table: $db.providerArtifacts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> messageFileRecordsRefs(
    Expression<bool> Function($$MessageFileRecordsTableFilterComposer f) f,
  ) {
    final $$MessageFileRecordsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.messageFileRecords,
      getReferencedColumn: (t) => t.messageId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MessageFileRecordsTableFilterComposer(
            $db: $db,
            $table: $db.messageFileRecords,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$MessageRowsTableOrderingComposer
    extends Composer<_$AppDatabase, $MessageRowsTable> {
  $$MessageRowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get ordinal => $composableBuilder(
    column: $table.ordinal,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get role => $composableBuilder(
    column: $table.role,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get content => $composableBuilder(
    column: $table.content,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get timestampMs => $composableBuilder(
    column: $table.timestampMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get modelId => $composableBuilder(
    column: $table.modelId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get providerId => $composableBuilder(
    column: $table.providerId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get totalTokens => $composableBuilder(
    column: $table.totalTokens,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get promptTokens => $composableBuilder(
    column: $table.promptTokens,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get completionTokens => $composableBuilder(
    column: $table.completionTokens,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get cachedTokens => $composableBuilder(
    column: $table.cachedTokens,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isStreaming => $composableBuilder(
    column: $table.isStreaming,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get reasoningText => $composableBuilder(
    column: $table.reasoningText,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get reasoningStartAtMs => $composableBuilder(
    column: $table.reasoningStartAtMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get reasoningFinishedAtMs => $composableBuilder(
    column: $table.reasoningFinishedAtMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get translation => $composableBuilder(
    column: $table.translation,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get reasoningSegmentsJson => $composableBuilder(
    column: $table.reasoningSegmentsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get groupId => $composableBuilder(
    column: $table.groupId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get version => $composableBuilder(
    column: $table.version,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get aiTeamProposalsJson => $composableBuilder(
    column: $table.aiTeamProposalsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get processStartedAtMs => $composableBuilder(
    column: $table.processStartedAtMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get processFinishedAtMs => $composableBuilder(
    column: $table.processFinishedAtMs,
    builder: (column) => ColumnOrderings(column),
  );

  $$ConversationRowsTableOrderingComposer get conversationId {
    final $$ConversationRowsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.conversationId,
      referencedTable: $db.conversationRows,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ConversationRowsTableOrderingComposer(
            $db: $db,
            $table: $db.conversationRows,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$MessageRowsTableAnnotationComposer
    extends Composer<_$AppDatabase, $MessageRowsTable> {
  $$MessageRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get ordinal =>
      $composableBuilder(column: $table.ordinal, builder: (column) => column);

  GeneratedColumn<String> get role =>
      $composableBuilder(column: $table.role, builder: (column) => column);

  GeneratedColumn<String> get content =>
      $composableBuilder(column: $table.content, builder: (column) => column);

  GeneratedColumn<int> get timestampMs => $composableBuilder(
    column: $table.timestampMs,
    builder: (column) => column,
  );

  GeneratedColumn<String> get modelId =>
      $composableBuilder(column: $table.modelId, builder: (column) => column);

  GeneratedColumn<String> get providerId => $composableBuilder(
    column: $table.providerId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get totalTokens => $composableBuilder(
    column: $table.totalTokens,
    builder: (column) => column,
  );

  GeneratedColumn<int> get promptTokens => $composableBuilder(
    column: $table.promptTokens,
    builder: (column) => column,
  );

  GeneratedColumn<int> get completionTokens => $composableBuilder(
    column: $table.completionTokens,
    builder: (column) => column,
  );

  GeneratedColumn<int> get cachedTokens => $composableBuilder(
    column: $table.cachedTokens,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get isStreaming => $composableBuilder(
    column: $table.isStreaming,
    builder: (column) => column,
  );

  GeneratedColumn<String> get reasoningText => $composableBuilder(
    column: $table.reasoningText,
    builder: (column) => column,
  );

  GeneratedColumn<int> get reasoningStartAtMs => $composableBuilder(
    column: $table.reasoningStartAtMs,
    builder: (column) => column,
  );

  GeneratedColumn<int> get reasoningFinishedAtMs => $composableBuilder(
    column: $table.reasoningFinishedAtMs,
    builder: (column) => column,
  );

  GeneratedColumn<String> get translation => $composableBuilder(
    column: $table.translation,
    builder: (column) => column,
  );

  GeneratedColumn<String> get reasoningSegmentsJson => $composableBuilder(
    column: $table.reasoningSegmentsJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get groupId =>
      $composableBuilder(column: $table.groupId, builder: (column) => column);

  GeneratedColumn<int> get version =>
      $composableBuilder(column: $table.version, builder: (column) => column);

  GeneratedColumn<String> get aiTeamProposalsJson => $composableBuilder(
    column: $table.aiTeamProposalsJson,
    builder: (column) => column,
  );

  GeneratedColumn<int> get processStartedAtMs => $composableBuilder(
    column: $table.processStartedAtMs,
    builder: (column) => column,
  );

  GeneratedColumn<int> get processFinishedAtMs => $composableBuilder(
    column: $table.processFinishedAtMs,
    builder: (column) => column,
  );

  $$ConversationRowsTableAnnotationComposer get conversationId {
    final $$ConversationRowsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.conversationId,
      referencedTable: $db.conversationRows,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ConversationRowsTableAnnotationComposer(
            $db: $db,
            $table: $db.conversationRows,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<T> messagePartsRefs<T extends Object>(
    Expression<T> Function($$MessagePartsTableAnnotationComposer a) f,
  ) {
    final $$MessagePartsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.messageParts,
      getReferencedColumn: (t) => t.messageId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MessagePartsTableAnnotationComposer(
            $db: $db,
            $table: $db.messageParts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> providerArtifactsRefs<T extends Object>(
    Expression<T> Function($$ProviderArtifactsTableAnnotationComposer a) f,
  ) {
    final $$ProviderArtifactsTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.id,
          referencedTable: $db.providerArtifacts,
          getReferencedColumn: (t) => t.messageId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$ProviderArtifactsTableAnnotationComposer(
                $db: $db,
                $table: $db.providerArtifacts,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }

  Expression<T> messageFileRecordsRefs<T extends Object>(
    Expression<T> Function($$MessageFileRecordsTableAnnotationComposer a) f,
  ) {
    final $$MessageFileRecordsTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.id,
          referencedTable: $db.messageFileRecords,
          getReferencedColumn: (t) => t.messageId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$MessageFileRecordsTableAnnotationComposer(
                $db: $db,
                $table: $db.messageFileRecords,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }
}

class $$MessageRowsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $MessageRowsTable,
          MessageRow,
          $$MessageRowsTableFilterComposer,
          $$MessageRowsTableOrderingComposer,
          $$MessageRowsTableAnnotationComposer,
          $$MessageRowsTableCreateCompanionBuilder,
          $$MessageRowsTableUpdateCompanionBuilder,
          (MessageRow, $$MessageRowsTableReferences),
          MessageRow,
          PrefetchHooks Function({
            bool conversationId,
            bool messagePartsRefs,
            bool providerArtifactsRefs,
            bool messageFileRecordsRefs,
          })
        > {
  $$MessageRowsTableTableManager(_$AppDatabase db, $MessageRowsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MessageRowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MessageRowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MessageRowsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> conversationId = const Value.absent(),
                Value<int> ordinal = const Value.absent(),
                Value<String> role = const Value.absent(),
                Value<String> content = const Value.absent(),
                Value<int> timestampMs = const Value.absent(),
                Value<String?> modelId = const Value.absent(),
                Value<String?> providerId = const Value.absent(),
                Value<int?> totalTokens = const Value.absent(),
                Value<int?> promptTokens = const Value.absent(),
                Value<int?> completionTokens = const Value.absent(),
                Value<int?> cachedTokens = const Value.absent(),
                Value<bool> isStreaming = const Value.absent(),
                Value<String?> reasoningText = const Value.absent(),
                Value<int?> reasoningStartAtMs = const Value.absent(),
                Value<int?> reasoningFinishedAtMs = const Value.absent(),
                Value<String?> translation = const Value.absent(),
                Value<String?> reasoningSegmentsJson = const Value.absent(),
                Value<String?> groupId = const Value.absent(),
                Value<int> version = const Value.absent(),
                Value<String?> aiTeamProposalsJson = const Value.absent(),
                Value<int?> processStartedAtMs = const Value.absent(),
                Value<int?> processFinishedAtMs = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MessageRowsCompanion(
                id: id,
                conversationId: conversationId,
                ordinal: ordinal,
                role: role,
                content: content,
                timestampMs: timestampMs,
                modelId: modelId,
                providerId: providerId,
                totalTokens: totalTokens,
                promptTokens: promptTokens,
                completionTokens: completionTokens,
                cachedTokens: cachedTokens,
                isStreaming: isStreaming,
                reasoningText: reasoningText,
                reasoningStartAtMs: reasoningStartAtMs,
                reasoningFinishedAtMs: reasoningFinishedAtMs,
                translation: translation,
                reasoningSegmentsJson: reasoningSegmentsJson,
                groupId: groupId,
                version: version,
                aiTeamProposalsJson: aiTeamProposalsJson,
                processStartedAtMs: processStartedAtMs,
                processFinishedAtMs: processFinishedAtMs,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String conversationId,
                required int ordinal,
                required String role,
                required String content,
                required int timestampMs,
                Value<String?> modelId = const Value.absent(),
                Value<String?> providerId = const Value.absent(),
                Value<int?> totalTokens = const Value.absent(),
                Value<int?> promptTokens = const Value.absent(),
                Value<int?> completionTokens = const Value.absent(),
                Value<int?> cachedTokens = const Value.absent(),
                Value<bool> isStreaming = const Value.absent(),
                Value<String?> reasoningText = const Value.absent(),
                Value<int?> reasoningStartAtMs = const Value.absent(),
                Value<int?> reasoningFinishedAtMs = const Value.absent(),
                Value<String?> translation = const Value.absent(),
                Value<String?> reasoningSegmentsJson = const Value.absent(),
                Value<String?> groupId = const Value.absent(),
                Value<int> version = const Value.absent(),
                Value<String?> aiTeamProposalsJson = const Value.absent(),
                Value<int?> processStartedAtMs = const Value.absent(),
                Value<int?> processFinishedAtMs = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MessageRowsCompanion.insert(
                id: id,
                conversationId: conversationId,
                ordinal: ordinal,
                role: role,
                content: content,
                timestampMs: timestampMs,
                modelId: modelId,
                providerId: providerId,
                totalTokens: totalTokens,
                promptTokens: promptTokens,
                completionTokens: completionTokens,
                cachedTokens: cachedTokens,
                isStreaming: isStreaming,
                reasoningText: reasoningText,
                reasoningStartAtMs: reasoningStartAtMs,
                reasoningFinishedAtMs: reasoningFinishedAtMs,
                translation: translation,
                reasoningSegmentsJson: reasoningSegmentsJson,
                groupId: groupId,
                version: version,
                aiTeamProposalsJson: aiTeamProposalsJson,
                processStartedAtMs: processStartedAtMs,
                processFinishedAtMs: processFinishedAtMs,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$MessageRowsTable, MessageRow>(table),
                  $$MessageRowsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback:
              ({
                conversationId = false,
                messagePartsRefs = false,
                providerArtifactsRefs = false,
                messageFileRecordsRefs = false,
              }) {
                return PrefetchHooks(
                  db: db,
                  explicitlyWatchedTables: [
                    if (messagePartsRefs) db.messageParts,
                    if (providerArtifactsRefs) db.providerArtifacts,
                    if (messageFileRecordsRefs) db.messageFileRecords,
                  ],
                  addJoins:
                      <
                        T extends TableManagerState<
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic
                        >
                      >(state) {
                        if (conversationId) {
                          state =
                              state.withJoin(
                                    currentTable: table,
                                    currentColumn: table.conversationId,
                                    referencedTable:
                                        $$MessageRowsTableReferences
                                            ._conversationIdTable(db),
                                    referencedColumn:
                                        $$MessageRowsTableReferences
                                            ._conversationIdTable(db)
                                            .id,
                                  )
                                  as T;
                        }

                        return state;
                      },
                  getPrefetchedDataCallback: (items) async {
                    return [
                      if (messagePartsRefs)
                        await $_getPrefetchedDataByColumns<
                          MessageRow,
                          $MessageRowsTable,
                          MessagePartRow,
                          $MessagePartsTable
                        >(
                          currentTable: table,
                          referencedTable: $$MessageRowsTableReferences
                              ._messagePartsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$MessageRowsTableReferences(
                                db,
                                table,
                                p0,
                              ).messagePartsRefs,
                          currentColumn: 'id',
                          referencedColumn: 'message_id',
                          typedResults: items,
                        ),
                      if (providerArtifactsRefs)
                        await $_getPrefetchedDataByColumns<
                          MessageRow,
                          $MessageRowsTable,
                          ProviderArtifactRow,
                          $ProviderArtifactsTable
                        >(
                          currentTable: table,
                          referencedTable: $$MessageRowsTableReferences
                              ._providerArtifactsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$MessageRowsTableReferences(
                                db,
                                table,
                                p0,
                              ).providerArtifactsRefs,
                          currentColumn: 'id',
                          referencedColumn: 'message_id',
                          typedResults: items,
                        ),
                      if (messageFileRecordsRefs)
                        await $_getPrefetchedDataByColumns<
                          MessageRow,
                          $MessageRowsTable,
                          MessageFileRecordRow,
                          $MessageFileRecordsTable
                        >(
                          currentTable: table,
                          referencedTable: $$MessageRowsTableReferences
                              ._messageFileRecordsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$MessageRowsTableReferences(
                                db,
                                table,
                                p0,
                              ).messageFileRecordsRefs,
                          currentColumn: 'id',
                          referencedColumn: 'message_id',
                          typedResults: items,
                        ),
                    ];
                  },
                );
              },
        ),
      );
}

typedef $$MessageRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $MessageRowsTable,
      MessageRow,
      $$MessageRowsTableFilterComposer,
      $$MessageRowsTableOrderingComposer,
      $$MessageRowsTableAnnotationComposer,
      $$MessageRowsTableCreateCompanionBuilder,
      $$MessageRowsTableUpdateCompanionBuilder,
      (MessageRow, $$MessageRowsTableReferences),
      MessageRow,
      PrefetchHooks Function({
        bool conversationId,
        bool messagePartsRefs,
        bool providerArtifactsRefs,
        bool messageFileRecordsRefs,
      })
    >;
typedef $$MessagePartsTableCreateCompanionBuilder =
    MessagePartsCompanion Function({
      Value<int> partId,
      required String messageId,
      required int ordinal,
      required String kind,
      Value<String?> toolCallId,
      Value<String?> toolName,
      Value<String?> argumentsJson,
      Value<String?> content,
      Value<String> status,
      Value<String?> approvalState,
      Value<String?> metadataJson,
      required int createdAtMs,
      required int updatedAtMs,
    });
typedef $$MessagePartsTableUpdateCompanionBuilder =
    MessagePartsCompanion Function({
      Value<int> partId,
      Value<String> messageId,
      Value<int> ordinal,
      Value<String> kind,
      Value<String?> toolCallId,
      Value<String?> toolName,
      Value<String?> argumentsJson,
      Value<String?> content,
      Value<String> status,
      Value<String?> approvalState,
      Value<String?> metadataJson,
      Value<int> createdAtMs,
      Value<int> updatedAtMs,
    });

final class $$MessagePartsTableReferences
    extends BaseReferences<_$AppDatabase, $MessagePartsTable, MessagePartRow> {
  $$MessagePartsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $MessageRowsTable _messageIdTable(_$AppDatabase db) =>
      db.messageRows.createAlias('message_parts__message_id__messages__id');

  $$MessageRowsTableProcessedTableManager get messageId {
    final $_column = $_itemColumn<String>('message_id')!;

    final manager = $$MessageRowsTableTableManager(
      $_db,
      $_db.messageRows,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_messageIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$MessagePartsTableFilterComposer
    extends Composer<_$AppDatabase, $MessagePartsTable> {
  $$MessagePartsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get partId => $composableBuilder(
    column: $table.partId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get ordinal => $composableBuilder(
    column: $table.ordinal,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get toolCallId => $composableBuilder(
    column: $table.toolCallId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get toolName => $composableBuilder(
    column: $table.toolName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get argumentsJson => $composableBuilder(
    column: $table.argumentsJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get content => $composableBuilder(
    column: $table.content,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get approvalState => $composableBuilder(
    column: $table.approvalState,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get metadataJson => $composableBuilder(
    column: $table.metadataJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAtMs => $composableBuilder(
    column: $table.createdAtMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAtMs => $composableBuilder(
    column: $table.updatedAtMs,
    builder: (column) => ColumnFilters(column),
  );

  $$MessageRowsTableFilterComposer get messageId {
    final $$MessageRowsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.messageId,
      referencedTable: $db.messageRows,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MessageRowsTableFilterComposer(
            $db: $db,
            $table: $db.messageRows,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$MessagePartsTableOrderingComposer
    extends Composer<_$AppDatabase, $MessagePartsTable> {
  $$MessagePartsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get partId => $composableBuilder(
    column: $table.partId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get ordinal => $composableBuilder(
    column: $table.ordinal,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get toolCallId => $composableBuilder(
    column: $table.toolCallId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get toolName => $composableBuilder(
    column: $table.toolName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get argumentsJson => $composableBuilder(
    column: $table.argumentsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get content => $composableBuilder(
    column: $table.content,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get approvalState => $composableBuilder(
    column: $table.approvalState,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get metadataJson => $composableBuilder(
    column: $table.metadataJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAtMs => $composableBuilder(
    column: $table.createdAtMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAtMs => $composableBuilder(
    column: $table.updatedAtMs,
    builder: (column) => ColumnOrderings(column),
  );

  $$MessageRowsTableOrderingComposer get messageId {
    final $$MessageRowsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.messageId,
      referencedTable: $db.messageRows,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MessageRowsTableOrderingComposer(
            $db: $db,
            $table: $db.messageRows,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$MessagePartsTableAnnotationComposer
    extends Composer<_$AppDatabase, $MessagePartsTable> {
  $$MessagePartsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get partId =>
      $composableBuilder(column: $table.partId, builder: (column) => column);

  GeneratedColumn<int> get ordinal =>
      $composableBuilder(column: $table.ordinal, builder: (column) => column);

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<String> get toolCallId => $composableBuilder(
    column: $table.toolCallId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get toolName =>
      $composableBuilder(column: $table.toolName, builder: (column) => column);

  GeneratedColumn<String> get argumentsJson => $composableBuilder(
    column: $table.argumentsJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get content =>
      $composableBuilder(column: $table.content, builder: (column) => column);

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<String> get approvalState => $composableBuilder(
    column: $table.approvalState,
    builder: (column) => column,
  );

  GeneratedColumn<String> get metadataJson => $composableBuilder(
    column: $table.metadataJson,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createdAtMs => $composableBuilder(
    column: $table.createdAtMs,
    builder: (column) => column,
  );

  GeneratedColumn<int> get updatedAtMs => $composableBuilder(
    column: $table.updatedAtMs,
    builder: (column) => column,
  );

  $$MessageRowsTableAnnotationComposer get messageId {
    final $$MessageRowsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.messageId,
      referencedTable: $db.messageRows,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MessageRowsTableAnnotationComposer(
            $db: $db,
            $table: $db.messageRows,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$MessagePartsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $MessagePartsTable,
          MessagePartRow,
          $$MessagePartsTableFilterComposer,
          $$MessagePartsTableOrderingComposer,
          $$MessagePartsTableAnnotationComposer,
          $$MessagePartsTableCreateCompanionBuilder,
          $$MessagePartsTableUpdateCompanionBuilder,
          (MessagePartRow, $$MessagePartsTableReferences),
          MessagePartRow,
          PrefetchHooks Function({bool messageId})
        > {
  $$MessagePartsTableTableManager(_$AppDatabase db, $MessagePartsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MessagePartsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MessagePartsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MessagePartsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> partId = const Value.absent(),
                Value<String> messageId = const Value.absent(),
                Value<int> ordinal = const Value.absent(),
                Value<String> kind = const Value.absent(),
                Value<String?> toolCallId = const Value.absent(),
                Value<String?> toolName = const Value.absent(),
                Value<String?> argumentsJson = const Value.absent(),
                Value<String?> content = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<String?> approvalState = const Value.absent(),
                Value<String?> metadataJson = const Value.absent(),
                Value<int> createdAtMs = const Value.absent(),
                Value<int> updatedAtMs = const Value.absent(),
              }) => MessagePartsCompanion(
                partId: partId,
                messageId: messageId,
                ordinal: ordinal,
                kind: kind,
                toolCallId: toolCallId,
                toolName: toolName,
                argumentsJson: argumentsJson,
                content: content,
                status: status,
                approvalState: approvalState,
                metadataJson: metadataJson,
                createdAtMs: createdAtMs,
                updatedAtMs: updatedAtMs,
              ),
          createCompanionCallback:
              ({
                Value<int> partId = const Value.absent(),
                required String messageId,
                required int ordinal,
                required String kind,
                Value<String?> toolCallId = const Value.absent(),
                Value<String?> toolName = const Value.absent(),
                Value<String?> argumentsJson = const Value.absent(),
                Value<String?> content = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<String?> approvalState = const Value.absent(),
                Value<String?> metadataJson = const Value.absent(),
                required int createdAtMs,
                required int updatedAtMs,
              }) => MessagePartsCompanion.insert(
                partId: partId,
                messageId: messageId,
                ordinal: ordinal,
                kind: kind,
                toolCallId: toolCallId,
                toolName: toolName,
                argumentsJson: argumentsJson,
                content: content,
                status: status,
                approvalState: approvalState,
                metadataJson: metadataJson,
                createdAtMs: createdAtMs,
                updatedAtMs: updatedAtMs,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$MessagePartsTable, MessagePartRow>(table),
                  $$MessagePartsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({messageId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (messageId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.messageId,
                                referencedTable: $$MessagePartsTableReferences
                                    ._messageIdTable(db),
                                referencedColumn: $$MessagePartsTableReferences
                                    ._messageIdTable(db)
                                    .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$MessagePartsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $MessagePartsTable,
      MessagePartRow,
      $$MessagePartsTableFilterComposer,
      $$MessagePartsTableOrderingComposer,
      $$MessagePartsTableAnnotationComposer,
      $$MessagePartsTableCreateCompanionBuilder,
      $$MessagePartsTableUpdateCompanionBuilder,
      (MessagePartRow, $$MessagePartsTableReferences),
      MessagePartRow,
      PrefetchHooks Function({bool messageId})
    >;
typedef $$ProviderArtifactsTableCreateCompanionBuilder =
    ProviderArtifactsCompanion Function({
      required String messageId,
      required String kind,
      required String payload,
      required int createdAtMs,
      required int updatedAtMs,
      Value<int> rowid,
    });
typedef $$ProviderArtifactsTableUpdateCompanionBuilder =
    ProviderArtifactsCompanion Function({
      Value<String> messageId,
      Value<String> kind,
      Value<String> payload,
      Value<int> createdAtMs,
      Value<int> updatedAtMs,
      Value<int> rowid,
    });

final class $$ProviderArtifactsTableReferences
    extends
        BaseReferences<
          _$AppDatabase,
          $ProviderArtifactsTable,
          ProviderArtifactRow
        > {
  $$ProviderArtifactsTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $MessageRowsTable _messageIdTable(_$AppDatabase db) => db.messageRows
      .createAlias('provider_artifacts__message_id__messages__id');

  $$MessageRowsTableProcessedTableManager get messageId {
    final $_column = $_itemColumn<String>('message_id')!;

    final manager = $$MessageRowsTableTableManager(
      $_db,
      $_db.messageRows,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_messageIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$ProviderArtifactsTableFilterComposer
    extends Composer<_$AppDatabase, $ProviderArtifactsTable> {
  $$ProviderArtifactsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get payload => $composableBuilder(
    column: $table.payload,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAtMs => $composableBuilder(
    column: $table.createdAtMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAtMs => $composableBuilder(
    column: $table.updatedAtMs,
    builder: (column) => ColumnFilters(column),
  );

  $$MessageRowsTableFilterComposer get messageId {
    final $$MessageRowsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.messageId,
      referencedTable: $db.messageRows,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MessageRowsTableFilterComposer(
            $db: $db,
            $table: $db.messageRows,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ProviderArtifactsTableOrderingComposer
    extends Composer<_$AppDatabase, $ProviderArtifactsTable> {
  $$ProviderArtifactsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get payload => $composableBuilder(
    column: $table.payload,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAtMs => $composableBuilder(
    column: $table.createdAtMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAtMs => $composableBuilder(
    column: $table.updatedAtMs,
    builder: (column) => ColumnOrderings(column),
  );

  $$MessageRowsTableOrderingComposer get messageId {
    final $$MessageRowsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.messageId,
      referencedTable: $db.messageRows,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MessageRowsTableOrderingComposer(
            $db: $db,
            $table: $db.messageRows,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ProviderArtifactsTableAnnotationComposer
    extends Composer<_$AppDatabase, $ProviderArtifactsTable> {
  $$ProviderArtifactsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<String> get payload =>
      $composableBuilder(column: $table.payload, builder: (column) => column);

  GeneratedColumn<int> get createdAtMs => $composableBuilder(
    column: $table.createdAtMs,
    builder: (column) => column,
  );

  GeneratedColumn<int> get updatedAtMs => $composableBuilder(
    column: $table.updatedAtMs,
    builder: (column) => column,
  );

  $$MessageRowsTableAnnotationComposer get messageId {
    final $$MessageRowsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.messageId,
      referencedTable: $db.messageRows,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MessageRowsTableAnnotationComposer(
            $db: $db,
            $table: $db.messageRows,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ProviderArtifactsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ProviderArtifactsTable,
          ProviderArtifactRow,
          $$ProviderArtifactsTableFilterComposer,
          $$ProviderArtifactsTableOrderingComposer,
          $$ProviderArtifactsTableAnnotationComposer,
          $$ProviderArtifactsTableCreateCompanionBuilder,
          $$ProviderArtifactsTableUpdateCompanionBuilder,
          (ProviderArtifactRow, $$ProviderArtifactsTableReferences),
          ProviderArtifactRow,
          PrefetchHooks Function({bool messageId})
        > {
  $$ProviderArtifactsTableTableManager(
    _$AppDatabase db,
    $ProviderArtifactsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ProviderArtifactsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ProviderArtifactsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ProviderArtifactsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> messageId = const Value.absent(),
                Value<String> kind = const Value.absent(),
                Value<String> payload = const Value.absent(),
                Value<int> createdAtMs = const Value.absent(),
                Value<int> updatedAtMs = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ProviderArtifactsCompanion(
                messageId: messageId,
                kind: kind,
                payload: payload,
                createdAtMs: createdAtMs,
                updatedAtMs: updatedAtMs,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String messageId,
                required String kind,
                required String payload,
                required int createdAtMs,
                required int updatedAtMs,
                Value<int> rowid = const Value.absent(),
              }) => ProviderArtifactsCompanion.insert(
                messageId: messageId,
                kind: kind,
                payload: payload,
                createdAtMs: createdAtMs,
                updatedAtMs: updatedAtMs,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ProviderArtifactsTable, ProviderArtifactRow>(
                    table,
                  ),
                  $$ProviderArtifactsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({messageId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (messageId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.messageId,
                                referencedTable:
                                    $$ProviderArtifactsTableReferences
                                        ._messageIdTable(db),
                                referencedColumn:
                                    $$ProviderArtifactsTableReferences
                                        ._messageIdTable(db)
                                        .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$ProviderArtifactsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ProviderArtifactsTable,
      ProviderArtifactRow,
      $$ProviderArtifactsTableFilterComposer,
      $$ProviderArtifactsTableOrderingComposer,
      $$ProviderArtifactsTableAnnotationComposer,
      $$ProviderArtifactsTableCreateCompanionBuilder,
      $$ProviderArtifactsTableUpdateCompanionBuilder,
      (ProviderArtifactRow, $$ProviderArtifactsTableReferences),
      ProviderArtifactRow,
      PrefetchHooks Function({bool messageId})
    >;
typedef $$MessageFileRecordsTableCreateCompanionBuilder =
    MessageFileRecordsCompanion Function({
      Value<int> id,
      required String messageId,
      required int ordinal,
      required String path,
      Value<String?> fileName,
      Value<int> sizeBytes,
      required int createdAtMs,
    });
typedef $$MessageFileRecordsTableUpdateCompanionBuilder =
    MessageFileRecordsCompanion Function({
      Value<int> id,
      Value<String> messageId,
      Value<int> ordinal,
      Value<String> path,
      Value<String?> fileName,
      Value<int> sizeBytes,
      Value<int> createdAtMs,
    });

final class $$MessageFileRecordsTableReferences
    extends
        BaseReferences<
          _$AppDatabase,
          $MessageFileRecordsTable,
          MessageFileRecordRow
        > {
  $$MessageFileRecordsTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $MessageRowsTable _messageIdTable(_$AppDatabase db) => db.messageRows
      .createAlias('message_file_records__message_id__messages__id');

  $$MessageRowsTableProcessedTableManager get messageId {
    final $_column = $_itemColumn<String>('message_id')!;

    final manager = $$MessageRowsTableTableManager(
      $_db,
      $_db.messageRows,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_messageIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$MessageFileRecordsTableFilterComposer
    extends Composer<_$AppDatabase, $MessageFileRecordsTable> {
  $$MessageFileRecordsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get ordinal => $composableBuilder(
    column: $table.ordinal,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get path => $composableBuilder(
    column: $table.path,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get fileName => $composableBuilder(
    column: $table.fileName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sizeBytes => $composableBuilder(
    column: $table.sizeBytes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAtMs => $composableBuilder(
    column: $table.createdAtMs,
    builder: (column) => ColumnFilters(column),
  );

  $$MessageRowsTableFilterComposer get messageId {
    final $$MessageRowsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.messageId,
      referencedTable: $db.messageRows,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MessageRowsTableFilterComposer(
            $db: $db,
            $table: $db.messageRows,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$MessageFileRecordsTableOrderingComposer
    extends Composer<_$AppDatabase, $MessageFileRecordsTable> {
  $$MessageFileRecordsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get ordinal => $composableBuilder(
    column: $table.ordinal,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get path => $composableBuilder(
    column: $table.path,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get fileName => $composableBuilder(
    column: $table.fileName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sizeBytes => $composableBuilder(
    column: $table.sizeBytes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAtMs => $composableBuilder(
    column: $table.createdAtMs,
    builder: (column) => ColumnOrderings(column),
  );

  $$MessageRowsTableOrderingComposer get messageId {
    final $$MessageRowsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.messageId,
      referencedTable: $db.messageRows,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MessageRowsTableOrderingComposer(
            $db: $db,
            $table: $db.messageRows,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$MessageFileRecordsTableAnnotationComposer
    extends Composer<_$AppDatabase, $MessageFileRecordsTable> {
  $$MessageFileRecordsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get ordinal =>
      $composableBuilder(column: $table.ordinal, builder: (column) => column);

  GeneratedColumn<String> get path =>
      $composableBuilder(column: $table.path, builder: (column) => column);

  GeneratedColumn<String> get fileName =>
      $composableBuilder(column: $table.fileName, builder: (column) => column);

  GeneratedColumn<int> get sizeBytes =>
      $composableBuilder(column: $table.sizeBytes, builder: (column) => column);

  GeneratedColumn<int> get createdAtMs => $composableBuilder(
    column: $table.createdAtMs,
    builder: (column) => column,
  );

  $$MessageRowsTableAnnotationComposer get messageId {
    final $$MessageRowsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.messageId,
      referencedTable: $db.messageRows,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MessageRowsTableAnnotationComposer(
            $db: $db,
            $table: $db.messageRows,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$MessageFileRecordsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $MessageFileRecordsTable,
          MessageFileRecordRow,
          $$MessageFileRecordsTableFilterComposer,
          $$MessageFileRecordsTableOrderingComposer,
          $$MessageFileRecordsTableAnnotationComposer,
          $$MessageFileRecordsTableCreateCompanionBuilder,
          $$MessageFileRecordsTableUpdateCompanionBuilder,
          (MessageFileRecordRow, $$MessageFileRecordsTableReferences),
          MessageFileRecordRow,
          PrefetchHooks Function({bool messageId})
        > {
  $$MessageFileRecordsTableTableManager(
    _$AppDatabase db,
    $MessageFileRecordsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MessageFileRecordsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MessageFileRecordsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MessageFileRecordsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> messageId = const Value.absent(),
                Value<int> ordinal = const Value.absent(),
                Value<String> path = const Value.absent(),
                Value<String?> fileName = const Value.absent(),
                Value<int> sizeBytes = const Value.absent(),
                Value<int> createdAtMs = const Value.absent(),
              }) => MessageFileRecordsCompanion(
                id: id,
                messageId: messageId,
                ordinal: ordinal,
                path: path,
                fileName: fileName,
                sizeBytes: sizeBytes,
                createdAtMs: createdAtMs,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String messageId,
                required int ordinal,
                required String path,
                Value<String?> fileName = const Value.absent(),
                Value<int> sizeBytes = const Value.absent(),
                required int createdAtMs,
              }) => MessageFileRecordsCompanion.insert(
                id: id,
                messageId: messageId,
                ordinal: ordinal,
                path: path,
                fileName: fileName,
                sizeBytes: sizeBytes,
                createdAtMs: createdAtMs,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$MessageFileRecordsTable, MessageFileRecordRow>(
                    table,
                  ),
                  $$MessageFileRecordsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({messageId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (messageId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.messageId,
                                referencedTable:
                                    $$MessageFileRecordsTableReferences
                                        ._messageIdTable(db),
                                referencedColumn:
                                    $$MessageFileRecordsTableReferences
                                        ._messageIdTable(db)
                                        .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$MessageFileRecordsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $MessageFileRecordsTable,
      MessageFileRecordRow,
      $$MessageFileRecordsTableFilterComposer,
      $$MessageFileRecordsTableOrderingComposer,
      $$MessageFileRecordsTableAnnotationComposer,
      $$MessageFileRecordsTableCreateCompanionBuilder,
      $$MessageFileRecordsTableUpdateCompanionBuilder,
      (MessageFileRecordRow, $$MessageFileRecordsTableReferences),
      MessageFileRecordRow,
      PrefetchHooks Function({bool messageId})
    >;
typedef $$ConversationWorkspaceBindingsTableCreateCompanionBuilder =
    ConversationWorkspaceBindingsCompanion Function({
      required String conversationId,
      required String configJson,
      required int updatedAtMs,
      Value<int> rowid,
    });
typedef $$ConversationWorkspaceBindingsTableUpdateCompanionBuilder =
    ConversationWorkspaceBindingsCompanion Function({
      Value<String> conversationId,
      Value<String> configJson,
      Value<int> updatedAtMs,
      Value<int> rowid,
    });

final class $$ConversationWorkspaceBindingsTableReferences
    extends
        BaseReferences<
          _$AppDatabase,
          $ConversationWorkspaceBindingsTable,
          ConversationWorkspaceBindingRow
        > {
  $$ConversationWorkspaceBindingsTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $ConversationRowsTable _conversationIdTable(_$AppDatabase db) =>
      db.conversationRows.createAlias(
        'conversation_workspace_bindings__conversation_id__conversations__id',
      );

  $$ConversationRowsTableProcessedTableManager get conversationId {
    final $_column = $_itemColumn<String>('conversation_id')!;

    final manager = $$ConversationRowsTableTableManager(
      $_db,
      $_db.conversationRows,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_conversationIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$ConversationWorkspaceBindingsTableFilterComposer
    extends Composer<_$AppDatabase, $ConversationWorkspaceBindingsTable> {
  $$ConversationWorkspaceBindingsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get configJson => $composableBuilder(
    column: $table.configJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAtMs => $composableBuilder(
    column: $table.updatedAtMs,
    builder: (column) => ColumnFilters(column),
  );

  $$ConversationRowsTableFilterComposer get conversationId {
    final $$ConversationRowsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.conversationId,
      referencedTable: $db.conversationRows,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ConversationRowsTableFilterComposer(
            $db: $db,
            $table: $db.conversationRows,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ConversationWorkspaceBindingsTableOrderingComposer
    extends Composer<_$AppDatabase, $ConversationWorkspaceBindingsTable> {
  $$ConversationWorkspaceBindingsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get configJson => $composableBuilder(
    column: $table.configJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAtMs => $composableBuilder(
    column: $table.updatedAtMs,
    builder: (column) => ColumnOrderings(column),
  );

  $$ConversationRowsTableOrderingComposer get conversationId {
    final $$ConversationRowsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.conversationId,
      referencedTable: $db.conversationRows,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ConversationRowsTableOrderingComposer(
            $db: $db,
            $table: $db.conversationRows,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ConversationWorkspaceBindingsTableAnnotationComposer
    extends Composer<_$AppDatabase, $ConversationWorkspaceBindingsTable> {
  $$ConversationWorkspaceBindingsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get configJson => $composableBuilder(
    column: $table.configJson,
    builder: (column) => column,
  );

  GeneratedColumn<int> get updatedAtMs => $composableBuilder(
    column: $table.updatedAtMs,
    builder: (column) => column,
  );

  $$ConversationRowsTableAnnotationComposer get conversationId {
    final $$ConversationRowsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.conversationId,
      referencedTable: $db.conversationRows,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ConversationRowsTableAnnotationComposer(
            $db: $db,
            $table: $db.conversationRows,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ConversationWorkspaceBindingsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ConversationWorkspaceBindingsTable,
          ConversationWorkspaceBindingRow,
          $$ConversationWorkspaceBindingsTableFilterComposer,
          $$ConversationWorkspaceBindingsTableOrderingComposer,
          $$ConversationWorkspaceBindingsTableAnnotationComposer,
          $$ConversationWorkspaceBindingsTableCreateCompanionBuilder,
          $$ConversationWorkspaceBindingsTableUpdateCompanionBuilder,
          (
            ConversationWorkspaceBindingRow,
            $$ConversationWorkspaceBindingsTableReferences,
          ),
          ConversationWorkspaceBindingRow,
          PrefetchHooks Function({bool conversationId})
        > {
  $$ConversationWorkspaceBindingsTableTableManager(
    _$AppDatabase db,
    $ConversationWorkspaceBindingsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ConversationWorkspaceBindingsTableFilterComposer(
                $db: db,
                $table: table,
              ),
          createOrderingComposer: () =>
              $$ConversationWorkspaceBindingsTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$ConversationWorkspaceBindingsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> conversationId = const Value.absent(),
                Value<String> configJson = const Value.absent(),
                Value<int> updatedAtMs = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ConversationWorkspaceBindingsCompanion(
                conversationId: conversationId,
                configJson: configJson,
                updatedAtMs: updatedAtMs,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String conversationId,
                required String configJson,
                required int updatedAtMs,
                Value<int> rowid = const Value.absent(),
              }) => ConversationWorkspaceBindingsCompanion.insert(
                conversationId: conversationId,
                configJson: configJson,
                updatedAtMs: updatedAtMs,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<
                    $ConversationWorkspaceBindingsTable,
                    ConversationWorkspaceBindingRow
                  >(table),
                  $$ConversationWorkspaceBindingsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({conversationId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (conversationId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.conversationId,
                                referencedTable:
                                    $$ConversationWorkspaceBindingsTableReferences
                                        ._conversationIdTable(db),
                                referencedColumn:
                                    $$ConversationWorkspaceBindingsTableReferences
                                        ._conversationIdTable(db)
                                        .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$ConversationWorkspaceBindingsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ConversationWorkspaceBindingsTable,
      ConversationWorkspaceBindingRow,
      $$ConversationWorkspaceBindingsTableFilterComposer,
      $$ConversationWorkspaceBindingsTableOrderingComposer,
      $$ConversationWorkspaceBindingsTableAnnotationComposer,
      $$ConversationWorkspaceBindingsTableCreateCompanionBuilder,
      $$ConversationWorkspaceBindingsTableUpdateCompanionBuilder,
      (
        ConversationWorkspaceBindingRow,
        $$ConversationWorkspaceBindingsTableReferences,
      ),
      ConversationWorkspaceBindingRow,
      PrefetchHooks Function({bool conversationId})
    >;
typedef $$MigrationMetaTableCreateCompanionBuilder =
    MigrationMetaCompanion Function({
      required String key,
      required String value,
      Value<int> rowid,
    });
typedef $$MigrationMetaTableUpdateCompanionBuilder =
    MigrationMetaCompanion Function({
      Value<String> key,
      Value<String> value,
      Value<int> rowid,
    });

class $$MigrationMetaTableFilterComposer
    extends Composer<_$AppDatabase, $MigrationMetaTable> {
  $$MigrationMetaTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnFilters(column),
  );
}

class $$MigrationMetaTableOrderingComposer
    extends Composer<_$AppDatabase, $MigrationMetaTable> {
  $$MigrationMetaTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$MigrationMetaTableAnnotationComposer
    extends Composer<_$AppDatabase, $MigrationMetaTable> {
  $$MigrationMetaTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);
}

class $$MigrationMetaTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $MigrationMetaTable,
          MigrationMetaRow,
          $$MigrationMetaTableFilterComposer,
          $$MigrationMetaTableOrderingComposer,
          $$MigrationMetaTableAnnotationComposer,
          $$MigrationMetaTableCreateCompanionBuilder,
          $$MigrationMetaTableUpdateCompanionBuilder,
          (
            MigrationMetaRow,
            BaseReferences<
              _$AppDatabase,
              $MigrationMetaTable,
              MigrationMetaRow
            >,
          ),
          MigrationMetaRow,
          PrefetchHooks Function()
        > {
  $$MigrationMetaTableTableManager(_$AppDatabase db, $MigrationMetaTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MigrationMetaTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MigrationMetaTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MigrationMetaTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> key = const Value.absent(),
                Value<String> value = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) =>
                  MigrationMetaCompanion(key: key, value: value, rowid: rowid),
          createCompanionCallback:
              ({
                required String key,
                required String value,
                Value<int> rowid = const Value.absent(),
              }) => MigrationMetaCompanion.insert(
                key: key,
                value: value,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$MigrationMetaTable, MigrationMetaRow>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $MigrationMetaTable,
                    MigrationMetaRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$MigrationMetaTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $MigrationMetaTable,
      MigrationMetaRow,
      $$MigrationMetaTableFilterComposer,
      $$MigrationMetaTableOrderingComposer,
      $$MigrationMetaTableAnnotationComposer,
      $$MigrationMetaTableCreateCompanionBuilder,
      $$MigrationMetaTableUpdateCompanionBuilder,
      (
        MigrationMetaRow,
        BaseReferences<_$AppDatabase, $MigrationMetaTable, MigrationMetaRow>,
      ),
      MigrationMetaRow,
      PrefetchHooks Function()
    >;
typedef $$LegacyQuarantineTableCreateCompanionBuilder =
    LegacyQuarantineCompanion Function({
      Value<int> id,
      required String sourceBox,
      Value<String?> sourceKey,
      Value<String?> payloadJson,
      Value<String?> payloadSha256,
      required String error,
      required int createdAtMs,
    });
typedef $$LegacyQuarantineTableUpdateCompanionBuilder =
    LegacyQuarantineCompanion Function({
      Value<int> id,
      Value<String> sourceBox,
      Value<String?> sourceKey,
      Value<String?> payloadJson,
      Value<String?> payloadSha256,
      Value<String> error,
      Value<int> createdAtMs,
    });

class $$LegacyQuarantineTableFilterComposer
    extends Composer<_$AppDatabase, $LegacyQuarantineTable> {
  $$LegacyQuarantineTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sourceBox => $composableBuilder(
    column: $table.sourceBox,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sourceKey => $composableBuilder(
    column: $table.sourceKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get payloadSha256 => $composableBuilder(
    column: $table.payloadSha256,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get error => $composableBuilder(
    column: $table.error,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAtMs => $composableBuilder(
    column: $table.createdAtMs,
    builder: (column) => ColumnFilters(column),
  );
}

class $$LegacyQuarantineTableOrderingComposer
    extends Composer<_$AppDatabase, $LegacyQuarantineTable> {
  $$LegacyQuarantineTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sourceBox => $composableBuilder(
    column: $table.sourceBox,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sourceKey => $composableBuilder(
    column: $table.sourceKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get payloadSha256 => $composableBuilder(
    column: $table.payloadSha256,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get error => $composableBuilder(
    column: $table.error,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAtMs => $composableBuilder(
    column: $table.createdAtMs,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LegacyQuarantineTableAnnotationComposer
    extends Composer<_$AppDatabase, $LegacyQuarantineTable> {
  $$LegacyQuarantineTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get sourceBox =>
      $composableBuilder(column: $table.sourceBox, builder: (column) => column);

  GeneratedColumn<String> get sourceKey =>
      $composableBuilder(column: $table.sourceKey, builder: (column) => column);

  GeneratedColumn<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get payloadSha256 => $composableBuilder(
    column: $table.payloadSha256,
    builder: (column) => column,
  );

  GeneratedColumn<String> get error =>
      $composableBuilder(column: $table.error, builder: (column) => column);

  GeneratedColumn<int> get createdAtMs => $composableBuilder(
    column: $table.createdAtMs,
    builder: (column) => column,
  );
}

class $$LegacyQuarantineTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $LegacyQuarantineTable,
          LegacyQuarantineRow,
          $$LegacyQuarantineTableFilterComposer,
          $$LegacyQuarantineTableOrderingComposer,
          $$LegacyQuarantineTableAnnotationComposer,
          $$LegacyQuarantineTableCreateCompanionBuilder,
          $$LegacyQuarantineTableUpdateCompanionBuilder,
          (
            LegacyQuarantineRow,
            BaseReferences<
              _$AppDatabase,
              $LegacyQuarantineTable,
              LegacyQuarantineRow
            >,
          ),
          LegacyQuarantineRow,
          PrefetchHooks Function()
        > {
  $$LegacyQuarantineTableTableManager(
    _$AppDatabase db,
    $LegacyQuarantineTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LegacyQuarantineTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LegacyQuarantineTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LegacyQuarantineTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> sourceBox = const Value.absent(),
                Value<String?> sourceKey = const Value.absent(),
                Value<String?> payloadJson = const Value.absent(),
                Value<String?> payloadSha256 = const Value.absent(),
                Value<String> error = const Value.absent(),
                Value<int> createdAtMs = const Value.absent(),
              }) => LegacyQuarantineCompanion(
                id: id,
                sourceBox: sourceBox,
                sourceKey: sourceKey,
                payloadJson: payloadJson,
                payloadSha256: payloadSha256,
                error: error,
                createdAtMs: createdAtMs,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String sourceBox,
                Value<String?> sourceKey = const Value.absent(),
                Value<String?> payloadJson = const Value.absent(),
                Value<String?> payloadSha256 = const Value.absent(),
                required String error,
                required int createdAtMs,
              }) => LegacyQuarantineCompanion.insert(
                id: id,
                sourceBox: sourceBox,
                sourceKey: sourceKey,
                payloadJson: payloadJson,
                payloadSha256: payloadSha256,
                error: error,
                createdAtMs: createdAtMs,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$LegacyQuarantineTable, LegacyQuarantineRow>(
                    table,
                  ),
                  BaseReferences<
                    _$AppDatabase,
                    $LegacyQuarantineTable,
                    LegacyQuarantineRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$LegacyQuarantineTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $LegacyQuarantineTable,
      LegacyQuarantineRow,
      $$LegacyQuarantineTableFilterComposer,
      $$LegacyQuarantineTableOrderingComposer,
      $$LegacyQuarantineTableAnnotationComposer,
      $$LegacyQuarantineTableCreateCompanionBuilder,
      $$LegacyQuarantineTableUpdateCompanionBuilder,
      (
        LegacyQuarantineRow,
        BaseReferences<
          _$AppDatabase,
          $LegacyQuarantineTable,
          LegacyQuarantineRow
        >,
      ),
      LegacyQuarantineRow,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$ConversationRowsTableTableManager get conversationRows =>
      $$ConversationRowsTableTableManager(_db, _db.conversationRows);
  $$MessageRowsTableTableManager get messageRows =>
      $$MessageRowsTableTableManager(_db, _db.messageRows);
  $$MessagePartsTableTableManager get messageParts =>
      $$MessagePartsTableTableManager(_db, _db.messageParts);
  $$ProviderArtifactsTableTableManager get providerArtifacts =>
      $$ProviderArtifactsTableTableManager(_db, _db.providerArtifacts);
  $$MessageFileRecordsTableTableManager get messageFileRecords =>
      $$MessageFileRecordsTableTableManager(_db, _db.messageFileRecords);
  $$ConversationWorkspaceBindingsTableTableManager
  get conversationWorkspaceBindings =>
      $$ConversationWorkspaceBindingsTableTableManager(
        _db,
        _db.conversationWorkspaceBindings,
      );
  $$MigrationMetaTableTableManager get migrationMeta =>
      $$MigrationMetaTableTableManager(_db, _db.migrationMeta);
  $$LegacyQuarantineTableTableManager get legacyQuarantine =>
      $$LegacyQuarantineTableTableManager(_db, _db.legacyQuarantine);
}
