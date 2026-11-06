# 交易式備份還原與資料保全導入計畫

> **狀態**：第二輪 Review 後修訂版；Phase 0、1a、1b 核心與 Phase 3 已實作並通過測試（2026-11）。**Phase 1c（Chatbox／Cherry 匯入回滾）與 Phase 2（附件 preflight）已實作並通過測試（2026-11-05）——全階段完成。**  
> **範圍**：P1 交易式備份還原／第三方匯入回滾、P2 Windows 檔案還原續行與附件 preflight、P3 串流與頭像微調。  
> **明確非目標**：**Windows 自訂資料目錄不導入**，不列入任何階段。  
> **不改動**：Backup v3 格式、SQLite schema、既有 Hive→SQLite 遷移與遺失安裝修復流程。

---

## 0. Review 結論

原始草案的整體方向正確（stage → verify → publish、不要先清空 live DB），但有幾個設計點若照原樣實作，會在還原成功後仍被 gate 判為失敗，或在中斷時留下不一致狀態。以下是必須修正的地方。

### 0.1 必須修正的設計問題

1. **`database_id` 與 installation receipt 不一致（阻斷級）**
   - `DatabaseInstallationGate._ensureReadyLocked()` 會檢查：
     `installationReceipt.databaseId == probe.databaseId`。
   - 若還原建立一個帶新 `database_id` 的 staging DB 並 publish，舊 receipt 仍指向舊 ID，下一次啟動會 fail-closed。
   - **修正**：staging DB **優先重用**現有有效 receipt 的 `database_id`；沒有 receipt 才用 live probe 的 ID；兩者都沒有才生成新 UUID。publish 後再驗證 receipt 與 target 一致。
   - 必須新增「已有安裝紀錄的情況下還原」的 gate 測試，而不只測 publisher。

2. **Restore journal 必須早於 gate 的 recovery-material 清理**
   - `DatabaseInstallationGate._cleanupRecoveryMaterial()` 在 admission 成功後會刪除 `.previous`、`.migrating`、`.upgrading`。
   - 若 restore journal 的復原邏輯晚於 gate 執行，中斷還原時唯一的舊 DB 可能已被刪掉。
   - **修正**：在 `ChatService.init()` 最前面（進入 `ChatStorageGate` 之前）先執行 `RestoreJournal.recoverIfNeeded()`；gate 在 journal 存在時不得清理 restore 相關檔案。
   - `ChatDatabaseFiles` 新增 `.restoring` 與 `restore-journal.json`，並納入 workflows／清理清單。

3. **檔案與 DB 的 commit 順序需要 journal，而不是單純 rollback**
   - 原草案把「檔案 swap → DB publish」寫成一個普通 try/catch；程序被殺時無法知道做到哪一步。
   - **修正**：使用持久化 `restore-journal.json` 記錄階段：
     `staged → files-swapped → db-published → live-verified → settings-applied → done`，
     另加兩個回復用 stage：`publish-unresolved`（publisher 無法裁決）與 `rolling-back`（已 commit 但驗證失敗，回滾中）。
   - Commit 順序定為：stage files → swap files（舊目錄保留）→ **publish DB（commit point）** → open/verify → settings → cleanup。
   - DB publish 前失敗：回滾檔案，舊 DB 不動。
   - DB publish 後失敗：依 journal 回滾，但 DB 與檔案必須一起；回滾前先寫 `rolling-back`（「舊 DB 一定在 `.previous`」的假設已由 §0.3 第 2 點取代）。
   - `publish()` 失敗時以 `DatabaseFamilyPublisher.recoverIfNeeded()` 為唯一裁決者（§0.3 第 1 點）。
   - 啟動時 journal 能完成或回滾，不能留下 `.previous-restore-*` 孤兒。

4. **Settings 不是交易式的，不能宣稱完整 atomicity**
   - SharedPreferences 沒有 transaction；原草案說「失敗則 rollback」過度承諾。
   - **修正**：先 snapshot 目前 prefs 到 app data 的 staging 檔；DB／檔案成功後才套用 settings。
   - settings 套用失敗時：**不 rollback 已成功的聊天 DB／檔案**，而是回報「聊天資料已還原，設定套用失敗」並提供重試；同時保留 snapshot 供下次套用。
   - 文件與 UI 文案都必須明確區分「完整成功」與「部分成功」。

5. **第三方匯入的 `clearAllData()` 會連 uploads 一起刪**
   - Chatbox／Cherry 目前在 overwrite 模式先 `clearAllData()`，失敗時舊對話與附件都已消失。
   - **修正**：不得在匯入前呼叫 `clearAllData()`；改為轉成 `ChatBackupPayload`，走 staging DB + 檔案 staging；成功後才替換。SharedPreferences（assistants／providers／tags）先 snapshot，失敗回滾。

6. **附件 preflight 只看 `fileRecords` 不夠**
   - inline 圖片在 `images/`、頭像在 `avatars/`，不一定有 `fileRecords`。
   - **修正**：preflight 以「備份目錄 manifest + `fileRecords` 參照」為準；在寫 zip 前列出所有預計加入的檔案，逐一確認存在。缺少時預設整份備份失敗並列出缺失清單（範圍限 app data 內參照，見 §0.3 第 5 點），不靜默略過。

