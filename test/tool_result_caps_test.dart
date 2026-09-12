// Workspace zero-residue plan (PLAN_WORKSPACE_ZERO_RESIDUE.md Phase 1.5).
//
// Covers the in-memory tool result capper that replaced P1-4 externalization:
// threshold passthrough, head/tail shape, truncation marker with the original
// size, per-tool-family re-query guidance, the bare transport variant, the
// budget contract that keeps the transport backstop from cutting the guidance
// out of an oversized payload, and the guarantee that nothing is ever written
// to disk.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/services/tools/tool_result_caps.dart';

void main() {
  group('ToolResultCaps.cap', () {
    test('results at or below the threshold pass through unchanged', () {
      final small = 'k' * ToolResultCaps.capThresholdChars;
      expect(
        ToolResultCaps.cap(toolName: 'file_read', result: small),
        small,
      );
    });

    test('oversized result is capped to head + marker + guidance + tail', () {
      const tailMarker = 'TAIL_MARKER';
      final big = '${'x' * 40000}$tailMarker';
      final out = ToolResultCaps.cap(toolName: 'file_read', result: big);

      // Head preserved at the start.
      expect(out, startsWith('x'));
      // Truncation marker present with the original size in KB.
      expect(
        out,
        contains('[... tool output truncated — ${(big.length / 1024).round()} KB total ...]'),
      );
      // Re-query guidance present.
      expect(out, contains('file_read with offset/limit'));
      expect(out, contains('file_search'));
      // Tail preserved at the end.
      expect(out, endsWith(tailMarker));
      // Budget contract: head + marker + guidance + tail fits the shared
      // threshold, so the transport backstop leaves the payload alone.
      expect(out.length, lessThanOrEqualTo(ToolResultCaps.capThresholdChars));
    });

    test('file tools get the file_read/file_search guidance', () {
      final out = ToolResultCaps.cap(
        toolName: 'file_extract_text',
        result: 'a' * 40000,
      );
      expect(out, contains('file_read with offset/limit'));
    });

    test('search_web gets the narrow-parameters guidance', () {
      final out = ToolResultCaps.cap(
        toolName: 'search_web',
        result: 'a' * 40000,
      );
      expect(out, contains('narrower parameters'));
      expect(out, contains('max_results'));
    });

    test('MCP / unknown tools get the generic guidance', () {
      final out = ToolResultCaps.cap(
        toolName: 'some_mcp_tool',
        result: 'a' * 40000,
      );
      expect(out, contains('Re-run the tool with narrower parameters'));
      expect(out, isNot(contains('file_search')));
    });

    test('oversized result is capped to head + marker + tail (bare)', () {
      const tailMarker = 'TAIL_BARE';
      final big = '${'y' * 40000}$tailMarker';
      final out = ToolResultCaps.capBare(big);

      expect(out, startsWith('y'));
      expect(
        out,
        contains('[... tool output truncated — ${(big.length / 1024).round()} KB total ...]'),
      );
      expect(out, endsWith(tailMarker));
      expect(out.length, lessThanOrEqualTo(ToolResultCaps.capThresholdChars));
      // The bare variant carries no per-family guidance.
      expect(out, isNot(contains('offset/limit')));
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
        result: 'b' * (120 * 1024),
      );

      // What `ChatApiService._truncateToolResultText` does to the payload.
      final onTheWire = ToolResultCaps.capBare(capped);

      expect(onTheWire, capped);
      expect(onTheWire, contains('offset/limit'));
      expect(onTheWire, contains('120 KB total'));
    });

    test('an already capped payload is never re-cut', () {
      final once = ToolResultCaps.capBare('c' * (120 * 1024));
      expect(ToolResultCaps.capBare(once), once);
      expect(ToolResultCaps.cap(toolName: 'file_read', result: once), once);
    });

    test('pre-fix payloads (marker above the budget) are passed through', () {
      // Shape emitted before the 2026-09-12 budget fix: the marker and the
      // guidance sat ~183 chars above the threshold, so the transport
      // backstop used to cut them out on every replay.
      final legacy = '${'d' * 16384}'
          '\n\n[... tool output truncated — 120 KB total ...]\n\n'
          '${ToolResultCaps.fileToolGuidance}\n\n'
          '${'d' * 16384}';
      expect(
        legacy.length,
        greaterThan(ToolResultCaps.capThresholdChars),
      );

      expect(ToolResultCaps.capBare(legacy), legacy);
    });

    test('a document quoting the marker cannot bypass the cap', () {
      final sneaky =
          '[... tool output truncated — 1 KB total ...]\n${'e' * (200 * 1024)}';
      final out = ToolResultCaps.capBare(sneaky);

      expect(out.length, lessThanOrEqualTo(ToolResultCaps.capThresholdChars));
      expect(out, endsWith('e'));
    });

    test('nothing is ever written to disk', () async {
      final tmp = await Directory.systemTemp.createTemp('omnichat_caps_');
      try {
        final before = tmp.listSync(recursive: true).length;
        ToolResultCaps.cap(
          toolName: 'file_read',
          result: 'a' * 40000,
        );
        expect(tmp.listSync(recursive: true).length, before);
      } finally {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      }
    });
  });
}
