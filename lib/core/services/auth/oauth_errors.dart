// Modified for OmniChat on 2026-11-01. See THIRD_PARTY_NOTICES.md.

import '../../models/provider_oauth.dart';

/// Which step of a login failed (plan O3). The adapter fills this in at the
/// moment of failure so the UI can say where the flow stopped.
enum OAuthStage {
  requestDeviceCode,
  waitDeviceAuthorization,
  prepareBrowser,
  browserAuthorization,
  exchangeToken,
  refreshToken,
}

/// How a transport-level failure was classified (plan O3). DNS/TLS/proxy
/// failures read differently from plain timeouts in the sign-in dialog.
enum OAuthFailureTransport {
  dns,
  tls,
  proxy,
  connection,
  connectionTimeout,
  sendTimeout,
  receiveTimeout,
  requestTimeout,
  unknown,
}

/// Base class for every failure the OAuth layer surfaces. Messages are already
/// redacted (plan C5) — callers can show [message] as-is.
class OAuthException implements Exception {
  OAuthException(
    this.message, {
    this.provider,
    this.loginRequired = false,
    this.stage,
    this.transportFailure,
  });

  final String message;
  final OAuthProvider? provider;

  /// True when the account has to sign in again (refresh rejected, session
  /// invalidated, credentials removed). The UI turns this into the recovery
  /// card instead of a transient error (plan C16).
  final bool loginRequired;

  /// Login step where this error arose; null for non-login surfaces.
  final OAuthStage? stage;

  /// Transport classification when the failure was connection-level (plan O3).
  final OAuthFailureTransport? transportFailure;

  @override
  String toString() => message;
}

/// The user dismissed the login sheet / cancelled the pending flow.
class OAuthLoginCancelled extends OAuthException {
  OAuthLoginCancelled({super.provider})
    : super('Sign-in cancelled', loginRequired: true);
}

/// The loopback callback (or device-code poll) ran out of time.
class OAuthLoginTimeout extends OAuthException {
  OAuthLoginTimeout({super.provider, String? hint})
    : super(
        hint == null || hint.isEmpty
            ? 'Sign-in timed out'
            : 'Sign-in timed out ($hint)',
        loginRequired: true,
      );
}

/// A staged-dialog free-form message from the authorization server.
class OAuthCallbackRejected extends OAuthException {
  OAuthCallbackRejected(super.message, {super.provider});
}

/// The browser window could not be opened (no handler, or the Android Custom
/// Tabs bridge is unavailable). ChatGpt falls back to device-code; Claude
/// falls back to paste-code.
class OAuthBrowserLaunchException extends OAuthException {
  OAuthBrowserLaunchException({super.provider})
    : super('Could not open the sign-in page');
}

/// Credentials are missing or already marked as requiring a fresh sign-in.
class OAuthLoginRequiredException extends OAuthException {
  OAuthLoginRequiredException({super.provider, String? reason})
    : super(
        reason == null || reason.isEmpty ? 'Sign-in required' : reason,
        loginRequired: true,
      );
}

/// The feature kill-switch (`provider_oauth_v1`) is off (plan D3).
class OAuthDisabledException extends OAuthException {
  OAuthDisabledException({super.provider})
    : super('Provider OAuth is disabled', loginRequired: false);
}

/// The credentials a request was using were replaced by a newer login (or a
/// sign-out) while the request was in flight. This is deliberately NOT a
/// login-required state: the newer session is healthy and must never be marked
/// as signed out by a stale response.
class OAuthSessionSupersededException extends OAuthException {
  OAuthSessionSupersededException({super.provider})
    : super('Sign-in session was replaced', loginRequired: false);
}

/// The provider asked for a newer client build
/// (`claude_code_version_too_old`).
class OAuthClientVersionTooOld extends OAuthException {
  OAuthClientVersionTooOld(this.requiredVersion, {super.provider})
    : super('Client version too old (requires $requiredVersion)');

  final String requiredVersion;
}

/// Non-auth transport/protocol failure. Network errors must NOT be classified
/// as [loginRequired] — that would strand a user with working credentials in
/// the recovery flow (plan C16).
class OAuthTransportException extends OAuthException {
  OAuthTransportException(
    String message, {
    super.provider,
    super.stage,
    OAuthFailureTransport? transportFailure,
  }) : super(
         redactOAuthText(message),
         transportFailure: transportFailure ?? classifyOAuthTransport(message),
       );
}

/// Best-effort mapping of a raw message (or thrown object) onto a transport
/// class. Callers that already know the kind pass the enum directly; this
/// string heuristic only keeps already-thrown [OAuthTransportException]s
/// informative when a helper rethrows them.
OAuthFailureTransport classifyOAuthTransport(Object? error) {
  final text = error.toString().toLowerCase();
  if (text.contains('proxy') || text.contains('tunnel')) {
    return OAuthFailureTransport.proxy;
  }
  if (text.contains('handshake') || text.contains('certificate')) {
    return OAuthFailureTransport.tls;
  }
  if (text.contains('socket') ||
      text.contains('connection') ||
      text.contains('host') ||
      text.contains('lookup')) {
    return text.contains('timed out') || text.contains('timeout')
        ? OAuthFailureTransport.requestTimeout
        : OAuthFailureTransport.connection;
  }
  if (text.contains('timed out') || text.contains('timeout')) {
    return OAuthFailureTransport.requestTimeout;
  }
  return OAuthFailureTransport.unknown;
}
