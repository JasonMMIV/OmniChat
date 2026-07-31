# OmniChat Developer Changes Log

## [v1.6.4] - 2026-07-31: Port Upstream Kelivo Features (v1.1.9, v1.1.11, v1.1.16, v1.1.17)

### 141. Upstream Kelivo Features Integration
- **Purpose**: Port features and optimizations from upstream project `kelivo` (v1.1.9, v1.1.11, v1.1.16, v1.1.17) into OmniChat.
- **Files Modified**:
  - `lib/features/home/widgets/side_drawer.dart` (added topic deletion confirmation dialog)
  - `lib/features/home/controllers/chat_actions.dart` (preserved trailing messages when regenerating from earlier messages)
  - `lib/features/home/services/message_builder_service.dart` (supported media attachments when editing user messages)
  - `lib/features/home/widgets/chat_selection_delete_bar.dart` (added multi-selection batch deletion toolbar)
  - `lib/features/home/controllers/home_view_model.dart` & `lib/features/home/controllers/home_page_controller.dart` (implemented batch delete logic and selection state)
  - `lib/features/chat/widgets/message_more_sheet.dart` & `lib/features/home/widgets/message_list_view.dart` (added multi-select entry in message menu)
  - `lib/core/providers/settings_provider.dart`, `lib/features/model/pages/default_model_page.dart`, `lib/desktop/setting/default_model_pane.dart` (added "Enable Thinking" toggle for chat title generation)
  - `lib/l10n/app_en.arb`, `lib/l10n/app_zh.arb`, `lib/l10n/app_zh_Hans.arb`, `lib/l10n/app_zh_Hant.arb` (added localization keys)
  - `pubspec.yaml` (bumped version to 1.6.4+59)
  - `CHANGES_LOG.md` (this entry)
- **Details**:
  - **Topic Deletion Confirmation**: Added confirmation modal before deleting conversations in the side drawer.
  - **Message Regeneration Trailing Preservation**: Retained subsequent messages and version branch structure when regenerating from earlier messages in a conversation.
  - **Edit Message Attachments**: Extended message parsing to preserve and allow editing/uploading attachments when editing user messages.
  - **Message Multi-Select & Batch Delete**: Added message multi-selection mode with custom selection toolbar allowing deletion of selected message versions or all history versions of selected messages.
  - **Title Generation Thinking Control**: Added "Enable Thinking" toggle in default model settings to control thinking budget during title generation API requests.

### 142. Fix Topic Deletion Confirmation Dialog Localization & Mobile Display
- **Purpose**: Fix two issues with the topic deletion confirmation dialog: (1) desktop dialog displayed Simplified Chinese regardless of system language, and (2) mobile version did not show confirmation dialog at all.
- **Files Modified**:
  - `lib/l10n/app_zh_Hant.arb` (added `sideDrawerDeleteConfirmTitle` and `sideDrawerDeleteConfirmContent` Traditional Chinese translations)
  - `lib/l10n/app_zh_Hans.arb` (added `sideDrawerDeleteConfirmTitle` and `sideDrawerDeleteConfirmContent` Simplified Chinese translations)
  - `lib/features/home/widgets/side_drawer.dart` (added `_confirmDeleteConversation` call in mobile bottom sheet delete action)
  - `lib/l10n/app_localizations_zh.dart` (regenerated)
- **Details**:
  - **Localization Fix**: The `sideDrawerDeleteConfirmTitle` and `sideDrawerDeleteConfirmContent` keys were missing from `app_zh_Hant.arb` and `app_zh_Hans.arb`, causing the dialog to fall back to Simplified Chinese from `app_zh.arb`. Added proper translations for both Traditional and Simplified Chinese.
  - **Mobile Confirmation Dialog**: The mobile bottom sheet delete action (line 311-328 in `side_drawer.dart`) directly deleted conversations without confirmation. Added `_confirmDeleteConversation` call to match desktop behavior.

### 143. Add "Enable Thinking" Toggle for Greeting Model
- **Purpose**: Add an "Enable Thinking" toggle for the greeting model, matching the existing functionality for title generation.
- **Files Modified**:
  - `lib/core/providers/settings_provider.dart` (added `greetingGenerationThinkingEnabled` setting, getter, setter, and `greetingGenerationThinkingBudgetFor` method)
  - `lib/features/home/services/greeting_service.dart` (pass `thinkingBudget` to `ChatApiService.generateText`)
  - `lib/features/model/pages/default_model_page.dart` (added `_GreetingThinkingSwitchRow` widget and passed it as `extra` to greeting model `_ModelCard`)
  - `lib/desktop/setting/default_model_pane.dart` (added `_GreetingThinkingSwitchRow` widget and passed it as `extra` to greeting model `_ModelCard`)
  - `lib/l10n/app_en.arb`, `lib/l10n/app_zh.arb`, `lib/l10n/app_zh_Hans.arb`, `lib/l10n/app_zh_Hant.arb` (added `greetingModelThinkingTitle` key)
  - `lib/l10n/app_localizations_zh.dart` (regenerated)
- **Details**:
  - **Settings Provider**: Added `greetingGenerationThinkingEnabled` boolean setting with default `true`, loaded from SharedPreferences. Added `greetingGenerationThinkingBudgetFor()` method that returns 0 when disabled, otherwise returns the global thinking budget.
  - **Greeting Service**: Updated `fetchAiGreetingInBackground` to pass `thinkingBudget: settings.greetingGenerationThinkingBudgetFor()` to `ChatApiService.generateText`.
  - **Mobile & Desktop UI**: Added `_GreetingThinkingSwitchRow` widget (matching `_TitleThinkingSwitchRow` pattern) and passed it as `extra` parameter to the greeting model `_ModelCard` in both mobile and desktop settings pages.

### 144. Revert Message Multi-Select & Batch Delete Feature
- **Purpose**: Remove the message multi-select and batch delete feature due to poor usability.
- **Files Modified**:
  - `lib/features/home/controllers/home_page_controller.dart` (removed `ChatSelectionMode` enum, selection state fields, `deleteSelectedMessages`, `_selectedMessageIdsForDeletion`, `selectedMessagesIncludeMultipleVersions`, `_selectedSelectionGroupIds`, `_allCurrentConversationMessages` methods; simplified `startMessageSelection` and `cancelSelection`)
  - `lib/features/home/controllers/home_view_model.dart` (removed `deleteMessages`, `buildBatchDeletePlan`, `computeNextVersionSelection` methods and `BatchDeletePlan`, `BatchDeleteGroupPlan` classes)
  - `lib/features/chat/widgets/message_more_sheet.dart` (removed `MessageMoreAction.select` enum value and "Select Messages" UI from both desktop and mobile)
  - `lib/features/home/pages/home_page.dart` (removed `chat_selection_delete_bar.dart` import, `_buildSelectionToolbarOverlay` delete mode handling, `_handleDeleteSelectedMessages` method, `onSelectMessages` callback)
  - `lib/features/home/widgets/message_list_view.dart` (removed `onSelectMessages` parameter and `MessageMoreAction.select` handler)
  - `lib/features/home/widgets/chat_selection_delete_bar.dart` (deleted file)
  - `lib/l10n/app_en.arb`, `lib/l10n/app_zh.arb`, `lib/l10n/app_zh_Hans.arb`, `lib/l10n/app_zh_Hant.arb` (removed `messageMoreSheetSelectMessages`, `chatSelectionDeleteSelected`, `chatSelectionSelectMessagesToDelete`, `chatSelectionDeleteSelectedConfirm`, `chatSelectionDeleteSelectedAllVersionsConfirm`, `messageMoreSheetDeleteAllVersions` keys)
  - `lib/l10n/app_localizations_zh.dart` (regenerated)
- **Details**:
  - **Removed Feature**: Completely removed the message multi-select and batch delete functionality that was added in v1.6.4 entry #141.
  - **Preserved Share Mode**: The share selection mode (`confirmSelection`, `cancelSelection`, `toggleSelection`) remains intact as it was pre-existing functionality.

### 145. Upstream Kelivo v1.1.16 Inline Message Editing & Attachment Support with RikkaHub Header Style
- **Purpose**: Port user message editing optimization from upstream project `kelivo` (v1.1.16), allowing users to edit messages and modify attachments directly inside the main chat input bar instead of modal popups, while styling the edit header banner according to RikkaHub's UI design and supporting dynamic localization (`AppLocalizations`).
- **Files Modified**:
  - `lib/features/home/controllers/home_page_controller.dart` (added `editingMessage` state, `startEditingMessage`, `cancelEditingMessage`; updated `sendMessage` to format & save edited text and attachments and trigger AI regeneration; cleared edit state on conversation switch)
  - `lib/features/home/widgets/chat_input_bar.dart` (added `isEditing` and `onCancelEdit` parameters; rendered RikkaHub-style top header banner inside input container with `Lucide.Pencil`, `AppLocalizations.of(context)!.messageEditPageTitle`, and `Lucide.X` close button)
  - `lib/features/home/widgets/chat_input_section.dart` (passed `isEditing` and `onCancelEdit` to `ChatInputBar`)
  - `lib/features/home/pages/home_page.dart` (wired `_controller.startEditingMessage` and passed edit state & cancel callback to `ChatInputSection`)
  - `CHANGES_LOG.md` (this entry)
- **Details**:
  - **Inline Editing**: Removed modal popup sheet and desktop edit dialog in favor of inline editing directly within `ChatInputBar`.
  - **Attachment Modification**: Parsed raw message content into text and media attachments (`imagePaths`, `documents`) upon editing, pre-filling the chat input bar and allowing users to add, remove, or update attachments before submitting.
  - **RikkaHub Header Styling**: Replaced Kelivo's top floating "V 僅儲存" bar with an in-box header banner matching RikkaHub UI (pencil icon + title + close `X` button).
  - **Full Localization (l10n)**: Dynamically binds title to `AppLocalizations.of(context)!.messageEditPageTitle`, adapting automatically to system language settings (English, Simplified Chinese, Traditional Chinese, etc.).

## [v1.6.3] - 2026-07-31: Token Stats Fix & Deep Research Refactoring


### 140. Deep Research Prompt Migration & System-Wide Code Refactoring
- **Purpose**: Consolidate "Deep Research" prompt injection into `InstructionInjectionStore` / `DeepResearchStore`, replace default prompt with deep reasoning prompt, remove redundant auto-created assistant from `AssistantProvider`, and refactor all `learningMode` legacy symbols to `deepResearch` and `instructionInjection`.
- **Files Modified**:
  - `lib/core/services/deep_research_store.dart` (renamed from `learning_mode_store.dart`, updated class name and default prompt)
  - `lib/core/services/instruction_injection_store.dart` (updated reference to `DeepResearchStore`)
  - `lib/core/providers/settings_provider.dart` (updated default prompt constant, renamed `learningMode` fields/getters/setters to `deepResearch`)
  - `lib/core/providers/assistant_provider.dart` (removed automated seeding logic and key for "Deep Research" assistant)
  - `lib/features/home/widgets/instruction_prompt_sheet.dart` (renamed from `learning_prompt_sheet.dart`, updated class name and method `showInstructionPromptSheet`)
  - `lib/features/home/widgets/chat_input_bar.dart` & `lib/features/home/widgets/chat_input_section.dart` (renamed `onToggleLearningMode`, `learningModeActive`, `onLongPressLearning` parameters to `onToggleInstructionInjection`, `instructionInjectionActive`, `onLongPressInstruction`)
  - `lib/features/home/pages/home_page.dart` (updated imports, handlers, and method bindings)
  - `lib/features/chat/widgets/bottom_tools_sheet.dart` (renamed handler call to `_showInstructionPromptSheet`)
  - `lib/l10n/app_zh.arb`, `lib/l10n/app_zh_Hans.arb`, `lib/l10n/app_zh_Hant.arb` (updated `instructionInjectionDefaultTitle` to "深度研究" and removed unused `bottomToolsSheetLearningMode` keys)
  - `CHANGES_LOG.md` (this entry)
- **Details**:
  - **Prompt Replacement**: Replaced the legacy teaching prompt with an advanced Deep Reasoning & Research prompt in `DeepResearchStore` and `SettingsProvider`.
  - **Assistant Seeding Cleanup**: Removed redundant auto-creation of a "Deep Research" assistant in `AssistantProvider` to unify all instruction injection entries under `InstructionInjectionStore`.
  - **Codebase Refactoring**: Completely refactored all legacy `learningMode` / `LearningMode` variables, widget properties, and helper sheets to `deepResearch` / `instructionInjection`, removing old file `learning_prompt_sheet.dart`.

### 139. Fix Token and Context Statistics Display & Mobile Overflow in Chat Messages
- **Purpose**: Fix an issue where enabling "Display Token and Context Statistics" in Settings -> Display Settings -> Chat Items Display did not show token/context statistics, and resolve mobile layout overflow where long user/model names and timestamp/token text ran off screen without wrapping.
- **Files Modified**:
  - `lib/features/chat/widgets/chat_message_widget.dart` (updated `_buildUserMessage` and `_buildAssistantMessage` to uniformly respect `showTokenStats`, wrapped header Columns in `Flexible`/`Expanded`, implemented `Wrap` for timestamp & token stats to auto-wrap on mobile, added CJK-aware `_estimateTokens` fallback and `_buildStatsText` helper)
  - `lib/features/home/controllers/chat_actions.dart` (preserved `totalTokens` when updating message state via `copyWith` upon stream completion)
  - `CHANGES_LOG.md` (this entry)
