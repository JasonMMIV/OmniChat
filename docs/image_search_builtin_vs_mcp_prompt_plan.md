# image_search 工具方案評估：built-in tool 化 vs MCP 指令注入（A/B/C/D）

> **版本**：v1.0（2026-11-09）  
> **狀態**：評估完成，尚未實作  
> **範圍**：`image_search` 的工具註冊、system-prompt 注入、設定 UI、遷移／備份、測試  
> **非目標**：不改寫 §3.14 agent loop kernel；不新增通用 MCP 管理 UI；不動 voice path  
> **重要前提**：使用者已實測「MCP server/tool 開啟、助手有綁定、連線正常時，模型看得到 `image_search`」。本文因此把「工具可見性」與「模型呼叫率」分開處理，不再假設工具被隱藏。  
> **本次定案**：保留 tool description 的「格式／參數／URL 規則」，把「何時用／何時不用／要幾張」搬到 system prompt；圖片張數**不設硬上限**。工具名稱定案為 **`illustrate`**（目的導向「為回答配圖」；MCP server id 維持 `image_search`、顯示名改為 `Illustrate`，`tools/call` 接受舊名 alias，見 §15.9）。

---

## 0. 執行摘要

目前 `image_search` 是 built-in in-memory MCP server（顯示名 `Illustrate`、內部 id `image_search`），由 `McpProvider._ensureBuiltinImageSearchServerPresent()` 保證存在；工具定義經 `McpToolService.listAvailableToolsForAssistant()` → `ToolHandlerService.buildToolDefinitions()` 進入請求。

使用者實測顯示：**只要工具真的被廣告，模型就看得到**。因此目前的核心問題是行為層——模型看見工具，但沒有穩定地主動呼叫；不是工具被隱藏。

本文評估五條路徑：

| 方案 | 一句話 |
|:---|:---|
| **0** | 改為 client-executed built-in tool（與 `web_fetch` 同類），用全域設定開關控制 |
| **A** | 不改 built-in，在 `toolDefs` 產生後用 tool-name registry 注入 system prompt（**推薦先做**） |
| **B** | `McpServerConfig.instructions`：讓每個 MCP server 自帶使用說明，依實際廣告的工具注入 |
| **C** | 使用 MCP `InitializeResult.instructions`（需 patch bundled `mcp_client`） |
| **D** | 使用 MCP prompts primitive（`prompts/list` / `prompts/get`） |

**結論**：

- 若目標只是「提高模型主動呼叫率」——**方案 A 成本最低、風險最小**，不需要 migration、新設定鍵或 UI，約 2–4 小時可完成 MVP（含測試）。
- 若目標還包含「所有使用者預設可用、不依賴助手綁定與 MCP 連線」——才做**方案 0**；它同時要處理 migration／backup／同名工具衝突，成本約 1–1.5 天。
- 方案 B／C／D 是通用化選項；對單一 `image_search` 偏重，建議等「要讓任意第三方 MCP server 自帶使用說明」時再投入。

**推薦順序**：

1. 先做 A，量測模型呼叫率與圖片正確率。
2. 若效果好但覆蓋率不足（使用者沒開 MCP／沒綁助手），再做 0。
3. B／C／D 視未來需求再評估。

> **上下文負擔與輸入框 toggle**：量測與建議見 §15。結論：精簡 description + 精簡政策約 420–500 tokens／請求（淨增約 45–55 tokens）；關閉時應同時移除 tool 與 prompt，負擔為 0。MCP 路線沿用既有輸入框 MCP toggle；只有 built-in 路線需要新增專用 toggle。

---

## 1. 背景與現況

### 1.1 目前資料流

```text
ImageSearchMcpServerEngine（in-memory JSON-RPC）
  → McpProvider.connect() / refreshTools()
  → McpToolService.listAvailableToolsForAssistant()
  → ToolHandlerService.buildToolDefinitions()
  → ChatApiService tools payload
  → model calls image_search
  → ToolHandlerService.buildToolCallHandler()
  → McpToolService.callToolTextForAssistant()
  → ImageSearchMcpServerEngine.handleMessage()
```

Prompt 組裝順序（主 chat path，`message_generation_service.dart`）：

```text
injectSystemPrompt()            // assistant prompt + [File Workspace]
injectMemoryAndRecentChats()
injectSearchPrompt()            // SearchToolService.getSystemPrompt()
injectInstructionPrompts()
injectTodoSnapshot()
SkillService.globalSkillsRoot() // warm-up
SkillInvocations.resolveInMessages()
applyContextLimit()
inlineLocalImages()
buildToolDefinitions()
```

> 注意：`buildToolDefinitions()` 目前跑在 `applyContextLimit()` 之後；`applyContextLimit()` 只做「訊息則數」裁切（且目前是 dormant），不會裁掉 system 內容，所以在 `toolDefs` 之後追加 system prompt 是安全的。

### 1.2 問題定義

| 問題 | 現況 | 影響 |
|:---|:---|:---|
| **可見性** | 已由使用者實測確認：開啟且綁定後模型看得到 | 不是本文要解決的問題 |
| **呼叫率** | tool description 已有 6 條規則（約 1.2k 字元），但部分模型把它當 metadata，權重低於 system instruction | 模型不一定主動呼叫 |
| **覆蓋率** | MCP 工具仍需 `assistant.mcpServerIds` 綁定 + server 連線 + tool toggle | 沒開 MCP 的使用者完全沒有這個工具 |
| **正確率** | 目前只靠 description 的規則 | 可能插入不相關圖片、重複圖片或自創 URL |

### 1.3 已定案決策

| 決策 | 內容 | 影響 |
|:---|:---|:---|
| 可見性前提 | 以使用者實測為準：工具開啟後模型看得到 | 本文不再主張「工具根本沒被廣告」 |
| 圖片張數 | **不設硬上限**；依答案實際需要，每個主體最多一張，不重複、不裝飾 | Prompt 不再寫「0–2 張」 |
| Description / Prompt 分工 | description 留「工具是什麼、參數、結果格式、URL/嵌入規則」；system prompt 放「何時用／何時不用／要幾張」 | 避免同一套規則重複付 token |
| 注入 predicate | 必須與「實際被廣告的 toolDefs」同源 | 不會叫模型用一個沒被送出的工具 |
| 方案 0 的預設（若採用） | 新安裝預設 ON、全域開關、可靠性修正同批 | 僅適用方案 0 |
| 方案 A/B/C/D 選擇 | 待決（本文建議 A 先行） | — |

---

## 2. 共用設計原則

以下原則適用於所有方案。

### 2.1 注入與 `toolDefs` 同源

`toolDefs` 是「模型實際看到哪些工具」的唯一真相。Prompt 注入應該在 `buildToolDefinitions()` 之後，根據實際的 function name 決定要不要注入。

這樣會自動涵蓋：

- `supportsTools == false` → 沒有 toolDef，不注入
- 模型不支援 tools → 不注入
- MCP server 沒綁到助手 → 沒有 toolDef，不注入
- Server 沒連上／tool toggle 關閉 → 沒有 toolDef，不注入
- Gemini 原生 built-ins 開啟 → function declarations 被整包抑制 → 不注入

若只讀設定或 server 設定就注入，會出現「system prompt 叫模型用工具，但 tools 陣列裡沒有」的矛盾。

### 2.2 Gemini 原生工具互斥

`MessageBuilderService.hasGeminiBuiltInTools()` 只要看到 `google_search` / `url_context` / `code_execution` / `youtube` 任一開啟就回傳 true；`chat_api_service.dart` 在這些 built-ins 存在時會**整包丟掉 `function_declarations`**（不是只丟 search）。

