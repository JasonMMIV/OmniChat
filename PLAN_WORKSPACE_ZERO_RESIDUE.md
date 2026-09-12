# 修改計畫：工作區零暫存殘留（Zero Workspace Residue）

> **版本**：v1.1（2026-09-12）
> **狀態**：✅ 已實作（Phase 1 + Phase 2.2 + Phase 3 文件同步完成；Phase 2.3 備案未啟用）
> **決策依據**：AnyBuff 調查（2026-09-12，本機 `C:\Users\w2bn1\Documents\GitHub\AnyBuff`）＋使用者裁示——工作區不得殘留任何暫存/隱藏檔案。
> **驗收定位**：手冊 §7 標準（`flutter analyze --no-pub` 0 errors、`flutter test` 全綠、Windows + Android 手動 smoke）。

---

## 0. 背景與目標

### 問題

OmniChat 工作區目前有兩類殘留：

| 殘留 | 來源 | 位置 |
|:---|:---|:---|
| `.omnichat/tool_outputs/*.txt` | P1-4 長輸出外部化（`tool_output_externalizer.dart`） | `{workspace}/.omnichat/tool_outputs/`，>32,768 字元的工具結果落盤（20 檔/7 天 retention，資料夾永不自清） |
| `{file}.omnichat-tmp-{token}` / `{file}.omnichat-backup-{token}` | `FileToolService._atomicReplace`（**實為 file_edit / file_patch**；file_write 為直寫，2026-09-12 審查更正——見 §8 F5） | 與目標檔同層；正常瞬時存在，crash 後殘留；Windows 路徑每筆寫入額外產生 backup 副檔 |

### AnyBuff 調查結論（做法對照）

1. **AnyBuff 不落盤任何工具輸出**——所有工具在記憶體內自行設上限，並教模型「重新查詢源頭」：
   - `read_files`：預設視窗化（每檔 2,000 行 / 50K chars；每次呼叫 100K chars / 20K tokens），續讀指引 `offset=N`；>10MB 拒讀並導向 code_search/glob（`common/src/util/file-read-limits.ts`、`sdk/src/tools/read-files.ts`）。
   - `run_terminal_command`：`BoundedOutputBuffer` 50K chars、50/50 head/tail、ANSI-color 安全（`sdk/src/tools/run-terminal-command.ts`）。
   - `code_search` 20K、`read_url` 20K（下載上限 2MB）、host-core `bash-command` 60K。
   - 設計原則：**源頭即事實，模型以 grep / offset-視窗外科式重查**；讀取無副作用、重跑免費，截斷不損失可恢復性。
2. **AnyBuff 的 agent 檔案編輯工具直寫**（`change-file.ts` 用 `fs.writeFile`，無暫存）——因為它只碰 git repo，復原責任在使用者 git（與 OmniChat 廢除 P1-5 快照的同一邏輯）。
3. **AnyBuff 自身的原子寫入標準（ADR-13 / §9.5）**用於 app 狀態檔：同目錄唯一 temp → fsync → rename-replace（**不預刪目標**）→ EPERM/EACCES/EBUSY 有界退避重試（AV/索引器鎖）→ 失敗時**舊檔保留**。單檔路徑**沒有 backup 副檔**（Node `fs.rename` 於 Windows = `MoveFileExW(REPLACE_EXISTING)`，NTFS 上原子）；temp 於同一呼叫內 `finally` 清除。temp 全部位於 app userData，不進專案。

### 目標

1. 工作區不再產生 `.omnichat/`（tool_outputs）。
2. 工作區不再產生 `.omnichat-backup-*` 副檔；暫存檔僅存在於單次寫入的瞬時窗口（無 backup 中斷窗、命名 `{file}.{micros}_{hash}.tmp`），crash 殘留面積最小化。
3. LLM 契約不退化：>32KB 工具結果仍收到 head/tail + 重新查詢指引（與現行傳輸後備截斷同形狀）；`file_read` 既有 offset/limit 分頁契約不變。

