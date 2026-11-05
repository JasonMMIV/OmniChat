# OpenCode 供應商整合實作計畫（OpenCode Zen／Go）

> **版本**：v1.1  
> **日期**：2026-11-05  
> **狀態**：Phase 0–7 與 Phase 8 文件／自動化測試已完成；Phase 5 使用 `provider_artifacts(opencode_usage_v1)` 且不影響其他 provider 的 balance。實機驗收清單仍待真實 OpenCode key 執行。
>
> **範圍**：讓 OmniChat 以 API Key 直接使用 OpenCode Console／Zen（按量付費）與 OpenCode Go（訂閱）的推論端點；核心是 **`x-opencode-session` 工作階段標頭**、穩定的 conversation id 貫通、Provider 預設、**每則訊息的成本顯示**，以及 **`models.opencode.ai/api.json` 模型目錄同步（優先於 models.dev）**。  
> **非範圍**：OpenCode 本機 `opencode serve` HTTP Server（`/session`、`/event`、`@opencode-ai/sdk`）、OpenCode 帳號 OAuth 訂閱登入、`opencode` CLI 程序整合、Console MCP（`https://opencode.ai/console/mcp`）、Provider 餘額（balance）API 與 UI 變更。  
> **相關文件**：`OmniChat 專案開發與維護手冊.md` §3.5（多模型適配／推理）、§3.10（串流容錯）、§3.18（SQLite 儲存）、§3.19（Provider OAuth 與攔截點前例）、§4（架構決策）、§5（陷阱）、§7（現狀）  
> **上游參考**：Kelivo commit [`054695a`](https://github.com/Chevey339/kelivo/commit/054695a)、[issue #987](https://github.com/Chevey339/kelivo/issues/987)、`lib/core/services/api/provider_request_headers.dart`

---

## 0. 摘要（TL;DR）

OpenCode 的推論閘道（Console／Zen／Go）要求用戶端在**每一個推論請求**帶上 `x-opencode-session`：一個**每個對話穩定不變**的 opaque 字串。OpenCode Go **強制**此標頭，缺漏時回 HTTP 400 `MissingSessionID`，且因為發生在模型路由之前，**所有模型都會失敗**，不是單一模型問題。OpenCode Zen／Console（按量付費）則為建議值（影響路由與 prompt cache 前綴）。

OmniChat 目前**已有** `providerSessionHeaders()` 與 `sendMessageStream(sessionId:)` 的雛形，但：

1. `providerSessionHeaders()` 只處理 `oauthProvider != null` 的訂閱帳號，OpenCode（API Key）走不到；
2. 非 OAuth 路徑 `_clientFor()` 直接回傳內層 client，沒有任何 header 注入點；
3. 多數 `sendMessageStream`／`generateText` 呼叫端沒有傳 `sessionId`（只有 `chat_actions` 主路徑把 conversationId 當 `requestId` 傳）。

**核心架構改動**：

- 新增 `lib/core/services/api/opencode.dart`（純 Dart）：host 判定、session id 解析、model id 正規化。
- 擴充 `providerSessionHeaders()`：非 OAuth 且 host 為 `opencode.ai` 時回傳 `x-opencode-session` + `x-opencode-client`。
- 新增 `ProviderSessionClient`（`http.BaseClient` 薄包裝），在 `_clientFor()` 這個**單一攔截點**注入；一次建立、重試與工具續輪共用，天然滿足「同一 generation 內穩定」。
- 把 conversation id 貫通到所有 generation 入口（chat／agent loop／標題／摘要／翻譯／OCR）。
- 新增兩個 Provider 預設（`OpenCode Zen`、`OpenCode Go`）＋ 模型清單／id 正規化／錯誤提示。
- **成本顯示**：解析 `usage.opencode` 的 `cost`／`list_cost`／`allowance`／`billing_source`，寫入 `TokenUsage` 與每則訊息的 `MessageUsage`，在訊息統計列與用量明細顯示；**只對 OpenCode 生效，不碰任何 provider 的 balance 欄位或 `ProviderBalanceText`**。
- **模型目錄**：在 `ModelCatalogService` 內新增 OpenCode overlay，從 `https://models.opencode.ai/api.json` 同步（bundled snapshot + cache + ETag），以 **per-model overlay** 合併進 `ModelCatalog`；同名模型由 OpenCode 目錄覆蓋 models.dev，models.dev 獨有的模型保留。

**關鍵設計決策**：不新增 `ProviderKind`。OpenCode 對外提供 OpenAI Chat Completions、OpenAI Responses、Anthropic Messages、Gemini 四種協定，且 Console 會**跨協定翻譯**（每個付費／Go 文字模型在每個 API family 都可用），因此沿用 `ProviderKind.openai` + `/chat/completions` 即可，後續可用 provider 層 `useResponseApi` 切換。

**工作量**：約 **8–10.5 人日**（單人約 2 週；Phase 0–4 為主幹，Phase 5 成本與 Phase 6 目錄可平行）。

```
Phase 0 純函式／契約
  -> Phase 1 請求層注入（單一攔截點）
  -> Phase 2 conversationId 線程貫通
  -> Phase 3 Provider 預設與 UI
  -> Phase 4 模型清單與能力
       ├-> Phase 5 成本遙測與顯示
       └-> Phase 6 OpenCode 模型目錄同步
  -> Phase 7 錯誤 UX 與日誌去識別
  -> Phase 8 文件、測試、驗收
```

### 0.1 已確認決策（2026-11-05）

| # | 決策 | 落實位置 |
|:---|:---|:---|
| 1 | **內建兩個 preset**：`OpenCode Zen`、`OpenCode Go` | Phase 3（`_providers()`／`_defaultBase`／`defaultsFor`） |
| 2 | **成本顯示納入本版**，且**不得影響其他 provider 的餘額顯示** | Phase 5；只新增 `MessageUsage` 與訊息統計，不改 `ProviderConfig.balance*`／`ProviderBalanceText` |
| 3 | **`models.opencode.ai/api.json` 目錄同步納入本版**，且**優先於 models.dev** | Phase 6；per-model overlay merge，OpenCode 條目覆蓋同名 models.dev 條目 |
| 4 | **`/models` 不送 `x-opencode-session`** | 2026-11-05 查證：官方文件與實測皆顯示 `/models` 為公開端點；session 檢查只在 inference POST。維持 `ModelProvider.listModels` 現狀 |
| 5 | **OCR 暫不改 conversation-scoped session** | 接受 provider 級決定性 fallback；不影響主要聊天，列為已知限制 |
| 6 | **成本明細加入 `MessageMoreSheet` 的「用量」入口** | 即使 `showTokenStats == false` 也能開啟用量與成本明細 |
| 7 | **THIRD_PARTY_NOTICES 列 Kelivo OpenCode 衍生部分** | 與既有 Kelivo OAuth 註記並列 |
| 8 | **v2 項目不做** | 對話級彙總、成本預估／匯出、prompt cache 觀測、`modelsPath` 等維持 Out of Scope |

### 0.2 為什麼不能只叫使用者「自己加自訂 header」

- OmniChat 的自訂 header 存在 `modelOverrides[modelId]['headers']`（**逐模型**），使用者每抓一個新模型就要重設一次；OpenCode 的 session 是**逐對話**動態值，靜態 header 無法表達。
- 手動填 `x-opencode-session` 只能填死一個值，等於所有對話共用一個 session：不會 400，但路由與 prompt cache 全部混在一起，失去供應商端的最佳化。
- 因此必須由程式在請求層自動注入，並以 conversation id 為值。

### 0.3 實作現況（2026-11-05）

**已完成（Phase 0–7）**

- Phase 0：`lib/core/services/api/opencode.dart`（host 判定、session id、model id 正規化）、`provider_request_headers.dart` 的 OpenCode 分支。
- Phase 1：`ProviderSessionClient` + `_clientFor` 單一注入點；覆蓋 chat／responses／claude／images／generateText／retry。
- Phase 2：`chat_actions`（主路徑＋proposer＋agent loop）、`ChatTurnRequest.conversationId`、`home_view_model` 標題／摘要、`side_drawer`、`translation_service` 已傳 `sessionId`；OCR 仍走 provider 級決定性 fallback。
- Phase 3：`OpenCode Zen`／`OpenCode Go` preset、`_defaultBase`、`balanceEnabled: false` + 空 balance path/key。
- Phase 4：`_apiModelId` 與 `ModelRegistry.inferForProvider` 都會剝除 `opencode/`／`opencode-go/` 前綴；模型清單本身零改動。
- Phase 6：`ModelCatalogService` OpenCode overlay（`assets/model_catalog/opencode.json`、cache、ETag、1 天 stale）、`mergeCatalogJson`／`filterCatalogProviders`、Zen/Go base URL 路徑解析、`ModelProvider` 刷新觸發；建置工具 `tool/build_opencode_catalog.dart`。
- Phase 7：`opencode_errors.dart` 錯誤分類、`chat_actions` 在地化提示、`RequestLogger` 遮罩 `x-opencode-session`。
- Phase 5：`MessageUsage`、`usage.opencode` 解析、`TokenUsage` snapshot／accumulate、`provider_artifacts(opencode_usage_v1)` 持久化、備份依 kind 驗證、訊息統計列與用量明細 sheet。

**驗證**

- `flutter test` 目標測試全數通過：session／preset／balance／error／redaction／chat turn、catalog merge／overlay refresh，以及成本解析／聚合／SQLite 重啟／備份還原。
- `flutter analyze` 0 error；既有 warning 不在本次新增檔案。

---

## 1. 現況盤點（As-Is）

### 1.1 傳輸層與 Provider 模型

| 層 | 檔案 | 現況 |
|:---|:---|:---|
| Provider 設定模型 | `lib/core/providers/settings_provider.dart`（`ProviderConfig`，約 4012 起；`ProviderKind` 約 4005） | `ProviderKind { openai, google, claude, neuralwatt }`；`openai` 同時承載所有 OpenAI 相容供應商 |
| 預設值 | `ProviderConfig.defaultsFor`（約 4433）、`_defaultBase`（約 4409）、`classify`（約 4400） | 以 key 子字串決定 kind／baseUrl；`OpenCode` 目前落入 fallback `https://api.openai.com/v1` |
| Provider 清單 UI | `lib/features/provider/pages/providers_page.dart`（`_providers()` 約 250–290） | 內建 preset 以 `_p(name, key)` 宣告；`OpenAI`／`SiliconFlow`／`Gemini`／`OpenRouter`／`Tensdaq`／`DeepSeek`／`Neuralwatt`／`AIhubmix`／`Aliyun`／`Zhipu AI`／`Claude`／`Grok`／`ByteDance` |
| 聊天傳輸 | `lib/core/services/api/chat_api_service.dart` | `sendMessageStream` / `generateText` → `_sendOpenAIStream`（chat & responses）／`_sendClaudeStream`／`_sendGoogleStream`／`_sendOpenAIImagesStream` |
| Client 建立 | 同上，`_clientFor`（約 1187–1220） | 先建 `DioHttpClient`（proxy／cancel／redaction），**非 OAuth 直接 `return inner`**；OAuth 才包 `OAuthHttpClient` |
| 既有 session header | `lib/core/services/api/provider_request_headers.dart` | 只處理 `OAuthProvider.chatgpt / claude`；`provider == null` 時回空 map |
| OAuth 攔截點 | `lib/core/services/auth/oauth_http_client.dart`（`_shape`） | 在 header 上 `addAll(providerSessionHeaders(...))`；這是目前唯一的 session header 注入點 |
| 模型清單 | `lib/core/providers/model_provider.dart`（`OpenAIProvider.listModels` 約 248） | `${cfg.baseUrl}/models` + `Authorization: Bearer`，`data[]` 解析 |
| 錯誤呈現 | `lib/features/home/controllers/chat_actions.dart`（`_handleStreamError` 約 2445） | 非 OAuth 一律 `e.toString()`（`HTTP 400: {...}` 原文）進氣泡／snackbar |
| 請求日誌 | `lib/core/services/network/request_logger.dart`（`redactHeaders`） | 已遮罩 `authorization`／`x-api-key`／OAuth session 類標頭 |

### 1.2 既有的 session 基礎其實已就位

`sendMessageStream` 的簽章已有一個**明確契約**的參數（節錄）：

```dart
// Stable conversation session id for provider attribution / prompt-cache
// prefixes (plan C15). Callers pass the conversation id; never random.
String? sessionId,
```

`_clientFor` 也已經接受 `sessionId` / `requestId`，並且對 OAuth 傳 `conversationId: sessionId`。也就是說：**管線存在，缺的是「非 OAuth 的注入點」與「呼叫端把 conversation id 傳下來」**。這與 Kelivo 的修法（commit `054695a`）完全同構。

### 1.3 成本與模型目錄現況（本版新增範圍）

#### 成本

| 層 | 檔案 | 現況 |
|:---|:---|:---|
| 用量模型 | `lib/core/models/token_usage.dart` | 只有 `promptTokens`／`completionTokens`／`cachedTokens`／`totalTokens`；`merge()` 對 token 取 **max**（串流快照語義），沒有成本欄位 |
| 訊息持久化 | `lib/core/models/chat_message.dart` | `totalTokens`（HiveField 6）、`promptTokens`（17）、`completionTokens`（18）、`cachedTokens`（19）；`toJson`／`fromJson` |
| SQLite schema | `lib/core/services/chat/storage/app_database.dart`（`MessageRows`，約 77–122） | `messages` 只有四個 token 整數欄；**沒有通用 metadata JSON 欄**；`currentChatSchemaVersion = 1`，installation gate **拒絕任何舊 schema 升級**（`No upgrade steps are published from schema N`） |
| 側表 | 同上 `ProviderArtifacts`（約 170） | `(message_id, kind)` 複合主鍵、`payload` TEXT、FK cascade；現只有 `kGeminiThoughtSignatureKind` 使用 |
| 儲存介面 | `lib/core/services/chat/storage/chat_storage.dart` | 已有 `getGeminiThoughtSignature`／`set...`／`remove...`；`updateMessage` 收 token 欄位 |
| 備份 | `lib/core/services/chat/storage/chat_backup_restorer.dart` | `ChatBackupPayload.geminiThoughtSigs`；`signatureCount => geminiThoughtSigs.length`；`verifyCounts` 以 **provider_artifacts 總數** 對比 `signatureCount` |
| 串流備份 | `lib/core/services/backup/data_sync.dart` | 匯出 `"geminiThoughtSigs"`（約 712）；解析（約 1135）；兩個 iterate 點（約 1199／1261） |
| 餘額 UI | `lib/features/provider/widgets/provider_balance_text.dart` | `if (cfg.balanceEnabled != true) return SizedBox.shrink();`；`ProviderManager.getBalance` 依 `balanceEnabled` 決定是否發請求 |

**結論**：成本不能新增 SQLite 欄位（schema v2 被 gate 擋住），也不能走「generic metadata column」（不存在）。可用且不改 schema 的持久化位置是 **`provider_artifacts` 側表**；備份計數需改成 **按 kind 計數**，否則新增成本 artifact 會讓 restore 驗證失敗。

#### 模型目錄

| 層 | 檔案 | 現況 |
|:---|:---|:---|
| 目錄模型 | `lib/core/services/model_catalog/model_catalog.dart` | `ModelCatalog` 單一 `instance`；lookup 階梯：provider id → host → global id → `canonical_model_id` → normalized id；`resolveCatalogProviderId` 以 id／name／host／transport 推斷 |
| 載入／刷新 | `lib/core/services/model_catalog/model_catalog_service.dart` | bundled `assets/model_catalog/models_dev.json` → cache `model_catalog_v1.json` → `https://models.dev/api.json`（ETag、30 天 stale、15 秒 timeout、single-flight） |
| 建置產物 | `tool/build_model_catalog.dart` | 下載 models.dev、`pruneCatalogJson`、寫入 `assets/model_catalog/models_dev.json` + `NOTICE.md` |
| 能力消費 | `ModelRegistry.infer`／`inferForProvider`、`ReasoningCapabilities`、`chat_api_service`、`context_trim` | 全部直接讀 `ModelCatalog.instance`；沒有第二來源或 overlay 概念 |

**結論**：要讓 OpenCode 目錄優先，最省改動的方式是 **在 catalog 載入時合併**（OpenCode 條目覆蓋同名 models.dev 條目），而不是改所有 lookup 呼叫端。

### 1.4 缺口表

| # | 缺口 | 現況 | 目標 | 工作流 |
|:---|:---|:---|:---|:---|
| G1 | OpenCode 沒有 session header | `providerSessionHeaders` 對非 OAuth 回空 map | host 為 `opencode.ai` 時回 `x-opencode-session`（＋`x-opencode-client`） | Phase 0 |
| G2 | 非 OAuth 沒有注入點 | `_clientFor` 對非 OAuth `return inner` | 新增 `ProviderSessionClient` 並在 `_clientFor` 包裝 | Phase 1 |
| G3 | conversation id 沒貫通 | 僅 `chat_actions` 主路徑以 `requestId` 傳 conversationId；`chat_turn_service`／`agent_orchestrator`／`generateText` 多數未傳 | 所有推論入口傳 `sessionId: conversationId`（或穩定替代值） | Phase 2 |
| G4 | 沒有 Provider preset | `OpenCode Zen` 落入 `api.openai.com` | `_defaultBase`／`defaultsFor`／`_providers()` 新增兩個 preset | Phase 3 |
| G5 | 模型 id 可能帶前綴 | OpenCode 設定檔常用 `opencode/<id>`、`opencode-go/<id>`；直接打 API 要裸 id | 請求前剝除前綴（`normalizeOpenCodeModelId`） | Phase 4 |
| G6 | 模型能力未知 | models.dev 未必收錄 Console 專有 id | OpenCode 目錄 overlay 優先；models.dev 補齊其他 provider | Phase 6 |
| G7 | 成本沒有解析 | 各 transport 只讀 token 欄位 | 解析 `usage.opencode` 與 `usage.cost` | Phase 5 |
| G8 | 成本沒有持久化 | `messages` 無成本欄、schema v1 不可升級 | 用 `provider_artifacts(kind=opencode_usage_v1)` 存 `MessageUsage` | Phase 5 |
| G9 | 成本沒有顯示 | 統計列只顯示 tokens／字數 | `MessageStatsLine` 追加成本；用量明細 sheet | Phase 5 |
| G10 | 備份會因新 artifact kind 驗證失敗 | `verifyCounts` 對比 provider_artifacts 總數 | 改為按 kind 計數；成本隨 `ChatMessage.toJson` 備份 | Phase 5 |
| G11 | 餘額顯示可能被誤動 | `ProviderBalanceText` 只看 `balanceEnabled` | OpenCode preset 保持 `balanceEnabled: false`；加回歸測試 | Phase 5 |
| G12 | 錯誤原文不友善 | `HTTP 400: {"type":"error","error":{"type":"MissingSessionID"...}}` 直接給使用者看 | 針對 `MissingSessionID`／`FreeTierError`／402／`ModelProtocolUnsupported` 給在地化提示 | Phase 7 |
| G13 | session id 會進日誌 | `redactHeaders` 未列 `x-opencode-session` | 加入遮罩名單 | Phase 7 |

---

## 2. OpenCode API 契約（2026-11 考證）

> 命名提醒：`opencode.ai/zen` 與 `opencode.ai/docs/zen` 目前會導向 **OpenCode Console › Models**。官方文件稱按量付費閘道為 **Console**（舊稱 Zen），另有訂閱制 **OpenCode Go**。本文沿用檔名與 preset 的 `OpenCode Zen` 作為舊稱別名，實際 API 相同。

### 2.1 產品與 Base URL

| 方案 | Base URL（本計畫採用） | 說明 |
|:---|:---|:---|
| Console／Zen（按量付費） | `https://opencode.ai/zen/v1` | 舊別名仍完整路由；`/models`、`/chat/completions`、`/responses`、`/messages` 都掛在此 base |
| OpenCode Go（訂閱） | `https://opencode.ai/zen/go/v1` | 同上；**`x-opencode-session` 強制** |
| 新版文件 base | `https://opencode.ai/inference`（Go：`/inference/go`） | 端點為 `/openai/v1/chat/completions`、`/anthropic/v1/messages`、`/google/v1beta/...`；**與 OmniChat 的 `baseUrl + chatPath` 模型不合**（模型清單是 `/inference/go/v1/models`，不是 `/inference/go/openai/v1/models`） |

**決策**：preset 使用 `/zen/v1` 與 `/zen/go/v1`。原因：OmniChat 的 `OpenAIProvider.listModels` 與 `_sendOpenAIStream` 都是「baseUrl + 固定 path」，只有舊別名的形狀能同時滿足 `/models` 與 `/chat/completions`。若未來別名下架，再於 §9 加「per-provider modelsPath」覆寫。

### 2.2 端點對照（以 `https://opencode.ai/zen/v1` 為 base）

| 用途 | 路徑 | OmniChat 對應 |
|:---|:---|:---|
| 模型清單 | `GET /models` | `OpenAIProvider.listModels` |
| Chat Completions | `POST /chat/completions` | `_sendOpenAIStream`（`chatPath: '/chat/completions'`） |
| Responses | `POST /responses` | `_sendOpenAIStream`（`useResponseApi: true`） |
| Anthropic Messages | `POST /messages` | `_sendClaudeStream`（providerType 需為 `claude`；`max_tokens` 必填，既有協商層已覆蓋） |
| Gemini | `POST https://opencode.ai/inference/google/v1beta/models/<model>:generateContent` | `_sendGoogleStream`；**不採用**（需要獨立 base，與 preset 的 `baseUrl + path` 形狀不合） |

**關鍵事實**：Console 會把請求翻譯到模型的原生端點——「Every API serves every paid and Go text model」。因此**不需要** per-model 協定路由；單一 `ProviderKind.openai` 就能用全部付費／Go 文字模型。這一點不同於 Kimi 的 per-model `oauthProtocol`（手冊 §3.19）。

### 2.3 必要／建議標頭

| 標頭 | 必要性 | 值 | 備註 |
|:---|:---|:---|:---|
| `Authorization` | 必要 | `Bearer oc_sk_...` | Console 建立的 API Key；每個 key 綁定單一 workspace，無需 workspace 標頭 |
| `x-opencode-session` | **Go 強制**；Zen 建議 | 每個對話穩定的 opaque 字串（官方工具用 `ses_` + 32 hex） | 缺失時 Go 回 400 `MissingSessionID`；發生在模型路由前，**所有模型都失敗** |
| `x-opencode-client` | 建議（非公開文件） | 用戶端識別，例如 `omnichat` | Pi／GoModel／Docker 等第三方實作會送；官方 Go 文件要求「用自己的 User-Agent，而非通用 SDK 名稱」 |
| `User-Agent` | 建議 | 自有名稱（`OmniChat` 或 `OmniChat/<version>`） | **不可偽造** `OpenCode/...`；免費模型限制不是靠 UA 繞過 |
| `Content-Type` | 必要 | `application/json` | 既有 header builder 已送 |

**不要送**：`x-opencode-request`／`x-opencode-org-id`（第三方觀察到但用途未公開，無證據必要，先不擴大攻擊面）。

### 2.4 已知 quirks

1. **免費模型僅限官方用戶端**：Console 的 free-tier 模型對第三方用戶端回 `403 FreeTierError`，即使 key 有效。換 UA／重登無效。OmniChat 應明確提示「請改用付費或 Go 模型」，而不是誤導使用者重設 key。
2. **`ModelProtocolUnsupported` 可能偽裝成 401**：把只在 Responses 提供的模型送到 `/chat/completions`，歷史上曾回 401（部分路由器回 400）。因為 Console 會跨協定翻譯，付費／Go 模型理論上不會遇到；若遇到，提示切換 `useResponseApi` 或改用 Claude 傳輸。
3. **Anthropic 路徑 `max_tokens` 必填**：走 `/messages` 時由既有 §3.5 Claude max_tokens 協商處理；若使用者把 OpenCode 設成 `ProviderKind.claude`，模型清單會用 `x-api-key` 而非 Bearer，**可能抓不到清單**——preset 一律用 OpenAI kind。
4. **推理參數不能「省略就等於關閉」**：部分模型永遠推理並要求 `low/high/max`（例：`[1210] This model always engages in thinking...`）；`kimi-k3` 在 Go 的預設是 High，要關閉必須明確送 `reasoning_effort: "none"`。OmniChat 既有的 effort 對應可表達 `low/high/max`；若某模型要求關閉時必須明確送 `none`、而目前 chain 是省略參數，則以 per-model override／`reasoningWire` 處理（§3.5 既有機制），不在此階段改動全局推理鏈。
5. **Session header 是無預警變強制的**：OpenCode Go 在 2026-09 後要求此標頭且沒有 deprecation window。實務教訓：把契約集中在一個 helper + 一支測試，遇到新型 400 先懷疑契約變更。
6. **計費資訊只在串流末端**：`usage.opencode.{cost,list_cost,billing_source,...}`（chat completions 需 `stream_options.include_usage`）。Go 的 `cost` 是 `0`，真正可用的數字是 `list_cost` 與 `allowance`。

### 2.5 Kelivo 上游作法考證（實作參考）

Kelivo **沒有** OpenCode 專屬 provider preset、也沒有新增 `ProviderKind`；它把 OpenCode 當一般自訂供應商，唯一的特例是 host 判定後注入 session header：

```dart
// chevey339/kelivo: lib/core/services/api/provider_request_headers.dart
final host = Uri.tryParse(config.baseUrl)?.host.toLowerCase();
...
if (host != 'opencode.ai') return extraHeaders;
final id = conversationId?.trim() ?? '';
return {
  'x-opencode-session': id.isEmpty ? const Uuid().v4() : id,
  ...?extraHeaders, // 使用者自訂 header 最後覆蓋
};
```

重點：

- **精確 host 比對** `opencode.ai`（`opencode.ai.example.com`、`fakeopencode.ai` 都不匹配），避免把對話 id 泄漏給相似網域。
- **每次 generation 解析一次**（在 retry 與 tool follow-up 之前），因此同一輪的所有請求共用同一個 id。
- **使用者自訂 header 優先**（spread 在最後）。
- `conversationId` 一路從 `sendMessageStream` / `generateMessage` / `generateText` 傳到 provider adapter；Kelivo 的 commit 一次補齊 chat、tool loop、翻譯、OCR、memory、標題生成等入口。
- Kelivo 的 base URL 實測為 `https://opencode.ai/zen/go/v1`；測試涵蓋 `chat/completions`、`responses`、`messages` 三條路徑。

**本計畫與 Kelivo 的兩個刻意差異**：

1. **不隨機 UUID**：OmniChat 的 C15 契約明寫「never random」。沒有 conversation id 時，改用 `oauthStableUuid('opencode:<providerId>:<baseUrl>')` 的**決定性**值，避免同一使用者的每次 utility 請求都換 session、破壞 cache 前綴。
2. **加內建 preset**：Kelivo 讓使用者自己填 base URL；OmniChat 已有 `_providers()`／`defaultsFor` 機制，加 preset 成本低、可避免打錯 `/zen` 與 `/zen/go`。

### 2.6 成本遙測契約（本版新增）

#### 回傳形狀

官方文件與第三方實測（Go、`glm-5.3-flash`／`deepseek-v4.1-flash`）的 `usage` 形狀：

```json
"usage": {
  "prompt_tokens": 13,
  "completion_tokens": 10,
  "total_tokens": 23,
  "prompt_tokens_details": { "cached_tokens": 0, "cache_write_tokens": null },
  "completion_tokens_details": { "reasoning_tokens": 10 },
  "cost": 0,
  "opencode": {
    "billing_source": "go",
    "list_cost": 0.00000695,
    "allowance": 0.00000695,
    "tokens": {
      "input": 13,
      "output": 10,
      "reasoning": 10,
      "cache_read": 0,
      "cache_write_5m": 0,
      "cache_write_1h": 0
    }
  }
}
```

| 欄位 | 語義 |
|:---|:---|
| `usage.cost` | 實際扣款（USD）。免費模型與 Go 在額度內為 `0`；BYOK 時是估算值（`opencode.estimated: true`）；模型沒有定價時可能缺席 |
| `opencode.billing_source` | `free`／`balance`／`go`／`go-plus`／`byok` |
| `opencode.list_cost` | 依模型定價（含尖峰／長上下文）計算的美元金額；**Go 要看這個，不是 `cost`** |
| `opencode.allowance` | 只有 Go：本次請求吃掉多少「方案月額度」美元 |
| `opencode.estimated` | 只有 BYOK：`cost` 是估算值 |
| `opencode.tokens` | 計費 token：`input` 不含 cache read/write；`output` 含 `reasoning` |

#### 各 transport 的出現位置

| Path | 容器 | 串流位置 |
|:---|:---|:---|
| OpenAI Chat Completions | `usage` | 最後一個 `choices: []` 的 usage chunk（需 `stream_options.include_usage`）；中間 chunk 的 `usage` 為 `null` |
| OpenAI Responses | `usage`（response 物件） | `response.completed` 事件 |
| Anthropic Messages | `usage` | `message_delta`（`input_tokens` 在 `message_start`、`output_tokens` 在 `message_delta`；成本取 `message_delta`） |
| Gemini | `usageMetadata` | 最後一個 `streamGenerateContent` chunk |

#### 顯示規則（OpenCode 專用）

| `billing_source` | 統計列主顯示 | 明細 sheet |
|:---|:---|:---|
| `free` | `免費` | `$0`、tokens 明細 |
| `balance` | `$0.0041`（`cost`） | `cost`／`list_cost`／tokens |
| `go`／`go-plus` | `配額 $0.0000069`（`allowance`）；若 `allowance` 為 0 則 `定價 $0.0000069` | `allowance`／`list_cost`／`cost: $0`／tokens |
| `byok` | `≈$0.0041`（`estimated` 為 true 時加 `≈`） | `cost`／`estimated`／tokens |
| 未知／缺席 | 不顯示成本 | 只顯示 tokens |

**格式**：`formatUsd` 純函式；`>= 0.01` 四位小數、`>= 0.0001` 六位、其餘八位並去尾零；`0` → `$0`；`null` → 不顯示。Go 的 `allowance` 可能極小（例：`0.00000695`），八位可保留原始精度。

**邊界**：
- `billing_source == 'go'` 時 `usage.cost` 是 `0`，**不得**當成「免費」顯示。
- `allowance != list_cost` 是正常的（Go 配額倍率，例如某些模型 2.0×／0.75×）；兩個都存、都顯示。
- 串流中間 chunk 的 `usage` 可能是 `null`，解析器必須容忍。
- 只有 `usage.opencode` 存在時才建立 `MessageUsage`；其他 provider 即使回傳 generic `cost` 也不顯示（避免改變既有 UI）。

### 2.7 模型目錄契約（本版新增）

`https://models.opencode.ai/api.json` 是 OpenCode 代管的 **models.dev v1 `api.json`**（檔案 > 2 MB；OpenCode 自己快取在 `~/.cache/opencode/models.json`，每小時刷新）。它是 **provider-keyed map**，每個 provider 內含 `models` map：

```jsonc
{
  "opencode": {
    "id": "opencode",
    "name": "OpenCode",
    "npm": "@ai-sdk/openai-compatible",
    "env": ["OPENCODE_API_KEY"],
    "doc": "https://opencode.ai/v2/docs/console/models/",
    "api": "https://opencode.ai/inference/openai/v1",
    "models": {
      "glm-5.3": {
        "name": "GLM-5.3",
        "attachment": false,
        "reasoning": true,
        "tool_call": true,
        "structured_output": true,
        "temperature": true,
        "limit": { "context": 1000000, "output": 131072 },
        "modalities": { "input": ["text"], "output": ["text"] },
        "cost": { "input": 1.4, "output": 4.4, "cache_read": 0.26 },
        "reasoning_options": [{ "type": "effort", "values": ["low", "high", "max"] }],
        "canonical_model_id": "zhipuai/glm-5.3"
      }
    }
  }
}
```

| 欄位 | 用途 |
|:---|:---|
| `limit.context`／`limit.input`／`limit.output` | 上下文與輸出上限；`effectiveInputWindow` 優先 `input` |
| `modalities.input`／`output` | vision／image output 判定 |
| `tool_call`／`reasoning`／`temperature` | 能力旗標；`false` 是明確否定，缺席是未知 |
| `reasoning_options` | `type: effort` 的 `values` 映射到 OmniChat 檔位；`toggle` 表示可關閉 |
| `interleaved.field` | `reasoning_content`／`reasoning_details` 回放欄位 |
| `cost.*` | 每 1M token 美元定價；**本版 runtime catalog 不保留**（prune 會丟棄；成本顯示以 `usage.opencode` 為準，估算列 v2） |
| `status` | `alpha`／`beta`／`deprecated`；**本版 runtime catalog 不保留**（prune 會丟棄；deprecated UI 列 v2） |
| `canonical_model_id` | 回退 lookup 的 canonical id |
| 每模型 `api.<protocol>` | 該模型原生協定；本計畫只用來理解資料，不據此切 transport |

**Provider id**：目錄至少會有 `opencode`（Zen）；Go 可能以 `opencode-go` 或同一個 `opencode` 表示。兩者的 `api` host 都是 `opencode.ai`，因此 `resolveCatalogProviderId` 以 host 命中時會落到排序較前的 `opencode`；本計畫再加一個明確規則：host == `opencode.ai` → 優先 `opencode`（若不存在才找 `opencode-go`），讓 Zen 與 Go 共用同一份能力資料。模型 id 皆為裸 id（`glm-5.3`、`kimi-k3`），與 API 一致。

**優先序**：`models.dev` 是 base，`models.opencode.ai` 是 overlay；**同名 provider + 同名 model 由 OpenCode 覆蓋**，OpenCode 沒有的 model 保留 models.dev 條目。這樣「OpenCode 目錄優先」是 per-model 的，不會讓其他 provider 失去資料。

---

## 3. 設計決策（Decision Record）

| # | 決策 | 理由 | 替代方案與否決原因 |
|:---|:---|:---|:---|
| D1 | 不新增 `ProviderKind`，沿用 `openai` + `/chat/completions` | Console 跨協定翻譯；單一 transport 可覆蓋全部付費／Go 文字模型 | 新增 `opencode` kind：要改 `_apiKind`、`builtin_tools`、UI、備份匯入等十餘處，零協定收益 |
| D2 | 注入點放在 `_clientFor` 的 `ProviderSessionClient` | 與 OAuth 的 `OAuthHttpClient` 對稱；一次建立涵蓋 chat／responses／claude／images／generateText／retry／tool 續輪 | 在每個 `_send*` 入口 merge `extraHeaders`：12+ 個 header 建構點，漏一處就 400 |
| D3 | host **精確等於** `opencode.ai` | 防止 session id 泄漏到 `opencode.ai.evil.com`；Kelivo 已驗證 | `contains('opencode.ai')`：會被相似網域繞過 |
| D4 | session 值優先序：`conversationId` → `sessionId` → `requestId` → 決定性 uuid | 對話內穩定；utility 請求也有穩定值 | 隨機 v4（Kelivo）：符合「有送就好」，但違反本專案 C15「never random」 |
| D4a | 值維持 conversationId 原樣，不強制加 `ses_` 前綴 | 官方文件稱其為 opaque；Kelivo 以裸 id 上線驗證可用 | 加 `ses_`：若未來形狀驗證變嚴，只需在 `resolveOpenCodeSessionId` 一處加前綴，呼叫端不動 |
| D5 | 使用者自訂 header 優先（`putIfAbsent`） | 保留逃生門（自架 relay／測試） | 強制覆蓋：使用者無法除錯 |
| D6 | 不偽造 OpenCode 官方 UA | 合規；免費模型限制是伺服器端判斷，偽造只會違反 ToS | 偽造 `OpenCode/...`：可能被視為濫用 |
| D7 | 請求前剝除 `opencode/`、`opencode-go/` 前綴 | 使用者常從 OpenCode 設定檔複製模型 id；直接打 API 要裸 id | 只在抓清單時處理：手動新增模型仍會 404 |
| D8 | 錯誤訊息在地化，但保留原始錯誤於 debug log | 使用者看到可行動提示；除錯仍有原始 body | 直接顯示 raw JSON：已困擾使用者 |
| D9 | `x-opencode-session` 納入日誌遮罩 | 雖為 opaque，但等於對話識別碼 | 不遮罩：日誌匯出會帶對話關聯 |
| D10 | 成本欄位加在 `TokenUsage`（nullable），另建 `MessageUsage` 作為持久化/顯示物件 | `TokenUsage` 是所有 transport 的共用聚合器；`MessageUsage` 只裝成本與計費 token，避免污染其他 provider | 直接改 `ChatMessage` 欄位／SQLite 欄位：schema v1 gate 拒絕升級 |
| D11 | 成本只對 OpenCode 顯示；generic `usage.cost` 不解析、不顯示 | 直接滿足「不影響其他 provider」；其他 provider 的 UI 完全不變 | 全 provider 顯示成本：會改變既有畫面與測試，且多數供應商沒有可靠成本 |
| D12 | 成本持久化走 `provider_artifacts`（`opencode_usage_v1`），**不新增 SQLite 欄位** | schema v1 不可升級；`provider_artifacts` 已有 `(message_id, kind)` 與 cascade | 新增 `messages.usage_meta_json`：需要 schema v2 + gate migration，風險過高 |
| D13 | 備份把成本放在 `ChatMessage.toJson`，restore 時寫回 artifact；`verifyCounts` 改按 `kind` 計數 | 不新增備份 payload key；舊備份沒有 `usageMeta` 也能還原 | 新增 `opencodeUsage` payload map：要改 streaming export/parse/兩個 iterate 點，重複且易漏 |
| D14 | OpenCode 目錄以 **per-model overlay** 合併進 `ModelCatalog` | 一次載入、所有 lookup 呼叫端零改動；OpenCode 同名模型覆蓋 models.dev，其餘保留 | 第二個 `ModelCatalog` + 改所有 lookup：10+ 呼叫點，容易漏 |
| D15 | OpenCode preset 的 `balanceEnabled` 明確設為 `false`，`balanceApiPath`／`balanceResultKey` 清空 | 避免 `ProviderBalanceText` 誤觸 `getBalance`；成本顯示與餘額完全脫鉤 | 讓 OpenCode 走 balance：需要新的餘額 API，超出範圍 |

---

## 4. 分階段實作

### Phase 0：純函式與契約層（0.5 人日）

**新增** `lib/core/services/api/opencode.dart`（零 Flutter import，可單測）：

```dart
const String kOpenCodeClientId = 'omnichat';
const String kOpenCodeZenBaseUrl = 'https://opencode.ai/zen/v1';
const String kOpenCodeGoBaseUrl = 'https://opencode.ai/zen/go/v1';

bool isOpenCodeBaseUrl(String baseUrl) {
  final uri = Uri.tryParse(baseUrl.trim());
  return uri != null && uri.host.toLowerCase() == 'opencode.ai';
}

/// 對話內穩定；缺 id 時退回決定性 uuid（禁止每次請求隨機）。
String resolveOpenCodeSessionId({
  required String providerId,
  required String baseUrl,
  String? conversationId,
  String? sessionId,
  String? requestId,
}) {
  for (final candidate in <String?>[conversationId, sessionId, requestId]) {
    final v = (candidate ?? '').trim();
    if (v.isNotEmpty) return v;
  }
  return oauthStableUuid('opencode:$providerId:$baseUrl');
}

Map<String, String> openCodeSessionHeaders({
  required String providerId,
  required String baseUrl,
  String? conversationId,
  String? sessionId,
  String? requestId,
}) => {
  'x-opencode-session': resolveOpenCodeSessionId(
    providerId: providerId,
    baseUrl: baseUrl,
    conversationId: conversationId,
    sessionId: sessionId,
    requestId: requestId,
  ),
  'x-opencode-client': kOpenCodeClientId,
};

/// `opencode/glm-5.3`、`opencode-go/glm-5.3` → `glm-5.3`
String normalizeOpenCodeModelId(String modelId) { ... }
```

**新增** `lib/core/models/message_usage.dart`（純 Dart；Phase 5 直接使用）：

```dart
class MessageUsage {
  final double? costUsd;
  final double? listCostUsd;
  final double? allowanceUsd;
  final String? billingSource;
  final bool estimated;
  final int? inputTokens;
  final int? outputTokens;
  final int? reasoningTokens;
  final int? cacheReadTokens;
  final int? cacheWrite5mTokens;
  final int? cacheWrite1hTokens;

  bool get isEmpty => costUsd == null && listCostUsd == null && allowanceUsd == null;
  Map<String, dynamic> toJson();
  factory MessageUsage.fromJson(Map<String, dynamic> json);
  static MessageUsage? tryParse(String? raw);
}
```

**新增** `lib/core/services/api/opencode_cost.dart`（純 Dart）：

```dart
/// 只在 usage.opencode 存在時回傳；其他 provider 一律 null。
MessageUsage? openCodeUsageFromJson(Map? usage) { ... }

/// 把成本與計費 token 疊到既有 TokenUsage；沒有 opencode 區塊時原樣返回。
TokenUsage applyOpenCodeUsage(TokenUsage base, Map? usage) { ... }
```

**修改** `lib/core/services/api/provider_request_headers.dart`：

```dart
final provider = config.oauthProvider;
if (provider == null) {
  if (!isOpenCodeBaseUrl(config.baseUrl)) return const <String, String>{};
  return openCodeSessionHeaders(
    providerId: config.id,
    baseUrl: config.baseUrl,
    conversationId: conversationId,
    sessionId: sessionId,
    requestId: requestId,
  );
}
// 以下 OAuth switch 完全維持原樣（包含 sessionId 只取 session 的現行語義）
```

**注意**：不要把 OAuth 分支的 `session` 改成 fallback `conversationId`；那會改變 ChatGPT／Claude 既有的 session 行為（手冊 §3.19）。

**測試**：`test/core/services/api/opencode_test.dart`、`test/core/message_usage_test.dart`（見 §5）。

**完成定義**：`providerSessionHeaders(非 OAuth OpenCode config)` 回傳兩個標頭；相似網域回空；OAuth 行為 byte-identical；成本 parser 對 Go／balance／free／byok 四種形狀皆正確。

---

### Phase 1：請求層注入（1 人日）

**新增** `lib/core/services/api/provider_session_client.dart`：

```dart
class ProviderSessionClient extends http.BaseClient {
  ProviderSessionClient({required http.Client inner, required Map<String, String> headers})
      : _inner = inner,
        _headers = Map<String, String>.unmodifiable(headers);

  final http.Client _inner;
  final Map<String, String> _headers;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    // 使用者自訂 header 已由 _customHeaders/extraHeaders 寫入，優先保留。
    for (final e in _headers.entries) {
      request.headers.putIfAbsent(e.key, () => e.value);
    }
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}
```

**修改** `lib/core/services/api/chat_api_service.dart` 的 `_clientFor`（並補上 `opencode.dart`／`provider_request_headers.dart`／`provider_session_client.dart` 的 import）：

```dart
if (!isOAuth) {
  final headers = providerSessionHeaders(
    config,
    sessionId: sessionId,
    conversationId: sessionId, // 本專案的 sessionId 即 conversation session id（見 sendMessageStream 註解）
    requestId: requestId,
  );
  if (headers.isEmpty) return inner;
  return ProviderSessionClient(inner: inner, headers: headers);
}
```

**為何這樣就滿足「retry／tool 續輪穩定」**：client 在 `sendMessageStream` 的 retry loop **之前**建立一次，loop 內所有嘗試與 follow-up 都重用同一個 client 與同一份 header map。

**覆蓋面**：`_sendOpenAIStream`（chat + responses）、`_sendClaudeStream`、`_sendGoogleStream`、`_sendOpenAIImagesStream`、`generateText`、`_generateTextViaStream`、AI Team／agent loop 全部走 `_clientFor`。

**測試 seam**：新增 `@visibleForTesting static http.Client debugClientFor(ProviderConfig cfg, {String? sessionId, String? requestId})`，讓測試能斷言回傳型別與 header；或直接對 `ProviderSessionClient` 做單測（見 §5）。

**完成定義**：`flutter test test/core/services/api/opencode_test.dart` 綠燈；非 OpenCode provider 的 client 型別不變。

---

### Phase 2：conversationId 線程貫通（1 人日）

現況：`sendMessageStream(sessionId:)` 與 `generateText(sessionId:)` 都已存在，但呼叫端多數沒傳。逐一補上（以 function 名為主，行號約略）：

| 檔案 | 位置 | 變更 |
|:---|:---|:---|
| `lib/features/home/controllers/chat_actions.dart` | 主送出路徑（約 1284，`useAgentLoop` 三元式） | 兩支都加 `sessionId: conversationId` |
| 同上 | AI Team proposer（約 1613） | 加 `sessionId: conversationId`（`requestId` 維持 `${conversationId}_proposer`，避免 cancel token 衝突） |
| `lib/features/home/services/agent_orchestrator.dart` | `run(...)`（約 181） | 方法簽章加 `String? sessionId`，原樣轉發 `ChatApiService.sendMessageStream` |
| `lib/core/services/chat/chat_turn_service.dart` | `ChatTurnRequest`（約 19） | **新增 `final String? conversationId`**（目前沒有）；`_run` 的 `sendMessageStream` 傳 `sessionId: request.conversationId` |
| `lib/features/home/widgets/side_drawer.dart` | 標題生成（約 820） | `generateText` 加 `sessionId: conversationId`（同 block 已有） |
| `lib/features/home/controllers/home_view_model.dart` | 摘要／標題／摘要更新（約 556／796／907） | 加 `sessionId: convo.id`（三個 block 的 `convo` 都在 scope） |
| `lib/features/home/services/translation_service.dart` | 翻譯（約 127） | `sessionId: message.id`（逐訊息穩定；OpenCode 只需存在） |
| `lib/features/home/services/ocr_service.dart` | OCR（約 74） | 有 message id 就傳，否則省略（Phase 0 的決定性 fallback 會補上） |
| `lib/features/home/services/greeting_service.dart` | 新聊天問候（約 138） | 省略（無對話）；fallback 為 provider 級穩定 id |

**`chat_turn_service` 的呼叫端**：`startTurn(...)` 的所有 caller 需補 `conversationId`（以 `grep -rn "ChatTurnRequest(" lib` 全量盤點；目前主要在建構 turn 的 home 層）。

**注意**：`agent_orchestrator` 的 `requestId` 也被用來當 cancel token key；`sessionId` 是**額外**參數，不要合併。

**完成定義**：在 OpenCode Go provider 上，主對話、工具續輪、AI Team、標題生成、摘要、翻譯都收到**同一個對話內穩定**的 `x-opencode-session`（以 request logger 或 MockClient 驗證）。

---

### Phase 3：Provider 預設與 UI（0.5–1 人日）

#### 3.1 `ProviderConfig`

`lib/core/providers/settings_provider.dart`：

```dart
// _defaultBase：放在 fallback 之前
if (k.contains('opencode')) {
  return RegExp(r'opencode[\s_-]*go').hasMatch(k)
      ? 'https://opencode.ai/zen/go/v1'
      : 'https://opencode.ai/zen/v1';
}
```

- `classify('OpenCode Zen' / 'OpenCode Go')` 已天然落入 `openai`，**不需改**。
- `defaultsFor` 的 `openai` 分支：`chatPath: '/chat/completions'`、`useResponseApi: false`。
- **OpenCode 專屬餘額隔離**：當 `lowerKey.contains('opencode')`，強制 `balanceEnabled: false`、`balanceApiPath: ''`、`balanceResultKey: ''`。不要讓它落入 `/user/info` 預設，避免未來有人打開 balance 開關時打錯端點。**不要**改動其他 provider 的 balance 分支。
- `models` 空陣列（由使用者按「取得模型」）。

#### 3.2 Provider 清單

`lib/features/provider/pages/providers_page.dart` 的 `_providers()`：

```dart
_p('OpenCode Zen', 'OpenCode Zen', enabled: false, models: 0),
_p('OpenCode Go', 'OpenCode Go', enabled: false, models: 0),
```

放在 `OpenRouter` 之後、`Tensdaq` 之前（與其他聚合商相鄰）。這兩個 key 會成為 built-in（不可批次刪除），與現有 preset 行為一致。

#### 3.3 品牌圖示

- `assets/icons/opencode.svg`：使用 OpenCode 官方標誌（專案為開源；加入 `THIRD_PARTY_NOTICES.md` 或確認授權後放入）。
- `lib/utils/brand_assets.dart`：在 mapping 前段加 `MapEntry(RegExp(r'opencode'), 'opencode.svg')`（`OpenCode` 不會誤中 `openai|gpt|o\d`）。
- 若標誌授權暫無法確認：先不加 asset，`_BrandAvatar` 會退回字母頭像；功能不受影響。

#### 3.4 l10n

新增 key（`app_en.arb`／`app_zh.arb`／`app_zh_Hans.arb`／`app_zh_Hant.arb`）：

| Key | en | zh_Hant |
|:---|:---|:---|
| `openCodeProviderHint` | `OpenCode Go requires a session header; OmniChat adds it automatically.` | `OpenCode Go 需要工作階段標頭，OmniChat 會自動帶上。` |
| `openCodeErrorMissingSession` | `OpenCode rejected the request because the session header was missing. Please update OmniChat.` | `OpenCode 因缺少工作階段標頭而拒絕請求，請更新 OmniChat。` |
| `openCodeErrorFreeTier` | `OpenCode free models only work in the official OpenCode client. Use a paid or Go model.` | `OpenCode 免費模型僅限官方用戶端使用，請改用付費或 Go 模型。` |
| `openCodeErrorInsufficientBalance` | `Your OpenCode balance is insufficient.` | `OpenCode 餘額不足。` |
| `openCodeErrorProtocolUnsupported` | `This model does not support the current API protocol. Try enabling the Responses API.` | `此模型不支援目前的 API 協定，請嘗試啟用 Responses API。` |

成本相關 key 於 Phase 5 追加。

#### 3.5 Provider 詳細頁提示（可選）

`lib/features/provider/pages/provider_detail_page.dart`：當 `isOpenCodeBaseUrl(cfg.baseUrl)` 為真，在 API Base URL 下方顯示 `openCodeProviderHint` 的小字（不阻擋操作）。若時間不足可延後，功能不受影響。

**完成定義**：新安裝可在 Provider 清單看到兩列；點入後 base URL 已填好；`balanceEnabled` 為 false；填 key → 取得模型 → 可聊天。

---

### Phase 4：模型清單與能力（1 人日）

1. **模型清單**：`OpenAIProvider.listModels`（`lib/core/providers/model_provider.dart`）已用 `${cfg.baseUrl}/models` + Bearer，對 `/zen/v1/models` 與 `/zen/go/v1/models` 皆正確，**預期零改動**。
   - **已查證（2026-11-05）**：`GET /models` 不需要 `x-opencode-session`；官方文件範例未帶此標頭，且 `https://opencode.ai/zen/v1/models`／`/zen/go/v1/models` 無標頭即回 200。session 檢查只在 inference POST 上。因此**維持現狀，不额外送 header**。
2. **id 正規化**：`ChatApiService._apiModelId(cfg, modelId)` 在回傳前，若 `isOpenCodeBaseUrl(cfg.baseUrl)` 則套 `normalizeOpenCodeModelId(raw)`。同時在 `ModelProvider` 的推斷路徑（`ModelRegistry.inferForProvider` 前）套同一函式，確保 catalog／regex 命中裸 id。
3. **能力推斷**：Phase 6 的 OpenCode 目錄 overlay 會提供 context／modalities／tool_call／reasoning／reasoning_options；models.dev 與 regex 仍是最終回退。
4. **推理檔位**：沿用 `ReasoningCapabilities`；`openai` transport 的 `none/low/medium/high/xhigh/max` 已能表達 Console 的 `reasoning_effort`。對「永遠推理」的模型：
   - 文件標註以 per-model override 設 `thinkingAlwaysOn: true`（UI 隱藏 Off）；
   - 或由使用者用 `reasoningWire` 指定方言。
5. **`/responses` 切換**：provider 層 `useResponseApi` 可直接開；Console 對所有付費／Go 模型都支援 Responses。預設關閉（chat completions 相容面最廣）。

**完成定義**：`OpenCode Go` 按「取得模型」列出清單；選 `opencode/...` 或 `opencode-go/...` 也能正確送出裸 id；切換 Responses 可正常串流。

---

### Phase 5：成本遙測與顯示（1.5–2 人日）

#### 5.1 模型層

`MessageUsage` 已在 Phase 0 建立，本階段不重複定義。

**修改** `lib/core/models/token_usage.dart`：

```dart
final double? costUsd;
final double? listCostUsd;
final double? allowanceUsd;
final String? billingSource;
final bool estimated;

TokenUsage merge(TokenUsage other);      // token 維持原 max 語義；成本取 other ?? 現值（快照）
TokenUsage accumulate(TokenUsage other); // token 用 merge；成本 sum（只用於多輪工具聚合）
MessageUsage? toMessageUsage();          // 無 opencode 成本 → null
```

- `merge` 的成本規則是「後到的非 null 快照覆蓋」，對應串流最後一個 usage chunk。
- `accumulate` 只用在 `aggUsage`／`totalUsage` 的**跨輪**聚合（Chat Completions tool loop、Responses、Claude、Gemini），避免多輪成本被 max 吃掉。
- Token 行為必須與現況 byte-identical；新增測試釘住。

**修改** `lib/core/models/chat_message.dart`：

- 新增 `@HiveField(22) final String? usageMetaJson;`（nullable；舊資料讀到 null）。
- `MessageUsage? get usageMeta => MessageUsage.tryParse(usageMetaJson);`
- `copyWith`／`toJson`／`fromJson` 同步；`toJson` 用 `'usageMeta': usageMeta?.toJson()`（備份可讀），`fromJson` 解析後存回 `usageMetaJson`。
- **`copyWith` 的 nullable 清除語義**：`usageMetaJson` 用 `??` 會無法把舊值清成 null；需要 sentinel（比照 `ProviderConfig` 的 `_sentinel`）或 `clearUsageMeta` flag。版本複製／重新生成要用 dedicated rebuild 清掉成本。
- 重新產生 `chat_message.g.dart`（`dart run build_runner build --delete-conflicting-outputs`）；Hive 只在 legacy 路徑使用，新增 nullable 欄位對舊資料安全。

#### 5.2 Transport 解析

在 `lib/core/services/api/chat_api_service.dart` 集中一個 helper，避免 6+ 個重複區塊漏改：

```dart
TokenUsage? _openAIUsage(Map? u) {
  if (u == null) return null;
  final usage = TokenUsage(
    promptTokens: (u['prompt_tokens'] ?? u['input_tokens'] ?? 0) as int,
    completionTokens: (u['completion_tokens'] ?? u['output_tokens'] ?? 0) as int,
    cachedTokens: (u['prompt_tokens_details']?['cached_tokens'] ?? 0) as int,
  );
  return applyOpenCodeUsage(usage, u); // opencode_cost.dart；無 opencode 區塊則原樣返回
}
```

> Chat Completions 的 `stream_options: {include_usage: true}` 已由現有 `_sendOpenAIStream` 對「非 OpenRouter／非 Mistral」host 送出；OpenCode host 會收到，因此串流末端一定有 `usage`。不需額外修改。

套用點：

| Path | 位置／容器 |
|:---|:---|
| Chat Completions | `obj['usage'] ?? obj['response']?['usage']`；串流最後一個 object 的 `usage`（約 3594、3662、4186、5377、5649、6232） |
| Responses | `json['response']?['usage']`（約 4597、4978） |
| Claude | `obj['usage'] ?? obj['message']?['usage']`（約 7847） |
| Gemini | `usageMetadata`（約 8907） |
| Images | `response['usage']`（約 10232） |

- `applyOpenCodeUsage` 只讀 `usage['opencode']`；沒有這個 key 就回傳原 `TokenUsage`。**不要**讀 generic `usage.cost`，避免其他 provider 受影響。
- `opencode.tokens` 放進 `MessageUsage` 的 input/output/reasoning/cache 欄位；`TokenUsage` 仍用原本的 prompt/completion/cached。
- 多輪聚合點改呼叫 `accumulate`；單輪串流事件仍用 `merge`。

#### 5.3 持久化（不新增 SQLite schema）

**新增常數** `kOpenCodeUsageKind = 'opencode_usage_v1'`（放 `message_part_codec.dart` 或新 `usage_artifact.dart`）。

**`ChatStorage` 介面**（`lib/core/services/chat/storage/chat_storage.dart`）：

```dart
MessageUsage? getOpenCodeUsage(String messageId);
Future<void> setOpenCodeUsage(String messageId, MessageUsage usage);
Future<void> removeOpenCodeUsage(String messageId);
```

**`SqliteChatStorage`**：

- 新增 `Map<String, MessageUsage> _openCodeUsage`。
- `_reloadAll()` 加 `_openCodeUsage.addAll(parse(await _repo.allProviderArtifactsOfKind(kOpenCodeUsageKind)))`（與 `_signatures` 同一個批次載入模式）。
- `_reloadMessages` 需同步移除舊訊息 id 的 `_openCodeUsage` 條目，避免刪除／切換對話後殘留。
- `getMessages`／`_reloadMessages` 在回傳或快取 `ChatMessage` 時 `copyWith(usageMetaJson: ...)`。
- `updateMessage(..., MessageUsage? usageMeta)`：非 null 時 `_repo.setProviderArtifact(messageId, kOpenCodeUsageKind, jsonEncode(usageMeta.toJson()))`，並更新 `_openCodeUsage` 與快取 `ChatMessage`。
- 版本複製（`totalTokens: null` 的路徑）同時把 `usageMetaJson: null`，避免新版本沿用舊成本。

**`HiveChatStorage`（legacy）**：

- 用同一個 `_toolEventsBox` 的 key prefix（例：`usage:<messageId>`）存 JSON；`getOpenCodeUsage` 讀取解析。若不想擴充 legacy，可實作 no-op（回 null），但要在註解明說「legacy 不含成本」。

**`chat_actions` 接線**：

- `state.usage` 已聚合 `TokenUsage`。
- 在三個完成點（約 2185、2378、2516）把 `state.usage?.toMessageUsage()` 傳給 `updateMessage(..., usageMeta: ...)`；串流中的 chunk 更新不傳，避免每個 chunk 寫 artifact。
- `ChatMessage.copyWith` 同步 `usageMetaJson`。

#### 5.4 備份與還原（不改 payload key）

- `ChatMessage.toJson` 已包含 `usageMeta`；`data_sync.dart` 的匯出確認使用 `m.toJson()`（約 705），因此串流備份會自動帶上。
- `ChatBackupRestorer` 在插入每則訊息後，若 `message.usageMeta != null`，呼叫 `repository.setProviderArtifact(message.id, kOpenCodeUsageKind, jsonEncode(...))`。
- `data_sync` 的兩條還原路徑（約 1199／1261 的 iterate 點所在流程）比照辦理；以 `grep -n "setProviderArtifact" lib/core/services/backup/data_sync.dart` 盤點實際插入點。
- **`verifyCounts` 修正**：新增 `ChatRepository.countProviderArtifactsOfKind(kind)`；把 `actual.providerArtifacts != payload.signatureCount` 改成 `await repository.countProviderArtifactsOfKind(kGeminiThoughtSignatureKind) != payload.signatureCount`。這樣成本 artifact 不會讓備份驗證失敗，其他 artifact kind 也不會。
- `LegacyReimportService` 若也有「total provider artifacts」比對，改為 signature kind 專用（以 `grep -n "providerArtifacts" lib/core/services/chat/storage/legacy_reimport_service.dart` 確認）。
- 舊備份沒有 `usageMeta` → `null`，照常還原；新備份被舊版 App 讀取時，未知的 `usageMeta` key 會被忽略。

#### 5.5 UI

**`lib/features/chat/widgets/chat_message_widget.dart`**：

- `buildMessageStatsText` 保持現有 `tokens · 字` 主體；若 `message.usageMeta != null`，追加 `buildUsageSummary` 的結果。
- 兩個 call site（約 859、1978）的 `Text` 包一層 `GestureDetector`，點擊開啟用量明細 sheet；`Tooltip` 顯示完整摘要（桌面 hover／行動長按）。
- `buildUsageSummary` 規則見 §2.6，放在 `lib/features/chat/widgets/message_stats_text.dart`（純函式）；`formatUsd` 放 `lib/utils/usd_format.dart`。實際渲染由 `MessageStatsLine` 負責。

**新增** `lib/features/chat/widgets/message_usage_sheet.dart`：

- 標題「用量與成本」。
- tokens 區：input／output／reasoning／cache read／cache write 5m／1h。
- 成本區：`cost`／`list_cost`／`allowance`／`billing_source`／`estimated`；Go 顯示「配額」與「定價」兩列。
- 只在 `usage != null` 時可開啟；`showTokenStats == false` 時仍可從 `MessageMoreSheet` 的「用量」入口開啟（已實作）。

**l10n**（Phase 5 追加）：

| Key | en | zh_Hant |
|:---|:---|:---|
| `messageUsageTitle` | `Usage & cost` | `用量與成本` |
| `messageUsageFree` | `Free` | `免費` |
| `messageUsageAllowance` | `Go allowance` | `Go 配額` |
| `messageUsageListCost` | `List price` | `定價` |
| `messageUsageCost` | `Charged` | `實際扣款` |
| `messageUsageEstimated` | `Estimated` | `估算` |
| `messageUsageBillingSource` | `Billing` | `計費方式` |

#### 5.6 餘額隔離（硬性驗收）

- **不修改** `ProviderManager.getBalance`、`OpenAIProvider.getBalance`、`ProviderBalanceText`。
- OpenCode preset 的 `balanceEnabled == false`；`ProviderBalanceText` 因 `cfg.balanceEnabled != true` 直接 `SizedBox.shrink()`。
- 新增測試：
  - `ProviderConfig.defaultsFor('OpenCode Zen'/'OpenCode Go').balanceEnabled == false`。
  - `ProviderManager.getBalance(openCodeCfg)` 回 `''`（且不發 HTTP）。
  - `MessageStatsLine` 對沒有 `usageMeta` 的訊息輸出與現況完全相同（含 estimated token 路徑）。

**完成定義**：OpenCode 的 balance／free／Go／BYOK 四種回應都能在訊息統計列看到正確成本摘要；重啟後成本仍在；備份還原後成本仍在；其他 provider 的訊息與餘額畫面零變化。

---

### Phase 6：OpenCode 模型目錄同步（1.5–2 人日）

#### 6.1 資料來源與產物

- 來源：`https://models.opencode.ai/api.json`（models.dev v1，provider-keyed map）。
- 只保留 OpenCode 相關 provider（`opencode`、`opencode-go`；以實際檔案為準），避免把 2 MB 全目錄塞進 overlay。
- **overlay 保證有 `opencode` 條目**：若來源只有 `opencode-go`，建置工具產生 `opencode` 別名（相同 models），確保 host 規則命中 overlay 而不是 models.dev 的舊 `opencode`。
- prune 規則沿用 `pruneCatalogJson`（只保留 `limit`／`modalities`／`tool_call`／`reasoning`／`temperature`／`interleaved`／`reasoning_options`／`canonical_model_id` 與 provider `api`）；`cost`／`status` 不進 runtime catalog，若未來要做成本估算或 deprecated UI 再擴充 prune。
- Bundled snapshot：`assets/model_catalog/opencode.json`（由建置工具產生；首次啟動／離線可用）。
- Cache：`opencode_catalog_v1.json`；prefs：`opencode_catalog_fetched_at_v1`、`opencode_catalog_etag_v1`（裝置私有，不進備份；比照 `model_catalog_*` 加入 `SettingsProvider._localOnlyKeys`）。
- 建置工具：擴充 `tool/build_model_catalog.dart` 或新增 `tool/build_opencode_catalog.dart`，重用 `pruneCatalogJson` 的 prune 規則，加一個 provider allowlist。輸出 `NOTICE.md` 需註明來源與授權。

#### 6.2 `OpenCodeCatalogService`

> 實作備註（2026-11-05）：overlay 職責已併入 `ModelCatalogService`，未新增獨立 service；常數、載入、cache／ETag、refresh 與 merge 都在同一處完成，`main.dart` 仍只有一個 `ensureLoaded()` 呼叫。以下保留原設計供對照。

**新增** `lib/core/services/model_catalog/opencode_catalog_service.dart`：

```dart
class OpenCodeCatalogService {
  static final instance = OpenCodeCatalogService();
  static const sourceUrl = 'https://models.opencode.ai/api.json';
  static const snapshotAsset = 'assets/model_catalog/opencode.json';
  static const cacheFileName = 'opencode_catalog_v1.json';
  static const fetchedAtPrefsKey = 'opencode_catalog_fetched_at_v1';
  static const etagPrefsKey = 'opencode_catalog_etag_v1';

  Future<void> ensureLoaded();              // memory → cache → asset
  String? get overlayJson;                  // pruned provider map
  Future<void> refreshIfStale({int days = 1, http.Client? client});
  Future<void> refresh({http.Client? client});

  @visibleForTesting
  void debugReset(); // 清 overlay + loaded 狀態；測試用
}
```

- 載入順序與 `ModelCatalogService` 相同；失敗靜默保留 snapshot。
- ETag／304、15 秒 timeout、single-flight、原子寫入（temp → rename）。
- 成功後呼叫 `ModelCatalogService.instance.setOverlayJson(overlayJson)`，觸發 rebuild。
- `ModelCatalogService.debugReset()` 同時清 `_overlayJson`；測試與診斷用。

#### 6.3 合併與優先序

**修改** `lib/core/services/model_catalog/model_catalog.dart`，新增純函式：

```dart
/// overlay 的 provider/model 覆蓋 base；base 獨有的 model 保留。
String mergeCatalogJson(String baseJson, String overlayJson) { ... }
```

- 合併粒度：provider 物件 merge，`models` map 再 merge；同名 model 由 overlay 整筆覆蓋（不是逐欄 merge，避免半新半舊）。
- `ModelCatalog.fromJsonString(mergeCatalogJson(base, overlay))` 即可得到「OpenCode 優先」的單一 catalog；所有 lookup 呼叫端零改動。
- `resolveCatalogProviderId` 加明確規則：`host == 'opencode.ai'` → `opencode`（若 overlay 有 `opencode-go` 才回退）。避免依賴 provider 排序。

**修改** `ModelCatalogService`：

- 保留 `_baseJson`（pruned base）與 `_overlayJson`。
- `setOverlayJson(String? json)`：更新 overlay 並 rebuild（`_parseMergedCatalog` 在 isolate）。
- `_installParsed` 改為 `parse(merge(base, overlay))`；沒有 overlay 時行為與現在完全相同。
- `refresh()` 完成後 rebuild（overlay 不變）。
- `ensureLoaded()` 先載 base，再套 overlay；若 overlay 尚未載入，先以 base 提供服務（不阻塞啟動超過 3 秒）。

#### 6.4 啟動與刷新觸發

**`main.dart` 啟動順序**（不增加啟動網路呼叫）：

> 實作備註：overlay 已併入 `ModelCatalogService.ensureLoaded()`，因此啟動端仍只有一個 3 秒 timeout 的呼叫；base 與 overlay 的 cache／snapshot 載入完成後才 merge + parse，不會出現半套 catalog。

```dart
// 實作版本：單一入口，內部載入 base + overlay。
await ModelCatalogService.instance.ensureLoaded().timeout(
  const Duration(seconds: 3),
  onTimeout: () {},
);
```

（原設計的並行載入／`setOverlayJson` 不再需要。）

- 新增／編輯 OpenCode provider、抓取模型清單、`refreshCatalogForModel` 對 OpenCode 模型 miss 時：
  - `OpenCodeCatalogService.refreshIfStale(days: 1)`（OpenCode 目錄變動比 models.dev 快）。
  - 若 OpenCode overlay 仍 miss，再 `ModelCatalogService.refreshIfStale(days: 30)` 補 models.dev。
- `ProviderManager.refreshCatalogIfStale`／`refreshCatalogForModel` 加 `isOpenCodeBaseUrl(cfg.baseUrl)` 分支；其他 provider 完全不變。
- 刷新失敗不影響現有 catalog；不顯示錯誤（與 models.dev 現行行為一致）。

#### 6.5 能力映射

- `limit.context`／`limit.input`／`limit.output` → `CatalogModel.context`／`input`／`output`（既有 parser 已支援）。
- `modalities.input/output` → image／video 判定；`tool_call`／`reasoning`／`temperature` → 能力旗標。
- `reasoning_options`：`effort.values` → `CatalogModel.efforts`；`toggle` → `hasToggle`；`budget_tokens` → min/max。
- `interleaved.field` → `interleavedField`（`reasoning_content` 回放）。
- `status`：`deprecated` 目前不影響 lookup；若要標記／隱藏，沿用 `ModelInfo` 既有規則，否則列 v2（本版不新增 deprecated UI）。
- `cost.*`：暫不寫入 `ModelInfo`；成本顯示以 `usage.opencode` 為準。若後續要做「預估成本」，再用這份定價。

#### 6.6 測試

- `mergeCatalogJson`：overlay 同名 model 覆蓋；base 獨有 model 保留；provider 的其他欄位不丟。
- `ModelCatalog.lookup(providerId: 'opencode', modelId: 'glm-5.3')` 回 overlay 的 context。
- `resolveCatalogProviderId(host: 'opencode.ai') == 'opencode'`。
- `OpenCodeCatalogService`：cache → asset 載入、ETag 304、refresh 失敗保留舊資料、cache 損壞回 snapshot。
- `ProviderManager.refreshCatalogForModel` 對 OpenCode 先刷 overlay、再刷 base（以 fetcher 計數驗證）。
- 既有 `test/core/model_catalog_test.dart`、`model_catalog_service_test.dart` 全部維持綠燈（沒有 overlay 時行為不變）。

**完成定義**：OpenCode provider 的模型能力（context／vision／reasoning／efforts）來自 OpenCode 目錄；同一模型在 models.dev 的舊資料被覆蓋；其他 provider 的目錄結果不變；離線首次啟動仍有 bundled snapshot。

---

### Phase 7：錯誤 UX 與日誌去識別（0.5–1 人日）

1. **錯誤分類 helper**：新增 `lib/core/services/api/opencode_errors.dart`（純函式）：

```dart
enum OpenCodeErrorKind { missingSession, freeTier, insufficientBalance, protocolUnsupported, none }

OpenCodeErrorKind classifyOpenCodeError(Object error) {
  final text = error.toString().toLowerCase();
  if (text.contains('missingsessionid') || text.contains('x-opencode-session')) return ...;
  if (text.contains('freetiererror') || text.contains('free tier')) return ...;
  if (text.contains('insufficient') || text.contains('"status":402')) return ...;
  if (text.contains('modelprotocolunsupported')) return ...;
  return OpenCodeErrorKind.none;
}
```

2. **接線**：`chat_actions._handleStreamError` 在 `errorText = e.toString()` 前插入：

```dart
final openCodeKind = isOpenCodeBaseUrl(state.ctx.config.baseUrl)
    ? classifyOpenCodeError(e)
    : OpenCodeErrorKind.none;
final errorText = oauthLoginRequired
    ? oauthNotice
    : openCodeKind != OpenCodeErrorKind.none
        ? _openCodeNotice(l10n, openCodeKind)
        : e.toString();
```

原始錯誤仍寫入 `FlutterLogger`／wire log，不丟失。

3. **日誌遮罩**：`RequestLogger.redactHeaders` 的 `sensitive` 集合加入 `'x-opencode-session'`。`oauthSensitiveBody` 不需要改（OpenCode 非 OAuth，body 不該被過度遮罩）。

4. **Provider 頁提示**：`openCodeProviderHint`（Phase 3 §3.5）；若模型 id 屬於已知免費清單（`big-pickle`、`beam-free` 等）且 provider 是 OpenCode，顯示「免費模型僅限官方用戶端」的提示。清單以常數維護，避免硬編碼到 UI。

5. **User-Agent（選項）**：本版先送 `x-opencode-client: omnichat`。若要更貼近官方 Go 文件「用自己的 UA」的建議，可在同一個 client wrapper 加 `User-Agent: OmniChat/<version>`；版本號需新增一個啟動時填入的靜態值（`PackageInfo` 已在專案中使用），沒有版本時送 `OmniChat` 即可。**不得**偽造 `OpenCode/...`。

**完成定義**：用無效 key／免費模型／缺 header 三種情境實測，訊息皆為在地化可行動文案；日誌中看不到 session 值。

---

### Phase 8：文件、測試與驗收（0.5–1 人日）

**狀態（2026-11-05）**：本計畫文件、`OmniChat 專案開發與維護手冊.md`、`THIRD_PARTY_NOTICES.md` 的 Kelivo 註記與下列自動化測試已完成；僅實機驗收仍待。

- `THIRD_PARTY_NOTICES.md`：已補 `Kelivo — OpenCode session headers`，列出改寫檔案、AGPL-3.0 與修改範圍。
- `assets/model_catalog/opencode.NOTICE.md`：已記錄 `models.opencode.ai/api.json` 來源與 models.dev 衍生關係。
- 自動化測試：見 §5；所有列出的測試檔已存在並通過。
- `OmniChat 專案開發與維護手冊.md`：已補 §3.5 §8（OpenCode Zen／Go）、§3.18 `provider_artifacts` 成本側表、§4 決策、§5.3 陷阱、§5.7 local-only keys 與 §7.7 整合紀錄。
- 實機驗收：§6.5 Release Checklist 仍全部未勾選，需真實 OpenCode key。
- 檔名：已改為 `docs/opencode_provider_integration_plan(已實作).md`。

---

## 5. 測試計畫

**狀態（2026-11-05）**：T1–T37 與 §5.5 的成本摘要純函式、`MessageStatsLine` widget、sheet、mobile／desktop menu、餘額 widget 測試已完成；以下檔名已按實際落地位置更新。`ChatMessageWidget` 只保留 `if (showTokenStats)` 的既有轉接行，未另建大型 bubble fixture。

### 5.1 Session／Provider 單元測試

`test/core/services/api/opencode_test.dart`：

| # | 案例 | 期望 |
|:---|:---|:---|
| T1 | `isOpenCodeBaseUrl('https://opencode.ai/zen/v1')` | true |
| T2 | `...opencode.ai.example.com`、`fakeopencode.ai`、`https://openrouter.ai/api/v1` | false |
| T3 | `resolveOpenCodeSessionId` 有 conversationId | 原值（trim） |
| T4 | 無任何 id | 兩次呼叫回**相同**的決定性 uuid（非隨機） |
| T5 | `providerSessionHeaders`（OpenCode、非 OAuth） | 含 `x-opencode-session`、`x-opencode-client: omnichat` |
| T6 | 同上但 `oauthProvider != null` | 只回 OAuth 標頭（行為不變） |
| T7 | `normalizeOpenCodeModelId('opencode/glm-5.3')`／`'opencode-go/kimi-k3'` | → `glm-5.3`／`kimi-k3`；裸 id 不變 |

`test/core/services/api/provider_session_client_test.dart`：

| # | 案例 | 期望 |
|:---|:---|:---|
| T8 | 空 request 經 `ProviderSessionClient` | header 被加入 |
| T9 | request 已有 `X-OpenCode-Session: manual`（大小寫不同） | 保留 `manual`（`putIfAbsent` 大小寫不敏感） |
| T10 | `close()` | 內層 client 被關閉 |

### 5.2 成本解析與模型測試

`test/core/message_usage_test.dart`：

| # | 案例 | 期望 |
|:---|:---|:---|
| T11 | Go 形狀（`cost: 0`、`allowance`、`list_cost`、`billing_source: go`） | `MessageUsage` 全欄位正確；`isEmpty == false` |
| T12 | balance 形狀（`cost: 0.00412`） | `costUsd == 0.00412`；`allowanceUsd == null` |
| T13 | free 形狀（`cost: 0`、`billing_source: free`） | `costUsd == 0`；摘要為「免費」 |
| T14 | byok + `estimated: true` | `estimated == true`；摘要加 `≈` |
| T15 | 沒有 `opencode` 區塊 | `null`（其他 provider 零影響） |
| T16 | `opencode.tokens` 的 reasoning／cache 欄位 | 映射到 `MessageUsage` |

`test/core/message_usage_test.dart`（TokenUsage group）：

| # | 案例 | 期望 |
|:---|:---|:---|
| T17 | 無成本欄位的 `merge` | 與現況完全相同（回歸） |
| T18 | 同一請求兩次快照（先 null、後 cost） | 後者覆蓋，成本不累加 |
| T19 | `accumulate` 兩輪成本 | 成本相加；tokens 仍用 max |
| T20 | `toMessageUsage` 無 opencode | null |

### 5.3 持久化與備份測試

`test/core/chat_storage/opencode_usage_storage_test.dart`：

| # | 案例 | 期望 |
|:---|:---|:---|
| T21 | `setOpenCodeUsage` → 重新載入 conversation | `ChatMessage.usageMeta` 還原 |
| T22 | 刪除訊息 | artifact 隨 FK cascade 消失 |
| T23 | 版本複製 | 新版本 `usageMeta == null` |
| T24 | `ChatMessage.toJson/fromJson` | `usageMeta` round-trip |

`test/core/chat_storage/chat_backup_restorer_test.dart`、`test/data_sync_streaming_backup_test.dart`：

| # | 案例 | 期望 |
|:---|:---|:---|
| T25 | 含成本訊息的備份 → 還原 | 成本 artifacts 還原 |
| T26 | 舊備份（無 usageMeta） | 照常還原，成本為 null |
| T27 | `verifyCounts` 在 DB 有成本 artifacts 時 | 只比對 signature kind，不誤報 |
| T28 | `DataSync` 匯出／匯入 | 成本隨訊息 JSON 往返 |

### 5.4 目錄測試

`test/core/opencode_catalog_test.dart`：

| # | 案例 | 期望 |
|:---|:---|:---|
| T29 | `mergeCatalogJson` 同名 model | overlay 覆蓋（context 1000000 > base 200000） |
| T30 | base 獨有 provider/model | 保留 |
| T31 | `resolveCatalogProviderId(host: 'opencode.ai')` | `opencode` |
| T32 | overlay 載入後 `lookup(providerId: 'opencode')` | 回 OpenCode 能力（reasoning efforts） |
| T33 | 無 overlay | 與現有 models.dev 行為完全相同 |

`test/core/model_catalog_service_test.dart`：

| # | 案例 | 期望 |
|:---|:---|:---|
| T34 | memory → cache → asset 載入順序 | 正確 |
| T35 | 304 | 更新 fetchedAt、不重建 |
| T36 | refresh 失敗 | 保留舊 overlay |
| T37 | cache 損壞 | 回 bundled snapshot |

### 5.5 UI／餘額回歸

`test/features/chat/message_stats_text_test.dart`、`test/features/chat/message_stats_line_test.dart`、`test/features/chat/message_usage_sheet_test.dart`、`test/features/chat/message_more_sheet_usage_test.dart`（widget／pure builder）：

- 有 `usageMeta` 的訊息顯示成本摘要；無 `usageMeta` 的訊息輸出與現況相同。
- Go 顯示「配額」；balance 顯示金額；free 顯示「免費」。
- `showTokenStats == false` 時不顯示統計列（維持現狀）。

`test/opencode_provider_preset_test.dart`、`test/opencode_balance_isolation_test.dart`（餘額隔離）：

- `ProviderConfig.defaultsFor('OpenCode Zen'/'OpenCode Go').balanceEnabled == false`。
- `ProviderManager.getBalance` 回 `''` 且不發 HTTP。
- `ProviderBalanceText` 對 OpenCode config 回 `SizedBox.shrink()`。

### 5.6 指令

```bash
flutter analyze
flutter test test/core/services/api/opencode_test.dart
flutter test test/core/services/api/provider_session_client_test.dart
flutter test test/core/message_usage_test.dart
flutter test test/core/chat_storage/opencode_usage_storage_test.dart
flutter test test/core/chat_storage/chat_backup_restorer_test.dart
flutter test test/data_sync_streaming_backup_test.dart
flutter test test/features/chat
flutter test test/core/opencode_catalog_test.dart
flutter test test/core/model_catalog_service_test.dart
flutter test test/opencode_provider_preset_test.dart
flutter test test/opencode_balance_isolation_test.dart
flutter test test/request_logger_oauth_redaction_test.dart
```

（全套 `flutter test` 於 Phase 8 收尾執行；Windows／Android 各做一次 smoke。）

---

## 6. 風險、相容性與回滾

| 風險 | 影響 | 緩解 | 回滾 |
|:---|:---|:---|:---|
| OpenCode 無預警改 session 契約 | 400 全模型失敗 | 契約集中在 `opencode.dart` + T5/T11 測試；錯誤訊息指向「更新 OmniChat」 | 移除 `_clientFor` 的 wrapper（單行） |
| 精確 host 判定讓自架 relay 收不到 header | relay 400 | 文件說明可用自訂 header；或把 relay host 加入 allowlist（本版不做） | 使用者以自訂 header 覆蓋（D5） |
| 成本重複計算（多輪工具） | 顯示金額偏高 | `merge`（快照）與 `accumulate`（跨輪）分離；T18/T19 釘住 | 只顯示 `costUsd`，停用 allowance 合併 |
| Go 的 `cost` 為 0 被誤顯示為免費 | 使用者誤判 | 顯示規則以 `billing_source` 優先；T11 | 純 UI 規則，可獨立回退 |
| 成本 artifact 讓備份驗證失敗 | restore 失敗 | `verifyCounts` 改按 kind 計數；T27 | 成本不進備份（仍保留本機顯示） |
| 新增 `ChatMessage` Hive 欄位 | 舊 Hive 資料讀取失敗 | nullable 欄位 + 重新 codegen；舊資料讀到 null | 移除欄位（Hive legacy 不影響 SQLite） |
| OpenCode 目錄檔案過大／刷新失敗 | 啟動變慢或無新資料 | 只保留 OpenCode provider 的 prune snapshot；15 秒 timeout；失敗保留舊資料 | 停用 overlay，回 models.dev |
| overlay 覆蓋造成其他 provider 能力改變 | 回歸 | merge 只覆蓋 OpenCode provider 的同名 model；T30/T33 | `setOverlayJson(null)` 即回原狀 |
| 免費模型 403 被誤認為 key 失效 | 使用者重設 key 無效 | Phase 7 專屬提示 | 純文案，可獨立回退 |
| session id 進日誌 | 對話關聯外洩 | `redactHeaders` 遮罩 | 單行移除 |
| `opencode/` 前綴模型 id 被直接送出 | 404／400 | `normalizeOpenCodeModelId` + T7 | 純函式，可停用 |
| 非預期影響其他 provider 的餘額 | 餘額消失或誤呼叫 | 不改 balance 邏輯；preset `balanceEnabled: false`；T 餘額測試 | 移除 OpenCode balance 隔離條件 |

**相容性**：
- `providerSessionHeaders` 的 OAuth 分支不動；`sendMessageStream` 只新增可選參數傳遞，不改簽章語義。
- 備份格式沒有新 payload key；`usageMeta` 是 `ChatMessage` JSON 的可選欄位，舊備份缺少時為 null。
- SQLite schema 維持 v1；成本走 `provider_artifacts`，不觸發 installation gate。
- 其他 provider 的 `TokenUsage` 成本欄位為 null，`MessageStatsLine` 與 balance UI 行為不變。

---

## 7. 驗收清單（Release Checklist）

前置：以真實 OpenCode key 各一組（Zen 按量、Go 訂閱）。

### Session／Provider

- [ ] `curl` 直連驗證：`/zen/v1/chat/completions` 帶 `x-opencode-session` 回 200；刻意移除標頭，Go 回 400 `MissingSessionID`。
- [ ] App 內新增 `OpenCode Go` → base URL 自動填入 → 貼 key → 「取得模型」列出清單。
- [ ] 單輪聊天：正常串流；request log 可見 `x-opencode-session`（遮罩後為 `***`）。
- [ ] 多輪工具呼叫：同一對話所有請求的 session 值一致。
- [ ] 網路斷線重試：retry 請求的 session 值不變。
- [ ] 標題自動生成、對話摘要、翻譯、OCR 各一次：不因缺標頭而 400。
- [ ] AI Team（提案＋彙整）：不因 `_proposer` 後綴而分裂 session。
- [ ] `useResponseApi` 開啟：`/responses` 正常。

### 成本

- [ ] Zen／balance 模型：統計列顯示實際扣款（`cost`），明細 sheet 顯示 `list_cost`。
- [ ] Go 模型：統計列顯示「配額」（`allowance`），明細顯示 `list_cost` 與 `cost: $0`；**不得**顯示「免費」。
- [ ] 免費模型：顯示「免費」。
- [ ] BYOK（若有）：`estimated` 時顯示 `≈`。
- [ ] 重啟 App：成本仍在。
- [ ] 備份 → 還原：成本仍在，`verifyCounts` 不報錯。
- [ ] 其他 provider（OpenAI／OpenRouter／Claude）：訊息統計列與現況完全相同；沒有 `usage.opencode` 時不顯示成本。

### 餘額隔離

- [ ] OpenCode provider 詳細頁沒有「餘額」列（`balanceEnabled == false`）。
- [ ] 其他 provider 的餘額顯示與現況完全相同。
- [ ] `flutter analyze` 0 error；目標測試全綠；全套 `flutter test` 無新失敗。

### 目錄

- [ ] OpenCode provider 的模型 context／vision／reasoning／efforts 來自 `models.opencode.ai`（與 models.dev 不同的模型可驗證）。
- [ ] 同一模型在 models.dev 的舊值被 OpenCode 目錄覆蓋。
- [ ] 其他 provider 的能力不變。
- [ ] 離線首次啟動：仍有 bundled `opencode.json` 可用。
- [ ] 網路失敗：保留舊目錄，不阻塞聊天。

### 平台

- [ ] Windows x64 與 Android arm64-v8a 各完成一次 smoke（本專案發佈平台）。

---

## 8. 工作量估算

| Phase | 內容 | 人日 |
|:---|:---|:---:|
| 0 | 純函式／session／成本 parser／merge 契約 | 0.5 |
| 1 | `ProviderSessionClient` + `_clientFor` | 1.0 |
| 2 | 8 個呼叫點 + `ChatTurnRequest` 欄位 | 1.0 |
| 3 | preset／`_defaultBase`／清單／l10n／icon／balance 隔離 | 0.5–1.0 |
| 4 | 模型清單／id 正規化／能力 | 1.0 |
| 5 | 成本解析／`TokenUsage`／artifact 持久化／備份／UI／測試 | 1.5–2.0 |
| 6 | OpenCode 目錄 service／merge／build tool／刷新／測試 | 1.5–2.0 |
| 7 | 錯誤分類／提示／日誌遮罩 | 0.5–1.0 |
| 8 | 文件／全套測試／smoke | 0.5–1.0 |
| **合計** |  | **8.0–10.5** |

單人約 2 週；Phase 5 與 Phase 6 可平行（都依賴 Phase 0 的純函式與 Phase 3 的 preset），Phase 7 可在 Phase 1 後獨立進行。

---

## 9. 後續選項（Out of Scope／v2）

1. **對話級成本彙總**：把 `MessageUsage` 加總到 conversation summary／stats page（需要 `ChatStorage` 的批次查詢與 UI）。
2. **成本預估**：用 OpenCode 目錄的 `cost.*` 對沒有 `usage.opencode` 的歷史訊息做估算（標示 `≈`），或補齊備份缺失的成本。
3. **OpenCode Console 帳號登入**（OAuth／device code）與餘額 API：目前僅 API Key；若 Console 推出公開 OAuth，可比照 §3.19 的 adapter 模式。
4. **Per-provider `modelsPath` 覆寫**：應對未來 `/zen` 別名下架或自架 relay 的 `/models` 路徑差異。
5. **OpenCode 本機 Server**：`opencode serve`（OpenAPI 3.1、`/session`、`/event` SSE、`x-opencode-directory`）是完全不同的整合面，若要做「本機 coding agent」再另立計畫。
6. **Prompt cache 觀測**：Console 以 session 做 cache 前綴；可在 request log 顯示 `cache_read` token 比例，驗證 session 穩定性帶來的實際效益。
7. **成本匯出**：把 `MessageUsage` 寫進 CSV／Markdown 匯出與 stats 報表。

---

## 10. 參考資料

- OpenCode Console 模型與定價：<https://opencode.ai/v2/docs/console/models/>
- Console Harnesses／Base URL／session header：<https://opencode.ai/v2/docs/console/harnesses>
- Console 推論 API／usage 格式：<https://opencode.ai/v2/docs/console/api/inference/>
- OpenCode Go 限制與用戶端識別：<https://opencode.ai/v2/docs/console/go/>
- OpenCode 模型目錄：<https://models.opencode.ai/api.json>
- models.dev API 參考（`api.json` 欄位）：<https://github.com/anomalyco/models.dev>
- Kelivo 修復 commit：<https://github.com/Chevey339/kelivo/commit/054695a>
- Kelivo issue #987：<https://github.com/Chevey339/kelivo/issues/987>
- Kelivo `provider_request_headers.dart`：<https://github.com/Chevey339/kelivo/blob/master/lib/core/services/api/provider_request_headers.dart>
- Docker Agent 的 OpenCode Zen provider（`/zen/v1` 與 `/zen/go/v1` 實證）：<https://docs.docker.com/ai/docker-agent/providers/opencode-zen/>
- Pi 的 OpenCode Console provider（identity headers 觀察）：<https://pi.dev/packages/pi-provider-opencode-console>
- OpenClaw 的 OpenCode provider（free-tier 403 說明）：<https://docs.openclaw.ai/providers/opencode>
- Go 成本實測（`cost: 0`、`allowance`／`list_cost`）：<https://github.com/farion1231/cc-switch/issues/8791>、<https://github.com/BerriAI/litellm/issues/48937>
