import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../models/assistant.dart';
import '../../models/chat_message.dart';
import '../../models/memory_entry.dart';
import '../../providers/memory_provider.dart';
import '../../providers/settings_provider.dart';
import '../api/chat_api_service.dart';
import '../chat/chat_service.dart';
import 'memory_prompts.dart';

/// Outcome of one manual "organize memory" run (Phase 3, M3-3).
class MemoryOrganizeResult {
  const MemoryOrganizeResult({
    this.gated = false,
    this.created = 0,
    this.merged = 0,
    this.skipped = 0,
    this.extracted = 0,
    this.error,
    this.busy = false,
  });

  final bool gated;
  final int created;
  final int merged;
  final int skipped;
  final int extracted;

  /// Stable error code (`no_model`, `no_history`, `request_failed`,
  /// `parse_failed`, `busy`). UI localizes it; raw provider text never does.
  final String? error;
  final bool busy;

  bool get ok => error == null && !busy;

  Map<String, dynamic> toLastRun(String model) => <String, dynamic>{
    'at': DateTime.now().toIso8601String(),
    'model': model,
    'extracted': extracted,
    'merged': merged,
    'skipped': skipped,
    'error': error,
  };
}

/// Manual memory organizer: Gate → Extract → Smart Add.
///
/// Deliberately single-shot and user-triggered only: no scheduler, no
/// watermark and no hidden LLM cost (`docs/記憶功能改善實作計畫(已實作).md` Phase 3).
typedef MemoryOrganizeGenerator = Future<String> Function({
  required dynamic config,
  required String modelId,
  required String prompt,
  int? thinkingBudget,
});

class MemoryOrganizeService {
  MemoryOrganizeService._();

  /// Observable so the assistant page can disable the action while a run is
  /// in flight instead of relying on a static flag that never rebuilds.
  static final ValueNotifier<bool> running = ValueNotifier<bool>(false);
  static bool get isRunning => running.value;

  static MemoryOrganizeGenerator _generator = _defaultGenerate;

  @visibleForTesting
  static void overrideGenerator(MemoryOrganizeGenerator generator) {
    _generator = generator;
  }

  @visibleForTesting
  static void resetGenerator() {
    _generator = _defaultGenerate;
  }

  static const int maxWindowMessages = 20;
  static const int maxMessageChars = 2000;
  static const int maxWindowChars = 12000;
  static const int maxExtracted = 20;

  /// The Smart Add prompt includes existing memories so the model can MERGE.
  /// Bounded by count and characters (whichever hits first) so a full store
  /// cannot blow up the prompt/context.
  static const int maxSmartAddExisting = 200;
  static const int maxSmartAddExistingChars = 24000;

  static Future<MemoryOrganizeResult> organize({
    required Assistant assistant,
    required SettingsProvider settings,
    required MemoryProvider memoryProvider,
    ChatService? chatService,
    @visibleForTesting String? transcriptOverride,
  }) async {
    if (running.value) return const MemoryOrganizeResult(busy: true);
    running.value = true;
    try {
      final providerKey = settings.memoryOrganizeModelProvider;
      final modelId = settings.memoryOrganizeModelId;
      if (providerKey == null || modelId == null) {
        return const MemoryOrganizeResult(error: 'no_model');
      }
      final config = settings.getProviderConfig(providerKey);
      // Disabled thinking means an explicit budget of 0; enabled leaves the
      // provider/model default untouched (null).
      final thinkingBudget = settings.memoryOrganizeThinkingEnabled ? null : 0;
      final transcript =
          transcriptOverride ??
          await _buildTranscript(chatService!, assistant.id);
      if (transcript.trim().isEmpty) {
        return const MemoryOrganizeResult(error: 'no_history');
      }

      // 1. Gatekeeper — one call; stop when nothing is worth remembering.
      final gateRaw = await _generate(
        config: config,
        modelId: modelId,
        prompt: MemoryPrompts.gatePrompt(transcript),
        thinkingBudget: thinkingBudget,
      );
      final gate = _asJsonObject(gateRaw);
      if (gate == null) {
        return const MemoryOrganizeResult(error: 'parse_failed');
      }
      if (gate['worth_recording'] != true) {
        return const MemoryOrganizeResult(gated: true);
      }

      await memoryProvider.initialize();
      final existing = memoryProvider.visibleFor(assistant.id);

      // 2. Extract — one call, existing memories included to avoid re-extract.
      final extractRaw = await _generate(
        config: config,
        modelId: modelId,
        prompt: MemoryPrompts.extractPrompt(
          transcript: transcript,
          existingMemories: _existingSummary(existing),
        ),
        thinkingBudget: thinkingBudget,
      );
      final extracted = _parseCandidates(extractRaw, assistant.id);
      if (extracted.isEmpty) {
        return const MemoryOrganizeResult(gated: false);
      }

      // 3. Smart Add.
      final counts = await _smartAdd(
        assistant: assistant,
        settings: settings,
        memoryProvider: memoryProvider,
        config: config,
        modelId: modelId,
        thinkingBudget: thinkingBudget,
        existing: existing,
        candidates: extracted,
      );

      return MemoryOrganizeResult(
        extracted: extracted.length,
        created: counts.created,
        merged: counts.merged,
        skipped: counts.skipped,
      );
    } catch (e) {
      debugPrint('Memory organize failed: $e');
      return const MemoryOrganizeResult(error: 'request_failed');
    } finally {
      running.value = false;
    }
  }

