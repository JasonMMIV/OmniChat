# 導入計畫：OmniChat Cowork 轉型總計畫（Agent Runtime + 工作區協作）

> **版本**：v1.1（2026-09-04）
> **v1.1 變更**：① P1-6 `shell_run` 自「一律審批」改為「allowlist 內免審批」；② P1-3 依使用者指示對照上游 kelivo `ask_user_input_v0`，補評估與採納清單（見 P1-3 評估表）
> **性質**：跨多版本的路線圖 + 實作計畫。**各 Phase 開工前應再出一份該 Phase 的細部執行計畫**（比照 `IMPORT_PLAN_CROSS_TURN_TOOL_RESULTS.md` 的粒度：逐檔案、逐測試）。
> **調查基礎**（2026-09-02 實際 clone / 讀碼）：
> - **OmniChat** master（v1.18.8+）
> - **kelivo** @ `7125a25`（串流層重構 `a43b79f`，2026-08-17）
> - **RikkaHub** @ `08c2648`（`GenerationHandler.kt` agent loop）
> - **AnyBuff**（本機 `C:\Users\w2bn1\Documents\GitHub\AnyBuff`；OmniChat §3.10 串流容錯層的移植來源）
> - **deepseek-harness**（github.com/deepseek-ai/deepseek-harness）

---

## 目錄

