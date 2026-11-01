// Ported from Chevey339/kelivo@05eef503b6e7cda14de897373b79bab7bebe35b9
// (`lib/core/services/auth/codex_request.dart`, AGPL-3.0), modified for
// OmniChat on 2026-11-01. See THIRD_PARTY_NOTICES.md.
//
// Codex Responses wire shaping. A pure function over the already-built body so
// every retry / tool follow-up round recomputes from a clean payload (C4) and
// the wrapper never double-injects.

import 'dart:convert';

import '../../models/provider_oauth.dart';

class CodexRequestContext {
  const CodexRequestContext({
    required this.accountId,
    required this.sessionId,
    this.conversationId,
    this.requestId,
    this.residency,
    this.routingHint,
    this.clientVersion = ProviderOAuthConstants.codexClientVersion,
  });

  final String accountId;
  final String sessionId;
  final String? conversationId;
  final String? requestId;
  final String? residency;
  final String? routingHint;
  final String clientVersion;
}

/// Params the Codex endpoint rejects outright; upstream removes them from every
/// round, including `max_output_tokens` (the subscription endpoint owns the
/// ceiling).
const Set<String> _codexStrippedParams = <String>{
  'temperature',
  'top_p',
  'top_k',
  'min_p',
  'presence_penalty',
  'frequency_penalty',
  'repetition_penalty',
  'logprobs',
  'top_logprobs',
  'max_output_tokens',
  'max_completion_tokens',
  'max_tokens',
  'stop',
};

const String codexReasoningInclude = 'reasoning.encrypted_content';

/// Shapes a Responses API body for the Codex subscription endpoint.
Map<String, dynamic> applyCodexRequest(
  Map<String, dynamic> body, {
  required CodexRequestContext ctx,
}) {
  final out = Map<String, dynamic>.from(body);
  for (final key in _codexStrippedParams) {
    out.remove(key);
  }
  out['store'] = false;
  out['stream'] = true;
  out.putIfAbsent('instructions', () => '');
  // Stable cache key: the provider reuses prefix cache across tool rounds.
  if (ctx.sessionId.trim().isNotEmpty) {
    out.putIfAbsent('prompt_cache_key', () => ctx.sessionId.trim());
  }

  // Normalize replay items: item references are not accepted, and carried
  // server ids would point at another conversation / already-stored item.
  final rawInput = out['input'];
  if (rawInput is List) {
    out['input'] = _repairToolPairs(<dynamic>[
      for (final item in rawInput)
        if (item is! Map || item['type'] != 'item_reference')
          item is Map && item['type'] != 'computer_call'
              ? (Map<String, dynamic>.from(item)..remove('id'))
              : item,
    ]);
  }

  // `include` is additive: the web-search source override writes its own list
  // and the follow-up rounds replay it, so merge instead of overwrite (C8).
  final include = <String>[];
  final includeRaw = out['include'];
  for (final value in includeRaw is List ? includeRaw : const []) {
    final s = value.toString();
    if (s.isNotEmpty && !include.contains(s)) include.add(s);
  }
  if (!include.contains(codexReasoningInclude)) {
    include.add(codexReasoningInclude);
  }
  out['include'] = include;

  // The endpoint bills/streams even for instruction-only utility calls, but it
  // requires at least one user input item. Mirror the last instruction as user
  // content when the caller provided nothing else.
  final instructions = (out['instructions'] ?? '').toString().trim();
  final input = out['input'];
  final emptyInput =
      input == null ||
      (input is List && input.isEmpty) ||
      (input is String && input.trim().isEmpty);
  if (emptyInput && instructions.isNotEmpty) {
    out['input'] = <Map<String, dynamic>>[
      <String, dynamic>{
        'role': 'user',
        'content': <Map<String, dynamic>>[
          <String, dynamic>{'type': 'input_text', 'text': instructions},
        ],
      },
    ];
    out.remove('instructions');
  }

  // Codex only accepts `reasoning.summary`; keep the caller's effort dialect
  // untouched (the Responses writer already produced it).
  return out;
}

