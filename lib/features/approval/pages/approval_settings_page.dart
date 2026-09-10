import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/agent/approval.dart';
import '../../../core/services/haptics.dart';

/// P1-1: mobile settings page for the tool-approval policy — strict mode
/// toggle plus management of the persisted "always allow" overrides
/// (out-of-workspace paths; the MCP policy source was removed 2026-09-10).
class ApprovalSettingsPage extends StatelessWidget {
  const ApprovalSettingsPage({super.key});

  String _overrideLabel(
    AppLocalizations l10n,
    ApprovalOverrideKey decoded,
  ) {
    return l10n.approvalOverridePath(decoded.resolvedPath ?? '*');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final settings = context.watch<SettingsProvider>();

    final overrides = settings.approvalAlwaysAllowed.toList()..sort();

    return Scaffold(
      appBar: AppBar(
        leading: Tooltip(
          message: l10n.settingsPageBackButton,
          child: _TactileIconButton(
            icon: Lucide.ArrowLeft,
            color: cs.onSurface,
            size: 22,
            onTap: () => Navigator.of(context).maybePop(),
          ),
        ),
        title: Text(l10n.approvalSettingsTitle),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          // Strict mode toggle
          _iosSectionCard(context, children: [
            SwitchListTile(
              value: settings.approvalStrictModeV1,
              onChanged: (v) => settings.setApprovalStrictModeV1(v),
              title: Text(
                l10n.approvalStrictModeTitle,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: cs.onSurface.withOpacity(0.9),
                ),
              ),
              subtitle: Text(
                l10n.approvalStrictModeSubtitle,
                style: TextStyle(
                  fontSize: 13,
                  color: cs.onSurface.withOpacity(0.5),
                ),
              ),
              secondary: Icon(Lucide.Shield, size: 20, color: cs.primary),
            ),
          ]),
          const SizedBox(height: 12),

          // Always-allow overrides
          _iosSectionLabel(context, l10n.approvalOverridesTitle),
          Text(
            l10n.approvalOverridesSubtitle,
            style: TextStyle(
              fontSize: 13,
              color: cs.onSurface.withOpacity(0.5),
            ),
          ),
          const SizedBox(height: 8),
          if (overrides.isEmpty)
            _iosSectionCard(context, children: [
              _pressableRow(
                context,
                icon: Lucide.CheckCircle,
                title: l10n.approvalOverridesEmpty,
                subtitle: null,
              ),
            ])
          else
            _iosSectionCard(
              context,
              children: [
                for (final key in overrides)
                  _pressableRow(
                    context,
                    icon: Lucide.FileQuestion,
                    title: _labelFor(l10n, key),
                    subtitle: null,
                    trailing: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        Haptics.light();
                        settings.removeApprovalAlwaysAllowed(key);
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 10),
                        child: Icon(
                          Lucide.X,
                          size: 16,
                          color: cs.onSurface.withOpacity(0.5),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  String _labelFor(AppLocalizations l10n, String key) {
    final decoded = decodeApprovalOverrideKey(key);
    return decoded != null ? _overrideLabel(l10n, decoded) : key;
  }
}

Widget _iosSectionLabel(BuildContext context, String text) {
  final cs = Theme.of(context).colorScheme;
  return Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: cs.onSurface.withOpacity(0.7),
      ),
    ),
  );
}

Widget _iosSectionCard(BuildContext context, {required List<Widget> children}) {
  final cs = Theme.of(context).colorScheme;
  final isDark = Theme.of(context).brightness == Brightness.dark;
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
}

Widget _pressableRow(
  BuildContext context, {
  required IconData icon,
  required String title,
  String? subtitle,
  VoidCallback? onTap,
  Widget? trailing,
}) {
  final cs = Theme.of(context).colorScheme;
  return GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: onTap == null
        ? null
        : () {
            Haptics.light();
            onTap();
          },
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      child: Row(
        children: [
          SizedBox(width: 36, child: Icon(icon, size: 20, color: cs.primary)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontSize: 15,
                color: cs.onSurface.withOpacity(0.9),
                fontWeight: FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (trailing != null) trailing,
        ],
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
    final pressColor = base.withOpacity(0.7);
    return GestureDetector(
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
        child: Icon(widget.icon, size: widget.size, color: _pressed ? pressColor : base),
      ),
    );
  }
}