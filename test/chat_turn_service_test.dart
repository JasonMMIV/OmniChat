import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/models/assistant.dart';
import 'package:OmniChat/core/models/chat_message.dart';
import 'package:OmniChat/core/models/conversation.dart';
import 'package:OmniChat/core/providers/model_provider.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/chat/chat_service.dart';
import 'package:OmniChat/core/services/chat/chat_turn_service.dart';

// 測試用 Dummy（沿用 voice_chat_windows_test.dart 的 implements + noSuchMethod
// 模式）：避免實例化真 SettingsProvider/ChatService 時觸發 SharedPreferences、
// Haptics、FontLoader 等平台副作用。
class TestChatService extends ChangeNotifier implements ChatService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 測試用 ChatService stub：僅覆寫 getToolEvents（工具重放測試用），
/// 其餘走 noSuchMethod（同 TestChatService 模式）。
class ToolEventChatService extends ChangeNotifier implements ChatService {
  ToolEventChatService(this.eventsByMessage);

  final Map<String, List<Map<String, dynamic>>> eventsByMessage;

  @override
  List<Map<String, dynamic>> getToolEvents(String assistantMessageId) =>
      eventsByMessage[assistantMessageId] ?? const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TestSettingsProvider extends ChangeNotifier implements SettingsProvider {
  @override
  bool get searchEnabled => false;

  @override
  bool get replayToolResults => false;

  @override
  int? get thinkingBudget => null;

  @override
  ProviderConfig getProviderConfig(String key, {String? defaultName}) =>
      ProviderConfig.defaultsFor(key, displayName: defaultName);

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
  String? reasoningText,
}) {
  return ChatMessage(
    id: id,
    role: role,
    content: content,
    conversationId: conversationId,
    groupId: groupId,
    version: version,
    reasoningText: reasoningText,
  );
}