7. **Windows staging 必須與目的地同磁碟區**
   - 跨磁碟區的 `Directory.rename` 不是原子操作，甚至直接失敗。
   - **修正**：staging 目錄放在 app data 下（與 `upload/`、`images/`、`avatars/` 同 volume），先 copy 到 staging，再 rename 進 live；rename 失敗做有界重試。

8. **還原前必須停止串流並清掉 in-memory 狀態**
   - 原草案只提到 maintenance lock，沒有處理目前串流、draft conversation、currentConversation。
   - **修正**：restore 開始前取消／flush 串流；成功 re-init 後清除 drafts、重設 currentConversation，避免 UI 仍指向已被替換的舊資料。

9. **Journal 的 stage 不能當成唯一真相**
   - 動作完成後、journal 寫入 stage 前 crash，會讓復原邏輯誤判「還沒 publish」。
   - **修正**：journal 記錄 `publishId`、`stagingDatabaseId`、`preservedPath`、`preservedDatabaseId`；啟動 recovery 先 probe target 的 `publish_id`／identity、檢查本次實際保留的 family 與檔案標記，再決定完成或 rollback。所有 recovery 操作必須 idempotent。

### 0.2 保留的原始決策

- 不先清空 live DB；以 staging DB + `DatabaseFamilyPublisher` 為核心。
- 重用 `ChatMaintenanceLock` 與既有 publish intent／`.previous` 機制。
- Phase 1a 先做 chats-only recovery 還原，獨立發佈。
- 不改 Backup v3 格式與 SQLite schema。
- Windows 自訂資料目錄不做。

### 0.3 第二輪 review 追加決策（實作前定案）

程式碼逐條核對後，§0.1 的九點全部與現況相符（gate 的 receipt 檢查、`_cleanupRecoveryMaterial()`、publisher 的 `migrate`/`upgrade` 白名單、`data_sync.dart:1281` 的 `catch (_) {}`、Chatbox／Cherry 的 `clearAllData()` 都在）。第二輪補強如下，直接納入本計畫：

1. **Commit point 之後才可回滾，且 rollback 不可與 publisher 的 roll-forward 打架**
   - `publish()` 成功（intent 已刪）＝ DB 已 commit；之後任何驗證失敗要回滾，必須先寫 `rolling-back` stage，且 DB 與檔案一起回滾。
   - `publish()` 失敗時不自行猜測 DB 狀態：同 process 立即呼叫 `DatabaseFamilyPublisher.recoverIfNeeded()` 當唯一裁決者。
     - 解析為新 target（intent 的 `publishId`）→ 視同 commit，繼續流程。
     - 解析為舊 target → 回滾檔案、刪 staging、丟錯。
     - `failClosed` → 不刪任何檔案，journal 停在 `publish-unresolved`，交下次啟動／overlay。
   - `rolling-back` 與 `publish-unresolved` 都是持久化 stage，啟動 recovery 必須能接續（idempotent）。

2. **Journal 不得假設「舊 DB 一定在 `.previous`」**
   - Publisher 在 `.previous` 已存在時會把舊 target 保留為 `.replaced-<publishId>`（`database_family_publisher.dart:148-172`），因此 publish 後 journal 必須記錄**本次實際**保留的 family：`preservedPath`、`preservedDatabaseId`、`publishId`（來源為 `DatabasePublishOutcome.previousPath`／`replacedPath` 加上現場 probe）。
   - Rollback 只使用 `databaseId` 與 journal 相符的 family；不符即 fail-closed。
   - Restore 進場 preflight：不得有既有 restore journal（表示上次 recovery 未完成）；若 `publishIntent` 存在，先跑 `publisher.recoverIfNeeded()`，未解析即拒絕還原（提示重啟）；不刪除既有 `.previous`／`.corrupt-*`／`.replaced-*`（診斷與回復材料）。

3. **Journal 本身的持久化契約**
   - 所有 stage 轉換一律用 `ChatDatabaseFiles.writeJsonAtomically()`。
   - Journal 損毀／無法解析時 **fail-closed**：不刪任何檔案，交 recovery overlay，不得猜測進度。

4. **`verifyCounts` 與孤兒資料**
   - 驗證 conversations、messages、tool events/parts、file records、`geminiThoughtSigs`、workspace bindings（provider artifacts 僅在 payload 具備時計數）。
   - `parseAndValidate` 拒絕「message.conversationId 不在 conversations」的孤兒 payload，不讓它進 staging。

5. **Phase 2 備份 preflight 的範圍**
   - 只對可解析到 app data 內 `upload/`、`images/`、`avatars/` 的參照強制存在；`FileRecord.path` 是絕對路徑，工作區／外部路徑本來就不在 Backup v3 範圍，列為「設計上不備份」的資訊項，不算失敗（否則會誤殺合法備份）。
   - App data 內的參照缺檔時整份備份失敗，且缺檔清單必須是可呈現的結構化錯誤，不是只寫 log。

