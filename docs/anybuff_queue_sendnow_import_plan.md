# Anybuff Queue／Send now 導入評估與計畫（執行佇列 + 進行中訊息插隊）

> **版本**：v1.1（2026-11-10 審查修訂版）  
> **狀態**：**規格已定案，待實作**——已納入對抗式審查（20+ 程式接點驗證）與使用者裁示；本文件先鎖規格與分層，未動工。  
> **來源**：Anybuff（`C:\Users\w2bn1\GitHub\Anybuff`）的 **ADR-30 queue-first / Send now（mid-turn steering）** 體系：`desktop/src/renderer/src/utils/send-routing.ts`、`queue-routing.ts`、`packages/host-core/src/run/steering-mailbox.ts` 與 `start-run.ts` 的 drain hook、`composer-queue-first.test.tsx` 等五組測試。  
> **範圍**：OmniChat 原生重寫兩項能力——①**執行佇列（Queue）**：對話進行中提交的訊息不再阻塞，改排入該對話佇列、回合結束後依序自動送出（支援純文字與附件）；②**Send now（進行中插隊）**：把輸入框中的純文字即時注入**正在生成中的回合**（下個 round 邊界或結算時），並在使用者氣泡即時回顯。  
> **非範圍**：跨對話背景 dispatch（v1 僅 dispatch「目前檢視的對話」的佇列）、AI Team 進行中的 steering、語音路徑、對話樹分支地形（regeneration 不感知佇列）、佇列的持久化／備份（in-memory，同 Anybuff）。  
> **相關文件**：手冊 §3.14 §9（Answer Review——review 與續航的互動）、§3.9（輸入列）；Anybuff `docs/testing.md` 手動矩陣第 4 列（Send now／steering）。
>
> **v1.1 修訂摘要（對抗式審查 F1–F15＋使用者裁示）**：
> - **F1** approval／ask_user pending 的 run 是 clean stop（loading 已 false）；佇列新增 **paused checkpoint gate**，避免自動 dispatch 劫持核准／ask_user 回覆。
> - **F2** 不以通用 loading 事件盲觸發 dispatch；新增 **轉場暫停旗標＋microtask 再檢**，避免 regenerate／resume 空窗被插隊。
> - **F3** mailbox 結算擴及 **terminal／error／cancel／team-stop 四路**；錯誤後不得讓佇列永久死鎖。
> - **F4** 結算續航改走 **`_finishStreaming(keepLoading)`**；`onStreamFinished` 移到續航判定後。
> - **F5** mailbox owner 改為 **run token（assistantMessageId）**；遲到 deactivate 一律 no-op。
> - **F6** 新增 `isAiTeamRunActive`；修正「AI Team 不經 kernel」的說法（**aggregator 會經 kernel**，proposer 不會）。
> - **F7** 對話切換喚醒接線。
> - **F8** Enter→queue 的 guard 放在**編輯訊息分支之後**。
> - **F9（使用者裁示）** Queue 顯示條件放寬為 `loading && (hasText || hasAttachments)`；Send now 仍限純文字。
> - **F10** Stop 時「有 leftover **或**佇列非空」一律暫停。
> - **F11** echo 收回改為 DB 刪除＋`_messages` 找到才移除；崩潰殘留列入風險。
> - **F12–F14** 術語、l10n、估時校正。
> - **F15（追加）** echo 在 **drain 時移動到當前 assistant 訊息之前**（ordinal swap），修正 replay 順序與下一輪 consecutive-user。
> - **使用者裁示**：「+」選單不加排隊入口、不加 dot；dock 編輯只改文字；Ctrl/Cmd+Enter 尊重 IME composing。

---

## 0. 摘要（TL;DR）

### 0.1 導入決策表

| # | Anybuff 能力 | 判斷 | 說明 | 估時 |
|:--:|:---|:--:|:---|:--:|
| 1 | Queue-first composer（進行中一律排隊） | **導入** | OmniChat 目前「進行中＝送出被禁」；改為排隊＋回合結束自動 dispatch（文字與附件皆可） | 1–1.5 人日 |
| 2 | Send now（mid-turn steering）round 邊界注入 | **導入**（kernel 表面已存在） | 經既有 `AgentLoopHooks.onRoundStart` 把注入文字 append 進 working 訊息 | 2–3 人日 |
| 3 | Send now 結算續航（final-round／無工具 run 的殘留） | **導入**（結算路徑） | `_finishStreaming(keepLoading: true)`＋`_continueSteeringSegment`；loading 不落地 | 1.5 人日 |
| 4 | Steering leftovers → 收回回顯＋回排隊伍頭＋Stop 即暫停 | **導入** | 四路結算（terminal／error／cancel／team-stop）；Stop 時有殘留或佇列非空即 pause | 1.5 人日 |
| 5 | Queue dock（佇列面板） | **導入** | 輸入列上方可折疊 dock；操作＝**立即插入／編輯（僅文字）／刪除／移到最前**（逐項 Send now 於 2026-11-13 追加） | 1.5–2 人日 |
| 6 | Queue 項目逐項「send now」 | **已提前實作（2026-11-13）** | 逐項「立即插入」＝把該則純文字 steer 進目前回合（gate 同 composer Send now；附件／斜線／AI Team／無 run 時停用）；edit 後 gate 以最新文字重判 | — |
| 7 | 論壇級 dispatch（cwd/task 雙軌、跨 tab 目標路由、blocked-cwd 表） | **不導入** | OmniChat 無 tab 概念；佇列 per-conversation 即足夠 | — |
| 8 | 佇列持久化（prefs／DB） | **不導入**（同 Anybuff：in-memory） | 程式重啟即清空；另案議 | — |

**合計：約 8–10.5 人日**（權威數字＝§5 Phase 加總：Phase 0 1＋Phase 1 3.5–4.5＋Phase 2 1.5–2＋Phase 3 1.5–2＋Phase 4 0.5–1）。上表逐列為**功能面粗估**，含跨列共用的測試與接線工，不與 §5 逐項相加；總額已含 F1–F15 防護、echo 順序修正與實機矩陣。

### 0.2 最重要的一件事（架構核心約束）

`ChatActions._conversationStreams[conversationId]` **每對話只容納一條串流訂閱**，`_executeGeneration` 起跑前會先 `cancel()` 舊訂閱（`chat_actions.dart` L1683）——這代表 OmniChat **不可能**像「再發一則訊息」那樣靠平行 run 做插隊：那會直接殺掉正在生成的回合。因此：

