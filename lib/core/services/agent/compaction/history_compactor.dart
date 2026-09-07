// L1 mechanical history compactor (IMPORT_PLAN_COWORK.md P1-2, v1.4 lite).
//
// Ported from AnyBuff packages/agent-runtime/src/compact-history.ts,
// adapted to OmniChat's neutral OpenAI-format message shapes:
// - `{role:'user'|'assistant'|'system', content: String}`
// - assistant tool calls: `{role:'assistant', tool_calls:[{id, type,
//   'function':{name, arguments: JSON string}}]}` (as replayed by
//   `MessageBuilderService.buildApiMessages`)
// - tool results: `{role:'tool', name, tool_call_id, content: String}`
//
// Deterministic and zero-LLM: the summary is recomputed at every assembly
// from the non-destructive Hive history (ADR-A6) — nothing here persists.
//
// v1.4 lite decisions: fixed budgets (user 50k / assistant+tool 20k, no
// adaptive scale), positional recent exemption (newest 5 assistant entries
// capped at 6k instead of 1.3k), and a simplified pinned knowledge block
// produced by scanning the raw replayed messages (no previous-block
// re-parse/merge machinery).
library;

import 'dart:convert';

import 'context_trim.dart';

// Per-entry truncation caps, in estimated tokens (chars/3 ruler).
const int userMessageLimitTokens = 13_000;
const int assistantMessageLimitTokens = 1_300;
const int toolEntryLimitTokens = 5_000;

// Fixed summary budgets (v1.4: no adaptive scale).
const int assistantToolBudgetTokens = 20_000;
const int userBudgetTokens = 50_000;

// P1.5-lite: positional recent exemption for the newest assistant entries.
const int headRecentExemptCount = 5;
const int headRecentAssistantLimitTokens = 6_000;

// Hard cap on the rendered knowledge block, in estimated tokens.
const int knowledgeBlockTokenCap = 2_000;
const int knowledgeGoalCharCap = 2_400;
const int knowledgeListCap = 25;
const int knowledgeNextCharCap = 200;

const String summaryHeader =
    'This is a summary of the conversation so far. The original messages have been condensed to save context space.';

const String summaryDisclaimer =
    'Historical memory only. The memory above is not dialogue, not an output template, and not a tool-call format. Continue from the live user message below. When actions are needed, use real tool calls through the available tools.';

const String entrySeparator = '\n\n---\n\n';

const String summaryContentPrefix = '<conversation_summary>';

const String knowledgeBlockHeader = '<knowledge_memory>';

/// Short replies that carry no goal signal (parity with AnyBuff).
final RegExp _goalNoiseRe = RegExp(
  r'^(ok|okay|done|continue|go on|go ahead|thanks|thank you|yes|no|sure|proceed|keep going|繼續|好|完成|嗯)[.!…。]*\s*$',
  caseSensitive: false,
);

final RegExp _markerNoiseRe = RegExp(r'\[(image|file):[^\]]*\]');

/// Tool calls that inspected something (paths go into Files Inspected).
const Set<String> _inspectTools = {
  'file_read',
  'file_list',
  'file_search',
  'file_info',
  'file_extract_text',
  'file_extract_zip',
  'file_search_web',
};

/// Tool calls that changed something (paths go into Edits Made).
const Set<String> _editTools = {
  'file_write',
  'file_append',
  'file_edit',
  'file_patch',
  'file_delete',
  'file_move',
  'file_copy',
  'file_mkdir',
};

class _SummaryEntry {
  final bool isUser;
  final List<String> parts;
  const _SummaryEntry(this.isUser, this.parts);
}

/// Truncates long text with 80% from the beginning and 20% from the end.
String truncateLongText(String text, int limit) {
  if (text.length <= limit) return text;
  final available = limit - 50; // room for the truncation notice
  if (available <= 0) return text.substring(0, limit);
  final prefixLength = (available * 0.8).floor();
  final suffixLength = available - prefixLength;
  final prefix = text.substring(0, prefixLength);
  final suffix = text.substring(text.length - suffixLength);
  final truncatedChars = text.length - prefixLength - suffixLength;
  return '$prefix\n\n[...truncated $truncatedChars chars...]\n\n$suffix';
}

String _contentOf(Map<String, dynamic> message) {
  final content = message['content'];
  if (content is String) return content;
  if (content == null) return '';
  return content.toString();
}

