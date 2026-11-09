# Answer Review 卡片化與可追溯計畫

> 狀態：**已實作（2026-11-09，P1–P4 完成；soak 為後續）**
> 前置：`docs/answer_review_plan.md`（Answer Review v1 已上線）、手冊 §3.14 §9
> 目標讀者：要評估 review 效果、需要看到「初稿 → 審查 → 修正」完整過程的人
>
> 2026-11-09 拍板：卡片放在 **process group 內**；終態預設收合；初稿預設保存
> （完整初稿，且**不會**進入後續對話上下文）；minor issues 顯示但低調；
> 匯出**包含**初稿/diff；smart gate 跳過時**完全不顯示**卡片。

---

## 1. 為什麼要做

目前使用者只看得到一個文字 chip：

- `審查回答中…` → `正在修正回答…` →（失敗時）`審查未完成，已保留原回答`
- **看不到**：初稿長什麼樣、reviewer 回了什麼 verdict、有哪些 issues、修正前後差在哪。
- 這些資料目前只存在記憶體（`AnswerReviewStreamState` + `ReviewVerdict`），
  `§9.4` 又刻意在 review/revision 期間不寫 DB；重新載入或重啟後完全消失，
  無法評估 review 效果，也無法事後追溯。

本計畫把整個過程變成**可折疊的卡片**，並在審查發生時把「初稿 + verdict + issues +
修正結果 + 時間/usage」持久化到既有 `message_parts`（不新增 table、不動 schema version），
讓卡片在重新載入後仍然存在。

### 設計原則

1. **透明**：初稿、審查中、審查結果、修正中、修正完成/失敗，全部看得到。
2. **可追溯**：卡片跟著訊息走；重啟、換版本、備份還原後都還在。
3. **不打擾**：預設可折疊；PASS 時低調；不影響答案閱讀與選取。
4. **重用**：沿用 process group / tool card 的折疊與配色；diff 重用
   `lib/core/services/file/unified_diff.dart` 的 `computeUnifiedDiff`。
5. **零回歸**：舊訊息沒有卡片；review off / smart gate 跳過 / AI Team / 語音 /
   非串流都不產生任何卡片或資料。

---

## 2. 現況與缺口

| 層 | 現況 | 缺口 |
|---|---|---|
| Orchestrator | 有 `ReviewVerdict`（verdict + issues + parsed），只寫 `developer.log` | verdict/issues 沒有傳給 UI |
| Chunk | `ChatStreamChunk.reviewPhase` 只有 `reviewing` / `revising` / `revision_failed` | 沒有 `reviewed`（結果）狀態、沒有 issues payload |
| UI 狀態 | `AnswerReviewStreamState` 只有 phase / reviewed / reviewTokens / draftBackup | 沒有初稿、verdict、issues、時間、失敗原因 |
| 顯示 | `message_list_view` 的 `_ReviewIndicator` 是純文字 chip | 不是卡片；沒有初稿/結果/diff |
| 持久化 | review/revision 訊息只存在記憶體 | 無法追溯；重啟即失 |
| DB | `message_parts` 只存 `kind='tool'` | review 沒有落點 |

> 實際案例（2026-11-09）：Agnes 回覆出現「審查中 → 修正中」，但 DB 只有修正後
> 的內容；draft 與 issues 已被覆寫，無法回答「到底改了什麼」。

---

## 3. 使用者體驗

### 3.1 卡片位置

放在 **process group 之內**（作為 group 的最後一列，工具/思考卡片之後）、答案
Markdown 之上。收合 process group 時卡片也一起收合；展開 group 才能看到完整
審查內容。group header 另外顯示一個低調的 review 摘要（狀態 + issue 數），
讓收合狀態下仍知道「這次有審查、結果如何」。

```
ProcessGroupCard（展開時）
├─ thinking / tool rows
├─ AnswerReviewCard（reviewing → passed / revised / failed …）
└─ （group 收合時只剩 header 上的 review 摘要）
```

完整卡片佈局：

```
┌─ Assistant card ────────────────────────────────────────────┐
│ [process group / thinking / tool cards]                     │
│ ┌─ 回答審查 · 已修正 · 2 個問題 ────────────── 1.8s ▾ ─┐   │
│ │ 初稿（1,107 字）                              [展開] │   │
│ │ 審查結果  REVISE                                    │   │
│ │   ⚠ major  開頭「艾瑞絲（Aries…）」                 │   │
│ │      問題：…    建議修正：…                          │   │
│ │ 修正差異  +12 / −8                        [查看差異] │   │
│ │ 審查 1.2s · 修正 3.4s · 2,214 tokens                 │   │
│ └─────────────────────────────────────────────────────┘   │
│ # 艾瑞絲（Aries）簡介 …（最終答案 Markdown）                 │
└─────────────────────────────────────────────────────────────┘
```

