// Ported from Chevey339/kelivo@05eef503b6e7cda14de897373b79bab7bebe35b9
// (`lib/core/services/auth/provider_oauth_adapter.dart`, AGPL-3.0), modified
// for OmniChat on 2026-11-01. See THIRD_PARTY_NOTICES.md.
//
// Grok (xAI) uses the OpenAI Responses wire. The CLI surface expects the
// `xai-grok-cli` token-auth marker and encrypted reasoning replay; `summary`
// is not accepted.

import '../../models/provider_oauth.dart';

Map<String, String> grokOAuthHeaders(ProviderOAuthCredentials credentials) =>
    <String, String>{
      'Authorization': 'Bearer ${credentials.accessToken}',
      'X-XAI-Token-Auth': 'xai-grok-cli',
    };

/// Pure shaping function: the wrapper always starts from the untouched request
/// body, so retries and tool follow-ups cannot double-apply it (plan C4).
Map<String, dynamic> applyGrokRequest(Map<String, dynamic> body) {
  final shaped = Map<String, dynamic>.from(body);

  final reasoning = shaped['reasoning'];
  if (reasoning is Map) {
    final next = Map<String, dynamic>.from(reasoning);
    next.remove('summary');
    if (next.isEmpty) {
      shaped.remove('reasoning');
    } else {
      shaped['reasoning'] = next;
    }
  }

  shaped['store'] = false;
  final include = shaped['include'];
  final merged = include is List ? List<dynamic>.from(include) : <dynamic>[];
  if (!merged.contains('reasoning.encrypted_content')) {
    merged.add('reasoning.encrypted_content');
  }
  shaped['include'] = merged;
  return shaped;
}
