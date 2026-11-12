# P1：使用者圖片路徑讀取失效（`userImagePaths` → `_encodeBase64File`）

> **版本**：v1.0（2026-11-12）  
> **狀態**：分析與方案定稿，尚未實作  
> **優先級**：P1（跨供應商穩定性；工程風險低到中等）  
> **命名說明**：本文件所稱 P1 指本次「使用者圖片路徑讀取失效」問題，不是 Cowork 計畫中的 P1-x 編號。  
> **相關問題**：P0（Gemini system prompt 的 `[image:<absolute-path>]`）  
> **行號基準**：2026-11-12 目前工作區；程式碼位置以函式名為主，行號可能隨重構漂移。

---

## 0. 摘要

P1 是圖片輸入的第二條路徑問題：

```text
使用者圖片路徑清單 userImagePaths
        │
        ▼
_encodeBase64File()
        │
        ▼
File(path).readAsBytes()   ← 沒有 try/catch
```

P0 修的是「訊息文字裡的 `[image:...]` marker」；P1 要處理的是「附件路徑清單」這條側門。兩者都會走到讀檔，但 P0 只防護了前者。

只要 `userImagePaths` 裡有一個：

- 不存在的檔案
- 不可讀的檔案
- 是目錄而非檔案
- 含 Windows 非法字元（例如 `<absolute-path>` 的 `<`、`>`）
- 已被使用者從儲存空間刪除的上傳檔案
- 備份還原時沒有帶到的附件

就會在 HTTP 請求送出前丟出 `PathNotFoundException` / `FileSystemException`，整個回合失敗。

**這是跨供應商的問題**：OpenAI、Responses、Claude、Gemini、OpenAI Images、Agnes 都有同類讀檔點，不是 Gemini 專屬。

**建議修法**：

1. `_encodeBase64File()` 改成安全讀檔，失敗回傳 `null`。
2. 所有呼叫端在 `null` 時降級成普通文字 part，不再讓整輪請求失敗。
3. OCR 入口加 local path 預檢，維持「OCR 失敗回傳 `null`」的既有語意。
4. OpenAI Images / Agnes 的 image edit 不做文字降級，改用清楚的 typed error。
5. 不做全域 `userImagePaths` 預檢；UI 提示列為 Phase 2。

---

## 1. P0 與 P1 的分界

| 項目 | P0 | P1 |
|---|---|---|
| 來源 | system prompt 內的字面 `[image:<absolute-path>]`，或訊息文字中的 marker | `userImagePaths` 附件路徑清單 |
| 解析點 | `_parseTextAndImages()` | `_encodeBase64File()` 直接讀檔 |
| 防護狀態 | 已修：marker 分支有 scheme 分流、`existsSync`、try/catch | 未修：直接 `File.readAsBytes()` |
| 觸發頻率 | 符合工作區條件時，每次 Gemini 請求（system 被當 user 掃描） | 只有路徑缺失/不可讀/非法時 |
| 受影響供應商 | Gemini 系列（其他傳輸跳過 system） | 所有供應商 |
| 與本次原始錯誤的關係 | **原始錯誤的肇因** | **另一個尚未爆發的既有缺口** |

P0 已完成的重點（目前工作區）：

- `file_workspace_prompt.dart` 不再輸出可被 `\[image:...\]` 命中的字面範例。
- `_parseTextAndImages()` 的 custom marker 分支補上 `data:` / `http(s)` / local 分流與存在檢查。
- Gemini 串流與非串流都把 `role0 == 'system'` 當純文字送出，不再進入 marker 掃描。
- 已補 `file_workspace_prompt_test.dart`、`chat_api_service_inline_image_marker_test.dart` 與 Gemini body capture 測試。

P1 不在 P0 的修復範圍內，因為 `userImagePaths` 根本不會經過 `_parseTextAndImages()`。

---

## 2. 問題鏈

### 2.1 首次送出

