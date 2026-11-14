// Named subagent profiles (docs/子代理P0-P1修正實作計畫.md P1-1).
//
// A profile is the *governance* layer of a helper run: a stable id, the
// instructions injected into the helper's system prompt, an optional tool
// allowlist, a read-only guard, and an optional pre-bound provider/model.
//
// Deliberately Flutter-free and dependency-free so profiles can be asserted
// without a provider tree. The built-in list is immutable authority: stored
// profiles may *replace* a built-in (same id) but never invent a second
// entry with that id.

/// Tools a read-only profile can never execute, even if an allowlist or a
/// stale advertised tool list lets them through (defense in depth).
const Set<String> subagentWriteToolNames = <String>{
  'file_write',
  'file_append',
  'file_edit',
  'file_patch',
  'file_delete',
  'file_move',
  'file_copy',
  'file_mkdir',
  'file_create_pdf',
  'file_extract_zip',
  'shell_run',
  'shell_exec',
  // Memory tools mutate the assistant's memory; a read-only helper must not
  // be able to write it through a stale or custom allowlist.
  'memory_update',
  'memory_edit',
  'memory_delete',
  'create_memory',
  'edit_memory',
  'delete_memory',
  // The parent's plan is a side effect; children are excluded from it and a
  // read-only profile must refuse it as well.
  'write_todos',
};

/// One named helper profile.
class SubagentProfile {
  const SubagentProfile({
    required this.id,
    required this.name,
    required this.description,
    this.instructions = '',
    this.allowedTools,
    this.readOnly = false,
    this.providerKey,
    this.modelId,
    this.maxSteps,
    this.tokenBudget,
    this.builtIn = false,
  });

  final String id;
  final String name;
  final String description;

  /// Profile-specific guidance appended to the helper system prompt.
  final String instructions;

  /// `null` = every child tool (still subject to the base exclusions).
  final Set<String>? allowedTools;

  /// Second line of defense: write/shell tools are refused at execution time.
  final bool readOnly;

  /// Pre-bound provider/model chosen in settings (A5). Both null = follow the
  /// conversation's model; a model without a provider is invalid.
  final String? providerKey;
  final String? modelId;

  /// Optional ceiling; a profile can only LOWER the model-requested budget.
  final int? maxSteps;
  final int? tokenBudget;

  /// Built-ins are always present (may be replaced by the same id).
  final bool builtIn;

  /// True when the profile follows the conversation's model.
  bool get followsConversationModel =>
      (providerKey ?? '').trim().isEmpty || (modelId ?? '').trim().isEmpty;

  /// Whether [toolName] may execute under this profile.
  bool permits(String toolName) {
    final allow = allowedTools;
    if (allow != null && !allow.contains(toolName)) return false;
    if (readOnly && subagentWriteToolNames.contains(toolName)) return false;
    return true;
  }

  SubagentProfile copyWith({
    String? id,
    String? name,
    String? description,
    String? instructions,
    Set<String>? allowedTools,
    bool? readOnly,
    String? providerKey,
    String? modelId,
    int? maxSteps,
    int? tokenBudget,
    bool? builtIn,
    bool clearModel = false,
    bool clearMaxSteps = false,
    bool clearTokenBudget = false,
    bool clearAllowedTools = false,
  }) {
    return SubagentProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      instructions: instructions ?? this.instructions,
      allowedTools: clearAllowedTools
          ? null
          : (allowedTools ?? this.allowedTools),
      readOnly: readOnly ?? this.readOnly,
      providerKey: clearModel ? null : (providerKey ?? this.providerKey),
      modelId: clearModel ? null : (modelId ?? this.modelId),
      maxSteps: clearMaxSteps ? null : (maxSteps ?? this.maxSteps),
      tokenBudget: clearTokenBudget ? null : (tokenBudget ?? this.tokenBudget),
      builtIn: builtIn ?? this.builtIn,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'description': description,
    'instructions': instructions,
    if (allowedTools != null)
      'allowedTools': allowedTools!.toList(growable: false),
    'readOnly': readOnly,
    if (providerKey != null && providerKey!.trim().isNotEmpty)
      'providerKey': providerKey,
    if (modelId != null && modelId!.trim().isNotEmpty) 'modelId': modelId,
    if (maxSteps != null) 'maxSteps': maxSteps,
    if (tokenBudget != null) 'tokenBudget': tokenBudget,
  };

