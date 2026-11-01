// Ported from Chevey339/kelivo@05eef503b6e7cda14de897373b79bab7bebe35b9
// (`lib/core/services/auth/oauth_callback_io.dart`, AGPL-3.0), modified for
// OmniChat on 2026-11-01. See THIRD_PARTY_NOTICES.md.
//
// Loopback authorization callback shared by both providers (and by any future
// MCP OAuth flow). One `HttpServer` per login attempt; the authorization code
// is exchanged on-device and never leaves the machine.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../models/provider_oauth.dart';
import 'oauth_errors.dart';

/// One authorization redirect, already validated against the expected state.
class OAuthCallbackResult {
  const OAuthCallbackResult({required this.code, this.state});

  final String code;
  final String? state;
}

class OAuthCallbackServer {
  OAuthCallbackServer._(this._server, this.provider);

  final HttpServer _server;
  final OAuthProvider provider;
  final Completer<void> _closed = Completer<void>();
  bool _received = false;

  int get port => _server.port;

  Uri get redirectUri => Uri.parse('http://localhost:$port$_path');

  String get _path => provider == OAuthProvider.claude
      ? ProviderOAuthConstants.claudeCallbackPath
      : ProviderOAuthConstants.codexCallbackPath;

  /// Binds the provider's fixed loopback port.
  ///
  /// Returns `null` (instead of throwing) when the port is unavailable so the
  /// caller can fall back — Claude to an ephemeral port + paste-code, ChatGPT
  /// to the device-code flow (plan C11).
  static Future<OAuthCallbackServer?> tryBind({
    required OAuthProvider provider,
    bool allowEphemeralFallback = false,
  }) async {
    final defaultPort = provider == OAuthProvider.claude
        ? ProviderOAuthConstants.claudeCallbackPort
        : ProviderOAuthConstants.codexCallbackPort;
    try {
      final server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        defaultPort,
        shared: false,
      );
      return OAuthCallbackServer._(server, provider);
    } on SocketException {
      if (!allowEphemeralFallback) return null;
      try {
        final server = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          0,
          shared: false,
        );
        return OAuthCallbackServer._(server, provider);
      } on SocketException {
        return null;
      }
    }
  }

  /// Waits for the redirect carrying an authorization code.
  ///
  /// Requests with a mismatched `state`, unknown paths or an `error` parameter
  /// are answered with a human-readable page and do NOT complete the wait —
  /// except for a real `error` redirect, which fails the flow.
  Future<OAuthCallbackResult> waitForCode({
    required String expectedState,
    required Duration timeout,
    // Android: answer with a 302 to the app's deep link instead of the HTML
    // success page. The code stays on the loopback connection; only `state`
    // travels through the deep link, which lets the native layer close the
    // browser and return to the foreground (M5.5). Evaluated lazily so a
    // native-browser fallback can switch back to the HTML page.
    Uri? Function()? mobileCallback,
  }) {
    final completer = Completer<OAuthCallbackResult>();

    // The completion path force-closes the server, so the response has to be
    // fully flushed before the completer resolves; otherwise the browser can
    // land on a blank page after a successful sign-in.
    Future<void> respond(
      HttpRequest request,
      int status,
      String message,
      bool ok,
    ) async {
      try {
        final response = request.response
          ..statusCode = status
          ..headers.contentType = ContentType.html
          ..write(_page(message, ok: ok));
        await response.close();
      } catch (_) {}
    }

    Future<void> redirect(HttpRequest request, Uri location) async {
      try {
        final response = request.response
          ..statusCode = HttpStatus.found
          ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
          ..headers.set('Referrer-Policy', 'no-referrer')
          ..headers.set(HttpHeaders.locationHeader, location.toString());
        await response.close();
      } catch (_) {}
    }

    Timer? timer;
    final sub = _server.listen(
      (request) async {
        if (completer.isCompleted) {
          await respond(
            request,
            410,
            _copy('This sign-in window is already finished.', '此登入視窗已完成。'),
            false,
          );
          return;
        }
        if (request.method != 'GET' || request.uri.path != _path) {
          await respond(request, 404, _copy('Not found.', '找不到頁面。'), false);
          return;
        }
        final q = request.uri.queryParameters;
        final state = q['state'];
        if (state == null || state != expectedState) {
          await respond(
            request,
            400,
            _copy(
              'State mismatch. Return to OmniChat and start sign-in again.',
              'state 驗證失敗，請回到 OmniChat 重新登入。',
            ),
            false,
          );
          return;
        }
        final error = q['error'];
        if (error != null && error.isNotEmpty) {
          final description = q['error_description'] ?? '';
          await respond(
            request,
            400,
            _copy('Sign-in was rejected by the provider.', '供應商拒絕了這次登入。'),
            false,
          );
          if (!completer.isCompleted) {
            completer.completeError(
              OAuthCallbackRejected(
                redactOAuthText(
                  'Sign-in rejected: $error'
                  '${description.isEmpty ? '' : ' — $description'}',
                ),
                provider: provider,
              ),
            );
          }
          return;
        }
        final code = q['code'];
        if (code == null || code.isEmpty) {
          await respond(
            request,
            400,
            _copy('Missing authorization code.', '缺少授權碼。'),
            false,
          );
          return;
        }
        _received = true;
        final callback = mobileCallback?.call();
        if (callback != null) {
          await redirect(
            request,
            callback.replace(
              queryParameters: <String, String>{'state': expectedState},
            ),
          );
        } else {
          await respond(
            request,
            200,
            _copy(
              'Signed in. You can close this tab and return to OmniChat.',
              '登入完成，可以關閉此分頁並回到 OmniChat。',
            ),
            true,
          );
        }
        if (!completer.isCompleted) {
          completer.complete(OAuthCallbackResult(code: code, state: state));
        }
      },
      onDone: () {
        // The adapter closes the server on cancel/timeout; release the timer and
        // the listener instead of keeping them alive until the deadline.
        timer?.cancel();
        if (!completer.isCompleted) {
          completer.completeError(OAuthLoginCancelled(provider: provider));
        }
      },
    );

    timer = Timer(timeout, () {
      if (completer.isCompleted) return;
      completer.completeError(OAuthLoginTimeout(provider: provider));
    });

    return completer.future.whenComplete(() async {
      timer?.cancel();
      await sub.cancel();
      await close();
    });
  }

  bool get received => _received;

  Future<void> close() async {
    if (_closed.isCompleted) return;
    _closed.complete();
    try {
      await _server.close(force: true);
    } catch (_) {}
  }

  static String _copy(String en, String zh) => '$en\n$zh';

  static String _page(String message, {required bool ok}) {
    final color = ok ? '#1a7f37' : '#b42318';
    final title = ok
        ? 'OmniChat · Sign-in complete'
        : 'OmniChat · Sign-in failed';
    return '<!doctype html><html><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        '<title>$title</title></head>'
        '<body style="font-family:-apple-system,Segoe UI,Roboto,sans-serif;'
        'background:#0f1115;color:#e6e6e6;display:flex;align-items:center;'
        'justify-content:center;height:100vh;margin:0">'
        '<div style="max-width:420px;padding:28px 32px;border-radius:16px;'
        'background:#171a21;border:1px solid #262b36">'
        '<h1 style="font-size:18px;margin:0 0 10px;color:$color">$title</h1>'
        '<p style="font-size:14px;line-height:1.6;color:#b9c0cc;'
        'white-space:pre-wrap;margin:0">${const HtmlEscape().convert(message)}</p>'
        '</div></body></html>';
  }
}
