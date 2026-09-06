# OmniChat CLI 工具整合計畫 — Windows + Android (proot) v4

> 讓 OmniChat 的 LLM 具備在 Workspace 內執行 Shell 指令的能力。Windows 使用原生 `dart:io` Process，Android 使用 proot 提供 Linux 環境。
> 
> 核心決策：Windows 採用完整 CLI 工具整合；Android 只提供前景單次 `shell_exec`。
> 
> 日期：2026-08-05（v4，基於 v3 之 2026-08-04 版本修訂）

---

## 一、架構決策與背景

### 1. 為什麼採用 Direct Function Call

與 File Tools 一致，CLI Tools 是核心內建能力，需要：

- 共用 workspace 路徑（從 `WorkspaceResolver` 取得）
- 相同的 enabled/disabled 控制邏輯
- 相同的 `ToolHandlerService` 分派機制（`name.startsWith('shell_')`）

### 2. 平台策略

| 平台      | CLI 能力                                        | 執行環境                    | 背景工作         | 評估   |
| ------- | --------------------------------------------- | ----------------------- | ------------ | ---- |
| Windows | 完整方案：foreground、script、background、status、stop | 原生 Windows process      | 支援，限 Windows | 高可行  |
| Android | 僅 `shell_exec`                                | PRoot + Alpine userland | 不支援          | 中高可行 |

### 3. 不採用的範圍

- Android 不實作 `shell_exec_background`。
- Android 不實作 `shell_script` 專用工具。
- Android 不提供 background job registry、job recovery 或 daemon 保證。
- 本版本不支援 SAF `content://` URI 作為 CLI workspace。
- 不預裝完整 Python、Pandoc、Git、ImageMagick 等 CLI 套件。
- 不宣稱 Shell commands 只能存取 workspace。

---

## 二、目前程式碼基礎

### 1. 現有 Workspace 行為

目前 Workspace 已完成以下功能（2026-08-05 驗證）：

- 全域 default、project workspace、conversation override。
- `WorkspaceResolver` 在 generation preparation 時解析 effective workspace，回傳 `WorkspaceResolution`（`source`、`path`，`enabled` 為 derived getter）。
- File Tools 使用 Direct Function Call，不經 MCP。
- 目前有 13 個 workspace tools：`file_read`、`file_write`、`file_append`、`file_edit`、`file_patch`、`file_delete`、`file_list`、`file_mkdir`、`file_info`、`file_move`、`file_copy`、`file_search`、`file_extract_text`。
- File Tools 與 File Browser 共用 `resolveSafePath()` 的 traversal、symlink 與 workspace boundary 檢查。
- FileRecord、tool events（`tool_events_v1` box）、backup（version 3，含 `workspaceBindings`）、fork 與 compress-context 已有持久化整合。
- Android 與 Windows 都使用 Dart `dart:io` 操作實體 filesystem path。

### 2. 已驗證基線

目前 generation 流程已將同一個 workspace path 傳給：

- system prompt builder（`message_builder_service.dart`：`You have file operation tools operating in: <path>`）；
- tool definitions builder（`ToolHandlerService.buildToolCallDefinitions`）；
- tool call handler（`ToolHandlerService.buildToolCallHandler` 的 `name.startsWith('file_')` branch）。

與 Shell 整合直接相關的既有約束：

- `ChatApiService._truncateToolResultText()` 對歷史 tool result 有 **32,768 字元**截斷門檻（head+tail 保留），應用於所有 follow-up request（OpenAI / Claude / Google 格式）。`FileToolService` 的 read/extract cap（16 KiB 預設 / 24 KiB hard cap）即為此預算設計。**Shell result cap 必須服從同一預算**（見五.3）。
- v1.5.17+ 的 `_withFetchQueue()`（2 併發 FIFO）是既有併發控制慣例，Shell foreground 排隊沿用同一模式。

### 3. 與 CLI 整合相關的現有限制

- `WorkspaceResolution` 目前提供 `source`、`path` 與 `enabled`，尚無 CLI capability 或 guest path。
- system prompt 目前只說明 File Tools 與 `file_extract_text`，沒有 Shell capability、平台、shell dialect 或 non-sandbox 警告。
- `ToolHandlerService` 目前處理 `file_*`、search、memory 與 MCP tools；`file_*` branch 已有 try/catch exception isolation（v1.6.9+ #155），`shell_*` branch 必須沿用同等保護。
- File Tools 封鎖 `.apk/.bat/.cmd/.dll/.exe/.ps1/.sh/.so/.vbs` 副檔名；Shell 啟用後，命令本身仍能建立或操作這些檔案。
- Android Manifest 已宣告 `MANAGE_EXTERNAL_STORAGE`（另有 `READ_EXTERNAL_STORAGE` maxSdkVersion 32），folder picker 會嘗試請求該權限。
- `requestLegacyExternalStorage` 不應被視為 Android 11+ 一般文件存取的替代方案。
- Backup 格式目前為 version 3；任何新持久化區段需升版並保持向後相容。
- AI Team（v1.5.23，MoA/CMoA）的 proposer/critic/aggregator 繼承目前 toolbar 的 `toolDefs` 與 `onToolCall`——Shell 啟用後這些 slot 也會取得 shell tools。

---

## 三、產品能力契約

### 1. Tool availability

CLI tools 只有在以下條件全部成立時才加入 model tool definitions：

1. 模型支援 function calling（`supportsTools`）。
2. Effective workspace 已啟用。
3. Shell capability 已由使用者明確啟用。
4. 對應平台 backend 已 ready（`ShellStatus.ready`）。
5. Android workspace 通過 host path probe。

Workspace enabled 不等於 Shell enabled。Shell 預設關閉，且 project/conversation 必須有獨立設定。

### 2. Shell capability model

新增 typed `ShellConfig`（獨立 model 檔 `lib/core/models/shell_config.dart`，序列化模式對齊 `WorkspaceConfig`），至少支援：

- `inherit_project`：conversation 沿用 project shell 設定。
- `disabled`：明確關閉 Shell。
- `enabled`：明確開啟 Shell。

Project 預設為 `disabled`。新 conversation 預設繼承 project，但不應因為 workspace 已啟用而自動開啟 Shell。

Shell runtime 另有獨立狀態，不把「設定已開啟」誤當成「目前可執行」：

- `disabled`：使用者未開啟 Shell。
- `installing`：Windows runtime probe 或 Android rootfs/bootstrap 正在執行。
- `ready`：backend 與 workspace probe 都成功。
- `broken`：初始化、權限、binary 或 rootfs 驗證失敗。

### 3. Tool approval

Shell capability 是第一層總開關，tool approval 是第二層逐次授權：

