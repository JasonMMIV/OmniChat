# 導入計畫：跨輪工具結果重放（Cross-Turn Tool Result Replay）

> **背景**：OmniChat 與上游 kelivo 為同一作者（psyche）的兩個分支（共同祖先 commit `cc6aa8fd`，2025-08-29）。分岔後 kelivo 於 2026-01-06（`02f606e7`「feat: add support for openai tool-call/tool-use messages」）起逐步實作「跨輪工具結果重放」，OmniChat 未跟上此演進線。
>
> **現況**：OmniChat 的 `MessageBuilderService.buildApiMessages()` 只輸出 `{role, content}` 純文字，工具事件（存於 `tool_events_v1` Hive box，`ChatService.getToolEvents`）僅用於 UI 卡片、匯出、備份，**從未重放進 API context**。因此 LLM 無法在下一輪「記住」先前輪次的工具呼叫與結果。
>
> **目標**：新增一個「跨輪工具結果」開關（位於 顯示設定 → 行為與啟動），預設開啟（對齊上游 kelivo 行為）；開啟時，每一輪組裝 context 都會把先前 assistant 訊息的 tool_calls + tool 結果重放給模型（對齊上游 kelivo 的 `includeToolMessages` 行為）。
>
> **✅ 已於 v1.18.6（2026-08-29）完成實作**：pubspec `1.18.6+96`；installer.iss 同步；開關預設 `true`。

---

## 目標項目總覽（✅ 全數完成）

| # | 項目 | 上游參考 | 狀態 | 實作檔案 |
|---|---|---|---|---|
| P1 | SettingsProvider 新增開關（`replayToolResults`） | —（自訂） | ✅ 完成 | `lib/core/providers/settings_provider.dart`（key `display_replay_tool_results_v1`，預設 `true`） |
| P2 | 行動端 UI：行為與啟動頁加開關 | —（自訂） | ✅ 完成 | `lib/features/settings/pages/display_settings_page.dart` → `BehaviorStartupSettingsPage`（`Lucide.Wrench` 圖示） |
| P3 | 桌面端 UI：設定頁行為區塊加開關 | —（自訂） | ✅ 完成 | `lib/desktop/desktop_settings_page.dart` → `_ToggleRowReplayToolResults` |
| P4 | l10n 文案（×4 語系）+ `flutter gen-l10n` | —（自訂） | ✅ 完成 | `app_{en,zh,zh_Hans,zh_Hant}.arb`（`displaySettingsPageReplayToolResultsTitle/Subtitle`）＋ `app_localizations*.dart` |
| P5 | `buildApiMessages` 加入 `includeToolMessages` 重放邏輯 | kelivo `message_builder_service.dart`（`02f606e7` 起） | ✅ 完成 | `lib/features/home/services/message_builder_service.dart`（含頂層 `toolResultContentForModel`） |
| P6 | `prepareApiMessagesWithInjections` 接上開關 | kelivo `message_generation_service.dart` | ✅ 完成 | `lib/features/home/services/message_generation_service.dart`（`includeToolMessages: settings.replayToolResults`） |
| P7 | provider 層格式轉換（OpenAI / Claude / Gemini） | kelivo `claude_history.dart` / `google_common.dart` / `chat_completions_api.dart` | ✅ 完成 | `lib/core/services/api/chat_api_service.dart`（OpenAI 保留結構＋`_preserveToolStructuredMessages`；Responses `function_call_output`/`function_call`；Claude `tool_use`/`tool_result` blocks（空結果→`(no output)`）；Gemini `functionCall`/`functionResponse`＋Gemini 3 thought signature） |
| P8 | edge cases：pending events、空結果、版本化、同步守則 | kelivo `9ebbba2e`、`claude_history.dart` | ✅ 完成（版本化限制記錄於下） | E1-E8 全處理；「重生成的版本無舊工具事件」為已知限制 |
| P9 | 測試（單元 + 整合） | 上游對應測試 | ✅ 完成 | `test/settings_provider_replay_tool_results_test.dart`、`test/message_builder_replay_tool_test.dart`、`test/replay_tool_results_api_test.dart`（120+ 測試通過） |

