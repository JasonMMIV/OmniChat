import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:path_provider/path_provider.dart';

enum LongImageExportStage { rendering, stitching, encoding }

class LongImageProgress {
  const LongImageProgress({required this.stage, required this.current, required this.total});

  final LongImageExportStage stage;
  final int current;
  final int total;

  double get fraction => total <= 0 ? 0 : (current / total).clamp(0.0, 1.0);
}

typedef LongImageProgressCallback = void Function(LongImageProgress progress);

class LongImageExportResult {
  const LongImageExportResult({
    required this.file,
    this.previewFile,
    this.effectivePixelRatio,
    this.requestedPixelRatio,
  });

  /// Full-resolution PNG for saving/sharing.
  final File file;

  /// Downscaled PNG for fast preview (null when the full image is already
  /// small enough to decode comfortably).
  final File? previewFile;

  /// Ratio actually used after the pixel-budget clamp, when known.
  final double? effectivePixelRatio;

  /// Ratio requested by the export caller, when known.
  final double? requestedPixelRatio;

  bool get wasDownscaled {
    final effective = effectivePixelRatio;
    final requested = requestedPixelRatio;
    return effective != null && requested != null && effective + 0.01 < requested;
  }
}

class LongImageSegmentedExportResult {
  const LongImageSegmentedExportResult({
    required this.files,
    required this.widthPx,
    required this.pageHeightPx,
    required this.totalHeightPx,
  });

  /// One PNG per vertical page, in reading order.
  final List<File> files;
  final int widthPx;
  final int pageHeightPx;
  final int totalHeightPx;

  int get pageCount => files.length;
}

class LongImageTooLargeException implements Exception {
  const LongImageTooLargeException({required this.widthPx, required this.heightPx, required this.maxPixels});

  final int widthPx;
  final int heightPx;
  final int maxPixels;

  String get sizeLabel => '$widthPx×$heightPx';

  @override
  String toString() => 'LongImageTooLargeException($sizeLabel > $maxPixels px)';
}

/// Pure tiling plan for a long-image export.
///
/// Tiles are captured at the requested ratio (max 4096 px on the long edge);
/// if the total would exceed the platform pixel budget, the final image is
/// scaled down to fit (never below 1x). If even 1x exceeds the budget, the
/// export is rejected rather than risking an OOM.
class LongImageTileRects {
  const LongImageTileRects({
    required this.sourceTop,
    required this.sourceHeight,
    required this.destTop,
    required this.destHeight,
  });

  final int sourceTop;
  final int sourceHeight;
  final int destTop;
  final int destHeight;
}

class LongImageTilePlan {
  const LongImageTilePlan({
    required this.widthPx,
    required this.heightPx,
    required this.effectivePixelRatio,
    required this.capturePixelRatio,
    required this.tileLogicalHeight,
    required this.tileCount,
  });

  final int widthPx;
  final int heightPx;

  /// Ratio used for the final image (may be lower than requested).
  final double effectivePixelRatio;

  /// Ratio used when capturing each tile (the effective ratio).
  final double capturePixelRatio;

  final double tileLogicalHeight;
  final int tileCount;

  static const int maxTilePx = 4096;

  factory LongImageTilePlan.fromContent({
    required double width,
    required double height,
    required double requestedPixelRatio,
    required int maxPixels,
  }) {
    if (width <= 0 || height <= 0 || requestedPixelRatio <= 0) {
      throw ArgumentError('Invalid long image size');
    }

    var ratio = requestedPixelRatio;
    final requestedPixels = width * height * requestedPixelRatio * requestedPixelRatio;
    if (requestedPixels > maxPixels) {
      final maxRatio = math.sqrt(maxPixels / (width * height));
      ratio = math.min(requestedPixelRatio, math.max(1.0, maxRatio));
    }

    // Floor both axes: rounding up can push the product just over the budget.
    final widthPx = math.max(1, (width * ratio).floor());
    final heightPx = math.max(1, (height * ratio).floor());
    if (widthPx * heightPx > maxPixels) {
      throw LongImageTooLargeException(widthPx: widthPx, heightPx: heightPx, maxPixels: maxPixels);
    }

    // Capture at the effective ratio: capturing at the requested ratio would
    // make the tile set larger than the final image for clamped long content.
    final tileLogicalHeight = maxTilePx / ratio;
    final tileCount = math.max(1, (height / tileLogicalHeight).ceil());

    return LongImageTilePlan(
      widthPx: widthPx,
      heightPx: heightPx,
      effectivePixelRatio: ratio,
      capturePixelRatio: ratio,
      tileLogicalHeight: tileLogicalHeight,
      tileCount: tileCount,
    );
  }

