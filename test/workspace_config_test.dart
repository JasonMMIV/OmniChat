import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:OmniChat/core/models/assistant.dart';
import 'package:OmniChat/core/models/conversation.dart';
import 'package:OmniChat/core/models/workspace_config.dart';
import 'package:OmniChat/core/services/workspace/workspace_resolver.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.root);

  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final conversation = Conversation(title: 'Test');

  test('serializes workspace modes and custom paths', () {
    const custom = WorkspaceConfig.custom('/projects/omnichat');
    final restored = WorkspaceConfig.fromJson(custom.toJson());

    expect(restored, custom);
    expect(
      WorkspaceConfig.fromJson('/legacy/path'),
      const WorkspaceConfig.custom('/legacy/path'),
    );

    const appPrivate = WorkspaceConfig.appPrivate();
    expect(appPrivate.toJson(), <String, dynamic>{'mode': 'app_private'});
    expect(WorkspaceConfig.fromJson(appPrivate.toJson()), appPrivate);
    expect(
      WorkspaceConfig.disabledFrom(appPrivate).restoreOnEnable,
      appPrivate,
    );
  });

  test('conversation settings override project settings', () async {
    final project = Assistant(
      id: 'project',
      name: 'Project',
      workspace: const WorkspaceConfig.custom('/project'),
    );

    final resolution = await WorkspaceResolver.resolve(
      conversation: conversation,
      project: project,
      conversationConfig: const WorkspaceConfig.custom('/conversation'),
      defaultConfig: const WorkspaceConfig.custom('/default'),
    );

    expect(resolution.path, '/conversation');
    expect(resolution.source, WorkspaceSource.conversation);
  });

  test('inheritance follows project and global default modes', () async {
    final project = Assistant(
      id: 'project',
      name: 'Project',
      workspace: const WorkspaceConfig.useDefault(),
    );

    final defaultResolution = await WorkspaceResolver.resolve(
      conversation: conversation,
      project: project,
      conversationConfig: null,
      defaultConfig: const WorkspaceConfig.custom('/default'),
    );
    expect(defaultResolution.path, '/default');

    final disabledResolution = await WorkspaceResolver.resolve(
      conversation: conversation,
      project: Assistant(
        id: 'project',
        name: 'Project',
        workspace: const WorkspaceConfig.disabled(),
      ),
      conversationConfig: null,
      defaultConfig: const WorkspaceConfig.custom('/default'),
    );
    expect(disabledResolution.enabled, isFalse);
    expect(disabledResolution.path, isNull);
  });

  test(
    'app private mode resolves to the platform private files directory',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'omnichat_ws_private_',
      );
      final previous = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
      addTearDown(() async {
        PathProviderPlatform.instance = previous;
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final resolution = await WorkspaceResolver.resolve(
        conversation: conversation,
        project: Assistant(
          id: 'project',
          name: 'Project',
          workspace: const WorkspaceConfig.useDefault(),
        ),
        conversationConfig: const WorkspaceConfig.appPrivate(),
        defaultConfig: const WorkspaceConfig.custom('/default'),
      );
      expect(resolution.path, '${tempDir.path}/files');
      expect(resolution.source, WorkspaceSource.defaultDirectory);

      final inherited = await WorkspaceResolver.resolve(
        conversation: conversation,
        project: Assistant(
          id: 'project',
          name: 'Project',
          workspace: const WorkspaceConfig.useDefault(),
        ),
        conversationConfig: null,
        defaultConfig: const WorkspaceConfig.appPrivate(),
      );
      expect(inherited.path, '${tempDir.path}/files');
    },
  );

  test('a disabled global default disables inherited workspaces', () async {
    final resolution = await WorkspaceResolver.resolve(
      conversation: conversation,
      project: Assistant(
        id: 'project',
        name: 'Project',
        workspace: const WorkspaceConfig.useDefault(),
      ),
      conversationConfig: null,
      defaultConfig: const WorkspaceConfig.disabled(),
    );

    expect(resolution.enabled, isFalse);
    expect(resolution.path, isNull);
    expect(resolution.source, WorkspaceSource.disabled);
  });
}
