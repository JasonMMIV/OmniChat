// P2-5: one host↔guest mount table for the Android PRoot shell.
//
// File tools execute on the host (Dart, real Android paths); `shell_exec`
// executes inside PRoot (guest paths such as /workspace). This table is the
// single source of truth used by:
// - the PRoot argv builder (binds);
// - the shell backend's cwd/path resolver;
// - the system prompt's path explanation;
// - tests that lock the round-trip and escape rules.
//
// Pure Dart: no Flutter imports and no filesystem access, so the containment
// rules can be unit-tested without an Android device.
library;

import 'package:path/path.dart' as p;

/// What a mount is for. Only [workspace] and [optional] entries are bindable;
/// the rootfs itself is mounted by PRoot via `-r`, not a bind.
enum WorkspaceMountKind { workspace, runtime, optional }

class WorkspaceMount {
  const WorkspaceMount({
    required this.hostPath,
    required this.guestPath,
    this.readOnly = false,
    this.kind = WorkspaceMountKind.workspace,
    this.fileToolsReadable = true,
  });

  /// Absolute host path (Android: `/data/user/0/...` or `/storage/...`).
  final String hostPath;

  /// Absolute guest path (`/workspace`, `/upload`, ...).
  final String guestPath;

  /// App-level policy only. PRoot `-b` does NOT enforce read-only; the file
  /// tools and prompt must refuse writes. Never treat this as a security
  /// boundary.
  final bool readOnly;

  final WorkspaceMountKind kind;

  /// Whether the host side is inside the file-tool sandbox for this
  /// conversation. Runtime mounts (rootfs) are not.
  final bool fileToolsReadable;

  bool get bindable => kind != WorkspaceMountKind.runtime;

  Map<String, dynamic> toChannelBind() => <String, dynamic>{
    'host': hostPath,
    'guest': guestPath,
    'readOnly': readOnly,
  };
}

class WorkspaceMountTable {
  WorkspaceMountTable._({required this.mounts, required this.workspace});

  factory WorkspaceMountTable.forWorkspace({
    required String workspaceHostPath,
    List<WorkspaceMount> optional = const <WorkspaceMount>[],
  }) {
    final host = _normalizeHost(workspaceHostPath);
    if (host == null) {
      throw ArgumentError.value(
        workspaceHostPath,
        'workspaceHostPath',
        'must be an absolute, NUL-free host path',
      );
    }
    final workspace = WorkspaceMount(
      hostPath: host,
      guestPath: '/workspace',
      kind: WorkspaceMountKind.workspace,
    );
    final table = WorkspaceMountTable._(
      mounts: <WorkspaceMount>[workspace, ...optional],
      workspace: workspace,
    );
    table._validate();
    return table;
  }

  final List<WorkspaceMount> mounts;
  final WorkspaceMount workspace;

  /// Binds handed to PRoot. Runtime entries are excluded.
  List<Map<String, dynamic>> get channelBinds => <Map<String, dynamic>>[
    for (final mount in mounts)
      if (mount.bindable) mount.toChannelBind(),
  ];

  /// Host path → guest path. Uses the longest matching host prefix so a
  /// nested mount wins over `/workspace`.
  String? guestPathForHost(String hostPath) {
    final host = _normalizeHost(hostPath);
    if (host == null) return null;
    WorkspaceMount? best;
    for (final mount in mounts) {
      if (!_isWithin(host, mount.hostPath)) continue;
      if (best == null || mount.hostPath.length > best.hostPath.length) {
        best = mount;
      }
    }
    if (best == null) return null;
    final relative = _relative(host, best.hostPath);
    return _joinGuest(best.guestPath, relative);
  }

  /// Guest path → host path. Uses the longest matching guest prefix.
  String? hostPathForGuest(String guestPath) {
    final guest = normalizeGuestPath(guestPath);
    if (guest == null) return null;
    WorkspaceMount? best;
    for (final mount in mounts) {
      if (!_isWithinGuest(guest, mount.guestPath)) continue;
      if (best == null || mount.guestPath.length > best.guestPath.length) {
        best = mount;
      }
    }
    if (best == null) return null;
    final relative = _relativeGuest(guest, best.guestPath);
    return relative.isEmpty
        ? best.hostPath
        : p.posix.normalize(p.posix.join(best.hostPath, relative));
  }