  /// Absolute source/destination rects for one tile. Destination coordinates
  /// are derived from absolute positions (not cumulative heights) so rounding
  /// cannot introduce 1px seams or overlaps.
  LongImageTileRects tileRectsFor({required int index, required double contentHeight, required double scrollOffset}) {
    final tileStart = index * tileLogicalHeight;
    final withinTop = (tileStart - scrollOffset).clamp(0.0, tileLogicalHeight);
    final remaining = (contentHeight - tileStart).clamp(0.0, tileLogicalHeight);
    final sourceTop = (withinTop * capturePixelRatio).round();
    final sourceHeight = (remaining * capturePixelRatio).round();
    final destTop = (tileStart * effectivePixelRatio).round();
    final destBottom = ((tileStart + remaining) * effectivePixelRatio).round();
    return LongImageTileRects(
      sourceTop: sourceTop,
      sourceHeight: sourceHeight,
      destTop: destTop,
      destHeight: destBottom - destTop,
    );
  }
}

class LongImageSegmentPlan {
  const LongImageSegmentPlan({
    required this.widthPx,
    required this.heightPx,
    required this.pixelRatio,
    required this.pageHeightPx,
    required this.pageCount,
  });

  final int widthPx;
  final int heightPx;
  final double pixelRatio;

  /// Maximum height of one output page in pixels.
  final int pageHeightPx;
  final int pageCount;

  /// Keep each output page comfortably below the single-image budget so the
  /// composed page plus its tiles do not hit the low-end Android OOM ceiling.
  static const int defaultPagePixels = 8000000;

  factory LongImageSegmentPlan.fromContent({
    required double width,
    required double height,
    required double requestedPixelRatio,
    int maxPixelsPerPage = defaultPagePixels,
  }) {
    if (width <= 0 || height <= 0 || requestedPixelRatio <= 0) {
      throw ArgumentError('Invalid segmented long image size');
    }
    if (maxPixelsPerPage <= 0) {
      throw ArgumentError('Invalid page pixel budget');
    }

    final widthPx = math.max(1, (width * requestedPixelRatio).floor());
    final heightPx = math.max(1, (height * requestedPixelRatio).floor());
    final maxPageHeight = math.max(1, maxPixelsPerPage ~/ widthPx);
    if (maxPageHeight < 64) {
      throw LongImageTooLargeException(widthPx: widthPx, heightPx: heightPx, maxPixels: maxPixelsPerPage);
    }
    final pageHeightPx = math.min(heightPx, maxPageHeight);
    final pageCount = math.max(1, (heightPx / pageHeightPx).ceil());

    return LongImageSegmentPlan(
      widthPx: widthPx,
      heightPx: heightPx,
      pixelRatio: requestedPixelRatio,
      pageHeightPx: pageHeightPx,
      pageCount: pageCount,
    );
  }
}

class LongImageExporter {
  const LongImageExporter._();

  /// Target size for the preview PNG. Returns null when the full image fits
  /// within the preview budget and does not need downscaling.
  static ({int width, int height})? previewSizeFor({
    required int width,
    required int height,
    int maxWidth = 1080,
    int maxPixels = 8000000,
  }) {
    if (width <= 0 || height <= 0) return null;
    // Cap width and total pixels, not height: capping height makes very tall
    // exports extremely narrow (e.g. 1440x24000 -> 246px wide) and blurry when
    // the preview panel upscales them.
    final scale = math.min(maxWidth / width, math.sqrt(maxPixels / (width * height)));
    if (scale >= 1) return null;
    final previewWidth = math.max(1, (width * scale).floor());
    var previewHeight = math.max(1, (height * scale).floor());
    // Rounding can land a few pixels over the budget; clamp the long edge.
    if (previewWidth * previewHeight > maxPixels) {
      previewHeight = math.max(1, maxPixels ~/ previewWidth);
    }
    return (width: previewWidth, height: previewHeight);
  }