  static Future<_SmartAddCounts> _smartAdd({
    required Assistant assistant,
    required SettingsProvider settings,
    required MemoryProvider memoryProvider,
    required dynamic config,
    required String modelId,
    required int? thinkingBudget,
    required List<MemoryEntry> existing,
    required List<_Candidate> candidates,
  }) async {
    if (assistant.memoryDedupeMode == MemoryDedupeMode.strict) {
      return _applyStrict(
        assistant: assistant,
        memoryProvider: memoryProvider,
        existing: existing,
        candidates: candidates,
      );
    }

    try {
      final candidateJson = jsonEncode(<Map<String, dynamic>>[
        for (final c in candidates)
          <String, dynamic>{
            'type': c.type.name,
            'scope': c.scope.name,
            'content': c.content,
          },
      ]);
      final existingItems = <Map<String, dynamic>>[];
      var existingChars = 0;
      for (final e in existing) {
        if (existingItems.length >= maxSmartAddExisting) break;
        final item = <String, dynamic>{
          'id': e.id,
          'type': e.type.name,
          'scope': e.scope.name,
          'content': e.content,
        };
        final size = jsonEncode(item).length;
        if (existingItems.isNotEmpty &&
            existingChars + size > maxSmartAddExistingChars) {
          break;
        }
        existingItems.add(item);
        existingChars += size;
      }
      final existingJson = jsonEncode(existingItems);
      final raw = await _generate(
        config: config,
        modelId: modelId,
        prompt: MemoryPrompts.smartAddPrompt(
          candidatesJson: candidateJson,
          existingJson: existingJson,
        ),
        thinkingBudget: thinkingBudget,
      );
      final decisions = _parseDecisions(raw);
      if (decisions == null) {
        // Strict degradation: never write unparsed LLM output.
        return await _applyStrict(
          assistant: assistant,
          memoryProvider: memoryProvider,
          existing: existing,
          candidates: candidates,
        );
      }
      var created = 0;
      var merged = 0;
      var skipped = 0;
      for (var i = 0; i < candidates.length; i++) {
        final candidate = candidates[i];
        final decision = i < decisions.length ? decisions[i] : null;
        if (decision == null) {
          final applied = await _applyNew(
            assistant: assistant,
            memoryProvider: memoryProvider,
            candidate: candidate,
            existing: existing,
          );
          created += applied;
          continue;
        }
        switch (decision.decision) {
          case 'SKIP':
            skipped++;
            break;
          case 'MERGE':
          case 'CONFLICT':
            final target = _findTarget(existing, decision.targetId, candidate);
            if (target != null) {
              final content = decision.content.trim().isEmpty
                  ? candidate.content
                  : decision.content;
              final updated = await memoryProvider.updateEntry(
                target.id,
                content: content,
              );
              if (updated != null) {
                merged++;
                break;
              }
            }
            created += await _applyNew(
              assistant: assistant,
              memoryProvider: memoryProvider,
              candidate: candidate,
              existing: existing,
            );
            break;
          default:
            created += await _applyNew(
              assistant: assistant,
              memoryProvider: memoryProvider,
              candidate: candidate,
              existing: existing,
            );
        }
      }
      return _SmartAddCounts(
        created: created,
        merged: merged,
        skipped: skipped,
      );
    } catch (e) {
      debugPrint('Memory smart add failed, falling back to strict: $e');
      return _applyStrict(
        assistant: assistant,
        memoryProvider: memoryProvider,
        existing: existing,
        candidates: candidates,
      );
    }
  }

