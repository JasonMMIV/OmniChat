import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/models/assistant.dart';
import 'package:OmniChat/core/models/memory_entry.dart';
import 'package:OmniChat/core/providers/memory_provider.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/memory/memory_organize_service.dart';
import 'package:OmniChat/core/services/memory_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsProvider settings;
  late MemoryProvider memory;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    MemoryStore.resetForTest();
    MemoryOrganizeService.resetGenerator();
    settings = SettingsProvider();
    // SettingsProvider kicks off an unawaited initial load; let it settle so
    // it cannot clobber values written by the test afterwards.
    await Future<void>.delayed(const Duration(milliseconds: 10));
    memory = MemoryProvider();
  });

  tearDown(() {
    MemoryOrganizeService.resetGenerator();
  });

  Future<MemoryOrganizeResult> run({
    required List<String> responses,
    Assistant? assistant,
    String transcript = 'User: I like green tea.\nAssistant: Noted.',
    bool withModel = true,
    bool thinkingEnabled = true,
    List<int?>? budgets,
  }) async {
    if (withModel) {
      await settings.setMemoryOrganizeModel('provider', 'model');
    }
    await settings.setMemoryOrganizeThinkingEnabled(thinkingEnabled);
    final queue = <String>[...responses];
    MemoryOrganizeService.overrideGenerator(({
      required dynamic config,
      required String modelId,
      required String prompt,
      int? thinkingBudget,
    }) async {
      budgets?.add(thinkingBudget);
      if (queue.isEmpty) {
        throw StateError('unexpected extra LLM call');
      }
      return queue.removeAt(0);
    });
    return MemoryOrganizeService.organize(
      assistant:
          assistant ?? const Assistant(id: 'a1', name: 'A', enableMemory: true),
      settings: settings,
      memoryProvider: memory,
      transcriptOverride: transcript,
    );
  }

  test('requires an organize model', () async {
    final result = await run(responses: const [], withModel: false);
    expect(result.error, 'no_model');
    expect(await MemoryStore.getAll(), isEmpty);
  });

  test('empty transcript reports no_history', () async {
    final result = await run(responses: const [], transcript: '   ');
    expect(result.error, 'no_history');
  });

  test('gate false stops before extraction and writes nothing', () async {
    final result = await run(
      responses: ['{"worth_recording": false, "reason": "small talk"}'],
    );
    expect(result.gated, isTrue);
    expect(result.extracted, 0);
    expect(await MemoryStore.getAll(), isEmpty);
  });

  test('extracts entries and writes them in strict mode', () async {
    final result = await run(
      responses: [
        '{"worth_recording": true}',
        jsonEncode([
          {
            'type': 'identity',
            'scope': 'assistant',
            'content': 'likes green tea',
          },
          {
            'type': 'workflow',
            'scope': 'global',
            'content': 'works on a Flutter client',
          },
        ]),
      ],
      assistant: const Assistant(
        id: 'a1',
        name: 'A',
        enableMemory: true,
        memoryDedupeMode: MemoryDedupeMode.strict,
      ),
    );
    expect(result.error, isNull);
    expect(result.extracted, 2);
    expect(result.created, 2);
    final entries = await MemoryStore.getAll();
    expect(entries, hasLength(2));
    expect(entries.every((e) => e.source == MemorySource.extracted), isTrue);
    expect(entries.any((e) => e.scope == MemoryScope.global), isTrue);
  });

  test('strict mode skips exact duplicates', () async {
    await memory.initialize();
    await memory.add(
      scope: MemoryScope.assistant,
      assistantId: 'a1',
      type: MemoryType.identity,
      content: 'likes green tea',
    );
    final result = await run(
      responses: [
        '{"worth_recording": true}',
        jsonEncode([
          {'type': 'identity', 'content': ' Likes  Green Tea '},
        ]),
      ],
      assistant: const Assistant(
        id: 'a1',
        name: 'A',
        enableMemory: true,
        memoryDedupeMode: MemoryDedupeMode.strict,
      ),
    );
    expect(result.created, 0);
    expect(result.skipped, 1);
    expect(await MemoryStore.getAll(), hasLength(1));
  });

  test('LLM smart add merges into the target entry', () async {
    await memory.initialize();
    final existing = await memory.add(
      scope: MemoryScope.assistant,
      assistantId: 'a1',
      type: MemoryType.identity,
      content: 'likes tea',
    );
    final result = await run(
      responses: [
        '{"worth_recording": true}',
        jsonEncode([
          {'type': 'identity', 'content': 'likes green tea'},
        ]),
        jsonEncode([
          {
            'decision': 'MERGE',
            'targetId': existing.entry.id,
            'content': 'likes green tea',
          },
        ]),
      ],
    );
    expect(result.merged, 1);
    expect(result.created, 0);
    final entries = await MemoryStore.getAll();
    expect(entries, hasLength(1));
    expect(entries.single.content, 'likes green tea');
  });

  test(
    'unparseable smart add output degrades to strict without junk',
    () async {
      final result = await run(
        responses: [
          '{"worth_recording": true}',
          jsonEncode([
            {'type': 'identity', 'content': 'likes green tea'},
          ]),
          'not json at all',
        ],
      );
      expect(result.error, isNull);
      expect(result.created, 1);
      expect(await MemoryStore.getAll(), hasLength(1));
    },
  );

  test('extracted content is capped at 2000 characters', () async {
    final long = 'x' * 2500;
    await run(
      responses: [
        '{"worth_recording": true}',
        jsonEncode([
          {'type': 'identity', 'content': long},
        ]),
      ],
      assistant: const Assistant(
        id: 'a1',
        name: 'A',
        enableMemory: true,
        memoryDedupeMode: MemoryDedupeMode.strict,
      ),
    );
    final entry = (await MemoryStore.getAll()).single;
    expect(entry.content.length, MemoryEntry.maxContentChars);
  });

  test('the thinking switch controls the organize generation budget', () async {
    final budgets = <int?>[];
    await run(
      responses: [
        jsonEncode({'worth_recording': false}),
      ],
      thinkingEnabled: false,
      budgets: budgets,
    );
    expect(budgets, everyElement(0));

    budgets.clear();
    await run(
      responses: [
        jsonEncode({'worth_recording': false}),
      ],
      thinkingEnabled: true,
      budgets: budgets,
    );
    expect(budgets, everyElement(isNull));
  });

  test('last-run payload carries counts and the model id', () async {
    const result = MemoryOrganizeResult(
      extracted: 3,
      created: 1,
      merged: 1,
      skipped: 1,
    );
    final lastRun = result.toLastRun('provider::model');
    expect(lastRun['model'], 'provider::model');
    expect(lastRun['extracted'], 3);
    expect(lastRun['merged'], 1);
    expect(lastRun['skipped'], 1);
    expect(lastRun['at'], isNotEmpty);
  });
}