6. **執行接縫**
   - `restoreChatBackup()` 與 `init()`／overlay Retry 共用既有 init completer 串行化；maintenance lock 由 `restoreChatBackup()` 持有（同 process re-entrant），`DataSync` 不另外加鎖。
   - Phase 3 的 `jumpTo` 由呼叫端傳入 `streaming` 旗標；`AvatarCache` 負向結果不得永久快取。

### 0.4 實作進度（2026-11）

已實作：

- `RestoreJournal`、`FileRestoreStager`、`ChatBackupRestorer`、`RestoreJournalRecovery`、`SettingsSnapshot`。
- `ChatService.restoreChatBackup()`：maintenance lock、journal、staging DB、publish、open／count 驗證、settings 部分成功、commit 後回滾。
- `DataSync` overwrite 路由與 recovery overlay 接線；移除 chats 還原外層吞錯。
- Gate 在 journal 存在時保留 `.previous`／`.replaced-*`；publisher 記錄 `operation: 'restore'` 與實際保留 family。
- Phase 3：串流中近底部使用 `jumpTo`；`AvatarCache` in-flight 去重與負向結果 30 秒 TTL。
- 測試：journal 損毀 fail-closed、`publish-unresolved` 保留全部檔案、`rolling-back` 續行、孤兒 message 拒絕、receipt `databaseId` 重用、殘留 `.previous` 選用 `.replaced-*`、檔案 copy 失敗、settings 部分成功。

尚未實作：

（無——Phase 1c 與 Phase 2 已於 2026-11-05 補齊，見下。）

### 0.5 Phase 1c／Phase 2 補齊實作（2026-11-05）

已實作：

- **Phase 1c**：`ChatService.restoreChatsPayload()`（與 `restoreChatBackup()` 共用 `_enqueueRestore` 串行化與 §2.2 commit protocol；接受 caller-built `ChatBackupPayload` 與 pre-staged `RestoreJournalEntry` 檔案清單）。`ChatboxImporter`／`CherryImporter` overwrite 改為「先完整解析成 payload（零副作用）→ staging DB＋（Cherry）staging upload swap → publish commit → commit 後才寫 providers／assistants／tags prefs」，**不再呼叫 `clearAllData()`**；prefs 先 `SharedPreferencesAsync.captureKeys()` snapshot，套用失敗以 `restoreKeys()` 回滾。Cherry 附件 materialize 改寫入 `restore_staging_<id>/upload/`（內容標記指向 live 路徑，swap 後即正確），測試 seam `CherryImporter.debugFailOnMaterialize`。merge 模式語義不變（去重、欄位規則皆保留），錯誤持續外拋。`ChatBackupRestorer.validatePayload()` 對 caller-built payload 套用與 archive parse 相同的孤兒／重複 id 規則。
- **Phase 2**：`lib/core/services/backup/backup_preflight.dart`——`BackupFilePreflight.classify()` 純分類器（僅強制存在於 app data `upload/`、`images/`、`avatars/` 內的參照；工作區／外部絕對路徑列為「設計上不備份」資訊項；Windows 以 normalize＋lowercase 正規化）與 `collectFromContent()`（`[image:]`／`[file:]`／markdown 圖片目標，經 `MarkdownMediaSanitizer.isLikelyLocalImagePath` 過濾——該方法移除 `@visibleForTesting` 以供重用）。`DataSync.prepareBackupFile()` 先建 manifest（掃描三目錄）再寫 zip；缺檔時拋出含結構化缺檔清單的 `BackupPreflightException`，部分寫入的 zip 會被清除。
- 測試：`test/core/chat_storage/third_party_import_transaction_test.dart`（Chatbox／Cherry overwrite 成功、第 N 則失敗／materialize 失敗不動 live 資料與 prefs、無 chat history 拒絕、雙 importer merge 去重）、`test/backup_preflight_test.dart`（分類器單元測試）、擴充 `test/data_sync_streaming_backup_test.dart`（缺檔拋結構化錯誤且不留 zip、外部參照不誤殺）。

實作決策（與 §3 Phase 1c 原文的差異）：

- prefs 改為「先 snapshot → chats commit 成功後才套用 → 套用失敗回滾 snapshot 並回報」，相較原文「先寫 prefs、失敗回滾」少了 prefs 的破壞窗口，且滿足同一驗收（失敗時舊對話、附件、助手設定皆在）。
- Chatbox 匯出無 chat history 時 overwrite 維持拒絕（`_ensureChatHistoryPresent`），避免以空 payload 覆寫 live 資料。
- 重寫 `chatbox_importer.dart` 時一併修復 HEAD 上已存在的 mojibake 註解損毀（該損毀曾把 `'thinkingBudget': thinkingBudget,` 併入註解行使其失效）；行為性字串（reasoning think 標籤包裝、三處 RegExp）以位元組級自 HEAD 還原、零語義變更。
- Phase 2 的 `debugRename` seam 與 rename 續行未再新增（§0.4 已記載 rename 有界重試與 journal 續行於 1b 具備）。

---

## 1. 目標與非目標

### 目標

1. 備份還原任何一步失敗，都不得先清空現有聊天資料。
2. 還原失敗時 UI 必須顯示失敗；不得再出現「已還原」但實際空白／半套。
3. Chatbox／Cherry overwrite 匯入失敗時，舊對話、附件、助手設定仍在。
4. Windows 上因檔案被鎖中斷的還原可重試或續行，不留下半套。
5. 備份寫入前確認附件存在，避免「成功但缺附件」。
6. 以低風險方式改善串流跟隨與頭像重複下載。

