# OmniChat 回答前審查（Answer Review v1）實作計畫

> **版本**：v1.2（2026-11-08；v1.1 規劃完成後**已實作**（P2–P6），補實作紀錄 §17）
> **狀態**：**已實作**（P7 Soak 待跑：預設 off，手動開啟驗證品質／成本）
> **決策**：採用 **C（driver-level review phase）**；**F-lite** 列為未來品質升級；**`request_review` 工具版淘汰**
> **基準**：OmniChat v1.27.0（`pubspec 1.27.0+110`）
> **上游需求**：模型在輸出最終回答前先 review，必要時修正，以提升回答品質；功能可開關；只套用串流主對話與一般聊天。

---

## 執行進度

| 階段 | 內容 | 狀態 |
|:--|:--|:--|
| P0 | 決策收斂、方案比較、契約設計 | ✅ 2026-11-08 |
| P1 | 本計畫文件 | ✅ 2026-11-08 |
| P2 | 純邏輯層：mode、gate、prompt、verdict parser、usage 合併 | ✅ 2026-11-08（`answer_review_test.dart` 21 案） |
| P3 | Orchestrator review phase＋chunk 契約 | ✅ 2026-11-08（`agent_orchestrator_review_test.dart` 19 案，含 capture server wire 驗證） |
| P4 | UI 狀態機＋StreamingState／Notifier／Indicator | ✅ 2026-11-08（`answer_review_stream_state_test.dart`） |
| P5 | 設定頁、l10n、同步鍵 | ✅ 2026-11-08（`settings_provider_answer_review_test.dart`） |
| P6 | 測試矩陣、provider smoke、文件與手冊 | ✅ 2026-11-08（手冊 §3.14 §9／§4 ADR-A10／§5.7／§7.2；全測試套 2,269 綠、僅 2 個既有 sqlite 失敗與本功能無關） |
| P7 | Soak（預設 off，手動開啟驗證品質／成本） | ⬜ |

---

## 0. 決策摘要

### 0.1 為什麼是 C

**C ＝ 在 `AgentOrchestrator` 的 `AgentRunFinishedEvent(finished)` 之後，由 harness 觸發一次同模型 review。**

- 模型先正常串流 draft 給使用者看。
- harness 在背景累積「最後一輪」的完整文字。
- draft 完成後，harness 把 draft 與 review rubric 送給同一模型（同一 system prompt、同一份 working messages）。
- reviewer 回傳 `PASS`／`REVISE`。
  - `PASS`：原 draft 直接放行，不再生成一次。
  - `REVISE`：帶著 blocker／major issues 重寫**一次**，串流替換原 draft。
- 整個流程只產生一個 terminal `isDone`；review／revision 的 usage 併入終態。

這個方案同時滿足：

| 需求 | C 的答案 |
|:--|:--|
| 回答前 review | harness 在 `finished` 後、terminal 前執行 |
| 必要時修正 | 只有 `REVISE` 才重寫一次 |
| 可開關 | `answer_review_v1` = `off`／`smart`／`always` |
| 只套用一般聊天 | 主聊天路徑顯式開啟；AI Team、語音路徑 opt-out |
| Token 成本最低 | 只在 REVISE 時重寫；不吃第二次 draft 生成 |
| 使用者只看到正常回答 | review 是內部請求，不進對話歷史、不產生工具卡 |

### 0.2 三個方案的定位

| 代號 | 本質 | 誰觸發 | 保證 review | 成本 | 結論 |
|:--|:--|:--|:--:|:--|:--|
| **C** | harness review phase＋同模型 reviewer | harness | 是 | 最低 | **v1 採用** |
| **F-lite** | 同一個 flow＋獨立 reviewer profile／模型 | harness | 是 | 較高 | **未來疊加** |
| **`request_review`** | 把 reviewer 包成工具，模型自行呼叫 | 模型 | 否 | 最高 | **淘汰** |

> 重要：**C 和 F-lite 不是兩個流程**。F-lite 是 C 的同一個 review phase 換 reviewer（獨立 prompt、策展歷史、可選模型）。所以先做 C，未來升級 F-lite 不需要重寫 orchestration。

### 0.3 Token 成本結論（決策依據）

在「每個答案都被 review」的前提下：

```text
C            = 一次 context pass + 短 verdict；只有 REVISE 才再生成一次答案
request_review = draft 先寫進 tool arguments（生成一次）＋ review ＋ 最終答案再生成一次
                 ＋ draft 與 issues 永久留在對話歷史，之後每輪重讀
```

- **Output 成本**：`request_review − C = (1 − r) × D`，其中 `r` 是 C 的修正率。C 通常 `r << 1`；`request_review` 等於每次都重寫。
- **Input 成本**：C 可命中主對話的 prompt cache（system prompt 不變）；`request_review` 的 reviewer prompt 通常 miss。
- **歷史膨脹**：`request_review` 會把 draft（tool args）與 issues（tool result）留在歷史；C 不落庫。
- **可預測性**：C 是「固定一次 review＋依 `r` 決定的修正」；`request_review` 取決於模型呼叫率，而呼叫率不保證。

> 一句話：**C 是「寫一次，有問題才重寫」；`request_review` 是「寫兩次，再看要不要改」。**

---

## 1. 範圍

### 1.1 In scope（v1）

- `AgentOrchestrator` 的 `finished` 路徑新增 review phase。
- 同一模型、同一 system prompt、同一份 working messages（`AgentRunFinishedEvent.messages`）。
- `PASS` 放行；`REVISE` 最多重寫一次。
- `off`／`smart`／`always` 三態設定，預設 `off`。
- 串流 UI 的「審查中／修正中／審查未完成」狀態。
- Token usage 合併、fail-open、取消時保留 draft。
- AI Team、語音、語音聽寫維持 opt-out。
- 單元測試、orchestrator 測試、設定測試、手冊更新。

### 1.2 Out of scope（v1）

- 多輪 review／多輪修正（v1 最多一次）。
- 獨立 reviewer prompt／獨立 reviewer 模型（F-lite，見 §14）。
- `request_review` 工具（淘汰，見 §15）。
- 子代理（P2-3）runtime。
- AI Team proposer／critic／aggregator 的 review。
- 語音通話、語音聽寫。
- Review 結果持久化（不寫入訊息、不寫入 Hive/SQLite）。
- Reviewer 的 UI 設定頁（模型、prompt、focus）。
- 將 review 的 reasoning 顯示給使用者。

### 1.3 適用路徑矩陣

| 路徑 | 進入點 | v1 行為 |
|:--|:--|:--|
| 串流主聊天 | `chat_actions._executeGeneration(ctx)`（四個一般呼叫端） | 依 `answer_review_v1` 套用 |
| 非串流主聊天 | 同上，但 `ctx.streamOutput == false` | **不 review**（v1 只支援串流） |
| AI Team proposer／critic | `_runProposerSilent`（orchestrator `run` 未傳 review config） | 預設 `off` |
| AI Team aggregator | `_executeGeneration(aggCtx, enableAnswerReview: false)` | **強制 off**（見 §10 陷阱） |
| 語音通話 | `chat_turn_service.startTurn` → `_orchestrator.run` | 顯式 `AnswerReviewConfig.off()` |
| 語音聽寫 | 不經過 `AgentOrchestrator` | 不受影響 |
| 標題／翻譯／OCR／記憶整理 | 各自服務，不經過主 generation 路徑 | 不受影響 |

---

## 2. 架構定位

```text
chat_actions._executeGeneration
  │
  ├─ ctx.settings.answerReviewMode ──▶ AnswerReviewConfig
  │
  ▼
AgentOrchestrator.run(answerReview: config)
  │
  ├─ kernel round 1..N ──▶ transport chunks ──▶ UI（正常串流）
  │
  ├─ AgentRunFinishedEvent(reason: finished, messages, executedCallCount)
  │     │
  │     ├─ draft = 最後一輪 content buffer
  │     ├─ gate（off / smart / always）
  │     │
  │     ▼
  │   review call（sendRoundImpl）
  │     ├─ messages = event.messages + <draft> + rubric
  │     ├─ tools: null
  │     ├─ streamOutput: false
  │     ├─ webFetchEnabled: false
  │     └─ extraBody 剝除 tools / stream / messages ...
  │     │
  │     ▼
  │   verdict parser
  │     ├─ PASS ──▶ 放行 held terminal（reviewed=true）
  │     └─ REVISE ──▶ revision call（text-only, stream）
  │                     ├─ 成功 ──▶ 合成 terminal（reviewed=true）
  │                     └─ 失敗 ──▶ 還原 draft（reviewed=false）
  │
  └─ 一個 terminal isDone
```

**責任邊界：**

| 層 | 責任 |
|:--|:--|
| `AgentLoop` kernel | 只負責工具迴圈；不知道 review 存在 |
| `AgentOrchestrator` | draft capture、terminal 緩衝、review call、verdict、revision、usage 合成 |
| `AnswerReview*`（新） | mode／gate／prompt／parser／message shape／body sanitize |
| `chat_actions` | 開關注入、UI 狀態、持久化、取消還原 |
| `StreamingContentNotifier` / `message_list_view` | 顯示「審查中／修正中／審查未完成」 |
| `SettingsProvider` | `answer_review_v1` 持久化與同步 |

---

## 3. 使用者可見行為

### 3.1 三種模式

| 模式 | 行為 | 額外請求 |
|:--|:--|:--|
| `off`（預設） | 與現在完全相同；不累積 draft、不緩衝 terminal、不改 UI | 0 |
| `smart` | 只有「值得審查」的答案才 review（見 §4.4） | 0 或 1 次 review（＋必要時 1 次 revision） |
| `always` | 每個非空 final answer 都 review | 1 次 review（＋必要時 1 次 revision） |

### 3.2 三種結局

1. **PASS（最常見）**
   - Draft 已完整顯示。
   - 短暫顯示「審查回答中…」。
   - 之後直接結束，文字完全不變。
2. **REVISE → 修正成功**
   - 顯示「審查回答中…」。
   - 顯示「正在修正回答…」，草稿文字暫時清空（工具卡、usage、totalTokens 保留）。
   - 修正版逐字串流取代草稿。
3. **Fail-open（review 失敗／逾時／解析失敗／修正失敗）**
   - 顯示「審查未完成，已保留原回答」（或直接結束）。
   - 保留原 draft；使用者不會看到錯誤 JSON、也不會失去答案。

### 3.3 使用者不會看到什麼

- 不會看到 review JSON、issues、reviewer prompt。
- 不會多一張 `request_review` 工具卡。
- 不會看到第二次完整 draft 被放進對話歷史。
- 不會看到兩個 `isDone`、重複的標題生成或重複的 summary 觸發。

