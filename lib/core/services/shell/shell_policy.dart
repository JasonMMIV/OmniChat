// P1-6 desktop shell policy (ADR-A8/A9). Pure Dart so the allow/ask/deny
// ladder is testable without a provider tree or platform bindings.
//
// Contract:
// - A command whose every segment's first program is in the saved allowlist
//   runs immediately.
// - Anything else asks the user (a Pending card naming the full command).
// - Command substitution (`$(...)`, backticks) always asks: the actual
//   program set cannot be known without executing the shell.
// - Strict mode (the existing approval strict-mode toggle) degrades every
//   would-be ask to deny.
library;

enum ShellPolicyDecision {
  /// Every segment's program is allowlisted; execute immediately.
  allow,

  /// Show a Pending approval card; do not execute until the user decides.
  ask,

  /// Refuse outright (strict mode / malformed command).
  deny,
}

class ShellPolicyResult {
  const ShellPolicyResult({
    required this.decision,
    required this.reason,
    this.programs = const <String>[],
    this.blockedPrograms = const <String>[],
  });

  final ShellPolicyDecision decision;

  /// Machine-readable reason: `allowlist`, `not_allowlisted`, `subshell`,
  /// `strict`, `empty_command`, `unparsed_command`.
  final String reason;

  /// First program of every compound segment, normalized.
  final List<String> programs;

  /// Programs that were not found in the allowlist.
  final List<String> blockedPrograms;

  bool get allowed => decision == ShellPolicyDecision.allow;
}

class ShellPolicy {
  ShellPolicy._();

  /// Default allowlist (P1-6 / ADR-A9). Users can edit it in Developer mode.
  static const List<String> defaultAllowlist = <String>[
    'git',
    'node',
    'npm',
    'npx',
    'python',
    'pip',
    'pandoc',
    'ffmpeg',
  ];

  /// Classify [command] against [allowlist].
  static ShellPolicyResult decide({
    required String command,
    required Iterable<String> allowlist,
    bool strictMode = false,
  }) {
    final trimmed = command.trim();
    if (trimmed.isEmpty) {
      return const ShellPolicyResult(
        decision: ShellPolicyDecision.deny,
        reason: 'empty_command',
      );
    }

    final programs = programsIn(trimmed);
    if (programs.isEmpty) {
      return ShellPolicyResult(
        decision: strictMode
            ? ShellPolicyDecision.deny
            : ShellPolicyDecision.ask,
        reason: 'unparsed_command',
      );
    }

    // Command substitution hides the real program set; never allowlist it.
    if (trimmed.contains(r'$(') || trimmed.contains('`')) {
      return ShellPolicyResult(
        decision: strictMode
            ? ShellPolicyDecision.deny
            : ShellPolicyDecision.ask,
        reason: strictMode ? 'strict' : 'subshell',
        programs: programs,
      );
    }

    final allowed = allowlist
        .map(normalizeProgram)
        .where((program) => program.isNotEmpty)
        .toSet();
    final blocked = <String>[
      for (final program in programs)
        if (!allowed.contains(normalizeProgram(program))) program,
    ];
    if (blocked.isEmpty) {
      return ShellPolicyResult(
        decision: ShellPolicyDecision.allow,
        reason: 'allowlist',
        programs: programs,
      );
    }
    return ShellPolicyResult(
      decision: strictMode ? ShellPolicyDecision.deny : ShellPolicyDecision.ask,
      reason: strictMode ? 'strict' : 'not_allowlisted',
      programs: programs,
      blockedPrograms: blocked,
    );
  }

  /// First program of every compound segment (`&&`, `&`, `||`, `;`, `|`,
  /// newline). Redirection ampersands (`2>&1`, `<&0`) are not separators;
  /// `&&` and `||` are consumed as one separator.
  ///
  /// Quote handling is deliberately conservative: a separator inside quotes
  /// still creates a segment, which can only make the policy stricter (ask
  /// instead of allow), never looser.
  static List<String> programsIn(String command) {
    final segments = _splitSegments(
      command.replaceAll('\r\n', '\n').replaceAll('\r', '\n'),
    );
    final seen = <String>{};
    final programs = <String>[];
    for (final segment in segments) {
      final program = _programOfSegment(segment);
      if (program.isEmpty) continue;
      final normalized = normalizeProgram(program);
      if (normalized.isEmpty || !seen.add(normalized)) continue;
      programs.add(normalized);
    }
    return programs;
  }

  /// Normalize an executable token for comparison/storage: quotes stripped,
  /// path reduced to its basename, Windows script suffixes removed, lower
  /// case (the shell resolves case-insensitively there).
  static String normalizeProgram(String raw) {
    var program = raw.trim();
    if (program.isEmpty) return '';
    if ((program.startsWith('"') && program.endsWith('"')) ||
        (program.startsWith("'") && program.endsWith("'"))) {
      program = program.substring(1, program.length - 1).trim();
    }
    program = program.replaceAll('\\', '/');
    if (program.contains('/')) {
      program = program.substring(program.lastIndexOf('/') + 1);
    }
    final lower = program.toLowerCase();
    for (final suffix in const ['.exe', '.cmd', '.bat', '.com']) {
      if (lower.endsWith(suffix)) {
        return lower.substring(0, lower.length - suffix.length);
      }
    }
    return lower;
  }

  /// Splits command separators without treating redirection `>&`/`<&` as a
  /// command boundary. A bare `&` is a separator on both cmd and POSIX shells
  /// (background execution), so it must participate in the allowlist check.
  static List<String> _splitSegments(String command) {
    final segments = <String>[];
    final buffer = StringBuffer();
    for (var i = 0; i < command.length; i++) {
      final char = command[i];
      final next = i + 1 < command.length ? command[i + 1] : '';
      if (char == '&') {
        if (next == '&') {
          segments.add(buffer.toString());
          buffer.clear();
          i++;
          continue;
        }
        final previous = i > 0 ? command[i - 1] : '';
        if (previous == '>' || previous == '<') {
          buffer.write(char);
          continue;
        }
        segments.add(buffer.toString());
        buffer.clear();
        continue;
      }
      if (char == '|') {
        if (next == '|') i++;
        segments.add(buffer.toString());
        buffer.clear();
        continue;
      }
      if (char == ';' || char == '\n') {
        segments.add(buffer.toString());
        buffer.clear();
        continue;
      }
      buffer.write(char);
    }
    segments.add(buffer.toString());
    return segments;
  }

  static String _programOfSegment(String segment) {
    final trimmed = segment.trim();
    if (trimmed.isEmpty) return '';
    var token = _firstToken(trimmed);
    // Skip leading environment assignments (`FOO=bar git status`).
    while (token.isNotEmpty &&
        RegExp(r'^[A-Za-z_][A-Za-z0-9_]*=').hasMatch(token)) {
      final rest = trimmed.substring(trimmed.indexOf(token) + token.length);
      token = _firstToken(rest.trim());
      if (token.isEmpty) return '';
    }
    return token;
  }

  static String _firstToken(String segment) {
    if (segment.isEmpty) return '';
    final quote = segment[0];
    if (quote == '"' || quote == "'") {
      final end = segment.indexOf(quote, 1);
      return end > 0 ? segment.substring(1, end) : segment.substring(1);
    }
    final match = RegExp(r'\S+').firstMatch(segment);
    return match?.group(0) ?? '';
  }
}
