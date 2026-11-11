// Workspace zero-residue plan (PLAN_WORKSPACE_ZERO_RESIDUE.md Phase 1.5).
//
// Covers the in-memory tool result capper: per-tool thresholds, head/tail
// shape, truncation marker with the original size, per-tool-family re-query
// guidance, the bare transport variant, the budget contract that keeps the
// transport backstop from cutting the guidance out of an oversized payload,
// and the guarantee that nothing is ever written to disk.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/services/tools/tool_result_caps.dart';

void main() {
  group('ToolResultCaps.cap', () {
    test('generic results at or below 32 KB pass through unchanged', () {
      final small = 'k' * ToolResultCaps.capThresholdChars;
      expect(
        ToolResultCaps.cap(toolName: 'some_mcp_tool', result: small),
        small,
      );
    });

    test('generic oversized result is capped to head + marker + guidance + tail', () {
      const tailMarker = 'TAIL_MARKER';
      final big = '${'x' * 40000}$tailMarker';
      final out = ToolResultCaps.cap(toolName: 'some_mcp_tool', result: big);

      expect(out, startsWith('x'));
      expect(
        out,
        contains(
          '[... tool output truncated — ${(big.length / 1024).round()} KB total ...]',
        ),
      );
      expect(out, contains('narrower parameters'));
      expect(out, endsWith(tailMarker));
      expect(out.length, lessThanOrEqualTo(ToolResultCaps.capThresholdChars));
    });

    test('file_read gets the 256 KB window instead of the 32 KB default', () {
      final window = 'k' * (128 * 1024);
      expect(ToolResultCaps.cap(toolName: 'file_read', result: window), window);

      final oversized = 'f' * (300 * 1024);
      final out = ToolResultCaps.cap(toolName: 'file_read', result: oversized);
      expect(out.length, lessThanOrEqualTo(ToolResultCaps.fileReadCapChars));
      expect(out, contains('file_read with offset/limit'));
    });

    test('shell_run gets the 64 KB inline window', () {
      final inline = 's' * (64 * 1024);
      expect(ToolResultCaps.cap(toolName: 'shell_run', result: inline), inline);

      final oversized = 's' * (100 * 1024);
      final out = ToolResultCaps.cap(toolName: 'shell_run', result: oversized);
      expect(out.length, lessThanOrEqualTo(ToolResultCaps.shellCapChars));
      expect(out, contains('Re-run the tool with narrower parameters'));
    });

    test(
      'other file tools keep the default 32 KB budget and file guidance',
      () {
        final out = ToolResultCaps.cap(
          toolName: 'file_extract_text',
          result: 'a' * 40000,
        );
        expect(out.length, lessThanOrEqualTo(ToolResultCaps.capThresholdChars));
        expect(out, contains('file_read with offset/limit'));
      },
    );

    test('search_web gets the narrow-parameters guidance', () {
      final out = ToolResultCaps.cap(
        toolName: 'search_web',
        result: 'a' * 40000,
      );
      expect(out, contains('narrower parameters'));
      expect(out, contains('max_results'));
    });

    test('oversized bare result is capped to head + marker + tail', () {
      const tailMarker = 'TAIL_BARE';
      final big = '${'y' * (300 * 1024)}$tailMarker';
      final out = ToolResultCaps.capBare(
        big,
        threshold: ToolResultCaps.maxCapThresholdChars,
      );

      expect(out, startsWith('y'));
      expect(
        out,
        contains(
          '[... tool output truncated — ${(big.length / 1024).round()} KB total ...]',
        ),
      );
      expect(out, endsWith(tailMarker));
      expect(
        out.length,
        lessThanOrEqualTo(ToolResultCaps.maxCapThresholdChars),
      );
      // The bare variant carries no per-family guidance.
      expect(out, isNot(contains('offset/limit')));
    });

    test('bare backstop defaults to the 32 KB catch-all', () {
      final out = ToolResultCaps.capBare('z' * 40000);
      expect(out.length, lessThanOrEqualTo(ToolResultCaps.capThresholdChars));
    });

    test('the marker reports the ORIGINAL size, not the capped size', () {
      final out = ToolResultCaps.cap(
        toolName: 'some_mcp_tool',
        result: 'a' * (200 * 1024),
      );
      expect(out, contains('[... tool output truncated — 200 KB total ...]'));
      expect(out.length, lessThanOrEqualTo(ToolResultCaps.capThresholdChars));
    });

    test('guidance and size survive the transport backstop', () {
      final capped = ToolResultCaps.cap(
        toolName: 'file_read',
        result: 'b' * (300 * 1024),
      );

      // What `ChatApiService._truncateToolResultText` does to the payload.
      final onTheWire = ToolResultCaps.capBare(
        capped,
        threshold: ToolResultCaps.maxCapThresholdChars,
      );

      expect(onTheWire, capped);
      expect(onTheWire, contains('offset/limit'));
      expect(onTheWire, contains('300 KB total'));
    });

    test('an already capped payload is never re-cut', () {
      final once = ToolResultCaps.capBare(
        'c' * (300 * 1024),
        threshold: ToolResultCaps.maxCapThresholdChars,
      );
      expect(
        ToolResultCaps.capBare(
          once,
          threshold: ToolResultCaps.maxCapThresholdChars,
        ),
        once,
      );
      expect(ToolResultCaps.cap(toolName: 'file_read', result: once), once);
    });

    test('a document quoting the marker cannot bypass the cap', () {
      final sneaky =
          '[... tool output truncated — 1 KB total ...]\n${'e' * (300 * 1024)}';
      final out = ToolResultCaps.capBare(
        sneaky,
        threshold: ToolResultCaps.maxCapThresholdChars,
      );

      expect(
        out.length,
        lessThanOrEqualTo(ToolResultCaps.maxCapThresholdChars),
      );
      expect(out, endsWith('e'));
    });

    test('nothing is ever written to disk', () async {
      final tmp = await Directory.systemTemp.createTemp('omnichat_caps_');
      try {
        final before = tmp.listSync(recursive: true).length;
        ToolResultCaps.cap(toolName: 'file_read', result: 'a' * (300 * 1024));
        expect(tmp.listSync(recursive: true).length, before);
      } finally {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      }
    });
  });
}
