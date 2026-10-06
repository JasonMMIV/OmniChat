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
// - Hit   → token removed; the message is rebuilt around Anybuff's
//           `buildFinalPrompt` frame (2026-10-06 revision): an explicit
//           `I invoke the following skill: …` line, the `<skill name="…">`
//           blocks (frontmatter stripped, capped), and — when text remains —
//           `User request: …` last. Without the explicit frame, models read
//           the frontmatter gating wording ("use ONLY when the user
//           explicitly…") and second-guessed whether the skill was active.
// - Miss  → token KEPT (the user sees the failed attempt); a
//           `<skill_error>` block is appended to the same user message and
//           the name reported back for the UI snackbar.
//
// User-turn delivery (2026-10-06 hands-on fix): the blocks used to be
// appended to the system message, but models then processed the
// token-stripped user turn as a plain request and never started the skill.
// The invoked skill must ride the message that carried the token. The
// system message is never touched by this resolver.
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

  /// Valid-format `/skill <name>` names in [text], token order, deduped.
  /// UI surfaces (bubble chip, `/skill` load rows) derive their labels from
  /// this so every consumer agrees on what was invoked.
  static List<String> extractSkillNames(String text) {
    final names = <String>[];
    for (final invocation in extractSkillInvocations(text)) {
      if (!names.contains(invocation.name)) names.add(invocation.name);
    }
    return names;
  }

  /// Resolves `/skill <name>` tokens across all string user messages in
  /// [apiMessages]. Mutates the list in place (assembly-time projection —
  /// Hive history is never touched, ADR-A6).
  ///
  /// Per message: hit tokens are removed and the message is rebuilt around
  /// Anybuff's `buildFinalPrompt` frame — an explicit
  /// `I invoke the following skill: …` line, the `<skill>` blocks (in token
  /// order; a repeated invocation of the same skill contributes a single
  /// block), then the remaining text under a `User request:` label. With no
  /// remaining text the frame is just the line plus blocks (never empty
  /// content, which providers like Anthropic reject). Miss tokens stay in
  /// place and gain a `<skill_error>` block at the end so the model can tell
  /// the user the invocation failed.
  static SkillInvocationResolution resolveInMessages(
    List<Map<String, dynamic>> apiMessages, {
    required SkillDefinition? Function(String name) loadSkill,
  }) {
    var changed = false;
    final failed = <String>[];

    for (final message in apiMessages) {
      if (message['role'] != 'user') continue;
      final content = message['content'];
      if (content is! String || content.isEmpty) continue;
      final invocations = extractSkillInvocations(content);
      if (invocations.isEmpty) continue;

      final hitBlocks = <String>[];
      final hitNames = <String>[];
      final errorBlocks = <String>[];
      final removedTokens = <SkillInvocation>[];
      final seenNames = <String>{};
      // Forward pass so block order is token order. A duplicated invocation
      // of the same skill contributes one block — the extra tokens are
      // still removed (hit) or kept (miss) as written.
      for (final inv in invocations) {
        final skill = loadSkill(inv.name);
        if (skill == null) {
          if (!failed.contains(inv.name)) failed.add(inv.name);
          if (seenNames.add(inv.name)) {
            errorBlocks.add(
              '<skill_error name="${_xmlEscape(inv.name)}">'
              'Skill "${_xmlEscape(inv.name)}" is not installed or could not '
              'be loaded. Inform the user the invocation failed.'
              '</skill_error>',
            );
          }
          continue; // token stays in the message (§9)
        }
        if (seenNames.add(inv.name)) {
          // Frontmatter is stripped from the activated payload (2026-10-06):
          // its `description` gating wording ("use ONLY when…") made models
          // question whether the skill was active even though the user had
          // just invoked it.
          final capped = ToolResultCaps.capBare(
            SkillParser.stripFrontmatter(skill.content),
          );
          hitNames.add(skill.name);
          hitBlocks.add(
            '<skill name="${_xmlEscape(skill.name)}">\n$capped\n</skill>',
          );
        }
        removedTokens.add(inv);
      }

      // Remove hit tokens back-to-front so earlier offsets stay valid.
      var updated = content;
      for (final inv in removedTokens.reversed) {
        updated = updated.replaceRange(inv.tokenStart, inv.tokenEnd, '');
      }

      final remainder = updated.trim();
      final sections = <String>[];
      if (hitBlocks.isNotEmpty) {
        sections.add(
          hitNames.length == 1
              ? 'I invoke the following skill: ${hitNames.single}'
              : 'I invoke the following skills: ${hitNames.join(', ')}',
        );
        sections.addAll(hitBlocks);
        if (remainder.isNotEmpty) sections.add('User request: $remainder');
      } else if (remainder.isNotEmpty) {
        // Miss-only message: the token(s) stay in place (§9).
        sections.add(remainder);
      }
      sections.addAll(errorBlocks);
      message['content'] = sections.join('\n\n');
      changed = true;
    }

    return SkillInvocationResolution(failedNames: failed, changed: changed);
  }

  static String _xmlEscape(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');
}
