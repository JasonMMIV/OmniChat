# Session C 導入計畫：推理/模型支援補齊（Reasoning & Model Support）

> 對應 kelivo v1.1.15（`8c5270d5` Responses 工具接續修復）、v1.1.13（`3a23b18a` GPT-5.5 推理細節）、v1.1.17（`c5dcd472` Kimi K2.7 + GLM 5.2）的 OmniChat 缺口。
> 預計版本號：`v1.18.2`（pubspec `1.18.2+N`；installer.iss 1.18.2）。

---

## 目標項目

| # | 功能 | 上游 commit | 現況 |
|---|---|---|---|
| C1 | OpenAI Responses 工具接續修復（follow-up input 補齊遺失的 `function_call` items） | `8c5270d5` | ❌ 缺失 |
| C2 | GPT-5.5 推理細節：`samplingRequiresNone`（推理時剝離 temperature/top_p） | `3a23b18a` | 🟡 有 xhigh，缺取樣參數剝離 |
| C3 | Kimi K2.7 thinking body 正規化 + 取樣參數剝離 | `c5dcd472`（kimi 部分） | 🟡 只做到 k2.5 |
| C4 | GLM 5.x：model registry regex + Zhipu thinking knob（`api.z.ai`/`glm-` 前綴） | `c5dcd472`（glm/zhipu 部分） | 🟡 registry 無 glm-5；knob 只認 bigmodel host |

---

## C1. OpenAI Responses 工具接續修復

### 問題與上游修法（`8c5270d5`）
- **問題**：Responses API 串流工具輪次後，follow-up 請求的 `input` 用 `response.completed` 的 `output` items + `function_call_output`。若 `output` 缺 `function_call` items（串流被截斷/未完成等），follow-up input 會出現「只有 `function_call_output`、沒有對應 `function_call`」→ API 拒絕。
- **上游修法**：新增 `_withResponsesFunctionCallItems(outputItems, calls)`——把 `ToolCallInfo`（已累積的 call）重建為 `function_call` items，補進 output items（按 call_id 去重），再餵給 follow-up input。

### OmniChat 實作步驟（`lib/core/services/api/chat_api_service.dart`）
1. 新增 static helper（比照上游 `openai_responses.dart` 的 `_withResponsesFunctionCallItems`，改為 OmniChat 的 `ToolCallInfo` 型別）：
   ```dart
   static List<Map<String, dynamic>> _withResponsesFunctionCallItems(
     List<Map<String, dynamic>> outputItems,
     Iterable<ToolCallInfo> calls,
   )
   ```
   - 複製 outputItems → 收集既有 `function_call` 的 call_id set → 對每個 call（id 非空且未出現）追加 `{type: 'function_call', call_id, name, arguments: jsonEncode(args)}`
2. 掛接點（Responses 路徑，`_sendOpenAIStream` 內）：
   - 第一輪 follow-up：`~L3443` 的 `if (lastResponseOutputItems.isNotEmpty) currentInput.addAll(lastResponseOutputItems);` → 改為
     ```dart
     final responseOutputItems = _withResponsesFunctionCallItems(lastResponseOutputItems, callInfos);
     if (responseOutputItems.isNotEmpty) currentInput.addAll(responseOutputItems);
     ```
     （`callInfos` 即該輪已 yield 的 `ToolCallInfo` list——確認變數名，可能在 `toolCalls` yield 區上方）
   - 第二輪（round loop 內）：`~L3690` 的 `if (outItems2.isNotEmpty) currentInput.addAll(outItems2);` → 同法用 `_withResponsesFunctionCallItems(outItems2, callInfos2)`
3. **測試**：找 OmniChat 既有 Responses 工具測試檔（`test/reasoning_budget_api_test.dart` 或 Images API 測試），加 1 case（移植上游 `chat_api_custom_image_marker_test.dart` 的 "Responses tool continuation keeps streamed function call before output"）：
   - HttpServer 回傳含 function_call 串流事件但 `response.completed` 的 `output` 為空 → follow-up 請求 `input` 內 `function_call`（call_id）出現在 `function_call_output` 之前

---

## C2. GPT-5.5 取樣參數剝離（samplingRequiresNone）

### 上游實作（`3a23b18a`）
- `openai_model_compat.dart`：`_gpt55Support = OpenAIReasoningSupport(supportedEfforts: ['none','low','medium','high','xhigh'], samplingRequiresNone: true)`；`_gpt55ProSupport`（['medium','high','xhigh']）；`gpt-5.5-codex|chat-latest` → null
- 使用處：`_shouldIncludeSamplingParams`（`samplingRequiresNone` 且 reasoning 啟用 → 不含 sampling params）

### OmniChat 實作步驟
1. **`lib/core/utils/reasoning_capabilities.dart`**：
   - `ReasoningCapabilities` 加 `samplingRequiresNone`（`bool`，預設 false）
   - `_openAiCapabilities`：`gpt-5.5`（minor==5、非 codex/chat-latest、非 pro）→ `supportsXhigh: true, samplingRequiresNone: true`
2. **`lib/core/services/api/chat_api_service.dart`**：OpenAI body 建構處（temperature/top_p 的 5 個掛接點，`~L1895/2055/2685/4106/4702`）——比照 upstream 的 helper：
   - 新增 `static bool _shouldIncludeSamplingParams(upstreamModelId, isReasoning, ...)`：capabilities 有 `samplingRequiresNone` 且 `isReasoning` → false
   - 各掛接點 `if (temperature != null) 'temperature': temperature` 加條件（或用既有 `_removeKimiK3SamplingParams` 模式新增 `_applyGpt55SamplingParams(body, upstreamModelId, isReasoning)`）
