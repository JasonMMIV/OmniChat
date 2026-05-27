# OmniChat Project Implementation Plan & Documentation

## Project Overview

- **Project Name**: OmniChat (A fork of Kelivo, inspired by Rikkahub)
- **Status**: 🛠️ Active Development / Feature Integration
- **Last Updated**: 2026-05-27
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

### 2. Account Balance Support (Integrated)

Ported from Rikkahub to provide real-time usage monitoring.

- **Provider Integration**: Supports OpenAI, Google Gemini, DeepSeek, OpenRouter, and Moonshot.
- **Custom Configuration**: Users can toggle balance fetching and define custom API paths and JSON result keys per provider.
- **UI Display**: Balance display integrated into Provider Settings and Model Selection menus.
- **Status**: ✅ **Verified Working**.

### 3. UI/UX Enhancements & Rebranding

Refined visual identity and improved accessibility.

- **Global Rebranding**: Completed migration from "Kelivo" to "OmniChat" across all visible strings (About section, notifications, tray icons).
- **Streamlined Settings**: Removed redundant "Docs" and "Sponsor" options to focus on core chat experience.
- **Translation Localization**: Updated default translation target to **Traditional Chinese (zh-TW)** for Chinese-speaking regions.
- **Icon Maximization**: Enlarged action icons across the app (AppBar, Sidebar, and Input Toolbar).
- **Desktop Optimization**: 1.4x scale for Voice Chat and New Chat buttons for better target acquisition.
- **Responsive Input Bar Action Overflow (v1.5.13)**:
  - Implemented dynamic layout calculations to automatically hide overflowing input actions (e.g. Inline Dictation, Reasoning Mode) on smaller screen sizes (mobile).
  - Instead of spawning a redundant second `+` button on the left, these overflowed items are gracefully consolidated into the existing right-side `+` (More) menu.
  - Within the `BottomToolsSheet`, the overflowed items are presented below "Learning Mode" and "Clear Context", rendered in a matching list row layout (icon on the left, label on the right).

### 4. Search Services (Integrated)

Provides configurable external web search providers for tool-enabled text chat.

- **Provider Registry**: Search providers are represented by typed `SearchServiceOptions` and resolved through `SearchService.getService`.
- **Supported Providers**: Bing Local, DuckDuckGo, Tavily, Exa, Zhipu, SearXNG, LinkUp, Brave, Google, Metaso, Jina, Ollama, Perplexity, and Bocha.
- **Google Search API**: Uses Google Custom Search JSON API with `apiKey` and Programmable Search Engine ID (`cx`). Per-request result count is capped to Google's `num <= 10` API limit.
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
- **Status**: ✅ **Verified Working (v1.5.9), hardened in v1.5.14**. Fixed caching and naming conflicts between `kelivo_run_js` and `run-javascript` through a manual database migration and build system cleanup.

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

---

## Chronological Development Summary

### 2026-05-27 Updates (Revert Android STT Timeout Automation - v1.5.14)
- **Local JavaScript MCP Hardening (v1.5.14)**:
  - **Change**: Disabled network APIs for the built-in JavaScript execution tool.
  - **Change**: Switched tool calls to per-call runtimes to avoid state leakage.
  - **Change**: Added QuickJS timeout/memory limits and conservative code preflight checks.
  - **Change**: Corrected tool instructions so the LLM uses valid JavaScript examples.

- **Revert Dictation Auto-Exit and Voice Chat Pause-on-Timeout (v1.5.14)**:
  - **Change**: Removed automatic dictation exit from STT `done`/`notListening`/error callbacks.
  - **Change**: Removed automatic Voice Chat pause from timeout/no-match STT errors.
  - **Reason**: Android STT timeout behavior varies by device and speech service version, and `notListening` can represent normal end-of-speech rather than silence timeout.

