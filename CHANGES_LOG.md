# OmniChat Documentation & Developer Changes Log

## 📌 Core Architecture & Feature Overview

### Project Overview

- **Project Name**: OmniChat (A fork of Kelivo, inspired by Rikkahub)
- **Status**: Active Development / Feature Integration
- **Last Updated**: 2026-08-12 (v1.17.0)
- **Platforms**: Android (ARM64 v8a), Windows

---

### Core Feature Modules

#### 1. Voice Chat Functionality (Integrated)

Provides a seamless, hands-free conversational experience with AI.

- **Cross-Platform State Machine**: Transitions smoothly between `Listening`, `Thinking` (processing), and `Talking` (TTS playback).
- **Silence Timeout Handling (v1.5.10, reverted in v1.5.14)**: 
  - The automatic "Pause-on-Timeout" strategy was removed because Android speech recognition timeout/status callbacks are not reliable enough to drive UI state.
  - Voice Chat now keeps Play/Pause state under explicit user control instead of auto-pausing on `notListening`, `error_speech_timeout`, or `error_no_match`.
- **Inline Voice Dictation (v1.5.8 - v1.5.12, timeout auto-exit reverted in v1.5.14)**: 
  - Added a microphone button directly to the text input bar, fully localized in English, Traditional Chinese, and Simplified Chinese according to system/app settings.
  - Supports non-destructive text entry (appends recognized speech to existing text).
  - Integrated dedicated "Stop" and "Confirm/Send" buttons (also fully localized) for a focused dictation UX.
  - **Manual Exit**: Timeout-driven auto-exit was removed. Users explicitly end dictation with Stop or Confirm for more predictable Android behavior.
- **Audio Session Management**: Optimized for Bluetooth/CarPlay on Mobile; platform-guarded on Desktop to prevent crashes.
- **Windows Architecture**:
  - **Current Implementation (v1.5.4)**: Dedicated Win32 Message-Only Window for robust thread marshalling and Chinese locale fallback.
  - **Key Feature**: Native support for high-accuracy "OneCore" DNN engines (Windows 10/11 Dictation quality).
  - **Crash Mitigation (v1.5.17 → v1.5.29)**:
    - **v1.5.17**: Reduced fetch download limit (2 MB → 512 KB), added historical tool-result truncation, and introduced a fetch concurrency queue to reduce compound memory pressure during deep-thinking + web-search + multi-fetch conversations.
    - **v1.5.18**: Replaced ReDoS-vulnerable RegExp patterns in `_preCleanHtml()` with linear-complexity lazy matchers (`[\s\S]*?`). Added `_capForParsing()` to truncate HTML to 256 KB before DOM parsing. Added 30-second HTTP timeout to `_fetchWithLimit()`. Offloaded heavy HTML→Markdown/TXT conversion to background isolates via `compute()` for pages >32 KB, with 15-second isolate timeout.
    - **v1.5.26–v1.5.29**: Reduced Windows native crash paths through platform-specific selection fallbacks, streaming-deferred Mermaid/PlantUML rendering, `WM_GETOBJECT` interception at both runner windows, WebView2 lifecycle guards, and WinRT speech-plugin thread-safety fixes. On Windows, completed messages use dedicated copy dialogs where inline `SelectionArea` is bypassed; during streaming, native-resource-heavy renderers are deferred.

#### 2. Account Balance Support (Integrated)

Ported from Rikkahub to provide real-time usage monitoring.

- **Provider Integration**: Supports OpenAI, Google Gemini, DeepSeek, OpenRouter, Moonshot, and **Neuralwatt (v1.5.15)**.
- **Custom Configuration**: Users can toggle balance fetching and define custom API paths and JSON result keys per provider.
- **Neuralwatt Quota (v1.5.15)**: Uses the official `GET /v1/quota` endpoint. Displays `balance.credits_remaining_usd` formatted as `$xx.xx`.
- **UI Display**: Balance display integrated into Provider Settings and Model Selection menus.
- **Status**: **Verified Working**.

#### 3. UI/UX Enhancements & Rebranding

Refined visual identity and improved accessibility.

- **Global Rebranding**: Completed migration from "Kelivo" to "OmniChat" across all visible strings (About section, notifications, tray icons).
- **Streamlined Settings**: Removed redundant "Docs" and "Sponsor" options to focus on core chat experience.
- **Translation Localization**: Updated default translation target to **Traditional Chinese (zh-TW)** for Chinese-speaking regions.
- **Icon Maximization**: Enlarged action icons across the app (AppBar, Sidebar, and Input Toolbar).
- **Desktop Optimization**: 1.4x scale for Voice Chat and New Chat buttons for better target acquisition.
- **Brand Icons (v1.5.16)**: Added `neuralwatt-color.svg` (brand blue `#2563EB`, replacing `currentColor` for cross-theme visibility) and `tinyfish.png` (64x64, resized from 200x200) to `assets/icons/`. Registered both in `BrandAssets` mapping so they appear in provider avatars, search service lists, model selectors, and all UI surfaces that resolve brand icons.
- **Reasoning Text Selection (v1.5.16)**: Reasoning/thinking blocks from reasoning-capable models now support text selection. Wrapped both plain-text and Markdown rendering paths in `SelectionArea` with a custom context menu providing "Select All" and "Copy" actions (long-press on mobile, right-click on desktop).
  - Implemented dynamic layout calculations to automatically hide overflowing input actions (e.g. Inline Dictation, Reasoning Mode) on smaller screen sizes (mobile).
  - Instead of spawning a redundant second `+` button on the left, these overflowed items are gracefully consolidated into the existing right-side `+` (More) menu.
  - Within the `BottomToolsSheet`, the overflowed items are presented below "Learning Mode" and "Clear Context", rendered in a matching list row layout (icon on the left, label on the right).

#### 4. Search Services (Integrated)

Provides configurable external web search providers for tool-enabled text chat.

- **Provider Registry**: Search providers are represented by typed `SearchServiceOptions` and resolved through `SearchService.getService`.
- **Supported Providers**: Bing Local, DuckDuckGo, Tavily, Exa, Zhipu, SearXNG, LinkUp, Brave, Google, Metaso, Jina, Ollama, Perplexity, Bocha, and **Tinyfish (v1.5.15)**.
- **Google Search API**: Uses Google Custom Search JSON API with `apiKey` and Programmable Search Engine ID (`cx`). Per-request result count is capped to Google's `num <= 10` API limit.
- **Tinyfish Search API (v1.5.15)**: Uses the official `GET https://api.search.tinyfish.ai` REST endpoint with `X-API-Key` header. Maps response `results[]` — `title`, `url`, `snippet` — to `SearchResultItem`. Supports `resultSize` limit and `timeout` control. REST API only; MCP integration is deferred.
- **UI Coverage**: Both mobile search service sheets and desktop settings panes support provider creation, editing, selection, status display, and brand icons.

#### 5. Local Code Execution (MCP) (Integrated)

Provides a sandboxed environment for LLM to execute code locally on all platforms, including Android.

- **In-memory MCP Transport**: Implemented an internal, high-performance transport that doesn't require network overhead.
- **JavaScript Runtime**: Integrated `flutter_js` (QuickJS/JavaScriptCore) to provide a secure, lightweight execution environment.
- **Tooling**: Exposes `run_javascript` tool to the LLM for data processing, calculations, and logic evaluation (e.g., fortune-telling algorithms).
- **Architecture**: Decoupled engine (`JsMcpServerEngine`) from the transport layer to ensure maintainability and portability.
- **Safety Hardening (v1.5.14)**:
  - Runs each JavaScript tool call in a fresh runtime to prevent global state leakage between calls.
  - Disables JavaScript network APIs for the built-in local execution tool and rejects direct `fetch`/`XMLHttpRequest`/`WebSocket` usage patterns.
  - Applies QuickJS timeout and memory limits on QuickJS-backed platforms, with preflight rejection for empty, oversized, and obvious infinite-loop snippets.
- **Fetch Server Memory Optimization (v1.5.16 → v1.5.18)**:
  - **v1.5.16**: Replaced unbuffered `http.get()` with a streaming `_fetchWithLimit()` method that reads the HTTP response chunk-by-chunk and rejects bodies exceeding 2 MB, preventing memory spikes from large web pages.
  - **v1.5.16**: Added `_preCleanHtml()` helper that strips `<script>`, `<style>`, `<head>`, `<noscript>`, `<svg>`, `<iframe>`, and inline `data:` URIs via RegExp before DOM parsing or Markdown conversion, reducing raw HTML payload by 70–90%.
  - **v1.5.17**: Reduced the download hard limit from 2 MB to **512 KB**. After pre-cleaning, most pages' meaningful content is 50–200 KB; 512 KB provides ample headroom while cutting peak per-fetch transient memory by ~75%.
  - **v1.5.17**: Added historical tool-result truncation in `ChatApiService` via `_truncateToolResultText()` (32,768-char threshold, head+tail preservation) and `_truncateToolResultsInMessages()`. Applied before every follow-up request across OpenAI, Claude, and Google formats, preventing `currentMessages` / `convo` from ballooning across multi-round tool-call loops.
  - **v1.5.17**: Added `_withFetchQueue()` concurrency limit of **2 parallel fetches** in `KelivoFetcher` with `Completer`-based FIFO queuing and exception-safe `finally` cleanup.
  - **v1.5.18**: Replaced ReDoS-prone RegExp patterns in `_preCleanHtml()` (`[^<]*(?:(?!</tag>)<[^<]*)*`) with linear lazy matchers (`[\s\S]*?`). This fixes deterministic crashes on HTML inputs containing many unpaired `<` characters that previously caused exponential backtracking (O(2ⁿ)).
  - **v1.5.18**: Added `_capForParsing()` to limit DOM parse input to **256 KB** (with UTF-16 surrogate pair safety), preventing OOM from building full DOM trees on large pages.
  - **v1.5.18**: Added a **30-second HTTP timeout** to `_fetchWithLimit()` to prevent indefinite hangs on slow/hanging servers.
  - **v1.5.18**: Offloaded heavy synchronous HTML processing (`_preCleanHtml` + `html2md.convert` / `html_parser.parse`) to background isolates via `compute()` for pages >32 KB. Isolates are capped at **15 seconds**; OOM or CPU spin in the isolate kills only the background worker, not the UI.
  - Applies to all four fetch tools: `fetch_html`, `fetch_markdown`, `fetch_txt`, `fetch_json`.
  - **Status**: **Verified Working (v1.5.9), hardened in v1.5.14, memory-optimized in v1.5.16, crash-threshold lowered in v1.5.17, ReDoS root cause fixed in v1.5.18**.

#### 6. Built-in API Providers (Integrated)

OmniChat ships with a curated list of built-in API providers, each with default base URLs, enabled states, and provider-specific configurations.

- **Provider Architecture**: Uses `ProviderKind` enum (`openai`, `google`, `claude`, `neuralwatt`) with `ProviderConfig.classify()` for automatic key-based inference and `ProviderConfig.defaultsFor()` for sensible defaults.
- **Provider Management**: `ProviderManager.forConfig()` resolves the correct `BaseProvider` implementation for model list fetching, balance checking, and connection testing.
- **Neuralwatt Provider (v1.5.15)**:
  - **Base URL**: `https://api.neuralwatt.com/v1`
  - **Model List**: Fetches from `GET /v1/models` and parses Neuralwatt-specific `metadata` — `display_name` for model display name, `capabilities.vision` for image input, `capabilities.tools` for tool ability, `capabilities.reasoning` / `reasoning_effort` for reasoning ability, and `deprecated` flag for deprecation marker.
  - **Balance**: `GET /v1/quota` extracting `balance.credits_remaining_usd`.
  - **Chat API**: OpenAI-compatible; neuralwatt is routed to the OpenAI chat completion / Responses API flow via `_apiKind()` helper in `ChatApiService` and `ProviderManager.testConnection()`.
  - **Config Defaults**: `chatPath: /chat/completions`, `useResponseApi: false`, `balanceEnabled: true`, `balanceApiPath: /quota`, `balanceResultKey: balance.credits_remaining_usd`.
  - **Brand Icon**: Mapped to `neuralwatt-color.svg` (v1.5.16, brand blue `#2563EB`) with letter `N` fallback.
  - **Scope**: First version covers REST API only; does not implement `/v1/usage/energy`, per-request energy display, or API key allowance management.

#### 7. AI Team — Mixture of Agents (Integrated, v1.5.19–v1.5.24)

Provides a Mixture-of-Agents pipeline supporting both Parallel (MoA) and sequential Chain (CMoA) collaboration models.

- **Parallel (MoA) Mode**: 1–4 "proposer" models answer the user's question independently, and an "aggregator" model synthesizes their outputs into a single final response.
- **Chain (CMoA) Mode**: Sequential chain pipeline (Proposer -> Critics -> Aggregator). The Proposer runs first with Proposer Prompt A. Then, sequential Critics (0-3) audit the previous outputs using Critic Prompt B, with preceding assistant and critic outputs stitched chronologically into the conversation history to simulate an ongoing dialogue. Finally, the Aggregator synthesizes the entire chain's thinking with Aggregator Prompt C.
- **Execution Strategy**: **Serial** execution — proposers and critics run sequentially (not in parallel) to avoid memory spikes during multi-round tool-call + web-search conversations, aligning with the v1.5.16–v1.5.18 fetch memory optimization work.
- **Proposal Phase**: Each proposer receives a cloned copy of the prepared `apiMessages` (including instruction injection, memory, search prompts) with the proposal system prompt **appended** to the existing system message (preserving assistant persona). Proposers can use all tools (search, fetch, MCP) inherited from the user's current toolbar settings.
- **Aggregation Phase**: Proposals are injected as `{role:'assistant'}` messages after the last user message, followed by a trailing `{role:'user'}` message instructing the aggregator to synthesize. This trailing user message ensures the last role is `user`, which is required by providers like Mistral that reject an assistant as the final message. The aggregator system prompt is appended to the existing system message. The aggregator receives `toolDefs` and `onToolCall` inherited from the toolbar settings, enabling it to call tools (search, fetch, MCP) when synthesizing the final answer. The aggregator stream is dispatched via the standard `_executeGeneration` flow, so UI streaming updates and tool cards work identically.
- **Stream Subscription Management**: Proposer/Critic subscriptions are managed via a local variable (NOT stored in `_conversationStreams`). Only the aggregator's subscription is registered for cancellation.
- **Placeholder Model ID**: When AI Team is enabled and an aggregator is explicitly configured, the assistant placeholder's `modelId`/`providerId` are set to the aggregator's values.
- **Error Handling**: Per-proposer/critic failures (429, timeout, network) are caught and skipped; only if ALL proposers fail does the entire flow abort.
- **Cancellation**: Cancelling during the proposal phase cancels the current proposer/critic subscription **and the underlying HTTP request** (via `ChatApiService.cancelRequest('${cid}_proposer')`), marks the placeholder with "AI Team stopped", and persists any partial proposals.
- **Proposals Rendering**: After the aggregator finishes, proposals are persisted as JSON in `ChatMessage.aiTeamProposalsJson` (HiveField 16) and rendered as a collapsible grey box titled "協作過程" (Collaboration Process) — visually mirroring the reasoning section but semantically independent.
- **Model Selection**: `showModelSelector` is called without `limitProviderKey`, allowing cross-provider MoA combinations (e.g. OpenAI + Claude + Google).
- **Default Prompts**: Defaults are localized (en, zh-Hans, zh-Hant) and switch with app language. Users can customize prompts; when customized, the `useDefaultProposalPrompt` / `useDefaultAggregatorPrompt` / `useDefaultChainProposerPrompt` / `useDefaultChainCriticPrompt` / `useDefaultChainAggregatorPrompt` flags flip to `false`, and the custom text is used. Each prompt editor has its own **Restore Default** button, so a single prompt can be reverted to the l10n default without touching the others.
- **Progress Indicator**: During the proposal/critic phase, a localized progress text (e.g., "AI Team running… Proposal X/N" or "AI Team running… Critic X/N") is pushed to the streaming UI via `StreamingContentNotifier.updateContent()`, giving users visual feedback that work is in progress.
- **Real-time Proposals**: Proposals and audits are shown in the UI as soon as each slot completes — not waiting for the entire flow to finish. After each completes, the partial proposals JSON is pushed to `StreamingContentNotifier.updateProposals()`, persisted to DB via `updateMessageSilent()`, and the in-memory message list is updated. The `AiTeamProposalsSection` widget dynamically filters empty proposals, so only completed proposals are visible during the phase. `sendMessage` and `regenerateAtMessage` use `unawaited(_executeAiTeamGeneration(...))` (instead of `await`) so that `sendMessage` returns immediately, `notifyListeners()` fires, `MessageListView` rebuilds, and `ValueListenableBuilder` mounts.
- **Mistral Aggregator Compatibility**: `_buildAggregatorMessages` appends a trailing `{role:'user'}` message after the proposals so the final role is `user`. Mistral API rejects an assistant as the last message (HTTP 400 `invalid_request_message_order`); the trailing user prompt resolves this and is harmless to other providers.
- **Rich Proposals**: Each proposal/audit captures not only the final content but also the reasoning text and tool-call history (name, arguments, truncated results). These are stored in the proposals JSON and rendered as collapsible sections within each block.
- **Proposals Position**: Proposals are rendered **before** the aggregator's reasoning section and main content, matching the logical reading order: proposals → aggregator thinking → aggregator answer.
- **Layered Collapsible UI**: Each proposal block in the grey box has individually collapsible Thinking and Tool Calls sections (default collapsed), with the final answer always visible.
- **Settings UI**: Full settings page (mobile `AiTeamPage` + desktop `DesktopAiTeamPane`) for enable toggle, collaboration mode selector (Parallel vs Chain), proposer/critic count, per-slot model selection, aggregator selection, and prompt editing. When `useDefault=true`, the l10n default is shown as preview. Accessible from Settings → Models & Services → AI Team.
- **Toolbar Button**: A `Lucide.Users` button is placed between Reasoning and Learning mode in the chat input bar, opening the AI Team settings page when tapped.
- **Regenerate**: `regenerateAtMessage` supports AI Team — when enabled, regeneration runs the full proposer → aggregator pipeline, consistent with `sendMessage`.
- **Status**: Integrated (v1.5.19–v1.5.24).

#### 8. Context Management & Compression (Integrated, v1.5.22)

Provides a comprehensive context control flow aligned with upstream (Kelivo)'s design.

- **Context Management Sheet**: Mobile users access an elegant bottom sheet to select between "Clear Context" and "Compress Context".
- **Desktop Dropdowns**: Integrated with the desktop text composer toolbar, featuring an anchored popover to select context operations.
- **Context Compression (Compress Context)**: 
  - Gathers the active chat history (optionally limited to the earliest, most recent, or unlimited characters) and serializes it.
  - Queries the LLM with the custom summary prompt (fully editable in settings).
  - Automatically creates a new conversation with the summary as the first message and transitions the user session to it, leaving the original conversation history untouched.
  - Dynamically resolves the most appropriate model: `Compress Model` (custom-configured) -> `Summary Model` -> `Title Model` -> `Assistant Model` -> `Chat Model` (global default).
- **Remaining Message Count**: Fixed context remaining message counting logic by utilizing complete messages in the view model instead of lazy-loaded segments.
- **Status**: **Integrated (v1.5.22)**.

---

### Technical Implementation Details

#### Architecture & State Management

- **Providers**: Centralized logic using `SettingsProvider`, `AssistantProvider`, `ChatService`, and `VoiceChatProvider`.
- **Windows Plugin**: Locally forked and patched `speech_to_text_windows` to support modern WinRT APIs and custom JSON transformation.
- **Text Chat Streaming**: Chat stream handling now serializes async chunk processing with subscription pause/resume guards. Unhandled async errors are routed into stream error handling and global guarded logging to reduce Windows text chat crashes.

#### Windows WinRT Migration Roadmap

1. **Phase 1 (Done)**: Build environment setup.
2. **Phase 2 (Done)**: Core implementation rewrite (SpeechRecognizer integrated).
3. **Phase 3 (Done)**: Runtime validation and robust threading via Message-Only Window.
4. **Phase 4 (Done)**: Chinese locale fallback and stability improvements.

#### Build & Release

- **Target Platform**: 
  - Android: Signed ARM64 v8a APK.
  - Windows: Portable ZIP and Inno Setup Installer.
- **Optimization**: Tree-shaking enabled; high-resolution asset unification.

---

## 📜 Version Changes Log
## [v1.17.0] - 2026-08-12: OpenAI Images API 支援（kelivo 移植）＋圖片比例選擇器

