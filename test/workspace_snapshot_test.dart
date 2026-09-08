// P1-5 workspace snapshot + one-click rollback tests (IMPORT_PLAN_COWORK.md).
//
// Covers: create (zip persisted, .omnichat/ excluded, skipped on empty/missing
// root, hostile run id sanitized), restore (roundtrip restores exact snapshot
// state, .omnichat/ preserved, path-traversal entries skipped, missing zip),
// listing (newest first), and the retention sweep (count cap, total-size cap,
// newest always kept).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import 'package:OmniChat/core/services/workspace/workspace_snapshot.dart';

void main() {
  late Directory tempRoot;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('omnichat_ws_snap_');
  });

  tearDown(() async {
    try {
      await tempRoot.delete(recursive: true);
    } catch (_) {}
  });

  String snapshotsDir() =>
      p.join(tempRoot.path, WorkspaceSnapshotService.snapshotsDirRelative);

  Future<void> writeUtf8(String path, String content) async {
    final f = File(path);
    await f.parent.create(recursive: true);
    await f.writeAsString(content);
  }

  group('WorkspaceSnapshotService.create', () {
    test('creates a zip snapshot under .omnichat/snapshots', () async {
      await writeUtf8(p.join(tempRoot.path, 'a.txt'), 'A');
      await writeUtf8(p.join(tempRoot.path, 'sub', 'b.txt'), 'B');

      final result = await WorkspaceSnapshotService.create(
        workspaceRoot: tempRoot.path,
        runId: 'run-1',
      );

      expect(result.ok, isTrue);
      expect(result.error, isNull);
      expect(
        p.canonicalize(result.zipPath!),
        p.canonicalize(p.join(snapshotsDir(), 'run-1.zip')),
      );
      expect(await File(result.zipPath!).exists(), isTrue);
      expect(result.totalBytes, greaterThan(0));
      // Workspace files counted (a.txt, b.txt) — the zip itself is excluded
      // from _countWorkspaceFiles? No: it counts all files under root; at
      // least the two content files must appear.
      expect(result.fileCount, greaterThanOrEqualTo(2));

      // Snapshot must not contain the app-managed .omnichat/ directory.
      final bytes = await File(result.zipPath!).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      expect(archive.files, isNotEmpty);
      for (final entry in archive.files) {
        expect(entry.name.startsWith('.omnichat'), isFalse,
            reason: 'entry ${entry.name} leaked app-managed files');
      }
      final names = archive.files.map((e) => e.name).toSet();
      expect(names, containsAll(<String>['a.txt', 'sub/b.txt']));
    });

    test('skips an empty or missing workspace root without throwing',
        () async {
      final empty = await WorkspaceSnapshotService.create(
        workspaceRoot: '',
        runId: 'run-1',
      );
      expect(empty.ok, isFalse);
      expect(empty.error, 'skipped');

      final missing = await WorkspaceSnapshotService.create(
        workspaceRoot: p.join(tempRoot.path, 'does_not_exist'),
        runId: 'run-1',
      );
      expect(missing.ok, isFalse);
      expect(missing.error, 'skipped');
    });

    test('sanitizes a hostile run id into the snapshots directory', () async {
      await writeUtf8(p.join(tempRoot.path, 'a.txt'), 'A');

      final result = await WorkspaceSnapshotService.create(
        workspaceRoot: tempRoot.path,
        runId: r'..\..\evil x?y',
      );

      expect(result.ok, isTrue);
      final base = p.basename(result.zipPath!);
      expect(base, matches(RegExp(r'^[A-Za-z0-9_-]+\.zip$')));
      expect(
        p.canonicalize(p.dirname(result.zipPath!)),
        p.canonicalize(snapshotsDir()),
      );
      // Nothing escaped the snapshots directory.
      expect(base.contains('..'), isFalse);
    });
  });

  group('WorkspaceSnapshotService.restore', () {
    test('roundtrip: restores the exact snapshot state', () async {
      await writeUtf8(p.join(tempRoot.path, 'a.txt'), 'A');
      await writeUtf8(p.join(tempRoot.path, 'sub', 'b.txt'), 'B');

      final created = await WorkspaceSnapshotService.create(
        workspaceRoot: tempRoot.path,
        runId: 'run-1',
      );
      expect(created.ok, isTrue);

      // Mutate: change a.txt, delete b.txt, add c.txt.
      await writeUtf8(p.join(tempRoot.path, 'a.txt'), 'A2');
      await File(p.join(tempRoot.path, 'sub', 'b.txt')).delete();
      await writeUtf8(p.join(tempRoot.path, 'c.txt'), 'C');

      final restored = await WorkspaceSnapshotService.restore(
        workspaceRoot: tempRoot.path,
        zipPath: created.zipPath!,
      );

      expect(restored.ok, isTrue);
      expect(restored.fileCount, 2);
      expect(await File(p.join(tempRoot.path, 'a.txt')).readAsString(), 'A');
      expect(
        await File(p.join(tempRoot.path, 'sub', 'b.txt')).readAsString(),
        'B',
      );
      expect(await File(p.join(tempRoot.path, 'c.txt')).exists(), isFalse);
      // The snapshot itself survives (rollback target stays available).
      expect(await File(created.zipPath!).exists(), isTrue);
    });

    test('keeps the app-managed .omnichat/ directory on restore', () async {
      await writeUtf8(p.join(tempRoot.path, 'a.txt'), 'A');

      final created = await WorkspaceSnapshotService.create(
        workspaceRoot: tempRoot.path,
        runId: 'run-1',
      );
      expect(created.ok, isTrue);

      final managed = p.join(tempRoot.path, '.omnichat', 'tool_outputs');
      await writeUtf8(p.join(managed, 'x.txt'), 'managed');

      await WorkspaceSnapshotService.restore(
        workspaceRoot: tempRoot.path,
        zipPath: created.zipPath!,
      );

      expect(
        await File(p.join(managed, 'x.txt')).readAsString(),
        'managed',
        reason: '.omnichat/ must never be wiped by a restore',
      );
    });

    test('skips path-traversal and absolute entry names', () async {
      final evilBytes = utf8.encode('evil');
      final archive = Archive()
        ..addFile(ArchiveFile('../evil.txt', evilBytes.length, evilBytes))
        ..addFile(ArchiveFile('/abs.txt', evilBytes.length, evilBytes))
        ..addFile(ArchiveFile('ok.txt', evilBytes.length, evilBytes));
      final zipPath = p.join(snapshotsDir(), 'evil.zip');
      await File(zipPath).parent.create(recursive: true);
      await File(zipPath).writeAsBytes(ZipEncoder().encode(archive)!);

      final result = await WorkspaceSnapshotService.restore(
        workspaceRoot: tempRoot.path,
        zipPath: zipPath,
      );

      expect(result.ok, isTrue);
      expect(result.fileCount, 1, reason: 'only ok.txt is safe to extract');
      expect(
        await File(p.join(tempRoot.path, 'ok.txt')).readAsString(),
        'evil',
      );
      expect(
        await File(p.join(tempRoot.parent.path, 'evil.txt')).exists(),
        isFalse,
      );
    });

    test('fails with snapshot_missing for an unknown zip', () async {
      final result = await WorkspaceSnapshotService.restore(
        workspaceRoot: tempRoot.path,
        zipPath: p.join(tempRoot.path, 'nope.zip'),
      );
      expect(result.ok, isFalse);
      expect(result.error, 'snapshot_missing');
    });
  });

  group('WorkspaceSnapshotService.listSnapshots', () {
    test('returns zips newest first and latestSnapshotPath agrees',
        () async {
      final ids = <String>[];
      for (var i = 0; i < 3; i++) {
        final id = 'run-$i';
        ids.add(id);
        await writeUtf8(p.join(tempRoot.path, 'f$i.txt'), 'x');
        final r = await WorkspaceSnapshotService.create(
          workspaceRoot: tempRoot.path,
          runId: id,
        );
        expect(r.ok, isTrue);
        // Ensure distinct mtimes on coarse-resolution filesystems.
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }

      final listed = await WorkspaceSnapshotService.listSnapshots(
        tempRoot.path,
      );
      expect(listed.length, 3);
      expect(p.basename(listed.first), 'run-2.zip');
      expect(p.basename(listed.last), 'run-0.zip');

      final latest = await WorkspaceSnapshotService.latestSnapshotPath(
        tempRoot.path,
      );
      expect(p.basename(latest!), 'run-2.zip');
    });

    test('empty workspace yields an empty list', () async {
      expect(await WorkspaceSnapshotService.listSnapshots(tempRoot.path),
          isEmpty);
      expect(
        await WorkspaceSnapshotService.latestSnapshotPath(tempRoot.path),
        isNull,
      );
    });
  });

  group('WorkspaceSnapshotService.sweepSnapshots', () {
    Future<List<String>> seedZips(int n) async {
      final paths = <String>[];
      for (var i = 0; i < n; i++) {
        final path = p.join(snapshotsDir(), 'run-$i.zip');
        await File(path).parent.create(recursive: true);
        await File(path).writeAsString('payload-$i');
        await Future<void>.delayed(const Duration(milliseconds: 30));
        paths.add(path);
      }
      return paths;
    }

    test('keeps the newest within the count cap', () async {
      final paths = await seedZips(5);

      await WorkspaceSnapshotService.sweepSnapshots(
        tempRoot.path,
        maxSnapshots: 2,
        maxTotalBytes: WorkspaceSnapshotService.retentionMaxTotalBytes,
      );

      final remaining = await WorkspaceSnapshotService.listSnapshots(
        tempRoot.path,
      );
      expect(remaining.length, 2);
      // Newest kept, oldest evicted.
      expect(p.basename(remaining.first), 'run-4.zip');
      expect(p.basename(remaining.last), 'run-3.zip');
      for (final gone in paths.take(3)) {
        expect(await File(gone).exists(), isFalse);
      }
    });

    test('keeps the newest even when it alone busts the total-size cap',
        () async {
      await seedZips(3);

      await WorkspaceSnapshotService.sweepSnapshots(
        tempRoot.path,
        maxSnapshots: 5,
        maxTotalBytes: 1,
      );

      final remaining = await WorkspaceSnapshotService.listSnapshots(
        tempRoot.path,
      );
      expect(remaining.length, 1);
      expect(p.basename(remaining.first), 'run-2.zip');
    });

    test('total-size cap evicts older snapshots that no longer fit',
        () async {
      // Each seeded zip is exactly 9 bytes ('payload-N').
      await seedZips(4);

      await WorkspaceSnapshotService.sweepSnapshots(
        tempRoot.path,
        maxSnapshots: 10,
        maxTotalBytes: 20,
      );

      final remaining = await WorkspaceSnapshotService.listSnapshots(
        tempRoot.path,
      );
      // Newest two fit under 20 bytes (9 + 9 = 18); a third would exceed.
      expect(remaining.length, 2);
      expect(p.basename(remaining.first), 'run-3.zip');
      expect(p.basename(remaining.last), 'run-2.zip');
    });

    test('no-op when everything fits', () async {
      final paths = await seedZips(2);

      await WorkspaceSnapshotService.sweepSnapshots(
        tempRoot.path,
        maxSnapshots: 5,
        maxTotalBytes: WorkspaceSnapshotService.retentionMaxTotalBytes,
      );

      for (final path in paths) {
        expect(await File(path).exists(), isTrue);
      }
    });
  });

  group('WorkspaceSnapshotService.clearSnapshots', () {
    test('removes the whole snapshots directory, nothing else', () async {
      await writeUtf8(p.join(tempRoot.path, 'a.txt'), 'A');
      final created = await WorkspaceSnapshotService.create(
        workspaceRoot: tempRoot.path,
        runId: 'run-1',
      );
      expect(created.ok, isTrue);

      await WorkspaceSnapshotService.clearSnapshots(tempRoot.path);

      expect(await Directory(snapshotsDir()).exists(), isFalse);
      expect(await File(p.join(tempRoot.path, 'a.txt')).exists(), isTrue);
    });
  });
}
