// P1-3 ask_user models — kelivo `ask_user_input_v0` data discipline
// (IMPORT_PLAN_COWORK.md P1-3).
//
// Pure Dart: normalization limits, the structured answer payload, and the
// tool-result protocol strings shared by the tool handler and the
// interactive card. Pending/answered state is carried entirely by the
// persisted tool-event content JSON (`ask_user_pending` / `ask_user_answer`),
// so rendering needs no live service.
library;

import 'dart:convert';

/// Tool name constant (single source of truth).
const String askUserToolName = 'ask_user';

/// Max questions per ask_user call (kelivo discipline: ≤4).
const int askUserMaxQuestions = 4;

/// Max options per question (kelivo discipline: ≤4, UI adds Other + Skip).
const int askUserMaxOptions = 4;

class AskUserQuestion {
  final String id;
  final String question;

  /// `'single'` (radio) or `'multi'` (checkbox).
  final String kind;
  final List<String> options;

  const AskUserQuestion({
    required this.id,
    required this.question,
    required this.kind,
    required this.options,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'question': question,
        'kind': kind,
        'options': options,
      };

  static AskUserQuestion fromJson(Map<String, dynamic> json) {
    return AskUserQuestion(
      id: (json['id'] ?? '').toString(),
      question: (json['question'] ?? '').toString(),
      kind: json['kind'] == 'multi' ? 'multi' : 'single',
      options: (json['options'] as List?)
              ?.map((e) => e.toString())
              .where((e) => e.trim().isNotEmpty)
              .toList() ??
          const <String>[],
    );
  }
}

/// Normalize the model's `questions` argument: cap counts, drop empties,
/// dedupe ids and reindex (`q1`, `q2`, …). Returns an empty list for
/// invalid input.
List<AskUserQuestion> normalizeAskUserQuestions(dynamic raw) {
  if (raw is! List) return const <AskUserQuestion>[];
  final out = <AskUserQuestion>[];
  var index = 0;
  for (final item in raw) {
    if (out.length >= askUserMaxQuestions) break;
    if (item is! Map) continue;
    final question =
        (item['question'] ?? item['text'] ?? '').toString().trim();
    if (question.isEmpty) continue;
    final kind = item['kind'].toString() == 'multi' ? 'multi' : 'single';
    final options = (item['options'] as List?)
            ?.map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .take(askUserMaxOptions)
            .toList() ??
        <String>[];
    out.add(AskUserQuestion(
      id: 'q${++index}',
      question: question,
      kind: kind,
      options: options,
    ));
  }
  return out;
}

/// One answered question in the structured answer payload.
class AskUserAnswerEntry {
  final String id;
  final String question;

  /// Selected option labels (empty when skipped / other-only).
  final List<String> selected;

  /// Free text from the Other field (empty when unused).
  final String other;
  final bool skipped;

  const AskUserAnswerEntry({
    required this.id,
    required this.question,
    this.selected = const <String>[],
    this.other = '',
    this.skipped = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'question': question,
        'selected': selected,
        'other': other,
        'skipped': skipped,
      };

  /// Human-readable summary used by the answered card and the model-facing
  /// tool result.
  String toDisplayText() {
    if (skipped) return '(skipped)';
    final parts = <String>[
      ...selected,
      if (other.trim().isNotEmpty) other.trim(),
    ];
    if (parts.isEmpty) return '(no answer)';
    return parts.join(', ');
  }
}

/// Content marker for a tool event whose questions are awaiting user input.
const String askUserPendingType = 'ask_user_pending';

/// Content marker for an answered ask_user tool event.
const String askUserAnswerType = 'ask_user_answer';

/// Build the pending tool-result JSON persisted on the ask_user event.
String buildAskUserPendingContent(List<AskUserQuestion> questions) {
  return jsonEncode({
    'type': askUserPendingType,
    'questions': [for (final q in questions) q.toJson()],
  });
}

/// Build the answered tool-result JSON persisted on the ask_user event and
/// returned to the model on resume.
String buildAskUserAnswerContent(List<AskUserAnswerEntry> answers) {
  return jsonEncode({
    'type': askUserAnswerType,
    'answers': [for (final a in answers) a.toJson()],
  });
}

/// Parse a tool-event content string into its protocol type and payload.
/// Returns `{type, questions?, answers?}` or null for non-ask_user content.
Map<String, dynamic>? parseAskUserContent(String? content) {
  if (content == null || content.trim().isEmpty) return null;
  try {
    final obj = jsonDecode(content);
    if (obj is! Map) return null;
    final type = (obj['type'] ?? '').toString();
    if (type != askUserPendingType && type != askUserAnswerType) return null;
    return Map<String, dynamic>.from(obj);
  } catch (_) {
    return null;
  }
}

/// Parse the pending JSON's question list.
List<AskUserQuestion> questionsFromPendingContent(Map<String, dynamic> obj) {
  return normalizeAskUserQuestions(obj['questions']);
}

/// Parse the answered JSON's answer list.
List<AskUserAnswerEntry> answersFromAnswerContent(Map<String, dynamic> obj) {
  final raw = obj['answers'];
  if (raw is! List) return const <AskUserAnswerEntry>[];
  return raw
      .whereType<Map>()
      .map((m) => AskUserAnswerEntry(
            id: (m['id'] ?? '').toString(),
            question: (m['question'] ?? '').toString(),
            selected: (m['selected'] as List?)
                    ?.map((e) => e.toString())
                    .toList() ??
                const <String>[],
            other: (m['other'] ?? '').toString(),
            skipped: m['skipped'] == true,
          ))
      .toList();
}
