// Ported from Chevey339/kelivo@05eef503b6e7cda14de897373b79bab7bebe35b9
// (`provider_oauth_service.dart` `_ProviderOAuthHttpClient`, AGPL-3.0),
// modified for OmniChat on 2026-11-01. See THIRD_PARTY_NOTICES.md.
//
// The single interception point for chat traffic (plan C1). Everything the
// OAuth surface needs is applied here, per request, from the untouched body
// bytes: token resolution/refresh, header rewrite, body shaping, one 401
// recovery attempt, error redaction and `close()` forwarding.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;

import '../../models/provider_oauth.dart';
import '../../providers/settings_provider.dart';
import '../../services/api/provider_request_headers.dart';
import 'claude_oauth_request.dart';
import 'codex_request.dart';
import 'grok_request.dart';
import 'kimi_request.dart';
import 'oauth_errors.dart';
import 'oauth_pkce.dart';
import 'provider_oauth_service.dart';

class OAuthHttpClient extends http.BaseClient {
  OAuthHttpClient({
    required http.Client inner,
    required this.config,
    ProviderOAuthService? service,
    this.sessionId,
    this.conversationId,
    this.requestId,
  }) : _inner = inner,
       _service = service ?? ProviderOAuthService.instance;

  final http.Client _inner;
  final ProviderConfig config;
  final ProviderOAuthService _service;
  final String? sessionId;
  final String? conversationId;
  final String? requestId;

  bool _closed = false;

  /// Process-lifetime bump when Anthropic answers `claude_code_version_too_old`
  /// (plan C7/D4). The first rejected request upgrades the whole process, so
  /// later requests do not pay the same 400 again.
  static String? _runtimeCliVersion;
  String? _requestCliVersion;
  bool _versionRetried = false;

  @visibleForTesting
  static void resetRuntimeCliVersion() => _runtimeCliVersion = null;

  String get _effectiveCliVersion =>
      _requestCliVersion ??
      _runtimeCliVersion ??
      ProviderOAuthConstants.claudeCodeVersion;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final provider = config.oauthProvider;
    if (provider == null || request is! http.Request) {
      return _inner.send(request);
    }

    final original = request;
    var access = await _service.resolve(config);
    var shaped = _shape(original, access);
    var response = await _inner.send(shaped.request);

    if (provider == OAuthProvider.claude &&
        response.statusCode == 400 &&
        !_versionRetried) {
      // A consumed body must be handed back verbatim if this is not the
      // version-too-old case.
      final bytes = await response.stream.toBytes();
      final text = utf8.decode(bytes, allowMalformed: true);
      final required = claudeRequiredVersionFromError(text);
      if (required != null) {
        _versionRetried = true;
        _requestCliVersion = required;
        _runtimeCliVersion = required;
        shaped = _shape(original, access);
        response = await _inner.send(shaped.request);
      } else {
        response = http.StreamedResponse(
          Stream<List<int>>.value(bytes),
          response.statusCode,
          contentLength: bytes.length,
          request: response.request,
          headers: response.headers,
          isRedirect: response.isRedirect,
          persistentConnection: response.persistentConnection,
          reasonPhrase: response.reasonPhrase,
        );
      }
    }