  /// Host cwd (must be inside the workspace) → guest `/workspace/...`.
  String? guestCwdForHost(String hostCwd) {
    final guest = guestPathForHost(hostCwd);
    if (guest == null) return null;
    if (guest != '/workspace' && !guest.startsWith('/workspace/')) return null;
    return guest;
  }

  /// Guest cwd (must be inside `/workspace`) → host path.
  String? hostCwdForGuest(String guestCwd) {
    final guest = normalizeGuestPath(guestCwd);
    if (guest == null) return null;
    if (guest != '/workspace' && !guest.startsWith('/workspace/')) return null;
    return hostPathForGuest(guest);
  }

  /// Workspace-relative form for a host path, or null when outside.
  String? workspaceRelativeForHost(String hostPath) {
    final host = _normalizeHost(hostPath);
    if (host == null || !_isWithin(host, workspace.hostPath)) return null;
    return _relative(host, workspace.hostPath);
  }

  /// Whether a guest path is inside the workspace bind.
  bool isInsideWorkspaceGuest(String guestPath) {
    final guest = normalizeGuestPath(guestPath);
    return guest != null &&
        (guest == '/workspace' || guest.startsWith('/workspace/'));
  }

  void _validate() {
    final guestTargets = <String>{};
    for (final mount in mounts) {
      final host = _normalizeHost(mount.hostPath);
      if (host == null || host != mount.hostPath) {
        throw ArgumentError(
          'invalid or non-normalized mount host: ${mount.hostPath}',
        );
      }
      final guest = normalizeGuestPath(mount.guestPath);
      if (guest == null) {
        throw ArgumentError('invalid mount guest: ${mount.guestPath}');
      }
      if (!guestTargets.add(guest)) {
        throw ArgumentError('duplicate guest mount: $guest');
      }
      if (mount.bindable && !_isAllowedGuest(guest)) {
        throw ArgumentError('guest mount is outside the allowlist: $guest');
      }
    }
    if (!guestTargets.contains('/workspace')) {
      throw ArgumentError('workspace mount is required');
    }
  }

  static bool _isAllowedGuest(String guest) {
    bool under(String root) => guest == root || guest.startsWith('$root/');
    return under('/workspace') ||
        under('/upload') ||
        under('/skills') ||
        under('/tmp') ||
        guest.startsWith('/mounts/');
  }

  static String? normalizeGuestPath(String? raw) {
    final text = (raw ?? '').trim();
    if (text.isEmpty || text.contains('\u0000')) return null;
    if (!text.startsWith('/')) return null;
    final segments = text.split('/');
    final stack = <String>[];
    for (final segment in segments) {
      if (segment.isEmpty || segment == '.') continue;
      if (segment == '..') {
        if (stack.isEmpty) return null;
        stack.removeLast();
      } else {
        stack.add(segment);
      }
    }
    return '/${stack.join('/')}';
  }

  static String? _normalizeHost(String? raw) {
    final text = (raw ?? '').trim();
    if (text.isEmpty || text.contains('\u0000')) return null;
    if (!text.startsWith('/')) return null;
    final normalized = p.posix.normalize(text);
    if (normalized == '/' || normalized == '.') return null;
    return normalized;
  }

  static String _relative(String path, String root) {
    if (path == root) return '';
    return path.substring(root.length + (root.endsWith('/') ? 0 : 1));
  }

  static String _relativeGuest(String path, String root) {
    if (path == root) return '';
    return path.substring(root.length + (root.endsWith('/') ? 0 : 1));
  }

  static String _joinGuest(String root, String relative) {
    if (relative.isEmpty) return root;
    return p.posix.normalize(p.posix.join(root, relative));
  }

  static bool _isWithin(String path, String root) {
    if (path == root) return true;
    final prefix = root.endsWith('/') ? root : '$root/';
    return path.startsWith(prefix);
  }

  static bool _isWithinGuest(String path, String root) {
    if (path == root) return true;
    final prefix = root.endsWith('/') ? root : '$root/';
    return path.startsWith(prefix);
  }
}
