// Share/QR boundary for subscription accounts (plan C6): the exported skeleton
// keeps the provider type but never carries credentials, and the import side
// builds a signed-out OAuth provider.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/models/provider_oauth.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/features/provider/widgets/share_provider_sheet.dart';

void main() {
  test('OAuth provider export strips credentials and marks the provider', () {
    final cfg = ProviderConfig.oauthAccount(
      id: 'Claude',
      name: 'Claude',
      provider: OAuthProvider.claude,
      credentials: ProviderOAuthCredentials(
        accessToken: 'secret-access',
        refreshToken: 'secret-refresh',
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
        sessionId: 'session',
      ).toJson(),
    );

    final code = encodeProviderConfig(cfg);
    expect(code.startsWith('ai-provider:v1:'), isTrue);
    final decoded = jsonDecode(
      utf8.decode(base64Decode(code.substring('ai-provider:v1:'.length))),
    ) as Map<String, dynamic>;

    expect(decoded['oauth'], 'claude');
    expect(decoded['type'], 'claude');
    expect(decoded['apiKey'], '');
    final raw = jsonEncode(decoded);
    expect(raw.contains('secret-access'), isFalse);
    expect(raw.contains('secret-refresh'), isFalse);
    expect(raw.contains('oauthCredentials'), isFalse);
  });

  test('ChatGPT export keeps the oauth marker and an empty key', () {
    final cfg = ProviderConfig.oauthAccount(
      id: 'ChatGPT',
      name: 'ChatGPT',
      provider: OAuthProvider.chatgpt,
    );
    final code = encodeProviderConfig(cfg);
    final decoded = jsonDecode(
      utf8.decode(base64Decode(code.substring('ai-provider:v1:'.length))),
    ) as Map<String, dynamic>;
    expect(decoded['oauth'], 'chatgpt');
    expect(decoded['apiKey'], '');
    expect(decoded['type'], 'openai');
  });

  test('non-OAuth export is unchanged', () {
    final cfg = ProviderConfig(
      id: 'OpenAI',
      enabled: true,
      name: 'OpenAI',
      apiKey: 'sk-test',
      baseUrl: 'https://api.openai.com/v1',
      providerType: ProviderKind.openai,
    );
    final code = encodeProviderConfig(cfg);
    final decoded = jsonDecode(
      utf8.decode(base64Decode(code.substring('ai-provider:v1:'.length))),
    ) as Map<String, dynamic>;
    expect(decoded.containsKey('oauth'), isFalse);
    expect(decoded['apiKey'], 'sk-test');
  });
}
