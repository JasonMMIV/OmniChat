// P1-2 wiring tests: L0 tool-result pruning + L1 summary projection in
// `MessageBuilderService.buildApiMessages`, and the summary exemption in
// `applyContextLimit`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/models/assistant.dart';
import 'package:OmniChat/core/models/chat_message.dart';
import 'package:OmniChat/core/models/conversation.dart';
import 'package:OmniChat/core/services/chat/chat_service.dart';
import 'package:OmniChat/core/services/agent/compaction/history_compactor.dart';
import 'package:OmniChat/core/services/agent/compaction/tool_result_pruner.dart';
import 'package:OmniChat/features/home/services/message_builder_service.dart';

class ToolEventChatService extends ChangeNotifier implements ChatService {
  ToolEventChatService(this.eventsByMessage);

  final Map<String, List<Map<String, dynamic>>> eventsByMessage;

  @override
  List<Map<String, dynamic>> getToolEvents(String assistantMessageId) =>
      eventsByMessage[assistantMessageId] ?? const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ChatMessage _msg(
  String role,
  String content,
  String conversationId, {
  String? id,
  String? groupId,
  int version = 0,
}) {
  return ChatMessage(
    id: id,
    role: role,
    content: content,
    conversationId: conversationId,
    groupId: groupId,
    version: version,
  );
}

Future<BuildContext> _pumpContext(WidgetTester tester) async {
  late BuildContext captured;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) {
          captured = context;
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  return captured;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BuildContext context;
  setUpAll(() async {
    // Individual tests pump their own context where needed.
  });

  testWidgets('L0: oversized replayed tool results are middle-pruned',
      (tester) async {
    context = await _pumpContext(tester);
    final chatService = ToolEventChatService({
      'a1': [
        {
          'id': 'c1',
          'name': 'file_read',
          'arguments': {'path': 'big.txt'},
          'content': 'r' * 20_000,
        },
      ],
    });
    final builder = MessageBuilderService(
      chatService: chatService,
      contextProvider: context,
    );
    final messages = [
      _msg('user', 'read it', 'c1'),
      _msg('assistant', 'read the file', 'c1', id: 'a1'),
    ];
    final out = builder.buildApiMessages(
      messages: messages,
      versionSelections: const {},
      currentConversation: null,
      includeToolMessages: true,
      enableAutoCompaction: true,
    );
    final toolMsg = out.firstWhere((m) => m['role'] == 'tool');
    final content = toolMsg['content'] as String;
    expect(content.length, lessThan(20_000));
    expect(content, contains(toolResultPruneMarker.trim()));
    // With the kill-switch off, the raw content passes through.
    final outOff = builder.buildApiMessages(
      messages: messages,
      versionSelections: const {},
      currentConversation: null,
      includeToolMessages: true,
      enableAutoCompaction: false,
    );
    final toolMsgOff = outOff.firstWhere((m) => m['role'] == 'tool');
    expect((toolMsgOff['content'] as String).length, 20_000);
  });

  testWidgets('L1: compactBeforeIndex rewrites the head into one summary',
      (tester) async {
    context = await _pumpContext(tester);
    final chatService = ToolEventChatService({});
    final builder = MessageBuilderService(
      chatService: chatService,
      contextProvider: context,
    );
    final messages = [
      _msg('user', 'Plan the site', 'c1', id: 'm0'),
      _msg('assistant', 'I planned the site.', 'c1', id: 'm1'),
      _msg('user', 'Write index.html', 'c1', id: 'm2'),
      _msg('assistant', 'Wrote index.html for you.', 'c1', id: 'm3'),
      _msg('user', 'live prompt', 'c1', id: 'm4'),
    ];
    final conversation = Conversation(
      title: 't',
      messageIds: messages.map((m) => m.id!).toList(),
      compactBeforeIndex: 3, // [m0, m1, m2) → wait: 0..2 inclusive = 3 messages
    );

    final out = builder.buildApiMessages(
      messages: messages,
      versionSelections: const {},
      currentConversation: conversation,
      includeToolMessages: false,
      enableAutoCompaction: true,
    );

    // First message is the summary; live messages follow it.
    expect(out.first['content'], startsWith(summaryContentPrefix));
    final summaryText = out.first['content'] as String;
    expect(summaryText, contains('Plan the site'));
    expect(summaryText, contains('I planned the site.'));
    expect(out.any((m) => m['content'] == 'Wrote index.html for you.'), isTrue);
    expect(out.last['content'], 'live prompt');

    // Determinism: rebuild → identical bytes.
    final out2 = builder.buildApiMessages(
      messages: messages,
      versionSelections: const {},
      currentConversation: conversation,
      includeToolMessages: false,
      enableAutoCompaction: true,
    );
    expect(out2.first['content'], summaryText);

    // Kill-switch off → no summary, full history.
    final outOff = builder.buildApiMessages(
      messages: messages,
      versionSelections: const {},
      currentConversation: conversation,
      includeToolMessages: false,
      enableAutoCompaction: false,
    );
    expect(
      outOff.any((m) => (m['content'] as String).startsWith(summaryContentPrefix)),
      isFalse,
    );
    expect(outOff.length, 5);
  });

  testWidgets('L1 respects truncateIndex: compacted range starts after it',
      (tester) async {
    context = await _pumpContext(tester);
    final chatService = ToolEventChatService({});
    final builder = MessageBuilderService(
      chatService: chatService,
      contextProvider: context,
    );
    final messages = [
      _msg('user', 'dropped', 'c1', id: 'm0'),
      _msg('assistant', 'dropped reply', 'c1', id: 'm1'),
      _msg('user', 'kept head', 'c1', id: 'm2'),
      _msg('assistant', 'kept head reply', 'c1', id: 'm3'),
      _msg('user', 'live', 'c1', id: 'm4'),
    ];
    final conversation = Conversation(
      title: 't',
      messageIds: messages.map((m) => m.id!).toList(),
      truncateIndex: 2,
      compactBeforeIndex: 4,
    );
    final out = builder.buildApiMessages(
      messages: messages,
      versionSelections: const {},
      currentConversation: conversation,
      includeToolMessages: false,
      enableAutoCompaction: true,
    );
    expect(out.first['content'], startsWith(summaryContentPrefix));
    final summaryText = out.first['content'] as String;
    expect(summaryText, contains('kept head'));
    expect(summaryText, isNot(contains('dropped reply')));
    expect(out.last['content'], 'live');
  });

  test('applyContextLimit exempts the summary message', () {
    final apiMessages = <Map<String, dynamic>>[
      {'role': 'system', 'content': 'sys'},
      {'role': 'user', 'content': '$summaryContentPrefix\nsummary body'},
      for (var i = 0; i < 30; i++) ...[
        {'role': 'user', 'content': 'u$i'},
        {'role': 'assistant', 'content': 'a$i'},
      ],
    ];
    final builder = MessageBuilderService(
      chatService: ToolEventChatService({}),
      contextProvider: _FakeBuildContext(),
    );
    builder.applyContextLimit(
      apiMessages,
      _assistantWithLimit(10),
    );
    // Summary still present; only real messages were trimmed to 10.
    expect(
      apiMessages.any((m) =>
          (m['content'] as String).startsWith(summaryContentPrefix)),
      isTrue,
    );
    final nonSummary = apiMessages
        .where((m) =>
            m['role'] != 'system' &&
            !(m['content'] as String).startsWith(summaryContentPrefix))
        .length;
    expect(nonSummary, 10);
  });
}

Assistant _assistantWithLimit(int limit) => Assistant(
      id: 'test-assistant',
      name: 'Test Assistant',
      contextMessageSize: limit,
      limitContextMessages: true,
    );

class _FakeBuildContext implements BuildContext {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
