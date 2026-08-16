import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_windows/webview_windows.dart' as winweb;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:io' as io;
import '../l10n/app_localizations.dart';
import '../icons/lucide_adapter.dart';
import '../shared/widgets/snackbar.dart';
import '../shared/widgets/ios_tactile.dart';
import 'dart:convert';

Future<void> showHtmlPreviewDesktopDialog(BuildContext context, {required String html, bool isXml = false}) async {
  if (Platform.isLinux) {
    final l10n = AppLocalizations.of(context)!;
    showAppSnackBar(context, message: l10n.htmlPreviewNotSupportedOnLinux, type: NotificationType.warning);
    return;
  }
  await showDialog(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => _HtmlPreviewDialog(html: html, isXml: isXml),
  );
}

class _HtmlPreviewDialog extends StatefulWidget {
  const _HtmlPreviewDialog({required this.html, this.isXml = false});
  final String html;
  // When true, the content is XML/SVG and is loaded as a standalone XML
  // document so the browser renders its native collapsible tree (or the SVG
  // graphic). HTML wrapping/theme injection is skipped for XML.
  final bool isXml;

  @override
  State<_HtmlPreviewDialog> createState() => _HtmlPreviewDialogState();
}

class _HtmlPreviewDialogState extends State<_HtmlPreviewDialog> {
  // macOS uses webview_flutter; Windows uses webview_windows.
  WebViewController? _flutterCtrl;
  winweb.WebviewController? _winCtrl;
  String? _tempFilePath; // for Windows loadUrl
  bool _ready = false;
  bool _loadedOnce = false;
  bool? _lastDark;
  bool _xmlLoaded = false; // XML documents are theme-independent: load once
  final List<_ConsoleMessage> _console = <_ConsoleMessage>[];
  StreamSubscription? _msgSub;
  // Race-safe init/dispose guards (v1.5.29 Fix C):
  // _winCtrl.initialize() is asynchronous (native WebView2 COM init on a
  // background thread). If the dialog is closed during initialize() the
  // previous dispose() ran _winCtrl?.dispose() concurrently with the
  // still-pending init, racing the COM heap -> 0xc0000374. These flags
  // ensure dispose() only touches the native controller after init has
  // completed; if init is still in flight we leave native cleanup to Dart
  // GC, avoiding the cross-thread race.
  bool _disposed = false;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  String? _initError;

