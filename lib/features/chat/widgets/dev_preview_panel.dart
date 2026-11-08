import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_windows/webview_windows.dart' as winweb;

import '../../../core/services/dev/dev_mime.dart';
import '../../../core/services/dev/dev_preview_controller.dart';
import '../../../core/services/dev/dev_server_service.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/snackbar.dart';

/// Viewport presets for the desktop preview stage.
enum DevPreviewViewport {
  full(0),
  tablet(768),
  phone(390);

  const DevPreviewViewport(this.width);
  final double width;
}

enum _ConsoleFilter { errors, warnings, all }

/// Cross-platform handle the toolbar uses to drive the live WebView.
class DevPreviewWebViewHandle {
  VoidCallback? _reload;

  void reload() => _reload?.call();
}

/// The site-preview panel: tabs, live WebView, console drawer and entry-point
/// discovery. Used by both [DevPreviewPage] (mobile) and the desktop dialog.
class DevPreviewPanel extends StatefulWidget {
  const DevPreviewPanel({
    super.key,
    required this.workspaceRoot,
    this.initialPath,
  });

  final String workspaceRoot;

  /// Workspace-relative file or directory to open first. Null falls back to
  /// `index.html` when present, otherwise the entry-point empty state.
  final String? initialPath;

  @override
  State<DevPreviewPanel> createState() => _DevPreviewPanelState();
}

class _DevPreviewPanelState extends State<DevPreviewPanel> {
  late final DevPreviewController _controller;
  final DevPreviewWebViewHandle _handle = DevPreviewWebViewHandle();
  final ScrollController _consoleScroll = ScrollController();
  DevPreviewViewport _viewport = DevPreviewViewport.full;
  _ConsoleFilter _filter = _ConsoleFilter.errors;
  bool _consoleOpen = false;