- **Queue** 走「回合終點 → 依序 dispatch」的純序列路徑，零 kernel 介入；
- **Send now** 走「注入進行中 run」兩道既有表面：
  1. **Round 邊界注入**：`AgentLoopHooks.onRoundStart(stepIndex, working, tokensUsed)` 會在**每次 LLM 請求前**收到 working 訊息清單（**以參考傳入、可直接原地 append**，`agent_loop.dart` L264／L294-300）；hook 內排水箱文字即可讓模型在下一輪看到使用者輸入——工具迴圈越長、插入點越自然。**step 0 不 drain**（避免與初始 replay 重複；見 §3.5）。
  2. **結算續航**：模型最後一輪（無 tool calls）期間輸入的注入，kernel 之後不再有 round 邊界 → 由 **`_handleStreamFinish` 在 `_finishStreaming` 之前**檢查水箱：有殘留就 **`_finishStreaming(keepLoading: true)`**（`_setConversationLoading(false)` 在 L3123，不能讓它落地）、正常結算本段（內容落盤、journal 結束、sub 取消 L3027），再以既有「resume 同形」管線（模板：`resumeAfterAskUserAnswer`，L496-556）立即派下一段。下一段終點正常落管線 → loading=false → queue 才接手。**`onStreamFinished` 延後到續航判定後**，避免背景通知提早收工。

兩道機制合起來涵蓋所有時點：單輪 Q&A 的注入落在 (2)；多輪 agent run 的注入落在 (1)（剛好在下個 round 請求前一瞬生效）；落在 review 期間的注入由 terminal 後的 (2) 兜住。**dispatch 不在 `onLoadingChanged` 通用出口盲觸發**——回合終點（terminal／error／cancel／team-stop）與「切回該對話」才喚醒，並在 microtask 再檢一次（F2）。

### 0.3 使用者 UI 裁示（本計畫的最高約束）

> **顯示條件**：Queue＝`isLoading && (text.trim().isNotEmpty || 有附件)`；Send now＝`isLoading && text.trim().isNotEmpty`（**純文字限定**；有文字＋附件時 Send now 顯示但禁用，tooltip 說明附件不可插入；附件-only 時只有 Queue）。  
> **桌面**：對話進行中在 **stop 按鈕左邊**直接加按鈕。  
> **行動**：同樣在 stop 按鈕左邊加按鈕；因右側加寬而**被排擠**的左側輸入列按鈕，照既有機制**收進「+」選單**（`BottomToolsSheet`）。**不**在「+」選單加「排隊中」入口、**不**在「+」圖示加 dot（使用者裁示）。  
> **鍵盤**：進行中 Enter＝排入佇列、Ctrl/Cmd+Enter＝立即送出（gate 不符時退回佇列；**IME composing 時交還 IME，與現行 Enter 分支同守衛**）。  
> **Dock**：逐項操作＝「立即插入（steer 該則純文字）／編輯（僅文字）／刪除／移到最前」；編輯後 gate 以最新文字重判。

這與 Anybuff 不同（Anybuff 的兩鈕在進行中**常駐**、空草稿 disabled）——以使用者裁示為準，Anybuff 只供腳位與語義參考。

---

## 1. Anybuff 事實調查（行為規格來源）

| # | 行為 | 來源（檔案:行） | 對應測試 |
|:--:|:---|:---|:---|
| 1 | **Queue-first contract**：進行中按 Enter／主按鈕＝排隊；僅明確意圖（Ctrl/Cmd+Enter 或 Send now 鈕）才 steering；排隊的訊息仍於本回合**結束後**依 FIFO dispatch | `Composer.tsx:743`（Enter 路由）、`Composer.tsx:842`（進行中主按鈕即 queue 鈕）、`App.tsx:2457-2540`（send() 的 running 分支） | `composer-queue-first.test.tsx`（空 run 時無 send-now 鈕；steerable 時兩鈕並列；無 run 時 idle send 鈕原樣） |
| 2 | **Steering gate（純文字限定）**：帶附件、以 `/` 或 `!` 開頭、prebuilt prompt、bash context、interview wrap 一律回退排隊——不能靜默丟上下文 | `send-routing.ts:38-49`（`canSteerRunningTurn`）、`:69-79`（`canSteerQueuedMessage`：`finalPrompt !== text` 即不可插隊） | `send-routing.test.ts:26-105` |
| 3 | **Push-time echo**：steering 送出當下就先把 user 氣泡追加進 transcript（`steeringId` 記推送 id），模型是否真的收到由 drain 決定 | `App.tsx:2485-2504`、`session-store.ts:337+`（echo/retract） | `steering-channel.test.ts:108+` |
| 4 | **Round/step 邊界 drain**：agent loop 每個步界呼叫 drain，把 mbox 文字以 user prompt 注入**同一個 run**，turn 繼續；`activateSteering(ownerId)` 在 run 起跑時開箱、owner guard 擋遲到的舊 run | `start-run.ts:1022-1024, 1242-1251`、`steering-mailbox.ts` 全檔 | `steering-mailbox.test.ts`（claim/accept/owner guard） |
| 5 | **Leftover 收回**：run 結算但 entry 未被 drain → 收回 echo 氣泡＋文字**前插**回佇列（block-prepend 保持 FIFO）；**Stop 造成者順帶暫停佇列**（防「剛按停止又自動重啟」） | `App.tsx:2194-2225`（`handleSteeredLeftovers`）、`send-routing.ts:95-103`（`leftoverRequeueItems`） | `send-routing.test.ts:109+` |
| 6 | **Queue 項目結構**：enqueue 當下即 **bake finalPrompt**（附件/`@file`/快速指令在 push 時烘焙）＋附件快照，dispatch 時用 snapshot 重烘焙；同時帶 taskId/tabId/cwd 目標路由與 model/effort/mode 快照 | `App.tsx:2431-2540`、`queue-routing.ts`（targeting、`firstDispatchableQueueIndex`、`moveQueueItemWithinTarget`、`promoteQueueItemWithinTarget`） | `message-queue-panel.test.tsx` |
| 7 | **Drain effect**：effect 輪詢佇列，取第一個「目標對得上、未暫停、未被 blocked、其對話無 run 在跑」的項目 dispatch；dispatch 失敗放回隊頭＋1.5s 冷卻 | `App.tsx:2883-2934`、`queue-routing.ts:89-100` | — |
| 8 | **Queue panel**：`N queued` 標題＋折疊；paused 時出「⏸ paused — resume」列；每項 edit（re-bake）/刪除/上移下移/promote to next/send now（僅 steer-able 時亮） | `MessageQueuePanel.tsx` 全檔 | `message-queue-panel.test.tsx:29-53` |
| 9 | **排隊後佇列與附件歸屬**：send 成功即清 composer 與附件列（已入佇列項目自帶快照） | `App.tsx:2536-2547` | — |

