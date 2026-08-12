# 導入 kelivo 圖片生成模型支援（OpenAI Images API）

> **本版修訂**：依 2026-08-12 review（F1–F13）修正後之計畫。各修正的落點於「修訂紀錄（review F1–F13）」章節對照。全文引用之行號以現行 `main` 為準（`chat_api_service.dart` 7388 行、`model_detail_sheet.dart` 1212 行、`model_edit_dialog.dart` 1137 行）。

## 目標與範圍

把 kelivo 上游的 OpenAI Images API 支援外科手術式地 backport 進 OmniChat，讓真正的圖片生成模型（`dall-e-3`、`gpt-image-1`、`agnes-image-*`、`sensenova-u1-fast`，以及透過開關手動啟用的 SiliconFlow FLUX/Kolors 等）能走獨立的 `/images/generations` 與 `/images/edits` 端點，而非聊天補全。

範圍限定：只移植 `openai_images.dart` 這一個 provider 與其最小 UI 接線。不引入 kelivo 後來的 provider-strategy 重構、結構化 `message_part`、`model_override_resolver` 等架構變更（OmniChat 仍是單檔單字串 content 模型）。

**分兩階段執行（F13）**：Phase 1＝步驟 1–6（核心 backport，可獨立合併）；Phase 2＝步驟 7（比例選擇器，含持久化 + UI + 比例轉換）。兩個 Phase 共用同一份檔案總表與驗證清單，但建議分兩個 PR。

## 背景：OmniChat 現況

OmniChat 是 kelivo 的較舊 fork。它已經有「聊天模型內嵌出圖」能力：

- OpenAI Responses API 的 `image_generation` 內建工具（`chat_api_service.dart:1640`、輸出處理 `:3211`）
- Gemini `responseModalities:['TEXT','IMAGE']`（`:6663`，含 `_bufferInlineImageChunk`/`_takeBufferedImageMarkdown` 局部函式 `:6820`/`:6837`）

這兩條路徑都把圖以 `![image](path)` markdown 插入回覆。缺少的是 kelivo 的 `lib/core/services/api/providers/openai_images.dart`（17KB）——獨立的 Images API 端點，依 model-id 路由，回傳單一 `ChatStreamChunk`（內容為 `![image](path)` markdown，不串流）。

## 設計決策（已與使用者確認；本版依 review 修正）

1. **判斷拆兩層**（`2026-08-13 最終定案`）：不再使用 model-id 白名單。① **`isOpenAIImageOutputModel(cfg, modelId)`**——「是否圖片模型」的單一標準：`_apiKind(cfg) == openai`（neuralwatt 亦屬之）且**模型基本設定頁輸出模式勾選「圖片」**（未設定時回退 `ModelRegistry.infer` 依 id 推斷，如 `dall-e-*`/`gpt-image-*`/`sensenova-u1-fast`）。**與開關無關**——供輸入列比例按鈕與 `generateText`/OCR/翻譯守護使用（關掉開關後模型仍可能經聊天補全出圖，按鈕/守護照常生效）。② **`shouldUseOpenAIImagesApi(cfg, modelId)`**——「是否走 Images API」的路由決策：＝① 且 `useImagesApi != false`（工具頁「使用 Images API」開關僅對圖片輸出模型顯示、預設開啟；關閉表示「輸出雖是圖片但走聊天補全」，混合模型/供應商以聊天補全出圖；非圖片輸出模型看不到開關、不可 opt-in），僅供 `sendMessageStream` 分支使用。
2. **生成 ＋ 編輯都要**：無輸入圖→`/images/generations`；有輸入圖（含引用上一張生成圖）→`/images/edits`（image-to-image / 疊代編輯）。
3. **公開路由判斷函式（F2）**：路由分支與輸入列比例按鈕**共用同一個公開函式** `ChatApiService.shouldUseOpenAIImagesApi(cfg, modelId)`（無底線、public static）——`chat_input_bar.dart` 與 `chat_api_service.dart` 屬不同 library，private 方法不可跨檔呼叫，且共用單一判斷來源才能保證「按鈕顯示 ⇔ 實際走 Images API」一致。
4. **比例參數由呼叫端 thread 進 service（F3）**：`ChatApiService` 為純 static、無 `SettingsProvider` 存取（已確認 `chat_api_service.dart` 內無任何 `SettingsProvider.` 引用、無 singleton）。`sendMessageStream` 新增 `String? imageAspectRatio` named param，由呼叫端讀取全域設定傳入。
5. **`aspect_ratio` 直傳需 per-model 覆寫旗標（F4）**：`_sendOpenAIImagesStream` 的進入條件保證 `kind == ProviderKind.openai`（`_apiKind` 把 neuralwatt 也映射為 openai），因此「非 OpenAI 系」不可能從 kind 判別。新增 `useAspectRatioParam` 覆寫旗標（僅在輸出模式含「圖片」時顯示於工具分頁），供原生支援 `aspect_ratio` 的供應商（如 Nano Banana 2）使用；SiliconFlow FLUX 走 `size`/`image_size`，不開此旗標。
6. **dall-e-3 回退提示不經 SnackBar（F5）**：service 層無 BuildContext 無法顯示 SnackBar；回退發生時將附註直接附加於回覆 markdown 之後。

