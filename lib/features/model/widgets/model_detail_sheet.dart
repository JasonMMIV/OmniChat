import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/providers/model_provider.dart';
import '../../../core/services/api/builtin_tools.dart';
import '../../../core/services/api/native_input_policy.dart';
import '../../../core/services/api/reasoning_wire.dart';
import '../../../core/utils/reasoning_overrides.dart';
import '../../../core/utils/token_format.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../shared/widgets/ios_switch.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/ios_tile_button.dart';
import 'modality_badge.dart';

Future<bool?> showModelDetailSheet(
  BuildContext context, {
  required String providerKey,
  required String modelId,
}) {
  final cs = Theme.of(context).colorScheme;
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: cs.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => SafeArea(
      top: false,
      child: AnimatedPadding(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: _ModelDetailSheet(
          providerKey: providerKey,
          modelId: modelId,
          isNew: false,
        ),
      ),
    ),
  );
}

Future<bool?> showCreateModelSheet(
  BuildContext context, {
  required String providerKey,
}) {
  final cs = Theme.of(context).colorScheme;
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: cs.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => SafeArea(
      top: false,
      child: AnimatedPadding(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: _ModelDetailSheet(
          providerKey: providerKey,
          modelId: '',
          isNew: true,
        ),
      ),
    ),
  );
}

class _ModelDetailSheet extends StatefulWidget {
  const _ModelDetailSheet({
    required this.providerKey,
    required this.modelId,
    this.isNew = false,
  });
  final String providerKey;
  final String modelId;
  final bool isNew;
  @override
  State<_ModelDetailSheet> createState() => _ModelDetailSheetState();
}

enum _TabKind { basic, advanced, tools }