因此：

- image tool 的註冊 predicate 必須包含 `!hasGeminiBuiltInTools`
- image prompt 的注入 predicate 也必須包含 `!hasGeminiBuiltInTools`

`buildToolDefinitions` 的參數名叫 `hasBuiltInSearch`，但在 `message_generation_service` 傳入的是 `hasGeminiBuiltInTools(...)`；文件與程式註解建議統一稱呼，避免誤解。

### 2.3 Prompt 與 description 的分工（本次定案）

| 內容 | 位置 | 理由 |
|:---|:---|:---|
| 工具 identity：搜尋網路圖片、回傳 direct URL | description | 模型需要知道工具存在與用途 |
| 參數：`query`、`max_results` | description | schema 本來就該在 tool definition |
| 結果格式：`items[]` 欄位 | description | 模型要知道怎麼讀結果 |
| URL 規則：只用回傳 URL、不得自創、`![alt](url)`、優先 `thumbnail_url` | description | 與工具輸出格式直接相關 |
| 何時用 | system prompt | 使用政策，權重高於 tool description |
| 何時不用 | system prompt | 避免過度觸發 |
| 要幾張／每主體一張／不重複／不裝飾 | system prompt | 回答層級政策 |
| 驗證 `title` 與主體相符 | system prompt | 品質控制 |
| 工具失敗／空結果的退場行為 | system prompt | 回答層級政策 |
| 來源／作者／授權標註 | system prompt | 回答層級政策（URL 規則仍在 description） |

#### 2.3.1 精簡後的 tool description

```text
Search the web for images and return direct image URLs.

Results are JSON: items[] with index, title, image_url, thumbnail_url,
source_url, author, license, backend.

Rules:
- Only use URLs returned by this tool. Never invent or guess an image URL.
- Embed each image as ![alt](url) immediately after the sentence it illustrates.
- Prefer thumbnail_url for embedding; image_url is the original.
- A maximum of 5 validated URLs are returned regardless of max_results.
```

`query` 參數描述保留「具體查詢」即可，例如：

```text
Concrete search query for the image you need, e.g.
"Ada Lovelace portrait" or "iPhone 15 Pro product photo".
```

`max_results` 的描述保留範圍與預設；若之後要對齊「只驗證前 5 筆」，可改成：

```text
Maximum number of results to request (1-15, default 10).
Only the first 5 candidates are HTTP-validated before being returned.
```

> 現況：`clampImageMaxResults()` 預設 10，但 `_validateHits` 只驗證前 5 筆。這是既有行為差異，建議一併修正（見 §10.5）。
>
> 現況：現行 description（`_toolDefinitions()`）寫 "Search for real photographs on the web..."，但引擎實際回傳的是 DDG 圖片搜尋與 Wikimedia 的**任意網路圖片**（照片、圖表、logo、插畫皆可能），並不限定真實照片；且現行 description 一律排除 "logos, icons, charts"，但當問題本身就是問 logo／圖表外觀時應該要找得到圖。§2.3.1 的精簡版改用 "images" 描述範圍並移除該排除；「何時不用」交給 system prompt 政策（§2.3.2）。

#### 2.3.2 System prompt 政策文字

以下文字不設硬性張數上限：

```text
## illustrate usage
You have the `illustrate` tool, which searches the web and returns direct URLs of matching images (photographs, artworks, diagrams, logos, and more).

When to use:
- The answer involves concrete real-world subjects whose appearance matters:
  people, products, landmarks, artworks, animals, places, notable objects.
- An image would materially improve the answer (identification, comparison,
  visual reference), or the user asks for pictures.

When not to use:
- Abstract concepts, code, math, definitions, opinions, or purely textual answers.
- Decorative filler that does not illustrate a specific subject.

How many:
- Use as many images as the answer genuinely needs. A single subject usually
  needs one image; a comparison or a list of distinct people/places/objects may
  need one per subject.
- Do not repeat the same image or query. Do not add images just to fill space.
- If a subject has no relevant result, omit it rather than forcing an image.

Rules:
- Use only URLs returned by the tool. Never invent or guess an image URL.
- Prefer `thumbnail_url` for embedding; use `image_url` for the original.
- Embed each image right after the sentence it illustrates: ![alt](url).
- Verify the returned title matches the intended subject before using it.
- Mention the source (and author/license for Wikimedia results) when appropriate.
- If the tool fails or returns nothing useful, continue without images;
  do not retry more than once.
```

> 這段文字刻意不寫「0–2 張」。若產品之後要控制成本，建議用「軟性建議」而非硬限制，例如「typical answers use 1–3 images; use more only when the answer covers multiple distinct subjects」。

### 2.4 圖片數量政策

- **不設硬上限**：問題涉及多個人物／地點／物件時，允許每個主體各一張。
- **每主體最多一張**：避免同一人物多張相似照片。
- **不重複**：同一張圖、同一查詢不要重複使用。
- **不裝飾**：圖片必須說明特定主體；不是為了讓版面好看。
- **找不到就略過**：不要用不相關的圖片硬湊。
- **延遲提醒**：多主體會變成多次 tool call；agent loop 是循序執行，延遲會累加。Prompt 可以要求模型「先盤點需要的主體，再一次把多個查詢並列發出」，但 kernel 仍會逐個跑，只能減少輪數，不能真的並行。

### 2.5 不注入的路徑

| 路徑 | 原因 |
|:---|:---|
| Voice（`ChatTurnService.prepare()`） | 只廣告 `search_web`；語音無法顯示圖片 |
| Gemini 原生 built-ins | function declarations 被整包抑制 |
| `supportsTools == false` | 模型無法呼叫工具 |
| Tool 不在實際 `toolDefs` | server 未綁定／未連線／tool toggle 關閉 |

AI Team 目前沒有走 `ToolHandlerService` 的工具路徑；本次不需要處理。Answer Review 的 review phase 是 `tools: null`，revision 繼承主 run 的 tools，會自動可用。

---

## 3. 方案 0：改為 built-in tool

### 3.1 目標架構

```text
ImageSearchTool（client-executed built-in）
  ├─ getToolDefinition()  → ToolHandlerService.buildToolDefinitions()
  ├─ getPrompt()          → MessageBuilderService.appendToSystemMessage()
  └─ execute()            → ToolHandlerService.buildToolCallHandler()
```

直接重用 `ImageSearchMcpServerEngine` 的 DDG + Wikimedia + HEAD 驗證邏輯；把 `_imageSearch` 抽成 public（例如 `Future<String> search(Map<String, dynamic> args)`），MCP wrapper 若暫時保留就 delegate 過去，避免兩份邏輯漂移。

### 3.2 Tool 層

新增 `lib/core/services/image_search/image_search_tool.dart`：

