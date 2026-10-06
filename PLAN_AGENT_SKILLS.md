# OmniChat Agent Skills 實作計劃

> **狀態**：✅ 已實作（2026-10-06，v1.25.0；驗證：`dart analyze` skills 相關檔案 0 error、新增測試 88 條全過（含型錄回歸共 96 條）。同日實測回饋修訂：移除 example-skill 播種改一次性清理、`/skill` token-only 空內容修正＋氣泡技能徽章、圖示改 WandSparkles（GitHub 下載鈕 Package）、說明移除 Anybuff；新增測試至 93 條。同日 /review 對抗式審查修復三項：未命中 warning 補 snackbar fallback（`onShowWarning` 未接線時直接 `showAppSnackBar`）、徽章 tooltip 改中性 `chatMessageWidgetSkillToken`（不宣稱已載入）、長技能名 Flexible+ellipsis 截斷；`skills_context_test` 新增 2 邊界測試至 95 條（全套 982）。同日實測修復 2（/skill 無法啟動 skill）：`SkillInvocations.resolveInMessages` 改為 **user-turn 投遞**——命中的 `<skill>` 與未命中的 `<skill_error>` 區塊一律附加到「帶有 token 的那則 user 訊息」（原文之後），system message 不再被碰觸；原設計的 system 尾端追加實測被模型忽視（token 被剝除後模型只看到剩餘文字、把 `/skill X 問題` 當一般問題處理，skill 完全未啟動；參照 Anybuff `buildFinalPrompt` 的 user-turn 投遞修復）；`emptyContentPlaceholder` 參數與 `appendToSystemMessage` 隨之移除（token-only 訊息現以 skill 區塊為內容、空內容 400 自然消解）。同日實測修復 3（/skill 投遞框架）：命中訊息改以 **Anybuff `buildFinalPrompt` 顯式框架**投遞——`I invoke the following skill: <name>`（多技能複數、token 順序）＋ `<skill>` 區塊（frontmatter 經 `SkillParser.stripFrontmatter` 剝除後再 cap）＋ 剩餘文字置尾冠 `User request: `；未命中行為不變。三則實測（ling/mimo 模型）顯示模型先讀到 description gating（「use ONLY when…」）而反覆自問是否已調用——顯式框架＋frontmatter 剝除即對症修正。另：助理過程區新增 `/skill` 靜態「載入技能」列（`ChatMessageWidget.userInvokedSkillNames`＋`_UserSkillLoadRow`，與自主調用的 skill 工具卡同款、受 `showToolCards` 閘控）；`extractSkillNames` 供徽章與新列共用。後續（同日實測回饋）：過程區「載入技能」列上線後，移除提問氣泡的技能徽章——`extractSkillNames` 仍服務過程區列與列表抽取，l10n `chatMessageWidgetSkillToken` 保留未用。手冊記錄見《OmniChat 專案開發與維護手冊.md》§3.15）
> **日期**：2026-10-05
> **目標版本**：v1.25.0（開發中）
> **參考**：Anybuff skills 子系統（`packages/host-core/src/skills/`、`common/src/types/skill.ts`、`packages/agent-runtime/src/tools/handlers/tool/skill.ts`）；本計畫的設計概念與 Anybuff 十分接近，差異處均已註明理由。
> **相關文件**：`OmniChat 專案開發與維護手冊.md`（§3.1 工作區沙盒、§3.9 輸入列按鈕自訂、§3.11 跨輪重放、§3.14 Agent Runtime）

---

## 0. 需求摘要

1. 自動讀取 **App sandbox 根目錄** `.agents/skills/` 內的 skills → **全域 skills**（桌面版位置為使用者 home `~/.agents/skills/`，業界慣例）
2. 自動讀取**當前對話工作目錄** `.agents/skills/` 內的 skills → **專案 skills**（同名時專案覆寫全域）
3. 設定頁新增 **Skills** 項目，位於「指令注入」**下方**
4. Skills 頁面包含：
   - **預載 skills 開關**：開啟 → 預先將 skill descriptions 載入 LLM 上下文，LLM 可自行調用；關閉 → 不載入，但使用者仍可透過指令調用
   - **新增 skill**
   - **匯入 skill**（本機檔案）
   - **從 GitHub 下載 skill**
   - 已安裝 skills 列表 + **刪除**按鈕
5. 輸入列新增 **skills 按鈕**，預設位於「指令注入」按鈕**後方**；點擊後顯示已安裝 skills 選單，點選即在對話框插入 `/skill <name>` 以調用該 skill

### 0.1 已確認的設計決策（與使用者確認結果）

| # | 決策 | 選擇 |
|---|---|---|
| D1 | 預載開關預設值 | **預設開啟**（與 Anybuff 一致，零配置即可用） |
| D2 | 設定頁管理範圍 | **只管理全域 skills**；專案 skills（工作目錄 `.agents/skills/`）為唯讀自動發現（對應 Anybuff 的 scope gate 概念——工作目錄屬於使用者的檔案，App 不應改寫） |
| D5 | 全域 skills 根目錄 | **桌面（Windows/macOS/Linux）**：`~/.agents/skills/`（使用者 home，業界慣例，可與 Claude Code / Anybuff 共用同一份 skills）。**行動（Android/iOS）**：`<appData>/.agents/skills/`（App 私有目錄——行動系統沒有使用者 home 概念，放 App data 才能寫入且不需權限） |
| D6 | 刪除鈕的平台差異（與 Anybuff 一致） | **桌面版不提供刪除鈕**——`~/.agents/skills/` 是與其他工具共用的目錄，刪除會影響 Claude Code / Anybuff，改在頁面說明區塊引導使用者手動刪除整個資料夾。**行動版提供刪除鈕**——skills 在 App sandbox 內、不與其他 App 共用，且只能透過本 App 刪除（外部檔案管理器難以觸及） |
| D3 | skill 工具註冊時機 | **預載 ON 時才註冊** `skill` 工具（描述內嵌 `<available_skills>` 清單）；預載 OFF 時完全不註冊，指令調用走獨立的訊息組裝路徑（見 §6.2），**兩條路徑互相獨立** |
| D4 | GitHub 下載 UX | **兩步驟**：輸入 repo → 列出含 `SKILL.md` 的資料夾（含檔案數）→ 點選後下載**整個資料夾**（含 `references/`、`scripts/` 等附件） |

---

## 1. Skill 格式規範（與 Claude Code / `npx skills` / Anybuff 相容）

採用 `SKILL.md` + YAML frontmatter 格式，與生態系完全相容（可直接貼入 Claude Code 的 `.claude/skills/` 或 Anybuff 的 `.agents/skills/`）。

```
<skills-dir>/<skill-name>/SKILL.md
```

```markdown
---
name: my-skill
description: 一段簡短描述，用於 LLM 發現與調用（1-1024 字元）
license: MIT                      # 選填
disable-model-invocation: false   # 選填；true = 不進入 LLM 發現清單，僅使用者可調用
metadata:                          # 選填；保留欄位，本版不使用
  category: development
---

# My Skill

完整的 skill 內容（此處的 Markdown 會在調用時完整送入 LLM 上下文）…
```

### 驗證規則（沿用 Anybuff `common/src/constants/skills.ts`）

| 欄位 | 規則 |
|---|---|
| `name` | 必填；`^[a-z0-9]+(-[a-z0-9]+)*$`；1–64 字元；**必須與資料夾名稱完全相同**（loader 以資料夾定址、以 frontmatter name 為 key，不一致則無法定址） |
| `description` | 必填；1–1024 字元（超出時**裁切而非拒絕**——過長描述是少顯示的理由，不是讓 skill 不可用的理由） |
| `license` | 選填字串 |
| `disable-model-invocation` | 選填 boolean；`true` 時該 skill 不出現在 `<available_skills>` 清單，但 `/skill <name>` 仍可調用 |
| `metadata` | 選填；寬鬆解析（未知結構不報錯） |

