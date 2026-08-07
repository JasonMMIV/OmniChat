import 'package:uuid/uuid.dart';

/// 第三方 STT（語音辨識）服務類型。
/// 本次僅建構「設定管理架構」（UI + 資料模型 + 持久化）；實際的網路轉錄
/// （錄音 → HTTP 上傳 → 轉錄 → 文字注入）為下階段範圍。
enum NetworkSttKind { openaiWhisper, groqWhisper }

String networkSttKindDisplayName(NetworkSttKind k) {
  switch (k) {
    case NetworkSttKind.openaiWhisper:
      return 'OpenAI Whisper';
    case NetworkSttKind.groqWhisper:
      return 'Groq Whisper';
  }
}

/// STT 服務設定的抽象基底（對照 `TtsServiceOptions` 層次，見 network_tts.dart）。
/// 穩定唯一 `id`、`enabled`、`name`、`apiKey`、`baseUrl`、`model`，
/// 含 `toJson` / `fromJson`。
abstract class SttServiceOptions {
  final String id;
  final bool enabled;
  final String name;
  final NetworkSttKind kind;

  SttServiceOptions({
    String? id,
    required this.enabled,
    required this.name,
    required this.kind,
  }) : id = id ?? const Uuid().v4();

  Map<String, dynamic> toJson();

  static SttServiceOptions fromJson(Map<String, dynamic> json) {
    final type = (json['kind'] ?? '').toString();
    final enabled = json['enabled'] == true;
    final name = (json['name'] ?? '').toString();
    final id = (json['id'] ?? '').toString();
    switch (type) {
      case 'openaiWhisper':
        return OpenAiWhisperSttOptions(
          id: id.isEmpty ? null : id,
          enabled: enabled,
          name: name.isEmpty ? 'OpenAI Whisper' : name,
          apiKey: (json['apiKey'] ?? '').toString(),
          baseUrl:
              (json['baseUrl'] ??
                      'https://api.openai.com/v1/audio/transcriptions')
                  .toString(),
          model: (json['model'] ?? 'whisper-1').toString(),
        );
      case 'groqWhisper':
        return GroqWhisperSttOptions(
          id: id.isEmpty ? null : id,
          enabled: enabled,
          name: name.isEmpty ? 'Groq Whisper' : name,
          apiKey: (json['apiKey'] ?? '').toString(),
          baseUrl:
              (json['baseUrl'] ??
                      'https://api.groq.com/openai/v1/audio/transcriptions')
                  .toString(),
          model: (json['model'] ?? 'whisper-large-v3').toString(),
        );
      default:
        // Fallback to OpenAI Whisper shape to avoid crash if kind missing
        return OpenAiWhisperSttOptions(
          id: id.isEmpty ? null : id,
          enabled: enabled,
          name: name.isEmpty ? 'OpenAI Whisper' : name,
          apiKey: (json['apiKey'] ?? '').toString(),
          baseUrl:
              (json['baseUrl'] ??
                      'https://api.openai.com/v1/audio/transcriptions')
                  .toString(),
          model: (json['model'] ?? 'whisper-1').toString(),
        );
    }
  }
}

class OpenAiWhisperSttOptions extends SttServiceOptions {
  final String apiKey;
  final String baseUrl;
  final String model;
  OpenAiWhisperSttOptions({
    super.id,
    required super.enabled,
    required super.name,
    required this.apiKey,
    required this.baseUrl,
    required this.model,
  }) : super(kind: NetworkSttKind.openaiWhisper);

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    'enabled': enabled,
    'name': name,
    'kind': 'openaiWhisper',
    'apiKey': apiKey,
    'baseUrl': baseUrl,
    'model': model,
  };
}

class GroqWhisperSttOptions extends SttServiceOptions {
  final String apiKey;
  final String baseUrl;
  final String model;
  GroqWhisperSttOptions({
    super.id,
    required super.enabled,
    required super.name,
    required this.apiKey,
    required this.baseUrl,
    required this.model,
  }) : super(kind: NetworkSttKind.groqWhisper);

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    'enabled': enabled,
    'name': name,
    'kind': 'groqWhisper',
    'apiKey': apiKey,
    'baseUrl': baseUrl,
    'model': model,
  };
}