```dart
class ImageSearchTool {
  // Model-facing tool name（2026-11-09 定案：illustrate，見 §15.9）。
  // The MCP server id stays 'image_search' so existing assistant bindings
  // and persisted JSON need no migration.
  static const String toolName = 'illustrate';

  static Map<String, dynamic> getToolDefinition() {
    return {
      'type': 'function',
      'function': {
        'name': toolName,
        'description': 'Search the web for images and return direct '
            'image URLs.\n\n'
            'Results are JSON: items[] with index, title, image_url, '
            'thumbnail_url, source_url, author, license, backend.\n\n'
            'Rules:\n'
            '- Only use URLs returned by this tool. Never invent or guess an '
            'image URL.\n'
            '- Embed each image as ![alt](url) immediately after the sentence '
            'it illustrates.\n'
            '- Prefer thumbnail_url for embedding; image_url is the original.\n'
            '- A maximum of 5 validated URLs are returned regardless of '
            'max_results.',
        'parameters': {
          'type': 'object',
          'properties': {
            'query': {
              'type': 'string',
              'description': 'Concrete search query for the image you '
                  'need, e.g. "Ada Lovelace portrait" or "iPhone 15 Pro '
                  'product photo".',
            },
            'max_results': {
              'type': 'integer',
              'description': 'Maximum number of results to request (1-15, '
                  'default 10). Only the first 5 candidates are HTTP-validated '
                  'before being returned.',
            },
          },
          'required': ['query'],
        },
      },
    };
  }

  static String getPrompt() => '''...§2.3.2 的政策文字...''';

  /// 只有當 illustrate 真的被廣告時才回傳政策文字。
  static String? promptForDefinitions(List<Map<String, dynamic>> defs) {
    final advertised = defs.any((d) {
      final fn = d['function'];
      return fn is Map && (fn['name'] ?? '').toString() == toolName;
    });
    return advertised ? getPrompt() : null;
  }

  static Future<String> execute(Map<String, dynamic> args) async {
    // 重用 engine；回傳 model-facing text。
  }
}
```

**不要**把 `illustrate` 加進 `BuiltInToolNames`。那個類別是 provider-native tool（`web_search`、`url_context`、`image_generation`）的命名空間，混進去會影響 model override、Gemini 衝突判定與排序。

### 3.3 註冊 predicate

在 `ToolHandlerService.buildToolDefinitions()`：

```dart
if (settings.imageSearchEnabled &&
    supportsTools &&
    !hasBuiltInSearch) { // message_generation_service 傳入的是 hasGeminiBuiltInTools
  toolDefs.add(ImageSearchTool.getToolDefinition());
}
```

### 3.4 Prompt 注入

即使方案 0 的註冊 predicate 已經很明確，仍建議用「post-toolDefs」注入，與方案 A 共用同一套機制：

```dart
final toolDefs = generationController.buildToolDefinitions(...);

final imagePrompt = ImageSearchTool.promptForDefinitions(toolDefs);
if (imagePrompt != null) {
  messageBuilderService.appendToSystemMessage(apiMessages, imagePrompt);
}
```

這樣 `illustrate` 的 prompt 與 tool 定義永遠同進同出，不需要在 `injectSystemPrompt` 再維護一份 predicate。

### 3.5 執行

在 `ToolHandlerService.buildToolCallHandler()` 加 explicit branch，**放在 MCP fallback 之前**：

```dart
if (name == ImageSearchTool.toolName) {
  if (!settings.imageSearchEnabled) {
    return jsonEncode(<String, dynamic>{
      'type': 'tool_error',
      'error': 'tool_disabled',
      'message': 'Image search is disabled in settings.',
      'tool': name,
    });
  }
  final result = await ImageSearchTool.execute(args);
  if (messageId != null && messageId.isNotEmpty) {
    try {
      await chatService.upsertToolEvent(
        messageId,
        id: (toolCallId ?? '').trim(),
        name: name,
        arguments: args,
        content: result,
        // 可選 UI-only extras：backend / hit count
      );
    } catch (_) {}
  }
  return ToolResultCaps.cap(toolName: name, result: result);
}
```

唯讀網路工具，不走 approval。

### 3.6 設定與 UI

`SettingsProvider` 新增：

```dart
static const String imageSearchEnabledKey = 'image_search_enabled_v1';
bool _imageSearchEnabled = true;
bool get imageSearchEnabled => _imageSearchEnabled;
Future<void> setImageSearchEnabled(bool enabled) async { ... }
```

需要補齊：

- `_load()`：`prefs.getBool(imageSearchEnabledKey) ?? true`
- setter + `notifyListeners`
- `copyWith` / `applySettings`（備份還原會走這裡）
- reset / clear 資料路徑
- 不放進 `_localOnlyKeys`（user intent，隨備份同步）

UI 放「搜尋服務」頁的 Web Fetch 區塊旁（手機版 search settings sheet 也可加），l10n ×4 並重新產生 `app_localizations_*.dart`。

工具卡（`chat_message_widget.dart`）：

- `_iconFor`：`case 'illustrate': return Lucide.Image;`
- `_titleFor`：顯示「圖片搜尋：`query`」
- `message_export_sheet.dart` 的重複 switch 也要加
- `tool_result_caps.dart` 加 image 的 re-query guidance

`process_group_logic` 不用改；`illustrate` 會正常顯示成一張工具卡，不需要像 `builtin_search` 那樣隱藏。

### 3.7 遷移與備份

照 `applyLegacyFetchMigration()` 複製一份 `applyLegacyImageSearchMigration()`：

1. 讀 `mcp_servers_v1`，辨識 `transport == inmemory` 且 `id == 'image_search'` / `name == 'Image_Search'` 的 entry。
2. 把 `enabled` / `isActive` / 單一 tool 的 `enabled` 轉成 `image_search_enabled_v1`（任一 enabled = on，與 `_legacyFetchEnabled` 同語義）。
3. 從 `mcp_servers_v1` 移除該 entry。
4. **必須在 `SettingsProvider` load 之前呼叫**（`main.dart` 現在呼叫 `applyLegacyFetchMigration()` 的位置旁），否則 SettingsProvider 會先讀到預設值。
5. 備份還原後也要呼叫（`data_sync.dart` 現有 fetch migration 的位置）。
6. `McpProvider._load()` 開頭也防御性呼叫一次（測試／非 main 啟動路徑）。
7. 刪掉 `_ensureBuiltinImageSearchServerPresent()`、`connect()` 的 image branch、`replaceAllFromJson` 的 `imageSearchEnabled` 分支與 `next.add(...)`。
8. `replaceAllFromJson` 的舊 JSON 匯入路徑也要有對應遷移，否則使用者匯入舊 MCP JSON 時 image 設定會默默消失。
9. 舊備份 restore 到新版本靠 step 5；新備份 restore 到舊版本會失去 image 功能，這是可接受的單向相容，release note 說明即可。

**同名工具衝突**：更名為 `illustrate` 後，第三方 MCP server 幾乎不可能也叫 `illustrate`，衝突風險大幅降低；若保守起見，`buildToolDefinitions` 仍可過濾同名 tool（provider 遇到重複 function name 可能直接 400）。

**Dead id**：`assistant.mcpServerIds` / `conversation.mcpServerIds` 會留下 `image_search`；功能上無害，但可考慮 lazy cleanup。

### 3.8 優缺點

| 優點 | 缺點 |
|:---|:---|
| 全域預設可用，不依賴助手綁定 | 需要 migration／backup 處理 |
| 不依賴 MCP 連線狀態 | 需要新設定鍵與 UI |
| 少一個 in-memory connection / JSON-RPC roundtrip | 失去 per-assistant 粒度 |
| 可用 settings toggle 控制 | 同名工具衝突風險（若沒移除 MCP server） |
| 工具卡／caps／測試可集中處理 | 新→舊備份不相容（單向） |

### 3.9 工作分解

| 階段 | 內容 | 估計 |
|:---|:---|:---|
| Tool 層 | `ImageSearchTool` + engine public `search()` + `buildToolDefinitions` + handler | 0.25 天 |
| Prompt 層 | 精簡 description + `getPrompt()` + post-toolDefs 注入 | 0.1 天 |
| 設定／UI | `imageSearchEnabled` + 搜尋頁 toggle + l10n + 工具卡 + caps | 0.25 天 |
| 遷移／備份 | `applyLegacyImageSearchMigration` + main/data_sync/_load + replaceAllFromJson | 0.25 天 |
| 測試／文件 | 新測試 + 更新 `web_fetch_migration_test` + 手冊 §3.13 | 0.5 天 |
| 可靠性（同批） | Wikimedia fallback、timeout、HEAD 並行、SSRF | 0.25 天 |
| **合計** | | **約 1–1.5 天** |

