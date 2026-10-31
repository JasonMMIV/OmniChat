import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:OmniChat/core/models/chat_message.dart';
import 'package:OmniChat/core/services/chat/chat_service.dart';

void main() {
  late Directory tempDir;
  late Box<ChatMessage> box;
  const boxName = 'stale_streaming_probe';

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('omni_stale_stream_');
    Hive.init(tempDir.path);
    if (!Hive.isAdapterRegistered(0)) {
      Hive.registerAdapter(ChatMessageAdapter());
    }
  });

  setUp(() async {
    box = await Hive.openBox<ChatMessage>(boxName);
    await box.clear();
  });

  tearDown(() async {
    await box.close();
    await Hive.deleteBoxFromDisk(boxName);
  });

  tearDownAll(() async {
    await Hive.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  ChatMessage message(String id, {required bool streaming}) {
    return ChatMessage(
      id: id,
      role: 'assistant',
      content: 'partial answer',
      conversationId: 'convo',
      isStreaming: streaming,
      reasoningText: 'thinking',
      promptTokens: 123,
      processStartedAt: DateTime.utc(2026, 10, 30, 12),
    );
  }

  test('clears only stale isStreaming flags and preserves every field',
      () async {
    await box.putAll(<String, ChatMessage>{
      'stale': message('stale', streaming: true),
      'done': message('done', streaming: false),
      'stale2': message('stale2', streaming: true),
    });

    final repaired = await ChatService.repairStaleStreamingMessages(box);

    expect(repaired, 2);
    expect(box.get('stale')!.isStreaming, isFalse);
    expect(box.get('stale2')!.isStreaming, isFalse);
    expect(box.get('done')!.isStreaming, isFalse);
    // The sweep must only flip the flag — no content/reasoning loss.
    final stale = box.get('stale')!;
    expect(stale.content, 'partial answer');
    expect(stale.reasoningText, 'thinking');
    expect(stale.promptTokens, 123);
    expect(stale.processStartedAt, DateTime.utc(2026, 10, 30, 12));
  });

  test('returns zero and writes nothing when every message is settled',
      () async {
    await box.put('done', message('done', streaming: false));

    final repaired = await ChatService.repairStaleStreamingMessages(box);

    expect(repaired, 0);
    expect(box.get('done')!.isStreaming, isFalse);
  });
}
