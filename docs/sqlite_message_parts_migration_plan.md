# SQLite/Drift Chat Storage and `message_parts` Migration Plan

| Item | Value |
|---|---|
| Status | M1-M4 landed 2026-10-31 (storage core, live `ChatService` facade, lazy tool detail, storage settings, marker-backed legacy retirement). M5 startup hardening is in progress: blocking progress/retry UI, the R5 Hive-open boundary, the optional pre-migration backup archive, streaming `DataSync` export, validated explicit legacy re-import, temporary Android foreground execution during migration, explicit restore/reset recovery, and per-conversation message lazy loading plus a Windows benchmark baseline are landed; Windows/Android platform smoke tests, Android benchmark validation, crash/kill tests, and Hive removal (M5-M6) remain |
| Scope | Chat history storage: conversations, messages, tool events, Gemini thought signatures, message file records, conversation workspace bindings |
| Target platforms | **Windows (x64/ARM64) and Android (arm64-v8a) are the release targets.** macOS/Linux/iOS code may remain source-compatible, but they are not released and are excluded from the M5/M6 acceptance gates. |
| Out of scope | Web storage, settings/assistant/MCP/skills Hive boxes, context-compaction policy, tool-output truncation policy, end-to-end encryption |
| Storage engine | SQLite through Drift |
| Authoritative source after cutover | `chat_v2.sqlite` |
| Legacy source | Existing Hive boxes, retained read-only after migration |

---

## 1. Summary

OmniChat currently stores chat data in several Hive boxes. The most problematic is `tool_events_v1`:

- The whole box is opened eagerly at startup.
- Each key is an assistant-message id.
- Each value is a `List<Map<String, dynamic>>` containing every tool call and result for that assistant message.
- Updating one tool result rewrites the entire list for that message.
- Hive appends frames; its default compaction strategy rewrites the whole box when `deletedEntries > 60` and `deletedEntries / entries > 15%`. This bounds stale frames, but not live data, and compaction itself is a full-box rewrite.
- There is no foreign key, no row-level index, and no cascade delete.

This plan replaces the chat-storage hot path with a single SQLite database managed by Drift. Tool calls and tool results become independently addressable `message_parts` rows. Full tool content is preserved; this plan does **not** introduce a retention policy, content cap, or deletion of old history.

The migration is a one-time copy-then-swap import. The temp database is disposable: an interrupted import is discarded and restarted from Hive rather than resumed from a cursor.

1. Build a new SQLite database in a temporary file.
2. Import Hive data in batches.
3. Validate counts, ordering, and content hashes.
4. Publish the SQLite file atomically.
5. Keep the original Hive files untouched as a legacy fallback/export source.

The existing `ChatService` public API remains as a facade during the transition. UI code is not required to switch to async database calls in the first milestone; a per-conversation cache preserves the synchronous read methods until lazy tool-detail loading is introduced.

This is a storage-architecture change, not a disk-usage reduction promise. SQLite replaces Hive's whole-box append/compaction behavior and enables row-level updates, but a complete tool history still grows with usage.

---

## 2. Current State

### 2.1 Hive boxes owned by chat

| Box | Key | Value |
|---|---|---|
| `conversations` | conversation id | `Conversation` |
| `messages` | message id | `ChatMessage` |
| `tool_events_v1` | assistant message id | `List<Map<String, dynamic>>` |
| `tool_events_v1` | `sig_<assistant message id>` | Gemini thought signature string |
| `message_file_records_v1` | message id | `List<Map<String, dynamic>>` |
| `conversation_workspace_bindings_v2` | conversation id | `WorkspaceConfig.toJson()` |
| `conversation_workspaces_v1` | conversation id | legacy absolute path string |

`messages` is also a single box, but each message has its own key. The tool-event problem is therefore not "all tools are in one key"; it is that **one assistant message's entire tool collection is one mutable List value**, and the box is eager with append-only frames that auto-compact on thresholds.

### 2.2 `tool_events_v1` event shape

A typical event contains:

```json
{
  "id": "call_abc123",
  "name": "web_fetch",
  "arguments": {"url": "https://example.com"},
  "content": "full tool result text",
  "approvalState": "pending",
  "searchProvider": "tavily",
  "searchFallbackFrom": "brave",
  "webFetchSource": "Local",
  "reasoning_content": "...",
  "reasoning_details": []
}
```

The exact set of optional keys can grow. The migration must preserve unknown keys instead of dropping them.

### 2.3 Current pain points

1. **Startup memory:** `Hive.openBox('tool_events_v1')` eagerly loads all keys and values.
2. **Write amplification:** `upsertToolEvent` copies the whole list, replaces one entry, and writes the whole list back.
3. **Append-only + full-box compaction:** Hive appends frames and auto-compacts at `deletedEntries > 60` with a `>15%` deleted ratio, but each compaction rewrites the entire box; live values still grow with use.
4. **No relational integrity:** deleting a conversation requires manual deletion of messages, tool events, signatures, file records, and workspace bindings.
5. **No indexes for row-level access:** the UI/replay path always decodes the whole event list for a message.
6. **Poor scaling with large tool results:** a single `web_fetch` or MCP result can dominate a message's storage value.

### 2.4 Behavior that must be preserved

- Full tool content already present in Hive (including the existing `file_read` 8 KB persisted preview).
- Tool ordering within a message.
- `id`, `name`, `arguments`, `content`, `approvalState`, and all known UI/replay extras.
- Pending approvals and `ask_user` checkpoints.
- Gemini thought signatures.
- Message order, version groups, and version selections.
- Conversation summaries, truncation index, and compaction boundary.
- File records and conversation workspace configuration.
- Existing backup/export JSON shape where practical.

**Intentional behavior change:** tool replay is no longer all-or-nothing on `content == null`, and pending approval-protocol JSON is no longer replayed as a tool result. The per-part pairing rules are in 9.5.2; this is a deliberate correction, not a preservation requirement.

---

## 3. Goals and Non-Goals

### 3.1 Goals

1. Normalize each tool call/result into an independent `message_parts` row.
2. Preserve all tool content that is stored in Hive, without adding a new storage-time truncation. The existing `file_read` 8 KB persisted-preview policy is unchanged and out of scope.
3. Avoid loading all tool contents at startup.
4. Make a single tool result update a row-level operation.
5. Enforce cascade deletion through foreign keys.
6. Preserve all existing Hive data through a validated migration.
7. Keep the migration crash-safe: an interrupted import discards the temp database and restarts from Hive.
8. Keep the original Hive data available for rollback/export.
9. Keep the `ChatService` API stable enough that UI changes are incremental.
10. Support full backup/restore/export of the migrated data.
11. Keep the design open for a future text/reasoning-parts migration.

### 3.2 Non-goals

- No deletion or truncation of old tool content.
- No retention-by-age or retention-by-size policy.
- No change to `ToolResultCaps` or transport-level tool-result limits.
- No change to context compaction, summarization, or tool-result pruning.
- No redesign of the chat UI.
- No migration of settings, assistants, MCP configuration, skills, logs, or other non-chat Hive boxes.
- No web/IndexedDB migration in this plan.
- No encryption-at-rest change (the SQLite file has the same trust boundary as the current Hive files).

---

## 4. Decisions

| ID | Decision | Rationale |
|---|---|---|
| D1 | Use Drift over raw SQLite for the chat database | Typed schema, generated queries, schema versioning, migration tests, and background-isolate support. The decision does not depend on any external project. |
| D2 | Use one SQLite database, not one database per conversation | One database supports indexes, cross-conversation queries, FTS, backup, and foreign keys without thousands of files. |
| D3 | Migrate tool events into `message_parts` first | Solves the tool-result hot path without simultaneously rewriting text/reasoning rendering. Text/reasoning parts remain a later phase. |
| D4 | Use copy-then-swap migration | Hive remains untouched until a validated SQLite copy is ready; rollback before publish is a file deletion. |
| D5 | Do not dual-write Hive and SQLite | Dual-write preserves the old performance problem and creates two sources of truth. Hive is a read-only legacy snapshot after publish. |
| D6 | Retain Hive files after migration | Enables export, forensic recovery, and a fallback before the first SQLite write. No automatic deletion. |
| D7 | Load tool summaries for the timeline and full content on demand | Keeps large tool bodies out of the first render and out of startup. |
| D8 | Keep the backup JSON shape compatible | Existing backup/restore and importers continue to work with a repository-backed `toolEvents` map. |

---

## 5. Target Architecture

### 5.1 Storage stack

- `AppDatabase` (Drift) owns `chat_v2.sqlite` under `AppDirectories.getAppDataDirectory()`.
- The database is opened with `NativeDatabase.createInBackground(...)` so SQLite work does not block the Flutter UI isolate.
- SQLite PRAGMAs:
  - `journal_mode = WAL`
  - `foreign_keys = ON`
  - `busy_timeout = 5000`
  - `synchronous = NORMAL` at runtime; the migration connection uses `synchronous = FULL` and checkpoints WAL before publish.
- PRAGMAs are set in Drift's `beforeOpen` and verified with `PRAGMA` assertions on startup.
- Ship a known SQLite build on the release targets (Windows/Android); do not depend on the host system SQLite. `sqlite3` native assets are the current mechanism; `sqlite3_flutter_libs` is EOL plan parity only.
- All writes go through repository methods and transactions.
- The Hive chat boxes are not opened when the SQLite database is authoritative.

### 5.2 High-level schema

```
conversations
  └─ messages (conversation_id, ordinal)
       ├─ message_parts (message_id, ordinal, kind='tool')
       ├─ provider_artifacts (message_id, kind)
       └─ message_file_records (message_id)

conversations
  └─ conversation_workspace_bindings (conversation_id)
```

### 5.3 `message_parts` semantics

Phase 1 uses `message_parts` for tool events:

- `kind = 'tool'`
- `tool_call_id` = event `id` (may be null/empty in legacy data)
- `tool_name` = event `name`
- `arguments_json` = serialized event `arguments`
- `content` = event `content` exactly as stored (nullable for pending tools)
- `status` = `pending` (approval required or still running), `interrupted` (no result after a crash/stop), `denied` (approval denied), or `completed` (real result present). Pending/denied rows may still carry approval-protocol JSON in `content`.
- `approval_state` = event `approvalState`
- `metadata_json` = unmapped extras only (`webFetchSource`, unknown keys)
- `ordinal` = index in the original Hive event list

The schema reserves `kind = 'text'` and `kind = 'reasoning'` for a later phase. Phase 1 does **not** move `ChatMessage.content` or `ChatMessage.reasoningText` out of the `messages` table. This avoids a simultaneous rewrite of rendering, API assembly, and migration.

A later phase may:

1. Insert text/reasoning parts with their own ordinals.
2. Keep `messages.content` / `messages.reasoning_text` as compatibility projections.
3. Remove those columns after all readers use parts.

`ordinal` is a single per-message order. In Phase 1 it is the tool-event list index. When Phase 2 adds text/reasoning parts, it must renumber all parts into one global order in its own schema migration; do not assume the Phase 1 tool ordinals survive unchanged.

That later phase must be its own schema migration with its own validation.

---

## 6. Schema

The following is the initial schema version (`schemaVersion = 1`). Column names are illustrative but should be treated as the implementation contract.

```sql
CREATE TABLE conversations (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  assistant_id TEXT,
  is_pinned INTEGER NOT NULL DEFAULT 0,
  truncate_index INTEGER NOT NULL DEFAULT -1,
  compact_before_index INTEGER NOT NULL DEFAULT -1,
  summary TEXT,
  last_summarized_message_count INTEGER NOT NULL DEFAULT 0,
  mcp_server_ids_json TEXT NOT NULL DEFAULT '[]',
  version_selections_json TEXT NOT NULL DEFAULT '{}',
  is_recovered INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX idx_conversations_updated_at
  ON conversations(updated_at DESC);

CREATE INDEX idx_conversations_assistant_updated
  ON conversations(assistant_id, updated_at DESC);

CREATE TABLE messages (
  id TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL
    REFERENCES conversations(id) ON DELETE CASCADE,
  ordinal INTEGER NOT NULL,
  role TEXT NOT NULL,
  content TEXT NOT NULL,
  timestamp INTEGER NOT NULL,
  model_id TEXT,
  provider_id TEXT,
  total_tokens INTEGER,
  prompt_tokens INTEGER,
  completion_tokens INTEGER,
  cached_tokens INTEGER,
  is_streaming INTEGER NOT NULL DEFAULT 0,
  reasoning_text TEXT,
  reasoning_start_at INTEGER,
  reasoning_finished_at INTEGER,
  translation TEXT,
  reasoning_segments_json TEXT,
  group_id TEXT,
  version INTEGER NOT NULL DEFAULT 0,
  ai_team_proposals_json TEXT,
  process_started_at INTEGER,
  process_finished_at INTEGER,
  UNIQUE(conversation_id, ordinal)
);

CREATE INDEX idx_messages_conversation_ordinal
  ON messages(conversation_id, ordinal);

CREATE INDEX idx_messages_group_version
  ON messages(conversation_id, group_id, version);

CREATE INDEX idx_messages_streaming
  ON messages(is_streaming);

CREATE TABLE message_parts (
  part_id INTEGER PRIMARY KEY AUTOINCREMENT,
  message_id TEXT NOT NULL
    REFERENCES messages(id) ON DELETE CASCADE,
  ordinal INTEGER NOT NULL,
  kind TEXT NOT NULL,
  tool_call_id TEXT,
  tool_name TEXT,
  arguments_json TEXT,
  content TEXT,
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK(status IN ('pending', 'completed', 'interrupted', 'denied')),
  approval_state TEXT,
  metadata_json TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  UNIQUE(message_id, ordinal),
  CHECK(status <> 'completed' OR content IS NOT NULL)
);

CREATE INDEX idx_message_parts_message_ordinal
  ON message_parts(message_id, ordinal);

CREATE INDEX idx_message_parts_tool_call
  ON message_parts(message_id, tool_call_id);

CREATE INDEX idx_message_parts_tool_name
  ON message_parts(message_id, tool_name, ordinal);

CREATE TABLE provider_artifacts (
  message_id TEXT NOT NULL
    REFERENCES messages(id) ON DELETE CASCADE,
  kind TEXT NOT NULL,
  payload TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY(message_id, kind)
);

CREATE TABLE message_file_records (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  message_id TEXT NOT NULL
    REFERENCES messages(id) ON DELETE CASCADE,
  ordinal INTEGER NOT NULL,
  path TEXT NOT NULL,
  file_name TEXT,
  size_bytes INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  UNIQUE(message_id, path)
);

CREATE INDEX idx_message_file_records_message
  ON message_file_records(message_id, ordinal);

CREATE TABLE conversation_workspace_bindings (
  conversation_id TEXT PRIMARY KEY
    REFERENCES conversations(id) ON DELETE CASCADE,
  config_json TEXT NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE migration_meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

CREATE TABLE legacy_quarantine (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  source_box TEXT NOT NULL,
  source_key TEXT,
  payload_json TEXT,
  payload_sha256 TEXT,
  error TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
```

### 6.1 Schema notes

