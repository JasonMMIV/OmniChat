import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:speech_to_text/speech_to_text.dart'
    show LocaleName, SpeechToText;

import '../../icons/lucide_adapter.dart' as lucide;
import '../../l10n/app_localizations.dart';
import '../../core/providers/settings_provider.dart';
import '../../core/services/stt/network_stt.dart';

/// Desktop: 語音辨識（STT）右側面板。
/// Adapt 行動版 `stt_services_page.dart`，樣式對齊 `tts_services_pane.dart`
/// （hoverable card 列表、系統STT卡片、編輯/刪除互動）。
/// 註：第三方 STT 轉錄尚未實作，故不提供「新增」入口，避免使用者誤以為可用。
class DesktopSttServicesPane extends StatefulWidget {
  const DesktopSttServicesPane({super.key});
  @override
  State<DesktopSttServicesPane> createState() => _DesktopSttServicesPaneState();
}

class _DesktopSttServicesPaneState extends State<DesktopSttServicesPane> {
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;

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
                      l10n.sttServicesPageTitle,
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

              // System STT card
              const SliverToBoxAdapter(child: _SystemSttCard()),
              const SliverToBoxAdapter(child: SizedBox(height: 12)),

              // Network STT services list
              SliverToBoxAdapter(child: _NetworkSttList()),
            ],
          ),
        ),
      ),
    );
  }
}

class _NetworkSttList extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final sp = context.watch<SettingsProvider>();
    final services = sp.sttServices;
    if (services.isEmpty) {
      final cs = Theme.of(context).colorScheme;
      final l10n = AppLocalizations.of(context)!;
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 40),
        alignment: Alignment.center,
        child: Text(
          l10n.sttServicesPageNoNetworkServices,
          style: TextStyle(color: cs.onSurface.withOpacity(0.6)),
        ),
      );
    }
    return Column(
      children: [
        for (int i = 0; i < services.length; i++)
          Padding(
            key: ValueKey('desktop-stt-service-${services[i].id}'),
            padding: const EdgeInsets.only(bottom: 12),
            child: _NetworkServiceCard(
              service: services[i],
              selected: sp.sttServiceSelected == i,
              onTap: () async =>
                  context.read<SettingsProvider>().setSttServiceSelected(i),
              onEdit: () async {
                final updated = await _showEditNetworkDialog(
                  context,
                  services[i],
                );
                if (updated != null) {
                  final list = List<SttServiceOptions>.from(
                    context.read<SettingsProvider>().sttServices,
                  );
                  list[i] = updated;
                  await context.read<SettingsProvider>().setSttServices(list);
                }
              },
              onDelete: () async {
                final sp2 = context.read<SettingsProvider>();
                final list = List<SttServiceOptions>.from(sp2.sttServices);
                list.removeAt(i);
                await sp2.setSttServices(list);
                var idx = sp2.sttServiceSelected;
                if (idx >= list.length) {
                  idx = list.isEmpty ? -1 : list.length - 1;
                }
                await sp2.setSttServiceSelected(idx);
              },
            ),
          ),
      ],
    );
  }
}

class _NetworkServiceCard extends StatefulWidget {
  const _NetworkServiceCard({
    required this.service,
    required this.selected,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });
  final SttServiceOptions service;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  @override
  State<_NetworkServiceCard> createState() => _NetworkServiceCardState();
}

class _NetworkServiceCardState extends State<_NetworkServiceCard> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final l10n = AppLocalizations.of(context)!;
    final baseBg = isDark ? Colors.white10 : Colors.white.withOpacity(0.96);
    final borderColor = _hover || widget.selected
        ? cs.primary.withOpacity(isDark ? 0.35 : 0.45)
        : cs.outlineVariant.withOpacity(isDark ? 0.12 : 0.08);
    final displayName = widget.service.name.trim().isEmpty
        ? networkSttKindDisplayName(widget.service.kind)
        : widget.service.name.trim();
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
              _CircleIconBadge(icon: lucide.Lucide.Mic, size: 24),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    // 尚未支援轉錄標示（下階段才實作網路轉錄）
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
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
              _SmallIconBtn(
                icon: lucide.Lucide.Settings2,
                onTap: widget.onEdit,
              ),
              const SizedBox(width: 6),
              _SmallIconBtn(icon: lucide.Lucide.Trash2, onTap: widget.onDelete),
              // no check icon on desktop
            ],
          ),
        ),
      ),
    );
  }
}

class _SystemSttCard extends StatefulWidget {
  const _SystemSttCard();

  @override
  State<_SystemSttCard> createState() => _SystemSttCardState();
}