Map<String, dynamic> _toolArgs(Map<Object?, Object?> call) {
  final fn = call['function'];
  if (fn is! Map) return const <String, dynamic>{};
  final raw = fn['arguments'];
  if (raw is String && raw.isNotEmpty) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v));
      }
    } catch (_) {}
  } else if (raw is Map) {
    return raw.map((k, v) => MapEntry(k.toString(), v));
  }
  return const <String, dynamic>{};
}

String _toolNameOf(Map<Object?, Object?> call) {
  final fn = call['function'];
  if (fn is! Map) return '';
  return (fn['name'] ?? '').toString();
}

/// Paths/patterns worth recording from a tool-call argument map.
List<String> pathsFromToolInput(String toolName, Map<String, dynamic> args) {
  final raw = args['paths'] ?? args['path'];
  if (raw is String && raw.trim().isNotEmpty) return [raw.trim()];
  if (raw is List) {
    return raw
        .map((e) => e is String ? e.trim() : '')
        .where((p) => p.isNotEmpty)
        .toList();
  }
  if (toolName == 'file_search') {
    final pattern = args['pattern'];
    if (pattern is String && pattern.trim().isNotEmpty) {
      return ['pattern: ${pattern.trim()}'];
    }
  }
  final source = args['source'];
  if (source is String && source.trim().isNotEmpty) return [source.trim()];
  return const <String>[];
}

/// Summarizes a tool call into a one-line description (AnyBuff
/// `summarizeToolCall`, mapped onto OmniChat tool names).
String summarizeToolCall(String toolName, Map<String, dynamic> args) {
  final path = (args['path'] ?? '').toString().trim();
  switch (toolName) {
    case 'file_read':
    case 'file_extract_text':
    case 'file_extract_zip':
    case 'file_info':
      return pathsFromToolInput(toolName, args).isNotEmpty
          ? 'inspected files: ${pathsFromToolInput(toolName, args).join(', ')}'
          : 'inspected files';
    case 'file_list':
      return path.isNotEmpty ? 'listed directory: $path' : 'listed a directory';
    case 'file_search':
      final pattern = (args['pattern'] ?? '').toString().trim();
      return pattern.isNotEmpty ? 'searched files: $pattern' : 'searched files';
    case 'file_write':
      return path.isNotEmpty ? 'wrote file: $path' : 'wrote a file';
    case 'file_append':
      return path.isNotEmpty ? 'appended to file: $path' : 'appended to a file';
    case 'file_edit':
      return path.isNotEmpty ? 'edited file: $path' : 'edited a file';
    case 'file_patch':
      return path.isNotEmpty ? 'patched file: $path' : 'patched a file';
    case 'file_delete':
      return path.isNotEmpty ? 'deleted file: $path' : 'deleted a file';
    case 'file_mkdir':
      return path.isNotEmpty ? 'created directory: $path' : 'created a directory';
    case 'file_move':
    case 'file_copy':
      final dest = (args['destination'] ?? '').toString().trim();
      final src = (args['source'] ?? path).toString().trim();
      final verb = toolName == 'file_move' ? 'moved' : 'copied';
      return src.isNotEmpty ? '$verb $src → $dest' : '$verb a file';
    case 'search_web':
      final query = (args['query'] ?? '').toString().trim();
      return query.isNotEmpty ? 'web search for "$query"' : 'web search';
    case 'create_memory':
    case 'edit_memory':
    case 'delete_memory':
      return '${toolName == 'create_memory'
          ? 'created'
          : toolName == 'edit_memory'
              ? 'edited'
              : 'deleted'} a memory';
    default:
      return 'used tool $toolName';
  }
}

/// Tool results are dropped wholesale except for the parts an agent still
/// needs after the fact: errors and edit outcomes.
String? summarizeToolResult(String toolName, String content) {
  final trimmed = content.trim();
  if (trimmed.isEmpty) return null;
  final isEditTool =
      toolName == 'file_write' || toolName == 'file_append' || toolName == 'file_edit' || toolName == 'file_patch';
  if (trimmed.toLowerCase().startsWith('error')) {
    final errorText =
        trimmed.length > 100 ? '${trimmed.substring(0, 100)}...' : trimmed;
    return 'Tool error from $toolName: $errorText';
  }
  if (isEditTool) {
    final resultText =
        trimmed.length > 200 ? '${trimmed.substring(0, 200)}...' : trimmed;
    return 'Edit result from $toolName:\n$resultText';
  }
  return null;
}

