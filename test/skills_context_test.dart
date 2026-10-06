import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/core/models/skill.dart';
import 'package:OmniChat/core/services/skills/skill_invocations.dart';
import 'package:OmniChat/core/services/skills/skill_service.dart';

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

    test('hit: token removed and skill block appended to system', () {
      final apiMessages = messagesWithUser('Use /skill git-release please');
      final resolution = SkillInvocations.resolveInMessages(
        apiMessages,
        loadSkill: (name) => skill(name),
      );
      expect(resolution.changed, isTrue);
      expect(resolution.failedNames, isEmpty);
      expect(apiMessages[1]['content'], 'Use  please');
      final system = apiMessages[0]['content'] as String;
      expect(system, contains('<skill name="git-release">'));
      expect(system, contains('Body of git-release.'));
      expect(system, endsWith('</skill>'));
    });

    test('miss: token kept, skill_error appended, name reported', () {
      final apiMessages = messagesWithUser('/skill no-such-skill');
      final resolution = SkillInvocations.resolveInMessages(
        apiMessages,
        loadSkill: (name) => null,
      );
      expect(resolution.failedNames, ['no-such-skill']);
      expect(apiMessages[1]['content'], '/skill no-such-skill');
      final system = apiMessages[0]['content'] as String;
      expect(system, contains('<skill_error name="no-such-skill">'));
    });

    test('invalid format: nothing happens', () {
      final apiMessages = messagesWithUser('I typed /skill Bad-Name today');
      final resolution = SkillInvocations.resolveInMessages(
        apiMessages,
        loadSkill: (name) => skill(name),
      );
      expect(resolution.changed, isFalse);
      expect(apiMessages[1]['content'], 'I typed /skill Bad-Name today');
    });

    test('multiple hits in one message', () {
      final apiMessages = messagesWithUser('/skill a-b and /skill c-d');
      final resolution = SkillInvocations.resolveInMessages(
        apiMessages,
        loadSkill: (name) => skill(name),
      );
      expect(resolution.failedNames, isEmpty);
      final system = apiMessages[0]['content'] as String;
      expect(system, contains('<skill name="a-b">'));
      expect(system, contains('<skill name="c-d">'));
      expect(apiMessages[1]['content'], ' and ');
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
      expect(apiMessages[1]['content'], 'Run  now');
      expect(
        (apiMessages[1]['content'] as String).contains('/'),
        isFalse,
      );
    });

    test('hit + miss mixed', () {
      final apiMessages = messagesWithUser('/skill good /skill bad2');
      final resolution = SkillInvocations.resolveInMessages(
        apiMessages,
        loadSkill: (name) => name == 'good' ? skill(name) : null,
      );
      expect(resolution.failedNames, ['bad2']);
      final system = apiMessages[0]['content'] as String;
      expect(system, contains('<skill name="good">'));
      expect(system, contains('<skill_error name="bad2">'));
      expect(apiMessages[1]['content'], contains('/skill bad2'));
      expect(apiMessages[1]['content'], isNot(contains('/skill good')));
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

    test('creates a system message when none exists', () {
      final List<Map<String, dynamic>> apiMessages = [
        {'role': 'user', 'content': '/skill git-release'},
      ];
      SkillInvocations.resolveInMessages(
        apiMessages,
        loadSkill: (name) => skill(name),
      );
      expect(apiMessages.first['role'], 'system');
      expect(apiMessages.first['content'], contains('<skill'));
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
}