## 實作步驟

### 步驟 1：在 `sendMessageStream` 加入路由分支（含比例參數 thread）

檔案：`lib/core/services/api/chat_api_service.dart`

1. `sendMessageStream`（`:795`）簽名新增 `String? imageAspectRatio`（F3）。
2. 在 try 區塊內、`final kind = _apiKind(config);`（`:811`）之後、`if (kind == ProviderKind.openai)`（`:826`）鏈之前，插入最早分支：

```dart
if (kind == ProviderKind.openai &&
    shouldUseOpenAIImagesApi(config, modelId)) {
  yield* _sendOpenAIImagesStream(
    client, config, modelId, truncatedMessages,
    userImagePaths: userImagePaths,
    extraHeaders: extraHeaders,
    extraBody: extraBody,
    imageAspectRatio: imageAspectRatio,
  );
} else if (kind == ProviderKind.openai) {
  yield* _sendOpenAIStream(...); // 既有
} else if (kind == ProviderKind.claude) { ... } else if (kind == ProviderKind.google) { ... }
```

這樣 Images API 模型完全不進入 `_sendOpenAIStream`，`finally` 的 `client.close()` + cancelToken 清理仍會執行。

3. **呼叫端更新（4 個 call site，F3）**——`sendMessageStream` 的所有呼叫端都要補傳比例參數（compile error 會強制，但請照此清單）：

| 呼叫端 | 位置 | 傳值 |
|---|---|---|
| `lib/core/services/chat/chat_turn_service.dart` | `:264` | `settings.imageAspectRatio`（有 `SettingsProvider` 處） |
| `lib/features/home/controllers/chat_actions.dart` | `:590`、`:921` | `ctx.settings.imageAspectRatio` |
| `lib/features/home/services/ocr_service.dart` | `:71` | `null`（已加守護，見步驟 3b，不會進 Images API） |
| `lib/features/home/services/translation_service.dart` | `:117` | `null`（同上） |

### 步驟 2：移植 openai_images 為 `ChatApiService` 的 static 方法

同一檔案。把 kelivo `openai_images.dart` 的頂層函式改寫為 `ChatApiService` 的 `static` 方法（與既有 `_sendOpenAIStream`、`_apiModelId`、`_saveInlineImageToFile` 一致），並做以下適配：

| kelivo 符號 | OmniChat 對應 / 改寫 |
|---|---|
| `AppDirectories.saveBase64Image(mime, b64)` | `_saveInlineImageToFile(mime, b64)`（`:436`，回傳 `String?` 路徑） |
| `AppDirectories.extFromMime(mime)` | `_extFromMime(mime)`（`:420`） |
| `SandboxPathResolver.canonicalize(path)` | 直接用 `_saveInlineImageToFile` 回傳的新路徑（已落在 images 目錄，無需 sandbox 重寫）；必要時包 `SandboxPathResolver.fix(...)` |
| `isImageMime(mime)` | 內聯 `mime.startsWith('image/')` 或新增小工具 `_isImageMime` |
| `parseInternalMediaRefs` / `multimodalInternalMediaPathsKey` / `_mimeForInternalMediaRef` / `InternalMediaRef` | 捨棄該分支（kelivo 結構化多模型，OmniChat 沒有）。`_openAIImagesInput` 改為依序：① `userImagePaths` 參數 ② `_parseTextAndImages` 解析最後一則 user 訊息的 `![](url)`/`[image:path]` ③ `_lastAssistantImageBefore` 回退（疊代編輯） |
| `_customHeaders(config, modelId, baseHeaders:, assistantHeaders:)` | OmniChat `_customHeaders(cfg, modelId)`（`:279`，無具名參數，只回傳 custom headers）。`_openAIImagesJsonHeaders` 改為：`{Authorization, Content-Type}` ⨁ `_customHeaders(cfg, modelId)` ⨁ `extraHeaders` |
| `_customBody(config, modelId, assistantBody:)` | OmniChat `_customBody(cfg, modelId)`（`:319`）。`_applyOpenAIImagesExtraBody` 改為 `body.addAll(_customBody(cfg, modelId)); if (extraBody != null) body.addAll(extraBody);` |
| `_apiModelId(config, modelId)` | `_apiModelId(cfg, modelId)`（`:217`，參數名 `cfg`） |
| `_apiKeyForRequest` / `_parseTextAndImages` / `_mimeFromPath`(:382) / `_mimeFromDataUrl`(:402) / `ChatStreamChunk`(:7349) / `TokenUsage`（`lib/core/models/token_usage.dart`，已 import） | 直接沿用，簽名相容 |
| `_ImageRef`（kelivo 自帶 `mime` 欄位） | 不另定義，沿用 OmniChat `_ImageRef`（`:7320`，有 `.kind`/`.src`）。需要 mime 時以 `_mimeFromPath(ref.src)`/`_mimeFromDataUrl(ref.src)` 推導，避免改動 `_ImageRef` |
| `http.Client client` | 沿用 `_clientFor` 回傳的 `http.Client`（`:773`）。**`DioHttpClient.send(BaseRequest)` 已實作**（`request.finalize().toBytes()` 全量緩衝後走 Dio，`RequestLogger` 相容），`client.post` / `client.send(MultipartRequest)` 皆相容，**不需獨立 `http.Client()` fallback**（獨立 client 反而會繞過 proxy 設定）。註記：multipart body 全量 in-memory，一般圖片（數 MB）可接受（F10） |

