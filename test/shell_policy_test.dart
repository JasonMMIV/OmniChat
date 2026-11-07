import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/core/services/shell/shell_policy.dart';

void main() {
  const allowlist = <String>[
    'git',
    'node',
    'npm',
    'npx',
    'python',
    'pip',
    'pandoc',
    'ffmpeg',
  ];

  group('ShellPolicy.decide', () {
    test('allows a single allowlisted program', () {
      final result = ShellPolicy.decide(
        command: 'git status',
        allowlist: allowlist,
      );
      expect(result.decision, ShellPolicyDecision.allow);
      expect(result.reason, 'allowlist');
      expect(result.programs, equals(<String>['git']));
    });

    test('allows a compound command when every segment is allowlisted', () {
      final result = ShellPolicy.decide(
        command: 'git status && npm test | node ./check.js',
        allowlist: allowlist,
      );
      expect(result.decision, ShellPolicyDecision.allow);
      expect(result.programs, equals(<String>['git', 'npm', 'node']));
    });

    test('asks when any compound segment is outside the allowlist', () {
      final result = ShellPolicy.decide(
        command: 'git status && curl https://example.com',
        allowlist: allowlist,
      );
      expect(result.decision, ShellPolicyDecision.ask);
      expect(result.reason, 'not_allowlisted');
      expect(result.blockedPrograms, equals(<String>['curl']));
    });

    test('treats a single ampersand as a command separator', () {
      final result = ShellPolicy.decide(
        command: 'git status & curl https://example.com',
        allowlist: allowlist,
      );
      expect(result.decision, ShellPolicyDecision.ask);
      expect(result.blockedPrograms, equals(<String>['curl']));
    });

    test('keeps redirection ampersands in the same segment', () {
      final result = ShellPolicy.decide(
        command: 'git status 2>&1',
        allowlist: allowlist,
      );
      expect(result.decision, ShellPolicyDecision.allow);
      expect(result.programs, equals(<String>['git']));
    });

    test('asks for shell pipes into non-allowlisted programs', () {
      final result = ShellPolicy.decide(
        command: 'git log | sh',
        allowlist: allowlist,
      );
      expect(result.decision, ShellPolicyDecision.ask);
      expect(result.blockedPrograms, equals(<String>['sh']));
    });

    test('asks for command substitution even with an allowlisted prefix', () {
      final result = ShellPolicy.decide(
        command: r'echo $(rm -rf build)',
        allowlist: const <String>['echo'],
      );
      expect(result.decision, ShellPolicyDecision.ask);
      expect(result.reason, 'subshell');
    });

    test('asks for backtick substitution', () {
      final result = ShellPolicy.decide(
        command: 'echo `whoami`',
        allowlist: const <String>['echo'],
      );
      expect(result.decision, ShellPolicyDecision.ask);
      expect(result.reason, 'subshell');
    });

    test('strict mode degrades every ask to deny', () {
      final result = ShellPolicy.decide(
        command: 'curl https://example.com',
        allowlist: allowlist,
        strictMode: true,
      );
      expect(result.decision, ShellPolicyDecision.deny);
      expect(result.reason, 'strict');
    });

    test('empty commands are denied', () {
      final result = ShellPolicy.decide(command: '   ', allowlist: allowlist);
      expect(result.decision, ShellPolicyDecision.deny);
      expect(result.reason, 'empty_command');
    });
  });

  group('ShellPolicy.programsIn', () {
    test('normalizes quotes, paths, Windows suffixes and env prefixes', () {
      final programs = ShellPolicy.programsIn(
        r'FOO=bar "C:\Program Files\Git\cmd\git.exe" status '
        r'&& NODE=C:\node PATH=C:\bin node --version',
      );
      expect(programs, equals(<String>['git', 'node']));
    });

    test('deduplicates repeated programs and skips empty segments', () {
      expect(
        ShellPolicy.programsIn('git status; git diff;'),
        equals(<String>['git']),
      );
    });

    test('normalizeProgram strips paths and suffixes', () {
      expect(ShellPolicy.normalizeProgram(r'C:\Tools\npm.CMD'), 'npm');
      expect(ShellPolicy.normalizeProgram('/usr/local/bin/python3'), 'python3');
      expect(ShellPolicy.normalizeProgram('"git.exe"'), 'git');
    });
  });
}