放在訊息內（而不是像現在浮在訊息上方）的好處：跟著訊息捲動、可選取、可複製、
匯出時自然帶到；串流中的臨時 chip 也由同一張卡片取代。

### 3.2 狀態機

```
idle
 └─ reviewing ──(pass)──────────────► passed
      │
      ├─(revise)─► revising ──(ok)──► revised
      │                └─(fail)─────► revision_failed
      ├─(timeout/error/empty/malformed)─► failed_open
      └─(user cancel)──────────────────► cancelled
（crash 後由 DB pending 還原）──────────► interrupted
```

`passed` / `revised` / `failed_open` / `revision_failed` / `cancelled` / `interrupted`
都是**終態**；卡片保留在訊息上，直到訊息被刪除。

### 3.3 各狀態的卡片內容

| 狀態 | Header | 內容 | 答案區 |
|---|---|---|---|
| `reviewing` | spinner +「審查回答中…」 | 初稿（可展開）、「以相同模型自查中…」 | 初稿已顯示 |
| `passed` | ✓「已通過 · N 個問題」 | 初稿、issues（通常 minor）、meta | 初稿 |
| `revising` | spinner +「正在修正回答…」 | 初稿、verdict + issues | 修正串流中 |
| `revised` | ✓「已修正 · N 個問題」 | 初稿、issues、diff +N/−M、meta | 修正後 |
| `failed_open` | ⚠「審查未完成 · 已保留原稿」 | 初稿、失敗原因（逾時/錯誤/空回應/格式錯誤） | 初稿 |
| `revision_failed` | ⚠「修正未完成 · 已保留原稿」 | 初稿、issues、修正失敗原因 | 初稿（還原） |
| `cancelled` | ⏹「已取消 · 已保留原稿」 | 初稿、最後已知狀態 | 初稿 |
| `interrupted` | ⚠「審查中斷 · 已保留原稿」 | 初稿、最後已知狀態 | 初稿 |

### 3.4 卡片區塊

1. **Header**：icon、標題「回答審查」、狀態 chip、issue 數量、總耗時、折疊箭頭。
2. **Timeline**（小字，可省略在折疊時）：初稿完成 → 審查 →（修正）→ 完成，
   每個節點有時間；失敗節點顯示原因。
3. **初稿**：完整文字，使用與訊息相同的 Markdown sanitizer 渲染；
   右上「複製」；過長時顯示「已截斷」提示（見 §5.4）。
4. **審查結果**：
   - verdict badge（PASS / REVISE / 未完成）。
   - issues 依 severity 分組：`blocker`（error 色）、`major`（amber/tertiary）、
     `minor`（muted）。每張 issue 顯示 `location`（code 樣式）、`problem`、`fix`。
   - 沒有 issues 時顯示「未發現阻擋性問題」。
   - **只顯示、不提供「套用」按鈕**（v1 固定由模型自動修正一次）。
   - **minor 一律顯示但低調**：muted 色、較小字、排在 blocker/major 之後；
     不隱藏、不折疊掉，讓使用者能評估 review 的誤判率。
5. **修正差異**：`+N / −M`；`computeUnifiedDiff(draft, final)` 的 hunks，
   等寬字型、`+`/`-` 著色；預設只顯示前 ~40 行，可「顯示全部」；
   完全相同時顯示「修正後內容與初稿相同」。
6. **Meta**：reviewer model、review/revision 耗時、review tokens、
   建立時間；debug 模式下顯示 message id / part id。

### 3.5 折疊行為

- **串流中**：預設展開（讓使用者看到正在審查）。
- **終態**：預設收合到 header（除非使用者手動展開）；若 process group 本身
  收合，review 卡片跟隨 group 一起隱藏，group header 保留摘要。
- 使用與 process group 相同的「explicit pin > forced open > auto collapse」
  規則（`process_group_logic.dart` 的 `resolveProcessOpen` 語意）；
  pin 狀態存在 controller（in-memory），與現有 process group 一致。
- `autoCollapseThinking` 關閉時，終態維持展開。

### 3.6 什麼情況沒有卡片

- `answer_review_v1 = off`
- `smart` gate 判定不需要 review（短回答、無工具、無 URL/數字/code）
- AI Team aggregator / 語音 / 非串流（本來就 opt-out）
- 舊訊息（沒有 review part）
- 使用者取消且 review 尚未開始（只有主答案）

