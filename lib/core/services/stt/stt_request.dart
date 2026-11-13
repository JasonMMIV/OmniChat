import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import 'network_stt.dart';
import 'stt_endpoint.dart';

/// 建立批次 STT 的 HTTP 請求（docs/speech_recognition_import_plan.md §5）。
///
/// 純函式，方便用 `MockClient` 驗證欄位；不含 retry（轉錄不是 idempotent）。
http.BaseRequest buildSttTranscriptionRequest({
  required SttServiceOptions service,
  required Uint8List wav,
  required int sampleRate,
}) {
  switch (service.kind) {
    case NetworkSttKind.openaiWhisper:
    case NetworkSttKind.groqWhisper:
    case NetworkSttKind.mistral:
    case NetworkSttKind.elevenLabs:
      return _buildMultipartRequest(
        service: service,
        wav: wav,
        sampleRate: sampleRate,
      );
    case NetworkSttKind.qwenAudio:
      return _buildQwenRequest(
        service: service as QwenAudioSttOptions,
        wav: wav,
        sampleRate: sampleRate,
      );
  }
}

http.MultipartRequest _buildMultipartRequest({
  required SttServiceOptions service,
  required Uint8List wav,
  required int sampleRate,
}) {
  final uri = resolveSttEndpoint(raw: service.configuredEndpoint, kind: service.kind);
  final request = http.MultipartRequest('POST', uri);
  final language = service.resolvedLanguage;

  switch (service.kind) {
    case NetworkSttKind.openaiWhisper:
      request.headers['Authorization'] = 'Bearer ${service.apiKey}';
      request.fields['model'] = service.model;
      if (language != null) request.fields['language'] = language;
      break;
    case NetworkSttKind.groqWhisper:
      request.headers['Authorization'] = 'Bearer ${service.apiKey}';
      request.fields['model'] = service.model;
      request.fields['response_format'] = 'json';
      if (language != null) request.fields['language'] = language;
      break;
    case NetworkSttKind.mistral:
      request.headers['Authorization'] = 'Bearer ${service.apiKey}';
      request.fields['model'] = service.model;
      if (language != null) request.fields['language'] = language;
      break;
    case NetworkSttKind.elevenLabs:
      // ElevenLabs 用 xi-api-key，不是 Bearer；欄位名也不同。
      request.headers['xi-api-key'] = service.apiKey;
      request.fields['model_id'] = service.model;
      request.fields['tag_audio_events'] = 'false';
      request.fields['timestamps_granularity'] = 'none';
      if (language != null) request.fields['language_code'] = language;
      break;
    case NetworkSttKind.qwenAudio:
      throw ArgumentError('Qwen uses a JSON body, not multipart');
  }

  request.files.add(
    http.MultipartFile.fromBytes(
      'file',
      wav,
      filename: 'audio.wav',
      contentType: MediaType('audio', 'wav'),
    ),
  );
  return request;
}

http.Request _buildQwenRequest({
  required QwenAudioSttOptions service,
  required Uint8List wav,
  required int sampleRate,
}) {
  final uri = resolveQwenSttEndpoint(
    endpoint: service.endpoint,
    workspaceId: service.workspaceId,
    region: service.region,
  );
  final language = service.resolvedLanguage;
  final body = <String, dynamic>{
    'model': service.model,
    'input': {
      'messages': [
        {
          'role': 'user',
          'content': [
            {
              'input_audio': {
                'data': 'data:audio/wav;base64,${base64Encode(wav)}',
              },
            },
          ],
        },
      ],
    },
    'parameters': <String, dynamic>{
      'format': 'wav',
      'sample_rate': sampleRate,
      if (language != null) 'language_hints': [language],
    },
  };
  final request = http.Request('POST', uri)
    ..headers['Authorization'] = 'Bearer ${service.apiKey}'
    ..headers['X-DashScope-SSE'] = 'disable'
    ..headers['Content-Type'] = 'application/json; charset=utf-8'
    ..body = jsonEncode(body);
  final workspace = service.workspaceId.trim();
  if (workspace.isNotEmpty) {
    request.headers['X-DashScope-WorkSpace'] = workspace;
  }
  return request;
}

/// 解析回應文字：multipart 供應商為 `{"text": ...}`，Qwen 為 `output.text`。
String parseSttTranscriptionBody(NetworkSttKind kind, String body) {
  final trimmed = body.trim();
  if (trimmed.isEmpty) return '';
  Object? decoded;
  try {
    decoded = jsonDecode(trimmed);
  } catch (_) {
    decoded = null;
  }
  if (decoded is Map) {
    final map = decoded.cast<String, dynamic>();
    if (kind == NetworkSttKind.qwenAudio) {
      final output = map['output'];
      if (output is Map) {
        final text = output['text'];
        if (text is String) return text.trim();
        // 部分 DashScope 模型回傳 choices[0].message.content。
        final choices = output['choices'];
        if (choices is List && choices.isNotEmpty) {
          final choice = choices.first;
          final message = choice is Map ? choice['message'] : null;
          final content = message is Map ? message['content'] : null;
          if (content is String) return content.trim();
          if (content is List && content.isNotEmpty) {
            final first = content.first;
            if (first is Map && first['text'] is String) {
              return (first['text'] as String).trim();
            }
          }
        }
      }
    }
    final text = map['text'];
    if (text is String) return text.trim();
    final result = map['result'];
    if (result is String) return result.trim();
    return '';
  }
  if (decoded is String) return decoded.trim();
  return trimmed;
}