```text
Composer 選圖
  │
  ├─ input.imagePaths
  │       │
  │       ▼
  │  buildUserImagePaths(input: input)
  │       │
  │       ▼
  │  ctx.userImagePaths
  │       │
  │       ▼
  │  _encodeBase64File() ──► File.readAsBytes()
  │
  └─ 訊息內容加入 [image:<path>]
          │
          ▼
     _parseTextAndImages()（P0 已防護）
```

### 2.2 重新生成 / 續聊 / ask_user resume

```text
歷史 user 訊息 [image:<path>]
        │
        ▼
parseInputFromRaw()
（regex 直接抓取，不檢查檔案）
        │
        ▼
lastUserImagePaths
        │
        ▼
buildUserImagePaths(input: null)
        │
        ▼
ctx.userImagePaths
        │
        ▼
_encodeBase64File() ──► File.readAsBytes() ──► 例外
```

這是 P1 最常見的觸發路徑。因為重新生成時 `input == null`，`buildUserImagePaths()` 會直接使用歷史訊息解析出的 `lastUserImagePaths`，即使該檔案早已不存在。

### 2.3 程式碼證據

| 位置 | 行為 |
|---|---|
| `lib/features/home/services/message_builder_service.dart:455-498` | `parseInputFromRaw()` 用 regex 抓 `[image:...]`，不檢查 scheme、存在性、是否為檔案 |
| `lib/features/home/services/message_builder_service.dart:544-551` | 最後一則 user 訊息的 `parsedUser.imagePaths` 直接存成 `lastUserImagePaths` |
| `lib/features/home/services/message_generation_service.dart:748-770` | `buildUserImagePaths()` 原樣回傳 `input.imagePaths` 或 `lastUserImagePaths` |
| `lib/core/services/api/chat_api_service.dart:1349-1362` | `_encodeBase64File()` 直接 `File(fixed).readAsBytes()`，沒有 try/catch |
| `lib/core/services/api/chat_api_service.dart:3285 / 3303` | Responses：parsed path / `userImagePaths` 直接編碼 |
| `lib/core/services/api/chat_api_service.dart:3508 / 3535` | OpenAI Chat：parsed path / `userImagePaths` 直接編碼 |
| `lib/core/services/api/chat_api_service.dart:4908` | Claude：`userImagePaths` 直接編碼 |
| `lib/core/services/api/chat_api_service.dart:6093 / 6117` | Gemini 串流：parsed path / `userImagePaths` 直接編碼 |
| `lib/core/services/api/chat_api_service.dart:6491 / 6515` | Gemini 非串流：parsed path / `userImagePaths` 直接編碼 |
| `lib/core/services/api/chat_api_service.dart:7397` | Agnes image edit：`_imageRefToAgnesImage()` 間接呼叫 |
| `lib/core/services/api/chat_api_service.dart:7809-7832` | OpenAI Images edit：`MultipartFile.fromPath()` 也是同類裸讀點 |

### 2.4 為什麼 P0 的 `existsSync` 沒蓋到

`_parseTextAndImages()` 只處理「訊息文字內容」。各傳輸在解析完文字後，另外有類似這樣的區塊：

```dart
if (hasAttachedImages) {
  for (final p in userImagePaths!) {
    final dataUrl = ... await _encodeBase64File(p, withPrefix: true);
    addImage(dataUrl);
  }
}
```

`userImagePaths` 是獨立參數，不會進入 `_parseTextAndImages()`，所以 P0 的 marker 防護完全幫不上忙。

還有一個容易誤判的點：

- P0 修好後，訊息文字中的 `[image:<absolute-path>]` 會保留成純文字，不會再炸 transport parser。
- 但 `parseInputFromRaw()` 仍會把同一個字串收進 `lastUserImagePaths`。
- 重新生成時，P1 仍會拿 `<absolute-path>` 去 `File.readAsBytes()`。

也就是說：**P0 讓文字變安全了，但 P1 這條附件清單還是會炸。**

---

## 3. 觸發情境

### 3.1 常見情境

