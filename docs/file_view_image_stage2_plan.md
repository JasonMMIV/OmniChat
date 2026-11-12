# file_view_image Stage 2：Vision Plumbing 細部執行計畫

> **版本**：v0.3（2026-11-12）— **已實作**（Phase 0–3 完成；Phase 4 剩真機 matrix）
> **前置**：Stage 1 已完成（commit `11adb10a`）
> **關聯**：`docs/Cowork剩餘項目實作計畫.md` §2.17、`OmniChat 專案開發與維護手冊.md` §3.1
> **範圍**：把工具結果中的 `[image:<abs-path>]` marker，在**送出請求時**升級為各 transport 的原生 vision part，讓模型真正「看得到」圖片。
>
> **實作紀錄（2026-11-12）**：新增 `lib/core/services/api/tool_result_images.dart`（marker／policy／plan）、`tool_image_codec.dart`（decode／resize／re-encode／LRU）、`lib/core/services/file/tool_image_access_ledger.dart`（in-memory 核准路徑）；`ChatApiService` 在每次 L1 請求建 plan，Claude／Responses／Gemini 3 原生編碼，Chat Completions 最後一組 synthetic user；`GenerationContext`／`AgentOrchestrator`／`MessageGenerationService`／`ChatActions` 接線；`sendToolImagesV1` 設定與 l10n；`imageSha256` extras、`SessionOutputs.rootDirectoryForRead()`、context image token 估算。測試：`test/tool_result_images_test.dart`（含 symlink 逃逸／偽造 extras／重複 marker／cap+prune 存活）、`test/tool_result_images_transport_test.dart`（四 transport＋Gemini streaming）、`test/settings_send_tool_images_test.dart`。安全修訂：persisted `imagePath` **不**授予界外路徑（防備份偽造），界外核准只靠 process-local ledger；重啟後需重新核准。
>
> **Stage 3 實作紀錄（2026-11-12）**：新增 `tool_image_send_status.dart`（純 Dart `ToolImageSendState`／`ToolImageSendStatus`／`shouldRetryToolImagesWithoutImages`）。`ToolImagePlan` 現在對每個 marker-bearing tool call 產生狀態（attached／settingOff／modelUnsupported／transportUnsupported／limitReached／notFound／outsideWorkspace／changed／tooLarge／unsupportedFormat／decodeFailed／providerRejected），status-only plan 有 32 筆上限避免長歷史每輪重寫。`ChatStreamChunk.toolImageStatuses` 經 `ChatActions`／`StreamController` 寫入 tool-event extras `imageSend`，再由 `ToolPartSummary`／SQLite／Hive 還原成工具卡 badge；`imageSend` 已列入 `kPreservedToolEventExtraKeys`。Provider 400 在 context-overflow trim 之後做一次「移除圖片重試」，只對 attached 狀態標 `providerRejected`，不消耗 transient retry 預算；`ToolImagePolicy.providerRejectedThisRun` 讓同一 generation 的後續 tool round 不再重打 400（新 user turn 重新嘗試）。工具卡新增靜態 badge（目前模型無 vision／設定關閉）與 runtime badge（實際送出失敗原因），runtime 優先；MCP 截圖的 `imagePath` 也顯示縮圖。l10n ×4、`test/tool_image_send_badge_test.dart`；目標測試 120 案、analyze 0 error/warning。

---

## 0. 摘要

| 項目 | 結論 |
|:--|:--|
| 核心做法 | **Send-time transform**：不改 DB schema、不持久化圖片 bytes；每次送請求時從工具結果文字解析 marker、驗證路徑、讀檔、正規化，再按 transport 編碼 |
| 原生支援 | Claude `tool_result` image block、OpenAI Responses `function_call_output.output` 陣列、Gemini 3 `functionResponse.parts[].inlineData` |
| 不支援 | OpenAI Chat Completions 的 `tool` role 只能放文字；採「最後一組 tool 結果後注入 synthetic user 圖片訊息」的相容策略（可關閉） |
| 能力偵測 | `ModelInfo.input.contains(Modality.image)`；Gemini 另需 Gemini 3 family |
| 安全 | 只允許 workspace／session-outputs／MCP 截圖快取／已核准路徑；symlink 逃逸、magic bytes、大小、數量全部檢查 |
| 失敗策略 | **一律降級回 Stage 1 文字 marker**，圖片問題絕不中斷對話（與 §2.17 原文「不支援模型回明確錯誤」不同，理由見 §4.7） |
| 預估工程量 | 約 7–10 個工程日（含測試與真機驗證），分 5 個 Phase 落地 |

---

## 1. 現況與缺口

### 1.1 Stage 1 已具備

- `FileToolService._viewImage()`（`lib/core/services/file/file_tool_service.dart`）驗證 PNG/JPEG/GIF/WebP/BMP（上限 10 MB），回傳：
  ```
  [image:<abs-path>]
  Format: PNG; Size: 1.2 MB
  ```
  並在 `FileToolResult.viewedImagePath` 帶出同一個絕對路徑。
- `ToolHandlerService` 把 `viewedImagePath` 寫進 tool event extras（`imagePath`，UI-only，已列入 `kPreservedToolEventExtraKeys`）；工具卡渲染縮圖、詳細視窗／底部 sheet 大圖（`chat_message_widget.dart` 的 `_ToolImageThumb`／`_buildToolImagePreview`）。
- MCP 工具（Playwright 截圖）走同一條管線：`McpScreenshotStore.save()` 落盤到 `{appCache}/mcp_screenshots/`，handler 在工具文字尾端追加 `[image:<abs-path>]` marker，extras 寫 `imagePath`。
- **模型端仍是純文字**：`chat_api_service.dart` 的 `[image:]` → vision part 轉換只作用於 `user`／一般 `assistant` 訊息；`role:'tool'` 訊息被刻意原樣保留（見 `_sendOpenAIStream` 的 `hasMultimodalEligibleRole` 與 Claude/Gemini 的 tool 轉換分支）。

### 1.2 缺口