### 命名規則範例

- 有效：`git-release`、`api-design`、`review2`
- 無效：`Git-Release`（大寫）、`my--skill`（連續連字號）、`-skill`（連字號開頭）、`skill-`（連字號結尾）

### 關於目錄名：統一 `.agents/skills`

- 全域與專案**統一使用 `.agents/skills/`**（複數），與 Claude Code / Anybuff 的 `.agents/` 生態完全相容——使用者現有的 skills 可直接被 OmniChat 讀到，OmniChat 裝的 skills 也能被其他工具讀到。
- v2 可再考慮**同時**掃描 `.claude/skills/`（唯讀）以擴大相容性；本版先收斂在 `.agents/` 一個位置，避免雙重安裝語意混淆。

---

## 2. 目錄與發現機制

### 2.1 兩層根目錄

| 層 | 路徑 | 來源 | 可寫性 |
|---|---|---|---|
| **全域（桌面）** | `~/.agents/skills/` | `AppDirectories.getUserHomeDirectory()`（Windows = `%USERPROFILE%`；macOS/Linux = `$HOME`） | **可寫，但不提供刪除鈕**（與 Claude Code / Anybuff 共用目錄；新增/匯入/GitHub 下載可寫入，刪除交使用者手動處理） |
| **全域（行動）** | `<appDataDir>/.agents/skills/` | `AppDirectories.getAppDataDirectory()`（Android/iOS = Application Documents） | **App 可寫**（含刪除——sandbox 內不與其他 App 共用） |
| **專案** | `<workspacePath>/.agents/skills/` | `WorkspaceResolver.resolve()` 的結果（對話級覆寫 → 專案級 → 全域預設 → app 私有沙盒） | **唯讀**（屬使用者的工作區檔案，零殘留原則） |

> **注意**：當工作區 fallback 到 app 私有沙盒（`AppDirectories.getFileSandboxDirectory()`）時，專案層可能與行動版的全域層重疊；載入時以「路徑不同」判斷，同名 skill 由**專案層覆寫全域層**（與 Anybuff `loadSkillsSync` 的「後掃描目錄覆寫前掃描目錄」一致）。桌面版的全域層在使用者 home，與任何工作區都不重疊。

### 2.2 發現流程

```
loadSkills(globalRoot, projectRoot):
  map = {}
  for dir in [globalRoot, projectRoot]:        # 順序即優先序（後者覆寫前者）
    for entry in listDir(dir):                 # 目錄才處理；不存在/不可讀則跳過
      if !isValidSkillName(entry): continue    # 記 log（verbose 模式）
      skillFile = <dir>/<entry>/SKILL.md        # 大小寫不敏感比對檔名（SKILL.md / skill.md / Skill.md）
      if !exists(skillFile): continue
      skill = parseSkillFileContent(read(skillFile), directoryName=entry, filePath=skillFile)
      if skill != null: map[skill.name] = skill  # 附帶 scope 標記（global / project）
  return map
```

### 2.3 重新整理時機

- App 啟動（`main.dart` provider 建立時 `initialize()`）
- 設定頁 Skills 頁開啟時（`initState` → `refresh()`）
- 每次發送訊息組裝 API messages 前（`prepareApiMessagesWithInjections`；此時才確定當前對話的 workspace，需合併專案層）
- 安裝/刪除/下載完成後
- 輸入列 skills 按鈕點擊時（確保選單是新鮮的）

---

## 3. 核心服務層

### 3.1 `lib/core/models/skill.dart` — 資料模型

```dart
enum SkillScope { global, project }

class SkillDefinition {
  final String name;
  final String description;
  final String? license;
  final bool disableModelInvocation;
  final String content;      // 完整 SKILL.md 原文（含 frontmatter）
  final String filePath;
  final SkillScope scope;
  final int fileCount;       // 資料夾內檔案數（UI 顯示「含附件」用）
  // fromJson / toJson / copyWith
}
```

### 3.2 `lib/core/services/skills/skill_parser.dart` — 純函數解析器

- `SkillDefinition? parseSkillFileContent(String content, {required String directoryName, required String filePath})`
  - 解析開頭 `---\n...\n---` 之間的 YAML frontmatter；**不引入 `yaml` 套件**（pubspec 無此依賴，避免為單一功能加依賴），改寫**極簡容忍解析器**：
    - 逐行讀 `key: value`；value 支援裸字串與單/雙引號字串；跳過註解（`#`）與空行
    - `metadata:` 後的縮排區塊整段忽略（本版不使用）
    - 無 frontmatter 或缺 `name`/`description` → 回 `null`（與 Anybuff `parseFrontmatter` 空物件回 null 的語意一致）
  - 驗證 name regex、長度；**必須等於 directoryName**，否則回 null
  - description 超過 1024 字元 → 裁切（clamped，不是 rejected）
- `String? extractSkillName(String content)` — 從 frontmatter 搶先取出 `name`（匯入路徑需要先有名稱才能做完整 parse；對應 Anybuff `extractSkillName`）
- `String buildSkillDocument({name, description, body})` — 組裝新 SKILL.md 文件（description 需做 YAML scalar 安全逸出：含冒號或特殊字元時改用 JSON 引號字串，因 JSON 字串字面值是合法的 YAML 雙引號 scalar）
- **純函數、無 Flutter/IO 依賴**，可直接單測（對應 Anybuff 把 `parseSkillFileContent` 放 `common` 的理由）。

### 3.3 `lib/core/services/skills/skill_service.dart` — IO 與 CRUD

靜態方法為主（方便單測），IO 部分可注入目錄路徑：

- `String globalSkillsRoot()` → 桌面：`<userHome>/.agents/skills/`；行動：`<appDataDir>/.agents/skills/`（async，快取）
  - 新增 `AppDirectories.getUserHomeDirectory()`：Windows 讀 `Platform.environment['USERPROFILE']`、macOS/Linux 讀 `Platform.environment['HOME']`；取不到時 fallback 到 `getAppDataDirectory()`（絕不回空字串）
  - 載入時若全域根不存在則**嘗試建立**（`mkdir -p`）——桌面首次使用時 `~/.agents/` 可能不存在；唯讀發現則容忍失敗
- `Map<String, SkillDefinition> loadSkills({String? globalRoot, String? projectRoot})`
- `String formatAvailableSkillsXml(Map<String, SkillDefinition> skills)` →
  ```xml
  <available_skills>
    <skill>
      <name>git-release</name>
      <description>…（XML 逸出）…</description>
    </skill>
  </available_skills>
  ```
  （沿用 Anybuff `formatAvailableSkillsXml`；過濾 `disableModelInvocation == true`；空清單回空字串）
- `SkillDefinition? loadSkillByName(String name, {globalRoot, projectRoot})` — skill 工具與 `/skill` 指令解析共用；**每次都從磁碟新鮮讀取**（session 中新安裝的 skill 立即可用，對應 Anybuff `loadSkillFromDisk` 的 `diskSkill ?? skills[name]` 優先策略）
- `InstallResult installSkill({name, content, confirm, source})`
  - 驗證順序（fail fast，絕不留半寫的 skill）：name regex → 完整文件 parse（name 需等於資料夾名）→ 目標路徑必須在全域根之下（defense in depth）→ 已存在（真有 `SKILL.md`，空資料夾不算）→ 要求 `confirm` 才覆寫 → 寫入（`mkdir -p` 後直接寫；沿用 §3.14 的「直寫」政策：新檔直寫、不原子化，crash 風險交使用者 git）
