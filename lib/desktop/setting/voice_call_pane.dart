import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../icons/lucide_adapter.dart' as lucide;
import '../../l10n/app_localizations.dart';
import '../../core/providers/settings_provider.dart';
import '../../core/services/live/live_api_models_service.dart';
import '../../shared/widgets/snackbar.dart';

/// Desktop: 即時語音通話（Voice Call）右側面板。
/// Adapt 行動版 `voice_call_settings_page.dart`，樣式對齊 `tts_services_pane.dart`
/// （hoverable card / dialog）。模式切換（標準 / Live API）即寫回並顯示 SnackBar；
/// Live API 區（僅 liveApi 模式顯示）四欄 debounce 300ms 寫回，無金鑰顯示警示。
class DesktopVoiceCallPane extends StatefulWidget {
  const DesktopVoiceCallPane({super.key});

  @override
  State<DesktopVoiceCallPane> createState() => _DesktopVoiceCallPaneState();
}

class _DesktopVoiceCallPaneState extends State<DesktopVoiceCallPane> {
  late final TextEditingController _baseUrlCtl;
  late final TextEditingController _apiKeyCtl;
  bool _showApiKey = false;

  Timer? _baseUrlDebounce;
  Timer? _apiKeyDebounce;

  @override
  void initState() {
    super.initState();
    final sp = context.read<SettingsProvider>();
    _baseUrlCtl = TextEditingController(text: sp.liveApiBaseUrl);
    _apiKeyCtl = TextEditingController(text: sp.liveApiApiKey);
  }

  @override
  void dispose() {
    _baseUrlDebounce?.cancel();
    _apiKeyDebounce?.cancel();
    _baseUrlCtl.dispose();
    _apiKeyCtl.dispose();
    super.dispose();
  }

