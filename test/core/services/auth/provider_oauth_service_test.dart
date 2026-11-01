// Service-level contract (plan §8): leeway refresh, concurrent refresh
// de-duplication, session checks, login-required marking, transient vs auth
// failures, kill-switch and sign-out that keeps the model list.

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:OmniChat/core/models/provider_oauth.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/auth/oauth_errors.dart';
import 'package:OmniChat/core/services/auth/provider_oauth_adapter.dart';
import 'package:OmniChat/core/services/auth/provider_oauth_service.dart';

class _FakeAdapter implements ProviderOAuthAdapter {
  _FakeAdapter({this.refreshError});

  Duration refreshDelay = const Duration(milliseconds: 20);
  final Object? refreshError;
  final String refreshTokenValue = 'new-token';
  int refreshCalls = 0;
  Object? modelError;
  List<OAuthModelEntry> models = const <OAuthModelEntry>[];
  Future<void> Function()? duringFetchModels;

  @override
  OAuthProvider get provider => OAuthProvider.claude;

  @override
  Future<ProviderOAuthCredentials> refresh({
    required ProviderOAuthCredentials credentials,
    required http.Client client,
  }) async {
    refreshCalls += 1;
    await Future<void>.delayed(refreshDelay);
    final error = refreshError;
    if (error != null) throw error;
    return credentials.copyWith(
      accessToken: refreshTokenValue,
      expiresAt: DateTime.now().add(const Duration(hours: 1)),
    );
  }

  @override
  Future<ProviderOAuthCredentials> login({
    required OAuthLoginController controller,
    required http.Client client,
    required Future<bool> Function(String url) launchBrowser,
    required String sessionId,
    String? previousDeviceId,
  }) async => throw UnimplementedError();

  @override
  Future<List<OAuthModelEntry>> fetchModels({
    required ProviderOAuthCredentials credentials,
    required http.Client client,
  }) async {
    final error = modelError;
    if (error != null) throw error;
    await duringFetchModels?.call();
    return models;
  }

  @override
  Future<OAuthUsage> fetchUsage({
    required ProviderOAuthCredentials credentials,
    required http.Client client,
  }) async => throw UnimplementedError();

  @override
  Future<ProviderOAuthCredentials> enrichIdentity({
    required ProviderOAuthCredentials credentials,
    required http.Client client,
  }) async => credentials;
}

ProviderConfig _config({DateTime? expiresAt, String sessionId = 'session-1'}) {
  final credentials = ProviderOAuthCredentials(
    accessToken: 'old-token',
    refreshToken: 'refresh-token',
    expiresAt: expiresAt ?? DateTime.now().add(const Duration(minutes: 30)),
    sessionId: sessionId,
    accountId: 'account-1',
  );
  return ProviderConfig.oauthAccount(
    id: 'Claude',
    name: 'Claude',
    provider: OAuthProvider.claude,
    credentials: credentials.toJson(),
    models: const <String>['claude-sonnet-4-5'],
  );
}

ProviderOAuthService _service(_FakeAdapter adapter, {bool enabled = true}) =>
    ProviderOAuthService.testing(
      adapterFactory: (_) => adapter,
      enabled: enabled,
    );

