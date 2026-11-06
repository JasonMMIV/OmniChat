import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../utils/sandbox_path_resolver.dart';

/// Document attachment chip shown inside a user message.
///
/// Unlike the old inline builder this checks file existence asynchronously
/// (multimodal plan §2.3-4 / §5.1-6: never `existsSync` on the UI isolate) and
/// renders a distinct "unavailable" state for deleted files, `includeFiles`
/// backups that omitted the blob, or cross-device path mismatches.
class UserAttachmentCard extends StatefulWidget {
  const UserAttachmentCard({
    super.key,
    required this.path,
    required this.fileName,
    required this.mime,
  });

  final String path;
  final String fileName;
  final String mime;

  @override
  State<UserAttachmentCard> createState() => _UserAttachmentCardState();
}

class _UserAttachmentCardState extends State<UserAttachmentCard> {
  bool? _available;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    var ok = false;
    try {
      ok = await File(SandboxPathResolver.fix(widget.path)).exists();
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    setState(() => _available = ok);
  }

  Future<void> _open() async {
    final l10n = AppLocalizations.of(context)!;
    if (_available == false) {
      showAppSnackBar(
        context,
        message: l10n.chatMessageWidgetFileNotFound(widget.fileName),
        type: NotificationType.error,
      );
      return;
    }
    try {
      final fixed = SandboxPathResolver.fix(widget.path);
      final res = await OpenFilex.open(fixed, type: widget.mime);
      if (res.type != ResultType.done && mounted) {
        showAppSnackBar(
          context,
          message: l10n.chatMessageWidgetCannotOpenFile(
            res.message ?? res.type.toString(),
          ),
          type: NotificationType.error,
        );
      }
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: l10n.chatMessageWidgetOpenFileError(e.toString()),
        type: NotificationType.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final l10n = AppLocalizations.of(context)!;
    final missing = _available == false;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: _open,
        overlayColor: MaterialStateProperty.resolveWith(
          (states) => cs.primary.withOpacity(
            states.contains(MaterialState.pressed) ? 0.14 : 0.08,
          ),
        ),
        splashColor: cs.primary.withOpacity(0.18),
        child: Ink(
          decoration: BoxDecoration(
            color: isDark ? Colors.white12 : cs.surface,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  missing
                      ? Icons.insert_drive_file_outlined
                      : Icons.insert_drive_file,
                  size: 16,
                  color: missing ? cs.error.withOpacity(0.8) : null,
                ),
                const SizedBox(width: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 180),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.fileName,
                        overflow: TextOverflow.ellipsis,
                        style: missing
                            ? TextStyle(color: cs.onSurface.withOpacity(0.5))
                            : null,
                      ),
                      if (missing)
                        Text(
                          l10n.attachmentUnavailable,
                          style: TextStyle(fontSize: 10.5, color: cs.error),
                        ),
                    ],
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
