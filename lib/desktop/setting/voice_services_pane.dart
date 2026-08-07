import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../icons/lucide_adapter.dart' as lucide;
import '../../l10n/app_localizations.dart';
import '../../core/providers/settings_provider.dart';
import 'tts_services_pane.dart';
import 'stt_services_pane.dart';

enum _VoiceSubPane { root, tts, stt }

/// Desktop: 「語音服務」中介面板（兩層導覽，與行動版 `VoiceServicesPage` 一致）。
/// 根層顯示「語音朗讀 / 語音辨識」兩個項目；點擊後**原地切換**為對應的
/// TTS / STT pane（中介層保留於兩平台，僅以 pane 內切換呈現）。
class DesktopVoiceServicesPane extends StatefulWidget {
  const DesktopVoiceServicesPane({super.key});
  @override
  State<DesktopVoiceServicesPane> createState() =>
      _DesktopVoiceServicesPaneState();
}

class _DesktopVoiceServicesPaneState extends State<DesktopVoiceServicesPane> {
  _VoiceSubPane _sub = _VoiceSubPane.root;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;

    switch (_sub) {
      case _VoiceSubPane.tts:
        return _SubPaneHost(
          title: l10n.settingsPageTts,
          onBack: () => setState(() => _sub = _VoiceSubPane.root),
          child: const DesktopTtsServicesPane(),
        );
      case _VoiceSubPane.stt:
        return _SubPaneHost(
          title: l10n.settingsPageStt,
          onBack: () => setState(() => _sub = _VoiceSubPane.root),
          child: const DesktopSttServicesPane(),
        );
      case _VoiceSubPane.root:
        return Container(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 960),
              child: CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: SizedBox(
                      height: 36,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          l10n.settingsPageVoiceServices,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w400,
                            color: cs.onSurface.withOpacity(0.9),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 16)),
                  SliverToBoxAdapter(
                    child: _VoiceServiceCard(
                      icon: lucide.Lucide.Volume2,
                      title: l10n.settingsPageTts,
                      subtitle: _ttsSubtitle(context),
                      onTap: () => setState(() => _sub = _VoiceSubPane.tts),
                    ),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 12)),
                  SliverToBoxAdapter(
                    child: _VoiceServiceCard(
                      icon: lucide.Lucide.Mic,
                      title: l10n.settingsPageStt,
                      subtitle: _sttSubtitle(context),
                      onTap: () => setState(() => _sub = _VoiceSubPane.stt),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
    }
  }

  String _ttsSubtitle(BuildContext context) {
    final sp = context.watch<SettingsProvider>();
    final l10n = AppLocalizations.of(context)!;
    if (sp.usingSystemTts) return l10n.ttsServicesPageSystemTtsTitle;
    final selected = sp.selectedTtsService;
    return selected?.name.isNotEmpty == true
        ? selected!.name
        : l10n.settingsPageTts;
  }

  String _sttSubtitle(BuildContext context) {
    final sp = context.watch<SettingsProvider>();
    final l10n = AppLocalizations.of(context)!;
    if (sp.usingSystemStt) return l10n.sttSystemProviderName;
    final selected = sp.selectedSttService;
    return selected?.name.isNotEmpty == true
        ? selected!.name
        : l10n.settingsPageStt;
  }
}

/// 子 pane 外殼：返回列 + 對應 pane（原地切換）。
class _SubPaneHost extends StatelessWidget {
  const _SubPaneHost({
    required this.title,
    required this.onBack,
    required this.child,
  });
  final String title;
  final VoidCallback onBack;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 40,
          child: Row(
            children: [
              Tooltip(
                message: l10n.sttServicesPageBackButton,
                child: IconButton(
                  icon: Icon(
                    lucide.Lucide.ArrowLeft,
                    size: 18,
                    color: cs.onSurface,
                  ),
                  onPressed: onBack,
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}

class _VoiceServiceCard extends StatefulWidget {
  const _VoiceServiceCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  @override
  State<_VoiceServiceCard> createState() => _VoiceServiceCardState();
}

class _VoiceServiceCardState extends State<_VoiceServiceCard> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final baseBg = isDark ? Colors.white10 : Colors.white.withOpacity(0.96);
    final borderColor = _hover
        ? cs.primary.withOpacity(isDark ? 0.35 : 0.45)
        : cs.outlineVariant.withOpacity(isDark ? 0.12 : 0.08);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          decoration: BoxDecoration(
            color: baseBg,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: borderColor, width: 1.0),
          ),
          padding: const EdgeInsets.all(14),
          constraints: const BoxConstraints(minHeight: 64),
          child: Row(
            children: [
              _CircleIconBadge(icon: widget.icon, size: 24),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurface.withOpacity(0.7),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                lucide.Lucide.ChevronRight,
                size: 18,
                color: cs.onSurface.withOpacity(0.6),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CircleIconBadge extends StatelessWidget {
  const _CircleIconBadge({required this.icon, this.size = 24});
  final IconData icon;
  final double size;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? Colors.white12 : Colors.black.withOpacity(0.06);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
      alignment: Alignment.center,
      child: Icon(
        icon,
        size: size * 0.62,
        color: cs.onSurface.withOpacity(0.9),
      ),
    );
  }
}
