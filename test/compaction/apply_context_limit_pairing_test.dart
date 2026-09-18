// Regression tests: the count-based context-limit trim must never split a
// replayed assistant `tool_calls` block from its `role:'tool'` results.
//
// Root cause of the DeepSeek v4 HTTP 400 ("Messages with role 'tool' must
// be a response to a preceding message with 'tool_calls'", wire-capture
// 2026-09-13): applyContextLimit cut at a plain message boundary, so a long
// conversation whose kept tail started mid tool-pair sent an orphaned tool
// message that strict OpenAI-compatible validators reject.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/models/assistant.dart';
import 'package:OmniChat/core/services/api/chat_api_service.dart';
import 'package:OmniChat/features/home/services/message_builder_service.dart';

import 'build_api_messages_compaction_test.dart' show ToolEventChatService;

Map<String, dynamic> _call(String id, int i) => {
      'id': '${id}_$i',
      'type': 'function',
      'function': {'name': 'file_read', 'arguments': '{"path":"a.txt"}'},
    };

/// A replayed tool-call assistant block followed by [count] tool results.
List<Map<String, dynamic>> _toolPair(String id, int count) => [
      {
        'role': 'assistant',
        'content': '\n\n',
        'tool_calls': [for (var i = 0; i < count; i++) _call(id, i)],
      },
      for (var i = 0; i < count; i++)
        {
          'role': 'tool',
          'name': 'file_read',
          'tool_call_id': '${id}_$i',
          'content': 'result $i',
        },
    ];

Assistant _assistantWithLimit(int limit) => Assistant(
      id: 'test-assistant',
      name: 'Test Assistant',
      contextMessageSize: limit,
      limitContextMessages: true,
    );

