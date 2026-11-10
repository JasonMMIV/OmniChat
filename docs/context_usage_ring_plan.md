# 上下文使用比例 Ring 實作計畫（v2，2026-11-11 修訂）

> 目標:把輸入列「上下文管理」按鈕(`Lucide.workflow`)升級為動態的上下文使用比例 ring,
> 視覺與行為比照 AnyBuff `desktop/src/renderer/src/components/Composer.tsx` 的 `TokenRing`。
> 點擊行為(壓縮/清空)、按鈕排序/隱藏設定完全不變。
>
> v2 依審查意見修正:壓縮邊界、measured 語義、手動/自動壓縮分流、`onMessagesChanged`
> 接線、模型切換有效性、選單 header 寬高、`peek` 冷啟動、refresh 競態、估算範圍、
> ratio/equality/animation 等共 16 點(對照見 §9)。**本文件只更新計畫,尚未改動程式碼。**
>
> **v2.1(實作後修訂)**:窗口未知時不再降級回 `workflow` 圖示。按鈕改為顯示空 ring
> (只畫 track);選單/sheet header 顯示 `used / ... Token`,且**不顯示百分比徽章**。
> snapshot 為 null 時按鈕同樣顯示空 ring,但 header 仍收起。§0 決策 1、§5/§6 的
> 「原圖示」描述與 §8 驗收清單已由本修訂取代。

## 0. 已確認決策

| # | 決策 |
|---|------|
| 1 | **窗口未知時**:learned 與 models.dev catalog 都查不到窗口 → 按鈕顯示空 ring(只畫 track),選單/sheet header 顯示 `used / ... Token` 且不顯示百分比徽章(仍不採用 `resolveContextWindowTokens` 的 1M fallback 來捏造比例) |
| 2 | **不做花費顯示**(AnyBuff 的 costUsd 部分) |
| 3 | **used/max 文字放在上下文管理選單的最上方**:桌面 = 錨定選單 header;手機 = `ContextManagementSheet` header。按鈕本身不放數字(tooltip 維持 `contextManagement`) |
| 4 | **measured 只作為 baseline**:measured assistant 自身的**文字回覆**(優先用 `completionTokens`)+ 之後的訊息補上,有任何估算成分就標 `≈` |
| 5 | **手動壓縮與自動壓縮分流**:手動壓縮 = 建立新會話;自動壓縮 = 同一會話推進 `compactBeforeIndex` |
| 6 | **估算必須鏡射真正的 API 組裝**:`truncateIndex` raw slice → 版本折疊 → `compactBeforeIndex` split(替換為 `<conversation_summary>`) |

## 1. 現況盤點(已逐項核對)

| 元素 | 位置 / 事實 |
|---|---|
| 按鈕本體 | `lib/features/home/widgets/chat_input_bar.dart` 的 `_buildResponsiveBottomRow`(L943);action id `'context'`(L1418),anchor `_contextMgmtAnchorKey`(L1421),`Lucide.workflow`;點擊開 `showContextMenu`(L1390) |
| 按鈕 slot | `_CompactIconButton`(L2567)支援 `childBuilder: Widget Function(Color)`(L2576/2586),非 model icon 時 `childSize = 24`(L2602-2608);`loading` prop 在 L118 |
| 按鈕目錄 | `lib/features/home/utils/chat_input_button_catalog.dart`;id `'context'` 不動,排序/隱藏不受影響 |
| 桌面選單 | `lib/desktop/desktop_context_menu.dart`;`showDesktopContextMenuAt` / `showDesktopAnchoredMenu`;**目前不支援 header**,`_estimateMenuWidth` 只量 item 文字,`estMenuHeight = items.length * 44` |
| 手機選單 | `lib/features/chat/widgets/context_management_sheet.dart`;目前只有 `onCompress/onClear/clearLabel`,需加 `header` |
| 手機入口 | `home_page.dart` `_toggleTools` → `BottomToolsSheet`(L1488)`onClear → _showContextManagementSheet`(L1495);手機輸入列沒有 context 按鈕(`chat_input_section.dart` L246-247 `isTablet ? … : null`) |
| 實測用量 | `ChatMessage.promptTokens`(HiveField 17);由 `chat_actions.dart` L3280-3315 在回合結束時寫入,是「產生該 assistant 的那次請求」的 prompt 大小 |
| 實測的限制 | ① 不包含之後才送出的 user 訊息;② 多輪 agent loop 取**最後一輪**的 usage snapshot(不是累加,`_CollectedRound.add` 是覆寫);③ Answer Review 回合會把 `reviewUsage` 加進 `chunk.usage`(`agent_orchestrator.dart` L889-912) |
| 模型身份 | assistant placeholder 寫入 `modelId` 與 `providerId = providerKey`(`message_generation_service.dart` L529-545);`ChatMessage` 有 `modelId/providerId` 欄位 |
| 估算尺 | `lib/core/services/agent/compaction/context_trim.dart`:`charsPerToken = 3`、`estimateTextTokens`、`estimateApiMessageTokens`;工具事件估算先例:`MessageGenerationService._estimateRawMessageTokens`(L110-121,private) |
| 窗口解析 | `LearnedContextWindows.lookup/peek`(兩者 nullable)+ `ModelCatalog.instance?.windowTokens(modelId, providerId:, host:)`(nullable);**沒有**使用者自訂 context window override;`resolveContextWindowTokens` 會退到 1M fallback,顯示層不可直接用 |
| learned 冷啟動 | `LearnedIntMap.peek`(L68)只讀記憶體;`_ensureLoaded` 只在 `lookup/record` 時跑(L41-43),所以冷啟動第一次 `peek` 必為 null |
| catalog 載入 | `main.dart` L108-113 `await ModelCatalogService.instance.ensureLoaded().timeout(3s)`,逾時則 `ModelCatalog.instance` 可能仍為 null |
| 清空分界 | `conversation.truncateIndex`;`toggleTruncateAtTail`(`chat_service.dart` L933-953)**只會**設 `-1` 或 `messages.length` |
| 自動壓縮分界 | `conversation.compactBeforeIndex`;`message_generation_service.dart` L244-248 設定;`MessageBuilderService.buildApiMessages` L263-307 把 `[truncateIndex, compactBeforeIndex)` 換成一則 `<conversation_summary>`(Hive 歷史不變) |
| 手動壓縮 | `HomeViewModel.compressContext`(L514-598)**建立新會話**,把摘要當第一則 user message,最後 `onConversationSwitched?.call()`;不設 `compactBeforeIndex` |
| 版本折疊 | `MessageBuilderService.collapseVersions(items, versionSelections)`;`HomeViewModel.collapseVersions(items)` 是無參數 wrapper(L677)→ `ChatController.collapseVersions`(L322,使用當前 `_versionSelections`) |
| 訊息變更回呼 | 實際接線:`home_view_model.dart` L98 `_chatActions.onMessagesChanged = _onMessagesChanged`,L202 只 `notifyListeners()`;`message_generation_service.dart` L93 只有欄位宣告。串流中 `chat_actions.dart` L3027 明確不呼叫它 |
| 串流完成回呼 | `HomeViewModel.onStreamFinished`(L158/247);`HomePageController` 已在 L686-690 設定 `onConversationSwitched` / `onStreamFinished` |
| 載入狀態 | `ChatInputSection.isLoading` → `ChatInputBar.loading`(L118),可直接驅動 ring 的 running 脈動 |
| l10n | `lib/l10n/app_en.arb`(template)、`app_zh.arb`、`app_zh_Hans.arb`、`app_zh_Hant.arb`;`l10n.yaml` 指定 `app_en.arb` |

