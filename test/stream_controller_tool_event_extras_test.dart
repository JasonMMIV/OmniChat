// Regression tests for the P1-3 reasoning-echo WRITE side (2026-09-11):
// `StreamController.handleToolCallsChunk` must persist the toolCalls
// chunk's `assistantExtras` (reasoning-echo fields) onto the placeholder
// tool events so the §3.11 cross-turn replay can re-attach
// `reasoning_content` after an ask_user / approval resume. The v1.8 fix
// read assistantExtras from tool-RESULT chunks — which never carry them —
// so nothing was ever persisted and DeepSeek-family thinking mode kept
// rejecting resumed requests with "The `reasoning_content` in the thinking
// mode must be passed back to the API." (HTTP 400).

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/models/chat_message.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/api/chat_stream_chunk.dart';
import 'package:OmniChat/core/services/chat/chat_service.dart';
import 'package:OmniChat/features/home/controllers/stream_controller.dart';

class _StubChatService extends ChangeNotifier implements ChatService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StubSettings extends ChangeNotifier implements SettingsProvider {
  @override
  bool get autoCollapseThinking => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

GenerationContext _ctx() {
  return GenerationContext(
    assistantMessage: ChatMessage(
      id: 'a1',
      role: 'assistant',
      content: '',
      conversationId: 'c1',
    ),
    apiMessages: const <Map<String, dynamic>>[],
    userImagePaths: const <String>[],
    providerKey: 'openai',
    modelId: 'deepseek-v4.1-flash',
    assistant: null,
    settings: _StubSettings(),
    config: ProviderConfig.defaultsFor('openai'),
    toolDefs: const <Map<String, dynamic>>[],
    supportsReasoning: true,
    enableReasoning: true,
    streamOutput: true,
  );
}

/// Runs one toolCalls chunk through handleToolCallsChunk and returns the
/// events passed to setToolEventsInDb (deduped placeholder list).
Future<List<Map<String, dynamic>>> _persistCallsChunk(
  Map<String, dynamic>? assistantExtras,
) async {
  final persisted = <Map<String, dynamic>>[];
  final controller = StreamController(
    chatService: _StubChatService(),
    onStateChanged: () {},
    getSettingsProvider: () => _StubSettings(),
    getCurrentConversationId: () => 'c1',
  );
  await controller.handleToolCallsChunk(
    ChatStreamChunk(
      content: '',
      isDone: false,
      totalTokens: 0,
      toolCalls: [
        ToolCallInfo(
          id: 'call_ask',
          name: 'ask_user',
          arguments: const <String, dynamic>{},
        ),
      ],
      assistantExtras: assistantExtras,
    ),
    StreamingState(_ctx()),
    updateReasoningSegmentsInDb: (String messageId, String json) async {},
    setToolEventsInDb:
        (String messageId, List<Map<String, dynamic>> events) async {
      persisted.addAll(events);
    },
    getToolEventsFromDb: (String messageId) => const <Map<String, dynamic>>[],
  );
  controller.dispose();
  return persisted;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('handleToolCallsChunk reasoning-echo persistence (P1-3 write side)',
      () {
    test('persists chunk assistantExtras onto the placeholder event',
        () async {
      final events = await _persistCallsChunk(<String, dynamic>{
        'reasoning_content': 'let me think about the question',
        'reasoning_details': [
          {'type': 'reasoning.text', 'text': 'thinking...'},
        ],
      });

      expect(events, hasLength(1));
      final event = events.single;
      expect(event['id'], 'call_ask');
      expect(event['name'], 'ask_user');
      expect(event['content'], isNull);
      expect(event['reasoning_content'], 'let me think about the question');
      expect(event['reasoning_details'], isA<List>());
    });

    test('chunk without assistantExtras persists a plain placeholder',
        () async {
      final events = await _persistCallsChunk(null);

      expect(events, hasLength(1));
      final event = events.single;
      expect(event.containsKey('reasoning_content'), isFalse);
      expect(event.containsKey('reasoning_details'), isFalse);
    });

    test('empty reasoning_content is not persisted (providers reject empty)',
        () async {
      final events = await _persistCallsChunk(<String, dynamic>{
        'reasoning_content': '',
      });

      expect(events, hasLength(1));
      expect(events.single.containsKey('reasoning_content'), isFalse);
    });
  });
}
