# P0-3（尾款）Legacy 傳輸層工具迴圈移除 — 逐檔案細部執行計畫

> **版本**：v1.0（2026-11-06）
> **上游**：`docs/Cowork剩餘項目實作計畫.md` §2.1（P0-3 尾款，🟡）
> **基準**：`aaf803ee`（feat(multimodal): add native audio/PDF input and modality gating）
> **性質**：strangler 收尾。kernel path 已是預設主路徑；本計畫移除四條內嵌於傳輸層的
> `while (true)` 工具迴圈，讓「一次請求＝一輪」成為傳輸層唯一語意，工具執行與追問組裝
> 只存在於 `AgentOrchestrator` + `agent_loop.dart`。

---

## 執行進度（2026-11-06）

| 步驟 | 狀態 |
|:--|:--|
| Step 0 基線 | ✅ 既有測試綠燈（89 案子集 + 既有回歸） |
| Step 1 Neuralwatt 上 kernel | ✅ `supportsKernelPath` 納入 neuralwatt |
| Step 2 移除 kill-switch | ✅ `agent_loop_v1` 自 `settings_provider` 移除；`chat_actions._executeGeneration` 固定走 orchestrator |
| Step 2.5 遷移其餘 legacy 呼叫端 | ✅ 語音（`chat_turn_service` 改走 `AgentOrchestrator`，新增 `webFetchEnabled` 傳遞）與 AI Team proposer（`_runProposerSilent` 改走 orchestrator）已完成；orchestrator 移至 `lib/core/services/agent/` 以維持分層。**傳輸層已無生產呼叫端傳入 `onToolCall`／`exposeToolCallsOnly`**（只剩測試） |
| Step 3–9 transport 迴圈刪除 | ✅ 2026-11-06 完成：OpenAI 非串流／`[DONE]`／Responses／無-DONE vendor（含巢狀 deepseek-knob）、Claude 多輪、Google 非串流／串流全部刪除；`onToolCall`／`exposeToolCallsOnly` 自 `sendMessageStream` 與三條 transport 簽名移除；legacy-only 測試刪除或改寫為 kernel 驅動 |

> **落地紀錄（2026-11-06）**：完成定義全數達成——`chat_api_service.dart` 只剩 1 個 `while (true)`（L1 retry，1419）、檔案由 10,697 行降至 8,009 行（−2,688）、`onToolCall`／`exposeToolCallsOnly` 零殘留。刪除時修掉三個機械轉換易犯的坑：
> 1. **Claude 的 `max_tokens` 協商與 `pause_turn` 續傳共用同一個迴圈**——攤平時把上界寫成 2 會讓第三次 400 協商直接靜默結束（不回 isDone、不 throw）。已改為 `for (round < 8)` ＋獨立 `pauseTurnRounds`（pause_turn 仍只續傳一次），`maxTokensAttempts` 維持真正的協商上限。
> 2. **OpenAI no-DONE 的 `finishReason == 'tool_calls'` 分支**原本漏帶 `assistantExtras`——GLM/DeepSeek 第二輪因此丟 `reasoning_content`（`session_c_reasoning_models_test` 抓出）。已補齊 reasoning echo。
> 3. **Responses／Claude／Gemini 的 neutral→wire 轉換**需要讀 `assistantExtras`（`responses_output_items`／`claude_thinking_blocks`／`gemini_thought_sigs`）；三處 converter 已補上，並由 `agent_loop_provider_parity_test` 鎖定。
> 4. **Claude provider-native server tools 不再被 kernel 當成 client tool 執行**：新增 `ToolCallInfo.execute`（預設 true）；`web_search`／`web_fetch` 的 server-tool 曝光 chunk 設 `execute: false`，kernel 只把它當 UI 事件、不執行也不附 `role:'tool'`（server 側已執行且 transport 已自行續傳）。此為既有 latent bug，單輪化後由 kernel 唯一路徑暴露，一併修復；`agent_loop_test`＋`send_message_stream_expose_providers_test` 各有回歸。
>
> 驗證：`flutter analyze` 0 errors；`flutter test` 全綠（2,009 案，2 skipped）。

> Step 7–8 的 Claude／Google 迴圈同時承載 `pause_turn`／server-tool 續傳，攤平時必須保留
> 「同一回合內最多再續傳一次」的行為，不可直接改成單次 `return`。
>
> **2026-11-06 嘗試紀錄**：以 brace-matching 腳本批次刪除已失敗並完整 revert
> （`chat_api_service.dart` 回到 HEAD）。原因：(1) OpenAI #1 的 gate 巢狀在
> `if (tcs.isNotEmpty…)` 內，刪到迴圈尾會拆掉 `try` 的收尾；(2) Claude 非串流與串流
gate 共用同一個 `while`，兩段刪除區重疊；(3) Google 串流沒有獨立 expose gate，
> 計畫的 9490 起點落在 `yield` 參數中間。下一輪請改為**一次只處理一個 transport**，
> 先讀出該分支完整的 try/if/while 巢狀再刪，每步以 analyzer + parity 測試驗證。

