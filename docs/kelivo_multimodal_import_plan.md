# OmniChat 上游 multimodal（音訊／影片／PDF 輸入）導入評估與計畫

> **版本**：v1.2（2026-11-06 落地紀錄）  
> **日期**：2026-11-05（v1.1 審查）／2026-11-06（v1.2 實作）  
> **狀態**：**Phase 0 + A + B + C 已實作（2026-11-06）**；Phase D（錄音）未做。實作摘要與與計畫的差異見下方「落地紀錄」。  
> **範圍**：上游 [Chevey339/kelivo](https://github.com/Chevey339/kelivo) 自 OmniChat fork 點（`d5a134ef1`，2026-01-03）之後新增的 **chat 訊息多模態輸入** 能力：native audio/video/PDF 輸入（`917ec2bc7`）、錄音與音訊播放（`0b0e4ce62`）、ModelSpec modality 能力層（`ab14b0734`／`e89b0d5bb`／`f1813db92`）、附件結構化儲存（`58afd0162`／`a0927b49f`）、圖片上下文管理（`249902b5`／`12af1d1a`／`af62cecb` 等）。  
> **非範圍**：ASR 轉錄擴充（另案 `docs/speech_recognition_import_plan.md`）；Gemini Live／TTS 樞紐（OmniChat §3.3 已有自家實作）；v1.3.2–v1.3.4 已評估項目（見 `docs/kelivo_v1.3.2_v1.3.4_import_plan(已實作).md`）；workspace 圖片檢視工具（`c58cc4a19`，屬工作區功能另議）。  
> **相關文件**：`OmniChat 專案開發與維護手冊.md` §3.5（模型適配／目錄）、§3.6（Images API）、§3.8（備份）、§5.3（5-Hook 與 content 形狀守衛）、§5.4（記憶體防暴衝）、**§3.21（本功能落地架構）**；`docs/kelivo_v1.3.2_v1.3.4_import_plan(已實作).md`；`docs/speech_recognition_import_plan.md`。

### 落地紀錄（v1.2，2026-11-06）

- **已完成**：Phase 0（audio MIME／跳過萃取／清 marker）、A（Modality 五值、目錄投影、單一 override parser、UI toggles/badges）、B（`native_input_parts` 四協議、attachment profile、policy/host gate、四 transport、body2 `chatWireMessages`、allowlist、encoded 預算）、C（gate＋snackbar、`AudioClipPlayer`、unavailable 卡、composer 灰態）。
- **與計畫的實作差異**：
  1. 沒有另做「neutral messages → wire messages」轉換器；改為 assembly 時一次性序列化 `_native_input {protocol, parts}`，各 transport 只 append 已序列化 parts，body2 由 `chatWireMessages`（已序列化的 `mm`）重建。功能等價，且 encode 只做一次。
  2. `_encodeBase64File(maxBytes:)` 未保留；大小預算集中在 `NativeInputParts`（單檔 raw 10 MB、單訊息 encoded 18 MB）。
  3. C1 的入口過濾以 **composer 灰態（warning icon＋tooltip）＋送出前 warning** 實作（單一「任意檔案」picker 沒有可隱藏的 audio/pdf 入口；為避免重複提示，不在挑選當下另跳 snackbar）。
- **行為變更／升級注意**：
  1. 音訊附件不再以 UTF-8 亂碼注入 `filePrompts`；模型不支援時整段不送（gate 會 warning）。
  2. 舊的 per-model override（沒有 `inputV: 2`）在載入時會自動補回推斷出的 `audio/video/pdf`；一旦以新版模型頁儲存（寫入 `inputV: 2`），使用者的明確移除才會被尊重。
  3. 純附件訊息若無 native parts 且無文字：歷史與當前訊息都以「附件無法送出」placeholder 保留（不 drop，避免 Gemini 空 parts／Claude 空 content，也避免刪除歷史 user turn 後出現 leading assistant turn）。
  4. Gemini 音訊只放行 wav/mp3/aiff/aac/ogg/flac；m4a/opus/pcm 會回 `attachment_unsupported_format`。
- **未做**：Phase D 錄音；實機 smoke（Windows/Android 真實帳號）；歷史 native 重放（V1 只末則）；圖片上下文治理（#1334）。

---

## 0. 摘要（TL;DR）

### 0.1 事實校正（先說清楚上游到底加了什麼）

1. **影片附件 OmniChat fork 時就已有**。上游影片支援是 2025-11 的舊功能（`2a9fbc77c`／`829660b2e`／`c5f2543e5`／`926f02def`），皆在 fork 點之前，本機已包含：`video_url`（Chat Completions）與 Gemini `inline_data` 路徑都在 `chat_api_service.dart`。**不需要重新導入**。
2. **上游沒有「模型原生音訊／影片輸出」**。本題（chat 多模態）在 fork 後的新工作都在**輸入面**；輸出面的音訊仍然是 TTS（`text_to_speech` 本地工具 + TTS 重播/匯出）。聊天回應 stream 不攜帶音訊 blob（`response.audio.delta` 在 decoder 被明確丟棄）。目錄雖有 `audioOutput`／`videoOutput` 值（78／68 筆），但上游不把它們當成 chat wire 的輸出面能力。
3. **真正的差距是四件事**（皆為 fork 後新增）：
   - **Native PDF 輸入**：OmniChat 目前一律把 PDF 走 `DocumentTextExtractor` 文字萃取——掃描式 PDF 完全無解、表格/版面全丟。上游以 provider 原生格式直送（目錄已把 claude/gemini/gpt 標了 `pdf` input）。
   - **音訊輸入**：OmniChat 目前**沒有 wire 支援**，但現況不是「靜默忽略」而是**更糟**：`DocumentTextExtractor` 對未知 MIME 一律以 UTF-8 解碼，`processUserMessagesForApi` 只跳過 `video/`，因此音訊附件會被當成文字（亂碼）注入 `filePrompts`，且**每一輪歷史訊息都重送**；`inferMimeByExtension` 也缺 `.mp3/.wav/.m4a` 分支（picker 選的音訊被標成 `text/plain`）。這是獨立於本計畫的 P0 現行 bug（§7 F2）。上游支援 Chat Completions `input_audio` 與 Gemini `inline_data`。
   - **Modality 能力層**：上游 ModelSpec 的 `Modality {text,image,audio,video,pdf}` + `supportsXxxInput` 閘門；OmniChat 的 `Modality` enum 只有 `{text,image}`，目錄 JSON 裡的 `audio`/`video`/`pdf` 值**有解析、但 `CatalogModel` 只投影出 `imageInput` 後丟掉**（`model_catalog.dart` L271-272）。
   - **附件/圖片的上下文治理**：上游 11 月以 #1334 做了 bounded image context（預算、pin、restore、per-conversation recall）；OmniChat 的「OCR 關閉時歷史 `[image:]` 每輪全數重放」是同類問題的未治理狀態。

### 0.2 結論：建議「分層部分導入」

| # | 上游項目（commit） | 判斷 | 優先級 | 主要理由 | 估時 |
|:--:|:---|:--:|:--:|:---|:--:|
| 1 | Native PDF／音訊輸入（`917ec2bc7`） | **導入（OmniChat 原生重寫）** | **P1** | 新能力類別；目錄資料已標好；wire 格式已被上游驗證 | 7–10 人日（審查後） |
| 2 | Modality 能力層消費（`ab14b0734` 的行為面，不是架構） | **導入（目錄投影擴充）** | **P0 前置** | 目錄 `audio/video/pdf` 資料已在、只差消費；是 #1/#3/#5 的共同基礎 | 3–4 人日（審查後） |
| 3 | 附件依模型 modality 閘門（`e89b0d5bb`，簡化版） | **導入（簡化版）** | **P1** | 防做白工與 provider 400；不含上游 home controller 大改 | 2 人日 |
| 4 | 音訊播放卡與附件 unavailable 狀態（`0b0e4ce62` UI 面） | **導入** | P2 | 音訊輸入的使用者可感知一半；播放器元件可移植 | 2–3 人日 |
| 5 | 錄音附件（不需 ASR 的錄音，`0b0e4ce62` 錄音面） | **部分導入** | P2/3 | OmniChat 已有麥克風管線（Live API 與聽寫），WAV 擷取可共用；先檔案後錄音 | 3–5 人日 |
| 6 | ModelSpec 架構整體（1019 行 `model_spec.dart` + resolver + guesser + provider 分層重構） | **不導入** | — | OmniChat 已有「目錄 + override 階梯」（§3.5 §6），只吸收行為規則 | — |
| 7 | 附件結構化儲存重構（`58afd0162`/`a0927b49f`，Hive→parts + kelivo-file URIs） | **不導入** | — | OmniChat 剛完成自己的 SQLite `message_parts` 底座（§3.18），上游的重構前提不存在 | — |
| 8 | 圖片上下文管理（`249902b5`/`12af1d1a`/`af62cecb`，#1334） | **暫緩另案** | P3 | 獨立大功能（repository + 檢查器 + 面板 UI）；且 OmniChat 先要量化現狀成本 | 另案 |
| 9 | TTS 本地工具 `text_to_speech` + TTS 匯出（`e6b5de5cc`/`29c52236a`） | **暫緩另案** | P3 | OmniChat TTS 為 UI 驅動；「agent 會說話」是新產品形態，非本題 multimodal | 另案 |

### 0.3 最重要的一件事

**OmniChat 的目錄資料層與上游同源（models.dev），卻把多模態能力丟掉了。** `assets/model_catalog/models_dev.json` 已收錄 `pdf`（如 `claude-fable-5` input `[text,image,pdf]`）、`video`（`minimax/MiniMax-M3`）、`audio` 等值；`_pruneModel`（`model_catalog.dart` L613-627）也**原樣保留**這些 modality 清單；唯獨 `CatalogModel` 建構時只取 `input.contains('image')`／`output.contains('image')` 兩個 bool（L271-272）。也就是說 **P0 只要補上投影與消費端，就能讓整條能力階梯（目錄 → regex → per-model override）取得 pdf/audio/video 三個輸入維度**。但要留意「免費」只對資料層成立：`CatalogModel` 目前是純 Dart、不可反向 import `model_provider` 的 `Modality`；且 `ov['input']`／`ov['output']` 有 5 個各自把未知值映射成 `text` 的 ad-hoc 解析器（§7 F6/F7），投影與 override 必須一起改，否則是無聲降級。

### 0.4 建議順序與工作量

```text
Phase A（P0 能力層前置）
  ├─ A1 CatalogModel/Modality 擴充 audio/video/pdf 輸入投影 + regex fallback
  ├─ A2 per-model override：沿用 modelOverrides[id]['input']／['output'] + 集中 parser
  └─ A3 模型詳情頁 input/output toggles + 三處 badge（l10n ×4）
        ↓
Phase B（P1 wire 層）
  ├─ B1 附件剖面：user 訊息的 audio/pdf 附件以 neutral 形狀掛進訊息（V1 不含 video）
  ├─ B2 新 native_input_parts（純 Dart）：四協議序列化 + 訊息轉換器 + 格式/大小守衛
  ├─ B3 四 transport 接入（主 body + 各 transport follow-up；§5.3 的 generateText 不吃附件，不列入）
  ├─ B4 _encodeBase64File encoded 預算（單檔 raw ≤10 MB、單訊息 encoded ≤18 MB）與結構化錯誤
  └─ B5 native PDF 時跳過文字萃取（對應上游 nativePdfInput）
        ↓
Phase C（P1/P2 UI）
  ├─ C1 附件 modality 閘門（picker 過濾 + 送出剝除 + snackbar）
  ├─ C2 AudioClipPlayer（移植/重寫）＋訊息與 composer 卡
  └─ C3 附件卡 unavailable 狀態（檔案缺失／includeFiles 關閉／跨裝置路徑失效）
        ↓
Phase D（P2/P3 錄音）
  └─ D1 共用錄音 session（16 kHz/16-bit mono → WAV）＋錄音鈕（門：supportsAudioInput）
```

| 階段 | 範圍 | 估計 |
|:--|:--|:--:|
| Phase A | A1–A3（含 5 個 override 解析器收斂） | 3–4 人日 |
| Phase B | B1–B5（含 body2 保存、guard allowlist、AI Team 政策） | 7–10 人日 |
| Phase C | C1–C3 | 3–4 人日 |
| Phase D | D1（`record` 已在 pubspec） | 3–5 人日 |
| **合計** | A+B+C（不含錄音） | **13–18 人日** |
| **合計** | A–D 全部 | **16–23 人日** |

> 另建議 Phase 0（0.5–1 人日）：先修 §7 F2 的音訊亂碼 bug（audio MIME + 跳過萃取 + 清 marker）。這是現行資料污染，不修的話 Phase B 的測試基線會被歷史亂碼干擾。

---

## 1. 上游變更盤點（fork 點之後）

### 1.1 核心功能 commit（多模態輸入）

| commit | 日期 | 內容 |
|:--|:--|:--|
| `58afd0162`／`a0927b49f` | 2026-08-09/10 | 訊息附件改為 **structured parts**（Hive 欄位棄用，改 DB parts + `kelivo-file://` URIs）；隨後一整串附件 migration 契約修補（`40b6e8e0e`／`01e896803`／`7ad1693d1`／`7438242e7`／`acfee09a5`／`966e3f0d7`／`685707362`）。**上游自己的儲存遷移；OmniChat 已有 `message_parts` 底座，前提不存在** |
| `ab14b0734` | 2026-09-15 | **ModelSpec P0**：`Modality{text,image,audio,video,pdf}`、`ModelAbility{tool,reasoning,structuredOutput}`、`supportsAudioInput/VideoInput/PdfInput`、maxOutput/cost/limit 齊聚 `model_spec.dart`（1019 行）+ `model_spec_resolver`（709 行）+ `model_defaults_guesser`（1095 行）+ 目錄 service 重寫 |
| `f1813db92` | 2026-09-15 | P3：桌面 ModelSpec 編輯 dialog + 模型標籤（tag wrap 顯示 audio/video/pdf） |
| `e89b0d5bb` | 2026-09-15 | P3：**附件依模型 input modalities 閘門**（`attachment_modality_gate.dart` 46 行 + 送出剝除 `strip_unsupported_media` + 入口 UI 過濾） |
| `917ec2bc7` | 2026-09-28 | **Native audio/video/PDF inputs**（主體，見 §1.2 wire 格式）+ `native_input_attachments.dart`（230 行） |
| `0b0e4ce62` | 2026-09-30 | **錄音與播放**：`asr_audio_capture` 分離錄音 session、輸入列錄音鈕（~210 行）、`AudioClipPlayer`（247 行）、composer/訊息卡播放控制；「不需 ASR 即可錄音附件」 |
| `aa5211cdf` | 2026-09-16 | Draft 持久化含不支援 media、請求時剝除 |
| `52c480984`／`08f61a6f0` | 2026-09-10／2026-03-16 | `deepseek-flash`、LongCat Omni 判為 multimodal——**OmniChat 靠目錄即可覆蓋，不需導入** |
| `2f6dedb49`／`1cda03cd1` | 2026-10-31 | workspace 附件路徑、附件鎖——上游 infra，非本題 |

### 1.2 wire 格式（`native_input_attachments.dart`，已被上游驗證）

依協議（`NativeInputProtocol`）與 ModelSpec 閘門（不支援的型別直接 skip）：

| 協議 | PDF | 音訊 | 影片 | 限制/例外 |
|:--|:--|:--|:--|:--|
| **Chat Completions** | `{'type':'file', 'file':{filename, file_data:'data:application/pdf;base64,…'}}`；遠端 URL 僅 OpenRouter 放行（`file_data: <url>`） | `{'type':'input_audio','input_audio':{'data': <b64 或 DashScope 特例加 data: 前綴>, 'format': …}}`；format 白名單 `wav/mp3/m4a/aac/flac/ogg/opus/aiff/pcm16`；**`api.openai.com` 只收 wav/mp3，其餘 host 允許擴充格式**；遠端音訊僅 DashScope 放行 | `{'type':'video_url','video_url':{'url': data URI 或遠端}}`；**`api.openai.com` 明確 throw** | 本機檔 base64；`data:` 前綴直解 |
| **Responses** | `{'type':'input_file', file:{…}}`：本機 → `file_data` data URI + filename；遠端 → `file_url` | **不支援（throw）** | **不支援（throw）** | — |
| **Claude** | `{'type':'document', title, source:{type:'base64'|'url', …}}`；**Vertex 只能本機檔（throw）** | **不支援（throw）** | **不支援（throw）** | OmniChat 建議再加：claude-compatible relay 僅走文字萃取（比照 §3.16 §8 host-gate 慣例） |
| **Gemini** | `inline_data{mime_type,data}`（本機）或 `file_data{file_uri,mime_type}`（非 Vertex：**僅** `generativelanguage.googleapis.com` 的 Files API URI；Vertex 模式接受任意 http(s) 遠端 URL；其他遠端 throw） | 同上；mime 正規化（`audio/x-m4a→audio/m4a`、`video/quicktime→video/mov` 等） | 同上 | 遠端檔在 OmniChat 無 Files API 整合 → 一律結構化錯誤 |

> 注：上表是上游 `917ec2bc7` 的**實作契約**，不是供應商官方文件全文；OpenAI `input_audio` 的可用格式／大小上限未經官方文件核實（§7 V9），落地時以官方 schema＋實測為準。

上游選擇「不支援就 **throw UnsupportedError**」讓 transport 冒出明確錯誤；OmniChat 對應策略見 §2.5 設計（組裝期剝除 + snackbar，不讓例外冒泡——§5.6 慣例）。

### 1.3 圖片上下文管理（#1334，暫緩另案的理由）

`249902b5`（bounded image context：預算投影、independent tool 觀察、前綴穩定）、`12af1d1a`（desktop/mobile UI，+820 行）、`af62cecb`（per-conversation image recall control）、`79c03995`（圖片會話用量估算）——需要 `chat_image_context_repository`（128 行 DB 層）+ `image_context.dart`（183 行模型）+ `request_image_context.dart`（image budget 投影）+ `image_context_panel`（600+ 行 UI）+ fork/summary/backup 生命週期整合。**與附件 modality 輸入是不同工程**；OmniChat 的「歷史圖片全重放」成本問題（OCR off 時）應先量化再決定，見 §2.4。

---

## 2. 逐項評估與 OmniChat 導入方案

### 2.1 A／能力層：目錄投影擴充 + regex fallback + override（P0）

**OmniChat 現況**

- `Modality {text, image}`（`lib/core/providers/model_provider.dart` L21）；`ModelInfo.input/output` 只裝這兩值。
- `ModelCatalog._pruneModel` 保留完整 `modalities.input/output` 陣列；`CatalogModel` 構造丟掉 audio/video/pdf（L271-272 只投影 `imageInput/imageOutput`）。
- regex fallback 層（`ModelRegistry.vision` 等）沒有 audio/video/pdf 家族規則；`reasoning_capabilities.dart` 只管推理預算，不是 modality 家族規則的落點（§7 F7）。
- `ChatApiService` 的能力判定 `canImageInput = info.input.contains(Modality.image)`（L2807 等）已是一個可複製的模式。

**設計（OmniChat 原生；不搬上游 ModelSpec）**

1. `enum Modality { text, image, audio, video, pdf }`（與上游同序同名，目錄字串映射直接）。`ModelAbility` 不動（OmniChat 的 tool/reasoning 已走自己的階梯）。**注意**：`Modality` 只用於 `ModelInfo`（不進 Hive／SQLite），新增值不會觸發 schema 遷移；但所有 `mod == Modality.text ? A : B` 的 badge 三元式要逐一改（`model_select_sheet` L1143/1149、`provider_detail_page` L2765/2771），否則 audio/video/pdf 會顯示成 image icon。
2. `CatalogModel`：**不要**直接回傳 `List<Modality>`。`model_catalog.dart` 是刻意的純 Dart 層（檔頭註明 no Flutter imports），而 `model_provider.dart` 已 import 它；反向 import 會形成循環。建議 `CatalogModel` 保留 `Set<String> inputModalities`／`outputModalities`（或三個 bool），由 `_inferWithCatalog` 映射成 `Modality`。
3. `ModelRegistry`／`_inferWithCatalog`：目錄命中時把 `inputModalities` 映射進 `ModelInfo.input`；regex fallback 新增最小家族規則（目錄為準、只補 miss；regex 只在 catalog miss 時執行，這是現行 early-return 語意）：
   - audio input：`qwen.*(omni|audio)`、`gemini-.*(audio|native-audio|omni)`、`gpt-4o.*audio`、`step.*audio`、`glm.*(omni|audio)`。
   - pdf input：`gemini-\d`、`claude`、`gpt-(4\.1|4o|5)`、`grok-\d`。
   - video input：`gemini-\d`、`qwen.*(vl|omni)`、`minimax-m3`、`doubao`、`step-3`、`glm-4.?v`。
4. **per-model override**：**沿用既有的 `modelOverrides[key]['input']`／`['output']` 字串陣列**（已有 5 個讀取器 + `model_detail_sheet` 寫入器），不要另開 `modalities` 鍵造成雙真相。把 5 處 `(e == 'image' ? Modality.image : Modality.text)` 收斂成共享 parser（放 `model_provider.dart` 或 `ModelRegistry`），未知值不再默默變 `text`；`{v:1}` 版本欄位可保留在既有 override map 內，與 reasoning override 同形。優先序 user override > 目錄 > regex；**負向能力要明確定義**（現行 catalog 分支只「加」image、不「移除」，audio/pdf 的 `false` 不會蓋掉 regex／override 的 `true`）。
5. **混淆面檢查**：`Modality` 擴充後 Images 路由（§3.6）與遠端圖片閘仍只檢查 `Modality.image`，不受影響；models.dev `modalities.output` 刻意不用於 `/images` 路由的政策**維持**（audio 進 output 不會誤路由）。但 `audioOutput/videoOutput` 會進模型 badge，建議只顯示 input 能力，避免暗示原生輸出。

**測試**：`test/core/model_catalog_test.dart` 補 audio/video/pdf 投射；`model_provider` infer fallback 案例；override 持久化/合併（照 `test/model_override_persistence_test.dart` 模式）；5 個 parser 的一致性；能力 toggles／badge l10n。

### 2.2 B／wire 層：native input parts（P1 主體）

**OmniChat 現況（附件管線的事實邊界）**

1. 附件以 marker 存於訊息內容：`[image:<path>]`、`[file:<path>|<name>|<mime>]`（`message_builder_service.dart` L285-328）。SQLite 遷移不動內容（§3.18），marker 體系原樣成立。
2. `processUserMessagesForApi`（同檔 L355 起）對**每則** user 訊息：文件 → `DocumentTextExtractor` 文字萃取注入 filePrompts；**只有 video 被跳過**（`if (mime.startsWith('video/')) continue;`）。**audio 沒有跳過**：`DocumentTextExtractor` 對未特別處理的 MIME（含 audio）走 `utf8.decode(bytes, allowMalformed: true)` fallback，所以音訊會被當成亂碼文字注入（且歷史每輪重送）。`inferMimeByExtension` 也沒有 audio 分支（`.mp3/.wav/.m4a` → `text/plain`）；`mimeForSharedFile` 雖有 audio，但 extractor 仍會落到文字 fallback。這是 §7 F2 的 P0 現行 bug。
3. `merged`（filePrompts+cleanedText）**回寫覆蓋** `apiMessages[i]['content']`：`[file:]` marker 一律移除，但 **filePrompts 仍會為歷史 PDF 重新萃取文字並每輪重送**；音訊則以亂碼文字重送；只有「native wire 形式」不存在。`[image:]` 只在 OCR 開啟時被移除 → **OCR off 時歷史圖片每輪全數 base64 重放**。
4. 末則訊息的影片經 `message_generation_service.buildUserImagePaths`（L587-592）併入 `userImagePaths`；chat-completions 路徑按 mime 分流 `image_url`／`video_url`（L3450-3460），Gemini 路徑 inline_data（L8360-8390，video mime 可通）；Responses/Claude 無。**B1 不可再把 video 放進 `_attachments`，否則末則影片會重複送**（§7 F5）。
5. `_encodeBase64File`（chat_api_service L1252）`readAsBytes` **無大小上限**——影音大檔 base64 直上請求體；`withPrefix:true` 的 MIME 由 `_mimeFromPath` 決定，而該函式對 audio/pdf 會回 `image/png`（B4 必須用 attachment mime 自建 data URI，或先擴充 `_mimeFromPath`）。
6. PDF 只有文字萃取一條路（`chat_api_service.dart` 全文無 pdf wire 處理；掃描 PDF 只會得到 `[PDF] Unable to extract text from file.` notice）。

**設計**

1. **附件剖面（B1）**：`processUserMessagesForApi` 解析各 user 訊息時，把 **audio/pdf**（V1 不含 video，見下）附件組成 `{path, name, mime, type}` 清單，以 **neutral 訊息內鍵**（如 `_attachments`，比照 §3.11 neutral 形狀精神與 §3.16 先例「capability 資料不進 persist」）掛在該則訊息 map 上。**邊界守門**：`[image:]` 的 decoded base64 圖片路徑**保持現狀**（不動圖片通路，零回歸）；video 仍走既有 `userImagePaths`，不得重複。另需在 `_preserveToolStructuredMessages` 保留 `_attachments`（見 B3）。
2. **序列化器（B2）**：新 `lib/core/services/api/native_input_parts.dart`（純 Dart、無 Flutter 依賴、可全單測）。輸入（attachments、capabilities、protocol、baseUrl、config）→ parts 陣列；**格式/白名單/table 以 §1.2 的上游表為藍本**，並以 OmniChat 慣例回**結構化錯誤**（`null + error payload`）而非 throw——錯誤進 snackbar（§5.6）與 wire log。**另做一個 `neutral messages → wire messages` 轉換器**（比照上游 `buildOpenAIChatCompletionMessages`），讓主 body 與 body2/follow-up 共用；只做 parts 陣列無法覆蓋 body2。
3. **transport 接入（B3）**（§5.3 5-Hook 是「參數／body 注入」契約；**generateText 只吃 `prompt` 字串、不吃附件**，見 §7 F11，不要為附件硬改它）：
   - chat-completions：`_sendOpenAIStream` 建 `mm` 的迴圈（`addImageUrl/addVideoUrl` 旁）＋ **body2 的 `mm2` 重建點**（L4108-4145）。`mm2` 走 `_preserveToolStructuredMessages`，目前只保留 role/content，會丟 `_attachments`；必須保留該鍵並在 body2 再跑一次轉換器，或把 parts 先序列化進 content array 再讓 body2 原樣帶走。**這是 §7 F3 的 blocker。**
   - responses：input builder（L3058 區塊）＋ Responses 的 body2（L4951）。
   - claude：content blocks 建構處（PDF document block）＋ tool_result follow-up 重建點。
   - gemini：inline_data 區塊（≈L8360-8390；L8266 為簽章解析區）＋ functionResponse follow-up 重建點。
   **chat-completions 形狀守衛必須先擴 allowlist**：`_normalizeOpenAiCompatMessageContent` 目前只保留 text/image_url/video_url/input_image，`input_audio` 與 `file` 會在入口（L2869）與 encode 前（L3613）被**無聲丟棄**。B3 要把它們加入 allowlist，並在 `chat_completions_content_shape_test.dart` 加案例；Responses/Claude/Gemini 不受此守衛影響。
4. **大小上限（B4）**：`_encodeBase64File` 加 `maxBytes`，但**不能只看 raw 20 MB**：Gemini inline 的官方上限是 **20 MB（含 text/system/所有 inline 檔的總請求）**，base64 膨脹約 33%，20 MB raw → ~26.7 MB encoded 必定失敗（§7 F8）。建議：單檔 raw ≤ 10 MB、單訊息 encoded 總量 ≤ 18 MB（留 text 餘量），超過回 `attachment_too_large` 並提示改用檔案較小或換 provider；`maxBytes` 只是防線，真正預算要在轉換器以 encoded length 計算。audio/pdf/video 皆走同一預算；`_encodeBase64File(withPrefix:true)` 的 MIME 不可用於 audio/pdf（`_mimeFromPath` 會回 `image/png`）。
5. **文字萃取與 native PDF 的互斥（B5）**：`processUserMessagesForApi(apiMessages, settings, assistant)` 目前**沒有 model/provider/protocol 參數**，無法自己判斷 native PDF 是否可用。需從 caller（`message_generation_service` L185-200 已有 config/modelId）傳入 `NativeInputPolicy`（含 `nativePdf`、`nativeAudio`、protocol/host gate）；對 `nativePdf=true` 的訊息跳過 PDF 萃取。**範圍要明確**：若 V1 只寄末則 native parts，則只跳過末則 PDF 萃取；歷史 PDF 仍走文字萃取（現況）。上游有 frozen-prompt／snapshot 版本治理；OmniChat 每次請求重萃取，確實不需要 freeze，但「只跳過本請求」不等於「歷史不重送文字」。另：`chat_turn_service.dart` 是 voice chat 的平行組裝器，完全不呼叫 `processUserMessagesForApi`；本計畫不支援語音通話中的附件，應在文件中列為限制。
6. **歷史訊息重放政策**：native PDF/audio 附件對**歷史訊息**是否重放：上游支援（`NativeInputAttachments.build` 逐訊息重建；OpenAI body2 亦重新呼叫 builder）。OmniChat 現狀不是「歷史附件一律不寄」：歷史 PDF 會重新萃取文字、歷史音訊會以亂碼文字重送；只有 native wire 形式不存在。**建議 V1 只寄末則 native parts**，歷史 native 重放列觀察項——理由：(a) 備份雖預設含 `upload/`（§7 F1），但使用者可關閉 `includeFiles`、檔案可被外部刪除、跨裝置絕對路徑可能失效，重放要處理 unavailable；(b) token 成本；(c) 與「歷史圖片重放」同源，留待 §2.6 另案。**不要**用「備份不含附件」當理由。

**測試**：`test/core/services/api/native_input_parts_test.dart`（4 協議 × pdf/audio + 既有 video 回歸 × 本機/遠端/data-URI × 能力 miss/格式 miss/encoded 超限，斷言結構化錯誤形狀）；`chat_completions_content_shape_test.dart` 擴充 input_audio/file **存活**案例（§7 F4）；body2/follow-up 附件 round-trip（§7 F3）；`processUserMessagesForApi` native PDF 跳萃取測試；DashScope/`api.openai.com` host 分支。

### 2.3 C／UI：modality 閘門 + 播放器 + unavailable（P1/P2）

**上游做法**（`e89b0d5bb`）：輸入列/工具選單按模型能力過濾 picker 入口；送出時 `strip_unsupported_media` 把不支援附件剝除（保留訊息可送）；`attachment_modality_gate.dart` 46 行集中判定。

**OmniChat 設計**

1. **集中判定**：比照 §3.16 §8 的 `BuiltInToolsHelper` 單一真相來源做法，新增 `AttachmentModalityGate`（純函數：`(mime, ModelInfo) → keep|strip|reason`）；chat_actions 送出前呼叫一次，直接從 `input` 中剝除不支援附件（**保留檔案與卡、只不送**），顯示在地化 snackbar（`unsupportedAttachmentStripped(count)`）。
2. **入口過濾（簡化）**：輸入列「+」選單對 audio/pdf 入口依當前模型能力顯示/隱藏或加「模型不支援」灰態；video 既有入口照舊。
3. **AudioClipPlayer**：播放卡（播放鍵 + 檔名 + 時間）。上游 widget 可**移植或原生重寫**（OmniChat 已依賴 `audioplayers`；Windows 用 `PlayerMode.mediaPlayer` 為既有慣例 §5.2 §1）。訊息卡（user 附件 `[file:]` mime audio/*）與 composer 卡共用。
4. **unavailable 狀態**：附件**預設會進 Backup v3**（`includeFiles` 預設 true，涵蓋 `upload/`、`images/`、`avatars/`；且 preflight 會在引用檔缺失時中止備份）——所以 unavailable 不是常態，而是「使用者關閉 includeFiles、檔案被外部刪除、第三方匯入未帶檔、跨裝置絕對路徑失效」的防禦。播放/送出前 `SandboxPathResolver.fix(path)` + async `File.exists()`（§5.1 §6：同步檢查禁用）作廢化顯示 `attachmentUnavailable` 卡。
5. l10n ×4（zh/zh_Hans/zh_Hant/en）。

**測試**：gate 純函數測試；送出剝除 + snackbar 回饋；播放卡在無檔案/非 audio path 的退化；本地備份還原後 unavailable 顯示。

### 2.4 D／錄音附件（P2/P3）

- OmniChat 已有：聽寫（Per-Utterance Restart）、Live API 16 kHz/16-bit mono PCM（W0）、TTS 端 `_pcmToWav`。**共用 WAV 擷取**：mic → PCM stream → `Uint8List` → WAV file；索引在 `asr/` 或語音 hub 的現有會話層。
- 入口：錄音鈕（門：`supportsAudioInput`），錄音中 UI（取消/重錄），完成後進 composer 佇列與其它附件同流（`mediaController.addFiles`）。
- 與 `docs/speech_recognition_import_plan.md` **有銜接**：該計畫 Phase 1 的 WAV codec/PCM 擷取元件可共用；若先做本計畫，**把 WAV codec 放成共用模組**避免做兩次。
- **估時 3–5 人日**（含錄音 UI session 保護、防 stale async——上游 `0b0e4ce62` 的教訓：錄音會話與播放請求要互相隔離）。

### 2.5 錯誤策略：組裝期剝除 > transport throw

上游在 transport 層 `throw UnsupportedError`；OmniChat 的差異在於**串流容錯層 §3.10 只處理 retryable/terminal 網路錯誤**——一個 `UnsupportedError` 會變 terminal 錯誤吃掉整輪 UX。因此：

1. **組裝期**（chat_actions / message_generation）先剝除+預警（有 UI 回饋）。
2. **transport 層**的 wire 錯誤只作為**第二道防線**，回結構化的 attachment error（`type: 'attachment_error'` 或 status chunk），**不要用 `tool_error`**——§5.6 的 `tool_error` 是工具處理器的契約，模型會把它當工具失敗。絕不讓例外打斷串流。
3. 不建議的自動降級**不做**（provider 400 說不支援 pdf → 不自動改送文字萃取重送；避免 double-billing 與不可預測行為；錯誤訊息指引「重送時關閉 native PDF（per-model override）」）。

### 2.6 圖片上下文治理（暫緩另案的理由與觀察項）

- OmniChat 現狀：OCR off 時歷史 `[image:]` 每輪全重放（§2.2 §3 事實）；上游 #1334 證明「bounded + pin + restore」是解法，但需要 DB 層（image_context_repository）+ per-image 生命週期 + 大面板 UI。
- **Phase E 另案範圍（若核定）**：(a) 量化現狀成本（wire log 統計單輪圖片 token/bytes 分布）；(b) 最小緩解：per-message 重放開關或「僅末則寄送」切換；(c) 再決定是否搬上游完整治理。**本計畫不包含。**
- 與本計畫的介面：附件剖面（B1 的 `_attachments` 內鍵）是未來圖片上下文治理的同一掛點，設計時保留擴充空間。

### 2.7 輸出面（校正後的結論）

- 聊天模型**不串流原生音訊輸出**；上游的輸出面 = TTS（本地工具 + UI）。
- OmniChat 對應現況：TTS 樞紐（網路 TTS + 浮動播放器）、Gemini Live（雙向音訊通話）**都已覆蓋同核心需求**；「TTS 播放/匯出」與上游 `29c52236a` 的差異僅是 UI 功能，非本題。
- `text_to_speech` 本地工具（模型在 agent run 主動朗讀）屬新產品形態；列 Phase F 另案（工具 schema 已簡單：`{text}` → 呼叫 TTS hub；若 OmniChat 要做 agent 語音回應，可與 §3.14 ask_user 決策卡整合）。

---

## 3. 導入設計總覽

| Phase | 項目 | 主要檔案 | 資料/相容性 |
|:--|:--|:--|:--|
| A | A1 投影 + A2 override | `lib/core/providers/model_provider.dart`（`Modality`、`ModelRegistry` 家族規則、集中 parser）、`lib/core/services/model_catalog/model_catalog.dart`（`Set<String>` 投影）、`lib/features/model/widgets/model_detail_sheet.dart`（input/output toggles + save/load）、`lib/features/model/widgets/model_select_sheet.dart`、`lib/features/provider/pages/provider_detail_page.dart`（badge/parser）、`lib/core/providers/settings_provider.dart`（`ProviderConfig.modelOverrides` 形狀）| **無 schema 變更**（catalog JSON 資料已在；Hive/SQLite 不動） |
| B | B1–B5 | 新 `lib/core/services/api/native_input_parts.dart`、`lib/features/home/services/message_builder_service.dart`、`lib/features/home/services/message_generation_service.dart`、`lib/features/home/controllers/chat_actions.dart`（含 AI Team 政策）、`lib/core/services/api/chat_api_service.dart`（guard allowlist、body2、四 transport、`_encodeBase64File`）、`lib/core/services/chat/chat_turn_service.dart`（限制註記） | neutral 內鍵形狀新增（persist 內容不變）；**無 schema 變更** |
| C | C1–C3 | 新 `lib/features/home/services/attachment_modality_gate.dart`、輸入列/訊息卡、`lib/shared/widgets/audio_clip_player.dart`、l10n ×4 | 無 |
| D | D1 新錄音 session | `lib/core/services/stt/`（或語音 hub）、輸入列 | 無 |

**遵循契約**：§5.3 5-Hook 掛接（參數／body 注入；附件只掛 sendMessageStream 主 body 與各 transport follow-up）；§5.5「嚴禁修改既有 `@HiveField`，新欄位給預設值」（Phase A/B/C/D 均不動 Hive schema）；§3.18 SQLite `message_parts` 不動（附件仍走內容 marker `_attachments` 內鍵屬訊息層投影）；§5.4 大小上限家族；§5.7 `_localOnlyKeys`（無新增裝置私有鍵——capabilities 屬模型資料，隨備份走可）。AGPL 來源標註：`native_input_parts.dart` 與 `AudioClipPlayer` 若**直接移植**上游檔案，保留 `Ported from Chevey339/kelivo@<sha> (AGPL-3.0), modified for OmniChat` 標頭並同步 `THIRD_PARTY_NOTICES.md`（§3.19 慣例；OmniChat 同為 AGPL-3.0，移植合法）。

---

## 4. 測試計畫

- **既有回歸**：`flutter test` 全數維持綠燈（手冊 §7.6 口徑基線 1,709 passed / 2 skipped）。重點守衛：`test/core/services/api/chat_completions_content_shape_test.dart`（§5.3 形狀守衛）、`test/message_builder_*test.dart`、`test/core/model_catalog_test.dart`、`test/model_override_persistence_test.dart`。
- **新增**：
  - `test/core/services/api/native_input_parts_test.dart`（wire 格式 × 4 協議 × 3 型別；格式白名單；encoded 大小預算；DashScope/`api.openai.com`/OpenRouter host 分支；`data:` 直解；結構化錯誤形狀；路徑 remap）。
  - `chat_completions_content_shape_test.dart` 擴充：`input_audio`/`file` **必須存活**、未知 block 仍被丟棄、user array 仍有 text block；這是 §7 F4 的回歸釘。
  - body2/follow-up round-trip：多輪工具呼叫 + PDF/audio，主 body 與 follow-up 都必須帶附件（OpenAI/Responses/Claude/Gemini 各一）；這是 §7 F3 的回歸釘。
  - 能力層測試（目錄 audio/video/pdf 投影、regex fallback、override 優先序、5 個 parser 的一致性）。
  - 附件閘門測試（keep/strip/reason 矩陣；送出剝除 snackbar；既有 `[image:]` 圖片通路不動；video 不重複）。
  - native PDF 跳萃取測試（組裝層 filePrompts 不含 PDF；歷史 PDF 仍萃取；OCR 流互不相擾）。
  - 現行 bug 回歸：`.mp3/.wav/.m4a` 不得被 `inferMimeByExtension` 標成 `text/plain`；audio 不得進入 filePrompts；歷史輪次不得重送亂碼。
  - AI Team：native 附件在 proposer/aggregator 的行為（V1 停用或 per-target gate）。
  - 播放卡/unavailable 測試（仿上游 `chat_message_widget_user_attachments_test.dart` 精神）；備份 `includeFiles` 開/關與缺檔的 unavailable。
- **實機 smoke**（Windows + Android）：Gemini（inline audio + video + PDF）、Claude 官方（PDF document）、Chat Completions 聚合商（input_audio wav/mp3）、video_url 既有路徑回歸。
- **平台**：Windows + Android 建置、`flutter analyze` 0 errors；macOS/Linux/iOS 不列入（手冊口徑）。

---

## 5. 風險與相容性

1. **body2/follow-up 丟附件（§7 F3，最高風險）**：OpenAI follow-up 用 `_preserveToolStructuredMessages` 重建 `mm2`，只保留 role/content（+ reasoning echo），`_attachments` 會被丟掉；body2 也不呼叫 parts builder。上游是在 body2 重新呼叫 `buildOpenAIChatCompletionMessages(..., nativeInputs: ...)`。解法：保留 `_attachments` 並在 body2 再跑轉換器，或把 parts 先序列化進 content array；兩者都要用「多輪工具 + PDF/audio」round-trip 釘住。
2. **chat-completions 形狀守衛會無聲吃掉新 block（§7 F4）**：`_normalizeOpenAiCompatMessageContent` 只放行 text/image_url/video_url/input_image；`input_audio`/`file` 會在 L2869 與 L3613 被丟棄。必須先擴 allowlist + 測試，否則 Phase B 做出來的功能「看起來有送、實際全空」。
3. **video 重複送（§7 F5）**：現行末則 video 已走 `userImagePaths` → `video_url`/Gemini inline_data；B1 若再把 video 放進 `_attachments`，同一段影片會送兩次。V1 明確把 video 排除在 B1 之外，或同一次改動把 video 從 `userImagePaths` 遷走。
4. **base64 記憶體／請求體（§7 F8）**：`readAsBytes` 全檔讀入 + `base64Encode` 字串 + request body 字串，20 MB raw 的峰值可達 60–80 MB；Gemini inline 另有 20 MB **encoded 總請求**上限。以 encoded length 做預算（單檔 raw ≤ 10 MB、單訊息 encoded ≤ 18 MB），超限回 `attachment_too_large`，不要讓 413/timeout 事後才爆。
5. **provider 400 面擴大**：input_audio/file/video 皆為「聚合商支援度不一」的形狀——`wire_errors.log` 策略（§5.3 教訓）沿用；結構化錯誤把 host/protocol 附進訊息，讓使用者可判斷。
6. **能力資料正確性**：目錄 `pdf` 值存在於 claude-fable/gemini-4 等；但**聚合商對同一模型可能不如實轉發**（relay 收到 `input_audio` 未必轉發上游）——閘門以「host/transport 判斷」補正（比照 §3.16 §8 慣例）；初期保守：native PDF 僅對 `api.anthropic.com`、`generativelanguage.googleapis.com`、Vertex origin 與 OpenAI 官方 chat-completions 開，其他聚合商預設關（文字萃取），per-model override 可手動開。
7. **AI Team 跨模型（§7 F10）**：`_executeAiTeamGeneration` 把 `ctx.apiMessages` 複製給多個 proposer/aggregator，`NativeInputPolicy` 卻只按「當前選中模型」算一次。選中 Gemini（native PDF）不等於每個 proposer 都支援 PDF；反之亦然。V1 建議 AI Team 模式停用 native audio/PDF（強制文字萃取或剝除），或對每個 proposer 重新 gate；不要把「選中模型的能力」當成整隊的能力。
8. **現行音訊亂碼（§7 F2）**：`[file:]` 音訊今天不是「靜默」而是被 `utf8.decode` 成亂碼注入，還每輪重送。導入後行為會從「送亂碼」變成「送原生音訊」或「不送」——這是**有感的行為變更**，不是「無破壞面」；Phase 0 先修，否則 Phase B 的 token/成本比較沒有乾淨基線。
9. **路徑與 MIME（§7 F12/F14）**：B2 必須用 `SandboxPathResolver.fix`/`resolveForIo`，不能直接 `File(path)`；data URI 的 MIME 必須用 attachment 的 mime，不能用 `_mimeFromPath`（它對 audio/pdf 回 `image/png`）。iOS/Android 的舊沙盒路徑也要走同一 resolver。
10. **舊資料相容**：marker 體系不變；PDF 附件風格不變（萃取仍預設、native 為能力/override 開啟）；音訊附件的 prompt 內容會改變（見第 8 點），應在 release note 說明。
11. **備份與 unavailable（§7 F1）**：Backup v3 的 `includeFiles` 預設 true，`upload/`、`images/`、`avatars/` 都會進 ZIP，且 preflight 會在引用檔缺失時 abort。unavailable 的理由是「includeFiles 關閉／檔案被外部刪除／第三方匯入未帶檔／跨裝置絕對路徑失效」，不是「備份不含附件」。不要新增「附件進備份」的機制——已經有了。
12. **上游差異風險**：上游 structured-parts 已生態化（fork/summary/backup/tool results 皆參照）；OmniChat 不搬 parts 儲存，**marker 與 `_attachments` 內鍵是投影**，資料一致性由 message_parts（§3.18）承接。

---

## 6. 評估後不導入項目

| 上游項目 | 理由 |
|:--|:--|
| ModelSpec 架構整體（`ab14b0734` 1019 行 + resolver/guesser/catalog 重寫 + provider 分層重構 `f1813db92`） | OmniChat 已有「目錄 + override + regex」階梯（§3.5 §6），行為規則吸收即可；搬架構是 20+ 人日級重構且觸碰 images 路由等已穩定面 |
| 附件 structured parts 儲存重構（`58afd0162`/`a0927b49f` + 8/10 的一整串 migration hardening） | OmniChat 已完成自家 SQLite `message_parts` 底座與遷移章法（§3.18），上游的重構是為了它自身的 Hive→DB 遷移；依照上游重做等價於重寫 OmniChat 儲存層 |
| `strip_unsupported_media` 完整 home controller 改造（`e89b0d5bb` 的 home_page/bottom_tools_sheet 大面積改動） | OmniChat 附件入口/UI 跟上游不同源；只收「集中 gate 函數＋送出剝除」行為 |
| 圖片上下文管理 #1334 完整搬遷（`249902b5`/`12af1d1a`/`af62cecb`） | 獨立大功能 × 未量化收益；另案（見 §2.6） |
| `text_to_speech` 本地工具 / TTS 匯出 | 輸出面已由 OmniChat TTS 樞紐 + Live API 覆蓋；agent 語音另案 |
| ASR 轉錄擴充（Groq/Mistral/ElevenLabs/Qwen Token Plan…） | 已有完整計畫文件 `docs/speech_recognition_import_plan.md` |
| workspace 圖片檢視工具（`c58cc4a19`） | 工作區功能面，非多模態輸入本題；與既有 file 卡/圖片預覽重疊度需另評 |
| 上游 draft 保留／voice service reorder 等零散 UX（`aa5211cdf`／`ead707d26`） | OmniChat 自家輸入列/語音樞紐實作不同源；draft 帖面需求另案 |

---

## 7. 嚴格審查紀錄（2026-11-05）

### 7.1 審查方法

- 逐條對照本機程式碼（行號以 2026-11-05 工作區為準）與 `upstream/master`（已 fetch；預設分支是 `master`，不是 `main`）。
- 目錄資料以 `assets/model_catalog/models_dev.json` 實測；commit 統計以 `git show --stat` 核對。
- 只審查計畫的**事實、可行性、遺漏、風險**；產品方向（分層部分導入）不在本次翻案範圍。

### 7.2 Blocker（v1.1 內文已修正；實作時必須先落地）

| ID | 位置 | 發現與證據 | 修正要求 |
|:--|:--|:--|:--|
| **F1** | §2.2-6、§2.3-4、§5-11、§0.4 C3 | **「備份不含附件檔」是錯的。** `BackupConfig.includeFiles` 預設 `true`（`lib/core/models/backup.dart` L22/L97）；`data_sync.dart` L389 會把 `upload/`、`images/`、`avatars/` 打進 ZIP，L1322 還原 upload；`backup_preflight.dart` 明列這三個目錄為 backup scope，引用檔缺失會 **abort 備份**。`restoreChatBackup` 的 `includeFiles:false` 只是 API 預設，不是 UI 備份預設。 | 內文已改為「預設會備份；unavailable 來自 includeFiles 關閉／檔案被刪／第三方匯入未帶檔／跨裝置路徑失效」。刪除「separate backup v3 擴充」的說法。 |
| **F2** | §0.1-3、§2.2-2、§5-8 | **現行音訊不是「靜默忽略」，是「亂碼注入」。** `processUserMessagesForApi` 只 skip `video/`；`DocumentTextExtractor.extract` 對未特別處理的 MIME（含 audio）走 `utf8.decode(bytes, allowMalformed:true)`（L81-84），所以 `.mp3/.wav/.m4a` 會被讀成文字；`inferMimeByExtension` 又缺 audio 分支（picker 選的音訊被標成 `text/plain`），`mimeForSharedFile` 雖有 audio 但 extractor 仍走文字 fallback。且 filePrompts 對**所有歷史 user 訊息**都建，會每輪重送。 | 加 Phase 0 hotfix：補 audio MIME、在 `processUserMessagesForApi` 跳過 `audio/` 並清 marker、加回歸測試。內文已把「無破壞面」改成「有感的行為變更」。 |
| **F3** | §2.2-B3、§5-1 | **OpenAI body2 會丟附件。** follow-up 用 `_preserveToolStructuredMessages`（L4108）重建 `mm2`，只保留 role/content（+ reasoning echo），`_attachments` 被丟；body2 也不呼叫 parts builder。上游是在 body2 重新呼叫 `buildOpenAIChatCompletionMessages(..., nativeInputs: ...)`（`chat_completions_api.dart` L916-932）。 | 保留 `_attachments` 並在 body2 再跑轉換器，或把 parts 先序列化進 content array；用「多輪工具 + PDF/audio」round-trip 釘住。 |
| **F4** | §2.2-B3、§5-2 | **形狀守衛會無聲吃掉新 block。** `_normalizeOpenAiCompatMessageContent` 的 user 分支只保留 text/input_text/image_url/video_url/input_image（L339-470），`input_audio`/`file` 屬「未知 block」直接丟棄；守衛掛在 L2869（入口）與 L3613（encode 前）。 | 擴 allowlist 加入 `input_audio`/`file`，並在 `chat_completions_content_shape_test.dart` 加「新 block 存活、未知 block 仍丟」案例；Responses/Claude/Gemini 不動。 |
| **F5** | §2.2-B1、§2.2-4 | **video 會重複送。** 末則 video 已由 `buildUserImagePaths`（L587-592）併入 `userImagePaths`，chat-completions 走 `video_url`（L3450-3460）、Gemini 走 inline_data（L8360-8390）。B1 若再把 video 放進 `_attachments`，同一段影片送兩次。 | V1 把 video 排除在 B1 之外（只做 audio/PDF），或同一次改動把 video 從 `userImagePaths` 遷走。 |

### 7.3 高風險／設計缺口（已補進內文）

| ID | 位置 | 發現 | 修正要求 |
|:--|:--|:--|:--|
| **F6** | §2.1-2 | `CatalogModel` 在 `model_catalog.dart`，該檔刻意保持純 Dart（no Flutter imports），而 `model_provider.dart` 已 import 它；若 `CatalogModel.inputModalities` 回傳 `List<Modality>`，會形成反向依賴／循環。 | `CatalogModel` 用 `Set<String>` 或 bool；在 `_inferWithCatalog` 映射成 `Modality`。 |
| **F7** | §2.1-4、§3 A | `ov['input']`/`ov['output']` 有 5 個 ad-hoc 讀取器（`chat_api_service` L796-807、`model_select_sheet` L110-119、`model_detail_sheet` L178-179、`provider_detail_page` L2418-2427／L2709-2718），全部把「非 image」映射成 `text`；另有 `model_detail_sheet` L1246-1247 的寫入映射也只認 image/text。另開 `modalities` 鍵會被現有 reader 忽略；擴 enum 後 badge 三元式也會把 audio/video/pdf 畫成 image icon。 | 沿用既有 `input`/`output` 陣列，集中一個 parser；同步改 save/load 與 3 處 badge（`model_select_sheet` L1143/1149、`provider_detail_page` L2765/2771）；A3 不是「只加標籤」，是 3 個 toggle + 寫入映射。 |
| **F8** | §2.2-B4 | Gemini inline 的官方上限是 **20 MB 總請求**（含 text/system/所有 inline 檔；`ai.google.dev/gemini-api/docs/audio`），base64 膨脹約 33%；計畫的「20 MB raw」換算後 ~26.7 MB，必定失敗。 | 以 encoded length 計算：單檔 raw ≤ 10 MB、單訊息 encoded 總量 ≤ 18 MB；超限回 `attachment_too_large`。 |
| **F9** | §2.2-B5、§3 B | `processUserMessagesForApi(apiMessages, settings, assistant)` 沒有 model/provider/protocol 參數，無法自行判斷 native PDF 是否可用；`chat_turn_service.dart` 是 voice chat 的平行組裝器（L144-300），完全不呼叫此方法。 | 從 caller 傳 `NativeInputPolicy`；文件明列「voice chat 不支援附件」為限制。 |
| **F10** | §2.3、§5-7 | AI Team 把 `ctx.apiMessages` 複製給多個 proposer/aggregator，`userImagePaths` 與能力判定都沿用「當前選中模型」；proposer 的模型可能不支援 PDF/audio。 | V1 在 AI Team 模式停用 native audio/PDF（強制文字萃取或剝除），或 per-proposer 重新 gate；加測試。 |
| **F11** | §0.4、§2.2-B3 | `generateText` 簽名只有 `prompt`（L1680-1690），body 是 `{'role':'user','content':safePrompt}`（L1810/1825/2021），不吃 messages/附件；§5.3 的 5-Hook 對「附件 parts」不適用。 | 文件已改為「5-Hook 是參數/body 注入契約；附件只掛 sendMessageStream 主 body + 各 transport follow-up」。 |
| **F12** | §2.2-B4 | `_encodeBase64File(withPrefix:true)` 用 `_mimeFromPath`，而該函式對 audio/pdf 回 `image/png`（L~820）；直接拿來做 data URI 會把 PDF 標成 PNG。 | 用 attachment 的 mime 自建 data URI，或先擴 `_mimeFromPath`（audio/video/pdf）。 |
| **F13** | §2.5-2 | 計畫說 transport 錯誤回 `tool_error`；但 §5.6 的 `tool_error` 是工具處理器契約，模型會當成工具失敗。 | 改用 `type:'attachment_error'` 或 status chunk。 |
| **F14** | §2.2-B2 | 計畫沒提路徑 remap；iOS/Android 舊沙盒路徑與桌面路徑都需要 `SandboxPathResolver.fix`/`resolveForIo`（上游也是這樣做）。 | B2 明列 resolver；測試 `data:`、本機、遠端、舊沙盒路徑。 |
| **F15** | 全篇 | 行號有漂移：`_encodeBase64File` 實際 L1252（非 L~7570）、video 實際 L587-592（非 L576-580）、chat-completions parts 實際 L3450-3460（非 L3376-3390）、Gemini 實際 L8360-8390（非 L8291-8310）。另有殘留錯字：「音訊輸入網」「聚性守門」「回歲」「native PDF/vs video」「attachments進備份」「non-recommended」「generatorText」「eject」。 | 已修主要錯字；行號建議改「≈」或下次同步時重抓，避免審查者被誤導。 |

### 7.4 已驗證正確的事實

| ID | 事實 | 證據 |
|:--|:--|:--|
| V1 | 上游預設分支是 `master`；fork 點 `d5a134ef1` 日期 2026-01-03 | `git remote -v`、`git log -1 --date=short d5a134ef1` |
| V2 | 影片支援在 fork 前（`2a9fbc77c`，2025-11-15），本機已有 `video_url` 與 Gemini inline_data | `git log -1 2a9fbc77c`；`chat_api_service` L3450/L8360 |
| V3 | `917ec2bc7` 的 `native_input_attachments.dart` 230 行；`0b0e4ce62` 的 `audio_clip_player.dart` 247 行、input bar +210；`ab14b0734` 的 `model_spec` 1019／resolver 709／guesser 1095 行 | `git show --stat` |
| V4 | 目錄實測：`audioInput` 795、`videoInput` 1615、`pdfInput` 2358、`audioOutput` 78；例 `302ai/gemini-3.1-flash-lite`（audio+video）、`302ai/claude-fable-5`（pdf）、`302ai/MiniMax-M3`（video） | Python 掃 `assets/model_catalog/models_dev.json` |
| V5 | `_pruneModel` 原樣保留 `modalities.input/output`；`CatalogModel` 只投影 `imageInput/imageOutput` | `model_catalog.dart` L600-627、L271-272 |
| V6 | 上游沒有模型原生音訊輸出；`response.audio.delta` 在 decoder 被丟棄 | `git grep` upstream；`chat_completions_decoder.dart` L507 |
| V7 | 上游會逐訊息重建 native parts，OpenAI body2 也重新呼叫 builder | `chat_completions_api.dart` L332-344、L916-932；`claude_history.dart` L587 |
| V8 | 手冊基線 1,709 passed／2 skipped；`audioplayers 6.5.1`、`record 7.1.1` 已在 pubspec；LICENSE 是 AGPL-3.0 | 手冊 §7.6；`pubspec.yaml`；`LICENSE` |
| V9 | §1.2 的 wire 表與上游實作大致相符（Chat Completions PDF/`input_audio`/`video_url`、Responses 只 PDF、Claude 只 PDF、Gemini inline/file_data）；但 OpenAI `input_audio` 的格式／大小上限沒有官方文件核實 | 上游 `native_input_attachments.dart` L120-260；官方文件只查到 Gemini 20 MB |
| V10 | per-model override 的 `{v:1,...}` 版本形狀已存在 | `lib/core/utils/reasoning_overrides.dart` L130 |
| V11 | `native_input_attachments.dart` 在 `917ec2bc7` 之後只被 `0b0e4ce62` 追加 `acceptsNativeAudioInput` gate；wire 格式未變 | `git log 917ec2bc7..upstream/master -- '*native_input*'`；`git diff 917ec2bc7 0b0e4ce62 -- ...` |

### 7.5 審查結論

1. **條件式通過**：分層部分導入的方向正確，但 F1–F5 是 blocker。v1.1 已把內文修正；**Phase B 開工前**必須先有 F3/F4 的設計定案與測試釘，否則會做出「有 UI、wire 全空」或「第一輪有 PDF、tool follow-up 就消失」的假功能。
2. **先做 Phase 0**：F2 是現行 bug（音訊亂碼 + 每輪重送），0.5–1 人日即可修；不修會污染 Phase B 的基線與成本比較。
3. **估時上修**：A 3–4、B 7–10、C 3–4、D 3–5；A–C 13–18、A–D 16–23 人日（原 10–14／13–19 低估了 parser 收斂、body2、guard、AI Team 與 encoded 預算）。
4. **維持不導入**：ModelSpec 架構、structured-parts 儲存重構、#1334 圖片上下文、TTS 本地工具、ASR 擴充；理由不變，且本次審查沒有發現需要翻案的新證據。
5. **下一步**：先修 F1–F5 的內文（已完成）與 Phase 0；Phase A 開工前補一張「5 個 parser → 1 個 parser」的變更清單，Phase B 開工前補一張「主 body／body2 × 四 transport」的附件矩陣測試表。

---

**核定後動作**：Phase 0／A 開工前在本文件記錄核定日期與負責人；每個 Phase 完成後將本檔改名加 `（已實作）` 後綴，並更新手冊 §3.6（多模態能力）／§3.5（目錄與能力層）對應小節（比照 §7.4 上游導入紀錄慣例）。若與 `docs/speech_recognition_import_plan.md` 的 WAV codec 元件共用，在兩份文件互相註記。