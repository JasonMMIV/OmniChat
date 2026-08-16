# Session B 導入計畫：Claude 提示快取（Prompt Caching）

> 對應 kelivo v1.1.13（`491789f2`）、v1.1.15（`073a3ded` 桌面 toggle）、v1.1.16（`53b051f9` TTL）的 Claude Prompt Caching 系列；附帶補強 DeepSeek Claude 相容 provider 偵測（`b29abdb7` 的 provider 判斷部分，v1.1.16）。
> 預計版本號：`v1.18.1`（pubspec `1.18.1+N`；installer.iss 1.18.1）。

---

## 目標項目

| # | 功能 | 上游 commit | 現況 |
|---|---|---|---|
| B1 | `ProviderConfig` 加 `claudePromptCachingEnabled` / `claudePromptCachingTtl` | `491789f2` + `53b051f9` | ❌ 缺失（全 codebase 無 `cache_control`） |
| B2 | Claude API 與 OpenRouter body 注入 `cache_control` | `491789f2` + `53b051f9` | ❌ 缺失 |
| B3 | Mobile provider detail + Desktop providers pane 設定 UI | `491789f2`（mobile）+ `073a3ded`/`53b051f9`（desktop + TTL） | ❌ 缺失 |
| B4 | DeepSeek Claude 相容 provider 偵測補強（`_isDeepSeekClaudeCompatible` 檢查 baseUrl/id/name） | `b29abdb7` | 🟡 目前只認 modelId 含 deepseek |

---

## B1. ProviderConfig 欄位（`lib/core/providers/settings_provider.dart`）

### 上游實作摘要
- 新增欄位：`claudePromptCachingEnabled`（`bool?`，預設 `false`）、`claudePromptCachingTtl`（`String?`，預設 `'5m'`）
- 新增 static：
  - `claudePromptCachingTtl5m = '5m'`、`claudePromptCachingTtl1h = '1h'`
  - `resolveClaudePromptCachingTtl(String?)`（非法值回退 `5m`）
  - `claudePromptCacheControl(String? ttl)` → `{'type': 'ephemeral', if 1h: 'ttl': '1h'}`
- `copyWith` / `toJson` / `fromJson` / `defaultsFor`（各 kind 分支）全部接上

### OmniChat 實作步驟
1. 在 `ProviderConfig` 類別中加入上述欄位與 static helper（放 `balanceResultKey` 附近）
2. `copyWith`、`toJson`、`fromJson` 三處接線（注意 OmniChat 用的是 `balanceResultKey` 而非上游的 `balanceResultPath`——以 OmniChat 現有欄位命名風格為準）
3. `defaultsFor` 各分支（openai/google/claude/neuralwatt）加 `claudePromptCachingEnabled: false`
4. **測試** `test/settings_provider_claude_prompt_caching_test.dart`（NEW）：`resolveClaudePromptCachingTtl` 正常值/非法值回退／`claudePromptCacheControl` 5m 無 ttl、1h 帶 ttl／fromJson 預設 false+5m／copyWith 保留、toJson round-trip

---

## B2. Body 注入（`lib/core/services/api/chat_api_service.dart`）

### 上游實作摘要
- Claude 路徑（`claude_official.dart` `_sendClaudeStream`）：body 加
  ```dart
  if (config.claudePromptCachingEnabled == true)
    'cache_control': ProviderConfig.claudePromptCacheControl(config.claudePromptCachingTtl),
  ```
- OpenAI 路徑（`openai_common.dart`）：新增 `_applyOpenRouterClaudePromptCaching(body, {config, upstreamModelId})`——僅當 `claudePromptCachingEnabled == true && isOpenRouterProvider(config) && (modelId 含 claude 或 anthropic/)` 時加 `body['cache_control'] = claudePromptCacheControl(...)`；在 OpenAI stream 建構處呼叫

### OmniChat 實作步驟
1. **Claude 路徑**：`_sendClaudeStream` body map（~L5558 附近，`'system'` 之後）加 `cache_control` 條件欄位
2. **OpenRouter 路徑**：
   - 新增 static `_applyOpenRouterClaudePromptCaching(Map body, {required ProviderConfig config, required String upstreamModelId})` + `_isClaudeModelId` helper（含 `claude` 或 `anthropic/`）——比照上游邏輯
   - 掛接點：OpenAI chat-completions body 建構處（主 body ~L2055 附近，**Grok `search_parameters` 注入點之前**）；比照 `_removeKimiK3SamplingParams` 的 5 處掛接模式，至少掛主 body（body2 重試沿用 body 不需重掛）
   - 確認 `BuiltInToolsHelper.isOpenRouterProvider` 已在 Session A 加入（B2 依賴 A3）；若 Session A 未完成，本 session 需先補該 helper
3. **測試**：`test/claude_dynamic_web_search_test.dart` 風格（HttpServer）加 2 case：
   - Claude provider 開啟 caching → body 含 `cache_control: {type: ephemeral}`；1h → 含 `ttl: '1h'`；關閉 → 無
   - OpenRouter（chat-completions、Claude 模型）開啟 → body 含 cache_control；非 Claude 模型 → 無

---

## B3. 設定 UI

