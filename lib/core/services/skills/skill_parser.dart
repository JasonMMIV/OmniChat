// Agent Skills parser (PLAN_AGENT_SKILLS.md §3.2).
//
// Pure Dart — no Flutter/IO imports — so parsing, validation and document
// assembly are unit-testable without bindings (mirrors how Anybuff keeps
// `parseSkillFileContent` in `common`).
//
// Frontmatter is parsed by a deliberately minimal, forgiving reader instead
// of the `yaml` package (pubspec has no such dependency and skill frontmatter
// is a flat subset: scalar `key: value` pairs plus one ignored nested block).
// Unknown/invalid structures never throw — a file either yields a valid
// SkillDefinition or null.
library;

import '../../models/skill.dart';

class SkillParser {
  SkillParser._();

  /// Frontmatter `name` rule (Anybuff `common/src/constants/skills.ts`):
  /// lowercase letters/digits, single hyphens as separators, 1–64 chars.
  static final RegExp namePattern = RegExp(r'^[a-z0-9]+(-[a-z0-9]+)*$');

  static const int maxNameLength = 64;

  /// `description` beyond this length is clamped (truncated, never rejected —
  /// an over-long description is a display concern, not a validity concern).
  static const int maxDescriptionLength = 1024;

  /// Name of the markdown file every skill folder must contain. Matching is
  /// case-insensitive on load (SKILL.md / skill.md / Skill.md all accepted).
  static const String skillFileName = 'SKILL.md';

  /// Parses the raw text of a SKILL.md into a [SkillDefinition].
  ///
  /// Returns null when: no frontmatter, missing `name`/`description`,
  /// invalid name (regex/length), or name ≠ [directoryName] (the loader
  /// addresses skills by folder; a mismatched key would be unreachable).
  static SkillDefinition? parseSkillFileContent(
    String content, {
    required String directoryName,
    required String filePath,
    SkillScope scope = SkillScope.global,
    int fileCount = 1,
  }) {
    final fm = parseFrontmatter(content);
    if (fm == null) return null;

    final name = fm['name'];
    final description = fm['description'];
    if (name == null || name.isEmpty) return null;
    if (description == null) return null;
    if (!isValidSkillName(name)) return null;
    if (name != directoryName) return null;

    final license = fm['license'];
    final disableRaw = fm['disable-model-invocation']?.toLowerCase();
    final disableModelInvocation = disableRaw == 'true';

    // Best-effort provenance from the metadata block (stamped by our own
    // installer; absent for skills installed by other tools).
    final metadata = parseMetadataBlock(content);
    final source = SkillInstallSourceCodec.fromValue(metadata['source']);
    DateTime? installedAt;
    final rawInstalledAt = metadata['installedAt'];
    if (rawInstalledAt != null && rawInstalledAt.isNotEmpty) {
      installedAt = DateTime.tryParse(rawInstalledAt);
    }

    return SkillDefinition(
      name: name,
      description: clampDescription(description),
      license: (license == null || license.isEmpty) ? null : license,
      disableModelInvocation: disableModelInvocation,
      content: content,
      filePath: filePath,
      scope: scope,
      fileCount: fileCount < 1 ? 1 : fileCount,
      source: source,
      installedAt: installedAt,
    );
  }

  /// Extracts the frontmatter `name` cheaply — used by the import path, which
  /// needs the install key before a full parse (mirrors Anybuff's
  /// `extractSkillName`).
  static String? extractSkillName(String content) {
    final fm = parseFrontmatter(content);
    final name = fm?['name'];
    if (name == null || name.isEmpty) return null;
    return name;
  }

  /// Validity of a bare skill name (folder or `/skill <name>` argument).
  static bool isValidSkillName(String name) {
    if (name.isEmpty || name.length > maxNameLength) return false;
    return namePattern.hasMatch(name);
  }

  /// Clamps `description` to [maxDescriptionLength] (never rejects).
  static String clampDescription(String description) {
    final trimmed = description.trim();
    if (trimmed.length <= maxDescriptionLength) return trimmed;
    return trimmed.substring(0, maxDescriptionLength);
  }

  /// Parses the leading `---\n...\n---` frontmatter into a flat map of
  /// top-level scalar keys. Returns null when there is no frontmatter.
  ///
  /// Forgiving by design: bare and quoted scalar values, `#` comments and
  /// blank lines are skipped; the nested `metadata:` block is ignored here.
  static Map<String, String>? parseFrontmatter(String content) {
    final normalized = content.replaceFirst(RegExp(r'^\uFEFF'), '');
    final lines = normalized.split('\n');
    var i = 0;
    while (i < lines.length && lines[i].trim().isEmpty) {
      i++;
    }
    if (i >= lines.length || lines[i].trim() != '---') return null;
    i++;

    final result = <String, String>{};
    for (; i < lines.length; i++) {
      final raw = lines[i];
      final trimmed = raw.trim();
      if (trimmed == '---') break;
      if (trimmed.isEmpty) continue;
      if (trimmed.startsWith('#')) continue;
      // Nested block (e.g. metadata:) — skip the whole indented section.
      if (raw.startsWith(' ') || raw.startsWith('\t')) continue;
      final idx = trimmed.indexOf(':');
      if (idx <= 0) continue;
      final key = trimmed.substring(0, idx).trim();
      var value = trimmed.substring(idx + 1).trim();
      if (key.isEmpty) continue;
      value = _unquote(_stripInlineComment(value));
      result[key] = value;
    }
    return result;
  }

