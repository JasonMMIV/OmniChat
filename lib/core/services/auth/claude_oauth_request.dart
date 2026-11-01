// Ported from Chevey339/kelivo@05eef503b6e7cda14de897373b79bab7bebe35b9
// (`lib/core/services/auth/claude_oauth_request.dart`, AGPL-3.0), modified for
// OmniChat on 2026-11-01. See THIRD_PARTY_NOTICES.md.
//
// Claude Code fingerprint layer. Every function here is pure and idempotent:
// the wrapper hands in the untouched body bytes each time, so a retry or a tool
// follow-up round can never stack prefixes or mismatch `cch` (plan C4).

import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

import '../../models/provider_oauth.dart';

class ClaudeOAuthRequestContext {
  const ClaudeOAuthRequestContext({
    required this.deviceId,
    required this.sessionId,
    required this.accountId,
    this.cliVersion = ProviderOAuthConstants.claudeCodeVersion,
    this.promptCaching = true,
    this.cacheTtl = '1h',
  });

  final String deviceId;
  final String sessionId;
  final String accountId;
  final String cliVersion;
  final bool promptCaching;
  final String cacheTtl;
}

/// Header Anthropic's CLI mints with each request; the `cch` suffix must match
/// the payload that follows it.
String claudeBillingHeader({
  required String cliVersion,
  required String fingerprint,
  required String cch,
}) =>
    'x-anthropic-billing-header: cc_version=$cliVersion.$fingerprint; '
    'cc_entrypoint=cli; cch=$cch;';

const String claudeCodeIdentity =
    "You are Claude Code, Anthropic's official CLI for Claude.";

Map<String, dynamic> _deepCopy(Map<String, dynamic> input) {
  try {
    final decoded = jsonDecode(jsonEncode(input));
    if (decoded is Map) return decoded.cast<String, dynamic>();
  } catch (_) {}
  return Map<String, dynamic>.from(input);
}

Map<String, dynamic> _cacheControl(String ttl) => <String, dynamic>{
  'type': 'ephemeral',
  if (ttl == '1h') 'ttl': '1h',
};

/// Prefixes client tool names so they cannot collide with Anthropic's server
/// tools. Responses are un-prefixed by [restoreClaudeOAuthToolName].
String claudeOAuthToolName(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return trimmed;
  if (ProviderOAuthConstants.claudeServerToolNames.contains(trimmed)) {
    return trimmed;
  }
  if (trimmed.startsWith('web_search') ||
      trimmed.startsWith('code_execution') ||
      trimmed.startsWith('computer')) {
    return trimmed;
  }
  return '_$trimmed';
}

String restoreClaudeOAuthToolName(String name) {
  final trimmed = name.trim();
  if (trimmed.startsWith('_') && trimmed.length > 1) {
    return trimmed.substring(1);
  }
  return trimmed;
}