---

## 4. 設定

### 4.1 Key 與 schema

```text
SharedPreferences key: answer_review_v1
型別: String
值: "off" | "smart" | "always"
預設: "off"
非法值: 回退 "off"
```

- 由 `AnswerReviewModeCodec.fromValue()` 解析；未知字串一律 `off`。
- **不列入 `_localOnlyKeys`**：這是使用者偏好，應隨備份跨裝置同步。
  - 手冊 §5.7 的「未來新增裝置私有偏好」規則不適用；此鍵屬於「使用者意圖」類，與 `developer_mode_v1` 同類。
- 不做一次性遷移（新鍵，缺省即 `off`）。

### 4.2 `SettingsProvider` 落點

- 常數：`static const String _answerReviewModeKey = 'answer_review_v1';`
- 欄位：`AnswerReviewMode _answerReviewMode = AnswerReviewMode.off;`
- Getter：`AnswerReviewMode get answerReviewMode => _answerReviewMode;`
- Setter：
  ```dart
  Future<void> setAnswerReviewMode(AnswerReviewMode mode) async {
    if (_answerReviewMode == mode) return;
    _answerReviewMode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_answerReviewModeKey, mode.value);
  }
  ```
- 載入：放在 behavior/display 設定的載入區（`autoCollapseThinking`／`replayToolResults` 附近）：
  ```dart
  _answerReviewMode = AnswerReviewModeCodec.fromValue(
    prefs.getString(_answerReviewModeKey),
  );
  ```
- `copyWith`：加入 `AnswerReviewMode? answerReviewMode`，並 `copy._answerReviewMode = answerReviewMode ?? _answerReviewMode;`
- `updateSettings`：**不需要**加入（備份還原走原始 prefs snapshot；`updateSettings` 目前只服務 search 頁）。若未來 `updateSettings` 成為通用套用入口，再補。

### 4.3 設定 UI

位置：`display_settings_page.dart` 的 `BehaviorStartupSettingsPage`（行為與啟動頁）。

樣式：沿用 Android 背景聊天模式的「導航列＋底部選單」模式：

```text
[icon] 回答前審查                 智慧 >
       在最終回答送出前檢查草稿；發現重大問題時自動修正一次
```

點擊後以 `showModalBottomSheet` 顯示三個選項：

- 關閉（off）
- 智慧（smart）— 只在值得審查時執行
- 每次（always）— 每個回答都審查

底部選單需附一段說明：

> 審查會多一次模型請求，可能增加延遲與 token 費用。`智慧` 只在有工具結果、長回答、程式碼、數字或 URL 時執行。

`detailBuilder` 顯示目前模式（關閉／智慧／每次）。

### 4.4 Smart 模式 gate

```text
進入 review 的條件（全部成立）：
1. mode == smart
2. draft.trim().isNotEmpty
3. 以下任一：
   a. executedCallCount > 0（有工具結果作為證據）
   b. draft.length >= 600（長回答）
   c. draft 含 code fence（```）
   d. draft 含 URL（http:// 或 https://）
   e. draft.length >= 200 且含 >= 2 個數字或 >= 1 個百分比
```

- 門檻集中定義在 `answer_review.dart` 的常數，方便 soak 後調整。
- `always` 只要求 `draft.trim().isNotEmpty`。
- `off` 永遠不 review。
- 不因 `executedCallCount > 0` 就跳過極短答案：工具輪的簡短結論仍會 review，避免工具結果被錯誤摘要。沒有工具時的短招呼／純語氣回覆才會跳過。

---

## 5. 流程與不變量

### 5.1 主流程

```text
run()
  working = kernel messages
  draft = StringBuffer()
  heldTerminal = null
  reviewUsage = TokenUsage()

  for event in kernel:
    case AgentStreamEvent(chunk):
      if chunk.errorKind != null:          // 主 run 的 L1 retry
        draft.clear()
        heldTerminal = null
      if chunk.isDone:
        // 每一輪 transport 都會發自己的 terminal（工具輪也有）。UI 今天
        // 靠 `_handleStreamFinish` 的 hasLoadingTool guard 吞掉工具輪的
        // terminal；這裡改成「全部扣住、逐輪覆蓋」，效果等價：
        //   - guard 早返只有兩個副作用：append terminal 內容（改由
        //     content-only chunk 承擔）、Usage 合併（guard 在 usage 合併
        //     之前早返，所以工具輪 terminal 本來就沒進 state.usage）。
        //   - 最後一輪的 terminal 覆蓋先前被扣住的工具輪 terminal。
        if chunk.content.isNotEmpty:
          draft.write(chunk.content)
          yield content-only chunk
        heldTerminal = chunk.withoutContent()   // hold-latest
      else:
        if chunk.content.isNotEmpty: draft.write(chunk.content)
        yield chunk

    case AgentRoundFinishedEvent():
      // 工具輪結束：preamble 不是 final answer，清空 draft
      draft.clear()

    case AgentRunFinishedEvent(reason, messages, executedCallCount, tokensUsed):
      if reason != finished:
        heldTerminal = null              // 丟棄被扣住的工具輪 terminal
        yield earlyStopTerminal(tokensUsed, reason)   // 不 review
        return

      if heldTerminal == null:
        // 異常：transport 沒給 terminal；合成一個，跳過 review
        yield ChatStreamChunk(isDone: true, totalTokens: tokensUsed)
        return

      if !shouldReview(mode, draft, executedCallCount):
        yield heldTerminal.withReview(reviewed: false)
        return

      yield reviewStatus('reviewing')
      reviewResult = await runReview(...)              // fail-open
      reviewUsage = reviewUsage.sum(reviewResult.usage)

      if reviewResult.verdict != revise:
        yield heldTerminal.withReview(reviewed: true, reviewUsage: reviewUsage)
        return

      yield reviewStatus('revising')
      revisionResult = await runRevision(...)          // fail-open
      reviewUsage = reviewUsage.sum(revisionResult.usage) // 失敗也計入已消耗的 tokens

      if revisionResult.ok:
        yield finalTerminal(
          usage: usageBase(§8.4).sum(reviewUsage),  // base=held.usage??0；total=max(held.total, tokensUsed)
          reviewed: true,
        )
      else:
        yield reviewStatus('revision_failed')
        yield ChatStreamChunk(content: draft, replaceContent: true, ...)
        yield heldTerminal.withReview(reviewed: false, reviewUsage: reviewUsage)
```

**Review／revision 呼叫的逾時語意：**

- **預設不設逾時**（`reviewTimeout = null`）：審查／修正跑到 provider 自然結束，或使用者按停止（`cancelStreaming` 會 cancel `{cid}_review`）。
- 若 config 明確設定 `reviewTimeout`，以 `Future.timeout` 加在「收集完整回應」上；逾時視為 fail-open，並 **cancel 內部 transport stream 的訂閱**（`await for` 逾時不會自動取消），否則 provider 的請求會在背景續跑、燒 token。`runReview` / `runRevision` 內先 `sub.cancel()` 再回傳 fail-open 結果。

### 5.2 不變量（實作時逐條檢查）

1. **只有 `AgentRunStopReason.finished` 才 review。**
   - `maxStepsReached`、`tokenBudgetReached`、`stoppedByHook`（審批暫停）一律跳過。
2. **整個 run 只發一個 terminal `isDone`。**
   - 每一輪 transport（含工具輪）都會發自己的 terminal；orchestrator 全部扣住、逐輪覆蓋（hold-latest），不轉發任何一個。
   - revision 的 terminal 也不直接轉發；`reason != finished` 時丟棄被扣住的 terminal；最後只合成一個。
3. **Review／revision 都是 text-only。**
   - `tools: null`、`webFetchEnabled: false`。
   - `extraBody` 剝除：`tools`、`tool_choice`、`functions`、`function_call`、`parallel_tool_calls`、`tool_config`、`tools_config`、`web_search_options`、`web_search`、`search`、`stream`、`model`、`messages`、`input`。
   - 不呼叫 hooks、不寫 checkpoint、不觸發審批、不執行任何工具。
4. **Draft 只取最後一輪。**
   - 工具輪的 preamble 不進 draft；每次 `AgentRoundFinishedEvent`（工具輪結束）清空 draft。
   - 主 run 的 L1 retry 也清空 draft。
5. **PASS 不改文字。**
   - 不重新生成、不重新持久化 draft。
6. **REVISE 最多一次。**
   - 修正失敗不重試第二次；fail-open 保留 draft。
7. **Fail-open。**
   - review 失敗、逾時、解析失敗、verdict 無 blocker/major、revision 回空、revision 截斷、revision 丟錯 → 保留 draft，照常結束。
8. **Review／revision 訊息不落庫。**
   - 只存在記憶體；不進 `event.messages`、不進 Hive/SQLite、不進下一輪對話。
9. **Usage 只計一次。**
   - 每個 review/revision 呼叫取「最後一個 usage 快照」或最大 `totalTokens`，不要逐 chunk 累加（避免串流 usage 重複）。
   - 終態 usage = 主 run terminal usage ＋ review usage ＋ revision usage。
   - `reviewUsage` 是終態 usage 的**子集**，只供顯示／log；UI 不可再加總一次。
10. **取消時保留 draft。**
    - `revising` 清空 UI 前把 draft 備份到 `ReviewStreamState`。
    - 取消／done／error 時若仍在 revising，還原備份再持久化。
11. **AI Team／語音 opt-out。**
    - Aggregator 走 `_executeGeneration(..., enableAnswerReview: false)`。
    - Proposer 不傳 config（預設 off）。
    - 語音 `chat_turn_service` 顯式 `AnswerReviewConfig.off()`。
12. **非串流不 review。**
    - `ctx.streamOutput == false` 時直接 off。
13. **標題／summary 只觸發一次。**
    - 只有最終 terminal 會進 `_handleStreamFinish` → `_finishStreaming`。

### 5.3 與 L1 retry 的互動

| 階段 | 行為 |
|:--|:--|
| 主 run 的 final round retry | transport 送 `errorKind` chunk；orchestrator 清空 draft；UI 走既有 `_resetStreamForRetry`（會清 usage/totalTokens）；重試成功後重新累積 |
| Review 內部 retry | 由 transport 的 L1 retry 處理；orchestrator 只收到最終結果，不轉發 retry 狀態給 UI |
| Review／revision 逾時 | 預設無逾時；設定 `reviewTimeout` 時由 `Future.timeout` 判定 fail-open，**並 cancel 內部 transport 訂閱**，避免請求背景續跑 |
| Revision 內部 retry | orchestrator 丟棄 retry 狀態 chunk，送 `replaceContent: true, content: ''` 讓 UI 清掉半截修正文字；不清主 run 的 usage/totalTokens/tool cards |

> 不要讓 revision 的 `errorKind` chunk 直接進 `_handleStreamChunk`：那會觸發 `_resetStreamForRetry`，把主 run 的 usage、totalTokens 清掉。

### 5.4 與審批／checkpoint 的互動

- Review 只發生在 `finished`，此時本 run 的工具都已執行完畢、審批卡已解決。
- Review／revision 沒有 tools，因此不可能產生新的審批或 checkpoint。
- `stoppedByHook`（審批暫停）直接跳過 review；恢復後是新的 run，重新累積。

---

## 6. Prompt 與 rubric

### 6.1 設計原則

- **同一個 system prompt**：C 不換 persona，reviewer instruction 放在最後一則 user message。
  - 好處：主對話前綴可命中 prompt cache。
  - 壞處：同模型自我審查容易放水；用嚴格 rubric 與 severity gate 緩解。
- **只檢查四類**：正確性、需求覆蓋、內在一致性、安全/格式。
- **不檢查**：語氣、風格、冗長度、可選改進。
- **不回傳 rewrite**：只回 issues；避免 reviewer 直接改寫造成 uncontrolled diff。
- **JSON only**：方便解析；parser 仍容忍純文字 PASS/REVISE。
- **嚴重度先行**：只有 blocker／major 才觸發修正；minor 不造成改寫。

### 6.2 Reviewer instruction（摘要）

完整 prompt 見 Appendix A。重點：

```text
[ANSWER REVIEW — internal]
You are auditing your own draft answer before it is shown to the user.
...
Return exactly one JSON object:
{"verdict":"pass"|"revise","issues":[...]}
```

### 6.3 Revision instruction（摘要）

完整 prompt 見 Appendix B。重點：

- 只修 blocker／major。
- 最小變動，保留正確內容、語言、結構、格式。
- 輸出完整答案，不要 diff、不要 preamble。
- 不要提到 review／reviewer／issues。
- 不要發明新事實、數字、引用或工具結果。

### 6.4 Severity 定義

| Severity | 定義 | 是否觸發修正 |
|:--|:--|:--:|
| `blocker` | 事實錯誤、與工具結果/對話矛盾、違反明確要求、危險內容 | ✅ |
| `major` | 缺少必要需求、關鍵主張無證據、結論不連貫且改變答案 | ✅ |
| `minor` | 純粹用詞、語氣、格式偏好、可選改進 | ❌ |

---

## 7. Verdict parser

### 7.1 回傳 schema

```json
{
  "verdict": "pass",
  "issues": []
}
```

```json
{
  "verdict": "revise",
  "issues": [
    {
      "severity": "blocker",
      "location": "第 2 段「...」",
      "problem": "與工具結果矛盾：...",
      "fix": "改成 ..."
    }
  ]
}
```

### 7.2 Tolerant 解析演算法

```text
1. 去除 markdown code fence（```json ... ```）
2. trim
3. 找第一個 '{' 與最後一個 '}'，嘗試 jsonDecode
4. 解析成功：
   - verdict 正規化：pass / revise（大小寫不敏感）
   - issues 逐筆解析 severity / location / problem / fix
   - severity 未知 → major（保守）
