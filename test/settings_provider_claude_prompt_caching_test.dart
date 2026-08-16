import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/providers/settings_provider.dart';

void main() {
  group('ProviderConfig.claudePromptCachingTtl', () {
    test('resolveClaudePromptCachingTtl accepts valid values', () {
      expect(
        ProviderConfig.resolveClaudePromptCachingTtl(null),
        ProviderConfig.claudePromptCachingTtl5m,
      );
      expect(
        ProviderConfig.resolveClaudePromptCachingTtl('5m'),
        ProviderConfig.claudePromptCachingTtl5m,
      );
      expect(
        ProviderConfig.resolveClaudePromptCachingTtl('1h'),
        ProviderConfig.claudePromptCachingTtl1h,
      );
    });

    test('resolveClaudePromptCachingTtl trims and lowercases', () {
      expect(
        ProviderConfig.resolveClaudePromptCachingTtl(' 1H '),
        ProviderConfig.claudePromptCachingTtl1h,
      );
    });

    test('resolveClaudePromptCachingTtl falls back to 5m for invalid values',
        () {
      expect(
        ProviderConfig.resolveClaudePromptCachingTtl('99m'),
        ProviderConfig.claudePromptCachingTtl5m,
      );
      expect(
        ProviderConfig.resolveClaudePromptCachingTtl(''),
        ProviderConfig.claudePromptCachingTtl5m,
      );
      expect(
        ProviderConfig.resolveClaudePromptCachingTtl('forever'),
        ProviderConfig.claudePromptCachingTtl5m,
      );
    });

    test('claudePromptCacheControl omits ttl for 5m', () {
      expect(
        ProviderConfig.claudePromptCacheControl(
          ProviderConfig.claudePromptCachingTtl5m,
        ),
        <String, dynamic>{'type': 'ephemeral'},
      );
      expect(
        ProviderConfig.claudePromptCacheControl(null),
        <String, dynamic>{'type': 'ephemeral'},
      );
    });

    test('claudePromptCacheControl includes ttl 1h', () {
      expect(
        ProviderConfig.claudePromptCacheControl(
          ProviderConfig.claudePromptCachingTtl1h,
        ),
        <String, dynamic>{'type': 'ephemeral', 'ttl': '1h'},
      );
      expect(
        ProviderConfig.claudePromptCacheControl('1H'),
        <String, dynamic>{'type': 'ephemeral', 'ttl': '1h'},
      );
    });
  });

  group('ProviderConfig JSON round-trip', () {
    test('fromJson defaults to disabled + 5m when absent', () {
      final cfg = ProviderConfig.fromJson(const <String, dynamic>{
        'id': 'Claude',
        'enabled': true,
        'name': 'Claude',
        'apiKey': '',
        'baseUrl': '',
      });

      expect(cfg.claudePromptCachingEnabled, false);
      expect(
        cfg.claudePromptCachingTtl,
        ProviderConfig.claudePromptCachingTtl5m,
      );
    });

    test('fromJson reads enabled + ttl values', () {
      final cfg = ProviderConfig.fromJson(const <String, dynamic>{
        'id': 'Claude',
        'enabled': true,
        'name': 'Claude',
        'apiKey': '',
        'baseUrl': '',
        'claudePromptCachingEnabled': true,
        'claudePromptCachingTtl': '1h',
      });

      expect(cfg.claudePromptCachingEnabled, true);
      expect(cfg.claudePromptCachingTtl, '1h');
    });

    test('fromJson normalizes an invalid stored ttl to 5m', () {
      final cfg = ProviderConfig.fromJson(const <String, dynamic>{
        'id': 'Claude',
        'enabled': true,
        'name': 'Claude',
        'apiKey': '',
        'baseUrl': '',
        'claudePromptCachingEnabled': true,
        'claudePromptCachingTtl': 'bad',
      });

      expect(
        cfg.claudePromptCachingTtl,
        ProviderConfig.claudePromptCachingTtl5m,
      );
    });

    test('toJson round-trips enabled + ttl', () {
      final cfg = ProviderConfig.fromJson(const <String, dynamic>{
        'id': 'Claude',
        'enabled': true,
        'name': 'Claude',
        'apiKey': '',
        'baseUrl': '',
        'claudePromptCachingEnabled': true,
        'claudePromptCachingTtl': '1h',
      });

      final json = cfg.toJson();
      expect(json['claudePromptCachingEnabled'], true);
      expect(json['claudePromptCachingTtl'], '1h');
    });

    test('toJson normalizes an invalid ttl before serializing', () {
      final cfg = ProviderConfig.fromJson(const <String, dynamic>{
        'id': 'Claude',
        'enabled': true,
        'name': 'Claude',
        'apiKey': '',
        'baseUrl': '',
        'claudePromptCachingEnabled': true,
        'claudePromptCachingTtl': '1h',
      }).copyWith(claudePromptCachingTtl: 'nonsense');

      expect(cfg.toJson()['claudePromptCachingTtl'], '5m');
    });

    test('copyWith preserves fields when omitted', () {
      final cfg = ProviderConfig.fromJson(const <String, dynamic>{
        'id': 'Claude',
        'enabled': true,
        'name': 'Claude',
        'apiKey': '',
        'baseUrl': '',
        'claudePromptCachingEnabled': true,
        'claudePromptCachingTtl': '1h',
      });

      final copied = cfg.copyWith(name: 'Renamed');
      expect(copied.claudePromptCachingEnabled, true);
      expect(copied.claudePromptCachingTtl, '1h');
    });

    test('defaultsFor defaults caching to disabled', () {
      for (final key in const [
        'Claude',
        'OpenRouter',
        'OpenAI',
        'Gemini',
        'Neuralwatt',
      ]) {
        final cfg = ProviderConfig.defaultsFor(key);
        expect(cfg.claudePromptCachingEnabled, false, reason: key);
        expect(
          cfg.claudePromptCachingTtl,
          ProviderConfig.claudePromptCachingTtl5m,
          reason: key,
        );
      }
    });
  });
}
