import 'package:OmniChat/core/services/api/reasoning_details_replay.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('joins text fragments without separators and folds signature', () {
    final merged = mergeReasoningDetails([
      {
        'type': 'reasoning.text',
        'text': 'First ',
        'index': 0,
        'format': 'anthropic-claude-v1',
      },
      {
        'type': 'reasoning.text',
        'text': 'second',
        'index': 0,
        'format': 'anthropic-claude-v1',
      },
      {
        'type': 'reasoning.text',
        'signature': 'sig',
        'index': 0,
        'format': 'anthropic-claude-v1',
      },
      {
        'type': 'reasoning.text',
        'text': 'new block',
        'index': 1,
        'format': 'anthropic-claude-v1',
      },
    ]);

    expect(merged, hasLength(2));
    expect(merged!.first['text'], 'First second');
    expect(merged.first['signature'], 'sig');
    expect(merged.last['text'], 'new block');
  });

  test('replay drops signature-only leftovers but persistence keeps them', () {
    final raw = [
      {
        'type': 'reasoning.text',
        'text': 'body',
        'signature': 'sig',
        'format': 'anthropic-claude-v1',
      },
      {
        'type': 'reasoning.text',
        'signature': 'orphan',
        'format': 'anthropic-claude-v1',
      },
    ];

    expect(mergeReasoningDetails(raw), hasLength(2));
    final replay = normalizeReasoningDetailsForReplay(raw);
    expect(replay, hasLength(1));
    expect(replay!.single['text'], 'body');
  });

  test('snapshot endpoints replace a growing prefix, fragments append', () {
    final first = [
      {'type': 'reasoning.text', 'text': 'a', 'index': 0},
    ];
    final snapshot = [
      {'type': 'reasoning.text', 'text': 'a', 'index': 0},
      {'type': 'reasoning.text', 'text': 'b', 'index': 0},
    ];
    expect(
      appendReasoningDetails(first, snapshot, allowSnapshots: true),
      snapshot,
    );
    expect(appendReasoningDetails(first, first, allowSnapshots: true), first);

    final fragments = appendReasoningDetails(first, [
      {'type': 'reasoning.text', 'text': 'b', 'index': 0},
    ], allowSnapshots: false);
    expect(fragments, hasLength(2));
  });

  test('wire replay keeps one representation per target', () {
    final details = [
      {
        'type': 'reasoning.text',
        'text': 'think',
        'signature': 'sig',
        'format': 'anthropic-claude-v1',
      },
    ];
    final structured = <Map<String, dynamic>>[
      {
        'role': 'assistant',
        'reasoning_content': 'think',
        'reasoning_details': details,
      },
    ];
    normalizeReasoningEchoMessages(
      structured,
      preserveDetails: true,
      needsText: true,
    );
    expect(structured.single.containsKey('reasoning_content'), isFalse);
    expect(structured.single['reasoning_details'], isA<List>());

    final scalar = <Map<String, dynamic>>[
      {'role': 'assistant', 'reasoning_details': details},
    ];
    normalizeReasoningEchoMessages(
      scalar,
      preserveDetails: false,
      needsText: true,
    );
    expect(scalar.single.containsKey('reasoning_details'), isFalse);
    expect(scalar.single['reasoning_content'], 'think');
  });
}
