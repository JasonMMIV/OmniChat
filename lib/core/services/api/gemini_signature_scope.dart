/// Gemini thought-signature provenance.
///
/// Gemini rejects signatures replayed to a different provider/endpoint with
/// `400 Corrupted thought signature` (upstream kelivo v1.3.3 / PR #1320).
/// OmniChat persists the signature next to the assistant message, so the
/// signature must remember which endpoint produced it and be filtered when a
/// later turn targets a different endpoint.
///
/// The scope is deliberately pure Dart (no Flutter/Hive imports) so the
/// matching rules are unit-testable without spinning up a chat service.
library;

/// Comment tag used by the legacy wire carrier.
const String geminiThoughtSignatureTag = 'gemini_thought_signatures';

/// Matches the HTML-comment carrier used by older persisted messages and by
/// the neutral API-message pipeline. Kept public so every caller strips /
/// normalizes with exactly the same rule.
final RegExp geminiThoughtSignatureCommentRegex = RegExp(
  r'<!--\s*gemini_thought_signatures:(.*?)-->',
  dotAll: true,
);

/// Removes every signature comment from [raw] and returns the first payload.
///
/// The persisted `provider_artifacts` payload is the bare JSON object; older
/// rows and the in-memory neutral pipeline still use the comment wrapper, so
/// every read path funnels through this helper.
({String cleaned, String? payload}) stripGeminiThoughtSignatureComment(
  String raw,
) {
  final match = geminiThoughtSignatureCommentRegex.firstMatch(raw);
  if (match == null) return (cleaned: raw, payload: null);
  final payload = (match.group(1) ?? '').trim();
  return (
    cleaned: raw.replaceAll(geminiThoughtSignatureCommentRegex, '').trimRight(),
    payload: payload.isEmpty ? null : payload,
  );
}

/// Accepts either a bare JSON payload or a legacy comment and returns the
/// bare payload. Opaque backup values are returned unchanged so old imports
/// keep working.
String normalizeGeminiThoughtSignaturePayload(String raw) {
  final captured = stripGeminiThoughtSignatureComment(raw);
  final payload = captured.payload;
  if (payload != null) return payload;
  return raw.trim();
}

/// Wraps a bare payload for the neutral transmission path.
String buildGeminiThoughtSignatureComment(String payload) =>
    '\n<!-- $geminiThoughtSignatureTag:${payload.trim()} -->';

/// Appends the signature carrier to [content], normalizing old artifact
/// formats and avoiding a duplicate when the content already carries it.
String appendGeminiThoughtSignatureComment(
  String content,
  String rawSignature,
) {
  final payload = normalizeGeminiThoughtSignaturePayload(rawSignature);
  if (payload.isEmpty) return content;
  if (content.contains('$geminiThoughtSignatureTag:')) return content;
  final comment = buildGeminiThoughtSignatureComment(payload);
  return content.isEmpty ? comment.trimLeft() : '$content$comment';
}

/// Builds the endpoint + model identity used for signature replay.
///
/// - Vertex AI: provider id + project + location (the regional origin is
///   derived from those two values, not from `baseUrl`).
/// - Everything else: provider id + normalized URL origin (scheme/host/port).
///   The path/API version is intentionally excluded: a missing `/v1beta`
///   suffix does not invalidate an otherwise identical endpoint.
/// - Both forms append the request model id when supplied. Thought signatures
///   are model-bound, so switching models inside one provider must also start
///   an unsigned replay.
String geminiProviderScope({
  required String providerId,
  required String baseUrl,
  bool vertexAI = false,
  String? projectId,
  String? location,
  String? modelId,
}) {
  // The provider id is part of the identity: OmniChat permits multiple
  // provider configs on the same host with different credentials. A
  // duplicated config (new id, same endpoint) deliberately falls back to the
  // unsigned placeholder instead of risking a cross-account signature.
  final id = providerId.trim().toLowerCase();
  final model = _normalizeModelId(modelId);
  final modelSuffix = model.isEmpty ? '' : '|model=$model';
  if (vertexAI) {
    final project = (projectId ?? '').trim().toLowerCase();
    final region = (location ?? '').trim().toLowerCase();
    if (project.isNotEmpty && region.isNotEmpty) {
      return '$id|vertex|$region|$project$modelSuffix';
    }
  }

  final raw = baseUrl.trim().toLowerCase();
  final uri = Uri.tryParse(raw);
  if (uri != null && uri.host.isNotEmpty) {
    final scheme = uri.scheme.isEmpty ? 'https' : uri.scheme;
    final port = uri.hasPort
        ? uri.port
        : (scheme == 'https' ? 443 : (scheme == 'http' ? 80 : 0));
    return port > 0
        ? '$id|$scheme://${uri.host}:$port$modelSuffix'
        : '$id|$scheme://${uri.host}$modelSuffix';
  }
  return '$id|$raw$modelSuffix';
}

/// Thought signatures are model-bound, so the producing model is part of the
/// scope. `models/gemini-4-argon` and `google/gemini-4-argon` normalize to the
/// same tail; different request ids deliberately do not match and fall back to
/// the unsigned placeholder.
String _normalizeModelId(String? modelId) {
  var value = (modelId ?? '').trim().toLowerCase();
  if (value.isEmpty) return '';
  final slash = value.lastIndexOf('/');
  if (slash >= 0) value = value.substring(slash + 1);
  return value;
}

/// Whether a signature may be replayed to the target endpoint.
///
/// New signatures carry their provenance in [signatureScope]. Legacy comments
/// written before this field existed have no scope; for those we fall back to
/// the assistant message's `providerId` (null means an old row with no
/// provenance, which stays replayable for backwards compatibility).
bool geminiSignatureMatchesProvider({
  required String? signatureScope,
  required String? messageProviderId,
  required String targetScope,
  required String targetProviderId,
}) {
  final scope = (signatureScope ?? '').trim();
  if (scope.isNotEmpty) return scope == targetScope;

  final source = (messageProviderId ?? '').trim();
  if (source.isEmpty) return true;
  return source.toLowerCase() == targetProviderId.trim().toLowerCase();
}
