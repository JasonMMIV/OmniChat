import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/api/builtin_tools.dart';
import 'package:OmniChat/core/services/model_catalog/model_catalog.dart';
import 'package:OmniChat/features/model/widgets/model_detail_sheet.dart';
import 'package:OmniChat/icons/lucide_adapter.dart';
import 'package:OmniChat/l10n/app_localizations.dart';
import 'package:OmniChat/shared/widgets/ios_tile_button.dart';

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

  // Token-limit facts for the sheet's freshly inferred `_base`. The sheet
  // projects the effective input window (`limit.input` ?? `limit.context`) and
  // `limit.output` from the global ladder, so the fixture model id must be the
  // one stored under `apiModelId`.
  const String _catalogFixture = '''
{
  "test-provider": {
    "models": {
      "model": {
        "limit": {"context": 100000, "output": 8000},
        "modalities": {"input": ["text"], "output": ["text"]},
        "tool_call": true,
        "reasoning": true
      }
    }
  }
}
''';

  setUp(() {
    ModelCatalog.loadFromJsonString(_catalogFixture);
  });

  tearDown(() {
    ModelCatalog.debugReset();
  });

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

  testWidgets('basic tab lays out five input modalities at 360px', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final settings = _FakeSettings(
      ProviderConfig(
        id: 'provider',
        enabled: true,
        name: 'Provider',
        apiKey: 'k',
        baseUrl: 'https://generativelanguage.googleapis.com',
        providerType: ProviderKind.google,
        models: const <String>['model'],
        modelOverrides: <String, dynamic>{
          'model': <String, dynamic>{
            'apiModelId': 'model',
            'name': 'Model',
            'type': 'chat',
            'input': const <String>[
              'text',
              'image',
              'audio',
              'video',
              'pdf',
            ],
            'inputV': 2,
            'output': const <String>['text'],
            'abilities': const <String>['tool'],
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
    await tester.pumpAndSettle();

    // Smoke-test the dense five-cell row at the narrowest common phone width.
    expect(find.text('PDF'), findsOneWidget);
    expect(find.text('Native attachments'), findsNothing);
    // The token limits row sits below the fold: scroll it into view and
    // verify the two side-by-side fields do not overflow at 360px.
    await tester.dragUntilVisible(
      find.byKey(const ValueKey('model-context-window-field')),
      find.byType(ListView),
      const Offset(0, -150),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('model-context-window-field')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('model-max-output-field')),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // ===== 預設 / 自訂 save behavior (Kelivo parity) =========================

  ProviderConfig _configWithOverrides(Map<String, dynamic> overrides) {
    return ProviderConfig(
      id: 'provider',
      enabled: true,
      name: 'Provider',
      apiKey: 'k',
      baseUrl: 'https://openrouter.ai/api/v1',
      providerType: ProviderKind.openai,
      models: const <String>['model'],
      modelOverrides: overrides,
    );
  }

  Future<void> _pumpSheet(WidgetTester tester, _FakeSettings settings) async {
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
  }

  Future<void> _pumpCreateSheet(
    WidgetTester tester,
    _FakeSettings settings,
  ) async {
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
                  onPressed: () => showCreateModelSheet(
                    context,
                    providerKey: 'provider',
                  ),
                  child: const Text('create'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('create'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
  }

  Map<String, dynamic> _savedOverrides(_FakeSettings settings) =>
      (settings.getProviderConfig('provider').modelOverrides['model'] as Map)
          .cast<String, dynamic>();

  testWidgets('no-op save drops legacy spec keys that match the inferred base',
      (tester) async {
    final settings = _FakeSettings(
      _configWithOverrides(<String, dynamic>{
        'model': <String, dynamic>{
          'apiModelId': 'model',
          'name': 'Model',
          // Legacy: every spec section re-stored its inferred default.
          'type': 'chat',
          'input': const <String>['text'],
          'inputV': 2,
          'output': const <String>['text'],
          'abilities': const <String>['tool', 'reasoning'],
          // Unrelated keys must survive the auto-clean.
          'builtInTools': const <String>[BuiltInToolNames.webFetch],
        },
      }),
    );

    await _pumpSheet(tester, settings);
    expect(find.text('Save'), findsOneWidget);
    await tester.tap(find.text('Save'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    final ov = _savedOverrides(settings);
    // Nothing differs from the base → no spec key is written, and the
    // legacy keys that re-stored the defaults are gone.
    expect(ov.containsKey('type'), isFalse, reason: 'matches the base');
    expect(ov.containsKey('input'), isFalse);
    expect(ov.containsKey('inputV'), isFalse);
    expect(ov.containsKey('output'), isFalse);
    expect(ov.containsKey('abilities'), isFalse);
    expect(ov.containsKey('contextWindow'), isFalse);
    expect(ov.containsKey('maxOutput'), isFalse);
    // Still carried through.
    expect(ov['apiModelId'], 'model');
    expect(ov['name'], 'Model');
    expect(
      (ov['builtInTools'] as List).contains(BuiltInToolNames.webFetch),
      isTrue,
    );
  });

  testWidgets('editing only the type writes just the type override',
      (tester) async {
    final settings = _FakeSettings(
      _configWithOverrides(<String, dynamic>{
        'model': <String, dynamic>{
          'apiModelId': 'model',
          'name': 'Model',
        },
      }),
    );

    await _pumpSheet(tester, settings);
    await tester.tap(find.text('Embedding'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    final ov = _savedOverrides(settings);
    expect(ov['type'], 'embedding');
    // Sibling sections stayed at their inferred defaults — not written, and
    // token limits are gated on the chat type.
    expect(ov.containsKey('input'), isFalse);
    expect(ov.containsKey('inputV'), isFalse);
    expect(ov.containsKey('output'), isFalse);
    expect(ov.containsKey('abilities'), isFalse);
    expect(ov.containsKey('contextWindow'), isFalse);
    expect(ov.containsKey('maxOutput'), isFalse);
  });

  testWidgets(
      'token limits follow defaults until edited; reset restores the base',
      (tester) async {
    // Tall viewport so the whole basic tab (token limits row included) is
    // built without scrolling.
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final settings = _FakeSettings(
      _configWithOverrides(<String, dynamic>{
        'model': <String, dynamic>{
          'apiModelId': 'model',
          'name': 'Model',
        },
      }),
    );

    await _pumpSheet(tester, settings);

    // Prefilled from the catalog fixture (context 100000 / output 8000).
    final ctxField = tester.widget<TextField>(
      find.byKey(const ValueKey('model-context-window-field')),
    );
    expect(ctxField.controller!.text, '100000');
    final outField = tester.widget<TextField>(
      find.byKey(const ValueKey('model-max-output-field')),
    );
    expect(outField.controller!.text, '8000');
    // Default state: no 自訂 capsule, no reset icon anywhere.
    expect(find.text('Custom'), findsNothing);
    expect(find.byIcon(Lucide.RotateCcw), findsNothing);

    // Editing one field flips only the token limits section to 自訂.
    await tester.enterText(
      find.byKey(const ValueKey('model-context-window-field')),
      '50000',
    );
    await tester.pumpAndSettle();
    expect(find.text('Custom'), findsOneWidget);
    expect(find.byIcon(Lucide.RotateCcw), findsOneWidget);

    // The reset icon restores the inferred defaults and clears 自訂.
    await tester.tap(find.byIcon(Lucide.RotateCcw));
    await tester.pumpAndSettle();
    expect(find.byIcon(Lucide.RotateCcw), findsNothing);
    expect(find.text('Custom'), findsNothing);
    final ctxFieldAfterReset = tester.widget<TextField>(
      find.byKey(const ValueKey('model-context-window-field')),
    );
    expect(ctxFieldAfterReset.controller!.text, '100000');

    // A custom value is written; the untouched sibling stays absent.
    await tester.enterText(
      find.byKey(const ValueKey('model-context-window-field')),
      '50000',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    final ov = _savedOverrides(settings);
    expect(ov['contextWindow'], 50000);
    expect(ov.containsKey('maxOutput'), isFalse);
    // Spec siblings untouched → nothing else written.
    expect(ov.containsKey('type'), isFalse);
    expect(ov.containsKey('input'), isFalse);
    expect(ov.containsKey('output'), isFalse);
    expect(ov.containsKey('abilities'), isFalse);
  });

  testWidgets('zero token limits are treated as unset (no dead override)',
      (tester) async {
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final settings = _FakeSettings(
      _configWithOverrides(<String, dynamic>{
        'model': <String, dynamic>{'apiModelId': 'model', 'name': 'Model'},
      }),
    );

    await _pumpSheet(tester, settings);
    await tester.enterText(
      find.byKey(const ValueKey('model-context-window-field')),
      '0',
    );
    await tester.enterText(
      find.byKey(const ValueKey('model-max-output-field')),
      '0',
    );
    await tester.pumpAndSettle();

    // 0 cannot be stored: `parseIntOverride` rejects it, so it must not count
    // as a custom section either.
    expect(find.text('Custom'), findsNothing);

    await tester.tap(find.text('Save'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    final ov = _savedOverrides(settings);
    expect(ov.containsKey('contextWindow'), isFalse);
    expect(ov.containsKey('maxOutput'), isFalse);
  });

  testWidgets('create flow infers defaults from the typed id', (tester) async {
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final settings = _FakeSettings(
      ProviderConfig(
        id: 'provider',
        enabled: true,
        name: 'Provider',
        apiKey: 'k',
        baseUrl: 'https://openrouter.ai/api/v1',
        providerType: ProviderKind.openai,
        models: const <String>[],
        modelOverrides: const <String, dynamic>{},
      ),
    );

    await _pumpCreateSheet(tester, settings);
    await tester.enterText(find.byType(TextField).first, 'model');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    // The token-limit hints come from the freshly inferred base, not the
    // generic `infer('custom')` defaults the sheet opened with.
    final ctxField = tester.widget<TextField>(
      find.byKey(const ValueKey('model-context-window-field')),
    );
    expect(ctxField.decoration!.hintText, '100k');
    final outField = tester.widget<TextField>(
      find.byKey(const ValueKey('model-max-output-field')),
    );
    expect(outField.decoration!.hintText, '8k');
    // Untouched spec sections match the final base → 預設, not 自訂.
    expect(find.text('Custom'), findsNothing);

    await tester.tap(
      find.descendant(
        of: find.byType(IosTileButton),
        matching: find.text('Add'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    final ov = _savedOverrides(settings);
    expect(ov['apiModelId'], 'model');
    // A no-op save must not persist an incomplete abilities/limits snapshot.
    expect(ov.containsKey('abilities'), isFalse);
    expect(ov.containsKey('contextWindow'), isFalse);
    expect(ov.containsKey('maxOutput'), isFalse);
  });
}
