import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('all four locales expose the same subagent keys', () {
    Map<String, dynamic> load(String locale) =>
        jsonDecode(File('lib/l10n/app_$locale.arb').readAsStringSync())
            as Map<String, dynamic>;

    final en = load('en');
    final required = <String>[
      'subagentProfilesTitle',
      'subagentProfileNew',
      'subagentProfileEdit',
      'subagentProfileReadOnly',
      'subagentProfileAllowedTools',
      'subagentProfileCustomTools',
      'subagentProfileMaxStepsRange',
      'subagentProfileTokenBudgetRange',
      'subagentProfileIdInUse',
      'subagentTraceTitle',
      'subagentTraceStep',
      'subagentTraceMore',
    ];
    for (final key in required) {
      expect(en[key], isA<String>(), reason: 'en.$key');
      expect((en[key] as String).trim(), isNotEmpty, reason: 'en.$key');
    }

    for (final locale in <String>['zh', 'zh_Hans', 'zh_Hant']) {
      final other = load(locale);
      for (final key in required) {
        expect(
          (other[key] as String?)?.trim(),
          isNotEmpty,
          reason: '$locale.$key',
        );
      }
    }
  });
}
