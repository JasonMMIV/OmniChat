# OmniChat 語音辨識（STT）擴充導入計畫

> **版本**：v1.2（第二輪 review 修訂版）  
> **日期**：2026-11-04  
> **狀態**：第二輪 review 完成；高風險設計問題與政策對齊已修訂，尚未實作  
> **範圍**：Groq／Mistral／ElevenLabs／Qwen 語音轉文字、Qwen Token Plan、Qwen 音訊 WAV 正規化、STT 設定頁提示樣式與三語系  
> **非範圍**：Sherpa／ONNX 本機模型、OpenAI Realtime、Volcengine、MiMo、Step、DashScope 即時串流、語音通話全面改用雲端 STT、TTS 全面重構  
> **相關文件**：`OmniChat 專案開發與維護手冊.md` §3.3（語音）、§5（平台陷阱）、§7（現狀）

---

## 0. 摘要（TL;DR）

### 0.1 結論

**建議「部分導入」，不是整包移植上游 ASR 子系統。**

| # | 工作項 | 判斷 | 優先級 | 主要理由 |
|:---:|:---|:---|:---:|:---|
| 1 | 新增 Groq、Mistral 語音轉文字 | **導入** | P1 | Groq 目前只有設定模型、沒有轉錄；Mistral 完全沒有。兩者與 OpenAI 同屬 multipart 批次 API，可共用同一條管線。 |
| 2 | 新增 ElevenLabs 與 Qwen 語音轉文字（即時／音檔／Token Plan） | **部分導入** | P1／P2 | ElevenLabs 音檔與 Qwen 錄音檔／Token Plan 可接批次管線；**Qwen 即時（WebSocket）暫緩，V1 不交付**。 |
| 3 | 修正 Qwen 音訊取樣率、播放 WAV 前正規化 | **有條件導入** | P2／P3 | 上游修正的本質是「WAV 容器／header 正規化」，不是重取樣。本專案 Qwen TTS 走不同 endpoint 且一律標成 MPEG，必須先確認真實回應格式；不能直接 cherry-pick。 |
| 4 | STT 設定提示顏色／字重、Workspace ID 佔位符、三語系 | **導入** | P1／P2 | 提示樣式是低成本修正；Workspace ID 欄位與 Qwen Token Plan 同批；三語系實務上要同步四個 ARB。 |

### 0.2 最重要的一件事

本專案目前的「語音辨識」頁面**只有設定層，沒有轉錄實作**：

- `lib/core/services/stt/network_stt.dart` 只有 `openaiWhisper`、`groqWhisper` 兩個選項型別，沒有 HTTP 請求。
- `lib/features/settings/pages/stt_services_page.dart` 對第三方服務顯示「尚未支援轉錄」徽章。
- 聽寫與語音通話都直接使用 `speech_to_text`，沒有任何執行時路徑讀取 `selectedSttService`。

因此，**第 1、2 項若不先建置批次 STT 管線，就只是再增加幾張「尚未支援轉錄」的卡片，沒有使用者價值。** 本計畫的第一個實作階段就是補上這條管線。

### 0.3 建議順序

```
Phase 0  範圍凍結、失敗案例、平台 spike
  -> Phase 1  WAV codec + PCM 擷取 + endpoint resolver + 設定相容性
  -> Phase 2  Groq / Mistral / OpenAI 批次轉錄 + 聽寫 session
  -> Phase 3  ElevenLabs + Qwen 錄音檔／Token Plan + 設定 UI／l10n
  -> Phase 4  Qwen 即時（暫緩，需另案授權）
  -> Phase 5  Qwen TTS WAV 播放正規化（有條件）
```

### 0.4 工作量

| 範圍 | 估時 |
|:---|:---|
| Phase 0–3（建議執行範圍，含測試） | **14–20 人日** |
| Phase 4 Qwen 即時 | +5–7 人日（暫緩） |
| Phase 5 Qwen TTS WAV 修正 | +1–2 人日（有條件） |

單人約 3–4 週；兩人可把「批次核心」與「設定 UI／l10n」切開平行，壓到 2–3 週。

### 0.5 本次 review 的修訂摘要

本次以「目前 OmniChat 程式碼 + 上游 v1.3.2–v1.3.4」逐項對照，發現以下問題；v1.1 已把它們寫回各節。

| # | 問題 | 嚴重度 | 修訂 |
|:---:|:---|:---:|:---|
| R1 | `baseUrl` 目前存的是**完整 endpoint**（`.../audio/transcriptions`）；計畫卻當成 base 再拼接，會變成重複後綴。 | 高 | 新增 `resolveSttEndpoint()`，同時接受 base 與完整 endpoint；預設保留完整 endpoint；補遷移與測試。 |
| R2 | 未知 kind 跳過後，`stt_selected_v1` 的整數索引會位移，選到別的服務。 | 高 | 改為 id 優先（`stt_selected_id_v1`），舊索引一次性遷移；編輯時保留 `id`。 |
| R3 | 目前 `settings_provider` 用一個大 `try/catch` 解析整個清單；任一筆壞掉會清空全部 STT 服務。 | 高 | 改為逐筆 `tryFromJson`；保留有效項目，只記錄壞項。 |
| R4 | 計畫的 `NetworkDictationController` 無法存取 `HomePageController` 的私有 `_preDictationText` 等狀態；partial/final 也可能重複追加。 | 高 | 改為 `HomePageController` 持有狀態，`NetworkDictationSession` 只負責擷取與 HTTP；批次沒有 partial，final 為權威，每次由 base+final 重算；partial 只留給 Phase 4。 |
| R5 | `record` 的 PCM chunk 可能切在半個 16-bit sample；30 秒 flush 可能落在奇數 byte。 | 高 | 擷取層保留 1-byte carry，flush 只切偶數長度；補 odd-chunk 測試與實際 sample rate spike。 |
| R6 | 取消機制依賴 `AbortableMultipartRequest`，但本專案目前只確認有 `AbortableRequest`；且 late response 可能回寫。 | 高 | 每個 session 專用 `http.Client`，`cancel()` close client + `_cancelled` 旗標；`finish()` 冪等。 |
| R7 | Qwen WAV 哨兵值寫反了：`0x7fffffbf` 是 RIFF size、`0x7fffff9b` 是 data size；且本專案 Qwen TTS endpoint 與上游不同。 | 高 | 修正數值與推導規則；Phase 5 先抓真實回應，必要時先修 JSON/SSE 解析。 |
| R8 | 直接重用 `initAudioSessionForVoiceChat()` 會套用 voiceChat/AGC/藍牙路由，不適合 ASR；也未處理背景與 dispose。 | 高 | 新增 dictation 專用 audio session；`onAppLifecycleStateChanged` 與 `dispose` 取消 session。 |
| R9 | 單一「尚未支援轉錄」徽章無法表示 OpenAI/Groq/Mistral 已可用、ElevenLabs/Qwen 尚未可用。 | 中 | 改為 per-service 可用性判定；未實作服務不可選取。 |
| R10 | 編輯 sheet 用大量 `initial is ...` 型別判斷；新增三種服務後容易漏欄位。 | 中 | 在 `SttServiceOptions` 加共同 getter（`apiKey`／`configuredEndpoint`／`model`／`language`），sheet 只保留 provider 專屬欄位。 |
| R11 | 分段文字直接串接，英文會黏在一起、中文可能被插入空格。 | 中 | 新增 `joinTranscript`，依 CJK／拉丁字元與標點決定分隔。 |
| R12 | `finish()`／`cancel()` 沒有定義重複呼叫、串流關閉與 state machine。 | 中 | 定義 `idle → recording → flushing → finishing → done/cancelled`，`finish()` 回傳同一個 future。 |
| R13 | 計畫提到 `isTranscribing`，但沒有列 `ChatInputBar`／`ChatInputSection` 的接線。 | 中 | 加入參數、`home_page.dart` 傳遞與 widget test。 |
| R14 | §7 範例用 `FontWeight.w400`，又說要用 `AppFontWeights.regular`；Android 字重正規化會不一致。 | 低 | 統一使用 `AppFontWeights.regular`。 |
| R15 | §15 寫「四個批次 Provider」，實際是五個（OpenAI／Groq／Mistral／ElevenLabs／Qwen）；估時也未含新增的相容性工作。 | 低 | 改為五個；估時上調為 14–20 人日。 |
| R16 | 狀態機把 `flushing` 當成不接受 PCM，segment 上傳期間會丟音訊。 | 高 | `flushing` 仍接受 PCM 到下一個 buffer；上傳佇列一次只送一個 segment；只有 `finishing`／`done`／`cancelled` 停止。 |

### 0.6 第二輪 review 修訂摘要（v1.2）

第二輪以「實際程式碼＋本專案手冊（§5.2.1、§7.3、§5.7）＋既有測試」逐項核對 v1.1；As-Is 描述與程式碼一致，另補以下修訂。

| # | 問題 | 嚴重度 | 修訂 |
|:---:|:---|:---:|:---|
| R17 | §4.7／§16 Q5 建議把 STT 金鑰搬 `flutter_secure_storage`，與手冊 §7.3（C-S01）已否決此路線的決策衝突。 | 中高 | 撤回該硬化項：STT 金鑰維持 SharedPreferences，比照手冊走備份加密（另案）；本計畫只做日誌脫敏與錯誤訊息截斷。 |
| R18 | `RecordConfig` 未指定 `audioInterruption`；手冊 §5.2.1 已記錄 Android focus loss 會讓 record 以預設 `PAUSE` 永久停 mic（Live API 因此用 `none`）。 | 中 | 固定 `audioInterruption: AudioInterruptionMode.none`；Android 不呼叫 `activateAudioSession()`（會以 gain 搶 focus）；Phase 0 加 focus spike。 |
| R19 | §4.2.2 的「選取 id 不存在 → 系統 STT」與現行 clamp（收斂到有效 index）及既有測試衝突，未列測試更新。 | 中 | 明示為刻意行為變更；Phase 0 更新 `test/settings_provider_stt_test.dart` 的 out-of-range 測試。 |
| R20 | R15 的「五個 Provider」有兩處漏改（§3 對照表、Phase 0）。 | 低 | 統一為五個（4 個 multipart＋Qwen JSON）。 |
| R21 | §9.1 提議的 `settings_provider_stt_test.dart` 與既有 `test/settings_provider_stt_test.dart` 同名不同位，易漂移。 | 低 | 既有三檔以擴充為原則；§9.1 標示「擴充」與「新增」。 |
| R22 | endpoint resolver 對 Groq base `…/openai` 會產生缺少 `/v1` 的 404 路徑。 | 低 | 改為版本段感知拼接（`/v1` 結尾只補尾段；Groq `/openai` 補 `/v1/audio/transcriptions`）；補測試。 |
| R23 | Phase 1 含 `BatchSttSession` 骨架，但 PR1 描述未涵蓋。 | 低 | PR1 描述補上 session 骨架。 |
| R24 | DoD 缺文件回寫；手冊維護指引要求新核心模組需更新 §3／§8。 | 低 | §15 新增手冊更新項；§12 每個 PR 附對應章節更新。 |