**額外涵蓋（超出原計畫）**：
- **voice chat 路徑**：`lib/core/services/chat/chat_turn_service.dart` 的 `buildApiMessages` 亦加入 `includeToolMessages`（由 `prepareTurnRequest` 的 `settings.replayToolResults` 控制）。
- **Gemini 3 thought signature**：重放的 `functionCall` 於 `_persistGeminiThoughtSigs`（gemini-3 模型）時自動補 `thoughtSignature` 佔位（原計畫列為「第一版不做」，實作時發現成本極低且可避免 Gemini 3 拒收，故一併加入）。
- **Claude 圖片轉換守衛**：`initialMessages` 的圖片轉換僅對 `content is String` 的使用者訊息套用，避免誤傷 List content 的 tool_result blocks（code-review 發現）。

---

## P1. SettingsProvider 新增開關

**檔案**：`lib/core/providers/settings_provider.dart`

比照既有 boolean 開關三件套（參考 `showTokenStats`，L2671-2680）：

1. **Key 常數**（與其他 `_xxxKey = 'xxx_v1'` 同區塊）：
   ```dart
   static const _displayReplayToolResultsKey = 'display_replay_tool_results_v1';
   ```
2. **欄位 + getter**：
   ```dart
   // 行為：跨輪工具結果重放
   bool _replayToolResults = true;           // 預設開啟（對齊上游 kelivo 恆開行為）
   bool get replayToolResults => _replayToolResults;
   ```
3. **`_load()`**：
   ```dart
   _replayToolResults = prefs.getBool(_displayReplayToolResultsKey) ?? true;
   ```
4. **setter**：
   ```dart
   Future<void> setReplayToolResults(bool v) async {
     if (_replayToolResults == v) return;
     _replayToolResults = v;
     notifyListeners();
     final prefs = await SharedPreferences.getInstance();
     await prefs.setBool(_displayReplayToolResultsKey, v);
   }
   ```

> **§5.7 同步守則**：此為全域行為偏好（跨裝置同步合理），**不加入** `data_sync.dart` 的 `_localOnlyKeys`。若日後改判為裝置私有，需補進該集合（含 `snapshot`/`restore`/`restoreSingle` 三路徑自動涵蓋）。

---

## P2. 行動端 UI：行為與啟動頁

**檔案**：`lib/features/settings/pages/display_settings_page.dart` → `BehaviorStartupSettingsPage`（L1170）

在現有開關列表中新增一行（建議放在「新對話啟動」`newChatOnLaunch` 之後，或「自動摺疊思考」之後；位置由實作時依視覺分群決定）：

```dart
_iosDivider(context),
_iosSwitchRow(
  context,
  icon: Lucide.Repeat,   // 或 Lucide.Workflow / Lucide.History，依 lucide_adapter 可用集
  label: l10n.displaySettingsPageReplayToolResultsTitle,
  value: sp.replayToolResults,
  onChanged: (v) => context.read<SettingsProvider>().setReplayToolResults(v),
),
```

需確認 `lib/icons/lucide_adapter.dart` 提供哪個圖示；若無 `Repeat`，改用既有已使用圖示（如 `Lucide.Workflow` / `Lucide.Bot`）。

---

## P3. 桌面端 UI

**檔案**：`lib/desktop/desktop_settings_page.dart`

- L5004 附近的「行為與啟動」區塊（`displaySettingsPageBehaviorStartupTitle`）內，比照行動端加對應開關（桌面端若用不同 switch widget / 排版，沿用該頁既有樣式）。
- 若桌面端行為區塊的開關有「自動摺疊思考」（L7217 `sp.autoCollapseThinking`）同區，直接仿照其寫法。

---

## P4. l10n 文案

**檔案**：`lib/l10n/app_en.arb`、`app_zh.arb`、`app_zh_Hans.arb`、`app_zh_Hant.arb`（4 語系皆須新增）

新增 key（含描述性 subtitle，建議兩行式：title + subtitle）：

```
displaySettingsPageReplayToolResultsTitle     → "Include prior tool results in context" / 「跨輪工具結果重放」等
displaySettingsPageReplayToolResultsSubtitle  → 說明「將先前輪次的工具呼叫與結果併入後續對話上下文，讓模型可參考（可能增加 Token 用量）」
```

> 比照其他開關：若現有 `_iosSwitchRow` 不支援 subtitle，可仿 `_iosSwitchRow` 擴充，或先只放 title（簡化）；subtitle 可留待後續。

執行 `flutter gen-l10n` 重新生成 `app_localizations*.dart`。

---

## P5. `buildApiMessages` 加入重放邏輯（核心）

**檔案**：`lib/features/home/services/message_builder_service.dart`

在 `buildApiMessages` 簽名加入 `bool includeToolMessages = false`（**預設 false = 完全向後相容**），並在組裝迴圈中、對每個 assistant message 插入重放：