模型知道「這裡有一張圖、路徑是什麼」，但看不到像素。對「寫網站 → 截圖 → 看結果 → 修 UI」的閉環，Stage 1 只完成「人看得到」的一半。

### 1.3 為什麼用 send-time transform

1. marker 已持久化在工具結果文字中，**重播、重新生成、舊對話**都拿得到，不需要新的 DB 欄位或遷移。
2. 圖片 bytes 只在請求週期記憶體中存在，符合專案的 zero-residue／隱私原則；Hive/SQLite 不會膨脹。
3. 各 transport 的 wire shape 差異可以集中在 `ChatApiService` 內處理，不動訊息組裝層（`MessageBuilderService` / `AgentLoop`）的核心契約。
4. 使用者已在 UI 看過同一張圖；Stage 2 只是把同一份內容多送一份給模型。

---

## 2. 協議能力矩陣（2026-11 查證）

| Transport | 工具結果可帶圖？ | 精確形狀 | 主要限制 |
|:--|:--|:--|:--|
| **Anthropic Claude** | ✅ 原生 | `tool_result.content` 可為陣列，內含 `image` block（`source.type = "base64"`） | 5 MB/張、8000×8000 px；>20 張時每張 ≤2000×2000；最多 100 張/請求 |
| **OpenAI Responses** | ✅ 原生 | `function_call_output.output` 可為陣列：`input_text`／`input_image`／`input_file` | `input_image.image_url` 必須是 HTTPS URL 或 base64 **data URL**；模型需支援 vision |
| **Google Gemini 3** | ✅ 原生 | `functionResponse.parts[]` 內含 `inlineData`（`displayName`／`mimeType`／`data`） | 官方文件以 Gemini 3 系列為準；`functionResponse.id` 要回 echo `functionCall.id` |
| **OpenAI Chat Completions** | ❌ 協議不支援 | `ChatCompletionToolMessageParam.content` 只能是 string 或 **text-only** content part 陣列 | `image_url` 只能出現在 `user` 訊息；tool role 不接受圖片 |

### 2.1 Anthropic Claude

`ToolResultBlockParam.content` 的型別包含 `ImageBlockParam`：

```ts
content?: string | Array<
  TextBlockParam |
  ImageBlockParam |
  SearchResultBlockParam |
  DocumentBlockParam
>

ImageBlockParam = {
  type: "image",
  source: {
    type: "base64",
    media_type: "image/jpeg" | "image/png" | "image/gif" | "image/webp",
    data: string
  }
}
```

重點：

- `data` 是**原始 base64**，不是 `data:image/...;base64,` URL。
- `tool_result` 必須在下一個 `user` 訊息、必須是該訊息 content 陣列的**最前面**（不能先放 text），且每個 `tool_use` 都要有對應的 `tool_result`、`tool_use_id` 相符、多個結果維持呼叫順序。
- 圖片 block 可以和 text block 混在同一個 `tool_result.content` 陣列內。
- 標準 vision 限制套用：5 MB/張、8000×8000 px；超過 20 張時每張 ≤2000×2000；最多 100 張/請求。

### 2.2 OpenAI Responses

`FunctionCallOutput.output` 目前允許字串或 content part 陣列：

```ts
{
  type: "function_call_output",
  call_id: string,
  output: string | Array<
    ResponseInputText | ResponseInputImage | ResponseInputFile
  >
}

ResponseInputImage = {
  type: "input_image",
  image_url?: string | null, // HTTPS URL 或 base64 data URL
  file_id?: string | null,
  detail?: "high" | "low" | "auto" | "original" | null
}
```

重點：

- 這是 **content part 陣列**，不是完整的 input item 陣列；不能在 `output` 裡放 `{role:'user', ...}`、另一個 `function_call_output` 或任意 item。
- 圖片用 `type: "input_image"`；Chat Completions 的 `type: "image_url"` 不是 Responses 的 part 型別。
- `image_url` 必須是 HTTPS URL 或 base64 **data URL**，不能是裸 base64。
- 模型仍需支援 image input；能力偵測照舊。

### 2.3 Google Gemini 3

官方 function-calling 文件：可把多模態資料放在 `functionResponse` 內嵌套的 `parts`，每個多模態 part 必須含 `inlineData`；若要在 structured `response` 內引用該 part，part 必須有唯一的 `displayName`。

REST 形狀：

```json
"functionResponse": {
  "name": "file_view_image",
  "id": "<echo functionCall.id>",
  "response": { "result": "Image attached." },
  "parts": [
    {
      "inlineData": {
        "displayName": "screenshot_0.png",
        "mimeType": "image/png",
        "data": "<base64>"
      }
    }
  ]
}
```

重點：

- 文件以 **Gemini 3 系列**為準（`gemini-3-*`）；Gemini 2.x 一律降級為文字 marker。
- `functionResponse.id` 要 echo 對應 `functionCall.id`（Gemini 3 的 manual two-turn flow 要求）。
- `response` 是 JSON object（Protobuf Struct），不能放 bytes；bytes 走 `parts`。
- `displayName` 在同一 `functionResponse` 內必須唯一；我們用 `image_0.<ext>`。
- `inlineData.data` 是 base64 字串。

### 2.4 OpenAI Chat Completions

`ChatCompletionToolMessageParam` 的 content union 只有：

```ts
content: string | ChatCompletionContentPartText[]

ChatCompletionContentPartText = {
  type: "text",
  text: string
}
```

**沒有** `image_url`／`input_image`。`image_url` 只能放在 `user` 訊息的 content part 陣列。

### 2.5 決策：Chat Completions 的相容策略

| 選項 | 優點 | 缺點 |
|:--|:--|:--|
| A. 只送文字 marker | 協議 100% 正確、零風險 | 模型看不到圖，Stage 2 對多數 OpenAI-compatible 使用者無效 |
| **B. 最後一組 tool 訊息後注入 synthetic user 圖片訊息（推薦）** | 模型看得到圖；tool role 維持文字，不違反協議 | 多一則 user 訊息，少數嚴格 provider 可能不適應；需要開關 |

**推薦 B**，理由：

