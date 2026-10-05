import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';

part 'chat_message.g.dart';

@HiveType(typeId: 0)
class ChatMessage extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String role; // 'user' or 'assistant'

  @HiveField(2)
  final String content;

  @HiveField(3)
  final DateTime timestamp;

  @HiveField(4)
  final String? modelId;

  @HiveField(5)
  final String? providerId;

  @HiveField(6)
  final int? totalTokens;

  @HiveField(7)
  final String conversationId;

  @HiveField(8)
  final bool isStreaming;

  // Optional reasoning fields for assistant messages
  @HiveField(9)
  final String? reasoningText;

  @HiveField(10)
  final DateTime? reasoningStartAt;

  @HiveField(11)
  final DateTime? reasoningFinishedAt;

  // Translation field for translated content
  @HiveField(12)
  final String? translation;
  
  // JSON encoded reasoning segments for multiple reasoning blocks
  @HiveField(13)
  final String? reasoningSegmentsJson;

  // Versioning: group messages sharing the same semantic position
  // groupId identifies a message thread; version starts from 0 and increments
  @HiveField(14)
  final String? groupId;

  @HiveField(15)
  final int version;

  @HiveField(16)
  final String? aiTeamProposalsJson;

  @HiveField(17)
  final int? promptTokens;

  @HiveField(18)
  final int? completionTokens;

  @HiveField(19)
  final int? cachedTokens;

  // 過程收褶 (process folding): the moment the whole process group ended —
  // i.e. the instant the last thinking segment / tool call finished and the
  // group header flips from 處理中 to 已完成. Distinct from
  // [reasoningFinishedAt], which is stamped as soon as THINKING pauses
  // (before the tools run), so it cannot close a timer that spans the tools.
  // Null on messages that never ran a process group and on rows written
  // before this field existed (the header then falls back to
  // reasoningFinishedAt, which is the pre-2026-10-05 behaviour).
  @HiveField(20)
  final DateTime? processFinishedAt;

  // The mirror of [processFinishedAt]: the moment this message's process
  // started — the FIRST process event, which is the first tool call OR the
  // first thinking token, whichever comes first (a tool-only turn, or a
  // tool-first agent loop, has no reasoning at all, so reasoningStartAt
  // cannot anchor the header timer). Null before this field existed and for
  // messages that never ran a process group.
  @HiveField(21)
  final DateTime? processStartedAt;

  ChatMessage({
    String? id,
    required this.role,
    required this.content,
    DateTime? timestamp,
    this.modelId,
    this.providerId,
    this.totalTokens,
    required this.conversationId,
    this.isStreaming = false,
    this.reasoningText,
    this.reasoningStartAt,
    this.reasoningFinishedAt,
    this.translation,
    this.reasoningSegmentsJson,
    String? groupId,
    int? version,
    this.aiTeamProposalsJson,
    this.promptTokens,
    this.completionTokens,
    this.cachedTokens,
    this.processFinishedAt,
    this.processStartedAt,
  })  : id = id ?? const Uuid().v4(),
        timestamp = timestamp ?? DateTime.now(),
        groupId = groupId ?? id,
        version = version ?? 0;

  ChatMessage copyWith({
    String? id,
    String? role,
    String? content,
    DateTime? timestamp,
    String? modelId,
    String? providerId,
    int? totalTokens,
    String? conversationId,
    bool? isStreaming,
    String? reasoningText,
    DateTime? reasoningStartAt,
    DateTime? reasoningFinishedAt,
    String? translation,
    String? reasoningSegmentsJson,
    String? groupId,
    int? version,
    String? aiTeamProposalsJson,
    int? promptTokens,
    int? completionTokens,
    int? cachedTokens,
    DateTime? processFinishedAt,
    DateTime? processStartedAt,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      role: role ?? this.role,
      content: content ?? this.content,
      timestamp: timestamp ?? this.timestamp,
      modelId: modelId ?? this.modelId,
      providerId: providerId ?? this.providerId,
      totalTokens: totalTokens ?? this.totalTokens,
      conversationId: conversationId ?? this.conversationId,
      isStreaming: isStreaming ?? this.isStreaming,
      reasoningText: reasoningText ?? this.reasoningText,
      reasoningStartAt: reasoningStartAt ?? this.reasoningStartAt,
      reasoningFinishedAt: reasoningFinishedAt ?? this.reasoningFinishedAt,
      translation: translation ?? this.translation,
      reasoningSegmentsJson: reasoningSegmentsJson ?? this.reasoningSegmentsJson,
      groupId: groupId ?? this.groupId,
      version: version ?? this.version,
      aiTeamProposalsJson: aiTeamProposalsJson ?? this.aiTeamProposalsJson,
      promptTokens: promptTokens ?? this.promptTokens,
      completionTokens: completionTokens ?? this.completionTokens,
      cachedTokens: cachedTokens ?? this.cachedTokens,
      processFinishedAt: processFinishedAt ?? this.processFinishedAt,
      processStartedAt: processStartedAt ?? this.processStartedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'role': role,
      'content': content,
      'timestamp': timestamp.toIso8601String(),
      'modelId': modelId,
      'providerId': providerId,
      'totalTokens': totalTokens,
      'conversationId': conversationId,
      'isStreaming': isStreaming,
      'reasoningText': reasoningText,
      'reasoningStartAt': reasoningStartAt?.toIso8601String(),
      'reasoningFinishedAt': reasoningFinishedAt?.toIso8601String(),
      'translation': translation,
      'reasoningSegmentsJson': reasoningSegmentsJson,
      'groupId': groupId,
      'version': version,
      'aiTeamProposalsJson': aiTeamProposalsJson,
      'promptTokens': promptTokens,
      'completionTokens': completionTokens,
      'cachedTokens': cachedTokens,
      'processFinishedAt': processFinishedAt?.toIso8601String(),
      'processStartedAt': processStartedAt?.toIso8601String(),
    };
  }

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      id: json['id'] as String,
      role: json['role'] as String,
      content: json['content'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
      modelId: json['modelId'] as String?,
      providerId: json['providerId'] as String?,
      totalTokens: json['totalTokens'] as int?,
      conversationId: json['conversationId'] as String,
      isStreaming: json['isStreaming'] as bool? ?? false,
      reasoningText: json['reasoningText'] as String?,
      reasoningStartAt: json['reasoningStartAt'] != null
          ? DateTime.parse(json['reasoningStartAt'] as String)
          : null,
      reasoningFinishedAt: json['reasoningFinishedAt'] != null
          ? DateTime.parse(json['reasoningFinishedAt'] as String)
          : null,
      translation: json['translation'] as String?,
      reasoningSegmentsJson: json['reasoningSegmentsJson'] as String?,
      groupId: json['groupId'] as String?,
      version: (json['version'] as int?) ?? 0,
      aiTeamProposalsJson: json['aiTeamProposalsJson'] as String?,
      promptTokens: json['promptTokens'] as int?,
      completionTokens: json['completionTokens'] as int?,
      cachedTokens: json['cachedTokens'] as int?,
      processFinishedAt: json['processFinishedAt'] != null
          ? DateTime.parse(json['processFinishedAt'] as String)
          : null,
      processStartedAt: json['processStartedAt'] != null
          ? DateTime.parse(json['processStartedAt'] as String)
          : null,
    );
  }
}
