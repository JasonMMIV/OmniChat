import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/core/services/shell/android/workspace_mount_table.dart';

void main() {
  const workspace = '/data/user/0/com.psyche.omnichat/files/workspace';

  group('WorkspaceMountTable', () {
    test('maps the workspace root in both directions', () {
      final table = WorkspaceMountTable.forWorkspace(
        workspaceHostPath: workspace,
      );
      expect(table.guestPathForHost(workspace), '/workspace');
      expect(table.hostPathForGuest('/workspace'), workspace);
      expect(table.guestCwdForHost(workspace), '/workspace');
      expect(table.hostCwdForGuest('/workspace'), workspace);
    });

    test('maps nested paths and round-trips them', () {
      final table = WorkspaceMountTable.forWorkspace(
        workspaceHostPath: workspace,
      );
      final host = '$workspace/lib/main.dart';
      expect(table.guestPathForHost(host), '/workspace/lib/main.dart');
      expect(table.hostPathForGuest('/workspace/lib/main.dart'), host);
      expect(table.workspaceRelativeForHost(host), 'lib/main.dart');
    });

    test('uses the longest matching mount', () {
      final table = WorkspaceMountTable.forWorkspace(
        workspaceHostPath: workspace,
        optional: const <WorkspaceMount>[
          WorkspaceMount(
            hostPath: '/storage/emulated/0/project',
            guestPath: '/mounts/project',
            kind: WorkspaceMountKind.optional,
          ),
        ],
      );
      expect(
        table.guestPathForHost('/storage/emulated/0/project/src/a.dart'),
        '/mounts/project/src/a.dart',
      );
      expect(
        table.hostPathForGuest('/mounts/project/src/a.dart'),
        '/storage/emulated/0/project/src/a.dart',
      );
    });

    test('rejects host paths outside every mount', () {
      final table = WorkspaceMountTable.forWorkspace(
        workspaceHostPath: workspace,
      );
      expect(table.guestPathForHost('/data/user/0/other/file.txt'), isNull);
      expect(table.hostPathForGuest('/etc/passwd'), isNull);
      expect(table.workspaceRelativeForHost('/data/user/0/other'), isNull);
    });

    test('rejects guest traversal, NUL, and relative paths', () {
      final table = WorkspaceMountTable.forWorkspace(
        workspaceHostPath: workspace,
      );
      expect(table.hostPathForGuest('/workspace/../etc/passwd'), isNull);
      expect(table.hostPathForGuest('/workspace/\u0000x'), isNull);
      expect(table.hostPathForGuest('workspace/file.txt'), isNull);
      expect(table.isInsideWorkspaceGuest('/workspace/../etc'), isFalse);
    });

    test('cwd conversion refuses mounts outside /workspace', () {
      final table = WorkspaceMountTable.forWorkspace(
        workspaceHostPath: workspace,
        optional: const <WorkspaceMount>[
          WorkspaceMount(
            hostPath: '/storage/emulated/0/project',
            guestPath: '/mounts/project',
            kind: WorkspaceMountKind.optional,
          ),
        ],
      );
      expect(table.guestCwdForHost('/storage/emulated/0/project'), isNull);
      expect(table.hostCwdForGuest('/mounts/project'), isNull);
    });

    test('channel binds contain only bindable mounts and keep read-only', () {
      final table = WorkspaceMountTable.forWorkspace(
        workspaceHostPath: workspace,
        optional: const <WorkspaceMount>[
          WorkspaceMount(
            hostPath: '/data/user/0/com.psyche.omnichat/files/skills',
            guestPath: '/skills',
            readOnly: true,
            kind: WorkspaceMountKind.optional,
            fileToolsReadable: false,
          ),
          WorkspaceMount(
            hostPath: '/data/user/0/com.psyche.omnichat/files/rootfs',
            guestPath: '/rootfs',
            kind: WorkspaceMountKind.runtime,
            fileToolsReadable: false,
          ),
        ],
      );
      expect(table.channelBinds.length, 2);
      expect(table.channelBinds.first['guest'], '/workspace');
      expect(table.channelBinds.last['guest'], '/skills');
      expect(table.channelBinds.last['readOnly'], true);
    });

    test('normalizes guest paths deterministically', () {
      expect(
        WorkspaceMountTable.normalizeGuestPath('/workspace//lib/./a.dart'),
        '/workspace/lib/a.dart',
      );
      expect(
        WorkspaceMountTable.normalizeGuestPath('/workspace/lib/../a.dart'),
        '/workspace/a.dart',
      );
      expect(
        WorkspaceMountTable.normalizeGuestPath('/workspace/../../etc'),
        isNull,
      );
    });

    test('requires a POSIX absolute workspace path', () {
      expect(
        () => WorkspaceMountTable.forWorkspace(workspaceHostPath: 'relative'),
        throwsArgumentError,
      );
      expect(
        () => WorkspaceMountTable.forWorkspace(workspaceHostPath: ''),
        throwsArgumentError,
      );
    });
  });
}
