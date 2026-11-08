import 'dart:io';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';

import '../../../desktop/dev_preview_dialog.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/snackbar.dart';
import '../pages/dev_preview_page.dart';

/// Opens the live site preview for [workspacePath].
///
/// [initialPath] is a workspace-relative file or directory. When omitted the
/// panel opens `index.html` if present, otherwise the entry-point picker.
Future<void> showDevPreview(
  BuildContext context, {
  required String workspacePath,
  String? initialPath,
}) async {
  final l10n = AppLocalizations.of(context)!;
  if (workspacePath.trim().isEmpty) {
    showAppSnackBar(
      context,
      message: l10n.devPreviewWorkspaceMissing,
      type: NotificationType.warning,
    );
    return;
  }
  if (Platform.isLinux) {
    showAppSnackBar(
      context,
      message: l10n.devPreviewNotSupported,
      type: NotificationType.warning,
    );
    return;
  }
  final isDesktop =
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.linux;
  if (isDesktop) {
    await showDevPreviewDesktopDialog(
      context,
      workspaceRoot: workspacePath,
      initialPath: initialPath,
    );
    return;
  }
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => DevPreviewPage(
        workspaceRoot: workspacePath,
        initialPath: initialPath,
      ),
    ),
  );
}
