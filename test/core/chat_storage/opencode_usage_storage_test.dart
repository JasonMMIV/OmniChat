import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/models/chat_message.dart';
import 'package:OmniChat/core/models/conversation.dart';
import 'package:OmniChat/core/models/message_usage.dart';
import 'package:OmniChat/core/services/chat/storage/message_part_codec.dart';
import 'package:OmniChat/core/services/chat/storage/sqlite_chat_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late SqliteChatStorage storage;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'omnichat_opencode_usage_',
    );
    storage = SqliteChatStorage(
      directory: directory,
      appVersion: 'test',
      background: false,
    );
    await storage.initialize();
  });

  tearDown(() async {
    await storage.dispose();
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  test('usage artifact survives a storage reopen', () async {
    await storage.putConversation(
      Conversation(id: 'c1', title: 'Chat', createdAt: DateTime(2026)),
    );
    const usage = MessageUsage(
      costUsd: 0.0041,
      listCostUsd: 0.005,
      billingSource: 'balance',
      inputTokens: 13,
      outputTokens: 10,
      reasoningTokens: 4,
    );
    await storage.appendMessage(
      ChatMessage(
        id: 'm1',
        role: 'assistant',
        content: 'hello',
        conversationId: 'c1',
        totalTokens: 23,
        promptTokens: 13,
        completionTokens: 10,
        usageMetaJson: jsonEncode(usage.toJson()),
      ),
    );

    expect(storage.getOpenCodeUsage('m1')?.costUsd, 0.0041);

    await storage.dispose();
    storage = SqliteChatStorage(
      directory: directory,
      appVersion: 'test',
      background: false,
    );
    await storage.initialize();
    await storage.ensureConversationLoaded('c1');

    final restored = storage.getMessages('c1').single;
    expect(restored.usageMeta?.costUsd, 0.0041);
    expect(restored.usageMeta?.allowanceUsd, isNull);
    expect(storage.getOpenCodeUsage('m1')?.reasoningTokens, 4);
  });

  test(
    'usage survives a conversation reload after a sibling deletion',
    () async {
      await storage.putConversation(
        Conversation(id: 'c1', title: 'Chat', createdAt: DateTime(2026)),
      );
      const usage = MessageUsage(costUsd: 0.0041, billingSource: 'balance');
      await storage.appendMessage(
        ChatMessage(
          id: 'm0',
          role: 'user',
          content: 'hi',
          conversationId: 'c1',
        ),
      );
      await storage.appendMessage(
        ChatMessage(
          id: 'm1',
          role: 'assistant',
          content: 'hello',
          conversationId: 'c1',
          usageMetaJson: jsonEncode(usage.toJson()),
        ),
      );
      await storage.ensureConversationLoaded('c1');

      expect(await storage.deleteMessage('m0'), isTrue);

      final restored = storage.getMessages('c1').single;
      expect(restored.id, 'm1');
      expect(restored.usageMeta?.costUsd, 0.0041);
    },
  );

  test('message version copy does not inherit usage metadata', () async {
    await storage.putConversation(
      Conversation(id: 'c1', title: 'Chat', createdAt: DateTime(2026)),
    );
    const usage = MessageUsage(costUsd: 0.0041, billingSource: 'balance');
    await storage.appendMessage(
      ChatMessage(
        id: 'm1',
        role: 'assistant',
        content: 'v1',
        conversationId: 'c1',
        usageMetaJson: jsonEncode(usage.toJson()),
      ),
    );
    await storage.ensureConversationLoaded('c1');

    final copy = await storage.appendMessageVersion(
      messageId: 'm1',
      content: 'v2',
    );

    expect(copy, isNotNull);
    expect(copy!.usageMeta, isNull);
    final artifacts = await storage.repository.allProviderArtifactsOfKind(
      kOpenCodeUsageKind,
    );
    expect(artifacts.containsKey(copy.id), isFalse);
    expect(artifacts['m1'], isNotNull);
  });

  test('deleting a message removes its usage artifact', () async {
    await storage.putConversation(
      Conversation(id: 'c1', title: 'Chat', createdAt: DateTime(2026)),
    );
    const usage = MessageUsage(costUsd: 0.0041, billingSource: 'balance');
    await storage.appendMessage(
      ChatMessage(
        id: 'm1',
        role: 'assistant',
        content: 'hello',
        conversationId: 'c1',
        usageMetaJson: jsonEncode(usage.toJson()),
      ),
    );
    await storage.ensureConversationLoaded('c1');

    expect(await storage.deleteMessage('m1'), isTrue);

    final artifacts = await storage.repository.allProviderArtifactsOfKind(
      kOpenCodeUsageKind,
    );
    expect(artifacts.containsKey('m1'), isFalse);
  });

  test('setOpenCodeUsage updates the cached message', () async {
    await storage.putConversation(
      Conversation(id: 'c1', title: 'Chat', createdAt: DateTime(2026)),
    );
    await storage.appendMessage(
      ChatMessage(
        id: 'm1',
        role: 'assistant',
        content: 'hello',
        conversationId: 'c1',
      ),
    );
    await storage.ensureConversationLoaded('c1');

    const usage = MessageUsage(costUsd: 0);
    await storage.setOpenCodeUsage('m1', usage);

    expect(storage.getMessages('c1').single.usageMeta, isNotNull);
  });
}