- Timestamps are epoch milliseconds (`INTEGER`). Dart `DateTime` values are absolute instants; store `millisecondsSinceEpoch` directly and do not add or subtract a timezone offset. Convert to local time only at the UI boundary. Backup/export keeps the existing ISO representation.
- Boolean columns are `0`/`1`.
- `truncate_index` is a zero-based **start index** in raw message-list space: messages at or after it are included, `-1` disables truncation, and a value equal to the message count means all messages are truncated (clear context). It is not a count, despite helper names such as `lastIndexPlusOne`.
- `compact_before_index` is a zero-based raw index: messages before it are compacted, `-1` disables compaction. Both indices are validated as `-1 <= value <= message count` during migration and after deletes.
- `message_parts.content` is `NULL` for a tool without a result; an empty string is a real empty result.
- `message_parts.status` is `pending | completed | interrupted | denied`. Status is derived from `approval_state` first: `pending` → `pending`, `denied` → `denied`; `approved`/`answered`/`auto` with content → `completed`, without content → `interrupted`. A pending/denied row may have approval-protocol JSON in `content`; that is not a tool result. `completed` requires non-null content, enforced by a table check.
- `approval_state` is a closed set: `auto | pending | approved | denied | answered`. Normalize unknown/null to `auto`. Use these exact values; there is no `rejected` approval state.
- `message_parts.metadata_json` preserves only event keys that have no dedicated column, plus a `legacyKeys` list. Do not duplicate `content`, `name`, `arguments`, or `approvalState`; `webFetchSource` has no dedicated column and stays in metadata.
- `message_parts.arguments_json` stores a JSON object string. If legacy `arguments` is not a map, preserve the raw value in metadata and store a valid JSON wrapper.
- `conversation.messageIds` is **not stored twice**. It is hydrated from `messages` ordered by `ordinal`; ID-only queries are cheap even for large libraries. This removes the dual-source-of-truth risk of a `message_ids_json` column.
- `is_recovered` is set when a conversation is synthesized for orphaned messages.
- `legacy_quarantine` stores raw legacy payloads that cannot be decoded or attached, with a SHA-256 hash. It exists so migration never silently discards data.
- Do not add a unique constraint on `(message_id, tool_call_id)` in v1: legacy data may contain empty or duplicate ids. The application keeps the "first match wins" behavior and logs duplicates.
- Upsert algorithm: if `tool_call_id` is non-empty, update the first row with that id; otherwise update the first row with the same `tool_name`, `status='pending'`, and `content IS NULL OR content = ''` in `ordinal` order; never reuse an `interrupted`/`denied` row. If none matches, append. When the no-id fallback matches, preserve the placeholder's existing `tool_call_id` as the resolved id so a later id-aware result upsert lands on the same row; if the incoming id is non-empty, use it. This mirrors `upsertToolEvent` and must be covered by tests with empty/duplicate ids.

### 6.2 Schema versioning

- `schemaVersion = 1` for the initial SQLite database.
- Maintain `publishedSchemaVersions = {1}`. Add a version only after that schema has actually shipped. A database at any version outside this set, or newer than the running binary, must not be opened by a normal connection.
- Drift `MigrationStrategy.onCreate` creates the v1 schema.
- Future changes use Drift migrations; generated schema snapshots are kept under `drift_schemas/` for migration tests.
- Schema upgrades are performed only by `DatabaseInstallationGate` (6.3), never implicitly by a normal chat connection. The gate performs the pre-upgrade rollback copy, per-version transaction, `user_version`/`foreign_key_check`/`integrity_check` verification, and database-family publish.
- `onUpgrade` and `onDowngrade` must never be empty. Test every version step with Drift's schema verification in CI.
- Generated Drift files are not edited by hand; run `dart run build_runner build --delete-conflicting-outputs`.

### 6.3 Installation gate and schema admission

`DatabaseInstallationGate` runs before `ChatStorageGate` and before any live chat connection. It never opens a Hive chat box. It inspects the SQLite file directly (header plus `PRAGMA user_version`) without starting Drift's migration side effects.

Before applying the cases below, if `chat_v2.publish-intent.json` exists, run the 8.2.1 recovery first and continue only after it resolves. Then check `chat_v2.legacy_import_disabled`: if that sentinel is present, never report `needsMigration`; use a valid published database, otherwise create an empty database with `source='reset'` and keep the sentinel. A `chat_v2.reset` marker defers to 8.10; it never authorizes importing Hive.

1. **No database and no prior installation receipt**: if chat Hive files are present, do **not** create a published database here; report `needsMigration` and let 8.2 create the temp database. If no chat Hive files are present, create the current schema, write `migration_meta` (`database_id`, `source='fresh'`, `installed_schema_version=currentSchemaVersion`, `installed_by_app_version`, `state='complete_clean'`) in one transaction, then write `chat_v2.installation.json`. This is the only path that creates a database from nothing for a genuine fresh install; the sentinel/reset recovery paths are separate.
2. **Empty (0-byte) database**: treat it as a crashed first launch only when there is no installation receipt, no reset marker, and no chat Hive migration pending. Delete the empty file and continue: create fresh when there is no Hive, or start the Hive migration when Hive is present. If a receipt exists, fail closed unless `chat_v2.reset` is present; in that case 8.10 owns the path. A missing or empty database after a recorded installation is data loss, not a fresh install.
3. **Database at the current schema**: verify the header, `user_version`, `integrity_check`, `foreign_key_check`, and the in-database installation receipt. Repair a missing sidecar from the database; fail closed if the sidecar and database disagree on `database_id`.
4. **Database at an older published schema**: acquire the maintenance lock; close all connections; checkpoint WAL; copy the database family to `chat_v2.sqlite.previous` as the rollback copy; copy the main database to `chat_v2.sqlite.upgrading` as the working copy. Run only the published version steps against `.upgrading` through a dedicated `upgradeExecutor` with `synchronous = FULL`, foreign keys on, and no normal live open. Verify `PRAGMA user_version`, `foreign_key_check`, `integrity_check`, and the installation receipt before publishing `.upgrading` through 8.2.1 with `operation='upgrade'`. The working copy keeps the existing `database_id`; update `migration_meta.installed_schema_version` to the new `user_version` and write a fresh `publish_id` before the final checkpoint/close. Rewrite `chat_v2.installation.json` after publish and verify the recorded version equals `PRAGMA user_version`. Keep `.previous` until the app starts successfully once on the new schema; restore it only if its recorded identity matches the publish intent.
5. **Newer, unpublished, unknown, or unreadable schema**: fail closed with a diagnostics screen. Never delete, recreate, or "repair" by wiping the database. This includes a schema version present in the file but absent from `publishedSchemaVersions`.
6. **Missing database with an installation receipt**: do not create an empty database silently. Require an explicit restore/reset decision. A `chat_v2.reset` marker is the exception: it defers to 8.10. If the gate creates the empty database itself, it must write `source='reset'`, keep `chat_v2.legacy_import_disabled`, and write the installation sidecar; it must never write `source='fresh'` on this path.

`chat_v2.installation.json` is a mirror, not an authority. The database's `migration_meta` wins when readable. If the database is missing, the sidecar is the only evidence that a prior installation existed, so it must block silent recreation. A malformed sidecar is a fail-closed condition, not a fresh install.

The live connection setup asserts `user_version == currentSchemaVersion`; it does not run migrations. `onDowngrade` follows 8.9 and fails closed.

---

## 7. Hive to SQLite Mapping

### 7.1 Box-to-table mapping

| Hive source | SQLite destination | Notes |
|---|---|---|
| `conversations` | `conversations` | Preserve id, title, timestamps, assistant, pin, indices, summary, MCP ids, version selections. |
| `messages` | `messages` | Preserve all `ChatMessage` fields; assign `ordinal` from `Conversation.messageIds`. |
| `tool_events_v1` normal keys | `message_parts` (`kind='tool'`) | One row per event, ordered by original list index. |
| `tool_events_v1` `sig_<id>` keys | `provider_artifacts` (`kind='gemini_thought_signature'`) | One signature per assistant message in the current model. |
| `message_file_records_v1` | `message_file_records` | Preserve path, file name, size, creation time, list order. |
| `conversation_workspace_bindings_v2` | `conversation_workspace_bindings` | Store `WorkspaceConfig.toJson()` as `config_json`. |
| `conversation_workspaces_v1` | `conversation_workspace_bindings` fallback | Convert legacy absolute path to `WorkspaceConfig.custom(path)` if no v2 binding exists. |
| `message_snapshots_v1` | not migrated | Retired feature; optionally export raw file for diagnostics. |

### 7.2 Conversation mapping

- `id` → `conversations.id`
- `title` → `title`
- `createdAt`, `updatedAt` → epoch ms
- `assistantId` → `assistant_id`
- `isPinned` → `is_pinned`
- `truncateIndex` → `truncate_index` (zero-based start index; `-1` disables)
- `compactBeforeIndex` → `compact_before_index` (zero-based raw index; `-1` disables)
- `summary` → `summary`
- `lastSummarizedMessageCount` → `last_summarized_message_count`
- `messageIds` → `messages.ordinal` only; hydrate `Conversation.messageIds` from the ordered message rows
- `mcpServerIds` → `mcp_server_ids_json`
- `versionSelections` → `version_selections_json`

If `messageIds` contains duplicate ids, keep the first occurrence for ordering and log the duplicate. If a referenced message is missing, record the issue and leave the id out of the SQLite projection; do not invent content.

### 7.3 Message mapping

For each conversation, iterate `messageIds` in order:

- `ordinal` = index in the list.
- Load the `ChatMessage` from the `messages` Hive box.
- If the message's `conversationId` differs from the containing conversation, use the containing conversation id for the FK and record a repair issue.
- Preserve every scalar field exactly.
- `content` is stored as-is, including `[image:...]` / `[file:...]` markers.
- `timestamp`, reasoning timestamps, and process timestamps become epoch ms.
- `isStreaming` must be `0` after migration. The startup repair already clears stale streaming flags; the importer must also normalize it to avoid a permanent spinner.
- `groupId` defaults to the message id and `version` defaults to `0` according to current model behavior.

Messages that exist in the `messages` box but are not referenced by any conversation are not discarded:

1. Group them by their own `conversationId`.
2. If that conversation exists, append them after the referenced messages with increasing ordinals and record a repair issue.
3. If the conversation does not exist, create a synthetic conversation titled `Recovered messages` with `is_recovered = 1`, and attach the messages there.
4. Record counts in the migration report.

### 7.4 Tool event mapping

For each assistant message id with a `tool_events_v1` value:

1. Decode the value as a list.
2. For each element, create one `message_parts` row with `kind='tool'`.
3. Preserve list order in `ordinal`.
4. Map:
   - `id` → `tool_call_id` (empty becomes `NULL`)
   - `name` → `tool_name`
   - `arguments` → `arguments_json`
   - `content` → `content` (string as-is; `NULL` stays `NULL`; non-string JSON is serialized and marked in metadata). Current writers normalize non-string content to `null`, so this is a defensive legacy path, not an expected shape; keep it but test it at lower priority. Read the raw Hive value, not a bounded projection. `file_read` values are already bounded by the existing writer; do not apply a different cap during migration.
   - `approvalState` → `approval_state`, normalized with `normalizeApprovalState` to `auto | pending | approved | denied | answered` (unknown/null → `auto`)
   - `webFetchSource` → `metadata_json.webFetchSource`
   - all other keys → `metadata_json`
5. Set `status` with `approvalState` priority (pending/denied usually have approval-protocol JSON in `content`, so content presence alone is not enough):
   - `approvalState == pending` → `pending`
   - `approvalState == denied` → `denied`
   - `approvalState == approved`/`answered` and content is a string → `completed`
   - `approvalState == approved`/`answered` and content is null → `interrupted` (approved but no result; a crash/stop, not pending)
   - `approvalState == auto`/unknown and content is a string → `completed`
   - `approvalState == auto`/unknown and content is null → `interrupted`
6. Preserve only unmapped keys in `metadata_json`; do not duplicate fields that have columns. If the event cannot be decoded at all, write a `legacy_quarantine` row with the raw payload and a hash.

The importer must read the raw box value (`Box.get`/`LazyBox.get`), **not** `ChatService.getToolEvents`. `getToolEvents` applies `_boundToolEventForPersistence`, which re-applies the 8 KB `file_read` preview and converts non-string content to `null`; using it would make the SQLite copy differ from what is actually stored. Do not apply `ToolResultCaps`, re-run `file_read` preview truncation, or impose any new content limit during migration. `file_read` is already bounded by the existing writer.

### 7.5 Gemini thought signatures

- A key matching `sig_<messageId>` becomes `provider_artifacts(message_id, 'gemini_thought_signature', payload, ...)`.
- If the message id does not exist, store the signature in `legacy_quarantine` with the source key.
- `getGeminiThoughtSignature` and `setGeminiThoughtSignature` remain facade methods.
- Backups continue to expose the signature map.

### 7.6 File records and workspace bindings

- `message_file_records_v1` values are lists of file records. Preserve the list order using `ordinal`.
- If a record's message is missing, quarantine the record and continue.
- If a message has duplicate `(message_id, path)` records, keep the first, record the duplicate as an issue, and do not fail the migration.
- Import `conversation_workspace_bindings_v2` first.
- For a conversation that only has `conversation_workspaces_v1` (legacy path), create a `WorkspaceConfig.custom(path)` JSON binding if no v2 binding exists.
- Do not move or delete user files referenced by file records or workspace paths.

### 7.7 Orphan and malformed data policy

The migration must never silently drop user-visible history. The policy is:

1. **Repairable reference issue** (wrong conversation id, duplicate order): repair, log, continue.
2. **Undecodable value** (typed Hive adapter throws): attempt to read the raw value; if raw value is available, store it in `legacy_quarantine`; otherwise fail the migration and keep Hive intact.
3. **Missing parent** (tool event without message, file record without message): quarantine with source key.
4. **Missing conversation for message**: create a recovered conversation.
5. **Any quarantine rows**: migration may still publish, but the migration report must show the count and the UI must surface a warning with an export action.

The migration is not considered "clean" if any quarantine rows exist; it is considered "complete with issues". A clean validation is required for the normal success path.

---

## 8. Migration Design

### 8.1 State machine

```
FRESH_INSTALL
  -> SQLITE_READY

HIVE_ONLY
  -> MIGRATING
  -> VALIDATING
  -> PUBLISHING
  -> SQLITE_READY

MIGRATING / VALIDATING
  -> FAILED
  -> HIVE_FALLBACK (before publish)
  -> RETRY

SQLITE_READY + HIVE_LEGACY
  -> SQLITE_READY (Hive is read-only legacy)
```

`chat_v2.sqlite` is the published database. `chat_v2.sqlite.migrating` is the unpublished temporary database; it is never read by the app as a live store. `migration_meta` inside the published database is authoritative; the sidecar receipt is a human-readable mirror that can be regenerated.

Startup decision:

| Hive present | Published DB | Temp DB | Meta / markers | Action |
|---|---|---|---|---|
| any | any | any | `chat_v2.publish-intent` present | Run 8.2.1 recovery before any other decision; do not open Hive or delete the target. |
| any | any | any | `chat_v2.legacy_import_disabled` sentinel present | Never import Hive, even if SQLite is missing. Use the published DB if valid; otherwise create an empty DB with `source='reset'` and `chat_v2.installation.json`. |
| any | any | any | `chat_v2.reset` marker present | Do not import Hive. If a published DB with `migration_meta.source='reset'` exists, use it; otherwise delete any non-reset DB plus stale `-wal`/`-shm` and temp DB, create an empty DB, write `migration_meta source='reset'` and `chat_v2.installation.json`. Write `chat_v2.legacy_import_disabled`, then remove `chat_v2.reset`. |
| No | No | No | — | Create fresh SQLite database, write `migration_meta` (`source='fresh'`, `state='complete_clean'`, zero counts) and `chat_v2.installation.json`. |
| Yes | No | No | — | Run migration into temp DB. |
| Yes | No | Yes, complete_* | — | Validate temp DB, then publish. |
| Yes | No | Yes, incomplete | — | Discard temp DB and restart from Hive. |
| Yes | Yes | No | complete_* | Use SQLite; do not open Hive chat boxes. |
| No | Yes | No | complete_* | Use SQLite. |
| any | Yes | Yes | complete_* | Published DB wins; delete the stale temp DB and its WAL/SHM. |
| Yes | Yes | No | missing/unreadable | Treat as inconsistent; preserve both, run diagnostics, do not guess. |
| No | Yes | No | missing/unreadable | Open read-only diagnostics; never silently recreate and overwrite. |