---

## 4. 資料模型與協定

### 4.1 `AnswerReviewReport`（純 Dart）

新增 `lib/core/models/answer_review_report.dart`（或放在現有
`lib/core/models/answer_review.dart`）：

```dart
class AnswerReviewReport {
  final int schemaVersion;      // 1
  final String phase;           // reviewing/passed/revising/revised/
                                // failed_open/revision_failed/cancelled/interrupted
  final String? verdict;        // 'pass' | 'revise' | null（未完成）
  final bool parsed;            // review 是否產生可辨識的 PASS/REVISE
                                // （JSON 或純文字）
  final List<ReviewIssue> issues;
  final bool reviewed;          // 最終答案是否套用審查結果（PASS 或修正成功）
  final String? failReason;     // timeout/error/empty/malformed/
                                // revision_failed/revision_paused/
                                // revision_tool_call/cancelled/interrupted
  final int reviewMs;
  final int revisionMs;
  final int reviewTokens;
  final String? modelId;
  final int draftChars;
  final bool draftTruncated;
  final int? startedAtMs;
  final int? finishedAtMs;

  Map<String, dynamic> toJson();
  factory AnswerReviewReport.fromJson(Map<String, dynamic> json);
}
```

`ReviewIssue` 重用 `lib/core/services/agent/answer_review.dart` 的既有模型
（`toJson` 已有）；若擔心 UI 依賴 service 層，可把 `ReviewIssue` 移到
`lib/core/models/`（純資料）並保留 re-export。

### 4.2 Chunk 協定

`lib/core/services/api/chat_stream_chunk.dart`：

```dart
final AnswerReviewReport? reviewReport;   // 新增，copyWith 保留
```

新增 phase 常數（`answer_review.dart`）：

```dart
const kReviewPhaseReviewed = 'reviewed';  // 新增：審查有結果（含 fail-open）
```

Emission 順序（`agent_orchestrator.dart`）：

```
reviewing                         ← 開始審查（既有）
reviewed (report)                 ← 新增：verdict/issues/failReason/durations
revising                          ← 僅當 report.verdict == 'revise'（既有）
revision_failed (report)          ← 修正失敗（既有 phase + report）
terminal (reviewed/reviewUsage)   ← 既有；卡片在 terminal 收尾
```

- `reviewed` **一定**會送（PASS、REVISE、fail-open、malformed 都送），
  讓卡片能顯示「結果」而不是只看到 chip 消失。
- Fail-open 的 `report.failReason`：
  - `timeout`：`_collectRound` 逾時（若 config 有設）
  - `error`：transport error
  - `empty`：response 空
  - `malformed`：無法辨識 PASS/REVISE（`parsed=false`）
  - `revision_failed`：修正失敗（在 `revision_failed` chunk 上）
- `reviewMs` / `revisionMs` 由 orchestrator 的 Stopwatch 量測（已有 reviewWatch；
  修正再加一個）。
- **初稿不進 chunk**：`chat_actions` 在收到 `reviewing` 時從
  `state.fullContentRaw` 快照（此時 revision 還沒清空）；為避免 UI/驅動內容
  不一致，report 可帶 `draftChars`（或 `draftHash`）做 sanity check。

### 4.3 持久化：复用 `message_parts`（不新增 table）

**選擇**：`message_parts` 新增一種 `kind`，而不是新 table。

理由：
- 現行 schema 是 v1，且有嚴格的 installation gate（`publishedChatSchemaVersions`）；
  新 table = 版本升級 + migration + 備份驗證，風險與工作量都高。
- `message_parts` 已隨訊息 cascade 刪除、已進備份、已有 ordinal 與 metadata。
- 既有工具管線大多已用 `kind == 'tool'` 過濾（`sqlite_chat_storage`、
  `chat_repository`、`legacy_hive_importer`），新增 kind 不會被誤認為工具。

**Part 形狀**：

| 欄位 | 值 |
|---|---|
| `kind` | `'answer_review'` |
| `ordinal` | 接在工具 parts 之後（`_nextPartOrdinal`） |
| `tool_call_id` / `tool_name` | `NULL` |
| `status` | `pending`（審查中）/ `completed`（有結果）/ `interrupted`（失敗/取消/中斷） |
| `content` | 初稿全文（可為 null；見 §5.4 截斷） |
| `metadata_json` | `AnswerReviewReport.toJson()` + `finalHash`（最終答案 hash） |

> `status='completed'` 的 CHECK 要求 `content IS NOT NULL`；初稿一定存在，
> 所以合法。若未來關閉「保存初稿」，改用 `status='interrupted'` 或放寬 CHECK
>（不建議）。