5. 解析失敗：
   - 若文字中含獨立單詞 "REVISE" → revise（但 issues 空 → 視為 pass）
   - 若含獨立單詞 "PASS" → pass
   - 其他 → pass（fail-open）
6. Severity gate：
   - 有任何 blocker 或 major → revise
   - 只有 minor / 無 issues → pass（即使 verdict 寫 revise）
7. 限制：
   - issues 最多取前 6 筆
   - location ≤ 200 字、problem ≤ 300 字、fix ≤ 300 字
   - 原始回應最多解析 20,000 字
```

### 7.3 為何「只有 minor 也 pass」

Reviewer 很容易把「可以更好」寫成 issue。若 minor 也觸發重寫，會造成：

- 不必要的 token 成本；
- 每次回答都被小幅改寫，品質不穩定；
- 使用者看到文字閃動。

因此 v1 只修 blocker／major。若 soak 後發現 reviewer 過度回報 minor，調整 rubric，而不是放寬 severity gate。

### 7.4 解析失敗的處理

- **一律 fail-open 當 PASS**，保留 draft。
- 寫 log：`answer_review.parse_failed rawLength=...`
- 不把 raw review 文字顯示給使用者。

---

## 8. Chunk 契約

### 8.1 新增欄位（`ChatStreamChunk`）

| 欄位 | 型別 | 預設 | 語意 |
|:--|:--|:--|:--|
| `reviewPhase` | `String?` | `null` | `'reviewing'`／`'revising'`／`'revision_failed'`；只出現在 status chunk，`isDone: false`、`content: ''` |
| `replaceContent` | `bool` | `false` | 為 `true` 時，`content` 取代目前累積的文字，而不是 append；用於 fail-open 還原 draft |
| `reviewed` | `bool` | `false` | 只出現在 terminal；`true` = review 完成且最終答案已套用（PASS 或成功修正） |
| `reviewUsage` | `TokenUsage?` | `null` | 只出現在 terminal；review＋revision 的 usage，**已包含在 `usage` 內**，僅供顯示／log |

**不改既有欄位語意。** `content`、`usage`、`totalTokens`、`isDone`、`toolCalls`、`toolResults`、`softStopReason` 全部維持原契約。

### 8.2 `copyWith`

`ChatStreamChunk` 目前沒有 `copyWith`。新增：

```dart
ChatStreamChunk copyWith({
  String? content,
  String? reasoning,
  bool? isDone,
  int? totalTokens,
  TokenUsage? usage,
  List<ToolCallInfo>? toolCalls,
  List<ToolResultInfo>? toolResults,
  String? errorKind,
  int? attempt,
  int? maxAttempts,
  int? nextRetryInMs,
  String? finishReason,
  bool? hasUsage,
  Map<String, dynamic>? assistantExtras,
  String? softStopReason,
  String? reviewPhase,
  bool? replaceContent,
  bool? reviewed,
  TokenUsage? reviewUsage,
})
```

> 只需要覆寫用得到的欄位；不支援把欄位設回 `null`（本流程不需要）。

### 8.3 Chunk 序列

**PASS**

```text
content chunk(s) ...           // 正常串流
reviewPhase: reviewing         // isDone=false, content=''
terminal                       // isDone=true, reviewed=true, usage=main+review
```

**REVISE 成功**

```text
content chunk(s) ...
reviewPhase: reviewing
reviewPhase: revising          // UI 清空草稿、備份、保留工具卡
content chunk(s) ...           // 修正版（逐字）
terminal                       // isDone=true, reviewed=true, usage=main+review+revision
```

**Fail-open（review 階段）**

```text
content chunk(s) ...
reviewPhase: reviewing
terminal                       // isDone=true, reviewed=false, usage=main+review
```

**Fail-open（revision 階段）**

```text
content chunk(s) ...
reviewPhase: reviewing
reviewPhase: revising
[content chunk(s) ...]         // 可能已有半截修正
reviewPhase: revision_failed
content: <original draft>, replaceContent: true
terminal                       // isDone=true, reviewed=false, usage=main+review+revision
```

**早停（max steps／budget／hook）**

```text
terminal                       // softStopReason=max_steps|token_budget|null
                               // reviewPhase=null, reviewed=false
```

### 8.4 Usage 語意

- `terminal.usage` = 主 run 基準 usage ＋ review usage ＋ revision usage。
- **主 run 基準**：`heldTerminal.usage ?? TokenUsage()`。`heldTerminal` 是最後一輪的
  transport terminal；`heldTerminal.usage == null` 時以零值起步（只有 review/revision
  usage 進終態，避免 NPE 與虛增）。
- **基準 totalTokens 取 `max(heldTerminal.totalTokens, tokensUsed)`**（`tokensUsed` 是
  kernel 在 `AgentRunFinishedEvent` 交出的多輪累計值）：
  - 單輪 run 兩者相等，行為不變；
  - 多輪（工具）run 下 transport terminal 只帶最後一輪的 usage，kernel 累計值才是
    全 run 的真實總量——與早停 terminal（已使用 `tokensUsed`）一致。
- `terminal.totalTokens` = 基準 total ＋ reviewUsage.total（若為 0 則用 `prompt + completion`）。
- `promptTokens`／`completionTokens`／`cachedTokens`：基準 usage ＋ reviewUsage 逐欄相加
  （`sum()`）；persisted usageMeta（成本）由 `MessageUsage.accumulate` 合併，代表實付總額。
- `terminal.reviewUsage` = review＋revision 的子集；**不要**在 UI 再加總。
- `withReview(reviewed:, reviewUsage:)` / `finalTerminal` 合成 helper：terminal 的
  usage 與 totalTokens 一律以本節基準（§8.4）與 reviewUsage 用 `sum()` 組成；
  `reviewUsage` 只是順帶輸出的子集欄位。PASS／fail-open／修正成功三種 terminal 相同。
- `TokenUsage` 新增 `sum()`（逐欄相加、`MessageUsage.accumulate` 合併成本）：
  ```dart
  TokenUsage sum(TokenUsage other) {
    final p = promptTokens + other.promptTokens;
    final c = completionTokens + other.completionTokens;
    final t = totalTokens + other.totalTokens;
    return TokenUsage(
      promptTokens: p,
      completionTokens: c,
      cachedTokens: cachedTokens + other.cachedTokens,
      totalTokens: t > 0 ? t : p + c,
      messageUsage: MessageUsage.accumulate(messageUsage, other.messageUsage),
    );
  }
  ```
- **不要用 `TokenUsage.merge()` 來累加 review usage**：`merge()` 是串流 max 語意，且會把 `totalTokens` 重算為 `prompt + completion`。

---

## 9. UI 狀態機

### 9.1 `StreamingState` 新增

```dart
final AnswerReviewStreamState answerReview = AnswerReviewStreamState();
```

`AnswerReviewStreamState`（新檔 `answer_review_stream_state.dart`，純 Dart、可單測）：

```dart
class AnswerReviewStreamState {
  String? phase;          // null | reviewing | revising | revision_failed
  bool reviewed = false;
  int reviewTokens = 0;
  String? _draftBackup;

  bool get isRevising => phase == 'revising';
  bool get needsDraftRestore => isRevising && _draftBackup != null;

  void beginReviewing() => phase = 'reviewing';

  void beginRevision(String draft) {
    _draftBackup ??= draft;   // retry 不覆蓋原始 draft
    phase = 'revising';
  }

