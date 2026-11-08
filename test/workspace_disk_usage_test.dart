import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/core/services/file/workspace_disk_usage.dart';

void main() {
  late Directory workspace;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp(
      'omnichat_disk_usage_',
    );
  });

  tearDown(() async {
    if (await workspace.exists()) await workspace.delete(recursive: true);
  });

  test('sums workspace files and excludes .omnichat', () async {
    await File('${workspace.path}/a.txt').writeAsString('hello');
    final nested = Directory('${workspace.path}/nested');
    await nested.create();
    await File('${nested.path}/b.bin').writeAsBytes(List<int>.filled(10, 1));
    final appState = Directory(
      '${workspace.path}/${WorkspaceDiskUsageService.excludedDirectoryName}',
    );
    await appState.create();
    await File(
      '${appState.path}/state.db',
    ).writeAsBytes(List<int>.filled(4096, 1));

    final usage = await WorkspaceDiskUsageService.measure(workspace.path);

    expect(usage, isNotNull);
    expect(usage!.totalBytes, 15);
    expect(usage.fileCount, 2);
    expect(usage.directoryCount, 1);
    expect(usage.scannedEntryCount, 3);
    expect(usage.truncated, isFalse);
  });

  test('reports visited entries, not only files, for a partial scan', () async {
    for (var i = 0; i < 8; i++) {
      await Directory('${workspace.path}/dir_$i').create();
    }
    await File('${workspace.path}/only.txt').writeAsString('x');

    final usage = await WorkspaceDiskUsageService.measure(
      workspace.path,
      maxScannedEntries: 2,
    );

    expect(usage, isNotNull);
    expect(usage!.scannedEntryCount, 2);
    expect(usage.fileCount, lessThan(2));
    expect(usage.truncated, isTrue);
  });

  test('returns null for a missing workspace', () async {
    final usage = await WorkspaceDiskUsageService.measure(
      '${workspace.path}/missing',
    );
    expect(usage, isNull);
  });

  test('formats byte counts compactly and promotes rounded 1024 KB', () {
    expect(formatWorkspaceBytes(0), '0 B');
    expect(formatWorkspaceBytes(512), '512 B');
    expect(formatWorkspaceBytes(1024), '1 KB');
    expect(formatWorkspaceBytes(1536), '1.5 KB');
    expect(formatWorkspaceBytes(2 * 1024 * 1024), '2 MB');
    expect(formatWorkspaceBytes(1024 * 1024 - 1), '1 MB');
  });
}
