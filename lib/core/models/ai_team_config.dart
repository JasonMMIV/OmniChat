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

class AiTeamConfig {
  final bool enabled;
  final int proposerCount; // 1~4
  final List<AiTeamModelSlot?> proposers; // length always 4, first `proposerCount` used
  final AiTeamModelSlot? aggregator; // null = use current model
  final String proposalSystemPrompt;
  final String aggregatorSystemPrompt;
  final bool useDefaultProposalPrompt; // true = use l10n localized default
  final bool useDefaultAggregatorPrompt; // true = use l10n localized default

  const AiTeamConfig({
    this.enabled = false,
    this.proposerCount = 2,
    this.proposers = const [null, null, null, null],
    this.aggregator,
    this.proposalSystemPrompt = AiTeamConfigDefaults.defaultProposalPrompt,
    this.aggregatorSystemPrompt = AiTeamConfigDefaults.defaultAggregatorPrompt,
    this.useDefaultProposalPrompt = true,
    this.useDefaultAggregatorPrompt = true,
  });

  AiTeamConfig copyWith({
    bool? enabled,
    int? proposerCount,
    List<AiTeamModelSlot?>? proposers,
    AiTeamModelSlot? aggregator,
    String? proposalSystemPrompt,
    String? aggregatorSystemPrompt,
    bool? useDefaultProposalPrompt,
    bool? useDefaultAggregatorPrompt,
  }) {
    return AiTeamConfig(
      enabled: enabled ?? this.enabled,
      proposerCount: proposerCount ?? this.proposerCount,
      proposers: proposers ?? this.proposers,
      aggregator: aggregator ?? this.aggregator,
      proposalSystemPrompt: proposalSystemPrompt ?? this.proposalSystemPrompt,
      aggregatorSystemPrompt: aggregatorSystemPrompt ?? this.aggregatorSystemPrompt,
      useDefaultProposalPrompt: useDefaultProposalPrompt ?? this.useDefaultProposalPrompt,
      useDefaultAggregatorPrompt: useDefaultAggregatorPrompt ?? this.useDefaultAggregatorPrompt,
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'proposerCount': proposerCount,
        'proposers': proposers
            .map((e) => e == null ? null : e.toJson())
            .toList(growable: false),
        'aggregator': aggregator == null ? null : aggregator!.toJson(),
        'proposalSystemPrompt': proposalSystemPrompt,
        'aggregatorSystemPrompt': aggregatorSystemPrompt,
        'useDefaultProposalPrompt': useDefaultProposalPrompt,
        'useDefaultAggregatorPrompt': useDefaultAggregatorPrompt,
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
      proposerCount: (json['proposerCount'] as int?) ?? 2,
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
    );
  }

  /// Active proposer slots (first `proposerCount`, non-null only).
  List<AiTeamModelSlot> get activeProposers => proposers
      .take(proposerCount)
      .whereType<AiTeamModelSlot>()
      .toList(growable: false);

  /// Whether there is at least one configured proposer to run.
  bool get hasProposers => activeProposers.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AiTeamConfig &&
          enabled == other.enabled &&
          proposerCount == other.proposerCount &&
          _listEquals(proposers, other.proposers) &&
          aggregator == other.aggregator &&
          proposalSystemPrompt == other.proposalSystemPrompt &&
          aggregatorSystemPrompt == other.aggregatorSystemPrompt &&
          useDefaultProposalPrompt == other.useDefaultProposalPrompt &&
          useDefaultAggregatorPrompt == other.useDefaultAggregatorPrompt;

  @override
  int get hashCode =>
      enabled.hashCode ^
      proposerCount.hashCode ^
      aggregator.hashCode ^
      proposalSystemPrompt.hashCode ^
      aggregatorSystemPrompt.hashCode ^
      useDefaultProposalPrompt.hashCode ^
      useDefaultAggregatorPrompt.hashCode;

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
}