---

## 4. 方案 A：MCP tool-name registry + `toolDefs` 後注入（推薦）

### 4.1 架構

不改變 `image_search` 的 MCP server id（顯示名改為 `Illustrate`），只在 prompt 組裝層加一個純函式 registry：

```text
buildToolDefinitions()
  → toolDefs（含 illustrate，若真的被廣告）
  → McpToolPrompts.forDefinitions(toolDefs)
  → appendToSystemMessage(apiMessages, prompt)
```

同時把 `ImageSearchMcpServerEngine._toolDefinitions()` 的 description 精簡成 §2.3.1 的版本；政策文字搬到 `McpToolPrompts`。

### 4.2 程式碼草圖

```dart
// lib/core/services/mcp/mcp_tool_prompts.dart
abstract class McpToolPrompts {
  static const Map<String, String> _byTool = {
    'illustrate': '''...§2.3.2 的政策文字...''',
  };

  /// 只回傳「本次真的被廣告」的 tool 的指令，順序穩定。
  static String? forDefinitions(List<Map<String, dynamic>> defs) {
    final blocks = <String>[];
    final seen = <String>{};
    for (final d in defs) {
      final fn = d['function'];
      if (fn is! Map) continue;
      final name = (fn['name'] ?? '').toString();
      if (name.isEmpty || !seen.add(name)) continue;
      final text = _byTool[name];
      if (text != null) blocks.add(text.trim());
    }
    return blocks.isEmpty ? null : blocks.join('\n\n');
  }
}
```

在 `message_generation_service.dart` 取得 `toolDefs` 之後（目前約 339 行）：

```dart
final toolDefs = generationController.buildToolDefinitions(...);

final toolPrompt = McpToolPrompts.forDefinitions(toolDefs);
if (toolPrompt != null) {
  messageBuilderService.appendToSystemMessage(apiMessages, toolPrompt);
}
```

`appendToSystemMessage()` 在 `message_builder_service.dart:907`，會把文字接在既有 system message 尾端；`applyContextLimit()` 只做訊息則數裁切（且目前 dormant），不會裁掉 system 內容。

### 4.3 為何在 `toolDefs` 之後

| Gate | 由 `toolDefs` 自動反映 |
|:---|:---|
| 模型不支援 tools | 無 toolDef → 不注入 |
| MCP server 沒綁助手 | 無 toolDef → 不注入 |
| Server 沒連上 | `getEnabledToolsForServers` 只回 connected → 不注入 |
| Tool toggle 關閉 | `getEnabledToolsForServers` 只回 enabled → 不注入 |
| Gemini 原生 built-ins | `chat_api_service` 丟掉 function declarations → 不注入 |
| 同名工具 dedupe | `McpToolPrompts` 以 name 去重，只注入一次（`toolDefs` 本身仍可能有兩份定義，需另處理） |

若改成「讀設定就注入」，上述每一個 gate 都要另外複製一份，容易漂移。

### 4.4 與 description 的分工

方案 A 也需要**同時**修改 MCP server 的 tool description（`image_search_server.dart`），否則 description 仍會帶著「何時用／何時不用」的舊文字，system prompt 又再寫一次，形成重複。建議：

- `_toolDefinitions()` 的 description 換成 §2.3.1 的精簡版。
- `McpToolPrompts` 放 §2.3.2 的政策文字。
- `refreshTools()` 會在下次連線時更新 `McpToolConfig.description`；既有 `enabled` 狀態會保留。

### 4.5 優缺點

| 優點 | 缺點 |
|:---|:---|
| 成本最低：1 個新檔案 + 1 個呼叫點 + 測試 | 只解決「模型不叫」；沒開 MCP／沒綁助手的使用者仍沒有工具 |
| 不需要 migration、新設定鍵、UI | Registry 以 tool name 為鍵；自訂改名（例如 `image_search_v2`）不會匹配 |
| 不動 MCP protocol／provider | Prompt 與 description 需要人工保持分工，否則會重複 |
| Agent loop / Answer Review revision 自動繼承 | 仍是 per-assistant MCP 綁定 |
| 可快速上線量測，效果不好可移除 | Token 成本：每次請求多約 350–400 tokens（詳細政策）或 160–190 tokens（精簡政策），見 §15 |

### 4.6 測試

- `McpToolPrompts.forDefinitions()`：
  - 有 `illustrate` → 回傳政策文字
  - 沒有 → 回傳 null
  - 重複 definition → 只回一次
  - 非 function 形狀 → 忽略
- 組裝整合測試：
  - `illustrate` 被廣告 → system message 包含 `## illustrate usage`
  - tool toggle 關閉 → 不包含
  - `supportsTools == false` → 不包含
  - Gemini built-ins → 不包含
- 手動 smoke：Claude / GPT / Gemini / DeepSeek，各測單主體、多主體、抽象概念、程式碼。

---

## 5. 方案 B：`McpServerConfig.instructions`

### 5.1 架構

讓每個 MCP server 自帶一段「使用說明」，由使用者在 MCP server 設定頁編輯；注入時只取「實際廣告的工具所屬 server」的 instructions。

### 5.2 Model 變更

```dart
class McpServerConfig {
  final String instructions;

  McpServerConfig({
    ...
    this.instructions = '',
  });

  McpServerConfig copyWith({String? instructions, ...}) => ...;

  Map<String, dynamic> toJson() => {
    ...
    if (instructions.trim().isNotEmpty) 'instructions': instructions,
  };

  factory McpServerConfig.fromJson(Map<String, dynamic> json) => McpServerConfig(
    ...
    instructions: (json['instructions'] as String?) ?? '',
  );
}
```

### 5.3 UI

`mcp_server_edit_sheet.dart` 加一個多行 `TextField`（label 例如「Usage instructions」），僅對非 built-in server 顯示；內建 `Illustrate` 由程式預填，欄位可設為唯讀或隱藏。

### 5.4 注入

```dart
String? instructionsForToolNames(
  Set<String> advertisedToolNames,
  Set<String> selectedServerIds,
) {
  final blocks = <String>[];
  for (final s in _servers) {
    if (!selectedServerIds.contains(s.id)) continue;
    if (!s.enabled) continue;
    if (statusFor(s.id) != McpStatus.connected) continue;
    final text = s.instructions.trim();
    if (text.isEmpty) continue;
    final ownsAdvertisedTool = s.tools.any(
      (t) => t.enabled && advertisedToolNames.contains(t.name),
    );
    if (!ownsAdvertisedTool) continue;
    blocks.add(text);
  }
  return blocks.isEmpty ? null : blocks.join('\n\n');
}
```

在 `buildToolDefinitions` 之後取得 `advertisedToolNames`，再用助手綁定的 server ids 呼叫此方法。

### 5.5 優缺點

| 優點 | 缺點 |
|:---|:---|
| 通用：任何 MCP server 都能帶使用說明 | 要改 model、JSON、UI、備份、測試 |
| 使用者可自訂／關閉 | 第三方 server 的 instructions 是不可信文字，直接進 system prompt 有 prompt-injection 風險 |
| 不需要為每個工具寫 code constant | Built-in server 的欄位是否可編輯需產品決策 |
| 與方案 A 的注入點可共用 | 仍是 per-assistant MCP 綁定 |

---

## 6. 方案 C：MCP `InitializeResult.instructions`