  /// Fail-open parse: a malformed profile is skipped by the caller, never
  /// turned into an exception.
  static SubagentProfile? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final map = raw.map((key, value) => MapEntry(key.toString(), value));
    final id = (map['id'] ?? '').toString().trim();
    if (!SubagentProfiles.isValidId(id)) return null;
    final name = (map['name'] ?? '').toString().trim();
    if (name.isEmpty) return null;

    Set<String>? allowed;
    final rawAllowed = map['allowedTools'];
    if (rawAllowed is List) {
      allowed = <String>{
        for (final item in rawAllowed)
          if (item.toString().trim().isNotEmpty) item.toString().trim(),
      };
    }

    int? positiveInt(Object? value) {
      if (value is num) {
        final v = value.toInt();
        return v > 0 ? v : null;
      }
      if (value is String) {
        final v = int.tryParse(value.trim());
        return v != null && v > 0 ? v : null;
      }
      return null;
    }

    final provider = (map['providerKey'] ?? '').toString().trim();
    final model = (map['modelId'] ?? '').toString().trim();
    // A half-specified model is dropped (A5: provider+model are a pair).
    final hasModel = provider.isNotEmpty && model.isNotEmpty;
    final readOnly = map['readOnly'] == true;
    // Stored data can predate a write tool being added to the guard. Drop it
    // on load so the editor never displays a checked-but-disabled write tool
    // and the persisted allowlist matches what `permits()` will enforce.
    if (readOnly && allowed != null) {
      allowed.removeWhere(subagentWriteToolNames.contains);
    }

    return SubagentProfile(
      id: id,
      name: name,
      description: (map['description'] ?? '').toString(),
      instructions: (map['instructions'] ?? '').toString(),
      allowedTools: allowed,
      readOnly: readOnly,
      providerKey: hasModel ? provider : null,
      modelId: hasModel ? model : null,
      maxSteps: positiveInt(map['maxSteps'])?.clamp(1, 40),
      tokenBudget: positiveInt(map['tokenBudget']),
      builtIn: SubagentProfiles.builtInIds.contains(id),
    );
  }
}

/// The profile registry: built-ins, storage merge and lookup.
abstract final class SubagentProfiles {
  /// Stored-profile ceiling (built-ins included).
  static const int maxProfiles = 20;

  static const int maxNameChars = 80;
  static const int maxDescriptionChars = 400;
  static const int maxInstructionsChars = 8000;

  static final RegExp _idPattern = RegExp(r'^[a-z][a-z0-9_-]{0,39}$');

  static bool isValidId(String id) => _idPattern.hasMatch(id);