- `InstallResult installSkillMulti({name, files, confirm, source})` — 整個資料夾安裝（GitHub 下載用）：全部寫入唯一 temp 目錄 → rename 進定位（Windows EPERM/EBUSY 退避重試，沿用 §3.14 `renameWithRetry` 語意）→ 覆寫時舊目錄暫停備份、失敗回滾（skill 要嘛完整安裝、要嘛完全不裝——半個 skill 會載入、會向模型宣傳自己、卻指向被悄悄丟棄的附件，是最混淆的失敗模式）
- `DeleteResult deleteSkill(String name)` — 只刪**全域** skill，且**只在行動平台**允許呼叫（桌面平台此方法直接回 `notSupported`，UI 也不會出現刪除鈕）；拒絕路徑穿越（`..`）、拒絕根目錄本身、拒絕非 skill 目錄；`recursive: true`
- `ImportResult importSkillFile({sourcePath, confirm, confirmFolder})` — 本機匯入：
  - 讀取 → `extractSkillName` → `installSkill`（單文件）
  - **資料夾感知（桌面）**：若挑的是 `<skill>/SKILL.md` 且同資料夾帶附件，走 `installSkillMulti`；**需使用者確認**（第一次回傳 `folderConfirm` + 完整檔案清單，再次帶 `confirmFolder: true` 才安裝——避免 `~/Downloads/SKILL.md` 旁的 20MB 安裝包被一起掃進來）
- `int countSkillFiles(String skillDir)` — 掃資料夾檔案數；**不跟隨 symlink、不進入 `.git` / `node_modules`**（對應 Anybuff `scanSkillFolder`）

### 3.4 `lib/core/services/skills/github_skill_service.dart` — GitHub 下載

- `GithubRepo? parseGithubRepo(String input)` — 接受 `owner/repo`、`github.com/owner/repo`、完整 https URL；**其他 host 一律以名稱拒絕**（輸入永遠不會觸網）；owner regex `^[A-Za-z0-9-]{1,39}$`、repo `^[A-Za-z0-9._-]{1,100}$`
- `ListGithubSkillsResult listGithubSkills(String repoInput)`:
  - `GET https://api.github.com/repos/{o}/{r}/git/trees/HEAD?recursive=1`（15s timeout，`User-Agent: OmniChat`）
  - 找出所有直接含 `SKILL.md` 的資料夾（含 repo 根目錄）→ 回傳候選清單（名稱、路徑、檔案數）
  - 404 → 「可能是私有儲存庫，僅支援公開儲存庫」；403/429 且 `x-ratelimit-remaining: 0` → 「未驗證請求每小時 60 次」
  - `truncated` 旗標 → 附加警告
- `DownloadGithubSkillResult downloadGithubSkill({repoInput, path, confirm})`:
  - 先取 trees → 取得該資料夾下**全部** blob → **先下載 `SKILL.md`**（它帶有 install 鍵定的 frontmatter name）→ extractSkillName + 驗證 → 已存在確認（在下載其餘檔案**之前**，省頻寬與 rate limit）→ 逐一下載其餘檔案（任一失敗即整體 abort，不留半個 skill）→ `installSkillMulti(source: 'github')`
  - **無檔案數/位元組上限**（沿用 Anybuff 2026-10-03 的決策：限額只會產生「半安裝的 skill」——載入、向模型宣傳、卻指向被悄悄丟棄的檔案；候選清單已顯示檔案數，選擇權交給使用者，以資訊與同意取代限額）
  - **路徑白名單**：所有 URL 只由 `api.github.com` / `raw.githubusercontent.com` 兩個常數 + 已驗證的 owner/repo 組成；`ghFetch` 內再 double-check host（defense in depth）
  - 每個 repo-relative path 過 `isSafeRelPath`（禁 `..`、絕對路徑、反斜線、`:`——Windows ADS）；不合格即整體拒絕（绝不靜默跳過）
- 使用既有 `dio`（pubspec 已有，且專案已有下載相關封装）或 `http`；**不新增依賴**

### 3.5 來源標記（provenance）

`installSkill` / `installSkillMulti` 在 frontmatter `metadata` 區塊蓋上 `source: manual|file|github` 與 `installedAt`（純文字手術，不做 YAML round-trip——文件其餘位元組保持不變；蓋章會破壞解析時退回原文，provenance 是 best-effort、絕不阻塞安裝）。設定頁可顯示來源徽章（手動/匯入/GitHub）。

---

## 4. 狀態管理：`SkillsProvider`

`lib/core/providers/skills_provider.dart`（`ChangeNotifier`，對照 `InstructionInjectionProvider` 的模式）：

```dart
class SkillsProvider extends ChangeNotifier {
  List<SkillDefinition> _globalSkills = const [];   // 設定頁管理的就是這些
  bool _loading = false;
  String? _error;

  List<SkillDefinition> get globalSkills => ...;
  bool get hasSkills => _globalSkills.isNotEmpty;

  Future<void> initialize();      // 載入全域 skills
  Future<void> refresh();         // 重新掃描（安裝/刪除/頁面開啟後）
  /// 合併全域 + 當前對話的專案 skills（發送訊息時用）
  Map<String, SkillDefinition> skillsForContext(String? workspacePath);

  Future<InstallResult> createSkill({name, description, body});
  Future<InstallResult> importSkill({sourcePath, confirm, confirmFolder});
  Future<ListGithubSkillsResult> listGithubSkills(String repoInput);
  Future<DownloadGithubSkillResult> downloadGithubSkill({repoInput, path, confirm});
  Future<DeleteResult> deleteSkill(String name);   // 僅行動平台可用（D6）；桌面平台由此頁不發起
}
```

- 在 `main.dart` 的 provider 矩陣註冊（`ChangeNotifierProvider(create: (_) => SkillsProvider()..initialize())`）
- `error` 與「空資料夾」必須區分（傳輸錯誤不是空資料夾——對應 Anybuff `skillsError` state）

---

## 5. 設定持久化

`SettingsProvider` 新增（對照 `replayToolResults` 的完整模式：key 常數、load、setter、`copyWith`/`clone` 覆寫）：

| 欄位 | SharedPreferences key | 預設 | 進備份？ |
|---|---|---|---|
| `skillsPreloadEnabled` | `skills_preload_enabled_v1` | `true` | **是**（全域行為偏好，同 §3.11 `replayToolResults`，不放 `_localOnlyKeys`） |

```dart
static const String _skillsPreloadEnabledKey = 'skills_preload_enabled_v1';
bool _skillsPreloadEnabled = true;
bool get skillsPreloadEnabled => _skillsPreloadEnabled;
Future<void> setSkillsPreloadEnabled(bool v) async { ... notifyListeners(); }
```

---

## 6. LLM 整合（兩條獨立路徑）

### 6.1 預載 ON：`skill` 工具（LLM 自行調用）

**工具定義**（在 `ToolHandlerService.buildToolDefinitions` 加入，`supportsTools && settings.skillsPreloadEnabled` 時註冊）：

```dart
{
  'type': 'function',
  'function': {
    'name': 'skill',
    'description': 'Load a skill by name to get its full instructions. Skills provide reusable '
                   'behaviors and domain-specific knowledge.\n\n'
                   'The following are the pre-loaded skills available:\n'
                   '$availableSkillsXml\n\n'
                   'Note: You can load any skill by name, including ones installed during this '
                   'session. The skill is always read fresh from disk.',
    'parameters': {
      'type': 'object',
      'properties': {'name': {'type': 'string', 'description': 'The name of the skill to load'}},
      'required': ['name'],
    },
  },
}
```

- `availableSkillsXml` 由 `SkillService.formatAvailableSkillsXml(skillsForContext(workspacePath))` 動態組裝——**需要傳入 workspacePath**，因此 `buildToolDefinitions` 與 `GenerationController.buildToolDefinitions` 的呼叫鏈需新增 `workspacePath` 參數（`message_generation_service.dart` 已有此值）。
- skill 清單為空時，描述改為「There are no skills available. Do not use this tool because there are no skills to load.」（避免 LLM 幻覺呼叫，對應 Anybuff 的明確表述）。