  /// Waits (bounded) for Flutter's ImageCache to finish pending images.
  /// Remote markdown images otherwise show up as blank tiles.
  static Future<void> _waitForImages({required Duration timeout, bool Function()? isCancelled}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (isCancelled?.call() ?? false) return;
      if (PaintingBinding.instance.imageCache.pendingImageCount == 0) {
        await SchedulerBinding.instance.endOfFrame;
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  static Future<File?> _writePreviewPng(
    ui.Image source,
    String dir,
    String name,
    ({int width, int height}) size,
  ) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImageRect(
      source,
      Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
      Rect.fromLTWH(0, 0, size.width.toDouble(), size.height.toDouble()),
      Paint()..filterQuality = FilterQuality.medium,
    );
    final picture = recorder.endRecording();
    try {
      final thumb = await picture.toImage(size.width, size.height);
      try {
        final data = await thumb.toByteData(format: ui.ImageByteFormat.png);
        if (data == null) return null;
        final file = File('$dir/$name');
        await file.writeAsBytes(data.buffer.asUint8List());
        return file;
      } finally {
        thumb.dispose();
      }
    } finally {
      picture.dispose();
    }
  }

  /// Releases tiles as soon as the composed picture has been rasterized.
  /// This only lowers the encode-phase peak: during capture the [ui.Picture]
  /// still retains every drawImageRect'd tile until `toImage`, so tiles cannot
  /// be released one-by-one before rasterization.
  static void _disposeTiles(List<ui.Image> tiles) {
    // Clear first so a throwing dispose cannot make the outer finally
    // double-dispose an already-released image (debug builds assert).
    final pending = List<ui.Image>.of(tiles);
    tiles.clear();
    for (final image in pending) {
      image.dispose();
    }
  }

  /// Windows/desktop can hold a larger RGBA image; Android is capped lower to
  /// leave headroom for the tile images and the encoder.
  static int defaultMaxPixels() {
    // Two peak phases: capture holds all tiles (≈ one final RGBA frame, because
    // ui.Picture retains every drawn tile), then encoding holds the composed
    // image + encoder buffer (≈ two frames). Caps stay below the raw device
    // budget so these phases do not push low-end devices into the OOM killer.
    if (Platform.isAndroid) return 36000000; // ~144 MB final, ~432 MB peak
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      return 80000000; // ~320 MB final, ~960 MB peak
    }
    return 60000000;
  }

