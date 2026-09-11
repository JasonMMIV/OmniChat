import 'package:flutter/foundation.dart';

enum WorkspaceMode { inheritProject, disabled, useDefault, custom }

extension WorkspaceModeCodec on WorkspaceMode {
  String get value => switch (this) {
    WorkspaceMode.inheritProject => 'inherit_project',
    WorkspaceMode.disabled => 'disabled',
    WorkspaceMode.useDefault => 'use_default',
    WorkspaceMode.custom => 'custom',
  };

  static WorkspaceMode fromValue(
    String? value, {
    WorkspaceMode fallback = WorkspaceMode.inheritProject,
  }) {
    return switch (value) {
      'inherit_project' => WorkspaceMode.inheritProject,
      'disabled' => WorkspaceMode.disabled,
      'use_default' => WorkspaceMode.useDefault,
      'custom' => WorkspaceMode.custom,
      _ => fallback,
    };
  }
}

@immutable
class WorkspaceConfig {
  const WorkspaceConfig({required this.mode, this.path, this.previous});

  const WorkspaceConfig.inheritProject()
    : mode = WorkspaceMode.inheritProject,
      path = null,
      previous = null;

  const WorkspaceConfig.disabled() : mode = WorkspaceMode.disabled, path = null, previous = null;

  const WorkspaceConfig.useDefault()
    : mode = WorkspaceMode.useDefault,
      path = null,
      previous = null;

  const WorkspaceConfig.custom(String value)
    : mode = WorkspaceMode.custom,
      path = value,
      previous = null;

  /// Toggle-off memory: builds the disabled config that remembers [prior]
  /// (the config active before the workspace was disabled) so toggling
  /// back on can restore it. The chain never nests — disabling an
  /// already-disabled config keeps the existing memory.
  factory WorkspaceConfig.disabledFrom(WorkspaceConfig prior) {
    final remembered = prior.mode == WorkspaceMode.disabled
        ? prior.previous
        : prior;
    return WorkspaceConfig(
      mode: WorkspaceMode.disabled,
      previous: remembered == null
          ? null
          : WorkspaceConfig(mode: remembered.mode, path: remembered.path),
    );
  }

  final WorkspaceMode mode;
  final String? path;

  /// The pre-disable config remembered by the enable/disable toggle. Only
  /// ever set on a `disabled` config and never nested (depth stays at 1).
  final WorkspaceConfig? previous;

  bool get isEnabled => mode != WorkspaceMode.disabled;

  /// The config to restore when the workspace is re-enabled. Falls back to
  /// project inheritance (re-joining the project/default resolution chain)
  /// when nothing was remembered.
  WorkspaceConfig get restoreOnEnable =>
      previous ?? const WorkspaceConfig.inheritProject();

  Map<String, dynamic> toJson() {
    final prior = previous;
    return {
      'mode': mode.value,
      if (mode == WorkspaceMode.custom && path != null) 'path': path,
      if (mode == WorkspaceMode.disabled && prior != null)
        'previous': {
          'mode': prior.mode.value,
          if (prior.mode == WorkspaceMode.custom && prior.path != null)
            'path': prior.path,
        },
    };
  }

  /// Parses a remembered pre-disable config. The nested value never carries
  /// its own `previous` (the chain depth is always one).
  static WorkspaceConfig _previousFromJson(dynamic raw) {
    if (raw is! Map) return const WorkspaceConfig.inheritProject();
    final mode = WorkspaceModeCodec.fromValue(raw['mode']?.toString());
    final path = raw['path']?.toString().trim();
    if (mode == WorkspaceMode.custom && (path == null || path.isEmpty)) {
      return const WorkspaceConfig.inheritProject();
    }
    return WorkspaceConfig(
      mode: mode,
      path: mode == WorkspaceMode.custom ? path : null,
    );
  }

  static WorkspaceConfig fromJson(
    dynamic raw, {
    WorkspaceMode fallback = WorkspaceMode.inheritProject,
  }) {
    if (raw is String && raw.trim().isNotEmpty) {
      return WorkspaceConfig.custom(raw.trim());
    }
    if (raw is! Map) return WorkspaceConfig(mode: fallback);

    final mode = WorkspaceModeCodec.fromValue(
      raw['mode']?.toString(),
      fallback: fallback,
    );
    final path = raw['path']?.toString().trim();
    if (mode == WorkspaceMode.custom && (path == null || path.isEmpty)) {
      return WorkspaceConfig(mode: fallback);
    }
    return WorkspaceConfig(
      mode: mode,
      path: mode == WorkspaceMode.custom ? path : null,
      previous: mode == WorkspaceMode.disabled && raw['previous'] != null
          ? _previousFromJson(raw['previous'])
          : null,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is WorkspaceConfig && other.mode == mode && other.path == path;
  }

  @override
  int get hashCode => Object.hash(mode, path);
}
