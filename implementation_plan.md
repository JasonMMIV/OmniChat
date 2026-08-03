# OmniChat LLM 檔案操作功能整合計畫 (Implementation Blueprint)

本文件為執行 OmniChat LLM 檔案操作功能的完整實作藍圖，包含架構決策、10 個 Tool 的完整 Specification、資料結構定義、UI/UX 變更規範，以及所有 15 個受影響檔案的精確修改內容。

---

## 一、架構決策與背景 (Architecture & Decisions)

### 1. 為什麼採用 Direct Function Call（非 MCP Server）
- **動態 Sandbox 支援**：使用者可在對話（Conversation）層級透過 GUI 切換「工作區」目錄。Direct Function Call 允許 `ToolHandlerService` 直接從 `ChatService` 讀取該對話目前的 Workspace 路徑。若採用 MCP Server，需要額外的跨進程/跨元件傳遞狀態機制。
- **核心功能整合**：檔案操作屬於 OmniChat 的核心內建能力（與 Memory, Web Search 同級），非可插拔外部擴充。
- **無狀態與高效能**：直接在 Dart 層與 `dart:io` 對接，避免 JSON-RPC 2.0 序列化/反序列化與 transport 封裝開銷。

### 2. Android 與 Windows 平台相容策略
- **Android (方案 A)**：在 `AndroidManifest.xml` 中宣告 `MANAGE_EXTERNAL_STORAGE` 權限。使用者選擇外部資料夾時，系統引導至 Android 設定授予全檔案存取權。這使得 `dart:io` 的 `File` 和 `Directory` 能直接對外部儲存區進行 Posix 操作，與 Windows 完全一致，無須撰寫 Kotlin Native Platform Channel 或 SAF (`ContentResolver`) 程式碼。
- **Windows**：`file_picker.getDirectoryPath()` 返回真實檔案系統路徑，`dart:io` 直接具備完全存取能力。

### 3. 未設定工作區時的預設行為 (Default Workspace)
- 當使用者尚未為某對話點選「工作區」設定時，系統預設使用 App 私有目錄下的 `files/` 資料夾（`AppDirectories.getFileSandboxDirectory()`），確保 LLM 檔案工具始終靜默可用（Silent Fallback），避免中斷對話流程。

---

## 二、檔案工具規格 (10 File Tools Spec & Security)

### 1. 安全機制 (Security Constraints)
所有檔案工具執行前，**必須**經過 `FileToolService._resolveSafePath(String relativePath, String workspaceRoot)` 解析：
1. **路徑正規化 (Canonicalization)**：使用 `path.canonicalize` 或 `File(p).resolveSymbolicLinksSync()` 解析所有相对路徑與 `..` 上級符號。
2. **Sandbox Root 強制邊界**：正規化後的絕對路徑必須以 `workspaceRoot` 為字首開頭，否則拋出 `SecurityException: Path out of workspace boundary`。
3. **高風險檔案過濾**：禁止寫入或建立具有危險副檔名的檔案：`.exe`, `.apk`, `.bat`, `.sh`, `.dll`, `.so`, `.cmd`, `.ps1`, `.vbs`。
4. **讀寫容量限制**：
   - 讀取單一檔案最大上限：`1 MB` (1,048,576 bytes)，超出時擷取前 1MB 並附加截斷警告。
   - 寫入單一檔案最大上限：`512 KB` (524,288 bytes)。

### 2. 10 個 Tools 完整定義 (JSON Schema Spec)

