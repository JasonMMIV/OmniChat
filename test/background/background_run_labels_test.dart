import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/services/background/background_run_labels.dart';
import 'package:OmniChat/core/services/background/background_run_monitor.dart';
import 'package:OmniChat/l10n/app_localizations_en.dart';

void main() {
  final l10n = AppLocalizationsEn();

  group('backgroundRunStatusLabel', () {
    test('idle has no status row', () {
      expect(
        backgroundRunStatusLabel(const BackgroundRunSnapshot(), l10n),
        isNull,
      );
    });

    test('running without a title omits the suffix', () {
      const snap = BackgroundRunSnapshot(
        phase: BackgroundRunPhase.running,
        activeConversationIds: <String>{'c1'},
      );

      expect(backgroundRunStatusLabel(snap, l10n), l10n.desktopTrayRunGenerating);
    });

    test('running with a title appends it', () {
      const snap = BackgroundRunSnapshot(
        phase: BackgroundRunPhase.running,
        activeConversationIds: <String>{'c1'},
        activeTitle: 'Plan',
        activeTitledConversationId: 'c1',
      );

      expect(
        backgroundRunStatusLabel(snap, l10n),
        '${l10n.desktopTrayRunGenerating} — Plan',
      );
    });

    test('concurrent runs expose the count so the status is not misleading', () {
      const snap = BackgroundRunSnapshot(
        phase: BackgroundRunPhase.running,
        activeConversationIds: <String>{'c1', 'c2'},
        activeTitle: 'Plan',
        activeTitledConversationId: 'c2',
      );

      expect(
        backgroundRunStatusLabel(snap, l10n),
        '${l10n.desktopTrayRunGenerating} (2) — Plan',
      );
    });

    test('terminal phases keep the title', () {
      const ready = BackgroundRunSnapshot(
        phase: BackgroundRunPhase.ready,
        lastConversationId: 'c1',
        lastTitle: 'Plan',
      );
      const failed = BackgroundRunSnapshot(
        phase: BackgroundRunPhase.failed,
        lastConversationId: 'c1',
        lastTitle: 'Plan',
      );
      const stopped = BackgroundRunSnapshot(
        phase: BackgroundRunPhase.stopped,
        lastConversationId: 'c1',
        lastTitle: 'Plan',
      );

      expect(backgroundRunStatusLabel(ready, l10n),
          '${l10n.desktopTrayRunReady} — Plan');
      expect(backgroundRunStatusLabel(failed, l10n),
          '${l10n.desktopTrayRunFailed} — Plan');
      expect(backgroundRunStatusLabel(stopped, l10n),
          '${l10n.desktopTrayRunStopped} — Plan');
    });

    test('terminal phases without a title stay bare', () {
      const ready = BackgroundRunSnapshot(
        phase: BackgroundRunPhase.ready,
        lastConversationId: 'c1',
        lastTitle: '   ',
      );

      expect(backgroundRunStatusLabel(ready, l10n), l10n.desktopTrayRunReady);
    });
  });

  group('backgroundRunJustFinished', () {
    test('running to ready or failed is a completion', () {
      expect(
        backgroundRunJustFinished(
          BackgroundRunPhase.running,
          BackgroundRunPhase.ready,
        ),
        isTrue,
      );
      expect(
        backgroundRunJustFinished(
          BackgroundRunPhase.running,
          BackgroundRunPhase.failed,
        ),
        isTrue,
      );
    });

    test('a user stop is not a completion', () {
      expect(
        backgroundRunJustFinished(
          BackgroundRunPhase.running,
          BackgroundRunPhase.stopped,
        ),
        isFalse,
      );
    });

    test('non-running transitions are not completions', () {
      expect(
        backgroundRunJustFinished(
          BackgroundRunPhase.ready,
          BackgroundRunPhase.running,
        ),
        isFalse,
      );
      expect(
        backgroundRunJustFinished(
          BackgroundRunPhase.idle,
          BackgroundRunPhase.ready,
        ),
        isFalse,
      );
      expect(
        backgroundRunJustFinished(
          BackgroundRunPhase.failed,
          BackgroundRunPhase.ready,
        ),
        isFalse,
      );
    });
  });
}