- 每個 shell tool 有一個 per-tool policy：`ask`（預設，逐次確認）、`allow`（免確認）、`deny`（拒絕）。
- 預設值：`shell_exec`、`shell_script`、`shell_exec_background`、`shell_job_stop` 為 `ask`；`shell_job_status` 為 `allow`（但仍必須驗證 job id）。
- `ask` 的 runtime 行為：tool handler 暫停該次 tool call，在 UI 彈出錨定於 tool card 的確認對話框（命令全文、workspace、shell dialect）；使用者核准才啟動 process；對話框逾時（建議 5 分鐘）未回應時回傳 approval-required 錯誤結果，不啟動 process。
- 確認對話框提供「本次允許」與「永遠允許此工具」；後者寫入 per-tool override 並持久化。
- policy 以 tool name 保存，不以 UI 順序或顯示文字保存；使用者可在 project/workspace 設定覆寫，但不能繞過 disabled 或 backend not ready 狀態。
- AI Team slot（proposer/critic/aggregator）的 shell call 使用同一份 approval snapshot 與 per-tool policy；serial 執行保證不會同時彈出多個確認對話框。

這個設計參考 RikkaHub 的逐工具 approval；Shell 不應只依賴 workspace enabled 作為授權。

### 4. Windows tools

Windows 完整方案提供：

| Tool                    | 行為                                           |
| ----------------------- | -------------------------------------------- |
| `shell_exec`            | 執行單次命令並等待完成                                  |
| `shell_script`          | 執行一次性多行 script，使用 app-private temporary file |
| `shell_exec_background` | 啟動 Windows background job，回傳不可猜測的 `job_id`   |
| `shell_job_status`      | 查詢 job 狀態、exit code、輸出摘要與 process 資訊         |
| `shell_job_stop`        | 停止 job 及其 process tree                       |

`shell_job_status` 與 `shell_job_stop` 是 background tool 的必要管理介面，不只回傳 OS PID。

### 5. Android tools

Android 只提供：

| Tool         | 行為                  |
| ------------ | ------------------- |
| `shell_exec` | 以 PRoot 執行一次命令並等待完成 |

Android 不加入 `shell_script`、`shell_exec_background`、`shell_job_status` 或 `shell_job_stop` definitions。多步驟工作由 command chaining、`file_write` 建立 Python/文字腳本，再呼叫 `shell_exec` 完成。

這不代表 `shell_script` 完全沒有價值：現有 File Tools 封鎖 shell script 副檔名，因此 Android 只承諾常見 Python、文字腳本與 inline shell command workflow，不宣稱與專用 `shell_script` 完全等價。

所有 foreground Shell tools 的共同參數：

- `command`：要執行的 command，必填。
- `cwd`：相對於 workspace root 的子目錄，預設為 workspace root；禁止使用 host absolute path 或 `..` 跳出 workspace。
- `timeout`：秒數，依平台與 tool type clamp 到計畫上限。

Windows 專屬參數：

- `shell`：`cmd` | `powershell`，預設 `cmd`。只允許列舉值，不接受任意 shell path 或 command 字串內自行切換。

Android 無 `shell` 參數（固定 guest `/bin/sh`）。

Android command 在 guest 內使用 `/workspace` 與相對 `cwd`；Windows command 使用 captured physical workspace 作為 working directory。

---

## 四、目標架構

```text
WorkspaceResolver
        |
        v
EffectiveWorkspace
{ physicalPath, enabled, source }
        |
        v
ShellCapabilityResolver
{ enabled, platform, backendReady, guestPath }
        |
        v
GenerationExecutionContext
{ workspace, shell capability, captured generation state }
        |
        +--------------------------+
        |                          |
        v                          v
FileToolService              CliToolService
dart:io local path            shared request/result contract
                                    |
                  +-----------------+-----------------+
                  |                                   |
                  v                                   v
           WindowsCliBackend                  AndroidProotBackend
           native process                     PRoot + Alpine
           Job Object (FFI)                   foreground only
```

### 1. Shared abstractions

新增共用模型：

- `CliExecutionRequest`：command、shell dialect、timeout、workspace、environment policy。
- `CliExecutionResult`：exit code、stdout、stderr、timed out、truncated、duration、backend。
- `CliBackend`：foreground execute、background start、status、stop、readiness probe。
- `CliCapability`：platform、available tools、backend status、workspace mapping。
- `ShellStatus`：disabled、installing、ready、broken。
- `WorkspaceMountTable`：統一保存 host source、guest target、可寫入範圍與用途。
- `CliProcessSupervisor`：啟動 process、建立 output collectors、timeout、cancel 與 process-tree termination。
- `WorkspacePathProbe`：確認 workspace 是 directory、可讀、可列舉、可建立與刪除 probe file。

### 2. Generation snapshot

每次 generation preparation（含 `sendMessage`、`regenerateAtMessage` 與 AI Team generation）必須一次捕獲：

- effective physical workspace path；
- workspace enabled 狀態；
- shell enabled 狀態與 shell dialect（Windows `cmd`/`powershell` 預設）；
- platform backend；
- Android guest path `/workspace`；
- conversation/project 的相對 `cwd`；
- generation 使用的 `WorkspaceMountTable` snapshot；
- tool approval snapshot（per-tool policy 值）；
- 該 generation 可用的 tool definitions。

generation 開始後，UI 改變 workspace 或 Shell 設定不應修改已建立的 handler。File Tools 與 Shell Tools 必須使用同一份 snapshot。

Compress Context 建立新 conversation 時，除複製 workspace binding（既有行為）外，也必須複製 conversation 層級 shell override。

### 3. Tool handler integration

`ToolHandlerService` 應將 Shell branch 與 File branch 分離：

- `file_*` 交給 `FileToolService`。
- `shell_*` 交給 `CliToolService`。
- disabled 或不支援的 stray call 回傳明確錯誤，不應讓 stream generator throw。
- tool approval 被拒絕（`deny` 或 `ask` 逾時未核准）時回傳可供模型理解的 approval-required result，不啟動 process。
- 所有 CLI exception 都轉成 tool result，並寫入受限 log（沿用 `[file-tool]` 的 FlutterLogger 模式，tag `shell-tool`），不中斷對話。
- FileRecord persistence 級別的 Hive 失敗必須與 tool result 分離（沿用 v1.6.9+ #155 的雙層 try/catch 模式）。

---

## 五、Shell 共用執行規則

### 1. Process start

