import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/features/chat/pages/image_viewer_page.dart';
import 'package:OmniChat/l10n/app_localizations.dart';
import 'package:OmniChat/shared/widgets/markdown_with_highlight.dart';
import 'package:OmniChat/shared/widgets/mermaid_image_cache.dart';

/// 1x1 transparent PNG so the bitmap path resolves without a codec error.
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8'
  'z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

Future<SettingsProvider> _loadedProvider() async {
  final sp = SettingsProvider();
  final done = Completer<void>();
  void listener() {
    if (!done.isCompleted) done.complete();
  }

  sp.addListener(listener);
  await done.future.timeout(const Duration(seconds: 10));
  sp.removeListener(listener);
  return sp;
}

Future<void> _pumpMd(WidgetTester tester, SettingsProvider sp, String text) async {
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: sp,
      child: MaterialApp(
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(body: MarkdownWithCodeHighlight(text: text)),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('renders image/code tabs and header actions', (tester) async {
    const code = 'graph TD;\nA-->B;';
    MermaidImageCache.put(code, _png);
    final sp = await _loadedProvider();
    await _pumpMd(tester, sp, '```mermaid\n$code\n```');

    // Tabs (en locale) replace the old 'mermaid' text label.
    expect(find.text('Image'), findsOneWidget);
    expect(find.text('Code'), findsOneWidget);
    // Header actions: copy label + labeled download.
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Download'), findsOneWidget);
    // The bitmap image is the default tab (no live WebView, no browser button).
    expect(find.byKey(const ValueKey('mermaid-preview-body')), findsOneWidget);
    expect(find.text('Open'), findsNothing);
  });

  testWidgets('code tab switches to the source view', (tester) async {
    const code = 'graph TD;\nA-->B;';
    MermaidImageCache.put(code, _png);
    final sp = await _loadedProvider();
    await _pumpMd(tester, sp, '```mermaid\n$code\n```');

    await tester.tap(find.text('Code'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('mermaid-code-body')), findsOneWidget);
    expect(find.textContaining('graph TD'), findsOneWidget);
  });

  testWidgets('tapping the image opens the full-screen viewer', (tester) async {
    const code = 'sequenceDiagram;\nA->>B: hi;';
    MermaidImageCache.put(code, _png);
    final sp = await _loadedProvider();
    await _pumpMd(tester, sp, '```mermaid\n$code\n```');

    await tester.tap(find.byType(Image));
    await tester.pumpAndSettle();

    expect(find.byType(ImageViewerPage), findsOneWidget);
  });

  testWidgets('collapsing hides the preview body', (tester) async {
    const code = 'graph LR;\nA-->B;';
    MermaidImageCache.put(code, _png);
    final sp = await _loadedProvider();
    await _pumpMd(tester, sp, '```mermaid\n$code\n```');

    expect(find.byKey(const ValueKey('mermaid-expanded')), findsOneWidget);

    // Tap the collapse chevron (the single AnimatedRotation in the header).
    await tester.tap(find.byType(AnimatedRotation));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('mermaid-collapsed')), findsOneWidget);
  });
}
