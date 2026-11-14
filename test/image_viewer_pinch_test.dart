import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:OmniChat/features/chat/pages/image_viewer_page.dart';
import 'package:OmniChat/l10n/app_localizations.dart';

/// Regression tests for the image viewer opened from a markdown image link.
///
/// Pinch-to-zoom used to fail whenever the first finger moved far enough, in
/// any direction, for the page's vertical-drag dismiss recognizer to claim it
/// before the second finger landed: the scale recognizer then never saw that
/// pointer and the pinch was ignored. Dismissal now rides on the
/// InteractiveViewer's scale gesture, so all pointers stay on one recognizer.
Uint8List _png(int width, int height) =>
    img.encodePng(img.Image(width: width, height: height));

Widget _app(List<String> sources) {
  return MaterialApp(
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            key: const ValueKey('open'),
            onPressed: () => Navigator.of(context).push(
              PageRouteBuilder(
                pageBuilder: (_, __, ___) => ImageViewerPage(images: sources),
                transitionDuration: const Duration(milliseconds: 360),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
}

Future<TransformationController> _open(
  WidgetTester tester,
  List<String> sources,
) async {
  await tester.pumpWidget(_app(sources));
  await tester.tap(find.byKey(const ValueKey('open')));
  await tester.pumpAndSettle();
  final finder = find.byType(InteractiveViewer);
  expect(finder, findsOneWidget);
  return tester.widget<InteractiveViewer>(finder).transformationController!;
}

Future<void> _pinch(
  WidgetTester tester, {
  required Offset center,
  required Offset deltaA,
  required Offset deltaB,
  int steps = 10,
}) async {
  final f1 = await tester.startGesture(center - const Offset(20, 0));
  final f2 = await tester.startGesture(center + const Offset(20, 0));
  await tester.pump();
  for (var i = 0; i < steps; i++) {
    await f1.moveBy(deltaA);
    await f2.moveBy(deltaB);
    await tester.pump(const Duration(milliseconds: 16));
  }
  await f1.up();
  await f2.up();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  final source =
      'data:image/png;base64,${base64Encode(_png(400, 800))}';

  testWidgets('symmetric pinch zooms the markdown image viewer',
      (tester) async {
    final ctrl = await _open(tester, [source]);
    final center = tester.getCenter(find.byType(InteractiveViewer));

    await _pinch(
      tester,
      center: center,
      deltaA: const Offset(-10, 0),
      deltaB: const Offset(10, 0),
    );

    expect(ctrl.value.getMaxScaleOnAxis(), greaterThan(1.0));
  });

  testWidgets('pinch zooms after the first finger pans vertically',
      (tester) async {
    final ctrl = await _open(tester, [source]);
    final center = tester.getCenter(find.byType(InteractiveViewer));

    final f1 = await tester.startGesture(center - const Offset(0, 20));
    for (var i = 0; i < 3; i++) {
      await f1.moveBy(const Offset(0, -10));
      await tester.pump(const Duration(milliseconds: 16));
    }
    final f2 = await tester.startGesture(center + const Offset(0, 20));
    await tester.pump();
    for (var i = 0; i < 8; i++) {
      await f1.moveBy(const Offset(0, -10));
      await f2.moveBy(const Offset(0, 10));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await f1.up();
    await f2.up();
    await tester.pump(const Duration(milliseconds: 100));

    expect(ctrl.value.getMaxScaleOnAxis(), greaterThan(1.0));
  });

  testWidgets('pinch zooms after the first finger pans horizontally',
      (tester) async {
    final ctrl = await _open(tester, [source]);
    final center = tester.getCenter(find.byType(InteractiveViewer));

    final f1 = await tester.startGesture(center - const Offset(20, 0));
    for (var i = 0; i < 3; i++) {
      await f1.moveBy(const Offset(-10, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    final f2 = await tester.startGesture(center + const Offset(20, 0));
    await tester.pump();
    for (var i = 0; i < 8; i++) {
      await f1.moveBy(const Offset(-10, 0));
      await f2.moveBy(const Offset(10, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await f1.up();
    await f2.up();
    await tester.pump(const Duration(milliseconds: 100));

    expect(ctrl.value.getMaxScaleOnAxis(), greaterThan(1.0));
  });

  testWidgets('one-finger swipe down still dismisses the viewer',
      (tester) async {
    await _open(tester, [source]);
    final center = tester.getCenter(find.byType(InteractiveViewer));

    final gesture = await tester.startGesture(center);
    for (var i = 0; i < 12; i++) {
      await gesture.moveBy(const Offset(0, 20));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.byType(ImageViewerPage), findsNothing);
  });
}