## 2. 資料模型

```dart
/// 一次性快照,由 controller 計算後放入 ValueNotifier。
@immutable
class ContextUsageSnapshot {
  final int usedTokens;
  final int? maxTokens;      // null = 窗口未知 → 空 ring + header 顯示 used / ...
  final bool measured;       // 是否有實測 baseline
  final bool estimated;      // 是否有估算成分(measured + delta 或整段估算)
  final String? modelId;     // 產生此快照時的邏輯 model id(除錯/防競態)
  final String? providerKey; // 產生此快照時的 provider key

  const ContextUsageSnapshot({
    required this.usedTokens,
    required this.maxTokens,
    required this.measured,
    required this.estimated,
    this.modelId,
    this.providerKey,
  });

  bool get hasWindow => maxTokens != null && maxTokens! > 0;

  /// 未 clamp 的比例;> 1 代表已超過窗口(模型切換/實測過期)。
  double get rawRatio =>
      hasWindow ? usedTokens / maxTokens! : 0.0;

  /// 給 ring 弧線用,clamp 到 0..1。
  double get ratio => rawRatio.clamp(0.0, 1.0).toDouble();

  /// header badge 用真實百分比(可 > 100)。
  int get displayPercent => (rawRatio * 100).round();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ContextUsageSnapshot &&
          other.usedTokens == usedTokens &&
          other.maxTokens == maxTokens &&
          other.measured == measured &&
          other.estimated == estimated &&
          other.modelId == modelId &&
          other.providerKey == providerKey;

  @override
  int get hashCode => Object.hash(
        usedTokens, maxTokens, measured, estimated, modelId, providerKey,
      );
}
```

> `ValueNotifier` 用 `==` 比較;沒有覆寫 `==` 會每次 refresh 都通知,造成不必要重建。
> `@immutable` 需 `import 'package:flutter/foundation.dart';`。
> `used > max` 時 ring 畫滿(ratio=1),但 header 顯示真實 `displayPercent`(例如 112%),不要只顯示 100%。

## 3. 改動清單(逐檔)

### A.(新檔)`lib/features/home/services/context_usage_service.dart`

純計算服務,不依賴 Flutter UI;估算與折疊函式以參數注入,便於單元測試。

#### A-1. 共用估算函式(順便把 `MessageGenerationService._estimateRawMessageTokens` 搬出來)

```dart
/// 一則訊息的 chars/3 估算,含 tool events 的 args/result。
int estimateChatMessageTokens(
  ChatMessage message, {
  required Iterable<Map<String, dynamic>> toolEvents,
}) {
  var chars = message.content.length;
  for (final e in toolEvents) {
    try {
      chars += jsonEncode(e['arguments'] ?? const <String, dynamic>{}).length;
    } catch (_) {}
    chars += (e['content'] ?? '').toString().length;
  }
  return (chars / charsPerToken).ceil();
}
```

- 這個檔案需要 `import 'dart:convert';` 與 `charsPerToken`(`context_trim.dart`)。
- `MessageGenerationService._estimateRawMessageTokens` 改為呼叫它,避免兩份估算漂移。
- `HomePageController` 的注入版本:`(m) => estimateChatMessageTokens(m, toolEvents: chatService.getToolEvents(m.id))`。

#### A-2. Token 文字格式(對齊 AnyBuff `formatTokens`)

```dart
String compactTokenText(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
  return '$n';
}
```

- 注意 AnyBuff 會保留 `.0`(`12_000 → '12.0k'`);若產品要 `12k`,另加 trim,但測試要寫清楚。v1 先照 AnyBuff。

#### A-3. `computeContextUsage`(核心;必須鏡射 `MessageBuilderService.buildApiMessages`)

```dart
ContextUsageSnapshot computeContextUsage({
  required List<ChatMessage> rawMessages,
  required Map<String, int> versionSelections,
  required int truncateIndex,
  required int compactBeforeIndex,
  required bool enableAutoCompaction,
  required int? learnedWindowTokens,
  required int? catalogWindowTokens,
  required String? currentModelId,
  required String? currentProviderKey,
  required String? streamingMessageId,
  required List<ChatMessage> Function(
    List<ChatMessage>, Map<String, int>,
  ) collapseVersions,
  required int Function(ChatMessage) estimateMessageTokens,
  required int Function(List<ChatMessage> headMessages) estimateCompactedHeadTokens,
})
```

演算法:

1. **max**:`learned > 0 ? learned : (catalog > 0 ? catalog : null)`;兩者皆無 → `maxTokens = null`(顯示層降級)。
2. **raw slice(與 `MessageBuilderService` L283-285 一致)**:
   ```dart
   final tValid = truncateIndex >= 0 && truncateIndex <= rawMessages.length;
   final rawStart = tValid ? truncateIndex : 0;
   final sourceAll = tValid
       ? rawMessages.sublist(truncateIndex)
       : List<ChatMessage>.of(rawMessages);
   ```
   - **不要**用 `computeClearContextRemainingMessageCount` 的 group 首索引規則;那是「剩餘訊息數」的 UI 規則,不是 token 組裝規則。
   - **不要**抄 `ChatTurnService` 的 `< messages.length`(`chat_turn_service.dart` L161-164);清空後 `truncateIndex == messages.length` 必須切成空,否則估算會把已清空的歷史全部加回來。
