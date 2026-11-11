import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/services/file/file_tool_service.dart';
import 'package:OmniChat/features/chat/tools/tool_presentation.dart';
import 'package:OmniChat/icons/lucide_adapter.dart';
import 'package:OmniChat/l10n/app_localizations_en.dart';
import 'package:OmniChat/l10n/app_localizations_zh.dart';

void main() {
  final en = AppLocalizationsEn();
  final zhHant = AppLocalizationsZhHant();

  List<String> fileToolNames() => FileToolService.getToolDefinitions()
      .map((def) => ((def['function'] as Map)['name'] ?? '').toString())
      .toList();

  group('tool presentation', () {
    test('every built-in file tool has a localized name and its own icon', () {
      final names = fileToolNames();
      expect(names.length, 17);
      for (final name in names) {
        expect(
          toolDisplayName(en, name),
          isNot(name),
          reason: '$name has no English display name',
        );
        expect(
          toolDisplayName(zhHant, name),
          isNot(name),
          reason: '$name has no zh-Hant display name',
        );
        expect(
          toolIcon(name),
          isNot(Lucide.Wrench),
          reason: '$name falls back to the generic wrench',
        );
      }
    });

    test('titles are name-only (no path, query, or command suffix)', () {
      expect(toolDisplayName(en, 'file_read'), 'Read file');
      expect(toolDisplayName(en, 'file_edit'), 'Edit file');
      expect(toolDisplayName(zhHant, 'file_edit'), '編輯檔案');
      expect(toolDisplayName(zhHant, 'file_list'), '列出資料夾');
    });

    test('every built-in workspace tool belongs to a display group', () {
      for (final name in fileToolNames()) {
        expect(
          workspaceToolGroup(name),
          isNot(WorkspaceToolGroup.other),
          reason: '$name has no switchboard group',
        );
      }
      expect(
        workspaceToolGroup('get_console_errors'),
        WorkspaceToolGroup.system,
      );
      expect(workspaceToolGroup('shell_run'), WorkspaceToolGroup.system);
    });

    test('all groups have a label and a one-line description', () {
      for (final group in WorkspaceToolGroup.values) {
        expect(workspaceToolGroupLabel(en, group), isNotEmpty);
        expect(workspaceToolGroupDescription(en, group), isNotEmpty);
        expect(workspaceToolGroupLabel(zhHant, group), isNotEmpty);
        expect(workspaceToolGroupDescription(zhHant, group), isNotEmpty);
      }
    });

    test('non-obvious tools carry a dedicated summary', () {
      const nonObvious = <String>[
        'file_patch',
        'file_extract_text',
        'file_extract_zip',
        'file_create_pdf',
        'get_console_errors',
      ];
      for (final name in nonObvious) {
        expect(toolShortDescription(en, name), isNotNull, reason: name);
        expect(toolShortDescription(zhHant, name), isNotNull, reason: name);
      }
      expect(toolShortDescription(en, 'file_read'), isNull);
    });

    test('external MCP tools keep their raw server-provided id', () {
      expect(
        toolDisplayName(en, 'browser_take_screenshot'),
        'browser_take_screenshot',
      );
      expect(toolIcon('browser_take_screenshot'), Lucide.Wrench);
    });

    test('legacy aliases resolve to the canonical tool', () {
      expect(toolDisplayName(en, 'fetch_html'), en.toolNameWebFetch);
      expect(toolDisplayName(en, 'read_page'), en.toolNameWebFetch);
      expect(
        toolDisplayName(en, 'create_memory'),
        en.chatMessageWidgetMemoryUpdate,
      );
      expect(toolDisplayName(en, 'image_search'), en.toolNameIllustrate);
      expect(toolIcon('image_search'), Lucide.Image);
    });
  });
}
