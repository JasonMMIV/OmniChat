// Ported from Chevey339/kelivo@05eef503b6e7cda14de897373b79bab7bebe35b9
// (`lib/core/services/auth/oauth_callback_io.dart`, AGPL-3.0), modified for
// OmniChat on 2026-11-01. See THIRD_PARTY_NOTICES.md.
//
// Android opens the authorization page in a Custom Tab/AuthTab through the
// native `app.oauth` channel. The authorization code still arrives on the
// loopback server; the loopback response redirects to the app's deep link with
// only `state`, which lets the native layer close the tab and return to the
// foreground. Desktop keeps using the system browser and the callback page.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../models/provider_oauth.dart';
import 'oauth_callback.dart';
import 'oauth_errors.dart';
import 'oauth_pkce.dart';

/// A failure reported by the native browser bridge. Kept separate from
/// [OAuthException] so the adapters can decide whether to fall back to
/// `url_launcher` or surface the failure.
class OAuthMobileBrowserException implements Exception {
  const OAuthMobileBrowserException(this.code, [this.message]);

  final String code;
  final String? message;

  bool get cancelled => code == 'authorization_cancelled';

  /// A browser/user-agent problem that a plain external-browser launch can
  /// work around (no Custom Tabs browser, no foreground activity, or an old
  /// build without the channel).
  bool get canFallBack =>
      code == 'authorization_failed' ||
      code == 'foreground_required' ||
      code == 'missing_plugin';

  @override
  String toString() =>
      'OAuth browser error ($code)${message == null ? '' : ': $message'}';
}

/// One native authorization window.
///
/// A new session id per attempt makes cancellation precise: a late callback
/// from a previous attempt can never complete the current one.
class OAuthMobileBrowser {
  OAuthMobileBrowser({
    required this.provider,
    MethodChannel? channel,
    String? sessionId,
    Uri? callbackUri,
  }) : _channel = channel ?? defaultChannel,
       sessionId = sessionId ?? oauthRandomString(24),
       callbackUri = callbackUri ?? defaultCallbackUri;

  static const MethodChannel defaultChannel = MethodChannel('app.oauth');

  /// Must stay in sync with the manifest intent-filter and `OAuthHandler.kt`.
  static final Uri defaultCallbackUri = Uri.parse(
    'com.psyche.omnichat://oauth-callback/authorize',
  );

  /// Only Android has the native bridge. Tests on the host must not take this
  /// path just because `defaultTargetPlatform` says Android.
  static bool get isSupported => !kIsWeb && Platform.isAndroid;

  static OAuthMobileBrowser? maybeCreate({required OAuthProvider provider}) =>
      isSupported ? OAuthMobileBrowser(provider: provider) : null;

  final OAuthProvider provider;
  final MethodChannel _channel;
  final String sessionId;
  final Uri callbackUri;

  /// Opens the authorization page natively and completes when the deep link
  /// comes back. The returned URI carries only `state` (never the code).
  Future<Uri> authenticate({
    required Uri authorizationUrl,
    required Duration timeout,
  }) async {
    try {
      final value = await _channel
          .invokeMethod<String>('authenticate', <String, dynamic>{
            'url': authorizationUrl.toString(),
            'redirectUri': callbackUri.toString(),
            'completionOnly': true,
            'sessionId': sessionId,
          })
          .timeout(timeout);
      final parsed = value == null ? null : Uri.tryParse(value);
      if (parsed == null || !matchesCallback(parsed)) {
        throw OAuthException(
          'The browser returned an invalid authorization callback',
          provider: provider,
        );
      }
      return parsed;
    } on TimeoutException {
      // Keep the OAuth error taxonomy: callers use it to switch to the
      // paste-code/device-code fallback and to show a localized timeout.
      throw OAuthLoginTimeout(provider: provider);
    } on MissingPluginException {
      throw const OAuthMobileBrowserException('missing_plugin');
    } on PlatformException catch (error) {
      throw OAuthMobileBrowserException(error.code, error.message);
    }
  }

  bool matchesCallback(Uri uri) =>
      uri.scheme.toLowerCase() == callbackUri.scheme.toLowerCase() &&
      uri.host.toLowerCase() == callbackUri.host.toLowerCase() &&
      uri.port == callbackUri.port &&
      uri.path == callbackUri.path &&
      !uri.hasFragment;

  Future<void> cancel() async {
    try {
      await _channel.invokeMethod<void>('cancel', <String, dynamic>{
        'sessionId': sessionId,
      });
    } catch (_) {
      // A missing bridge or an expired session is already cancelled.
    }
  }
}