> 依「導入 kelivo 圖片生成模型支援」計畫執行。從 kelivo 上游 commit `e1c20378`（feat: support Images API generations and edits）外科手術式 backport `openai_images.dart` 為 `ChatApiService` 的 static 方法：**輸出模式含「圖片」的模型**（於模型基本設定頁勾選輸出圖片；未設定時由 `ModelRegistry.infer` 依 id 推斷，如 `dall-e-*`、`gpt-image-*`、`sensenova-u1-fast`）**預設**改走獨立 `/images/generations` 與 `/images/edits` 端點，而非聊天補全；工具頁「使用 Images API」開關（僅圖片輸出模型可見）預設開啟，混合模型或供應商以聊天補全出圖者可手動關閉——關閉後仍走聊天補全出圖，比例參數照常注入。無輸入圖→生成；有輸入圖（含引用上一張生成圖的疊代編輯）→ `/images/edits`（multipart 上傳，經既有 `DioHttpClient.send`）。Phase 2 另加圖片比例選擇器（全域 `imageAspectRatio` 設定 + 輸入列按鈕 + `size`/`aspect_ratio` 轉換）。

- **193a** Images API 移植（`chat_api_service.dart`）：
  - `sendMessageStream` 新增 `String? imageAspectRatio` 參數，並在 `kind == ProviderKind.openai` 分支前插入最早路由分支 `shouldUseOpenAIImagesApi(config, modelId)`。**判斷拆成兩層**：① `isOpenAIImageOutputModel`（公開）＝ `_apiKind(cfg) == openai`（neuralwatt 亦屬之）且有效輸出模式含 `Modality.image`（有效輸出 = per-model override 的 `output` 優先、否則 `ModelRegistry.infer` 推斷）——**「是否圖片模型」的單一標準**，供輸入列比例按鈕與 `generateText`/OCR/翻譯守護使用，**與開關無關**（關掉後模型仍可能經聊天補全出圖）；② `shouldUseOpenAIImagesApi` ＝ ① 且 `useImagesApi != false`——**「是否走 Images API」的路由決策**，僅供 `sendMessageStream` 分支使用（圖片輸出模型預設開啟、工具頁開關可關閉，非圖片輸出模型無開關、不可 opt-in）。
  - 移植 24 個 static 方法 + `_OpenAIImagesInput`：`shouldUseOpenAIImagesApi`（公開）、`isOpenAIImageEditModel`（公開，`2026-08-13`：**移除編輯 id 白名單**，改以「有效 input 與 output 皆含圖片」判斷編輯能力）、`_sendOpenAIImagesStream`（單一 `ChatStreamChunk`，`isDone: true`、null-safe usage——dall-e 無 token usage → 0）、生成/編輯 JSON/multipart 三條請求路徑、輸入解析（`userImagePaths` → `_parseTextAndImages` → `_lastAssistantImageBefore` 疊代回退）、custom headers/body 合併（`_parseOverrideValue`）、base64 存檔（沿用 `_saveInlineImageToFile`/`_extFromMime`）、`output_format` mime 推導、`MediaType` 校驗（+`http_parser: ^4.1.2` 依賴）。
  - `generateText` 防誤用守護（圖片模型回 `''`）；OCR（`ocr_service.dart`）與翻譯（`translation_service.dart`）呼叫 `sendMessageStream` 前套用同一守護（圖片模型時回空文字/回原文），避免誤出圖。
  - 比例轉換 `_imageApiSizeParam`：custom body（`size`/`image_size`/`aspect_ratio`）優先 → `useAspectRatioParam` 覆寫直傳 `aspect_ratio` 字串 → 白名單 `size` 表格（1:1→1024x1024、3:4→1024x1360、4:3→1360x1024、16:9→1792x1024、9:16→1024x1792）→ 預設 size；dall-e-3 3:4/4:3 回退最接近合法值（1024x1792/1792x1024）並在回覆 markdown 附加附註（service 無 BuildContext，不經 SnackBar）。
  - **聊天補全路徑也注入比例**：`_sendOpenAIStream` 新增 `imageAspectRatio` 參數，圖片輸出模型且開關關閉（`useResponseApi != true`）時，送請求前以 `_applyOpenAIImagesSize` 注入 `size`/`aspect_ratio`（custom body 仍優先）——關掉開關的模型經聊天補全出圖時比例照常生效。
  - **編輯能力＝模式判斷（`2026-08-13`）**：輸入含圖片（且輸出含圖片）→ 送 `/images/edits`；否則**送前快速失敗**（保留 `UnsupportedError` 清晰訊息，不做 4xx 自動降級——錯誤原因很多，不能僅憑狀態碼判定）。`ModelRegistry.infer` 同步修正：`dall-e-3`/`sensenova-u1-fast` 改為**僅輸出含圖片**（input 純文字，非編輯模型），`dall-e-2` 維持 input+output（OpenAI 支援其 edits 端點）；使用者於基本設定頁顯式勾選 input 圖片可覆寫推論。
- **193b** 模型設定 UI（mobile `model_detail_sheet.dart` + desktop `model_edit_dialog.dart` 兩份獨立實作）：工具分頁**僅在輸出模式含「圖片」時**顯示「使用 Images API」（`useImagesApi`）與「使用 aspect_ratio 參數」（`useAspectRatioParam`）兩個開關；`useImagesApi` **預設開啟**（`bool _useImagesApi = true`，initState 讀回 explicit 值、`_save` 僅在關閉時寫 `useImagesApi: false`），供混合模型/聊天補全出圖供應商關閉路由；`ModelRegistry.infer` 擴充既有 `contains('image')` 區塊（`dall-e-|sensenova-u1-fast` regex）供未設定的模型推斷輸出模式。
- **193c** 圖片比例選擇器（Phase 2）：
  - `SettingsProvider` 新增全域 `imageAspectRatio`（鍵 `image_aspect_ratio_v1`，預設 `1:1`），由呼叫端讀取後經 `sendMessageStream(..., imageAspectRatio:)` thread 進 service（`ChatApiService` 為純 static，不直讀 provider）。
  - `lucide_adapter.dart` 新增 `Lucide.Ratio = lucide.LucideIcons.frame`（套件無 ratio 圖示）；`chat_input_button_catalog.dart` 在 `model` 之後新增 `imageRatio` 規格與預設順序（`chatInputButtonEffectiveOrder([])` 必須等於 default order 的測試不變量）。
  - `chat_input_bar.dart`：僅當 `ChatApiService.isOpenAIImageOutputModel` 為 true（**「是否圖片模型」的單一標準：kind == openai 且輸出含圖片，與開關無關**）顯示比例按鈕——關閉 Images API 開關後模型仍可能出圖，按鈕不消失（`Lucide.Ratio` 圖示 + tooltip 顯示目前比例）；行動版 bottom sheet、桌面版 anchored popover（等比例預覽方框），overflow 進 `+` 選單時回退居中 dialog；Gemini 內嵌出圖不顯示。
- **Status**: 全部完成——`flutter test` full suite **264 tests passed**（v1.16.0 為 230 → +34：`openai_images_api_test.dart` 31、`settings_provider_image_ratio_test.dart` 3）；`flutter analyze` 修改檔案 **no new errors**（全專案僅既有 vendored `speech_to_text_windows` example 2 個 error）。實機端到端（文生圖/圖生圖/疊代編輯/比例轉換）尚未驗證。
- **Version**: pubspec `1.17.0+81`；installer.iss 1.17.0（`OmniChat_windows_v1.17.0_setup`）。
- **Files Modified**: `lib/core/services/api/chat_api_service.dart`、`lib/features/model/widgets/model_detail_sheet.dart`、`lib/desktop/model_edit_dialog.dart`、`lib/core/providers/model_provider.dart`、`lib/core/providers/settings_provider.dart`、`lib/icons/lucide_adapter.dart`、`lib/features/home/utils/chat_input_button_catalog.dart`、`lib/features/home/widgets/chat_input_bar.dart`、`lib/core/services/chat/chat_turn_service.dart`、`lib/features/home/controllers/chat_actions.dart`、`lib/features/home/services/ocr_service.dart`、`lib/features/home/services/translation_service.dart`、`lib/l10n/*.arb`（+10 keys × 4 語系，`flutter gen-l10n` 重新生成）、`pubspec.yaml`（+`http_parser: ^4.1.2`、version `1.17.0+81`）、`installer.iss`、`CHANGES_LOG.md`、`導入 kelivo 圖片生成模型支援.md`（計畫文件同步實作細節）。
- **Tests**: `test/openai_images_api_test.dart`（NEW，31 案例：輸出模式判斷（id 推斷/override 覆寫/`useImagesApi: false` 關閉/預設開啟/非圖片模型不可 opt-in/非 OpenAI kind 拒絕）、`isOpenAIImageOutputModel`（含開關關閉仍為圖片模型）、`isOpenAIImageEditModel`（input+output 為編輯模型/dall-e-3、sensenova 非編輯/override 覆寫/非 OpenAI kind 拒絕）、開關關閉走 `/chat/completions` 且注入 size、生成/編輯 multipart、jpeg content-type、結構化輸入、dall-e-3 編輯拒絕、base64 存檔/失敗、疊代編輯、非 2xx、size 注入、custom body 優先、dall-e-3 回退附註、`aspect_ratio` 直傳）、`test/settings_provider_image_ratio_test.dart`（NEW，3 案例：預設/round-trip/notify）。

## [v1.16.0] - 2026-08-10: Live API gapless 播放 W0 計時預啟動（timed pre-start）

> 依「IMPLEMENTATION_PLAN_GAPLESS_B」§3.1 執行低成本 workaround（W0）：殘餘包間隙的本質是「player 交接延遲」而非「資料斷供」，W0 以計時預啟動縮短交接，不引入 sink 抽象、不新增 native 程式碼。維持 191p 雙槽架構，目前槽 resume 後依 WAV duration 排定預備槽 resume 於「預期完成時間 − lead」提前觸發；`onPlayerComplete` 保留為保險。Windows 播放行為不變。

- **191t** W0 計時預啟動（`live_api_session.dart`）：
  - `_schedulePreStart`：目前槽 resume 成功後依 `wavDuration`（data bytes ÷ byte rate）排定 timer，於「預期完成時間 − `w0HandoffLead`」提前觸發；包太短（duration ≤ lead）或預備槽未就緒時不排程，回退既有 `onPlayerComplete` 路徑。
  - `_firePreStart`：timer 觸發時沿用 `_switchTo` 與 `_playEpoch` 防護提前 resume 預備槽；目前槽保留為新欄位 `_prev`，其 `onPlayerComplete` 到達時僅釋放資源（`_onSlotComplete` 的 `_prev` 分支），避免提前切換後舊 player 洩漏。
  - 平台旗標：constructor 新增 `enableTimedPreStart`（預設 `defaultTargetPlatform == android`，Windows 維持現況）與 `w0HandoffLead`（實機微調定案 20 ms：80 ms 實測無間隙但輕微重疊 → 逐次下修 50→40→30→20 ms，20 ms 最順暢）。
  - 診斷 log（tag `live-api`）：`play #N start（含 ms 時長）`、`switch #N resume`、`complete #N`、`pre-start #N -> #M fire（lead）`——供實機量測交接延遲（量測點 A/B）。
  - 資源防護：`_flushPlayback`/dispose 取消 timer 並釋放 `_prev`；預啟動 resume 失敗時恢復舊槽為目前槽（避免雙播放或管線卡住）。
- **Status**: W0 完成——**實機測試（2026-08-10，speaker 路徑）20 秒連續語音完全無間隙 ✓；`w0HandoffLead` 逐次下修（80→50→40→30→20 ms）後 20 ms 為最順暢（無間隙、無重疊）→ W0 Gate 達成，不需 B2**；M1–M5（B2 單一連續 PCM 管線）不再啟動。
- **Version**: pubspec `1.16.0+79`；installer.iss 1.16.0（`OmniChat_windows_v1.16.0_setup`）。
- **Files Modified**: `lib/core/services/live/live_api_session.dart`、`test/live_api_session_integration_test.dart`（+1）、`IMPLEMENTATION_PLAN_GAPLESS_B.md`（狀態更新）、`pubspec.yaml`、`installer.iss`。
- **Tests**: `flutter test` full suite **230 tests passed**（v1.15.0 為 229 → +1）；修改檔案 `flutter analyze` **no issues**（全專案 2 個 error 為既有 vendored `speech_to_text_windows` example，與本次無關）。

### 192. Windows AppId 隔離與 CI 品牌統一（OmniChat 品牌化）

> 上游 Kelivo 與 OmniChat 共用同一個 Inno Setup AppId `{A7B8C9D0-E1F2-4A5B-8C9D-0E1F2A3B4C5D}`，導致 Windows 上後安裝的產品覆蓋前者。CI workflow 也沿用 Kelivo 品牌，跨平台產物（APK/IPA/DMG/AppImage/deb/rpm）皆命名為 Kelivo。本次進行全平台品牌一致化。

- **192a** Windows Inno Setup AppId 更換：`installer.iss` 與 CI workflow 中的 AppId 統一換為新 GUID `{40F08C97-A646-4522-A280-D8DD72F4760C}`，與上游 Kelivo 隔離，兩者可共存。
- **192b** CI Windows 安裝程式品牌改為 OmniChat：`MyAppName`、`MyAppExeName`、`OutputBaseFilename`、ZIP 檔名、Release/artifact 路徑全面改為 OmniChat。並修復舊腳本寫死 `kelivo.exe` 而本 repo 實際建置 `OmniChat.exe` 的 bug。
- **192c** CI 跨平台產物品牌改為 OmniChat：Android（`OmniChat_android_*.apk`）、iOS（`OmniChat_ios_*.ipa`）、macOS（`OmniChat.app`、`OmniChat_macos_*.dmg`、volname "OmniChat"）、Linux（`OmniChat_linux_*`、`Name=OmniChat`、`Exec=omnichat`、`Package: omnichat`、`/opt/omnichat`）。
- **Version**: pubspec `1.16.0+80`；installer.iss 1.16.0（`OmniChat_windows_v1.16.0_setup`）。
- **Files Modified**: `installer.iss`、`.github/workflows/build-stable.yml`、`.github/workflows/build-stable-38.yml`、`.github/workflows/build.yml`、`.github/workflows/build-linux-arm64.yml`、`CHANGES_LOG.md`、`pubspec.yaml`。

- **191p** Function calling 與 gapless 連續播放：session 新增 `tools`（setup `functionDeclarations`）與 `toolHandler`；解析 `toolCall` → `pendingToolCalls`（UI 顯示「正在呼叫工具」）→ 執行 handler → `toolResponse`；`toolCallCancellation` 移除 pending；新增 `live_tools.dart` 內建 `get_current_datetime` 工具。播放管線改為雙槽預備播放（`setSource` 預先 prepare 下一個包、完成時 `resume` 切換不重建），並修兩個「目前槽失敗 × 預備槽進行中」的 race（提拔預備槽／預備槽接手），`interrupted`/stop/flush 以 `_playEpoch` 失效清理。
- **191q** Live API 新增 `search_web` 工具：`builtInLiveTools` 宣告 `search_web`（`query` 必填 STRING）；`runBuiltInLiveTool` 改為 async 並傳入 `settings`，直接複用 `SearchToolService.executeSearch`——吃使用者在 LL 對話頁搜尋設定 sheet 選定的搜尋服務（`searchServiceSelected`，與標準聊天共用，不需另設 API key）；含注入 seam `searchExecutor` 供測試，錯誤（空 query／無 settings／executor 拋錯／非 JSON）都回 error map。
- **Version**: pubspec `1.15.0+78`；installer.iss 1.15.0（`OmniChat_windows_v1.15.0_setup`）。
- **Files Modified**: `lib/core/services/live/live_api_session.dart`、`lib/core/services/live/live_tools.dart`（新增）、`lib/features/voice_chat/pages/live_call_screen.dart`、`lib/l10n/*.arb`（+`liveCallToolRunning`）、`test/live_api_session_integration_test.dart`（+9）、`test/live_call_screen_test.dart`（+1）、`test/live_tools_test.dart`（新增，+9）。
- **Tests**: `flutter test` full suite **220 tests passed**（v1.14.0 為 201 → +19）；修改檔案 `flutter analyze` **no issues**。

## [v1.14.0] - 2026-08-09: Live API 半雙工六輪修復（P0–P2）— Windows/Android 穩定化

> 依「Implementation Plan Voice Services Reorganization & Live API Settings v5」§10 執行六輪修復迭代（191h–191m）與 Android 實機修復（191n）：修正輸入取樣率與 PCM 契約、實作可靠 VAD turn 結束、統一 Android/Windows 半雙工音訊初始化、修復播放佇列與資源清理、加入 lifecycle/斷網重連、API Key 遷移至 secure storage 並全面遮蔽診斷資訊、修復 Android 播放模式與音訊 focus。Windows 與 Android 實機測試均通過。`flutter test` 201 tests passed。

- **191h** P0/P1/P2：`RecordConfig.sampleRate` 改為 micSampleRate（16 kHz）並與輸出 24 kHz 分離、PCM frame 對齊與實際格式診斷；行動版 model picker 接住 bottom sheet 回傳值；模型快取以 API Key + endpoint 為 key、Base URL 變更清除、自訂 endpoint 保留 port/path、錯誤訊息遮蔽 API Key。
- **191i** P1：`audio_stream_end`（mute/stop/dispose 依序送出，setupComplete 前不送）；unmute 清空 buffer 不重送舊 PCM；模型播放中不送 mic（半雙工契約）；playerFactory 測試 seam + 10 案例整合測試。
- **191j** P2：LiveCall 與標準語音流程共用 `startCallMode`/`stopCallMode`（audio focus / SCO / speaker 路由）；所有退出路徑（返回/錯誤/重試/goAway/dispose）對稱釋放；`Platform.isAndroid` → `defaultTargetPlatform`。
- **191k** P2：播放佇列——下一個播放包只在上一個完成/失敗後啟動、失敗 dispose player 並記診斷、`_flushPlayback` 二次 dispose 防護、interrupted/stop 清理安全。
- **191l** P2：lifecycle（背景停 mic/前景重啟、背景不播放）與有限次數退避重連（`maxReconnectAttempts`=3、重試前完整 cleanup、`setupComplete` 重設計數）；`LiveCallScreen` 實作 `WidgetsBindingObserver` + reconnecting/background 狀態 UI；新增 `liveCallReconnecting`/`liveCallBackground` l10n。
- **191m** P2：API Key 自 SharedPreferences 遷移至 `flutter_secure_storage`（`LiveApiKeyStore`，舊值自動遷移並清除）；共用 `maskApiKey` 遮蔽 `http.ClientException`/`WebSocketException`/server error；`pubspec.yaml` +`flutter_secure_storage: ^10.3.1`；widget 測試環境需 `FlutterSecureStorage.setMockInitialValues`（未 mock 的 platform channel 永不回傳）。
- **191n** Android 實機修復：`PlayerMode.lowLatency`（SoundPool）不支援 `BytesSource`（`setForSoundPool` 直接 error）→ 改用 `mediaPlayer` 修復模型語音播放；mic `RecordConfig` 設 `audioInterruption: none` 防止 record 在 focus loss 時永久暫停錄音（audioplayers 預設請求 `AUDIOFOCUS_GAIN`）；`--split-per-abi` 產出單一 ABI arm64 APK（`OmniChat_android_v1.14.0_arm64.apk`）。
- **Version**: pubspec `1.14.0+77`；installer.iss 1.14.0（`OmniChat_windows_v1.14.0_setup`）。
- **Files Modified**: 見各 191h–191m 條目；`test/live_api_session_integration_test.dart`（+18）、`test/live_call_screen_test.dart`（+3）、`test/live_call_settings_mobile_test.dart`（+3）、`test/live_api_key_store_test.dart`（+6）、`test/live_api_settings_test.dart`（+3）、`test/live_api_models_service_test.dart`（+4）、`test/live_api_session_test.dart`（+3）。
- **Tests**: `flutter test` full suite **201 tests passed**（v1.13.1 為 165 → +36）；修改檔案 `flutter analyze` **no issues**。Windows 實機測試通過；Android speaker 路徑實機測試通過（Bluetooth 依 §8.4 矩陣仍待驗證）。

## [v1.13.1] - 2026-08-08: Live API Phase B — Model Picker + Real-time Voice Call
## [v1.13.1] - 2026-08-08: Live API Phase B — Model Picker + Real-time Voice Call

> 依「Implementation Plan Voice Services Reorganization & Live API Settings v3」執行 **Phase B**（Live API 通話引擎 + 模型名單）。測試回報兩項問題一併處理：(1) 模型名稱不再依賴手寫，改為從 Gemini REST `/v1beta/models` 抓取名單後於行動版 bottom sheet / 桌面版 dialog 選擇（含重新整理、手動輸入備援）；(2) 輸入列語音聊天按鈕改為跟隨 `voiceCallMode`：Live API 模式且已設定 → 進入新的即時語音通話畫面；未設定金鑰 → SnackBar 提示先完成設定；標準模式維持原 `VoiceChatScreen`。