```json
[
  {
    "name": "file_read",
    "description": "Read text content from a file within the current workspace.",
    "parameters": {
      "type": "object",
      "properties": {
        "path": { "type": "string", "description": "Relative file path inside workspace (e.g. 'notes.txt' or 'src/main.py')" }
      },
      "required": ["path"]
    }
  },
  {
    "name": "file_write",
    "description": "Write or overwrite text content to a file in the workspace.",
    "parameters": {
      "type": "object",
      "properties": {
        "path": { "type": "string", "description": "Relative target file path." },
        "content": { "type": "string", "description": "Text content to write." }
      },
      "required": ["path", "content"]
    }
  },
  {
    "name": "file_append",
    "description": "Append text content to an existing file in the workspace.",
    "parameters": {
      "type": "object",
      "properties": {
        "path": { "type": "string", "description": "Relative target file path." },
        "content": { "type": "string", "description": "Text content to append." }
      },
      "required": ["path", "content"]
    }
  },
  {
    "name": "file_delete",
    "description": "Delete a file or empty directory in the workspace.",
    "parameters": {
      "type": "object",
      "properties": {
        "path": { "type": "string", "description": "Relative path to delete." }
      },
      "required": ["path"]
    }
  },
  {
    "name": "file_list",
    "description": "List files and subdirectories in a workspace directory.",
    "parameters": {
      "type": "object",
      "properties": {
        "path": { "type": "string", "description": "Relative directory path (optional, defaults to workspace root '')." }
      }
    }
  },
  {
    "name": "file_mkdir",
    "description": "Create a new directory (and parent directories if missing) in the workspace.",
    "parameters": {
      "type": "object",
      "properties": {
        "path": { "type": "string", "description": "Relative directory path to create." }
      },
      "required": ["path"]
    }
  },
  {
    "name": "file_info",
    "description": "Get metadata of a file or directory (size, modified time, type).",
    "parameters": {
      "type": "object",
      "properties": {
        "path": { "type": "string", "description": "Relative path to query." }
      },
      "required": ["path"]
    }
  },
  {
    "name": "file_move",
    "description": "Move or rename a file/directory inside the workspace.",
    "parameters": {
      "type": "object",
      "properties": {
        "source": { "type": "string", "description": "Source relative path." },
        "destination": { "type": "string", "description": "Destination relative path." }
      },
      "required": ["source", "destination"]
    }
  },
  {
    "name": "file_copy",
    "description": "Copy a file from source to destination inside the workspace.",
    "parameters": {
      "type": "object",
      "properties": {
        "source": { "type": "string", "description": "Source relative path." },
        "destination": { "type": "string", "description": "Destination relative path." }
      },
      "required": ["source", "destination"]
    }
  },
  {
    "name": "file_search",
    "description": "Search for files matching a wildcard or substring pattern within the workspace.",
    "parameters": {
      "type": "object",
      "properties": {
        "pattern": { "type": "string", "description": "Search pattern or string (e.g. '*.py' or 'config')." },
        "path": { "type": "string", "description": "Subdirectory to start searching from (optional)." }
      },
      "required": ["pattern"]
    }
  }
]
```

---

## 三、資料結構與持久化 (Data Models & Persistence)

### 1. Workspace 狀態儲存
- **Hive Box**: `conversation_workspaces_v1`
- **Key**: `conversationId` (`String`)
- **Value**: `workspacePath` (`String`)

### 2. Message 檔案記錄模型 (FileRecord)
每當 `file_write`, `file_append`, `file_copy`, `file_move` 成功觸發時，系統必須建立並儲存 `FileRecord`。

```dart
// Location: lib/core/models/file_record.dart (or embedded in chat_service.dart)
class FileRecord {
  final String path;        // 檔案絕對路徑
  final String fileName;    // 檔名 (e.g. "main.py")
  final int sizeBytes;      // 檔案位元組大小
  final DateTime createdAt; // 建立/修改時間

  Map<String, dynamic> toJson() => {
    'path': path,
    'fileName': fileName,
    'sizeBytes': sizeBytes,
    'createdAt': createdAt.toIso8601String(),
  };

  factory FileRecord.fromJson(Map<String, dynamic> json) => FileRecord(
    path: json['path'] as String,
    fileName: json['fileName'] as String,
    sizeBytes: json['sizeBytes'] as int,
    createdAt: DateTime.parse(json['createdAt'] as String),
  );
}
```

- **Hive Box**: `message_file_records_v1`
- **Key**: `messageId` (`String` - 對應 Assistant 訊息的 ID)
- **Value**: `List<Map<String, dynamic>>` (序列化後的 FileRecord 陣列)

---

## 四、UI/UX 佈局與元件規範 (UI Specs)

### 1. Top Bar 按鈕配置變更
- **移除**: Top Bar 的 Voice Chat 按鈕 (`CupertinoIcons.waveform_circle`)。
- **新增**: 「工作區」按鈕，使用 `Lucide.FolderCode` 圖示（帶 `<>` 的資料夾，與側邊欄專案 Icon `Lucide.Folder` 區隔）。
- **按鈕順序**:
  - **Desktop** (`home_desktop_layout.dart`): `[MiniMap 🗺️]` -> `[Workspace 📂]` -> `[PanelRight]` -> `[NewChat ✉️]`
  - **Mobile** (`home_mobile_layout.dart`): `[MiniMap 🗺️]` -> `[Workspace 📂]` -> `[NewChat ✉️]`

### 2. Input Bar 按鈕配置變更 (`chat_input_bar.dart`)
- **搬移**: Voice Call 按鈕從 Top Bar 搬移至底部對話框按鈕區段。
- **位置**: 置於 `Instruction Injection` (系統提示注入) 之後、`Context Management` (上下文管理) 之前。
- **順序**: `[Model]` -> `[Search]` -> `[MCP]` -> `[Reasoning]` -> `[AiTeam]` -> `[Instruction]` -> `[VoiceChat 🎙️]` -> `[ContextMgmt]` -> `[MiniMap]` -> `[OCR]`