  @override
  void initState() {
    super.initState();
    _controller = DevPreviewController(
      workspaceRoot: widget.workspaceRoot,
      initialPath: widget.initialPath,
    )..addListener(_handleControllerChanged);
    // Start after the first frame: the controller's initial notifyListeners()
    // would otherwise call setState from initState.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_controller.start());
    });
  }

  void _handleControllerChanged() {
    if (!mounted) return;
    setState(() {});
    if (_consoleOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_consoleScroll.hasClients) return;
        _consoleScroll.jumpTo(_consoleScroll.position.maxScrollExtent);
      });
    }
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_handleControllerChanged)
      ..dispose();
    _consoleScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 820;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildToolbar(context, wide: wide),
            const Divider(height: 1),
            Expanded(child: _buildBody(context)),
            AnimatedSize(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: _consoleOpen
                  ? _buildConsole(context)
                  : const SizedBox(width: double.infinity, height: 0),
            ),
          ],
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Toolbar + tabs
  // ---------------------------------------------------------------------------

  Widget _buildToolbar(BuildContext context, {required bool wide}) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final tabs = _controller.tabs;
    return Container(
      height: 50,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      color: cs.surface,
      child: Row(
        children: [
          Expanded(
            child: tabs.isEmpty
                ? Align(
                    alignment: Alignment.centerLeft,
                    child: _controller.baseUrl == null
                        ? const SizedBox.shrink()
                        : _buildStatusPill(context),
                  )
                : ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: tabs.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 6),
                    itemBuilder: (context, index) {
                      final tab = tabs[index];
                      return _buildTabChip(
                        context,
                        tab,
                        active: _controller.activeTab?.id == tab.id,
                      );
                    },
                  ),
          ),
          if (wide) ...[
            _buildViewportSwitcher(context),
            const SizedBox(width: 6),
            Container(
              width: 1,
              height: 20,
              color: cs.onSurface.withValues(alpha: 0.10),
            ),
            const SizedBox(width: 6),
          ],
          Tooltip(
            message: l10n.devPreviewEntryPoints,
            child: IosIconButton(
              icon: Lucide.FolderOpen,
              size: 17,
              minSize: 32,
              semanticLabel: l10n.devPreviewEntryPoints,
              onTap: _showEntryPicker,
            ),
          ),
          Tooltip(
            message: l10n.messageWebViewRefreshTooltip,
            child: IosIconButton(
              icon: Lucide.RefreshCw,
              size: 17,
              minSize: 32,
              semanticLabel: l10n.messageWebViewRefreshTooltip,
              enabled: _controller.activeTab != null,
              onTap: _handle.reload,
            ),
          ),
          Tooltip(
            message: l10n.messageWebViewOpenInBrowser,
            child: IosIconButton(
              icon: Lucide.ExternalLink,
              size: 17,
              minSize: 32,
              semanticLabel: l10n.messageWebViewOpenInBrowser,
              enabled: _controller.activeTab != null,
              onTap: _openInBrowser,
            ),
          ),
          _buildConsoleButton(context),
        ],
      ),
    );
  }

  Widget _buildTabChip(
    BuildContext context,
    DevPreviewTab tab, {
    required bool active,
  }) {
    final cs = Theme.of(context).colorScheme;
    final icon = tab.relativePath.isEmpty || !devIsHtmlPath(tab.relativePath)
        ? Lucide.Globe
        : Lucide.Code;
    return Material(
      color: active
          ? cs.primary.withValues(alpha: 0.12)
          : cs.surfaceContainerHighest.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: () => _controller.selectTab(tab.id),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.fromLTRB(9, 5, 4, 5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color: active
                  ? cs.primary.withValues(alpha: 0.35)
                  : Colors.transparent,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 13,
                color: active
                    ? cs.primary
                    : cs.onSurface.withValues(alpha: 0.55),
              ),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 190),
                child: Text(
                  tab.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                    color: active
                        ? cs.onSurface
                        : cs.onSurface.withValues(alpha: 0.72),
                  ),
                ),
              ),
              const SizedBox(width: 2),
              InkResponse(
                radius: 12,
                onTap: () => _controller.closeTab(tab.id),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(
                    Lucide.X,
                    size: 12,
                    color: cs.onSurface.withValues(alpha: 0.45),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildViewportSwitcher(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    Widget option(
      DevPreviewViewport viewport,
      IconData? icon,
      String text,
      String label,
    ) {
      final selected = _viewport == viewport;
      final color = selected ? cs.primary : cs.onSurface.withValues(alpha: 0.5);
      return Tooltip(
        message: label,
        child: Material(
          color: selected
              ? cs.primary.withValues(alpha: 0.14)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () => setState(() => _viewport = viewport),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
              child: icon != null
                  ? Icon(icon, size: 14, color: color)
                  : Text(
                      text,
                      style: TextStyle(
                        fontSize: 9.5,
                        fontWeight: FontWeight.w700,
                        color: color,
                      ),
                    ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          option(
            DevPreviewViewport.full,
            Lucide.Monitor,
            '',
            l10n.devPreviewViewportDesktop,
          ),
          option(
            DevPreviewViewport.tablet,
            null,
            '768',
            l10n.devPreviewViewportTablet,
          ),
          option(
            DevPreviewViewport.phone,
            Lucide.Phone,
            '',
            l10n.devPreviewViewportMobile,
          ),
        ],
      ),
    );
  }

  Widget _buildConsoleButton(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final errors = _controller.errorCount;
    final warnings = _controller.warningCount;
    final badge = errors + warnings;
    return Tooltip(
      message: l10n.messageWebViewConsoleLogs,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          IosIconButton(
            icon: Lucide.Terminal,
            size: 17,
            minSize: 32,
            color: _consoleOpen ? cs.primary : null,
            semanticLabel: l10n.messageWebViewConsoleLogs,
            onTap: () => setState(() => _consoleOpen = !_consoleOpen),
          ),
          if (badge > 0)
            Positioned(
              right: 1,
              top: 2,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: errors > 0 ? cs.error : cs.secondary,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: cs.surface, width: 1),
                ),
                child: Text(
                  '$badge',
                  style: TextStyle(
                    fontSize: 8,
                    height: 1.2,
                    fontWeight: FontWeight.w700,
                    color: errors > 0 ? cs.onError : cs.onSecondary,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Body
  // ---------------------------------------------------------------------------

  Widget _buildBody(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (defaultTargetPlatform == TargetPlatform.linux) {
      return _messageState(
        context,
        icon: Lucide.Monitor,
        title: l10n.devPreviewNotSupported,
        body: '',
      );
    }
    if (_controller.loading) {
      return const Center(
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(strokeWidth: 2.4),
        ),
      );
    }
    final error = _controller.error;
    if (error != null) {
      // Details belong in the debug log (written once by the controller), not
      // the localized UI (manual v1.25.1).
      return _messageState(
        context,
        icon: Lucide.CircleAlert,
        title: l10n.devPreviewOpenFailed,
        body: '',
        action: FilledButton.icon(
          onPressed: () => unawaited(_controller.retry()),
          icon: const Icon(Lucide.RefreshCw, size: 16),
          label: Text(l10n.htmlPreviewRetry),
        ),
        isError: true,
      );
    }
    // Check the session before the empty state: a dead session must not show
    // "nothing open" chips that silently no-op.
    if (!_controller.isRunning) {
      // Another workspace's panel (or a forced stop) closed the shared
      // session; the page would otherwise silently keep a dead URL.
      return _messageState(
        context,
        icon: Lucide.CircleAlert,
        title: l10n.devPreviewSessionClosed,
        body: '',
        action: FilledButton.icon(
          onPressed: () => unawaited(_controller.retry()),
          icon: const Icon(Lucide.RefreshCw, size: 16),
          label: Text(l10n.htmlPreviewRetry),
        ),
        isError: true,
      );
    }
    final tab = _controller.activeTab;
    if (tab == null) return _buildEmptyState(context);
    return _buildStage(context, tab);
  }

  Widget _buildStage(BuildContext context, DevPreviewTab tab) {
    final cs = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 820;
        final target = _viewport == DevPreviewViewport.full
            ? constraints.maxWidth
            : _viewport.width;
        final width = target > constraints.maxWidth
            ? constraints.maxWidth
            : target;
        final stage = ClipRRect(
          borderRadius: BorderRadius.circular(wide ? 12 : 0),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: cs.surface,
              border: wide
                  ? Border.all(color: cs.onSurface.withValues(alpha: 0.10))
                  : null,
              boxShadow: wide
                  ? [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.18),
                        blurRadius: 24,
                        offset: const Offset(0, 8),
                      ),
                    ]
                  : null,
            ),
            child: DevPreviewWebView(url: tab.url, handle: _handle),
          ),
        );
        return ColoredBox(
          color: cs.surfaceContainerHighest.withValues(alpha: 0.24),
          child: Stack(
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _DotGridPainter(
                    color: cs.onSurface.withValues(alpha: 0.055),
                  ),
                ),
              ),
              Padding(
                padding: EdgeInsets.all(wide ? 16 : 0),
                child: Center(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    width: width,
                    height: double.infinity,
                    child: stage,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final entries = _controller.entries;
    final visible = entries.take(8).toList();
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 470),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.10),
                  shape: BoxShape.circle,
                ),
                child: Icon(Lucide.Monitor, size: 28, color: cs.primary),
              ),
              const SizedBox(height: 16),
              Text(
                l10n.devPreviewEmptyTitle,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                l10n.devPreviewEmptyHint,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.5,
                  color: cs.onSurface.withValues(alpha: 0.62),
                ),
              ),
              const SizedBox(height: 20),
              if (entries.isEmpty)
                Text(
                  l10n.devPreviewNoEntryPoints,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurface.withValues(alpha: 0.55),
                  ),
                )
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    for (final entry in visible)
                      ActionChip(
                        avatar: Icon(
                          devIsHtmlPath(entry.relativePath)
                              ? Lucide.Code
                              : Lucide.FolderOpen,
                          size: 14,
                        ),
                        label: Text(
                          entry.title,
                          style: const TextStyle(fontSize: 11.5),
                        ),
                        onPressed: () => _controller.openEntry(entry),
                      ),
                    if (entries.length > visible.length)
                      ActionChip(
                        avatar: const Icon(Lucide.Plus, size: 14),
                        label: Text(
                          '+${entries.length - visible.length}',
                          style: const TextStyle(fontSize: 11.5),
                        ),
                        onPressed: _showEntryPicker,
                      ),
                  ],
                ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TextButton.icon(
                    onPressed: () => unawaited(_controller.refreshEntries()),
                    icon: const Icon(Lucide.RefreshCw, size: 14),
                    label: Text(
                      l10n.devPreviewRescan,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  if (_controller.baseUrl != null)
                    Padding(
                      padding: const EdgeInsets.only(left: 10),
                      child: _buildStatusPill(context),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusPill(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: const BoxDecoration(
              color: Color(0xFF3FB950),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            _controller.baseUrl!.replaceFirst('http://', ''),
            style: TextStyle(
              fontSize: 10.5,
              fontFamily: 'monospace',
              color: cs.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }

  Widget _messageState(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String body,
    Widget? action,
    bool isError = false,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 34, color: isError ? cs.error : cs.primary),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
                height: 1.4,
              ),
            ),
            if (body.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                body,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: cs.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ],
            if (action != null) ...[const SizedBox(height: 16), action],
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Console drawer
  // ---------------------------------------------------------------------------

  List<DevConsoleEntry> get _visibleConsole {
    final all = _controller.console;
    return switch (_filter) {
      _ConsoleFilter.errors =>
        all.where((entry) => entry.level == 'error').toList(),
      _ConsoleFilter.warnings =>
        all.where((entry) => entry.level == 'warn').toList(),
      _ConsoleFilter.all => all,
    };
  }

  Widget _buildConsole(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final entries = _visibleConsole;
    final list = entries.isEmpty
        ? Center(
            child: Text(
              l10n.messageWebViewNoConsoleMessages,
              style: TextStyle(
                fontSize: 12,
                color: cs.onSurface.withValues(alpha: 0.45),
              ),
            ),
          )
        : ListView.builder(
            controller: _consoleScroll,
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
            itemCount: entries.length,
            itemBuilder: (context, index) =>
                _consoleRow(context, entries[index]),
          );
    return Container(
      height: 212,
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border(
          top: BorderSide(color: cs.onSurface.withValues(alpha: 0.10)),
        ),
      ),
      child: Column(
        children: [
          SizedBox(
            height: 38,
            child: Row(
              children: [
                const SizedBox(width: 12),
                Text(
                  l10n.devPreviewConsoleTitle.toUpperCase(),
                  style: TextStyle(
                    fontSize: 10.5,
                    letterSpacing: 0.6,
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface.withValues(alpha: 0.55),
                  ),
                ),
                const SizedBox(width: 10),
                _consoleFilterChip(
                  context,
                  _ConsoleFilter.errors,
                  l10n.devPreviewConsoleErrors,
                  _controller.errorCount,
                ),
                _consoleFilterChip(
                  context,
                  _ConsoleFilter.warnings,
                  l10n.devPreviewConsoleWarnings,
                  _controller.warningCount,
                ),
                _consoleFilterChip(
                  context,
                  _ConsoleFilter.all,
                  l10n.devPreviewConsoleAll,
                  _controller.console.length,
                ),
                const Spacer(),
                IosIconButton(
                  icon: Lucide.Eraser,
                  size: 15,
                  minSize: 28,
                  semanticLabel: l10n.devPreviewConsoleClear,
                  onTap: _controller.clearConsole,
                ),
                IosIconButton(
                  icon: Lucide.X,
                  size: 15,
                  minSize: 28,
                  semanticLabel: l10n.devPreviewConsoleClose,
                  onTap: () => setState(() => _consoleOpen = false),
                ),
                const SizedBox(width: 6),
              ],
            ),
          ),
          Divider(height: 1, color: cs.onSurface.withValues(alpha: 0.08)),
          Expanded(child: list),
        ],
      ),
    );
  }

  Widget _consoleFilterChip(
    BuildContext context,
    _ConsoleFilter filter,
    String label,
    int count,
  ) {
    final cs = Theme.of(context).colorScheme;
    final selected = _filter == filter;
    return Padding(
      padding: const EdgeInsets.only(right: 5),
      child: Material(
        color: selected
            ? cs.primary.withValues(alpha: 0.14)
            : cs.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => setState(() => _filter = filter),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            child: Text(
              '$label · $count',
              style: TextStyle(
                fontSize: 10,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected
                    ? cs.primary
                    : cs.onSurface.withValues(alpha: 0.62),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _consoleRow(BuildContext context, DevConsoleEntry entry) {
    final cs = Theme.of(context).colorScheme;
    final color = switch (entry.level) {
      'error' => cs.error,
      'warn' => cs.secondary,
      'debug' => cs.onSurface.withValues(alpha: 0.45),
      _ => cs.onSurface.withValues(alpha: 0.68),
    };
    final source = (entry.source ?? '').trim();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 42,
            padding: const EdgeInsets.symmetric(vertical: 2),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              entry.level.toUpperCase(),
              style: TextStyle(
                fontSize: 8.5,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.message,
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.45,
                    fontFamily: 'monospace',
                    color: cs.onSurface.withValues(alpha: 0.86),
                  ),
                ),
                if (source.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      entry.line != null && entry.line! > 0
                          ? '$source:${entry.line}'
                          : source,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 9.5,
                        fontFamily: 'monospace',
                        color: cs.onSurface.withValues(alpha: 0.42),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  Future<void> _openInBrowser() async {
    final tab = _controller.activeTab;
    if (tab == null) return;
    final ok = await launchUrl(
      Uri.parse(tab.url),
      mode: LaunchMode.externalApplication,
    );
    if (!ok && mounted) {
      showAppSnackBar(
        context,
        message: AppLocalizations.of(context)!.webView2NotAvailableMessage,
        type: NotificationType.error,
      );
    }
  }

  Future<void> _showEntryPicker() async {
    final l10n = AppLocalizations.of(context)!;
    final entries = _controller.entries;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final cs = Theme.of(dialogContext).colorScheme;
        return AlertDialog(
          title: Text(l10n.devPreviewEntryPoints),
          contentPadding: const EdgeInsets.fromLTRB(0, 12, 0, 0),
          content: SizedBox(
            width: 420,
            height: 420,
            child: entries.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        l10n.devPreviewNoEntryPoints,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurface.withValues(alpha: 0.6),
                        ),
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: entries.length,
                    itemBuilder: (context, index) {
                      final entry = entries[index];
                      return ListTile(
                        dense: true,
                        leading: Icon(
                          devIsHtmlPath(entry.relativePath)
                              ? Lucide.Code
                              : Lucide.FolderOpen,
                          size: 17,
                        ),
                        title: Text(
                          entry.relativePath,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12.5),
                        ),
                        onTap: () {
                          Navigator.of(dialogContext).pop();
                          _controller.openEntry(entry);
                        },
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                unawaited(_controller.refreshEntries());
              },
              child: Text(l10n.devPreviewRescan),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(l10n.mcpPageClose),
            ),
          ],
        );
      },
    );
  }
}

/// The live WebView. Windows uses WebView2 (`webview_windows`); every other
/// preview-capable platform uses `webview_flutter`.
class DevPreviewWebView extends StatefulWidget {
  const DevPreviewWebView({super.key, required this.url, required this.handle});

  final String url;
  final DevPreviewWebViewHandle handle;

  @override
  State<DevPreviewWebView> createState() => _DevPreviewWebViewState();
}

class _DevPreviewWebViewState extends State<DevPreviewWebView> {
  WebViewController? _flutterController;
  winweb.WebviewController? _windowsController;
  bool _ready = false;
  bool _initialized = false;
  bool _disposed = false;
  bool _loading = true;
  String? _error;
  String? _lastUrl;

  @override
  void initState() {
    super.initState();
    widget.handle._reload = _reload;
    unawaited(_initialize());
  }

  @override
  void didUpdateWidget(covariant DevPreviewWebView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.handle, widget.handle)) {
      oldWidget.handle._reload = null;
      widget.handle._reload = _reload;
    }
    if (oldWidget.url != widget.url) {
      unawaited(_load());
    }
  }

  Future<void> _initialize() async {
    if (Platform.isWindows) {
      final controller = winweb.WebviewController();
      try {
        await controller.initialize();
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _error = '$e';
          _loading = false;
        });
        return;
      }
      if (_disposed) return;
      _initialized = true;
      _windowsController = controller;
      try {
        await controller.setBackgroundColor(Colors.transparent);
      } catch (_) {}
      if (_disposed) return;
      _ready = true;
      await _load();
      return;
    }
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (mounted) setState(() => _loading = true);
          },
          onPageFinished: (_) {
            if (mounted) {
              setState(() {
                _loading = false;
                _error = null;
              });
            }
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame == true && mounted) {
              setState(() {
                _loading = false;
                _error = error.description;
              });
            }
          },
        ),
      );
    _flutterController = controller;
    _ready = true;
    await _load();
  }

  Future<void> _load() async {
    if (!_ready || _disposed) return;
    final url = widget.url;
    if (url == _lastUrl) return;
    _lastUrl = url;
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      if (Platform.isWindows) {
        await _windowsController?.loadUrl(url);
        // webview_windows exposes no page-finished event; hide the loading
        // state once the navigation call has been accepted.
        if (mounted) setState(() => _loading = false);
      } else {
        await _flutterController?.loadRequest(Uri.parse(url));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  void _reload() {
    if (!_ready) return;
    try {
      if (Platform.isWindows) {
        unawaited(_windowsController?.reload() ?? Future<void>.value());
      } else {
        unawaited(_flutterController?.reload() ?? Future<void>.value());
      }
      if (mounted) setState(() => _loading = true);
      if (Platform.isWindows) {
        Future<void>.delayed(const Duration(milliseconds: 350), () {
          if (mounted) setState(() => _loading = false);
        });
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _disposed = true;
    _ready = false;
    if (widget.handle._reload == _reload) {
      widget.handle._reload = null;
    }
    // Same race-safe disposal as the HTML preview dialog: disposing while
    // initialize() is still pending races the WebView2 COM heap.
    if (_initialized && _windowsController != null) {
      try {
        _windowsController!.dispose();
      } catch (_) {}
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    if (_error != null) {
      return ColoredBox(
        color: cs.surface,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Lucide.CircleAlert, size: 30, color: cs.error),
                const SizedBox(height: 10),
                Text(
                  l10n.htmlPreviewLoadFailed,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 6),
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontFamily: 'monospace',
                    color: cs.onSurface.withValues(alpha: 0.55),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final viewer = Platform.isWindows
        ? (_windowsController == null
              ? const SizedBox.shrink()
              : winweb.Webview(_windowsController!))
        : (_flutterController == null
              ? const SizedBox.shrink()
              : WebViewWidget(controller: _flutterController!));
    return Stack(
      children: [
        Positioned.fill(child: viewer),
        if (_loading)
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LinearProgressIndicator(minHeight: 2),
          ),
      ],
    );
  }
}

/// Subtle dotted backdrop behind the preview card.
class _DotGridPainter extends CustomPainter {
  _DotGridPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    const spacing = 26.0;
    for (var y = spacing / 2; y < size.height; y += spacing) {
      for (var x = spacing / 2; x < size.width; x += spacing) {
        canvas.drawCircle(Offset(x, y), 1.1, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DotGridPainter oldDelegate) =>
      oldDelegate.color != color;
}