需移植的方法清單（全改為 `static`，貼進 `ChatApiService`）： **`shouldUseOpenAIImagesApi`**（公開，F2）、**`isOpenAIImageEditModel`**（公開，`2026-08-13`：**編輯 id 白名單已移除**，改以「有效 input 與 output 皆含圖片」判斷）、`_openAIImagesUrl`、`_sendOpenAIImagesStream`、`_sendOpenAIImageGeneration`、`_sendOpenAIImageEdit`、`_lastOpenAIImagePrompt`、`_openAIImagesInput`、`_lastAssistantImageBefore`、`_extractOpenAIImageRefs`、`_addOpenAIStructuredImageRefs`、`_addOpenAIStructuredImageData`、`_imageRefFromSource`、`_tryOpenAIImageMultipartFile`、`_openAIImageMediaType`、`_openAIImagesJsonHeaders`、`_openAIImagesMultipartHeaders`、`_applyOpenAIImagesExtraBody`、`_openAIImagesOutputMime`、`_decodeOpenAIImagesResponse`、`_openAIImagesResponseToMarkdown`、`_openAIImagesUsage`、**`_imageApiSizeParam`**（步驟 7d），以及小類別 `_OpenAIImagesInput`。（生成白名單 `_supportsOpenAIImageGenerations` 已刪除；編輯白名單 `_supportsOpenAIImageEdits` 亦已刪除——都不再以 id 白名單決定，改由模式判斷。）

**兩個公開函式實作**（F2；`2026-08-13 最終定案`）：

```dart
/// 「是否圖片模型」——單一標準，與開關無關（比例按鈕、generateText/OCR/翻譯守護用）
static bool isOpenAIImageOutputModel(ProviderConfig cfg, String modelId) {
  if (_apiKind(cfg) != ProviderKind.openai) return false;   // neuralwatt 亦屬 openai
  return _effectiveModelInfo(cfg, modelId).output.contains(Modality.image);
}

/// 「是否走 Images API」——路由決策（sendMessageStream 分支用）
static bool shouldUseOpenAIImagesApi(ProviderConfig cfg, String modelId) {
  if (!isOpenAIImageOutputModel(cfg, modelId)) return false; // 非圖片輸出模型：無開關、不可 opt-in
  final ov = _modelOverride(cfg, modelId);
  return ov['useImagesApi'] != false;                        // 預設開啟，僅 explicit false 關閉
}
```

`_effectiveModelInfo`（既有，`:340`）＝ per-model override 的 `type`/`input`/`output`/`abilities` 覆蓋 `ModelRegistry.infer` 推斷結果——即**模型基本設定頁勾選的模式**優先，未設定時由 `ModelRegistry.infer` 依 id 推斷。**`isOpenAIImageEditModel`**（公開）＝ `_apiKind(cfg) == openai` 且有效 input **與** output 皆含圖片——輸入含圖片（且輸出含圖片）→ 送 `/images/edits`；否則 **送前快速失敗**（保留 `UnsupportedError` 清晰訊息，`2026-08-13`：不做 4xx 自動降級，錯誤原因很多不能僅憑狀態碼判定）。**infer 修正（`2026-08-13`）**：`dall-e-3`/`sensenova-u1-fast` 改為**僅輸出含圖片**（input 純文字 → 非編輯模型），`dall-e-2` 維持 input+output（OpenAI 支援其 edits 端點）；使用者顯式勾選 input 圖片可覆寫推論。

**收尾 chunk 契約（F12）**：`_sendOpenAIImagesStream` 回傳單一 `ChatStreamChunk`（`content`＝`![image](path)` markdown、`isDone: true`、`totalTokens`＝`_openAIImagesUsage` 提供；消費端 `_handleStreamData`/`_handleStreamDone` 依賴此契約）。`_openAIImagesUsage` 必須 **null 安全**：dall-e 系列不回傳 token usage（→ `totalTokens: 0`、`usage: null`）；gpt-image-1 有 `usage.input_tokens`/`output_tokens`/`total_tokens`（含 images tokens），有則映射、無則 0。

### 步驟 3：`generateText` 防誤用守護 ＋ 3b：OCR/翻譯守護

**3a.** 同一檔案 `generateText`（`:898`，用於標題/摘要）。在 openai 分支（`:903`）開頭加：

```dart
if (shouldUseOpenAIImagesApi(config, modelId)) return '';
```

圖片模型無法做文字摘要；回傳空字串避免崩潰（`finally` 仍會 `client.close()`，無洩漏）。