/// Shapes a Messages API body for the Claude OAuth (Claude Code) surface.
Map<String, dynamic> encodeClaudeOAuthRequest(
  Map<String, dynamic> body, {
  required ClaudeOAuthRequestContext ctx,
  // The chat wrapper already decoded a disposable map from the untouched body
  // bytes, so production passes `false` to avoid a full deep copy per request.
  bool copy = true,
}) {
  final out = copy ? _deepCopy(body) : body;

  // The standard wire puts cache_control on content blocks; the legacy
  // top-level key is only tolerated by some proxies (plan C7 / Spike F).
  out.remove('cache_control');

  // ---- system: string -> blocks --------------------------------------
  final fingerprint = claudeBillingFingerprint(
    _firstUserText(out['messages']),
    cliVersion: ctx.cliVersion,
  );
  final systemRaw = out['system'];
  final systemBlocks = <Map<String, dynamic>>[];
  systemBlocks.add(<String, dynamic>{
    'type': 'text',
    'text': claudeBillingHeader(
      cliVersion: ctx.cliVersion,
      fingerprint: fingerprint,
      cch: claudeCchPlaceholder,
    ),
  });
  if (ctx.promptCaching) {
    systemBlocks.add(<String, dynamic>{
      'type': 'text',
      'text': claudeCodeIdentity,
      'cache_control': _cacheControl(ctx.cacheTtl),
    });
  } else {
    systemBlocks.add(<String, dynamic>{
      'type': 'text',
      'text': claudeCodeIdentity,
    });
  }
  if (systemRaw is String && systemRaw.trim().isNotEmpty) {
    systemBlocks.add(<String, dynamic>{'type': 'text', 'text': systemRaw});
  } else if (systemRaw is List) {
    for (final item in systemRaw) {
      if (item is String && item.trim().isNotEmpty) {
        systemBlocks.add(<String, dynamic>{'type': 'text', 'text': item});
      } else if (item is Map) {
        final block = item.cast<String, dynamic>();
        systemBlocks.add(<String, dynamic>{
          'type': (block['type'] ?? 'text').toString(),
          ...block,
        });
      }
    }
  }
  out['system'] = systemBlocks;

  // ---- tools: client names get the `_` prefix ------------------------
  final toolsRaw = out['tools'];
  if (toolsRaw is List) {
    final tools = <Map<String, dynamic>>[];
    for (final tool in toolsRaw) {
      if (tool is! Map) continue;
      final copy = tool.cast<String, dynamic>();
      final name = (copy['name'] ?? '').toString();
      if (name.isNotEmpty) copy['name'] = claudeOAuthToolName(name);
      tools.add(copy);
    }
    out['tools'] = tools;
  }

  // Historical tool_use blocks must use the same prefixed names as the tool
  // definitions, otherwise the next round references a tool that no longer
  // exists in `tools`.
  final messagesRaw = out['messages'];
  if (messagesRaw is List) {
    for (final message in messagesRaw) {
      if (message is! Map) continue;
      final content = message['content'];
      if (content is! List) continue;
      for (final block in content) {
        if (block is! Map || block['type'] != 'tool_use') continue;
        final name = (block['name'] ?? '').toString();
        if (name.isNotEmpty) block['name'] = claudeOAuthToolName(name);
      }
    }
  }

  // A forced tool choice references a tool by name and must be prefixed too.
  final toolChoice = out['tool_choice'];
  if (toolChoice is Map && toolChoice['type'] == 'tool') {
    final name = (toolChoice['name'] ?? '').toString();
    if (name.isNotEmpty) toolChoice['name'] = claudeOAuthToolName(name);
  }

  // ---- metadata identity ---------------------------------------------
  final metadata = <String, dynamic>{};
  final existingMetadata = out['metadata'];
  if (existingMetadata is Map) {
    metadata.addAll(existingMetadata.cast<String, dynamic>());
  }
  metadata['user_id'] = jsonEncode(<String, String>{
    'device_id': ctx.deviceId,
    'session_id': ctx.sessionId,
    // Bootstrap identity is best-effort; an empty account_uuid is rejected by
    // the OAuth surface, so omit it when it is unknown (upstream contract).
    if (ctx.accountId.trim().isNotEmpty) 'account_uuid': ctx.accountId,
  });
  out['metadata'] = metadata;

  // ---- max_tokens / thinking budget ----------------------------------
  final rawMaxTokens = out['max_tokens'];
  var maxTokens = rawMaxTokens is num
      ? rawMaxTokens.toInt()
      : ProviderOAuthConstants.claudeMaxTokensCap;
  maxTokens = maxTokens.clamp(1, ProviderOAuthConstants.claudeMaxTokensCap);
  final thinking = out['thinking'];
  if (thinking is Map) {
    final thinkingMap = thinking.cast<String, dynamic>();
    final budgetRaw = thinkingMap['budget_tokens'];
    final budget = budgetRaw is num ? budgetRaw.toInt() : null;
    if (thinkingMap['type'] == 'enabled' && budget != null && budget > 0) {
      final required =
          budget + ProviderOAuthConstants.claudeThinkingOutputReserve;
      if (maxTokens < required) {
        maxTokens = math.min(
          ProviderOAuthConstants.claudeMaxTokensCap,
          required,
        );
      }
      // The OAuth surface requires room for visible output below the budget;
      // when the 64k cap prevents that, shrink the budget instead.
      final allowedBudget = math.max(
        1024,
        maxTokens - ProviderOAuthConstants.claudeThinkingOutputReserve,
      );
      if (budget > allowedBudget) {
        thinkingMap['budget_tokens'] = allowedBudget;
      }
    }
    out['thinking'] = thinkingMap;
  }
  out['max_tokens'] = maxTokens;

  // ---- cache breakpoints (max 4) -------------------------------------
  if (ctx.promptCaching) {
    _applyCacheBreakpoints(out, ctx.cacheTtl);
  }

  // ---- fixed key order + cch -----------------------------------------
  // The OAuth surface fingerprints the exact serialized body. The map handed
  // back must therefore be ordered exactly like the string that was hashed
  // (the wrapper jsonEncodes it verbatim), and the cch suffix is spliced into
  // the five-character placeholder in place so the length — and thus the
  // hash input for every other byte — never changes (plan C4).
  const order = <String>[
    'model',
    'system',
    'messages',
    'tools',
    'metadata',
    'max_tokens',
    'thinking',
    'context_management',
    'output_config',
    'stream',
  ];
  final ordered = <String, dynamic>{
    for (final key in order)
      if (out.containsKey(key)) key: out[key],
    for (final entry in out.entries)
      if (!order.contains(entry.key)) entry.key: entry.value,
  };
  final encoded = jsonEncode(ordered);
  final digest = xxh64Hex(utf8.encode(encoded), seed: claudeCchSeed);
  final cch = digest.substring(digest.length - 5);
  final billing = (ordered['system'] as List).first as Map;
  billing['text'] = (billing['text'] as String).replaceFirst(
    'cch=$claudeCchPlaceholder',
    'cch=$cch',
  );
  return ordered;
}