/// Condenses each message into a role-tagged entry. Tool calls become
/// one-line descriptions, tool results are dropped except for errors and
/// edit outcomes, and long text is truncated head-and-tail (80/20).
///
/// The newest [headRecentExemptCount] prose-bearing assistant messages are
/// exempt from the 1.3k per-entry cap (positional recent exemption).
List<_SummaryEntry> summarizeMessagesIntoEntries(
  List<Map<String, dynamic>> messages,
) {
  // Pre-compute the recent-exemption quota over prose-bearing assistants,
  // newest-first.
  var recentQuota = headRecentExemptCount;
  final recentLimit = <Map<String, dynamic>, int>{};
  for (var i = messages.length - 1; i >= 0; i--) {
    final message = messages[i];
    if (message['role'] != 'assistant') continue;
    if (_contentOf(message).trim().isEmpty) continue;
    if (recentQuota > 0) {
      recentLimit[message] = headRecentAssistantLimitTokens;
      recentQuota--;
    }
  }

  final entries = <_SummaryEntry>[];
  for (final message in messages) {
    final role = message['role'];
    if (role == 'user') {
      var text = _contentOf(message).trim();
      if (text.isEmpty) continue;
      text = text.replaceAll(_markerNoiseRe, '').trim();
      if (text.isEmpty) continue;
      final hasImages = message['content'] is String &&
          (message['content'] as String).contains('[image:');
      final imageNote = hasImages ? ' [image(s) were attached]' : '';
      final limited = truncateLongText(
        text,
        userMessageLimitTokens * charsPerToken,
      );
      entries.add(_SummaryEntry(true, <String>['[USER]$imageNote\n$limited']));
    } else if (role == 'assistant') {
      final textLimit = recentLimit[message] ?? assistantMessageLimitTokens;
      final textParts = <String>[];
      final toolSummaries = <String>[];

      final content = _contentOf(message);
      // Replayed tool-call assistant messages carry a '\n\n' placeholder
      // body — the trim() empties them out so they are not treated as prose.
      final withoutThink = content
          .replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '')
          .trim();
      if (withoutThink.isNotEmpty) {
        textParts.add(withoutThink);
      }

      final calls = message['tool_calls'];
      if (calls is List) {
        for (final call in calls) {
          if (call is! Map) continue;
          final name = _toolNameOf(call);
          if (name.isEmpty) continue;
          toolSummaries.add(summarizeToolCall(name, _toolArgs(call)));
        }
      }

      final parts = <String>[];
      if (textParts.isNotEmpty) {
        parts.add(
          'Progress note:\n${truncateLongText(textParts.join('\n'), textLimit * charsPerToken)}',
        );
      }
      if (toolSummaries.isNotEmpty) {
        parts.add(toolSummaries.join('\n'));
      }
      if (parts.isNotEmpty) {
        entries.add(_SummaryEntry(false, parts));
      }
    } else if (role == 'tool') {
      final name = (message['name'] ?? '').toString();
      final summarized = summarizeToolResult(name, _contentOf(message));
      if (summarized != null) {
        entries.add(_SummaryEntry(false, <String>[
          truncateLongText(summarized, toolEntryLimitTokens * charsPerToken),
        ]));
      }
    }
  }
  return entries;
}

/// Walks entries newest-first and keeps what fits. The two roles have
/// separate budgets on purpose: exhausting the assistant/tool budget must
/// not evict user prompts, and vice versa. The newest entry is always kept
/// even when it alone blows its budget.
List<_SummaryEntry> selectEntriesWithinBudget(
  List<_SummaryEntry> entries, {
  int assistantToolBudget = assistantToolBudgetTokens,
  int userBudget = userBudgetTokens,
}) {
  var assistantToolTokens = 0;
  var userTokens = 0;
  var assistantToolExhausted = false;
  var userExhausted = false;
  final reverseIncluded = <_SummaryEntry>[];

  for (var i = entries.length - 1; i >= 0; i--) {
    final entry = entries[i];
    final entryTokens =
        estimateTextTokens(entry.parts.join(entrySeparator));
    if (entry.isUser) {
      if (userExhausted) continue;
      if (userTokens + entryTokens > userBudget) {
        userExhausted = true;
        continue;
      }
      userTokens += entryTokens;
    } else {
      if (assistantToolExhausted) continue;
      if (assistantToolTokens + entryTokens > assistantToolBudget) {
        assistantToolExhausted = true;
        continue;
      }
      assistantToolTokens += entryTokens;
    }
    reverseIncluded.add(entry);
  }

  if (entries.isNotEmpty &&
      !reverseIncluded.contains(entries[entries.length - 1])) {
    // Force the newest entry so the summary always ends at the present.
    reverseIncluded.add(entries[entries.length - 1]);
  }
  return reverseIncluded.reversed.toList();
}