- **Details**:
  - **Token Stats Rendering**: `_buildUserMessage` lacked rendering logic for `showTokenStats`, and `_buildAssistantMessage` only rendered token stats when `message.totalTokens != null`. Updated both to render statistics using CJK-aware estimation fallback when `totalTokens` is not returned by the API.
  - **Mobile Layout & Auto-Wrap Fix**:
    - Unconstrained `Column` elements in header `Row`s caused long user names, model names, and timestamp/token text to overflow the screen on mobile devices.
    - Wrapped the user message header `Column` in `Flexible` and assistant message header `Column` in `Expanded` with text truncation (`TextOverflow.ellipsis`).
    - Replaced non-wrapping `Row` for timestamp and token stats with responsive `Wrap` widgets (`WrapAlignment.end` for user, `WrapAlignment.start` for assistant), allowing timestamp and token/char counts to wrap cleanly onto a new line when horizontal space is limited on mobile screens.
  - **State Persistence**: Resolved a state update bug in `chat_actions.dart` where `totalTokens` was dropped when copying message state upon stream completion.

## [v1.6.2] - 2026-07-30: Android Back Navigation Fix

### 138. Android Back Button Navigation Fix for Root Chat Page
- **Purpose**: Fix an issue where pressing the Android system back button on the new chat (or root chat) page would not exit the app, getting trapped on the root page until a sub-page (like history) was navigated.
- **Files Modified**:
  - `lib/shared/widgets/interactive_drawer.dart` (updated `PopScope` back invocation logic to invoke `SystemNavigator.pop()` when `!didPop` and drawer is closed)
  - `CHANGES_LOG.md` (this entry)
- **Details**:
  - After upgrading from `WillPopScope` to `PopScope` in Flutter 3.44, when the app was on the root home page (`Navigator.canPop()` == `false`) and the side drawer was closed, pressing Android back resulted in `didPop` == `false`.
  - The previous handler only checked `if (!didPop && _controllerProxy.isOpen) _controllerProxy.close()`, doing nothing when the drawer was closed.
  - Updated `onPopInvokedWithResult` to trigger `SystemNavigator.pop()` when `!didPop` and `!_controllerProxy.isOpen`, ensuring back gesture correctly exits the application on Android root pages.

## [v1.6.1] - 2026-07-30: Customizable New Chat Empty State & Dynamic AI Greetings

### 137. Customizable New Chat Empty State & Dynamic AI Greetings
- **Purpose**: Allow users to customize the empty state of new chat pages with custom logos (OmniChat icon, current model icon, custom uploaded image, or hidden) and greeting texts (preset time-based greeting, dynamic AI background-cached greeting, current model name, custom text, or hidden), plus dedicated Greeting Model & Prompt configuration.
- **Files Modified**:
  - `pubspec.yaml` (bumped version to `1.6.1+58`)
  - `installers/omnichat_setup.iss` (updated `MyAppVersion` to `1.6.1` and `OutputBaseFilename` to `omnichat_setup_1.6.1`)
  - `lib/features/home/services/greeting_service.dart` (created: non-blocking background AI greeting fetching with 12s timeout & local fallback pool)
  - `lib/features/home/widgets/new_chat_empty_state.dart` (created: UI widget for rendering custom logo and text on empty chat pages)
  - `lib/features/home/widgets/message_list_view.dart` (integrated `NewChatEmptyState` when message list is empty)
  - `lib/core/providers/settings_provider.dart` (added state management & persistence for logo/text choices, custom image filenames, custom text, and greeting model/prompt configuration)
  - `lib/features/settings/pages/display_settings_page.dart` (added Mobile New Chat Page customization settings subpage)
  - `lib/desktop/desktop_settings_page.dart` (added Desktop New Chat Page logo/text configuration rows)
  - `lib/features/model/pages/default_model_page.dart` (added Mobile Greeting Model selector and prompt editor)
  - `lib/desktop/setting/default_model_pane.dart` (added Desktop Greeting Model selector and prompt editor)
  - `lib/l10n/app_en.arb`, `lib/l10n/app_zh.arb`, `lib/l10n/app_zh_Hant.arb` (added localization keys for New Chat Page & Greeting Model settings)
  - `CHANGES_LOG.md` (this entry)
- **Details**:
  - **Dynamic Logo & Text Options**: Users can choose logo display (`omnichat`, `model`, `custom`, `none`) and text display (`preset`, `ai_greeting`, `model_name`, `custom`, `none`).
  - **Zero-Latency AI Greetings**: `GreetingService` fetches AI greetings in the background during app startup or settings updates, caching the result in `SettingsProvider` to ensure instant loading on new chat creation.
  - **Greeting Model Configuration**: Dedicated Greeting Model card added to Default Model settings on both Mobile and Desktop, allowing custom model provider/ID selection and prompt customization.
  - **Cross-Platform Adaptability**: Desktop and Mobile settings UI tailored to respective design guidelines.
  - **Refinements**:
    - **Full Localization (EN, ZH, ZH_Hant)**: Added complete ARB localization keys (`app_en.arb`, `app_zh.arb`, `app_zh_Hant.arb`) for all New Chat Page options, headers, dropdowns, and dialogs. Updated `GreetingService` with 3 separate time-of-day greeting pools (English, Simplified Chinese, Traditional Chinese) and `SettingsProvider` with language-aware default AI prompts (`defaultGreetingPromptEn`, `defaultGreetingPromptZhHans`, `defaultGreetingPromptZhHant`), clearing cached greetings on language switch. Localized Greeting Model card title, subtitle, and prompt hint getters in Default Model settings (`default_model_page.dart` & `default_model_pane.dart`).
    - **Visual Option Icons**: Added semantic Lucide icons to all options in New Chat Page settings across Mobile (`_iosSelectableRow`) and Desktop (`_DesktopNewChatLogoRow` & `_DesktopNewChatTextRow` popup items and buttons) for visual consistency.
    - **Signed ARM64 APK & Windows Installer Build**: Re-generated signed release Android ARM64 APK (`OmniChat_1.6.1_arm64.apk`) and Inno Setup Windows installer (`omnichat_setup_1.6.1.exe`).
    - **Cleaned UI Labels**: Removed redundant parenthetical English annotations (e.g., `(Logo)`, `(Model Icon)`).
    - **Model Icon & Model Name Resolution**: Integrated `getModelDisplayInfo` to accurately resolve active model icons and friendly model names (e.g. GPT-4o, Gemini 1.5 Pro) instead of fallback defaults.
    - **Taiwan Chinese Terminology**: Standardized greetings (e.g., "午安", "晚安", "夜深了") and default prompt to strict Taiwan Traditional Chinese conventions.
    - **App-Launch AI Greeting Refresh**: Added session guard (`_hasFetchedThisSession`) and concurrency guard (`_isFetching`) so AI greetings auto-generate exactly once per App cold boot, while preventing redundant API calls on subsequent new chat pages during the same session.

## [v1.6.0] - 2026-07-30: Flutter 3.38 → 3.44 Upgrade & Bug Fixes

### 135. Flutter SDK Upgrade (3.38.6 → 3.44.8) & Full Cleanup
- **Purpose**: Upgrade Flutter SDK to latest stable 3.44.8 (Dart 3.12.2), sync Android build toolchain, fix deprecation warnings, merge orphaned Android platform channel, and resolve latent naming/configuration issues across all platforms.
- **Files Modified**:
  - `pubspec.yaml` (SDK constraint `^3.8.1` → `^3.9.0`, `lucide_icons_flutter` `^3.1.4` → `^3.1.15`)
  - `android/settings.gradle.kts` (AGP `8.9.1` → `8.11.1`, KGP `2.1.0` → `2.2.20`)
  - `android/gradle/wrapper/gradle-wrapper.properties` (Gradle `8.12` → `8.14`)
  - `android/app/build.gradle.kts` (NDK `flutter.ndkVersion`, Java 11 → 17, removed duplicate `dependencies{}`/`android{lint{}}` blocks)
  - `android/gradle.properties` (Flutter migrator auto-added `builtInKotlin=false`, `newDsl=false`)
  - `android/app/src/main/kotlin/com/psyche/omnichat/MainActivity.kt` (merged `app.process_text` channel from orphaned kelivo)
  - `android/app/src/main/kotlin/com/psyche/kelivo/MainActivity.kt` (deleted — orphaned package)
  - `lib/shared/pages/webview_page.dart` (`WillPopScope` → `PopScope`)
  - `lib/shared/widgets/interactive_drawer.dart` (`WillPopScope` → `PopScope`)
  - `lib/theme/theme_factory.dart` (removed `useMaterial3: true` × 4 — now default)
  - `lib/icons/lucide_adapter.dart` (`Github` icon: `lucide.LucideIcons.github` → `lucide.LucideIcons.cat` — upstream removed `github`)
  - `linux/runner/my_application.cc` (window title `kelivo` → `OmniChat`)
  - `analysis_options.yaml` (removed stale `analyzer: exclude: dependencies/flutter_tts/**` — path never existed)
- **Details**:
  - **Flutter SDK**: 3.38.6 → 3.44.8 (Dart 3.12.2, DevTools 2.57.0). Covers 3.41 + 3.44 stable releases.
  - **Android Toolchain**: AGP 8.11.1, Gradle 8.14, KGP 2.2.20, Java 17, NDK aligned with Flutter default (`flutter.ndkVersion` = r28). Matches Flutter 3.44 recommended compatibility matrix.
  - **`app.process_text` Channel Restoration**: The `app.process_text` channel (`getInitialText`/`onProcessText`) was defined in an orphaned `com.psyche.kelivo.MainActivity` that was never instantiated (manifest points to `com.psyche.omnichat.MainActivity`). Merged the channel into the active `MainActivity` and deleted the orphan, restoring Android "share text to app" functionality.
  - **Deprecation Cleanup**: `WillPopScope` → `PopScope` (2 widgets), `useMaterial3: true` removal (4 ThemeData constructors — Material 3 is default since Flutter 3.16).
  - **`lucide_icons_flutter` 3.1.6 → 3.1.15**: Upgraded to fix `IconData` marked `final` (3.44 breaking change). Upstream removed `github` icon (trademark); replaced with `cat` (closest visual match).
  - **Linux Branding Fix**: Window title `kelivo` → `OmniChat` in `linux/runner/my_application.cc`.
  - **Analysis Cleanup**: Removed dead `analyzer: exclude` for non-existent `dependencies/flutter_tts/**` path.
  - **Windows Build**: Verified — `OmniChat.exe` produced.
  - **Android Build**: Verified — `app-debug.apk` produced (Gradle 561 tasks, 1m 16s).
  - **iOS/macOS**: Phase D (SwiftPM migration) and Phase E (UIScene manual migration — `AppDelegate.swift` has custom `app.clipboard` channel) deferred to macOS environment.
  - **Upgrade Plan**: Full plan documented in `Flutter_Upgrade_Plan.md`.

### 136. Replace Header Model Selector with Current Project Name Display
- **Purpose**: Remove the top header model selection menu/capsule across both mobile and desktop layouts and replace it with the current project name (assistant name) while maintaining the original typography and animation transitions.
- **Files Modified**:
  - `lib/features/home/pages/home_mobile_layout.dart` (replaced dynamic model selector with static assistant name text, cleaned unused params)
  - `lib/features/home/pages/home_desktop_layout.dart` (replaced clickable model capsule with static assistant name text, cleaned unused params)
  - `lib/features/home/pages/home_page.dart` (removed unused model display parameter pass-throughs, variables, and imports)
  - `CHANGES_LOG.md` (this entry)
- **Details**:
  - Replaced interactive model selector in top bar on both mobile and desktop layouts with current assistant/project name (`_getAssistantName`).
  - Preserved font size, alignment, and `AnimatedTextSwap` transition behavior.
  - Kept bottom chat input bar model selector (`ChatInputSection`) intact.
  - Removed unused constructor parameters (`providerName`, `modelDisplay`, `onSelectModel`) and imports across affected files for code cleanliness.

## [v1.5.32] - 2026-07-30: Consolidated Search Citations Card & Source Favicons

### 134. Unified Assistant/Project Naming & Cleanup — Default Project & Deep Research
- **Purpose**: Simplify default assistant structure by eliminating the redundant blank default assistant, standardizing the primary assistant as "Default Project" ("預設專案"), renaming "Deep Research Assistant" to "Deep Research" ("深度研究"), and updating all localization files and automatic migration logic.
- **Files Modified**:
  - `lib/l10n/app_en.arb` (updated assistant default/sample and deep research names)
  - `lib/l10n/app_zh.arb` (updated assistant default/sample and deep research names)
  - `lib/l10n/app_zh_Hans.arb` (updated assistant default/sample and deep research names)
  - `lib/l10n/app_zh_Hant.arb` (updated assistant default/sample and deep research names)
  - `lib/core/providers/assistant_provider.dart` (merged sample assistant into primary default project, updated deep research name, and added migration logic for legacy assistant names)
  - `CHANGES_LOG.md` (this entry)
- **Details**:
  - **Default Assistant Unification**: Merged the blank "Default Assistant" with "Sample Project" into a single, comprehensive "Default Project" ("預設專案" / "默认项目") to clean up default project setup.
  - **Deep Research Renaming**: Renamed "Deep Research Assistant" ("深度研究助理") to "Deep Research" ("深度研究").
  - **Localization Synchronization**: Updated ARB files across all supported languages (en, zh, zh-Hans, zh-Hant) for consistent project names.
  - **Legacy Migration & Persistence**: Implemented automatic migration logic in `AssistantProvider.ensureDefaults` to migrate existing stored user assistant names seamlessly upon app launch, and added `_hasSeededDeepResearchKey` to prevent deleted default projects from reappearing on app restart.

