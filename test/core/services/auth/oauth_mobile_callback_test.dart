// M5.5 loopback half: the code stays local, the deep link carries only state,
// and the launcher waits for the native completion signal. This file must not
// initialize TestWidgetsFlutterBinding: that installs a mock HttpClient which
// turns every loopback request into a 400.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/models/provider_oauth.dart';
import 'package:OmniChat/core/services/auth/oauth_callback.dart';
import 'package:OmniChat/core/services/auth/oauth_mobile_browser.dart';

Future<void> _hit(Uri uri, {required bool followRedirects}) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(uri);
    request.followRedirects = followRedirects;
    final response = await request.close();
    await response.drain<void>();
  } finally {
    client.close(force: true);
  }
}

class _FakeMobile extends OAuthMobileBrowser {
  _FakeMobile()
    : super(
        provider: OAuthProvider.claude,
        sessionId: 'session-3',
        callbackUri: Uri.parse(
          'com.psyche.omnichat://oauth-callback/authorize',
        ),
      );

  final Completer<Uri> native = Completer<Uri>();
  int cancels = 0;

  @override
  Future<Uri> authenticate({
    required Uri authorizationUrl,
    required Duration timeout,
  }) => native.future;

  @override
  Future<void> cancel() async {
    cancels += 1;
  }
}

void main() {
  test('the loopback response redirects with state only', () async {
    final server = await OAuthCallbackServer.tryBind(
      provider: OAuthProvider.claude,
      allowEphemeralFallback: true,
    );
    final mobileCallback = Uri.parse(
      'com.psyche.omnichat://oauth-callback/authorize',
    );
    final future = server!.waitForCode(
      expectedState: 'state-1',
      timeout: const Duration(seconds: 5),
      mobileCallback: () => mobileCallback,
    );

    final client = HttpClient();
    final request = await client.getUrl(
      server.redirectUri.replace(
        queryParameters: <String, String>{
          'code': 'secret-code',
          'state': 'state-1',
        },
      ),
    );
    request.followRedirects = false;
    final response = await request.close();
    final location = response.headers.value(HttpHeaders.locationHeader);
    expect(response.statusCode, HttpStatus.found);
    expect(location, isNotNull);
    expect(location, contains('state=state-1'));
    expect(location, isNot(contains('secret-code')));
    await response.drain<void>();
    client.close(force: true);

    expect((await future).code, 'secret-code');
    await server.close();
  });

  test(
    'launcher waits for the loopback code and the native completion',
    () async {
      final server = await OAuthCallbackServer.tryBind(
        provider: OAuthProvider.claude,
        allowEphemeralFallback: true,
      );
      final browser = _FakeMobile();
      final launcher = OAuthBrowserLauncher(
        provider: OAuthProvider.claude,
        mobile: browser,
      );
      var externalBrowserOpened = false;
      final resultFuture = launcher.waitForCallback(
        server: server!,
        authorizationUrl: Uri.parse('https://auth.example/authorize?state=s3'),
        expectedState: 's3',
        cancelSignal: Completer<void>().future,
        launchBrowser: (_) async {
          externalBrowserOpened = true;
          return true;
        },
        timeout: const Duration(seconds: 5),
      );

      await _hit(
        server.redirectUri.replace(
          queryParameters: <String, String>{'code': 'code-3', 'state': 's3'},
        ),
        followRedirects: false,
      );
      browser.native.complete(
        Uri.parse('com.psyche.omnichat://oauth-callback/authorize?state=s3'),
      );

      final result = await resultFuture;
      expect(result.code, 'code-3');
      expect(externalBrowserOpened, isFalse);
      expect(browser.cancels, greaterThan(0));
      await server.close();
    },
  );
}