**工具執行**（`buildToolCallHandler` 新增 `name == 'skill'` 分支）：

- `SkillService.loadSkillByName(args['name'], globalRoot, projectRoot)`（**永遠從磁碟新鮮讀取**，session 中新裝的 skill 立即可用）
- 命中 → 回傳 `jsonEncode({name, description, content, license?})`
- 未命中或 `disable-model-invocation` → 回傳結構化錯誤 + 目前可用 skill 名稱清單（引導 LLM 改呼叫）
- **不需審批**（唯讀、無副作用）；**不經過 `ToolResultCaps`**（skill 內容屬指引文字，非工具輸出資料；但需有上限保護——見 §12）
- 需在 `_isWorkspaceToolGloballyDisabled` 的判斷中排除 `skill`（它不是 workspace 工具）

### 6.2 預載 OFF（或 ON）：`/skill <name>` 指令（使用者主動調用）

**完全不需要 skill 工具**——在訊息組裝階段解析 token：

- 使用者從輸入列按鈕（或手動）插入 `/skill my-skill` 到對話框
- `MessageGenerationService.prepareApiMessagesWithInjections` 新增一步（在 `processUserMessagesForApi` 之後、`injectInstructionPrompts` 附近）：
  ```
  resolveSkillInvocations(apiMessages, workspacePath):
    for each user message (至少處理最後一則):
      找出 /skill <name> token（regex，容許多個、容許前後文字）
      for each name:
        skill = loadSkillByName(name)   # project 優先、再 global
        命中 → 收集內容；未命中 → 收集錯誤訊息（送回 LLM 與使用者）
      移除使用者訊息中的 token，避免把無意義指令留在上下文
      將命中的 skill 內容組成 <skill> 區塊（frontmatter 剝除後 capBare）、未命中為 <skill_error>；
      以顯式調用框架重組「帶有 token 的那則 user 訊息」（2026-10-06 修訂 3；Anybuff buildFinalPrompt 措辭）：
        I invoke the following skill: my-skill
        <skill name="my-skill">
        …完整 SKILL.md 正文（frontmatter 已剝除）…
        </skill>
        User request: <剩餘文字>
        （未命中的以 <skill_error> 區塊註明於訊息尾端，讓 LLM 知道使用者想調用但失敗）
  ```
- 效果：即使預載 OFF、沒有 skill 工具，使用者一樣能把完整 skill 內容送進當前這一輪的上下文。

> **【2026-10-06 修訂 2 — 實測修復】** 投遞位置由 system message 改為 **user turn**：命中的 `<skill name="…">…</skill>` 區塊（未命中為 `<skill_error>`）附加在**帶有 token 的那則 user 訊息原文之後**（token-only 訊息即為區塊本身、不再需要 placeholder）。原因：system 尾端追加在實測中被模型忽視——token 被剝除後模型只看到剩餘文字，把 `/skill X 問題` 當一般問題處理、skill 完全未啟動；Anybuff `buildFinalPrompt` 正是把 invoked skill 內容併入使用者訊息，故對齊之。

> **【2026-10-06 修訂 3 — 實測修復（投遞框架）】** 命中訊息改以 Anybuff `buildFinalPrompt` 顯式框架重組：`I invoke the following skill: <name>`（多技能複數、token 順序）＋ `<skill>` 區塊（frontmatter 先經 `SkillParser.stripFrontmatter` 剝除再 `capBare`）＋ 剩餘文字置尾冠 `User request: `（空則省略；框架行固定英文）。原因：修訂 2 的裸附加在實測中被模型以 frontmatter `description` 的 gating 措辭（「use ONLY when…」）反覆質疑「使用者是否真的調用了」——顯式框架＋frontmatter 剝除即對症修正；未命中行為不變。助理過程區另新增 `/skill` 靜態「載入技能」列（與自主調用的 skill 工具卡同款、受 `showToolCards` 閘控）。

### 6.3 語意澄清（審查後補充）

- **預載 ON 且使用者又插入 `/skill <name>`——不是「重複注入」**：兩條路徑獨立且語意不同。`/skill` token 把**完整內容**注入該輪 user 訊息（一次性、該輪有效）；skill 工具只是讓 LLM **可以**呼叫（呼叫才回傳內容）。兩者可同時存在，內容不會重複堆叠（token 注入的是該次調用的內容；工具只在 LLM 主動呼叫時觸發）。實務上預載 ON 時使用者不太需要再插 token，但允許它（等於「這一輪強制載入 + 之後也可再呼叫」）。
- **重生生成（regenerate）的行為是正確的**：`/skill` token 存在使用者訊息的持久化內容裡，每次組裝（包含重生生成、跨輪重放）都重新解析。這是刻意設計——重生生成 = 重新回答同一個問題，skill 指引當然要重新載入；且 token 解析是純函數、每次結果一致。
- **工具卡片渲染**：`skill` 工具的 tool event 走一般的工具卡片渲染路徑（`chat_message_widget.dart` 的 `_iconFor`/`_titleFor`），顯示為「載入技能：git-release」。skill 工具事件**參與 §3.11 跨輪重放**（普通 function call，無特殊處理）。

### 6.4 與既有系統的互動契約

- **§3.11 跨輪重放**：`skill` 工具的 tool event **照常重放**（它是普通 function call，結果是合法的 tool result）。`/skill` 指令路徑只在組裝投影改寫該則 user 訊息內容（Hive 原文不動、每次重投影結果一致），工具事件重放語意不變、無重放負擔。
- **§3.14 切點安全（tool_pairing）**：skill 工具的 tool result 走與其他工具相同的 neutral 訊息路徑，無特殊處理。
- **§3.5 提示快取**：skill 工具定義放在工具清單**尾部**（`buildToolDefinitions` 最後加入），skill 清單變動只影響尾部，盡量不破 prefix 快取；`/skill` 注入的內容放在最新 user 訊息（2026-10-06 修訂 2/3；只有尾端 user turn 變動、system 前綴穩定——比 system 追加更利於 prefix 快取；修訂 3 起以顯式框架重組同一則訊息）。
- **無 workspace 時**：`workspacePath == null` → 只載入全域 skills（專案層為空）；skill 工具仍可用。

---

## 7. 設定頁：Skills（位於「指令注入」下方）

### 7.1 入口（`lib/features/settings/pages/settings_page.dart`）

在「模型與服務」section card 中，`settingsPageInstructionInjection` row 之後插入：

```dart
_iosDivider(context),
_iosNavRow(
  context,
  icon: Lucide.Sparkles,            // 或 Lucide.Wand2；與輸入列按鈕同圖示
  label: l10n.settingsPageSkills,
  onTap: () => Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => const SkillsPage()),
  ),
),
```

### 7.2 頁面（`lib/features/skills/pages/skills_page.dart`）

對照 `InstructionInjectionPage` 的視覺語言（AppBar + 觸覺卡片 + Slidable），但內容更多：

```
┌─ AppBar: Skills                    [匯入] [GitHub] [+ 新增] ┐
│                                                              │
│  ┌─ 預載 skills ─────────────────────────────────────────┐  │
│  │  預先將 skill 描述載入 LLM 上下文，                   │  │
│  │  讓 LLM 可自行調用。關閉時仍可用 /skill 指令調用。    │  │
│  │                                     [IosSwitch ●——]    │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                              │
│  已安裝（3）                              ← l10n 計數       │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ ✦ git-release                          [GitHub 徽章]  │  │
│  │   Generate changelog and bump versions…               │  │
│  │   3 個檔案 · 全域                              [刪除] │  │
│  ├──────────────────────────────────────────────────────┤  │
│  │ ✦ api-design                          [手動 徽章]     │  │
│  │   …                                                   │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                              │
│  （空狀態：圖示 + 「尚未安裝 skills，可新增、匯入或從       │
│   GitHub 下載」+ 三個入口按鈕）                              │
│                                                              │
│  說明區塊：skill 格式、目錄位置（全域/專案）、與             │
│   Claude Code/Anybuff 的相容性                               │
└──────────────────────────────────────────────────────────────┘
```