void main() {
  group('applyContextLimit pairing safety', () {
    test('cut landing between a tool pair drops the dangling tool results', () {
      final apiMessages = <Map<String, dynamic>>[
        {'role': 'system', 'content': 'sys'},
        {'role': 'user', 'content': 'u0'},
        ..._toolPair('c1', 2), // 3 messages, would straddle the cut
        {'role': 'user', 'content': 'u1'},
        {'role': 'assistant', 'content': 'a1'},
        {'role': 'user', 'content': 'latest'},
      ];
      MessageBuilderService(
        chatService: ToolEventChatService(const {}),
        contextProvider: _FakeBuildContext(),
      ).applyContextLimit(apiMessages, _assistantWithLimit(4));

      final tools = apiMessages.where((m) => m['role'] == 'tool').toList();
      // No orphaned tool result may survive: each must be preceded by the
      // assistant message that carries its call.
      final seenCallIds = <String>{};
      for (final m in apiMessages) {
        if (m['role'] == 'assistant') {
          final calls = m['tool_calls'];
          if (calls is List) {
            seenCallIds.addAll(calls.map((c) => c['id'].toString()));
          }
        } else if (m['role'] == 'tool') {
          final id = m['tool_call_id'].toString();
          expect(
            seenCallIds.contains(id),
            isTrue,
            reason: 'tool result $id must follow its assistant tool_calls',
          );
        }
      }
      // The c1 pair was split by the count budget → its dangling results
      // are dropped with it (the assistant carrier stays behind the cut).
      expect(tools.where((m) => m['tool_call_id'].startsWith('c1')), isEmpty);
      expect(apiMessages.last['content'], 'latest');
    });

    test('unsplittable pair at the boundary: list left untrimmed', () {
      final apiMessages = <Map<String, dynamic>>[
        {'role': 'system', 'content': 'sys'},
        {'role': 'user', 'content': 'u0'},
        {'role': 'assistant', 'content': 'a0'},
        ..._toolPair('c1', 1), // ends the list: only dangling results would remain
      ];
      MessageBuilderService(
        chatService: ToolEventChatService(const {}),
        contextProvider: _FakeBuildContext(),
      ).applyContextLimit(apiMessages, _assistantWithLimit(1));

      // Advancing the cut past the tool result leaves nothing to keep:
      // keep the whole list intact rather than send an orphan.
      expect(apiMessages.length, 5);
      expect(apiMessages.any((m) => m['role'] == 'tool'), isTrue);
    });

    test('normal counts still trim (no pairing interference)', () {
      final apiMessages = <Map<String, dynamic>>[
        {'role': 'system', 'content': 'sys'},
        for (var i = 0; i < 30; i++) ...[
          {'role': 'user', 'content': 'u$i'},
          {'role': 'assistant', 'content': 'a$i'},
        ],
      ];
      MessageBuilderService(
        chatService: ToolEventChatService(const {}),
        contextProvider: _FakeBuildContext(),
      ).applyContextLimit(apiMessages, _assistantWithLimit(10));
      final nonSystem = apiMessages.where((m) => m['role'] != 'system');
      expect(nonSystem.length, 10);
      expect(nonSystem.first['content'], 'u25');
      expect(nonSystem.last['content'], 'a29');
    });
  });

  group('transport-layer orphan repair (debugRepairOrphanToolMessages)', () {
    test('drops tool results whose call carrier is missing', () {
      final repaired = ChatApiService.debugRepairOrphanToolMessages([
        {'role': 'system', 'content': 'sys'},
        {'role': 'user', 'content': 'u0'},
        {
          'role': 'tool',
          'name': 'file_read',
          'tool_call_id': 'c1_0',
          'content': 'orphan',
        },
        {'role': 'user', 'content': 'latest'},
      ]);
      expect(repaired.any((m) => m['role'] == 'tool'), isFalse);
      expect(repaired.length, 3);
    });

    test('keeps well-formed pairs untouched', () {
      final pair = _toolPair('c1', 2);
      final repaired = ChatApiService.debugRepairOrphanToolMessages([
        {'role': 'system', 'content': 'sys'},
        {'role': 'user', 'content': 'u0'},
        ...pair,
        {'role': 'user', 'content': 'latest'},
      ]);
      expect(repaired.length, 6);
      expect(repaired.where((m) => m['role'] == 'tool').length, 2);
    });

    test('drops duplicate responses for an already-answered call', () {
      final repaired = ChatApiService.debugRepairOrphanToolMessages([
        ..._toolPair('c1', 1),
        {
          'role': 'tool',
          'name': 'file_read',
          'tool_call_id': 'c1_0',
          'content': 'duplicate',
        },
      ]);
      expect(repaired.where((m) => m['role'] == 'tool').length, 1);
    });

    test('tool result without a tool_call_id is dropped', () {
      final repaired = ChatApiService.debugRepairOrphanToolMessages([
        {'role': 'tool', 'name': 'x', 'content': 'no id'},
      ]);
      expect(repaired, isEmpty);
    });
  });

  test('end-to-end: trimmed request must pass the transport pairing guard',
      () {
    // Assemble the same shape the DeepSeek regression produced: a long
    // replayed history, a context-limit cut that would start mid-pair,
    // then the chat-completions transport entry. The full pipeline must
    // emit a request with no orphaned tool messages.
    final apiMessages = <Map<String, dynamic>>[
      {'role': 'system', 'content': 'sys'},
      {'role': 'user', 'content': 'u0'},
      ..._toolPair('c1', 2),
      {'role': 'user', 'content': 'u1'},
      {'role': 'assistant', 'content': 'a1'},
      {'role': 'user', 'content': 'latest'},
    ];
    MessageBuilderService(
      chatService: ToolEventChatService(const {}),
      contextProvider: _FakeBuildContext(),
    ).applyContextLimit(apiMessages, _assistantWithLimit(4));
    final wired = ChatApiService.debugRepairOrphanToolMessages(apiMessages);
    final seenCallIds = <String>{};
    for (final m in wired) {
      if (m['role'] == 'assistant') {
        final calls = m['tool_calls'];
        if (calls is List) {
          seenCallIds.addAll(calls.map((c) => c['id'].toString()));
        }
      } else if (m['role'] == 'tool') {
        expect(
          seenCallIds.contains(m['tool_call_id'].toString()),
          isTrue,
          reason: 'tool result must follow its assistant tool_calls',
        );
      }
    }
    // Every remaining tool result is answered exactly once by id.
    final toolIds = wired
        .where((m) => m['role'] == 'tool')
        .map((m) => m['tool_call_id'].toString())
        .toList();
    expect(toolIds.length, toolIds.toSet().length);
  });

  test('context limiting is disabled by default for new assistants', () {
    const a = Assistant(id: 'a', name: 'A');
    expect(a.limitContextMessages, isFalse);
  });

  test('round-trips persisted value; falls back to disabled when absent', () {
    expect(
      Assistant.fromJson({
        'id': 'a',
        'name': 'A',
        'limitContextMessages': true,
      }).limitContextMessages,
      isTrue,
      reason: 'explicitly persisted value must survive deserialization',
    );
    expect(
      Assistant.fromJson({'id': 'a', 'name': 'A'}).limitContextMessages,
      isFalse,
      reason: 'legacy entries without the key must not enable the trim',
    );
  });

  test('applyContextLimit keeps the full history when limiting is off', () {
    final apiMessages = <Map<String, dynamic>>[
      {'role': 'system', 'content': 'sys'},
      for (var i = 0; i < 200; i++) ...[
        {'role': 'user', 'content': 'u$i'},
        {'role': 'assistant', 'content': 'a$i'},
      ],
    ];
    MessageBuilderService(
      chatService: ToolEventChatService(const {}),
      contextProvider: _FakeBuildContext(),
    ).applyContextLimit(apiMessages, const Assistant(id: 'a', name: 'A'));
    expect(apiMessages, hasLength(401));
    expect(apiMessages.last['content'], 'a199');
  });
}

class _FakeBuildContext implements BuildContext {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
