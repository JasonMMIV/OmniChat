# OmniChat Voice Chat Mode 優化計畫

> 來源：Code review（2026-08-06）
> 範圍：`lib/features/voice_chat/pages/voice_chat_screen.dart`（1204 行）、`lib/features/chat/voice_chat_provider.dart`、`lib/features/home/pages/home_page.dart` 的 voice chat 入口、`lib/core/providers/tts_provider.dart` 整合面、相關 l10n 與權限設定；另含 `lib/features/home/controllers/home_page_controller.dart` 的輸入列聽寫（任務 1.6）。
> 目標：修復全部已知 bug、消除死碼、統一重複邏輯、拆分 god class、優化桌面端語音結束機制（任務 1.6），並建立可回歸驗證的行為基準。

---

## 一、問題清單（完整盤點）

### A. Bug（會造成凍結或行為錯誤）

| # | 問題 | 位置 | 影響 |
|---|------|------|------|
| A1 | 靜音約 7 秒後 STT 停止（`pauseFor` timeout / no-match 被當良性錯誤），但 `_isPaused` 仍為 false，UI 顯示「聆聽中」實際已凍結，需手動按暫停/播放才恢復 | `_handleSpeechError`、`_doStartListening`（pauseFor: 7s；桌面版將於 1.6 移除）、onResult 空結果分支 (line 445-447) | 使用者以為在聽，實際沒在聽 |
| A2 | `_showSubtitles` 開關無效：`_toggleSubtitle` 只切換 icon，字幕 `Text` 從未被此 flag 包住 | build() line 882-889 | 功能不存在 |
| A3 | `currentConversationId == null` 分支呼叫 `_startVoiceRecognition()` 而非 `_startVoiceRecognitionAfterProcessing()`，`_isProcessingVoiceInput` 永不重置，`_doStartListening` 永遠被擋 | `_sendToLLM` line 762-774 | 該情境後聽寫永久凍結 |
| A4 | 結束 voice chat 時 `_cleanup()` 未停止 TTS 朗讀，也未取消進行中的 LLM stream（無 subscription handle） | `_cleanup()` line 1155-1195 | 回到主畫面後 TTS 繼續唸；stream 在背景繼續跑 |

### B. 設計問題

| # | 問題 | 位置 |
|---|------|------|
| B1 | `VoiceChatProvider` 是死碼：註冊於 `main.dart`、`home_page` 有 listener，但全專案無人呼叫 `startListening()`/`speak()`；且 app 啟動即初始化 STT 引擎，白白付出成本 | `lib/features/chat/voice_chat_provider.dart`、`main.dart:141`、`home_page.dart:130-131, 231-239` |
| B2 | 兩個同名 `VoiceChatState` enum（provider: idle/listening/speaking；screen: listening/thinking/talking），靠 `hide` 解決衝突 | `home_page.dart:64-65` |
| B3 | `_sendToLLM` 複製了 home page 約 200 行送訊邏輯（truncateIndex、version collapsing、system prompt 注入、search tool 注入、tool defs），兩邊遲早 diverge | `_sendToLLM` line 500-643 vs `chat_actions.dart` |
| B4 | `hasBuiltInSearch` 用 `modelId.contains('1.5') \|\| contains('gemini-pro')` 判斷，脆弱 | line 588 |
| B5 | 每個 stream chunk 都 `await chatService.updateMessage()` 寫 DB，長回應產生大量寫入 | line 647-659 |
| B6 | Pause 只停 STT，不中斷進行中的 LLM stream 與 TTS 朗讀；無 barge-in（朗讀中無法以說話打斷） | `_togglePause` line 1039-1056 |
| B7 | 每次 `_doStartListening` 都重新呼叫 `_speechToText.locales()` 解析 locale，未 cache | line 316-425 |
| B8 | role mapping 把所有非 assistant 角色壓成 'user'；voice chat 不支援圖片/附件（已知限制，需文件化） | line 563-571 |

### C. 小問題（hygiene / robustness）