### 133. Side Drawer UI Optimization — Removed Project Icon from Folder Tree
- **Purpose**: Clean up project/assistant folder tile visuals in the unified folder tree by removing the assistant avatar icon and retaining only the folder icon (`Lucide.Folder` / `Lucide.FolderOpen`).
- **Files Modified**:
  - `lib/features/home/widgets/side_drawer.dart` (removed `avatar` from `_AssistantFolderTile` and removed unused `_assistantAvatar` helpers)
  - `CHANGES_LOG.md` (this entry)
- **Details**:
  - **Visual Cleanup**: Removed `widget.avatar` from `_AssistantFolderTile`, simplifying the project row layout to show only the folder icon and project title.
  - **Dead Code Cleanup**: Deleted unused `_assistantAvatar`, `_assistantInitialAvatar`, and `_assistantEmojiAvatar` helper methods.

### 132. Desktop Language Selector Async Fix
- **Purpose**: Resolve async race condition in `showLanguageSelector` for desktop platforms where opening the context menu and selecting a target language returned `null` before selection completed.
- **Files Modified**:
  - `lib/features/settings/widgets/language_select_sheet.dart` (implemented `Completer<LanguageOption?>` pattern for synchronous-safe async selection handling)
  - `CHANGES_LOG.md` (this entry)
- **Details**:
  - **Completer Async Pattern**: Replaced direct variable assignment with `Completer<LanguageOption?>` to safely capture target language selection or menu dismissal, ensuring single-message inline translation triggers reliably on desktop.

### 131. Citation Sheet Details UI Optimization
- **Purpose**: Upgrade the citation detail popover/sheet items (`_SourceRow`) to match `kelivo`'s modern card layout, featuring favicons, distinct title hierarchy, index badges, and domain names.
- **Files Modified**:
  - `lib/features/chat/widgets/chat_message_widget.dart` (redesigned `_SourceRow` with `IosCardPress`, `_SourceFavicon`, domain extraction, and dark/light adaptive theme borders)
  - `CHANGES_LOG.md` (this entry)
- **Details**:
  - **Card Layout**: Converted `_SourceRow` into a tactile `IosCardPress` card with subtle borders.
  - **Favicon Integration**: Added domain favicon to each individual citation entry in the popup sheet.
  - **Typography & Hierarchy**: Enhanced readability with 2-line title wrapping, explicit host domain, and index pill badge.

### 130. Consolidated Search Citations & Source Favicons Integration
- **Purpose**: Import upstream `kelivo` search citation block optimizations, consolidating all search results from multiple web/builtin search tool calls into a single summary card at the bottom of AI messages, styled with a transparent card border and source site favicons.
- **Files Modified**:
  - `pubspec.yaml` (bumped version to `1.5.32+56`)
  - `installers/omnichat_setup.iss` (updated `MyAppVersion` to `1.5.32` and `OutputBaseFilename` to `omnichat_setup_1.5.32`)
  - `lib/shared/widgets/ios_tactile.dart` (added `BoxBorder? border` property to `IosCardPress`)
  - `lib/features/chat/widgets/chat_message_widget.dart` (replaced `_latestSearchItems()` with `_allSearchItems()`, updated `_SourcesSummaryCard` UI, added `_SourceFaviconStack`, `_SourceFavicon`, `_SourceFaviconFallback` widgets and `_tryNormalizeExternalUri` helper)
  - `lib/features/home/controllers/stream_controller.dart` (enhanced `dedupeToolPartsList` and `dedupeToolEvents` with `_toolDedupeBase` and `_toolDedupeKey` for robust stream tool result deduplication)
  - `CHANGES_LOG.md` (this entry)
- **Details**:
  - **All-Search Aggregation**: Replaced single-result `_latestSearchItems()` with `_allSearchItems()`, ensuring all unique search results across multiple `search_web` or `builtin_search` tool calls are collected and displayed together.
  - **Favicon Stack**: Added `_SourceFaviconStack` to render up to 3 overlapping source website favicons fetched from `favicone.com`, with fallback to a globe icon.
  - **UI Refinement**: Updated `_SourcesSummaryCard` styling to feature a transparent base with a dark/light mode aware border.
  - **Stream Tool Deduplication**: Enhanced `StreamController` to preserve completed no-ID tool calls while dropping stale placeholders during streaming.

## [v1.5.31] - 2026-07-30: Unified Left Drawer Folder-Tree Architecture & Top Mini Map Unification

### 129. Sidebar Cleanup — Removed Storage & Translate Buttons
- **Purpose**: Remove duplicate Storage Space button (already available in Settings) and standalone Translate button/page from the left sidebar drawer (`SideDrawer`), while preserving message-level translation in chat conversations. Also clean up unused `desktop_nav_rail.dart`, `translate_page.dart`, and `desktop_translate_page.dart` dead code.
- **Files Modified**:
  - `lib/features/home/widgets/side_drawer.dart` (removed Storage Space and Translate buttons from bottom action bar, removed unused imports)
  - `lib/desktop/desktop_nav_rail.dart` [DELETED] (removed unused legacy desktop navigation rail component)
  - `lib/features/translate/pages/translate_page.dart` [DELETED] (removed unused standalone translate page)
  - `lib/desktop/desktop_translate_page.dart` [DELETED] (removed unused desktop translate page)
  - `CHANGES_LOG.md` (this entry)
- **Details**:
  - **Storage Button Removal**: Removed `Lucide.Folder` (Storage Space) button from the bottom of `SideDrawer` since Storage Space is accessible via Settings (`SettingsPage`).
  - **Sidebar Translate Button Removal**: Removed `Lucide.Languages` (Translate) button from the bottom of `SideDrawer`.
  - **Preserved Message-Level Translation**: Retained `widget.onTranslate` callback and translation menu actions in `chat_message_widget.dart` for inline message translation.
  - **Dead Code Cleanup**: Deleted unreferenced `desktop_nav_rail.dart`, `translate_page.dart`, and `desktop_translate_page.dart` files.

### 128. Unified Mini Map Button Position Across Desktop & Mobile
- **Purpose**: Relocate the Desktop Mini map (chat navigator) button from the chat input bar to the top App bar's top-right actions area (between Voice Chat and New Conversation buttons), unifying the UI layout across desktop and mobile devices, and updating the desktop popover placement to anchor below the top-right button.
- **Files Modified**:
  - `lib/features/home/pages/home_desktop_layout.dart` (added `miniMapKey` and `onOpenMiniMap` to `HomeDesktopScaffold`; rendered `IosIconButton(icon: Lucide.Map)` in `_buildActions` between Voice Chat and New Conversation)
  - `lib/features/home/pages/home_mobile_layout.dart` (added `miniMapKey` to `HomeMobileScaffold` and attached key to Mini map `IosIconButton`)
  - `lib/features/home/pages/home_page.dart` (added `_topMiniMapKey` to `_HomePageState` and passed to `HomeDesktopScaffold` and `HomeMobileScaffold`; updated `onOpenMiniMap` callback to pass `_topMiniMapKey` to `showDesktopMiniMapPopover`)
  - `lib/features/home/widgets/chat_input_section.dart` (disabled `showMiniMapButton` in `ChatInputSection` to avoid duplicate button in input bar)
  - `lib/desktop/mini_map_popover.dart` (updated `_MiniMapPopoverState.build` with `isTopAnchor` logic to position popover card below top-anchored button with top-right screen alignment and downward slide-in animation)
  - `CHANGES_LOG.md` (this entry)
- **Details**:
  - **Unified Top-Right Actions Layout**: Placed the Mini map button (`Lucide.Map`) in the top App bar's action area on desktop, positioning it between the Voice Chat (`Lucide.Phone`) button and the New Conversation (`Lucide.MessageCirclePlus`) button.
  - **Input Bar Button Removal**: Set `showMiniMapButton: false` in `ChatInputSection` for desktop/tablet mode to prevent duplicate Mini map controls.
  - **Top-Anchored Popover Positioning**: Extended `showDesktopMiniMapPopover` positioning math to support top-anchored buttons (`isTopAnchor = widget.anchorRect.top < screen.height / 2`). The popover now floats right below the top App bar button, aligned to its right edge with a smooth downward slide-in animation.
  - **Responsive Narrow Window Support**: Attached `miniMapKey` to `HomeMobileScaffold` so that when a desktop app window is resized to narrow width, clicking the top-right Mini map button continues to correctly anchor and render the desktop popover.

### 127. Unified Left Drawer Folder-Tree Architecture
- **Purpose**: Unify Windows Desktop and Mobile/Tablet left drawer/sidebar layouts into a single folder-tree structure where projects (assistants) act as expandable folders containing their respective conversations, replacing legacy Desktop tabs, top "Current Assistant" cards, and the separate right-side topics sidebar.
- **Files Modified**:
  - `pubspec.yaml` (bumped version to `1.5.31+55`)
  - `installers/omnichat_setup.iss` (updated `MyAppVersion` to `1.5.31` and `OutputBaseFilename` to `omnichat_setup_1.5.31`)
  - `lib/features/home/widgets/side_drawer.dart` (implemented `_buildFolderTreeList` and `_AssistantFolderTile`, added accordion logic via `_expandedAssistantIds`, preserved tag grouping, date grouping, and pinned conversation sections; removed legacy desktop tabs/views/headers)
  - `lib/features/home/pages/home_desktop_layout.dart` (removed `_buildRightSidebar` and legacy desktop tab parameters from `SideDrawer`)
  - `lib/desktop/desktop_sidebar.dart` (updated `SideDrawer` initialization parameters)
  - `CHANGES_LOG.md` (this entry)
- **Details**:
  - **Folder Accordion Structure**: Each project (assistant) is rendered as a folder tile (`_AssistantFolderTile`). Clicking the project toggles its open/closed state (`FolderOpen` / `Folder`) while keeping the active conversation intact.
  - **Top Card Removal**: Removed the top "Current Project" card from `SideDrawer`, leaving search and history buttons at the top.
  - **New Chat Button**: Replaced the edit/settings button on project tiles with a `Lucide.Plus` button. Clicking `+` sets `currentAssistantId`, expands the folder, and creates a new conversation under that project.
  - **Desktop Layout Simplification**: Completely removed the desktop-specific dual-tab view (Projects/Topics) and right-side topics panel, unifying the UI across Windows desktop and mobile devices.
  - **Sub-conversation Grouping**: Retained Pinned (`isPinned`) and Date Grouping (`showChatListDate`) logic inside expanded project folders.
- **Version bump**: 1.5.30+54 -> 1.5.31+55.

## [v1.5.30] - 2026-07-29: Terminology Update & AI Team Real-time Proposer Streaming

### 126. Terminology Update — Assistant Feature Renamed to Project in UI (l10n)
- **Purpose**: Rename the user-facing "Assistant" (助理 / 助手) feature terminology to "Project" (專案 / 项目) across English, Traditional Chinese, and Simplified Chinese localization files and hardcoded UI text, while preserving underlying model/class architecture and LLM system prompt definitions.
- **Files Modified**:
  - `lib/l10n/app_en.arb` (updated UI strings from "Assistant/Assistants" to "Project/Projects")
  - `lib/l10n/app_zh_Hant.arb` (updated UI strings from "助理/助手" to "專案")
  - `lib/l10n/app_zh_Hans.arb` & `lib/l10n/app_zh.arb` (updated UI strings from "助手/助理" to "项目")
  - `lib/l10n/app_localizations*.dart` (regenerated via `flutter gen-l10n`)
  - `lib/features/backup/pages/backup_page.dart` (updated hardcoded dialog prompt text from 助手 to 项目/專案)
  - `lib/core/providers/assistant_provider.dart` (added "Deep Research Project" and traditional/simplified variants to lookup fallbacks while preserving legacy "Deep Research Assistant")
  - `CHANGES_LOG.md` (this entry)
- **Details**:
  - **Localization Update**: Replaced user-facing UI labels ("Assistant Settings" -> "Project Settings", "Default Assistant" -> "Default Project", "Edit Assistant" -> "Edit Project", "Search assistants..." -> "Search projects...", etc.) across all 4 locale files.
  - **Preserved Contexts**: Reverted system prompt template role descriptions ("You are a helpful AI assistant") and "Deep Research Assistant" default names back to Assistant/助理/助手 for LLM prompt clarity and backward compatibility.
  - **Architecture Protection**: Code symbols (`Assistant` class, provider keys, database schemas) remain unchanged to avoid breaking changes to user-saved data and states.