### 6.1 規格

MCP `initialize` 的 `InitializeResult` 有 optional `instructions` 字串。官方 lifecycle 範例：

```json
{
  "protocolVersion": "2025-06-18",
  "capabilities": { ... },
  "serverInfo": { ... },
  "instructions": "Optional instructions for the client"
}
```

官方部落格說明它是給模型的 hint，client「MAY be added to the system prompt」。  
參考：<https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle>、<https://blog.modelcontextprotocol.io/posts/2025-11-03-using-server-instructions/>

### 6.2 目前 bundled client 的 gap

- `dependencies/mcp_client/lib/src/protocol/protocol.dart`：`defaultVersion = v2025_03_26`
- `dependencies/mcp_client/lib/src/models/models.dart` 的 `InitializeResult` 只有 `serverInfo` / `protocolVersion` / `capabilities`，**沒有 `instructions`**
- `dependencies/mcp_client/lib/src/client/client.dart` 的 `_initialize()` 也只讀這三個欄位

所以今天 server 就算回傳 `instructions`，也會被丟掉。

### 6.3 實作路徑

1. Patch `mcp_client` 的 `InitializeResult` 與 `_initialize()`，暴露 `serverInstructions` getter（或 `initialize()` 回傳原始 map）。
2. `McpProvider.connect()` 將 instructions 存到 `_serverInstructions[id]`。
3. `ImageSearchMcpServerEngine` 在 `initialize` result 加上 `instructions`。
4. 注入時，對「已選取、已連線、有實際廣告工具」的 server，追加其 instructions。

### 6.4 優缺點

| 優點 | 缺點 |
|:---|:---|
| 符合 MCP 規格，server 自帶說明 | 要 patch vendored dependency，維護成本高 |
| 對遠端／第三方 MCP server 也適用 | 是 server 級而非 tool 級；多工具 server 無法分別說明 |
| 不需要新 UI | 依賴連線成功；連線失敗就沒有 instructions |
| | 第三方文字直接進 system prompt，有 prompt-injection 風險 |
| | 仍需自行決定「何時注入」與長度上限 |

---

## 7. 方案 D：MCP prompts primitive

### 7.1 能力

`mcp_client` 已支援：

- `client.listPrompts()`（`client.dart:508`）
- `client.getPrompt(name, args)`（`client.dart:523`）

MCP server 可以暴露 `prompts/list` / `prompts/get`；`Illustrate` 目前只實作 `initialize` / `tools/list` / `tools/call`，需要新增。

### 7.2 實作路徑

1. `ImageSearchMcpServerEngine` 新增 `prompts/list`（例如一個 `usage_instructions` prompt）與 `prompts/get`。
2. `McpProvider.connect()` 或第一次使用時抓取並快取。
3. 注入時，對已選取／已連線／有廣告工具的 server，追加其 prompt 內容。
4. 可選：在 MCP UI 提供「檢視／插入 prompt」入口。

### 7.3 優缺點

| 優點 | 缺點 |
|:---|:---|
| 使用 MCP 標準 primitive | 對單一工具是 overkill |
| Server 可提供多個 prompt／參數化 | 「連線時自動抓取並注入」仍是 client 自訂政策，不是 protocol 自動行為 |
| 未來可讓使用者手動呼叫 | 多一次 roundtrip；prompt 內容不可信 |
| | 比方案 A 多改 server 與 provider，收益有限 |

---

## 8. 方案比較

| 維度 | 方案 0（built-in） | 方案 A（registry） | 方案 B（server instructions） | 方案 C（initialize.instructions） | 方案 D（MCP prompts） |
|:---|:---|:---|:---|:---|:---|
| 解決「模型不叫」 | ✅（需 prompt） | ✅ | ✅ | ✅ | ✅ |
| 解決「預設全體可用」 | ✅ | ❌ | ❌ | ❌ | ❌ |
| 不依賴助手綁定／連線 | ✅ | ❌ | ❌ | ❌ | ❌ |
| 需要 migration／備份 | ✅ 需要 | ❌ | ❌ 不需要（JSON 向後相容） | ❌ | ❌ |
| 需要新設定／UI | ✅ 需要 | ❌ | ✅ 需要 | ❌ | ⚠️ 可選 |
| 需要改 vendored dependency | ❌ | ❌ | ❌ | ✅ 需要 | ❌ |
| 每助手粒度 | ❌ 全域 | ✅ 保留 | ✅ 保留 | ✅ 保留 | ✅ 保留 |
| 第三方 server 適用 | ❌ | ⚠️ 需逐工具加 registry | ✅ | ✅ | ✅ |
| 實作成本 | 高（1–1.5 天） | **低（2–4 小時）** | 中 | 中高 | 中高 |
| 主要風險 | 同名工具、遷移、備份相容 | 覆蓋率仍受 MCP 綁定限制 | 不可信文字、UI 複雜 | patch 依賴、server 級粒度 | overkill、額外 roundtrip |

---

## 9. 建議與決策路徑

### 9.1 只為提高呼叫率

選 **方案 A**：

- 新增 `McpToolPrompts`（policy 文字）。
- 精簡 `image_search_server.dart` 的 description。
- 在 `message_generation_service` 的 `toolDefs` 之後注入。
- 加測試與手動 smoke。

### 9.2 要讓所有使用者預設可用

先做 **方案 A** 驗證 prompt 效果，再做 **方案 0**：

- A 的 `McpToolPrompts` 可直接被 built-in 的 `ImageSearchTool.getPrompt()` 重用。
- 方案 0 的 migration 與 settings/UI 是主要成本。
- 兩者不衝突；先 A 後 0 可以降低一次改太大的風險。

### 9.3 要讓任意 MCP server 自帶說明

- 產品化選 **方案 B**（使用者可編輯、隨備份）。
- 協定化選 **方案 C**（server 作者可提供，但需 patch client）。
- 方案 D 只有在「要讓使用者手動呼叫 prompt」時才有額外價值。

---

## 10. 共通風險與陷阱

### 10.1 同名工具衝突

Built-in tool 與第三方 MCP server 的同名工具同時被廣告 → OpenAI/Claude 可能拒絕請求或行為不可預測。更名為 `illustrate` 後衝突風險大幅降低（第三方幾乎不可能同名）；方案 0 若保守仍可在 `buildToolDefinitions` dedupe；方案 A 不需要，因為只有 MCP 一份。

### 10.2 Gemini 原生工具抑制

`google_search` / `url_context` / `code_execution` / `youtube` 任一開啟時，`chat_api_service` 會整包丟掉 `function_declarations`。Tool 與 prompt 都要 gate 在 `!hasGeminiBuiltInTools`。

### 10.3 Test doubles 的 `NoSuchMethodError`

`native_fetch_gating_test.dart`、`web_fetch_registry_test.dart` 的 fake `SettingsProvider` 只實作部分 getter。方案 0 直接讀 `settings.imageSearchEnabled` 會炸；要更新 doubles，或照 `_shellToolReady` / `ChatTurnService` 的 `try/on NoSuchMethodError` 風格加 tolerant helper。

### 10.4 Prompt 過度觸發

不設硬上限後，更容易出現「每篇都插圖」。用以下規則降噪：

- 先確認回傳 `title` 與目標主體相符，否則不要用。
- 同一輪不重複搜尋同一主體。
- 答案本身已夠清楚就不要為了視覺效果呼叫。
- 找不到合適結果就略過，不要硬湊。
- 用 3–4 個模型手動 smoke，觀察呼叫率與圖片正確率。

### 10.5 現有引擎的可靠性問題（所有方案都適用）