- 只注入**最後一組連續 tool 訊息**（也就是本輪剛執行的工具結果），不在歷史每一組都注入，降低語義干擾與 token 成本。
- 該訊息是 send-time 產物，不持久化、不進 DB，下一輪會重新注入。
- 文案固定為中性指令，例如 `Tool output images (auto-attached for inspection; continue the task):`，避免模型把它當成新的使用者需求。
- 提供全域開關 `sendToolImagesV1`（預設開），provider 不接受時可關閉。

---

## 3. 設計原則

1. **Single source of truth**：持久化的 `[image:…]` marker 是唯一入口；不新增 DB 欄位。
2. **Send-time only**：圖片 bytes 不落盤、不進 Hive/SQLite、不進 log。
3. **Protocol-correct**：每個 transport 用自己的原生形狀；Chat Completions 绝對不把圖片塞進 tool role。
4. **Capability-gated**：`ModelInfo.input.contains(Modality.image)` 才送；Gemini 另需 Gemini 3 family。
5. **Fail-open to Stage 1**：任何圖片問題都降級成文字 marker，讓請求繼續。
6. **Security before convenience**：只讀允許根目錄／已核准路徑；symlink、traversal、magic bytes、大小、數量全部檢查。
7. **Deterministic bytes**：同一張圖每次編碼結果一致（固定品質／尺寸），讓 Claude prompt caching 的 prefix 穩定；必要時加記憶體快取。

---

## 4. 架構

### 4.1 資料流

```
persisted tool result text (contains [image:/abs/path])
        │
        ▼
ToolImagePlan.build(messages, policy, target, canImageInput)
  1. extract markers (regex, local absolute paths only)
  2. validate path: allowed roots / trusted paths / symlink / traversal
  3. read bytes, magic-byte sniff, size cap
  4. decode → downscale → re-encode (package:image)
  5. per-request budget: newest-first, max 8 images
        │
        ▼
transport encoder
  Claude      : tool_result.content = [text, image, image, ...]
  Responses   : function_call_output.output = [input_text, input_image, ...]
  Gemini 3    : functionResponse.parts = [inlineData, ...]
  Chat        : tool message 保持文字；最後一組後注入 synthetic user image message
        │
        ▼
HTTP request
```

### 4.2 新模組

建議拆成兩個檔案，保持「純邏輯」與「影像編碼」分離、可單獨測試：

#### `lib/core/services/api/tool_result_images.dart`（純 Dart，不 import Flutter）

| 型別 | 責任 |
|:--|:--|
| `enum ToolImageTarget { claude, responses, gemini, openAiChat }` | 目標 transport |
| `class ToolImagePolicy` | `workspaceRoot`、額外 allowed roots、trusted paths、`enabled`、每張/每請求上限（**純 Dart，不 import Flutter**） |
| `class ResolvedToolImagePolicy` | 已 canonical 的 `allowedRoots`、trusted paths、limits；由 `ChatApiService` 在送請求前用 `SessionOutputs.rootDirectoryForRead()`／`McpScreenshotStore.directory()`／ledger 建好，再交給純邏輯的 `ToolImagePlan` |
| `class ToolImageMarker` | `path`、`start`、`end`、`raw` |
| `class ToolImagePayload` | `path`、`mime`、`bytes`、`width`、`height`、`displayName` |
| `class ToolImageError` | `code`、`path`、`detail`（穩定錯誤碼，見 §4.7） |
| `class ToolImageResolution` | `cleanText`、`images`、`errors` |
| `class ToolImagePlan` | `Map<int, ToolImageResolution> byMessageIndex`、`totalImages`、`build()` 靜態工廠 |
| `class ToolImageCache` | LRU（key = canonical path + mtimeMs + size + target），上限 24 張 / 32 MB |

`ToolImagePlan.build()` 的行為：

- 只掃 `role == 'tool'` 的訊息；`content` 必須是 String（若是 List 先 `flattenContentBlocksToText`）。
- 用 `RegExp(r'\[image:([^\]\r\n]+)\]')` 抓 marker；跳過 `http://`、`https://`、`data:`（遠端 URL 不在 Stage 2 範圍）。
- **從最新訊息往舊掃**，累計到 `maxImagesPerRequest`（預設 8）為止；較舊的 marker 留在文字裡。
- 同一則工具訊息最多 `maxImagesPerToolMessage`（預設 4）。
- 同一路徑去重。

#### `lib/core/services/api/tool_image_codec.dart`

| 職責 | 說明 |
|:--|:--|
| `normalize(bytes, target)` | magic-byte sniff → `package:image` decode（`bakeOrientation: true`）→ 等比縮放 → JPEG/PNG 編碼 |
| `ToolImageEncoded` | 回傳 `bytes`、`mime`、`width`、`height`（簡單 record/class，可跨 isolate） |
| isolate | 原生平台且 raw > 256 KB 時用 `Isolate.run`；web 同步執行 |
| cache | 先查 `ToolImageCache`；命中直接回傳 |

### 4.3 安全與路徑政策

允許的根目錄（canonical path；由 `ChatApiService` 的 resolver 產生 `ResolvedToolImagePolicy`，純邏輯模組不直接呼叫 Flutter 的 path_provider）：

1. **作用中 workspace**：`WorkspaceResolver.resolve(...).path`（與 file tools 同一個來源）。
2. **Session outputs**：`SessionOutputs.rootDirectoryForRead()` → `{appData}/tool_outputs`（**不建立目錄**；寫入路徑仍用 `rootDirectory()`）。
3. **MCP 截圖快取**：`{appCache}/mcp_screenshots`（由 `McpScreenshotStore` 新增 `directory()` getter 取得）。
4. **已核准路徑（trusted paths）**：
   - **只**來自 process-local `ToolImageAccessLedger`：`file_view_image`／MCP 截圖成功時記錄 `viewedImagePath`／`savedPath`（只有 handler 能寫，tool output 偽造無效）。
   - **不**從 persisted tool-event extras 的 `imagePath` 授予路徑：備份／匯入的對話可以偽造該欄位，若信任它就能把任意本機檔案送給模型。extras 只用於 `imageSha256` snapshot 驗證；界外路徑在 app 重啟後需重新核准。

