# write_todos 改善計畫：以 conversation event 為單一真相

> **實作狀態**：Phase 0–3 已完成（2026-11-10）。`write_todos` 已以 conversation event 為單一真相，`todo_v1` 寫入移除，Phase 3 的目前計畫 sheet、使用者清除、獨立 planning toggle、live dock 均已接上。  
> **版本**：v1.2（2026-11-09；實作前 review 修訂）  
> **Anybuff 基準**：`6594bbd80b48ad80b44e6356b03dd50f63dbdfca`（2026-11-08，desktop v1.9.0）  
> **範圍**：`write_todos` 工具、`TodoPlanCard`、system-prompt 注入、`todo_v1` Hive box、相關 backup/fork/delete/restore 行為  
> **非目標**：不改寫 `ask_user_input_v0` 的互動協定；不新增 plan mode；不重做 agent loop  
> **行號基準**：2026-11-09 目前工作樹；實作時以符號搜尋為準（本計畫會標出檔案與函式）  
> **v1.2 主要變更**：review 後補上 `hasWriteTodosEnabled` 純函式（不搬 `buildToolDefinitions`，避開 skills 冷 cache）、`cowork_tool_cards.dart` import 遷移、Phase 0 卡片 canonical items、`metadata.origin` 落點、cleared 狀態 per-request 語意、Gemini thought-signature 證據、空容器氣泡與 kill switch 退役註記。  
> **v1.1 主要變更**：加入 Anybuff 對照（§1.8）；採納寬容輸入、精簡 tool result、共用 parser、compaction todo 摘要、UI status/progress/dock；確認「任何 item 無效即整筆拒絕」與「result 只在正規化改動時附 items」。

---

## 0. 執行摘要

目前 `write_todos` 的核心缺陷不是 UI，而是**狀態所有權**：計畫同時存在於「tool event 的 arguments」與「獨立 Hive box `todo_v1`」，但只有前者在 conversation lifecycle 裡。於是 backup/restore、delete、fork、regenerate 全部對不上，injection 又與 tool 註冊脫鉤，形成「卡片看得到、模型看不到」或「模型看得到、使用者改不了」的分裂。

Anybuff 的調查驗證了這個方向：它沒有第二個 todo store，host 把 tool input 正規化後存進 transcript 的 tool card，renderer 只是 pure view，tool result 也不重複整份清單（§1.8）。但 Anybuff 的 schema 較窄、沒有長度上限，且 `Boolean()` 正規化與「取第一筆 snapshot」有實際缺陷，不能整包照搬。

本計畫的目標架構只有一句話：

> **最新一筆成功的 `write_todos` conversation event 就是唯一真相；不再有 `todo_v1`，不再把動態計畫塞進 system prompt。**

執行順序嚴格照下列三步，先止血再重構：

1. **防資料遺失**：lenient + strict parser、任何 item 無效即整筆拒絕且不清空、初始化失敗可見、卡片顯示錯誤/中斷。
2. **修注入**：injection 與 tool registration 用同一個 predicate（含 compaction override）；真實 tool result 精簡，synthetic state pair 注入完整 canonical snapshot；同一輪內以真實 tool result 為準。
3. **改單一真相**：新增 event projection，移除 `todo_v1`，讓 backup/fork/delete/regenerate 自然正確；動態狀態改放 conversation tail，不再污染 system prompt 的 cache 前綴；compaction 使用最新 snapshot 的 todo 摘要。

---

## 1. 問題盤點

### 1.1 P0：`todo_v1` 不在 conversation lifecycle

| 問題 | 證據 | 影響 |
|:--|:--|:--|
| backup 不包含 `todo_v1` | `lib/core/services/backup/data_sync.dart:723-751` 只匯出 conversations/messages/toolEvents/geminiThoughtSigs/workspaces/workspaceBindings/fileRecords | 還原後卡片還在（tool event 被還原），但模型注入空清單 |
| pre-migration backup 不包含 `todo_v1` | `lib/core/services/chat/storage/database_installation_gate.dart:560-577` 的 `chatHiveFiles` 沒有 `todo_v1` | 遷移前備份救不回計畫 |
| 刪除對話不清理 | `lib/core/services/chat/chat_service.dart:552-602` 沒有通知 `TodoService` | orphan row 累積 |
| fork 不帶計畫 | `lib/core/services/chat/chat_service.dart:1010-1025` 只用 `sourceMessages` fork；`todo_v1` 用舊 conversation id | 分支後模型不知道原計畫 |
| regenerate/version 看到「現在」 | `todo_v1` 是 conversation-level global snapshot，不隨 branch point 改變 | 切換版本時計畫時間點錯誤 |
| `clearForConversation` 沒 caller | `lib/core/services/chat/todo_service.dart:145-150`；全 repo 搜尋無呼叫 | 證明 lifecycle 沒接完 |
| 錯誤的 backup 註解 | `todo_service.dart:4-7` 宣稱「follows normal conversation sync rules（NOT in `_localOnlyKeys`）」 | `_localOnlyKeys` 只控制 SharedPreferences settings snapshot，與 Hive backup 無關 |
| 為新功能保留 Hive | `chat_service.dart:227-233` 明說「TodoService still opens its own box, so keep the Hive path initialized」 | 與 SQLite 遷移方向相反；且真正需要 Hive 的其實還有 agent checkpoint store，註解把兩件事混在一起 |

### 1.2 P0/P1：Injection 與 tool 可用性脫鉤

- `message_generation_service.dart:267-274`：只要 `currentTodos` 非空就注入，沒有檢查 `toolDefs` 是否包含 `write_todos`。
- `tool_handler_service.dart:324-328`：workspace 關閉時 `buildWorkspaceToolDefinitions` 回傳空。
- `tool_handler_service.dart:344-347`：全域 per-tool toggle 關閉時，`write_todos` 也被過濾。
- 模型不支援 tools 時，`supportsTools == false`，同樣沒有 `write_todos`。

結果：system prompt 說「目前有一份計畫」，模型卻沒有工具可更新；使用者看到卡片，UI 也沒有入口可改。

### 1.3 P1：Malformed input 直接清空

`tool_handler_service.dart:786-793`：

```dart
final todos = normalizeTodoItems(args['todos']);
await todoService.setTodos(conversationId, todos);
```

`normalizeTodoItems`（`todo_service.dart:56-70`）對非 `List`、缺少 `todos`、全部空 content 都回傳空 list。於是：

- `todos: {}`、`todos: null`、缺少 key → 都變成「清空」。
- 全部 item 的 content 為空 → 也清空。
- 回傳 `"Todo list updated: 0 items"`，模型以為成功。

此外，invalid status 會靜默變 `pending`、超量會被截斷，但 tool result 只回人類可讀的 counts 字串，模型不知道輸入被改寫。

### 1.4 P1：兩份真相，失敗不可見

- UI 讀 tool event arguments（`cowork_tool_cards.dart:29-30`、`chat_message_widget.dart:3489-3491`）。
- 模型讀 `TodoService` Hive box（`message_generation_service.dart:146-162`）。
- 兩邊沒有 transaction / reconciliation：box 寫失敗時卡片仍像成功；event 寫失敗時模型有計畫但 UI 沒卡片。
- `TodoPlanCard` 只看 `content == null || content.isEmpty` 當 loading（`cowork_tool_cards.dart:84-86`），完全忽略 `tool_error` / `interrupted`。
- `TodoService._ensureInitialized`（`todo_service.dart:93-97`）有競態與失敗 latch：

```dart
if (_initialized) return;
_initialized = true;
_box = await Hive.openBox(boxName);
```

並行呼叫的第二個會看到 `_initialized == true` 但 `_box == null`；`openBox` 失敗後永久 latch，`setTodos` 的 `_box?.put(...)` 靜默 no-op。

### 1.5 P1：Prompt cache 與回合內新鮮度

- `message_builder_service.dart:808-830` 把 snapshot append 到 system message。每次計畫變更，system block 就變一次：
  - Anthropic `cache_control` 是 block 邊界，system 變更會讓後續 cache breakpoint 失效。
  - OpenAI prefix cache 只能命中變更點之前的前綴。
- `prepareApiMessagesWithInjections` 只在 turn 開始跑一次（`lib/features/home/controllers/chat_actions.dart:356-369`）。模型呼叫 `write_todos` 後，同一輪的 system 仍是舊計畫；下一個 user turn 才更新。
- 結果：同一輪同時看到「system 的 A 計畫」與「tool result 的 B 計畫」。

### 1.6 P1：注入內容的安全與大小

`renderTodoSnapshot`（`todo_service.dart:74-83`）直接把 content 放進 system prompt：

```text
<current_todo_list>
[ ] ...
</current_todo_list>
```