另修正：§2.1 行數（實測 1,137 行，改為約 1,100 行）、`joinTranscript` 的 Hangul 邊界、§4.2.4 的降級注意。

---

## 1. 上游變更盤點

### 1.1 版本對應

| 上游版本 | 相關變更 |
|:---|:---|
| v1.3.2 | 新增 Groq、Mistral 語音轉錄；修正 Qwen WAV 音訊播放前正規化 |
| v1.3.3 | 新增 ElevenLabs、Qwen 語音轉錄（即時、錄音檔、Qwen Token Plan） |
| v1.3.4 | STT 設定提示顏色／字重；Workspace ID 佔位符改為 `e.g. token-plan`；補英文、簡中、繁中 |

### 1.2 上游實際檔案與規模

上游不是把功能塞進單一 `network_stt.dart`，而是一整套 ASR 子系統：

| 檔案 | 行數（v1.3.4） | 角色 |
|:---|---:|:---|
| `lib/core/services/asr/asr_service_options.dart` | 838 | 11 種服務型別、序列化、Qwen 模式／地域／Workspace |
| `lib/core/services/asr/cloud_asr_service.dart` | 2,170 | WebSocket 即時、分段 HTTP、multipart、Qwen JSON、錯誤處理 |
| `lib/core/services/asr/asr_audio_capture.dart` | 122 | `record` PCM16 擷取、WAV header |
| `lib/core/providers/asr_provider.dart` | 631 | 麥克風與 session 編排、狀態機 |
| `lib/core/services/asr/system_asr_service.dart` | 346 | 系統 STT 包裝 |
| `lib/features/settings/widgets/asr_services_section.dart` | 2,449 | 桌面／行動設定 UI |
| `test/core/services/asr/*` | 多檔 | options、multipart、Qwen HTTP、WAV、capture、provider |
| `test/core/services/tts/network_tts_test.dart` | 多檔 | Qwen WAV 長度／chunk／格式測試 |

上游 v1.3.3 的兩個關鍵 commit：

- `ca2721e07`：`feat(asr): add ElevenLabs speech transcription`
- `e6023a6e3`：`feat(asr): support Qwen Token Plan transcription`

### 1.3 四個工作項的實際內容

#### 1.3.1 Groq、Mistral

- 兩者都是 **錄音檔批次轉錄**，不是即時。
- Groq：`POST https://api.groq.com/openai/v1/audio/transcriptions`，Bearer，multipart `file`（WAV）、`model=whisper-large-v3`、可選 `language`、`response_format=json`。
- Mistral：`POST https://api.mistral.ai/v1/audio/transcriptions`，Bearer，multipart `file`、`model=voxtral-mini-latest`、可選 `language`。
- 回應皆為 `{"text": "..."}`。
- 最短音訊：Groq 10 ms、ElevenLabs 100 ms；太短的尾巴要補零，否則 API 會拒絕。

#### 1.3.2 ElevenLabs 與 Qwen

- **ElevenLabs**：錄音檔批次。
  - `POST https://api.elevenlabs.io/v1/speech-to-text`
  - Header：`xi-api-key`
  - multipart：`file`、`model_id=scribe_v2`、可選 `language_code`、`tag_audio_events=false`、`timestamps_granularity=none`
  - 回應：`{"text": "..."}`
- **Qwen 錄音檔（transcription）**：
  - `POST https://<workspace>.<region>.maas.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation`
  - Header：`Authorization: Bearer <key>`、`X-DashScope-WorkSpace: <workspace>`、`X-DashScope-SSE: disable`
  - JSON body：`input.messages[0].content[0]` 為 `input_audio`，內容是 `data:audio/wav;base64,...`
  - `parameters.format=wav`、`sample_rate=16000`、可選 `language_hints`
  - 回應：`output.text`
- **Qwen 即時（realtime）**：
  - `wss://<workspace>.<region>.maas.aliyuncs.com/api-ws/v1/inference`
  - Header：`X-DashScope-WorkSpace`
  - 模型：`qwen-audio-3.0-asr-flash-streaming`
  - PCM16 16 kHz 串流、句子結束事件、部分轉錄。
  - 本計畫**暫不導入**，原因見 §14。

#### 1.3.3 Qwen Token Plan

- Token Plan 使用 **錄音檔模式**，不是即時。
- Workspace ID 填 `token-plan`（不是 URL）。
- 地域（region）與金鑰必須匹配：
  - `cn-beijing`
  - `ap-southeast-1`
- 有 Workspace 時主機為 `<workspace>.<region>.maas.aliyuncs.com`；沒有 Workspace 時走 `dashscope.aliyuncs.com`（國際地域為 `dashscope-intl.aliyuncs.com`）。
- 上游 UI 的提示原文：
  - `For Token Plan, choose Recorded audio, enter token-plan as the Workspace ID, and select the region for your key.`
  - 繁中：`使用 Token Plan 時，選擇錄音轉寫，業務空間 ID 填 token-plan，並選擇與金鑰對應的地域。`
- 上游對 Workspace ID 的驗證：只允許英數與連字號，長度 1–63，不能是 URL；錯誤訊息為 `Enter a workspace ID, not a URL.`

#### 1.3.4 Qwen WAV 正規化

- 上游 v1.3.2 的修正發生在 **Qwen TTS 串流播放**路徑，不是 ASR 錄音。
- 真正做的事：
  1. 收到音訊後先看 RIFF magic。
  2. 若是 WAV，解析 `fmt `／`data` chunk，允許串流寫入者使用的哨兵／推導長度。
  3. 用實際 `fmt ` 內容重新編碼成 canonical WAV，`sampleRate` 從 header 讀取，不是硬編碼。
  4. 若是 raw PCM，檢查長度是否為 16-bit 對齊，再用 24 kHz 包成 WAV。
- **沒有重取樣（resampling）**。若播放器需要 44.1 kHz，必須另案處理。
- 本專案目前：
  - `_qwenSpeech()` 走 `/services/aigc/text-to-speech/synthesis`，非串流，直接把回應 bytes 標成 `audio/mpeg`。
  - 上游走 `/services/aigc/multimodal-generation/generation`，SSE，回傳 WAV。
  - `_pcmToWav()` 只被 Gemini TTS 使用。
  - `TtsProvider._playAudioBytes()` 依 mime 決定副檔名後直接播放，沒有 RIFF 檢查或 header 正規化。
- 因此 Phase 5 不是「直接套上游 patch」，而是先確認本專案 Qwen TTS 的實際契約。

#### 1.3.5 提示樣式與 Workspace ID

- 上游 v1.3.4 在 `_EditorField` 的 `InputDecoration` 加上 `hintStyle`：
  - 顏色：`colorScheme.onSurface`，深色模式 alpha `0.42`、淺色模式 alpha `0.46`。
  - 字重：`AppFontWeights.regular`。
- Workspace ID 的 hint 從硬編碼 `token-plan` 改為 l10n key `asrServicesWorkspaceIdHint`，值為 `e.g. token-plan`。
- 三語系：
  - 英文：`e.g. token-plan`
  - 簡中：`例如：token-plan`
  - 繁中：`例如：token-plan`

---

## 2. 本專案現況（As-Is）

### 2.1 設定層

| 位置 | 現況 |
|:---|:---|
| `lib/core/services/stt/network_stt.dart`（130 行） | `NetworkSttKind { openaiWhisper, groqWhisper }`；`SttServiceOptions` 只有 `id`、`enabled`、`name`、`kind`；兩個子類別只有 `apiKey`、`baseUrl`、`model`；**`baseUrl` 預設是完整 endpoint**（`.../audio/transcriptions`）；`fromJson` 對未知 kind 會靜默退回 OpenAI Whisper。 |
| `lib/core/providers/settings_provider.dart` | 持久化 key：`stt_services_v1`、`stt_selected_v1`、`stt_system_locale_v1`；提供 `sttServices`、`selectedSttService`、`usingSystemStt`、`setSttServices()`、`setSttServiceSelected()`；**整份 JSON 用一個 try/catch 解析，任一筆壞掉會清空全部**；`stt_selected_v1` 是整數索引。 |
| `lib/features/settings/pages/stt_services_page.dart`（約 1,100 行） | 系統 STT 一列＋第三方服務列表；編輯 sheet 有類型、名稱、API Key、Base URL、模型；第三方卡片固定顯示 `sttServicesPageNotImplementedBadge`（「尚未支援轉錄」）；編輯既有服務時**沒有保留 `id`**。 |
| `lib/features/settings/pages/voice_services_page.dart` | 語音服務入口，連到 `SttServicesPage`。 |

### 2.2 執行時路徑

| 功能 | 現況 |
|:---|:---|
| 行內聽寫 | `lib/features/home/controllers/home_page_controller.dart` 直接建立 `stt.SpeechToText.withMethodChannel()`，使用系統引擎、每句 final 後重開 session、7 秒（行動）／60 秒（桌面）靜音 watchdog。`HomePageController` 私有持有 `_isDictating`、`_dictationPaused`、`_preDictationText`、`_dictationStopFuture`。 |
| 語音通話 | `lib/features/voice_chat/controllers/voice_chat_controller.dart` 直接使用另一個 `SpeechToText` 實例，STT → LLM → TTS。 |
| 第三方 STT | **沒有任何執行時路徑讀取 `selectedSttService`**；`selectedSttService` 只被設定頁使用。 |
| 生命週期 | `home_page.dart` 的 `didChangeAppLifecycleState` 呼叫 `_controller.onAppLifecycleStateChanged(state)`；此方法目前只記錄前景狀態，沒有處理聽寫。 |
| 音訊 session | `PlatformAudioSetup` 只有 voice chat 用的 `initAudioSessionForVoiceChat()`（`playAndRecord` + `voiceChat` + Bluetooth/defaultToSpeaker），沒有 dictation 專用設定。 |

這是本計畫最重要的缺口：**設定存在，但不會被任何功能使用。**

### 2.3 TTS 的 Qwen／ElevenLabs 現況

- `lib/core/services/tts/network_tts.dart` 已支援 Qwen TTS 與 ElevenLabs TTS。
- Qwen TTS 走 `/services/aigc/text-to-speech/synthesis` 非串流請求，回應一律視為 `audio/mpeg`。
- ElevenLabs TTS 依 `output_format` 決定 mime；`pcm_*` 被標成 `audio/wav`，但註解明說沒有轉換。
- `_pcmToWav()` 只被 Gemini TTS 使用；沒有通用 WAV parser／encoder。
- `TtsProvider._playAudioBytes()` 將 bytes 寫入暫存檔，依 mime 決定 `.mp3`／`.wav`／`.ogg`，交給 `audioplayers` 播放。

### 2.4 l10n 現況

