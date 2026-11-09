import 'image_search/image_search_server.dart' show ImageSearchMcpServerEngine;

/// Per-tool usage policies injected into the system prompt AFTER
/// `buildToolDefinitions()`, keyed by the model-facing function name.
///
/// Contract (docs/image_search_option_a_implementation_plan.md §2): a policy
/// is injected only when its tool is actually advertised in this request's
/// `toolDefs`. The ONE exception is Gemini native built-ins —
/// `chat_api_service` strips function declarations AFTER assembly, so the call
/// site must additionally gate on `!hasBuiltInSearch`
/// (see message_generation_service.dart).
abstract class McpToolPrompts {
  static const Map<String, String> _byTool = {
    ImageSearchMcpServerEngine.toolName: _imageSearchPolicy,
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
Use only returned URLs; verify the title matches the subject; prefer thumbnail_url; embed as ![alt](<url>) after the relevant sentence; cite source/license; on failure, continue without images and retry at most once.''';
}
