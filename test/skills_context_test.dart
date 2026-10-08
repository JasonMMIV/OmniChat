import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/core/models/skill.dart';
import 'package:OmniChat/core/providers/skills_provider.dart';
import 'package:OmniChat/core/services/skills/skill_invocations.dart';
import 'package:OmniChat/core/services/skills/skill_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('extractSkillInvocations', () {
    test('finds a simple token', () {
      final invocations =
          SkillInvocations.extractSkillInvocations('/skill git-release');
      expect(invocations, hasLength(1));
      expect(invocations.first.name, 'git-release');
    });

    test('finds tokens embedded in surrounding text', () {
      final invocations = SkillInvocations.extractSkillInvocations(
        '請先用 /skill api-design 幫我審一下，謝謝',
      );
      expect(invocations, hasLength(1));
      expect(invocations.first.name, 'api-design');
    });

    test('finds multiple tokens', () {
      final invocations = SkillInvocations.extractSkillInvocations(
        '/skill a-b then /skill c-d',
      );
      expect(invocations.map((e) => e.name), ['a-b', 'c-d']);
    });

    test('keyword is case-insensitive', () {
      final invocations =
          SkillInvocations.extractSkillInvocations('/SKILL git-release');
      expect(invocations, hasLength(1));
    });

    test('irregular separators still yield exact token offsets', () {
      // `[ \t]+` may span several chars — offsets must come from the match
      // position, never from an assumed single-char separator.
      final text = 'before  /skill  git-release after';
      final invocations = SkillInvocations.extractSkillInvocations(text);
      expect(invocations, hasLength(1));
      final inv = invocations.first;
      expect(text.substring(inv.tokenStart, inv.tokenEnd),
          '/skill  git-release');
    });

    test('leading newline before the keyword is preserved', () {
      final text = '\n/skill git-release';
      final invocations = SkillInvocations.extractSkillInvocations(text);
      expect(invocations, hasLength(1));
      expect(invocations.first.tokenStart, 1);
    });

    test('invalid name formats stay unparsed', () {
      expect(
        SkillInvocations.extractSkillInvocations('/skill Git-Release'),
        isEmpty,
        reason: 'uppercase names are not valid skill names (§9)',
      );
      expect(
        SkillInvocations.extractSkillInvocations('/skill -bad'),
        isEmpty,
      );
      expect(
        SkillInvocations.extractSkillInvocations('/skill'),
        isEmpty,
      );
      expect(
        SkillInvocations.extractSkillInvocations('/skillx git-release'),
        isEmpty,
      );
    });
  });

  group('extractSkillNames', () {
    test('returns names in token order, deduped', () {
      expect(
        SkillInvocations.extractSkillNames(
          '/skill a-b then /skill c-d and /skill a-b again',
        ),
        ['a-b', 'c-d'],
      );
    });

    test('empty when there are no valid tokens', () {
      expect(SkillInvocations.extractSkillNames('no tokens here'), isEmpty);
      expect(SkillInvocations.extractSkillNames('/skill Bad-Name'), isEmpty);
    });
  });

  group('resolveInMessages', () {
    SkillDefinition skill(String name, {bool disabled = false}) {
      return SkillDefinition(
        name: name,
        description: 'desc of $name',
        disableModelInvocation: disabled,
        content: '---\nname: $name\ndescription: desc of $name\n---\n\nBody of $name.',
        filePath: '/skills/$name/SKILL.md',
        scope: SkillScope.global,
      );
    }

    List<Map<String, dynamic>> messagesWithUser(String content) => [
          {'role': 'system', 'content': 'You are helpful.'},
          {'role': 'user', 'content': content},
        ];

    test('hit: explicit invocation frame replaces the token', () {
      final apiMessages = messagesWithUser('Use /skill git-release please');
      final resolution = SkillInvocations.resolveInMessages(
        apiMessages,
        loadSkill: (name) => skill(name),
      );
      expect(resolution.changed, isTrue);
      expect(resolution.failedNames, isEmpty);
      final user = apiMessages[1]['content'] as String;
      // Anybuff `buildFinalPrompt` frame: explicit line, block, then the
      // remaining text under a `User request:` label.
      expect(
        user,
        startsWith('I invoke the following skill: git-release\n\n'),
      );
      expect(user, contains('<skill name="git-release">'));
      expect(user, contains('Body of git-release.'));
      expect(user, endsWith('User request: Use  please'));
      expect(user.contains('/skill git-release'), isFalse);
      // User-turn delivery: the system message is never touched.
      expect(apiMessages[0]['content'], 'You are helpful.');
    });

    test('skill content rides the user turn, not the system prompt', () {
      // 2026-10-06 hands-on fix: the block used to be appended to the system
      // prompt tail while the token was stripped from the user message, so
      // models processed the remnant as a plain request and never started
      // the skill. Delivery must stay on the message that carried the token
      // (Anybuff `buildFinalPrompt` parity).
      final apiMessages = messagesWithUser('/skill git-release 翻譯這段');
      SkillInvocations.resolveInMessages(
        apiMessages,
        loadSkill: (name) => skill(name),
      );
      expect(apiMessages[0]['content'], 'You are helpful.');
      final user = apiMessages[1]['content'] as String;
      expect(
        user,
        startsWith('I invoke the following skill: git-release\n\n'),
      );
      expect(user, contains('<skill name="git-release">'));
      expect(user, contains('User request: 翻譯這段'));
    });

    test('miss: token kept, skill_error appended to the user message', () {
      final apiMessages = messagesWithUser('/skill no-such-skill');
      final resolution = SkillInvocations.resolveInMessages(
        apiMessages,
        loadSkill: (name) => null,
      );
      expect(resolution.failedNames, ['no-such-skill']);
      expect(resolution.changed, isTrue);
      final user = apiMessages[1]['content'] as String;
      expect(user, startsWith('/skill no-such-skill\n\n'));
      expect(user, contains('<skill_error name="no-such-skill">'));
      expect(apiMessages[0]['content'], 'You are helpful.');
    });

    test('invalid format: nothing happens', () {
      final apiMessages = messagesWithUser('I typed /skill Bad-Name today');
      final resolution = SkillInvocations.resolveInMessages(
        apiMessages,
        loadSkill: (name) => skill(name),
      );
      expect(resolution.changed, isFalse);
      expect(apiMessages[1]['content'], 'I typed /skill Bad-Name today');
      expect(apiMessages[0]['content'], 'You are helpful.');
    });

    test('multiple hits keep token order and get a plural frame', () {
      final apiMessages = messagesWithUser('/skill a-b and /skill c-d');
      final resolution = SkillInvocations.resolveInMessages(
        apiMessages,
        loadSkill: (name) => skill(name),
      );
      expect(resolution.failedNames, isEmpty);
      final user = apiMessages[1]['content'] as String;
      expect(
        user,
        startsWith('I invoke the following skills: a-b, c-d\n\n'),
      );
      final abIdx = user.indexOf('<skill name="a-b">');
      final cdIdx = user.indexOf('<skill name="c-d">');
      expect(abIdx, greaterThan(0));
      expect(cdIdx, greaterThan(abIdx));
      expect(user, contains('User request: and'));
    });

    test('duplicate invocations of one skill keep a single block', () {
      final apiMessages = messagesWithUser('/skill a-b /skill a-b');
      SkillInvocations.resolveInMessages(
        apiMessages,
        loadSkill: (name) => skill(name),
      );
      final user = apiMessages[1]['content'] as String;
      expect(user, isNot(contains('/skill a-b')));
      expect(RegExp(r'<skill name="a-b">').allMatches(user).length, 1);
      expect(user, startsWith('I invoke the following skill: a-b\n\n'));
      expect(user.trim(), endsWith('</skill>'));
      expect(user.contains('User request:'), isFalse);
    });

    test('hit with multi-space separator leaves no token residue', () {
      // Regression: the removal range once assumed a single-char separator,
      // leaving a stray `/` behind for `/skill  name`.
      final apiMessages = messagesWithUser('Run /skill  a-b now');
      final resolution = SkillInvocations.resolveInMessages(
        apiMessages,
        loadSkill: (name) => skill(name),
      );
      expect(resolution.changed, isTrue);
      final user = apiMessages[1]['content'] as String;
      expect(user, startsWith('I invoke the following skill: a-b\n\n'));
      // Exact remainder pins the offsets — a stray `/` would break it.
      expect(
        user.substring(user.indexOf('User request:')),
        'User request: Run  now',
      );
    });

    test('hit + miss mixed in one message', () {
      final apiMessages = messagesWithUser('/skill good /skill bad2');
      final resolution = SkillInvocations.resolveInMessages(
        apiMessages,
        loadSkill: (name) => name == 'good' ? skill(name) : null,
      );
      expect(resolution.failedNames, ['bad2']);
      final user = apiMessages[1]['content'] as String;
      expect(user, startsWith('I invoke the following skill: good\n\n'));
      expect(user, contains('/skill bad2'));
      expect(user, isNot(contains('/skill good')));
      expect(user, contains('<skill name="good">'));
      expect(user, contains('<skill_error name="bad2">'));
      expect(user, contains('User request: /skill bad2'));
      // The hit block precedes the retained miss token's error block.
      expect(
        user.indexOf('<skill name="good">'),
        lessThan(user.indexOf('<skill_error name="bad2">')),
      );
      expect(apiMessages[0]['content'], 'You are helpful.');
    });

    test('only user messages are touched', () {
      final apiMessages = [
        {'role': 'system', 'content': 'sys'},
        {'role': 'assistant', 'content': 'try /skill x-y maybe'},
        {'role': 'user', 'content': '/skill x-y'},
      ];
      SkillInvocations.resolveInMessages(
        apiMessages,
        loadSkill: (name) => skill(name),
      );
      expect(apiMessages[1]['content'], 'try /skill x-y maybe');
      expect(apiMessages[0]['content'], 'sys');
      expect(apiMessages[2]['content'], contains('<skill name="x-y">'));
    });

    test('resolves tokens across every user message', () {
      // Regenerate / replay re-resolve the whole assembly, so historical
      // user messages carrying tokens must keep resolving too.
      final apiMessages = <Map<String, dynamic>>[
        {'role': 'system', 'content': 'You are helpful.'},
        {'role': 'user', 'content': '/skill a-b first'},
        {'role': 'assistant', 'content': 'ok'},
        {'role': 'user', 'content': '/skill c-d second'},
      ];
      SkillInvocations.resolveInMessages(
        apiMessages,
        loadSkill: (name) => skill(name),
      );
      expect(apiMessages[1]['content'], contains('<skill name="a-b">'));
      expect(apiMessages[3]['content'], contains('<skill name="c-d">'));
      expect(apiMessages[0]['content'], 'You are helpful.');
    });

    test('empty map loader with no tokens is a no-op', () {
      final apiMessages = messagesWithUser('hello world');
      final resolution = SkillInvocations.resolveInMessages(
        apiMessages,
        loadSkill: (name) => null,
      );
      expect(resolution.changed, isFalse);
      expect(apiMessages[0]['content'], 'You are helpful.');
    });

    test('no system message is created or modified', () {
      final List<Map<String, dynamic>> apiMessages = [
        {'role': 'user', 'content': '/skill git-release'},
      ];
      SkillInvocations.resolveInMessages(
        apiMessages,
        loadSkill: (name) => skill(name),
      );
      expect(apiMessages, hasLength(1));
      expect(apiMessages.first['role'], 'user');
      expect(
        apiMessages.first['content'],
        startsWith('I invoke the following skill: git-release\n\n'),
      );
    });

    test('token-only message becomes the invocation frame, never empty', () {
      // A message consisting ONLY of the token would otherwise resolve to
      // empty user content — several providers (Anthropic among them) reject
      // that. The invocation frame itself fills the message (the 2026-10-06
      // placeholder workaround is no longer needed).
      final apiMessages = messagesWithUser('/skill git-release');
      final resolution = SkillInvocations.resolveInMessages(
        apiMessages,
        loadSkill: (name) => skill(name),
      );
      expect(resolution.changed, isTrue);
      expect(resolution.failedNames, isEmpty);
      final user = apiMessages[1]['content'] as String;
      expect(
        user,
        startsWith('I invoke the following skill: git-release\n\n'),
      );
      expect(user, endsWith('</skill>'));
      expect(user.contains('User request:'), isFalse);
      expect(apiMessages[0]['content'], 'You are helpful.');
    });

    test('several hits leaving only whitespace yield frame-only content', () {
      final apiMessages = messagesWithUser('/skill a-b /skill c-d');
      SkillInvocations.resolveInMessages(
        apiMessages,
        loadSkill: (name) => skill(name),
      );
      final user = apiMessages[1]['content'] as String;
      expect(
        user,
        startsWith('I invoke the following skills: a-b, c-d\n\n'),
      );
      expect(user, contains('<skill name="a-b">'));
      expect(user, contains('<skill name="c-d">'));
      expect(user.trim(), endsWith('</skill>'));
      expect(user.contains('User request:'), isFalse);
    });

    test('a failed token keeps the message non-empty', () {
      // The miss keeps its token visible (§9 R4), so the message is never
      // blank and needs no placeholder.
      final apiMessages = messagesWithUser('/skill good /skill bad2');
      SkillInvocations.resolveInMessages(
        apiMessages,
        loadSkill: (name) => name == 'good' ? skill(name) : null,
      );
      final user = (apiMessages[1]['content'] as String).trim();
      expect(user, contains('/skill bad2'));
      expect(user, contains('<skill_error name="bad2">'));
    });
    test('injected block strips the YAML frontmatter', () {
      // 2026-10-06 revision: the frontmatter `description` carries gating
      // wording ("use ONLY when the user explicitly…") that made models
      // second-guess whether the skill was active. The payload must carry
      // the body only.
      final apiMessages = messagesWithUser('/skill git-release');
      SkillInvocations.resolveInMessages(
        apiMessages,
        loadSkill: (name) => skill(name),
      );
      final user = apiMessages[1]['content'] as String;
      expect(user, contains('Body of git-release.'));
      expect(user.contains('---'), isFalse);
      expect(user.contains('description:'), isFalse);
      expect(user.contains('name: git-release'), isFalse);
    });

    test('frame order: invocation line, block, then User request', () {
      final apiMessages = messagesWithUser('請 /skill a-b 幫我檢查');
      SkillInvocations.resolveInMessages(
        apiMessages,
        loadSkill: (name) => skill(name),
      );
      final user = apiMessages[1]['content'] as String;
      final lineIdx = user.indexOf('I invoke the following skill: a-b');
      final blockIdx = user.indexOf('<skill name="a-b">');
      final requestIdx = user.indexOf('User request: ');
      expect(lineIdx, 0);
      expect(blockIdx, greaterThan(lineIdx));
      expect(requestIdx, greaterThan(blockIdx));
      expect(user.trim(), endsWith('幫我檢查'));
    });
  });

  group('SkillsProvider seeded-example cleanup', () {
    late Directory home;

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      home = await Directory.systemTemp.createTemp('seed_cleanup_');
      SkillService.debugHomeDirectoryOverride = home.path;
      SkillService.debugResetGlobalRootCache();
    });

    tearDown(() async {
      SkillService.debugHomeDirectoryOverride = null;
      SkillService.debugResetGlobalRootCache();
      try {
        await home.delete(recursive: true);
      } catch (_) {}
    });

    Future<void> writeSeed(String description) async {
      final dir = Directory('${home.path}/.agents/skills/example-skill');
      await dir.create(recursive: true);
      await File('${dir.path}/SKILL.md').writeAsString(
        '---\nname: example-skill\ndescription: $description\n'
        'metadata:\n  source: manual\n---\n\n# Example Skill\n',
      );
    }

    test('removes the unmodified seeded example-skill once', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'skills_example_seeded_v1': true,
      });
      await writeSeed(
        'A minimal example showing the SKILL.md format. Edit or delete it freely.',
      );

      await SkillsProvider().initialize();

      expect(
        Directory('${home.path}/.agents/skills/example-skill').existsSync(),
        isFalse,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('skills_example_seeded_v1'), isNull);
    });

    test('keeps the folder when the user has edited it', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'skills_example_seeded_v1': true,
      });
      await writeSeed('My own customized skill folder');

      await SkillsProvider().initialize();

      expect(
        Directory('${home.path}/.agents/skills/example-skill').existsSync(),
        isTrue,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('skills_example_seeded_v1'), isNull);
    });

    test('no-op when the device never seeded', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await writeSeed(
        'A minimal example showing the SKILL.md format. Edit or delete it freely.',
      );

      await SkillsProvider().initialize();

      // No flag → cleanup must not run (a manually created folder with the
      // same description survives).
      expect(
        Directory('${home.path}/.agents/skills/example-skill').existsSync(),
        isTrue,
      );
    });
  });

  group('skillsForContext integration', () {
    test('loadSkillByName picks project over global (fresh read)', () async {
      final globalRoot = await Directory.systemTemp.createTemp('ctx_g_');
      final projectRoot = await Directory.systemTemp.createTemp('ctx_p_');
      addTearDown(() async {
        await globalRoot.delete(recursive: true);
        await projectRoot.delete(recursive: true);
      });
      var dir = Directory('${globalRoot.path}/git-release')
        ..createSync(recursive: true);
      File('${dir.path}/SKILL.md').writeAsStringSync(
        '---\nname: git-release\ndescription: global\n---\n',
      );
      dir = Directory('${projectRoot.path}/.agents/skills/git-release')
        ..createSync(recursive: true);
      File('${dir.path}/SKILL.md').writeAsStringSync(
        '---\nname: git-release\ndescription: project\n---\n',
      );

      final merged = SkillService.skillsForContext(
        workspacePath: projectRoot.path,
        globalRoot: globalRoot.path,
      );
      expect(merged['git-release']!.description, 'project');

      final loaded = SkillService.loadSkillByName(
        'git-release',
        workspacePath: projectRoot.path,
        globalRoot: globalRoot.path,
      );
      expect(loaded!.description, 'project');
    });
  });

  group('SkillsProvider.deleteSkill project shadow', () {
    late Directory home;
    late Directory workspace;

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues(<String, Object>{});
      home = await Directory.systemTemp.createTemp('del_home_');
      workspace = await Directory.systemTemp.createTemp('del_ws_');
      SkillService.debugHomeDirectoryOverride = home.path;
      SkillService.debugResetGlobalRootCache();
    });

    tearDown(() async {
      SkillService.debugHomeDirectoryOverride = null;
      SkillService.debugResetGlobalRootCache();
      try {
        await home.delete(recursive: true);
      } catch (_) {}
      try {
        await workspace.delete(recursive: true);
      } catch (_) {}
    });

    Future<void> writeSkill(String rootPath, String name) async {
      final dir = Directory('$rootPath/$name')..createSync(recursive: true);
      File('${dir.path}/SKILL.md').writeAsStringSync(
        '---\nname: $name\ndescription: d\n---\n',
      );
    }

    test('reports a same-named read-only project skill after a delete',
        () async {
      final provider = SkillsProvider();
      await provider.initialize();
      await writeSkill('${home.path}/.agents/skills', 'notes');
      await writeSkill('${workspace.path}/.agents/skills', 'notes');
      await provider.refresh();

      // What the input-bar menu does before offering the skill.
      provider.skillsForContext(workspace.path);

      final result = await provider.deleteSkill('notes', mobilePlatform: true);

      expect(result.ok, isTrue, reason: result.error);
      expect(result.projectShadow, isTrue);
      expect(
        Directory('${home.path}/.agents/skills/notes').existsSync(),
        isFalse,
      );
      // The menu keeps listing the name — via the project layer, by design.
      expect(
        provider.skillsForContext(workspace.path).containsKey('notes'),
        isTrue,
      );
    });

    test('no shadow flag when only the global copy existed', () async {
      final provider = SkillsProvider();
      await provider.initialize();
      await writeSkill('${home.path}/.agents/skills', 'solo');
      await provider.refresh();
      provider.skillsForContext(workspace.path);

      final result = await provider.deleteSkill('solo', mobilePlatform: true);
      expect(result.ok, isTrue, reason: result.error);
      expect(result.projectShadow, isFalse);
      expect(provider.globalSkills, isEmpty);
    });
  });

  group('SkillsProvider.noteProjectSkills', () {
    test('surfaces project-only setups and dedupes notifications', () async {
      final workspace = await Directory.systemTemp.createTemp('hint_ws_');
      addTearDown(() async {
        await workspace.delete(recursive: true);
      });
      final dir = Directory('${workspace.path}/.agents/skills/notes')
        ..createSync(recursive: true);
      File('${dir.path}/SKILL.md').writeAsStringSync(
        '---\nname: notes\ndescription: project notes\n---\n\nBody.\n',
      );

      final provider = SkillsProvider();
      expect(provider.hasAnyKnownSkills, isFalse);

      var notified = 0;
      provider.addListener(() => notified++);
      provider.noteProjectSkills(workspace.path);
      expect(provider.hasAnyKnownSkills, isTrue);
      expect(notified, 1);

      // Unchanged skill set → no redundant notification.
      provider.noteProjectSkills(workspace.path);
      expect(notified, 1);
    });

    test('clears the hint when the workspace goes away', () async {
      final workspace = await Directory.systemTemp.createTemp('hint_ws_');
      addTearDown(() async {
        await workspace.delete(recursive: true);
      });
      final dir = Directory('${workspace.path}/.agents/skills/notes')
        ..createSync(recursive: true);
      File('${dir.path}/SKILL.md').writeAsStringSync(
        '---\nname: notes\ndescription: project notes\n---\n\nBody.\n',
      );

      final provider = SkillsProvider();
      provider.noteProjectSkills(workspace.path);
      expect(provider.hasAnyKnownSkills, isTrue);

      var notified = 0;
      provider.addListener(() => notified++);
      provider.noteProjectSkills(null);
      expect(provider.hasAnyKnownSkills, isFalse);
      expect(notified, 1);
    });

    test('stays hidden when no skills exist anywhere', () async {
      final workspace = await Directory.systemTemp.createTemp('hint_ws_');
      addTearDown(() async {
        await workspace.delete(recursive: true);
      });

      final provider = SkillsProvider();
      var notified = 0;
      provider.addListener(() => notified++);
      provider.noteProjectSkills(workspace.path); // no .agents/skills inside
      provider.noteProjectSkills(null);
      expect(provider.hasAnyKnownSkills, isFalse);
      expect(notified, 0);
    });
  });
}
