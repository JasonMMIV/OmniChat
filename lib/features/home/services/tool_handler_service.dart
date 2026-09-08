import 'dart:convert';
import 'package:path/path.dart' as path;
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import '../../../core/models/assistant.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/mcp_provider.dart';
import '../../../core/providers/memory_provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/mcp/mcp_tool_service.dart';
import '../../../core/services/search/search_tool_service.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/chat/todo_service.dart';
import '../../../core/services/chat/ask_user_models.dart';
import '../../../core/services/file/file_tool_service.dart';
import '../../../core/services/logging/flutter_logger.dart';
import '../../../core/services/tools/tool_output_externalizer.dart';
import '../../../core/models/file_record.dart';

/// 工具调用处理服务
///
/// 处理各类工具调用：
/// - MCP 工具
/// - Memory 工具 (create/edit/delete)
/// - Search 工具
/// - Workspace file 工具
class ToolHandlerService {
  ToolHandlerService({
    required this.contextProvider,
    required this.chatService,
  });

  /// Build context (used for accessing providers)
  final BuildContext contextProvider;
  final ChatService chatService;

  // ============================================================================
  // Tool Schema Sanitization
  // ============================================================================

  /// Sanitize/translate JSON Schema to each provider's accepted subset.
  ///
  /// Different providers (Google, OpenAI, Claude) have different requirements
  /// for tool parameter schemas. This method normalizes schemas to work across
  /// all providers.
  static Map<String, dynamic> sanitizeToolParametersForProvider(
    Map<String, dynamic> schema,
    ProviderKind kind,
  ) {
    Map<String, dynamic> clone = _deepCloneMap(schema);
    clone = _sanitizeNode(clone, kind) as Map<String, dynamic>;
    return clone;
  }

  static dynamic _sanitizeNode(dynamic node, ProviderKind kind) {
    if (node is List) {
      return node.map((e) => _sanitizeNode(e, kind)).toList();
    }
    if (node is! Map) return node;

    final m = Map<String, dynamic>.from(node);
    // Remove $schema as it's not needed for tool definitions
    m.remove(r'$schema');

    // Convert 'const' to 'enum' for compatibility
    if (m.containsKey('const')) {
      final v = m['const'];
      if (v is String || v is num || v is bool) {
        m['enum'] = [v];
      }
      m.remove('const');
    }

    // Flatten anyOf/oneOf/allOf to first variant for simplicity
    for (final key in [
      'anyOf',
      'oneOf',
      'allOf',
      'any_of',
      'one_of',
      'all_of',
    ]) {
      if (m[key] is List && (m[key] as List).isNotEmpty) {
        final first = (m[key] as List).first;
        final flattened = _sanitizeNode(first, kind);
        m.remove(key);
        if (flattened is Map<String, dynamic>) {
          m
            ..remove('type')
            ..remove('properties')
            ..remove('items');
          m.addAll(flattened);
        }
      }
    }

    // Normalize type array to single type
    final t = m['type'];
    if (t is List && t.isNotEmpty) m['type'] = t.first.toString();

    // Normalize items array to single item
    final items = m['items'];
    if (items is List && items.isNotEmpty) m['items'] = items.first;
    if (m['items'] is Map) m['items'] = _sanitizeNode(m['items'], kind);

    // Recursively sanitize properties
    if (m['properties'] is Map) {
      final props = Map<String, dynamic>.from(m['properties']);
      final norm = <String, dynamic>{};
      props.forEach((k, v) {
        norm[k] = _sanitizeNode(v, kind);
      });
      m['properties'] = norm;
    }

    // Keep only allowed keys based on provider
    Set<String> allowed;
    switch (kind) {
      case ProviderKind.google:
        allowed = {
          'type',
          'description',
          'properties',
          'required',
          'items',
          'enum',
        };
        break;
      case ProviderKind.openai:
      case ProviderKind.neuralwatt:
      case ProviderKind.claude:
        allowed = {
          'type',
          'description',
          'properties',
          'required',
          'items',
          'enum',
        };
        break;
    }
    m.removeWhere((k, v) => !allowed.contains(k));
    return m;
  }

  static Map<String, dynamic> _deepCloneMap(Map<String, dynamic> input) {
    return jsonDecode(jsonEncode(input)) as Map<String, dynamic>;
  }

  // ============================================================================
  // Tool Definitions Builder
  // ============================================================================

