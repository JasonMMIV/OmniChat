import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:OmniChat/core/providers/assistant_provider.dart';
import 'package:OmniChat/core/providers/mcp_provider.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/chat/chat_service.dart';
import 'package:OmniChat/core/services/mcp/mcp_tool_service.dart';
import 'package:OmniChat/features/home/services/tool_handler_service.dart';

class _McpProvider extends ChangeNotifier implements McpProvider {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _AssistantProvider extends ChangeNotifier implements AssistantProvider {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecordingChatService extends ChangeNotifier implements ChatService {
  final Map<String, Map<String, dynamic>> extrasById =
      <String, Map<String, dynamic>>{};

  @override
  Future<void> upsertToolEvent(
    String assistantMessageId, {
    required String id,
    required String name,
    required Map<String, dynamic> arguments,
    String? content,
    String? approvalState,
    Map<String, dynamic>? extras,
  }) async {
    if (extras != null) extrasById[id] = extras;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    // The handler persists a FileRecord after a successful write; return a
    // completed future instead of throwing from the base noSuchMethod.
    if (invocation.memberName.toString().contains('addMessageFileRecord')) {
      return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}

class _Settings extends ChangeNotifier implements SettingsProvider {
  @override
  bool get developerModeV1 => false;

  @override
  bool get approvalStrictModeV1 => false;

  @override
  Set<String> get approvalAlwaysAllowed => const <String>{};

  @override
  List<String> get shellAllowlist => const <String>[];

  @override
  bool isWorkspaceToolEnabled(String toolName) => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('file_write persists diff extras before the result upsert', (
    tester,
  ) async {
    final chat = _RecordingChatService();
    late BuildContext captured;
    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider<McpProvider>.value(
          value: _McpProvider(),
          child: ChangeNotifierProvider<AssistantProvider>.value(
            value: _AssistantProvider(),
            child: ChangeNotifierProvider<McpToolService>.value(
              value: McpToolService(),
              child: Builder(
                builder: (context) {
                  captured = context;
                  return const SizedBox.shrink();
                },
              ),
            ),
          ),
        ),
      ),
    );
    final service = ToolHandlerService(
      contextProvider: captured,
      chatService: chat,
    );

    await tester.runAsync(() async {
      final workspace = await Directory.systemTemp.createTemp(
        'omnichat_handler_diff_',
      );
      try {
        final handler = service.buildToolCallHandler(
          _Settings(),
          null,
          workspacePath: workspace.path,
          messageId: 'assistant-1',
        )!;

        final result = await handler(
          'file_write',
          {'path': 'note.txt', 'content': 'one\n'},
          toolCallId: 'call-1',
        );
        expect(result, contains('Wrote'));

        final extras = chat.extrasById['call-1'];
        expect(extras, isNotNull);
        expect(extras!['diffAdded'], 1);
        expect(extras['diffRemoved'], 0);
        expect(extras['diffText'], contains('+one'));
        expect(extras['diffText'], contains('+++ b/note.txt'));

        // No-op and read-only calls must not persist diff extras.
        await handler(
          'file_write',
          {'path': 'note.txt', 'content': 'one\n'},
          toolCallId: 'call-2',
        );
        expect(chat.extrasById.containsKey('call-2'), isFalse);

        await handler(
          'file_read',
          {'path': 'note.txt'},
          toolCallId: 'call-3',
        );
        expect(chat.extrasById.containsKey('call-3'), isFalse);
      } finally {
        if (await workspace.exists()) {
          await workspace.delete(recursive: true);
        }
      }
    });
  });

}