### 8.2 Copy-then-swap

1. Confirm the exclusive maintenance lock is held.
2. Create `chat_v2.sqlite.migrating` in the same app-data directory.
3. Open Hive boxes with `openLazyBox` only; never eager-open `tool_events_v1`.
4. Import in batches.
5. Validate the temp database.
6. Write `migration_meta` with `database_id` (new UUID), `publish_id` (new UUID), `installed_schema_version=currentSchemaVersion`, `installed_by_app_version`, `source='hive'`, `state = 'complete_clean'` or `'complete_with_issues'`, `quarantine_count`, counts, total UTF-8 payload-byte sums (content plus canonical `arguments_json`), and the validation mode/seed/hash. "Complete" means the import and validation finished; it is still unpublished until the database-family publish succeeds. Generate both ids here so the publish helper never has to reopen a closed temp database.
7. Checkpoint WAL (`PRAGMA wal_checkpoint(TRUNCATE)`), confirm `chat_v2.sqlite.migrating-wal`/`-shm` are gone, close the temp database, and flush it to disk.
8. Publish the temp database family with the helper in 8.2.1. The helper verifies the temp family and its recorded `publish_id`, writes a durable publish-intent marker, preserves any existing published family as `.previous`, publishes the new family, fsyncs the parent directory, and verifies the target before clearing the intent. The final database is then published.
9. Write the sidecar receipt and installation sidecar. If this step fails, the in-database `migration_meta` is still authoritative and both sidecars can be regenerated on next launch.
10. Keep all Hive files untouched.

Use `PRAGMA synchronous = FULL` on the migration connection. The publication unit is the database family, not a single file: WAL/SHM sidecars, the previous family, and the intent marker must be handled together (8.2.1). The preferred path is an atomic replace that leaves the old target in place until the new file is durable. If the platform cannot replace atomically, use the recoverable move-aside path: write the intent marker first, preserve the old family as `.previous`, then rename. Never delete the old target before the intent marker is durable. On Windows, validate the primitive with `tool/windows_rename_spike.dart` and the shared helper before adding a second implementation.

A maintenance lock does not exist today and must be implemented before migration, not assumed. Use a Windows named mutex and a macOS/Linux advisory lock file containing the PID and process start time; treat a lock with a dead PID as stale. Android/iOS normally have one app process, but still enforce a process-level guard and a single database connection.

The lock is **exclusive only for pre-migration backup, migration, schema upgrade, publish, `clearAllData`, reset, and legacy retirement**. It does not make the whole app single-instance: normal SQLite reads/writes are protected by a single connection per process, WAL, and `busy_timeout`. A second instance may run normally **only when a published current database exists**; during migration, upgrade, or publish it waits at the gate with the 9.6 retry UI or exits, and it must never validate, publish, rebuild, or delete the database while another instance holds the maintenance lock. Surface `SQLITE_BUSY` as a retryable error rather than corrupting state.

### 8.2.1 Database-family publication

The publication unit is the database family, not a single `.sqlite` file. At minimum:

- `chat_v2.sqlite`
- `chat_v2.sqlite-wal`
- `chat_v2.sqlite-shm`
- `chat_v2.sqlite.migrating` and its `-wal`/`-shm` (Hive migration working copy)
- `chat_v2.sqlite.upgrading` and its `-wal`/`-shm` (schema-upgrade working copy)
- `chat_v2.sqlite.previous` (previous published family for either operation)
- `chat_v2.sqlite.replaced-<publish_id>` (non-atomic replacement cleanup copy, if used)
- `chat_v2.installation.json` and `chat_v2.migration.json`
- `chat_v2.publish-intent.json`

The SQLite/WAL/SHM files are renamed as a family. The JSON receipts are written after target verification, and the intent marker is written before target mutation; they are not renamed into place with the database. For a Hive migration, `temp` means `.migrating`; for an upgrade, `temp` means `.upgrading`. `previous` always means `.previous`.

Rules:

- Never leave `-wal`/`-shm` from a closed temp database. Run `wal_checkpoint(TRUNCATE)`, close, verify the sidecars are gone, and fsync the temp file.
- Write `chat_v2.publish-intent.json` atomically before moving or replacing the target. It records: format version, operation (`migrate` or `upgrade`), temp path, target path, previous path, `publish_id`, temp database id, target database id, previous database id/schema/size/SHA-256 (when a previous exists), target schema version, temp/target sizes and SHA-256, stage (`prepared`, `target-preserved`, `published`, or `verified`), timestamps, and app version.
- `publish_id` is generated when the temp/upgrading database's `migration_meta` is written, before its final checkpoint/close; the helper reads it and records it in the intent. Do not reopen a closed temp database just to write it. A target counts as published only when it carries the intent's `publish_id`. This works for upgrades, where the working copy intentionally keeps the same `database_id` as the target. If the recorded `publish_id` is missing or empty, fail closed.
- Use the strongest same-volume replace primitive available. If it cannot replace atomically, preserve the existing target as `.previous` and rename the temp into place. If a matching `.previous` already exists, do not overwrite it: move the current target to `.replaced-<publish_id>` for cleanup instead. The intent marker makes this recoverable; the old target must not be deleted before the marker is durable.
- `fsync` the temp file and, where supported, the parent directory after every rename. The target is not considered published until it opens, passes `integrity_check`/`foreign_key_check`, carries the intent's `publish_id`, and its in-database `migration_meta` receipt is readable. Sidecar JSON can be regenerated after this check.
- Remove `publish-intent` only after verification. Keep `.previous` until the app has started successfully once on the new database (or until the next successful maintenance operation); then delete it in a separate, best-effort cleanup.
- Recovery only treats a readable target as the old target when its schema has shipped and, for the current schema, it is complete with an installation identity. A newer, unpublished, or incomplete target fails closed and is never replaced by the intent's temp database.
- If the target base file is gone but `-wal`/`-shm` remain, quarantine those sidecars as `chat_v2.sqlite.orphan-<publish_id>-wal/-shm` before renaming the temp family into place; they must never attach to the new database. A corrupt target is quarantined as `.corrupt-<publish_id>` and publication completes without requiring a `.previous`.
- A stale `.previous` is not an alternate live database. It is recovery material only.

Startup recovery (run before Hive admission):

| Intent state | Target | Temp | Action |
|---|---|---|---|
| absent | valid current | any | Normal admission; delete stale temp/previous only after verifying the target. |
| present, `prepared`/`target-preserved`/`published` | valid current, carries the intent `publish_id` | valid complete and temp id matches the intent | Target already published; verify, remove temp, keep previous until a clean admission deletes it. |
| present, any | valid current, carries the intent `publish_id` | invalid/missing | Target already published; remove only the invalid/missing temp and keep a valid `.previous` until clean admission. |
| present, `prepared` | valid current, does not carry the intent `publish_id` | valid complete and temp id matches the intent | Normal pre-publish crash: preserve the target as `.previous` (or verify the already-recorded previous), rename temp into place, then verify. |
| present, `prepared`/`target-preserved` | valid current, does not carry the intent `publish_id` | invalid/corrupt | Target is the intact old database: verify its identity/schema, keep it, discard/quarantine the bad temp, remove the intent, and restart import/upgrade. Do not publish. |
| present, `target-preserved` | missing | valid complete and temp id matches the intent | Verify temp, complete the rename, then verify the target. |
| present, `target-preserved` | valid current, target id matches the recorded previous id | valid complete and temp id matches the intent | The target move has not happened yet: move/verify the target as `.previous` or `.replaced-<publish_id>`, complete the rename, then verify. |
| present, `published`/`verified` | valid current, does not carry the intent `publish_id` | valid complete | Split-brain: do not guess and do not delete either; show diagnostics. |
| present, any | target is valid current and carries neither the intent `publish_id` nor the recorded previous database id | any | Split-brain: do not guess and do not delete anything; show diagnostics. |
| present, any | invalid/missing | valid complete and temp id matches the intent | Quarantine an existing invalid target as `chat_v2.sqlite.corrupt-<publish_id>`; complete publication; never overwrite a `.previous` that matches the intent. |
| present, any | invalid/missing | invalid/missing | Restore `.previous` only if its database id/schema/size/SHA-256 match the intent; otherwise fail closed and keep all files for diagnostics. |
| present, any | any | temp exists but its database id differs from the intent | Split-brain: do not publish or delete; keep all files and diagnose. |
| malformed | any | any | Fail closed; never delete target, temp, or previous. |

Temp identity must match the intent's recorded temp `database_id` before any publication step; a mismatch is a split-brain condition, not a retry. The installation gate deletes `.previous`, `.migrating`, `.upgrading`, `.replaced-*`, and their sidecars after a clean admission with no publish intent and a verified current target. That is the defined "started successfully once" trigger.

### 8.2.2 Pre-migration backup (optional)

**M5 implementation:** `PreMigrationBackupService` runs under the maintenance lock, streams each raw `.hive` file and a JSON export from a **staging copy** into a temp zip, records sizes/mtimes/SHA-256 in `manifest.json`, flushes, reopens the zip to verify entry sizes, then renames it atomically. `ChatStorageGate` prompts before creating the temp database; the production path requires an explicit backup/skip decision (`requireBackupPrompt`), and a cancelled backup or backup failure returns `failed` and leaves Hive authoritative for this launch. The receipt records `backup=completed` plus `backupArtifact`. The JSON export opens a **staging copy** only after asserting that no chat Hive box is already open; if the legacy fallback still holds the boxes, the backup refuses and asks for a restart instead of touching the real files.

Before creating the temp database, the migration gate offers:

- **Back up chat data now** (recommended): stream an archive containing the chat Hive artifacts listed in 8.8 (excluding the retired `message_snapshots_v1`) plus the existing JSON export (`conversations`, `messages`, `toolEvents`, `geminiThoughtSigs`, `fileRecords`, `workspaces`) and a manifest.
- **Skip backup**: allowed only after explicit confirmation. Record `backup='skipped'` in the migration receipt and show the Hive location.

Rules:

- Run the backup gate under the maintenance lock, after the migration gate has blocked chat writes and before the temp database is created. Release the lock only when the backup step is finished (or explicitly skipped).
- The backup is chat-only. Settings, assistants, MCP/skills, logs, and media outside the chat boxes are out of scope and must not be silently implied.
- Write to a user-selected folder or the platform document picker; never overwrite an existing backup without confirmation.
- Stream file copies; do not build the whole archive in memory. Write a temp archive, fsync it, then atomically rename it to the final name.
- The manifest includes app version, timestamp, artifact names/sizes/SHA-256, and JSON export counts. Re-open and verify the archive before reporting success.
- A failed backup does not corrupt migration. The user can retry or explicitly skip. A skipped or failed backup is recorded, and the UI repeats that Hive remains in place.
- The backup is for disaster recovery/manual restore; it is not an automatic rollback source. Hive remains the primary pre-publish fallback.
- Backup files contain full tool content and use the same access controls and warnings as existing exports.

### 8.3 Import order

Per conversation, in a transaction:

1. Insert/update the conversation row.
2. Insert message batches.
3. Insert tool parts for those messages.
4. Insert provider artifacts for those messages.
5. Insert file records.
6. Insert workspace binding.

This order satisfies foreign keys. Each conversation is committed independently, but an interrupted run is not resumed: the temp database is discarded and the import restarts from Hive. After all conversations, import orphan messages/tool events into recovery conversations/quarantine.

After import, run the SQLite equivalent of `repairStaleStreamingMessages`: any `messages.is_streaming = 1` at startup is stale and must be set to `0`. For parts, use an explicit predicate so a part still waiting for approval is never flipped:

```sql
UPDATE message_parts
SET status = 'interrupted'
WHERE content IS NULL
  AND status <> 'denied'
  AND (approval_state IS NULL OR approval_state <> 'pending');
```

Do not invent a new `process_started_at` or timer. This repair is idempotent and is covered by acceptance tests. `approved`/`answered` with null content intentionally becomes `interrupted`; pin that semantic in tests.

### 8.4 Batch strategy

- Conversation batch: 64 conversations per progress step.
- Message batch: 128 messages per transaction.
- Tool event batch: 256 parts per transaction.
- There is **no cursor and no resume**. The temp database is a disposable work copy; if it is missing, corrupt, or the process dies, delete it and restart from Hive. Hive is the source of truth.
- `migration_meta` stores only diagnostic/progress fields: `stage`, `started_at`, `source_counts`, `state`, `quarantine_count`, and validation mode/seed. It does not store `last_*` ids.
- Each batch uses `INSERT ... ON CONFLICT ... DO UPDATE` for duplicate legacy keys within the same run. **Never use `INSERT OR REPLACE` on `conversations` or `messages`**: SQLite implements it as delete-then-insert, which fires `ON DELETE CASCADE` and can silently delete already-imported child rows. For `message_parts`, insert on `(message_id, ordinal)` and keep `part_id` stable.
- Migration inserts use the source-list `(message_id, ordinal)` key; runtime upserts use `tool_call_id`/tool-name fallback. The two keys serve different stages and do not need a shared version pin.
- Measure the restart cost in M0. If a target device routinely exceeds the migration budget, add a coarse checkpoint as a separate, tested optimization; do not build a resume state machine into v1.

### 8.5 Validation before publish

The migration must pass all of the following:

1. `destination_conversations = source_conversations + synthesized_conversations`; every synthesized conversation has a recorded reason and its source message ids.
2. `destination_messages = source_messages - unreadable_messages`; unreadable messages are recorded as issues and never invented.
3. For every conversation, `messageIds` hydrated from `messages.ordinal` equals the source `Conversation.messageIds` order after removing missing references and recording them.
4. For every decodable tool-event list, the per-message destination part count plus quarantined elements equals the source list length, and `destination_parts + quarantined_event_elements = source_event_elements`. A whole list that cannot be decoded is quarantined as one unit and counted as one source unit, with `element_count_unknown` recorded.
5. `destination_provider_artifacts + quarantined_signatures = source_sig_keys`.
6. `destination_file_records + quarantined_file_records = source_file_records`.
7. `destination_workspace_bindings = distinct_conversation_ids(v2 keys ∪ v1 keys)`; a v1 key with a v2 binding is counted once and is not overwritten.
8. For every conversation, `truncate_index` and `compact_before_index` are `-1` or within `[0, message_count]`; `truncate_index` is a start index, not a count.
9. Every message has a valid conversation FK.
10. Every part has a valid message FK.
11. No duplicate `(conversation_id, ordinal)` or `(message_id, ordinal)`.
12. `PRAGMA integrity_check` returns `ok`.
13. `PRAGMA foreign_key_check` returns no rows.
14. **All rows:** source and destination counts and total UTF-8 payload-byte sums match for `content` and `arguments_json`. This catches dropped, duplicated, or grossly truncated rows without re-decoding every large body. Compute content as raw UTF-8 bytes (NULL contributes 0 bytes); compute arguments as canonical JSON UTF-8 bytes using the same canonicalization as item 15. Use Dart `utf8.encode(...).length`; use SQLite `length(CAST(content AS BLOB))` / `length(CAST(arguments_json AS BLOB))` for the stored side. Do not compare Dart `String.length` (UTF-16 code units) with SQLite `length(TEXT)` (Unicode code points), or astral characters will cause false mismatches.
15. **Small source (total decoded message + tool-event content `<= 64 MiB`):** per-message content SHA-256 and per-tool-event canonical JSON SHA-256 match between Hive and SQLite, in order. This is the default for typical libraries.
16. **Large source (`> 64 MiB` total decoded content):** a deterministic sample of at least `max(500, 1%)` of messages and tool parts matches: string content byte-for-byte, structured content by canonical JSON equality. Store the sample seed in the receipt.
17. In both modes, at least 100 tool contents are compared explicitly, and all quarantine rows have a recorded source key, error, and raw payload hash.

