import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/providers/settings_provider.dart';
import '../../../core/services/agent/subagent_profiles.dart';
import '../../../core/services/file/file_tool_service.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';

/// P1-1 (A1): the subagent profile registry editor.
///
/// Reachable from Add-ons → Advanced Features → "Subagent profiles".
/// A profile decides a helper's tools, permissions and (optionally) a
/// pre-bound provider/model. Built-ins are always present; they may be edited
/// and reset, but their id never changes. Changes apply to the NEXT spawn —
/// a running helper keeps the snapshot it started with.
class SubagentProfilesPage extends StatelessWidget {
  const SubagentProfilesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final settings = context.watch<SettingsProvider>();
    final profiles = settings.subagentProfiles;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.subagentProfilesTitle),
        actions: [
          IconButton(
            tooltip: l10n.subagentProfileNew,
            icon: const Icon(Lucide.Plus, size: 20),
            onPressed: () => _openEditor(context, null),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
              child: Text(
                l10n.subagentProfilesDescription,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.4,
                  color: cs.onSurface.withValues(alpha: 0.62),
                ),
              ),
            ),
            for (final profile in profiles)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _ProfileRow(
                  profile: profile,
                  onTap: () => _openEditor(context, profile),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _openEditor(
    BuildContext context,
    SubagentProfile? profile,
  ) async {
    final settings = context.read<SettingsProvider>();
    await Navigator.of(context, rootNavigator: true).push<void>(
      MaterialPageRoute(
        builder: (_) =>
            _SubagentProfileEditorPage(initial: profile, settings: settings),
      ),
    );
  }
}

class _ProfileRow extends StatelessWidget {
  const _ProfileRow({required this.profile, required this.onTap});

  final SubagentProfile profile;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final toolCount = profile.allowedTools?.length;
    final model = profile.followsConversationModel
        ? l10n.subagentProfileFollowConversation
        : '${profile.providerKey} / ${profile.modelId}';
    final detail = [
      if (profile.readOnly) l10n.subagentProfileReadOnly,
      if (toolCount != null) l10n.subagentProfileToolsCount('$toolCount'),
      model,
    ].join(' · ');

    return Material(
      color: cs.surfaceContainerHighest.withValues(alpha: 0.35),
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(12, 2, 8, 2),
        leading: Icon(
          profile.readOnly ? Lucide.Eye : Lucide.UserRoundCheck,
          size: 20,
          color: cs.primary,
        ),
        title: Row(
          children: [
            Flexible(
              child: Text(
                profile.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              profile.builtIn
                  ? l10n.subagentProfileBuiltIn
                  : l10n.subagentProfileCustom,
              style: TextStyle(
                fontSize: 10,
                color: cs.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
        subtitle: Text(
          '${profile.id} · $detail',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 11.5,
            height: 1.35,
            color: cs.onSurface.withValues(alpha: 0.55),
          ),
        ),
        trailing: Icon(
          Lucide.ChevronRight,
          size: 16,
          color: cs.onSurface.withValues(alpha: 0.5),
        ),
        onTap: onTap,
      ),
    );
  }
}

class _SubagentProfileEditorPage extends StatefulWidget {
  const _SubagentProfileEditorPage({
    required this.initial,
    required this.settings,
  });

  final SubagentProfile? initial;
  final SettingsProvider settings;

  @override
  State<_SubagentProfileEditorPage> createState() =>
      _SubagentProfileEditorPageState();
}

class _SubagentProfileEditorPageState
    extends State<_SubagentProfileEditorPage> {
  late final bool _isNew = widget.initial == null;
  late final SubagentProfile _base = widget.initial ?? _newProfile();

  late final TextEditingController _name;
  late final TextEditingController _description;
  late final TextEditingController _instructions;
  late final TextEditingController _maxSteps;
  late final TextEditingController _tokenBudget;
  late final TextEditingController _customTools;
  late final Set<String> _allowedTools = <String>{
    ...?widget.initial?.allowedTools,
  };
  late bool _restrictTools = widget.initial?.allowedTools != null;
  late bool _readOnly = widget.initial?.readOnly ?? false;
  String? _providerKey;
  String? _modelId;
  String? _error;
  String? _liveError;
  bool _draftTouched = false;

  static SubagentProfile _newProfile() =>
      const SubagentProfile(id: '', name: '', description: '');

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: _base.name);
    _description = TextEditingController(text: _base.description);
    _instructions = TextEditingController(text: _base.instructions);
    _maxSteps = TextEditingController(text: _base.maxSteps?.toString() ?? '');
    _tokenBudget = TextEditingController(
      text: _base.tokenBudget?.toString() ?? '',
    );
    final selectable = _selectableTools.toSet();
    _customTools = TextEditingController(
      text: (_base.allowedTools ?? const <String>{})
          .where((name) => !selectable.contains(name))
          .join(', '),
    );
    _providerKey = _base.providerKey;
    _modelId = _base.modelId;
    for (final controller in <TextEditingController>[
      _name,
      _description,
      _instructions,
      _maxSteps,
      _tokenBudget,
      _customTools,
    ]) {
      controller.addListener(_onDraftChanged);
    }
  }

