// Ported from Chevey339/kelivo@05eef503b6e7cda14de897373b79bab7bebe35b9
// (`lib/core/services/auth/provider_oauth_adapter.dart`, AGPL-3.0), modified
// for OmniChat on 2026-11-01. See THIRD_PARTY_NOTICES.md.
//
// Kimi Code is a coding-plan endpoint: some models speak the Anthropic Messages
// wire and the rest speak OpenAI chat completions. The device identity headers
// are required on every request, and the Anthropic surface needs `x-api-key`
// in addition to the bearer token.

import 'dart:io' show Platform;

import '../../models/provider_oauth.dart';

Map<String, String> kimiDeviceHeaders({String? deviceId}) => <String, String>{
  'User-Agent': ProviderOAuthConstants.kimiUserAgent,
  'X-Msh-Platform': ProviderOAuthConstants.kimiPlatform,
  'X-Msh-Version': ProviderOAuthConstants.kimiVersion,
  'X-Msh-Device-Name': ProviderOAuthConstants.kimiDeviceName,
  'X-Msh-Device-Model': Platform.operatingSystem,
  if ((deviceId ?? '').trim().isNotEmpty) 'X-Msh-Device-Id': deviceId!.trim(),
};

Map<String, String> kimiOAuthHeaders(ProviderOAuthCredentials credentials) =>
    <String, String>{
      'Authorization': 'Bearer ${credentials.accessToken}',
      ...kimiDeviceHeaders(deviceId: credentials.deviceId),
    };

/// Anthropic Messages on Kimi rejects a thinking budget that leaves no room for
/// output. The upstream client clamps it below `max_tokens`; this is a pure
/// function so retries cannot stack edits (plan C4).
Map<String, dynamic> applyKimiAnthropicRequest(Map<String, dynamic> body) {
  final shaped = Map<String, dynamic>.from(body);
  final thinking = shaped['thinking'];
  if (thinking is! Map) return shaped;
  final budget = _number(thinking['budget_tokens']);
  final maxTokens = _number(shaped['max_tokens']);
  if (budget == null || maxTokens == null || budget < maxTokens) return shaped;
  final next = Map<String, dynamic>.from(thinking);
  next['budget_tokens'] = (maxTokens - 1).clamp(1, 32000).toInt();
  shaped['thinking'] = next;
  return shaped;
}

double? _number(Object? value) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '');
}