/// Placeholder written into the billing header before the payload hash exists;
/// it is exactly as wide as the final suffix so the serialized length is stable.
const String claudeCchPlaceholder = '00000';

/// Seed the pinned upstream client uses for the payload fingerprint.
const int claudeCchSeed = 0x4d659218e32a3268;

/// First visible text of the first user turn — the billing fingerprint input.
String _firstUserText(Object? messages) {
  if (messages is! List) return '';
  for (final message in messages) {
    if (message is! Map || message['role'] != 'user') continue;
    final content = message['content'];
    if (content is String) return content;
    if (content is List) {
      for (final block in content) {
        if (block is Map && block['type'] == 'text') {
          return (block['text'] ?? '').toString();
        }
      }
    }
    return '';
  }
  return '';
}

/// `<sha256 prefix of a fixed salt + three body characters + cli version>`.
/// Matches the pinned upstream client so the billing header looks native even
/// when the request carries no user text yet.
String claudeBillingFingerprint(
  String firstUserText, {
  required String cliVersion,
}) {
  final seed = <int>[4, 7, 20]
      .map((index) => index < firstUserText.length ? firstUserText[index] : '0')
      .join();
  return sha256
      .convert(utf8.encode('59cf53e54c78$seed$cliVersion'))
      .toString()
      .substring(0, 3);
}

void _applyCacheBreakpoints(Map<String, dynamic> out, String ttl) {
  final cache = _cacheControl(ttl);
  final system = out['system'];
  final tools = out['tools'];
  final messages = out['messages'];

  // Existing controls may come from a caller-supplied system/tool block. Count
  // them before adding anything so the request never exceeds the four-block
  // ceiling.
  var used = 0;
  if (system is List) {
    for (final block in system) {
      if (block is Map && block['cache_control'] != null) used++;
    }
  }
  if (tools is List) {
    for (final tool in tools) {
      if (tool is Map && tool['cache_control'] != null) used++;
    }
  }
  if (messages is List) {
    for (final message in messages) {
      if (message is! Map) continue;
      final content = message['content'];
      if (content is! List) continue;
      for (final block in content) {
        if (block is Map && block['cache_control'] != null) used++;
      }
    }
  }

  // Tools: mark the last loadable tool definition once.
  if (used < 4 && tools is List && tools.isNotEmpty) {
    final hasControl = tools.any(
      (tool) => tool is Map && tool['cache_control'] != null,
    );
    if (!hasControl) {
      for (final tool in tools.reversed) {
        if (tool is Map && tool['defer_loading'] != true) {
          tool['cache_control'] = <String, dynamic>{...cache};
          used++;
          break;
        }
      }
    }
  }

  if (used >= 4 || messages is! List || messages.isEmpty) return;

  final userIndices = <int>[];
  for (var index = 0; index < messages.length; index++) {
    final message = messages[index];
    if (message is! Map ||
        message['role'] != 'user' ||
        message['clear_at'] == 'next_user_message') {
      continue;
    }
    final content = message['content'];
    final hasVisibleBlock =
        content is String ||
        (content is List &&
            content.whereType<Map>().any(
              (block) => block['type'] != 'tool_result',
            ));
    if (hasVisibleBlock) userIndices.add(index);
  }

  final trailing = <int>[];
  for (var index = messages.length - 1; index >= 0; index--) {
    final message = messages[index];
    if (message is! Map || message['clear_at'] == 'next_user_message') {
      continue;
    }
    trailing.add(index);
    if (trailing.length == 2) break;
  }

  final candidates = <int>{
    if (trailing.isNotEmpty) trailing.first,
    for (var ordinal = userIndices.length - 1; ordinal >= 0; ordinal--)
      if ((ordinal + 1) % 15 == 0) userIndices[ordinal],
    ...trailing,
  };

  var budget = 4 - used;
  for (final index in candidates) {
    if (budget <= 0) break;
    final message = messages[index];
    if (message is! Map) continue;
    final content = message['content'];
    if (content is String && content.isNotEmpty) {
      message['content'] = <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'text',
          'text': content,
          'cache_control': <String, dynamic>{...cache},
        },
      ];
      budget--;
      continue;
    }
    if (content is! List) continue;
    // Walking backwards mirrors Anthropic's rule: the breakpoint belongs on
    // the last cacheable block, never on thinking or an empty text block.
    for (final block in content.reversed) {
      if (block is! Map) continue;
      final type = block['type'];
      if (const <String>{
        'thinking',
        'redacted_thinking',
        'fallback',
        'tool_addition',
        'tool_removal',
      }.contains(type)) {
        continue;
      }
      if (type == 'text' && (block['text'] as String? ?? '').isEmpty) {
        continue;
      }
      if (block['cache_control'] == null) {
        block['cache_control'] = <String, dynamic>{...cache};
        budget--;
      }
      break;
    }
  }
}

