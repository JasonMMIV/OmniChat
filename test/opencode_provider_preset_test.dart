import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/core/providers/model_provider.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';

void main() {
  group('OpenCode provider presets', () {
    test('Zen uses the Zen base URL and OpenAI transport', () {
      final cfg = ProviderConfig.defaultsFor('OpenCode Zen');
      expect(cfg.baseUrl, 'https://opencode.ai/zen/v1');
      expect(cfg.providerType, ProviderKind.openai);
      expect(cfg.chatPath, '/chat/completions');
      expect(cfg.useResponseApi, isFalse);
      expect(cfg.enabled, isFalse);
    });

    test('Go uses the Go base URL', () {
      expect(
        ProviderConfig.defaultsFor('OpenCode Go').baseUrl,
        'https://opencode.ai/zen/go/v1',
      );
    });

    test('hyphenated and lowercase keys still resolve to Go', () {
      expect(
        ProviderConfig.defaultsFor('OpenCode-Go').baseUrl,
        'https://opencode.ai/zen/go/v1',
      );
      expect(
        ProviderConfig.defaultsFor('opencode go').baseUrl,
        'https://opencode.ai/zen/go/v1',
      );
    });

    test('balance is explicitly disabled and has no endpoint', () {
      for (final key in const ['OpenCode Zen', 'OpenCode Go']) {
        final cfg = ProviderConfig.defaultsFor(key);
        expect(cfg.balanceEnabled, isFalse);
        expect(cfg.balanceApiPath, isEmpty);
        expect(cfg.balanceResultKey, isEmpty);
      }
    });

    test('getBalance is a no-op without a configured endpoint', () async {
      final cfg = ProviderConfig.defaultsFor('OpenCode Go');
      expect(await ProviderManager.getBalance(cfg), '');
    });

    test('a custom name that merely mentions OpenCode keeps its own defaults', () {
      final cfg = ProviderConfig.defaultsFor('OpenCode Proxy');
      expect(cfg.baseUrl, isNot('https://opencode.ai/zen/v1'));
      expect(cfg.balanceApiPath, '/user/info');
      expect(cfg.balanceResultKey, 'data.available_balance');
    });

    test('other providers keep their balance settings', () {
      final openRouter = ProviderConfig.defaultsFor('OpenRouter');
      expect(openRouter.balanceEnabled, isTrue);
      expect(openRouter.balanceApiPath, '/credits');
      expect(
        openRouter.balanceResultKey,
        'data.total_credits - data.total_usage',
      );
    });
  });
}