**3b.（F11）** OCR（`lib/features/home/services/ocr_service.dart`）與翻譯（`lib/features/home/services/translation_service.dart`）也以聊天模型呼叫 `sendMessageStream`——若使用者把圖片模型設為聊天模型，這兩條流程會誤出圖。在兩者呼叫前套用同一守護：`shouldUseOpenAIImagesApi(cfg, modelId)` 為 true 時，OCR 回傳空文字、翻譯回傳原文（不呼叫 `sendMessageStream`）。

### 步驟 4：模型設定 UI 加「使用 Images API」與「使用 aspect_ratio 參數」開關（**mobile + desktop，F6；`2026-08-13 最終定案`：開關僅圖片輸出模型可見、預設開啟**）

**mobile**：`lib/features/model/widgets/model_detail_sheet.dart`

- 新增狀態 `bool _useImagesApi = true;` 與 `bool _useAspectRatioParam = false;`（宣告於 `:67` 附近的工具開關區）
- `initState`（`:93`）在 `ov != null` 區塊（`:143`）內讀回：`final imApi = ov['useImagesApi']; _useImagesApi = imApi is bool ? imApi : true;` 與 `_useAspectRatioParam = (ov['useAspectRatioParam'] == true);`
- 在 `_buildTools`（`:505`）的 `openai/neuralwatt` 分支（`:558`）加**兩個** `_ToolTile`，**皆僅在輸出模式含圖片時顯示**（`if (_output.contains(Modality.image))`）：
  - title: `modelDetailSheetUseImagesApiTool`、desc: `modelDetailSheetUseImagesApiToolDescription`（說明走 `/images/generations` 與 `/images/edits` 而非聊天補全；dall-e/gpt-image/FLUX 等）——`value: _useImagesApi`（**預設 true**）、`onChanged: (v) => setState(() => _useImagesApi = v)`
  - title: `modelDetailSheetUseAspectRatioParamTool`（設計決策 5 的 `useAspectRatioParam` 覆寫旗標 UI）、desc: `modelDetailSheetUseAspectRatioParamToolDescription`（對原生支援 `aspect_ratio` 的供應商直接傳比例字串，而非轉換為 size）——`onChanged: (v) => setState(() => _useAspectRatioParam = v)`
- `_save()`（`:637`）在 `ov[key] = {...}`（`:686`）：`if (!_useImagesApi) 'useImagesApi': false,`（**僅關閉時寫入**，開啟/未動則不寫、回退預設開啟）與 `'useAspectRatioParam': _useAspectRatioParam,`

**desktop（新增，F6）**：`lib/desktop/model_edit_dialog.dart`（桌面版是獨立實作，mobile sheet 的變更不會涵蓋它）

- 新增狀態 `bool _useImagesApi = true;` 與 `bool _useAspectRatioParam = false;`（宣告於工具開關區，`:59`–`:74` 附近）
- `initState` 的 override 讀回區塊（`:98`–`:141`）加 `final imApi = ov['useImagesApi']; _useImagesApi = imApi is bool ? imApi : true;` 與 `_useAspectRatioParam = (ov['useAspectRatioParam'] == true);`
- 在工具 tile 區塊 `else if (_providerKind == ProviderKind.openai)`（`:522`）加**兩個** `_ToolTile`，**皆僅在 `_output.contains(Modality.image)` 時顯示**（`useImagesApi` 在前、`useAspectRatioParam` 在後）。注意桌面另有「Responses Only」提示文字條件（`:484` 的 `cfg.useResponseApi != true`），此二 tile 不受限制
- `_save()`（`:565`）寫入 override 的 map literal：`if (!_useImagesApi) 'useImagesApi': false,` 與 `'useAspectRatioParam': _useAspectRatioParam,`（與 mobile 相同）

### 步驟 5：本地化字串

檔案：`lib/l10n/app_en.arb`、`app_zh.arb`、`app_zh_Hans.arb`、`app_zh_Hant.arb`（比照既有 `modelDetailSheet*` 鍵）新增：

- `modelDetailSheetUseImagesApiTool`：例 "Use Images API"／"使用 Images API"
- `modelDetailSheetUseImagesApiToolDescription`：例 "Route this model to /images/generations and /images/edits instead of chat completions (dall-e, gpt-image, FLUX, etc.)"／"改走 /images/generations 與 /images/edits 端點而非聊天補全（dall-e、gpt-image、FLUX 等）"
- `modelDetailSheetUseAspectRatioParamTool`：例 "Use aspect_ratio param"／"使用 aspect_ratio 參數"
- `modelDetailSheetUseAspectRatioParamToolDescription`：例 "Send the selected ratio as the aspect_ratio field for providers that support it natively (e.g. Nano Banana 2)"／"對原生支援 aspect_ratio 的供應商（如 Nano Banana 2）直接傳所選比例字串，而非轉換為 size"

**CI 修正（F7）**：本 repo **沒有** `.github/scripts/check_no_new_untranslated.py`（`.github/` 僅 FUNDING.yml、ISSUE_TEMPLATE、workflows）；`l10n.yaml` 設 `untranslated-messages-file: desiredFileName.txt`，`flutter gen-l10n` 對缺翻譯只寫檔、不失敗。但仍應**一次補齊全部 4 個 arb**（en 為 template，zh/zh_Hans/zh_Hant 皆需），並重新生成 `app_localizations*.dart`，維持既有慣例。

