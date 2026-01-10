# OmniChat Developer Changes Log

## [v1.4.7] - 2026-01-09: Global Rebranding & UI Streamlining

### 85. Global Rebranding: From Kelivo to OmniChat
- **Purpose**: Fully align the application UI and metadata with the new "OmniChat" brand.
- **Files Modified**:
  - `lib/features/settings/pages/about_page.dart`: Updated app name and links.
  - `lib/desktop/setting/about_pane.dart`: Rebranded desktop About section.
  - `lib/desktop/desktop_tray_controller.dart`: Updated system tray tooltip.
  - `lib/core/services/notification_service.dart`: Updated notification ticker.
  - `lib/core/services/android_background.dart`: Updated background service title.
  - `lib/l10n/app_*.arb`: Rebranded visible localization strings in EN, ZH-Hans, and ZH-Hant.
- **Details**:
  - Replaced all instances of "Kelivo" with "OmniChat" in the About section, tray icon tooltips, and system notification fields.
  - Updated repository URLs to `https://github.com/JasonMMIV/OmniChat`.

### 86. UI Cleanup: Removal of Docs and Sponsor Options
- **Purpose**: Simplify the settings menu by removing external documentation and donation links.
- **Files Modified**:
  - `lib/features/settings/pages/settings_page.dart`: Removed "Docs" and "Sponsor" rows.
  - `lib/desktop/setting/about_pane.dart`: Removed "Sponsor" row and associated dialog code.
- **Details**: Removed "Official Website", "Docs", and "Sponsor" from all platforms to focus on the core chat experience.

### 87. Translation Enhancement: Traditional Chinese Default
- **Purpose**: Better accommodate regional preferences for Chinese users.
- **Files Modified**:
  - `lib/features/translate/pages/translate_page.dart`: Updated default target language.
  - `lib/desktop/desktop_translate_page.dart`: Updated default target language.
- **Details**: Changed the default translation target from Simplified Chinese to **Traditional Chinese (zh-TW)** when the app is running in a Chinese locale.

---

## [v1.5.4] - 2026-01-08: Windows Voice Robust Win32 Threading & Locale Fallback

### 84. Windows Voice: Private Message-Only Window & Best Effort Locale
- **Purpose**: Permanently resolve "No Response" issues on Windows and fix Chinese speech recognition failures.
- **Files Modified**:
  - `dependencies/speech_to_text_windows/windows/speech_to_text_windows_plugin.h`: Added private window class.
  - `dependencies/speech_to_text_windows/windows/speech_to_text_windows_plugin.cpp`: Implemented Message-Only Window `WndProc` and Chinese fallback logic.
  - `lib/features/voice_chat/pages/voice_chat_screen.dart`: Added `mounted` checks to prevent `setState` crashes.
- **Details**:
  - **Threading**: Replaced unreliable `DispatcherQueue`/`WindowProcDelegate` with a dedicated, invisible Win32 Message-Only window (`HWND_MESSAGE`). This guarantees the plugin receives its own cross-thread messages (`WM_RUN_ON_MAIN_THREAD`).
  - **Locale Fallback**: Implemented a "Best Effort" strategy for Chinese. If initialization for `zh-TW` fails (e.g., missing speech pack), the plugin automatically attempts `zh-CN`, and vice-versa, before falling back to English. This maximizes compatibility across different Windows region configurations.
  - **Stability**: Fixed Dart-side "setState() called after dispose()" crashes during async voice operations.
- **Outcome**: Voice chat is now stable, thread-safe, and resilient to missing specific Chinese language packs.

---

## [v1.5.3] - 2026-01-08: Windows Voice Threading & Stability Fix

### 83. Windows Voice: WinRT Thread Safety
- **Purpose**: Prevent crashes and "non-platform thread" errors when using voice recognition.
- **Files Modified**:
  - `dependencies/speech_to_text_windows/windows/speech_to_text_windows_plugin.h`: Implemented `WindowProcDelegate` for robust thread marshalling.
  - `dependencies/speech_to_text_windows/windows/speech_to_text_windows_plugin.cpp`: Switched to exclusive use of `PostMessage` + `WindowProc` to guarantee main-thread execution.
- **Details**:
  - **Issue**: WinRT speech events fire on background threads. Flutter's `InvokeMethod` crashes if called from non-UI threads. `DispatcherQueue` proved unreliable on some user systems.
  - **Fix**: Removed `DispatcherQueue` dependency. The plugin now registers a `WindowProcDelegate` and uses `PostMessage(WM_RUN_ON_MAIN_THREAD)` to marshal all tasks to the main UI thread via the native Windows message loop.
  - **Outcome**: Eliminated red console errors, memory leaks from unresponded messages, and application freezes; ensures reliable voice results delivery.

