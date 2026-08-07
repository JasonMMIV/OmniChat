import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:speech_to_text/speech_to_text.dart'
    show LocaleName, SpeechToText;

import '../../../core/providers/settings_provider.dart';
import '../../../core/services/stt/network_stt.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../core/services/haptics.dart';

/// 行動版「語音辨識」服務管理頁面（仿照 `tts_services_page.dart` 結構）。
///
/// 範圍註記：本次僅建構第三方 STT 服務的「設定管理架構」；網路轉錄
/// （錄音 → 上傳 → 轉錄 → 注入）為下階段範圍，故第三方卡片標示
/// 「尚未支援轉錄」。系統STT 提供語言覆寫設定，影響 Voice Chat 與 Dictation。
class SttServicesPage extends StatelessWidget {
  const SttServicesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        leading: Tooltip(
          message: l10n.sttServicesPageBackButton,
          child: _TactileIconButton(
            icon: Lucide.ArrowLeft,
            color: cs.onSurface,
            size: 22,
            onTap: () => Navigator.of(context).maybePop(),
          ),
        ),
        title: Text(l10n.sttServicesPageTitle),
        actions: [
          Tooltip(
            message: l10n.sttServicesPageAddTooltip,
            child: _TactileIconButton(
              icon: Lucide.Plus,
              color: cs.onSurface,
              size: 22,
              onTap: () async {
                final created = await _showAddNetworkSttSheet(context);
                if (!context.mounted) return;
                if (created != null) {
                  final sp = context.read<SettingsProvider>();
                  final list = List<SttServiceOptions>.from(sp.sttServices)
                    ..add(created);
                  await sp.setSttServices(list);
                  if (sp.usingSystemStt) {
                    await sp.setSttServiceSelected(list.length - 1);
                  }
                }
              },
            ),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: Consumer<SettingsProvider>(
        builder: (context, sp, _) {
          final services = sp.sttServices;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              _header(context, l10n.sttServicesPageTitle, first: true),
              _iosSectionCard(
                children: [
                  // System STT as first row
                  _SystemSttRowMobile(),
                  if (services.isNotEmpty) _iosDivider(context),
                  if (services.isNotEmpty) ...[
                    for (int i = 0; i < services.length; i++) ...[
                      _NetworkSttRowMobile(service: services[i], index: i),
                      if (i != services.length - 1) _iosDivider(context),
                    ],
                  ],
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

// --- iOS-style widgets and helpers ---

Widget _header(BuildContext context, String text, {bool first = false}) {
  final cs = Theme.of(context).colorScheme;
  return Padding(
    padding: EdgeInsets.fromLTRB(12, first ? 6 : 18, 12, 6),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: cs.onSurface.withOpacity(0.8),
      ),
    ),
  );
}

class _TactileIconButton extends StatefulWidget {
  const _TactileIconButton({
    required this.icon,
    required this.color,
    required this.onTap,
    this.semanticLabel,
    this.size = 22,
    this.haptics = true,
  });
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final String? semanticLabel;
  final double size;
  final bool haptics;
  @override
  State<_TactileIconButton> createState() => _TactileIconButtonState();
}

class _TactileIconButtonState extends State<_TactileIconButton> {
  bool _pressed = false;
  @override
  Widget build(BuildContext context) {
    final base = widget.color;
    final icon = Icon(
      widget.icon,
      size: widget.size,
      color: _pressed ? base.withOpacity(0.7) : base,
      semanticLabel: widget.semanticLabel,
    );
    return Semantics(
      button: true,
      label: widget.semanticLabel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: () {
          if (widget.haptics) Haptics.light();
          widget.onTap();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          child: icon,
        ),
      ),
    );
  }
}

class _TactileRow extends StatefulWidget {
  const _TactileRow({
    required this.builder,
    this.onTap,
    this.pressedScale = 1.00,
    this.haptics = true,
  });
  final Widget Function(bool pressed) builder;
  final VoidCallback? onTap;
  final double pressedScale;
  final bool haptics;
  @override
  State<_TactileRow> createState() => _TactileRowState();
}

class _TactileRowState extends State<_TactileRow> {
  bool _pressed = false;
  void _set(bool v) {
    if (_pressed != v) setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: widget.onTap == null ? null : (_) => _set(true),
      onTapUp: widget.onTap == null ? null : (_) => _set(false),
      onTapCancel: widget.onTap == null ? null : () => _set(false),
      onTap: widget.onTap == null
          ? null
          : () {
              if (widget.haptics &&
                  context.read<SettingsProvider>().hapticsOnListItemTap) {
                Haptics.soft();
              }
              widget.onTap!.call();
            },
      child: AnimatedScale(
        scale: _pressed ? widget.pressedScale : 1.0,
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOutCubic,
        child: widget.builder(_pressed),
      ),
    );
  }
}

class _AnimatedPressColor extends StatelessWidget {
  const _AnimatedPressColor({
    required this.pressed,
    required this.base,
    required this.builder,
  });
  final bool pressed;
  final Color base;
  final Widget Function(Color c) builder;
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final target = pressed
        ? (Color.lerp(base, isDark ? Colors.black : Colors.white, 0.55) ?? base)
        : base;
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: target),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      builder: (context, color, _) => builder(color ?? base),
    );
  }
}

