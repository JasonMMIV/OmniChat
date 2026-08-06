# OmniChat 桌面版語音對話 & 聽寫 `pauseFor` 機制移除計畫

## 🎯 目標
針對桌面版（Windows、macOS、Linux），在兩處 `SpeechToText.listen` 呼叫中移除 `pauseFor: 7s` 參數，將其設為 `null`，使其交由系統底層語音引擎來決定語音結束的時機。

涵蓋兩項功能：
1. **語音對話模式**（`VoiceChatScreen`）
2. **輸入列語音聽寫**（`HomePageController.startDictation`）

## 💡 背景與動機
目前 OmniChat 中有兩處對 `_speechToText.listen` 傳入了 `pauseFor: const Duration(seconds: 7)` 的參數：
- `lib/features/voice_chat/pages/voice_chat_screen.dart`（語音對話模式）
- `lib/features/home/controllers/home_page_controller.dart`（輸入列語音聽寫）

這項設定在不同平台上有效益差異：
1. **Android 手機版**：原生語音引擎若在 7 秒內沒有收到聲音就會中斷收音。因此，Android 確實需要這套「虛擬靜音計時器」，強制結束現有收音階段、送出辨識結果給 LLM，並重新啟動聆聽來維持對話循環。
2. **Windows 桌面版**：Windows 系統底層的語音辨識引擎**在接收完聲音後，會自動判斷語意結束並停止聆聽**。因此，完全不需要前端額外掛載 7 秒的虛擬靜音計時器來強制中斷。

移除此參數可以讓桌面版減少不必要的等待，並讓語音辨識更加順暢地依靠系統原生能力結束。

## 🛠 實作範圍與修改細節

### 檔案一：語音對話模式

**修改檔案：** 
`lib/features/voice_chat/pages/voice_chat_screen.dart`

**修改位置：** 
找到 `_doStartListening()` 方法中呼叫 `_speechToText.listen(...)` 的區塊（約在檔案的 440-460 行附近）。

**具體變更：**
將 `pauseFor` 參數改為動態判斷，當平台為桌面版時傳入 `null`，否則維持 7 秒。

```dart
// 修改前
      await _speechToText.listen(
        onResult: (result) {
          // ... 略
        },
        listenMode: ListenMode.dictation,
        localeId: selectedLocaleId,
        cancelOnError: true,
        partialResults: true,
        pauseFor: const Duration(seconds: 7),
        listenFor: const Duration(seconds: 60),
      );
```

```dart
// 修改後
      await _speechToText.listen(
        onResult: (result) {
          // ... 略
        },
        listenMode: ListenMode.dictation,
        localeId: selectedLocaleId,
        cancelOnError: true,
        partialResults: true,
        // 桌面版不設定 pauseFor，完全交由系統判斷語音結束；手機版維持 7 秒虛擬計時器
        pauseFor: (Platform.isWindows || Platform.isMacOS || Platform.isLinux)
            ? null
            : const Duration(seconds: 7),
        listenFor: const Duration(seconds: 60),
      );
```

> **注意：** 由於 `voice_chat_screen.dart` 頂部已經有 `import 'dart:io';`，因此可直接使用 `Platform` 物件進行環境判斷。

---

### 檔案二：輸入列語音聽寫

**修改檔案：**
`lib/features/home/controllers/home_page_controller.dart`

**修改位置：**
找到 `startDictation()` 方法中呼叫 `_speechToText!.listen(...)` 的區塊（約在檔案的 200-220 行附近）。

**具體變更：**
將 `pauseFor` 參數改為動態判斷，當平台為桌面版時傳入 `null`，否則維持 7 秒。

```dart
// 修改前
      _speechToText!.listen(
        onResult: (val) {
          // ... 略
        },
        cancelOnError: true,
        pauseFor: const Duration(seconds: 7),
        listenFor: const Duration(seconds: 60),
      );
```

