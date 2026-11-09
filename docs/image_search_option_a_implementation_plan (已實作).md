# image_search 方案 A 實作計畫：`illustrate` 改名 + prompt 注入 registry

> **版本**：v1.0（2026-11-10）
> **狀態**：✅ 已實作（2026-11-10；自動化測試通過，手動 smoke 待執行）
> **上游評估**：`docs/image_search_builtin_vs_mcp_prompt_plan.md`（方案 A＝§4、命名定案＝§15.9、上下文負擔＝§15、可靠性問題＝§10.5）
> **範圍**：engine 改名與精簡 description、內建 tool-name 遷移、legacy 名稱路由、`McpToolPrompts` registry、system-prompt 注入點、answer-review／README 文字、引擎可靠性修正、測試
> **非目標**：不新增設定鍵或 UI；不做 built-in 化（方案 0）；不動 MCP server id／顯示名（`image_search`／`Image_Search`）；不動 voice path；不新增 l10n；不移除 in-memory MCP server
> **預估工作量**：約 1 天（MVP＝Step 1–6 約 0.5 天；Step 7 可獨立 PR 但建議同批）

---

## 0. 定案摘要（沿襲評估文件，不再重新辯論）

| 項目 | 決策 |
|:---|:---|
| 工具名稱 | model-facing 名稱改為 **`illustrate`**（目的導向「為回答配圖」；§15.9）。MCP server id `image_search`、顯示名 `Image_Search` **維持不變** → 綁定與 persisted JSON 零結構遷移 |
| Description | 精簡為 468 字元版（評估文件 §2.3.1，2026-11-10「images」措辭），只留 identity／參數／結果格式／URL 規則 |
| 使用政策 | **中間版 policy（759 字元，約 190–220 tokens）**放入 system prompt（§15.8 推薦版；保留「appearance matters」「user asks for pictures」「identification/comparison」三個高價值約束） |
| 圖片張數 | **不設硬上限**：每個不同主體一張、不重複、不裝飾、找不到就略過 |
| Toggle | 沿用既有輸入框 MCP toggle（`Image_Search` 只有一個 tool，server/tool toggle 等同本工具開關）；**不新增**輸入框按鈕 |
| 上下文負擔 | 總固定負擔 ~430–510 tokens／請求（現行 ~380–450；精簡定義 946 + 中間版 759 ≈ 1,705 chars），**淨增約 +50–60 tokens**；關閉 toggle 時 tool 與 prompt 同時消失，負擔為 0 |
| 可靠性 | 與本計畫**同批**修正評估文件 §10.5 的引擎問題（Wikimedia fallback 條件、HEAD 並行、總 timeout、SSRF、max_results 描述） |

為什麼是方案 A 而不是 0／B／C／D：見評估文件 §8 比較表與 §9 決策路徑。一句話——它用最小改動（1 個新檔案 + 1 個呼叫點 + 改名）直接解決「模型看得到但不叫」的已證實問題，且不需要 migration schema、新設定或 UI。

---

## 1. 目標與成功標準

| # | 目標 | 驗收方式 |
|:--|:---|:---|
| G1 | 模型更穩定地主動呼叫工具 | 手動 smoke：4 模型 × 4 情境矩陣（§11.4），呼叫率與圖片正確率較現行有可觀察改善 |
| G2 | tool 與 prompt 同進同出 | 廣告 `illustrate` 才注入 policy；toggle 關閉／未綁定／未連線／Gemini built-ins 時兩者都缺席（§11.2、§11.4） |
| G3 | 既有對話不中斷 | 舊對話（歷史含 `image_search` tool_calls）續聊正常；stale call 有正確結果或明確錯誤，不會拿到空字串 |
| G4 | 使用者的開關狀態在升級後保留 | 曾把 `image_search` tool 關閉的使用者，升級後 `illustrate` 維持關閉（§5） |
| G5 | 最壞延遲可控 | 單後端路徑 ≈ 12s、fallback 路徑 ≈ 20s 內（現行最壞 ≈ 47s） |

---

## 2. Gating 契約（本計畫的不變式）

```text
policyInjected  ⟺  toolDefs 含 'illustrate'      ← 唯一真相：buildToolDefinitions() 的輸出
                    && !hasBuiltInSearch           ← 明列的例外（見下）
```

由 `toolDefs` 自動反映的 gates（不需要額外 predicate）：

| Gate | 機制 |
|:---|:---|
| 模型不支援 tools | `buildToolDefinitions` 內 `supportsTools == false` → MCP defs 為空 |
| MCP server 沒綁助手 | `listAvailableToolsForAssistant` 只回 `assistant.mcpServerIds` 內的 server |
| Server 沒連上 | `getEnabledToolsForServers` 只回 `McpStatus.connected`（`mcp_provider.dart:1504`） |
| Tool toggle 關閉 | 同上，只回 `t.enabled` |
| MCP 按鈕關閉整個 server | `s.enabled == false` → 不列入 |

