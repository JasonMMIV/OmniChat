import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/core/services/chat/storage/message_part_codec.dart';

void main() {
  group('approval/status normalization', () {
    test('normalizes unknown/null approval states to auto', () {
      expect(normalizeApprovalState(null), kApprovalAuto);
      expect(normalizeApprovalState('rejected'), kApprovalAuto);
      expect(normalizeApprovalState(' answered '), kApprovalAnswered);
      expect(normalizeApprovalState('denied'), kApprovalDenied);
    });

    test('legacy status follows approval state before content presence', () {
      expect(
        deriveLegacyToolPartStatus(
          approvalState: kApprovalPending,
          content: '{"requested_at":1}',
        ),
        kPartStatusPending,
      );
      expect(
        deriveLegacyToolPartStatus(
          approvalState: kApprovalDenied,
          content: '{"denied":true}',
        ),
        kPartStatusDenied,
      );
      expect(
        deriveLegacyToolPartStatus(
          approvalState: kApprovalApproved,
          content: null,
        ),
        kPartStatusInterrupted,
      );
      expect(
        deriveLegacyToolPartStatus(
          approvalState: kApprovalAnswered,
          content: 'result',
        ),
        kPartStatusCompleted,
      );
      expect(
        deriveLegacyToolPartStatus(
          approvalState: kApprovalAuto,
          content: null,
        ),
        kPartStatusInterrupted,
      );
      expect(
        deriveLegacyToolPartStatus(
          approvalState: kApprovalAuto,
          content: '',
        ),
        kPartStatusCompleted,
      );
    });

    test('runtime status keeps a no-result placeholder pending', () {
      expect(
        deriveRuntimeToolPartStatus(
          approvalState: kApprovalAuto,
          content: null,
        ),
        kPartStatusPending,
      );
      expect(
        deriveRuntimeToolPartStatus(
          approvalState: kApprovalApproved,
          content: null,
        ),
        kPartStatusPending,
      );
      expect(
        deriveRuntimeToolPartStatus(
          approvalState: kApprovalDenied,
          content: null,
        ),
        kPartStatusDenied,
      );
    });

    test('only completed and denied parts replay', () {
      expect(isReplayablePartStatus(kPartStatusCompleted), isTrue);
      expect(isReplayablePartStatus(kPartStatusDenied), isTrue);
      expect(isReplayablePartStatus(kPartStatusPending), isFalse);
      expect(isReplayablePartStatus(kPartStatusInterrupted), isFalse);
    });
  });

  group('canonical JSON', () {
    test('sorts keys recursively and preserves list order', () {
      final a = canonicalJsonEncode({
        'b': 1,
        'a': {
          'z': [3, 2, 1],
          'y': 'text',
        },
      });
      final b = canonicalJsonEncode({
        'a': {
          'y': 'text',
          'z': [3, 2, 1],
        },
        'b': 1,
      });
      expect(a, b);
      expect(jsonDecode(a), isA<Map<String, dynamic>>());
    });

    test('UTF-8 byte length counts astral characters by bytes', () {
      expect(utf8Length(null), 0);
      expect(utf8Length('abc'), 3);
      expect(utf8Length('😀'), 4);
    });
  });

  group('legacy event mapping', () {
    test('maps every field and preserves unknown keys', () {
      final draft = toolPartDraftFromLegacyEvent({
        'id': 'call_1',
        'name': 'web_fetch',
        'arguments': {'url': 'https://example.com', 'max_length': 10},
        'content': 'page',
        'approvalState': 'auto',
        'webFetchSource': 'Local',
        'customFutureKey': {'nested': true},
      });

      expect(draft.toolCallId, 'call_1');
      expect(draft.toolName, 'web_fetch');
      expect(draft.content, 'page');
      expect(draft.status, kPartStatusCompleted);
      expect(draft.approvalState, kApprovalAuto);

      final metadata =
          jsonDecode(draft.metadataJson!) as Map<String, dynamic>;
      expect(metadata['webFetchSource'], 'Local');
      expect(metadata['customFutureKey'], {'nested': true});
      // Column-backed keys are never duplicated.
      expect(metadata.containsKey('id'), isFalse);
      expect(metadata.containsKey('content'), isFalse);
      expect(metadata.containsKey('approvalState'), isFalse);
    });

    test('an empty id becomes null and empty content stays a result', () {
      final draft = toolPartDraftFromLegacyEvent({
        'id': '   ',
        'name': 'ask_user',
        'arguments': <String, dynamic>{},
        'content': '',
      });
      expect(draft.toolCallId, isNull);
      expect(draft.status, kPartStatusCompleted);
      expect(draft.content, '');
    });

    test('non-map arguments are preserved in metadata', () {
      final draft = toolPartDraftFromLegacyEvent({
        'id': 'x',
        'name': 'tool',
        'arguments': 'not-a-map',
        'content': null,
      });
      expect(draft.argumentsJson, '{}');
      expect(draft.status, kPartStatusInterrupted);
      final metadata = jsonDecode(draft.metadataJson!) as Map<String, dynamic>;
      expect(metadata['legacyArguments'], 'not-a-map');
      expect(metadata['legacyKeys'], ['arguments']);
    });

    test('non-string content is serialized and flagged', () {
      final draft = toolPartDraftFromLegacyEvent({
        'id': 'x',
        'name': 'tool',
        'arguments': <String, dynamic>{},
        'content': {'unexpected': true},
      });
      expect(draft.content, '{"unexpected":true}');
      final metadata = jsonDecode(draft.metadataJson!) as Map<String, dynamic>;
      expect(metadata['legacyContentSerialized'], isTrue);
    });

    test('round-trips a stored part back to the event shape', () {
      final draft = toolPartDraftFromLegacyEvent({
        'id': 'call_1',
        'name': 'web_fetch',
        'arguments': {'url': 'https://example.com'},
        'content': 'page',
        'approvalState': 'auto',
        'webFetchSource': 'Local',
      });
      final event = toolEventFromStoredPart(
        toolCallId: draft.toolCallId,
        toolName: draft.toolName,
        argumentsJson: draft.argumentsJson,
        content: draft.content,
        approvalState: draft.approvalState,
        metadataJson: draft.metadataJson,
      );
      expect(event['id'], 'call_1');
      expect(event['name'], 'web_fetch');
      expect(event['arguments'], {'url': 'https://example.com'});
      expect(event['content'], 'page');
      expect(event['approvalState'], 'auto');
      expect(event['webFetchSource'], 'Local');
    });
  });
}