### 2026-05-27 Updates (Chat Input Bar Overflow UI Refactor - v1.5.13)
- **Chat Input Bar Overflow UI Refactor (v1.5.13)**:
  - **Feature**: Automatically routes overflowing items from the left side of the input bar (like Dictation, Reasoning Mode) into the right-side `+` (More) menu instead of rendering a separate left-side `+` button.
  - **Design**: Displays these overflowed actions dynamically below "Learning Mode" and "Clear Context" using a list row layout (icon on the left, label on the right).

### 2026-05-27 Updates (Dictation Auto-Exit on Timeout - v1.5.12)
- **Dictation Auto-Exit on Timeout (v1.5.12)**:
  - **Status**: Reverted in v1.5.14.
  - **Original Feature**: Automatically exits dictation mode and resets the input bar UI when the system's voice recognition stops (emits `'notListening'`) due to silence timeout.
  - **Reason**: Android `notListening` is not a reliable timeout signal and can also represent normal end-of-speech.

### 2026-05-27 Updates (Inline Voice Dictation Localization - v1.5.11)
- **Inline Voice Dictation Localization (v1.5.11)**:
  - **Feature**: Localized the inline voice dictation button, stop button, and tooltips in English, Traditional Chinese, and Simplified Chinese according to system settings.

### 2026-05-27 Updates (Voice Chat Pause-on-Timeout - v1.5.10)
- **Voice Chat STT Pause-on-Timeout (v1.5.10)**:
  - **Status**: Reverted in v1.5.14.
  - **Original Feature**: Automatically transition to a "paused" state (changing the pause button to a Play button) when a silence timeout occurs (e.g. `error_speech_timeout`).
  - **Reason**: Android timeout/no-match callbacks are not reliable enough to drive Play/Pause state without introducing confusing state transitions.

### 2026-05-27 Updates (Local JavaScript MCP Server - v1.5.6)
- **Local JavaScript MCP Server (v1.5.6)**:
  - **Feature**: Added `run-javascript` as a built-in In-memory MCP server.
  - **Engine**: Integrated `flutter_js` (QuickJS) for sandboxed code execution.
  - **Availability**: Automatically enabled on all platforms (Android, iOS, Windows, macOS, Linux).
  - **Outcome**: LLMs can now perform local calculations and data processing without external dependencies or remote servers.

### 2026-05-25 Updates (Search Provider & Windows Stability - v1.5.5)
- **Google Search API Provider (v1.5.5)**:
  - **Feature**: Added `Google` to Search Services -> Search Providers.
  - **Configuration**: Requires an API Key and Search Engine ID (`cx`) for Google Custom Search JSON API.
  - **Outcome**: Users can select Google as the external web search provider in both mobile and desktop settings.
- **Windows Text Chat Crash Mitigation (v1.5.5)**:
  - **Fix**: Serialized async stream chunk handling with `pause()` / `resume()` and guarded all stream callbacks.
  - **Stability**: Added `runZonedGuarded` startup protection and handled `PlatformDispatcher` errors after logging.
  - **Outcome**: Reduces intermittent Windows crashes caused by unhandled async errors during normal text chat streaming.

### 2026-02-22 Updates (Feature Enhancements & Fixes - v1.4.9)
- **Formatted Text Copy (v1.4.9)**:
  - **Feature**: Replaced raw markdown copying with formatted Rich Text (HTML) + Plain Text fallback using `super_clipboard`.
  - **Outcome**: Pasting into word processors maintains formatting (bold, headers, bullets, etc.) seamlessly.
- **Windows Export Fix (v1.4.9)**:
  - **Feature**: Bypassed the native `Share` sheet entirely for Desktop platforms (Windows/macOS/Linux).
  - **Outcome**: Resolves the "export to file" failure on Windows backups by utilizing `FilePicker.platform.saveFile` for native dialogue saving.

### 2026-01-09 Updates (Rebranding & UI Cleanup - v1.4.7)

- **Global Rebranding (v1.4.7)**:
  - **UI**: Changed all occurrences of "Kelivo" to "OmniChat" in the "About" section, system tray tooltips, and notification titles.
  - **Links**: Updated repository and license links to `JasonMMIV/OmniChat`.
  - **Cleanup**: Removed "Docs" and "Sponsor" options from the settings on all platforms.
