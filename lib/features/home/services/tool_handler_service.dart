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
import '../../../core/services/agent/approval.dart';
import '../../../core/services/api/chat_stream_chunk.dart' show ToolCallHandler;
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

  /// P1-1: persisted "always allow" override keys (policy snapshot, refreshed
  /// from `SettingsProvider.approvalAlwaysAllowed` whenever a handler is
  /// built). Keys are `workspace-out:{resolvedPath}`.
  Set<String> _approvalAlwaysAllowed = <String>{};

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

    // P1-3 + tool toggles: the 15 file tools and the write_todos / ask_user
    // decision tools share one gate — the conversation workspace switch
    // and the global per-tool toggles (a disabled workspace turns all of
    // them off).
    if (supportsTools) {
      toolDefs.addAll(
        buildWorkspaceToolDefinitions(
          settings,
          workspaceEnabled: workspaceEnabled,
        ),
      );
    }

    // MCP tools
    final mcpTools = _buildMcpToolDefinitions(
      settings: settings,
      assistant: assistant,
      providerKey: providerKey,
      supportsTools: supportsTools,
    );
    toolDefs.addAll(mcpTools);

    return toolDefs;
  }

  /// Workspace tools (15 file tools + write_todos + ask_user) gated by the
  /// workspace switch and the global per-tool toggles. Static and pure so
  /// the gating policy is unit-testable without a provider tree.
  static List<Map<String, dynamic>> buildWorkspaceToolDefinitions(
    SettingsProvider settings, {
    required bool workspaceEnabled,
  }) {
    if (!workspaceEnabled) return const [];
    return <Map<String, dynamic>>[
      ...FileToolService.getToolDefinitions(),
      ..._buildCoworkToolDefinitions(),
    ].where((def) {
      final name = ((def['function'] as Map)['name'] ?? '').toString();
      return name.isNotEmpty && settings.isWorkspaceToolEnabled(name);
    }).toList();
  }

  /// P1-3 Cowork tools: write_todos (log-only plan snapshot) and ask_user
  /// (decision card). Neither mutates anything dangerous — no approval.
  static List<Map<String, dynamic>> _buildCoworkToolDefinitions() {
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
  ///
  /// P1-4 id-aware contract: the optional [ToolCallHandler.toolCallId]
  /// parameter carries the provider call id when known — it keys the
  /// approval Pending event id (kernel path) and the externalized output
  /// filename. Closures of the legacy `(name, args)` shape remain
  /// assignable.
  ///
  /// P1-1 v1.6: [approvedResolvedPath] is set by the approval resume path —
  /// the user approved this concrete out-of-workspace path, so the call
  /// skips re-classification and executes against it exactly once.
  ToolCallHandler? buildToolCallHandler(
    SettingsProvider settings,
    Assistant? assistant, {
    String? conversationId,
    String? messageId,
    String? workspacePath,
    String? approvedResolvedPath,
  }) {
    // P1-1 v1.6: refresh the "always allow" policy snapshot from settings so
    // persisted workspace-out overrides are actually consulted (the set
    // previously stayed empty and overrides never reached the engine).
    _approvalAlwaysAllowed = settings.approvalAlwaysAllowed.toSet();
    final mcp = contextProvider.read<McpProvider>();
    final toolSvc = contextProvider.read<McpToolService>();
    // Capture AssistantProvider reference before async gap to avoid
    // use_build_context_synchronously warning
    final assistantProvider = contextProvider.read<AssistantProvider>();

    return (name, args, {String? toolCallId}) async {
      // Defense in depth: a tool disabled globally (or by the workspace
      // switch) must never execute even if a stale request still carries
      // its definition.
      if (_isWorkspaceToolGloballyDisabled(name)) {
        return jsonEncode(<String, dynamic>{
          'type': 'tool_error',
          'error': 'tool_disabled',
          'message': 'This tool is disabled in the workspace tools settings.',
          'tool': name,
        });
      }

      // P1-1: workspace tools execute under a per-conversation cwd; resolve
      // the sandbox root the same way FileToolService does so the approval
      // policy classifies the same path the executor will use.
      String? effectiveWorkspace;
      if (name.startsWith('file_')) {
        if (workspacePath == null || workspacePath.trim().isEmpty) {
          return 'Error: Workspace is disabled for this conversation.';
        }
        try {
          effectiveWorkspace = await FileToolService.prepareWorkspaceFor(
            workspacePath,
          );
        } catch (_) {
          effectiveWorkspace = null;
        }
      }

      // P1-1: approval gate (ADR-A5) — classify BEFORE execution; an `ask`
      // decision returns the approval_required JSON without running the tool
      // and marks the event Pending so the card offers Approve / Deny. An
      // approved resume (`approvedResolvedPath` set) skips classification:
      // the user's decision IS the gate, and the call executes once below.
      final decision = name.startsWith('file_') && approvedResolvedPath != null
          ? _PendingDecision(
              state: ApprovalDecision.allow,
              resolvedPath: approvedResolvedPath,
            )
          : _classifyApproval(
              name,
              args,
              workspacePath: effectiveWorkspace,
            );
      if (decision.state == ApprovalDecision.ask ||
          decision.state == ApprovalDecision.deny) {
        if (messageId != null && conversationId != null) {
          try {
            await chatService.upsertToolEvent(
              messageId,
              // Kernel path: key the Pending event by the REAL provider
              // call id so resolveApproval / setToolEventApprovalState
              // match exactly the event the synthetic toolResults upsert
              // writes (legacy path has no id here; the fallback matcher
              // in upsertToolEvent keeps that path working).
              id:
                  (toolCallId != null && toolCallId.trim().isNotEmpty)
                  ? toolCallId
                  : decision.toolCallId,
              name: name,
              arguments: args,
              content: decision.content,
              approvalState: decision.state == ApprovalDecision.ask
                  ? approvalStatePending
                  : approvalStateDenied,
            );
          } catch (_) {}
        }
        return decision.content;
      }

      if (name.startsWith('file_')) {
        try {
          final result = await FileToolService.execute(
            name,
            args,
            workspacePath,
            approvedOutsidePath: decision.resolvedPath,
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
            toolCallId: toolCallId,
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

        // Search tool — dispatched through the multi-provider engine
        // (fallback / round-robin). The returned JSON is unchanged; the
        // provider trace is persisted as UI-only tool-event extras.
        if (name == SearchToolService.toolName && settings.searchEnabled) {
          final q = (args['query'] ?? '').toString();
          final trace = await SearchToolService.executeSearchWithTrace(
            q,
            settings,
          );
          if (messageId != null && messageId.isNotEmpty) {
            try {
              await chatService.upsertToolEvent(
                messageId,
                id: (toolCallId ?? '').trim(),
                name: name,
                arguments: args,
                content: trace.json,
                extras: <String, dynamic>{
                  if (trace.providerName != null)
                    'searchProvider': trace.providerName,
                  if (trace.fallbackFromName != null)
                    'searchFallbackFrom': trace.fallbackFromName,
                },
              );
            } catch (_) {
              // Extras are best-effort UI metadata — never break a search.
            }
          }
          return await ToolOutputExternalizer.maybeExternalize(
            toolName: name,
            result: trace.json,
            workspacePath: workspacePath,
            toolCallId: toolCallId,
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
          toolCallId: toolCallId,
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

  // ==========================================================================
  // P1-1 Approval policy (ADR-A5/A8/A9)
  // ==========================================================================

  /// Classify one tool call against the P1-1 policy engine. The generation
  /// policy snapshot was taken in [buildToolCallHandler]; only [name],
  /// [args] and the resolved workspace are consulted here.
  _PendingDecision _classifyApproval(
    String name,
    Map<String, dynamic> args, {
    String? workspacePath,
  }) {
    // Non-callable decision tools and in-sandbox flows skip the engine.
    if (name == askUserToolName || name == todoToolName) {
      return _PendingDecision.allow();
    }

    final settings = _safeReadSettings();
    final alwaysAllowed = _approvalAlwaysAllowed;
    final strict = settings?.approvalStrictModeV1 ?? false;

    // --- Workspace (file_*) tools: sandbox boundary → ask (ADR-A8 v1.5) ---
    if (name.startsWith('file_')) {
      if (workspacePath == null || workspacePath.trim().isEmpty) {
        // No workspace → the executor will refuse anyway; treat as deny so
        // no Pending card is raised for a call that cannot run.
        return _PendingDecision(
          state: ApprovalDecision.deny,
          toolCallId: _approvalCallId(name),
          content: jsonEncode(<String, dynamic>{
            'type': 'tool_error',
            'error': 'workspace_disabled',
            'message': 'Workspace is disabled for this conversation.',
            'tool': name,
          }),
        );
      }
      final pathProbe = FileToolService.probePathSafety(
        (args['path'] ?? args['source'] ?? '').toString(),
        workspacePath,
      );
      final decision = decideApproval(
        ApprovalContext(
          isWorkspaceTool: true,
          pathInsideWorkspace: pathProbe.inside,
          resolvedPath: pathProbe.resolvedPath,
          alwaysAllowedKeys: alwaysAllowed,
          strictMode: strict,
        ),
      );
      if (decision == ApprovalDecision.allow) {
        // Override-approved out-of-bounds call: carry the concrete resolved
        // path so the executor runs against it (the approval IS the gate;
        // blocked extensions / size caps still apply downstream).
        return _PendingDecision(
          state: ApprovalDecision.allow,
          resolvedPath: pathProbe.inside ? null : pathProbe.resolvedPath,
        );
      }
      final content = decision == ApprovalDecision.ask
          ? buildApprovalPendingContent(
              toolName: name,
              resolvedPath: pathProbe.resolvedPath,
              outsideWorkspace: !pathProbe.inside,
              arguments: args,
              previewDiff: buildEditPreviewDiff(args),
            )
          : buildApprovalDeniedContent(toolName: name);
      return _PendingDecision(
        state: decision,
        toolCallId: _approvalCallId(name),
        content: content,
      );
    }

    // MCP tools are deliberately NOT approval-gated (2026-09-10): the
    // black-box policy source was removed — per-call MCP approval proved
    // unnecessary, and the approve side of the engine never actually
    // executed the call. MCP calls fall through to `allow` and run directly.
    return _PendingDecision.allow();
  }

  /// Stable per-call id used to persist the Pending tool event before the
  /// provider's own call id is known (the kernel path executes tools with
  /// the provider id; the event is later matched/upserted by name when the
  /// provider id arrives, or resumed by this id).
  String _approvalCallId(String name) => 'approval_$name';

  SettingsProvider? _safeReadSettings() {
    try {
      return contextProvider.read<SettingsProvider>();
    } catch (_) {
      return null;
    }
  }

  /// True when [name] is a workspace tool (file_* / write_todos /
  /// ask_user) the user disabled globally. Tolerates settings access
  /// failures (e.g. test doubles) by treating every tool as enabled.
  bool _isWorkspaceToolGloballyDisabled(String name) {
    if (!name.startsWith('file_') &&
        name != todoToolName &&
        name != askUserToolName) {
      return false;
    }
    final settings = _safeReadSettings();
    if (settings == null) return false;
    try {
      return !settings.isWorkspaceToolEnabled(name);
    } catch (_) {
      return false;
    }
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

/// The outcome of the P1-1 approval classification for one tool call.
class _PendingDecision {
  const _PendingDecision({
    required this.state,
    this.toolCallId = '',
    this.content = '',
    this.resolvedPath,
  });

  const _PendingDecision.allow()
    : state = ApprovalDecision.allow,
      toolCallId = '',
      content = '',
      resolvedPath = null;

  final ApprovalDecision state;
  final String toolCallId;
  final String content;

  /// The approved concrete out-of-workspace path handed to the executor when
  /// the call runs (set when an override allowed an out-of-bounds workspace
  /// call). Null for ordinary in-sandbox calls.
  final String? resolvedPath;
}