---

## 0. 前置條件與完成定義

**開工前置（計畫 §2.1 原文要求）**

1. `agent_loop_v1` kill-switch soak 滿一個版本且無回歸。此條件無法由程式碼推導，需版本紀錄佐證；
   本計畫把「移除 kill-switch」排在傳輸層刪除**之前**，以 soak 期間的預設值（`true`）作為唯一路徑。
2. 基線綠燈：`flutter analyze --no-pub` 無新增 error；`flutter test` 全綠；三個 parity 測試
   （`agent_loop_provider_parity_test`、`agent_loop_followup_parity_test`、
   `send_message_stream_expose_providers_test`）通過。

**完成定義**

- `lib/core/services/api/chat_api_service.dart` 內只剩 **1 個** `while (true)`（`sendMessageStream`
  的 L1 retry 迴圈，1469–1718）；四個 transport 的追問迴圈與工具執行分支全部消失。
- `sendMessageStream` / `_sendOpenAIStream` / `_sendClaudeStream` / `_sendGoogleStream` 不再接受
  `onToolCall`、`exposeToolCallsOnly`：傳輸層永遠「一輪一請求、只揭露 tool calls」。
- `chat_actions._executeGeneration` 不再有 kill-switch 分支；`SettingsProvider.agentLoopV1`
  與 prefs key `agent_loop_v1` 移除。
- 所有 provider（含 Neuralwatt）走 kernel path。
- `flutter analyze` 無新增 error／warning；`flutter test` 全綠；手冊 §3.10／§7.2 與計畫 §0.4 更新。

**不變的職責（刪迴圈時必須保留）**

| 職責 | 位置 | 說明 |
|:--|:--|:--|
| SSE 解析、`[DONE]`／`message_stop`／`finish_reason` | 四個 transport | 純解析，不隨迴圈刪除 |
| §3.10 L1 retry／靜默中斷判定 | `sendMessageStream` 1469–1718 | `StreamAttemptFlags` 的 `finishReason`／`hasUsage` 同步點必須逐一保留 |
| P0-4 reasoning echo | `assistantExtras` / `_normalizeReasoningEchoBody` | follow-up 不再由傳輸層組裝，echo 只走 kernel 的 `roundExtras` |
| prompt caching、vendor knobs、`extraBody` | 各 transport body 組裝 | 首輪路徑不動 |
| OAuth 攔截點 | `OAuthHttpClient`（1331 起） | 單一攔截點不動 |

---

## 1. 迴圈與分支盤點（行號為基準 commit）

### 1.1 `sendMessageStream`（1377–1718）：**保留**

- 1469–1718：L1 retry 迴圈（單次 HTTP 請求的重試與靜默中斷偵測）。**不是**工具迴圈。
- 1511／1538／1564：三個 transport 分派點，`exposeToolCallsOnly` 參數在此傳遞；刪除參數後
  三處同步移除。
- 1426：`config.oauthProvider == OAuthProvider.chatgpt` → 強制 `stream = true`（Codex 端點
  只支援 SSE）。**保留**。
- 1747：ChatGPT（Codex）Responses 分支的 OAuth 判斷。**保留**。

### 1.2 `_sendOpenAIStream`（2887–7117）：**移除 3 個迴圈 + 1 個非串流迴圈**

| # | 迴圈 | 行號 | 包住它的分支 | 曝光閘門 | 刪除區間 | 備註 |
|:--|:--|:--|:--|:--|:--|:--|
| 1 | 非串流工具追問 | 3826–4073（248 行） | `if (!stream)` 內 | 3923–3934 | 3935–4072（138 行） | 非串流 JSON 的工具鏈；kernel 走 `<n>` 串流或 expose 單輪，兩者都不需要它 |
| 2 | `[DONE]` 串流追問 | 4257–4741（485 行） | `if (finishReason == 'tool_calls' …)`（4171 gate） | 4171–4183 | 4184–4755（572 行，含 #2 與巢狀 gate 4637） | 主追問迴圈；巢狀 gate 4647–4740 一併消失 |
| 3 | Responses API 工具追問 | （無獨立 `while`，順序式追問） | `hasRespCalls`（4939） | 5017–5026 | 5027–5387（361 行） | Responses 的 `output_item` continuation 由 kernel 重放 |
| 4 | 無 `[DONE]` vendor 追問 | 5793–6278（486 行） | `finishReason != 'tool_calls'` 的 pending-calls 分支（5712 gate） | 5712–5721 | 5722–7090（1,369 行，含 #4、巢狀 6186、以及 deepseek-knob 追問迴圈 6418–6881／gate 6340） | 最大的單一刪除區；刪後該分支只剩「曝光 + flags 同步 + return」 |