- 使用 `Process.start()`，不要用不可控的 `Process.run().timeout()`。
- 啟動 process 後要立即建立 stdout/stderr collectors，再開始等待 process；不能等 process 結束後才讀 output。
- stdout/stderr 必須即時串流 drain。
- output 超過上限時仍持續讀取並丟棄多餘資料，避免 pipe deadlock。
- timeout 必須終止 process tree，不只是讓 Dart Future timeout。
- cancellation 必須終止目前 process 與其子程序，不能把取消例外吞掉後讓 command 繼續執行。
- executable 使用明確或已驗證的絕對 path。
- command 只作為明確的任意命令能力，不把 denylist 描述成 security sandbox。
- foreground 併發：每個 generation 最多 1 個同時 foreground 執行（FIFO 排隊，Completer-based，沿用 `_withFetchQueue()` 慣例）；background jobs 另計。

### 2. Process supervisor contract

`CliProcessSupervisor` 應統一處理 Windows 與 Android 的共同生命週期：

- `start`：建立 process、記錄 process handle、啟動 collectors。
- `awaitResult`：等待正常 exit、timeout 或 cancellation。
- `cancel`：先使用平台 backend 的 tree-kill，再回收 stdin/stdout/stderr。
- `collectOutput`：達到 cap 後繼續 drain，但只保留 cap 內資料並設置 `truncated=true`。
- `cleanup`：關閉 streams、刪除 temporary files、釋放 Job Object/PRoot handles。

Android PRoot 要使用 `--kill-on-exit`，確保 PRoot 結束時 guest child 不繼續殘留。Windows 要使用 Job Object；兩者都不能只依賴父 process 的單獨 kill。

Shell command 應以獨立 argument 傳入 guest shell，不把未處理的 command 字串直接拼接進 host process command line。Android 可採用 `/bin/sh -c <command>`；若 rootfs 有 Bash，才使用 login Bash 和 positional arguments 傳遞 cwd/command。

### 3. Output policy

所有 result 的序列化總長（stdout + stderr + metadata）必須 ≤ **32,768 字元**，以符合 `ChatApiService` 的 tool-result 預算，避免歷史截斷與 UI cap 雙重语义不一致。

Foreground `shell_exec`：

- stdout hard cap：**24 KB**。
- stderr hard cap：**6 KB**。
- 預設 timeout：30 秒。
- timeout 上限：120 秒。
- result 必須帶 exit code、timeout、truncated 與 duration。

Windows `shell_script`：

- 預設 timeout：60 秒。
- timeout 上限：300 秒。
- stdout/stderr cap 與 `shell_exec` 相同（24 KB / 6 KB），除非測試證明需要獨立上限。

Background job：

- stdout/stderr 只能保存有限 ring buffer（建議各 16 KB）。
- `shell_job_status` 單次回傳結果仍須符合 32,768 字元預算。
- job registry 只保存 metadata 與受限輸出，不保存無限長 log。
- app-wide 同時最多 2 個 active jobs。

### 4. Environment policy

- `includeParentEnvironment: false`。
- 明確 allowlist `SystemRoot`、`ComSpec`、`TEMP`、`TMP`、必要的 `PATH` 與 shell runtime variables。
- 外部 CLI 的安裝路徑由已知目錄或使用者設定加入，不直接無條件繼承完整 parent environment。
- 不將 API keys、provider secrets 或整個 parent environment 暴露給 child process。
- Windows `PATH` 必須包含已驗證的 system、user CLI 與 app-managed runtime 目錄。

### 5. Output encoding policy

Windows console 預設使用 OEM codepage（zh-TW 系統為 cp950，非 UTF-8），直接解碼會產生亂碼；PowerShell 5.1 部分輸出可能是 UTF-16。策略：

- `cmd`：命令前綴 `chcp 65001 >nul &`，強制 UTF-8 console output。
- `powershell`：命令前綴 `[Console]::OutputEncoding=[Text.Encoding]::UTF8; $OutputEncoding=[Text.Encoding]::UTF8;`。
- Dart 端以 UTF-8 `allowMalformed: true` 解碼 stdout/stderr，解碼失敗字元以替換字元呈現，不 throw。
- Android guest（Alpine）預設 UTF-8（由 rootfs patcher 設定 `LANG=C.UTF-8`），同一解碼策略。
- 編碼行為必須有專屬測試（CJK 輸出、cp950 系統、PowerShell UTF-16 路徑）。

---

## 六、Windows 完整 CLI Backend

### 1. Foreground execution

預設使用：

```text
cmd.exe /d /s /c "chcp 65001 >nul & <command>"
workingDirectory = effectiveWorkspacePath
runInShell = false
includeParentEnvironment = false
```

PowerShell 必須透過 tool 的 `shell` 參數明確選擇，不允許 command 字串自行切換 shell：

```text
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "[Console]::OutputEncoding=[Text.Encoding]::UTF8; <command>"
```

`-ExecutionPolicy Bypass` 必要：Windows PowerShell 5.1 預設 Restricted policy 會拒絕執行 script。Shell 選項為 `cmd` 與 `powershell` 兩個列舉值。每個 shell 都必須有獨立 quoting、encoding 與 timeout 測試。

### 2. Process tree termination

Windows 優先使用 native Job Object，以**純 Dart FFI** 實作（專案將 `win32` 與 `ffi` 改為直接相依；目前兩者存在於相依圖但為間接相依）：

- `CreateJobObjectW` + `SetInformationJobObject`（`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`）；
- process 建立後立即 `AssignProcessToJobObject`；
- timeout、cancel、`shell_job_stop` 時 `TerminateJobObject` 終止整個 job；
- 使用 process handle 與 job handle，不依賴 PID 作為唯一識別；
- 可設定 job memory、process count 與 CPU policy；
- `taskkill /T` 只作無法使用 native wrapper 時的 fallback。

只呼叫 Dart `Process.kill()` 不符合完成條件，因為 `cmd.exe` 可能已建立無法被單獨終止的子程序。FFI 方案不需要修改 `windows/runner`；若 FFI 路徑在實作中不可行，才退回 native runner/plugin。

### 3. `shell_script`

- script 放在 app-private temporary directory，不寫入使用者 workspace。
- 檔名使用 random token，避免碰撞與 path injection。
- script 結束、timeout、exception、app cancellation 都必須清除。
- cmd script 以 `cmd.exe /d /s /c "<temp path>"` 執行；PowerShell script 以 `powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "<temp path>"` 執行。
- script encoding（UTF-8，PowerShell 需注意無 BOM 時的解碼行為）、CRLF、`cmd.exe` quoting 必須有測試。
- 若 script 需要輸出 workspace 檔案，working directory 仍設定為 captured workspace。

### 4. Background jobs

`shell_exec_background` 回傳：

- `job_id`：隨機且不可猜測。
- backend。
- command 摘要。
- start time。
- initial state。

job state：

- `starting`
- `running`
- `exited`
- `failed`
- `killed`
- `lost`

