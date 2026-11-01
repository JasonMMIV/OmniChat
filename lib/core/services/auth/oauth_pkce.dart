// Ported from Chevey339/kelivo@05eef503b6e7cda14de897373b79bab7bebe35b9
// (`lib/core/services/auth/oauth_callback_io.dart` PKCE helpers, AGPL-3.0),
// modified for OmniChat on 2026-11-01. See THIRD_PARTY_NOTICES.md.

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

final Random _secureRandom = Random.secure();

/// Base64-url alphabet without padding — the PKCE / `state` character set.
const String _unreserved =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';

/// Cryptographically-random PKCE verifier (RFC 7636: 43–128 characters).
String oauthRandomString([int length = 64]) {
  final buffer = StringBuffer();
  for (var i = 0; i < length; i++) {
    buffer.write(_unreserved[_secureRandom.nextInt(_unreserved.length)]);
  }
  return buffer.toString();
}

/// `BASE64URL(SHA256(ASCII(verifier)))` — S256 challenge.
String oauthPkceChallenge(String verifier) {
  final digest = sha256.convert(ascii.encode(verifier));
  return base64Url.encode(digest.bytes).replaceAll('=', '');
}

/// Opaque CSRF token for the authorization round-trip.
String oauthState() => oauthRandomString(32);

/// RFC 4122 version-4 UUID drawn from [Random.secure] (no dependency needed for
/// the handful of ids the OAuth layer mints: session ids and device ids).
String oauthUuidV4() {
  final bytes = List<int>.generate(16, (_) => _secureRandom.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  String hex(int v) => v.toRadixString(16).padLeft(2, '0');
  final b = bytes.map(hex).join();
  return '${b.substring(0, 8)}-${b.substring(8, 12)}-${b.substring(12, 16)}-'
      '${b.substring(16, 20)}-${b.substring(20)}';
}

/// Deterministic UUID-shaped id for callers without a conversation id (utility
/// calls such as title generation). Stability matters more than uniqueness
/// here: the provider uses it to attribute a conversation, and a random value
/// per request would defeat prompt-cache prefixes (plan C15).
String oauthStableUuid(String seed) {
  final digest = sha1.convert(utf8.encode(seed)).bytes;
  final bytes = List<int>.from(digest.take(16));
  bytes[6] = (bytes[6] & 0x0f) | 0x50; // version 5 shape
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  String hex(int v) => v.toRadixString(16).padLeft(2, '0');
  final b = bytes.map(hex).join();
  return '${b.substring(0, 8)}-${b.substring(8, 12)}-${b.substring(12, 16)}-'
      '${b.substring(16, 20)}-${b.substring(20)}';
}