**移除順序**：#1 → #2 → #3 → #4。每刪一個就 `dart analyze` + 對應 transport 測試，避免
一次 2,700 行變更無法定位回歸。

**必須同步改寫的判斷式**

- `(onToolCall != null || exposeToolCallsOnly)`（3877、4121、4604、4939、5675、6153、6289）→
  直接以 `toolCalls.isNotEmpty` / `hasRespCalls` 判斷（傳輸層永遠只揭露）。
- `if (exposeToolCallsOnly) {…return;}` → 去掉 `if` 外殼，保留內部的 flags 同步與 `return`。
- `onToolCall!(...)` 執行點（3939、4191、4654、5034、5324、5729、6203、6358）全部刪除。
- `onToolCall` 參數（2899 附近）與 `exposeToolCallsOnly`（2899）自簽名移除。

**清理目標（analyzer 會指出）**：`_preserveToolStructuredMessages` 若只剩 legacy 使用則刪；
`toolAccResp`／`respToolCallsByIndex`／`lastResponseOutputItems` 等僅供追問使用的累積器；
`currentMessages`／`mm2`／`assistantToolCallMsg` 的組裝殘留。

### 1.3 `_sendClaudeStream`（7137–8377）：**移除 1 個迴圈**

| 迴圈 | 行號 | 曝光閘門 | 刪除區間 | 備註 |
|:--|:--|:--|:--|:--|
| 多輪 tool_use 迴圈 | 7473–8376（904 行） | 非串流 gate 7670–7680（刪 7681–7727，47 行）；串流 gate 8298–8343（刪 8344–8375，32 行） | 見左 | 非串流 gate 位於 `if (toolUses.isNotEmpty …)` 內，刪後該 block 只剩「曝光 + `claude_thinking_blocks` + flags + return」；串流 gate 之後的 `toolResultsBlocks` 組裝與 `convo` 追加（8344–8375）刪除，**保留** 8376 的迴圈收尾，再把 `while (true)` 攤平 |

**Claude 專屬注意**

- OAuth 工具名還原：`_claudeResponseToolName`（1373）與 `restoreClaudeOAuthToolName` 在**曝光**
  路徑仍要套用（`ToolCallInfo.name` 必須是邏輯名），此邏輯在 parsing 段，不動。
- 思考塊回顯：`claude_thinking_blocks`（7662–7670、8323–8340）必須留在曝光 chunk 的
  `assistantExtras`；刪追問時不可連帶刪掉。
- `pause_turn`／server-tool 續跑（8262–8285）屬 provider 內部續傳，**不是**工具迴圈；保留
  （它 `continue` 的是同一個 `while`，攤平迴圈時要改成一次性 `return` 前的 finalize，或保留
  一個 `for (var round = 0; round < 2; round++)` 的續傳上限）。

### 1.4 `_sendGoogleStream`（8379–9835）：**移除 2 個迴圈（非串流／串流各一）**

| 路徑 | 迴圈 | 行號 | 曝光閘門 | 刪除區間 |
|:--|:--|:--|:--|:--|
| 非串流 `generateContent` | 8682–8827（146 行） | 8764–8774 | 8775–8826（52 行：`onToolCall!` + functionResponse 追加 + `continue`） |
| 串流 `streamGenerateContent` | 9120–9834（715 行） | 無獨立 gate（以 `!exposeToolCallsOnly` 守衛，9487／9507） | 需逐段改寫：`calls` 收集 → 曝光 chunk → flags → `return`；刪除 9490–9834 的結果回填與 `convo` 追加 |

**Google 專屬注意**

- thought signature：`gemini_thought_sigs` 的 `assistantExtras`（8757–8766、串流對應段）必須保留。
- `_persistGeminiThoughtSigs` 的 meta comment 屬最終內容輸出，不動。
- `google_search`／`url_context` 的 citations 累積（8860–8900）不是工具迴圈，不動。

### 1.5 Neuralwatt

- `_apiKind`（715–721）把 `ProviderKind.neuralwatt` 映射成 `openai`，因此它共用
  `_sendOpenAIStream` 的 legacy 迴圈。
