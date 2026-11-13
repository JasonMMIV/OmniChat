import 'package:uuid/uuid.dart';

/// 第三方 STT（語音辨識）服務類型。
///
/// 本專案只實作「錄音檔批次轉錄」；Qwen 即時（WebSocket）尚未支援
/// （docs/speech_recognition_import_plan.md §14）。
enum NetworkSttKind {
  openaiWhisper,
  groqWhisper,
  mistral,
  elevenLabs,
  qwenAudio,
}

String networkSttKindDisplayName(NetworkSttKind k) {
  switch (k) {
    case NetworkSttKind.openaiWhisper:
      return 'OpenAI Whisper';
    case NetworkSttKind.groqWhisper:
      return 'Groq Whisper';
    case NetworkSttKind.mistral:
      return 'Mistral Voxtral';
    case NetworkSttKind.elevenLabs:
      return 'ElevenLabs Scribe';
    case NetworkSttKind.qwenAudio:
      return 'Qwen Audio';
  }
}

/// Qwen 辨識模式。V1 只交付 `recorded`。
enum QwenSttMode { realtime, recorded }

String qwenSttModeDisplayName(QwenSttMode mode) {
  switch (mode) {
    case QwenSttMode.realtime:
      return 'Real-time';
    case QwenSttMode.recorded:
      return 'Recorded audio';
  }
}

const String kDefaultOpenAiSttEndpoint =
    'https://api.openai.com/v1/audio/transcriptions';
const String kDefaultGroqSttEndpoint =
    'https://api.groq.com/openai/v1/audio/transcriptions';
const String kDefaultMistralSttEndpoint =
    'https://api.mistral.ai/v1/audio/transcriptions';
const String kDefaultElevenLabsSttEndpoint =
    'https://api.elevenlabs.io/v1/speech-to-text';

const String kDefaultOpenAiSttModel = 'whisper-1';
const String kDefaultGroqSttModel = 'whisper-large-v3';
const String kDefaultMistralSttModel = 'voxtral-mini-latest';
const String kDefaultElevenLabsSttModel = 'scribe_v2';
const String kDefaultQwenSttModel = 'qwen-audio-3.0-asr-flash';

const String kDefaultQwenSttRegion = 'cn-beijing';
const List<String> kQwenSttRegions = <String>[
  'cn-beijing',
  'ap-southeast-1',
];

const int kDefaultSttSampleRate = 16000;
const int kDefaultSttSegmentDurationSec = 30;

/// Qwen Workspace ID：只允許英數與連字號，長度 1–63，不能是 URL。
final RegExp _workspaceIdPattern = RegExp(
  r'^[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$',
);

bool isValidSttWorkspaceId(String value) =>
    _workspaceIdPattern.hasMatch(value.trim());

/// 只接受 http／https、host 非空、無 userInfo／fragment 的 endpoint。
bool isValidSttEndpointUrl(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return false;
  final uri = Uri.tryParse(trimmed);
  if (uri == null) return false;
  if (uri.scheme != 'http' && uri.scheme != 'https') return false;
  if (uri.host.isEmpty) return false;
  if (uri.userInfo.isNotEmpty) return false;
  if (uri.hasFragment) return false;
  return true;
}

String defaultSttEndpoint(NetworkSttKind kind) {
  switch (kind) {
    case NetworkSttKind.openaiWhisper:
      return kDefaultOpenAiSttEndpoint;
    case NetworkSttKind.groqWhisper:
      return kDefaultGroqSttEndpoint;
    case NetworkSttKind.mistral:
      return kDefaultMistralSttEndpoint;
    case NetworkSttKind.elevenLabs:
      return kDefaultElevenLabsSttEndpoint;
    case NetworkSttKind.qwenAudio:
      return 'https://dashscope.aliyuncs.com';
  }
}