- ARB 檔：`app_en.arb`、`app_zh.arb`、`app_zh_Hans.arb`、`app_zh_Hant.arb`。
- `l10n.yaml` 以 `app_en.arb` 為 template，輸出 `lib/l10n/app_localizations*.dart`；產物已進版控。
- 現有 STT key 使用 `sttServices...` 前綴；**沒有** Workspace ID、Region、Language、Recognition mode 相關 key。
- `app_zh.arb` 是簡中別名，與 `app_zh_Hans.arb` 內容大致相同；新增 key 時四個 ARB 都要同步，否則 `app_localizations_zh.dart` 可能出現未翻譯或 fallback。

### 2.5 缺口表

| # | 缺口 | 現況 | 目標 | 階段 |
|:---:|:---|:---|:---|:---:|
| G1 | 批次 STT 管線 | 無 | PCM 擷取 → WAV → HTTP → 文字 | Phase 1 |
| G2 | Groq 轉錄 | 只有設定模型 | multipart 轉錄 | Phase 2 |
| G3 | Mistral 轉錄 | 完全沒有 | multipart 轉錄 | Phase 2 |
| G4 | OpenAI 轉錄 | 只有設定模型 | 遷移到共用管線 | Phase 2 |
| G5 | ElevenLabs 轉錄 | 完全沒有 | multipart 轉錄 | Phase 3 |
| G6 | Qwen 錄音檔 | 完全沒有 | JSON data URL 轉錄 | Phase 3 |
| G7 | Qwen Token Plan | 完全沒有 | Workspace／Region／Endpoint | Phase 3 |
| G8 | Qwen 即時 | 完全沒有 | WebSocket PCM | Phase 4（暫緩） |
| G9 | Qwen WAV 正規化 | 只有簡單 PCM→WAV | 共用 WAV codec＋串流哨兵解析 | Phase 1／5 |
| G10 | 提示樣式 | 無 `hintStyle` | 顏色／字重區分 | Phase 3 |
| G11 | Workspace ID 文案 | 無欄位、無 key | 欄位＋三語系 | Phase 3 |
| G12 | 執行時接線 | 無 | 聽寫使用選定服務 | Phase 2 |
| G13 | Endpoint 相容 | 現值為完整 endpoint | resolver 同時接受 base／full | Phase 1 |
| G14 | 選取遷移 | 整數 index | id 優先＋舊資料遷移 | Phase 1 |

---

## 3. 為什麼不直接 cherry-pick 上游

| 原因 | 說明 |
|:---|:---|
| 模型不同 | 上游用 `AsrServiceOptions`／`AsrProvider`；本專案用 `SttServiceOptions`／`SettingsProvider`。直接引入會出現兩套設定與選取狀態。 |
| 規模過大 | 上游雲端服務 2,170 行、設定 UI 2,449 行、11 種 Provider；本專案只需要 5 種批次 Provider（4 個 multipart＋Qwen JSON）。 |
| 平台與 UI 差異 | 上游設定頁同時處理桌面／行動、Sherpa 模型下載、系統 STT；本專案目前是行動風格頁面，直接覆蓋會產生大量衝突。 |
| 不相關功能 | OpenAI Realtime、Volcengine、MiMo、Step、Sherpa ONNX 都不在本次需求內。 |
| 測試依賴 | 上游測試依賴 `AsrProvider`、`FakeAsrAudioCapture`、`MockClient` 等整套 fixture；直接搬會把測試體系一起搬進來。 |
| Endpoint 語義 | 本專案既有 `baseUrl` 是完整 endpoint；上游是 base + suffix。直接照搬會產生重複路徑。 |

**做法：移植「行為與協定」，不移植整套類別。** 保留本專案既有 `SttServiceOptions` 與 `stt_services_v1`，只擴充欄位與新增精簡的 session 層。

授權：OmniChat 與 Kelivo 同為 AGPL-3.0；移植協定與少量程式碼時，保留來源註解與 commit 參照即可。

---

## 4. 建議目標架構

### 4.1 分層

```
SettingsProvider（既有 stt_services_v1）
  └─ selectedSttService（SttServiceOptions）
        │
HomePageController（聽寫，狀態唯一擁有者）
  ├─ SystemDictationPath（既有 speech_to_text，不動）
  └─ NetworkDictationSession（新，plain class）
        ├─ SttAudioCapture（record，PCM16 16 kHz mono）
        └─ SttSession（新）
              ├─ BatchSttSession（OpenAI／Groq／Mistral／ElevenLabs）
              ├─ QwenRecordedSttSession（JSON data URL）
              └─ QwenRealtimeSttSession（Phase 4，暫緩）
```

### 4.2 資料模型

在既有 `network_stt.dart` 擴充，不新增平行模型：

```dart
enum NetworkSttKind {
  openaiWhisper,
  groqWhisper,
  mistral,
  elevenLabs,
  qwenAudio,
}

enum QwenSttMode { realtime, recorded }
```

`SttServiceOptions` 新增可選欄位：

| 欄位 | 用途 | 預設 |
|:---|:---|:---|
| `language` | BCP-47／語言代碼；空字串或 `auto` 視為自動 | `''` |
| `sampleRate` | 擷取與上傳取樣率 | `16000` |
| `segmentDurationSec` | 批次分段長度 | `30` |
| `mode` | 僅 Qwen：`realtime`／`recorded` | `recorded`（本專案 V1 只支援 recorded） |
| `workspaceId` | 僅 Qwen Token Plan | `''` |
| `region` | 僅 Qwen | `cn-beijing` |
| `endpoint` | 僅 Qwen，可選完整 URL | `''` |

#### 4.2.1 Endpoint 語義（R1）

- `baseUrl` 欄位保留，**語義是「使用者輸入的 endpoint」**，可為完整 endpoint 或 base。
- 既有 OpenAI／Groq 的預設值本來就是完整 endpoint：
  - OpenAI：`https://api.openai.com/v1/audio/transcriptions`
  - Groq：`https://api.groq.com/openai/v1/audio/transcriptions`
- 新增 `lib/core/services/stt/stt_endpoint.dart`：

```dart
Uri resolveSttEndpoint({
  required String raw,
  required NetworkSttKind kind,
});
```

規則：

1. `trim()`、解析 URL；只允許 `http`／`https`；host 非空；不得有 userInfo 或 fragment。
2. 移除結尾 `/`。
3. 若 `raw` 是空字串，使用該 kind 的預設完整 endpoint。
4. 若 path 是空或 `/`，直接使用 provider 預設完整 path，**不再進入步驟 5–8**：
   - OpenAI：`/v1/audio/transcriptions`
   - Groq：`/openai/v1/audio/transcriptions`
   - Mistral：`/v1/audio/transcriptions`
   - ElevenLabs：`/v1/speech-to-text`
5. 依 kind 決定尾段：
   - OpenAI／Groq／Mistral：`/audio/transcriptions`
   - ElevenLabs：`/speech-to-text`
6. 若 path 已以尾段結尾（忽略大小寫），直接使用，**不可重複拼接**。
7. 若 path 已以版本段 `/v1` 結尾（Groq 的 `/openai/v1` 亦同），只追加尾段。
8. 其餘情況（含代理前綴）追加完整預設 path：
   - OpenAI：`/v1/audio/transcriptions`
   - Groq：`/openai/v1/audio/transcriptions`；若 path 已以 `/openai` 結尾，只追加 `/v1/audio/transcriptions`
   - Mistral：`/v1/audio/transcriptions`
   - ElevenLabs：`/v1/speech-to-text`
9. 保留 query string；不可把 API key 放在 URL。

測試必須涵蓋：完整 endpoint、只有 host 的 base、結尾斜線、代理前綴、query、ElevenLabs `/v1`、重複 suffix、OpenAI `…/v1`、Groq `…/openai` 與 `…/openai/v1`（不得產生缺少 `/v1` 的路徑）。

#### 4.2.2 解析與選取遷移（R2、R3）

- 新增 `SttServiceOptions.tryFromJson(Map<String, dynamic>)`，回傳 `SttServiceOptions?`。
- `settings_provider` 改成逐筆解析：

```dart
final parsed = <SttServiceOptions>[];
for (final raw in list) {
  if (raw is! Map) {
    // log：略過非物件項目，不輸出 apiKey
    continue;
  }
  final map = Map<String, dynamic>.from(raw);
  final option = SttServiceOptions.tryFromJson(map);
  if (option != null) {
    parsed.add(option);
  } else {
    // log：kind/id/name，不輸出 apiKey
  }
}
_sttServices = parsed;
```

- 未知 kind、缺少必要欄位、URL 格式錯誤 → 回傳 `null`，不靜默變成 OpenAI。
- `fromJson` 不可再保留「未知 kind 退回 OpenAI」的 fallback；若其他呼叫端仍用它，讓它委派 `tryFromJson` 並在 null 時拋出 `FormatException`。
- 只有最外層 JSON decode 失敗才清空清單；單筆壞掉不影響其他服務。
- 新增 `_sttSelectedIdKey = 'stt_selected_id_v1'`：
  - 載入時優先以 id 找 index。
  - 若沒有 id key，使用舊 `stt_selected_v1` index，並在載入後寫回 id（一次性遷移）。
  - 舊 index 必須對照**原始清單**，不是過濾後的 `parsed` 清單；若原始 index 的項目無效，fallback 系統 STT，避免又選錯。
  - 若 id 找不到（服務被刪除），fallback 到系統 STT（`-1`），不要隨便選第一個。
- `setSttServiceSelected(int index)` 同時寫入 index 與 id。
- `setSttServices()` 若目前選取的 id 不再存在，fallback 系統 STT。
  - **這是刻意的行為變更**：現行實作在索引超界時會收斂到第一個有效服務（`settings_provider.dart` 的 clamp），且 `test/settings_provider_stt_test.dart` 的 `out-of-range selection converges when services are deleted` 釘住此行為。本計畫改為「選取 id 不存在 → 系統 STT（-1）」，避免使用者刪掉 A 服務後被靜默切到未預期的 B 服務（可能產生費用）。Phase 0 必須同步更新該測試（預期 `-1`／`usingSystemStt == true`）。
- 編輯既有服務時，建立新 options 必須帶 `id: initial?.id`，否則 id 會變、選取會掉。

#### 4.2.3 共同 getter（R10）

在 `SttServiceOptions` 新增：

```dart
String get apiKey;
String get configuredEndpoint;
String get model;
String get language;
```

- OpenAI／Groq／Mistral／ElevenLabs 的 `configuredEndpoint` 回傳 `baseUrl`。
- Qwen 的 `configuredEndpoint` 回傳 `endpoint.trim().isEmpty ? defaultEndpoint : endpoint.trim()`。
- 編輯 sheet 用這些 getter 初始化欄位，不再寫一長串 `initial is ...`。
- Provider 專屬欄位（Qwen 的 mode／workspace／region、ElevenLabs 的 voice 等）才用型別判斷。

#### 4.2.4 相容性規則

