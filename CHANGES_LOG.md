# OmniChat Developer Changes Log

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
