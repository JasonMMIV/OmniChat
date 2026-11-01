// M4 recovery card: visible only for a message that actually failed on
// subscription auth, hidden for API-key providers, and manual-only (Retry is a
// user action; nothing is re-sent automatically).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/models/provider_oauth.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/auth/oauth_recovery_registry.dart';
import 'package:OmniChat/core/services/auth/provider_oauth_service.dart';
import 'package:OmniChat/features/provider/widgets/oauth_message_recovery.dart';
import 'package:OmniChat/l10n/app_localizations.dart';

ProviderOAuthCredentials _credentials() => ProviderOAuthCredentials(
  accessToken: 'access-token',
  refreshToken: 'refresh-token',
  expiresAt: DateTime.now().add(const Duration(hours: 1)),
  sessionId: 'session-1',
  accountId: 'account-1',
);

ProviderConfig _config() => ProviderConfig.oauthAccount(
  id: 'ChatGPT',
  name: 'ChatGPT',
  provider: OAuthProvider.chatgpt,
  credentials: _credentials().toJson(),
);

Widget _wrap(Widget child) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(
    body: Center(child: SizedBox(width: 420, child: child)),
  ),
);

void main() {
  testWidgets('only a message recorded as an auth failure can show the card', (
    tester,
  ) async {
    final service = ProviderOAuthService.testing();
    final registry = OAuthRecoveryRegistry();
    final config = _config();
    await tester.pumpWidget(
      _wrap(
        OAuthMessageRecovery(
          messageId: 'm1',
          config: config,
          service: service,
          registry: registry,
        ),
      ),
    );
    // The account is flagged, but this particular message did not fail.
    service.markLoginRequired(config.id);
    await tester.pump();
    expect(find.text('Sign-in required'), findsNothing);

    registry.markFailed('m1');
    await tester.pump();
    expect(find.text('Sign-in required'), findsOneWidget);
    expect(find.text('Sign in again'), findsOneWidget);
    expect(
      find.textContaining('The subscription account for ChatGPT'),
      findsOneWidget,
    );

    // Signing in out of band flips the card to the manual retry state instead
    // of making it disappear under a now-stale bubble notice.
    service.clearLoginRequired(config.id);
    await tester.pump();
    expect(find.text('Ready to retry'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('retry is manual and keeps the version recoverable', (
    tester,
  ) async {
    final service = ProviderOAuthService.testing();
    final registry = OAuthRecoveryRegistry()..markFailed('m1');
    var retried = false;
    await tester.pumpWidget(
      _wrap(
        OAuthMessageRecovery(
          messageId: 'm1',
          config: _config(),
          service: service,
          registry: registry,
          onRetry: () => retried = true,
        ),
      ),
    );

    expect(find.text('Ready to retry'), findsOneWidget);
    expect(find.text('Sign in again'), findsNothing);

    await tester.tap(find.text('Retry'));
    await tester.pump();

    expect(retried, isTrue);
    // Retry creates a new version; switching back to this failed version must
    // still offer the manual retry, so the entry is not consumed here.
    expect(registry.isFailed('m1'), isTrue);
  });

  testWidgets('a non-OAuth provider never renders the card', (tester) async {
    final service = ProviderOAuthService.testing();
    final registry = OAuthRecoveryRegistry()..markFailed('m1');
    final apiKeyConfig = ProviderConfig(
      id: 'OpenAI',
      enabled: true,
      name: 'OpenAI',
      apiKey: 'sk-test',
      baseUrl: 'https://api.openai.com/v1',
    );
    await tester.pumpWidget(
      _wrap(
        OAuthMessageRecovery(
          messageId: 'm1',
          config: apiKeyConfig,
          service: service,
          registry: registry,
        ),
      ),
    );
    expect(find.text('Sign-in required'), findsNothing);
    expect(find.text('Sign in again'), findsNothing);
  });
}