The 64 MiB threshold is a starting constant to be confirmed in M0. Do not skip aggregate count/length checks even when sampling; sampling only replaces the expensive per-row hash pass.

A migration with quarantine rows is **complete with issues**, not clean; record `state='complete_with_issues'`. It may publish only if the user-facing report exposes the quarantine count and export path. A clean migration has zero quarantine rows and records `state='complete_clean'`.

If any non-quarantine check fails, do not publish. Keep Hive intact and show a retry/diagnostics screen.

### 8.6 Receipt

Write a sidecar file, for example `chat_v2.migration.json`, containing:

- format version
- `database_id`
- `publish_id`
- `source` (`hive`, `fresh`, or `reset`)
- source box names
- backup choice (`completed`, `skipped`, or `failed`) and backup artifact name when applicable
- started/completed timestamps
- counts and total UTF-8 payload-byte sums (`content` plus canonical `arguments_json`)
- validation mode (`full` or `sampled`), threshold, sample seed, and content hash summary
- quarantine count and migration `state`
- publication verification result and target schema version
- app version that performed migration

Also write the same key/value pairs to `migration_meta` inside SQLite, including `state` (`complete_clean`/`complete_with_issues`) and `quarantine_count`. Precedence is: `chat_v2.reset`/`chat_v2.legacy_import_disabled` markers first, then readable in-database `migration_meta`, then the sidecar. The sidecar is only a fast-path hint and is ignored when it disagrees. If the sidecar says "complete" but the database has no meta or fails `integrity_check`, treat the state as inconsistent and do not open Hive.

### 8.7 Failure and crash handling

| Failure point | Behavior |
|---|---|
| Hive open/read failure | Abort; keep Hive; show error; no SQLite publish. |
| SQLite write failure | Roll back the current batch; discard the temp DB and retry from Hive. |
| App killed during import | Temp DB may contain a prefix; discard it and restart from Hive. |
| Validation mismatch | Do not publish; keep temp DB for diagnostics; keep Hive. |
| Crash during publish | `chat_v2.publish-intent` plus target/temp/previous are inspected by 8.2.1; recover or fail closed. Never guess and never delete both copies. |
| Split-brain target + temp | Keep both, validate `publish_id`/receipts/previous identity, show diagnostics; do not open Hive or pick one silently. |
| Crash after publish, before receipt | In-database `migration_meta` is authoritative; sidecar can be regenerated. |
| Disk full | Abort before publish; report required free space; keep Hive. |

### 8.8 Legacy retention and deletion

- Never delete Hive chat boxes automatically.
- After successful migration, Hive files are inert legacy data.
- Storage settings must show:
  - SQLite database size
  - WAL size
  - legacy Hive size
  - export action for each legacy box
  - explicit "delete legacy chat files" action with confirmation
  - state of an interrupted or completed legacy cleanup
- Deleting legacy files is a separate destructive action; it must not be part of migration.

#### Preconditions

Before creating a retirement marker:

1. `migration_meta.source='hive'` and `migration_meta.state` is `complete_clean` or `complete_with_issues`, and the SQLite database opens and passes `integrity_check`/`foreign_key_check`. For `complete_with_issues` or a non-zero `quarantine_count`, require a successful legacy export and an explicit warning before cleanup; the one-click path is unavailable. For `source='reset'` or `source='fresh'` with Hive artifacts still present, refuse the normal cleanup path: those artifacts were never imported and may be the only copy. Offer only a separate "discard never-migrated legacy files" action, after a successful export and an explicit warning.
2. No active stream, backup, export, or migration is running. Acquire the maintenance lock for the cleanup.
3. The user has explicitly confirmed deletion, with a warning that full tool history in Hive will be removed.
4. The artifact inventory contains only regular files. Symlinks, directories, and unknown files abort the cleanup.

#### Artifacts

Inventory all chat Hive boxes and their `.lock` companions, never unrelated Hive boxes:

- `conversations.hive`
- `messages.hive`
- `tool_events_v1.hive` (including `sig_` entries)
- `message_file_records_v1.hive`
- `conversation_workspace_bindings_v2.hive`
- `conversation_workspaces_v1.hive`

`message_snapshots_v1.hive` is retired and not part of the migrated chat data. Do not include it silently in this inventory; if the storage UI offers to delete it, label it as a separate retired-snapshot action.

#### Retirement marker

Write `chat_v2.legacy-retirement.json` atomically before the first unlink. It contains:

- format name and version
- `state` (`deleting` or `completed`)
- `requestedAtUtc` and `completedAtUtc`
- `database_id` and migration completion timestamp
- artifacts, each with `name`, `sizeBytes`, `modifiedAtMs`, and an optional `sha256`

`sizeBytes` and `modifiedAtMs` are mandatory. `sha256` is optional for very large files but, when recorded, must be verified before deletion. The marker is fsynced before any file is removed.

#### Deletion algorithm

1. Re-stat every artifact. If a file is already missing, record it as already absent; this is normal when resuming an interrupted cleanup.
2. If `sizeBytes` or `modifiedAtMs` differs from the inventory, abort without deleting that file or any later file. Show a diagnostics error; the user must re-inventory explicitly.
3. If a recorded `sha256` is present, recompute and compare before deleting.
4. Delete one artifact at a time and fsync the parent directory after each unlink.
5. Write the `completed` marker after all artifacts are gone. Keep the receipt; it is the durable record that cleanup finished.

#### Crash and corruption handling

- A `deleting` marker found on the next launch means cleanup was interrupted. Do not auto-delete. Show "legacy cleanup interrupted" and require the user to resume; revalidate every remaining artifact first.
- A malformed marker, a changed file, or an unreadable migration receipt fails closed. Never delete a file whose identity changed after the inventory.
- A `completed` marker hides the delete action and shows the completion timestamp. A missing marker with remaining Hive files is treated as "not yet cleaned", not as permission to delete.
- If the SQLite database is missing, corrupt, or no longer carries a complete migration receipt, refuse cleanup. Hive may be the only remaining copy.

### 8.9 Dual-write and downgrade

- No dual-write. After publish, SQLite is the only writable chat store.
- Hive remains a pre-migration snapshot.
- Downgrading to a build that only reads Hive is not supported after the first SQLite write, because post-migration messages are not in Hive.
- Release notes must warn users to make a backup before upgrading.
- A failed migration can fall back to Hive **before** the first SQLite write; after that, fallback requires an explicit export/restore path.
- Drift `onUpgrade` must be real for every version; never use `onUpgrade: (_, __, ___) async {}`.
- Drift `onDowngrade` must fail closed. If the binary is older than the database schema, show "This database was created by a newer version" and stop; do not delete or recreate the database.

### 8.10 `clearAllData` and reset

`clearAllData` is a destructive user action. It must:

0. Confirm the exclusive maintenance lock is held.
1. Close the database and all streams.
2. Atomically write a `chat_v2.reset` marker **before** deleting anything. The marker means "do not import Hive"; it does not mean "delete any published database".
3. Delete `chat_v2.sqlite`, `-wal`, and `-shm`. This is not atomic; the startup reset path must finish it before creating a new database, including removing stale `-wal`/`-shm`.
4. Delete `chat_v2.sqlite.migrating`, `chat_v2.sqlite.upgrading`, `chat_v2.sqlite.previous`, `chat_v2.sqlite.replaced-*`, their `-wal`/`-shm` files, and `chat_v2.publish-intent.json` if present.
5. Delete `chat_v2.migration.json` and `chat_v2.installation.json`.
6. Leave legacy Hive files untouched unless the user separately chooses "delete legacy chat files" (8.8).
7. If no published database exists, create an empty one with `migration_meta` recording `database_id`, `source='reset'`, and `state='complete_clean'`, then write a fresh `chat_v2.installation.json`. If a published database with `source='reset'` already exists (for example, the app was killed after step 7 created it), keep it and use it; a non-reset database must be deleted before creating the empty one.
8. Atomically write `chat_v2.legacy_import_disabled`. This durable sentinel means "never import Hive again" even if the SQLite database is later lost. Remove it only through an explicit legacy-import action.
9. Remove `chat_v2.reset` and re-run onboarding/settings initialization.

If the app is killed between steps, startup must see `chat_v2.reset` or `chat_v2.legacy_import_disabled`, **not** re-import Hive, and must not wipe a published database created after the reset. Never silently resurrect old Hive chat data. If the user also chooses to delete legacy files, do that only after the reset marker is durable.

---

## 9. Application Integration

### 9.1 Storage abstraction

Introduce:

```
ChatRepository
  - conversations and messages
  - tool parts and provider artifacts
  - file records
  - workspace bindings
  - migration metadata

ChatStorage
  - HiveChatStorage (legacy, read/write until migration)
  - SqliteChatStorage (authoritative after cutover)
```

`ChatService` remains the app-facing `ChangeNotifier` and delegates to the selected `ChatStorage`. This keeps provider wiring, UI notifications, and existing call sites stable.

`Conversation` and `ChatMessage` currently extend `HiveObject`, so callers can invoke `.save()`/`.delete()` directly and bypass `ChatService`. Those calls work only while the Hive box is open. Before cutover, audit every `.save()`/`.delete()` on chat models (including `Conversation.save()` calls inside `ChatService`) and route them through repository methods; add a grep-based checklist item so no direct HiveObject write remains.

### 9.2 Preserve the sync read API with a cache

**Implemented 2026-10-31 (M6 prep):** startup loads conversations and metadata only; `ensureConversationLoaded` loads message bodies plus summaries, `getMessages` fails closed for an unloaded persisted conversation, and `ensureAllMessagesLoaded` is the explicit full-history escape hatch. The opt-in benchmark harness is `test/benchmark/chat_storage_benchmark_test.dart`.

`ChatService.getToolEvents(String)` is synchronous and has many callers. Do not convert every caller to async in the first milestone.

Recommended compatibility strategy:

- Add `Future<void> ensureToolEventsLoaded(Iterable<String> messageIds)`.
- Add `Future<void> ensureConversationLoaded(String conversationId)`.
- `SqliteChatStorage` loads the current conversation's messages and **tool-part summaries** into an in-memory cache. Summaries are a separate immutable view from full tool events; they never carry `content`.
- Add `getToolPartSummaries(messageId)` for timeline/process-group restore. `StreamController.restoreMessageUiState` must use summaries, not `getToolEvents`; using full events there would either throw on a cache miss or load every tool body and defeat lazy detail loading.
- `getToolEvents(messageId)` is the model-replay API and returns full events from the cache if loaded. If not loaded, it must **fail closed** with a typed `ToolEventsNotLoadedException` rather than returning an empty list; an empty list silently changes model history and approval state. Timeline/UI restore uses summaries instead.
- `getMessages(conversationId)` follows the same rule: an unloaded conversation throws rather than returning `[]`. An empty list must mean "loaded and genuinely empty", never "not loaded yet".
- All async entry points that need model replay call `ensureToolEventsLoaded`/`ensureConversationLoaded` before calling a synchronous builder. There is no synchronous retry: `MessageBuilderService.buildApiMessages` and `ChatTurnService.buildApiMessages` cannot await. A throw from them is a contract violation, not a recoverable cache miss; the async caller must preload first. A top-level catch may show an error and trigger an async reload, but must not substitute an empty list.
- A cache that is loaded and has no rows returns an empty list legitimately; only an unknown/unloaded cache throws.
- `Conversation.messageIds` is hydrated from an ID-only query ordered by `ordinal` when conversations are listed; there is no `message_ids_json` cache.
- Preserve draft conversations (`ChatService._draftConversations`) in memory. A draft id is considered loaded, so `getMessages` returns its in-memory messages rather than throwing. `getAllConversations` checks drafts before SQLite; the first save promotes the draft and its messages into SQLite in one transaction.
- Write methods update SQLite and the cache in the same operation.

Callers to audit and update:

- `HomeViewModel` open-conversation path before any `getMessages` call
- `MessageBuilderService.neutralMessagesFor` / `buildApiMessages` (filter tools by `status`, not by `content == null`; pending approval JSON is non-null; emit call/result pairs per 9.5.2)
- `MessageGenerationService.prepareApiMessagesWithInjections`
- `ChatTurnService.buildApiMessages` (same status filter and pairing rules as `MessageBuilderService`)
- `StreamController.restoreMessageUiState` (must use `getToolPartSummaries`, not `getToolEvents`)
- `ChatActions` approval/ask_user/resume paths
- `MessageExportSheet`
- `DataSync` backup/restore/merge
- Importers (`chatbox_importer`, `cherry_importer`)

### 9.3 Read paths

| Read path | Query shape |
|---|---|
| Conversation list | `conversations` ordered by `updated_at DESC`; one ID-only message query grouped in memory to hydrate `Conversation.messageIds`; no message bodies or parts. This is O(total messages) but only IDs; if profiling shows it is too heavy, add a `message_count` projection rather than duplicating the full id list. |
| Open conversation | `messages` for one conversation ordered by `ordinal`; no full tool content. |
| Timeline tool cards | Part summaries: `part_id`, `message_id`, `tool_name`, `tool_call_id`, `approval_state`, `status`, `length(content) AS content_length_chars`, `substr(arguments_json, 1, 256) AS arguments_preview`, `length(arguments_json) AS arguments_length_chars`, `updated_at`. |
| Tool detail expand | One part row by `part_id`, including `content`. |
| Model replay | Full parts for the exact message ids in the API slice, ordered by `ordinal`. |
| Backup/export | Full parts per message, preserving the existing JSON map shape; stream one conversation at a time. |
| Search | Conversation/message indexes; FTS is optional in a later phase. |

SQLite `length(TEXT)` counts Unicode code points, while Dart `String.length` counts UTF-16 code units; they differ for astral characters. Use SQLite `length(TEXT)` only for UI character counts. For storage estimates and cross-language totals use `length(CAST(content AS BLOB))` plus UTF-8 byte counts in Dart, or add a `content_bytes` column if profiling needs it.

Do not load full `arguments_json` for every timeline card: `file_write` arguments can contain an entire file. Show `arguments_preview` by default and load the full arguments together with `content` when the card is expanded. Pending/denied summaries are the exception: include their approval-protocol `content` eagerly because the approval/denial card cannot render from a length alone.

### 9.4 Write paths

| Operation | SQL behavior |
|---|---|
| Add message | Insert message row, assign `max(ordinal)+1`, update conversation `updated_at` in one transaction. |
| Update message | Update only changed columns by message id. |
| Add/update tool event | Find by `(message_id, tool_call_id)` when the id is non-empty; otherwise by `(message_id, tool_name)` for the first `status='pending'` row with null or empty content; if absent, append with `max(part.ordinal)+1` and a status derived with approval priority (`pending` if approval is pending, `denied` if denied, `completed` if approved/answered/auto with content, else `pending`). Update only that row and `status`. |
| Approval state | Update `approval_state`, `status`, and optional `content` on the matching row; a denied approval becomes `status='denied'`. |
| Delete message | Delete the row; cascade parts/artifacts/file records; renumber the conversation and adjust indices (below). |
| Delete conversation | Delete conversation row; cascade messages and all child rows. |
| Fork conversation | Clone messages, `message_parts`, provider artifacts, file records, and workspace binding; assign fresh IDs and ordinals. |
| Toggle truncate/clear context | Set `truncate_index` to the current message count (hide all messages) or `-1` (restore all); no row deletion. |
| Set Gemini signature | Upsert `provider_artifacts(message_id, 'gemini_thought_signature')`. |
| File record | Upsert by `(message_id, path)` with `ordinal`. |
| Workspace config | Upsert/delete `conversation_workspace_bindings`. |