### 步驟 6（選用、純 UI 標記）：`ModelRegistry.infer` 擴充圖片模型推斷

檔案：`lib/core/providers/model_provider.dart`。

**既有規則（F8）**：`infer`（`:85`）已有 `if (id.contains('image'))` 區塊（`:98` 附近），`gpt-image-*`/`chatgpt-image-*`/`agnes-image-*` 已被涵蓋（且同時把 input 與 output 都標為 image、移除 tool/reasoning——此為既有行為，dall-e-3 不接受圖輸入，維持現狀即可，不需本次處理）。

**擴充**：在同一個 `if` 區塊的條件加 regex，涵蓋 `dall-e-*` 與 `sensenova-u1-fast`（這兩個 id 不含 "image" 子字串）：

```dart
if (id.contains('image') ||
    RegExp(r'(dall-e-|sensenova-u1-fast)').hasMatch(id)) {
```

**不要**新增第二條並行的 image 推斷規則。不影響路由（路由依 id/覆寫，不依 output 能力），純粹是 picker 一致性。

### 步驟 7（Phase 2）：圖片比例選擇器（輸入列按鈕）

當使用者選擇的聊天模型被判定為圖片模型（`ChatApiService.shouldUseOpenAIImagesApi` 為 true——與步驟 1 路由判斷共用同一公開函式，F2）時，在輸入列動態顯示一個「比例」按鈕，點擊後彈出比例選項。

#### 7a. 比例選項與視覺預覽

支援以下五種預設比例，每個選項前放一個等比例縮放的小方框（`Container` 固定高度，寬度按比例計算），讓使用者一目瞭然：

| 選項 | 預覽方框示意 | 說明 |
|------|------------|------|
| 1:1  | ■（正方形）| 預設值 |
| 3:4  | ▮（直幅）  | 社群媒體常用 |
| 4:3  | ▬（橫幅）  | 傳統照片 |
| 16:9 | ▬▬（寬橫幅）| 桌布、影片封面 |
| 9:16 | ▮▮（高直幅）| 手機桌布、Story |

視覺預覽實作：每個選項以固定高度（如 16px）的 `Container`，寬度 = `高度 * (w/h)`，加 1px 邊框（`cs.onSurface.withOpacity(0.4)`）+ 圓角，排列在文字標籤左側。

#### 7b. 狀態持久化

檔案：`lib/core/providers/settings_provider.dart`

- 新增 `imageAspectRatio` getter/setter，持久化鍵 `image_aspect_ratio_v1`，預設 `'1:1'`。
- 該設定為全域（非 per-model），因為使用者的比例偏好通常跨模型一致。
- **service 不直接讀取**（F3）：由輸入列/呼叫端讀取後經 `sendMessageStream(..., imageAspectRatio: ...)` thread 進 service（步驟 1 已定義）。

#### 7c. 輸入列按鈕

檔案：`lib/icons/lucide_adapter.dart`（**F1**）

- **新增映射**：`static const IconData Ratio = lucide.LucideIcons.frame;`（鎖定版 `lucide_icons_flutter 3.1.15` 有 `frame`——四角括號矩形，最貼近「比例」語意；`crop` 為備選）。**`Lucide.RatioIcon` 不存在**，不可直接引用。

檔案：`lib/features/home/utils/chat_input_button_catalog.dart`

- `chatInputButtonCatalog` 在 **`'model'` 之後**插入 `ChatInputButtonSpec(id: 'imageRatio', icon: Lucide.Ratio, label: _imageRatioLabel)`（F9 實作細節：`chatInputButtonEffectiveOrder([])` 回傳 catalog 順序且測試要求其等於 `chatInputButtonDefaultOrder`，因此 catalog 與 default order **都**必須把 `imageRatio` 放在 model 之後——只加 default order 會破壞既有測試不變量）。
- **`chatInputButtonDefaultOrder` 在 `'model'` 之後插入 `'imageRatio'`**（F9）。用戶仍可在「自訂輸入列按鈕」頁重新排序或隱藏它。

檔案：`lib/features/home/widgets/chat_input_bar.dart`

- 在 `_buildResponsiveBottomRow`（`:783`）的 `actions` 清單中，當 `_shouldShowImageRatioButton()` 為 true 時插入 `imageRatio` 的 `_OverflowAction`（id 與 catalog 一致；排序/隱藏由既有 `hiddenIds` + `chatInputButtonEffectiveOrder` 機制處理，`:1257`–`:1265`）。
- `_shouldShowImageRatioButton()` 判斷邏輯（**單一來源，F2**）：讀取目前 provider config 與 modelId（`currentProviderKey`/`currentModelId`/`cfg`，`:847`–`:855` 既有邏輯），直接呼叫 **`ChatApiService.isOpenAIImageOutputModel(cfg, modelId)`**（「是否圖片模型」的標準，**與開關無關**——關閉 Images API 後模型仍可能出圖，按鈕不消失；不要複製白名單或覆寫判斷）。
- 按鈕 icon 動態顯示目前選中的比例文字（如 `16:9`），或在空間不足時顯示 `Lucide.Ratio`。
- 點擊後在行動版彈出 bottom sheet，桌面版彈出 anchored popover，列出五個比例選項（含視覺預覽方框）。選中後寫入 `SettingsProvider.imageAspectRatio`。
- Gemini 系內嵌出圖（`responseModalities: ['TEXT','IMAGE']`）**不顯示**此按鈕——`shouldUseOpenAIImagesApi` 對 Gemini 一律 false，天然滿足（與步驟 1 路由一致）。

