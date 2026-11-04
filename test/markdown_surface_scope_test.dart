import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/l10n/app_localizations.dart';
import 'package:OmniChat/shared/markdown/markdown_surface_scope.dart';
import 'package:OmniChat/shared/widgets/markdown_with_highlight.dart';

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

bool _spanUsesColor(InlineSpan span, Color color) {
  if (span is! TextSpan) return false;
  if (span.style?.color == color) return true;
  for (final child in span.children ?? const <InlineSpan>[]) {
    if (_spanUsesColor(child, color)) return true;
  }
  return false;
}

bool _spanHasShadows(InlineSpan span) {
  if (span is! TextSpan) return false;
  final shadows = span.style?.shadows;
  if (shadows != null && shadows.isNotEmpty) return true;
  for (final child in span.children ?? const <InlineSpan>[]) {
    if (_spanHasShadows(child)) return true;
  }
  return false;
}

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  test('MarkdownSurface defaults, shadows and equality', () {
    const cs = ColorScheme.light();
    final surface = MarkdownSurface.fromColorScheme(cs);

    expect(surface.surface, cs.surface);
    expect(surface.onSurface, cs.onSurface);
    expect(surface.onSurfaceVariant, cs.onSurfaceVariant);
    expect(surface.isTranslucent, isFalse);
    expect(surface.hasWallpaper, isFalse);
    expect(surface.bodyTextShadows, isEmpty);

    expect(surface.copyWith(isTranslucent: true).bodyTextShadows, isNotEmpty);
    expect(
      const MarkdownSurface(
        surface: Colors.white,
        onSurface: Colors.black,
        onSurfaceVariant: Colors.grey,
        hasWallpaper: true,
      ).bodyTextShadows,
      isNotEmpty,
    );

    expect(surface, MarkdownSurface.fromColorScheme(cs));
    expect(
      surface == surface.copyWith(isTranslucent: true),
      isFalse,
    );
  });

  testWidgets('scoped ink and subtle shadow reach markdown body text',
      (tester) async {
    final sp = await _loadedProvider();
    const onSurface = Color(0xFF123456);
    const surface = MarkdownSurface(
      surface: Color(0xFFFAFAFA),
      onSurface: onSurface,
      onSurfaceVariant: Color(0xFF666666),
      isTranslucent: true,
    );

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: sp,
        child: MaterialApp(
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: MarkdownSurfaceScope(
            surface: surface,
            child: const Scaffold(
              body: MarkdownWithCodeHighlight(text: 'Hello surface scope'),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final richTexts = tester.widgetList<RichText>(find.byType(RichText));
    final matching = richTexts
        .where((r) => r.text.toPlainText().contains('Hello surface scope'))
        .toList();
    expect(matching, isNotEmpty);

    expect(
      matching.any((r) => _spanUsesColor(r.text, onSurface)),
      isTrue,
      reason: 'Markdown body text must use the scoped paired ink.',
    );
    expect(
      matching.any((r) => _spanHasShadows(r.text)),
      isTrue,
      reason: 'Translucent surfaces must add the subtle body-text shadow.',
    );
  });
}
