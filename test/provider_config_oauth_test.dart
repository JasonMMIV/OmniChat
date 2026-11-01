// ProviderConfig OAuth fields: JSON symmetry, legacy fallback, the nullable
// copyWith trap and the dedicated clear path (plan C14 / §8).

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/models/provider_oauth.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';

ProviderOAuthCredentials _creds() => ProviderOAuthCredentials(
  accessToken: 'access',
  refreshToken: 'refresh',
  expiresAt: DateTime.fromMillisecondsSinceEpoch(1800000000000),
  sessionId: 'session-1',
  accountId: 'acct',
  email: 'user@example.com',
  planType: 'plus',
  deviceId: 'device',
);

void main() {
  test('OAuth factory selects the native transport per provider', () {
    final claude = ProviderConfig.oauthAccount(
      id: 'Claude',
      name: 'Claude',
      provider: OAuthProvider.claude,
    );
    expect(claude.providerType, ProviderKind.claude);
    expect(claude.baseUrl, ProviderOAuthConstants.claudeBaseUrl);
    expect(claude.useResponseApi, isNot(true));
    expect(claude.claudePromptCachingEnabled, isTrue);
    expect(
      claude.claudePromptCachingTtl,
      ProviderConfig.claudePromptCachingTtl1h,
    );

    final chatgpt = ProviderConfig.oauthAccount(
      id: 'ChatGPT',
      name: 'ChatGPT',
      provider: OAuthProvider.chatgpt,
    );
    expect(chatgpt.providerType, ProviderKind.openai);
    expect(chatgpt.baseUrl, ProviderOAuthConstants.codexBaseUrl);
    expect(chatgpt.useResponseApi, isTrue);

    final grok = ProviderConfig.oauthAccount(
      id: 'Grok',
      name: 'Grok',
      provider: OAuthProvider.grok,
    );
    expect(grok.providerType, ProviderKind.openai);
    expect(grok.baseUrl, ProviderOAuthConstants.grokBaseUrl);
    expect(grok.useResponseApi, isTrue);

    final kimi = ProviderConfig.oauthAccount(
      id: 'Kimi',
      name: 'Kimi',
      provider: OAuthProvider.kimi,
    );
    expect(kimi.providerType, ProviderKind.openai);
    expect(kimi.baseUrl, ProviderOAuthConstants.kimiBaseUrl);
    expect(kimi.useResponseApi, isNot(true));
  });

  test(
    'Kimi resolves the per-model wire protocol before transport selection',
    () {
      final kimi = ProviderConfig.oauthAccount(
        id: 'Kimi',
        name: 'Kimi',
        provider: OAuthProvider.kimi,
        modelOverrides: const <String, dynamic>{
          'kimi-k3': <String, dynamic>{'oauthProtocol': 'anthropic'},
          'kimi-k2.5': <String, dynamic>{'oauthProtocol': 'openai'},
        },
      );
      expect(
        kimi.forModelProtocol('kimi-k3').providerType,
        ProviderKind.claude,
      );
      expect(
        kimi.forModelProtocol('kimi-k2.5').providerType,
        ProviderKind.openai,
      );
      expect(
        kimi.forModelProtocol('unknown').providerType,
        ProviderKind.openai,
      );
    },
  );

  test('toJson/fromJson round-trips the provider and credentials', () {
    final cfg = ProviderConfig.oauthAccount(
      id: 'Claude',
      name: 'Claude',
      provider: OAuthProvider.claude,
      credentials: _creds().toJson(),
    );
    final restored = ProviderConfig.fromJson(cfg.toJson());
    expect(restored.oauthProvider, OAuthProvider.claude);
    final creds = restored.oauthCredentialsValue;
    expect(creds, isNotNull);
    expect(creds!.accessToken, 'access');
    expect(creds.refreshToken, 'refresh');
    expect(creds.accountId, 'acct');
    expect(creds.email, 'user@example.com');
    expect(creds.planType, 'plus');
    expect(creds.sessionId, 'session-1');
    expect(creds.deviceId, 'device');
    expect(creds.expiresAt, DateTime.fromMillisecondsSinceEpoch(1800000000000));
  });

  test('legacy JSON without OAuth fields loads as a plain provider', () {
    final cfg = ProviderConfig.fromJson(<String, dynamic>{
      'id': 'OpenAI',
      'name': 'OpenAI',
      'apiKey': 'sk-x',
      'baseUrl': 'https://api.openai.com/v1',
      'providerType': 'openai',
      'models': <String>['gpt-4o'],
    });
    expect(cfg.oauthProvider, isNull);
    expect(cfg.oauthCredentials, isNull);
    expect(cfg.isOAuth, isFalse);
  });

  test('unknown oauthProvider values degrade to null', () {
    final cfg = ProviderConfig.fromJson(<String, dynamic>{
      'id': 'X',
      'name': 'X',
      'apiKey': '',
      'baseUrl': '',
      'oauthProvider': 'future-provider',
    });
    expect(cfg.oauthProvider, isNull);
  });

  test(
    'copyWith cannot clear credentials; clearOAuthCredentials does (C14)',
    () {
      final cfg = ProviderConfig.oauthAccount(
        id: 'Claude',
        name: 'Claude',
        provider: OAuthProvider.claude,
        credentials: _creds().toJson(),
        models: const <String>['claude-sonnet-4-5'],
      );
      expect(cfg.copyWith(oauthCredentials: null).oauthCredentials, isNotNull);

      final cleared = cfg.clearOAuthCredentials();
      expect(cleared.oauthCredentials, isNull);
      expect(cleared.oauthProvider, OAuthProvider.claude);
      expect(cleared.models, <String>['claude-sonnet-4-5']);
      expect(cleared.name, 'Claude');
    },
  );

  test('malformed credential blobs are treated as signed out', () {
    final cfg = ProviderConfig.oauthAccount(
      id: 'Claude',
      name: 'Claude',
      provider: OAuthProvider.claude,
      credentials: const <String, dynamic>{'v': 1, 'accessToken': 42},
    );
    expect(cfg.oauthCredentialsValue, isNull);
  });
}