Todo content 可能來自 web_fetch、MCP、檔案內容，經模型寫入後被提升成 system 指令，而且跨回合持久化。這是實質的 persistent prompt injection 路徑。同時沒有 per-item / total 長度上限，50 項可以讓 system prompt 暴增。

### 1.7 P2：UI、整合與測試

- **還原後 completed plan card 一直轉圈**：`chat_repository.dart:893-902` 的 `eagerContent` 只涵蓋 pending/denied 與 `ask_user`，不 eager `write_todos` content；`TodoPlanCard` 用 `content == null` 判斷 loading，且建構時沒收到 `part.loading` / `part.status`。
- **錯誤與中斷被忽略**：card 不解析 `tool_error`，也不顯示 `interrupted`。
- **Dead code**：`hasEverHadTodos`、`peek`、`TodoItem.fromJson`、`clearForConversation`、`notifyListeners` 沒有實際 consumer。
- **測試不足**：`test/cowork_todo_ask_user_test.dart` 只測 pure functions；持久化、初始化失敗、刪除/fork/restore、injection gating 都沒測。
- **Workspace coupling**：`write_todos` 綁在 workspace 開關下；若 planning 不只想用於 Cowork，應拆成獨立 tool gate。
- **沒有「目前計畫」入口**：只能從歷史卡片看；沒有查看/清除目前計畫的 UI。
- **Tool description 不精確**：說「never stored as conversation history」，但 tool event 其實有存；應改成「not replayed as conversation history」。

### 1.8 Anybuff `write_todos` 對照（2026-11-09 調查）

> 基準：Anybuff HEAD `6594bbd80b48ad80b44e6356b03dd50f63dbdfca`（2026-11-08）。Anybuff 的 `write_todos` 源自 Codebuff upstream；下列 commit 都在公開歷史中。

#### 1.8.1 架構：沒有第二個 store

- Tool handler 是 stateless：`packages/agent-runtime/src/tools/handlers/tool/write-todos.ts:10-19` 只回 `{message:'Todos written'}`，不寫任何 store。
- Host 在 `tool_call` 事件進來時，把 `write_todos` input 正規化成 `UiEvent.todos`（`packages/host-core/src/run/start-run.ts:517-527`）。
- Session store 在建立 tool card 時把 `todos` 存在 card 上（`packages/host-core/src/sessions/session-store.ts:190-207`）；`tool_result` 只更新 status/detail，不覆蓋 `todos`（`:209-220`）。
- Transcript 是唯一耐久來源：`packages/host-core/src/settings/settings.ts:1657-1684` 寫 `tasks/<taskId>.json`，`:1778-1788` 載入，`:1790-1801` 刪 task 時一併刪除。
- Renderer 是 pure view：`session-store.ts:18-25` 的註解明說 main-process session store 是 single source of truth；`desktop/src/renderer/src/App.tsx:1681-1695` 只用 `event.todos` 更新 per-task live state，`finish` 時丟掉。

**對 OmniChat 的意義**：這正是本計畫 Phase 2 的方向。Anybuff 證明「tool event + transcript」可以同時餵 UI 與後續 context，不需要 `todo_v1`。

#### 1.8.2 輸入與輸出

- Schema：`common/src/tools/params/tool/write-todos.ts:8-27`，`{todos:[{task, completed}]}`，`endsAgentStep=false`。
- 寬容前處理：`common/src/tools/params/utils.ts:21-33` 的 `coerceToArray` 接受單一物件、stringified JSON array；`5edd8088d` 引入。
- Handler result：只有 `{message:'Todos written'}`（`write-todos.ts:59-66`、handler `:10-19`）；`318ead2df` 刻意移除 result 裡的重複清單。
- 缺少：`maxItems` / `maxLength` / `maxTotalChars`，schema 沒有上限。
- 缺陷：host normalize 用 `String(item.task ?? '')` 與 `Boolean(item.completed)`（`start-run.ts:520-525`），會接受空 task，且 `"false"` 會變 `true`。

**對 OmniChat 的意義**：採納 `coerceToArray` 的寬容度，但不要用 `Boolean()`；OmniChat 保留三態 status 與長度上限。真實 result 可精簡，但 OmniChat 在正規化改動清單時要附 `items` 讓模型知道。

#### 1.8.3 UI

- `desktop/src/renderer/src/components/ChatMessage.tsx:456-483` 的 `TodoCard` 直接吃 `todos`，顯示 `done/total` 與 checklist。
- `:485-557` 的 `ToolCard`：`running = tool.status === 'running' && isLast`（`:486`）；header 顯示 `${done}/${total} completed`（`:546`）；`Running…` / `Failed` / `Interrupted` 由 status 決定（`:547-549`）；展開時用 `TodoCard inline`。
- `desktop/src/renderer/src/App.tsx:4605` 的 `activeTodos` 與 `:5403-5407` 的 `todo-panel-dock` 只在 `viewRunning` 時顯示；`finish` 時 drop（`:1681-1682`）。
- CSS：`desktop/src/renderer/src/styles.css:2733-2863`。

**對 OmniChat 的意義**：`TodoPlanCard` 已有 progress pill，但 spinner 仍用 `content == null` 判斷（`lib/features/chat/widgets/cowork_tool_cards.dart:86`）。應改成 status/loading/contentLoaded 狀態機；live dock 可作 Phase 3。

#### 1.8.4 Prompt / gating

- `agents/base2/base2.ts:501`：3+ steps 才用；include ALL；include review/validation；skip simple tasks。
- `:122`：`!isFast && 'write_todos'`。
- `:531`：Plan mode 明確禁用 `write_todos`。
- `agents/base3.ts:43,53,114`：base3/CLI roots 一直包含，system prompt 只說「Use `write_todos` to plan and track multi-step tasks.」。

**對 OmniChat 的意義**：目前 tool description 只說「送完整清單」，沒有說「何時用、何時不用」。應補上 3+ steps / ALL / review / skip simple；若未來加 plan mode，planning gate 要 mode-aware。

#### 1.8.5 Compaction

- `agents/context-pruner.ts:677-692` 把歷史 `write_todos` 摘要成 `Todos: x/y complete. Remaining:` 或 `(all done!)`。
- `:431-437` 的 `Next Action` 取**第一筆**有 incomplete item 的 `write_todos`，不是最新一筆；`agents/__tests__/context-pruner.test.ts:717-735` 只測單一 snapshot。
- `:480-488` 把 `Next Action` 放進 pinned knowledge block。

**對 OmniChat 的意義**：OmniChat 目前只有 `nextActionOverride`（`lib/core/services/agent/compaction/history_compactor.dart:442-445`），沒有完整 todo 摘要。應加 `Todos: x/y complete...`，但必須取最新成功 snapshot；同時 gate 在 `hasWriteTodos`。

#### 1.8.6 歷史教訓

- `0937bf461415f89e86cb273def271d1c377d0aa0` → `5e07e379bdeb1307e191b9c1c3d8bb10861c75c7` → `31b8421b918c662073ba0cfd8a090465c6944856` → `75c574de3ba8ad07f64d3f5447ef157c33d29b15`：Anybuff 試過「all todos completed 就結束回合」，最後移除；現在所有 `write_todos` 都像正常 tool 一樣強制下一步（`common/src/tools/constants.ts:12-23` 的 no-force 清單不含 `write_todos`）。
- `318ead2df33872679a07d548f4d558d4d528829c`：result 不再重複 todos。
- `5edd8088d621ddf38c76a323de30c93e37f3fc08`：加 `coerceToArray` 處理錯誤 schema。
- `81df753b74f5397243ed63867ffd162d67b01a2c`：多 tab 並行後，live todo 改成 per-task state，背景任務不污染前景。

**對 OmniChat 的意義**：不要 special-case 回合結束；不要重放每一筆歷史 snapshot；不要讓一個全域 todo 狀態跨 task 汙染。

#### 1.8.7 採納與不採納

| 採納 | 不採納 |
|:--|:--|
| transcript/event 是唯一真相 | `{task, completed}` 二元 schema（OmniChat 保留三態） |
| `coerceToArray` 式寬容輸入 | `Boolean(item.completed)` 字串強轉 |
| 精簡 tool result | 無 `maxItems` / `maxLength` 上限 |
| handler/projection/UI 共用 parser | `Next Action` 取第一筆 snapshot |
| 3+ steps / ALL / review prompt 指引 | all-complete 就結束回合 |
| compaction todo 摘要 | 重放每一筆歷史 snapshot |
| status/progress/live dock | Plan mode 直接禁用（OmniChat 尚無 plan mode；未來若新增，gate 需 mode-aware） |

---

## 2. 目標設計

### 2.1 單一真相：TodoProjection

新增兩個純 Dart 模組（不依賴 Hive / Flutter provider）：

```text
lib/core/services/chat/todo_models.dart      // TodoItem、status、lenient + strict parser、canonical result builder、renderer
lib/core/services/chat/todo_projection.dart  // 從 conversation events 推導最新狀態
```