3. **版本折疊**:`collapsedAll = collapseVersions(sourceAll, versionSelections)`;**先 raw slice,再折疊**(與 `buildApiMessages` 相同)。若 `hasCompact`,可跳過 `collapsedAll`,只折疊 head/tail,避免重複走訪。
4. **`compactBeforeIndex` split**:
   ```dart
   final compactSplit = compactBeforeIndex - rawStart;
   final hasCompact = enableAutoCompaction &&
       compactBeforeIndex > 0 &&
       compactSplit > 0 &&
       compactSplit < sourceAll.length;

   final List<ChatMessage> active;
   final List<ChatMessage>? compactedHead;
   if (hasCompact) {
     final head = collapseVersions(
       sourceAll.sublist(0, compactSplit), versionSelections);
     final tail = collapseVersions(
       sourceAll.sublist(compactSplit), versionSelections);
     active = tail;
     compactedHead = head;
   } else {
     active = collapsedAll;
     compactedHead = null;
   }
   ```
   - `enableAutoCompaction` 必須是 `settings.autoCompactionV1`:設定關閉時 `buildApiMessages` 不會套 split,估算也不能套。
   - **head summary 只在沒有 measured 時才計算**(§3A-7);measured 路徑不需要重建 head summary,避免每次 tool event 都跑一次 `compactHistoryMessages`。
   - 若估算路徑頻繁觸發,可依 `(conversationId, compactBeforeIndex, head 的 id 清單/hash)` 快取 head summary;**不要只用長度**,編輯訊息可能讓長度不變但內容變了。v1 可先不快取。
   - `estimateCompactedHeadTokens` 由 controller 注入,內部用
     `MessageBuilderService.neutralMessagesFor(head, settings.replayToolResults, includeGeminiThoughtSignatures: …)`
     → `compactHistoryMessages(...)` → `estimateApiMessageTokens(summary)`。
     summary 為 null 時回 0(實際請求也不會有 head)。
   - `compactionNextAction` / `todoSummaryOverride` v1 傳 null;與實際請求的摘要文字可能有小幅差異,但量級正確(文件註記)。

5. **尋找可用的 measured**(在 `active` 中由尾端往前):
   ```dart
   // 先建 raw id → raw index,避免 O(n²)
   final rawIndexById = { for (var i = 0; i < rawMessages.length; i++) rawMessages[i].id: i };

   ChatMessage? measuredMessage;
   int measuredAt = -1;
   for (var i = active.length - 1; i >= 0; i--) {
     final m = active[i];
     if (m.role != 'assistant' || (m.promptTokens ?? 0) <= 0) continue;
     final rawIndex = rawIndexById[m.id];
     if (rawIndex == null || rawIndex < rawStart) continue;
     if (hasCompact && rawIndex < compactBeforeIndex) continue; // 壓縮前實測已過期
     // currentModelId/currentProviderKey 已由 refresh 入口保證非 null;
     // 舊資料缺 modelId/providerId 也會被這個 equality 擋掉(保守)。
     if (m.modelId != currentModelId ||
         m.providerId != currentProviderKey) continue;
     measuredMessage = m;
     measuredAt = i;
     break;
   }
   ```
   - `modelId/providerId` 由 assistant placeholder 寫入(`message_generation_service.dart` L540-541),所以正常訊息都有;缺少的舊資料會被 equality 擋掉、退回估算,避免跨模型誤差。
   - `rawIndex < compactBeforeIndex` 的排除很重要:壓縮後請求失敗、或使用者刪掉壓縮後的回覆時,最後一則 assistant 可能是壓縮前的大 prompt,不能拿來顯示。

6. **有 measured:補上 measured assistant 自身 + trailing delta**
   ```dart
   if (measuredMessage != null) {
     // measured 的 prompt 不含該則 assistant 自己的文字回覆,但下一個 prompt 會包含。
     // 只加 content,不加它的 tool events:agent loop 的 tool calls/results 已經
     // 在最後一輪的 prompt 內,再加一次會重複計算。
     final hasExactCompletion = (measuredMessage.completionTokens ?? 0) > 0;
     final completion = hasExactCompletion
         ? measuredMessage.completionTokens!
         : estimateTextTokens(measuredMessage.content);
     var delta = completion;
     var hasEstimate = !hasExactCompletion;
     for (var j = measuredAt + 1; j < active.length; j++) {
       final m = active[j];
       if (m.role == 'assistant' && m.id == streamingMessageId) continue; // 進行中的輸出不算 prompt
       delta += estimateMessageTokens(m);
       hasEstimate = true;
     }
     final used = measuredMessage.promptTokens! + delta;
     return ContextUsageSnapshot(
       usedTokens: used,
       maxTokens: maxTokens,
       measured: true,
       estimated: hasEstimate || streamingMessageId != null,
       modelId: currentModelId,
       providerKey: currentProviderKey,
     );
   }
   ```
   - 這修正「使用者剛送出 10k 文件,ring 還停在上一輪」的低估;同時讓回合結束前的顯示更接近下一個請求。
   - measured assistant 只加 completion(`completionTokens`,沒有才用 `estimateTextTokens(content)`),不加它的 tool events:多輪 agent loop 的 tool pairs 已經是最後一輪 prompt 的一部分,再加會重複。若 loop 在 max steps 停在一個 tool call(沒有文字回覆),該最後 tool result 會少算;這是罕見邊界,v1 接受。
   - 其後訊息的 `estimateMessageTokens` 才含 tool events,且要跟 `settings.replayToolResults` 一致;replay=false 時 controller 傳空列表,否則會高估。
   - 若 provider 沒回 usage(`promptTokens == 0`)而落到更早的 measured,中間完成的 assistant 會用完整估算(含 tool events)計入。
   - `estimated` 也包含「streaming 中」:approval/ask_user resume 會在上一則 assistant 上追加 tool result,該增量不是獨立訊息、不會進 delta;此時 measured 是最後一則非 streaming 訊息,標 `≈` 才誠實。
   - 若 `completionTokens` 存在且沒有 trailing 訊息/串流,`estimated` 可以是 false(measured prompt + measured completion);只有用到 `estimateTextTokens` 或 trailing 估算時才標 `≈`。

