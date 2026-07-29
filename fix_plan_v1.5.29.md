# OmniChat v1.5.29 — Windows 閃退統一根因修復計畫

> **狀態**：已批准，待實作
> **版本路徑**：`1.5.28+52` → `1.5.29+53`
> **建立日期**：2026-07-29

---

## 1. 背景與症狀

### 1.1 閃退事件報告

v1.5.28.52（Participant 已套用 v1.5.28 的 `WM_GETOBJECT` 攔截修復）仍記錄到 4 個 Windows 應用程式錯誤事件：

| # | Exception Code | Faulting Module | 推斷角色 |
|---|----------------|-----------------|----------|
| 1 | `0xc0000374`   | `ntdll.dll`           | **堆積損毀源頭** (STATUS_HEAP_CORRUPTION) |
| 2 | `0xc0000005`   | unknown               | **次級崩潰** — 堆積損毀後讀到無效指標 |
| 3 | `0xc0000005`   | unknown               | **次級崩潰** — 同上 |
| 4 | `0xc0000005`   | `flutter_windows.dll` | **獨立路徑** — Flutter 引擎內部存取違規 |

事件 #2/#3 的 faulting module 為 `unknown` 與 fault offset 隨機變動，符合「源頭為堆積損毀 (#1)，後續 native 操作在已損壞的 heap 上讀到無效位址而崩潰」的典型連鎖效應。

### 1.2 用戶測試回報

- 閃退頻率較 v1.5.28 前已明顯降低，但仍偶發
- 閃退時機：**AI 串流輸出回應中**（非完成後）
- 用戶**未使用**輔助工具 (NVDA / 朗讀程式 / 放大鏡)
- 回應中**很少或未察覺**含 Mermaid 圖表

### 1.3 歷史修復脈絡

| 版本 | 修復內容 | 內在模式 |
|------|---------|---------|
| v1.5.18 | fetch ReDoS + DOM OOM → `compute()` 隔離 | 將重工作移出串流 上下文 |
| v1.5.23 | `SelectionArea` 串流中繞過 (Reasoning/Translation) | 串流中繞過原生資源 widget |
| v1.5.26 | `SelectionArea` ListView 完整繞過 + WinRT thread guard + QuickJS isolate | 串流中繞過 / 隔離原生資源 |
| v1.5.27 | HTML Preview Console `SelectionArea` 繞過 | 同上 |
| v1.5.28 | 頂層視窗 `WM_GETOBJECT` 攔截 → 關閉 semantics pipeline | 關閉會被串流重建風暴放大的原生 pipeline |
| **v1.5.29 (本計畫)** | **Mermaid WebView2 串流延後渲染** + 子視窗 `WM_GETOBJECT` 補漏 + WebView2 race guard + WinRT thread safety | **把 v1.5.23 的「串流繞過原生資源」政策延伸到 WebView2，補上 v1.5.23 遺漏的一整類 native widget** |

---

## 2. 根因分析（統一根因）

### 2.1 共通模式

歷次修復表面上各自獨立，但對應同一個工程層根因：

> **串流期間每個 token chunk 都觸發 `MarkdownWithCodeHighlight` 完整重建，其中任何非同步原生資源（WebView2 / Semantics / SkParagraph）的 init/dispose race 會被「重建風暴」放大到統計上必然觸發 heap corruption。**

v1.5.23/26/27 已對 `SelectionArea` 套用「串流中繞過/簡化」策略，但 **WebView2 從未套用同一策略** — 這是 v1.5.23 修復時遺漏的一整類原生資源 widget。

### 2.2 雙層根因

**根因 #1（工程層）— 重建風暴中的原生資源生命週期 race**