Future<BuildContext> _pumpContext(WidgetTester tester) async {
  // PromptTransformer.buildPlaceholders 需要 Localizations.localeOf(context)，
  // 故包一層 MaterialApp 取得真實 context。
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

  group('ChatTurnService.buildApiMessages', () {
    test('maps roles and drops empty content', () {
      final service = ChatTurnService(chatService: TestChatService());
      final conversation = Conversation(title: 't');
      final api = service.buildApiMessages(
        conversation: conversation,
        messages: [
          _msg('user', 'hi', conversation.id),
          _msg('assistant', 'yo', conversation.id),
          _msg('user', '', conversation.id),
        ],
        versionSelections: {},
      );

      expect(api, hasLength(2));
      expect(api[0], {'role': 'user', 'content': 'hi'});
      expect(api[1], {'role': 'assistant', 'content': 'yo'});
    });

    test('collapses grouped versions to the selected one', () {
      final service = ChatTurnService(chatService: TestChatService());
      final conversation = Conversation(title: 't');
      const group = 'g1';
      final api = service.buildApiMessages(
        conversation: conversation,
        messages: [
          _msg('user', 'v0', conversation.id, groupId: group, version: 0),
          _msg('user', 'v1', conversation.id, groupId: group, version: 1),
          _msg('user', 'v2', conversation.id, groupId: group, version: 2),
        ],
        versionSelections: {group: 1},
      );

      expect(api, hasLength(1));
      expect(api.single['content'], 'v1');
    });
  });

  group('ChatTurnService.prepareTurnRequest (system prompt injection)', () {
    testWidgets(
      'injects assistant system prompt at index 0 without runtime type error',
      (tester) async {
        // 回歸測試：Phase 3 曾因 buildApiMessages 的 map literal 型別推斷為
        // Map<String, String>，導致此 insert 拋出
        // 「type '_Map<String, dynamic>' is not a subtype of type
        // 'Map<String, String>' of 'element'」，voice chat 卡在 listening。
        final context = await _pumpContext(tester);
        final service = ChatTurnService(chatService: TestChatService());
        final conversation = Conversation(title: 't');
        const assistant = Assistant(
          id: 'a1',
          name: 'TestBot',
          systemPrompt: 'You are {assistant_name} running {model_id}.',
        );

        final request = service.prepareTurnRequest(
          conversation: conversation,
          messages: [
            _msg('user', 'hello', conversation.id),
            _msg('assistant', 'hi', conversation.id),
          ],
          versionSelections: {},
          providerKey: 'OpenAI',
          modelId: 'gpt-4o',
          settings: TestSettingsProvider(),
          assistant: assistant,
          context: context,
          userNickname: 'tester',
        );

        expect(request.apiMessages.first['role'], 'system');
        final sys = request.apiMessages.first['content'] as String;
        expect(sys, contains('TestBot'));
        expect(sys, contains('gpt-4o'));
        expect(sys, isNot(contains('{assistant_name}')));
        expect(request.apiMessages, hasLength(3));
        expect(request.apiMessages[1]['content'], 'hello');
        expect(request.apiMessages[2]['role'], 'assistant');
      },
    );

    testWidgets('leaves messages untouched when assistant has no system prompt',
        (tester) async {
      final context = await _pumpContext(tester);
      final service = ChatTurnService(chatService: TestChatService());
      final conversation = Conversation(title: 't');
      const assistant = Assistant(id: 'a1', name: 'TestBot');

      final request = service.prepareTurnRequest(
        conversation: conversation,
        messages: [
          _msg('user', 'hello', conversation.id),
        ],
        versionSelections: {},
        providerKey: 'OpenAI',
        modelId: 'gpt-4o',
        settings: TestSettingsProvider(),
        assistant: assistant,
        context: context,
        userNickname: 'tester',
      );

      expect(request.apiMessages, hasLength(1));
      expect(request.apiMessages.first['role'], 'user');
      expect(request.apiMessages.first['content'], 'hello');
    });
  });

  group('ChatTurnService.buildApiMessages tool replay reasoning echo', () {
    test('falls back to the assistant reasoningText when events carry none',
        () {
      final service = ChatTurnService(
        chatService: ToolEventChatService({
          'a1': [
            {
              'id': 'call_1',
              'name': 'web_search',
              'arguments': {'query': 'x'},
              'content': 'results',
            },
          ],
        }),
      );
      final conversation = Conversation(title: 't', id: 'c1');
      final api = service.buildApiMessages(
        conversation: conversation,
        messages: [
          _msg('user', 'search x', conversation.id),
          _msg('assistant', '', conversation.id,
              id: 'a1', reasoningText: 'thinking about the search'),
          _msg('user', 'go on', conversation.id),
        ],
        versionSelections: {},
        includeToolMessages: true,
      );

      // user / assistant(tool_calls + reasoning_content) / tool / user
      expect(api, hasLength(4));
      final assistantMsg = api[1] as Map;
      expect(assistantMsg['tool_calls'], hasLength(1));
      expect(assistantMsg['reasoning_content'], 'thinking about the search');
    });

    test('event reasoning_content wins over the reasoningText fallback', () {
      final service = ChatTurnService(
        chatService: ToolEventChatService({
          'a1': [
            {
              'id': 'call_1',
              'name': 'web_search',
              'arguments': {'query': 'x'},
              'content': 'results',
              'reasoning_content': 'event echo',
            },
          ],
        }),
      );
      final conversation = Conversation(title: 't', id: 'c1');
      final api = service.buildApiMessages(
        conversation: conversation,
        messages: [
          _msg('user', 'search x', conversation.id),
          _msg('assistant', '', conversation.id,
              id: 'a1', reasoningText: 'message reasoning'),
          _msg('user', 'go on', conversation.id),
        ],
        versionSelections: {},
        includeToolMessages: true,
      );

      final assistantMsg = api[1] as Map;
      expect(assistantMsg['reasoning_content'], 'event echo');
    });
  });
}