**Repository / storage 新增**：

- `chat_repository.upsertAnswerReviewPart({messageId, draft, report, status})`
  - 同一 message 只留一列：先查 `kind='answer_review'`，有則 update、無則 insert。
  - 不經過 `upsertToolEvent`（避免 tool 狀態機）。
- `chat_repository.getAnswerReviewParts(messageIds)`（batch；`allPartsBatch` 已抓全部，
  可在同一輪分出 review rows，避免 extra query）。
- `chat_service.upsertAnswerReview(...)` / `getAnswerReviews(...)` facade。
- `StreamController._answerReviews: Map<String, AnswerReviewViewData>` +
  `restoreAnswerReviews(...)`（與 `_toolParts` 同模式）。
- `sqlite_chat_storage._reloadToolEvents`：目前 `if (row.kind != kToolPartKind) continue;`；
  新增同一迴圈收集 `kind == kAnswerReviewPartKind` 的 rows → 回傳/還原。

**讀寫審計（實作前必做）**：

- `chat_repository.setToolEvents` / 刪除/重寫 parts 的查詢是否只針對
  `kind='tool'`（目前 931/1029 行有 `kind.equals(kToolPartKind)`；逐一確認）。
- `allPartsBatch`、`getToolPartSummariesForMessages`、`loadToolEventDetail`
  是否會把 review row 當工具（目前多數有 kind 過濾；補測試）。
- `legacy_hive_importer` 只匯入 tool parts（已過濾）。
- 備份/還原（`data_sync`、`backup_preflight`、`chat_backup_restorer`）是否
  整表帶 `message_parts`；若是，review 自動跟著走；若只帶 tool，需擴充。
- 匯出（`message_export_sheet.dart`）目前有 thinking/tool card；新增 review
  summary（見 §5.6）。

### 4.4 寫入時機

| 時機 | 動作 |
|---|---|
| `reviewing` chunk | 快照 draft；insert/upsert part（`pending`，content=draft） |
| `reviewed` chunk | 更新 metadata：verdict/issues/parsed/reviewMs/tokens；status → `completed`（有結果）或 `interrupted`（fail-open） |
| `revising` chunk | metadata.phase=revising、revisionStartedAt |
| `revision_failed` | metadata.failReason=revision_failed；status=`interrupted` |
| terminal | metadata.phase=passed/revised、finishedAt、reviewed、reviewTokens；status 對應 |
| error/cancel | metadata.phase=cancelled/interrupted；status=`interrupted`；draft 保留 |
| crash | 下次載入時把 `pending` 正規化為 `interrupted`（與工具 pending 的處理一致） |

- 每次只做一次小 update（metadata），draft 只寫一次；不要在串流中反复寫。
- 持久化必須發生在 `_finishStreaming` 清掉 `StreamingState` **之前**；
  失敗時 catch + log，不能讓卡片錯誤阻塞答案完成。

---

## 5. UI 元件與檔案變更

### 5.1 新元件

- `lib/features/chat/widgets/answer_review_card.dart`
  - `AnswerReviewCard({required AnswerReviewViewData data, bool live, ...})`
  - 自帶 expand/collapse（`AnimatedSize`）、header、sections。
- `lib/features/chat/widgets/answer_review_diff.dart`（可合併進 card）
  - 呼叫 `computeUnifiedDiff(oldText: draft, newText: final, path: 'answer')`；
  - 只渲染 `UnifiedDiffHunk`；行數/位元組上限沿用其 `maxBytes`；
  - 大 diff 只顯示前 N hunk，其餘「顯示全部」。
- `lib/features/chat/widgets/answer_review_issue_tile.dart`（可合併）
  - severity 色票、location/problem/fix。

### 5.2 既有檔案

- `lib/features/home/widgets/message_list_view.dart`
  - 移除 `_ReviewIndicator`（或保留給「尚未有 report」的極短暫狀態）；
  - 把 `answerReview`（live report 或 restored record）傳給 `ChatMessageWidget`。
- `lib/features/chat/widgets/chat_message_widget.dart`
  - 新增 `AnswerReviewViewData? answerReview` 參數；
  - 在 process group 之後、答案 Markdown 之前插入 `AnswerReviewCard`；
  - 卡片不參與 `hideStreamingIndicator` / process group 的 fold 邏輯。
- `lib/features/home/controllers/streaming_content_notifier.dart`
  - `StreamingContentData` 新增 `AnswerReviewReport? reviewReport`（或
    `AnswerReviewViewData`），在**所有** copy/update 方法保留（目前已有
    `reviewPhase` 的 7 個 copy 點，照同樣模式）；
  - `updateReviewReport(messageId, report)` 只在一階段變更時 notify。
