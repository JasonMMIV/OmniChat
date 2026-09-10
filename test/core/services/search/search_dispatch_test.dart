import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/services/search/search_dispatch.dart';

/// Multi-provider search dispatch engine tests (pure Dart — no bindings
/// beyond the test framework).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const candidates = <SearchDispatchCandidate>[
    SearchDispatchCandidate(id: 'a', name: 'Alpha'),
    SearchDispatchCandidate(id: 'b', name: 'Beta'),
    SearchDispatchCandidate(id: 'c', name: 'Gamma'),
  ];

  group('SearchDispatchModeCodec', () {
    test('maps values both ways and falls back to fallback', () {
      expect(
        SearchDispatchModeCodec.fromValue('fallback'),
        SearchDispatchMode.fallback,
      );
      expect(
        SearchDispatchModeCodec.fromValue('round_robin'),
        SearchDispatchMode.roundRobin,
      );
      expect(
        SearchDispatchModeCodec.fromValue(null),
        SearchDispatchMode.fallback,
      );
      expect(
        SearchDispatchModeCodec.fromValue('bogus'),
        SearchDispatchMode.fallback,
      );
      expect(SearchDispatchMode.fallback.value, 'fallback');
      expect(SearchDispatchMode.roundRobin.value, 'round_robin');
    });
  });

  group('classifySearchFailure', () {
    test('classifies 429 / rate limit / too many requests as rateLimit', () {
      expect(
        classifySearchFailure(Exception('HTTP 429 Too Many Requests')),
        SearchFailureKind.rateLimit,
      );
      expect(
        classifySearchFailure('rate limit exceeded'),
        SearchFailureKind.rateLimit,
      );
      expect(
        classifySearchFailure('RATE_LIMITED'),
        SearchFailureKind.rateLimit,
      );
    });

    test('classifies timeout messages', () {
      expect(
        classifySearchFailure(Exception('request timeout')),
        SearchFailureKind.timeout,
      );
      expect(
        classifySearchFailure('Connection timed out'),
        SearchFailureKind.timeout,
      );
    });

    test('everything else is generic', () {
      expect(
        classifySearchFailure(Exception('500 internal server error')),
        SearchFailureKind.generic,
      );
    });
  });

  group('orderCandidates', () {
    test('fallback keeps the priority order (first = primary)', () {
      final dispatcher = SearchDispatcher();
      final ordered = dispatcher.orderCandidates(
        candidates,
        SearchDispatchMode.fallback,
      );
      expect(ordered.map((c) => c.id).toList(), <String>['a', 'b', 'c']);
    });

    test('round-robin rotates the starting provider after each search', () async {
      final dispatcher = SearchDispatcher();
      expect(
        dispatcher
            .orderCandidates(candidates, SearchDispatchMode.roundRobin)
            .map((c) => c.id)
            .toList(),
        <String>['a', 'b', 'c'],
      );
      await dispatcher.dispatch<String>(
        candidates: candidates,
        mode: SearchDispatchMode.roundRobin,
        attempt: (c) async => 'ok:${c.id}',
      );
      expect(
        dispatcher
            .orderCandidates(candidates, SearchDispatchMode.roundRobin)
            .map((c) => c.id)
            .toList(),
        <String>['b', 'c', 'a'],
      );
      await dispatcher.dispatch<String>(
        candidates: candidates,
        mode: SearchDispatchMode.roundRobin,
        attempt: (c) async => 'ok:${c.id}',
      );
      expect(
        dispatcher
            .orderCandidates(candidates, SearchDispatchMode.roundRobin)
            .map((c) => c.id)
            .toList(),
        <String>['c', 'a', 'b'],
      );
    });

    test('429 cooldown skips the cooling provider until it expires', () async {
      var now = DateTime(2026, 1, 1, 12, 0, 0);
      final dispatcher = SearchDispatcher(
        clock: () => now,
        cooldownDuration: const Duration(seconds: 60),
      );
      var calls = <String>[];
      final first = await dispatcher.dispatch<String>(
        candidates: candidates,
        mode: SearchDispatchMode.fallback,
        attempt: (c) async {
          calls.add(c.id);
          if (c.id == 'a') throw Exception('HTTP 429 rate limit');
          return 'ok:${c.id}';
        },
      );
      expect(first.succeeded, isTrue);
      expect(first.provider?.id, 'b');
      expect(first.fallbackFrom?.id, 'a');
      expect(calls, <String>['a', 'b']);
      expect(dispatcher.isInCooldown('a'), isTrue);

      calls = <String>[];
      final second = await dispatcher.dispatch<String>(
        candidates: candidates,
        mode: SearchDispatchMode.fallback,
        attempt: (c) async {
          calls.add(c.id);
          return 'ok:${c.id}';
        },
      );
      expect(second.provider?.id, 'b');
      expect(calls, <String>['b']);

      now = now.add(const Duration(seconds: 61));
      calls = <String>[];
      final third = await dispatcher.dispatch<String>(
        candidates: candidates,
        mode: SearchDispatchMode.fallback,
        attempt: (c) async {
          calls.add(c.id);
          return 'ok:${c.id}';
        },
      );
      expect(third.provider?.id, 'a');
      expect(calls, <String>['a']);
    });

    test('uses the full order when every candidate is cooling down', () async {
      var now = DateTime(2026, 1, 1, 12, 0, 0);
      final dispatcher = SearchDispatcher(
        clock: () => now,
        cooldownDuration: const Duration(seconds: 60),
      );
      await dispatcher.dispatch<String>(
        candidates: candidates,
        mode: SearchDispatchMode.fallback,
        attempt: (c) async => throw Exception('429 rate limit'),
      );
      expect(candidates.every((c) => dispatcher.isInCooldown(c.id)), isTrue);

      final calls = <String>[];
      final out = await dispatcher.dispatch<String>(
        candidates: candidates,
        mode: SearchDispatchMode.fallback,
        attempt: (c) async {
          calls.add(c.id);
          return 'ok:${c.id}';
        },
      );
      expect(out.succeeded, isTrue);
      expect(calls, <String>['a']);
    });
  });

  group('dispatch', () {
    test('single provider success (legacy behaviour regression)', () async {
      final dispatcher = SearchDispatcher();
      const single = <SearchDispatchCandidate>[
        SearchDispatchCandidate(id: 'a', name: 'Alpha'),
      ];
      final out = await dispatcher.dispatch<String>(
        candidates: single,
        mode: SearchDispatchMode.fallback,
        attempt: (c) async => 'result-from-${c.id}',
      );
      expect(out.succeeded, isTrue);
      expect(out.value, 'result-from-a');
      expect(out.provider?.name, 'Alpha');
      expect(out.fallbackFrom, isNull);
      expect(out.failures, isEmpty);
    });

    test('failure switches to the next provider and records the origin', () async {
      final dispatcher = SearchDispatcher();
      final calls = <String>[];
      final out = await dispatcher.dispatch<String>(
        candidates: candidates,
        mode: SearchDispatchMode.fallback,
        attempt: (c) async {
          calls.add(c.id);
          if (c.id == 'a') throw Exception('boom');
          return 'ok:${c.id}';
        },
      );
      expect(calls, <String>['a', 'b']);
      expect(out.succeeded, isTrue);
      expect(out.value, 'ok:b');
      expect(out.provider?.id, 'b');
      expect(out.fallbackFrom?.id, 'a');
      expect(out.failures.single.candidate.id, 'a');
      expect(out.failures.single.kind, SearchFailureKind.generic);
    });

    test('all providers failing builds the aggregated error JSON', () async {
      final dispatcher = SearchDispatcher();
      final out = await dispatcher.dispatch<String>(
        candidates: candidates,
        mode: SearchDispatchMode.fallback,
        attempt: (c) async {
          if (c.id == 'a') throw Exception('HTTP 429 rate limit');
          if (c.id == 'b') throw Exception('request timeout');
          throw Exception('server exploded');
        },
      );
      expect(out.succeeded, isFalse);
      expect(out.failures.length, 3);

      final decoded =
          jsonDecode(SearchDispatcher.buildAggregateErrorJson(out.failures))
              as Map<String, dynamic>;
      expect(decoded['error'], isA<String>());
      expect(decoded['error'], contains('Alpha'));
      expect(decoded['error'], contains('Beta'));
      expect(decoded['error'], contains('Gamma'));

      final attempts = decoded['attempts'] as List;
      expect(attempts.length, 3);
      expect((attempts[0] as Map)['provider'], 'Alpha');
      expect((attempts[0] as Map)['type'], 'rate_limit');
      expect((attempts[1] as Map)['provider'], 'Beta');
      expect((attempts[1] as Map)['type'], 'timeout');
      expect((attempts[2] as Map)['provider'], 'Gamma');
      expect((attempts[2] as Map).containsKey('type'), isFalse);
    });

    test('empty candidate set yields an empty outcome and error JSON', () async {
      final dispatcher = SearchDispatcher();
      final out = await dispatcher.dispatch<String>(
        candidates: const <SearchDispatchCandidate>[],
        mode: SearchDispatchMode.fallback,
        attempt: (c) async => 'never',
      );
      expect(out.succeeded, isFalse);
      expect(out.failures, isEmpty);
      final decoded =
          jsonDecode(SearchDispatcher.buildAggregateErrorJson(out.failures))
              as Map<String, dynamic>;
      expect(decoded['error'], 'No search services configured');
    });
  });
}