`MarkdownWithCodeHighlight` 在每個 chunk 完整重建。若回應含 ` ```mermaid ` 圍欄：
1. `_MermaidBlock` 建立 → `winweb.WebviewController().initialize()` 是**非同步 COM**，工作在 native thread
2. 下一個 chunk 改變了 markdown 結構（例如程式碼未閉合或滾出視窗）→ Flutter dispose 當前 state
3. `dispose()` 同步呼叫 `_controller.dispose()`，但 `_controller.initialize()` 可能仍在進行
4. **`initialize()` 與 `dispose()` 同時競爭同一個 COM heap** → `0xc0000374` (ntdll heap corruption)
5. 後續 native 操作讀到已損毀的 heap → `0xc0000005` (Access Violation) 次級崩潰

這條路徑解釋事件 #1/#2/#3。

**根因 #2（子系統層）— Flutter engine semantics race**

v1.5.28 在**頂層視窗**攔截 `WM_GETOBJECT` 並 return 0，但 Flutter 引擎實際渲染在**子視窗** (`FlutterViewController::view()->GetNativeWindow()`)，子視窗有自己獨立的 `WndProc`。即便沒有 AT 工具，Windows 本身也會在工作列預覽、Alt+Tab 縮圖、DWM 合成等情況對**底層可見視窗**發送 `WM_GETOBJECT`：
- 子視窗收到 `WM_GETOBJECT` → Flutter engine `OnGetObject` → `OnUpdateSemanticsEnabled(true)` **永久啟用** semantics pipeline
- 串流中每個 chunk 觸發 SemanticsNode 重建風暴 → engine race → `0xc0000005` (flutter_windows.dll)

這條路徑解釋事件 #4。

### 2.3 為何 v1.5.28 後閃退降低但未消失

v1.5.28 關閉了「事件 #4」的**主要**觸發（語義 pipeline），但：
- 「事件 #1 (Mermaid WebView2 heap corruption)」**從未被處理過**
- 子視窗漏網的 `WM_GETOBJECT` 仍可觸發「事件 #4」的次要路徑

兩條獨立路徑殘留 = 偶發閃退的來源。

---

## 3. 修復策略

**Tier 1 — 根本修復（對應根因 #1）**
- **Fix A**：Mermaid/PlantUML「串流延後渲染」— 把 v1.5.23 對 `SelectionArea` 套用的「串流中繞過」政策，延伸到 WebView2/原生資源 widget

**Tier 2 — 防禦性硬化（對應根因 #2 + 子系統本身漏洞）**
- **Fix B**：子視窗 `WM_GETOBJECT` 雙層攔截
- **Fix C**：WebView2 race-safe init/dispose 守護
- **Fix D**：WinRT 語音 plugin 執行緒安全

**Tier 3 — 版本與記錄**
- **Fix E**：版本號/安裝脚本/CHANGES_LOG

---

## 4. 詳細實作

### Fix A — Mermaid/PlantUML 串流延後渲染（根因修復）

**檔案**：`lib/shared/widgets/markdown_with_highlight.dart`

**變更**：

1. `MarkdownWithCodeHighlight` 新增可選參數：
   ```dart
   const MarkdownWithCodeHighlight({
     super.key,
     required this.text,
     this.onCitationTap,
     this.baseStyle,
     this.isStreaming = false,  // 新增，預設 false 維持向後相容
   });
   final bool isStreaming;
   ```

2. `codeBuilder` 中分流：
   ```dart
   codeBuilder: (ctx, name, code, closed) {
     final lang = name.trim();
     final langLower = lang.toLowerCase();
     // 串流中：純 Dart 程式碼區塊，不建 WebView2
     if ((langLower == 'mermaid' || langLower == 'plantuml') && isStreaming) {
       return _CollapsibleCodeBlock(language: lang, code: code);
     }
     if (langLower == 'mermaid') return _MermaidBlock(code: code);
     if (langLower == 'plantuml') return PlantUMLBlock(code: code);
     return _CollapsibleCodeBlock(language: lang, code: code);
   }
   ```

3. 呼叫端串流點傳 `isStreaming: true`：
   - `lib/features/chat/widgets/chat_message_widget.dart` 的 assistant 內容 `MarkdownWithCodeHighlight(text: visualContent, ...)` → 加 `isStreaming: widget.message.isStreaming`
   - 翻譯區塊已是 `widget.message.isStreaming == false` 守護的區段，`isStreaming` 可固定傳 `false` 或省略

4. 靜態內容呼叫端（`SelectCopyPage` / `SelectCopySheet` / `SelectCopyDialog` / `HTMLPreviewPage` / `html_preview_dialog.dart` 等）全部保留預設 `isStreaming=false`，不需改動。

**效果**：
- 串流中：` ```mermaid ` 顯示為可摺疊程式碼區碼區塊（純 Dart，無原生資源）
- 串流完成 (`isStreaming` true → false 觸發 rebuild)：自動建立 `_MermaidBlock` → WebView2 首次載入 → 圖表渲染
- 從源頭消除 WebView2 init/dispose race 觸發機會

---

### Fix B — 子視窗 WM_GETOBJECT 雙層攔截

**檔案**：`windows/runner/flutter_window.cpp`、`windows/runner/flutter_window.h`

**變更**：

1. `flutter_window.cpp` 新增 `#include <commctrl.h>`（取得 `SetWindowSubclass` / `RemoveWindowSubclass` / `DefSubclassProc`）

