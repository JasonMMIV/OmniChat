import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:OmniChat/core/models/skill.dart';
import 'package:OmniChat/core/services/skills/github_skill_service.dart';
import 'package:OmniChat/core/services/skills/skill_service.dart';

http.Response _treesResponse(List<Map<String, dynamic>> tree,
        {bool truncated = false}) =>
    http.Response(
      jsonEncode({'sha': 'HEAD', 'truncated': truncated, 'tree': tree}),
      200,
      headers: {'content-type': 'application/json'},
    );

void main() {
  late Directory globalRoot;

  setUp(() async {
    globalRoot = await Directory.systemTemp.createTemp('gh_skills_');
  });

  tearDown(() async {
    GithubSkillService.debugHttpClient = null;
    if (await globalRoot.exists()) await globalRoot.delete(recursive: true);
  });

  group('parseGithubRepo', () {
    test('accepts owner/repo and URL forms', () {
      for (final input in [
        'owner/repo',
        'github.com/owner/repo',
        'https://github.com/owner/repo',
        'https://github.com/owner/repo.git',
        'https://github.com/owner/repo/',
        'https://www.github.com/owner/repo',
      ]) {
        final repo = GithubSkillService.parseGithubRepo(input);
        expect(repo, isNotNull, reason: 'input "$input" must parse');
        expect(repo!.owner, 'owner');
        expect(repo.repo, 'repo');
      }
    });

    test('rejects other hosts and malformed inputs by name', () {
      for (final input in [
        'gitlab.com/owner/repo',
        'example.com/owner/repo',
        'https://evil.com/github.com/owner/repo',
        'owner',
        'owner/repo/extra/deep',
        '-owner/repo',
        'owner/-repo',
        'owner/',
        '',
      ]) {
        expect(
          GithubSkillService.parseGithubRepo(input),
          isNull,
          reason: 'input "$input" must be rejected',
        );
      }
    });
  });

  group('isSafeRelPath (via install gate)', () {
    test('rejects traversal shapes', () {
      expect(SkillService.isSafeRelPath('../x'), isFalse);
      expect(SkillService.isSafeRelPath('a/../b'), isFalse);
      expect(SkillService.isSafeRelPath('/abs'), isFalse);
      expect(SkillService.isSafeRelPath('C:/x'), isFalse);
    });
  });

  group('listGithubSkills', () {
    test('finds folders containing SKILL.md including repo root', () async {
      GithubSkillService.debugHttpClient = MockClient((request) async {
        expect(request.url.host, 'api.github.com');
        expect(request.url.path,
            '/repos/owner/repo/git/trees/HEAD');
        expect(request.headers['User-Agent'], 'OmniChat');
        return _treesResponse([
          {'path': 'SKILL.md', 'type': 'blob'},
          {'path': 'README.md', 'type': 'blob'},
          {'path': 'git-release/SKILL.md', 'type': 'blob'},
          {'path': 'git-release/notes.md', 'type': 'blob'},
          {'path': 'git-release/references/deep.md', 'type': 'blob'},
          {'path': 'api-design/SKILL.md', 'type': 'blob'},
        ]);
      });
      final result = await GithubSkillService.listGithubSkills('owner/repo');
      expect(result.ok, isTrue);
      expect(result.candidates.map((c) => c.path).toList(),
          ['', 'api-design', 'git-release']);
      expect(result.candidates.last.fileCount, 3);
    });

    test('404 → not_found', () async {
      GithubSkillService.debugHttpClient = MockClient((request) async {
        return http.Response('not found', 404);
      });
      final result = await GithubSkillService.listGithubSkills('owner/repo');
      expect(result.ok, isFalse);
      expect(result.error, 'not_found');
    });

    test('403 with exhausted rate limit → rate_limit', () async {
      GithubSkillService.debugHttpClient = MockClient((request) async {
        return http.Response('rate limited', 403,
            headers: {'x-ratelimit-remaining': '0'});
      });
      final result = await GithubSkillService.listGithubSkills('owner/repo');
      expect(result.error, 'rate_limit');
    });

    test('network error → network', () async {
      GithubSkillService.debugHttpClient = MockClient((request) async {
        throw http.ClientException('boom');
      });
      final result = await GithubSkillService.listGithubSkills('owner/repo');
      expect(result.error, 'network');
    });

    test('invalid repo input never touches the network', () async {
      GithubSkillService.debugHttpClient = MockClient((request) async {
        fail('network should not be reached');
      });
      final result =
          await GithubSkillService.listGithubSkills('gitlab.com/a/b');
      expect(result.error, 'invalid_repo');
    });

    test('truncated flag propagates', () async {
      GithubSkillService.debugHttpClient = MockClient((request) async {
        return _treesResponse([
          {'path': 'a/SKILL.md', 'type': 'blob'},
        ], truncated: true);
      });
      final result = await GithubSkillService.listGithubSkills('owner/repo');
      expect(result.truncated, isTrue);
    });
  });

  group('downloadGithubSkill', () {
    test('downloads the whole folder and installs it', () async {
      GithubSkillService.debugHttpClient = MockClient((request) async {
        if (request.url.host == 'api.github.com') {
          return _treesResponse([
            {'path': 'git-release/SKILL.md', 'type': 'blob'},
            {'path': 'git-release/references/a.md', 'type': 'blob'},
            {'path': 'git-release/run.exe', 'type': 'blob'},
            {'path': 'unrelated/x.md', 'type': 'blob'},
          ]);
        }
        // raw host
        final path = request.url.path;
        if (path.endsWith('git-release/SKILL.md')) {
          return http.Response(
            '---\nname: git-release\ndescription: from github\n---\n\nbody\n',
            200,
          );
        }
        if (path.endsWith('references/a.md')) {
          return http.Response('attachment a', 200);
        }
        if (path.endsWith('run.exe')) {
          fail('executable must be skipped');
        }
        return http.Response('nf', 404);
      });

      final result = await GithubSkillService.downloadGithubSkill(
        repoInput: 'owner/repo',
        path: 'git-release',
        globalRoot: globalRoot.path,
      );
      expect(result.ok, isTrue, reason: 'error=${result.error}');
      expect(result.skill!.name, 'git-release');
      expect(result.skill!.source.value, 'github');
      expect(
        File('${globalRoot.path}/git-release/SKILL.md').existsSync(),
        isTrue,
      );
      expect(
        File('${globalRoot.path}/git-release/references/a.md').existsSync(),
        isTrue,
      );
      expect(
        File('${globalRoot.path}/git-release/run.exe').existsSync(),
        isFalse,
        reason: 'dangerous extension skipped',
      );
    });

    test('exists gate runs before remaining downloads', () async {
      Directory('${globalRoot.path}/git-release').createSync(recursive: true);
      File('${globalRoot.path}/git-release/SKILL.md').writeAsStringSync('old');
      var rawCalls = 0;
      GithubSkillService.debugHttpClient = MockClient((request) async {
        if (request.url.host == 'api.github.com') {
          return _treesResponse([
            {'path': 'git-release/SKILL.md', 'type': 'blob'},
            {'path': 'git-release/big.md', 'type': 'blob'},
          ]);
        }
        rawCalls++;
        if (request.url.path.endsWith('SKILL.md')) {
          return http.Response(
            '---\nname: git-release\ndescription: new\n---\n',
            200,
          );
        }
        return http.Response('x', 200);
      });

      final result = await GithubSkillService.downloadGithubSkill(
        repoInput: 'owner/repo',
        path: 'git-release',
        globalRoot: globalRoot.path,
      );
      expect(result.ok, isFalse);
      expect(result.exists, isTrue);
      expect(rawCalls, 1, reason: 'only SKILL.md fetched before the gate');

      final ok = await GithubSkillService.downloadGithubSkill(
        repoInput: 'owner/repo',
        path: 'git-release',
        confirm: true,
        globalRoot: globalRoot.path,
      );
      expect(ok.ok, isTrue);
    });

    test('binary attachments survive byte-for-byte', () async {
      // A text round-trip used to write replacement characters over every
      // non-UTF-8 attachment fetched from GitHub.
      final png = <int>[
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0xFF, 0x00, 0x7F,
      ];
      GithubSkillService.debugHttpClient = MockClient((request) async {
        if (request.url.host == 'api.github.com') {
          return _treesResponse([
            {'path': 'img-skill/SKILL.md', 'type': 'blob'},
            {'path': 'img-skill/assets/logo.png', 'type': 'blob'},
          ]);
        }
        if (request.url.path.endsWith('SKILL.md')) {
          return http.Response(
            '---\nname: img-skill\ndescription: d\n---\n',
            200,
          );
        }
        return http.Response.bytes(png, 200);
      });

      final result = await GithubSkillService.downloadGithubSkill(
        repoInput: 'owner/repo',
        path: 'img-skill',
        globalRoot: globalRoot.path,
      );
      expect(result.ok, isTrue, reason: result.error);
      expect(
        File('${globalRoot.path}/img-skill/assets/logo.png').readAsBytesSync(),
        png,
      );
    });

    test('frontmatter name mismatch with folder name installs by name', () async {
      GithubSkillService.debugHttpClient = MockClient((request) async {
        if (request.url.host == 'api.github.com') {
          return _treesResponse([
            {'path': 'weird-folder/SKILL.md', 'type': 'blob'},
          ]);
        }
        return http.Response(
          '---\nname: real-name\ndescription: d\n---\n',
          200,
        );
      });
      final result = await GithubSkillService.downloadGithubSkill(
        repoInput: 'owner/repo',
        path: 'weird-folder',
        globalRoot: globalRoot.path,
      );
      expect(result.ok, isTrue);
      expect(result.skill!.name, 'real-name');
      expect(Directory('${globalRoot.path}/real-name').existsSync(), isTrue);
    });

    test('unsafe path aborts the whole download', () async {
      GithubSkillService.debugHttpClient = MockClient((request) async {
        if (request.url.host == 'api.github.com') {
          return _treesResponse([
            {'path': 's/SKILL.md', 'type': 'blob'},
            {'path': 's/../escape.md', 'type': 'blob'},
          ]);
        }
        return http.Response('---\nname: s\ndescription: d\n---\n', 200);
      });
      final result = await GithubSkillService.downloadGithubSkill(
        repoInput: 'owner/repo',
        path: 's',
        globalRoot: globalRoot.path,
      );
      expect(result.ok, isFalse);
      expect(result.error, 'unsafe_path');
    });
  });
}
