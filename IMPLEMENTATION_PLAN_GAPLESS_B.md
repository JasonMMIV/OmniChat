# OmniChat gapless 連續播放 B 方案實作計畫（獨立文件）

> **狀態：✅ W0 完成（Gate 達成）**（2026-08-10 實作並實機驗證；2026-08-09 決策，v1.15.0 後排程）。
>
> **執行順序：先試低成本 workaround（W0 計時預啟動，§3.1）；W0 不足再進行完整實作（B2，M1–M5）。**
>
> **W0 實作紀錄（2026-08-10）**：`lib/core/services/live/live_api_session.dart` 已實作計時預啟動——
> `_schedulePreStart`（目前槽 resume 後依 WAV duration 排定預備槽 resume 於「預期完成時間 − `w0HandoffLead`」）、
> `_firePreStart`（提前切換，目前槽保留為 `_prev` 待其 `onPlayerComplete` 僅釋放）、constructor 參數
> `enableTimedPreStart`（預設僅 Android 啟用，Windows 維持現況）與 `w0HandoffLead`（實機微調定案 20 ms：
> 80 ms 實測無間隙但輕微重疊 → 逐次下修 50→40→30→20 ms）；`onPlayerComplete` 保留為保險；`_flushPlayback`/dispose 取消 timer 並釋放 `_prev`。
> 新增整合測試「W0 計時預啟動」；`flutter test` 全數通過、`flutter analyze` 零新增錯誤。
> **實機測試（2026-08-10，speaker 路徑）：20 秒連續語音完全無間隙 ✓；`w0HandoffLead` 逐次下修
> （80→50→40→30→20 ms）後，20 ms 為最順暢（無間隙、無重疊）→ **W0 Gate 達成，不需 B2**。**
> **Gate 判定（§3.1：聽感無間隙 + 交接延遲縮小）接近達成，待 50 ms 復測收尾。**
>
> 本文件是**自足的獨立計畫**：所有必要背景、現況、程式位置、驗收與發布門檻均已內嵌，執行時不需參照其他檔案（例如 `IMPLEMENTATION_PLAN_LIVE_VOICE_V5.md`）。本文件對應該主計畫中的「B 方案（§11）」與「Phase 8：gapless 連續播放」。

---

## 1. 背景與問題

### 1.1 現況

本專案（OmniChat，Flutter）的 Live API 半雙工語音通話中，模型語音以 audio chunk 形式送達（約每 0.5 秒一個 chunk）。目前播放實作對**每個 chunk**：

1. 將 PCM 包裝成一個 WAV 檔（`BytesSource`）。
2. 建立一個新的 `AudioPlayer`（Android 底層為 `MediaPlayer`，以 `PlayerMode.mediaPlayer` 播放）。
3. 播放完成後 dispose。

### 1.2 問題

每個播放包都是一次 MediaPlayer **冷啟動**，包與包之間產生可感知的播放間隙（gap）。雙槽預備播放等止血措施已大幅改善，但**無法從架構上根治**——只要繼續「每包新建 player」，間隙就必然存在。

### 1.3 已實作的止血措施（本計畫的起點，不得回退）

| 代號 | 內容 | 效果 |
|---|---|---|
| 191k | 播放序列化清理：`stop()`/`dispose()`/錯誤/goAway 的清理順序防護 | 無資源洩漏、無 native race |
| 191p | 雙槽預備播放（`_createSlot`/`_primeSlot`/`_startSlot`）：目前槽播放中預先 `setSource` prepare 下一槽，完成時直接 `resume` 切換 | 消除每包 prepare 冷啟動的延遲，間隙明顯變小 |
| 191r C1 | 播放器 `audioFocus: NONE`：audioplayers 不再每包 request/abandon audio focus（focus 由 call mode 集中管理） | 移除每包 focus 交接造成的延遲；保留 call mode 路由 |

C1 的完整策略（本計畫必須延續）：focus 由 call mode 統一管理；`buildPlaybackAudioContext` 必須把目前路由值一併帶入播放器 context，因為 audioplayers 的 `setAudioContext` 在 Android 會**全域覆寫** `AudioManager.mode` 與 `isSpeakerphoneOn`——藍牙路徑傳 `inCommunication`/speakerphone off，喇叭路徑傳 `normal`/speakerphone on。