### 3. 工作區選單 (WorkspaceSheet)
點擊「工作區」按鈕彈出選單（Desktop: Popover / Mobile: Bottom Sheet），包含 5 個功能區塊：
1. **目前工作區路徑**：顯示絕對路徑（若未設定則顯示「未設定 (使用預設目錄)」）。
2. **📁 選擇資料夾**：觸發 `FilePicker.platform.getDirectoryPath()`。Android 上若未取得權限則引導請求 `Permission.manageExternalStorage`。
3. **🏠 使用預設目錄**：重置為 `AppDirectories.getFileSandboxDirectory()`。
4. **🗑️ 清除工作區**：刪除對話在 Hive 中的 workspaceBinding，重置為預設。
5. **📄 檔案**：點擊開啟 `WorkspaceFileBrowser`，展示當前工作區內容。

### 4. 訊息卡片佈局與點擊選單 (Message File Cards)
- **位置**: 渲染於 Assistant 訊息的主體 Markdown 內容最下方 (`_buildAssistantBubbleContainer` 之後)。
- **樣式**: `IosCardPress` 圓角卡片，顯示檔案類型 Icon、檔名、檔案大小。
- **點擊行為**: 彈出選單（`DesktopAnchoredMenu` 或 Bottom Sheet），提供三個動作：
  1. 📂 **Show in folder**：
     - **Windows**: `Process.run('explorer', ['/select,', filePath.replaceAll('/', '\\')])`
     - **macOS**: `Process.run('open', ['-R', filePath])`
     - **Android**: 開啟 `WorkspaceFileBrowser` 並定位至該檔案目錄。
  2. 🔗 **Open externally**：
     - 執行 `OpenFilex.open(filePath)`，利用系統廣播開啟。
  3. 💾 **Download**：
     - **Desktop**: 調用 `FilePicker.platform.saveFile()` 另存新檔。
     - **Mobile**: 調用 `Share.shareXFiles([XFile(filePath)])` 分享/儲存。

---

## 五、受影響檔案清單與變更細節 (15 Target Files)

### 1. [MODIFY] `android/app/src/main/AndroidManifest.xml`
- **目的**: 加入全檔案存取權限。
```xml
<uses-permission android:name="android.permission.MANAGE_EXTERNAL_STORAGE" />
```

### 2. [MODIFY] `lib/icons/lucide_adapter.dart`
- **目的**: 匯出工作區 Icon 與選單所需的 Lucide 圖示。
```dart
static const IconData FolderCode = lucide.LucideIcons.folderCode;
static const IconData ExternalLink = lucide.LucideIcons.externalLink;
```

### 3. [MODIFY] `lib/utils/app_directories.dart`
- **目的**: 建立全域預設 Sandbox 目錄。
```dart
static Future<Directory> getFileSandboxDirectory() async {
  final root = await getAppDataDirectory();
  final dir = Directory('${root.path}/files');
  if (!dir.existsSync()) {
    dir.createSync(recursive: true);
  }
  return dir;
}
```

### 4. [NEW] `lib/core/services/file/file_tool_service.dart`
- **目的**: 實作 10 個 File Tools 邏輯與安全檢查。
- **核心方法**:
  - `static List<Map<String, dynamic>> getToolDefinitions()`
  - `static Future<FileToolResult> execute(String toolName, Map<String, dynamic> args, String? workspacePath)`
  - `static String? _resolveSafePath(String relativePath, String workspaceRoot)`

```dart
class FileToolResult {
  final String text;
  final String? createdOrModifiedFilePath;
  final String? fileName;
  final int? fileSizeBytes;

  FileToolResult({
    required this.text,
    this.createdOrModifiedFilePath,
    this.fileName,
    this.fileSizeBytes,
  });
}
```

### 5. [NEW] `lib/features/chat/widgets/workspace_sheet.dart`
- **目的**: 「工作區」按鈕彈出視窗，包含資料夾選擇與 Android 權限處理。

### 6. [NEW] `lib/features/chat/widgets/workspace_file_browser.dart`
- **目的**: 工作目錄檔案瀏覽器頁面/彈窗，列出資料夾中的檔案與目錄，並可點擊直接開啟。

### 7. [MODIFY] `lib/core/services/chat/chat_service.dart`
- **目的**: 持久化 WorkspaceBinding 與 Per-message FileRecords。
```dart
// Workspace Hive Box
String? getConversationWorkspace(String conversationId);
Future<void> setConversationWorkspace(String conversationId, String? path);

// Message File Records Hive Box
Future<void> addMessageFileRecord(String messageId, FileRecord record);
List<FileRecord> getMessageFileRecords(String messageId);
```

