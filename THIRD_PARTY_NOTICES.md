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