手動驗收矩陣見 Anybuff `docs/testing.md`（矩陣 #4＝檔案 L195）：Send now 只該被**同一 task** 的 run 收到。Anybuff 的兩鈕在進行中常駐、空草稿 disabled；本專案依使用者裁示改為「有 queueable input 才顯示」，只借用其語義與腳位。

---

## 2. OmniChat 現況與差異映射

| 領域 | Anybuff | OmniChat 現況 | 映射決策 |
|:---|:---|:---|:---|
| 回合結構 | agent run（SDK 管理 transcript，多 user prompt 可塞同一 run） | 訊息樹：`user → assistant(+review) → user → …`；串流狀態 per assistant message id | Steering 保持「各段各自 user＋assistant」樹形；插入的 user 訊息是真實 `ChatMessage`；**drain 時把 echo 移到當前 assistant 之前**（F15） |
| 進行中送出 | Enter＝排隊 | **送出被禁**（`_CompactSendButton` loading 即 stop；但桌面 **Enter 仍會直呼 `_handleSend` bypass**——L368/L586 無 loading 守衛） | Enter／主送出在進行中改為排隊；guard 放在 `HomePageController.sendMessage` 的**編輯分支之後**（F8） |
| Kernel 表面 | `drainSteeringMessages` 引擎 hook（每步界） | `AgentLoopHooks.onRoundStart` 已存在且 working 清單以**引用**傳入（`agent_loop.dart` L264／L294-300），P1 接線點 `_buildPhase1Hooks`（`chat_actions.dart` L1450-1508） | **零 kernel 改動**：hook 內原地 append `{role:'user', content}`；**step 0 不 drain** |
| 結算點 | run settle（start-run.ts）＋steeredLeftovers | `_handleStreamDone` → `_handleStreamFinish` → `_finishStreaming`（loading=false 在 L3123）→ journal → `onStreamFinished` | 續航需 **`_finishStreaming(keepLoading: true)`**；在 journal 結束與 sub 取消（L3027）後才 `_continueSteeringSegment`（F4） |
| Approval／ask_user pending | blocked 佇列項 | run 以 `stoppedByHook` **clean stop**、loading=false、checkpoint 留 `paused`（`agent_run_journal.dart` L127-136／L249-250） | dispatch 前讀 `checkpointStore.load(cid)`；`phase == paused || hasPendingUserAction` 一律不 dispatch（F1） |
| 取消 | abort（run 由宿主任務管理） | `cancelStreaming`（`chat_actions.dart` L1238-1364）：L1323／L1355 設 loading=false＋checkpoint 清除 | Stop＝殘留收回＋佇列暫停；**mailbox 結算必須在 loading=false 之前**（F3） |
| 佇列視圖 | 輸入列上方 dock | 無（新增 `message_queue_dock.dart`，仿 `TodoPlanLiveDock` 慣例） | 新增；編輯僅文字；逐項立即插入（2026-11-13） |
| 輸入列 | Composer 主動區＝queue 鈕常駐 | `chat_input_bar.dart::_buildResponsiveBottomRow`（L941-1631）：左＝14 鍵 catalog 自應式布局（overflow→桌面左側 `+` popover／行動 `+`(Plus) 選單），右＝[+（僅行動）][send/stop]；`rightSideWidth` 預算（L956-965）逐鍵寬度計價 | Queue 掛在右側 send/stop 左邊（可見條件含附件-only）；Send now 純文字；行動側把按鈕寬度加進 `rightSideWidth`，被排擠左鍵由既有 overflow 進 `+` 選單；**不新增**選單入口／dot |
| 插入 user 訊息常式 | `beginUserTurn` | `messageGenerationService.createUserMessage`（`chat_actions.dart` L322 呼叫例）＋ `chatService.appendMessage`（`max(ordinal)+1`，`chat_repository.dart` L302-309） | Echo 走同一常式；drain 時以新 `moveMessageBefore` 交換 ordinal，落回 assistant 之前（F15） |
| 續派既有模板 | runPrompt | **`resumeAfterAskUserAnswer`**（L416-557）：新 assistant placeholder＋正常 replay/grading/串流接線；loading true 在 L507、`_executeGeneration` 在 L555 | 結算續航用同形管線；續航段 `generateTitleOnFinish: false` |
| dispatch 觸發 | drain effect 輪詢 | 無（loading 狀態由 `_setConversationLoading` 分發） | **不以通用 loading 事件觸發**；由回合終點 `notifyTurnEnded(cid)`＋切回對話喚醒（F2／F7） |

---

## 3. OmniChat 行為規格

### 3.1 定義

- **執行佇列件（`QueuedMessage`）**：`{ id, conversationId, input: ChatInputData, createdAt }`。`ChatInputData`（text/imagePaths/documents）在 **enqueue 當下快照**；dispatch 時重走正常 `sendMessage` 管線（烘焙＝`prepareApiMessagesWithInjections`，原樣）。模型／助理／推理檔位 **以 dispatch 當下為準**（Anybuff 有快照，v1 簡化——明示差異，見 §7）。
- **Steering 水箱（`SteeringMailbox`）**：per `(conversationId)` 一個水箱，**owner token＝當前段的 `assistantMessageId`**（不是 conversationId；F5）。`activate(token)`／`push(text) → SteeringEntry{pushId, text, echoMessageId}`（僅活躍 owner 受理）／`drain(token)`（一次取空）／`hasPending`／`deactivate(token)`（token 不符即 no-op，擋遲到舊 run）／`abandon() → List<SteeringEntry>`（結算路徑無條件清空，**回傳被清空的 entries** 供收回 echo／前插佇列）。續航時 `deactivate(oldTok)` 後立即 `activate(newTok)`。
- **Steering echo**：`push` 時以 `createUserMessage` 落盤 user 氣泡（**一則** echo；新的 push 併 `\n\n` 續文，避免 consecutive-user 400），並加入 in-memory pending set（不新增 DB 欄位）。**初始位置在當前 assistant 訊息之後**（時間軸立即出現）；**在 drain（round 邊界）時移到該 assistant 之前**（`moveMessageBefore`，F15），使 replay 順序為「user echo → assistant」；B 路徑（未 drain）保持在其後，下一段 assistant 自然接在 echo 之後。Stop／error 收回：`chatService.deleteMessage`（L917）＋`_messages` 找到才移除；崩潰時殘留的 pending echo 視為普通 user 訊息（R15）。
- **可排隊 gate（`canQueueChatInput`）**：`loading && (text.trim().isNotEmpty || imagePaths.isNotEmpty || documents.isNotEmpty)`。
- **可插隊 gate（`canSteerChatInput`）**：`loading && text.trim().isNotEmpty && imagePaths.isEmpty && documents.isEmpty && !text.trimStart().startsWith('/')`。附件與 `/skill` 等 token 必須走排隊；gate 不通時 Send now 鈕**禁用＋tooltip 說明原因**，Queue 鈕照常可用。本專案無 `@file` mention 系統，快速片語為純文字可插隊。
- **Dispatch 政策（純函式）**：`canDispatchTurn({inFlight, mailboxActive, queuePaused, internalTransition, checkpointPaused, isCurrentConversation, cooldownActive, hasItems})`；任何一項不滿足即不派送（§3.4）。

