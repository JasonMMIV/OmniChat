import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/core/models/skill.dart';
import 'package:OmniChat/core/services/skills/skill_parser.dart';

void main() {
  const filePath = '/skills/git-release/SKILL.md';

  SkillDefinition? parse(
    String content, {
    String directoryName = 'git-release',
    SkillScope scope = SkillScope.global,
  }) {
    return SkillParser.parseSkillFileContent(
      content,
      directoryName: directoryName,
      filePath: filePath,
      scope: scope,
    );
  }

  group('parseSkillFileContent', () {
    test('parses a well-formed skill', () {
      final skill = parse('''
---
name: git-release
description: Generate changelog and bump versions.
license: MIT
---

# Git Release

Body text.
''');
      expect(skill, isNotNull);
      expect(skill!.name, 'git-release');
      expect(skill.description, 'Generate changelog and bump versions.');
      expect(skill.license, 'MIT');
      expect(skill.disableModelInvocation, isFalse);
      expect(skill.content, contains('# Git Release'));
      expect(skill.filePath, filePath);
      expect(skill.scope, SkillScope.global);
    });

    test('keeps the full original content including frontmatter', () {
      const raw = '---\nname: git-release\ndescription: d\n---\n\nbody\n';
      final skill = parse(raw);
      expect(skill!.content, raw);
    });

    test('returns null without frontmatter', () {
      expect(parse('# Just a doc\nno frontmatter here'), isNull);
    });

    test('returns null when missing name', () {
      expect(parse('---\ndescription: d\n---\nbody'), isNull);
    });

    test('returns null when missing description', () {
      expect(parse('---\nname: git-release\n---\nbody'), isNull);
    });

    test('returns null for invalid names', () {
      for (final bad in ['Git-Release', 'my--skill', '-skill', 'skill-', 'a']) {
        // 'a' is valid; only assert the truly invalid ones below.
        if (bad == 'a') continue;
        expect(
          parse('---\nname: $bad\ndescription: d\n---\n'),
          isNull,
          reason: 'name "$bad" must be rejected',
        );
      }
    });

    test('accepts valid names', () {
      for (final good in ['git-release', 'api-design', 'review2', 'a']) {
        expect(
          SkillParser.isValidSkillName(good),
          isTrue,
          reason: 'name "$good" must be accepted',
        );
      }
    });

    test('rejects names exceeding 64 chars', () {
      final long = 'a' * 65;
      expect(SkillParser.isValidSkillName(long), isFalse);
      expect(SkillParser.isValidSkillName('a' * 64), isTrue);
    });

    test('returns null when name differs from directoryName', () {
      expect(
        parse('---\nname: other-name\ndescription: d\n---\n'),
        isNull,
      );
    });

    test('clamps over-long description instead of rejecting', () {
      final skill = parse('---\nname: git-release\ndescription: ${'x' * 2000}\n---\n');
      expect(skill, isNotNull);
      expect(skill!.description.length, SkillParser.maxDescriptionLength);
    });

    test('parses disable-model-invocation: true', () {
      final skill = parse(
        '---\nname: git-release\ndescription: d\ndisable-model-invocation: true\n---\n',
      );
      expect(skill!.disableModelInvocation, isTrue);
    });

    test('parses quoted values', () {
      final skill = parse(
        '---\nname: "git-release"\ndescription: \'Single quoted\'\n---\n',
      );
      expect(skill!.name, 'git-release');
      expect(skill.description, 'Single quoted');
    });

    test('skips comments and blank lines', () {
      final skill = parse('''
---
# a comment
name: git-release

description: d
---
''');
      expect(skill!.name, 'git-release');
    });

    test('ignores metadata block without failing', () {
      final skill = parse('''
---
name: git-release
description: d
metadata:
  category: development
  nested:
    deep: value
---
''');
      expect(skill, isNotNull);
      expect(skill!.name, 'git-release');
    });

    test('reads provenance from metadata block', () {
      final skill = parse('''
---
name: git-release
description: d
metadata:
  source: github
  installedAt: 2026-10-06T10:30:00.000
---
''');
      expect(skill!.source, SkillInstallSource.github);
      expect(skill.installedAt, isNotNull);
    });

    test('defaults source to external when unstamped', () {
      final skill = parse('---\nname: git-release\ndescription: d\n---\n');
      expect(skill!.source, SkillInstallSource.external);
    });

    test('passes project scope through', () {
      final skill = parse(
        '---\nname: git-release\ndescription: d\n---\n',
        scope: SkillScope.project,
      );
      expect(skill!.scope, SkillScope.project);
    });

    test('tolerates BOM at file start', () {
      final skill = parse('\uFEFF---\nname: git-release\ndescription: d\n---\n');
      expect(skill!.name, 'git-release');
    });
  });

  group('stripFrontmatter', () {
    test('removes the frontmatter block and following blank lines', () {
      const raw =
          '---\nname: git-release\ndescription: d\n---\n\n# Title\n\nBody\n';
      final body = SkillParser.stripFrontmatter(raw);
      expect(body, '# Title\n\nBody\n');
      expect(body.contains('---'), isFalse);
    });

    test('returns content unchanged without frontmatter', () {
      const raw = '# Just a doc\nno frontmatter here';
      expect(SkillParser.stripFrontmatter(raw), raw);
    });

    test('returns content unchanged for an unterminated block', () {
      const raw = '---\nname: git-release\nnever closed';
      expect(SkillParser.stripFrontmatter(raw), raw);
    });

    test('handles BOM and leading blank lines', () {
      const raw = '\uFEFF\n---\nname: x\ndescription: d\n---\nbody';
      expect(SkillParser.stripFrontmatter(raw), 'body');
    });

    test('frontmatter-only content strips to empty', () {
      expect(
        SkillParser.stripFrontmatter('---\nname: x\ndescription: d\n---\n'),
        '',
      );
    });
  });

  group('extractSkillName', () {
    test('extracts the frontmatter name', () {
      expect(
        SkillParser.extractSkillName('---\nname: git-release\ndescription: d\n---\n'),
        'git-release',
      );
    });

    test('returns null when absent or malformed', () {
      expect(SkillParser.extractSkillName('no frontmatter'), isNull);
      expect(SkillParser.extractSkillName('---\ndescription: d\n---\n'), isNull);
    });
  });

  group('buildSkillDocument', () {
    test('produces a document the parser round-trips', () {
      final doc = SkillParser.buildSkillDocument(
        name: 'my-skill',
        description: 'A description with: colon, "quotes" and # hash.',
        body: '## When to use\n\nDo the thing.',
      );
      final skill = SkillParser.parseSkillFileContent(
        doc,
        directoryName: 'my-skill',
        filePath: '/x/my-skill/SKILL.md',
      );
      expect(skill, isNotNull);
      expect(
        skill!.description,
        'A description with: colon, "quotes" and # hash.',
      );
      expect(skill.content, contains('## When to use'));
    });

    test('escapes newlines in description', () {
      final doc = SkillParser.buildSkillDocument(
        name: 'my-skill',
        description: 'line one\nline two',
        body: 'b',
      );
      final skill = SkillParser.parseSkillFileContent(
        doc,
        directoryName: 'my-skill',
        filePath: '/x/SKILL.md',
      );
      expect(skill!.description, 'line one\nline two');
    });

    test('yamlScalar quotes special text and leaves plain text bare', () {
      expect(SkillParser.yamlScalar('plain text'), 'plain text');
      expect(
        SkillParser.yamlScalar('has: colon'),
        '"has: colon"',
      );
      expect(SkillParser.yamlScalar('say "hi"'), '"say \\"hi\\""');
      expect(SkillParser.yamlScalar(''), '""');
    });
  });
}
