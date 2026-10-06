// `/skill <name>` invocation resolution (PLAN_AGENT_SKILLS.md §6.2 / §9).
//
// The user-invocation path is deliberately NOT a slash-command system: the
// token lives inside the persisted user message and is re-parsed at every
// message assembly, so regenerate / cross-turn replay reproduce the exact
// same skill load (pure function, deterministic).
//
// Semantics (§9):
// - A token is recognized only when `/skill` (case-insensitive) is followed
//   by a strictly valid skill name — anything else stays untouched so a
//   sentence that merely mentions "/skill" never pollutes the conversation.
// - Hit   → token removed from the user message, full SKILL.md content
//           appended to the system message as `<skill name="…">…</skill>`
//           (one turn's context, capped).
// - Miss  → token KEPT (the user sees the failed attempt), a
//           `<skill_error>` block appended to the system message, and the
//           name reported back for the UI snackbar.
//
// Pure Dart: no Flutter/IO imports; skill loading is injected as a callback.
library;

import '../../models/skill.dart';
import '../tools/tool_result_caps.dart';
import 'skill_parser.dart';

class SkillInvocation {
  const SkillInvocation({
    required this.name,
    required this.tokenStart,
    required this.tokenEnd,
  });

  final String name;

  /// Offsets of the `/skill <name>` token (without the consumed leading
  /// whitespace) inside the message content.
  final int tokenStart;
  final int tokenEnd;
}

class SkillInvocationResolution {
  const SkillInvocationResolution({
    this.failedNames = const <String>[],
    this.changed = false,
  });

  /// Valid-format names that did not resolve to an installed skill.
  final List<String> failedNames;

  /// True when any message was rewritten (token removed or block appended).
  final bool changed;
}

class SkillInvocations {
  SkillInvocations._();

  /// `(?:^|\s)/skill\s+<name>` — keyword case-insensitive; the captured name
  /// is validated against the strict skill-name rule afterwards (so
  /// `/skill Git-Release` or `/skill -foo` stays untouched, §9 R4).
  static final RegExp tokenPattern = RegExp(
    r'(?:^|\s)/skill[ \t]+([a-z0-9][a-z0-9-]*)',
    caseSensitive: false,
  );

  /// Extracts valid-format `/skill <name>` tokens from [text].
  static List<SkillInvocation> extractSkillInvocations(String text) {
    final out = <SkillInvocation>[];
    if (text.isEmpty) return out;
    for (final match in tokenPattern.allMatches(text)) {
      final rawName = match.group(1);
      if (rawName == null) continue;
      // Token offsets exclude any leading whitespace the regex consumed:
      // `(?:^|\s)` eats exactly one whitespace char when it did not match
      // empty `^` at index 0, so the keyword then starts one char later.
      // Never derive this from `match.end` with an assumed single-char
      // separator — `[ \t]+` may span several (e.g. `/skill  name`).
      final keywordStart =
          match.start < text.length && RegExp(r'\s').hasMatch(text[match.start])
              ? match.start + 1
              : match.start;
      if (!SkillParser.isValidSkillName(rawName)) continue;
      out.add(
        SkillInvocation(
          name: rawName,
          tokenStart: keywordStart,
          tokenEnd: match.end,
        ),
      );
    }
    return out;
  }

  /// Resolves `/skill <name>` tokens across all string user messages in
  /// [apiMessages]. Mutates the list in place (assembly-time projection —
  /// Hive history is never touched, ADR-A6).
  ///
  /// [emptyContentPlaceholder] replaces user content that would otherwise
  /// become empty because it consisted only of tokens — several providers
  /// (Anthropic among them) reject empty user content, which made a lone
  /// `/skill name` look like a dead command.
  static SkillInvocationResolution resolveInMessages(
    List<Map<String, dynamic>> apiMessages, {
    required SkillDefinition? Function(String name) loadSkill,
    String emptyContentPlaceholder =
        'Follow the instructions in the skill loaded above.',
  }) {
    var changed = false;
    final failed = <String>[];
    final skillBlocks = <String>[];
    final errorBlocks = <String>[];

    for (final message in apiMessages) {
      if (message['role'] != 'user') continue;
      final content = message['content'];
      if (content is! String || content.isEmpty) continue;
      final invocations = extractSkillInvocations(content);
      if (invocations.isEmpty) continue;

      var updated = content;
      // Process from the end so earlier offsets stay valid while removing.
      for (final inv in invocations.reversed) {
        final skill = loadSkill(inv.name);
        if (skill == null) {
          if (!failed.contains(inv.name)) failed.add(inv.name);
          errorBlocks.add(
            '<skill_error name="${_xmlEscape(inv.name)}">'
            'Skill "${_xmlEscape(inv.name)}" is not installed or could not '
            'be loaded. Inform the user the invocation failed.'
            '</skill_error>',
          );
          continue; // token stays in the message (§9)
        }
        final capped = ToolResultCaps.capBare(skill.content);
        skillBlocks.add(
          '<skill name="${_xmlEscape(skill.name)}">\n$capped\n</skill>',
        );
        updated = updated.replaceRange(inv.tokenStart, inv.tokenEnd, '');
        changed = true;
      }
      if (!identical(updated, content) && updated != content) {
        if (updated.trim().isEmpty && emptyContentPlaceholder.isNotEmpty) {
          updated = emptyContentPlaceholder;
        }
        message['content'] = updated;
      }
    }

    if (skillBlocks.isNotEmpty || errorBlocks.isNotEmpty) {
      final block = [...skillBlocks, ...errorBlocks].join('\n\n');
      appendToSystemMessage(apiMessages, block);
      changed = true;
    }
    return SkillInvocationResolution(failedNames: failed, changed: changed);
  }

  /// Appends [content] to the first system message (creates one when absent).
  static void appendToSystemMessage(
    List<Map<String, dynamic>> apiMessages,
    String content,
  ) {
    if (apiMessages.isNotEmpty && apiMessages.first['role'] == 'system') {
      final existing = (apiMessages.first['content'] ?? '').toString();
      apiMessages.first['content'] = '$existing\n\n$content';
    } else {
      apiMessages.insert(
        0,
        <String, dynamic>{'role': 'system', 'content': content},
      );
    }
  }

  static String _xmlEscape(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');
}
