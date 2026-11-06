import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/core/models/memory_entry.dart';
import 'package:OmniChat/core/services/memory/memory_block_builder.dart';

MemoryEntry _entry({
  required String id,
  required String content,
  MemoryType type = MemoryType.identity,
  MemoryScope scope = MemoryScope.assistant,
  String? assistantId = 'a1',
  MemoryStatus status = MemoryStatus.active,
  DateTime? created,
  DateTime? updated,
}) => MemoryEntry(
  id: id,
  scope: scope,
  assistantId: scope == MemoryScope.assistant ? assistantId : null,
  type: type,
  status: status,
  content: content,
  source: MemorySource.manual,
  createdAt: created ?? DateTime(2026, 1, 1),
  updatedAt: updated ?? DateTime(2026, 1, 1),
);

void main() {
  test('renders empty type blocks as self-closing tags', () {
    final out = MemoryBlockBuilder.build(
      entries: [_entry(id: 'mem_1', content: 'likes tea')],
      includeToolInstructions: false,
    );
    expect(out, contains('<user_memory type="identity">'));
    expect(out, contains('<user_memory type="workflow"/>'));
    expect(out, contains('<user_memory type="voice"/>'));
    expect(out, contains('<user_memory type="instruction"/>'));
    expect(out, contains('- [2026-01-01] (assistant) likes tea'));
  });

  test('returns an empty string when there is nothing to inject', () {
    expect(
      MemoryBlockBuilder.build(
        entries: const <MemoryEntry>[],
        includeToolInstructions: false,
      ),
      isEmpty,
    );
    expect(
      MemoryBlockBuilder.build(
        entries: [
          _entry(id: 'mem_1', content: 'old', status: MemoryStatus.archived),
        ],
        includeToolInstructions: false,
      ),
      isEmpty,
    );
  });

  test('summary mode keeps the most recently updated entries', () {
    final entries = <MemoryEntry>[
      for (var i = 1; i <= 12; i++)
        _entry(
          id: 'mem_${i.toString().padLeft(2, '0')}',
          content: 'fact $i',
          updated: DateTime(2026, 1, i),
        ),
    ];
    final out = MemoryBlockBuilder.build(
      entries: entries,
      maxItemsPerType: 3,
      includeToolInstructions: false,
    );
    expect(out, contains('mode="summary" total="12" shown="3"'));
    expect(out, contains('fact 12'));
    expect(out, contains('fact 10'));
    expect(out, isNot(contains('fact 9')));
    expect(out, contains('memory_read'));
  });

  test('full injection types ignore the per-type cap', () {
    final entries = <MemoryEntry>[
      for (var i = 1; i <= 12; i++)
        _entry(id: 'mem_$i', content: 'fact $i', type: MemoryType.workflow),
    ];
    final out = MemoryBlockBuilder.build(
      entries: entries,
      maxItemsPerType: 3,
      fullInjectionTypes: {MemoryType.workflow},
      includeToolInstructions: false,
    );
    expect(out, isNot(contains('mode="summary"')));
    expect(out, contains('fact 1'));
    expect(out, contains('fact 12'));
    expect(
      RegExp(r'- \[2026-01-01\] (\(assistant\) )?fact').allMatches(out).length,
      12,
    );
  });

  test('sorts global before assistant, then createdAt, then id', () {
    final out = MemoryBlockBuilder.build(
      entries: [
        _entry(
          id: 'mem_b',
          content: 'assistant early',
          created: DateTime(2026, 1, 1),
        ),
        _entry(
          id: 'mem_c',
          content: 'global later',
          scope: MemoryScope.global,
          created: DateTime(2026, 2, 1),
        ),
        _entry(
          id: 'mem_a',
          content: 'assistant late',
          created: DateTime(2026, 3, 1),
        ),
      ],
      includeToolInstructions: false,
    );
    final globalIdx = out.indexOf('global later');
    final earlyIdx = out.indexOf('assistant early');
    final lateIdx = out.indexOf('assistant late');
    expect(globalIdx, greaterThan(-1));
    expect(globalIdx, lessThan(earlyIdx));
    expect(earlyIdx, lessThan(lateIdx));
    expect(out, contains('(assistant) assistant early'));
  });

  test('escapes markup and flattens whitespace', () {
    final out = MemoryBlockBuilder.build(
      entries: [
        _entry(
          id: 'mem_1',
          content: 'a & b <script>alert(1)</script>\n second   line',
        ),
      ],
      includeToolInstructions: false,
    );
    expect(out, contains('a &amp; b &lt;script&gt;alert(1)&lt;/script&gt;'));
    expect(out, isNot(contains('<script>')));
    expect(out, contains('second line'));
  });

  test('is idempotent for identical input', () {
    final entries = <MemoryEntry>[
      _entry(id: 'mem_1', content: 'likes tea'),
      _entry(
        id: 'mem_2',
        content: 'works on Flutter',
        type: MemoryType.workflow,
      ),
    ];
    final first = MemoryBlockBuilder.build(
      entries: entries,
      includeToolInstructions: false,
    );
    final second = MemoryBlockBuilder.build(
      entries: entries,
      includeToolInstructions: false,
    );
    expect(first, second);
  });

  test('tool instructions are gated but the memory body is not', () {
    final entries = [_entry(id: 'mem_1', content: 'likes tea')];
    final withTools = MemoryBlockBuilder.build(
      entries: entries,
      includeToolInstructions: true,
    );
    final withoutTools = MemoryBlockBuilder.build(
      entries: entries,
      includeToolInstructions: false,
    );
    expect(withTools, contains('## Memory tools'));
    expect(withoutTools, isNot(contains('## Memory tools')));
    expect(withoutTools, contains('likes tea'));
  });

  test('whole-block byte cap trims from the tail', () {
    final entries = <MemoryEntry>[
      for (var i = 0; i < 60; i++)
        _entry(
          id: 'mem_${i.toString().padLeft(2, '0')}',
          content: 'memory entry number $i with some padding text',
        ),
    ];
    final out = MemoryBlockBuilder.build(
      entries: entries,
      maxItemsPerType: 30,
      includeToolInstructions: false,
      byteCap: 1500,
    );
    expect(utf8.encode(out).length, lessThanOrEqualTo(1500));
    expect(
      out,
      contains('[some memory entries were omitted to fit the context budget]'),
    );
    expect(out, isNot(contains('memory entry number 59')));
  });

  test('the byte cap includes the tool instructions', () {
    final entries = <MemoryEntry>[
      for (var i = 0; i < 80; i++)
        _entry(
          id: 'mem_${i.toString().padLeft(2, '0')}',
          content: 'memory entry number $i with some padding text',
        ),
    ];
    final out = MemoryBlockBuilder.build(
      entries: entries,
      maxItemsPerType: 30,
      includeToolInstructions: true,
      byteCap: 4096,
    );
    expect(utf8.encode(out).length, lessThanOrEqualTo(4096));
    expect(out, contains('## Memory tools'));
  });

  test('a degenerate byte cap never exceeds the budget', () {
    final out = MemoryBlockBuilder.build(
      entries: [_entry(id: 'mem_1', content: 'likes tea')],
      includeToolInstructions: true,
      byteCap: 1,
    );
    expect(utf8.encode(out).length, lessThanOrEqualTo(1));
    expect(out, isEmpty);
  });
}
