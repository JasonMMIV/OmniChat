/// P2-2: pure presentation helpers shared by the desktop tray and the Android
/// notification gate (docs/Cowork剩餘項目實作計畫.md §2.5).
///
/// Kept separate from `background_run_presentation.dart` and
/// `desktop_tray_controller.dart` because both depend on platform plugins,
/// while these two decisions are the truthfulness-critical part and must stay
/// unit-testable.
library;

import '../../../l10n/app_localizations.dart';
import 'background_run_monitor.dart';

/// Localized one-line run status for the desktop tray menu / tooltip.
///
/// Returns null when there is nothing to report (idle). A conversation title
/// is appended when known; while several runs are active the count is shown so
/// the status cannot imply a single run.
String? backgroundRunStatusLabel(
  BackgroundRunSnapshot snapshot,
  AppLocalizations l10n,
) {
  final title = (snapshot.openConversationTitle ?? '').trim();
  final suffix = title.isEmpty ? '' : ' — $title';
  switch (snapshot.phase) {
    case BackgroundRunPhase.idle:
      return null;
    case BackgroundRunPhase.running:
      final base = snapshot.activeCount > 1
          ? '${l10n.desktopTrayRunGenerating} (${snapshot.activeCount})'
          : l10n.desktopTrayRunGenerating;
      return '$base$suffix';
    case BackgroundRunPhase.ready:
      return '${l10n.desktopTrayRunReady}$suffix';
    case BackgroundRunPhase.failed:
      return '${l10n.desktopTrayRunFailed}$suffix';
    case BackgroundRunPhase.stopped:
      return '${l10n.desktopTrayRunStopped}$suffix';
  }
}

/// True when [phase] is a new terminal result the user did not cause: the
/// previous snapshot was running and the new one succeeded or failed.
///
/// `stopped` is deliberately excluded — the user pressed stop, so a "finished"
/// notification would be noise.
bool backgroundRunJustFinished(
  BackgroundRunPhase previousPhase,
  BackgroundRunPhase phase,
) =>
    previousPhase == BackgroundRunPhase.running &&
    (phase == BackgroundRunPhase.ready || phase == BackgroundRunPhase.failed);