### 190. Live API Model Picker（行動版 + 桌面版）

- **Purpose**: 新增 `LiveApiModelsService`：以 API Key 呼叫 REST `GET https://{host}/v1beta/models`（host 自 `liveApiBaseUrl` 推導、官方端點回退 `generativelanguage.googleapis.com`），以 `supportsLiveGeneration == true` 或名稱含 "live" 篩選，排序後回傳；記憶體快取 5 分鐘，`setLiveApiApiKey` 變更時清除。
- **UI**: 行動版 Model 欄改為 `_ModelPickerRow`（bottom sheet：載入中 / 錯誤重試 / 清單選取 / 手動輸入）；桌面版改為 `_ModelSelectRow`（dialog 同功能）。
- **Files Modified**: `lib/core/services/live/live_api_models_service.dart`（NEW）、`lib/features/settings/pages/voice_call_settings_page.dart`、`lib/desktop/setting/voice_call_pane.dart`、`lib/core/providers/settings_provider.dart`（`setLiveApiApiKey` 清除模型快取）
- **New test** `test/live_api_models_service_test.dart`（9 案例：篩選邏輯、排序、錯誤回應、快取、自訂 host 推導）

### 191s. 修復：模型輸出字幕（output transcription）未顯示

> 使用者回報：即時對話字幕只顯示聲音輸入的字幕，沒有顯示輸出的字幕。根因：`_onServerMessage` 只解析 snake_case `output_transcription`，而官方文件/server 實際以 camelCase `outputTranscription` 回傳——`assistantPartial` 永遠為空，字幕退回到 `userPartial`（輸入側在 191o 就有 camel fallback 所以正常）。此路徑先前零測試覆蓋。

- **Purpose**:
  - `live_api_session.dart`：output transcription 改為與 input 對稱的雙 casing 解析（`output_transcription` ?? `outputTranscription`），`assistantPartial` 正常累積。
  - 測試補洞：整合測試 +4——snake 累積、**camelCase（本 bug 的實際路徑）**、空字串不累積、turnComplete 提交到 turns；widget 測試 +1——字幕優先序（模型回覆 > 使用者轉錄 > 上一個完成的模型回合）。
- **Files Modified**: `lib/core/services/live/live_api_session.dart`、`test/live_api_session_integration_test.dart`（+4）、`test/live_call_screen_test.dart`（+1）
- **Verification**: `flutter test` 229 passed（+5）；analyze no issues。
- **Note**: 實機驗證（2026-08-09）：模型字幕正常顯示。

### 191r. C 方案：Android 播放器 audioFocus NONE（移除每包 focus 交接，減少包間隙）

> 使用者回報 Android 仍有輕微包間隙（Windows 無感）。調查後確認根因：每 0.5s WAV 包 = 獨立 MediaPlayer，完成時 release（含 abandon audio focus），下一個包要等 complete 事件串行觸發 resume → 重新 requestAudioFocus → MediaPlayer 冷啟動。C1 移除「每包 focus 交接」這個來源（冷啟動仍在，需 B 方案根治）。比較後確認 C 方案為 Android 專屬：Windows（Media Engine）無 focus 機制、加大包對 Windows 是負收益（首包延遲）。

- **Purpose**:
  - `MainActivity.kt`：`omnichat/call_mode` channel 新增 `getCallModeState`——回傳目前路由狀態（`bluetoothConnected`/`audioMode`/`isSpeakerphoneOn`）。
  - `platform_audio_setup.dart`：新增純函式 `buildPlaybackAudioContext` 與查詢 `playbackAudioContext()`。關鍵設計：audioplayers 的 `setAudioContext` 在 Android 會**全域覆寫** `AudioManager.mode`/`isSpeakerphoneOn`，而 call mode 的路由是動態的（藍牙→`MODE_IN_COMMUNICATION`+speakerphone off；喇叭→`MODE_NORMAL`+speakerphone on）——因此 context 必須帶入目前路由值（`audioFocus: NONE` 只關 focus，mode/speakerphone/usage 與 call mode 一致），否則會弄壞藍牙 SCO 或喇叭輸出。未知 audioMode 值安全回退 normal（fromInt 對不到會拋錯）。
  - `live_api_session.dart`：新增 `playbackAudioContext` 參數；預設 player factory 在建立播放器後 fire-and-forget 套用（`setAudioContext` 早於 `setSource` prepare）。測試注入的 fake player factory 不受影響。
  - `live_call_screen.dart`：`startCallMode()` 後查詢並傳入 session。
  - 計畫 §3.3：gapless 條目更新——**B 方案（單一連續 PCM 串流／ExoPlayer 串接）列為正式待實作**以根治；C1 為已實作的 Android 專屬止血。
- **Files Modified**: `android/app/src/main/kotlin/com/psyche/omnichat/MainActivity.kt`、`lib/features/voice_chat/services/platform_audio_setup.dart`、`lib/core/services/live/live_api_session.dart`、`lib/features/voice_chat/pages/live_call_screen.dart`、`test/platform_audio_setup_test.dart`（新增，+4）、`IMPLEMENTATION_PLAN_LIVE_VOICE_V5.md`（§3.3）
- **Verification**: `flutter test` 224 passed（+4）；analyze no issues。
- **Note**: 實機驗證（2026-08-09）：Android speaker 路徑語音間隙明顯變小、路由正常；Bluetooth 路徑仍待驗證（§8.4 矩陣）。冷啟動來源仍在，根治需 B 方案。

### 191q. Live API 新增 search_web 工具（複用既有搜尋服務設定）

> 使用者要求：Live API 語音通話加入 web search 工具。確認機制後實作——直接複用既有 `SearchToolService.executeSearch`，吃使用者已在 LL 對話頁搜尋設定 sheet 選定的搜尋服務（`searchServiceSelected`，Tavily/Brave/Zhipu/Ollama/Exa 之一），不需另設 API key。

- **Purpose**:
  - `live_tools.dart`：`builtInLiveTools` 新增 `search_web` 宣告（`query` 必填 STRING，schema 沿用 Gemini JSON enum 大寫風格）；`runBuiltInLiveTool` 改為 async，新增可選 `settings`（`SettingsProvider`）與注入 seam `searchExecutor`（`LiveSearchExecutor`，預設 `SearchToolService.executeSearch`）。執行流程：空 query / 無 settings → error map；executor 拋錯 → `{'error': 'search failed: ...'}`；非 JSON 回傳 → 原樣 error；成功 → 解析 `{'answer', 'items'}` 回傳給模型。
  - `live_call_screen.dart`：`toolHandler` 傳入 `settings`（`context.read<SettingsProvider>()`），讓 search_web 能解析使用者選定的搜尋服務。
- **Files Modified**: `lib/core/services/live/live_tools.dart`、`lib/features/voice_chat/pages/live_call_screen.dart`、`test/live_tools_test.dart`（新增，+9）
- **Verification**: `flutter test` 220 passed（+9）；analyze no issues；改動檔案維持全 CRLF。
- **Note**: 語音場景下模型會把搜尋結果「講」出來（Live API `toolResponse` 無標準聊天的 citation 渲染機制）。

### 191p. Function calling（工具呼叫）與 gapless 連續播放管線

> 使用者要求：開始實作 Function calling 與 gapless 連續播放（§3.3 待實作清單）。

- **Purpose**:
  - Function calling：`live_api_session.dart` 新增 `tools`（setup `tools.functionDeclarations`）與 `toolHandler`（`LiveToolHandler` typedef）注入；解析伺服器 `toolCall.functionCalls` → `pendingToolCalls` 狀態（供 UI 顯示）→ 非同步執行 handler → `buildToolResponsePayload` 送回 `toolResponse`（handler 拋錯或未註冊時回 `{'error': ...}`）；`toolCallCancellation` 移除 pending call。新增純函式 `extractToolCalls` / `extractCancelledToolIds` / `buildToolResponsePayload`。
  - 內建工具：新增 `lib/core/services/live/live_tools.dart`——`builtInLiveTools`（`get_current_datetime` 宣告）與 `runBuiltInLiveTool`（執行器，未知工具回 error）。
  - UI：`live_call_screen.dart` 接入 `builtInLiveTools` + handler；狀態列顯示「正在呼叫工具：<name>」（l10n `liveCallToolRunning`）。
  - gapless：`_startSlot`/`_primeSlot`/`_switchTo` 雙槽播放管線取代「每包新建 player 並 play」——目前槽播放時以 `setSource` 預先 prepare 下一個槽，完成時直接 `resume` 切換（不重建、無包間隙）；`interrupted`/stop/flush 以 `_playEpoch` 讓 in-flight 操作失效並釋放所有槽。修兩個 edge case：目前槽在預備槽就緒後失敗 → 提拔預備槽；目前槽在預備期間失敗 → 預備槽接手成為目前槽（避免管線卡住）。
- **Files Modified**: `lib/core/services/live/live_api_session.dart`、`lib/core/services/live/live_tools.dart`（新增）、`lib/features/voice_chat/pages/live_call_screen.dart`、`lib/l10n/*.arb`（+`liveCallToolRunning`）、`test/live_api_session_integration_test.dart`（+4 tool、改寫播放測試為 gapless 語意、+1 預備槽釋放）
- **Verification**: `flutter test` 211 passed（+5）；analyze no issues；所有改動檔案維持全 CRLF。

### 191o. Live API 即時對話字幕 — 使用者語音轉錄顯示與字幕開關

> 使用者要求：Live API 支援即時顯示對話文字（官方 API 的 `inputAudioTranscription`/`outputAudioTranscription` 雙向轉錄），並在通話頁面右下角補上字幕開關（參考標準語音模式）。

- **Purpose**:
  - `live_api_session.dart`：解析 `serverContent.input_transcription`（使用者語音即時轉錄）→ 新增 `userPartial` 狀態。與模型側（`assistantPartial` 累加）不同，使用者轉錄是同一句話的遞增/修正文字，採**取代**語意；`turnComplete` 時清除，下一個語句重新填入。新增純函式 `extractInputTranscription`——實測 API 回傳 snake_case（`input_transcription`，與既有 `output_transcription` 一致），官方文件寫 camelCase（`inputTranscription`），兩種 casing 都解析以防 API 變動。空文字訊息不覆寫既有 partial。
  - `live_call_screen.dart`：右下角（原對稱佔位 `SizedBox` 位置）新增字幕開關——`Lucide.Captions` / `Lucide.CaptionsOff` icon，與標準語音模式 `voice_chat_screen.dart` 同款（關閉時保留字幕區塊避免 layout 跳動）。字幕顯示優先序：進行中的模型回覆（`assistantPartial`）→ 使用者語音即時轉錄（`userPartial`）→ 上一個完成的模型回合（`turns.last`）。
- **Files Modified**: `lib/core/services/live/live_api_session.dart`、`lib/features/voice_chat/pages/live_call_screen.dart`、`test/live_api_session_integration_test.dart`（+4）、`test/live_call_screen_test.dart`（+1）
- **New tests**：input transcription 取代語意更新；camelCase `inputTranscription` 亦解析；turnComplete 清除 + 下一語句重新填入；空文字不覆寫；字幕開關切換顯示/隱藏（fake session 覆寫字幕 getter）。
- **Tests**: `flutter test` full suite **206 tests passed**（+5）；修改檔案 `flutter analyze` **no issues**。
- **備註**：使用者側即時轉錄同時是通話紀錄（待實作，§3.3）的前置步驟；若實機發現 input transcription 是 delta 而非完整 partial，將取代語意改為累加即可（已有註解標明）。
### 191n. Live API Android 實機修復 — 播放模式與音訊 focus（實機測試回報 → 已修復並驗證）

> Android 實機測試回報：啟動語音聊天後麥克風 icon 出現、說話完 icon 消失且無任何回應。定位出兩個 Android 專屬根因並修正。

- **Root causes**（均在 Android 專屬路徑，Windows 不受影響，故 Windows 測試正常）：
  - **播放全滅**：`_playNext` 使用 `PlayerMode.lowLatency`——audioplayers 在 Android 的 lowLatency 走 `SoundPoolPlayer`，而 `BytesSource.setForSoundPool()` 直接 `error("Bytes sources are not supported on LOW_LATENCY mode yet.")` → 每個播放包都在 `player.play()` 拋錯 → 模型語音在 Android 上**完全無法播放**（`_playNext` catch 後 dispose 續播，但每個包都失敗，靜默無聲）。
  - **麥克風被暫停**：`record` 套件 Android 的 `AudioSessionManager` 在 `audioInterruption != NONE`（預設 `PAUSE`）時自行 `requestAudioFocus(GAIN)`，且 `onFocusLoss` 會 `pauseRecording()`——而預設 `PAUSE` 中斷模式在 focus 回來時**不會恢復**（只有 `PAUSE_RESUME` 才恢復）→ 播放一旦開始（audioplayers 預設也請求 `AUDIOFOCUS_GAIN`）搶走 focus，mic 就被永久暫停（Android 麥克風使用中 icon 消失）。
- **Fixes**（`lib/core/services/live/live_api_session.dart`）：
  - `_playNext`：改用 `PlayerMode.mediaPlayer`（Android 走 MediaPlayer，支援 BytesSource；Windows 僅支援 mediaPlayer，行為不變）。補播放 start/done 診斷 log（tag `live-api`）。
  - mic `RecordConfig`：設 `audioInterruption: AudioInterruptionMode.none`——錄音器對 audio focus 變化免疫，由 call mode（`startCallMode`/audio_session）集中管理 focus，避免播放模型語音時 mic 被暫停。刻意**不**用 audioplayers 的 `setAudioContext(AudioFocus.none)`：其在 Android 會全域覆寫 `AudioManager.mode` 與 `isSpeakerphoneOn`（`WrappedPlayer.updateAudioContext` / plugin global handler），會破壞 call mode 的 speaker/SCO 路由。
  - mic stream 加 `onDone` 診斷 log（平台側自行結束串流時記錄）。
- **New tests**: 整合測試 `RecordConfig` 案例補 `audioInterruption == AudioInterruptionMode.none` 斷言（防回歸）。
- **Tests**: `flutter test` full suite **201 tests passed**；`flutter analyze` 修改檔案 **no issues**。
- **Artifacts**: `flutter build apk --release --split-per-abi --target-platform android-arm64` → `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`（52.8 MB，複製為根目錄 `OmniChat_android_v1.14.0_arm64.apk`）。已驗證：aapt2 `native-code: 'arm64-v8a'`（單一 ABI）、apksigner OmniChat 憑證簽署、versionName 1.14.0 (77)。註：一般 `--target-platform android-arm64`（無 split）產出的 APK 第三方 native lib 仍含全 ABI（flutter 自己的 libapp/libflutter 正確 arm64-only）——需 `--split-per-abi` 才有真正單一 ABI 產物。
- **實機驗證**：2026-08-09 Android arm64 實機測試通過——說話後可聽到模型語音、麥克風 icon 全程顯示、連續多輪對話正常。若仍有異常，Log Viewer（tag `live-api`）的 mic stats / play start-done / reconnect 原因可定位下一層問題。
### 191m. Live API 第六輪修復 — P2 API Key 安全儲存與診斷遮蔽（§5.8）

> 依「Implementation Plan Voice Services Reorganization & Live API Settings v5」§10 第六輪（§5.8）：API Key 自 SharedPreferences 遷移至 flutter_secure_storage（含舊值自動遷移），並確認所有診斷 log/UI 遮蔽 API Key。

- **Purpose**:
  - 新增 `LiveApiKeyStore`（`lib/core/services/live/live_api_key_store.dart`）：正式值存 `flutter_secure_storage`（Android Keystore / Windows DPAPI，key `live_api_key_secure_v1`）；`read()` 在 secure 無值時自動從舊 SharedPreferences 位置（`live_api_key_v1`）遷移（寫入 secure + 刪除舊值，不留明文殘留）；secure 有值時優先並順手清除殘留 legacy。平台異常（如測試環境未註冊 channel）會 catch 並退回 legacy/null，不中斷設定載入。
  - `SettingsProvider`：`_load()` 與 `setLiveApiApiKey()` 改走 `LiveApiKeyStore`（可注入 fake 供測試）；移除 `_liveApiApiKeyKey` 常數（舊位置僅由 store 作為遷移來源引用）。既有測試僅需在 setUp 加 `FlutterSecureStorage.setMockInitialValues({})`。
  - 診斷遮蔽補洞（共用 `maskApiKey(message, apiKey)`，位於 `live_api_models_service.dart`）：`http.ClientException` 訊息含 request uri（含 `?key=...`）→ models service network catch 先遮蔽；dart:io `WebSocketException` 訊息含完整 uri → session `_connect` catch 與 `_onWsError` 先遮蔽；server error 訊息也過遮蔽層（防回顯）。HTTP 非 200 的 `detail` 沿用既有 `_uriWithoutKey`。
  - 確認無其他洩漏管道：`RequestLogger` 只攔 Dio 流量，Live API models 走 plain `http.Client()` 不會被記錄；UI 輸入框已 `obscureText`；session 診斷 log（mic stats / playback failed / odd frame）不含 key。
- **Files Modified**: `pubspec.yaml`（+`flutter_secure_storage: ^10.3.1`）、`lib/core/services/live/live_api_key_store.dart`（新增）、`lib/core/providers/settings_provider.dart`、`lib/core/services/live/live_api_models_service.dart`、`lib/core/services/live/live_api_session.dart`、`test/live_api_key_store_test.dart`（新增 6 案例）、`test/live_api_settings_test.dart`（+3 案例）、`test/live_api_models_service_test.dart`（+4 案例）、`test/live_api_session_integration_test.dart`（+1 案例）、`test/live_call_settings_mobile_test.dart` / `live_call_screen_test.dart` / `settings_provider_stt_test.dart` / `widget_test.dart`（setUp 加 secure storage mock）
- **New tests**：store 讀寫 round-trip、legacy 遷移（舊值寫入 secure 並清除）、secure 優先於 legacy、write/delete 清除 legacy；provider 層遷移與優先權；`maskApiKey` 遮蔽／無 key 原樣／空 key 原樣；network error detail 不含 key；ws error 訊息不含 key（整合測試，WebSocketException 含完整 uri）。
- **Tests**: `flutter test` full suite **201 tests passed**（+14）；`flutter analyze` 修改檔案 **no issues**。注意：widget 測試環境下未 mock 的 platform channel 呼叫**永不回傳**（非拋錯），`SettingsProvider._load` 現在會 await secure read——所有直接建 provider 的測試 setUp 都需 `FlutterSecureStorage.setMockInitialValues({})`，否則整檔測試卡死。

### 191l. Live API 第五輪修復 — P2 lifecycle、斷網處理與重連（§5.7）

> 依「Implementation Plan Voice Services Reorganization & Live API Settings v5」§10 第五輪（§5.7）：實作 foreground/background/reconnecting/error 狀態機、有限次數退避重連、重試前完整資源清理，背景/前景切換不重複建立資源。

- **Purpose**:
  - `LiveCallState` 新增 `background`、`reconnecting` 兩狀態；`_connect()` 自 `start()` 抽出——`start()`（含錯誤後手動重試）重置重連計數，重連流程呼叫 `_connect()` 不重置。
  - 重連：`_onServerDone`（非預期斷線）/ ws stream error / setup timeout → `_scheduleReconnect()`；server error 訊息維持直接 `error`（auth 類錯誤不重試）。有限次數（`maxReconnectAttempts`，預設 3）+ 指數退避（`reconnectBackoffBase`，預設 1s；`1 << (attempt-1)`）；超過次數進入 `error` 並帶明確訊息（「已重連 N 次仍失敗，請檢查網路後重試」），UI 提供手動重試。`setupComplete` 成功時重設計數，避免多次短暫斷線累加耗盡。
  - 資源安全：`_scheduleReconnect` 與重連 timer 都先 `await _cleanup()` 才建立新連線；`_cleanup()` 改為並發去重（`_pendingCleanup`）且**立即**清空 `_ws` 再關閉舊連線，避免舊 cleanup 誤關新連線；`_onServerMessage`/`_onServerDone`/`_onWsError` 加 `_closing`/`_ws != ws` 防護——不並存多個 recorder/ws/player。
  - lifecycle：`pause()`（進入背景）送 stream end → 停 mic（`_stopMic()`）→ 清播放佇列，**保留 WebSocket**；`resume()` 直接重啟 mic 回 `active`（不需重連）。背景期間伺服器推來的音訊不播放（只累積轉錄）；背景中斷線仍會自動重連。
  - `LiveCallScreen` 實作 `WidgetsBindingObserver`：`paused`/`hidden` → `session.pause()`，`resumed` → `session.resume()`，`inactive`/`detached` 不動作（避免 mic 反覆重啟）；狀態 UI 新增 `reconnecting`（橘色 + 原因文字）與 `background` 顯示。新增 `sessionFactory` 測試 seam。
