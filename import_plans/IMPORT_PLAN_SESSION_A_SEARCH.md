# Session A 導入計畫：搜尋家族（Search Family）

> 對應 kelivo v1.1.13 / v1.1.16 / v1.1.17 的搜尋相關功能。
> 移植基準：以 v1.17.7（Querit 移植）確立的既有模式為範本（service + registry + mobile/desktop UI + brand icon + l10n + 測試）。
> 預計版本號：`v1.18.0`（pubspec `1.18.0+N`；installer.iss `OmniChat_windows_v1.18.0_setup`）。

---

## 目標項目

| # | 功能 | 上游 commit | 現況 |
|---|---|---|---|
| A1 | Serper 搜尋服務商 | `dcf4ca63` | ❌ 完全缺失 |
| A2 | Grok 搜尋服務商（xAI Responses API） | `67eb8bce` + `9fec9444` + `5e62d5d9` | ❌ 完全缺失（註：OmniChat 已有的「Grok 模型內建搜尋」是不同功能，勿混淆） |
| A3 | OpenRouter 內建搜尋 | `9b579073` | ❌ 缺失 |
| A4 | DeepSeek 內建搜尋（Claude 格式） | `d2b909a3`（僅取 OmniChat 缺口部分） | 🟡 核心注入已有，缺 `isDeepSeekProvider` helper 與 UI 白名單 |
| A5 | Claude 4.8 / Fable 5 動態搜尋白名單 | `316c343a`（僅白名單部分） | 🟡 缺 2 個 model id |

---

## A1. Serper 搜尋服務商

### 上游實作（`dcf4ca63`，638 行 + 測試）
- `POST https://google.serper.dev/search`，headers `X-API-KEY` + `Content-Type: application/json`
- body：`{q, gl?, hl?, tbs?, page?}`（country/language/time-filter/page 皆可選）
- 非 200 → 拋錯；解析 `data.organic[]` → `title`/`link`/`snippet` → `SearchResultItem`，`resultSize` 截斷

### OmniChat 實作步驟
1. **新增** `lib/core/services/search/providers/serper_search_service.dart`
   - 逐行移植上游（沿用 `SearchService<SerperOptions>` 基類與 `http.Client` 注入模式，與 `querit_search_service.dart` 一致）
2. **註冊** `lib/core/services/search/search_service.dart`
   - `SerperOptions`（apiKey + gl/hl/tbs/page，可選欄位皆有預設值）
   - `SearchService.getService` 加 `case SerperOptions _`；`SearchServiceOptions.fromJson` 加 `case 'serper'`
3. **品牌** `assets/icons/serper.svg`（NEW，上游原檔）+ `lib/utils/brand_assets.dart` 加 `MapEntry(RegExp(r'serper'), 'serper-color.svg')`（放 tinyfish/querit 同區塊）
4. **行動版 UI** `lib/features/search/pages/search_services_page.dart`
   - 服務清單 + `_getServiceName` case；新增/編輯表單（apiKey 必填 + gl/hl/tbs/page 4 個可選欄位）
   - `_BrandBadge._nameForService`／`_getServiceIcon`／`_getServiceStatus`（apiKey 空 → 需金鑰）／`_ServiceIcon._getMatchName` 接上 `SerperOptions`
5. **桌面版 UI** `lib/desktop/setting/search_services_pane.dart`
   - `_ServiceTypeChipsState._types` 加 serper 型別；新增/編輯 dialog 5 個欄位 + controller 初始化、`_createService`/`_updateService` 建構；`_BrandBadge._nameForService` 接上
6. **l10n**（7 keys × 4 語系，譯文採上游）：
   - `searchServiceNameSerper`／`searchProviderSerperDescription`／`searchServicesDialogCountryOptional`／`searchServicesDialogLanguageOptional`／`searchServicesDialogTimeFilterOptional`／`searchServicesDialogPageOptional`／`searchServicesDialogPageInvalid`
   - 執行 `flutter gen-l10n`
7. **測試** `test/core/services/search/serper_search_service_test.dart`（NEW，移植上游 130 行 7 案例：序列化與 factory／icon 映射（`BrandAssets.assetForName('serper')`）／body 建構與結果解析／可選欄位省略／page 驗證／空 apiKey 行為／非 200 拋錯）

---

## A2. Grok 搜尋服務商

