# OmniChat 上游 kelivo v1.3.2 ~ v1.3.4 導入評估與計畫

> **版本**：v1.0（初版評估）  
> **日期**：2026-11-05  
> **狀態**：評估完成，待核定後依 Phase 順序實作  
> **範圍**：評估上游 [Chevey339/kelivo](https://github.com/Chevey339/kelivo) v1.3.2 ~ v1.3.4（含 v1.2.5 同線早期項目）與 OmniChat v1.27.0 的功能差距，並為需要導入的項目提出 OmniChat 原生實作計畫  
> **非範圍**：上游 v1.3.3 的大型新功能（桌面 side panel、獨立 workspace web apps、IntelligentUI、Argon2id 備份加密等）；v1.3.4 的訊息儲存 AOT 修復（OmniChat 已有自己的 SQLite 儲存底座，見 §3.18／§6）  
> **相關文件**：`OmniChat 專案開發與維護手冊.md` §3.5 / §3.11 / §3.19 / §5.3 / §7.4；`docs/speech_recognition_import_plan.md`（格式範本）

---

## 0. 摘要（TL;DR）

### 0.1 結論

**建議「部分導入」**：使用者列出的 8 大項中（第 3 項拆為 3a/3b），Gemini 3.x thinkingLevel、DeepSeek 推理回顯、Codex 模型清單刷新 3 個子項 OmniChat 已獨立實作（不需導入）；Gemini 4 與 thought-signature 供應商隔離 2 項存在**會直接 400 的正確性缺陷**（P1，優先導入）；其餘為值得吸收的修復與 UX 改良（P2/P3）。逐項判定如下（行號以 v1.27.0 基線為準）：

| # | 上游項目（來源版本 / commit） | 判斷 | 優先級 | 主要理由 |
|:--:|:---|:--:|:--:|:---|
| 1 | Gemini 4 支援：thinkingLevel + thought-signature replay（v1.3.2 `3b4cb633`）；Gemini 3.x 全走 thinkingLevel（v1.2.5 `717dc0d6`） | **部分導入** | **P1** | 3.x→thinkingLevel 已實作；**gemini-4 會落入 `thinkingBudget` 分支（HTTP 400）**，且簽章保存閘寫死 `gemini-3`（§2.1） |
| 2 | Thought signature 留在產生它的供應商；工具呼叫途中切換供應商/模型開新回覆（v1.3.3 `03f6e9f` / PR #1320） | **導入** | **P1** | OmniChat 簽章存於訊息文字註解、重放時不辨識 `providerId`，跨 Gemini 系供應商（官方 ↔ Vertex ↔ 聚合商）切換會重播他人簽章 → `Corrupted thought signature` 400（§2.2） |
| 3a | 修正 Claude adaptive thinking 模式與模型預設值（v1.3.2 `5181bd6`） | **部分導入** | P2 | OmniChat 已有 adaptive+effort；缺 `between_tools` off 方言、快照日期版號守衛、opus-5.5 always-on（§2.3） |
| 3b | 合成引用卡片不寫入歷史（v1.3.2 `3945725`） | **導入（小修）** | P2 | OmniChat 的 `builtin_search` 顯示用工具事件**未被重放排除**，會以 client `tool_use` 名義回送（§2.4） |
| 4 | Responses API 工具歷史維持順序、保留工具圖片、重放前合併推理片段（v1.3.2 `9fa4bd8`/`a9b9ba9`/`bbeacf9`） | **部分導入** | P2 | kernel 路徑已原序重放；工具圖片不適用；**reasoning_details 有「覆寫式累加＋雙寫」缺陷**（§2.5） |
| 5 | DeepSeek 推理內容工具續接回顯（v1.2.5 `0f44150`） | 不需導入 | — | OmniChat 已更完整實作（輸入＋輸出雙側、非空 sentinel、§5.3 契約）（§2.6） |
| 6 | App 版本變更後刷新 Codex 模型清單（v1.3.2 `290837e`）；GPT-5 推理預設修正；OpenRouter Auto 可啟用推理（`a5900dac`/`776b339`） | **部分導入** | P3 | Codex 刷新已實作；GPT-5 基礎型 regex 落空（靠目錄補）、OpenRouter `openrouter/auto` 能力判定落空（§2.7） |
| 7 | 編輯供應商顯示實際請求 URL、自動補 API 版本、連線測試失敗說明原因（v1.3.3 `8be28e1`） | **導入** | P2 | OmniChat 三者皆無；純 UX/診斷改良、無協議風險（§2.8） |
| 8 | OAuth 已啟用模型跨同步/登入記憶（v1.3.3 `63c00ec`）；額度用量對齊 Codex/Claude/Kimi/Grok；登入失敗指出哪一步（`2c9027c`/`7cf72d8`） | **部分導入** | P2/P3 | 用量摘要視窗已於 2026-11-03 落地；缺「使用者已刪除/停用模型會被同步復活」、Codex `spend_control`、Grok on-demand/advisory、失敗階段標籤（§2.9） |

### 0.2 最重要的一件事

上游內建目錄與 OmniChat 的 `assets/model_catalog/models_dev.json` **都已收錄 `gemini-4-argon`**，但 OmniChat 的 wire 層還不認得它：

- `lib/core/services/api/reasoning_wire.dart` 的 `autoGeminiThinkingConfig`（L617 起）只比對 `gemini-3.*-pro|flash|lite`；`gemini-4-*` 落到「Gemini 2.x 以下」分支送 **`thinkingBudget`** — 上游 commit `3b4cb633` 的動機記錄明言 Gemini 4 對此回 **HTTP 400**。
- `lib/core/services/api/chat_api_service.dart:8026-8028`：`_persistGeminiThoughtSigs = modelId.contains('gemini-3')` — **gemini-4 的 thought signature 不會被保存**，跨輪重放只能靠 `_ensureGeminiFunctionCallThoughtSig` 的固定佔位值。

另一個同級缺陷：Gemini 簽章以 `<!-- gemini_thought_signatures:... -->` 註解存在訊息文字內，Google 傳輸重建歷史（`chat_api_service.dart` L8533/L8634）時**不分來源供應商**全部取用 — 上游 PR #1320 實測這在「Vertex ↔ Gemini 開發者 API」互切時回 `400 Corrupted thought signature`。OmniChat 的訊息模型已有 `providerId`（`chat_message.dart` HiveField 5）、SQLite 已預定義 `provider_artifacts.kind = 'gemini_thought_signature'`（`message_part_codec.dart:7`），導入成本比上游更低。

### 0.3 建議順序

```text
Phase 0（P1 正確性，先行）
  ├─ G1 Gemini 4：thinkingLevel 化 + 簽章保存閘改 generation 判定
  └─ G2 簽章按供應商隔離（providerId 比對；legacy 註解相容讀取）
        ↓
Phase 1（P2 修復 + UX）
  ├─ C1 Claude adaptive 修正（between_tools / 版本解析 / always-on）
  ├─ R1 reasoning_details 合併 + 單一表示回顯（OpenRouter 工具迴圈）
  ├─ R2 builtin_search 顯示事件排除於重放
  ├─ U1 供應商編輯：請求 URL 預覽 / API 版本自動補齊 / 測試失敗說明
  └─ O1 OAuth 帳號 disabledModels（已刪除/停用模型不被同步復活）
        ↓
Phase 2（P3 補強，可與發佈週期併行）
  ├─ M1 GPT-5 基礎型推理檔位 + Off→minimal
  ├─ M2 openrouter/auto 能力判定
  ├─ O2 OAuth 用量對齊（Codex spend_control / Grok on-demand+advisory / Kimi usages）
  ├─ O3 OAuth 登入失敗階段標籤（stage + transport 分類）
  └─ R3（可選）legacy neutral 訊息的 Responses 順序微調
```

### 0.4 工作量

| 階段 | 內容 | 估計 |
|:--|:--|:--:|
| Phase 0 | G1 + G2（含 artifacts 遷移與測試；僅行為修復約 2–3 人日） | 3–4 人日 |
| Phase 1 | C1 + R1 + R2 + U1 + O1 | 5–7 人日 |
| Phase 2 | M1 + M2 + O2 + O3 + R3 | 3–4 人日 |
| **合計** | | **11–15 人日** |

---

## 1. 上游變更盤點

### 1.1 v1.3.2（`b1702b3`，2026-10-26）— 本計畫主體

| 項目 | commit | 內容 |
|:--|:--|:--|
| Gemini 4 支援 | `3b4cb633` | model-spec 認得 `gemini-4[.N]-*`：dialect `geminiThinkingLevel`、levels `low/medium/high`、`canDisable:false`、預設 medium（`cyber-permissive` 變體 high）、sampling 永遠剝除、maxOutput 65536、`replay: all`；上游 tool config 混用內建工具的閘由 `contains('gemini-3')` 改為 generation ≥ 3 |
| Gemini 工具回合重放 | PR #1270（`ab792d0c`/`163ae977`/`870b6376`） | 平行 function call 批次以**單一簽署 model turn** 重放（簽章只在批次第一顆 call）；每個回合有明確邊界、文字/思考逐輪保留；code-execution ID 去重 |
| Claude adaptive 修正 | `5181bd6` | 版本解析正規化（八位快照日期 `claude-opus-4-20250514` 不得當 minor）；新增 `anthropicBetweenTools` 方言（Sonnet 5.5 的 Off = `thinking:{type:'between_tools'}`）；opus ≥ 5.5 always-on；adaptive-only 模型（4.7+）sampling `never`；max output 預設表（5.x/4.6+ → 128000） |
| 合成引用卡不進歷史 | `3945725` | Claude server-side hosted tools（`server_tool_use`/`web_search_tool_result`/`citations_delta`）的**僅顯示**卡片（合成 id `:search-…`）不再被重建為 `tool_use` block；帶 `metadata:{server:true}` 標記 + id 合法性 regex 過濾；跨供應商切換時其他家的卡仍保留 |
| Responses 順序 | `9fa4bd8` | legacy 訊息重建 Responses input 時，assistant 文字 item 以 `assistantMessageIndex` 插入到自己的 `function_call` 之前，文字不得把 call 與 output 隔開 |
| Responses 工具圖片 | `a9b9ba9`（+`13f1ef7`/`eeb47f9`） | `role:'tool'` 訊息複製時保留 `metadata`（圖片型別資訊），讓後續 follow-up/重放能重建 `input_image`；最終送線上前才剝除 |
| 推理片段合併 | `bbeacf9` | 新增 `mergeReasoningDetails()`：delta 片段依（type/textKey/id/index/format 相同且未被簽章打斷）合併成完整 block；opaque/encrypted 條目為邊界；重放時結構化 details 與純量 `reasoning_content` **二選一**，避免重複思考內容 |
| Codex 模型清單刷新 | `290837e` | `syncOutdatedModels()` 於啟動時比對 `oauthModelsClientVersion` 與 `codexClientVersion`（0.153.0→0.159.0），失敗保留舊清單、下次重試 |
| GPT-5 預設 / OpenRouter Auto | `a5900dac` / `776b339` | `gpt-5|gpt-5-mini|gpt-5-nano` 檔位 `['none',…] → ['minimal','low','medium','high']`（Off 送 `minimal`）；OpenRouter `reasoning` 在 auto 檔 `putIfAbsent('enabled', true)` |

### 1.2 v1.3.3（`12af1d1`，2026-11-02）— 本計畫主體

| 項目 | commit | 內容 |
|:--|:--|:--|
| 簽章按供應商隔離 | `03f6e9f`（PR #1320） | `buildApiMessages(googleProviderId:)`；assistant 訊息的 `providerId` ≠ 目標 Google 供應商時：清掉文字內註解簽章 + 剝除 metadata 簽章（**不動持久化資料**）；相同供應商才附 artifact 簽章 → 工具回合中途切換＝以未簽章狀態開新回覆 |
| 供應商 URL UI | `8be28e1` | 新 `provider_url.dart`（`normalizeBaseUrl`/`providerUrlVersion`（google=`/v1beta`、其餘 `/v1`）/`resolveRequestUrl`）；base URL 欄下方即時請求 URL 預覽；路徑為空時自動補版號（snackbar + Undo + `autoVersionDisabled` 持久化）；`testConnection` 帶 `onRequestUrl`，`ProviderTestFailure` 解析 `HTTP <code> <reason>` 給出摘要＋全文 |
| OAuth 啟用模型記憶 | `63c00ec` | `ProviderConfig.disabledModels`（Set）；同步/重新登入經 `copyWith` 保留；模型暫時從目錄消失也保留停用標記；停用清選擇但保留 pin/reasoning/override；模型列加 per-model 開關 |
| OAuth 用量對齊 | `2c9027c` | Codex 解析 `spend_control.individual_limit`（`spend-cap` 視窗，新增 `remaining`/`advisory` 欄位；credit 席位只依明確 `reached` 判定）；Claude 輸出上限改由 model spec 帶入（chat 與 connection test 同源）；Kimi 解析 `usages` 月視窗；Grok 週/月並存 + on-demand 視窗 + `advisory` 標記 |
| 登入失敗階段 | `7cf72d8` | `ProviderOAuthStage`（requestDeviceCode…refreshToken）+ `ProviderOAuthTransportFailure`（dns/tls/proxy/timeout…）；只有分類跨過 OAuth 邊界（訊息/URL/header 永不複製）；UI 三行式：在地化階段標籤／傳輸摘要＋(HTTP nnn)／脫敏伺服器訊息 |

### 1.3 v1.2.5（`6263eb7`，2026-08-31）— 同線早期項目

| 項目 | commit | OmniChat 現況 |
|:--|:--|:--|
| Gemini 3.x 全走 thinkingLevel | `717dc0d6` | **已實作**（手冊 §3.5.1；`reasoning_wire.dart` `autoGeminiThinkingConfig`） |
| 簽章改存 provider artifact | `27982ac7` | **未跟進**（仍存訊息文字註解）；SQLite 已預定義 `kGeminiThoughtSignatureKind` |
| DeepSeek 工具續接回顯 | `0f44150` | **已超越實作**（手冊 §5.3） |

### 1.4 v1.3.4（`4a7da9b`，2026-11-02）

訊息儲存 AOT 崩潰修復、Android 全選選單、iOS Live Activities、STT 設定提示色。OmniChat 的對應面：儲存層已由自家 SQLite 底座取代（§3.18；且手冊所述 status-based 重放已接上）；STT 為自家樞紐。**本輪無需導入**（見 §6）。

---

## 2. 逐項評估

### 2.1 G1：Gemini 4 支援（P1，導入）

**OmniChat 現況**

- 能力層 OK：`lib/core/utils/reasoning_capabilities.dart:148-158` `_googleCapabilities` 以 `gemini-(\d+)` 解析 major ≥ 3 → thinkingLevel 撥盤（gemini-4 自然命中，顯示 Xhigh 檔）。
- **wire 層缺口**：`reasoning_wire.dart` `autoGeminiThinkingConfig`（L617 起）只認 `gemini-3.*-pro|flash|lite`；gemini-4 落入「Gemini 2.x 以下」分支 → 送 `thinkingBudget` → Gemini 4 回 HTTP 400（上游 `3b4cb633` 動機原文）。`gemini.level` 顯式方言的 isPro 判定（L594）同樣只認 `gemini-3.*-pro`。
- **簽章保存缺口**：`chat_api_service.dart:8026-8028` `_persistGeminiThoughtSigs = contains('gemini-3')` → gemini-4 回合的簽章不落盤；重放只能靠 `_ensureGeminiFunctionCallThoughtSig`（L600-617，只補**第一顆** functionCall part）的固定佔位值。
- 目錄已覆蓋：`assets/model_catalog/models_dev.json` 內含 `gemini-4-argon`、`gemini-4-argon-contributor`（能力/視窗/價格由目錄供應）。

**導入方案（OmniChat 原生）**

1. `reasoning_wire.dart`：把 `autoGeminiThinkingConfig` 與 `gemini.level` writer 的家族判定改為 **generation 解析**（`RegExp(r'gemini-(\d+)')` major ≥ 3 即 thinkingLevel 家族；禁止對 major ≥ 3 送 `thinkingBudget`）；gemini-4 預設對齊上游（levels low/medium/high、不可關閉 → Off 映射最低檔；`gemini-4.*cyber-permissive` 預設 high）。
2. `chat_api_service.dart`：`_persistGeminiThoughtSigs` 改為同一 generation 判定（major ≥ 3），gemini-4 回合的簽章照 gemini-3 管道持久化（註解 tag 或 §2.2 的 artifacts）。
3. 簽章重放沿用現行 `_applyGeminiThoughtSignatures` + `_ensureGeminiFunctionCallThoughtSig` 兜底（批次第一顆補佔位）。gemini-4 的 `replay: all` 是否要求同一 model turn 的所有 part 皆帶簽章，需以 wire 測試確認；若只補第一顆不足，擴充為逐 part 補佔位。
4. 目錄刷新：`ModelCatalogService.refreshForModel` 已會在新增 gemini-4 模型時拉新目錄，無需額外工作。

**測試**：`test/core/reasoning_wire_test.dart` 補 gemini-4 案例（`thinkingConfig:{includeThoughts,thinkingLevel:'HIGH'}`、無 `thinkingBudget` 鍵、off→最低檔）；`_persistGeminiThoughtSigs` 行為單測。

### 2.2 G2：Thought signature 按供應商隔離（P1，導入）

**上游修了什麼**（`03f6e9f` / PR #1320）：每則 assistant 訊息帶 `providerId`；送請求時只有「訊息的產生者 == 目標 Google 供應商」才附簽章（artifact 或 metadata），否則清文字註解、剝 metadata 簽章，**持久化資料不動**（切回原供應商時簽章還在）。工具回合中途切換供應商/模型 → 以未簽章狀態重建請求（＝開新回覆），不再 `400 Corrupted thought signature`。

**OmniChat 現況**

- 簽章存於訊息文字 `<!-- gemini_thought_signatures:... -->`（`chat_api_service.dart:829-833` regex；stream 端 L8117/8214 寫入、Google 歷史重建 L8533/8634 讀取）。
- 訊息模型已有 `providerId`（`lib/core/models/chat_message.dart` HiveField 5），但重放管線**未使用**它過濾簽章。
- SQLite 已預定義 `provider_artifacts.kind = 'gemini_thought_signature'`（`message_part_codec.dart:7`）但 runtime 尚未使用 — 這是比上游更乾淨的落地點（不再污染訊息文字、任何傳輸都不用再剝註解）。

**導入方案**

1. **行為修復（必做）**：`lib/features/home/services/message_builder_service.dart` / `chat_turn_service.dart` 組裝 neutral 訊息時，把「目標 Google 供應商 key」傳入（比照上游 `googleProviderId`）；`chat_api_service.dart` Google 歷史重建（L8533/8634）僅在 `msg.providerId == 當前 Google provider key`（或 `providerId == null` 的 legacy 訊息）時 `_extractGeminiThoughtMeta` 取簽章，否則使用 cleaned text、functionCall part 不附簽章（交由 `_ensureGeminiFunctionCallThoughtSig` 佔位兜底）。
2. **儲存升級（建議同 phase）**：新訊息的簽章改寫入 `provider_artifacts`（kind `gemini_thought_signature`、payload 為 bare JSON），讀取時「artifact 優先、legacy 註解 fallback（讀後原樣保留）」；訊息文字不再新增註解。刪除/分叉訊息時 artifacts 隨訊息生命週期（M 系列已有契約）。
3. 模型中途切換：OmniChat 現行工具迴圈以 `ChatTurnService` 建構時固定的 `modelId` 跑完（`chat_turn_service.dart:22/34`，請求沿用同一 id），單回合內無切換入口，行為已等價上游「開新回覆」；跨回合切換由第 1 點覆蓋。**注意**：provider scope 不能只用 provider key — 同一 provider 改 baseUrl（AI Studio ↔ Vertex）key 不變，仍會重放他人簽章；應以 `providerId + 解析後 origin` 為鍵（與 U1 的 `resolveRequestUrl` 共用邏輯）。

**測試**：新增 provider 切換協議測試（模擬 Vertex → 官方互切，斷言請求體不含他人簽章、含本家簽章；持久化訊息未被改動）；legacy 註解相容讀取測試。

### 2.3 C1：Claude adaptive thinking 修正（P2，部分導入）

**OmniChat 現況**

- 已有：adaptive on = `{'type':'adaptive','display':'summarized'}` + `output_config.effort`（`chat_api_service.dart:2458`、`reasoning_wire.dart` claudeAdaptive 分支 L528 起）；能力表（`reasoning_capabilities.dart:250-287`）覆蓋 `claude-(opus|sonnet)-5`、opus-4.7/4.8、4.6。
- 缺口：(a) **off → `{'type':'disabled'}`**（`reasoning_wire.dart` `resolveClaudeReasoningWire` 的 claudeBudget/claudeAdaptive 分支：off 都送 disabled）— 上游證實 Sonnet 5.5 不能全關，需 `between_tools`；(b) 版本解析弱：`claude-(?:opus|sonnet)-5(?:$|[._:@/-])` 不認 haiku-5、`claude-5-5-*` 反序；且無「八位快照日期非 minor」守衛（上游正是此 bug 的修復點）；(c) 無 opus-5.5 always-on / adaptive-only sampling `never` 語義。

**導入方案**

1. `reasoning_wire.dart` 新增 claude off 方言：`claudeAdaptiveBetweenTools`（off → `{'type':'between_tools'}`；on 同 adaptive+effort）；能力來源 `supportsAdaptiveThinking` + 模型 id 判定決定 off 行為。
2. `reasoning_capabilities.dart` `_claudeCapabilities` 重寫：單一 `(family, major, minor)` 解析（容忍 `claude-opus-4-20250514` 快照尾、`claude-5-5-haiku` 反序）；`claude-4.{6,7,8}`、`claude-5.x`、`fable/mythos` 規則對齊上游表；opus ≥ 5.5 → `thinkingAlwaysOn`；adaptive-only（4.7+/5.x）→ 供採樣剝離判定。
3. 目錄覆蓋不變（user override > reasoningSynced > 目錄 > regex）。

**測試**：`test/reasoning_capabilities_test.dart` 補快照日期/反序/haiku-5 案例；wire 測試斷言 sonnet-5.5 off → `between_tools`、opus-5.5 off → adaptive+`effort:low`。

### 2.4 R2：引用/伺服器工具顯示事件不進歷史（P2，小修）

**上游修了什麼**（`3945725`）：僅顯示的 hosted-search 卡片被重建為 `tool_use` block → 無效 id / 重複的 server 呼叫破壞請求。

**OmniChat 現況**：Claude/Gemini/OpenRouter/Grok 的內建搜尋在 OmniChat 以 **`builtin_search` 工具事件**持久化（`chat_api_service.dart` L4220/4682/5683/7563/9166/9276），UI 隱藏卡片、只顯示來源卡；但 `tool_replay.dart:12-15` 的 `kNonReplayableToolNames` **只有** `todoToolName`（即 `write_todos`）與 `workspace_snapshot` — `builtin_search` 會被 `buildToolReplayPairs` 重放為 client `tool_calls` + `role:'tool'`，各傳輸再轉為 `tool_use`/`functionCall`/`function_call`。server-side 呼叫不應以 client 名義回送（對 Claude 官方尤其危險：`web_search_20250305` 是 server tool，歷史中出現不存在的 client `tool_use`）。

**導入方案**：`kNonReplayableToolNames` 加入 `builtin_search`（一行修）。注意 `search_web`（OmniChat 自家 client 工具）**必須保留**重放。若未來要把 server 卡片帶去別家供應商，再考慮上游的 `metadata.server` 標記方案。

**測試**：重放測試斷言 builtin_search 不產生 pair、search_web 正常。

### 2.5 R1：reasoning_details 合併與單一表示回顯（P2，部分導入）

**上游修了什麼**（`bbeacf9`）：delta 式 `reasoning_details` 每片段一條 → 重放時上游 Claude（Bedrock）收到整排碎片 block（簽章-only block 的 text 為 null → 400）；且結構化 details 與純量 `reasoning_content` 同時回送會重複思考內容。

**OmniChat 現況**

- OpenRouter 推理模型已跨工具輪保留 `reasoning_details`（`chat_api_service.dart:2836` 起 `preserveReasoningDetails`），但累加是**覆寫式**：`reasoningDetailsAccum = rd`（L4274/4277，每個 delta 直接取代）— snapshot 型供應商正確，fragment 型供應商只剩最後一片。
- 回顯雙寫：`lib/features/home/services/message_builder_service.dart:241-265`、`chat_turn_service.dart:213-236`、`stream_controller.dart:744-746` 同時附 `reasoning_content` 與 `reasoning_details`。

**導入方案**

1. 新增純 Dart `mergeReasoningDetails()`（比照上游規則：type/textKey/id/index/format 全同且未被簽章/opaque 條目打斷才合併；文字精確串接；orphan 簽章保留於持久化、回放前過濾），於串流 emit 點與重放 echo 前套用。
2. echo 收斂為單一表示：OpenRouter host（或 `catalogInterleaved == 'reasoning_details'`）有結構化 details 時移除平行 `reasoning_content`；純量端點（native DeepSeek 等）unsigned 片段摺疊進 `reasoning_content`。
3. 覆寫式累加改為「merge 後取代」，snapshot 供應商行為不變。

**測試**：新增 round-trip 測試（兩輪工具 + 持久化 + 重放；OpenRouter ↔ native DeepSeek 切換；orphan 簽章守衛），比照上游 `reasoning_details_round_trip_test.dart` 精神。

### 2.6 DeepSeek 推理回顯（不需導入）

OmniChat 於 2026-09-12 起**超越上游**地實作：範圍是「每一條 assistant 訊息」（非僅 tool_calls）、輸出側寫入＋輸入側回填雙保險、非空 sentinel `'(no reasoning content)'`、5-Hook 全掛接（手冊 §5.3 契約 + `test/deepseek_claude_compat_test.dart` 等）。上游 `0f44150` 的「tool 輪也強制 echo」已被 OmniChat 的全量 echo 覆蓋。

### 2.7 Codex 刷新 / GPT-5 預設 / OpenRouter Auto（P3，部分導入）

- **Codex 模型清單刷新：不需導入**。OmniChat 已有同構實作：`main.dart:187` 啟動呼叫 `syncOutdatedModels`；`provider_oauth_service.dart:628-655` 以 `credentials.modelsClientVersion` 比對 `ProviderOAuthConstants.codexClientVersion`、3 秒上限、失敗不動版本。維運提醒：上游已把 codex client version 升到 0.159.0（後端對舊版隱藏新模型），OmniChat 跟隨上游節奏更新常數即可。
- **GPT-5 預設（M1，小修）**：`reasoning_capabilities.dart` `_openAiCapabilities` 只解析 `gpt-5.(\d+)`；`gpt-5`/`gpt-5-mini`/`gpt-5-nano` 落 `unsupported`（目錄有這些 id，能力靠目錄補，但 regex miss 時 `openAiOffFallback` 必為 null → Off 只能省略參數）。補一條 base-family 分支：efforts `{minimal, low, medium, high}`、`openAiOffFallback: 'minimal'`（對齊上游 `a5900dac`：Off 送最低文件檔位，不送 none）。
- **OpenRouter Auto（M2，小修）**：`openrouter/auto` 模型 id 不命中任何能力 regex → 推理撥盤不可用；而 OmniChat 的 auto 鏈（`reasoning_wire.dart:222-240`）在使用者開啟撥盤時已會送 `reasoning:{enabled:true}`。補：`openrouter/auto` 給予能力條目（efforts 空、可停用），讓撥盤出現；保持「非破壞性」（使用者 custom body 仍最後合併）。

### 2.8 U1：供應商編輯 URL 預覽 / API 版本補齊 / 測試失敗說明（P2，導入）

**OmniChat 現況**：`provider_detail_page.dart` 只有 base URL / chatPath 輸入（hint 顯示預設值）；連線測試 `_openTestDialog`（L1775；`_ConnectionTestDialog` 於 L1779）與批次偵測把 `e.toString()` 直接展示（L1717-1731）；Google 傳輸的版本段內嵌於 baseUrl（`chat_api_service.dart:8047/8049` 非串流、`8457/8462` 串流，直接拼 `$base/models/...`），無任何「實際會打到哪裡」的預覽。

**導入方案（OmniChat 原生，對齊上游 `8be28e1`）**

1. 新 `lib/core/utils/provider_url.dart`：`providerUrlVersion(kind)`（google → `/v1beta`，其餘 `/v1`）、`resolveRequestUrl(config, modelId, {useResponses, isStream})` — 集中 openai（chatPath / responses）、claude（`/messages`）、google（`/models/$id:generateContent|:streamGenerateContent`、Vertex regional origin）的 URL 組裝；`chat_api_service` 各處改呼叫（行為 byte-identical，由測試釘住）。
2. `provider_detail_page.dart` base URL 欄下新增請求 URL 預覽列（resolved URL，與輸入差異段以 primary 色強調 + 說明文字）。
3. 版本自動補齊：commit 時路徑為空 → 自動補 `/v1`|`/v1beta`，snackbar + Undo；`ProviderConfig.autoVersionDisabled`（可選 bool）記住不再自動補。
4. 測試失敗說明：`ProviderManager.testConnection`（`model_provider.dart:746`）錯誤訊息帶 status + reason phrase；新 `ProviderTestFailure` 解析器輸出「狀態碼＋原因短句 / 全文 / 請求 URL」，`_ConnectionTestDialog` 與批次偵測改用。

**測試**：`provider_url` 純函式測試；URL 表單測試（貼上含 `/chat/completions` 尾巴、缺版號、尾斜線）；`ProviderTestFailure` 解析測試。

### 2.9 O1/O2/O3：OAuth 三項（P2 + P3，部分導入）

- **O1 啟用模型記憶（P2）**：OmniChat `mergeSyncedModels`（`provider_oauth_service.dart:450-533`）對 provider 回傳的每個 model `if (!models.contains) models.add(...)` — **使用者刪除過的 oauth-synced 模型會在每次同步/登入時復活**（`syncOutdatedModels` 每次啟動都跑）；且帳號層只有單一 `ProviderConfig.enabled`（手冊 §3.19），無 per-model 開關。導入上游 `63c00ec` 的 `disabledModels`（Set<String>，隨 `provider_configs_v1` 備份、不進分享/QR）：`mergeSyncedModels` 保留之、模型暫時從目錄消失也保留標記；帳號詳情頁模型列加 per-model 開關；模型選擇器/`hasAnyActiveModel`/排程執行器過濾 `enabledModels`；停用時清當前選擇但保留 pin/reasoning/override（沿用 `clearSelectionsForModel` 語義）。
- **O2 用量對齊（P3，需實機）**：OmniChat 已有四家 usage 解析＋視窗優先序（2026-11-03，手冊 §3.19）。補上游 `2c9027c` 的差集：Codex `spend_control.individual_limit`（新視窗型別 + `remaining`/`advisory` 欄位；credit 席位只依明確 `reached`）、Grok 週/月並存 + on-demand + `advisory`（推算百分比不當帳號封鎖）、Kimi `usages` 月視窗、Codex residency `no_constraint` 不送 header。**注意**：全部需要真實訂閱帳號驗證（手冊 §3.19 已列實機驗收為未完成項）。
- **O3 登入失敗階段（P3）**：OmniChat `oauth_errors.dart` 有例外分類（cancel/timeout/rejected/browser/required/disabled/superseded/client-version/transport）＋登入流程 UI 有步驟狀態，但失敗時**沒有**結構化「哪一步 + 傳輸分類」。導入上游 `7cf72d8` 的 stage enum（requestDeviceCode/waitDeviceAuthorization/prepareBrowser/browserAuthorization/exchangeToken/refreshToken）+ transport 分類（dns/tls/proxy/timeout…，僅分類跨邊界、原文永不複製），`oauth_login_flow.dart` 錯誤文字改三行式（在地化階段標籤／摘要＋(HTTP nnn)／脫敏訊息）。l10n ×4。

### 2.10 R3：Responses 順序微調（P3，可選）

OmniChat kernel 路徑已以 `responses_output_items` 原樣重放（順序完美）；legacy neutral 路徑的 assistant 文字 item 排在其 function_call 批次之後（chronology 顛倒但 Responses API 寬容，且 OmniChat 把 tool_calls 與文字拆成兩則訊息，不存在上游「同訊息內交錯」的 bug）。**可選**：在 legacy 路徑比照 `assistantMessageIndex` 把空文字 tool_calls 訊息的文字 item 插到 calls 前；收益低，列為觀察項。

---

## 3. 導入設計總覽

| Phase | 項目 | 主要檔案 | 資料/相容性 |
|:--|:--|:--|:--|
| 0 | G1 | `reasoning_wire.dart`、`chat_api_service.dart` | 無 schema 變更 |
| 0 | G2 | `chat_api_service.dart`、`message_builder_service.dart`、`chat_turn_service.dart`、（建議）`chat_repository.dart`/`message_part_codec.dart` | 新寫入走 provider_artifacts；legacy 註解只讀不刪 |
| 1 | C1 | `reasoning_wire.dart`、`reasoning_capabilities.dart` | 無 schema 變更 |
| 1 | R1 | `chat_api_service.dart`、`message_builder_service.dart`、`chat_turn_service.dart`、新 `reasoning_details_replay.dart` | extras 形狀不變 |
| 1 | R2 | `tool_replay.dart` | 一行 |
| 1 | U1 | 新 `core/utils/provider_url.dart`、`provider_detail_page.dart`、`model_provider.dart`、`settings_provider.dart`（`autoVersionDisabled`） | ProviderConfig 新可選欄位（向後相容） |
| 1 | O1 | `provider_oauth_service.dart`、`provider_oauth.dart`、`settings_provider.dart`、`oauth_provider_detail_page.dart` | ProviderConfig 新 `disabledModels`（隨備份同步、不進分享） |
| 2 | M1/M2 | `reasoning_capabilities.dart` | 無 |
| 2 | O2 | `provider_oauth_adapter.dart`、`provider_oauth.dart`、UI | `OAuthUsageWindow` 新 `remaining`/`advisory` |
| 2 | O3 | 新 stage 常數、`oauth_errors.dart`、`oauth_login_flow.dart`、l10n ×4 | 無 |
| 2 | R3 | `chat_api_service.dart` | 無 |

**遵循契約**：§5.3 的 5-Hook 全掛接規則（G1/C1 的任何參數處理須同步 generateText 主 body 1 處、sendMessageStream 主 body 1 處、body2 三種格式 3 處，共 5 處）；§5.5「嚴禁改動既有 HiveField，新欄位給預設值」；AGPL 來源標註：僅參考行為、以 OmniChat 原生重寫，不複製上游碼者免；若直接移植檔案須保留 `Ported from ... (AGPL-3.0), modified for OmniChat` 標頭並同步 `THIRD_PARTY_NOTICES.md`（依其既有慣例）。

## 4. 測試計畫

- **既有迴歸**：`flutter test`（手冊 §7.6 最新驗證：1,709 passed / 2 skipped，2026-11-04）全數維持綠燈；重點守衛 `test/core/reasoning_wire_test.dart`、`test/reasoning_capabilities_test.dart`、`test/message_builder_replay_tool_test.dart`、`test/replay_tool_results_api_test.dart`、`test/claude_max_tokens_test.dart`、`test/deepseek_claude_compat_test.dart`、`test/core/services/auth/*`。
- **新增**：gemini-4 wire/簽章保存、provider 切換協議測試、claude adaptive 版本解析/`between_tools`、reasoning_details round-trip、`builtin_search` 重放排除、`provider_url`/`ProviderTestFailure`、`disabledModels` 持久化與合併、OAuth usage 新視窗、stage 標籤。
- **實機 smoke**：Gemini 4（`gemini-4-argon`）多輪工具＋跨 Gemini 系供應商切換；Claude 5.5（Sonnet）off 行為；OpenRouter auto；OAuth 四家（真實訂閱帳號，與 §3.19 未完成驗收合併執行）。
- **平台**：Windows + Android 建置與 `flutter analyze`；不做 macOS/Linux/iOS 驗收（手冊口徑）。

## 5. 風險與相容性

1. **G2 簽章隔離**：切換供應商後第一輪請求未附真簽章，仰賴 Google 對佔位值的容忍（現行 gemini-3 已驗證可行）；若 Gemini 4 嚴格拒收佔位值，fallback 是「無簽章時不重放 functionCall part、改以文字摘要」— 列為 Phase 0 內的備援開關。另兩個邊界：(a) 同一 provider 改 baseUrl（AI Studio ↔ Vertex）時 providerId 不變，scope 必須含解析後 origin，否則仍會重放；(b) legacy `providerId == null` 的舊訊息無來源可判，僅在單一 Google 供應商帳號下安全，多供應商使用者需以對話層 `lastProviderId` 補記或列為已知限制。
2. **G2 artifacts 遷移**：只新增寫入路徑、legacy 只讀不洗資料，避免一次性遷移風險（比照手冊 §5.5 的保守慣例）。
3. **R1 合併規則**：文字串接必須精確（不加分隔、不去重），否則重放的思考內容失真；以向量測試釘住。
4. **U1 `resolveRequestUrl`**：是行為不變重構，任何 URL 組裝差異都會被既有 chat 測試抓到；先寫 URL 快照測試再動手。
5. **O1 disabledModels**：與既有「刪除模型」語義並存 — 刪除（models 列表移除）與停用（保留在列表、不進選擇器）同時提供；分享/QR 沿用 `apiKey 恆空 + oauth 標記` 既有脫敏，`disabledModels` 需加入分享白名單審核。
6. **上游差異風險**：上游 model-spec 體系（`ReasoningDialect`/`ModelSpec`）與 OmniChat 的 catalog+override 階梯不同，**只吸收行為規則，不搬架構**；所有 wire 變更走 OmniChat 既有方言/override 優先序（user > reasoningSynced > 目錄 > regex）。

## 6. 評估後不導入項目

| 上游項目 | 理由 |
|:--|:--|
| v1.3.3 桌面 side panel、360px 佈局、獨立 workspace web apps、上下文壓縮可逆化、對話級 MCP、Argon2id 備份加密、ElevenLabs/Qwen STT、legacy inline code style 等 | 屬大型新功能/產品方向，不在本次 8 項評估範圍；且 §7.6 已決議「不追求與 kelivo 1:1」。備份加密 OmniChat 另有 C-S01 決策（§7.3）走 AES-GCM |
| v1.3.4 訊息儲存 AOT 修復 | OmniChat 聊天儲存已切換至自家 SQLite/Drift 底座（§3.18），上游 Hive 寫入迴圈的修復前提不存在 |
| v1.3.4 Android 全選選單、iOS Live Activities、STT 提示色 | 與 OmniChat 自家輸入列/STT 樞紐實作不同源，無已知對應缺陷 |
| Responses 工具圖片保留（`a9b9ba9`） | OmniChat 工具結果為純字串（24KB 讀取上限、32KB 裁剪門檻），尚無「工具結果帶圖片進上下文」的功能面 |
| Gemini code-execution ID 去重（PR #1270 子項） | OmniChat 未啟用 Gemini code execution server tool |

---

**核定後動作**：Phase 0 開工前在本文件記錄核定日期與負責人；每個 Phase 完成後將本檔改名加 `（已實作）` 後綴並更新手冊 §3.5 / §3.11 / §3.19 對應小節（比照 §7.4 的上游導入紀錄慣例）。
