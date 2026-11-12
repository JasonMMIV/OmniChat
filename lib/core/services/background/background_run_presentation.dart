/// P2-2 presentation layer for [BackgroundRunMonitor]
/// (docs/Cowork剩餘項目實作計畫.md §2.5).
///
/// One subscription drives both platforms:
/// - **Desktop**: the tray icon text and its status menu row (generating /
///   ready / failed / stopped). Clicking the row restores the window and asks
///   the chat page to open the conversation. This is a *tray* status, not a
///   toast: the project ships no Windows notification plugin (see manual
///   §3.14 §11 — documented limitation, no new dependency).
/// - **Android**: a completion / failure notification, only when the user chose
///   the `onNotify` background mode and the app is not in the foreground (a
///   notification for a chat the user is watching would be noise). Tapping it
///   opens the conversation.
library;

import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding;

import '../../../desktop/desktop_tray_controller.dart';
import '../../../l10n/app_localizations.dart';
import '../../providers/settings_provider.dart';
import '../notification_service.dart';
import 'background_run_labels.dart';
import 'background_run_monitor.dart';

class BackgroundRunPresentation {
  BackgroundRunPresentation._();

  static final BackgroundRunPresentation instance =
      BackgroundRunPresentation._();

  SettingsProvider? _settings;
  AppLocalizations? _l10n;
  StreamSubscription<BackgroundRunSnapshot>? _subscription;
  BackgroundRunPhase _lastPhase = BackgroundRunPhase.idle;

  bool get isAttached => _subscription != null;

  /// Wire the monitor once. Called from the app builder; idempotent so a
  /// rebuild never installs a second subscription.
  void attach({required SettingsProvider settings}) {
    _settings = settings;
    if (_subscription != null) return;
    _subscription = BackgroundRunMonitor.instance.changes.listen(
      _onSnapshot,
      onError: (_) {},
    );
  }

  /// Latest localizations (refreshed from the app builder on locale change).
  void updateLocalizations(AppLocalizations? l10n) {
    if (l10n == null) return;
    _l10n = l10n;
  }

  Future<void> _onSnapshot(BackgroundRunSnapshot snapshot) async {
    // Compute the transition before the first await: listeners run
    // concurrently, so updating `_lastPhase` after awaiting the tray plugin
    // could overwrite a newer phase with a stale one and duplicate or drop the
    // completion notification.
    final justFinished = backgroundRunJustFinished(
      _lastPhase,
      snapshot.phase,
    );
    _lastPhase = snapshot.phase;

    try {
      await DesktopTrayController.instance.applyRunSnapshot(snapshot);
    } catch (_) {
      // A missing tray/window backend must never break generation tracking.
    }

    if (!justFinished) return;
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    if (snapshot.lastConversationId == null) return;

    final settings = _settings;
    if (settings == null ||
        settings.androidBackgroundChatMode !=
            AndroidBackgroundChatMode.onNotify) {
      return;
    }

    // Foreground completions are already visible in the chat; only notify
    // when the app is not resumed.
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle == null || lifecycle == AppLifecycleState.resumed) return;

    final l10n = _l10n;
    if (l10n == null) return;

    final failed = snapshot.phase == BackgroundRunPhase.failed;
    final title = (snapshot.displayTitle ?? '').trim();
    final body = failed
        ? l10n.backgroundRunNotificationFailed
        : l10n.backgroundRunNotificationReady;
    try {
      await NotificationService.showRunFinished(
        title: 'OmniChat',
        body: title.isEmpty ? body : '$title — $body',
        conversationId: snapshot.lastConversationId!,
      );
    } catch (_) {
      // Notification permission may be denied; the run itself is unaffected.
    }
  }
}
