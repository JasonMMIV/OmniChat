# OmniChat Documentation & Developer Changes Log

## 📌 Core Architecture & Feature Overview

### Project Overview

- **Project Name**: OmniChat (A fork of Kelivo, inspired by Rikkahub)
- **Status**: Active Development / Feature Integration
- **Last Updated**: 2026-08-06 (v1.10.1)
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