#### 7d. 比例到 API 參數的轉換

檔案：`lib/core/services/api/chat_api_service.dart`

在 `_sendOpenAIImagesStream` 內，以參數收到的 `imageAspectRatio`（**非直接讀 SettingsProvider，F3**）呼叫 `_imageApiSizeParam`，結果注入請求 body。**聊天補全路徑同樣注入**：`_sendOpenAIStream` 新增 `imageAspectRatio` 參數，圖片輸出模型且開關關閉（`useResponseApi != true`）時，送請求前以 `_applyOpenAIImagesSize` 注入 `size`/`aspect_ratio`（custom body 仍優先）——關掉開關的模型經聊天補全出圖時比例照常生效。

**`_imageApiSizeParam(String ratio, String modelId, ProviderConfig cfg)` 決策規則（F4）**——注意 `_sendOpenAIImagesStream` 的進入條件保證 kind 永遠是 `openai`，**不能用 kind 區分供應商**：

1. **custom body 優先**：`_applyOpenAIImagesExtraBody` 之後，若 body 已含 `size`／`image_size`／`aspect_ratio` 任一鍵 → 回傳空 map，不注入（使用者進階分頁的自訂 key-value 覆蓋自動轉換；與風險章節一致）。
2. **`useAspectRatioParam == true`（per-model 覆寫旗標，設計決策 5）** → 回傳 `{'aspect_ratio': ratio}`（原生支援 `aspect_ratio` 的供應商，如 Nano Banana 2）。
3. **其他走 Images API 的模型**（輸出含圖片，含依 id 推斷的圖片家族）→ 依表格回傳 `{'size': ...}`：

| 比例 | `size` 值 | 備註 |
|------|----------|------|
| 1:1  | `1024x1024` | 所有模型通用 |
| 3:4  | `1024x1360` | 1360 ÷ 16 = 85 ✓（gpt-image-2 任意解析度） |
| 4:3  | `1360x1024` | 同上 |
| 16:9 | `1792x1024` | dall-e-3 / gpt-image-2 均支援 |
| 9:16 | `1024x1792` | 同上 |

   **dall-e-3 回退**：僅支援 `1024x1024`、`1792x1024`、`1024x1792` 三種，3:4 / 4:3 不支援——3:4 → `1024x1792`、4:3 → `1792x1024`。回退發生時**不顯示 SnackBar**（service 無 BuildContext，F5），改在 `_sendOpenAIImagesStream` 把附註附加於回覆 markdown 之後：`![image](path)\n\n> Note: dall-e-3 does not support 3:4/4:3; used <size>.`（固定英文短句，避免把 locale 也 thread 進 service）。
4. **依 id 推斷的輸出含圖片模型（如 SiliconFlow FLUX，於基本設定頁勾選輸出「圖片」）** → 回傳 `{'size': 表格值}`；供應商 API 若用不同參數名（如 SiliconFlow 的 `image_size`），以自訂 body key-value 設定（規則 1 覆蓋）。不開 `useAspectRatioParam` 就**不會**送 `aspect_ratio`。

#### 7e. 本地化字串

檔案：`lib/l10n/app_en.arb`、`app_zh.arb`、`app_zh_Hans.arb`、`app_zh_Hant.arb`（全部補齊，F7）

- `chatInputBarImageRatioTooltip`："Image Ratio" / "圖片比例"
- `imageRatioOption1x1`："1:1 Square" / "1:1 正方形"
- `imageRatioOption3x4`："3:4 Portrait" / "3:4 直幅"
- `imageRatioOption4x3`："4:3 Landscape" / "4:3 橫幅"
- `imageRatioOption16x9`："16:9 Widescreen" / "16:9 寬螢幕"
- `imageRatioOption9x16`："9:16 Vertical" / "9:16 直式"

## 修改檔案總表