```dart
List<Map<String, dynamic>> buildApiMessages({
  required List<ChatMessage> messages,
  required Map<String, int> versionSelections,
  required Conversation? currentConversation,
  bool includeToolMessages = false,          // ← 新增
}) {
  // ...既有 tIndex / collapseVersions ...
  final out = <Map<String, dynamic>>[];
  for (final m in source) {
    // ── 跨輪工具結果重放（移植自 kelivo `02f606e7` 起之邏輯）──
    if (includeToolMessages && m.role == 'assistant') {
      final events = chatService.getToolEvents(m.id);
      if (events.isNotEmpty) {
        // 工具歷史僅在「每個呼叫都有結果」時有效；有 pending（content==null）則整個跳過
        final hasPendingToolEvent = events.any((e) => e['content'] == null);
        if (!hasPendingToolEvent) {
          final calls = <Map<String, dynamic>>[];
          final toolMessages = <Map<String, dynamic>>[];
          for (int i = 0; i < events.length; i++) {
            final e = events[i];
            final name = (e['name'] ?? '').toString().trim();
            if (name.isEmpty) continue;
            final rawId = (e['id'] ?? '').toString().trim();
            final id = rawId.isNotEmpty
                ? rawId
                : 'call_${m.id.substring(0, min(m.id.length, 8))}_$i';  // 無 id 時產生穩定 fallback
            Map<String, dynamic> args = const <String, dynamic>{};
            final a = e['arguments'];
            if (a is Map) args = a.map((k, v) => MapEntry(k.toString(), v));
            String argumentsJson = '{}';
            try { argumentsJson = jsonEncode(args); } catch (_) {}
            calls.add({
              'id': id,
              'type': 'function',
              'function': {'name': name, 'arguments': argumentsJson},
            });
            toolMessages.add({
              'role': 'tool',
              'name': name,
              'tool_call_id': id,
              'content': toolResultContentForModel(e['content']?.toString()),  // 見 P8
            });
          }
          if (calls.isNotEmpty) {
            out.add({'role': 'assistant', 'content': '\n\n', 'tool_calls': calls});
            out.addAll(toolMessages);
          }
        }
      }
    }
    // ── 既有 assistant/user 純文字訊息邏輯（content 為空且無附件時跳過，比照上游）──
    // ...（原邏輯保留，但需處理「純工具 turn 的 content 可能為空」——上游用 mediaRefs 判斷，
    //     OmniChat 無 parts，先維持 `m.content.isNotEmpty` 過濾即可，工具 turn 通常 content 為 '\n\n' 或文字）...
  }
  return out;
}
```

**注意**：
- `jsonEncode` 需 `import 'dart:convert';`（確認該檔是否已 import）。
- OmniChat 的 `ChatMessage` 無 `parts`（上游有），故 `mediaRefsFromParts` 相關邏輯不移植；重放只靠 `getToolEvents(m.id)`。
- 純工具 turn（無文字）的 assistant message 其 `content` 可能為空——上游靠 mediaRefs 判斷是否保留，OmniChat 維持現況過濾（`content.isNotEmpty`）。此 edge case 在 P8 一併確認。

---

## P6. 接上開關

**檔案**：`lib/features/home/services/message_generation_service.dart` → `prepareApiMessagesWithInjections()`

```dart
// 現況：
final apiMessages = messageBuilderService.buildApiMessages(
  messages: messages,
  versionSelections: versionSelections,
  currentConversation: currentConversation,
);
// 改為：
final apiMessages = messageBuilderService.buildApiMessages(
  messages: messages,
  versionSelections: versionSelections,
  currentConversation: currentConversation,
  includeToolMessages: settings.replayToolResults,   // ← 開關
);
```

> 上游是 `switch(kind) { openai/claude/google => true }`（寫死）。我們改由開關控制；若未來要對齊上游「三家恆開」，只需把此處改為 `settings.replayToolResults && <kind 判斷>` 或直接 `true`。

---

## P7. provider 層格式轉換（高風險，關鍵）

重放產生的中立 tool 訊息（`role:'tool'` + `tool_call_id`，以及 assistant 的 `tool_calls`）必須在各 provider body 建構處正確轉換，否則 API 拒收。

**檔案**：`lib/core/services/api/chat_api_service.dart`（OmniChat 為單一巨型檔，邏輯在 `_sendOpenAIStream` / `_sendClaudeStream` / `_sendGoogleStream` 及其 body 建構處）