- **預載開關**：`IosSwitch`（對照 §3.1 workspace popover 的主開關風格）+ 說明文字；即時寫入 `SettingsProvider.setSkillsPreloadEnabled`。
- **已安裝列表**：**行動版**用 `Slidable`（同 instruction_injection_page 的刪除手勢）+ 每列附**刪除按鈕**（icon + confirm dialog——刪除整個資料夾需二次確認）；**桌面版不渲染刪除控件**（`PlatformUtils.isMobile` 判斷，與 D6 一致）。載入中顯示 `CircularProgressIndicator`；載入錯誤顯示錯誤列（區分空資料夾）。
- **新增**：bottom sheet 表單（name / description / body 三欄，body 預填範本：`## When to use this skill` / `## Instructions`）；即時驗證 name regex；已存在 → confirm 對話框。
- **匯入**：`FilePicker.platform.pickFiles(allowedExtensions: ['md'])`（多選）→ `importSkill`；命中資料夾附件 → 顯示檔案清單 confirm → `confirmFolder`。
- **GitHub**：對話框輸入 repo → 呼叫 `listGithubSkills` → 顯示候選清單（名稱、檔案數、警告）→ 點選 → 已存在 → confirm → `downloadGithubSkill`。下載中顯示 `LoadingDialogCard`；結果 snackbar（成功/錯誤訊息需本地化，尤其 404/rate-limit 說明）。
- **專案 skills 提示**：頁面底部說明專案 skills 位於工作目錄 `.agents/skills/`、為唯讀自動發現（引導進階使用者直接操作檔案系統）。
- **桌面版刪除引導**：說明區塊如實註明——全域 skills 位於 `~/.agents/skills/`，該目錄與 Claude Code / Anybuff **共用**，因此本頁不提供刪除；要移除某個 skill 請手動刪除整個資料夾（路徑可直接顯示，甚至附「開啟資料夾」按鈕——桌面已有 `url_launcher` 基礎設施）。

### 7.3 範例 skill 預載（可選，建議）

首次進入 Skills 頁（或首次 initialize 且全域根為空）時，種子一個 `example-skill`（內容改寫自 Anybuff 的 `initial-agents-dir/skills/example-skill/SKILL.md`，說明格式與調用方式）。讓使用者打開頁面就看到「長什麼樣」。用 SharedPreferences 一次性旗標 `skills_example_seeded_v1` 避免重複種子/覆蓋使用者刪除後的結果。

> ⚠️ 種子會在桌面版建立 `~/.agents/skills/example-skill/`——這是**共用目錄**，Claude Code / Anybuff 也會看到這個 skill。可接受（範例 skill 本身無害且可自行刪除），但旗標只在**本機**記一次，使用者手動刪除後不會再種。

---

## 8. 輸入列：skills 按鈕（位於「指令注入」後方）

### 8.1 按鈕型錄（`lib/features/home/utils/chat_input_button_catalog.dart`）

```dart
ChatInputButtonSpec(
  id: 'skills',
  icon: Lucide.Sparkles,
  label: _skillsLabel,      // l10n.skillsTitle
),
```

- 加入 `chatInputButtonCatalog`；`chatInputButtonDefaultOrder` 中放在 **`'instruction'` 之後**（`'voice'` 之前）。
- ⚠️ `test/chat_input_button_catalog_test.dart` 需更新（assert 預設順序長度/集合）。

### 8.2 ChatInputBar（`lib/features/home/widgets/chat_input_bar.dart`）

- 新增 `onOpenSkills` 回調與 `_OverflowAction(id: 'skills', ...)`（完全比照 instruction 按鈕的 pattern，含 desktop overflow menu item）。
- 顯示條件：`SkillsProvider` 有**任何**可用 skill（全域+專案）時顯示（同 `showQuickPhraseButton` 的條件式顯示策略）。
- active 狀態：無（skills 按鈕是即點即選，不持有開關狀態）。

### 8.3 ChatInputSection（`lib/features/home/widgets/chat_input_section.dart`）

傳遞 `onOpenSkills`（`isTablet ? onOpenSkills : null`——比照 instruction 按鈕只在 tablet/desktop layout 顯示，手機版走 bottom sheet 入口或保持隱藏，後續可調整）。

### 8.4 選單 UI

- **桌面**：`lib/desktop/skills_popover.dart` → `showDesktopSkillsPopover(context, anchorKey: _inputBarKey, skills: [...])`，完全仿照 `quick_phrase_popover.dart` 的 Overlay + glass panel + anchored 上彈選單。每列：圖示 + skill name + description 預覽（截斷）+ scope 徽章（全域/專案）。
- **行動**：`showModalBottomSheet`（同 instruction injection sheet 的模式）。
- **點選後**：在對話框插入 `/skill <name> `（注意：是 `/skill <name>` 空格結尾，方便繼續輸入問題；對應 Anybuff Composer 的 `replaceToken('/skill:${name} ')`，但 OmniChat 用空格而非冒號——見 §11 指令格式）。
  - 插入方式：`home_page` 持有 `_inputController`，直接用既有 pattern（同 `_handleProcessText`）：
    ```dart
    final next = current.replaceRange(start, end, '/skill $name ');
    _inputController.value = _inputController.value.copyWith(
      text: next,
      selection: TextSelection.collapsed(offset: start + inserted.length),
      composing: TextRange.empty,
    );
    _inputFocus.requestFocus();
    ```
  - **空清單保護**：`SkillsProvider.skillsForContext` 為空時，按鈕不顯示（ popover/sheet 也不需空狀態）。

---

## 9. 指令格式與解析

- **格式**：`/skill <name>`（正規表示式需容許：行首或空白後的 `/skill`、一個以上空白、name；容許行尾註解或夾雜其他文字；**容許多個 `/skill` token**）
- **解析 regex（草案）**：`(?:^|\s)/skill\s+([a-z0-9-]+)`（大小寫不敏感於 `/skill` 關鍵字；name 嚴格小寫避免歧義）
- **命中投遞框架（2026-10-06 修訂）**：`I invoke the following skill: <name>`（多技能為 `I invoke the following skills: a, b`）＋ `<skill name="…">` 區塊（frontmatter 先以 `SkillParser.stripFrontmatter` 剝除、再 `capBare`）＋ 剩餘文字置尾冠 `User request: `——Anybuff `buildFinalPrompt` 措辭；修掉實測所見模型「先讀到 description gating、反覆懷疑是否已調用」的現象。未命中仍保留 token 並於尾端加 `<skill_error>`。
- **與既有指令系統的關係**：OmniChat 沒有全域 slash command 系統，`/skill` 是**訊息組裝階段的 token 解析**（§6.2），不是傳統的 client-side 指令——這是刻意的：它讓 `/skill` 在重新生成、跨輪重放時都能穩定重現（token 存在使用者訊息裡，每次組裝都重新解析）。
- ⚠️ 邊界：`/skill` 後 name 不存在/格式不合 → 注入 `<skill_error>` 區塊而非刪除 token（讓使用者看到嘗試失敗了）。
- ⚠️ 若使用者只是想打字聊到 `/skill` 開頭的句子：只在**真的 match `<有效 name>`** 時才解析；未命中名稱的 `/skill xyz` 保持原樣留在訊息裡（不注入錯誤區塊，避免污染正常對話）。

---

## 10. l10n（4 語系 × ARB + 生成檔）

新增 keys（命名遵循既有 `instructionInjection*` / `settingsPage*` 風格）：

