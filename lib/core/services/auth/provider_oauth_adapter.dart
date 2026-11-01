// Ported from Chevey339/kelivo@05eef503b6e7cda14de897373b79bab7bebe35b9
// (`lib/core/services/auth/provider_oauth_adapter.dart`, AGPL-3.0), modified
// for OmniChat on 2026-11-01. See THIRD_PARTY_NOTICES.md.
//
// Provider adapters own the protocol: authorization URL, token exchange,
// refresh, model listing and usage parsing. They never touch `ProviderConfig`
// or shared preferences — the service owns persistence.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../models/provider_oauth.dart';
import 'codex_request.dart';
import 'grok_request.dart';
import 'kimi_request.dart';
import 'oauth_callback.dart';
import 'oauth_errors.dart';
import 'oauth_mobile_browser.dart';
import 'oauth_pkce.dart';

/// UI-facing progress handle for an in-flight login.
///
/// The service/adapter fills the fields and calls [notify]; the login panel
/// reads them and re-renders. All waits are cancellable and manual codes are
/// delivered through [submitManualCode] so the user has a fallback when the
/// browser never comes back (plan C11).
class OAuthLoginController {
  OAuthLoginController({required this.provider});

  final OAuthProvider provider;

  String? authorizeUrl;
  String? userCode;
  String? verificationUrl;

  /// `preparing` / `waiting` / `manual` / `device` / `exchanging` / `done`.
  String status = 'preparing';

  /// Localized by the UI; only shown for manual-entry validation errors.
  String? manualError;

  /// True once the adapter accepts a pasted authorization code.
  bool manualMode = false;

  void Function()? onChanged;

  final Completer<void> _cancel = Completer<void>();
  Completer<String>? _manual;
  String? _pendingManual;
  bool _finished = false;

  bool get isCancelled => _cancel.isCompleted;
  bool get isFinished => _finished;
  Future<void> get cancelSignal => _cancel.future;

  void notify() {
    try {
      onChanged?.call();
    } catch (_) {}
  }

  void setAuthorizeUrl(String url) {
    authorizeUrl = url;
    status = 'waiting';
    notify();
  }

  void setDeviceCode({
    required String code,
    required String url,
    String statusKey = 'device',
  }) {
    userCode = code;
    verificationUrl = url;
    status = statusKey;
    notify();
  }

  void setManualMode({bool enabled = true, String? statusKey}) {
    manualMode = enabled;
    if (statusKey != null) status = statusKey;
    notify();
  }

  void setStatus(String value) {
    status = value;
    notify();
  }

  void setManualError(String? message) {
    manualError = message;
    notify();
  }

  Future<String> waitForManualCode() {
    final pending = _pendingManual;
    if (pending != null) {
      _pendingManual = null;
      return Future<String>.value(pending);
    }
    _manual ??= Completer<String>();
    return _manual!.future;
  }

  void resetManualWait() {
    _manual = null;
  }

  void submitManualCode(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return;
    manualError = null;
    final completer = _manual;
    if (completer != null && !completer.isCompleted) {
      completer.complete(value);
    } else {
      _pendingManual = value;
    }
    notify();
  }

  void cancel() {
    if (!_cancel.isCompleted) _cancel.complete();
    notify();
  }

  void finish() {
    _finished = true;
    status = 'done';
    notify();
  }
}

/// Parsed result of a successful interactive authorization.
class OAuthLoginResult {
  const OAuthLoginResult({required this.credentials});

  final ProviderOAuthCredentials credentials;
}

abstract class ProviderOAuthAdapter {
  OAuthProvider get provider;

  /// Interactive login. Implementations must honour [OAuthLoginController]
  /// cancellation, close every server they opened, and return redacted errors.
  Future<ProviderOAuthCredentials> login({
    required OAuthLoginController controller,
    required http.Client client,
    required Future<bool> Function(String url) launchBrowser,
    required String sessionId,
    String? previousDeviceId,
  });

  Future<ProviderOAuthCredentials> refresh({
    required ProviderOAuthCredentials credentials,
    required http.Client client,
  });

  Future<List<OAuthModelEntry>> fetchModels({
    required ProviderOAuthCredentials credentials,
    required http.Client client,
  });

  Future<OAuthUsage> fetchUsage({
    required ProviderOAuthCredentials credentials,
    required http.Client client,
  });

  /// Optional identity enrichment after the token exchange (Claude bootstrap).
  Future<ProviderOAuthCredentials> enrichIdentity({
    required ProviderOAuthCredentials credentials,
    required http.Client client,
  }) async => credentials;
}

/// Result of a raw OAuth HTTP call; non-2xx does not throw so device polling can
/// inspect pending states.
class OAuthHttpResult {
  const OAuthHttpResult(this.statusCode, this.json, this.raw);

  final int statusCode;
  final Map<String, dynamic> json;
  final String raw;

  bool get ok => statusCode >= 200 && statusCode < 300;

  String? get errorCode {
    final error = json['error'];
    if (error is String) return error;
    if (error is Map) return (error['code'] ?? error['type'])?.toString();
    return null;
  }

  String? get errorDescription {
    final desc = json['error_description'] ?? json['message'];
    if (desc != null) return desc.toString();
    final error = json['error'];
    if (error is Map && error['message'] != null) {
      return error['message'].toString();
    }
    return null;
  }
}