### 上游實作（`67eb8bce` + `9fec9444` + `5e62d5d9`，636 行 + 測試）
- `POST {customUrl}`（預設 `https://api.x.ai/v1/responses`），`Authorization: Bearer`，body：
  - `{model, input: [system + user], tools: [{type:'web_search'},{type:'x_search'}], store: false}`
  - model 預設 `grok-4-1-fast-non-reasoning`
- 解析 `data.output[]` → 找 `type=='message' && role=='assistant'` → `content[].output_text`（作為 `answer`）
- `5e62d5d9`：`textContent.annotations[]` 的 `url_citation`（`url`/`title`）→ `SearchResultItem`，去重 URL、`resultSize` 截斷
- `9fec9444`：Grok 加進 search engine option mapping（UI 清單）

### OmniChat 實作步驟
1. **新增** `lib/core/services/search/providers/grok_search_service.dart`
   - 移植上游 107 行；注意 `SearchResult(answer:, items:)` 的 `answer` 欄位在 OmniChat 的 `SearchResult` 是否有對應（無則略過或比照 upstream 加入）
2. **註冊** `search_service.dart`：`GrokOptions`（apiKey + model + customUrl + systemPrompt，皆可選、有預設、含 `resolved*` getter）；`getService`/`fromJson` 加 `grok` case
3. **品牌** `assets/icons/grok-color.svg`？——**上游未附 grok svg**（commit stat 無 icon），確認：grok 的 brand 映射上游用既有 `grok.svg`（OmniChat 已有 `assets/icons/grok.svg` + `brand_assets.dart` `RegExp(r'grok')`）。`_BrandBadge`/`_getServiceIcon` 比照 `BrandAssets.assetForName('grok')` 即可，不新增檔
4. **行動版 UI** `search_services_page.dart`：服務清單 + 表單（apiKey / model / customUrl / systemPrompt 4 欄）+ 各接線點
5. **桌面版 UI** `search_services_pane.dart`：type chip + 4 欄 dialog
6. **l10n**（5 keys × 4 語系；`searchServicesDialogApiKey`／`searchServicesDialogModel`／`searchServicesDialogSystemPrompt` 在 OmniChat 不存在，需新增）：
   - `searchServiceNameGrok`／`searchProviderGrokDescription`／`searchServicesDialogApiKey`／`searchServicesDialogModel`／`searchServicesDialogSystemPrompt`
   - 執行 `flutter gen-l10n`
7. **測試** `test/core/services/search/grok_search_service_test.dart`（NEW，移植上游 158 行：序列化與 factory／body 建構（tools/systemPrompt）／結果解析（output_text + annotations 去重）／空 apiKey 不發 request／非 200 拋錯／resultSize 截斷）

---

## A3. OpenRouter 內建搜尋

### 上游實作（`9b579073`，223 行 + 測試）
- `builtin_tools.dart`：新增 `isOpenRouterProvider(cfg)`（`baseUrl` host 含 `openrouter.ai` 或 id 含 `openrouter`）；OpenAI kind 的 built-in search 支援 → 若 OpenRouter 且 `useResponseApi != true` 即支援
- `openai_common.dart`：chat-completions body 注入 `plugins: [{'id': 'web'}]`（與既有 plugins 合併、去重）

### OmniChat 實作步驟
1. **`lib/core/services/api/builtin_tools.dart`**：新增 `isOpenRouterProvider(ProviderConfig?)`（同上游）；在 `supportsSearch`（openai 分支）加入 OpenRouter 判斷
2. **`lib/core/services/api/chat_api_service.dart`**：OpenAI chat-completions body 建構處（**Grok `search_parameters` 注入點 ~L2194 附近**）新增：
   ```dart
   if (BuiltInToolsHelper.isOpenRouterProvider(config) &&
       config.useResponseApi != true &&
       builtIns.contains(BuiltInToolNames.search)) {
     // 合併既有 plugins + {'id': 'web'}（去重）
   }
   ```
   - 注意：OmniChat 有主 body + body2 重試多個建構點（比照 `_removeKimiK3SamplingParams` 的 5 個掛接點），此處只需主 body 1 處即可（重試沿用 body）
3. **UI 白名單**：
   - `lib/features/search/widgets/search_settings_sheet.dart`：`isOpenRouter = cfg.providerType == openai && isOpenRouterProvider(cfg)`，納入 built-in search toggle 顯示條件
   - `lib/desktop/search_provider_popover.dart`：同上