Delete semantics are behaviorally significant:

- `deleteMessage` currently removes one version of a group and moves a remaining version into the removed slot. Implement this in one transaction: delete the row, choose the first remaining message with the same `group_id` (or `id` if `group_id` is null), move it to the removed slot, then renumber all messages in the conversation to `0..n-1`. Because `UNIQUE(conversation_id, ordinal)` is enforced, renumber in two phases (shift by a temporary offset such as `+1000000`, then assign `0..n-1`) or update in an order that cannot collide.
- `truncate_index` and `compact_before_index` are list positions, not raw ordinal values. When a message before either index is deleted, decrement the index; clamp both to the new message count. When all messages are deleted, reset both to `-1`.
- `toggleTruncateAtTail` uses the message count, not `max(ordinal)`; gaps are allowed during a transaction but must be removed before commit.
- `forkConversation` must copy tool parts and provider artifacts. The current Hive implementation clones messages and file records but not tool events; the SQLite implementation must not preserve that gap, and a regression test must pin the new behavior.

### 9.5 UI changes for lazy tool detail

`ToolUIPart` currently carries the full `content` string. To avoid loading all tool bodies:

- Add `contentLoaded`, `contentLength` (or `hasContent`), and `status` to `ToolUIPart`.
- Persisted timeline parts are created from summaries with `content = null`, `contentLoaded = false`, an `arguments_preview`, a length from SQL, and the persisted `status`.
- Exception: `status='pending'` and `status='denied'` parts load their approval-protocol JSON content eagerly and set `contentLoaded=true`, because the approval/denial card needs `resolved_path`, `requested_at`, and the denial message. This is normally small; if a pending diff/arguments payload is large, render a compact card and load the rest on expand. Completed result bodies remain lazy.
- Expanding a tool card calls `ChatService.loadToolEventDetail(messageId, toolCallId)` and updates both full `arguments` and `content`; never load full arguments for every card.
- Live streaming parts still carry full content immediately.
- `process_group` loading logic must not treat a completed but unloaded part as `loading`; use `status`/`approval_state` and `contentLength`. A part with `status='pending'` shows the approval/loading card even if its approval-protocol JSON gives it a non-zero `contentLength`; `status='interrupted'` shows "Interrupted"; `status='denied'` shows "Denied"; a `completed` part with null content is not loading.
- `message_export_sheet` and "copy full output" must call the loader before copying.
- A not-yet-loaded card shows a neutral "Load result" / placeholder, not "No result yet".
- Live streaming parts use the in-memory `isStreaming` flag only; migrated parts never get `loading=true` merely because `content` is null.

**Landed (M4):** timeline parts come from `getToolPartSummaries`; completed bodies are loaded on expand through `ChatService.loadToolEventDetail`. Pending/denied approval JSON is loaded eagerly so the approval card is never blank.

### 9.5.1 Full-content callers

These callers need more than summaries; each must use a bounded query, not "load all parts for all conversations":

| Caller | Strategy |
|---|---|
| Model replay | Load full parts for the exact message IDs in the API slice, in one query. Emit a tool call only for `status='completed'` or `status='denied'` parts that also emit a matching tool result; `denied` carries the model-facing denial JSON. Omit `pending` and `interrupted` as a call/result pair, even when approval-protocol JSON is present. Never emit a call without a result; if no pairs remain, omit the assistant tool-calls block. |
| Compaction / token estimation | Use SQL aggregates (`length(content)`, count) or a bounded window; do not load full bodies. |
| Citations / search result lists (`search_web` JSON) | Parse in the repository and expose typed citation rows, or load only the parts referenced by the visible message. |
| `ask_user` / approval resume | Load the specific pending part by `(message_id, tool_call_id)`; never depend on a whole-conversation cache. |
| Export / backup | Stream one conversation at a time, or one message at a time, into the existing JSON shape. |
| Tool detail UI | One part per expand; cache it in `ToolUIPart` until the message is disposed. |

`MessageExportSheet`, `DataSync`, and importers must not call an unbounded `getAllToolEvents()`. If such an API exists today, replace it with a per-conversation or paginated API as part of the integration milestone.

### 9.5.2 Replay pairing and intentional behavior change

Current behavior in both builders is all-or-nothing: both use `events.any((e) => e['content'] == null)` to omit the whole assistant tool history. They also treat a pending approval-protocol payload as a tool result because its `content` is non-null. The SQLite path deliberately changes both rules.

Required algorithm:

1. Replay only parts with `status='completed'` or `status='denied'`.
2. Omit `status='pending'` and `status='interrupted'` as a **pair**: do not emit the tool call and do not emit a tool result. Never inject **pending** approval-protocol JSON as a result; the `denied` denial JSON is the one approval-protocol shape that is replayed.
3. Every emitted `tool_call` must have exactly one matching `role='tool'` message with the same `tool_call_id` in the same tool-result block. No dangling calls and no orphan results.
4. If a message has no replayable pairs, do not emit a synthetic assistant `tool_calls` message. Its normal text content, if any, still follows.
5. A `denied` part with null content is omitted and logged rather than inventing a denial. A `completed` part with null content is already rejected by the `CHECK(status <> 'completed' OR content IS NOT NULL)`; treat any such row as corruption and fail closed.
6. Attach `reasoning_content`/`reasoning_details` only from events that actually produced a replayed pair. Keep `write_todos` and the retired `workspace_snapshot` excluded.
7. Provider-shaped tests must assert pairing for both builders, including mixed completed+pending, all-pending, and denied+completed histories.

This is a behavior change for the live path: the old `content == null` whole-message skip and the accidental replay of pending approval JSON are not preserved. Record it in release notes and pin it with regression tests.

### 9.6 Startup flow

Add a `ChatStorageGate` before the chat surface:

0. Acquire the **exclusive maintenance lock** at process start, before the gate opens Hive, a temp DB, or the published DB. Release it after the gate when no maintenance is needed; normal SQLite operation does not hold it. Another instance must not validate, publish, or rebuild a temp DB while maintenance is running. The lock is process-wide and re-entrant within its owner; the gate receives the already-held handle, so an upgrade/backup inside the gate does not re-acquire and self-block. If another live process holds the lock, wait with a bounded timeout (for example 30 seconds), show "another window is updating", and offer retry; recover a stale PID lock, but never force-break a live lock. The timeout is a UI retry point, not a claim that migration finishes in 30 seconds; the second instance may wait again or exit without opening the database.
1. Run `DatabaseInstallationGate.ensureReady()` (6.3) before opening a live chat connection or any Hive chat box. It creates, upgrades, or rejects the database and recovers a pending database-family publish. If Hive is present and no database has been published, it returns `needsMigration` instead of creating an empty database. This step never imports Hive.
2. Detect fresh install / Hive-only / migrating / ready. A fresh database is created together with `migration_meta` (`database_id`, `source='fresh'`, `state='complete_clean'`) and `chat_v2.installation.json`; otherwise launch #3 would look like an unreadable database.
3. If migration is needed, wait for any active stream to finish or be stopped; never start migration while a chat completion is running. Before creating the temp DB, show the optional backup choice from 8.2.2 and record `backup=completed|skipped|failed` in the receipt. Then show a blocking progress screen with:
   - current stage
   - conversations/messages processed
   - quarantine count
   - cancel/retry policy (cancel before publish only)
4. On success, open SQLite, preload the last-opened conversation (or show a loading state), and then enter the normal chat UI.
5. On failure, keep Hive available through `HiveChatStorage` for one release and show a retry/diagnostics action.
6. Never let a chat widget call `getMessages`/`getToolEvents` before storage initialization.

`ChatService.init` can remain the entry point, but it must select the storage backend and run both gates before setting `_initialized = true`.

**M5 implementation:** `ChatStorageInitStatus` exposes `preparing → checking → backingUp/migrating/validating → opening → ready|failed`. `ChatStorageStartupOverlay` is mounted above the home surface, blocks input, shows localized stages and destination counts, and keeps a failed start visible with Copy diagnostics + Retry. `ChatService.init()` de-duplicates concurrent callers (one gate per process), and the Retry action re-runs the post-init conversation/share setup. Hive open failures are converted by `HiveOpenBoundary` into one diagnostic (R5). The pre-migration backup choice from step 3 is wired through `ChatStorageGate.backupPrompt`; a skip is explicit, and a failed/cancelled backup leaves Hive authoritative.

### 9.7 Backup, restore, and import

- The optional pre-migration backup in 8.2.2 is a separate disaster-recovery archive containing raw Hive files and a streamed `chats.json`; it is not the normal in-app backup format. It is implemented by `PreMigrationBackupService` and offered before the temp DB is created.
- Keep the existing backup JSON shape:
  - `conversations` (with `messageIds` hydrated before export)
  - `messages`
  - `toolEvents` map keyed by assistant message id
  - `geminiThoughtSigs`
  - `fileRecords`
  - `workspaces`
- `DataSync` reads from the repository and writes the same shape.
- Restore inserts conversations/messages/parts/artifacts in transactions.
- Importers continue to call `ChatService` facade methods.
- Do not silently overwrite existing events; preserve the current "only fill empty" merge semantics unless a separate decision changes it.
- For large backups, use streaming JSON writing or a database snapshot; do not build a second full in-memory copy if avoidable. **M5:** `DataSync` streams the v3 chats JSON into a temp file, adds it to the zip with awaited `addFile`, and uploads WebDAV with `StreamedRequest` + Content-Length. Only `settings.json` and small workspace/signature maps are assembled in memory.
- `clearAllData` must follow section 8.10; it is not a backup/restore path.

### 9.8 Storage settings

Add a "Chat storage" section:

- database size and WAL size
- message/part counts
- legacy Hive file sizes
- "legacy import disabled" indicator when `chat_v2.legacy_import_disabled` exists
- export legacy Hive files
- explicit "import legacy Hive" action (confirmation; removes `chat_v2.legacy_import_disabled` only after a validated import)
- delete legacy Hive files (explicit confirmation; marker-backed, size-validated flow in 8.8)
- interrupted legacy cleanup status with an explicit resume action
- optional "optimize database" (`VACUUM`) after large deletions; never automatic. `VACUUM` needs roughly the database size in free space and blocks writers; require an idle app, no active stream, a maintenance lock, and a free-space check.

**M4 implementation:** the page is `ChatStoragePage` (settings → storage → chat storage). It shows the SQLite/WAL sizes, counts, schema/source/state, legacy artifacts, export/delete/resume, and a backend-gated optimize action. The page performs only the shallow database probe; the integrity/foreign-key check runs once in `delete`. Export and delete share the maintenance lock. A durable `chat_v2.legacy-export.json` receipt is required for `complete_with_issues`/quarantine and never-imported files, and delete re-hashes the source to compare with that receipt. **M5** adds the explicit "import legacy Hive" action: `LegacyReimportService` imports the snapshot into a disposable staging database first, then merges by stable id into the live SQLite store. Existing conversations/messages are never overwritten; missing rows are appended and existing rows only receive missing parts/artifacts/records. A message id that already exists with different content (or in another conversation) is counted/logged as a conflict and the existing row wins; the merge verifies that every source message is in its target conversation plus the imported part/signature/file-record/workspace rows before committing. The action requires an idle store (no `is_streaming` rows) and serializes concurrent callers. The `legacy_import_disabled` sentinel is removed only after the merge and verification succeed.

---

## 10. Performance Plan

### 10.1 Principles

- Do not load tool content for the chat list.
- Do not load full tool content for collapsed timeline cards.
- Do not query parts in a loop; use batch `IN` queries chunked below SQLite's variable limit.
- Do not rewrite a conversation document for one tool update.
- Keep the database on a background isolate.

### 10.2 Provisional targets

These targets are provisional. M0 must replace them with values measured from the real per-box distribution recorded by `StorageUsageService`, not from a synthetic 250 MB assumption:

| Metric | Target |
|---|---|
| Startup chat list | No chat Hive box open (especially `tool_events_v1`); conversation metadata query only |
| Open a 1,000-message conversation | First screen without full tool bodies; target < 300 ms on reference desktop |
| Tool result upsert (1 MB content) | p95 < 50 ms on local SSD; one row write |
| Tool detail expand | < 100 ms for a 1 MB part on local SSD |
| Migration (250 MB / ~16k events) | < 5 minutes on reference desktop; progress visible; memory bounded by batch size |
| Resident memory after opening one large conversation | Does not include all historical tool bodies |

### 10.3 Indexes

The schema includes indexes for:

- conversation list (`updated_at`)
- assistant conversation list (`assistant_id, updated_at`)
- message order (`conversation_id, ordinal`)
- version grouping (`conversation_id, group_id, version`)
- stale streaming repair (`is_streaming`)
- tool order (`message_id, ordinal`)
- tool call lookup (`message_id, tool_call_id`)
- tool name fallback (`message_id, tool_name, ordinal`)
- file record order (`message_id, ordinal`)

Add further indexes only after query plans show a need.

---

## 11. Reliability and Security

- Use transactions for every multi-row mutation.
- Keep foreign keys enabled on every connection.
- Run `PRAGMA integrity_check` after migration and in diagnostics.
- Handle SQLite busy/locked errors with bounded retry and a clear user message.
- Use the exclusive maintenance lock for pre-migration backup, migration, schema upgrade, publish, `clearAllData`, reset, and legacy retirement. Normal writes use WAL + `busy_timeout` and surface `SQLITE_BUSY` without corruption.
- Publish only through the database-family helper in 8.2.1; never rename a single database file while WAL/SHM or a previous family can be present.
- Run `DatabaseInstallationGate` before any live connection; unknown, newer, or missing-with-receipt schemas fail closed.
- Legacy deletion is marker-backed and size-validated; never delete a file whose identity changed after the inventory.
- Check free disk space before migration. The temp database, final database, WAL, and quarantine can coexist; require at least **2× the live Hive data size + 20%** free space, and fail early with the required amount if it is unavailable.
- Store the database in the app-private data directory. Do not place it in a user-visible Documents folder unless the existing platform policy already does so.
- Do not log tool content, file contents, API keys, or signatures during migration. Log ids, counts, sizes, and hashes only.
- Encryption at rest is out of scope; the SQLite file has the same local trust boundary as Hive. If encryption is required, evaluate SQLCipher separately.
- Backup files and exports contain full tool content; preserve the existing user-facing warning and access controls.

---

## 12. Rollout Plan

### M0: Storage spike and decision confirmation

- Capture the real per-box distribution first. `StorageUsageService.computeReport()` already reports `messages`, `conversations`, and `tool_events_v1` sizes; use a copy of real data to record counts, file sizes, and largest events before setting targets.
- Add Drift, `sqlite3_flutter_libs`, and the Drift generator in a branch.
- Copy a real app-data directory to a temporary location.
- Implement a throwaway importer for conversations/messages/tool events.
- Measure:
  - migration time and memory, including a killed-and-restarted run
  - full-hash validation cost; confirm the 64 MiB full/sampled threshold
  - pre-migration backup time, archive size, and verification cost
  - database-family publish/recovery on Windows and Android, including a forced kill between target-preserved and published
  - publish-intent SHA-256 cost on the real database; if it dominates, replace it with a bounded prefix hash plus size/schema/database id
  - startup time with SQLite vs eager Hive
  - tool upsert latency
  - DB size vs Hive size
  - Windows/Android packaging requirements (release targets only)
