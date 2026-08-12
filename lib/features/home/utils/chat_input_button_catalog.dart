import 'package:flutter/material.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';

/// Catalog of reorderable/hideable chat input bar buttons.
///
/// Shared by the input bar renderer ([ChatInputBar]) and the settings UI so
/// that order/visibility preferences use stable ids across platforms.
class ChatInputButtonSpec {
  const ChatInputButtonSpec({
    required this.id,
    required this.icon,
    required this.label,
  });

  final String id;
  final IconData icon;
  final String Function(AppLocalizations l10n) label;
}

const List<ChatInputButtonSpec> chatInputButtonCatalog = [
  ChatInputButtonSpec(
    id: 'model',
    icon: Lucide.Boxes,
    label: _modelLabel,
  ),
  ChatInputButtonSpec(
    id: 'imageRatio',
    icon: Lucide.Ratio,
    label: _imageRatioLabel,
  ),
  ChatInputButtonSpec(
    id: 'search',
    icon: Lucide.Globe,
    label: _searchLabel,
  ),
  ChatInputButtonSpec(
    id: 'mcp',
    icon: Lucide.Hammer,
    label: _mcpLabel,
  ),
  ChatInputButtonSpec(
    id: 'quickPhrase',
    icon: Lucide.Zap,
    label: _quickPhraseLabel,
  ),
  ChatInputButtonSpec(
    id: 'dictation',
    icon: Lucide.Mic,
    label: _dictationLabel,
  ),
  ChatInputButtonSpec(
    id: 'camera',
    icon: Lucide.Camera,
    label: _cameraLabel,
  ),
  ChatInputButtonSpec(
    id: 'photos',
    icon: Lucide.Image,
    label: _photosLabel,
  ),
  ChatInputButtonSpec(
    id: 'upload',
    icon: Lucide.Paperclip,
    label: _uploadLabel,
  ),
  ChatInputButtonSpec(
    id: 'reasoning',
    icon: Lucide.Brain,
    label: _reasoningLabel,
  ),
  ChatInputButtonSpec(
    id: 'aiTeam',
    icon: Lucide.Users,
    label: _aiTeamLabel,
  ),
  ChatInputButtonSpec(
    id: 'instruction',
    icon: Lucide.Layers,
    label: _instructionLabel,
  ),
  ChatInputButtonSpec(
    id: 'voice',
    icon: Lucide.AudioWaveform,
    label: _voiceLabel,
  ),
  ChatInputButtonSpec(
    id: 'context',
    icon: Lucide.workflow,
    label: _contextLabel,
  ),
  ChatInputButtonSpec(
    id: 'ocr',
    icon: Lucide.Eye,
    label: _ocrLabel,
  ),
];

/// Default order matches the original fixed layout of the input bar.
const List<String> chatInputButtonDefaultOrder = [
  'model',
  'imageRatio',
  'search',
  'mcp',
  'quickPhrase',
  'dictation',
  'camera',
  'photos',
  'upload',
  'reasoning',
  'aiTeam',
  'instruction',
  'voice',
  'context',
  'ocr',
];

ChatInputButtonSpec? chatInputButtonSpecById(String id) {
  for (final spec in chatInputButtonCatalog) {
    if (spec.id == id) return spec;
  }
  return null;
}

/// Returns the given button ids reordered per [order] (unknown ids appended
/// in catalog order), which is the effective order used by the input bar.
List<String> chatInputButtonEffectiveOrder(List<String> order) {
  final known = chatInputButtonCatalog.map((s) => s.id).toList();
  final result = <String>[];
  final seen = <String>{};
  for (final id in order) {
    if (seen.add(id) && known.contains(id)) result.add(id);
  }
  for (final id in known) {
    if (seen.add(id)) result.add(id);
  }
  return result;
}

String _modelLabel(AppLocalizations l10n) => l10n.chatInputBarSelectModelTooltip;
String _searchLabel(AppLocalizations l10n) => l10n.chatInputBarOnlineSearchTooltip;
String _mcpLabel(AppLocalizations l10n) => l10n.chatInputBarMcpServersTooltip;
String _quickPhraseLabel(AppLocalizations l10n) =>
    l10n.chatInputBarQuickPhraseTooltip;
String _dictationLabel(AppLocalizations l10n) =>
    l10n.chatInputBarDictationTooltip;
String _cameraLabel(AppLocalizations l10n) => l10n.bottomToolsSheetCamera;
String _photosLabel(AppLocalizations l10n) => l10n.bottomToolsSheetPhotos;
String _uploadLabel(AppLocalizations l10n) => l10n.bottomToolsSheetUpload;
String _reasoningLabel(AppLocalizations l10n) =>
    l10n.chatInputBarReasoningStrengthTooltip;
String _aiTeamLabel(AppLocalizations l10n) => l10n.chatInputBarAiTeamTooltip;
String _instructionLabel(AppLocalizations l10n) =>
    l10n.instructionInjectionTitle;
String _voiceLabel(AppLocalizations l10n) => l10n.voiceChatButtonTooltip;
String _contextLabel(AppLocalizations l10n) => l10n.contextManagement;
String _ocrLabel(AppLocalizations l10n) => l10n.chatInputBarOcrTooltip;
String _imageRatioLabel(AppLocalizations l10n) =>
    l10n.chatInputBarImageRatioTooltip;