### 1.4 本計畫的目標

以「**單一連續 PCM 播放管線**」取代「每約 0.5 秒建立一個 WAV + 新 MediaPlayer」，從架構上消滅包間隙。

---

## 2. 目標與驗收

### 2.1 目標

- 播放契約固定為 **PCM16、mono、24 kHz 輸出**（輸入為 16 kHz mono，輸入與輸出不得共用同一個 `sampleRate` 常數；`outputSampleRate = 24000`、`outputChannels = 1`、`bitsPerSample = 16`）。
- 收到 server audio chunk 即 `append` 到單一串流，不再等 0.5 秒包門檻、不再每包新建 player。
- Windows 播放行為**維持現況**（Windows 現況即無可感知間隙），Android 導入新管線。

### 2.2 驗收條件

1. Android speaker 與 Bluetooth headset 兩條路徑，連續 20 秒模型語音皆**無可感知包間隙**。
2. 20 秒播放期間 **underrun 計數 = 0**（sink 診斷計數器）。
3. 首包延遲 ≤ 300 ms（從收到第一個 server audio chunk 到聲音輸出；現況 0.5s 包門檻，不得變慢）。
4. interrupted、stop、error、dispose 後：無未釋放 AudioTrack／player、無殘留音訊、`dumpsys media.audio_flinger` 無 active track 殘留。
5. 路由不退化：speaker 路徑維持 call mode 路由與音量；Bluetooth SCO 輸入輸出正常（C1 的「focus none + 保留 mode/speakerphone」策略必須延續）。
6. `flutter test` 全數通過、`flutter analyze` 零新增錯誤；Windows 播放行為不變（維持現況即 gapless）。

---

## 3. 方案比較與決策

| 方案 | 做法 | 優點 | 缺點 |
|---|---|---|---|
| **B2（推薦）自訂 Kotlin AudioTrack 串流 plugin** | MethodChannel 餵 PCM16，native 端以 `AudioTrack` MODE_STREAM + blocking queue 串流播放 | 零新依賴、完全控制延遲/buffer、與 C1 策略天然對齊（不碰 focus、不覆寫路由）、arm64-only 體積不增 | 需自己處理寫執行緒、underrun、裝置差異；無現成測試基礎（實機驗證為主） |
| **B1（備案）media3 ExoPlayer + 自訂 DataSource** | 自訂 `DataSource` 先吐 WAV header 再持續餵 PCM16，`WavExtractor` 解析，`LoadControl` 壓低 `minBufferMs` | 播放器 battle-tested、format negotiation 免操心、間隙與中斷處理成熟 | 新增 media3 依賴（+~2MB native）、需停用其 audio focus 管理（`handleAudioFocus=false`）、低延遲需調校、Android-only 但引入整套播放器抽象 |
| B3 捨棄 | 直接改用現成播放套件（media_kit/just_audio） | 套件成熟 | 皆不提供「持續餵 PCM 的單一串流」開箱能力，仍需自訂 source；遷移成本等同 B1 但控制力更差 |

**決策（完整實作，W0 不足時啟用）：以 B2（自訂 Kotlin AudioTrack 串流 plugin）為主實作。** 理由：

- 播放契約極簡且固定（PCM16 mono 24 kHz），不需要播放器的格式協商能力。
- C1 已確立「audio focus none + 保留 call mode 路由」策略——AudioTrack 的 `AudioAttributes` 可直接對齊（`USAGE_VOICE_COMMUNICATION`/`CONTENT_TYPE_SPEECH`，不 request focus），不像 ExoPlayer 需先關閉內建 focus 管理。
- 專案現況為 arm64-only APK，重視產物體積與可控性；B2 不增加任何第三方 native 依賴。
- 若 B2 的 underrun 調校在特定裝置上無法達成（風險 §9-R2），**以 B1 為備案**，介面設計（§6）須讓兩種實作可互換。

### 3.1 執行順序：低成本 workaround（W0）先行，不足再完整實作（M1–M5）

**策略**：殘餘間隙的本質是「player 交接延遲」而非「資料斷供」（§1.2），平滑緩衝只有在單一連續管線內才有效（§5）。因此在投入 B2 之前，先以最低成本驗證「縮短交接延遲」是否已足以達成驗收。

