// New-skill form bottom sheet (PLAN_AGENT_SKILLS.md §7.2). Fields:
// name (live regex validation) / description / body (Markdown template).

import 'package:flutter/material.dart';

import '../../../core/services/skills/skill_parser.dart';
import '../../../l10n/app_localizations.dart';
import '../../../core/services/haptics.dart';

/// Returns a result map on save: {name, description, body}. Null = cancelled.
Future<Map<String, String>?> showSkillEditSheet(BuildContext context) {
  final cs = Theme.of(context).colorScheme;
  return showModalBottomSheet<Map<String, String>>(
    context: context,
    isScrollControlled: true,
    backgroundColor: cs.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => const _SkillEditSheet(),
  );
}

class _SkillEditSheet extends StatefulWidget {
  const _SkillEditSheet();

  @override
  State<_SkillEditSheet> createState() => _SkillEditSheetState();
}

class _SkillEditSheetState extends State<_SkillEditSheet> {
  late final TextEditingController _nameController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _bodyController;
  String? _nameError;

  static const String _bodyTemplate = '''## When to use this skill

Describe when the model should use this skill.

## Instructions

Step-by-step instructions for the model.''';

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _descriptionController = TextEditingController();
    _bodyController = TextEditingController(text: _bodyTemplate);
    _nameController.addListener(_validateName);
  }

  @override
  void dispose() {
    _nameController.removeListener(_validateName);
    _nameController.dispose();
    _descriptionController.dispose();
    _bodyController.dispose();
    super.dispose();
  }

  void _validateName() {
    final value = _nameController.text.trim();
    String? error;
    if (value.isNotEmpty && !SkillParser.isValidSkillName(value)) {
      error = AppLocalizations.of(context)!.skillNameInvalid;
    }
    if (_nameError != error) setState(() => _nameError = error);
  }

  bool get _canSave =>
      _nameController.text.trim().isNotEmpty &&
      _nameError == null &&
      _descriptionController.text.trim().isNotEmpty;

  InputDecoration _decoration(
    BuildContext context,
    String label, {
    String? errorText,
  }) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return InputDecoration(
      labelText: label,
      errorText: errorText,
      filled: true,
      fillColor: isDark ? Colors.white10 : const Color(0xFFF2F3F5),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: cs.outlineVariant.withOpacity(0.4)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: cs.outlineVariant.withOpacity(0.4)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: cs.primary.withOpacity(0.5)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 12,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withOpacity(0.2),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Center(
              child: Text(
                l10n.skillsAddTitle,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _nameController,
              autofocus: true,
              decoration: _decoration(
                context,
                l10n.skillNameLabel,
                errorText: _nameError,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _descriptionController,
              maxLength: 1024,
              decoration: _decoration(context, l10n.skillDescriptionLabel),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _bodyController,
              maxLines: 6,
              decoration: _decoration(context, l10n.skillBodyLabel),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _SheetOutlineButton(
                    label: l10n.quickPhraseCancelButton,
                    onTap: () => Navigator.of(context).pop(),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _SheetFilledButton(
                    label: l10n.quickPhraseSaveButton,
                    onTap: _canSave
                        ? () {
                            Navigator.of(context).pop(<String, String>{
                              'name': _nameController.text.trim(),
                              'description':
                                  _descriptionController.text.trim(),
                              'body': _bodyController.text,
                            });
                          }
                        : null,
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

class _SheetOutlineButton extends StatefulWidget {
  const _SheetOutlineButton({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  State<_SheetOutlineButton> createState() => _SheetOutlineButtonState();
}

class _SheetOutlineButtonState extends State<_SheetOutlineButton> {
  bool _pressed = false;

  void _set(bool v) {
    if (_pressed != v) setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _set(true),
      onTapUp: (_) =>
          Future.delayed(const Duration(milliseconds: 80), () => _set(false)),
      onTapCancel: () => _set(false),
      onTap: () {
        Haptics.soft();
        widget.onTap();
      },
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOutCubic,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: cs.outlineVariant.withOpacity(0.4)),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              color: cs.onSurface,
              fontWeight: FontWeight.w600,
              fontSize: 14,
            ),
          ),
        ),
      ),
    );
  }
}

class _SheetFilledButton extends StatefulWidget {
  const _SheetFilledButton({required this.label, this.onTap});
  final String label;
  final VoidCallback? onTap;

  @override
  State<_SheetFilledButton> createState() => _SheetFilledButtonState();
}

class _SheetFilledButtonState extends State<_SheetFilledButton> {
  bool _pressed = false;

  void _set(bool v) {
    if (_pressed != v) setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final enabled = widget.onTap != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: enabled ? (_) => _set(true) : null,
      onTapUp: enabled
          ? (_) =>
              Future.delayed(const Duration(milliseconds: 80), () => _set(false))
          : null,
      onTapCancel: enabled ? () => _set(false) : null,
      onTap: enabled
          ? () {
              Haptics.soft();
              widget.onTap!();
            }
          : null,
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOutCubic,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: enabled ? cs.primary : cs.primary.withOpacity(0.35),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              color: cs.onPrimary,
              fontWeight: FontWeight.w600,
              fontSize: 14,
            ),
          ),
        ),
      ),
    );
  }
}