- 舊 JSON 的 `kind` 可能是 `openaiWhisper`／`groqWhisper`，`tryFromJson` 必須繼續接受。
- 未知 `kind` 不可再靜默退回 OpenAI；跳過該筆並記錄。
- `enabled` 欄位保留，設定頁新增時固定 `true`。
- Qwen `mode` 若缺失，V1 預設 `recorded`；若讀到 `realtime`，UI 標示「尚未支援即時」，不可默默當 recorded 使用。
- **降級限制**：舊版 App 的 `fromJson` 會把未知 kind 靜默轉成 OpenAI Whisper。本計畫只保證「舊→新」相容，不保證「新→舊」的備份還原語義；文件與 release note 應註明。

### 4.3 音訊擷取

新增 `lib/core/services/stt/stt_audio_capture.dart`：

- 使用專案已有的 `record ^7.1.1`（Live API 已在用）。
- `RecordConfig`：
  - `encoder: AudioEncoder.pcm16bits`
  - `sampleRate: 16000`
  - `numChannels: 1`
  - `autoGain: false`、`echoCancel: false`、`noiseSuppress: false`
  - `audioInterruption: AudioInterruptionMode.none`（**必要**）：手冊 §5.2.1 已記錄 record 的 Android AudioSessionManager 在 focus loss 時以預設 `PAUSE` 暫停錄音、focus 回來後不恢復（Live API 因此永久靜音，見 `live_api_session.dart` 的 `_startMic`）。Dictation 只收音、不播放，沒有理由讓 focus 事件暫停擷取。
- 介面：`hasPermission()`、`start({sampleRate})`、`stop()`、`cancel()`、`dispose()`。

#### 4.3.1 PCM 對齊（R5）

`record` 的 chunk 不保證是 2-byte 對齊；`BatchSttSession` 必須：

- 保留 1 byte 的 `_pendingByte`。
- `addPcm16(chunk)` 先把 pending byte 接回，若 chunk 長度為奇數，最後 1 byte 留到下一次。
- 只把偶數長度的資料放進 segment buffer。
- flush 時 `segmentBytes = sampleRate * 2 * segmentDurationSec`（必為偶數），只切偶數長度。
- `finish()` 時若仍有 1 byte，丟棄並記錄 warning（單一 byte 不是完整 sample；補零會產生 click）。

測試：1/3/5 byte chunk、跨 chunk 的 sample、flush 邊界、finish 剩 1 byte。

#### 4.3.2 實際取樣率 spike

- `RecordConfig.sampleRate: 16000` 是「請求值」，不保證平台一定以此速率交付。
- Phase 1 以 1 秒擷取檢查 bytes 是否約 `16000 * 2`；若平台回 48 kHz，必須：
  - 在擷取層重取樣，或
  - 以實際 rate 寫 WAV header 與 `sample_rate` 參數。
- 不可在未驗證前假設 30 秒 = 960,000 bytes。

#### 4.3.3 行動端 audio session（R8）

- 不要直接重用 `PlatformAudioSetup.initAudioSessionForVoiceChat()`：它的 `voiceChat` mode、Bluetooth、defaultToSpeaker、AGC/echo/noise 處理不適合 ASR。
- 新增 `PlatformAudioSetup.initAudioSessionForDictation()`：
  - iOS：`playAndRecord`，以 `measurement` 或 `spokenAudio` 為候選，關閉不必要的 Bluetooth/defaultToSpeaker；實際以裝置測試為準。開始前 `setActive(true)`，停止／取消／背景時 `setActive(false)`。
  - Android：`AndroidAudioAttributes` 使用語音內容類型；**V1 不呼叫 `activateAudioSession()`**——audio_session 的 focus 設定只有 gain 系列（`AndroidAudioFocusGainType` 無 `none`），會搶走使用者的音樂 focus；dictation 只收音、不播放，不需要 focus。改由 `RecordConfig.audioInterruption: none` 讓擷取對 focus 變化免疫（見 §4.3 與手冊 §5.2.1）。
  - 若未來要 duck／暫停外部音訊，再另案接 audio_session focus 管理。
- Windows／macOS／Linux 以 `record` 既有行為為準；Windows 權限以 `record.hasPermission()` 為準，不要只依賴 `permission_handler`。
- 與 `speech_to_text` 互斥：開始網路擷取前先停止系統 STT；網路 session 結束後才可重啟系統 STT。不可同時持有麥克風。

### 4.4 批次 session

新增 `lib/core/services/stt/cloud_stt_service.dart`：

```dart
class SttTranscriptUpdate {
  const SttTranscriptUpdate({
    required this.finalText,
    this.partialText = '',
  });

  final String finalText;   // 已定稿的累積文字
  final String partialText; // 目前 segment 的暫定文字；批次模式為空
}

abstract interface class SttSession {
  Stream<SttTranscriptUpdate> get transcripts;
  Future<void> addPcm16(Uint8List chunk);
  Future<String> finish();               // 冪等；回傳完整文字
  Future<void> cancel();                 // 冪等；丟棄未完成結果
}
```

`BatchSttSession`：

1. 狀態機：`idle → recording ⇄ flushing → finishing → done/cancelled`；`flushing` 代表有 segment 正在上傳，但仍接受新 PCM 到下一個 buffer。
2. 累積對齊後的 PCM；每 `segmentDurationSec` 或 `finish()` 沖出一個 segment。
3. 將 PCM 包成 44-byte WAV（`pcm16MonoToWav`）。
4. 依 Provider 建立請求：
   - OpenAI／Groq／Mistral／ElevenLabs：multipart。
   - Qwen：JSON + base64 data URL。
5. 解析 `{"text"}` 或 `output.text`，用 `joinTranscript` 串接。
6. 批次 API 沒有 partial；每個 segment 完成時送出 `SttTranscriptUpdate(finalText: 累積文字, partialText: '')`。UI 以取代方式顯示，不可 append。
7. `finish()` 先轉 `finishing`（拒絕新 PCM），等待當前 `addPcm16` 與所有上傳完成；回傳完整文字，重複呼叫回傳同一個 future；完成後關閉 `transcripts` 一次。
8. `cancel()` 設定 `_cancelled`、關閉專用 `http.Client`、清空 buffer、關閉 `transcripts`；已完成文字由呼叫端決定是否保留（聽寫採丟棄）。
9. `addPcm16` 只在 `idle`／`finishing`／`done`／`cancelled` 為 no-op；`recording` 與 `flushing` 都接受。
10. 上傳佇列一次只送一個 segment，確保文字順序；`flushing` 期間新 PCM 進下一個 buffer，不可丟棄。
11. `cancel()` 在 `done` 後為 no-op；`finish()` 在 `cancelled` 後回傳空字串，不拋錯；測試要鎖定。

#### 4.4.1 HTTP 與取消（R6）

- 每個 session 建立**專用** `http.Client`（測試可注入 `MockClient`）。
- `cancel()` 直接 `client.close()`，不需要依賴 `AbortableMultipartRequest`。
- `http` 1.6.0 已提供 `AbortableRequest`；若 `AbortableMultipartRequest` 可用，可作為加分，但不是必要條件。
- 所有 `await` 後檢查 `_cancelled`；late response 不可再 emit 文字。
- 每次 segment 請求 timeout 60 秒；`finish()` 等待最後一段 timeout 90 秒。
- **不自動重試**：轉錄請求不是 idempotent，重試可能產生重複文字；失敗由使用者重新開始。

#### 4.4.2 分段文字串接（R11）

新增 `lib/core/services/stt/transcript_join.dart`：

```dart
String joinTranscript(String prefix, String next);
```

規則：

- `prefix` 為空 → `next`；`next` 為空 → `prefix`。
- `next` 以空白開頭 → 直接相接。
- 邊界是 Han／Hiragana／Katakana／Thai → 不加空格。
- 邊界是拉丁字母／數字／標點／Hangul，且下一個以字母或數字開頭 → 加一個空格（韓文以空格分詞）。
- 其餘情況直接相接。

測試：中文、英文、中英混合、標點、已有空白、空字串、韓文。

### 4.5 與聽寫整合（R4、R13）

#### 4.5.1 狀態擁有權

- `HomePageController` 仍是聽寫狀態的唯一擁有者：`_isDictating`、`_dictationPaused`、`_preDictationText`、`_inputController`。
- 新增 `NetworkDictationSession`（plain class，不是 ChangeNotifier）：
  - 負責 `SttAudioCapture` + `SttSession`。
  - 對外暴露 `Stream<NetworkDictationUpdate> updates`，內含 `finalText`、`partialText`、`isTranscribing`、`error`。
  - `SttSession.transcripts` 的 `partialText` 在批次模式為空；`finalText` 是已定稿累積文字。
  - 不持有 `TextEditingController`，不自己改輸入框。
- `HomePageController` 訂閱 updates，負責把文字寫進輸入框。

#### 4.5.2 文字模型

- `baseText`：進入網路聽寫前的輸入框文字（沿用 `_preDictationText`）。
- `finalText`：已完成的 segment 累積文字。
- `partialText`：目前 segment 的暫定文字（可能為空）。
- 顯示文字一律重算：

```dart
String composeNetworkDictationText({
  required String base,
  required String finalText,
  required String partialText,
}) {
  var out = base;
  if (finalText.isNotEmpty) out = joinTranscript(out, finalText);
  if (partialText.isNotEmpty) out = joinTranscript(out, partialText);
  return out;
}
```

- 每次 update 都用 `compose...` 覆寫 `_inputController.value`，**不可在目前文字上 append**。
- segment 完成時 `partialText` 清空、`finalText` 更新；UI 不會重複。
- 批次模式沒有 partial，`partialText` 固定為空；Phase 4 即時模式才會有值。
- `stopDictation()` 等 `finish()` 後，把 `baseText` 更新為 `composeNetworkDictationText(base: baseText, finalText: finalText, partialText: '')`，再清空 final/partial。
- `cancel()` 還原 `baseText`，丟棄 partial/final。

#### 4.5.3 生命週期

- `startDictation()`：
  - `selectedSttService == null` → 既有系統路徑，完全不變。
  - 有選定服務但 `isSttServiceAvailable == false`（例如舊資料的 Qwen realtime）→ 顯示「尚未支援即時」並改走系統 STT，不可默默送批次。
  - 有選定且可用的服務 → 檢查權限 → 停止系統 STT → `NetworkDictationSession.start()`。
- `stopDictation()` 保持 `void`（UI callback 是 `VoidCallback`），內部 `unawaited(_stopNetworkDictation())`；避免改動既有 callback 型別。
- `pauseDictation()`：先 `finish()` 目前 segment（保留已定稿文字），停止擷取，將 `baseText` 更新為 base+final；`resumeDictation()` 以目前輸入框文字為新 `baseText` 開新 session。
- `onAppLifecycleStateChanged(state)`：`paused`／`hidden`／`detached` 時取消網路 session（不送出半段），把輸入框還原為 `baseText`（丟棄 partial/final），重置 `_isDictating`／`isTranscribing`；`inactive` 先暫停、不立即取消，避免權限對話框或控制中心誤觸。
- `dispose()`：取消 updates 訂閱，並 `unawaited(_networkDictation?.cancel())`。
- 使用者在 session 中切換／刪除服務：目前 session 繼續用啟動時快照的 service；若服務被刪除，下一次設定通知時取消 session。不要中途換 provider。