#### 2.1.1 模型

```dart
class TodoState {
  final List<TodoItem> items;
  final String? sourceMessageId;
  final String? sourceToolCallId;
  final bool hasExplicitState; // 有成功的 write_todos event，即使 items 為空
  final DateTime? updatedAt;
}
```

`hasExplicitState` 用來區分：

- 從來沒有計畫 → `null`（不注入）。
- 使用者明確清空 → `TodoState(items: [], hasExplicitState: true)`（可注入一次 `cleared` 狀態，或 UI 顯示「已清除」）。

#### 2.1.2 投影規則

```dart
TodoState? projectTodoState({
  required List<ChatMessage> activeMessages, // 已 collapseVersions
  required Map<String, List<Map<String, dynamic>>> eventsByMessageId,
});
```

規則：

1. 只掃 `activeMessages`，順序即 conversation 順序。
2. 只看 `event['name'] == 'write_todos'`。
3. 只用 **成功的 event**：
   - `approvalState` + `content` 推導 status，必須是 `completed`（`deriveLegacyToolPartStatus`）。
   - `content` 若是 `tool_error` JSON → 忽略，不改變狀態。
   - `content` 若是完整或 `changed=true` 的 `todo_snapshot`（含 `items`）→ 用 result 的 canonical items。
   - `content` 是精簡 snapshot（`changed=false`，只有 counts）或 `content == null` 但 args 合法 → 用 lenient parser 從 arguments 重建（記 log）。
   - `content` 是舊版人類可讀字串（非 JSON）但 args 合法 → 用 lenient parser 從 arguments 重建（legacy）。
4. `arguments['todos']` 用 **lenient parser**（單一 object、stringified JSON、`task`/`completed` alias）；只有 `content` 的完整 canonical snapshot 才用 strict parser。兩者都失敗 → 忽略該 event，記 log。
5. 後出現的成功 event 覆蓋前面的；同一 message 內以最後一筆為準。
6. `todos: []` 且成功 → `TodoState(items: [], hasExplicitState: true)`。
7. 回傳最後一筆；沒有則 `null`。

**branch/version 正確性**：`activeMessages` 必須是 `messageBuilderService.collapseVersions(messages, versionSelections)` 的結果（`message_builder_service.dart:99-133`）。這樣：

- regenerate：目前選到的舊 assistant version 會被納入。
- 切換 message version：只投影選到的分支。
- fork：新 conversation 的 messages 是 clone，投影自然只看 fork 後的分支。
- compaction：投影掃完整 selected branch，不因 `compactBeforeIndex` 丟失狀態。

#### 2.1.3 效能

- generation 路徑：`ensureToolEventsLoaded(messages.map((m) => m.id))` 已經在 `message_generation_service.dart:135` 執行，投影可直接用同一批 events。
- UI 路徑：先查目前 conversation 的 `write_todos` parts（見 §4），或用現有 `getToolEvents` 對 active assistant messages 取；`write_todos` event 數量少，成本可接受。
- 若 profiling 顯示成本過高，再加 materialized `conversation_todos` 或 index；**任何 materialized 狀態都必須和 tool event 在同一個 SQLite transaction 更新**，不得成為第二個真相。

### 2.2 Tool contract 收緊

#### 2.2.1 輸入驗證

| 輸入 | 行為 |
|:--|:--|
| `args['todos']` 不是 `List` / 缺少 key / `null` | 先嘗試 `coerceTodoList`；仍無法變成 list → `tool_error {error: invalid_todos}`；**保留舊計畫**；不呼叫任何 store |
| `todos: []` | 明確 clear；成功；寫入空狀態 event |
| `todos` 是單一 object | 包成 array；item 有效則成功 |
| `todos` 是 stringified JSON array / object | parse 後再驗證；parse 失敗 → `invalid_todos` |
| list 內**任何** item 無效（非 Map、trim 後空 content、status 無法解析） | **整筆拒絕** `invalid_todos`；保留舊計畫；不寫 store；錯誤帶 `index` / `reason` |
| 部分 item 無效 | 同上：整筆拒絕，**不採納** v1.0 的「丟棄無效 item」 |
| item 用 `task` 而非 `content` | 接受 alias，正規化為 `content` + warning |
| item 用 `completed` 而非 `status` | 接受 alias；`true` → `completed`、`false` → `pending` + warning；`status` 同時存在時以 `status` 為準 |
| item 缺少 `status` 與 `completed` | 預設 `pending` + warning（不視為 invalid；schema 仍要求 `status`） |
| status alias（`done` / `complete` / `doing` / `active` / `open` / `todo`…） | 已知 alias 正規化（`done` → `completed`、`doing` → `in_progress`、`open`/`todo` → `pending`）+ warning；無法解析 → invalid item → 整筆拒絕 |
| `completed` 是 `"false"` / `"0"` / `"true"` / `"1"` | 明確 parse 成 boolean；**禁用 `Boolean()`** |
| 超過 `maxItems` / `maxItemChars` / `maxTotalChars` | 截斷 + `truncated: true` + warning（仍成功） |
| 多於一個 `in_progress` | warning，不視為錯誤（模型常這樣做） |

#### 2.2.2 參數限制

建議值（可依實際 prompt 預算調整）：

- `maxItems = 50`
- `maxItemChars = 2000`
- `maxTotalChars = 8000`
- JSON Schema 同步加 `maxItems: 50`、`content.maxLength: 2000`。

#### 2.2.3 Tool result 形狀（精簡 + changed）

真實 tool result 只在**正規化改動清單**時才附 `items`；平常只回 counts。這是 Anybuff `318ead2df` 的 token 效率，加上 OmniChat 需要的「模型知道輸入被改寫」。

沒有改動：

```json
{
  "type": "todo_snapshot",
  "changed": false,
  "counts": {"total": 2, "pending": 0, "inProgress": 1, "completed": 1},
  "cleared": false
}
```

有改動（alias、截斷、status normalize）：

```json
{
  "type": "todo_snapshot",
  "changed": true,
  "items": [
    {"content": "Inspect schema", "status": "completed"},
    {"content": "Write migration", "status": "in_progress"}
  ],
  "counts": {"total": 2, "pending": 0, "inProgress": 1, "completed": 1},
  "warnings": ["item 2: status 'done' normalized to 'completed'"],
  "truncated": false,
  "cleared": false
}
```

- 成功 clear：`items: []`、`counts` 全 0、`cleared: true`；若舊狀態非空則 `changed: true`，本來就空則 `changed: false`。
- `changed` 只表示 canonical list 與輸入不同（coerce / alias / 截斷）；單純 warning（例如多個 `in_progress`）不算 `changed`。
- 錯誤：`{"type":"tool_error","error":"invalid_todos","message":"...","tool":"write_todos","invalidItems":[{"index":2,"reason":"empty_content"}]}`。
- `changed=false` 時，projection/UI 用同一個 parser 從 arguments 重建；`changed=true` 時，result 的 `items` 是 canonical，projection/UI 優先採用。
- **synthetic state pair 的 tool content 永遠是完整 canonical snapshot**（含 items），不受此處精簡影響。
- 不再回純文字 `Todo list updated: N items`；`changed=false` 仍是結構化 JSON（`type`/`changed`/`counts`/`cleared`），不是人類可讀字串。

#### 2.2.4 Tool description

改成：

> Use this tool for multi-step tasks (3+ steps) after gathering context. Send the COMPLETE list every call (last write wins); statuses: pending, in_progress, completed. Keep exactly one item in_progress while working. Include ALL applicable steps, including review/validation. Skip for simple edits or Q&A. `todos: []` clears the plan. The latest successful snapshot is persisted with the tool event and re-injected as conversation state; older snapshots are not replayed as tool calls. Max 50 items; each item max 2000 chars; total max 8000 chars.

修正「never stored as conversation history」的錯誤說法；並補上 Anybuff `base2.ts:501` 的「3+ steps / ALL / review / skip simple」使用指引。

### 2.3 Injection 治理

#### 2.3.1 同一個 predicate

現在 `toolDefs` 在 `buildApiMessages` 與 injection 之後才建立（`message_generation_service.dart:194-205`、`:267-274` vs `:339-347`），而 `compactionNextAction` 在 `:200` 就已經傳進 compaction。這代表 workspace 關閉、toggle 關閉、模型不支援 tools 時，knowledge block 仍可能提到計畫。

調整順序：

