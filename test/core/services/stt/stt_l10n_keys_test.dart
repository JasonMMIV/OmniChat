import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// docs/speech_recognition_import_plan.md §9.2：新 key 在四個 ARB 都存在。
const List<String> _arbFiles = <String>[
  'lib/l10n/app_en.arb',
  'lib/l10n/app_zh.arb',
  'lib/l10n/app_zh_Hans.arb',
  'lib/l10n/app_zh_Hant.arb',
];

const List<String> _requiredKeys = <String>[
  'sttServicesPageAddServiceTooltip',
  'sttServicesFieldLanguageLabel',
  'sttServicesFieldLanguageHint',
  'sttServicesFieldWorkspaceIdLabel',
  'sttServicesFieldRegionLabel',
  'sttServicesFieldEndpointAuto',
  'sttServicesEndpointInvalid',
  'sttServicesModeLabel',
  'sttServicesModeRealtime',
  'sttServicesModeRecorded',
  'sttServicesWorkspaceIdHint',
  'sttServicesWorkspaceIdInvalid',
  'sttServicesQwenTokenPlanHint',
  'sttServicesRealtimeUnsupported',
  'sttServicesTranscribing',
  'sttServicesTranscriptionFailed',
  'sttServicesNoSpeechDetected',
  'sttServicesMicrophonePermissionDenied',
];

Map<String, dynamic> _read(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

void main() {
  test('new STT keys exist in all four ARB files', () {
    for (final path in _arbFiles) {
      final map = _read(path);
      for (final key in _requiredKeys) {
        expect(
          map[key],
          isA<String>(),
          reason: '$path is missing $key',
        );
      }
    }
  });

  test('transcriptionFailed declares its error placeholder', () {
    final en = _read('lib/l10n/app_en.arb');
    expect(en['sttServicesTranscriptionFailed'], contains('{error}'));
    final meta = en['@sttServicesTranscriptionFailed'];
    expect(meta, isA<Map<String, dynamic>>());
    final placeholders = (meta as Map<String, dynamic>)['placeholders'];
    expect(placeholders, isA<Map<String, dynamic>>());
    expect(
      (placeholders as Map<String, dynamic>)['error'],
      isA<Map<String, dynamic>>(),
    );
  });
}
