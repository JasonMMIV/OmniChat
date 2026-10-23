// Web fetch SSRF guard (WEB_FETCH_PLAN.md §5.3).
//
// Pure Dart (dart:io only) so it can be unit-tested without Flutter bindings.
//
// Best-effort under a proxy: when the request goes through `DioHttpClient`
// the DNS resolution happens at the proxy, so hostname checks only cover the
// device's own resolver. IP-literal checks always apply and always work.
// Every redirect hop is checked again by FetchCore.

import 'dart:io';
import 'dart:typed_data';

/// One refused address (or host) with a human-readable reason.
class SsrfBlock {
  const SsrfBlock({required this.host, required this.address});

  /// The host exactly as it appeared in the URL.
  final String host;

  /// The offending address (null when the host literal itself was refused).
  final String? address;

  String get reason => address == null
      ? 'The host "$host" points to a private or reserved address.'
      : 'The host "$host" resolves to a private or reserved address '
            '($address).';
}

/// Refuses requests to loopback / private / link-local / reserved addresses.
///
/// `allowPrivateHosts == true` disables every check (the user opted in from
/// settings and understands what it means).
class SsrfGuard {
  SsrfGuard({
    this.allowPrivateHosts = false,
    Future<List<InternetAddress>> Function(String host)? lookup,
  }) : _lookup = lookup ?? InternetAddress.lookup;

  final bool allowPrivateHosts;
  final Future<List<InternetAddress>> Function(String host) _lookup;

  /// Returns null when [uri] may be fetched, otherwise the block reason.
  ///
  /// Resolution failures are intentionally allowed through: the connection
  /// itself will fail with a network error (same contract as
  /// mcp-server-fetch).
  Future<SsrfBlock?> check(Uri uri) async {
    if (allowPrivateHosts) return null;

    final host = uri.host;
    if (host.isEmpty) return null;

    final literal = parseIpLiteral(host);
    if (literal != null) {
      if (isBlocked(literal)) {
        return SsrfBlock(host: host, address: literal.address);
      }
      return null;
    }

    final List<InternetAddress> addresses;
    try {
      addresses = await _lookup(host);
    } on SocketException {
      return null;
    } on ArgumentError {
      return null;
    }
    for (final address in addresses) {
      if (isBlocked(address)) {
        return SsrfBlock(host: host, address: address.address);
      }
    }
    return null;
  }

  /// True when [address] falls inside a blocked IPv4 / IPv6 range.
  static bool isBlocked(InternetAddress address) {
    final bytes = address.rawAddress;
    if (bytes.length == 4) return isBlockedIpv4Bytes(bytes);
    if (bytes.length == 16) {
      // IPv4-mapped (::ffff:0:0/96) is judged as its IPv4 target.
      final mapped = _mappedIpv4(bytes);
      if (mapped != null) return isBlockedIpv4Bytes(mapped);
      return isBlockedIpv6Bytes(bytes);
    }
    return false;
  }

  /// Convenience for tests: parses an IP literal (including the shorthand
  /// forms `127.1`, `2130706433`, `0x7f000001`) and reports whether it is
  /// blocked. Returns null when [host] is not an IP literal at all.
  static bool? isBlockedHostLiteral(String host) {
    final literal = parseIpLiteral(host);
    if (literal == null) return null;
    return isBlocked(literal);
  }

  /// Parses an IP literal the way a browser / libc resolver would, so
  /// shorthand forms cannot slip past a dotted-quad check.
  ///
  /// Supported: dotted decimal (1–4 parts, last part may span the remaining
  /// bytes), a single 32-bit decimal (`2130706433`), hex (`0x7f000001`), and
  /// IPv6 (including IPv4-mapped). Returns null for hostnames.
  static InternetAddress? parseIpLiteral(String host) {
    var value = host.trim();
    if (value.isEmpty) return null;
    if (value.startsWith('[') && value.endsWith(']')) {
      value = value.substring(1, value.length - 1);
    }

    final direct = InternetAddress.tryParse(value);
    if (direct != null) return direct;

    // IPv4 shorthand forms.
    final ipv4 = _parseIpv4Shorthand(value);
    if (ipv4 != null) return InternetAddress.fromRawAddress(ipv4);
    return null;
  }

  static const List<List<int>> _blockedIpv4 = <List<int>>[
    <int>[0, 0, 0, 0, 8], // 0.0.0.0/8
    <int>[10, 0, 0, 0, 8], // 10.0.0.0/8
    <int>[100, 64, 0, 0, 10], // 100.64.0.0/10
    <int>[127, 0, 0, 0, 8], // 127.0.0.0/8
    <int>[169, 254, 0, 0, 16], // 169.254.0.0/16
    <int>[172, 16, 0, 0, 12], // 172.16.0.0/12
    <int>[192, 0, 0, 0, 24], // 192.0.0.0/24
    <int>[192, 0, 2, 0, 24], // 192.0.2.0/24
    <int>[192, 88, 99, 0, 24], // 192.88.99.0/24
    <int>[192, 168, 0, 0, 16], // 192.168.0.0/16
    <int>[198, 18, 0, 0, 15], // 198.18.0.0/15
    <int>[198, 51, 100, 0, 24], // 198.51.100.0/24
    <int>[203, 0, 113, 0, 24], // 203.0.113.0/24
    <int>[224, 0, 0, 0, 4], // 224.0.0.0/4
    <int>[240, 0, 0, 0, 4], // 240.0.0.0/4
    <int>[255, 255, 255, 255, 32], // 255.255.255.255/32
  ];