String defaultSttModel(NetworkSttKind kind) {
  switch (kind) {
    case NetworkSttKind.openaiWhisper:
      return kDefaultOpenAiSttModel;
    case NetworkSttKind.groqWhisper:
      return kDefaultGroqSttModel;
    case NetworkSttKind.mistral:
      return kDefaultMistralSttModel;
    case NetworkSttKind.elevenLabs:
      return kDefaultElevenLabsSttModel;
    case NetworkSttKind.qwenAudio:
      return kDefaultQwenSttModel;
  }
}

/// 服務是否可用於轉錄。Qwen 即時模式保留設定但 V1 不可選取。
bool isSttServiceAvailable(SttServiceOptions service) {
  if (service.kind == NetworkSttKind.qwenAudio) {
    return (service as QwenAudioSttOptions).mode != QwenSttMode.realtime;
  }
  return true;
}

int? _positiveIntOrNull(Object? raw) {
  if (raw is int) return raw > 0 ? raw : null;
  if (raw is num) return raw > 0 ? raw.toInt() : null;
  final parsed = int.tryParse(raw?.toString().trim() ?? '');
  return (parsed != null && parsed > 0) ? parsed : null;
}

/// STT 服務設定的抽象基底。
///
/// `baseUrl` 的語義是「使用者輸入的 endpoint」：可以是完整 endpoint
/// （既有 OpenAI／Groq 預設），也可以是 base；由 `resolveSttEndpoint()`
/// 避免重複拼接。
abstract class SttServiceOptions {
  final String id;
  final bool enabled;
  final String name;
  final NetworkSttKind kind;

  /// BCP-47／語言代碼；空字串或 `auto` 視為自動。
  final String language;

  /// 擷取與上傳取樣率（請求值；實際值由擷取層回報）。
  final int sampleRate;

  /// 批次分段長度（秒）。
  final int segmentDurationSec;

  SttServiceOptions({
    String? id,
    required this.enabled,
    required this.name,
    required this.kind,
    this.language = '',
    this.sampleRate = kDefaultSttSampleRate,
    this.segmentDurationSec = kDefaultSttSegmentDurationSec,
  }) : id = id ?? const Uuid().v4();

  String get apiKey;

  /// 使用者設定的 endpoint（空白代表使用預設）。
  String get configuredEndpoint;

  String get model;

  /// 送給 API 的語言值；空字串或 `auto` 回傳 `null`（不送欄位）。
  String? get resolvedLanguage {
    final value = language.trim();
    if (value.isEmpty || value.toLowerCase() == 'auto') return null;
    return value;
  }

  Map<String, dynamic> toJson();

  /// 所有子類別共用的欄位。
  Map<String, dynamic> baseJson() => <String, dynamic>{
    'id': id,
    'enabled': enabled,
    'name': name,
    'kind': kind.name,
    'language': language,
    'sampleRate': sampleRate,
    'segmentDurationSec': segmentDurationSec,
  };

