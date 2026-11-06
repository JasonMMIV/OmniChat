import 'package:flutter/widgets.dart';

import '../../../core/providers/model_provider.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';

/// Icon used for a modality badge. Shared by the model picker and the
/// provider detail page so `audio` / `video` / `pdf` never render as an
/// image icon (multimodal plan §2.1-1).
IconData modalityIcon(Modality modality) {
  switch (modality) {
    case Modality.text:
      return Lucide.Type;
    case Modality.image:
      return Lucide.Image;
    case Modality.audio:
      return Lucide.Music;
    case Modality.video:
      return Lucide.Video;
    case Modality.pdf:
      return Lucide.FileText;
  }
}

/// Localized short label for a modality.
String modalityLabel(AppLocalizations l10n, Modality modality) {
  switch (modality) {
    case Modality.text:
      return l10n.modelDetailSheetTextMode;
    case Modality.image:
      return l10n.modelDetailSheetImageMode;
    case Modality.audio:
      return l10n.modelDetailSheetAudioMode;
    case Modality.video:
      return l10n.modelDetailSheetVideoMode;
    case Modality.pdf:
      return l10n.modelDetailSheetPdfMode;
  }
}