2. `FlutterWindow` 類別新增 (header)：
   ```cpp
   private:
     HWND child_hwnd_ = nullptr;
     static LRESULT CALLBACK ChildWndSubclassProc(
         HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam,
         UINT_PTR id_subclass, DWORD_PTR ref_data) noexcept;
   ```

3. `flutter_window.cpp` `OnCreate()` 中 `SetChildContent(...)` 之後：
   ```cpp
   SetChildContent(flutter_controller_->view()->GetNativeWindow());
   child_hwnd_ = flutter_controller_->view()->GetNativeWindow();
   SetWindowSubclass(child_hwnd_, ChildWndSubclassProc, /*id=*/1, /*ref=*/0);
   ```

4. 新增 subclass proc 實作：
   ```cpp
   LRESULT CALLBACK FlutterWindow::ChildWndSubclassProc(
       HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam,
       UINT_PTR id_subclass, DWORD_PTR ref_data) noexcept {
     if (msg == WM_GETOBJECT) {
       return 0;  // 阻斷子視窗漏網，與父視窗形成雙層防護
     }
     return DefSubclassProc(hwnd, msg, wparam, lparam);
   }
   ```

5. `OnDestroy()` 補上反註冊：
   ```cpp
   void FlutterWindow::OnDestroy() {
     if (child_hwnd_) {
       RemoveWindowSubclass(child_hwnd_, ChildWndSubclassProc, 1);
       child_hwnd_ = nullptr;
     }
     if (flutter_controller_) {
       flutter_controller_ = nullptr;
     }
     Win32Window::OnDestroy();
   }
   ```

**連結需求**：`comctl32.lib` — Windows common controls 預設於 Flutter Windows 專案 CMake 已連結，無需手動增修 `windows/runner/CMakeLists.txt`。實作後驗證編譯。

**效果**：父 + 子雙層 `WM_GETOBJECT` return 0，確保**零**訊息達到 Flutter engine 的 `OnGetObject` 路徑 → 關閉「事件 #4」「子視窗漏網」分支。

---

### Fix C — WebView2 Race-safe Init/Dispose 守護

**檔案 A**：`lib/shared/widgets/mermaid_bridge_stub.dart` (`_MermaidInlineWindowsViewState`)

**變更**：

1. 新增狀態欄位：
   ```dart
   bool _disposed = false;
   bool _initialized = false;
   ```

2. `_init()` 在每個 `await` 之後檢查 `_disposed`，並在 `initialize()` 完成後設 `_initialized = true`：
   ```dart
   Future<void> _init() async {
     try {
       await _controller.initialize();
       if (_disposed) return;
       _initialized = true;
       try { await _controller.setBackgroundColor(const Color(0x00000000)); } catch (_) {}
       if (_disposed) return;
       _msgSub = _controller.webMessage.listen((event) { /* ... */ });
       if (_disposed) {
         _msgSub?.cancel();
         _msgSub = null;
         return;
       }
       await _loadHtml();
     } catch (_) {}
   }
   ```

3. `dispose()` 改為防競爭版：
   ```dart
   @override
   void dispose() {
     _disposed = true;  // 立即標記，避免 _init 後續 await 之後仍執行 native 操作
     try { _heightDebounce?.cancel(); } catch (_) {}
     _heightDebounce = null;
     try { _msgSub?.cancel(); } catch (_) {}
     _msgSub = null;
     // 只有完整初始化完成時才同步 dispose；否則交給 Dart GC，
     // 避免與進行中的 initialize() 同時競爭 COM heap → 0xc0000374
     if (_initialized) {
       try { _controller.dispose(); } catch (_) {}
     }
     try {
       if (_tempFilePath != null) File(_tempFilePath!).deleteSync();
     } catch (_) {}
     super.dispose();
   }
   ```

**檔案 B**：`lib/desktop/html_preview_dialog.dart` (`_HtmlPreviewDialogState`)

套用同樣 `_disposed` / `_initialized` 雙守護模式。`dispose()` 只在 `_initialized` 為真時才主動 `_winCtrl?.dispose()`。

**效果**：
- 有 Fix A 後，串流中不會建立 `_MermaidInlineWindowsView`，race 觸發機率已大幅降低
- Fix C 提供雙保險 — 即使在用戶手動切換視窗、開 HTML Preview Dialog 等場景，`initialize()` 與 `dispose()` 不會競爭 COM heap

---

### Fix D — WinRT 語音 plugin 執行緒安全

