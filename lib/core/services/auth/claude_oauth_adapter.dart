// Ported from Chevey339/kelivo@05eef503b6e7cda14de897373b79bab7bebe35b9
// (`lib/core/services/auth/claude_oauth_adapter.dart`, AGPL-3.0), modified for
// OmniChat on 2026-11-01. See THIRD_PARTY_NOTICES.md.
//
// Claude (Pro / Max) subscription login: PKCE + paste-code fallback, a JSON
// token endpoint (not form-encoded), bootstrap identity, paged model listing
// and the usage endpoint that serves both old and new payload shapes.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../models/provider_oauth.dart';
import 'claude_oauth_request.dart';
import 'oauth_effort_metadata.dart';
import 'oauth_callback.dart';
import 'oauth_errors.dart';
import 'oauth_mobile_browser.dart';
import 'oauth_pkce.dart';
import 'provider_oauth_adapter.dart';

bool? _claudeThinkingAlwaysOn(Object? capabilities) {
  if (capabilities is! Map) return null;
  final thinking = capabilities['thinking'];
  if (thinking is! Map) return null;
  final types = thinking['types'];
  if (types is! Map) return null;
  final disabled = types['disabled'];
  if (disabled is! Map) return null;
  final supported = disabled['supported'];
  return supported is bool ? !supported : null;
}

class ClaudeOAuthAdapter implements ProviderOAuthAdapter {
  @override
  OAuthProvider get provider => OAuthProvider.claude;

  @override
  Future<ProviderOAuthCredentials> login({
    required OAuthLoginController controller,
    required http.Client client,
    required Future<bool> Function(String url) launchBrowser,
    required String sessionId,
    String? previousDeviceId,
  }) async {
    final verifier = oauthRandomString(64);
    final challenge = oauthPkceChallenge(verifier);
    final state = oauthState();
    final server = await OAuthCallbackServer.tryBind(
      provider: OAuthProvider.claude,
      // Port taken by another app (or a stale window): ephemeral + paste code.
      allowEphemeralFallback: true,
    );
    final redirectUri =
        server?.redirectUri.toString() ??
        ProviderOAuthConstants.claudeRedirectUri;

    controller.setManualMode(enabled: true);
    try {
      final url = Uri.parse(ProviderOAuthConstants.claudeAuthorizeEndpoint)
          .replace(
            queryParameters: <String, String>{
              'code': 'true',
              'client_id': ProviderOAuthConstants.claudeClientId,
              'response_type': 'code',
              'redirect_uri': redirectUri,
              'scope': ProviderOAuthConstants.claudeScope,
              'code_challenge': challenge,
              'code_challenge_method': 'S256',
              'state': state,
            },
          );
      controller.setAuthorizeUrl(url.toString());
      controller.setManualMode(enabled: true, statusKey: 'waiting');
      final launcher = server == null
          ? null
          : OAuthBrowserLauncher(provider: provider);

      final code = await _waitForCode(
        server: server,
        expectedState: state,
        controller: controller,
        launcher: launcher,
        launchBrowser: launchBrowser,
        authorizationUrl: url,
      );
      controller.setStatus('exchanging');
      var credentials = await _exchangeCode(
        client: client,
        code: code,
        verifier: verifier,
        redirectUri: redirectUri,
        sessionId: sessionId,
        deviceId: previousDeviceId ?? oauthUuidV4(),
      );
      credentials = await enrichIdentity(
        credentials: credentials,
        client: client,
      );
      controller.finish();
      return credentials;
    } finally {
      await server?.close();
    }
  }