### 非目標

- Windows 自訂資料目錄（本次不碰）。
- 重寫 Hive→SQLite 遷移（現有 gate／publisher 已足夠）。
- 重做遺失安裝修復（現有 `ChatStorageRecoveryOverlay` 已具備）。
- AOT 編譯器 crash、切換對話、廣泛效能改寫、搜尋／長歷史／推理滑桿。
- 不改 Backup v3、不改 SQLite schema。

---

## 2. 目標架構

### 2.1 元件

| 元件 | 職責 |
|:--|:--|
| `ChatBackupPayload` | 解析後的備份內容：conversations、messages、toolEvents、signatures、workspaces、fileRecords |
| `ChatBackupRestorer` | 解析 archive、建立 staging DB、匯入 rows、count 驗證、呼叫 publisher |
| `RestoreJournal` | 持久化 commit 階段；記錄實際保留的 family；啟動時完成或回滾（所有寫入原子化） |
| `FileRestoreStager` | 將 upload/images/avatars 複製到同 volume staging，swap 與 rollback |
| `SettingsSnapshot` | 還原前快照 SharedPreferences；套用失敗時提供重試／回報 |
| `DatabaseFamilyPublisher` | 既有 publish intent／`.previous`／identity 驗證；新增 `operation: 'restore'`；`recoverIfNeeded()` 是 DB 狀態唯一裁決者 |
| `ChatService.restoreChatBackup()` | 對外協調 lock、detach、restore、re-init、journal 完成 |

### 2.2 Commit protocol

```text
restoreChatBackup(archive, includeFiles, restoreSettings)
  acquire maintenance lock
  stop/flush active stream
  preflight: 無既有 restore journal；publisher.recoverIfNeeded() 必須 resolved（不得有未解析的 publish intent）
  payload = parseAndValidate(archive)        // 孤兒 message 直接拒絕
  journal.begin(restoreId, archiveHash, publishId, stagingDatabaseId)
  stagingDb = buildStagingDatabase(payload, databaseId: receiptOrLiveOrNew)
  verifyStagingCounts(stagingDb, payload)
  journal.stage = staged

  if includeFiles:
    stageFilesToAppData(archive)             // 逐目錄狀態寫入 journal
    journal.stage = files-staged

  detachStorage()
  if includeFiles:
    swapFiles(old -> .previous-restore-<id>, staged -> live)
    journal.stage = files-swapped

  outcome = publish(stagingDb, operation: 'restore')   // commit point
  if !outcome.success:
    recovery = publisher.recoverIfNeeded()
    if !recovery.resolved:
      journal.stage = publish-unresolved     // 保留全部檔案，交下次啟動
      throw ChatRestoreException(publish, cause)
    if target carries this publishId:        // publisher roll-forward 完成
      treat as success; continue
    else:                                    // publisher 已回到舊 target
      journal.stage = rolling-back           // DB 已是舊的，只需回滾檔案
      rollbackFiles(); journal.discard(); re-open old DB
      throw ChatRestoreException(publish, cause)

  journal.notePublished(publishId, preservedPath, preservedDatabaseId)
  journal.stage = db-published

  openLiveStorage()
  verifyLiveCounts()
  journal.stage = live-verified

  if restoreSettings:
    applySettingsSnapshot()                  // 失敗＝部分成功，不回滾聊天資料
    journal.stage = settings-applied

  journal.done()
  cleanup preserved family / staging

  on error before publish:
    rollbackFiles(); delete staging; journal.discard(); re-open old DB
    throw ChatRestoreException(stage, cause)
  on error after publish:
    journal.stage = rolling-back
    用 journal 記錄且 identity 相符的 preserved family 還原 DB + 回滾檔案
    journal.discard()
    throw ChatRestoreException(stage, cause)
```

### 2.3 啟動順序

`ChatService._initialize()` 在取得 app data directory 後、呼叫 `_selectSqliteStorage()` 前必須是：

```text
1. RestoreJournal.recoverIfNeeded()   // 先於 gate／publish-intent recovery
2. ChatStorageGate.ensureReady()
3. SqliteChatStorage.initialize()
```

`RestoreJournal.recoverIfNeeded()`：

- 先跑 `DatabaseFamilyPublisher.recoverIfNeeded()`；未解析（failClosed）→ 保留全部檔案、回報 overlay，不再往下猜。
- `staged`：刪 staging DB／檔案，rollback 檔案（若已 swap），刪 journal。
- `files-swapped` 但 DB 未 publish：把舊檔案目錄移回，刪 staging。
- `publish-unresolved`：重跑 publisher recovery；解析為新 target 則續完成，解析為舊 target 則回滾檔案後丟棄 journal，仍 failClosed 則維持原狀。
- `db-published` 但 live 未驗證：驗證 target；成功則完成，失敗則寫 `rolling-back`，用 journal 記錄且 identity 相符的 preserved family 還原舊 DB（沒有相符者 → fail-closed）。
- `rolling-back`：先 probe target——已非本次 `publishId` → 只回滾檔案；仍為本次 `publishId` → 用 journal 記錄且 identity 相符的 preserved family 還原 DB，再回滾檔案；兩者皆不可行 → fail-closed。完成後丟棄 journal。
- `live-verified`／`settings-applied`：完成清理（含 `.previous-restore-*`）。
- Journal 存在時，`DatabaseInstallationGate` 不得執行 `_cleanupRecoveryMaterial()` 刪除 `.previous`／`.replaced-*`。
- Stage 僅供提示：recovery 必須以 target 的 `publish_id`／`database_id`、journal 的 `preservedPath`／`preservedDatabaseId` 與檔案標記重新判定實際進度，不能只信 journal stage。

