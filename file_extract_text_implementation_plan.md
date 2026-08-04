# `file_extract_text` 第一階段實作計畫

## 1. 目標

在現有 Workspace Direct Function Call 架構中，新增一個唯讀工具：

```text
file_extract_text
```

讓 LLM 可以讀取 workspace 內下列檔案的文字內容：

- PDF：抽取可選取的文字。
- DOCX：抽取 Word 主文件中的文字。
- PPTX：抽取投影片中可見的文字。

本階段不支援 XLSX，也不加入文件生成或修改能力。

## 2. 明確非目標

本階段不得加入以下功能：

- XLSX、XLS、XLSM 讀取。
- DOC、PPT 等舊式二進位 Office 格式。
- DOCX/PPTX/PDF 生成、編輯、轉檔或覆寫。
- PDF 掃描影像 OCR。
- PDF 圖片、附件、表單欄位、註解或版面還原。
- DOCX 頁首、頁尾、註腳、尾註、註解、文字方塊與完整版面還原。
- PPTX 講者備註、圖表快取資料、動畫、版面或圖片抽取。
- Raw bytes、Base64 或二進位內容回傳給 LLM。
- Shell、CLI、PRoot、Alpine、MCP Server 或任何外部命令執行。
- 新增 WorkspaceResolver、ChatApiService、FileRecord 或 Backup 架構。

## 3. 現有架構與可重用程式碼

目前 Workspace 已使用 Direct Function Call，新增工具應完全沿用既有流程。

主要檔案：

- `lib/core/services/file/file_tool_service.dart`
  - 既有 file tool schema。
  - `execute()` tool dispatch。
  - `resolveSafePath()` workspace boundary 檢查。
  - `FileToolResult` tool result 與檔案 metadata。
- `lib/core/services/chat/document_text_extractor.dart`
  - 現有 PDF 與 DOCX 附件文字抽取器。
- `lib/features/home/services/tool_handler_service.dart`
  - 以 `name.startsWith('file_')` 統一分派 Workspace file tools。
- `lib/features/home/services/message_builder_service.dart`
  - Workspace system prompt 與可用工具清單。
- `test/file_tool_service_test.dart`
  - 現有 file tool sandbox、限制與 CRUD 測試。

目前已存在且本階段可直接重用的依賴：

- `archive`
- `xml`
- `syncfusion_flutter_pdf`

依賴決策：

- `archive` 與 `xml` 已存在於目前專案，不需要新增到 `pubspec.yaml`。
- 目前 lock 版本為 `archive 4.0.7` 與 `xml 6.6.1`，第一階段應維持現有 major version。
- `archive` 只作為 DOCX/PPTX 的 ZIP 容器解析器，不新增 `archive_read` 或通用 ZIP 解壓 tool。
- `xml` 只解析已確認的 OOXML XML entry，不新增 `xml_read` 或通用 XML tool。
- LLM 不得控制 archive entry path，也不得要求將 archive 解壓到 workspace。
- 不應為了 DOCX/PPTX 引入依賴 `archive 3.x` 的 `docx_to_text` 或其他替代套件。
- 若實作需要升級 `archive` 或 `xml` major version，應先停止並重新評估 Syncfusion 相容性，不得在本階段自行升級。

不得新增以下套件：

- `excel`
- `excel_plus`
- `pdf_text`
- `docx_to_text`
- `dart_pptx`
- `flutter_pptx`
- `open_xml`

## 4. Tool 介面

### 4.1 Tool 名稱

固定使用 `file_extract_text`，不可使用 `pdf_read`、`docx_read` 或 `pptx_read` 作為第一階段的公開 tool 名稱。

原因：現有 `ToolHandlerService` 會將 `file_*` 呼叫送至 `FileToolService`；使用其他名稱會落入 MCP/其他工具分派流程，必須額外修改 handler。

### 4.2 建議 schema

在 `FileToolService.getToolDefinitions()` 新增以下 function definition：

```json
{
  "type": "function",
  "function": {
    "name": "file_extract_text",
    "description": "Extract text from a PDF, DOCX, or PPTX file inside the current workspace. Use relative paths only. This tool returns text only and does not perform OCR or preserve document layout.",
    "parameters": {
      "type": "object",
      "properties": {
        "path": {
          "type": "string",
          "description": "Relative path to a PDF, DOCX, or PPTX file inside the current workspace."
        },
        "format": {
          "type": "string",
          "enum": ["auto", "pdf", "docx", "pptx"],
          "description": "Optional format override. Defaults to auto-detection from the file extension and file signature."
        },
        "offset": {
          "type": "integer",
          "description": "Optional zero-based UTF-8 byte offset in the extracted text. Defaults to 0. Use next_offset from the previous result to continue."
        },
        "limit": {
          "type": "integer",
          "description": "Optional number of UTF-8 bytes to return from the extracted text. Defaults to 16384 and is capped at 24576."
        }
      },
      "required": ["path"]
    }
  }
}
```