**W0 內容（計時預啟動，timed pre-start）**：

- 維持現行雙槽架構（session 內的 `_createSlot`/`_primeSlot`/`_startSlot`），**不引入 sink 抽象、不新增 native 程式碼**。
- 目前槽 `resume()` 時，依 WAV duration 排定預備槽的 `resume()` 於「預期完成時間 − 交接延遲估計值」**提前觸發**，不再等 `onPlayerComplete`；`onPlayerComplete` 保留為保險（未提前啟動時才在此刻切換），沿用既有 `_switchTo` 與 epoch 防護。
- 交接延遲估計值取自 §9.4 量測點 B 的實測（先量測取初值，再以實機微調）。
- 可選增強：提前量不足導致仍可感知時，加**極短重疊＋預備槽 volume 淡入**緩衝 click；優先先測純預啟動。
- W0 先以 **Android 為範圍**（可先以平台旗標限定），Windows 維持現況；若 W0 採納為正式方案，再評估納入 `ChunkedPlayerSink` 並以回歸測試保障。

**風險與防護**：

- MediaPlayer 播放時鐘對牆鐘漂移：提前太早 → 兩軌同時發聲（混音/click）；太晚 → 間隙照舊。防護：以量測值為基礎、可選淡入緩衝、speaker 與 BT 實機驗證。
- 不得縮小 WAV 包或增加 player 數目——W0 是縮短交接，不是「多 player 湊合」（§1.2 已排除該方向）。

**Gate（判定 W0 是否足夠）**：

- speaker 路徑實機 20 秒連續語音**無可感知間隙**，且量測點 B 交接延遲明顯縮小（聽感門檻約 <30 ms，以實機為準）→ **W0 完成**，不需 B2，直接進入 §10 發布。
- 未達 → 啟動 **M1–M5 完整實作**（B2 單一連續 PCM 管線）。

---

## 4. 現況基線（相關程式位置）

- **`lib/core/services/live/live_api_session.dart`**
  - `AudioPlayer Function(String playerId)` 注入與 `_createPlayerWithContext`（約 line 61–86）：建立 player 並套用 `playbackAudioContext`（191r C1）。
  - `_playEpoch`（約 line 164）：interrupted/stop/flush/mute 時 `epoch++` 使 in-flight 操作失效。
  - 雙槽播放管線：`_pumpPlayback`/`_createSlot`/`_startSlot`/`_primeSlot`/`_switchTo`（約 line 795–889）：`setSource(BytesSource(wav))` 預先 prepare、完成時 `resume` 切換、失敗時提拔預備槽。
- **`lib/features/voice_chat/services/platform_audio_setup.dart`**
  - `startCallMode()`/`stopCallMode()`：經 `omnichat/call_mode` MethodChannel 管理 call mode 路由（藍牙 SCO、speaker、focus）。
  - `buildPlaybackAudioContext(...)`（約 line 90–119）：C1 方案——`audioFocus: none`，並帶入目前路由（藍牙→`voiceCommunication`/`speech`、喇叭→`media`/`music`）避免覆寫路由。
- **`android/app/src/main/kotlin/com/psyche/omnichat/MainActivity.kt`**
  - `omnichat/call_mode` MethodChannel（約 line 22–126）：`startCallMode`/`stopCallMode` 的 native 實作（`AudioManager.mode`、`isSpeakerphoneOn`、藍牙 SCO）。
  - 新 plugin（B2）在此檔案或平行 Kotlin 檔案中新增 `omnichat/audio_sink` channel。
- **現有測試**
  - `test/live_api_session_integration_test.dart`：fake WebSocket、fake recorder、fake player（含 `xyz.luan/audioplayers` MethodChannel mock）。
  - `test/live_call_screen_test.dart`：LiveCallScreen widget 測試（含 `omnichat/call_mode` mock）。

---

## 5. 架構：播放抽象層

新增播放抽象，session 不再直接依賴 audioplayers：

```text
LiveAudioSink（抽象介面）
├── AndroidAudioTrackSink  ← B2：MethodChannel → Kotlin AudioTrack 串流（Android 使用）
└── ChunkedPlayerSink      ← 現有雙槽預備播放邏輯封裝（Windows 使用，行為不變）
```