### 2.4 `database_id` 規則

1. 讀取有效 `chat_v2.installation.json` 的 `databaseId`。
2. 若無，讀 live `probeDatabase().databaseId`。
3. 若仍無，生成新 UUID。
4. Staging DB 的 `migration_meta.database_id` 使用上述值；`publish_id` 每次 restore 新生成；`source='restore'`；`state='complete_clean'`。
5. Publish 後驗證 `installationReceipt.databaseId == probe.databaseId`；若無 receipt，讓 gate 在 admission 時補寫（現行 `_verifyAndAdmit` 已具備此行為；測試需覆蓋「有 receipt」與「無 receipt」兩條）。

---

## 3. 分階段工作

### Phase 0：失敗重現與測試接縫（1–1.5 天）

- 在 `DataSync`／`ChatService` 加測試專用 seam：
  - `debugFailAfterConversations = N`
  - `debugFailOnPublish`
  - `debugFailOnFileCopy`
  - `debugFailOnSettingsApply`
- 寫一條整合測試重現目前行為：還原第 N 個 conversation 失敗後，live 清單空白或只剩部分，且呼叫端可能顯示成功。
- 定義 `ChatBackupPayload`、`ChatRestoreException(stage, cause)`。
- 定義 journal 欄位：`restoreId`、`archiveHash`、`publishId`、`stagingDatabaseId`、`preservedPath`、`preservedDatabaseId`、`stage`（含 `publish-unresolved`／`rolling-back`）、`fileSwapPaths`（每個目錄含 `swapped`／`rolled-back` 狀態）、`settingsSnapshotPath`。所有 stage 轉換走 `writeJsonAtomically()`。
- 加 log tag `backup-restore`，記錄 restoreId／stage／counts／耗時；不記錄訊息內容。

**驗收**：有穩定失敗測試，尚未改正式流程。

---

### Phase 1a：交易式 chats-only recovery 還原（3.5–4.5 天）

只處理 recovery overlay 的 `includeFiles:false`、`restoreSettings:false`。

#### 檔案變更

1. `lib/core/services/chat/storage/chat_database_files.dart`
   - 新增 `restoring`（`chat_v2.sqlite.restoring`）。
   - 新增 `restoreJournal`（`chat_v2.restore-journal.json`）。
   - 納入 `workflows` 與清理清單。

2. `lib/core/services/chat/storage/database_family_publisher.dart`
   - `publish()` 允許 `operation == 'restore'`（`operation` 無其他下游消費者）。
   - Publish intent 記錄 `operation`。
   - `DatabasePublishOutcome` 帶回本次實際保留的 family：`previousPath` 與 `replacedPath` 二選一；restore 用它寫 journal 的 `preservedPath`／`preservedDatabaseId`。
   - 保留 `.previous`／`.replaced-*` 直到 restore journal 完成，不讓 gate 提前清除。
   - 新增 `debugFailOnPublish` seam 供測試；不得為 restore 另寫 roll-forward 邏輯（重用 `recoverIfNeeded()`）。

3. 新增 `lib/core/services/chat/storage/chat_backup_restorer.dart`
   - `parseAndValidate(File archive) -> ChatBackupPayload`：重用／抽出 `ChatStorageRecoveryService.validateBackup()` 的解析邏輯；拒絕孤兒 message（`conversationId` 不在 conversations）。
   - `buildStagingDatabase(payload, databaseId)`：
     - `AppDatabase.open(files.restoring, background: false, synchronousFull: true)`
     - `verifyHealthy()`
     - 寫 `migration_meta`（database_id、publish_id、source=restore、state=complete_clean）
     - 以 `ChatRepository.restoreConversation()` 匯入 conversations/messages
     - 匯入 tool events、provider artifacts（若 payload 具備）、workspace bindings、file records
     - `checkpointAndTruncate()`、close、`ensureNoSidecars()`
   - `verifyCounts(stagingDb, payload)`：conversations、messages、tool parts/elements、file records、`geminiThoughtSigs`、workspace bindings（provider artifacts 僅在 payload 具備時計數）。
   - `publishStaging()`：呼叫 publisher。