1. 先把 gating 抽成純函式 `hasWriteTodosEnabled(...)`，條件與 `buildWorkspaceToolDefinitions` 完全同源（`supportsTools`、workspace 決策、`settings.isWorkspaceToolEnabled(todoToolName)`）。**不要**把整個 `buildToolDefinitions` 搬到 `buildApiMessages` 之前：它目前跑在 `message_generation_service.dart:339`，晚於 `SkillService.globalSkillsRoot()` 的 warm-up（`:282`）；搬前會讓 skills 掃描在冷 cache 下誤判（`:276-281` 的註解已警告）。`write_todos` 只由 `_buildCoworkToolDefinitions` 產生，沒有其他 assistant-level allowlist，所以這個 predicate 等價。
2. 在 `buildApiMessages` 之前用該 predicate 算 `hasWriteTodos`；取得實際 `toolDefs` 後再比對一次（assert + log），避免兩套條件日後漂移。
3. 只有 `hasWriteTodos` 才注入/附加 state，**也才把 `compactionNextAction` / `todoSummary` 傳進 `buildApiMessages`**。
4. `buildToolCallHandler` 仍只在 `toolDefs.isNotEmpty` 時建立。

這樣 workspace 關閉、toggle 關閉、模型不支援 tools 時，prompt 與 compaction knowledge block 都不會再提到計畫。若未來要保留唯讀顯示，必須在 prompt 明確寫「此清單僅供參考，你目前沒有更新工具」，且 UI 也要標示唯讀。

#### 2.3.2 動態狀態放 conversation tail，不放 system

目標：**system prompt bytes 在 todo 更新前後保持不變**。

在 `prepareApiMessagesWithInjections` 結尾，對 `apiMessages` append 一組 synthetic state pair：

```text
assistant: content="\n\n", tool_calls=[{
  id: "<latest-real-toolCallId 或 todo_state_<stateHash>>",
  type: "function",
  function: {name: "write_todos", arguments: "<canonical args JSON>"}
}]
tool: tool_call_id="<latest-real-toolCallId 或 todo_state_<stateHash>>",
      name="write_todos",
      content="<full canonical snapshot JSON>"
```

規則：

- 只在 `hasWriteTodos && todoState != null` 時 append。
- `todoState.items.isEmpty && !hasExplicitState` → 不 append。
- `todoState.items.isEmpty && hasExplicitState` → **每次 request** 都 append `cleared` 狀態（synthetic pair 不持久，這是 per-request 行為，直到有更新的成功 event 覆蓋）。模型每輪都會看到「計畫已空」，這是刻意的。
- `id` 優先用**最新成功 event 的真實 `toolCallId`**（Anybuff 用 real id 配對 call/result，見 `packages/host-core/src/contracts/types.ts:34-35`、`session-store.ts:199`）；若 id 為空、或與 `apiMessages` 既有 tool_call id 碰撞，fallback `todo_state_<stateHash>`。**不要用時間戳**；同一狀態在 retry 時 id 不變，避免 cache 抖動。
- synthetic pair 的 `content` **永遠是完整 canonical snapshot**（含 `items`），即使真實 tool result 是精簡版；這是下一輪的狀態注入，不能只放 counts。
- 歷史上的 `write_todos` 仍留在 `kNonReplayableToolNames`（`tool_replay.dart:15-19`），避免每個舊計畫都重放造成 token 膨脹；只有 tail 這一組進入 request。
- 若最後一則訊息已經是同一組 state pair（例如同一輪內重組），跳過避免重複。

**Cache 效果**：

- system/tools 前綴完全不變；Anthropic/OpenAI 的 cache 前綴可命中到 synthetic pair 之前。
- 只有 tail 變動，這是動態狀態的最小代價。
- 同一輪內，模型呼叫 `write_todos` 後的**真實 tool result** 排在 synthetic pair 之後，因此模型看到的是最新版本；不需要在 `onRoundStart` 重建 system。

**Provider 相容性**：

- synthetic pair 的形狀與現有 `buildApiMessages` 的 replay pair 相同（`message_builder_service.dart:300-308`），Claude/Gemini/OpenAI 轉換器已能處理。
- Gemini 3 要求重放的 `functionCall` 帶 thought signature；既有 `_ensureGeminiFunctionCallThoughtSig`（`chat_api_service.dart:660-678`）會補 placeholder，且 synthetic pair 只有一個 `functionCall`，正好落在「只驗證第一個 part」的保護內。仍要加 Gemini parity test 覆蓋 `:5901`、`:6284` 的重放轉換路徑。
- 若某 provider 對「assistant 先呼叫工具」有特殊限制，加 parity test；必要時 fallback 成「gated system block + cache breakpoint 前移」，但這是備案，不是預設。

#### 2.3.3 回合內新鮮度

- 真實 tool result 精簡：`changed=false` 時模型仍可從自己的 tool call arguments 看到原清單；`changed=true` 時 result 含 `items` + warnings，模型知道正規化結果。
- synthetic pair 的 result 永遠是完整 canonical snapshot，模型下一輪直接看到最新狀態。
- 同一輪多次 `write_todos`：每次真實 result 都覆蓋前一版；tail 的 synthetic pair 是最後一次 user turn 前的狀態，較舊，但真實 result 在後面，模型會以較新的為準。
- 若未來 L0/L1 真的把 todo result 修剪掉（目前 result 很小，不會觸發 8192 字門檻），再加 `onRoundStart` 保險：若目前 messages 找不到最新 state pair，補一組；不要重建整個 system。

### 2.4 UI 修正

#### 2.4.1 TodoPlanCard 狀態機

`ToolUIPart` 已經有 `loading`、`status`、`contentLoaded`、`contentLength`（`chat_message_widget.dart:3206-3264`），不需要新增模型欄位。`chat_message_widget.dart:3489-3491` 改成：

```dart
TodoPlanCard(
  arguments: part.arguments,
  content: part.content,
  loading: part.loading,
  status: part.status,
  contentLoaded: part.contentLoaded,
)
```

Card 狀態：

| 條件 | 顯示 |
|:--|:--|
| `loading == true` 或 `status == running` | spinner（只有真的還在跑） |
| `status == interrupted` | 中斷圖示 + 中斷文案，**不要 spinner** |
| `content` 是 `tool_error` JSON | 錯誤圖示 + 錯誤訊息；不要渲染成有效計畫 |
| `content` 是 `todo_snapshot` | 用 canonical items/counts/warnings；`changed=false` 時用 arguments 重建 |
| `content == null` 但 `status == completed` | 用 arguments 渲染計畫 + completed 圖示；不要 spinner |
| `content == null` 但 `status == pending` | spinner（真的還在跑） |
| `contentLoaded == false` 且需要錯誤細節 | 顯示「載入結果」按鈕或 lazy load，不要用 spinner 假設 |

Anybuff 的 `ToolCard` 用 `running = tool.status === 'running' && isLast`（`desktop/src/renderer/src/components/ChatMessage.tsx:486`），不是用 `content == null`。OmniChat 應鏡射這個規則：spinner 只跟 status/loading 有關，與 content 是否載入無關。

#### 2.4.2 歷史卡片

- 只展開最新一筆；較舊的預設折疊。
- 全部 completed 自動折疊（現有 `_allCompleted` 已做，保留）。
- 長 item 用 `maxLines` + 展開詳情。
- `contentLoaded == false` 不再等於 loading。

#### 2.4.3 目前計畫入口

新增 `TodoPlanSheet`（或 dialog）：

- 來源：同一個 `TodoProjection`，不是 `TodoService`。
- 入口：chat overflow menu / workspace menu 的「目前計畫」；沒有計畫時 disabled 或顯示空狀態。
- 內容：items + status + 最後更新來源；長內容可展開。
- Clear（已定案，Phase 3）：append 一筆成功的 `write_todos` tool part（`arguments: {"todos":[]}`、canonical result、`metadata.origin = 'user_clear'`；必要時建立 assistant message 容器；`write_todos` 在 non-replayable 名單，不會產生 dangling tool call）到目前 conversation；不要只改本地 UI。清除後 projection 回傳 `hasExplicitState: true` 的空狀態，sheet 顯示「已清除」。若建立 assistant 容器，render 端要過濾沒有正文的容器氣泡（只留卡片），避免多一個空氣泡。

#### 2.4.4 Eager content

`chat_repository.dart:893-897` 的 `eagerContent` CASE 目前只涵蓋 pending/denied 與 `ask_user`，但 `:898-902` 的 `eagerArguments` 已經包含 `write_todos`。這造成還原後的 completed card 有 arguments、`content == null`，而 `TodoPlanCard` 用 `content == null` 判斷 loading（`cowork_tool_cards.dart:86`），所以永久轉圈。

修正：`eagerContent` CASE 加入 `OR message_parts.tool_name = 'write_todos'`。`write_todos` result 是小型 canonical JSON（精簡後更小），eager load 成本低，能讓還原後的錯誤/完成狀態正確顯示。若不想 eager，card 必須用 `contentLoaded` 顯示 lazy 狀態，不能再用 `content == null` 當 loading。

#### 2.4.5 Live dock（Anybuff 對照）