- `lib/features/home/controllers/answer_review_stream_state.dart`
  - 擴充：`draft`、`report`、`reviewStartedAt`、`verdictAt`、`revisionStartedAt`；
  - `beginRevision` 保留既有 backup 行為；`finish` 設定最終 report。
- `lib/features/home/controllers/chat_actions.dart`
  - `_handleReviewPhaseChunk`：處理 `reviewed`；capture draft；更新 notifier；
  - `_handleStreamFinish` / `_handleStreamError` / `cancelStreaming`：finalize report、
    寫入 part、把 `pending` 轉 `interrupted`；
  - `_resetStreamForRetry` 不要清掉 review report（review 尚未開始）。
- `lib/core/services/api/chat_stream_chunk.dart`：新增 `reviewReport` + copyWith。
- `lib/core/services/agent/agent_orchestrator.dart`：emit `reviewed` / report / durations。
- `lib/core/services/agent/answer_review.dart`：新增 `kReviewPhaseReviewed`。
- `lib/core/services/chat/storage/message_part_codec.dart`：
  `const kAnswerReviewPartKind = 'answer_review';` + report codec helpers。
- `lib/core/services/chat/storage/chat_repository.dart` / `sqlite_chat_storage.dart` /
  `chat_service.dart` / `chat_storage.dart`：upsert + batch load + facade。
- `lib/features/home/controllers/stream_controller.dart`：
  `_answerReviews` map + restore + clear；`StreamingState` 增加 report 欄位。
- 匯出：`lib/features/chat/widgets/message_export_sheet.dart` 新增
  `_ExportReviewCard`（summary；draft/diff 由選項控制）。

### 5.3 檢視資料（view model）

```dart
class AnswerReviewViewData {
  final AnswerReviewReport report;
  final String? draft;        // 完整或截斷
  final String? finalText;    // 訊息 content（用於 diff）
  final bool draftTruncated;
  final bool live;
}
```

- live：從 `StreamingContentData.reviewReport` + `state.fullContentRaw` + notifier。
- restored：從 `message_parts` row + `ChatMessage.content` 組成。
- 同一 message 以 live 優先；terminal 後改用 persisted row。

### 5.4 大小與截斷

- **不設初稿長度上限**：`content` 存完整初稿（初稿是 UI/匯出專用，永不進入
  模型上下文，因此没有理由截斷）。
- `metadata.draftTruncated` 僅保留给舊資料（上限移除前寫入的 row）；新 row 永遠
  是 `false`。卡片對舊 row 仍會顯示「已截斷」並跳過 diff。
- 不在 part 裡存 `revised`（最終答案已在 `messages.content`，避免 2× 重複）。

### 5.5 i18n

4 個 ARB（`app_en`, `app_zh`, `app_zh_Hans`, `app_zh_Hant`）新增：

- `chatAnswerReviewCardTitle` / `chatAnswerReviewStatus*`
- `chatAnswerReviewDraftTitle` / `chatAnswerReviewIssuesTitle` /
  `chatAnswerReviewIssueCount`
- `chatAnswerReviewSeverityBlocker/Major/Minor`
- `chatAnswerReviewLocation/Problem/Fix`
- `chatAnswerReviewDiffTitle` / `chatAnswerReviewDiffSummary` /
  `chatAnswerReviewShowDiff` / `chatAnswerReviewHideDiff`
- `chatAnswerReviewMeta` / `chatAnswerReviewDraftTruncated`
- `chatAnswerReviewNoIssues` / `chatAnswerReviewReviewingHint`
- `chatAnswerReviewCanceled` / `chatAnswerReviewInterrupted`

### 5.6 匯出

- 對話 Markdown / PDF 匯出：加一張「回答審查」卡片（狀態、verdict、issues、+N/−M），
  並**預設包含初稿全文與 diff**（可用匯出選項關閉；舊資料的截斷標註仍保留）。
- 分享單一訊息：同上（預設帶初稿/diff）。
- 匯出只讀 `messages.content` 作為最終答案，初稿/diff 從 review part 取；
  不改變既有匯出格式的其他部分。

---

## 6. 設定與隱私

### 6.1 初稿與模型上下文（重要）

**初稿保存後不會進入後續對話的上下文。** 這是設計保證，不是巧合：