- **Files Modified**: `lib/core/services/live/live_api_session.dart`、`lib/features/voice_chat/pages/live_call_screen.dart`、`lib/l10n/app_en.arb`、`app_zh.arb`、`app_zh_Hans.arb`、`app_zh_Hant.arb`（+`liveCallReconnecting`/`liveCallBackground`，`flutter gen-l10n` 重新生成）、`test/live_api_session_integration_test.dart`（+5 案例）、`test/live_call_screen_test.dart`（+1 案例）
- **New tests**：斷線後自動重連（新 ws/recorder、舊資源已 close/dispose、新 buffer 不含舊 PCM）；重連次數耗盡進 error 且手動 `start()` 重試成功；server error 不觸發重連；`pause()` 停 mic/送 stream end/背景不播放 + `resume()` 重啟 mic；背景中斷線自動 reconnecting；widget 測試驗證 lifecycle paused/resumed 接到 `session.pause/resume`（`inactive` 不觸發）。
- **Tests**: `flutter test` full suite **187 tests passed**（+6）；`flutter analyze` 修改檔案 **no issues**。

### 191k. Live API 第四輪修復 — P2 播放佇列與資源清理（§5.6）

> 依「Implementation Plan Voice Services Reorganization & Live API Settings v5」§10 第四輪（§5.6）：播放佇列依序播放、播放失敗續播、interrupted/stop/dispose/錯誤的播放清理順序安全。

- **Purpose**:
  - `_playNext()`：下一個播放包只在上一個**完成或失敗**後啟動（`_playing` 旗標 + 完成事件續播）；播放失敗（如 Windows Media Foundation）時 dispose 該 player、以 `live-api` tag 記可診斷 log，再繼續佇列；`setPlayerMode`/`play` 等待期間若被 `flushPlayback` 取代（interrupted/stop/錯誤/goAway），直接放棄該 player，不重設狀態、不續播。
  - 追蹤 `onPlayerComplete` 的 subscription（`_playSub`），flush 時取消；`_flushPlayback()` 對目前 player 依序 `stop()` → `dispose()`，並防護二次 dispose（`_player` 先清 null）。
  - 播放完成事件內 dispose player 後才把 `_playing` 設回 false 並續播——完成與失敗都只會啟動下一個播放包。
- **Files Modified**: `lib/core/services/live/live_api_session.dart`、`test/live_api_session_integration_test.dart`（+4 案例）
- **New tests**（`test/live_api_session_integration_test.dart`）：播放失敗時 dispose 失敗的 player 並由下一個播放包接手；`interrupted` 清空佇列、釋放目前 player，之後新音訊建立全新 player；播放中 `stop()` 釋放 player 且不 crash（stop 後再推音訊也安全）；三個播放包依序播放——每個時刻只有一個 player，前一個 dispose 後才啟動下一個。
- **Tests**: `flutter test` full suite **181 tests passed**（+4）；`flutter analyze` 修改檔案 **no issues**。

### 191j. Live API 第三輪修復 — P2 統一 LiveCall 半雙工音訊初始化（Call Mode 對稱）

> 依「Implementation Plan Voice Services Reorganization & Live API Settings v5」§10 第三輪（§5.4）：明確決定 LiveCall 與標準語音流程**共用** `startCallMode()` / `stopCallMode()`（audio focus、Bluetooth SCO、speaker 路由、mic unmute），開始與所有退出路徑對稱。

- **Purpose**:
  - `LiveCallScreen._init()`：麥克風權限通過後、建立 session 前呼叫 `startCallMode()`（與 `voice_chat_controller.startUp` 的順序一致）。
  - `_end()`（結束鈕 / X）：session stop/dispose → `deactivateAudioSession()` → `stopCallMode()` → pop。
  - `dispose()`（系統返回、goAway 自動關閉、錯誤後離開）：fire-and-forget `deactivateAudioSession()` + `stopCallMode()`——所有退出路徑都釋放 audio focus 與 call mode，通話結束後不再佔用麥克風或音訊焦點。
  - 平台判斷改用 `defaultTargetPlatform == TargetPlatform.android`（取代 `Platform.isAndroid`）：實機行為相同，且 widget 測試可覆寫平台。
- **Files Modified**: `lib/features/voice_chat/pages/live_call_screen.dart`、`test/live_call_screen_test.dart`（NEW，2 案例）
- **New test** `test/live_call_screen_test.dart`：mock `omnichat/call_mode`、`com.llfbandit.record/messages`、`com.ryanheise.audio_session` 三 channel——通話啟動後 `startCallMode` 被呼叫且 audio session 完成 `setConfiguration`；結束鈕觸發 `stopCallMode` 並 pop 畫面；route dispose（替換 widget，等同返回）也觸發 `stopCallMode`。註：`audio_session.setActive` 在非 iOS/Android 主機為 no-op、無法從 channel 觀察，以「釋放路徑完成並 pop」代表 `_end`/`dispose` 的清理有執行。
- **Tests**: `flutter test` full suite **177 tests passed**；`flutter analyze` 修改檔案 **no issues**。

### 191i. Live API 第二輪修復 — P1 `audio_stream_end` 與可靠 VAD Turn 結束

> 依「Implementation Plan Voice Services Reorganization & Live API Settings v5」§10 第二輪（§5.3）執行，並依 §8.2 建立 fake WebSocket / fake recorder / fake player 的 session 整合測試。

- **Purpose**:
  - 新增純函式 `buildAudioStreamEndPayload()`（`realtimeInput.audio_stream_end` 空訊息），通知伺服器輸入串流結束以完成目前 turn 的 VAD 判斷。
  - `setMuted(true)` 送出 stream end；`setMuted(false)` 清空 `_micBuf`（不重送停頓前的舊 PCM）並重新開始音訊串流。
  - `stop()`（`_closeGracefully`）在 `clientClose` 之前先送 stream end。
  - `_sendStreamEnd()` 僅在 `state == active`（setupComplete 後）且連線存在時送出；setupComplete 前、mute、error、ended 都不會誤送。
  - 半雙工輸入抑制維持既有行為（`_playing` 期間 mic chunk 丟棄、播放完成後恢復），本輪以整合測試鎖定契約。
  - 新增 `playerFactory` 測試 seam（與既有 `channelFactory` / `recorderFactory` 對稱），供 fake player 注入。
- **Files Modified**: `lib/core/services/live/live_api_session.dart`、`test/live_api_session_test.dart`（+1 stream_end payload 案例）、`test/live_api_session_integration_test.dart`（NEW，10 案例）、`pubspec.yaml`（dev_dependencies 新增 `stream_channel: ^2.1.2`）
- **New test** `test/live_api_session_integration_test.dart`：以 fake WebSocketChannel（`extends StreamChannelMixin implements WebSocketChannel`）、fake recorder（`extends AudioRecorder`）、fake player（`extends AudioPlayer`）覆蓋——setupComplete 前不送音訊或 stream end、setupComplete 後 audio 送出（mime `audio/pcm;rate=16000`、長度正確）、mute 送 stream end 且 unmute 清 buffer 不重送舊 PCM、模型播放中不送 mic 且播放完成後恢復、`stop()` 依序送 stream end → `clientClose` 並清理 recorder/ws、retry 不重用舊 buffer（重連前清空 mic 暫存）、recorder 啟動失敗保留原始 mic 錯誤、dispose 後不再通知 listener、RecordConfig 為 16 kHz mono PCM16。
- **Tests**: `flutter test` full suite **175 tests passed**；`flutter analyze` 修改檔案 **no issues**。

### 191h. Live API 第一輪修復 — P0 輸入取樣率 / P1 Mobile Model Picker / P2 模型快取 Scope

> 依「Implementation Plan Voice Services Reorganization & Live API Settings v5」第一個修復迭代（§10：輸入取樣率 → 模型 picker → 模型快取）執行，未引入新的播放引擎或任何全雙工行為。

- **Purpose**:
  - **P0（§5.1）**：`_startMic()` 的 `RecordConfig.sampleRate` 原沿用輸出用的 24 kHz，與 mimeType 宣告的 16 kHz 不符（1008/無回應根因之一）。修正為 `micSampleRate`（16 kHz），並將輸出常數更名 `outputSampleRate`（24 kHz），輸入/輸出取樣率明確分離、不再共用 `sampleRate`。
  - **P0 診斷（§5.1 #3/#5）**：`_onMicChunk` 統計實際 mic chunk 長度、每秒 chunk 數、推估取樣率與位元深度，tag `live-api` 寫入 `FlutterLogger`（Settings → Log Viewer）；送出前若 frame 長度為奇數會丟棄 1 byte 維持 PCM16 偶數對齊並記錄。重採樣依計畫「必要時」才加入——待實機 log 確認 plugin 實際輸出 rate 偏離 16 kHz 再評估。
  - **P1（§5.2）**：行動版 `_showModelPicker()` 呼叫 `showModalBottomSheet` 後沒有把回傳值賦給 `picked`（該變數從未被賦值），清單選取與手動輸入都不會保存——改為 `final picked = await ...` 並於 trim 後 `setLiveApiModel()`。
  - **P2（§5.5）**：模型清單快取由「全域單一清單」改為「標準化 API Key + endpoint（scheme/host/port/path）」為 key 的 map；`setLiveApiBaseUrl` 變更時一併清除快取（與 `setLiveApiApiKey` 對稱）；`modelsUri` 保留自訂 endpoint 的 port 與 `/ws/` 之前的 path prefix（官方主機維持根路徑）；HTTP 錯誤訊息改用不含 `key` query 的 URI 顯示，API Key 不再進入 log/UI。
- **Files Modified**: `lib/core/services/live/live_api_session.dart`（RecordConfig→`micSampleRate`、`outputSampleRate`、mic 診斷、frame 對齊、移除未使用 `dart:io` import）、`lib/features/settings/pages/voice_call_settings_page.dart`（picker 回傳值）、`lib/core/services/live/live_api_models_service.dart`（cache scope、`modelsUri`、key 遮蔽、`clientFactory` 測試 hook）、`lib/core/providers/settings_provider.dart`（`setLiveApiBaseUrl` 清除快取）
- **New test** `test/live_call_settings_mobile_test.dart`（3 案例：bottom sheet 清單選取保存、手動輸入保存、重開設定頁後仍顯示已存模型）
- **Tests**: `test/live_api_session_test.dart`（+3：輸入 16k/輸出 24k 分離、mime rate 對齊常數、WAV header 用輸出取樣率）；`test/live_api_models_service_test.dart`（+6：modelsUri 官方/自訂 port/`/ws/` prefix/無效回退、快取按 key 與 host 分開、同 key+endpoint 重用、invalidateCache 全清、HTTP 錯誤 detail 不含 API Key）——`flutter test` full suite **165 tests passed**；`flutter analyze` 上述檔案 **no issues**。

### 191g. Mic Input 16kHz Fix — 1008 "The operation was aborted" Root Cause

- **Purpose**: 通話建立後送出麥克風音訊即被伺服器中止（close 1008 "The operation was aborted"）。分析：
  - 1008 + "aborted" 是 Windows 底層 socket 被 RST 的特徵（ERROR_OPERATION_ABORTED），非伺服器正常 close frame。
  - probe 實測：合成音訊（16k/24k 均宣告正確 rate）完全正常——伺服器只中止**宣告 rate 與實際資料不符**的輸入。
  - `record_windows` 的 `PcmEncoder::Feed` 直接輸出 MF 產生的 buffer；若裝置原生 rate ≠ 宣告值（App 原宣告 24kHz，Windows 裝置常見 44.1k/48k），伺服器解碼違規 → RST。
  - **修正**：麥克風改錄官方原生 **16kHz**（`micSampleRate`），mimeType 宣告 `audio/pcm;rate=16000`；輸出播放維持 24kHz 不變。
- **Verification**: probe 16kHz 合成音訊通過（setupComplete、無 close）；`flutter test` — **150 tests passed**；installer 已重建。
- **Files Modified**: `lib/core/services/live/live_api_session.dart`（`micSampleRate=16000`、`_micChunkBytes=3200`、mimeType、RecordConfig）、`test/live_api_session_test.dart`（rate 斷言 16000）
- **Note**: 若 16kHz 仍 1008，錯誤訊息現在會附註「本機 WebSocket 被中止」提示；下一步需 log 實際 mic 輸出 rate 驗證。

### 191f. RealtimeInput audio Field Fix — 1008 "The operation was aborted"

- **Purpose**: 修正通話建立後送音訊即斷線。以真實 Key probe 實測：
  - 送舊欄位 `realtimeInput.mediaChunks` → 伺服器 1007 拒絕：
    `realtime_input.media_chunks is deprecated. Use audio, video, or text instead.`
  - v1beta `BidiGenerateContentRealtimeInput` 已將音訊欄位改為 **`audio`（Blob：`mimeType`/`data`）**，`media_chunks` 標記 DEPRECATED。
  - `buildRealtimeInputPayload` 改送 `realtimeInput.audio`；`audio_stream_end` 欄位亦已存在（`audio_stream_end`，供後續麥克風暫停使用）。
- **Verification**: probe 實測 `audio` 欄位（24kHz 與 16kHz）均被接受（closeCode=null，無 1008/1007）；合成音訊未觸發伺服器 VAD 屬預期（非語音）。`flutter test` — **150 tests passed**；installer 已重建。
- **Files Modified**: `lib/core/services/live/live_api_session.dart`、`test/live_api_session_test.dart`（`realtimeInput.audio` 斷言）

### 191e. Live API Setup Payload Fix — "connection closed" Root Cause

- **Purpose**: 修復通話啟動即斷線（"connection closed"）。以真實 Key 重現後，伺服器 close code 1007 回報：
  `Unknown name "outputAudioFormat" at 'setup.generation_config': Cannot find field.`
  對照 v1beta `BidiGenerateContentSetup` proto 後修正 `buildSetupPayload`：
  1. **欄位名改 snake_case**：`generation_config` / `response_modalities` / `speech_config` / `voice_config` / `prebuilt_voice_config` / `voice_name`（原 camelCase 全數被拒）。
  2. **移除不存在的欄位**：`output_audio_format`、`audio_input_config` 在 v1beta setup 中不存在（輸出固定 24kHz PCM；輸入格式由 `mediaChunks.mimeType` 宣告）。
  3. **`response_modalities` 改為僅 `["AUDIO"]`**：實測 `gemini-3.1-flash-live-preview` 拒絕 AUDIO+TEXT 組合（1007）。
  4. `_onServerDone` 現在顯示 close code/reason（如 `connection closed (code: 1007, ...)`），不再只顯示泛用訊息。
- **Verification**: 真實 Key 端到端實測：`setupComplete` → 送文字 prompt → **39 個音訊 chunks** → `turnComplete` → 正常關閉（closeCode=null）。`flutter test` — **150 tests passed**；Windows installer 已重建。
- **Files Modified**: `lib/core/services/live/live_api_session.dart`、`test/live_api_session_test.dart`（snake_case payload 斷言）

### 191c. Live API Model List Fix + API Key Show/Hide Toggle

- **Purpose**: 修正模型清單抓取與「顯示/隱藏」API Key 按鈕：
  1. **模型清單抓取失敗（root cause）**：以真實 API Key 實測 `GET /v1beta/models`，發現實際回應**沒有** `supportsLiveGeneration` 欄位，且 Live 模型的 `supportedGenerationMethods` 是 `bidiGenerateContent`（不是 `generateContent`），舊篩選邏輯把所有模型過濾掉 → 空清單誤報「無法取得模型清單」。修正：接受 `bidiGenerateContent` 方法宣告。
  2. **分頁**：官方端點預設僅回傳 50 筆，全部 Live 模型在第 2 頁（`nextPageToken`）——原實作不翻頁。修正：`pageSize=100` + 依 `nextPageToken` 迴圈翻頁（上限 10 頁）。
  3. **誤導性錯誤訊息**：抓取成功但無 Live 模型時，原 UI 顯示通用的「檢查 API Key 與網路」；改為顯示「未找到 Live 模型」專用訊息（行動版 bottom sheet 與桌面版 dialog 同步）。
  4. **API Key 顯示切換**：行動版設定頁與桌面版 `voice_call_pane` 的 API Key 欄位加入眼睛圖示（`Eye`/`EyeOff`）切換明文/遮蔽。
- **Files Modified**: `lib/core/services/live/live_api_models_service.dart`、`lib/features/settings/pages/voice_call_settings_page.dart`、`lib/desktop/setting/voice_call_pane.dart`、`test/live_api_models_service_test.dart`（+2 案例：bidiGenerateContent 真實回應形狀、nextPageToken 翻頁）
- **Verification**: 以真實 API Key 端到端驗證 → 6 個 Live 模型（含 `gemini-3.1-flash-live-preview`、`gemini-3.5-live-translate-preview`）；`flutter test` — **150 tests passed**。

### 191b. Review Fixes — Live API Phase B

- **Purpose**: 審查 Phase B 實作發現並修正 7 項問題：
  1. `LiveApiSession.start()`：麥克風啟動失敗後 `_closing` 被重設為 false、繼續監聽已關閉的 WS，導致 onDone 以通用錯誤覆寫特定 mic 錯誤 → 失敗後立即 return。
  2. `_playNext()` onPlayerComplete：`_flushPlayback()` 已 dispose player 後，stop 觸發的 complete 事件會二次 dispose → 以 `_player != player` 防護（audioplayers 二次 dispose 會拋 StateError）。
  3. `_flushPlayback()`：原本 dispose 後 complete 事件不再觸發、目前播放中的 WAV 暫存檔永不刪除 → 追蹤 `_currentPlaybackFile` 於 flush 時刪除；`p.stop()` 改為 try/catch。
  4. `_onMicChunk()`：`setupComplete` 前即送出音訊（Gemini 協議要求先完成 setup）→ 改為 `_state == active` 才送。
  5. `_cleanup()`：清除 `_micBuf` 殘留（重試時避免送出舊片段）。
  6. `LiveCallScreen.dispose()`：goAway 自動關閉或返回鍵退出時未停用 audio session（Android 持續佔用音訊焦點）→ dispose 時 fire-and-forget `deactivateAudioSession()`。
  7. `LiveApiModelsService`：內部建立的 `http.Client()` 未關閉（連線池洩漏）→ `finally` 中僅對自建 client 執行 `close()`。
- **Files Modified**: `lib/core/services/live/live_api_session.dart`、`lib/features/voice_chat/pages/live_call_screen.dart`、`lib/core/services/live/live_api_models_service.dart`
- **Tests**: `flutter analyze` — clean；`flutter test` — full suite passes (**148 tests**)。

### 191. Live API Real-time Voice Call（Phase B 通話引擎）

- **Purpose**: 新增 `LiveApiSession` 與 `LiveCallScreen`：
  - **Session**：`IOWebSocketChannel` 連至 `resolvedLiveApiBaseUrl?key=`；setup 指定 model / prebuilt voice / `responseModalities: [AUDIO, TEXT]` / 24kHz PCM16 輸入輸出；麥克風 `record` 套件 `startStream`（pcm16bits 24kHz mono、echoCancel）每 100ms 累積為 `realtimeInput` 送出；`serverContent` 的 TEXT parts 累積字幕、AUDIO parts 封裝 WAV（暫存檔）依序播放；`interrupted` 清空播放佇列與未完成句子；`turnComplete` 提交句子；`goAway` / 錯誤 → 乾淨關閉。純函式解析（`extractText` / `extractAudio` / `buildSetupPayload` / `buildRealtimeInputPayload` / `pcm16ToWav` / `buildWebSocketUri`）獨立可測。
  - **Screen**：沿用 `VoiceChatScreen` 視覺（灰黑漸層、狀態列、字幕區）；靜音切換（暫停送 mic）、結束鈕、錯誤重試、mic 權限覆蓋層。
  - **Routing**：`home_page._startVoiceChat()` 依 `settings.usingLiveApi` 分流：standard → 原畫面；liveApi 且 `liveApiConfigured` → `LiveCallScreen`；liveApi 未設定 → warning SnackBar。
- **Files Modified**: `lib/core/services/live/live_api_session.dart`（NEW）、`lib/features/voice_chat/pages/live_call_screen.dart`（NEW）、`lib/features/home/pages/home_page.dart`、`pubspec.yaml`（+`record: ^7.1.1`、+`web_socket_channel: ^3.0.1`；version `1.13.1+76`）、`installer.iss`（1.13.1）、`lib/l10n/app_en.arb` / `app_zh.arb` / `app_zh_Hans.arb` / `app_zh_Hant.arb`（+13 keys、已重新生成 `app_localizations*.dart`）
- **New test** `test/live_api_session_test.dart`（11 案例：URI/query 合併、setup payload、realtimeInput base64、訊息解析、WAV header）
- **Known limits**: 通話內容尚未寫入對話紀錄（留待下階段）；正式環境建議 Ephemeral token / 後端代理（金鑰目前僅本機儲存）。
- **Tests**: `flutter analyze` — no new errors（僅既有 dependency example 2 errors 與既有 info）；`flutter test` — full suite passes (**148 tests**, +20 new)。