  static const List<SubagentProfile> builtIns = <SubagentProfile>[
    SubagentProfile(
      id: 'general',
      name: 'General',
      description: 'Full helper: every child tool, no extra restrictions.',
      builtIn: true,
    ),
    SubagentProfile(
      id: 'explore',
      name: 'Explore',
      description: 'Read-only exploration of the workspace.',
      instructions:
          'You are exploring an existing codebase. Read before you reason, '
          'cite concrete paths and line numbers, and never guess file '
          'contents. You cannot modify anything.',
      allowedTools: <String>{
        'file_read',
        'file_list',
        'file_info',
        'file_search',
        'file_grep',
        'file_view_image',
        'file_extract_text',
      },
      readOnly: true,
      builtIn: true,
    ),
    SubagentProfile(
      id: 'reviewer',
      name: 'Reviewer',
      description: 'Read-only code review with console diagnostics.',
      instructions:
          'You review code for correctness, regressions and missing edge '
          'cases. Quote the exact path and line, state severity, and prefer '
          'a small number of high-value findings over a long checklist.',
      allowedTools: <String>{
        'file_read',
        'file_list',
        'file_info',
        'file_search',
        'file_grep',
        'file_view_image',
        'file_extract_text',
        'get_console_errors',
      },
      readOnly: true,
      builtIn: true,
    ),
    SubagentProfile(
      id: 'researcher',
      name: 'Researcher',
      description: 'Read-only workspace + web research.',
      instructions:
          'You collect facts from the workspace and the web. Prefer primary '
          'sources, record where each fact came from, and mark anything you '
          'could not verify as unverified.',
      allowedTools: <String>{
        'file_read',
        'file_list',
        'file_info',
        'file_search',
        'file_grep',
        'file_view_image',
        'file_extract_text',
        'web_fetch',
        'search_web',
      },
      readOnly: true,
      builtIn: true,
    ),
    SubagentProfile(
      id: 'coder',
      name: 'Coder',
      description: 'Implementation helper: may read, write and run tools.',
      instructions:
          'You implement changes end to end. Read the surrounding code first, '
          'make the smallest correct edit, and verify with the tools you have '
          'before reporting.',
      builtIn: true,
    ),
  ];

  static final Set<String> builtInIds = <String>{
    for (final p in builtIns) p.id,
  };

  static SubagentProfile builtIn(String id) =>
      builtIns.firstWhere((p) => p.id == id, orElse: () => builtIns.first);

  /// Merge a stored list over the built-ins: every built-in stays available
  /// (a stored entry with the same id replaces it), customs follow in stored
  /// order, duplicates and invalid ids are dropped, and the list is capped.
  static List<SubagentProfile> mergeWithBuiltIns(
    Iterable<SubagentProfile> stored,
  ) {
    final byId = <String, SubagentProfile>{for (final p in builtIns) p.id: p};
    final order = <String>[for (final p in builtIns) p.id];
    for (final p in stored) {
      if (!isValidId(p.id)) continue;
      if (!byId.containsKey(p.id)) order.add(p.id);
      byId[p.id] = byId.containsKey(p.id) && builtInIds.contains(p.id)
          ? p.copyWith(builtIn: true)
          : p;
      if (order.length >= maxProfiles) break;
    }
    return <SubagentProfile>[
      for (final id in order)
        if (byId[id] != null) byId[id]!,
    ];
  }

  /// Look up [id]; unknown ids return null (the caller reports
  /// `unknown_agent`). An empty id resolves to `general`.
  static SubagentProfile? resolve(
    String? id,
    Iterable<SubagentProfile> profiles,
  ) {
    final key = (id ?? '').trim();
    final target = key.isEmpty ? 'general' : key;
    for (final p in profiles) {
      if (p.id == target) return p;
    }
    for (final p in builtIns) {
      if (p.id == target) return p;
    }
    return null;
  }

  static List<String> availableIds(Iterable<SubagentProfile> profiles) =>
      <String>[for (final p in profiles) p.id];

  /// Validation shared by the settings setter and the editor. Returns a
  /// localized-key-friendly error code, or null when valid.
  static String? validate(SubagentProfile profile, {required bool isNew}) {
    if (!isValidId(profile.id)) return 'invalid_id';
    if (isNew && builtInIds.contains(profile.id)) return 'built_in_id';
    if (profile.name.trim().isEmpty) return 'name_required';
    if (profile.name.length > maxNameChars) return 'name_too_long';
    if (profile.description.length > maxDescriptionChars) {
      return 'description_too_long';
    }
    if (profile.instructions.length > maxInstructionsChars) {
      return 'instructions_too_long';
    }
    final provider = (profile.providerKey ?? '').trim();
    final model = (profile.modelId ?? '').trim();
    if (provider.isEmpty != model.isEmpty) return 'model_pair_required';
    if (profile.maxSteps != null &&
        (profile.maxSteps! < 1 || profile.maxSteps! > 40)) {
      return 'max_steps_out_of_range';
    }
    if (profile.tokenBudget != null && profile.tokenBudget! <= 0) {
      return 'token_budget_out_of_range';
    }
    return null;
  }
}