### 明確不做（結案記錄，防重提）

- **啟動殘留清掃器（原 Phase 3）**：不實作。歷史殘留（舊 `.omnichat/`、crash 孤兒暫存檔）由使用者手動清理，清理指引見 §5。理由：啟動期對使用者資料夾做刪除式掃描風險與複雜度不成比例，且殘留是一次性的（新代碼不再製造）。
- **agent 工具直寫（AnyBuff `change-file.ts` 模式）**：**部分不採（2026-09-12 更正）**。原敘述「不採直寫」與實作不符——`file_write` / `file_append` 一直都是直寫。裁示**維持直寫**（§8 F5 決定 (b)）：讀-改-寫工具（`file_edit` / `file_patch`）走 ADR-13 原子替換——其舊內容在記憶體內被改寫，撕裂即真損失且無副本；`file_write` / `file_append` 為直寫，**已接受風險**是 crash 撕裂檔案，復原責任交使用者自己的 git。**未採的替代方案**：(a) `file_write` 全面原子化——每次寫入（含新檔）都多一個瞬時 `.tmp`，且 replace 會丟失硬連結／Windows ADS（Zone.Identifier）／自訂 ACL，鎖檔時還要多付 ~1.5s 退避重試延遲才報錯；(c) 僅覆寫既有檔時原子化——保護面相近但兩條路徑需各自文件化，複雜度換來的好處有限。
- **`.omnichat/snapshots/`**：依手冊 §3.14 §6 維持「使用者檔案、保留不動」。

---

## Phase 1 — 移除 P1-4 外部化，改為記憶體上限（消滅 `.omnichat/tool_outputs/`）

| # | 動作 | 檔案 |
|:--|:---|:---|
| 1.1 | 新增純 Dart 工具 `ToolResultCaps.cap()`（AnyBuff `BoundedOutputBuffer` 的 Dart 對應）：>32,768 字元 → 50/50 head/tail + `[... tool output truncated — N KB total ...]` + **依工具家族的重新查詢指引**（file_* 工具 → 「以 `file_read` offset 續讀 / `file_search` 定位」；`search_web` / MCP → 「縮小參數重跑、降低 max_results」；其他 → 通用指引） | 新檔 `lib/core/services/tools/tool_result_caps.dart` |
| 1.2 | 三個呼叫點改接 `ToolResultCaps`（file_* 工具、`search_web`、全部 MCP 工具）；`toolCallId` 參數鏈保留（tool event upsert 仍需要它，僅不再用於檔名） | `tool_handler_service.dart` L573 / L669 / L697 |
| 1.3 | 刪除外部化器及其測試 | 刪 `lib/core/services/tools/tool_output_externalizer.dart`、`test/tool_output_externalizer_test.dart` |
| 1.4 | 傳輸層後備截斷 `_truncateToolResultText` 改為委派同一個 caps 函式（單一事實來源；輸出形狀不變，對 `sendMessageStream` 五處套用點零改動） | `chat_api_service.dart` |
| 1.5 | 新測試：caps 形狀、各工具家族指引文字、32K 邊界 | 新 `test/tool_result_caps_test.dart` |

**附帶修復的既有潛在缺陷**：現行重放（§3.11）會把「預覽 + 讀取 `.omnichat/tool_outputs/xxx.txt`」的指引原文送回模型——檔案 7 天後已被 sweep，指引指向幽靈路徑。改記憶體上限後此失效模式整個消失。

**能力取捨（接受）**：>32KB 的 MCP / search 結果失去「7 天內可分頁讀回」加值，中段不再保留。與 AnyBuff 全工具家族的既有取捨一致；相對今天的傳輸後備路徑是零退化。

## Phase 2 — 原子寫入簡化為 AnyBuff ADR-13（消滅 `-backup-` 副檔與 target 消失窗）