- 初稿只寫入 `message_parts`，`kind='answer_review'`；不是 `messages` 的一列。
- 所有餵給模型的歷史組裝都只讀 `messages.content` + `message_parts.kind='tool'`：
  - `sqlite_chat_storage._reloadToolEvents` 明確 `if (row.kind != kToolPartKind) continue;`
  - `chat_repository.getToolEvents` 明確 `if (row.kind == kToolPartKind)`
  - `getToolPartSummariesForMessages` / `getToolPartsForMessage` 的 SQL 都有
    `kind = 'tool'`
  - `ChatTurnService.buildApiMessages` / `MessageBuilderService.neutralMessagesFor`
    只呼叫 `chatService.getToolEvents(m.id)` 與 `m.content`。
- 同一輪的 review / revision 請求當然會帶初稿（那是審查 prompt 的一部分），
  但那些訊息只存在記憶體、不寫入歷史；回合結束後只剩最終答案會被重放。
- 備份/還原會帶 review part（因為是 message_parts 的一員），但還原後仍不會
  被重放；它只驅動卡片與匯出。

**回歸保護**：P3 必須加一個測試：訊息有一個 `kind='answer_review'` 的 part
時，`buildApiMessages` 的輸出不得包含初稿文字，`getToolEvents` 也不得把它
當成工具事件。

- 新增 `answer_review_details_v1`（bool，預設 `true`）：
  - `true`：保存初稿 + report（卡片重啟後完整）。
  - `false`：只保存 report（verdict/issues/時間）；初稿只在 live 卡片顯示，
    重啟後顯示「初稿未保存」。
- 放在「行為與啟動」頁的 Answer Review 模式下方（與 `answer_review_v1` 同區）。
- 刪除訊息/對話/清除全部對話：`message_parts` cascade，review 紀錄一起刪。
- 備份：parts 已隨備份；若使用者備份很大，提示包含審查詳情。
- 隱私：初稿與 issues 是模型輸出，與訊息同等敏感；不另傳網路。

---

## 7. 邊界案例

| 案例 | 行為 |
|---|---|
| PASS + minor issues | 卡片顯示「已通過」+ minor 清單（muted）；無 diff |
| fail-open（timeout/error/empty/malformed） | 「審查未完成 · 已保留原稿」+ 原因；reviewed=false |
| revision 失敗 | 「修正未完成 · 已保留原稿」；issues 保留；無 diff |
| 使用者在 reviewing/revising 按停止 | 「已取消 · 已保留原稿」；part=interrupted；draft 還原 |
| App crash 在 reviewing | 下次載入 pending → interrupted；不顯示 spinner |
| 主 run L1 retry | draft 清空；review 只在成功的最終輪開始；不重複 part |
| 重新生成/版本切換 | 每個 message id 各自一張卡；切版本跟著換 |
| AI Team / 語音 / 非串流 | 無卡片、無 part |
| 超大初稿/超長 diff | 截斷 + 「顯示全部」；不阻塞渲染 |
| 舊訊息 | 無卡片、無 layout shift |
| smart gate 跳過 | 完全沒有卡片、沒有 part、沒有 group header 摘要 |
| Markdown/HTML 注入 | 初稿用既有 sanitizer；issues 以純文字渲染，不解析 HTML |
| 重複 `reviewed` chunk（理論上不會） | upsert by messageId+kind，不產生重複列 |

---

## 8. 測試計畫

### 8.1 Unit

- `AnswerReviewReport` JSON round-trip（含未知欄位、缺欄位、schemaVersion）。
- 狀態機：reviewing → passed / revising → revised / revision_failed /
  failed_open（4 種原因）/ cancelled / interrupted。
- `draftTruncated` 舊資料相容（`true` 時卡片標註並跳過 diff）。
- 超過 64k 的初稿完整 round-trip（DB ↔ record ↔ 卡片/匯出）。
- `computeUnifiedDiff`：相同、純新增、純刪除、混合、超長截斷。
- Part codec：report ↔ metadata_json；draft ↔ content；status 合法值。

### 8.2 Widget

- 各狀態卡片渲染（header 文案、顏色、icon、issue 數量）。
- 折疊/展開、live 預設展開、終態預設收合、pin。
- 三種 severity 的色票與排序（blocker > major > minor）。
- diff 顯示（+/- 行、行號、截斷提示、無差異文案）。
- restored record（無 live data）渲染。
- 舊訊息（answerReview=null）不渲染卡片。
- 文字縮放 / RTL / 深色主題（至少 smoke）。

### 8.3 Integration

- Orchestrator：PASS / REVISE / fail-open 各自 emit `reviewed` + report；
  revision 成功/失敗的順序與 durations。
