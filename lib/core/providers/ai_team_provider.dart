import 'package:flutter/foundation.dart';

import '../models/ai_team_config.dart';
import '../services/ai_team_store.dart';

class AiTeamProvider with ChangeNotifier {
  AiTeamConfig _config = const AiTeamConfig();
  bool _initialized = false;

  AiTeamConfig get config => _config;
  bool get enabled => _config.enabled;
  int get proposerCount => _config.proposerCount;
  List<AiTeamModelSlot?> get proposers => _config.proposers;
  List<AiTeamModelSlot> get activeProposers => _config.activeProposers;
  bool get hasProposers => _config.hasProposers;
  AiTeamModelSlot? get aggregator => _config.aggregator;
  String get proposalPrompt => _config.proposalSystemPrompt;
  String get aggregatorPrompt => _config.aggregatorSystemPrompt;

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

  bool get useDefaultProposalPrompt => _config.useDefaultProposalPrompt;
  bool get useDefaultAggregatorPrompt => _config.useDefaultAggregatorPrompt;

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

  Future<void> resetPrompts() async {
    await update((c) => c.copyWith(
          proposalSystemPrompt: AiTeamConfigDefaults.defaultProposalPrompt,
          aggregatorSystemPrompt: AiTeamConfigDefaults.defaultAggregatorPrompt,
          useDefaultProposalPrompt: true,
          useDefaultAggregatorPrompt: true,
        ));
  }
}
