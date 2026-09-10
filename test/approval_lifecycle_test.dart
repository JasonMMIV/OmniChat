// P0-2 Phase-1 approval lifecycle (kernel path): a synthetic tool-result
// upsert that rewrites an event which already carries `approvalState`
// (written by the approval gate as Pending) must preserve the state —
// otherwise the approval card loses its lifecycle record and the pause
// detection in `ChatActions._buildPhase1Hooks` misfires.
//
// Also locks the P0-3 `resumeRun` dispatch contract constants: the
// ask_user protocol type strings the facade dispatches on.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:OmniChat/core/services/chat/chat_service.dart';
import 'package:OmniChat/core/services/chat/ask_user_models.dart';
import 'package:OmniChat/core/services/agent/approval.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dataDirectory;
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() async {
    dataDirectory = await Directory.systemTemp.createTemp(
      'omnichat_approval_lifecycle_',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
          if (call.method == 'getApplicationSupportDirectory' ||
              call.method == 'getApplicationDocumentsDirectory') {
            return dataDirectory.path;
          }
          return null;
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    await Hive.close();
    if (await dataDirectory.exists()) {
      await dataDirectory.delete(recursive: true);
    }
  });

  test('result upsert preserves the Pending approvalState', () async {
    final service = ChatService();
    await service.init();

    const messageId = 'assistant-message';
    // The approval gate marks the event Pending with the approval-required
    // content (tool NOT executed).
    await service.upsertToolEvent(
      messageId,
      id: 'call_1',
      name: 'file_write',
      arguments: {'path': 'out.txt'},
      content: buildApprovalPendingContent(toolName: 'file_write'),
      approvalState: approvalStatePending,
    );
    expect(
      service
          .getToolEvents(messageId)
          .firstWhere((e) => e['id'] == 'call_1')['approvalState'],
      approvalStatePending,
    );

    // The kernel's synthetic toolResults upsert (or the approve-path result
    // upsert) rewrites the same event id WITHOUT an explicit approvalState:
    // the previously persisted state must survive.
    await service.upsertToolEvent(
      messageId,
      id: 'call_1',
      name: 'file_write',
      arguments: {'path': 'out.txt'},
      content: 'file written',
    );
    final event = service
        .getToolEvents(messageId)
        .firstWhere((e) => e['id'] == 'call_1');
    expect(event['approvalState'], approvalStatePending);
    expect(event['content'], 'file written');
  });

  test('explicit approvalState on the upsert still wins over the old value',
      () async {
    final service = ChatService();
    await service.init();

    const messageId = 'assistant-message';
    await service.upsertToolEvent(
      messageId,
      id: 'call_2',
      name: 'file_read',
      arguments: const {},
      content: buildApprovalPendingContent(toolName: 'file_read'),
      approvalState: approvalStatePending,
    );
    // The resume path flips the state explicitly.
    await service.upsertToolEvent(
      messageId,
      id: 'call_2',
      name: 'file_read',
      arguments: const {},
      content: 'result',
      approvalState: approvalStateApproved,
    );
    expect(
      service
          .getToolEvents(messageId)
          .firstWhere((e) => e['id'] == 'call_2')['approvalState'],
      approvalStateApproved,
    );
  });

  test(
      'P1-3 fix: reasoning-echo extras survive the answered ask_user upsert',
      () async {
    final service = ChatService();
    await service.init();

    const messageId = 'assistant-message';
    // The stream driver persists the tool call carrying the round's
    // reasoning-echo extras (DeepSeek thinking mode).
    await service.upsertToolEvent(
      messageId,
      id: 'call_ask',
      name: 'ask_user',
      arguments: const {
        'questions': [
          {'id': 'q1', 'question': 'Which?', 'options': ['A', 'B']},
        ],
      },
      content: null,
      extras: const {
        'reasoning_content': 'let me think about the question',
      },
    );
    expect(
      service
          .getToolEvents(messageId)
          .firstWhere((e) => e['id'] == 'call_ask')['reasoning_content'],
      'let me think about the question',
    );

    // The answer upsert rewrites the same event (same flow as
    // resumeAfterAskUserAnswer) — the persisted reasoning-echo extra must
    // survive so the §3.11 replay can re-attach it.
    await service.upsertToolEvent(
      messageId,
      id: 'call_ask',
      name: 'ask_user',
      arguments: const {},
      content: '{"type":"ask_user_answer"}',
    );
    final event = service
        .getToolEvents(messageId)
        .firstWhere((e) => e['id'] == 'call_ask');
    expect(event['content'], '{"type":"ask_user_answer"}');
    expect(
      event['reasoning_content'],
      'let me think about the question',
    );
  });

  test('ask_user pending/answered protocol strings are stable', () {
    expect(askUserToolName, 'ask_user');
    expect(askUserPendingType, 'ask_user_pending');
    expect(askUserAnswerType, 'ask_user_answer');
  });
}