| 檔案 | 變更 |
|---|---|
| `lib/core/services/api/chat_api_service.dart` | 步驟 1（路由分支 :826 前 + `imageAspectRatio` 參數）、2（移植 ~24 個 static 方法 + `_OpenAIImagesInput`，含公開 `shouldUseOpenAIImagesApi`）、3a（generateText 守護 :903）、7d（`_imageApiSizeParam` 比例轉換） |
| `lib/features/model/widgets/model_detail_sheet.dart` | 步驟 4（mobile：狀態/initState/tools 頁開關/save，`useImagesApi`（預設開啟）＋`useAspectRatioParam`，皆輸出含圖片才顯示） |
| `lib/desktop/model_edit_dialog.dart` | 步驟 4（**desktop，F6**：狀態/initState/tools 開關/save，`useImagesApi`（預設開啟）＋`useAspectRatioParam`，皆輸出含圖片才顯示） |
| `lib/core/providers/model_provider.dart` | 步驟 6（擴充既有 `contains('image')` 區塊，F8） |
| `lib/core/providers/settings_provider.dart` | 步驟 7b（`imageAspectRatio` getter/setter + 持久化） |
| `lib/icons/lucide_adapter.dart` | 步驟 7c（新增 `Lucide.Ratio = frame` 映射，F1） |
| `lib/features/home/utils/chat_input_button_catalog.dart` | 步驟 7c（新增 `imageRatio` 規格 + **default order 插入 model 之後，F9**） |
| `lib/features/home/widgets/chat_input_bar.dart` | 步驟 7c（圖片模型判斷、比例按鈕渲染、選項 sheet/popover；按鈕以 `Lucide.Ratio` 圖示＋tooltip 顯示目前比例，overflow 到 `+` 選單時回退居中 dialog） |
| `test/openai_images_api_test.dart` | 新增（移植 kelivo 案例 + `isOpenAIImageOutputModel`（含開關關閉仍為圖片模型）/`isOpenAIImageEditModel`（input+output 為編輯模型、dall-e-3/sensenova 非編輯、override 覆寫、非 OpenAI kind 拒絕）/shouldUseOpenAIImagesApi（id 推斷/override output 覆寫/`useImagesApi: false` 關閉/預設開啟/非圖片模型不可 opt-in/非 OpenAI kind 拒絕）/開關關閉走 `/chat/completions` 且注入 size/比例 size 注入/dall-e-3 回退附註/useAspectRatioParam/custom body 優先，共 31 案例） |
| `test/settings_provider_image_ratio_test.dart` | 新增（`imageAspectRatio` 預設/round-trip/notify，3 案例） |
| `lib/core/services/chat/chat_turn_service.dart` | 步驟 1（傳 `imageAspectRatio`，F3） |
| `lib/features/home/controllers/chat_actions.dart` | 步驟 1（兩處傳 `imageAspectRatio`，F3） |
| `lib/features/home/services/ocr_service.dart` | 步驟 1（傳 null）+ 3b（守護，F11） |
| `lib/features/home/services/translation_service.dart` | 步驟 1（傳 null）+ 3b（守護，F11） |
| `lib/l10n/app_en.arb` 及 `app_zh.arb` / `app_zh_Hans.arb` / `app_zh_Hant.arb` | 步驟 5（4 個新字串 × 4 語系）、7e（6 個比例相關字串 × 4 語系）＝淨 +10 鍵 × 4 語系；重新生成 `app_localizations*.dart` |

## 驗證

1. 文生圖：在某 OpenAI 相容供應商新增 `dall-e-3` 模型，送「一隻貓」，預期回覆含 `![image](本地路徑)`，圖片渲染、點擊開啟 `ImageViewerPage`。
2. 輸出模式路由＋預設開啟：在 SiliconFlow 新增 FLUX 模型、於基本設定頁勾選輸出「圖片」，工具頁「使用 Images API」開關預設開啟，送 prompt，預期圖片產出；關閉開關後同模型改走聊天補全（驗證開關語意）。
3. 圖生圖/編輯：對 `gpt-image-1` 模型附一張圖＋prompt，預期走 `/images/edits` 並回傳編輯後圖片。
4. 疊代編輯：在同一對話延續，只送文字 prompt（不附圖），預期 `_lastAssistantImageBefore` 回退抓上一張生成圖做 `/images/edits`。
5. 回歸：一般聊天模型（如 `gpt-4o`，輸出僅文字）→ 仍走聊天補全，不受影響。
6. 誤用守護：把圖片模型設為標題/摘要模型，觸發標題生成 → 不崩潰（`generateText` 回 `''`）；**設為聊天模型後觸發 OCR/翻譯 → 回傳空文字/原文，不出圖（F11）**。
7. 比例按鈕顯隱：選擇一般聊天模型（如 `gpt-4o`，輸出僅文字）→ 輸入列無比例按鈕；切換至輸出含圖片的模型（如 `dall-e-3`，或基本設定頁勾選輸出「圖片」的 FLUX）→ 比例按鈕出現；**關閉「使用 Images API」開關後按鈕仍在**（模型仍是圖片輸出、可能經聊天補全出圖，且比例照常注入 `/chat/completions`）。**Gemini 系內嵌出圖模型不顯示**（kind 非 openai）。
8. 比例轉換（OpenAI 系）：選擇 `gpt-image-2` + 比例 `16:9`，送 prompt → 檢查 API 請求 body 含 `"size": "1792x1024"`，生成圖片為橫幅。
9. 比例轉換（dall-e-3 回退）：選擇 `dall-e-3` + 比例 `3:4`（不在 dall-e-3 合法清單）→ 自動回退為 `1024x1792`，**回覆文字含 fallback 附註（非 SnackBar，F5）**。
10. 比例直傳（`useAspectRatioParam` 覆寫）：對支援 `aspect_ratio` 的供應商模型開啟 `useAspectRatioParam` + 比例 `9:16` → 檢查 API 請求 body 含 `"aspect_ratio": "9:16"`；**未開啟該旗標的 FLUX 不應送 `aspect_ratio`（F4）**。
11. custom body 覆蓋：在模型進階分頁手動設 `size` 或 `aspect_ratio` key-value → 請求 body 以自訂值為準，比例按鈕不注入。
12. 靜態檢查：`flutter analyze` 通過（全專案僅既有 vendored `speech_to_text_windows` example 2 個 error）；4 個 arb 補齊後 `flutter gen-l10n` 重新生成 `app_localizations*.dart`（本 repo 無 CI untranslated 檢查腳本，F7）。
13. **桌面端（F6）**：桌面模型編輯 dialog 的 openai 模型輸出含「圖片」時顯示「使用 Images API」（預設開啟）與「使用 aspect_ratio 參數」開關，儲存後重開仍保留、關閉 Images API 後重開仍為關閉；FLUX（桌面新增，輸出勾圖片）走 Images API 出圖。
14. 收尾契約（F12）：Images API 回覆後對話正常結束（`isDone` chunk 到達、`_handleStreamDone` 正常收尾）；dall-e 生成後 token 統計顯示 0 不崩潰。

