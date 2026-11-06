import 'dart:convert';

import '../../models/assistant.dart';
import '../../models/memory_entry.dart';
import '../../providers/memory_provider.dart';
import '../logging/flutter_logger.dart';
import '../memory_store.dart';
import 'memory_tools.dart';

/// Executes the V1 memory tool surface against a [MemoryProvider].
///
/// Extracted from `ToolHandlerService` so the JSON contract can be tested
/// without a widget tree: SharedPreferences futures never complete inside a
/// `testWidgets` fake-async zone, which made the original contract test hang.
/// The service wrapper only resolves the provider and delegates here.
///
/// Every result is JSON. Failures follow the M0-2 shape
/// `{error: 'tool_error', code, message}` and are also written to
/// [FlutterLogger] (handbook §5.6).
class MemoryToolHandler {
  const MemoryToolHandler._();

  /// True when [name] is a memory tool and memory is enabled for [assistant].
  static bool handles(String name, Assistant? assistant) =>
      assistant?.enableMemory == true && MemoryTools.isMemoryTool(name);

  /// Returns null when [name] is not a memory tool or memory is disabled.
  static Future<String?> handle(
    String name,
    Map<String, dynamic> args,
    Assistant? assistant,
    MemoryProvider provider,
  ) async {
    if (!handles(name, assistant)) return null;
    final enabledAssistant = assistant!;
    try {
      // P0-1: never read the in-memory list before the lazy load finished.
      await provider.initialize();

      switch (name) {
        case MemoryTools.update:
        case MemoryTools.legacyCreate:
          final content = (args['content'] ?? '').toString().trim();
          if (content.isEmpty) {
            return _error('invalid_args', 'content must not be empty.');
          }
          final rawType = args['type'];
          final type = _parseMemoryType(rawType);
          // Only the legacy create alias may omit `type`; an unknown value is
          // always an error (never silently write `identity`).
          final legacyOmittedType =
              name == MemoryTools.legacyCreate && rawType == null;
          if (type == null && !legacyOmittedType) {
            return _error(
              'invalid_args',
              'type must be one of ${MemoryTools.typeNames().join(', ')}.',
            );
          }
          final scope = _resolveMemoryScope(enabledAssistant, args['scope']);
          final result = await provider.add(
            scope: scope,
            assistantId: scope == MemoryScope.assistant
                ? enabledAssistant.id
                : null,
            type: type ?? MemoryType.identity,
            content: content,
            source: MemorySource.tool,
            skipExactDuplicate: true,
          );
          final payload = <String, dynamic>{
            'id': result.entry.id,
            'action': result.duplicate ? 'skipped' : 'created',
          };
          if (result.truncated) payload['note'] = '[content truncated]';
          if (provider.all.length >= MemoryStore.softEntryLimit) {
            payload['warning'] = 'threshold';
            payload['hint'] = 'merge or delete outdated memories';
          }
          return jsonEncode(payload);

        case MemoryTools.edit:
        case MemoryTools.legacyEdit:
          final id = (args['id'] ?? '').toString().trim();
          final content = (args['content'] ?? '').toString().trim();
          if (id.isEmpty || content.isEmpty) {
            return _error('invalid_args', 'id and content are required.');
          }
          final result = await provider.updateEntry(id, content: content);
          if (result == null) {
            return _error('not_found', 'No memory with id "$id".');
          }
          return jsonEncode(<String, dynamic>{
            'id': result.entry.id,
            'action': 'edited',
            if (result.truncated) 'note': '[content truncated]',
          });

        case MemoryTools.delete:
        case MemoryTools.legacyDelete:
          final id = (args['id'] ?? '').toString().trim();
          if (id.isEmpty) {
            return _error('invalid_args', 'id is required.');
          }
          final ok = await provider.archive(id);
          if (!ok) {
            return _error('not_found', 'No memory with id "$id".');
          }
          return jsonEncode(<String, dynamic>{'id': id, 'action': 'deleted'});

        case MemoryTools.read:
          final rawLimit = args['limit'];
          final parsedLimit = _parseInt(rawLimit);
          if (rawLimit != null && parsedLimit == null) {
            return _error('invalid_args', 'limit must be an integer.');
          }
          final rawOffset = args['offset'];
          final parsedOffset = _parseInt(rawOffset);
          if (rawOffset != null && parsedOffset == null) {
            return _error('invalid_args', 'offset must be an integer.');
          }
          final limit = (parsedLimit ?? 50).clamp(1, 100);
          final offset = (parsedOffset ?? 0) < 0 ? 0 : (parsedOffset ?? 0);

          final rawType = args['type'];
          final typeFilter = rawType == null ? null : _parseMemoryType(rawType);
          if (rawType != null && typeFilter == null) {
            return _error(
              'invalid_args',
              'type must be one of ${MemoryTools.typeNames().join(', ')}.',
            );
          }

          final entries =
              provider
                  .forAssistant(enabledAssistant.id, includeArchived: false)
                  .where((e) => typeFilter == null || e.type == typeFilter)
                  .toList()
                ..sort((a, b) {
                  final byUpdated = b.updatedAt.compareTo(a.updatedAt);
                  return byUpdated != 0 ? byUpdated : a.id.compareTo(b.id);
                });
          final total = entries.length;
          final start = offset > total ? total : offset;
          final end = (start + limit) > total ? total : start + limit;
          final items = <Map<String, dynamic>>[];
          for (final e in entries.sublist(start, end)) {
            items.add(<String, dynamic>{
              'id': e.id,
              'type': e.type.name,
              'scope': e.scope.name,
              'content': e.content,
              'updated': _formatDate(e.updatedAt),
            });
          }
          return jsonEncode(<String, dynamic>{
            'total': total,
            'has_more': end < total,
            'next_offset': end,
            'items': items,
          });

        default:
          return null;
      }
    } catch (e, st) {
      FlutterLogger.log(
        'Memory tool "$name" failed: $e\n$st',
        tag: 'memory-tool',
      );
      return _error('execution_error', e.toString(), tool: name);
    }
  }

