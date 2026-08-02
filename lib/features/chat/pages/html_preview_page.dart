import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../../../l10n/app_localizations.dart';

class HtmlPreviewPage extends StatefulWidget {
  const HtmlPreviewPage({super.key, required this.html, this.isXml = false});
  final String html;
  // When true, the content is XML/SVG and is loaded as a standalone XML
  // document so the browser renders its native collapsible tree (or the SVG
  // graphic). HTML wrapping/theme injection is skipped for XML.
  final bool isXml;

  @override
  State<HtmlPreviewPage> createState() => _HtmlPreviewPageState();
}

class _HtmlPreviewPageState extends State<HtmlPreviewPage> {
  late final WebViewController _controller;
  bool _didInit = false;
  bool _xmlLoaded = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted);
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
    if (widget.isXml) {
      // Native XML document view: no theme dependence, load once.
      if (_xmlLoaded) return;
      final dir = await getTemporaryDirectory();
      final file = File(
        '${dir.path}/xml_preview_${DateTime.now().millisecondsSinceEpoch}.xml',
      );
      await file.writeAsString(widget.html, flush: true);
      // Android's implementation of loadFile enables allowFileAccess itself.
      await _controller.loadFile(file.path);
      _xmlLoaded = true;
      return;
    }
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final html = _wrapIfNeeded(widget.html, isDark: isDark);
    await _controller.loadHtmlString(html);
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
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.assistantEditPreviewTitle),
      ),
      body: SafeArea(
        child: WebViewWidget(controller: _controller),
      ),
    );
  }
}
