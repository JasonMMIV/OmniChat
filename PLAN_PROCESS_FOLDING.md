# 計畫：過程收褶（Process Folding）— 思考卡片與工具卡片比照 Anybuff 呈現

> **版本**：v1.0（草案）→ **v1.1 修訂定稿（2026-10-05 已實作完成，見 §8）** → **v1.2 實測修訂（同日）** → **v1.3 計時語意修訂（同日，見 §8.2）**
> **修訂（v1.1）**：使用者否決「思考段去卡片頭改連續灰字」——思考卡片比照工具卡片，保留原本完整樣式，僅隨群組收褶。
> **修訂（v1.2）**：實測後用時只留在**群組標題**（每則訊息一個計時）；**思考卡片不再顯示用時**（避免一則訊息多張計時器）。
> **修訂（v1.3）**：群組計時改量**整段過程**（新增 `ChatMessage.processStartedAt`／`processFinishedAt`，起點＝首個過程事件、終點＝最後一個過程事件），修掉完成瞬間數字倒退、以及純工具／工具先行的訊息漏算前導工具時間兩個缺陷。
> **日期**：2026-10-05
> **狀態**：可行性評估完成 → **可行**，待核准後實作
> **參照實作**：`C:\Users\w2bn1\GitHub\Anybuff`
> - `desktop/src/renderer/src/utils/chat-groups.ts`（純邏輯，含單元測試 `desktop/test/chat-groups.test.ts`）
> - `desktop/src/renderer/src/components/ProcessGroup.tsx`（UI 殼）
> - `desktop/src/renderer/src/styles.css` §Process group（樣式）

---

## 0. 需求重述

將 OmniChat 聊天訊息中的「思考過程」（深度思考卡片）與「工具呼叫卡片」，由現行**各自獨立的卡片列**，改為比照 Anybuff 的**單一收褶群組**：

- 群組標題列以 `▸` 三角形呈現，執行中顯示 **`處理中...`**（英文 `Working...`）＋三點彈跳動畫，並**展開**顯示內容；
- 思考與工具全部執行完畢後，標題翻轉為 **`已完成`**（英文 `Worked`），並**自動收褶**；
- 使用者可手動點擊展開／收褶；手動選擇後**釘選**（不再被自動行為覆蓋）。

---

## 1. Anybuff 參照行為拆解（目標規格）

### 1.1 純邏輯層（`chat-groups.ts`）

- `buildChatNodes(items, { streaming })` 將時間線摺疊為三種節點：
  - **process 群組**：兩個正文區塊之間「思考卡片 + 工具卡片 + 串流佔位點」的**最大連續 run**，共用一個收褶頭；
  - **body**：含可見正文的 assistant 項目，照常渲染泡泡（其 reasoning 已被抽離進群組）；
  - **plain**：使用者訊息／系統列——會**關閉**當前群組。
- **live（→ 顯示 `Working…`）判定**：群組內含執行中工具（`tool.status === 'running'`）、串流中的思考、dots 佔位，**或**串流中且該群組位於時間線尾部（補「工具已結束、下一事件未到」的空窗）。完成後標題變 `Worked`。
- 完成過的段落**永遠不會**誤閃 `Working…`（live 僅限尾群組）。

### 1.2 收褶狀態機

```ts
isGroupOpen(explicit, live) = explicit ?? live
```

- `explicit === undefined`：跟隨執行狀態——**執行中展開、完成自動收褶**；
- 使用者手動切換過 → `explicit` **永久釘選**，勝過一切自動行為（含結束後的自動收褶）。

### 1.3 UI 殼（`ProcessGroup.tsx` + 樣式）

- 標題列：三角形（收合 `▸`／展開 `▾`，`AnimatedRotation`）＋ mono 標籤 `Working`／`Worked`＋（live 時）CSS 三點彈跳；
- 樣式準則：**不用強調色**——live 狀態由「文字語義（Working/Worked）＋三點動畫」承擔，避免搶走正文視覺焦點；標籤沿用卡片文字色（比照現行 `cardTextColor`）；
- 展開本體（`process-body`）：內含原本的思考內文列與工具卡片列。

