import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/models/chat_message.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/chat/chat_service.dart';
import 'package:OmniChat/core/services/chat/storage/message_part_codec.dart';
import 'package:OmniChat/features/home/controllers/stream_controller.dart'
    as stream_ctrl;

class _StubChatService extends ChangeNotifier implements ChatService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  stream_ctrl.StreamController controller() {
    return stream_ctrl.StreamController(
      chatService: _StubChatService(),
      onStateChanged: () {},
      getSettingsProvider: SettingsProvider.new,
      getCurrentConversationId: () => 'convo',
    );
  }

  ChatMessage assistant({required bool streaming}) {
    return ChatMessage(
      id: 'assistant-1',
      role: 'assistant',
      content: streaming ? '' : 'partial answer',
      conversationId: 'convo',
      isStreaming: streaming,
    );
  }

  List<ToolPartSummary> pendingSummaries() => <ToolPartSummary>[
    ToolPartSummary(
      partId: 0,
      messageId: 'assistant-1',
      ordinal: 0,
      toolCallId: 'call-1',
      toolName: 'web_fetch',
      approvalState: kApprovalAuto,
      status: kPartStatusPending,
      contentLengthChars: 0,
      argumentsLengthChars: 32,
      argumentsPreview: '{"url":"https://example.com"}',
      updatedAt: DateTime(2026),
      eagerContent: null,
      eagerArgumentsJson: null,
    ),
  ];

  test('a finished message cannot keep a pending tool row spinning', () {
    final c = controller();
    final message = assistant(streaming: false);

    c.restoreMessageUiState(
      message,
      getToolPartSummariesFromDb: (_) => pendingSummaries(),
      getGeminiThoughtSigFromDb: (_) => null,
    );

    final part = c.toolParts[message.id]!.single;
    expect(part.content, isNull);
    expect(part.loading, isFalse);
  });

  test('a genuinely streaming message still shows the tool as loading', () {
    final c = controller();
    final message = assistant(streaming: true);

    c.restoreMessageUiState(
      message,
      getToolPartSummariesFromDb: (_) => pendingSummaries(),
      getGeminiThoughtSigFromDb: (_) => null,
    );

    expect(c.toolParts[message.id]!.single.loading, isTrue);
  });

  test('restored completed/interrupted parts stay lazy and never spin', () {
    final c = controller();
    final message = assistant(streaming: false);
    final summaries = <ToolPartSummary>[
      ToolPartSummary(
        partId: 0,
        messageId: message.id,
        ordinal: 0,
        toolCallId: 'read',
        toolName: 'file_read',
        approvalState: kApprovalAuto,
        status: kPartStatusCompleted,
        contentLengthChars: 4,
        argumentsLengthChars: 24,
        argumentsPreview: '{"path":"a.txt"}',
        updatedAt: DateTime(2026),
        eagerContent: null,
        eagerArgumentsJson: null,
      ),
      ToolPartSummary(
        partId: 1,
        messageId: message.id,
        ordinal: 1,
        toolCallId: 'fetch',
        toolName: 'web_fetch',
        approvalState: kApprovalAuto,
        status: kPartStatusInterrupted,
        contentLengthChars: 0,
        argumentsLengthChars: 32,
        argumentsPreview: '{"url":"https://example.com"}',
        updatedAt: DateTime(2026),
        eagerContent: null,
        eagerArgumentsJson: null,
      ),
    ];

    c.restoreMessageUiState(
      message,
      getToolPartSummariesFromDb: (_) => summaries,
      getGeminiThoughtSigFromDb: (_) => null,
    );

    final parts = c.toolParts[message.id]!;
    expect(parts, hasLength(2));
    expect(parts.first.content, isNull);
    expect(parts.first.contentLoaded, isFalse);
    expect(parts.first.loading, isFalse);
    expect(parts.first.status, kPartStatusCompleted);
    expect(parts.first.arguments, const {'path': 'a.txt'});
    expect(parts.last.loading, isFalse);
    expect(parts.last.status, kPartStatusInterrupted);
  });

  test('eager pending approval content does not show the loading spinner', () {
    final c = controller();
    final message = assistant(streaming: true);
    final approvalJson =
        '{"type":"approval_required","tool":"file_write"}';
    final summaries = <ToolPartSummary>[
      ToolPartSummary(
        partId: 0,
        messageId: message.id,
        ordinal: 0,
        toolCallId: 'write',
        toolName: 'file_write',
        approvalState: kApprovalPending,
        status: kPartStatusPending,
        contentLengthChars: approvalJson.length,
        argumentsLengthChars: 24,
        argumentsPreview: '{"path":"b.txt"}',
        updatedAt: DateTime(2026),
        eagerContent: approvalJson,
        eagerArgumentsJson: '{"path":"b.txt"}',
      ),
    ];

    c.restoreMessageUiState(
      message,
      getToolPartSummariesFromDb: (_) => summaries,
      getGeminiThoughtSigFromDb: (_) => null,
    );

    final part = c.toolParts[message.id]!.single;
    expect(part.loading, isFalse);
    expect(part.contentLoaded, isTrue);
    expect(part.content, approvalJson);
    expect(part.status, kPartStatusPending);
  });
}