| # | 問題 | 位置 |
|---|------|------|
| C1 | `'Paused'` 狀態文字硬編碼英文，未本地化 | `_getStateText` line 1001 |
| C2 | `_handleSpeechError` line 243 與 onResult line 435 的 `setState` 無 `mounted` 保護，dispose 後的 platform callback 可能 throw | |
| C3 | 全檔 40+ 處 `print()` debug 輸出；STT initialize 還開著 `debugLogging: true` | 全檔、line 162 |
| C4 | `_voiceStopTimer` 宣告後從未賦值，死變數 | line 72 |
| C5 | 麥克風權限被永久拒絕（permanentlyDenied）時，overlay 按鈕只重呼 `request()`（不會再彈系統對話框），未引導至系統設定 | `_requestMicrophonePermission` line 1028-1037 |
| C6 | 1204 行 god class：UI + STT + LLM 編排 + TTS + platform channel + locale 解析全部混在一個 State | `voice_chat_screen.dart` |
| C7 | 頂部返回鍵直接 `Navigator.pop()` 未走 `_cleanup()`（靠 dispose 兜底），與中央停止鍵行為不一致 | line 826 |
| C8 | TTS 若 completion handler 永不觸發（引擎被殺），`speak()` future 永不完成，卡在 talking 狀態無 watchdog | `tts_provider.dart:294-316` |

### D. 平台面確認（已驗證 OK，無需改動）

- Android：`RECORD_AUDIO`、`MODIFY_AUDIO_SETTINGS`、`BLUETOOTH_CONNECT`、`FOREGROUND_SERVICE(_DATA_SYNC)` 權限齊全；`MainActivity.kt` call mode（SCO/audio focus）有 start/stop 對稱與 `onDestroy` 兜底。
- iOS：`NSMicrophoneUsageDescription` 已存在。
- Windows：`speech_to_text_windows` / `permission_handler_windows` path override 有註解說明。

---

## 二、執行計畫

> 原則：Phase 1/2 不改檔案結構、風險最低先落地；Phase 3 結構重構獨立成 commits，方便 revert。每個任務附驗收條件。

### Phase 1 — P0 Bug 修復

#### 任務 1.1：靜音逾時後自動恢復聆聽（A1）

**設計背景與機制（重要）**

`pauseFor: 7s` 是刻意設計：Android 系統辨識引擎在未設定 `EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MSEC` 時，約 5~8 秒無語音即自行結束 session（`SpeechToTextPlugin.kt` 未設定該參數，且會把純靜音的 `ERROR_NO_MATCH` 轉為 `error_speech_timeout`）。`pauseFor` 與此時限對齊，作為 Android 上的確定性 fallback。桌面版則不同：**Windows 原生引擎（UWP `ContinuousRecognitionSession`）在語音結束後會自行判斷語意結束、停止聆聽並送出 `finalResult`（已實測驗證，2026-08-06）**，因此桌面端不依賴 `pauseFor` 作為結束通道（見任務 1.6：桌面版將移除 `pauseFor`）。`pauseFor` 的目的是讓 session 以可控方式結束後**自動重啟**，形成連續對話循環。

Session 結束有兩個通道，重啟邏輯必須兩者都覆蓋：

| 通道 | 觸發來源 | 事件 |
|------|---------|------|
| A（Android 上通常先到，~5s） | 系統引擎靜音偵測 | 有說過話 → `onEndOfSpeech` → finalResult；純靜音 → `error_speech_timeout`（onError） |
| B（`pauseFor: 7s`） | plugin Dart-side timer（`_stopOnPauseOrListen`） | 停止並把累積內容包成 finalResult（任務 1.6 後僅 Android/iOS 有此通道；桌面版改依賴原生自動結束） |

**現況失敗原因**：line 83 註解 `// Removed restart timers for pause-on-timeout behavior` — 重啟 timer 曾存在但被移除；`_handleSpeechError` 註解「不要自動 pause」被誤擴大為「不要自動重啟」，導致兩條結束通道都無人重啟，UI 卻仍顯示「聆聽中」。

**邊界條件分析（不會誤重啟的保證）**

1. **說話中不會被 7 秒切斷**：`pauseFor` 語意是「最後語音事件後靜音 7 秒」而非「session 滿 7 秒」。plugin 每次收到變化的辨識結果就重置 `_lastSpeechEventAt`（`_notifyResults` line 667-669），timer 隨之延展（`_setupListenAndPause`），到期時還會二次檢查（`_stopOnPauseOrListen`）。只要 partial results 持續流入，timer 永不到期。句中停頓 >7 秒視為語句結束，屬設計訊號。
2. **thinking/talking 期間不會重啟**：收到 final result 後 app 呼叫 `stop()`，plugin 內 `_shutdownListener()` 會 `_listenTimer?.cancel()`（line 747），timer 隨 session 消滅；無 session 即無回調，重啟無從觸發；且 `_resumeListening()` 的 `_currentState == listening` 與 `_isProcessingVoiceInput` guard 雙重擋下任何殘留回調。唯一 re-entry 為 TTS 完成後的 `_startVoiceRecognitionAfterProcessing()`。
3. **`listenFor: 60s` 硬上限**：連續說話超過 60 秒 session 會被切斷並送處理（之後照常循環恢復）。若預期超長獨白，可評估調高此值。