4. `lib/core/services/chat/chat_service.dart`
   - 新增 `restoreChatBackup(File archive)`；maintenance lock 由本方法持有（`ChatMaintenanceLock` 同 process re-entrant，gate 內再取不會 self-block）。
   - 流程：preflight（publisher recovery）→ lock → stop/flush stream → detach storage → journal → build → publish → init → 清 drafts/currentConversation → journal done。
   - 與 `init()`／overlay Retry 的併發以既有 init completer（`_initFuture`）同一機制串行化，避免 restore 中途被第二次 init 插入。
   - 失敗：publish 前＝刪 staging、回滾檔案、重新開啟舊 DB；publish 失敗＝交 `recoverIfNeeded()` 裁決（§0.3）；post-publish 失敗＝`rolling-back` 回滾 DB＋檔案。都丟 `ChatRestoreException(stage, cause)`。
   - 不呼叫 `resetChatStorage()`。

5. `lib/features/home/pages/home_page.dart`
   - `_restoreStorageBackup()` 移除 `resetChatStorage()`。
   - 改呼叫 `chatService.restoreChatBackup(backup)`。
   - 只有成功返回才顯示 `chatStorageRecoveryRestoreDone`；失敗讓 overlay 顯示錯誤。

6. `lib/core/services/backup/data_sync.dart`
   - 移除 chats 還原區塊外層 `catch (_) {}`（`data_sync.dart:1281`）。
   - overwrite 路徑改走 `restoreChatBackup()`（lock 由它持有，DataSync 不另外加鎖）；merge 模式保留，但錯誤要往外拋。
   - WebDAV／Dropbox 下載後的 `_restoreFromBackupFile` 共用同一新流程。
   - PR 1 窗口內 `includeFiles:true` 的完整還原仍是「新 chats 交易 + 舊檔案區塊」：chats 先 commit、檔案區塊維持現行先刪後複製；此窗口不宣稱檔案層 atomicity（Phase 1b 才納入）。

7. `lib/core/services/chat/storage/chat_storage_recovery_service.dart`
   - `validateBackup()` 改為回傳 `ChatBackupPayload`（或新增 `parseBackup()`），避免解析兩次。
   - 驗證版本、conversation/message JSON、必要欄位。

8. 新測試
   - `test/core/chat_storage/chat_backup_restorer_test.dart`
   - `test/core/chat_storage/restore_journal_test.dart`
   - 擴充 `chat_storage_recovery_overlay_test.dart`
   - 擴充 `database_family_publisher_test.dart`
   - 擴充 `chat_storage_recovery_service_test.dart`
   - 必測：殘留 `.previous` 時 publisher 走 `.replaced-*` 且 rollback 用對 family；journal 損毀 fail-closed；`publish-unresolved`／`rolling-back` 重啟續行；restore 與 overlay Retry 併發；孤兒 message payload 被拒。

#### 驗收

- 損壞 archive：live DB 完全不變。
- 第 N 個 conversation 寫入失敗：舊資料仍在，錯誤可見，可 retry。
- publish 失敗：舊 target／保留 family 不動，`recoverIfNeeded()` 可接手；failClosed 時 journal 停 `publish-unresolved`。
- publish 後驗證失敗：`rolling-back` 會同時回滾 DB 與檔案，不留下半套。
- 已有 installation receipt 的安裝：還原後 gate 可正常 admission（databaseId 一致）。
- 程序在 publish 前／後被殺：下次啟動只看到完整舊資料或完整新資料。
- 在「publish 完成、journal stage 尚未更新」時被殺：recovery 仍能由 target 的 publishId 判定為新 DB，不會誤回滾。
- 在「檔案已 swap、DB 尚未 publish」時被殺：recovery 能由 journal + 檔案標記回滾舊目錄。
- 殘留 `.previous` 時發起還原：publisher 保留舊 target 為 `.replaced-*`，rollback 使用 journal 記錄的實際 family。
- recovery overlay 不再出現「空白清單 + 成功」的組合。

---

### Phase 1b：完整備份還原（檔案＋設定，4–5 天）

#### 工作

1. `FileRestoreStager`
   - staging 目錄放在 app data（與目的地同 volume）。
   - 先複製到 `restore_staging_<id>/upload|images|avatars`，驗證存在與大小。
   - swap：舊目錄改名為 `.previous-restore-<id>`，staging 改名進 live。
   - rename 失敗：有界重試（5 次，100/200/400/800ms）；仍失敗則 rollback。
2. `RestoreJournal` 加入 `files-staged`／`files-swapped`／`db-published`／`live-verified`／`settings-applied`／`rolling-back`；`fileSwapPaths` 逐目錄記錄 `swapped`／`rolled-back`，支援部分 swap 的接續。
3. `SettingsSnapshot`
   - 還原前把目前 SharedPreferences 寫入 app data 的 `restore_settings_snapshot.json`。
   - DB／檔案成功後套用備份 settings。
   - 失敗時不 rollback 聊天資料；回報「部分成功」並保留 snapshot 供重試。
4. `DatabaseFamilyPublisher`／gate
   - Journal 存在時跳過 `.previous` 清理。
   - 還原後 gate 可正常 admission（重驗 databaseId／receipt）。
5. UI
   - 完整成功：顯示「備份已還原」。
   - 部分成功：顯示「聊天資料已還原，設定套用失敗」與重試入口。
6. 測試
   - 檔案 copy 中途失敗：舊檔案與舊 DB 都在。
   - DB publish 成功但檔案 swap 失敗：依 journal 回滾 DB／檔案。
   - settings 失敗：DB／檔案保留，UI 顯示部分成功。
   - 重啟後 journal 完成或回滾，無孤兒目錄。