4. **測試** `test/openrouter_builtin_search_test.dart`（NEW，移植上游 192 行 → 改用 OmniChat 既有 `claude_dynamic_web_search_test.dart` 的 HttpServer 端到端風格，驗證 plugins 注入）

---

## A4. DeepSeek 內建搜尋（Claude 格式）

### 上游實作（`d2b909a3` 相關部分）
- `isDeepSeekProvider(cfg)`（host 含 `deepseek.com` 或 id/name 含 deepseek）
- Claude kind 的 built-in search 支援 → DeepSeek provider 直接 true
- `supportsClaudeDynamicWebSearchForModel` → DeepSeek 一律 false（僅用舊版 `web_search_20250305`，不掛 code_execution 配套）

### OmniChat 實作步驟（核心注入已存在，只補判斷與 UI）
1. **`builtin_tools.dart`**：新增 `isDeepSeekProvider(ProviderConfig?)`；`supportsClaudeDynamicWebSearchForModel` 加 `!isDeepSeekProvider(cfg) &&`；`supportsSearch` 的 claude 分支保持 true（已涵蓋）
   - 驗證 `_sendClaudeStream`：builtIns 含 search 時已注入 `web_search_20250305`（因 deepseek 不觸發 dynamic → toolType 正確為舊版），且 code_execution 配套不會附加 ✅ 不需改
2. **UI 白名單**：
   - `search_settings_sheet.dart`：`isClaude` 分支加 `isDeepSeekProvider(cfg)` → 允許開啟內建搜尋 toggle（DeepSeek-Anthropic provider 的模型如 `deepseek-chat` 目前不在 `claudeSupportedModels` 白名單）
   - `search_provider_popover.dart`：同上
3. **測試**：`test/claude_dynamic_web_search_test.dart` 或新增 case——DeepSeek-Anthropic provider 啟用內建搜尋 → tools 含 `web_search_20250305`、不含 code_execution、不含 `web_search_20260209`

---

## A5. Claude 4.8 / Fable 5 動態搜尋白名單

1. **`builtin_tools.dart`** `isClaudeDynamicWebSearchSupportedModel`：加入 `normalized == 'claude-fable-5'`、`normalized == 'claude-opus-4-8'`（`_normalizedModelId` 已 lower+trim）
2. **`search_settings_sheet.dart`** `claudeSupportedModels` set：加入 `claude-fable-5`、`claude-opus-4-8`
3. **`search_provider_popover.dart`**：同 set 補齊
4. **測試**：`test/builtin_tools_claude_dynamic_search_test.dart` 補 2 個 case（fable-5／opus-4-8 → dynamic web search supported）

---

## 驗證與收尾（Session A 通用）

```bash
flutter gen-l10n
flutter test            # 全量（現況 381 tests；預期 +30 左右）
flutter analyze         # 修改檔案無 new errors/warnings
```

- 版本號：`pubspec.yaml` → `1.18.0+N`；`installer.iss` → 1.18.0
- `CHANGES_LOG.md` 新增 v1.18.0 條目（比照 v1.17.7 格式：功能說明、逐項檔案清單、Tests 清單、Status/Version/Files Modified）
- commit 慣例（若使用者要求）：`feat(port): kelivo v1.1.13/v1.1.16 — Serper/Grok search providers + OpenRouter/DeepSeek built-in search + Claude 4.8/Fable-5 dynamic search whitelist`

---

## 風險與注意

- **`SearchResult.answer`**：確認 OmniChat 的 `SearchResult` 是否有 `answer` 欄位（Grok 用）；沒有就跟上游查 `SearchResultItem` 結構決定是否新增（涉及 UI 呈現，需一併確認 citation card 是否使用）
- **`searchServicesDialogApiKey` 等 3 個 key 為新 key**：Querit 移植時桌面版用 hardcoded `'API Key'` 是因為 key 不存在——本 session 補上後，桌面版可一併改用 l10n key（與上游一致；改動小、可選）
- **Grok svg**：上游 Grok 沒新增 icon 檔，直接沿用 OmniChat 既有 `grok.svg`（勿新增 `grok-color.svg` 造成重複）
- **plugins 注入位置**：僅 chat-completions 路徑（`useResponseApi != true`）；Responses 路徑由上游 `9b579073` 明確排除