---

## 2. OmniChat 現狀（被改動的區域）

| 區域 | 檔案 / 位置 | 現行行為 |
|:--|:--|:--|
| 混合內容渲染 | `lib/features/chat/widgets/chat_message_widget.dart` ~L1874–L2076 | `reasoningSegments`（每段帶 `toolStartIndex`）× `toolParts` 交錯渲染：每段一張 `_ReasoningSection` 卡 + 其後的 `_ToolCallItem` 列；另有 fallback 路徑（單一 `reasoningText` / inline think 區塊 + 工具列） |
| 思考卡片 | 同檔 `_ReasoningSection` ~L4010 | 自有標題（deepthink 圖示 + 「深度思考」＋計時＋chevron）；loading 未展開時 80px 自動捲動預覽；收合受 `autoCollapseThinking` 控制 |
| 工具卡片 | 同檔 `_ToolCallItem` ~L3181 | 單行列卡（loading 轉圈 / 完成換圖示），點擊開詳情；特殊卡：`TodoPlanCard`／`AskUserCard`／`ApprovalToolCard`／`workspace_snapshot`（不渲染） |
| 狀態保存 | `features/home/controllers/stream_controller.dart`（記憶體） | `reasoning[messageId]`、`reasoningSegments[messageId]`（每段 `expanded`）、`toolParts[messageId]`；**不進 Hive** |
| 訊息列表組裝 | `lib/features/home/widgets/message_list_view.dart` ~L546–L572 | 組裝 `ReasoningSegment` 與 `toolParts` 傳入 `ChatMessageWidget` |
| 設定閘門 | `core/providers/settings_provider.dart` | `showThinkingCards`／`showToolCards`／`autoCollapseThinking`（預設 true）／`enableReasoningMarkdown` |

**關鍵既有事實**：OmniChat 的全部思考＋工具軌跡都發生在**單一 assistant 訊息內、正文之前**（agent loop 逐輪附掛 tool events，正文最後到齊）。因此 Anybuff 的「兩個正文之間的最大 run」在 OmniChat 退化為**每則 assistant 訊息至多一個群組**——不需要跨訊息分組，實作大幅簡化。

---

## 3. 可行性評估

### 3.1 結論：**可行**，且改動範圍收斂

| Anybuff 概念 | OmniChat 對應 | 既備性 |
|:--|:--|:--|
| process entries（思考+工具 run） | `reasoningSegments` + `toolParts`，交錯順序已由 `toolStartIndex` 編碼 | ✅ 資料已就緒 |
| tool `status === 'running'` | `ToolUIPart.loading` | ✅ |
| thought streaming | `segment.loading`（`finishedAt == null && text.isNotEmpty`） | ✅ |
| dots 佔位 | 泡泡內既有 `LoadingIndicator`（串流且尚無正文時） | ✅ 保留即可 |
| live 尾群組判定 | `message.isStreaming && (任一 loading || 尚無正文)` | ✅ 純推導 |
| explicit 釘選 | 新增 `processGroupExplicitOpen[messageId]`（記憶體，比照 segment `expanded` 的保存方式） | 🔨 少量新增 |
| 純邏輯可單測 | 抽 `process_group_logic.dart` 純 Dart 函式 | 🔨 新檔 |

### 3.2 必須處理的 OmniChat 特有邊界（Anybuff 沒有的）