1. **使用者從儲存空間刪除上傳圖片**
   - `StorageUsageService.deleteUploadFiles()` 只刪檔案，不會回頭修改訊息內容。
   - 之後重新生成該訊息就會使用舊路徑。

2. **備份還原沒有包含檔案**
   - 聊天記錄還原了，但 `upload/` 目錄沒有還原。

3. **匯入舊聊天**
   - 訊息內的附件路徑可能指向不存在的檔案。

4. **使用者移動或刪除 `upload/` 目錄**
   - 桌面版特別容易發生。

5. **使用者訊息含字面 `[image:<absolute-path>]`**
   - 可能是貼上、匯入、或早期版本留下的內容。
   - `parseInputFromRaw()` 不會驗證，照樣收進 `lastUserImagePaths`。

6. **影片附件缺失**
   - `buildUserImagePaths()` 也會把 `input.documents` 中的 video path 加進 `userImagePaths`。
   - 影片檔案被刪除時，走的是同一條讀檔路徑。

7. **首次送出時檔案在選取後被移動或刪除**
   - 比較少見，但本質相同。

### 3.2 具體重現步驟

1. 送出一張圖片，訊息內容存成：
   ```text
   [image:C:\Users\...\upload\a.png]
   ```
2. 到「設定 → 儲存空間」刪除該圖片，或手動刪除 `upload/a.png`。
3. 回到該對話，按「重新生成」。
4. `buildUserImagePaths(input: null)` 回傳舊路徑。
5. `_encodeBase64File()` 讀檔失敗：
   - 一般缺失：`PathNotFoundException`（errno 2）
   - Windows 非法字元：`FileSystemException`（errno 123）

### 3.3 為什麼只有某些模型會遇到？

P1 本身是**所有供應商**都可能遇到；但實際表現會取決於：

- 該供應商是否支援圖片輸入。
- 該訊息是否是最後一則 user 訊息。
- 是否有 `userImagePaths`。
- 是否在重新生成 / 續聊路徑。

原始回報的 Gemini 3.5 Flash Lite 錯誤主要是 P0，因為只有 Gemini 會把 system 訊息當 `role: 'user'` 掃 marker。P1 則是另一條路徑，不能只用「Gemini 特有」來理解。

---

## 4. 影響

### 4.1 直接影響

- 例外發生在 HTTP 請求送出前，該輪請求直接失敗。
- `PathNotFoundException` 不是 transient error，L1 重試機制不會重試。
- 只要該訊息仍是最後一則 user 訊息，每次重新生成都會再次失敗。
- 使用者會看到錯誤，但可能不知道是「附件檔案已不存在」。

### 4.2 間接影響

- **重新生成 / 續聊 / ask_user resume**：最常踩到。
- **AI Team**：每個 proposer 都拿到同一份 `userImagePaths`；可能全部失敗或全部降級。
- **OCR**：`OcrService` 也直接把 `userImagePaths` 傳給 `sendMessageStream`；若不做預檢，可能從「OCR 失敗」變成「沒有圖片卻繼續跑」。
- **OpenAI Images / Agnes**：image edit 的輸入圖缺失時，`MultipartFile.fromPath()` 或 `_imageRefToAgnesImage()` 會拋例外。

### 4.3 嚴重度

- 對「已刪除附件」的舊對話：**高**，因為該對話可能永久無法重新生成。
- 對一般新對話：**低**，因為檔案通常存在。
- 對跨供應商穩定性：**中高**，因為不是 Gemini 專屬。

---

## 5. 歷史與歸因：P1 是既有問題

### 5.1 Git 時間線