class _SystemSttCardState extends State<_SystemSttCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final l10n = AppLocalizations.of(context)!;
    final sp = context.watch<SettingsProvider>();

    final baseBg = isDark ? Colors.white10 : Colors.white.withOpacity(0.96);
    final borderColor = _hover
        ? cs.primary.withOpacity(isDark ? 0.35 : 0.45)
        : cs.outlineVariant.withOpacity(isDark ? 0.12 : 0.08);

    final currentLocale = sp.sttSystemLocaleId;
    final subText = (currentLocale == null || currentLocale.isEmpty)
        ? l10n.sttLanguageAuto
        : currentLocale;

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () async {
          try {
            await context.read<SettingsProvider>().setSttServiceSelected(-1);
          } catch (_) {}
        },
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
              _CircleIconBadge(icon: lucide.Lucide.Mic, size: 24),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      l10n.sttServicesPageSystemSttTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subText,
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
              Tooltip(
                message: l10n.sttServicesPageSystemSttConfigureTooltip,
                child: _SmallIconBtn(
                  icon: lucide.Lucide.Settings2,
                  onTap: () => _showSystemSttLanguageDialog(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showSystemSttLanguageDialog(BuildContext context) async {
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
      // 空列表防護：直接視為「自動」並顯示提示
      await sp.setSttSystemLocaleId(null);
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: true,
        builder: (ctx) => Dialog(
          backgroundColor: cs.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 18,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          l10n.sttLanguageSettingsTitle,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      _SmallIconBtn(
                        icon: lucide.Lucide.X,
                        onTap: () => Navigator.of(ctx).maybePop(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  _deskDivider(context),
                  const SizedBox(height: 10),
                  Text(
                    l10n.sttLanguageNoLocalesMessage,
                    style: TextStyle(
                      fontSize: 13,
                      color: cs.onSurface.withOpacity(0.8),
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
          ),
        ),
      );
      return;
    }

    final current = sp.sttSystemLocaleId;
    await showDialog<String>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        return Dialog(
          backgroundColor: cs.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 18,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(ctx).size.height * 0.6,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(6, 4, 6, 8),
                        child: Text(
                          l10n.sttLanguageSettingsTitle,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      for (int i = 0; i < locales.length + 1; i++) ...[
                        if (i != 0)
                          Divider(
                            height: 10,
                            thickness: 0.6,
                            indent: 4,
                            endIndent: 4,
                            color: cs.outlineVariant.withOpacity(0.12),
                          ),
                        _DialogOption(
                          label: i == 0
                              ? l10n.sttLanguageAuto
                              : locales[i - 1].localeId,
                          selected: i == 0
                              ? (current == null || current.isEmpty)
                              : (current == locales[i - 1].localeId),
                          onTap: () => Navigator.of(ctx).pop(
                            i == 0
                                ? l10n.sttLanguageAuto
                                : locales[i - 1].localeId,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
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
}

// --------- Small UI helpers (local to this file) ---------

// 用於 `locales()` 的專屬實例（只查詢語言列表，不佔用語音對話/聽寫實例）；
// 延遲建立，避免 module load 即構造 SpeechToText 實例。
SpeechToText? _sttLocalesSpeechToText;
SpeechToText get _localesSpeechToText =>
    // ignore: invalid_use_of_visible_for_testing_member
    _sttLocalesSpeechToText ??= SpeechToText.withMethodChannel();

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

class _SmallIconBtn extends StatefulWidget {
  const _SmallIconBtn({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;
  @override
  State<_SmallIconBtn> createState() => _SmallIconBtnState();
}

class _SmallIconBtnState extends State<_SmallIconBtn> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = _hover
        ? (isDark
              ? Colors.white.withOpacity(0.06)
              : Colors.black.withOpacity(0.05))
        : Colors.transparent;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.center,
          child: Icon(widget.icon, size: 18, color: cs.onSurface),
        ),
      ),
    );
  }
}

Widget _deskDivider(BuildContext context) {
  final cs = Theme.of(context).colorScheme;
  return Divider(
    height: 6,
    thickness: 0.6,
    indent: 12,
    endIndent: 12,
    color: cs.outlineVariant.withOpacity(0.18),
  );
}

class _DialogOption extends StatefulWidget {
  const _DialogOption({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;
  @override
  State<_DialogOption> createState() => _DialogOptionState();
}

class _DialogOptionState extends State<_DialogOption> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = widget.selected
        ? cs.primary.withOpacity(0.08)
        : (_hover
              ? (isDark
                    ? Colors.white.withOpacity(0.06)
                    : Colors.black.withOpacity(0.04))
              : Colors.transparent);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: 14,
                    color: cs.onSurface.withOpacity(0.9),
                  ),
                ),
              ),
              if (widget.selected)
                Icon(lucide.Lucide.Check, size: 16, color: cs.primary),
            ],
          ),
        ),
      ),
    );
  }
}

Future<SttServiceOptions?> _showEditNetworkDialog(
  BuildContext context,
  SttServiceOptions initial,
) => _showNetworkDialog(context, initial);