### P7a. OpenAI（chat-completions 路徑）
- **中立格式與 OpenAI 格式幾乎一致**：`role:'tool'` + `tool_call_id` + `content`、assistant 帶 `tool_calls`。
- 需確認現有 body 建構迴圈（`final mm = <Map<String, dynamic>>[];` 附近，L2307）對「非 system/user 角色」的處理——上游 `chat_completions_api.dart:32-61` 有 `_cleanToolMessages` 類邏輯（`role=='tool'` 時保留 `tool_call_id`、移除多餘欄位）。OmniChat 對照補上。
- **Responses 路徑**（`useResponseApi == true`）：上游 `openai_provider.dart:259-261` 把 `role:'tool'` 轉為 `function_call_output`。OmniChat 若走 Responses，需比照。
- 既有 `_truncateToolResultsInMessages` 已會截斷 `role=='tool'` 的長 content（32KB），無需改。

### P7b. Claude
- **需新增轉換**：中立 `role:'tool'` → user 訊息內的 `{type:'tool_result', tool_use_id, content}` blocks；assistant `tool_calls` → user/assistant 內 `{type:'tool_use', id, name, input}` blocks。
- 參考上游 `lib/core/services/api/providers/claude/claude_history.dart`（`_readTurn`、`_toolUseBlockFromToolCall`、`_plainMessage` 等，約 350 行）。
- **空結果佔位**：`claudeToolResultContent()` → 空字串換成 `'(no output)'`（Anthropic 拒絕空 text block）。
- 上游還有 `reasoning_content` / `reasoning_details` 重放與 `claudeReplayMetadata`（`server_tool_use` 相關）——**OmniChat 第一版可先不做**（沒有 server_tool_use 場景），但需在計畫中標註為「未涵蓋」。

### P7c. Google Gemini
- **需新增轉換**：中立 `role:'tool'` → `contents` 內 `{role:'user', parts:[{functionResponse:{name, response}}]}`；assistant `tool_calls` → `{role:'model', parts:[{functionCall:{name, args}}]}`。
- 參考上游 `lib/core/services/api/providers/google_common.dart`（L485 附近 `_googleFunctionResponsePartFromToolMessage`、L224 `_googleFunctionCallPartFromToolCall`）。
- 上游有 `_ensureGeminiFunctionCallThoughtSig`（Gemini 3 thought signature）——**第一版可不做**，標註。

### P7d. 版本化 / 重生成
- OmniChat tool events 以 `assistantMessageId` 為 key（`tool_events_v1`），**無 groupId/version 概念**。
- 重生成（新版本）時，該版本是新的 assistant message id → tool events 自然為空 → 重放不出舊版工具（行為等同「新版本不含舊工具」）。上游新版以 `message.parts` 存 ToolCallPart 並隨版本走；OmniChat 的 `_toolEventsBox` 沒有。
- **決策**：第一版接受「重生成的版本無舊工具事件」此限制（視為合理：重生成 = 重新回答，不需要舊工具痕跡）。若需對齊上游需大改儲存結構，不在本次範圍。**在計畫中明確記錄此限制。**

---

## P8. edge cases（與 P5/P7 一併處理）

| # | 情境 | 處理 | 上游參考 |
|---|---|---|---|
| E1 | pending tool event（`content == null`，工具尚未執行完/被中斷） | 該 assistant message **整段跳過**重放（不產出半套 tool_calls） | `9ebbba2e`「prevent building API tool calls for pending tool events」 |
| E2 | 工具結果為空字串 | OpenAI 原樣；Claude 換 `'(no output)'` | `claude_history.dart` |
| E3 | tool event 無 `id` | 產生穩定 fallback id（`call_{msgId前8}_{idx}`） | 上游同邏輯 |
| E4 | 同一 assistant 訊息含多個工具 | 依序展開為多個 tool_calls + 多個 tool 訊息，順序對齊 | 上游 |
| E5 | `arguments` 序列化失敗 | fallback `'{}'` | 上游 |
| E6 | 長結果 | 既有 `_truncateToolResultsInMessages`（32KB head/tail）自動涵蓋 | 既有 |
| E7 | MCP 結構化結果（metadata/圖片） | 上游有 `toolResultContentForModel`（legacy envelope → Markdown）。OmniChat 的 `_boundToolResultForPersistence` 已處理 MCP 結果；重放時直接用存好的 `content` 字串 | 上游 `mcp_structured_image.dart` |
| E8 | 開關關閉 | `includeToolMessages: false` → 完全等於現況，零行為改變 | — |