**修法（恢復原設計意圖）**

- 決策：voice chat 維持「持續對話」體驗，靜音/session 結束後自動重新聆聽（而非假性凍結、也非自動 pause）。
- 修改 `voice_chat_screen.dart`：
  - 抽單一 `_resumeListening()` helper（含 `_isProcessingVoiceInput` 重置與 guard），三條結束路徑統一呼叫：
    1. onResult 空最終結果分支（line 445-447，通道 A 純靜音或 B 到期）。
    2. `_handleSpeechError` 良性錯誤分支（line 226-241，通道 A speech timeout / no match）。
    3. `_handleSpeechStatus` 的 `done`/`notListening`（通道 B 到期或 listenFor 60s 總上限）。
  - Guard：`!_isPaused && !_isCleaningUp && mounted && _currentState == listening && !_isProcessingVoiceInput`；以 `_isListening` flag 做 idempotent，兩通道競態時不會重複啟動。
  - 保留 `_manualStopInProgress` 判斷，避免手動停止被自動重啟覆蓋。
  - 防死循環：短 debounce（~250ms）+ 連續空結果計數器，若連續 N 次（如 5 次）立即結束且無內容（麥克風故障/引擎異常），轉為 paused 並顯示提示，不再重啟。
- 驗收：
  - 進入 voice chat 不說話 15 秒以上，UI 持續顯示「聆聽中」且能辨識隨後說出的話。
  - Android 純靜音（error_speech_timeout）與有說話後靜音（finalResult）兩條路徑皆自動恢復（debug log 可確認重啟）。
  - 按暫停後不會自動重啟；連續失敗保護觸發時顯示 paused。

#### 任務 1.2：字幕開關生效（A2）
- build() 中字幕區塊以 `_showSubtitles` 條件包住（關閉時可保留區塊高度或顯示佔位，避免 layout 跳動）。
- 驗收：切換按鈕後字幕實際隱藏/顯示，icon 與狀態一致。

#### 任務 1.3：無對話分支凍結修復（A3）
- `_sendToLLM` line 772-774 改為 `_startVoiceRecognitionAfterProcessing()`（或統一改用 1.1 的 `_resumeListening()`）。
- 驗收：在無 currentConversation 的異常路徑後，voice chat 仍可繼續聆聽。

#### 任務 1.4：結束時完整停止管線（A4）
- `_cleanup()` 加入：
  - `await widget.ttsProvider.stop()`（停止網路與系統 TTS）。
  - LLM stream 取消：將 `await for` 改為持有 `StreamSubscription`（成員變數 `_streamSub`），cleanup 時 `await _streamSub?.cancel()`；`await for` 迴圈改用 `listen` + completer 或 `for await` 外包 try/finally 均可，擇一致實作。
- 驗收：朗讀中按停止鍵 → 立即無聲並返回主畫面；thinking 中按停止 → stream 被 cancel，DB 中 assistant 訊息保留已收到的部分內容（`updateMessage(isStreaming: false)` 於 cancel 路徑補呼叫）。

#### 任務 1.5：setState 安全化（C2）
- `_handleSpeechError`、onResult、`_handleSpeechStatus` 內所有 `setState` 前加 `mounted` 檢查（與既有 `_isCleaningUp` 檢查並存）。
- 驗收：`flutter analyze` 通過；快速進出 voice chat 畫面不再出現 setState after dispose。

#### 任務 1.6：桌面版移除 `pauseFor`，依賴原生語音結束偵測（語音對話 + 輸入列聽寫）

**設計背景與機制（重要）**

`speech_to_text` 7.3.0 的 `pauseFor` 是 **Dart 層計時器**（`_setupListenAndPause` → `_stopOnPauseOrListen`），跨平台生效：自最後一次收到**新的辨識結果**起靜默超過 `pauseFor` 即呼叫 `_stop()`，性質是「無新結果看門狗」而非平台專屬機制——它在 Windows 上目前確實有作用。

