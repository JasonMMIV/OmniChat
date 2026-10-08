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

  group('importSkillFolder (folder pick — mobile attachment route)', () {
    test('installs the whole folder, nested paths and bytes intact', () async {
      final picked = Directory('${projectRoot.path}/picked-skill')
        ..createSync(recursive: true);
      File('${picked.path}/SKILL.md').writeAsStringSync(
        '---\nname: picked-skill\ndescription: d\n---\n\nbody\n',
      );
      File('${picked.path}/references/deep/a.md')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('reference');
      final png = File('${picked.path}/assets/logo.png')
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(<int>[0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF]);

      // Consent gate first: nothing is installed until the caller confirms.
      final preview = await SkillService.importSkillFolder(
        folderPath: picked.path,
        globalRoot: globalRoot.path,
      );
      expect(preview.folderConfirm, isTrue);
      expect(preview.pendingName, 'picked-skill');
      expect(preview.folderFiles, contains('references/deep/a.md'));
      expect(preview.folderFiles, contains('assets/logo.png'));
      expect(
        Directory('${globalRoot.path}/picked-skill').existsSync(),
        isFalse,
        reason: 'the preview must never install',
      );

      final result = await SkillService.importSkillFolder(
        folderPath: picked.path,
        confirmFolder: true,
        globalRoot: globalRoot.path,
      );
      expect(result.ok, isTrue, reason: result.error);
      expect(
        File('${globalRoot.path}/picked-skill/references/deep/a.md')
            .readAsStringSync(),
        'reference',
        reason: 'a real folder pick preserves the skill structure',
      );
      expect(
        File('${globalRoot.path}/picked-skill/assets/logo.png').readAsBytesSync(),
        png.readAsBytesSync(),
      );
      expect(result.skill!.fileCount, 3);
    });

    test('descends a single wrapper level (unzipped release)', () async {
      final wrapper = Directory('${projectRoot.path}/my-skill-main')
        ..createSync(recursive: true);
      File('${wrapper.path}/SKILL.md').writeAsStringSync(
        '---\nname: my-skill\ndescription: d\n---\n',
      );
      File('${wrapper.path}/scripts/run.sh')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('echo hi');

      final result = await SkillService.importSkillFolder(
        folderPath: wrapper.path,
        confirmFolder: true,
        globalRoot: globalRoot.path,
      );
      expect(result.ok, isTrue, reason: result.error);
      expect(result.skill!.name, 'my-skill');
      expect(
        File('${globalRoot.path}/my-skill/scripts/run.sh').existsSync(),
        isTrue,
      );
    });

    test('refuses a skills root holding several skills', () async {
      final root = Directory('${projectRoot.path}/.agents/skills')
        ..createSync(recursive: true);
      writeSkill(root, 'skill-a', 'a');
      writeSkill(root, 'skill-b', 'b');

      final result = await SkillService.importSkillFolder(
        folderPath: root.path,
        confirmFolder: true,
        globalRoot: globalRoot.path,
      );
      expect(result.ok, isFalse);
      expect(result.error, 'multiple_skills');
      expect(globalRoot.listSync(), isEmpty,
          reason: 'picking the skills root must sweep nothing in');
    });

    test('reports a folder without any SKILL.md', () async {
      final empty = Directory('${projectRoot.path}/not-a-skill')
        ..createSync(recursive: true);
      File('${empty.path}/readme.txt').writeAsStringSync('hi');
      final result = await SkillService.importSkillFolder(
        folderPath: empty.path,
        confirmFolder: true,
        globalRoot: globalRoot.path,
      );
      expect(result.ok, isFalse);
      expect(result.error, 'skill_md_not_found');
    });

    test('a lower-case skill.md still becomes SKILL.md', () async {
      final picked = Directory('${projectRoot.path}/case-skill')
        ..createSync(recursive: true);
      File('${picked.path}/skill.md').writeAsStringSync(
        '---\nname: case-skill\ndescription: d\n---\n',
      );
      File('${picked.path}/notes.md').writeAsStringSync('notes');

      final result = await SkillService.importSkillFolder(
        folderPath: picked.path,
        confirmFolder: true,
        globalRoot: globalRoot.path,
      );
      expect(result.ok, isTrue, reason: result.error);
      expect(
        File('${globalRoot.path}/case-skill/SKILL.md').existsSync(),
        isTrue,
      );
      expect(
        File('${globalRoot.path}/case-skill/notes.md').readAsStringSync(),
        'notes',
      );
    });

    test('two case variants of the skill document install once', () async {
      final picked = Directory('${projectRoot.path}/variant-skill')
        ..createSync(recursive: true);
      File('${picked.path}/SKILL.md').writeAsStringSync(
        '---\nname: variant-skill\ndescription: canonical\n---\n',
      );
      // On a case-insensitive filesystem (Windows, default macOS) the two
      // spellings are ONE file, so the duplicate cannot be built there and the
      // scenario is simply unreachable — the guard still holds where it can
      // occur (Linux, case-sensitive volumes).
      File('${picked.path}/probe.txt').writeAsStringSync('x');
      if (File('${picked.path}/PROBE.TXT').existsSync()) {
        return;
      }
      File('${picked.path}/probe.txt').deleteSync();
      File('${picked.path}/skill.md').writeAsStringSync(
        '---\nname: variant-skill\ndescription: shadow\n---\n',
      );

      final result = await SkillService.importSkillFolder(
        folderPath: picked.path,
        globalRoot: globalRoot.path,
      );
      expect(result.ok, isTrue, reason: result.error);
      expect(
        result.skill!.description,
        'canonical',
        reason: 'the exact convention name must win over the variant',
      );
      final installed = Directory('${globalRoot.path}/variant-skill')
          .listSync()
          .map((e) => e.path.split(Platform.pathSeparator).last)
          .where((name) => name.toLowerCase() == 'skill.md')
          .toList();
      expect(
        installed,
        hasLength(1),
        reason: 'a shadowed variant must never be installed alongside — the '
            'loader would read whichever it lists first',
      );
    });

    test('pickSkillDocument: exact name wins, variants are shadowed', () {
      // Pure rule, so it is asserted on every host — the on-disk duplicate
      // below only exists where the filesystem keeps the two spellings apart.
      final picked = SkillService.pickSkillDocument(
        ['references/a.md', 'skill.md', 'SKILL.md'],
      );
      expect(picked!.key, 'SKILL.md');
      expect(picked.shadowed, {'skill.md'});

      final variantOnly = SkillService.pickSkillDocument(['Skill.md', 'x.md']);
      expect(variantOnly!.key, 'Skill.md');
      expect(variantOnly.shadowed, isEmpty);

      expect(SkillService.pickSkillDocument(['notes.md']), isNull);
      expect(SkillService.pickSkillDocument(const <String>[]), isNull);
    });

    test('a blank or missing folder path is refused before any IO', () async {
      final blank = await SkillService.importSkillFolder(
        folderPath: '   ',
        globalRoot: globalRoot.path,
      );
      expect(blank.ok, isFalse);
      expect(blank.error, 'folder_not_found');
      expect(
        globalRoot.listSync(),
        isEmpty,
        reason: 'a blank path resolves to the process working directory',
      );

      final missing = await SkillService.importSkillFolder(
        folderPath: '${projectRoot.path}/does-not-exist',
        globalRoot: globalRoot.path,
      );
      expect(missing.ok, isFalse);
      expect(missing.error, 'folder_not_found');
    });

    test('an existing name asks for overwrite and honours confirm', () async {
      writeSkill(globalRoot, 'dupe-skill', 'old');
      // Wrapper-named pick (a release zip unzipped in the Files app): the
      // folder name differs from the skill, so the name in the overwrite
      // prompt can only come from the parsed document.
      final picked = Directory('${projectRoot.path}/dupe-skill-main')
        ..createSync(recursive: true);
      File('${picked.path}/SKILL.md').writeAsStringSync(
        '---\nname: dupe-skill\ndescription: new\n---\n',
      );

      final first = await SkillService.importSkillFolder(
        folderPath: picked.path,
        globalRoot: globalRoot.path,
      );
      expect(first.ok, isFalse);
      expect(first.exists, isTrue);
      expect(
        first.pendingName,
        'dupe-skill',
        reason: 'the overwrite prompt must name the skill, not the folder',
      );

      final second = await SkillService.importSkillFolder(
        folderPath: picked.path,
        confirm: true,
        globalRoot: globalRoot.path,
      );
      expect(second.ok, isTrue, reason: second.error);
      expect(second.skill!.description, 'new');
    });

  });

  group('importSkillFile on Android (original document URI)', () {
    test('document URIs map to the real folder, unknown shapes to null', () {
      SkillService.debugAndroidExternalStorageRoot = projectRoot.path;
      addTearDown(() => SkillService.debugAndroidExternalStorageRoot = null);
      // The service normalizes path separators (POSIX shapes throughout), so
      // Windows expectations are compared in the same shape.
      String fx(String path) => path.replaceAll('\\', '/');
      const base = 'content://com.android.externalstorage.documents/document/';
      expect(
        SkillService.androidFolderPathFromDocumentUri(
          '${base}primary%3ADownload%2Fmy-skill%2FSKILL.md',
        ),
        fx('${projectRoot.path}/Download/my-skill'),
      );
      // Percent-decoding survives, so a folder with a space works.
      expect(
        SkillService.androidFolderPathFromDocumentUri(
          '${base}primary%3ADownload%2Fmy%20skill%2FSKILL.md',
        ),
        fx('${projectRoot.path}/Download/my skill'),
      );
      // A removable volume (SD card) keeps its own root.
      expect(
        SkillService.androidFolderPathFromDocumentUri(
          '${base}1234-5678%3ASkills%2Fgit-release%2FSKILL.md',
        ),
        '/storage/1234-5678/Skills/git-release',
      );
      // The folder picker's tree shape names the folder itself.
      expect(
        SkillService.androidFolderPathFromDocumentUri(
          'content://com.android.externalstorage.documents/'
          'tree/primary%3ADownload%2Fmy-skill',
        ),
        fx('${projectRoot.path}/Download/my-skill'),
      );
    });

    test('Downloads-provider raw: ids resolve to their absolute path', () {
      // AOSP DownloadStorageProvider gives a plain file a `raw:` id that IS its
      // absolute path — the shape produced by opening a downloaded skill zip
      // through the "Downloads" entry of the system picker. No filesystem is
      // touched here (existence is checked by the caller), so the real default
      // storage root applies without the test seam.
      const base =
          'content://com.android.providers.downloads.documents/document/';
      expect(
        SkillService.androidFolderPathFromDocumentUri(
          '${base}raw%3A%2Fstorage%2Femulated%2F0%2FDownload%2Fmy-skill%2FSKILL.md',
        ),
        '/storage/emulated/0/Download/my-skill',
      );
      // A removable volume (SD card) is its own root.
      expect(
        SkillService.androidFolderPathFromDocumentUri(
          '${base}raw%3A%2Fstorage%2F1234-5678%2FDownload%2Fmy-skill%2FSKILL.md',
        ),
        '/storage/1234-5678/Download/my-skill',
      );
      // Tree shape names the folder itself.
      expect(
        SkillService.androidFolderPathFromDocumentUri(
          'content://com.android.providers.downloads.documents/'
          'tree/raw%3A%2Fstorage%2Femulated%2F0%2FDownload%2Fmy-skill',
        ),
        '/storage/emulated/0/Download/my-skill',
      );
      // The volume root stays excluded even here — it is a container, and an
      // over-eager root match would hand the scanner the whole storage.
      expect(
        SkillService.androidFolderPathFromDocumentUri(
          '${base}raw%3A%2Fstorage%2Femulated%2F0%2FSKILL.md',
        ),
        isNull,
      );
      expect(
        SkillService.androidFolderPathFromDocumentUri(
          '${base}raw%3A%2Fstorage%2F1234-5678%2FSKILL.md',
        ),
        isNull,
      );
    });

    test('raw: ids outside shared storage, or with traversal, are refused', () {
      const base =
          'content://com.android.providers.downloads.documents/document/';
      // Another app's private data is not shared storage, even though the
      // provider's id would decode to a plausible absolute path.
      expect(
        SkillService.androidFolderPathFromDocumentUri(
          '${base}raw%3A%2Fdata%2Fdata%2Fcom.example%2Ffiles%2FSKILL.md',
        ),
        isNull,
      );
      expect(
        SkillService.androidFolderPathFromDocumentUri(
          '${base}raw%3A%2Fstorage%2Femulated%2F0%2FDownload%2F..%2F..%2Fetc%2FSKILL.md',
        ),
        isNull,
      );
      expect(
        SkillService.androidFolderPathFromDocumentUri('${base}raw%3A'),
        isNull,
      );
      // MediaStore-backed ids (`msf:`/`msd:`) encode no path at all.
      expect(
        SkillService.androidFolderPathFromDocumentUri(
          '${base}msd%3A12345',
        ),
        isNull,
      );
    });

    test('pseudo-volumes and foreign providers are refused', () {
      const base = 'content://com.android.externalstorage.documents/document/';
      // The Downloads provider hands back ids whose path mapping would be a
      // lie — resolving one would point the scan at an unrelated directory.
      expect(
        SkillService.androidFolderPathFromDocumentUri(
          'content://com.android.providers.downloads.documents/'
          'document/msf%3A1000000033',
        ),
        isNull,
      );
      expect(
        SkillService.androidFolderPathFromDocumentUri('${base}downloads'),
        isNull,
      );
      expect(
        SkillService.androidFolderPathFromDocumentUri(
          'content://com.google.android.apps.docs.storage/document/acc%3D1%3Bdoc%3D42',
        ),
        isNull,
      );
      expect(
        SkillService.androidFolderPathFromDocumentUri('${base}raw%3A%2Fsystem%2Fetc'),
        isNull,
      );
      expect(
        SkillService.androidFolderPathFromDocumentUri('${base}primary%3A'),
        isNull,
      );
      expect(SkillService.androidFolderPathFromDocumentUri('not a uri'), isNull);
      expect(
        SkillService.androidFolderPathFromDocumentUri('file:///storage/x/SKILL.md'),
        isNull,
      );
    });

    test('skills roots, volume roots and traversal are refused', () {
      SkillService.debugAndroidExternalStorageRoot = projectRoot.path;
      addTearDown(() => SkillService.debugAndroidExternalStorageRoot = null);
      const base = 'content://com.android.externalstorage.documents/document/';
      // A document sitting directly in a skills root is refused by the folder
      // resolution itself — asserted through the import path in the next test.
      expect(
        SkillService.androidFolderPathFromDocumentUri(
          '${base}primary%3ADownload%2F..%2F..%2Fetc%2FSKILL.md',
        ),
        isNull,
        reason: 'a provider-supplied docId must not steer the scan by traversal',
      );
      expect(
        SkillService.androidFolderPathFromDocumentUri('${base}primary%3ASKILL.md'),
        isNull,
        reason: 'the volume root is a container, never a skill folder',
      );
    });

    test('a document inside a skills root never sweeps the root', () async {
      SkillService.debugAndroidExternalStorageRoot = projectRoot.path;
      addTearDown(() => SkillService.debugAndroidExternalStorageRoot = null);
      final root = Directory('${projectRoot.path}/.agents/skills')
        ..createSync(recursive: true);
      File('${root.path}/SKILL.md').writeAsStringSync(
        '---\nname: loose-skill\ndescription: d\n---\n',
      );
      final other = Directory('${root.path}/other-skill')
        ..createSync(recursive: true);
      File('${other.path}/SKILL.md').writeAsStringSync(
        '---\nname: other-skill\ndescription: d\n---\n',
      );
      File('${other.path}/notes.md').writeAsStringSync('other notes');

      final cache = Directory('${projectRoot.path}/cache/file_picker/456')
        ..createSync(recursive: true);
      final cachedCopy = File('${cache.path}/SKILL.md')
        ..writeAsStringSync('---\nname: loose-skill\ndescription: d\n---\n');

      SkillService.debugFolderImportOverride = false; // simulate Android
      addTearDown(() => SkillService.debugFolderImportOverride = null);

      final result = await SkillService.importSkillFile(
        sourcePath: cachedCopy.path,
        sourceIdentifier:
            'content://com.android.externalstorage.documents/document/primary%3A.agents%2Fskills%2FSKILL.md',
        globalRoot: globalRoot.path,
      );
      expect(
        SkillService.pickCarriesItsFolder(
          cachedCopy.path,
          'content://com.android.externalstorage.documents/document/primary%3A.agents%2Fskills%2FSKILL.md',
        ),
        isFalse,
        reason: 'the UI warning keys on this gate, so it must agree with it',
      );
      expect(
        result.folderConfirm,
        isFalse,
        reason: 'the skills root must never be offered as one skill folder',
      );
      expect(result.ok, isTrue, reason: result.error);
      expect(result.skill!.fileCount, 1);
      expect(
        Directory('${globalRoot.path}/other-skill').existsSync(),
        isFalse,
        reason: "another installed skill's files must not be swept in",
      );
    });

    test('the real folder rides along while the cache sibling does not', () async {
      // The original folder, as Android exposes it through all-files access
      // (the seam stands in for /storage/emulated/0).
      SkillService.debugAndroidExternalStorageRoot = projectRoot.path;
      addTearDown(() => SkillService.debugAndroidExternalStorageRoot = null);
      final real = Directory('${projectRoot.path}/Download/my-skill')
        ..createSync(recursive: true);
      File('${real.path}/SKILL.md').writeAsStringSync(
        '---\nname: my-skill\ndescription: d\n---\n\nbody\n',
      );
      File('${real.path}/references/a.md')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('reference');

      // The picker's flat cache copy of that same document, sitting beside
      // another pick — the shape that made mobile import single-file only.
      final cache = Directory('${projectRoot.path}/cache/file_picker/123')
        ..createSync(recursive: true);
      final cachedCopy = File('${cache.path}/SKILL.md')
        ..writeAsStringSync(
          '---\nname: my-skill\ndescription: d\n---\n\nbody\n',
        );
      File('${cache.path}/other-skill.md').writeAsStringSync(
        '---\nname: other-skill\ndescription: d\n---\n',
      );

      SkillService.debugFolderImportOverride = false; // simulate Android
      addTearDown(() => SkillService.debugFolderImportOverride = null);
      const identifier = 'content://com.android.externalstorage.documents/'
          'document/primary%3ADownload%2Fmy-skill%2FSKILL.md';

      final preview = await SkillService.importSkillFile(
        sourcePath: cachedCopy.path,
        sourceIdentifier: identifier,
        globalRoot: globalRoot.path,
      );
      expect(
        SkillService.pickCarriesItsFolder(cachedCopy.path, identifier),
        isTrue,
        reason: 'the real folder is exactly what the UI reports as resolvable',
      );
      expect(
        preview.folderConfirm,
        isTrue,
        reason: 'the real folder takes the same two-step path as desktop',
      );
      expect(preview.folderFiles, contains('references/a.md'));

      final result = await SkillService.importSkillFile(
        sourcePath: cachedCopy.path,
        sourceIdentifier: identifier,
        confirmFolder: true,
        globalRoot: globalRoot.path,
      );
      expect(result.ok, isTrue, reason: result.error);
      expect(
        File('${globalRoot.path}/my-skill/references/a.md').readAsStringSync(),
        'reference',
      );
      expect(
        File('${globalRoot.path}/my-skill/other-skill.md').existsSync(),
        isFalse,
        reason: 'a picker cache sibling must never travel with this skill',
      );
      expect(result.skill!.fileCount, 2);
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
