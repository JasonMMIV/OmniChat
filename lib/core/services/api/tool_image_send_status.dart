// Send-time status for a tool result that carried an `[image:...]` marker.
//
// Kept in a pure-Dart file so `chat_stream_chunk.dart` can carry these
// statuses through the agent-loop kernel without importing `dart:io` or
// Flutter code.

enum ToolImageSendState {
  attached,
  settingOff,
  modelUnsupported,
  transportUnsupported,
  limitReached,
  notFound,
  outsideWorkspace,
  changed,
  tooLarge,
  unsupportedFormat,
  decodeFailed,
  providerRejected,
  unknown,
}

class ToolImageSendStatus {
  const ToolImageSendStatus({
    required this.toolCallId,
    required this.state,
    this.detail,
    this.modelId,
    this.at,
  });

  final String toolCallId;
  final ToolImageSendState state;
  final String? detail;
  final String? modelId;
  final DateTime? at;

  bool get isAttached => state == ToolImageSendState.attached;

  ToolImageSendStatus copyWith({
    ToolImageSendState? state,
    String? detail,
    String? modelId,
    DateTime? at,
  }) {
    return ToolImageSendStatus(
      toolCallId: toolCallId,
      state: state ?? this.state,
      detail: detail ?? this.detail,
      modelId: modelId ?? this.modelId,
      at: at ?? this.at,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'state': state.name,
      if (detail != null && detail!.isNotEmpty) 'detail': detail,
      if (modelId != null && modelId!.isNotEmpty) 'modelId': modelId,
      if (at != null) 'at': at!.toIso8601String(),
    };
  }

  static ToolImageSendState? tryParseState(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    for (final state in ToolImageSendState.values) {
      if (state.name == raw) return state;
    }
    return null;
  }
}

/// One-shot degraded retry gate for the provider-400 image fallback.
///
/// A 400 is terminal in the normal retry policy. This helper only allows the
/// single, deliberate retry that removes the optional tool-result images:
/// the request must actually have carried an image, it must not be a
/// context-overflow rejection (that path has its own trim retry), and no
/// visible output/reasoning may already have been billed.
bool shouldRetryToolImagesWithoutImages({
  required int? statusCode,
  required bool isContextOverflow,
  required bool alreadyTried,
  required bool yieldedAnything,
  required bool receivedReasoning,
  required int attachedImageCount,
}) {
  return statusCode == 400 &&
      !isContextOverflow &&
      !alreadyTried &&
      !yieldedAnything &&
      !receivedReasoning &&
      attachedImageCount > 0;
}