- Exercise the installation gate against fresh, 0-byte, older published, unknown, newer, and missing-with-receipt databases.
- Confirm Drift and the schema decisions.

### M1: Schema and repository

- Add `AppDatabase`, tables, DAOs, generated code.
- Add `currentSchemaVersion`, `publishedSchemaVersions`, and the installation-gate admission checks.
- Implement `ChatRepository` unit tests:
  - message CRUD/order and `messageIds` hydration
  - tool part upsert/approval/order/status
  - signature upsert
  - file records
  - workspace bindings
  - cascade delete
  - version-group delete and index clamping
  - fork cloning
  - stale streaming repair
- No UI switch yet.

### M2: Hive importer and migration gate

- Implement `LegacyHiveImporter` with batches, disposable temp DB, and receipt.
- Implement validation, quarantine, and `complete_clean`/`complete_with_issues` states.
- Implement the database-family publish helper and publish-intent recovery.
- Implement the optional pre-migration backup flow and manifest verification.
- Add synthetic migration tests and interrupted-migration tests.
- Add `DatabaseInstallationGate`, `ChatStorageGate`, progress UI, reset-marker handling, and the exclusive maintenance lock.
- Test with a copy of real data.

### M3: `ChatService` facade switch

- Add `ChatStorage` implementations.
- Keep synchronous read API via cache and `ensure...Loaded` methods; no synchronous retry for a cache miss.
- Audit and replace every `Conversation`/`ChatMessage` `.save()`/`.delete()` HiveObject call with a repository method.
- Switch write paths to SQLite.
- Implement status-based replay pairing in both `MessageBuilderService` and `ChatTurnService` (9.5.2); assert there are no dangling tool calls.
- Keep Hive implementation available as a fallback for one release.
- Add feature flag / dart-define for internal testing.

### M4: Lazy tool detail and backup/export

**Status: landed 2026-10-31.**

- [x] Add part summaries and lazy content loading.
- [x] Update process group/tool cards/export.
- [x] Adapt `DataSync`, importers, storage settings (streaming JSON/snapshot export remains M5).
- [x] Add marker-backed legacy retirement with size/mtime/SHA-256 validation and interrupted-cleanup resume.
- [x] Add regression tests for tool replay and approvals.

Implementation notes:

- `ChatRepository.getToolPartSummaries` returns timeline parts without completed bodies; `ToolUIPart.contentLoaded` distinguishes a summary from a loaded result.
- `ChatService.loadToolEventDetail` loads one part; `ChatMessageWidget` loads on expand; process-group loading uses `status`/`approval_state`, not `content == null`.
- `message_export_sheet` preloads the message before copying; `DataSync` preloads before a full export.
- `LegacyRetirementService` writes a durable export receipt (`chat_v2.legacy-export.json`) only after copy verification. A later delete requires that receipt when the migration had issues or the Hive files were never imported; every unlink revalidates size/mtime/SHA-256 and resumes from a `deleting` marker.
- `ChatStoragePage` exposes database/WAL sizes, counts, legacy files, export/delete/resume, and an explicit `VACUUM`.

### M5: Platform hardening and release

**Status: in progress 2026-10-31.**

- [x] Blocking startup/migration progress UI with stage labels, destination counts, quarantine count, failure diagnostics, copy, and retry (§9.6 step 3).
- [x] R5: settle Hive's unhandled open-completer error at the legacy import/fallback boundary with one actionable diagnostic.
- [x] Pre-migration backup archive and manifest verification (§8.2.2): raw Hive + streamed `chats.json` + manifest, SHA-256, atomic rename, and startup prompt.
- [x] Bounded/streaming `DataSync` archive export (§9.7): `chats.json` is written to a temp file incrementally, zip entries are awaited, and WebDAV uses a streamed PUT with Content-Length.
- Windows MSIX/Inno: `sqlite3.dll` is verified in the local release bundle; CI and `install_msix.ps1` now fail if it is missing. A real MSIX/Inno install smoke test is still pending.
- Release scope: **Windows and Android only.** macOS/Linux/iOS are not release targets and are not part of M5/M6 acceptance until they are shipped.
- Android: ABI coverage; upgrade from previous version; low-storage behavior. **Foreground migration:** `ChatService` exposes start/finish lifecycle callbacks only for real backup/import work; `HomePage` temporarily enables the existing data-sync foreground service with a localized notification, serializes start/stop, and restores the user's background setting after success, failure, or retry.
- Windows: MSIX/Inno upgrade, SQLite DLL load, second-instance behavior, Application Support write/delete permissions.
- Run crash/kill tests at each migration stage on Windows and Android, including database-family publish and legacy-cleanup deletion.
- Verify `.previous` recovery and publish-intent diagnostics on Windows and Android.
- Release notes: first launch may migrate; full history is preserved; backup is recommended; downgrade is unsupported.

### M6: Remove Hive chat hot path

After at least one stable Windows + Android release with the Hive fallback, and after the Windows/Android smoke + crash/kill gates pass:

- Remove Hive chat reads/writes from `ChatService`.
- Keep legacy export code and migration receipt.
- Remove obsolete Hive adapters/boxes only after a separate decision and after users have had an export path.

---

## 13. Testing Strategy

### 13.1 Unit tests

- Drift schema creation and DAO queries.
- Message order and version group queries.
- Tool part insert/update/order.
- Approval state transitions.
- Signature upsert/delete.
- File record upsert/order.
- Workspace binding upsert.
- Cascade delete for conversation/message.
- Stale streaming repair.
- Delete a versioned message: replacement moves into the removed slot, ordinals are contiguous, and `truncate_index`/`compact_before_index` are adjusted.
- Fork a conversation: messages, tool parts, provider artifacts, file records, and workspace binding are cloned with fresh IDs.
- `getToolEvents` and `getMessages` fail closed when the cache is not loaded; an empty loaded cache still returns `[]`.
- Empty-id tool upsert does not reuse an `interrupted`/`denied` row.
- Placeholder created without an id, then updated by an id-aware result, stays one row and keeps/upgrades the id correctly.
- `clearAllData` removes the DB/WAL/SHM/temp/sidecar, leaves Hive untouched, and a restart does not re-import the old Hive data.

### 13.2 Migration tests

Use temporary directories and real Hive boxes:

- fresh install writes `source='fresh'` meta and survives a second launch
- empty Hive
- one conversation/one message
- many conversations/messages
- large tool content (1 MB, 10 MB)
- non-string raw content (defensive legacy path; low priority)
- pending approval with approval-protocol JSON content → `status='pending'`, not `completed`
- denied approval with denial JSON content → `status='denied'`, not `completed`
- `content = null` + pending approval → `status='pending'`
- `content = null` + denied approval → `status='denied'`
- `content = null` + approved/answered approval → `status='interrupted'` (pinned semantic)
- `content` + answered approval → `status='completed'`
- `content = null` + no pending/terminal approval → `status='interrupted'`
- empty string content + auto approval → `status='completed'`
- a `completed` row with null content is rejected by the table check
- `file_read` bounded content is preserved as stored
- empty/duplicate tool ids
- duplicate tool names
- pending approval
- `ask_user` pending/answered
- unknown event extras
- Gemini signatures
- file records
- workspace v1/v2 bindings
- orphan messages
- orphan tool events
- message conversation-id mismatch
- kill during import at several points; temp DB is discarded and the next run starts from Hive
- large source uses sampled validation; aggregate counts/UTF-8 payload-byte sums still match and the seed reproduces the sample
- validation failure
- disk-full simulation where practical
- repeated migration after success is a no-op
- published DB + stale temp DB: published wins and temp is removed
- sidecar says complete but DB meta is missing/corrupt: must fail closed, not open Hive
- `messageIds` hydration order matches source after missing references are skipped
- fork after migration preserves tool parts
- reset marker + existing post-reset DB: restart uses the DB and does not wipe it
- after reset, delete the SQLite DB and restart: the durable sentinel prevents Hive re-import
- Drift schema upgrade from the previous schema fixture, including a forced failure and backup restore
- installation gate: 0-byte file without receipt and no Hive creates fresh; 0-byte file without receipt but Hive present starts migration; 0-byte file with receipt fails closed
- installation gate: missing database with `chat_v2.installation.json` fails closed; reset marker defers to 8.10
- installation gate: `chat_v2.legacy_import_disabled` + Hive + no database never reports `needsMigration` and creates `source='reset'`
- installation gate: older published schema upgrades through `.upgrading`, updates `installed_schema_version`, and publishes via 8.2.1 with intent recovery; unknown/newer/unpublished schema fails closed without deletion
- publish intent: crash after `prepared`, after `target-preserved` but before moving the target, after rename, and before intent cleanup; each state recovers or fails closed
- publish intent: `prepared` with a corrupt temp and an intact target; target is kept and the bad temp is discarded
- publish intent: `target-preserved` with the target still present and a valid temp; target is moved to `.previous`/`.replaced-<id>` and the temp is published
- publish split-brain: stage `published`/`verified` without the intent `publish_id` in the target, or a target matching neither `publish_id` nor the recorded previous; both are preserved and diagnostics are shown
- publish identity: a temp database id or target `publish_id` that does not match the intent is not published and is kept for diagnostics
- publish with stale `.previous`: target wins only after verification; a previous whose database id/schema/size/hash does not match the intent is not restored or opened as live data
- pre-migration backup: completed, skipped, failed, and archive manifest/hash verification; restore from the backup in a temp directory
- legacy retirement: interrupted `deleting` marker, already-missing file, changed size/mtime abort, malformed marker, incomplete migration refusal, `complete_with_issues`/quarantine export requirement, reset/fresh source refusal, and completed marker

### 13.3 Regression tests

Keep or extend:

- `test/chat_service_file_record_test.dart`
- `test/approval_lifecycle_test.dart`
- `test/message_builder_replay_tool_test.dart`
- `test/replay_tool_results_api_test.dart`
- `test/chat_turn_service_test.dart`
- `test/compaction/*`
- `test/web_fetch_registry_test.dart`
- replay pairing in both builders: pending approval-protocol JSON never becomes a tool result; mixed completed+pending emits only the completed pair; all-pending emits no assistant `tool_calls`; denied+completed history stays paired; no dangling `tool_call_id`
- backup/import tests
- tool card/process group widget tests, including summary-only restore and lazy detail expand

### 13.4 Platform tests (Windows + Android release scope)

Only Windows and Android are release targets. macOS/Linux/iOS builds are not required for M5/M6 acceptance; if they become release targets later, apply this same matrix before shipping them.

- Fresh install on Windows and Android.
- Upgrade from a Hive-backed build.
- Backup/restore after migration.
- Delete conversation/message and verify cascade.
- Open a legacy conversation and inspect a full tool result.
- Run with a read-only or full disk.
- Force-kill during migration and restart.
- Force-kill during database-family publish (after `prepared`, after `target-preserved` but before moving the target, after rename, before intent cleanup) and verify recovery/fail-closed behavior.
- Corrupt the temp while leaving the target intact at `prepared` stage; verify the target is kept and the bad temp is discarded.
- Leave the target present at `target-preserved` stage with a valid temp; verify the target move and publish complete.
- Force-kill during legacy cleanup and verify the `deleting` marker prevents blind deletion of changed files.
- Complete and skip the pre-migration backup on desktop and mobile save paths; verify the archive on a separate restore attempt.
- Windows: launch a second instance during migration; it must not validate/publish/rebuild. It bounded-waits, shows the "another window is updating" retry UI, and never force-breaks a live lock; same-process gate re-acquisition must reuse the held handle and not self-block. Normal SQLite writes on a second instance handle `SQLITE_BUSY` without corruption after a current database is published. Android is single-process in normal use; still verify a repeated gate acquisition in-process does not self-block.
- Kill after reset DB creation but before marker removal; restart must keep post-reset data.
- Windows packaged build (MSIX/Inno) with SQLite DLL.
- Android packaged APK/AAB with the released ABI(s).

### 13.5 Performance tests

- Synthetic 250 MB / 16k tool events.
- Cold start with SQLite ready.
- Open a large conversation.
- Upsert 1 KB, 100 KB, 1 MB, 10 MB tool result.
- Expand a tool detail.
- Backup/export of a large conversation.
- Record results in the migration report on at least one Windows machine and one Android device. macOS/Linux/iOS benchmarks are out of scope for the current release.

**Opt-in harness:** `test/benchmark/chat_storage_benchmark_test.dart`. It is skipped in the normal suite and prints one `CHAT_STORAGE_BENCHMARK {...}` JSON line:

```bash
flutter test test/benchmark/chat_storage_benchmark_test.dart \
  --dart-define=RUN_CHAT_STORAGE_BENCHMARK=true \
  --dart-define=BENCH_SCALE=2 \
  --dart-define=BENCH_PAYLOAD_BYTES=25600 \
  -r expanded
```

**Recorded baseline (Windows development machine, 2026-10-31):** 100 conversations, 20,000 messages, 10,000 tool events, 25,600-byte payload (~256 MB logical content): seed 13,735 ms, cold start **809 ms before lazy message loading / 643 ms after**, RSS after cold start **319,520,768 bytes before / 259,284,992 bytes after**, load conversation 20 ms, load tool detail 1 ms, median upsert 1 KB 1 ms / 100 KB 1 ms / 1 MB 9 ms / 10 MB 171 ms after lazy loading. This is a comparison baseline, not an acceptance result; Android is still required.

---

## 14. Acceptance Criteria

A release is acceptable only when all of the following are true:

1. A clean Hive migration completes with zero quarantine rows; if quarantine rows exist, every source record is either migrated or recorded in `legacy_quarantine` with a report, and the result is explicitly labeled complete-with-issues rather than clean.
2. Full content is preserved in order: when total decoded message + tool-event content is `<= 64 MiB`, every event is validated by canonical hash; larger sources validate aggregate counts and **UTF-8 payload-byte sums** (`content` plus canonical `arguments_json`) plus a deterministic sample (at least `max(500, 1%)`), with string content byte-for-byte and structured content by canonical JSON equality.
3. The SQLite database passes `integrity_check` and `foreign_key_check`.
4. After migration, startup does not open any chat Hive box: `conversations`, `messages`, `tool_events_v1`, `message_file_records_v1`, or workspace binding boxes.
5. Tool event updates write one `message_parts` row, not a whole conversation/document.
6. Conversation and message deletion cascade to all child rows.
7. Opening a conversation renders tool cards from summaries without loading full content; full tool content and full tool arguments remain viewable after detail expand and after reopening the conversation.
8. A pending approval, a denied approval, and an answered `ask_user` survive migration and resume/render correctly.
9. Gemini thought signatures survive migration and are used for the next request.
10. Backup/restore round-trips the full data.
11. A forced kill during migration does not lose Hive data; the temp DB is discarded and the next run restarts from Hive.
12. Failure before publish leaves the app able to run on Hive.
13. `Conversation.messageIds` order matches the source, and deleting a message keeps version groups stable and indices clamped.
14. Forking a conversation preserves messages, tool parts, artifacts, file records, and workspace binding.
15. `clearAllData` removes SQLite artifacts without deleting Hive legacy files; a restart with Hive present, and even a later loss of the SQLite database, does not resurrect old chat data because `chat_v2.legacy_import_disabled` is durable.
16. `getToolEvents`/`getMessages` never return a silent empty list for an unloaded cache; the typed error is handled by the caller, and no synchronous builder retries.
17. No direct `Conversation`/`ChatMessage` HiveObject `.save()`/`.delete()` remains on a chat path.
18. A second app instance cannot run migration, schema upgrade, publish, `clearAllData`, reset, or legacy retirement concurrently; the maintenance lock is acquired first. Normal concurrent SQLite writes surface `SQLITE_BUSY` without corruption.
19. A fresh install writes `migration_meta` (`source='fresh'`) and remains ready on the second launch.
20. Windows and Android smoke tests pass, including Windows MSIX/Inno SQLite DLL loading and the released Android ABI(s). macOS/Linux/iOS are not release targets for this gate.
21. The targeted existing test suite and the new migration suite pass.
22. The migration report contains counts, hashes, quarantine issues, timing, free-space requirements, and the backup choice (`completed`, `skipped`, or `failed`).
23. Database publication uses the family helper: temp WAL/SHM are gone before publish, a publish-intent file with `publish_id` is durable before target mutation, the target is verified by `publish_id`, `.previous` is preserved until one successful start, and every crash state either recovers or fails closed without deleting both copies.
24. `DatabaseInstallationGate` creates only on a genuine fresh install or an explicit reset, upgrades only published older schemas, and fails closed on unknown/newer/unreadable schemas or a missing database with an installation receipt. The live connection never runs migrations.
25. A pre-migration backup is offered before the temp database is created. If completed, its manifest and artifact hashes verify; if skipped or failed, the receipt records the choice and Hive remains untouched.
26. Legacy cleanup is refused unless migration is complete and the database is healthy; `complete_with_issues`/quarantine requires a successful export, and reset/fresh sources are refused. It writes a durable `deleting` marker before the first unlink, verifies size/mtime (and optional SHA-256) before each delete, resumes only after revalidation, and writes a `completed` marker.
27. Both replay builders emit no dangling tool calls: `pending`/`interrupted` parts are omitted as a call/result pair, pending approval-protocol JSON is never sent as a tool result (the denied denial JSON is the intended result), and `completed`/`denied` pairs are preserved for every emitted call.