  static Future<_SmartAddCounts> _applyStrict({
    required Assistant assistant,
    required MemoryProvider memoryProvider,
    required List<MemoryEntry> existing,
    required List<_Candidate> candidates,
  }) async {
    var created = 0;
    var skipped = 0;
    final seen = <String>{
      for (final e in existing) _dedupeKey(e.scope, e.assistantId, e.content),
    };
    for (final c in candidates) {
      final key = _dedupeKey(
        c.scope,
        c.scope == MemoryScope.assistant ? assistant.id : null,
        c.content,
      );
      if (!seen.add(key)) {
        skipped++;
        continue;
      }
      final result = await memoryProvider.add(
        scope: c.scope,
        assistantId: c.scope == MemoryScope.assistant ? assistant.id : null,
        type: c.type,
        content: c.content,
        source: MemorySource.extracted,
        skipExactDuplicate: true,
      );
      if (result.duplicate) {
        skipped++;
      } else {
        created++;
      }
    }
    return _SmartAddCounts(created: created, merged: 0, skipped: skipped);
  }

  static Future<int> _applyNew({
    required Assistant assistant,
    required MemoryProvider memoryProvider,
    required _Candidate candidate,
    required List<MemoryEntry> existing,
  }) async {
    final key = _dedupeKey(
      candidate.scope,
      candidate.scope == MemoryScope.assistant ? assistant.id : null,
      candidate.content,
    );
    for (final e in existing) {
      if (_dedupeKey(e.scope, e.assistantId, e.content) == key) return 0;
    }
    final result = await memoryProvider.add(
      scope: candidate.scope,
      assistantId: candidate.scope == MemoryScope.assistant
          ? assistant.id
          : null,
      type: candidate.type,
      content: candidate.content,
      source: MemorySource.extracted,
      skipExactDuplicate: true,
    );
    return result.duplicate ? 0 : 1;
  }

  static MemoryEntry? _findTarget(
    List<MemoryEntry> existing,
    String? targetId,
    _Candidate candidate,
  ) {
    if (targetId == null || targetId.trim().isEmpty) return null;
    for (final e in existing) {
      if (e.id == targetId &&
          e.scope == candidate.scope &&
          (candidate.scope == MemoryScope.global ||
              e.assistantId == candidate.assistantId)) {
        return e;
      }
    }
    return null;
  }

  static String _dedupeKey(
    MemoryScope scope,
    String? assistantId,
    String content,
  ) =>
      '${scope.name}|${(assistantId ?? '').toLowerCase()}|'
      '${MemoryEntry.normalizeContent(content)}';

  static String _existingSummary(List<MemoryEntry> existing) {
    if (existing.isEmpty) return '(none)';
    final buf = StringBuffer();
    for (final e in existing.take(80)) {
      final line =
          '- [${e.type.name}] '
          '${e.scope == MemoryScope.assistant ? "(assistant) " : ""}'
          '${e.content}';
      if (buf.isNotEmpty &&
          buf.length + line.length > maxSmartAddExistingChars) {
        break;
      }
      buf.writeln(line);
    }
    return buf.toString().trimRight();
  }

  static Future<String> _buildTranscript(
    ChatService chatService,
    String assistantId,
  ) async {
    final conversations = chatService
        .getAllConversations()
        .where((c) => c.assistantId == assistantId)
        .toList();
    if (conversations.isEmpty) return '';
    conversations.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final conversation = conversations.first;
    await chatService.ensureConversationLoaded(conversation.id);
    final messages = chatService.getMessages(conversation.id);
    final usable = messages.where((m) => m.content.trim().isNotEmpty).toList();
    final window = usable.length <= maxWindowMessages
        ? usable
        : usable.sublist(usable.length - maxWindowMessages);

    final buf = StringBuffer();
    for (final m in window) {
      final content = _truncate(m.content.trim(), maxMessageChars);
      buf.writeln('${_roleLabel(m)}: $content');
      if (buf.length >= maxWindowChars) break;
    }
    return _truncate(buf.toString(), maxWindowChars);
  }