### 125. AI Team — Real-time Proposer Streaming Display
- **Purpose**: Show each proposer model's streaming output in the main content area in real-time during the AI Team proposal phase, replacing the static progress text ("Proposal X/N"). After each proposer completes, its result moves to the "Collaboration Process" proposals section and the next proposer's output takes over the main content area. Pass `isStreaming` to proposal section `MarkdownWithCodeHighlight` calls to defer Mermaid/PlantUML WebView2 during active streaming.
- **Files Modified**:
  - `lib/features/home/controllers/chat_actions.dart` (`_runProposerSilent` gains `onPartialContent` callback fired on each chunk; `_executeAiTeamGeneration` proposer loop passes callback using `scheduleThrottledUpdate` (60ms throttle) for content + `updateReasoning` with timestamp throttle for reasoning; adds `setPendingStreamContent` between proposers to prevent stale content overwrite; clears pending content before aggregator phase; `_handleAiTeamStopped` now calls `cleanupTimers` to cancel proposer-phase throttle timer on cancel)
  - `lib/features/home/controllers/stream_controller.dart` (added `_pendingTotalTokens` mutable map to `scheduleThrottledUpdate` to fix `totalTokens` closure capture bug; `_cleanupStreamTimers` and `_cancelAllTimers` clean up the new map)
  - `lib/features/chat/widgets/ai_team_proposals_section.dart` (`_CollapsibleProposalBlock` gains `isStreaming` parameter; both `MarkdownWithCodeHighlight` calls (reasoning + content) now pass `isStreaming: widget.isStreaming` to defer Mermaid/PlantUML WebView2 during active streaming)
  - `CHANGES_LOG.md` (this entry)
- **Details**:
  - **Real-time streaming**: `_runProposerSilent` now fires an `onPartialContent(content, reasoning, reasoningStartAt)` callback on each stream chunk. The caller (`_executeAiTeamGeneration`) handles throttling via `streamController.scheduleThrottledUpdate` (60ms `Timer.periodic`, same as aggregator) for content, and a timestamp-based 60ms throttle for reasoning updates via `streamingContentNotifier.updateReasoning`. `MessageListView`'s `ValueListenableBuilder` picks up both content and reasoning from the notifier and renders them in real-time.
  - **Pending content sync**: Between proposers, `setPendingStreamContent` is called with the progress text to prevent the throttle timer from overwriting with stale content from the previous proposer. After all proposers complete, pending content is cleared to prevent leaking into the aggregator phase.
  - **Streaming-deferred proposals**: `AiTeamProposalsSection` now passes `isStreaming` to its `MarkdownWithCodeHighlight` calls. During active AI Team streaming (`message.isStreaming == true`), Mermaid/PlantUML code blocks in completed proposals render as collapsible source blocks (no WebView2), preventing the COM heap race crash path identified in v1.5.29 entry 124. Once streaming completes, the blocks automatically swap to rendered charts.
  - **Bug fix — totalTokens closure capture** (Fix 1): `scheduleThrottledUpdate` used `??=` to create the timer once; the `totalTokens` parameter was captured in the closure at first call and never updated. The proposer phase's `totalTokens: 0` permanently overwrote the aggregator's actual token count. Fixed by storing `totalTokens` in a mutable `_pendingTotalTokens[messageId]` map updated on every call. This also fixes a pre-existing bug where standard (non-AI-Team) streaming's token count was stuck at the first-chunk value.
  - **Bug fix — proposer-phase throttle timer leak on cancel** (Fix 2): Cancelling during the proposer phase left the throttle timer running (every 60ms), which kept overwriting `message.content` with the last proposer's text via `updateMessageInList`. Any subsequent rebuild would display the proposer text instead of "AI Team stopped". Fixed by calling `streamController.cleanupTimers(assistantMessage.id)` in `_handleAiTeamStopped`.
  - **Windows crash regression fallback**: This change leverages the existing streaming-deferred rendering infrastructure (v1.5.29). If users report Windows crash regression after this update, the fallback is to skip passing `onPartialContent` when `defaultTargetPlatform == TargetPlatform.windows` (Windows reverts to post-completion-only display). This can be done with a single platform check in `_executeAiTeamGeneration`.
- **Version bump**: 1.5.29+53 -> 1.5.30+54.

### 124. Comprehensive Windows Crash Root Cause Fix
- **Purpose**: Eliminate the residual native Windows crashes (`0xc0000374` heap corruption in `ntdll.dll`, `0xc0000005` access violation in `flutter_windows.dll` and unknown modules) that persisted after v1.5.28's parent-window `WM_GETOBJECT` intercept. These crashes occurred during AI response streaming even without external AT tools running. The fix applies a unified engineering principle - **defer native-resource-heavy widgets during streaming** - that was already applied to `SelectionArea` in v1.5.23/26/27 but had never been extended to WebView2-backed widgets (Mermaid/PlantUML). Four independent crash paths are addressed: (A) WebView2 init/dispose COM heap race, (B) child-window `WM_GETOBJECT` leakage, (C) WebView2 race-safe disposal guard, and (D) WinRT speech plugin thread safety.
- **Files Modified**:
  - `pubspec.yaml` (bumped version to `1.5.29+53`)
  - `installers/omnichat_setup.iss` (updated `MyAppVersion` to `1.5.29` and installer output filename)
  - `lib/shared/widgets/markdown_with_highlight.dart` (added `isStreaming` parameter to `MarkdownWithCodeHighlight` and `FencedCodeBlockMd`; defer Mermaid/PlantUML WebView2 creation during streaming to pure-Dart `_CollapsibleCodeBlock`)
  - `lib/features/chat/widgets/chat_message_widget.dart` (passed `isStreaming` to assistant content, translation, and reasoning `MarkdownWithCodeHighlight` call sites)
  - `windows/runner/flutter_window.h` (added `child_hwnd_` member and `ChildWndSubclassProc` static callback declaration)
  - `windows/runner/flutter_window.cpp` (installed `SetWindowSubclass` on the Flutter child window to intercept `WM_GETOBJECT` at the child level; reordered `OnDestroy` to remove subclass before controller teardown)
  - `windows/runner/CMakeLists.txt` (added explicit `comctl32.lib` link for `SetWindowSubclass`/`RemoveWindowSubclass`)
  - `lib/shared/widgets/mermaid_bridge_stub.dart` (added `_disposed`/`_initialized` race-safe guards in `_MermaidInlineWindowsViewState`; `_controller.dispose()` now skipped when `initialize()` is still in flight, leaving cleanup to Dart GC)
  - `lib/desktop/html_preview_dialog.dart` (same `_disposed`/`_initialized` race-safe pattern in `_HtmlPreviewDialogState`)
  - `dependencies/speech_to_text_windows/windows/speech_to_text_windows_plugin.h` (changed `HWND m_messageWindow` to `std::atomic<HWND>`; added `std::atomic<bool> m_isDestroyed`)
  - `dependencies/speech_to_text_windows/windows/speech_to_text_windows_plugin.cpp` (reordered destructor: mark `m_isDestroyed` first, then revoke WinRT event tokens, then destroy message window; `RunOnMainThread` checks `m_isDestroyed` and uses atomic `HWND` load; `DestroyMessageWindow` uses `exchange(nullptr)` for atomic clearing; `CreateMessageWindow` uses atomic store at end; `MessageWindowProc` checks `m_isDestroyed` before executing queued tasks)
  - `CHANGES_LOG.md`
