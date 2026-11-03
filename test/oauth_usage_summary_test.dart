import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/core/models/provider_oauth.dart';

OAuthUsageWindow _window(String kind, double percent, {String? label}) =>
    OAuthUsageWindow(kind: kind, percent: percent, label: label);

void main() {
  group('OAuthUsage.summaryWindow', () {
    test('is null when the provider reported no window', () {
      expect(
        const OAuthUsage(windows: <OAuthUsageWindow>[]).summaryWindow,
        isNull,
      );
    });

    test('prefers the monthly window over session and weekly', () {
      final usage = OAuthUsage(
        windows: <OAuthUsageWindow>[
          _window('session', 92),
          _window('weekly', 61),
          _window('monthly', 12),
        ],
      );
      final summary = usage.summaryWindow;
      expect(summary?.kind, 'monthly');
      expect(summary?.percent, 12);
    });

    test('falls back to the weekly window when no monthly exists', () {
      final usage = OAuthUsage(
        windows: <OAuthUsageWindow>[
          _window('session', 88),
          _window('seven_day', 30),
        ],
      );
      expect(usage.summaryWindow?.kind, 'seven_day');
    });

    test('prefers the Kimi total quota over the weekly window', () {
      final usage = OAuthUsage(
        windows: <OAuthUsageWindow>[
          _window('weekly', 40),
          _window('total', 5),
        ],
      );
      expect(usage.summaryWindow?.kind, 'total');
    });

    test('picks the highest percent inside one tier', () {
      final usage = OAuthUsage(
        windows: <OAuthUsageWindow>[
          _window('weekly', 20),
          _window('seven_day', 44),
          _window('weekly_all', 31),
        ],
      );
      expect(usage.summaryWindow?.percent, 44);
    });

    test('ignores scoped, per-product and per-limit windows', () {
      final usage = OAuthUsage(
        windows: <OAuthUsageWindow>[
          _window('weekly', 25),
          _window('weekly_scoped', 99, label: 'Opus'),
          _window('limit-0', 98, label: 'kimi-k2'),
          _window('Grok', 97, label: 'Grok'),
        ],
      );
      expect(usage.summaryWindow?.percent, 25);
    });

    test('surfaces a scoped window when it is the only data', () {
      final usage = OAuthUsage(
        windows: <OAuthUsageWindow>[
          _window('weekly_scoped', 70, label: 'Opus'),
        ],
      );
      expect(usage.summaryWindow?.percent, 70);
    });
  });
}
