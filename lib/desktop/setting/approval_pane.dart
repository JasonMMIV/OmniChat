import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../icons/lucide_adapter.dart' as lucide;
import '../../l10n/app_localizations.dart';
import '../../core/providers/settings_provider.dart';
import '../../core/services/agent/approval.dart';
import '../../shared/widgets/ios_switch.dart';

/// P1-1: desktop settings pane for the tool-approval policy — strict mode
/// toggle plus management of the persisted "always allow" overrides
/// (out-of-workspace paths; the MCP override keys were removed 2026-09-10).
class DesktopApprovalPane extends StatelessWidget {
  const DesktopApprovalPane({super.key});

  String _overrideLabel(
    AppLocalizations l10n,
    ApprovalOverrideKey decoded,
  ) {
    return l10n.approvalOverridePath(decoded.resolvedPath ?? '*');
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final settings = context.watch<SettingsProvider>();

    final overrides = settings.approvalAlwaysAllowed.toList()..sort();

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
                      l10n.approvalSettingsTitle,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: cs.onSurface.withOpacity(0.8),
                      ),
                    ),
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 8)),

              // Strict mode toggle
              SliverToBoxAdapter(
                child: _approvalCard(
                  context,
                  child: Row(
                    children: [
                      Icon(lucide.Lucide.Shield,
                          size: 20, color: cs.primary),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              l10n.approvalStrictModeTitle,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w500,
                                color: cs.onSurface.withOpacity(0.9),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              l10n.approvalStrictModeSubtitle,
                              style: TextStyle(
                                fontSize: 12,
                                color: cs.onSurface.withOpacity(0.55),
                              ),
                            ),
                          ],
                        ),
                      ),
                      IosSwitch(
                        value: settings.approvalStrictModeV1,
                        onChanged: (v) =>
                            settings.setApprovalStrictModeV1(v),
                      ),
                    ],
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 16)),

              // Always-allow overrides
              SliverToBoxAdapter(
                child: _sectionLabel(
                  context,
                  l10n.approvalOverridesTitle,
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    l10n.approvalOverridesSubtitle,
                    style: TextStyle(
                      fontSize: 12,
                      color: cs.onSurface.withOpacity(0.55),
                    ),
                  ),
                ),
              ),
              if (overrides.isEmpty)
                SliverToBoxAdapter(
                  child: _approvalCard(
                    context,
                    child: Row(
                      children: [
                        Icon(lucide.Lucide.CheckCircle,
                            size: 18, color: cs.onSurface.withOpacity(0.4)),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            l10n.approvalOverridesEmpty,
                            style: TextStyle(
                              fontSize: 13,
                              color: cs.onSurface.withOpacity(0.5),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              else
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (ctx, i) {
                      final key = overrides[i];
                      final decoded = decodeApprovalOverrideKey(key);
                      return _approvalCard(
                        context,
                        child: Row(
                          children: [
                            Icon(
                              lucide.Lucide.FileQuestion,
                              size: 18,
                              color: cs.onSurface.withOpacity(0.6),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                decoded != null
                                    ? _overrideLabel(l10n, decoded)
                                    : key,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: cs.onSurface.withOpacity(0.85),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            _SmallIconBtn(
                              icon: lucide.Lucide.X,
                              tooltip: l10n.approvalOverrideRemove,
                              onTap: () =>
                                  settings.removeApprovalAlwaysAllowed(key),
                            ),
                          ],
                        ),
                      );
                    },
                    childCount: overrides.length,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

Widget _sectionLabel(BuildContext context, String text) {
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

Widget _approvalCard(BuildContext context, {required Widget child}) {
  final cs = Theme.of(context).colorScheme;
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final Color bg = isDark ? Colors.white10 : Colors.white.withOpacity(0.96);
  return Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: cs.outlineVariant.withOpacity(isDark ? 0.08 : 0.06),
          width: 0.6,
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: child,
    ),
  );
}

class _SmallIconBtn extends StatefulWidget {
  const _SmallIconBtn({required this.icon, required this.onTap, this.tooltip});
  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  State<_SmallIconBtn> createState() => _SmallIconBtnState();
}

class _SmallIconBtnState extends State<_SmallIconBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: widget.tooltip ?? '',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _hover ? cs.onSurface.withOpacity(0.08) : Colors.transparent,
            ),
            child: Icon(widget.icon, size: 18, color: cs.onSurface.withOpacity(0.6)),
          ),
        ),
      ),
    );
  }
}
