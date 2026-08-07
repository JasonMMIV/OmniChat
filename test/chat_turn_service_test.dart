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

class TestSettingsProvider extends ChangeNotifier implements SettingsProvider {
  @override
  bool get searchEnabled => false;

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
  String? groupId,
  int version = 0,
}) {
  return ChatMessage(
    role: role,
    content: content,
    conversationId: conversationId,
    groupId: groupId,
    version: version,
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
}