**明列的例外——Gemini 原生 built-ins**：`buildToolDefinitions` 把 MCP tools 加入 `toolDefs` 時**不看** `hasBuiltInSearch`（`tool_handler_service.dart:263–270` 只 gate `supportsTools`）；Gemini 的 `function_declarations` 整包剝除發生在**組裝之後**的 `chat_api_service.dart`（約 6092／6477 行，built-ins 與 function declarations 互斥）。因此注入點必須自行補上 `!hasBuiltInSearch`，否則會出現「system prompt 叫模型用 `illustrate`，但請求的 tools 陣列是空的」。這是本計畫對評估文件 §4.3 表格的一處修正。

---

## 3. 變更總覽

| # | 檔案 | 變更 | 類型 |
|:--|:---|:---|:---|
| 1 | `lib/core/services/mcp/image_search/image_search_server.dart` | `toolName` 改 `illustrate`、legacy alias、精簡 description、doc comment 措辭、可靠性修正（Step 7） | 修改 |
| 2 | `lib/core/providers/mcp_provider.dart` | 內建 tool-name 遷移 `migrateBuiltinImageSearchToolName()`（靜態，比照 `applyLegacyFetchMigration`） | 修改 |
| 3 | `lib/core/services/mcp/mcp_tool_service.dart` | legacy 名稱 scoped 路由（`callToolTextForAssistant`） | 修改 |
| 4 | `lib/core/services/mcp/mcp_tool_prompts.dart` | tool-name → policy registry（**新檔案**） | 新增 |
| 5 | `lib/features/home/services/message_generation_service.dart` | `toolDefs` 之後注入 policy（約 375 行後） | 修改 |
| 6 | `lib/core/services/agent/answer_review.dart` | 兩處範例名稱 `image_search` → `illustrate`（190、297 行） | 修改 |
| 7 | `README.md`／`README_ZH_TW.MD` | 各 2 處工具名稱（137 行附近） | 修改 |
| 8 | `test/image_search_server_test.dart` | 更名斷言、alias 測試、fallback／SSRF 測試 | 修改 |
| 9 | `test/mcp_tool_prompts_test.dart` | registry 純函式測試（**新檔案**） | 新增 |
| 10 | `test/image_search_tool_rename_migration_test.dart` | 遷移測試（**新檔案**，比照 `web_fetch_migration_test.dart` 風格） | 新增 |

不改的檔案（明確列出以免擴散）：`tool_handler_service.dart`（MCP defs 與 fallback 已足夠）、`chat_turn_service.dart`（voice path 本來就不廣告 MCP tools）、`chat_message_widget.dart`／`message_export_sheet.dart`（MCP 工具卡已走通用路徑）、`tool_result_caps.dart`（現行 MCP 工具就沒有專屬 guidance，維持現狀）、l10n（無新字串）。

---

## 4. Step 1 — Engine：改名、legacy alias、精簡 description

檔案：`lib/core/services/mcp/image_search/image_search_server.dart`

### 4.1 常數

```dart
static const String serverName = 'Image_Search'; // 不變（MCP 頁顯示名）
static const String toolName = 'illustrate';     // 2026-11-10 定案（評估文件 §15.9）

/// Legacy model-facing name. Never advertised by tools/list; accepted by
/// tools/call (and by McpToolService routing) so stale model calls from old
/// conversations keep working — same pattern as WebFetchTool legacy names.
static const String legacyToolName = 'image_search';
```

### 4.2 `tools/call` 接受兩個名稱

`_handleSingle()` 的 `methodCallTool` switch（約 88–96 行）：

```dart
switch (name) {
  case toolName:
  case legacyToolName:
    return _ok(id, result: await _imageSearch(arguments));
  default:
    return _error(id, code: -32101, message: 'Tool not found: $name');
}
```

`tools/list` 不變，仍只輸出 `_toolDefinitions()` → 只廣告 `illustrate`。

### 4.3 精簡 description（468 字元版，取代現行 985 字元版）

`_toolDefinitions()` 整段換成：

```dart
List<Map<String, dynamic>> _toolDefinitions() {
  return [
    {
      'name': toolName,
      'description':
          'Search the web for images and return direct image URLs.\n'
          '\n'
          'Results are JSON: items[] with index, title, image_url, thumbnail_url, '
          'source_url, author, license, backend.\n'
          '\n'
          'Rules:\n'
          '- Only use URLs returned by this tool. Never invent or guess an image URL.\n'
          '- Embed each image as ![alt](<url>) immediately after the sentence it illustrates.\n'
          '- Prefer thumbnail_url for embedding; image_url is the original.\n'
          '- A maximum of 5 validated URLs are returned regardless of max_results.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'query': {
            'type': 'string',
            'description':
                'Concrete search query for the image you need, e.g. '
                '"Ada Lovelace portrait" or "iPhone 15 Pro product photo".',
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
  ];
}
```

