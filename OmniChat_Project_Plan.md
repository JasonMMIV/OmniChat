# OmniChat Project Implementation Plan & Documentation

## Project Overview

- **Project Name**: OmniChat (A fork of Kelivo, inspired by Rikkahub)
- **Status**: 🛠️ Active Development / Feature Integration
- **Last Updated**: 2026-01-09
- **Platforms**: Android (ARM64 v8a), iOS, Windows, macOS, Linux

---

## Core Feature Modules

### 1. Voice Chat Functionality (Integrated)

Provides a seamless, hands-free conversational experience with AI.

- **Cross-Platform State Machine**: Transitions smoothly between `Listening`, `Thinking` (processing), and `Talking` (TTS playback).
- **Continuous Listening**: Implemented an event-based restart mechanism to bypass system silence timeouts.
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

---

## Technical Implementation Details

### Architecture & State Management

- **Providers**: Centralized logic using `SettingsProvider`, `AssistantProvider`, `ChatService`, and `VoiceChatProvider`.
- **Windows Plugin**: Locally forked and patched `speech_to_text_windows` to support modern WinRT APIs and custom JSON transformation.

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