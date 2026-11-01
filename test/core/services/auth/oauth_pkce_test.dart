// PKCE primitives for the provider OAuth login flow (plan §8).

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/services/auth/oauth_pkce.dart';

void main() {
  test('verifier uses the unreserved character set and requested length', () {
    for (final length in const [43, 64, 128]) {
      final verifier = oauthRandomString(length);
      expect(verifier.length, length);
      expect(RegExp(r'^[A-Za-z0-9\-._~]+$').hasMatch(verifier), isTrue);
    }
  });

  test('verifiers are random', () {
    final values = <String>{for (var i = 0; i < 32; i++) oauthRandomString(64)};
    expect(values.length, 32);
  });

  test('S256 challenge matches the RFC 7636 reference vector', () {
    // RFC 7636 Appendix B.
    expect(
      oauthPkceChallenge('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'),
      'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
    );
  });

  test('state values are URL-safe and unique', () {
    final a = oauthState();
    final b = oauthState();
    expect(a, isNot(b));
    expect(a.length, 32);
    expect(Uri.encodeQueryComponent(a), a);
  });

  test('uuid v4 is shaped correctly and random', () {
    final ids = <String>{for (var i = 0; i < 20; i++) oauthUuidV4()};
    expect(ids.length, 20);
    for (final id in ids) {
      expect(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ).hasMatch(id),
        isTrue,
        reason: id,
      );
    }
  });

  test('stable uuid is deterministic for the same seed', () {
    expect(
      oauthStableUuid('provider:model'),
      oauthStableUuid('provider:model'),
    );
    expect(
      oauthStableUuid('provider:model'),
      isNot(oauthStableUuid('provider:other')),
    );
  });
}
