# OmniChat Developer Changes Log

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