---

## [v1.5.2] - 2026-01-08: Windows Voice Locale Switching Fix

### 82. Windows Voice: Dynamic Locale Switching Support
- **Purpose**: Enable proper switching between languages (e.g., English -> Chinese) for speech recognition on Windows.
- **Files Modified**:
  - `dependencies/speech_to_text_windows/windows/speech_to_text_windows_plugin.h`: Added `m_currentLocale` state.
  - `dependencies/speech_to_text_windows/windows/speech_to_text_windows_plugin.cpp`: Implemented recognizer re-initialization logic.
- **Details**:
  - **Issue**: The WinRT plugin previously initialized the speech recognizer once (usually with the system default language) and ignored subsequent `localeId` requests from the Dart side.
  - **Fix**: Added `m_currentLocale` to track the active recognizer's language. Modified `StartListeningAsync` to compare the requested `localeId` with the current one.
  - **Logic**: If the requested locale differs from the current one, the plugin now closes the existing `SpeechRecognizer` and creates a new one with the correct language constraints.
- **Outcome**: Users can now seamlessly switch between English and Chinese (or other installed languages) in Voice Chat, and the engine will correctly recognize the selected language.

---

## [v1.5.1] - 2026-01-08: Windows Voice WinRT Debugging

### 81. Windows Voice: WinRT Debug Logs & Syntax Fix
- **Purpose**: Investigate "No Response" issue in WinRT mode and fix build-breaking string corruption.
- **Files Modified**:
  - `dependencies/speech_to_text_windows/windows/speech_to_text_windows_plugin.cpp`: Added detailed `[OmniChat]` logging.
- **Details**:
  - **Logging**: Added logs for `InitializeAsync`, `StartListeningAsync`, `CompileConstraintsAsync`, and Event Handlers.
  - **Syntax Fix**: Resolved a critical `C2001: newline in constant` error caused by string literal corruption during the previous update.
  - **Robustness**: Refined the JSON construction using explicit string concatenation to prevent tool-related encoding issues.

---

## [v1.5.0] - 2026-01-08: Windows Voice WinRT Migration

### 80. Windows Voice: WinRT Architecture Upgrade
- **Purpose**: Permanently resolve low accuracy ("你好" -> "應考") and initialization failures by migrating from legacy SAPI to modern Windows Runtime (WinRT) APIs.
- **Files Modified**:
  - `dependencies/speech_to_text_windows/windows/CMakeLists.txt`: Enabled C++/WinRT compilation (`/await`).
  - `dependencies/speech_to_text_windows/windows/speech_to_text_windows_plugin.h`: Updated headers for WinRT objects.
  - `dependencies/speech_to_text_windows/windows/speech_to_text_windows_plugin.cpp`: Rewrote implementation using `Windows::Media::SpeechRecognition`.
- **Key Changes**:
  - **Engine**: Switched from `ISpRecognizer` (SAPI) to `SpeechRecognizer` (WinRT). This automatically uses the high-quality "Embedded DNN" (OneCore) engine found in Windows 10/11 Dictation/Cortana.
  - **Dictation**: Configured `SpeechRecognitionTopicConstraint` with `SpeechRecognitionScenario::Dictation`, enabling true free-form speech recognition.
  - **Async Model**: Replaced COM message loops with native WinRT asynchronous events (`ResultGenerated`, `HypothesisGenerated`).
  - **Safety & Robustness**: 
    - **Coroutine Safety**: Moved to `shared_ptr` for `MethodResult` to ensure lifetime during `co_await` suspensions.
    - **Thread Safety**: Implemented `mutex` protection and local pointer swapping to prevent race conditions during async state changes.
  - **Stability**: Removed manual SAPI token enumeration and fallback logic; WinRT handles engine selection and cloud/offline modes automatically.
- **Outcome**: Users on Windows 10/11 will now experience native-quality dictation accuracy.

---

## [v1.4.11] - 2026-01-08: Windows Voice Initialization Robustness

### 79. Windows Voice: Engine Initialization Fallback
- **Purpose**: Fix "Error starting speech recognition: PlatformException(NOT_READY)" caused by incompatible OneCore engines.
- **Files Modified**:
  - `dependencies/speech_to_text_windows/windows/speech_to_text_windows_plugin.cpp`: Implemented robust initialization loop.
  - `dependencies/speech_to_text_windows/windows/speech_to_text_windows_plugin.h`: Updated class declarations.