| 日期 | Commit | 內容 |
|---|---|---|
| 2025-08-29 | `a210c8e6` init | `_encodeBase64File()` 的 `File.readAsBytes()` 從初始版本就沒有 try/catch |
| 2025-12-04 | `e952ca9f` | `parseInputFromRaw()` / `lastUserImagePaths` 出現；regex 直接抓 `[image:...]`，沒有檔案檢查 |
| 2025-12-05 | `825dd4eb` | `buildUserImagePaths()` 出現，原樣傳遞 `input.imagePaths` / `lastUserImagePaths` |
| 2025-12-17 | `5f201adb` | 儲存空間管理頁出現；刪除 upload 檔案後，訊息中的舊路徑不會被修正 |
| 2026-08-01 | `6854896c` | `_encodeBase64File()` 僅簽名排版改變，讀檔邏輯沒有變安全 |
| 2026-11-11 | `54b56158` | 本次 workspace prompt 修改；**沒有碰** `_encodeBase64File()`、`parseInputFromRaw()`、`buildUserImagePaths()`、`lastUserImagePaths` |

### 5.2 結論

- **P1 的程式缺陷至少從 2025-08-29 就存在。**
- `userImagePaths` 這條路徑從 2025-12 就有。
- 儲存空間刪除造成的 stale path 從 2025-12 就有。
- 最近的 `54b56158` 只改 workspace prompt 相關檔案，不是 P1 的來源。

### 5.3 與原始錯誤的關係

你最初回報的 Gemini 3.5 Flash Lite 錯誤，肇因是 **P0**：

```text
system prompt 的 [image:<absolute-path>]
→ Gemini 把 system 當 user
→ _parseTextAndImages() 把 <absolute-path> 當檔案
→ File('<absolute-path>').readAsBytes()
→ errno 123
```

在符合工作區條件時，P0 是每次請求都必炸，所以看起來像最近的 regression。  
P1 則是舊的 latent bug，只有在檔案缺失/不可讀/非法時才會出現。

**P1 不是本次錯誤的肇因，但它是同一類「把路徑當成一定可讀」假設的既有殘留。**

---

## 6. 解決方案

### 6.1 設計原則

1. **讀檔失敗不能中斷整個請求**
   - 圖片是附件，不應該讓文字對話完全無法使用。
2. **不要靜默丟棄**
   - 用普通文字 fallback 告訴模型「有圖片但不可用」。
3. **不要用 `[image:...]` 當 fallback**
   - 避免重播時再次被 parser 命中。
4. **正常圖片路徑不變**
   - 只改失敗分支，不改成功路徑的格式與 MIME。
5. **不要在全域 `sendMessageStream` 過濾 `userImagePaths`**
   - 會影響 OCR、影片-only 訊息與其他 caller。
6. **Image edit 不做文字降級**
   - OpenAI Images / Agnes 沒有輸入圖就沒有意義，應給清楚的 typed error。
7. **OCR 維持原本失敗語意**
   - 缺圖時回傳 `null`，不要讓 OCR 模型對沒有圖片的 prompt 產生幻覺。

### 6.2 Phase 1：低風險修正

Phase 1 只改失敗路徑，不改附件挑選、訊息組裝、資料庫、prompt 或 UI。

#### 6.2.1 安全化 `_encodeBase64File()`

建議改成：

```dart
static Future<String?> _encodeBase64File(
  String path, {
  bool withPrefix = false,
}) async {
  try {
    final fixed = SandboxPathResolver.fix(path);
    final bytes = await File(fixed).readAsBytes();

    // 空檔案不可能是有效圖片/影片；可視為不可用。
    if (bytes.isEmpty) return null;

    final b64 = base64Encode(bytes);
    if (withPrefix) {
      return 'data:${_mimeFromPath(fixed)};base64,$b64';
    }
    return b64;
  } on FileSystemException catch (e) {
    _logImageReadFailure(path, e);
    return null;
  } on Exception catch (e) {
    _logImageReadFailure(path, e);
    return null;
  }
}
```

要點：

- 主要 catch `FileSystemException`；`PathNotFoundException`、`PathAccessException` 都是它的子類。
- 不要 catch `Error`（例如 `OutOfMemoryError`）。
- `_logImageReadFailure` 只記錄 basename 或通用訊息，避免把完整本機路徑寫進 log。此 helper 為本方案新增的私有函式；可直接用 `FlutterLogger.log` 實作，或內聯處理。
- `bytes.isEmpty` 檢查是建議選項；若不想改變空檔案行為，可先不加，另案處理。

