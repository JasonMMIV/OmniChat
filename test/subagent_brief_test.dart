import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/features/home/services/file_workspace_prompt.dart';

Map<String, dynamic> _tool(String name) => <String, dynamic>{
  'type': 'function',
  'function': <String, dynamic>{'name': name},
};

void main() {
  group('buildSubagentBrief (P0-3)', () {
    test('includes the workspace, file map and assistant instructions', () {
      final brief = buildSubagentBrief(
        workspacePath: r'C:\projects\demo',
        childTools: [_tool('file_read'), _tool('file_list')],
        projectInstructions: 'Always follow the project conventions.',
        workspaceFileMap: '[Workspace file map]\nlib/main.dart (12 B)',
      );

      expect(brief, contains(r'C:\projects\demo'));
      expect(brief, contains('file_read'));
      expect(brief, contains('lib/main.dart'));
      expect(brief, contains('Always follow the project conventions.'));
      expect(brief, contains('your own tool list wins'));
    });

    test('omits the file map when the child cannot list files', () {
      final brief = buildSubagentBrief(
        workspacePath: '/workspace',
        childTools: [_tool('file_read')],
        workspaceFileMap: '[Workspace file map]\nsecret.dart (1 KB)',
      );

      expect(brief, contains('/workspace'));
      expect(brief, isNot(contains('secret.dart')));
    });

    test('omits the workspace block when no workspace is configured', () {
      final brief = buildSubagentBrief(
        workspacePath: null,
        childTools: [_tool('file_read')],
        projectInstructions: 'Standing instructions.',
      );

      expect(brief, isNot(contains('[File Workspace]')));
      expect(brief, contains('Standing instructions.'));
      expect(brief, isNot(contains('shell_run')));
    });

    test('truncates assistant instructions before the file map', () {
      final brief = buildSubagentBrief(
        workspacePath: '/workspace',
        childTools: [_tool('file_read'), _tool('file_list')],
        projectInstructions: 'A' * 12000,
        workspaceFileMap: 'B' * 12000,
      );

      expect(brief.length, lessThan(14500));
      expect(brief, contains('[... brief truncated ...]'));
      expect(brief, contains('[Workspace file map]'));
      // The assistant block was the first thing clipped.
      expect(brief.indexOf('A'), lessThan(brief.indexOf('B')));
    });

    test('a read-only child list never advertises shell tools', () {
      final brief = buildSubagentBrief(
        workspacePath: '/workspace',
        childTools: [
          _tool('file_read'),
          _tool('file_grep'),
          _tool('file_list'),
        ],
      );

      expect(brief, contains('file_grep'));
      expect(brief, isNot(contains('shell_run')));
      expect(brief, isNot(contains('shell_exec')));
    });
  });
}
