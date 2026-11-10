import 'image_search/image_search_server.dart' show ImageSearchMcpServerEngine;
import '../chat/todo_models.dart';

/// Per-tool usage policies injected into the system prompt AFTER
/// `buildToolDefinitions()`, keyed by the model-facing function name.
///
/// Contract (docs/image_search_option_a_implementation_plan (已實作).md §2): a policy
/// is injected only when its tool is actually advertised in this request's
/// `toolDefs`. The ONE exception is Gemini native built-ins —
/// `chat_api_service` strips function declarations AFTER assembly, so the call
/// site must additionally gate on `!hasBuiltInSearch`
/// (see message_generation_service.dart).
abstract class McpToolPrompts {
  static const Map<String, String> _byTool = {
    ImageSearchMcpServerEngine.toolName: _imageSearchPolicy,
    todoToolName: _todoPolicy,
  };

  /// Policy text for this request, or null when it must not be injected.
  ///
  /// [hasBuiltInSearch] encodes the Gemini exception: native built-ins strip
  /// every function declaration after assembly, so injecting a policy there
  /// would tell the model to call a tool the request does not contain.
  static String? forRequest({
    required List<Map<String, dynamic>> defs,
    required bool hasBuiltInSearch,
  }) {
    if (hasBuiltInSearch) return null;
    return forDefinitions(defs);
  }

  /// Concatenated policies for the tools actually advertised in [defs], or
  /// null when none match. Accepts both OpenAI-style
  /// `{'type':'function','function':{'name':...}}` and MCP-style
  /// `{'name':...}` shapes (same tolerance as `reviewToolNames`).
  static String? forDefinitions(List<Map<String, dynamic>> defs) {
    final blocks = <String>[];
    final seen = <String>{};
    for (final d in defs) {
      final fn = d['function'];
      final name = fn is Map
          ? (fn['name'] ?? '').toString()
          : (d['name'] ?? '').toString();
      if (name.isEmpty || !seen.add(name)) continue;
      final text = _byTool[name];
      if (text != null) blocks.add(text.trim());
    }
    return blocks.isEmpty ? null : blocks.join('\n\n');
  }

  /// Middle-ground policy (~759 chars / ~190–220 tokens) from
  /// docs/image_search_builtin_vs_mcp_prompt_plan.md §15.8. Keeps the three
  /// high-value constraints — appearance matters, the user explicitly asks for
  /// pictures, identification/comparison/visual reference — while dropping the
  /// detailed bullet structure. Image count is intentionally NOT hard-capped:
  /// one per distinct subject, no repeats, no decorative filler.
  static const String _imageSearchPolicy = '''
## illustrate usage
Use illustrate when the answer involves concrete subjects whose appearance matters (people, products, landmarks, artworks, animals, places), an image would materially help (identification, comparison, visual reference), or the user asks for pictures.
Do not use it for abstract concepts, code, math, definitions, opinions, or decorative filler.
Use as many images as the answer needs: usually one per distinct subject; never repeat an image or query; omit subjects with no good result; never add images just to fill space.
Use only returned URLs; verify the title matches the subject; prefer thumbnail_url; embed as ![alt](url) after the relevant sentence; cite source/license; on failure, continue without images and retry at most once.''';

  /// Anybuff `write-todos.ts` maintenance doctrine, adapted to OmniChat's
  /// three-state schema. Targets the failure mode where the model writes the
  /// plan once and then never reports progress: every call must rewrite the
  /// whole list, and the tool must be used after each completed step.
  static const String _todoPolicy = '''
## write_todos usage
Call write_todos after you have gathered enough context to plan a multi-step task (3+ steps). Send the COMPLETE list every time, ordered the way you will execute it, and include review/validation steps.
After completing each step, call write_todos again to mark that step completed. Rewrite ALL todos with their current statuses on every call — never drop or shorten the list while work remains, and never mark a step completed before it is actually done.
Use it frequently as you work: it keeps you on track and informs the user of the plan and current progress. Keep exactly one item in_progress while working. Use todos: [] only when the plan is cancelled or obsolete.''';
}
