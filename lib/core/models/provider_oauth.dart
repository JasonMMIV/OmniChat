// Ported from Chevey339/kelivo@05eef503b6e7cda14de897373b79bab7bebe35b9
// (`lib/core/models/provider_oauth.dart`, AGPL-3.0), modified for OmniChat on
// 2026-11-01. See THIRD_PARTY_NOTICES.md.
//
// Provider OAuth account models: the provider enum, the credential blob that
// lives inside `ProviderConfig.oauthCredentials`, usage windows, and the
// version/endpoint constants (plan D4: one place to bump).

import 'dart:convert';

/// Subscription providers OmniChat can sign in to.
///
/// Phase 1 ships [chatgpt] and [claude]; [grok] and [kimi] keep their constants
/// so a later adapter only adds the wire implementation (plan M6 / Q3).
enum OAuthProvider {
  chatgpt('chatgpt'),
  claude('claude'),
  grok('grok'),
  kimi('kimi');

  const OAuthProvider(this.wireName);

  /// Stable value used in JSON (share codes, backup, stored credentials).
  final String wireName;

  static OAuthProvider? fromWire(Object? value) {
    final v = value?.toString().trim().toLowerCase();
    if (v == null || v.isEmpty) return null;
    for (final p in OAuthProvider.values) {
      if (p.wireName == v || p.name == v) return p;
    }
    return null;
  }

  /// Human-readable provider name (UI only; localized names live in ARB).
  String get displayName => switch (this) {
    OAuthProvider.chatgpt => 'ChatGPT',
    OAuthProvider.claude => 'Claude',
    OAuthProvider.grok => 'Grok',
    OAuthProvider.kimi => 'Kimi Code',
  };

  /// Default API base URL for a signed-in account.
  String get defaultBaseUrl => switch (this) {
    OAuthProvider.chatgpt => ProviderOAuthConstants.codexBaseUrl,
    OAuthProvider.claude => ProviderOAuthConstants.claudeBaseUrl,
    OAuthProvider.grok => ProviderOAuthConstants.grokBaseUrl,
    OAuthProvider.kimi => ProviderOAuthConstants.kimiBaseUrl,
  };
}

/// Single source of truth for every version anchor and endpoint (plan D4).
///
/// Upstream bumps these continuously; keeping them here means the runtime
/// "version too old" recovery paths need a one-line change.
class ProviderOAuthConstants {
  ProviderOAuthConstants._();

  // ---- ChatGPT (Codex) -------------------------------------------------
  static const String codexClientId = 'app_EMoamEEZ73f0CkXaXp7hrann';
  static const String codexAuthorizeEndpoint =
      'https://auth.openai.com/oauth/authorize';
  static const String codexTokenEndpoint =
      'https://auth.openai.com/oauth/token';
  static const String codexRedirectUri = 'http://localhost:1455/auth/callback';
  static const int codexCallbackPort = 1455;
  static const String codexCallbackPath = '/auth/callback';
  static const String codexBaseUrl = 'https://chatgpt.com/backend-api/codex';
  static const String codexUsageUrl =
      'https://chatgpt.com/backend-api/wham/usage';
  static const String codexResetCreditsUrl =
      'https://chatgpt.com/backend-api/rate-limit-reset-credits';
  static const String codexScope = 'openid profile email offline_access';

  /// Spike E (plan §5 M0) could not be run without a subscription account, so
  /// this stays a single constant: `omnichat` is the brand-correct value, and
  /// switching to the upstream value is a one-line change if OpenAI rejects it.
  static const String codexOriginator = 'omnichat';
  static const String codexClientVersion = '0.159.0';
  static const String codexResponsesBeta = 'responses=experimental';
  static const String codexUserAgent =
      'codex_cli_rs/0.159.0 (OmniChat) Dart/3.x';

  /// Device-code fallback (used when the loopback port is taken or blocked).
  static const String codexDeviceUserCodeUrl =
      'https://auth.openai.com/api/accounts/deviceauth/usercode';
  static const String codexDeviceTokenUrl =
      'https://auth.openai.com/api/accounts/deviceauth/token';
  static const String codexDeviceVerificationUrl =
      'https://auth.openai.com/codex/device';

  /// Redirect recorded by the device-code grant; the token exchange must send
  /// the same value (pinned upstream client).
  static const String codexDeviceRedirectUri =
      'https://auth.openai.com/deviceauth/callback';
  static const int codexDevicePollAttempts = 120;