### 3.2 UI 條件（使用者裁示落地）

| 狀態 | 按鈕顯示 |
|:---|:---|
| `isLoading == false`（閒置） | **不顯示**（主送出鈕維持現行 send 行為） |
| `isLoading == true` 且輸入框有**文字** | **兩鈕顯示**：`[Queue][Send now]`。Send now 僅在「無附件且非 `/` 開頭」可用；否則禁用＋tooltip |
| `isLoading == true` 且**僅附件**（無文字） | **只顯示 Queue**（`[Queue]`）；Send now 不出現（純文字限定） |
| `isLoading == true` 且輸入框全空 | **不顯示** |
| 送出成功（Queue／Send now／主送出）或使用者清空 | 立即消失（`_onTextChanged` 已觸發重建） |

進行中主送出鈕（stop）**不變**；按鈕出現不影響 stop。Queue 按鈕會把完整 `ChatInputData`（含附件）入列。

### 3.3 平台細節

- **桌面（tablet 層級寬度）**：右側 Row 變為 `[Queue][Send now][stop]`，附件-only 時 `[Queue][stop]`（L1582-1625 分支）；按鈕為 `_CompactIconButton`（24 視覺、32 步進），tooltip 即 l10n。不進 `ChatInputButtonCatalog`（左鍵目錄的自訂排序／隱藏機制與「僅情境出現」語義不合——**故意**固定，見 §4.4）。
- **桌面鍵盤**：`_handleKeyEvent`（L556 起；Enter 分支 L572-589）——`Enter`（無修飾）＝`_handleSend()`，進行中時**路由改為 enqueue**；新增 `Ctrl/Cmd+Enter`＝**Send now**（gate 不符時退回 enqueue；閒置時 Ctrl/Cmd+Enter＝普通送出）。**IME composing 時一律交還 IME**（與 L575-578 現行守衛相同，不攔截 Ctrl/Cmd+Enter）。iOS tablet 的硬鍵盤與 `TextInputAction.send`（L2212-2216）同 Enter 語義。
- **行動**：右側 Row 變為 `[+][Queue][Send now][stop]`（附件-only 時 `[+][Queue][stop]`；dictation 分支 L1553-1580 不動）。`_buildResponsiveBottomRow` 的 `rightSideWidth` 依可見按鈕數加 `normalButtonW * n + spacing * n`（L956-965）→ 左側可用寬度縮減 → 被排擠的左鍵由既有 overflow 流入 `menuItems` → `onMore` → `BottomToolsSheet`（`home_page.dart` L1486-1509）。**不新增**機制，量測點補一個 widget test。
- **按鈕進出場**：`AnimatedSwitcher`（仿 `moreOpen` 旋轉淡入的 200ms 慣例），防布局跳動；`loading` 翻轉與文字／附件增刪都會自然觸發重建。

### 3.4 佇列 dispatch 條件（嚴格序）

**觸發點**（F2／F7）：`_handleStreamFinish` 正常結算、`_handleStreamDone`（idempotent）、`_handleStreamError`、`cancelStreaming`、`_handleAiTeamStopped`，以及 `switchConversationAnimated` 完成後。**不**在 `_setConversationLoading` 的通用出口盲觸發。

```
notifyTurnEnded(conversationId):
  scheduleMicrotask:
    if loading(conversationId) || internalTransition(conversationId): return
    await dispatchIfIdle(conversationId)

dispatchIfIdle(conversationId):
  if dispatchInFlight(conversationId): return            // single-flight
  if mailbox.isActive(conversationId): return            // 續航／run 進行中
  if queuePaused.has(conversationId): return             // Stop 後暫停
  if internalTransition(conversationId): return          // regenerate／resume／approval 空窗（F2）
  cp = await checkpointStore.load(conversationId)
  if cp != null && (cp.phase == agentRunPhasePaused || cp.hasPendingUserAction):
    return                                               // approval／ask_user 未決（F1）
  if conversationId != currentConversation?.id: return   // v1 不背景 dispatch
  if cooldownActive(conversationId): return              // 失敗冷卻
  items = queue[conversationId]
  if items.isEmpty: return
  head = items.removeAt(0)
  dispatchInFlight.add(conversationId)
  ok = false
  try:
    ok = await viewModel.sendMessage(head.input)         // 完整正常送出；繞過 UI guard
    if (ok):
      resetFailure(conversationId, head)
    else:
      queue[conversationId].insert(0, head)              // 失敗回隊頭
      markFailure(conversationId, head)
      cooldown(conversationId, 1.5s)
      if (head 連續失敗 2 次): queuePaused.add(conversationId)  // 防無限重試
  catch:
    queue[conversationId].insert(0, head)
    markFailure(conversationId, head)
    cooldown(conversationId, 1.5s)
  finally:
    dispatchInFlight.remove(conversationId)
  if (!ok && !queuePaused.has(conversationId)):
    scheduleRetry(conversationId, 1.5s)                  // 冷卻到期再走一次 notifyTurnEnded
  // 成功時不在此續送：剛起跑的回合 terminal 會再 notifyTurnEnded
```

派出的項目走**完整正常送出**（錯誤 snackbar、title 生成、review 照常）；dispatch 失敗時項目**放回隊頭**（同 Anybuff fallback）＋1.5s 冷卻，冷卻到期由一次性 timer 重新喚醒 `notifyTurnEnded`；同一項連續失敗 2 次即暫停佇列（dock 顯示可 Resume）。成功 dispatch 後**不在同一輪迴圈續送**——該回合的 terminal 會再次觸發 `notifyTurnEnded`，由 single-flight 保證序列。

### 3.5 Steering 注入語義

