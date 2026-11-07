import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/services/shell/changed_files.dart';

WorkspaceFileStamp _stamp(int modifiedMs) =>
    WorkspaceFileStamp(modifiedMs: modifiedMs, size: 1);

void main() {
  test('does not report deletions when the after snapshot is truncated', () {
    final before = WorkspaceSnapshot(
      files: <String, WorkspaceFileStamp>{'old.txt': _stamp(1)},
    );
    final after = WorkspaceSnapshot(
      files: const <String, WorkspaceFileStamp>{},
      truncated: true,
    );

    final diff = diffWorkspaceSnapshots(before, after);

    expect(diff.deleted, isEmpty);
    expect(diff.truncated, isTrue);
  });

  test('marks the result truncated when the before snapshot was capped', () {
    final before = WorkspaceSnapshot(
      files: const <String, WorkspaceFileStamp>{},
      truncated: true,
    );
    final after = WorkspaceSnapshot(
      files: <String, WorkspaceFileStamp>{'new.txt': _stamp(2)},
    );

    final diff = diffWorkspaceSnapshots(before, after);

    expect(diff.paths, contains('new.txt'));
    expect(diff.truncated, isTrue);
  });
}
