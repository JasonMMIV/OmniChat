import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/providers/settings_provider.dart';
import '../../../core/services/shell/shell_run_service.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';

/// P1-6: desktop developer mode — the master switch for `shell_run` plus the
/// command allowlist. The page is visible on every platform so the policy is
/// auditable, but the switch is disabled (and the tool never advertised) on
/// Android/iOS.
class DeveloperModePage extends StatefulWidget {
  const DeveloperModePage({super.key});

  @override
  State<DeveloperModePage> createState() => _DeveloperModePageState();
}

class _DeveloperModePageState extends State<DeveloperModePage> {
  final TextEditingController _controller = TextEditingController();
  bool _adding = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _addProgram(SettingsProvider settings) async {
    if (_adding) return;
    final value = _controller.text.trim();
    if (value.isEmpty) return;
    setState(() => _adding = true);
    await settings.addShellAllowlistEntry(value);
    if (!mounted) return;
    _controller.clear();
    setState(() => _adding = false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final settings = context.watch<SettingsProvider>();
    final isDesktop = ShellRunService.isPlatformSupported;
    final availability = ShellRunService.probeAllowlist(
      settings.shellAllowlist,
      refresh: true,
    );

    return Scaffold(
      appBar: AppBar(title: Text(l10n.developerModeTitle)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
          children: [
            _warningCard(context, l10n.developerModeWarning),
            const SizedBox(height: 12),
            _sectionCard(
              context,
              children: [
                SwitchListTile(
                  value: settings.developerModeV1,
                  onChanged: isDesktop
                      ? (value) => settings.setDeveloperModeV1(value)
                      : null,
                  title: Text(
                    l10n.developerModeMasterTitle,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: cs.onSurface.withValues(alpha: 0.9),
                    ),
                  ),
                  subtitle: Text(
                    l10n.developerModeMasterSubtitle,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.35,
                      color: cs.onSurface.withValues(alpha: 0.55),
                    ),
                  ),
                  secondary: Icon(
                    Lucide.Terminal,
                    size: 20,
                    color: cs.primary,
                  ),
                ),
                if (!isDesktop)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Text(
                      l10n.developerModeDesktopOnly,
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurface.withValues(alpha: 0.55),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            Text(
              l10n.developerModeAllowlistTitle,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: cs.onSurface.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              l10n.developerModeAllowlistSubtitle,
              style: TextStyle(
                fontSize: 12,
                height: 1.35,
                color: cs.onSurface.withValues(alpha: 0.5),
              ),
            ),
            const SizedBox(height: 8),
            _sectionCard(
              context,
              children: [
                if (settings.shellAllowlist.isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    child: Text(
                      l10n.developerModeAllowlistEmpty,
                      style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurface.withValues(alpha: 0.55),
                      ),
                    ),
                  ),
                for (final program in settings.shellAllowlist) ...[
                  ListTile(
                    dense: true,
                    leading: Icon(
                      Lucide.Terminal,
                      size: 18,
                      color: cs.primary,
                    ),
                    title: Text(
                      program,
                      style: const TextStyle(
                        fontSize: 14,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      availability[program] == true
                          ? l10n.developerModeDetected
                          : l10n.developerModeNotDetected,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: availability[program] == true
                            ? cs.primary.withValues(alpha: 0.75)
                            : cs.onSurface.withValues(alpha: 0.45),
                      ),
                    ),
                    trailing: IconButton(
                      tooltip: l10n.developerModeRemoveProgram,
                      icon: Icon(
                        Lucide.X,
                        size: 16,
                        color: cs.onSurface.withValues(alpha: 0.5),
                      ),
                      onPressed: () =>
                          settings.removeShellAllowlistEntry(program),
                    ),
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                ],
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _controller,
                          textInputAction: TextInputAction.done,
                          decoration: InputDecoration(
                            border: InputBorder.none,
                            labelText: l10n.developerModeAddProgram,
                            hintText: l10n.developerModeAddProgramHint,
                          ),
                          onSubmitted: (_) => _addProgram(settings),
                        ),
                      ),
                      IconButton(
                        tooltip: l10n.developerModeAddProgram,
                        onPressed: _adding ? null : () => _addProgram(settings),
                        icon: Icon(
                          Lucide.Plus,
                          size: 20,
                          color: cs.primary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _warningCard(BuildContext context, String text) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: isDark ? 0.14 : 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Colors.orange.withValues(alpha: 0.25),
          width: 0.6,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Lucide.Shield, size: 18, color: Colors.orange),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.4,
                color: cs.onSurface.withValues(alpha: 0.75),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionCard(BuildContext context, {required List<Widget> children}) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        color: isDark ? Colors.white10 : Colors.white.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: cs.outlineVariant.withValues(alpha: isDark ? 0.08 : 0.06),
          width: 0.6,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );
  }
}