  void markRevisionFailed() => phase = 'revision_failed';

  String takeDraftForRestore() {
    final draft = _draftBackup ?? '';
    _draftBackup = null;
    phase = 'revision_failed';
    return draft;
  }

  void finish({required bool reviewed, int reviewTokens = 0}) {
    phase = null;
    this.reviewed = reviewed;
    this.reviewTokens = reviewTokens;
    _draftBackup = null;
  }
}
```

### 9.2 `StreamingContentNotifier`

- `StreamingContentData` 新增 `String? reviewPhase`。
- 新增：
  ```dart
  void updateReviewPhase(String messageId, String? phase) { ... }
  ```
- **所有既有 copy 建構點**都要保留 `reviewPhase`：
  - `updateContent`
  - `updateReasoning`
  - `updateRetryStatus`
  - `updateProposals`
  - `forceRebuild`
  - 其他直接 `StreamingContentData(...)` 的地方
- `==` / `hashCode` 加入 `reviewPhase`。

> 這是典型遺漏點：新增欄位後，某個 copy 方法沒帶到，狀態會在特定重建時消失。測試需覆蓋「updateContent 後 reviewPhase 仍在」。

### 9.3 `_handleStreamChunk` 路由

在既有 `errorKind` 分支之後、`chunkContent` 計算之前：

```dart
if (chunk.reviewPhase != null) {
  await _handleReviewPhaseChunk(chunk, state);
  return; // status chunk 不帶 content
}
```

`_handleReviewPhaseChunk`：

```dart
Future<void> _handleReviewPhaseChunk(ChatStreamChunk chunk, state) async {
  final phase = chunk.reviewPhase!;
  switch (phase) {
    case 'reviewing':
      state.answerReview.beginReviewing();
      streamController.streamingContentNotifier.updateReviewPhase(
        state.messageId, 'reviewing',
      );
      break;
    case 'revising':
      state.answerReview.beginRevision(state.fullContentRaw);
      streamController.clearGeminiThoughtSignature(state.messageId);
      streamController.cancelThrottleTimer(state.messageId);
      state.fullContentRaw = '';
      // 清 UI / notifier；「修定期間的 DB／_messages 寫入」一律暫停（§9.4）：
      // - DB 與 _messages 保留 draft；使用者中途按停止時
      //   cancelStreaming 以 _messages 的 draft 持久化，原稿不會丟
      // - crash 也同樣只會留下 draft（比半截修正更安全）
      streamController.streamingContentNotifier.updateReviewPhase(
        state.messageId, 'revising',
      );
      streamController.streamingContentNotifier.updateContent(
        state.messageId, '', state.totalTokens,
      );
      break;
    case 'revision_failed':
      state.answerReview.markRevisionFailed();
      streamController.streamingContentNotifier.updateReviewPhase(
        state.messageId, 'revision_failed',
      );
      break;
  }
}
```

> `revising` **不清** `state.usage`、`state.totalTokens`、`state.agentPromptTokens`、工具卡。只清文字、Gemini thought signature、throttle。

### 9.4 `_handleContentChunk` 的 `replaceContent`

在 `state.fullContentRaw += chunkContent;` 之前：

```dart
if (chunk.replaceContent) {
  state.fullContentRaw = chunkContent;
  streamController.clearGeminiThoughtSignature(state.messageId);
  streamController.cancelThrottleTimer(state.messageId);
} else {
  state.fullContentRaw += chunkContent;
}
```

- **修定期間（`state.answerReview.isRevising == true`）的 `_handleContentChunk` 抑制：**
  - skip `chatService.updateMessageSilent(...)`——DB 不被半截修正覆寫；
  - skip `_messages[index]` copyWith——cancel 時 `cancelStreaming` 以 `_messages`
    的 draft（未被覆寫）持久化；
  - skip `scheduleThrottledUpdate` 的外部回呼（`onContentUpdated` 會改 conversation
    list）——notifier 仍即時顯示修正文字，工具卡／usage／totalTokens 不動。
- `replaceContent` chunk（fail-open 還原 draft）在此抑制狀態下**只寫
  `state.fullContentRaw` 與 notifier**：DB 與 `_messages` 自 revising 開始就還是
  draft，不需重寫；terminal 時 `_finishStreaming` 一次性寫入最終內容。
- 「還原」chunk 的 `chunk.replaceContent` 需為 `true`（取代而非 append；
  `state.fullContentRaw` 此時是 `''`）。
- 修正階段的正常串流 `chunk.replaceContent` 為 `false`（`revising` 已清空，直接
  append）；`replaceContent: true` 只用於 fail-open 還原 draft，與（防禦性）單塊
  全文替換。

### 9.5 `_handleStreamFinish`

在合併 usage 時：

```dart
final terminalTotal = chunk.totalTokens;
if (chunk.usage != null) {
  state.usage = (state.usage ?? const TokenUsage()).merge(chunk.usage!);
  state.totalTokens = math.max(
    math.max(state.totalTokens, terminalTotal),
    state.usage!.totalTokens,
  );
  ...
} else if (terminalTotal > 0) {
  state.totalTokens = math.max(state.totalTokens, terminalTotal);
}

state.answerReview.finish(
  reviewed: chunk.reviewed,
  reviewTokens: chunk.reviewUsage?.totalTokens ?? 0,
);
state.reviewTokens = chunk.reviewUsage?.totalTokens ?? 0;
streamController.streamingContentNotifier.updateReviewPhase(messageId, null);
```

> **陷阱**：`TokenUsage.merge()` 會把 `totalTokens` 重算成 `prompt + completion`。若主 run 的累計值大於 terminal 的 per-round 值，直接覆寫會變小。用 `max(...)` 保留。

### 9.6 `_handleStreamDone` / `_handleStreamError` 的 draft 還原

```dart
void _restoreReviewDraftIfNeeded(stream_ctrl.StreamingState state) {
  if (!state.answerReview.needsDraftRestore) return;
  final draft = state.answerReview.takeDraftForRestore();
  state.fullContentRaw = draft;
  streamController.streamingContentNotifier.updateContent(
    state.messageId, draft, state.totalTokens,
  );
}
```

- `_handleStreamDone`：在 `markStreamingEnded` 之前呼叫；之後 `_finishStreaming` 會用還原後的 `fullContentRaw` 持久化。
- `_handleStreamError`：在計算/寫入錯誤訊息之前呼叫，避免把錯誤訊息接在半截修正後面。
- `_handleStreamFinish`：正常 terminal 已帶最終內容，`finish()` 清掉 backup，不需要還原。
- **使用者按停止（`cancelStreaming`，chat_actions L1102）不需要額外還原邏輯**：
  修定期間 DB 與 `_messages` 未被覆寫（§9.4 抑制），該路徑以 `_messages` 內容
  持久化＝直接回寫 draft。它會在同一處補 `ChatApiService.cancelRequest('${cid}_review')`
  取消進行中的 review/revision（§10.4）。
- 若取消發生在 `reviewing`（尚未 revising），backup 為 null → 不還原，draft 本來就還在（UI 已顯示 draft，DB 也已是 draft）。

### 9.7 狀態指示器

`message_list_view.dart` 的 `_buildStreamingMessageWidget`：

```dart
final reviewPhase = data.reviewPhase;
...
if (reviewPhase != null)
  _ReviewIndicator(phase: reviewPhase),