背景工作的語意是「app 仍存活時可在 UI 外繼續執行」，不是永久 daemon 保證。app 被關閉、OS 終止或 process handle 不可恢復時，job 標記為 `lost` 或 `killed`，不得假裝仍然可管理。Job Object handle 不應設定在 app 結束時主動 terminate 以外之限制——app process 結束時 job handle 關閉，`KILL_ON_JOB_CLOSE` 會清理殘餘 child，這是可接受的行為。

job registry 必須保存：

- job id；
- process/job metadata；
- command 摘要；
- workspace path snapshot；
- start、finish、timeout、exit state；
- 受限 stdout/stderr preview。

不應把 PID 當作跨 app restart 的可靠控制憑證。

---

## 七、Android PRoot Backend

### 1. 支援範圍

Android backend 只負責 foreground `shell_exec`：

```text
host workspace path
        |
        v
PRoot --rootfs <rootfs>
      --bind <workspacePath>:/workspace
      --cwd /workspace
      --kill-on-exit
      /bin/sh -c <command>
```

`/workspace` 是 guest path。File Tools 使用 host physical path，Shell 使用 `/workspace`，兩者必須映射到同一個實體目錄。

### 2. Runtime layout

使用現有 async API：

```dart
final appData = await AppDirectories.getAppDataDirectory();
final runtimeRoot = Directory('${appData.path}/cli_runtime');
```

建立以下目錄：

- `cli_runtime/bin/`
- `cli_runtime/rootfs/<version>/`
- `cli_runtime/tmp/`
- `cli_runtime/cache/`
- `cli_runtime/locks/`
- `cli_runtime/metadata.json`

不使用計畫中不存在的 `getAppSupportPath()`。

### 3. PRoot binary

至少支援 `arm64-v8a`，採用 **jniLibs native library** 打包（對齊 RikkaHub 的 `libproot_exec.so` + loader 模式）：

- binary 放在 `android/app/src/main/jniLibs/arm64-v8a/libproot_exec.so`（必要時含 `libproot_loader.so`），**不使用 Flutter assets**——Android 10+（API 29+）assets 預設壓縮且無 exec 權限，無法直接執行。
- 執行策略二選一，擇一後固定：
  1. `android:extractNativeLibs="true"`：安裝時解壓到 `nativeLibraryDirectory`，該路徑 `.so` 可執行；或
  2. `.so` 在 APK 內 uncompressed 且 page-aligned（AGP packaging options `useLegacyPackaging = false` 時需確認 16 KB alignment 與 exec bit 行為），直接自 APK 執行。
- 啟動時 probe：解析實際 binary path、驗證可執行、記錄 hash 與版本 metadata。
- binary 必須是 Android-compatible build（bionic/linker 相容），不可直接假設一般 Linux `aarch64` binary 可執行。
- 真機驗證 `proot --version`、`echo`、`ls`、`cat`、`/bin/sh`。
- 若未來加入其他 ABI，必須提供對應 binary 或明確限制 APK ABI（目前 release APK 為 ARM64 v8a only，與現有發行一致）。
- PRoot GPL-2.0-or-later 的 license、source offer、修改紀錄與對應 source 必須隨 F-Droid 發行資料提供。

### 4. Rootfs bootstrap

- Alpine rootfs 有明確版本、ABI、hash 與來源 URL。
- F-Droid 版本預設使用 pinned、可追蹤來源的 rootfs asset（打包於 APK 或首次啟動下載，擇一後固定）；不接受 LLM 任意指定的 rootfs URL。
- 若未來提供手動 rootfs URL，必須是使用者明確操作、HTTPS、大小受限、來源可追蹤且 hash 驗證通過；不能由模型直接改變 runtime source。
- 支援 tar.gz 與 tar.xz 等已測試格式，格式由 pinned metadata 或副檔名判斷。
- 解壓前取得 lock，避免兩個 generation 同時初始化。
- 解壓到 temporary staging directory。
- 驗證必要檔案、symlink、executable mode 與 `/bin/sh` 後 atomic rename。
- partial extraction 下次啟動時可安全清理與重新解壓。
- rootfs、apk cache、staging 與 user-installed packages 都要有 disk quota。
- 啟動時顯示 bootstrap progress（本地化字串），不阻塞 Flutter UI。

Rootfs installer 應拆成可測試的階段：

1. `download`：connect/read timeout、大小上限、progress、取消。
2. `stage`：temporary directory、archive 解壓與 traversal 檢查。
3. `validate`：`/bin/sh`、必要 symlink、executable mode、ABI/version/hash。
4. `activate`：完成後才替換 active rootfs，失敗時保留舊版或回復到 disabled/broken。
5. `cleanup`：刪除 archive、staging、rootfs `/tmp`、`/var/tmp` 與 app temporary files。

### 5. Rootfs patching

Rootfs 啟用前執行可重複、可測試的 patcher，參考 RikkaHub 的 runtime 修補方式：

- 寫入可用的 DNS resolver 設定；
- 確保 `/etc/hosts`、localhost 與 hostname 合法；
- 設定 `LANG=C.UTF-8`（與五.5 編碼策略一致）；
- 建立 `/tmp`、`/var/tmp`、`/root` 並設定必要權限；
- 必要時加入 host supplementary group 對應，避免 bind mount 存取出現難以理解的權限錯誤；
- patch 必須只修改 rootfs staging 或 active rootfs 內允許的檔案，不可觸碰 host workspace。

這些是借鑑 runtime 行為，不直接複製 RikkaHub 程式碼。RikkaHub 是 AGPL-3.0 專案，任何程式碼重用都必須先完成 license compatibility review。

### 6. Mount table 與 bind policy

所有 bind mount 集中由 `WorkspaceMountTable` 管理，並同時提供給：

- PRoot command builder；
- File Tools 的 guest-to-host path resolver；
- system prompt 的可用路徑說明；
- runtime cleanup 與 probe。

每個 mount entry 至少包含：

- host source path；
- guest target path；
- read-only/read-write policy；
- 是否屬於 workspace、runtime 或 optional feature；
- 是否允許 File Tools 讀寫。

預設只 bind：

- rootfs；
- 已通過 host probe 的 workspace 到 `/workspace`；
- 經 Android 真機測試確實需要的 `/proc`、`/sys`、`/dev`。

不因方便而 bind 整個 `/storage/emulated/0`、`/data` 或其他 host tree。每一個額外 bind 都會增加 command 可見的 host 資源。

**Shared storage filesystem 限制**：external workspace 位於 `/storage/emulated/0`（FUSE/sdcardfs）時不支援 exec bit、symlink 與 POSIX permission。guest 可讀寫資料檔，但不能在該 workspace 內執行 script 或建立 symlink；prompt 與錯誤訊息必須說明此限制，probe 不需因此失敗（資料讀寫仍可用）。

### 7. Host path probe

在提供 Android Shell definitions 前確認：