  Future<String> _waitForCode({
    required OAuthCallbackServer? server,
    required String expectedState,
    required OAuthLoginController controller,
    required OAuthBrowserLauncher? launcher,
    required Future<bool> Function(String url) launchBrowser,
    required Uri authorizationUrl,
  }) async {
    final completer = Completer<String>();
    StreamSubscription<void>? cancelSub;

    void complete(String code) {
      if (!completer.isCompleted) completer.complete(code);
    }

    void fail(Object error) {
      if (!completer.isCompleted) completer.completeError(error);
    }

    cancelSub = controller.cancelSignal.asStream().listen((_) {
      fail(OAuthLoginCancelled(provider: provider));
    });

    if (server != null && launcher != null) {
      launcher
          .waitForCallback(
            server: server,
            authorizationUrl: authorizationUrl,
            expectedState: expectedState,
            cancelSignal: controller.cancelSignal,
            launchBrowser: launchBrowser,
            timeout: ProviderOAuthConstants.callbackDeadline(provider),
          )
          .then(
            (result) => complete(result.code),
            onError: (Object e) {
              // A missing browser or an expired callback window is not fatal:
              // the user can still paste the code from the failed redirect URL
              // (C11). A rejected callback/cancel is terminal.
              if (e is OAuthCallbackRejected) {
                fail(e);
              } else if (e is OAuthLoginTimeout ||
                  e is OAuthBrowserLaunchException) {
                controller.setManualMode(enabled: true, statusKey: 'manual');
              } else {
                fail(e);
              }
            },
          );
    } else {
      // The loopback server could not bind (or the native bridge is absent).
      // The authorization page must still open; manual paste remains the
      // fallback if the launch fails.
      bool opened = false;
      try {
        opened = await launchBrowser(authorizationUrl.toString());
      } catch (_) {}
      controller.setManualMode(
        enabled: true,
        statusKey: opened ? 'waiting' : 'manual',
      );
    }

    // Manual codes: keep accepting until one parses or the flow is cancelled.
    final manualDeadline = DateTime.now().add(
      ProviderOAuthConstants.callbackDeadline(provider) +
          const Duration(minutes: 5),
    );
    // Completes when the callback path wins. Without it the pump would keep a
    // pending manual wait (and its timeout timer) alive for up to 10 minutes
    // after a successful browser sign-in.
    final stopPump = Completer<void>();
    final manualPump = () async {
      while (!completer.isCompleted) {
        final remaining = manualDeadline.difference(DateTime.now());
        if (remaining <= Duration.zero) {
          fail(OAuthLoginTimeout(provider: provider, hint: 'paste code'));
          return;
        }
        final String raw;
        try {
          raw = await Future.any<String>(<Future<String>>[
            controller.waitForManualCode(),
            controller.cancelSignal.then((_) => ''),
            stopPump.future.then((_) => ''),
          ]).timeout(remaining);
        } on TimeoutException {
          fail(OAuthLoginTimeout(provider: provider, hint: 'paste code'));
          return;
        }
        if (raw.isEmpty) return; // cancelled: the cancel path owns the error
        controller.resetManualWait();
        try {
          final code = parseClaudeManualCode(raw, expectedState: expectedState);
          controller.setManualError(null);
          // The code is already in hand; the browser (if any) is no longer
          // needed and must not keep the process bound.
          unawaited(launcher?.cancel() ?? Future<void>.value());
          complete(code);
          return;
        } on OAuthException catch (e) {
          controller.setManualError(e.message);
        }
      }
    }();
    // Swallow the pump's own terminal error; the completer owns the outcome.
    unawaited(manualPump.catchError((_) {}));

    try {
      return await completer.future;
    } finally {
      if (!stopPump.isCompleted) stopPump.complete();
      await cancelSub.cancel();
      await launcher?.cancel();
    }
  }

  Future<ProviderOAuthCredentials> _exchangeCode({
    required http.Client client,
    required String code,
    required String verifier,
    required String redirectUri,
    required String sessionId,
    required String deviceId,
  }) async {
    final result = await oauthHttpRequest(
      client,
      'POST',
      Uri.parse(ProviderOAuthConstants.claudeTokenEndpoint),
      headers: <String, String>{
        'anthropic-beta': ProviderOAuthConstants.claudeOAuthBeta,
        'user-agent': ProviderOAuthConstants.claudeUserAgent,
        'Accept': 'application/json',
      },
      jsonBody: <String, dynamic>{
        'grant_type': 'authorization_code',
        'code': code,
        'redirect_uri': redirectUri,
        'client_id': ProviderOAuthConstants.claudeClientId,
        'code_verifier': verifier,
      },
    );
    throwForOAuthFailure(
      result,
      provider: provider,
      label: 'Token exchange failed',
    );
    return _credentialsFromTokenResponse(
      result.json,
      sessionId: sessionId,
      deviceId: deviceId,
    );
  }