| 問題 | 現況 | 建議 |
|:---|:---|:---|
| 最壞延遲 | DDG 10s + Wikimedia 12s + 5 次 HEAD × 5s ≈ 47s | HEAD 並行（3–4 併發）、總 timeout 15–20s、加 in-memory TTL cache |
| Wikimedia fallback 條件 | 只在 `ddgRaw.isEmpty` 才查 Commons；DDG 有結果但全部 HEAD 失敗時不 fallback | 改成「validated hits 為空就試 Commons」 |
| SSRF | `_isImageUrl()` 只檢查 scheme，對任意 http(s) URL 發 HEAD | 重用 `SsrfGuard` 或至少檢查私有網段／loopback |
| `max_results` 不一致 | 預設 10，但只驗證前 5 筆 | schema 改 default 5 / max 5，或明確註明只驗證前 5 |
| 縮圖熱鏈 | HEAD 200 不代表 Flutter 端一定載得到 | 保留 `errorBuilder`；必要時優先 Wikimedia／原圖 fallback |

### 10.6 遷移順序

`applyLegacyImageSearchMigration()` 必須在 `SettingsProvider` load **之前**執行；否則 SettingsProvider 先讀到預設值，遷移值永遠進不了 UI。備份還原後也要再跑一次。

### 10.7 `McpProvider.hasAnyEnabled` 的 UI 副作用

移除 `Illustrate` 後，只綁 image 的使用者會發現輸入列 MCP 按鈕消失。這是正確行為（他們已改用 built-in），但要在 release note 說明。

### 10.8 新→舊備份不相容

新版本備份還原到舊版本時，舊版只認 MCP entry，image 功能會消失。這是可接受的單向相容，release note 說明即可。

### 10.9 Tool card / export 的重複 switch

`chat_message_widget.dart` 的 `_iconFor` / `_titleFor` 與 `message_export_sheet.dart` 都有 tool-name switch；方案 0 要同步加 `illustrate`，否則卡片顯示 generic Wrench／標題。

### 10.10 `web_fetch_migration_test.dart` 會壞

它的 fixture 目前包含 `image_search` 並斷言 `enabled == true`；方案 0 要改成「legacy image entry 被移除 + `image_search_enabled_v1` 被寫入」。

---

## 11. 測試計畫

### 11.1 方案 A

- `McpToolPrompts.forDefinitions()` 純函式測試（有／無／重複／非 function）。
- 組裝整合測試：image tool 被廣告 → system message 含政策；未廣告 → 不含。
- Gate 測試：tool toggle 關閉、server 未連線、`supportsTools=false`、Gemini built-ins。
- 手動 smoke：Claude / GPT / Gemini / DeepSeek；單主體、多主體、抽象概念、程式碼。

### 11.2 方案 0

- `ImageSearchTool`：definition／prompt／execute（用 `ddgsOverride`）。
- `applyLegacyImageSearchMigration`：legacy entry、disabled、無 key 預設、idempotent、JSON import path。
- `buildToolDefinitions`：image gating、同名 dedupe（更名後風險極低，可作保守測試）、非 tool model。
- `buildToolCallHandler`：built-in branch、disabled → `tool_disabled`、不落到 MCP fallback。
- 更新 `web_fetch_migration_test.dart` 與 fake settings。
- `flutter analyze` + targeted `flutter test`。

### 11.3 方案 B／C／D

- B：`McpServerConfig` JSON round-trip、instructions 注入 gating、UI 儲存。
- C：patched `InitializeResult` 解析、`connect()` 快取、注入 gating。
- D：`prompts/list` / `prompts/get` engine 測試、快取與注入。

---

## 12. 待決事項

1. 方案 A 上線後，是否保留 tool description 的「何時用」摘要，或完全只留 identity／參數／URL 規則？（本文定案為後者）
2. 是否要在同一批修正 §10.5 的可靠性問題？（建議是）
3. 是否需要 per-assistant opt-out（例如某些助手永遠不要圖片）？
4. 方案 B 的 `instructions` 欄位是否要對第三方 MCP server 開放編輯？若開放，是否需要長度上限與「不可信內容」警告？
5. 方案 C 是否值得 patch vendored `mcp_client`，或等上游支援？

---

## 13. 附錄：程式碼位置

| 檔案 | 相關符號／職責 |
|:---|:---|
| `lib/core/services/mcp/image_search/image_search_server.dart` | `ImageSearchMcpServerEngine`、`_toolDefinitions()`、`_imageSearch()`、`renderImageSearchResult()`、`ImageSearchInMemoryClientTransport` |
| `lib/core/providers/mcp_provider.dart` | `McpServerConfig`、`McpToolConfig`、`_ensureBuiltinImageSearchServerPresent()`、`connect()`、`refreshTools()`、`setToolEnabled()`、`getEnabledToolsForServers()`、`applyLegacyFetchMigration()` |
| `lib/core/services/mcp/mcp_tool_service.dart` | `listAvailableToolsForAssistant()`、`callToolTextForAssistant()` |
| `lib/features/home/services/tool_handler_service.dart` | `buildToolDefinitions()`、`buildToolCallHandler()`、`sanitizeToolParametersForProvider()` |
| `lib/features/home/services/message_generation_service.dart` | prompt 注入順序、`toolDefs` 組裝（約 339 行） |
| `lib/features/home/services/message_builder_service.dart` | `injectSystemPrompt()`、`injectSearchPrompt()`、`appendToSystemMessage()`、`applyContextLimit()` |
| `lib/core/services/api/chat_api_service.dart` | Gemini function declarations 與 built-ins 互斥（約 6092 行） |
| `lib/core/services/chat/chat_turn_service.dart` | voice path：只廣告 `search_web` |
| `lib/core/services/search/search_tool_service.dart` | `getSystemPrompt()`：既有的 prompt 注入先例 |
| `lib/core/services/web/web_fetch_tool.dart` | `getToolDefinition()`、`canonicalToolName()`：built-in tool 先例 |
| `lib/features/chat/widgets/chat_message_widget.dart` | `_iconFor()`、`_titleFor()` |
| `lib/features/chat/widgets/message_export_sheet.dart` | tool-name switch（匯出） |
| `lib/core/services/tools/tool_result_caps.dart` | `cap()`、`_guidanceFor()` |
| `lib/main.dart` | `applyLegacyFetchMigration()` 啟動位置（image migration 比照） |
| `lib/core/services/backup/data_sync.dart` | 備份還原後的 migration 位置 |
| `test/image_search_server_test.dart` | 既有 engine 測試 |
| `test/web_fetch_migration_test.dart` | 需更新的 legacy MCP migration 測試 |

---

## 14. 參考資料

- MCP Lifecycle（`InitializeResult.instructions`）：<https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle>
- MCP Server Instructions 官方部落格：<https://blog.modelcontextprotocol.io/posts/2025-11-03-using-server-instructions/>
- 專案內既有先例：
  - `docs/` 的 `web_fetch` 遷移（`McpProvider.applyLegacyFetchMigration()`）
  - `lib/core/services/search/search_tool_service.dart` 的 `getSystemPrompt()`
  - `lib/features/home/services/message_builder_service.dart` 的 `appendToSystemMessage()`
- 手冊：`OmniChat 專案開發與維護手冊.md` §3.13（Image Search）、§3.16（Web Fetch）

---

## 15. 補充：上下文負擔與輸入框 toggle（2026-11-09）

### 15.1 量測基準

以目前工作樹的 `image_search` 定義與 §2.3.2 政策文字計算（minified JSON，UTF-8 字元數）；精簡 description 與各政策採 2026-11-10 的「images」措辭版：