**實測結論（2026-08-06）：Windows 原生引擎在語音結束後會自行判斷語意結束、停止聆聽並送出 `finalResult`**（對應 `speech_to_text_windows_plugin.cpp` 的 `ResultGenerated` 事件），因此桌面端不需要這 7 秒看門狗；移除後語音結束更快、更自然（無需等滿 7 秒），由原生能力接管。Android 維持 7 秒不變（任務 1.1 的通道 B 仍需要它作為確定性結束機制）。

**修改範圍（兩處）**

| 檔案 | 位置 | 平台判斷 |
|------|------|----------|
| `lib/features/voice_chat/pages/voice_chat_screen.dart` | `_doStartListening()` 的 `_speechToText.listen(...)`（`pauseFor` 於 line 453） | `dart:io` 已 import，直接使用 `Platform` |
| `lib/features/home/controllers/home_page_controller.dart` | `startDictation()` 的 `_speechToText!.listen(...)`（`pauseFor` 於 line 213） | 未 import `dart:io`，沿用既有 `PlatformUtils.isDesktopTarget` |

**具體變更**

`voice_chat_screen.dart`：
```dart
// 桌面版不設定 pauseFor，完全交由系統判斷語音結束；手機版維持 7 秒虛擬計時器
pauseFor: (Platform.isWindows || Platform.isMacOS || Platform.isLinux)
    ? null
    : const Duration(seconds: 7),
```

`home_page_controller.dart`：
```dart
// 桌面版不設定 pauseFor，完全交由系統判斷語音結束；手機版維持 7 秒虛擬計時器
pauseFor: PlatformUtils.isDesktopTarget
    ? null
    : const Duration(seconds: 7),
```

**保留與注意事項**
- `listenFor: 60s` 保留：作為桌面端安全上限，防止邊緣情況下麥克風被永久佔用。
- `lib/features/chat/voice_chat_provider.dart` 的 `listen()`（line 37）本就未傳 `pauseFor`，行為已符合目標；該檔案屬任務 3.1 死碼刪除範圍，不需另行修改。
- 邊界：若實測發現某桌面引擎結束延遲過長，可改為較短的 `pauseFor`（如 3-5 秒）折衷；iOS 具原生結束偵測（`SFSpeechRecognizer`），可評估同樣移除，本次維持現狀列為未來方向。

**驗收**
- Windows：語音對話與輸入列聽寫皆能在講完話後自然、迅速地結束並送出結果，無 7 秒倒數等待。
- Android：語音對話與聽寫仍維持 7 秒強制中斷，行為與先前一致。

### Phase 2 — Robustness 與 UX polish

#### 任務 2.1：Pause 語義完整化（B6 部分）
- `_togglePause` 進入 paused 時：取消進行中的 stream（沿用 1.4 的 `_streamSub`）並 `ttsProvider.stop()`；恢复時依 `_currentState` 回到 listening。
- 文件註記：barge-in（朗讀中說話打斷）因 STT 會收到 TTS 音訊造成回授，列為 Out of Scope（見第五節）。
- 驗收：talking 時按暫停 → 朗讀立即停止、狀態顯示 Paused；再按播放 → 回到聆聽。

#### 任務 2.2：Pause 文字本地化（C1）
- 新增 l10n key `voiceChatPaused`：
  - `app_en.arb`: "Paused"
  - `app_zh_Hant.arb`: "已暫停"
  - `app_zh_Hans.arb`: "已暂停"
  - `app_zh.arb` 若存在對應 fallback 結構一併補上。
- 執行 `flutter gen-l10n`，`_getStateText` 改用 `l10n.voiceChatPaused`。
- 驗收：三種語言下暫停狀態文字正確。

#### 任務 2.3：權限永久拒絕引導（C5）
- `_requestMicrophonePermission` 與 overlay：
  - `status.isPermanentlyDenied` 時，按鈕改為/增加「開啟系統設定」（`openAppSettings()`），並更新 subtitle 文案（新增 l10n key `voiceChatPermissionOpenSettings`）。
- 驗收：Android/iOS 永久拒絕後出現引導按鈕，可跳轉設定。

#### 任務 2.4：Logging 清理（C3）
- 全檔 `print()` 移除或收斂：
  - 專案目前無 logger 工具 → 建立最小 `lib/core/utils/app_logger.dart`（`AppLog.d/i/e`，內部 `if (kDebugMode) debugPrint(...)`），替換所有 `[OmniChat Dart]` print。
  - STT `initialize` 的 `debugLogging: true` 改為 `kDebugMode`。
