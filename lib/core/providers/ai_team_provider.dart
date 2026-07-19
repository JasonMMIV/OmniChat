import 'package:flutter/foundation.dart';

import '../models/ai_team_config.dart';
import '../services/ai_team_store.dart';

class AiTeamProvider with ChangeNotifier {
  AiTeamConfig _config = const AiTeamConfig();
  bool _initialized = false;

  AiTeamConfig get config => _config;
  bool get enabled => _config.enabled;
  AiTeamMode get mode => _config.mode;
  int get proposerCount => _config.proposerCount;
  int get criticCount => _config.criticCount;
  List<AiTeamModelSlot?> get proposers => _config.proposers;
  List<AiTeamModelSlot> get activeProposers => _config.activeProposers;
  List<AiTeamModelSlot> get activeChainModels => _config.activeChainModels;
  bool get hasProposers => _config.hasProposers;
  AiTeamModelSlot? get aggregator => _config.aggregator;
  String get proposalPrompt => _config.proposalSystemPrompt;
  String get aggregatorPrompt => _config.aggregatorSystemPrompt;
  String get chainProposerPrompt => _config.chainProposerSystemPrompt;
  String get chainCriticPrompt => _config.chainCriticSystemPrompt;
  String get chainAggregatorPrompt => _config.chainAggregatorSystemPrompt;

  Future<void> initialize() async {
    if (_initialized) return;
    await loadAll();
    _initialized = true;
  }

  Future<void> loadAll() async {
    try {
      _config = await AiTeamStore.getConfig();
      notifyListeners();
    } catch (e) {
      debugPrint('Failed to load AI team config: $e');
      _config = const AiTeamConfig();
      notifyListeners();
    }
  }

  Future<void> update(AiTeamConfig Function(AiTeamConfig config) updater) async {
    _config = updater(_config);
    notifyListeners();
    await AiTeamStore.saveConfig(_config);
  }

  Future<void> toggleEnabled() async {
    await update((c) => c.copyWith(enabled: !c.enabled));
  }

  Future<void> setEnabled(bool enabled) async {
    await update((c) => c.copyWith(enabled: enabled));
  }

  Future<void> setProposerCount(int n) async {
    final clamped = n.clamp(1, 4);
    await update((c) => c.copyWith(proposerCount: clamped));
  }

  Future<void> setProposerAt(int index, AiTeamModelSlot? slot) async {
    if (index < 0 || index >= 4) return;
    await update((c) {
      final list = List<AiTeamModelSlot?>.from(c.proposers);
      list[index] = slot;
      return c.copyWith(proposers: list);
    });
  }

  Future<void> setAggregator(AiTeamModelSlot? slot) async {
    await update((c) => c.copyWith(aggregator: slot));
  }

  Future<void> setMode(AiTeamMode mode) async {
    await update((c) => c.copyWith(mode: mode));
  }

  Future<void> setCriticCount(int n) async {
    final clamped = n.clamp(0, 3);
    await update((c) => c.copyWith(criticCount: clamped));
  }

  bool get useDefaultProposalPrompt => _config.useDefaultProposalPrompt;
  bool get useDefaultAggregatorPrompt => _config.useDefaultAggregatorPrompt;
  bool get useDefaultChainProposerPrompt => _config.useDefaultChainProposerPrompt;
  bool get useDefaultChainCriticPrompt => _config.useDefaultChainCriticPrompt;
  bool get useDefaultChainAggregatorPrompt => _config.useDefaultChainAggregatorPrompt;

  Future<void> setProposalPrompt(String s) async {
    await update((c) => c.copyWith(
          proposalSystemPrompt: s.trim().isEmpty
              ? AiTeamConfigDefaults.defaultProposalPrompt
              : s.trim(),
          useDefaultProposalPrompt: false,
        ));
  }

  Future<void> setAggregatorPrompt(String s) async {
    await update((c) => c.copyWith(
          aggregatorSystemPrompt: s.trim().isEmpty
              ? AiTeamConfigDefaults.defaultAggregatorPrompt
              : s.trim(),
          useDefaultAggregatorPrompt: false,
        ));
  }

  Future<void> setChainProposerPrompt(String s) async {
    await update((c) => c.copyWith(
          chainProposerSystemPrompt: s.trim().isEmpty
              ? AiTeamConfigDefaults.defaultChainProposerPrompt
              : s.trim(),
          useDefaultChainProposerPrompt: false,
        ));
  }

  Future<void> setChainCriticPrompt(String s) async {
    await update((c) => c.copyWith(
          chainCriticSystemPrompt: s.trim().isEmpty
              ? AiTeamConfigDefaults.defaultChainCriticPrompt
              : s.trim(),
          useDefaultChainCriticPrompt: false,
        ));
  }

  Future<void> setChainAggregatorPrompt(String s) async {
    await update((c) => c.copyWith(
          chainAggregatorSystemPrompt: s.trim().isEmpty
              ? AiTeamConfigDefaults.defaultChainAggregatorPrompt
              : s.trim(),
          useDefaultChainAggregatorPrompt: false,
        ));
  }

  Future<void> resetPrompts() async {
    await update((c) => c.copyWith(
          proposalSystemPrompt: AiTeamConfigDefaults.defaultProposalPrompt,
          aggregatorSystemPrompt: AiTeamConfigDefaults.defaultAggregatorPrompt,
          useDefaultProposalPrompt: true,
          useDefaultAggregatorPrompt: true,
          chainProposerSystemPrompt: AiTeamConfigDefaults.defaultChainProposerPrompt,
          chainCriticSystemPrompt: AiTeamConfigDefaults.defaultChainCriticPrompt,
          chainAggregatorSystemPrompt: AiTeamConfigDefaults.defaultChainAggregatorPrompt,
          useDefaultChainProposerPrompt: true,
          useDefaultChainCriticPrompt: true,
          useDefaultChainAggregatorPrompt: true,
        ));
  }
}
