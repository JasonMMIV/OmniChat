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
      'subagentTraceStepMeta',
      'subagentTraceRunning',
      'subagentTraceRunningTool',
      'subagentTraceMore',
      'subagentProfileNoEnabledModels',
      'subagentProfileModelUnavailable',
      'subagentDelegatedTo',
      'subagentDelegatedContinue',
      'subagentDelegatedFailed',
      'subagentDelegatedEmpty',
      'toolNameDelegateSubagent',
      'addonsSubagentEnable',
      'addonsSubagentSubtitle',
      'addonsSubagentProfileCount',
      'addonsSubagentPickHint',
      'composerSendNowDelegationHint',
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

  test('Add-ons subagent subtitle describes returning the result', () {
    Map<String, dynamic> load(String locale) =>
        jsonDecode(File('lib/l10n/app_$locale.arb').readAsStringSync())
            as Map<String, dynamic>;

    final en = load('en')['addonsSubagentSubtitle'] as String;
    expect(en.toLowerCase(), contains('result'));
    expect(en.toLowerCase(), isNot(contains('summary')));

    for (final locale in <String>['zh', 'zh_Hans']) {
      final text = load(locale)['addonsSubagentSubtitle'] as String;
      expect(text, contains('可独立完成'));
      expect(text, contains('只收回结果'));
      expect(text, isNot(contains('摘要')));
    }
    final zhHant = load('zh_Hant')['addonsSubagentSubtitle'] as String;
    expect(zhHant, contains('可獨立完成'));
    expect(zhHant, contains('只收回結果'));
    expect(zhHant, isNot(contains('摘要')));
  });
}
