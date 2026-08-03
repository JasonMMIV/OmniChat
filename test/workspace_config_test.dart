import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/core/models/assistant.dart';
import 'package:OmniChat/core/models/conversation.dart';
import 'package:OmniChat/core/models/workspace_config.dart';
import 'package:OmniChat/core/services/workspace/workspace_resolver.dart';

void main() {
  final conversation = Conversation(title: 'Test');

  test('serializes workspace modes and custom paths', () {
    const custom = WorkspaceConfig.custom('/projects/omnichat');
    final restored = WorkspaceConfig.fromJson(custom.toJson());

    expect(restored, custom);
    expect(
      WorkspaceConfig.fromJson('/legacy/path'),
      const WorkspaceConfig.custom('/legacy/path'),
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
      defaultPath: '/default',
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
      defaultPath: '/default',
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
      defaultPath: '/default',
    );
    expect(disabledResolution.enabled, isFalse);
    expect(disabledResolution.path, isNull);
  });
}