- **(A) Round 邊界**：`_buildPhase1Hooks.onRoundStart` 在既有 journal + compaction 之後：
  ```
  if (stepIndex > 0 && !isAiTeamRunActive(conversationId)):
    entries = mailbox.drain(ownerToken)        // 一次取空；owner 不符即空
    if entries.isNotEmpty:
      for e in entries:
        chatService.moveMessageBefore(
          conversationId: conversationId,
          messageId: e.echoMessageId,
          beforeMessageId: state.messageId,
        )                                             // F15：echo 移到 assistant 前
      messages.add({'role':'user','content': mergedText})                 // working 以引用原地 append（單則）
  return true
  ```
  **step 0 不 drain**：push 若發生在 `prepareApiMessagesWithInjections` 之前，echo 已由初始 replay 涵蓋；若之後，留待下一輪或結算 (B)，保證不重複。注入點在 compaction **之後**，避免 midrun compactor 與注入互相踩踏（§7 R4）。AI Team run（proposer／aggregator）一律不 drain（F6）。
- **push 當下**：echo user 訊息落盤（初始在當前 assistant 之後）＋`onMessagesChanged`（時間軸立即出現，模型晚一拍看到——同 Anybuff push-time echo）。drain 時氣泡會移到 assistant 上方（一次性 reflow，接受；R17）。
- **(B) 結算續航**：`_handleStreamFinish` 流程：
  ```
  hasLeftover = mailbox.hasPending(conversationId)
  _finishStreaming(state, keepLoading: hasLeftover)   // 正常落盤；loading 不落地
  _finishRunJournal(state)
  ... reasoning 收尾、sub cancel（L3027）...
  if (hasLeftover):
    mailbox.drain(ownerToken)                          // 只消耗；不 append——DB replay 已含 echo
    _continueSteeringSegment(state)                    // 新 placeholder → activate(newToken) → prepare(_messages) → _executeGeneration
  else:
    mailbox.deactivate(ownerToken)
    notifyTurnEnded(conversationId)
  ```
  `_handleStreamDone` 為第二 terminal 路徑：先做同樣的 mailbox 判定，靠 `state.finishHandled` 冪等（`_finishStreaming` 早退時不會再設 loading）。`_continueSteeringSegment` 同形 `resumeAfterAskUserAnswer`（L496-556）：`createAssistantPlaceholder` → `markStreamingStarted` → `_messages.add` → **不再** `_setConversationLoading(true)`（全程維持 true）→ `prepareApiMessagesWithInjections` → `buildGenerationContext(generateTitleOnFinish: false)` → `_executeGeneration`。`onStreamFinished` 在 `if/else` **之後**（`_handleStreamFinish` 返回前）才呼叫，避免背景通知在續航判定前提早收工；續航段起跑後同樣在該段終點再呼叫一次。
- **四路結算（F3）**：
  - **terminal 成功**：上述 (B)；若無殘留則 `deactivate`＋`notifyTurnEnded`。
  - **error**（`_handleStreamError`，L3279 之前）：`mailbox.abandon()` → 刪 echo → 文字前插佇列 → loading=false → `notifyTurnEnded`；**不 pause**（靠 1.5s 冷卻與二次失敗暫停）。
  - **cancel／Stop**（`cancelStreaming`，L1323／L1355 之前）：`abandon()` → 刪 echo → 前插佇列；**若 leftovers 非空或佇列非空 → `queuePaused.add`**（F10）。dock 顯示「⏸ 已暫停——停止後不自動續送」＋「繼續」鈕；Resume＝清除 pause 並立即 dispatch 頭項；**下一次正常送出**亦自動清 pause。
  - **team-stop**（`_handleAiTeamStopped`，L2267 之前）：`abandon()`（steering 對 team 停用，防禦性）→ loading=false → `notifyTurnEnded`。
- **絕不允許**：loading 先落地才結算 mailbox（會讓 `isActive` 擋住新一輪 dispatch，或讓 dispatch 與殘留 echo 交錯）。

### 3.6 情境矩陣

| 情境 | 規格 |
|:---|:---|
| 閒置輸入 Enter | 正常送出（現行），按鈕不存在 |
| 進行中輸入純文字 → Enter／Queue 鈕 | 快照 enqueue、清 composer；dock 計數＋1 |
| 進行中輸入文字＋附件 | 兩鈕顯示；Queue 入列（含附件）；Send now 禁用（附件 tooltip） |
| 進行中僅附件（無文字） | 只顯示 Queue；入列後回合結束自動送出（含附件） |
| 進行中 → Send now 鈕／Ctrl/Cmd+Enter | gate 通過：push echo＋清 composer；不符：退回 enqueue（`/` 開頭則進佇列） |
| 工具迴圈中 push | 下一個 round 請求即見輸入（宛如演出中場插話指揮）；drain 時 echo 移到 assistant 前 |
| 單輪回答期間 push | 結算續航（B）——本段正常結束＋新段立即起；loading 不閃滅 |
| 進行中 AI Team（proposer／aggregator） | Send now **禁用**（`composerSendNowTeamHint`）；Queue 可用（聚合終點 loading=false 後 dispatch） |
| approval／ask_user pending | run 已 clean stop（loading=false）→ 兩鈕不顯示；佇列**不自動 dispatch**（paused checkpoint gate）；使用者解卡、resume run 結束後才續送（F1） |
| Review 期間 push | (B) 在 terminal 後檢查——溫和加入下一段 |
| 按停止（有 echo 或佇列） | leftover 收回＋回排隊頭＋**佇列暫停**；dock 提示「繼續」 |
| 按停止（只有佇列、無 echo） | 一樣暫停（F10），不自動重啟 |
| 對話切換 | 佇列跟對話走；切走不清；非檢視對話不 dispatch；**切回該對話即喚醒 dispatch**（F7） |
| 對話刪除／清空全部 | 清佇列＋mbox；dock 隨對話消失 |
| regenerate／清空對話內容 | `cancelStreaming` 期間 `internalTransition` 抑制 dispatch；佇列照暫停（見上） |
| 多則 push（drain 前累積） | 併入同一則 echo（`\n\n`）；drain 一次全倒 |
| Queue 項目 dispatch 時正被切走 | v1 不 dispatch（掛住）；回該對話畫面即續 drain |
| 佇列頭項 dispatch 失敗 | 回隊頭＋1.5s 冷卻；連續 2 次失敗→暫停並提示 |
| 佇列內有多則、第一則送出成功 | 回合結束 `notifyTurnEnded` 續送下一則 |

---

## 4. 模組與檔案設計

### 4.1 新增（純 Dart、零 Flutter import，仿 `process_group_logic.dart` 契約）