#### 6.2.2 更新所有呼叫端

目前 `_encodeBase64File()` 有 **10 個呼叫點**：

| 傳輸 | 行號 | 用途 |
|---|---|---|
| Responses | 3285 | parsed `ref.kind == 'path'` |
| Responses | 3303 | `userImagePaths` |
| OpenAI Chat | 3508 | parsed path |
| OpenAI Chat | 3535 | `userImagePaths` |
| Claude | 4908 | `userImagePaths` |
| Gemini 串流 | 6093 | parsed path |
| Gemini 串流 | 6117 | `userImagePaths` |
| Gemini 非串流 | 6491 | parsed path |
| Gemini 非串流 | 6515 | `userImagePaths` |
| Agnes | 7397 | `_imageRefToAgnesImage()` |

另外還有 **1 個同類裸讀點**：

| 位置 | 行為 |
|---|---|
| `chat_api_service.dart:7809-7832` | OpenAI Images edit 的 `MultipartFile.fromPath()` |

`null` 時的做法：

- **聊天傳輸**：加入普通文字 part，例如 `(image unavailable)`。
- ** Responses**：user 用 `input_text`，assistant 用 `output_text`。
- **OpenAI Chat / Gemini / Claude**：用 `text` part。
- **OpenAI Images / Agnes**：不要文字 fallback，丟出清楚的 `FormatException`。

Gemini 範例：

```dart
final b64 = await _encodeBase64File(ref.src, withPrefix: false);
if (b64 == null) {
  parts.add({'text': '(image unavailable)'});
} else {
  parts.add({
    'inline_data': {'mime_type': mime, 'data': b64},
  });
}
```

OpenAI Chat 範例：

```dart
final url = await _encodeBase64File(p, withPrefix: true);
if (url == null) {
  parts.add({'type': 'text', 'text': '(image unavailable)'});
} else {
  addImageUrl(url);
}
```

Claude 範例：

```dart
final b64 = await _encodeBase64File(p, withPrefix: false);
if (b64 == null) {
  parts.add({'type': 'text', 'text': '(image unavailable)'});
} else {
  parts.add({
    'type': 'image',
    'source': {
      'type': 'base64',
      'media_type': mime,
      'data': b64,
    },
  });
}
```

實作規則：

- **禁止** `?? ''`：空 base64 會產生無效的 `data:image/...;base64,` 或空 `inline_data`。
- fallback 不要帶完整本機路徑；需要區分多張圖時用序號，例如 `(image 1 unavailable)`。
- 同一張圖只加一次 fallback；可用 per-message `Set<String>` 去重。
- 若 raw text 已經保留同一個 `[image:path]` marker，可跳過 fallback，避免重複。
- fallback 只存在於本次 API messages，不會寫回聊天記錄。

#### 6.2.3 OCR 入口預檢

`OcrService` 在 `ocr_service.dart:74` 直接呼叫 `sendMessageStream()` 並傳入 `userImagePaths`。

如果 Phase 1 讓缺圖變成文字 fallback，OCR 可能變成「沒有圖片卻繼續跑」，模型有機會產生幻覺。因此 Phase 1 應加上 local path 預檢：

```dart
Future<bool> _hasReadableLocalImages(List<String> paths) async {
  for (final raw in paths) {
    final p = raw.trim();
    if (p.isEmpty) continue;

    // data / http(s) 不是本機檔案，交由 transport 處理。
    if (p.startsWith('data:') ||
        p.startsWith('http://') ||
        p.startsWith('https://')) {
      continue;
    }

    try {
      final fixed = SandboxPathResolver.fix(p);
      final stat = await File(fixed).stat();
      if (stat.type != FileSystemEntityType.file || stat.size == 0) {
        return false;
      }
    } catch (_) {
      return false;
    }
  }
  return true;
}
```

