class DocumentAttachment {
  final String path; // absolute file path
  final String fileName;
  final String mime; // e.g. application/pdf, text/plain

  const DocumentAttachment({
    required this.path,
    required this.fileName,
    required this.mime,
  });
}

class ChatInputData {
  final String text;
  final List<String> imagePaths; // absolute file paths or data URLs
  final List<DocumentAttachment> documents; // selected files

  /// Continue an existing helper session. Set by the `Delegated to X` card's
  /// Continue action; ignored unless the text starts with the matching
  /// `@profile` mention.
  final String? subagentSessionId;

  /// Profile that owns [subagentSessionId]. Kept together so editing a queued
  /// mention cannot attach the session to a different helper.
  final String? subagentSessionProfileId;

  const ChatInputData({
    required this.text,
    this.imagePaths = const [],
    this.documents = const [],
    this.subagentSessionId,
    this.subagentSessionProfileId,
  });

  ChatInputData copyWith({
    String? subagentSessionId,
    String? subagentSessionProfileId,
  }) {
    return ChatInputData(
      text: text,
      imagePaths: imagePaths,
      documents: documents,
      subagentSessionId: subagentSessionId ?? this.subagentSessionId,
      subagentSessionProfileId:
          subagentSessionProfileId ?? this.subagentSessionProfileId,
    );
  }
}