1. path 是 directory。
2. app 可以列出目錄。
3. app 可以建立並刪除 random probe file。
4. path 不是 `content://` URI。
5. canonical path 與 workspace 設定一致。

probe 失敗時回傳清楚的 permission/path error，不把錯誤延後到 PRoot command 執行後才顯示。

### 8. Storage permission

本版本只發布 F-Droid，因此 Android 可以保留 direct-path shared storage：

- Manifest 保留 `MANAGE_EXTERNAL_STORAGE`。
- 使用者選擇外部 workspace 時才導向 Special app access。
- 從設定頁返回 app 後重新檢查 permission status。
- permission denied 時保留 app-private workspace 與 disabled 選項。
- 不把 permission denied 靜默轉成外部 workspace 成功。
- `requestLegacyExternalStorage` 不作為 Android 11+ 權限策略依據。
- `content://` SAF path 明確拒絕，不傳入 PRoot。

### 9. Android package installation

使用者或 LLM 可以透過 `shell_exec` 執行 `apk add` 或其他安裝命令，但產品不承諾所有套件都可用：

- 安裝受 120 秒 foreground timeout 限制；
- 大型 Python package、native compilation、重型資料分析套件可能失敗或超時；
- package cache 與 rootfs quota 必須可查看與清理；
- network、DNS、Alpine mirror 與 OEM 差異必須在真機驗證；
- 不提供 background install 或稍後自動完成的承諾。

---

## 八、安全與使用者授權

### 1. Non-sandbox contract

System prompt 必須明確說明：

```text
Commands start in the selected workspace. This is not a security sandbox.
Commands may access other paths visible to the application and to configured
PRoot bindings. Do not assume that the workspace boundary restricts shell
commands.
```

Windows prompt 應說明目前 shell 是 `cmd` 或 PowerShell。Android prompt 應說明 command 的 current directory 是 `/workspace`（shell 工具使用 guest path），且 external workspace 不支援執行 script（見七.6）。

system prompt 不應要求模型使用 Android host absolute path；host path 只保留在 app internal execution context。File Tools 仍使用 workspace-relative path。

### 2. Permission UI

新增獨立 Shell capability UI（所有字串需四語系本地化）：

- `Allow shell commands in this project`。
- `Allow shell commands in this conversation`。
- 顯示每個 Shell tool 的 approval policy（`ask` / `allow` / `deny`），至少包含 `shell_exec`、`shell_script`、background start、status、stop。
- 預設值見三.3；policy 覆寫以 tool name 保存，未覆寫的 tool 使用安全預設值。
- 顯示 Shell 是任意命令能力，不是 File Tools 的同等 sandbox。
- Android 顯示 PRoot readiness、workspace probe 與 external storage permission 狀態。
- Windows 顯示目前 shell backend、可用 runtime 與 background job 狀態。
- Shell runtime 顯示 `disabled`、`installing`、`ready`、`broken`，並提供可理解的錯誤與重試/重建入口。
- Shell 預設關閉。

### 3. Denylist

可建立 command denylist 以降低意外破壞，例如：

- fork bomb；
- Windows `format`、`diskpart` 等磁碟破壞命令；
- Android/Unix 的直接格式化與極端 recursive deletion；
- 明確造成無限 process 或無限輸出的命令。

Denylist 只是 accident guard，不是 security boundary。command 可透過 encoding、其他 binary、子程序或重導向繞過簡單字串比對，因此 prompt 與使用者明確授權仍是主要安全控制。

### 4. Secret handling

- 不繼承完整 parent environment。
- stdout、stderr 與 command metadata 都可能包含秘密，不應無限制保存。
- tool event 使用 cap、敏感值遮蔽與明確的 backup 行為。
- log 不保存完整 command secret 或完整輸出。
- 使用者停用 Shell 後，既有歷史仍可閱讀，但不可重新執行。

---

## 九、Persistence、UI 與 Backup

### 1. Tool events

沿用現有 `tool_events_v1` box（key = assistantMessageId），增加 Shell event 欄位：

- `kind: shell`；
- tool name；
- platform/backend；
- shell dialect；
- command preview；
- job id；
- start/finish time；
- exit code；
- timeout/killed/lost state；
- capped stdout/stderr preview（沿用現有 8 KB tool-event persistence cap 慣例）；
- truncated flag。

Shell command/result 的保存限制獨立於 File Tools 的 API safeguard，但 result 回傳給模型時仍受五.3 的 32,768 字元預算約束。

### 2. FileRecord

Shell 可能建立或修改任意檔案，不能安全地依賴 command result 自動建立 FileRecord。初版規則：

- File Tools 成功 mutation 維持現有 FileRecord 行為。
- Shell 產生的檔案不自動建立 FileRecord。
- 使用者可透過 File Browser 或後續 File Tools（含 `file_extract_text`）查看與操作。
- Shell result 只保存 command/result metadata。

### 3. Backup

Backup 格式版本由 **3 升至 4**（`data_sync.dart` `'version': 4`）；v3 備份必須仍可還原（向後相容，沿用 v2 → v3 的模式）。

Backup 可以保存：

- project/conversation shell capability config；
- per-tool approval policy 覆寫；
- captured `cwd` policy 與 mount table version，不保存未驗證的 host path 映射；
- Shell tool events 的受限 preview；
- job metadata 與終止狀態。

Backup 不保存：

- workspace 實體檔案；
- PRoot rootfs；
- apk cache；
- 未完成的 process 或 background job。

Restore 後：

- Windows 與 Android 的 command history 只作歷史記錄，不自動 replay；
- Android rootfs 由 bootstrap version/hash 重新準備；
- 不存在或無權限的 workspace 必須顯示 invalid/unavailable，不靜默改寫路徑。

Workspace path 本來就是平台相關的 absolute path，因此跨 Windows/Android restore 不保證可直接使用。

### 4. UI

Shell tool card 顯示（本地化）：

- command 與 shell dialect；
- running/completed/failed/timeout/killed/lost；
- exit code；
- stdout/stderr 可折疊區塊；
- output truncated 警告；
- background job id、status、stop action；
- `ask` policy 時的核准操作入口。

Android 不顯示 background job action。Bootstrap、permission、probe、disk quota 與 PRoot readiness 應可在 Workspace/Shell settings 查看。

---

## 十、資源與生命週期限制

| 項目                   | Windows foreground     | Windows script         | Windows background | Android `shell_exec` |
| -------------------- | ----------------------:| ----------------------:| ------------------:| --------------------:|
| 預設 timeout           | 30 秒                   | 60 秒                   | job policy         | 30 秒                 |
| hard timeout         | 120 秒                  | 300 秒                  | job policy         | 120 秒                |
| stdout result cap    | 24 KB                  | 24 KB                  | ring buffer 16 KB  | 24 KB                |
| stderr result cap    | 6 KB                   | 6 KB                   | ring buffer 16 KB  | 6 KB                 |
| concurrent execution | 每 generation 1 個（FIFO） | 每 generation 1 個（FIFO） | 最多 2 個             | 1 個                  |
| app restart recovery | 不保證                    | 不適用                    | `lost`/`killed`    | 不適用                  |

