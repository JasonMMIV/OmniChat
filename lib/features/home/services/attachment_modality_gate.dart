// Attachment x model-modality gate (multimodal plan C1).
//
// Single source of truth for "will this attachment actually reach the model".
// Kept as a pure function so the send path and tests agree.
//
// Scope notes:
//   - PDF is always deliverable: native document input when supported,
//     otherwise the existing DocumentTextExtractor fallback.
//   - Video keeps its existing `userImagePaths` path (§7 F5); it is not gated
//     here to avoid double-send changes.
//   - Images keep the existing path; only the last message's images are sent
//     and the transport already gates remote fetching on image capability.

import '../../../core/models/chat_input_data.dart';
import '../../../core/providers/model_provider.dart';
import '../../../core/services/api/attachment_kind.dart';

class AttachmentModalityGate {
  AttachmentModalityGate._();

  /// Audio documents that will be omitted from the request.
  ///
  /// [nativeAudioEnabled] must be the resolved policy (host gate + AI Team
  /// disable), not only the model capability: a model that advertises audio
  /// but talks to an aggregator without native support also drops the part.
  static List<DocumentAttachment> unsupported(
    List<DocumentAttachment> documents,
    ModelInfo info, {
    bool nativeAudioEnabled = true,
  }) {
    final out = <DocumentAttachment>[];
    for (final doc in documents) {
      final kind = attachmentKindFor(doc.mime, doc.fileName);
      if (kind != AttachmentKind.audio) continue;
      if (!info.input.contains(Modality.audio) || !nativeAudioEnabled) {
        out.add(doc);
      }
    }
    return out;
  }
}