class _ModelDetailSheetState extends State<_ModelDetailSheet>
    with SingleTickerProviderStateMixin {
  _TabKind _tab = _TabKind.basic;
  late final TabController _tabCtrl;
  late final ProviderKind _providerKind;
  late final bool _showBuiltinToolsTab;

  late TextEditingController _idCtrl;
  late TextEditingController _nameCtrl;
  bool _nameEdited = false;
  ModelType _type = ModelType.chat;
  final Set<Modality> _input = {Modality.text};
  final Set<Modality> _output = {Modality.text};
  final Set<ModelAbility> _abilities = {};

  // Freshly inferred defaults (models.dev catalog → regex fallback) for the
  // current model id. The "預設 / 自訂" source capsules compare the live
  // section state against this snapshot; a section is 自訂 when it differs,
  // and the reset icon restores these values. In the create flow the id is
  // typed after the sheet opens, so this is recomputed as the id changes.
  late ModelInfo _base;
  Timer? _baseDebounce;

  // Which spec sections the user actually touched. When `_base` is recomputed
  // for a newly typed id, untouched sections adopt the new inferred defaults;
  // touched ones stay as the user left them (and become 自訂 relative to the
  // new base if they differ).
  bool _typeTouched = false;
  bool _inputTouched = false;
  bool _outputTouched = false;
  bool _abilitiesTouched = false;

  // Token limits (basic tab). Empty text = follow the inferred default; the
  // parsed values persist as modelOverrides[key]['contextWindow' |
  // 'maxOutput'] only when they differ from _base.
  late final TextEditingController _contextWindowCtrl;
  late final TextEditingController _maxOutputCtrl;

  // Native audio/PDF transport (multimodal plan B5). `null` = follow the
  // host/provider default; a bool is an explicit per-model override.
  bool? _nativePdf;
  bool? _nativeAudio;
  late final bool _nativePdfAuto;
  late final bool _nativeAudioAuto;

  // Advanced (UI only)
  final List<_HeaderKV> _headers = [];
  final List<_BodyKV> _bodies = [];

  // Built-in tools (per provider)
  bool _googleUrlContextTool = false;
  bool _googleCodeExecutionTool = false;
  bool _googleYoutubeTool = false;
  bool _openaiCodeInterpreterTool = false;
  bool _openaiImageGenerationTool = false;

  // Route this model through the standalone OpenAI Images API
  // (/images/generations + /images/edits) instead of chat completions.
  // Defaults ON for image-output models (the only models that see the toggle);
  // stored as `useImagesApi: false` only when explicitly turned off.
  bool _useImagesApi = true;

  // Per-model reasoning-effort override. `null` = follow built-in rules;
  // non-null = stored under modelOverrides[key]['reasoning'] on save.
  ReasoningOverride? _reasoningOverride;
  // Explicit reasoning wire dialect (plan batch 2). `null` = auto.
  String? _reasoningWire;
  late final ReasoningWireTransport _wireTransport;
  bool _reasoningProbing = false;
  String _reasoningProbeProgress = '';

  // Pass the aspect-ratio string directly as `aspect_ratio` for providers
  // that natively support it (e.g. Nano Banana 2) instead of `size`.
  // Whether the model is an image model is decided by the output modality
  // (basic tab), so this toggle only shows for image-output models.
  bool _useAspectRatioParam = false;

  @override
  void initState() {
    super.initState();
    final settings = context.read<SettingsProvider>();
    final cfg = settings.getProviderConfig(widget.providerKey);
    final modelCfg = widget.isNew ? cfg : cfg.forModelProtocol(widget.modelId);
    _providerKind = ProviderConfig.classify(
      modelCfg.id,
      explicitType: modelCfg.providerType,
    );
    _wireTransport = reasoningWireTransportFor(
      providerType: _providerKind.name,
      useResponseApi: modelCfg.useResponseApi == true,
    );
    _nativePdfAuto = nativePdfDefaultFor(modelCfg);
    _nativeAudioAuto = nativeAudioDefaultFor(modelCfg);
    _showBuiltinToolsTab =
        _providerKind == ProviderKind.google ||
        _providerKind == ProviderKind.openai ||
        _providerKind == ProviderKind.neuralwatt;
    _tabCtrl = TabController(length: _showBuiltinToolsTab ? 3 : 2, vsync: this);
    _tabCtrl.addListener(() {
      if (_tabCtrl.indexIsChanging) return;
      setState(() {
        if (_tabCtrl.index == 0) {
          _tab = _TabKind.basic;
        } else if (_tabCtrl.index == 1) {
          _tab = _TabKind.advanced;
        } else {
          _tab = _TabKind.tools;
        }
      });
    });
    // Resolve display model id from per-model overrides when present (apiModelId),
    // falling back to the logical key for backwards compatibility.
    Map? _initialOv;
    if (!widget.isNew) {
      final raw = cfg.modelOverrides[widget.modelId];
      if (raw is Map) _initialOv = raw;
    }
    String displayModelId = widget.modelId;
    if (_initialOv != null) {
      final raw = (_initialOv['apiModelId'] ?? _initialOv['api_model_id'])
          ?.toString()
          .trim();
      if (raw != null && raw.isNotEmpty) {
        displayModelId = raw;
      }
    }
    _idCtrl = TextEditingController(text: displayModelId);
    // Defaults from inferred base if id provided; otherwise generic defaults for new
    final base = ModelRegistry.infer(
      ModelInfo(
        id: displayModelId.isEmpty ? 'custom' : displayModelId,
        displayName: displayModelId.isEmpty ? '' : displayModelId,
      ),
    );
    _nameCtrl = TextEditingController(text: base.displayName);
    _type = base.type;
    _input
      ..clear()
      ..addAll(base.input);
    _output
      ..clear()
      ..addAll(base.output);
    _abilities
      ..clear()
      ..addAll(base.abilities);
    _base = base;
    // Token limits prefill from the inferred defaults; a stored user override
    // (loaded below) replaces the prefill.
    _contextWindowCtrl = TextEditingController(
      text: base.contextWindow?.toString() ?? '',
    );
    _maxOutputCtrl = TextEditingController(
      text: base.maxOutput?.toString() ?? '',
    );

    if (!widget.isNew) {
      final rawOv = cfg.modelOverrides[widget.modelId];
      final ov = _initialOv ?? (rawOv is Map ? rawOv : null);
      if (ov != null) {
        _nameCtrl.text = (ov['name'] as String?)?.trim().isNotEmpty == true
            ? (ov['name'] as String)
            : _nameCtrl.text;
        final t = (ov['type'] as String?) ?? '';
        if (t == 'embedding')
          _type = ModelType.embedding;
        else if (t == 'chat')
          _type = ModelType.chat;
        // Shared parser + legacy migration (multimodal plan §7 F7): unknown
        // values are skipped, and a pre-multimodal override's implicit
        // `text,image` list must not hide the catalog's audio/pdf/video.
        final effective = ModelRegistry.applyOverride(base, ov);
        _input
          ..clear()
          ..addAll(effective.input);
        _output
          ..clear()
          ..addAll(effective.output);
        _abilities
          ..clear()
          ..addAll(effective.abilities);
        // Token limits: a stored user override replaces the inferred prefill
        // (an absent key keeps the default already in the controllers).
        final ovContextWindow = ModelRegistry.parseIntOverride(
          ov['contextWindow'],
        );
        if (ovContextWindow != null) {
          _contextWindowCtrl.text = '$ovContextWindow';
        }
        final ovMaxOutput = ModelRegistry.parseIntOverride(ov['maxOutput']);
        if (ovMaxOutput != null) {
          _maxOutputCtrl.text = '$ovMaxOutput';
        }
        // headers/body
        final rawHdrs = ov['headers'];
        final hdrs = (rawHdrs is List) ? rawHdrs : const <dynamic>[];
        for (final h in hdrs) {
          if (h is Map) {
            final kv = _HeaderKV();
            kv.name.text = (h['name'] as String?) ?? '';
            kv.value.text = (h['value'] as String?) ?? '';
            _headers.add(kv);
          }
        }
        final rawBds = ov['body'];
        final bds = (rawBds is List) ? rawBds : const <dynamic>[];
        for (final b in bds) {
          if (b is Map) {
            final kv = _BodyKV();
            kv.keyCtrl.text = (b['key'] as String?) ?? '';
            kv.valueCtrl.text = (b['value'] as String?) ?? '';
            _bodies.add(kv);
          }
        }
        final rawNativePdf = ov['nativePdf'];
        _nativePdf = rawNativePdf is bool ? rawNativePdf : null;
        final rawNativeAudio = ov['nativeAudio'];
        _nativeAudio = rawNativeAudio is bool ? rawNativeAudio : null;
        final imApi = ov['useImagesApi'];
        _useImagesApi = imApi is bool ? imApi : true;
        _useAspectRatioParam = (ov['useAspectRatioParam'] == true);
        // Built-in tools toggles
        final builtInSet = BuiltInToolNames.parseAndNormalize(
          ov['builtInTools'],
        );

        _googleUrlContextTool = builtInSet.contains(
          BuiltInToolNames.urlContext,
        );
        _googleCodeExecutionTool = builtInSet.contains(
          BuiltInToolNames.codeExecution,
        );
        _googleYoutubeTool = builtInSet.contains(BuiltInToolNames.youtube);

        _openaiCodeInterpreterTool = builtInSet.contains(
          BuiltInToolNames.codeInterpreter,
        );
        _openaiImageGenerationTool = builtInSet.contains(
          BuiltInToolNames.imageGeneration,
        );

        // Backward compatibility: legacy UI-only tools map (older versions)
        final rawTools = ov['tools'];
        final tools = rawTools is Map ? rawTools : const <dynamic, dynamic>{};
        _googleUrlContextTool =
            _googleUrlContextTool || ((tools['urlContext'] as bool?) ?? false);
      }
    }
    // Load a stored reasoning override, if any. With no stored entry the
    // model follows the built-in capability table.
    if (!widget.isNew) {
      final rawOv = cfg.modelOverrides[widget.modelId];
      if (rawOv is Map && rawOv['reasoning'] != null) {
        _reasoningOverride = ReasoningOverride.fromMap(rawOv['reasoning']);
      }
      if (rawOv is Map) {
        final wire = ReasoningWire.normalize(
          rawOv['reasoningWire']?.toString(),
        );
        _reasoningWire = wire == ReasoningWire.auto ? null : wire;
      }
    }
  }

  @override
  void dispose() {
    _baseDebounce?.cancel();
    _tabCtrl.dispose();
    _idCtrl.dispose();
    _nameCtrl.dispose();
    _contextWindowCtrl.dispose();
    _maxOutputCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      maxChildSize: 0.95,
      minChildSize: 0.4,
      builder: (c, scrollController) {
        return Column(
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: cs.onSurface.withOpacity(0.2),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            const SizedBox(height: 8),
            _buildHeader(context, l10n),
            _buildTabs(context, l10n),
            Expanded(
              child: ListView(
                controller: scrollController,
                padding: EdgeInsets.zero,
                children: [
                  ..._buildTabContent(context, l10n),
                  const SizedBox(height: 12),
                  SizedBox(height: MediaQuery.of(context).padding.bottom),
                ],
              ),
            ),
            _buildFooter(context, l10n),
          ],
        );
      },
    );
  }

  Widget _buildHeader(BuildContext context, AppLocalizations l10n) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 44,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            IosIconButton(
              icon: Lucide.X,
              size: 22,
              color: cs.onSurface,
              minSize: 36,
              onTap: () => Navigator.of(context).maybePop(false),
              semanticLabel: l10n.modelDetailSheetCancelButton,
            ),
            Expanded(
              child: Center(
                child: Text(
                  widget.isNew
                      ? l10n.modelDetailSheetAddModel
                      : l10n.modelDetailSheetEditModel,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            // Right spacer to balance title centering
            const SizedBox(width: 36),
          ],
        ),
      ),
    );
  }

  Widget _buildTabs(BuildContext context, AppLocalizations l10n) {
    // iOS segmented tabs like provider add sheet
    final tabs = <String>[
      l10n.modelDetailSheetBasicTab,
      l10n.modelDetailSheetAdvancedTab,
      if (_showBuiltinToolsTab) l10n.modelDetailSheetBuiltinToolsTab,
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: _SegTabBar(controller: _tabCtrl, tabs: tabs),
    );
  }

  List<Widget> _buildTabContent(BuildContext context, AppLocalizations l10n) {
    switch (_tab) {
      case _TabKind.basic:
        return _buildBasic(context, l10n);
      case _TabKind.advanced:
        return _buildAdvanced(context, l10n);
      case _TabKind.tools:
        return _buildTools(context, l10n);
    }
  }

  List<Widget> _buildBasic(BuildContext context, AppLocalizations l10n) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cs = Theme.of(context).colorScheme;
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _label(context, l10n.modelDetailSheetModelIdLabel),
            const SizedBox(height: 6),
            TextField(
              controller: _idCtrl,
              readOnly: !widget.isNew, // existing model ID is read-only
              enableInteractiveSelection: widget.isNew,
              style: TextStyle(
                color: widget.isNew ? null : cs.onSurface.withOpacity(0.6),
              ),
              onChanged: widget.isNew
                  ? (v) {
                      if (!_nameEdited) {
                        _nameCtrl.text = v;
                        setState(() {});
                      }
                      _scheduleBaseRefresh(v);
                    }
                  : null,
              decoration: InputDecoration(
                filled: true,
                fillColor: isDark ? Colors.white10 : Colors.white,
                hintText: l10n.modelDetailSheetModelIdHint,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(
                    color: Theme.of(
                      context,
                    ).colorScheme.outlineVariant.withOpacity(0.4),
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(
                    color: Theme.of(
                      context,
                    ).colorScheme.outlineVariant.withOpacity(0.4),
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(
                    color: Theme.of(
                      context,
                    ).colorScheme.primary.withOpacity(0.5),
                  ),
                ),
                suffixIconConstraints: const BoxConstraints(
                  minWidth: 46,
                  minHeight: 40,
                ),
                suffixIcon: widget.isNew
                    ? null
                    : Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: _CopySuffixButton(
                          onTap: () {
                            final text = _idCtrl.text.trim();
                            if (text.isEmpty) return;
                            Clipboard.setData(ClipboardData(text: text));
                            showAppSnackBar(
                              context,
                              message: l10n.shareProviderSheetCopiedMessage,
                              type: NotificationType.success,
                            );
                          },
                          tooltip: l10n.shareProviderSheetCopyButton,
                          icon: Lucide.Copy,
                          color: cs.onSurface.withOpacity(0.9),
                          hoverColor: cs.onSurface.withOpacity(0.08),
                          pressedColor: cs.onSurface.withOpacity(0.12),
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 12),
            _label(context, l10n.modelDetailSheetModelNameLabel),
            const SizedBox(height: 6),
            TextField(
              controller: _nameCtrl,
              onChanged: (_) {
                if (!_nameEdited) setState(() => _nameEdited = true);
              },
              decoration: InputDecoration(
                filled: true,
                fillColor: isDark ? Colors.white10 : Colors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(
                    color: Theme.of(
                      context,
                    ).colorScheme.outlineVariant.withOpacity(0.4),
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(
                    color: Theme.of(
                      context,
                    ).colorScheme.outlineVariant.withOpacity(0.4),
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(
                    color: Theme.of(
                      context,
                    ).colorScheme.primary.withOpacity(0.5),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            _SpecSectionHeader(
              label: l10n.modelDetailSheetModelTypeLabel,
              custom: _typeCustom,
              onReset: _resetType,
            ),
            const SizedBox(height: 6),
            _SegmentedSingle(
              options: [
                l10n.modelDetailSheetChatType,
                l10n.modelDetailSheetEmbeddingType,
              ],
              value: _type == ModelType.chat ? 0 : 1,
              onChanged: (i) => setState(() {
                _type = i == 0 ? ModelType.chat : ModelType.embedding;
                _typeTouched = true;
              }),
            ),
          ],
        ),
      ),
      if (_type == ModelType.chat)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SpecSectionHeader(
                label: l10n.modelDetailSheetInputModesLabel,
                custom: _inputCustom,
                onReset: _resetInput,
              ),
              const SizedBox(height: 6),
              _SegmentedMulti(
                options: [
                  for (final mod in Modality.values)
                    modalityLabel(l10n, mod),
                ],
                isSelected: [
                  for (final mod in Modality.values) _input.contains(mod),
                ],
                dense: true,
                onChanged: (idx) => setState(() {
                  _inputTouched = true;
                  final mod = Modality.values[idx];
                  if (_input.contains(mod)) {
                    _input.remove(mod);
                    if (_input.isEmpty) _input.add(Modality.text);
                  } else {
                    _input.add(mod);
                  }
                }),
              ),
              const SizedBox(height: 12),
              _SpecSectionHeader(
                label: l10n.modelDetailSheetOutputModesLabel,
                custom: _outputCustom,
                onReset: _resetOutput,
              ),
              const SizedBox(height: 6),
              _SegmentedMulti(
                options: [
                  modalityLabel(l10n, Modality.text),
                  modalityLabel(l10n, Modality.image),
                ],
                // Output stays text/image: no chat transport streams native
                // audio/video, and showing those would imply they do
                // (multimodal plan §2.1-5).
                isSelected: [
                  _output.contains(Modality.text),
                  _output.contains(Modality.image),
                ],
                onChanged: (idx) => setState(() {
                  _outputTouched = true;
                  final mod = idx == 0 ? Modality.text : Modality.image;
                  if (_output.contains(mod)) {
                    _output.remove(mod);
                    if (_output.isEmpty) _output.add(Modality.text);
                  } else {
                    _output.add(mod);
                  }
                }),
              ),
              const SizedBox(height: 12),
              _SpecSectionHeader(
                label: l10n.modelDetailSheetAbilitiesLabel,
                custom: _abilitiesCustom,
                onReset: _resetAbilities,
              ),
              const SizedBox(height: 6),
              _SegmentedMulti(
                options: [
                  l10n.modelDetailSheetToolsAbility,
                  l10n.modelDetailSheetReasoningAbility,
                ],
                isSelected: [
                  _abilities.contains(ModelAbility.tool),
                  _abilities.contains(ModelAbility.reasoning),
                ],
                allowEmpty: true,
                onChanged: (idx) => setState(() {
                  _abilitiesTouched = true;
                  final ab = idx == 0
                      ? ModelAbility.tool
                      : ModelAbility.reasoning;
                  if (_abilities.contains(ab)) {
                    _abilities.remove(ab);
                  } else {
                    _abilities.add(ab);
                  }
                }),
              ),
              const SizedBox(height: 12),
              // Token limits (Kelivo parity): prefilled with the inferred
              // catalog values, editable per model, persisted as
              // `contextWindow` / `maxOutput` overrides only when custom.
              _SpecSectionHeader(
                label: l10n.modelDetailSheetTokenLimitsLabel,
                custom: _limitsCustom,
                onReset: _resetLimits,
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('model-context-window-field'),
                      controller: _contextWindowCtrl,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: isDark ? Colors.white10 : Colors.white,
                        labelText: l10n.modelDetailSheetContextWindowLabel,
                        hintText: _base.contextWindow == null
                            ? l10n.modelDetailSheetTokenLimitsAuto
                            : formatTokenCount(_base.contextWindow!),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(
                            color: Theme.of(
                              context,
                            ).colorScheme.outlineVariant.withOpacity(0.4),
                          ),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(
                            color: Theme.of(
                              context,
                            ).colorScheme.outlineVariant.withOpacity(0.4),
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(
                            color: Theme.of(
                              context,
                            ).colorScheme.primary.withOpacity(0.5),
                          ),
                        ),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      key: const ValueKey('model-max-output-field'),
                      controller: _maxOutputCtrl,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: isDark ? Colors.white10 : Colors.white,
                        labelText: l10n.modelDetailSheetMaxOutputLabel,
                        hintText: _base.maxOutput == null
                            ? l10n.modelDetailSheetTokenLimitsAuto
                            : formatTokenCount(_base.maxOutput!),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(
                            color: Theme.of(
                              context,
                            ).colorScheme.outlineVariant.withOpacity(0.4),
                          ),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(
                            color: Theme.of(
                              context,
                            ).colorScheme.outlineVariant.withOpacity(0.4),
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(
                            color: Theme.of(
                              context,
                            ).colorScheme.primary.withOpacity(0.5),
                          ),
                        ),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
    ];
  }

  List<Widget> _buildAdvanced(BuildContext context, AppLocalizations l10n) {
    final cs = Theme.of(context).colorScheme;
    final showNativeInputs =
        _type == ModelType.chat &&
        (_input.contains(Modality.pdf) || _input.contains(Modality.audio));
    return [
      ..._buildReasoningOverrideSection(context, l10n),
      if (showNativeInputs) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
          child: Text(
            l10n.modelDetailSheetNativeInputLabel,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
          child: Text(
            l10n.modelDetailSheetNativeAdvancedDescription,
            style: TextStyle(
              color: cs.onSurface.withOpacity(0.65),
              fontSize: 12,
            ),
          ),
        ),
        if (_input.contains(Modality.pdf))
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: _ToolTile(
              title: l10n.modelDetailSheetNativePdfTool,
              desc: l10n.modelDetailSheetNativePdfToolDescription,
              value: _nativePdf ?? _nativePdfAuto,
              onChanged: (v) => setState(() => _nativePdf = v),
            ),
          ),
        if (_input.contains(Modality.audio))
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: _ToolTile(
              title: l10n.modelDetailSheetNativeAudioTool,
              desc: l10n.modelDetailSheetNativeAudioToolDescription,
              value: _nativeAudio ?? _nativeAudioAuto,
              onChanged: (v) => setState(() => _nativeAudio = v),
            ),
          ),
      ],
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        child: Text(
          l10n.modelDetailSheetCustomHeadersTitle,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Column(
          children: [
            for (int i = 0; i < _headers.length; i++)
              _HeaderRow(
                kv: _headers[i],
                onDelete: () => setState(() => _headers.removeAt(i)),
              ),
            const SizedBox(height: 8),
            _OutlinedAddButton(
              label: l10n.modelDetailSheetAddHeader,
              onTap: () => setState(() => _headers.add(_HeaderKV())),
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        child: Text(
          l10n.modelDetailSheetCustomBodyTitle,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Column(
          children: [
            for (int i = 0; i < _bodies.length; i++)
              _BodyRow(
                kv: _bodies[i],
                onDelete: () => setState(() => _bodies.removeAt(i)),
              ),
            const SizedBox(height: 8),
            _OutlinedAddButton(
              label: l10n.modelDetailSheetAddBody,
              onTap: () => setState(() => _bodies.add(_BodyKV())),
            ),
          ],
        ),
      ),
    ];
  }

  String _wireLabel(AppLocalizations l10n, String id) {
    switch (id) {
      case ReasoningWire.chatEffort:
        return l10n.modelDetailReasoningWireChatEffort;
      case ReasoningWire.chatReasoningEffortObj:
        return l10n.modelDetailReasoningWireChatReasoningEffortObj;
      case ReasoningWire.chatReasoningBudgetObj:
        return l10n.modelDetailReasoningWireChatReasoningBudgetObj;
      case ReasoningWire.chatThinkingBudget:
        return l10n.modelDetailReasoningWireChatThinkingBudget;
      case ReasoningWire.chatEnableThinking:
        return l10n.modelDetailReasoningWireChatEnableThinking;
      case ReasoningWire.chatThinkingMode:
        return l10n.modelDetailReasoningWireChatThinkingMode;
      case ReasoningWire.chatTemplateKwargs:
        return l10n.modelDetailReasoningWireChatTemplateKwargs;
      case ReasoningWire.chatNone:
      case ReasoningWire.responsesNone:
      case ReasoningWire.claudeNone:
      case ReasoningWire.geminiNone:
        return l10n.modelDetailReasoningWireNone;
      case ReasoningWire.responsesEffort:
        return l10n.modelDetailReasoningWireResponsesEffort;
      case ReasoningWire.claudeBudget:
        return l10n.modelDetailReasoningWireClaudeBudget;
      case ReasoningWire.claudeAdaptive:
        return l10n.modelDetailReasoningWireClaudeAdaptive;
      case ReasoningWire.claudeAdaptiveBetweenTools:
        return l10n.modelDetailReasoningWireClaudeAdaptiveBetweenTools;
      case ReasoningWire.geminiBudget:
        return l10n.modelDetailReasoningWireGeminiBudget;
      case ReasoningWire.geminiLevel:
        return l10n.modelDetailReasoningWireGeminiLevel;
      case ReasoningWire.auto:
      default:
        return l10n.modelDetailReasoningWireAuto;
    }
  }

  // Per-model reasoning-effort override UI (effort set, off-fallback,
  // always-thinking, sampling stripping, adaptive thinking, auto-detect).
  List<Widget> _buildReasoningOverrideSection(
    BuildContext context,
    AppLocalizations l10n,
  ) {
    final cs = Theme.of(context).colorScheme;
    final ovr = _reasoningOverride;
    final bool isOpenAiKind =
        _providerKind == ProviderKind.openai ||
        _providerKind == ProviderKind.neuralwatt;
    // A stored dialect can belong to another transport (e.g. the provider's
    // Responses toggle changed after the model was saved). DropdownButton
    // requires its value to be one of the rendered items, so fall back to
    // auto instead of asserting.
    final wireOptions = ReasoningWire.optionsFor(_wireTransport);
    final normalizedWire = ReasoningWire.normalize(_reasoningWire);
    final wireValue = wireOptions.contains(normalizedWire)
        ? normalizedWire
        : ReasoningWire.auto;

    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
        child: Text(
          l10n.modelDetailReasoningSectionTitle,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
        child: Text(
          l10n.modelDetailReasoningDescription,
          style: TextStyle(color: cs.onSurface.withOpacity(0.65), fontSize: 12),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
        child: _SegmentedSingle(
          options: [
            l10n.modelDetailReasoningModeInherited,
            l10n.modelDetailReasoningModeCustom,
          ],
          value: ovr == null ? 0 : 1,
          onChanged: (i) => setState(() {
            if (i == 0) {
              _reasoningOverride = null;
            } else {
              _reasoningOverride ??= const ReasoningOverride(
                hasEfforts: false,
                efforts: {},
                hasOffFallback: false,
                offFallback: null,
                hasSupportsXhigh: false,
                supportsXhigh: false,
                hasSupportsMax: false,
                supportsMax: false,
                hasThinkingAlwaysOn: false,
                thinkingAlwaysOn: false,
                hasSamplingRequiresNone: false,
                samplingRequiresNone: false,
                hasAdaptiveThinking: false,
                adaptiveThinking: false,
              );
            }
          }),
        ),
      ),
      // Reasoning parameter wire format (plan batch 2 §14). Shown whether or
      // not the capability override is custom: the two are independent.
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        child: Text(
          l10n.modelDetailReasoningWireLabel,
          style: TextStyle(fontSize: 13, color: cs.onSurface.withOpacity(0.8)),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: Theme.of(context).brightness == Brightness.dark
                ? Colors.white10
                : const Color(0xFFF2F3F5),
            border: Border.all(color: cs.outlineVariant.withOpacity(0.35)),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: wireValue,
              isExpanded: true,
              borderRadius: BorderRadius.circular(12),
              items: [
                for (final id in wireOptions)
                  DropdownMenuItem<String>(
                    value: id,
                    child: Text(
                      _wireLabel(l10n, id),
                      style: const TextStyle(fontSize: 14),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (value) => setState(() {
                final selected = ReasoningWire.normalize(value);
                _reasoningWire = selected == ReasoningWire.auto
                    ? null
                    : selected;
              }),
            ),
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
        child: Text(
          l10n.modelDetailReasoningWireDescription,
          style: TextStyle(color: cs.onSurface.withOpacity(0.6), fontSize: 12),
        ),
      ),
      if (ReasoningWire.isToggleOnly(wireValue))
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Text(
            l10n.modelDetailReasoningWireToggleOnlyNote,
            style: TextStyle(
              color: cs.onSurface.withOpacity(0.6),
              fontSize: 12,
            ),
          ),
        ),
      if (ovr != null) ...[
        if (isOpenAiKind) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: Text(
              l10n.modelDetailReasoningEffortsLabel,
              style: TextStyle(
                fontSize: 13,
                color: cs.onSurface.withOpacity(0.8),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: Column(
              children: [
                for (final effort in ReasoningOverride.allEfforts)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: _ToolTile(
                      title: effort,
                      desc: '',
                      value: ovr.efforts.contains(effort),
                      onChanged: (v) => setState(() {
                        final next = {...ovr.efforts};
                        if (v) {
                          next.add(effort);
                        } else {
                          next.remove(effort);
                        }
                        // Keep the xhigh/max display flags in lockstep with
                        // the effort set: the budget sheet / popover tiles
                        // are gated on these flags, not on the set itself.
                        _reasoningOverride = ovr.copyWith(
                          efforts: next,
                          supportsXhigh: next.contains('xhigh'),
                          supportsMax: next.contains('max'),
                        );
                      }),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: Text(
              l10n.modelDetailReasoningOffFallbackLabel,
              style: TextStyle(
                fontSize: 13,
                color: cs.onSurface.withOpacity(0.8),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: _SegmentedSingle(
              options: ReasoningOverride.allEfforts,
              value:
                  (ovr.hasOffFallback &&
                      ovr.offFallback != null &&
                      ReasoningOverride.allEfforts.contains(ovr.offFallback))
                  ? ReasoningOverride.allEfforts.indexOf(ovr.offFallback!)
                  : -1,
              onChanged: (i) => setState(() {
                if (i < 0 || i >= ReasoningOverride.allEfforts.length) {
                  _reasoningOverride = ovr.copyWith(clearOffFallback: true);
                } else {
                  _reasoningOverride = ovr.copyWith(
                    offFallback: ReasoningOverride.allEfforts[i],
                  );
                }
              }),
            ),
          ),
        ] else ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: _ToolTile(
              title: l10n.modelDetailReasoningAdaptive,
              desc: '',
              value: ovr.hasAdaptiveThinking && ovr.adaptiveThinking,
              onChanged: (v) => setState(() {
                _reasoningOverride = ovr.copyWith(adaptiveThinking: v);
              }),
            ),
          ),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: _ToolTile(
            title: l10n.modelDetailReasoningAlwaysThinking,
            desc: '',
            value: ovr.hasThinkingAlwaysOn && ovr.thinkingAlwaysOn,
            onChanged: (v) => setState(() {
              _reasoningOverride = ovr.copyWith(thinkingAlwaysOn: v);
            }),
          ),
        ),
        if (isOpenAiKind)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: _ToolTile(
              title: l10n.modelDetailReasoningStripSampling,
              desc: '',
              value: ovr.hasSamplingRequiresNone && ovr.samplingRequiresNone,
              onChanged: (v) => setState(() {
                _reasoningOverride = ovr.copyWith(samplingRequiresNone: v);
              }),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Row(
            children: [
              Expanded(
                child: _OutlinedAddButton(
                  label: l10n.modelDetailReasoningResetToBuiltin,
                  onTap: () => setState(() {
                    _reasoningOverride = null;
                    _reasoningWire = null;
                  }),
                ),
              ),
              if (isOpenAiKind) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: _OutlinedAddButton(
                    label: _reasoningProbing
                        ? l10n.modelDetailReasoningProbeRunning
                        : l10n.modelDetailReasoningProbeButton,
                    onTap: () {
                      if (!_reasoningProbing) _probeReasoningLevels();
                    },
                  ),
                ),
              ],
            ],
          ),
        ),
        if (_reasoningProbing && _reasoningProbeProgress.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: Text(
              _reasoningProbeProgress,
              style: TextStyle(
                fontSize: 12,
                color: cs.onSurface.withOpacity(0.6),
              ),
            ),
          ),
      ],
    ];
  }

  Future<void> _probeReasoningLevels() async {
    final l10n = AppLocalizations.of(context)!;
    final settings = context.read<SettingsProvider>();
    if (_providerKind != ProviderKind.openai &&
        _providerKind != ProviderKind.neuralwatt) {
      showAppSnackBar(
        context,
        message: l10n.modelDetailReasoningProbeUnsupportedTransport,
        type: NotificationType.error,
      );
      return;
    }
    setState(() {
      _reasoningProbing = true;
      _reasoningProbeProgress = '';
    });
    ReasoningProbeSummary? summary;
    try {
      final cfg = settings.getProviderConfig(widget.providerKey);
      summary = await ProviderManager.probeReasoning(
        cfg,
        widget.isNew ? _idCtrl.text.trim() : widget.modelId,
        onProgress: (effort, index, total) {
          if (!mounted) return;
          setState(() {
            _reasoningProbeProgress = '$effort ($index/$total)';
          });
        },
      );
    } on ReasoningProbeException {
      if (!mounted) return;
      setState(() => _reasoningProbing = false);
      showAppSnackBar(
        context,
        message: l10n.modelDetailReasoningProbeFailed,
        type: NotificationType.error,
      );
      return;
    } catch (_) {
      if (!mounted) return;
      setState(() => _reasoningProbing = false);
      showAppSnackBar(
        context,
        message: l10n.modelDetailReasoningProbeFailed,
        type: NotificationType.error,
      );
      return;
    }
    if (!mounted) return;
    setState(() => _reasoningProbing = false);
    if (summary.cancelled) {
      showAppSnackBar(
        context,
        message: l10n.modelDetailReasoningProbeCancelled,
      );
      return;
    }
    await _showReasoningProbeResult(summary);
  }

  Future<void> _showReasoningProbeResult(ReasoningProbeSummary summary) async {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    Color statusColor(String effort) {
      switch (summary.statusFor(effort)) {
        case ReasoningProbeStatus.supported:
          return Colors.green.shade400;
        case ReasoningProbeStatus.unsupported:
          return cs.error;
        case ReasoningProbeStatus.unknown:
          return cs.onSurface.withOpacity(0.5);
      }
    }

    String statusLabel(String effort) {
      switch (summary.statusFor(effort)) {
        case ReasoningProbeStatus.supported:
          return '✓';
        case ReasoningProbeStatus.unsupported:
          return '✗';
        case ReasoningProbeStatus.unknown:
          return '?';
      }
    }

    final apply = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.modelDetailReasoningProbeResultTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final effort in ReasoningOverride.allEfforts)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Text(
                      statusLabel(effort),
                      style: TextStyle(
                        color: statusColor(effort),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(effort),
                  ],
                ),
              ),
            if (summary.suggestedOffFallback != null) ...[
              const SizedBox(height: 8),
              Text(
                '${l10n.modelDetailReasoningOffFallbackLabel}: ${summary.suggestedOffFallback}',
                style: TextStyle(
                  fontSize: 12,
                  color: cs.onSurface.withOpacity(0.7),
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.modelDetailReasoningProbeKeepCurrent),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.modelDetailReasoningProbeApply),
          ),
        ],
      ),
    );
    if (apply != true) return;
    if (!mounted) return;
    final overrideMap = summary.toOverrideMap();
    if (overrideMap == null) {
      // Nothing conclusive was probed (e.g. every step timed out or was
      // rate-limited); keep the user's current settings untouched.
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: l10n.modelDetailReasoningProbeFailed,
        type: NotificationType.error,
      );
      return;
    }
    setState(() {
      // Merge probe results with the current override: fields the probe
      // cannot measure (samplingRequiresNone, adaptiveThinking and a manual
      // offFallback) survive; probe-measured fields are replaced.
      final current = _reasoningOverride;
      final probed = ReasoningOverride.fromMap(overrideMap)!;
      _reasoningOverride = ReasoningOverride(
        hasEfforts: probed.hasEfforts,
        efforts: probed.efforts,
        hasOffFallback: probed.hasOffFallback,
        offFallback: probed.offFallback,
        hasSupportsXhigh: probed.hasSupportsXhigh,
        supportsXhigh: probed.supportsXhigh,
        hasSupportsMax: probed.hasSupportsMax,
        supportsMax: probed.supportsMax,
        hasThinkingAlwaysOn: probed.hasThinkingAlwaysOn,
        thinkingAlwaysOn: probed.thinkingAlwaysOn,
        hasSamplingRequiresNone: current?.hasSamplingRequiresNone ?? false,
        samplingRequiresNone: current?.samplingRequiresNone ?? false,
        hasAdaptiveThinking: current?.hasAdaptiveThinking ?? false,
        adaptiveThinking: current?.adaptiveThinking ?? false,
      );
    });
  }

  List<Widget> _buildTools(BuildContext context, AppLocalizations l10n) {
    final cs = Theme.of(context).colorScheme;
    final settings = context.watch<SettingsProvider>();
    final cfg = settings.getProviderConfig(widget.providerKey);
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: Text(
          l10n.modelDetailSheetBuiltinToolsDescription,
          style: TextStyle(color: cs.onSurface.withOpacity(0.8), fontSize: 13),
        ),
      ),
      if (_providerKind == ProviderKind.google) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Text(
            l10n.modelDetailSheetGeminiCodeExecutionMutuallyExclusiveHint,
            style: TextStyle(
              color: cs.onSurface.withOpacity(0.65),
              fontSize: 12,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: _ToolTile(
            title: l10n.modelDetailSheetUrlContextTool,
            desc: l10n.modelDetailSheetUrlContextToolDescription,
            value: _googleUrlContextTool,
            // URL Context is disabled when Code Execution is enabled (mutually exclusive)
            onChanged: _googleCodeExecutionTool
                ? null
                : (v) => setState(() => _googleUrlContextTool = v),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: _ToolTile(
            title: l10n.modelDetailSheetCodeExecutionTool,
            desc: l10n.modelDetailSheetCodeExecutionToolDescription,
            value: _googleCodeExecutionTool,
            // Code Execution is disabled when URL Context is enabled (mutually exclusive)
            onChanged: _googleUrlContextTool
                ? null
                : (v) => setState(() => _googleCodeExecutionTool = v),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: _ToolTile(
            title: l10n.modelDetailSheetYoutubeTool,
            desc: l10n.modelDetailSheetYoutubeToolDescription,
            value: _googleYoutubeTool,
            onChanged: (v) => setState(() => _googleYoutubeTool = v),
          ),
        ),
      ] else if (_providerKind == ProviderKind.openai ||
          _providerKind == ProviderKind.neuralwatt) ...[
        if (_output.contains(Modality.image))
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: _ToolTile(
              title: l10n.modelDetailSheetUseImagesApiTool,
              desc: l10n.modelDetailSheetUseImagesApiToolDescription,
              value: _useImagesApi,
              onChanged: (v) => setState(() => _useImagesApi = v),
            ),
          ),
        if (_output.contains(Modality.image))
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: _ToolTile(
              title: l10n.modelDetailSheetUseAspectRatioParamTool,
              desc: l10n.modelDetailSheetUseAspectRatioParamToolDescription,
              value: _useAspectRatioParam,
              onChanged: (v) => setState(() => _useAspectRatioParam = v),
            ),
          ),
        if (cfg.useResponseApi != true)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text(
              l10n.modelDetailSheetOpenaiBuiltinToolsResponsesOnlyHint,
              style: TextStyle(
                color: cs.onSurface.withOpacity(0.65),
                fontSize: 12,
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: _ToolTile(
            title: l10n.modelDetailSheetOpenaiCodeInterpreterTool,
            desc: l10n.modelDetailSheetOpenaiCodeInterpreterToolDescription,
            value: _openaiCodeInterpreterTool,
            onChanged: (cfg.useResponseApi == true)
                ? (v) => setState(() => _openaiCodeInterpreterTool = v)
                : null,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: _ToolTile(
            title: l10n.modelDetailSheetOpenaiImageGenerationTool,
            desc: l10n.modelDetailSheetOpenaiImageGenerationToolDescription,
            value: _openaiImageGenerationTool,
            onChanged: (cfg.useResponseApi == true)
                ? (v) => setState(() => _openaiImageGenerationTool = v)
                : null,
          ),
        ),
      ] else
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: Text(
            l10n.modelDetailSheetBuiltinToolsUnsupportedHint,
            style: TextStyle(
              color: cs.onSurface.withOpacity(0.65),
              fontSize: 12,
            ),
          ),
        ),
    ];
  }

  Widget _buildFooter(BuildContext context, AppLocalizations l10n) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        8,
        16,
        10 + MediaQuery.of(context).padding.bottom,
      ),
      child: SizedBox(
        width: double.infinity,
        child: IosTileButton(
          icon: widget.isNew ? Lucide.Plus : Lucide.Check,
          label: widget.isNew
              ? l10n.modelDetailSheetAddButton
              : l10n.modelDetailSheetConfirmButton,
          backgroundColor: cs.primary,
          onTap: _save,
        ),
      ),
    );
  }

  Widget _label(BuildContext context, String text) => Text(
    text,
    style: TextStyle(
      fontSize: 13,
      color: Theme.of(context).colorScheme.onSurface.withOpacity(0.8),
    ),
  );

  // ===== 預設 / 自訂 source state ==========================================
  //
  // A section counts as 自訂 when its live state differs from the freshly
  // inferred [_base]. Legacy overrides that merely re-stored the inferred
  // values therefore read (and save) as 預設 again — the diff, not the mere
  // presence of an override key, is the source of truth.

  bool get _typeCustom => _type != _base.type;

  bool get _inputCustom => !_modalitySetEquals(_input, _base.input);

  bool get _outputCustom => !_modalitySetEquals(_output, _base.output);

  bool get _abilitiesCustom => !_abilitySetEquals(_abilities, _base.abilities);

  // Zero is not a meaningful token limit: treat it like an empty field
  // (follow the default) so it can never be persisted as a dead override.
  int? get _parsedContextWindow {
    final value = int.tryParse(_contextWindowCtrl.text.trim());
    return value != null && value > 0 ? value : null;
  }

  int? get _parsedMaxOutput {
    final value = int.tryParse(_maxOutputCtrl.text.trim());
    return value != null && value > 0 ? value : null;
  }

  /// Token limits count as 自訂 only when a field carries a value that
  /// differs from the inferred default; an empty field means "follow the
  /// default" (the override key is simply not written).
  bool get _limitsCustom =>
      (_parsedContextWindow != null &&
          _parsedContextWindow != _base.contextWindow) ||
      (_parsedMaxOutput != null && _parsedMaxOutput != _base.maxOutput);

  void _resetType() => setState(() {
    _type = _base.type;
    _typeTouched = false;
  });

  void _resetInput() => setState(() {
    _input
      ..clear()
      ..addAll(_base.input);
    _inputTouched = false;
  });

  void _resetOutput() => setState(() {
    _output
      ..clear()
      ..addAll(_base.output);
    _outputTouched = false;
  });

  void _resetAbilities() => setState(() {
    _abilities
      ..clear()
      ..addAll(_base.abilities);
    _abilitiesTouched = false;
  });

  void _resetLimits() => setState(() {
    _contextWindowCtrl.text = _base.contextWindow?.toString() ?? '';
    _maxOutputCtrl.text = _base.maxOutput?.toString() ?? '';
  });

  /// Create-flow only: re-infer the defaults shortly after the user types an
  /// id (typing every keystroke would run the catalog lookup needlessly).
  void _scheduleBaseRefresh(String id) {
    _baseDebounce?.cancel();
    _baseDebounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      _applyBase(_inferBase(id));
    });
  }

  ModelInfo _inferBase(String id) {
    final trimmed = id.trim();
    return ModelRegistry.infer(
      ModelInfo(
        id: trimmed.isEmpty ? 'custom' : trimmed,
        displayName: trimmed,
      ),
    );
  }

  /// Replace [_base] and adopt the new defaults for sections the user has not
  /// touched. Token-limit fields are left alone: an empty field already means
  /// "follow the default", and hint text reads from [_base] directly.
  void _applyBase(ModelInfo next) {
    setState(() {
      _base = next;
      if (!_typeTouched) _type = next.type;
      if (!_inputTouched) {
        _input
          ..clear()
          ..addAll(next.input);
      }
      if (!_outputTouched) {
        _output
          ..clear()
          ..addAll(next.output);
      }
      if (!_abilitiesTouched) {
        _abilities
          ..clear()
          ..addAll(next.abilities);
      }
    });
  }

  /// Effective base values of the sheet's spec sections in stored (override
  /// map) format. Used by `_syncOwnedFieldsChanged`: a key missing from the
  /// saved map means "matches the inferred default", not "removed".
  Map<String, dynamic> _baseSpecSnapshot() => <String, dynamic>{
    'type': _base.type == ModelType.chat ? 'chat' : 'embedding',
    'input': _base.input.map(ModelRegistry.modalityToCatalogValue).toList(),
    'output': _base.output.map(ModelRegistry.modalityToCatalogValue).toList(),
    'abilities': _base.abilities
        .map((e) => e == ModelAbility.reasoning ? 'reasoning' : 'tool')
        .toList(),
  };

  // Generate a unique logical key for a model instance within a provider.
  // This allows multiple configurations to share the same upstream API model id.
  String _nextModelKey(ProviderConfig cfg, String apiModelId) {
    final existing = <String>{...cfg.models, ...cfg.modelOverrides.keys};
    if (!existing.contains(apiModelId)) return apiModelId;
    int i = 2;
    while (true) {
      final candidate = '$apiModelId#$i';
      if (!existing.contains(candidate)) return candidate;
      i++;
    }
  }

  Future<void> _save() async {
    final settings = context.read<SettingsProvider>();
    final old = settings.getProviderConfig(widget.providerKey);
    // Logical key used inside configs (stable across edits)
    final String prevKey = widget.modelId;
    // Upstream/vendor model id typed by the user
    final String apiModelId = _idCtrl.text.trim();
    // Basic validation
    if (apiModelId.isEmpty || apiModelId.length < 2) {
      final l10n = AppLocalizations.of(context)!;
      showAppSnackBar(
        context,
        message: l10n.modelDetailSheetInvalidIdError,
        type: NotificationType.error,
      );
      return;
    }

    if (widget.isNew) {
      // The create flow types the id after the sheet opens; make sure the
      // custom/default comparison uses the final id even when the debounce
      // has not fired yet. Untouched sections adopt the final defaults.
      _base = _inferBase(apiModelId);
      if (!_typeTouched) _type = _base.type;
      if (!_inputTouched) {
        _input
          ..clear()
          ..addAll(_base.input);
      }
      if (!_outputTouched) {
        _output
          ..clear()
          ..addAll(_base.output);
      }
      if (!_abilitiesTouched) {
        _abilities
          ..clear()
          ..addAll(_base.abilities);
      }
    }

    final ov = Map<String, dynamic>.from(old.modelOverrides);
    final headers = [
      for (final h in _headers)
        if (h.name.text.trim().isNotEmpty)
          {'name': h.name.text.trim(), 'value': h.value.text},
    ];
    final bodies = [
      for (final b in _bodies)
        if (b.keyCtrl.text.trim().isNotEmpty)
          {'key': b.keyCtrl.text.trim(), 'value': b.valueCtrl.text},
    ];
    final prev = (prevKey.isNotEmpty && ov[prevKey] is Map)
        ? (ov[prevKey] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final oauthProtocol = prev['oauthProtocol'];
    final source = prev['source'];
    final oauthAccountId = prev['oauthAccountId'];
    final reasoningSynced = prev['reasoningSynced'];
    final builtInSet = BuiltInToolNames.parseAndNormalize(prev['builtInTools']);
    if (_providerKind == ProviderKind.google) {
      builtInSet.remove(BuiltInToolNames.urlContext);
      builtInSet.remove(BuiltInToolNames.codeExecution);
      builtInSet.remove(BuiltInToolNames.youtube);
      if (_googleUrlContextTool) builtInSet.add(BuiltInToolNames.urlContext);
      if (_googleCodeExecutionTool)
        builtInSet.add(BuiltInToolNames.codeExecution);
      if (_googleYoutubeTool) builtInSet.add(BuiltInToolNames.youtube);
    } else if (_providerKind == ProviderKind.openai ||
        _providerKind == ProviderKind.neuralwatt) {
      builtInSet.remove(BuiltInToolNames.codeInterpreter);
      builtInSet.remove(BuiltInToolNames.imageGeneration);
      if (_openaiCodeInterpreterTool)
        builtInSet.add(BuiltInToolNames.codeInterpreter);
      if (_openaiImageGenerationTool)
        builtInSet.add(BuiltInToolNames.imageGeneration);
    }
    // Carry the reasoning override across saves. Stored data is loaded into
    // _reasoningOverride at init, so null here means either "never had one"
    // or "the user explicitly reset to built-in" — both correctly drop the
    // key. Writing prev through unconditionally would both resurrect reset
    // data and let the stale map literal key overwrite the user's edits.
    final builtInTools = BuiltInToolNames.orderedForStorage(builtInSet);
    // Decide which logical key to use for this instance
    final String key = (prevKey.isEmpty || widget.isNew)
        ? _nextModelKey(old, apiModelId)
        : prevKey;
    // Kelivo parity: a section's key is written only when it is 自訂 —
    // i.e. its live state differs from the freshly inferred `_base`. Legacy
    // overrides that re-stored the inferred values are dropped here
    // (auto-clean), and the freshly inferred defaults keep applying.
    final int? savedContextWindow = _type == ModelType.chat
        ? _parsedContextWindow
        : null;
    final int? savedMaxOutput = _type == ModelType.chat
        ? _parsedMaxOutput
        : null;
    final next = <String, dynamic>{
      'apiModelId': apiModelId,
      'name': _nameCtrl.text.trim(),
      if (_typeCustom) 'type': _type == ModelType.chat ? 'chat' : 'embedding',
      if (_inputCustom)
        'input': _input.map(ModelRegistry.modalityToCatalogValue).toList(),
      // Marks the list as post-multimodal so an explicit removal of
      // audio/pdf/video is respected instead of being re-merged on load.
      // Always written together with `input` — the version belongs to it.
      if (_inputCustom) 'inputV': ModelRegistry.inputOverrideVersion,
      if (_outputCustom)
        'output': _output.map(ModelRegistry.modalityToCatalogValue).toList(),
      if (_abilitiesCustom)
        'abilities': _abilities
            .map((e) => e == ModelAbility.reasoning ? 'reasoning' : 'tool')
            .toList(),
      if (savedContextWindow != null &&
          savedContextWindow != _base.contextWindow)
        'contextWindow': savedContextWindow,
      if (savedMaxOutput != null && savedMaxOutput != _base.maxOutput)
        'maxOutput': savedMaxOutput,
      // Only persist an override while the matching modality is enabled;
      // otherwise the value becomes invisible in Advanced and can resurrect
      // later when the modality is re-added.
      if (_input.contains(Modality.pdf) && _nativePdf != null)
        'nativePdf': _nativePdf,
      if (_input.contains(Modality.audio) && _nativeAudio != null)
        'nativeAudio': _nativeAudio,
      'headers': headers,
      'body': bodies,
      if (oauthProtocol is String && oauthProtocol.trim().isNotEmpty)
        'oauthProtocol': oauthProtocol.trim(),
      if (source is String && source.trim().isNotEmpty) 'source': source.trim(),
      if (oauthAccountId is String && oauthAccountId.trim().isNotEmpty)
        'oauthAccountId': oauthAccountId.trim(),
      if (reasoningSynced is Map)
        'reasoningSynced': Map<String, dynamic>.from(reasoningSynced),
      if (!_useImagesApi) 'useImagesApi': false,
      'useAspectRatioParam': _useAspectRatioParam,
      // Read-modify-write: these maps are edited on the search settings sheet,
      // not here, so a model-detail save must carry them through untouched.
      if (prev['webSearch'] is Map)
        'webSearch': Map<String, dynamic>.from(prev['webSearch'] as Map),
      if (prev['webFetch'] is Map)
        'webFetch': Map<String, dynamic>.from(prev['webFetch'] as Map),
      if (builtInTools.isNotEmpty) 'builtInTools': builtInTools,
      if (_reasoningOverride != null) 'reasoning': _reasoningOverride!.toMap(),
      if (_reasoningWire != null &&
          _reasoningWire != ReasoningWire.auto &&
          (_reasoningWire == prev['reasoningWire'] ||
              ReasoningWire.optionsFor(
                _wireTransport,
              ).contains(_reasoningWire)))
        'reasoningWire': _reasoningWire,
    };
    // Only a change to a provider-owned field makes the model user-owned.
    // A no-op save (or a reasoning-only edit) must keep the OAuth sync link.
    // Keys absent from `next` now mean "matches the inferred default" — the
    // comparison falls back to the base snapshot instead of null.
    if (source == 'oauth-synced' &&
        _syncOwnedFieldsChanged(prev, next, _baseSpecSnapshot())) {
      next['source'] = 'user';
    }
    ov[key] = next;

    // Apply updates to provider config
    if (prevKey.isEmpty || widget.isNew) {
      // Creating a new model
      final list = old.models.toList()..add(key);
      final disabled = Set<String>.of(old.disabledModels)..remove(key);
      await settings.setProviderConfig(
        widget.providerKey,
        old.copyWith(
          modelOverrides: ov,
          models: list,
          disabledModels: disabled,
        ),
      );
      // models.dev catalog trigger (plan batch 1 §6.3): unknown ids fetch once,
      // known ids return without a request.
      try {
        ProviderManager.refreshCatalogForModel(
          settings.getProviderConfig(widget.providerKey),
          apiModelId,
        );
      } catch (_) {}
    } else {
      // Existing model instance; keep logical key stable and just persist overrides
      await settings.setProviderConfig(
        widget.providerKey,
        old.copyWith(modelOverrides: ov),
      );
    }
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }
}