要點：

- 「何時用／何時不用／要幾張」全部移出 description，搬到 `McpToolPrompts`（Step 4）——這是評估文件的定案分工，避免同一套規則付兩次 token。
- 移除現行 description 對 "logos, icons, charts" 的一律排除：工具回傳的是任意網路圖片，當問題本身就是問 logo／圖表外觀時應該要找得到圖；「何時不用」由 system prompt 政策以「與主體無關的裝飾圖」表述。
- `max_results` 描述同時完成 §10.5 的「只驗證前 5 筆」揭露（`clampImageMaxResults` 行為不變，1–15、預設 10）。
- 順手修正檔頭 doc comment 的過時措辭："exposing a real-photo image search tool" → "exposing a web image search tool"；用途註解的 "**real** images" 改為 "images found on the web"。

---

## 5. Step 2 — McpProvider：內建 tool-name 遷移

### 5.1 為什麼需要（`refreshTools()` 的合併行為）

`mcp_provider.dart:1282–1345` 的 `refreshTools()` 以 **tool name** 對齊既有設定：

```dart
final prior = existingMap[t.name];
...
merged.add(McpToolConfig(
  enabled: prior?.enabled ?? true,   // ← 新名稱查無 prior → 預設開啟
  ...
));
```

且 `merged` 完全由新的 `tools/list` 輸出重建（persisted 的舊名 entry 會被丟棄）。後果：

- engine 改名後，第一次連線會產生一個 **enabled 預設為 true** 的 `illustrate` entry；
- **曾把 `image_search` tool 關閉的使用者會被靜默重新開啟**（G4 違約）。

server id 不變，所以 `assistant.mcpServerIds` 綁定不需要任何處理；要修的只有「tool entry 改名時保留 enabled」。

### 5.2 實作（`mcp_provider.dart`，比照 `applyLegacyFetchMigration` 的形狀）

```dart
/// One-time rename of the built-in image search tool entry persisted under
/// `mcp_servers_v1` (2026-11-10: `image_search` → `illustrate`, 見
/// docs/image_search_option_a_implementation_plan.md §5).
///
/// `refreshTools()` merges by tool name and defaults NEW tools to
/// `enabled: true`, so without this migration a user who had the old tool
/// toggled OFF would silently get it re-enabled after the rename. Scoped to
/// the built-in server by id (`image_search`) — a write operation, so use
/// the canonical key alone (tighter than `_ensureBuiltinImageSearchServerPresent`'s
/// id-or-name read predicate) so third-party servers are never touched.
/// Idempotent; writes prefs only when something changed.
static Future<void> migrateBuiltinImageSearchToolName() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(_prefsKey);
  if (raw == null || raw.isEmpty) return;

  final List<dynamic> list;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return;
    list = decoded;
  } catch (_) {
    return;
  }

  var changed = false;
  for (final item in list) {
    if (item is! Map) continue;
    final server = item.cast<String, dynamic>();
    if (server['id']?.toString() != builtinImageSearchServerId) continue;
    final tools = server['tools'];
    if (tools is! List) continue;
    // If the new name is already present (hand-edited JSON import), skip:
    // renaming would create a duplicate `illustrate` entry, which gets
    // advertised twice until the next refreshTools() collapses it.
    final hasNewName = tools.any((t) =>
        t is Map &&
        t['name']?.toString() == ImageSearchMcpServerEngine.toolName);
    if (hasNewName) continue;
    for (var i = 0; i < tools.length; i++) {
      final t = tools[i];
      if (t is Map &&
          t['name']?.toString() == ImageSearchMcpServerEngine.legacyToolName) {
        tools[i] = <String, dynamic>{
          ...t.cast<String, dynamic>(),
          'name': ImageSearchMcpServerEngine.toolName,
        };
        changed = true;
      }
    }
  }
  if (!changed) return;
  await prefs.setString(_prefsKey, jsonEncode(list));
}
```

（`mcp_provider.dart` 的 `connect()` inmemory 分支已建構 engine，`ImageSearchMcpServerEngine` 應已在 import 範圍；若無則補 import。）

### 5.3 呼叫點（三處，與 `applyLegacyFetchMigration` 完全同構）

| 位置 | 現況 | 加一行 |
|:---|:---|:---|
| `lib/main.dart`（約 97 行，SettingsProvider 載入前） | `await McpProvider.applyLegacyFetchMigration();` | 後面加 `await McpProvider.migrateBuiltinImageSearchToolName();`（同樣包 try/catch） |
| `lib/core/services/backup/data_sync.dart`（約 1550 行，備份還原寫入 prefs 後） | 同上 | 同上——還原進來的舊 JSON 也要改名 |
| `lib/core/providers/mcp_provider.dart` `_load()`（335 行旁） | `_load()` 開頭呼叫 fetch migration | 加防禦性呼叫，覆蓋非 main 啟動路徑 |

