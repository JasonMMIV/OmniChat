import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/tts/tts_text_selection.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';

class TtsSettingsPage extends StatelessWidget {
  const TtsSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Lucide.ArrowLeft, size: 22),
          color: cs.onSurface,
          tooltip: l10n.ttsServicesPageBackButton,
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(l10n.ttsSettingsPageTitle),
      ),
      body: const TtsSettingsContent(),
    );
  }
}

class TtsSettingsContent extends StatelessWidget {
  const TtsSettingsContent({super.key, this.padding});

  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final settings = context.watch<SettingsProvider>();
    final cs = Theme.of(context).colorScheme;

    return ListView(
      padding: padding ?? const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        _SettingsSection(
          title: l10n.ttsSettingsPlaybackSection,
          children: [
            SwitchListTile(
              value: settings.ttsAutoPlayAssistantReplies,
              onChanged: (val) {
                context
                    .read<SettingsProvider>()
                    .setTtsAutoPlayAssistantReplies(val);
              },
              title: Text(
                l10n.ttsSettingsAutoPlayTitle,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface,
                ),
              ),
              subtitle: Text(
                l10n.ttsSettingsAutoPlayDescription,
                style: TextStyle(
                  fontSize: 12,
                  color: cs.onSurface.withOpacity(0.6),
                ),
              ),
              activeColor: cs.primary,
            ),
          ],
        ),
        const SizedBox(height: 16),
        _SettingsSection(
          title: l10n.ttsSettingsTextSelectionSection,
          children: [
            RadioListTile<TtsTextSelectionMode>(
              value: TtsTextSelectionMode.fullText,
              groupValue: settings.ttsTextSelectionMode,
              onChanged: (mode) {
                if (mode != null) {
                  context
                      .read<SettingsProvider>()
                      .setTtsTextSelectionMode(mode);
                }
              },
              title: Text(
                l10n.ttsSettingsTextSelectionFullText,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: cs.onSurface,
                ),
              ),
              activeColor: cs.primary,
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
            RadioListTile<TtsTextSelectionMode>(
              value: TtsTextSelectionMode.outsideParentheses,
              groupValue: settings.ttsTextSelectionMode,
              onChanged: (mode) {
                if (mode != null) {
                  context
                      .read<SettingsProvider>()
                      .setTtsTextSelectionMode(mode);
                }
              },
              title: Text(
                l10n.ttsSettingsTextSelectionOutsideParentheses,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: cs.onSurface,
                ),
              ),
              activeColor: cs.primary,
            ),
          ],
        ),
      ],
    );
  }
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 8, bottom: 8),
          child: Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: cs.primary,
            ),
          ),
        ),
        Card(
          elevation: 0,
          color: cs.surfaceContainerHighest.withOpacity(0.4),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(children: children),
        ),
      ],
    );
  }
}