- **Root Cause Analysis**:
  - Some Windows 10/11 systems have specialized "OneCore" engines (e.g., `MS-1033-110-WINMO-DNN`) that do not support the standard SAPI `LoadDictation` call, returning error `0x8004503a`.
  - Previously, the plugin picked the "best" match and failed immediately if it didn't work.
- **Solution**:
  - **Initialization Loop**: `InitEngine` now iterates through *all* matching tokens sorted by priority (OneCore Exact -> Legacy Exact -> Fallbacks).
  - **Automatic Fallback**: If `AttemptInit` fails for a token (e.g., due to `LoadDictation` error), it cleans up and seamlessly tries the next token in the list.
- **Outcome**: The app now successfully initializes speech recognition even if the highest-priority engine is incompatible, automatically falling back to a working Legacy SAPI 8.0 engine if needed.

---

## [v1.4.10] - 2026-01-08: Windows Voice OneCore Support

### 78. Windows Voice: OneCore Recognizer Priority
- **Purpose**: Significantly improve speech recognition accuracy on Windows 10/11 by prioritizing modern "OneCore" speech recognizers (Cortana/Dictation engine) over legacy SAPI 8.0 recognizers.
- **Files Modified**:
  - `dependencies/speech_to_text_windows/windows/speech_to_text_windows_plugin.cpp`: Implemented dual-category enumeration.
- **Root Cause Analysis**:
  - Legacy SAPI 8.0 recognizers (e.g., `MS-1028-80-DESK`) are outdated and often produce poor results like "應考" for "你好".
  - Modern Windows systems have "OneCore" recognizers (e.g., `MSTC_zh-TW_ZHC`) used by system dictation, which are far superior but stored in a different registry path (`HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Speech_OneCore\Recognizers`).
- **Solution**:
  - **Dual Enumeration**: The plugin now scans both OneCore and Legacy registry paths.
  - **Priority**: OneCore tokens are checked *first*. If a OneCore recognizer matches the requested locale (e.g., `zh-TW`), it is used immediately.
  - **Fallback**: Legacy SAPI recognizers are used only if no OneCore recognizer is found.
- **Outcome**: Users on Windows 10/11 should experience significantly better voice recognition quality, matching the system's native dictation performance.

---

## [v1.4.9] - 2026-01-08: Windows Voice Recognition LCID & Locale Source Fix

### 77. Windows Voice: LCID Format Support & App Locale Source Fix
- **Purpose**: Fix speech recognition still failing ("你好" -> "應考") on systems with legacy SAPI 8.0 recognizers.
- **Files Modified**:
  - `dependencies/speech_to_text_windows/windows/speech_to_text_windows_plugin.cpp`: Added LCID-to-locale mapping.
  - `lib/features/voice_chat/pages/voice_chat_screen.dart`: Fixed locale source to use `SettingsProvider.appLocale`.
- **Root Cause Analysis**:
  1. **LCID Format Not Supported**: Legacy SAPI 8.0 uses Token IDs like `MS-1028-80-DESK` where `1028` is an LCID (Locale ID), not `MSTC_zh-CN_ZHC` format. The previous `ExtractLocaleFromTokenId()` failed to parse this, returning `EY-LO` (garbage).
  2. **Wrong Locale Source**: Dart code was using `AppLocalizations.of(context)?.localeName` which returns the UI localization language (`en`), not the user's configured app language from Settings (`zh_Hant`).
- **Solution**:
  - **LCID Mapping**: Added `LcidToLocale()` function that maps Windows LCIDs to standard locale codes:
    - `1028` → `zh-TW` (Chinese Traditional Taiwan)
    - `2052` → `zh-CN` (Chinese Simplified PRC)
    - `1033` → `en-US` (English US)
    - Plus 15+ other common locales
  - **Locale Source Fix**: Changed Dart code to use `widget.settings.appLocale` instead of `AppLocalizations.localeName`.
  - **Enhanced Chinese Matching**: Improved fallback logic to find any Chinese recognizer if exact match fails.
- **Expected Log Output**:
  ```
  [OmniChat]   Found: HKEY_...\MS-1028-80-DESK
  [OmniChat]     LCID 1028 -> zh-TW
  [OmniChat]     -> Locale: zh-TW, Desc: Microsoft Speech Recognizer 8.0...
  [OmniChat Dart] Settings locale: zh_Hant (tag: zh_Hant), isSystemLocale: false
  [OmniChat Dart] Chinese Traditional match found: zh-TW
  ```

---

## [v1.4.8] - 2026-01-08: Windows Voice Recognition Locale Matching Fix