  // ---- Grok (xAI) ------------------------------------------------------
  static const String grokClientId = 'b1a00492-073a-47ea-816f-4c329264a828';
  static const String grokTokenEndpoint = 'https://auth.x.ai/oauth2/token';
  static const String grokDeviceCodeEndpoint =
      'https://auth.x.ai/oauth2/device/code';
  static const String grokUserInfoEndpoint =
      'https://auth.x.ai/oauth2/userinfo';
  static const String grokBaseUrl = 'https://api.x.ai/v1';
  static const String grokModelsV2Url =
      'https://cli-chat-proxy.grok.com/v1/models-v2';
  static const String grokBillingUrl =
      'https://cli-chat-proxy.grok.com/v1/billing';
  static const String grokBillingCreditsUrl =
      'https://cli-chat-proxy.grok.com/v1/billing?format=credits';
  static const String grokScope =
      'openid profile email offline_access grok-cli:access api:access';

  // ---- Kimi Code -------------------------------------------------------
  static const String kimiClientId = '17e5f671-d194-4dfb-9706-5516cb48c098';
  static const String kimiTokenEndpoint =
      'https://auth.kimi.com/api/oauth/token';
  static const String kimiDeviceCodeEndpoint =
      'https://auth.kimi.com/api/oauth/device_authorization';
  static const String kimiBaseUrl = 'https://api.kimi.com/coding/v1';
  static const String kimiUserAgent = 'KimiCLI/1.0';
  static const String kimiPlatform = 'kimi_cli';
  static const String kimiVersion = '1.0';
  static const String kimiDeviceName = 'OmniChat';

  // ---- Claude ----------------------------------------------------------
  static const String claudeClientId = '9d1c250a-e61b-44d9-88ed-5944d1962f5e';
  static const String claudeAuthorizeEndpoint =
      'https://claude.ai/oauth/authorize';
  static const String claudeTokenEndpoint =
      'https://api.anthropic.com/v1/oauth/token';
  static const String claudeRedirectUri = 'http://localhost:54545/callback';
  static const int claudeCallbackPort = 54545;
  static const String claudeCallbackPath = '/callback';
  static const String claudeBaseUrl = 'https://api.anthropic.com/v1';
  static const String claudeBootstrapUrl =
      'https://api.anthropic.com/api/claude_cli/bootstrap';
  static const String claudeUsageUrl =
      'https://api.anthropic.com/api/oauth/usage';
  static const String claudeScope =
      'org:create_api_key user:profile user:inference user:sessions:claude_code '
      'user:mcp_servers user:file_upload';
  static const String claudeOAuthBeta = 'oauth-2025-04-20';
  static const String claudeCodeVersion = '2.1.280';
  static const String claudeUserAgent = 'claude-cli/2.1.280 (external, cli)';

  /// Anthropic rejects `max_tokens` above this on the OAuth (Claude Code)
  /// surface — the shaping layer clamps before the request leaves the device
  /// (plan C7).
  static const int claudeMaxTokensCap = 64000;

  /// Output tokens that must stay available below a thinking budget (C7).
  static const int claudeThinkingOutputReserve = 4000;

  /// Beta headers sent with every OAuth Claude call (pinned upstream set).
  static const List<String> claudeBetaHeaders = <String>[
    'claude-code-20250219',
    'oauth-2025-04-20',
    'interleaved-thinking-2025-05-14',
    'thinking-token-count-2026-05-13',
    'context-management-2025-06-27',
    'prompt-caching-scope-2026-01-05',
    'mid-conversation-system-2026-04-07',
    'effort-2025-11-24',
    'fallback-credit-2026-06-01',
  ];

  /// Claude Code's bundled Anthropic SDK version, sent in `X-Stainless-*`.
  static const String claudeCodeSdkVersion = '0.112.1';

  /// Tool names that live on Anthropic's side and must not be renamed.
  static const List<String> claudeServerToolNames = <String>[
    'web_search',
    'web_search_preview',
    'code_execution',
    'text_editor',
    'computer',
  ];

  // ---- Shared ----------------------------------------------------------
  /// Refresh leeway per provider: Claude rotates tokens aggressively enough
  /// that 5 minutes of head-room avoids mid-conversation refreshes.
  static Duration refreshLeeway(OAuthProvider provider) =>
      provider == OAuthProvider.claude
      ? const Duration(minutes: 5)
      : const Duration(minutes: 1);