```
settingsPageSkills                       "Skills" / "Skills 技能"
skillsTitle                              "Skills"
skillsPreloadTitle                       "Preload skills" / "預載 skills"
skillsPreloadDescription                 "Load skill descriptions into the LLM context so it can invoke skills on its own. When off, you can still invoke a skill with the /skill command." / "預先將 skill 描述載入 LLM 上下文，讓 LLM 可自行調用。關閉時仍可用 /skill 指令調用。"
skillsInstalledSection(count)            "Installed ({count})" / "已安裝（{count}）"
skillsEmptyMessage                       "No skills installed yet." / "尚未安裝 skills。"
skillsAddTooltip / skillsAddTitle
skillsImportTooltip / skillsImportSuccess(count) / skillsImportFailed
skillsGithubTooltip / skillsGithubDialogTitle / skillsGithubRepoHint
skillsGithubListing / skillsGithubDownloadSuccess(name) / skillsGithubError404 / skillsGithubRateLimit / skillsGithubInvalidRepo
skillsDeleteTooltip / skillsDeleteConfirm(name)
skillNameLabel / skillDescriptionLabel / skillBodyLabel
skillScopeGlobal / skillScopeProject
skillSourceManual / skillSourceFile / skillSourceGithub
skillFilesCount(count)
skillsFormatHelp（格式與目錄說明）
chatInputBarSkillsTooltip
skillInvocationFailed(name)
chatMessageWidgetSkillLoad(name)            "Load skill: {name}" / "載入 skill：{name}"
```

- 同時手動更新生成檔；嘗試 `flutter gen-l10n` 重新生成，若環境不允許則手動補齊。
- ⚠️ **生成檔結構（已確認）**：
  - `app_localizations.dart` → abstract `AppLocalizations` + `supportedLocales`（`en`、`zh`、`zh-Hans`、`zh-Hant` 四個）
  - `app_localizations_en.dart` → `class AppLocalizationsEn`
  - `app_localizations_zh.dart` → **三個類別同檔**：`class AppLocalizationsZh`（源自 `app_zh.arb`）、`class AppLocalizationsZhHans extends AppLocalizationsZh`（源自 `app_zh_Hans.arb`）、`class AppLocalizationsZhHant extends AppLocalizationsZh`（源自 `app_zh_Hant.arb`）
  - 手動補新 key 時：abstract getter 加在 `app_localizations.dart`；`AppLocalizationsEn` 必加；`AppLocalizationsZh` 基類加上中文預設譯文，`Hans`/`Hant` 類**只在需要繁簡差異用語時覆寫**（既有 key 多由基類繼承，新增 key 若無繁簡差異可只加基類）
  - ⚠️ `app_zh_Hans.arb` / `app_zh_Hant.arb` 中的 key 若與 `app_zh.arb` 不同，會在對應子類產生覆寫——補 key 前先確認該 key 是否已存在於任一 ARB

---

## 11. 安全考量

| 風險 | 對策 |
|---|---|
| GitHub 下載指向任意 host | URL 只由兩個常數 host + 已 regex 驗證的 owner/repo 組成；`ghFetch` 內再驗 host；其他 host 一律拒絕 |
| 下載路徑穿越（`..`、絕對路徑） | `isSafeRelPath` 逐段檢查；不合格即**整體拒絕**（不靜默跳過） |
| 寫入目標逸出 skills 根 | `isInside(root, dir)` containment 檢查（同 §3.1 `FileToolService.resolveSafePath` 的精神） |
| 覆寫使用者 skill | `exists` gate → 強制 `confirm`；`installSkillMulti` 覆寫走 temp + rename + 回滾（舊內容在成功後才刪） |
| 危險副檔名寫入 | skills 安裝在**工作區之外**（桌面 `~/.agents/skills/`、行動 `<appData>/.agents/skills/`），不經 `FileToolService` 的副檔名黑名單——但 GitHub 下載**仍應**跳過 `.exe`/`.bat`/`.sh`/`.cmd`/`.ps1`/`.vbs`/`.dll`/`.so` 等執行檔（這些對 skill 無意義，且避免使用者誤裝惡意附件） |
| 寫入使用者 home 目錄（桌面） | 桌面版的新增/匯入/GitHub 下載會寫入 `~/.agents/skills/`——這在 Windows/macOS/Linux 都是**無需特殊權限**的可寫位置；但需注意：該目錄與其他工具共用，**刪除一律不開放**（D6），避免誤刪別的工具的 skill |
| Symlink / junction 放大掃描 | 資料夾掃描**不跟隨 symlink**（對應 Anybuff `scanSkillFolder`） |
| skill 內容注入提示汙染 | skill 內容在使用者主動調用時是**使用者選擇**的內容（風險等同指令注入）；GitHub 來源需在 UI 標示來源與「社群 skills 未經審查」的提醒 |
| Rate limit / 大儲存庫 | trees API `truncated` 旗標如實呈現警告；無大小限額（以資訊+同意取代） |
| Skill 內容無上限送入上下文 | `loadSkillByName` 讀取後若內容 > 32KB，在工具結果路徑走 `ToolResultCaps.cap`（head/tail + 重新查詢指引）；`/skill` 注入路徑同樣裁切並註記（避免單一 skill 洗爆上下文） |

---

## 12. 檔案清單

### 新增（14）

| 檔案 | 內容 |
|---|---|
| `lib/core/models/skill.dart` | `SkillDefinition`、`SkillScope`、`SkillInstallSource`、結果模型（`InstallResult`/`DeleteResult`/`ImportResult`/`ListGithubSkillsResult`/`DownloadGithubSkillResult`） |
| `lib/core/services/skills/skill_parser.dart` | 純函數 frontmatter 解析、驗證、文件組裝 |
| `lib/core/services/skills/skill_service.dart` | 載入/安裝/匯入/刪除/格式化 XML |
| `lib/core/services/skills/github_skill_service.dart` | repo 解析、trees 掃描、整資料夾下載 |
| `lib/core/providers/skills_provider.dart` | `ChangeNotifier` 狀態管理 |
| `lib/features/skills/pages/skills_page.dart` | 設定頁（預載開關 + 列表 + 新增/匯入/GitHub） |
| `lib/features/skills/widgets/skill_edit_sheet.dart` | 新增/編輯表單 bottom sheet |
| `lib/features/skills/widgets/github_skills_dialog.dart` | GitHub 下載兩步驟對話框 |
| `lib/desktop/skills_popover.dart` | 桌面輸入列 anchored popover（仿 `quick_phrase_popover.dart`） |
| `lib/features/home/widgets/skills_sheet.dart` | 行動版 bottom sheet 選單 |
| `test/skills_parser_test.dart` | 解析/驗證/組裝單測 |
| `test/skills_service_test.dart` | 載入優先序、安裝/刪除、格式化 XML 單測 |
| `test/github_skill_service_test.dart` | repo 解析、路徑安全、trees 解析單測（mock client） |
| `test/skills_context_test.dart` | `skillsForContext` 合併 + `/skill` token 解析單測 |

### 修改（12）