| # | 情境 | 處理契約 |
|---|:--|:--|
| B1 | **審批 Pending 卡（`ApprovalToolCard`）與未回答 `AskUserCard`** 需要使用者操作才能 resume | 群組含此類卡時**強制展開並視為 live**（標題維持 `處理中...`），且忽略 explicit 收褶——絕不可被收褶藏起而卡死「中斷 → 決定 → 恢復」管線（手冊 §3.14 §2） |
| B2 | `autoCollapseThinking` 設定 | 語義映射：`true`（預設）＝Anybuff 行為（完成即收）；`false`＝完成後維持展開（標題仍翻 `已完成`）。**不新增設定鍵**，沿用既有「顯示設定」開關 |
| B3 | `showThinkingCards`／`showToolCards` 開關 | 仍於群組**內**過濾；兩者皆關、或過濾後無任何可摺項目（`builtin_search`、legacy `workspace_snapshot` 已剔除）→ **整個群組不渲染**（不出空殼） |
| B4 | inline `<think>`／`<thought>` 區塊（模型直接在 content 內輸出 think 標籤，經 `THINKING_REGEX` 萃取，非 `reasoningText` 欄位） | fallback 路徑的 `extractedThinking` 同樣摺入群組；`_inlineThinkExpanded` 手動切換語義併入 explicit 釘選 |
| B5 | AI Team「協作過程」區塊 | **維持不變**（自有摺疊與「最終回答」語義），不摺入群組 |
| B6 | Windows `SelectionArea` 禁區（手冊 §5.1） | 群組內 reasoning 內文沿用現行守衛：**僅非串流時**包 `SelectionArea`；串流中為純 widget，不新增任何平台守衛缺口 |
| B7 | 訊息列表滾動錨定 | 群組自動收褶瞬間高度驟變，沿用訊息層既有的 RepaintBoundary 與列表錨定機制；列入手動驗收項（長訊息 + 多工具輪次） |
| B8 | 舊對話（僅有 Hive 持久化的 `reasoningText`、無 segments） | fallback 路徑統一走同一群組；歷史訊息一律 `已完成`（收褶） |
| B9 | 匯出（`message_export_sheet.dart` 的 `_ExportThinkingCard`／`_ExportToolCard`） | **不動**——匯出語義與聊天 UI 解耦 |
| B10 | voice chat / deep research 路徑 | 不渲染這些卡片，**不受影響** |

---

## 4. 實作計畫（分階段）

### Phase 1 — 純邏輯層（可單測，移植 `buildChatNodes` 退化版）

新增 `lib/features/chat/widgets/process_group_logic.dart`（純 Dart、無 Flutter 依賴）：

```dart
/// 一個過程項目：思考段或工具卡
sealed class ProcessEntry { ... }
class ThoughtEntry extends ProcessEntry { final String text; final bool streaming; }
class ToolEntry extends ProcessEntry { final ToolUIPart part; }

class ProcessGroupModel {
  final List<ProcessEntry> entries; // 交錯順序保留
  final bool live;                  // → 標題 Working/Worked
  final bool forcedOpen;            // → B1 審批/ask_user 強制展開
  final bool visible;               // → B3 空群組不渲染
}

/// 輸入：segments、toolParts、isStreaming、hasAnswerText、
/// showThinkingCards / showToolCards / autoCollapseThinking
ProcessGroupModel buildProcessGroup({ ... });

/// Anybuff isGroupOpen 的移植 + B1/B2 修飾
bool resolveProcessOpen({ required bool? explicitOpen, required ProcessGroupModel m, required bool autoCollapse });
```

測試 `test/process_group_logic_test.dart`：
- live 判定矩陣（執行中工具／串流思考／串流尾端尚無正文／全部完成→非 live；歷史訊息→非 live）；
- 交錯順序保留（segment.toolStartIndex 切分工具區間）；
- `builtin_search`／`workspace_snapshot` 剔除後空群組 → `visible = false`；
- B1：approval-pending / 未回答 ask_user → `forcedOpen = true` 且 live；
- B2：`autoCollapseThinking == false` → 完成後 open 維持 true；
- explicit 釘選勝過 live 轉換。

### Phase 2 — UI 殼與 l10n

新增 `lib/features/chat/widgets/process_group_card.dart`：

