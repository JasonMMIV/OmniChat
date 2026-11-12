import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../core/services/background/background_run_labels.dart';
import '../core/services/background/background_run_monitor.dart';
import '../l10n/app_localizations.dart';

/// Desktop tray + window close behaviour controller.
///
/// - Manages system tray icon visibility and context menu
/// - Implements "minimize to tray on close" when enabled in settings
class DesktopTrayController with TrayListener, WindowListener {
  DesktopTrayController._();
  static final DesktopTrayController instance = DesktopTrayController._();

  bool _initialized = false;
  bool _isDesktop = false;
  bool _trayVisible = false;
  bool _showTraySetting = false;
  bool _minimizeToTrayOnClose = false;
  String _localeKey = '';
  bool _contextMenuOpen = false;
  AppLocalizations? _l10n;
  BackgroundRunSnapshot? _runSnapshot;

  /// Sync tray state from settings & current localization.
  /// Safe to call multiple times; initialization is performed lazily.
  Future<void> syncFromSettings(
    AppLocalizations l10n, {
    required bool showTray,
    required bool minimizeToTrayOnClose,
  }) async {
    if (kIsWeb) return;
    final isDesktop = defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux;
    if (!isDesktop) return;
    _isDesktop = true;

    if (!_initialized) {
      try {
        await windowManager.ensureInitialized();
      } catch (_) {}
      try {
        trayManager.addListener(this);
      } catch (_) {}
      try {
        windowManager.addListener(this);
      } catch (_) {}
      _initialized = true;
    }

    // Persist latest settings (enforce basic invariant in controller as well).
    _showTraySetting = showTray;
    _minimizeToTrayOnClose = showTray && minimizeToTrayOnClose;

    // Whether to intercept window close.
    final shouldPreventClose = _showTraySetting && _minimizeToTrayOnClose;
    try {
      await windowManager.setPreventClose(shouldPreventClose);
    } catch (_) {}

    // Handle tray icon visibility + localized menu.
    final newLocaleKey = l10n.localeName;
    final localeChanged = newLocaleKey != _localeKey;
    _localeKey = newLocaleKey;
    _l10n = l10n;
    // Seed the run status so a tray enabled mid-run renders the current state
    // instead of waiting for the next monitor change.
    _runSnapshot = BackgroundRunMonitor.instance.snapshot;

    if (_showTraySetting) {
      if (!_trayVisible || localeChanged) {
        await _ensureTrayIconAndMenu();
        _trayVisible = true;
      }
    } else {
      if (_trayVisible) {
        try {
          await trayManager.destroy();
        } catch (_) {}
        _trayVisible = false;
      }
    }
  }

  Future<void> _ensureTrayIconAndMenu() async {
    if (!_isDesktop) return;

    // Use platform-specific tray icons (mirrors Gopeed's approach):
    // - Windows: multi-size ICO for crisp scaling
    // - macOS: template PNG so the system can adapt to light/dark menu bar
    // - Linux/others: regular PNG asset
    final platform = defaultTargetPlatform;
    try {
      if (platform == TargetPlatform.windows) {
        await trayManager.setIcon('assets/app_icon.ico');
      } else if (platform == TargetPlatform.macOS) {
        await trayManager.setIcon('assets/icon_mac.png', isTemplate: true);
      } else {
        await trayManager.setIcon('assets/app_icon.png');
      }
    } catch (_) {}

    await _applyToolTip();
    try {
      await trayManager.setContextMenu(_buildMenu());
    } catch (_) {}
  }

  /// P2-2: mirror the app-level run state (generating / reply ready / failed /
  /// stopped) into the tray tooltip and the first context-menu row. Never
  /// creates a tray the user turned off, and never touches the tray when the
  /// platform has no tray backend (mobile, web). Calling this with the same
  /// snapshot is a no-op so redundant monitor emissions are cheap.
  Future<void> applyRunSnapshot(BackgroundRunSnapshot snapshot) async {
    if (kIsWeb || !_isDesktop || !_showTraySetting || !_trayVisible) return;
    if (_l10n == null) return;
    if (snapshot == _runSnapshot) return;
    _runSnapshot = snapshot;
    await _applyToolTip();
    try {
      await trayManager.setContextMenu(_buildMenu());
    } catch (_) {}
  }

