// L1 mechanical history compactor units: determinism, budgets, recent
// exemption, tool-call one-liners, and the pinned knowledge block.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/core/services/agent/compaction/history_compactor.dart';

Map<String, dynamic> user(String c) => {'role': 'user', 'content': c};
Map<String, dynamic> assistant(String c) => {'role': 'assistant', 'content': c};

Map<String, dynamic> assistantWithTool(String name, Map<String, dynamic> args,
    {String content = '\n\n'}) {
  return {
    'role': 'assistant',
    'content': content,
    'tool_calls': [
      {
        'id': 'c_${name}_${args.hashCode}',
        'type': 'function',
        'function': {'name': name, 'arguments': jsonEncode(args)},
      }
    ],
  };
}

Map<String, dynamic> toolMsg(String name, String c) => {
      'role': 'tool',
      'name': name,
      'tool_call_id': 'x',
      'content': c,
    };

void main() {
  group('compactHistoryMessages', () {
    test('empty input → null', () {
      expect(compactHistoryMessages(const []), isNull);
    });

    test('deterministic: same input → byte-identical summary', () {
      final messages = [
        user('Plan the report'),
        assistantWithTool('file_read', {'path': 'notes.md'}),
        toolMsg('file_read', 'contents of notes'),
        assistant('I read the notes and drafted the outline.'),
      ];
      final a = compactHistoryMessages(messages)!;
      final b = compactHistoryMessages(messages)!;
      expect(a['content'], b['content']);
    });

    test('envelope shape: summary + knowledge block + disclaimer', () {
      final messages = [
        user('Write the landing page'),
        assistantWithTool('file_write', {'path': 'index.html'}),
        toolMsg('file_write', 'Wrote 1024 bytes to index.html'),
        assistant('Done, the page is live.'),
      ];
      final summary = compactHistoryMessages(messages)!;
      final text = summary['content'] as String;
      expect(summary['role'], 'user');
      expect(text, startsWith('<conversation_summary>'));
      expect(text, contains('<historical_memory>'));
      expect(text, contains('Historical memory only.'));
      expect(text, contains('<knowledge_memory>'));
      expect(text, contains('Goal: Write the landing page'));
      expect(text, contains('Edits Made:'));
      expect(text, contains('- index.html'));
    });

    test('tool calls become one-liners; plain results are dropped', () {
      final messages = [
        user('look around'),
        assistantWithTool('file_read', {'path': 'a.txt'}),
        toolMsg('file_read', 'plain result body'),
        assistantWithTool('file_search', {'pattern': '*.py'}),
        assistant('found them'),
      ];
      final text = compactHistoryMessages(messages)!['content'] as String;
      expect(text, contains('inspected files: a.txt'));
      expect(text, contains('searched files: *.py'));
      expect(text, isNot(contains('plain result body')));
    });

    test('error tool results are preserved (truncated)', () {
      final messages = [
        user('do it'),
        assistantWithTool('file_write', {'path': 'x.txt'}),
        toolMsg('file_write', 'Error: workspace boundary violation — '
            'path out of workspace. ${'z' * 500}'),
      ];
      final text = compactHistoryMessages(messages)!['content'] as String;
      expect(text, contains('Tool error from file_write: Error:'));
      expect(text, contains('workspace boundary violation'));
    });

    test('budgets: newest entries kept, old user prompts evicted first', () {
      // 30 user prompts of ~3k tokens each — the 50k user budget keeps only
      // the newest ~16.
      final messages = <Map<String, dynamic>>[
        for (var i = 0; i < 30; i++) ...[
          user('question $i ${'q' * 9000}'),
          assistant('answer $i'),
        ],
      ];
      final text = compactHistoryMessages(messages)!['content'] as String;
      expect(text, contains('question 29'));
      expect(text, isNot(contains('question 0 ')));
    });

    test('recent exemption: newest assistant prose keeps more text', () {
      final big = 'r' * 9000; // 3000 tokens: > 1.3k cap, < 6k exempt cap
      final messages = <Map<String, dynamic>>[
        user('q1'),
        // 7 old assistants — only the 5 newest are exempt from the 1.3k cap.
        for (var i = 0; i < 7; i++) assistant('OLD$i:$big'),
        user('q2'),
        assistant('RECENT:$big'),
      ];
      final text = compactHistoryMessages(messages)!['content'] as String;
      // The newest assistant entry (6k exempt cap) survives whole.
      expect(text, contains('RECENT:$big'));
      // The oldest entries fall back to the 1.3k cap and are truncated.
      expect(text, contains('OLD0:'));
      expect(text, contains('[...truncated'));
    });

    test('image markers stripped from user entries, image note kept', () {
      final messages = [
        user('[image:/upload/pic.png]\nWhat is in this photo?'),
        assistant('A cat.'),
      ];
      final text = compactHistoryMessages(messages)!['content'] as String;
      expect(text, isNot(contains('[image:/upload/pic.png]')));
      expect(text, contains('[image(s) were attached]'));
      expect(text, contains('What is in this photo?'));
    });
  });

  group('buildKnowledgeBlock', () {
    test('goal skips short filler replies and markers', () {
      final block = buildKnowledgeBlock([
        user('continue'),
        assistant('ok'),
        user('[file:/tmp/x.pdf] the real goal'),
        assistant('working'),
      ]);
      expect(block, contains('Goal: the real goal'));
      expect(block, isNot(contains('[file:')));
    });

    test('Files Inspected dedupes paths, capped at 25', () {
      final messages = <Map<String, dynamic>>[
        for (var i = 0; i < 30; i++)
          assistantWithTool('file_read', {'path': 'file$i.txt'}),
      ];
      final block = buildKnowledgeBlock(messages);
      expect(block, contains('Files Inspected:'));
      expect('- file0.txt'.allMatches(block).length, 1);
      expect('- file29.txt'.allMatches(block).length, 0); // capped at 25
      expect('- file24.txt'.allMatches(block).length, 1);
    });

    test('Next Action falls back to the latest assistant text (≤200 chars)', () {
      final block = buildKnowledgeBlock([
        user('go'),
        assistant('early words'),
        assistant('${'n' * 500}'),
      ]);
      expect(block, contains('Next Action:'));
      final nextLine =
          block.split('Next Action: ').last.split('\n').first;
      expect(nextLine.length, lessThanOrEqualTo(200));
    });

    test('huge goal is capped at 2400 chars', () {
      final block = buildKnowledgeBlock([
        user('${'g' * 8000}'),
      ]);
      expect(block, contains('Goal:'));
      final goalLine = block.split('Goal: ').last.split('\n').first;
      expect(goalLine.length, lessThanOrEqualTo(2401)); // 2400 + ellipsis
    });

    test('whole-block token cap drops trailing sections', () {
      final longPathFor = (int i) => 'd$i/${'p' * 140}/file.txt'; // ~150 chars, unique
      final block = buildKnowledgeBlock([
        user('${'g' * 2400}'), // ~800 tokens
        for (var i = 0; i < 30; i++)
          assistantWithTool('file_read', {'path': longPathFor(i)}),
      ]);
      // Goal + 25 unique long paths exceeds the 2k cap → trailing sections
      // are dropped until it fits; the pinned Goal survives.
      expect(block, isNotEmpty);
      expect(block, contains('Goal:'));
      expect(block, isNot(contains('Files Inspected:')));
    });
  });

  group('summarizeToolCall', () {
    test('one-liners for OmniChat tool names', () {
      expect(
        summarizeToolCall('file_read', {'path': 'a.md'}),
        'inspected files: a.md',
      );
      expect(
        summarizeToolCall('file_write', {'path': 'b.html'}),
        'wrote file: b.html',
      );
      expect(
        summarizeToolCall('file_edit', {'path': 'c.txt'}),
        'edited file: c.txt',
      );
      expect(
        summarizeToolCall('search_web', {'query': 'flutter hive'}),
        'web search for "flutter hive"',
      );
      expect(summarizeToolCall('mystery_tool', {}), 'used tool mystery_tool');
    });
  });
}
