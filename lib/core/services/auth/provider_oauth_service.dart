// Ported from Chevey339/kelivo@05eef503b6e7cda14de897373b79bab7bebe35b9
// (`lib/core/services/auth/provider_oauth_service.dart`, AGPL-3.0), modified
// for OmniChat on 2026-11-01. See THIRD_PARTY_NOTICES.md.
//
// Single owner of OAuth account state: interactive login, credential
// persistence (inside `ProviderConfig.oauthCredentials`), concurrent-refresh
// de-duplication, the 401 recovery path, model sync and usage caching.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/provider_oauth.dart';
import '../../providers/settings_provider.dart';
import '../../utils/reasoning_overrides.dart';
import '../network/dio_http_client.dart';
import 'claude_oauth_adapter.dart';
import 'oauth_errors.dart';
import 'oauth_pkce.dart';
import 'provider_oauth_adapter.dart';

/// Persists a credential/model update for one provider. Registered once from
/// `main.dart` so the auth layer never depends on widget-tree providers.
typedef OAuthConfigUpdater =
    Future<void> Function(
      String providerId,
      ProviderConfig Function(ProviderConfig current) update,
    );

class ProviderOAuthService extends ChangeNotifier {
  ProviderOAuthService._({
    http.Client Function(ProviderConfig? config)? clientFactory,
    ProviderOAuthAdapter Function(OAuthProvider provider)? adapterFactory,
  }) : _clientFactory = clientFactory,
       _adapterFactory = adapterFactory;

  /// App-wide singleton.
  static final ProviderOAuthService instance = ProviderOAuthService._();

  /// Isolated instance for tests; no shared-preferences side effects unless
  /// [loadPreferences] is called explicitly.
  @visibleForTesting
  ProviderOAuthService.testing({
    http.Client Function(ProviderConfig? config)? clientFactory,
    ProviderOAuthAdapter Function(OAuthProvider provider)? adapterFactory,
    bool enabled = true,
  }) : _clientFactory = clientFactory,
       _adapterFactory = adapterFactory {
    _enabled = enabled;
  }

  static const String prefsKey = 'provider_oauth_v1';

  final http.Client Function(ProviderConfig? config)? _clientFactory;
  final ProviderOAuthAdapter Function(OAuthProvider provider)? _adapterFactory;
  OAuthConfigUpdater? _updater;

  bool _enabled = true;
  bool get enabled => _enabled;

  bool _loaded = false;

  final Map<String, ProviderOAuthCredentials> _cache =
      <String, ProviderOAuthCredentials>{};
  final Set<String> _loginRequired = <String>{};
  final Map<String, Future<ProviderOAuthCredentials>> _refreshes =
      <String, Future<ProviderOAuthCredentials>>{};

  /// Session that owns each in-flight refresh. A refresh that started before a
  /// re-login must not be shared with the new session (it can only fail as
  /// superseded).
  final Map<String, String> _refreshSessions = <String, String>{};
  final Map<String, OAuthUsage> _usageCache = <String, OAuthUsage>{};
  final Map<String, DateTime> _usageFetchedAt = <String, DateTime>{};

  /// Bumped by sign-in and sign-out. An async refresh that started before a
  /// bump must never write its (now stale) token into the new session.
  final Map<String, int> _epochs = <String, int>{};
  int _epochOf(String providerId) => _epochs[providerId] ?? 0;
  bool _syncingOutdated = false;

  static const Duration usageCacheTtl = Duration(minutes: 5);

  void attachSettings(SettingsProvider settings) {
    _updater = (id, update) async {
      // Only update an existing provider: a refresh that lands after the user
      // deleted the account must not resurrect it.
      final current = settings.providerConfigs[id];
      if (current == null) return;
      await settings.setProviderConfig(id, update(current));
    };
  }

  @visibleForTesting
  void attachUpdater(OAuthConfigUpdater updater) => _updater = updater;