驗證步驟：

```
raw path
  → trim、拒絕 NUL
  → SessionOutputs.isSessionPath() 走 SessionOutputs.resolveFromRoot()（若適用）
  → p.normalize + File.resolveSymbolicLinksSync()（失敗則視為不存在）
  → 必須位於某個 allowed root 之下（Windows 大小寫不敏感、分隔符統一）
     或 在 in-memory trusted ledger 中（persisted extras 不算）
  → File.stat(): 存在、isFile、size > 0、size <= 12 MB raw
  → magic bytes: PNG / JPEG / GIF / WebP / BMP（其他格式直接失敗）
```

**拒絕**：

- 目錄、空檔、>12 MB、非圖片 magic bytes。
- symlink 指向允許範圍外（用 canonical path 判斷）。
- `..` traversal、NUL、相對路徑。
- 不在任何 allowed root、也不是 trusted path 的檔案。

**隱私**：

- 不把 base64、完整路徑寫進 log；只記 basename + 錯誤碼。
- 重新編碼會丟掉 EXIF（GPS 等 metadata）。
- 圖片 bytes 只存在記憶體與 LRU 快取，不落盤。

### 4.4 圖片正規化

`package:image` 目前是 transitive dependency（4.10.1）。**Stage 2 要在 `pubspec.yaml` 加 direct dependency `image: ^4.10.1`**，避免 `depend_on_referenced_packages` lint，並固定版本。

| Target | 最長邊 | 單張上限 | 編碼 |
|:--|--:|--:|:--|
| Claude | 1568 px | 5 MB | 不透明 → JPEG q90；有 alpha → PNG |
| Responses | 2048 px | 5 MB | 同上 |
| Gemini 3 | 2048 px | 5 MB | 同上 |
| Chat Completions（synthetic user） | 2048 px | 4 MB | 同上 |

流程：

1. 讀 raw bytes（上限 12 MB）。
2. `img.decodeImage(bytes)`；GIF 取第一帧；BMP/WebP 由 `package:image` 解碼。
3. `img.bakeOrientation()` 修正 EXIF 方向。
4. 等比縮放到「最長邊 ≤ target 上限」；**不放大**。
5. 有 alpha → `encodePng`；否則 `encodeJpg(quality: 90)`。
6. 若 encoded > 單張上限：quality 90 → 80 → 70 → 60，再以 0.75 倍逐步縮小（下限 768 px），直到符合或失敗。
7. 回傳 payload；寫入 LRU 快取（key 含 mtime/size，檔案變更會自然 miss）。

注意：

- 不支援 SVG／HEIC／TIFF；遇到就回 `image_unsupported_format`。
- 動畫 GIF 只送第一帧（與多數 vision API 行為一致）。
- 重新編碼是 deterministic 的；同一張圖同一 target 每次 bytes 相同，利於 prompt caching。

### 4.5 與既有管線的接縫

| 檔案／位置 | 變更 |
|:--|:--|
| `lib/core/services/api/chat_api_service.dart` `sendMessageStream` | 新增 optional `ToolImagePolicy? toolImagePolicy`；在 L1 loop 內、每次 attempt 依 `truncatedMessages` 建 `ToolImagePlan`（R0 trim 後自動重算）；目標 transport 由 `_apiKind(config)` + `useResponseApi` 決定 |
| `lib/core/services/agent/agent_orchestrator.dart` `run` / `sendRoundImpl` | 新增 `toolImagePolicy` 參數；主 run 與 revision round 傳入，review round 傳 `null`（review 是純文字） |
| `lib/features/home/controllers/stream_controller.dart` `GenerationContext` | 新增 `final ToolImagePolicy? toolImagePolicy;` |
| `lib/features/home/services/message_generation_service.dart` `prepareGeneration` / `buildGenerationContext` | 把 `workspacePath` 包成 `ToolImagePolicy(workspaceRoot: workspacePath)`，放進 `PreparedGeneration` / `GenerationContext` |
| `lib/features/home/controllers/chat_actions.dart` `_executeGeneration` / `aggCtx` / `_runProposerSilent` | 主 run 與 aggregator 傳 `ctx.toolImagePolicy`；AI Team proposer 預設 `null`（跨模型能力不一致，先用保守值） |
| `lib/features/home/controllers/generation_controller.dart` `buildGenerationContext` | 新增 optional `ToolImagePolicy?`，預設 `null` |
| `lib/core/services/chat/chat_turn_service.dart` | 語音路徑沒有 file tools，policy 傳 `null`；若未來 voice 也要看圖再開 |
| `lib/features/home/services/tool_handler_service.dart` | `file_view_image` 成功後 `ToolImageAccessLedger.allow(result.viewedImagePath!)`；MCP 每個 `savedPath` 也 `allow` |
| `lib/features/home/services/message_builder_service.dart` / `chat_turn_service.dart` `buildApiMessages` | 重播 tool event 時只帶 `pair.event['imageSha256']` 作 snapshot 驗證；**不**帶 `imagePath` 作為信任來源 |
| `lib/core/services/mcp/mcp_screenshot_store.dart` | 新增 `static Future<Directory> directory()`（給 policy 解析 allowed root） |
| `lib/core/services/file/file_tool_service.dart` | `file_view_image` 工具描述改寫（見 §4.10）；`viewedImageSha256` 已實作 |
| `lib/core/services/api/chat_api_service.dart` 各 transport | 依 §4.6 產生 wire shape；**所有內部鍵**（`_tool_images`、`_tool_image_allowed_paths`、`_native_input`、`_attachments`）在 encode 前剝除 |
| `lib/core/services/tools/tool_result_caps.dart` / `tool_result_pruner.dart` | 不改邏輯，但補測試：head/tail 的 marker 在 cap/prune 後仍存在 |

**重要**：`_normalizeOpenAiCompatMessageContent` 對 `role:'tool'` 會把 List content 攤平成字串。因此圖片**不能**以 content part 的形式掛在 neutral tool message 上；必須走 `ToolImagePlan` 的 side channel，transport 編碼時才產生。這樣也能保證 shape guard 不會把圖片吃掉。

