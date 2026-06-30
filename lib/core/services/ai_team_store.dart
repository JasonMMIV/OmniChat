import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/ai_team_config.dart';

class AiTeamStore {
  AiTeamStore._();

  static const String _configKey = 'ai_team_config_v1';

  static AiTeamConfig? _cache;

  static Future<AiTeamConfig> getConfig() async {
    if (_cache != null) return _cache!;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_configKey);
    if (raw == null || raw.trim().isEmpty) {
      _cache = const AiTeamConfig();
      return _cache!;
    }
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      _cache = AiTeamConfig.fromJson(json);
    } catch (_) {
      _cache = const AiTeamConfig();
    }
    return _cache!;
  }

  static Future<void> saveConfig(AiTeamConfig config) async {
    _cache = config;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_configKey, jsonEncode(config.toJson()));
  }

  static Future<void> update(AiTeamConfig Function(AiTeamConfig) updater) async {
    final current = await getConfig();
    final next = updater(current);
    await saveConfig(next);
  }

  static Future<void> setEnabled(bool enabled) async {
    await update((c) => c.copyWith(enabled: enabled));
  }

  static Future<void> setProposerCount(int count) async {
    final clamped = count.clamp(1, 4);
    await update((c) => c.copyWith(proposerCount: clamped));
  }

  static Future<void> setProposerAt(int index, AiTeamModelSlot? slot) async {
    if (index < 0 || index >= 4) return;
    await update((c) {
      final list = List<AiTeamModelSlot?>.from(c.proposers);
      list[index] = slot;
      return c.copyWith(proposers: list);
    });
  }

  static Future<void> setProposers(List<AiTeamModelSlot?> proposers) async {
    final padded = List<AiTeamModelSlot?>.filled(4, null);
    for (var i = 0; i < 4 && i < proposers.length; i++) {
      padded[i] = proposers[i];
    }
    await update((c) => c.copyWith(proposers: padded));
  }

  static Future<void> setAggregator(AiTeamModelSlot? slot) async {
    await update((c) => c.copyWith(aggregator: slot));
  }

  static Future<void> setProposalPrompt(String prompt) async {
    final p = prompt.trim().isEmpty ? AiTeamConfigDefaults.defaultProposalPrompt : prompt.trim();
    await update((c) => c.copyWith(
          proposalSystemPrompt: p,
          useDefaultProposalPrompt: false,
        ));
  }

  static Future<void> setAggregatorPrompt(String prompt) async {
    final p = prompt.trim().isEmpty ? AiTeamConfigDefaults.defaultAggregatorPrompt : prompt.trim();
    await update((c) => c.copyWith(
          aggregatorSystemPrompt: p,
          useDefaultAggregatorPrompt: false,
        ));
  }

  static Future<void> resetPrompts() async {
    await update((c) => c.copyWith(
          proposalSystemPrompt: AiTeamConfigDefaults.defaultProposalPrompt,
          aggregatorSystemPrompt: AiTeamConfigDefaults.defaultAggregatorPrompt,
          useDefaultProposalPrompt: true,
          useDefaultAggregatorPrompt: true,
        ));
  }
}
