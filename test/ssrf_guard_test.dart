import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/core/services/web/ssrf_guard.dart';

Future<List<InternetAddress>> Function(String host) _lookup(
  Map<String, List<InternetAddress>> table,
) {
  return (host) async => table[host] ?? <InternetAddress>[];
}

void main() {
  group('IPv4 ranges', () {
    for (final address in <String>[
      '0.0.0.0',
      '10.1.2.3',
      '100.64.0.1',
      '127.0.0.1',
      '169.254.169.254',
      '172.16.0.1',
      '172.31.255.255',
      '192.0.0.1',
      '192.0.2.10',
      '192.88.99.1',
      '192.168.1.1',
      '198.18.0.1',
      '198.51.100.7',
      '203.0.113.9',
      '224.0.0.1',
      '240.0.0.1',
      '255.255.255.255',
    ]) {
      test('blocks $address', () {
        expect(
          SsrfGuard.isBlocked(InternetAddress(address)),
          isTrue,
          reason: address,
        );
      });
    }

    test('allows public addresses', () {
      expect(SsrfGuard.isBlocked(InternetAddress('8.8.8.8')), isFalse);
      expect(SsrfGuard.isBlocked(InternetAddress('1.1.1.1')), isFalse);
      expect(SsrfGuard.isBlocked(InternetAddress('93.184.216.34')), isFalse);
    });
  });

  group('IPv6 ranges', () {
    for (final address in <String>[
      '::',
      '::1',
      '64:ff9b::1',
      '100::1',
      '2001:db8::1',
      'fc00::1',
      'fd12:3456::1',
      'fe80::1',
      'ff02::1',
    ]) {
      test('blocks $address', () {
        expect(
          SsrfGuard.isBlocked(InternetAddress(address)),
          isTrue,
          reason: address,
        );
      });
    }

    test('blocks IPv4-mapped loopback', () {
      expect(
        SsrfGuard.isBlocked(InternetAddress('::ffff:127.0.0.1')),
        isTrue,
      );
      expect(
        SsrfGuard.isBlocked(InternetAddress('::ffff:10.0.0.1')),
        isTrue,
      );
    });

    test('allows a public IPv6 address', () {
      expect(
        SsrfGuard.isBlocked(InternetAddress('2001:4860:4860::8888')),
        isFalse,
      );
    });
  });

  group('IPv4 shorthand literals', () {
    test('127.1 is loopback', () {
      expect(SsrfGuard.isBlockedHostLiteral('127.1'), isTrue);
    });

    test('2130706433 is 127.0.0.1', () {
      expect(SsrfGuard.isBlockedHostLiteral('2130706433'), isTrue);
    });

    test('0x7f000001 is loopback', () {
      expect(SsrfGuard.isBlockedHostLiteral('0x7f000001'), isTrue);
    });

    test('10.1 is 10.0.0.1', () {
      expect(SsrfGuard.isBlockedHostLiteral('10.1'), isTrue);
    });

    test('hostnames are not treated as literals', () {
      expect(SsrfGuard.isBlockedHostLiteral('example.com'), isNull);
      expect(SsrfGuard.isBlockedHostLiteral('localhost'), isNull);
    });
  });

  group('check()', () {
    test('rejects a hostname when any resolved address is private', () async {
      final guard = SsrfGuard(
        lookup: _lookup({
          'mixed.example': <InternetAddress>[
            InternetAddress('93.184.216.34'),
            InternetAddress('192.168.0.10'),
          ],
        }),
      );
      final block = await guard.check(Uri.parse('https://mixed.example/a'));
      expect(block, isNotNull);
      expect(block!.address, '192.168.0.10');
    });

    test('allows a public hostname', () async {
      final guard = SsrfGuard(
        lookup: _lookup({
          'public.example': <InternetAddress>[
            InternetAddress('93.184.216.34'),
          ],
        }),
      );
      expect(
        await guard.check(Uri.parse('https://public.example/a')),
        isNull,
      );
    });

    test('literal loopback is refused without a lookup', () async {
      var lookedUp = false;
      final guard = SsrfGuard(
        lookup: (host) async {
          lookedUp = true;
          return <InternetAddress>[];
        },
      );
      final block = await guard.check(
        Uri.parse('http://127.0.0.1:11434/api/tags'),
      );
      expect(block, isNotNull);
      expect(lookedUp, isFalse);
    });

    test('DNS failure is allowed through to the network layer', () async {
      final guard = SsrfGuard(
        lookup: (host) async => throw const SocketException('no dns'),
      );
      expect(
        await guard.check(Uri.parse('https://does-not-resolve.example')),
        isNull,
      );
    });

    test('allowPrivateHosts disables every check', () async {
      final guard = SsrfGuard(allowPrivateHosts: true);
      expect(
        await guard.check(Uri.parse('http://127.0.0.1:8080/')),
        isNull,
      );
      expect(
        await guard.check(Uri.parse('http://192.168.1.1/')),
        isNull,
      );
    });
  });
}