/// Opens the authorization page (native on Android, external browser
/// elsewhere) and waits for the loopback code.
class OAuthBrowserLauncher {
  OAuthBrowserLauncher({required this.provider, OAuthMobileBrowser? mobile})
    : mobile = mobile ?? OAuthMobileBrowser.maybeCreate(provider: provider);

  final OAuthProvider provider;
  final OAuthMobileBrowser? mobile;

  /// After a fallback to `url_launcher` the deep link is no longer expected to
  /// close anything, but the loopback flow remains valid.
  bool _usedFallback = false;

  Future<OAuthCallbackResult> waitForCallback({
    required OAuthCallbackServer server,
    required Uri authorizationUrl,
    required String expectedState,
    required Future<void> cancelSignal,
    required Future<bool> Function(String url) launchBrowser,
    required Duration timeout,
  }) async {
    final browser = mobile;
    Future<Uri>? nativeFuture;
    var completed = false;
    final completer = Completer<OAuthCallbackResult>();

    void finish(OAuthCallbackResult value) {
      if (completed) return;
      completed = true;
      completer.complete(value);
    }

    void fail(Object error) {
      if (completed) return;
      completed = true;
      completer.completeError(error);
    }

    final cancelSub = cancelSignal.asStream().listen((_) {
      unawaited(browser?.cancel() ?? Future<void>.value());
      fail(OAuthLoginCancelled(provider: provider));
    });

    if (browser == null) {
      bool opened;
      try {
        opened = await launchBrowser(authorizationUrl.toString());
      } catch (_) {
        opened = false;
      }
      if (!opened) {
        await cancelSub.cancel();
        throw OAuthBrowserLaunchException(provider: provider);
      }
    } else {
      nativeFuture = browser.authenticate(
        authorizationUrl: authorizationUrl,
        timeout: timeout,
      );
      nativeFuture.then(
        (_) {
          // Completion signal only: the loopback code is authoritative and
          // arrives before this future resolves.
        },
        onError: (Object error) {
          if (completed) return;
          if (error is OAuthException) {
            // Timeouts and other auth-layer failures already carry the right
            // type/message; wrapping them would break the Claude fallback.
            fail(error);
            return;
          }
          if (error is OAuthMobileBrowserException) {
            if (error.cancelled) {
              fail(OAuthLoginCancelled(provider: provider));
              return;
            }
            if (error.canFallBack) {
              _fallbackToExternalBrowser(
                authorizationUrl: authorizationUrl,
                launchBrowser: launchBrowser,
                fail: fail,
              );
              return;
            }
          }
          fail(
            OAuthException(
              redactOAuthText(error.toString()),
              provider: provider,
            ),
          );
        },
      );
    }

    final wait = server.waitForCode(
      expectedState: expectedState,
      timeout: timeout,
      // Evaluate at request time: a native failure may have switched us to the
      // external browser, where the success HTML page is the right response.
      mobileCallback: () => _usedFallback ? null : browser?.callbackUri,
    );
    wait.then(finish, onError: fail);

    try {
      final result = await completer.future;
      if (nativeFuture != null && !_usedFallback) {
        try {
          final callback = await nativeFuture.timeout(
            const Duration(seconds: 5),
          );
          final states = callback.queryParametersAll['state'];
          if (states == null ||
              states.length != 1 ||
              states.single != expectedState) {
            throw OAuthException(
              'The browser returned a mismatched authorization callback',
              provider: provider,
            );
          }
        } on TimeoutException {
          // The code is already safe on loopback. A browser that does not
          // follow the deep link must not turn a successful sign-in into a
          // failure; the user can still switch back manually.
        } on OAuthMobileBrowserException catch (error) {
          if (error.cancelled) {
            throw OAuthLoginCancelled(provider: provider);
          }
        }
      }
      return result;
    } finally {
      await cancelSub.cancel();
      await mobile?.cancel();
    }
  }

  void _fallbackToExternalBrowser({
    required Uri authorizationUrl,
    required Future<bool> Function(String url) launchBrowser,
    required void Function(Object error) fail,
  }) {
    if (_usedFallback) return;
    _usedFallback = true;
    unawaited(
      launchBrowser(authorizationUrl.toString())
          .then((opened) {
            if (!opened) fail(OAuthBrowserLaunchException(provider: provider));
          })
          .catchError((Object _) {
            fail(OAuthBrowserLaunchException(provider: provider));
          }),
    );
  }

  Future<void> cancel() async => mobile?.cancel();
}