#### 4.5.4 UI 狀態

- `HomePageController` 新增 `bool get isTranscribing`。
- `ChatInputBar`／`ChatInputSection` 新增 `isTranscribing` 參數。
- `home_page.dart` 傳入 `isTranscribing: _controller.isTranscribing`。
- 聽寫中且 `isTranscribing == true`：顯示小型進度指示或「轉錄中」文字；停止按鈕仍可結束並等待最後一段。
- 錯誤以 SnackBar 顯示，不清空輸入框。

**語音通話 V1 不改。** 現有 `VoiceChatController` 依賴 `SpeechToText` 的 final callback 與每句重啟；批次 STT 延遲較高，直接接入會破壞自動恢復與暫停語義。等批次流程穩定後，再另案評估。

### 4.6 設定 UI

不重寫 `stt_services_page.dart`，只做最小擴充：

- 服務類型清單加入 Mistral、ElevenLabs、Qwen Audio。
- 使用 §4.2.3 的共同 getter 初始化欄位，避免新增 type-check 分支。
- 編輯既有服務時保留 `id`。
- 編輯 sheet 依類型顯示欄位：
  - 通用：名稱、API Key、Endpoint、模型、語言。
  - Qwen：模式（V1 只顯示「錄音檔」；即時標示尚未支援）、Workspace ID、Region、Endpoint override、模型。
- per-service 可用性（R9）：
  - 新增 `bool isSttServiceAvailable(SttServiceOptions s)`。
  - OpenAI／Groq／Mistral／ElevenLabs／Qwen recorded → 可用。
  - Qwen realtime → 不可用。
  - 列表徽章只對不可用服務顯示「尚未支援」；可用服務不顯示此徽章。
  - 點選不可用服務時顯示 SnackBar，不改變選取。
- 既有 `_inputRowMobile` 加上 `hintStyle`，並讓所有 STT 欄位共用。

### 4.7 安全與金鑰

- 目前 STT API Key 存在 `SharedPreferences`（明文），與 TTS／搜尋／WebDAV 憑證同級。**本計畫不遷移 `flutter_secure_storage`**：手冊 §7.3（C-S01）已否決此路線（備份/還原語意改變、只修一處堵不完），採用方向是備份加密（另案）；STT 金鑰比照處理，避免同一類憑證出現兩套儲存語意。
- 若未來備份加密落地，STT 金鑰自動受益（同一份 `stt_services_v1`），不需要額外遷移。
- 日誌不得輸出 API Key、完整 endpoint 查詢字串或音訊 base64。
- 錯誤訊息只顯示 provider、HTTP status 與截斷後的 body；不要把 body 整段塞進 UI。

---

## 5. Provider 規格

### 5.1 共通

| 項目 | 規格 |
|:---|:---|
| 音訊格式 | 16 kHz、16-bit、mono WAV（44-byte header） |
| 分段 | 30 秒，或 `finish()` 強制 flush |
| 最短音訊 | Groq 10 ms、ElevenLabs 100 ms；不足補零 |
| 語言 | 空字串或 `auto` 時不送語言欄位 |
| 錯誤 | 非 2xx 讀取 body，拋出含 status 與 provider 名稱的例外 |
| 取消 | 專用 `http.Client.close()` + `_cancelled` 旗標；late response 忽略 |
| 回應 | UTF-8 JSON；`text` 或 `output.text` |
| Timeout | 每段 60 秒；finish 90 秒 |
| 重試 | 不自動重試（避免重複文字）；由使用者重新開始 |

> **Endpoint 語義（R1）**：本節的 `{endpoint}` 是 `resolveSttEndpoint()` 的結果。`baseUrl` 可以是完整 endpoint 或 base；resolver 會避免重複後綴。既有 OpenAI／Groq 的預設值是完整 endpoint，不可直接再拼接 `/audio/transcriptions`。

### 5.2 OpenAI Whisper（既有遷移）

| 項目 | 值 |
|:---|:---|
| Endpoint | `POST {endpoint}`；預設 `https://api.openai.com/v1/audio/transcriptions` |
| Auth | `Authorization: Bearer <key>` |
| Model | `whisper-1` |
| Body | multipart `file`、`model`、可選 `language` |
| 回應 | `{"text": "..."}` |

### 5.3 Groq

| 項目 | 值 |
|:---|:---|
| Endpoint | `POST {endpoint}`；預設 `https://api.groq.com/openai/v1/audio/transcriptions` |
| Auth | `Authorization: Bearer <key>` |
| Model | `whisper-large-v3`（可自訂，例如 `whisper-large-v3-turbo`） |
| Body | multipart `file`、`model`、`response_format=json`、可選 `language` |
| 最短 | 10 ms |
| 回應 | `{"text": "..."}` |

### 5.4 Mistral

| 項目 | 值 |
|:---|:---|
| Endpoint | `POST {endpoint}`；預設 `https://api.mistral.ai/v1/audio/transcriptions` |
| Auth | `Authorization: Bearer <key>` |
| Model | `voxtral-mini-latest` |
| Body | multipart `file`、`model`、可選 `language` |
| 回應 | `{"text": "..."}` |

### 5.5 ElevenLabs

| 項目 | 值 |
|:---|:---|
| Endpoint | `POST {endpoint}`；預設 `https://api.elevenlabs.io/v1/speech-to-text` |
| Auth | `xi-api-key: <key>`（不是 Bearer） |
| Model | `scribe_v2` |
| Body | multipart `file`、`model_id`、可選 `language_code`、`tag_audio_events=false`、`timestamps_granularity=none` |
| 最短 | 100 ms |
| 回應 | `{"text": "..."}` |

### 5.6 Qwen 錄音檔（含 Token Plan）

| 項目 | 值 |
|:---|:---|
| Endpoint | `POST https://<workspace>.<region>.maas.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation` |
| 無 Workspace 時 | `https://dashscope.aliyuncs.com/api/v1/...`；`ap-southeast-1` 用 `dashscope-intl.aliyuncs.com` |
| Auth | `Authorization: Bearer <key>` |
| Workspace Header | `X-DashScope-WorkSpace: <workspaceId>`（僅非空時） |
| SSE | `X-DashScope-SSE: disable` |
| Model | `qwen-audio-3.0-asr-flash` |
| Body | JSON：`input.messages[0].content[0].input_audio.data = data:audio/wav;base64,...` |
| Parameters | `format=wav`、`sample_rate=16000`、可選 `language_hints` |
| 回應 | `output.text` |
| Token Plan | 模式 `recorded`、Workspace `token-plan`、Region `cn-beijing`／`ap-southeast-1` |

端點驗證：

- Workspace 只允許 `^[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$`。
- Endpoint 必須是 `http`／`https`，host 非空，不能有 userInfo 或 fragment。
- 不可把 URL 填進 Workspace ID；UI 顯示「請輸入業務空間 ID，不要填寫網址。」

### 5.7 Qwen 即時（Phase 4，暫緩）

| 項目 | 值 |
|:---|:---|
| Endpoint | `wss://<workspace>.<region>.maas.aliyuncs.com/api-ws/v1/inference` |
| Auth | `Authorization: Bearer <key>` |
| Workspace Header | `X-DashScope-WorkSpace` |
| Model | `qwen-audio-3.0-asr-flash-streaming` |
| 音訊 | PCM16、16 kHz、mono、連續 frame |
| 事件 | session 建立、`input_audio_buffer.append`、句子結束、final transcript |
| 為何暫緩 | 與系統 STT／Live API 功能重疊；WebSocket 事件 schema 變動風險高；需要新的 session 狀態機與斷線重連；V1 批次已能滿足聽寫。 |

---

## 6. Qwen 音訊正規化

### 6.1 修正的真正內容（R7）

上游不是「把 Qwen 音訊重取樣成某個固定 rate」，而是：

1. 用 RIFF magic 判斷是否為 WAV。
2. 解析 `fmt ` chunk，取得實際 channels／sampleRate／byteRate／blockAlign／bitsPerSample。
3. 允許串流 WAV 的哨兵／推導長度：
   - `_isStreamingWavLength` 直接接受 `0xffffffff`、`0x7fffffff`、`0x7fffffbf`。
   - data size 若超出 RIFF 結尾，且可由 `dataStart + size == declaredEnd` 推導，也可接受。
   - issue #1232 的案例是 **RIFF size `0x7fffffbf`、data size `0x7fffff9b`**；不要把兩者顛倒。
   - 其他測試組合：`(0x7fffffff, 0x7fffffff)`、`(0xffffffff, 0xffffffff)`、`(0x7fffffff, 0x7fffffdb)`、`(0xffffffff, 0xffffffdb)`、`(0xffffffff, null)`、`(null, 0xffffffff)`。
4. 用 `_encodeWav(formatData, audioData)` 重寫 canonical header。
5. 若沒有 RIFF（raw PCM），檢查長度是否為 16-bit 對齊；用 24 kHz 包成 WAV。
6. 回傳 `mime: audio/wav` 與實際 `sampleRate`。
7. 支援 `JUNK`／`LIST` 等額外 chunk、多個 `data` chunk，以及奇數長度的 8-bit WAV padding。

### 6.2 本專案現況

- `network_tts.dart` 的 `_qwenSpeech()` 走 `/services/aigc/text-to-speech/synthesis`，非串流，回應直接 `mime: 'audio/mpeg'`。
- 上游 v1.3.2 走 `/services/aigc/multimodal-generation/generation`，SSE，回傳 WAV。
- `_pcmToWav()` 只有 Gemini 使用；沒有通用 WAV parser／encoder。
- `tts_provider.dart` 播放時依 mime 選副檔名，沒有讀 WAV header。
- 因此**不能直接 cherry-pick 上游的 Qwen TTS 修正**；本專案沒有對應的串流 WAV 路徑。

### 6.3 建議做法

新增 `lib/core/services/audio/wav_codec.dart`（Phase 1 就會需要，供 ASR 上傳）：

```dart
bool isRiffWav(Uint8List bytes);
Uint8List pcm16MonoToWav(Uint8List pcm, {required int sampleRate});
WavInfo parseWav(Uint8List bytes, {bool allowStreamingLengths = false});
Uint8List encodeWav(Uint8List formatData, Iterable<Uint8List> audioData);
Uint8List normalizeWavForPlayback(Uint8List bytes);
```

規則：

- `parseWav` 要驗證 RIFF／WAVE／`fmt `／`data`，拒絕 blockAlign 不一致、bitsPerSample 非 8 的倍數、byteRate 不符。
- `normalizeWavForPlayback` 只重寫 header，不重取樣。
- 若 `data` 長度不是 blockAlign 的倍數，直接報錯，不補零；不可默默播放破碎音訊。
- 多個 `fmt ` chunk 內容不一致 → 報錯；`data` 為空 → 報錯。
- TTS 播放前：
  - 先 `isRiffWav`；是 WAV 就 `normalizeWavForPlayback`。
  - 不是 WAV 才依 mime 處理。
  - `mime` 不可再無條件相信供應商；以 magic 為準。