另外：MCP 頁的 JSON 匯入（`mcp_json_edit_sheet.dart:60` → `replaceAllFromJson()`，`mcp_provider.dart:529`）可能寫入含舊名的 JSON——在 `replaceAllFromJson` 寫完 prefs 後也呼叫一次遷移（或在其文末直接呼叫）。

---

## 6. Step 3 — McpToolService：legacy 名稱 scoped 路由

現況：`callToolTextForAssistant()`（`mcp_tool_service.dart:146`）以 `t.name == toolName` 精確匹配，找不到就回傳**空字串**。改名後，模型模仿舊對話歷史發出的 stale `image_search` call 會拿到空結果。

修改（同檔 `callToolTextForAssistant` 內、server 匹配前）：

```dart
final servers =
    mcpProvider.connectedServers.where((s) => selected.contains(s.id)).toList();

var effectiveName = toolName;
var candidates = servers
    .where((s) => s.tools.any((t) => t.enabled && t.name == effectiveName))
    .toList();

// Scoped legacy fallback: only the built-in server accepts the pre-rename
// name `image_search` (→ `illustrate`). Third-party servers that happen to
// expose a tool with the same name are NOT hijacked.
if (candidates.isEmpty &&
    toolName == ImageSearchMcpServerEngine.legacyToolName) {
  effectiveName = ImageSearchMcpServerEngine.toolName;
  candidates = servers
      .where((s) =>
          s.id == McpProvider.builtinImageSearchServerId &&
          s.tools.any((t) => t.enabled && t.name == effectiveName))
      .toList();
}

for (final s in candidates) {
  final res = await mcpProvider.callTool(s.id, effectiveName, arguments);
  if (res == null) {
    final errMsg = mcpProvider.errorFor(s.id) ?? 'Unknown error';
    // 必須用 effectiveName：legacy call 經改名路由後，server 的 tools 清單裡
    // 只有新名 entry；用舊名 firstWhere 會丟 StateError，被外層 catch 吃掉
    // 後降級成 generic execution_error，失去 self-correcting 錯誤 JSON。
    final schema =
        s.tools.firstWhere((t) => t.name == effectiveName).schema;
    return _renderToolErrorForModel(
      serverName: s.name,
      toolName: effectiveName,
      arguments: arguments,
      errorMessage: errMsg,
      schema: schema,
    );
  }
  ... flatten content（現行邏輯不變） ...
}
```

（需補 `import 'image_search/image_search_server.dart';`；`builtinImageSearchServerId` 已是 public static 常數。）

**規則：匹配區塊內所有 `toolName` 的使用——`callTool` 參數與錯誤路徑的 `firstWhere`——一律換成 `effectiveName`。**

行為：stale call 在內建 server 上**直接執行成功**（模型拿到真實圖片 URL），而不是空字串或錯誤。選「執行」而非「回 tool_error 要求改用新名」：對模型而言零摩擦，且 engine 端本來就接受兩名（Step 1）。

可選（不阻塞）：`callToolTextForConversation()`（對話層）目前沒有接進 `buildToolDefinitions`，本次不動；若之後對話層綁定啟用，再加同樣的 fallback。

---

## 7. Step 4 — `McpToolPrompts` registry（新檔案）

`lib/core/services/mcp/mcp_tool_prompts.dart`：

```dart
import 'image_search/image_search_server.dart' show ImageSearchMcpServerEngine;

/// Per-tool usage policies injected into the system prompt AFTER
/// `buildToolDefinitions()`, keyed by the model-facing function name.
///
/// Contract (評估文件 §2.1): a policy is injected only when its tool is
/// actually advertised in this request's `toolDefs`. The ONE exception is
/// Gemini native built-ins — `chat_api_service` strips function declarations
/// AFTER assembly, so the call site must additionally gate on
/// `!hasBuiltInSearch` (see message_generation_service.dart).
abstract class McpToolPrompts {
  static const Map<String, String> _byTool = {
    ImageSearchMcpServerEngine.toolName: _imageSearchPolicy,
  };

  /// Concatenated policies for the tools actually advertised in [defs], or
  /// null when none match. Accepts both OpenAI-style
  /// `{'type':'function','function':{'name':...}}` and MCP-style
  /// `{'name':...}` shapes (same tolerance as `reviewToolNames`).
  static String? forDefinitions(List<Map<String, dynamic>> defs) {
    final blocks = <String>[];
    final seen = <String>{};
    for (final d in defs) {
      final fn = d['function'];
      final name = fn is Map
          ? (fn['name'] ?? '').toString()
          : (d['name'] ?? '').toString();
      if (name.isEmpty || !seen.add(name)) continue;
      final text = _byTool[name];
      if (text != null) blocks.add(text.trim());
    }
    return blocks.isEmpty ? null : blocks.join('\n\n');
  }

  /// 中間版政策（759 chars / ~190–220 tokens，評估文件 §15.8）。
  /// 保留高價值約束：appearance matters、user asks for pictures、
  /// identification/comparison/visual reference。張數不設硬上限。
  static const String _imageSearchPolicy = '''
## illustrate usage
Use illustrate when the answer involves concrete subjects whose appearance matters (people, products, landmarks, artworks, animals, places), an image would materially help (identification, comparison, visual reference), or the user asks for pictures.
Do not use it for abstract concepts, code, math, definitions, opinions, or decorative filler.
Use as many images as the answer needs: usually one per distinct subject; never repeat an image or query; omit subjects with no good result; never add images just to fill space.
Use only returned URLs; verify the title matches the subject; prefer thumbnail_url; embed as ![alt](<url>) after the relevant sentence; cite source/license; on failure, continue without images and retry at most once.''';
}
```

