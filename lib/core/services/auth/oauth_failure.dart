// Modified for OmniChat on 2026-11-01. See THIRD_PARTY_NOTICES.md.
//
// Classification shared by the chat error path and its tests. Kept pure so
// the "did this turn fail because the subscription account needs a fresh
// sign-in?" decision is independent of widgets and the service singleton.

import '../../providers/settings_provider.dart';
import '../api/stream_retry_policy.dart';
import 'oauth_errors.dart';

/// Whether [error] should turn this turn into the OAuth recovery flow.
///
/// Two shapes reach the caller (plan C3):
///  * a refresh / resolution failure throws an [OAuthException] whose
///    [OAuthException.loginRequired] is already authoritative;
///  * a second 401 after a successful refresh is *returned* by the wrapper
///    after `markLoginRequired()`, so the transport surfaces a plain
///    `HttpException('HTTP 401: …')`. That path is only a recovery failure
///    while the service still flags this account — a 401 from an unrelated
///    cause must not be hijacked.
///
/// A later 500 / parse error keeps its own text even while the account is
/// still flagged from an earlier 401 ([accountFlagged] alone is not enough).
bool isOAuthLoginRequiredFailure({
  required ProviderConfig config,
  required Object error,
  required bool accountFlagged,
}) {
  if (config.oauthProvider == null) return false;
  if (error is OAuthException) return error.loginRequired;
  return accountFlagged && extractStatusCode(error) == 401;
}