Future<OAuthHttpResult> oauthHttpRequest(
  http.Client client,
  String method,
  Uri url, {
  Map<String, String> headers = const <String, String>{},
  Map<String, dynamic>? jsonBody,
  Map<String, String>? formBody,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final request = http.Request(method, url)
    ..followRedirects = false
    ..headers.addAll(headers);
  if (jsonBody != null) {
    request.headers['Content-Type'] = 'application/json';
    request.body = jsonEncode(jsonBody);
  } else if (formBody != null) {
    request.headers['Content-Type'] = 'application/x-www-form-urlencoded';
    request.body = formBody.entries
        .map(
          (e) =>
              '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
        )
        .join('&');
  }
  try {
    final streamed = await client.send(request).timeout(timeout);
    final raw = await streamed.stream.bytesToString().timeout(timeout);
    Map<String, dynamic> decoded = const <String, dynamic>{};
    if (raw.trim().isNotEmpty) {
      try {
        final obj = jsonDecode(raw);
        if (obj is Map) decoded = obj.cast<String, dynamic>();
      } catch (_) {}
    }
    return OAuthHttpResult(streamed.statusCode, decoded, raw);
  } on TimeoutException {
    throw OAuthTransportException('Request timed out');
  } on http.ClientException catch (e) {
    throw OAuthTransportException(e.message);
  } catch (e) {
    throw OAuthTransportException(e.toString());
  }
}

void throwForOAuthFailure(
  OAuthHttpResult result, {
  required OAuthProvider provider,
  String label = 'Request failed',
  bool loginRequiredOnAuthError = false,
  Set<String> extraAuthCodes = const <String>{},
}) {
  if (result.ok) return;
  final code = result.errorCode ?? '';
  final description = result.errorDescription ?? '';
  // Only 401 / explicit token errors invalidate the session. A 403 can be a
  // plan or scope restriction on one endpoint; treating it as "sign in again"
  // would strand a perfectly valid account (plan C16; pinned upstream does the
  // same 401-only mapping).
  final authFailure =
      result.statusCode == 401 ||
      code == 'invalid_grant' ||
      code == 'invalid_token' ||
      code == 'unauthorized' ||
      extraAuthCodes.contains(code);
  final message = redactOAuthText(
    '$label (HTTP ${result.statusCode})'
    '${code.isEmpty ? '' : ': $code'}'
    '${description.isEmpty ? '' : ' — $description'}',
  );
  throw OAuthException(
    message,
    provider: provider,
    loginRequired: loginRequiredOnAuthError && authFailure,
  );
}

Map<String, dynamic> _asMap(Object? value) =>
    value is Map ? value.cast<String, dynamic>() : const <String, dynamic>{};

String? _string(Object? value) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? null : text;
}

double? _number(Object? value) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString().trim() ?? '');
}

DateTime? _date(Object? value) {
  if (value is String) {
    final parsed = DateTime.tryParse(value);
    if (parsed != null) return parsed;
  }
  final number = _number(value);
  if (number == null) return null;
  return DateTime.fromMillisecondsSinceEpoch(
    (number > 1000000000000 ? number : number * 1000).toInt(),
  );
}

// ---------------------------------------------------------------------------
// ChatGPT (Codex)
// ---------------------------------------------------------------------------

