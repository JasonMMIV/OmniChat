import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/providers/settings_provider.dart';
import '../../../core/services/live/live_api_models_service.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../core/services/haptics.dart';
import '../../../shared/widgets/snackbar.dart';

/// 行動版「即時語音通話」設定頁（`語音服務 → 即時語音通話`）。
///
/// - 模式選擇：標準語音模式（STT → LLM → TTS）／ Live API 模式，切換即
///   `setVoiceCallMode` + SnackBar。
/// - Live API 區（僅 `liveApi` 模式顯示）：Base URL / API Key / Model / Voice
///   四欄，`onChanged` debounce 300ms 寫回 `SettingsProvider`。
/// - 無金鑰時顯示 `liveApiNotConfigured` 警示；切至 `liveApi` 若無 Key 自動聚焦
///   Key 欄位。
class VoiceCallSettingsPage extends StatefulWidget {
  const VoiceCallSettingsPage({super.key});

  @override
  State<VoiceCallSettingsPage> createState() => _VoiceCallSettingsPageState();
}

class _VoiceCallSettingsPageState extends State<VoiceCallSettingsPage> {
  late final TextEditingController _baseUrlCtl;
  late final TextEditingController _apiKeyCtl;
  final FocusNode _apiKeyFocus = FocusNode();
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
    _apiKeyFocus.dispose();
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
    // 切至 liveApi 若無 Key 則自動聚焦 Key 欄位
    if (mode == VoiceCallMode.liveApi && !sp.liveApiConfigured) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _apiKeyFocus.requestFocus();
      });
    }
  }

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
        title: Text(l10n.settingsPageVoiceCall),
      ),
      body: Consumer<SettingsProvider>(
        builder: (context, sp, _) {
          final isLive = sp.usingLiveApi;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              _header(context, l10n.settingsPageVoiceCall, first: true),
              _iosSectionCard(
                children: [
                  _ModeRow(
                    label: l10n.voiceCallModeStandard,
                    selected: !isLive,
                    onTap: () => _switchMode(VoiceCallMode.standard),
                  ),
                  _iosDivider(context),
                  _ModeRow(
                    label: l10n.voiceCallModeLiveApi,
                    selected: isLive,
                    onTap: () => _switchMode(VoiceCallMode.liveApi),
                  ),
                ],
              ),
              if (isLive) ...[
                _header(context, l10n.liveApiConfigTitle),
                _iosSectionCard(
                  children: [
                    _inputRowMobile(
                      context,
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
                    _iosDivider(context),
                    _inputRowMobile(
                      context,
                      label: l10n.liveApiKey,
                      controller: _apiKeyCtl,
                      obscure: !_showApiKey,
                      focusNode: _apiKeyFocus,
                      suffixIcon: _TactileIconButton(
                        icon: _showApiKey ? Lucide.EyeOff : Lucide.Eye,
                        size: 18,
                        color: cs.onSurface.withOpacity(0.6),
                        onTap: () =>
                            setState(() => _showApiKey = !_showApiKey),
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
                    _iosDivider(context),
                    _ModelPickerRow(label: l10n.liveApiModel, value: sp.liveApiModel),
                    _iosDivider(context),
                    Builder(
                      builder: (ctx) => _sheetSelectRow(
                        ctx,
                        label: l10n.liveApiVoice,
                        value: sp.liveApiVoice,
                        options: VoiceCallDefaults.voices,
                        onSelected: (picked) async {
                          await context
                              .read<SettingsProvider>()
                              .setLiveApiVoice(picked);
                        },
                      ),
                    ),
                  ],
                ),
                if (!sp.liveApiConfigured) ...[
                  const SizedBox(height: 12),
                  _WarningBanner(
                    icon: Lucide.KeyRound,
                    message: l10n.liveApiNotConfigured,
                  ),
                ],
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
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
    );
  }
}

// --- Mode check row ---

class _ModeRow extends StatelessWidget {
  const _ModeRow({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return _TactileRow(
      pressedScale: 1.00,
      haptics: false,
      onTap: onTap,
      builder: (pressed) {
        final base = cs.onSurface.withOpacity(0.9);
        return _AnimatedPressColor(
          pressed: pressed,
          base: base,
          builder: (c) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
              child: Row(
                children: [
                  Icon(
                    selected ? Lucide.Activity : Lucide.Circle,
                    size: 18,
                    color: selected ? cs.primary : c.withOpacity(0.5),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 15,
                        color: c,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
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
        borderRadius: BorderRadius.circular(12),
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

// --- iOS-style helpers (mirroring stt_services_page.dart) ---

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
    this.size = 22,
  });
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final double size;
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
    );
    return Semantics(
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: () {
          Haptics.light();
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

Widget _inputRowMobile(
  BuildContext context, {
  required String label,
  required TextEditingController controller,
  String? hint,
  bool obscure = false,
  FocusNode? focusNode,
  Widget? suffixIcon,
  ValueChanged<String>? onChanged,
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
          focusNode: focusNode,
          onChanged: onChanged,
          decoration: InputDecoration(
            hintText: hint,
            hintMaxLines: 2,
            isDense: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            suffixIcon: suffixIcon,
          ),
        ),
      ],
    ),
  );
}

bool _isDark(BuildContext context) =>
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

/// 模型選擇列：點擊開啟 bottom sheet，從 Gemini REST API 抓取 Live 模型清單。
class _ModelPickerRow extends StatelessWidget {
  const _ModelPickerRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return _TactileRow(
      onTap: () => _showModelPicker(context, current: value),
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
}

Future<void> _showModelPicker(
  BuildContext context, {
  required String current,
}) async {
  final sp = context.read<SettingsProvider>();
  final cs = Theme.of(context).colorScheme;
  // P1：bottom sheet 的回傳值必須接住，否則清單選取與手動輸入都不會保存。
  final picked = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: cs.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) {
      return _ModelPickerSheet(
        apiKey: sp.liveApiApiKey,
        baseUrl: sp.liveApiBaseUrl,
        current: current,
        onSelected: (name) => Navigator.of(ctx).pop(name),
        onManual: () async {
          final name = await _showManualModelDialog(ctx, current);
          if (name != null && name.trim().isNotEmpty && ctx.mounted) {
            Navigator.of(ctx).pop(name.trim());
          }
        },
      );
    },
  );
  final selected = switch (picked) {
    final String v => v.trim(),
    _ => '',
  };
  if (selected.isNotEmpty) {
    await sp.setLiveApiModel(selected);
  }
}

Future<String?> _showManualModelDialog(BuildContext context, String current) {
  final l10n = AppLocalizations.of(context)!;
  final controller = TextEditingController(text: current);
  return showDialog<String>(
    context: context,
    builder: (ctx) {
      return AlertDialog(
        title: Text(l10n.liveApiModelManualInput),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: 'gemini-3.1-flash-live-preview'),
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
}

class _ModelPickerSheet extends StatefulWidget {
  const _ModelPickerSheet({
    required this.apiKey,
    required this.baseUrl,
    required this.current,
    required this.onSelected,
    required this.onManual,
  });

  final String apiKey;
  final String baseUrl;
  final String current;
  final ValueChanged<String> onSelected;
  final VoidCallback onManual;

  @override
  State<_ModelPickerSheet> createState() => _ModelPickerSheetState();
}

class _ModelPickerSheetState extends State<_ModelPickerSheet> {
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.65,
        ),
        child: Column(
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
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: l10n.liveApiModelRefresh,
                    onPressed: _refresh,
                    icon: const Icon(Lucide.RefreshCw, size: 20),
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
                          const Icon(Lucide.CircleX, size: 28),
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
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 24),
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
                            icon: const Icon(Lucide.RefreshCw, size: 16),
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
                  return ListView.separated(
                    shrinkWrap: true,
                    itemCount: models.length,
                    separatorBuilder: (c, i) => _sheetDivider(c),
                    itemBuilder: (c, i) => _sheetOption(
                      c,
                      label: models[i],
                      onTap: () => widget.onSelected(models[i]),
                    ),
                  );
                },
              ),
            ),
            const Divider(height: 1, thickness: 0.6),
            _sheetOption(
              context,
              label: l10n.liveApiModelManualInput,
              onTap: widget.onManual,
            ),
          ],
        ),
      ),
    );
  }
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
                  _isDark(context) ? Colors.black : Colors.white,
                  0.55,
                ) ??
                base)
          : base;
      final bgTarget = pressed
          ? (_isDark(context)
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