  /// Loopback callback deadlines (plan C11).
  static Duration callbackDeadline(OAuthProvider provider) =>
      provider == OAuthProvider.claude
      ? const Duration(minutes: 5)
      : const Duration(minutes: 10);
}

/// Credentials persisted inside `ProviderConfig.oauthCredentials`.
///
/// `sessionId` is the concurrency-safety anchor: it is regenerated on every
/// login and every refresh/401/logout check compares it, so a signed-out or
/// superseded session can never apply a stale token (plan §2.4).
class ProviderOAuthCredentials {
  const ProviderOAuthCredentials({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    required this.sessionId,
    this.accountId,
    this.email,
    this.planType,
    this.organizationId,
    this.organizationName,
    this.deviceId,
    this.modelsClientVersion,
    this.obtainedAt,
    this.scope,
    this.extra = const <String, dynamic>{},
  });

  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;
  final String sessionId;
  final String? accountId;
  final String? email;
  final String? planType;
  final String? organizationId;
  final String? organizationName;
  final String? deviceId;

  /// Codex models were last synced with this client version (plan §2.2).
  final String? modelsClientVersion;
  final DateTime? obtainedAt;
  final String? scope;

  /// Provider-specific extras (Codex residency / routing hints, Claude
  /// subscription flags…). Forward-compatible by construction.
  final Map<String, dynamic> extra;

  bool get hasRefreshToken => refreshToken.trim().isNotEmpty;

  bool expiresWithin(Duration leeway) =>
      expiresAt.isBefore(DateTime.now().add(leeway));

  ProviderOAuthCredentials copyWith({
    String? accessToken,
    String? refreshToken,
    DateTime? expiresAt,
    String? sessionId,
    String? accountId,
    String? email,
    String? planType,
    String? organizationId,
    String? organizationName,
    String? deviceId,
    String? modelsClientVersion,
    DateTime? obtainedAt,
    String? scope,
    Map<String, dynamic>? extra,
  }) => ProviderOAuthCredentials(
    accessToken: accessToken ?? this.accessToken,
    refreshToken: refreshToken ?? this.refreshToken,
    expiresAt: expiresAt ?? this.expiresAt,
    sessionId: sessionId ?? this.sessionId,
    accountId: accountId ?? this.accountId,
    email: email ?? this.email,
    planType: planType ?? this.planType,
    organizationId: organizationId ?? this.organizationId,
    organizationName: organizationName ?? this.organizationName,
    deviceId: deviceId ?? this.deviceId,
    modelsClientVersion: modelsClientVersion ?? this.modelsClientVersion,
    obtainedAt: obtainedAt ?? this.obtainedAt,
    scope: scope ?? this.scope,
    extra: extra ?? this.extra,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'v': 1,
    'accessToken': accessToken,
    'refreshToken': refreshToken,
    'expiresAt': expiresAt.millisecondsSinceEpoch,
    'sessionId': sessionId,
    if (accountId != null) 'accountId': accountId,
    if (email != null) 'email': email,
    if (planType != null) 'planType': planType,
    if (organizationId != null) 'organizationId': organizationId,
    if (organizationName != null) 'organizationName': organizationName,
    if (deviceId != null) 'deviceId': deviceId,
    if (modelsClientVersion != null) 'modelsClientVersion': modelsClientVersion,
    if (obtainedAt != null) 'obtainedAt': obtainedAt!.millisecondsSinceEpoch,
    if (scope != null) 'scope': scope,
    if (extra.isNotEmpty) 'extra': extra,
  };