bool _syncOwnedFieldsChanged(
  Map<String, dynamic> prev,
  Map<String, dynamic> next,
  Map<String, dynamic> base,
) {
  for (final key in const <String>[
    'name',
    'type',
    'input',
    'output',
    'abilities',
    'oauthProtocol',
  ]) {
    if (!prev.containsKey(key)) continue;
    final effective = next.containsKey(key) ? next[key] : base[key];
    if (!_modelValueEquals(prev[key], effective)) return true;
  }
  return false;
}

bool _modelValueEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_modelValueEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

/// Order-insensitive equality for the sheet's modality / ability state vs.
/// the inferred base lists. The stored override keeps its own order; only a
/// real difference in membership (or count) counts as 自訂.
bool _modalitySetEquals(Set<Modality> a, List<Modality> b) =>
    a.length == b.length && a.containsAll(b);

bool _abilitySetEquals(Set<ModelAbility> a, List<ModelAbility> b) =>
    a.length == b.length && a.containsAll(b);

/// Section header for the basic tab's spec sections: label on the left, then
/// a right-aligned 預設 / 自訂 source capsule, and — when the section is 自訂 —
/// a reset-to-default icon at the far right (Kelivo's SpecFieldHeader, adapted
/// to OmniChat's label styling).
class _SpecSectionHeader extends StatelessWidget {
  const _SpecSectionHeader({
    required this.label,
    required this.custom,
    this.onReset,
  });