class ChatGptOAuthAdapter implements ProviderOAuthAdapter {
  @override
  OAuthProvider get provider => OAuthProvider.chatgpt;

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
      provider: OAuthProvider.chatgpt,
    );
    if (server == null) {
      // Port busy/hijacked: the device-code flow is the documented fallback.
      return _loginWithDeviceCode(
        controller: controller,
        client: client,
        sessionId: sessionId,
        previousDeviceId: previousDeviceId,
      );
    }

    try {
      final redirectUri = server.redirectUri.toString();
      final url = Uri.parse(ProviderOAuthConstants.codexAuthorizeEndpoint)
          .replace(
            queryParameters: <String, String>{
              'response_type': 'code',
              'client_id': ProviderOAuthConstants.codexClientId,
              'redirect_uri': redirectUri,
              'scope': ProviderOAuthConstants.codexScope,
              'code_challenge': challenge,
              'code_challenge_method': 'S256',
              'id_token_add_organizations': 'true',
              'codex_cli_simplified_flow': 'true',
              'originator': ProviderOAuthConstants.codexOriginator,
              'state': state,
            },
          );
      controller.setAuthorizeUrl(url.toString());
      final launcher = OAuthBrowserLauncher(provider: provider);
      final OAuthCallbackResult result;
      try {
        result = await launcher.waitForCallback(
          server: server,
          authorizationUrl: url,
          expectedState: state,
          cancelSignal: controller.cancelSignal,
          launchBrowser: launchBrowser,
          timeout: ProviderOAuthConstants.callbackDeadline(provider),
        );
      } on OAuthBrowserLaunchException {
        if (controller.isCancelled) rethrow;
        // No browser and no native tab: the device-code grant is the
        // documented headless fallback (plan C11).
        await launcher.cancel();
        await server.close();
        return await _loginWithDeviceCode(
          controller: controller,
          client: client,
          sessionId: sessionId,
          previousDeviceId: previousDeviceId,
        );
      }
      controller.setStatus('exchanging');
      final exchange = await oauthHttpRequest(
        client,
        'POST',
        Uri.parse(ProviderOAuthConstants.codexTokenEndpoint),
        headers: <String, String>{'Accept': 'application/json'},
        formBody: <String, String>{
          'grant_type': 'authorization_code',
          'code': result.code,
          'redirect_uri': redirectUri,
          'client_id': ProviderOAuthConstants.codexClientId,
          'code_verifier': verifier,
        },
      );
      throwForOAuthFailure(
        exchange,
        provider: provider,
        label: 'Token exchange failed',
      );
      final credentials = _credentialsFromTokenResponse(
        exchange.json,
        sessionId: sessionId,
        deviceId: previousDeviceId ?? oauthUuidV4(),
      );
      controller.finish();
      return credentials;
    } finally {
      await server.close();
    }
  }

  Future<ProviderOAuthCredentials> _loginWithDeviceCode({
    required OAuthLoginController controller,
    required http.Client client,
    required String sessionId,
    String? previousDeviceId,
  }) async {
    controller.setStatus('device_start');
    final start = await oauthHttpRequest(
      client,
      'POST',
      Uri.parse(ProviderOAuthConstants.codexDeviceUserCodeUrl),
      jsonBody: <String, dynamic>{
        'client_id': ProviderOAuthConstants.codexClientId,
        'scope': ProviderOAuthConstants.codexScope,
      },
    );
    if (!start.ok) {
      throwForOAuthFailure(
        start,
        provider: provider,
        label: 'Device authorization failed',
      );
    }
    final userCode = (start.json['user_code'] ?? start.json['usercode'] ?? '')
        .toString();
    final deviceAuthId =
        (start.json['device_auth_id'] ?? start.json['device_authid'] ?? '')
            .toString();
    if (userCode.isEmpty || deviceAuthId.isEmpty) {
      throw OAuthException(
        'Device authorization returned an unexpected payload',
        provider: provider,
      );
    }
    final verificationUrl =
        (start.json['verification_uri'] ??
                start.json['verification_url'] ??
                ProviderOAuthConstants.codexDeviceVerificationUrl)
            .toString();
    controller.setDeviceCode(code: userCode, url: verificationUrl);
    final intervalSeconds =
        int.tryParse((start.json['interval'] ?? '5').toString()) ?? 5;

    for (
      var attempt = 0;
      attempt < ProviderOAuthConstants.codexDevicePollAttempts;
      attempt++
    ) {
      if (controller.isCancelled) {
        throw OAuthLoginCancelled(provider: provider);
      }
      await Future<void>.delayed(Duration(seconds: intervalSeconds));
      if (controller.isCancelled) {
        throw OAuthLoginCancelled(provider: provider);
      }
      final poll = await oauthHttpRequest(
        client,
        'POST',
        Uri.parse(ProviderOAuthConstants.codexDeviceTokenUrl),
        jsonBody: <String, dynamic>{
          'device_auth_id': deviceAuthId,
          'user_code': userCode,
        },
      );
      if (poll.ok) {
        final code = (poll.json['authorization_code'] ?? '').toString();
        final verifier = (poll.json['code_verifier'] ?? '').toString();
        if (code.isNotEmpty && verifier.isNotEmpty) {
          final exchange = await oauthHttpRequest(
            client,
            'POST',
            Uri.parse(ProviderOAuthConstants.codexTokenEndpoint),
            formBody: <String, String>{
              'grant_type': 'authorization_code',
              'code': code,
              'client_id': ProviderOAuthConstants.codexClientId,
              'code_verifier': verifier,
              'redirect_uri': ProviderOAuthConstants.codexDeviceRedirectUri,
            },
          );
          throwForOAuthFailure(
            exchange,
            provider: provider,
            label: 'Token exchange failed',
          );
          controller.finish();
          return _credentialsFromTokenResponse(
            exchange.json,
            sessionId: sessionId,
            deviceId: previousDeviceId ?? oauthUuidV4(),
          );
        }
        if ((poll.json['access_token'] ?? '').toString().isNotEmpty) {
          controller.finish();
          return _credentialsFromTokenResponse(
            poll.json,
            sessionId: sessionId,
            deviceId: previousDeviceId ?? oauthUuidV4(),
          );
        }
      } else if (poll.statusCode != 403 &&
          poll.statusCode != 404 &&
          poll.statusCode != 428 &&
          poll.statusCode != 400) {
        throwForOAuthFailure(
          poll,
          provider: provider,
          label: 'Device authorization failed',
        );
      }
    }
    throw OAuthLoginTimeout(provider: provider, hint: 'device code');
  }

  ProviderOAuthCredentials _credentialsFromTokenResponse(
    Map<String, dynamic> json, {
    required String sessionId,
    required String deviceId,
  }) {
    final access = (json['access_token'] ?? '').toString();
    final refresh = (json['refresh_token'] ?? '').toString();
    if (access.isEmpty) {
      throw OAuthException(
        'Token exchange returned no access token',
        provider: provider,
      );
    }
    final expiresIn =
        int.tryParse((json['expires_in'] ?? '3600').toString()) ?? 3600;
    final idToken = (json['id_token'] ?? '').toString();
    final claims =
        decodeJwtClaims(access) ??
        (idToken.isEmpty ? null : decodeJwtClaims(idToken)) ??
        const <String, dynamic>{};
    final accountId = jwtStringClaim(claims, <String>[
      'chatgpt_account_id',
      'account_id',
      'organization_id',
    ]);
    final planType = jwtStringClaim(claims, <String>[
      'chatgpt_plan_type',
      'plan_type',
    ]);
    final email = jwtStringClaim(claims, <String>[
      'email',
      'preferred_username',
    ]);
    final organizationId = jwtStringClaim(claims, <String>['organization_id']);
    final residency = jwtStringClaim(claims, <String>[
      'chatgpt_residency_region',
      'residency_region',
    ]);
    final routingHint = jwtStringClaim(claims, <String>[
      'chatgpt_routing_hint',
      'routing_hint',
    ]);
    return ProviderOAuthCredentials(
      accessToken: access,
      refreshToken: refresh,
      expiresAt: DateTime.now().add(Duration(seconds: expiresIn)),
      sessionId: sessionId,
      accountId: accountId,
      email: email,
      planType: planType,
      organizationId: organizationId,
      deviceId: deviceId,
      obtainedAt: DateTime.now(),
      scope: (json['scope'] ?? '').toString().isEmpty
          ? null
          : json['scope'].toString(),
      extra: <String, dynamic>{
        if (residency != null) 'residency': residency,
        if (routingHint != null) 'routingHint': routingHint,
      },
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
      Uri.parse(ProviderOAuthConstants.codexTokenEndpoint),
      formBody: <String, String>{
        'grant_type': 'refresh_token',
        'client_id': ProviderOAuthConstants.codexClientId,
        'refresh_token': credentials.refreshToken,
        'scope': ProviderOAuthConstants.codexScope,
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
    final identity = _credentialsFromTokenResponse(
      <String, dynamic>{
        ...result.json,
        'refresh_token':
            (result.json['refresh_token'] ?? credentials.refreshToken)
                .toString(),
      },
      sessionId: credentials.sessionId,
      deviceId: credentials.deviceId ?? oauthUuidV4(),
    );
    return identity.copyWith(
      accountId: identity.accountId ?? credentials.accountId,
      email: identity.email ?? credentials.email,
      planType: identity.planType ?? credentials.planType,
      organizationId: identity.organizationId ?? credentials.organizationId,
      extra: <String, dynamic>{...credentials.extra, ...identity.extra},
    );
  }

  @override
  Future<List<OAuthModelEntry>> fetchModels({
    required ProviderOAuthCredentials credentials,
    required http.Client client,
  }) async {
    final uri = Uri.parse(
      '${ProviderOAuthConstants.codexBaseUrl}/models'
      '?client_version=${Uri.encodeQueryComponent(ProviderOAuthConstants.codexClientVersion)}',
    );
    final result = await oauthHttpRequest(
      client,
      'GET',
      uri,
      headers: codexOAuthHeaders(credentials, sessionId: credentials.sessionId),
    );
    throwForOAuthFailure(
      result,
      provider: provider,
      label: 'Model sync failed',
      loginRequiredOnAuthError: true,
    );
    final list = (result.json['models'] ?? result.json['data']);
    final entries = <OAuthModelEntry>[];
    if (list is List) {
      for (final raw in list) {
        if (raw is! Map) continue;
        final map = raw.cast<String, dynamic>();
        final id = (map['slug'] ?? map['id'] ?? map['model'] ?? '').toString();
        if (id.isEmpty) continue;
        final visibility = (map['visibility'] ?? '').toString().toLowerCase();
        if (visibility == 'hide' || visibility == 'hidden') continue;
        final display = (map['display_name'] ?? map['displayName'] ?? id)
            .toString();
        final modalities = map['input_modalities'] ?? map['inputModalities'];
        final vision = modalities is List
            ? modalities.any(
                (value) => value.toString().toLowerCase() == 'image',
              )
            : true; // Codex subscription models accept images; the list may not say.
        entries.add(
          OAuthModelEntry(
            id: id,
            displayName: display.isEmpty ? id : display,
            vision: vision,
            priority: int.tryParse((map['priority'] ?? '').toString()),
          ),
        );
      }
    }
    entries.sort((a, b) {
      final pa = a.priority ?? 1 << 30;
      final pb = b.priority ?? 1 << 30;
      if (pa != pb) return pa.compareTo(pb);
      return a.id.compareTo(b.id);
    });
    return entries;
  }

  @override
  Future<OAuthUsage> fetchUsage({
    required ProviderOAuthCredentials credentials,
    required http.Client client,
  }) async {
    final result = await oauthHttpRequest(
      client,
      'GET',
      Uri.parse(ProviderOAuthConstants.codexUsageUrl),
      headers: <String, String>{
        'Authorization': 'Bearer ${credentials.accessToken}',
        'Accept': 'application/json',
        if ((credentials.accountId ?? '').isNotEmpty)
          'chatgpt-account-id': credentials.accountId!,
        'originator': ProviderOAuthConstants.codexOriginator,
        'User-Agent': ProviderOAuthConstants.codexUserAgent,
      },
    );
    throwForOAuthFailure(
      result,
      provider: provider,
      label: 'Usage request failed',
      loginRequiredOnAuthError: true,
    );
    return parseCodexUsage(result.json, fetchedAt: DateTime.now());
  }

  @override
  Future<ProviderOAuthCredentials> enrichIdentity({
    required ProviderOAuthCredentials credentials,
    required http.Client client,
  }) async => credentials;
}

// ---------------------------------------------------------------------------
// Generic RFC 8628 device-code flow (Grok / Kimi)
// ---------------------------------------------------------------------------

Future<ProviderOAuthCredentials> _deviceCodeLogin({
  required OAuthProvider provider,
  required OAuthLoginController controller,
  required http.Client client,
  required String deviceEndpoint,
  required String tokenEndpoint,
  required String clientId,
  required String sessionId,
  String scope = '',
  String? deviceId,
  Map<String, String> headers = const <String, String>{},
  Future<ProviderOAuthCredentials> Function(ProviderOAuthCredentials)? enrich,
}) async {
  controller.setStatus('device_start');
  final start = await oauthHttpRequest(
    client,
    'POST',
    Uri.parse(deviceEndpoint),
    headers: headers,
    formBody: <String, String>{
      'client_id': clientId,
      if (scope.isNotEmpty) 'scope': scope,
    },
  );
  if (!start.ok) {
    throwForOAuthFailure(
      start,
      provider: provider,
      label: 'Device authorization failed',
    );
  }
  final deviceCode = _string(start.json['device_code']);
  final userCode = _string(start.json['user_code']);
  final verification =
      _string(start.json['verification_uri_complete']) ??
      _string(start.json['verification_uri']);
  final verificationUri = verification == null
      ? null
      : Uri.tryParse(verification);
  if (deviceCode == null ||
      userCode == null ||
      verificationUri == null ||
      verificationUri.scheme != 'https') {
    throw OAuthException(
      'Device authorization returned an unexpected payload',
      provider: provider,
    );
  }
  controller.setDeviceCode(code: userCode, url: verificationUri.toString());

  final expiresIn = (_number(start.json['expires_in']) ?? 600)
      .clamp(1, 1800)
      .toInt();
  final deadline = DateTime.now().add(Duration(seconds: expiresIn));
  var interval = Duration(
    seconds: (_number(start.json['interval']) ?? 5).clamp(1, 60).toInt(),
  );

  while (DateTime.now().isBefore(deadline)) {
    if (controller.isCancelled) {
      throw OAuthLoginCancelled(provider: provider);
    }
    // Cancellation must not wait out a slow_down interval (up to 60s).
    await Future.any<void>(<Future<void>>[
      Future<void>.delayed(interval),
      controller.cancelSignal,
    ]);
    if (controller.isCancelled) {
      throw OAuthLoginCancelled(provider: provider);
    }

    final poll = await oauthHttpRequest(
      client,
      'POST',
      Uri.parse(tokenEndpoint),
      headers: headers,
      formBody: <String, String>{
        'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
        'client_id': clientId,
        'device_code': deviceCode,
      },
    );
    if (controller.isCancelled) {
      throw OAuthLoginCancelled(provider: provider);
    }
    if (poll.ok && _string(poll.json['access_token']) != null) {
      var credentials = _credentialsFromDeviceToken(
        poll.json,
        provider: provider,
        sessionId: sessionId,
        deviceId: deviceId,
      );
      if (enrich != null) credentials = await enrich(credentials);
      controller.finish();
      return credentials;
    }

    final error = _string(poll.json['error']);
    if (error == 'authorization_pending') continue;
    if (error == 'slow_down') {
      interval += const Duration(seconds: 5);
      continue;
    }
    if (error == 'access_denied') {
      throw OAuthException('Sign-in was denied', provider: provider);
    }
    if (error == 'expired_token') {
      throw OAuthLoginTimeout(provider: provider, hint: 'device code');
    }
    throwForOAuthFailure(
      poll,
      provider: provider,
      label: 'Device sign-in failed',
    );
  }
  throw OAuthLoginTimeout(provider: provider, hint: 'device code');
}

ProviderOAuthCredentials _credentialsFromDeviceToken(
  Map<String, dynamic> json, {
  required OAuthProvider provider,
  required String sessionId,
  String? deviceId,
  String? fallbackRefresh,
}) {
  final access = _string(json['access_token']);
  final refresh = _string(json['refresh_token']) ?? fallbackRefresh;
  if (access == null || refresh == null || refresh.trim().isEmpty) {
    throw OAuthException(
      'Token exchange returned an incomplete credential set',
      provider: provider,
    );
  }
  final claims = decodeJwtClaims(access) ?? const <String, dynamic>{};
  final expiresIn = _number(json['expires_in']);
  final jwtExpiry = _number(claims['exp']);
  if (expiresIn == null && jwtExpiry == null) {
    // Guessing an expiry would either refresh-storm or send a dead token;
    // upstream rejects the response instead.
    throw OAuthException(
      'Token exchange returned no expiry',
      provider: provider,
    );
  }
  final expiresAt = expiresIn != null
      ? DateTime.now().add(Duration(seconds: expiresIn.toInt()))
      : DateTime.fromMillisecondsSinceEpoch((jwtExpiry! * 1000).toInt());
  return ProviderOAuthCredentials(
    accessToken: access,
    refreshToken: refresh,
    expiresAt: expiresAt,
    sessionId: sessionId,
    accountId: jwtStringClaim(claims, <String>['user_id', 'sub', 'account_id']),
    email: jwtStringClaim(claims, <String>['email', 'preferred_username']),
    planType: jwtStringClaim(claims, <String>[
      'plan',
      'plan_type',
      'subscription_plan',
    ]),
    deviceId: deviceId,
    obtainedAt: DateTime.now(),
    scope: _string(json['scope']),
  );
}

const Set<String> _refreshRotationErrors = <String>{
  'refresh_token_reused',
  'refresh_token_expired',
  'refresh_token_invalid',
};

// ---------------------------------------------------------------------------
// Grok (xAI)
// ---------------------------------------------------------------------------

class GrokOAuthAdapter implements ProviderOAuthAdapter {
  @override
  OAuthProvider get provider => OAuthProvider.grok;

  @override
  Future<ProviderOAuthCredentials> login({
    required OAuthLoginController controller,
    required http.Client client,
    required Future<bool> Function(String url) launchBrowser,
    required String sessionId,
    String? previousDeviceId,
  }) async {
    var credentials = await _deviceCodeLogin(
      provider: provider,
      controller: controller,
      client: client,
      deviceEndpoint: ProviderOAuthConstants.grokDeviceCodeEndpoint,
      tokenEndpoint: ProviderOAuthConstants.grokTokenEndpoint,
      clientId: ProviderOAuthConstants.grokClientId,
      scope: ProviderOAuthConstants.grokScope,
      sessionId: sessionId,
      deviceId: previousDeviceId,
    );
    // Userinfo is optional: a successfully exchanged token remains usable if
    // the profile call fails.
    try {
      final info = await oauthHttpRequest(
        client,
        'GET',
        Uri.parse(ProviderOAuthConstants.grokUserInfoEndpoint),
        headers: <String, String>{
          'Authorization': 'Bearer ${credentials.accessToken}',
          'Accept': 'application/json',
        },
      );
      if (info.ok) {
        credentials = credentials.copyWith(
          accountId: _string(info.json['sub']) ?? credentials.accountId,
          email: _string(info.json['email']) ?? credentials.email,
        );
      }
    } catch (_) {}
    return credentials;
  }

  @override
  Future<ProviderOAuthCredentials> refresh({
    required ProviderOAuthCredentials credentials,
    required http.Client client,
  }) async {
    final result = await oauthHttpRequest(
      client,
      'POST',
      Uri.parse(ProviderOAuthConstants.grokTokenEndpoint),
      formBody: <String, String>{
        'grant_type': 'refresh_token',
        'client_id': ProviderOAuthConstants.grokClientId,
        'refresh_token': credentials.refreshToken,
      },
    );
    if (!result.ok) {
      throwForOAuthFailure(
        result,
        provider: provider,
        label: 'Token refresh failed',
        loginRequiredOnAuthError: true,
        extraAuthCodes: _refreshRotationErrors,
      );
    }
    final next = _credentialsFromDeviceToken(
      result.json,
      provider: provider,
      sessionId: credentials.sessionId,
      deviceId: credentials.deviceId,
      fallbackRefresh: credentials.refreshToken,
    );
    return next.copyWith(
      accountId: next.accountId ?? credentials.accountId,
      email: next.email ?? credentials.email,
      planType: next.planType ?? credentials.planType,
      deviceId: next.deviceId ?? credentials.deviceId,
    );
  }

  @override
  Future<List<OAuthModelEntry>> fetchModels({
    required ProviderOAuthCredentials credentials,
    required http.Client client,
  }) async {
    final catalogs = <Map<String, dynamic>>[];
    Object? firstError;
    for (final url in <String>[
      ProviderOAuthConstants.grokModelsV2Url,
      '${ProviderOAuthConstants.grokBaseUrl}/models',
    ]) {
      try {
        final result = await oauthHttpRequest(
          client,
          'GET',
          Uri.parse(url),
          headers: grokOAuthHeaders(credentials),
        );
        throwForOAuthFailure(
          result,
          provider: provider,
          label: 'Model sync failed',
          loginRequiredOnAuthError: true,
        );
        catalogs.add(result.json);
      } catch (e) {
        firstError ??= e;
      }
    }
    if (catalogs.isEmpty) {
      throw firstError is OAuthException
          ? firstError
          : OAuthException(
              'Model sync failed',
              provider: provider,
              loginRequired: true,
            );
    }

    final byId = <String, OAuthModelEntry>{};
    final imageOrVoice = RegExp(r'grok-(?:imagine|stt|voice|tts)');
    var sawRows = false;
    for (final catalog in catalogs) {
      final rows = catalog['data'] ?? catalog['models'];
      if (rows is! List) continue;
      sawRows = true;
      for (final raw in rows) {
        if (raw is! Map) continue;
        final row = raw.cast<String, dynamic>();
        final meta = _asMap(row['_meta']);
        final id =
            _string(row['model']) ??
            _string(row['modelId']) ??
            _string(row['id']) ??
            _string(meta['model']) ??
            _string(meta['modelId']);
        if (id == null || imageOrVoice.hasMatch(id)) continue;
        if (row['hidden'] == true || meta['hidden'] == true) continue;
        final efforts =
            row['reasoningEfforts'] ??
            row['reasoning_efforts'] ??
            meta['reasoningEfforts'];
        final modalities =
            row['input_modalities'] ??
            row['inputModalities'] ??
            meta['input_modalities'];
        final display =
            _string(row['display_name']) ??
            _string(row['displayName']) ??
            _string(row['name']) ??
            id;
        byId.putIfAbsent(
          id,
          () => OAuthModelEntry(
            id: id,
            displayName: display,
            reasoning:
                (efforts is List && efforts.isNotEmpty) ||
                row['supports_reasoning'] == true,
            vision: modalities is List
                ? modalities.any(
                    (value) => value.toString().toLowerCase() == 'image',
                  )
                : true,
            priority: int.tryParse((row['priority'] ?? '').toString()),
          ),
        );
      }
    }
    if (!sawRows) {
      throw OAuthException(
        'Model sync returned an unexpected payload',
        provider: provider,
        loginRequired: true,
      );
    }
    final entries = byId.values.toList();
    entries.sort((a, b) {
      final pa = a.priority ?? 1 << 30;
      final pb = b.priority ?? 1 << 30;
      if (pa != pb) return pa.compareTo(pb);
      return a.id.compareTo(b.id);
    });
    return entries;
  }

  @override
  Future<OAuthUsage> fetchUsage({
    required ProviderOAuthCredentials credentials,
    required http.Client client,
  }) async {
    final creditsData = await _grokGet(
      client,
      ProviderOAuthConstants.grokBillingCreditsUrl,
      credentials,
    );
    final weekly = parseGrokUsage(creditsData);
    if (weekly.windows.isNotEmpty &&
        _asMap(creditsData['config'])['isUnifiedBillingUser'] != true) {
      return weekly;
    }
    final monthlyData = await _grokGet(
      client,
      ProviderOAuthConstants.grokBillingUrl,
      credentials,
    );
    final monthly = parseGrokUsage(monthlyData);
    if (monthly.windows.isNotEmpty) return monthly;
    final monthlyLimit = _number(
      _asMap(_asMap(monthlyData['config'])['monthlyLimit'])['val'],
    );
    if (monthlyLimit == 0) {
      return parseGrokUsage(creditsData, allowInferredWeekly: true);
    }
    return monthly;
  }

  @override
  Future<ProviderOAuthCredentials> enrichIdentity({
    required ProviderOAuthCredentials credentials,
    required http.Client client,
  }) async => credentials;

  Future<Map<String, dynamic>> _grokGet(
    http.Client client,
    String url,
    ProviderOAuthCredentials credentials,
  ) async {
    final result = await oauthHttpRequest(
      client,
      'GET',
      Uri.parse(url),
      headers: grokOAuthHeaders(credentials),
    );
    throwForOAuthFailure(
      result,
      provider: provider,
      label: 'Usage request failed',
      loginRequiredOnAuthError: true,
    );
    return result.json;
  }
}

// ---------------------------------------------------------------------------
// Kimi Code
// ---------------------------------------------------------------------------

class KimiOAuthAdapter implements ProviderOAuthAdapter {
  @override
  OAuthProvider get provider => OAuthProvider.kimi;

  @override
  Future<ProviderOAuthCredentials> login({
    required OAuthLoginController controller,
    required http.Client client,
    required Future<bool> Function(String url) launchBrowser,
    required String sessionId,
    String? previousDeviceId,
  }) {
    final deviceId = oauthUuidV4().replaceAll('-', '');
    return _deviceCodeLogin(
      provider: provider,
      controller: controller,
      client: client,
      deviceEndpoint: ProviderOAuthConstants.kimiDeviceCodeEndpoint,
      tokenEndpoint: ProviderOAuthConstants.kimiTokenEndpoint,
      clientId: ProviderOAuthConstants.kimiClientId,
      sessionId: sessionId,
      deviceId: deviceId,
      headers: kimiDeviceHeaders(deviceId: deviceId),
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
      Uri.parse(ProviderOAuthConstants.kimiTokenEndpoint),
      headers: kimiDeviceHeaders(deviceId: credentials.deviceId),
      formBody: <String, String>{
        'grant_type': 'refresh_token',
        'client_id': ProviderOAuthConstants.kimiClientId,
        'refresh_token': credentials.refreshToken,
      },
    );
    if (!result.ok) {
      throwForOAuthFailure(
        result,
        provider: provider,
        label: 'Token refresh failed',
        loginRequiredOnAuthError: true,
        extraAuthCodes: _refreshRotationErrors,
      );
    }
    final next = _credentialsFromDeviceToken(
      result.json,
      provider: provider,
      sessionId: credentials.sessionId,
      deviceId: credentials.deviceId,
      fallbackRefresh: credentials.refreshToken,
    );
    return next.copyWith(
      accountId: next.accountId ?? credentials.accountId,
      email: next.email ?? credentials.email,
      planType: next.planType ?? credentials.planType,
      deviceId: next.deviceId ?? credentials.deviceId,
    );
  }

  @override
  Future<List<OAuthModelEntry>> fetchModels({
    required ProviderOAuthCredentials credentials,
    required http.Client client,
  }) async {
    final result = await oauthHttpRequest(
      client,
      'GET',
      Uri.parse('${ProviderOAuthConstants.kimiBaseUrl}/models'),
      headers: kimiOAuthHeaders(credentials),
    );
    throwForOAuthFailure(
      result,
      provider: provider,
      label: 'Model sync failed',
      loginRequiredOnAuthError: true,
    );
    final rows = result.json['data'] ?? result.json['models'];
    if (rows is! List) {
      throw OAuthException(
        'Model sync returned an unexpected payload',
        provider: provider,
        loginRequired: true,
      );
    }
    final entries = <OAuthModelEntry>[];
    for (final raw in rows) {
      if (raw is! Map) continue;
      final row = raw.cast<String, dynamic>();
      final id =
          _string(row['id']) ??
          _string(row['model']) ??
          _string(row['modelId']);
      if (id == null) continue;
      final display =
          _string(row['display_name']) ??
          _string(row['displayName']) ??
          _string(row['name']) ??
          id;
      final modalities = row['input_modalities'] ?? row['inputModalities'];
      entries.add(
        OAuthModelEntry(
          id: id,
          displayName: display,
          reasoning: _kimiReasoningSupport(row),
          tool:
              row['supports_tool_use'] != false &&
              row['supports_tools'] != false,
          vision:
              row['supports_vision'] == true ||
              row['supports_image'] == true ||
              (modalities is List &&
                  modalities.any(
                    (value) => value.toString().toLowerCase() == 'image',
                  )),
          priority: int.tryParse((row['priority'] ?? '').toString()),
          protocol: kimiOAuthProtocol(row),
        ),
      );
    }
    return entries;
  }

  @override
  Future<OAuthUsage> fetchUsage({
    required ProviderOAuthCredentials credentials,
    required http.Client client,
  }) async {
    final result = await oauthHttpRequest(
      client,
      'GET',
      Uri.parse('${ProviderOAuthConstants.kimiBaseUrl}/usages'),
      headers: kimiOAuthHeaders(credentials),
    );
    throwForOAuthFailure(
      result,
      provider: provider,
      label: 'Usage request failed',
      loginRequiredOnAuthError: true,
    );
    return parseKimiUsage(result.json, fetchedAt: DateTime.now());
  }

  @override
  Future<ProviderOAuthCredentials> enrichIdentity({
    required ProviderOAuthCredentials credentials,
    required http.Client client,
  }) async => credentials;
}

/// Kimi's catalog marks OpenAI-protocol models with an explicit null
/// `protocol`; every other row is Anthropic Messages (pinned upstream rule).
String kimiOAuthProtocol(Map<String, dynamic> row) {
  return row['protocol'] == null && row.containsKey('protocol')
      ? 'openai'
      : 'anthropic';
}

bool _kimiReasoningSupport(Map<String, dynamic> row) {
  if (row.containsKey('supports_reasoning')) {
    return row['supports_reasoning'] == true;
  }
  if (row.containsKey('supports_thinking_type')) {
    return const <String>{
      'only',
      'both',
    }.contains(row['supports_thinking_type']);
  }
  final efforts = _asMap(row['think_efforts']);
  if (efforts.containsKey('support')) return efforts['support'] == true;
  final levels = row['supported_reasoning_levels'];
  if (levels is List) return levels.isNotEmpty;
  final effortsList = row['supported_reasoning_efforts'];
  if (effortsList is List) return effortsList.isNotEmpty;
  return false;
}

/// Parses Grok's billing payload (weekly credits or monthly quota).
OAuthUsage parseGrokUsage(
  Map<String, dynamic> json, {
  bool allowInferredWeekly = false,
}) {
  final data = _asMap(json['config']);
  final windows = <OAuthUsageWindow>[];
  final period = _asMap(data['currentPeriod']);
  final start = _date(period['start']);
  final end = _date(period['end']);
  final explicitPercent = _number(data['creditUsagePercent']);
  final percent =
      explicitPercent ??
      ((data['isUnifiedBillingUser'] != true || allowInferredWeekly) &&
              start != null &&
              end != null &&
              end.isAfter(start) &&
              end.isAfter(DateTime.now()) &&
              '${period['type']}'.toUpperCase().contains('WEEK')
          ? 0.0
          : null);
  if (period.isNotEmpty && percent != null) {
    windows.add(
      OAuthUsageWindow(kind: 'weekly', percent: percent, resetsAt: end),
    );
    final products = data['productUsage'];
    if (products is List) {
      for (final raw in products.whereType<Map>()) {
        final product = raw.cast<String, dynamic>();
        final productPercent = _number(product['usagePercent']);
        if (productPercent == null) continue;
        windows.add(
          OAuthUsageWindow(
            kind: '${product['product']}',
            label: _string(product['product']),
            percent: productPercent,
            resetsAt: end,
          ),
        );
      }
    }
  } else {
    final limit = _number(_asMap(data['monthlyLimit'])['val']);
    final used = _number(_asMap(data['used'])['val']);
    if (limit != null && limit > 0 && used != null) {
      windows.add(
        OAuthUsageWindow(
          kind: 'monthly',
          percent: used / limit * 100,
          resetsAt: _date(data['billingPeriodEnd']),
        ),
      );
    }
  }
  return OAuthUsage(
    windows: windows,
    planType: _string(data['planName']) ?? _string(data['plan']),
    fetchedAt: DateTime.now(),
  );
}

/// Parses Kimi Code's `/usages` payload. The API may report used/limit or
/// remaining; windows without enough data are skipped rather than shown as 0%.
OAuthUsage parseKimiUsage(
  Map<String, dynamic> json, {
  required DateTime fetchedAt,
}) {
  final windows = <OAuthUsageWindow>[];
  void add(Map<String, dynamic> row, String kind, {String? label}) {
    if (row.isEmpty) return;
    final limit = _number(row['limit']);
    final remaining = _number(row['remaining']);
    final used =
        _number(row['used']) ??
        (limit != null && remaining != null ? limit - remaining : null);
    final explicitPercent = _number(row['usedPercent']);
    final percent = used != null && limit != null && limit > 0
        ? used / limit * 100
        : explicitPercent;
    if (percent == null) return;
    windows.add(
      OAuthUsageWindow(
        kind: kind,
        label: label,
        percent: percent,
        resetsAt: _date(row['resetTime'] ?? row['reset_at']),
      ),
    );
  }

  add(_asMap(json['usage']), 'weekly');
  add(_asMap(json['totalQuota']), 'total');
  final limits = json['limits'];
  var index = 0;
  if (limits is List) {
    for (final raw in limits.whereType<Map>()) {
      final row = raw.cast<String, dynamic>();
      add(
        _asMap(row['detail'] ?? row),
        'limit-${index++}',
        label: _string(row['name']),
      );
    }
  }
  return OAuthUsage(windows: windows, fetchedAt: fetchedAt);
}

/// Parses `GET /backend-api/wham/usage`.
OAuthUsage parseCodexUsage(
  Map<String, dynamic> json, {
  required DateTime fetchedAt,
}) {
  final windows = <OAuthUsageWindow>[];
  final rate = _asMap(json['rate_limit'] ?? json['rate_limits']);
  void addWindow(Object? raw, String kind) {
    final map = _asMap(raw);
    if (map.isEmpty) return;
    final percentRaw = map['used_percent'] ?? map['percent'] ?? map['used'];
    final percent = percentRaw is num
        ? percentRaw.toDouble()
        : double.tryParse(percentRaw?.toString() ?? '');
    if (percent == null) return;
    final resetRaw = map['reset_at'] ?? map['resets_at'];
    DateTime? resetsAt;
    if (resetRaw is num) {
      resetsAt = DateTime.fromMillisecondsSinceEpoch(
        resetRaw > 1000000000000 ? resetRaw.toInt() : resetRaw.toInt() * 1000,
      );
    } else if (resetRaw is String) {
      resetsAt = DateTime.tryParse(resetRaw);
    }
    windows.add(
      OAuthUsageWindow(kind: kind, percent: percent, resetsAt: resetsAt),
    );
  }

  addWindow(rate['primary_window'] ?? rate['primary'], 'session');
  addWindow(rate['secondary_window'] ?? rate['secondary'], 'weekly');
  final plan = (json['plan_type'] ?? json['plan'] ?? '').toString();
  return OAuthUsage(
    windows: windows,
    planType: plan.isEmpty ? null : plan,
    fetchedAt: fetchedAt,
  );
}