## [v1.13.0] - 2026-08-08: Voice Call Phase A — Live API Settings Architecture (Voice Services Hub 3rd Entry)

> 依「Implementation Plan Voice Services Reorganization & Live API Settings v3」執行 **Phase A**（§9 階段 A：5 鍵 + l10n + Hub 擴 3 項 + 設定頁，可獨立合併）。在「語音服務」中樞新增第三個子項「即時語音通話」，含雙模式（標準 / Live API）切換與 Live API 四欄組態（Base URL / API Key / Model / Voice）。所有 Live API 設定存為 `SettingsProvider` 直屬欄位（不寫入 `ProviderConfig`，與既有 TTS / STT 相同做法），故 `ModelProvider.getBalance()` 不會掃描 Live API。Phase B–E（`LiveApiService` / `LiveCallProvider` / 通話 UI / 視訊）需 Gemini API Key 與網路，依計畫暫緩。入口置灰決策：為避免死巷（無金鑰時連設定頁都進不去），Hub 入口與 Live API 模式選項保持可點，無金鑰狀態以桌面卡片 subtitle 與設定頁警示呈現「請先完成 Live API 設定」。

### 186. Voice Call — 5 Keys Persistence (`SettingsProvider`)

- **Purpose**: 新增 `voice_call_mode_v1` / `live_api_base_url_v1` / `live_api_key_v1` / `live_api_model_v1` / `live_api_voice_v1` 五鍵（`SharedPreferences`，後續可遷 `flutter_secure_storage`），並提供 `VoiceCallMode` enum（`standard` 預設 / `liveApi`）與 `VoiceCallDefaults`（官方 `wss://generativelanguage.googleapis.com/ws/...BidiGenerateContent` 端點、預設模型 `gemini-3.1-flash-live-preview`、預設音色 `Kore`、可選音色清單 Kore/Puck/Charon/Aoede/Fenrir/Leda/Orus/Zephyr）。
- **Files Modified**: `lib/core/providers/settings_provider.dart`
- **Key Points**:
  - `liveApiConfigured`（金鑰與模型非空）供後續階段「Live API 入口置灰」判斷；`resolvedLiveApiBaseUrl` 於 Base URL 為空時回退官方端點。
  - 所有 setter 空值清除鍵（`prefs.remove`），模式以 `mode.name` 存字串，`_load()` 對未知值回退 `standard`。

### 187. Voice Call Settings Pages (Mobile & Desktop)

- **Purpose**: 行動版 `VoiceCallSettingsPage` 與桌面版 `DesktopVoiceCallPane`（樣式分別對齊 `stt_services_page.dart` / `stt_services_pane.dart`）：模式選擇兩選項（切換即 `setVoiceCallMode` + SnackBar）；Live API 區僅於 `liveApi` 模式顯示——Base URL / API Key（`obscureText`）/ Model 三欄 + Voice 下拉選擇，`onChanged` debounce 300ms 寫回；金鑰為空顯示 `liveApiNotConfigured` 警示與金鑰本機儲存安全註記；切至 `liveApi` 若無金鑰自動聚焦 Key 欄位。
- **Files Modified**: `lib/features/settings/pages/voice_call_settings_page.dart`（NEW）、`lib/desktop/setting/voice_call_pane.dart`（NEW）

### 188. Voice Services Hub 3rd Entry + Localization

- **Purpose**: 行動版 `VoiceServicesPage` 與桌面版 `voice_services_pane.dart` 各新增第三個入口「即時語音通話」（`Lucide.Phone`）；桌面卡片 subtitle 顯示目前模式（標準語音模式 / Live API 模式），Live API 且未設定金鑰時顯示「請先完成 Live API 設定」。新增 14 個 l10n key（en / zh-Hant / zh-Hans / zh）並重新生成 `app_localizations*.dart`。
- **Files Modified**: `lib/features/settings/pages/voice_services_page.dart`、`lib/desktop/setting/voice_services_pane.dart`、`lib/l10n/app_en.arb` / `app_zh_Hant.arb` / `app_zh_Hans.arb` / `app_zh.arb`

### 189b. Review Fix — Desktop Mode Card Badge Icon

- **Purpose**: 審查發現桌面 `_ModeCard` 原寫法在「標準模式」被選中時 badge 也顯示 `Activity`（脈動）圖示，與 Live API 卡完全相同、造成兩個都是「live」的視覺混淆。修正後各卡保留自身圖示（標準 = `Circle` / Live API = `Activity`），選中狀態僅以 primary tint 區分。
- **Files Modified**: `lib/desktop/setting/voice_call_pane.dart`
- **Tests**: `flutter analyze` — no new errors (UI-only change)。

### 189. Version & Tests

- **Files Modified**: `pubspec.yaml` (version `1.13.0+75`) / `installer.iss` (1.13.0, output `OmniChat_windows_v1.13.0_setup`) / `CHANGES_LOG.md` (this entry)
- **New test** `test/live_api_settings_test.dart`（6 案例：mode 預設與 round-trip、未知 mode 回退 standard、baseUrl/apiKey round-trip 與清空、model/voice 預設與 round-trip、`resolvedLiveApiBaseUrl` 回退官方端點、`liveApiConfigured` 金鑰判斷）
- **Tests**: `flutter analyze` — no new errors (僅既有 dependency example 2 errors 與既有 info warnings)；`flutter test` — full suite passes (**128 tests**, +6 new)。

## [v1.12.0] - 2026-08-08: Dictation Per-Utterance Session Restart (Windows/Android) + STT Plugin Hardening

> 根治「聽寫只對第一句話產出文字」：Windows 與 Android 的連續辨識 session 在送出第一個非空 final 結果後，引擎便不再辨識後續語音（session 仍開啟、不送 notListening、麥克風持續被佔用——UI 顯示聆聽但後續講話沒有文字）。修法與 Voice Chat 每句話重啟的模式一致：每句話（非空 final result）後立即 `stop()` 並重開全新 session（先等 stop 真正完成再 `listen()`，避免 plugin 以「Already listening」忽略 Listen）。另修 Windows STT plugin 的事件 handler 洩漏（每次重啟重複註冊、事件倍數觸發）並新增檔案 log 以便診斷（OmniChat 為 GUI 應用，stdout 無 console 可依附、`std::cout` 全部遺失）。Windows 先以裝置實測驗證（Hello / Good morning / How are you / I'm fine / Thank you / You're welcome 逐句產出並接續），Android 實測確認相同問題後移除平台閘門、一併套用。

### 182. Dictation Per-Utterance Session Restart (All Platforms)

- **Purpose**: Windows 與 Android 的連續辨識 session 只對第一句話輸出結果：第一次非空 final 送出後引擎不再辨識。在 onResult 收到非空 final result 後，把本句併入接續基底（`_preDictationText = newText`，下一句才不會覆蓋前文），並立即 `stop()` + 重新 `listen()` 開全新 session，讓後續語句持續被辨識。
- **Files Modified**:
  - `lib/features/home/controllers/home_page_controller.dart` (onResult 對所有平台處理每句話重啟；新增 `_restartDictationAfterFinal()` / `_restartDictationAfterFinalAsync()` / `_stopDictationEngine()`；新增 `_dictationRestarting` / `_dictationStopFuture` / `_disposed` 旗標；`pauseDictation` / `stopDictation` / `dispose` / `resumeDictation` 改走共用 `_stopDictationEngine()`)
- **Key Points**:
  - **每句話重啟**：`_restartDictationAfterFinal()` 以 `_dictationRestarting` 重入旗標防重複重啟；重啟過渡期忽略舊 session 殘留的 partial（避免疊字），`finally` 復位。
  - **先停完再聽**：`_stopDictationEngine()` 以 in-flight future 去重，暫停恢復與每句話重啟共用——一律等待 plugin 的 `m_isListening` 歸零再 `listen()`，修掉「暫停後快速恢復沒反應」的競態（log 中可見 Listen called 之後沒有 StartListeningAsync）。
  - **dispose 防護**：`_disposed` 旗標擋下 dispose 後到達的異步回調，不再觸發 notifier。
  - **套件層去重確認**：speech_to_text `_notifyResults` 送出第一個 final 後設 `_notifiedFinal`，後續所有結果（含 Android `stop()` 觸發的補送 final）直接丟棄，不會重複文字或重複重啟。
  - **平台**：先僅桌面驗證（Windows 實測多句話逐句產出），Android 裝置實測確認相同「每 session 一句話」行為後移除 `isDesktopPlatform` 閘門、所有平台一致處理（iOS 沿用同一路徑，未另行驗證）。

### 183. Windows STT Plugin — Event Handler Leak Fix & File Logging

- **Purpose**: 每個 `StartListeningAsync` 都在同一個 recognizer / continuous session 上重新註冊事件 handler 卻從不撤銷舊 token，導致每次重啟（voice chat 與新的聽寫每句話重啟）handler 無限累積——`stt_plugin.log` 實測可見 `ResultGenerated` / `Session Completed` 重複次數隨句數成長（1→2→3→4→6→8），最終造成重複文字與效能劣化。另因 GUI 應用無 console，`std::cout` 輸出全部遺失，新增直接寫檔的診斷 log 讓行為可稽核。
- **Files Modified**:
  - `dependencies/speech_to_text_windows/windows/speech_to_text_windows_plugin.cpp` (新增 `OmniLog` / `OmniLogFilePath` / `NowStamp` 檔案 log 基礎設施與各事件點 log；`StartListeningAsync` 註冊 handler 前先撤銷舊 `EventRegistrationToken`（HypothesisGenerated / ResultGenerated / Completed，與解構子相同模式）)
- **Key Points**:
  - **Token 撤銷**：`if (m_xToken) recognizer.xxx(m_xToken); m_xToken = {};` 撤銷後清空成員，避免失效 token 殘留或重複撤銷；包 try/catch，撤銷失敗不阻斷聆聽。
  - **檔案 log**：`OmniLog` 每次事件直接開檔、append、關檔（含 HH:MM:SS.mmm 時間戳），寫入 `%LOCALAPPDATA%\OmniChat\stt_plugin.log`（回退 TEMP）——不受 stream 緩衝與 console 有無影響，release 模式同樣可診斷。
  - **兩條路徑一併受惠**：voice chat 與聽寫共用同一 plugin，handler 洩漏修復同時涵蓋兩者。

### 184. Version & Tests

- **Files Modified**: `pubspec.yaml` (version `1.12.0+74`) / `installer.iss` (1.12.0, output `OmniChat_windows_v1.12.0_setup`) / `CHANGES_LOG.md` (this entry)
- **Tests**: `flutter analyze` — no new errors (15 pre-existing info only); `flutter test` — STT 相關套件全過 (stt_locale_resolver / settings_provider_stt / voice_chat_windows / network_stt, 20 tests)。

### 185. Remove "Add" Button from STT Settings Pages (Third-party not yet supported)

- **Purpose**: 第三方 STT 轉錄尚未實作（目前僅設定管理架構：UI + 資料模型 + 持久化），為避免使用者誤以為可新增並使用第三方語音辨識服務，移除行動版與桌面版「語音辨識」頁面右上角的「+」新增按鈕；第三方區塊的空狀態文案由「尚未新增任何語音辨識服務」改為「第三方語音辨識尚未開放」，不再暗示可新增。已存在的第三方服務（舊版本留下的設定）仍可編輯/刪除/選用，但無新增入口。
- **Files Modified**:
  - `lib/features/settings/pages/stt_services_page.dart` (移除 AppBar 右上角「+」按鈕與 `_showAddNetworkSttSheet` 死碼)
  - `lib/desktop/setting/stt_services_pane.dart` (移除標題列右側「+」按鈕與 `_showAddNetworkDialog` 死碼；標題列簡化；檔案註解更新)
  - `lib/l10n/app_en.arb` / `app_zh_Hant.arb` / `app_zh_Hans.arb` / `app_zh.arb` (+ regenerated `app_localizations*.dart`): 移除不再使用的 `sttServicesPageAddTooltip`；`sttServicesPageNoNetworkServices` 改為「第三方語音辨識尚未開放」(en: "Third-party speech recognition is not available yet")
- **Tests**: `flutter analyze` — no new errors (僅既有 dependency example 2 errors 與既有 info warnings)；`flutter test` — STT 相關套件全過 (network_stt / stt_locale_resolver / settings_provider_stt, 19 tests)。


## [v1.11.1] - 2026-08-07: Inline Dictation Pause/Resume + Silence Watchdog Auto-Pause

> 輸入列語音聽寫右側新增「暫停/播放」按鈕，並以「靜音看門狗」偵測系統語音引擎的靜默結束（Android/iOS 約 7 秒、Windows/macOS/Linux 約 60 秒無新辨識結果）自動切為暫停（icon 變「播放」）；按下播放重新開啟聆聽並續接既有文字。聽寫模式的送出按鈕 icon 由打勾改為向上箭頭，符合「送出」語意。背景：Android 的 timeout/status callbacks 不可靠（v1.5.14 曾因此 revert 自動暫停），因此採用純看門狗計時器，不依賴引擎通知。

### 179. Dictation Send Icon → Up Arrow & Pause/Play Button Row

- **Purpose**: 聽寫模式右側按鈕改為三顆：停止、暫停/播放、送出；送出 icon 由 `Lucide.Check` 改為 `Lucide.ArrowUp` 以符合「送出」語意。暫停時中間按鈕顯示「播放」、聆聽中顯示「暫停」（tooltip 本地化為「暫停聽寫」/「繼續聽寫」）。
- **Files Modified**:
  - `lib/features/home/widgets/chat_input_bar.dart` (dictating 分支改為三按鈕 Row；新增 `dictationPaused` / `onToggleDictationPause` 參數；右側寬度計算改 `normalButtonW*3 + spacing*2`；送出 icon → `Lucide.ArrowUp`)
  - `lib/features/home/widgets/chat_input_section.dart` (新增參數傳遞)
  - `lib/features/home/pages/home_page.dart` (接線 `dictationPaused` / `onToggleDictationPause`)
  - `lib/l10n/app_en.arb` / `app_zh_Hant.arb` / `app_zh_Hans.arb` / `app_zh.arb` (+ regenerated `app_localizations*.dart`): `chatInputBarPauseDictationTooltip` / `chatInputBarResumeDictationTooltip`

### 180. Silence Watchdog — Auto-Pause When Listening Ends Silently

- **Purpose**: 系統語音引擎靜默結束聆聽（無 onStatus/onResult 通知）時，UI 不再卡在「聆聽中」；改用平台化靜音看門狗自動進入暫停狀態，按下播放可重新開啟聆聽。
- **Files Modified**:
  - `lib/features/home/controllers/home_page_controller.dart` (三態狀態 `_dictationPaused`；`_dictationWatchdogTimer` 每次收到辨識結果即重置，超過平台靜音上限無新結果 → `pauseDictation()`；提取 `_startDictationListening()` 供 start/resume 共用並啟用 `partialResults: true`；`pauseDictation()` 先捕捉目前文字作為 resume 接續基底再 `stop()`；`resumeDictation()` 重新 `listen()`；`stopDictation()`/`dispose()` 一律取消計時器並釋放麥克風)
- **Key Points**:
  - 平台靜音上限：行動（Android/iOS）7 秒、桌面（Windows/macOS/Linux）60 秒，以既有 `PlatformUtils.isDesktopTarget` 判斷。
  - **重複追加防護**：暫停後 Android `stop()` 可能補送 final result，onResult 開頭以 `if (_dictationPaused) return;` 忽略，避免 `_preDictationText` 已含相同文字造成重複。
  - **async gap 防護**：看門狗在 `listen()` 前一刻啟動；locale 解析 await 期間若已被暫停/結束則不再啟動聆聽。
  - 暫停狀態下送出/停止按鈕維持可用（送出 = 停聽寫並送文字；停止 = 結束聽寫）。

### 181. Version & Tests

- **Files Modified**: `pubspec.yaml` (version `1.11.1+73`) / `installer.iss` (1.11.1, output `OmniChat_windows_v1.11.1_setup`) / `CHANGES_LOG.md` (this entry)
- **Tests**: `flutter test` — full suite passes (122 tests); `flutter analyze` no new errors.

## [v1.11.0] - 2026-08-07: Voice Services Hub + STT Settings Architecture

> 依「語音服務重構與語音辨識（STT）擴充計畫 v2」執行。建立「語音服務」中介頁面（行動/桌面兩層導覽一致）、系統 STT 語言覆寫設定（同時影響 Voice Chat 與 Dictation）、第三方 STT 服務的設定管理架構（OpenAI Whisper / Groq Whisper）；網路轉錄明確排除於本次，第三方服務僅儲存設定並標示「尚未支援轉錄」。

### 174. Voice Services Hub — Unified Two-Level Navigation (Mobile & Desktop)

- **Purpose**: Introduce an intermediate "Voice Services" settings page on both platforms so TTS (語音朗讀) and STT (語音辨識) live under one roof, with identical UX on mobile and desktop.
- **Files Modified**:
  - `lib/features/settings/pages/voice_services_page.dart` (NEW — mobile two-entry page: 語音朗讀 → `TtsServicesPage`, 語音辨識 → `SttServicesPage`)
  - `lib/features/settings/pages/settings_page.dart` (models & services card: TTS row replaced by 語音服務 row → `VoiceServicesPage`)
  - `lib/desktop/setting/voice_services_pane.dart` (NEW — desktop intermediate pane: two hoverable cards that switch **in place** to `DesktopTtsServicesPane` / `DesktopSttServicesPane`, with a back affordance)
  - `lib/desktop/desktop_settings_page.dart` (`_SettingsMenuItem.tts` renamed to `voiceServices`; sidebar icon `Volume2` → `Mic`; switch cases updated)
- **Key Points**: 桌面版保留中介層（與行動版一致），以 pane 內切換呈現，而非砍掉中介層。

### 175. STT Settings Pages (Mobile & Desktop)

- **Purpose**: Speech recognition service management with the system STT entry (non-deletable) and third-party provider cards flagged as not-yet-implemented for transcription.
- **Files Modified**:
  - `lib/features/settings/pages/stt_services_page.dart` (NEW — mobile: system STT row + language config sheet, network service CRUD, selected/delete interactions)
  - `lib/desktop/setting/stt_services_pane.dart` (NEW — desktop adaptation, hoverable card style aligned with `tts_services_pane.dart`)
- **Key Points**: 系統STT 語言對話框透過 `speechToText.locales()` 取得系統語言列表（含「自動」選項）；**空列表防護**：`locales()` 回空（Windows WinRT 限制）或拋錯時，不顯示空對話框，直接視為「自動」並顯示 `sttLanguageNoLocalesMessage`。第三方卡片顯示「尚未支援轉錄」標示。

### 176. STT Data Model & SettingsProvider Persistence

- **Purpose**: Mirror the `TtsServiceOptions` hierarchy for STT configuration with SharedPreferences persistence.
- **Files Modified**:
  - `lib/core/services/stt/network_stt.dart` (NEW — `NetworkSttKind { openaiWhisper, groqWhisper }`, abstract `SttServiceOptions` with stable `id` / `enabled` / `name` / `kind` + `toJson`/`fromJson`, `OpenAiWhisperSttOptions` (base `https://api.openai.com/v1/audio/transcriptions`, model `whisper-1`), `GroqWhisperSttOptions` (base `https://api.groq.com/openai/v1/audio/transcriptions`, model `whisper-large-v3`))
  - `lib/core/providers/settings_provider.dart` (prefs keys `stt_services_v1` / `stt_selected_v1` / `stt_system_locale_v1`; `_sttServices` / `_sttServiceSelected` (-1 = System STT) / `_sttSystemLocaleId` (null = auto); getters/setters, load & out-of-range convergence mirroring TTS)

### 177. STT Locale Resolution Integration (Voice Chat + Dictation)

- **Purpose**: Both voice chat and inline dictation now honor the user-configured speech recognition language.
- **Files Modified**:
  - `lib/features/voice_chat/services/stt_locale_resolver.dart` (explicit `sttSystemLocaleId` takes priority over auto matching; **cache key now includes `systemSttLocaleId`** so mid-session settings changes take effect; `locales()` exception path fixed to still run the forced fallback instead of returning null)
  - `lib/features/home/controllers/home_page_controller.dart` (dictation creates its own `SttLocaleResolver` bound to its dedicated `SpeechToText.withMethodChannel()` instance per X1, and passes `localeId` to `listen()`; failure degrades to platform default)