  final String label;
  final bool custom;
  final VoidCallback? onReset;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final capsuleColor = custom ? cs.primary : cs.onSurface;
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              color: cs.onSurface.withOpacity(0.8),
            ),
          ),
        ),
        Container(
          key: const ValueKey('spec-source-capsule'),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
          decoration: BoxDecoration(
            color: capsuleColor.withOpacity(0.10),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: capsuleColor.withOpacity(0.22),
              width: 0.5,
            ),
          ),
          child: Text(
            custom
                ? l10n.modelDetailSheetSourceCustom
                : l10n.modelDetailSheetSourceDefault,
            style: TextStyle(
              fontSize: 10.5,
              height: 1.4,
              color: capsuleColor.withOpacity(0.85),
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        if (custom && onReset != null)
          InkWell(
            onTap: onReset,
            borderRadius: BorderRadius.circular(999),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(
                Lucide.RotateCcw,
                size: 14,
                color: cs.onSurface.withOpacity(0.55),
              ),
            ),
          ),
      ],
    );
  }
}

class _SegmentedSingle extends StatelessWidget {
  const _SegmentedSingle({
    required this.options,
    required this.value,
    required this.onChanged,
  });
  final List<String> options;
  final int value; // index; -1 = nothing selected
  final ValueChanged<int> onChanged;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final Color sel = isDark
        ? cs.primary.withOpacity(0.20)
        : cs.primary.withOpacity(0.14);
    Widget chip(int i) => InkWell(
      onTap: () => onChanged(i),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: i == value ? sel : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (i == value)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Icon(Lucide.Check, size: 16, color: cs.primary),
              ),
            Text(
              options[i],
              style: TextStyle(
                color: cs.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
    // Long ladders (e.g. the 7-value off-fallback selector) scroll
    // horizontally instead of squeezing into equal-width cells.
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: isDark ? Colors.white10 : const Color(0xFFF2F3F5),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant.withOpacity(0.35),
        ),
      ),
      child: options.length > 3
          ? SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [for (int i = 0; i < options.length; i++) chip(i)],
              ),
            )
          : Row(
              children: [
                for (int i = 0; i < options.length; i++)
                  Expanded(child: chip(i)),
              ],
            ),
    );
  }
}