- 標題列：`AnimatedRotation`（`expanded ? 0.25 : 0.0`，與現行 chevron 同參數）＋ l10n 標籤＋live 時三點彈跳（小型自繪動畫，三個 `AnimatedOpacity`/縮放圓點，100ms 級）＋計時 `(12.3s)`（沿用現行 `_elapsed` 與 `_Shimmer`）；
- 本體：`AnimatedSize`（沿用現行 translation/reasoning 同款 300ms 曲線 `Cubic(0.2, 0.8, 0.2, 1)`）；
- 思考段在群組內改為**連續灰字內文**（沿用 `_ReasoningSection` 的 `_reasoningContent` 樣式與 `enableReasoningMarkdown` 分流，但**去掉個別卡片標題**；計時移至群組標題）——即把 `_ReasoningSection` 重構為內容件 `_ReasoningBody`；
  > **【2026-10-05 修訂（v1.1）— 使用者否決上述設計】** 思考段保留**原版完整卡片**（deepthink 圖示＋標題＋展開/收合，逐字還原 HEAD 的 `_ReasoningSection`＋`_Shimmer`），僅隨群組收褶；**不**重構 `_ReasoningBody`。
  >
  > **【2026-10-05 修訂（v1.2）— 實測回饋】** 計時只放**群組標題**（`startAt` = 訊息層 reasoning 起點、`finishedAt` = 群組非 live 時的 reasoning 終點，即收褶前的計時契約）；思考卡片**不顯示用時**（`_ReasoningSection` 的 `startAt`／`finishedAt`、`_elapsedTick`／`Ticker` 一併刪除，`ReasoningSegment`／`ProcessThought`／`ThoughtEntry` 的時間透傳欄位同步移除）。
- 工具卡維持現行 `_ToolCallItem` 單行列（含 provider 徽章、fallback 提示、TodoPlanCard/AskUserCard/ApprovalToolCard 特殊渲染）。

l10n（4 份 arb + gen）：
| key | en | zh / zh_Hans | zh_Hant |
|:--|:--|:--|:--|
| `processGroupWorking` | `Working...` | `处理中...` | `處理中...` |
| `processGroupWorked` | `Worked` | `已完成` | `已完成` |

### Phase 3 — 接線

| 檔案 | 改動 |
|:--|:--|
| `chat_message_widget.dart` | 混合內容區塊與 fallback 區塊改為：`buildProcessGroup` →（visible 時）單一 `ProcessGroupCard`。**【修訂】** `_ReasoningSection` 保留為群組內思考列渲染件（不被取代）；`_inlineThinkExpanded` 自動收褶邏輯**保留**，fallback 路徑仍驅動個別卡片展開狀態 |
| `message_list_view.dart` | 傳入 explicit 狀態與 toggle callback（比照 `onToggleReasoningSegment`） |
| `stream_controller.dart` | 新增 `processGroupExplicitOpen: Map<String, bool>`（記憶體）＋ `toggleProcessGroup(messageId)` |
| `home_page_controller.dart` / `home_page.dart` | 接上 toggle；`toggleReasoningSegment` 保留 API 但 chat 路徑不再逐段呼叫 |

### Phase 4 — 驗證

1. `flutter analyze` → 0 errors；
2. `flutter test` → 全數通過（含新增 `process_group_logic_test.dart`；既有 700+ 項不回歸）；
3. 手動驗收（Windows + Android）：
   - 新對話：工具執行中 → 群組展開、標題 `處理中...`＋三點；完成 → 標題 `已完成`、自動收褶；
   - 手動展開後完成 → **維持展開**（釘選）；再手動收褶 → 維持收褶；
   - 審批卡／ask_user：群組強制展開、標題 `處理中...`，核准後恢復正常流程；
   - 舊對話載入：一律 `已完成` 收褶，展開可看完整 reasoning 與工具列；
   - 長訊息滾動不跳動；深淺色主題對比正常。

### Phase 5 — 文件更新（手冊維護指引：屬「架構層級變更」）

- 手冊 §3.9（UI/UX）新增「過程收褶」小節：群組規則、live 判定、explicit 釘選、B1 強制展開契約；
- 手冊 §4 決策表新增一列：**過程收褶（移植自 AnyBuff）**——每訊息單一群組（退化情形）；審批/ask_user 卡強制展開；`autoCollapseThinking` 語義映射為「完成是否自動收褶」。

---

## 5. 風險與對策

