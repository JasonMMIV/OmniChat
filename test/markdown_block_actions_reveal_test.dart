import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/l10n/app_localizations.dart';
import 'package:OmniChat/shared/widgets/hover_reveal.dart';
import 'package:OmniChat/shared/widgets/markdown_with_highlight.dart';
import 'package:OmniChat/shared/widgets/mermaid_image_cache.dart';

/// 1x1 transparent PNG so the Mermaid bitmap path resolves without a codec
/// error and the block does not schedule another render.
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

Future<void> _pumpMd(
  WidgetTester tester,
  SettingsProvider sp,
  String text,
) async {
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

double _actionsOpacity(WidgetTester tester, String key) {
  final opacity = tester.widget<AnimatedOpacity>(
    find.descendant(
      of: find.byKey(ValueKey(key)),
      matching: find.byType(AnimatedOpacity),
    ),
  );
  return opacity.opacity;
}

/// Moves a synthetic mouse pointer into [target].
Future<TestGesture> _hoverOver(WidgetTester tester, Finder target) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: const Offset(1, 1));
  addTearDown(gesture.removePointer);
  await tester.pump();

  await gesture.moveTo(tester.getCenter(target));
  await tester.pumpAndSettle();
  return gesture;
}

const _codeMd = '```dart\nvoid main() {}\n```';

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
    'code block actions stay hidden until the pointer hovers the block',
    (tester) async {
      final sp = await _loadedProvider();
      await _pumpMd(tester, sp, _codeMd);

      expect(_actionsOpacity(tester, 'code-block-actions'), 0);

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: const Offset(1, 1));
      addTearDown(gesture.removePointer);
      await tester.pump();

      await gesture.moveTo(
        tester.getCenter(find.byType(SelectableHighlightView)),
      );
      await tester.pumpAndSettle();
      expect(_actionsOpacity(tester, 'code-block-actions'), 1);

      await gesture.moveTo(const Offset(795, 595));
      await tester.pumpAndSettle();
      expect(_actionsOpacity(tester, 'code-block-actions'), 0);
    },
  );

  testWidgets(
    'code block actions reveal on touch tap and hide again after a delay',
    (tester) async {
      final sp = await _loadedProvider();
      await _pumpMd(tester, sp, _codeMd);

      expect(_actionsOpacity(tester, 'code-block-actions'), 0);

      // Tapping the code body is the normal gesture on Android. It focuses
      // the selectable text, which must not pin the actions open: only tap
      // reveal and focus inside the action buttons should keep them visible.
      await tester.tap(find.byType(SelectableHighlightView));
      await tester.pump();
      expect(_actionsOpacity(tester, 'code-block-actions'), 1);

      await tester.pump(const Duration(seconds: 4));
      expect(_actionsOpacity(tester, 'code-block-actions'), 0);
    },
  );

  testWidgets(
    'tapping outside the code block hides the actions immediately',
    (tester) async {
      final sp = await _loadedProvider();
      await _pumpMd(tester, sp, _codeMd);

      await tester.tap(find.byType(SelectableHighlightView));
      await tester.pump();
      expect(_actionsOpacity(tester, 'code-block-actions'), 1);

      // Anywhere below the block is outside its TapRegion.
      final block = tester.getRect(find.byType(HoverReveal));
      await tester.tapAt(Offset(block.center.dx, block.bottom + 40));
      await tester.pump();
      expect(_actionsOpacity(tester, 'code-block-actions'), 0);
    },
  );

  testWidgets(
    'mermaid actions stay hidden until the pointer hovers the block',
    (tester) async {
      const code = 'graph TD;\nA-->B;';
      MermaidImageCache.put(code, _png);
      final sp = await _loadedProvider();
      await _pumpMd(tester, sp, '```mermaid\n$code\n```');

      expect(_actionsOpacity(tester, 'mermaid-block-actions'), 0);

      final gesture = await _hoverOver(
        tester,
        find.byKey(const ValueKey('mermaid-preview-body')),
      );
      expect(_actionsOpacity(tester, 'mermaid-block-actions'), 1);

      await gesture.moveTo(const Offset(795, 595));
      await tester.pumpAndSettle();
      expect(_actionsOpacity(tester, 'mermaid-block-actions'), 0);
    },
  );
}