Anybuff 在 composer 上方有一個 `todo-panel-dock`，只在 `viewRunning` 時顯示（`desktop/src/renderer/src/App.tsx:5403-5407`）；`finish` 時 drop per-task live state（`:1681-1682`），transcript card 仍保留。OmniChat 可採同樣分工：

- **live dock**：目前 running task 的最新 snapshot，位於 composer 上方；跑完消失。
- **transcript card**：耐久，事後可查。
- **TodoPlanSheet**：非 running 時查看「目前計畫」的入口。

Live dock 放 Phase 3，不阻塞 Phase 0/1/2。

### 2.5 Lifecycle / backup / migration

#### 2.5.1 事件已是 conversation data

一旦投影改讀 tool events：

- **backup/restore**：`omnichat_chats_*.json` 的 `toolEvents` 已包含 `write_todos`；不需新增 `todo_v1` 匯出。還原後投影直接得到同一份計畫。
- **delete**：`message_parts` 隨 message/conversation cascade 刪除；沒有 orphan box。
- **fork**：`ChatRepository.forkConversation` 會 clone `message_parts`（`chat_repository.dart:1451-1475`，含 arguments/content/status/metadataJson），fork 後投影得到 fork 前的計畫。SQLite 後端的 `getToolEvents` 本身就是 `message_parts` 的投影（`sqlite_chat_storage.dart:1083-1105`），所以 clone parts 等於 clone event。
- **regenerate/version**：投影用 `collapseVersions` 的 selected branch，時間點正確。
- **pre-migration backup**：若遷移期間仍需讀舊 box，過渡版把 `todo_v1` 加進 `chatHiveFiles`（`database_installation_gate.dart:560-577`），讓備份包含它；移除 box 後再刪掉這行。

Anybuff 的實作可作為對照：它在 tool card 建立時把 `todos` 存在 transcript 上，`tool_result` 只更新 status/detail（`packages/host-core/src/sessions/session-store.ts:190-220`），task 刪除時一併刪 transcript（`packages/host-core/src/settings/settings.ts:1790-1801`）。這正是 OmniChat 要的 lifecycle：**沒有 orphan todo row，備份/還原/刪除/fork 都跟著 conversation 走**。

#### 2.5.2 移除 `todo_v1`

最終狀態：

- 刪除 `TodoService` class、`main.dart:214` 的 provider、所有 `getTodos/setTodos/clearForConversation` 呼叫。
- 移除 `todo_service.dart`；模型/parser 搬到 `todo_models.dart`。遷移期若需要 fallback，保留一個**唯讀** `TodoV1LegacyReader`（可放在 migration service），不保留 `TodoService` 的寫入 API。
- `tool_replay.dart:5` 的 import 改成 `todo_models.dart`。
- `chat_service.dart:227-233` 的註解更新：Hive 保留給 `AgentRunCheckpointStore`（`lib/core/services/agent/checkpoint/agent_run_checkpoint_store.dart:29-45`），不是為了 `todo_v1`；不要直接刪掉 `Hive.init`，否則 checkpoint store 會壞。
- `main.dart` 不再建立 `TodoService`；UI/注入全部改用 projection（migration fallback 例外）。

#### 2.5.3 遷移策略（避免舊資料消失）

採「一次性遷移 + 過渡 fallback」：

1. 啟動時若 `todo_v1` 存在，讀取每個 conversation 的 snapshot。
2. 若該 conversation 已有成功的 `write_todos` event → event 勝出，直接丟棄 box entry。
3. 若沒有 event 且 items 非空 → 找目前 active branch（`collapseVersions` 後）的最後一則 assistant message，追加一筆 completed `write_todos` part：
   - `arguments = {"todos": [...]}`
   - `content = 完整 canonical todo_snapshot JSON（含 items，不是精簡 counts）`
   - `metadata = {"origin": "todo_v1_migration"}`
   - 若 conversation 沒有 assistant message → 保留 box entry，投影 fallback 到 box，下次再試。
4. 全部處理完設 SharedPreferences `todo_v1_migrated_v1 = true`；box file 可在下一版刪除。
5. 遷移失敗只記錄 log，不阻塞啟動；fallback 讓使用者至少還看得到計畫。

> 注意：追加 part 到既有 assistant message 不會重放（`write_todos` 在 non-replayable 名單），所以不會產生 dangling tool call；UI 會多一張「計畫已還原」卡片。若不想要這張卡，可在 card 以 `metadata.origin` 隱藏，但計畫仍存在。
>
> `metadata.origin` 存在 tool part 的 `message_parts.metadata_json`（`app_database.dart:158`）；`toolEventFromStoredPart` 會把它帶進 projection 的 event（`sqlite_chat_storage.dart:1097-1104`）。`user_clear` 與 `todo_v1_migration` 共用同一個欄位。

### 2.6 注入安全與大小

預設路徑是 synthetic state pair（§2.3.2），不再把 `<current_todo_list>` 放進 system prompt。Todo content 只出現在：

- synthetic pair 的 `arguments` / tool result JSON；
- UI 卡片；
- compaction 摘要（純文字）。

因此安全重點改成「JSON data-only + 長度上限」：

- canonical result builder 用 `jsonEncode`；tool description 宣告 item content 是資料；synthetic pair 的完整 snapshot 加 `notice`，真實精簡 result 不加，避免 token。
- `jsonEncode` 後把 `<` / `>` escape 成 `\u003c` / `\u003e`，避免 content 提前關閉任何標籤。
- 加 `maxItems` / `maxItemChars` / `maxTotalChars`；截斷時加 `_truncated: true`。
- UI 保留 status legend（`[ ]` / `[~]` / `[x]`）給人看；模型看 JSON。
- 真實 tool result：`changed=false` 只有 counts，`changed=true` 附 canonical items + warnings。
- synthetic pair 的 tool content 永遠是完整 canonical snapshot；與 UI/projection 共用同一個 builder，避免兩套格式。
- compaction 的 todo 摘要用同一份 projection，不從 raw arguments 重新猜；只放 `- ` 前綴的單行 item，strip 換行/控制字元，並 cap 數量與字元，不把 item content 放進指令句。明確 clear（items 空、`hasExplicitState: true`）顯示 `Todos: cleared`，不要顯示 `0/0`。

**Fallback**：若 provider 拒絕 synthetic pair，才退回 gated system block；此時 `renderTodoSnapshot` 必須是 JSON data block（含 `DATA ONLY` 宣告與 escape），且只在 `hasWriteTodos` 時注入。

---

## 3. 分階段實作

### Phase 0：防資料遺失（P0 hotfix，建議 2–3 天）

**目標**：即使架構還沒重構，也不能再因 malformed call 清空計畫、不能因初始化失敗靜默成功、卡片不能假 loading。

| # | 工作 | 檔案 |
|:--|:--|:--|
| 0-1 | 新增 lenient + strict parser：`coerceTodoList`、`content`/`task` alias、`status`/`completed` alias、明確 boolean；strict parser 供 canonical snapshot 用 | `todo_service.dart`（或新 `todo_models.dart`） |
| 0-2 | Handler 先驗證再寫入；**任何 invalid item → 整筆拒絕** `invalid_todos`（帶 `index`/`reason`），保留舊計畫；`todos: []` 才是 clear；成功回精簡 result（`changed`/`counts`；有改動才附 `items`/warnings） | `tool_handler_service.dart:776-801` |
| 0-3 | `TodoService` 初始化改 `_initFuture`，失敗可重試；`_box == null` 時丟明確錯誤，不靜默 no-op | `todo_service.dart:93-97` |
| 0-4 | `TodoPlanCard` 接 `loading/status/contentLoaded`；解析 `tool_error`、`interrupted`；spinner 只看 status/loading，不看 `content == null`；`content` 是含 `items` 的 `todo_snapshot` 時優先渲染 canonical items（`changed=false` 才用 arguments），避免 Phase 0 上線後卡片與正規化結果不一致 | `cowork_tool_cards.dart:40-86`、`chat_message_widget.dart:3489-3491` |
| 0-5 | 補測試：malformed args 不清空、single object/stringified array、`completed:"false"`、任何 invalid item 整筆拒絕、init 失敗、card 狀態（loading/completed/interrupted/error）、canonical result 優先 | 新測試檔 |

**Exit criteria**

- `todos` 缺少 / `null` / 無法 coercible → 舊計畫不變，回 `invalid_todos`。
- `todos` 是單一 object 或 stringified JSON array → 正規化後成功（若 item 有效）。
- 任何 item 無效 → 舊計畫不變，回 `invalid_todos` + index/reason，不寫 store。
- `todos: []` → 清空，回 `cleared: true`。
- `completed:"false"` → `pending`，不是 `completed`。
- 成功 result 在 `changed=false` 時不含 items；`changed=true` 時含 canonical items。
- `openBox` 失敗後重試可成功；`setTodos` 不再靜默成功。
- 還原後的 completed/interrupted card 不再永久 spinner。