實際 Dart schema 應遵循現有 `FileToolService.getToolDefinitions()` 的格式與命名風格。

### 4.3 Result 格式

Tool result 必須是文字，並包含可供 LLM 續讀的 metadata：

```text
[Extracted format=pptx; bytes 0-1200 of 4200; next_offset=1200; has_more=true]
--- Slide 1 ---
Title
Body text
--- Slide 2 ---
More text
```

要求：

- `offset` 與 `next_offset` 使用抽取結果的 UTF-8 byte offset。
- 不可在 UTF-8 code point 中間切斷文字。
- `limit` 預設 16 KiB，單次 hard cap 24 KiB，與既有 `file_read` 行為一致。
- `has_more=true` 時必須提供有效的 `next_offset`。
- 空白結果應回傳格式與檔案資訊，並明確說明沒有可抽取文字。
- 錯誤只回傳安全的錯誤文字，不回傳 workspace 絕對路徑或 parser stack trace。

### 4.4 `archive` 與 `xml` 的實作範圍

這兩個套件不是新的 Workspace tool，也不是使用者可直接呼叫的服務。它們只在 `DocumentTextExtractor` 內部使用：

| 套件 | 用途 | 使用限制 |
|---|---|---|
| `archive` | 讀取 DOCX/PPTX 的 ZIP container | 不落地解壓、不建立 symlink、不處理任意 archive path |
| `xml` | 解析指定的 `document.xml`、slide XML 與 relationship XML | 只解析必要 entry，不接受 LLM 提供的 XML，不執行 DTD/XSLT/XQuery |

實作前應先確認目前 lock 版本的 API。若使用 `ZipDecoder().decodeBytes()`，必須配合來源檔案大小、entry 數量、entry 解壓後大小與 XML part 大小限制，因為 memory decode 可能同時保留壓縮資料、解壓資料與 XML DOM。

若現有 `archive 4.x` API 能安全使用 `InputFileStream`/`decodeStream` 讀取，應優先評估該方式；但不得為了追求 streaming 而改用另一個 archive major version。第一階段的最低要求是：即使維持目前 API，也必須有 hard caps、錯誤處理與不落地解壓保護。

`xml` 對單一受限 XML part 可使用 DOM API；不得把整個 workspace 檔案或整個 ZIP 當作 XML 輸入。若 XML part 可能超過上限，應在 parse 前拒絕，而不是讓 DOM 無限制成長。

## 5. 實作步驟

### Step 1: 擴充 `FileToolService`

修改 `lib/core/services/file/file_tool_service.dart`：

1. 在 `getToolDefinitions()` 加入 `file_extract_text` schema。
2. 在 `execute()` 加入 `file_extract_text` case。
3. 使用既有 `_prepareWorkspace()` 與 `resolveSafePath()`。
4. 只允許 regular file，不允許目錄、symlink 跳出 workspace 或 absolute path。
5. 在 parser 執行前檢查來源檔案大小。
6. 將 parser 回傳的完整文字交給共用的 bounded text segment 邏輯。
7. `FileToolResult` 只填入 `text`，不要建立或修改 `FileRecord`。

建議新增常數，避免重用寫入限制：

```dart
static const int defaultExtractResultBytes = 16 * 1024;
static const int maxExtractResultBytes = 24 * 1024;
static const int maxExtractInputBytes = 16 * 1024 * 1024;
static const int maxExtractedTextBytes = 256 * 1024;
```

上述數值可在實作時依測試調整，但必須有明確 hard cap，不能無限制地讀取或建立文字結果。

### Step 2: 擴充既有 `DocumentTextExtractor`

修改 `lib/core/services/chat/document_text_extractor.dart`，不要建立另一個平行的 document service。

保留現有附件流程的 `extract({path, mime})` API，另外增加一個供 Workspace 使用的受限入口，例如：

```dart
static Future<DocumentExtractionResult> extractWorkspaceText({
  required String safePath,
  required String format,
  required int maxInputBytes,
  required int maxOutputBytes,
})
```

注意：此入口接收的必須是已經由 `FileToolService.resolveSafePath()` 解析過的 safe path，不接受 LLM 原始 path，也不自行放寬 workspace boundary。

