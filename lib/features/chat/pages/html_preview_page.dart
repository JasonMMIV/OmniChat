import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../utils/markdown_preview_assets.dart';

class HtmlPreviewPage extends StatefulWidget {
  const HtmlPreviewPage({super.key, required this.html, this.isXml = false, required this.isMarkdown});
  final String html;
  // When true, the content is XML/SVG and is loaded as a standalone XML
  // document so the browser renders its native collapsible tree (or the SVG
  // graphic). HTML wrapping/theme injection is skipped for XML.
  final bool isXml;

  /// Markdown HTML needs the extracted `vendor/` siblings; raw workspace
  /// HTML/SVG deliberately uses an isolated temp directory instead.
  final bool isMarkdown;

  @override
  State<HtmlPreviewPage> createState() => _HtmlPreviewPageState();
}

class _HtmlPreviewPageState extends State<HtmlPreviewPage> {
  late final WebViewController _controller;
  bool _didInit = false;
  bool _xmlLoaded = false;
  File? _htmlFile;
  File? _xmlFile;
  int _loadGeneration = 0;
  Timer? _loadTimeout;
  bool _loading = true;
  bool _timedOut = false;
  bool _loadFailed = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) => _onPageFinished(),
          onWebResourceError: (error) {
            if (error.isForMainFrame == true) _onLoadFailed();
          },
        ),
      );
  }

  /// Mutates loading state without setState. Callers are either in
  /// didChangeDependencies (an immediate build follows) or the retry button
  /// (which schedules its own setState first).
  void _startLoading() {
    _loadTimeout?.cancel();
    _loading = true;
    _timedOut = false;
    _loadFailed = false;
    _loadTimeout = Timer(const Duration(seconds: 10), () {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _timedOut = true;
        _loadFailed = false;
      });
    });
  }

  void _onPageFinished() {
    // A straggler page-finished event (including the browser's error page)
    // must not hide the timeout/failure retry UI.
    if (_timedOut || _loadFailed) return;
    _loadTimeout?.cancel();
    _loadTimeout = null;
    if (!mounted || (!_loading && !_loadFailed)) return;
    setState(() {
      _loading = false;
      _loadFailed = false;
    });
  }

  void _onLoadFailed() {
    // Keep the first terminal state if the timeout already fired.
    if (_timedOut) return;
    _loadTimeout?.cancel();
    _loadTimeout = null;
    if (!mounted) return;
    setState(() {
      _loading = false;
      _timedOut = false;
      _loadFailed = true;
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Safe place to access Theme.of(context)
    if (!_didInit) {
      _didInit = true;
      _loadHtml();
    } else {
      // Reload on theme changes (HTML only; XML is theme-independent)
      _loadHtml();
    }
  }

  Future<void> _loadHtml() async {
    final generation = ++_loadGeneration;
    if (widget.isXml) {
      // Native XML document view: no theme dependence, load once.
      if (_xmlLoaded) return;
      _startLoading();
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/xml_preview_${DateTime.now().microsecondsSinceEpoch}.xml');
      await file.writeAsString(widget.html, flush: true);
      if (!mounted || generation != _loadGeneration) {
        try {
          await file.delete();
        } catch (_) {}
        return;
      }
      _xmlFile = file;
      // Android's implementation of loadFile enables allowFileAccess itself.
      await _controller.loadFile(file.path);
      _xmlLoaded = true;
      return;
    }
    _startLoading();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final html = _wrapIfNeeded(widget.html, isDark: isDark);
    // Only Markdown-generated HTML needs vendor/ siblings. Raw workspace
    // HTML/SVG stays in a separate temp dir so it cannot read preview files.
    final file = widget.isMarkdown
        ? await MarkdownPreviewAssets.instance.writeHtml(html)
        : await MarkdownPreviewAssets.instance.writeStandaloneHtml(html);
    if (!mounted || generation != _loadGeneration) {
      await MarkdownPreviewAssets.instance.deleteHtml(file);
      return;
    }
    final previous = _htmlFile;
    _htmlFile = file;
    await _controller.loadFile(file.path);
    if (generation == _loadGeneration) {
      await MarkdownPreviewAssets.instance.deleteHtml(previous);
    }
  }

  @override
  void dispose() {
    _loadGeneration++;
    _loadTimeout?.cancel();
    unawaited(MarkdownPreviewAssets.instance.deleteHtml(_htmlFile));
    final xmlFile = _xmlFile;
    if (xmlFile != null) {
      try {
        if (xmlFile.existsSync()) xmlFile.deleteSync();
      } catch (_) {}
    }
    super.dispose();
  }

  String _wrapIfNeeded(String input, {required bool isDark}) {
    final hasHtmlTag = input.toLowerCase().contains('<html');
    final hasBodyTag = input.toLowerCase().contains('<body');
    if (hasHtmlTag && hasBodyTag) return input;
    final bg = isDark ? '#111111' : '#ffffff';
    final fg = isDark ? '#eaeaea' : '#222222';
    return '''<!doctype html>
<html>
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <style>
      html, body { background: ${bg}; color: ${fg}; margin: 0; padding: 0; }
      .container { padding: 12px; }
      img, video, canvas, iframe { max-width: 100%; height: auto; }
      pre, code { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, "Liberation Mono", monospace; }
    </style>
  </head>
  <body>
    <div class="container">
      ${input}
    </div>
  </body>
</html>''';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.assistantEditPreviewTitle)),
      body: SafeArea(
        child: Stack(
          children: [
            WebViewWidget(controller: _controller),
            if (_loading) const Align(alignment: Alignment.topCenter, child: LinearProgressIndicator(minHeight: 2)),
            if (_timedOut || _loadFailed)
              Positioned.fill(
                child: Stack(
                  children: [
                    ModalBarrier(dismissible: false, color: cs.surface.withValues(alpha: 0.94)),
                    Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(_timedOut ? Icons.timer_off_outlined : Icons.error_outline, size: 32, color: cs.error),
                          const SizedBox(height: 10),
                          Text(
                            _timedOut ? l10n.htmlPreviewLoadTimeout : l10n.htmlPreviewLoadFailed,
                            textAlign: TextAlign.center,
                            style: TextStyle(color: cs.onSurface),
                          ),
                          const SizedBox(height: 8),
                          TextButton.icon(
                            onPressed: () {
                              if (widget.isXml) _xmlLoaded = false;
                              setState(() {
                                _loading = true;
                                _timedOut = false;
                                _loadFailed = false;
                              });
                              _loadHtml();
                            },
                            icon: const Icon(Icons.refresh, size: 18),
                            label: Text(l10n.htmlPreviewRetry),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