### Phase 1：單一來源與 injection（P1，建議 4–6 天）

**目標**：模型與 UI 讀同一份 projection；injection 只在 tool 真的註冊時發生；system prompt 不再因 todo 變動；compaction 使用最新 snapshot。

> Phase 1 只建立**唯讀** projection 與 injection gate；handler 仍寫入 `TodoService`。Phase 2 才移除 store / 寫入路徑，維持「先修注入、再改單一真相」的順序。

| # | 工作 | 檔案 |
|:--|:--|:--|
| 1-1 | 拆出 `todo_models.dart` / `todo_projection.dart`；lenient + strict parser、coercion、alias、renderer 搬過去；同步把 `cowork_tool_cards.dart` 的 `todo_service.dart` import 改到 models（避免 Phase 2 刪檔時編譯失敗） | 新檔、`cowork_tool_cards.dart:22` |
| 1-2 | 用 projection 取代 `TodoService.getTodos` 的 nextAction（`message_generation_service.dart:146-162`）；取最新成功 snapshot | `message_generation_service.dart` |
| 1-3 | 抽 `hasWriteTodosEnabled` 純函式（與 `buildWorkspaceToolDefinitions` 同源；**不搬** `buildToolDefinitions`，見 §2.3.1）；在 `buildApiMessages` 前算 `hasWriteTodos`；同時 gate state pair 與 `compactionNextAction`/`todoSummary` | `message_generation_service.dart:194-205`、`:339-347`、`tool_handler_service.dart:324-348` |
| 1-4 | 移除 `injectTodoSnapshot`；改成 `appendTodoStatePair`（synthetic pair）；id 用最新 real `toolCallId`，碰撞 fallback hash；content 用完整 snapshot | `message_generation_service.dart`、`message_builder_service.dart:808-830` |
| 1-5 | 真實 tool result 改精簡格式（`changed`/`counts`；有改動才附 `items`+warnings）；不再回純文字 counts 字串 | `tool_handler_service.dart:776-801` |
| 1-6 | 投影用 `collapseVersions(messages, versionSelections)`，確保 version/regenerate 正確 | `todo_projection.dart`、`message_builder_service.dart:99-133` |
| 1-7 | Compaction 加 `Todos: x/y complete...` 摘要；取最新成功 snapshot；cap 長度；gate `hasWriteTodos` | `history_compactor.dart:378-460`、`message_generation_service.dart` |
| 1-8 | Tool description 補「3+ steps / ALL / review / skip simple」；修正「never stored」說法 | `tool_handler_service.dart:398` |
| 1-9 | 測試：gating（workspace/toggle/no-tools，含 compaction）、cache 前綴不變、in-turn result、最新 snapshot | 新測試檔 |

**Exit criteria**

- workspace 關閉 / toggle 關閉 / 模型不支援 tools → 不注入、不 append state pair、compaction 也不提計畫。
- todo 更新前後 `apiMessages[0]`（system）byte-identical。
- 模型呼叫 `write_todos` 後，下一輪 messages 的真實 tool result 是精簡格式；若 `changed=true` 則含 canonical items。
- synthetic pair 的 result 永遠含完整 canonical items；id 是最新 real `toolCallId` 或安全的 hash fallback。
- compaction 的 todo 摘要取最新成功 snapshot，不是第一筆。
- version 切換 / regenerate 的投影只反映選到的 branch。

### Phase 2：移除 `todo_v1` 與 lifecycle（P0，建議 3–4 天）

**目標**：不再有第二個 store；backup/restore/delete/fork 全部由 conversation events 自然處理。

| # | 工作 | 檔案 |
|:--|:--|:--|
| 2-1 | 停止寫入 `todo_v1`；正常讀取改 projection（migration fallback 例外） | `tool_handler_service.dart`、`message_generation_service.dart` |
| 2-2 | 一次性遷移（§2.5.3）；`todo_v1` 加入過渡期 `chatHiveFiles` | `chat_service.dart` 或新 migration service、`database_installation_gate.dart` |
| 2-3 | 刪除 `TodoService` 的寫入 API / provider / imports；保留 `todoToolName` 常數在 models；遷移 fallback 用唯讀 legacy reader | `todo_service.dart`、`main.dart:214`、`tool_replay.dart`、`workspace_tools_page.dart`、migration service |
| 2-4 | 更新 `chat_service.dart:227-233` 註解：Hive 是 checkpoint store，不是 todo | `chat_service.dart` |
| 2-5 | Eager `write_todos` content | `chat_repository.dart:893-897` |
| 2-6 | 確認 `write_todos` 仍在 `kNonReplayableToolNames`；transcript/event 是唯一來源（Anybuff 對照） | `tool_replay.dart:15-19` |
| 2-7 | 測試：backup round-trip、delete cascade、fork copies events、restore、migration、`changed=true` result 優先 | 新測試檔 |

**Exit criteria**

- 全 repo 不再有 `todo_v1` / `TodoService` 寫入路徑。
- backup → restore 後，卡片與模型注入都是同一份計畫。
- 刪除對話後無 orphan todo row；fork 後新 conversation 有 fork 點之前的計畫。
- 舊 `todo_v1` 有資料但沒有 event 的 conversation，遷移後仍看得到計畫（或 fallback 可讀）。
- 還原後 completed card 有 content 或可用 arguments + status 正確渲染，不轉圈。

### Phase 3：UI / UX / 清理（P2，建議 2–4 天）

**目標**：把「看得到、改得到、錯誤看得到」補完，並拆掉 workspace coupling。

| # | 工作 | 檔案 |
|:--|:--|:--|
| 3-1 | `TodoPlanSheet`：目前計畫、status、長內容展開 | 新 widget |
| 3-2 | 使用者 clear（已定案）：append `write_todos(todos: [])` tool part，`origin=user_clear`；必要時建 assistant message 容器 | `lib/features/home/controllers/chat_actions.dart` / chat service |
| 3-3 | 歷史卡片只展開最新一筆；舊卡折疊；header 顯示 progress/status | `cowork_tool_cards.dart` |
| 3-4 | 把 `write_todos` 從 workspace gate 拆出（已定案，`buildPlanningToolDefinitions`），由獨立 planning toggle 控制（預設開啟） | `tool_handler_service.dart:248-259`、`workspace_tools_page.dart` |
| 3-5 | Live dock：running task 的目前計畫顯示在 composer 上方，finish 後消失（Anybuff 對照） | 新 widget / chat page |
| 3-6 | 刪 dead code；更新 tool description、comments、docs | 多檔 |
| 3-7 | Widget / integration / migration 測試補齊 | 測試檔 |

**Exit criteria**

- 使用者可以從聊天頁查看目前計畫；沒有計畫時不誤顯示。
- `write_todos` 可在非 workspace 對話使用（已定案；獨立 planning toggle 預設開啟）。
- running 時有 live dock，finish 後 dock 消失但 transcript card 保留。
- 所有新舊測試綠燈；`flutter analyze` 無新 warning。

---

## 4. 檔案變更清單

| 檔案 | 變更 |
|:--|:--|
| `lib/core/services/chat/todo_models.dart`（新） | `TodoItem`、status、lenient + strict parser、`coerceTodoList`、alias、canonical result builder、renderer、`TodoState` |
| `lib/core/services/chat/todo_projection.dart`（新） | `projectTodoState`、event 掃描、最新成功 snapshot、branch/version 規則 |
| `lib/core/services/chat/todo_service.dart` | Phase 2 移除；read fallback 移到 migration service 的 `TodoV1LegacyReader` |
| `lib/features/home/services/tool_handler_service.dart` | 驗證（整筆拒絕 invalid item）、精簡 result、description、planning gate |
| `lib/features/home/services/message_generation_service.dart` | 先建 toolDefs/`hasWriteTodos`、projection nextAction、gate compaction、append state pair |
| `lib/features/home/controllers/chat_actions.dart` | Phase 3 user_clear：append `write_todos(todos: [])` event |
| `lib/features/home/services/message_builder_service.dart` | 移除 system injection；新增 `appendTodoStatePair`（完整 snapshot） |
| `lib/core/services/agent/compaction/history_compactor.dart` | todo 摘要、最新 snapshot、長度 cap |
| `lib/core/services/chat/tool_replay.dart` | 保持 non-replayable；import 改 models；更新「system-prompt tail」註解為 synthetic state pair |
| `lib/features/chat/widgets/cowork_tool_cards.dart` | 狀態機、錯誤/中斷、精簡 result、progress/status、長內容；`todo_service.dart` import 改 `todo_models.dart`（Phase 1） |
| `lib/features/chat/widgets/chat_message_widget.dart` | 傳 `loading/status/contentLoaded` |
| `lib/core/services/chat/storage/chat_repository.dart` | eager `write_todos` content；可選 latest todo query |
| `lib/core/services/chat/storage/database_installation_gate.dart` | 過渡期加入 `todo_v1` 到 `chatHiveFiles` |
| `lib/core/services/chat/chat_service.dart` | 更新 Hive/TodoService 註解；migration 入口 |
| `lib/main.dart` | 移除 `TodoService` provider（Phase 2） |
| `lib/features/chat/pages/workspace_tools_page.dart` | `todoToolName` import 改 models；planning gate 調整 |
| `lib/features/chat/widgets/todo_plan_sheet.dart`（新） | 目前計畫 UI |
| `test/cowork_todo_ask_user_test.dart` | 保留 pure function 測試；新增 parser cases |
| `test/core/services/chat/todo_parser_test.dart`（新） | coercion、alias、`completed:"false"`、整筆拒絕、caps |
| `test/core/services/chat/todo_projection_test.dart`（新） | latest event、clear、tool_error、changed result、branch/version |
| `test/core/services/chat/todo_lifecycle_test.dart`（新） | backup/restore/delete/fork/migration |
| `test/compaction/todo_compaction_test.dart`（新） | 最新 snapshot、todo 摘要、gating、cap |
| `test/features/chat/widgets/todo_plan_card_test.dart`（新） | loading/completed/interrupted/error、progress/status |
| `test/features/home/services/todo_injection_test.dart`（新） | gating、system byte-identical、in-turn compact result、synthetic pair id |