---

### Phase 1c：Chatbox／Cherry 匯入回滾（3–4 天）

1. 兩個 importer 先完整解析、驗證；轉成 `ChatBackupPayload`。
2. overwrite 模式不得先 `clearAllData()`：
   - 走 Phase 1a 的 staging DB；
   - 檔案走 Phase 1b 的 staging；
   - assistants／providers／tags 先 snapshot，失敗回滾。
3. merge 模式：
   - 不改既有去重語義；
   - 寫入錯誤要回報，不可靜默。
4. 測試
   - Chatbox 第 N 則訊息失敗：舊對話／助手／附件仍在。
   - Cherry 檔案 materialize 失敗：不改 live DB。
   - overwrite 成功：counts 正確，舊資料被替換。
   - merge 成功：重複資料不新增，既有資料不被刪。

---

### Phase 2：Windows 續行＋附件 preflight（2–4 天，視重現）

1. `FileRestoreStager` 的 `restore-journal` 支援啟動時完成未完成的 rename。
2. 測試 seam `debugRename` 模擬 Windows `Access is denied`／檔案被鎖。
3. `prepareBackupFile()`：
   - 先建立「預計加入 zip 的檔案 manifest」：目錄掃描（upload/images/avatars）＋ chats 參照集（fileRecords、訊息內圖片）。
   - 只對**可解析到 app data 內** `upload/`、`images/`、`avatars/` 的參照強制存在；`FileRecord.path` 是絕對路徑，工作區／外部路徑本來就不在 Backup v3 範圍，列為「設計上不備份」的資訊項，不算失敗（否則會誤殺合法備份）。
   - App data 內的參照缺檔時整份備份失敗，錯誤需帶可呈現的缺檔清單（結構化，不是只寫 log）。
   - 不靜默略過；若未來要「允許缺少」，必須有明確 UI 選項與 manifest。
4. 驗收：Windows 鎖定資料夾時可重試／續行；備份不再成功但缺附件。

---

### Phase 3：低風險 UX 微調（1 天）

1. `ChatScrollController._animateToBottom`：串流中、已在底部、距離很小時用 `jumpTo(max)`；其餘維持動畫。串流狀態由呼叫端（串流 chunk 路徑）傳入 `streaming` 旗標，controller 不自行猜測。
2. `AvatarCache`：加 in-flight `Map<String, Future<String?>>`，同 URL 共用 future，完成後移除；同時取消「失敗永久記入 `_memo`」——負向結果只保留短 TTL（或完全不快取），避免暫時性失敗永久化。
3. 不聲稱效能加速，除非有前後量測。

---

## 4. 失敗行為矩陣

| 失敗點 | 預期行為 |
|:--|:--|
| Archive 損壞／版本不支援／孤兒 message | live DB 完全不動，顯示錯誤 |
| staging DB 建立失敗 | 刪 staging，live DB 不動 |
| 第 N 筆 row 寫入失敗 | 刪 staging，live DB 不動 |
| count 驗證失敗 | 不 publish，live DB 不動 |
| 檔案 copy 失敗 | 舊檔案／舊 DB 不動 |
| 檔案 swap 失敗 | 回滾舊目錄，舊 DB 不動 |
| DB publish 失敗、publisher 解析為舊 target | 回滾檔案；舊 target／保留 family 不動 |
| DB publish 失敗、publisher failClosed | journal `publish-unresolved`；所有檔案保留，overlay 顯示失敗 |
| publish 後驗證失敗 | journal `rolling-back`；DB 與檔案一起回滾（只用 journal 記錄且 identity 相符的 preserved family） |
| Journal 損毀 | fail-closed；不刪任何檔案 |
| 殘留 `.previous` 時還原 | publisher 保留舊 target 為 `.replaced-*`；rollback 依 journal 的實際路徑 |
| settings 套用失敗 | 聊天資料保留；顯示部分成功，提供重試 |
| 程序中途被殺 | 下次啟動 journal 完成或回滾，不開空白清單 |

---

## 5. 測試與驗收

### 自動測試

優先擴充：

- `test/data_sync_streaming_backup_test.dart`
- `test/core/chat_storage/chat_storage_recovery_service_test.dart`
- `test/core/chat_storage/database_family_publisher_test.dart`
- `test/chat_storage_recovery_overlay_test.dart`
- `test/core/chat_storage/chat_service_cutover_test.dart`

新增：

- `test/core/chat_storage/chat_backup_restorer_test.dart`
- `test/core/chat_storage/restore_journal_test.dart`
- 失敗注入：row write、publish、init、file copy、settings apply、journal write。
- count mismatch、孤兒 message payload。
- 已有 installation receipt 的還原後 admission（含無 receipt 由 gate 補寫）。
- 殘留 `.previous` → `.replaced-*` → rollback 選對 family。
- Journal 損毀、`publish-unresolved`、`rolling-back` 的 fail-closed 與續行。
- restore 與 overlay Retry／`init()` 併發。
- 程序重啟模擬：journal 各階段殘留。

### 手動驗收（Windows + Android）