  /// 容錯解析：未知 kind／缺少必要欄位／URL 格式錯誤 → `null`。
  ///
  /// 不可再靜默退回 OpenAI Whisper（舊行為會讓使用者以為在用 A、實際用 B）。
  static SttServiceOptions? tryFromJson(Map<String, dynamic> json) {
    final type = (json['kind'] ?? '').toString().trim();
    final enabled = json['enabled'] == true;
    final rawId = (json['id'] ?? '').toString().trim();
    final id = rawId.isEmpty ? null : rawId;
    final rawName = (json['name'] ?? '').toString().trim();
    final apiKey = (json['apiKey'] ?? '').toString().trim();
    final baseUrlRaw = (json['baseUrl'] ?? '').toString().trim();
    final modelRaw = (json['model'] ?? '').toString().trim();
    final language = (json['language'] ?? '').toString().trim();
    final sampleRate =
        _positiveIntOrNull(json['sampleRate']) ?? kDefaultSttSampleRate;
    final segmentDurationSec =
        _positiveIntOrNull(json['segmentDurationSec']) ??
        kDefaultSttSegmentDurationSec;

    if (apiKey.isEmpty) return null;
    if (baseUrlRaw.isNotEmpty && !isValidSttEndpointUrl(baseUrlRaw)) {
      return null;
    }

    switch (type) {
      case 'openaiWhisper':
        return OpenAiWhisperSttOptions(
          id: id,
          enabled: enabled,
          name: rawName.isEmpty ? 'OpenAI Whisper' : rawName,
          apiKey: apiKey,
          baseUrl: baseUrlRaw.isEmpty ? kDefaultOpenAiSttEndpoint : baseUrlRaw,
          model: modelRaw.isEmpty ? kDefaultOpenAiSttModel : modelRaw,
          language: language,
          sampleRate: sampleRate,
          segmentDurationSec: segmentDurationSec,
        );
      case 'groqWhisper':
        return GroqWhisperSttOptions(
          id: id,
          enabled: enabled,
          name: rawName.isEmpty ? 'Groq Whisper' : rawName,
          apiKey: apiKey,
          baseUrl: baseUrlRaw.isEmpty ? kDefaultGroqSttEndpoint : baseUrlRaw,
          model: modelRaw.isEmpty ? kDefaultGroqSttModel : modelRaw,
          language: language,
          sampleRate: sampleRate,
          segmentDurationSec: segmentDurationSec,
        );
      case 'mistral':
        return MistralSttOptions(
          id: id,
          enabled: enabled,
          name: rawName.isEmpty ? 'Mistral Voxtral' : rawName,
          apiKey: apiKey,
          baseUrl: baseUrlRaw.isEmpty ? kDefaultMistralSttEndpoint : baseUrlRaw,
          model: modelRaw.isEmpty ? kDefaultMistralSttModel : modelRaw,
          language: language,
          sampleRate: sampleRate,
          segmentDurationSec: segmentDurationSec,
        );
      case 'elevenLabs':
        return ElevenLabsSttOptions(
          id: id,
          enabled: enabled,
          name: rawName.isEmpty ? 'ElevenLabs Scribe' : rawName,
          apiKey: apiKey,
          baseUrl:
              baseUrlRaw.isEmpty ? kDefaultElevenLabsSttEndpoint : baseUrlRaw,
          model: modelRaw.isEmpty ? kDefaultElevenLabsSttModel : modelRaw,
          language: language,
          sampleRate: sampleRate,
          segmentDurationSec: segmentDurationSec,
        );
      case 'qwenAudio':
        final workspaceId = (json['workspaceId'] ?? '').toString().trim();
        if (workspaceId.isNotEmpty && !isValidSttWorkspaceId(workspaceId)) {
          return null;
        }
        final endpoint = (json['endpoint'] ?? '').toString().trim();
        if (endpoint.isNotEmpty && !isValidSttEndpointUrl(endpoint)) {
          return null;
        }
        final regionRaw = (json['region'] ?? '').toString().trim();
        final modeRaw = (json['mode'] ?? '').toString().trim();
        return QwenAudioSttOptions(
          id: id,
          enabled: enabled,
          name: rawName.isEmpty ? 'Qwen Audio' : rawName,
          apiKey: apiKey,
          workspaceId: workspaceId,
          region: regionRaw.isEmpty ? kDefaultQwenSttRegion : regionRaw,
          endpoint: endpoint,
          model: modelRaw.isEmpty ? kDefaultQwenSttModel : modelRaw,
          mode: modeRaw == 'realtime'
              ? QwenSttMode.realtime
              : QwenSttMode.recorded,
          language: language,
          sampleRate: sampleRate,
          segmentDurationSec: segmentDurationSec,
        );
      default:
        return null;
    }
  }

  /// 嚴格解析；不合法時拋出 [FormatException]（呼叫端需能處理）。
  static SttServiceOptions fromJson(Map<String, dynamic> json) {
    final parsed = tryFromJson(json);
    if (parsed == null) {
      throw FormatException(
        'Unsupported or invalid STT service entry: '
        'kind=${json['kind']}, id=${json['id']}',
      );
    }
    return parsed;
  }
}