Future<SttServiceOptions?> _showNetworkDialog(
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
  await showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) {
      return Dialog(
        backgroundColor: cs.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: StatefulBuilder(
              builder: (ctx2, setState) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            initial == null
                                ? l10n.sttServicesDialogAddTitle
                                : l10n.sttServicesDialogEditTitle,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        _SmallIconBtn(
                          icon: lucide.Lucide.X,
                          onTap: () => Navigator.of(ctx).maybePop(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    _deskDivider(context),
                    const SizedBox(height: 10),
                    Flexible(
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _SelectRow(
                              label: l10n.sttServicesDialogProviderType,
                              value: networkSttKindDisplayName(kind),
                              options: NetworkSttKind.values
                                  .map(networkSttKindDisplayName)
                                  .toList(),
                              onSelected: (picked) {
                                setState(() {
                                  for (final k in NetworkSttKind.values) {
                                    if (picked ==
                                        networkSttKindDisplayName(k)) {
                                      kind = k;
                                      break;
                                    }
                                  }
                                });
                              },
                            ),
                            const SizedBox(height: 6),
                            _InputRow(
                              label: l10n.sttServicesFieldNameLabel,
                              controller: nameCtl,
                              hint: networkSttKindDisplayName(kind),
                            ),
                            const SizedBox(height: 6),
                            _InputRow(
                              label: l10n.sttServicesFieldApiKeyLabel,
                              controller: apiKeyCtl,
                              obscure: true,
                            ),
                            const SizedBox(height: 6),
                            _InputRow(
                              label: l10n.sttServicesFieldBaseUrlLabel,
                              controller: baseCtl,
                              hint: _defaultBaseUrl(kind),
                            ),
                            const SizedBox(height: 6),
                            _InputRow(
                              label: l10n.sttServicesFieldModelLabel,
                              controller: modelCtl,
                              hint: _defaultModel(kind),
                            ),
                            const SizedBox(height: 14),
                          ],
                        ),
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextButton(
                            onPressed: () => Navigator.of(ctx).maybePop(),
                            style: TextButton.styleFrom(
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                            ),
                            child: Text(l10n.sttServicesDialogCancelButton),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            onPressed: () {
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
                              if (apiKey.isEmpty) return; // guard
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
                            style: FilledButton.styleFrom(
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 10,
                              ),
                            ),
                            child: Text(
                              initial == null
                                  ? l10n.sttServicesDialogAddButton
                                  : l10n.sttServicesDialogSaveButton,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      );
    },
  ).then((_) {});
  return result;
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

class _SelectRow extends StatelessWidget {
  const _SelectRow({
    required this.label,
    required this.value,
    required this.options,
    required this.onSelected,
  });
  final String label;
  final String value;
  final List<String> options;
  final ValueChanged<String> onSelected;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 15,
                color: cs.onSurface.withOpacity(0.9),
              ),
            ),
          ),
          _SelectButton(value: value, options: options, onSelected: onSelected),
        ],
      ),
    );
  }
}

class _SelectButton extends StatefulWidget {
  const _SelectButton({
    required this.value,
    required this.options,
    required this.onSelected,
  });
  final String value;
  final List<String> options;
  final ValueChanged<String> onSelected;
  @override
  State<_SelectButton> createState() => _SelectButtonState();
}

class _SelectButtonState extends State<_SelectButton> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = _hover
        ? (isDark
              ? Colors.white.withOpacity(0.06)
              : Colors.black.withOpacity(0.04))
        : Colors.transparent;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: () async {
          final picked = await _showOptionsDialog(
            context,
            widget.options,
            widget.value,
          );
          if (picked != null) widget.onSelected(picked);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: cs.outlineVariant.withOpacity(0.12),
              width: 0.6,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.value,
                style: TextStyle(
                  fontSize: 14,
                  color: cs.onSurface.withOpacity(0.9),
                ),
              ),
              const SizedBox(width: 6),
              Icon(
                lucide.Lucide.ChevronDown,
                size: 16,
                color: cs.onSurface.withOpacity(0.8),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<String?> _showOptionsDialog(
  BuildContext context,
  List<String> options,
  String current,
) async {
  if (options.isEmpty) return null;
  final cs = Theme.of(context).colorScheme;
  String? result;
  await showDialog<String>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) {
      return Dialog(
        backgroundColor: cs.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(ctx).size.height * 0.6,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (int i = 0; i < options.length; i++) ...[
                      _DialogOption(
                        label: options[i],
                        selected: options[i] == current,
                        onTap: () => Navigator.of(ctx).pop(options[i]),
                      ),
                      if (i != options.length - 1)
                        Divider(
                          height: 10,
                          thickness: 0.6,
                          indent: 4,
                          endIndent: 4,
                          color: cs.outlineVariant.withOpacity(0.12),
                        ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  ).then((v) => result = v);
  return result;
}

class _InputRow extends StatelessWidget {
  const _InputRow({
    required this.label,
    required this.controller,
    this.hint,
    this.obscure = false,
  });
  final String label;
  final TextEditingController controller;
  final String? hint;
  final bool obscure;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: cs.onSurface.withOpacity(0.7),
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: controller,
            obscureText: obscure,
            decoration: InputDecoration(
              hintText: hint,
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