```

`_ReviewIndicator` 仿 `_RetryIndicator`：

| phase | 圖示 | 文字 |
|:--|:--|:--|
| `reviewing` | spinner | 審查回答中… |
| `revising` | spinner | 正在修正回答… |
| `revision_failed` | info icon | 審查未完成，已保留原回答 |

- 不顯示 review JSON、issue 數量、severity。
- `reviewed=true` 不顯示持續性徽章（v1）；終態直接回到一般訊息。
- 若未來要顯示「已審查」勾勾，需持久化否則重載後消失；v1 不做。

### 9.8 持久化

- `content`、`totalTokens`、`promptTokens`、`completionTokens`、`cachedTokens`、`usageMeta` 照舊由 `_handleContentChunk` / `_finishStreaming` 寫入。
- `reviewed`／`reviewPhase` 不持久化。
- `reviewTokens` 目前只存在記憶體；若未來要在訊息詳情顯示「review 花費」，再新增 `MessageUsage.reviewTokens` 與對應序列化（v1 不做）。
- Review／revision 的訊息與 verdict 不寫入 DB。

---

## 10. 逐檔案改動

> 行號以 v1.27.0 為基準；實作時以符號/錨點為準。

### 10.1 新增檔案

#### `lib/core/models/answer_review.dart`

- `enum AnswerReviewMode { off, smart, always }`
- `extension` 或 `AnswerReviewModeCodec`：
  ```dart
  static AnswerReviewMode fromValue(String? value) => switch (value) {
    'smart' => AnswerReviewMode.smart,
    'always' => AnswerReviewMode.always,
    _ => AnswerReviewMode.off,
  };
  String get value => switch (this) { ... };
  ```
- 純 Dart、無 Flutter import，供 `SettingsProvider` 與 service 共用。

#### `lib/core/services/agent/answer_review.dart`

- `AnswerReviewConfig`：
  ```dart
  class AnswerReviewConfig {
    const AnswerReviewConfig({
      this.mode = AnswerReviewMode.off,
      this.reviewTimeout,      // null = 無逾時；使用者可取消
      this.maxReviewTokens,    // null = 不送 max_tokens（provider 預設）
      // F-lite 預留；v1 不設定
      this.reviewerConfig,
      this.reviewerModelId,
    });
    const AnswerReviewConfig.off() : this();
    ...
  }
  ```
  - `ProviderConfig? reviewerConfig`、`String? reviewerModelId` 是 F-lite 預留欄位；v1 永遠 null。
  - 這個檔案會 import `settings_provider.dart`（為了 `ProviderConfig`）；enum 本身放在 `lib/core/models/answer_review.dart`，避免 `SettingsProvider → service` 的循環依賴。
- `shouldReviewDraft({mode, draft, executedCallCount})`：smart gate。
- `buildReviewTurn(...)` / `buildRevisionTurn(...)`：
  - 複製 `working`（shallow copy）；
  - 若最後一則 `role == 'user'`，把 review/revision 文字合併到該訊息（處理 `content` 是 `String` 或 `List` 兩種形狀）；
  - 否則新增一則 `role: 'user'`。
- `ReviewIssue` / `ReviewVerdict` / `parseReviewVerdict(String raw)`。
- `sanitizeReviewExtraBody(Map<String, dynamic>? body)`：剝除工具/串流/請求覆寫鍵。
- `reviewInstruction(draft)` / `revisionInstruction(draft, issuesJson)`。
- 常數：smart gate 門檻、issue 長度上限、review phase 字串。
- 使用 `dart:developer` log，不印 draft 內容。

#### `lib/features/home/controllers/answer_review_stream_state.dart`

- 見 §9.1。純 Dart、可單測。

### 10.2 `lib/core/services/api/chat_stream_chunk.dart`

- 新增 `reviewPhase`、`replaceContent`、`reviewed`、`reviewUsage` 欄位與建構參數。
- 新增 `copyWith(...)`。
- 更新類別註解，說明 terminal／status chunk 的契約。

### 10.3 `lib/core/services/agent/agent_orchestrator.dart`

- `run()` 新增參數：
  ```dart
  AnswerReviewConfig answerReview = const AnswerReviewConfig.off(),
  Future<Stream<ChatStreamChunk>> Function(
    List<Map<String, dynamic>> messages,
  )? reviewSendRound,
  ```
- `run()` 內新增：
  - `_draft`（`StringBuffer`）
  - `_heldTerminal`（`ChatStreamChunk?`）
  - `_reviewUsage`（`TokenUsage`）
  - `_reviewCall(...)`：呼叫 `sendRoundImpl`（或測試注入的 `reviewSendRound`），
    參數契約：
    - `userImagePaths: null`、`imageAspectRatio: null`——圖片已在主 run 送出，
      review 不重傳（避免重複上傳成本）；
    - `requestId: '${requestId}_review'`（比照 proposer 的 `'${cid}_proposer'`
      慣例；`cancelStreaming` 需同步 cancel 此 id，見 §10.4）；
    - `sessionId` 沿用主 run 的值（OpenCode session 綁定）；
    - `thinkingBudget`／`temperature`／`topP` 沿用主 run；`maxTokens` 只在
      `config.maxReviewTokens` 非 null 時覆寫（預設不設上限，讓 always-thinking
      模型先花完思考再輸出 JSON）；若 soak 發現 verdict 不穩，可把 temperature
      固定為 0（不影響 prompt cache）；
    - `streamOutput: false`、`webFetchEnabled: false`、`tools: null`；
    - `extraBody` 先過 `sanitizeReviewExtraBody`；
    - 收集回應只在 `config.reviewTimeout != null` 時套 `Future.timeout`；逾時後
      先 cancel 內部訂閱再回傳 fail-open 結果（§5.1 逾時語意）。
  - `_collectCall(...)`：收集 content／usage，過濾 tool calls
  - `_runReview(...)` / `_runRevision(...)`
- `AgentStreamEvent` 分支：
  - `errorKind != null` → `_draft.clear(); _heldTerminal = null;`
  - `isDone` → **每一輪（含工具輪）的 terminal 都扣住**（hold-latest，互相覆蓋），
    先 `yield` content-only chunk（若有 content）
  - 其他 → append draft、照常 yield
- `AgentRunFinishedEvent` 分支：
  - `reason != finished` → **丟棄 `_heldTerminal`**，既有行為（合成 terminal，跳過 review）
  - `finished` → 依 gate 跑 review／revision，最後只 `yield` 一個 terminal
- `sendRoundImpl` 不變；review 直接呼叫它。
- 更新檔案頂端註解（driver 現在也擁有 review phase）。

### 10.4 `lib/features/home/controllers/chat_actions.dart`

- `_executeGeneration` 簽名：
  ```dart
  Future<void> _executeGeneration(
    stream_ctrl.GenerationContext ctx, {
    bool enableAnswerReview = true,
  }) async {
    final answerReview = (enableAnswerReview && ctx.streamOutput)
        ? AnswerReviewConfig(mode: ctx.settings.answerReviewMode)
        : const AnswerReviewConfig.off();
    ...
    final stream = _agentOrchestrator.run(
      ...
      answerReview: answerReview,
    );
  ```
- Aggregator 呼叫（約 L1752）：
  ```dart
  await _executeGeneration(aggCtx, enableAnswerReview: false);
  ```
- `_handleStreamChunk`：加入 `reviewPhase` 分支（§9.3）。
- `_handleContentChunk`：處理 `replaceContent`（§9.4）；revision 階段跳過 `_finishReasoningOnContent`（可選）。
- `_handleStreamFinish`：`max(...)` 保留 totalTokens；`finish()` review state（§9.5）。
- `_handleStreamDone` / `_handleStreamError`：呼叫 `_restoreReviewDraftIfNeeded`（§9.6）。
- `_resetStreamForRetry`：**不變**（主 run retry 仍清 usage/totalTokens）；review state 的 draft backup 不受影響，因為主 run retry 不會發生在 revising。
- `_handleAiTeamStopped` / AI Team 其他路徑：不變。
- `cancelStreaming`（chat_actions L1102）：在 `await sub?.cancel()` /
  `ChatApiService.cancelRequest(cid)` 附近補
  `ChatApiService.cancelRequest('${cid}_review');`（比照 proposer 的
  `'${cid}_proposer'` 模式），讓中途停止可取消進行中的 review/revision。
- 由於修定期間 DB／`_messages` 寫入被抑制（§9.4），`cancelStreaming` 現有的
  「以 `_messages` 內容持久化」會直接回寫 draft，不需要額外還原邏輯。

### 10.5 `lib/features/home/controllers/stream_controller.dart`

- `StreamingState` 新增 `final AnswerReviewStreamState answerReview = ...;`
- 新增 `int reviewTokens = 0;`，供 UI／log 使用；不持久化。
- 不新增 DB 欄位。

### 10.6 `lib/features/home/controllers/streaming_content_notifier.dart`

- `StreamingContentData` 新增 `String? reviewPhase`。
- 新增 `updateReviewPhase`。
- 所有 copy 建構點保留 `reviewPhase`。
- `==` / `hashCode` 更新。

### 10.7 `lib/features/home/widgets/message_list_view.dart`

- `_buildStreamingMessageWidget`：讀取 `data.reviewPhase`，在 `_RetryIndicator` 附近插入 `_ReviewIndicator`。
- 新增 `_ReviewIndicator`（仿 `_RetryIndicator`）。
- l10n key 見 §10.10。

### 10.8 `lib/core/providers/settings_provider.dart`

- 新增 key、欄位、getter、setter、load、`copyWith`（§4.2）。
- **不加入** `_localOnlyKeys`。

### 10.9 `lib/features/settings/pages/display_settings_page.dart`

- `BehaviorStartupSettingsPage` 新增 `_iosNavRow`（icon 建議 `Lucide.ScanSearch`）。
- `Lucide.ScanSearch` 需先在 `lib/icons/lucide_adapter.dart` 新增一行
  `static const IconData ScanSearch = lucide.LucideIcons.scanSearch;`
  ——adapter 是手動策展清單，`ScanSearch` 目前不存在；底層
  `lucide_icons_flutter 3.1.22` 有 `scanSearch`（L100399）。
- 新增 `_showAnswerReviewSheet(context)`（仿 `_showAndroidBackgroundChatSheet`）。
- 三個選項 + 說明文字。
- 若 `sp.answerReviewMode` 改變，`context.watch<SettingsProvider>()` 會自動重建。

### 10.10 l10n

`lib/l10n/app_zh.arb`、`app_zh_Hans.arb`、`app_zh_Hant.arb`、`app_en.arb` 新增：

| Key | zh（繁） | en |
|:--|:--|:--|
| `displaySettingsPageAnswerReviewTitle` | 回答前審查 | Answer review |
| `displaySettingsPageAnswerReviewDescription` | 在最終回答送出前檢查草稿；發現重大問題時自動修正一次 | Review the draft before the final answer is sent and fix major issues once |
| `displaySettingsPageAnswerReviewOptionOff` | 關閉 | Off |
| `displaySettingsPageAnswerReviewOptionSmart` | 智慧 | Smart |
| `displaySettingsPageAnswerReviewOptionAlways` | 每次 | Always |
| `displaySettingsPageAnswerReviewSmartHint` | 只在有工具結果、長回答、程式碼、數字或 URL 時執行 | Only when tool results, long answers, code, numbers, or URLs are present |
| `displaySettingsPageAnswerReviewCostHint` | 審查會多一次模型請求，可能增加延遲與 token 費用 | Review adds one model request and may increase latency and token cost |
| `chatAnswerReviewInProgress` | 審查回答中… | Reviewing answer… |
| `chatAnswerReviewRevising` | 正在修正回答… | Revising answer… |
| `chatAnswerReviewFailedOpen` | 審查未完成，已保留原回答 | Review unavailable; original answer kept |

- 執行 `flutter gen-l10n`，同步 `app_localizations*.dart`。
- `zh_Hans` / `zh_Hant` 的譯法依既有檔案風格（簡體／繁體）。

### 10.11 `lib/core/services/chat/chat_turn_service.dart`

- `_orchestrator.run(...)` 顯式加：
  ```dart
  answerReview: const AnswerReviewConfig.off(),
  ```
- 雖然預設已是 off，但顯式標記可防止未來改預設值時誤開。

### 10.12 `lib/core/models/token_usage.dart`

- 新增 `TokenUsage sum(TokenUsage other)`（§8.4）。
- 不改 `merge()`／`accumulate()` 的既有語意。
- 補單元測試：prompt/completion/cached/total、total-only、messageUsage 成本累加。

### 10.13 文件

- 本計畫（`docs/answer_review_plan.md`）。
- `OmniChat 專案開發與維護手冊.md`：
  - §3.14 新增 `#### 9. 回答前審查（Answer Review v1）`
  - §4 ADR 表新增一列（ADR-A10 暫定）
  - §5.7 新增 `answer_review_v1` 不在 `_localOnlyKeys` 的說明
  - §7.2 新增待辦／完成項目
  - 版本註記（實作完成後）
- 若實作期間發現新的 provider 限制，補在本計畫 §12 或手冊 §3.14。

---

## 11. 測試矩陣

### 11.1 純邏輯（`test/core/services/agent/answer_review_test.dart`）

| 案例 | 斷言 |
|:--|:--|
| `fromValue('off'/'smart'/'always')` | 正確解析 |
| `fromValue(null/'bogus')` | `off` |
| smart：工具輪、長文、code fence、URL、數字 | 觸發 |
| smart：短招呼、純語氣回覆 | 不觸發 |
| always：短非空 draft | 觸發 |
| off：任何 draft | 不觸發 |
| parser：純 JSON pass | pass, issues empty |
| parser：純 JSON revise + blocker | revise |
| parser：code fence JSON | 正確解析 |
| parser：JSON 前後有 prose | 正確解析 |
| parser：`{"verdict":"pass"}` 但有 blocker | revise（severity gate） |
| parser：`{"verdict":"revise"}` 只有 minor | pass |
| parser：純文字 REVISE 無 issues | pass |
| parser：malformed | pass（fail-open） |
| parser：未知 severity | major |
| parser：issues 超過 6 筆 | 只取前 6 |
| `sanitizeReviewExtraBody` | 移除 tools/stream/messages 等，保留 reasoning 設定 |
| `buildReviewTurn`：最後是 user（String） | 合併到同一則，不新增 consecutive user |
| `buildReviewTurn`：最後是 user（List content） | 追加 text part |
| `buildReviewTurn`：最後是 tool | 新增 user 訊息 |
| `buildReviewTurn`：空 working | 新增 user 訊息 |
| `TokenUsage.sum` | 逐欄相加、total 正確、成本累加 |

### 11.2 Orchestrator（`test/features/home/services/agent_orchestrator_review_test.dart`）

| 案例 | 斷言 |
|:--|:--|
| `off` 正常 run | chunks 與既有測試一致；沒有 review 呼叫；只有一個 isDone |
| `always` + PASS | 有 `reviewing`；`reviewed=true`；draft 不變；只有一個 isDone；review messages 不含 tool schema；`_reviewCall` 固定 `tools=null`、`streamOutput=false` |
| `always` + REVISE 成功 | 有 `reviewing`→`revising`；修正文字被串流；terminal `reviewed=true`；usage 合計正確 |
| revision 回空 | `revision_failed`；`replaceContent` 還原 draft；terminal `reviewed=false` |
| revision 丟錯 | 同上 |
| revision 無 terminal（截斷） | 同上 |
| review 丟錯 | fail-open；terminal `reviewed=false`；draft 保留 |
| review timeout | fail-open；terminal 只有一個；內部 mock stream 已被 cancel |
| review 回 malformed JSON | fail-open PASS |
| 工具輪 terminal | 多輪 run 中工具輪的 transport terminal 被扣住不轉發，最後一輪 terminal 覆蓋之 |
| 早停丟棄 held terminal | `reason=maxStepsReached` 時被扣住的 terminal 不轉發，只有合成的 soft-stop terminal |
| maxSteps / tokenBudget / hook veto | 不 review；terminal 行為與既有測試一致 |
| 工具輪 preamble + final answer | review messages 的 `<draft>` 只含 final answer，不含 preamble |
| 主 run final round L1 retry | draft 被清空；重試後只 review 新內容 |
| review messages 角色 | 最後一則是 user；沒有 consecutive user（最後是 user 時合併） |
| review extraBody | `tools`、`stream`、`messages` 被剝除 |
| review 呼叫參數 | `userImagePaths=null`、`imageAspectRatio=null`、`requestId` 帶 `_review` 後綴 |
| usage | terminal total = main + review + revision；`reviewUsage` 是子集；不重複加總 |
| 取消（模擬） | 不產生第二個 terminal；不影響既有 cancel 行為 |

### 11.3 UI 狀態（`test/features/home/controllers/answer_review_stream_state_test.dart`）

| 案例 | 斷言 |
|:--|:--|
| reviewing → revising | backup = 原 draft；phase 正確 |
| revising 再次 revising（retry） | backup 不被覆蓋 |
| revising → finish(success) | phase null、backup null、reviewed true |
| revising → takeDraftForRestore | 回傳原 draft、backup 清空 |
| reviewing → cancel | needsDraftRestore false |
| `StreamingContentNotifier.updateContent` | 保留 `reviewPhase` |
| `updateReviewPhase(id, null)` | 清除狀態 |

### 11.4 設定（`test/settings_provider_answer_review_test.dart`）

| 案例 | 斷言 |
|:--|:--|
| 預設 | `off` |
| setter 寫入後重載 | 值保留 |
| 非法 prefs 值 | `off` |
| `copyWith` | 保留／覆寫正確 |
| `_localOnlyKeys` | 不含 `answer_review_v1`（若測試可達） |

### 11.5 回歸

- `flutter test test/core/services/agent/agent_loop_test.dart`
- `flutter test test/features/home/services/agent_orchestrator_test.dart`
- `flutter test test/core/services/api/agent_loop_provider_parity_test.dart`
- `flutter test test/core/services/api/agent_loop_followup_parity_test.dart`
- 既有 settings、stream controller、AI Team、voice 相關測試。
- `flutter analyze`。

### 11.6 手動 smoke（provider 矩陣）

| 情境 | OpenAI | Claude | Gemini | DeepSeek/Kimi | OpenRouter |
|:--|:--:|:--:|:--:|:--:|:--:|
| 純文字 PASS | ☐ | ☐ | ☐ | ☐ | ☐ |
| 工具後 REVISE | ☐ | ☐ | ☐ | ☐ | ☐ |
| Thinking/reasoning 模型 | ☐ | ☐ | ☐ | ☐ | ☐ |
| Review JSON malformed | ☐ | ☐ | ☐ | ☐ | ☐ |
| 修正中途取消 | ☐ | ☐ | ☐ | ☐ | ☐ |
| 長對話接近 context 上限 | ☐ | ☐ | ☐ | ☐ | ☐ |

---

## 12. 風險與對策

| # | 風險 | 影響 | 對策 |
|:--:|:--|:--|:--|
| 1 | 同模型自我審查放水 | review 抓不到錯 | 嚴格 rubric、severity gate、soak 量測；F-lite 為長期解 |
| 2 | Reviewer 幻覺／過度回報 | 不必要的重寫、成本上升 | 只修 blocker/major；要求 location；issues 上限；minor 不觸發 |
| 3 | 延遲增加 | 使用者等待 | 顯示「審查中」；無預設逾時（可由 config 覆寫）；使用者可取消；smart 模式；預設 off |
| 4 | Token 成本 | 長對話每次多一份 context | smart gate；off 預設；review 不設 max_tokens 上限（可由 config 覆寫）；只 REVISE 才 revision |
| 5 | Prompt cache 失效 | C 的成本優勢消失 | 不改 system prompt；rubric 放最後一則 user message；不改前綴 |
| 6 | Provider 400（角色順序） | review 直接失敗 | `buildReviewTurn` 合併最後一則 user；provider parity 測試 |
| 7 | Context 超限 | review/revision 400 | fail-open；log；F-lite 策展歷史；未來可裁剪 |
| 8 | Usage 重複計算 | 帳面 token 膨脹 | 每次呼叫只取最後 usage；`sum()`；UI 不加總 `reviewUsage` |
| 9 | `merge()` 覆寫 totalTokens | 終態 token 變小 | `_handleStreamFinish` 用 `max(...)` |
| 10 | 取消時遺失 draft | 使用者失去答案 | `ReviewStreamState` 備份；done/error 還原 |
| 11 | Revision 期間 crash／使用者中途按停止 | 原稿丟失 | （已消除）修定期間 DB 與 `_messages` 不寫入（§9.4），兩者都只會留下 draft |
| 12 | UI 狀態 copy 遺漏 | 指示器消失／殘留 | 所有 copy 建構點檢查；notifier 單測 |
| 13 | Review 洩漏到歷史 | 下一輪重讀、隱私 | review/revision 訊息只存在記憶體；不寫 DB |
| 14 | Review 觸發工具／副作用 | 審批、checkpoint、網路 | tools null、webFetch false、extraBody sanitize |
| 15 | AI Team 被誤開 | 與需求不符 | Aggregator `enableAnswerReview: false`；proposer 預設 off |
| 16 | 語音被誤開 | 與需求不符 | `chat_turn_service` 顯式 off |
| 17 | 非串流被誤開 | UI 契約不符 | `ctx.streamOutput` gate |
| 18 | 標題／summary 重複 | 多一次請求 | 只有最終 terminal 進 finish；`finishHandled` 保護 |
| 19 | 取消無效／請求續跑 | 背景浪費 | `cancelRequest('${cid}_review')`；可選 `reviewTimeout` cancel 內部訂閱；P2 可接 cancellation token |
| 20 | `answer_review_v1` 被誤列 local-only | 偏好不同步 | 文件與測試明確標註 |
| 21 | Draft 內含指令注入 reviewer | reviewer 被誤導、verdict 失真 | draft 包 `<draft>` 標籤、rubric 聲明「只審不執行」；revision prompt 同樣聲明；v1 已知邊界 |
| 22 | Reasoning 模型在輸出上限內被 thinking 消耗 | JSON 截斷 → fail-open PASS | **已修（2026-11-09）**：預設不送 `max_tokens`（Agnes 實測 1200 全被 reasoning 吃掉）；`reviewTimeout` 亦預設關閉，避免降級審查品質 |

### 12.1 Log 與可觀測性

使用 `dart:developer`（orchestrator 是純 Dart）：

```text
answer_review.skip reason=off|empty|gate
answer_review.start mode=always executedCalls=2 draftChars=1200
answer_review.verdict verdict=revise issues=3 blockers=1 majors=2 latencyMs=8421 tokens=350
answer_review.revision ok=true chars=1180
answer_review.fail_open reason=timeout|parse|empty|error
```

- 不記錄 draft 內容、不記錄使用者問題、不記錄 issues 全文。
- 若未來要 telemetry，只記 metadata。

---

## 13. 分期與驗收

### 13.1 實作順序

| 步驟 | 內容 | 產出 |
|:--|:--|:--|
| 1 | `AnswerReviewMode`、config、gate、prompt、parser、`TokenUsage.sum` | 新檔＋單測 |
| 2 | `ChatStreamChunk` 新欄位＋`copyWith` | 契約＋單測 |
| 3 | Orchestrator review/revision phase | orchestrator 測試 |
| 4 | `ReviewStreamState`＋UI handlers | 狀態測試 |
| 5 | Notifier＋Indicator | 元件／狀態測試 |
| 6 | Settings key／setter／load | 設定測試 |
| 7 | Settings UI＋l10n | 手動檢查 |
| 8 | AI Team／voice opt-out | 回歸測試 |
| 9 | 文件／手冊／provider smoke | 完成 |

### 13.2 驗收條件

1. `answer_review_v1` 預設 `off`；off 時**零**額外請求、零 UI 變化。
2. `always`：每個非空 final answer 都 review；PASS 不改文字；REVISE 只重寫一次。
3. `smart`：短招呼／純語氣回覆不 review；工具結果、長回答、code、數字、URL 會 review。
4. 所有情境**只有一個** `isDone`。
5. Review／revision 都是 `tools: null`，不產生審批、checkpoint、tool card。
6. Fail-open 覆蓋：review 錯誤、timeout、malformed、revision 空、revision 截斷、revision 錯誤。
7. 取消於 revising 時，draft 完整保留並持久化。
8. AI Team（proposer／critic／aggregator）與語音永遠不 review。
9. Terminal usage 包含 review＋revision；`reviewUsage` 不重複加總。
10. 最終回答仍是正常 Markdown；沒有 JSON、沒有 review 工具卡。
11. `flutter analyze` 無新錯誤；既有測試全綠；新測試覆蓋 §11。
12. 手冊 §3.14／§4／§5.7／§7.2 已更新。

### 13.3 Rollback

- 使用者層：把 `answer_review_v1` 設回 `off`。
- 程式層：`AnswerReviewConfig.off()` 是預設值；移除 UI 入口即可完全停用，不需要資料遷移。
- 不需要 feature flag／kill-switch；設定本身就是開關。

---

## 14. F-lite 未來疊加

### 14.1 定位

**F-lite ＝ C 的同一個 review phase，換一個獨立 reviewer。**

不新增流程、不動 kernel、不需要 P2-3 子代理 runtime。只改 `sendRoundImpl` 的四個參數：

| 參數 | C | F-lite |
|:--|:--|:--|
| system prompt | 主對話 system prompt | 獨立 reviewer system prompt |
| messages | `event.messages` + draft + rubric | 策展後的歷史 + draft + rubric |
| model | 主模型 | 可選 reviewer 模型 |
| tools | null | null |

### 14.2 需要新增的設定

```text
answer_review_reviewer_v1: "same_model" | "isolated"
answer_review_model_v1:    "<providerKey>::<modelId>"（isolated 時使用）
```

- 預設 `same_model`，行為與 v1 完全相同。
- `isolated` 時使用獨立 prompt／模型。
- 可再加 `answer_review_focus_v1`（correctness／requirements／both），但非必要。

### 14.3 Context 策展

F-lite 的重點不是「移除 reasoning」（plain assistant reasoning 本來就不在 messages），而是：

- 保留原始使用者問題與所有 user turns。
- 保留本 run 的 tool calls／tool results（可截斷長結果）。
- 補上 draft。
- 控制總大小（必要時只保留最近 N 輪＋工具結果摘要）。
- Provider-aware 處理 reasoning echo（DeepSeek／OpenRouter／Claude thinking／Gemini thought signature）。

### 14.4 成本

- 換 system prompt → 主對話 prefix cache 失效。
- 可選更強模型 → 單價更高。
- 因此 F-lite 應搭配 `smart` 模式或「高風險答案才用 isolated」；不建議所有答案預設 isolated。
- 架構上不需要改 chunk／UI；最多加一個「reviewed by …」的顯示（需持久化）。

### 14.5 升級路徑

1. v1 先上 C（同模型）。
2. 收集 verdict 分佈、修正率、使用者回饋、token 成本。
3. 若發現同模型放水明顯，再加 F-lite 的 `reviewerConfig` / `reviewerModelId` 與策展函式。
4. 不動 `AgentOrchestrator` 的 state machine；只替換 `_reviewCall` 的參數。

---

## 15. `request_review` 工具版淘汰紀錄

### 15.1 結構性限制

「最終回答」的定義是**沒有 tool call 的那一輪**。模型不可能在 final answer 之後才呼叫工具，因為那會讓它變成另一輪、final answer 就不是 final answer。

因此 `request_review` 只能：

- 在 final answer 之前呼叫；
- review 模型自己傳進 tool arguments 的 draft；
- 無法保證 review 真正的最終答案。

### 15.2 其他問題

| 問題 | 說明 |
|:--|:--|
| 不保證 | 模型可以跳過、太早呼叫、呼叫後不採納 |
| Draft 重複生成 | tool arguments 一次、final answer 一次；output token 直接多一倍 |
| 歷史膨脹 | draft 與 issues 永久留在 messages，之後每輪重讀 |
| Context 重建 | tool handler 拿不到 kernel 的 live `working` messages，只能從 DB 拼或靠模型傳 |
| Usage 不可見 | handler 只回 `String`，review 的 token 不進 kernel 統計 |
| UI 足跡 | 對話多一張工具卡；展開可看到 issues JSON |
| 迴圈風險 | 模型可能重複呼叫同一份 draft |
| `tool_choice` 無法保證 | 無法預先知道哪一輪是最後一輪；每輪強制會造成迴圈 |

### 15.3 Description 能不能救？

可以**提高呼叫機率**，但不能變成保證：

- 給正向觸發條件、反向條件、指定完整 draft、說明回傳 issues。
- 避免空泛的 MUST／ALWAYS。
- 真正的保證仍然只能由 harness（C）提供。

### 15.4 未來可能性

若未來要做「任務中途的 second opinion」，`request_review` 可以作為可選工具回歸；但它不會是「回答前 review」的實作方案，也不會取代 C。

---

## 16. 文件更新清單

| 文件 | 更新 |
|:--|:--|
| `docs/answer_review_plan.md` | 本計畫；實作後把狀態改為「已實作」並補進度表 |
| `OmniChat 專案開發與維護手冊.md` §3.14 | 新增「9. 回答前審查（Answer Review v1）」：流程、狀態機、fail-open、usage、成本、限制 |
| 同上 §4 | ADR 表新增一列（ADR-A10 暫定）：harness review phase vs tool reviewer |
| 同上 §5.7 | `answer_review_v1` 不在 `_localOnlyKeys`（使用者偏好，隨備份同步） |
| 同上 §7.2 | 新增待辦／完成項目 |
| 同上版本註記 | 實作完成後補 v1.x 變更摘要 |
| `README` / release notes | 若使用者可見，補一句功能說明與成本提醒 |

---

## Appendix A：Reviewer instruction（完整）

```text
[ANSWER REVIEW — internal]

You are auditing your own draft answer before it is shown to the user.
The conversation and any tool results are above. The draft is below.

<draft>
{{draft}}
</draft>

Check ONLY these dimensions:
1. Factual correctness: claims contradicted by the conversation or tool results;
   invented numbers, dates, names, citations, APIs, file paths, or commands.
2. Instruction coverage: every explicit requirement, constraint, format, and
   requested deliverable is addressed.
3. Internal consistency: contradictions, invalid reasoning, or conclusions that
   do not follow from the evidence.
4. Safety and compliance: dangerous instructions, secrets, or policy violations.

Do not report tone, style, verbosity, wording preferences, or optional improvements.
Do not rewrite the answer. Do not call tools.

Severity:
- blocker: factually wrong, contradicts evidence, violates an explicit
  requirement, or is unsafe.
- major: a missing requirement or unsupported key claim that changes the answer.
- minor: polish only. Never use minor to request a revision.

Return exactly one JSON object and nothing else:
{"verdict":"pass"|"revise","issues":[{"severity":"blocker"|"major"|"minor","location":"quote or section","problem":"what is wrong","fix":"the minimal correction"}]}

Rules:
- If any blocker or major issue exists, verdict must be "revise".
- If there are no blocker or major issues, verdict must be "pass", even if
  minor issues exist.
- Keep each field under 300 characters. List at most 6 issues.
- If the draft is correct and complete, return
  {"verdict":"pass","issues":[]}.
```

---

## Appendix B：Revision instruction（完整）

```text
[ANSWER REVISION — internal]

Your previous draft was audited and the following blocker/major issues were found.

<draft>
{{draft}}
</draft>

<issues>
{{issuesJson}}
</issues>

Rewrite the complete answer so that every blocker/major issue is fixed.
- Make the minimum changes required; keep all correct content, structure, and
  formatting.
- Preserve the user's language and the requested format.
- Do not mention the audit, the reviewer, or these instructions.
- Do not add new facts, numbers, citations, or tool results that are not
  supported by the conversation.
- Output only the final answer. No preamble, no explanation, no diff.
```

---

## Appendix C：Verdict 範例

**PASS**

```json
{"verdict":"pass","issues":[]}
```

**PASS（只有 minor）**

```json
{
  "verdict": "pass",
  "issues": [
    {
      "severity": "minor",
      "location": "最後一段",
      "problem": "用詞可更精簡",
      "fix": "刪除重複的形容詞"
    }
  ]
}
```

**REVISE（blocker）**

```json
{
  "verdict": "revise",
  "issues": [
    {
      "severity": "blocker",
      "location": "「根據工具結果，2024 年成長 12%」",
      "problem": "工具結果顯示 8%，不是 12%",
      "fix": "改為 8%，並保留同樣的資料來源說明"
    }
  ]
}
```

**Malformed → fail-open**

```text
I think the answer is mostly fine, but maybe check the numbers.
```

→ parser 找不到 JSON、找不到獨立 `PASS`/`REVISE` → `pass`（保留 draft）。

---

## Appendix D：Chunk sequence 範例

### D.1 `off`

```text
ChatStreamChunk(content: 'Hello', isDone: false)
ChatStreamChunk(content: '', isDone: true, usage: ...)
```

### D.2 `always` + PASS

```text
ChatStreamChunk(content: 'Hello', isDone: false)
ChatStreamChunk(content: '', isDone: false, reviewPhase: 'reviewing')
ChatStreamChunk(content: '', isDone: true, reviewed: true,
                usage: mainPlusReview, reviewUsage: reviewOnly)
```

### D.3 `always` + REVISE

```text
ChatStreamChunk(content: 'Draft', isDone: false)
ChatStreamChunk(content: '', isDone: false, reviewPhase: 'reviewing')
ChatStreamChunk(content: '', isDone: false, reviewPhase: 'revising')
ChatStreamChunk(content: 'Revised', isDone: false)
ChatStreamChunk(content: '', isDone: true, reviewed: true,
                usage: mainPlusReviewPlusRevision, reviewUsage: reviewPlusRevision)
```

### D.4 Fail-open（revision 失敗）

```text
ChatStreamChunk(content: 'Draft', isDone: false)
ChatStreamChunk(content: '', isDone: false, reviewPhase: 'reviewing')
ChatStreamChunk(content: '', isDone: false, reviewPhase: 'revising')
ChatStreamChunk(content: '', isDone: false, reviewPhase: 'revision_failed')
ChatStreamChunk(content: 'Draft', isDone: false, replaceContent: true)
ChatStreamChunk(content: '', isDone: true, reviewed: false,
                usage: mainPlusReviewPlusRevision,
                reviewUsage: reviewPlusRevision)
```

### D.5 早停

```text
ChatStreamChunk(content: '', isDone: true, totalTokens: 1234,
                softStopReason: 'max_steps')
```

---

## Appendix E：設定與 l10n key 清單

### E.1 SharedPreferences

```text
answer_review_v1 = "off" | "smart" | "always"
```

### E.2 Dart 符號

```text
enum AnswerReviewMode { off, smart, always }
class AnswerReviewModeCodec
class AnswerReviewConfig
class ReviewIssue
class ReviewVerdict
class AnswerReviewStreamState
```

### E.3 `ChatStreamChunk`

```text
reviewPhase:    String?
replaceContent: bool
reviewed:       bool
reviewUsage:    TokenUsage?
```

### E.4 l10n

```text
displaySettingsPageAnswerReviewTitle
displaySettingsPageAnswerReviewDescription
displaySettingsPageAnswerReviewOptionOff
displaySettingsPageAnswerReviewOptionSmart
displaySettingsPageAnswerReviewOptionAlways
displaySettingsPageAnswerReviewSmartHint
displaySettingsPageAnswerReviewCostHint
chatAnswerReviewInProgress
chatAnswerReviewRevising
chatAnswerReviewFailedOpen
```

---

## Appendix F：實作檢查清單（給 PR 作者）

- [ ] `AnswerReviewMode` 預設 `off`，非法值回退 `off`。
- [ ] `answer_review_v1` 不在 `_localOnlyKeys`。
- [ ] `_executeGeneration` 只在 `enableAnswerReview && ctx.streamOutput` 時套用。
- [ ] AI Team aggregator 傳 `enableAnswerReview: false`。
- [ ] `chat_turn_service` 顯式 `AnswerReviewConfig.off()`。
- [ ] `AgentOrchestrator.run` 的 `answerReview` 預設 off（所有舊呼叫端零影響）。
- [ ] 主 run terminal 被扣住，只有一個 `isDone`。
- [ ] `reviewPhase` status chunk 不進 `_handleContentChunk`。
- [ ] `revising` 清文字、保留工具卡／usage／totalTokens。
- [ ] `revising` 前備份 draft；done/error 可還原。
- [ ] 修定期間 `_handleContentChunk` 抑制 DB／`_messages`／`onContentUpdated` 寫入（§9.4）。
- [ ] `cancelStreaming` 補 `ChatApiService.cancelRequest('${cid}_review')`。
- [ ] Review／revision 呼叫 `userImagePaths: null`、`imageAspectRatio: null`。
- [ ] 被扣住的工具輪 terminal 不轉發；早停時丟棄。
- [ ] `replaceContent` 只取代、不 append。
- [ ] `_handleStreamFinish` 用 `max(...)` 保留 totalTokens。
- [ ] `review/revision usage` 只取每次呼叫最後快照；不逐 chunk 累加。
- [ ] `reviewUsage` 不重複加總。
- [ ] Review／revision `tools: null`、`webFetchEnabled: false`、`extraBody` 已剝除工具鍵。
- [ ] Review messages 最後一則是 user；不產生 consecutive user。
- [ ] Review／revision 訊息不落庫。
- [ ] 所有 `StreamingContentData` copy 建構點保留 `reviewPhase`。
- [ ] l10n 四份 ARB 與 generated 檔案已更新。
- [ ] 新測試與既有測試全綠；`flutter analyze` 乾淨。
- [ ] 手冊 §3.14／§4／§5.7／§7.2 已更新。
```

---

## 17. 實作紀錄（2026-11-08，P2–P6）

### 17.1 落地檔案

| 檔案 | 內容 |
|:--|:--|
| `lib/core/models/answer_review.dart`（新） | `AnswerReviewMode` + `AnswerReviewModeCodec`（純 Dart） |
| `lib/core/services/agent/answer_review.dart`（新） | `AnswerReviewConfig`（F-lite 預留欄位）、`shouldReviewDraft`、`buildReviewTurn`／`buildRevisionTurn`、`parseReviewVerdict`（`ReviewVerdict.parsed` 標記 JSON 是否真解析）、`sanitizeReviewExtraBody`、Appendix A/B prompt、常數 |
| `lib/core/services/api/chat_stream_chunk.dart` | `reviewPhase`／`replaceContent`／`reviewed`／`reviewUsage` 欄位 + `copyWith` |
| `lib/core/models/token_usage.dart` | `sum()`（逐欄相加、`MessageUsage.accumulate` 成本合併） |
| `lib/core/services/agent/agent_orchestrator.dart` | hold-latest terminal、draft capture、`reviewRound` 參數契約、`_collectRound`（review，`Future.timeout` + 內部訂閱 cancel）、`_withDeadline`（revision 串流牆鐘期限）、`_releaseHeldTerminal`（§8.4 合成）、`dart:developer` log |
| `lib/features/home/controllers/answer_review_stream_state.dart`（新） | §9.1 狀態機 |
| `lib/features/home/controllers/stream_controller.dart` | `StreamingState.answerReview` + `reviewTokens` |
| `lib/features/home/controllers/streaming_content_notifier.dart` | `reviewPhase` 欄位、`updateReviewPhase`、六個 copy 建構點全保留、`==`/`hashCode` |
| `lib/features/home/controllers/chat_actions.dart` | `_executeGeneration(enableAnswerReview:)`、aggregator `false`、reviewPhase 路由、`replaceContent`、修定期抑制（DB／`_messages`／throttle／reasoning）、`_handleStreamFinish` max() + `finish()`、done/error 還原、`cancelStreaming` 補 `cancelRequest('{cid}_review')` |
| `lib/features/home/widgets/message_list_view.dart` | `_ReviewIndicator`（仿 `_RetryIndicator`） |
| `lib/core/providers/settings_provider.dart` | `answer_review_v1` 鍵、getter/setter、load、`copyWith`；**不在** `_localOnlyKeys` |
| `lib/features/settings/pages/display_settings_page.dart` | 行為與啟動頁 nav row（`Lucide.ScanSearch`）＋底部三選項 sheet＋兩段說明 |
| `lib/icons/lucide_adapter.dart` | 新增 `ScanSearch`（lucide 3.1.21/3.1.22 皆有 `scanSearch`） |
| l10n × 4 ARB + `flutter gen-l10n` | §10.10 十鍵（zh／zh_Hans／zh_Hant／en） |
| `lib/core/services/chat/chat_turn_service.dart` | 顯式 `AnswerReviewConfig.off()` |

### 17.2 與計畫的差異（實作裁定）

1. **Revision 的 maxTokens**：計畫 §10.3 只寫「maxTokens 以 `config.maxReviewTokens` 覆寫」——該句按文意限定 **verdict 呼叫**。revision 重寫全文，若同樣壓到小預算會把長回答截半串流給使用者；故 **revision 沿用主 run 的 `maxTokens`**。verdict 之後改為 **預設不設上限**（2026-11-09：Agnes 的 thinking 會把 1200 全部吃掉、正文 0 字）。
2. **Usage 基準（§8.4 的 `tokensUsed`）**：計畫假設 kernel 的 `tokensUsed` 是「多輪真實累計」，但 kernel 對每個 usage chunk **逐 chunk 相加**，而各 transport 的 usage 都是**輪內累計值**（Gemini 甚至每個 delta 都帶 cumulative usageMetadata）——直接 `max(held, tokensUsed)` 對此類 provider 單輪就會膨脹 N 倍（含 review-off 路徑）。driver 另測「逐輪 usage 最大值之和」（`roundMaxUsageTotal` / `usageAcrossRounds`），基準改為 **`observedTotal > 0 ? observedTotal : tokensUsed`**（不用 kernel 加總值贏 max）——單一 usage chunk 的 provider（OpenAI／Claude 非串流）結果與計畫相同，重複帶 cumulative usage 的 provider（Gemini）不再虛增（回歸測試：`r19`）。
3. **Malformed verdict 的 `reviewed`**：§5.1 pseudo-code 對「非 revise」一律 `reviewed: true`，但 §8.1 定義 `reviewed = review 完成且最終答案已套用`。裁定：**JSON 真解析的 PASS → `reviewed: true`**；malformed fail-open PASS、逾時、錯誤、空回應 → `reviewed: false`（`ReviewVerdict.parsed` 承載此區分，log 補 `fail_open reason=parse`）。
4. **修定期 UI**：`scheduleThrottledUpdate` 的外部回呼抑制改為「review phase 活動期間（含 `revision_failed` 後的還原 chunk）直接 `updateContent` 寫 notifier」（不建 throttle timer、不觸發 `onContentUpdated`；code review 後抑制閘門由 `isRevising` 放寬為 `phase != null`，否則還原 chunk 會逃出 §9.4 抑制）。另外 revision 的 content delta **不轉發 `reasoning`**（避免修正輪的思考回聲附加到主 run 已完成的思考時間線）。
5. **`_handleStreamFinish` 的 `state.totalTokens`**：由覆寫改為 `max(state.totalTokens, terminalTotal, usage.totalTokens)`（§9.5），對 off 路徑單輪行為不變、多輪取更大累計值。

### 17.3 測試與驗證

- 新測試 4 檔 52 案全綠：`test/core/services/agent/answer_review_test.dart`（21）、`test/features/home/services/agent_orchestrator_review_test.dart`（20）、`test/features/home/controllers/answer_review_stream_state_test.dart`（10）、`test/settings_provider_answer_review_test.dart`（6）。
- Orchestrator 測試以 `sendRound`／`reviewSendRound` 注入驅動 §11.2 矩陣（off／PASS／REVISE 成功／revision 空・錯・截斷／review 錯・逾時（驗證內部訂閱已 cancel）・malformed／工具輪 terminal 扣住／早停丟棄／maxSteps・tokenBudget・hook veto 不 review／preamble 不入 draft／L1 retry 清 draft／consecutive-user／smart gate），另以本機 `HttpServer` capture 驗證真實 wire 契約（review 請求無 `tools`、`stream=false`、不送 `max_tokens`、rubric 併入最後 user 訊息、extraBody 已剝除），並新增 SSE finish-marker 回歸測試（尾塊 `finish_reason:null` 不得覆寫先前的 `stop`）。
- 回歸：`agent_loop_test`、`agent_orchestrator_test`、`agent_loop_provider_parity_test`、`agent_loop_followup_parity_test`、`chat_turn_service_test`、stream controller 三檔、settings 既有檔全綠；全套 `flutter test` 2,269 綠（僅 `sqlite_chat_storage_test` 2 案**既有**失敗，stash 驗證與本功能無關）。`flutter analyze` 於全部改動檔 0 error（repo 既有 3,269 則 lint 訊息不變）。
- 未驗證（P7）：真實 provider 實機 smoke（OpenAI／Claude／Gemini／DeepSeek × off/smart/always）、verdict 分佈與修正率量測、token 成本對照。