| 元件 | 字元數 | 說明 |
|:---|--:|:---|
| 現行 tool description | 985 | `image_search_server.dart` 的 `_toolDefinitions()` |
| 現行完整 tool definition | 1,399 | name + description + parameters（minified JSON） |
| 精簡後 tool description | 468 | §2.3.1（2026-11-10「images」措辭版） |
| 精簡後完整 tool definition | 946 | 同上 |
| 詳細政策（§2.3.2） | 1,467 | 231 words |
| 精簡政策（§15.6） | 728 | 109 words |
| 超精簡政策（§15.6） | 587 | 84 words |

Token 估計：英文 prose 約 4 chars/token；JSON/schema 約 3–3.5 chars/token。以下為範圍估計，實際依 provider tokenizer 而異（約 ±10–15%）。

### 15.2 每次請求的固定負擔

| 情境 | 每次請求字元數 | 估計 tokens | 相對現行 |
|:---|--:|--:|--:|
| 現行（只有 tool definition） | 1,399 | ~380–450 | 0 |
| 精簡 description + 詳細政策 | 2,415 | ~620–740 | +245–285 |
| 精簡 description + 精簡政策 | 1,676 | ~420–500 | +45–55 |
| 精簡 description + 超精簡政策 | 1,535 | ~390–460 | +10–20 |
| 現行 description + 詳細政策 | 2,868 | ~740–870 | +355–420 |
| 現行 description + 精簡政策 | 2,129 | ~540–620 | +155–195 |

占上下文窗口比例（約）：

| 情境 | 8k | 32k | 128k | 200k |
|:---|--:|--:|--:|--:|
| 現行 | 4.6–5.5% | 1.2–1.4% | 0.3% | 0.2% |
| 精簡 + 詳細 | 7.6–9.0% | 1.9–2.3% | 0.5–0.6% | 0.3–0.4% |
| 精簡 + 精簡 | 5.1–6.1% | 1.3–1.5% | 0.3–0.4% | 0.2% |
| 現行 + 詳細 | 9.0–10.6% | 2.3–2.7% | 0.6% | 0.4% |

**解讀**：

- 對 128k 以上的模型，固定負擔不到 1%，主要成本是使用者體驗（是否要多圖）與 tool result 累積。
- 對 8k–16k 的模型，5–10% 不是小數目；若還要多主體多次呼叫，感受會更明顯。
- 因此**輸入框 toggle 是合理的**，尤其是行動端與小上下文模型。

### 15.3 Tool result 的額外負擔

固定負擔之外，每次呼叫會把結果寫進 conversation history：

- `renderImageSearchResult()` 最多 5 筆（`validateLimit = 5`），每筆含 title、兩個 URL、source、author/license、backend。
- 估計每次呼叫約 250–450 tokens；多主體 3–5 次呼叫約 750–2,000 tokens。
- 這些結果會留到 compaction 才消失；長對話中通常比 instruction 本身更大。

所以「關閉 image search」的價值不只是省 tool definition，而是避免模型主動產生這些 tool result。

### 15.4 Prompt caching 的影響

- Claude（Anthropic／OpenRouter）啟用 prompt caching 時，`cache_control` 會掛在 system/tools；穩定的 image prompt 有機會被快取。
- OpenAI 自動前綴快取、Gemini 隱式快取也會降低重複前綴的成本。
- 但**快取只降成本，不降 context 佔用**；而且 `write_todos` 等會變動 system tail 的功能可能讓 cache 前綴失效。
- 目前建議的 post-`toolDefs` 注入會把 image prompt 放在 todo snapshot 之後；若 cache 成本敏感，可考慮改在 `injectTodoSnapshot` 之前注入，但那需要一個輕量 predicate，會增加耦合。現階段不建議為此犧牲「注入與 toolDefs 同源」。

### 15.5 建議：toggle 放哪裡

**分流處理，不要重複做兩套 toggle：**

| 路線 | 現況 | 建議 |
|:---|:---|:---|
| **MCP（A/B/C/D）** | 輸入框已有 MCP 按鈕：桌面 `showDesktopMcpServersPopover`、行動 `showAssistantMcpSheet`；`Illustrate` 只有一個 tool，server/tool toggle 就等同 image search toggle | **沿用既有 MCP toggle，不新增專用 toggle**。需要的話只調整 tooltip／圖示，讓使用者知道它是 image search |
| **Built-in（方案 0）** | built-in tool 不會出現在 MCP sheet | **新增專用輸入框 toggle**（`Lucide.Image`），或至少提供一鍵入口；否則使用者只能進設定頁關閉 |

理由：

1. 8k–32k 模型上固定負擔有意義（5–6% / 1.3–1.5%）。
2. Tool result 會累積，多主體答案可能再加 1–2k tokens。
3. 圖片是「有主觀偏好」的功能；使用者可能只想在特定對話要圖。
4. 關閉時可以做到 0 負擔（tool + prompt 同時移除）。

#### MCP 路線的注意事項

- 既有 MCP toggle 是 **per-assistant**（`assistant.mcpServerIds`），不是 per-conversation；切換會影響所有使用該助手的對話。若產品需要「同一助手、不同對話」的差異，才需要另外做 per-conversation override。
- `Illustrate` 只有一個 tool，所以 server-level toggle 與 tool-level toggle 效果相同；若未來加第二個 tool，才需要區分。
- 若同時做 built-in 專用 toggle 與 MCP toggle，兩者不要互相覆寫；built-in 路線移除 MCP server 後，MCP toggle 自然消失。

#### Built-in 路線的 toggle 設計

- **全域預設**：`image_search_enabled_v1`（預設 ON），設定頁可改。
- **輸入框 toggle**：`ChatInputBar` 的 `_CompactIconButton`，圖示 `Lucide.Image`，active tint 與 search 一致；窄螢幕可放進既有 overflow menu／`ChatInputButtonCatalog`。
- **per-conversation override（可選）**：若要「同一助手、不同對話」的差異，避免 SQLite schema migration 的做法是用 SharedPreferences 的 `StringList`（例如 `image_search_disabled_conversations_v1`），在刪除對話／清除資料時 prune；若要進 conversation model，則需 SQLite/Hive migration，成本較高。
- **顯示條件**：只要模型支援 tools 就顯示；停用時圖示轉灰。
- **防禦**：toggle 關閉後，若模型仍送出 stale call（`illustrate` 或 legacy `image_search`），handler 要回 `tool_disabled`，不要真的執行。

#### 共通 Gating 契約

```text
effectiveImageSearch =
    imageSearchAvailable          // MCP: server selected + connected + tool enabled
                                  // built-in: settings.imageSearchEnabled (+ conversation override)
    && supportsTools
    && !hasGeminiBuiltInTools
```

- `buildToolDefinitions`：effective 為 false 時，built-in 不加 definition；MCP 則過濾掉 `illustrate`（server id 仍為 `image_search`，見 §15.9）。
- `McpToolPrompts.forDefinitions`：看不到 `illustrate` → 不注入 prompt。
- **永遠不要**只關 tool 或只關 prompt；兩者必須同進同出。

### 15.6 精簡政策文字（建議搭配 toggle 使用）

```text
## illustrate usage
Use illustrate when the answer benefits from images of concrete subjects (people, products, landmarks, artworks, animals, places). Do not use it for abstract concepts, code, math, definitions, opinions, or decorative filler.
Insert as many images as the answer genuinely needs: usually one per distinct subject; never repeat an image or query; omit a subject if no relevant result exists; never add images just to fill space.
Use only returned URLs; verify the title matches the subject; prefer thumbnail_url; embed as ![alt](url) right after the relevant sentence; mention source/author/license when appropriate; if the tool fails or returns nothing useful, continue without images and retry at most once.
```