### 4.6 各 transport 實作

#### 4.6.1 Claude（`_sendClaudeStream`，role:'tool' 分支）

> 實作注意：Claude 目前的迴圈是 `for (final m in messages)`，沒有 index；需改成 indexed loop（`for (var i = 0; i < messages.length; i++)`）或把 plan key 成 message map identity，才能用 `byMessageIndex[i]`。

目前：

```dart
'content': claudeToolResultContent((m['content'] ?? '').toString())
```

改成：

```dart
final resolution = imagePlan?.byMessageIndex[i];
final text = claudeToolResultContent(resolution?.cleanText ?? raw);

'content': resolution == null || resolution.images.isEmpty
    ? text
    : <Map<String, dynamic>>[
        {'type': 'text', 'text': text},
        for (final image in resolution.images)
          {
            'type': 'image',
            'source': {
              'type': 'base64',
              'media_type': image.mime,
              'data': base64Encode(image.bytes),
            },
          },
      ]
```

- 保持「一個 tool message → 一個 user 訊息 + 一個 tool_result」的現有結構，不動外層順序。
- `text` 不可為空；`claudeToolResultContent` 已處理 `(no output)`。
- 多張圖就是多個 image block。

#### 4.6.2 OpenAI Responses（`_sendOpenAIStream` 的 `function_call_output`）

目前：

```dart
'output': content,
```

改成：

```dart
final resolution = imagePlan?.byMessageIndex[i];

'output': resolution == null || resolution.images.isEmpty
    ? content
    : <Map<String, dynamic>>[
        {'type': 'input_text', 'text': resolution.cleanText},
        for (final image in resolution.images)
          {
            'type': 'input_image',
            'image_url':
                'data:${image.mime};base64,${base64Encode(image.bytes)}',
            'detail': 'auto',
          },
      ],
```

- 只在 `canImageInput == true` 時才會有 plan。
- `output` 陣列是 content parts，不是 input items；不要包 role。

#### 4.6.3 Gemini 3（`_sendGoogleStream`，stream 與 non-stream 兩處）

目前：

```dart
'functionResponse': {'name': name, 'response': response}
```

改成：

```dart
final resolution = imagePlan?.byMessageIndex[i];
final functionResponse = <String, dynamic>{
  'name': name,
  if (isGemini3 && toolCallId.isNotEmpty) 'id': toolCallId,
  'response': resolution == null || resolution.images.isEmpty
      ? response
      : {'result': resolution.cleanText},
  if (resolution != null && resolution.images.isNotEmpty)
    'parts': <Map<String, dynamic>>[
      for (var k = 0; k < resolution.images.length; k++)
        {
          'inlineData': {
            'displayName': 'image_$k.${_extForMime(resolution.images[k].mime)}',
            'mimeType': resolution.images[k].mime,
            'data': base64Encode(resolution.images[k].bytes),
          },
        },
    ],
};
```

- `isGemini3` 用新的 `isGemini3Family(modelId)`（建議放 `reasoning_wire.dart` 或新的 `gemini_capabilities.dart`；regex `gemini-3(\.\d+)?`，前後邊界避免誤匹配）。
- 非 Gemini 3 或 `canImageInput == false`：不建 plan，維持現狀。
- `response` 若是合法 JSON 且沒有圖片，保持原樣；有圖片時用 `{'result': cleanText}`，避免 bytes 進 JSON。
- `id` 只在 Gemini 3 且 `tool_call_id` 非空時加，降低舊模型相容風險。

#### 4.6.4 Chat Completions（`_sendOpenAIStream` 的 else 分支）

tool message 本身維持文字。在 `mm` 建完後（body 組裝前）執行：

```dart
if (canImageInput && settings sendToolImages && imagePlan?.tailUserImages.isNotEmpty == true) {
  mm.add({
    'role': 'user',
    'content': <Map<String, dynamic>>[
      {
        'type': 'text',
        'text': 'Tool output images (auto-attached for inspection; continue the task):',
      },
      for (final image in imagePlan!.tailUserImages)
        {
          'type': 'image_url',
          'image_url': {
            'url': 'data:${image.mime};base64,${base64Encode(image.bytes)}',
          },
        },
    ],
  });
}
```

- 只處理 `messages` 尾端連續的 tool 訊息（最後一組）；歷史較早的 tool 圖片留在文字 marker。
- 上限 4 張/請求（Chat Completions 的 synthetic 路徑）。
- 這則 user 訊息不持久化；下一輪由 transport 重新注入。
- `_normalizeOpenAiCompatMessageContent` 在 `mm` 建完前已執行，不會看到這則訊息；它的 user content allowlist 本來就接受 `image_url`，所以即使順序反過來也安全。
- 若 provider 回 400，Phase 3 已實作一次「無圖片重試」的 hardening（見 §7）；同一 generation 後續 tool round 會記住拒絕，避免重打。

### 4.7 失敗與降級矩陣

| 情況 | 行為 | 錯誤碼 |
|:--|:--|:--|
| 模型不支援 image input | status-only plan；Stage 1 文字 marker＋badge | `image_model_unsupported` |
| Gemini < 3 | status-only plan；Stage 1 文字 marker＋badge | `image_protocol_unsupported` |
| Chat Completions 開關關閉 | 不注入 synthetic user 訊息；badge | `image_setting_off` |
| 路徑不在 allowed roots / trusted | 跳過該張，保留 marker | `image_outside_workspace` |
| 檔案不存在（快取被 prune／工作區變動） | 跳過，保留 marker | `image_not_found` |
| 檔案 > 12 MB 或編碼後仍 > 上限 | 跳過 | `image_too_large` |
| magic bytes 不是支援格式／解碼失敗 | 跳過 | `image_unsupported_format`／`image_decode_failed` |
| 編碼失敗 | 跳過 | `image_encode_failed` |
| 超過每則／每請求上限 | 較舊的圖片不送，marker 保留 | `image_budget_exceeded`（log only） |
| 檔案在工具執行後被修改 | sha256 不符則跳過＋badge | `image_changed` |
| Provider 400（少數相容 provider 不接受圖片） | 自動移除圖片重試一次；同 generation 後續 round 不再重送 | `image_provider_rejected`（badge） |