  /// Lenient by design: a credential blob written by an older/newer build must
  /// never crash the app, it just yields `null` and the account is treated as
  /// signed out.
  static ProviderOAuthCredentials? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final map = raw.cast<Object?, Object?>();
    // Tokens must be strings; a numeric/structured value means the blob was
    // written by something else and the account is treated as signed out.
    final accessRaw = map['accessToken'];
    final refreshRaw = map['refreshToken'];
    final access = accessRaw is String ? accessRaw.trim() : '';
    final refresh = refreshRaw is String ? refreshRaw.trim() : '';
    if (access.isEmpty && refresh.isEmpty) return null;
    final expiresRaw = map['expiresAt'];
    DateTime expiresAt;
    if (expiresRaw is num) {
      expiresAt = DateTime.fromMillisecondsSinceEpoch(expiresRaw.toInt());
    } else {
      expiresAt =
          DateTime.tryParse(expiresRaw?.toString() ?? '') ?? DateTime.now();
    }
    final obtainedRaw = map['obtainedAt'];
    final extraRaw = map['extra'];
    return ProviderOAuthCredentials(
      accessToken: access,
      refreshToken: refresh,
      expiresAt: expiresAt,
      sessionId: (map['sessionId'] ?? '').toString(),
      accountId: _nonEmpty(map['accountId']),
      email: _nonEmpty(map['email']),
      planType: _nonEmpty(map['planType']),
      organizationId: _nonEmpty(map['organizationId']),
      organizationName: _nonEmpty(map['organizationName']),
      deviceId: _nonEmpty(map['deviceId']),
      modelsClientVersion: _nonEmpty(map['modelsClientVersion']),
      obtainedAt: obtainedRaw is num
          ? DateTime.fromMillisecondsSinceEpoch(obtainedRaw.toInt())
          : null,
      scope: _nonEmpty(map['scope']),
      extra: extraRaw is Map
          ? extraRaw.map((k, v) => MapEntry(k.toString(), v))
          : const <String, dynamic>{},
    );
  }

  static String? _nonEmpty(Object? value) {
    final s = value?.toString().trim();
    return (s == null || s.isEmpty) ? null : s;
  }
}

/// Outcome of a successful token refresh/exchange, together with the session
/// identity the caller must keep comparing against (plan §2.4).
class OAuthAccessToken {
  const OAuthAccessToken({
    required this.token,
    required this.sessionId,
    required this.credentials,
  });

  final String token;
  final String sessionId;
  final ProviderOAuthCredentials credentials;

  String? get accountId => credentials.accountId;
}

/// One usage window as rendered on the account card. `kind` is a stable key —
/// the UI localizes the label, the auth layer never ships display copy.
class OAuthUsageWindow {
  const OAuthUsageWindow({
    required this.kind,
    required this.percent,
    this.resetsAt,
    this.label,
    this.used,
    this.limit,
    this.remaining,
    this.duration,
    this.unit,
    this.advisory = false,
  });

  /// `session` / `weekly` / `monthly` / `weekly_scoped` / `usage` / `extra` …
  final String kind;

  /// 0..100. Values above 100 are kept (providers report overages).
  final double percent;
  final DateTime? resetsAt;

  /// Provider-supplied name for scoped windows (e.g. `Opus`).
  final String? label;

  /// Raw meter values when the provider reports absolute amounts (plan O2).
  /// The account card falls back to the derived [percent] when either is null.
  final double? used;
  final double? limit;
  final double? remaining;

  /// Raw window duration as reported by Codex plan windows.
  final Duration? duration;

  /// Metering unit for spend-cap windows (`credits`); informational.
  final String? unit;

  /// Inferred / estimated window the provider did not publish itself (plan O2:
  /// advisory data is displayed but never blocks a request).
  final bool advisory;

  bool get isWarning => percent >= 90;
}

class OAuthUsage {
  const OAuthUsage({
    required this.windows,
    this.planType,
    this.extraSpentUsd,
    this.extraCurrency,
    this.fetchedAt,
    this.resetCredits,
    this.allowed,
    this.limitReached,
  });

  final List<OAuthUsageWindow> windows;
  final String? planType;

  /// Claude `extra_usage` / `spend` when the provider reports it.
  final double? extraSpentUsd;
  final String? extraCurrency;
  final DateTime? fetchedAt;

  /// Codex credit reset tokens (plan O2). Informational today; the request
  /// layer never derives a verdict from them.
  final int? resetCredits;

  /// Explicit backend verdict, only present when the provider reported one.
  /// Advisory / inferred data must never force a block (plan O2).
  final bool? allowed;
  final bool? limitReached;

  bool get isEmpty => windows.isEmpty;