（728 chars / 109 words，約 160–190 tokens。）

超精簡版（587 chars / 84 words，約 120–150 tokens）：

```text
## illustrate usage
Use illustrate only when images of concrete subjects (people, products, places, artworks, animals) materially improve the answer; skip abstract concepts, code, math, definitions, opinions, and decorative filler.
Insert as many images as needed, usually one per distinct subject; never repeat an image or query; omit subjects with no good result.
Use only returned URLs; verify the title matches; prefer thumbnail_url; embed as ![alt](url) after the relevant sentence; cite source/license when appropriate; on failure, continue without images and retry at most once.
```

### 15.7 決策建議

| 情境 | 建議 |
|:---|:---|
| MCP 路線（已有輸入框 MCP toggle） | 用「精簡 description + 精簡政策」；沿用既有 toggle；總負擔 ~420–500 tokens；關閉 = 0 |
| Built-in 路線（需新增專用 toggle） | 用「精簡 description + 精簡政策」；新增 `Lucide.Image` toggle；關閉 = 0 |
| 沒有 toggle、但想最大化遵循率 | 用「精簡 description + 詳細政策」；總負擔 ~620–740 tokens |
| 只有 128k+ 模型、且使用者已明確開啟 | 「現行 description + 詳細政策」也可接受（~740–870 tokens） |
| 8k–16k 模型 | 強烈建議 toggle；必要時預設 OFF，由使用者按需開啟 |

### 15.8 精簡 policy 犧牲了什麼

| 內容 | 詳細政策 | 精簡政策 | 影響 |
|:---|:---|:---|:---|
| 「whose appearance matters」 | ✅ | ❌ | 最大的差異：少了「外觀是否重要」這個篩選，容易對任何具體名詞都插圖 |
| 「or the user asks for pictures」 | ✅ | ❌ | 使用者明確要圖時，模型可能忽略 |
| 「identification / comparison / visual reference」 | ✅ | ❌ | 少了「圖片為何有幫助」的例子，判斷較粗 |
| 「notable objects」 | ✅ | ❌ | 物件類主體覆蓋略減 |
| 「purely textual answers」 | ✅ | ❌ | 與 abstract/code/math/definitions 重疊，影響小 |
| 「A single subject usually needs one image」 | ✅ | ⚠️ 以「one per distinct subject」概括 | 影響小 |
| 「comparison or list may need one per subject」 | ✅ | ⚠️ 概括 | 多主體仍可推得 |
| 「never invent or guess」 | ✅ | ⚠️ 以「only returned URLs」概括 | 影響小 |
| 「use image_url for the original」 | ✅ | ❌（仍在 description） | 影響小 |
| 「for Wikimedia results」 | ✅ | ❌ | 影響小 |
| Section headers / bullets | ✅ | ❌ | 結構提示變弱；弱模型較容易漏掉「when not」 |
| 字元數 / tokens | 1,467 / ~350–400 | 728 / ~160–190 | 省約 50% |

**真正的風險**：不是少數幾個字，而是 **「何時不該用」與「外觀是否重要」的約束被壓縮**。如果模型本來就偏愛插圖，精簡版可能讓「每篇都插圖」更嚴重。

**建議的中間版本（759 chars / ~190–220 tokens）**：保留高價值約束，仍比詳細版省約 48%：

```text
## illustrate usage
Use illustrate when the answer involves concrete subjects whose appearance matters (people, products, landmarks, artworks, animals, places), an image would materially help (identification, comparison, visual reference), or the user asks for pictures.
Do not use it for abstract concepts, code, math, definitions, opinions, or decorative filler.
Use as many images as the answer needs: usually one per distinct subject; never repeat an image or query; omit subjects with no good result; never add images just to fill space.
Use only returned URLs; verify the title matches the subject; prefer thumbnail_url; embed as ![alt](url) after the relevant sentence; cite source/license; on failure, continue without images and retry at most once.
```

> 若實測發現模型仍然過度插圖，再從中間版本加回 bullet headers 或「do not retry」等細節；不建議一開始就用最精簡版。

### 15.9 工具命名：illustrate（2026-11-09 定案）

**候選與取捨**：

| 候選 | 評語 |
|:---|:---|
| `add_images` | 效果導向次優；與 `image_generation` 區隔明確，但字面像「工具替你加圖」 |
| `illustrate_with_photos` | 最精確但最長（22 字元） |
| `insert_images` / `include_images` | 語意相近但觸發較弱 |
| `get_photos` / `fetch_photos` | 機制準確、目的弱；觸發情境全靠 description |
| **`illustrate`（定案）** | 目的導向「為回答配圖」，最短；生成歧義由 description／policy 雙重緩解 |

避免的方向：`generate/create_image`（與 provider 原生 `image_generation` 撞車）、`download/save`（不落地檔案）、`embed_*`（vector embeddings 誤導）、任何 `search` 變體（即要擺脫的機制命名）。

**歧義緩解**（`illustrate` 可能被解讀為生成插畫或「舉例說明」）：

- description 與 policy 都錨定「web 檢索」："Search the web for images..."（§2.3.1）、"searches the web and returns ... matching images"（§2.3.2）——工具找的是網路上既有的圖片，不是生成。
- policy 第一句列舉回傳類型（photographs, artworks, diagrams, logos 等），明確範圍是任意網路圖片，不限定真實照片。
- 詳細版的 when-not 清單（abstract concepts／decorative filler）排除與主體無關的裝飾圖；logo／圖表在「問題本身與其相關」時是合理目標，不預先排除。
- 若實測仍出現生成類請求，再在 policy 加回 "Never present generated or placeholder images"。

**範圍（最小遷移）**：

- 只改 model-facing tool 名稱：`ImageSearchMcpServerEngine.toolName = 'illustrate'`。
- MCP server id `image_search` **維持不變**、顯示名改為 `Illustrate` → `assistant.mcpServerIds` 綁定與 persisted id 零遷移；只做一次顯示名 migration。
- `tools/list` 只廣告 `illustrate`；`tools/call` 同時接受 `illustrate` 與 legacy `image_search`（engine 內 alias，比照 §3.16 `web_fetch` 舊名別名模式）。
- `McpToolService` 的 server/tool 比對在「目標 server 為內建 `image_search`」時接受舊名 → 新名（scoped，避免綁架第三方同名工具）；純全域 canonicalize（`WebFetchTool.canonicalToolName` 式）在「使用者另有第三方 server 也叫 `image_search`」時有誤路由風險。
- 本文 §1 的 `image_search` 指現況名稱；實作後 model-facing 名稱為 `illustrate`。
- 更名使各政策文字每處 `image_search` → `illustrate` 減 2 字元；§15 的字元數統計誤差 ≤ 4 chars，可忽略。

**要同步更新的檔案**：

- `lib/core/services/mcp/image_search/image_search_server.dart`：`toolName` 常數、alias branch、description。
- `test/image_search_server_test.dart`：名稱斷言 + alias 測試。
- `lib/core/services/agent/answer_review.dart`：兩處以 `image_search` 為例的提示（行 190 註解、行 297 review prompt）→ 改 `illustrate`。
- `McpToolPrompts` registry key 與政策標題（§4.2）。
- `README.md`／`README_ZH_TW.MD` 各 2 處。
- l10n／工具卡目前無專屬字串；若之後加友善標題（`_titleFor`），中文名建議「配圖」。
- 未來若走方案 0：built-in handler 以 `illustrate` 為主、`image_search` canonicalize（`WebFetchTool.canonicalToolName` 模式）。