7. **沒有 measured:純估算**
   ```dart
   var used = compactedHead == null
       ? 0
       : estimateCompactedHeadTokens(compactedHead);
   for (final m in active) {
     used += estimateMessageTokens(m);
   }
   return ContextUsageSnapshot(
     usedTokens: used,
     maxTokens: maxTokens,
     measured: false,
     estimated: true,
     modelId: currentModelId,
     providerKey: currentProviderKey,
   );
   ```
   - **已知下界**:估算只含聊天訊息 + tool events + 壓縮摘要;不含 system prompt、tool definitions、memory/instruction/search 注入、todo state pair。小窗口(32k)可能低估 10-30%,所以一定要標 `≈`。
   - tail 的估算未套 `applyToolResultMiddlePrune`(L0 的 8192-char 中段裁剪),會略微高估;v1 接受,精準版可對 tail 建 neutral messages 後 prune 再估算。
   - 可選 Phase 2:用上一次 measured 反推 `staticOverhead = measured - Σ estimate(該次 prompt 的訊息)`,再加到估算;v1 不做,先把正確性站穩。

#### A-4. 邊界與防護

- `estimateCompactedHeadTokens` 拋錯 → catch、回 0(實際請求若 summary 失敗也不會送 head)。
- `rawMessages` 空 → `used = 0`;`maxTokens` 已知時 ring 顯示 0%。
- `maxTokens == null` 仍回傳 snapshot(供除錯/header 判斷),UI 依 `hasWindow` 隱藏。
- `estimateMessageTokens` 必須是 pure/無 await;controller 的 tool events 讀取是同步 cache(`getToolEvents` 回傳記憶體列表),不能在每次 refresh 做 I/O。

### B.(新檔)`lib/features/home/widgets/context_usage_ring.dart`

#### B-1. `ContextUsageRing`

```dart
ContextUsageRing({
  required double ratio,       // 已 clamp 0..1
  double size = 20,
  double strokeWidth = 2.6,
  bool running = false,
  Color? trackColor,           // 由 childBuilder 的 fgColor 帶入,保留 hover 回饋
})
```

- `CustomPaint`:底軌 `trackColor ?? onSurface @ 10%` + 比例弧;12 點鐘起始、`StrokeCap.round`。
- 三段色階:`ratio < 0.70` → `colorScheme.primary`;`0.70–0.89` → `Colors.orange.shade600`;`≥ 0.90` → `colorScheme.error`。
- **Stateful**,保留 `_displayedRatio`;`didUpdateWidget` 從目前值動畫到新值(250ms),**不要**每次 `ChatInputBar` 重建都從 0 開始。
  - 可用一個 `AnimationController` + `Tween<double>`;`dispose` 釋放。
  - `running` 另用一個重複反向的 `AnimationController`(0.55→1.0,約 1.1s),`running` false 時 stop/reset;`dispose` 釋放。
- `Semantics(label: …)` 可選;至少不要讓 ring 吃掉 `IosIconButton` 的 tooltip semantics。
- 20px ring 放進 `_CompactIconButton` 的 24px slot,置中;stroke 2.6 不會碰到邊。

#### B-2. `ContextUsageMenuHeader`

```dart
ContextUsageMenuHeader({
  required ValueListenable<ContextUsageSnapshot?> listenable,
  EdgeInsets padding = const EdgeInsets.fromLTRB(12, 10, 12, 10),
})
```

- `ValueListenableBuilder`;`value == null || !hasWindow` → `SizedBox.shrink()`(**不要**留固定高度/空白 gap)。
- 版面:
  `[ring 18px]  12.3k / 200k Token  ≈   ······   [6.2% badge]`
  - ring:`ContextUsageRing(ratio: snap.ratio, size: 18, strokeWidth: 2.2)`;`running` 不需要(header 不在輸入列)。
  - 文字:`compactTokenText(used) / compactTokenText(max) Token`;`Flexible` + `TextOverflow.ellipsis`,避免窄選單溢出。
  - `≈`:只有 `snap.estimated` 時顯示;可用 `l10n.contextUsageEstimatedBadge` 當 tooltip/label。
  - **badge 規則**:只要 `snap.estimated == true` 就顯示 `≈`;`snap.measured` 僅用於除錯/可選文案,不影響 badge。
  - badge:`displayPercent`(可 >100),`ratio >= 0.90` 時用 `colorScheme.error` 背景/文字。
- header 不接收點擊、不關閉選單;桌面選單的 divider 由 `desktop_context_menu.dart` 加,sheet 由呼叫端加 bottom padding。
- 手機 sheet 開啟後若 lookup 才完成,header 會從 shrink 變成有內容, sheet 高度可能跳一次;`_showContextManagementSheet` 先 `await refreshContextUsage()` 可避免(見 §3H)。

### C. `lib/desktop/desktop_context_menu.dart`

- `showDesktopContextMenuAt` / `showDesktopAnchoredMenu` 新增選用參數:
  ```dart
  Widget? header,
  double headerHeight = 0,   // 未給且 header != null 時用 56
  double? minMenuWidth,      // header 較寬時由呼叫端給,例如 240
  ```
- `_estimateMenuWidth(ctx, items, minW, maxW, {double? minMenuWidth})`:
  ```dart
  final measured = maxText.clamp(minW, maxW).toDouble();
  return math.max(
    measured,
    (minMenuWidth ?? 0).clamp(minW, maxW).toDouble(),
  );
  ```
- `estMenuHeight = (items.length * 44.0 + (header != null ? (headerHeight > 0 ? headerHeight : 56) : 0)).clamp(44.0, menuMaxHeight)`;需要 `import 'dart:math' as math;`。
  - 上下翻轉判斷、`showDesktopAnchoredMenu` 的置中寬度都要用**同一個** `menuWidth` / `estMenuHeight`;不要把 header 只加在 render、卻用舊高度判斷。
- `showDesktopAnchoredMenu` 必須把 `header/headerHeight/minMenuWidth` 原樣轉給 `showDesktopContextMenuAt`,並用同一組 `menuWidth/estMenuHeight` 置中/翻轉;只改其中一邊會讓選單偏位。
- header 渲染在 glass `Column` 首位,下面加 1px 髮絲線(`outlineVariant @ 0.2`),**不要**包 `_GlassMenuItem`/`IosCardPress`(點 header 不應關閉選單)。
- 既有右鍵選單呼叫端不傳 header,行為不變。