- 驗收：release build console 無 voice chat 雜訊輸出；debug 下仍可追蹤。

#### 任務 2.5：死碼清除（C4）
- 移除 `_voiceStopTimer` 宣告與 cleanup 中對應的 cancel。
- 驗收：`flutter analyze` 無 unused 警告。

#### 任務 2.6：TTS 卡死 watchdog（C8）
- voice chat 端包一層超時：`await widget.ttsProvider.speak(fullContent).timeout(Duration(seconds: 120), onTimeout: ...)`（或於 TtsProvider 內對 `_speakingCompleter` 加 watchdog，擇一，建議 voice chat 端以不影響其他呼叫方）。
- timeout 時：`ttsProvider.stop()` 並回到 listening。
- 驗收：模擬 completion handler 不觸發（可暫時註解 native callback）時不再永久卡死。

#### 任務 2.7：返回鍵行為一致（C7）
- 頂部 `IconButton` 的 `onPressed` 改為 `_endVoiceChat`。
- 驗收：兩條離開路徑都執行完整 cleanup。

#### 任務 2.8：Locale 解析 cache（B7）
- 抽出 locale 解析為 `Future<String?> _resolveSttLocale()`，結果 cache 於成員變數；僅當 `settings.appLocale` / `isFollowingSystemLocale` 變更時重新解析（可在 build 比對或於每次聆聽前以 key 比對，簡單實作即可）。
- 驗收：連續多輪對話只查一次 `locales()`（debug log 可確認）。

### Phase 3 — 結構重構（獨立 commits）

#### 任務 3.1：刪除死碼 `VoiceChatProvider`（B1、B2）
- 刪除 `lib/features/chat/voice_chat_provider.dart`。
- `main.dart:141` 移除 provider 註冊與 import。
- `home_page.dart` 移除 `_voiceChatProvider` 欄位、listener 註冊/移除（line 130-131、164）、`_onVoiceChatStateChanged`（line 231-239）、import 與 `hide VoiceChatState`。
- `VoiceChatState` enum 唯一來源留在 voice chat feature 內（建議移至新 controller 檔，見 3.3）。
- 驗收：`flutter analyze` 通過；app 啟動不再初始化閒置 STT 引擎；voice chat 功能不受影響。

#### 任務 3.2：抽出共用 LLM 送訊服務（B3、B4、B5、B8）
- 新增 `lib/core/services/chat/chat_turn_service.dart`（名稱可議），職責：
  1. 依 conversation 組 context：truncateIndex 裁切、`collapseVersions`（version selections）、過濾空內容。
  2. System prompt placeholder 注入（`PromptTransformer`）。
  3. Search tool system prompt 與 tool defs 注入；`hasBuiltInSearch` 判斷改為查 `ModelRegistry.infer` 的 abilities（或至少集中為單一 helper，並補 TODO 說明限制）。
  4. 呼叫 `ChatApiService.sendMessageStream`，回傳統一包裝（stream + cancel handle + onChunk 回調）。
  5. 內建 streaming 持久化 throttle：chunk 期間以計時器（如 300ms）batch `chatService.updateMessage`，結束時 flush 一次最終內容 + `isStreaming: false`。
- `voice_chat_screen`（或新 controller）改為呼叫此服務；`chat_actions.dart` 的對應段落於同 PR 或下一 PR 切換（若一次改動風險過大，先讓 voice chat 使用、home page 維持現狀並列追蹤項）。
- 驗收：voice chat 與 home page（若已切換）送訊結果與先前一致（含 search tool、system prompt、版本選擇）；長回應 DB 寫入次數顯著下降（log 可驗證）。

#### 任務 3.3：拆分 god class（C6）
將 `voice_chat_screen.dart` 拆為：
- `lib/features/voice_chat/controllers/voice_chat_controller.dart`：狀態機（`VoiceChatState` enum 移至此）、listening/thinking/talking 轉換、pause 語義、cleanup 編排。以 `ChangeNotifier` 實作，由 screen 透過 `ChangeNotifierProvider`（route 層級）持有，確保 dispose 時一定執行 cleanup。
- `lib/features/voice_chat/services/stt_locale_resolver.dart`：locale 解析（含 cache）。
- `lib/features/voice_chat/services/platform_audio_setup.dart`：audio session / background service / call mode channel 的 init & teardown（Platform 判斷集中）。
- `voice_chat_screen.dart` 僅留 UI（build、overlay、控制列）。
- 驗收：`voice_chat_screen.dart` < 400 行；`flutter analyze` 通過；行為與重構前一致（依 Phase 4 清單回歸）。

