import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/icons/lucide_adapter.dart';
import 'package:OmniChat/l10n/app_localizations.dart';
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

const _tableMd = '| Name | Age |\n| --- | --- |\n| Alice | 30 |\n| Bob | 25 |';

/// Touch devices have no hover: a tap reveals the actions for a few seconds.
Future<void> _revealActionsByTap(WidgetTester tester) async {
  await tester.tapAt(tester.getCenter(find.byType(Table)));
  await tester.pump();
}

double _tableActionsOpacity(WidgetTester tester) {
  final opacity = tester.widget<AnimatedOpacity>(
    find.descendant(
      of: find.byKey(const ValueKey('markdown-table-actions')),
      matching: find.byType(AnimatedOpacity),
    ),
  );
  return opacity.opacity;
}

/// Installs an in-memory clipboard so [Clipboard.setData]/[Clipboard.getData]
/// resolve immediately in the test environment (the platform channel has no
/// host implementation under flutter test and would otherwise hang).
void _mockClipboard(WidgetTester tester) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        _copied = (call.arguments as Map)['text'] as String?;
        return null;
      }
      if (call.method == 'Clipboard.getData') {
        return <String, dynamic>{'text': _copied};
      }
      return null;
    },
  );
}

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('renders download and copy actions below the table without a top bar', (tester) async {
    final sp = await _loadedProvider();
    await _pumpMd(tester, sp, _tableMd);

    // Toolbar label is removed (empty).
    expect(find.text('Table'), findsNothing);
    // Copy and download actions (icon-only; localized labels in tooltips).
    expect(find.byIcon(Lucide.Copy), findsOneWidget);
    expect(find.byIcon(Lucide.Download), findsOneWidget);

    // Verify actions are placed below the Table
    final tableBottom = tester.getBottomLeft(find.byType(Table)).dy;
    final copyTop = tester.getTopLeft(find.byIcon(Lucide.Copy)).dy;
    final downloadTop = tester.getTopLeft(find.byIcon(Lucide.Download)).dy;
    expect(copyTop, greaterThanOrEqualTo(tableBottom));
    expect(downloadTop, greaterThanOrEqualTo(tableBottom));
  });

  testWidgets('table actions stay hidden until the pointer hovers the table', (tester) async {
    final sp = await _loadedProvider();
    await _pumpMd(tester, sp, _tableMd);

    expect(_tableActionsOpacity(tester), 0);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: const Offset(1, 1));
    addTearDown(gesture.removePointer);
    await tester.pump();

    await gesture.moveTo(tester.getCenter(find.byType(Table)));
    await tester.pumpAndSettle();
    expect(_tableActionsOpacity(tester), 1);

    await gesture.moveTo(const Offset(795, 595));
    await tester.pumpAndSettle();
    expect(_tableActionsOpacity(tester), 0);
  });

  testWidgets('table actions reveal on touch tap and hide again after a delay', (tester) async {
    final sp = await _loadedProvider();
    await _pumpMd(tester, sp, _tableMd);

    expect(_tableActionsOpacity(tester), 0);

    await _revealActionsByTap(tester);
    expect(_tableActionsOpacity(tester), 1);

    await tester.pump(const Duration(seconds: 4));
    expect(_tableActionsOpacity(tester), 0);
  });

  testWidgets('copy button writes the rebuilt markdown table to the clipboard', (tester) async {
    _mockClipboard(tester);
    final sp = await _loadedProvider();
    await _pumpMd(tester, sp, _tableMd);

    await _revealActionsByTap(tester);
    await tester.tap(find.byIcon(Lucide.Copy));
    // Let the snackbar enter/exit animations finish before the test ends:
    // settle the entrance, fire the 3s auto-dismiss timer, then settle the exit.
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();

    expect(_copied, '| Name | Age |\n| --- | --- |\n| Alice | 30 |\n| Bob | 25 |');
  });

  testWidgets('a table with math in cells still rebuilds cleanly', (tester) async {
    _mockClipboard(tester);
    final sp = await _loadedProvider();
    await _pumpMd(tester, sp, '| X | Y |\n| --- | --- |\n| \$P(A|B)\$ | \$|x|\$ |');

    await _revealActionsByTap(tester);
    await tester.tap(find.byIcon(Lucide.Copy));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();

    // Pipes inside math are protected by EscapeAwareTableMd (no cell split);
    // the rebuilt markdown escapes them again so re-rendering still works.
    expect(_copied, '| X | Y |\n| --- | --- |\n| \$P(A\\|B)\$ | \$\\|x\\|\$ |');
  });

  testWidgets('table action buttons paint ink on a local transparent Material', (tester) async {
    final sp = await _loadedProvider();
    await _pumpMd(tester, sp, _tableMd);

    // Regression: the actions sit below the table; InkWell hover/splash
    // overlays only render when a Material ancestor sits right above them.
    // Without it the overlay is painted on a distant Material and hidden
    // behind the surrounding backgrounds (no hover effect on Windows).
    for (final icon in const [Lucide.Copy, Lucide.Download]) {
      final element = tester.element(find.byIcon(icon));
      Material? nearest;
      element.visitAncestorElements((ancestor) {
        final widget = ancestor.widget;
        if (widget is Material) {
          nearest = widget;
          return false;
        }
        return true;
      });
      expect(nearest, isNotNull, reason: 'No Material ancestor for "$icon"');
      expect(
        nearest!.type,
        MaterialType.transparency,
        reason: 'Ink overlay for "$icon" must paint on the local surface',
      );
    }
  });

  testWidgets('table header tint follows the theme primary color', (tester) async {
    final sp = await _loadedProvider();
    const cs = ColorScheme.light(primary: Color(0xFF7C4DFF), surface: Colors.white, onSurface: Colors.black);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: sp,
        child: MaterialApp(
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          theme: ThemeData(colorScheme: cs),
          home: Scaffold(body: MarkdownWithCodeHighlight(text: _tableMd)),
        ),
      ),
    );
    await tester.pump();

    final table = tester.widget<Table>(find.byType(Table).first);
    final headerBg = (table.children.first.decoration as BoxDecoration?)?.color;
    // The header is a translucent theme-primary wash over the surface.
    expect(headerBg, Color.alphaBlend(cs.primary.withOpacity(0.08), cs.surface));
  });
}

String? _copied;