- `chat_actions`：reviewing 寫 pending part；reviewed 更新 metadata；
  terminal 完成；cancel/error 轉 interrupted；draft 還原。
- Reload：`_reloadToolEvents` 收集 review rows → 卡片還原；tool 管線不受影響。
- `setToolEvents` / 刪除 / 重寫 parts 不影響 review row。
- 備份/還原：review part 跟著訊息。
- 既有 2,271 tests 全過；`flutter analyze` 0 errors。

### 8.4 手動 soak

- Agnes / DeepSeek 各跑 5 次：PASS、REVISE、fail-open 各至少一次。
- 確認卡片顯示的 diff 與實際修改一致。
- 長回答（>4k 字）與多工具回合的效能。
- 重啟 App 後卡片仍存在且內容一致。

---

## 9. 實作階段

### P1 — 協定與資料（無 UI）

- `AnswerReviewReport` model（純 Dart）。
- `ChatStreamChunk.reviewReport` + `kReviewPhaseReviewed`。
- Orchestrator emit `reviewed` / fail reasons / durations。
- 單測：report、orchestrator 順序。

### P2 — Live 卡片（不持久化）

- `AnswerReviewCard` + diff widget。
- `StreamingContentData.reviewReport` + notifier 更新。
- `ChatMessageWidget` 接線；移除 `_ReviewIndicator`。
- l10n × 4 + gen-l10n。
- Widget tests。

### P3 — 持久化與還原

- `message_parts` kind + repository/storage/service upsert + batch load。
- `StreamController._answerReviews` + restore。
- chat_actions 寫入時機（pending/completed/interrupted）。
- cancel/crash 正規化；備份/匯出審計。
- Integration tests。

### P4 — Diff、meta、polish

- diff 區塊（重用 `computeUnifiedDiff`）、+N/−M、截斷。
- 時間/usage/model meta。
- 匯出 summary。
- 折疊/pin/autoCollapse 整合。
- 效能與 soak。

---

## 10. 風險與開放問題

### 風險

1. **`message_parts` 語意**：新增非 tool kind 需全面審計讀寫；
   `setToolEvents` 的刪除/重寫必須只針對 `kind='tool'`（最高風險）。
2. **DB 成長**：初稿 ≈ 答案大小，等於 2×；依使用者要求**不設上限**（初稿不進
   上下文，換取完整可追溯性）。備份檔案也會跟著變大。
3. **Rebuild 頻率**：只在 phase 變更時更新 notifier，避免每 chunk 重建卡片。
4. **大 diff 效能**：hunk/位元組上限 + 只渲染可見部分。
5. **備份/匯出相容**：parts 若未整表帶，需補；舊備份沒有 review part 也要能讀。
6. **崩潰一致性**：pending part 與 crash recovery 的時序；載入時正規化為 interrupted。
7. **隱私/大小**：使用者可能不想把初稿留在 DB；提供關閉選項。

### 已拍板（2026-11-09）

1. 卡片位置：**process group 內**（group header 保留摘要）。
2. 終態預設收合；跟隨 process group 的 pin / autoCollapse。
3. 初稿預設保存（**完整初稿，無長度上限**）；**不會進入後續對話上下文**（見 §6.1）。
4. minor issues 顯示但低調（muted、排序在後）。
5. 匯出包含初稿/diff（預設開啟，可用選項關閉）。
6. smart gate 跳過時不顯示任何「未審查」卡片或 part。

### 驗收條件（Definition of Done）

- 任一 reviewed 回覆在串流中能看到「初稿 → 審查中 → 結果 → 修正中 → 完成」
  的卡片，且答案區不會在修正前丢失初稿。
- 重啟 App 後同一張卡片仍在，內容與最終答案一致。
- PASS / REVISE / fail-open / cancel / crash 五種路徑都有對應狀態與測試。
- 工具卡片、replay、審批、備份、匯出、AI Team、語音皆無回歸。
- `flutter analyze` 0 errors；全測試通過（含新增案例）。

---

## 11. 實作記錄（2026-11-09）

### 已完成

- **報告模型**：`lib/core/models/answer_review.dart` 新增 `ReviewIssue`、
  `AnswerReviewReport`（verdict/issues/timings/tokens/failReason/truncation）、
  `AnswerReviewRecord` 與 `AnswerReviewPhase`；`AnswerReviewMode` 不變。
- **協定**：`ChatStreamChunk.reviewReport`；orchestrator 在 verdict 後發
  `reviewed`（PASS/REVISE/fail-open 都送），terminal 帶最終 report；
  fail-open 原因為 `timeout`/`error`/`empty`/`malformed`/`revision_failed`、
  `revision_paused`（revision 工具待審批），以及 `revision_tool_call`
  （revision 吐出工具呼叫 markup）。
