import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/api/builtin_tools.dart';
import 'package:OmniChat/features/model/widgets/model_detail_sheet.dart';
import 'package:OmniChat/l10n/app_localizations.dart';

class _FakeSettings extends ChangeNotifier implements SettingsProvider {
  _FakeSettings(this._config);

  ProviderConfig _config;

  @override
  ProviderConfig getProviderConfig(String key, {String? defaultName}) =>
      _config;

  @override
  Future<void> setProviderConfig(String key, ProviderConfig config) async {
    _config = config;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('saving model details preserves webSearch and webFetch maps',
      (tester) async {
    final settings = _FakeSettings(
      ProviderConfig(
        id: 'provider',
        enabled: true,
        name: 'Provider',
        apiKey: 'k',
        baseUrl: 'https://openrouter.ai/api/v1',
        providerType: ProviderKind.openai,
        models: const <String>['model'],
        modelOverrides: <String, dynamic>{
          'model': <String, dynamic>{
            'apiModelId': 'model',
            'name': 'Model',
            'type': 'chat',
            'input': const <String>['text'],
            'output': const <String>['text'],
            'abilities': const <String>['tool'],
            'builtInTools': const <String>[
              BuiltInToolNames.webFetch,
            ],
            'webSearch': <String, dynamic>{
              'toolVersion': 'web_search_20260209',
              'maxUses': 3,
            },
            'webFetch': <String, dynamic>{
              'toolVersion': 'web_fetch',
              'maxContentTokens': 12000,
              'allowedDomains': const <String>['docs.example.com'],
            },
          },
        },
      ),
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: settings,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => showModelDetailSheet(
                    context,
                    providerKey: 'provider',
                    modelId: 'model',
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Save'), findsOneWidget);
    await tester.tap(find.text('Save'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    final saved = settings.getProviderConfig('provider');
    final ov = (saved.modelOverrides['model'] as Map).cast<String, dynamic>();
    expect(ov['webSearch'], isA<Map>());
    expect((ov['webSearch'] as Map)['toolVersion'], 'web_search_20260209');
    expect((ov['webSearch'] as Map)['maxUses'], 3);
    expect(ov['webFetch'], isA<Map>());
    expect((ov['webFetch'] as Map)['maxContentTokens'], 12000);
    expect(
      (ov['webFetch'] as Map)['allowedDomains'],
      const <String>['docs.example.com'],
    );
    expect(
      (ov['builtInTools'] as List).contains(BuiltInToolNames.webFetch),
      isTrue,
    );
  });
}