### D. `lib/features/chat/widgets/context_management_sheet.dart`

- 新增 `Widget? header`。
- 位置:
  - `header == null` → drag handle → `SizedBox(16)` → 第一個 `_OptionRow`(現狀)。
  - `header != null` → drag handle → `header` → 第一個 `_OptionRow`(**跳過 16px**,header 自己負責上下間距)。
- `header` 在 unknown 時回 `SizedBox.shrink()`(zero size),**shrink 分支不要包 Padding**;這樣不會留 gap。
- `onCompress/onClear/clearLabel` 不變。

### E. `lib/features/home/widgets/chat_input_bar.dart`

- 新 prop:`final ValueListenable<ContextUsageSnapshot?>? contextUsage;`
- `'context'` action(L1416-1433)的 `builder`:
  ```dart
  _CompactIconButton(
    tooltip: l10n.contextManagement,
    icon: Lucide.workflow,
    onTap: showContextMenu,
    childBuilder: widget.contextUsage == null
        ? null
        : (c) => ContextUsageButtonIcon(
              usage: widget.contextUsage!,
              loading: widget.loading,
              color: c,
            ),
  )
  ```
  - `_CompactIconButton` 的 `childBuilder` 已被包在 `SizedBox(24,24)`,ring 20px 置中。
  - 未知窗口 → 空 ring(只畫 track);`contextUsage == null` 時連 `ValueListenableBuilder` 都不建(維持原圖示)。
- `showContextMenu`(L1390):
  ```dart
  final usage = widget.contextUsage?.value;
  showDesktopAnchoredMenu(
    context,
    anchorKey: _contextMgmtAnchorKey,
    header: (usage != null && usage.hasWindow)
        ? ContextUsageMenuHeader(listenable: widget.contextUsage!)
        : null,
    headerHeight: 56,
    minMenuWidth: (usage != null && usage.hasWindow) ? 240 : null,
    items: [...],
  );
  ```
  - header 本身用 `ValueListenableBuilder`,選單開著時實測完成會即時更新。
  - 若開啟時窗口未知、之後才學到,header 不會臨時出現(可接受;下次開啟才有)。要即時出現就得固定傳 header + 動態高度,代價是選單高度不準。
- `'context'` 的 `menu:`(overflow 版本)維持 `Lucide.workflow`;ring 只出現在輸入列。header 兩條路徑共用 `showContextMenu`,所以 overflow 開啟時仍看得到 header。
- `IosIconButton` 的 hover/press 顏色動畫會傳進 `childBuilder`;ring 用 `trackColor` 保留回饋,填充色仍用三段色階。

### F. `lib/features/home/widgets/chat_input_section.dart`

- 新 prop:`final ValueListenable<ContextUsageSnapshot?>? contextUsage;`
- 傳給 `ChatInputBar(contextUsage: contextUsage, ...)`;不 watch、不重建。
- `isTablet ? onClearContext : null` / `isTablet ? onCompressContext : null` 不動(手機仍從 BottomToolsSheet 進 sheet)。

### G. `lib/features/home/controllers/home_page_controller.dart`

#### G-1. State

```dart
final ValueNotifier<ContextUsageSnapshot?> contextUsage = ValueNotifier(null);
Timer? _contextUsageDebounce;
int _contextUsageEpoch = 0;
bool _contextUsageCatalogRetryScheduled = false;
bool _contextUsageReady = false;
bool _usageListenersAttached = false;
({String providerKey, String modelId})? _lastUsageModelKey;
```

- `_scheduleContextUsageRefresh()`:若 `_disposed` 或 `!_contextUsageReady` 直接 return;cancel 舊 timer;`Timer(120ms, () => unawaited(refreshContextUsage()))`。
  - `_contextUsageReady` 在 `_initialize` 完成、`_viewModel`/`_messageBuilderService` 都建立後設為 true,再呼叫第一次 refresh;避免 late field 尚未初始化時被 listener 觸發。
  - 120ms 只是合併同一波事件,不是「串流節流」;`onMessagesChanged` 是離散事件,不需要 500ms。
- `refreshContextUsage()`:
  1. 若 `_disposed` return。
  2. `final convo = currentConversation; if (convo == null) { contextUsage.value = null; return; }`
  3. 解析 **effective model**(要跟 send/regenerate 路徑一致):
     - `assistant = convo.assistantId == null ? ap.currentAssistant : ap.getById(convo.assistantId!)`
     - `mc = _messageGenerationService.getModelConfig(settings, assistant)`(`getModelConfig` 是 public,`message_generation_service.dart` L605)
     - `final aiTeam = context.read<AiTeamProvider>();`(lazy,refresh 時已過 initState;讀取失敗時視為未啟用,不要讓 ring 拖垮聊天)
     - 若 `aiTeam.enabled && aiTeam.config.aggregator != null`,改用 aggregator 的 `providerKey/modelId`(對應 `chat_actions.dart` 的 `effProviderKey/effModelId`);否則用 `mc`。
     - 令 `providerKey/modelId` 為上述 effective 值;任一為 null → `contextUsage.value = null; return;`
  4. 以下直接用 step 3 的 effective `providerKey/modelId`。
  5. `final cfg = settings.getProviderConfig(providerKey);`
  6. `final learnedPeek = LearnedContextWindows.peek(providerKey, modelId);`
  7. `final catalogWindow = ModelCatalog.instance?.windowTokens(modelId, providerId: cfg.catalogProviderId, host: cfg.catalogHost);`
  8. `final epoch = ++_contextUsageEpoch;`
  9. 用 `computeContextUsage(...)` 算第一版:
     - `rawMessages: messages`
     - `versionSelections: versionSelections`
     - `truncateIndex: convo.truncateIndex`
     - `compactBeforeIndex: convo.compactBeforeIndex`
     - `enableAutoCompaction: settings.autoCompactionV1`
     - `learnedWindowTokens: learnedPeek`
     - `catalogWindowTokens: catalogWindow`
     - `currentModelId: modelId`、`currentProviderKey: providerKey`
     - `streamingMessageId`:由尾端找第一則 `isStreaming` 的 id(用 simple loop,不依賴 `firstWhereOrNull`)
     - `collapseVersions: _messageBuilderService.collapseVersions`
     - `estimateMessageTokens: (m) => estimateChatMessageTokens(m, toolEvents: settings.replayToolResults ? _chatService.getToolEvents(m.id) : const [])`
     - `estimateCompactedHeadTokens: (head) => _estimateCompactedHeadTokens(head, settings, providerKey)`(見 G-2)
  10. `_setContextUsageIfCurrent(epoch, convo.id, providerKey, modelId, snapshot)`。
  11. `final learned = await LearnedContextWindows.lookup(providerKey, modelId);`
      - await 後重新檢查 `epoch == _contextUsageEpoch && !_disposed && currentConversation?.id == convo.id && model identity 未變`;不符就丟棄(避免舊 lookup 覆蓋新會話/新模型)。
      - await 後重新取一次 `messages`(清單可能已更新),再用同一 epoch 重算。
      - 重算後直接 `contextUsage.value = next`(`ValueNotifier` 有 `==`,相同值不會通知);不需要手動比對。
  12. 若 `ModelCatalog.instance == null` 且尚未排程:
      ```dart
      _contextUsageCatalogRetryScheduled = true;
      unawaited(ModelCatalogService.instance.ensureLoaded().then((_) {
        _contextUsageCatalogRetryScheduled = false;
        if (!_disposed) _scheduleContextUsageRefresh();
      }));
      ```
      解決 `main.dart` 3 秒 timeout 後 catalog 才載入、ring 一直隱藏的問題。