- Phase 1 先把 `network_tts.dart` 的 `_pcmToWav()` 移到 `wav_codec.dart`，避免兩份實作；Gemini 測試要回歸。

### 6.4 Phase 5 前置條件

在改任何 Qwen TTS 播放程式碼前，先做：

1. 用真實金鑰呼叫目前 `_qwenSpeech()` 的 endpoint／model。
2. 記錄 HTTP status、`Content-Type`、前 32 bytes、是否為 JSON／SSE／binary。
3. 若是 JSON（例如 `output.audio.url` 或 `output.audio.data`），先修回應解析，再談 WAV 正規化。
4. 若是 binary WAV，才套用 §6.1。
5. 若是 MP3，Phase 5 不需要，改為關閉或另案。

### 6.5 何時做

| 情境 | 是否需要 |
|:---|:---:|
| 只做批次 STT（本計畫 Phase 1–3） | 需要 `pcm16MonoToWav`，但不需要 TTS 播放修正 |
| 要做 Qwen 錄音檔上傳 | 需要 WAV header，不需要串流哨兵解析 |
| 要做 Qwen 即時 | 需要 PCM frame，不需要 WAV |
| 要修 Qwen TTS 播放 | 需要完整 `parseWav`＋`normalizeWavForPlayback`，且先確認 API 契約 |

因此 Phase 1 先做最小 WAV codec；Phase 5 再補串流哨兵與 TTS 播放路徑。

---

## 7. 設定頁與 l10n

### 7.1 Hint 樣式（R14）

在 `stt_services_page.dart` 的 `_inputRowMobile` 與其他 STT 輸入欄位加入：

```dart
import '../../../theme/app_font_weights.dart';

final theme = Theme.of(context);
final hintStyle = TextStyle(
  color: theme.colorScheme.onSurface.withValues(
    alpha: theme.brightness == Brightness.dark ? 0.42 : 0.46,
  ),
  fontWeight: AppFontWeights.regular,
);
```

`InputDecoration(hintText: hint, hintStyle: hintStyle, ...)`。

- 不要改動已輸入文字的樣式；只讓 placeholder 更淡、更細。
- 使用 `AppFontWeights.regular`，不要直接用 `FontWeight.w400`；Android 會做字重正規化。
- 套用範圍：STT 編輯 sheet 的所有 `TextField`，包含未來的 Workspace ID／Region／Endpoint。

### 7.2 Workspace ID 欄位

僅在 `kind == qwenAudio && mode == recorded` 時顯示：

- Label：`Workspace ID`
- Hint：`e.g. token-plan`
- 說明文字：Token Plan 使用錄音檔模式、Workspace 填 `token-plan`、Region 要與金鑰匹配。
- 驗證：空白允許（走一般 DashScope）；非空必須符合 Workspace regex；顯示 `Enter a workspace ID, not a URL.`
- Region：`cn-beijing`、`ap-southeast-1` 兩選項。
- Endpoint override：可選；空白時依 Workspace／Region 自動組 URL。

### 7.3 新增 l10n key

以本專案既有 `sttServices` 前綴命名，避免和上游 `asrServices` 混用：

| Key | 英文 | 簡中 | 繁中 |
|:---|:---|:---|:---|
| `sttServicesFieldWorkspaceIdLabel` | Workspace ID | 业务空间 ID | 業務空間 ID |
| `sttServicesFieldRegionLabel` | Region | 地域 | 地域 |
| `sttServicesFieldLanguageLabel` | Language | 语言 | 語言 |
| `sttServicesModeLabel` | Recognition mode | 识别模式 | 辨識模式 |
| `sttServicesModeRealtime` | Real-time | 实时 | 即時 |
| `sttServicesModeRecorded` | Recorded audio | 录音转写 | 錄音轉寫 |
| `sttServicesWorkspaceIdHint` | e.g. token-plan | 例如：token-plan | 例如：token-plan |
| `sttServicesWorkspaceIdInvalid` | Enter a workspace ID, not a URL. | 请输入业务空间 ID，不要填写网址。 | 請輸入業務空間 ID，不要填寫網址。 |
| `sttServicesQwenTokenPlanHint` | For Token Plan, choose Recorded audio, enter token-plan as the Workspace ID, and select the region for your key. | 使用 Token Plan 时，选择录音转写，业务空间 ID 填 token-plan，并选择与密钥对应的地域。 | 使用 Token Plan 時，選擇錄音轉寫，業務空間 ID 填 token-plan，並選擇與金鑰對應的地域。 |
| `sttServicesTranscribing` | Transcribing… | 正在转写… | 正在轉寫… |
| `sttServicesTranscriptionFailed` | Transcription failed: {error} | 转写失败：{error} | 轉寫失敗：{error} |
| `sttServicesNoSpeechDetected` | No speech was detected. | 未检测到语音。 | 未偵測到語音。 |
| `sttServicesMicrophonePermissionDenied` | Microphone permission was not granted. | 未授予麦克风权限。 | 未授予麥克風權限。 |

注意：

- `sttServicesTranscriptionFailed` 在 ARB 需要 `@sttServicesTranscriptionFailed` 的 `placeholders.error` 定義。
- 本專案有 **四個** ARB：`app_en.arb`、`app_zh.arb`、`app_zh_Hans.arb`、`app_zh_Hant.arb`。使用者說的「英文、簡中、繁中」對應三個語言，但 `app_zh.arb` 是簡中別名，必須同步，否則 `zh` locale 會缺 key。
- 修改 ARB 後執行 `flutter gen-l10n`，不要手改 `app_localizations*.dart`。
- 確認 `untranslated-messages-file` 沒有新增缺漏。

---

## 8. 分階段計畫

### Phase 0：範圍凍結與失敗案例（1–2 人日）

**目標**：先證明目前「選了第三方服務但沒有作用」，並固定相容性與平台契約。

工作：

- [ ] 擴充 `test/network_stt_test.dart`：`SttServiceOptions.tryFromJson` 對 `openaiWhisper`／`groqWhisper` 的 round-trip。
- [ ] 擴充 `test/network_stt_test.dart`：未知 kind 回傳 `null`，不再靜默變成 OpenAI。
- [ ] 新增 `test/core/services/stt/stt_endpoint_test.dart`：`resolveSttEndpoint` 對完整 endpoint／base／只有 host／結尾斜線／重複 suffix／proxy 前綴／ElevenLabs `/v1`／OpenAI `…/v1`／Groq `…/openai` 的行為。
- [ ] 擴充 `test/settings_provider_stt_test.dart`：舊 `stt_selected_v1` index 遷移到 id；選取服務被刪除後 fallback 系統 STT（行為變更，見 §4.2.2；更新既有 out-of-range 測試）。
- [ ] 擴充 `test/settings_provider_stt_test.dart`：`selectedSttService != null` 時，聽寫仍走系統 STT（目前行為；作為回歸基線）。
- [ ] PCM spike：Windows／Android 各錄 1 秒，檢查實際 sample rate 與 chunk 對齊。
- [ ] Audio session spike：iOS／Android 用 `record` 擷取，確認不觸發 voiceChat 的 AGC／路由問題。
- [ ] Audio focus spike（Android 實機）：dictation 期間觸發 focus loss（播放通知音／其他 app 播放），確認 mic 不因預設 `PAUSE` 永久靜音；固定 `audioInterruption: none` 後重測。
- [ ] 文件化五個 Provider 的請求契約（§5）。

**完成定義**：測試能重現「設定存在但執行時未使用」、「未知 kind 誤 fallback」、「endpoint 重複拼接」；PCM／audio session／focus spike 有結果。

### Phase 1：共用基礎（3–4 人日）

**目標**：建立可測試的音訊與設定基礎，不接任何 Provider。

工作：

- [ ] 新增 `lib/core/services/audio/wav_codec.dart`：
  - `pcm16MonoToWav`、`isRiffWav`、`parseWav`（先不做串流哨兵）、`encodeWav`。
  - 把 `network_tts.dart` 的 `_pcmToWav` 移到這裡，Gemini 回歸。
- [ ] 新增 `lib/core/services/stt/stt_audio_capture.dart`：
  - `RecordAsrAudioCapture`、`SttAudioCapture`。
  - PCM carry 與 odd-chunk 測試。
- [ ] 新增 `lib/core/services/stt/stt_endpoint.dart`：
  - `resolveSttEndpoint` 與測試。
- [ ] 擴充 `network_stt.dart`：
  - 新 enum、新欄位、共同 getter、`tryFromJson`。
  - 舊 kind／完整 endpoint 相容。
- [ ] `settings_provider`：
  - 逐筆解析、保留有效項目。
  - `stt_selected_id_v1` 遷移。
- [ ] `stt_services_page.dart`：
  - 編輯時保留 `id`；使用共同 getter。
- [ ] `PlatformAudioSetup.initAudioSessionForDictation()`。
- [ ] 新增 `lib/core/services/stt/cloud_stt_service.dart`：
  - `SttSession` 介面、`BatchSttSession` 骨架（狀態機、分段、flush、cancel）。
- [ ] 測試：
  - WAV header 44 bytes、RIFF／WAVE／fmt／data、sample rate 16000、bits 16。
  - PCM 長度為奇數時依 §4.3.1 丟棄最後 1 byte；WAV data 長度仍為偶數。
  - 分段邊界：30 秒、0 bytes、超過上限。
  - `cancel()` 不會再送後續 segment；late response 不 emit。
  - `finish()` 重複呼叫回傳同一 future。

**完成定義**：不連網也能證明 WAV、PCM 對齊、endpoint 與設定遷移正確；`flutter test` 相關測試通過。

### Phase 2：Groq／Mistral／OpenAI 批次轉錄＋聽寫接線（5–7 人日）

**目標**：第一個可用 End-to-End 流程。

工作：

- [ ] 實作 multipart 請求：
  - OpenAI：Bearer、`model`、`language`
  - Groq：Bearer、`model`、`response_format=json`、最短 10 ms
  - Mistral：Bearer、`model`
- [ ] `BatchSttSession` 完整實作：`joinTranscript`、每段 final 累積（batch 無 partial）、`finish()` 冪等、`cancel()` close client。
- [ ] 新增 `NetworkDictationSession`（plain class）與 `NetworkDictationUpdate`。
- [ ] `HomePageController`：
  - start／stop／pause／resume 分支。
  - 文字模型 `base + final + partial`，每次覆寫不 append。
  - `isTranscribing` getter。
  - `onAppLifecycleStateChanged` 取消、`dispose` 取消。