**檔案**：
- `dependencies/speech_to_text_windows/windows/speech_to_text_windows_plugin.h`
- `dependencies/speech_to_text_windows/windows/speech_to_text_windows_plugin.cpp`

**變更**：

1. `speech_to_text_windows_plugin.h`：
   - `HWND m_messageWindow = nullptr;` → `std::atomic<HWND> m_messageWindow{ nullptr };`
   - 新增 `std::atomic<bool> m_isDestroyed{ false };`
   - 註：`std::atomic<HWND>` 對 64-bit Windows 為 lock-free（HWND 是 `void*` 8 bytes 自然對齊）

2. `speech_to_text_windows_plugin.cpp` 解構函式反序（順序是關鍵）：
   ```cpp
   SpeechToTextWindowsPlugin::~SpeechToTextWindowsPlugin() {
     // 步驟 1：立即標記 destroyed，RunOnMainThread 進入前應看到
     m_isDestroyed.store(true, std::memory_order_release);

     // 步驟 2：鎖 mutex，撤銷所有 WinRT 事件 token，關閉 recognizer
     {
       std::lock_guard<std::mutex> lock(m_mutex);
       if (m_recognizer) {
         try {
           if (m_hypothesisToken) {
             m_recognizer.HypothesisGenerated(m_hypothesisToken);
             m_hypothesisToken = {};
           }
           if (m_resultToken) {
             m_recognizer.ContinuousRecognitionSession().ResultGenerated(m_resultToken);
             m_resultToken = {};
           }
           if (m_completedToken) {
             m_recognizer.ContinuousRecognitionSession().Completed(m_completedToken);
             m_completedToken = {};
           }
           if (m_isListening) {
             try { m_recognizer.ContinuousRecognitionSession().StopAsync().get(); } catch (...) {}
           }
           m_recognizer.Close();
         } catch (...) {}
       }
     }

     // 步驟 3：最後才銷毀 message window（順序絕對不可在前）
     // 否則 WinRT callback 在 token 撤銷前命中已 destroyed 的 window → UAF
     DestroyMessageWindow();
   }
   ```

3. `RunOnMainThread()` 加 guard：
   ```cpp
   void SpeechToTextWindowsPlugin::RunOnMainThread(std::function<void()> task) {
     if (m_isDestroyed.load(std::memory_order_acquire)) return;
     const HWND hwnd = m_messageWindow.load(std::memory_order_acquire);
     if (!hwnd || !IsWindow(hwnd)) {
       if (GetCurrentThreadId() == m_mainThreadId) {
         CreateMessageWindow();
       } else {
         return;  // 安全丟棄
       }
     }
     const HWND current = m_messageWindow.load(std::memory_order_acquire);
     if (current && IsWindow(current)) {
       {
         std::lock_guard<std::mutex> lock(m_queueMutex);
         m_taskQueue.push(task);
       }
       PostMessage(current, WM_RUN_ON_MAIN_THREAD, 0, 0);
     }
   }
   ```

4. `MessageWindowProc` 內處理 `WM_RUN_ON_MAIN_THREAD` 時也檢查 `m_isDestroyed`。

5. `CreateMessageWindow()` 末尾：`m_messageWindow.store(hwnd, std::memory_order_release);`

6. `DestroyMessageWindow()` 開頭：`m_messageWindow.store(nullptr, std::memory_order_release);` 然後 `DestroyWindow(...)`。

**效果**：消除 destructor 中「先 DestroyWindow 才撤銷 event token」的 UAF 視窗；跨 thread 讀寫 `m_messageWindow` 不再有 data race。屬於長期隱患修復，與串流無直接關聯。

---

### Fix E — 版本與記本與記錄

**檔案**：
- `pubspec.yaml`：`1.5.28+52` → `1.5.29+53`
- `installers/omnichat_setup.iss`：`MyAppVersion` 1.5.28 → 1.5.29，安裝包輸出檔名相應調整
- `CHANGES_LOG.md`：新增 v1.5.29 段落，記錄：
  - 統一根因分析（連結 v1.5.23/26/27/28 內在邏輯）
  - 5 個修正內容與對應阻斷的 crash 路徑
  - 維持 `SelectionArea` 可用性（不影響文字選取）
  - Trade-off：Mermaid 串流中顯示為程式碼區塊，回應完成後自動渲染為圖表
  - 防禦性硬化說明與未來可移除的條件

---

## 5. 不變事項保證清單

下列事項**不會被本計畫變更**：