#### G-2. `estimateCompactedHeadTokens`

```dart
int _estimateCompactedHeadTokens(
  List<ChatMessage> head,
  SettingsProvider settings,
  String providerKey,
) {
  final cfg = settings.getProviderConfig(providerKey);
  final isGoogle =
      ProviderConfig.classify(cfg.id, explicitType: cfg.providerType) ==
          ProviderKind.google;
  final api = _messageBuilderService.neutralMessagesFor(
    head,
    settings.replayToolResults,
    includeGeminiThoughtSignatures: isGoogle,
  );
  final summary = compactHistoryMessages(api); // null → 0
  return summary == null ? 0 : estimateApiMessageTokens(summary);
}
```

- `neutralMessagesFor` 是 public;`compactHistoryMessages` / `estimateApiMessageTokens` 都是 public。
- `ProviderConfig.classify(cfg.id, explicitType: cfg.providerType)` 與 `MessageGenerationService._isGoogleProviderKey` 的邏輯相同(後者也是 classify);重點是**與 `buildApiMessages` 的 `includeGeminiThoughtSignatures` 判斷一致**,否則 head 估算和實際請求會有小差異。`ProviderKind` 需 import。
- `compactionNextAction`/`todoSummaryOverride` v1 傳 null;文件註記。

#### G-3. 接線 / 生命週期

- 在 `_initialize` 建立 `_viewModel` 後:
  ```dart
  _viewModel.onMessagesChanged = _scheduleContextUsageRefresh; // 新 public callback
  ```
  既有 `onStreamFinished` / `onConversationSwitched` closure(L686-690)內追加 `_scheduleContextUsageRefresh();`。
- 模型/assistant 變更:
  - **不要在建構子的 `_initialize` 直接 `context.read` 註冊 listener**(State 尚未完成第一次 build 時可能不安全)。改成 lazy attach:第一次 `refreshContextUsage()` 時(已在 initState 之後)才 `context.read<SettingsProvider>()` / `context.read<AssistantProvider>()` / `context.read<AiTeamProvider>()` 並 addListener;或在 `HomePage.didChangeDependencies` 注入。用 `_usageListenersAttached` 防止重複註冊。
  - `_onModelIdentityMaybeChanged`:算 **effective** `(providerKey, modelId)`(含 AI Team aggregator override);與 `_lastUsageModelKey` 相同就 return;不同才更新並 `_scheduleContextUsageRefresh()`。
  - 在 `refreshContextUsage` 算出 effective key 後也更新 `_lastUsageModelKey`,讓 listener 的比較有基準。
  - `dispose` 移除 listener、cancel debounce、`contextUsage.dispose()`。
- `HomePageController.clearContext`(L1048)在 `await _viewModel.clearContext();` 後呼叫 `_scheduleContextUsageRefresh()`(清空不動 `onConversationSwitched`)。
- `HomePageController.compressContext`(L1054)成功後 `_scheduleContextUsageRefresh()`;`_viewModel.compressContext` 本身已會 `onConversationSwitched`(新會話),兩個觸發點都安全(有 `==`/debounce)。
- `onStreamFinished` 後刷新:此時 `promptTokens` 已落庫(`chat_actions.dart` L3280-3315),measured 才生效。
- 首次載入 / `_initialize` 完成後呼叫一次 `refreshContextUsage()`;`ModelCatalog` 的 3 秒 timeout 由 G-1.12 補救。
- **`onMessagesChanged` 的正確語義**:它是 `HomeViewModel` 的離散事件回呼(訊息新增、tool event、回合完成、版本切換等),不是串流高頻 tick;串流內容更新走 `StreamingContentNotifier`,不呼叫它(`chat_actions.dart` L3027)。所以不要再加 500ms 節流。

### H. `lib/features/home/controllers/home_view_model.dart`

- 新增 public callback(放在 L145-171 的 callback 區):
  ```dart
  VoidCallback? onMessagesChanged;
  ```
- `_onMessagesChanged()`(L202):
  ```dart
  void _onMessagesChanged() {
    notifyListeners();
    onMessagesChanged?.call();
  }
  ```
- 這讓 controller 能在「訊息清單真的變了」時刷新,而不必在 `HomePage` 每次重建時掃描 messages。

### I. `lib/features/home/pages/home_page.dart`

- `ChatInputSection(...)`(L1101)加 `contextUsage: _controller.contextUsage`。
- `_showContextManagementSheet`(L1547)在 `showModalBottomSheet` 前:
  ```dart
  await _controller.refreshContextUsage(); // 避免 sheet 開啟後 header 才長高
  ```
  然後 `ContextManagementSheet(header: ContextUsageMenuHeader(listenable: _controller.contextUsage), ...)`。
  - 若不想等待,可只在 `!(_controller.contextUsage.value?.hasWindow ?? false)` 時 await;但 `refresh` 的 peek/catalog 路徑是同步的,實際很快。
  - `await` 後要檢查 `mounted`,避免 controller 在等待期間 dispose 才開 sheet。
- `BottomToolsSheet` 不變(手機入口仍是清空 → sheet)。

### J. l10n(4 個 arb + gen)