---

## 5. 測試矩陣

| 情境 | 預期 | 測試 |
|:--|:--|:--|
| `todos` 缺失 / null / 無法 coercible | `invalid_todos`；舊計畫不變 | parser + handler |
| `todos` 是單一 object | 包成 array；item 有效則成功 | parser + handler |
| `todos: {}` / 單一無效 object | 包成 array 後 item 無效 → `invalid_todos`；不清空 | parser + handler |
| `todos` 是 stringified JSON array / object | parse 後驗證；有效則成功 | parser |
| `todos: []` | clear；state `hasExplicitState` | handler + projection |
| 任何 item 空 content / 非 Map | `invalid_todos`；整筆拒絕；不清空 | parser + handler |
| 部分 item 無效 | `invalid_todos`；整筆拒絕；舊計畫不變 | parser + handler |
| item 用 `task` alias | 正規化 `content` + warning | parser |
| item 用 `completed` alias | `true` → `completed`、`false` → `pending` + warning | parser |
| `completed: "false"` | `pending`，不是 `completed` | parser |
| status `done` | normalize `completed` + warning | parser |
| 51 items / 超長 content | truncate + `truncated: true` | parser + schema |
| 多個 `in_progress` | warning，不失敗 | parser |
| 成功 result `changed=false` | 不含 items，只回 counts | handler |
| 成功 result `changed=true` | 含 canonical items + warnings | handler |
| tool event 是 `tool_error` | 投影忽略，不前進狀態 | projection |
| 舊版人類可讀 content | 用 arguments 投影，不忽略 | projection |
| 同一 message 多個 write_todos | 最後一筆成功者勝 | projection |
| 兩個 message version，各有不同計畫 | 依 `versionSelections` 投影 | projection |
| compaction 後 | 最新計畫仍可投影 | projection |
| compaction todo 摘要 | 取最新 snapshot，不是第一筆 | compaction |
| compaction item 含換行/控制字元 | 單行化 + cap；不逃逸 | compaction |
| backup → restore | 卡片與模型注入一致 | lifecycle |
| delete conversation | 無 orphan todo / part | lifecycle |
| fork conversation | fork 後保有 fork 點前計畫 | lifecycle |
| regenerate | 使用 regenerate 分支的計畫 | projection |
| workspace disabled | 無 tool、無 injection、無 compaction override | injection |
| per-tool toggle off | 無 tool、無 injection、無 compaction override | injection |
| model no tools | 無 injection、無 compaction override | injection |
| todo 更新前後 | system content byte-identical | injection |
| synthetic pair | 完整 canonical snapshot；id 用最新 real `toolCallId` | injection |
| synthetic pair id 碰撞 | fallback `todo_state_<stateHash>` | injection |
| write_todos 後同一輪 | 真實 result 精簡；`changed=true` 才有 canonical items | agent/integration |
| 還原 completed card | 不轉圈 | widget |
| 還原 interrupted card | 顯示中斷 | widget |
| tool_error card | 顯示錯誤，不顯示有效計畫 | widget |
| `changed=true` result 的 card | 顯示 canonical items，不是 raw arguments | widget |
| live dock | running 顯示；finish 消失；transcript card 保留 | widget |
| 惡意 content `</current_todo_list>` / `</tool>` | JSON escape；不逃逸 data block / tool result | renderer |
| 50 項 + 長 content | prompt 不超過 cap | renderer |

---

## 6. 驗收標準

- [ ] `todo_v1` 不再有寫入；所有計畫狀態可由 conversation events 重建。
- [ ] Backup/restore 後，plan card 與模型注入都恢復。
- [ ] 刪除對話不留下任何 todo 資料；fork 帶入 fork 點之前的計畫。
- [ ] Regenerate / 切換 message version 時，注入的是該分支的計畫，不是全域最新。
- [ ] `todos` 是單一 object 或 stringified JSON array 時可正規化成功。
- [ ] `todos` 型別錯誤、缺少、或**任何 item 無效**時，舊計畫保留，回 `invalid_todos` + index/reason，且不寫 store。
- [ ] `todos: []` 是唯一 clear 方式，且 UI 顯示清除。
- [ ] 成功 result 在 `changed=false` 時不含 items；`changed=true` 時含 canonical items + warnings。
- [ ] workspace 關閉 / toggle 關閉 / 模型不支援 tools 時，prompt 與 compaction knowledge block 都不再提到計畫。
- [ ] Todo 更新不改變 system prompt bytes；只有 tail state pair 變。
- [ ] synthetic pair 的 result 永遠含完整 canonical items；id 用最新 real `toolCallId` 或安全 fallback。
- [ ] 同一輪 `write_todos` 後，模型下一輪看到精簡真實 result；需要時含 canonical items。
- [ ] Compaction 的 todo 摘要取最新成功 snapshot，不是第一筆。
- [ ] Restored completed / interrupted card 不再無限 spinner；錯誤 card 顯示錯誤。
- [ ] `changed=true` 的卡片顯示 canonical items（與模型看到的一致）。
- [ ] Running 時有 live dock；finish 後 dock 消失但 transcript card 保留。
- [ ] Todo content 不能逃逸 data block 或 tool result；有 item/total 長度上限。
- [ ] 新舊測試全綠，`flutter analyze` 無新 warning。

---

## 7. 風險與緩解

| 風險 | 影響 | 緩解 |
|:--|:--|:--|
| Synthetic tool pair 被某些 provider 拒絕 | 請求 400 / 工具輪中斷 | 沿用既有 replay pair 形狀；加 Claude/Gemini/OpenAI parity test；必要時 fallback 成 gated system block |
| 整筆拒絕造成模型重試迴圈 | 計畫更新延遲 / 使用者覺得卡 | 錯誤帶 `index`/`reason`；tool description 明示完整格式；handler 不自動重試，讓模型自行修正；agent loop 的 max steps 仍是最後防線 |
| 精簡 result 讓模型不知道正規化結果 | 模型與 UI 認知分歧 | `changed=true` 一定附 canonical `items` + warnings；`changed=false` 時模型仍有自己的 tool call arguments；synthetic pair 永遠完整 |
| 真實 `toolCallId` 與既有 tool call 碰撞 | provider 400 / pair 配對錯誤 | append 前掃 `apiMessages` 的 tool_call id；碰撞即 fallback `todo_state_<stateHash>` |
| Compaction todo 摘要撐爆 knowledge block | 擠掉 Goal/Files/Edits | remaining 數量與字元數 cap；超過時只留 counts + 前 N 項 |
| Parser 分歧（handler / projection / UI） | 同一 event 三種解讀 | 全部走 `todo_models.dart`；strict parser 只給 canonical snapshot，lenient parser 給 legacy arguments |
| 沿用 Anybuff 的無上限 schema | prompt / token 暴增 | 保留 `maxItems` / `maxItemChars` / `maxTotalChars`，並在 JSON Schema 同步 |
| `Next Action` 取到舊 snapshot | 模型做過期工作 | 只用最新成功 snapshot；多 snapshot 測試 |
| Projection 掃描長 conversation 變慢 | 延遲 | 先用量測；必要時只查 `write_todos` parts 或加 index；materialized 狀態必須同 transaction |
| 遷移遺失舊 `todo_v1` 資料 | 使用者計畫消失 | 先 event 勝出；無 event 才合成；合成失敗保留 box fallback；記錄 log |
| 使用者 clear 產生額外卡片 | UI 雜訊 | metadata `origin=user_clear`；card 可顯示「已清除」或隱藏 |
| 超長 / 惡意 todo content | prompt injection / token 暴增 | JSON escape、data-only 宣告、maxItems/maxLength/maxTotalChars |
| `write_todos` 拆離 workspace gate 改變產品行為 | 使用者預期落差 | 已定案 Phase 3 拆出獨立 planning toggle；新 toggle 預設開啟以保持行為等價，並提供一版可回退開關 |
| 移除 Hive init 影響 checkpoint store | agent resume 壞 | 只移除 TodoService 理由；保留 `Hive.init` 給 `AgentRunCheckpointStore`，另開 ticket 遷移 |