  /// Blocked IPv6 ranges as (network bytes, prefix length).
  static final List<(List<int>, int)> _blockedIpv6 = <(List<int>, int)>[
    (_ipv6Bytes(const <int>[]), 128), // ::/128
    (_ipv6Bytes(const <int>[
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
    ]), 128), // ::1/128
    (_ipv6Bytes(const <int>[0x00, 0x64, 0xff, 0x9b]), 96), // 64:ff9b::/96
    (_ipv6Bytes(const <int>[0x01, 0x00]), 64), // 100::/64
    (_ipv6Bytes(const <int>[0x20, 0x01, 0x0d, 0xb8]), 32), // 2001:db8::/32
    (_ipv6Bytes(const <int>[0xfc, 0x00]), 7), // fc00::/7
    (_ipv6Bytes(const <int>[0xfe, 0x80]), 10), // fe80::/10
    (_ipv6Bytes(const <int>[0xff, 0x00]), 8), // ff00::/8
  ];

  static bool isBlockedIpv4Bytes(List<int> bytes) {
    for (final range in _blockedIpv4) {
      if (_matchBytes(bytes, range.sublist(0, 4), range[4])) return true;
    }
    return false;
  }

  static bool isBlockedIpv6Bytes(List<int> bytes) {
    for (final range in _blockedIpv6) {
      if (_matchBytes(bytes, range.$1, range.$2)) return true;
    }
    return false;
  }

  static bool _matchBytes(List<int> bytes, List<int> network, int prefix) {
    final fullBytes = prefix ~/ 8;
    for (var i = 0; i < fullBytes && i < bytes.length; i++) {
      if (bytes[i] != network[i]) return false;
    }
    final remainder = prefix % 8;
    if (remainder == 0) return true;
    if (fullBytes >= bytes.length) return true;
    final mask = 0xFF << (8 - remainder) & 0xFF;
    return (bytes[fullBytes] & mask) == (network[fullBytes] & mask);
  }

  /// Returns the IPv4 bytes of an IPv4-mapped IPv6 address, or null.
  static List<int>? _mappedIpv4(List<int> bytes) {
    for (var i = 0; i < 10; i++) {
      if (bytes[i] != 0) return null;
    }
    if (bytes[10] != 0xFF || bytes[11] != 0xFF) return null;
    return bytes.sublist(12);
  }

  static List<int> _ipv6Bytes(List<int> leading) {
    final out = List<int>.filled(16, 0);
    final source = leading.length > 16 ? leading.sublist(0, 16) : leading;
    for (var i = 0; i < source.length; i++) {
      out[i] = source[i];
    }
    return out;
  }

  /// inet_aton-compatible parsing for IPv4 shorthands.
  static Uint8List? _parseIpv4Shorthand(String value) {
    final parts = value.split('.');
    if (parts.length > 4) return null;

    final numbers = <int>[];
    for (final raw in parts) {
      final part = raw.trim();
      if (part.isEmpty) return null;
      int? parsed;
      if (part.startsWith('0x') || part.startsWith('0X')) {
        parsed = int.tryParse(part.substring(2), radix: 16);
      } else if (part.length > 1 && part.startsWith('0')) {
        parsed = int.tryParse(part.substring(1), radix: 8);
      } else {
        parsed = int.tryParse(part, radix: 10);
      }
      if (parsed == null || parsed < 0) return null;
      numbers.add(parsed);
    }

    // Every part except the last must fit in one byte; the last part may
    // occupy all the remaining bytes.
    for (var i = 0; i < numbers.length - 1; i++) {
      if (numbers[i] > 0xFF) return null;
    }
    final remainingBytes = 5 - numbers.length;
    final maxLast = remainingBytes >= 4
        ? 0xFFFFFFFF
        : (1 << (8 * remainingBytes)) - 1;
    if (numbers.last > maxLast) return null;

    var value32 = numbers.last;
    for (var i = 0; i < numbers.length - 1; i++) {
      value32 += numbers[i] << (8 * (3 - i));
    }
    return Uint8List.fromList(<int>[
      (value32 >> 24) & 0xFF,
      (value32 >> 16) & 0xFF,
      (value32 >> 8) & 0xFF,
      value32 & 0xFF,
    ]);
  }
}