### B3a. Mobile（`lib/features/provider/pages/provider_detail_page.dart`）
1. State：`_claudePromptCachingEnabled`（`bool`）+ `_claudePromptCachingTtl`（`String`，init 用 `resolveClaudePromptCachingTtl`）；`initState` 讀取 `_cfg.*`
2. 新增 `_supportsClaudePromptCaching` 判斷（上游邏輯：kind == claude，或 OpenRouter + Claude 模型——依 OmniChat 的 `ProviderConfig.classify` 實作）
3. 在既有 provider 選項區（`_save()` 之前）插入：
   - toggle row（`IosCardPress`/既有 row 元件風格）標題 `providerDetailPageClaudePromptCachingTitle`、help 用既有 help 按鈕慣例
   - TTL segmented control（僅 caching 開啟時顯示，上游用 `_PromptCachingTtlSegmentedControl`，OmniChat 可用既有 segmented/toggle 元件）
4. `_save()`：`claudePromptCachingEnabled: _supportsClaudePromptCaching ? _claudePromptCachingEnabled : false`（同 TTL，關閉時回退 5m）

### B3b. Desktop（`lib/desktop/desktop_settings_page.dart` 的 `_DesktopProviderDetailPane`）
> 上游在 `lib/desktop/setting/providers_pane.dart`（獨立檔），OmniChat 的 desktop provider detail 在 `desktop_settings_page.dart` 內（`_DesktopProviderDetailPaneState`，~L1253 起）——**插入位置以 OmniChat 既有 proxy/balance 等選項區為準**。
1. State 加 `_claudePromptCachingEnabled`/`_claudePromptCachingTtl`
2. 在 provider 選項區插入 toggle + TTL dropdown（`DesktopSelectDropdown<String>`，options 5m/1h，`AnimatedCrossFade` 顯示 TTL 行——移植上游 `53b051f9` 的 desktop diff）
3. 儲存時 `copyWith(claudePromptCachingEnabled: ..., claudePromptCachingTtl: ...)`

### B3c. l10n（7 keys × 4 語系，譯文採上游）
- `providerDetailPageClaudePromptCachingTitle`
- `providerDetailPageClaudePromptCachingHelp`
- `providerDetailPageClaudePromptCachingTtlTitle`
- `providerDetailPageClaudePromptCachingTtlHelp`
- `providerDetailPageClaudePromptCachingTtl5m`
- `providerDetailPageClaudePromptCachingTtl1h`
- （`073a3ded` 另有 desktop 用的 title/help 變體——實際以該 commit 的 arb diff 為準補齊）
- 執行 `flutter gen-l10n`

---

## B4. DeepSeek Claude 相容 provider 偵測補強

### 現況
`_claudeThinkingConfig` / `_claudeOutputConfig` 只檢查 `modelId.toLowerCase().contains('deepseek')`——自訂名稱的 DeepSeek-Anthropic provider（baseUrl `api.deepseek.com/anthropic`、模型叫 `deepseek-chat` 以外名稱）不會走 Claude 相容 thinking。

### 實作步驟（`chat_api_service.dart`）
1. 新增 static `_isDeepSeekClaudeCompatible(String modelId, {ProviderConfig? config})`：
   - modelId 含 deepseek → true
   - config 非空且 baseUrl 含 `api.deepseek.com`、或 id/name 含 deepseek → true
2. `_claudeThinkingConfig` / `_claudeOutputConfig` 的 deepseek 判斷改用此函式（保持 `modelId`-only 行為相容，config 為選填）
3. **測試**：`test/claude_dynamic_web_search_test.dart` 或 `test/reasoning_budget_api_test.dart` 加 case：baseUrl `https://api.deepseek.com/anthropic`、modelId 不含 deepseek → thinking `{type: enabled}`、output_config effort 正確

---

## 驗證與收尾（Session B 通用）

```bash
flutter gen-l10n
flutter test            # 全量（預期 +10 左右）
flutter analyze         # 修改檔案無 new errors/warnings
```

- 版本號：`pubspec.yaml` → `1.18.1+N`；`installer.iss` → 1.18.1
- `CHANGES_LOG.md` 新增 v1.18.1 條目（比照既有格式）
- commit（若要求）：`feat(port): kelivo v1.1.13–v1.1.16 — Claude prompt caching (Anthropic + OpenRouter, TTL) + DeepSeek Claude-compatible provider detection`

---

## 風險與注意

- **`cache_control` 位置**：上游把 `cache_control` 放在 Claude request body **頂層**（非 content block 內）——這是上游既定的做法，先照移植；若實測 Anthropic 官方 API 不接受頂層 cache_control，再評估改掛 system 區塊（需另開 issue 記錄）
- **OpenRouter 判定**：B2 依賴 `BuiltInToolsHelper.isOpenRouterProvider`（Session A 的 A3 產出）。若 Session A 未先行，本 session 第一件事是補這個 helper（含測試）
- **`_supportsClaudePromptCaching`**：OmniChat 的 `ProviderConfig.classify` 與上游 `ProviderKind` 一致，但 OpenRouter 是 openai kind——判斷式要「claude kind 全支援」＋「openai kind 且 isOpenRouterProvider 且模型含 claude」兩段式
- **Desktop 檔案位置**：上游 desktop UI 在獨立 `providers_pane.dart`，OmniChat 在巨型 `desktop_settings_page.dart` 內——編輯前先用 `grep` 定位 `_DesktopProviderDetailPaneState` 的 proxy/balance 區塊，確認既有 row 元件慣例（`row()`/`_TactileRow`/`DesktopSelectDropdown`）