### Phase 4 — 驗證

1. `flutter analyze` 零 error（warning 不收斂至零但至少不增加）。
2. 手動回歸矩陣（每階段完成後跑一次核心路徑；Phase 3 後全跑）：

| 情境 | Android | iOS | Windows |
|------|:-:|:-:|:-:|
| 進入→說話→回覆朗讀→繼續聆聽（3 輪） | ☐ | ☐ | ☐ |
| 靜音 10 秒後仍可辨識 | ☐ | ☐ | ☐ |
| pauseFor：桌面自然結束 / 手機 7 秒強制中斷（語音對話+聽寫） | ☐ | ☐ | ☐ |
| thinking 中按暫停/播放 | ☐ | ☐ | ☐ |
| talking 中按停止鍵（TTS 立即停） | ☐ | ☐ | ☐ |
| 字幕開關生效 | ☐ | ☐ | ☐ |
| 權限拒絕/永久拒絕路徑 | ☐ | ☐ | ☐（Windows 權限路徑不同，記錄行為） |
| 無 API key / 無模型錯誤提示後仍可聆聽 | ☐ | ☐ | ☐ |
| zh-TW / zh-Hans / en 狀態文字（含 Paused） | ☐ | — | ☐ |
| 藍牙耳機 call mode 進出（startCallMode/stopCallMode 對稱） | ☐ | — | — |

3. 既有 `test/` 套件執行通過（若 voice chat 無單測，本次至少不破壞現有測試；單測補強列為後續項，因 STT/TTS 依賴 platform channel，需 mock，成本高）。

---

## 三、檔案變更清單（預估）

| 檔案 | 動作 | 相關任務 |
|------|------|----------|
| `lib/features/voice_chat/pages/voice_chat_screen.dart` | 修改→最終拆分 | 1.x, 2.x, 3.3 |
| `lib/features/chat/voice_chat_provider.dart` | 刪除 | 3.1 |
| `lib/main.dart` | 移除 provider 註冊 | 3.1 |
| `lib/features/home/pages/home_page.dart` | 移除 listener 相關 | 3.1 |
| `lib/core/services/chat/chat_turn_service.dart` | 新增 | 3.2 |
| `lib/features/voice_chat/controllers/voice_chat_controller.dart` | 新增 | 3.3 |
| `lib/features/voice_chat/services/stt_locale_resolver.dart` | 新增 | 2.8, 3.3 |
| `lib/features/voice_chat/services/platform_audio_setup.dart` | 新增 | 3.3 |
| `lib/core/utils/app_logger.dart` | 新增 | 2.4 |
| `lib/l10n/app_en.arb` / `app_zh_Hant.arb` / `app_zh_Hans.arb`（+`app_zh.arb`） | 新增 keys | 2.2, 2.3 |
| `lib/features/home/controllers/chat_actions.dart` | （選配）切換共用服務 | 3.2 |
| `lib/features/home/controllers/home_page_controller.dart` | 修改（`startDictation` 的 `pauseFor` 平台判斷） | 1.6 |

## 四、實作順序與 commit 建議

1. `fix(voice-chat): resume listening after silence timeout`（1.1, 1.3, 1.5）
2. `perf(voice): native end-of-speech on desktop, remove pauseFor`（1.6）
3. `fix(voice-chat): subtitles toggle & full pipeline stop on exit`（1.2, 1.4）
4. `fix(voice-chat): pause semantics, permission UX, logging cleanup`（2.1–2.7）
5. `refactor(voice-chat): remove dead VoiceChatProvider`（3.1）
6. `refactor(chat): extract shared chat turn service`（3.2）
7. `refactor(voice-chat): split screen into controller/services`（3.3）

每筆 commit 後皆需通過 `flutter analyze` 與核心回歸路徑。

## 五、Out of Scope（本次不做，記錄在案）

- **Barge-in（朗讀中說話打斷）**：STT 會拾取 TTS 音訊造成自我觸發，需 AEC/回授抑制，屬語音引擎層級改造。
- **語音訊息附件/多模態輸入**：voice chat 維持純文字輸入。
- **iOS 背景執行**：`flutter_background` 僅支援 Android，iOS 背景時 STT 中斷屬平台限制。
- **Voice chat 單元測試**：STT/TTS 重度依賴 platform channel，需先建立 mock 基礎建設，另開任務。
