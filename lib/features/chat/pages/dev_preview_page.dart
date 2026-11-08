import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../widgets/dev_preview_panel.dart';

/// Mobile/tablet full-screen host for the site-preview panel.
class DevPreviewPage extends StatelessWidget {
  const DevPreviewPage({
    super.key,
    required this.workspaceRoot,
    this.initialPath,
  });

  final String workspaceRoot;
  final String? initialPath;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.devPreviewTitle)),
      body: SafeArea(
        child: DevPreviewPanel(
          workspaceRoot: workspaceRoot,
          initialPath: initialPath,
        ),
      ),
    );
  }
}