- 新 key:`contextUsageEstimatedBadge`
  - en:`≈ estimated`
  - zh / zh_Hans / zh_Hant:`≈ 估算`
- 單位「Token」與百分比不新增 key(沿用專案「Token」寫法)。
- 改完跑 `flutter gen-l10n`。`l10n.yaml` template 是 `app_en.arb`,四個檔案都要補。

## 4. 更新時機(修正版)

| 事件 | 動作 |
|---|---|
| `HomeViewModel.onMessagesChanged`(訊息新增/刪除、tool event、版本切換、回合完成) | `_scheduleContextUsageRefresh()`(120ms 合併) |
| `onStreamFinished`(usage 已落庫) | 立即 refresh(合併排程) |
| 使用者送出訊息(新增 user message) | 隨 `onMessagesChanged` 刷新;measured baseline + trailing delta 會先反映 |
| 清空上下文 | `HomePageController.clearContext` 後立即 refresh(`truncateIndex` 變 length) |
| 手動壓縮完成 | `onConversationSwitched`(新會話)+ `compressContext` 成功後 refresh |
| 自動壓縮(`compactBeforeIndex` 前移) | 下一輪 `promptTokens` 落庫後由 `onStreamFinished` 刷新;估算路徑用 split,不會把 head 加回來 |
| 切換會話 / 首次載入 | `onConversationSwitched` + `_initialize` 完成後 refresh |
| 切換 assistant / model | settings/assistant listener → 只在 `(providerKey, modelId)` 變更時 refresh |
| catalog 載入完成(3s timeout 後) | `ensureLoaded().then(...)` 補一次 refresh |
| 開手機 sheet | 先 `await refreshContextUsage()` 再開,避免 header 高度跳動 |

## 5. 邊界情況(修正版)

- **手動壓縮**:新會話、第一則 user = 摘要;measured 為空 → 估算。ring 應從 0 開始,不是延續舊會話的比例。
- **自動壓縮**:同一會話;`compactBeforeIndex` 之後的實測才有效。`rawIndex < compactBeforeIndex` 的 measured 一律視為過期(壓縮後請求失敗、刪掉壓縮後回覆等)。
- **清空上下文 == `truncateIndex = messages.length`**:slice 成空 → used 0;要使用 `<=`,不是 `<`。
- **清空後 restore(`truncateIndex = -1`)**:measured 重新有效,ring 回到舊比例。
- **最後實測之後有長 user 訊息(或 measured assistant 自己的文字回覆)**:measured + delta(measured 加 `completionTokens`/content,之後訊息含 tool events);有估算成分時顯示 `≈`。
- **AI Team**:effective model 是 aggregator;若 refresh 只用 `getModelConfig`,AI Team 對話的 measured 會因 model mismatch 被拒、窗口也會錯。
- **串流中**:`promptTokens` 尚未落庫,measured 來自上一則 assistant + trailing user delta;`running` 脈動;回合完成後跳到實測值。
- **模型/provider 切換**:measured 必須 `modelId/providerId` 相符;否則退回估算(標 `≈`)。這避免舊 tokenizer 的數字套到新窗口。
- **Answer Review**:`promptTokens` 含 review 子請求(`agent_orchestrator.dart` L889-912),會高估。v1 接受並在文件註記;要精準就另存 `reviewPromptTokens` 再扣除(需 schema/寫入變更,不在本版範圍)。
- **版本折疊 / regenerate**:先 raw slice,再 `collapseVersions`;`versionSelections` 必須是當前 selections。regenerate 完成後走 `onMessagesChanged`。
- **空會話**:窗口已知 → ring 0%;未知 → 空 ring(track only)。
- **窗口未知**:learned/catalog 都 null → `hasWindow == false`;按鈕顯示空 ring,選單/sheet header 顯示 `used / ... Token`、不顯示百分比。
- **used > max**:ring 畫滿;header 顯示真實百分比(例如 112%),紅色;不要 clamp 成 100% 文字。
- **`ChatInputBar` 頻繁重建**:ring 是 stateful、保留 `_displayedRatio`;不會每次從 0 閃一下。
- **選單 header 寬度**:`minMenuWidth: 240` + `Flexible`/ellipsis;`estMenuHeight` 加 header 高度,否則上下翻轉會差 header 高度。
- **手機 sheet header**:snapshot 為 null 時保留原本 16px 間距,不留多餘 gap;開 sheet 前先 refresh,避免高度跳動。
- **refresh 競態**:epoch + `(conversationId, providerKey, modelId)` 檢查;`_disposed` 保護;`ValueNotifier` 的 `==` 避免重複通知。
- **估算下界**:不含 system/tool defs/memory/instruction/search/todo pair;v1 以 `≈` 表達,不假裝精確。
- **範圍外(明確不做)**:手機 BottomToolsSheet 清空列的 ring 小圖示、cost 顯示、桌面按鈕旁 used/max 文字、Answer Review 的精準扣除。

## 6. 測試計畫

| 檔案 | 內容 |
|---|---|
| `test/features/home/services/context_usage_service_test.dart`(新,單元) | max 優先序(learned > catalog > null);`truncateIndex` -1/length/invalid;slice→collapse 的版本群組;`compactBeforeIndex` split(head summary + tail,不重複加 head);`autoCompactionV1 = false` 不 split;measured 有效性(raw index < truncateIndex、< compactBeforeIndex、model/provider 不符 → 退回估算);trailing delta(measured assistant 用 completionTokens/文字、tool events 不重複、streaming assistant 排除、`estimated` 只在有估算時為 true);純估算;`rawRatio`/`displayPercent`(150% = 300k/200k、125% = 250k/200k);`compactTokenText`;`==/hashCode` |
| `test/features/home/widgets/context_usage_ring_test.dart`(新,widget) | 三色階門檻(0.699/0.70/0.899/0.90);ratio=1.0 畫滿;`ContextUsageMenuHeader` 在 `maxTokens == null` 時顯示 `6.6k / ... Token` 且無百分比;顯示 `12.0k / 200.0k Token`、`≈`、`112%`;重建後動畫不從 0 開始(用 `@visibleForTesting` 的 displayed ratio 或注入 zero duration) |
| `test/features/chat/widgets/context_management_sheet_header_test.dart`(新,widget) | 有/無 header;header 為 shrink 時不留 gap;兩個選項 tap 回呼仍正常 |
| `test/desktop_context_menu_header_test.dart`(新,widget) | `showDesktopAnchoredMenu` 帶 header 的最小 `MaterialApp` + `Overlay` harness;header 文字可見、無 overflow;不帶 header 時行為不變;`minMenuWidth` 生效 |
| `test/features/home/services/context_usage_service_test.dart` 的 epoch/identity 子測試 | 把 `_setContextUsageIfCurrent` 的 epoch/identity 檢查抽成 pure helper,測「舊 snapshot 晚到不覆蓋新會話/新模型」;catalog null → `maxTokens == null` |
| 回歸 | `flutter analyze`;`flutter test test/home_view_model_compress_context_test.dart test/features/home/widgets/compress_context_dialog_test.dart test/chat_input_button_catalog_test.dart`(前兩者已確認存在) |
| 手動 | Windows:catalog 模型/未知模型各一;長對話;手動壓縮後 ring 歸零;自動壓縮後估算不爆;模型切換顯示 `≈`;Answer Review 開啟時的比例;手機 sheet header;把 catalog 載入延後/失敗,確認 `ensureLoaded` 後 ring 出現 |