class _SegmentedMulti extends StatelessWidget {
  const _SegmentedMulti({
    required this.options,
    required this.isSelected,
    required this.onChanged,
    this.allowEmpty = false,
    this.dense = false,
  });

  final List<String> options;
  final List<bool> isSelected;
  final ValueChanged<int> onChanged;
  final bool allowEmpty;

  /// Five input modalities need tighter cells than the two-option groups.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    assert(options.length == isSelected.length);
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bool allSelected =
        isSelected.isNotEmpty && isSelected.every((e) => e);
    final int selectedCount = isSelected.where((e) => e).length;

    final base = isDark ? Colors.white10 : const Color(0xFFF2F3F5);
    final sel = isDark
        ? cs.primary.withOpacity(0.20)
        : cs.primary.withOpacity(0.14);
    final r = BorderRadius.circular(12);

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: r,
        color: base, // 外层始终用同一个“底色”
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant.withOpacity(0.35),
        ),
      ),
      child: ClipRRect(
        // 确保内部遮罩遵守圆角
        borderRadius: r,
        child: Stack(
          children: [
            // 全选时：在“同一个底色”上叠加一层 sel（与单选的叠加路径一致）
            if (allSelected)
              Positioned.fill(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  decoration: BoxDecoration(color: sel, borderRadius: r),
                ),
              ),
            Row(
              children: [
                for (int i = 0; i < options.length; i++)
                  Expanded(
                    child: InkWell(
                      splashColor: Colors.transparent,
                      highlightColor: Colors.transparent,
                      onTap: () => onChanged(i),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        padding: EdgeInsets.symmetric(
                          horizontal: dense ? 4.0 : 12.0,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          // 全选时子项透明，让上面的整条遮罩生效；
                          // 非全选时按原逻辑逐项着色
                          color: allSelected
                              ? Colors.transparent
                              : (isSelected[i] ? sel : Colors.transparent),
                          borderRadius: selectedCount == 1 && isSelected[i]
                              ? r
                              : i == 0
                              ? const BorderRadius.only(
                                  topLeft: Radius.circular(12),
                                  bottomLeft: Radius.circular(12),
                                )
                              : (i == options.length - 1
                                    ? const BorderRadius.only(
                                        topRight: Radius.circular(12),
                                        bottomRight: Radius.circular(12),
                                      )
                                    : BorderRadius.zero),
                        ),
                        child: SizedBox(
                          width: double.infinity,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              Padding(
                                padding: EdgeInsets.symmetric(
                                  horizontal: dense ? 10.0 : 12.0,
                                ),
                                child: Text(
                                  options[i],
                                  maxLines: 1,
                                  softWrap: false,
                                  overflow: TextOverflow.fade,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: cs.onSurface,
                                    fontWeight: FontWeight.w600,
                                    fontSize: dense ? 12.5 : null,
                                  ),
                                ),
                              ),
                              if (isSelected[i])
                                Positioned(
                                  left: dense ? 0.0 : 6.0,
                                  child: Icon(
                                    Lucide.Check,
                                    size: dense ? 10.0 : 16.0,
                                    color: cs.primary,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _HeaderKV {
  final TextEditingController name = TextEditingController();
  final TextEditingController value = TextEditingController();
}

class _BodyKV {
  final TextEditingController keyCtrl = TextEditingController();
  final TextEditingController valueCtrl = TextEditingController();
}

class _HeaderRow extends StatelessWidget {
  const _HeaderRow({required this.kv, required this.onDelete});
  final _HeaderKV kv;
  final VoidCallback onDelete;
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: kv.name,
                  decoration: InputDecoration(
                    hintText: l10n.modelDetailSheetHeaderKeyHint,
                    filled: true,
                    fillColor: isDark ? Colors.white10 : Colors.white,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(
                        color: cs.outlineVariant.withOpacity(0.4),
                      ),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(
                        color: cs.outlineVariant.withOpacity(0.4),
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(
                        color: cs.primary.withOpacity(0.5),
                      ),
                    ),
                  ),
                ),
              ),
              IosIconButton(
                icon: Lucide.Trash2,
                size: 20,
                color: cs.onSurface.withOpacity(0.8),
                onTap: onDelete,
                semanticLabel: 'Delete header',
                minSize: 40,
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: kv.value,
            decoration: InputDecoration(
              hintText: l10n.modelDetailSheetHeaderValueHint,
              filled: true,
              fillColor: isDark ? Colors.white10 : Colors.white,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(
                  color: cs.outlineVariant.withOpacity(0.4),
                ),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(
                  color: cs.outlineVariant.withOpacity(0.4),
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(
                  color: Theme.of(context).colorScheme.primary.withOpacity(0.5),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BodyRow extends StatelessWidget {
  const _BodyRow({required this.kv, required this.onDelete});
  final _BodyKV kv;
  final VoidCallback onDelete;
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: kv.keyCtrl,
                  decoration: InputDecoration(
                    hintText: l10n.modelDetailSheetBodyKeyHint,
                    filled: true,
                    fillColor: isDark ? Colors.white10 : Colors.white,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(
                        color: Theme.of(
                          context,
                        ).colorScheme.outlineVariant.withOpacity(0.4),
                      ),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(
                        color: Theme.of(
                          context,
                        ).colorScheme.outlineVariant.withOpacity(0.4),
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(
                        color: Theme.of(
                          context,
                        ).colorScheme.primary.withOpacity(0.5),
                      ),
                    ),
                  ),
                ),
              ),
              IosIconButton(
                icon: Lucide.Trash2,
                size: 20,
                color: cs.onSurface.withOpacity(0.8),
                onTap: onDelete,
                semanticLabel: 'Delete entry',
                minSize: 40,
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: kv.valueCtrl,
            minLines: 3,
            maxLines: 6,
            decoration: InputDecoration(
              hintText: l10n.modelDetailSheetBodyJsonHint,
              filled: true,
              fillColor: isDark ? Colors.white10 : Colors.white,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(
                  color: Theme.of(
                    context,
                  ).colorScheme.outlineVariant.withOpacity(0.4),
                ),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(
                  color: Theme.of(
                    context,
                  ).colorScheme.outlineVariant.withOpacity(0.4),
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(
                  color: Theme.of(context).colorScheme.primary.withOpacity(0.5),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ToolTile extends StatelessWidget {
  const _ToolTile({
    required this.title,
    required this.desc,
    required this.value,
    required this.onChanged,
  });
  final String title;
  final String desc;
  final bool value;
  final ValueChanged<bool>? onChanged;
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cs = Theme.of(context).colorScheme;
    final bool isDisabled = onChanged == null;
    return Opacity(
      opacity: isDisabled ? 0.45 : 1.0,
      child: Material(
        color: isDark ? Colors.white10 : const Color(0xFFF2F3F5),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      desc,
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurface.withOpacity(0.7),
                      ),
                    ),
                  ],
                ),
              ),
              IosSwitch(value: value, onChanged: onChanged),
            ],
          ),
        ),
      ),
    );
  }
}

class _OutlinedAddButton extends StatelessWidget {
  const _OutlinedAddButton({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final border = BorderSide(color: cs.primary.withOpacity(0.5));
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border.fromBorderSide(border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Lucide.Plus, size: 18, color: cs.primary),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(color: cs.primary)),
          ],
        ),
      ),
    );
  }
}

class _CopySuffixButton extends StatefulWidget {
  const _CopySuffixButton({
    required this.onTap,
    required this.tooltip,
    required this.icon,
    required this.color,
    required this.hoverColor,
    required this.pressedColor,
  });
  final VoidCallback onTap;
  final String tooltip;
  final IconData icon;
  final Color color;
  final Color hoverColor;
  final Color pressedColor;

  @override
  State<_CopySuffixButton> createState() => _CopySuffixButtonState();
}

class _CopySuffixButtonState extends State<_CopySuffixButton> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final bg = _pressed
        ? widget.pressedColor
        : (_hover ? widget.hoverColor : Colors.transparent);
    final icon = Icon(widget.icon, size: 18, color: widget.color);

    Widget child = AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: icon,
    );

    child = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: child,
      ),
    );

    return Tooltip(message: widget.tooltip, child: child);
  }
}