## 風險與注意

- **`_ImageRef` 共用**：OmniChat 的 `_parseTextAndImages` 產出 `_ImageRef`，移植的 images 函式也消費同一型別——不可重複定義。mime 皆以 `_mimeFromPath`/`_mimeFromDataUrl` 推導。
- **`_customBody` 回傳值若含非純量需確認既有解析（`_parseOverrideValue`，`:300`）**；Images API 的 `size`/`quality`/`n`/`output_format` 等參數可由使用者在模型「進階」分頁以自訂 body key-value 設定，毋須新增 UI。
- **multipart 上傳（`/images/edits` 本機檔）**：`DioHttpClient.send()` 已實作，直接走 `_clientFor` 的 client（保留 proxy 設定）；注意 body 全量 in-memory 緩衝（F10）。
- **判斷一致性**：比例按鈕與守護用公開 `isOpenAIImageOutputModel`（「是否圖片模型」單一標準，與開關無關）；路由用 `shouldUseOpenAIImagesApi`（F2）。Gemini 系內嵌出圖的 `responseModalities` 不接受 size/aspect_ratio 參數，天然不顯示比例按鈕。
- **dall-e-3 固定 size**：僅 `1024x1024`/`1792x1024`/`1024x1792`，3:4/4:3 回退至最接近合法值並以回覆附註提示（F5）。
- **custom body 優先**：使用者手動設的 `size`/`image_size`/`aspect_ratio` 優先於比例按鈕自動轉換（`_imageApiSizeParam` 規則 1）。
- **service 為純 static**：所有需要使用者設定的值（比例）一律由呼叫端參數傳入，service 不讀 `SettingsProvider`（F3）。
- **桌面與行動版模型編輯器是兩份獨立實作**：`useAspectRatioParam` 開關必須在兩邊都做，且都以「輸出模式含圖片」為顯示條件（F6）。

## 修訂紀錄（review F1–F13）

| # | 問題 | 修正落點 |
|---|---|---|
| F1 | `Lucide.RatioIcon` 不存在 | 7c：adapter 新增 `Lucide.Ratio = lucide.LucideIcons.frame` |
| F2 | private `_shouldUseOpenAIImagesApi` 跨檔不可見 | 設計決策 3、步驟 2、7c：公開 `isOpenAIImageOutputModel`（按鈕/守護，與開關無關）與 `shouldUseOpenAIImagesApi`（路由）兩層函式（最終定案） |
| F3 | static 讀不到 `SettingsProvider` | 設計決策 4、步驟 1、7d：`sendMessageStream` 新增參數 + 4 個 call site |
| F4 | `kind` 永遠是 openai，aspect_ratio 直傳判別失效 | 設計決策 5、7d：`useAspectRatioParam` 覆寫旗標 |
| F5 | service 層無法顯示 SnackBar | 設計決策 6、7d：改為回覆 markdown 附註 |
| F6 | 桌面模型編輯器漏掉 | 步驟 4、檔案總表、驗證 13：`model_edit_dialog.dart` |
| F7 | CI untranslated 腳本不存在 | 步驟 5、7e：移除錯誤宣稱，仍補齊 4 個 arb |
| F8 | 步驟 6 與既有 `contains('image')` 重疊 | 步驟 6：擴充既有區塊，不新增並行規則 |
| F9 | 「model 之後」與 effective order 不符 | 7c：`chatInputButtonDefaultOrder` 插入 `imageRatio` |
| F10 | multipart fallback 不必要 | 步驟 2 適配表：確認 `DioHttpClient.send` 已實作，移除 fallback |
| F11 | 守護只蓋 `generateText` | 步驟 3b：OCR/翻譯同步守護 |
| F12 | 收尾 chunk 契約未定義 | 步驟 2：`isDone: true` + null-safe usage |
| F13 | 範圍過大 | 設計決策 6：分 Phase 1（步驟 1–6）與 Phase 2（步驟 7） |
