# OmniChat Android 分享接收導入計畫

> 狀態：已實作（Android 實機相容性驗證待完成）  
> 範圍：Android 由其他 App 分享文字、圖片及文件至 OmniChat，並將內容填入聊天輸入列草稿。  
> 本文件記錄調查、實作契約與實作現況；功能已實作，尚未完成實機來源 App 相容性驗證。

---

## 1. 背景與目標

使用者觀察到上游 Kelivo 會出現在 Android 瀏覽器的分享選單，而 OmniChat 不會。調查確認兩者的 Android Intent 接收範圍不同：

- OmniChat 目前只宣告 `ACTION_PROCESS_TEXT` / `text/plain`，供 Android 文字選取操作使用；目前原生端也只擷取選取文字並插入輸入框。
- Kelivo 除 `PROCESS_TEXT` 外，亦宣告 `ACTION_SEND`、`ACTION_SEND_MULTIPLE`，並在原生端處理分享文字與 URI，再交由 Flutter 放進聊天輸入列草稿。
- OmniChat 已有輸入列圖片／文件附件狀態及檔案複製流程，可做為 Flutter 草稿匯入的整合點；但目前沒有 Android 一般分享 Intent、`content://` URI 讀取及交接流程。

### 目標

1. 讓 OmniChat 成為一般 Android 分享流程的可解析目標，涵蓋文字、單一／多個檔案。
2. 將接收內容放入聊天輸入列，供使用者檢查及編輯。
3. 沿用現有附件格式與訊息送出流程，避免另建平行附件管線。
4. 保留既有 `PROCESS_TEXT` 行為。

### 非目標

- 收到分享後自動送出訊息或自動呼叫模型。
- 宣稱特定瀏覽器、相簿或檔案 App 一定會顯示 OmniChat；這需依各 App 實際 Intent 與裝置做實測。
- 將 OmniChat 註冊為一般 HTTP/HTTPS 網頁連結處理器。分享「網址文字」與接管網頁連結是不同功能。
- 新增第三方依賴或 Android 儲存權限，除非實作時發現必要且另行評估。

---

## 2. Android 分享解析與 Kelivo 範圍

Kelivo 上游目前宣告：

| Intent | MIME／資料 | 用途 |
|---|---|---|
| `ACTION_SEND`、`ACTION_SEND_MULTIPLE` | `*/*` | 一般文字、單一或多個檔案分享 |
| `ACTION_PROCESS_TEXT` | `text/plain` | 選取文字處理 |
| `ACTION_VIEW` | `content://`、`file://` + `*/*` | 本機內容 URI 開啟；不是一般 HTTP/HTTPS link handler |

Kelivo 原生接收器會檢查 `EXTRA_TEXT`、`EXTRA_STREAM` 及 `ClipData`，讀取分享者授予的 URI，複製到 App 私有位置後才交給 Flutter；上游對一個分享最多處理 32 個 URI。Flutter 將內容加入輸入列草稿，不自動傳送。

公開上游文件、Issue、release notes 與測試未提供具名來源 App 的已驗證相容清單。因此 Chrome、Firefox、YouTube、相簿與檔案管理器只能列為候選測試 App，不能僅憑 Manifest 宣告視為已驗證。

參考來源：

