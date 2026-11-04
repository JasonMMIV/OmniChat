import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:OmniChat/utils/markdown_preview_assets.dart';
import 'package:OmniChat/utils/markdown_preview_html.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('mark.html uses local classic vendor scripts, not CDNs', () {
    final html = File('assets/html/mark.html').readAsStringSync();

    expect(html, contains('vendor/markdown-it.min.js'));
    expect(html, contains('vendor/markdown-it-task-lists.min.js'));
    expect(html, contains('vendor/markdown-it-katex.min.js'));
    expect(html, contains('vendor/katex.min.css'));
    expect(html, contains('vendor/highlight.min.js'));
    expect(html, contains('vendor/mermaid.min.js'));
    expect(html, contains('vendor/purify.min.js'));
    expect(html, contains('vendor/base64.min.js'));
    expect(html, isNot(contains('esm.sh')));
    expect(html, isNot(contains('cdn.jsdelivr.net')));
    expect(html, isNot(contains('type="module"')));
    expect(html, contains('{{BASE_HREF}}'));

    // The external-KaTeX plugin resolves window.katex at IIFE evaluation time.
    final katexIndex = html.indexOf('vendor/katex.min.js');
    final pluginIndex = html.indexOf('vendor/markdown-it-katex.min.js');
    expect(katexIndex, greaterThanOrEqualTo(0));
    expect(pluginIndex, greaterThan(katexIndex));

    // A renamed/missing vendor file must fail here, not at runtime in WebView.
    final refs = RegExp(r'(?:src|href)="(vendor/[^"]+)"').allMatches(html).map((m) => m.group(1)!).toSet();
    expect(refs, isNotEmpty);
    for (final ref in refs) {
      final file = ref == 'vendor/mermaid.min.js' ? File('assets/mermaid.min.js') : File('assets/html/$ref');
      expect(file.existsSync(), isTrue, reason: ref);
    }
  });

  testWidgets('builder substitutes the base href and leaves no placeholders', (tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Material(child: SizedBox(key: key)),
      ),
    );
    final context = key.currentContext;
    expect(context, isNotNull);

    final html = await MarkdownPreviewHtmlBuilder.buildFromMarkdown(
      context!,
      '# probe\n\n| a | b |\n| - | - |\n| 1 | 2 |',
    );
    expect(html, contains('<base href="../">'));
    expect(html, isNot(contains(RegExp(r'\{\{[A-Z_]+\}\}'))));
  });

  test('concurrent extraction is deduplicated and the marker is reused', () async {
    final dir = await Directory.systemTemp.createTemp('omnichat_preview_assets_concurrent_');
    addTearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    final assets = MarkdownPreviewAssets.instance;
    final results = await Future.wait(<Future<Directory>>[
      assets.ensureExtracted(cacheDirectory: dir),
      assets.ensureExtracted(cacheDirectory: dir),
    ]);
    expect(results.every((d) => d.path == dir.path), isTrue);

    final marker = File('${dir.path}/.ready');
    expect(await marker.exists(), isTrue);

    // A sentinel survives only if the marker short-circuit really avoided a
    // second extraction (timestamp equality is unreliable on FAT/Android).
    final sentinel = File('${dir.path}/sentinel.txt');
    await sentinel.writeAsString('keep');
    await assets.ensureExtracted(cacheDirectory: dir);
    expect(await sentinel.exists(), isTrue);
  });

  test('vendor bundle extracts once and hosts previews in isolated dirs', () async {
    final dir = await Directory.systemTemp.createTemp('omnichat_preview_assets_');
    addTearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    final assets = MarkdownPreviewAssets.instance;
    final extracted = await assets.ensureExtracted(cacheDirectory: dir);
    expect(extracted.path, dir.path);

    for (final name in <String>[
      'vendor/markdown-it.min.js',
      'vendor/markdown-it-task-lists.min.js',
      'vendor/markdown-it-katex.min.js',
      'vendor/katex.min.js',
      'vendor/katex.min.css',
      'vendor/highlight.min.js',
      'vendor/mermaid.min.js',
      'vendor/purify.min.js',
      'vendor/base64.min.js',
      'vendor/atom-one-dark.min.css',
      'vendor/fonts/KaTeX_Main-Regular.woff2',
    ]) {
      final file = File('${dir.path}/$name');
      expect(await file.exists(), isTrue, reason: name);
      expect(await file.length(), greaterThan(0), reason: name);
    }

    final html = await assets.writeHtml('<html>probe</html>', cacheDirectory: dir);
    expect(await html.exists(), isTrue);
    expect(html.parent.path, isNot(dir.path));
    expect(p.basename(html.parent.path), startsWith('preview_'));
    expect(html.uri.pathSegments.last, 'index.html');
    expect(await html.readAsString(), '<html>probe</html>');

    await assets.deleteHtml(html);
    expect(await html.exists(), isFalse);
    expect(await html.parent.exists(), isFalse);

    final standaloneDir = await Directory.systemTemp.createTemp('omnichat_preview_standalone_');
    addTearDown(() async {
      try {
        await standaloneDir.delete(recursive: true);
      } catch (_) {}
    });
    final standalone = await assets.writeStandaloneHtml('<html>raw</html>', cacheDirectory: standaloneDir);
    expect(standalone.parent.path, isNot(dir.path));
    expect(await standalone.readAsString(), '<html>raw</html>');
    await assets.deleteHtml(standalone);
    expect(await standalone.exists(), isFalse);

    final firstExternal = await assets.writeExternalHtml('<html>one</html>', cacheDirectory: dir);
    await assets.writeExternalHtml('<html>two</html>', cacheDirectory: dir);
    final openDirs = dir
        .listSync()
        .whereType<Directory>()
        .where((d) => p.basename(d.path).startsWith('open_'))
        .toList();
    expect(openDirs, hasLength(1));
    final openFile = File('${openDirs.single.path}/index.html');
    expect(await openFile.readAsString(), '<html>two</html>');
    expect(await firstExternal.exists(), isFalse);
    await assets.deleteHtml(openFile);
    expect(await openFile.exists(), isFalse);
  });
}
