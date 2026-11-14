import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/models/chat_message.dart';
import 'package:OmniChat/core/models/conversation.dart';
import 'package:OmniChat/core/services/chat/storage/app_database.dart';
import 'package:OmniChat/core/services/chat/storage/chat_repository.dart';

void main() {
  late AppDatabase db;
  late ChatRepository repo;

  setUp(() {
    db = AppDatabase.inMemory();
    repo = ChatRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('subagent trace extras survive the SQLite summary round-trip', () async {
    final conversation = Conversation(
      title: 'Trace',
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 2),
    );
    await repo.upsertConversation(conversation);
    final assistant = await repo.appendMessage(
      ChatMessage(
        role: 'assistant',
        content: '',
        conversationId: conversation.id,
        timestamp: DateTime(2026, 1, 1),
      ),
    );

    const trace = <String, dynamic>{
      'status': 'max_steps',
      'profile': 'explore',
      'steps': 12,
      'toolCalls': 14,
      'tokens': 54210,
      'summarySource': 'wrap_up',
      'items': [
        {'t': 'file_grep', 'ms': 120, 'chars': 800},
      ],
    };
    await repo.upsertToolEvent(
      assistantMessageId: assistant.id,
      id: 'call-spawn',
      name: 'spawn_subagent',
      arguments: const {'task': 'x'},
      content: '{"type":"subagent_result","status":"max_steps"}',
      extras: const {'subagentTrace': trace, 'subagentTokens': 54210},
    );

    final summaries = await repo.getToolPartSummaries(assistant.id);
    expect(summaries, hasLength(1));
    final summary = summaries.single;
    expect(summary.subagentTrace, isNotNull);
    expect(summary.subagentTrace!['profile'], 'explore');
    expect((summary.subagentTrace!['items'] as List), hasLength(1));
    expect((summary.subagentTrace!['items'] as List).single, {
      't': 'file_grep',
      'ms': 120,
      'chars': 800,
    });

    final rows = await repo.partsForMessage(assistant.id);
    expect(rows.single.metadataJson, contains('subagentTokens'));
    expect(rows.single.metadataJson, contains('file_grep'));
  });
}