---

## 8. 遷移與 rollout

1. **Phase 0/1 先上**：不動 `todo_v1`，只修 validation、init、card、injection gating；風險最低。
2. **Phase 2 遷移**：
   - 啟動時跑 `TodoV1Migration`（一次性，idempotent）。
   - 過渡期 `chatHiveFiles` 包含 `todo_v1`，pre-migration backup 可救。
   - 遷移成功後停止寫入；下一版刪 box file / code。
3. **Kill switch（可選）**：以 SharedPreferences `todo_event_projection_v1` 控制；預設 true。若 projection 出現問題，暫時 fallback 到 `todo_v1` 讀取（只讀），但不再寫入。下一版刪除 box file 時，kill switch 一併退役（fallback 已無資料可讀）。
4. **觀察點**：
   - `invalid_todos` 次數與「同一個 plan 重試次數」（模型輸入品質 / 整筆拒絕是否造成迴圈）。
   - `changed=true` 比例（alias / 截斷 / status normalize 的頻率）。
   - projection 找不到 state 但歷史有 plan card 的次數（event/arguments 解析問題）。
   - compaction todo 摘要是否過長或被 cap 的次數。
   - migration 失敗 / fallback 次數。
   - provider 對 synthetic pair 的 400 次數。
   - synthetic pair 使用 hash fallback 的次數（real `toolCallId` 缺失或碰撞）。
   - synthetic pair 佔 prompt 比例（arguments + content 各一份完整 snapshot；必要時調整 `maxTotalChars`）。

---

## 9. 已定案決策（2026-11-08 / 2026-11-09）

| # | 決策 | 結論 | 落地階段 |
|:--|:--|:--|:--|
| 1 | `write_todos` 是否拆離 workspace gate | **拆出獨立 planning gate**；新 toggle 預設開啟，非 workspace 對話也能使用 | Phase 3 |
| 2 | 是否提供使用者 clear | **提供**；寫成一筆成功的 `write_todos(todos: [])` event，`metadata.origin = 'user_clear'`，不提供純本地清除 | Phase 3 |
| 3 | 動態狀態的注入載體 | **Synthetic trailing tool pair**；沿用 replay pair 形狀，system prompt bytes 不變 | Phase 1 |
| 4 | 既有 `todo_v1` 資料 | **Event 優先＋必要時合成**；合成失敗保留唯讀 fallback，不阻塞啟動 | Phase 2 |
| 5 | 長度上限 | 採預設值 `maxItems=50`、`maxItemChars=2000`、`maxTotalChars=8000`；數值集中定義在 `todo_models.dart`，可依 token 預算調整 | Phase 0/1 |
| 6 | 輸入寬容度與 invalid item | **採 Anybuff 式 `coerceToArray` + alias**（`task`/`content`、`completed`/`status`、明確 boolean）；**任何 item 無效即整筆拒絕** `invalid_todos`，保留舊計畫，不寫 store | Phase 0 |
| 7 | 成功 tool result 形狀 | **精簡**：`changed=false` 只回 counts；`changed=true` 才附 canonical `items` + warnings；synthetic pair 永遠完整 snapshot | Phase 0/1 |
| 8 | Compaction todo 摘要 | **新增** `Todos: x/y complete...`；取最新成功 snapshot；gate `hasWriteTodos`；remaining 數量/字元 cap | Phase 1 |
| 9 | UI status / progress / live dock | **補 status/error/progress**；running 時 composer 上方 live dock，finish 後只留 transcript card | Phase 0/3 |
| 10 | Synthetic pair 的 id | **優先用最新成功 event 的 real `toolCallId`**；空值或碰撞 fallback `todo_state_<stateHash>`；不用時間戳 | Phase 1 |
| 11 | `hasWriteTodos` 的判定來源 | **純函式 `hasWriteTodosEnabled`**（`supportsTools` + workspace + per-tool toggle），與 `buildWorkspaceToolDefinitions` 同源；不搬 `buildToolDefinitions`（避開 skills warm-up 與 MCP 建置成本） | Phase 1 |

> 決策 2 的 UI 入口與決策 1 的 gate 拆分都在 Phase 3；Phase 0/1/2 不依賴它們，可先行實作。決策 6–11 是 2026-11-09 依 Anybuff 調查與實作前 review 新增；1–5 維持原結論。

---

## 10. 與現有計畫的關係

- 本計畫取代 `docs/Cowork剩餘項目實作計畫.md` 中「P1-3 TODO 已落地」的後續維護假設；P1-3 的功能範圍不變，但狀態所有權改為 conversation events。
- `ask_user_input_v0` 不動；它已經有「answer JSON upsert 成 tool event」的 conversation 語意，可作為 `write_todos` 的對照實作。
- 與 SQLite 遷移方向一致：chat 資料只剩 SQLite；Hive 僅保留 device-local 的 agent checkpoint（`agent_runs_v1`），不再為 `todo_v1` 保留 runtime 依賴。

---

## 11. Anybuff 參考索引

> 基準 HEAD：`6594bbd80b48ad80b44e6356b03dd50f63dbdfca`（2026-11-08）。

| 主題 | 路徑 | 重點 |
|:--|:--|:--|
| Tool schema / description | `common/src/tools/params/tool/write-todos.ts` | `:8-27` schema、`:28-52` description、`:59-66` output |
| 寬容陣列 | `common/src/tools/params/utils.ts` | `:21-33` `coerceToArray` |
| Stateless handler | `packages/agent-runtime/src/tools/handlers/tool/write-todos.ts` | `:10-19` 只回 `{message:'Todos written'}` |
| Host normalize | `packages/host-core/src/run/start-run.ts` | `:517-527` `UiEvent.todos`；注意 `Boolean()` |
| Contracts | `packages/host-core/src/contracts/types.ts` | `:11-14` `TodoItem`、`:34-35` toolCallId、`:39` tool `todos`、`:81` event `todos` |
| Session store | `packages/host-core/src/sessions/session-store.ts` | `:18-25` single source、`:190-220` tool card snapshot（`:199` real toolCallId） |
| Host-core extraction | `9dc13062d74bc2bff3383d1965b827cb6ab74f24` | Electron-free host；transcript/session store 成為 single source |
| Per-task state | `81df753b74f5397243ed63867ffd162d67b01a2c` | 多 tab 並行；`todosByTask` 隔離 |
| Transcript | `packages/host-core/src/settings/settings.ts` | `:1657-1684` save、`:1778-1788` load、`:1790-1801` delete |
| UI card | `desktop/src/renderer/src/components/ChatMessage.tsx` | `:456-483` `TodoCard`、`:485-557` `ToolCard` status/progress |
| UI dock | `desktop/src/renderer/src/App.tsx` | `:1681-1695` per-task state、`:4605` activeTodos、`:5403-5407` dock |
| Prompt | `agents/base2/base2.ts` | `:122` gating、`:501` 3+ steps、`:531` plan mode forbids |
| Compaction | `agents/context-pruner.ts` | `:431-437` first-snapshot Next Action、`:677-692` todo summary |
| No-force list | `common/src/tools/constants.ts` | `:12-23` 不含 `write_todos` |
| Tool introduced | `2bc8607144b44f0342871f5137124d47ebd4d133` | 初版 `write_todos` |
| Prompt tuning | `04a3759345130a71386a0a27a969f1b07c296808`, `ce635357394cb1f60be837d9ad79c5bc49669d42` | ALL applicable tasks；trivial tasks 不用 |
| Result dedup | `318ead2df33872679a07d548f4d558d4d528829c` | tool result 不再重複 todos |
| Coercion commit | `5edd8088d621ddf38c76a323de30c93e37f3fc08` | `coerceToArray` |
| Turn-end history | `0937bf461415f89e86cb273def271d1c377d0aa0` → `5e07e379bdeb1307e191b9c1c3d8bb10861c75c7` → `31b8421b918c662073ba0cfd8a090465c6944856` → `75c574de3ba8ad07f64d3f5447ef157c33d29b15` | all-complete 例外最後被移除 |