介面（對應目前 `_slots`/`_primeSlot`/`_startSlot`/`_playEpoch` 的職責）：

- `Future<void> open(...)`：設定取樣率/聲道/位元深、AudioAttributes（usage/contentType 依目前路由，同 C1）、建立原生資源。
- `Future<void> append(List<int> pcmBytes)`：寫入 PCM。sink 內部以 blocking queue 平滑，Dart 端每 ~50–100 ms 批次送一次（控制 channel 往返開銷）。
- `Future<void> start()` / `pause()`：播放/暫停。
- `Future<void> flush()`：清空內部 queue 與 AudioTrack，**保留 open 狀態**（對應 interrupted 清空、mute 重新開始）。
- `Future<void> stop()` / `dispose()`：停止並釋放；stop 與 dispose 序列化（沿用現有順序防護）。
- 事件：`onStateChange`（started/stopped/underrun）、`onError`。

Session 重構要點：

- 移除 `_createSlot`/`_primeSlot`/`_startSlot` 的雙槽管理，改為：`open` → `append`（收到 server audio 即 append，不再等 0.5 s 門檻）→ `start`。
- `_playEpoch` 保留：interrupted/stop/flush/mute 時 `epoch++` 使 in-flight 操作失效，並呼叫 `sink.flush()`。
- 平台分派：`defaultTargetPlatform == android` 用 `AndroidAudioTrackSink`，否則 `ChunkedPlayerSink`（Windows 維持現況）；保留 runtime fallback flag（Android 上 sink 建立失敗自動退回 `ChunkedPlayerSink`，見 §9-R4）。
- `playbackAudioContext`（191r C1）改由 sink `open()` 接收並在 native 端套用同等策略（不 request focus、保留 mode/speakerphone）。

### 5.1 Windows 影響範圍：不用改什麼、會改什麼

**Windows 不需要改的部分：**

- 不導入任何新播放管線：B2（Kotlin AudioTrack）與 B1（media3 ExoPlayer）皆為 **Android-only**，Windows 不使用，也不新增任何 Windows 原生程式碼。
- 播放**行為與體驗維持現況**（Windows 現況即無可感知間隙），這是 §2.2 驗收 6 與 §9.1 回歸的硬性要求，不是可選項。

**Windows 會受到影響的部分（僅 M1 的共享層重構）：**

- session 播放程式碼是跨平台共用的，M1 把雙槽管理從 session 抽到 `ChunkedPlayerSink`（封裝現有 `_createSlot`/`_primeSlot`/`_startSlot` 邏輯）。Windows 只是改從 sink 介面呼叫**同一套既有邏輯**——程式碼位置與呼叫方式會變，但行為語意、epoch／順序防護與播放結果不變。
- 保障方式：M1 完成條件「Windows/Chunked 行為不變」＋既有整合測試改寫為 sink 語意後全綠＋實機矩陣 Windows 兩列回歸（§9.2）。

**一句話結論：Windows 不用為了解決間隙而改——間隙是 Android 專屬問題；Windows 唯一會碰到的是 M1 的共用程式碼重構，且以「行為不變」為硬性約束。**

---

## 6. Kotlin AudioTrack plugin 規格（B2）

- **Channel**：`omnichat/audio_sink`（與既有 `omnichat/call_mode` 平行，實作於 `android/app/src/main/kotlin/com/psyche/omnichat/`）。
- **方法**：`create`（sampleRate/channels/bitsPerSample/usage/contentType）、`write`（byte[]）、`start`、`pause`、`flush`、`stop`、`dispose`；事件走 event channel：`started`/`stopped`/`underrun`/`error`。
- **播放執行緒**：`AudioTrack.write()` blocking 寫入；內部 `LinkedBlockingQueue` 深度約 **150–300 ms** 音訊（延遲與 underrun 的取捨，見 §9-R1）。
- **AudioAttributes**：`USAGE_VOICE_COMMUNICATION` + `CONTENT_TYPE_SPEECH`（Bluetooth 時對齊現有 C1 的 usage 切換）；**不 requestAudioFocus**（call mode 已持 focus，維持 C1 策略）。
- **不修改** `AudioManager.mode`/`isSpeakerphoneOn`（由既有 `startCallMode()` 負責，plugin 不得覆寫）。
- **underrun 診斷**：記錄 `write()` 回傳 < 請求長度的次數與 buffer 水位，透過 event channel 回報 Dart 供實機矩陣驗證（驗收 §2.2-2）。
- **執行緒安全**：不得在 `dispose` 前釋放執行緒造成 native race；`stop`/`dispose` 由 Dart 端序列化呼叫。

