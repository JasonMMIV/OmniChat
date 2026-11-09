import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'package:provider/provider.dart';
import 'package:mcp_client/mcp_client.dart' as mcp;
import '../../providers/mcp_provider.dart';
import '../chat/chat_service.dart';
import '../../providers/assistant_provider.dart';
import 'image_search/image_search_server.dart';

class McpToolService extends ChangeNotifier {
  McpToolService();

  /// Resolve which connected servers should receive [toolName], applying the
  /// scoped legacy alias for the built-in image search server
  /// (`image_search` → `illustrate`). Pure function so the routing rules stay
  /// unit-testable without provider fakes.
  @visibleForTesting
  static ({String name, List<McpServerConfig> servers}) resolveCallTarget({
    required Iterable<McpServerConfig> connectedServers,
    required Set<String> selected,
    required String toolName,
  }) {
    var effectiveName = toolName;
    var candidates = connectedServers
        .where((s) => selected.contains(s.id))
        .where((s) => s.tools.any((t) => t.enabled && t.name == effectiveName))
        .toList();

    // Scoped legacy fallback: only the built-in image search server accepts
    // the pre-rename name `image_search` (→ `illustrate`). Third-party servers
    // that happen to expose a tool with the same name are NOT hijacked.
    if (candidates.isEmpty &&
        toolName == ImageSearchMcpServerEngine.legacyToolName) {
      effectiveName = ImageSearchMcpServerEngine.toolName;
      candidates = connectedServers
          .where((s) => selected.contains(s.id))
          .where((s) =>
              s.id == McpProvider.builtinImageSearchServerId &&
              s.tools.any((t) => t.enabled && t.name == effectiveName))
          .toList();
    }

    return (name: effectiveName, servers: candidates);
  }

  List<McpToolConfig> listAvailableToolsForConversation(
    McpProvider mcpProvider,
    ChatService chat,
    String conversationId,
  ) {
    final selected = chat.getConversationMcpServers(conversationId).toSet();
    return mcpProvider.getEnabledToolsForServers(selected);
  }

  List<McpToolConfig> listAvailableToolsForAssistant(
    McpProvider mcpProvider,
    AssistantProvider assistants,
    String? assistantId,
  ) {
    final a = (assistantId != null) ? assistants.getById(assistantId) : assistants.currentAssistant;
    final selected = (a?.mcpServerIds ?? const <String>[]).toSet();
    return mcpProvider.getEnabledToolsForServers(selected);
  }

  Future<mcp.CallToolResult?> callToolForConversation(
    McpProvider mcpProvider,
    ChatService chat, {
      required String conversationId,
      required String toolName,
      Map<String, dynamic> arguments = const {},
  }) async {
    final selected = chat.getConversationMcpServers(conversationId).toSet();
    // debugPrint('[MCP/Call/Select] convo=$conversationId tool=$toolName selectedServers=${selected.join(',')}');
    if (selected.isEmpty) return null;

    // Find a server that has this tool enabled
    final connected = mcpProvider.connectedServers.where((s) => selected.contains(s.id)).toList();
    // debugPrint('[MCP/Call/Select] connectedAndSelected=${connected.map((s)=>s.id).join(',')}');
    for (final s in connected) {
      final has = s.tools.any((t) => t.enabled && t.name == toolName);
      if (has) {
        // debugPrint('[MCP/Call/Select] using server=${s.id} name=${s.name} transport=${s.transport.name}');
        return await mcpProvider.callTool(s.id, toolName, arguments);
      }
    }
    return null;
  }

  // Convenience: call tool and flatten result contents to plain text
  Future<String> callToolTextForConversation(
    McpProvider mcpProvider,
    ChatService chat, {
      required String conversationId,
      required String toolName,
      Map<String, dynamic> arguments = const {},
  }) async {
    // Attempt call via selected server
    final selected = chat.getConversationMcpServers(conversationId).toSet();
    final connected = mcpProvider.connectedServers.where((s) => selected.contains(s.id)).toList();
    mcp.CallToolResult? res;
    McpServerConfig? usedServer;
    for (final s in connected) {
      final has = s.tools.any((t) => t.enabled && t.name == toolName);
      if (!has) continue;
      usedServer = s;
      res = await mcpProvider.callTool(s.id, toolName, arguments);
      break;
    }
    if (res == null) {
      if (usedServer != null) {
        final errMsg = mcpProvider.errorFor(usedServer.id) ?? 'Unknown error';
        final schema = usedServer.tools.firstWhere((t) => t.name == toolName).schema;
        return _renderToolErrorForModel(
          serverName: usedServer.name,
          toolName: toolName,
          arguments: arguments,
          errorMessage: errMsg,
          schema: schema,
        );
      }
      return '';
    }
    final buf = StringBuffer();
    // Be liberal in what we accept: many servers return different content variants.
    for (final c in res.content) {
      try {
        // Known types from mcp_client
        if (c is mcp.TextContent) {
          if ((c.text).trim().isNotEmpty) buf.writeln(c.text);
          continue;
        }
        if (c is mcp.ResourceContent) {
          final t = (c.text ?? '').toString();
          if (t.trim().isNotEmpty) {
            buf.writeln(t);
          } else {
            final uri = (c.uri).toString();
            if (uri.isNotEmpty) buf.writeln('resource: $uri');
          }
          continue;
        }
        if (c is mcp.ImageContent) {
          final url = (c.url ?? '').toString();
          final mime = (c.mimeType ?? '').toString();
          buf.writeln('[image:${url.isNotEmpty ? url : mime}]');
          continue;
        }
        // Try dynamic accessors that some adapters may expose
        final dyn = c as dynamic;
        try {
          final txt = (dyn.text as String?);
          if (txt != null && txt.trim().isNotEmpty) {
            buf.writeln(txt);
            continue;
          }
        } catch (_) {}
        try {
          final uri = (dyn.uri as String?);
          if (uri != null && uri.isNotEmpty) {
            buf.writeln('resource: $uri');
            continue;
          }
        } catch (_) {}
        // As a last resort, serialize to JSON if available
        try {
          final json = (dyn.toJson as dynamic).call();
          buf.writeln(const JsonEncoder.withIndent('  ').convert(json));
          continue;
        } catch (_) {}
        // Fallback to a readable string (avoid Instance of ... when possible)
        final s = c.toString();
        if (!s.startsWith('Instance of')) buf.writeln(s);
      } catch (_) {
        // ignore single content parse errors and continue
      }
    }
    return buf.toString().trim();
  }

