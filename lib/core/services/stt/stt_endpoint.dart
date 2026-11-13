import 'network_stt.dart';

/// 解析 STT 上傳 endpoint（docs/speech_recognition_import_plan.md §4.2.1）。
///
/// `raw` 可能是完整 endpoint（既有 OpenAI／Groq 預設值）或 base URL；
/// 規則避免重複拼接後綴，並處理代理前綴與版本段（`/v1`、Groq `/openai`）。
Uri resolveSttEndpoint({
  required String raw,
  required NetworkSttKind kind,
}) {
  if (kind == NetworkSttKind.qwenAudio) {
    throw ArgumentError.value(
      kind,
      'kind',
      'Qwen endpoints are resolved by resolveQwenSttEndpoint()',
    );
  }
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return Uri.parse(defaultSttEndpoint(kind));

  final uri = Uri.tryParse(trimmed);
  if (uri == null || !isValidSttEndpointUrl(trimmed)) {
    throw FormatException('Invalid STT endpoint: $trimmed');
  }

  var path = uri.path;
  if (path.endsWith('/')) path = path.substring(0, path.length - 1);
  if (path.isEmpty) {
    return uri.replace(path: _defaultEndpointPath(kind));
  }

  final suffix = _endpointSuffix(kind);
  final lower = path.toLowerCase();
  String resolved;
  if (lower.endsWith(suffix)) {
    resolved = path;
  } else if (lower.endsWith('/v1')) {
    resolved = '$path$suffix';
  } else {
    switch (kind) {
      case NetworkSttKind.openaiWhisper:
      case NetworkSttKind.mistral:
        resolved = '$path/v1/audio/transcriptions';
        break;
      case NetworkSttKind.groqWhisper:
        resolved = lower.endsWith('/openai')
            ? '$path/v1/audio/transcriptions'
            : '$path/openai/v1/audio/transcriptions';
        break;
      case NetworkSttKind.elevenLabs:
        resolved = '$path/v1/speech-to-text';
        break;
      case NetworkSttKind.qwenAudio:
        throw ArgumentError.value(kind, 'kind');
    }
  }
  // query string 保留；API key 只從 header 送，不進 URL。
  return uri.replace(path: resolved);
}

/// 依 Workspace／Region／覆寫組出 Qwen 錄音檔 endpoint。
Uri resolveQwenSttEndpoint({
  required String endpoint,
  required String workspaceId,
  required String region,
}) {
  final override = endpoint.trim();
  if (override.isNotEmpty) {
    if (!isValidSttEndpointUrl(override)) {
      throw FormatException('Invalid Qwen endpoint: $override');
    }
    return Uri.parse(override);
  }
  final workspace = workspaceId.trim();
  final effectiveRegion = region.trim().isEmpty ? kDefaultQwenSttRegion : region.trim();
  const path = '/api/v1/services/aigc/multimodal-generation/generation';
  if (workspace.isNotEmpty) {
    if (!isValidSttWorkspaceId(workspace)) {
      throw FormatException('Invalid workspace ID: $workspace');
    }
    return Uri.parse('https://$workspace.$effectiveRegion.maas.aliyuncs.com$path');
  }
  final host = effectiveRegion == 'ap-southeast-1'
      ? 'dashscope-intl.aliyuncs.com'
      : 'dashscope.aliyuncs.com';
  return Uri.parse('https://$host$path');
}

String _endpointSuffix(NetworkSttKind kind) {
  switch (kind) {
    case NetworkSttKind.openaiWhisper:
    case NetworkSttKind.groqWhisper:
    case NetworkSttKind.mistral:
      return '/audio/transcriptions';
    case NetworkSttKind.elevenLabs:
      return '/speech-to-text';
    case NetworkSttKind.qwenAudio:
      return '/multimodal-generation/generation';
  }
}

String _defaultEndpointPath(NetworkSttKind kind) {
  switch (kind) {
    case NetworkSttKind.openaiWhisper:
    case NetworkSttKind.mistral:
      return '/v1/audio/transcriptions';
    case NetworkSttKind.groqWhisper:
      return '/openai/v1/audio/transcriptions';
    case NetworkSttKind.elevenLabs:
      return '/v1/speech-to-text';
    case NetworkSttKind.qwenAudio:
      return '/api/v1/services/aigc/multimodal-generation/generation';
  }
}