---

## 7. 里程碑

| 里程碑 | 內容 | 完成條件 |
|---|---|---|
| **W0 低成本 workaround：計時預啟動**（🟡 已實作 2026-08-10） | 在現行雙槽管線上，依目前槽 WAV duration 提前排定預備槽 `resume`（不需 sink 抽象）；以 §9.4 量測點 B 實測交接延遲並微調提前量（`w0HandoffLead`，初始 80 ms） | speaker 實機 20 秒無可感知間隙且交接延遲明顯縮小 → 直接完成；未達 → 啟動 M1–M5（**實機驗證待執行**） |
| **M1 抽象層與 session 重構** | 新增 `LiveAudioSink` 介面 + `ChunkedPlayerSink`（封裝現有雙槽邏輯）＋ `FakeSink`；session 改走 sink；整合測試改寫為 sink 語意 | 全部 `flutter test` 綠（Windows/Chunked 行為不變）；`flutter analyze` 零新增錯誤 |
| **M2 Kotlin plugin + Android sink** | `omnichat/audio_sink` channel + `AndroidAudioTrackSink`；先以測試 tone/silence 驗證串流可播、無 underrun | 實機 logcat 顯示 write 正常、underrun=0（空資料流） |
| **M3 接線與實機調校** | ① 先做**間隙基線量測**（現行雙槽管線，speaker 與 BT 各測，方法見 §9.4）；② session 於 Android 使用新 sink；③ speaker/BT 實機驗證；④ 延遲與 buffer 調校；⑤ 切換後重做量測對照 | §2.2 驗收 1–3 達成（speaker 先行、BT 次之）；基線與切換後數據記錄於實機矩陣 |
| **M4 資源與矩陣收尾** | interrupted/stop/dispose 洩漏檢查（`dumpsys`）、20 秒矩陣納入實機矩陣、release build | §2.2 驗收全數達成；`flutter test` 全綠 |
| **M5 備案（僅在 R1/R2 失敗時）** | 改以 media3 ExoPlayer + 自訂 DataSource（WAV header + 持續 PCM）實作同一介面 | §2.2 驗收達成 |

---

## 8. 風險與緩解

- **R1 延遲 vs underrun 取捨**：buffer 太小易 underrun、太大首包延遲上升。緩解：buffer 深度 150–300 ms 可調、underrun 計數器診斷、M3 以實機數據決定預設值。
- **R2 裝置差異**：部分裝置（Samsung/小米等）對 `USAGE_VOICE_COMMUNICATION` 的 AudioTrack 處理不同。緩解：speaker 路徑可備用 `USAGE_MEDIA`（call mode 路由仍由 AudioManager 控制）；仍失敗則啟動 M5（ExoPlayer 備案）。
- **R3 Bluetooth SCO 行為**：SCO 下 AudioTrack 的取樣率/通道限制（SCO 通常 16 kHz mono，輸出契約 24 kHz 需重採樣或讓 AudioTrack 自行轉換）。緩解：BT 路徑實機矩陣專項驗證；必要時輸出端依路由動態調整取樣率（輸出契約屬輸出端，可平台路由化）。**實機觀察（2026-08-09）：speaker 路徑聽得到包間隙、BT 路徑無感——來源端空窗相同，但 BT 的 SCO jitter buffer／耳機端緩衝／語音管線重取樣把空窗平滑掉；這佐證 BT 路徑自帶緩衝與轉換能力，BT 驗收風險低於 speaker，驗收重點收斂到 speaker 路徑（仍須以 §9.4 量測數據確認）。**
- **R4 原生失敗回退**：sink 建立/寫入失敗必須能回退 `ChunkedPlayerSink`（保底可用），並在診斷 log 記錄原因。
- **R5 測試覆蓋缺口**：無 Android 單元測試基礎建設。緩解：Kotlin 端以實機 + logcat 診斷（underrun/水位）為主要驗證手段；Dart 端以 FakeSink 覆蓋 session 編排邏輯。