- **Unified Root Cause Analysis**:
  - **Cross-version pattern**: Every historical crash fix (v1.5.18, v1.5.23, v1.5.26, v1.5.27, v1.5.28) shares a single engineering principle: **during streaming, defer or simplify widgets whose lifecycle involves native async resources (WebView2 COM, WinRT, SemanticsNode trees, QuickJS C heap)**. Each token chunk triggers a full `MarkdownWithCodeHighlight` rebuild, creating a "rebuild storm" that amplifies every latent native lifecycle race into statistical inevitability. v1.5.23/26/27 applied this principle to `SelectionArea` but never extended it to WebView2-backed Mermaid/PlantUML widgets.
  - **Crash #1 (`0xc0000374` ntdll heap corruption)**: During streaming, if a ` ```mermaid` code fence is present, each markdown rebuild creates/updates a `_MermaidInlineWindowsView` with a `winweb.WebviewController`. `initialize()` is async (native COM on a background thread). If the widget is disposed before `initialize()` completes (e.g. message scrolled out, list recycling, or fence code change), `dispose()` calls `_controller.dispose()` concurrently with the still-in-progress `initialize()`, both operating on the same COM heap. This is the source of `0xc0000374` (STATUS_HEAP_CORRUPTION).
  - **Crash #2/#3 (`0xc0000005` in unknown module)**: Secondary crash - once the heap is corrupted by crash #1, subsequent native operations read invalid memory at random addresses. The "unknown" faulting module (version 0.0.0.0) and variable fault offsets confirm this is a cascade effect.
  - **Crash #4 (`0xc0000005` in `flutter_windows.dll`)**: Separate path - v1.5.28 intercepts `WM_GETOBJECT` only on the **parent** window (`FlutterWindow::MessageHandler`). But the Flutter engine renders into a **child** window (`FlutterViewController`'s native HWND) which has its own `WndProc` set up by the engine. Windows itself sends `WM_GETOBJECT` to the child window for taskbar previews, Alt+Tab thumbnails, DWM compositing, etc., even without explicit AT tools. This activates the engine's `OnGetObject` -> `OnUpdateSemanticsEnabled(true)` path, which stays active permanently (no disable path). Subsequent streaming rebuilds trigger the SemanticsNode callback race, producing `0xc0000005`.
  - **Why v1.5.28 reduced but did not eliminate crashes**: v1.5.28 closed the parent-window `WM_GETOBJECT` path (reducing #4 frequency) but left crash #1 (WebView2 COM race) and the child-window path to #4 completely unaddressed.
- **Fix A (Root Cause - Streaming-Deferred Rendering)**:
  - `MarkdownWithCodeHighlight` and `FencedCodeBlockMd` now accept an `isStreaming` flag (default `false` for backward compatibility with static call sites).
  - When `isStreaming == true`, Mermaid and PlantUML code blocks render as a pure-Dart `_CollapsibleCodeBlock` (no native resource). When `isStreaming` flips to `false` (message completes streaming), the widget tree rebuilds and swaps in the real WebView2-based `_MermaidBlock` / `PlantUMLBlock` renderer.
  - This eliminates the WebView2 COM init/dispose race entirely during streaming - the dominant trigger for crash #1.
  - This is the same policy applied to `SelectionArea` in v1.5.23, now extended to all native-resource-heavy widgets.
  - `isStreaming` is passed from: (1) assistant content (`widget.message.isStreaming`), (2) translation section (`widget.message.isStreaming || translationInProgress`), (3) reasoning section (`widget.loading || widget.isParentStreaming`).
  - All other call sites (user messages, AI Team proposals, SelectCopy dialogs, HTML preview, export) retain the default `false`, since they render static/completed content.
- **Fix B (Defense - Child Window WM_GETOBJECT Double-Layer Guard)**:
  - After `SetChildContent(...)`, the runner now installs `SetWindowSubclass` on the Flutter engine's child window with a `ChildWndSubclassProc` that returns `0` for `WM_GETOBJECT`.
  - `RemoveWindowSubclass` is called in `OnDestroy` **before** destroying the Flutter controller, ensuring no teardown-time race.
  - This forms a double-layer guard (parent `MessageHandler` + child subclass), ensuring zero `WM_GETOBJECT` reaches the engine regardless of which window receives it.
  - `comctl32.lib` is explicitly linked in `CMakeLists.txt` for `SetWindowSubclass`/`RemoveWindowSubclass`/`DefSubclassProc`.
- **Fix C (Defense - WebView2 Race-Safe Init/Dispose Guard)**:
  - Both `_MermaidInlineWindowsViewState` and `_HtmlPreviewDialogState` now track `_disposed` and `_initialized` flags.
  - `_init()` checks `_disposed` after every `await` and bails out if the widget was disposed during initialization.
  - `dispose()` sets `_disposed = true` first, then only calls `_controller.dispose()` if `_initialized == true`. If `initialize()` is still in flight, native cleanup is left to Dart GC, avoiding the cross-thread COM heap race.
  - This is defensive hardening layered on top of Fix A - it protects any remaining WebView2 lifecycle scenarios (manual HTML preview dialog, future Mermaid usage outside streaming guard).
- **Fix D (Defense - WinRT Speech Plugin Thread Safety)**:
  - `m_messageWindow` changed from raw `HWND` to `std::atomic<HWND>`, eliminating data races from cross-thread reads.
  - `m_isDestroyed` (`std::atomic<bool>`) added, set at the very start of the destructor.
  - Destructor reordered: (1) flip `m_isDestroyed`, (2) revoke all WinRT event tokens and close recognizer under mutex, (3) only then destroy message window. The previous order (destroy window first, revoke tokens second) left a window where background callbacks could fire into a half-destroyed state.
  - `RunOnMainThread` checks `m_isDestroyed` on entry, uses atomic `HWND` load, and re-checks destroyed flag after potential `CreateMessageWindow` fallback.
  - `MessageWindowProc` checks `m_isDestroyed` before executing queued tasks, preventing use-after-free from tasks queued just before the destructor ran.
  - `CreateMessageWindow` stores the new HWND via atomic store (release ordering); `DestroyMessageWindow` exchanges to nullptr (acq-rel ordering) before `DestroyWindow`.
  - This fixes a long-standing latent UAF/data-race that was unrelated to streaming but could manifest during extended sessions with voice input.
- **Trade-offs**:
  - **Mermaid during streaming**: While `isStreaming == true`, ` ```mermaid` code blocks display as a collapsible code block showing the Mermaid source. Once streaming completes, the block automatically swaps to the rendered chart via WebView2. This is an **improvement** over the previous behavior (mid-stream WebView2 rendering that flickered on each chunk).
  - **Lost (same as v1.5.28)**: Windows screen readers remain unable to introspect OmniChat's Flutter widgets, now at both parent and child window layers.
  - **Preserved**: All text selection on completed messages (`SelectionArea` is completely untouched), keyboard navigation, mouse/touch interaction, copy/paste, WebView2 rendering (after streaming), all plugins.
- **Re-enabling in the future**: Both `WM_GETOBJECT` short-circuits (parent in `MessageHandler` and child in `ChildWndSubclassProc`) should be removed once upstream Flutter resolves the Windows engine AX 2.0 callback race. See v1.5.28 re-enabling instructions for validation steps. The streaming-deferred rendering (Fix A) is a permanent architectural improvement and should be retained regardless.
- **Version Bump**: `1.5.28+52` -> `1.5.29+53`.

---

## [v1.5.28] - 2026-07-26: Windows Crash Root Cause Fix — Disable Flutter Windows Semantics

### 123. Windows Crash Root Cause — Disable Flutter Windows Engine Semantics
- **Purpose**: Definitively resolve the recurring native Windows crashes (`0xc0000005` access violation in `flutter_windows.dll` and secondary `ntdll.dll` heap corruption) that occurred during AI response streaming. v1.5.27's restoration of inline `SelectionArea` made these crashes noticeably more frequent than v1.5.26, but the root cause is **not** `SelectionArea` itself — it is a Flutter Windows engine semantics lifecycle defect present since Flutter 3.22.
- **Files Modified**:
  - `pubspec.yaml` (bumped version to `1.5.28+52`)
  - `installers/omnichat_setup.iss` (updated `MyAppVersion` to `1.5.28` and installer output filename)
  - `windows/runner/flutter_window.cpp` (intercept `WM_GETOBJECT` at the top of `FlutterWindow::MessageHandler` and return `0`, preventing the Flutter Windows engine embedding's `OnGetObject` → `OnUpdateSemanticsEnabled(true)` call path)
  - `CHANGES_LOG.md`
- **Root Cause Analysis**:
  - User testing confirmed two facts that ruled out the prior `SelectionArea`-in-`ListView` hypothesis: (1) crashes occurred **while a response was still streaming**, (2) **the user performed no action** (no selection, scroll, or hover). This was incompatible with the v1.5.26 `SkParagraph` dangling-pointer theory which posited that the crash fired during list recycling with an active selection.
  - Cross-referenced public evidence: Flutter GitHub issue [#187994](https://github.com/flutter/flutter/issues/187994) (`flutter_windows.dll` 0xc0000005, deterministic offset, release-mode-only, reproduced on both 3.41.5 and 3.44.2), [#180560](https://github.com/flutter/flutter/issues/180560), and the community analysis on forum.itsallwidgets.com (silent `0xc0000005` / `0xc000041d` crashes in `flutter_windows.dll`, not surfaced to Sentry, attributed to engine semantics callbacks firing after engine/view destruction).
  - Engine source inspection (`flutter/shell/platform/windows/flutter_window.cc:765` `OnGetObject` → line 786 `OnUpdateSemanticsEnabled(true)`) confirms the trigger path: the Flutter Windows engine enables its AX 2.0 semantics pipeline whenever **any external process queries the window via `WM_GETOBJECT`** (Microsoft Active Accessibility / UI Automation). Unlike other platforms, Windows does not provide a "screen reader state changed" notification — instead the engine listens for `WM_GETOBJECT` requests from NVDA, JAWS, Narrator, Process Explorer, automation tools, Microsoft Diagnostics, or any UIA-walking software. Once enabled, the embedding's `FlutterWindowsEngine::UpdateSemanticsEnabled(true)` instantiates the `AccessibilityBridgeWindows`, which builds `FlutterPlatformNodeDelegate` objects for every node in the framework's SemanticsNode tree.
  - In a chat app, every streamed chunk triggers a `MarkdownWithCodeHighlight` rebuild that constructs a new SemanticsNode tree (especially large for complex content: tables, LaTeX via `flutter_math_fork`, multiple code blocks). The semantics rebuild storm dramatically amplifies callback race frequency inside the AX 2.0 pipeline, eventually tripping access violations during view destruction (`0xc0000005`). `SelectionArea` further multiplies the SemanticsNode count via the selection registrar — which is exactly why v1.5.27's restoration of inline `SelectionArea` made crashes more frequent **without** actually being the root cause.
  - **Note on engine switches**: the `FLUTTER_ENGINE_SWITCHES` environment variable is **only** honored in debug/profile builds (guarded by `#ifndef FLUTTER_RELEASE` in `flutter/shell/platform/common/engine_switches.cc`), so the straightforward env-var approach cannot disable semantics in OmniChat's release installer. The Windows public embedding header (`flutter_windows.h`) does not expose a `FlutterDesktopEngineUpdateSemanticsEnabled` API, and the accessibility message channel from Dart (`SystemChannels.accessibility`) only accepts `announce` events — neither path can disable semantics from Dart.
- **Fix**: Intercepting `WM_GETOBJECT` at the **runner's C++ layer** (in `FlutterWindow::MessageHandler` before `flutter_controller_->HandleTopLevelWindowProc` is called) and returning `0`. This is the only point where the Flutter Windows embedding's `OnGetObject` can be safely bypassed, because:
  - `WM_GETOBJECT` is a `Win32` window message that arrives at the top-level window via the standard `WndProc` dispatch, which is fully owned by OmniChat's `FlutterWindow`
  - The default Flutter embedding code (`case WM_GETOBJECT:` in `flutter/shell/platform/windows/flutter_window.cc:680`) is reached only if the project-side `MessageHandler` returns without overriding — by short-circuiting before that path is taken, the engine never invokes `OnGetObject`, never calls `OnUpdateSemanticsEnabled(true)`, never instantiates `AccessibilityBridgeWindows`, and never builds SemanticsNode trees
  - Returning `0` from `WM_GETOBJECT` is the MSDN-documented "no accessible object available" reply — AT clients will see an inaccessible window and skip it, but the engine's native semantics callback race is eliminated at the source
- **Trade-offs**:
  - **Lost**: Windows screen readers (NVDA / JAWS / Narrator) and Windows Voice Access / UI Automation-based tools can no longer introspect OmniChat's Flutter widgets. This impacts visually impaired users relying on assistive technology. The app's own `TtsProvider` (a separate TTS path, not UIA-based) still works for read-aloud of message content.
  - **Preserved**: All keyboard navigation, mouse/touch interaction, text selection, copy/paste, WebView2 rendering, Mermaid rendering, Windows hotkeys, and tray functionality. There is no perceptible difference for the vast majority of users, and performance improves slightly from skipping SemanticsNode tree construction.
  - **v1.5.27's inline `SelectionArea` restoration is intentionally KEPT**: with semantics disabled at the runner layer, `SelectionArea` no longer amplifies the (now-eliminated) SemanticsNode rebuild storm. Windows users therefore retain inline text selection on completed AI responses — the v1.5.27 usability goal is preserved without re-introducing the crash.
- **Re-enabling in the future**: The `if (message == WM_GETOBJECT) { return 0; }` short-circuit in `windows/runner/flutter_window.cpp` should be **removed** once upstream Flutter resolves the Windows engine AX 2.0 callback race (tracked across flutter/flutter issues [#143814](https://github.com/flutter/flutter/issues/143814), [#175016](https://github.com/flutter/flutter/issues/175016), [#180560](https://github.com/flutter/flutter/issues/180560), [#187994](https://github.com/flutter/flutter/issues/187994)). To validate whether a future Flutter version is safe, remove the short-circuit, rebuild in release mode, then run a streaming session with complex content (tables + LaTeX + multiple code blocks) for 30+ minutes; if no `0xc0000005` event appears in the Windows Event Viewer (Application log, Event ID 1000, faulting module `flutter_windows.dll`), and NVDA / Narrator can correctly read the message text, the workaround is no longer required.
- **Version Bump**: `1.5.27+51` → `1.5.28+52`.

---

## [v1.5.27] - 2026-07-26: API Tool Result Truncation, WinRT Thread Validation & SelectCopy Enhancement

### 122. Initial Request Tool Truncation, WinRT Thread ID Safety & SelectCopy Full Text
- **Purpose**: Resolve 5 medium-risk vulnerabilities identified during code review: (1) Truncate historical tool results on initial API request, (2) Support List/Map tool result block truncation, (3) Validate main thread ID in WinRT speech plugin, (4) Revoke WinRT event tokens on plugin destruction, (5) Fix `EscapeJsonString` backslash escaping, and (6) Enhance `SelectCopyDesktopDialog` to display and copy full content including Reasoning and Translation sections.
- **Files Modified**:
  - `pubspec.yaml` (bumped version to `1.5.27+51`)
  - `installers/omnichat_setup.iss` (updated MyAppVersion to `1.5.27`)
  - `lib/core/services/api/chat_api_service.dart`
  - `lib/features/chat/widgets/chat_message_widget.dart`
  - `lib/desktop/select_copy_dialog.dart`
  - `lib/desktop/html_preview_dialog.dart`
  - `dependencies/speech_to_text_windows/windows/speech_to_text_windows_plugin.h`
  - `dependencies/speech_to_text_windows/windows/speech_to_text_windows_plugin.cpp`
  - `CHANGES_LOG.md`
- **Details**:
  - **API Initial Request Tool Result Truncation**: Applied `_truncateToolResultsInMessages` to `safeMessages` inside `sendMessageStream` before dispatching to OpenAI, Claude, and Google stream providers, preventing historical tool output OOM crashes on initial message send.
  - **Nested Tool Result Truncation**: Extended `_truncateToolResultsInMessages` to handle OpenAI content blocks as `List`, Claude `tool_result` content as `List` of text blocks, and Google `functionResponse` structured `Map` results.
  - **WinRT Main Thread ID Validation**: Added `m_mainThreadId` capturing in `SpeechToTextWindowsPlugin` constructor. `RunOnMainThread` now verifies `GetCurrentThreadId() == m_mainThreadId` before attempting to recreate `m_messageWindow`, preventing window creation on background message loops.
  - **WinRT Event Revocation & Mutex Lock**: Updated plugin destructor to lock `m_mutex` and explicitly revoke `m_hypothesisToken`, `m_resultToken`, and `m_completedToken` subscriptions before closing `SpeechRecognizer`.
  - **JSON Backslash Escape Fix**: Fixed `EscapeJsonString` in C++ plugin to output standard `\\` instead of literal string.
  - **Translation Selection Area Bypass**: Added `translationInProgress` check to bypass `SelectionArea` during active translation streaming.
  - **SelectCopy Full Content Support**: Updated `SelectCopyDesktopDialog` to format and render complete message content including Reasoning/Thinking blocks and Translation blocks.
  - **HTML Preview Console SelectionArea Bypass**: Bypassed `SelectionArea` wrapping `ListView.builder` inside `html_preview_dialog.dart` on Windows (`defaultTargetPlatform == TargetPlatform.windows`), eliminating the final remaining `SkParagraph` dangling pointer crash source in `flutter_windows.dll` (`0xc0000005`).

---

## [v1.5.26] - 2026-07-26: Windows Crash Fix — Complete SelectionArea Bypass & WinRT Thread Safety

### 121. Windows Crash Fix — Complete SelectionArea Bypass in Message Lists & WinRT Thread Guard
- **Purpose**: Fix non-deterministic Windows crashes (`0xc0000005` in `flutter_windows.dll`, `0xc0000374` in `ntdll.dll`, `ucrtbase.dll`) caused by (1) Flutter Windows engine's native `SkParagraph` dangling pointers when `SelectionArea` is used inside scrolling `ListView.builder`, and (2) `speech_to_text_windows` fallback executing tasks directly on WinRT background threads when message window handle is lost.
- **Files Modified**:
  - `pubspec.yaml` (bumped version to `1.5.26+50`)
  - `installers/omnichat_setup.iss` (updated MyAppVersion to `1.5.26` and installer output filename)
  - `lib/features/chat/widgets/chat_message_widget.dart`
  - `lib/features/chat/widgets/ai_team_proposals_section.dart`
  - `lib/core/services/mcp/kelivo_js/kelivo_js_server.dart`
  - `dependencies/speech_to_text_windows/windows/speech_to_text_windows_plugin.cpp`
  - `CHANGES_LOG.md`
- **Details**:
  - **Message List SelectionArea Bypass on Windows**: On Windows (`defaultTargetPlatform == TargetPlatform.windows`), `SelectionArea` is now completely bypassed across all message list items (`ChatMessageWidget` user messages, assistant content, reasoning content, translation blocks, and `AiTeamProposalsSection`). Text copying and selection remain fully functional via the dedicated `SelectCopyPage` / `SelectCopyDialog` / `SelectCopySheet` modal windows.
  - **WinRT Native Thread Safety**: Removed unsafe direct `task()` fallback execution in `SpeechToTextWindowsPlugin::RunOnMainThread` when `PostMessage` fails or `m_messageWindow` is uninitialized. `RunOnMainThread` now attempts to recreate the window if missing, and safely drops background tasks if the window is unavailable, preventing WinRT background thread pool calls from invoking `MethodChannel` and corrupting process heap memory (`0xc0000374`).
  - **QuickJS Background Isolate Isolation**: Refactored `kelivo_js_server.dart` to offload local JavaScript tool execution (`run_javascript`) into a dedicated background Isolate via `compute()` with a 5-second execution timeout guard. This isolates QuickJS C Native Heap memory creation, evaluation, and GC/disposal from the main UI Isolate, preventing C-level heap corruption from impacting the UI thread.

---

## [v1.5.25] - 2026-07-25: Gemini 3.5 Lite Thinking Level Translation & Reasoning Documentation

### 120. Gemini 3.5 Lite & 3.x Lite Reasoning Level Translation & Model Mapping
- **Purpose**: Expand Google Gemini 3 series regex matching in `ChatApiService` to include `gemini-3.5-lite` and all `gemini-3.x-lite` model variants, ensuring their thinking effort options map dynamically to Gemini official `thinkingLevel` parameters (`minimal`, `low`, `medium`, `high`) instead of falling back to raw token budgets.
- **Files Modified**:
  - `lib/core/services/api/chat_api_service.dart`
  - `omnichat_reasoning_approach.md` (NEW: OmniChat reasoning mechanism architecture document)
  - `kelivo_reasoning_approach.md` (NEW: Upstream Kelivo reasoning design principles document)
  - `rikkahub_reasoning_approach.md` (NEW: RikkaHub architecture and comparison document)
  - `CHANGES_LOG.md`
- **Details**:
  - **Regex Expansion**: Updated `isGemini3FlashOrLite` regex in `chat_api_service.dart` from `RegExp(r'gemini-3-flash(-preview)?')` to `RegExp(r'gemini-3.*-(flash|lite)(-preview)?')`.
  - **Dynamic Level Mapping**: `gemini-3.5-lite` now maps OmniChat's thinking effort UI options: Off (`0`) -> `minimal` (minimal thinking), Light (`1024`) -> `low`, Medium (`16000`) -> `medium`, Heavy (`32000`) / Auto (`-1`) -> `high`.
  - **Architecture Documentation**: Documented reasoning budget translation, provider key collision workarounds (`"reasoning_effort": "null"`), upstream Kelivo design roots, and RikkaHub comparison in three standalone `.md` files.

---

## [v1.5.24] - 2026-07-19: AI Team — Chain Mixture of Agents (CMoA) Mode & Tool Integration

## [v1.5.23] - 2026-07-19: Windows Crash Fix — SelectionArea Bypass for Reasoning & Translation

### 117. Windows Crash Fix — SelectionArea Bypass during Active Typewriter Streaming (Reasoning & Translation)
- **Purpose**: Fix a non-deterministic Windows crash (`0xc0000005` in `flutter_windows.dll`) occurring while receiving typewriter streaming outputs when reasoning blocks (`_ReasoningSection`) or translation sections have completed loading but the main message is still actively streaming.
- **Files Modified**:
  - `pubspec.yaml` (bumped version to `1.5.23+48`)
  - `installers/omnichat_setup.iss` (bumped MyAppVersion to `1.5.23` and installer output filename)
  - `lib/features/chat/widgets/chat_message_widget.dart`
  - `CHANGES_LOG.md`
- **Details**:
  - **Reasoning Section Selection Bypass**: Passed `isParentStreaming: widget.message.isStreaming` into `_ReasoningSection`. When the parent message is streaming, `SelectionArea` is completely bypassed even if the reasoning text itself has finished loading (`loading = false`). This prevents Flutter's native `SkParagraph` / `Libtxt` from attempting dynamic text geometry calculations on active selection during typewriter updates.
  - **Translation Section Selection Bypass**: Wrapped translation section in `widget.message.isStreaming` check, bypassing `SelectionArea` during active streaming output.
  - **New Preset Assistant**: Integrated **Deep Research Assistant** (`深度研究助理`, user-deletable) into default assistant initializers with a multi-round deep reasoning & research system prompt protocol.
  - **Version Bump**: `1.5.22+47` → `1.5.23+48`.

### 118. AI Team — Enable Tool Calling for Aggregator Model
- **Purpose**: Enable external tool definitions (`toolDefs`) and execution callbacks (`onToolCall`) for the aggregator model in the AI Team Mixture-of-Agents pipeline, matching the proposer models' capabilities.
- **Files Modified**:
  - `lib/features/home/controllers/chat_actions.dart`
  - `CHANGES_LOG.md`
  - `OmniChat_Project_Plan.md`
- **Details**:
  - **Aggregator Tool Execution**: Updated `_executeAiTeamGeneration` to pass `ctx.toolDefs` and `ctx.onToolCall` into `aggCtx` (previously hardcoded to `const []` and `null`). When the user enables tools (web search, fetch, local JS MCP engine, etc.) on the chat toolbar, the aggregator model can now invoke tools during the synthesis phase, matching proposer behavior.


### 119. AI Team — Add Chain Mixture of Agents (CMoA) Mode
- **Purpose**: Implement a configurable toggle to switch the AI Team from a Parallel (MoA) pipeline to a sequential Chain (CMoA) pipeline (Proposer -> Critics -> Aggregator), providing deep reflection and synthesis capability.
- **Files Modified**:
  - `lib/core/models/ai_team_config.dart`
  - `lib/core/providers/ai_team_provider.dart`
  - `lib/features/home/controllers/chat_actions.dart`
  - `lib/features/chat/widgets/ai_team_proposals_section.dart`
  - `lib/features/ai_team/pages/ai_team_page.dart`
  - `lib/desktop/setting/ai_team_pane.dart`
  - `lib/l10n/app_en.arb`, `app_zh.arb`, `app_zh_Hans.arb`, `app_zh_Hant.arb`
  - `CHANGES_LOG.md`
- **Details**:
  - **Data Schema & Config**: Introduced `AiTeamMode` enum (parallel, chain). Added `criticCount` (0~3) and three independent system prompts for chain mode (Proposer Prompt A, Critic Prompt B, Aggregator Prompt C) to `AiTeamConfig` with full JSON serialization.
  - **Sequential Chain Pipeline**: In CMoA mode, run Proposer first, then sequential Critics. For Critic $i$, its system prompt is set to Critic Prompt B, and preceding outputs are stitched into the conversation history so each critic sees the work as a continuing dialogue.
  - **Aggregator Synthesis**: The final aggregator synthesis combines the initial proposer output, all critic self-audit outputs, and Aggregator Prompt C.
  - **Adaptive Settings UI**: Reconfigured settings pages on both mobile and desktop. Selecting Chain mode hides the "Proposer Count" selector, and dynamically displays the "Auditor Count" selector (0~3), Proposer/Critic slot picker configuration, and prompts editor inputs for Prompt A, B, and C.
  - **Localizations**: Added all mode titles, auditor counts, critic status texts, and labels in English, Traditional Chinese, and Simplified Chinese.

---

## [v1.5.22] - 2026-07-15: Context Management & Compression Aligned with Upstream

### 115. Context Management — Clear & Compress Context Integration
- **Purpose**: Align context clearing functionality with upstream (Kelivo)'s "Context Management" bottom sheets and dropdown popovers, and add the "Compress Context" summary generation feature.
- **Files Modified**:
  - `pubspec.yaml` (bumped version to `1.5.22+47`)
  - `installers/omnichat_setup.iss` (bumped MyAppVersion to `1.5.22` and installer file output name)
  - `lib/icons/lucide_adapter.dart` (added `package2` and `workflow` icons)
  - `lib/l10n/app_en.arb`, `lib/l10n/app_zh.arb`, `lib/l10n/app_zh_Hans.arb`, `lib/l10n/app_zh_Hant.arb` (added context management, compression settings, and dialog labels)
  - `lib/theme/app_font_weights.dart` (NEW: font weight normalizer utility)
  - `lib/shared/widgets/ios_form_text_field.dart` (NEW: iOS style form input text field)
  - `lib/shared/widgets/loading_dialog_card.dart` (NEW: activity indicator loading dialog box overlay)
  - `lib/core/providers/settings_provider.dart` (added configuration keys, default prompt template, getters/setters/resetters for the "Compress Model")
  - `lib/features/home/controllers/home_view_model.dart` (added `CompressContextOptions`, `CompressContextLimitMode`, and the `compressContext()` action. Refactored the context remaining message count logic)
  - `lib/features/home/controllers/home_page_controller.dart` (delegated `compressContext()` action to view model)
  - `lib/features/chat/widgets/context_management_sheet.dart` (NEW: options bottom sheet widget with Clear Context and Compress Context actions)
  - `lib/features/chat/widgets/bottom_tools_sheet.dart` (swapped Clear Context row for Context Management with trailing chevron)
  - `lib/features/home/widgets/chat_input_bar.dart` & `lib/features/home/widgets/chat_input_section.dart` (desktop dropdown anchored popover menu support for context management)
  - `lib/features/home/pages/home_page.dart` (wired in popover callbacks, sheet modals, and options input dialogs)
  - `lib/desktop/setting/default_model_pane.dart` & `lib/features/model/pages/default_model_page.dart` (embedded "Compress Model" and "Compress Prompt" settings card)
  - `test/home_view_model_compress_context_test.dart` (NEW: unit tests for limits, text builders, and message counters)
- **Details**:
  - **Context Management Sheet**: Added a sleek bottom sheet on mobile devices. When "Clear Context" is tapped, it opens the sheet providing both "Clear Context" (marks boundary) and "Compress Context" (summarizes and forks to new chat) options.
  - **Desktop Composer Toolbar**: Integrated an anchored popover with both options when clicking the context management icon.
  - **Context Compression**: Binds a dedicated LLM model configured in Settings. Feeds conversation context (optionally limited by characters/mode) through a customized prompt. Creates a new conversation using the generated summary and switches the user active session to it automatically.
  - **Remaining Message Count**: Fixed context remaining message counting logic by utilizing complete messages in the view model instead of lazy-loaded segments.
  - **Version Bump**: `1.5.21+46` → `1.5.22+47`.

---

### 116. Windows Crash Fix — SelectionArea Bypass during Active Typewriter Streaming
- **Purpose**: Fix a non-deterministic Windows crash (0xc0000005 in `flutter_windows.dll`) occurring while receiving typewriter streaming outputs. The crash was triggered by `SelectionArea` attempting to recalculate selection geometries/offsets on a dynamically updating text widget while the user hovered or had active selection.
- **Files Modified**:
  - `lib/features/chat/widgets/chat_message_widget.dart`
  - `lib/features/chat/widgets/ai_team_proposals_section.dart`
- **Details**:
  - **Typewriter Selection Bypass**: During active streaming/loading (where typewriter updates occur), `SelectionArea` is completely bypassed. This prevents Flutter's native `SkParagraph` / `Libtxt` from calculating dynamic text geometries, eliminating the memory access violation crash.
  - **Preserved Functionality**: Once streaming/loading completes, a rebuild is triggered and `SelectionArea` wrapping is restored, allowing full copy/select capability on finished static messages.

---

## [v1.5.21] - 2026-06-30: AI Team Label, Real-time Proposals, Mistral Fix

### 114. AI Team — Fix Real-time UI Updates (unawaited _executeAiTeamGeneration)
- **Purpose**: Fix a critical rendering bug where AI Team progress text ("Proposal X/N") and real-time proposals were not visible during the proposal phase on Windows (nothing shown at all) and Android (only progress text, no proposals section). The root cause was that `sendMessage` and `regenerateAtMessage` used `await _executeAiTeamGeneration(...)`, which blocked the entire call until all proposers + aggregator finished. This prevented `sendMessage` from returning, which prevented `HomePageController.notifyListeners()` from firing, which prevented `MessageListView` from rebuilding, which prevented `ValueListenableBuilder` from mounting — so all `StreamingContentNotifier` updates had no UI listener.
- **Files Modified**:
  - `lib/features/home/controllers/chat_actions.dart` (two call sites: `sendMessage` and `regenerateAtMessage` — changed `await _executeAiTeamGeneration(ctx, aiTeamConfig)` to `unawaited(_executeAiTeamGeneration(ctx, aiTeamConfig))`)
- **Details**:
  - **Root cause**: `onMessagesChanged?.call()` is wired to `HomeViewModel.notifyListeners()`, but `HomeViewModel` has zero registered listeners. The actual UI rebuild path is `HomePageController.notifyListeners()` → `_onControllerChanged` → `setState`. This only fires after `await _viewModel.sendMessage(...)` returns. Non-AI-Team streaming works because `_executeGeneration` sets up a subscription and returns immediately; `sendMessage` returns; `notifyListeners()` fires. AI Team `await _executeAiTeamGeneration(...)` blocked this return until the entire pipeline (proposers + aggregator) finished.
  - **Fix**: Changed `await` to `unawaited(...)` at both call sites (`sendMessage` and `regenerateAtMessage`). Now `sendMessage` returns immediately after launching the AI Team pipeline in the background. `notifyListeners()` fires, `MessageListView` rebuilds, `ValueListenableBuilder` mounts, and all subsequent `updateContent()` / `updateProposals()` calls have a live listener to rebuild the UI.
  - **Timeline**: After the fix, the sequence is: (1) `_executeAiTeamGeneration` starts, pushes "Proposal 1/N" to notifier; (2) hits `await _runProposerSilent(...)`, yields to event loop; (3) `sendMessage` returns → `notifyListeners()` → `MessageListView` rebuilds → `ValueListenableBuilder` mounts; (4) reads current notifier value ("Proposal 1/N") → displays it; (5) proposer completes → `updateProposals()` → notifier fires → rebuild → proposals section appears.
  - **No version bump**: This is a bug fix for the v1.5.21 real-time proposals feature.

---

### 113. AI Team — Collaboration Label, Real-time Proposals, Mistral Aggregator Fix
- **Purpose**: Address three AI Team issues: (1) rename the proposals box header from "最終回答"/"Final Answer" to "協作過程"/"Collaboration Process" since it holds proposals, not the final answer; (2) show proposals in real-time during the proposal phase instead of waiting for all proposers to complete; (3) fix HTTP 400 `invalid_request_message_order` error when using Mistral as the aggregator.
- **Files Modified**:
  - `lib/l10n/app_en.arb` / `app_zh.arb` / `app_zh_Hans.arb` / `app_zh_Hant.arb` (renamed `aiTeamFinalAnswerLabel` value; added new `aiTeamAggregatorUserPrompt` key)
  - `lib/l10n/app_localizations*.dart` (regenerated via `flutter gen-l10n`)
  - `lib/features/home/controllers/streaming_content_notifier.dart` (added `aiTeamProposalsJson` field to `StreamingContentData`; added `updateProposals()` method; preserved the field across all existing update methods and `==`/`hashCode`)
  - `lib/features/home/widgets/message_list_view.dart` (`ValueListenableBuilder` now passes `data.aiTeamProposalsJson` into `streamingMessage.copyWith()`)
  - `lib/features/home/controllers/chat_actions.dart` (`_buildAggregatorMessages` now accepts `aggregatorUserPrompt` and appends a trailing `{role:'user'}` message after proposals; `_executeAiTeamGeneration` proposer loop now pushes partial proposals JSON to `StreamingContentNotifier.updateProposals()` + persists via `updateMessageSilent()` + updates `_messages[idx]` after each proposer completes)
  - `pubspec.yaml` (version bump)
  - `installers/omnichat_setup.iss` (version bump)
- **Details**:
  - **Label rename**: The proposals section header was misleadingly labeled "最終回答". Renamed to "協作過程"/"Collaboration Process" to reflect that it contains the collaboration/proposal output, not the aggregator's final answer.
  - **Real-time proposals**: Previously proposals were only persisted and rendered after the entire AI Team flow (including aggregator) completed. Now, after each proposer finishes, its result is immediately: (a) pushed to `StreamingContentNotifier` via `updateProposals()` so `ValueListenableBuilder` triggers a rebuild showing the updated `AiTeamProposalsSection`, (b) persisted to DB via `updateMessageSilent()`, and (c) updated in the in-memory `_messages` list. The `AiTeamProposalsSection` widget filters out empty-content proposals, so only completed proposals are visible at any given moment during the phase.
  - **Mistral aggregator fix**: Mistral API requires the last message role to be `user` or `tool` (or `assistant` with prefix). The original `_buildAggregatorMessages` inserted proposals as `{role:'assistant'}` messages at the end, causing the last role to be `assistant`, which Mistral rejects with HTTP 400. Fixed by appending a localized trailing `{role:'user'}` message (e.g., "Please review the proposals above and synthesize them into a single, coherent final answer.") after the proposals. This is a standard MoA pattern and is harmless to OpenAI, Gemini, and other providers.
  - **Version bump**: `1.5.20+45` → `1.5.21+46`.

---

## [v1.5.20] - 2026-06-30: AI Team UX Enhancements

### 111. AI Team — Progress Indicator, Rich Proposals, Localized Prompts, Layered UI
- **Purpose**: Enhance the AI Team feature with (1) real-time progress indication during proposal phase, (2) proposer reasoning + tool-call capture, (3) localized default prompts that switch with app language, (4) proposals moved before aggregator content, (5) layered collapsible proposal UI (thinking → tools → answer).
- **Files Modified**:
  - `lib/core/models/ai_team_config.dart` (added `useDefaultProposalPrompt` / `useDefaultAggregatorPrompt` flags)
  - `lib/core/services/ai_team_store.dart` (flag-aware `setProposalPrompt` / `setAggregatorPrompt` / `resetPrompts`)
  - `lib/core/providers/ai_team_provider.dart` (exposed `useDefaultProposalPrompt` / `useDefaultAggregatorPrompt` getters)
  - `lib/features/home/controllers/chat_actions.dart` (`_runProposerSilent` returns `Map` with content/reasoning/toolCalls; `_executeAiTeamGeneration` resolves l10n prompts, pushes progress text via `StreamingContentNotifier`, stores enriched proposals JSON; added `AppLocalizations` import)
  - `lib/features/chat/widgets/ai_team_proposals_section.dart` (rewritten: layered `_CollapsibleProposalBlock` with thinking/tools/answer sections, tool-call item rendering)
  - `lib/features/chat/widgets/chat_message_widget.dart` (moved `AiTeamProposalsSection` from after content to before reasoning)
  - `lib/features/ai_team/pages/ai_team_page.dart` (prompt editors show l10n default when `useDefault=true`)
  - `lib/desktop/setting/ai_team_pane.dart` (same l10n-aware prompt display)
  - `lib/l10n/app_en.arb` / `app_zh.arb` / `app_zh_Hans.arb` / `app_zh_Hant.arb` (7 new keys: default prompts, progress text, thinking label, tool-calls label, aggregator label)
  - `lib/l10n/app_localizations*.dart` (regenerated via `flutter gen-l10n`)
  - `pubspec.yaml` (version bump)
  - `installers/omnichat_setup.iss` (version bump)
- **Details**:
  - **Progress indicator**: During the proposal phase, `StreamingContentNotifier.updateContent()` pushes "AI Team running… Proposal X/N" (localized) to the streaming UI, replacing the empty placeholder. This is cleared before the aggregator starts.
  - **Proposer reasoning capture**: `_runProposerSilent` now accumulates `chunk.reasoning` into a `reasoningBuffer` alongside content, and captures `chunk.toolCalls` / `chunk.toolResults`. Tool results are truncated to 2000 chars to prevent storage bloat.
  - **Enriched proposals JSON**: Each proposal entry now contains `{providerKey, modelId, content, reasoning, toolCalls}`, where `toolCalls` is a list of `{id, name, arguments, result?}`.
  - **Localized default prompts**: New ARB keys `aiTeamDefaultProposalPrompt` / `aiTeamDefaultAggregatorPrompt` provide language-specific defaults (en, zh-Hans, zh-Hant). When `useDefaultProposalPrompt=true` (the default), the l10n version is used at runtime; when the user edits a prompt, the flag flips to `false` and the customized text is used regardless of app language.
  - **Proposals before content**: `AiTeamProposalsSection` is now rendered above the aggregator's reasoning section, matching the logical reading order: proposals → aggregator thinking → aggregator answer.
  - **Layered collapsible UI**: Each proposal block has individually collapsible Thinking and Tool Calls sections (default collapsed), with the final answer always visible. Tool-call items show name, arguments, and truncated results in a monospace card.
  - **Version bump**: `1.5.19+44` → `1.5.20+45`.

---

## [v1.5.20] - 2026-06-30: AI Team Polish — Restore-Default Button & Proposal-Phase HTTP Cancel

### 112. AI Team — Per-Prompt Restore Default & Proposal-Phase HTTP Cancellation
- **Purpose**: Address two AI Team UX/gap issues: (1) the prompt editor only had Cancel/Save and no way to revert a single prompt to its localized default, and (2) the Stop button during the proposal phase needed to abort the underlying HTTP request as well as the local stream subscription.
- **Files Modified**:
  - `lib/features/ai_team/pages/ai_team_page.dart` (mobile prompt editor now shows a "Restore Default" button between Cancel and Save)
  - `lib/desktop/setting/ai_team_pane.dart` (desktop prompt dialog now shows a "Restore Default" button between Cancel and Save)
  - `lib/core/providers/ai_team_provider.dart` (existing `update()` used to flip `useDefault*Prompt` flags)
  - `lib/core/services/ai_team_store.dart` (existing flag-aware prompt storage)
  - `lib/features/home/controllers/chat_actions.dart` (`cancelStreaming()` now calls `ChatApiService.cancelRequest('${cid}_proposer')` when `_aiTeamInProposalPhase` is true)
  - `lib/core/services/api/chat_api_service.dart` (existing `cancelRequest()` + `_activeCancelTokens` used by proposer `requestId: '${conversationId}_proposer'`)
  - `lib/l10n/app_en.arb` / `app_zh.arb` / `app_zh_Hans.arb` / `app_zh_Hant.arb` (new `aiTeamRestoreDefaultPrompt` key)
  - `lib/l10n/app_localizations*.dart` (regenerated via `flutter gen-l10n`)
- **Details**:
  - **Per-prompt Restore Default**: Both mobile bottom-sheet and desktop AlertDialog now expose a third button labeled "Restore default" (localized). Tapping it sets the corresponding `useDefaultProposalPrompt` / `useDefaultAggregatorPrompt` flag back to `true` and closes the editor, causing the preview/editor to show the l10n default again. The existing global `RotateCcw` reset button still resets both prompts at once.
  - **Proposal-phase HTTP cancellation**: `_runProposerSilent()` already tagged each proposer stream with `requestId: '${conversationId}_proposer'`. `cancelStreaming()` now checks `_aiTeamInProposalPhase` and, after completing the cancel completer and cancelling the local subscription, calls `ChatApiService.cancelRequest('${cid}_proposer')` to abort the underlying Dio HTTP request. This prevents the network call from continuing after the user hits Stop.
  - **No version bump**: These are polish items on top of the v1.5.20 AI Team UX enhancements.

---

## [v1.5.19] - 2026-06-30: AI Team (Mixture of Agents)

### 110. AI Team Feature — Multi-Model Proposal & Aggregation Pipeline
- **Purpose**: Implement a Mixture-of-Agents (MoA) feature where 1–4 "proposer" models answer the user's question independently, and an "aggregator" model synthesizes their outputs into a single final response.
- **Files Added**:
  - `lib/core/models/ai_team_config.dart`
  - `lib/core/services/ai_team_store.dart`
  - `lib/core/providers/ai_team_provider.dart`
  - `lib/features/ai_team/pages/ai_team_page.dart` (mobile settings page)
  - `lib/desktop/setting/ai_team_pane.dart` (desktop settings pane)
  - `lib/features/chat/widgets/ai_team_proposals_section.dart` (collapsible "最終回答" grey box)
- **Files Modified**:
  - `lib/main.dart` (register `AiTeamProvider`)
  - `lib/features/settings/pages/settings_page.dart` (nav row in Models & Services)
  - `lib/desktop/desktop_settings_page.dart` (enum + menu + title + content switcher)
  - `lib/features/home/controllers/chat_actions.dart` (AI Team branch in `sendMessage`, `_executeAiTeamGeneration`, `_runProposerSilent`, `_cloneForProposer`, `_buildAggregatorMessages`, `_handleAiTeamStopped`, cancel handling, `_finishStreaming` persistence)
  - `lib/core/services/chat/chat_service.dart` (`updateMessage` + `updateMessageSilent` accept `aiTeamProposalsJson`)
  - `lib/core/models/chat_message.dart` (HiveField 16: `aiTeamProposalsJson`)
  - `lib/core/models/chat_message.g.dart` (regenerated via build_runner)
  - `lib/features/chat/widgets/chat_message_widget.dart` (render `AiTeamProposalsSection` after assistant content)
  - `lib/features/home/widgets/chat_input_bar.dart` (new toolbar button between Reasoning and Learning mode)
  - `lib/features/home/widgets/chat_input_section.dart` (prop wiring + `AiTeamProvider` watch)
  - `lib/features/home/pages/home_page.dart` (`_openAiTeamSettings` callback)
  - `lib/icons/lucide_adapter.dart` (added `Users` icon)
  - `lib/l10n/app_en.arb`, `app_zh.arb`, `app_zh_Hans.arb`, `app_zh_Hant.arb` (16 new localization keys)
  - `pubspec.yaml` (version bump)
- **Details**:
  - **Serial execution**: Proposers run sequentially, not in parallel, to avoid memory spikes during multi-round tool-call + web-search conversations. This aligns with the v1.5.16–v1.5.18 fetch memory optimization work.
  - **Proposal system prompt**: Appended (not replaced) to the existing system message, preserving assistant persona, instruction injection, memory, and recent chat context (audit finding K3).
  - **Proposer stream subscription**: Managed via a local variable, NOT stored in `_conversationStreams` (audit finding K1). Only the aggregator's stream subscription is registered for cancellation.
  - **Placeholder model ID**: When AI Team is enabled and an aggregator is explicitly configured, the assistant placeholder's `modelId`/`providerId` are set to the aggregator's values (audit finding K2).
  - **Per-proposer error handling**: If a single proposer fails (429, timeout, network error), it is skipped and the loop continues. Only if ALL proposers fail does the entire AI Team flow abort (audit finding I1).
  - **Cancellation**: Cancelling during the proposal phase cancels the current proposer subscription via local variable, marks the placeholder with "AI Team stopped", and persists any partial proposals (audit finding I3).
  - **Proposals rendering**: After the aggregator finishes, proposals are persisted as JSON in `ChatMessage.aiTeamProposalsJson` and rendered as a collapsible grey box titled "最終回答" (Final Answer) — visually mirroring the reasoning section but semantically independent.
  - **Aggregator messages**: Proposals are injected as `{role:'assistant', content:'=== Proposal N (provider/model) ===...'}` messages after the last user message. The aggregator system prompt is appended to the existing system message.
  - **Model selection**: Uses `showModelSelector` without `limitProviderKey`, allowing cross-provider MoA combinations (e.g. OpenAI + Claude + Google).
  - **Default prompts**:
    - Proposal: "直接回答問題。不要問候、不要結尾客套話、不要追問使用者、不要評價問題本身。只給出你的答案和推理。"
    - Aggregator: Integrates multiple thinking directions into a single coherent answer, preserving the strongest reasoning, resolving contradictions, and producing a more complete/precise response than any individual proposal.
  - **Version bump**: `1.5.18+43` → `1.5.19+44`.
  - **Regenerate support**: `regenerateAtMessage` also checks `AiTeamProvider`; when enabled, regeneration uses the full AI Team pipeline (symmetric with `sendMessage`).

---

## [v1.5.18] - 2026-06-29: Kelivo Fetch ReDoS Root Cause Fix — RegExp, DOM Cap, Timeout, compute()

### 109. Fix ReDoS in Kelivo Fetch, Add DOM Cap, HTTP Timeout, and Isolate Offloading
- **Purpose**: Fix deterministic Windows crashes during `fetch_markdown` tool execution caused by (1) ReDoS-vulnerable RegExp in `_preCleanHtml()`, (2) unbounded DOM parse on UI isolate, and (3) no HTTP timeout / no crash isolation.
- **Files Modified**:
  - `lib/core/services/mcp/kelivo_fetch/kelivo_fetch_server.dart`
  - `pubspec.yaml`
- **Details**:
  - **ReDoS RegExp fix**: Replaced 6 exponential-backtracking patterns (`[^<]*(?:(?!</tag>)<[^<]*)*`) with linear lazy matchers (`[\s\S]*?`) in `_preCleanHtml()`. The old patterns caused O(2ⁿ) backtracking on HTML with many unpaired `<` characters, freezing the UI isolate indefinitely and triggering Windows "Not Responding" kills.
  - **DOM parse size cap**: Added `_capForParsing()` helper that truncates cleaned HTML to 256 KB before DOM parsing. Includes UTF-16 surrogate pair safety (`codeUnitAt` check for 0xDC00–0xDFFF range). Prevents OOM from building full DOM trees on large pages.
  - **HTTP timeout**: Split `_fetchWithLimit()` into `_fetchWithLimit()` (wrapper with 30s `.timeout()`) and `_readStreamed()` (actual stream reading). On timeout, the `finally` block calls `client.close()`, aborting the connection.
  - **Isolate offloading via `compute()`**: Added top-level functions `_convertHtmlToMarkdown()` and `_convertHtmlToText()`. For HTML >32 KB, `markdown()` and `txt()` offload post-fetch processing (`_preCleanHtml` + DOM parse/conversion) to a background isolate using `compute()`. Each `compute()` call has a 15-second `.timeout()`. OOM or CPU spin in the isolate kills only the background worker; the main app receives an error result instead of crashing.
  - **Version bump**: `1.5.17+42` → `1.5.18+43`.

---

## [v1.5.17] - 2026-06-29: Windows Crash Fix — Fetch Memory Reduction & Tool Result Truncation

### 108. Windows Crash Fix: Reduce Fetch Download Limit, Truncate Tool Results, Add Fetch Queue
- **Purpose**: Fix non-deterministic Windows crashes during deep-thinking + web-search + multi-fetch conversations caused by compound memory pressure (unbounded `currentMessages` growth, persistent stream-controller maps, concurrent fetch spikes).
- **Files Modified**:
  - `lib/core/services/mcp/kelivo_fetch/kelivo_fetch_server.dart`
  - `lib/core/services/api/chat_api_service.dart`
- **Details**:
  - **Fetch download limit reduced 2 MB → 512 KB**: `_maxDownloadBytes` lowered to 512 KB. The downstream HTML pre-cleaning already strips 70–90% of bloat (scripts, styles, SVGs, iframes, data URIs); 512 KB of meaningful text ≈ 128,000 chars ≈ 32,000 tokens, sufficient for LLM extraction.
  - **Historical tool result truncation**: Added `_truncateToolResultText()` (32,768 char threshold, keep head+tail + truncation marker) and `_truncateToolResultsInMessages()` helpers in `ChatApiService`. Truncation is applied to historical tool results before every follow-up API request, covering OpenAI, Claude, and Google formats. Current-round results remain intact for the LLM to read.
  - **Fetch concurrency queue**: Added `_withFetchQueue()` in `KelivoFetcher` limiting concurrent fetches to 2. Uses a `Completer`-based FIFO queue; `finally` ensures the counter decrements and the next waiter is released even if the fetch throws. Maximum waiter backlog capped at 50 as a safety valve.
  - **Impact**: Peak memory in the reported crash scenario drops from ~100 MB to ~60–70 MB (≈30% reduction).

---

## [v1.5.16] - 2026-06-25: Fetch Server Memory Optimization, Brand Icons & Reasoning Text Selection

### 107. Enable Text Selection in Reasoning Blocks
- **Purpose**: Allow users to select, copy, and "Select All" text within reasoning/thinking blocks produced by reasoning-capable models.
- **Files Modified**:
  - `lib/features/chat/widgets/chat_message_widget.dart`
  - `lib/l10n/app_en.arb`
  - `lib/l10n/app_zh.arb`
  - `lib/l10n/app_zh_Hans.arb`
  - `lib/l10n/app_zh_Hant.arb`
  - `lib/l10n/app_localizations*.dart` (auto-generated)
- **Details**:
  - Wrapped both the plain-text (`Text`) and Markdown (`MarkdownWithCodeHighlight`) rendering paths in `_reasoningContent()` with `SelectionArea`, enabling native text selection.
  - Uses Flutter's built-in `AdaptiveTextSelectionToolbar` with `selectAll` and `copy` button items, anchored at the selection position as a small floating menu (not full-screen).
  - ~~Added `chatMessageWidgetSelectAll` and `chatMessageWidgetCopy` localization keys to all 4 ARB files~~ (no longer needed — `AdaptiveTextSelectionToolbar` uses system-native labels).

### 106. Add Neuralwatt & Tinyfish Brand Icons
- **Purpose**: Replace generic letter-fallback icons with proper brand icons for the Neuralwatt provider and Tinyfish search service.
- **Files Added**:
  - `assets/icons/neuralwatt-color.svg`
  - `assets/icons/tinyfish.png`
- **Files Modified**:
  - `lib/utils/brand_assets.dart`
- **Details**:
  - **Neuralwatt icon**: Copied from project root `neuralwatt.svg`, replaced `currentColor` with `#2563EB` (blue) so the icon is visible in both light and dark modes without depending on Flutter's SVG `currentColor` rendering.
  - **Tinyfish icon**: Resized from 200x200 to 64x64 (4.4 KB) from project root `Tinyfish.png`.
  - **BrandAssets mapping**: Added `MapEntry(RegExp(r'neuralwatt'), 'neuralwatt-color.svg')` and `MapEntry(RegExp(r'tinyfish'), 'tinyfish.png')` to the icon resolver. Icons are now displayed in provider avatars, search service lists (mobile/desktop), model selectors, and all other locations that use `BrandAssets.assetForName()`.

### 105. Optimize Kelivo Fetch Server to Prevent Memory Leaks
- **Purpose**: Address memory growth and OOM crashes during multi-round chat sessions with web fetch tools by limiting download size and pre-cleaning HTML before DOM parsing.
- **Files Modified**:
  - `lib/core/services/mcp/kelivo_fetch/kelivo_fetch_server.dart`
- **Details**:
  - **Download size limit**: Replaced the original `http.get()` (which buffered the entire response body in memory) with a new `_fetchWithLimit()` method that reads the HTTP response stream chunk-by-chunk and throws an exception if the body exceeds 2 MB. This prevents fetching 5–10 MB+ pages from causing instantaneous memory spikes.
  - **HTML pre-cleaning**: Added `_preCleanHtml()` helper that uses RegExp to strip memory-heavy, non-content elements before DOM parsing or Markdown conversion: `<script>`, `<style>`, `<head>`, `<noscript>`, `<svg>`, `<iframe>`, and inline `data:` URIs (base64 images). This can shrink raw HTML by 70–90% before the DOM tree is built.
  - **Scope**: Applies to all four fetch tools (`fetch_html`, `fetch_markdown`, `fetch_txt`, `fetch_json`). The original `_fetch()` method was removed and replaced by `_fetchWithLimit()`.

### 104. Update Inno Setup Installer Script
- **Purpose**: Update the Windows installer script to match the current project paths and version.
- **Files Modified**:
  - `installers/omnichat_setup.iss`
- **Details**:
  - Updated version from `1.5.13` to `1.5.15`.
  - Updated all hardcoded paths from `C:\temp\OmniChat_v1.5.5\...` to the current project directory `C:\Users\w2bn1\Documents\GitHub\OmniChat\...`.
  - Updated `OutputBaseFilename` to include version number (`omnichat_setup_1.5.15`).

---

## [v1.5.15] - 2026-06-25: Tinyfish Search Provider & Neuralwatt Built-in Provider

### 104. Add Neuralwatt Built-in API Provider
- **Purpose**: Add Neuralwatt as a built-in API provider with official `/v1/models` model list fetching, `/v1/quota` balance checking, and Neuralwatt-specific model metadata parsing (display name, capabilities).
- **Files Modified**:
  - `lib/core/providers/settings_provider.dart`
  - `lib/core/providers/model_provider.dart`
  - `lib/core/services/api/chat_api_service.dart`
  - `lib/core/services/api/builtin_tools.dart`
  - `lib/core/services/backup/chatbox_importer.dart`
  - `lib/desktop/desktop_settings_page.dart`
  - `lib/features/home/services/tool_handler_service.dart`
  - `lib/features/model/widgets/model_detail_sheet.dart`
  - `lib/features/provider/pages/provider_detail_page.dart`
  - `lib/features/provider/pages/providers_page.dart`
  - `lib/utils/brand_assets.dart`
- **Details**:
  - **ProviderKind enum**: Added `ProviderKind.neuralwatt` to the enum, with `classify()` matching `neuralwatt` in the provider key.
  - **Default base URL**: `https://api.neuralwatt.com/v1`, enabled by default.
  - **NeuralwattProvider class**: Fetches models from `GET /v1/models` and parses the Neuralwatt-specific `metadata` object — `display_name` for the model display name, `capabilities.vision` for image input modality, `capabilities.tools` for tool ability, `capabilities.reasoning` / `reasoning_effort` for reasoning ability, and `deprecated` flag to append `(deprecated)` suffix.
  - **Balance check**: `GET /v1/quota` with `X-API-Key` / `Authorization: Bearer` header, extracting `balance.credits_remaining_usd` and formatting as `$xx.xx`.
  - **OpenAI-compatible chat**: Neuralwatt is treated as OpenAI-compatible for chat API request format via `_apiKind()` helper in both `ChatApiService` and `ProviderManager.testConnection()`, routing neuralwatt to the OpenAI chat completion / Responses API flow.
  - **Switch statement fixes**: Updated all `ProviderKind` switch statements and comparisons across `builtin_tools.dart`, `tool_handler_service.dart`, `desktop_settings_page.dart`, `model_detail_sheet.dart`, `provider_detail_page.dart`, and `chatbox_importer.dart` to include or co-handle `ProviderKind.neuralwatt`.
  - **Provider import/export**: `providerType: 'neuralwatt'` serializes and deserializes correctly via `ProviderKind.values.firstWhere`.
  - **Built-in providers list**: Neuralwatt added to `providers_page.dart`.
  - **Brand icon**: Added `neuralwatt` → `neuralwatt-color.svg` mapping in `BrandAssets`; falls back to letter `N` if the SVG asset is absent.

### 103. Add Tinyfish Search Provider
- **Purpose**: Integrate Tinyfish Search as a search provider in OmniChat's existing search service architecture, allowing users to add Tinyfish in search service settings, enter an API key, and retrieve search results via the existing `search_web` tool.
- **Files Added**:
  - `lib/core/services/search/providers/tinyfish_search_service.dart`
- **Files Modified**:
  - `lib/core/services/search/search_service.dart`
  - `lib/features/search/pages/search_services_page.dart` (mobile)
  - `lib/desktop/setting/search_services_pane.dart` (desktop)
  - `lib/l10n/app_en.arb`
  - `lib/l10n/app_zh.arb`
  - `lib/l10n/app_zh_Hans.arb`
  - `lib/l10n/app_zh_Hant.arb`
  - `lib/l10n/app_localizations*.dart` (auto-generated)
- **Details**:
  - **TinyfishSearchService**: Sends `GET https://api.search.tinyfish.ai?query=...` with `X-API-Key` header. Maps the response `results[]` array — `title` → `SearchResultItem.title`, `url` → `SearchResultItem.url`, `snippet` → `SearchResultItem.text`. Supports `resultSize` limit and `timeout` control.
  - **TinyfishOptions**: New `SearchServiceOptions` subclass with a single `apiKey` field, JSON type `'tinyfish'`. Registered in `SearchService.getService()` switch and `SearchServiceOptions.fromJson()` switch.
  - **Mobile UI**: Tinyfish added to the service type list, name resolver, add/edit form fields (API Key only, grouped with Tavily/Exa/Brave/Bocha etc.), create/update service logic, connection status display, service icon, and brand badge.
  - **Desktop UI**: Tinyfish added to the service type chips/dropdown constant list, add/edit dialog fields, create/update service logic, and brand badge name resolver.
  - **Multi-language support**: Added `searchServiceNameTinyfish` and `searchProviderTinyfishDescription` keys to all 4 ARB files (English, Simplified Chinese ×2, Traditional Chinese), with `flutter gen-l10n` regeneration.
  - **Scope**: First version covers REST Search API only; does not integrate Tinyfish MCP, OAuth, or Search + Fetch pipeline.
