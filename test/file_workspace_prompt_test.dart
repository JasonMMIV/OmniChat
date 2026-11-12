import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/features/home/services/file_workspace_prompt.dart';

Map<String, dynamic> _tool(String name) => <String, dynamic>{
  'type': 'function',
  'function': <String, dynamic>{
    'name': name,
    'description': '',
    'parameters': <String, dynamic>{'type': 'object'},
  },
};

void main() {
  const workspace = r'C:\work\demo';

  group('buildFileWorkspacePrompt', () {
    test('returns null when no workspace tools are advertised', () {
      final prompt = buildFileWorkspacePrompt(workspace, <Map<String, dynamic>>[
        _tool('search_web'),
        _tool('write_todos'),
        _tool('ask_user'),
        _tool('mcp__demo__echo'),
      ]);

      expect(prompt, isNull);
    });

    test('returns null for a missing or blank workspace path', () {
      expect(
        buildFileWorkspacePrompt(null, <Map<String, dynamic>>[
          _tool('file_read'),
        ]),
        isNull,
      );
      expect(
        buildFileWorkspacePrompt('   ', <Map<String, dynamic>>[
          _tool('file_read'),
        ]),
        isNull,
      );
    });

    test('lists only the workspace tools actually advertised', () {
      final prompt = buildFileWorkspacePrompt(workspace, <Map<String, dynamic>>[
        _tool('file_read'),
        _tool('file_grep'),
        _tool('file_view_image'),
        _tool('get_console_errors'),
        _tool('shell_run'),
        _tool('search_web'),
        _tool('write_todos'),
        _tool('ask_user'),
      ]);

      expect(prompt, isNotNull);
      final text = prompt!;
      expect(text, contains('[File Workspace]'));
      expect(text, contains(workspace));
      expect(text, contains('file_read'));
      expect(text, contains('file_grep'));
      expect(text, contains('file_view_image'));
      expect(text, contains('get_console_errors'));
      expect(text, contains('shell_run'));
      expect(text, isNot(contains('file_write')));
      expect(text, isNot(contains('file_patch')));
      expect(text, isNot(contains('file_extract_text')));
      expect(text, isNot(contains('file_extract_zip')));
      expect(text, isNot(contains('file_create_pdf')));
      expect(text, isNot(contains('search_web')));
      expect(text, isNot(contains('write_todos')));
      expect(text, isNot(contains('ask_user')));
      expect(text, isNot(contains('Dangerous file types')));
      expect(text, isNot(contains('exact text replacement')));
    });

    test('does not teach a parseable inline image marker', () {
      final prompt = buildFileWorkspacePrompt(workspace, <Map<String, dynamic>>[
        _tool('file_read'),
        _tool('file_edit'),
        _tool('file_patch'),
        _tool('file_grep'),
        _tool('file_view_image'),
        _tool('get_console_errors'),
        _tool('shell_run'),
        _tool('file_extract_text'),
        _tool('file_extract_zip'),
        _tool('file_create_pdf'),
      ]);

      expect(prompt, isNotNull);
      final text = prompt!;
      expect(text, contains('file_view_image'));
      expect(text, isNot(contains('[image:')));
      expect(text, isNot(contains('<absolute-path>')));
    });

    test('describes tolerant edit matching and current zip validation', () {
      final prompt = buildFileWorkspacePrompt(workspace, <Map<String, dynamic>>[
        _tool('file_edit'),
        _tool('file_extract_text'),
        _tool('file_extract_zip'),
        _tool('file_create_pdf'),
      ]);

      expect(prompt, isNotNull);
      final text = prompt!;
      expect(text, contains('matches exact text first'));
      expect(text, contains('indentation-tolerant'));
      expect(text, isNot(contains('exact text replacement')));
      expect(text, contains('Archive entry paths are validated'));
      expect(text, isNot(contains('Dangerous file types')));
      expect(text, contains('file_extract_text'));
      expect(text, contains('file_extract_zip'));
      expect(text, contains('file_create_pdf'));
    });

    test('shell-only workspace does not claim file operations', () {
      final prompt = buildFileWorkspacePrompt(workspace, <Map<String, dynamic>>[
        _tool('shell_run'),
      ]);

      expect(prompt, isNotNull);
      final text = prompt!;
      expect(text, contains('Available tools: shell_run.'));
      expect(
        text,
        isNot(contains('Use relative paths for all file operations')),
      );
      expect(text, contains('not a security sandbox'));
    });
  });
}