| # | 動作 | 檔案 |
|:--|:---|:---|
| 2.1 | **Windows rename 語意 spike**（決策閘）：實測 Dart `File.rename` 在 Windows 對「已存在目標」的行為（AnyBuff 的依據是 Node `fs.rename` = `MoveFileExW(REPLACE_EXISTING)`；Dart 不保證相同，須以短 spike 驗證） | 暫時性 spike + 結論筆記 |
| 2.2 | **閘通過**：`_atomicReplace` 改為 AnyBuff §9.5——同目錄唯一 temp（`{file}.{pid}.{ts}.tmp`）→ 寫入 → fsync → rename-replace → EPERM/EACCES/EBUSY 有界退避重試 → `finally` 清 temp。**移除 backup 副檔與「target 先改名走」的中斷窗**；失敗時舊檔原樣保留 | `file_tool_service.dart` `_atomicReplace` |
| 2.3 | **閘不通過**（Dart rename 不覆蓋既有檔）：退而求其次——temp 與 backup 集中到單一隱藏的 `{workspace}/.omnichat/tmp/`（同磁碟分割、原子性不變、平時為空）；Windows 屬性加 Hidden。此為唯一允許 `.omnichat/` 存在的情境，並於手冊註記 | 同上 |
| 2.4 | 測試：replace 既有檔成功、無 backup 殘留、temp 於 finally 清除、失敗時舊檔保留、EPERM 重試路徑 | `file_tool_service_test.dart` |

> 命名說明：採用 2.2 時暫存檔名為 `{file}.{pid}.{ts}.tmp`（AnyBuff §9.5 形狀），不再帶 `omnichat-` 字樣；`.tmp` 後綴對使用者/同步引擎/索引器的干擾最小，且 `finally` 保證同呼叫清除。

## Phase 3 — 文件同步與驗收

| # | 動作 | 檔案 |
|:--|:---|:---|
| 3.1 | **手冊**：§3.14 §5 改寫（外部化移除、記憶體上限政策、ADR-13 原子寫入契約、工作區零殘留承諾）；§4 ADR 表新增一行「工具輸出不留盤（比照 AnyBuff）」 | `OmniChat 專案開發與維護手冊.md` |
| 3.2 | **IMPORT_PLAN_COWORK.md**：P1-4 進度列標記「⛔ 已回撤（比照 AnyBuff 改記憶體上限）」＋一行理由；§6 同步風險表 `tool_outputs` 列更新 | `IMPORT_PLAN_COWORK.md` |
| 3.3 | **驗收**（手冊 §7 標準）：`flutter analyze --no-pub` 0 errors；`flutter test` 全綠；Windows + Android 手動 smoke——開工作區跑一次大輸出工具呼叫（`file_read` 大檔 / `search_web`）與一次 `file_edit`，確認工作區**零新增檔案/資料夾**；crash 模擬（殺進程）後僅可能餘單一 `.tmp`、目標檔完好 | — |

---

## 風險與對策

| 風險 | 對策 |
|:---|:---|
| MCP 不可重推導的結果失去中段（>32KB） | 與 AnyBuff 既有取捨一致；上限維持 32K、輸出形狀與現行後備相同——相對後備路徑零退化 |
| Windows rename 語意不確定 | Phase 2.1 決策閘；兩條路徑（2.2 / 2.3）皆已備妥 |
| 舊對話重放含指向已刪 `tool_outputs` 的指引 | 模型讀檔會得到明確的 file-not-found 結構化錯誤（可自行重查），非静默失敗；且新代碼不再產生此類指引 |
| 歷史殘留（舊 `.omnichat/`、crash 孤兒暫存） | 不建清掃器（見 §0「不做」）；提供手動清理指引（§5） |

---

## 5. 歷史殘留手動清理指引（給使用者 / 維護者）