    if (response.statusCode == 401) {
      // Drain before reusing the connection (plan C3).
      try {
        await response.stream.drain<void>();
      } catch (_) {}

      try {
        access = await _service.forceRefresh(
          config,
          sessionId: access.sessionId,
        );
        shaped = _shape(original, access);
        response = await _inner.send(shaped.request);
        if (response.statusCode == 401) {
          _service.markLoginRequired(config.id);
        }
      } on OAuthDisabledException {
        rethrow;
      } on OAuthException catch (e) {
        // Only auth failures may poison the account. A network blip during the
        // refresh is transient (plan C16) and must not turn the next request
        // into a permanent "sign-in required" state.
        if (e.loginRequired) _service.markLoginRequired(config.id);
        rethrow;
      }
    }
    return response;
  }

  _ShapedRequest _shape(http.Request original, OAuthAccessToken access) {
    final provider = config.oauthProvider!;
    final credentials = access.credentials;
    final session = (sessionId ?? '').trim().isNotEmpty
        ? sessionId!.trim()
        : access.sessionId;

    final headers = Map<String, String>.from(original.headers);
    _removeHeader(headers, 'content-length');
    var url = original.url;
    var body = utf8.decode(original.bodyBytes, allowMalformed: true);

    switch (provider) {
      case OAuthProvider.chatgpt:
        _removeHeader(headers, 'x-api-key');
        headers.addAll(
          codexOAuthHeaders(
            credentials,
            sessionId: session,
            conversationId: conversationId,
            requestId: requestId,
          ),
        );
        headers.addAll(
          providerSessionHeaders(
            config,
            sessionId: session,
            conversationId: conversationId,
            requestId: requestId,
          ),
        );
        if (body.trim().isNotEmpty) {
          final decoded = _tryDecodeObject(body);
          if (decoded != null) {
            final shaped = applyCodexRequest(
              decoded,
              ctx: CodexRequestContext(
                accountId: credentials.accountId ?? '',
                sessionId: session,
                conversationId: conversationId,
                requestId: requestId,
                residency: credentials.extra['residency']?.toString(),
                routingHint: credentials.extra['routingHint']?.toString(),
              ),
            );
            body = jsonEncode(shaped);
          }
        }
        break;
      case OAuthProvider.claude:
        _removeHeader(headers, 'x-api-key');
        _removeHeader(headers, 'authorization');
        // Keep any feature betas the caller added; the OAuth set is merged in.
        final existingBeta = _takeHeader(headers, 'anthropic-beta');
        headers.addAll(
          claudeOAuthHeaders(
            credentials,
            sessionId: session,
            cliVersion: _effectiveCliVersion,
            acceptEventStream:
                (original.headers['Accept'] ?? '').contains('event-stream') ||
                body.contains('"stream":true'),
          ),
        );
        headers.addAll(
          claudeMergedBetaHeaders(
            existingBeta,
            extendedCacheTtl:
                config.claudePromptCachingEnabled == true &&
                ProviderConfig.resolveClaudePromptCachingTtl(
                      config.claudePromptCachingTtl,
                    ) ==
                    ProviderConfig.claudePromptCachingTtl1h,
          ),
        );
        headers.addAll(providerSessionHeaders(config, sessionId: session));
        // `/v1/messages` on the OAuth surface requires `?beta=true`.
        if (url.path.endsWith('/messages') &&
            url.queryParameters['beta'] != 'true') {
          url = url.replace(
            queryParameters: <String, String>{
              ...url.queryParameters,
              'beta': 'true',
            },
          );
        }
        if (body.trim().isNotEmpty) {
          final decoded = _tryDecodeObject(body);
          if (decoded != null) {
            final shaped = encodeClaudeOAuthRequest(
              decoded,
              copy: false,
              ctx: ClaudeOAuthRequestContext(
                deviceId:
                    credentials.deviceId ??
                    oauthStableUuid('${config.id}:${credentials.accountId}'),
                sessionId: session,
                accountId: credentials.accountId ?? '',
                cliVersion: _effectiveCliVersion,
                promptCaching: config.claudePromptCachingEnabled == true,
                cacheTtl: ProviderConfig.resolveClaudePromptCachingTtl(
                  config.claudePromptCachingTtl,
                ),
              ),
            );
            body = jsonEncode(shaped);
          }
        }
        break;
      case OAuthProvider.grok:
        _removeHeader(headers, 'x-api-key');
        headers.addAll(grokOAuthHeaders(credentials));
        if (body.trim().isNotEmpty) {
          final decoded = _tryDecodeObject(body);
          if (decoded != null) body = jsonEncode(applyGrokRequest(decoded));
        }
        break;
      case OAuthProvider.kimi:
        _removeHeader(headers, 'x-api-key');
        headers.addAll(kimiOAuthHeaders(credentials));
        // Kimi's Anthropic-protocol models accept the bearer token but the
        // Claude Code-compatible surface also reads x-api-key.
        if (url.path.endsWith('/messages')) {
          headers['x-api-key'] = credentials.accessToken;
          if (body.trim().isNotEmpty) {
            final decoded = _tryDecodeObject(body);
            if (decoded != null) {
              body = jsonEncode(applyKimiAnthropicRequest(decoded));
            }
          }
        }
        break;
    }

    final clone = http.Request(original.method, url)
      ..headers.addAll(headers)
      ..followRedirects = original.followRedirects
      ..maxRedirects = original.maxRedirects
      ..persistentConnection = original.persistentConnection;
    clone.bodyBytes = utf8.encode(body);
    return _ShapedRequest(clone);
  }

  /// Header maps lose `http.BaseRequest`'s case-insensitivity when copied, so
  /// removal must match regardless of casing (a leaked x-api-key would be sent
  /// alongside the OAuth bearer token).
  static void _removeHeader(Map<String, String> headers, String name) {
    final lower = name.toLowerCase();
    headers.removeWhere((key, _) => key.toLowerCase() == lower);
  }

  static String? _takeHeader(Map<String, String> headers, String name) {
    final lower = name.toLowerCase();
    String? value;
    headers.removeWhere((key, candidate) {
      if (key.toLowerCase() != lower) return false;
      value = candidate;
      return true;
    });
    return value;
  }

  Map<String, dynamic>? _tryDecodeObject(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) return decoded.cast<String, dynamic>();
    } catch (_) {}
    return null;
  }

  /// `http.BaseClient.close()` is a no-op; without this forward every chat
  /// request would leak one Dio instance (plan C1).
  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _inner.close();
  }
}

class _ShapedRequest {
  const _ShapedRequest(this.request);

  final http.Request request;
}
