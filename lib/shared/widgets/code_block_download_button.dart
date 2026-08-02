import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../../icons/lucide_adapter.dart';
import '../../l10n/app_localizations.dart';
import 'snackbar.dart';

/// Saves [code] to a file with the given [extension], reusing the app's
/// standard export flow: desktop picks a location via FilePicker then writes
/// the file; mobile lets FilePicker write the bytes directly (required on
/// Android & iOS).
Future<void> saveCodeBlockToFile(
  BuildContext context,
  String code,
  String extension,
) async {
  final l10n = AppLocalizations.of(context)!;
  final filename =
      'omnichat-block-${DateTime.now().millisecondsSinceEpoch}.$extension';
  try {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      // Desktop: choose save location, then write the file.
      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: l10n.backupPageExportToFile,
        fileName: filename,
        type: FileType.custom,
        allowedExtensions: <String>[extension],
      );
      if (savePath == null) return; // user cancelled
      await File(savePath).parent.create(recursive: true);
      await File(savePath).writeAsString(code);
      if (!context.mounted) return;
      showAppSnackBar(
        context,
        message: l10n.messageExportSheetExportedAs(_baseNameOf(savePath)),
        type: NotificationType.success,
      );
    } else {
      // Mobile: FilePicker writes the file itself via the bytes param.
      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: l10n.backupPageExportToFile,
        fileName: filename,
        type: FileType.custom,
        allowedExtensions: <String>[extension],
        bytes: utf8.encode(code),
      );
      if (savePath == null) return; // user cancelled
      if (!context.mounted) return;
      showAppSnackBar(
        context,
        message: l10n.messageExportSheetExportedAs(_baseNameOf(savePath)),
        type: NotificationType.success,
      );
    }
  } catch (e) {
    if (!context.mounted) return;
    showAppSnackBar(
      context,
      message: l10n.messageExportSheetExportFailed('$e'),
      type: NotificationType.error,
    );
  }
}

String _baseNameOf(String path) {
  final seg = path.split(RegExp(r'[/\\]')).last;
  return seg.isEmpty ? path : seg;
}

/// Download header action button, styled to match the Copy/Preview actions in
/// code block headers.
class CodeBlockDownloadButton extends StatelessWidget {
  const CodeBlockDownloadButton({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      splashColor: Platform.isIOS ? Colors.transparent : null,
      highlightColor: Platform.isIOS ? Colors.transparent : null,
      hoverColor: Platform.isIOS ? Colors.transparent : null,
      overlayColor: Platform.isIOS
          ? const MaterialStatePropertyAll(Colors.transparent)
          : null,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Lucide.Download,
              size: 14,
              color: cs.onSurface.withOpacity(0.6),
            ),
            const SizedBox(width: 6),
            Text(
              AppLocalizations.of(context)!.codeBlockDownloadButton,
              style: TextStyle(
                fontSize: 12,
                color: cs.onSurface.withOpacity(0.6),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
