// Classification tests for the recovery flow (plan C3/C16). The wrapper
// returns a second 401 instead of throwing, so the transport surfaces a plain
// HttpException; that shape must still open the recovery card while the
// account is flagged.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/models/provider_oauth.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/auth/oauth_errors.dart';
import 'package:OmniChat/core/services/auth/oauth_failure.dart';

ProviderConfig _oauth() => ProviderConfig.oauthAccount(
  id: 'ChatGPT',
  name: 'ChatGPT',
  provider: OAuthProvider.chatgpt,
);

ProviderConfig _apiKey() => ProviderConfig(
  id: 'OpenAI',
  enabled: true,
  name: 'OpenAI',
  apiKey: 'sk-test',
  baseUrl: 'https://api.openai.com/v1',
);

void main() {
  test('an OAuthException login-required failure is authoritative', () {
    expect(
      isOAuthLoginRequiredFailure(
        config: _oauth(),
        error: OAuthLoginRequiredException(provider: OAuthProvider.chatgpt),
        accountFlagged: false,
      ),
      isTrue,
    );
  });

  test('the second-401 HttpException counts while the account is flagged', () {
    expect(
      isOAuthLoginRequiredFailure(
        config: _oauth(),
        error: HttpException('HTTP 401: unauthorized'),
        accountFlagged: true,
      ),
      isTrue,
    );
  });

  test('the same 401 is not hijacked when no account is flagged', () {
    expect(
      isOAuthLoginRequiredFailure(
        config: _oauth(),
        error: HttpException('HTTP 401: unauthorized'),
        accountFlagged: false,
      ),
      isFalse,
    );
  });

  test('a later 500 keeps its own error even on a flagged account', () {
    expect(
      isOAuthLoginRequiredFailure(
        config: _oauth(),
        error: HttpException('HTTP 500: upstream'),
        accountFlagged: true,
      ),
      isFalse,
    );
  });

  test('a superseded session is not a login-required failure', () {
    expect(
      isOAuthLoginRequiredFailure(
        config: _oauth(),
        error: OAuthSessionSupersededException(provider: OAuthProvider.chatgpt),
        accountFlagged: true,
      ),
      isFalse,
    );
  });

  test('an API-key provider is never classified as OAuth recovery', () {
    expect(
      isOAuthLoginRequiredFailure(
        config: _apiKey(),
        error: HttpException('HTTP 401: unauthorized'),
        accountFlagged: true,
      ),
      isFalse,
    );
  });
}
