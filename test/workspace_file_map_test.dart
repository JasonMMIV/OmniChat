import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:OmniChat/core/services/agent/compaction/context_trim.dart';
import 'package:OmniChat/core/services/file/file_tool_service.dart';
import 'package:OmniChat/core/services/workspace/workspace_file_map.dart';

Future<Directory> _tempWorkspace(String prefix) async {
  return Directory.systemTemp.createTemp(prefix);
}

Future<File> _write(Directory root, String relative, String content) async {
  final file = File(p.join(root.path, relative));
  await file.parent.create(recursive: true);
  return file.writeAsString(content);
}

void main() {
  group('WorkspaceFileMap.build', () {
    test('empty and missing workspaces produce no block', () async {
      final empty = await _tempWorkspace('wsmap_empty');
      addTearDown(() async => empty.delete(recursive: true));
      expect(await WorkspaceFileMap.build(workspacePath: empty.path), '');

      expect(
        await WorkspaceFileMap.build(
          workspacePath: p.join(empty.path, 'does_not_exist'),
        ),
        '',
      );
    });

    test('renders a deterministic size-annotated map', () async {
      final ws = await _tempWorkspace('wsmap_basic');
      addTearDown(() async => ws.delete(recursive: true));
      await _write(ws, 'index.html', '<html></html>');
      await _write(ws, 'src/app.tsx', 'x' * 2048);
      await _write(ws, 'src/lib/util.ts', 'y' * 5);

      final first = await WorkspaceFileMap.build(workspacePath: ws.path);
      final second = await WorkspaceFileMap.build(workspacePath: ws.path);

      expect(first, second, reason: 'same tree state must render identically');
      expect(first, startsWith('Workspace file map (3 files'));
      // Case-insensitive path order: index.html < src/app.tsx < src/lib/util.ts
      expect(
        first,
        contains(
          '- index.html · 13 B\n- src/app.tsx · 2.0 KB\n'
          '- src/lib/util.ts · 5 B',
        ),
      );
    });

    test('excludes dot segments and scanner noise directories', () async {
      final ws = await _tempWorkspace('wsmap_noise');
      addTearDown(() async => ws.delete(recursive: true));
      await _write(ws, 'visible.txt', 'v');
      await _write(ws, '.env', 'SECRET=1');
      await _write(ws, '.omnichat/cache/x.json', '{}');
      await _write(ws, '.git/config', '[core]');
      await _write(ws, 'node_modules/pkg/index.js', 'm');
      await _write(ws, '__pycache__/mod.pyc', 'c');

      final map = await WorkspaceFileMap.build(workspacePath: ws.path);
      expect(map, contains('visible.txt'));
      expect(map, isNot(contains('.env')));
      expect(map, isNot(contains('.omnichat')));
      expect(map, isNot(contains('.git')));
      expect(map, isNot(contains('node_modules')));
      expect(map, isNot(contains('__pycache__')));
      expect(map, contains('(1 files'));
    });

    test(
      'marks tool-written files and ignores outside-workspace records',
      () async {
        final ws = await _tempWorkspace('wsmap_written');
        addTearDown(() async => ws.delete(recursive: true));
        final outside = await _tempWorkspace('wsmap_outside');
        addTearDown(() async => outside.delete(recursive: true));
        await _write(ws, 'src/generated.md', 'g');

        final map = await WorkspaceFileMap.build(
          workspacePath: ws.path,
          toolWrittenAbsolutePaths: [
            p.join(ws.path, 'src', 'generated.md'),
            p.join(outside.path, 'session_outputs', 'big.png'),
          ],
        );
        expect(map, contains('- src/generated.md · 1 B · agent-written'));
      },
    );

    test(
      'unchanged tree stays byte-identical across mtime-only touches',
      () async {
        final ws = await _tempWorkspace('wsmap_touch');
        addTearDown(() async => ws.delete(recursive: true));
        final file = await _write(ws, 'a.txt', 'stable');

        final before = await WorkspaceFileMap.build(workspacePath: ws.path);

        // mtime-only churn (touch / editor save with identical content).
        await file.writeAsString('stable', flush: true);
        file.setLastModifiedSync(DateTime.now().add(const Duration(hours: 1)));

        final after = await WorkspaceFileMap.build(workspacePath: ws.path);
        expect(after, before, reason: 'cache-prefix contract (plan §2.9.4)');

        // A size-changing rewrite must invalidate the map.
        await file.writeAsString('stable-content-now-longer', flush: true);
        final changed = await WorkspaceFileMap.build(workspacePath: ws.path);
        expect(changed, isNot(before));
        expect(changed, contains('25 B'));
      },
    );

    test('degrades to bare paths and truncates under the token budget', () async {
      final ws = await _tempWorkspace('wsmap_budget');
      addTearDown(() async => ws.delete(recursive: true));
      // 300 moderately long paths: annotated exceeds 1600 tokens (~4800 chars).
      for (var i = 0; i < 300; i++) {
        await _write(ws, 'dir_$i/some_rather_long_file_name_$i.txt', 'x');
      }

      final map = await WorkspaceFileMap.build(workspacePath: ws.path);
      expect(
        estimateTextTokens(map),
        lessThanOrEqualTo(WorkspaceFileMap.tokenCap),
      );
      expect(map, isNot(contains(' · ')), reason: 'stage 2+: sizes dropped');
      expect(map, contains('(+'));
      expect(map, contains('more files not shown'));
      // Header still reports the full tree size.
      expect(map, contains('(300 files'));
      // A monotone prefix: every rendered entry sorts before the first
      // omitted one.
      final entryLines = map
          .split('\n')
          .where((l) => l.startsWith('- '))
          .toList();
      expect(entryLines, isNotEmpty);
      expect(map.indexOf('(+'), greaterThan(map.indexOf(entryLines.last)));
    });

    test(
      'enforces the hard render cap even when under the token budget',
      () async {
        final ws = await _tempWorkspace('wsmap_cap');
        addTearDown(() async => ws.delete(recursive: true));
        // 250 tiny files would fit the 1600-token budget bare, but only
        // maxEntries (200) may ever render.
        for (var i = 0; i < 250; i++) {
          await _write(ws, 'f_$i.txt', 'x');
        }

      final map = await WorkspaceFileMap.build(workspacePath: ws.path);
      expect(map, contains('(250 files'));
      expect(map, contains('(+50 more files not shown)'));
      final renderedEntries = map
          .split('\n')
          .where((line) => line.startsWith('- '))
          .length;
      expect(renderedEntries, WorkspaceFileMap.maxEntries);
      },
    );

    test('map paths are consistent with the file_list tool output', () async {
      final ws = await _tempWorkspace('wsmap_flist');
      addTearDown(() async => ws.delete(recursive: true));
      await _write(ws, 'index.html', 'i');
      await _write(ws, 'src/app.tsx', 'a');
      await _write(ws, 'src/lib/util.ts', 'u');

      final map = await WorkspaceFileMap.build(workspacePath: ws.path);
      final listed = await FileToolService.execute('file_list', {
        'path': '',
      }, ws.path);

      // file_list lists the top level; every map entry's first segment must
      // appear there.
      final listedNames = listed.text
          .split('\n')
          .map((l) => l.replaceFirst(RegExp(r'^\[(dir|file)\] '), ''))
          .toSet();
      for (final line in map.split('\n')) {
        if (!line.startsWith('- ')) continue;
        final path = line.substring(2).split(' · ').first;
        final topSegment = path.contains('/') ? path.split('/').first : path;
        expect(
          listedNames,
          contains(topSegment),
          reason: 'map entry "$path" not discoverable via file_list',
        );
      }
    });
  });
}