備註：

- 以 **engine 常數**為鍵（不是字面值），改名時單點生效。
- 未來若走方案 0，`ImageSearchTool.getPrompt()` 直接重用 `_imageSearchPolicy`，registry 不浪費。
- 若 smoke 觀察到過度插圖，第一個調整點是這段文字（例如加回詳細版的 bullet headers），**不是**架構。

---

## 8. Step 5 — 注入點（`message_generation_service.dart`）

位置：`final toolDefs = generationController.buildToolDefinitions(...)` 敘述句（375 行）**緊後**、write_todos drift check 之前——注入只依賴 `toolDefs`，放在離產生處最近的位置最清晰；與 `appendTodoStatePair`（user/assistant 訊息對）的先後順序對 system 內容沒有影響。

```dart
final toolDefs = generationController.buildToolDefinitions(
  settings,
  assistant,
  providerKey,
  modelId,
  hasBuiltInSearch,
  workspaceEnabled: workspaceResolution?.enabled ?? false,
  workspacePath: workspacePath,
);

// illustrate (image search) usage policy — same-source with toolDefs:
// injected only when the tool is really advertised in this request.
// Gemini native built-ins are the documented exception: chat_api_service
// strips function declarations AFTER assembly, so gate here too.
if (!hasBuiltInSearch) {
  // 純函式 + 不會丟例外的 append，不需要 try/catch。
  final toolPrompt = McpToolPrompts.forDefinitions(toolDefs);
  if (toolPrompt != null) {
    messageBuilderService.appendToSystemMessage(apiMessages, toolPrompt);
  }
}
```

需補 import：`import '../../../core/services/mcp/mcp_tool_prompts.dart';`（路徑相對 `lib/features/home/services/`）。

路徑覆蓋說明：

| 路徑 | 行為 |
|:---|:---|
| 主 chat path | 注入（上述程式碼）。`appendToSystemMessage`（`message_builder_service.dart:907`）把文字接在 system 尾端；`applyContextLimit()` 只做訊息則數裁切且 dormant，不會裁掉 system 內容 |
| Agent loop（多輪工具） | 使用同一份 `apiMessages` → policy 自動在場 |
| Answer Review revision | 繼承主 run 的 messages 與 tools → policy 自動在場；review phase 是 `tools: null`，其指令不含 policy（不需要） |
| Voice（`ChatTurnService.prepare()`） | 不經過此段、只廣告 `search_web` → 不注入（符合評估文件 §2.5） |
| Gemini 原生 built-ins 開啟 | `!hasBuiltInSearch` 擋下 → 不注入（見 §2） |

與既有 `injectSearchPrompt()`（302 行，settings-based）的差別：search 的注入以設定為準是既有先例；本工具以「實際廣告的 toolDefs」為準是本計畫的核心契約，兩者並存不衝突。

---

## 9. Step 6 — answer_review 與 README 文字

| 檔案 | 位置 | 現況 → 改為 |
|:---|:---|:---|
| `lib/core/services/agent/answer_review.dart` | 190 行（註解） | `the classic \`image_search\`-not-attached case` → `the classic \`illustrate\`-not-attached case` |
| 同上 | 297 行（revision 指令） | `an asset (for example \`image_search\`)` → `an asset (for example \`illustrate\`)` |
| `README.md` | 137 行 | `image_search(query, max_results)` → `illustrate(query, max_results)`（`Image_Search` server 名不變） |
| `README_ZH_TW.MD` | 137 行 | 同上（中文敘述同步微調） |

`answer_review_test.dart` 的 fixtures 以參數傳入 tool 名稱，模板文字改動不影響其斷言，不需更新（可順手把 fixture 名稱改成 `illustrate` 以求一致，非必要）。