### Step 3: PDF 抽取

使用現有 `syncfusion_flutter_pdf`：

1. 先檢查檔案大小與 PDF signature。
2. 以 `PdfDocument` 載入檔案。
3. 優先按頁抽取，讓 parser 可以在達到 `maxExtractedTextBytes` 時停止。
4. 每頁之間加入清楚的 page break marker，例如 `--- Page N ---`。
5. 使用既有 `UnicodeSanitizer.sanitize()`。
6. 以 `try/finally` 確保 `PdfDocument.dispose()` 一定執行。
7. 無文字時回傳「PDF 沒有可抽取文字，可能是掃描影像」的明確結果。

不引入 `pdf_text` 或 `pdf`。

### Step 4: DOCX 抽取

使用既有 `archive` 與 `xml`：

1. 檢查 ZIP signature 與來源大小。
2. 確認 ZIP 內存在 `word/document.xml`。
3. 只解析 `word/document.xml`。
4. 按 `w:p` 保留段落換行。
5. 讀取其中的 `w:t`，保留同一段落內的文字順序。
6. 既有 parser 已能透過 `w:p` 讀到一般表格儲存格文字，應保留此行為。
7. 不需在本階段加入頁首、頁尾、註腳、註解或完整格式還原。
8. 對 malformed ZIP、缺少 XML、XML parse error 回傳可理解的錯誤。

解析時不得將 ZIP 內容解壓到 workspace 或暫存目錄。

### Step 5: PPTX 基本文字抽取

使用既有 `archive` 與 `xml`，自行加入受限 parser：

1. 檢查 ZIP signature。
2. 確認存在 `ppt/presentation.xml`。
3. 讀取 `ppt/_rels/presentation.xml.rels`。
4. 依 `p:sldIdLst` 中的 relationship 順序取得投影片，而不是依 ZIP entry 順序或檔名排序。
5. 對每張 slide XML，依 XML 文件順序讀取 `a:t` 節點。
6. 同一文字段落保留合理的文字連接與換行。
7. 每張投影片加入 `--- Slide N ---` marker。
8. 只處理投影片可見文字；不處理 notes、圖片、動畫、版面、圖表快取資料或完整 OOXML 結構。
9. 至少測試 `slide1.xml`、`slide2.xml`、`slide10.xml` 的正確順序。

不可使用已 discontinued 的 `dart_pptx` 或 `flutter_pptx`。

### Step 6: 更新工具提示

修改 `lib/features/home/services/message_builder_service.dart` 的 Workspace prompt：

- 將 `file_extract_text` 加入可用工具清單。
- 說明只支援 PDF、DOCX、PPTX。
- 說明使用 workspace-relative path。
- 說明大檔案必須使用 `next_offset` 續讀。
- 說明 PDF 掃描影像不會自動 OCR。
- 說明 `file_read` 仍只適合 UTF-8 純文字，不應用來直接讀取 PDF/DOCX/PPTX binary。

### Step 7: 確認不需要修改的模組

正常情況下，下列模組不應修改：

- `WorkspaceResolver`
- `ChatApiService`
- `ChatService` 的 FileRecord schema
- Backup 格式
- Workspace UI
- Android manifest 或權限設定

原因：這是唯讀文字 tool，結果在既有 tool result channel 中傳遞，不會產生或修改檔案。

若實作結果可能超過 24 KiB，必須在 `FileToolService` 內先截斷，而不是依賴 API layer 的 32,768 字元截斷。

## 6. 安全與資源限制

### Path safety

- 所有 LLM path 必須先經過 `resolveSafePath()`。
- 拒絕 NUL character。
- 拒絕 absolute path。
- 拒絕 `..` 穿越 workspace。
- 拒絕 symlink 解析到 workspace 外。
- 不將 parser 接收到的 path 直接交給外部命令。

### Input limits

- 來源檔案超過 `maxExtractInputBytes` 時，在 parser 前拒絕。
- 只接受 regular file。
- ZIP entry 數量與解壓後大小必須有上限。
- 不建立 ZIP entry 對應的實體檔案。
- 不處理外部 URL、external link 或 macro。

### Output limits

- Parser 內部文字結果不得無限制累積。
- DOCX/PPTX 達到 `maxExtractedTextBytes` 後停止或標記結果截斷。
- PDF 優先使用逐頁抽取，達到上限後停止。
- 最終 tool result 不超過 24 KiB 的 UTF-8 bytes，並保留 metadata。

### UI responsiveness