- [ ] `ChatInputBar`／`ChatInputSection` 加 `isTranscribing`；`home_page.dart` 傳遞。
- [ ] 設定頁加入 Mistral；既有 Groq 改為可用。
- [ ] per-service 可用性：OpenAI／Groq／Mistral 可用；ElevenLabs／Qwen 仍顯示「尚未支援」。
- [ ] 錯誤處理：401／403／413／422／timeout／空結果／取消。
- [ ] 測試：
  - MockClient 檢查 multipart 欄位、auth header、WAV filename／content-type。
  - UTF-8 中文回應。
  - 取消、空結果、late response。
  - 聽寫追加文字不覆蓋既有內容；每段 final 不重複。
  - `joinTranscript` 中英文。
  - `isTranscribing` UI。

**完成定義**：Windows 上以 Groq 或 Mistral 金鑰完成一次聽寫；系統 STT 路徑回歸不變；單元與 widget 測試通過。

### Phase 3：ElevenLabs＋Qwen 錄音檔／Token Plan＋UI／l10n（3–4 人日）

**目標**：補齊第二家與 Qwen 的差異化能力。

工作：

- [ ] ElevenLabs multipart：
  - `xi-api-key`
  - `model_id=scribe_v2`
  - `language_code`
  - `tag_audio_events=false`
  - `timestamps_granularity=none`
  - 最短 100 ms
- [ ] Qwen 錄音檔：
  - JSON body、base64 WAV data URL
  - `X-DashScope-WorkSpace`
  - `X-DashScope-SSE: disable`
  - `parameters.format=wav`、`sample_rate=16000`、`language_hints`
  - 解析 `output.text`
- [ ] Qwen Token Plan UI：
  - 模式：V1 只開放「錄音轉寫」；「即時」標示尚未支援。
  - Workspace ID、Region、Endpoint override。
  - 驗證與錯誤文案。
- [ ] Hint 樣式套用到所有 STT 欄位（`AppFontWeights.regular`）。
- [ ] l10n：四個 ARB 補 key（含 `@` placeholders），`flutter gen-l10n`。
- [ ] 測試：
  - ElevenLabs header／fields（不可出現 `model`／`language`，需有 `model_id`／`language_code`）。
  - Qwen JSON body、workspace header、base64 WAV、`output.text`。
  - Workspace regex／URL 誤填。
  - Widget：Qwen 欄位只在 recorded 模式顯示；hintStyle 顏色／字重。
  - l10n：新 key 在四個 ARB 都存在。

**完成定義**：ElevenLabs 與 Qwen Token Plan 各完成一次真實轉錄；設定頁顯示正確；三語系無缺 key。

### Phase 4：Qwen 即時（暫緩，5–7 人日）

**前提**：Phase 2／3 穩定，且使用者明確需要低延遲逐字結果。

工作：

- [ ] WebSocket 連線、session 建立、PCM frame 傳送。
- [ ] 句子結束／final transcript 事件解析。
- [ ] 斷線重連、取消、超時。
- [ ] 與聽寫狀態機整合（取代批次模式）。
- [ ] 測試：事件 fixture、重連、取消、無最終結果。

**建議**：先不做。理由見 §14。

### Phase 5：Qwen TTS WAV 播放正規化（有條件，1–2 人日）

**前提**：§6.4 的真實回應檢查完成，確認 Qwen TTS 回應是 WAV／PCM，或使用者回報播放雜音／取樣率錯誤。

工作：

- [ ] `wav_codec.dart` 補 `allowStreamingLengths` 與哨兵／推導長度。
- [ ] `network_tts.dart` 的 Qwen 路徑：
  - 先偵測 RIFF。
  - 是 WAV → parse＋encode，回傳 `audio/wav` 與實際 sampleRate。
  - 是 raw PCM → 檢查 16-bit 對齊，24 kHz 包 WAV。
  - 不是兩者 → 才依原 mime。
- [ ] `tts_provider.dart` 播放前用 magic 判斷，不只信 mime。
- [ ] 測試：
  - 正常 WAV、額外 chunk、多個 data chunk。
  - RIFF／data 長度組合（§6.1 的八組）。
  - 奇數長度 PCM 報錯；奇數 8-bit WAV padding。
  - 非 WAV 的 MP3 不受影響。

**完成定義**：Qwen TTS 的 WAV 不再因 header 哨兵或錯誤 mime 而播放失敗；MP3 路徑回歸不變。

---

## 9. 測試計畫

### 9.1 單元測試

既有 `test/network_stt_test.dart`、`test/settings_provider_stt_test.dart`、`test/stt_locale_resolver_test.dart` 以**擴充**為原則，不另建同名檔案（避免兩份測試各自漂移）。其餘新檔放 `test/core/services/stt/`：

| 測試檔 | 內容 |
|:---|:---|
| （擴充）`test/network_stt_test.dart` | 舊 kind 相容、新 kind round-trip、未知 kind 回 null、Qwen 欄位預設、共同 getter |
| `stt_endpoint_test.dart`（新） | 完整 endpoint／base／只有 host／結尾斜線／重複 suffix／proxy 前綴／query／ElevenLabs `/v1`／OpenAI `…/v1`／Groq `…/openai` |
| （擴充）`test/settings_provider_stt_test.dart` | 逐筆容錯、未知 kind 不覆蓋、舊 index 跳過無效項後不位移、id 選取、刪除 fallback（更新既有 out-of-range 測試） |
| `wav_codec_test.dart` | header、sample rate、bits、odd length、串流哨兵／推導長度（Phase 5） |
| `cloud_stt_service_test.dart` | 分段、flush、cancel、空結果、拼接、每段 final、batch 無 partial、`finish()` 冪等、late response |
| `audio_transcription_test.dart` | OpenAI／Groq／Mistral／ElevenLabs 的 multipart 欄位與 auth |
| `qwen_audio_http_test.dart` | JSON body、workspace header、data URL、`output.text` |
| `stt_audio_capture_test.dart` | 權限、start／stop／cancel、dispose、odd chunk carry（fake recorder） |
| `transcript_join_test.dart` | 中文、英文、中英混合、標點、空白、韓文 |

### 9.2 Widget 測試

新增 `test/features/settings/stt_services_page_test.dart`：

- 服務類型清單包含 Mistral／ElevenLabs／Qwen。
- 選 Qwen → 顯示模式、Workspace ID、Region。
- 選 recorded → Workspace ID 可見；realtime → 標示尚未支援。
- 空白 Workspace 可儲存；URL 形式顯示錯誤。
- `hintStyle` 的顏色 alpha 與字重正確（深淺色各一）。
- 不可用服務顯示「尚未支援」；可用服務不顯示該徽章；不可用服務不可選取。
- 編輯既有服務後 `id` 不變。

新增／擴充 `test/features/home/widgets/chat_input_bar_is_transcribing_test.dart`：

- `isTranscribing == true` 時顯示轉錄狀態。
- `isTranscribing == false` 時不顯示。

### 9.3 手動 Smoke

| 平台 | 檢查 |
|:---|:---|
| Windows | 系統 STT 聽寫仍正常；Groq 聽寫中文／英文；停止後文字正確追加；網路斷線顯示錯誤且不清空 |
| Windows | 英文分段之間有空格、中文之間沒有空格；每段 final 不重複 |
| Windows | Mistral、ElevenLabs 各一次；短音訊（<1 秒）不因最短長度被拒 |
| Windows | Qwen Token Plan：Workspace `token-plan`、Region 與金鑰匹配；成功取得文字 |
| Windows | Qwen 一般模式（無 Workspace）成功 |
| Android | 麥克風權限；聽寫；切換服務；系統 STT 回歸；audio session 不啟用 voiceChat 處理；focus loss 後收音不中斷 |
| 全部 | 取消轉錄會釋放麥克風；再次開始不會「Already listening」 |
| 全部 | 切換 App 背景／回來，不會卡在「轉錄中」；輸入文字保留 |
| 全部 | 舊資料若選到 Qwen realtime，開始聽寫會提示尚未支援並走系統 STT，不會送批次 |
| 全部 | 重啟 App 後選取的服務仍是同一個（id 遷移） |
| TTS（Phase 5） | Qwen WAV 播放無雜音、時間長度正確；MP3 不受影響 |

### 9.4 回歸

- `flutter analyze`
- `flutter test test/core/services/stt test/network_stt_test.dart test/settings_provider_stt_test.dart test/stt_locale_resolver_test.dart test/core/services/tts test/features/settings test/features/home`
- 既有系統 STT 測試（若有）與 `voice_chat` 相關測試。
- 不跑全套 1,600+ 測試，除非改到共用 provider；Phase 2 接線 `HomePageController` 時建議跑 `test/features/home` 相關。

### 9.5 無法在 CI 驗證的部分

- 真實 API 金鑰（Groq／Mistral／ElevenLabs／Qwen／Token Plan）。
- Windows 麥克風裝置切換、藍牙耳機。
- Qwen Token Plan 的帳號權限與地域匹配。
- 這些列入 release checklist，不宣稱已通過。

---

## 10. 失敗模式與處理

| 現象 | 可能原因 | 處理 |
|:---|:---|:---|
| 401／403 | 金鑰錯誤、Workspace／Region 不匹配、Token Plan 未開通 | 顯示 provider 回傳訊息；不要重試到死；引導檢查 Region／Workspace |
| 413／422 | 音訊太長、格式不符、太短 | 30 秒分段；短音訊補零；顯示「音訊格式不支援」 |
| 404／重複路徑 | `baseUrl` 已是完整 endpoint，resolver 又拼一次 | `resolveSttEndpoint` 先檢查 suffix；測試覆蓋 |
| Timeout | 網路慢、伺服器無回應 | 專用 client close；保留既有文字；提供重試；不自動重送 |
| 空 `text` | 靜音、語言不符、模型判斷無語音 | 顯示「未偵測到語音」；不追加空白 |
| 麥克風被占用 | 系統 STT 未停、Live API 正在用 | 開始前停止系統 STT；顯示「麥克風忙碌」 |
| 收音中途變靜音（App 仍在前景） | Android focus loss 觸發 record 預設 `PAUSE`，focus 回來不恢復（手冊 §5.2.1） | `audioInterruption: AudioInterruptionMode.none`；Phase 0 實機 spike |
| `Already listening` | `speech_to_text` 舊 session 未歸零 | 網路模式不使用 `speech_to_text`；切回系統時先 `stop()` 並等待 |
| App 進背景 | 擷取被系統暫停 | 取消 session；保留輸入文字；回來後提示重試；不自動送出半段 |
| PCM 奇數長度 | chunk 切在半個 sample | 1-byte carry；flush 只切偶數；finish 剩 1 byte 丟棄並記錄 |
| 選到錯誤服務 | 未知 kind 被跳過、整數 index 位移 | id 優先選取；遷移舊 index；找不到 fallback 系統 |
| 服務清單全空 | 單筆 JSON 壞掉觸發整份 catch | 逐筆 `tryFromJson`；保留有效項目 |
| WAV header 錯誤 | 串流長度哨兵、odd length | `parseWav(allowStreamingLengths)`；失敗時顯示格式錯誤，不播放雜音 |
| 取消後又收到結果 | 請求已送出，late response 回寫 | `_cancelled` 旗標；client close；await 後檢查 |
| 設定頁存檔失敗 | SharedPreferences 寫入失敗 | 顯示錯誤；保留表單內容；不要假裝成功 |

