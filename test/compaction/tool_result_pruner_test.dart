// L0 tool-result middle pruner units (threshold / marker / surrogate / idempotent).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/core/services/agent/compaction/tool_result_pruner.dart';

void main() {
  group('pruneToolResultText', () {
    test('below threshold → unchanged (null)', () {
      expect(pruneToolResultText('short'), isNull);
      expect(
        pruneToolResultText('a' * toolResultPruneThresholdChars),
        isNull,
      );
    });

    test('above threshold → head + marker + tail', () {
      final content = '${'a' * 5000}MIDDLE${'b' * 5000}';
      final pruned = pruneToolResultText(content)!;
      expect(pruned.length, lessThan(content.length));
      expect(pruned, contains(toolResultPruneMarker.trim()));
      expect(pruned.startsWith('a' * 100), isTrue);
      expect(pruned.endsWith('b' * 100), isTrue);
      expect(pruned, isNot(contains('MIDDLE')));
    });

    test('keeps head 4096 and tail 1024 chars', () {
      final content =
          '${'h' * toolResultPruneHeadChars}${'m' * 4000}${'t' * toolResultPruneTailChars}';
      final pruned = pruneToolResultText(content)!;
      expect(pruned.startsWith('h' * toolResultPruneHeadChars), isTrue);
      expect(pruned.endsWith('t' * toolResultPruneTailChars), isTrue);
    });

    test('idempotent: pruned output is below the threshold', () {
      final content = 'x' * 100_000;
      final once = pruneToolResultText(content)!;
      final twice = pruneToolResultText(once);
      expect(twice, isNull);
    });

    test('surrogate-safe: does not split an emoji pair at the cut', () {
      // 4095 ascii chars then an emoji (surrogate pair) then padding.
      final content =
          '${'a' * (toolResultPruneHeadChars - 1)}😀${'b' * 5000}';
      final pruned = pruneToolResultText(content)!;
      final head = pruned.split(toolResultPruneMarker).first;
      // The cut backed off one code unit: the head ends before the emoji and
      // contains no lone surrogate.
      expect(
        head.codeUnits.any((c) => c >= 0xD800 && c <= 0xDFFF),
        isFalse,
      );
    });
  });

  group('applyToolResultMiddlePrune', () {
    test('prunes role:tool string contents in place, leaves others alone', () {
      final messages = <Map<String, dynamic>>[
        {'role': 'user', 'content': 'u' * 20_000},
        {'role': 'tool', 'tool_call_id': 'c1', 'content': 't' * 20_000},
        {'role': 'assistant', 'content': 'a' * 20_000},
        {'role': 'tool', 'tool_call_id': 'c2', 'content': 'small'},
      ];
      applyToolResultMiddlePrune(messages);
      expect(messages[0]['content'], 'u' * 20_000); // untouched
      expect((messages[1]['content'] as String).length,
          lessThan(20_000));
      expect(messages[1]['content'], contains(toolResultPruneMarker.trim()));
      expect(messages[2]['content'], 'a' * 20_000); // untouched
      expect(messages[3]['content'], 'small'); // untouched
    });
  });
}