| 檔案 | 內容 | 測試 |
|:---|:---|:---|
| `lib/core/services/chat/turn_queue/steering_mailbox.dart` | `SteeringEntry{pushId,text,echoMessageId}`、`activate/deactivate/push/drain/hasPending/abandon/listen`、**owner token guard**（遲到 deactivate no-op） | `test/core/services/chat/steering_mailbox_test.dart`（owner token／一次 drain 清空／遲到 deactivate 不傷新 owner／`\n\n` 合併） |
| `lib/core/services/chat/turn_queue/send_gate.dart` | `canQueueChatInput({loading,text,imageCount,docCount})`、`canSteerChatInput({loading,text,imageCount,docCount})`、`LeftoverReorder.prepend(items,leftovers)`（block-prepend 保 FIFO） | `test/core/services/chat/send_gate_test.dart`（附件-only 可 queue／附件不可 steer／`/` 開頭／空白；leftover 前插順序） |
| `lib/core/services/chat/turn_queue/dispatch_gate.dart` | `canDispatchTurn({inFlight,mailboxActive,queuePaused,internalTransition,checkpointPaused,isCurrentConversation,cooldownActive,hasItems})` 純函式 | `test/core/services/chat/dispatch_gate_test.dart`（pending／paused／inFlight／非當前／transition／冷卻） |
| `lib/core/services/chat/turn_queue/turn_queue.dart` | `QueuedMessage`、`TurnQueueStore`（per-conversation FIFO、promote/delete/move、single-flight、queuePaused set、cooldown map、連續失敗計數，全純邏輯） | `test/core/services/chat/turn_queue_test.dart` |

> 分層已驗證：`ChatInputData` 位於 `lib/core/models/chat_input_data.dart`（純 Dart、無 Flutter import），`QueuedMessage` 直接持有它不破「core 不依賴 features」；`TurnQueueStore` 亦不引用 `ChatMessage`／`ChatService`，echo 落盤留在 `ChatActions` 接線層。

### 4.2 修改（接線）

| 檔案 | 動作 |
|:---|:---|
| `lib/features/home/controllers/chat_actions.dart` | ① 持有 `SteeringMailbox`/`TurnQueueStore` 或經 HomeViewModel 注入；② `_executeGeneration` 起跑時 `mailbox.activate(state.messageId)`（team run 除外）；③ `_buildPhase1Hooks.onRoundStart` 於 compaction 後、**stepIndex > 0** drain＋`moveMessageBefore`＋working append（§3.5 A）；④ `_finishStreaming({bool keepLoading=false})`（L3042 簽名擴充，L3123 條件化）；⑤ `_handleStreamFinish` 續航分支（§3.5 B，抽 `_continueSteeringSegment`）；⑥ 四路結算 `_settleTurnMailbox(retract: bool)`；⑦ `cancelStreaming` 在 L1323／L1355 前結算＋pause；⑧ `_handleStreamError`、`_handleAiTeamStopped` 結算；⑨ `isAiTeamRunActive(cid)` 公開 getter（team run 全程 true）；⑩ dispatch 觸發 `notifyTurnEnded`、pending gate、cooldown；⑪ `onStreamFinished` 移到續航判定後 |
| `lib/core/services/chat/chat_service.dart` | 新增 `moveMessageBefore({conversationId, messageId, beforeMessageId})`（drain 時 order swap） |
| `lib/core/services/chat/storage/chat_storage.dart` | 介面新增 `moveMessageBefore`（append-only 之外的唯一順序操作） |
| `lib/core/services/chat/storage/chat_repository.dart` | SQLite 實作：transaction 內以暫存 ordinal 交換（ordinal 為 int，見 L302-309）；不改 schema |
| `lib/core/services/chat/storage/hive_chat_storage.dart` | Hive 實作：list 內移動物件位置（legacy 對等） |
| `lib/features/home/controllers/home_view_model.dart` | 暴露 `enqueueMessage(input)`、`steerNow(text)`（內部 push echo）、`queueItemsFor(cid)`、`clearQueueItem/promote/resumeQueue`、`queuePausedFor`、`isAiTeamRunActive(cid)` 等薄包裝；`sendMessage` 仍為 dispatch 的正式入口（`ChatActions` 是唯一管線主人） |
| `lib/features/home/controllers/home_page_controller.dart` | ① `sendMessage` 在**編輯分支之後**加「進行中→enqueue」路由（F8）；② `_wireViewModelCallbacks` 接 queue 狀態→`notifyListeners`；③ `switchConversationAnimated` 完成後喚醒 dispatch（F7）；④ 對話刪除／clear-all hook 清佇列 |
| `lib/features/home/pages/home_page.dart` | ① `_buildChatInputBar` 新回呼（`onQueue`、`onSendNow`、`sendNowDisabledReason` 等狀態參）；② `TodoPlanLiveDock` 下方掛 `MessageQueueDock(visible: queue 非空 && 屬當前對話)`（兩處平台布局 L751／L863 同構） |
| `lib/features/home/widgets/chat_input_bar.dart` | ① 新參數 `onQueue`/`onSendNow`/`sendNowEnabled`/`sendNowDisabledReason`（枚舉 none/attachments/command/team）；② 右側插入按鈕（Queue 可見＝`loading && (hasText || hasImages || hasDocs)`；Send now 可見＝`loading && hasText`）；③ `rightSideWidth` 依可見數計價；④ Enter→queue、Ctrl/Cmd+Enter→steer（**IME composing 守衛**）；⑤ `AnimatedSwitcher` 包裹 |
| `lib/features/home/widgets/chat_input_section.dart` | 透傳回呼＋組合可見條件（`isLoading` 已有，`hasImages`/`hasDocs` 由 `ChatInputBar` 內部持有） |
| `lib/features/home/widgets/message_queue_dock.dart`（新） | 折疊 dock：`N 則排隊中 · 對話閒置時自動送出`；paused 時警告列＋「繼續」；項目列（文字預覽＋**編輯（僅文字）**／移到最前／刪除；v1 無逐項 send now）仿 `TodoPlanLiveDock`（`todo_plan_sheet.dart` L586）樣式 |
| `lib/l10n/app_*.arb` ×4 | §4.3 鍵值（見下） |

### 4.3 l10n 鍵（×4 語系：en／zh／zh_Hans／zh_Hant）

```
composerQueueTooltip            排入佇列——此回合結束後自動送出（含附件）
composerSendNowTooltip          立即送出——插入進行中的回合（僅純文字）
composerSendNowAttachmentsHint  附件訊息無法插入進行中的回合，僅能排入佇列
composerSendNowCommandHint      以 / 開頭的指令需排入佇列，無法插入回合
composerKeyboardHint            進行中：Enter＝排入佇列、Ctrl/Cmd+Enter＝立即送出（IME 輸入中不攔截）
composerSendNowTeamHint         多模型協作（AI Team）進行中不支援立即送出，可先排入佇列
queueDockTitle(n)               {n} 則排隊中
queueDockHint                   對話閒置後依序自動送出
queueDockPausedHint             已暫停——停止後不自動續送，按「繼續」或另行送出解除
queueDockResume                 繼續
queueDockEdit                   編輯文字
queueDockRemove                 移除
queueDockPromote                移到最前
queueDockUp / queueDockDown     上移／下移
queueDockSendFailed             佇列訊息送出失敗，已放回隊首
```