void main() {
  test('a token outside the leeway is returned without refreshing', () async {
    final adapter = _FakeAdapter();
    final service = _service(adapter);
    final access = await service.resolve(_config());
    expect(access.token, 'old-token');
    expect(adapter.refreshCalls, 0);
  });

  test('a token inside the five-minute leeway refreshes once', () async {
    final adapter = _FakeAdapter();
    final service = _service(adapter);
    final access = await service.resolve(
      _config(expiresAt: DateTime.now().add(const Duration(minutes: 2))),
    );
    expect(access.token, 'new-token');
    expect(adapter.refreshCalls, 1);
  });

  test('concurrent 401s share one refresh future', () async {
    final adapter = _FakeAdapter();
    final service = _service(adapter);
    final config = _config(
      expiresAt: DateTime.now().add(const Duration(minutes: 1)),
    );
    final results = await Future.wait(<Future<OAuthAccessToken>>[
      service.resolve(config),
      service.resolve(config),
      service.resolve(config),
    ]);
    expect(results.map((r) => r.token).toSet(), <String>{'new-token'});
    expect(adapter.refreshCalls, 1);
  });

  test(
    'forceRefresh rejects a stale session without marking the new one',
    () async {
      final adapter = _FakeAdapter();
      final service = _service(adapter);
      final config = _config();
      await expectLater(
        service.forceRefresh(config, sessionId: 'other-session'),
        throwsA(isA<OAuthSessionSupersededException>()),
      );
      expect(service.isLoginRequired(config.id), isFalse);
      expect(adapter.refreshCalls, 0);
    },
  );

  test('a logout during refresh cannot resurrect the credentials', () async {
    final adapter = _FakeAdapter();
    final service = _service(adapter);
    ProviderConfig? persisted;
    service.attachUpdater((id, update) async {
      persisted = update(persisted ?? _config());
    });
    final config = _config(
      expiresAt: DateTime.now().add(const Duration(minutes: 1)),
    );
    final pending = service.resolve(config);
    await Future<void>.delayed(const Duration(milliseconds: 1));
    await service.logout(config);
    await expectLater(pending, throwsA(isA<OAuthSessionSupersededException>()));
    expect(persisted?.oauthCredentials, isNull);
    expect(service.isLoginRequired(config.id), isFalse);
  });

  test('a new login never joins the previous session\'s refresh', () async {
    final adapter = _FakeAdapter()
      ..refreshDelay = const Duration(milliseconds: 30);
    final service = _service(adapter);
    final oldConfig = _config(
      expiresAt: DateTime.now().add(const Duration(minutes: 1)),
    );
    final oldRefresh = service.resolve(oldConfig);
    final oldExpectation = expectLater(
      oldRefresh,
      throwsA(isA<OAuthSessionSupersededException>()),
    );
    await Future<void>.delayed(const Duration(milliseconds: 1));

    final newCredentials = ProviderOAuthCredentials(
      accessToken: 'login-token',
      refreshToken: 'login-refresh',
      expiresAt: DateTime.now().add(const Duration(hours: 1)),
      sessionId: 'session-2',
      accountId: 'account-1',
    );
    final newConfig = ProviderConfig.oauthAccount(
      id: 'Claude',
      name: 'Claude',
      provider: OAuthProvider.claude,
      credentials: newCredentials.toJson(),
    );
    await service.applyLoginResult(newConfig, newCredentials);

    // forceRefresh must start a refresh for session-2 instead of returning the
    // old session's (doomed) future.
    final refreshed = await service.forceRefresh(
      newConfig,
      sessionId: 'session-2',
    );
    expect(refreshed.token, adapter.refreshTokenValue);
    expect(refreshed.sessionId, 'session-2');
    expect(adapter.refreshCalls, 2);
    await oldExpectation;
  });

  test('model sync persists a refresh that landed during the fetch', () async {
    final adapter = _FakeAdapter();
    final service = _service(adapter);
    final config = _config();
    ProviderConfig? persisted;
    service.attachUpdater((id, update) async {
      persisted = update(persisted ?? config);
    });
    adapter.models = const <OAuthModelEntry>[
      OAuthModelEntry(id: 'claude-opus-4-6', displayName: 'Opus 4.6'),
    ];
    adapter.duringFetchModels = () async {
      // A concurrent 401 refreshes and rotates the token while the model list
      // is downloading. The sync must persist the newer token, not the one it
      // started with.
      await service.forceRefresh(config, sessionId: 'session-1');
    };

    await service.syncModels(config, throwOnFailure: false);

    final stored = persisted!.oauthCredentialsValue!;
    expect(stored.accessToken, adapter.refreshTokenValue);
    expect(stored.sessionId, 'session-1');
    expect(persisted!.models, contains('claude-opus-4-6'));
  });

  test('an invalid_grant refresh marks login required and rethrows', () async {
    final adapter = _FakeAdapter(
      refreshError: OAuthException(
        'Token refresh failed (HTTP 400): invalid_grant',
        loginRequired: true,
      ),
    );
    final service = _service(adapter);
    final config = _config(
      expiresAt: DateTime.now().add(const Duration(minutes: 1)),
    );
    await expectLater(service.resolve(config), throwsA(isA<OAuthException>()));
    expect(service.isLoginRequired(config.id), isTrue);
  });

  test('a rejected model sync marks the account as login-required', () async {
    final adapter = _FakeAdapter()
      ..modelError = OAuthException(
        'Model sync failed (HTTP 401)',
        loginRequired: true,
      );
    final service = _service(adapter);
    final config = _config();
    await expectLater(
      service.syncModels(config),
      throwsA(isA<OAuthException>()),
    );
    expect(service.isLoginRequired(config.id), isTrue);
  });

  test('a transport failure stays transient', () async {
    final adapter = _FakeAdapter(
      refreshError: OAuthTransportException('network down'),
    );
    final service = _service(adapter);
    final config = _config(
      expiresAt: DateTime.now().add(const Duration(minutes: 1)),
    );
    await expectLater(
      service.resolve(config),
      throwsA(isA<OAuthTransportException>()),
    );
    expect(service.isLoginRequired(config.id), isFalse);
  });

  test('missing credentials throw login-required', () async {
    final service = _service(_FakeAdapter());
    final config = ProviderConfig.oauthAccount(
      id: 'Claude',
      name: 'Claude',
      provider: OAuthProvider.claude,
    );
    await expectLater(
      service.resolve(config),
      throwsA(isA<OAuthLoginRequiredException>()),
    );
    expect(service.isLoginRequired(config.id), isTrue);
  });

  test('kill-switch blocks resolution', () async {
    final service = _service(_FakeAdapter(), enabled: false);
    await expectLater(
      service.resolve(_config()),
      throwsA(isA<OAuthDisabledException>()),
    );
  });

  test('logout clears credentials but keeps the model list', () async {
    final service = _service(_FakeAdapter());
    ProviderConfig? persisted;
    service.attachUpdater((id, update) async {
      persisted = update(_config());
    });
    await service.logout(_config());
    expect(persisted, isNotNull);
    expect(persisted!.oauthCredentials, isNull);
    expect(persisted!.oauthProvider, OAuthProvider.claude);
    expect(persisted!.models, <String>['claude-sonnet-4-5']);
  });
}