`ocr_service.dart` 需新增 `dart:io` 與 `SandboxPathResolver` import（若尚未存在）。  
在 `runOcrForImages()` 呼叫 `sendMessageStream()` 前：

```dart
if (!await _hasReadableLocalImages(imagePaths)) return null;
```

這樣 OCR 缺失圖片時仍回傳 `null`，維持原本「OCR 失敗」的語意，不會產生文字化 OCR。

#### 6.2.4 OpenAI Images / Agnes

這兩個路徑不應該降級成文字：

- OpenAI Images edit：`MultipartFile.fromPath()` 包 try/catch，失敗丟 `FormatException('Input image is unavailable: ...')`。
- Agnes：`_imageRefToAgnesImage()` 遇到 `null` 丟 `FormatException`。

這樣仍然是失敗，但錯誤訊息清楚，且維持原本「image edit 需要輸入圖」的語意。

#### 6.2.5 Phase 1 測試

1. **`_encodeBase64File()` 單元測試**
   - 不存在的路徑 → 回傳 `null`，不拋例外。
   - 字面 `<absolute-path>` → 回傳 `null`。
   - 路徑是目錄 → 回傳 `null`。
   - 空檔案 → 回傳 `null`（若採用空檔案檢查）。
   - 合法 PNG → 回傳 base64 / data URL。
   - 可用 `@visibleForTesting` seam，沿用 P0 的 `parseTextAndImagesForTest` 模式。

2. **跨供應商整合測試**
   - 用 fake HTTP server 攔截請求。
   - 傳入 `userImagePaths: ['<absolute-path>']` 或已刪除的暫存檔。
   - 斷言：
     - 請求仍有送出。
     - body 含 `(image unavailable)` 文字 part。
     - Gemini body 不含 `inline_data`。
     - 沒有拋出 `PathNotFoundException`。

3. **合法圖片回歸測試**
   - 正常圖片仍會產生 base64 / `inline_data` / `image_url`。
   - 不能只測缺圖，否則可能誤把正常圖片也降級。

4. **OCR 預檢測試**
   - 缺失 local path → `runOcrForImages()` 回傳 `null`，不呼叫 transport。
   - `data:` / `http(s)` 不會被 local path 預檢誤擋。

5. **Images API 測試**
   - 缺失輸入圖 → 清楚的 `FormatException`，不是 raw `PathNotFoundException`。

---

### 6.3 Phase 2：UX 提示（選配）

Phase 1 只保證不再中斷請求；使用者仍可能不知道圖片沒送到。

Phase 2 建議：

- 在 chat 專屬的 `buildUserImagePaths()` 回傳：
  ```dart
  class UserImageSelection {
    final List<String> paths;
    final List<String> unavailable;
  }
  ```
- 由 `chat_actions` 顯示一次 snackbar：
  > 「1 張圖片無法讀取，已以文字方式送出。」
- 重用既有的 `attachmentErrorUnavailable` / `attachmentSkippedNotice` 字串或模式。
- 每次送出只提示一次，避免重試/每輪 follow-up 重複跳通知。

**不要**把這個預檢放進全域 `sendMessageStream()`，原因見下一節。

### 6.4 不建議做的事

1. **不要在 `sendMessageStream()` 全域過濾 `userImagePaths`**
   - `sendMessageStream()` 的 caller 不只聊天：
     - `AgentOrchestrator.sendRoundImpl()`：聊天
     - `OcrService.runOcrForImages()`：OCR
     - `TranslationService`：翻譯（不傳圖片）
     - `_generateTextViaStream()`：內部文字生成（不傳圖片）
   - 全域過濾會影響 OCR 與影片-only 訊息，且可能讓內容變成空。
2. **不要 catch 後回傳空字串**
   - 會產生空 base64，供應商可能 400。
3. **不要用 `[image:...]` 當 fallback**
   - 重播時可能再次被 parser 命中。
4. **不要只用 `existsSync()` 取代 try/catch**
   - 檔案可能在檢查後才消失（TOCTOU），權限問題也可能在讀取時才爆發。