const Map<String, String> _codexToolOutputTypes = <String, String>{
  'function_call': 'function_call_output',
  'custom_tool_call': 'custom_tool_call_output',
  'computer_call': 'computer_call_output',
};

/// The Codex endpoint rejects a request that carries half a tool round. Turn
/// orphaned outputs into assistant text and close orphaned calls with an
/// explicit placeholder result (plan §2.1: 工具配對修復).
List<dynamic> _repairToolPairs(List<dynamic> input) {
  final calls = <String, String>{};
  final outputs = <String, String>{};
  for (final item in input.whereType<Map>()) {
    final id = item['call_id'];
    if (id is! String) continue;
    final outputType = _codexToolOutputTypes[item['type']];
    if (outputType != null) calls[id] = outputType;
    if (_codexToolOutputTypes.containsValue(item['type'])) {
      outputs[id] = item['type'] as String;
    }
  }

  final result = <dynamic>[];
  for (final item in input) {
    final id = item is Map ? item['call_id'] : null;
    if (item is! Map || id is! String) {
      result.add(item);
      continue;
    }
    final type = item['type'];
    if (_codexToolOutputTypes.containsValue(type) && calls[id] != type) {
      var text = item['output'] is String
          ? item['output'] as String
          : jsonEncode(item['output']);
      if (text.length > 16000) {
        text = '${text.substring(0, 16000)}\n...[truncated]';
      }
      result.add(<String, dynamic>{
        'type': 'message',
        'role': 'assistant',
        'content':
            '[Previous ${item['name'] ?? 'tool'} result; call_id=$id]: $text',
      });
    } else if (_codexToolOutputTypes.containsKey(type) &&
        outputs[id] != _codexToolOutputTypes[type]) {
      if (type == 'computer_call') {
        result.add(<String, dynamic>{
          'type': 'message',
          'role': 'assistant',
          'content':
              '[Computer call interrupted before a screenshot was recorded; '
              'call_id=$id]',
        });
      } else {
        result.addAll(<dynamic>[
          item,
          <String, dynamic>{
            'type': _codexToolOutputTypes[type],
            'call_id': id,
            'output':
                '[No tool output recorded: the tool call was interrupted '
                'before it produced a result.]',
          },
        ]);
      }
    } else {
      result.add(item);
    }
  }
  return result;
}

/// Session headers the Codex backend attributes a conversation by (C15).
/// Stable per conversation — never random per request.
Map<String, String> codexOAuthHeaders(
  ProviderOAuthCredentials credentials, {
  required String sessionId,
  String? conversationId,
  String? requestId,
  String clientVersion = ProviderOAuthConstants.codexClientVersion,
}) {
  final accountId = credentials.accountId?.trim() ?? '';
  return <String, String>{
    'Authorization': 'Bearer ${credentials.accessToken}',
    'originator': ProviderOAuthConstants.codexOriginator,
    'version': clientVersion,
    'OpenAI-Beta': ProviderOAuthConstants.codexResponsesBeta,
    'User-Agent': ProviderOAuthConstants.codexUserAgent,
    'Accept': 'text/event-stream',
    'session_id': sessionId,
    if ((conversationId ?? '').isNotEmpty) 'conversation_id': conversationId!,
    if ((requestId ?? '').isNotEmpty) 'x-client-request-id': requestId!,
    if (accountId.isNotEmpty) 'chatgpt-account-id': accountId,
    if ((credentials.extra['residency'] ?? '').toString().isNotEmpty)
      'x-openai-internal-codex-residency': credentials.extra['residency']
          .toString(),
    if ((credentials.extra['routingHint'] ?? '').toString().isNotEmpty)
      'x-codex-routing-hint': credentials.extra['routingHint'].toString(),
  };
}