### 76. Windows Voice: Token ID to Locale Code Matching Fix
- **Purpose**: Fix poor speech recognition quality ("你好" -> "應考") caused by incorrect SAPI engine selection.
- **Files Modified**:
  - `dependencies/speech_to_text_windows/windows/speech_to_text_windows_plugin.cpp`: Rewrote locale matching logic.
  - `lib/features/voice_chat/pages/voice_chat_screen.dart`: Added diagnostic logging.
- **Root Cause Analysis**:
  1. **Token ID Mismatch**: The `GetEngineToken()` function was comparing the full SAPI registry path (e.g., `HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Speech_OneCore\Recognizers\Tokens\MSTC_zh-CN_ZHC`) against short locale codes (e.g., `zh-CN`). This comparison **always failed**, causing the system to fall back to the default English recognizer.
  2. **Incorrect Locale Format**: `GetLocales()` was returning full registry paths instead of standardized locale codes, making Dart-side matching impossible.
- **Solution**:
  - **Locale Extraction**: Added `ExtractLocaleFromTokenId()` helper function that extracts the actual locale code (e.g., `zh-CN`, `en-US`) from SAPI token IDs using pattern matching.
  - **Fuzzy Matching**: Rewrote `GetEngineToken()` to perform case-insensitive substring matching with language fallback (e.g., if `zh-TW` is requested but only `zh-CN` is installed, it will use `zh-CN`).
  - **Standardized Output**: Updated `GetLocales()` to return normalized locale codes instead of raw registry paths.
  - **Diagnostic Logging**: Added comprehensive `[OmniChat]` logging in both C++ and Dart to trace locale resolution.
- **Testing**: Run the app and check debug console for `[OmniChat]` logs showing locale matching process.

---

## [v1.4.7] - 2026-01-08: Windows Voice Recognition Accuracy & Language Switching Fix

### 75. Windows Voice: Audio Format Correction & Real Engine Switching
- **Purpose**: Fix poor speech recognition quality ("Nihao" -> "Liguo") and enable real language switching.
- **Files Modified**:
  - `dependencies/speech_to_text_windows/windows/speech_to_text_windows_plugin.cpp`: Core logic rewrite.
  - `dependencies/speech_to_text_windows/windows/speech_to_text_windows_plugin.h`: Added helper declarations.
  - `lib/features/voice_chat/pages/voice_chat_screen.dart`: Enabled locale passing for Windows.
- **Root Cause Analysis**:
  1. **Audio Distortion**: The Windows SAPI engine expects 16kHz audio, but modern microphones often provide 48kHz. Without resampling, this causes frequency shifts (pitch distortion), leading to misrecognition of phonetically similar words.
  2. **Locale Lock**: The plugin was ignoring `localeId` and using the system default, preventing users from switching between Chinese and English engines.
  3. **Fake Locales**: `GetLocales` was hardcoded, preventing the app from knowing which SAPI voices were actually installed.
- **Solution**:
  - **Audio Resampling**: Forced SAPI audio input to **16kHz, 16-bit, Mono PCM** format. This provides crystal clear audio to the engine, resolving the "distorted recognition" issue.
  - **Dynamic Engine Switching**: Implemented `InitEngine(localeId)` which enumerates installed SAPI tokens and loads the specific recognizer matching the requested language.
  - **Real Enumeration**: Updated `GetLocales` to perform real system enumeration of installed SAPI voices.
  - **App Integration**: Updated `VoiceChatScreen` to allow Windows to pass the selected `localeId` to the plugin instead of forcing `null`.

---

## [v1.4.6] - 2026-01-08: Windows Voice Chat Critical Fix

### 74. Windows Speech Recognition JSON Format Fix
- **Purpose**: Fix critical bug where Windows speech recognition showed "microphone in use" but never triggered `onResult` callback.
- **Files Modified**:
  - `lib/features/voice_chat/pages/voice_chat_screen.dart` - Fixed race condition in `_startUp()` initialization sequence.
  - `dependencies/speech_to_text_windows/lib/speech_to_text_windows.dart` - Patched JSON format transformation.
  - `pubspec.yaml` - Added `dependency_overrides` to use local patched version.
- **Root Cause Analysis**:
  1. **Race Condition**: `_initializeSpeechEngine()` and `_checkMicrophonePermission()` were executing concurrently without `await`, causing `_doStartListening()` to never be called.
  2. **JSON Format Mismatch**: Windows native C++ code sends `{"recognizedWords":"...", "finalResult":true}`, but the `speech_to_text` package's JSON parser expects `{"alternates":[{"recognizedWords":"...", "confidence":1.0}], "finalResult":true}`. This caused a `type 'Null' is not a subtype of type 'List<dynamic>' in type cast` error, silently failing the `onResult` callback.