1. 正常備份 → 還原：對話／附件／設定完整。
2. 還原過程強制關閉程序 → 重開不出現空白清單。
3. 磁碟幾乎滿 → 還原失敗，舊資料仍在，錯誤可見。
4. 損壞 zip → 不影響現有資料。
5. Windows 鎖定 upload 資料夾 → 可重試／續行。
6. Chatbox／Cherry overwrite 中途失敗 → 舊資料仍在。

### Definition of Done

- 沒有任何還原路徑會先清空 live DB 再冒失敗風險。
- 所有失敗都回到 UI，不再被 `catch (_) {}` 吞掉。
- 還原成功後 counts 與備份一致。
- 程序被殺後只看到完整舊資料或完整新資料。
- 既有測試全綠；新增失敗注入測試覆蓋失敗矩陣。

---

## 6. 發佈與回退

- 不新增使用者設定；預設走新流程。
- 保留舊 `DataSync` overwrite 實作在測試 seam 後面一個版本，方便回退；不要讓兩條路徑同時對使用者開放。
- 先發佈 Phase 1a（chats-only），確認無 regression 後再做 1b／1c。
- Release note 明寫：「recovery overlay 的對話還原失敗不再清空資料；完整備份的檔案層交易式還原於 1b 提供」。
- log 只記 restoreId／stage／counts／耗時／錯誤類型，不記訊息內容。

---

## 7. 風險與對策

| 風險 | 對策 |
|:--|:--|
| staging DB 額外佔用磁碟 | 動 live 前檢查可用空間；失敗即刪 staging |
| `database_id`／receipt 不一致 | 重用有效 receipt 的 database_id；publish 後 gate 測試 |
| gate 提前刪 `.previous` | journal 先於 gate；journal 存在時禁止 cleanup（含 `.replaced-*`） |
| 殘留 `.previous` 讓 journal 指錯舊 DB | publish 後記錄實際 `preservedPath`／`preservedDatabaseId`；rollback 前驗 identity |
| journal 損毀 | fail-closed，不刪檔案，交 overlay |
| restore 與 init／Retry 併發 | 共用 init completer 串行化；restore 持 maintenance lock |
| Windows rename 被鎖 | 同 volume staging＋有界重試＋journal 續行 |
| SharedPreferences 非交易式 | snapshot；失敗回報部分成功，不假裝完整 |
| 第三方 importer 刪 uploads | 禁止先 `clearAllData()`；檔案 staging |
| merge 模式行為改變 | merge 不走 destructive restore；只補錯誤回報 |
| 範圍膨脹 | Phase 1a 先獨立發佈；1b／1c 分開 PR |

---

## 8. PR 切分

### PR 0.5（Phase 0 + journal 基礎，無行為改動）

- 失敗重現測試。
- `ChatDatabaseFiles.restoring`／`restoreJournal`。
- Journal 資料模型（含 `publish-unresolved`／`rolling-back`）＋原子寫入。
- Gate/journal 互斥測試（journal 存在時不清 `.previous`／`.replaced-*`）。

### PR 1（Phase 1a，行為變更）

- `DatabaseFamilyPublisher` 的 `restore` operation 與 outcome 保留路徑。
- `ChatBackupRestorer` parse／build／publish。
- `ChatService.restoreChatBackup()`。
- recovery overlay 接線；移除 `resetChatStorage()`。
- chats-only 失敗注入測試。

### PR 2（Phase 1b）

- FileRestoreStager。
- SettingsSnapshot。
- Journal 全階段與啟動 recovery。
- 完整還原測試。

### PR 3（Phase 1c）

- Chatbox／Cherry staging＋prefs snapshot。
- 匯入失敗測試。

### PR 4（Phase 2，視重現）

- Windows rename 重試／續行。
- 備份附件 manifest preflight。

### PR 5（Phase 3）

- 串流 `jumpTo`。
- Avatar in-flight 去重。

---

## 9. 粗估排程

| 階段 | 內容 | 估時 | 依賴 |
|:--|:--|--:|:--|
| Phase 0 | 失敗重現、journal 基礎（PR 0.5）、型別、log | 1–1.5 天 | — |
| Phase 1a | 交易式 chats-only 還原 | 3.5–4.5 天 | Phase 0 |
| Phase 1b | 完整檔案＋設定還原 | 4–5 天 | 1a |
| Phase 1c | Chatbox／Cherry 回滾 | 3–4 天 | 1a |
| Phase 2 | Windows 續行＋附件 preflight | 2–4 天 | 1b，視重現 |
| Phase 3 | 串流／頭像微調 | 1 天 | 無 |

**P1 合計約 11–14 個工作天**（第二輪 review 加入 publisher 裁決語義、journal 回復 stage、殘留 `.previous` 與併發測試）。Phase 2／3 另加 3–5 天。建議 Phase 1a 先做成可發佈的垂直切片。

---

## 10. 明確排除

- Windows 自訂資料目錄。
- Hive→SQLite 遷移重寫。
- 遺失安裝修復重做（現有 recovery overlay 已足夠）。
- AOT 編譯器 crash 修復。
- 切換對話可見性。
- 搜尋／長歷史／推理滑桿／工具長對話的廣泛效能改寫。
- Backup v3 格式變更、SQLite schema 變更。
