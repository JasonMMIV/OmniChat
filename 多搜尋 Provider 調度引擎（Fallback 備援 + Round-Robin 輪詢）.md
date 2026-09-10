# 多搜尋 Provider 調度引擎（Fallback 備援 + Round-Robin 輪詢）

## 需求

### 1. 資料模型與設定層（SettingsProvider）

- 新增有序多選：`search_selected_providers_v1`（`List<String>` service ids，**選中的集合**；優先順序 = 服務清單順序）；新增模式 `search_dispatch_mode_v1`（`fallback` | `round_robin`），預設 `fallback`
- 新 enum `SearchDispatchMode` 定義於新的純 Dart 檔（仿 `WorkspaceConfig` 模式），非 `_localOnlyKeys` → 隨既有備份機制跨裝置同步
- 載入時遷移：無新 key 時由舊 `search_selected_v1`（單一 int）推導為 `[services[idx].id]`，零動作升級
- `setSearchServices`（刪除/重排）時自動修剪/維護 selected ids 不懸空；設定 UI 防止選中集合為空（至少保留一家，比照現有「至少一個服務」守衛）
- `copyWith` / `updateSettings` 加入兩個新欄位；舊 `searchServiceSelected` getter 保留為「首位選中者的 index」之衍生值，僅供未改動的呼叫面過渡

### 2. 調度引擎（新檔 `lib/core/services/search/search_dispatch.dart`，純 Dart 可測）

- `orderCandidates()`：依模式產生嘗試順序——
  - **fallback**：選中者按清單順序，首位為主要 provider
  - **round_robin**：記憶體游標輪轉起始點（app 生命週期內持續，重啟重置），每次搜尋後推進
- **429 冷卻**：`Map<String, DateTime>` 記憶體冷卻表（60 秒）；429 的 provider 在冷卻期間被跳過；若所有候選都在冷卻則照常使用（避免全滅）
- **失敗分類器**：輕量 regex 分類（`429|rate.?limit|too many requests` → rateLimit 觸發冷卻；`timeout|timed out`；其餘 generic）——三類皆觸發換下一家，不需改動 24 個 provider 的丟例外字串格式
- 全部候選失敗 → 回傳聚合錯誤 JSON（列出各家嘗試與失敗原因），維持現有 `{'error': ...}` 形狀

### 3. 執行整合（`search_tool_service.dart`）

- `executeSearch(query, settings)` 簽名**不變**（3 個呼叫點：tool_handler_service、live_tools 語音、chat_turn_service 全自動受益，零改動）
- 內部改走調度引擎逐一嘗試；成功即回傳
- 新增 `executeSearchWithTrace()` 回傳 `{json, providerName, fallbackFromName}`；`executeSearch` 委派並只取 `.json`——**給 LLM 的 JSON 內容完全不變**
- 單次搜尋最壞延遲 = 候選數 × timeout（每家仍受 `searchCommonOptions.timeout` 約束），不做嘗試次數上限

### 4. 工具卡片顯示（UI-only，不進 LLM context）

- `tool_handler_service` 的 `search_web` 分支改用 trace 版本；`ChatService.upsertToolEvent` 增加可選 `extras` 參數，把 `searchProvider` / `searchFallbackFrom` 寫入 tool event 紀錄的獨立欄位（跨輪重放只讀 content，自動不受影響）
- `chat_message_widget` 的 search_web 工具卡片標題區顯示實際 provider 名稱徽章；發生 fallback 時顯示「已從 X 切換至 Y」提示（l10n）

### 5. 四個 UI 選擇面改多選

- **設定面**（mobile `search_services_page` + desktop `search_services_pane`）：每列加核取方塊（選中集合）；新增「調度模式」segmented control（備援/輪詢 + 副標說明）；desktop 既有拖曳排序保留（= 優先順序）；mobile 頁新增拖曳排序（ReorderableListView，決定主要 provider）
- **快速面**（desktop `search_provider_popover` + mobile `search_settings_sheet`）：點一下 = 設為優先首位（服務清單移至頂端）＋選中＋啟用搜尋；已選多家時顯示順序編號徽章（1,2,3…）
- **chat 輸入列搜尋按鈕**（`chat_input_bar`）：顯示首位 provider 品牌圖示 + 「+N」疊加徽章（多選時）

### 6. l10n ×4 語系（en / zh / zh_Hans / zh_Hant）

- 模式名稱與副標（備援、輪詢）、工具卡片 fallback 提示（含 `{from}`/`{to}` placeholder）

### 7. 測試與文件

- 新增 `test/core/services/search/search_dispatch_test.dart`：fallback 順序、失敗換手、429 冷卻跳過、輪詢旋轉、全失敗聚合錯誤、空選集、單家（=現行為）回歸
- 既有測試保持綠燈（`live_tools_test`、`chat_turn_service`、各 provider 測試）
- 更新《OmniChat 專案開發與維護手冊》§3.4（架構級變更，依文件維護指引）

## Notes

- **LLM 可見 JSON 零變更**：provider 資訊只存在 tool event 的 extras 欄位與 UI，不進對話 context、不進跨輪重放、不進備份匯出的文字內容（僅 metadata）
- 冷卻與輪詢游標皆為記憶體狀態（重啟重置），符合既有「ephemeral 連線測試結果」的模式
- 舊行為相容：只選一家且模式為 fallback 時，行為與現版完全一致
- 供應商原生搜尋（Gemini/Claude/OpenAI built-in）與本機制互斥的現有邏輯不動
- AI Team 提案階段的搜尋自動受益（同一匯流點）
- 空結果（非例外）不觸發 fallback，避免雙倍成本；可作為未來選項

## 相關檔案

- `lib/core/services/search/search_tool_service.dart`（調度整合 + trace）
- `lib/core/services/search/search_dispatch.dart`（新：引擎 + enum + 分類器 + 冷卻表）
- `lib/core/providers/settings_provider.dart`（新 keys、遷移、setter、copyWith）
- `lib/core/services/chat/chat_service.dart`（upsertToolEvent extras）
- `lib/features/home/services/tool_handler_service.dart`（search_web 分支改用 trace）
- `lib/features/chat/widgets/chat_message_widget.dart`（工具卡片 provider 徽章）
- `lib/features/search/pages/search_services_page.dart`、`lib/desktop/setting/search_services_pane.dart`（多選 + 模式切換 + mobile 排序）
- `lib/desktop/search_provider_popover.dart`、`lib/features/search/widgets/search_settings_sheet.dart`（點選=設為首位）
- `lib/features/home/widgets/chat_input_bar.dart`（品牌圖示 + "+N" 徽章）
- `lib/l10n/app_en.arb` / `app_zh.arb` / `app_zh_Hans.arb` / `app_zh_Hant.arb`（+ 產生的 localizations 檔）
- `test/core/services/search/search_dispatch_test.dart`（新）
- `OmniChat 專案開發與維護手冊.md`（§3.4 更新）