- **Solution**:
  - Added `await` to initialization calls to ensure sequential execution.
  - Created a local patched version of `speech_to_text_windows` that transforms the JSON format before passing it to the main package's parser.
- **Technical Details**:
  - The `_transformRecognitionResult()` method in the patched plugin converts the Windows-native JSON format to the expected format with `alternates` array.
  - This is a workaround for an upstream bug in `speech_to_text_windows` version 1.0.0+beta.8.

---

## [v1.4.5] - 2026-01-08: Windows SAPI Compatibility Fix

### 73. Windows Voice: Force System Default Locale
- **Purpose**: Definitive fix for "Microphone active but no response" issue on Windows.
- **Files Modified**: `lib/features/voice_chat/pages/voice_chat_screen.dart`.
- **Details**:
  - **Problem**: Previous attempts to fuzzy-match the app locale (e.g., `zh_Hant`) to a Windows SAPI engine ID (e.g., `zh-TW`) failed because SAPI requires the *currently active* recognizer to match the request exactly. If the system default is English but the app requests Chinese, the engine initializes but remains silent.
  - **Solution**: Explicitly force `localeId: null` on Windows. This compels the library to use the user's active system recognizer.
  - **User Impact**: Users must ensure their Windows Speech settings match the language they intend to speak. The app will now reliably transcribe speech in the system's configured language.
  - **Mode**: Retained `ListenMode.dictation` to ensure free-form speech recognition.

## [v1.4.4] - 2026-01-08: Windows Voice Recognition Stabilization

### 72. Windows Voice Logic Overhaul
- **Purpose**: Resolve "microphone active but no response" by fixing locale negotiation and listen mode.
- **Files Modified**: `lib/features/voice_chat/pages/voice_chat_screen.dart`.
- **Details**:
  - **Fuzzy Locale Matching**: Implemented a sophisticated matching system to map App Locales (e.g., `zh_Hant`) to system-specific Windows SAPI IDs (e.g., `zh-TW`). This ensures the engine initializes with a recognizer that actually understands the user's speech.
  - **Listen Mode Reversion**: Switched back to `ListenMode.dictation`. Previous testing showed that `deviceDefault` (Command mode) frequently ignored natural conversational speech on Windows.
  - **Fallback Strategy**: The system now attempts exact matches, then language-variant matches, then general language matches, and only falls back to the system default (`null`) if no installed SAPI voice is suitable.
  - **Logging**: Added detailed debug output for available system locales and the final selection process.

## [v1.4.3] - 2026-01-08: Windows Voice Locale Fix

### 71. Windows SAPI Locale Bypass
- **Purpose**: Resolve persistent "microphone active but no response" issue on Windows.
- **Files Modified**: `lib/features/voice_chat/pages/voice_chat_screen.dart`.
- **Details**: 
  - Identified that the Windows SAPI engine is highly sensitive to mismatched `localeId` (e.g., passing `zh_TW` when only `zh-TW` or a default recognizer is available can cause it to stall).
  - Modified `_doStartListening` to strictly skip locale resolution on Windows (`selectedLocaleId = null`), forcing the engine to use the system's default active recognizer. This provides the most reliable experience.

## [v1.4.2] - 2026-01-08: Windows Voice Critical Fixes

### 68. Windows Voice Regex Fix
- **Purpose**: Resolve the "microphone active but no response" bug.
- **Files Modified**: `lib/features/voice_chat/pages/voice_chat_screen.dart`.
- **Details**: Fixed a typo in the locale splitting regex (`[_寿-]` -> `[_-]`). This error caused the fuzzy locale matcher to crash or return invalid data, preventing the Windows SAPI engine from initializing with the correct language pack.

### 69. Windows Listen Mode Optimization
- **Purpose**: Improve SAPI engine stability.
- **Files Modified**: `lib/features/voice_chat/pages/voice_chat_screen.dart`.
- **Details**: Switched `listenMode` to `ListenMode.deviceDefault` on Windows. The `dictation` mode used on mobile was found to be unreliable with the Windows Speech API, leading to silence or timeouts.

### 70. Audio Diagnostics
- **Purpose**: Enable hardware input verification.
- **Files Modified**: `lib/features/voice_chat/pages/voice_chat_screen.dart`.
- **Details**: Added `onSoundLevelChange` logging to print "Mic level" to the debug console, allowing verification that the app is physically receiving audio data.

## [v1.4.1] - 2026-01-07: Windows Voice Stability

### 56. Voice Chat Input Fix
- **Purpose**: Resolve "microphone active but no response" issue on Windows.
- **Files Modified**: `lib/features/voice_chat/pages/voice_chat_screen.dart`.
- **Details**: Implemented robust locale resolution logic. The app now fetches system-supported locales and intelligently matches them (exact or fuzzy) against the app's current language to ensure the Speech-to-Text engine receives a valid `localeId`.