---

## 9. 測試計畫

### 9.1 Dart 單元/整合（FakeSink）

- append 批次語意、flush 清空、interrupted/stop/dispose 序列化、epoch 失效、mute 重新開始、sink 錯誤 → 回退 `ChunkedPlayerSink`、dispose 後不再通知。
- 改寫現有播放測試（fake player → FakeSink）。
- 回歸：Windows 走 `ChunkedPlayerSink`，既有行為與測試不得改變。

### 9.2 實機矩陣

| 平台 | 音訊路徑 | 必測項目 |
|---|---|---|
| Android | 內建 speaker | 短句、長句、靜音、重試、背景 |
| Android | Bluetooth headset | 路由、短句、長句、拔除耳機 |
| Windows | 內建/USB 麥克風與 speaker | 取樣率、短句、長句、播放完整性 |
| Windows | 耳機 | 半雙工往返、重試、播放完整性 |

每個環境至少執行：

- 10 次短句往返。
- 5 次連續兩句往返。
- 3 次 20 秒以上模型語音播放。
- 3 次錯誤或斷網後重試。
- 3 次背景/前景或視窗失焦恢復。

本計畫擴充（speaker 與 BT 各）：20 秒連續播放（underrun=0）、首包延遲量測、10 次短句往返、interrupted 清空、stop/dispose 後 `dumpsys media.audio_flinger` 無殘留 track。

### 9.3 工具與命令

- 診斷：logcat 觀看 `write()` 正常與 underrun/水位事件。
- 洩漏檢查：`dumpsys media.audio_flinger` 確認無 active track 殘留。
- 建置/檢查：`flutter test`、`flutter analyze`（零新增錯誤）。

### 9.4 間隙量測（診斷程序）

目的：用實機數據確認「包間空窗」的大小，並驗證「BT 路徑因下游緩衝掩蓋空窗、speaker 路徑直接暴露」的理論（見 §8-R3）。

- **量測點 A（來源端空窗）**：`live_api_session.dart` 的 `_startSlot` 已有 `play #N start` log（tag `live-api`）。從 logcat 取出連續兩包的 start 時間戳，間隔即「上一包開始到下一包開始」；扣掉單包音訊長度（約 0.5 s）即為空窗上限。
- **量測點 B（交接延遲）**：在 `onPlayerComplete`（目前槽完成）與下一個 player `resume`／開始輸出之間加計時 log，直接量測雙槽切換延遲。
- **執行**：speaker 與 BT 各播 20 秒連續語音，分別記錄；對照同一組來源端空窗數據，確認 BT 掩蓋（來源空窗相同，但 BT 聽感無間隙）。
- **驗證**：新 sink（M3）切換後重做同一量測，空窗應趨近 0（單一連續管線無包邊界）；數值同時用於決定 §8-R1 的 buffer 深度預設值。
- **W0 判定（§3.1）**：計時預啟動上線後重測量測點 B，交接延遲應明顯縮小；speaker 聽感無間隙即為 W0 完成條件，否則啟動 M1–M5。

---

## 10. 發布門檻

- 本計畫（W0 或完整實作）完成前，產品與 UI 必須**明確標示「非 gapless 預覽版」**：發布門檻允許「播放沒有明顯包間隙，**或**產品明確標示仍為非 gapless 預覽版」。
- **W0 達成即移除標示**：若 W0（計時預啟動）通過 §2.2 驗收 1/3/5（聽感＋§9.4 量測數據判定），可移除「非 gapless 預覽版」標示；underrun 計數（驗收 2）僅在 B2 sink 下適用。
- 完整實作（B2）完成後：移除標示，並將 §2.2 驗收全數納入正式發布門檻。
- 既有發布門檻其餘條款不受影響：`flutter test` 全數通過、新增 analyzer error 為零、半雙工限制與非全雙工宣示不變、沒有 credential 進入 repository/log/文件/產物。