  /// Reads the top-level `metadata:` block's one-level-indented scalar pairs
  /// (provenance stamp: `source`, `installedAt`). Lenient — unknown shapes
  /// simply contribute nothing.
  static Map<String, String> parseMetadataBlock(String content) {
    final result = <String, String>{};
    final lines = content.replaceFirst(RegExp(r'^\uFEFF'), '').split('\n');
    var i = 0;
    while (i < lines.length && lines[i].trim().isEmpty) {
      i++;
    }
    if (i >= lines.length || lines[i].trim() != '---') return result;
    i++;
    var inMetadata = false;
    for (; i < lines.length; i++) {
      final raw = lines[i];
      final trimmed = raw.trim();
      if (trimmed == '---') break;
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      if (!raw.startsWith(' ') && !raw.startsWith('\t')) {
        final idx = trimmed.indexOf(':');
        final key = idx <= 0 ? '' : trimmed.substring(0, idx).trim();
        inMetadata = key == 'metadata';
        continue;
      }
      if (!inMetadata) continue;
      final idx = trimmed.indexOf(':');
      if (idx <= 0) continue;
      final key = trimmed.substring(0, idx).trim();
      var value = trimmed.substring(idx + 1).trim();
      if (key.isEmpty) continue;
      value = _stripInlineComment(_unquote(value));
      result[key] = value;
    }
    return result;
  }

  /// Assembles a new SKILL.md document for [buildDocument].
  ///
  /// `description` is escaped with [yamlScalar] so colons / quotes / hashes
  /// in the text cannot corrupt the frontmatter (a JSON string literal is a
  /// legal YAML double-quoted scalar, so quoting is always safe).
  static String buildSkillDocument({
    required String name,
    required String description,
    required String body,
  }) {
    final buf = StringBuffer()
      ..writeln('---')
      ..writeln('name: $name')
      ..writeln('description: ${yamlScalar(description)}');
    if (body.trim().isNotEmpty) {
      buf
        ..writeln('---')
        ..writeln()
        ..writeln(body.trim())
        ..writeln();
    } else {
      buf
        ..writeln('---')
        ..writeln();
    }
    return buf.toString();
  }

  /// Escapes [value] as a safe YAML scalar: JSON double-quoted when the text
  /// contains YAML-special characters or line breaks, bare otherwise.
  static String yamlScalar(String value) {
    final needsQuote = value.isEmpty ||
        _yamlSpecialChars.hasMatch(value) ||
        value.contains('\n') ||
        value.contains('\r') ||
        value != value.trim();
    if (!needsQuote) return value;
    final escaped = value
        .replaceAll('\\', '\\\\')
        .replaceAll('"', '\\"')
        .replaceAll('\n', '\\n')
        .replaceAll('\r', '\\r')
        .replaceAll('\t', '\\t');
    return '"$escaped"';
  }

  // YAML-special scalar characters (quoted explicitly so the regex is
  // readable): colon, hash, brackets, braces, and the YAML indicator set.
  static final RegExp _yamlSpecialChars = RegExp(
    r'["\\#:<>[\]{}&*!|>%@`''~]',
  );

  /// Strips a YAML inline comment (` # ...`) from an unquoted scalar value.
  /// A `#` only opens a comment at the start or preceded by whitespace.
  static String _stripInlineComment(String value) {
    if (value.startsWith('"') || value.startsWith("'")) return value;
    for (var i = 0; i < value.length; i++) {
      if (value.codeUnitAt(i) == 0x23 /* # */ &&
          (i == 0 || _isWhitespace(value.codeUnitAt(i - 1)))) {
        return value.substring(0, i).trim();
      }
    }
    return value;
  }

  static bool _isWhitespace(int codeUnit) =>
      codeUnit == 0x20 || codeUnit == 0x09;

  /// Removes one layer of matching single/double quotes and unescapes the
  /// JSON-style escapes a double-quoted YAML scalar may carry.
  static String _unquote(String value) {
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      final inner = value.substring(1, value.length - 1);
      return inner
          .replaceAllMapped(RegExp(r'\\(.)'), (m) {
            switch (m.group(1)) {
              case 'n':
                return '\n';
              case 't':
                return '\t';
              case 'r':
                return '\r';
              default:
                return m.group(1)!;
            }
          })
          .replaceAll('\\\\', '\\');
    }
    if (value.length >= 2 && value.startsWith("'") && value.endsWith("'")) {
      return value
          .substring(1, value.length - 1)
          .replaceAll("''", "'");
    }
    return value;
  }
}
