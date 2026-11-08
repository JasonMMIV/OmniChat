import 'package:flutter/material.dart';

import '../features/chat/widgets/dev_preview_panel.dart';
import '../icons/lucide_adapter.dart';
import '../l10n/app_localizations.dart';
import '../shared/widgets/ios_tactile.dart';

/// Desktop (Windows/macOS) dialog host for the site-preview panel.
Future<void> showDevPreviewDesktopDialog(
  BuildContext context, {
  required String workspaceRoot,
  String? initialPath,
}) async {
  await showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => _DevPreviewDialog(
      workspaceRoot: workspaceRoot,
      initialPath: initialPath,
    ),
  );
}

class _DevPreviewDialog extends StatelessWidget {
  const _DevPreviewDialog({required this.workspaceRoot, this.initialPath});

  final String workspaceRoot;
  final String? initialPath;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    // Clamp to the actual viewport: a fixed 1080×760 box overflows a
    // 1366×768 laptop once the 24 px inset padding is applied.
    final screen = MediaQuery.sizeOf(context);
    final width = (screen.width - 48).clamp(320.0, 1180.0);
    final height = (screen.height - 48).clamp(320.0, 820.0);
    return Dialog(
      elevation: 12,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SizedBox(
        width: width,
        height: height,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Material(
            color: cs.surface,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 8, 8),
                  child: Row(
                    children: [
                      Icon(Lucide.Monitor, size: 18, color: cs.primary),
                      const SizedBox(width: 8),
                      Text(
                        l10n.devPreviewTitle,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const Spacer(),
                      IosIconButton(
                        icon: Lucide.X,
                        size: 18,
                        minSize: 34,
                        semanticLabel: l10n.mcpPageClose,
                        onTap: () => Navigator.of(context).maybePop(),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: DevPreviewPanel(
                    workspaceRoot: workspaceRoot,
                    initialPath: initialPath,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