---

## 11. 風險與對策

| 風險 | 影響 | 對策 |
|:---|:---|:---|
| 範圍膨脹成完整 ASR 子系統 | 工期失控、破壞既有語音 | 只做 5 個批次 Provider；Qwen 即時、Sherpa、其他 Provider 明確排除 |
| Endpoint 重複拼接 | 既有 OpenAI／Groq 使用者 404 | `resolveSttEndpoint` 同時接受 base／full；測試完整 endpoint 與 proxy path |
| 選取 index 位移 | 使用者以為在用 A、實際用 B | id 優先；舊 index 一次性遷移；編輯保留 id |
| 單筆壞資料清空全部服務 | 使用者設定消失 | 逐筆 parse；保留有效項目；只記錄壞項 |
| 麥克風雙重持有 | 錄音失敗、系統 STT 卡住 | 單一 `SttAudioCapture` 鎖；切換前 stop；測試 `Already listening` |
| PCM chunk 未對齊 | WAV 破損、轉錄失敗 | 1-byte carry；偶數 flush；spike 驗證實際 sample rate |
| 批次延遲影響聽寫體驗 | 使用者覺得「講完很久才出字」 | 30 秒分段、`isTranscribing` 狀態、每段 final 即時顯示；必要時再加 VAD |
| Partial/final 重複 | 文字重複、使用者要手動刪 | 批次以 final 權威；partial 僅 Phase 4；每次由 base+final 重算 |
| Qwen Token Plan 無法實測 | 上線後才發現 Region／權限問題 | 列 release checklist；提供 endpoint override；錯誤訊息帶 provider 原文 |
| Qwen TTS API 契約未知 | Phase 5 修錯地方 | 先抓真實回應；必要時先修 JSON/SSE 解析 |
| Qwen 即時 protocol 不穩定 | 連線／事件解析常壞 | 暫緩；若要做，pin 模型與事件 fixture |
| API Key 明文存 SharedPreferences | 裝置被入侵時外洩 | 依手冊 §7.3（C-S01）走備份加密（另案），**不**遷移 `flutter_secure_storage`；本計畫只做日誌脫敏與錯誤訊息截斷 |
| l10n 四個 ARB 不同步 | `zh` locale 缺字、gen-l10n 警告 | 四個檔案一起改；CI 檢查 key 數量 |
| 設定頁約 1,100 行再膨脹 | 維護困難 | 只加欄位與共同 getter；必要時抽 widget，但不全面重構 |
| `record` 在 Windows 的 PCM 格式差異 | WAV 播放／上傳失敗 | Phase 0 spike；固定 16 kHz mono；測試 header 與實際 rate |
| 行動端 audio session 處理 | AGC／路由造成辨識變差 | dictation 專用 session；不用 voiceChat；實機測試 |
| 上游程式碼授權／ attribution | 合規風險 | 保留 AGPL 標頭與 commit 參照；不複製無關程式碼 |
| 既有 `stt_services_v1` 資料損壞 | 使用者服務消失 | `tryFromJson` 容錯；未知 kind 跳過但不覆蓋原 JSON；提供除錯 log |

---

## 12. PR 切分

| PR | 內容 | 依賴 |
|:---:|:---|:---|
| 1 | `feat(stt): add WAV codec, PCM capture, endpoint resolver, settings migration, and batch session skeleton` | 無 |
| 2 | `feat(stt): add batch transcription core and OpenAI/Groq/Mistral` | PR 1 |
| 3 | `feat(stt): use selected cloud service for inline dictation` | PR 2 |
| 4 | `feat(stt): add ElevenLabs and Qwen recorded transcription` | PR 2 |
| 5 | `feat(stt): add Qwen Token Plan settings, hint styling, and l10n` | PR 4 |
| 6 | `fix(tts): normalize Qwen WAV before playback`（有條件） | PR 1 |
| 7 | `feat(stt): add Qwen realtime transcription`（暫緩） | PR 3 |

建議每個 PR 都附：
- 對應測試。
- 手動 smoke 結果（若有金鑰）。
- 若無法實測，明確寫「未驗證」與原因。
- 對應的手冊章節更新（§3.3 行為變更、§8 目錄、§5 新平台陷阱）。

---

## 13. 估時

| 階段 | 人日 | 備註 |
|:---|---:|:---|
| Phase 0 | 1–2 | 測試、PCM／audio session／focus spike |
| Phase 1 | 3–4 | WAV／擷取／endpoint／設定遷移 |
| Phase 2 | 5–7 | 三個 Provider＋聽寫 session＋UI 狀態 |
| Phase 3 | 3–4 | 兩個 Provider＋Token Plan＋UI／l10n |
| Phase 4 | 5–7 | 暫緩 |
| Phase 5 | 1–2 | 有條件 |
| QA／手動 smoke | 2–3 | 含 Windows／Android |
| **建議範圍合計** | **14–20** | Phase 0–3＋QA，不含 Phase 4／5 |

若只要最快看到成果：Phase 0＋1＋Phase 2 的 Groq 部分，約 **7–10 人日**，即可在 Windows 上用 Groq 聽寫。

---

## 14. 不導入清單

| 項目 | 決定 | 理由 |
|:---|:---|:---|
| Sherpa／ONNX 本機模型 | 不導入 | 模型檔大、平台 bundling 複雜、與 `speech_to_text` 系統引擎重疊；本專案不需要離線模型。 |
| OpenAI Realtime ASR | 不導入 | 需 WebSocket、VAD、事件狀態機；受眾與 Qwen 即時重疊；暫無需求。 |
| Volcengine、MiMo、Step | 不導入 | 本次需求未提及；多一家就多一組協定與測試。 |
| Qwen 即時（Phase 4） | 暫緩 | 與系統 STT／Live API 重疊；維護成本高；批次已足夠。 |
| 上游整個 `AsrProvider`／`asr_services_section.dart` | 不整包移植 | 2,000+ 行且與本專案設定模型衝突；只移植行為。 |
| 語音通話改用雲端 STT | 不導入（V1） | 會破壞既有 final callback、每句重啟、暫停語義；另案評估。 |
| Qwen TTS 全面重寫 | 不導入 | 只做 WAV 容器正規化；不改 TTS 佇列／播放器架構。 |

---

## 15. 驗收標準（DoD）

- [ ] 使用者在 STT 設定頁可新增／編輯／選取 OpenAI、Groq、Mistral、ElevenLabs、Qwen。
- [ ] 選定第三方服務後，行內聽寫會使用該服務；未選定時系統 STT 行為完全不變。
- [ ] 五個批次 Provider 的請求契約有單元測試（multipart／JSON、auth、model、language）。
- [ ] `resolveSttEndpoint` 對完整 endpoint／base／只有 host／重複 suffix／Groq `…/openai` 版本段有測試；既有 OpenAI／Groq 設定不會 404。
- [ ] 未知 kind 不會靜默變成 OpenAI；選取以 id 優先，重啟後仍是同一個服務；刪除選取中的服務後回系統 STT。
- [ ] Qwen Token Plan 可填 `token-plan`、選 Region、成功轉錄；Workspace 填 URL 會被擋下。
- [ ] 短音訊（Groq <10 ms、ElevenLabs <100 ms）會補零，不因長度被拒。
- [ ] PCM chunk 為奇數長度時不會產生破損 WAV；30 秒分段與實際 sample rate 一致。
- [ ] 批次每段 final 不會重複追加；英文分段有空格、中文分段無空格；Phase 4 partial 另測。
- [ ] V1 DoD 不含 Qwen 即時；UI 明確標示尚未支援。
- [ ] 失敗（401／timeout／空結果／取消）不會清空既有輸入文字，也不會卡在「轉錄中」。
- [ ] App 背景／dispose 會取消網路擷取並釋放麥克風；再次開始不會 `Already listening`。
- [ ] STT 欄位 placeholder 的顏色與字重和已輸入值有明顯區別。
- [ ] `sttServicesWorkspaceIdHint` 等新 key 在英文、簡中、繁中（含 `app_zh.arb`）都存在。
- [ ] 完成後更新《OmniChat 專案開發與維護手冊》：§3.3（批次轉錄）、§5（若新增平台陷阱，例如 Android focus 暫停）、§8（`stt/`、`audio/` 目錄）。
- [ ] `flutter analyze` 無新增警告；相關 `flutter test` 通過。
- [ ] 手動 smoke 結果如實記錄；無金鑰的項目標為「未驗證」，不宣稱通過。
- [ ] 未把 API Key、音訊 base64、完整請求 URL 寫入日誌。

---

## 16. 待確認問題

1. **是否接受 V1 不交付 Qwen 即時？** 本計畫只做批次；若「即時」是硬需求，需另開 Phase 4（+5–7 人日）。
2. **是否同意 `baseUrl` 保留「完整 endpoint」語義？** 這是避免既有 OpenAI／Groq 設定 404 的最小改動；若堅持改成純 base，需要一次性遷移所有使用者資料。
3. **是否有真實金鑰可 smoke？** Groq／Mistral／ElevenLabs／Qwen／Token Plan 各一組；沒有金鑰就只能做契約測試，不能宣稱端到端通過。
4. **Qwen TTS 目前是否真的會回 WAV？** 先用真實回應確認；若回 JSON URL，Phase 5 要先修解析，不能只做 header 正規化。
5. **STT API Key 是否本次就搬 secure storage？** 已決：**不搬**。手冊 §7.3（C-S01）已否決此路線（備份/換機語意、只修一處堵不完），改以備份加密處理（另案）；本計畫只做日誌脫敏與錯誤訊息截斷。
6. **Windows 是否唯一 release blocker？** 若是，Android 可延後 smoke；反之要預留測試時間。
7. **是否接受聽寫 session 在背景時直接取消？** 這是避免半段音訊與網路競態的保守做法；若要在背景完成，需額外設計。

---

## 17. 參考

- 上游 Kelivo `v1.3.2`：Groq／Mistral、Qwen WAV 正規化。
- 上游 Kelivo `v1.3.3`：ElevenLabs（`ca2721e07`）、Qwen Token Plan（`e6023a6e3`）。
- 上游 Kelivo `v1.3.4`：STT hint 樣式、Workspace ID 佔位符、三語系。
- 上游檔案：`lib/core/services/asr/asr_service_options.dart`、`cloud_asr_service.dart`、`asr_audio_capture.dart`、`lib/features/settings/widgets/asr_services_section.dart`。
- 上游測試：`test/core/services/asr/audio_transcription_asr_test.dart`、`qwen_audio_http_asr_test.dart`、`test/core/services/tts/network_tts_test.dart`。
- 本專案：`lib/core/services/stt/network_stt.dart`、`lib/features/settings/pages/stt_services_page.dart`、`lib/features/home/controllers/home_page_controller.dart`、`lib/core/services/tts/network_tts.dart`、`lib/core/providers/tts_provider.dart`、`lib/features/voice_chat/services/platform_audio_setup.dart`。