5. **不要讓 OpenAI Images / Agnes 降級成文字**
   - image edit 沒有輸入圖就沒有意義。
6. **不要把 `parseInputFromRaw()` 改成 async 或直接在裡面過濾**
   - 它也用於 composer 還原；改動會影響 UI 附件顯示。驗證應放在送出/OCR 邊界。

---

## 7. 風險評估

### 7.1 風險表

| 面向 | 風險 | 原因 |
|---|---|---|
| 編譯 / 型別 | 低 | `_encodeBase64File()` 是 private；改成 `String?` 後編譯器會強制所有呼叫點處理 |
| 正常圖片 | 低 | 成功路徑不變；但必須有回歸測試，避免 `?? ''` 之類的錯誤 |
| 缺圖行為 | 中 | 從「整輪失敗」變成「缺圖但繼續」，屬於產品行為改變 |
| OCR | 中 | 若不做預檢，可能從 OCR 失敗變成文字化 OCR |
| Images API | 低 | typed error 仍維持失敗語意，只改善錯誤訊息 |
| 效能 | 低 | 沒有新增 stat/讀檔；只是多一層 catch |
| 資料庫 / 備份 | 無 | 完全沒有動 |
| UI | 低 | Phase 1 不動 UI；但會有靜默降級的 UX 風險 |
| 大檔案 / OOM | 未解決 | try/catch 不能處理記憶體上限，這是另一個問題 |

### 7.2 為什麼 Phase 1 是低風險

- 主要改 `chat_api_service.dart` 的失敗分支與 10 個呼叫點，另加 `ocr_service.dart` 的 local path 預檢。
- 不改附件挑選、訊息組裝、資料庫、prompt、UI。
- 不改 `sendMessageStream()` 的簽名或流程。
- 正常圖片的輸出格式完全不變。
- fallback 只存在於本次 API messages，不會污染聊天記錄。
- 編譯器會抓到漏改的呼叫點。

### 7.3 Phase 1 仍有的產品風險

Phase 1 最大的風險不是 crash，而是：

> **使用者以為圖片已送出，但模型其實沒看到圖。**

因此：

- Phase 1 可以用 `(image unavailable)` 讓模型知道附件不可用。
- Phase 2 應加 UI 提示。
- 若某個場景不允許降級（OCR、image edit），要用預檢或 typed error 保持失敗語意。

### 7.4 結論

> **工程風險：低。**  
> **產品行為風險：中等。**  
> **整體：低到中等、可控。**

前提是 Phase 1 嚴格限制在「失敗路徑」且包含 OCR 預檢；若同時做全域 `userImagePaths` 預檢，風險會上升到中高。

---

## 8. 測試與驗證

### 8.1 單元測試

- `_encodeBase64File()` 缺失路徑。
- `_encodeBase64File()` 字面 `<absolute-path>`。
- `_encodeBase64File()` 目錄路徑。
- `_encodeBase64File()` 空檔案（若採用空檔案檢查）。
- `_encodeBase64File()` 合法 PNG。
- OCR local path 預檢（缺失 / 合法 / data URL / http URL）。

### 8.2 整合測試

- OpenAI Chat：缺圖仍送出請求，body 有 `text` fallback，無空 `image_url`。
- Responses：缺圖仍送出請求，body 有 `input_text` / `output_text` fallback。
- Claude：缺圖仍送出請求，body 有 `text` fallback。
- Gemini 串流 / 非串流：缺圖仍送出請求，body 有 `text` fallback，無 `inline_data`。
- 合法圖片：四個供應商都仍產生正確的 image part。
- OpenAI Images / Agnes：缺圖產生清楚的 `FormatException`。

### 8.3 建議指令

```bash
dart format lib/core/services/api/chat_api_service.dart \
  lib/features/home/services/ocr_service.dart \
  test/...

dart analyze lib/core/services/api/chat_api_service.dart \
  lib/features/home/services/ocr_service.dart \
  test/...

flutter test test/chat_api_service_inline_image_marker_test.dart \
  test/file_workspace_prompt_test.dart \
  test/core/services/api/agent_loop_provider_parity_test.dart

git diff --check
```