**為什麼不「回明確錯誤」**：`file_view_image` 的結果是**可選上下文**，不是請求的必要條件。硬性報錯會讓一個本來可以正常回答的回合直接失敗（尤其 provider 兼容性差異大）。Stage 2 選擇「無聲降級 + log + UI 提示」，與 Stage 1 的行為一致。若使用者真的需要模型看圖，tool card 會顯示「Image not sent to model」badge（靜態模型／設定檢查＋runtime 失敗原因）。

### 4.8 Replay / regeneration / compaction

| 情境 | 行為 |
|:--|:--|
| 同一回合的多輪 tool loop | `AgentLoop` 把 live tool result 放進 working list；send-time plan 每輪重新解析，最後一組一定有圖 |
| 重新生成舊回覆 | `MessageBuilderService.neutralMessagesFor` 重播 tool events；marker 仍在，plan 重新讀檔送圖（受 8 張上限） |
| `replayToolResults = false` | 完全不重播 tool messages → 不會有工具圖片；使用者關閉了工具記憶，這是預期行為 |
| L1 重試 | plan 在同一請求内重用；圖片 bytes 由 LRU 快取避免重複編碼 |
| Context 壓縮（L1 summary） | 舊 tool result 被摘要成文字，詳細圖片不再送；最近未壓縮的 tool result 仍可送 |
| L0 middle prune（8192 chars） | marker 在 head 或 tail，4096/1024 的保留區可覆蓋；補測試確保不會被切 |
| MCP 截圖 prune（40 張） | 檔案不存在 → `image_not_found`，降級文字 marker |
| 工作區檔案被修改 | `file_view_image` 的 `imageSha256` extras 已實作；send-time 比對不符即跳過（`image_changed`），模型可重新呼叫工具。MCP 截圖沒有 sha（cache 檔不可變），仍以路徑／magic bytes 驗證。 |

**Snapshot fidelity（已實作）**：`file_view_image` 在讀 bytes 時計算 SHA-256，寫入 `imageSha256` extras；重播時 `ToolImagePlan` 比對目前檔案 hash，不符就降級文字 marker。這避免「模型以為看到舊圖、實際送出被改過的圖」。MCP 截圖是 app 私有 cache 產物，未加 hash。

### 4.9 Token / context / 成本

- 每請求最多 8 張；每則工具最多 4 張；Chat Completions synthetic 路徑最多 4 張。
- 粗略 token 成本（保守估計，用於 context 估算）：
  - Claude 1568 px：約 1.1k tokens/張（Anthropic 會再依實際尺寸調整）。
  - OpenAI high detail：約 1.1k tokens/張（依 tiles 變動）。
  - Gemini：約 258 tokens/張。
- Phase 3 在 `context_usage_service.dart` 加 `estimateToolImageTokens(messages)`：每個未被丟棄的 marker × 1,500 tokens（保守上限），避免壓縮觸發點低估。
- Prompt caching：
  - Claude 的 tool_result 圖片會進 cache prefix；deterministic 編碼 + 固定順序讓同一段歷史的 prefix 穩定。
  - LRU 快取避免每輪重新編碼造成 bytes 不穩。
  - 不要在圖片 block 上加 `cache_control`（沿用既有 cache breakpoint 策略）。

### 4.10 設定與 UI

#### 新設定

- Key：`send_tool_images_v1`
- `SettingsProvider`：`bool _sendToolImages = true;` + getter/setter + `copyWith` + `load()`（比照 `replayToolResults`）。
- UI：`display_settings_page.dart` 的「顯示」區，放在 `replayToolResults` 附近：
  - 標題（en）：`Send tool images to vision models`
  - 副標（en）：`Attach screenshots from file_view_image and MCP tools when the model supports image input. Turn off if a provider rejects image content.`
  - 中文（zh_Hant）：`將工具結果圖片傳送給視覺模型`／`當模型支援圖片輸入時，將 file_view_image 與 MCP 工具的截圖附加到工具結果。若供應商拒絕圖片內容，請關閉此選項。`
  - l10n 四檔：`app_en.arb`、`app_zh.arb`、`app_zh_Hans.arb`、`app_zh_Hant.arb`；跑 `flutter gen-l10n`。
- 設定關閉時：`ChatApiService` 不建 plan；所有 transport 回到 Stage 1。

#### 工具描述

`FileToolService.getToolDefinitions()` 的 `file_view_image` 描述改寫：

> View an image in the workspace (PNG, JPEG, GIF, WebP, or BMP). On vision-capable models the image is attached to the tool result so you can inspect it directly; otherwise a preview is shown to the user.

#### Tool card（Phase 3）

- 目前模型不支援 vision：在 `file_view_image`／MCP 圖片卡上加一個小 badge（`Image not sent to model`），hover/tap 顯示原因。
- 需要把「目前模型能力」傳進卡片，或由 send-time 失敗時寫一個 ephemeral extras（不建議持久化）。Phase 3 再定。

---

## 5. 測試計畫

### 5.1 新 unit tests

| 檔案 | 覆蓋 |
|:--|:--|
| `test/tool_result_images_test.dart` | marker 抽取（head/tail、多張、重複、URL 跳過、malformed）；newest-first 上限；cleanText 正確移除成功 marker、保留失敗 marker |
| `test/tool_result_images_test.dart` | workspace/session/MCP root 允許；outside 拒絕；`..`/NUL/relative 拒絕；symlink 逃逸拒絕（Windows 無權限時 skip）；ledger trusted path 允許；persisted `_tool_image_allowed_paths` **不**授予；重複 marker 失敗保留 |
| `test/tool_image_codec_test.dart` | PNG/JPEG/GIF/WebP/BMP decode；alpha → PNG；opaque → JPEG；縮放不放大；>5MB 降級；corrupt bytes；EXIF 方向（可選）；cache key 隨 mtime/size 變更 |
| `test/tool_result_marker_survival_test.dart` | `ToolResultCaps.cap` 與 `pruneToolResultText` 後 head/tail marker 仍存在 |