1. **`.omnichat/` 資料夾**：可整個刪除。新代碼不再於工作區建立它；`tool_outputs/` 內容皆為可再生成的工具輸出副本，無使用者資料。若資料夾內有 `snapshots/`（舊 P1-5 殘留），同樣可刪——手冊稱「保留不動」僅指 App 不主動碰它。
2. **`*.omnichat-tmp-*` / `*.omnichat-backup-*` 孤兒檔**：僅在寫入中途 crash 才會出現，皆為惰性殘留。安全清理法：確認同名目標檔存在且內容正確 → 直接刪除孤兒檔；若目標檔遺失，把對應 `-backup-` 檔改名回目標檔名即可復原舊內容。
3. **OneDrive / Dropbox 同步資料夾注意**：刪除殘留前後可能觸發同步事件；`tool_outputs/` 若已被同步到其他裝置，需在各裝置端清理。

---

## 7. 實作記錄（2026-09-12；同日複核修訂見 §8）

| 項目 | 結果 |
|:---|:---|
| Phase 1.1 | `lib/core/services/tools/tool_result_caps.dart` 新增（`ToolResultCaps.cap` / `capBare`，head/tail 50/50 + 依家族指引） |
| Phase 1.2 | `tool_handler_service.dart` 三呼叫點改接 `ToolResultCaps.cap`；`toolCallId` 鏈保留 |
| Phase 1.3 | `tool_output_externalizer.dart` + `test/tool_output_externalizer_test.dart` 已刪除 |
| Phase 1.4 | `ChatApiService._truncateToolResultText` 委派 `ToolResultCaps.capBare`（單一截斷路徑） |
| Phase 1.5 | `test/tool_result_caps_test.dart` 新增，8 測試全綠（含「永不落盤」驗證） |
| Phase 2.1 spike | `tool/windows_rename_spike.dart` 實測：Dart `File.rename` 於 Windows **REPLACE** 既有目標（MoveFileExW 語意）→ 採 2.2 |
| Phase 2.2 | `_atomicReplace` 改 ADR-13 形狀：唯一 temp（`{file}.{ts}.{hash}.tmp`）+ flush + rename-replace + EPERM/EACCES/EBUSY（5/32/33/1/13/16）有界退避（6 次、50ms 起 2×）+ 全退出路徑清 temp；backup 副檔與 target 消失窗已移除 |
| Phase 2.4 | `test/file_tool_service_test.dart` 新增 zero-residue 組（4 測試）：replace/edit/重複寫入無殘留、無 `.tmp`、無 `.omnichat*`；63/63 全綠 |
| 驗證 | `flutter analyze --no-pub` 0 errors（新檔 0 issues；既有 info/warning 不增量）；`tool_result_caps` + `file_tool_service` + `tool_handler_mcp_failure` + `workspace_tools_toggle` 測試全綠 |
| Phase 3 | 手冊 §3.14 §5 改寫＋§4 ADR 表新增「工具輸出不留盤」＋版本 v1.22.0；IMPORT_PLAN P1-4 標 ⛔回撤、已結案清單新增條目、同步風險表更新 |
| 待辦 | Android 手動 smoke（開工作區跑大輸出工具呼叫 + file_edit，確認零新增檔案）待下一次 Android 建置時執行 |

---

## 8. 審查修訂（2026-09-12，同日複核）

> 觸發：實作完成後逐行複核（見 `~/.commandcode/plans/workspace-zero-residue-review.md`）。結論：**主體設計正確**（外部化確實完全移除、ADR-13 原子寫入真落地），但四個缺陷需修，另發現一個待決問題。

