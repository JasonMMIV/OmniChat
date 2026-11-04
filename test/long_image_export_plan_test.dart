import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/shared/widgets/long_image_exporter.dart';

void main() {
  test('short content keeps the requested ratio and uses one tile', () {
    final plan = LongImageTilePlan.fromContent(
      width: 480,
      height: 1000,
      requestedPixelRatio: 3,
      maxPixels: 40000000,
    );

    expect(plan.effectivePixelRatio, 3);
    expect(plan.capturePixelRatio, 3);
    expect(plan.widthPx, 1440);
    expect(plan.heightPx, 3000);
    expect(plan.tileCount, 1);
  });

  test('long content clamps the ratio to the pixel budget', () {
    final plan = LongImageTilePlan.fromContent(
      width: 480,
      height: 40000,
      requestedPixelRatio: 3,
      maxPixels: 40000000,
    );

    expect(plan.effectivePixelRatio, lessThan(3));
    expect(plan.effectivePixelRatio, greaterThanOrEqualTo(1));
    expect(plan.widthPx * plan.heightPx, lessThanOrEqualTo(40000000));
    expect(plan.tileCount, greaterThan(1));
  });

  test('throws when even 1x exceeds the pixel budget', () {
    expect(
      () => LongImageTilePlan.fromContent(
        width: 1000,
        height: 100000,
        requestedPixelRatio: 3,
        maxPixels: 40000000,
      ),
      throwsA(isA<LongImageTooLargeException>()),
    );
  });

  test('tile count covers the full logical height', () {
    final plan = LongImageTilePlan.fromContent(
      width: 480,
      height: 40000,
      requestedPixelRatio: 3,
      maxPixels: 120000000,
    );

    final expectedTileHeight = LongImageTilePlan.maxTilePx /
        plan.effectivePixelRatio;
    expect(plan.tileLogicalHeight, expectedTileHeight);
    expect(plan.tileCount, (40000 / expectedTileHeight).ceil());
    expect(plan.capturePixelRatio, plan.effectivePixelRatio);
  });

  test('capture ratio follows the clamped effective ratio', () {
    final plan = LongImageTilePlan.fromContent(
      width: 480,
      height: 40000,
      requestedPixelRatio: 3,
      maxPixels: 40000000,
    );

    expect(plan.effectivePixelRatio, lessThan(3));
    expect(plan.capturePixelRatio, plan.effectivePixelRatio);
    expect(
      plan.tileLogicalHeight,
      LongImageTilePlan.maxTilePx / plan.effectivePixelRatio,
    );
  });

  test('tile destination rects are contiguous (no seams)', () {
    const contentHeight = 40000.0;
    final plan = LongImageTilePlan.fromContent(
      width: 480,
      height: contentHeight,
      requestedPixelRatio: 3,
      maxPixels: 80000000,
    );
    final maxScroll = math.max(0.0, contentHeight - plan.tileLogicalHeight);

    var previousBottom = 0;
    for (var i = 0; i < plan.tileCount; i++) {
      final tileStart = i * plan.tileLogicalHeight;
      final scroll = math.min(tileStart, maxScroll);
      final rects = plan.tileRectsFor(
        index: i,
        contentHeight: contentHeight,
        scrollOffset: scroll,
      );

      expect(rects.destTop, previousBottom, reason: 'seam before tile $i');
      previousBottom = rects.destTop + rects.destHeight;
    }

    expect(previousBottom, closeTo(plan.heightPx, 1));
  });

  test('preview size caps the long edge and skips small images', () {
    final tall = LongImageExporter.previewSizeFor(width: 1440, height: 24000);
    expect(tall, isNotNull);
    expect(tall!.width, greaterThanOrEqualTo(600));
    expect(tall.width, lessThanOrEqualTo(1080));
    expect(tall.width * tall.height, lessThanOrEqualTo(8000000));
    expect(tall.height, greaterThan(4096));

    final small = LongImageExporter.previewSizeFor(width: 800, height: 2000);
    expect(small, isNull);
  });

  test('rejects invalid dimensions', () {
    expect(
      () => LongImageTilePlan.fromContent(
        width: 0,
        height: 100,
        requestedPixelRatio: 2,
        maxPixels: 1000000,
      ),
      throwsArgumentError,
    );
  });
}
