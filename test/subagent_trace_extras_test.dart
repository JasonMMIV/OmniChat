import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/services/chat/storage/message_part_codec.dart';

void main() {
  group('subagent trace extras (P1-2)', () {
    const trace = <String, dynamic>{
      'status': 'max_steps',
      'profile': 'explore',
      'steps': 12,
      'toolCalls': 14,
      'tokens': 54210,
      'summarySource': 'wrap_up',
      'items': [
        {'t': 'file_grep', 'ms': 120, 'chars': 800},
      ],
    };

    test('the preserved key list includes the trace and token extras', () {
      expect(kPreservedToolEventExtraKeys, contains('subagentTrace'));
      expect(kPreservedToolEventExtraKeys, contains('subagentTokens'));
    });

    test('legacy summary reads the trace back from the event', () {
      final summary = toolPartSummaryFromEvent(
        event: {
          'id': 'call_1',
          'name': 'spawn_subagent',
          'arguments': const <String, dynamic>{},
          'content': '{"type":"subagent_result"}',
          'approvalState': 'auto',
          'subagentTrace': trace,
          'subagentTokens': 54210,
        },
        messageId: 'm1',
        ordinal: 0,
      );
      expect(summary.subagentTrace, isNotNull);
      expect(summary.subagentTrace!['profile'], 'explore');
      expect((summary.subagentTrace!['items'] as List), hasLength(1));
    });

    test('the Hive import path preserves the trace in metadata', () {
      final draft = toolPartDraftFromLegacyEvent({
        'id': 'call_1',
        'name': 'spawn_subagent',
        'arguments': const <String, dynamic>{},
        'content': '{}',
        'subagentTrace': trace,
      });
      final metadata = jsonDecode(draft.metadataJson!) as Map;
      expect(metadata['subagentTrace'], isNotNull);
      expect((metadata['subagentTrace'] as Map)['tokens'], 54210);
    });
  });
}