Android 執行若 app 進入背景，不能承諾 command 一定完成。若現有 Flutter foreground service 能維持 generation，仍需真機確認 PRoot child process 的實際存活行為；這不等同於支援 background jobs。

---

## 十一、受影響檔案

### 新增

1. `lib/core/models/shell_config.dart`（Shell capability mode 與 per-tool approval serialization，對齊 `WorkspaceConfig` 模式）
2. `lib/core/services/cli/cli_models.dart`
3. `lib/core/services/cli/cli_tool_service.dart`
4. `lib/core/services/cli/cli_process_supervisor.dart`
5. `lib/core/services/cli/cli_backend.dart`
6. `lib/core/services/cli/shell_capability_resolver.dart`
7. `lib/core/services/cli/windows_cli_backend.dart`
8. `lib/core/services/cli/windows_job_controller.dart`（`win32` + `ffi` 直接相依，Job Object FFI）
9. `lib/core/services/cli/android_proot_backend.dart`
10. `lib/core/services/cli/proot_bootstrap.dart`
11. `lib/core/services/cli/rootfs_patcher.dart`
12. `lib/core/services/cli/workspace_mount_table.dart`
13. `lib/core/services/cli/workspace_path_probe.dart`
14. `test/cli_tool_service_test.dart`
15. `test/cli_process_supervisor_test.dart`
16. `test/windows_cli_backend_test.dart`
17. `test/android_proot_backend_test.dart`
18. `test/rootfs_patcher_test.dart`
19. `test/workspace_mount_table_test.dart`
20. `test/shell_config_test.dart`
21. `android/app/src/main/jniLibs/arm64-v8a/libproot_exec.so`（及必要 loader `.so`）
22. `assets/cli/alpine-rootfs.tar.gz`（若採 APK 內打包方案）或 pinned download metadata（若採首次下載方案）
23. F-Droid license/source/metadata files for PRoot and rootfs packages

### 修改

1. `lib/core/services/workspace/workspace_resolver.dart`：保留 workspace resolution，必要時提供 captured execution context。
2. `lib/features/home/services/message_generation_service.dart`：捕獲 workspace、Shell config、backend capability、approval snapshot。
3. `lib/features/home/services/message_builder_service.dart`：加入 platform-specific Shell prompt 與 non-sandbox warning（現有的 workspace prompt block 延伸）。
4. `lib/features/home/services/tool_handler_service.dart`：加入 `shell_*` definitions、dispatch、approval gate、exception isolation（沿用 `file_*` branch 模式）。
5. `lib/features/home/controllers/generation_controller.dart`：傳遞 CLI context。
6. `lib/features/home/controllers/home_view_model.dart`：compress-context 新 conversation 複製 conversation shell override（對齊 workspace binding 複製）。
7. `lib/core/services/chat/chat_service.dart`：Shell config 存取、shell tool event、job cleanup 與 conversation lifecycle（fork/delete/clear 覆蓋 shell 設定）。
8. `lib/core/services/backup/data_sync.dart`：backup version 3 → 4，backup/restore Shell config、approval 與 capped Shell events；v3 備份可讀。
9. `lib/features/chat/widgets/workspace_sheet.dart`：Shell capability、probe、permission 與 PRoot status。
10. `lib/features/chat/widgets/chat_message_widget.dart`：Shell command/result cards 與 approval 操作。
11. `lib/core/providers/settings_provider.dart`：Shell default settings（預設關閉）。
12. `lib/l10n/app_en.arb` / `app_zh.arb` / `app_zh_Hans.arb` / `app_zh_Hant.arb`（+ 重新產生 `app_localizations*.dart`）：Shell settings、approval、runtime status、bootstrap progress、tool card、錯誤訊息等所有新字串。
13. `pubspec.yaml`：`win32`、`ffi` 改為直接相依；runtime assets；版本 bump 至 `1.9.0+67`。
14. `android/app/build.gradle.kts`：jniLibs packaging（`useLegacyPackaging` / alignment）與 ABI filter 確認。
15. `android/app/src/main/AndroidManifest.xml`：確認 F-Droid direct-path permission 與 `extractNativeLibs` 策略。
16. `installer.iss` / `installers/omnichat_setup.iss`：安裝程式版本 1.9.0。
17. `README.md`、`README_ZH_TW.MD`：Shell capability、非 sandbox、F-Droid 限定說明。
18. `CHANGES_LOG.md`：本次變更 entry。
19. F-Droid build metadata、license notices、source offer 與 reproducibility documentation。

---

## 十二、實作階段

### Phase 0：Capability 與安全契約

預估 3～5 個工作天。

- 定義 `ShellConfig`、`ShellStatus`、per-tool approval policy（ask/allow/deny）、`CliCapability`、request/result models。
- 定義 tool availability rules。
- 定義 Shell tool event schema 與 output persistence cap。
- 定義 platform-specific prompt 與 non-sandbox 文案。
- 定義 command denylist 只是 accident guard 的產品文案。
- 定義所有新 UI 的 l10n keys（四語系）。
- 補上 workspace path probe abstraction。
- 補上 `WorkspaceMountTable`，讓 PRoot、File Tools、prompt 與 cleanup 共用同一份 mount 定義。
- 定義 `CliProcessSupervisor` 的 start、collector、cancel、timeout、cleanup contract。

完成條件：沒有 backend 時不提供 Shell definitions；workspace disabled 或 Shell disabled 時不提供 Shell definitions。

### Phase 1：Windows foreground execution

預估 3～7 個工作天。

- `shell_exec`（含 `shell` 參數）。
- `cmd`/PowerShell 選擇與 `-ExecutionPolicy Bypass`。
- environment allowlist。
- output streaming cap（24 KB / 6 KB）與 32,768 字元 result 預算。
- console codepage / UTF-8 編碼策略。
- timeout、cancel、pipe drain。
- process 啟動後立即建立 stdout/stderr collectors。
- Job Object FFI 基礎整合（`win32`/`ffi` 直接相依）。

完成條件：能在 workspace 中執行 `echo`、`dir`、`type`、Python/Git probe，CJK 輸出正確，且 timeout 可終止整個 process tree。

### Phase 2：Windows 完整 CLI

預估 7～15 個工作天。