/// Merges the caller's `anthropic-beta` with the required set.
///
/// Callers may add feature betas through extra headers; overwriting them would
/// silently disable those features. `extended-cache-ttl` is required for the
/// 1h prompt-cache TTL, and `context-1m` is stripped (pinned upstream rule).
Map<String, String> claudeMergedBetaHeaders(
  String? existing, {
  bool extendedCacheTtl = false,
}) {
  final betas = <String>{...ProviderOAuthConstants.claudeBetaHeaders};
  if (existing != null) {
    betas.addAll(
      existing
          .split(',')
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty),
    );
  }
  if (extendedCacheTtl) betas.add('extended-cache-ttl-2025-04-11');
  betas.remove('context-1m-2025-08-07');
  return <String, String>{'anthropic-beta': betas.join(',')};
}

/// Request headers for every OAuth Claude call (chat, models, usage, refresh).
/// Non-chat callers must use this generator instead of hand-building headers
/// (plan C1).
Map<String, String> claudeOAuthHeaders(
  ProviderOAuthCredentials credentials, {
  String? sessionId,
  String cliVersion = ProviderOAuthConstants.claudeCodeVersion,
  bool acceptEventStream = true,
  bool includeSessionHeader = true,
}) {
  final session = (sessionId ?? credentials.sessionId).trim();
  return <String, String>{
    'Authorization': 'Bearer ${credentials.accessToken}',
    'anthropic-version': '2023-06-01',
    'anthropic-beta': ProviderOAuthConstants.claudeBetaHeaders.join(','),
    'anthropic-dangerous-direct-browser-access': 'true',
    'user-agent': 'claude-cli/$cliVersion (external, cli)',
    'x-app': 'cli',
    'X-Stainless-Lang': 'js',
    'X-Stainless-Package-Version': ProviderOAuthConstants.claudeCodeSdkVersion,
    'X-Stainless-OS': 'Linux',
    'X-Stainless-Runtime': 'node',
    'X-Stainless-Runtime-Version': 'v26.3.0',
    'X-Stainless-Retry-Count': '0',
    'X-Stainless-Timeout': '600',
    'Accept': acceptEventStream ? 'text/event-stream' : 'application/json',
    if (includeSessionHeader && session.isNotEmpty)
      'X-Claude-Code-Session-Id': session,
  };
}

/// `/v1/messages?beta=true` — the OAuth surface requires the query flag.
Uri claudeOAuthMessagesUrl(String baseUrl) {
  final base = baseUrl.endsWith('/')
      ? baseUrl.substring(0, baseUrl.length - 1)
      : baseUrl;
  return Uri.parse('$base/messages?beta=true');
}

/// Extracts the version from a `claude_code_version_too_old` 400 body.
String? claudeRequiredVersionFromError(String body) {
  if (!body.contains('claude_code_version_too_old')) return null;
  final match = RegExp(
    r'(?:requires?|minimum|version)[^0-9]{0,24}(\d+\.\d+\.\d+)',
    caseSensitive: false,
  ).firstMatch(body);
  return match?.group(1);
}

/// Deterministic JSON with sorted keys — the input to the `cch` hash.
String canonicalJson(Object? value) {
  final buffer = StringBuffer();
  void write(Object? v) {
    if (v == null) {
      buffer.write('null');
    } else if (v is Map) {
      final keys = v.keys.map((e) => e.toString()).toList()..sort();
      buffer.write('{');
      for (var i = 0; i < keys.length; i++) {
        if (i > 0) buffer.write(',');
        buffer.write(jsonEncode(keys[i]));
        buffer.write(':');
        write(v[keys[i]]);
      }
      buffer.write('}');
    } else if (v is List) {
      buffer.write('[');
      for (var i = 0; i < v.length; i++) {
        if (i > 0) buffer.write(',');
        write(v[i]);
      }
      buffer.write(']');
    } else if (v is String) {
      buffer.write(jsonEncode(v));
    } else if (v is num || v is bool) {
      buffer.write(v.toString());
    } else {
      buffer.write(jsonEncode(v.toString()));
    }
  }

  write(value);
  return buffer.toString();
}