```dart
// 修改後
      _speechToText!.listen(
        onResult: (val) {
          // ... 略
        },
        cancelOnError: true,
        // 桌面版不設定 pauseFor，完全交由系統判斷語音結束；手機版維持 7 秒虛擬計時器
        pauseFor: PlatformUtils.isDesktopTarget
            ? null
            : const Duration(seconds: 7),
        listenFor: const Duration(seconds: 60),
      );
```

> **注意：** `home_page_controller.dart` **未直接 import `dart:io`**，因此不能使用 `Platform` 物件。該檔案已 import `../../../utils/platform_utils.dart`（第 17 行），且檔案內已有多處使用 `PlatformUtils.isDesktopTarget`（例如 `isDesktopPlatform` getter），故沿用此寫法最一致。
>
> `PlatformUtils.isDesktopTarget` 內部透過 Flutter framework 的 `defaultTargetPlatform` 判斷目標平台（macOS / Windows / Linux），在實際執行於桌面系統時與 `Platform.isXXX` 結果一致，兩者皆可；選擇 `isDesktopTarget` 是為了與檔案內既有慣例一致。

## ⚠️ 補充考量

### 1. iOS 平台（本次不處理，列為未來方向）
目前的平台判斷式僅涵蓋桌面三平台。iOS 使用 `SFSpeechRecognizer`，同樣具備原生的語音結束偵測能力，設定 `pauseFor: null` 在 iOS 上可能也有益。但由於本次計畫範圍為「桌面版」，iOS 維持現狀（7 秒），可作為未來優化方向。

### 2. `listenFor: 60s` 予以保留（作為安全上限）
本次**不修改** `listenFor`。在桌面平台上，60 秒的 `listenFor` 作為安全上限（safety net）仍有其價值——防止邊緣情況下語音引擎永不結束導致麥克風一直被佔用。

### 3. 邊緣情況：桌面語音引擎的結束延遲
某些 Windows 語音引擎在使用者停止說話後，可能不會**立即**觸發 `finalResult`，使用者可能感受到一段「等待引擎判斷結束」的延遲（通常遠短於 7 秒，但需實測確認）。這與原先的 7 秒強制中斷體驗不同。若實測發現延遲過長，可考慮為桌面端設定一個較短的 `pauseFor`（如 3-5 秒）作為折衷方案。

### 4. 語意結束行為的改變
`pauseFor: null` 時，`finalResult` 的觸發時機改由原生引擎判斷語意結束來決定，而非由 7 秒計時器強制觸發。兩處程式碼的 `onResult` 回呼皆已正確處理 `finalResult`，因此不受影響；但桌面版使用者講完話後，對話循環的節奏會比過去更快。

## ✅ 驗證計畫 (Verification Plan)

實作完成後，請協助執行以下測試以確保修改符合預期：

### 桌面版 (Windows) 回歸測試

1. **語音對話模式**：
   - 進入語音對話模式，對麥克風說一段完整的話。
   - 講完後停止說話，確認系統是否能依賴原生引擎**自然且迅速地結束聆聽狀態**，並順利觸發「思考中（Thinking）」狀態，將訊息送出給 LLM。
   - 確認這個過程沒有受限於強制的 7 秒倒數。
2. **輸入列語音聽寫**：
   - 點擊輸入列的語音聽寫按鈕，說一段完整的話。
   - 講完後停止說話，確認聽寫能**自然且迅速地結束**，並將辨識文字填入輸入框。
   - 確認文字填入後無多餘的 7 秒等待。

### 手機版 (Android) 回歸測試

1. **語音對話模式**：
   - 進入語音對話模式，講完話後保持靜音。
   - 確認 7 秒後系統仍會如以往般正確觸發強制中斷，並將訊息送出。
2. **輸入列語音聽寫**：
   - 啟動語音聽寫，講完話後保持靜音。
   - 確認 7 秒後系統仍會如以往般正確結束聽寫，並將文字填入輸入框。

---
*文件生成時間：2026-08-06*
