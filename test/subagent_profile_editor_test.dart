import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/agent/subagent_profiles.dart';
import 'package:OmniChat/features/settings/pages/subagent_profiles_page.dart';
import 'package:OmniChat/l10n/app_localizations.dart';

class _FakeSettings extends ChangeNotifier implements SettingsProvider {
  _FakeSettings({
    List<SubagentProfile>? profiles,
    Map<String, ProviderConfig>? providers,
  }) : _profiles =
           profiles ?? List<SubagentProfile>.of(SubagentProfiles.builtIns),
       _providers = providers ?? <String, ProviderConfig>{};

  List<SubagentProfile> _profiles;
  final Map<String, ProviderConfig> _providers;

  @override
  List<SubagentProfile> get subagentProfiles =>
      List<SubagentProfile>.unmodifiable(_profiles);

  @override
  Future<void> setSubagentProfiles(List<SubagentProfile> profiles) async {
    _profiles = SubagentProfiles.mergeWithBuiltIns(profiles);
    notifyListeners();
  }

  @override
  Map<String, ProviderConfig> get providerConfigs =>
      Map<String, ProviderConfig>.unmodifiable(_providers);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ProviderConfig _provider(
  String id,
  List<String> models, {
  bool enabled = true,
  Set<String> disabledModels = const <String>{},
}) => ProviderConfig(
  id: id,
  enabled: enabled,
  name: id,
  apiKey: 'k',
  baseUrl: 'http://127.0.0.1:1',
  providerType: ProviderKind.openai,
  models: models,
  disabledModels: disabledModels,
);

Future<void> _pumpPage(WidgetTester tester, _FakeSettings settings) async {
  // The editor is intentionally long; give it a tall viewport so every
  // section is built and hit-testable without fragile scroll offsets.
  await tester.binding.setSurfaceSize(const Size(800, 2000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ChangeNotifierProvider<SettingsProvider>.value(
      value: settings,
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const SubagentProfilesPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openNew(WidgetTester tester) async {
  await tester.tap(find.byTooltip('New profile'));
  await tester.pumpAndSettle();
}

Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      220,
      scrollable: find.byType(Scrollable).first,
    );
  } else {
    await tester.ensureVisible(finder.first);
  }
  await tester.pumpAndSettle();
}

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await _scrollTo(tester, finder);
  await tester.tap(finder.first);
  await tester.pumpAndSettle();
}

Future<void> _tapSwitch(WidgetTester tester, String title) async {
  await _tapVisible(tester, find.widgetWithText(SwitchListTile, title));
}

Future<void> _save(WidgetTester tester) async {
  await tester.tap(find.text('Save'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('field labels and hints match the compact input text size', (
    tester,
  ) async {
    final settings = _FakeSettings();
    await _pumpPage(tester, settings);
    await _openNew(tester);

    final nameField = tester.widget<TextField>(
      find.widgetWithText(TextField, 'Name').first,
    );
    expect(nameField.decoration?.labelStyle?.fontSize, 13.5);
    expect(nameField.decoration?.hintStyle?.fontSize, 13.5);

    final instructionsField = tester.widget<TextField>(
      find.widgetWithText(TextField, 'Instructions').first,
    );
    expect(instructionsField.decoration?.hintStyle?.fontSize, 13.5);
  });

  testWidgets('creates a custom profile with custom tool names', (
    tester,
  ) async {
    final settings = _FakeSettings();
    await _pumpPage(tester, settings);

    await _openNew(tester);
    await tester.enterText(find.byType(TextField).first, 'Test Agent');
    await _tapSwitch(tester, 'Allowed tools');
    await _tapVisible(tester, find.text('file_read'));
    await _scrollTo(tester, find.widgetWithText(TextField, 'Other tool names'));
    await tester.enterText(
      find.widgetWithText(TextField, 'Other tool names'),
      'mcp_demo_tool',
    );
    await _save(tester);

    final profile = settings.subagentProfiles.firstWhere(
      (p) => p.id == 'test_agent',
    );
    expect(profile.name, 'Test Agent');
    expect(profile.allowedTools, contains('file_read'));
    expect(profile.allowedTools, contains('mcp_demo_tool'));
  });

  testWidgets('read-only blocks write tools and does not persist them', (
    tester,
  ) async {
    final settings = _FakeSettings();
    await _pumpPage(tester, settings);

    await _openNew(tester);
    await tester.enterText(find.byType(TextField).first, 'Read Only Agent');
    await _tapSwitch(tester, 'Read-only');
    await _tapSwitch(tester, 'Allowed tools');

    final appendFinder = find.widgetWithText(CheckboxListTile, 'file_append');
    await _scrollTo(tester, appendFinder);
    final append = tester.widget<CheckboxListTile>(appendFinder);
    expect(append.onChanged, isNull);
    expect(append.value, isFalse);

    // Typing a write tool into the free-form field must not bypass the guard.
    final customField = find.widgetWithText(TextField, 'Other tool names');
    await _scrollTo(tester, customField);
    await tester.enterText(customField, 'file_write, file_read');

    await _save(tester);
    final profile = settings.subagentProfiles.firstWhere(
      (p) => p.id == 'read_only_agent',
    );
    expect(profile.readOnly, isTrue);
    expect(profile.allowedTools, contains('file_read'));
    expect(profile.allowedTools, isNot(contains('file_append')));
    expect(profile.allowedTools, isNot(contains('file_write')));
  });

  testWidgets('a deleted provider does not crash the editor and blocks save', (
    tester,
  ) async {
    final explore = SubagentProfiles.resolve(
      'explore',
      SubagentProfiles.builtIns,
    )!.copyWith(providerKey: 'gone', modelId: 'missing-model');
    final settings = _FakeSettings(profiles: [explore]);
    await _pumpPage(tester, settings);

    await tester.tap(find.text('Explore'));
    await tester.pumpAndSettle();

    // No assertion: the missing provider is treated as "follow conversation".
    expect(find.text('Follow conversation'), findsOneWidget);
    await _save(tester);
    expect(
      find.textContaining('no longer', findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets('duplicates and resets a built-in profile', (tester) async {
    final settings = _FakeSettings(
      providers: {
        'p1': _provider('p1', ['m1']),
      },
    );
    await _pumpPage(tester, settings);

    await tester.tap(find.text('Explore'));
    await tester.pumpAndSettle();
    await _tapVisible(tester, find.text('Duplicate'));

    final copy = settings.subagentProfiles.firstWhere(
      (p) => p.id == 'explore_copy',
    );
    expect(copy.builtIn, isFalse);
    expect(copy.readOnly, isTrue);

    // Reset the built-in to its defaults after editing it.
    await tester.tap(find.text('Explore'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Explore edited');
    await _save(tester);
    expect(
      settings.subagentProfiles.firstWhere((p) => p.id == 'explore').name,
      'Explore edited',
    );

    await tester.tap(find.text('Explore edited'));
    await tester.pumpAndSettle();
    await _tapVisible(tester, find.text('Reset to default'));
    expect(
      settings.subagentProfiles.firstWhere((p) => p.id == 'explore').name,
      'Explore',
    );
  });

  testWidgets('validates numeric limits while the user edits', (tester) async {
    final settings = _FakeSettings();
    await _pumpPage(tester, settings);

    await _openNew(tester);
    await tester.enterText(find.byType(TextField).first, 'Live Agent');
    final steps = find.widgetWithText(TextField, 'Max steps');
    await _scrollTo(tester, steps);
    await tester.enterText(steps, '99');
    await tester.pump();

    expect(find.text('Max steps must be between 1 and 40.'), findsOneWidget);

    await tester.enterText(steps, 'abc');
    await tester.pump();
    expect(find.text('Max steps must be between 1 and 40.'), findsOneWidget);

    await tester.enterText(steps, '10');
    await tester.pump();
    expect(find.text('Max steps must be between 1 and 40.'), findsNothing);
  });

  testWidgets('deletes a custom profile after confirmation', (tester) async {
    final settings = _FakeSettings(
      profiles: [
        ...SubagentProfiles.builtIns,
        const SubagentProfile(
          id: 'throwaway',
          name: 'Throwaway',
          description: 'd',
        ),
      ],
    );
    await _pumpPage(tester, settings);

    await tester.tap(find.text('Throwaway'));
    await tester.pumpAndSettle();
    await _tapVisible(tester, find.text('Delete'));
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(settings.subagentProfiles.any((p) => p.id == 'throwaway'), isFalse);
  });

  testWidgets('only offers enabled providers and enabled models', (
    tester,
  ) async {
    final settings = _FakeSettings(
      providers: {
        'active-provider': _provider(
          'active-provider',
          ['active-model', 'disabled-model'],
          disabledModels: {'disabled-model'},
        ),
        'disabled-provider': _provider('disabled-provider', [
          'hidden-model',
        ], enabled: false),
      },
    );
    await _pumpPage(tester, settings);

    await _openNew(tester);
    await tester.tap(find.byType(DropdownButtonFormField<String?>).first);
    await tester.pumpAndSettle();

    expect(find.text('active-provider'), findsOneWidget);
    expect(find.text('disabled-provider'), findsNothing);

    await tester.tap(find.text('active-provider').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();

    expect(find.text('active-model'), findsOneWidget);
    expect(find.text('disabled-model'), findsNothing);
  });

  testWidgets('shows an immediate warning for a disabled model binding', (
    tester,
  ) async {
    final explore = SubagentProfiles.resolve(
      'explore',
      SubagentProfiles.builtIns,
    )!.copyWith(providerKey: 'p1', modelId: 'm1');
    final settings = _FakeSettings(
      profiles: [explore],
      providers: {
        'p1': _provider('p1', ['m1'], disabledModels: const <String>{'m1'}),
      },
    );
    await _pumpPage(tester, settings);

    await tester.tap(find.text('Explore'));
    await tester.pumpAndSettle();

    expect(
      find.text('This model is no longer enabled. Pick another model.'),
      findsOneWidget,
    );
    await _save(tester);
    expect(
      find.text('This model is no longer enabled. Pick another model.'),
      findsOneWidget,
    );
  });

  testWidgets('a provider with no enabled models cannot be saved', (
    tester,
  ) async {
    final settings = _FakeSettings(
      providers: {'empty-provider': _provider('empty-provider', [])},
    );
    await _pumpPage(tester, settings);

    await _openNew(tester);
    await tester.enterText(find.byType(TextField).first, 'Empty Model Agent');
    await tester.tap(find.byType(DropdownButtonFormField<String?>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('empty-provider').last);
    await tester.pumpAndSettle();

    expect(
      find.text(
        'No enabled models for this provider. Add or enable a model in Providers first.',
      ),
      findsOneWidget,
    );
    await _save(tester);
    expect(
      find.text(
        'No enabled models for this provider. Add or enable a model in Providers first.',
      ),
      findsOneWidget,
    );
    expect(
      settings.subagentProfiles.any((p) => p.id == 'empty_model_agent'),
      isFalse,
    );
  });

  testWidgets('persists a pre-bound provider and model', (tester) async {
    final settings = _FakeSettings(
      providers: {
        'p1': _provider('p1', ['m1']),
      },
    );
    await _pumpPage(tester, settings);

    await _openNew(tester);
    await tester.enterText(find.byType(TextField).first, 'Bound Agent');

    await tester.tap(find.byType(DropdownButtonFormField<String?>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('p1').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('m1').last);
    await tester.pumpAndSettle();

    await _save(tester);
    final profile = settings.subagentProfiles.firstWhere(
      (p) => p.id == 'bound_agent',
    );
    expect(profile.providerKey, 'p1');
    expect(profile.modelId, 'm1');
  });
}
