// Claude adapter parsing contract: the four paste shapes, state validation,
// and both usage payload generations (plan §8).

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/services/auth/claude_oauth_adapter.dart';
import 'package:OmniChat/core/services/auth/oauth_errors.dart';
import 'package:OmniChat/core/services/auth/provider_oauth_adapter.dart';

void main() {
  group('parseClaudeManualCode', () {
    const state = 'state-abc';

    test('accepts a raw code', () {
      expect(parseClaudeManualCode('abc123', expectedState: state), 'abc123');
    });

    test('accepts code=...&state=...', () {
      expect(
        parseClaudeManualCode(
          'code=abc123&state=state-abc',
          expectedState: state,
        ),
        'abc123',
      );
    });

    test('accepts code#state', () {
      expect(
        parseClaudeManualCode('abc123#state-abc', expectedState: state),
        'abc123',
      );
    });

    test('accepts the full callback URL', () {
      expect(
        parseClaudeManualCode(
          'http://localhost:54545/callback?code=abc123&state=state-abc',
          expectedState: state,
        ),
        'abc123',
      );
    });

    test('rejects a mismatched state', () {
      expect(
        () => parseClaudeManualCode(
          'http://localhost:54545/callback?code=abc123&state=other',
          expectedState: state,
        ),
        throwsA(isA<OAuthException>()),
      );
      expect(
        () => parseClaudeManualCode('abc123#other', expectedState: state),
        throwsA(isA<OAuthException>()),
      );
    });

    test('rejects empty and whitespace-containing codes', () {
      expect(
        () => parseClaudeManualCode('   ', expectedState: state),
        throwsA(isA<OAuthException>()),
      );
      expect(
        () => parseClaudeManualCode('abc 123', expectedState: state),
        throwsA(isA<OAuthException>()),
      );
    });
  });

  group('parseClaudeUsage', () {
    final fetchedAt = DateTime.utc(2026, 11, 1);

    test('new limits[] + spend shape', () {
      final usage = parseClaudeUsage(<String, dynamic>{
        'plan_type': 'max',
        'limits': <Map<String, dynamic>>[
          <String, dynamic>{
            'kind': 'session',
            'percent': 42,
            'resets_at': '2026-11-01T10:00:00Z',
          },
          <String, dynamic>{
            'kind': 'weekly_scoped',
            'percent': 91,
            'scope': <String, dynamic>{
              'model': <String, dynamic>{'display_name': 'Opus'},
            },
          },
        ],
        'spend': <String, dynamic>{'amount': 3.5, 'currency': 'USD'},
      }, fetchedAt: fetchedAt);

      expect(usage.windows.length, 2);
      expect(usage.windows.first.kind, 'session');
      expect(usage.windows.first.percent, 42);
      expect(usage.windows.first.resetsAt, DateTime.utc(2026, 11, 1, 10));
      expect(usage.windows.last.label, 'Opus');
      expect(usage.windows.last.isWarning, isTrue);
      expect(usage.planType, 'max');
      expect(usage.extraSpentUsd, 3.5);
      expect(usage.extraCurrency, 'USD');
    });

    test('legacy five_hour / seven_day_* shape', () {
      final usage = parseClaudeUsage(<String, dynamic>{
        'five_hour': <String, dynamic>{'utilization': 12.5},
        'seven_day': <String, dynamic>{'utilization': 80},
        'seven_day_opus': <String, dynamic>{'utilization': 99},
        'seven_day_sonnet': <String, dynamic>{'utilization': 60},
        'extra_usage': <String, dynamic>{'spent_usd': 1.25},
      }, fetchedAt: fetchedAt);
      expect(usage.windows.map((w) => w.kind).toList(), <String>[
        'session',
        'weekly',
        'weekly_scoped',
        'weekly_scoped',
      ]);
      expect(usage.windows[2].label, 'Opus');
      expect(usage.windows[2].isWarning, isTrue);
      expect(usage.extraSpentUsd, 1.25);
    });

    test('empty payload yields no windows', () {
      final usage = parseClaudeUsage(
        const <String, dynamic>{},
        fetchedAt: fetchedAt,
      );
      expect(usage.isEmpty, isTrue);
    });
  });

  group('parseCodexUsage', () {
    test('parses primary and secondary windows', () {
      final usage = parseCodexUsage(<String, dynamic>{
        'plan_type': 'plus',
        'rate_limit': <String, dynamic>{
          'primary_window': <String, dynamic>{
            'used_percent': 25,
            'reset_at': 1790000000,
          },
          'secondary_window': <String, dynamic>{
            'used_percent': 95,
            'reset_at': '2026-11-02T00:00:00Z',
          },
        },
      }, fetchedAt: DateTime.utc(2026, 11, 1));
      expect(usage.planType, 'plus');
      expect(usage.windows.length, 2);
      expect(usage.windows.first.kind, 'session');
      expect(usage.windows.first.percent, 25);
      expect(usage.windows.first.resetsAt, isNotNull);
      expect(usage.windows.last.kind, 'weekly');
      expect(usage.windows.last.isWarning, isTrue);
    });
  });
}