  Future<void> _switchMode(VoiceCallMode mode) async {
    final sp = context.read<SettingsProvider>();
    if (sp.voiceCallMode == mode) return;
    await sp.setVoiceCallMode(mode);
    if (!mounted) return;
    showAppSnackBar(
      context,
      message: mode == VoiceCallMode.liveApi
          ? AppLocalizations.of(context)!.voiceCallSwitchedToLiveApi
          : AppLocalizations.of(context)!.voiceCallSwitchedToStandard,
      type: NotificationType.success,
    );
  }

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
          child: Consumer<SettingsProvider>(
            builder: (context, sp, _) {
              final isLive = sp.usingLiveApi;
              return CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: SizedBox(
                      height: 36,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          l10n.settingsPageVoiceCall,
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
                    child: Row(
                      children: [
                        Expanded(
                          child: _ModeCard(
                            icon: lucide.Lucide.Circle,
                            title: l10n.voiceCallModeStandard,
                            selected: !isLive,
                            onTap: () =>
                                _switchMode(VoiceCallMode.standard),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _ModeCard(
                            icon: lucide.Lucide.Activity,
                            title: l10n.voiceCallModeLiveApi,
                            selected: isLive,
                            onTap: () => _switchMode(VoiceCallMode.liveApi),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (isLive) ...[
                    const SliverToBoxAdapter(child: SizedBox(height: 20)),
                    SliverToBoxAdapter(
                      child: _configCard(l10n.liveApiConfigTitle, [
                        _InputRow(
                          label: l10n.liveApiBaseUrl,
                          controller: _baseUrlCtl,
                          hint: VoiceCallDefaults.officialBaseUrl,
                          onChanged: (v) {
                            _baseUrlDebounce?.cancel();
                            _baseUrlDebounce = Timer(
                              const Duration(milliseconds: 300),
                              () => context
                                  .read<SettingsProvider>()
                                  .setLiveApiBaseUrl(v),
                            );
                          },
                        ),
                        _InputRow(
                          label: l10n.liveApiKey,
                          controller: _apiKeyCtl,
                          obscure: !_showApiKey,
                          suffixIcon: MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: GestureDetector(
                              onTap: () =>
                                  setState(() => _showApiKey = !_showApiKey),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 8),
                                child: Icon(
                                  _showApiKey
                                      ? lucide.Lucide.EyeOff
                                      : lucide.Lucide.Eye,
                                  size: 18,
                                  color: cs.onSurface.withOpacity(0.6),
                                ),
                              ),
                            ),
                          ),
                          onChanged: (v) {
                            _apiKeyDebounce?.cancel();
                            _apiKeyDebounce = Timer(
                              const Duration(milliseconds: 300),
                              () => context
                                  .read<SettingsProvider>()
                                  .setLiveApiApiKey(v),
                            );
                          },
                        ),
                        _ModelSelectRow(
                          label: l10n.liveApiModel,
                          value: sp.liveApiModel,
                          apiKey: sp.liveApiApiKey,
                          baseUrl: sp.liveApiBaseUrl,
                          onSelected: (v) => context
                              .read<SettingsProvider>()
                              .setLiveApiModel(v),
                        ),
                        _SelectRow(
                          label: l10n.liveApiVoice,
                          value: sp.liveApiVoice,
                          options: VoiceCallDefaults.voices,
                          onSelected: (picked) => context
                              .read<SettingsProvider>()
                              .setLiveApiVoice(picked),
                        ),
                      ]),
                    ),
                    if (!sp.liveApiConfigured) ...[
                      const SliverToBoxAdapter(child: SizedBox(height: 12)),
                      SliverToBoxAdapter(
                        child: _WarningBanner(
                          icon: lucide.Lucide.KeyRound,
                          message: l10n.liveApiNotConfigured,
                        ),
                      ),
                    ],
                    const SliverToBoxAdapter(child: SizedBox(height: 12)),
                    SliverToBoxAdapter(
                      child: Text(
                        l10n.liveApiKeyStorageNote,
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurface.withOpacity(0.6),
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _configCard(String title, List<Widget> children) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? Colors.white10 : Colors.white.withOpacity(0.96);
    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: cs.outlineVariant.withOpacity(isDark ? 0.12 : 0.08),
          width: 1.0,
        ),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface.withOpacity(0.8),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _deskDivider(context),
          const SizedBox(height: 6),
          ...children,
        ],
      ),
    );
  }
}

// --- Mode card ---

class _ModeCard extends StatefulWidget {
  const _ModeCard({
    required this.icon,
    required this.title,
    required this.selected,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final bool selected;
  final VoidCallback onTap;
  @override
  State<_ModeCard> createState() => _ModeCardState();
}

class _ModeCardState extends State<_ModeCard> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final baseBg = isDark ? Colors.white10 : Colors.white.withOpacity(0.96);
    final borderColor = (_hover || widget.selected)
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
              _CircleIconBadge(
                icon: widget.icon,
                size: 24,
                tinted: widget.selected,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: widget.selected ? cs.primary : null,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WarningBanner extends StatelessWidget {
  const _WarningBanner({required this.icon, required this.message});
  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.tertiary.withOpacity(0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.tertiary.withOpacity(0.3), width: 0.6),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Icon(icon, size: 18, color: cs.tertiary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(fontSize: 13, color: cs.tertiary),
            ),
          ),
        ],
      ),
    );
  }
}

// --------- Small UI helpers (local to this file, mirroring stt_services_pane) ---------

class _CircleIconBadge extends StatelessWidget {
  const _CircleIconBadge({
    required this.icon,
    this.size = 24,
    this.tinted = false,
  });
  final IconData icon;
  final double size;
  final bool tinted;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = tinted
        ? cs.primary.withOpacity(0.12)
        : isDark
        ? Colors.white12
        : Colors.black.withOpacity(0.06);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
      alignment: Alignment.center,
      child: Icon(
        icon,
        size: size * 0.62,
        color: tinted ? cs.primary : cs.onSurface.withOpacity(0.9),
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

class _InputRow extends StatelessWidget {
  const _InputRow({
    required this.label,
    required this.controller,
    this.hint,
    this.obscure = false,
    this.suffixIcon,
    this.onChanged,
  });
  final String label;
  final TextEditingController controller;
  final String? hint;
  final bool obscure;
  final Widget? suffixIcon;
  final ValueChanged<String>? onChanged;
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
            onChanged: onChanged,
            decoration: InputDecoration(
              hintText: hint,
              hintMaxLines: 2,
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              suffixIcon: suffixIcon,
              suffixIconConstraints: const BoxConstraints(
                minWidth: 36,
                minHeight: 36,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 模型選擇列：點擊開啟 dialog，從 Gemini REST API 抓取 Live 模型清單。
class _ModelSelectRow extends StatelessWidget {
  const _ModelSelectRow({
    required this.label,
    required this.value,
    required this.apiKey,
    required this.baseUrl,
    required this.onSelected,
  });

  final String label;
  final String value;
  final String apiKey;
  final String baseUrl;
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
          _ModelSelectButton(
            value: value,
            apiKey: apiKey,
            baseUrl: baseUrl,
            onSelected: onSelected,
          ),
        ],
      ),
    );
  }
}

class _ModelSelectButton extends StatelessWidget {
  const _ModelSelectButton({
    required this.value,
    required this.apiKey,
    required this.baseUrl,
    required this.onSelected,
  });

