import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/shared/widgets/markdown_with_highlight.dart';

void main() {
  test('retries transient nulls and succeeds on a later attempt', () async {
    var calls = 0;
    final result = await captureMermaidBitmapWithHandler(
      () async {
        calls++;
        return calls < 3 ? null : Uint8List.fromList([1, 2, 3]);
      },
      retryDelay: Duration.zero,
    );

    expect(result.status, MermaidBitmapRenderStatus.success);
    expect(result.bytes, [1, 2, 3]);
    expect(calls, 3);
  });

  test('gives up after the bounded attempts', () async {
    var calls = 0;
    final result = await captureMermaidBitmapWithHandler(
      () async {
        calls++;
        return null;
      },
      retryDelay: Duration.zero,
    );

    expect(result.status, MermaidBitmapRenderStatus.failed);
    expect(result.bytes, isNull);
    expect(calls, 3);
  });

  test('empty bytes count as a failed attempt and keep retrying', () async {
    var calls = 0;
    final result = await captureMermaidBitmapWithHandler(
      () async {
        calls++;
        return calls == 1 ? Uint8List(0) : Uint8List.fromList([9]);
      },
      retryDelay: Duration.zero,
    );

    expect(result.status, MermaidBitmapRenderStatus.success);
    expect(calls, 2);
  });

  test('swallows handler exceptions and returns failed', () async {
    final result = await captureMermaidBitmapWithHandler(
      () async => throw StateError('webview gone'),
      retryDelay: Duration.zero,
    );

    expect(result.status, MermaidBitmapRenderStatus.failed);
  });
}