  Future<void> _init() async {
    if (Platform.isWindows) {
      final c = winweb.WebviewController();
      try {
        await c.initialize();
      } catch (e) {
        // WebView2 Runtime missing / init failure (W-C04): degrade to a
        // readable error UI with install/browser fallbacks instead of crashing.
        if (_disposed || !mounted) return;
        _initError = '$e';
        setState(() {});
        return;
      }
      // After this await, dispose() may have already run; bail before touching
      // any COM surface to avoid racing the disposal path.
      if (_disposed) return;
      _initialized = true;
      _winCtrl = c;
      try { await c.setBackgroundColor(const Color(0x00000000)); } catch (_) {}
      if (_disposed) return;
      // Listen to web messages (console bridge)
      _msgSub = _winCtrl!.webMessage.listen((event) {
        try {
          String text;
          final dynamic e = event;
          if (e is String) {
            text = e;
          } else {
            text = (e.content?.toString() ?? e.toString());
          }
          final obj = json.decode(text) as Map<String, dynamic>;
          _pushConsole(level: (obj['level']?.toString() ?? 'log').toUpperCase(), message: obj['message']?.toString() ?? '', source: obj['source']?.toString(), line: (obj['line'] as num?)?.toInt());
        } catch (_) {}
      });
      if (_disposed) {
        _msgSub?.cancel();
        _msgSub = null;
        return;
      }
      _ready = true;
      if (mounted) setState(() {});
    } else {
      if (_disposed) return;
      final c = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..addJavaScriptChannel('Console', onMessageReceived: (m) {
          try {
            final obj = json.decode(m.message) as Map<String, dynamic>;
            _pushConsole(level: (obj['level']?.toString() ?? 'log').toUpperCase(), message: obj['message']?.toString() ?? '', source: obj['source']?.toString(), line: (obj['line'] as num?)?.toInt());
          } catch (_) {
            _pushConsole(level: 'LOG', message: m.message);
          }
        });
      _flutterCtrl = c;
      _ready = true;
      if (mounted) setState(() {});
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loadWithTheme();
  }

  String _wrapWithTheme(String input, {required bool isDark}) {
    final hasHtmlTag = input.toLowerCase().contains('<html');
    final hasBodyTag = input.toLowerCase().contains('<body');
    if (hasHtmlTag && hasBodyTag) return input;
    final bg = isDark ? '#111111' : '#ffffff';
    final fg = isDark ? '#eaeaea' : '#222222';
    return '''<!doctype html><html><head><meta charset="utf-8"/><meta name="viewport" content="width=device-width, initial-scale=1"/><style>html,body{background:${bg};color:${fg};margin:0;padding:0}.container{padding:12px}img,video,canvas,iframe{max-width:100%;height:auto}pre,code{font-family:ui-monospace, SFMono-Regular, Menlo, Consolas, \"Liberation Mono\", monospace;}</style></head><body><div class="container">${input}</div></body></html>''';
  }

  Future<String> _writeTempFile(String content, String extension) async {
    final dir = await getTemporaryDirectory();
    final file = io.File('${dir.path}/preview_${DateTime.now().millisecondsSinceEpoch}$extension');
    await file.writeAsString(content, flush: true);
    return file.path;
  }

  void _openInBrowser() {
    final ext = widget.isXml ? '.xml' : '.html';
    _writeTempFile(widget.html, ext).then((path) async {
      if (!mounted) return;
      final ok = await launchUrl(Uri.file(path), mode: LaunchMode.externalApplication);
      if (!ok && mounted) {
        showAppSnackBar(context,
            message: AppLocalizations.of(context)!.webView2NotAvailableMessage,
            type: NotificationType.error);
      }
    });
  }

  void _openWebView2Download() {
    launchUrl(Uri.parse('https://developer.microsoft.com/microsoft-edge/webview2/'),
        mode: LaunchMode.externalApplication);
  }

  Future<void> _loadWithTheme() async {
    if (!_ready) return;
    if (widget.isXml) {
      // Native XML document view: no theme dependence, load once.
      if (_xmlLoaded) return;
      final path = await _writeTempFile(widget.html, '.xml');
      _tempFilePath = path;
      if (Platform.isWindows) {
        await _winCtrl?.loadUrl(Uri.file(path).toString());
      } else {
        await _flutterCtrl?.loadFile(path);
      }
      _xmlLoaded = true;
      if (mounted) setState(() {});
      return;
    }
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (_loadedOnce && _lastDark == isDark) return; // no change
    _lastDark = isDark;
    final html = _wrapWithTheme(widget.html, isDark: isDark);
    if (Platform.isWindows) {
      final path = await _writeTempFile(html, '.html');
      _tempFilePath = path;
      await _winCtrl?.loadUrl(Uri.file(path).toString());
    } else {
      await _flutterCtrl?.loadHtmlString(html);
    }
    _loadedOnce = true;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    // Keep content updated with theme changes
    WidgetsBinding.instance.addPostFrameCallback((_) { _loadWithTheme(); });
    return Dialog(
      elevation: 12,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 520, maxWidth: 900, maxHeight: 740),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Material(
            color: cs.surface,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                  child: Row(
                    children: [
                      // Left title
                      Text(l10n.assistantEditPreviewTitle, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                      const Spacer(),
                      // Right function buttons
                      IosIconButton(
                        icon: Lucide.Terminal,
                        size: 18,
                        minSize: 34,
                        semanticLabel: l10n.messageWebViewConsoleLogs,
                        onTap: _openConsoleDialog,
                      ),
                      const SizedBox(width: 4),
                      // Far right: close
                      IosIconButton(
                        icon: Lucide.X,
                        size: 18,
                        minSize: 34,
                        semanticLabel: l10n.mcpPageClose,
                        onTap: () => Navigator.of(context).maybePop(),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Builder(
                        builder: (context) {
                          if (_initError != null) {
                            return Center(
                              child: Padding(
                                padding: const EdgeInsets.all(24),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.warning_amber_rounded, size: 36, color: cs.error),
                                    const SizedBox(height: 12),
                                    Text(l10n.webView2NotAvailableTitle,
                                        style: Theme.of(context).textTheme.titleMedium),
                                    const SizedBox(height: 8),
                                    Text(l10n.webView2NotAvailableMessage,
                                        textAlign: TextAlign.center,
                                        style: Theme.of(context).textTheme.bodyMedium),
                                    const SizedBox(height: 16),
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 8,
                                      alignment: WrapAlignment.center,
                                      children: [
                                        FilledButton.icon(
                                          onPressed: _openWebView2Download,
                                          icon: const Icon(Icons.download, size: 18),
                                          label: Text(l10n.webView2InstallAction),
                                        ),
                                        OutlinedButton.icon(
                                          onPressed: _openInBrowser,
                                          icon: const Icon(Icons.open_in_new, size: 18),
                                          label: Text(l10n.messageWebViewOpenInBrowser),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            );
                          }
                          if (Platform.isWindows) {
                            final c = _winCtrl;
                            if (c == null) return const SizedBox.shrink();
                            return winweb.Webview(c);
                          }
                          final c = _flutterCtrl;
                          if (c == null) return const SizedBox.shrink();
                          return WebViewWidget(controller: c);
                        },
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    // Mark disposed FIRST so that any in-flight _init() continuation, after
    // its next await, observes the flag and exits without touching COM.
    _disposed = true;
    try { _msgSub?.cancel(); } catch (_) {}
    // Only synchronously dispose the native controller when initialize() has
    // already completed. Disposing while initialize() is still pending races
    // the COM heap (source of 0xc0000374 ntdll crashes traced in v1.5.29).
    // If init is still in flight, leave native cleanup to Dart GC.
    if (_initialized && _winCtrl != null) {
      try { _winCtrl!.dispose(); } catch (_) {}
    }
    super.dispose();
  }
}

extension _ConsoleDialogExt on _HtmlPreviewDialogState {
  void _openConsoleDialog() {
    final l10n = AppLocalizations.of(context)!;
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black.withOpacity(0.25),
      barrierLabel: 'console-logs',
      pageBuilder: (ctx, _, __) => _ConsoleDialog(title: l10n.messageWebViewConsoleLogs, messages: List<_ConsoleMessage>.from(_console)),
      transitionBuilder: (ctx, anim, _, child) {
        final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
        return FadeTransition(opacity: curved, child: ScaleTransition(scale: Tween<double>(begin: 0.98, end: 1).animate(curved), child: child));
      },
    );
  }
}

class _ConsoleDialog extends StatelessWidget {
  const _ConsoleDialog({required this.title, required this.messages});
  final String title;
  final List<_ConsoleMessage> messages;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Dialog(
      elevation: 12,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 520, maxWidth: 700, maxHeight: 620),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Material(
            color: cs.surface,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                  child: Row(
                    children: [
                      Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                      const Spacer(),
                      IosIconButton(
                        icon: Lucide.X,
                        size: 18,
                        minSize: 34,
                        semanticLabel: AppLocalizations.of(context)!.mcpPageClose,
                        onTap: () => Navigator.of(context).maybePop(),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Builder(builder: (context) {
                      final listView = ListView.builder(
                        itemCount: messages.length,
                        itemBuilder: (ctx, i) {
                          final m = messages[i];
                          Color c;
                          switch (m.level) {
                            case 'ERROR': c = cs.error; break;
                            case 'WARN':
                            case 'WARNING': c = cs.secondary; break;
                            default: c = cs.onSurface; break;
                          }
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Text(
                              '${m.level}: ${m.message}\nSource: ${m.source ?? ''}${m.line != null ? ':${m.line}' : ''}',
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: c, fontFamily: 'monospace'),
                            ),
                          );
                        },
                      );
                      return defaultTargetPlatform == TargetPlatform.windows
                          ? listView
                          : SelectionArea(child: listView);
                    }),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ConsoleMessage {
  _ConsoleMessage({required this.level, required this.message, this.source, this.line});
  final String level;
  final String message;
  final String? source;
  final int? line;
}

extension on _HtmlPreviewDialogState {
  void _pushConsole({required String level, required String message, String? source, int? line}) {
    if (!mounted) return;
    setState(() {
      _console.add(_ConsoleMessage(level: level, message: message, source: source, line: line));
      if (_console.length > 128) {
        _console.removeRange(0, _console.length - 128);
      }
    });
  }
}

// (Bottom sheet version removed; desktop uses custom dialog.)
