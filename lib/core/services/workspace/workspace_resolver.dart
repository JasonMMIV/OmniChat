import '../../../utils/app_directories.dart';
import '../../models/assistant.dart';
import '../../models/conversation.dart';
import '../../models/workspace_config.dart';

enum WorkspaceSource { conversation, project, defaultDirectory, disabled }

class WorkspaceResolution {
  const WorkspaceResolution({required this.source, required this.path});

  final WorkspaceSource source;
  final String? path;

  bool get enabled => path != null && path!.trim().isNotEmpty;
}

class WorkspaceResolver {
  WorkspaceResolver._();

  static Future<WorkspaceResolution> resolve({
    required Conversation conversation,
    required Assistant? project,
    required WorkspaceConfig? conversationConfig,
    required WorkspaceConfig? defaultConfig,
  }) async {
    final conversationSetting =
        conversationConfig ?? const WorkspaceConfig.inheritProject();
    if (conversationSetting.mode != WorkspaceMode.inheritProject) {
      return _resolveSetting(
        conversationSetting,
        source: WorkspaceSource.conversation,
        defaultConfig: defaultConfig,
      );
    }

    return _resolveSetting(
      project?.workspace ?? const WorkspaceConfig.useDefault(),
      source: WorkspaceSource.project,
      defaultConfig: defaultConfig,
    );
  }

  static Future<WorkspaceResolution> _resolveSetting(
    WorkspaceConfig setting, {
    required WorkspaceSource source,
    required WorkspaceConfig? defaultConfig,
  }) async {
    switch (setting.mode) {
      case WorkspaceMode.disabled:
        return const WorkspaceResolution(
          source: WorkspaceSource.disabled,
          path: null,
        );
      case WorkspaceMode.custom:
        final path = setting.path?.trim();
        if (path == null || path.isEmpty) {
          return _resolveDefault(defaultConfig, source: source);
        }
        return WorkspaceResolution(source: source, path: path);
      case WorkspaceMode.useDefault:
      case WorkspaceMode.inheritProject:
        return _resolveDefault(defaultConfig, source: source);
    }
  }

  static Future<WorkspaceResolution> _resolveDefault(
    WorkspaceConfig? defaultConfig, {
    required WorkspaceSource source,
  }) async {
    switch (defaultConfig?.mode) {
      case WorkspaceMode.disabled:
        return const WorkspaceResolution(
          source: WorkspaceSource.disabled,
          path: null,
        );
      case WorkspaceMode.custom:
        final configured = defaultConfig!.path?.trim();
        if (configured != null && configured.isNotEmpty) {
          return WorkspaceResolution(source: source, path: configured);
        }
        return _resolveAppPrivate(source);
      case WorkspaceMode.useDefault:
      case WorkspaceMode.inheritProject:
      case null:
        return _resolveAppPrivate(source);
    }
  }

  static Future<WorkspaceResolution> _resolveAppPrivate(
    WorkspaceSource source,
  ) async {
    final fallback = (await AppDirectories.getFileSandboxDirectory()).path;
    return WorkspaceResolution(
      source: WorkspaceSource.defaultDirectory,
      path: fallback,
    );
  }
}
