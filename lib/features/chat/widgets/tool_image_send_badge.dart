import 'package:flutter/material.dart';

import '../../../core/services/api/tool_image_send_status.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';

/// Localized explanation for a tool-image send state. `attached` is only used
/// as a defensive fallback; callers hide the badge for it.
String? toolImageSendReason(AppLocalizations l10n, ToolImageSendState state) {
  switch (state) {
    case ToolImageSendState.modelUnsupported:
      return l10n.chatMessageWidgetToolImageNotSentModel;
    case ToolImageSendState.transportUnsupported:
      return l10n.chatMessageWidgetToolImageNotSentTransport;
    case ToolImageSendState.settingOff:
      return l10n.chatMessageWidgetToolImageNotSentSetting;
    case ToolImageSendState.providerRejected:
      return l10n.chatMessageWidgetToolImageNotSentProvider;
    case ToolImageSendState.limitReached:
      return l10n.chatMessageWidgetToolImageNotSentLimit;
    case ToolImageSendState.notFound:
    case ToolImageSendState.outsideWorkspace:
    case ToolImageSendState.changed:
    case ToolImageSendState.tooLarge:
    case ToolImageSendState.unsupportedFormat:
    case ToolImageSendState.decodeFailed:
    case ToolImageSendState.unknown:
      return l10n.chatMessageWidgetToolImageNotSentUnavailable;
    case ToolImageSendState.attached:
      // Attached images never render a badge; a nullable result keeps direct
      // callers honest instead of returning misleading copy.
      return null;
  }
}

/// Static fallback used before the first runtime status arrives (or for old
/// conversations). Unknown model capability stays badge-free rather than
/// guessing. Kept pure so the three states are unit-testable.
ToolImageSendState? staticToolImageSendState({
  required bool hasImage,
  required bool sendToolImages,
  required bool? modelSupportsImages,
}) {
  if (!hasImage) return null;
  if (!sendToolImages) return ToolImageSendState.settingOff;
  if (modelSupportsImages == false) return ToolImageSendState.modelUnsupported;
  return null;
}

/// Small pill on the collapsed tool card. The tooltip/detail dialog carries
/// the reason; the card itself stays compact enough for mobile widths.
class ToolImageSendBadge extends StatelessWidget {
  const ToolImageSendBadge({
    super.key,
    required this.title,
    required this.reason,
    required this.color,
  });

  final String title;
  final String reason;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: reason,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withOpacity(0.08),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Lucide.ImageOff, size: 11, color: color),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10.5, color: color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