class OpenAiWhisperSttOptions extends SttServiceOptions {
  @override
  final String apiKey;

  final String baseUrl;

  @override
  final String model;

  OpenAiWhisperSttOptions({
    super.id,
    required super.enabled,
    required super.name,
    required this.apiKey,
    required this.baseUrl,
    required this.model,
    super.language,
    super.sampleRate,
    super.segmentDurationSec,
  }) : super(kind: NetworkSttKind.openaiWhisper);

  @override
  String get configuredEndpoint => baseUrl;

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
    ...baseJson(),
    'apiKey': apiKey,
    'baseUrl': baseUrl,
    'model': model,
  };
}

class GroqWhisperSttOptions extends SttServiceOptions {
  @override
  final String apiKey;

  final String baseUrl;

  @override
  final String model;

  GroqWhisperSttOptions({
    super.id,
    required super.enabled,
    required super.name,
    required this.apiKey,
    required this.baseUrl,
    required this.model,
    super.language,
    super.sampleRate,
    super.segmentDurationSec,
  }) : super(kind: NetworkSttKind.groqWhisper);

  @override
  String get configuredEndpoint => baseUrl;

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
    ...baseJson(),
    'apiKey': apiKey,
    'baseUrl': baseUrl,
    'model': model,
  };
}

class MistralSttOptions extends SttServiceOptions {
  @override
  final String apiKey;

  final String baseUrl;

  @override
  final String model;

  MistralSttOptions({
    super.id,
    required super.enabled,
    required super.name,
    required this.apiKey,
    required this.baseUrl,
    required this.model,
    super.language,
    super.sampleRate,
    super.segmentDurationSec,
  }) : super(kind: NetworkSttKind.mistral);

  @override
  String get configuredEndpoint => baseUrl;

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
    ...baseJson(),
    'apiKey': apiKey,
    'baseUrl': baseUrl,
    'model': model,
  };
}

class ElevenLabsSttOptions extends SttServiceOptions {
  @override
  final String apiKey;

  final String baseUrl;

  @override
  final String model;

  ElevenLabsSttOptions({
    super.id,
    required super.enabled,
    required super.name,
    required this.apiKey,
    required this.baseUrl,
    required this.model,
    super.language,
    super.sampleRate,
    super.segmentDurationSec,
  }) : super(kind: NetworkSttKind.elevenLabs);

  @override
  String get configuredEndpoint => baseUrl;

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
    ...baseJson(),
    'apiKey': apiKey,
    'baseUrl': baseUrl,
    'model': model,
  };
}

class QwenAudioSttOptions extends SttServiceOptions {
  @override
  final String apiKey;

  /// Token Plan 的業務空間（例如 `token-plan`）；空字串＝一般 DashScope。
  final String workspaceId;

  /// `cn-beijing`／`ap-southeast-1`。
  final String region;

  /// 完整 URL 覆寫；空字串＝依 Workspace／Region 自動組。
  final String endpoint;

  @override
  final String model;

  final QwenSttMode mode;

  QwenAudioSttOptions({
    super.id,
    required super.enabled,
    required super.name,
    required this.apiKey,
    this.workspaceId = '',
    this.region = kDefaultQwenSttRegion,
    this.endpoint = '',
    required this.model,
    this.mode = QwenSttMode.recorded,
    super.language,
    super.sampleRate,
    super.segmentDurationSec,
  }) : super(kind: NetworkSttKind.qwenAudio);

  @override
  String get configuredEndpoint =>
      endpoint.trim().isEmpty ? defaultSttEndpoint(kind) : endpoint.trim();

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
    ...baseJson(),
    'apiKey': apiKey,
    'workspaceId': workspaceId,
    'region': region,
    'endpoint': endpoint,
    'model': model,
    'mode': mode == QwenSttMode.realtime ? 'realtime' : 'recorded',
  };
}