  Future<String> callToolTextForAssistant(
    McpProvider mcpProvider,
    AssistantProvider assistants, {
      required String? assistantId,
      required String toolName,
      Map<String, dynamic> arguments = const {},
  }) async {
    // try servers selected for the assistant
    final a = (assistantId != null) ? assistants.getById(assistantId) : assistants.currentAssistant;
    final selected = (a?.mcpServerIds ?? const <String>[]).toSet();
    // debugPrint('[MCP/Call/Select] assistant=${assistantId ?? a?.id ?? '(current)'} tool=$toolName selectedServers=${selected.join(',')}');
    if (selected.isEmpty) return '';

    final target = resolveCallTarget(
      connectedServers: mcpProvider.connectedServers,
      selected: selected,
      toolName: toolName,
    );
    final effectiveName = target.name;
    final candidates = target.servers;

    for (final s in candidates) {
      // debugPrint('[MCP/Call/Select] using server=${s.id} name=${s.name} transport=${s.transport.name}');
      final res = await mcpProvider.callTool(s.id, effectiveName, arguments);
      if (res == null) {
        final errMsg = mcpProvider.errorFor(s.id) ?? 'Unknown error';
        // Use effectiveName: after legacy routing the server only lists the
        // new name — firstWhere(oldName) would throw and lose the structured
        // self-correcting tool error.
        final schema =
            s.tools.firstWhere((t) => t.name == effectiveName).schema;
        return _renderToolErrorForModel(
          serverName: s.name,
          toolName: effectiveName,
          arguments: arguments,
          errorMessage: errMsg,
          schema: schema,
        );
      }
      final buf = StringBuffer();
      for (final c in res.content) {
        try {
          if (c is mcp.TextContent) {
            if ((c.text).trim().isNotEmpty) buf.writeln(c.text);
            continue;
          }
          if (c is mcp.ResourceContent) {
            final t = (c.text ?? '').toString();
            if (t.trim().isNotEmpty) {
              buf.writeln(t);
            } else {
              final uri = (c.uri).toString();
              if (uri.isNotEmpty) buf.writeln('resource: $uri');
            }
            continue;
          }
          if (c is mcp.ImageContent) {
            final url = (c.url ?? '').toString();
            final mime = (c.mimeType ?? '').toString();
            buf.writeln('[image:${url.isNotEmpty ? url : mime}]');
            continue;
          }
          final dyn = c as dynamic;
          try {
            final txt = (dyn.text as String?);
            if (txt != null && txt.trim().isNotEmpty) {
              buf.writeln(txt);
              continue;
            }
          } catch (_) {}
          try {
            final uri = (dyn.uri as String?);
            if (uri != null && uri.isNotEmpty) {
              buf.writeln('resource: $uri');
              continue;
            }
          } catch (_) {}
          try {
            final json = (dyn.toJson as dynamic).call();
            buf.writeln(const JsonEncoder.withIndent('  ').convert(json));
            continue;
          } catch (_) {}
          final s = c.toString();
          if (!s.startsWith('Instance of')) buf.writeln(s);
        } catch (e, st) {
          // debugPrint('[MCP/Call/TextParseError] server=${s.id} tool=$toolName type=${c.runtimeType} err=$e');
          // debugPrint(st.toString());
        }
      }
      return buf.toString().trim();
    }
    return '';
  }

  String _renderToolErrorForModel({
    required String serverName,
    required String toolName,
    required Map<String, dynamic> arguments,
    required String errorMessage,
    Map<String, dynamic>? schema,
  }) {
    // Provide a concise JSON for the model to self-correct and retry
    final map = <String, dynamic>{
      'type': 'tool_error',
      'error': 'invalid_arguments',
      'message': errorMessage,
      'tool': toolName,
      'server': serverName,
      'lastArguments': arguments,
      if (schema != null && schema.isNotEmpty) 'parametersSchema': schema,
      'instruction': 'Revise arguments to satisfy parametersSchema, then call the same tool again.'
    };
    return const JsonEncoder.withIndent('  ').convert(map);
  }
}