  static Future<LongImageExportResult?> export(
    BuildContext context,
    Widget content, {
    required double width,
    double pixelRatio = 3.0,
    int? maxPixels,
    LongImageProgressCallback? onProgress,
    bool Function()? isCancelled,
    String filePrefix = 'chat-export',
  }) async {
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return null;

    final boundaryKey = GlobalKey();
    final contentKey = GlobalKey();
    final controller = ScrollController();
    final viewportHeight = ValueNotifier<double>(LongImageTilePlan.maxTilePx / pixelRatio);
    final freezeTickers = ValueNotifier<bool>(false);

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) {
        return Positioned(
          left: -10000,
          top: -10000,
          child: RepaintBoundary(
            key: boundaryKey,
            child: ValueListenableBuilder<double>(
              valueListenable: viewportHeight,
              builder: (_, height, __) => Container(
                width: width,
                height: height,
                color: Theme.of(ctx).colorScheme.background,
                child: SingleChildScrollView(
                  controller: controller,
                  physics: const NeverScrollableScrollPhysics(),
                  child: KeyedSubtree(
                    key: contentKey,
                    child: Material(
                      type: MaterialType.transparency,
                      // Tickers stay enabled during the initial settle so entry
                      // animations reach their target values; freeze them only
                      // before the tile capture loop.
                      child: ValueListenableBuilder<bool>(
                        valueListenable: freezeTickers,
                        builder: (_, frozen, __) => TickerMode(enabled: !frozen, child: content),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );

    overlay.insert(entry);

    final tileImages = <ui.Image>[];
    ui.Image? composed;
    try {
      // Let the overlay build, lay out and paint before measuring.
      await WidgetsBinding.instance.endOfFrame;
      await WidgetsBinding.instance.endOfFrame;
      await Future<void>.delayed(const Duration(milliseconds: 500));
      // Total image-settle budget, shared across all tiles so a stuck remote
      // image cannot add 500 ms to every tile of a 100-tile export.
      final imageSettleDeadline = DateTime.now().add(const Duration(seconds: 4));
      final preMeasureWait = imageSettleDeadline.difference(DateTime.now());
      await _waitForImages(
        timeout: preMeasureWait > const Duration(seconds: 2) ? const Duration(seconds: 2) : preMeasureWait,
        isCancelled: isCancelled,
      );
      if (isCancelled?.call() ?? false) return null;

      // Freeze tickers after the initial settle, before measuring/capturing.
      freezeTickers.value = true;
      await WidgetsBinding.instance.endOfFrame;

      final contentSize = contentKey.currentContext?.size;
      if (contentSize == null || contentSize.height <= 0) return null;

      final plan = LongImageTilePlan.fromContent(
        width: width,
        height: contentSize.height,
        requestedPixelRatio: pixelRatio,
        maxPixels: maxPixels ?? defaultMaxPixels(),
      );

      // Resize the viewport to the effective capture ratio (long content is
      // clamped above); keep the content mounted so it is laid out once.
      if ((viewportHeight.value - plan.tileLogicalHeight).abs() > 0.5) {
        viewportHeight.value = plan.tileLogicalHeight;
        await WidgetsBinding.instance.endOfFrame;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }

      final boundary = boundaryKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return null;

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final paint = Paint()..filterQuality = FilterQuality.medium;

      var drawnPx = 0;
      for (var i = 0; i < plan.tileCount; i++) {
        if (isCancelled?.call() ?? false) return null;

        final tileStart = i * plan.tileLogicalHeight;
        final maxScroll = controller.hasClients ? controller.position.maxScrollExtent : 0.0;
        final scrollOffset = math.min(tileStart, math.max(0.0, maxScroll));
        controller.jumpTo(scrollOffset);
        // jumpTo may not schedule a frame when the offset is unchanged (the
        // last tile is clamped), so force one before capturing.
        SchedulerBinding.instance.scheduleFrame();
        await SchedulerBinding.instance.endOfFrame;
        await Future<void>.delayed(const Duration(milliseconds: 16));
        if (DateTime.now().isBefore(imageSettleDeadline)) {
          await _waitForImages(timeout: imageSettleDeadline.difference(DateTime.now()), isCancelled: isCancelled);
        }
        if (isCancelled?.call() ?? false) return null;

        // The first tile can be captured before images/WebView settle; allow
        // more retries there than for subsequent tiles.
        final attempts = i == 0 ? 5 : 2;
        final retryDelay = i == 0 ? 200 : 120;
        ui.Image? tile;
        for (var retry = 0; retry < attempts; retry++) {
          try {
            tile = await boundary.toImage(pixelRatio: plan.capturePixelRatio);
            break;
          } catch (_) {
            await Future<void>.delayed(Duration(milliseconds: retryDelay));
          }
        }
        if (tile == null) return null;
        tileImages.add(tile);

        final rects = plan.tileRectsFor(index: i, contentHeight: contentSize.height, scrollOffset: scrollOffset);
        if (rects.sourceHeight <= 0 || rects.destHeight <= 0) break;

        final src = Rect.fromLTWH(0, rects.sourceTop.toDouble(), tile.width.toDouble(), rects.sourceHeight.toDouble());
        final dst = Rect.fromLTWH(0, rects.destTop.toDouble(), plan.widthPx.toDouble(), rects.destHeight.toDouble());
        canvas.drawImageRect(tile, src, dst, paint);
        drawnPx = rects.destTop + rects.destHeight;

        onProgress?.call(
          LongImageProgress(stage: LongImageExportStage.rendering, current: i + 1, total: plan.tileCount),
        );
      }

      if (drawnPx <= 0) return null;
      final picture = recorder.endRecording();
      onProgress?.call(const LongImageProgress(stage: LongImageExportStage.stitching, current: 1, total: 1));

      final finalHeight = math.min(drawnPx, plan.heightPx);
      try {
        composed = await picture.toImage(plan.widthPx, finalHeight);
      } finally {
        picture.dispose();
      }
      // The picture is rasterized; tile images are no longer referenced by the
      // encoder. Drop them before encoding to cut the peak by ~one RGBA frame.
      _disposeTiles(tileImages);

      onProgress?.call(const LongImageProgress(stage: LongImageExportStage.encoding, current: 0, total: 1));
      final data = await composed.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return null;
      final dir = await getTemporaryDirectory();
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final file = File('${dir.path}/$filePrefix-$stamp.png');
      await file.writeAsBytes(data.buffer.asUint8List());

      if (isCancelled?.call() ?? false) return null;
      File? previewFile;
      try {
        final previewSize = previewSizeFor(width: composed.width, height: composed.height);
        if (previewSize != null) {
          previewFile = await _writePreviewPng(composed, dir.path, '$filePrefix-$stamp-preview.png', previewSize);
        }
      } catch (_) {
        previewFile = null;
      }

      onProgress?.call(const LongImageProgress(stage: LongImageExportStage.encoding, current: 1, total: 1));
      return LongImageExportResult(
        file: file,
        previewFile: previewFile,
        effectivePixelRatio: plan.effectivePixelRatio,
        requestedPixelRatio: pixelRatio,
      );
    } finally {
      entry.remove();
      // The overlay entry is removed on the next frame; disposing the
      // notifier before its final build would trip "used after dispose".
      try {
        await WidgetsBinding.instance.endOfFrame;
      } catch (_) {}
      viewportHeight.dispose();
      freezeTickers.dispose();
      controller.dispose();
      _disposeTiles(tileImages);
      composed?.dispose();
    }
  }

  /// Exports long content as multiple vertical PNG pages.
  ///
  /// Each page is kept within [LongImageSegmentPlan.defaultPagePixels] so a
  /// document that cannot fit into one image remains exportable without
  /// allocating one giant RGBA buffer. The requested pixel ratio is preserved;
  /// pages are split by height instead of silently reducing quality.
  static Future<LongImageSegmentedExportResult?> exportSegments(
    BuildContext context,
    Widget content, {
    required double width,
    double pixelRatio = 3.0,
    int? maxPixelsPerPage,
    LongImageProgressCallback? onProgress,
    bool Function()? isCancelled,
    String filePrefix = 'chat-export',
  }) async {
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return null;

    final boundaryKey = GlobalKey();
    final contentKey = GlobalKey();
    final controller = ScrollController();
    final viewportHeight = ValueNotifier<double>(LongImageTilePlan.maxTilePx / pixelRatio);
    final freezeTickers = ValueNotifier<bool>(false);

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) {
        return Positioned(
          left: -10000,
          top: -10000,
          child: RepaintBoundary(
            key: boundaryKey,
            child: ValueListenableBuilder<double>(
              valueListenable: viewportHeight,
              builder: (_, height, __) => Container(
                width: width,
                height: height,
                color: Theme.of(ctx).colorScheme.background,
                child: SingleChildScrollView(
                  controller: controller,
                  physics: const NeverScrollableScrollPhysics(),
                  child: KeyedSubtree(
                    key: contentKey,
                    child: Material(
                      type: MaterialType.transparency,
                      child: ValueListenableBuilder<bool>(
                        valueListenable: freezeTickers,
                        builder: (_, frozen, __) => TickerMode(enabled: !frozen, child: content),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );

    overlay.insert(entry);

    final pageTiles = <ui.Image>[];
    final files = <File>[];
    var succeeded = false;
    try {
      // Let the overlay build, lay out and paint before measuring.
      await WidgetsBinding.instance.endOfFrame;
      await WidgetsBinding.instance.endOfFrame;
      await Future<void>.delayed(const Duration(milliseconds: 500));

      final imageSettleDeadline = DateTime.now().add(const Duration(seconds: 4));
      final preMeasureWait = imageSettleDeadline.difference(DateTime.now());
      await _waitForImages(
        timeout: preMeasureWait > const Duration(seconds: 2) ? const Duration(seconds: 2) : preMeasureWait,
        isCancelled: isCancelled,
      );
      if (isCancelled?.call() ?? false) return null;

      freezeTickers.value = true;
      await WidgetsBinding.instance.endOfFrame;

      final contentSize = contentKey.currentContext?.size;
      if (contentSize == null || contentSize.height <= 0) return null;

      final plan = LongImageSegmentPlan.fromContent(
        width: width,
        height: contentSize.height,
        requestedPixelRatio: pixelRatio,
        maxPixelsPerPage: maxPixelsPerPage ?? LongImageSegmentPlan.defaultPagePixels,
      );
      final tileLogicalHeight = LongImageTilePlan.maxTilePx / plan.pixelRatio;
      if ((viewportHeight.value - tileLogicalHeight).abs() > 0.5) {
        viewportHeight.value = tileLogicalHeight;
        await WidgetsBinding.instance.endOfFrame;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }

      final boundary = boundaryKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return null;

      final dir = await getTemporaryDirectory();
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final paint = Paint()..filterQuality = FilterQuality.medium;

      for (var page = 0; page < plan.pageCount; page++) {
        if (isCancelled?.call() ?? false) return null;

        final pageStartPx = page * plan.pageHeightPx;
        final pageEndPx = math.min(plan.heightPx, pageStartPx + plan.pageHeightPx);
        final pageHeightPx = pageEndPx - pageStartPx;
        if (pageHeightPx <= 0) break;

        final pageStartLogical = pageStartPx / plan.pixelRatio;
        final pageEndLogical = math.min(pageEndPx / plan.pixelRatio, contentSize.height);
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        var nextDestTop = 0;
        var tileIndex = 0;

        for (
          var tileStart = pageStartLogical;
          tileStart < pageEndLogical - 0.0001;
          tileStart += tileLogicalHeight, tileIndex++
        ) {
          if (isCancelled?.call() ?? false) return null;

          final tileEnd = math.min(tileStart + tileLogicalHeight, pageEndLogical);
          final maxScroll = controller.hasClients ? controller.position.maxScrollExtent : 0.0;
          final scrollOffset = math.min(tileStart, math.max(0.0, maxScroll));
          controller.jumpTo(scrollOffset);
          SchedulerBinding.instance.scheduleFrame();
          await SchedulerBinding.instance.endOfFrame;
          await Future<void>.delayed(const Duration(milliseconds: 16));
          if (DateTime.now().isBefore(imageSettleDeadline)) {
            await _waitForImages(timeout: imageSettleDeadline.difference(DateTime.now()), isCancelled: isCancelled);
          }
          if (isCancelled?.call() ?? false) return null;

          final attempts = page == 0 && tileIndex == 0 ? 5 : 2;
          final retryDelay = page == 0 && tileIndex == 0 ? 200 : 120;
          ui.Image? tile;
          for (var retry = 0; retry < attempts; retry++) {
            try {
              tile = await boundary.toImage(pixelRatio: plan.pixelRatio);
              break;
            } catch (_) {
              await Future<void>.delayed(Duration(milliseconds: retryDelay));
            }
          }
          if (tile == null) return null;
          pageTiles.add(tile);

          final sourceTop = ((tileStart - scrollOffset) * plan.pixelRatio).round();
          final sourceBottom = ((tileEnd - scrollOffset) * plan.pixelRatio).round();
          final sourceHeight = sourceBottom - sourceTop;
          final destBottom = math.min(pageHeightPx, math.max(0, ((tileEnd * plan.pixelRatio).round() - pageStartPx)));
          final destHeight = destBottom - nextDestTop;
          if (sourceHeight <= 0 || destHeight <= 0) {
            nextDestTop = destBottom;
            continue;
          }

          final src = Rect.fromLTWH(0, sourceTop.toDouble(), tile.width.toDouble(), sourceHeight.toDouble());
          final dst = Rect.fromLTWH(0, nextDestTop.toDouble(), plan.widthPx.toDouble(), destHeight.toDouble());
          canvas.drawImageRect(tile, src, dst, paint);
          nextDestTop = destBottom;
        }

        if (nextDestTop <= 0) break;
        final picture = recorder.endRecording();
        onProgress?.call(
          LongImageProgress(stage: LongImageExportStage.rendering, current: page + 1, total: plan.pageCount),
        );
        late final ui.Image composedPage;
        try {
          composedPage = await picture.toImage(plan.widthPx, pageHeightPx);
        } finally {
          picture.dispose();
        }
        _disposeTiles(pageTiles);

        onProgress?.call(
          LongImageProgress(stage: LongImageExportStage.encoding, current: page + 1, total: plan.pageCount),
        );
        final file = File('${dir.path}/$filePrefix-$stamp-${page + 1}.png');
        try {
          final data = await composedPage.toByteData(format: ui.ImageByteFormat.png);
          if (data == null) return null;
          await file.writeAsBytes(data.buffer.asUint8List());
          files.add(file);
        } finally {
          composedPage.dispose();
        }
      }

      if (files.isEmpty) return null;
      succeeded = true;
      return LongImageSegmentedExportResult(
        files: files,
        widthPx: plan.widthPx,
        pageHeightPx: plan.pageHeightPx,
        totalHeightPx: plan.heightPx,
      );
    } finally {
      entry.remove();
      try {
        await WidgetsBinding.instance.endOfFrame;
      } catch (_) {}
      viewportHeight.dispose();
      freezeTickers.dispose();
      controller.dispose();
      _disposeTiles(pageTiles);
      if (!succeeded) {
        for (final file in files) {
          try {
            await file.delete();
          } catch (_) {}
        }
      }
    }
  }
}