實際測試檔名依新增測試調整。

---

## 9. 驗收標準

- [ ] 缺失 local image 時，四個聊天傳輸都不再拋 `PathNotFoundException`。
- [ ] 請求仍有送出，body 含普通文字 fallback。
- [ ] 缺失圖片不會產生空 base64、空 `inline_data` 或空 `image_url`。
- [ ] 合法圖片仍正常編碼，格式與修改前一致。
- [ ] Gemini 缺圖 body 不含 `inline_data`。
- [ ] OCR 缺失 local image 時回傳 `null`，不呼叫 transport。
- [ ] OCR 的 `data:` / `http(s)` 圖片不被 local path 預檢誤擋。
- [ ] OpenAI Images / Agnes 缺圖時給出清楚 typed error。
- [ ] `dart analyze` 沒有新增本次修改造成的問題。
- [ ] `git diff --check` 通過。

---

## 10. 附錄

### 10.1 關鍵程式碼位置

| 檔案 | 角色 |
|---|---|
| `lib/core/services/api/chat_api_service.dart` | `_encodeBase64File()`、各 transport 的 `userImagePaths` 呼叫點、OpenAI Images multipart |
| `lib/features/home/services/message_builder_service.dart` | `parseInputFromRaw()`、`lastUserImagePaths` 捕獲、`processUserMessagesForApi()` |
| `lib/features/home/services/message_generation_service.dart` | `buildUserImagePaths()` |
| `lib/features/home/services/ocr_service.dart` | OCR 的 `sendMessageStream()` 呼叫與預檢位置 |
| `lib/core/services/agent/agent_orchestrator.dart` | 聊天 transport 的 `sendMessageStream()` caller |
| `lib/core/services/storage/storage_usage_service.dart` | 刪除 upload 檔案（不會修正訊息路徑） |

### 10.2 Git 時間線

| 日期 | Commit | 說明 |
|---|---|---|
| 2025-08-29 | `a210c8e6` | `_encodeBase64File()` 初始版本即裸讀 |
| 2025-12-04 | `e952ca9f` | `parseInputFromRaw()` / `lastUserImagePaths` |
| 2025-12-05 | `825dd4eb` | `buildUserImagePaths()` |
| 2025-12-17 | `5f201adb` | 儲存空間管理頁 |
| 2026-08-01 | `6854896c` | `_encodeBase64File()` 簽名排版變更，讀檔邏輯未變 |
| 2026-11-11 | `54b56158` | workspace prompt 修改（P0 觸發源），未動 P1 |

### 10.3 相關測試

- `test/file_workspace_prompt_test.dart`
- `test/chat_api_service_inline_image_marker_test.dart`
- `test/core/services/api/agent_loop_provider_parity_test.dart`
- 新增：`test/chat_api_service_image_read_failure_test.dart`（建議名稱）
- 新增：`test/features/home/services/ocr_service_image_preflight_test.dart`（建議名稱）

### 10.4 待裁示事項

| 項目 | 建議 |
|---|---|
| fallback 是否帶路徑 | 不帶；用 `(image unavailable)` 或序號 |
| 空檔案是否視為不可用 | 建議是；可另案決定 |
| OCR 預檢 | Phase 1 必做 |
| UI 提示 | Phase 2 |
| 全域 `userImagePaths` 預檢 | 不做 |
| OpenAI Images / Agnes | typed error，不文字降級 |
| 大檔案 / OOM | 另案處理 |
| 路徑安全 / 任意本機檔案讀取 | 另案安全審查，不混入 P1 |

---

## 11. 變更紀錄

| 版本 | 日期 | 變更 |
|---|---|---|
| v1.0 | 2026-11-12 | 初版：整理 P1 問題鏈、歷史歸因、Phase 1 / Phase 2 方案、風險與測試計畫 |