| 風險 | 對策 |
|:--|:--|
| 串流高頻重建 × `AnimatedSize` 量測成本 | 沿用現行 reasoning/translation 已驗證的同款模式；訊息層已有 RepaintBoundary；必要時對 body 加 `RepaintBoundary` |
| 自動收褶造成列表跳動 | 僅在「串流結束」邊界收褶一次（與 Anybuff 相同）；列入 B7 手動驗收；必要時比照訊息列表既有的 pinned-indicator 錨定手法 |
| 移除 `_ReasoningSection` 波及未知呼叫點 | Phase 3 前先全域 grep；`_ExportThinkingCard` 為獨立實作不受影響 |
| 群組收褶與訊息多選／分享選取的互動 | 群組僅改變折疊顯示，不變更訊息模型與事件資料，無互斥面 |

---

## 6. 估工

| 項目 | 估時 |
|:--|:--|
| Phase 1 純邏輯 + 單元測試 | 0.5 天 |
| Phase 2 UI 殼 + l10n | 0.5 天 |
| Phase 3 接線 + inline think 併軌 | 0.5 天 |
| Phase 4 驗證（analyze/test/雙平台手動） | 0.5 天 |
| **合計** | **約 2 個工作天** |

---

## 7. 明確不做（Out of Scope）

- 不改 tool events 的資料形狀與 Hive 持久化（§3.11 重放不受影響）；
- 不改匯出 sheet、AI Team 協作過程區塊、voice chat、deep research；
- 不新增設定鍵；不改動 `showThinkingCards`／`showToolCards` 的既有語義；
- 不做跨訊息群組合併（OmniChat 單訊息內已足夠）。

---

## 8. 實作記錄（2026-10-05 修訂定稿）

使用者修訂：**否決原計畫「思考段去卡片頭改連續灰字」**——思考卡片比照工具卡片，保留原本完整樣式，僅隨群組收褶。已照修訂實作：

- `process_group_logic.dart`：`ProcessThought`／`ThoughtEntry` 增加 `expanded`／`startAt`／`finishedAt`／`onToggle` 透傳欄位（皆有預設值，既有測試不需改）；
- `chat_message_widget.dart`：從 git HEAD 逐字還原 `_ReasoningSection`＋`_Shimmer`（剔除死碼 `_sanitizedeepthink`，`_Shimmer` 改用 `withValues`）；群組內思考列由呼叫端原版卡片渲染（圖示、標題、計時、展開/收合全部保留），刪除 `_ReasoningBody`；**群組標題不帶計時**（ProcessGroupCard 不傳 startAt/finishedAt）；inline think 的 `_inlineThinkExpanded` 狀態與 initState/didUpdateWidget 自動收褶邏輯還原；
- toggle 鏈（review 定稿）：list 層綁定 messageId 後以 `(open, forcedOpen)` 呼叫——widget 傳「當下渲染的 resolvedOpen」＋B1 forcedOpen，home_page 只做 `!open` 取反與 `forcedOpen` 短路，controller 端不重算；
- 驗證：`process_group_logic_test.dart` 新增透傳測試（28 項全過）；全量 `flutter test` 通過；`flutter analyze` 0 errors；`flutter build windows --release` 通過。

### 8.1 v1.2 修訂（實測後，同日）

使用者的實測結論：**思考卡片保留原樣即可，但用時應回到群組標題**（一則訊息只要一個計時）。實作調整：

- `chat_message_widget.dart`：`ProcessGroupCard` 重新傳入 `startAt: widget.reasoningStartAt`、`finishedAt: model.live ? null : widget.reasoningFinishedAt`（群組 live 時不凍結，讓工具尾巴的時間繼續算）；`_ReasoningSection` 刪除 `startAt`／`finishedAt` 參數、`_elapsedTick`、`Ticker`、`_elapsed()` 與標題列的計時區塊（並移除已無用途的 `SingleTickerProviderStateMixin`）；
- `process_group_logic.dart`：`ProcessThought`／`ThoughtEntry` 移除 `startAt`／`finishedAt`（思考卡不再計時，群組標題是唯一計時來源），保留 `expanded`／`onToggle` 透傳；
- `message_list_view.dart`：`ReasoningSegment` 同步移除 `startAt`／`finishedAt`（`loading` 仍由 `entry.value.finishedAt` 推導，資料面不變）；
- 測試：`process_group_logic_test.dart` 透傳測試改為驗 `expanded`／`onToggle`；`process_group_card_test.dart` 的計時測試不動（那些是群組標題的計時，現在重新接回生產路徑）；
- 驗證：`flutter analyze` 0 errors、全量 `flutter test`（875 項）通過、`flutter build windows --release` 通過。