### 57. Windows System TTS Repair
- **Purpose**: Fix "TTS speak failed" / "TTS unavailable" error on Windows.
- **Files Modified**: `pubspec.yaml`.
- **Details**: Switched `flutter_tts` dependency from a local path (which lacked Windows implementation) to the official `^4.2.3` version on pub.dev.

### 58. Desktop UI Accessibility
- **Purpose**: Improve usability of key actions on desktop.
- **Files Modified**: `lib/features/home/pages/home_desktop_layout.dart`.
- **Details**: Increased the size of "Voice Chat" and "New Chat" buttons in the top-right toolbar by approximately 1.7x (Icon: 34px, Touch Target: 54px).

### 59. Crash Prevention
- **Purpose**: Prevent `MissingPluginException` crashes in Voice Chat mode.
- **Files Modified**: `lib/features/voice_chat/pages/voice_chat_screen.dart`.
- **Details**: Guarded `AudioSession.instance` calls with platform checks to ensure they only run on Android/iOS, as the plugin is not supported on Windows.

### 60. Desktop UI Refinement
- **Purpose**: Optimize button sizes in the top-right toolbar.
- **Files Modified**: `lib/features/home/pages/home_desktop_layout.dart`.
- **Details**: Adjusted "Voice Chat" and "New Chat" buttons to an intermediate size (1.4x) between the original and the previous large increase. New dimensions: Icon size 28, tap target 48.

### 61. Windows System TTS Crash Fix
- **Purpose**: Prevent crash when using System TTS on Windows.
- **Files Modified**: `lib/core/providers/tts_provider.dart`.
- **Details**: 
  - Restricted `_selectEngine` to run only on Android, as `getEngines` is not supported on Windows.
  - Conditionally applied `focus: true` in `_tts.speak()` only for Android, as passing this named argument on Windows caused issues.

### 62. Windows Voice Stability & Recognition
- **Purpose**: Fix "no speech response" and crash on exit issues on Windows.
- **Files Modified**: `lib/features/voice_chat/pages/voice_chat_screen.dart`.
- **Details**:
  - **Recognition**: Switched `listenMode` to `ListenMode.search` (instead of `dictation`) on non-mobile platforms to improve compatibility with Windows SAPI.
  - **Stability**: Wrapped `_speechToText.cancel()` in a try-catch block and ensured `AudioSession` and `FlutterBackground` are strictly guarded against execution on Windows to prevent exit crashes.

### 63. Windows TTS Stability Finalization
- **Purpose**: Prevent native crashes caused by unsupported method calls in `flutter_tts` on Windows.
- **Files Modified**: `lib/core/providers/tts_provider.dart`.
- **Details**: Restricted `awaitSpeakCompletion`, `awaitSynthCompletion`, `setEngine`, and `setQueueMode` to Android/iOS only. Windows SAPI implementation does not safely support these synchronous waits or engine switching.

### 64. Windows Voice Recognition & Exit Fix
- **Purpose**: Fix "microphone active but no response" and crash on exit.
- **Files Modified**: `lib/features/voice_chat/pages/voice_chat_screen.dart`.
- **Details**:
  - **Recognition**: Reverted `listenMode` to `ListenMode.dictation` (was `search`) as it proved more reliable for Windows.
  - **Cleanup**: Implemented `_isCleaningUp` semaphore to prevent double-disposal race conditions between `dispose()` and navigation pop.

### 65. Windows TTS Playback Fix
- **Purpose**: Allow System TTS playback even if no network providers are configured.
- **Files Modified**: `lib/features/home/controllers/home_page_controller.dart`.
- **Details**: Updated `speakMessage` logic to allow playback when `usingSystemTts` is true, bypassing the check for network service existence.

### 66. Windows TTS Settings UI Adjustment
- **Purpose**: Hide unsupported Engine/Language selectors on Windows.
- **Files Modified**: `lib/desktop/setting/tts_services_pane.dart`.
- **Details**: Wrapped engine and language dropdowns in `if (Platform.isAndroid)` blocks, as `flutter_tts` does not support listing engines/languages on Windows/iOS.

### 67. Windows Voice Recognition & Race Condition Fix
- **Purpose**: Resolve "microphone active but no response" by fixing engine race conditions.
- **Files Modified**: `lib/features/voice_chat/pages/voice_chat_screen.dart`.
- **Details**:
  - **Logic**: Removed aggressive manual restarts at the end of `_doStartListening` which caused engine re-entrancy conflicts. Restarts are now strictly handled by `onStatus` and `onError` callbacks.
  - **State**: Improved `_isListening` state management to prevent overlapping `listen()` calls.
  - **Locale**: Enhanced Windows locale matching to fuzzy-match app language with system-installed SAPI voices (e.g., matching `zh_Hant` to `zh_TW` or `zh_HK`).
  - **Debug**: Enabled `debugLogging` in the STT engine for better diagnostic output.