### 5.2 Transport golden tests

| 檔案 | 新增案例 |
|:--|:--|
| `test/replay_tool_results_api_test.dart` | Claude：tool_result content 為陣列、含 text + image block、順序正確、空文字變 `(no output)`；Responses：`function_call_output.output` 陣列含 `input_text` + `input_image` data URL；Gemini 3：`functionResponse.parts[].inlineData` + `id`；Gemini 2.x：維持文字 |
| `test/core/services/api/agent_loop_provider_parity_test.dart` | 多輪 tool loop 中，第二輪 follow-up body 的 tool result 帶圖；Gemini 3 thought signature + image parts 可共存 |
| `test/core/services/api/chat_completions_content_shape_test.dart` | tool message 仍是純文字；synthetic user 訊息只在最後一組 tool 後出現；`image_url` part 不被 shape guard 丟棄；內部鍵不外洩 |
| `test/chat_api_service_oauth_routing_test.dart` | Codex/Responses OAuth 路徑的 `function_call_output` 圖片陣列 |
| `test/file_grep_view_image_test.dart` | `file_view_image` 的 marker/extras 不變；Phase 3 sha256 extras |
| `test/settings_provider_*_test.dart` | `sendToolImagesV1` 預設 true、持久化、copyWith |

### 5.3 回歸與真機驗證

- `flutter analyze`（至少 touched files clean）。
- `flutter test` 目標檔 + 全 suite。
- 真機 matrix（至少各一）：
  - Claude vision 模型：`file_view_image` → 問「圖裡有什麼」→ 答案正確。
  - OpenAI Responses vision 模型：同上。
  - Gemini 3：同上。
  - Chat Completions vision 模型：同上（synthetic user 路徑）。
  - 非 vision 模型：請求成功、回 Stage 1 文字。
  - 關閉 `sendToolImagesV1`：所有 transport 回 Stage 1。
  - 工作區外的檔案：不會被送出（用一個假的 `[image:C:\Windows\...]` marker 測）。

---

## 6. 實作階段

### Phase 0：共用模組與依賴（無行為變更）✅

- [x] `pubspec.yaml` 加 `image: ^4.10.1`（lock 已有 4.10.1）。
- [x] 新增 `tool_result_images.dart`、`tool_image_codec.dart`。
- [x] 新增 `ToolImageAccessLedger`。
- [x] 新增 `McpScreenshotStore.directory()`。
- [x] 單元測試：marker、policy、codec、cache、cap/prune survival。
- **驗收**：`flutter test` 新測試全綠；現有測試不受影響；尚無 transport 行為變更。

### Phase 1：Claude + Responses + Gemini 3（原生路徑）✅

- [x] `ChatApiService.sendMessageStream` 加 `ToolImagePolicy?`；建 plan；傳給三個 transport。
- [x] `AgentOrchestrator.run` / `sendRoundImpl` 加參數；主 run 與 revision 傳入。
- [x] `GenerationContext` / `MessageGenerationService` / `ChatActions` 接線。
- [x] `ToolHandlerService` 寫 ledger；`MessageBuilderService` 只重播 `imageSha256`。
- [x] Claude / Responses / Gemini 3 wire 編碼（含 streaming Gemini）。
- [x] `isGemini3OrNewer` helper。
- [x] Golden tests 擴充。
- **驗收**：三個原生 transport 的 wire 測試通過；非 vision 模型不受影響；圖片不出現在 DB/log。

### Phase 2：Chat Completions 相容路徑 + 設定 ✅

- [x] `sendToolImagesV1` 設定（provider、UI、l10n ×4、測試）。
- [x] Chat Completions synthetic user 訊息（只最後一組、上限 4）。
- [x] Shape guard／orphan repair 回歸測試。
- **驗收**：Chat Completions vision 模型能看圖；關閉設定後完全回 Stage 1；嚴格 provider 不出現 shape 400。

### Phase 3：韌性與成本（可分批）✅

- [x] LRU 圖片快取。
- [x] `imageSha256` extras + send-time 比對（檔案變更偵測）。
- [x] `context_usage_service` 的 image token 估算。
- [x] Tool card「Image not sent to model」badge（靜態＋runtime）。
- [x] Provider 400 的一次性無圖片重試（run 內記憶拒絕，避免每輪重打）。
- [x] status-only plan 32 筆上限，避免長歷史每輪大量 DB 寫入。
- **驗收**：長對話 token 估算不嚴重低估；檔案變更不會送出錯誤 snapshot；失敗有可見提示（badge）。

### Phase 4：文件與全面回歸 🔶

- [x] 更新 `docs/Cowork剩餘項目實作計畫.md` §2.17（Stage 2 狀態）。
- [x] 更新 `OmniChat 專案開發與維護手冊.md` §3.1（vision plumbing、圖片安全邊界、設定）。
- [x] 更新 `docs/file_view_image_stage2_plan.md` 的實作紀錄（含 Stage 3）。
- [x] 目標測試檔 + `flutter analyze`。
- [ ] 真機 matrix（Claude／Responses／Gemini 3／Chat Completions／非 vision）尚未跑。
- **驗收**：文件與程式一致；所有自動測試通過；真機驗證待做。

---

## 7. 風險與待決事項

| # | 議題 | 建議 | 備註 |
|:--|:--|:--|:--|
| 1 | Chat Completions 是否預設注入 synthetic user 訊息？ | **預設開**，提供 `sendToolImagesV1` 關閉 | 若實測發現多數 provider 不適應，再改預設關 |
| 2 | 已核准的工作區外圖片是否要送？ | **要，但只靠 in-memory ledger** | persisted extras 可被備份偽造，不授予路徑；重啟後需重新核准 |
| 3 | 是否驗證檔案 snapshot（sha256）？ | **已做**（`file_view_image`） | MCP 截圖不變，未加 hash |
| 4 | 是否快取編碼結果？ | **Phase 0 先做簡單 LRU** | 避免每輪重編碼；對 prompt caching 有幫助 |
| 5 | 每請求圖片上限 | **8 張**（每則 4 張） | 成本與 context 的折衷；可調 |
| 6 | Claude 最長邊 | **1568 px** | Anthropic 會再縮；送更大浪費 token |
| 7 | 是否支援遠端 `[image:https://...]` tool marker？ | **Stage 2 不做** | 目前 MCP 圖片已落盤；遠端 URL 可另立計畫 |
| 8 | 是否支援 SVG/HEIC？ | **不做** | `file_view_image` 目前也不接受；避免格式矩陣膨脹 |
| 9 | 圖片在 L0 prune 被切掉怎麼辦？ | 補測試；必要時讓 prune 保留 marker 行 | 目前 head/tail 設計應足夠 |
| 10 | Gemini 2.x 是否真的不支援？ | **先降級**，等有官方文件再開 | 保守避免 400 |