  final String value;
  final String apiKey;
  final String baseUrl;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () async {
          final picked = await _showModelDialog(
            context,
            current: value,
            apiKey: apiKey,
            baseUrl: baseUrl,
          );
          if (picked != null && picked.isNotEmpty) onSelected(picked);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: cs.outlineVariant.withOpacity(0.12),
              width: 0.6,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: Text(
                  value,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    color: cs.onSurface.withOpacity(0.9),
                  ),
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

Future<String?> _showModelDialog(
  BuildContext context, {
  required String current,
  required String apiKey,
  required String baseUrl,
}) async {
  final cs = Theme.of(context).colorScheme;
  return showDialog<String>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) {
      return Dialog(
        backgroundColor: cs.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420, maxHeight: 460),
          child: _ModelDialog(
            current: current,
            apiKey: apiKey,
            baseUrl: baseUrl,
          ),
        ),
      );
    },
  );
}

class _ModelDialog extends StatefulWidget {
  const _ModelDialog({
    required this.current,
    required this.apiKey,
    required this.baseUrl,
  });

  final String current;
  final String apiKey;
  final String baseUrl;

  @override
  State<_ModelDialog> createState() => _ModelDialogState();
}

class _ModelDialogState extends State<_ModelDialog> {
  late Future<LiveApiModelsResult> _future;

  @override
  void initState() {
    super.initState();
    _future = _fetch();
  }

  Future<LiveApiModelsResult> _fetch() {
    return LiveApiModelsService.fetchLiveModels(
      apiKey: widget.apiKey,
      baseUrl: widget.baseUrl,
    );
  }

  void _refresh() {
    LiveApiModelsService.invalidateCache();
    setState(() {
      _future = _fetch();
    });
  }

  Future<void> _manual() async {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController(text: widget.current);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(l10n.liveApiModelManualInput),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'gemini-3.1-flash-live-preview'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(l10n.sttServicesDialogCancelButton),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(controller.text),
              child: Text(l10n.sttServicesDialogSaveButton),
            ),
          ],
        );
      },
    );
    if (name != null && name.trim().isNotEmpty && mounted) {
      Navigator.of(context).pop(name.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  l10n.liveApiModelSelectTitle,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                tooltip: l10n.liveApiModelRefresh,
                onPressed: _refresh,
                icon: const Icon(lucide.Lucide.RefreshCw, size: 18),
              ),
            ],
          ),
        ),
        const Divider(height: 1, thickness: 0.6),
        Flexible(
          child: FutureBuilder<LiveApiModelsResult>(
            future: _future,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 40),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final result = snap.data;
              if (result == null || result.hasError) {
                if (result?.error == LiveApiModelsError.empty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: Text(
                        l10n.liveApiModelFetchEmpty,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13,
                          color: cs.onSurface.withOpacity(0.7),
                        ),
                      ),
                    ),
                  );
                }
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(lucide.Lucide.CircleX, size: 28),
                      const SizedBox(height: 10),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Text(
                          l10n.liveApiModelFetchError,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 13,
                            color: cs.onSurface.withOpacity(0.7),
                          ),
                        ),
                      ),
                      if ((result?.detail ?? '').isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: SelectableText(
                            result!.detail!,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 11,
                              color: cs.onSurface.withOpacity(0.5),
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      FilledButton.tonalIcon(
                        onPressed: _refresh,
                        icon: const Icon(lucide.Lucide.RefreshCw, size: 16),
                        label: Text(l10n.liveApiModelFetchRetry),
                      ),
                    ],
                  ),
                );
              }
              final models = result.models;
              if (models.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Center(
                    child: Text(
                      l10n.liveApiModelFetchEmpty,
                      style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurface.withOpacity(0.7),
                      ),
                    ),
                  ),
                );
              }
              return ListView.builder(
                itemCount: models.length,
                itemBuilder: (c, i) {
                  final model = models[i];
                  return ListTile(
                    dense: true,
                    title: Text(
                      model,
                      style: const TextStyle(fontSize: 14),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: model == widget.current
                        ? Icon(lucide.Lucide.Check, size: 18, color: cs.primary)
                        : null,
                    onTap: () => Navigator.of(c).pop(model),
                  );
                },
              );
            },
          ),
        ),
        const Divider(height: 1, thickness: 0.6),
        ListTile(
          dense: true,
          leading: const Icon(lucide.Lucide.Pencil, size: 18),
          title: Text(l10n.liveApiModelManualInput,
              style: const TextStyle(fontSize: 14)),
          onTap: _manual,
        ),
      ],
    );
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