  static String _roleLabel(ChatMessage message) => switch (message.role) {
    'user' => 'User',
    'assistant' => 'Assistant',
    _ => message.role,
  };

  static String _truncate(String text, int max) =>
      text.length <= max ? text : text.substring(0, max);

  static Future<String> _generate({
    required dynamic config,
    required String modelId,
    required String prompt,
    int? thinkingBudget,
  }) => _generator(
    config: config,
    modelId: modelId,
    prompt: prompt,
    thinkingBudget: thinkingBudget,
  );

  static Future<String> _defaultGenerate({
    required dynamic config,
    required String modelId,
    required String prompt,
    int? thinkingBudget,
  }) => ChatApiService.generateText(
    config: config,
    modelId: modelId,
    prompt: prompt,
    thinkingBudget: thinkingBudget,
  );

  static Map<String, dynamic>? _asJsonObject(String raw) {
    final decoded = _decodeJson(raw);
    if (decoded is Map) return decoded.cast<String, dynamic>();
    return null;
  }

  static dynamic _decodeJson(String raw) {
    var text = raw.trim();
    final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(text);
    if (fence != null) text = fence.group(1)?.trim() ?? text;
    try {
      return jsonDecode(text);
    } catch (_) {
      final start = text.indexOf(RegExp(r'[\[{]'));
      if (start == -1) return null;
      for (var end = text.length; end > start; end--) {
        try {
          return jsonDecode(text.substring(start, end));
        } catch (_) {}
      }
      return null;
    }
  }

  static List<_Candidate> _parseCandidates(String raw, String assistantId) {
    final decoded = _decodeJson(raw);
    if (decoded is! List) return const <_Candidate>[];
    final out = <_Candidate>[];
    for (final item in decoded) {
      if (item is! Map) continue;
      final content = (item['content'] ?? '').toString().trim();
      if (content.isEmpty) continue;
      final type = _parseType(item['type']);
      final scopeName = (item['scope'] ?? '').toString().trim().toLowerCase();
      final scope = scopeName == 'global'
          ? MemoryScope.global
          : MemoryScope.assistant;
      out.add(
        _Candidate(
          type: type,
          scope: scope,
          assistantId: assistantId,
          content: _truncate(content, MemoryEntry.maxContentChars),
        ),
      );
      if (out.length >= maxExtracted) break;
    }
    return out;
  }

  static List<_Decision>? _parseDecisions(String raw) {
    final decoded = _decodeJson(raw);
    if (decoded is! List) return null;
    final out = <_Decision>[];
    for (final item in decoded) {
      if (item is! Map) {
        out.add(const _Decision('NEW', null, ''));
        continue;
      }
      final decision = (item['decision'] ?? 'NEW')
          .toString()
          .trim()
          .toUpperCase();
      out.add(
        _Decision(
          decision,
          (item['targetId'] ?? '').toString().trim(),
          (item['content'] ?? '').toString(),
        ),
      );
    }
    return out;
  }

  static MemoryType _parseType(Object? raw) {
    final name = (raw ?? '').toString().trim().toLowerCase();
    for (final type in MemoryType.values) {
      if (type.name == name) return type;
    }
    return MemoryType.identity;
  }
}

class _Candidate {
  const _Candidate({
    required this.type,
    required this.scope,
    required this.assistantId,
    required this.content,
  });

  final MemoryType type;
  final MemoryScope scope;
  final String assistantId;
  final String content;
}

class _Decision {
  const _Decision(this.decision, this.targetId, this.content);

  final String decision;
  final String? targetId;
  final String content;
}

class _SmartAddCounts {
  const _SmartAddCounts({
    required this.created,
    required this.merged,
    required this.skipped,
  });

  final int created;
  final int merged;
  final int skipped;
}