  @override
  void dispose() {
    _name.removeListener(_onDraftChanged);
    _description.removeListener(_onDraftChanged);
    _instructions.removeListener(_onDraftChanged);
    _maxSteps.removeListener(_onDraftChanged);
    _tokenBudget.removeListener(_onDraftChanged);
    _customTools.removeListener(_onDraftChanged);
    _name.dispose();
    _description.dispose();
    _instructions.dispose();
    _maxSteps.dispose();
    _tokenBudget.dispose();
    _customTools.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final providers = widget.settings.providerConfigs;
    final providerIds = providers.keys.toList()..sort();
    // A profile can outlive the provider it was bound to (deleted config or a
    // backup restored on another device). Treat the missing provider as
    // "follow conversation" for display so the dropdown never asserts; the
    // save path reports the problem instead of persisting a dangling id.
    final selectedProvider =
        (_providerKey != null && providers.containsKey(_providerKey))
        ? _providerKey
        : null;
    final models = <String>[
      if (selectedProvider != null) ...[
        ...?providers[selectedProvider]?.models,
        ...?providers[selectedProvider]?.modelOverrides.keys,
      ],
    ].toSet().toList()..sort();
    if (_modelId != null && !models.contains(_modelId)) {
      models.insert(0, _modelId!);
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _isNew ? l10n.subagentProfileNew : l10n.subagentProfileEdit,
        ),
        actions: [
          TextButton(onPressed: _save, child: Text(l10n.subagentProfileSave)),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            if ((_liveError ?? _error) != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  (_liveError ?? _error)!,
                  style: TextStyle(fontSize: 12, color: cs.error),
                ),
              ),
            _field(l10n.subagentProfileName, _name),
            _field(
              l10n.subagentProfileDescriptionLabel,
              _description,
              maxLines: 2,
            ),
            _field(
              l10n.subagentProfileInstructions,
              _instructions,
              maxLines: 6,
              hint: l10n.subagentProfileInstructionsHint,
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                l10n.subagentProfileReadOnly,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: Text(
                l10n.subagentProfileReadOnlySubtitle,
                style: TextStyle(
                  fontSize: 12,
                  color: cs.onSurface.withValues(alpha: 0.55),
                ),
              ),
              value: _readOnly,
              onChanged: (v) => setState(() {
                _readOnly = v;
                if (v) {
                  _allowedTools.removeWhere(subagentWriteToolNames.contains);
                }
              }),
            ),
            const Divider(height: 20),
            _sectionLabel(context, l10n.subagentProfileModel),
            _modelPicker(context, l10n, providerIds, models, selectedProvider),
            const Divider(height: 20),
            _sectionLabel(context, l10n.subagentProfileAllowedTools),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                l10n.subagentProfileAllowedTools,
                style: const TextStyle(fontSize: 13),
              ),
              subtitle: Text(
                l10n.subagentProfileAllowedToolsHint,
                style: TextStyle(
                  fontSize: 11.5,
                  color: cs.onSurface.withValues(alpha: 0.55),
                ),
              ),
              value: _restrictTools,
              onChanged: (v) => setState(() => _restrictTools = v),
            ),
            if (_restrictTools)
              for (final name in _selectableTools) _toolCheckbox(name, l10n),
            if (_restrictTools)
              _field(
                l10n.subagentProfileCustomTools,
                _customTools,
                maxLines: 2,
                hint: l10n.subagentProfileCustomToolsHint,
              ),
            const Divider(height: 20),
            _sectionLabel(context, l10n.subagentProfileMaxSteps),
            _field(
              l10n.subagentProfileMaxSteps,
              _maxSteps,
              keyboardType: TextInputType.number,
              hint: '1–40',
            ),
            _field(
              l10n.subagentProfileTokenBudget,
              _tokenBudget,
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 12),
            if (!_isNew && !_base.builtIn)
              OutlinedButton.icon(
                onPressed: _delete,
                icon: Icon(Lucide.Trash2, size: 16, color: cs.error),
                label: Text(
                  l10n.subagentProfileDelete,
                  style: TextStyle(color: cs.error),
                ),
              ),
            if (!_isNew)
              TextButton.icon(
                onPressed: _duplicate,
                icon: const Icon(Lucide.Copy, size: 16),
                label: Text(l10n.subagentProfileDuplicate),
              ),
            if (_base.builtIn)
              TextButton.icon(
                onPressed: _resetBuiltIn,
                icon: const Icon(Lucide.RotateCcw, size: 16),
                label: Text(l10n.subagentProfileReset),
              ),
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(BuildContext context, String text) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 4, 2, 6),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
          color: cs.onSurface.withValues(alpha: 0.5),
        ),
      ),
    );
  }

  Widget _field(
    String label,
    TextEditingController controller, {
    int maxLines = 1,
    String? hint,
    TextInputType? keyboardType,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: controller,
        maxLines: maxLines,
        keyboardType: keyboardType,
        style: const TextStyle(fontSize: 13.5),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          isDense: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
    );
  }

  Widget _toolCheckbox(String name, AppLocalizations l10n) {
    final cs = Theme.of(context).colorScheme;
    final blocked = _readOnly && subagentWriteToolNames.contains(name);
    return CheckboxListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      title: Text(name, style: const TextStyle(fontSize: 13)),
      subtitle: blocked
          ? Text(
              l10n.subagentProfileWriteBlocked,
              style: TextStyle(
                fontSize: 11,
                color: cs.onSurface.withValues(alpha: 0.55),
              ),
            )
          : null,
      value: _allowedTools.contains(name),
      onChanged: blocked
          ? null
          : (v) => setState(() {
              if (v == true) {
                _allowedTools.add(name);
              } else {
                _allowedTools.remove(name);
              }
            }),
    );
  }

  Set<String> _parsedCustomTools() {
    final result = <String>{};
    for (final raw in _customTools.text.split(RegExp(r'[\s,]+'))) {
      final name = raw.trim();
      if (name.isNotEmpty) result.add(name);
    }
    return result;
  }

  SubagentProfile _buildProfile({required String id, required bool builtIn}) {
    return SubagentProfile(
      id: id,
      name: _name.text.trim(),
      description: _description.text.trim(),
      instructions: _instructions.text.trim(),
      allowedTools: _restrictTools
          ? <String>{..._allowedTools, ..._parsedCustomTools()}
                .where(
                  (name) =>
                      !_readOnly || !subagentWriteToolNames.contains(name),
                )
                .toSet()
          : null,
      readOnly: _readOnly,
      providerKey: _providerKey,
      modelId: _providerKey == null ? null : _modelId,
      maxSteps: int.tryParse(_maxSteps.text.trim()),
      tokenBudget: int.tryParse(_tokenBudget.text.trim()),
      builtIn: builtIn,
    );
  }

  Widget _modelPicker(
    BuildContext context,
    AppLocalizations l10n,
    List<String> providerIds,
    List<String> models,
    String? selectedProvider,
  ) {
    return Column(
      children: [
        DropdownButtonFormField<String?>(
          value: selectedProvider,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: l10n.subagentProfileProvider,
            isDense: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
          items: [
            DropdownMenuItem<String?>(
              value: null,
              child: Text(
                l10n.subagentProfileFollowConversation,
                style: const TextStyle(fontSize: 13),
              ),
            ),
            for (final id in providerIds)
              DropdownMenuItem<String?>(
                value: id,
                child: Text(
                  widget.settings.providerConfigs[id]?.name ?? id,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
          ],
          onChanged: (value) => setState(() {
            _draftTouched = true;
            _providerKey = value;
            _modelId = null;
            _liveError = _computeLiveError();
          }),
        ),
        const SizedBox(height: 10),
        if (selectedProvider != null)
          DropdownButtonFormField<String>(
            value: _modelId,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: l10n.subagentProfileModel,
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            items: [
              for (final id in models)
                DropdownMenuItem<String>(
                  value: id,
                  child: Text(
                    id,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
            ],
            onChanged: (value) => setState(() {
              _draftTouched = true;
              _modelId = value;
              _liveError = _computeLiveError();
            }),
          ),
      ],
    );
  }

  List<String> get _selectableTools {
    final names = <String>{
      for (final def in FileToolService.getToolDefinitions())
        ((def['function'] as Map)['name'] ?? '').toString(),
      'get_console_errors',
      'web_fetch',
      'search_web',
      'shell_run',
      'shell_exec',
    }..removeWhere((n) => n.isEmpty);
    final sorted = names.toList()..sort();
    return sorted;
  }

  /// P1-1: validate while the user edits instead of only on Save. The error
  /// text is rendered above the form, mirroring the save-time messages so the
  /// user sees the same wording in both paths.
  void _onDraftChanged() {
    if (!mounted) return;
    setState(() {
      _draftTouched = true;
      // A draft change invalidates the previous save/delete error. Without
      // this reset, fixing the field would fall back to the stale banner.
      _error = null;
      _liveError = _computeLiveError();
    });
  }

  String? _computeLiveError() {
    if (!_draftTouched) return null;
    final l10n = AppLocalizations.of(context)!;
    final name = _name.text.trim();
    if (name.isEmpty) return l10n.subagentProfileNameRequired;
    final id = _isNew ? _slug(name) : _base.id;
    if (_isNew) {
      if (!SubagentProfiles.isValidId(id)) {
        return l10n.subagentProfileIdInvalid;
      }
      if (widget.settings.subagentProfiles.any((p) => p.id == id)) {
        return l10n.subagentProfileIdInUse;
      }
      if (widget.settings.subagentProfiles.length >=
          SubagentProfiles.maxProfiles) {
        return l10n.subagentProfileLimitReached;
      }
    }
    if (_maxSteps.text.trim().isNotEmpty &&
        int.tryParse(_maxSteps.text.trim()) == null) {
      return l10n.subagentProfileMaxStepsRange;
    }
    if (_tokenBudget.text.trim().isNotEmpty &&
        int.tryParse(_tokenBudget.text.trim()) == null) {
      return l10n.subagentProfileTokenBudgetRange;
    }
    if (_providerKey != null &&
        !widget.settings.providerConfigs.containsKey(_providerKey)) {
      return l10n.subagentProfileProviderMissing;
    }
    if (_providerKey != null && (_modelId ?? '').trim().isEmpty) {
      return l10n.subagentProfileModelPair;
    }
    final error = SubagentProfiles.validate(
      _buildProfile(id: id, builtIn: SubagentProfiles.builtInIds.contains(id)),
      isNew: _isNew,
    );
    return error == null ? null : _errorText(l10n, error);
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;
    _draftTouched = true;
    final live = _computeLiveError();
    if (live != null) {
      setState(() {
        _error = null;
        _liveError = live;
      });
      return;
    }
    final id = _isNew ? _slug(_name.text) : _base.id;
    if (_isNew && !SubagentProfiles.isValidId(id)) {
      setState(() => _error = l10n.subagentProfileIdInvalid);
      return;
    }
    if (_providerKey != null &&
        !widget.settings.providerConfigs.containsKey(_providerKey)) {
      setState(() => _error = l10n.subagentProfileProviderMissing);
      return;
    }
    final profile = _buildProfile(
      id: id,
      builtIn: SubagentProfiles.builtInIds.contains(id),
    );
    final error = SubagentProfiles.validate(profile, isNew: _isNew);
    if (error != null) {
      setState(() => _error = _errorText(l10n, error));
      return;
    }
    if (_providerKey != null && (_modelId ?? '').isEmpty) {
      setState(() => _error = l10n.subagentProfileModelPair);
      return;
    }

    final current = widget.settings.subagentProfiles;
    final existingIds = current.map((p) => p.id).toSet();
    if (_isNew && existingIds.contains(id)) {
      setState(() => _error = l10n.subagentProfileIdInUse);
      return;
    }
    if (_isNew && current.length >= SubagentProfiles.maxProfiles) {
      setState(() => _error = l10n.subagentProfileLimitReached);
      return;
    }
    final next = <SubagentProfile>[
      for (final p in current)
        if (p.id == id) profile else p,
      if (!existingIds.contains(id)) profile,
    ];
    await widget.settings.setSubagentProfiles(next);
    if (!mounted) return;
    Navigator.of(context).maybePop();
  }

  String _errorText(AppLocalizations l10n, String code) {
    switch (code) {
      case 'invalid_id':
        return l10n.subagentProfileIdInvalid;
      case 'built_in_id':
        return l10n.subagentProfileIdReserved;
      case 'name_required':
        return l10n.subagentProfileNameRequired;
      case 'name_too_long':
      case 'description_too_long':
      case 'instructions_too_long':
        return l10n.subagentProfileValueTooLong;
      case 'model_pair_required':
        return l10n.subagentProfileModelPair;
      case 'max_steps_out_of_range':
        return l10n.subagentProfileMaxStepsRange;
      case 'token_budget_out_of_range':
        return l10n.subagentProfileTokenBudgetRange;
      default:
        return l10n.subagentProfileNameRequired;
    }
  }

  Future<void> _delete() async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(l10n.subagentProfileDeleteConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.subagentProfileCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.subagentProfileDelete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final next = widget.settings.subagentProfiles
        .where((p) => p.id != _base.id)
        .toList();
    await widget.settings.setSubagentProfiles(next);
    if (!mounted) return;
    Navigator.of(context).maybePop();
  }

  Future<void> _duplicate() async {
    final l10n = AppLocalizations.of(context)!;
    final current = widget.settings.subagentProfiles;
    if (current.length >= SubagentProfiles.maxProfiles) {
      setState(() => _error = l10n.subagentProfileLimitReached);
      return;
    }
    final ids = current.map((p) => p.id).toSet();
    final stem = _base.id.length > 28 ? _base.id.substring(0, 28) : _base.id;
    var index = 2;
    var id = '${stem}_copy';
    while (ids.contains(id) || !SubagentProfiles.isValidId(id)) {
      id = '${stem}_copy$index';
      index++;
    }
    final baseName = _name.text.trim().isEmpty ? _base.name : _name.text.trim();
    final copy = _buildProfile(
      id: id,
      builtIn: false,
    ).copyWith(name: '$baseName copy');
    final error = SubagentProfiles.validate(copy, isNew: false);
    if (error != null) {
      setState(() => _error = _errorText(l10n, error));
      return;
    }
    if (copy.providerKey != null &&
        !widget.settings.providerConfigs.containsKey(copy.providerKey)) {
      setState(() => _error = l10n.subagentProfileProviderMissing);
      return;
    }
    await widget.settings.setSubagentProfiles(<SubagentProfile>[
      ...current,
      copy,
    ]);
    if (!mounted) return;
    Navigator.of(context).maybePop();
  }

  Future<void> _resetBuiltIn() async {
    final current = widget.settings.subagentProfiles;
    final defaults = SubagentProfiles.builtIn(_base.id);
    await widget.settings.setSubagentProfiles(<SubagentProfile>[
      for (final p in current)
        if (p.id == _base.id) defaults else p,
    ]);
    if (!mounted) return;
    Navigator.of(context).maybePop();
  }

  /// Slug from the display name; the id is immutable once created.
  String _slug(String name) {
    final lower = name.toLowerCase().trim();
    final buffer = StringBuffer();
    for (final rune in lower.runes) {
      final ch = String.fromCharCode(rune);
      final ok =
          (ch.codeUnitAt(0) >= 97 && ch.codeUnitAt(0) <= 122) ||
          (ch.codeUnitAt(0) >= 48 && ch.codeUnitAt(0) <= 57);
      if (ok) {
        buffer.write(ch);
      } else if (buffer.isNotEmpty && !buffer.toString().endsWith('_')) {
        buffer.write('_');
      }
    }
    var id = buffer.toString().replaceAll(RegExp(r'_+$'), '');
    if (id.isEmpty) return '';
    if (!RegExp(r'^[a-z]').hasMatch(id)) id = 'a$id';
    return id.length > 40 ? id.substring(0, 40) : id;
  }
}
