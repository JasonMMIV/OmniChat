// Model-sync merge semantics (plan C13 / D5): user overrides are never
// overwritten, sync failures keep the old list, and switching accounts replaces
// only the models that were synced from the previous account.

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/models/provider_oauth.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/auth/provider_oauth_service.dart';

ProviderConfig _config({String account = 'account-a'}) =>
    ProviderConfig.oauthAccount(
      id: 'Claude',
      name: 'Claude',
      provider: OAuthProvider.claude,
      credentials: ProviderOAuthCredentials(
        accessToken: 'a',
        refreshToken: 'r',
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
        sessionId: 's',
        accountId: account,
      ).toJson(),
      models: const <String>['user-model', 'synced-old'],
      modelOverrides: const <String, dynamic>{
        'user-model': <String, dynamic>{
          'name': 'My model',
          'source': 'user',
          'headers': <Map<String, dynamic>>[
            <String, dynamic>{'name': 'X-Test', 'value': '1'},
          ],
        },
        'synced-old': <String, dynamic>{
          'name': 'Old',
          'source': 'oauth-synced',
          'oauthAccountId': 'account-a',
          'reasoning': <String, dynamic>{
            'efforts': <String>['low', 'high'],
          },
        },
      },
    );

void main() {
  test('same account: adds models and refreshes synced metadata only', () {
    final merged = ProviderOAuthService.mergeSyncedModels(
      _config(),
      const <OAuthModelEntry>[
        OAuthModelEntry(
          id: 'claude-sonnet-4-5',
          displayName: 'Sonnet 4.5',
          vision: true,
        ),
      ],
      accountId: 'account-a',
    );

    expect(
      merged.models,
      containsAll(<String>['user-model', 'synced-old', 'claude-sonnet-4-5']),
    );
    expect(merged.modelOverrides['user-model'], isNotNull);
    final userOverride = merged.modelOverrides['user-model'] as Map;
    expect(userOverride['name'], 'My model');
    expect(userOverride['headers'], isNotNull);
    final synced = merged.modelOverrides['claude-sonnet-4-5'] as Map;
    expect(synced['source'], 'oauth-synced');
    expect(synced['oauthAccountId'], 'account-a');
    expect(synced['abilities'], containsAll(<String>['tool', 'reasoning']));
    expect(synced['input'], contains('image'));
  });

  test(
    'different account replaces oauth-synced models but keeps user models',
    () {
      final merged = ProviderOAuthService.mergeSyncedModels(
        _config(),
        const <OAuthModelEntry>[
          OAuthModelEntry(id: 'claude-opus-4-6', displayName: 'Opus 4.6'),
        ],
        accountId: 'account-b',
      );

      expect(merged.models, isNot(contains('synced-old')));
      expect(merged.modelOverrides.containsKey('synced-old'), isFalse);
      expect(merged.models, contains('user-model'));
      expect(merged.models, contains('claude-opus-4-6'));
      expect((merged.modelOverrides['user-model'] as Map)['name'], 'My model');
    },
  );

  test('re-login detects the old account from synced override metadata', () {
    // The page writes the new credentials before syncing, so the credential
    // blob alone can no longer tell which account the models came from.
    final merged = ProviderOAuthService.mergeSyncedModels(
      _config(account: 'account-b'),
      const <OAuthModelEntry>[
        OAuthModelEntry(id: 'claude-opus-4-6', displayName: 'Opus 4.6'),
      ],
      accountId: 'account-b',
    );
    expect(merged.models, isNot(contains('synced-old')));
    expect(merged.modelOverrides.containsKey('synced-old'), isFalse);
    expect(merged.models, contains('user-model'));
    expect(merged.models, contains('claude-opus-4-6'));
  });

  test('user-authored overrides are never replaced by sync', () {
    final merged = ProviderOAuthService.mergeSyncedModels(
      _config(),
      const <OAuthModelEntry>[
        OAuthModelEntry(
          id: 'user-model',
          displayName: 'Synced name',
          vision: false,
        ),
      ],
      accountId: 'account-a',
    );
    final override = merged.modelOverrides['user-model'] as Map;
    expect(override['name'], 'My model');
    expect(override['headers'], isNotNull);
    expect(override['source'], 'user');
  });

  test('sync persists provider reasoning separately from user overrides', () {
    final merged = ProviderOAuthService.mergeSyncedModels(
      _config(),
      const <OAuthModelEntry>[
        OAuthModelEntry(
          id: 'synced-old',
          displayName: 'Old',
          efforts: <String>{'xhigh', 'low', 'high'},
          thinkingAlwaysOn: true,
        ),
        OAuthModelEntry(
          id: 'user-model',
          displayName: 'Synced name',
          efforts: <String>{'max'},
        ),
      ],
      accountId: 'account-a',
    );

    final synced = merged.modelOverrides['synced-old'] as Map;
    final syncedReasoning = synced['reasoningSynced'] as Map;
    expect(syncedReasoning['v'], 1);
    expect(syncedReasoning['efforts'], <String>['low', 'high', 'xhigh']);
    expect(syncedReasoning['thinkingAlwaysOn'], isTrue);
    expect(synced['source'], 'oauth-synced');
    expect((synced['reasoning'] as Map)['efforts'], <String>['low', 'high']);

    final user = merged.modelOverrides['user-model'] as Map;
    expect(user['name'], 'My model');
    expect(user['source'], 'user');
    // Provider capability metadata still refreshes for user-owned entries.
    expect((user['reasoningSynced'] as Map)['efforts'], <String>['max']);
  });

  test('a later sync without metadata removes only reasoningSynced', () {
    final initial = ProviderOAuthService.mergeSyncedModels(
      _config(),
      const <OAuthModelEntry>[
        OAuthModelEntry(
          id: 'synced-old',
          displayName: 'Old',
          efforts: <String>{'low', 'max'},
        ),
      ],
      accountId: 'account-a',
    );
    expect(
      (initial.modelOverrides['synced-old'] as Map).containsKey(
        'reasoningSynced',
      ),
      isTrue,
    );

    final next = ProviderOAuthService.mergeSyncedModels(
      initial,
      const <OAuthModelEntry>[
        OAuthModelEntry(id: 'synced-old', displayName: 'Old'),
      ],
      accountId: 'account-a',
    );
    final override = next.modelOverrides['synced-old'] as Map;
    expect(override.containsKey('reasoningSynced'), isFalse);
    expect((override['reasoning'] as Map)['efforts'], <String>['low', 'high']);
  });

  test('empty sync result leaves the existing list untouched', () {
    final merged = ProviderOAuthService.mergeSyncedModels(
      _config(),
      const <OAuthModelEntry>[],
      accountId: 'account-a',
    );
    expect(merged.models, <String>['user-model', 'synced-old']);
  });
}