  Future<void> loadPreferences() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(prefsKey) ?? true;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(prefsKey, value);
    } catch (_) {}
  }

  /// Kill-switch gate (plan D3). Kept separate so callers can render the
  /// disabled state without triggering an auth exception.
  void ensureEnabled() {
    if (!_enabled) throw OAuthDisabledException();
  }

  ProviderOAuthAdapter _adapter(OAuthProvider provider) {
    final factory = _adapterFactory;
    if (factory != null) return factory(provider);
    switch (provider) {
      case OAuthProvider.chatgpt:
        return ChatGptOAuthAdapter();
      case OAuthProvider.claude:
        return ClaudeOAuthAdapter();
      case OAuthProvider.grok:
        return GrokOAuthAdapter();
      case OAuthProvider.kimi:
        return KimiOAuthAdapter();
    }
  }

  http.Client _newClient(ProviderConfig? config) {
    final factory = _clientFactory;
    if (factory != null) return factory(config);
    // Every client created here serves OAuth endpoints (token exchange,
    // refresh, model list, usage), so their bodies are always log-redacted.
    if (config == null) return DioHttpClient(redactSensitiveBody: true);
    final enabledProxy = config.proxyEnabled == true;
    final host = (config.proxyHost ?? '').trim();
    final portStr = (config.proxyPort ?? '').trim();
    if (enabledProxy && host.isNotEmpty && portStr.isNotEmpty) {
      return DioHttpClient(
        proxy: NetworkProxyConfig(
          enabled: true,
          host: host,
          port: int.tryParse(portStr) ?? 8080,
          username: (config.proxyUsername ?? '').trim().isEmpty
              ? null
              : config.proxyUsername!.trim(),
          password: (config.proxyPassword ?? '').trim().isEmpty
              ? null
              : config.proxyPassword!.trim(),
        ),
        redactSensitiveBody: true,
      );
    }
    return DioHttpClient(redactSensitiveBody: true);
  }

  // ---- interactive login -------------------------------------------------

  /// Runs the interactive flow and stores the resulting credentials.
  ///
  /// The caller is responsible for creating/updating the `ProviderConfig` with
  /// the returned credentials (see [applyLoginResult]).
  Future<ProviderOAuthCredentials> login({
    required OAuthProvider provider,
    required String providerId,
    OAuthLoginController? controller,
    Future<bool> Function(String url)? launchBrowser,
    http.Client? client,
    String? previousDeviceId,
    // Existing account being re-authenticated: reuse its proxy. A brand-new
    // account has no config yet, so login uses a direct client.
    ProviderConfig? networkConfig,
  }) async {
    ensureEnabled();
    final ctrl = controller ?? OAuthLoginController(provider: provider);
    final sessionId = oauthUuidV4();
    final httpClient = client ?? _newClient(networkConfig);
    try {
      final credentials = await _adapter(provider).login(
        controller: ctrl,
        client: httpClient,
        launchBrowser: launchBrowser ?? (_) async => true,
        sessionId: sessionId,
        previousDeviceId: previousDeviceId,
      );
      _cache[providerId] = credentials;
      _loginRequired.remove(providerId);
      notifyListeners();
      return credentials;
    } on OAuthException {
      rethrow;
    } catch (e) {
      throw OAuthException(redactOAuthText(e.toString()), provider: provider);
    } finally {
      if (client == null) httpClient.close();
    }
  }

  /// Persists a completed login into the stored provider config, merges the
  /// account's models and returns the updated config.
  Future<ProviderConfig> applyLoginResult(
    ProviderConfig config,
    ProviderOAuthCredentials credentials,
  ) async {
    _epochs[config.id] = _epochOf(config.id) + 1;
    _cache[config.id] = credentials;
    _loginRequired.remove(config.id);
    // A different account may have signed in: never show the previous one's
    // cached usage.
    _usageCache.remove(config.id);
    _usageFetchedAt.remove(config.id);
    var updated = config.copyWith(
      oauthProvider: config.oauthProvider,
      oauthCredentials: credentials.toJson(),
      enabled: true,
    );
    // A model-list failure must not fail a completed sign-in (C13); the
    // account page offers a retry.
    updated = await syncModels(updated, throwOnFailure: false);
    notifyListeners();
    return updated;
  }

  // ---- resolution / refresh ----------------------------------------------

  ProviderOAuthCredentials? credentialsFor(ProviderConfig config) {
    final cached = _cache[config.id];
    if (cached != null) return cached;
    final stored = ProviderOAuthCredentials.fromJson(config.oauthCredentials);
    if (stored != null) _cache[config.id] = stored;
    return stored;
  }

  bool isLoginRequired(String providerId) =>
      _loginRequired.contains(providerId);

  void clearLoginRequired(String providerId) {
    if (_loginRequired.remove(providerId)) notifyListeners();
  }

  void markLoginRequired(String providerId) {
    if (_loginRequired.add(providerId)) notifyListeners();
  }

  /// Resolves a usable access token, refreshing when it is inside the leeway.
  Future<OAuthAccessToken> resolve(
    ProviderConfig config, {
    bool forceRefresh = false,
  }) async {
    ensureEnabled();
    if (config.oauthProvider == null) {
      throw OAuthException('Not an OAuth provider');
    }
    final credentials = credentialsFor(config);
    if (credentials == null) {
      markLoginRequired(config.id);
      throw OAuthLoginRequiredException(
        provider: config.oauthProvider,
        reason: 'Sign-in required',
      );
    }
    if (_loginRequired.contains(config.id) && !forceRefresh) {
      throw OAuthLoginRequiredException(
        provider: config.oauthProvider,
        reason: 'Sign-in required',
      );
    }
    final leeway = ProviderOAuthConstants.refreshLeeway(config.oauthProvider!);
    if (forceRefresh ||
        credentials.accessToken.trim().isEmpty ||
        credentials.expiresWithin(leeway)) {
      final refreshed = await _refreshDedup(config, credentials);
      return OAuthAccessToken(
        token: refreshed.accessToken,
        sessionId: refreshed.sessionId,
        credentials: refreshed,
      );
    }
    return OAuthAccessToken(
      token: credentials.accessToken,
      sessionId: credentials.sessionId,
      credentials: credentials,
    );
  }

  /// 401 recovery path. Only refreshes when the failing request still belongs
  /// to the current session; a signed-out or re-logged session must not be
  /// resurrected (plan C3).
  Future<OAuthAccessToken> forceRefresh(
    ProviderConfig config, {
    required String sessionId,
  }) async {
    ensureEnabled();
    final current = credentialsFor(config);
    if (current == null || current.sessionId != sessionId) {
      // A newer login (or sign-out) already owns this provider: do not mark it
      // as requiring sign-in on behalf of the stale request.
      throw OAuthSessionSupersededException(provider: config.oauthProvider);
    }
    final refreshed = await _refreshDedup(config, current);
    return OAuthAccessToken(
      token: refreshed.accessToken,
      sessionId: refreshed.sessionId,
      credentials: refreshed,
    );
  }

  Future<ProviderOAuthCredentials> _refreshDedup(
    ProviderConfig config,
    ProviderOAuthCredentials expected,
  ) {
    final existing = _refreshes[config.id];
    if (existing != null && _refreshSessions[config.id] == expected.sessionId) {
      return existing;
    }
    late final Future<ProviderOAuthCredentials> future;
    future = _doRefresh(config, expected).whenComplete(() {
      if (identical(_refreshes[config.id], future)) {
        _refreshes.remove(config.id);
        _refreshSessions.remove(config.id);
      }
    });
    _refreshes[config.id] = future;
    _refreshSessions[config.id] = expected.sessionId;
    return future;
  }

  Future<ProviderOAuthCredentials> _doRefresh(
    ProviderConfig config,
    ProviderOAuthCredentials expected,
  ) async {
    final epoch = _epochOf(config.id);
    final current = credentialsFor(config);
    if (current == null || current.sessionId != expected.sessionId) {
      throw OAuthSessionSupersededException(provider: config.oauthProvider);
    }
    final client = _newClient(config);
    try {
      final refreshed = await _adapter(
        config.oauthProvider!,
      ).refresh(credentials: current, client: client);
      // Re-check after the await: a logout or a fresh login may have landed
      // while the refresh was in flight. The epoch catches a sign-out that
      // completed just before the session check re-read the stored blob.
      if (_epochOf(config.id) != epoch) {
        throw OAuthSessionSupersededException(provider: config.oauthProvider);
      }
      final latest = credentialsFor(config);
      if (latest == null || latest.sessionId != current.sessionId) {
        throw OAuthSessionSupersededException(provider: config.oauthProvider);
      }
      _cache[config.id] = refreshed;
      _loginRequired.remove(config.id);
      await _persistCredentials(config.id, refreshed, epoch: epoch);
      notifyListeners();
      return refreshed;
    } on OAuthException catch (e) {
      if (e.loginRequired) markLoginRequired(config.id);
      rethrow;
    } catch (e) {
      // Network failures stay transient: a user with valid credentials must not
      // be thrown into the re-login flow (plan C16).
      throw OAuthTransportException(
        e.toString(),
        provider: config.oauthProvider,
      );
    } finally {
      client.close();
    }
  }

  Future<void> _persistCredentials(
    String providerId,
    ProviderOAuthCredentials credentials, {
    int? epoch,
  }) async {
    final updater = _updater;
    if (updater == null) return;
    try {
      await updater(providerId, (current) {
        // Re-check inside the write: sign-out may have landed between the
        // post-refresh checks and this updater call.
        if (epoch != null && _epochOf(providerId) != epoch) return current;
        return current.copyWith(oauthCredentials: credentials.toJson());
      });
    } catch (_) {}
  }

  /// Intentional sign-out: credentials go away, the model list stays (D5).
  Future<void> logout(ProviderConfig config) async {
    // Invalidate every refresh that was already in flight for this account.
    _epochs[config.id] = _epochOf(config.id) + 1;
    _cache.remove(config.id);
    _loginRequired.remove(config.id);
    _usageCache.remove(config.id);
    _usageFetchedAt.remove(config.id);
    final updater = _updater;
    if (updater != null) {
      await updater(config.id, (current) => current.clearOAuthCredentials());
    }
    notifyListeners();
  }

  // ---- model sync --------------------------------------------------------

  /// Builds the provider-owned `reasoningSynced` map only from metadata the
  /// provider actually returned. Missing fields stay absent so models.dev or
  /// the built-in regex can still supply them.
  static Map<String, dynamic>? _syncedReasoningForEntry(OAuthModelEntry entry) {
    if (entry.efforts.isEmpty &&
        entry.thinkingAlwaysOn == null &&
        entry.offFallback == null) {
      return null;
    }
    return <String, dynamic>{
      'v': 1,
      if (entry.efforts.isNotEmpty)
        'efforts': <String>[
          for (final effort in ReasoningOverride.allEfforts)
            if (entry.efforts.contains(effort)) effort,
        ],
      if (entry.offFallback != null) 'offFallback': entry.offFallback,
      // A false-only flag is treated as "no opinion" by ReasoningOverride.isEmpty
      // (the user-customization guard). Keep false only when the effort set
      // itself makes the layer non-empty.
      if (entry.thinkingAlwaysOn != null &&
          (entry.thinkingAlwaysOn == true || entry.efforts.isNotEmpty))
        'thinkingAlwaysOn': entry.thinkingAlwaysOn,
    };
  }

  /// Merges synced models without ever touching user-authored overrides (C13).
  @visibleForTesting
  static ProviderConfig mergeSyncedModels(
    ProviderConfig config,
    List<OAuthModelEntry> entries, {
    required String accountId,
  }) {
    var previousAccount = ProviderOAuthCredentials.fromJson(
      config.oauthCredentials,
    )?.accountId;
    final models = List<String>.from(config.models);
    final overrides = Map<String, dynamic>.from(config.modelOverrides);

    // Re-login replaces `oauthCredentials` before the first sync, so the
    // config's account id may already be the new one. The override metadata is
    // the durable record of which account the existing synced models came
    // from (D5).
    if (accountId.isNotEmpty) {
      for (final value in overrides.values) {
        if (value is! Map || value['source'] != 'oauth-synced') continue;
        final syncedAccount = (value['oauthAccountId'] ?? '').toString().trim();
        if (syncedAccount.isNotEmpty && syncedAccount != accountId) {
          previousAccount = syncedAccount;
          break;
        }
      }
    }

    if (accountId.isNotEmpty &&
        previousAccount != null &&
        previousAccount.isNotEmpty &&
        previousAccount != accountId) {
      // A different account signed in: its synced models replace the previous
      // account's, while hand-added models survive.
      for (final id in models.toList()) {
        final ov = overrides[id];
        if (ov is Map && ov['source'] == 'oauth-synced') {
          models.remove(id);
          overrides.remove(id);
        }
      }
    }

    for (final entry in entries) {
      if (!models.contains(entry.id)) models.add(entry.id);
      final existingRaw = overrides[entry.id];
      final existing = existingRaw is Map
          ? existingRaw.cast<String, dynamic>()
          : <String, dynamic>{};
      final syncedReasoning = _syncedReasoningForEntry(entry);
      if (existing.isNotEmpty && existing['source'] != 'oauth-synced') {
        // Hand-authored override: keep every user field, but capability
        // metadata is still provider-owned and should stay fresh.
        final next = <String, dynamic>{...existing};
        if (syncedReasoning != null) {
          next['reasoningSynced'] = syncedReasoning;
        } else {
          next.remove('reasoningSynced');
        }
        overrides[entry.id] = next;
        continue;
      }
      final next = <String, dynamic>{
        ...existing,
        'name': entry.displayName,
        'type': 'chat',
        'input': entry.vision ? <String>['text', 'image'] : <String>['text'],
        'output': const <String>['text'],
        'abilities': <String>[
          if (entry.tool) 'tool',
          if (entry.reasoning) 'reasoning',
        ],
        if (entry.protocol != null) 'oauthProtocol': entry.protocol,
        'source': 'oauth-synced',
        'oauthAccountId': accountId,
      };
      if (syncedReasoning != null) {
        next['reasoningSynced'] = syncedReasoning;
      } else {
        next.remove('reasoningSynced');
      }
      overrides[entry.id] = next;
    }

    return config.copyWith(models: models, modelOverrides: overrides);
  }

  /// Fetches and persists this account's models.
  Future<ProviderConfig> syncModels(
    ProviderConfig config, {
    bool throwOnFailure = true,
  }) async {
    if (config.oauthProvider == null) return config;
    final epoch = _epochOf(config.id);
    final access = await resolve(config);
    final client = _newClient(config);
    try {
      final entries = await _adapter(
        config.oauthProvider!,
      ).fetchModels(credentials: access.credentials, client: client);
      // Signing out during the fetch must not restore the model list onto a
      // signed-out account (and must never re-persist the old credentials).
      if (_epochOf(config.id) != epoch) {
        if (throwOnFailure) {
          throw OAuthSessionSupersededException(provider: config.oauthProvider);
        }
        return config.clearOAuthCredentials();
      }
      final accountId = access.credentials.accountId ?? '';
      var updated = mergeSyncedModels(config, entries, accountId: accountId);
      // A concurrent 401 may have refreshed (and rotated) the token while the
      // model list was downloading. Persist that newer token, never the one
      // that started the request, or the next launch uses a dead refresh token.
      var credentials = credentialsFor(config) ?? access.credentials;
      if (credentials.sessionId != access.credentials.sessionId) {
        throw OAuthSessionSupersededException(provider: config.oauthProvider);
      }
      if (config.oauthProvider == OAuthProvider.chatgpt) {
        credentials = credentials.copyWith(
          modelsClientVersion: ProviderOAuthConstants.codexClientVersion,
        );
      }
      _cache[config.id] = credentials;
      updated = updated.copyWith(oauthCredentials: credentials.toJson());
      final updater = _updater;
      if (updater != null) {
        // Re-merge against the config as it is now: enabled/proxy/prompt-cache
        // changes and user-added models made while the list was downloading
        // must survive.
        await updater(config.id, (current) {
          // The sign-out may have landed between the epoch check above and
          // this write; never resurrect credentials in that window.
          if (_epochOf(config.id) != epoch) return current;
          return mergeSyncedModels(
            current,
            entries,
            accountId: accountId,
          ).copyWith(oauthCredentials: credentials.toJson());
        });
      }
      notifyListeners();
      return updated;
    } on OAuthException catch (e) {
      // A rejected token must move the account into the recovery state even
      // when the model list is fetched outside the chat path.
      if (e.loginRequired) markLoginRequired(config.id);
      if (throwOnFailure) rethrow;
      return config;
    } catch (e) {
      if (throwOnFailure) {
        throw OAuthTransportException(
          e.toString(),
          provider: config.oauthProvider,
        );
      }
      return config;
    } finally {
      client.close();
    }
  }

  /// Network-only model listing for the "add models" sheet. Persistence stays
  /// with the caller so its normal selection flow keeps working.
  Future<List<OAuthModelEntry>> fetchModels(ProviderConfig config) async {
    final access = await resolve(config);
    final client = _newClient(config);
    try {
      return await _adapter(
        config.oauthProvider!,
      ).fetchModels(credentials: access.credentials, client: client);
    } on OAuthException catch (e) {
      if (e.loginRequired) markLoginRequired(config.id);
      rethrow;
    } finally {
      client.close();
    }
  }

  /// Startup re-sync when the pinned Codex client version moved (plan §2.2).
  /// Bounded and single-flight; failures are silent.
  Future<void> syncOutdatedModels(SettingsProvider settings) async {
    if (!_enabled || _syncingOutdated) return;
    _syncingOutdated = true;
    try {
      // Materialize before any write: setProviderConfig mutates the map.
      final configs = settings.providerConfigs.values
          .where(
            (c) =>
                c.oauthProvider == OAuthProvider.chatgpt &&
                c.oauthCredentials != null,
          )
          .toList();
      for (final config in configs) {
        final version = ProviderOAuthCredentials.fromJson(
          config.oauthCredentials,
        )?.modelsClientVersion;
        if (version == ProviderOAuthConstants.codexClientVersion) continue;
        try {
          await syncModels(
            config,
            throwOnFailure: false,
          ).timeout(const Duration(seconds: 3));
        } catch (_) {}
      }
    } finally {
      _syncingOutdated = false;
    }
  }

  // ---- usage -------------------------------------------------------------

  Future<OAuthUsage> fetchUsage(
    ProviderConfig config, {
    bool force = false,
  }) async {
    final cachedAt = _usageFetchedAt[config.id];
    final cached = _usageCache[config.id];
    if (!force &&
        cached != null &&
        cachedAt != null &&
        DateTime.now().difference(cachedAt) < usageCacheTtl) {
      return cached;
    }
    final access = await resolve(config);
    final client = _newClient(config);
    try {
      final usage = await _adapter(
        config.oauthProvider!,
      ).fetchUsage(credentials: access.credentials, client: client);
      // Never cache a previous session's usage after a re-login raced the
      // request; the caller's own session guard handles the display.
      if (credentialsFor(config)?.sessionId == access.sessionId) {
        _usageCache[config.id] = usage;
        _usageFetchedAt[config.id] = DateTime.now();
      }
      notifyListeners();
      return usage;
    } on OAuthException catch (e) {
      if (e.loginRequired) markLoginRequired(config.id);
      rethrow;
    } finally {
      client.close();
    }
  }

  @visibleForTesting
  void setUsageCache(String providerId, OAuthUsage usage) {
    _usageCache[providerId] = usage;
    _usageFetchedAt[providerId] = DateTime.now();
  }
}
