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
  const WorkspaceConfig({required this.mode, this.path});

  const WorkspaceConfig.inheritProject()
    : mode = WorkspaceMode.inheritProject,
      path = null;

  const WorkspaceConfig.disabled() : mode = WorkspaceMode.disabled, path = null;

  const WorkspaceConfig.useDefault()
    : mode = WorkspaceMode.useDefault,
      path = null;

  const WorkspaceConfig.custom(String value)
    : mode = WorkspaceMode.custom,
      path = value;

  final WorkspaceMode mode;
  final String? path;

  bool get isEnabled => mode != WorkspaceMode.disabled;

  Map<String, dynamic> toJson() => {
    'mode': mode.value,
    if (mode == WorkspaceMode.custom && path != null) 'path': path,
  };

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
    );
  }

  @override
  bool operator ==(Object other) {
    return other is WorkspaceConfig && other.mode == mode && other.path == path;
  }

  @override
  int get hashCode => Object.hash(mode, path);
}