---

## P9. 測試

1. **`test/settings_provider_*_test.dart` 模式**：新增 `test/settings_provider_replay_tool_results_test.dart`——mock SharedPreferences，驗證 load 預設 false、set 後持久化。
2. **`test/message_builder_service` 單元測試**（若現有測試檔存在則擴充；否則新建 `test/cross_turn_tool_result_replay_test.dart`）：
   - `includeToolMessages: false` → 輸出與現況一致（無 tool 訊息）。
   - `includeToolMessages: true` + assistant 有 tool events（全有 content）→ 輸出含 assistant `tool_calls` + 對應 `role:'tool'` 訊息，順序正確。
   - pending event（`content == null`）→ 整段跳過。
   - 多工具順序對齊；無 id fallback；`arguments` 序列化。
3. **provider 轉換測試**（比照既有 `deepseek_claude_compat_test.dart` / `claude_dynamic_web_search_test.dart` 的 HttpServer 端到端風格）：
   - Claude：body 的 messages 含 `tool_result`/`tool_use` blocks 且格式正確。
   - Gemini：contents 含 `functionResponse`/`functionCall`。
   - OpenAI：保留 `role:'tool'` + `tool_call_id`。

---

## 驗證與收尾（✅ 已執行）

```bash
flutter gen-l10n                                    # ✅ 通過
flutter analyze --no-pub                            # ✅ 0 errors（3904 issues 全為既有 warning/info）
flutter test <新增+回歸>                              # ✅ 120+ 測試全數通過（含既有 chat/api/settings 回歸）
```

- 版本號：✅ `pubspec.yaml` → `1.18.6+96`；`msix_config.msix_version` → `1.18.6.0`；`installer.iss` → `1.18.6`（`OmniChat_windows_v1.18.6_setup`）。
- 手冊更新：待使用者確認後補（`OmniChat 專案開發與維護手冊.md` §3.5 附近「跨輪工具結果重放」段落，記錄開關、行為、已知限制）。
- commit 慣例：`feat(chat): cross-turn tool result replay toggle (behavior & startup)`（本次 commit 採用）。

---

## 風險與注意

- **P7 是最大風險**：Claude/Gemini 的轉換若格式錯，API 直接 400。務必先用端到端測試（HttpServer 捕獲 body）驗證三格式。
- **AI Team / voice chat 路徑**：`ChatTurnService`（voice）的 `buildApiMessages` 是獨立實作（`lib/core/services/chat/chat_turn_service.dart`），本次**不動**；若未來要涵蓋 voice 再另行規劃。AI Team 的 proposer/aggregator 走 `chat_actions._cloneForProposer` 等，會沿用主路徑的 apiMessages（含重放）——需在測試中確認不破壞 AI Team。
- **token 成本**：開啟後 prompt 會變長（工具結果重放）。已用 `_truncateToolResultsInMessages` 截斷緩解；subtitle 文案需提醒使用者。
- **`lucide_adapter`**：圖示需確認可用集，避免編譯錯誤。
- **`dart:convert`**：`message_builder_service.dart` 需 `jsonEncode`，確認 import。
- **上游未涵蓋部分**（第一版不做，記錄即可）：`server_tool_use` / `pause_turn` replay、Gemini thought signature 重放、`reasoning_details` 重放、版本化 tool events 儲存。

---

## 附：上游參考對照（移植時直接讀取）

| 上游檔案 | 用途 |
|---|---|
| `lib/features/home/services/message_builder_service.dart`（`buildApiMessages`，含 `includeToolMessages` 區塊） | P5 核心邏輯 |
| `lib/features/home/services/message_generation_service.dart`（L134 `includeToolMessages` switch） | P6 開關接線參考 |
| `lib/core/services/api/providers/claude/claude_history.dart` | P7b Claude 轉換 |
| `lib/core/services/api/providers/google/google_common.dart`（L224/L485） | P7c Gemini 轉換 |
| `lib/core/services/api/providers/openai/chat_completions_api.dart`（L32-61） | P7a OpenAI tool 訊息清理 |
| `lib/core/services/api/providers/openai/openai_provider.dart`（L259-261） | P7a Responses `function_call_output` |
| `lib/utils/mcp_structured_image.dart`（`toolResultContentForModel`） | E7 MCP 結果處理參考 |

> 上游已 clone 於 `/tmp/kelivo-upstream`（shallow clone；如需完整歷史可 `git fetch --unshallow`）。