- `AgentOrchestrator.supportsKernelPath`（48–55）目前排除 neuralwatt。**移除迴圈前必須先把它納入**
  （否則 Neuralwatt 會只拿到第一輪 tool calls 而無人執行）。其 wire 與 OpenAI chat-completions
  相同，parity 風險＝OpenAI 分支已驗證的行为；納入後以 `agent_loop_provider_parity_test` 補一組
  neuralwatt case（config 形狀用 `providerType: ProviderKind.neuralwatt`）。

---

## 2. OAuth 分支盤點（§3.19 路徑不可回歸）

| Provider | 觸發點 | 行為 | 本計畫處置 |
|:--|:--|:--|:--|
| ChatGPT Codex | 1426 `oauthProvider == chatgpt` → `stream = true`；1747 Responses 分支 | 端點只吃 SSE；工具走 Responses `output_item` | 首輪路徑不動；Responses 追問由 kernel 的 `output_item` 重放承接（`agent_loop_provider_parity_test` 已驗證） |
| Claude Pro/Max | 1373 `_claudeResponseToolName`；`OAuthHttpClient` 401 續期 | 工具名 `mcp__…` 還原、thinking block echo | 曝光路徑保留工具名還原 + `claude_thinking_blocks`；`OAuthHttpClient` 不動 |
| Grok（device-code） | Responses 塑形（`useResponseApi`） | 工具追問走 `output_item` | 同 ChatGPT，由 kernel 重放 |
| Kimi Code | `forModelProtocol`（Kimi Anthropic/OpenAI 雙協議） | 兩種 transport 都可能 | 兩條 transport 都改單輪；`forModelProtocol` 不動 |
| 一般 API key | `OAuthHttpClient` 之外的 client | — | 不動 |

**驗證重點**：`chat_api_service_oauth_routing_test`（291 行目前注入 `onToolCall`）需改為
expose 模式斷言（只驗證 URL／headers／body，不驗證工具執行）。

---

## 3. 逐檔案變更清單

| 檔案 | 變更 |
|:--|:--|
| `lib/core/services/api/chat_api_service.dart` | 四個 transport 刪除 legacy 追問與工具執行（§1.2–§1.4）；移除 `onToolCall`／`exposeToolCallsOnly` 參數；清理 legacy-only 累積器與 helper |
| `lib/features/home/services/agent_orchestrator.dart` | `sendRoundImpl` 不再傳 `onToolCall`／`exposeToolCallsOnly`；`supportsKernelPath` 改為永遠 true（或刪除，由呼叫端直接走 kernel）；更新檔頭註解（kill-switch 段落移除） |
| `lib/features/home/controllers/chat_actions.dart` | `_executeGeneration`（1317–1360）刪除 kill-switch 三元式，固定使用 `_agentOrchestrator.run`；檔頭 P0-2 註解更新 |
| `lib/core/providers/settings_provider.dart` | 刪 `_agentLoopV1Key`（111）、`_agentLoopV1`／getter／setter（3227–3235）、載入（847）、copy（4021） |
| `lib/core/services/chat/chat_turn_service.dart` | 移除 `onToolCall: request.onToolCall`（414–428）；若 `ChatTurnRequest.onToolCall` 因此無人使用，連同欄位刪除 |
| `lib/features/home/services/translation_service.dart`／`ocr_service.dart` | 確認未傳 `onToolCall`；不需改 |
| `lib/features/home/controllers/chat_actions.dart`（1679 AI Team proposer） | 確認 `onToolCall` 的使用意圖：若為 legacy 工具迴圈，改為 orchestrator 或移除參數 |

**測試（逐檔）**

| 測試 | 處置 |
|:--|:--|
| `test/core/services/api/agent_loop_provider_parity_test.dart` | 刪除 legacy 對照半部，保留 kernel 斷言；新增 neuralwatt case |
| `test/core/services/api/agent_loop_followup_parity_test.dart` | 同上（259–262 的 legacy 呼叫改為 expose 單輪） |
| `test/core/services/api/send_message_stream_expose_providers_test.dart` | 移除 `exposeToolCallsOnly: true` 參數，斷言不變（Claude／Gemini 單輪揭露） |
| `test/core/services/api/native_input_followup_test.dart`／`native_input_followup_providers_test.dart` | 目前以 `onToolCall` 驅動第二輪附件；改以 kernel 驅動（`AgentOrchestrator.run`）或拆成「曝光輪 + 第二輪 body」兩段斷言 |
| `test/chat_api_service_oauth_routing_test.dart` | 移除 `onToolCall`，改驗證 expose 行為 |
| `test/chat_turn_service_test.dart`、`deepseek_claude_compat_test.dart`、`replay_tool_results_api_test.dart`、`claude_prompt_caching_test.dart` | 預期不需改（無工具執行），但屬回歸必跑 |
| `test/agent_loop_test.dart` | kernel 本体，不動 |