## [v1.4.0] - 2026-01-06: Windows UX, Branding & Voice Fixes

### 50. Windows Branding & Icon Update
- **Purpose**: Align the Windows build with the OmniChat brand.
- **Files Modified**:
  - `windows/CMakeLists.txt`, `windows/runner/Runner.rc`, `windows/runner/main.cpp`: Renamed binary and metadata from "kelivo" to "OmniChat".
  - `windows/runner/resources/app_icon.ico`: Replaced with the new OmniChat icon.
  - `lib/desktop/desktop_home_page.dart`: Updated title bar icon and text.

### 51. UI Unification & Navigation
- **Purpose**: Make the Windows experience consistent with Android.
- **Files Modified**:
  - `lib/desktop/desktop_home_page.dart`: Removed the unique desktop rail; now uses the unified `HomePage` and `SideDrawer`.
  - `lib/features/home/widgets/side_drawer.dart`: Added a "Storage" shortcut to the bottom bar for parity.

### 52. Voice Chat & System TTS Fixes
- **Purpose**: Resolve Windows-specific voice issues and enable missing features.
- **Files Modified**:
  - `lib/features/voice_chat/pages/voice_chat_screen.dart`: Added aggressive resource cleanup using `cancel()` to release the microphone; added locale-aware recognition.
  - `lib/desktop/setting/tts_services_pane.dart`: Re-enabled the **System TTS** card for Windows users.

### 53. Windows Icon Resolution Fix
- **Purpose**: Fix low-quality icon display on Windows by unifying source to high-resolution assets.
- **Files Modified**: `flutter_launcher_icons.yaml`, `pubspec.yaml`.
- **Note**: Requires running `dart run flutter_launcher_icons` to regenerate assets.

### 54. Sidebar Navigation Restoration
- **Purpose**: Ensure "Settings", "User", "Translation", and "Storage" buttons are visible in the Windows sidebar.
- **Files Modified**:
  - `lib/desktop/desktop_sidebar.dart`: Removed forced hiding of the bottom bar.
  - `lib/features/home/widgets/side_drawer.dart`: Updated logic to display the bottom bar in embedded/desktop modes when `showBottomBar` is true.
  - `lib/features/home/pages/home_desktop_layout.dart`: Enabled bottom bar on the left drawer while maintaining a clean right drawer (topic list).

### 55. Windows System Font Support
- **Purpose**: Allow Windows users to use native system fonts for a more integrated OS experience.
- **Files Modified**:
  - `lib/desktop/desktop_settings_page.dart`: Updated `_showDesktopFontChooserDialog` to show "System Default" and "Monospace Default" options; enabled these flags in the font rows.
  - `lib/theme/theme_factory.dart`: (Verified) Already contains appropriate fallbacks for Windows (Segoe UI, Microsoft YaHei).
- **Outcome**: Users can now select "System Default" in font settings to use Windows native fonts.

## [v1.1.6] - 2026-01-06: Windows Release & Packaging

### 49. Windows Build & Installer

- **Purpose**: Fix compilation errors and provide distribution packages for Windows.
- **Files Modified**:
  - `dependencies/flutter-permission-handler/permission_handler_windows/windows/permission_handler_windows_plugin.cpp`: Fixed C4819 encoding error by replacing a non-standard hyphen.
  - `installers/omnichat_setup.iss`: Created Inno Setup script for building the Windows installer.
  - `installers/OmniChat_v1.1.6_Windows_Portable.zip`: Created portable ZIP package from the release build.
- **Outcome**: 
  - Successful `flutter build windows --release`.
  - Portable and Installer-ready artifacts generated in `installers/`.

## [v1.3.0] - 2026-01-06: OpenRouter Balance & Production Build

### 47. OpenRouter Balance Calculation

- **Purpose**: Fix OpenRouter balance always showing `?` due to missing support for subtraction in JSON path evaluation.
- **Files Modified**:
  - `lib/core/providers/model_provider.dart`: Updated `_JsonUtils.eval` to support arithmetic subtraction (`a - b`).
  - `lib/core/providers/settings_provider.dart`: Updated `_migrateBalanceSettings` to set OpenRouter's result key to `data.total_credits - data.total_usage`.
- **Outcome**: OpenRouter balance now correctly displays the net available credits.