- `SelectionArea` 任何用法 — 用戶可在已完成訊息上正常選取文字（與 v1.5.28 行為一致）
- `pubspec.yaml` 依賴清單 — 不升級 Flutter 引擎或 webview_windows
- `MarkdownWithCodeHighlight` 對外 API — `isStreaming` 預設 `false`，既有呼叫端維持原行為
- `flutter_window.cpp` 頂層視窗 `WM_GETOBJECT` 攔截 — 保留，新增子視窗為雙保險
- WinRT 插件對外 method channel 接口 — Dart 語音 plugin 不動
- QuickJS isolate (v1.5.26) — 不動
- `SelectCopyPage` / `SelectCopySheet` / `SelectCopyDialog` / `HTMLPreviewPage` 等靜態內容呼叫端 — 全部預設 `isStreaming=false`

---

## 6. 驗證流程

1. **編譯驗證**
   - `flutter build windows --release` 編譯成功
   - 零 C++ warnings（含 `flutter_window.cpp` / `speech_to_text_windows_plugin.cpp`）
   - `flutter analyze` 無錯誤

2. **功能驗證**
   - 完成訊息長按選取文字 → 出現 copy/select all 浮動選單 → Ctrl+C 正常（確認 SelectionArea 仍可用）
   - 觸發含 Mermaid 圖表的回應：串流中顯示為 ` ```mermaid ` 程式碼區塊 → 回應完成後自動切換為圖表
   - 開啟 NVDA / 朗讀程式 → OmniChat 視窗被報為 inaccessible（確認 `WM_GETOBJECT` 攔截生效）

3. **壓力測試**
   - 30 分鐘連續串流，含表格 + LaTeX + 多個已完成 ` ```mermaid` 圍欄
   - 觀察 Windows 事件檢視器 → 應用程式日誌 → 確認無 Event ID 1000 的 `OmniChat.exe` 故障紀錄
   - 故障模組為 `flutter_windows.dll` 或 `ntdll.dll` 的事件為 0

4. **殘留問題處理（若有）**
   - 啟用 Application Verifier PageHeap：`gflags /p /enable OmniChat.exe /full`
   - 重現後取得 dump → WinDbg + `!analyze -v` 直接定位 heap corruption 源頭
   - 把 dump 與 call stack 回饋以進行下一輪修復

---

## 7. 實作順序

1. **Fix A** (根因) — `markdown_with_highlight.dart` + `chat_message_widget.dart` 呼叫端
2. **Fix B** (子視窗) — `flutter_window.cpp` / `.h`
3. **Fix C** (WebView guard) — `mermaid_bridge_stub.dart` + `html_preview_dialog.dart`
4. **Fix D** (WinRT) — `speech_to_text_windows_plugin.h` / `.cpp`
5. **Fix E** (版本/記錄) — `pubspec.yaml` + `omnichat_setup.iss` + `CHANGES_LOG.md`
6. **驗證** — `flutter build windows --release` + `flutter analyze`

每個 Tier 完成後檢視，確認無 regression 後再進入下一 Tier。

---

## 8. 修復對應矩陣

| Crash 事件 | 對應路徑 | 阻斷者 |
|-----------|---------|--------|
| #1 `0xc0000374` ntdll | WebView2 init/dispose race | **Fix A** (消除觸發點) + **Fix C** (race guard) |
| #2 `0xc0000005` unknown | #1 次級崩潰 | **Fix A + Fix C** (源頭消除後次級崩潰消失) |
| #3 `0xc0000005` unknown | #1 次級崩潰 | 同上 |
| #4 `0xc0000005` flutter_windows.dll | 子視窗 `WM_GETOBJECT` 啟用 semantics | **Fix B** (雙層攔截) |

| 長期隱患 | 對應路徑 | 阻斷者 |
|---------|---------|--------|
| WinRT destructor UAF | destructor 反序 + cross-thread race | **Fix D** |

---

## 9. 診斷準備（不改碼，建議用戶配置）

供下次部署前可一併設定，以便驗證修復成效或萬一仍有殘留問題時直接定位源頭：

- **啟用 Application Verifier PageHeap**（需 Debugging Tools for Windows）：
  ```
  gflags /p /enable OmniChat.exe /full
  ```
  下次崩潰會產生明確的 `0xC0000374` heap 位置 call stack。

- **核心記憶體傾印**：「系統內容 → 進階 → 啟動與修復 → 撰寫偵錯資訊」設為「核心記憶體傾印」。

- 攔截到的 dump 可用 WinDbg + `!analyze -v` 直接定位 heap corruption 的 native caller。