### 8. [MODIFY] `lib/features/home/services/tool_handler_service.dart`
- **目的**: 將 File tools 接入 JSON Schema 生成與 Tool Call 分發迴圈。
```dart
// 1. 在 buildToolDefinitions 中加入 FileToolService.getToolDefinitions()
// 2. 在 buildToolCallHandler 中攔截 name.startsWith('file_')
if (name.startsWith('file_')) {
  final workspace = chatService.getConversationWorkspace(conversationId);
  final result = await FileToolService.execute(name, args, workspace);
  if (result.createdOrModifiedFilePath != null && messageId != null) {
    await chatService.addMessageFileRecord(
      messageId,
      FileRecord(
        path: result.createdOrModifiedFilePath!,
        fileName: result.fileName ?? path.basename(result.createdOrModifiedFilePath!),
        sizeBytes: result.fileSizeBytes ?? 0,
        createdAt: DateTime.now(),
      ),
    );
  }
  return result.text;
}
```

### 9. [MODIFY] `lib/core/services/chat/prompt_transformer.dart`
- **目的**: 將當前對話的 Workspace Context 寫入 System Prompt。
```dart
if (workspacePath != null) {
  systemPrompt += '\n\n[File Workspace]\n'
    'You have file operation tools operating in: $workspacePath\n'
    'Use relative paths for all operations. Available tools: file_read, file_write, '
    'file_append, file_delete, file_list, file_mkdir, file_info, file_move, file_copy, file_search';
}
```

### 10. [MODIFY] `lib/features/home/pages/home_desktop_layout.dart`
- **目的**: Top Bar 清除 VoiceChat 按鈕，加入 Workspace 按鈕 (`Lucide.FolderCode`)。

### 11. [MODIFY] `lib/features/home/pages/home_mobile_layout.dart`
- **目的**: Top Bar 清除 VoiceChat 按鈕，加入 Workspace 按鈕 (`Lucide.FolderCode`)。

### 12. [MODIFY] `lib/features/home/pages/home_page.dart`
- **目的**: 串接 `onOpenWorkspace` 觸發 `showWorkspaceSheet`；將 `onVoiceChat` 傳入 Input Section。

### 13. [MODIFY] `lib/features/home/widgets/chat_input_section.dart`
- **目的**: 接收 `onVoiceChat` 並透傳給 `ChatInputBar`。

### 14. [MODIFY] `lib/features/home/widgets/chat_input_bar.dart`
- **目的**: 接受 `onVoiceChat` 參數，置於 `Instruction Injection` 與 `Context Management` 之間。

### 15. [MODIFY] `lib/features/chat/widgets/chat_message_widget.dart`
- **目的**: 在 Assistant 訊息 Bubble 底部讀取 `chatService.getMessageFileRecords(message.id)`，若不為空則渲染 `_FileCardsSection`，並實作彈出選單 (Show in folder, Open externally, Download)。

---

## 六、驗證與測試計畫 (Verification Plan)

### 1. 單元測試 (Unit Tests)
新增 `test/file_tool_service_test.dart`:
- 測試 `_resolveSafePath`: 防範 `../` traversal, 絕對路徑跳脫, 符號連結跳脫。
- 測試 10 個 tools 的 CRUD 功能：
  - `file_write` 寫入文字與容量限制 (超出 512KB 拒絕)。
  - `file_read` 讀取文字與容量限制 (超出 1MB 截斷)。
  - `file_move`, `file_copy`, `file_delete`, `file_search` 邏輯正確性。

### 2. 手動測試矩陣 (Manual E2E Matrix)
1. **Windows 平台**:
   - 點擊 Top Bar `Lucide.FolderCode` 工作區按鈕，選擇任意本機資料夾。
   - 要求 LLM 建立 Python/Markdown 檔案 -> 驗證工具調用成功。
   - 檢視訊息下方出現檔案卡片，點擊彈出選單 -> 點擊 "Show in folder" 驗證開啓 Explorer 並高亮該檔案。
2. **Android 平台**:
   - 點擊工作區按鈕 -> 驗證觸發全檔案存取權限引導。
   - 選擇 Shared Storage / SD Card 資料夾 -> 驗證 LLM 可順利寫入/讀取。
   - 點擊檔案卡片 "Download" -> 驗證正確觸發系統原生分享/儲存 Intent。
3. **安全邊界測試**:
   - 指示 LLM `file_read` 讀取 `../../../../Windows/System32/drivers/etc/hosts` -> 驗證遭受 `SecurityException` 攔截並傳回邊界錯誤提示。