  static String _error(String code, String message, {String? tool}) =>
      jsonEncode(<String, dynamic>{
        'error': 'tool_error',
        'code': code,
        'message': message,
        if (tool != null) 'tool': tool,
      });

  /// Accepts both JSON numbers and numeric strings (some providers serialize
  /// integer arguments as strings).
  static int? _parseInt(Object? raw) {
    if (raw == null) return null;
    if (raw is num) return raw.toInt();
    return int.tryParse(raw.toString().trim());
  }

  /// Returns null for an unknown type so callers can reject the call instead
  /// of silently writing/querying `identity`.
  static MemoryType? _parseMemoryType(Object? raw) {
    final name = (raw ?? '').toString().trim().toLowerCase();
    for (final type in MemoryType.values) {
      if (type.name == name) return type;
    }
    return null;
  }

  /// Assistant write policy (M2-1): `always*` overrides the model's `scope`
  /// argument; `toolDefault*` lets an explicit argument win.
  static MemoryScope _resolveMemoryScope(Assistant assistant, Object? raw) {
    final scopeName = (raw ?? '').toString().trim().toLowerCase();
    final policy = assistant.memoryWriteScope;
    final allowsToolChoice =
        policy == MemoryWriteScope.toolDefaultGlobal ||
        policy == MemoryWriteScope.toolDefaultAssistant;
    if (allowsToolChoice) {
      if (scopeName == 'global') return MemoryScope.global;
      if (scopeName == 'assistant') return MemoryScope.assistant;
    }
    return (policy == MemoryWriteScope.alwaysGlobal ||
            policy == MemoryWriteScope.toolDefaultGlobal)
        ? MemoryScope.global
        : MemoryScope.assistant;
  }

  static String _formatDate(DateTime value) {
    final local = value.toLocal();
    return '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
  }
}
