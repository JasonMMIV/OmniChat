import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/search/search_dispatch.dart';
import 'package:OmniChat/core/services/search/search_service.dart';

/// 與 `live_tools_test.dart` 相同的載入輔助。
Future<SettingsProvider> _loadedProvider() async {
  final sp = SettingsProvider();
  final done = Completer<void>();
  void listener() {
    if (!done.isCompleted) done.complete();
  }

  sp.addListener(listener);
  await done.future.timeout(const Duration(seconds: 10));
  sp.removeListener(listener);
  return sp;
}

Map<String, Object> _twoServicesPrefs({
  Map<String, Object> extra = const <String, Object>{},
}) {
  return <String, Object>{
    'search_services_v1': jsonEncode(<Map<String, dynamic>>[
      BingLocalOptions(id: 's1').toJson(),
      TavilyOptions(id: 's2', apiKey: 'k').toJson(),
    ]),
    ...extra,
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('search multi-select migration', () {
    test('derives the checked set from the legacy single-selection int', () async {
      SharedPreferences.setMockInitialValues(
        _twoServicesPrefs(extra: <String, Object>{'search_selected_v1': 1}),
      );
      final sp = await _loadedProvider();
      // Zero-touch upgrade: the legacy index resolves to the same provider.
      expect(sp.searchSelectedProviders, <String>['s2']);
      expect(sp.searchServiceSelected, 1);
      expect(sp.searchDispatchMode, SearchDispatchMode.fallback);
    });

    test('loads the new keys when present and persists the dispatch mode',
        () async {
      SharedPreferences.setMockInitialValues(
        _twoServicesPrefs(
          extra: <String, Object>{
            'search_selected_providers_v1': <String>['s2'],
            'search_dispatch_mode_v1': 'round_robin',
          },
        ),
      );
      final sp = await _loadedProvider();
      expect(sp.searchSelectedProviders, <String>['s2']);
      expect(sp.searchDispatchMode, SearchDispatchMode.roundRobin);

      await sp.setSearchDispatchMode(SearchDispatchMode.fallback);
      final reloaded = await _loadedProvider();
      expect(reloaded.searchDispatchMode, SearchDispatchMode.fallback);
    });
  });

  group('selected set maintenance', () {
    Future<SettingsProvider> providerWithTwoServices() async {
      SharedPreferences.setMockInitialValues(
        _twoServicesPrefs(
          extra: <String, Object>{
            'search_selected_providers_v1': <String>['s1', 's2'],
          },
        ),
      );
      return _loadedProvider();
    }

    test('setSearchServices prunes dangling ids and re-seeds an empty set',
        () async {
      final sp = await providerWithTwoServices();
      expect(sp.searchSelectedProviders, <String>['s1', 's2']);

      // Deleting s1 prunes it from the checked set.
      await sp.setSearchServices(<SearchServiceOptions>[
        TavilyOptions(id: 's2', apiKey: 'k'),
      ]);
      expect(sp.searchSelectedProviders, <String>['s2']);

      // Deleting the only checked provider re-seeds the first remaining one.
      await sp.setSearchServices(<SearchServiceOptions>[
        BingLocalOptions(id: 's3'),
      ]);
      expect(sp.searchSelectedProviders, <String>['s3']);
    });

    test('setSearchSelectedProviders normalizes order and never stays empty',
        () async {
      final sp = await providerWithTwoServices();
      // Priority order = service-list order.
      await sp.setSearchSelectedProviders(<String>['s2', 's1']);
      expect(sp.searchSelectedProviders, <String>['s1', 's2']);

      await sp.setSearchSelectedProviders(<String>['nope']);
      expect(sp.searchSelectedProviders, <String>['s1']);

      await sp.setSearchSelectedProviders(<String>[]);
      expect(sp.searchSelectedProviders, <String>['s1']);
    });

    test('promoteSearchProvider moves the provider to the top and selects it',
        () async {
      final sp = await providerWithTwoServices();
      await sp.setSearchSelectedProviders(<String>['s1']);

      await sp.promoteSearchProvider('s2');
      expect(sp.searchServices.first.id, 's2');
      expect(sp.searchSelectedProviders, <String>['s2', 's1']);
      // The promoted provider is now the primary one.
      expect(sp.searchServiceSelected, 0);
    });
  });
}