- **Key Points**: 語音對話路徑原先已在 `voice_chat_controller.dart` 使用 resolver；本次讓 Dictation 路徑也納入語言解析（原僅 Voice Chat）。

### 178. Localization, Tests & Docs

- **Files Modified**:
  - `lib/l10n/app_en.arb` / `app_zh_Hant.arb` / `app_zh_Hans.arb` / `app_zh.arb` (+ regenerated `app_localizations*.dart`): `settingsPageTts` 改為「語音朗讀」；新增 `settingsPageVoiceServices`（語音服務）、`settingsPageStt`（語音辨識）與完整 `sttServices*` / `sttLanguage*` key 家族
  - `test/network_stt_test.dart` (NEW — 8 tests: JSON round-trip per kind, unknown-kind fallback, kind defaults, display names, unique ids)
  - `test/stt_locale_resolver_test.dart` (NEW — 7 tests: explicit > auto, override priority, auto matching, **cache invalidation on locale change**, empty-list fallback, zh-Hant fallback, `locales()` exception fallback)
  - `test/settings_provider_stt_test.dart` (NEW — 5 tests: `stt_services_v1` / `stt_selected_v1` / `stt_system_locale_v1` persistence round-trips, out-of-range selection convergence, `selectedSttService` bounds)
  - `pubspec.yaml` (version `1.11.0+72`) / `installer.iss` (1.11.0) / `CHANGES_LOG.md` (this entry; 隱私註記：本次未實作網路轉錄，無音訊外送)
- **Tests**: `flutter test` — full suite passes (122 tests, +20 new); `flutter analyze` no new errors.


## [v1.10.2] - 2026-08-07: Phase 3 Structural Refactor + Runtime Type Regression Fix

> 依「OmniChat Voice Chat Mode 優化計畫 v2」執行 Phase 3（結構重構 3.1–3.3）。重構後實測發現 voice chat 卡在 listening 不回覆、結束對話卡住——根因是 `buildApiMessages` 的執行期型別錯誤（Phase 3 回歸，`flutter analyze` 與既有測試都抓不到），已修復並補上回歸測試；另依使用者要求移除除錯用 AppLog。對應底部 v1.10.2 摘要條目（#171–#173）。

### 171. Phase 3 — Structure Refactor (3.1–3.3)

- **Purpose**: Split the 1397-line `voice_chat_screen.dart` god class, remove the dead `VoiceChatProvider`, and extract a reusable LLM turn-sending service.
- **Files Modified**:
  - `lib/features/chat/voice_chat_provider.dart` (deleted, 68 lines)
  - `lib/core/services/chat/chat_turn_service.dart` (new: context assembly, system prompt injection, search tool injection, `sendMessageStream` wrapper with cancel handle, 300ms streaming persist throttle)
  - `lib/features/voice_chat/controllers/voice_chat_controller.dart` (new: state machine listening/thinking/talking, pause semantics, X1/X2 invariants)
  - `lib/features/voice_chat/services/stt_locale_resolver.dart` (new: Task 2.8 locale resolution + cache)
  - `lib/features/voice_chat/services/platform_audio_setup.dart` (new: audio session / background service / call mode)
  - `lib/features/voice_chat/pages/voice_chat_screen.dart` (1397 → ~200 lines, UI only)
  - `lib/main.dart`、`lib/features/home/pages/home_page.dart`（移除 provider 註冊）
- **Key Points**: `VoiceChatState` enum 唯一來源移至新 controller；X1（專屬 `SpeechToText.withMethodChannel()` 實例）保留。

### 172. Regression Fix — buildApiMessages Runtime Type Error (voice chat stuck at listening)

- **Symptom**: Phase 3 後語音辨識收到但永不離開 listening、無回應；結束語音對話卡住。
- **Root Cause**: `buildApiMessages` 宣告回傳 `List<Map<String, dynamic>>`，但 map literal 執行期被推斷為 `_Map<String, String>`；`prepareTurnRequest` 的 `apiMessages.insert(0, {'role': 'system', ...})` 因此拋出 `type '_Map<String, dynamic>' is not a subtype of type 'Map<String, String>' of 'element'`（純執行期錯誤，`flutter analyze` 無法攔截）。
- **Fix**: map literal 明確標註 `<String, dynamic>{...}`。
- **Files Modified**:
  - `lib/core/services/chat/chat_turn_service.dart`

### 173. Debug Cleanup & Regression Test

- **AppLog removed**: `lib/core/utils/app_logger.dart` 刪除；4 個 voice-chat/chat-turn 檔案的 ~90 處 `AppLog.d/i/e` 與 import 全部移除（除錯用，依使用者要求）。
- **New test** `test/chat_turn_service_test.dart`（4 案例）：
  - `buildApiMessages` role 映射 + 空內容過濾、版本收斂（`_collapseVersions`）
  - **回歸守門員**：`prepareTurnRequest` 注入 system prompt 於 index 0 且不拋型別錯誤（已驗證：還原型別註記時測試會以與 Phase 3 完全相同的錯誤訊息失敗）
  - 無 system prompt 時訊息原樣傳遞
- **Note**: 除錯期間加的臨時卡死防護（requestId cancel、3s timeout、turn handle 120s watchdog）已於根因修復後移除；TTS 120s watchdog（Task 2.6）為正式功能保留。

## [v1.10.1] - 2026-08-06: Voice Chat Optimisation Plan — Phase 1/2 Completed + Out-of-Plan Fixes

> 依「OmniChat Voice Chat Mode 優化計畫 v2」執行：Phase 1（1.1–1.6）與 Phase 2（2.1–2.8）全部按計畫落地，另有 4 項計畫外修復（X1–X4），均隨 v1.10.1 發布（commits `c82a8886` + `61139970`）。Phase 3（結構重構）尚未執行，追蹤於計畫文件。此處為逐項補記；對應底部 v1.10.1 摘要條目（#168–#170）。

### 168. Phase 1 — Silence/Session Auto-Resume & Listening Loop Stability (1.1–1.6)

- **Purpose**: Make the voice chat listening loop seamless — automatically resume listening after silence or native session end, without dead-loops or a frozen UI — and remove the now-redundant `pauseFor` on all platforms.
- **Files Modified**:
  - `lib/features/voice_chat/pages/voice_chat_screen.dart` (1.1–1.6: auto-resume, subtitle toggle, no-conversation branch, cleanup completeness, mounted guards, `pauseFor` removal)
  - `lib/features/home/controllers/home_page_controller.dart` (1.6: dictation `listen()` no longer passes `pauseFor`)
- **Details**:
  - **1.1 Auto-resume**: `notListening`/`done` status (and benign timeout/no-match errors) now schedule `_resumeListening` via a 250ms debounce (`_scheduleResumeListening`). A `_consecutiveEmptyResumes` counter guards against mic/engine failure loops — after 5 consecutive empty resumes the UI auto-pauses instead of looping forever. `_manualStopInProgress` suppresses auto-resume after an explicit user stop.
  - **1.2 Subtitle toggle**: the captions button now actually toggles the subtitle text (the block is retained to avoid layout jumps).
  - **1.3 No-conversation branch**: the missing-active-conversation error path routes through `_startVoiceRecognitionAfterProcessing`, resetting `_isProcessingVoiceInput` so dictation never freezes permanently.
  - **1.4 Cleanup completeness**: `_cleanup()` fully stops TTS, cancels the in-flight LLM stream subscription (`_streamSub`) and completes the `_streamDone` completer so the DB write-back (`isStreaming: false`) always runs.
  - **1.5 Mounted guards**: every `setState` is preceded by a `mounted` check.
  - **1.6 `pauseFor` removed**: both `listen()` calls (voice chat + dictation) drop `pauseFor` — the package default is `null`. Native engines on Windows and Android both detect end-of-speech themselves (Android measured to finish immediately as well), so the 7-second virtual timer was redundant on both platforms.
- **Tests**: `flutter test` — full suite passes (99 tests); manual regression on Android + Windows (second-round silence no longer auto-pauses at 5–7s).

### 169. Phase 2 — Pause Semantics, Permission Guidance & TTS Watchdog (2.1–2.8)

- **Purpose**: Tighten pause/resume semantics, add proper localization, guide users out of permanently-denied microphone permission, and harden the TTS playback path.
- **Files Modified**:
  - `lib/features/voice_chat/pages/voice_chat_screen.dart` (2.1 pause semantics, 2.5 dead `_voiceStopTimer` removal, 2.6 TTS watchdog, 2.7 back-button cleanup, 2.8 STT locale caching)
  - `lib/core/utils/app_logger.dart` (NEW — `AppLog.d/i/e`, debug-only) (2.4)
  - `lib/l10n/app_en.arb` / `app_zh.arb` / `app_zh_Hans.arb` / `app_zh_Hant.arb` (+ regenerated `app_localizations*.dart`) (2.2, 2.3)
- **Details**:
  - **2.1 Pause semantics**: pausing now interrupts the running LLM stream (cancels the subscription and completes the stream-done completer) and stops TTS; resuming returns to `listening`, resets the empty-resume counter, and restarts recognition (unless voice input is still being processed).
  - **2.2 Localization**: `voiceChatPaused` added to en / zh / zh-Hans / zh-Hant.
  - **2.3 Permanently denied permission**: the microphone overlay now calls `openAppSettings()` and shows `voiceChatPermissionOpenSettings` / `voiceChatPermissionDeniedSubtitle` instead of retrying a denied permission endlessly.
  - **2.4 AppLog**: new `lib/core/utils/app_logger.dart` (debug-only `AppLog.d/i/e`); speech engine init uses `debugLogging: kDebugMode`.
  - **2.5 Dead code**: unused `_voiceStopTimer` field removed.
  - **2.6 TTS watchdog**: `ttsProvider.speak()` is wrapped in a 120-second timeout; on timeout TTS is force-stopped and the loop returns to listening.
  - **2.7 Top back button**: the app-bar ✕ now runs the full `_endVoiceChat` cleanup before popping, matching the center stop button.
  - **2.8 Locale caching**: `_resolveSttLocale()` caches the resolved locale keyed by `appLocale` + `isFollowingSystemLocale`, so repeated listens no longer re-query the engine's locale list.

### 170. Out-of-Plan Fixes (X1–X4)

- **Purpose**: Fixes discovered while executing Phase 1/2, shipped with v1.10.1.
- **Files Modified**:
  - `lib/features/voice_chat/pages/voice_chat_screen.dart` (X1, X2)
  - `lib/features/home/controllers/home_page_controller.dart` (X1 — dictation dedicated STT instance)
  - `dependencies/speech_to_text_windows/windows/speech_to_text_windows_plugin.cpp` (X3)
  - `windows/CMakeLists.txt` (X4)
  - `installer.iss` / removed `installers/omnichat_setup.iss` (installer unification)
- **Details**:
  - **X1 Singleton listener bug**: `SpeechToText` is a singleton whose `initialize()` only registers `onStatus`/`onError` on the first successful call; at app start the `VoiceChatProvider` had grabbed that first registration without listeners, so the screen handlers never fired and the UI froze on "Listening" after silence. Voice chat and dictation now each use a dedicated `SpeechToText.withMethodChannel()` instance so events always route to the active screen.
  - **X2 Cancel/resume dead loop**: `onResult` used to set `_isListening = false` early, which skipped `stop()` and kept the native mic hot during thinking/TTS (Windows tray mic stayed lit); forced cancels produced `notListening` events that triggered auto-resume → cancel → infinite loop (UI auto-paused after 5–7s of silence). Fixed by keeping `_isListening = true` so `stop()` actually executes, adding the `_resumeLocked` gate to ignore self-produced `notListening`, an empty-result gate, and an `onResult` re-entry guard. Auto-pause now also stops the native session so the UI state and mic state never diverge.
  - **X3 Windows 60s silence timeout**: pure silence no longer interrupts at ~7s. `InitialSilenceTimeout` (60s) is set after `CompileConstraintsAsync` so dictation constraint compilation can't reset it; added `Session Completed, status: N` diagnostics.
  - **X4 CMake install prefix**: hard-coded `runner/Release` replaced with `$<TARGET_FILE_DIR:${BINARY_NAME}>`, fixing debug builds / `flutter run` missing `flutter_windows.dll`.
  - **Installer unification**: `installers/omnichat_setup.iss` deleted (root cause of 32-bit → Program Files (x86) installs); root `installer.iss` is now the single 64-bit source.
- **Tests**: `flutter test` — full suite passes (99 tests); `flutter analyze` clean.

## [v1.9.0] - 2026-08-05: ZIP Extraction, Markdown Table Output & PDF Generation

### 164. `file_extract_zip` Workspace Tool

- **Purpose**: Add a `file_extract_zip` workspace tool so the LLM can unpack batch-uploaded archives inside the workspace, with strict Zip-Slip defenses and decompression-bomb limits. Reuses the existing `archive` dependency — no new packages.
- **Files Modified**:
  - `lib/core/services/file/file_tool_service.dart` (`file_extract_zip` schema, dispatch case, `_extractZip`: source cap 100 MB, total decompressed cap 50 MB, entry cap 1000, per-entry `..`/absolute-path rejection, `_rejectBlockedExtension` per entry, header-size pre-check + post-decompression size re-check, validation-before-write pass with best-effort cleanup, default destination = archive stem folder, forward-slash normalized listing capped at 100 entries)
  - `lib/features/home/services/message_builder_service.dart` (workspace prompt: `file_extract_zip` documented)
  - `test/file_tool_service_test.dart` (ZIP tests: default & explicit destination, Zip-Slip rejection, blocked extensions, malformed/missing archives, entry-count limit, non-file path)
  - `README.md` / `README_ZH_TW.MD` (Workspace section)
  - `CHANGES_LOG.md` (this entry)
  - `pubspec.yaml` (version `1.9.0+68`)
  - `installer.iss` / `installers/omnichat_setup.iss` (installer version `1.9.0`)