  Future<void> _applyToolTip() async {
    if (!_isDesktop) return;
    // Some Linux environments do not support tooltip; keep the call
    // consistent with Gopeed and skip it there.
    if (defaultTargetPlatform == TargetPlatform.linux) return;
    final status = _statusText();
    final text = status == null ? 'OmniChat' : 'OmniChat — $status';
    try {
      await trayManager.setToolTip(_truncate(text, 120));
    } catch (_) {}
  }

  Menu _buildMenu() {
    final l10n = _l10n!;
    final items = <MenuItem>[];
    final status = _statusText();
    if (status != null) {
      // Clicking the status row restores the window and opens the chat that is
      // running (or just finished) — the desktop stand-in for a toast.
      items.add(
        MenuItem(
          label: _truncate(status, 96),
          toolTip: _truncate(status, 120),
          onClick: (_) async => _openRunConversation(),
        ),
      );
      items.add(MenuItem.separator());
    }
    items.add(
      MenuItem(
        label: l10n.desktopTrayMenuShowWindow,
        onClick: (_) async => _showWindow(),
      ),
    );
    items.add(MenuItem.separator());
    items.add(
      MenuItem(
        label: l10n.desktopTrayMenuExit,
        onClick: (_) async => _exitApp(),
      ),
    );
    return Menu(items: items);
  }

  /// Localized one-line run status, or null when there is nothing to report
  /// (idle, or no monitor state yet).
  String? _statusText() {
    final l10n = _l10n;
    final snapshot = _runSnapshot;
    if (l10n == null || snapshot == null) return null;
    return backgroundRunStatusLabel(snapshot, l10n);
  }

  Future<void> _openRunConversation() async {
    final id = _runSnapshot?.openConversationId;
    await _showWindow();
    if (id == null || id.isEmpty) return;
    BackgroundRunMonitor.instance.requestOpen(id);
    // The user has seen the result; drop the terminal tray row. Active runs
    // are left alone by acknowledgeTerminal().
    BackgroundRunMonitor.instance.acknowledgeTerminal();
  }

  String _truncate(String value, int max) =>
      value.length <= max ? value : '${value.substring(0, max - 1)}…';

  Future<void> _showWindow() async {
    if (!_isDesktop) return;
    try {
      await windowManager.show();
      await windowManager.focus();
    } catch (_) {}
  }

  Future<void> _exitApp() async {
    if (!_isDesktop) return;
    try {
      // On Windows we may have `preventClose` enabled to support
      // "close to tray". Temporarily disable it and send a normal
      // close so the window can exit immediately without being
      // intercepted by the minimize‑to‑tray logic.
      if (defaultTargetPlatform == TargetPlatform.windows) {
        try {
          await windowManager.setPreventClose(false);
        } catch (_) {}
        try {
          await windowManager.close();
          return;
        } catch (_) {}
      }

      // Other desktop platforms (and Windows fallback): destroy the
      // window so the process exits cleanly.
      await windowManager.destroy();
    } catch (_) {}
  }

  // ===== TrayListener =====

  @override
  void onTrayIconMouseDown() {
    // Left‑click: bring main window to front.
    if (!_isDesktop) return;
    _showWindow();
  }

  @override
  void onTrayIconRightMouseDown() async {
    // Right‑click: 弹出托盘菜单。
    // 使用内部标记防止在一次交互周期内重复弹出，
    // 否则在某些 Windows 环境下会看到第二个偏移的菜单。
    if (_contextMenuOpen) {
      return;
    }
    _contextMenuOpen = true;
    try {
      // Windows 需要在调用 TrackPopupMenu 前把窗口置为前台，
      // 否则点击其他地方时菜单可能不会自动关闭。
      await trayManager.popUpContextMenu(bringAppToFront: true);
    } catch (_) {}
    // 无论是点击菜单项还是点击其他地方关闭菜单，
    // popUpContextMenu 都会在菜单关闭后返回，这里统一重置标记。
    _contextMenuOpen = false;
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    // 任一菜单项被点击视为一次菜单交互结束，
    // 额外保险地解除防抖标记（即使 Future 尚未完成）。
    _contextMenuOpen = false;
  }

  // ===== WindowListener =====

  @override
  void onWindowClose() async {
    if (!_isDesktop) return;
    // Only intercept close when user enabled minimize-to-tray.
    final shouldIntercept = _showTraySetting && _minimizeToTrayOnClose;
    if (!shouldIntercept) return;
    try {
      final isPreventClose = await windowManager.isPreventClose();
      if (!isPreventClose) return;
      await windowManager.hide();
    } catch (_) {}
  }
}