---

## 8. 驗收清單

- [x] Claude：`tool_result` image block wire shape（transport test）。真機描述內容待驗。
- [x] OpenAI Responses：`function_call_output.output` 含 `input_image`（transport test）。真機描述內容待驗。
- [x] Gemini 3：`functionResponse.parts[].inlineData` + `id`（stream/non-stream transport test）。真機描述內容待驗。
- [x] Chat Completions：tool role 維持文字；最後一組後有 synthetic user 圖片訊息（transport test）。真機描述內容待驗。
- [x] 非 vision 模型：Stage 1 文字 marker，無圖片 part（transport test）。Gemini 2.x 真機待驗。
- [x] 工作區外、symlink 逃逸、偽造 persisted extras、非圖片檔、>12 MB：不送出，穩定錯誤碼（unit tests）。
- [x] 圖片 bytes 不進 DB／不進 log；重新編碼剝除 EXIF。
- [ ] `replayToolResults=false` 時沒有工具圖片（邏輯上成立，尚無專測）。
- [ ] 重新生成／重播舊對話時，圖片仍能按 marker 重建（workspace 路徑成立；界外核准重啟後需重新核准）。
- [x] `flutter analyze` 無 error／warning；Stage 2 相關測試全綠。全 suite 另有 2 個與本功能無關的 Hive 初始化失敗（`sqlite_chat_storage_test.dart`）。
- [x] 文件（§2.17、手冊 §3.1、本計畫）同步。

---

## 9. 參考資料

### 協議

- Anthropic Messages API — `ToolResultBlockParam`、`ImageBlockParam`、`Base64ImageSource`：
  <https://docs.anthropic.com/en/api/messages>
- Anthropic Tool use — tool_result 順序與配對規則：
  <https://docs.anthropic.com/en/docs/build-with-claude/tool-use/overview>
- Anthropic Vision — 圖片格式與尺寸限制：
  <https://docs.anthropic.com/en/docs/build-with-claude/vision#image-limitations>
- OpenAI Responses API — `FunctionCallOutput`、`ResponseInputImage`：
  <https://developers.openai.com/api/reference/resources/responses/methods/create>
- OpenAI Chat Completions — `ChatCompletionToolMessageParam`：
  <https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create>
- Google Gemini — function calling 的 multimodal function response：
  <https://ai.google.dev/gemini-api/docs/function-calling>

### 程式碼

- `lib/core/services/file/file_tool_service.dart` — `_viewImage()`、`_sniffImageFormat()`、工具定義。
- `lib/core/services/api/chat_api_service.dart` — `sendMessageStream()`、`_sendClaudeStream()`、`_sendOpenAIStream()`（Responses／Chat Completions）、`_sendGoogleStream()`、`_truncateToolResultsInMessages()`、`_normalizeOpenAiCompatMessageContent()`。
- `lib/core/services/agent/agent_loop.dart` — `AgentNeutralMessages.toolResultMessage()`、follow-up 訊息。
- `lib/core/services/agent/agent_orchestrator.dart` — `run()`、`sendRoundImpl()`。
- `lib/core/services/chat/chat_turn_service.dart` — `buildApiMessages()`（重播 tool events）。
- `lib/features/home/services/message_builder_service.dart` — `buildApiMessages()`、`neutralMessagesFor()`、`toolResultContentForModel()`。
- `lib/features/home/services/tool_handler_service.dart` — file tool 結果、`_persistImagePreviewExtras()`。
- `lib/features/home/controllers/stream_controller.dart` — `GenerationContext`。
- `lib/features/home/services/message_generation_service.dart` — `workspacePath`、`buildGenerationContext()`。
- `lib/core/services/mcp/mcp_screenshot_store.dart` — `save()`、`prune()`。
- `lib/core/services/file/session_outputs.dart` — `rootDirectory()`、`rootDirectoryForRead()`、`resolveFromRoot()`。
- `lib/core/services/model_catalog/model_catalog.dart` / `model_provider.dart` — `imageInput`、`Modality.image`。
- `lib/core/services/api/reasoning_wire.dart` — Gemini 3 family regex 可放這裡。
- `lib/core/services/agent/compaction/tool_result_pruner.dart` / `tool_result_caps.dart` — marker 存活測試。
- `test/replay_tool_results_api_test.dart`、`test/core/services/api/agent_loop_provider_parity_test.dart`、`test/core/services/api/chat_completions_content_shape_test.dart` — golden 測試擴充點。

---

## 10. 與 §2.17 原文的差異說明

`docs/Cowork剩餘項目實作計畫.md` §2.17 原藍圖寫「不支援的模型回明確錯誤」。本計畫改為**無聲降級 + log + UI 提示**，原因：

1. 工具結果圖片是**可選上下文**；硬性錯誤會讓原本可回答的回合失敗。
2. OpenAI-compatible 生態對圖片／tool content 的接受度差異大，硬錯會造成大量客服問題。
3. Stage 1 已經是「文字 marker」的可用狀態；降級不是功能缺失，而是回到既有行為。
4. 真正的能力問題（模型不支援 vision）在 UI 顯示即可，不需要讓模型或請求失敗。

若未來要做「明確錯誤」，應只在**使用者主動要求看圖**且模型不支援時，於 UI 提示切換模型，而不是在 transport 層丟錯。
