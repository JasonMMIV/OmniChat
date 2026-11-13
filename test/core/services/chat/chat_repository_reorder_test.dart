// SQLite `moveMessageBefore` tests (docs/anybuff_queue_sendnow_import_plan.md
// §4.2 / §6.1: `chat_repository_reorder_test.dart`).
//
// Pins the ordinal swap that makes the steering echo replay *before* the
// assistant message (F15), including the UNIQUE(conversation_id, ordinal)
// safe three-step swap and the no-op guards.

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/models/chat_message.dart';
import 'package:OmniChat/core/models/conversation.dart';
import 'package:OmniChat/core/services/chat/storage/app_database.dart';
import 'package:OmniChat/core/services/chat/storage/chat_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late ChatRepository repo;

  setUp(() {
    db = AppDatabase.inMemory();
    repo = ChatRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<Conversation> createConversation() async {
    final conversation = Conversation(
      title: 'queue reorder',
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 2),
    );
    await repo.upsertConversation(conversation);
    return conversation;
  }

  Future<ChatMessage> addMessage(String conversationId, String content) {
    return repo.appendMessage(
      ChatMessage(
        role: 'user',
        content: content,
        conversationId: conversationId,
        timestamp: DateTime(2026, 1, 1),
      ),
    );
  }

  test('moves the echo immediately before the assistant (F15)', () async {
    final conversation = await createConversation();
    final user = await addMessage(conversation.id, 'question');
    final assistant = await addMessage(conversation.id, '');
    final echo = await addMessage(conversation.id, 'steer');

    // Initial order: user → assistant → echo (push-time position).
    expect(
      (await repo.getMessages(conversation.id)).map((m) => m.id),
      [user.id, assistant.id, echo.id],
    );

    final moved = await repo.moveMessageBefore(
      conversationId: conversation.id,
      messageId: echo.id,
      beforeMessageId: assistant.id,
    );
    expect(moved, isTrue);

    // Drain-time order: user → echo → assistant (replay-consistent).
    expect(
      (await repo.getMessages(conversation.id)).map((m) => m.id),
      [user.id, echo.id, assistant.id],
    );
  });

  test('is idempotent: an already-before echo keeps its place', () async {
    final conversation = await createConversation();
    final user = await addMessage(conversation.id, 'question');
    final assistant = await addMessage(conversation.id, '');
    final echo = await addMessage(conversation.id, 'steer');

    expect(
      await repo.moveMessageBefore(
        conversationId: conversation.id,
        messageId: echo.id,
        beforeMessageId: assistant.id,
      ),
      isTrue,
    );
    // A second (or late) drain must not flip the pair back.
    expect(
      await repo.moveMessageBefore(
        conversationId: conversation.id,
        messageId: echo.id,
        beforeMessageId: assistant.id,
      ),
      isTrue,
    );
    expect(
      (await repo.getMessages(conversation.id)).map((m) => m.id),
      [user.id, echo.id, assistant.id],
    );
  });

  test('no-op when both ids are the same', () async {
    final conversation = await createConversation();
    final message = await addMessage(conversation.id, 'only');
    final moved = await repo.moveMessageBefore(
      conversationId: conversation.id,
      messageId: message.id,
      beforeMessageId: message.id,
    );
    expect(moved, isFalse);
  });

  test('no-op when either row is missing', () async {
    final conversation = await createConversation();
    final message = await addMessage(conversation.id, 'only');
    expect(
      await repo.moveMessageBefore(
        conversationId: conversation.id,
        messageId: message.id,
        beforeMessageId: 'missing',
      ),
      isFalse,
    );
    expect(
      await repo.moveMessageBefore(
        conversationId: conversation.id,
        messageId: 'missing',
        beforeMessageId: message.id,
      ),
      isFalse,
    );
    expect(
      await repo.moveMessageBefore(
        conversationId: 'other-conversation',
        messageId: message.id,
        beforeMessageId: message.id,
      ),
      isFalse,
    );
  });

  test('keeps other conversations untouched', () async {
    final a = await createConversation();
    final b = Conversation(
      title: 'other',
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 2),
    );
    await repo.upsertConversation(b);
    final aUser = await addMessage(a.id, 'a-user');
    final aAssistant = await addMessage(a.id, '');
    final aEcho = await addMessage(a.id, 'a-echo');
    final bUser = await addMessage(b.id, 'b-user');

    await repo.moveMessageBefore(
      conversationId: a.id,
      messageId: aEcho.id,
      beforeMessageId: aAssistant.id,
    );

    expect(
      (await repo.getMessages(a.id)).map((m) => m.id),
      [aUser.id, aEcho.id, aAssistant.id],
    );
    expect(
      (await repo.getMessages(b.id)).map((m) => m.id),
      [bUser.id],
    );
  });
}