  /// The single window surfaced outside the account card (model-picker
  /// headers, provider list): a bare percentage next to the provider name.
  ///
  /// Preference follows the billing period, longest first — `monthly`, then
  /// Kimi's `total`, then weekly, then the 5-hour `session`. Per-model and
  /// per-product windows (`weekly_scoped`, `limit-*`, Grok product rows) only
  /// surface when nothing else was reported, because they describe one model
  /// rather than the account. Ties inside one tier pick the highest percentage
  /// (the window closest to its limit). ChatGPT reports only `session` (5h) and
  /// `weekly` today, so it surfaces the weekly window.
  ///
  /// The value is the provider's own utilization percentage — identical to the
  /// number the account card renders — never a `100 - x` remainder.
  OAuthUsageWindow? get summaryWindow {
    OAuthUsageWindow? best;
    var bestRank = 1 << 30;
    for (final window in windows) {
      final rank = _summaryRank(window.kind);
      final current = best;
      if (current == null ||
          rank < bestRank ||
          (rank == bestRank && window.percent > current.percent)) {
        best = window;
        bestRank = rank;
      }
    }
    return best;
  }

  static int _summaryRank(String kind) => switch (kind) {
    'monthly' => 0,
    'total' => 1,
    'weekly' || 'seven_day' || 'weekly_all' => 2,
    'session' || 'five_hour' => 3,
    'usage' =>
      4, // Codex window whose reported duration could not be classified.
    'spend-cap' => 5,
    'weekly_scoped' => 6,
    'on-demand' => 7,
    _ => kind.startsWith('limit-') ? 6 : 5,
  };
}

class OAuthModelEntry {
  const OAuthModelEntry({
    required this.id,
    required this.displayName,
    this.reasoning = true,
    this.tool = true,
    this.vision = false,
    this.priority,
    this.protocol,
    this.efforts = const <String>{},
    this.thinkingAlwaysOn,
    this.offFallback,
  });

  final String id;
  final String displayName;
  final bool reasoning;
  final bool tool;
  final bool vision;
  final int? priority;

  /// Kimi Code serves some models over the Anthropic Messages wire and some
  /// over OpenAI chat completions. Null for every other provider.
  final String? protocol;

  /// Standard reasoning effort tiers reported by the provider's model endpoint.
  ///
  /// Codex publishes `supported_reasoning_levels`; Claude publishes
  /// `capabilities.effort`. Only `ReasoningOverride.allEfforts` values are
  /// kept; Codex-only modes such as `ultra`/`persistent` are intentionally
  /// ignored because they are not raw Responses API effort values. An empty
  /// set means "the endpoint did not tell us", not "no reasoning".
  final Set<String> efforts;

  /// `true` when the provider says reasoning cannot be turned off, `false`
  /// when it explicitly offers a non-thinking mode, and `null` when unknown.
  final bool? thinkingAlwaysOn;

  /// Provider-specific effort used when reasoning is switched off, if given.
  final String? offFallback;
}

/// Decodes the payload of a JWT without verifying it. OAuth access tokens are
/// opaque to us; only the claims the provider mints for its own CLI are read
/// (account id, plan, residency hints). Returns `null` for opaque tokens.
Map<String, dynamic>? decodeJwtClaims(String token) {
  final parts = token.split('.');
  if (parts.length < 2) return null;
  try {
    final payload = base64Url.normalize(parts[1]);
    final decoded = utf8.decode(base64Url.decode(payload));
    final obj = jsonDecode(decoded);
    if (obj is Map) return obj.cast<String, dynamic>();
  } catch (_) {}
  return null;
}

/// Reads a claim from either the top level or OpenAI's namespaced auth object.
String? jwtStringClaim(Map<String, dynamic> claims, List<String> keys) {
  for (final key in keys) {
    final direct = claims[key];
    if (direct is String && direct.trim().isNotEmpty) return direct.trim();
  }
  for (final value in claims.values) {
    if (value is Map) {
      for (final key in keys) {
        final nested = value[key];
        if (nested is String && nested.trim().isNotEmpty) return nested.trim();
      }
    }
  }
  return null;
}

final RegExp _jwtPattern = RegExp(
  r'eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]*',
);

/// Replaces tokens, JWTs and provider identifiers in a string with
/// `[redacted]` (plan C5). Every auth-layer exception message goes through it.
String redactOAuthText(String input, {Iterable<String> secrets = const []}) {
  var out = input;
  for (final secret in secrets) {
    final s = secret.trim();
    if (s.length >= 8) out = out.replaceAll(s, '[redacted]');
  }
  out = out.replaceAll(_jwtPattern, '[redacted]');
  out = out.replaceAllMapped(
    RegExp(r'(sk-[A-Za-z0-9_\-]{6,}|Bearer\s+[A-Za-z0-9_\-\.]{8,})'),
    (_) => '[redacted]',
  );
  return out;
}