若實測顯示大型 PDF/DOCX/PPTX 會阻塞 Flutter UI，將 parser 呼叫移到 background isolate。即使暫時不做 isolate，也必須先有 input/output hard caps，不能以無限制主 isolate 解析作為正式版本行為。

## 7. 測試計畫

### FileToolService tests

在 `test/file_tool_service_test.dart` 增加：

- tool definitions 包含 `file_extract_text`。
- 正常讀取 PDF、DOCX、PPTX。
- uppercase extension 可正常 auto-detect。
- `format` override 可正常運作。
- absolute path、`../`、NUL path 被拒絕。
- workspace 外 symlink 被拒絕。
- 目錄與不存在的 path 回傳錯誤。
- unsupported extension 回傳明確錯誤。
- 檔案超過 input limit 時不進入 parser。
- `offset`、`limit`、`next_offset`、`has_more` 正確。
- UTF-8 多位元字元不被切斷。
- output hard cap 不被 `limit` 參數繞過。

### PDF tests

- 以測試程式產生包含多頁文字的 PDF，確認 page marker 與續讀。
- 空白 PDF 回傳無文字提示。
- malformed PDF 回傳錯誤而不拋出到 generation 流程。
- 確認 parser 失敗時仍會 dispose document。

### DOCX tests

使用最小 ZIP/XML fixture 測試：

- 多段落文字。
- CJK、emoji 與 UTF-8。
- 表格儲存格文字。
- XML entity 解碼。
- 缺少 `word/document.xml`。
- malformed XML。
- 不會將 ZIP 解壓到 workspace。

### PPTX tests

使用最小 ZIP/XML fixture 測試：

- 單張與多張投影片。
- 投影片文字順序。
- `slide1`、`slide2`、`slide10` 順序。
- relationship 順序與檔名順序不同時仍正確。
- CJK、emoji 與 UTF-8。
- 缺少 presentation XML 或 relationship XML。
- malformed XML/ZIP。

### Integration tests

若現有測試架構允許，增加至少一個 `ToolHandlerService` integration test，確認：

- `file_extract_text` 會由 `file_*` routing 送到 `FileToolService`。
- workspace disabled 時回傳既有 disabled error。
- extraction read 不會建立 FileRecord。

## 8. 實作順序

1. 先為 `DocumentTextExtractor` 整理受限 Workspace extraction API。
2. 加入 PDF extraction 與 result segmentation。
3. 加入 DOCX extraction 與 tests。
4. 加入 PPTX relationship-aware extraction 與 tests。
5. 將 tool schema 與 dispatch 接入 `FileToolService`。
6. 更新 Workspace system prompt。
7. 執行 formatter、分析器與完整測試。
8. 進行 Android 與 Windows debug/release build 驗證。
9. 更新 `CHANGES_LOG.md` 與 Workspace 行為文件。

## 9. 驗收條件

實作完成前，必須全部符合：

- Workspace enabled 且模型支援 tools 時，模型能看到 `file_extract_text`。
- Workspace disabled 時，tool definition 不會提供給模型。
- PDF、DOCX、PPTX 基本文字可成功抽取。
- 所有 path 操作均受既有 workspace boundary 保護。
- 不新增 Shell、MCP、PRoot、Alpine 或額外檔案權限。
- 不新增 XLSX 相關依賴。
- 不會因 malformed binary、ZIP bomb 或超大檔案讓 app crash。
- tool result 可使用 `next_offset` 續讀。
- 不會建立 FileRecord 或修改 workspace 檔案。
- 現有 Workspace、FileTool、Chat、Backup 測試全部通過。
- `flutter analyze` 無新增 error。
- `flutter test` 全部通過。
- Android 與 Windows build 成功。

## 10. 給 Coding Agent 的執行限制

- 先閱讀本計畫與下列實際現況文件，再開始修改：
  - `lib/core/services/file/file_tool_service.dart`
  - `lib/core/services/chat/document_text_extractor.dart`
  - `lib/features/home/services/tool_handler_service.dart`
  - `lib/features/home/services/message_builder_service.dart`
  - `test/file_tool_service_test.dart`
- 不要重新設計 Workspace 架構。
- 不要新增 XLSX 或文件生成能力。
- 不要因為 PPTX 需要解析而引入 discontinued package。
- 不要把 LLM path 直接傳入既有附件 extractor。
- 不要刪除或放寬既有安全檢查。
- 修改後先執行針對性測試，再執行完整 `flutter test`、`flutter analyze` 與平台 build。
- 不要修改或回復其他 agent/使用者未相關的工作區變更。