### 48. Android Build & Environment Fixes

- **Purpose**: Resolve persistent build failures for production release.
- **Files Modified**:
  - `android/app/build.gradle.kts`: Temporarily redirected `buildDir` to bypass `FileAlreadyExistsException` (restored after build).
  - `android/app/proguard-rules.pro`: Added rules to keep `androidx.window` classes, fixing R8 compilation errors.

## [v1.2.0] - 2026-01-05: Account Balance & UI Polish

### 46. Account Balance Fix & Migration

- **Purpose**: Fix missing balance values for OpenRouter and other providers by forcing correct API paths.
- **Files Modified**:
  - `lib/core/providers/settings_provider.dart`: Enhanced `_migrateBalanceSettings` to force-update incorrect paths (e.g., OpenRouter now uses `/credits`).
- **Status**: OpenRouter balance displays `?`, indicating parsing issues despite correct path.

### 45. Signed APK Build & Fixes

- **Purpose**: Package the application for ARM64 v8a and fix compilation errors.
- **Files Modified**:
  - `lib/features/home/widgets/chat_input_bar.dart`: Fixed syntax errors (missing `LayoutBuilder` and variable definitions) introduced during previous edits.

### 44. New Chat Icon Resizing

- **Purpose**: Slightly reduce the size of the "New Chat" header icon for better visual consistency.
- **Files Modified**:
  - `lib/features/home/pages/home_mobile_layout.dart`: Reduced `MessageCirclePlus` (New Chat) icon to 24px (Voice and Map remain at 24px).

### 43. Model Icon Resizing

- **Purpose**: Fine-tune model icon size for better visual alignment with other buttons.
- **Files Modified**:
  - `lib/features/home/widgets/chat_input_bar.dart`: Adjusted `modelButtonW` to 38px and `childSize` to 36px with 1px padding.

### 42. Final UI Reversion & Polish

- **Purpose**: Restore approved icon sizes and clean up balance display logic.
- **Files Modified**:
  - `lib/features/home/widgets/chat_input_bar.dart`: Reverted `modelButtonW` to 40px and `_CompactIconButton` icon to 38px.
  - `lib/features/home/widgets/chat_input_section.dart`: Reverted `CurrentModelIcon` size to 38px.
  - `lib/core/providers/settings_provider.dart`: Reverted aggressive migration; now only initializes null balance fields.
  - `lib/core/providers/model_provider.dart`: Reverted custom headers and extended error parsing in `getBalance`.
  - `lib/features/provider/widgets/provider_balance_text.dart`: Improved placeholder display (`...`) and ensured wallet icon visibility.

### 41. Icon Maximization & Initial Balance UI

- **Purpose**: Enlarge icons for better space utilization and add money icon to balance text.
- **Files Modified**:
  - `lib/features/home/widgets/chat_input_bar.dart`: Initial enlargement of toolbar icons (20->24px).
  - `lib/features/home/widgets/model_icon.dart`: Enlarged internal logo scale (0.5->0.65).
  - `lib/features/provider/widgets/provider_balance_text.dart`: Added `Lucide.Banknote` icon support.
  - `lib/features/model/widgets/model_select_sheet.dart`: Changed `_ProviderChip` to a vertical layout to prevent text clipping.

### 40. Account Balance Feature (Initial Port)

- **Purpose**: Port "Get account balance" logic and UI from Rikkahub.
- **Files Modified**:
  - `lib/core/providers/settings_provider.dart`: Added `balanceEnabled`, `balanceApiPath`, and `balanceResultKey` to `ProviderConfig`.
  - `lib/core/providers/model_provider.dart`: Implemented `getBalance` and nested JSON parsing.
  - `lib/l10n/app_*.arb`: Added balance configuration localizations.

### 39. Upstream Merge & Preservation

- **Purpose**: Sync with latest `kelivo` changes while maintaining Voice Chat features.

---

## [v1.1.0] - 2026-01-04: Voice Chat Stability

### 38. Bluetooth & Call Mode Refinement

- **Purpose**: Fix audio routing and Bluetooth headset detection.
  - `android/app/src/main/kotlin/com/psyche/omnichat/MainActivity.kt`: Fixed false-positive detection.
  - `lib/features/voice_chat/pages/voice_chat_screen.dart`: Optimized `_startUp` sequence.

### 37. Voice UX Improvements

- **Purpose**: Disable auto-play in text mode and improve navigation logic.

---

## [v1.0.0] - 2025-11-27: Voice Chat Launch

### 1-36. Initial Voice Chat Implementation

- **Purpose**: Core voice features and project rebranding from "Kelivo" -> "OmniChat".