- `shell_script` 與 temp cleanup。
- `shell_exec_background`。
- `shell_job_status`。
- `shell_job_stop`。
- job registry、state machine、restart/lost handling。
- approval 對話框流程（ask/allow/deny、逾時、永遠允許）。
- background UI、tool events、backup v4。

完成條件：background job 可啟動、查詢、停止；app/process 終止後不會錯誤宣稱 job 仍可控。

### Phase 3：Android PRoot bootstrap

預估 10～15 個工作天，不含完整 OEM matrix。

- arm64 PRoot binary 以 jniLibs `.so` 打包與執行策略驗證。
- ABI probe。
- rootfs extraction、tar format、version/hash、lock、atomic rename。
- DNS/hosts/locale（`LANG=C.UTF-8`）/temp/group rootfs patcher。
- runtime directory、quota、cache cleanup。
- pinned rootfs source 與 download/staging/validation/activate/cleanup pipeline。
- `/bin/sh`、`echo`、`ls`、`cat` probe。
- PRoot license/source packaging。

完成條件：至少一台 arm64 Android 真機 app-private workspace 可完成基本命令。

### Phase 4：Android foreground `shell_exec`

預估 8～12 個工作天。

- host workspace probe。
- `WorkspaceMountTable` 與 `/workspace` bind。
- File Tools/Shell Tools same physical path。
- app-private workspace。
- F-Droid direct-path external workspace、permission status 與 shared storage noexec 限制說明。
- foreground timeout、output cap、collector drain、cancellation、錯誤處理。
- Shell runtime status、per-tool approval、cwd。
- Android settings/UI 與 package/runtime status（本地化）。

完成條件：app-private 不需 storage special access 即可執行；external workspace 只在 probe 與 permission 都成功時啟用。

### Phase 5：測試與 F-Droid 發行

預估 5～10 個工作天，加上裝置等待時間。

- Windows integration test。
- 至少兩台不同 Android 裝置或 OEM 驗證。
- low storage、permission denied、bootstrap interruption、app background、process timeout。
- AI Team + Shell 組合驗證。
- license/source offer audit。
- F-Droid metadata、reproducible build 與 release artifact 驗證。
- pubspec/installer 版本 bump、README、CHANGES_LOG 更新。

---

## 十三、測試矩陣

### 1. 共用 unit tests

- workspace disabled 不提供 Shell tools。
- Shell disabled 不提供 Shell tools。
- model 不支援 function calling 時不提供 Shell tools。
- null/empty workspace 拒絕執行。
- backend not ready 回傳明確錯誤。
- `ShellStatus` transitions：disabled/installing/ready/broken。
- per-tool approval policy default（ask/allow）、override、deny result、ask 逾時 result。
- command schema、shell enum（cmd/powershell）與 timeout clamp。
- stdout 24 KB / stderr 6 KB cap 與 pipe drain。
- result 序列化總長 ≤ 32,768 字元。
- process 啟動後 collectors 先於 wait 建立，超過 cap 後仍持續 drain。
- timeout 會終止 process tree。
- cancellation 不會被吞掉，且會終止目前 process。
- parent environment 不會完整繼承。
- denylist blocked result 不會 throw。
- tool exception 不會中斷對話 stream。
- tool event preview cap 與 secret redaction。
- File Tools 與 Shell 使用同一份 captured physical workspace。
- `cwd` 只能在 workspace 內。
- `WorkspaceMountTable` 的最長 target match、read-only policy 與 host/guest round-trip。
- `ShellConfig` serialization、inherit/disabled/enabled resolution。
- Compress context 複製 conversation shell override。

### 2. Windows integration tests

- `cmd`：`echo hello`、`dir`、`type`。
- PowerShell：基本 command、非互動模式、`-ExecutionPolicy Bypass` script 執行。
- 編碼：zh-TW 系統（cp950）下 `chcp 65001` 的 CJK 輸出；PowerShell UTF-8/UTF-16 路徑。
- workspace 內 File Tool 建立檔案，Shell 讀取。
- Shell 建立檔案，File Tool 讀取（含 `file_extract_text` 讀取 shell 產生的文字檔）。
- command 建立 child process 後 timeout，確認 process tree 清除（Job Object）。
- stdout 超過 24 KB 仍能正常結束。
- stderr 超過 6 KB 仍能正常結束。
- command cancellation 後 child process 與輸出 collectors 都能回收。
- script temp file 在 success、timeout、exception 後都清除。
- background job start/status/stop。
- background job crash/app restart 後標記 `lost` 或 `killed`。
- 同時 job 數量限制（2）。
- foreground FIFO 排隊（generation 內第二個 shell call 等待第一個完成）。
- command/environment 不會洩漏 provider secrets。
- AI Team：proposer/aggregator 繼承 shell tools；deny 的 slot 回傳 approval-required result 且不中斷流程。

### 3. Android integration tests

- app-private workspace 無 `MANAGE_EXTERNAL_STORAGE` 授權時成功。
- external workspace 在權限授權與 probe 成功後執行；驗證 noexec/symlink 限制下的行為與錯誤訊息。
- permission denied 時不提供 external Shell tools。
- `content://` path 明確拒絕。
- PRoot binary version probe（jniLibs `.so` 執行路徑）。
- rootfs lock、partial extraction recovery、hash/version upgrade。
- rootfs download/staging/validation/activate/cleanup pipeline。
- tar.gz/tar.xz extraction、traversal rejection、symlink/hardlink policy。
- DNS/hosts/locale/temp/group rootfs patcher 可重複執行。
- `echo`、`ls`、`cat`、`/bin/sh`。
- File Tool 寫入後 PRoot 讀取，反向亦然。
- timeout、output cap、pipe drain。
- cancellation 後 PRoot、guest child、collectors 與 temporary files 都能回收。
- mount table 與 `/workspace`、optional bind mount 的雙向 path resolution。
- Shell status、per-tool approval、cwd validation。
- app 進入背景、螢幕鎖定與 foreground service 行為。
- low storage、package cache、rootfs quota。
- 至少一台 arm64 真機完整通過。

Android 不測試 background job，因為它不在產品契約內。

### 4. F-Droid release tests

- PRoot source、license 與修改紀錄完整。
- Alpine rootfs package license/source 可追溯。
- APK 不含無法追溯來源的 opaque runtime binary。
- jniLibs `.so` 在目標裝置可執行（packaging 策略驗證）。
- F-Droid metadata 與 build recipe 可執行。
- clean environment 可重現相同 runtime asset hash。
- F-Droid 安裝後 PRoot extraction 與基本命令成功。

---

## 十四、風險與緩解