---

## 15. Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Migration bug loses data | Critical | Copy-then-swap; Hive untouched; count/hash validation; quarantine; real-data dry run. |
| Database-family publish splits target/temp/previous | Critical | Publish-intent marker; preserve `.previous`; fsync file and parent; verify target; split-brain diagnostics; kill tests at every stage. |
| Installation gate opens an unknown/newer schema or silently recreates a missing DB | Critical | `publishedSchemaVersions`; direct header/`user_version` inspection; live connection rejects non-current; missing DB with installation receipt fails closed; no implicit `onUpgrade`. |
| Pre-migration backup is skipped or silently fails | Medium | Recommended UI step; explicit skip confirmation; record `completed`/`skipped`/`failed`; Hive retained; no claim that backup exists unless verified. |
| Legacy cleanup deletes a changed/wrong file or runs after an incomplete migration | High | Preconditions require a healthy complete migration; `complete_with_issues`/quarantine requires export; reset/fresh sources are refused; marker before unlink; size/mtime (and optional SHA-256) validation; fail closed on change; no auto-resume. |
| App killed mid-migration | High | Hive untouched; discard temp DB; restart from scratch; startup state machine; measure restart cost in M0. |
| SQLite native packaging fails on Windows | High | `sqlite3_flutter_libs`; verify DLL in MSIX/Inno; clean-install test; CI packaging. |
| Hive typed adapter cannot decode old record | High | Lazy read; raw fallback/quarantine; fail closed if raw unavailable. |
| Async repository breaks sync UI callers | High | Facade + per-conversation cache; `ensure...Loaded`; audit all call sites; tests. A cache miss must throw, never return `[]`; synchronous builders cannot retry. |
| Direct `HiveObject.save()/delete()` bypasses facade | High | Grep-based audit; replace all chat-model direct writes with repository calls before cutover. |
| Concurrent instance during maintenance | High | Exclusive mutex/lock file with stale-PID handling for migration/publish/clear/reset; normal writes rely on WAL + busy_timeout and surface `SQLITE_BUSY`. |
| Reset marker wipes post-reset data or Hive resurrects | High | Marker only suppresses import; keep a `source='reset'` DB, write durable `chat_v2.legacy_import_disabled`, and delete stale WAL/SHM before creating the new DB. |
| Future Drift upgrade fails midway | High | Pre-upgrade backup; per-version transaction; `user_version`/integrity checks; schema fixtures in CI. |
| Fresh install has no `migration_meta` | High | Create the DB and write `source='fresh'`, `state='complete_clean'` in one transaction. |
| `status` placeholder defaults to completed | Medium | Default `pending`; `CHECK(status <> 'completed' OR content IS NOT NULL)`; insert placeholders explicitly. |
| Empty-id fallback hijacks an interrupted card | Medium | Match only `status='pending'` rows; append a new part for interrupted/denied rows. |
| Loading all parts for a huge conversation still slow | Medium | Part summaries; lazy content; batch queries; pagination if needed. |
| Duplicate/empty tool ids | Medium | No unique constraint in v1; first-match behavior; log duplicates; preserve raw ids. |
| Approval/ask_user state lost | High | Dedicated columns and migration tests; never quarantine a decodable pending event. |
| Replay emits a call without a result or leaks pending approval JSON | High | Status-based per-part filter; omit pending/interrupted as a pair; assert call/result ids for both builders; provider-shaped regression tests; replay denied denial JSON intentionally. |
| Backup format drift | Medium | Keep existing JSON shape; round-trip tests; version the backup if changed. |
| `INSERT OR REPLACE` cascades on re-import | High | Use `ON CONFLICT DO UPDATE`; never replace parent rows; test a killed-and-restarted import. |
| Delete renumber hits unique constraint | Medium | Two-phase ordinal shift inside a transaction; test versioned-message deletion. |
| Truncate boundary off-by-one | High | Treat `truncate_index` as a zero-based start index; validate range; migration test with `-1`, `0`, `length-1`, and `length`. |
| Downgrade loses new messages | Medium | Release-note warning; keep Hive snapshot; no silent downgrade; export path. |
| DB file grows indefinitely | Expected | Full history is retained by design; this plan does not promise size reduction. Add separate retention/archive policy only with explicit user consent. |
| SQLite lock/busy under backup/export | Medium | WAL, busy timeout, serialized maintenance, checkpoint before backup. |
| Existing `file_read` 8 KB persisted preview remains | Product decision | Migration preserves stored bytes; removing the cap is a separate change with its own storage impact. |

---

## 16. Open Decisions

| Topic | Recommended default |
|---|---|
| Web support | Out of scope for this migration; add a separate Drift-web/IndexedDB plan if web is a supported target. |
| Text/reasoning parts | Phase 2 after tool-part migration stabilizes; keep message columns as compatibility projections. |
| Dual-write | No. Use Hive fallback only before the first SQLite write. |
| Hive deletion | Never automatic; explicit storage-settings action after export and the 8.8 marker/size gate. |
| `file_read` 8 KB persistence cap | Preserve existing behavior during migration; decide separately whether full file reads are required. |
| Encryption at rest | Out of scope; evaluate SQLCipher separately if the threat model changes. |
| Backup format | Keep JSON v3 shape; optionally add a SQLite snapshot format later. |
| Pre-migration backup | Recommended, skippable with explicit confirmation; record `completed`/`skipped`/`failed`; the archive is raw Hive + JSON, not the normal backup. |
| Migration UI | Blocking progress screen; no chat interaction until the database is published. |

---

## 17. Relevant Files

Paths are relative to the OmniChat repository root.

### Models and current storage

- `lib/core/models/chat_message.dart` — Hive message model; source fields for `messages`.
- `lib/core/models/conversation.dart` — Hive conversation model; source fields for `conversations`.
- `lib/core/models/file_record.dart` — file record shape.
- `lib/core/models/workspace_config.dart` — workspace binding JSON.
- `lib/core/services/chat/chat_service.dart` — current Hive boxes, cache, CRUD, tool events, signatures, file records, workspace bindings.
- `lib/core/services/storage/storage_usage_service.dart` — existing per-box size report (`messages`, `conversations`, `tool_events_v1`); use it for the M0 real-data baseline.
- `lib/core/models/chat_message.g.dart` and `lib/core/models/conversation.g.dart` — generated Hive adapters (do not edit manually).

### Chat behavior and API assembly

- `lib/features/home/services/message_builder_service.dart` — tool replay, message assembly, compaction projection.
- `lib/features/home/services/message_generation_service.dart` — generation prep; ensure tool events are loaded before `buildApiMessages`.
- `lib/core/services/chat/chat_turn_service.dart` — second API message builder/turn path.
- `lib/features/home/controllers/stream_controller.dart` — live tool parts, restore, approval/ask_user state.
- `lib/features/home/controllers/chat_actions.dart` — approval/ask_user resume, tool event updates.
- `lib/features/home/services/tool_handler_service.dart` — tool execution and pre-result upserts.
- `lib/features/home/controllers/home_page_controller.dart` — `initChat` / startup flow.
- `lib/main.dart` — app bootstrap and storage gate placement.

### UI

- `lib/features/chat/widgets/chat_message_widget.dart` — `ToolUIPart`, tool card/detail rendering, citations.
- `lib/features/chat/widgets/process_group_card.dart` — process group rendering and timer state.
- `lib/features/chat/widgets/process_group_logic.dart` — grouping/loading logic.
- `lib/features/chat/widgets/message_export_sheet.dart` — export uses tool events.
- `lib/features/settings/pages/storage_space_page.dart` — legacy Hive export/delete UI.

### Backup and import

- `lib/core/services/backup/data_sync.dart` — backup/restore/merge of tool events, signatures, file records, workspaces.
- `lib/core/services/backup/chatbox_importer.dart`
- `lib/core/services/backup/cherry_importer.dart`

### Tests to extend

- `test/chat_service_file_record_test.dart`
- `test/approval_lifecycle_test.dart`
- `test/message_builder_replay_tool_test.dart`
- `test/replay_tool_results_api_test.dart`
- `test/chat_turn_service_test.dart`
- `test/compaction/*`
- `test/process_group_card_test.dart`
- `test/stream_controller_stale_tool_loading_test.dart`
- `test/web_fetch_registry_test.dart`
- `test/data_sync_local_only_keys_test.dart`

### Build and dependencies

- `pubspec.yaml` — add `drift`, `sqlite3_flutter_libs`, and the Drift dev generator.
- `build.yaml` — Drift code generation configuration if needed.
- `lib/core/services/file/file_tool_service.dart` — existing atomic-replace pattern to reuse or extract.
- `tool/windows_rename_spike.dart` — Windows `File.rename` replace validation.
- `windows/`, `android/`, `macos/`, `ios/`, `linux/` — packaging and native SQLite validation.

---

## 18. Implementation Notes (2026-10-31)

### 18.1 What landed

Milestones M1–M3 of §12 are implemented. M1–M2 built the storage core; M3
switched the live `ChatService` facade to the gate-selected backend, so the app
now reads/writes SQLite when admission succeeds and keeps Hive as the
one-release fallback. The storage code lives in
`lib/core/services/chat/storage/`; the replay helper lives in
`lib/core/services/chat/tool_replay.dart`.

| Area | Implementation |
|---|---|
| Schema v1 | `app_database.dart` + generated `app_database.g.dart`; `currentSchemaVersion = 1`; `publishedSchemaVersions = {1}`; WAL/foreign keys/busy timeout/synchronous PRAGMAs; live connections reject any other `user_version` and never migrate implicitly. Schema snapshot: `drift_schemas/drift_schema_v1.json`. |
| Repository | `chat_repository.dart`: conversation/message CRUD, messageIds hydration from `ordinal`, part upsert by id then pending same-name placeholder (never reuses interrupted/denied), approval transitions, part summaries without completed bodies, lazy detail load, signatures, file records, workspace bindings, fork with parts/artifacts/records/binding, two-phase message renumber, index clamping, cascade deletes, stale-streaming repair, migration meta/quarantine. |
| Part codec | `message_part_codec.dart`: approval normalization (`auto|pending|approved|denied|answered`), legacy/runtime status derivations, canonical JSON, unmapped-key metadata preservation, legacy event round-trip. |
| Installation gate | `database_installation_gate.dart`: fresh/0-byte/older/newer/unpublished/missing-with-receipt admission, reset marker completion, `chat_v2.legacy_import_disabled` sentinel, sidecar repair and identity checks, fail-closed diagnostics. |
| Family publish | `database_family_publisher.dart`: durable `publish-intent.json`, `.previous` preservation, `.replaced-<id>` fallback, `publish-id` verification, split-brain fail-closed recovery for the §8.2.1 crash table. |
| Hive importer | `legacy_hive_importer.dart`: lazy boxes (`crashRecovery: false`), copy-then-swap temp DB, conversation batching, orphan/recovered conversations, quarantine with payload hash, count + UTF-8 byte-sum + full/sampled hash validation, in-database meta and sidecar receipt, atomic publish. |
| Lock + orchestration | `chat_maintenance_lock.dart` (re-entrant process guard, file lock with stale-PID recovery, bounded wait) and `chat_storage_gate.dart` (admission -> migration -> re-admission, Hive fallback on failure). |
| Facade (M3/M6-prep) | `chat_storage.dart` contract, `hive_chat_storage.dart` legacy backend, `sqlite_chat_storage.dart` cache backend; `ChatService` is now a delegating `ChangeNotifier`. SQLite loads conversation metadata (including ID-only `messageIds`), file records, workspace bindings, and signatures at startup; message bodies and tool parts load per conversation. `getMessages`/`getToolEvents` fail closed with `ChatStorageNotLoadedException`; `ensureAllMessagesLoaded` is explicit for backup/import/stats. Drafts stay in the facade and are promoted on the first message. |
| Startup wiring | `ChatService.init()` runs `ChatStorageGate` and selects SQLite on `ready`/`migrated`; `failed` falls back to Hive. `needsRestoreOrReset` pauses in `ChatStorageInitPhase.restoreRequired` and shows a blocking recovery overlay (restore backup, rebuild from Hive, reset, or continue with Hive for this session). `CHAT_STORAGE_FORCE_HIVE` and constructor injection (`storage`, `backend`) provide escape hatches. `DataSync`, conversation-open paths, message generation, and voice chat preload tool events. |
| Replay pairing (§9.5.2) | `tool_replay.dart` shared by `MessageBuilderService` and `ChatTurnService`: only `completed`/`denied` pairs replay, `pending`/`interrupted` are omitted as a pair, `denied` replays its denial JSON, and `write_todos`/`workspace_snapshot` never replay. Legacy events without `approvalState` infer pending from `approval_required`/`ask_user_pending` protocol JSON (and denied from `approval_denied`); duplicate non-empty call ids replay only the first pair; denials with null content are logged and omitted. |
| Reset / clear | `clearAllData` follows §8.10: close DB, write `chat_v2.reset`, let the installation gate delete the family, create `source='reset'`, write `legacy_import_disabled`, remove the marker, reopen and reload. Backup restore overwrite uses the separate `clearAllChatRows` path, which deletes rows without resetting the installation or writing the sentinel, so a routine restore never blocks the legacy import path. |
| Review fixes | R1 (no cross-reply version promotion), R2 (selection retargeted on version delete), R3 (group id normalized on appendMessageVersion), R4 (`is_recovered` preserved unless explicitly set) are implemented with regression tests. |
| Tests | `test/core/chat_storage/`: codec, repository, importer, installation gate, publisher recovery, storage gate, SQLite cache/facade, Hive-only cutover, pre-migration backup archive; plus replay-pairing tests in `message_builder_replay_tool_test.dart` and `chat_turn_service_test.dart`. |

