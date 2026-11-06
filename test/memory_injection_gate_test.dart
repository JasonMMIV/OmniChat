import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/models/assistant.dart';
import 'package:OmniChat/core/models/chat_message.dart';
import 'package:OmniChat/core/models/conversation.dart';
import 'package:OmniChat/core/models/memory_entry.dart';
import 'package:OmniChat/core/providers/memory_provider.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/chat/chat_service.dart';
import 'package:OmniChat/core/services/chat/chat_turn_service.dart';
import 'package:OmniChat/core/services/memory/memory_block_builder.dart';
import 'package:OmniChat/core/services/memory_store.dart';

class _TestChatService extends ChangeNotifier implements ChatService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestSettingsProvider extends ChangeNotifier implements SettingsProvider {
  @override
  bool get searchEnabled => false;

  @override
  bool get replayToolResults => false;

  @override
  int? get thinkingBudget => null;

  @override
  ProviderConfig getProviderConfig(String key, {String? defaultName}) =>
      ProviderConfig.defaultsFor(key, displayName: defaultName);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ChatMessage _msg(String role, String content, String conversationId) =>
    ChatMessage(role: role, content: content, conversationId: conversationId);

Future<BuildContext> _pumpContext(WidgetTester tester) async {
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

  test(
    'P0-1: an uninitialized provider still loads persisted memories',
    () async {
      final entry = MemoryEntry(
        id: 'mem_00000001',
        scope: MemoryScope.assistant,
        assistantId: 'a1',
        type: MemoryType.identity,
        status: MemoryStatus.active,
        content: 'name Ya-Lun',
        source: MemorySource.manual,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
      );
      SharedPreferences.setMockInitialValues(<String, Object>{
        MemoryStore.v2Key: jsonEncode(<String, dynamic>{
          'v': 2,
          'entries': [entry.toJson()],
        }),
      });
      MemoryStore.resetForTest();

      final provider = MemoryProvider();
      expect(provider.initialized, isFalse);
      await provider.initialize();
      expect(provider.initialized, isTrue);
      expect(provider.visibleFor('a1'), hasLength(1));
      expect(provider.visibleFor('a2'), isEmpty);
    },
  );

  test('global memories are visible to every assistant', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      MemoryStore.v2Key: jsonEncode(<String, dynamic>{
        'v': 2,
        'entries': [
          MemoryEntry(
            id: 'mem_00000001',
            scope: MemoryScope.global,
            assistantId: null,
            type: MemoryType.identity,
            status: MemoryStatus.active,
            content: 'prefers concise answers',
            source: MemorySource.manual,
            createdAt: DateTime(2026, 1, 1),
            updatedAt: DateTime(2026, 1, 1),
          ).toJson(),
        ],
      }),
    });
    MemoryStore.resetForTest();
    final provider = MemoryProvider();
    await provider.initialize();
    expect(provider.visibleFor('a1'), hasLength(1));
    expect(provider.visibleFor('a2'), hasLength(1));
  });

  test(
    'the memory body is injected without tool instructions for non-tool models',
    () {
      final entries = [
        MemoryEntry(
          id: 'mem_00000001',
          scope: MemoryScope.assistant,
          assistantId: 'a1',
          type: MemoryType.identity,
          status: MemoryStatus.active,
          content: 'likes tea',
          source: MemorySource.manual,
          createdAt: DateTime(2026, 1, 1),
          updatedAt: DateTime(2026, 1, 1),
        ),
      ];
      final block = MemoryBlockBuilder.build(
        entries: entries,
        includeToolInstructions: false,
      );
      expect(block, contains('likes tea'));
      expect(block, isNot(contains('Memory tools')));
    },
  );

  testWidgets('voice turn requests append the read-only memory block', (
    tester,
  ) async {
    final context = await _pumpContext(tester);
    final service = ChatTurnService(chatService: _TestChatService());
    final conversation = Conversation(title: 't');
    const assistant = Assistant(
      id: 'a1',
      name: 'Bot',
      systemPrompt: 'SYS',
      enableMemory: true,
    );

    final request = service.prepareTurnRequest(
      conversation: conversation,
      messages: [_msg('user', 'hello', conversation.id)],
      versionSelections: const <String, int>{},
      providerKey: 'OpenAI',
      modelId: 'gpt-4o',
      settings: _TestSettingsProvider(),
      assistant: assistant,
      context: context,
      userNickname: 'tester',
      memoryBlock: '## Long-term memory\n- [2026-01-01] likes tea',
    );

    final system = request.apiMessages.first['content'] as String;
    expect(system, contains('SYS'));
    expect(system, contains('## Long-term memory'));
    expect(system, contains('likes tea'));
    expect(request.toolDefs, isEmpty);
  });

  testWidgets('turn requests without a memory block stay unchanged', (
    tester,
  ) async {
    final context = await _pumpContext(tester);
    final service = ChatTurnService(chatService: _TestChatService());
    final conversation = Conversation(title: 't');
    const assistant = Assistant(id: 'a1', name: 'Bot', systemPrompt: 'SYS');

    final request = service.prepareTurnRequest(
      conversation: conversation,
      messages: [_msg('user', 'hello', conversation.id)],
      versionSelections: const <String, int>{},
      providerKey: 'OpenAI',
      modelId: 'gpt-4o',
      settings: _TestSettingsProvider(),
      assistant: assistant,
      context: context,
      userNickname: 'tester',
    );

    final system = request.apiMessages.first['content'] as String;
    expect(system, 'SYS');
    expect(system, isNot(contains('Long-term memory')));
  });

  test('a store revision bump reloads an initialized provider', () async {
    MemoryEntry entry(String id, String content) => MemoryEntry(
      id: id,
      scope: MemoryScope.assistant,
      assistantId: 'a1',
      type: MemoryType.identity,
      status: MemoryStatus.active,
      content: content,
      source: MemorySource.manual,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );

    SharedPreferences.setMockInitialValues(<String, Object>{
      MemoryStore.v2Key: jsonEncode(<String, dynamic>{
        'v': 2,
        'entries': [entry('mem_00000001', 'first').toJson()],
      }),
    });
    MemoryStore.resetForTest();
    final provider = MemoryProvider();
    await provider.initialize();
    expect(provider.visibleFor('a1').single.content, 'first');

    // Simulate a backup restore writing a new payload behind the cache.
    SharedPreferences.setMockInitialValues(<String, Object>{
      MemoryStore.v2Key: jsonEncode(<String, dynamic>{
        'v': 2,
        'entries': [entry('mem_00000002', 'restored').toJson()],
      }),
    });
    await MemoryStore.invalidateCache();
    await provider.initialize();
    expect(provider.visibleFor('a1').single.content, 'restored');
  });
}