| # | 缺陷 | 根因（被推翻的假設） | 修訂 |
|:--|:--|:--|:--|
| **F1** | `ToolResultCaps.cap` 輸出恆為 32,898~32,951 字元（32,768 + 標記 + 指引）→ 傳輸層後備**每次**重截，把中段的標記與指引整段切掉：**家族指引零到達**，且標記的 KB 報成截斷後大小 | 計畫 1.4 假設「cap 輸出 ≤ 32,768（與後備同形狀）」，但實作把標記與指引**加在**預算之上 | `cap`/`capBare` 共用 `_truncate`，內容預算 = 32768 − 分隔 − block（標記±指引）→ 輸出**恰為 32768**，後備成為 no-op；另加 `truncationMarkerPrefix` 幂等判斷（容許 ≤256 字元的舊版超標殘留，使既有 Hive 內容重放也不再被切）。測試：邊界改 `lessThanOrEqualTo`、新增幂等／指引存活／真實 KB／防繞道／舊版形狀 5 條 |
| **F2** | `_atomicReplace` 的 temp 寫入在 try/finally 之外 → 寫入失敗（ENOSPC／AV 鎖）在使用者工作區留半截 `.tmp`；迴圈後的「防禦性清理」為**不可達程式碼** | 「所有退出路徑清 temp」在實作時只覆蓋了 rename 之後的路徑 | `write + rename 迴圈` 全部包進 `try`，`finally` 統一 `exists()→delete`；移除不可達區塊；temp 名收斂單一時間戳（`{file}.{micros}_{hash}.tmp`） |
| **F3** | 「a failed write preserves the old file」測試**實際斷言寫入成功**（名實不符）；計畫 2.4 承諾的失敗路徑完全無測試。且原 zero-residue 測試用 `file_write`——**根本不經過** `_atomicReplace` | 誤以為 `file_write` 走原子路徑（F5）；測試以「無殘留」為滿足，未製造失敗 | 加 `@visibleForTesting` seam `debugWriteTemp` / `debugRename`（production null）；3 條真測試（EPERM 一次後成功 attempts=2、重試耗盡 attempts=6 且舊檔完好、temp 寫入失敗零殘留）；既有 3 條 zero-residue 測試改用 `file_edit`，才真正覆蓋原子路徑 |
| **F4** | 文件漂移：手冊 4 處與程式註解 4 處仍描述已刪除的 `ToolOutputExternalizer`；「單一截斷路徑」敘述與實際三種形狀不符 | Phase 3.1 只改了手冊 §3.14 §5 與 §4 | 手冊 §6.3／§7.1×2／§8 更新；§3.14 §5 補「預算契約／三種截斷形狀／原子寫入覆蓋範圍與已接受風險」；`chat_stream_chunk.dart`／`tool_handler_service.dart`／`agent_orchestrator.dart`／`stream_controller.dart` 的 `toolCallId` 說明改為審批事件 key；手冊版本標「未發佈」 |
| **F5** | **已決 (b)**：`file_write` / `file_append` 為**直寫**（`File.writeAsBytes`，截斷覆寫），未走 `_atomicReplace` → crash 可撕裂使用者檔案 | 計畫 §0 的殘留表把 `_atomicReplace` 的覆蓋範圍寫成「file_write / file_edit / file_patch」，實作從未如此（僅 edit/patch 走讀-改-寫路徑）；§0「不採工具面直寫」的敘述因此與實作矛盾 | **2026-09-12 裁示：維持直寫（b），修訂敘述而非行為**。§0「明確不做」已更正並記錄未採的 (a)/(c) 與理由；`file_tool_service.dart` 的 `_write` 加註此行意圖；手冊 §3.14 §5 覆蓋範圍與 §4 ADR 列同步。撕裂風險為**已接受風險**（復原交使用者 git），與 P1-5 快照回撤同一邏輯 |

**未採用（防重提）**：提高 32K 預算（違反既有工具結果預算契約，且 16K/24K 讀取上限以其為設計依據）；移除 handler 層 cap 只留傳輸層（傳輸層拿不到工具名 → 無法產生家族指引）。

**驗證（2026-09-12 複核後）**：`flutter analyze --no-pub` 0 errors（`tool_result_caps.dart`／`file_tool_service.dart`／兩測試檔 0 issues）；`tool_result_caps_test`（12）＋ `file_tool_service_test`（65，含新 3 條失敗路徑）= **77 全綠**。

**仍待手動 smoke（兩項）**：① F1 端到端——觸發 >32KB 工具結果（大樹 `file_search` 或大回應 MCP 工具），檢查實際送給模型的 payload **同時含家族指引與真實 KB**（wire capture／log），這是 F1 唯一的端到端證明；② Android 手動 smoke（原 §7 待辦）。