// Segmented tab bar matching provider add sheet style
class _SegTabBar extends StatelessWidget {
  const _SegTabBar({required this.controller, required this.tabs});
  final TabController controller;
  final List<String> tabs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    const double outerHeight = 44;
    const double innerPadding = 4;
    const double gap = 6;
    const double minSegWidth = 88;
    final double pillRadius = 18;
    final double innerRadius = ((pillRadius - innerPadding).clamp(
      0.0,
      pillRadius,
    )).toDouble();

    return LayoutBuilder(
      builder: (context, constraints) {
        final double availWidth = constraints.maxWidth;
        final double innerAvailWidth = availWidth - innerPadding * 2;
        final double segWidth =
            (innerAvailWidth - gap * (tabs.length - 1)) / tabs.length;
        final double rowWidth =
            segWidth * tabs.length + gap * (tabs.length - 1);

        final Color shellBg = isDark
            ? Colors.white.withOpacity(0.08)
            : Colors.white;

        List<Widget> children = [];
        for (int index = 0; index < tabs.length; index++) {
          final bool selected = controller.index == index;
          children.add(
            SizedBox(
              width: segWidth < minSegWidth ? minSegWidth : segWidth,
              height: double.infinity,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => controller.index = index,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOutCubic,
                  decoration: BoxDecoration(
                    color: selected
                        ? cs.primary.withOpacity(0.14)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(innerRadius),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    tabs[index],
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected
                          ? cs.primary
                          : cs.onSurface.withOpacity(0.82),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          );
          if (index != tabs.length - 1)
            children.add(const SizedBox(width: gap));
        }

        return Container(
          height: outerHeight,
          decoration: BoxDecoration(
            color: shellBg,
            borderRadius: BorderRadius.circular(pillRadius),
          ),
          clipBehavior: Clip.hardEdge,
          child: Padding(
            padding: const EdgeInsets.all(innerPadding),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              child: ConstrainedBox(
                constraints: BoxConstraints(minWidth: innerAvailWidth),
                child: SizedBox(
                  width: rowWidth,
                  child: Row(children: children),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
