import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/models/chat_message.dart';
import 'package:OmniChat/core/services/chat/chat_service.dart';
import 'package:OmniChat/features/home/controllers/stream_controller.dart';

class _SignatureRecordingChatService extends ChangeNotifier
    implements ChatService {
  String? stored;
  String? removedId;

  @override
  Future<void> setGeminiThoughtSignature(
    String assistantMessageId,
    String signature,
  ) async {
    stored = signature;
  }

  @override
  String? getGeminiThoughtSignature(String assistantMessageId) => stored;

  @override
  Future<void> removeGeminiThoughtSignature(String assistantMessageId) async {
    removedId = assistantMessageId;
    stored = null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

StreamController _controller(_SignatureRecordingChatService chatService) {
  return StreamController(
    chatService: chatService,
    onStateChanged: () {},
    getSettingsProvider: () => throw StateError('unused'),
    getCurrentConversationId: () => null,
  );
}

void main() {
  test('captures a signature comment into the artifact as bare JSON', () async {
    final chatService = _SignatureRecordingChatService();
    final controller = _controller(chatService);

    final cleaned = controller.captureGeminiThoughtSignature(
      'answer\n<!-- gemini_thought_signatures:{"text":{"k":"thoughtSignature","v":"sig"}} -->',
      'message-1',
    );

    expect(cleaned, 'answer');
    await Future<void>.delayed(Duration.zero);
    expect(chatService.stored, '{"text":{"k":"thoughtSignature","v":"sig"}}');
  });

  test('legacy full-comment artifacts are normalized on replay', () {
    final chatService = _SignatureRecordingChatService()
      ..stored =
          '<!-- gemini_thought_signatures:{"text":{"k":"thoughtSignature","v":"sig"}} -->';
    final controller = _controller(chatService);
    final message = ChatMessage(
      id: 'message-1',
      role: 'assistant',
      content: 'answer',
      conversationId: 'c1',
    );

    final replayed = controller.appendGeminiThoughtSignatureForApi(
      message,
      'answer',
    );

    expect(replayed, contains('gemini_thought_signatures:'));
    expect(replayed, contains('"v":"sig"'));
    expect(
      replayed,
      'answer\n<!-- gemini_thought_signatures:{"text":{"k":"thoughtSignature","v":"sig"}} -->',
    );
  });

  test('a retry clears both the cached and persisted signature', () async {
    final chatService = _SignatureRecordingChatService();
    final controller = _controller(chatService);
    controller.captureGeminiThoughtSignature(
      'answer\n<!-- gemini_thought_signatures:{"text":{"k":"thoughtSignature","v":"sig"}} -->',
      'message-1',
    );
    await Future<void>.delayed(Duration.zero);
    expect(chatService.stored, isNotNull);

    controller.clearGeminiThoughtSignature('message-1');
    await Future<void>.delayed(Duration.zero);

    expect(chatService.removedId, 'message-1');
    expect(chatService.stored, isNull);
    final message = ChatMessage(
      id: 'message-1',
      role: 'assistant',
      content: 'answer',
      conversationId: 'c1',
    );
    expect(
      controller.appendGeminiThoughtSignatureForApi(message, 'answer'),
      'answer',
    );
  });
}