> 測試注意:`ContextUsageService.computeContextUsage` 需要注入 `collapseVersions`;測試可用 10 行版本(依 `versionSelections` 選版本),不要 import `MessageBuilderService`(它有 `BuildContext` 依賴)。`estimateCompactedHeadTokens` 在測試中可用固定值(例如 head 長度 / 3)。

## 7. 實作順序

1. `context_usage_service.dart`:`ContextUsageSnapshot`、`estimateChatMessageTokens`、`compactTokenText`、`computeContextUsage` + 單元測試。
2. `context_usage_ring.dart`:`ContextUsageRing`、`ContextUsageMenuHeader` + widget 測試。
3. `desktop_context_menu.dart`:`header/headerHeight/minMenuWidth` + 高度/寬度 + widget 測試。
4. `chat_input_bar.dart` / `chat_input_section.dart`:prop、`childBuilder` ring、降級、`showContextMenu` header。
5. `home_view_model.dart` 新 `onMessagesChanged`;`home_page_controller.dart` notifier/refresh/epoch/listeners/hooks/dispose。
6. `context_management_sheet.dart` header + `home_page.dart` 傳參/預刷新。
7. l10n 四檔 + `flutter gen-l10n`。
8. `flutter analyze` + 目標測試 + Windows/手機手動驗證。

## 8. 驗收清單

- [ ] catalog/learned 已知窗口:ring 顯示,比例隨對話成長,串流中脈動。
- [ ] 未知窗口:按鈕顯示空 ring;選單/sheet header 顯示 `used / ... Token`,且無百分比徽章。
- [ ] 70% / 90% 門檻變色(amber / error)。
- [ ] 最後一則實測後有長 user 訊息:ring 立即反映(measured + delta,標 `≈`)。
- [ ] 自動壓縮後:估算不把 `compactBeforeIndex` 前的 head 加回來;measured 在邊界後才採用。
- [ ] 手動壓縮:新會話 ring 從 0/摘要估算開始。
- [ ] 模型/provider 切換:舊 measured 不沿用,顯示 `≈`;窗口跟著新模型。
- [ ] AI Team aggregator 開啟時,ring 用 aggregator 的窗口/measured,不會落到「未知窗口」或永久 `≈`。
- [ ] `used > max`:弧線滿、header 顯示 >100% 真實百分比。
- [ ] 點 ring → 桌面選單最上方顯示 `used / max Token` 與百分比;有任何估算成分(`completionTokens` 缺失、trailing 訊息、streaming)時有 `≈` 標記。
- [ ] 手機:ContextManagementSheet 最上方同款 header;開啟不因 header 遲到而跳高。
- [ ] 按鈕拖曳排序 / 隱藏設定不受影響(id 仍為 `'context'`)。
- [ ] `flutter analyze` 0 issue;壓縮上下文/按鈕目錄相關既有測試全綠。

## 9. 修訂對照(審查意見 → 本版落點)

| # | 審查意見 | 本版落點 |
|---|---|---|
| P0-1 | 估算忽略 `compactBeforeIndex` | §3A-3/4:split + head summary + `enableAutoCompaction` |
| P0-2 | measured 少算 trailing user / 自身回覆 | §3A-6:measured assistant 加 `completionTokens`(沒有才用 content),避免重複計 tool events;再加其後訊息 |
| P0-3 | 手動/自動壓縮混用;measured 邊界 | §1、§3G-1、§4、§5:分流 + `rawIndex >= compactBeforeIndex` |
| P0-4 | `onMessagesChanged` 不是串流高頻;位置錯 | §1、§3G-3、§3H:新增 `HomeViewModel.onMessagesChanged`;改接 `onStreamFinished`/`onConversationSwitched` |
| P1-5 | 模型切換後 measured 過期 | §3A-5:modelId/providerId 必須相符 |
| P1-6 | 選單 header 寬度/高度 | §3C:`minMenuWidth`、`headerHeight`、同步置中/翻轉 |
| P1-7 | `peek` 冷啟動 / catalog 未載入 | §3G-1.12:catalog retry;peek 只作第一版,lookup 後刷新 |
| P1-8 | refresh 競態 | §3G-1:epoch + ids + `_disposed` |
| P1-9 | Answer Review 高估 | §5:註記;精準扣除列範圍外 |
| P2-10 | 估算函式 private / 低估注入 | §3A-1、§3A-7:共用 estimator + 下界說明 |
| P2-11 | ratio clamp 隱藏 >100% | §2、§5:`rawRatio`/`displayPercent` |
| P2-12 | ring 重建從 0 閃 | §3B-1:stateful `_displayedRatio` |
| P2-13 | snapshot 無 `==` | §2:`==/hashCode` |
| P2-14 | 手機 header gap/跳高 | §3B-2、§3I:shrink + 預刷新 |
| P2-15 | `truncateIndex == length` 邊界 | §3A-2:`<=` + sublist;不要抄 ChatTurnService 的 `<` |
| P2-16 | 桌面 menu 測試 harness | §6:`MaterialApp` + `Overlay` |
| 其他 | `providerId (config.id)`、`collapseVersions`、`formatTokens`、overflow 範圍 | §3A/§3G/§3E/§6 |
| 其他 | AI Team effective model、listener 時機、sheet 16px gap、anchored menu 轉參、測試路徑 | §3C/§3D/§3G/§6 |