// ---------------------------------------------------------------------------
// XXH64 (public-domain algorithm, inline implementation — no new dependency,
// matching upstream and plan §10.3).
// ---------------------------------------------------------------------------

const int _mask64 = 0xFFFFFFFFFFFFFFFF;
const int _prime1 = 0x9E3779B185EBCA87;
const int _prime2 = 0xC2B2AE3D27D4EB4F;
const int _prime3 = 0x165667B19E3779F9;
const int _prime4 = 0x85EBCA77C2B2AE63;
const int _prime5 = 0x27D4EB2F165667C5;

int _rotl64(int x, int r) =>
    ((x << r) & _mask64) | ((x & _mask64) >>> (64 - r));

int _readUint64LE(List<int> data, int offset) {
  var value = 0;
  for (var i = 7; i >= 0; i--) {
    value = ((value << 8) | data[offset + i]) & _mask64;
  }
  return value;
}

int _readUint32LE(List<int> data, int offset) =>
    data[offset] |
    (data[offset + 1] << 8) |
    (data[offset + 2] << 16) |
    (data[offset + 3] << 24);

int _round(int acc, int input) {
  var a = (acc + ((input * _prime2) & _mask64)) & _mask64;
  a = _rotl64(a, 31);
  return (a * _prime1) & _mask64;
}

int _mergeRound(int acc, int value) {
  var a = acc ^ _round(0, value);
  a = ((a * _prime1) + _prime4) & _mask64;
  return a;
}

/// 64-bit XXH64 as hex (lowercase, 16 chars).
String xxh64Hex(List<int> data, {int seed = 0}) {
  final length = data.length;
  var index = 0;
  int hash;

  if (length >= 32) {
    var v1 = (seed + _prime1 + _prime2) & _mask64;
    var v2 = (seed + _prime2) & _mask64;
    var v3 = seed & _mask64;
    var v4 = (seed - _prime1) & _mask64;
    while (index <= length - 32) {
      v1 = _round(v1, _readUint64LE(data, index));
      v2 = _round(v2, _readUint64LE(data, index + 8));
      v3 = _round(v3, _readUint64LE(data, index + 16));
      v4 = _round(v4, _readUint64LE(data, index + 24));
      index += 32;
    }
    hash =
        (_rotl64(v1, 1) + _rotl64(v2, 7) + _rotl64(v3, 12) + _rotl64(v4, 18)) &
        _mask64;
    hash = _mergeRound(hash, v1);
    hash = _mergeRound(hash, v2);
    hash = _mergeRound(hash, v3);
    hash = _mergeRound(hash, v4);
  } else {
    hash = (seed + _prime5) & _mask64;
  }

  hash = (hash + length) & _mask64;

  while (index + 8 <= length) {
    final k1 = _round(0, _readUint64LE(data, index));
    hash ^= k1;
    hash = ((_rotl64(hash, 27) * _prime1) + _prime4) & _mask64;
    index += 8;
  }
  if (index + 4 <= length) {
    hash ^= (_readUint32LE(data, index) * _prime1) & _mask64;
    hash = ((_rotl64(hash, 23) * _prime2) + _prime3) & _mask64;
    index += 4;
  }
  while (index < length) {
    hash ^= (data[index] * _prime5) & _mask64;
    hash = (_rotl64(hash, 11) * _prime1) & _mask64;
    index++;
  }

  // Dart's `>>` is arithmetic (sign-propagating); xxh64 needs the unsigned
  // shift, otherwise every high-bit hash is wrong.
  hash ^= hash >>> 33;
  hash = (hash * _prime2) & _mask64;
  hash ^= hash >>> 29;
  hash = (hash * _prime3) & _mask64;
  hash ^= hash >>> 32;

  // Dart ints are signed 64-bit, so `toRadixString(16)` on the wrapped value
  // would print a leading '-'. Format the two 32-bit halves separately.
  final high = (hash >>> 32) & 0xFFFFFFFF;
  final low = hash & 0xFFFFFFFF;
  return high.toRadixString(16).padLeft(8, '0') +
      low.toRadixString(16).padLeft(8, '0');
}