0. [背景與目標](#0-背景與目標)
1. [調查結論摘要（設計依據）](#1-調查結論摘要設計依據)
2. [架構決策（ADR）](#2-架構決策adr)
3. [Phase 0：AgentLoop 手術](#3-phase-0agentloop-手術)
4. [Phase 1：MVP Cowork](#4-phase-1mvp-cowork)
5. [Phase 2：重度場景](#5-phase-2重度場景)
6. [Phase 3：拋光](#6-phase-3拋光)
7. [全域風險與注意](#7-全域風險與注意)
8. [驗證策略](#8-驗證策略)
9. [附A：參考實作對照表（抄哪裡）](#9-附a參考實作對照表抄哪裡)
10. [附B：與專案手冊的同步清單](#10-附b與專案手冊的同步清單)

---

## 0. 背景與目標

> **現況**：OmniChat 是功能豐富的 LLM chat client，但已內建 workspace 檔案工具組、MCP 基礎設施、跨輪工具重放（§3.11）、串流容錯（§3.10）——開了工作區的對話**事實上已是短 agent run**，只是 agent 迴圈寄生在傳輸層（`chat_api_service.dart` ~9,000 行，4 份內嵌 `while(true)` 工具迴圈）。
>
> **目標**：升級為可勝任 **AI Cowork**（編輯文件、製作網站、多步驟研究）的應用——長任務可執行、可監督、可恢復——同時保持 chat 本業與跨平台穩定性。
>
> **不做**：不做雲端服務、不做通用瀏覽器 agent、不改動語音/即時通話主線。

### 0.1 現況的三個結構性問題（本計畫的直接動機）

| # | 問題 | 證據 |
|---|---|---|
| C1 | **工具迴圈寄生在傳輸層**：執行工具、重建 body、reasoning echo、多輪 follow-up 全部內嵌在 `_sendOpenAIStream` / `_sendClaudeStream` / `_sendGoogleStream` / Responses 路徑（L3200 / L6158 / L7115 等四份 `while(true)`） | `chat_api_service.dart`；kelivo 同期已把它拆出（`generation/tool_loop_runner.dart`） |
| C2 | **Retry 重放工具副作用**：L1 retry（`sendMessageStream` L994）以「整條工具鏈」為重試單位，鏈中段 5xx/silent-interrupt 會**從頭重跑所有 `onToolCall`**——`file_append` 內容重複、搜尋重複計費、MCP 副作用工具重複觸發 | 觸發機率與工具鏈長度成正比；kelivo 用 zero-yield gate 繞過（鏈中段直接放棄），RikkaHub 用「單步 retry」根治 |
| C3 | **無迭代上限、無預算**：模型反覆呼叫工具時唯一的止損是使用者手動停止；token 估算僅 `chars/4` 粗估 | 三家參考中 RikkaHub 有 `maxSteps=256`（參數化）；deepseek-harness 有壓力觸發 |

---

## 1. 調查結論摘要（設計依據）

### 1.1 三個 chat 專案的 agent loop 形狀

| 維度 | OmniChat（現況） | kelivo（`a43b79f` 重構後） | RikkaHub |
|---|---|---|---|
| Loop 位置 | ❌ 傳輸層內嵌 ×4 | ✅ `generation/tool_loop_runner.dart`（154 行，高於 providers/） | ✅ app 層 `data/ai/GenerationHandler.kt`（598 行） |
| 資料模型 | `tool_events_v1` 旁掛 box（無版本概念） | `message.parts`（ToolCallPart 按真實順序持久化） | `UIMessagePart.Tool`（call+result 同一 part，審批五態內建） |
| 迭代上限 | 無 | 無 | `maxSteps=256` 參數化（caller 可傳） |
| Retry 粒度 | 整鏈（C2 bug） | 整鏈 + zero-yield gate | **單步**（快照重合併 + 固定訊息 ID 覆蓋） |
| 審批/斷點 | 無 | 無 | 五態 + `canResumeExecution`（審批=迴圈暫停，非阻塞） |
| 長輸出 | 32KB head/tail 截斷 | 32KB 截斷 | 截斷→存檔→`cat`/`grep` 取回指令 |
| 執行能力 | QuickJS（無網路無檔案） | Claude code-exec 容器保活 | Proot rootfs + `workspace_shell`（Android！） |
| 譜系 | fork 自 kelivo | **8 月重構以 RikkaHub `ai` 模組為範本**（sealed StreamChunk / StreamChunkHandler / limitContext hysteresis 逐項對應） | 原創 |

### 1.2 兩個 harness 的互補資產

| 功能 | AnyBuff（Codebuff） | deepseek-harness | 採用 |
|---|---|---|---|
| 自動壓縮 | `compact-history.ts`：**確定性機械壓縮（零 LLM 呼叫）**、預算制（user 50k / assistant+tool 20k tokens）、`cache_expiry` 觸發（30 分鐘閒置=cache 已冷、壓縮免 cache 代價） | `compaction/`：`tool-pairing.ts`（增量 balance 計數器，保證切點永不拆散 tool_call/result 配對）、`compaction-tool-result-pruner`（中段修剪 8192/4096/1024）、`checkpoint.ts`（compactionId 溯源） | **兩家各取一半**：L0=deepseek 中段修剪、L1=AnyBuff 機械壓縮、切點安全=tool-pairing |
| 快照/回滾 | `propose_*` 工具 + per-runId `proposed-content-store`（提案→審批→套用，預防式） | ❌ 無 git snapshot（有 `tool-fs/diff.ts`） | 預防抄 AnyBuff；**回滾自建**（zip 快照，`archive` 套件現成） |
| 背景 + checkpoint | — | `session-checkpoint-policy`：**durable-before-dispatch**（模型請求前綴未落地不得發下一動作；工具分派前、步驟完成後三邊界）+ `SessionWriteBehind`（200ms 批次寫、JSONL、corruption 偵測、`interruptedTurnClosers`） | 語意移植，**Hive 輕量版**（messages/tool events 已持久化，只需補 step 邊界 + pending 落地 + resume 進入點） |
| Plan/TODO | `write_todos` / `create-plan` / `add-subgoal` handlers | `todo/tool-todo`：**極簡三態** `{content, status: pending|in_progress|completed}`、整表快照 last-write-wins、「Log-only UI state; never derived history」 | 資料模型抄 deepseek，工具介面形狀參考 AnyBuff |

### 1.3 為何 loop 屬於 app 層（決策依據）

1. **依賴方向**：loop 需要審批、todo、預算、壓縮、checkpoint——全是 app 概念。現在用 `onToolCall` 回呼把 app 行為注入傳輸層，每加一個概念就多一條穿過傳輸層的參數線（巨型檔案的成因）。正確方向：**UI → AgentLoop(driver) → {工具、ChatService、Settings} → ChatApiService（純傳輸）**。
2. **Retry 語義按範圍分家**：傳輸層 retry = 單次 HTTP 請求；「審批後 resume」= loop 語意。混在同一層即 C2 bug。
3. **有狀態 vs 無狀態**：`ChatApiService` 全 static（傳輸保真、無狀態）；loop 天生有狀態（messages 累積、step 計數、審批五態）。現況 flags 漂移（`flags?.` vs `flags.`）是狀態寄生 static 服務的症狀。
4. **三個獨立架構收斂同一答案**：RikkaHub（app 層）、kelivo（generation/ 高於 providers/）、deepseek-harness（checkpoint policy 坐在 llm/stream 之上）。
5. **OmniChat 已有兩個 app 層 loop 先例**：AI Team 串行調度（`chat_actions._runProposerSilently`）、voice（`ChatTurnService.startTurn`）——主聊天路徑是唯一異類。

---

## 2. 架構決策（ADR）

新增（應同步至手冊 §4 ADR 表）：

| # | 決策 | 內容 |
|---|---|---|
| ADR-A1 | **Loop 分兩層：kernel + driver** | kernel（純機械骨架：`while + execute + append + followUp`，無 Flutter import、可單獨測試）放 `lib/core/services/agent/`；driver（政策層：maxSteps、審批暫停/resume、todo、預算、壓縮觸發、checkpoint）放 `lib/features/home/services/`。kelivo `tool_loop_runner.dart` = kernel 形狀；RikkaHub `GenerationHandler` = driver 形狀 |
| ADR-A2 | **`ChatApiService` 退化為單輪傳輸** | `sendMessageStream` 語意 = 恰一輪（含單輪 L1 retry + §3.10 silent-interrupt 偵測）；多輪 follow-up 由 kernel 驅動；follow-up 訊息以 **OpenAI 中立格式**組裝，複用 §3.11 的三家轉換器（`_preserveToolStructuredMessages` / Claude `tool_use`/`tool_result` / Gemini `functionCall`/`functionResponse`） |
| ADR-A3 | **Retry 粒度 = 單步，且永不重放工具副作用** | 工具結果由 kernel/driver 持有並落地；重試只是重發同一個 follow-up 請求。RikkaHub 模式：每次 attempt 從「本步開始前的訊息快照」重合併、assistant 訊息 ID 固定（UI 覆蓋同一分支而非新增） |
| ADR-A4 | **上限 = 參數化 `maxSteps`（預設 256）+ 軟預算** | 不用固定小數字（deep research 單輪可達 20-30 次工具呼叫，見 `deep_research_store.dart` prompt 驅動協議）；預算耗盡時**停下來問使用者**（軟閘），而非硬切 |
| ADR-A5 | **審批 = 迴圈暫停，不是阻塞** | RikkaHub 五態 `Auto/Pending/Approved/Denied/Answered` + `canResumeExecution`；Denied → 以結構化 error JSON 回饋模型；Answered → 使用者答案直接作為工具結果（`ask_user` 模式）——kelivo `ask_user_input_v0`（`7125a25`）即此模式的完整 Dart 範本（結構化結果 JSON、取消語意、事後補答＝resume），評估值見 P1-3 |
| ADR-A6 | **壓縮 = 確定性機械優先，LLM 摘要其後** | 零 LLM 成本、可重放、無散文失真（AnyBuff 論證）；組裝期投影（assembly-time projection）**不改寫 Hive 歷史**——OmniChat 的歷史是可編輯/重生成的資產，壓縮必須非破壞性 |
| ADR-A7 | **Checkpoint = durable-before-dispatch（Hive 版）** | 模型請求前綴未落地，不得發下一動作；三邊界（round 前、工具結果落地後、step 完成後）。§3.10「不做 L3 整輪恢復」的 ADR 隨此**翻案**為「L3 = agent run 恢復」 |
| ADR-A8 | **政策分級：沙盒模式 vs 桌面開發者模式** | FileToolService 危險副檔名黑名單與 512KB/24KB 上限**維持為預設**（商店合規敘事不變）；桌面開發者模式（opt-in）才放寬：允許工作區內腳本、提高寫入上限、啟用 allowlist shell。**allowlist 內 `shell_run` 免審批**（2026-09-04 決策：dev-mode opt-in＋allowlist 比對即使用者明示同意閘，偏離 RikkaHub「一律 needsApproval」政策） |

---

## 3. Phase 0：AgentLoop 手術

> **目標**：C1/C2/C3 三個結構性問題一次解決。**不做任何新功能**。
> **建議版本**：v1.19.0（breaking-internal，kill-switch 保護）

### P0-1 Loop kernel（新檔 `lib/core/services/agent/agent_loop.dart`）

純 Dart、零 Flutter import。形狀參考 kelivo `tool_loop_runner.dart`（154 行）+ RikkaHub `GenerationHandler` 迴圈骨架：

```dart
class AgentLoopOptions {
  final int maxSteps;              // 預設 256（RikkaHub 對齊）
  final int? tokenBudget;          // 軟預算（跨輪累計 usage）
  final bool emitCalls;            // 工具卡片即時顯示
}

class AgentLoopEvent { ... }       // passthrough chunk + RoundStart/RoundEnd/StepBudgetReached

Stream<AgentLoopEvent> runAgentLoop({
  required List<Map<String, dynamic>> messages,   // OpenAI 中立格式（含 §3.11 重放結構）
  required Stream<ChatStreamChunk> Function(List<Map<String, dynamic>> round)
      sendRound,                                   // ← ChatApiService.sendMessageStream（單輪語意）
  required Future<String> Function(String name, Map<String, dynamic> args,
      {String? toolCallId}) onToolCall,           // ← ToolHandlerService handler（既有）
  required AgentLoopOptions options,
  required AgentLoopHooks hooks,                  // onRoundStart（預算/審批/壓縮檢查點）/ onToolExecuted / onRoundEnd
});
```

迴圈體（RikkaHub 語意）：

```
for (step in 0..maxSteps):
  hooks.onRoundStart(step)          // 預算檢查、審批 resume 判定、壓縮觸發（Phase 1 接入）
  round = await for sendRound(messages) → 收集 toolCalls chunk（透傳其餘 chunk）
  calls = round 的 toolCalls
  if calls.isEmpty → break
  executed = for each call → onToolCall(...)      // 副作用只在此發生一次
  messages += [assistant tool_calls msg] + [role:'tool' results]   // 中立格式
  hooks.onToolExecuted(executed)
```

**關鍵技術點**：
- `sendRound` 之間的 follow-up 訊息以中立格式組裝，**複用 §3.11 三家轉換器**（P7 已建：OpenAI 保留結構、Claude blocks、Gemini parts）——這是本次手術可行的地基。
- **Reasoning echo 不可回歸**：現有內嵌迴圈對工具 follow-up 帶 `reasoning_content` / `reasoning_details` / Gemini thought signature（§3.11 已知限制：跨輪重放不帶）。kernel 的中立 assistant 訊息需**擴充可選欄位**承載這些（round 間記憶體持有，不進跨輪重放），轉換器補對應輸出。測試必須鎖死（見 P0-6）。
- Dart `async*` 守則：kernel 內**一律 `await for` + `yield`，禁止 `yield*`**（§3.10 已記錄的 try/catch 限制，延伸至本檔）。

### P0-2 Loop driver（新檔 `lib/features/home/services/agent_orchestrator.dart`）

接線層，替代 `chat_actions` 中 `onToolCall: ctx.onToolCall` 的注入式接法（L620/786/898）：

- 持有 kernel 例項 + `ToolHandlerService` + `ChatService`（tool events 持久化走既有 `handleToolCallsChunk` 路徑不變，UI 工具卡片零改動）
- `hooks.onRoundStart` 實作：累計 usage（kelivo `88d5e83` 教訓：**usage 必須跨輪加總**）、軟預算閘、（Phase 1 起）審批暫停/resume、壓縮觸發
- resume 進入點：`resumeRun(conversationId, {approvedToolIds, answers})`
- kill-switch：Settings `agent_loop_v1`（預設 `true`；`false` = 舊傳輸層迴圈路徑），strangler 遷移期間兩路並存，**下一版 soak 後移除舊路徑**
- **2026-09-04 進度**：driver 已落地（`AgentOrchestrator.run`，stateless per run）：sendRound=單輪 `sendMessageStream(exposeToolCallsOnly: true, onToolCall: null)`、工具執行走既有 `(name,args)` handler、kernel 事件→chunk 重組（transport chunk 原樣透傳；`emitCalls` 合成 toolResults 照舊更新工具卡片；正常結束不重複發 isDone、早停/否決合成終端 isDone 帶累計 tokens）。**P0-4 缺口已關**：`ChatStreamChunk.assistantExtras`（transport 持有的 echo 政策）→ kernel 每輪末合併進 follow-up assistant `tool_calls` 訊息；OpenAI chat-completions 三站點（non-stream/stream/no-DONE）掛上 `reasoning_content`/`reasoning_details`，與 legacy `assistantToolCallMsg` 逐欄位相同。**驗證**：`agent_loop_followup_parity_test.dart` 新增「kernel run 與 legacy 逐位元組相等」（同 server 交替兩輪，`messages` payload 完全相等＋echo 到位）；`agent_orchestrator_test.dart` 5 案（透傳/工具輪/早停合成 isDone/hook 否決零請求/supportsKernelPath）。**接線**：`chat_actions._executeGeneration` 依 `ctx.settings.agentLoopV1 && AgentOrchestrator.supportsKernelPath(config) && ctx.onToolCall != null` 分流；`supportsKernelPath` 目前限 OpenAI chat-completions（Claude thinking-block、Gemini thought-signature、Responses output_item 續傳的 follow-up echo 尚未貫通＝P0-3 後段，這些 provider 在 parity 測試補齊前維持 legacy 路徑）。**2026-09-04 P0-3 後段（echo 貫通）**：Claude 與 Gemini 的 follow-up echo 已貫通並有 parity 測試（`agent_loop_provider_parity_test.dart`）：① Claude——expose 站點（non-stream＋streaming round-end surface）把本輪 thinking/redacted_thinking blocks（含 signature）掛上 `assistantExtras['claude_thinking_blocks']`，kernel 合併進中性 assistant 訊息，`_sendClaudeStream` 的轉換器讀回並在 tool_use 前重建 blocks（Anthropic 要求 thinking 開啟時必須回帶）；② Gemini——non-stream 與 streaming per-part 的 expose 站點把每個 functionCall 的 thought signature 掛上 `assistantExtras['gemini_thought_sigs']`（keyed by call id），兩個轉換器（non-stream L~7050／streaming L~7450）依 tool_call id 讀回並附到 functionCall part（取代 `_ensureGeminiFunctionCallThoughtSig` 的 placeholder），non-stream 同時改用 vendor call id 取代硬編碼 `fn_0`；③ 修正 Gemini streaming expose 輪**尾發 isDone** 的契約違反（原會落到 `calls.isEmpty` 終端塊）：`exposeSurfacedCalls` 旗標讓 expose 輪乾淨 return、不發 isDone、不誤入 `while(true)` 續迴圈——這同時消除了 driver 路徑下 UI 早終止的隱患。**驗證**：Claude/Gemini 各一 parity 案全綠（legacy 與 kernel 各自跑完兩輪，follow-up `messages`/`contents` 逐位元組相等、echo 欄位到位）；`supportsKernelPath` 放寬為 openai/claude/google（Responses 續傳與 Neuralwatt 仍未驗證，維持 legacy）；driver 測試更新為新閘。**2026-09-04 Responses 續傳 parity 已關**：Responses `output_item` 續傳已貫通並有 parity 測試（`agent_loop_provider_parity_test.dart` 第 3 案，SSE fixture：output_item.added→delta→done→response.completed 帶 `response.output`［assistant message item＋function_call item］）：① expose 站點把本輪原始 output items 掛上 `assistantExtras['responses_output_items']`（含 assistant `message` item）；② input builder 在中性 assistant 訊息攜帶該欄位時，改用 `_withResponsesFunctionCallItems`（legacy 續傳同一函式）重放原始 items 逐位元組等價——kernel follow-up `input` 與 legacy `currentInput`（initialInput＋replay＋function_call_output）完全相等；③ `supportsKernelPath` 全面放寬為 openai（含 Responses）/claude/google；Neuralwatt 維持 legacy（工具迴圈形狀未驗證）。**驗證**：3 parity 案全綠（Claude/Gemini/Responses）；driver 測試更新（Responses→true）。**尚缺**：Neuralwatt parity（可選）；`hooks.onRoundStart` 的 Phase-1 審批暫停/resume 與 `resumeRun` 實作（Phase 1 範圍）；P0-3 後段最後一步＝在 kill-switch 後移除四條舊迴圈。

### P0-3 `ChatApiService` 瘦身

- 移除四條內嵌多輪迴圈（chat-completions L3200 / Responses / Claude L6158 / Google L7115），`sendMessageStream` = 單輪 + 既有 L1 retry（範圍自動縮為單輪）+ §3.10 偵測（粒度自動降為單輪）
- **2026-09-04 偵察結論（影響接線順序）**：逐行確認三家的所有工具分支都以 `onToolCall != null` 為閘（OpenAI stream/non-stream/Responses 多子路、Claude L6287/6690/6825、Google L7165/7891）——**onToolCall 為 null 時工具呼叫連 `chunk.toolCalls` 都不會透出**，kernel 會誤判為「無工具、正常結束」。因此 kernel 路徑不能直接以「不傳 onToolCall」接線；P0-3 需先為 `_sendXxxStream` 加「單輪 expose 模式」
- **2026-09-04 進度**：`exposeToolCallsOnly`（預設 `false`＝舊行為不變）已實作並貫通 `sendMessageStream`→三家 provider。**已覆蓋**：OpenAI chat-completions（non-stream JSON 與 SSE stream、finish_reason='tool_calls' 早執、無 [DONE] 的 vendor fallback、巢狀 follow-up 的 toolAcc2 副本）、OpenAI Responses 主輪、Claude streaming（per-block 執行改為收集、round 尾一次 yield toolCalls 即 return）、Google 主 functionCall 路徑。**驗證**：`send_message_stream_expose_test.dart`（3 案：non-stream/stream/no-DONE vendor fallback——各 1 請求、零執行、單一 toolCalls chunk、無 follow-up）＋ `send_message_stream_expose_providers_test.dart`（4 案：Claude non-stream/streaming、Gemini non-stream/streaming 次要路徑）＋ parity/回歸全綠。**2026-09-04 補齊**：① Claude streaming 的 per-block placeholder toolCalls（content_block_start tool_use、server_tool_use web_search、srv args 三處）在 expose 下抑制，round 尾只發一次完整參數的 toolCalls；② OpenAI 無 [DONE] fallback 在 toolCalls yield 後補 `return`（原本會落到 `onToolCall!` 崩潰）；③ Google 次要 per-part functionCall 路徑（L~7930）在 expose 下跳過執行、不進 `calls`，round 正常收尾（多 part 多 chunk 由 kernel 合併，`agent_loop.dart` 已驗證逐 chunk 累加）。已確認設計上安全：OpenAI Responses 巢狀副本（L4244）與 OpenAI/Claude 的 follow-up 迴圈副本（L5699/5829）在 expose 下**結構性不可達**（主輪即 return）。**2026-09-04 補齊**：Responses expose 測試已入（`send_message_stream_expose_test.dart` 第 4 案：output_item.added→function_call_arguments.delta→output_item.done→response.completed，單一 toolCalls chunk、零執行、零 follow-up），expose 覆蓋 8 案全綠。**2026-09-04 P0-3 後段 echo 全貫通**：Claude thinking-block、Gemini thought-signature、Responses output_item 續傳三家 follow-up echo 均已掛載 assistantExtras、kernel 合併、轉換器讀回，並各有 parity 測試（見 P0-2 進度）；`supportsKernelPath` 已放寬為 openai（含 Responses）/claude/google，僅 Neuralwatt 維持 legacy。
- 保留：`_truncateToolResultsInMessages`、`_sanitizeMessages`、廠商 quirk/參數剝離、§3.11 轉換器
- 語音路徑 `ChatTurnService`（語音工具為單輪搜尋）**本階段不動**

### P0-4 交付清單

| 項目 | 內容 |
|---|---|
| 新檔 | `lib/core/services/agent/agent_loop.dart`（已完成）、`lib/features/home/services/agent_orchestrator.dart`（待 P0-2）；另抽純 Dart `lib/core/services/api/chat_stream_chunk.dart`（ChatStreamChunk/ToolCallInfo/ToolResultInfo，chat_api_service import＋export）供 kernel 引用 |
| 修改 | `chat_api_service.dart`（移除四迴圈）、`chat_actions.dart`（改接 driver）、`settings_provider.dart`（kill-switch）、`generation_controller.dart` / `stream_controller.dart`（事件透傳） |
| 手冊 | 新增 §3.13 Agent Runtime；§3.10 補記 retry 粒度變更 |

### P0-5 已知接受的限制

- kernel 中立訊息不進行跨輪持久化（跨輪仍走 §3.11 重放）→ 重生成版本無舊工具事件的限制不變（kelivo `message.parts` 資料模型遷移**不在 Phase 0**，列為 Phase 2+ 可選項）
- voice 與 AI Team proposer 路徑沿用舊接法（`_cloneForProposer` 產物相容），需回歸測試確認

### P0-6 測試（Phase 0 驗收）

1. **kernel 單元測試**（fake `sendRound`，零 HTTP）：多輪工具順序、maxSteps 停止、工具失敗不斷迴圈（error JSON 透傳）、預算軟閘事件
2. **body 逐位元組對照**：新舊路徑對同一腳本產出的 follow-up body 必須一致（HttpServer 捕獲，沿用 `replay_tool_results_api_test.dart` 風格）——**特別覆蓋 reasoning echo 場景**（DeepSeek `reasoning_content`、OpenRouter `reasoning_details`、Gemini thought sig）
3. **副作用重放回歸**：模擬第 2 輪 503 → 驗證 `file_append` 只執行一次、`search_web` 只計費一次
4. 既有回正：`chat_turn_service_test`、`deepseek_claude_compat_test`、`claude_prompt_caching_test`、`replay_tool_results_api_test`、`home_view_model_compress_context_test`、`chat_service_file_record_test`

---

## 4. Phase 1：MVP Cowork

> **目標**：使用者可以在工作區內完成一個受監督的多步驟檔案任務（改文件、建小網站）。
> **建議版本**：v1.20.x
> **獨立積木**（不依賴 Phase 0，可先行出貨）：P1-2 的 L0、P1-3、P1-4。

### P1-1 審批五態 + Diff 檢視（抄 RikkaHub）

- **資料**：tool event record 增加 `approvalState`（`tool_events_v1` 為版本化 box，加欄位安全）；狀態機 `Auto → Pending → Approved/Denied/Answered`
- **政策**：`ToolHandlerService.buildToolDefinitions` 加 per-tool `needsApproval` 回呼——檔案工具（沙盒內）免審、路徑出界升級審批、`shell_run` **免審批**（allowlist 內；allowlist 外直接拒絕、不彈審批，見 P1-6）
- **Driver**：遇 `needsApproval` → 標記 Pending → 持久化 → **break**（ADR-A5 語意）；使用者批准/拒絕/答覆 → `resumeRun` 從斷點續跑
- **UI**：工具卡片加審批列（Approve / Deny / 自由文字 Answer；Answer 卡即 `ask_user` 問答卡，見 P1-3 評估）；`file_edit` 未執行時以 `old_text`/`new_text` 參數生成**預覽 diff**，執行後由 metadata 帶**全檔 diff**（RikkaHub `WorkspaceToolUIs.diffOf` 模式）——diff 渲染可先以 unified diff 文字塊呈現，Phase 3 再升級專屬 viewer
- **l10n** ×4 語系 + `flutter gen-l10n`

### P1-2 自動壓縮（L0 + L1 + 觸發）

分層（插入點 = `buildApiMessages` 出口，與 §3.11 同位置）：

| 層 | 內容 | 來源 |
|---|---|---|
| L0 | **工具結果中段修剪**：threshold 8192 / head 4096 / tail 1024 chars、`[... tool result middle pruned ...]` 標記、surrogate-safe 計數；適用於重放 tool events 與跨輪 tool 訊息；既有 32KB head/tail 保留為極端值後盾 | deepseek `compaction-tool-result-pruner/config.ts` |
| L1 | **機械式歷史壓縮**：把壓縮範圍內的訊息重寫為結構化 `<conversation_summary>`（工具呼叫降為一行 `inspected files: X` / `wrote file: Y`；user 截 13k tokens、assistant 截 1.3k、tool 條目截 5k；80/20 head/tail）；預算 user 50k / assistant+tool 20k tokens（`chars/3` 尺） | AnyBuff `compact-history.ts` |
| 觸發 | (a) `usage.promptTokens` > 模型 context window × 75%（usage 已有，context window 需 per-model 常數表）；(b) **`cache_expiry`**：閒置 ≥30 分鐘（cache 已冷 → 壓縮的 cache 代價為零；Anthropic ephemeral TTL 考量，寧可錯過免費壓縮也不丟溫 cache） | AnyBuff 觸發器 + OmniChat §3.5 prompt caching |
| 切點安全 | **tool-call/result 配對增量 balance 計數器**：壓縮切面永不落在 tool_calls 與其 role:tool 結果之間（§3.11 配對完整性的演算法化保證） | deepseek `tool-pairing.ts` |
| 非破壞性 | **組裝期投影**：不改寫 Hive 訊息；持久化一個「compact before index N」標記（語意同既有 `truncateIndex`）保證跨輪穩定；機械壓縮輸出確定性 → 每次組裝重算即可，無需儲存摘要 | ADR-A6 |
| 下限 | 低於 2×（20k+50k）=140k tokens 的 context 不做投機性壓縮（資訊損失不划算；AnyBuff 論證含兩把尺子換算誤差） | AnyBuff `DEFAULT_CACHE_EXPIRY_MIN_TOKENS` |

### P1-3 Plan/TODO 物件（deepseek 資料模型 + kelivo 問答卡 UI）

- **資料**：新 Hive box `todo_v1`，key = conversationId，value = `TodoItem[] {content, status: pending|in_progress|completed}`——**整表快照寫入（last-write-wins）、無 id 無 priority**、replay 安全
- **工具**：`write_todos`（免審批）加入 `ToolHandlerService`；模型每次全量重寫。**列為 log-only 工具**：事件仍走一般工具流程落地（卡片在訊息流中的定位與備份免費），但**排除於 §3.11 重放與 L0/L1 配對壓縮**——計畫快照只以最新狀態注入（見下），避免每輪把整份計畫灌進 context
- **注入**：當前 todo list 以穩定位置注入 system prompt 尾部（cache 前綴友好）；**絕不進對話歷史**（「Log-only UI state; never derived history」）
- **UI**：計畫卡以 `write_todos` 工具事件卡呈現於訊息流該輪位置，形狀抄 kelivo AskUser 卡（見下方評估）：標題列（icon＋標題＋狀態膠囊＋收合）、三態勾選清單（pending / in_progress / completed）、全部完成自動收合為「N/M 完成」摘要；桌面與行動共用既有工具卡元件
- **決策配套**：新增免審批工具 `ask_user`（schema、UI、語意抄 kelivo `ask_user_input_v0`；**名稱定案 `ask_user`**，2026-09-04 使用者確認）——單/多選題、UI 自動附 Other 自由文字與 Skip、結構化作答 JSON；模型於計畫執行中需使用者抉擇（方向、取捨、計畫確認）時呼叫——與 P1-1 五態的 Answered、P3-5 Plan Mode 的「人批」共用同一互動卡
- **同步**：todo 屬對話資料 → 隨既有對話同步規則；不進 `_localOnlyKeys`

**評估：kelivo `ask_user_input_v0`（2026-09-04 實讀 `7125a25`）**——依使用者指示，以 Plan/TODO 為目的對照上游此工具：

| kelivo 資產（7125a25） | 內容 | 評估結論 |
|---|---|---|
| `ask_user_interaction_service.dart`（268 行） | `AskUserQuestion{id, question, kind: single/multi, options}`；引數正規化（≤4 題、每題 ≤4 選項、id 去重重編）；結果 `AskUserResult.toJsonString()`：`{type:'ask_user_answer', answers:{id:{type,value,custom,skipped}}}` 或 `{type:'tool_error'}`；pending 以 toolCallId 索引；`cancelAll`/`cancelForConversation`（中斷 → cancelled error JSON 回饋模型） | **採納資料紀律**：問答式決策的引數上限與結構化結果 JSON 直接套用於 todo/ask_user 卡與審批回饋——Denied＝error JSON、Answered＝answer JSON 正好是現成的兩種形狀 |
| AskUser 卡 UI（`chat_message_widget.dart` L6012-6768：`_AskUserToolCard`/`_AskUserInlineBody`/`_AskUserQuestionView`/`_AskUserAnsweredQuestion`/`_AskUserSubmitButton` 等） | 內嵌訊息流的工具卡：標題列（icon＋標題＋狀態＋摺疊）、single＝radio / multi＝checkbox、**UI 自動提供 Other 自由文字與 Skip**（工具 description 明令模型不必自己加）、Submit 需全部作答、作答後收合為摘要並標「Answered」；以 `context.watch` 綁定 pending 服務即時反映 | **採納（P1-3 UI 藍圖）**：todo 卡照此形狀。kelivo 以 message part 為卡錨，OmniChat 改以 log-only 工具事件為錨（見上），卡片外觀、作答表單、摘要收合皆可移植。另有兩點可補強 P1-1 審批卡：pending 時顯示引數摘要（`_argsSummary` monospace 2 行）、Deny 帶理由 dialog |
| resume 語意（`home_page_controller.submitRecoveredAskUserAnswer` L1017、`chat_actions` L1936） | 「呼叫已落地、content 未作答」的歷史卡可**事後補答**：upsert tool event content → `continueAssistantMessageAfterToolAnswer` 續跑該 assistant 訊息 | **採納（重要）**：工具事件（call＋args 已持久化、只欠 content）本身就是天然 checkpoint——審批與問答的 resume ＝ 補 content＋續跑，Phase 1 即可兌現 ADR-A5 精神；P2-1 的 `agent_runs_v1` 縮小為「跨 session/背景續跑」才需要 |
| 阻塞執行（tool handler 內 `await Completer.future`） | kelivo 以阻塞等待作答（其內嵌 loop 可接受） | **不採納**：OmniChat 維持「Pending → break → resume 續跑」，等待期間不掛住 SSE 連線；只抄卡片與資料，不抄阻塞語意 |
| `tool_approval_service.dart` | MCP 與 `requiresUserApproval` local tools 的審批服務；**pending key 為 (conversationId, toolCallId) 雙重作用域**，防兩對話共用 round 序號 id 時互相污染 | **只取作用域守則**：P1-1 pending 索引必須含 conversationId（kelivo 已踩過此坑） |
| `test/ask_user_interaction_service_test.dart`（134 行） | 正規化、作答、取消語意單元測試 | 移植為 OmniChat `ask_user_test.dart`（Phase 1 驗收） |

**結論**：todo 卡與 ask_user 卡共用一套「內嵌訊息流互動卡」元件（標題列＋膠囊＋收合＋作答表單/摘要）；`ask_user` 為獨立小工具、可先行出貨；審批與問答的 resume 統一走「tool event 補 content＋續跑」路徑。

### P1-4 長輸出外部化（抄 RikkaHub `maybeTruncateToolOutput`）

- 超過 32KB 的工具輸出 → 寫入 workspace `.omnichat/tool_outputs/{toolCallId}.txt` → 回傳 4KB preview + 明確取回指引：「完整輸出於 `X`，用 `file_read` 讀取 / 搜尋關鍵字」
- 位置：`ToolHandlerService` 的執行包裝層；**不依賴 Phase 0，可先行**

### P1-5 工作區快照 + 一鍵回滾（自建）

- **快照**：agent run 啟動時（workspace 啟用）以 `archive`（既有依賴，備份管線已用）對工作區做 zip 快照至 `.omnichat/snapshots/{runId}.zip`；保留最近 5 份 + 總量守衛（防 workspace 巨大時暴衝，沿用 §5.4 記憶體教義：串流寫入）
- **回滾**：對話頁「本次任務改動 N 檔案 → 還原」入口 + run 結束卡片上的還原鈕；還原 = 快照覆寫 + FileRecord 卡片標記
- **同步**：快照屬裝置本地 → 加入 `_localOnlyKeys` 排除集合（§5.7 審查）

### P1-6 桌面開發者模式 + Allowlist Shell

- **設定**：`developer_mode_v1`（桌面限定、預設 `false`）+ allowlist（預設 `git, node, npm, npx, python, pip, pandoc, ffmpeg`，可增刪）
- **新工具 `shell_run`**：`Process.run` 於 workspace cwd；**免審批（2026-09-04 決策）**——allowlist 精確比對（第一個 token）是唯一閘門：dev-mode opt-in＋allowlist 成員身分即使用者明示同意，逐次審批只會打斷高頻 shell 工作流；**allowlist 外不彈審批、直接回傳錯誤**。硬逾時看門狗；輸出 32KB head/tail + stdout/stderr 分流；環境變數最小化
- **§5.1 教義延伸**：外部程序一律串行（與 `npm install` 等長命令互斥）、輸出截斷、never-parallel 守衛
- **政策分級**（ADR-A8）：開發者模式內允許在工作區建 `.sh/.ps1` 等腳本檔（黑名單例外僅桌面+opt-in），執行時把直譯器（`bash`、`python` 等）加入 allowlist 即可用 `shell_run` 執行；Android 維持全黑名單、不提供 `shell_run`
- **合規**：更新 `STORE_REVIEW_PLAN.md`——MSIX/WACK 重跑（shell 能力敘述）、F-Droid metadata（Android 不受影響，敘事簡單）

### P1-7 測試（Phase 1 驗收）

- L0/L1 壓壓縮：參考實作移植的 **parity 測試**（固定歷史 → 期望摘要快照）；**配對安全性質測試**（隨機產生含工具呼叫歷史 → 斷言所有切點 balanced）；觸發條件（usage 閾值 / cache_expiry）單元測試
- 審批：斷點續跑（Pending → resume → 迴圈從正確步繼續）、Denied → error JSON 進 body、五態 UI 快照測試
- todo/ask_user：整表寫入冪等、注入位置穩定（cache 前綴不變）、**log-only 排除（不進 §3.11 重放）**、作答 JSON/取消語意/事後補答 resume（移植 kelivo `ask_user_interaction_service_test.dart`）
- 快照：建立/回滾/上限輪替；`.omnichat/` 排除於備份
- shell：allowlist 精確比對（成員直接執行；非成員**即時拒絕且不觸發審批 UI**）、逾時殺進程、輸出截斷、dev-mode 關閉時工具不注入/呼叫被拒
- 全域：`flutter analyze --no-pub` 0 errors；既有回歸 + 新測試全綠

---

## 5. Phase 2：重度場景

> **建議版本**：v1.21.x+（可拆多版）

| # | 項目 | 內容 | 藍圖 |
|---|---|---|---|
| P2-1 | **Checkpoint 持久化** | 新 Hive box `agent_runs_v1`：{conversationId, messageId, stepIndex, pendingApprovals, todos, usage, roundMessages ref}；**durable-before-dispatch** 三邊界（round 發送前綴落地後才發請求 / 工具結果落地後才進下一步 / step 完成標記落地）；落地採 debounce 批次（~200ms）；app 啟動偵測未完成 run → 橫幅「繼續任務？」→ `resumeRun` | deepseek `session-checkpoint-policy` + `SessionWriteBehind` 語意，Hive 輕量版；§3.10「無 checkpoint」ADR 翻案 |
| P2-2 | **背景長任務** | 桌面：關窗縮托盤續跑（`desktop_tray_controller` 現成）+ 完成托盤通知；Android：`AndroidBackgroundManager` 前景服務（現成）+ 通知 | 既有基建 + P2-1 |
| P2-3 | **子代理** | 泛化 AI Team 串行調度（ADR 延續 §5.1）：`spawn_subagent` 工具——子代理全新 context、角色 prompt、回傳摘要；主對話不收原始工具軌跡。候選用途：檔案批量摘要、平行翻譯、research fan-out | AnyBuff `agents/`（file-picker/researcher/thinker 等 template 模式）+ `AiTeamController` |
| P2-4 | **Mini dev server + Live 預覽** | 127.0.0.1 隨機埠靜態伺服 workspace；`html_preview_dialog` 升級為分頁面板；檔案變更自動重整（watch + 注入 reload bridge）；console 捕獲（注入 bridge）→ 工具 `get_console_errors` | 既有 `html_preview_*` + 新 `dev_server_service.dart` |
| P2-5 | **Proot on Android**（stretch） | rootfs 下載/安裝/patch + `ProotShellRunner` → 手機端 `shell_run`；先做可行性評估（rootfs 體積、F-Droid 政策、效能）再決定 | RikkaHub `workspace/` 模組 |
| P2-6 | **L2/L3 壓縮** | L2：LLM 摘要壓縮（deepseek `compaction-basic`，用 `generateText` 既有方法）供 L1 機械摘要不足時；L3：**工作區檔案地圖**——組裝期注入 workspace 樹 + per-file 一行描述（來自 FileRecord/mtime），模型需詳情再 `file_read` 指定範圍 | deepseek `compaction-basic` + AnyBuff `truncate-file-tree` 概念 |
| P2-7 | **（可選）kelivo 資料模型對齊** | `message.parts` 遷移 + sealed StreamChunk 事件模型 + trace 錄製回放測試——**僅在需要持續吸收上游 decoder 修補時才做**，否則維持 `tool_events_v1` 投影 | kelivo `a43b79f` + `docs/ai-stream.md` |

---

## 6. Phase 3：拋光

| # | 項目 | 內容 |
|---|---|---|
| P3-1 | 瀏覽器 QA 工具 | Playwright via MCP STDIO（桌面限定）：截圖、console errors、點擊驗證——掛入既有 MCP 基礎設施（`mcp_pane` UI 現成） |
| P3-2 | Skill 庫 | SKILL.md 集合管理：來源 URL + `computedHash` 鎖定（RikkaHub `skills-lock.json` 模式），per-assistant 勾選注入 |
| P3-3 | 跨會話任務恢復 | `agent_runs_v1` 未完成 run 清單 UI（全域「進行中任務」頁）→ resume |
| P3-4 | 上限再校準 | 開發者模式寫入上限提升（2MB 級）+ 磁碟預算顯示；`file_read` 分頁體驗優化 |
| P3-5 | Plan Mode | 先規劃（模型產出計畫）→ 人批 → 再執行的模式切換 | deepseek `plan/plan-mode` |

---

## 7. 全域風險與注意

| 風險 | 緩解 |
|---|---|
| **Reasoning echo 回歸**（P0 最大風險）：中立格式 follow-up 若丟失 `reasoning_content`/`reasoning_details`/Gemini thought sig，DeepSeek/Kimi/OpenRouter 多輪工具會降智或報錯 | kernel 中立訊息擴充可選承載欄位 + body 逐位元組對照測試鎖死（kelivo `0f44150`「fix(deepseek): echo reasoning for tool continuations」為前車之鑑） |
| **壓縮 × prompt cache 互咬**：每輪壓一點 = cache 永遠冷 | `cache_expiry` 觸發 + 成批壓縮 + 注入位置穩定；L1 摘要放系統區尾、todo 注入固定槽位 |
| **兩把 token 尺**：預算用 `chars/3`、閾值用 usage 實測——混用會誤判 | 觸發一律以 usage 實測為準；chars 估算僅作 L1 內部預算；下限 floor 取保守值 |
| **Windows 穩定性（§5.1）**：外部程序是新的記憶體/並發風險源 | shell 串行、輸出截斷、看門狗；§5 手冊補一節「外部程序治理」 |
| **商店合規**：shell/腳本能力改變 MSIX/F-Droid 審查敘事 | ADR-A8 政策分級：預設路徑能力不變（黑名單照舊）；`STORE_REVIEW_PLAN.md` 隨 P1-6 更新；WACK 重跑 |
| **同步（§5.7）**：新鍵值分類 | `developer_mode_v1`、shell allowlist、審批政策 = 全域偏好（同步）；快照、agent_runs、tool_outputs = 裝置本地（排除）；todo 隨對話資料 |
| **Dart `async*`**：`yield*` 於 try/catch 的例外穿透限制 | kernel/driver 一律 `await for` + `yield`；手冊 §3.10 守則標注適用範圍擴及 `agent/` |
| **voice/AI Team 路徑** | P0 明確不動 + 回歸測試（`chat_turn_service_test`、AI Team smoke） |
| **舊路徑雙軌期** | kill-switch + 一個 soak 版本後移除；雙軌期內不對舊迴圈加任何新功能 |

---

## 8. 驗證策略（各 Phase 收尾必跑）

```bash
flutter gen-l10n                # 有新增 l10n key 時
flutter analyze --no-pub        # 0 errors（既有 warnings/info 不增量）
flutter test                    # 新增測試 + 既有回歸（重點清單見各 Phase）
```

- 各 Phase 出貨前：Windows（含 ARM64）+ Android 手動 smoke；涉 MSIX 變更跑 `tool/run_wack.ps1`
- 手冊同步：依附B 清單更新 `OmniChat 專案開發與維護手冊.md`（架構變更級 → 必更）

---

## 9. 附A：參考實作對照表（抄哪裡）

| 參考 | 位置 | 用於 |
|---|---|---|
| **kelivo** `7125a25`（`/tmp/kelivo-upstream`） | `lib/core/services/api/generation/tool_loop_runner.dart`（154 行）；`docs/ai-stream.md`；`stream/retrying_stream.dart`；`providers/{claude,google,openai}/`；`models/message_part.dart`；`tool/trace_recorder.dart` + `test/fixtures/stream-traces/`；`lib/features/home/services/ask_user_interaction_service.dart`（268 行）+ `tool_approval_service.dart`；`lib/features/chat/widgets/chat_message_widget.dart` AskUser/Approval 卡（L6012/L5862 起）；`home_page_controller.submitRecoveredAskUserAnswer`（L1017）；`test/ask_user_interaction_service_test.dart`（134 行） | P0 kernel 形狀（Dart 範本）、單輪 provider 分層、（可選 P2-7）資料模型與 trace 回放測試、P1-3 問答卡 UI 與「tool event 補答＝resume」範本 |
| **RikkaHub** `08c2648`（`/tmp/rikkahub`） | `app/.../data/ai/GenerationHandler.kt`（598 行）；`ai/core/Tool.kt`（`needsApproval`）；`app/.../tools/WorkspaceTools.kt`；`ui/.../WorkspaceToolUIs.kt`（`diffOf`）；`ai/ui/Message.kt`（`limitContext` hysteresis、`alignContextStart`）；`workspace/`（Proot） | P0 driver 語意（maxSteps/審批=暫停/resume/單步 retry 快照重合併）、P1-1 審批五態+diff、P1-4 長輸出外部化、P2-5 Proot |
| **AnyBuff**（本機） | `packages/agent-runtime/src/compact-history.ts`（機械壓縮 + cache_expiry + 預算）；`tools/handlers/tool/proposed-content-store.ts`（提案→審批→套用）；`write-todos.ts`；`agents/`（子代理 template）；`sdk/src/impl/llm.ts`（§3.10 移植源） | P1-2 L1 壓縮、P1-1 提案式審批補充、P1-3 工具介面、P2-3 子代理 |
| **deepseek-harness**（`/tmp/deepseek-harness`） | `packages/compaction/compaction/src/{tool-pairing,checkpoint,index}.ts`；`compaction-tool-result-pruner/src/config.ts`（8192/4096/1024）；`session/session-checkpoint-policy/src/index.ts`（durable-before-dispatch）；`session/session-persistence/src/{coordinator,write-behind}.ts`；`todo/tool-todo/src/types.ts`（三態整表模型）；`plan/plan-mode` | P1-2 L0+切點安全+觸發詞彙、P2-1 checkpoint、P1-3 todo 資料模型、P3-5 Plan Mode |

> 移植須知：RikkaHub 為 Kotlin/Compose——**抄決策與語意，不抄代碼**；kelivo 為 Dart 可近逐行參考但資料模型已分岔（§3.11）；AnyBuff 為 TypeScript——`compact-history.ts` 自帶完整設計註釋與 parity test 模式，價值最高。

---

## 10. 附B：與專案手冊的同步清單

| 手冊位置 | 動作 | 時機 |
|---|---|---|
| §3.10 串流容錯層 | 補記：retry 粒度自「整鏈」改為「單輪」；L1 迴圈範圍重定義；`await for` 守則擴及 `agent/` | Phase 0 |
| §3.11 跨輪重放 | 補記：L0/L1 壓縮插入點與配對安全（tool-pairing）互動 | Phase 1 |
| 新增 §3.13 Agent Runtime | kernel/driver 分層、maxSteps、審批=暫停、resume、checkpoint | Phase 0/2 |
| §4 ADR 表 | 新增 ADR-A1~A8（見本文 §2）；翻案「不做 L3 整輪恢復」 | Phase 0 / 2 |
| §5.1 Windows 穩定性 | 新增子節「外部程序治理」（shell 串行/截斷/看門狗） | Phase 1（P1-6） |
| §5.7 `_localOnlyKeys` | 新鍵值歸類審查（快照/agent_runs 本地；dev mode/審批政策同步） | Phase 1 |
| §7 現狀與待辦 | 各 Phase 完成後更新 roadmap | 每版本 |
| `STORE_REVIEW_PLAN.md` | P1-6 合規敘事更新 + WACK 重跑記錄 | Phase 1 |

---

## 進度追蹤

| # | 項目 | 藍圖 | 狀態 |
|---|---|---|---|
| P0-1 | Loop kernel（`core/services/agent/agent_loop.dart`） | kelivo `tool_loop_runner` + RikkaHub 迴圈 | ✅ 2026-09-04（12 tests 綠） |
| P0-2 | Loop driver（`features/home/services/agent_orchestrator.dart`） | RikkaHub `GenerationHandler` | 🟡 driver＋kill-switch 接線已落地（OpenAI chat-completions / Claude / Gemini 走 kernel，parity 全綠）；待：Phase-1 hooks 實作 |
| P0-3 | `ChatApiService` 單輪化 + kill-switch | kelivo providers 分層 | 🟡 exposeToolCallsOnly 已入且各家 expose 測試 8 案全綠；Claude/Gemini/Responses follow-up echo 已貫通（3 parity 案全綠）；待：舊迴圈移除（kill-switch 後） |
| P0-4 | reasoning echo 承載 + body 對照測試 | kelivo `0f44150` 教訓 | ✅ 2026-09-04（assistantExtras 貫通＋kernel/legacy 逐位元組 parity 2 案綠） |
| P0-5 | maxSteps + 軟預算 | RikkaHub + ADR-A4 | 🟡 kernel 內建（maxStepsReached/tokenBudgetReached 事件）；driver 已透傳 options（早停合成 isDone 測試綠）；使用者可見的軟閘 UX 待 Phase 1 |
| P1-1 | 審批五態 + diff + resume | RikkaHub | ⬜ |
| P1-2 | 壓縮 L0/L1 + 觸發 + 配對安全 | deepseek + AnyBuff | ⬜ |
| P1-3 | TODO 物件 + 注入 + UI + ask_user 決策卡 | deepseek + kelivo（評估值採納） | ⬜ |
| P1-4 | 長輸出外部化（**可先行**） | RikkaHub | ⬜ |
| P1-5 | 工作區 zip 快照 + 回滾 | 自建 | ⬜ |
| P1-6 | 開發者模式 + allowlist shell（allowlist 內免審） | ADR-A8（allowlist 為閘） | ⬜ |
| P2-1 | Checkpoint 持久化（durable-before-dispatch） | deepseek | ⬜ |
| P2-2 | 背景長任務 | 既有基建 | ⬜ |
| P2-3 | 子代理 | AnyBuff agents/ | ⬜ |
| P2-4 | Dev server + live 預覽 | 既有 html_preview | ⬜ |
| P2-5 | Proot on Android（stretch） | RikkaHub workspace/ | ⬜ |
| P2-6 | L2/L3 壓縮（LLM 摘要 + 檔案地圖） | deepseek + AnyBuff | ⬜ |
| P2-7 | （可選）kelivo parts 資料模型對齊 | kelivo `a43b79f` | ⬜ |
| P3-1 | 瀏覽器 QA 工具 | MCP + Playwright | ⬜ |
| P3-2 | Skill 庫（hash 鎖定） | RikkaHub skills-lock | ⬜ |
| P3-3 | 跨會話任務恢復 | P2-1 延伸 | ⬜ |
| P3-4 | 上限再校準 + 磁碟預算 | — | ⬜ |
| P3-5 | Plan Mode | deepseek plan-mode | ⬜ |