- **Translation Enhancement**:
  - **Default Language**: Changed the default translation target language from Simplified Chinese to Traditional Chinese (`zh-TW`) in both mobile and desktop versions.

### 2026-01-08 Updates (Windows Voice Robust Threading - v1.5.4)

- **Windows Voice Private Message Window (v1.5.4)**:
  - **Fix**: Implemented a private Win32 Message-Only Window for dedicated thread marshalling.
  - **Outcome**: Resolved persistent "No Response" issues by owning the message loop for recognition events, bypassing unreliable window delegates.

### 2026-01-08 Updates (Windows Voice Robust Threading - v1.5.4)

- **Windows Voice Private Message Window (v1.5.4)**:
  - **Fix**: Implemented a private Win32 Message-Only Window for dedicated thread marshalling.
  - **Locale Resilience**: Added automatic fallback between Traditional (`zh-TW`) and Simplified (`zh-CN`) Chinese if the specific speech pack is missing.
  - **Outcome**: Resolved persistent "No Response" issues and enabled Chinese voice recognition on systems with partial language pack installations.

### 2026-01-08 Updates (Windows Voice Stability - v1.5.3)

- **Windows Voice Threading Fix (v1.5.3)**:
  - **Fix**: Implemented robust thread marshalling for WinRT speech events.
  - **Mechanism**: Exclusively uses `PostMessage` + `WindowProcDelegate` to route background tasks to the main UI thread message loop.
  - **Outcome**: Resolved "non-platform thread" crashes, memory leaks, and "No Response" issues caused by unreliable `DispatcherQueue` availability.

### 2026-01-08 Updates (Windows Voice WinRT Locale Fix - v1.5.2)

- **Windows Voice Locale Switching (v1.5.2)**:
  - **Fix**: Implemented dynamic `SpeechRecognizer` re-initialization in the C++ plugin when the requested locale changes.
  - **Outcome**: Resolved the issue where switching languages (e.g., English -> Chinese) failed to update the underlying recognition engine.

### 2026-01-08 Updates (Windows Voice WinRT Migration - v1.5.0/v1.5.1)

- **Windows Voice WinRT Debugging (v1.5.1)**:
  - **Debugging**: Added detailed `[OmniChat]` console logging to trace initialization, compilation, and session events.
  - **Stability**: Fixed a build error caused by string literal corruption (`backticks` vs `quotes`).
- **Windows Voice WinRT Migration (v1.5.0)**:
  - **Architecture Upgrade**: Migrated from legacy **SAPI** to modern **Windows Runtime (WinRT)**.
  - **Goal**: Enable high-accuracy "OneCore" DNN engines for neural-quality recognition.
  - **Implementation**: Enabled C++ coroutines (`/await`), moved to `shared_ptr` for coroutine safety, and implemented `EscapeJsonString` for robust speech-to-Dart communication.

### 2026-01-08 Updates (Windows Voice Robustness & OneCore - v1.4.10/v1.4.11)

- **Windows Voice Initialization Robustness (v1.4.11)**:
  - **Fallback**: Implemented a robust loop to try all matching SAPI tokens if OneCore failed. (Superseded by v1.5.0).
- **Windows Voice OneCore Support (v1.4.10)**:
  - **Enhancement**: Priority scanning for modern registry paths in legacy SAPI. (Superseded by v1.5.0).

### 2026-01-08 Updates (v1.4.4 - v1.4.9)

- **LCID & Locale Source Fix (v1.4.9)**: Added LCID-to-locale mapping and fixed Dart-side locale source.
- **Token ID Matching (v1.4.8)**: Implemented `ExtractLocaleFromTokenId` helper for SAPI.
- **Audio Correction (v1.4.7)**: Forced **16kHz, 16-bit, Mono** format to fix spectral distortion.
- **JSON Format Fix (v1.4.6)**: Resolved mismatch between Windows native results and `speech_to_text` package expectations.
- **Logic Overhaul (v1.4.4/v1.4.5)**: Reverted to `ListenMode.dictation` and improved fuzzy matching.