Widget _iosSectionCard({required List<Widget> children}) {
  return Builder(
    builder: (context) {
      final theme = Theme.of(context);
      final cs = theme.colorScheme;
      final isDark = theme.brightness == Brightness.dark;
      final Color bg = isDark ? Colors.white10 : Colors.white.withOpacity(0.96);
      return Container(
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: cs.outlineVariant.withOpacity(isDark ? 0.08 : 0.06),
            width: 0.6,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(children: children),
        ),
      );
    },
  );
}

Widget _iosDivider(BuildContext context) {
  final cs = Theme.of(context).colorScheme;
  return Divider(
    height: 6,
    thickness: 0.6,
    indent: 54,
    endIndent: 12,
    color: cs.outlineVariant.withOpacity(0.18),
  );
}

class _SmallTactileIcon extends StatefulWidget {
  const _SmallTactileIcon({
    required this.icon,
    required this.onTap,
    this.enabled = true,
    this.baseColor,
  });
  final IconData icon;
  final VoidCallback onTap;
  final bool enabled;
  final Color? baseColor;
  @override
  State<_SmallTactileIcon> createState() => _SmallTactileIconState();
}

class _SmallTactileIconState extends State<_SmallTactileIcon> {
  bool _pressed = false;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final base = widget.baseColor ?? cs.onSurface;
    final c = widget.enabled
        ? base.withOpacity(_pressed ? 0.6 : 0.9)
        : base.withOpacity(0.3);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: widget.enabled ? (_) => setState(() => _pressed = true) : null,
      onTapUp: widget.enabled ? (_) => setState(() => _pressed = false) : null,
      onTapCancel: widget.enabled
          ? () => setState(() => _pressed = false)
          : null,
      onTap: widget.enabled
          ? () {
              Haptics.soft();
              widget.onTap();
            }
          : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Icon(widget.icon, size: 18, color: c),
      ),
    );
  }
}

class _AvatarBadge extends StatelessWidget {
  const _AvatarBadge({required this.letter, required this.overlay});
  final String letter;
  final Color overlay;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final baseBg = isDark ? Colors.white10 : cs.primary.withOpacity(0.1);
    return Stack(
      alignment: Alignment.center,
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(color: baseBg, shape: BoxShape.circle),
          alignment: Alignment.center,
          child: Text(
            letter,
            style: TextStyle(
              color: cs.primary,
              fontWeight: FontWeight.w700,
              fontSize: 14,
            ),
          ),
        ),
        if (overlay != Colors.transparent)
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: overlay, shape: BoxShape.circle),
          ),
      ],
    );
  }
}

// --- System STT row ---

