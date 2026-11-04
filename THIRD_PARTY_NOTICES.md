# Third-Party Notices

OmniChat is distributed under the GNU Affero General Public License v3
(`LICENSE`). This file lists code that was ported or adapted from other
AGPL-3.0 projects, as required by AGPL §5.

## Kelivo — provider OAuth login

| Item | Value |
|:--|:--|
| Project | [Chevey339/kelivo](https://github.com/Chevey339/kelivo) |
| Anchored commit | `05eef503b6e7cda14de897373b79bab7bebe35b9` (2026-10-30) |
| License | GNU Affero General Public License v3.0 |
| Upstream design doc | `docs/provider-oauth.md` |
| Ported | 2026-11-01, modified for OmniChat |

### Ported / adapted files

- `lib/core/models/provider_oauth.dart`
- `lib/core/services/auth/oauth_callback.dart`
- `lib/core/services/auth/oauth_pkce.dart`
- `lib/core/services/auth/provider_oauth_adapter.dart`
- `lib/core/services/auth/claude_oauth_adapter.dart`
- `lib/core/services/auth/claude_oauth_request.dart`
- `lib/core/services/auth/codex_request.dart`
- `lib/core/services/auth/grok_request.dart`
- `lib/core/services/auth/kimi_request.dart`
- `lib/core/services/auth/oauth_mobile_browser.dart`
- `lib/core/services/auth/provider_oauth_service.dart`
- `lib/core/services/auth/oauth_http_client.dart`
- `lib/core/services/auth/oauth_errors.dart`
- `lib/core/services/api/provider_request_headers.dart`
- `android/app/src/main/kotlin/com/psyche/omnichat/OAuthHandler.kt`
- `android/app/src/main/kotlin/com/psyche/omnichat/OAuthAuthorizationActivity.kt`
- `android/app/src/main/kotlin/com/psyche/omnichat/OAuthCallbackActivity.kt`
- `android/app/src/main/kotlin/com/psyche/omnichat/OAuthBrowserService.kt`
- `lib/features/provider/widgets/oauth_login_panel.dart` (UI rewritten to
  OmniChat's layout conventions; protocol flow follows upstream)
- `lib/features/provider/widgets/oauth_account_card.dart`
- `lib/features/provider/pages/oauth_provider_detail_page.dart`

### Modifications

The port keeps the upstream protocol logic (authorization endpoints, PKCE,
token/refresh payload shapes, Claude Code fingerprint headers, Codex Responses
shaping, usage parsing) and changes the following for OmniChat:

- persistence uses `ProviderConfig.oauthCredentials` on top of OmniChat's
  `provider_configs_v1`, with a dedicated `clearOAuthCredentials()` sign-out;
- every chat request is shaped in a single `OAuthHttpClient` wrapper around the
  existing `_clientFor()` factory, instead of upstream's hook points;
- `generateText` for Codex is implemented as a stream-and-aggregate fork;
- Grok/Kimi Code device-code adapters, usage parsers and model catalogs follow
  the same pinned upstream implementation (M6);
- Android uses the ported Custom Tabs/AuthTab method-channel bridge with the
  OmniChat scheme/host (`com.psyche.omnichat://oauth-callback`), while the
  authorization code still arrives on the loopback server (M5.5);
- request logging redacts OAuth session/account identifiers
  (`RequestLogger.redactOAuthBody`);
- UI copy, l10n keys, navigation, model-sync merge semantics and the
  `provider_oauth_v1` kill-switch are OmniChat-specific;
- no Kelivo branding, package ids, URL schemes, assets or application ids are
  carried over.

These derivative files remain licensed under AGPL-3.0. The app registers the
same notice in the in-app license page (`LicenseRegistry` in `lib/main.dart`).

## Markdown preview vendor assets

`assets/html/mark.html` loads the following vendored browser libraries from
`assets/html/vendor/` so Markdown preview works offline (no CDN/ES-module
requests). They are unmodified except `markdown-it-katex.min.js`, which is the
`@vscode/markdown-it-katex` ESM bundle wrapped as a classic IIFE with esbuild.

| Package | Version | License | Source |
|:--|:--|:--|:--|
| markdown-it | 14.0.0 | MIT | https://github.com/markdown-it/markdown-it |
| markdown-it-task-lists | 2.1.1 | ISC | https://github.com/revin/markdown-it-task-lists |
| @vscode/markdown-it-katex | 1.1.2 | MIT | https://github.com/microsoft/markdown-it-katex |
| KaTeX (JS, CSS, fonts) | 0.16.8 | MIT | https://github.com/KaTeX/KaTeX |
| highlight.js | 11.9.0 | BSD-3-Clause | https://github.com/highlightjs/highlight.js |
| DOMPurify | 3.2.4 | Apache-2.0 OR MPL-2.0 | https://github.com/cure53/DOMPurify |
| js-base64 | 3.7.5 | BSD-3-Clause | https://github.com/dankogai/js-base64 |
| Mermaid | existing app asset | MIT | https://github.com/mermaid-js/mermaid |

See `assets/html/vendor/README.md` for exact file names, versions and the
reproduction command.

## Markdown rendering dependencies

Production dependencies used by the Markdown renderer:

| Package | Version | License | Source |
|:--|:--|:--|:--|
| gpt_markdown | 1.3.0 | BSD-3-Clause | https://github.com/useval/gpt_markdown |
| flutter_svg | 2.3.0 | MIT | https://pub.dev/packages/flutter_svg |

The following packages are pulled in only by the `gpt_markdown` 1.4.0 Gate 1
spike in `pubspec_overrides.yaml`. They are not part of the production
dependency set until the modern pipeline is accepted and the override is
removed.

| Package | Version | License | Source |
|:--|:--|:--|:--|
| gpt_markdown | 1.4.0 | BSD-3-Clause | https://github.com/useval/gpt_markdown |
| material_ui | 1.10.0 | BSD-3-Clause | https://github.com/flutter/packages |
| val_latex_flutter | 0.1.3 | BSD-3-Clause; Latin Modern fonts under GUST Font License | https://pub.dev/packages/val_latex_flutter |
| val_latex | 0.1.3 | BSD-3-Clause | https://pub.dev/packages/val_latex |
| val_highlight | 0.1.1 | BSD-3-Clause | https://pub.dev/packages/val_highlight |
| val_highlight_flutter | 0.1.1 | BSD-3-Clause | https://pub.dev/packages/val_highlight_flutter |

The bundled Latin Modern font license is available at
`fonts/latin-modern/GUST-FONT-LICENSE.txt` in the `val_latex_flutter` package.
If Gate 1 is reverted, remove the 1.4.0 spike rows together with the override;
the production `gpt_markdown` 1.3.0 and `flutter_svg` entries remain.