| 檔案 | 變更 |
|---|---|
| `lib/main.dart` | 註冊 `SkillsProvider` |
| `lib/utils/app_directories.dart` | 新增 `getUserHomeDirectory()`（Windows `%USERPROFILE%`、macOS/Linux `$HOME`，fallback `getAppDataDirectory()`） |
| `lib/core/providers/settings_provider.dart` | `skillsPreloadEnabled` 欄位/key/load/setter/clone |
| `lib/features/settings/pages/settings_page.dart` | 新增 Skills nav row（指令注入下方） |
| `lib/features/home/utils/chat_input_button_catalog.dart` | `skills` 按鈕型錄 + 預設順序 |
| `lib/features/home/widgets/chat_input_bar.dart` | `onOpenSkills` 回調 + `_OverflowAction` |
| `lib/features/home/widgets/chat_input_section.dart` | 傳遞 `onOpenSkills` |
| `lib/features/home/pages/home_page.dart` | `_openSkillsMenu`（桌面 popover / 行動 sheet）+ 插入 `/skill <name>` |
| `lib/features/home/services/tool_handler_service.dart` | `skill` 工具定義（`buildToolDefinitions` 需新增 `workspacePath` 參數）+ 執行分支（`buildToolCallHandler`——**已有** `workspacePath` 參數，直接用） |
| `lib/features/home/services/message_generation_service.dart` | 呼叫鏈傳 `workspacePath` 給 `buildToolDefinitions`；新增 `resolveSkillInvocations` 步驟 |
| `lib/features/home/controllers/generation_controller.dart` | `buildToolDefinitions` 簽名加 `workspacePath` 並透傳 |
| `lib/features/chat/widgets/chat_message_widget.dart` | 工具卡片：`_iconFor` 加 `skill` 圖示（`Lucide.Sparkles`）；`_titleFor` 加 `skill` 標題（`l10n.chatMessageWidgetSkillLoad(name)`——格式如「載入 skill：git-release」） |

| `test/chat_input_button_catalog_test.dart` | 更新預設順序斷言 |

> **呼叫鏈現況**（已驗證）：`buildToolDefinitions` 只有 **1 個呼叫點**（`message_generation_service.dart:240`）；`buildToolCallHandler` 有 **2 個呼叫點**（`message_generation_service.dart` 與 `chat_actions.dart:562` 的 approval-resume 路徑），**兩處都已傳 `workspacePath`**。`skill` 工具不涉及審批，approval-resume 路徑不會觸發 skill 呼叫，但 handler 內部的 skill 分支會自動對兩條路徑都生效。

### 文件更新（2）

- `OmniChat 專案開發與維護手冊.md`：§3 新增子節（§3.15 Agent Skills），更新目錄；§4 補設計決策（`.agent` 目錄選擇、預載開關語意、無限額策略與理由）
- `README.md` / `README_ZH_TW.MD`：功能清單補 Skills（可選）

---

## 13. 實作步驟（建議順序）

### Phase 0：協定層（純函數，無 UI 依賴）
1. `lib/core/models/skill.dart` — 模型與結果型別
2. `lib/core/services/skills/skill_parser.dart` — 解析/驗證/組裝
3. `test/skills_parser_test.dart` — 先寫測試再實作（TDD）：frontmatter 各種格式、name 不符、缺欄位、超長 description、引號逸出

### Phase 1：IO 與狀態
4. `lib/core/services/skills/skill_service.dart` — 載入/安裝/刪除/匯入/`formatAvailableSkillsXml`
5. `test/skills_service_test.dart` — 優先序覆寫、安裝驗證順序、exists gate、刪除拒絕穿越、XML 逸出
6. `lib/core/providers/skills_provider.dart` + `main.dart` 註冊
7. `SettingsProvider.skillsPreloadEnabled` 完整持久化

### Phase 2：LLM 整合
8. `ToolHandlerService`：`skill` 工具定義（含動態 `availableSkillsXml`；`buildToolDefinitions` 加 `workspacePath`）+ `buildToolCallHandler` 內 `skill` 執行分支（複用既有 `workspacePath`）
9. `message_generation_service.dart` / `generation_controller.dart`：`buildToolDefinitions` 呼叫鏈傳 `workspacePath`；新增 `resolveSkillInvocations` token 解析注入
10. `test/skills_context_test.dart` — 合併邏輯 + token 解析（命中/未命中/多個/夾雜文字）

### Phase 3：GitHub 下載
11. `github_skill_service.dart`（`parseGithubRepo`、`listGithubSkills`、`downloadGithubSkill`）
12. `test/github_skill_service_test.dart` — repo 解析（各種 URL 形式、非法 host）、`isSafeRelPath`、trees JSON 解析、錯誤分類

### Phase 4：UI
13. 設定頁入口 row + `SkillsPage`（預載開關 + 列表 + 刪除）
14. `skill_edit_sheet.dart`（新增表單）
15. 匯入流程（FilePicker + 資料夾確認）
16. `github_skills_dialog.dart`（兩步驟）
17. 輸入列：型錄 + `ChatInputBar` + `ChatInputSection` + `home_page` 接線
18. `skills_popover.dart`（桌面）+ `skills_sheet.dart`（行動）+ 插入 `/skill <name>`
18b. 工具卡片渲染：`chat_message_widget.dart` 的 `_iconFor`/`_titleFor` 加 `skill`（連帶 l10n key）

### Phase 5：收尾
19. l10n：ARB ×4 + 生成檔（`flutter gen-l10n` 或手動）
20. 更新 `test/chat_input_button_catalog_test.dart`
21. 手動 E2E 驗證（見 §14）
22. 更新專案手冊 §3.15 與 §4
23. Code review 迭代至無新問題

---

## 14. 驗證計畫

### 14.1 自動化測試

- `flutter test test/skills_parser_test.dart test/skills_service_test.dart test/github_skill_service_test.dart test/skills_context_test.dart`
- `flutter test test/chat_input_button_catalog_test.dart`（既有，需更新）
- `flutter analyze lib/core/services/skills lib/features/skills lib/core/providers/skills_provider.dart`
- 回歸：`flutter test test/chat_turn_service_test.dart`（工具定義變更）、`flutter test test/tool_handler_mcp_failure_test.dart`（handler 分支）

### 14.2 E2E 手動驗證清單

1. **發現**：在全域根放 skill（桌面 `~/.agents/skills/git-release/SKILL.md`；行動 `<appData>/.agents/skills/git-release/SKILL.md`）→ 重啟 app → 輸入列出現 skills 按鈕。桌面版可進一步驗證：把現有 Claude Code 的 `.agents/skills/` 直接指向同一個 home 目錄 → OmniChat 讀到同一份 skills
2. **專案覆寫**：工作區 `.agents/skills/git-release/SKILL.md` 用不同 description → 發送訊息 → skill 工具描述顯示專案版
3. **預載 ON**：隨意問一個 skill 描述能解的問題 → LLM 自行呼叫 `skill` → 回覆帶有 skill 指引
4. **預載 OFF**：切開關 → 重發 → LLM 不再呼叫 skill 工具；改用輸入列按鈕插入 `/skill git-release` → 發送 → 該輪回覆帶有 skill 指引；檢查上下文確認 token 已被替換成 `<skill>` 區塊
5. **新增**：設定頁新增 `test-skill` → 檔案系統確認全域根下 `test-skill/SKILL.md` 內容正確（桌面 `~/.agents/skills/`、行動 `<appData>/.agents/skills/`）
6. **匯入**：挑一個帶 `references/` 的 skill 資料夾之 `SKILL.md` → 確認對話框列出附件清單 → 確認 → 附件完整安裝
7. **GitHub**：輸入 `anthropics/skills`（或任何含 skills 的公開 repo）→ 列出候選 → 下載 → 安裝完整
8. **GitHub 錯誤**：私有 repo URL → 顯示 404 說明；亂打 host 名 → 顯示「僅支援 github.com」
9. **刪除**：（行動）滑動/點按刪除 → confirm → 資料夾消失、列表更新、輸入列按鈕在無 skill 時隱藏；（桌面）確認列表**無刪除鈕**，說明區塊有路徑引導
10. **無 skill 時**：全新安裝 → 輸入列無 skills 按鈕；skill 工具不出現在工具清單
11. **跨平台**：Windows + Android 各跑一遍（目錄路徑、popover vs sheet、FilePicker 行為）

---

## 15. 風險與未決事項

