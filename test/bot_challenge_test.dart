import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/core/services/web/bot_challenge.dart';

void main() {
  group('provider markers', () {
    test('detects AWS WAF', () {
      final challenge = BotChallengeDetector.detect(
        '<html><script>window.gokuProps = {};</script></html>',
        status: 202,
      );
      expect(challenge?.kind, BotChallengeKind.awsWaf);
      expect(challenge?.marker, 'gokuprops');
    });

    test('detects Cloudflare Turnstile on a 403 page', () {
      final challenge = BotChallengeDetector.detect(
        '<html><script src="https://challenges.cloudflare.com/turnstile/v0/api.js"></script>'
        '<p>Verify you are human</p></html>',
        status: 403,
      );
      expect(challenge?.kind, BotChallengeKind.cloudflare);
    });

    test('detects a Cloudflare interstitial without a Turnstile URL', () {
      final challenge = BotChallengeDetector.detect(
        '<html><head><title>Just a moment...</title>'
        '<meta http-equiv="content-security-policy" '
        'content="default-src none; script-src self '
        'https://challenges.cloudflare.com">'
        '</head><body></body></html>',
        status: 403,
      );
      expect(challenge?.kind, BotChallengeKind.cloudflare);
      expect(challenge?.marker, 'challenges.cloudflare.com');
    });

    test('detects hashcash', () {
      final challenge = BotChallengeDetector.detect(
        '<html><title>Checking your browser...</title>'
        '<script src="/__challenge/probes.js"></script></html>',
        status: 403,
      );
      expect(challenge?.kind, BotChallengeKind.hashcash);
    });

    test('detects Reddit JS challenge', () {
      final challenge = BotChallengeDetector.detect(
        '<html><form id="js_challenge"><input name="jsc_token"></form></html>',
        status: 200,
      );
      expect(challenge?.kind, BotChallengeKind.reddit);
      expect(challenge?.marker, 'jsc_token');
    });

    test('detects DataDome, PerimeterX, Imperva and Akamai', () {
      final cases = <String, BotChallengeKind>{
        '<script src="https://geo.captcha-delivery.com/captcha/"></script>':
            BotChallengeKind.dataDome,
        '<script src="https://captcha.px-cdn.net/px-captcha.js"></script>':
            BotChallengeKind.perimeterX,
        '<p>Request unsuccessful. Incapsula incident ID: 123</p>':
            BotChallengeKind.imperva,
        '<script>window._abck = "x"; bm-verify</script>':
            BotChallengeKind.akamai,
      };
      for (final entry in cases.entries) {
        expect(
          BotChallengeDetector.detect(entry.key, status: 403)?.kind,
          entry.value,
        );
      }
    });
  });

  group('false positives', () {
    test('normal article mentioning Cloudflare and captcha is not a challenge', () {
      final challenge = BotChallengeDetector.detect(
        '<html><body><article><p>'
        '${'Cloudflare Turnstile and captcha are discussed here. ' * 20}'
        '</p></article></body></html>',
        status: 200,
      );
      expect(challenge, isNull);
    });

    test('generic 403 page is not a challenge', () {
      final challenge = BotChallengeDetector.detect(
        '<html><body><h1>Forbidden</h1><p>Access denied.</p></body></html>',
        status: 403,
      );
      expect(challenge, isNull);
    });

    test('generic phrases only trigger on challenge statuses', () {
      final html =
          '<html><body>Checking your browser... Verify you are human.</body></html>';
      expect(BotChallengeDetector.detect(html, status: 200), isNull);
      expect(
        BotChallengeDetector.detect(html, status: 403)?.kind,
        BotChallengeKind.generic,
      );
      expect(
        BotChallengeDetector.detect(html, status: 403)?.provider,
        'bot-verification',
      );
    });

    test('Cloudflare script on a normal 200 page is not a challenge', () {
      final challenge = BotChallengeDetector.detect(
        '<html><body>'
        '<script src="https://challenges.cloudflare.com/turnstile/v0/api.js"></script>'
        '<p>Just a moment while the form loads.</p>'
        '<article><p>${'Normal article body. ' * 30}</p></article></body></html>',
        status: 200,
      );
      expect(challenge, isNull);
    });

    test('AWS WAF token script on a passing 200 page is not a challenge', () {
      final challenge = BotChallengeDetector.detect(
        '<html><body><script src="https://token.awswaf.com/token.js"></script>'
        '<article><p>${'Normal article body. ' * 30}</p></article></body></html>',
        status: 200,
      );
      expect(challenge, isNull);
    });

    test('a 200 page quoting js_challenge without Reddit markers is not a challenge', () {
      final challenge = BotChallengeDetector.detect(
        '<html><body><article><p>Example: '
        '&lt;form id="js_challenge"&gt; is Reddit-specific.</p>'
        '</article></body></html>',
        status: 200,
      );
      expect(challenge, isNull);
    });

    test('Akamai cookie and noscript copy on a 200 page are not a challenge', () {
      final challenge = BotChallengeDetector.detect(
        '<html><body><script>window._abck = "x";</script>'
        '<noscript>JavaScript required</noscript>'
        '<article><p>${'Normal article body. ' * 30}</p></article></body></html>',
        status: 200,
      );
      expect(challenge, isNull);
    });
  });

  test('scans the full document, not only the head', () {
    final html = '${'x' * 120000}<script>window.jsc_token = "x";</script>';
    expect(
      BotChallengeDetector.detect(html, status: 200)?.kind,
      BotChallengeKind.reddit,
    );
  });
}
