// P1-4 long-output externalization tests (IMPORT_PLAN_COWORK.md).
//
// Covers: threshold passthrough, externalization (file persisted, preview +
// retrieval guidance), no-workspace fallback (transport truncator backstop),
// invalid workspace never throws, id-bearing sanitized file names, collision
// fallback, and the retention sweep (max files / max age).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:OmniChat/core/services/tools/tool_output_externalizer.dart';

void main() {
  late Directory tempRoot;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('omnichat_toolout_');
  });

  tearDown(() async {
    try {
      await tempRoot.delete(recursive: true);
    } catch (_) {}
  });

  group('ToolOutputExternalizer.maybeExternalize', () {
    test('results at or below the threshold pass through unchanged', () async {
      final small = 'k' * ToolOutputExternalizer.externalizeThresholdChars;
      final out = await ToolOutputExternalizer.maybeExternalize(
        toolName: 'file_read',
        result: small,
        workspacePath: tempRoot.path,
      );
      expect(out, small);
      // Nothing written to the workspace.
      expect(
        Directory(
          p.join(
            tempRoot.path,
            ToolOutputExternalizer.toolOutputsDirRelative,
          ),
        ).existsSync(),
        isFalse,
      );
    });

    test('oversized result is externalized with preview and guidance',
        () async {
      final big = '${'x' * 40000}TAIL_MARKER';
      final out = await ToolOutputExternalizer.maybeExternalize(
        toolName: 'file_read',
        result: big,
        workspacePath: tempRoot.path,
      );

      // Preview head preserved; the tail (beyond 4KB) is NOT in the
      // preview — it lives in the persisted file.
      expect(out, startsWith('x'));
      expect(out, isNot(contains('TAIL_MARKER')));
      expect(out.length, lessThan(10000));

      // Guidance present with the relative path.
      expect(out, contains('Full output saved to: .omnichat/tool_outputs/'));
      expect(out, contains('file_read(path: ".omnichat/tool_outputs/'));
      expect(out, contains('file_search'));

      // The file holds the FULL original result (single truncation path:
      // the model can retrieve the exact bytes, no double truncation).
      final dir = Directory(
        p.join(tempRoot.path, ToolOutputExternalizer.toolOutputsDirRelative),
      );
      final files = await dir.list().toList();
      expect(files, hasLength(1));
      final persisted = await (files.single as File).readAsString();
      expect(persisted, big);
      expect(persisted, endsWith('TAIL_MARKER'));
    });

    test('P1-4 id-aware contract: toolCallId names the persisted file and '
        'is idempotent across re-runs', () async {
      final big = 'z' * 40000;
      final out = await ToolOutputExternalizer.maybeExternalize(
        toolName: 'file_read',
        result: big,
        workspacePath: tempRoot.path,
        toolCallId: 'call_xyz-01',
      );
      expect(out, contains('file_read-call_xyz-01.txt'));

      // Re-running the same call id with the same workspace state lands on
      // the same file (overwrite, not a disambiguated copy).
      final out2 = await ToolOutputExternalizer.maybeExternalize(
        toolName: 'file_read',
        result: big,
        workspacePath: tempRoot.path,
        toolCallId: 'call_xyz-01',
      );
      expect(out2, out);
      final dir = Directory(
        p.join(tempRoot.path, ToolOutputExternalizer.toolOutputsDirRelative),
      );
      expect(await dir.list().toList(), hasLength(1));

      // A hostile id is sanitized to a safe filename charset — no path
      // separators survive, so the referenced path stays inside the
      // tool_outputs directory.
      final out3 = await ToolOutputExternalizer.maybeExternalize(
        toolName: 'file_read',
        result: big,
        workspacePath: tempRoot.path,
        toolCallId: r'..\..\evil',
      );
      final name3 =
          RegExp(r'Full output saved to: (\S+)').firstMatch(out3)!.group(1)!;
      expect(p.basename(name3), isNot(contains('..')));
    });

    test('null/empty workspace returns the result unchanged (backstop)',
        () async {
      final big = 'y' * 40000;
      final outNull = await ToolOutputExternalizer.maybeExternalize(
        toolName: 'mcp_tool',
        result: big,
        workspacePath: null,
      );
      expect(outNull, big);
      final outEmpty = await ToolOutputExternalizer.maybeExternalize(
        toolName: 'mcp_tool',
        result: big,
        workspacePath: '   ',
      );
      expect(outEmpty, big);
    });

    test('hostile tool name / call id are sanitized into the file name',
        () async {
      final big = 'z' * 40000;
      final out = await ToolOutputExternalizer.maybeExternalize(
        toolName: '../../evil & tool??',
        result: big,
        workspacePath: tempRoot.path,
        toolCallId: r'call\id:with/slashes',
      );
      expect(out, contains('Full output saved to: .omnichat/tool_outputs/'));

      final dir = Directory(
        p.join(tempRoot.path, ToolOutputExternalizer.toolOutputsDirRelative),
      );
      final name = (await dir.list().toList()).single.path;
      // Stay inside the directory: no separators or traversal in the name.
      expect(p.basename(name), isNot(contains(r'\')));
      expect(p.basename(name), isNot(contains('/')));
      expect(p.basename(name), isNot(contains('..')));
      expect(p.basename(name), matches(RegExp(r'^[\w-]+\.txt$')));
    });

    test('same id twice overwrites in place (deterministic round-trip)',
        () async {
      // P1-4 id-aware contract: tools execute at most once per run
      // (ADR-A3), so an id collision only happens across resume/retry —
      // and then the LATEST result must win at the SAME path, not spawn a
      // suffixed copy that would invalidate the preview's retrieval path.
      final big = 'w' * 40000;
      await ToolOutputExternalizer.maybeExternalize(
        toolName: 'shell_run',
        result: big,
        workspacePath: tempRoot.path,
        toolCallId: 'call_1',
      );
      final out2 = await ToolOutputExternalizer.maybeExternalize(
        toolName: 'shell_run',
        result: '${big}second',
        workspacePath: tempRoot.path,
        toolCallId: 'call_1',
      );
      final dir = Directory(
        p.join(tempRoot.path, ToolOutputExternalizer.toolOutputsDirRelative),
      );
      final names = (await dir.list().toList())
          .map((e) => p.basename(e.path))
          .toList();
      expect(names, hasLength(1));
      expect(names, contains('shell_run-call_1.txt'));
      // Second result references the same deterministic path.
      final secondName =
          RegExp(r'Full output saved to: (\S+)').firstMatch(out2)!.group(1)!;
      expect(p.basename(secondName), 'shell_run-call_1.txt');
      // The overwrite carries the latest bytes.
      final second = await File(
        p.join(dir.path, 'shell_run-call_1.txt'),
      ).readAsString();
      expect(second, contains('second'));
    });

    test('invalid workspace root never throws and returns original',
        () async {
      final big = 'q' * 40000;
      final bogus = p.join(tempRoot.path, 'no_such_dir', 'deeper');
      final out = await ToolOutputExternalizer.maybeExternalize(
        toolName: 'file_search',
        result: big,
        workspacePath: bogus,
      );
      // Either externalized under the created path or returned unchanged —
      // both are acceptable; the contract is "never throws".
      expect(out.length, greaterThan(0));
    });
  });

  group('ToolOutputExternalizer.sweepToolOutputs', () {
    Future<File> seed(String name, {DateTime? mtime}) async {
      final dir = Directory(
        p.join(tempRoot.path, ToolOutputExternalizer.toolOutputsDirRelative),
      );
      await dir.create(recursive: true);
      final f = File(p.join(dir.path, name));
      await f.writeAsString('data', flush: true);
      if (mtime != null) {
        await f.setLastModified(mtime);
      }
      return f;
    }

    test('keeps at most maxFiles, evicting oldest first', () async {
      final now = DateTime.now();
      for (var i = 0; i < 5; i++) {
        await seed('file_read-c$i.txt', mtime: now.subtract(Duration(minutes: 100 - i)));
      }
      await ToolOutputExternalizer.sweepToolOutputs(
        tempRoot.path,
        maxFiles: 3,
        maxAgeDays: 7,
      );
      final remaining =
          Directory(p.join(tempRoot.path, ToolOutputExternalizer.toolOutputsDirRelative))
              .listSync()
              .map((e) => p.basename(e.path))
              .toList();
      expect(remaining, hasLength(3));
      // Oldest two (c0, c1) evicted; newest kept.
      expect(remaining.contains('file_read-c0.txt'), isFalse);
      expect(remaining.contains('file_read-c1.txt'), isFalse);
      expect(remaining.contains('file_read-c4.txt'), isTrue);
    });

    test('drops files older than maxAgeDays', () async {
      final now = DateTime.now();
      await seed('old.txt', mtime: now.subtract(const Duration(days: 9)));
      await seed('fresh.txt', mtime: now.subtract(const Duration(hours: 1)));
      await ToolOutputExternalizer.sweepToolOutputs(
        tempRoot.path,
        maxFiles: 20,
        maxAgeDays: 7,
      );
      final remaining =
          Directory(p.join(tempRoot.path, ToolOutputExternalizer.toolOutputsDirRelative))
              .listSync()
              .map((e) => p.basename(e.path))
              .toList();
      expect(remaining, ['fresh.txt']);
    });

    test('no-op when the directory does not exist', () async {
      await ToolOutputExternalizer.sweepToolOutputs(tempRoot.path);
      expect(await tempRoot.exists(), isTrue);
    });
  });
}