---

## 10. Step 7 — 引擎可靠性修正（評估文件 §10.5，可獨立 PR 但建議同批）

### 10.1 Wikimedia fallback 條件

現況：只在 `ddgRaw.isEmpty` 才查 Commons；DDG 有結果但全部 HEAD 驗證失敗時不 fallback → 回「no usable image」。改為「**DDG 驗證後為空就 fallback**」。`_imageSearch()` 重構：

```dart
// --- Backend 1: DuckDuckGo (primary) ---
List<Map<String, dynamic>> ddgRaw = const [];
String? ddgError;
try {
  ddgRaw = await _fetchDuckDuckGo(query, maxResults);
} catch (e) {
  ddgError = e.toString();
}

const validateLimit = 5;
List<ImageSearchHit> hits = await _validateHits(
  [for (final m in ddgRaw) ..._hitsFromDuckDuckGo(m)]
      .take(validateLimit)
      .toList(),
);

// --- Backend 2: Wikimedia Commons — fallback when DDG is empty OR every
// DDG candidate failed HTTP validation (previously: only when empty).
List<Map<String, dynamic>> wikimediaRaw = const [];
if (hits.isEmpty) {
  try {
    wikimediaRaw = await _fetchWikimedia(query, maxResults);
  } catch (_) {
    // Commons is best-effort; failure is surfaced only when no usable
    // image came from any backend.
  }
  hits = await _validateHits(
    [for (final m in wikimediaRaw) ..._hitsFromWikimedia(m)]
        .take(validateLimit)
        .toList(),
  );
}

if (hits.isEmpty) { /* 現行錯誤訊息邏輯不變（why 判斷改用 ddgRaw/ddgError） */ }
return _okResult(renderImageSearchResult(hits));
```

### 10.2 HEAD 驗證並行

`_validateHits()` 現為循序（5 × 5s = 最壞 25s）。改為並行（保留原順序、過濾失敗者）：

```dart
Future<List<ImageSearchHit>> _validateHits(List<ImageSearchHit> candidates) async {
  final client = _httpClient ?? http.Client();
  try {
    final results = await Future.wait([for (final hit in candidates) _validateHit(client, hit)]);
    return [for (final h in results) if (h != null) h];
  } finally {
    if (_httpClient == null) client.close();
  }
}

Future<ImageSearchHit?> _validateHit(http.Client client, ImageSearchHit hit) async {
  final checkUrl = hit.thumbnailUrl.isNotEmpty ? hit.thumbnailUrl : hit.imageUrl;
  if (checkUrl.isEmpty) return null;
  if (!(await _isImageUrl(client, checkUrl))) return null;
  return hit;
}
```

### 10.3 Timeout 收斂

| 階段 | 現況 | 改為 |
|:---|:---|:---|
| DDG | `DDGS(timeout: 10s)` | `DDGS(timeout: 8s)` |
| Wikimedia API | `.timeout(12s)` | `.timeout(8s)` |
| HEAD per-URL | `.timeout(5s)` × 5 循序 | `.timeout(4s)` × 5 並行 |

最壞路徑：8（DDG 失敗）+ 8（Wikimedia）+ 4（並行 HEAD）≈ **20s**；單路徑 ≈ 12s。現行最壞 ≈ 47s。

### 10.4 SSRF

`_isImageUrl()` 現只檢查 scheme 就對任意 URL 發 HEAD。在 HEAD 前加 guard（重用 web fetch 的既有防護，`lib/core/services/web/ssrf_guard.dart`）：

```dart
final SsrfGuard _ssrfGuard = SsrfGuard(); // allowPrivateHosts: false（FetchCore 預設一致）

Future<bool> _isImageUrl(http.Client client, String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) return false;
  if (await _ssrfGuard.check(uri) != null) return false; // loopback/private/reserved
  try {
    final resp = await client.head(uri).timeout(const Duration(seconds: 4));
    ...
  }
}
```

說明：guard 只套用在 ≤5 個候選上，DNS 解析成本有界；IP literal（含 `127.1`／`0x7f000001` 等簡寫）由 `SsrfGuard.parseIpLiteral` 涵蓋。已知限制：這裡的 HEAD 不像 FetchCore 逐跳重查 redirect；ddgs／Wikimedia 來源可信度尚可，屬 defense-in-depth，註解說明即可。

### 10.5 `max_results` 對齊

schema 描述已於 Step 1 註明「只驗證前 5 筆」；`clampImageMaxResults`（1–15、預設 10）與 `validateLimit = 5` 行為不變。不調整數值，避免破壞既有對 `max_results: 5` 的測試預期（ddgs 端抓多一點 candidates 仍有價值）。

---

## 11. 測試計畫