3. **測試**：`test/reasoning_budget_api_test.dart` 加 case：gpt-5.5 + 推理 + temperature 設定 → body 無 temperature/top_p；gpt-5.5 非推理 → 保留；gpt-5.5-pro → 保留（pro 無 samplingRequiresNone）

---

## C3. Kimi K2.7 thinking body 正規化

### 上游實作（`c5dcd472` kimi 部分）
- `_isKimiThinkingModel` 加入 `kimi-k2.7`；新增 `_isKimiOmitsSamplingParamsModel`（k2.5 + k2.7）；`_removeMoonshotKimiUnsupportedSamplingParams` 剝離 5 個參數（temperature/top_p/n/presence_penalty/frequency_penalty）

### OmniChat 實作步驟（`lib/core/services/api/chat_api_service.dart`）
1. `_isKimiK25Model` → 廣義化（k2.5/k2.7 共用 thinking `{type}` 行為）或新增 `_isKimiK27Model`
2. `_isKimiThinkingModel` 加入 `lower.contains('kimi-k2.7')`
3. `_normalizeMoonshotKimiChatBody`：k2.7 比照 k2.5——`thinking: {type: enabled|disabled}` + 剝離 5 個採樣參數
4. **測試**：`test/reasoning_budget_api_test.dart` 加 case：kimi-k2.7 thinking enabled → `{type: 'enabled'}`、5 個採樣參數移除；off → `{type: 'disabled'}`；非 thinking → 無 `thinking`

---

## C4. GLM 5.x 支援（registry + Zhipu thinking knob）

### 上游實作（`c5dcd472` glm/zhipu 部分）
- `model_provider.dart`：vision/tool/reasoning regex 加 `glm-5`（上游該版已把 glm 家族 regex 整理為 `glm-4([-.])(?:5|6|7)|glm-5`）
- `_isZhipuLikeProvider({providerId, host, upstreamModelId})`：providerId 含 `zhipu`/`智谱`、host 含 `bigmodel`、host == `api.z.ai`、或 modelLower `startsWith('glm-')` → 套用 `thinking: {type: enabled|disabled}` knob（原本只認 bigmodel host）

### OmniChat 實作步驟
1. **`lib/core/providers/model_provider.dart`**：
   - `tool` regex：`glm-4\.5|glm-4\.6` → `glm-4\.[5-7]|glm-5`（或比照上游）
   - `reasoning` regex：同法補 `glm-5`
   - （vision 可選：上游 vision 含 `kimi-k2(.5|6|7)`、`glm`——OmniChat 的 vision regex 是 `gemini|claude` 等泛化，確認 glm 是否需加；依現況決定）
2. **`lib/core/services/api/chat_api_service.dart`**：
   - 新增 static `_isZhipuLikeProvider({required String providerId, required String host, required String upstreamModelId})`（比照上游）
   - 現有 5 處 `host.contains('open.bigmodel.cn') || host.contains('bigmodel')` 分支改為 `_isZhipuLikeProvider(...)`（`~L1037/2106/2733/4152` 附近 + 重試 body2 處）
3. **測試**：`test/reasoning_budget_api_test.dart` 或新增 `test/glm_zhipu_thinking_test.dart`：modelId `glm-5.2`（host 非 bigmodel）→ body 含 `thinking: {type: enabled}`；host `api.z.ai` → 同樣生效；非 glm/zhipu → 不受影響

---

## 驗證與收尾（Session C 通用）

```bash
flutter test            # 全量（預期 +8 左右）
flutter analyze         # 修改檔案無 new errors/warnings
```

（C 批無新 l10n key、無新 UI、無新 icon → 不需 `flutter gen-l10n`；除非 C1 測試需要建新 test 檔）

- 版本號：`pubspec.yaml` → `1.18.2+N`；`installer.iss` → 1.18.2
- `CHANGES_LOG.md` 新增 v1.18.2 條目
- commit（若要求）：`feat(port): kelivo v1.1.13/v1.1.15/v1.1.17 — Responses tool continuation fix + GPT-5.5 sampling + Kimi K2.7/GLM 5.2 thinking`

---

## 風險與注意

- **C1 變數名**：OmniChat 的 Responses 路徑變數（`lastResponseOutputItems`/`outItems2`/`callInfos`/`callInfos2`）與上游略異，移植前先讀 `~L3170–3690` 區段確認實際名稱與 yield 順序
- **C2 不導入 'none' effort**：上游 GPT-5.5 支援 `'none'` effort，但 OmniChat 的 effort 由 budget 映射（無 'none' 來源），本計畫只導入**取樣參數剝離**（有實際 bug 影響）；`'none'` effort 列為選項、可略
- **C4 vision regex**：OmniChat vision 判斷是 `gemini|claude` 泛化 regex，GLM 5.x 若需 vision 能力再補——先以 tool/reasoning 為準，避免過度改動
- **5 處掛接點**：C2/C4 都涉及多處 body 建構點，編輯後逐一 grep 確認沒有漏掛（比照 `_removeKimiK3SamplingParams` 的既有 5 處模式）