| 風險                                           | 平台      | 嚴重度 | 緩解                                                                               |
| -------------------------------------------- | ------- | --- | -------------------------------------------------------------------------------- |
| Windows child process 無法完整終止                 | Windows | 高   | Native Job Object（FFI），不只 `Process.kill()`                                       |
| Windows CLI 未安裝或 PATH 不一致                    | Windows | 中   | tool discovery、environment allowlist、明確 runtime 設定                               |
| Console codepage（cp950）造成輸出亂碼                | Windows | 中   | `chcp 65001` / PowerShell UTF-8 前綴、allowMalformed 解碼、編碼測試                        |
| PowerShell ExecutionPolicy 阻擋 script         | Windows | 中   | `-ExecutionPolicy Bypass` 納入所有 PowerShell 調用模板                                   |
| stdout/stderr collector 建立太晚造成 pipe deadlock | 兩者      | 高   | process start 後立即建立 collectors，超 cap 後仍持續 drain                                  |
| shell result 超過 API 32,768 字元預算造成雙重截斷        | 兩者      | 中   | stdout 24 KB / stderr 6 KB，序列化結果總長 ≤ 32,768 字元                                   |
| File Tools 與 PRoot 使用不同 mount/path mapping   | Android | 高   | 單一 `WorkspaceMountTable` 同時供 runner、file resolver、prompt、cleanup 使用              |
| PRoot binary 在裝置無法執行（assets 無 exec 權限/壓縮）    | Android | 高   | jniLibs `.so` 打包 + `extractNativeLibs`/alignment 策略 + 真機 probe，失敗時 disable Shell |
| Android phantom process/OEM 限制               | Android | 高   | 不提供 background job，只承諾 foreground execution                                      |
| Alpine 套件或 native dependency 不相容             | Android | 高   | 宣告支援範圍，不承諾完整 Linux userland                                                      |
| rootfs 下載、解壓或 patch 中斷造成半套 runtime           | Android | 高   | lock、staging、validation、atomic activate、cleanup、broken status                    |
| 任意 rootfs URL 引入供應鏈或版本風險                     | Android | 高   | F-Droid 預設 pinned source/hash，不接受 LLM 任意指定來源                                     |
| 外部 storage 權限拒絕或 noexec 行為                   | Android | 中   | status recheck、probe、app-private fallback、prompt 說明 noexec 限制                    |
| shell command 破壞或存取敏感資料                      | 兩者      | 高   | 獨立明確授權、non-sandbox warning、environment policy、accident denylist                  |
| tool output 保存秘密                             | 兩者      | 高   | cap、redaction、backup preview policy                                              |
| rootfs 或 package cache 佔滿磁碟                  | Android | 中   | quota、usage UI、清理策略                                                              |
| F-Droid 建置無法追溯 runtime asset                 | Android | 中高  | source offer、build recipe、hash、license audit                                     |
| 跨平台 conversation 內含不相容 command               | 兩者      | 中   | prompt 注入目前平台，不自動 replay 歷史 command                                              |
| AI Team 多 slot 同時觸發 approval                 | 兩者      | 低   | serial 執行 + 同一 approval snapshot；deny 回傳 result 不中斷流程                            |

---

## 十五、F-Droid 發行要求

本專案不做 Google Play 版本，但 F-Droid 版本仍需：

- 公開 PRoot source、GPL license 與 source offer。
- 公開 PRoot 修改內容與 build instructions。
- 追蹤 Alpine rootfs 與預置套件的版本、來源與 license。
- 避免把無法從 source 重建的 binary 當作不可說明的資產提交。
- 保持 runtime asset hash、版本 metadata 與 release artifact 一致。
- 在 README 與設定頁說明 Shell 的任意命令能力與 non-sandbox 性質。
- 說明 Android shared storage 需要使用者授權 `MANAGE_EXTERNAL_STORAGE`。
- 說明 Android 只支援前景單次 command，不支援 background job。

---

## 十六、完成條件

本 v4 只有在以下條件全部成立後才算完成：

1. Windows 提供 `shell_exec`、`shell_script`、`shell_exec_background`、`shell_job_status`、`shell_job_stop`。
2. Windows timeout、cancel 與 stop 能可靠終止 process tree（Job Object FFI）。
3. Windows environment、stdout/stderr cap（24 KB / 6 KB）、collector drain、cancellation、pipe drain、編碼與 temp cleanup 測試通過。
4. Shell runtime status 正確區分 `disabled`、`installing`、`ready`、`broken`。
5. per-tool approval（ask/allow/deny）預設安全、覆寫可持久化，未核准時不啟動 process；ask 逾時回傳明確錯誤。
6. Android 只提供 `shell_exec`，不提供 background/script/job tools。
7. Android 至少一台 arm64 真機可啟動 PRoot（jniLibs `.so`）並執行 `echo`、`ls`、`cat`。
8. Android app-private workspace 不需 `MANAGE_EXTERNAL_STORAGE` 即可執行。
9. Android external workspace 只有在 permission 與 host probe 都成功時才啟用，且 noexec 限制已對模型與使用者說明。
10. PRoot、File Tools、path resolver、prompt 與 cleanup 共用同一個 `WorkspaceMountTable`。
11. File Tools 與 Shell Tools 在同一 generation 使用同一個 physical workspace path。
12. Android `cwd` 只能在 `/workspace` 對應的 workspace 範圍內。
13. System prompt 不宣稱 workspace 是 security sandbox，且正確說明 Windows/Android shell 差異。
14. Shell capability 獨立於 Workspace capability，預設關閉。
15. Shell command、result、job state 與 secrets 的 persistence policy 已測試；result 總長符合 32,768 字元 API 預算。
16. Rootfs download、staging、validation、patch、atomic activate、cleanup 與 broken recovery 測試通過。
17. PRoot、Alpine rootfs 與相關套件的 F-Droid license/source 文件完整。
18. F-Droid clean build、APK 安裝、runtime bootstrap 與基本 CLI workflow 通過。
19. 所有新 UI 字串完成 en / zh / zh_Hans / zh_Hant 四語系本地化並重新產生 localizations。
20. Backup 格式升至 version 4 且 v3 備份仍可還原。
21. AI Team generation 繼承 shell tools 的行為已測試（含 deny 路徑）。
22. pubspec 版本、installer 版本、README 與 CHANGES_LOG 同步更新。

---

## 十七、最終建議

先完成 Windows foreground `shell_exec` 與共用 CLI abstraction，再完成 Windows background/job 工具；之後把相同的 generation snapshot、tool event 與 UI contract 複用到 Android PRoot。

Android 初版應明確定位為「可在手機前景執行的 PRoot CLI」，不要承諾完整 Linux、任意重型套件或 background execution。F-Droid-only 的發行策略讓 shared storage 與 `MANAGE_EXTERNAL_STORAGE` 可納入同一版本，但不能降低 PRoot 真機驗證、process lifecycle、F-Droid source compliance 與 Shell non-sandbox 授權的要求。
