import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/models/chat_message.dart';
import 'package:OmniChat/core/models/conversation.dart';
import 'package:OmniChat/core/services/chat/chat_service.dart';
import 'package:OmniChat/features/home/services/message_builder_service.dart';

/// 建立真實 BuildContext（MessageBuilderService 的 contextProvider 是 required）。
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

/// 測試用 ChatService stub：僅覆寫 getToolEvents，其餘走 noSuchMethod。
class ToolEventChatService extends ChangeNotifier implements ChatService {
  ToolEventChatService(this.eventsByMessage);

  /// assistantMessageId -> tool events（與 ChatService.getToolEvents 同形）。
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MessageBuilderService.buildApiMessages includeToolMessages', () {
    testWidgets('off by default: no tool replay', (tester) async {
      final context = await _pumpContext(tester);
      final service = MessageBuilderService(
        chatService: ToolEventChatService({
          'a1': [
            {
              'id': 'call_1',
              'name': 'file_read',
              'arguments': {'path': 'main.dart'},
              'content': 'file contents',
            },
          ],
        }),
        contextProvider: context,
      );
      final conversation = Conversation(title: 't', id: 'c1');
      final api = service.buildApiMessages(
        messages: [
          _msg('user', 'read the file', 'c1'),
          _msg('assistant', 'done', 'c1', id: 'a1'),
          _msg('user', 'what did you find?', 'c1'),
        ],
        versionSelections: {},
        currentConversation: conversation,
      );
      // 預設不重放：只有純文字訊息。
      expect(api, hasLength(3));
      expect(api.where((m) => m['role'] == 'tool'), isEmpty);
    });

    testWidgets('replays tool_calls + tool results before the assistant reply',
        (tester) async {
      final context = await _pumpContext(tester);
      final service = MessageBuilderService(
        chatService: ToolEventChatService({
          'a1': [
            {
              'id': 'call_1',
              'name': 'file_read',
              'arguments': {'path': 'main.dart'},
              'content': 'file contents',
            },
            {
              'id': 'call_2',
              'name': 'web_search',
              'arguments': {'query': 'flutter'},
              'content': 'search results',
            },
          ],
        }),
        contextProvider: context,
      );
      final conversation = Conversation(title: 't', id: 'c1');
      final api = service.buildApiMessages(
        messages: [
          _msg('user', 'research this', 'c1'),
          _msg('assistant', 'here is my answer', 'c1', id: 'a1'),
          _msg('user', 'thanks', 'c1'),
        ],
        versionSelections: {},
        currentConversation: conversation,
        includeToolMessages: true,
      );

      // user / assistant(tool_calls) / tool / tool / assistant(reply) / user
      expect(api, hasLength(6));
      expect(api[0]['role'], 'user');
      expect(api[1]['role'], 'assistant');
      expect(api[1]['tool_calls'], hasLength(2));
      expect(api[1]['content'], '\n\n');
      final tc0 = api[1]['tool_calls'][0] as Map;
      expect(tc0['id'], 'call_1');
      expect(tc0['function']['name'], 'file_read');
      expect(api[2]['role'], 'tool');
      expect(api[2]['tool_call_id'], 'call_1');
      expect(api[2]['content'], 'file contents');
      expect(api[3]['role'], 'tool');
      expect(api[3]['tool_call_id'], 'call_2');
      expect(api[4]['role'], 'assistant');
      expect(api[4]['content'], 'here is my answer');
      expect(api[5]['role'], 'user');
      expect(api[5]['content'], 'thanks');
    });

    testWidgets('skips replay when any tool event is pending (no result yet)',
        (tester) async {
      final context = await _pumpContext(tester);
      final service = MessageBuilderService(
        chatService: ToolEventChatService({
          'a1': [
            {
              'id': 'call_1',
              'name': 'file_read',
              'arguments': {'path': 'main.dart'},
              'content': 'file contents',
            },
            {
              'id': 'call_2',
              'name': 'web_search',
              'arguments': {'query': 'flutter'},
              // content == null → pending（該輪尚未結束）
              'content': null,
            },
          ],
        }),
        contextProvider: context,
      );
      final conversation = Conversation(title: 't', id: 'c1');
      final api = service.buildApiMessages(
        messages: [
          _msg('user', 'research this', 'c1'),
          _msg('assistant', 'still working', 'c1', id: 'a1'),
        ],
        versionSelections: {},
        currentConversation: conversation,
        includeToolMessages: true,
      );

      // 有 pending event → 不重放，只保留純文字。
      expect(api, hasLength(2));
      expect(api.where((m) => m['role'] == 'tool'), isEmpty);
    });

    testWidgets('falls back to a synthetic call id when event id is empty',
        (tester) async {
      final context = await _pumpContext(tester);
      final service = MessageBuilderService(
        chatService: ToolEventChatService({
          'a1': [
            {
              'id': '',
              'name': 'file_read',
              'arguments': {'path': 'x.txt'},
              'content': 'data',
            },
          ],
        }),
        contextProvider: context,
      );
      final conversation = Conversation(title: 't', id: 'c1');
      final api = service.buildApiMessages(
        messages: [
          _msg('user', 'read x', 'c1'),
          _msg('assistant', 'done', 'c1', id: 'a1'),
        ],
        versionSelections: {},
        currentConversation: conversation,
        includeToolMessages: true,
      );

      // user / assistant(tool_calls) / tool / assistant(reply)
      expect(api, hasLength(4));
      final tc0 = api[1]['tool_calls'][0] as Map;
      final toolMsg = api[2] as Map;
      expect((tc0['id'] as String).startsWith('call_'), isTrue);
      expect(toolMsg['tool_call_id'], tc0['id']);
    });

    testWidgets('drops events with empty tool names', (tester) async {
      final context = await _pumpContext(tester);
      final service = MessageBuilderService(
        chatService: ToolEventChatService({
          'a1': [
            {
              'id': 'call_1',
              'name': '   ',
              'arguments': {'path': 'x.txt'},
              'content': 'data',
            },
          ],
        }),
        contextProvider: context,
      );
      final conversation = Conversation(title: 't', id: 'c1');
      final api = service.buildApiMessages(
        messages: [
          _msg('user', 'read x', 'c1'),
          _msg('assistant', 'done', 'c1', id: 'a1'),
        ],
        versionSelections: {},
        currentConversation: conversation,
        includeToolMessages: true,
      );

      // 名稱空的 event 被略過 → 無 tool_calls → 無重放。
      expect(api, hasLength(2));
      expect(api.where((m) => m['role'] == 'tool'), isEmpty);
    });
  });
}
