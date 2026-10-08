import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/core/models/skill.dart';
import 'package:OmniChat/core/services/skills/skill_parser.dart';
import 'package:OmniChat/core/services/skills/skill_service.dart';

void main() {
  late Directory globalRoot;
  late Directory projectRoot;

  Future<void> writeSkill(
    Directory root,
    String name,
    String description, {
    String? content,
    Map<String, String> extra = const {},
  }) async {
    final dir = Directory('${root.path}/$name')
      ..createSync(recursive: true);
    File('${dir.path}/SKILL.md').writeAsStringSync(
      content ??
          '---\nname: $name\ndescription: $description\n---\n\n# $name\n',
    );
    for (final e in extra.entries) {
      final f = File('${dir.path}/${e.key}');
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(e.value);
    }
  }

  setUp(() async {
    globalRoot = await Directory.systemTemp.createTemp('skills_global_');
    projectRoot = await Directory.systemTemp.createTemp('skills_project_');
  });

  tearDown(() async {
    if (await globalRoot.exists()) await globalRoot.delete(recursive: true);
    if (await projectRoot.exists()) await projectRoot.delete(recursive: true);
  });

  group('loadSkills', () {
    test('discovers skills from the global root', () {
      writeSkill(globalRoot, 'git-release', 'Release tooling');
      writeSkill(globalRoot, 'api-design', 'API review');
      final skills = SkillService.loadSkills(globalRoot: globalRoot.path);
      expect(skills.keys.toSet(), {'git-release', 'api-design'});
      expect(skills['git-release']!.scope, SkillScope.global);
    });

    test('skips folders with invalid names', () {
      Directory('${globalRoot.path}/Bad-Name').createSync();
      Directory('${globalRoot.path}/.hidden').createSync();
      File('${globalRoot.path}/loose.md').writeAsStringSync('x');
      final skills = SkillService.loadSkills(globalRoot: globalRoot.path);
      expect(skills, isEmpty);
    });

    test('skips folders without SKILL.md', () {
      Directory('${globalRoot.path}/empty-skill').createSync();
      expect(
        SkillService.loadSkills(globalRoot: globalRoot.path),
        isEmpty,
      );
    });

    test('accepts case-insensitive skill.md filename', () {
      final dir = Directory('${globalRoot.path}/git-release')
        ..createSync(recursive: true);
      File('${dir.path}/skill.md').writeAsStringSync(
        '---\nname: git-release\ndescription: d\n---\n',
      );
      final skills = SkillService.loadSkills(globalRoot: globalRoot.path);
      expect(skills, hasLength(1));
    });

    test('project scope overrides global on name collision', () {
      writeSkill(globalRoot, 'git-release', 'global description');
      final wsSkills = Directory('${projectRoot.path}/.agents/skills')
        ..createSync(recursive: true);
      final dir = Directory('${wsSkills.path}/git-release')
        ..createSync(recursive: true);
      File('${dir.path}/SKILL.md').writeAsStringSync(
        '---\nname: git-release\ndescription: project description\n---\n',
      );
      final skills = SkillService.loadSkills(
        globalRoot: globalRoot.path,
        projectRoot: '${projectRoot.path}/.agents/skills',
      );
      expect(skills['git-release']!.description, 'project description');
      expect(skills['git-release']!.scope, SkillScope.project);
    });

    test('skillsForContext with null workspace loads global only', () {
      writeSkill(globalRoot, 'git-release', 'global');
      writeSkill(projectRoot, 'git-release', 'project');
      final skills = SkillService.skillsForContext(
        workspacePath: null,
        globalRoot: globalRoot.path,
      );
      expect(skills['git-release']!.scope, SkillScope.global);
    });

    test('skillsForContext resolves the project subfolder', () {
      final wsSkills = Directory('${projectRoot.path}/.agents/skills')
        ..createSync(recursive: true);
      final dir = Directory('${wsSkills.path}/git-release')
        ..createSync(recursive: true);
      File('${dir.path}/SKILL.md').writeAsStringSync(
        '---\nname: git-release\ndescription: from workspace\n---\n',
      );
      final skills = SkillService.skillsForContext(
        workspacePath: projectRoot.path,
        globalRoot: globalRoot.path,
      );
      expect(skills['git-release']!.description, 'from workspace');
    });

    test('tolerates missing roots', () {
      final skills = SkillService.loadSkills(
        globalRoot: '${globalRoot.path}/nope',
        projectRoot: '${projectRoot.path}/nope',
      );
      expect(skills, isEmpty);
    });
  });

  group('loadSkillByName', () {
    test('reads fresh from disk (project priority)', () {
      writeSkill(globalRoot, 'git-release', 'global version');
      final wsSkills = Directory('${projectRoot.path}/.agents/skills')
        ..createSync(recursive: true);
      final dir = Directory('${wsSkills.path}/git-release')
        ..createSync(recursive: true);
      File('${dir.path}/SKILL.md').writeAsStringSync(
        '---\nname: git-release\ndescription: project version\n---\n',
      );
      final skill = SkillService.loadSkillByName(
        'git-release',
        workspacePath: projectRoot.path,
        globalRoot: globalRoot.path,
      );
      expect(skill!.description, 'project version');
    });

    test('returns null for unknown names', () {
      expect(
        SkillService.loadSkillByName(
          'nope',
          workspacePath: null,
          globalRoot: globalRoot.path,
        ),
        isNull,
      );
    });
  });

  group('formatAvailableSkillsXml', () {
    test('renders escaped XML sorted by name', () {
      writeSkill(globalRoot, 'zz-skill', 'Last & <special>');
      writeSkill(globalRoot, 'aa-skill', 'First "quoted"');
      final skills = SkillService.loadSkills(globalRoot: globalRoot.path);
      final xml = SkillService.formatAvailableSkillsXml(skills);
      expect(xml, startsWith('<available_skills>'));
      expect(xml.indexOf('aa-skill'), lessThan(xml.indexOf('zz-skill')));
      expect(xml, contains('First &quot;quoted&quot;'));
      expect(xml, contains('Last &amp; &lt;special&gt;'));
    });

    test('hides disable-model-invocation skills', () {
      writeSkill(
        globalRoot,
        'hidden-skill',
        'secret',
        content: '---\nname: hidden-skill\ndescription: secret\ndisable-model-invocation: true\n---\n',
      );
      writeSkill(globalRoot, 'open-skill', 'visible');
      final skills = SkillService.loadSkills(globalRoot: globalRoot.path);
      final xml = SkillService.formatAvailableSkillsXml(skills);
      expect(xml, contains('open-skill'));
      expect(xml, isNot(contains('hidden-skill')));
    });

    test('returns empty string for no visible skills', () {
      expect(
        SkillService.formatAvailableSkillsXml(const {}),
        '',
      );
    });
  });

  group('installSkill', () {
    test('creates the folder and writes a stamped SKILL.md', () async {
      final result = await SkillService.installSkill(
        name: 'test-skill',
        content: '---\nname: test-skill\ndescription: d\n---\n\nBody\n',
        globalRoot: globalRoot.path,
      );
      expect(result.ok, isTrue);
      final file = File('${globalRoot.path}/test-skill/SKILL.md');
      expect(file.existsSync(), isTrue);
      final written = file.readAsStringSync();
      expect(written, contains('metadata:'));
      expect(written, contains('source: manual'));
      expect(written, contains('installedAt:'));
    });

    test('rejects invalid names', () async {
      final result = await SkillService.installSkill(
        name: 'Bad Name',
        content: '---\nname: bad\ndescription: d\n---\n',
        globalRoot: globalRoot.path,
      );
      expect(result.ok, isFalse);
      expect(result.error, 'invalid_name');
    });

    test('rejects name/content mismatch', () async {
      final result = await SkillService.installSkill(
        name: 'test-skill',
        content: '---\nname: other\ndescription: d\n---\n',
        globalRoot: globalRoot.path,
      );
      expect(result.ok, isFalse);
      expect(result.error, 'invalid_skill');
    });

    test('exists gate requires confirm', () async {
      writeSkill(globalRoot, 'test-skill', 'original');
      final first = await SkillService.installSkill(
        name: 'test-skill',
        content: '---\nname: test-skill\ndescription: new\n---\n',
        globalRoot: globalRoot.path,
      );
      expect(first.ok, isFalse);
      expect(first.exists, isTrue);

      final second = await SkillService.installSkill(
        name: 'test-skill',
        content: '---\nname: test-skill\ndescription: new\n---\n',
        confirm: true,
        globalRoot: globalRoot.path,
      );
      expect(second.ok, isTrue);
      expect(second.skill!.description, 'new');
    });

    test('empty folder does not trigger the exists gate', () async {
      Directory('${globalRoot.path}/test-skill').createSync(recursive: true);
      final result = await SkillService.installSkill(
        name: 'test-skill',
        content: '---\nname: test-skill\ndescription: d\n---\n',
        globalRoot: globalRoot.path,
      );
      expect(result.ok, isTrue);
    });
  });

  group('installSkillMulti', () {
    test('installs the whole folder', () async {
      final result = await SkillService.installSkillMulti(
        name: 'test-skill',
        files: {
          'SKILL.md': '---\nname: test-skill\ndescription: d\n---\n\nb\n',
          'references/extra.md': 'attachment',
        },
        globalRoot: globalRoot.path,
      );
      expect(result.ok, isTrue);
      expect(
        File('${globalRoot.path}/test-skill/references/extra.md')
            .existsSync(),
        isTrue,
      );
      expect(result.skill!.fileCount, 2);
    });

    test('missing SKILL.md is rejected', () async {
      final result = await SkillService.installSkillMulti(
        name: 'test-skill',
        files: {'README.md': 'x'},
        globalRoot: globalRoot.path,
      );
      expect(result.error, 'missing_skill_md');
    });

    test('unsafe relative paths abort the whole install', () async {
      final result = await SkillService.installSkillMulti(
        name: 'test-skill',
        files: {
          'SKILL.md': '---\nname: test-skill\ndescription: d\n---\n',
          '../escape.txt': 'x',
        },
        globalRoot: globalRoot.path,
      );
      expect(result.ok, isFalse);
      expect(result.error, contains('unsafe_path'));
      expect(
        File('${globalRoot.path}/escape.txt').existsSync(),
        isFalse,
      );
      // Pre-validation must run before createTemp — an early return after
      // it would leak a `.{name}_install_*` directory into the root.
      final residue = globalRoot
          .listSync()
          .map((e) => e.path.split(Platform.pathSeparator).last)
          .where((n) =>
              n.startsWith('.') &&
              (n.contains('_install_') || n.contains('_old_')))
          .toList();
      expect(residue, isEmpty);
    });

    test('overwrite with confirm replaces atomically (no stale backup left)',
        () async {
      writeSkill(globalRoot, 'test-skill', 'old',
          extra: {'references/old.md': 'old attachment'});
      final result = await SkillService.installSkillMulti(
        name: 'test-skill',
        files: {
          'SKILL.md': '---\nname: test-skill\ndescription: new\n---\n',
          'references/new.md': 'new attachment',
        },
        confirm: true,
        globalRoot: globalRoot.path,
      );
      expect(result.ok, isTrue);
      expect(
        File('${globalRoot.path}/test-skill/references/new.md').existsSync(),
        isTrue,
      );
      expect(
        File('${globalRoot.path}/test-skill/references/old.md').existsSync(),
        isFalse,
      );
      // No temp/backup folders left behind.
      final leftovers = globalRoot
          .listSync()
          .where((e) => e.path.contains('_install_') || e.path.contains('_old_'))
          .toList();
      expect(leftovers, isEmpty);
    });
  });

  group('deleteSkill', () {
    test('refuses on desktop (notSupported)', () async {
      writeSkill(globalRoot, 'test-skill', 'd');
      final result = await SkillService.deleteSkill(
        'test-skill',
        mobilePlatform: false,
        globalRoot: globalRoot.path,
      );
      expect(result.ok, isFalse);
      expect(result.error, 'notSupported');
      expect(
        Directory('${globalRoot.path}/test-skill').existsSync(),
        isTrue,
      );
    });

    test('deletes on mobile', () async {
      writeSkill(globalRoot, 'test-skill', 'd');
      final result = await SkillService.deleteSkill(
        'test-skill',
        mobilePlatform: true,
        globalRoot: globalRoot.path,
      );
      expect(result.ok, isTrue);
      expect(Directory('${globalRoot.path}/test-skill').existsSync(), isFalse);
    });

    test('refuses path traversal and non-skill folders', () async {
      final traversal = await SkillService.deleteSkill(
        '..',
        mobilePlatform: true,
        globalRoot: globalRoot.path,
      );
      expect(traversal.ok, isFalse);

      Directory('${globalRoot.path}/not-a-skill').createSync();
      final notSkill = await SkillService.deleteSkill(
        'not-a-skill',
        mobilePlatform: true,
        globalRoot: globalRoot.path,
      );
      expect(notSkill.error, 'not_a_skill');
    });
  });

  group('importSkillFile', () {
    test('imports a bare SKILL.md as a single file', () async {
      final src = File('${projectRoot.path}/skill.md')
        ..writeAsStringSync('---\nname: imported-skill\ndescription: d\n---\n');
      final result = await SkillService.importSkillFile(
        sourcePath: src.path,
        globalRoot: globalRoot.path,
      );
      expect(result.ok, isTrue);
      expect(result.skill!.source, SkillInstallSource.file);
      expect(
        Directory('${globalRoot.path}/imported-skill').existsSync(),
        isTrue,
      );
    });

    test('folder-aware import asks for confirmation first', () async {
      final skillDir = Directory('${projectRoot.path}/imported-skill')
        ..createSync(recursive: true);
      final src = File('${skillDir.path}/SKILL.md')
        ..writeAsStringSync('---\nname: imported-skill\ndescription: d\n---\n');
      final refs = Directory('${skillDir.path}/references')
        ..createSync(recursive: true);
      File('${refs.path}/a.md').writeAsStringSync('a');

      final probe = await SkillService.importSkillFile(
        sourcePath: src.path,
        globalRoot: globalRoot.path,
      );
      expect(probe.folderConfirm, isTrue);
      // The picked document itself is not an attachment — only what comes
      // with it is listed (the dialog counts "files next to the SKILL.md").
      expect(probe.folderFiles, ['references/a.md']);

      final confirm = await SkillService.importSkillFile(
        sourcePath: src.path,
        confirmFolder: true,
        globalRoot: globalRoot.path,
      );
      expect(confirm.ok, isTrue);
      expect(
        File('${globalRoot.path}/imported-skill/references/a.md').existsSync(),
        isTrue,
      );
    });

    test('rejects files without a valid name', () async {
      final src = File('${projectRoot.path}/bad.md')
        ..writeAsStringSync('no frontmatter');
      final result = await SkillService.importSkillFile(
        sourcePath: src.path,
        globalRoot: globalRoot.path,
      );
      expect(result.error, 'invalid_skill');
    });

    test('folder import does not require folder name == skill name', () async {
      // A downloaded zip unpacks into `my-skill-main/`; the old
      // folder-name gate silently installed the SKILL.md alone.
      final skillDir = Directory('${projectRoot.path}/my-skill-main')
        ..createSync(recursive: true);
      final src = File('${skillDir.path}/SKILL.md')
        ..writeAsStringSync('---\nname: my-skill\ndescription: d\n---\n');
      final refs = Directory('${skillDir.path}/references')
        ..createSync(recursive: true);
      File('${refs.path}/a.md').writeAsStringSync('a');

      final probe = await SkillService.importSkillFile(
        sourcePath: src.path,
        globalRoot: globalRoot.path,
      );
      expect(probe.folderConfirm, isTrue);
      expect(probe.folderFiles, ['references/a.md']);

      final confirm = await SkillService.importSkillFile(
        sourcePath: src.path,
        confirmFolder: true,
        globalRoot: globalRoot.path,
      );
      expect(confirm.ok, isTrue, reason: confirm.error);
      expect(confirm.skill!.name, 'my-skill');
      expect(
        File('${globalRoot.path}/my-skill/references/a.md').readAsStringSync(),
        'a',
      );
    });

    test('binary attachments are installed byte-for-byte', () async {
      final skillDir = Directory('${projectRoot.path}/img-skill')
        ..createSync(recursive: true);
      final src = File('${skillDir.path}/SKILL.md')
        ..writeAsStringSync('---\nname: img-skill\ndescription: d\n---\n');
      final png = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0xFF];
      File('${skillDir.path}/logo.png').writeAsBytesSync(png);
      // Python/version-control noise must never travel with the skill.
      final cache = Directory('${skillDir.path}/__pycache__')..createSync();
      File('${cache.path}/mod.pyc').writeAsBytesSync(<int>[0x00, 0xFF]);

      final confirm = await SkillService.importSkillFile(
        sourcePath: src.path,
        confirmFolder: true,
        globalRoot: globalRoot.path,
      );
      expect(confirm.ok, isTrue, reason: confirm.error);
      expect(
        File('${globalRoot.path}/img-skill/logo.png').readAsBytesSync(),
        png,
        reason: 'a non-UTF-8 attachment used to be dropped after confirm',
      );
      expect(
        Directory('${globalRoot.path}/img-skill/__pycache__').existsSync(),
        isFalse,
      );
    });

    test('skipFolder imports only the picked document', () async {
      final skillDir = Directory('${projectRoot.path}/solo-skill')
        ..createSync(recursive: true);
      final src = File('${skillDir.path}/SKILL.md')
        ..writeAsStringSync('---\nname: solo-skill\ndescription: d\n---\n');
      File('${skillDir.path}/notes.md').writeAsStringSync('notes');

      final result = await SkillService.importSkillFile(
        sourcePath: src.path,
        skipFolder: true,
        globalRoot: globalRoot.path,
      );
      expect(result.ok, isTrue, reason: result.error);
      expect(result.skill!.fileCount, 1);
      expect(
        File('${globalRoot.path}/solo-skill/notes.md').existsSync(),
        isFalse,
      );
    });

    test('folder import is desktop-only (flattened mobile picks stay single)',
        () async {
      final skillDir = Directory('${projectRoot.path}/mobile-skill')
        ..createSync(recursive: true);
      final src = File('${skillDir.path}/SKILL.md')
        ..writeAsStringSync('---\nname: mobile-skill\ndescription: d\n---\n');
      // A second pick cached in the same flattened picker directory.
      File('${skillDir.path}/other-skill.md').writeAsStringSync(
        '---\nname: other-skill\ndescription: d\n---\n',
      );

      SkillService.debugFolderImportOverride = false; // simulate mobile
      addTearDown(() => SkillService.debugFolderImportOverride = null);

      final result = await SkillService.importSkillFile(
        sourcePath: src.path,
        globalRoot: globalRoot.path,
      );
      expect(result.folderConfirm, isFalse);
      expect(result.ok, isTrue, reason: result.error);
      expect(result.skill!.fileCount, 1);
      expect(
        File('${globalRoot.path}/mobile-skill/other-skill.md').existsSync(),
        isFalse,
        reason: 'another cached pick must never travel with this skill',
      );
    });

    test('a picked my-skill.md inside a folder becomes SKILL.md', () async {
      final skillDir = Directory('${projectRoot.path}/renamed-skill')
        ..createSync(recursive: true);
      final src = File('${skillDir.path}/my-skill.md')
        ..writeAsStringSync('---\nname: renamed-skill\ndescription: d\n---\n');
      File('${skillDir.path}/extra.md').writeAsStringSync('extra');

      final result = await SkillService.importSkillFile(
        sourcePath: src.path,
        confirmFolder: true,
        globalRoot: globalRoot.path,
      );
      expect(result.ok, isTrue, reason: result.error);
      expect(
        File('${globalRoot.path}/renamed-skill/SKILL.md').existsSync(),
        isTrue,
      );
      expect(
        File('${globalRoot.path}/renamed-skill/extra.md').readAsStringSync(),
        'extra',
      );
    });
  });

  group('isSafeRelPath', () {
    test('accepts normal relative paths', () {
      expect(SkillService.isSafeRelPath('SKILL.md'), isTrue);
      expect(SkillService.isSafeRelPath('references/a.md'), isTrue);
    });

    test('rejects traversal, absolute, backslash and ADS paths', () {
      expect(SkillService.isSafeRelPath('../x'), isFalse);
      expect(SkillService.isSafeRelPath('/abs'), isFalse);
      expect(SkillService.isSafeRelPath('a\\b'), isFalse);
      expect(SkillService.isSafeRelPath('a:b'), isFalse);
      expect(SkillService.isSafeRelPath(''), isFalse);
      expect(SkillService.isSafeRelPath('.'), isFalse);
    });
  });

  group('countSkillFiles', () {
    test('counts nested files, skipping .git and node_modules', () {
      writeSkill(globalRoot, 'test-skill', 'd', extra: {
        'references/a.md': 'a',
        'scripts/run.py': 'b',
        '.git/config': 'c',
        'node_modules/pkg/index.js': 'd',
      });
      final count = SkillService.countSkillFiles(
        '${globalRoot.path}/test-skill',
      );
      expect(count, 3); // SKILL.md + references/a.md + scripts/run.py
    });
  });

  group('stampProvenance', () {
    test('adds metadata to a doc without one', () {
      final stamped = SkillService.stampProvenance(
        '---\nname: a\ndescription: d\n---\n\nbody\n',
        SkillInstallSource.github,
      );
      expect(stamped, contains('metadata:'));
      expect(stamped, contains('source: github'));
      expect(stamped, contains('installedAt:'));
      // Rest of the document unchanged.
      expect(stamped, contains('name: a\ndescription: d'));
      expect(stamped.endsWith('body\n'), isTrue);
    });

    test('updates an existing metadata block', () {
      final stamped = SkillService.stampProvenance(
        '---\nname: a\ndescription: d\nmetadata:\n  source: manual\n  installedAt: old\n---\n\nbody\n',
        SkillInstallSource.file,
      );
      expect(stamped, contains('source: file'));
      expect(stamped, isNot(contains('source: manual')));
      expect(SkillParser.parseMetadataBlock(stamped)['installedAt'],
          isNot('old'));
    });

    test('never throws on malformed input', () {
      final stamped = SkillService.stampProvenance(
        'not frontmatter at all',
        SkillInstallSource.manual,
      );
      expect(stamped, 'not frontmatter at all');
    });
  });

  group('containment', () {
    test('isInsideRoot semantics enforced through deleteSkill', () async {
      // A name that would resolve outside the root can never pass the name
      // regex, but the containment check is exercised via a crafted root.
      final result = await SkillService.deleteSkill(
        'test-skill',
        mobilePlatform: true,
        globalRoot: '${globalRoot.path}/sub',
      );
      expect(result.ok, isFalse); // nothing there → not_a_skill
    });
  });
}
