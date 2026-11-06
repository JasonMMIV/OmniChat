import 'dart:convert';

import '../../models/memory_entry.dart';
import 'memory_prompts.dart';

/// Deterministic memory block builder.
///
/// Invariants (see `docs/記憶功能改善實作計畫(已實作).md` M2-3 and M1-1): the request
/// assembly path must never read the clock or any other per-turn variable.
/// Identical inputs therefore produce byte-identical output, which keeps the
/// prefix cache stable between memory writes.
class MemoryBlockBuilder {
  const MemoryBlockBuilder._();

  static const int defaultMaxItemsPerType = 10;
  static const int minMaxItemsPerType = 3;
  static const int maxMaxItemsPerType = 30;

  /// Whole-block cap; the last line of defence after per-type limits.
  static const int totalBytesCap = 32 * 1024;

  /// Type blocks always render in this order so output is deterministic.
  static const List<MemoryType> typeOrder = <MemoryType>[
    MemoryType.identity,
    MemoryType.workflow,
    MemoryType.voice,
    MemoryType.instruction,
  ];

  static int clampMaxItems(int value) =>
      value.clamp(minMaxItemsPerType, maxMaxItemsPerType);

  /// Builds the system-tail memory block. Returns an empty string when there
  /// are no active entries (an empty section would only add noise).
  static String build({
    required List<MemoryEntry> entries,
    int maxItemsPerType = defaultMaxItemsPerType,
    Set<MemoryType> fullInjectionTypes = const <MemoryType>{},
    required bool includeToolInstructions,
    int byteCap = totalBytesCap,
  }) {
    final active = entries
        .where((e) => e.status == MemoryStatus.active && e.content.trim().isNotEmpty)
        .toList();
    if (active.isEmpty) return '';

    final cap = clampMaxItems(maxItemsPerType);

    // Collect the rendered entry lines per type; trimming for the byte cap
    // removes whole lines from the tail of the rendered order.
    final blocks = <MemoryType, _TypeBlock>{};
    for (final type in typeOrder) {
      final ofType = active.where((e) => e.type == type).toList();
      if (ofType.isEmpty) {
        blocks[type] = _TypeBlock(lines: const <String>[]);
        continue;
      }
      final total = ofType.length;
      final full = fullInjectionTypes.contains(type);
      final summarize = !full && total > cap;
      final selected = summarize
          ? (ofType.toList()
              ..sort((a, b) {
                final byUpdated = b.updatedAt.compareTo(a.updatedAt);
                return byUpdated != 0 ? byUpdated : a.id.compareTo(b.id);
              }))
              .take(cap)
              .toList()
          : ofType;
      selected.sort(_compareForBlock);
      blocks[type] = _TypeBlock(
        lines: <String>[for (final e in selected) _formatLine(e)],
        summary: summarize,
        total: total,
      );
    }

    // The 32 KB budget covers the whole injected block, including the fixed
    // tool rules appended after the memory body.
    final rules = includeToolInstructions
        ? '\n\n${MemoryPrompts.rulesEn}'
        : '';
    final rulesBytes = utf8.encode(rules).length;
    final bodyCap = byteCap > rulesBytes ? byteCap - rulesBytes : 0;

    var trimmed = false;
    var byteLength = _render(blocks, trimmed: false).bytes;
    while (byteLength > bodyCap) {
      final donor = typeOrder.lastWhere(
        (t) => blocks[t]!.lines.isNotEmpty,
        orElse: () => typeOrder.first,
      );
      final lines = blocks[donor]!.lines;
      if (lines.isEmpty) break;
      lines.removeLast();
      trimmed = true;
      byteLength = _render(blocks, trimmed: true).bytes;
    }

    final body = _render(blocks, trimmed: trimmed).text;
    if (body.isEmpty) return '';
    final output = '$body$rules';
    if (utf8.encode(output).length <= byteCap) return output;
    // Degenerate tiny cap: the header alone cannot fit, so keep only the
    // fixed tool contract when it fits; otherwise emit nothing rather than
    // violating the caller's budget.
    final rulesOnly = rules.trimLeft();
    return utf8.encode(rulesOnly).length <= byteCap ? rulesOnly : '';
  }

  /// global first, then createdAt, then id — deterministic and stable.
  static int _compareForBlock(MemoryEntry a, MemoryEntry b) {
    if (a.isGlobal != b.isGlobal) return a.isGlobal ? -1 : 1;
    final byCreated = a.createdAt.compareTo(b.createdAt);
    if (byCreated != 0) return byCreated;
    return a.id.compareTo(b.id);
  }

  static String _formatLine(MemoryEntry e) {
    final date = _formatDate(e.updatedAt);
    final scopePrefix = e.scope == MemoryScope.assistant ? '(assistant) ' : '';
    return '- [$date] $scopePrefix${escapeAndFlatten(e.content)}';
  }

  static String _formatDate(DateTime value) {
    final local = value.toLocal();
    final y = local.year.toString().padLeft(4, '0');
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  /// Conservative XML escaping of content only (& < >); whitespace collapses
  /// to single spaces so a multi-line memory cannot forge block structure.
  static String escapeAndFlatten(String input) => input
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static _Rendered _render(
    Map<MemoryType, _TypeBlock> blocks, {
    required bool trimmed,
  }) {
    final buf = StringBuffer();
    buf.writeln('## Long-term memory');
    buf.writeln(MemoryPrompts.intro);
    for (final type in typeOrder) {
      final block = blocks[type]!;
      if (block.lines.isEmpty) {
        buf.writeln('<user_memory type="${type.name}"/>');
        continue;
      }
      if (block.summary) {
        buf.writeln(
          '<user_memory type="${type.name}" mode="summary" '
          'total="${block.total}" shown="${block.lines.length}">',
        );
      } else {
        buf.writeln('<user_memory type="${type.name}">');
      }
      for (final line in block.lines) {
        buf.writeln(line);
      }
      if (block.summary) {
        buf.writeln(MemoryPrompts.moreEntriesHint);
      }
      buf.writeln('</user_memory>');
    }
    if (trimmed) buf.writeln(MemoryPrompts.olderOmittedHint);
    final text = buf.toString().trimRight();
    return _Rendered(text: text, bytes: utf8.encode(text).length);
  }
}

class _TypeBlock {
  _TypeBlock({required this.lines, this.summary = false, this.total = 0});

  final List<String> lines;
  final bool summary;
  final int total;
}

class _Rendered {
  const _Rendered({required this.text, required this.bytes});

  final String text;
  final int bytes;
}