- **持久化**：`message_parts.kind='answer_review'`（ordinal 1e9，一訊息一列），
  `content` = 初稿（完整、無上限）、`metadata_json` = report、`status` =
  pending/completed/interrupted。`replaceToolEvents` 只選/刪/改 `kind='tool'`，
  `_nextPartOrdinal` 也只計算 tool rows；crash repair 會把 pending review row
  寫回 interrupted。
- **上下文隔離**：所有 replay 路徑仍只讀 `messages.content` +
  `message_parts.kind='tool'`；review part 不會進 `buildApiMessages`、
  `getToolEvents` 或工具摘要。新增回歸測試。
- **UI**：`AnswerReviewCard` 放在 `ProcessGroupCard.children` 最後一列；group
  header 顯示低調 review 摘要；初稿、issues（blocker/major/minor，minor muted）、
  diff（`computeUnifiedDiff`）、meta。串流中展開、終態預設收合，跟隨 group 的
  pin/autoCollapse。
- **狀態收尾**：finish / error / stream-done / cancel 都會 finalize 卡片；
  terminal report 不會被 late error/onDone 降級；失敗保留 draft。
- **匯出/備份**：單訊息與整段對話的 Markdown/TXT 帶入初稿+diff；圖片/PDF 卡
  片在「顯示思考與工具卡片」開啟時一起渲染。備份 v3 新增可選
  `answerReviews`（舊備份沒有此 key 仍可還原）。
- **測試**：新增 `test/answer_review_card_persistence_test.dart`（report JSON、
  review part 耐久性、tool rewrite 隔離、pending→interrupted、process group
  visibility）；orchestrator review 測試補上 report/phase/failReason 斷言。
  全量 `flutter test`：2,261 通過、2 個既有 `sqlite_chat_storage_test`
  失敗（乾淨樹同樣失敗）、2 skipped；`flutter analyze` 0 errors。

### 2026-11-09 hotfix（實測失敗）

實際案例：助手 system prompt 要求 `image_search`，但該助手／對話沒有掛載 Image_Search
MCP server；reviewer 把「缺少圖片」判為 major → revision 想呼叫 `image_search`，
在 text-only 回合吐出 `<tool_call>` / DeepSeek DSML 原文，最後被當成答案存下，
覆蓋真正的初稿。

修正（2026-11-09 設計修正）：

- **review 仍維持 text-only**：reviewer 可以指出「缺少工具使用」是真 issue，
  但自己不可呼叫工具。
- **不再過濾工具依賴的 issue**：`ReviewIssue.requiresToolCall` 與 parser 的
  tool-issue filter 已移除；`image_search`／補圖等 finding 會正常觸發 revision。
- **revision 改為完整 agent loop**：沿用主 run 的 tools、`onToolCall`、
  `webFetchEnabled` 與 `extraBody`，可多輪呼叫工具；每個工具輪的 preamble 在
  round boundary 丟棄，只有最後一輪正文成為修正答案。工具卡照常即時顯示與
  持久化。
- **revision 專用 hooks**：不覆寫主 run 的 checkpoint journal；只在 revision
  工具落入審批 Pending 時，於下一輪前停止並 fail-open（`revision_paused`），
  避免未批准的呼叫繼續送出。
- `containsToolCallMarkup` 保留為 malformed-output 防線：revision 若把
  `<tool_call>`、`<function=`、`<parameter=` 或 `｜｜DSML｜｜` 當正文吐出，
  仍 fail-open 保留原 draft，report `failReason='revision_tool_call'`。
- 新增 parser / orchestrator 回歸測試（工具 issue 保留、revision 工具 loop、
  審批暫停、markup fail-open、revision wire 契約帶 tools）。

### 已知限制 / 後續

- 初稿目前一律保存（**完整、無上限**），尚未提供 `answer_review_details_v1`
  關閉選項；隱私敏感使用者可先關閉 review 模式。DB/備份大小會隨初稿線性成長。
- 卡片在 process group 收合時只剩 header 摘要；要看完整 issues/diff 需展開
  group + 卡片（終態卡片預設收合）。
- revision 失敗／暫停時，已執行的 revision 工具卡與副作用不會回滾；pending 的
  approval 會在 fail-open 前自動 denied，但已完成的工具仍留在 process group。
- P7 soak 未跑：需用 Agnes/DeepSeek 各跑 PASS/REVISE/fail-open，確認卡片顯示
  的 diff 與實際修改一致。