  ProviderOAuthCredentials _credentialsFromTokenResponse(
    Map<String, dynamic> json, {
    required String sessionId,
    required String deviceId,
  }) {
    final access = (json['access_token'] ?? '').toString();
    if (access.isEmpty) {
      throw OAuthException(
        'Token exchange returned no access token',
        provider: provider,
      );
    }
    final refresh = (json['refresh_token'] ?? '').toString();
    final expiresIn =
        int.tryParse((json['expires_in'] ?? '28800').toString()) ?? 28800;
    final account = json['account'] is Map
        ? (json['account'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final organization = json['organization'] is Map
        ? (json['organization'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final accessClaims = decodeJwtClaims(access) ?? const <String, dynamic>{};
    final accountId = (account['uuid'] ?? account['account_uuid'] ?? '')
        .toString()
        .trim();
    final organizationId =
        (organization['uuid'] ?? organization['organization_uuid'] ?? '')
            .toString()
            .trim();
    final email = (account['email_address'] ?? account['email'] ?? '')
        .toString()
        .trim();
    return ProviderOAuthCredentials(
      accessToken: access,
      refreshToken: refresh,
      expiresAt: DateTime.now().add(Duration(seconds: expiresIn)),
      sessionId: sessionId,
      accountId: accountId.isNotEmpty
          ? accountId
          : jwtStringClaim(accessClaims, <String>['account_uuid']),
      email: email.isNotEmpty
          ? email
          : jwtStringClaim(accessClaims, <String>['email']),
      planType: jwtStringClaim(accessClaims, <String>[
        'subscription_type',
        'plan_type',
      ]),
      organizationId: organizationId.isNotEmpty
          ? organizationId
          : jwtStringClaim(accessClaims, <String>['organization_uuid']),
      organizationName:
          (organization['name'] ?? organization['organization_name'] ?? '')
              .toString()
              .trim()
              .isEmpty
          ? null
          : (organization['name'] ?? organization['organization_name'])
                .toString(),
      deviceId: deviceId,
      obtainedAt: DateTime.now(),
      scope: (json['scope'] ?? '').toString().isEmpty
          ? null
          : json['scope'].toString(),
    );
  }

  @override
  Future<ProviderOAuthCredentials> refresh({
    required ProviderOAuthCredentials credentials,
    required http.Client client,
  }) async {
    final result = await oauthHttpRequest(
      client,
      'POST',
      Uri.parse(ProviderOAuthConstants.claudeTokenEndpoint),
      headers: <String, String>{
        'anthropic-beta': ProviderOAuthConstants.claudeOAuthBeta,
        'user-agent': ProviderOAuthConstants.claudeUserAgent,
        'Accept': 'application/json',
      },
      jsonBody: <String, dynamic>{
        'grant_type': 'refresh_token',
        'refresh_token': credentials.refreshToken,
        'client_id': ProviderOAuthConstants.claudeClientId,
      },
    );
    if (!result.ok) {
      throwForOAuthFailure(
        result,
        provider: provider,
        label: 'Token refresh failed',
        loginRequiredOnAuthError: true,
      );
    }
    final refreshed = _credentialsFromTokenResponse(
      <String, dynamic>{
        ...result.json,
        'refresh_token':
            (result.json['refresh_token'] ?? credentials.refreshToken)
                .toString(),
      },
      sessionId: credentials.sessionId,
      deviceId: credentials.deviceId ?? oauthUuidV4(),
    );
    return refreshed.copyWith(
      accountId: refreshed.accountId ?? credentials.accountId,
      email: refreshed.email ?? credentials.email,
      organizationId: refreshed.organizationId ?? credentials.organizationId,
      organizationName:
          refreshed.organizationName ?? credentials.organizationName,
      planType: refreshed.planType ?? credentials.planType,
    );
  }

  @override
  Future<ProviderOAuthCredentials> enrichIdentity({
    required ProviderOAuthCredentials credentials,
    required http.Client client,
  }) async {
    try {
      final uri = Uri.parse(ProviderOAuthConstants.claudeBootstrapUrl).replace(
        queryParameters: <String, String>{
          'entrypoint': 'cli',
          'client': 'cli',
          'version': ProviderOAuthConstants.claudeCodeVersion,
        },
      );
      final result = await oauthHttpRequest(
        client,
        'GET',
        uri,
        headers: claudeOAuthHeaders(
          credentials,
          acceptEventStream: false,
          includeSessionHeader: false,
        ),
      );
      if (!result.ok) return credentials;
      final account = result.json['oauth_account'];
      if (account is! Map) return credentials;
      final map = account.cast<String, dynamic>();
      final accountId = (map['account_uuid'] ?? '').toString().trim();
      final email = (map['email_address'] ?? map['email'] ?? '')
          .toString()
          .trim();
      final orgId = (map['organization_uuid'] ?? '').toString().trim();
      final orgName = (map['organization_name'] ?? map['organization'] ?? '')
          .toString()
          .trim();
      return credentials.copyWith(
        accountId: accountId.isEmpty ? null : accountId,
        email: email.isEmpty ? null : email,
        organizationId: orgId.isEmpty ? null : orgId,
        organizationName: orgName.isEmpty ? null : orgName,
      );
    } catch (_) {
      // Identity enrichment is informational; never fail a completed login.
      return credentials;
    }
  }

  @override
  Future<List<OAuthModelEntry>> fetchModels({
    required ProviderOAuthCredentials credentials,
    required http.Client client,
  }) async {
    final out = <OAuthModelEntry>[];
    String? afterId;
    final seen = <String>{};
    for (var page = 0; page < 8; page++) {
      final base = ProviderOAuthConstants.claudeBaseUrl;
      final query = <String, String>{
        'limit': '1000',
        if (afterId != null && afterId.isNotEmpty) 'after_id': afterId,
      };
      final uri = Uri.parse('$base/models').replace(queryParameters: query);
      final result = await oauthHttpRequest(
        client,
        'GET',
        uri,
        headers: claudeOAuthHeaders(
          credentials,
          acceptEventStream: false,
          includeSessionHeader: false,
        ),
      );
      throwForOAuthFailure(
        result,
        provider: provider,
        label: 'Model sync failed',
        loginRequiredOnAuthError: true,
      );
      final data = result.json['data'];
      if (data is List) {
        for (final raw in data) {
          if (raw is! Map) continue;
          final id = (raw['id'] ?? '').toString();
          if (id.isEmpty || !seen.add(id)) continue;
          final display = (raw['display_name'] ?? raw['name'] ?? id).toString();
          final capabilities = raw['capabilities'];
          final efforts = <String>{
            ...normalizeOAuthCapabilityEfforts(
              capabilities is Map ? capabilities['effort'] : null,
            ),
            ...normalizeOAuthReasoningEfforts(
              raw['reasoning_efforts'] ??
                  raw['reasoningEfforts'] ??
                  raw['supported_reasoning_efforts'],
            ),
          };
          out.add(
            OAuthModelEntry(
              id: id,
              displayName: display.isEmpty ? id : display,
              reasoning: true,
              tool: true,
              vision: true,
              efforts: efforts,
              offFallback: efforts.contains('none') ? 'none' : null,
              thinkingAlwaysOn: _claudeThinkingAlwaysOn(capabilities),
            ),
          );
        }
      }
      final hasMore = result.json['has_more'] == true;
      final lastId = (result.json['last_id'] ?? '').toString();
      if (!hasMore || lastId.isEmpty || lastId == afterId) break;
      afterId = lastId;
    }
    return out;
  }

  @override
  Future<OAuthUsage> fetchUsage({
    required ProviderOAuthCredentials credentials,
    required http.Client client,
  }) async {
    final result = await oauthHttpRequest(
      client,
      'GET',
      Uri.parse(ProviderOAuthConstants.claudeUsageUrl),
      headers: claudeOAuthHeaders(
        credentials,
        acceptEventStream: false,
        includeSessionHeader: false,
      ),
    );
    throwForOAuthFailure(
      result,
      provider: provider,
      label: 'Usage request failed',
      loginRequiredOnAuthError: true,
    );
    return parseClaudeUsage(result.json, fetchedAt: DateTime.now());
  }
}

/// Parses both usage payload generations: the legacy `five_hour` / `seven_day*`
/// keys and the newer `limits[]` / `spend` shape (plan §2.3).
OAuthUsage parseClaudeUsage(
  Map<String, dynamic> json, {
  required DateTime fetchedAt,
}) {
  final windows = <OAuthUsageWindow>[];
  DateTime? parseTime(Object? raw) {
    if (raw is num) {
      return DateTime.fromMillisecondsSinceEpoch(
        raw > 1000000000000 ? raw.toInt() : raw.toInt() * 1000,
      ).toUtc();
    }
    if (raw is String && raw.trim().isNotEmpty) {
      return DateTime.tryParse(raw)?.toUtc();
    }
    return null;
  }

  double? parsePercent(Object? raw) {
    if (raw is num) return raw.toDouble();
    return double.tryParse(raw?.toString() ?? '');
  }

  final limits = json['limits'];
  if (limits is List && limits.isNotEmpty) {
    for (final raw in limits) {
      if (raw is! Map) continue;
      final map = raw.cast<String, dynamic>();
      final kind = (map['kind'] ?? map['type'] ?? 'limit').toString();
      final percent = parsePercent(
        map['percent'] ?? map['utilization'] ?? map['used_percent'],
      );
      if (percent == null) continue;
      String? label;
      final scope = map['scope'];
      if (scope is Map) {
        final model = scope['model'];
        if (model is Map) {
          label = (model['display_name'] ?? model['id'])?.toString();
        } else if (scope['label'] != null) {
          label = scope['label'].toString();
        }
      }
      windows.add(
        OAuthUsageWindow(
          kind: kind,
          percent: percent,
          resetsAt: parseTime(map['resets_at'] ?? map['reset_at']),
          label: label,
        ),
      );
    }
  }

  if (windows.isEmpty) {
    void addLegacy(String key, String kind, {String? label}) {
      final map = json[key];
      if (map is! Map) return;
      final percent = parsePercent(
        map['utilization'] ?? map['percent'] ?? map['used_percent'],
      );
      if (percent == null) return;
      windows.add(
        OAuthUsageWindow(
          kind: kind,
          percent: percent,
          resetsAt: parseTime(map['resets_at'] ?? map['reset_at']),
          label: label,
        ),
      );
    }

    addLegacy('five_hour', 'session');
    addLegacy('seven_day', 'weekly');
    addLegacy('seven_day_opus', 'weekly_scoped', label: 'Opus');
    addLegacy('seven_day_sonnet', 'weekly_scoped', label: 'Sonnet');
  }

  double? spend;
  String? currency;
  final extra = json['extra_usage'];
  if (extra is Map) {
    final value = extra['spent_usd'] ?? extra['used_usd'] ?? extra['amount'];
    if (value is num) spend = value.toDouble();
    currency = (extra['currency'] ?? '').toString();
  }
  final spendObj = json['spend'];
  if (spendObj is Map) {
    final value = spendObj['amount'] ?? spendObj['used'] ?? spendObj['usd'];
    if (value is num) spend = value.toDouble();
    final c = (spendObj['currency'] ?? '').toString();
    if (c.isNotEmpty) currency = c;
  }

  final plan = (json['plan_type'] ?? json['subscription_type'] ?? '')
      .toString();
  return OAuthUsage(
    windows: windows,
    planType: plan.isEmpty ? null : plan,
    extraSpentUsd: spend,
    extraCurrency: currency == null || currency.isEmpty ? null : currency,
    fetchedAt: fetchedAt,
  );
}

/// Parses the four accepted paste shapes (plan §2.3):
/// raw code, `code=…&state=…`, `code#state`, or the full callback URL.
String parseClaudeManualCode(String input, {required String expectedState}) {
  final text = input.trim();
  if (text.isEmpty) {
    throw OAuthException('Paste the authorization code first');
  }

  void checkState(String? state) {
    if (state == null || state.isEmpty) return;
    if (state != expectedState) {
      throw OAuthException(
        'This code belongs to a different sign-in attempt — start again',
      );
    }
  }

  String normalizeCode(String code) {
    final cleaned = code.trim();
    if (cleaned.isEmpty) {
      throw OAuthException('The authorization code is empty');
    }
    if (RegExp(r'\s').hasMatch(cleaned)) {
      throw OAuthException('The authorization code contains spaces');
    }
    return cleaned;
  }

  if (text.startsWith('http://') || text.startsWith('https://')) {
    final uri = Uri.tryParse(text);
    if (uri == null) throw OAuthException('Unrecognized sign-in URL');
    checkState(uri.queryParameters['state']);
    // Some clients put the state in the fragment (code#state on a full URL).
    if (uri.fragment.contains('=')) {
      checkState(Uri.splitQueryString(uri.fragment)['state']);
    }
    final code = uri.queryParameters['code'];
    if (code == null) throw OAuthException('That URL has no code parameter');
    return normalizeCode(code);
  }

  if (text.contains('#')) {
    final index = text.lastIndexOf('#');
    final code = text.substring(0, index);
    final state = text.substring(index + 1);
    checkState(state);
    return normalizeCode(code);
  }

  if (text.startsWith('code=') || text.contains('&state=')) {
    final params = Uri.splitQueryString(text.replaceFirst(RegExp(r'^\?'), ''));
    checkState(params['state']);
    final code = params['code'];
    if (code == null || code.isEmpty) {
      throw OAuthException('No code= value found');
    }
    return normalizeCode(code);
  }

  return normalizeCode(text);
}

/// Convenience for tests/diagnostics: compact token description without the
/// secret (never log the token itself).
String describeClaudeToken(ProviderOAuthCredentials credentials) {
  final claims = decodeJwtClaims(credentials.accessToken);
  return jsonEncode(<String, dynamic>{
    'hasAccessToken': credentials.accessToken.isNotEmpty,
    'hasRefreshToken': credentials.hasRefreshToken,
    'expiresAt': credentials.expiresAt.toIso8601String(),
    'accountId': credentials.accountId,
    'claims': claims == null ? 'opaque' : claims.keys.toList(),
  });
}