### 11.1 `test/image_search_server_test.dart`（更新）

| 測試 | 動作 |
|:---|:---|
| `listTools exposes image_search with schema` | 改名為 `listTools exposes illustrate with schema`；斷言 `name == 'illustrate'`、`desc` contains `'Search the web for images'`／`'thumbnail_url'`／`'![alt](<url>)'` |
| 所有 `tools/call` 的 `params.name: 'image_search'` | 改為 `'illustrate'`（missing-query、ddgs path、wikimedia fallback、HTML strip 各測試） |
| 新增：legacy alias | `tools/call` 用 `name: 'image_search'`（ddgsOverride 命中）→ 與 `'illustrate'` 相同的成功結果；`tools/list` 仍只回 1 個 `illustrate` |
| 新增：驗證全失敗時 fallback Wikimedia | headOnly client（HEAD 回 403、GET 回 Commons JSON）+ ddgsOverride 回 1 筆 → `backend == 'wikimedia'`（舊行為會直接失敗） |
| 新增：SSRF | ddgsOverride 回 `http://127.0.0.1/x.jpg`；MockClient 對**任何**請求 throw → 結果為 `no usable image`（證明未發出 HEAD） |
| `clampImageMaxResults`／`renderImageSearchResult` groups | 不變 |

### 11.2 `test/mcp_tool_prompts_test.dart`（新）

- defs 含 `illustrate`（OpenAI 形狀）→ 回傳含 `## illustrate usage` 的字串
- defs 只有 `web_fetch` → null
- 空清單 → null
- 重複的 `illustrate` 定義 → 只回一次
- MCP 形狀 `{'name': 'illustrate'}` → 仍匹配
- 混合多工具 → 只回 `illustrate` 區塊

### 11.3 `test/image_search_tool_rename_migration_test.dart`（新）

比照 `web_fetch_migration_test.dart` 的 `SharedPreferences.setMockInitialValues` 模式，直接對 `mcp_servers_v1` JSON 測 `migrateBuiltinImageSearchToolName()`：

- 內建 server（id `image_search`）的 tool `image_search` enabled:false → 改名 `illustrate` 且 **enabled:false 保留**
- 已是 `illustrate` → 冪等（prefs 不被改寫）
- 同一 server 的 tools 同時含舊名與新名 → 跳過改名（防重複 entry）
- 非內建 server 的 `image_search` tool → 完全不動
- 無 `tools` 欄位／壞 JSON／空 prefs → 安全返回

### 11.3b `test/mcp_tool_service_routing_test.dart`（新，實作時補充）

`McpToolService.resolveCallTarget()` 純函式測試（不需 provider fakes）：

- stale `image_search` + 內建 `illustrate`（enabled）→ 路由到內建 server、名稱改為 `illustrate`
- 內建 `illustrate` 已關閉 → 無候選
- 第三方 server 有 enabled 的 `image_search` → 不綁架，路由到第三方
- 一般 `illustrate` call → 直接通過
- server 未在 `selected` 中 → 無候選

### 11.4 手動 smoke 矩陣（G1/G2 驗收）

| | 單主體 | 多主體比較 | 抽象概念／程式碼 | 使用者明確要圖 |
|:--|:---|:---|:---|:---|
| Claude / GPT / Gemini / DeepSeek | 應 1 張 | 應每主體各 1 張 | 不應呼叫 | 應呼叫 |

對照組（用 dev tools 或 request logger 看 wire）：

- MCP toggle 關閉 → tools 無 `illustrate` **且** system 不含 `## illustrate usage`
- Gemini 開 `google_search` → function declarations 被剝除且 system 不含 policy
- 舊對話（含 `image_search` 歷史）續聊 → 正常；若模型發 stale call，handler 仍回真實結果

---

## 12. 驗收清單

- [x] `tools/list` 只廣告 `illustrate`；`tools/call` 接受 `illustrate` 與 `image_search`
- [x] 升級使用者的 tool enabled 狀態經遷移保留（含備份還原與 JSON 匯入路徑）
- [x] policy 只在「toolDefs 含 `illustrate` 且 `!hasBuiltInSearch`」時出現在 system prompt
- [x] `flutter analyze` 無新 error；`flutter test test/image_search_server_test.dart test/mcp_tool_prompts_test.dart test/image_search_tool_rename_migration_test.dart test/web_fetch_migration_test.dart` 全綠
- [ ] 手動 smoke：至少 2/4 模型的呼叫率與圖片正確率較現行可觀察改善
- [ ] 舊對話續聊不中斷（G3）

---

## 13. 風險與回滾

