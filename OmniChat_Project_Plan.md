# OmniChat Project Implementation Plan & Documentation

## Project Overview

- **Project Name**: OmniChat (A fork of Kelivo, inspired by Rikkahub)
- **Status**: Active Development / Feature Integration
- **Last Updated**: 2026-06-29
- **Platforms**: Android (ARM64 v8a), iOS, Windows, macOS, Linux

---

## Core Feature Modules

### 1. Voice Chat Functionality (Integrated)

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
  - **Crash Mitigation (v1.5.17 → v1.5.18)**:
    - **v1.5.17**: Reduced fetch download limit (2 MB → 512 KB), added historical tool-result truncation, and introduced a fetch concurrency queue to reduce compound memory pressure during deep-thinking + web-search + multi-fetch conversations.
    - **v1.5.18**: Replaced ReDoS-vulnerable RegExp patterns in `_preCleanHtml()` with linear-complexity lazy matchers (`[\s\S]*?`). Added `_capForParsing()` to truncate HTML to 256 KB before DOM parsing. Added 30-second HTTP timeout to `_fetchWithLimit()`. Offloaded heavy HTML→Markdown/TXT conversion to background isolates via `compute()` for pages >32 KB, with 15-second isolate timeout.

### 2. Account Balance Support (Integrated)

Ported from Rikkahub to provide real-time usage monitoring.

- **Provider Integration**: Supports OpenAI, Google Gemini, DeepSeek, OpenRouter, Moonshot, and **Neuralwatt (v1.5.15)**.
- **Custom Configuration**: Users can toggle balance fetching and define custom API paths and JSON result keys per provider.
- **Neuralwatt Quota (v1.5.15)**: Uses the official `GET /v1/quota` endpoint. Displays `balance.credits_remaining_usd` formatted as `$xx.xx`.
- **UI Display**: Balance display integrated into Provider Settings and Model Selection menus.
- **Status**: **Verified Working**.

### 3. UI/UX Enhancements & Rebranding

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

### 4. Search Services (Integrated)

Provides configurable external web search providers for tool-enabled text chat.

- **Provider Registry**: Search providers are represented by typed `SearchServiceOptions` and resolved through `SearchService.getService`.
- **Supported Providers**: Bing Local, DuckDuckGo, Tavily, Exa, Zhipu, SearXNG, LinkUp, Brave, Google, Metaso, Jina, Ollama, Perplexity, Bocha, and **Tinyfish (v1.5.15)**.
- **Google Search API**: Uses Google Custom Search JSON API with `apiKey` and Programmable Search Engine ID (`cx`). Per-request result count is capped to Google's `num <= 10` API limit.
- **Tinyfish Search API (v1.5.15)**: Uses the official `GET https://api.search.tinyfish.ai` REST endpoint with `X-API-Key` header. Maps response `results[]` — `title`, `url`, `snippet` — to `SearchResultItem`. Supports `resultSize` limit and `timeout` control. REST API only; MCP integration is deferred.
- **UI Coverage**: Both mobile search service sheets and desktop settings panes support provider creation, editing, selection, status display, and brand icons.

### 5. Local Code Execution (MCP) (Integrated)

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

### 6. Built-in API Providers (Integrated)

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

---

## Technical Implementation Details

### Architecture & State Management

- **Providers**: Centralized logic using `SettingsProvider`, `AssistantProvider`, `ChatService`, and `VoiceChatProvider`.
- **Windows Plugin**: Locally forked and patched `speech_to_text_windows` to support modern WinRT APIs and custom JSON transformation.
- **Text Chat Streaming**: Chat stream handling now serializes async chunk processing with subscription pause/resume guards. Unhandled async errors are routed into stream error handling and global guarded logging to reduce Windows text chat crashes.

### Windows WinRT Migration Roadmap

1. **Phase 1 (Done)**: Build environment setup.
2. **Phase 2 (Done)**: Core implementation rewrite (SpeechRecognizer integrated).
3. **Phase 3 (Done)**: Runtime validation and robust threading via Message-Only Window.
4. **Phase 4 (Done)**: Chinese locale fallback and stability improvements.

### Build & Release

- **Target Platform**: 
  - Android: Signed ARM64 v8a APK.
  - Windows: Portable ZIP and Inno Setup Installer.
- **Optimization**: Tree-shaking enabled; high-resolution asset unification.