### 18.2 Deliberate deviations from the draft

1. **`hive_generator` was removed from `dev_dependencies`.** It pins the pre-macros analyzer/source_gen chain and cannot resolve together with `drift_dev` on Dart 3.13. The existing generated Hive adapters (`chat_message.g.dart`, `conversation.g.dart`) stay checked in; running `dart run build_runner build` deletes them because their builder is gone, so restore them from Git after a Drift regeneration (or temporarily re-add the generator with an older toolchain).
2. **Undecodable Hive values abort the import instead of raw-quarantining.** Hive exposes no public raw-frame reader; the importer opens boxes with `crashRecovery: false` so a corrupt box is never rewritten, and fails with Hive intact. Missing parents (tool events/signatures/file records/workspaces whose message or conversation is absent) are quarantined with the raw payload and SHA-256.
3. **Validation hashes the mapped part payload**, not the whole original event map: `approvalState` normalization and empty-id handling intentionally change the event shape, so the contract is the stored columns + metadata (content byte-for-byte, arguments/status/approval/metadata canonically).
4. **No upgrade steps exist yet.** `publishedSchemaVersions = {1}`, so any older `user_version` is rejected until a real migration step is published. The gate has no implicit `onUpgrade`.
5. **`sqlite3_flutter_libs` is kept for plan parity but is EOL**; `sqlite3` 3.x ships SQLite through Dart native assets, which is what the tests and desktop build use.
6. **Pre-migration backup and legacy-retirement UI are now implemented.** `PreMigrationBackupService` archives raw Hive + streamed `chats.json` with a SHA-256 manifest and refuses when a live Hive box set is open; `LegacyRetirementService`/`ChatStoragePage` provide the marker-backed export/delete flow. The explicit re-import/merge action is now implemented by `LegacyReimportService` (staging import → idempotent merge → cache refresh → sentinel removal).
7. **Per-conversation message loading landed after the M5 benchmark.** `SqliteChatStorage` now loads only conversation metadata at startup; `getMessages` fails closed until `ensureConversationLoaded` loads that conversation. Open/switch paths already preload; stats, importers, re-import, and backup use explicit `ensureAllMessagesLoaded`/`ensureAllConversationsLoaded`. Upload cleanup uses a narrow SQL `LIKE` query instead of loading every message. The Windows benchmark dropped cold start from 809 ms to 643 ms and RSS from ~319 MB to ~259 MB on the 20k-message/10k-event profile; Android still needs a device run.
8. **`needsRestoreOrReset` has an explicit recovery decision.** `ChatService` now pauses in `ChatStorageInitPhase.restoreRequired` instead of silently falling back. `ChatStorageRecoveryOverlay` offers (1) restore a validated `chats.json` backup through `DataSync`, (2) rebuild SQLite from untouched Hive files, (3) reset to an empty `source='reset'` database with the legacy-import sentinel, or (4) continue on Hive for this session. `ChatStorageRecoveryService` performs reset/rebuild under the maintenance lock and never deletes Hive; restore is rejected before reset when the archive has no `chats.json`. This closes the §9.6 step 5 UI gap.
9. **Replay pairing derives status from the event shape, not `message_parts.status`.** Both builders receive the legacy event map (Hive or SQLite). `deriveLegacyToolPartStatus(approvalState, content)` is a pure function that matches the importer's stored status, so one code path serves both backends; the SQLite `CHECK (status <> 'completed' OR content IS NOT NULL)` still makes a null-content completed pair impossible. Legacy events with no `approvalState` are classified from the persisted protocol JSON (`approval_required`/`ask_user_pending` → pending, `approval_denied` → denied), so the intentional "never replay pending approval JSON" correction also applies to pre-M3 history.
10. **Live `setToolEvents` uses the runtime status.** When the assistant row is streaming, a result-less placeholder is `pending`; a restored/migrated row is `interrupted`. The distinction is pinned by a storage test.

### 18.3 Not yet wired (next milestones)

- Chatbox/Cherry importer review and a restore-from-backup drill (§9.7). The pre-migration backup, streaming `DataSync` export, and explicit legacy re-import are landed.
- Platform packaging/smoke tests for the two release targets only: Windows MSIX/Inno install + SQLite DLL, Android ABI + foreground keep-alive; plus crash/kill tests on Windows and Android (M5). The Android foreground keep-alive is wired; packaged smoke coverage is still pending. macOS/Linux/iOS are intentionally out of scope.
- Performance benchmarks and the M5 release with the legacy fallback.

The facade is live: the app now reads/writes SQLite when the gate succeeds and
keeps Hive byte-identical as the legacy/export source. Lazy detail, storage
settings, legacy retirement, pre-migration backup, streaming backup export, and
explicit legacy re-import are landed; the remaining work is platform hardening
and the Hive removal release.

### 18.4 Deferred review findings (2026-10-31)

An adversarial review of the landed storage core found the issues below. They
were deliberately not fixed in the M1/M2 change because the core was inert.
**M3 resolved R1–R4** (the facade now calls these methods); **M5 resolved R5**
with the startup progress/diagnostics work. Each fix landed with a regression
test.

#### R1. Version-group delete can move an earlier version across a reply

- **Path:** `ChatRepository.deleteMessage`.
- **Finding:** after deleting a version, the method moves the first remaining
  message with the same `groupId` into the removed slot, then renumbers. This
  matches the current plan and the Hive behavior. If versions are not
  contiguous, an earlier version can cross an intervening message:
  `[A v0, reply, A v1]` minus `A v1` becomes `[reply, A v0]`.
- **Impact:** wrong conversation order after a version delete. Not observable
  until the facade/delete UI calls the method; contiguous version groups are
  unaffected.
- **Next action:** decide whether promotion is allowed only when no earlier
  version remains, or whether a delete should never move group members. Update
  the delete semantics in §9.4 and add a non-contiguous-group regression test.
- **Resolved (M3):** promotion is now restricted to a remaining version at or
  after the removed slot. An earlier version never jumps across an intervening
  reply. Pinned by `test/core/chat_storage/sqlite_chat_storage_test.dart`
  (`delete version renumbers and retargets the selection`).

#### R2. Delete does not retarget `version_selections_json`

- **Path:** `deleteMessage`; the only writer is `setVersionSelections`.
- **Finding:** a selection pointing at the removed version is left in place.
- **Impact:** the selected version can reference a deleted row; the reader
  needs a fallback, and stale entries accumulate. This becomes visible when
  version selection is wired to SQLite.
- **Next action:** remove the deleted version's selection. If other versions
  remain, choose a deterministic survivor (for example the nearest lower
  `version`, else the nearest higher) or clear the group entry. Add tests for
  deleting the selected and a non-selected version.
- **Resolved (M3):** the deleted version's selection is retargeted to the
  nearest lower remaining version, then the nearest higher, then cleared. Pinned
  by the same delete test.

#### R3. `appendMessageVersion` can write outside the requested group

- **Path:** `ChatRepository.appendMessageVersion`.
- **Finding:** the `groupId` parameter updates `versionSelections[groupId]`,
  but the inserted row keeps the `ChatMessage`'s own `groupId`, which may be
  null or different.
- **Impact:** a version can land outside its group, and a selection can be
  written for a group that has no rows.
- **Next action:** normalize or reject a mismatch inside the transaction
  (`message.groupId == groupId`, or assign the parameter to the message) and
  test a null/mismatched message group id before the facade calls this method.
- **Resolved (M3):** `appendMessageVersion` normalizes the inserted row's
  `groupId` to the requested group inside the transaction.

#### R4. `upsertConversation` can clear `is_recovered`

- **Path:** `ChatRepository.upsertConversation`.
- **Finding:** `isRecovered` defaults to `false` and
  `insertOnConflictUpdate` writes it on every upsert.
- **Impact:** a generic save of a recovered conversation clears
  `is_recovered`, which the diagnostics/recovery UI will rely on. There is no
  such caller today.
- **Next action:** make the parameter nullable and preserve the existing column
  when it is omitted, or move the flag to an explicit recovery method. Add an
  update-after-recovery test.
- **Resolved (M3):** `upsertConversation` takes a nullable `isRecovered` and
  writes the column only when explicitly supplied, so a generic save preserves
  the flag. Covered by the repository tests.

#### R5. A corrupt Hive box can emit an unhandled asynchronous error

- **Path:** `LegacyHiveImporter._openHiveBoxes` /
  `Hive.openLazyBox(crashRecovery: false)`.
- **Finding:** the importer wraps the open failure in
  `LegacyMigrationException`, but Hive can also report an unhandled
  asynchronous error while opening a corrupt box. This was observed while
  writing a corrupt-box test; the test was removed rather than encoding flaky
  behavior.
- **Impact:** startup diagnostics may see an uncaught zone error in addition to
  the migration failure. The import still aborts, opened boxes are closed, and
  Hive is left byte-identical.
- **Next action:** catch/settle the Hive open error at the migration/startup
  boundary and expose one actionable diagnostic. Do not enable
  `crashRecovery`. Add a deterministic boundary test, or test the handler if
  Hive's error cannot be made deterministic.
- **Why deferred:** this belongs to startup/UI error handling (M5), not the
  storage core.

**Resolved (M5):** `HiveOpenBoundary` runs each legacy box open in an isolated
zone, captures both the returned future error and Hive's internal
open-completer error, waits a short settle window, and closes a box that opened
before the secondary error surfaced. The importer and the Hive fallback both
use it, so the startup overlay receives one `LegacyMigrationException` /
`HiveOpenException` diagnostic instead of an extra uncaught zone error.

**Tracking:** R1–R4 are closed as of M3; R5 is closed as of M5.

---

## Appendix A: Current Hive Event Example

```json
{
  "id": "call_abc123",
  "name": "web_fetch",
  "arguments": {
    "url": "https://example.com/article",
    "max_length": 10000,
    "start_index": 0
  },
  "content": "URL: https://example.com/article\nTitle: ...\n---\n\nfull page content...",
  "approvalState": "auto",
  "webFetchSource": "Local"
}
```

Mapping:

| Event field | `message_parts` column |
|---|---|
| `id` | `tool_call_id` |
| `name` | `tool_name` |
| `arguments` | `arguments_json` |
| `content` | `content` |
| `approvalState` | `approval_state` |
| derived status | `status` (`completed`, `pending`, `interrupted`, or `denied`) |
| `webFetchSource` | `metadata_json.webFetchSource` |
| unknown keys | `metadata_json` |

A pending approval event normally carries approval-protocol JSON in `content`; this is preserved as text. A true `content: null` is a generation-time placeholder with no result; it is preserved as SQL `NULL`. Status is derived from `approval_state` first, never from content presence alone.

---

## Appendix B: Migration Checklist

> Status 2026-10-31 (M5 in progress): the checked items are implemented and
> covered by `test/core/chat_storage/`, the replay tests, the storage-page and
> startup-overlay widget tests, the pre-migration backup test, and the Hive-only
> cutover test. The app
> reads/writes SQLite when the installation gate succeeds and keeps Hive as the
> one-release fallback; see §18.3 for the remaining M5–M6 work.

- [ ] Copy a real app-data directory to a safe temporary location.
- [x] Add Drift/SQLite dependencies and generated code.
- [x] Implement schema v1 and DAO tests.
- [x] Implement `ChatRepository` (the `ChatStorage` abstraction/facade is still open).
- [x] Implement lazy Hive importer with batches and a disposable temp DB.
- [x] Implement validation counts and content hashes.
- [x] Implement quarantine and recovered-conversation handling.
- [x] Implement `DatabaseInstallationGate`, `publishedSchemaVersions`, and schema admission.
- [x] Implement the database-family publish helper, `publish_id`, and publish-intent recovery.
- [x] Implement the optional pre-migration backup and manifest verification (raw Hive + streamed JSON + SHA-256 manifest; startup prompt).
- [x] Implement the maintenance lock, fresh/reset sentinel, and the migration orchestrator.
- [x] Implement the blocking startup/migration progress screen with retry and diagnostics.
- [x] Implement SQLite-backed `ChatService` facade with cache.
- [x] Update message builder/generation/turn service preload calls.
- [x] Update approval/ask_user/resume paths (current-conversation ensure + facade writes).
- [x] Update backup/restore/import/export routing. (Facade routing and `ensureAllConversationsLoaded` landed in M3; `DataSync` preloads before full export in M4; streamed chats JSON + WebDAV PUT landed in M5.)
- [x] Implement lazy tool detail UI and `status` rendering.
- [x] Load message bodies per conversation instead of at startup; audit open/switch, stats, importers, re-import, and backup preload paths.
- [x] Implement delete/fork/truncate/clear paths and their tests.
- [x] Resolve R1/R2/R3/R4 and R5 in §18.4 (R5 via `HiveOpenBoundary`).
- [x] Add a blocking migration progress screen (§9.6 step 3).
- [x] Add an explicit `needsRestoreOrReset` recovery screen: validated backup restore, Hive rebuild, reset with the legacy-import sentinel, and session-only Hive fallback.
- [x] Add a pre-migration backup choice before the temp DB is created and record `backup=completed|skipped`; failure/cancel aborts before the temp DB.
- [x] Add storage settings for legacy Hive export/delete and marker-backed retirement.
- [x] Add the explicit "import legacy Hive" merge action (staging import → idempotent merge → cache refresh → sentinel removal only after validation).
- [x] Add a durable legacy export receipt (format/version/database id/size/mtime/SHA-256) and validate it before deletion; delete re-hashes the source and compares it with the receipt.
- [x] Compare the user-confirmed artifact inventory under the maintenance lock and support resetting a completed marker when files reappear.
- [x] Add a widget test for the storage page and unit tests for export/tamper/size+mtime-preserved content changes/resume/reset.
- [ ] Run synthetic and real-data migration tests. (Synthetic + Hive-only cutover tests landed in M3; a real-data copy is still required.)
- [x] Run backup archive and manifest verification tests.
- [x] Keep long Android migrations alive with a temporary data-sync foreground service and restore the user's background setting afterward.
- [ ] Run Windows and Android smoke tests only, including SQLite DLL and Android foreground migration. macOS/Linux/iOS are not release targets.
- [ ] Run crash/kill tests for import, database-family publish, and legacy cleanup.
- [x] Exercise installation-gate fresh, 0-byte, unknown, newer, and missing-with-receipt cases (no older published schema exists yet).
- [ ] Run performance benchmarks and record results.
- [ ] Release with legacy Hive fallback for one release.
- [ ] After one stable release, remove Hive chat hot paths.

---

## Appendix C: Glossary

| Term | Meaning |
|---|---|
| Hive box | A key-value store file; opening an eager `Box` loads all keys/values into memory. |
| `message_parts` | Child rows of a message; Phase 1 stores tool calls/results, later text/reasoning. |
| Copy-then-swap | Build a temporary SQLite database, validate it, then rename it into place. |
| Migration receipt | A sidecar and/or in-database record proving the import completed. |
| `publish_id` | A UUID written into `migration_meta` and the publish intent; the target counts as published only when the two match. |
| Installation gate | Pre-live admission that creates, upgrades, or rejects the SQLite database before any chat connection. |
| Legacy retirement marker | A durable `deleting`/`completed` receipt with artifact sizes and timestamps, written before Hive files are unlinked. |
| Quarantine | A table holding raw legacy payloads that could not be attached or decoded, so they are not silently lost. |
| Legacy Hive | The pre-migration Hive files, retained read-only after cutover. |
| Lazy detail | Loading a tool result only when the user expands the card, not during timeline load. |
| Compatibility projection | A derived value kept for existing code/UI; the normalized table remains authoritative. `Conversation.messageIds` is hydrated from `messages.ordinal`, not stored as a second list. |