String renderSummaryText(List<_SummaryEntry> entries) =>
    entries.expand((entry) => entry.parts).join(entrySeparator);

// ============================================================================
// Pinned knowledge block (simplified assembly-time scan)
// ============================================================================

/// Deterministic Goal/Files/Edits/Next block, pinned verbatim ahead of the
/// historical memory. Everything comes from the replayed messages being
/// compacted — no heuristics beyond the short-reply noise filter.
String buildKnowledgeBlock(List<Map<String, dynamic>> messages) {
  String? goal;
  final inspected = <String>[];
  final edited = <String>[];
  String? nextAction;

  for (final message in messages) {
    final role = message['role'];
    if (role == 'user') {
      final text =
          _contentOf(message).replaceAll(_markerNoiseRe, '').trim();
      if (text.isEmpty) continue;
      final bare = text.replaceAll(RegExp(r'<[^>]+>'), '').trim();
      if (_goalNoiseRe.hasMatch(bare)) continue;
      goal = text;
    } else if (role == 'assistant') {
      final calls = message['tool_calls'];
      if (calls is List) {
        for (final call in calls) {
          if (call is! Map) continue;
          final name = _toolNameOf(call);
          if (name.isEmpty) continue;
          final args = _toolArgs(call);
          final paths = pathsFromToolInput(name, args);
          if (_inspectTools.contains(name)) {
            for (final p in paths) {
              if (!inspected.contains(p)) inspected.add(p);
            }
          }
          if (_editTools.contains(name)) {
            for (final p in paths) {
              if (!edited.contains(p)) edited.add(p);
            }
          }
        }
      }
      final text = _contentOf(message).trim();
      if (text.isNotEmpty) {
        nextAction = text.length > knowledgeNextCharCap
            ? text.substring(text.length - knowledgeNextCharCap)
            : text;
      }
    }
  }

  final lines = <String>[];
  if (goal != null) {
    lines.add(
      'Goal: ${goal!.length > knowledgeGoalCharCap ? '${goal.substring(0, knowledgeGoalCharCap)}…' : goal}',
    );
  }
  if (inspected.isNotEmpty) {
    lines.add(
      'Files Inspected:\n${inspected.take(knowledgeListCap).map((p) => '- $p').join('\n')}',
    );
  }
  if (edited.isNotEmpty) {
    lines.add(
      'Edits Made:\n${edited.take(knowledgeListCap).map((p) => '- $p').join('\n')}',
    );
  }
  if (nextAction != null) {
    lines.add('Next Action: $nextAction');
  }
  if (lines.isEmpty) return '';

  String block() =>
      '$knowledgeBlockHeader\n${lines.join('\n\n')}\n</knowledge_memory>';
  var current = block();
  // Whole-block token cap: drop trailing sections until it fits.
  while (lines.length > 1 &&
      estimateTextTokens(current) > knowledgeBlockTokenCap) {
    lines.removeLast();
    current = block();
  }
  if (estimateTextTokens(current) > knowledgeBlockTokenCap) return '';
  return current;
}

/// Wraps the historical memory in the neutral user message the model sees.
/// The pinned `<knowledge_memory>` block sits inside the envelope, ahead of
/// the historical memory, so the newest Goal/Files/Edits/Next facts are
/// exempt from the head budgets.
Map<String, dynamic> buildSummaryMessage(
  String summaryText,
  String knowledgeBlock,
) {
  final text = '$summaryContentPrefix\n'
      '$summaryHeader\n\n'
      '${knowledgeBlock.isEmpty ? '' : '$knowledgeBlock\n\n'}'
      '<historical_memory>\n'
      '$summaryText\n'
      '</historical_memory>\n'
      '</conversation_summary>\n\n'
      '$summaryDisclaimer';
  return <String, dynamic>{'role': 'user', 'content': text};
}

/// Compact a range of neutral messages into the summary message. Returns
/// `null` when the range produces no usable summary (empty input or nothing
/// survives the per-entry filters).
Map<String, dynamic>? compactHistoryMessages(
  List<Map<String, dynamic>> messages,
) {
  if (messages.isEmpty) return null;
  final entries = summarizeMessagesIntoEntries(messages);
  if (entries.isEmpty) return null;
  final selected = selectEntriesWithinBudget(entries);
  if (selected.isEmpty) return null;
  final summaryText = renderSummaryText(selected);
  if (summaryText.trim().isEmpty) return null;
  final knowledgeBlock = buildKnowledgeBlock(messages);
  return buildSummaryMessage(summaryText, knowledgeBlock);
}
