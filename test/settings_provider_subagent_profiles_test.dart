import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/agent/subagent_profiles.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('subagent profiles persistence (P1-1)', () {
    test('stored profiles merge with the built-ins on load', () async {
      SharedPreferences.setMockInitialValues({
        'subagent_profiles_v1': jsonEncode([
          {
            'id': 'my-reviewer',
            'name': 'My reviewer',
            'description': 'custom',
            'instructions': 'review only',
            'readOnly': true,
            'providerKey': 'openai',
            'modelId': 'gpt-4o',
            'maxSteps': 9,
          },
        ]),
      });

      final settings = SettingsProvider();
      await pumpEventQueue(times: 20);

      expect(
        settings.subagentProfiles.map((p) => p.id),
        contains('my-reviewer'),
      );
      expect(
        settings.subagentProfiles.map((p) => p.id),
        containsAll(SubagentProfiles.builtIns.map((p) => p.id)),
      );
      final custom = settings.subagentProfiles.firstWhere(
        (p) => p.id == 'my-reviewer',
      );
      expect(custom.readOnly, isTrue);
      expect(custom.providerKey, 'openai');
      expect(custom.modelId, 'gpt-4o');
    });

    test('a malformed payload falls back to the built-ins', () async {
      SharedPreferences.setMockInitialValues({
        'subagent_profiles_v1': '{not json',
      });

      final settings = SettingsProvider();
      await pumpEventQueue(times: 20);

      expect(
        settings.subagentProfiles.map((p) => p.id).toList(),
        SubagentProfiles.builtIns.map((p) => p.id).toList(),
      );
    });

    test('setSubagentProfiles persists the merged list', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsProvider();
      await pumpEventQueue(times: 20);

      await settings.setSubagentProfiles([
        const SubagentProfile(
          id: 'persisted',
          name: 'Persisted',
          description: 'd',
          instructions: 'i',
          maxSteps: 4,
        ),
      ]);

      final prefs = await SharedPreferences.getInstance();
      final stored =
          jsonDecode(prefs.getString('subagent_profiles_v1')!) as List;
      final ids = stored.map((e) => (e as Map)['id']).toList();
      expect(ids, contains('persisted'));
      expect(ids, containsAll(SubagentProfiles.builtIns.map((p) => p.id)));
    });

    test('read-only profiles cannot persist write tools', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsProvider();
      await pumpEventQueue(times: 20);

      await settings.setSubagentProfiles([
        const SubagentProfile(
          id: 'ro',
          name: 'RO',
          description: 'd',
          readOnly: true,
          allowedTools: {'file_read', 'file_append', 'file_write'},
        ),
      ]);

      final stored = settings.subagentProfiles.firstWhere((p) => p.id == 'ro');
      expect(stored.allowedTools, contains('file_read'));
      expect(stored.allowedTools, isNot(contains('file_append')));
      expect(stored.allowedTools, isNot(contains('file_write')));
    });

    test('invalid entries are dropped and the list stays capped', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsProvider();
      await pumpEventQueue(times: 20);

      final profiles = <SubagentProfile>[
        const SubagentProfile(id: 'valid', name: 'Valid', description: 'd'),
        const SubagentProfile(id: 'empty-name', name: '  ', description: 'd'),
        const SubagentProfile(id: 'bad budget', name: 'Bad', description: 'd'),
        for (var i = 0; i < 30; i++)
          SubagentProfile(id: 'custom_$i', name: 'Custom $i', description: 'd'),
      ];

      await settings.setSubagentProfiles(profiles);

      expect(settings.subagentProfiles.length, lessThanOrEqualTo(20));
      expect(
        settings.subagentProfiles.any((p) => p.id == 'empty-name'),
        isFalse,
      );
      expect(
        settings.subagentProfiles.any((p) => p.id == 'bad budget'),
        isFalse,
      );
      expect(settings.subagentProfiles.any((p) => p.id == 'valid'), isTrue);
    });
  });
}