**不新增**任何「+」選單佇列入口或 dot 相關鍵（使用者裁示）。`queueDockTitle(n)` 需在 arb 補 placeholder metadata；編輯對話框沿用既有通用「儲存／取消」鍵。

### 4.4 不動的東西

- `agent_loop.dart` kernel（零策略契約不破——drain 走 hook）。
- `ChatInputButtonCatalog`／排序／隱藏設定（按鈕為情境 pinned，非目錄鍵）。
- SQLite schema／備份格式（`moveMessageBefore` 只調 ordinal，不改 schema）。
- dictation Row（L1553-1580）形態照舊。
- 修飾鍵語義：Shift+Enter 新行；其他修飾不猜；IME composing 一律交還 IME。

---

## 5. 實作 Phase 與工作量

```text
Phase 0  純邏輯四件套 + 測試                    1 人日
          send_gate / steering_mailbox / dispatch_gate / turn_queue（failing-first）

Phase 1  資料面 / controller 接線              3.5–4.5 人日
         1a queue 端點：enqueue、turn-end dispatch、single-flight、失敗回隊頭＋冷卻＋二次失敗 pause
         1b steering push／echo 落盤（createUserMessage 重用）
         1c onRoundStart drain（step>0）＋moveMessageBefore＋working append（含 compaction 先後序）
         1d 結算續航 _continueSteeringSegment（_finishStreaming keepLoading＋loading 不落地）
         1e 四路 mailbox 結算（terminal/error/cancel/team-stop）＋Stop pause 語義
         1f pending checkpoint gate（approval／ask_user）
         1g 對話切換喚醒＋轉場抑制旗標（regenerate/resume/approval）
         1h chat_service/storage 的 moveMessageBefore（SQLite 交換＋Hive 等價）
         1i 整合測試（Fake stream 驅動 drain/續航/leftover/pending/競態）
         ——Phase 0+1 完成即功能可用；Phase 2 前以 controller 直呼驗證

Phase 2  輸入列 UI（顯示／鍵盤／+ 選單）        1.5–2 人日
         2a 兩鈕（Queue 含附件-only；Send now 純文字；rightSideWidth＋AnimatedSwitcher）
         2b Enter／Ctrl+Enter／IME 守衛／iOS TextInputAction 路由
         2c home_page 回呼與 HomePageController 路由（編輯分支後 guard）
         2d widget tests（顯示條件／禁用 tooltip／行動 + 選單承載被排擠鍵）

Phase 3  Queue dock UI                        1.5–2 人日
         3a message_queue_dock（折疊／paused 列／編輯僅文字／移到最前／刪除）
         3b dock 進出場接上兩平台布局；dock tests

Phase 4  驗收矩陣 + 收尾                      0.5–1 人日
         4a 資料面整合測試（pending／error／switch／regen 競態）
         4b 實機矩陣（§6.2）
         4c 手冊 §3.25＋§4 決策＋§5 陷阱記錄
```

**合計 8–10.5 人日**。建議切成兩個 PR：`PR#1 = Phase 0+1`（純資料面＋controller＋storage），`PR#2 = Phase 2+3`（UI），Phase 4 併 PR#2。

---

## 6. 測試計畫

### 6.1 自動化（Anybuff 五組測試的同構映射＋v1.1 新增）

| Anybuff 測試 | OmniChat 對應 |
|:---|:---|
| `send-routing.test.ts`（canSteer/canSteerQueued/leftoverRequeue） | `send_gate_test.dart`（canQueue／canSteer／leftover 前插） |
| `steering-mailbox.test.ts` | `steering_mailbox_test.dart`（owner token／遲到 deactivate／合併） |
| `composer-queue-first.test.tsx`（鈕出現／禁用／idle 原樣） | `chat_input_bar_queue_buttons_test.dart`（**閒置時兩鍵不存在**；文字→兩鈕；附件-only→只有 Queue；文字＋附件→Send now 禁用；清空即消失；IME 不攔截） |
| `message-queue-panel.test.tsx` | `message_queue_dock_test.dart`（計數／paused 列／編輯僅文字／無逐項 send now） |
| `steering-channel.test.ts`（echo/retract） | `chat_actions_steering_test.dart`（push→echo 落盤；drain→echo 移到 assistant 前；Stop→收回＋回隊頭＋pause；error→收回＋回隊頭） |
| —（Anybuff 無結算續航測試） | 新增：final-round push → 首段正常結算＋第二段生成／**loading 全程 true**（keepLoading） |
| —（v1.1 審查新增） | `dispatch_gate_test.dart`（pending／paused／inFlight／transition／非當前／冷卻）；`chat_repository_reorder_test.dart`（ordinal 交換後 replay 順序：user echo → assistant）；整合案：approval pending 時佇列不送、resolve 後續送；regenerate 空窗不插隊；error 後 mailbox 不再 active；切換對話喚醒 |

單元目標：**驅動 `runAgentLoop` 的 round 邊界 drain 生效**（`test/features/home/services/` 慣例，仿 `agent_orchestrator_review_test.dart` 的本機 capture 接線）。

### 6.2 手動驗收矩陣（Anybuff `docs/testing.md` 風格）

| # | 情境 | 期望 |
|:--:|:---|:---|
| 1 | 閒置對話輸入文字 | 兩鈕不出現；Enter 正常送出 |
| 2 | 串流中輸入文字 | 兩鈕即現於 stop 左；左列被排擠鍵收進 `+`（行動） |
| 3 | 串流中只放附件 | 只出現 Queue；入列後回合結束自動送出附件 |
| 4 | 串流中按 Queue | composer 清空、dock 計數＋1、回合結束後該訊息成**新一輪**開始（含 title/usage 正常） |
| 5 | 深度工具迴圈（write_todos→file 連走）中 Send now | 該輪請求前模型已見插入文字並回應；回合不斷；echo 氣泡移至回答上方 |
| 6 | 單輪回答中 Send now | 回答照常結束（review 照跑）→ 下段立刻起、loading 不閃滅 |
| 7 | 串流中按停止（有 echo＋佇列） | echo 收回、文字回隊頭、dock 顯示已暫停；「繼續」或重新送出解鎖 |
| 8 | 串流中按停止（只有佇列） | 同樣暫停，不自動重啟 |
| 9 | 佇列多則、頭項 dispatch 失敗（斷網） | snackbar＋放回隊首＋冷卻；連續兩次失敗後暫停 |
| 10 | AI Team 進行中 | Send now 禁用（`composerSendNowTeamHint`），Queue 可用（聚合結束後 dispatch） |
| 11 | approval／ask_user pending + 佇列有料 | 不自動 dispatch；解卡 resume 完成後才續送 |
| 12 | regenerate／clear 對話時佇列有料 | regenerate 期間不被插隊；佇列維持暫停狀態 |
| 13 | 串流中切走再切回 | 切走不 dispatch；切回即續 drain |
| 14 | 佇列 3 則連續送出 | 逐則成為新回合；dock 計數遞減；無 interleave |
| 15 | Ctrl/Cmd+Enter（含中文 IME 輸入中） | composing 時不送出；確認後 gate 通過才 Send now |
| 16 | Windows＋Android 真機煙霧 | 兩平台 §6.2#1–8 全綠 |