class _SystemSttRowMobile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    return Builder(
      builder: (context) {
        final sp = context.watch<SettingsProvider>();
        final currentLocale = sp.sttSystemLocaleId;
        final subText = (currentLocale == null || currentLocale.isEmpty)
            ? l10n.sttLanguageAuto
            : currentLocale;
        return _TactileRow(
          pressedScale: 0.98,
          haptics: false,
          onTap: () async {
            try {
              await sp.setSttServiceSelected(-1);
            } catch (_) {}
          },
          builder: (pressed) {
            final base = cs.onSurface.withOpacity(0.9);
            return _AnimatedPressColor(
              pressed: pressed,
              base: base,
              builder: (c) {
                final isDark = Theme.of(context).brightness == Brightness.dark;
                final overlay = pressed
                    ? (isDark
                          ? Colors.black.withOpacity(0.06)
                          : Colors.white.withOpacity(0.05))
                    : Colors.transparent;
                final titleText = l10n.sttServicesPageSystemSttTitle;
                final letter =
                    (titleText.trim().isEmpty
                            ? '?'
                            : titleText.trim().substring(0, 1))
                        .toUpperCase();
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 11,
                  ),
                  child: Row(
                    children: [
                      _AvatarBadge(letter: letter, overlay: overlay),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              titleText,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 15,
                                color: c,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              subText,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: c.withOpacity(0.7),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Tooltip(
                        message: l10n.sttServicesPageSystemSttConfigureTooltip,
                        child: _SmallTactileIcon(
                          icon: Lucide.Settings2,
                          baseColor: c,
                          onTap: () => _showSystemSttLanguageSheet(context),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Builder(
                        builder: (_) {
                          final sel = context
                              .watch<SettingsProvider>()
                              .usingSystemStt;
                          return sel
                              ? Icon(Lucide.Check, size: 16, color: c)
                              : const SizedBox(width: 16);
                        },
                      ),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}

// --- Network STT rows ---

class _NetworkSttRowMobile extends StatefulWidget {
  const _NetworkSttRowMobile({required this.service, required this.index});
  final SttServiceOptions service;
  final int index;
  @override
  State<_NetworkSttRowMobile> createState() => _NetworkSttRowMobileState();
}

class _NetworkSttRowMobileState extends State<_NetworkSttRowMobile> {
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final displayName = widget.service.name.trim().isEmpty
        ? networkSttKindDisplayName(widget.service.kind)
        : widget.service.name.trim();
    return _TactileRow(
      pressedScale: 0.98,
      haptics: false,
      onTap: () async =>
          context.read<SettingsProvider>().setSttServiceSelected(widget.index),
      builder: (pressed) {
        final base = cs.onSurface.withOpacity(0.9);
        return _AnimatedPressColor(
          pressed: pressed,
          base: base,
          builder: (c) {
            final isDark = Theme.of(context).brightness == Brightness.dark;
            final overlay = pressed
                ? (isDark
                      ? Colors.black.withOpacity(0.06)
                      : Colors.white.withOpacity(0.05))
                : Colors.transparent;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              child: Row(
                children: [
                  _AvatarBadge(
                    letter: (displayName.isEmpty ? '?' : displayName[0])
                        .toUpperCase(),
                    overlay: overlay,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            color: c,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 3),
                        // 尚未支援轉錄標示（下階段才實作網路轉錄）
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: cs.tertiary.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: cs.tertiary.withOpacity(0.3),
                              width: 0.6,
                            ),
                          ),
                          child: Text(
                            l10n.sttServicesPageNotImplementedBadge,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 10.5,
                              color: cs.tertiary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  _SmallTactileIcon(
                    icon: Lucide.Settings2,
                    baseColor: c,
                    onTap: () async {
                      final updated = await _showEditNetworkSttSheet(
                        context,
                        widget.service,
                      );
                      if (updated != null) {
                        final list = List<SttServiceOptions>.from(
                          context.read<SettingsProvider>().sttServices,
                        );
                        list[widget.index] = updated;
                        await context.read<SettingsProvider>().setSttServices(
                          list,
                        );
                      }
                    },
                  ),
                  const SizedBox(width: 6),
                  _SmallTactileIcon(
                    icon: Lucide.Trash2,
                    baseColor: c,
                    onTap: () async {
                      final sp = context.read<SettingsProvider>();
                      final list = List<SttServiceOptions>.from(sp.sttServices);
                      list.removeAt(widget.index);
                      await sp.setSttServices(list);
                      var idx = sp.sttServiceSelected;
                      if (idx >= list.length) {
                        idx = list.isEmpty ? -1 : list.length - 1;
                      }
                      await sp.setSttServiceSelected(idx);
                    },
                  ),
                  const SizedBox(width: 8),
                  Builder(
                    builder: (_) {
                      final sp2 = context.watch<SettingsProvider>();
                      final sel = (sp2.sttServiceSelected == widget.index);
                      return sel
                          ? Icon(Lucide.Check, size: 16, color: c)
                          : const SizedBox(width: 16);
                    },
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

// --- Add / Edit network STT sheet ---

Future<SttServiceOptions?> _showAddNetworkSttSheet(BuildContext context) =>
    _showNetworkSttSheet(context, null);

Future<SttServiceOptions?> _showEditNetworkSttSheet(
  BuildContext context,
  SttServiceOptions initial,
) => _showNetworkSttSheet(context, initial);

Future<SttServiceOptions?> _showNetworkSttSheet(
  BuildContext context,
  SttServiceOptions? initial,
) async {
  final cs = Theme.of(context).colorScheme;
  final l10n = AppLocalizations.of(context)!;
  NetworkSttKind kind = initial?.kind ?? NetworkSttKind.openaiWhisper;
  final nameCtl = TextEditingController(text: initial?.name ?? '');
  final apiKeyCtl = TextEditingController(
    text: (initial is OpenAiWhisperSttOptions)
        ? initial.apiKey
        : (initial is GroqWhisperSttOptions)
        ? initial.apiKey
        : '',
  );
  final baseCtl = TextEditingController(
    text: (initial is OpenAiWhisperSttOptions)
        ? initial.baseUrl
        : (initial is GroqWhisperSttOptions)
        ? initial.baseUrl
        : '',
  );
  final modelCtl = TextEditingController(
    text: (initial is OpenAiWhisperSttOptions)
        ? initial.model
        : (initial is GroqWhisperSttOptions)
        ? initial.model
        : '',
  );

  SttServiceOptions? result;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: cs.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) {
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 6),
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: cs.onSurface.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
              child: Row(
                children: [
                  _TactileIconButton(
                    icon: Lucide.X,
                    color: cs.onSurface,
                    size: 20,
                    onTap: () => Navigator.of(ctx).maybePop(),
                  ),
                  Expanded(
                    child: Center(
                      child: Text(
                        initial == null
                            ? l10n.sttServicesDialogAddTitle
                            : l10n.sttServicesDialogEditTitle,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  _TactileIconButton(
                    icon: Lucide.Check,
                    color: cs.onSurface,
                    size: 20,
                    onTap: () {
                      final name = (nameCtl.text.trim().isEmpty)
                          ? networkSttKindDisplayName(kind)
                          : nameCtl.text.trim();
                      final apiKey = apiKeyCtl.text.trim();
                      final base = baseCtl.text.trim().isEmpty
                          ? _defaultBaseUrl(kind)
                          : baseCtl.text.trim();
                      final model = modelCtl.text.trim().isEmpty
                          ? _defaultModel(kind)
                          : modelCtl.text.trim();
                      if (apiKey.isEmpty) {
                        Navigator.of(ctx).maybePop();
                        return;
                      }
                      if (kind == NetworkSttKind.openaiWhisper) {
                        result = OpenAiWhisperSttOptions(
                          enabled: true,
                          name: name,
                          apiKey: apiKey,
                          baseUrl: base,
                          model: model,
                        );
                      } else if (kind == NetworkSttKind.groqWhisper) {
                        result = GroqWhisperSttOptions(
                          enabled: true,
                          name: name,
                          apiKey: apiKey,
                          baseUrl: base,
                          model: model,
                        );
                      }
                      Navigator.of(ctx).pop();
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Padding(
              padding: EdgeInsets.only(
                left: 12,
                right: 12,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 12,
              ),
              child: StatefulBuilder(
                builder: (ctx2, setState) {
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _sheetSelectRow(
                        ctx2,
                        label: l10n.sttServicesDialogProviderType,
                        value: networkSttKindDisplayName(kind),
                        options: NetworkSttKind.values
                            .map(networkSttKindDisplayName)
                            .toList(),
                        onSelected: (picked) async {
                          for (final k in NetworkSttKind.values) {
                            if (picked == networkSttKindDisplayName(k)) {
                              kind = k;
                              break;
                            }
                          }
                          (ctx as Element).markNeedsBuild();
                        },
                      ),
                      const SizedBox(height: 6),
                      _inputRowMobile(
                        context,
                        label: l10n.sttServicesFieldNameLabel,
                        controller: nameCtl,
                        hint: networkSttKindDisplayName(kind),
                      ),
                      const SizedBox(height: 6),
                      _inputRowMobile(
                        context,
                        label: l10n.sttServicesFieldApiKeyLabel,
                        controller: apiKeyCtl,
                        obscure: true,
                      ),
                      const SizedBox(height: 6),
                      _inputRowMobile(
                        context,
                        label: l10n.sttServicesFieldBaseUrlLabel,
                        controller: baseCtl,
                        hint: _defaultBaseUrl(kind),
                      ),
                      const SizedBox(height: 6),
                      _inputRowMobile(
                        context,
                        label: l10n.sttServicesFieldModelLabel,
                        controller: modelCtl,
                        hint: _defaultModel(kind),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      );
    },
  );
  return result;
}

// --- 系統STT 語言選擇 ---

// 用於 `locales()` 的專屬實例（只查詢語言列表，不佔用語音對話/聽寫實例）；
// 延遲建立，避免 module load 即構造 SpeechToText 實例。
SpeechToText? _sttLocalesSpeechToText;
SpeechToText get _localesSpeechToText =>
    // ignore: invalid_use_of_visible_for_testing_member
    _sttLocalesSpeechToText ??= SpeechToText.withMethodChannel();

Future<void> _showSystemSttLanguageSheet(BuildContext context) async {
  final cs = Theme.of(context).colorScheme;
  final l10n = AppLocalizations.of(context)!;
  final sp = context.read<SettingsProvider>();

  // 一次取得系統支援語言列表（Windows WinRT 限制可能回空列表）
  List<LocaleName> locales = const <LocaleName>[];
  try {
    locales = await _localesSpeechToText.locales();
  } catch (_) {
    locales = const <LocaleName>[];
  }
  if (!context.mounted) return;

  if (locales.isEmpty) {
    // 空列表防護：不顯示空對話框，直接視為「自動」並顯示提示
    await sp.setSttSystemLocaleId(null);
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: cs.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: cs.onSurface.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    l10n.sttLanguageSettingsTitle,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    l10n.sttLanguageNoLocalesMessage,
                    style: TextStyle(
                      fontSize: 13,
                      color: cs.onSurface.withOpacity(0.8),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.of(ctx).maybePop(),
                    child: Text(l10n.ttsServicesCloseButton),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    return;
  }

  final current = sp.sttSystemLocaleId;
  await showModalBottomSheet<String>(
    context: context,
    backgroundColor: cs.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) {
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.65,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 6),
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: cs.onSurface.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  l10n.sttLanguageSettingsTitle,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: locales.length + 1, // +1 for Auto
                  separatorBuilder: (c, i) => _sheetDivider(c),
                  itemBuilder: (c, i) {
                    final isAuto = i == 0;
                    final label = isAuto
                        ? l10n.sttLanguageAuto
                        : locales[i - 1].localeId;
                    final selected = isAuto
                        ? (current == null || current.isEmpty)
                        : (current == locales[i - 1].localeId);
                    return _TactileRow(
                      pressedScale: 1.00,
                      haptics: true,
                      onTap: () => Navigator.of(c).pop(label),
                      builder: (pressed) {
                        final base = cs.onSurface;
                        final target = pressed
                            ? (Color.lerp(
                                    base,
                                    isDark(c) ? Colors.black : Colors.white,
                                    0.55,
                                  ) ??
                                  base)
                            : base;
                        final bgTarget = pressed
                            ? (isDark(c)
                                  ? Colors.white.withOpacity(0.06)
                                  : Colors.black.withOpacity(0.05))
                            : Colors.transparent;
                        return TweenAnimationBuilder<Color?>(
                          tween: ColorTween(end: target),
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeOutCubic,
                          builder: (context, color, _) {
                            final cc = color ?? base;
                            return AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              curve: Curves.easeOutCubic,
                              color: bgTarget,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 14,
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      label,
                                      style: TextStyle(fontSize: 15, color: cc),
                                    ),
                                  ),
                                  if (selected)
                                    Icon(
                                      Lucide.Check,
                                      size: 16,
                                      color: cs.primary,
                                    ),
                                ],
                              ),
                            );
                          },
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      );
    },
  ).then((picked) async {
    if (picked == null) return;
    final isAuto = (picked == l10n.sttLanguageAuto);
    await sp.setSttSystemLocaleId(isAuto ? null : picked);
  });
}

bool isDark(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark;

Widget _sheetSelectRow(
  BuildContext context, {
  required String label,
  required String value,
  required List<String> options,
  required Future<void> Function(String picked) onSelected,
}) {
  final cs = Theme.of(context).colorScheme;
  return _TactileRow(
    onTap: options.isEmpty
        ? null
        : () async {
            final picked = await showModalBottomSheet<String>(
              context: context,
              backgroundColor: cs.surface,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
              ),
              builder: (ctx2) {
                return SafeArea(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.of(ctx2).size.height * 0.6,
                    ),
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: options.length,
                      separatorBuilder: (c, i) => _sheetDivider(ctx2),
                      itemBuilder: (c, i) => _sheetOption(
                        ctx2,
                        label: options[i],
                        onTap: () => Navigator.of(ctx2).pop(options[i]),
                      ),
                    ),
                  ),
                );
              },
            );
            if (picked != null && picked.isNotEmpty) {
              await onSelected(picked);
            }
          },
    builder: (pressed) {
      final baseColor = Theme.of(
        context,
      ).colorScheme.onSurface.withOpacity(0.9);
      return _AnimatedPressColor(
        pressed: pressed,
        base: baseColor,
        builder: (c) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Row(
              children: [
                Expanded(
                  child: Text(label, style: TextStyle(fontSize: 15, color: c)),
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Text(
                    value,
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withOpacity(0.6),
                    ),
                  ),
                ),
                Icon(Lucide.ChevronRight, size: 16, color: c),
              ],
            ),
          );
        },
      );
    },
  );
}

Widget _sheetOption(
  BuildContext context, {
  required String label,
  required VoidCallback onTap,
}) {
  final cs = Theme.of(context).colorScheme;
  return _TactileRow(
    pressedScale: 1.00,
    haptics: true,
    onTap: onTap,
    builder: (pressed) {
      final base = cs.onSurface;
      final target = pressed
          ? (Color.lerp(
                  base,
                  isDark(context) ? Colors.black : Colors.white,
                  0.55,
                ) ??
                base)
          : base;
      final bgTarget = pressed
          ? (isDark(context)
                ? Colors.white.withOpacity(0.06)
                : Colors.black.withOpacity(0.05))
          : Colors.transparent;
      return TweenAnimationBuilder<Color?>(
        tween: ColorTween(end: target),
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        builder: (context, color, _) {
          final c = color ?? base;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            color: bgTarget,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Expanded(
                  child: Text(label, style: TextStyle(fontSize: 15, color: c)),
                ),
              ],
            ),
          );
        },
      );
    },
  );
}

Widget _sheetDivider(BuildContext context) {
  final cs = Theme.of(context).colorScheme;
  return Divider(
    height: 1,
    thickness: 0.6,
    indent: 16,
    endIndent: 16,
    color: cs.outlineVariant.withOpacity(0.18),
  );
}

Widget _inputRowMobile(
  BuildContext context, {
  required String label,
  required TextEditingController controller,
  String? hint,
  bool obscure = false,
}) {
  final cs = Theme.of(context).colorScheme;
  return Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(fontSize: 12, color: cs.onSurface.withOpacity(0.7)),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          obscureText: obscure,
          decoration: InputDecoration(
            hintText: hint,
            isDense: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
      ],
    ),
  );
}

String _defaultBaseUrl(NetworkSttKind k) {
  switch (k) {
    case NetworkSttKind.openaiWhisper:
      return 'https://api.openai.com/v1/audio/transcriptions';
    case NetworkSttKind.groqWhisper:
      return 'https://api.groq.com/openai/v1/audio/transcriptions';
  }
}

String _defaultModel(NetworkSttKind k) {
  switch (k) {
    case NetworkSttKind.openaiWhisper:
      return 'whisper-1';
    case NetworkSttKind.groqWhisper:
      return 'whisper-large-v3';
  }
}