- [Kelivo AndroidManifest.xml](https://github.com/Chevey339/kelivo/blob/d4752260adb1ca959422c4baa01485d80cfcad04/android/app/src/main/AndroidManifest.xml)
- [Kelivo IncomingShareHandler.kt](https://github.com/Chevey339/kelivo/blob/d4752260adb1ca959422c4baa01485d80cfcad04/android/app/src/main/kotlin/com/psyche/kelivo/IncomingShareHandler.kt)
- [Kelivo MainActivity.kt](https://github.com/Chevey339/kelivo/blob/d4752260adb1ca959422c4baa01485d80cfcad04/android/app/src/main/kotlin/com/psyche/kelivo/MainActivity.kt)
- [Kelivo incoming_share_service.dart](https://github.com/Chevey339/kelivo/blob/d4752260adb1ca959422c4baa01485d80cfcad04/lib/core/services/incoming_share_service.dart)
- [Android 接收其他 App 分享資料](https://developer.android.com/develop/ui/compose/sharing/receive)
- [Android Intent filters](https://developer.android.com/guide/components/intents-filters)

---

## 3. 建議使用者體驗

1. 使用者在其他 App 點選「分享」並選擇 OmniChat。
2. OmniChat 開啟或回到前景，切換至聊天首頁／目前可輸入對話。
3. 分享文字併入輸入框；分享的圖片與文件顯示於輸入列既有附件預覽。
4. 使用者可編輯文字、移除附件、追加內容或切換對話。
5. 只有使用者明確按下送出才送出訊息。
6. 某些 URI 無法讀取時，保留可讀內容並明確告知部分附件未匯入；不得讓整個分享流程無聲失敗。

若 App 尚未完成初始化、Flutter 引擎尚未就緒，分享內容需先暫存於 App 私有資料，再於聊天 UI 初始化後交付；不能依賴啟動時 MethodChannel 已存在。

---

## 4. 建議架構與資料流

### 4.1 Android Intent 宣告

- 在主 Activity 新增 `ACTION_SEND` / `ACTION_SEND_MULTIPLE` 的 `CATEGORY_DEFAULT` 接收 filter。
- 首版評估以 `*/*` 支援一般文件及不同分享來源；若採寬 MIME filter，必須在接收端完整驗證 action、MIME、URI 與讀取結果。
- `PROCESS_TEXT` filter 與目前程式碼保持不變。
- 不新增 `ACTION_VIEW`，除非需求明確擴大至開啟本機檔案；不新增 `http`／`https` scheme。
- `singleTop` 已存在。需同時處理冷啟動的初始 Intent 與 App 已存在時的 `onNewIntent`。

### 4.2 原生接收及暫存

原生 Android 層負責在 URI 權限有效期間取得外部資料：

1. 接受 `ACTION_SEND`、`ACTION_SEND_MULTIPLE`；從 `EXTRA_TEXT`、`EXTRA_STREAM`、`ClipData` 蒐集文字及 URI。
2. 對重複 URI 去重；設定明確的每次分享 URI 上限（初步可參照 Kelivo 的 32 個），超出時回報未匯入數量。
3. 優先透過 `ContentResolver` 讀取 `content://`；取得 display name、MIME type 與實際內容，不假設 URI path 是可直接開啟的檔案路徑。
4. 只接受分享授權的 `content://`。**拒絕 `file://`**：`contentResolver` 會以本 App 的 uid 讀取，exported Activity 一旦接受，任何 App 都能把 OmniChat 私有檔案塞進草稿（API 24+ 的 sender 也無法分享 `file://`）。
5. 將內容複製到 App 私有暫存／上傳目錄，保留安全檔名及合理 MIME fallback；不得把授權 URI 當永久附件路徑保存。
6. 以可恢復的 pending-share 記錄交給 Flutter；在 Flutter 確認草稿附件已接收後清理暫存記錄。冷啟動、程序重建、重複回呼及確認時機需定義冪等行為。
7. 傳遞失敗時只記錄不含內容與敏感路徑的診斷資訊，並將可理解的失敗狀態交給 UI。

### 4.3 Flutter 草稿整合

- 沿用 `ChatInputBarController.addImages` / `addFiles` 的既有附件狀態入口。
- 沿用 `FileUploadService` 相關附件命名、MIME／影像分類原則，避免不同匯入入口產生不同的附件表示。
- 分享文字併入輸入框時需明確決定合併政策：空輸入直接填入；已有文字時以換行分隔追加，不可靜默覆蓋使用者正在編輯的內容。
- 確認分享內容只建立草稿；不直接呼叫 `_controller.sendMessage`。
- 冷啟動時等待 HomePage、輸入列與附件控制器就緒後再套用；前景接收則即時套用。
- 若使用者在處理期間切換對話，應避免把分享內容放入錯誤對話；建議以新的草稿／目前首頁輸入列為目標，或先定義清楚的對話歸屬政策。

### 4.4 資源生命週期

- 分享複製檔存於 App 私有上傳目錄，使用現有附件管理方式。
- 使用者移除草稿附件時應按現有行為清除其檔案；分享暫存副本不得在匯入完成前刪除。
- 未被確認／匯入的 pending share 需有清理政策，避免程序中止後永久殘留；清理不得刪除已成為草稿附件或已送出訊息所引用的檔案。
- 首版可先比照現有複製流程，不額外引入資料庫或長期分享歷史。

---

## 5. 隱私、安全與穩定性要求

- 外部分享內容皆視為不可信輸入；檔名需剝除路徑分隔符及控制字元，防止路徑穿越與檔名覆寫。
- 必須以串流複製或受控緩衝方式讀取 URI，並設定單檔及總量上限；具體上限需在實作前依現有附件／模型 API 限制定案，不照搬上游未設限制的行為。
- MIME type 不可信；依 URI provider 宣告、Intent type、檔名推斷交叉處理，未知類型使用安全 fallback，不能只因宣告 `image/*` 就假設內容一定是圖片。
- 對超大檔、讀取失敗、permission grant 失效、無檔名、重複 URI、provider 回傳空內容等情況需可預期地降級並回報。
- 不要求 `MANAGE_EXTERNAL_STORAGE` 才能接收分享；只使用分享 Intent 授予的 URI 權限，除非實測證明必要並另行審查權限政策。
- 不將分享內容、URI token 或檔案內容寫入一般日誌、分析資料或外部服務。
- 寬泛 `*/*` filter 的好處是提高多種 sender MIME 的匹配機會，代價是更廣的候選暴露面；接收端必須限制 action/scheme、檔案數與容量。

---

## 6. 分階段實作計畫

### Phase 0 — 規格確認

- 確認首版目標為一般分享文字、圖片及文件，採草稿、不自動送出。
- 確認多檔上限、單檔／總容量上限、文字追加規則及未完成分享清理方式。
- 確認不處理一般 HTTPS link opening；網址以分享文字接收。

### Phase 1 — Android 接收骨架

- 增加 `SEND` / `SEND_MULTIPLE` filter，保留 `PROCESS_TEXT`。
- 實作冷啟動與 `onNewIntent` 的 Intent 正規化。
- 建立原生 URI 複製與 pending-share 交接契約，含去重、上限及錯誤計數。
- 驗證 `content://` 權限在接收期間可用，且不依賴 URI 實體路徑。

### Phase 2 — Flutter 草稿接線

- 增加 incoming-share service／MethodChannel 或等效事件介面。
- 等聊天頁就緒後，將文字、圖片、文件附件套用至輸入列。
- 保留使用者原有文字及附件；明確處理重複通知與 acknowledgement。
- 確保只有使用者按送出才送出。

### Phase 3 — 錯誤處理與生命週期

- 處理部分 URI 成功、部分失敗、超量、超大檔及暫存清理。
- 驗證從其他 App 返回、App 冷啟動、背景存活及程序重建等路徑。
- 提供必要的在地化提示；若只有少量附件失敗，保留其餘已成功匯入項目。

### Phase 4 — 裝置相容性驗證

- 先使用 Android 測試／模擬器透過 `adb` 送出合成 `ACTION_SEND` / `SEND_MULTIPLE` Intent，檢查資料解析與附件草稿行為。
- 再用實機逐一測試來源 App，記錄 App 名稱、版本、Android 版本、分享 action/MIME、文字／URI 形狀及結果。
- 未實際測過的來源 App 不標示為「已支援」；Manifest 可匹配只代表符合解析條件，不等於該 App 的分享介面一定顯示 OmniChat。

---

## 7. 驗收標準

### Android 原生／Intent

- [ ] `ACTION_SEND` + `text/plain` 分享文字，OmniChat 可出現在標準 Android 分享目標中並正確收到文字。
- [ ] `ACTION_SEND` + `image/*` 與一般文件 MIME 可被接收；`ACTION_SEND_MULTIPLE` 可處理多個 URI。
- [ ] 同一內容同時出現在 `EXTRA_STREAM` 和 `ClipData` 時不產生重複附件。
- [ ] 冷啟動、既有 Activity 的 `onNewIntent`、App 背景恢復三種路徑都不丟失分享。
- [ ] 不匹配或不支援的 action／URI scheme 安全拒絕，不因檔案 URI 解析失敗而崩潰。

### Flutter 草稿

- [ ] 分享文字填入聊天輸入列；既有使用者文字不被覆蓋。
- [ ] 圖片與文件出現在正確的附件預覽中，並能沿用現有移除及送出流程。
- [ ] 接收分享不會自動送出訊息或呼叫模型。
- [ ] 部分附件失敗時仍保留成功項目，並向使用者明示失敗數量。

### 安全與資源

- [ ] 使用 URI grant 讀取 `content://`，不依賴真實檔案路徑或全檔案存取權限。
- [ ] 檔名清洗、檔案數上限、容量上限及未完成暫存清理有測試覆蓋。
- [ ] 分享內容與敏感 URI 不進一般日誌。
- [ ] 分享檔案在草稿附件建立前不會被清理；移除／送出後的生命週期與既有附件一致。

### 來源 App 相容矩陣

每次實機測試至少記錄：

| 欄位 | 記錄內容 |
|---|---|
| 裝置／Android | 型號、Android 版本與系統分享介面 |
| 來源 App | 名稱與版本 |
| 分享內容 | 文字、網址文字、圖片、單檔、多檔 |
| Intent | action、MIME type、`EXTRA_TEXT`／`EXTRA_STREAM`／`ClipData` 實際形狀 |
| 結果 | OmniChat 是否出現、是否可啟動、草稿文字／附件是否正確 |
| 問題 | URI 權限、名稱／MIME 錯誤、部分失敗或其他差異 |

建議候選測試來源：Android 瀏覽器、相簿、檔案管理器及常見通訊／內容 App。此為待驗證矩陣，不代表任何特定 App 已成功。

---

## 8. 預期主要風險

| 風險 | 影響 | 緩解方式 |
|---|---|---|
| Share sender 使用不同 Intent 或 MIME | OmniChat 不出現在該來源 App 的分享 UI | 實機記錄 Intent；必要時以有限的 MIME filter 補充，不盲目宣稱全 App 相容 |
| `content://` provider 權限短暫或 URI 不可讀 | 檔案附件匯入失敗 | 原生端儘早複製；部分失敗回報；測試各類 provider |
| 冷啟動時 Flutter 尚未就緒 | 分享內容遺失 | 原生 pending queue／私有暫存及 acknowledgement |
| 大檔或大量附件 | OOM、啟動延遲、磁碟佔用 | 串流複製、容量／數量上限、逐項失敗隔離 |
| 寬 MIME filter | OmniChat 對更多類型顯示為候選，但不一定能處理所有內容 | 嚴格接收驗證、未知 MIME fallback 與 UI 錯誤訊息 |
| 文字與附件誤入錯誤對話 | 草稿歸屬錯誤或使用者資料意外混合 | 明確定義新／目前對話策略，接收流程序列化並避免默默覆蓋 |

---

## 9. 實作現況與後續決策（2026-10-29）

- 本計畫根據 OmniChat 現有 Android Manifest、`MainActivity`、`AndroidProcessText`、`HomePage`、`FileUploadService` 與 `ChatInputBarController` 調查而成。
- 第一至第三階段（原生接收、Flutter 草稿接線、錯誤與生命週期）已實作；第四階段（實機／模擬器驗證）尚未執行。
- 已定案：每次最多 32 檔、單檔 20 MB、總量 50 MB，未確認暫存保留 7 天；分享文字以換行追加、不覆蓋既有草稿；附件一律落在首頁輸入列草稿，不自動切換對話、不自動送出。
- 上游功能實作可參考，但應遵守 OmniChat 既有附件資料流、錯誤處理與安全政策，不直接複製上游的無限制檔案複製行為。
- 附帶修正：`FileUploadService.copyPickedFiles` 現在遇到上傳目錄已存在的同名檔會加 ` (n)` 而不是靜默覆寫（所有挑選／拖放入口共用），並改為串流複製；`copyPickedFiles` 另接受 `names` 覆寫，因為 dart:io 的 `XFile.name` 會被忽略。

### 實作對照

| 層 | 檔案 | 職責 |
|---|---|---|
| Manifest | `android/app/src/main/AndroidManifest.xml` | `SEND`／`SEND_MULTIPLE` ＋ `*/*` filter；`PROCESS_TEXT` 不變 |
| 原生接收 | `android/app/src/main/kotlin/com/psyche/omnichat/IncomingShareHandler.kt` | 蒐集 `EXTRA_TEXT`／`EXTRA_STREAM`／`ClipData`、去重、串流複製、上限與失敗計數、`share.json` 原子寫入、7 天清理 |
| 原生通道 | `MainActivity.kt` | `omnichat/incoming_share`：`getPendingShares`／`acknowledge`／`onIncomingSharesChanged`；冷啟動與 `onNewIntent` 兩條路徑 |
| Dart 橋接 | `lib/features/home/services/android_incoming_share.dart` | MethodChannel 封裝；`PlatformException`／`MissingPluginException` 一律降級為空結果 |
| 草稿接線 | `lib/features/home/pages/home_page.dart` | 等 `initChat()` 完成、串行化 drain、確認後才套用 UI、失敗提示 |
| 附件匯入 | `lib/features/home/services/file_upload_service.dart` | `importSharedFiles`：檔名清洗、串流複製、同名加 ` (n)`、MIME 交叉判定 |
| 文案 | `lib/l10n/app_*.arb` | `incomingShareFilesFailed`（×4，`count` 為 `int`） |
| 測試 | `test/android_incoming_share_test.dart` | 橋接例外降級、檔名清洗、同名不覆寫、失敗計數 |

### 仍待完成

- 以 `adb` 送出合成 `ACTION_SEND` / `SEND_MULTIPLE` Intent，再逐一實測候選來源 App 並填寫 §7 相容矩陣。
- 程序終止後系統重送原始 Intent（`FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY`）目前視為新分享，未做跨程序去重；如實測造成重複草稿再補持久化去重鍵。
