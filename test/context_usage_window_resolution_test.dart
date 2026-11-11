// Context-usage ring window resolution.
//
// The ring must use the same catalog facts as the model picker chips:
// `apiModelId` aliases resolve to the upstream model, the provider-scoped
// entry wins over a same-named model from another provider, and an unknown
// model stays null (the ring then shows `used / ...`, never a fake 1M ratio).

import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/core/providers/model_provider.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/model_catalog/model_catalog.dart';

const String _catalogJson = '''
{
  "agnes": {
    "api": "https://apihub.agnes-ai.com/v1",
    "models": {
      "agnes-3.0-flash": {
        "limit": {"context": 512000, "output": 65536},
        "modalities": {"input": ["text"], "output": ["text"]}
      }
    }
  },
  "commandcode": {
    "api": "https://api.commandcode.ai/provider/v1",
    "models": {
      "deepseek/deepseek-v4.1-flash": {
        "limit": {"context": 1000000, "output": 384000},
        "modalities": {"input": ["text"], "output": ["text"]}
      }
    }
  },
  "openrouter": {
    "api": "https://openrouter.ai/api/v1",
    "models": {
      "deepseek/deepseek-v4.1-flash": {
        "limit": {"context": 1048576, "output": 384000},
        "modalities": {"input": ["text"], "output": ["text"]}
      }
    }
  }
}
''';

ProviderConfig _cfg({
  required String id,
  required String name,
  required String baseUrl,
  Map<String, dynamic> modelOverrides = const <String, dynamic>{},
}) {
  return ProviderConfig.fromJson(<String, dynamic>{
    'id': id,
    'name': name,
    'baseUrl': baseUrl,
    'providerType': 'openai',
    'modelOverrides': modelOverrides,
  });
}

void main() {
  setUp(() => ModelCatalog.loadFromJsonString(_catalogJson));
  tearDown(ModelCatalog.debugReset);

  test('resolves the provider-scoped catalog window', () {
    final cfg = _cfg(
      id: 'OpenAI - Agnes',
      name: 'Agnes',
      baseUrl: 'https://apihub.agnes-ai.com/v1',
    );
    expect(ModelRegistry.catalogContextWindow(cfg, 'agnes-3.0-flash'), 512000);
  });

  test('provider scope wins over a same-named model elsewhere', () {
    final cfg = _cfg(
      id: 'OpenAI - Command Code Goat',
      name: 'Command Code Goat',
      baseUrl: 'https://api.commandcode.ai/provider/v1',
    );
    expect(
      ModelRegistry.catalogContextWindow(cfg, 'deepseek/deepseek-v4.1-flash'),
      1000000,
    );
  });

  test('resolves a logical alias through apiModelId', () {
    final cfg = _cfg(
      id: 'OpenAI - Agnes',
      name: 'Agnes',
      baseUrl: 'https://apihub.agnes-ai.com/v1',
      modelOverrides: <String, dynamic>{
        'my-flash': <String, dynamic>{'apiModelId': 'agnes-3.0-flash'},
      },
    );
    expect(ModelRegistry.catalogContextWindow(cfg, 'my-flash'), 512000);
  });

  test('unknown model stays null (no 1M fallback)', () {
    final cfg = _cfg(
      id: 'Local',
      name: 'Local',
      baseUrl: 'http://127.0.0.1:1234/v1',
    );
    expect(ModelRegistry.catalogContextWindow(cfg, 'unknown-model'), isNull);
  });

  test('install listeners fire once per catalog replacement', () {
    var calls = 0;
    void listener() => calls++;
    ModelCatalog.addInstallListener(listener);
    ModelCatalog.addInstallListener(listener); // duplicate is ignored
    ModelCatalog.loadFromJsonString(_catalogJson);
    expect(calls, 1);
    ModelCatalog.loadFromJsonString(_catalogJson);
    expect(calls, 2);
    ModelCatalog.removeInstallListener(listener);
    ModelCatalog.debugReset();
    expect(calls, 2);
  });
}
