// M5.5 native half: the method-channel payload is exact, a wrong callback
// origin is rejected, and cancellation carries the same session id.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/models/provider_oauth.dart';
import 'package:OmniChat/core/services/auth/oauth_errors.dart';
import 'package:OmniChat/core/services/auth/oauth_mobile_browser.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('authenticate sends the native session contract', () async {
    const channel = MethodChannel('test.oauth.authenticate');
    MethodCall? seen;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          seen = call;
          return 'com.psyche.omnichat://oauth-callback/authorize?state=s1';
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    final browser = OAuthMobileBrowser(
      provider: OAuthProvider.claude,
      channel: channel,
      sessionId: 'session-1',
    );
    final callback = await browser.authenticate(
      authorizationUrl: Uri.parse('https://auth.example/authorize?state=s1'),
      timeout: const Duration(seconds: 5),
    );

    expect(callback.queryParameters['state'], 's1');
    expect(seen?.method, 'authenticate');
    final args = seen!.arguments as Map<Object?, Object?>;
    expect(args['url'], 'https://auth.example/authorize?state=s1');
    expect(
      args['redirectUri'],
      'com.psyche.omnichat://oauth-callback/authorize',
    );
    expect(args['completionOnly'], isTrue);
    expect(args['sessionId'], 'session-1');
  });

  test('cancel carries the same session id', () async {
    const channel = MethodChannel('test.oauth.cancel');
    MethodCall? seen;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          seen = call;
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    final browser = OAuthMobileBrowser(
      provider: OAuthProvider.grok,
      channel: channel,
      sessionId: 'session-2',
    );
    await browser.cancel();
    expect(seen?.method, 'cancel');
    expect(
      (seen!.arguments as Map<Object?, Object?>)['sessionId'],
      'session-2',
    );
  });  test('a native timeout stays an OAuth timeout', () async {
    const channel = MethodChannel('test.oauth.timeout');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          // Never completes: the Dart-side deadline owns the outcome.
          return Completer<String>().future;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    final browser = OAuthMobileBrowser(
      provider: OAuthProvider.claude,
      channel: channel,
    );
    await expectLater(
      browser.authenticate(
        authorizationUrl: Uri.parse('https://auth.example/authorize?state=s1'),
        timeout: const Duration(milliseconds: 20),
      ),
      throwsA(isA<OAuthLoginTimeout>()),
    );
  });

  test('a request completed outside the native window is never accepted', () async {
      const channel = MethodChannel('test.oauth.invalid');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            return 'https://evil.example/callback?state=s1';
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      final browser = OAuthMobileBrowser(
        provider: OAuthProvider.claude,
        channel: channel,
      );
      await expectLater(
        browser.authenticate(
          authorizationUrl: Uri.parse(
            'https://auth.example/authorize?state=s1',
          ),
          timeout: const Duration(seconds: 5),
        ),
        throwsA(isA<Exception>()),
      );
    },
  );
}