| # | 項目 | 狀態 |
|---|---|---|
| ~~R1~~ | ~~目錄名 `.agent` vs 生態系 `.agents`/`.claude`~~ | **已解決**：全域與專案統一 `.agents/skills/`，與 Claude Code / Anybuff 完全相容（D5）。v2 才考慮額外掃描 `.claude/skills/` |
| R13 | **桌面全域目錄與其他工具共用** | `~/.agents/skills/` 可能已有 Claude Code / Anybuff 的 skills。對策：(1) 載入時**接納**它們（使用者當然希望現有 skills 直接可用）；(2) **不提供刪除鈕**（D6）；(3) 安裝時蓋上 OmniChat provenance（§3.5），但**不**以此阻止覆寫——位置是共用的，最後寫入者贏，與其他工具行為一致；(4) settings 列表上的 skill 須能顯示「非本 App 安裝」的差異（provenance 徽章在無標記時顯示「外部/external」） |
| R2 | **skill 工具描述的 token 成本** | N 個 skill × (name + description ≤1024) 字元常駐工具描述。緩解：description 顯示時截斷至較短長度（如選單用 50 字元、工具描述用 200 字元）；`disable-model-invocation` 讓使用者可把不常用的踢出清單 |
| R3 | **預載 ON 時 `availableSkillsXml` 每輪重算** | 讀檔掃描在每次 `buildToolDefinitions` 時跑一次（N 個小檔案，毫秒級）；可接受。若 skill 極多才考慮快取 + 檔案 mtime 失效 |
| R4 | **`/skill` 與使用者想打 `/skill` 開頭的普通文字衝突** | 只在 name 實際命中已安裝 skill 時才解析替換；未命中保持原文（§9）。風險低 |
| R5 | **Android FilePicker 不保留資料夾結構** | Anybuff 的 `pickedFilesShareFolder` seam 就是處理這個。OmniChat 的 `FilePicker.platform.pickFiles` 在 Android 上也是扁平化 → **資料夾感知匯入在 Android 退化為單文件模式**（只裝 SKILL.md）；桌面（Windows/macOS/Linux）保留路徑→可整資料夾安裝。需在 UI 上對 Android 隱藏附件預覽或標明 |
| R6 | **GitHub 未驗證 rate limit（60/hr）** | 錯誤訊息如實說明 + 重試建議；不引入 token 認證（與 Anybuff 2026-10-03 決策一致——P2 token 已移除，多餘） |
| R7 | **`skill` 工具與 AI Team 路徑** | 已確認 AI Team（§3.2）走獨立組裝、不經 `buildToolDefinitions`（手冊 §3.2/§3.14 明載「AI Team 串行調度不經過 kernel」）。**本版只在主對話路徑提供 skill 工具**，AI Team 保持不變（避免範圍蔓延）；若需要再評估 |
| R8 | **voice chat / chat_turn 路徑** | `chat_turn_service.dart`（§3.11 語音路徑）是否需要 skill 工具？**本版不納入**；`/skill` 指令在文字路徑才解析 |
| R9 | **既有 `PLAN_PROCESS_FOLDING.md` 的未追蹤狀態** | 該檔在 git status 中為 untracked；本計畫檔同樣會以 untracked 新增。commit 時由使用者決定是否一併納入 |
| R10 | **skills 不在 Backup v3 範圍內** | 備份系統（§3.8）只打包 Hive boxes + SharedPreferences，**skills 是磁碟檔案、不會被備份**（已確認 `data_sync.dart` 的備份鍵清單不含任何檔案目錄）。跨裝置還原後全域 skills 不會跟著走——桌面版還更慘：目標裝置可能已有自己的 `~/.agents/skills/`，直接覆寫會刪掉別人的 skills，所以 v2 也只能做「匯出/匯入 skills ZIP」而非自動同步。本版刻不加（避免擴大範圍）。Skills 頁說明區塊應如實註明此限制 |
| R11 | **輸入列按鈕設定頁自動生效** | `chat_input_button_order_page.dart` 是 catalog 驅動的（`chatInputButtonEffectiveOrder` 會把未知 id 補在後面），新按鈕**自動出現**、可拖曳排序與隱藏——無需改該頁；只需更新其依賴的 `chat_input_button_catalog_test.dart` |
| R12 | **行動版輸入列沒有 instruction 按鈕** | 現有 instruction 按鈕是 tablet-only（`chat_input_section.dart` 的 `isTablet ? ... : null`），行動版走 `BottomToolsSheet`。skills 按鈕**比照辦理**（tablet/desktop 才顯示），行動版使用者可從「+」更多選單或設定頁使用；未來若行動版 instruction 按鈕解禁，skills 按鈕一併跟進 |

---

## 16. 與 Anybuff 的對照總覽

| 面向 | Anybuff | OmniChat（本計畫） | 理由 |
|---|---|---|---|
| 目錄 | `~/.agents/skills` + `~/.claude/skills`（全域）；`<cwd>/.agents/skills` + `.claude/skills`（專案） | 桌面 `~/.agents/skills`（行動 `<appData>/.agents/skills`）；`<workspace>/.agents/skills`（專案） | 業界慣例位置，與 Claude Code / Anybuff 完全相容；行動無 home 概念，退回 App data |
| 格式 | `SKILL.md` + YAML frontmatter（gray-matter + zod） | 完全相同，但用**極簡自寫解析器**（無 `yaml` 套件依賴） | pubspec 無 yaml；skill frontmatter 是平坦子集，自寫更可控 |
| LLM 發現 | `skill` 工具，描述內嵌 `<available_skills>` XML | **相同** | 證明有效的設計 |
| 使用者調用 | Composer 打 `/skill:name`（slash command 選單插入 `insertText`） | 輸入列按鈕插入 `/skill <name>`，**組裝階段解析注入** | OmniChat 無 slash command 系統；組裝階段解析讓重生成時也�定重現 |
| 安裝 scope gate | `globalSkillsScope: 'shared' | 'managed'`（桌面 shared → 唯讀；Android managed → 可寫） | **採用相同的 shared/managed 分野**：桌面 `~/.agents/skills` = shared → 可寫入但**不提供刪除**；行動 sandbox 內 = managed → 完整 CRUD；專案層永遠唯讀 | 與 Anybuff 一致，避免誤刪其他工具的 skill；OmniChat 簡化點：不掃 `.claude/`，只讀 `.agents/` 一個位置 |
| 大小/數量限額 | **無**（2026-10-03 移除；限額只造出半安裝的 skill） | **無**（同策略，以資訊+同意取代） | 半個 skill 是最混淆的失敗模式 |
| 原子寫入 | `writeFileAtomic` + `renameWithRetry`（ADR-13） | `installSkillMulti` 用 temp dir + rename + 退避重試；單文件 `installSkill` 直寫（對齊 §3.14「新檔直寫」決策） | 與專案既有原子化政策一致（只有 file_edit/file_patch 走原子化） |
| Provenance | `metadata.source` + `installedAt`（純文字手術） | **相同** | 低成本、高價值的來源標記 |
| 預載開關 | `globalSkillsEnabled`（掃 home dir 與否） | `skillsPreloadEnabled`（控制 skill 工具註冊與描述載入） | 語意不同：Anybuff 控制「掃不掃全域目錄」，OmniChat 控制「要不要把描述送進上下文」——更貼合使用者的實際問題（token 成本） |

---

## 17. 附錄：`<available_skills>` XML 範例

```xml
<available_skills>
  <skill>
    <name>git-release</name>
    <description>Generate changelog entries, bump versions, and tag releases following the project&apos;s convention.</description>
  </skill>
  <skill>
    <name>api-design</name>
    <description>Review REST/GraphQL API designs for consistency, pagination, and error semantics.</description>
  </skill>
</available_skills>
```

## 18. 附錄：`/skill` 注入後的 user 訊息片段（2026-10-06 修訂 3）

```
I invoke the following skill: git-release

<skill name="git-release">
# Git Release

When the user asks to cut a release…
</skill>

User request: <使用者原文（token 已移除）>
```

（frontmatter 由 `SkillParser.stripFrontmatter` 剝除；未命中時原文保留 token、尾端加 `<skill_error>` 區塊。）