---

## 7. 已知風險與取捨（Fail-safe 清單）

| # | 風險／取捨 | 對策 |
|:--:|:---|:---|
| R1 | **Enter 語義變更**（桌面進行中 Enter＝排隊） | l10n tooltip＋`composerKeyboardHint`；IME composing 不攔截；行動無影響 |
| R2 | **echo 訊息 consecutive-user 風險** | push 端合併為單則 echo（§3.1）、drain 注入也單則；**drain 時 echo 移到 assistant 前**（F15），避免下一輪 dangling user；與 review instruction 併入實例同因 |
| R3 | **結算續航與 Answer Review 互動** | review 逐段各自執行；續航只發生在「terminal 段結算之後」，不插入 review 內部；usage `sum` 語義按段落各自成立 |
| R4 | **midrun compaction 與注入時序** | drain 發生在 `maybeApplyMidRunCompaction` **之後**（同 hook 尾段），注入永不進 compactor 視野 |
| R5 | **跨對話 owner 錯置** | Send now 鈕僅對「當前檢視對話的 run」供給；mbox 以 conversationId＋run token 鍵定，跨對話 push 由 UI 條件根絕 |
| R6 | **queue dispatch 與 regeneration／版本樹** | dispatch 走正式 `sendMessage`——在版本樹尾端開新分支；echo 的 ordinal 交換不對版本群組做任何改動；regenerate 期間 `internalTransition` 抑制 dispatch |
| R7 | **dispatch 時附件檔已消失** | 附件路徑屬 upload 持久目錄；破損時落既有「unavailable chip」語義（多模態計畫 C），非新增行為 |
| R8 | **model 快照缺失**（dispatch 用當下模型，Anybuff 有快照） | v1 明示差異；若回饋要求，v2 把 `modelProvider/modelId/thinkingBudget` 併入 QueuedMessage 快照 |
| R9 | **程式重啟佇列不存** | 與 Anybuff 同；在 dock hint 說明「本 session 記憶體佇列」；持久化另案 |
| R10 | **single-flight 死鎖／重試風暴** | dispatch 全路徑 `try/catch/finally` 必清 `dispatchInFlight`；失敗回隊頭＋1.5s 冷卻；同一項連續失敗 2 次即 pause |
| R11 | **兩鍵閃爍**（續航若誤讓 loading 短暫 false→true） | `_finishStreaming(keepLoading: true)` 讓 loading 不落地；queue dispatch 只認 turn-end＋single-flight；測試斷言 loading 全程 true |
| R12 | **pending gate 誤判**（checkpoint 讀取失敗） | 讀取失敗視為 **blocked**（fail-safe，不 dispatch）；等下一次 turn-end 或使用者手動送出再試 |
| R13 | **轉場競態**（regenerate／resume 空窗被插隊） | `internalTransition(cid)` 旗標覆蓋整個轉場；`notifyTurnEnded` 走 microtask 再檢 loading／transition／pending |
| R14 | **錯誤路徑 mailbox 死鎖** | `_handleStreamError`／team-stop 必 `abandon()`；四路結算測試釘住 |
| R15 | **echo 崩潰殘留** | 崩潰時 pending echo 會以普通 user 訊息留在歷史（無 DB 標記）；列為已知限制，未來可加 `kind` 或 pending 表 |
| R16 | **續航段 title 時機** | 續航段 `generateTitleOnFinish: false`；首段可能先產 title（可接受）；v2 可延到最後一段 |
| R17 | **echo drain 時的 UI reflow** | 氣泡由 assistant 下方移到上方（一次性）；以 `AnimatedSwitcher`／keyed list 平滑；語義正確優先 |
| R18 | **AI Team 判定** | `isAiTeamRunActive(cid)` 於整個 team run（proposer＋aggregator）為 true；aggregator 即使經 kernel 也不 drain（防禦性） |

---

## 8. 與手冊的接軌（實作完成時）

- §3 新增「**3.25 執行佇列與訊息插隊（Turn Queue & Send now）**」：規格（§3 全文搬入 §3.25）、模組清單、資料流位置（送出／round 注入／結算／取消四個入口）。
- §4 新增決策：「per-conversation 佇列 v1 不背景 dispatch」「佇列以記憶體為限」「steering drain 使用 `AgentLoopHooks.onRoundStart` 引用傳參（零 kernel 改動）」「結算續航以 `_finishStreaming(keepLoading)` 保住 serial 調度」「mailbox owner 以 run token 區分」「dispatch 以 checkpoint paused gate 避開 approval／ask_user pending」「echo 於 drain 時以 ordinal swap 移到 assistant 之前」。
- §5 若實作時踩到新陷阱（如 provider 對注入 user 訊息處的特殊癖、ordinal 交換的 UI reflow），以當時證據補記。
- 頂部更新摘要行（仿既有風格單行 changelog）。

---

## 9. 已裁示事項（2026-11-10）

1. **「+」選單**：**不**把「排隊中」狀態做成入口；**不**在「+」圖示加 dot（dock 已承擔追蹤）。
2. **逐項 Send now**：v1 暫緩；dock 的「編輯」**只改文字**（附件不入編輯範圍）。
3. **附件-only**：採 (a)——Queue 顯示條件放寬為 `loading && (hasText || hasAttachments)`；Send now 仍限純文字（附件-only 時不出現 Send now）。
4. **修飾鍵**：維持現行（Shift+Enter 新行；其他修飾不猜）；補「Ctrl/Cmd+Enter 仍需尊重 IME composing，與現行 Enter 分支同守衛」。

### 9.1 v2 候選（不在本次範圍）

- 佇列逐項 Send now（需 edit 後 gate 重判與 mailbox 時序）。
- 佇列持久化／跨重啟恢復。
- QueuedMessage 的 model／effort 快照。
- AI Team steering（需 proposer／aggregator 的注入語義）。
- echo 的真正分段（把 assistant 訊息在注入點切成兩段，取代 ordinal swap）。