- **Details**:
  - **Zip-Slip defense**: every entry name is normalized (`\` → `/`), rejected when absolute or containing a `..` segment, blocked when the extension is dangerous, and the final path is resolved through the existing `resolveSafePath()` boundary check before any write.
  - **Zip-bomb defense**: the archive central directory is parsed first; `entry.size` (uncompressed) is summed against the 50 MB total cap **before** any entry is decompressed, and a second check on the actual decompressed length runs during extraction.
  - **Transactional validation**: all entries are validated before the first file is written; failures abort with an `Error` result and best-effort cleanup of partial output.
  - **Default destination**: omitted `destination` extracts into a folder named after the archive next to it (e.g. `bundle.zip` → `bundle/`).

### 165. DOCX / PPTX / XLSX Output as Markdown Tables

- **Purpose**: Upgrade `DocumentTextExtractor` so tables in DOCX, PPTX, and XLSX files are returned as structured Markdown tables (`| col1 | col2 |` with a header separator) instead of flattened text / `A1: value` cell references, making spreadsheet and document analysis dramatically more reliable for the LLM.
- **Files Modified**:
  - `lib/core/services/chat/document_text_extractor.dart` (shared `_tableToMarkdown` / `_markdownCell` helpers with cell truncation & column caps; DOCX `_docxBlockLines` walks `w:body` children in order, renders `w:tbl` as tables and excludes table-internal paragraphs from the plain loop; PPTX `_pptxBlockLines` walks slide descendants, renders `a:tbl` as tables and skips paragraphs inside tables, preserving the per-slide text-run cap; XLSX `_sheetTableLines` preserves column positions from cell references with empty-cell padding instead of skipping them; both the chat-attachment extractors and the workspace `file_extract_text` path share the new helpers)
  - `lib/core/services/file/file_tool_service.dart` (`file_extract_text` description: tables returned as Markdown)
  - `lib/features/home/services/message_builder_service.dart` (workspace prompt: Markdown table output documented, `A1: value` reference removed)
  - `test/file_tool_service_test.dart` (11 XLSX tests rewritten to the Markdown format, DOCX/PPTX table assertions, new PPTX table fixture)
  - `README.md` / `README_ZH_TW.MD` (Workspace section)
  - `CHANGES_LOG.md` (this entry)
- **Details**:
  - **Duplicate-output fix**: DOCX `w:p` and PPTX `a:p` inside tables are no longer emitted as plain paragraphs (they were previously flattened), preventing table text from appearing twice.
  - **Sparse cells preserved**: XLSX rows with empty interior cells now render as padded `| a |  | b |` rows instead of collapsing columns; out-of-range shared-string indexes and empty trailing cells keep their column position.
  - **Bounds**: cells truncated at 200 chars, tables capped at 50 columns; sheet markers (`--- Sheet N (name) ---`) and byte-capped continuation reads are unchanged.

### 166. `file_create_pdf` Workspace Tool (Markdown → PDF)

- **Purpose**: Add a `file_create_pdf` workspace tool so the LLM can write a formatted PDF report from Markdown text. Uses the **already-present** `syncfusion_flutter_pdf` engine (no `pdf` package, no bundled CJK fonts) with built-in Simplified / Traditional Chinese rendering via `PdfCjkStandardFont`.
- **Files Modified**:
  - `lib/core/services/file/markdown_pdf_converter.dart` (NEW — `MarkdownPdfConverter`: ATX headings, paragraphs, bold / italic / inline code, ordered & unordered lists, GFM pipe tables via `PdfGrid`, fenced code blocks with tinted background, block quotes, horizontal rules, `[text](url)` / `![alt](url)` links, per-page page numbers; manual word-wrap via `measureString`; traditional-vs-simplified CJK font detection (`monotypeSungLight` vs `sinoTypeSongLight`); 8 MB output cap)
  - `lib/core/services/file/file_tool_service.dart` (`file_create_pdf` schema & dispatch, `_createPdf`: required string content capped at 512 KB, `MarkdownPdfConverter.convert`, FileRecord metadata returned so the file card appears)
  - `lib/features/home/services/message_builder_service.dart` (workspace prompt: `file_create_pdf` documented)
  - `test/markdown_pdf_converter_test.dart` (NEW — headings/lists/code/page numbers, tables/quotes/HR, Simplified & Traditional Chinese extraction round-trip, link stripping, size cap)
  - `test/file_tool_service_test.dart` (PDF tool tests: readable output, Chinese + table rendering, invalid argument rejection)
  - `README.md` / `README_ZH_TW.MD` (Workspace section)
  - `CHANGES_LOG.md` (this entry)
- **Details**:
  - **Library choice**: the original plan proposed adding `pdf: ^3.12.0`; review found `syncfusion_flutter_pdf` is already a direct dependency (used for PDF text extraction) and its `PdfCjkStandardFont` renders Chinese without bundling font files, so no new dependency was added.
  - **CJK detection**: the renderer picks `monotypeSungLight` (MSung) when Traditional-only characters are detected and `sinoTypeSongLight` (STSong) otherwise, so both scripts render without viewer substitution.
  - **FileRecord**: successful writes return `createdOrModifiedFilePath` / `fileName` / `fileSizeBytes`, so the existing assistant file-card flow attaches the generated PDF automatically.
  - **Isolate rendering (review fix)**: `_createPdf` runs `MarkdownPdfConverter.convert` via `compute()` in a background isolate so large documents do not jank the UI (the converter is pure Dart and sendable).
  - **DOCX nested paragraphs (review fix)**: `_docxBlockLines` walks all descendants (like the PPTX path) instead of only direct `w:body` children, so paragraphs nested in `w:sdt` content controls and `w:txbxContent` text boxes are preserved while table-internal paragraphs stay deduplicated.
  - **ZIP test coverage (review fix)**: added backslash-traversal (`..\x`) and absolute-path (`/etc/passwd`) entry tests.
  - **Vertical layout fix (second-pass review)**: `_drawRuns` now advances past the final drawn line and `_drawCodeBlock` page-breaks before every line, fixing overlapping text when paragraphs / headings / lists / code blocks wrapped past a single line; the trailing line-height advance no longer produces a spurious blank page at the document end.
- **Tests**: `flutter test` — full suite passes (99 tests), including ZIP extraction, PDF generation/converter, DOCX nested-paragraph, vertical-layout regression, and updated XLSX/DOCX/PPTX format assertions.

## [v1.8.1+] - 2026-08-05: Unrestricted Chat File Upload & Legacy Office MIME Handling

### 163. Chat "Upload File" Picker No Longer Restricts File Types

- **Purpose**: The chat file-upload button limited the picker to a hardcoded extension allowlist that kept missing common types (`.xls`, `.xlsx`, `.pptx`, `.csv`, `.svg`, archives, source files, ...). Since maintaining an exhaustive list is impractical, the picker now accepts any file (`FileType.any`); images vs documents are still classified by extension downstream, and drag-and-drop already had no restriction.
- **Files Modified**:
  - `lib/features/home/services/file_upload_service.dart` (`onPickFiles` now uses `FileType.any` with no `allowedExtensions`; `inferMimeByExtension` adds `.xls` -> `application/vnd.ms-excel`, `.ppt` -> `application/vnd.ms-powerpoint`, `.csv` -> `text/csv`)
  - `lib/features/home/widgets/chat_input_bar.dart` (pasted-file `_inferMimeByExtension` adds the same `.xlsx` / `.xls` / `.ppt` / `.csv` mappings so files pasted from Explorer get correct MIME types)
  - `lib/core/services/chat/document_text_extractor.dart` (global `extract()` returns explicit `[[XLS format (.xls) not supported...]]` and `[[PPT format (.ppt) not supported...]]` messages instead of reading legacy binaries as garbage text)
  - `CHANGES_LOG.md` (this entry)
- **Details**:
  - Purpose-specific pickers (avatar images, backup restore zip/json, provider JSON, font TTF/OTF, export, system-prompt import) are intentionally unchanged.
  - Legacy `.xls` / `.ppt` files are now selectable and receive an explicit "not supported for text extraction" result rather than raw binary text.

## [v1.8.1] - 2026-08-05: XLSX Text Extraction (`file_extract_text`)

### 162. XLSX (Excel) Text Extraction

- **Purpose**: Extend the read-only `file_extract_text` workspace tool and the chat attachment extractor to pull readable text and values from `.xlsx` workbooks using the existing `archive` + `xml` dependencies — no new packages, and no changes to the workspace sandbox, FileRecord, backup, or permission layers.
- **Files Modified**:
  - `lib/core/services/chat/document_text_extractor.dart` (bounded `_extractXlsxWorkspace`: optional `xl/sharedStrings.xml` table, `xl/workbook.xml` `<sheets>` order mapped through `xl/_rels/workbook.xml.rels` with `--- Sheet N (name) ---` markers, per-row output with cell references like `A1: value`; shared-string lookups with rich-text run concatenation, inline strings, numbers, booleans (`TRUE`/`FALSE`), and cached values of `str`/`d`/`e` cells; `rPh` phonetic runs excluded; dedicated 16 MiB sharedStrings part cap while other XML parts stay at 4 MiB; global `extract()` MIME branch + `_extractXlsx` for chat attachments; format detection for `.xlsx` extension and `xl/workbook.xml` ZIP layout)
  - `lib/core/services/file/file_tool_service.dart` (`file_extract_text` description and `format` enum now include XLSX; `_extractText` format whitelist and error text)
  - `lib/features/home/services/message_builder_service.dart` (workspace prompt lists XLSX; notes cell references, raw dates, cached formula values, and that `file_read` must not read XLSX binary)
  - `lib/features/home/services/file_upload_service.dart` (`.xlsx` MIME mapping + allowed upload extension)
  - `test/file_tool_service_test.dart` (XLSX fixtures + 11 new tests)
  - `pubspec.yaml` (version bumped to `1.8.1+67`)
  - `installer.iss` / `installers/omnichat_setup.iss` (installer version 1.8.1)
  - `README.md` / `README_ZH_TW.MD` (Workspace section: XLSX text extraction)
  - `CHANGES_LOG.md` (this entry)
- **Details**:
  - **Sheet order**: worksheets are read in `xl/workbook.xml` `<sheets>` (tab) order via the workbook relationships — not ZIP entry or filename order — with worksheet names in the markers.
  - **Cell handling**: `t="s"` shared strings, `t="inlineStr"` inline strings, plain numbers, booleans, and cached values of `str`/`d`/`e` cells; formulas (`<f>`) are skipped and only cached `<v>` values are returned; empty cells and rows are omitted; each non-empty cell is prefixed with its reference so the LLM can reconstruct the grid.
  - **sharedStrings is optional**: numeric-only workbooks or writers that inline all strings still extract; out-of-range shared-string indexes are skipped defensively.
  - **Limits**: reuses the 16 MiB input cap, 256 KiB parser cap, 24 KiB result cap, and `next_offset` continuation; malformed worksheets are skipped while malformed workbook/relationships/sharedStrings fail with safe error text.
  - **Out of scope**: legacy `.xls`, grid layout/styles/formula recomputation, Excel date-serial to human date conversion, chart sheets, and any XLSX generation or modification.
- **Tests**: `flutter test` — full suite passes (78 tests; 11 new XLSX tests covering workbook-order extraction with cell refs, ZIP-layout auto-detection, uppercase extensions, format override, numeric-only workbooks without sharedStrings, missing workbook error, boolean/formula/out-of-range cells, empty-workbook notice, the chat-attachment extractor, continuation offsets, and UTF-8 boundaries).

## [v1.8.0] - 2026-08-04: LLM Text Extraction from PDF/DOCX/PPTX (`file_extract_text`)

### 161. `file_extract_text` Workspace Tool

- **Purpose**: Add a read-only `file_extract_text` workspace tool so the LLM can pull readable text from PDF, DOCX, and PPTX files inside the current workspace, with continuation-based segmented reads and strict input/output caps.
- **Files Modified**:
  - `lib/core/services/chat/document_text_extractor.dart` (restricted `extractWorkspaceText` entry point plus `DocumentExtractionResult` / `DocumentExtractionException`; page-by-page PDF extraction with `--- Page N ---` markers and guaranteed `dispose()`; DOCX `word/document.xml` `w:p`/`w:t` extraction; relationship-aware PPTX extraction using `p:sldIdLst` order mapped through `presentation.xml.rels`)
  - `lib/core/services/file/file_tool_service.dart` (`file_extract_text` schema, dispatch case, and `_extractText` with UTF-8-boundary segmentation and the suggested caps: 16 KiB default / 24 KiB hard result cap / 16 MiB input cap / 256 KiB parser text cap)
  - `lib/features/home/services/message_builder_service.dart` (workspace prompt: added `file_extract_text`, PDF/DOCX/PPTX scope, workspace-relative path, `next_offset` continuation, no-OCR note, and a warning that `file_read` is only for UTF-8 plain text)
  - `test/file_tool_service_test.dart` (15 new extraction tests)
  - `pubspec.yaml` (version bumped to `1.8.0+66`)
  - `installer.iss` / `installers/omnichat_setup.iss` (installer version 1.8.0)
  - `README.md` / `README_ZH_TW.MD` (Workspace section: PDF/DOCX/PPTX text extraction)
  - `CHANGES_LOG.md` (this entry)
- **Details**:
  - **Tool contract**: `path` (required), `format` (`auto`/`pdf`/`docx`/`pptx`, default auto-detected from file signature first, then extension, then ZIP layout), `offset`/`limit` (default 16 KiB, hard cap 24 KiB) with `next_offset`/`has_more` metadata; UTF-8 code points are never split across segments.
  - **Limits**: source file ≤ 16 MiB (rejected before parsing), parser accumulates ≤ 256 KiB, single XML parts ≤ 4 MiB, ZIP entries ≤ 10000, one result ≤ 24 KiB with a cap warning. Results are text-only; no `FileRecord` is created.
  - **Safety**: reuses `resolveSafePath()` (absolute/traversal/NUL/symlink-escape rejection), rejects directories and non-files, never extracts archives to disk, and returns safe error text without absolute paths or stack traces.
  - **PPTX ordering**: slides are read in `p:sldIdLst` relationship order — not ZIP entry or filename order — verified with a fixture whose relationship order is slide2 → slide1 → slide10.
  - **Out of scope**: XLSX, legacy DOC/PPT, OCR of scanned PDFs, layout/notes/comments restoration, and any document generation or modification.
- **Tests**: `flutter test` — 29 file-tool tests pass (15 new extraction tests covering definitions, PDF/DOCX/PPTX extraction, auto-detect, format override, path rejection, malformed files, input caps, continuation, UTF-8 boundaries, and hard-cap enforcement).

## [v1.7.0] - 2026-08-03: Customizable Chat Input Bar Buttons (Order & Visibility)

### 160. Input Bar Button Order & Visibility Customization

- **Purpose**: Let users tailor the chat input bar tools to their workflow with one shared layout for mobile and desktop — drag to reorder buttons, toggle to show/hide rarely used ones, and one-tap restore the default order/visibility.
- **Files Modified**:
  - `lib/features/home/utils/chat_input_button_catalog.dart` (NEW — `ChatInputButtonSpec` catalog: 14 buttons with stable ids, icons, and localized labels; `chatInputButtonDefaultOrder`; `chatInputButtonEffectiveOrder`)
  - `lib/core/providers/settings_provider.dart` (`chat_input_button_order_v1` / `chat_input_button_hidden_v1` persisted string lists, `setChatInputButtonOrder` / `setChatInputButtonHidden`)
  - `lib/features/home/widgets/chat_input_bar.dart` (applies effective order & visibility: hidden ids filtered out, actions sorted by effective order)
  - `lib/features/settings/pages/chat_input_button_order_page.dart` (NEW — mobile settings page + shared `ChatInputButtonOrderPanel` with drag-to-reorder and show/hide toggles)
  - `lib/desktop/desktop_settings_page.dart` (Display Settings card: hidden count badge, Customize button opening a 520x560 dialog reusing the shared panel, one-tap reset)
  - `lib/features/settings/pages/display_settings_page.dart` ("Input Bar Buttons" entry)
  - `lib/l10n/app_en.arb` / `app_zh.arb` / `app_zh_Hans.arb` / `app_zh_Hant.arb` (+ regenerated `app_localizations*.dart`; `.arb` template keys completed in a follow-up commit)
  - `test/chat_input_button_catalog_test.dart` (NEW)
  - `pubspec.yaml` (version bumped to `1.7.0+65`)
  - `installers/omnichat_setup.iss` (installer version 1.7.0)
  - `README.md` / `README_ZH_TW.MD` (Customizable Input Bar Buttons section)
  - `CHANGES_LOG.md` (this entry)
- **Details**:
  - **Stable ids**: model selector, web search, MCP servers, quick phrases, dictation, camera, photos, upload, reasoning, AI Team, instruction injection, voice chat, context management, OCR — shared by the input bar renderer and the settings UI so preferences use stable ids across platforms.
  - **Effective order**: an empty stored order yields the default catalog order; custom orders keep unspecified buttons appended in catalog order; unknown/legacy ids are dropped via `chatInputButtonEffectiveOrder`.
  - **Visibility**: hidden button ids are removed from the input bar; platform-specific buttons (camera/photos on mobile, upload/OCR on desktop) only render where available.
  - **Reset**: one-tap reset clears both stored lists, restoring the default catalog order and visibility.
- **Tests**: `test/chat_input_button_catalog_test.dart` — 8 tests pass (unique ids, default-order coverage, custom-order merging with append, unknown-id dropping, exactly-once guarantees).

---

## [v1.7.0+] - 2026-08-03: Default Working Directory Options & Workspace Sheet Auto-Close

### 159. Global Default Working Directory Mode & Auto-Close Workspace Sheets

- **Purpose**: Turn the global default working directory into an explicit three-option setting (Do not use workspace / Use app private directory / Choose folder) stored as a typed `WorkspaceConfig`, and make the default-directory dialog and the conversation workspace sheet auto-close after a selection — consistent with the project workspace sheet.
- **Files Modified**:
  - `lib/core/providers/settings_provider.dart` (global default stored as `default_workspace_config_v1` typed JSON; legacy `default_workspace_path_v1` migrates to `custom` on first load; `setDefaultWorkspaceConfig` replaces `setDefaultWorkspacePath`)
  - `lib/core/services/workspace/workspace_resolver.dart` (global default now accepts `WorkspaceConfig?`; a disabled global default disables inherited project/conversation workspaces; unset/`useDefault` falls back to the app-private `files/` sandbox)
  - `lib/features/chat/widgets/workspace_settings_dialog.dart` (default directory sheet rewritten to three options with live check marks and custom-path subtitle; auto-closes after selection; `workspaceDefaultDirectoryLabel` helper)
  - `lib/features/chat/widgets/workspace_sheet.dart` (conversation mode options and folder picker auto-close after selection)
  - `lib/features/settings/pages/settings_page.dart` (row detail shows the current global mode: not used / app private / custom path)
  - `lib/features/home/services/message_generation_service.dart` / `lib/features/chat/widgets/chat_message_widget.dart` (pass `defaultWorkspaceConfig` to the resolver)
  - `lib/l10n/app_en.arb` / `app_zh.arb` / `app_zh_Hans.arb` / `app_zh_Hant.arb` (+ regenerated `app_localizations*.dart`; added `workspaceUseAppPrivateDirectory`, removed `workspaceDefaultDirectoryReset`)
  - `test/workspace_config_test.dart` (disabled-global-default resolution test)
- **Details**:
  - **Typed global default**: `default_workspace_config_v1` stores `{mode, path?}`; users pick disabled / app private / custom folder. The legacy single-path key is migrated once and removed.
  - **Disabled propagation**: a disabled global default resolves inherited "use default" project/conversation settings to no workspace, omitting `file_*` tools and the workspace prompt block.
  - **Consistent UX**: the default-directory dialog and the conversation workspace sheet close immediately after a selection, matching the project workspace sheet; the workspace sheet re-resolves after the gear-opened default-directory dialog closes.
- **Tests**: `flutter test` — 52 tests pass.

## [v1.6.9+] - 2026-08-03: Incremental File Editing and Segmented Reads

### 158. `file_edit` / `file_patch` Tools and Bounded `file_read` Segments

- **Purpose**: Add exact text editing, single-file unified patching, and continuation-based reads for files larger than one tool response.
- **Files Modified**:
  - `lib/core/services/file/file_tool_service.dart`
  - `lib/core/services/chat/chat_service.dart`
  - `lib/features/home/services/message_builder_service.dart`
  - `test/file_tool_service_test.dart`
  - `test/chat_service_file_record_test.dart`
- **Details**:
  - `file_edit` performs literal replacement, requires a unique match by default, and supports explicit `replace_all`.
  - `file_patch` applies one-file unified diffs only after all hunk context and line counts validate; the explicit tool path remains authoritative.
  - Both mutation tools reuse workspace boundary checks, blocked extensions, strict UTF-8 validation, and the 512 KB final-file limit. Successful edits produce the existing FileRecord metadata.
  - `file_edit` and `file_patch` use a pre-write snapshot comparison and same-directory temporary replacement to avoid overwriting concurrent edits or leaving a partially written target.
  - `file_read` now accepts zero-based byte `offset` and `limit` parameters, returns `next_offset` / `has_more`, avoids splitting UTF-8 code points, defaults to 16 KB, and caps one response at 24 KB so it stays below the API tool-result budget.
  - `file_read` tool-event persistence is capped to an 8 KB preview, including legacy events returned for backup, without requiring a Hive schema migration.
- **Tests**: File tool unit suite passes with coverage for continuation offsets, UTF-8 boundaries, exact/ambiguous edits, replacement bounds, unified patch context/newline failures, CRLF preservation, persistence bounds, and tool definitions.

## [v1.6.9+] - 2026-08-03: Workspace Modes & Global Default Working Directory

### 157. Workspace Modes (Disabled / Default / Project Default / Custom) & Global Default Directory

- **Purpose**: Replace the redundant "Clear workspace" action with a three-level workspace model — global default directory, per-project workspace setting, and per-conversation override — so users can opt out of file tools entirely ("Do not use workspace"), inherit the project's workspace, use the global default directory, or pick a custom folder per conversation.
- **Files Modified**:
  - `lib/core/models/workspace_config.dart` (NEW — `WorkspaceMode` enum (`inherit_project` / `disabled` / `use_default` / `custom`) and `WorkspaceConfig` serialization)
  - `lib/core/services/workspace/workspace_resolver.dart` (NEW — resolves the effective workspace: conversation override → project setting → global default → app-private `files/` sandbox)
  - `lib/features/chat/widgets/workspace_settings_dialog.dart` (NEW — global default directory sheet and project workspace mode sheet)
  - `test/workspace_config_test.dart` (NEW — mode serialization, conversation-overrides-project, inheritance & disabled resolution)
  - `lib/core/providers/settings_provider.dart` (`default_workspace_path_v1`, `setDefaultWorkspacePath`)
  - `lib/core/services/chat/chat_service.dart` (`conversation_workspace_bindings_v2` typed box, legacy `conversation_workspaces_v1` migration, `setConversationWorkspaceConfig`, fork/delete/clear coverage)
  - `lib/core/models/assistant.dart` (per-project `workspace` config, default `use_default`)
  - `lib/features/settings/pages/settings_page.dart` (General section row "Default working directory")
  - `lib/features/assistant/pages/assistant_settings_edit_page.dart` (workspace row in project Basic settings, mobile & desktop, gear shortcut to global default)
  - `lib/features/chat/widgets/workspace_sheet.dart` (menu rewritten: Do not use / Use default directory / Use project default directory / Choose folder / Files; gear shortcut re-resolves after global default changes)
  - `lib/features/home/services/message_generation_service.dart` / `lib/features/home/services/tool_handler_service.dart` / `lib/features/home/controllers/generation_controller.dart` (workspace resolution at generation time; `file_*` tools and system-prompt injection omitted when disabled; handler rejects file calls with no active workspace)
  - `lib/features/home/controllers/chat_actions.dart` (resolve assistant from the conversation's `assistantId` instead of the current assistant)
  - `lib/features/home/controllers/home_view_model.dart` (compress-context copies the workspace binding)
  - `lib/features/chat/widgets/chat_message_widget.dart` (show-in-folder resolves the current effective workspace)
  - `lib/core/services/backup/data_sync.dart` (backup version 3: `workspaceBindings` section, backward-compatible v2 restore)
  - `lib/l10n/app_en.arb` / `app_zh.arb` / `app_zh_Hans.arb` / `app_zh_Hant.arb` (+ regenerated `app_localizations*.dart`)
- **Details**:
  - **Migration**: Existing custom workspace paths are preserved as conversation `custom` bindings; conversations without a binding and all new conversations inherit the project setting (previously they fell back to the app-private sandbox).
  - **Resolution order**: conversation setting → project setting → global default directory → app-private `files/` sandbox; "Do not use workspace" resolves to no workspace and disables the file browser entry.
  - **Disabled mode**: `file_*` tool definitions are not offered to the model and the system prompt omits the workspace block; the tool-call handler rejects stray `file_` calls when no workspace is active.
  - **Global default directory**: configured under Settings → General → "Default working directory" (choose folder / restore app-private), with gear shortcuts from the project Basic settings and the conversation workspace sheet; the sheet re-resolves after the settings dialog closes.
  - **Project setting**: Basic settings shows the workspace mode with the effective label; options are disabled / use default directory / custom folder.
  - **Conversation menu**: Do not use workspace / Use default directory (with gear shortcut) / Use project default directory / Choose folder / Files — "Clear workspace" removed.
  - **Backup v3**: `workspaceBindings` stores typed modes; restore (overwrite & merge) writes them back; v2 backups remain readable.
  - **Tests**: `flutter test` — 35 tests pass (10 workspace & file-tool focused).

---

## [v1.6.9+] - 2026-08-03: New Project Button Styling & File Tool Reliability Fix

### 154. New Project Button Matches Project List Format

- **Purpose**: Restyle the sidebar "New Project" button so it matches the project list tiles exactly — black text (theme-aware), no border, no background, same font size (14) and icon size (20) — differing only in the icon (`FolderPlus` instead of `Folder`/`FolderOpen`).
- **Files Modified**:
  - `lib/features/home/widgets/side_drawer.dart` (rewrote `_NewProjectButtonState.build` to mirror `_AssistantFolderTile`: `IosCardPress` with transparent base, `BorderRadius.circular(12)`, `EdgeInsets.symmetric(horizontal: 8, vertical: 8)` padding, `FolderPlus` icon at size 20 with `cs.onSurface.withOpacity(0.7)` color, text at 14 / `FontWeight.w500` colored `isDark ? Colors.white : Colors.black`; removed the previous `AnimatedContainer` with primary-tinted background, border, and primary-colored text)
- **Details**:
  - **No Border / No Background**: The button now uses `IosCardPress` with `Colors.transparent` base (only a subtle surface tint on hover, identical to project tiles), replacing the old `cs.primary`-tinted container with a `cs.primary` border.
  - **Black Text**: Label color follows the project-list `textBase` convention — pure black in light mode, white in dark mode.
  - **Matching Metrics**: Icon 20px / text 14px / `w500` / padding 8/8 / radius 12 — all identical to `_AssistantFolderTile`.

### 155. Fix File Tool Conversation Interruption & Stuck Tool Card

- **Purpose**: Fix a Windows-observed bug where a `file_write` call succeeded on disk but the tool card stayed in the running state with no result ("（暫無結果）") and the conversation stopped. Root cause: the `file_` branch in `ToolHandlerService.buildToolCallHandler` had no error protection — any exception after the write (e.g., FileRecord persistence via Hive) propagated through the stream generator's `await onToolCall(...)`, so the `toolResults` chunk was never emitted and the stream errored.
- **Files Modified**:
  - `lib/features/home/services/tool_handler_service.dart` (wrapped the entire `file_` tool branch in `try/catch`: any unexpected failure is logged via `FlutterLogger.log` (tag `file-tool`) and converted into an `Error: ...` result string instead of throwing; `addMessageFileRecord` persistence is additionally isolated in its own `try/catch` so a Hive failure can never break the conversation; added `flutter_logger.dart` import)
- **Details**:
  - **Conversation Continuity**: Tool results are now always returned to the LLM, the `toolResults` chunk is always emitted, the tool card resolves to the result state, and the follow-up request proceeds — the conversation never breaks on file-tool failures.
  - **Diagnosability**: Real failures (with stack trace) are recorded to the app's flutter log (`Settings → Log Viewer`) under the `[file-tool]` tag for later inspection.
  - **Follow-up root cause**: The first FileRecord write returned an immutable empty list and failed on `removeWhere`; `ChatService` now copies the list before updating it, with a regression test covering the first record.
  - **Tests**: Full suite `flutter test` — 32 tests pass; the FileRecord regression test passes with `dart analyze` reporting only pre-existing warnings in `chat_service.dart`.

### 156. File Card: Tap to Preview & More Menu Button

- **Purpose**: Change the file card interaction so tapping the card previews the file instead of opening the actions menu, and the trailing three-dot icon becomes a dedicated button that opens the existing menu (show in folder / open externally / download) anchored at the click position on desktop.
- **Files Modified**:
  - `lib/features/chat/widgets/chat_message_widget.dart` (added `_previewFile` with a hybrid preview dispatcher: images open the in-app `ImageViewerPage`; Markdown is rendered via `MarkdownPreviewHtmlBuilder`; HTML/XML/SVG open the existing HTML preview (desktop dialog on Windows/macOS, page on mobile, unsupported toast on Linux); plain text/code/JSON/CSV/YAML etc. are HTML-escaped into a `<pre>` preview with a 2 MB in-app cap, falling back to `OpenFilex` for larger or non-text files; the card `onTap` now calls `_previewFile`, and the trailing `MoreVertical` icon became an `IosIconButton` wrapped in a `GestureDetector` that sets `DesktopMenuAnchor.setPosition` from the tap position on desktop so the menu appears near the button)
  - `lib/l10n/app_en.arb`, `lib/l10n/app_zh.arb`, `lib/l10n/app_zh_Hans.arb`, `lib/l10n/app_zh_Hant.arb` (added `chatMessageWidgetFileActions` semantic label)
- **Details**:
  - **Hybrid Preview**: image extensions (png/jpg/jpeg/gif/webp/bmp) open the existing full-screen image viewer; text-like extensions render in-app; everything else (PDF, DOCX, unknown/binary) opens with the system default app — no new dependencies.
  - **Safe Fallbacks**: file missing → existing error snackbar; text read failure (binary/encoding) → external open; `MarkdownPreviewHtmlBuilder` failure → external open.
  - **Desktop Anchor Fix**: previously the file menu always opened at the screen center because nothing updated `DesktopMenuAnchor`; the new button sets the anchor from `onTapDown.globalPosition`, matching the pattern used by the message action buttons.
  - **Tests**: Full suite `flutter test` — 32 tests pass; `dart analyze` on the modified file reports no new issues.

---

## [v1.6.9] - 2026-08-03: LLM File Operations (Workspace Tools) & Review Fixes

### 153. LLM File Operations — Sandboxed Workspace Tools

- **Purpose**: Grant the LLM sandboxed file read/write access to a per-conversation "Workspace" folder through 10 direct function-call tools (`file_read` / `file_write` / `file_append` / `file_delete` / `file_list` / `file_mkdir` / `file_info` / `file_move` / `file_copy` / `file_search`), implemented as Direct Function Calls (not an MCP server). Also address the 5 review findings: strict `content` validation, large-file / large-directory bounds, backup & restore coverage, widget test reliability, and workspace localization.
- **Files Modified**:
  - `lib/core/services/file/file_tool_service.dart` (NEW — tool definitions, sandbox path resolution, byte/entry limits, tool dispatch)
  - `lib/core/models/file_record.dart` (NEW — Hive FileRecord model for tool-produced files)
  - `lib/features/chat/widgets/workspace_sheet.dart` (NEW — workspace picker sheet)
  - `lib/features/chat/widgets/workspace_file_browser.dart` (NEW — workspace file browser UI)
  - `test/file_tool_service_test.dart` (NEW — FileToolService unit tests)
  - `lib/core/services/chat/chat_service.dart` (`conversation_workspaces_v1` / `message_file_records_v1` Hive boxes, workspace & FileRecord CRUD, fork replication)
  - `lib/features/home/services/tool_handler_service.dart` (`file_*` tool dispatch, FileRecord persistence)
  - `lib/features/home/controllers/generation_controller.dart` (pass `conversationId` / `messageId` to tools)
  - `lib/features/home/services/message_builder_service.dart` (workspace info injected into system prompt)
  - `lib/features/chat/widgets/chat_message_widget.dart` (assistant file cards: show in folder / open externally / download / share)
  - `lib/features/home/pages/home_desktop_layout.dart` / `home_mobile_layout.dart` / `home_page.dart` (Workspace button replaces appbar voice-chat entry; Voice Chat moved to input overflow menu)
  - `lib/features/home/widgets/chat_input_bar.dart` / `chat_input_section.dart` / `lib/features/home/controllers/chat_actions.dart` (overflow menu wiring)
  - `lib/core/services/backup/data_sync.dart` (backup version 2: `workspaces` + `fileRecords` fields, overwrite/merge restore)
  - `lib/core/providers/settings_provider.dart` (workspace UI visibility settings)
  - `lib/core/providers/update_provider.dart` (update check endpoint)
  - `lib/utils/app_directories.dart` (`getFileSandboxDirectory`)
  - `lib/main.dart` (`MyApp.enableUpdateCheck` test parameter)
  - `test/widget_test.dart` (reliable OmniChat smoke test)
  - `lib/icons/lucide_adapter.dart` (workspace icons)
  - `android/app/src/main/AndroidManifest.xml` (`MANAGE_EXTERNAL_STORAGE` permission)
  - `lib/l10n/app_en.arb` / `app_zh.arb` / `app_zh_Hans.arb` / `app_zh_Hant.arb` (+ regenerated `app_localizations*.dart`)
  - `pubspec.yaml` (direct `path: ^1.9.0` dependency; version bumped to `1.6.9+64`)
  - `installer.iss` / `installers/omnichat_setup.iss` (installer version 1.6.9)
  - `CHANGES_LOG.md` (this entry)
- **Details**:
  - **Security**: Every tool call is routed through `FileToolService.resolveSafePath()` — canonicalization, workspace-root boundary enforcement, and rejection of dangerous extensions (`.exe/.apk/.bat/.sh/.dll/.so/.cmd/.ps1/.vbs`).
  - **Resource Bounds (review fix)**: `file_read` uses a bounded read (1 MB + 1 bytes) and reports truncation; `file_write`/`file_append` reject payloads over 512 KB; `file_list` streams entries and truncates output at 1000 entries; `file_search` caps results at 1000 and the scan at 10000 visited entries with a truncation warning.
  - **Strict content validation (review fix)**: `file_write`/`file_append` reject missing or non-string `content` arguments before touching the filesystem — a failed validation never overwrites an existing file.
  - **Persistence**: Per-conversation workspace bindings (`conversation_workspaces_v1`) and tool-produced `FileRecord`s (`message_file_records_v1`) in Hive; conversation fork replicates both.
  - **Backup v2 (review fix)**: `data_sync.dart` backup format version raised to 2 with `workspaces` and `fileRecords` sections; both overwrite and merge restore write them back into the Hive boxes.
  - **UI**: Workspace button in the app bar opens `WorkspaceSheet` (pick / change folder, default = app-private `files/` sandbox); `WorkspaceFileBrowser` browses the sandbox; assistant messages render file cards with show-in-folder / open-externally / download / share actions.
  - **Tests (review fix)**: `test/widget_test.dart` rewritten as a deterministic `MyApp(enableUpdateCheck: false)` smoke test; `test/file_tool_service_test.dart` covers sandbox escapes, symlink rejection, byte limits, listing/search truncation, and CRUD operations. Full suite: 31 tests pass.
  - **Localization (review fix)**: workspace & file-card strings added across en / zh / zh_Hans / zh_Hant ARB files and wired to `AppLocalizations`.

- **v1.10.0** (2026-08-06, entry #167):
  - **Summary**: Integrated upstream Kelivo voice service features — 4 new Network TTS providers (Qwen, Groq, xAI, MiMo), MiniMax default model upgrade to `speech-2.6-turbo`, Voice Settings page (`TtsSettingsPage`) with auto-play assistant replies and speech text content filter ("Full text" / "Text outside brackets"), and Settings button ⚙️ added to voice service headers on Mobile and Desktop.
  - **Files Changed**:
    - `lib/core/services/tts/tts_text_selection.dart` (new `TtsTextSelection` utility for regex bracket stripping)
    - `lib/core/services/tts/network_tts.dart` (`QwenTtsOptions`, `GroqTtsOptions`, `XaiTtsOptions`, `MimoTtsOptions`, API handlers)
    - `lib/core/providers/settings_provider.dart` (`ttsAutoPlayAssistantReplies`, `ttsTextSelectionMode` getters/setters & persistence)
    - `lib/features/settings/pages/tts_settings_page.dart` (new settings page with switch and radio controls)
    - `lib/features/settings/pages/tts_services_page.dart` (mobile settings button & all 8 TTS providers UI)
    - `lib/desktop/setting/tts_services_pane.dart` (desktop settings button & dialog UI for 8 TTS providers)
    - `lib/features/home/controllers/home_page_controller.dart` (stream finished auto-play hook & speech text filtering)
    - `lib/l10n/app_en.arb` / `app_zh.arb` (Voice settings & new TTS provider translations)  - `pubspec.yaml` (version bumped to `1.10.0+69`)
  - `installer.iss` / `installers/omnichat_setup.iss` (installer version 1.10.0)

- **v1.10.2** (2026-08-07, entries #171–#173):
  - **Summary**: Phase 3 structural refactor — removed the dead `VoiceChatProvider`; extracted `ChatTurnService` (shared LLM turn-sending with 300ms streaming persist throttle) and split the 1397-line `voice_chat_screen.dart` into a `VoiceChatController` + `SttLocaleResolver` + `PlatformAudioSetup` (~200 lines, UI-only). Fixed a Phase 3 regression where a runtime map-literal type mismatch in `buildApiMessages` (inserting a `Map<String, dynamic>` literal into a runtime `List<Map<String, String>>`) froze voice chat at "Listening" and made ending the session hang; added `test/chat_turn_service_test.dart` regression tests (verified to fail with the exact Phase 3 error when the fix is reverted); removed debug-only `AppLog` utility per user request. Version bumped to `1.10.2+71`.
  - **Files Changed**:
    - `lib/core/services/chat/chat_turn_service.dart` (NEW) / `lib/features/voice_chat/controllers/voice_chat_controller.dart` (NEW) / `lib/features/voice_chat/services/stt_locale_resolver.dart` (NEW) / `lib/features/voice_chat/services/platform_audio_setup.dart` (NEW)
    - `lib/features/chat/voice_chat_provider.dart` (deleted) / `lib/core/utils/app_logger.dart` (deleted)
    - `lib/features/voice_chat/pages/voice_chat_screen.dart` (1397 → ~200 lines) / `lib/main.dart` / `lib/features/home/pages/home_page.dart`
    - `test/chat_turn_service_test.dart` (NEW, 4 regression tests)
    - `pubspec.yaml` (version `1.10.2+71`) / `installer.iss` (1.10.2)

- **v1.10.1** (2026-08-06, entries #168–#170):
  - **Summary**: Voice chat stability fixes (Windows + Android) — fixed the silence dead-loop that made the UI auto-pause after ~5–7s of quiet and kept the tray mic icon lit, the `SpeechToText` singleton listener bug that froze the UI on "Listening", and the Windows CMake install-prefix bug that broke `flutter run`/debug builds (missing `flutter_windows.dll`); native `InitialSilenceTimeout` raised to 60s on Windows so pure silence no longer cuts off at ~7s; `pauseFor` fully removed on all platforms (package default is null) so native engines decide end-of-speech.
  - **Files Changed**:
    - `lib/features/voice_chat/pages/voice_chat_screen.dart` (dedicated `SpeechToText.withMethodChannel()` instance so `onStatus`/`onError` are actually registered; `_resumeLocked` guard suppressing resumes triggered by our own force-cancel; keep `_isListening` true on final result so `stop()` really stops the native mic during thinking/TTS; `pauseFor` removed; auto-pause now stops the native session too; duplicate-final re-entry guard)
    - `lib/features/home/controllers/home_page_controller.dart` (dictation uses its own `SpeechToText` instance; `pauseFor` removed)
    - `lib/core/utils/app_logger.dart` (NEW — `AppLog.d/i/e`, debug-only)
    - `lib/l10n/app_en.arb` / `app_zh.arb` / `app_zh_Hans.arb` / `app_zh_Hant.arb` (+ regenerated `app_localizations*.dart`: `voiceChatPaused`, `voiceChatPermissionOpenSettings`, `voiceChatPermissionDeniedSubtitle`)
    - `dependencies/speech_to_text_windows/windows/speech_to_text_windows_plugin.cpp` (`InitialSilenceTimeout(60s)` set after constraint compilation; `Session Completed, status: N` diagnostics)
    - `windows/CMakeLists.txt` (install prefix `runner/Release` → `$<TARGET_FILE_DIR:${BINARY_NAME}>` so Debug/Profile/Release each get a complete bundle)
    - `lib/desktop/setting/tts_services_pane.dart` (unified provider icon)
    - `pubspec.yaml` (version bumped to `1.10.1+70`)
    - `installer.iss` / `installers/omnichat_setup.iss` (installer version 1.10.1)
    - `CHANGES_LOG.md` (this entry)
  - **Tests**: `flutter test` — full suite passes (99 tests); `flutter analyze` clean.
  - **Detailed records**: itemized Phase 1/2 and the out-of-plan fixes (X1–X4) are documented in entries #168–#170 at the top of the Version Changes Log.

---

## 📦 Archived Versions (v1.6.8+ and earlier)

Detailed entries for **v1.6.8+ and earlier** were moved to [`CHANGES_LOG_ARCHIVE_v1.5-v1.6.md`](./CHANGES_LOG_ARCHIVE_v1.5-v1.6.md) on 2026-08-05 to keep this file readable. The summaries below preserve the full project history — reading this file alone is sufficient to understand the project's evolution; open the archive only when you need file-level details of an older change.

### Version Summaries

- **v1.6.8+** (2026-08-03, entries #148–152): Code-block Preview buttons for XML/Markdown/CSV/TSV; Download button for all code blocks; sidebar "New Project" button as part of the project list with unified 4px item spacing.
- **v1.6.8** (2026-08-02, entries #144b–145b): Academic search providers — arXiv, PubMed (E-utilities), Semantic Scholar — with optional API keys and brand icons.
- **v1.6.7** (2026-08-01, entry #143b): `xhigh`/`max` reasoning budget tiers with model-specific API translation (OpenAI effort, Anthropic adaptive thinking, DeepSeek thinking knob, Moonshot Kimi K3 always-on).
- **v1.6.6** (2026-08-01, entry #122a): Dropbox streaming backup — streaming ZIP creation, streamed HTTP upload with 30-minute timeout, scope-toggle preservation, `omnichat_backup_` prefix, Inno Setup directory guard.
- **v1.6.5** (2026-08-01, entry #142b): Kelivo Statistics integration — granular token metrics (prompt/completion/cached) and the "Project Usage" statistics page.
- **v1.6.4** (2026-07-31, entries #141, #142a–147): Upstream Kelivo ports (v1.1.9/1.1.11/1.1.16/1.1.17) — topic deletion confirmation, message multi-select batch delete (added, then reverted for usability), inline message editing with RikkaHub-style header, greeting-model "Enable Thinking" toggle, waveform-circle voice icon, new-chat empty-state visual refinements.
- **v1.6.3** (2026-07-31, entries #139–140): Deep Research prompt migration and system-wide `learningMode` → `deepResearch`/`instructionInjection` refactor; token/context statistics display and mobile overflow fixes.
- **v1.6.2** (2026-07-30, entry #138): Android back-button fix — `SystemNavigator.pop()` on the root page when the drawer is closed (post-`PopScope` migration).
- **v1.6.1** (2026-07-30, entry #137): Customizable new-chat empty state (logo/text options), background `GreetingService` AI greetings with local fallback, dedicated Greeting Model & Prompt settings.
- **v1.6.0** (2026-07-30, entries #135–136): Flutter 3.38.6 → 3.44.8 upgrade (AGP 8.11.1, Gradle 8.14, KGP 2.2.20, Java 17), orphaned `app.process_text` channel restored, `WillPopScope` → `PopScope`, header model selector replaced by project name.
- **v1.5.32** (2026-07-30, entries #130–134): Consolidated search citations card with source favicons; default assistant unified into "Default Project" and "Deep Research" renaming with migration; folder-tree project icon cleanup; desktop language selector async fix.
- **v1.5.31** (2026-07-30, entries #127–129): Unified left-drawer folder-tree architecture (projects as folders containing conversations); Mini Map button moved to the top-right app bar; Storage/Translate sidebar buttons removed.
- **v1.5.30** (2026-07-29, entries #124–126): "Assistant" → "Project" UI terminology; AI Team real-time proposer streaming with throttle/totalTokens fixes; comprehensive Windows crash root-cause fix (v1.5.29 build) — streaming-deferred Mermaid/PlantUML rendering, child-window `WM_GETOBJECT` guard, WebView2 race-safe dispose, WinRT speech thread safety.
- **v1.5.28** (2026-07-26, entry #123): Windows crash root-cause fix — intercept `WM_GETOBJECT` at the runner to keep the Flutter engine's AX 2.0 semantics pipeline disabled (screen-reader trade-off documented).
- **v1.5.27** (2026-07-26, entry #122): Initial-request tool-result truncation, List/Map result truncation, WinRT main-thread validation & event-token revocation, JSON escaping fix, SelectCopy full-content support.
- **v1.5.26** (2026-07-26, entry #121): Complete `SelectionArea` bypass in Windows message lists with modal copy dialogs; WinRT thread guard; QuickJS execution moved to a background isolate.
- **v1.5.25** (2026-07-25, entry #120): Gemini 3.5/3.x-lite `thinkingLevel` translation; reasoning architecture documentation (OmniChat/Kelivo/RikkaHub).
- **v1.5.24** (2026-07-19, entries #118–119): AI Team aggregator tool calling; Chain Mixture-of-Agents (CMoA) mode with critics and per-mode prompts.
- **v1.5.23** (2026-07-19, entry #117): Windows crash fix — `SelectionArea` bypass for reasoning/translation during active typewriter streaming; Deep Research preset assistant added.
- **v1.5.22** (2026-07-15, entries #115–116): Context Management — Clear & Compress Context (summary fork to a new conversation); typewriter streaming selection bypass.
- **v1.5.21** (2026-06-30, entries #113–114): AI Team proposals renamed to "協作過程", real-time proposal rendering, Mistral aggregator message-order fix, `unawaited` pipeline for live UI updates.
- **v1.5.20** (2026-06-30, entries #111–112): AI Team progress indicator, rich proposals (reasoning + tool calls), localized default prompts, layered collapsible UI; per-prompt Restore Default and proposal-phase HTTP cancellation.
- **v1.5.19** (2026-06-30, entry #110): AI Team (Mixture of Agents) introduced — serial proposers, aggregator synthesis, proposals JSON persistence.
- **v1.5.18** (2026-06-29, entry #109): Fetch ReDoS root-cause fix, 256 KB DOM parse cap, 30-second HTTP timeout, `compute()` isolate offloading.
- **v1.5.17** (2026-06-29, entry #108): Fetch download limit 2 MB → 512 KB, historical tool-result truncation (32,768 chars), fetch concurrency queue (2).
- **v1.5.16** (2026-06-25, entries #104–107): Fetch server memory optimization (`_fetchWithLimit`, `_preCleanHtml`), Neuralwatt/Tinyfish brand icons, reasoning-block text selection, installer script update.
- **v1.5.15** (2026-06-25, entries #103–104a): Tinyfish search provider and Neuralwatt built-in API provider (models, quota, OpenAI-compatible chat).
