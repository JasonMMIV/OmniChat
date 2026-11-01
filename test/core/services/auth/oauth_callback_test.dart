// Loopback callback contract: receives the code, rejects a mismatched state
// without completing, and times out cleanly (plan §8).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/models/provider_oauth.dart';
import 'package:OmniChat/core/services/auth/oauth_callback.dart';
import 'package:OmniChat/core/services/auth/oauth_errors.dart';

Future<void> _hit(Uri uri) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(uri);
    final response = await request.close();
    await response.drain<void>();
  } finally {
    client.close(force: true);
  }
}

void main() {
  test('receives a code with a valid state', () async {
    final server = await OAuthCallbackServer.tryBind(
      provider: OAuthProvider.claude,
      allowEphemeralFallback: true,
    );
    expect(server, isNotNull);
    final future = server!.waitForCode(
      expectedState: 'state-1',
      timeout: const Duration(seconds: 5),
    );
    await _hit(
      server.redirectUri.replace(
        queryParameters: <String, String>{'code': 'code-1', 'state': 'state-1'},
      ),
    );
    final result = await future;
    expect(result.code, 'code-1');
  });

  test('a bad state is rejected and the wait continues', () async {
    final server = await OAuthCallbackServer.tryBind(
      provider: OAuthProvider.claude,
      allowEphemeralFallback: true,
    );
    final future = server!.waitForCode(
      expectedState: 'state-ok',
      timeout: const Duration(seconds: 5),
    );
    await _hit(
      server.redirectUri.replace(
        queryParameters: <String, String>{'code': 'code-1', 'state': 'bad'},
      ),
    );
    // Still pending: the wrong-state request must not complete the flow.
    var completed = false;
    future.whenComplete(() => completed = true);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(completed, isFalse);

    await _hit(
      server.redirectUri.replace(
        queryParameters: <String, String>{
          'code': 'code-2',
          'state': 'state-ok',
        },
      ),
    );
    final result = await future;
    expect(result.code, 'code-2');
  });

  test('times out when no redirect arrives', () async {
    final server = await OAuthCallbackServer.tryBind(
      provider: OAuthProvider.chatgpt,
      allowEphemeralFallback: true,
    );
    await expectLater(
      server!.waitForCode(
        expectedState: 's',
        timeout: const Duration(milliseconds: 60),
      ),
      throwsA(isA<OAuthLoginTimeout>()),
    );
    await server.close();
  });

  test('unknown paths are rejected', () async {
    final server = await OAuthCallbackServer.tryBind(
      provider: OAuthProvider.claude,
      allowEphemeralFallback: true,
    );
    final future = server!.waitForCode(
      expectedState: 'state-ok',
      timeout: const Duration(seconds: 5),
    );
    await _hit(
      Uri.parse(
        'http://localhost:${server.port}/wrong'
        '?code=code-1&state=state-ok',
      ),
    );
    var completed = false;
    future.whenComplete(() => completed = true);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(completed, isFalse);

    await _hit(
      server.redirectUri.replace(
        queryParameters: <String, String>{
          'code': 'code-3',
          'state': 'state-ok',
        },
      ),
    );
    expect((await future).code, 'code-3');
  });
}
