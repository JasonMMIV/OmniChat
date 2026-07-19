class AiTeamModelSlot {
  final String providerKey;
  final String modelId;

  const AiTeamModelSlot({
    required this.providerKey,
    required this.modelId,
  });

  AiTeamModelSlot copyWith({
    String? providerKey,
    String? modelId,
  }) {
    return AiTeamModelSlot(
      providerKey: providerKey ?? this.providerKey,
      modelId: modelId ?? this.modelId,
    );
  }

  Map<String, dynamic> toJson() => {
        'providerKey': providerKey,
        'modelId': modelId,
      };

  static AiTeamModelSlot fromJson(Map<String, dynamic> json) => AiTeamModelSlot(
        providerKey: (json['providerKey'] as String?) ?? '',
        modelId: (json['modelId'] as String?) ?? '',
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AiTeamModelSlot &&
          providerKey == other.providerKey &&
          modelId == other.modelId;

  @override
  int get hashCode => providerKey.hashCode ^ modelId.hashCode;
}

enum AiTeamMode { parallel, chain }

class AiTeamConfig {
  final bool enabled;
  final AiTeamMode mode;
  final int proposerCount; // 1~4 (Parallel mode)
  final int criticCount; // 0~3 (Chain mode)
  final List<AiTeamModelSlot?> proposers; // length always 4.
  // Parallel mode: uses first proposerCount slots
  // Chain mode: proposers[0] is Proposer, proposers[1] to proposers[criticCount] are Critics.
  final AiTeamModelSlot? aggregator; // null = use current model
  final String proposalSystemPrompt;
  final String aggregatorSystemPrompt;
  final bool useDefaultProposalPrompt;
  final bool useDefaultAggregatorPrompt;

  // Chain mode prompts
  final String chainProposerSystemPrompt;
  final String chainCriticSystemPrompt;
  final String chainAggregatorSystemPrompt;
  final bool useDefaultChainProposerPrompt;
  final bool useDefaultChainCriticPrompt;
  final bool useDefaultChainAggregatorPrompt;

  const AiTeamConfig({
    this.enabled = false,
    this.mode = AiTeamMode.parallel,
    this.proposerCount = 2,
    this.criticCount = 1,
    this.proposers = const [null, null, null, null],
    this.aggregator,
    this.proposalSystemPrompt = AiTeamConfigDefaults.defaultProposalPrompt,
    this.aggregatorSystemPrompt = AiTeamConfigDefaults.defaultAggregatorPrompt,
    this.useDefaultProposalPrompt = true,
    this.useDefaultAggregatorPrompt = true,
    this.chainProposerSystemPrompt = AiTeamConfigDefaults.defaultChainProposerPrompt,
    this.chainCriticSystemPrompt = AiTeamConfigDefaults.defaultChainCriticPrompt,
    this.chainAggregatorSystemPrompt = AiTeamConfigDefaults.defaultChainAggregatorPrompt,
    this.useDefaultChainProposerPrompt = true,
    this.useDefaultChainCriticPrompt = true,
    this.useDefaultChainAggregatorPrompt = true,
  });

  AiTeamConfig copyWith({
    bool? enabled,
    AiTeamMode? mode,
    int? proposerCount,
    int? criticCount,
    List<AiTeamModelSlot?>? proposers,
    AiTeamModelSlot? aggregator,
    String? proposalSystemPrompt,
    String? aggregatorSystemPrompt,
    bool? useDefaultProposalPrompt,
    bool? useDefaultAggregatorPrompt,
    String? chainProposerSystemPrompt,
    String? chainCriticSystemPrompt,
    String? chainAggregatorSystemPrompt,
    bool? useDefaultChainProposerPrompt,
    bool? useDefaultChainCriticPrompt,
    bool? useDefaultChainAggregatorPrompt,
  }) {
    return AiTeamConfig(
      enabled: enabled ?? this.enabled,
      mode: mode ?? this.mode,
      proposerCount: proposerCount ?? this.proposerCount,
      criticCount: criticCount ?? this.criticCount,
      proposers: proposers ?? this.proposers,
      aggregator: aggregator ?? this.aggregator,
      proposalSystemPrompt: proposalSystemPrompt ?? this.proposalSystemPrompt,
      aggregatorSystemPrompt: aggregatorSystemPrompt ?? this.aggregatorSystemPrompt,
      useDefaultProposalPrompt: useDefaultProposalPrompt ?? this.useDefaultProposalPrompt,
      useDefaultAggregatorPrompt: useDefaultAggregatorPrompt ?? this.useDefaultAggregatorPrompt,
      chainProposerSystemPrompt: chainProposerSystemPrompt ?? this.chainProposerSystemPrompt,
      chainCriticSystemPrompt: chainCriticSystemPrompt ?? this.chainCriticSystemPrompt,
      chainAggregatorSystemPrompt: chainAggregatorSystemPrompt ?? this.chainAggregatorSystemPrompt,
      useDefaultChainProposerPrompt: useDefaultChainProposerPrompt ?? this.useDefaultChainProposerPrompt,
      useDefaultChainCriticPrompt: useDefaultChainCriticPrompt ?? this.useDefaultChainCriticPrompt,
      useDefaultChainAggregatorPrompt: useDefaultChainAggregatorPrompt ?? this.useDefaultChainAggregatorPrompt,
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'mode': mode.name,
        'proposerCount': proposerCount,
        'criticCount': criticCount,
        'proposers': proposers
            .map((e) => e == null ? null : e.toJson())
            .toList(growable: false),
        'aggregator': aggregator == null ? null : aggregator!.toJson(),
        'proposalSystemPrompt': proposalSystemPrompt,
        'aggregatorSystemPrompt': aggregatorSystemPrompt,
        'useDefaultProposalPrompt': useDefaultProposalPrompt,
        'useDefaultAggregatorPrompt': useDefaultAggregatorPrompt,
        'chainProposerSystemPrompt': chainProposerSystemPrompt,
        'chainCriticSystemPrompt': chainCriticSystemPrompt,
        'chainAggregatorSystemPrompt': chainAggregatorSystemPrompt,
        'useDefaultChainProposerPrompt': useDefaultChainProposerPrompt,
        'useDefaultChainCriticPrompt': useDefaultChainCriticPrompt,
        'useDefaultChainAggregatorPrompt': useDefaultChainAggregatorPrompt,
      };

  static AiTeamConfig fromJson(Map<String, dynamic> json) {
    final proposersRaw = (json['proposers'] as List?) ?? const [];
    final proposers = List<AiTeamModelSlot?>.filled(4, null);
    for (var i = 0; i < 4 && i < proposersRaw.length; i++) {
      final e = proposersRaw[i];
      if (e != null && e is Map<String, dynamic>) {
        proposers[i] = AiTeamModelSlot.fromJson(e);
      }
    }
    final aggRaw = json['aggregator'];
    return AiTeamConfig(
      enabled: (json['enabled'] as bool?) ?? false,
      mode: AiTeamMode.values.firstWhere(
        (e) => e.name == json['mode'],
        orElse: () => AiTeamMode.parallel,
      ),
      proposerCount: (json['proposerCount'] as int?) ?? 2,
      criticCount: (json['criticCount'] as int?) ?? 1,
      proposers: proposers,
      aggregator: (aggRaw != null && aggRaw is Map<String, dynamic>)
          ? AiTeamModelSlot.fromJson(aggRaw)
          : null,
      proposalSystemPrompt: (json['proposalSystemPrompt'] as String?) ??
          AiTeamConfigDefaults.defaultProposalPrompt,
      aggregatorSystemPrompt: (json['aggregatorSystemPrompt'] as String?) ??
          AiTeamConfigDefaults.defaultAggregatorPrompt,
      useDefaultProposalPrompt: (json['useDefaultProposalPrompt'] as bool?) ?? true,
      useDefaultAggregatorPrompt: (json['useDefaultAggregatorPrompt'] as bool?) ?? true,
      chainProposerSystemPrompt: (json['chainProposerSystemPrompt'] as String?) ??
          AiTeamConfigDefaults.defaultChainProposerPrompt,
      chainCriticSystemPrompt: (json['chainCriticSystemPrompt'] as String?) ??
          AiTeamConfigDefaults.defaultChainCriticPrompt,
      chainAggregatorSystemPrompt: (json['chainAggregatorSystemPrompt'] as String?) ??
          AiTeamConfigDefaults.defaultChainAggregatorPrompt,
      useDefaultChainProposerPrompt: (json['useDefaultChainProposerPrompt'] as bool?) ?? true,
      useDefaultChainCriticPrompt: (json['useDefaultChainCriticPrompt'] as bool?) ?? true,
      useDefaultChainAggregatorPrompt: (json['useDefaultChainAggregatorPrompt'] as bool?) ?? true,
    );
  }

  /// Active proposer slots (first `proposerCount`, non-null only) in Parallel mode.
  List<AiTeamModelSlot> get activeProposers => proposers
      .take(proposerCount)
      .whereType<AiTeamModelSlot>()
      .toList(growable: false);

  /// Active proposer + critic slots in Chain mode.
  /// Slot 0 is the Proposer.
  /// Slots 1 to criticCount are Critics.
  List<AiTeamModelSlot> get activeChainModels {
    final list = <AiTeamModelSlot>[];
    if (proposers.isNotEmpty && proposers[0] != null) {
      list.add(proposers[0]!);
    }
    for (var i = 1; i <= criticCount && i < proposers.length; i++) {
      if (proposers[i] != null) {
        list.add(proposers[i]!);
      }
    }
    return list;
  }

  /// Whether there is at least one configured proposer to run.
  bool get hasProposers => mode == AiTeamMode.parallel
      ? activeProposers.isNotEmpty
      : (proposers.isNotEmpty && proposers[0] != null);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AiTeamConfig &&
          enabled == other.enabled &&
          mode == other.mode &&
          proposerCount == other.proposerCount &&
          criticCount == other.criticCount &&
          _listEquals(proposers, other.proposers) &&
          aggregator == other.aggregator &&
          proposalSystemPrompt == other.proposalSystemPrompt &&
          aggregatorSystemPrompt == other.aggregatorSystemPrompt &&
          useDefaultProposalPrompt == other.useDefaultProposalPrompt &&
          useDefaultAggregatorPrompt == other.useDefaultAggregatorPrompt &&
          chainProposerSystemPrompt == other.chainProposerSystemPrompt &&
          chainCriticSystemPrompt == other.chainCriticSystemPrompt &&
          chainAggregatorSystemPrompt == other.chainAggregatorSystemPrompt &&
          useDefaultChainProposerPrompt == other.useDefaultChainProposerPrompt &&
          useDefaultChainCriticPrompt == other.useDefaultChainCriticPrompt &&
          useDefaultChainAggregatorPrompt == other.useDefaultChainAggregatorPrompt;

  @override
  int get hashCode =>
      enabled.hashCode ^
      mode.hashCode ^
      proposerCount.hashCode ^
      criticCount.hashCode ^
      aggregator.hashCode ^
      proposalSystemPrompt.hashCode ^
      aggregatorSystemPrompt.hashCode ^
      useDefaultProposalPrompt.hashCode ^
      useDefaultAggregatorPrompt.hashCode ^
      chainProposerSystemPrompt.hashCode ^
      chainCriticSystemPrompt.hashCode ^
      chainAggregatorSystemPrompt.hashCode ^
      useDefaultChainProposerPrompt.hashCode ^
      useDefaultChainCriticPrompt.hashCode ^
      useDefaultChainAggregatorPrompt.hashCode;

  static bool _listEquals(List<AiTeamModelSlot?> a, List<AiTeamModelSlot?> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

class AiTeamConfigDefaults {
  AiTeamConfigDefaults._();

  static const String defaultProposalPrompt =
      '直接回答問題。不要問候、不要結尾客套話、不要追問使用者、不要評價問題本身。只給出你的答案和推理。';

  static const String defaultAggregatorPrompt =
      '我到目前為止對這個問題整理了幾種不同的思考方向。請你幫我把這些思考整合成一個完整、連貫的最終回答。\n'
      '要求：\n'
      '- 不是總結或列舉這些思考，而是直接給出一個整合後的答案。\n'
      '- 保留其中最扎實的推理和最好的例子，去掉重複或薄弱的部份。\n'
      '- 如果有互相矛盾的地方，做出判斷，挑最站得住腳的說法，不要兩邊都留。\n'
      '- 最終回答必須比任何一段單獨的思考更完整、更精準。\n'
      '- 像你第一次回答這個問題那樣直接給出答案，不要提「之前的思考」或「整合過程」。';

  static const String defaultChainProposerPrompt =
      'You are an advanced Deep Reasoning & Research AI Agent. You value depth of insight, logical validity, and authoritative evidence.\n\n'
      'Throughout your reasoning process, you must maintain a strict distinction between:\n'
      '- Evidence: Direct observations, data, empirical findings, expert consensus, and other externally checkable claims.\n'
      '- Inference: Interpretations, causal explanations, generalizations, and conclusions drawn from evidence.\n'
      '- Judgment: Recommendations, priorities, trade-offs, and value-dependent choices.\n\n'
      'Never present an inference as an observed fact. Never present a preference or value judgment as if evidence alone determines it. Your purpose is not to validate the first plausible explanation, but to construct the most accurate, well-calibrated, and decision-useful understanding that the available evidence permits.\n\n'
      'Before answering, think deeply:\n'
      '- Identify the fundamental principles governing this problem. Restate the question sharply. Identify key assumptions, ambiguities, and potential confounders.\n\n'
      'Then give your most complete, rigorous answer.\n\n'
      'Question:';

  static const String defaultChainCriticPrompt =
      'Perform a rigorous self-audit of your preceding analysis. For key claims you are uncertain about or that need verification, proactively use search tools to verify.\n\n'
      '1. Challenge your current understanding by applying one or more of the most relevant of these 7 Analytical Lenses:\n'
      '   - Adversarial: Step outside your framing. Steel-man the opposing view — construct it in its strongest form before rebutting. Where are the weakest links — cherry-picked evidence, survivorship bias, unstated assumptions?\n'
      '   - Causal/Structural: Identify mechanisms, hidden dependencies, feedback loops, second-order effects, and edge cases.\n'
      '   - Comparative: Compare realistic alternatives, base rates, benchmarks, and opportunity costs.\n'
      '   - Temporal: Examine trends, time horizons, tipping points, path dependency, and conditions under which findings may no longer hold.\n'
      '   - Stakeholder: Analyze how incentives, risks, and constraints vary across affected groups.\n'
      '   - Analogical: Use cross-domain analogies to reveal structure, then explicitly test where the analogy breaks.\n'
      '   - Boundary-Condition: Identify populations, contexts, scales, thresholds, and definitions under which the conclusion changes.\n\n'
      '2. What genuinely shifted? Identify new insights from your reasoning and research — not restatements. Do not silently discard conflicting evidence — flag the tension and investigate it.\n\n'
      '3. Where is understanding still fragile? Pinpoint specific gaps, then convert each into a reasoning question for the next round and a search query where applicable.\n\n'
      '4. Belief Calibration:\n'
      '   - Current conclusion\n'
      '   - Main support (note source quality: authoritative / general / weak)\n'
      '   - Main objections\n'
      '   - Still uncertain\n'
      '   - Ruled-out hypotheses (and why)\n'
      '   - Under what specific conditions or new evidence would your conclusion change\n\n'
      'Output items 1–4 in full.';

  static const String defaultChainAggregatorPrompt =
      'Synthesize your reasoning and research into a final response. Integrate all preceding rounds of thinking (initial answer and each round of reflection). Follow these requirements:\n\n'
      '1. Re-anchor — Silently confirm your understanding of the original question (this step need not appear in the final output), ensuring the synthesis stays focused on the original question.\n\n'
      '2. Integrate and strengthen — Combine what remains sound from the initial answer with the corrections, additions, and withdrawals from the reflection rounds into a coherent, rigorous account. Withdrawn arguments no longer appear; new insights are integrated; corrected arguments appear in their revised form.\n\n'
      '3. Language — Respond in the same language the user used.\n\n'
      '4. Cite Material Claims — Every key factual claim must be backed by traceable sources. Use [numbered references] with a reference list at the end. Never fabricate or misrepresent sources.\n\n'
      '5. Structure — Adapt to the question\'s complexity.\n\n'
      '6. Epistemic Honesty (where applicable) — Clearly separate what is well-established, what is a well-supported inference, and what remains unresolved. State assumptions, evidence gaps, and source conflicts explicitly. Use explicit epistemic markers (e.g., "evidence suggests," "we infer," "uncertainty remains").\n\n'
      '7. Present the strongest counter-perspective (where applicable) — Articulate the best opposing argument fairly and explain why your position is more compelling — or why the question remains genuinely open.\n\n'
      '8. Be decision-useful — If the user is making a decision, provide actionable recommendations. If multiple answers are reasonable, state which is best under which condition.';
}