  /// Build tool definitions for API call.
  ///
  /// Returns a list of tool definitions including:
  /// - Search tool (if enabled and model supports tools)
  /// - Memory tools (if assistant has memory enabled)
  /// - MCP tools (from selected servers for the assistant)
  List<Map<String, dynamic>> buildToolDefinitions(
    SettingsProvider settings,
    Assistant? assistant,
    String providerKey,
    String modelId,
    bool hasBuiltInSearch, {
    required bool workspaceEnabled,
    required bool Function(String providerKey, String modelId) isToolModel,
  }) {
    final List<Map<String, dynamic>> toolDefs = <Map<String, dynamic>>[];
    final supportsTools = isToolModel(providerKey, modelId);

    // Search tool (skip when Gemini built-in search is active)
    if (settings.searchEnabled && !hasBuiltInSearch && supportsTools) {
      toolDefs.add(SearchToolService.getToolDefinition());
    }

    // Memory tools
    if (assistant?.enableMemory == true && supportsTools) {
      toolDefs.addAll(_buildMemoryToolDefinitions());
    }

    // P1-3: plan/TODO + ask_user decision tools (no approval needed).
    if (supportsTools) {
      toolDefs.addAll(_buildCoworkToolDefinitions());
    }

    // MCP tools
    final mcpTools = _buildMcpToolDefinitions(
      settings: settings,
      assistant: assistant,
      providerKey: providerKey,
      supportsTools: supportsTools,
    );
    toolDefs.addAll(mcpTools);

    // File tools are available to every model that supports function calls.
    if (supportsTools && workspaceEnabled) {
      toolDefs.addAll(FileToolService.getToolDefinitions());
    }

    return toolDefs;
  }