| 風險 | 緩解 |
|:---|:---|
| Policy 過度觸發（每篇都插圖） | 中間版文字已含降噪約束；第一調整點是 registry 文字，不是架構 |
| 模型對改名困惑 | tools/call alias + scoped 路由已處理 stale calls；tools/list 只廣告新名，無混雜 |
| 遷移漏網（匯入／還原順序） | 三個呼叫點 + `replaceAllFromJson` + `_load()` 防禦；遷移冪等 |
| 第三方 server 同名 `image_search` tool | 遷移以 id 精確匹配、路由以內建 server id 限縮，不綁架 |
| 手工 JSON 同時含新舊名 | 遷移偵測新名即跳過；`refreshTools` 下次連線自然收斂 |
| Gemini built-ins 下誤注入 | 注入點明確 gate `!hasBuiltInSearch`（§2、§8） |
| 回滾 | 單一 revert 即可：無 schema／設定鍵變更。唯一殘留：回滾後 `refreshTools` 會以 `enabled: true` 重建舊名 entry（原關閉者被重開）——可接受，release note 說明 |

---

## 14. 實作順序與工作量

| 順序 | 內容 | 估計 |
|:--|:---|:---|
| 1 | Step 1 engine（改名 + alias + description） | 0.15 天 |
| 2 | Step 2 遷移 + 呼叫點 | 0.1 天 |
| 3 | Step 3 legacy 路由 | 0.05 天 |
| 4 | Step 4 registry（新檔） | 0.05 天 |
| 5 | Step 5 注入點 | 0.05 天 |
| 6 | Step 6 answer_review／README | 0.05 天 |
| 7 | Step 7 可靠性（可獨立 PR） | 0.25 天 |
| 8 | 測試（11.1–11.3）+ `flutter analyze` + targeted tests | 0.3 天 |
| — | **合計** | **約 1 天**（MVP＝1–6 約 0.5 天） |

建議 commit 切分：(a) rename + migration + routing（含測試）；(b) registry + 注入（含測試）；(c) 可靠性（含測試）。三個都可獨立 revert。

---

## 15. 附錄：程式碼位置（2026-11-10 驗證）

| 符號 | 位置 |
|:---|:---|
| `ImageSearchMcpServerEngine.serverName/toolName` | `lib/core/services/mcp/image_search/image_search_server.dart`（~55 行） |
| `methodCallTool` switch | 同檔（~88 行） |
| `_imageSearch()`／`_fetchDuckDuckGo`（DDGS 10s）／`_fetchWikimedia`（12s、`ddgRaw.isEmpty` 才查） | 同檔（~131–210 行） |
| `_validateHits`（循序、`validateLimit = 5`）／`_isImageUrl`（HEAD 5s、僅 scheme 檢查） | 同檔（~215–250 行） |
| `_toolDefinitions()`（現行 985 字元 description） | 同檔（~417–460 行） |
| `clampImageMaxResults`／`renderImageSearchResult` | 同檔（尾端） |
| `builtinImageSearchServerId = 'image_search'` | `lib/core/providers/mcp_provider.dart:443` |
| `_ensureBuiltinImageSearchServerPresent` | 同檔（445–458 行） |
| `refreshTools()`（name 合併、`prior?.enabled ?? true`） | 同檔（1282–1345 行） |
| `getEnabledToolsForServers`（connected + enabled 閘門） | 同檔（1504–1513 行） |
| `applyLegacyFetchMigration()`（靜態、`_prefsKey` JSON） | 同檔（292 行起）；呼叫點：`main.dart:97`、`data_sync.dart:1550`、`_load():335` |
| `replaceAllFromJson` | 同檔（529 行）；呼叫點：`mcp_json_edit_sheet.dart:60` |
| `listAvailableToolsForAssistant`／`callToolTextForAssistant` | `lib/core/services/mcp/mcp_tool_service.dart`（21／146 行） |
| `buildToolDefinitions`（MCP defs 不看 `hasBuiltInSearch`） | `lib/features/home/services/tool_handler_service.dart`（193 行；MCP 段 ~263 行） |
| `_buildMcpToolDefinitions`（McpToolConfig → OpenAI 形狀） | 同檔（~537 行） |
| MCP fallback（handler） | 同檔（~1015 行） |
| `final toolDefs = ...buildToolDefinitions(`（注入點） | `lib/features/home/services/message_generation_service.dart:375` |
| `injectSearchPrompt` 呼叫／定義 | 同服務 302 行／`message_builder_service.dart:864` |
| `appendToSystemMessage` | `lib/features/home/services/message_builder_service.dart:907` |
| Gemini 剝除 function declarations | `lib/core/services/api/chat_api_service.dart`（~6092／~6477 行） |
| `SsrfGuard.check(Uri)`／`isBlocked` | `lib/core/services/web/ssrf_guard.dart`（33 行起） |
| review 指令兩處 `image_search` 範例 | `lib/core/services/agent/answer_review.dart`（190／297 行） |
| README 工具名稱 | `README.md:137`、`README_ZH_TW.MD:137` |