---

## 4. 執行順序（每步一個可回復的 commit）

1. **Step 0 — 基線**：`flutter test` 全綠；記錄 `flutter analyze` 的 error 數（0）。
2. **Step 1 — Neuralwatt 上 kernel**：`supportsKernelPath` 納入 neuralwatt + parity test。
3. **Step 2 — 移除 kill-switch**：`chat_actions` 固定 kernel；刪 `settings_provider` 的 key；
   `flutter test test/agent_loop_provider_parity_test.dart test/chat_turn_service_test.dart`。
4. **Step 3 — `_sendOpenAIStream` #1 非串流迴圈**（138 行）：analyze + OpenAI 相關測試。
5. **Step 4 — `_sendOpenAIStream` #2 `[DONE]` 追問**（572 行）：analyze + parity + deepseek compat。
6. **Step 5 — `_sendOpenAIStream` #3 Responses**（361 行）：analyze + Responses/OAuth 測試。
7. **Step 6 — `_sendOpenAIStream` #4 無 DONE vendor**（1,369 行）：analyze + 全 OpenAI 測試。
8. **Step 7 — `_sendClaudeStream`**（904 行迴圈攤平）：Claude prompt-caching／OAuth 測試。
9. **Step 8 — `_sendGoogleStream`**（146 + 715 行）：Gemini 測試。
10. **Step 9 — 參數清除**：`onToolCall`／`exposeToolCallsOnly` 自四個簽名移除；六個呼叫點更新；
    legacy-only 測試刪除或改寫。
11. **Step 10 — 收尾**：手冊 §3.10（L1 職責界線）、§7.2（roadmap）、計畫 §0.4 更新；
    `STORE_REVIEW_PLAN.md` 不需動（無新能力）。

**每步驗證指令**

```bash
flutter analyze --no-pub            # 0 errors；本案新增檔案不得新增 warning
flutter test <受影響測試>            # 先跑局部
flutter test                        # 每一步收尾跑全量（700+ 案）
```

---

## 5. 風險與回退

| 風險 | 影響 | 緩解 |
|:--|:--|:--|
| Reasoning echo 遺失 | DeepSeek／Kimi／OpenRouter 多輪降智或 400 | echo 已由 kernel `assistantExtras` 承接；每步跑 `deepseek_claude_compat_test`、`agent_loop_followup_parity_test` |
| OAuth Codex Responses 續傳差異 | ChatGPT 訂閱路徑工具第二輪失敗 | Step 5 前先跑 `chat_api_service_oauth_routing_test` + parity；保留 `useResponseApi` 分支 |
| Claude thinking block 丟失 | Anthropic 400（tool continuation 缺 thinking） | 曝光 chunk 的 `claude_thinking_blocks` 不可刪；以 `send_message_stream_expose_providers_test` 鎖定 |
| Gemini thought signature 丟失 | Gemini 3 工具第二輪 400 | `gemini_thought_sigs` 保留；以 parity 測試鎖定 |
| 大量刪除造成不可定位回歸 | 難以 bisect | 一步一 commit、一步一測試（§4） |
| 非串流路徑被誤刪 | OCR／翻譯等聚合呼叫失效 | 這些呼叫不帶 tools，走「無 tool calls → final content」分支；Step 3 後跑 `ocr`／translation 相關測試 |
| Neuralwatt 行為未實測 | 該 provider 工具鏈失效 | Step 1 先納入 kernel 並補 parity；無法實測時在 release note 標註 |

**回退**：每一步為獨立 commit；`chat_api_service.dart` 的刪除以區間為單位，`git revert` 單一
commit 即可恢復該 transport，不影響其他步。

---

## 6. 與其他計畫項目的界面

- **P1-6（`shell_run`）**：shell 工具只經 kernel 執行；本項完成後 `ToolHandlerService` 不需再
  應付「傳輸層自行執行」的第二條路徑，審批分類只有一處。
- **P2-1（checkpoint）**：durable-before-dispatch 的邊界在 kernel／driver；傳輸層單輪化後
  「一輪 = 一請求」成為契約，checkpoint 的 step 邊界即 kernel 的 `onRoundStart`。
- **P2-3（子代理）**：子代理沿用同一 kernel，不再需要 legacy 相容。