  /// P1-3 Cowork tools: write_todos (log-only plan snapshot) and ask_user
  /// (decision card). Neither mutates anything dangerous — no approval.
  List<Map<String, dynamic>> _buildCoworkToolDefinitions() {
    return [
      {
        'type': 'function',
        'function': {
          'name': todoToolName,
          'description':
              'Write the plan/todo list for the current task. Send the COMPLETE list every call (last write wins) — statuses: pending, in_progress, completed. Keep exactly one item in_progress while working. Log-only UI state: the list is shown to the user as a plan card and injected into your context; it is never stored as conversation history.',
          'parameters': {
            'type': 'object',
            'properties': {
              'todos': {
                'type': 'array',
                'description': 'The full todo list snapshot.',
                'items': {
                  'type': 'object',
                  'properties': {
                    'content': {
                      'type': 'string',
                      'description': 'The task description.',
                    },
                    'status': {
                      'type': 'string',
                      'enum': [
                        todoStatusPending,
                        todoStatusInProgress,
                        todoStatusCompleted,
                      ],
                    },
                  },
                  'required': ['content', 'status'],
                },
              },
            },
            'required': ['todos'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': askUserToolName,
          'description':
              'Ask the user one or multiple-choice questions when a decision is needed (direction, trade-offs, plan confirmation). The UI shows interactive answer cards and automatically provides an Other free-text field and Skip — do NOT add those options yourself. Max 4 questions, max 4 options each. End your turn after calling this; the answers arrive as the next user input.',
          'parameters': {
            'type': 'object',
            'properties': {
              'questions': {
                'type': 'array',
                'items': {
                  'type': 'object',
                  'properties': {
                    'question': {
                      'type': 'string',
                      'description': 'The question text.',
                    },
                    'kind': {
                      'type': 'string',
                      'enum': ['single', 'multi'],
                      'description':
                          'single = one choice (radio), multi = several choices (checkboxes).',
                    },
                    'options': {
                      'type': 'array',
                      'items': {'type': 'string'},
                      'description': 'The selectable option labels.',
                    },
                  },
                  'required': ['question', 'kind', 'options'],
                },
              },
            },
            'required': ['questions'],
          },
        },
      },
    ];
  }

  /// Build memory tool definitions (create/edit/delete).
  List<Map<String, dynamic>> _buildMemoryToolDefinitions() {
    return [
      {
        'type': 'function',
        'function': {
          'name': 'create_memory',
          'description': 'create a memory record',
          'parameters': {
            'type': 'object',
            'properties': {
              'content': {
                'type': 'string',
                'description': 'The content of the memory record',
              },
            },
            'required': ['content'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'edit_memory',
          'description': 'update a memory record',
          'parameters': {
            'type': 'object',
            'properties': {
              'id': {
                'type': 'integer',
                'description': 'The id of the memory record',
              },
              'content': {
                'type': 'string',
                'description': 'The content of the memory record',
              },
            },
            'required': ['id', 'content'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'delete_memory',
          'description': 'delete a memory record',
          'parameters': {
            'type': 'object',
            'properties': {
              'id': {
                'type': 'integer',
                'description': 'The id of the memory record',
              },
            },
            'required': ['id'],
          },
        },
      },
    ];
  }

  /// Build MCP tool definitions from connected servers.
  List<Map<String, dynamic>> _buildMcpToolDefinitions({
    required SettingsProvider settings,
    required Assistant? assistant,
    required String providerKey,
    required bool supportsTools,
  }) {
    if (!supportsTools) return [];

    final mcp = contextProvider.read<McpProvider>();
    final toolSvc = contextProvider.read<McpToolService>();
    final tools = toolSvc.listAvailableToolsForAssistant(
      mcp,
      contextProvider.read<AssistantProvider>(),
      assistant?.id,
    );

    if (tools.isEmpty) return [];

    final providerCfg = settings.getProviderConfig(providerKey);
    final providerKind = ProviderConfig.classify(
      providerCfg.id,
      explicitType: providerCfg.providerType,
    );

    return tools.map((t) {
      Map<String, dynamic> baseSchema;
      if (t.schema != null && t.schema!.isNotEmpty) {
        baseSchema = Map<String, dynamic>.from(t.schema!);
      } else {
        final props = <String, dynamic>{
          for (final p in t.params) p.name: {'type': (p.type ?? 'string')},
        };
        final required = [
          for (final p in t.params.where((e) => e.required)) p.name,
        ];
        baseSchema = {
          'type': 'object',
          'properties': props,
          if (required.isNotEmpty) 'required': required,
        };
      }
      final sanitized = sanitizeToolParametersForProvider(
        baseSchema,
        providerKind,
      );
      return {
        'type': 'function',
        'function': {
          'name': t.name,
          if ((t.description ?? '').isNotEmpty) 'description': t.description,
          'parameters': sanitized,
        },
      };
    }).toList();
  }

  // ============================================================================
  // Tool Call Handler
  // ============================================================================

  /// Build tool call handler function.
  ///
  /// Returns a function that handles tool calls by name and arguments.
  /// Supports:
  /// - Search tool calls
  /// - Memory tool calls (create/edit/delete)
  /// - MCP tool calls
  Future<String> Function(String, Map<String, dynamic>)? buildToolCallHandler(
    SettingsProvider settings,
    Assistant? assistant, {
    String? conversationId,
    String? messageId,
    String? workspacePath,
  }) {
    final mcp = contextProvider.read<McpProvider>();
    final toolSvc = contextProvider.read<McpToolService>();
    // Capture AssistantProvider reference before async gap to avoid
    // use_build_context_synchronously warning
    final assistantProvider = contextProvider.read<AssistantProvider>();

    return (name, args) async {
      if (name.startsWith('file_')) {
        if (workspacePath == null || workspacePath.trim().isEmpty) {
          return 'Error: Workspace is disabled for this conversation.';
        }
        try {
          final result = await FileToolService.execute(
            name,
            args,
            workspacePath,
          );
          if (result.createdOrModifiedFilePath != null && messageId != null) {
            try {
              await chatService.addMessageFileRecord(
                messageId,
                FileRecord(
                  path: result.createdOrModifiedFilePath!,
                  fileName:
                      result.fileName ??
                      path.basename(result.createdOrModifiedFilePath!),
                  sizeBytes: result.fileSizeBytes ?? 0,
                  createdAt: DateTime.now(),
                ),
              );
            } catch (e, st) {
              // Never let FileRecord persistence break the conversation.
              FlutterLogger.log(
                'File tool "$name": failed to persist FileRecord: $e\n$st',
                tag: 'file-tool',
              );
            }
          }
          // P1-4 long-output externalization: oversized results are written
          // to {workspace}/.omnichat/tool_outputs/ and the model gets a
          // preview + retrieval guidance (single truncation path).
          return await ToolOutputExternalizer.maybeExternalize(
            toolName: name,
            result: result.text,
            workspacePath: workspacePath,
          );
        } catch (e, st) {
          // Never let an unexpected file-tool failure break the conversation.
          FlutterLogger.log(
            'File tool "$name" failed: $e\n$st',
            tag: 'file-tool',
          );
          return 'Error: $e';
        }
      }

      try {
        // P1-3: write_todos — log-only plan snapshot (whole-list rewrite).
        if (name == todoToolName) {
          if (conversationId == null || conversationId.isEmpty) {
            return jsonEncode({
              'type': 'tool_error',
              'error': 'no_conversation',
              'message': 'write_todos requires an active conversation.',
              'tool': name,
            });
          }
          try {
            final todoService = contextProvider.read<TodoService>();
            final todos = normalizeTodoItems(args['todos']);
            await todoService.setTodos(conversationId, todos);
            final inProgress = todos.where((t) => t.isInProgress).length;
            final completed = todos.where((t) => t.isCompleted).length;
            return 'Todo list updated: ${todos.length} items '
                '($inProgress in progress, $completed completed).';
          } catch (e) {
            return jsonEncode({
              'type': 'tool_error',
              'error': 'todo_store_failed',
              'message': e.toString(),
              'tool': name,
            });
          }
        }

        // P1-3: ask_user — surface the interactive answer card and end the
        // turn (Pending → answer → resume). The returned JSON is persisted
        // as the tool event content: the card renders from it, and resume
        // replaces it with the structured answer JSON.
        if (name == askUserToolName) {
          final questions = normalizeAskUserQuestions(args['questions']);
          if (questions.isEmpty) {
            return jsonEncode({
              'type': 'tool_error',
              'error': 'invalid_questions',
              'message':
                  'ask_user requires at least one question with non-empty text and options.',
              'tool': name,
            });
          }
          return jsonEncode({
            'type': askUserPendingType,
            'questions': [for (final q in questions) q.toJson()],
            'instruction':
                'These questions are now shown to the user as interactive answer cards. End your turn now and wait — the structured answers will arrive with the user next input. Do not invent or assume answers.',
          });
        }

        // Search tool
        if (name == SearchToolService.toolName && settings.searchEnabled) {
          final q = (args['query'] ?? '').toString();
          return await ToolOutputExternalizer.maybeExternalize(
            toolName: name,
            result: await SearchToolService.executeSearch(q, settings),
            workspacePath: workspacePath,
          );
        }

        // Memory tools
        final memoryResult = await _handleMemoryToolCall(
          name,
          args,
          assistant,
        );
        if (memoryResult != null) {
          return memoryResult;
        }

        // MCP tools
        final text = await toolSvc.callToolTextForAssistant(
          mcp,
          assistantProvider,
          assistantId: assistant?.id,
          toolName: name,
          arguments: args,
        );
        // P1-4 long-output externalization (workspace may be null → the
        // externalizer returns the result unchanged).
        return await ToolOutputExternalizer.maybeExternalize(
          toolName: name,
          result: text,
          workspacePath: workspacePath,
        );
      } catch (e) {
        // Catch unexpected exceptions and return error JSON to the LLM.
        // This prevents tool execution failures from terminating the chat flow.
        FlutterLogger.log(
          'Tool "$name" failed unexpectedly: $e',
          tag: 'tool-handler',
        );
        return jsonEncode({
          'type': 'tool_error',
          'error': 'execution_error',
          'message': e.toString(),
          'tool': name,
          'instruction':
              'The tool execution failed unexpectedly. You may try again with different parameters or inform the user about the issue.',
        });
      }
    };
  }

  /// Handle memory tool calls (create/edit/delete).
  ///
  /// Returns null if the tool is not a memory tool or memory is not enabled.
  Future<String?> _handleMemoryToolCall(
    String name,
    Map<String, dynamic> args,
    Assistant? assistant,
  ) async {
    if (assistant?.enableMemory != true) return null;

    try {
      final mp = contextProvider.read<MemoryProvider>();

      if (name == 'create_memory') {
        final content = (args['content'] ?? '').toString();
        if (content.isEmpty) return '';
        final m = await mp.add(assistantId: assistant!.id, content: content);
        return m.content;
      } else if (name == 'edit_memory') {
        final id = (args['id'] as num?)?.toInt() ?? -1;
        final content = (args['content'] ?? '').toString();
        if (id <= 0 || content.isEmpty) return '';
        final m = await mp.update(id: id, content: content);
        return m?.content ?? '';
      } else if (name == 'delete_memory') {
        final id = (args['id'] as num?)?.toInt() ?? -1;
        if (id <= 0) return '';
        final ok = await mp.delete(id: id);
        return ok ? 'deleted' : '';
      }
    } catch (_) {
      // Ignore memory operation errors
    }

    return null;
  }
}