### 8.2 v1.3 修訂（同日，使用者選擇「整段過程耗時」）

實測發現的缺陷：v1.2 的計時錨定 `reasoningFinishedAt`，而該欄位在**思考一停就寫入**（工具還沒跑），所以有工具的訊息會在完成瞬間**倒退**（數到 11.4s → 跳回 2.0s）。使用者選擇升級為「整段過程耗時」。

- `chat_message.dart`：**新增 Hive field 20 `processFinishedAt`**（過程終點）與 **field 21 `processStartedAt`**（過程起點），`chat_message.g.dart` 由 `build_runner` 重新產生（`writeByte(22)`）；`toJson`／`fromJson`／`copyWith` 同步（匯出／匯入沿用同一組）。
- `chat_service.dart`：`addMessage`／`updateMessage`／`updateMessageSilent` 加選擇性的 `processFinishedAt`。
- `stream_controller.dart`：`ReasoningData.processFinishedAt`／`processStartedAt`（從訊息還原，並擴大還原條件以涵蓋無思考的純工具訊息）；新增 `_groupIsLive`（鏡射 UI 的 live 推導）、`_stampProcessFinished`（在「無待處理工具／思考段且已有正文」時寫一次，**每輪至多一筆**，不隨每個 content chunk 寫）、`_clearProcessFinished`（新思考段／新工具輪開始時清掉舊值，避免第 2 輪凍結在第 1 輪的舊時間）、`_stampProcessStarted`（**首個過程事件**：第一個工具呼叫或第一個思考 token，以先到者為準，每則訊息至多寫一次；純工具輪會順帶建立 `ReasoningData` 與 `startAt`）。呼叫點：`_stampProcessFinished` 於 `finishReasoningOnContent`、`handleToolResultsChunk`、`finishReasoningAndPersist`（錯誤／取消／空答的補場）；`_stampProcessStarted` 於 `handleToolCallsChunk`、`handleReasoningChunk`。
- `chat_actions.dart`：4 個 `updateReasoningInDb` closure 與新的 tool-call／tool-result 補場 closure 串上新參數。
- `process_group_logic.dart`：新增純函式 `resolveProcessStartAt({processStartedAt, reasoningStartAt})` 與 `resolveProcessFinishedAt({live, processFinishedAt, reasoningFinishedAt})`——live 時回 null（外殼自行跳動），非 live 時回 `processFinishedAt ?? reasoningFinishedAt`；舊資料（無新欄位）兩端都退回 reasoning 值，即修訂前行為。
- UI：`ChatMessageWidget.reasoningProcessStartedAt`／`reasoningProcessFinishedAt`（由 `message_list_view` 從 `r.processStartedAt`／`r.processFinishedAt` 傳入）→ `ProcessGroupCard.startAt`／`finishedAt`。`ProcessGroupCard` 不變。
- 測試：`process_group_logic_test.dart` 新增 7 項（起點優先採首個過程事件、純工具輪有錨點、舊列退回 reasoning 起點、不回退性質、舊列退回思考終點等）；新增 `test/core/models/chat_message_process_finished_at_test.dart`（JSON round-trip／copyWith／舊列為 null，含無思考的純工具輪）。
- 已知限制：`build_runner` 對本專案其他檔案報 SEVERE（既有現象），但 `chat_message.g.dart` 已確實重新產生；`_stampProcessStarted` 為每則訊息至多一次持久化寫入，串流熱路徑無額外 I/O。
