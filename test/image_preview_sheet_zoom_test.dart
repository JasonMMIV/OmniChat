import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:OmniChat/features/chat/widgets/image_preview_sheet.dart';
import 'package:OmniChat/l10n/app_localizations.dart';

/// A tall image so the preview lays out a scrollable/pannable canvas.
final List<int> _tallPng = img.encodePng(img.Image(width: 100, height: 2000));

void main() {
  late Directory tempDir;
  late File imageFile;

  setUpAll(() {
    tempDir = Directory.systemTemp.createTempSync('omnichat_image_preview_');
    imageFile = File('${tempDir.path}${Platform.pathSeparator}preview.png')
      ..writeAsBytesSync(_tallPng);
  });

  tearDownAll(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  testWidgets('mobile image preview supports pinch to zoom', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;

    await tester.pumpWidget(
      MaterialApp(
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                key: const ValueKey('open-preview'),
                onPressed: () =>
                    showImagePreviewSheet(context, file: imageFile),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    // Decode the image so the preview lays out its real aspect ratio instead
    // of collapsing to zero height in the test environment.
    await tester.runAsync(() async {
      await precacheImage(
        FileImage(imageFile),
        tester.element(find.byType(ElevatedButton)),
      );
    });
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('open-preview')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // The mobile sheet is now mounted; restore the debug override before the
    // test body ends so the test binding's invariant check passes.
    debugDefaultTargetPlatformOverride = null;

    final viewerFinder = find.byType(InteractiveViewer);
    expect(viewerFinder, findsOneWidget);
    final controller = tester
        .widget<InteractiveViewer>(viewerFinder)
        .transformationController!;
    expect(controller.value.getMaxScaleOnAxis(), 1.0);

    final center = tester.getCenter(viewerFinder);
    final finger1 = await tester.startGesture(center - const Offset(20, 0));
    final finger2 = await tester.startGesture(center + const Offset(20, 0));
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await finger1.moveBy(const Offset(-10, 0));
      await finger2.moveBy(const Offset(10, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await finger1.up();
    await finger2.up();
    await tester.pump(const Duration(milliseconds: 100));

    expect(controller.value.getMaxScaleOnAxis(), greaterThan(1.0));

    // At 1x a tall image must still be pannable, replacing the old
    // SingleChildScrollView behavior.
    controller.value = Matrix4.identity();
    await tester.pump();
    await tester.drag(viewerFinder, const Offset(0, -200));
    await tester.pump(const Duration(milliseconds: 100));
    expect(controller.value.storage[13], lessThan(0));

    final handleFinder = find.byKey(const ValueKey('image-preview-sheet-handle'));

    // The sheet route no longer handles drag-to-dismiss directly, so the
    // handle must still move the sheet and eventually dismiss it.
    final handleTopBeforeDrag = tester.getRect(handleFinder).top;
    final handleGesture = await tester.startGesture(
      tester.getCenter(handleFinder),
    );
    for (var i = 0; i < 5; i++) {
      await handleGesture.moveBy(const Offset(0, 40));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(
      tester.getRect(handleFinder).top,
      greaterThan(handleTopBeforeDrag + 100),
    );
    for (var i = 0; i < 4; i++) {
      await handleGesture.moveBy(const Offset(0, 50));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await handleGesture.up();
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsNothing);
  });
}
