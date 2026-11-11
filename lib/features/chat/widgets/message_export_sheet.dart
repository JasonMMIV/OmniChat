import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

import 'image_preview_sheet.dart';
import '../pages/image_viewer_page.dart';
import '../tools/tool_presentation.dart';

import '../../../icons/lucide_adapter.dart';
import '../../../core/models/answer_review.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/conversation.dart';
import '../../../core/services/file/unified_diff.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/providers/model_provider.dart';
import '../../../core/providers/user_provider.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/models/assistant.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../utils/sandbox_path_resolver.dart';
import '../../../shared/markdown/markdown_render_policy.dart';
import '../../../shared/markdown/markdown_surface_scope.dart';
import '../../../shared/widgets/markdown_with_highlight.dart';
import '../../../shared/widgets/export_capture_scope.dart';
import '../../../shared/widgets/long_image_exporter.dart';
import '../../../shared/widgets/mermaid_exporter.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/ios_switch.dart';
import '../../../l10n/app_localizations.dart';
import '../../../utils/brand_assets.dart';
import '../../../utils/avatar_cache.dart';
import 'chat_message_widget.dart' show ToolUIPart;
import 'answer_review_card.dart';

// Regular expression to extract thinking content from message
final RegExp thinkingRegex = RegExp(
  r"<(?:think|thought)>([\s\S]*?)(?:</(?:think|thought)>|$)",
  dotAll: true,
);

// Shared helpers
String _guessImageMime(String path) {
  final lower = path.toLowerCase();
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.webp')) return 'image/webp';
  return 'image/png';
}

String? _modelDisplayName(BuildContext context, ChatMessage msg) {
  if (msg.role != 'assistant') return null;
  final modelId = msg.modelId;
  if (modelId == null || modelId.isEmpty) return null;
  final settings = context.read<SettingsProvider>();
  String? name;
  String baseId = modelId;
  final providerId = msg.providerId;
  if (providerId != null && providerId.isNotEmpty) {
    try {
      final cfg = settings.getProviderConfig(providerId);
      final ov = cfg.modelOverrides[modelId] as Map?;
      if (ov != null) {
        final overrideName = (ov['name'] as String?)?.trim();
        if (overrideName != null && overrideName.isNotEmpty) {
          name = overrideName;
        }
        final apiId = (ov['apiModelId'] ?? ov['api_model_id'])
            ?.toString()
            .trim();
        if (apiId != null && apiId.isNotEmpty) {
          baseId = apiId;
        }
      }
    } catch (_) {
      // ignore lookup issues; fall back to inference below.
    }
  }

  final inferred = ModelRegistry.infer(
    ModelInfo(id: baseId, displayName: baseId),
  );
  final fallback = inferred.displayName.trim();
  return name ?? (fallback.isNotEmpty ? fallback : baseId);
}

String _getRoleName(BuildContext context, ChatMessage msg) {
  final l10n = AppLocalizations.of(context)!;
  if (msg.role == 'user') {
    final userProvider = context.read<UserProvider>();
    return userProvider.name;
  } else if (msg.role == 'assistant') {
    // Check if using assistant
    final assistant = context.read<AssistantProvider>().currentAssistant;
    if (assistant != null &&
        assistant.useAssistantAvatar == true &&
        assistant.name.trim().isNotEmpty) {
      return assistant.name.trim();
    }
    // Otherwise use model display name
    final modelName = _modelDisplayName(context, msg);
    if (modelName != null && modelName.isNotEmpty) {
      return modelName;
    }
    return l10n.messageExportSheetAssistant;
  }
  return msg.role;
}

_Parsed _parseContent(String raw) {
  // Robustly parse inline attachments in the form [image:...] and [file:path|name|mime]
  // without requiring escaping backslashes, and guard against malformed tokens.
  final images = <String>[];
  final docs = <_DocRef>[];
  final buffer = StringBuffer();
  int idx = 0;
  while (idx < raw.length) {
    // Fast path: only try to parse when current char is '['
    if (raw.codeUnitAt(idx) == 0x5B /* '[' */ ) {
      final sub = raw.substring(idx);
      // [image:...]
      final mImg = RegExp(r"^\[image:([^\]]+)\]").firstMatch(sub);
      if (mImg != null) {
        final p = (mImg.groupCount >= 1 ? mImg.group(1) : null)?.trim();
        if (p != null && p.isNotEmpty) images.add(p);
        idx += mImg.group(0)!.length;
        continue;
      }
      // [file:path|name|mime]
      final mFile = RegExp(r"^\[file:([^|\]]+)\|([^|\]]+)\|([^\]]+)\]")
          .firstMatch(sub);
      if (mFile != null) {
        final path =
            (mFile.groupCount >= 1 ? mFile.group(1) : null)?.trim() ?? '';
        final name =
            (mFile.groupCount >= 2 ? mFile.group(2) : null)?.trim() ?? 'file';
        final mime =
            (mFile.groupCount >= 3 ? mFile.group(3) : null)?.trim() ??
            'text/plain';
        docs.add(_DocRef(path: path, fileName: name, mime: mime));
        idx += mFile.group(0)!.length;
        continue;
      }
    }
    // Fallback: normal character
    buffer.write(raw[idx]);
    idx++;
  }
  return _Parsed(buffer.toString().trim(), images, docs);
}

String _softBreakMd(String input) {
  // Insert zero-width break in very long tokens outside fenced code blocks.
  final lines = input.split('\n');
  final out = StringBuffer();
  bool inFence = false;
  for (final line in lines) {
    String l = line;
    final trimmed = l.trimLeft();
    if (trimmed.startsWith('```')) {
      inFence = !inFence; // toggle on fence lines
      out.writeln(l);
      continue;
    }
    if (!inFence) {
      l = l.replaceAllMapped(RegExp(r'(\S{60,})'), (m) {
        final s = m.group(1)!;
        final buf = StringBuffer();
        for (int i = 0; i < s.length; i++) {
          buf.write(s[i]);
          if ((i + 1) % 20 == 0) buf.write('\u200B');
        }
        return buf.toString();
      });
    }
    out.writeln(l);
  }
  return out.toString();
}

/// Snapshots the inherited values the exported tree watches (settings, theme,
/// media query) so Provider-mediated notifications during the long capture do
/// not rebuild different tiles with different content. Direct listeners on the
/// notifier (e.g. ListenableBuilder) are not covered.
Widget _freezeExportContext(
  BuildContext context,
  SettingsProvider settings,
  Widget child,
) {
  return Provider<SettingsProvider>.value(
    value: settings,
    child: MediaQuery(
      data: MediaQuery.of(context),
      child: Theme(data: Theme.of(context), child: child),
    ),
  );
}

Future<LongImageExportResult?> _renderAndSaveMessageImage(
  BuildContext context,
  ChatMessage message, {
  bool showThinkingAndToolCards = false,
  bool expandThinkingContent = false,
  required bool tilingEnabled,
  LongImageProgressCallback? onProgress,
  bool Function()? isCancelled,
}) async {
  final cs = Theme.of(context).colorScheme;
  final settings = context.read<SettingsProvider>();
  final l10n = AppLocalizations.of(context)!;
  // Pre-render mermaid diagrams to images for export
  try {
    final codes = extractMermaidCodes(message.content);
    await preRenderMermaidCodesForExport(context, codes);
  } catch (_) {}

  // Desktop uses larger width and lower pixel ratio for better proportions
  final bool isDesktop =
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  final content = ExportCaptureScope(
    enabled: true,
    child: _ExportedMessageCard(
      message: message,
      title:
          context
              .read<ChatService>()
              .getConversation(message.conversationId)
              ?.title ??
          l10n.messageExportSheetDefaultTitle,
      cs: cs,
      chatFontScale: settings.chatFontScale,
      showThinkingAndToolCards: showThinkingAndToolCards,
      expandThinkingContent: expandThinkingContent,
      isDesktop: isDesktop,
    ),
  );
  return _renderWidgetDirectly(
    context,
    _freezeExportContext(context, settings, content),
    width: isDesktop ? 720 : 480,
    pixelRatio: isDesktop ? 2.0 : 3.0,
    tilingEnabled: tilingEnabled,
    onProgress: onProgress,
    isCancelled: isCancelled,
  );
}

Future<LongImageExportResult?> _renderAndSaveChatImage(
  BuildContext context,
  Conversation conversation,
  List<ChatMessage> messages, {
  bool showThinkingAndToolCards = false,
  bool expandThinkingContent = false,
  required bool tilingEnabled,
  LongImageProgressCallback? onProgress,
  bool Function()? isCancelled,
}) async {
  final cs = Theme.of(context).colorScheme;
  final settings = context.read<SettingsProvider>();
  final l10n = AppLocalizations.of(context)!;
  // Pre-render all mermaid diagrams found in selected messages
  try {
    final codes = messages
        .map((m) => extractMermaidCodes(m.content))
        .expand((e) => e)
        .toList();
    await preRenderMermaidCodesForExport(context, codes);
  } catch (_) {}

  // Desktop uses larger width and lower pixel ratio for better proportions
  final bool isDesktop =
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  final content = ExportCaptureScope(
    enabled: true,
    child: _ExportedChatImage(
      conversationTitle: (conversation.title.trim().isNotEmpty)
          ? conversation.title
          : l10n.messageExportSheetDefaultTitle,
      cs: cs,
      chatFontScale: settings.chatFontScale,
      messages: messages,
      timestamp: conversation.updatedAt,
      showThinkingAndToolCards: showThinkingAndToolCards,
      expandThinkingContent: expandThinkingContent,
      isDesktop: isDesktop,
    ),
  );
  return _renderWidgetDirectly(
    context,
    _freezeExportContext(context, settings, content),
    width: isDesktop ? 720 : 480,
    pixelRatio: isDesktop ? 2.0 : 3.0,
    tilingEnabled: tilingEnabled,
    onProgress: onProgress,
    isCancelled: isCancelled,
  );
}

Future<LongImageSegmentedExportResult?> _renderAndSaveMessageImageSegments(
  BuildContext context,
  ChatMessage message, {
  bool showThinkingAndToolCards = false,
  bool expandThinkingContent = false,
  LongImageProgressCallback? onProgress,
  bool Function()? isCancelled,
}) async {
  final cs = Theme.of(context).colorScheme;
  final settings = context.read<SettingsProvider>();
  final l10n = AppLocalizations.of(context)!;
  try {
    final codes = extractMermaidCodes(message.content);
    await preRenderMermaidCodesForExport(context, codes);
  } catch (_) {}

  final bool isDesktop =
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  final content = ExportCaptureScope(
    enabled: true,
    child: _ExportedMessageCard(
      message: message,
      title:
          context
              .read<ChatService>()
              .getConversation(message.conversationId)
              ?.title ??
          l10n.messageExportSheetDefaultTitle,
      cs: cs,
      chatFontScale: settings.chatFontScale,
      showThinkingAndToolCards: showThinkingAndToolCards,
      expandThinkingContent: expandThinkingContent,
      isDesktop: isDesktop,
    ),
  );
  return LongImageExporter.exportSegments(
    context,
    _freezeExportContext(context, settings, content),
    width: isDesktop ? 720 : 480,
    pixelRatio: isDesktop ? 2.0 : 3.0,
    onProgress: onProgress,
    isCancelled: isCancelled,
  );
}

Future<LongImageSegmentedExportResult?> _renderAndSaveChatImageSegments(
  BuildContext context,
  Conversation conversation,
  List<ChatMessage> messages, {
  bool showThinkingAndToolCards = false,
  bool expandThinkingContent = false,
  LongImageProgressCallback? onProgress,
  bool Function()? isCancelled,
}) async {
  final cs = Theme.of(context).colorScheme;
  final settings = context.read<SettingsProvider>();
  final l10n = AppLocalizations.of(context)!;
  try {
    final codes = messages
        .map((m) => extractMermaidCodes(m.content))
        .expand((e) => e)
        .toList();
    await preRenderMermaidCodesForExport(context, codes);
  } catch (_) {}

  final bool isDesktop =
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  final content = ExportCaptureScope(
    enabled: true,
    child: _ExportedChatImage(
      conversationTitle: (conversation.title.trim().isNotEmpty)
          ? conversation.title
          : l10n.messageExportSheetDefaultTitle,
      cs: cs,
      chatFontScale: settings.chatFontScale,
      messages: messages,
      timestamp: conversation.updatedAt,
      showThinkingAndToolCards: showThinkingAndToolCards,
      expandThinkingContent: expandThinkingContent,
      isDesktop: isDesktop,
    ),
  );
  return LongImageExporter.exportSegments(
    context,
    _freezeExportContext(context, settings, content),
    width: isDesktop ? 720 : 480,
    pixelRatio: isDesktop ? 2.0 : 3.0,
    onProgress: onProgress,
    isCancelled: isCancelled,
  );
}

// Single-shot fallback (kept for LONG_IMAGE_TILING=false).
Future<File?> _renderWidgetSingleShot(
  BuildContext context,
  Widget content, {
  double width = 480, // 宽度*3
  double pixelRatio = 3.0,
}) async {
  final overlay = Overlay.of(context);

  final boundaryKey = GlobalKey();
  final completer = Completer<void>();

  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (ctx) {
      // Schedule the completion after multiple frames to ensure rendering
      int frameCount = 0;
      void scheduleCompletion() {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          frameCount++;
          if (frameCount < 3) {
            // Wait for 3 frames to ensure complete rendering
            scheduleCompletion();
          } else if (!completer.isCompleted) {
            completer.complete();
          }
        });
      }

      scheduleCompletion();

      return Positioned(
        left: -10000, // Position far offscreen
        top: -10000,
        child: RepaintBoundary(
          key: boundaryKey,
          child: Container(
            width: width,
            color: Theme.of(ctx).colorScheme.background,
            child: Material(type: MaterialType.transparency, child: content),
          ),
        ),
      );
    },
  );

  overlay.insert(entry);

  ui.Image? image;
  try {
    // Wait for the widget to be ready
    await completer.future;
    // Additional delay to ensure everything is painted
    await Future<void>.delayed(const Duration(milliseconds: 500));

    final boundary =
        boundaryKey.currentContext?.findRenderObject()
            as RenderRepaintBoundary?;
    if (boundary == null) return null;

    // Try to capture the image with retries
    for (int retry = 0; retry < 10; retry++) {
      try {
        image = await boundary.toImage(pixelRatio: pixelRatio);
        break;
      } catch (e) {
        if (retry == 9) {
          print('Failed to capture image after 10 retries: $e');
          return null;
        }
        // Wait before retrying
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }

    if (image == null) return null;

    // Convert to PNG
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) return null;

    // Save to file
    final dir = await getTemporaryDirectory();
    final file = File(
      '${dir.path}/chat-export-${DateTime.now().millisecondsSinceEpoch}.png',
    );
    await file.writeAsBytes(data.buffer.asUint8List());

    return file;
  } finally {
    image?.dispose();
    entry.remove();
  }
}

const bool kLongImageTilingEnabled = bool.fromEnvironment(
  'LONG_IMAGE_TILING',
  defaultValue: true,
);

/// Compile-time kill switch for tiled export. Tiling is also disabled at
/// runtime when `long_image_tiling_v1` is off (Display → Rendering), which
/// selects the previous single-shot capture path.
Future<LongImageExportResult?> _renderWidgetDirectly(
  BuildContext context,
  Widget content, {
  double width = 480,
  double pixelRatio = 3.0,
  bool tilingEnabled = true,
  LongImageProgressCallback? onProgress,
  bool Function()? isCancelled,
}) async {
  if (!kLongImageTilingEnabled || !tilingEnabled) {
    final file = await _renderWidgetSingleShot(
      context,
      content,
      width: width,
      pixelRatio: pixelRatio,
    );
    return file == null
        ? null
        : LongImageExportResult(
            file: file,
            effectivePixelRatio: pixelRatio,
            requestedPixelRatio: pixelRatio,
          );
  }
  return LongImageExporter.export(
    context,
    content,
    width: width,
    pixelRatio: pixelRatio,
    onProgress: onProgress,
    isCancelled: isCancelled,
  );
}

Future<void> showMessageExportSheet(
  BuildContext context,
  ChatMessage message,
) async {
  // The export renders full tool cards; the SQLite facade loads tool bodies
  // per conversation, so make sure this message's parts are available.
  try {
    await context.read<ChatService>().ensureToolEventsLoaded([message.id]);
  } catch (_) {}
  if (!context.mounted) return;
  final cs = Theme.of(context).colorScheme;
  try {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      // Desktop: show centered dialog
      await showDialog<void>(
        context: context,
        barrierDismissible: true,
        builder: (ctx) => Dialog(
          elevation: 12,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 24,
            vertical: 24,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: _ExportDialog(message: message, parentContext: context),
        ),
      );
      return;
    }
  } catch (_) {
    // Fallback to bottom sheet below
  }
  // Mobile: keep bottom sheet
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: cs.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) {
      return SafeArea(
        top: false,
        child: _ExportSheet(message: message, parentContext: context),
      );
    },
  );
}

Future<void> showChatExportSheet(
  BuildContext context, {
  required Conversation conversation,
  required List<ChatMessage> selectedMessages,
}) async {
  final cs = Theme.of(context).colorScheme;
  try {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      // Desktop: show centered dialog
      await showDialog<void>(
        context: context,
        barrierDismissible: true,
        builder: (ctx) => Dialog(
          elevation: 12,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 24,
            vertical: 24,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: _BatchExportDialog(
            conversation: conversation,
            messages: selectedMessages,
            parentContext: context,
          ),
        ),
      );
      return;
    }
  } catch (_) {
    // Fallback to bottom sheet below
  }
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: cs.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) {
      return SafeArea(
        top: false,
        child: _BatchExportSheet(
          conversation: conversation,
          messages: selectedMessages,
          parentContext: context,
        ),
      );
    },
  );
}

/// A conversation together with the messages that should be exported.
class ChatExportBundle {
  const ChatExportBundle({required this.conversation, required this.messages});

  final Conversation conversation;
  final List<ChatMessage> messages;
}

/// Opens the export-format picker for whole conversations.
///
/// This is the sidebar "Export" entry point: the message-selection step used by
/// the per-message Share action is skipped, and every user/assistant message of
/// each conversation is exported. A single conversation reuses the regular
/// batch sheet; two or more use a compact "pick one format, save one file each"
/// panel.
Future<void> showConversationsExportSheet(
  BuildContext context, {
  required List<ChatExportBundle> bundles,
}) async {
  if (bundles.isEmpty) return;
  if (bundles.length == 1) {
    await showChatExportSheet(
      context,
      conversation: bundles.first.conversation,
      selectedMessages: bundles.first.messages,
    );
    return;
  }
  final cs = Theme.of(context).colorScheme;
  try {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      await showDialog<void>(
        context: context,
        barrierDismissible: true,
        builder: (ctx) => Dialog(
          elevation: 12,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 24,
            vertical: 24,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: _MultiConversationExportPanel(
            bundles: bundles,
            parentContext: context,
            inSheet: false,
          ),
        ),
      );
      return;
    }
  } catch (_) {
    // Fall back to the bottom sheet below.
  }
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: cs.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => SafeArea(
      top: false,
      child: _MultiConversationExportPanel(
        bundles: bundles,
        parentContext: context,
        inSheet: true,
      ),
    ),
  );
}

// Desktop dialog: single message export
class _ExportDialog extends StatefulWidget {
  const _ExportDialog({required this.message, required this.parentContext});
  final ChatMessage message;
  final BuildContext parentContext;

  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<_ExportDialog> {
  bool _exporting = false;
  bool _showThinkingAndToolCards = false;
  bool _expandThinkingContent = false;

  String _formatTime(BuildContext context, DateTime time) {
    final l10n = AppLocalizations.of(context)!;
    final fmt = DateFormat(l10n.messageExportSheetDateTimeWithSecondsPattern);
    return fmt.format(time);
  }

  Future<void> _onExportMarkdown() async {
    if (_exporting) return;
    // Close dialog first to avoid overlapping UI
    if (mounted) await Navigator.of(context).maybePop();
    try {
      final pctx = widget.parentContext;
      final msg = widget.message;
      final service = pctx.read<ChatService>();
      final convo = service.getConversation(msg.conversationId);
      final l10n = AppLocalizations.of(pctx)!;
      final title = ((convo?.title ?? '').trim().isNotEmpty)
          ? (convo?.title ?? '')
          : l10n.messageExportSheetDefaultTitle;
      final time = _formatTime(pctx, msg.timestamp);

      final parsed = _parseContent(msg.content);

      final buf = StringBuffer();
      buf.writeln('# $title');
      buf.writeln('');
      buf.writeln('> $time · ${_getRoleName(pctx, msg)}');
      buf.writeln('');
      if (parsed.text.isNotEmpty) {
        buf.writeln(parsed.text);
        buf.writeln('');
      }
      for (final p in parsed.images) {
        final fixed = SandboxPathResolver.fix(p);
        try {
          final f = File(fixed);
          if (await f.exists()) {
            final bytes = await f.readAsBytes();
            final b64 = base64Encode(bytes);
            final mime = _guessImageMime(fixed);
            buf.writeln('![](data:$mime;base64,$b64)');
          } else {
            buf.writeln('![image]($fixed)');
          }
        } catch (_) {
          buf.writeln('![image]($fixed)');
        }
        buf.writeln('');
      }
      for (final d in parsed.docs) {
        buf.writeln('- ${d.fileName}  `(${d.mime})`');
      }
      final review = _answerReviewMarkdown(pctx, service, msg);
      if (review.isNotEmpty) buf.writeln(review);

      final filename =
          'chat-export-${DateTime.now().millisecondsSinceEpoch}.md';
      // Desktop save
      final String? savePath = await FilePicker.platform.saveFile(
        dialogTitle: AppLocalizations.of(pctx)!.backupPageExportToFile,
        fileName: filename,
        type: FileType.custom,
        allowedExtensions: const ['md'],
      );
      if (savePath != null) {
        await File(savePath).parent.create(recursive: true);
        await File(savePath).writeAsString(buf.toString());
        final l10n = AppLocalizations.of(pctx)!;
        showAppSnackBar(
          pctx,
          message: l10n.messageExportSheetExportedAs(p.basename(savePath)),
          type: NotificationType.success,
        );
      }
    } catch (e) {
      final pctx = widget.parentContext;
      final l10n = AppLocalizations.of(pctx)!;
      showAppSnackBar(
        pctx,
        message: l10n.messageExportSheetExportFailed('$e'),
        type: NotificationType.error,
      );
    }
  }

  Future<void> _onExportTxt() async {
    if (_exporting) return;
    // Close dialog first to avoid overlapping UI
    if (mounted) await Navigator.of(context).maybePop();
    try {
      final pctx = widget.parentContext;
      final msg = widget.message;
      final service = pctx.read<ChatService>();
      final convo = service.getConversation(msg.conversationId);
      final l10n = AppLocalizations.of(pctx)!;
      final title = ((convo?.title ?? '').trim().isNotEmpty)
          ? (convo?.title ?? '')
          : l10n.messageExportSheetDefaultTitle;
      final time = _formatTime(pctx, msg.timestamp);

      final parsed = _parseContent(msg.content);

      final buf = StringBuffer();
      buf.writeln(title);
      buf.writeln('');
      buf.writeln('$time · ${_getRoleName(pctx, msg)}');
      buf.writeln('');
      if (parsed.text.isNotEmpty) {
        buf.writeln(parsed.text);
        buf.writeln('');
      }
      for (final d in parsed.docs) {
        buf.writeln('- ${d.fileName} (${d.mime})');
      }
      final review = _answerReviewMarkdown(pctx, service, msg);
      if (review.isNotEmpty) buf.writeln(review);

      final filename =
          'chat-export-${DateTime.now().millisecondsSinceEpoch}.txt';
      // Desktop save
      final String? savePath = await FilePicker.platform.saveFile(
        dialogTitle: AppLocalizations.of(pctx)!.backupPageExportToFile,
        fileName: filename,
        type: FileType.custom,
        allowedExtensions: const ['txt'],
      );
      if (savePath != null) {
        await File(savePath).parent.create(recursive: true);
        await File(savePath).writeAsString(buf.toString());
        final l10n = AppLocalizations.of(pctx)!;
        showAppSnackBar(
          pctx,
          message: l10n.messageExportSheetExportedAs(p.basename(savePath)),
          type: NotificationType.success,
        );
      }
    } catch (e) {
      final pctx = widget.parentContext;
      final l10n = AppLocalizations.of(pctx)!;
      showAppSnackBar(
        pctx,
        message: l10n.messageExportSheetExportFailed('$e'),
        type: NotificationType.error,
      );
    }
  }

  Future<void> _onExportImage() async {
    if (_exporting) return;
    final tilingEnabled = widget.parentContext
        .read<SettingsProvider>()
        .longImageTilingEnabled;
    // Close dialog first to avoid overlapping UI
    if (mounted) await Navigator.of(context).maybePop();
    await _runImageExport(
      widget.parentContext,
      render: (onProgress, isCancelled) => _renderAndSaveMessageImage(
        widget.parentContext,
        widget.message,
        showThinkingAndToolCards: _showThinkingAndToolCards,
        expandThinkingContent: _expandThinkingContent,
        tilingEnabled: tilingEnabled,
        onProgress: onProgress,
        isCancelled: isCancelled,
      ),
    );
  }

  Future<void> _onExportSegmentedImage() async {
    if (_exporting) return;
    if (mounted) await Navigator.of(context).maybePop();
    await _runSegmentedImageExport(
      widget.parentContext,
      render: (onProgress, isCancelled) => _renderAndSaveMessageImageSegments(
        widget.parentContext,
        widget.message,
        showThinkingAndToolCards: _showThinkingAndToolCards,
        expandThinkingContent: _expandThinkingContent,
        onProgress: onProgress,
        isCancelled: isCancelled,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    return ConstrainedBox(
      constraints: const BoxConstraints(
        minWidth: 420,
        maxWidth: 640,
        maxHeight: 640,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Material(
          color: cs.surface,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.messageExportSheetFormatTitle,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      tooltip: l10n.mcpPageClose,
                      icon: Icon(
                        Lucide.X,
                        size: 18,
                        color: cs.onSurface.withOpacity(0.75),
                      ),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              // Body
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: Scrollbar(
                    child: ListView(
                      children: [
                        _ExportOptionTile(
                          icon: Lucide.BookOpenText,
                          title: l10n.messageExportSheetMarkdown,
                          subtitle:
                              l10n.messageExportSheetSingleMarkdownSubtitle,
                          onTap: _exporting ? null : _onExportMarkdown,
                        ),
                        _ExportOptionTile(
                          icon: Lucide.FileText,
                          title: l10n.messageExportSheetPlainText,
                          subtitle: l10n.messageExportSheetSingleTxtSubtitle,
                          onTap: _exporting ? null : _onExportTxt,
                        ),
                        _ExportOptionTile(
                          icon: Lucide.Image,
                          title: l10n.messageExportSheetExportImage,
                          subtitle:
                              l10n.messageExportSheetSingleExportImageSubtitle,
                          onTap: _exporting ? null : _onExportImage,
                        ),
                        _ExportOptionTile(
                          icon: Lucide.Layers,
                          title: l10n.messageExportSheetSegmentedImage,
                          subtitle:
                              l10n.messageExportSheetSegmentedImageSubtitle,
                          onTap: _exporting ? null : _onExportSegmentedImage,
                        ),
                        const SizedBox(height: 8),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Column(
                            children: [
                              _buildSwitchRow(
                                context,
                                title: l10n
                                    .messageExportSheetShowThinkingAndToolCards,
                                value: _showThinkingAndToolCards,
                                onChanged: (v) {
                                  setState(() {
                                    _showThinkingAndToolCards = v;
                                    if (!v) _expandThinkingContent = false;
                                  });
                                },
                              ),
                              _buildSwitchRow(
                                context,
                                title:
                                    l10n.messageExportSheetShowThinkingContent,
                                value: _expandThinkingContent,
                                onChanged: _showThinkingAndToolCards
                                    ? (v) => setState(
                                        () => _expandThinkingContent = v,
                                      )
                                    : null,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSwitchRow(
    BuildContext context, {
    required String title,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) {
    final cs = Theme.of(context).colorScheme;
    final isEnabled = onChanged != null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontSize: 14,
                color: isEnabled ? cs.onSurface : cs.onSurface.withOpacity(0.4),
              ),
            ),
          ),
          IosSwitch(
            value: value,
            onChanged: onChanged,
            activeColor: cs.primary,
          ),
        ],
      ),
    );
  }
}

// Desktop dialog: batch export
class _BatchExportDialog extends StatefulWidget {
  const _BatchExportDialog({
    required this.conversation,
    required this.messages,
    required this.parentContext,
  });
  final Conversation conversation;
  final List<ChatMessage> messages;
  final BuildContext parentContext;

  @override
  State<_BatchExportDialog> createState() => _BatchExportDialogState();
}

class _BatchExportDialogState extends State<_BatchExportDialog> {
  bool _exporting = false;
  bool _showThinkingAndToolCards = false;
  bool _expandThinkingContent = false;

  String _formatTime(BuildContext context, DateTime time) {
    final l10n = AppLocalizations.of(context)!;
    final fmt = DateFormat(l10n.messageExportSheetDateTimeWithSecondsPattern);
    return fmt.format(time);
  }

  Future<void> _onExportMarkdown() async {
    if (_exporting) return;
    // Close dialog first to avoid overlapping UI
    if (mounted) await Navigator.of(context).maybePop();
    try {
      final pctx = widget.parentContext;
      final service = pctx.read<ChatService>();
      final conv = widget.conversation;
      final l10n = AppLocalizations.of(pctx)!;
      final title = (conv.title.trim().isNotEmpty)
          ? conv.title
          : l10n.messageExportSheetDefaultTitle;
      final buf = StringBuffer();
      buf.writeln('# $title');
      buf.writeln('');
      for (final msg in widget.messages) {
        final time = _formatTime(pctx, msg.timestamp);
        buf.writeln('> $time · ${_getRoleName(pctx, msg)}');
        buf.writeln('');
        final parsed = _parseContent(msg.content);
        if (parsed.text.isNotEmpty) {
          buf.writeln(parsed.text);
          buf.writeln('');
        }
        for (final p in parsed.images) {
          final fixed = SandboxPathResolver.fix(p);
          try {
            final f = File(fixed);
            if (await f.exists()) {
              final bytes = await f.readAsBytes();
              final b64 = base64Encode(bytes);
              final mime = _guessImageMime(fixed);
              buf.writeln('![](data:$mime;base64,$b64)');
            } else {
              buf.writeln('![image]($fixed)');
            }
          } catch (_) {
            buf.writeln('![image]($fixed)');
          }
          buf.writeln('');
        }
        for (final d in parsed.docs) {
          buf.writeln('- ${d.fileName}  `(${d.mime})`');
        }
        final review = _answerReviewMarkdown(pctx, service, msg);
        if (review.isNotEmpty) buf.writeln(review);
        buf.writeln('\n---\n');
      }

      final filename =
          'chat-export-${DateTime.now().millisecondsSinceEpoch}.md';
      final String? savePath = await FilePicker.platform.saveFile(
        dialogTitle: AppLocalizations.of(pctx)!.backupPageExportToFile,
        fileName: filename,
        type: FileType.custom,
        allowedExtensions: const ['md'],
      );
      if (savePath == null) {
        return; // user cancelled
      }
      try {
        await File(savePath).parent.create(recursive: true);
        await File(savePath).writeAsString(buf.toString());
      } catch (e) {
        showAppSnackBar(
          pctx,
          message: l10n.messageExportSheetExportFailed('$e'),
          type: NotificationType.error,
        );
        return;
      }
      showAppSnackBar(
        pctx,
        message: l10n.messageExportSheetExportedAs(p.basename(savePath)),
        type: NotificationType.success,
      );
    } catch (e) {
      final pctx = widget.parentContext;
      final l10n = AppLocalizations.of(pctx)!;
      showAppSnackBar(
        pctx,
        message: l10n.messageExportSheetExportFailed('$e'),
        type: NotificationType.error,
      );
    }
  }

  Future<void> _onExportTxt() async {
    if (_exporting) return;
    // Close dialog first to avoid overlapping UI
    if (mounted) await Navigator.of(context).maybePop();
    try {
      final pctx = widget.parentContext;
      final conv = widget.conversation;
      final l10n = AppLocalizations.of(pctx)!;
      final title = (conv.title.trim().isNotEmpty)
          ? conv.title
          : l10n.messageExportSheetDefaultTitle;
      final buf = StringBuffer();
      buf.writeln(title);
      buf.writeln('');
      for (final msg in widget.messages) {
        final time = _formatTime(pctx, msg.timestamp);
        buf.writeln('$time · ${_getRoleName(pctx, msg)}');
        buf.writeln('');
        final parsed = _parseContent(msg.content);
        if (parsed.text.isNotEmpty) {
          buf.writeln(parsed.text);
          buf.writeln('');
        }
        for (final d in parsed.docs) {
          buf.writeln('- ${d.fileName} (${d.mime})');
        }
        buf.writeln('\n---\n');
      }

      final filename =
          'chat-export-${DateTime.now().millisecondsSinceEpoch}.txt';
      final String? savePath = await FilePicker.platform.saveFile(
        dialogTitle: AppLocalizations.of(pctx)!.backupPageExportToFile,
        fileName: filename,
        type: FileType.custom,
        allowedExtensions: const ['txt'],
      );
      if (savePath == null) {
        return; // user cancelled
      }
      try {
        await File(savePath).parent.create(recursive: true);
        await File(savePath).writeAsString(buf.toString());
      } catch (e) {
        showAppSnackBar(
          pctx,
          message: l10n.messageExportSheetExportFailed('$e'),
          type: NotificationType.error,
        );
        return;
      }
      showAppSnackBar(
        pctx,
        message: l10n.messageExportSheetExportedAs(p.basename(savePath)),
        type: NotificationType.success,
      );
    } catch (e) {
      final pctx = widget.parentContext;
      final l10n = AppLocalizations.of(pctx)!;
      showAppSnackBar(
        pctx,
        message: l10n.messageExportSheetExportFailed('$e'),
        type: NotificationType.error,
      );
    }
  }

  Future<void> _onExportImage() async {
    if (_exporting) return;
    final tilingEnabled = widget.parentContext
        .read<SettingsProvider>()
        .longImageTilingEnabled;
    // Close dialog first to avoid overlapping UI
    if (mounted) await Navigator.of(context).maybePop();
    await _runImageExport(
      widget.parentContext,
      render: (onProgress, isCancelled) => _renderAndSaveChatImage(
        widget.parentContext,
        widget.conversation,
        widget.messages,
        showThinkingAndToolCards: _showThinkingAndToolCards,
        expandThinkingContent: _expandThinkingContent,
        tilingEnabled: tilingEnabled,
        onProgress: onProgress,
        isCancelled: isCancelled,
      ),
    );
  }

  Future<void> _onExportSegmentedImage() async {
    if (_exporting) return;
    if (mounted) await Navigator.of(context).maybePop();
    await _runSegmentedImageExport(
      widget.parentContext,
      render: (onProgress, isCancelled) => _renderAndSaveChatImageSegments(
        widget.parentContext,
        widget.conversation,
        widget.messages,
        showThinkingAndToolCards: _showThinkingAndToolCards,
        expandThinkingContent: _expandThinkingContent,
        onProgress: onProgress,
        isCancelled: isCancelled,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    return ConstrainedBox(
      constraints: const BoxConstraints(
        minWidth: 480,
        maxWidth: 720,
        maxHeight: 460,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Material(
          color: cs.surface,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.messageExportSheetFormatTitle,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      tooltip: l10n.mcpPageClose,
                      icon: Icon(
                        Lucide.X,
                        size: 18,
                        color: cs.onSurface.withOpacity(0.75),
                      ),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              // Body
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: Scrollbar(
                    child: ListView(
                      children: [
                        _ExportOptionTile(
                          icon: Lucide.BookOpenText,
                          title: l10n.messageExportSheetMarkdown,
                          subtitle:
                              l10n.messageExportSheetBatchMarkdownSubtitle,
                          onTap: _exporting ? null : _onExportMarkdown,
                        ),
                        _ExportOptionTile(
                          icon: Lucide.FileText,
                          title: l10n.messageExportSheetPlainText,
                          subtitle: l10n.messageExportSheetBatchTxtSubtitle,
                          onTap: _exporting ? null : _onExportTxt,
                        ),
                        _ExportOptionTile(
                          icon: Lucide.Image,
                          title: l10n.messageExportSheetExportImage,
                          subtitle:
                              l10n.messageExportSheetBatchExportImageSubtitle,
                          onTap: _exporting ? null : _onExportImage,
                        ),
                        _ExportOptionTile(
                          icon: Lucide.Layers,
                          title: l10n.messageExportSheetSegmentedImage,
                          subtitle:
                              l10n.messageExportSheetSegmentedImageSubtitle,
                          onTap: _exporting ? null : _onExportSegmentedImage,
                        ),
                        const SizedBox(height: 8),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Column(
                            children: [
                              _buildSwitchRow(
                                context,
                                title: l10n
                                    .messageExportSheetShowThinkingAndToolCards,
                                value: _showThinkingAndToolCards,
                                onChanged: (v) {
                                  setState(() {
                                    _showThinkingAndToolCards = v;
                                    if (!v) _expandThinkingContent = false;
                                  });
                                },
                              ),
                              _buildSwitchRow(
                                context,
                                title:
                                    l10n.messageExportSheetShowThinkingContent,
                                value: _expandThinkingContent,
                                onChanged: _showThinkingAndToolCards
                                    ? (v) => setState(
                                        () => _expandThinkingContent = v,
                                      )
                                    : null,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSwitchRow(
    BuildContext context, {
    required String title,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) {
    final cs = Theme.of(context).colorScheme;
    final isEnabled = onChanged != null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontSize: 14,
                color: isEnabled ? cs.onSurface : cs.onSurface.withOpacity(0.4),
              ),
            ),
          ),
          IosSwitch(
            value: value,
            onChanged: onChanged,
            activeColor: cs.primary,
          ),
        ],
      ),
    );
  }
}

class _ExportSheet extends StatefulWidget {
  const _ExportSheet({required this.message, required this.parentContext});
  final ChatMessage message;
  final BuildContext parentContext;

  @override
  State<_ExportSheet> createState() => _ExportSheetState();
}

class _BatchExportSheet extends StatefulWidget {
  const _BatchExportSheet({
    required this.conversation,
    required this.messages,
    required this.parentContext,
  });
  final Conversation conversation;
  final List<ChatMessage> messages;
  final BuildContext parentContext;

  @override
  State<_BatchExportSheet> createState() => _BatchExportSheetState();
}

class _BatchExportSheetState extends State<_BatchExportSheet> {
  final DraggableScrollableController _ctrl = DraggableScrollableController();
  bool _exporting = false;
  bool _showThinkingAndToolCards = false;
  bool _expandThinkingContent = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  String _formatTime(BuildContext context, DateTime time) {
    final l10n = AppLocalizations.of(context)!;
    final fmt = DateFormat(l10n.messageExportSheetDateTimeWithSecondsPattern);
    return fmt.format(time);
  }

  Future<void> _onExportMarkdown() async {
    if (_exporting) return;

    // Dismiss dialog immediately
    if (mounted) Navigator.of(context).maybePop();

    setState(() => _exporting = true);
    try {
      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        showAppSnackBar(
          context,
          message: l10n.messageExportSheetExporting,
          type: NotificationType.info,
        );
      }
      final ctx = context;
      final service = ctx.read<ChatService>();
      final conv = widget.conversation;
      final l10n = AppLocalizations.of(ctx)!;
      final title = (conv.title.trim().isNotEmpty)
          ? conv.title
          : l10n.messageExportSheetDefaultTitle;
      final buf = StringBuffer();
      buf.writeln('# $title');
      buf.writeln('');
      for (final msg in widget.messages) {
        final time = _formatTime(ctx, msg.timestamp);
        buf.writeln('> $time · ${_getRoleName(ctx, msg)}');
        buf.writeln('');
        final parsed = _parseContent(msg.content);
        if (parsed.text.isNotEmpty) {
          buf.writeln(parsed.text);
          buf.writeln('');
        }
        for (final p in parsed.images) {
          final fixed = SandboxPathResolver.fix(p);
          try {
            final f = File(fixed);
            if (await f.exists()) {
              final bytes = await f.readAsBytes();
              final b64 = base64Encode(bytes);
              final mime = _guessImageMime(fixed);
              buf.writeln('![](data:$mime;base64,$b64)');
            } else {
              buf.writeln('![image]($fixed)');
            }
          } catch (_) {
            buf.writeln('![image]($fixed)');
          }
          buf.writeln('');
        }
        for (final d in parsed.docs) {
          buf.writeln('- ${d.fileName}  `(${d.mime})`');
        }
        final review = _answerReviewMarkdown(ctx, service, msg);
        if (review.isNotEmpty) buf.writeln(review);
        buf.writeln('\n---\n');
      }

      final filename =
          'chat-export-${DateTime.now().millisecondsSinceEpoch}.md';

      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        // Desktop: choose save location
        final l10n = AppLocalizations.of(context)!;
        final String? savePath = await FilePicker.platform.saveFile(
          dialogTitle: l10n.backupPageExportToFile,
          fileName: filename,
          type: FileType.custom,
          allowedExtensions: const ['md'],
        );
        if (savePath == null) {
          return; // user cancelled
        }
        try {
          await File(savePath).parent.create(recursive: true);
          await File(savePath).writeAsString(buf.toString());
        } catch (e) {
          if (!mounted) return;
          showAppSnackBar(
            context,
            message: l10n.messageExportSheetExportFailed('$e'),
            type: NotificationType.error,
          );
          return;
        }
        if (mounted) {
          showAppSnackBar(
            context,
            message: l10n.messageExportSheetExportedAs(p.basename(savePath)),
            type: NotificationType.success,
          );
        }
      } else {
        // Mobile: use FilePicker with bytes parameter (required on Android & iOS)
        final l10n = AppLocalizations.of(context)!;
        final contentBytes = utf8.encode(buf.toString());
        final String? savePath = await FilePicker.platform.saveFile(
          dialogTitle: l10n.backupPageExportToFile,
          fileName: filename,
          type: FileType.custom,
          allowedExtensions: const ['md'],
          bytes: Uint8List.fromList(contentBytes),
        );
        if (savePath == null) {
          return; // user cancelled
        }
        if (mounted) {
          showAppSnackBar(
            context,
            message: l10n.messageExportSheetExportedAs(p.basename(savePath)),
            type: NotificationType.success,
          );
        }
      }
    } catch (e) {
      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        showAppSnackBar(
          context,
          message: l10n.messageExportSheetExportFailed('$e'),
          type: NotificationType.error,
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _onExportTxt() async {
    if (_exporting) return;

    // Dismiss dialog immediately
    if (mounted) Navigator.of(context).maybePop();

    setState(() => _exporting = true);
    try {
      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        showAppSnackBar(
          context,
          message: l10n.messageExportSheetExporting,
          type: NotificationType.info,
        );
      }
      final ctx = context;
      final conv = widget.conversation;
      final l10n = AppLocalizations.of(ctx)!;
      final title = (conv.title.trim().isNotEmpty)
          ? conv.title
          : l10n.messageExportSheetDefaultTitle;
      final buf = StringBuffer();
      buf.writeln(title);
      buf.writeln('');
      for (final msg in widget.messages) {
        final time = _formatTime(ctx, msg.timestamp);
        buf.writeln('$time · ${_getRoleName(ctx, msg)}');
        buf.writeln('');
        final parsed = _parseContent(msg.content);
        if (parsed.text.isNotEmpty) {
          buf.writeln(parsed.text);
          buf.writeln('');
        }
        for (final d in parsed.docs) {
          buf.writeln('- ${d.fileName} (${d.mime})');
        }
        buf.writeln('\n---\n');
      }

      final filename =
          'chat-export-${DateTime.now().millisecondsSinceEpoch}.txt';

      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        // Desktop: choose save location
        final String? savePath = await FilePicker.platform.saveFile(
          dialogTitle: l10n.backupPageExportToFile,
          fileName: filename,
          type: FileType.custom,
          allowedExtensions: const ['txt'],
        );
        if (savePath == null) {
          return; // user cancelled
        }
        try {
          await File(savePath).parent.create(recursive: true);
          await File(savePath).writeAsString(buf.toString());
        } catch (e) {
          if (!mounted) return;
          showAppSnackBar(
            context,
            message: l10n.messageExportSheetExportFailed('$e'),
            type: NotificationType.error,
          );
          return;
        }
        if (mounted) {
          showAppSnackBar(
            context,
            message: l10n.messageExportSheetExportedAs(p.basename(savePath)),
            type: NotificationType.success,
          );
        }
      } else {
        // Mobile: use FilePicker with bytes parameter (required on Android & iOS)
        final contentBytes = utf8.encode(buf.toString());
        final String? savePath = await FilePicker.platform.saveFile(
          dialogTitle: l10n.backupPageExportToFile,
          fileName: filename,
          type: FileType.custom,
          allowedExtensions: const ['txt'],
          bytes: Uint8List.fromList(contentBytes),
        );
        if (savePath == null) {
          return; // user cancelled
        }
        if (mounted) {
          showAppSnackBar(
            context,
            message: l10n.messageExportSheetExportedAs(p.basename(savePath)),
            type: NotificationType.success,
          );
        }
      }
    } catch (e) {
      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        showAppSnackBar(
          context,
          message: l10n.messageExportSheetExportFailed('$e'),
          type: NotificationType.error,
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _onExportImage() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    final tilingEnabled = widget.parentContext
        .read<SettingsProvider>()
        .longImageTilingEnabled;
    try {
      await _runImageExport(
        widget.parentContext,
        render: (onProgress, isCancelled) => _renderAndSaveChatImage(
          widget.parentContext,
          widget.conversation,
          widget.messages,
          showThinkingAndToolCards: _showThinkingAndToolCards,
          expandThinkingContent: _expandThinkingContent,
          tilingEnabled: tilingEnabled,
          onProgress: onProgress,
          isCancelled: isCancelled,
        ),
        beforePreview: () async {
          // Close the sheet before opening the preview, otherwise maybePop
          // would dismiss the preview itself.
          if (mounted) await Navigator.of(context).maybePop();
        },
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _onExportSegmentedImage() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      await _runSegmentedImageExport(
        widget.parentContext,
        render: (onProgress, isCancelled) => _renderAndSaveChatImageSegments(
          widget.parentContext,
          widget.conversation,
          widget.messages,
          showThinkingAndToolCards: _showThinkingAndToolCards,
          expandThinkingContent: _expandThinkingContent,
          onProgress: onProgress,
          isCancelled: isCancelled,
        ),
        beforePreview: () async {
          if (mounted) await Navigator.of(context).maybePop();
        },
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    return DraggableScrollableSheet(
      controller: _ctrl,
      expand: false,
      initialChildSize: 0.55,
      maxChildSize: 0.70,
      minChildSize: 0.3,
      builder: (c, sc) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: cs.onSurface.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Center(
              child: Text(
                l10n.messageExportSheetFormatTitle,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: ListView(
                controller: sc,
                children: [
                  _ExportOptionTile(
                    icon: Lucide.BookOpenText,
                    title: l10n.messageExportSheetMarkdown,
                    subtitle: l10n.messageExportSheetBatchMarkdownSubtitle,
                    onTap: _exporting
                        ? null
                        : () {
                            _onExportMarkdown();
                          },
                  ),
                  _ExportOptionTile(
                    icon: Lucide.FileText,
                    title: l10n.messageExportSheetPlainText,
                    subtitle: l10n.messageExportSheetBatchTxtSubtitle,
                    onTap: _exporting
                        ? null
                        : () {
                            _onExportTxt();
                          },
                  ),
                  _ExportOptionTile(
                    icon: Lucide.Image,
                    title: l10n.messageExportSheetExportImage,
                    subtitle: l10n.messageExportSheetBatchExportImageSubtitle,
                    onTap: _exporting
                        ? null
                        : () {
                            _onExportImage();
                          },
                  ),
                  _ExportOptionTile(
                    icon: Lucide.Layers,
                    title: l10n.messageExportSheetSegmentedImage,
                    subtitle: l10n.messageExportSheetSegmentedImageSubtitle,
                    onTap: _exporting
                        ? null
                        : () {
                            _onExportSegmentedImage();
                          },
                  ),
                  const SizedBox(height: 8),
                  // Image export options
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Column(
                      children: [
                        _buildSwitchRow(
                          context,
                          title:
                              l10n.messageExportSheetShowThinkingAndToolCards,
                          value: _showThinkingAndToolCards,
                          onChanged: (v) {
                            setState(() {
                              _showThinkingAndToolCards = v;
                              if (!v) {
                                _expandThinkingContent = false;
                              }
                            });
                          },
                        ),
                        _buildSwitchRow(
                          context,
                          title: l10n.messageExportSheetShowThinkingContent,
                          value: _expandThinkingContent,
                          onChanged: _showThinkingAndToolCards
                              ? (v) {
                                  setState(() {
                                    _expandThinkingContent = v;
                                  });
                                }
                              : null,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSwitchRow(
    BuildContext context, {
    required String title,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) {
    final cs = Theme.of(context).colorScheme;
    final isEnabled = onChanged != null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontSize: 14,
                color: isEnabled ? cs.onSurface : cs.onSurface.withOpacity(0.4),
              ),
            ),
          ),
          IosSwitch(
            value: value,
            onChanged: onChanged,
            activeColor: cs.primary,
          ),
        ],
      ),
    );
  }
}

class _ExportSheetState extends State<_ExportSheet> {
  final DraggableScrollableController _ctrl = DraggableScrollableController();
  bool _exporting = false;
  bool _showThinkingAndToolCards = false;
  bool _expandThinkingContent = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  String _formatTime(BuildContext context, DateTime time) {
    final l10n = AppLocalizations.of(context)!;
    final fmt = DateFormat(l10n.messageExportSheetDateTimeWithSecondsPattern);
    return fmt.format(time);
  }

  Future<void> _onExportMarkdown() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final ctx = context;
      final msg = widget.message;
      final service = ctx.read<ChatService>();
      final convo = service.getConversation(msg.conversationId);
      final l10n = AppLocalizations.of(ctx)!;
      final title = ((convo?.title ?? '').trim().isNotEmpty)
          ? (convo?.title ?? '')
          : l10n.messageExportSheetDefaultTitle;
      final time = _formatTime(ctx, msg.timestamp);

      final parsed = _parseContent(msg.content);

      final buf = StringBuffer();
      buf.writeln('# $title');
      buf.writeln('');
      buf.writeln('> $time · ${_getRoleName(ctx, msg)}');
      buf.writeln('');
      if (parsed.text.isNotEmpty) {
        buf.writeln(parsed.text);
        buf.writeln('');
      }
      // Inline images as data URLs where possible
      for (final p in parsed.images) {
        final fixed = SandboxPathResolver.fix(p);
        try {
          final f = File(fixed);
          if (await f.exists()) {
            final bytes = await f.readAsBytes();
            final b64 = base64Encode(bytes);
            final mime = _guessImageMime(fixed);
            buf.writeln('![](data:$mime;base64,$b64)');
          } else {
            buf.writeln('![image]($fixed)');
          }
        } catch (_) {
          buf.writeln('![image]($fixed)');
        }
        buf.writeln('');
      }
      // List file attachments as links (path only)
      for (final d in parsed.docs) {
        buf.writeln('- ${d.fileName}  `(${d.mime})`');
      }
      final review = _answerReviewMarkdown(ctx, service, msg);
      if (review.isNotEmpty) buf.writeln(review);

      final filename =
          'chat-export-${DateTime.now().millisecondsSinceEpoch}.md';

      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        // Desktop: choose save location
        final String? savePath = await FilePicker.platform.saveFile(
          dialogTitle: AppLocalizations.of(context)!.backupPageExportToFile,
          fileName: filename,
          type: FileType.custom,
          allowedExtensions: const ['md'],
        );
        if (savePath != null) {
          await File(savePath).parent.create(recursive: true);
          await File(savePath).writeAsString(buf.toString());
          if (mounted) {
            final l10n = AppLocalizations.of(context)!;
            showAppSnackBar(
              context,
              message: l10n.messageExportSheetExportedAs(p.basename(savePath)),
              type: NotificationType.success,
            );
          }
        }
      } else {
        // Mobile: use FilePicker with bytes parameter (required on Android & iOS)
        final contentBytes = utf8.encode(buf.toString());
        final String? savePath = await FilePicker.platform.saveFile(
          dialogTitle: AppLocalizations.of(context)!.backupPageExportToFile,
          fileName: filename,
          type: FileType.custom,
          allowedExtensions: const ['md'],
          bytes: Uint8List.fromList(contentBytes),
        );
        if (savePath != null) {
          if (mounted) {
            final l10n = AppLocalizations.of(context)!;
            showAppSnackBar(
              context,
              message: l10n.messageExportSheetExportedAs(p.basename(savePath)),
              type: NotificationType.success,
            );
          }
        }
      }
    } catch (e) {
      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        showAppSnackBar(
          context,
          message: l10n.messageExportSheetExportFailed('$e'),
          type: NotificationType.error,
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _onExportTxt() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final ctx = context;
      final msg = widget.message;
      final service = ctx.read<ChatService>();
      final convo = service.getConversation(msg.conversationId);
      final l10n = AppLocalizations.of(ctx)!;
      final title = ((convo?.title ?? '').trim().isNotEmpty)
          ? (convo?.title ?? '')
          : l10n.messageExportSheetDefaultTitle;
      final time = _formatTime(ctx, msg.timestamp);

      final parsed = _parseContent(msg.content);

      final buf = StringBuffer();
      buf.writeln(title);
      buf.writeln('');
      buf.writeln('$time · ${_getRoleName(ctx, msg)}');
      buf.writeln('');
      if (parsed.text.isNotEmpty) {
        buf.writeln(parsed.text);
        buf.writeln('');
      }
      for (final d in parsed.docs) {
        buf.writeln('- ${d.fileName} (${d.mime})');
      }
      final review = _answerReviewMarkdown(ctx, service, msg);
      if (review.isNotEmpty) buf.writeln(review);

      final filename =
          'chat-export-${DateTime.now().millisecondsSinceEpoch}.txt';

      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        // Desktop: choose save location
        final String? savePath = await FilePicker.platform.saveFile(
          dialogTitle: AppLocalizations.of(context)!.backupPageExportToFile,
          fileName: filename,
          type: FileType.custom,
          allowedExtensions: const ['txt'],
        );
        if (savePath != null) {
          await File(savePath).parent.create(recursive: true);
          await File(savePath).writeAsString(buf.toString());
          if (mounted) {
            final l10n = AppLocalizations.of(context)!;
            showAppSnackBar(
              context,
              message: l10n.messageExportSheetExportedAs(p.basename(savePath)),
              type: NotificationType.success,
            );
          }
        }
      } else {
        // Mobile: use FilePicker with bytes parameter (required on Android & iOS)
        final contentBytes = utf8.encode(buf.toString());
        final String? savePath = await FilePicker.platform.saveFile(
          dialogTitle: AppLocalizations.of(context)!.backupPageExportToFile,
          fileName: filename,
          type: FileType.custom,
          allowedExtensions: const ['txt'],
          bytes: Uint8List.fromList(contentBytes),
        );
        if (savePath != null) {
          if (mounted) {
            final l10n = AppLocalizations.of(context)!;
            showAppSnackBar(
              context,
              message: l10n.messageExportSheetExportedAs(p.basename(savePath)),
              type: NotificationType.success,
            );
          }
        }
      }
    } catch (e) {
      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        showAppSnackBar(
          context,
          message: l10n.messageExportSheetExportFailed('$e'),
          type: NotificationType.error,
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _onExportImage() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    final tilingEnabled = widget.parentContext
        .read<SettingsProvider>()
        .longImageTilingEnabled;
    try {
      await _runImageExport(
        widget.parentContext,
        render: (onProgress, isCancelled) => _renderAndSaveMessageImage(
          widget.parentContext,
          widget.message,
          showThinkingAndToolCards: _showThinkingAndToolCards,
          expandThinkingContent: _expandThinkingContent,
          tilingEnabled: tilingEnabled,
          onProgress: onProgress,
          isCancelled: isCancelled,
        ),
        beforePreview: () async {
          // Close the sheet before opening the preview, otherwise maybePop
          // would dismiss the preview itself.
          if (mounted) await Navigator.of(context).maybePop();
        },
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _onExportSegmentedImage() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      await _runSegmentedImageExport(
        widget.parentContext,
        render: (onProgress, isCancelled) => _renderAndSaveMessageImageSegments(
          widget.parentContext,
          widget.message,
          showThinkingAndToolCards: _showThinkingAndToolCards,
          expandThinkingContent: _expandThinkingContent,
          onProgress: onProgress,
          isCancelled: isCancelled,
        ),
        beforePreview: () async {
          if (mounted) await Navigator.of(context).maybePop();
        },
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    return DraggableScrollableSheet(
      controller: _ctrl,
      expand: false,
      initialChildSize: 0.55,
      maxChildSize: 0.70,
      minChildSize: 0.3,
      builder: (c, sc) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: cs.onSurface.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Center(
              child: Text(
                l10n.messageExportSheetFormatTitle,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: ListView(
                controller: sc,
                children: [
                  _ExportOptionTile(
                    icon: Lucide.BookOpenText,
                    title: l10n.messageExportSheetMarkdown,
                    subtitle: l10n.messageExportSheetSingleMarkdownSubtitle,
                    onTap: _exporting
                        ? null
                        : () {
                            _onExportMarkdown();
                          },
                  ),
                  _ExportOptionTile(
                    icon: Lucide.FileText,
                    title: l10n.messageExportSheetPlainText,
                    subtitle: l10n.messageExportSheetSingleTxtSubtitle,
                    onTap: _exporting
                        ? null
                        : () {
                            _onExportTxt();
                          },
                  ),
                  _ExportOptionTile(
                    icon: Lucide.Image,
                    title: l10n.messageExportSheetExportImage,
                    subtitle: l10n.messageExportSheetSingleExportImageSubtitle,
                    onTap: _exporting
                        ? null
                        : () {
                            _onExportImage();
                          },
                  ),
                  _ExportOptionTile(
                    icon: Lucide.Layers,
                    title: l10n.messageExportSheetSegmentedImage,
                    subtitle: l10n.messageExportSheetSegmentedImageSubtitle,
                    onTap: _exporting
                        ? null
                        : () {
                            _onExportSegmentedImage();
                          },
                  ),
                  const SizedBox(height: 8),
                  // Image export options
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Column(
                      children: [
                        _buildSwitchRow(
                          context,
                          title:
                              l10n.messageExportSheetShowThinkingAndToolCards,
                          value: _showThinkingAndToolCards,
                          onChanged: (v) {
                            setState(() {
                              _showThinkingAndToolCards = v;
                              if (!v) {
                                _expandThinkingContent = false;
                              }
                            });
                          },
                        ),
                        _buildSwitchRow(
                          context,
                          title: l10n.messageExportSheetShowThinkingContent,
                          value: _expandThinkingContent,
                          onChanged: _showThinkingAndToolCards
                              ? (v) {
                                  setState(() {
                                    _expandThinkingContent = v;
                                  });
                                }
                              : null,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSwitchRow(
    BuildContext context, {
    required String title,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) {
    final cs = Theme.of(context).colorScheme;
    final isEnabled = onChanged != null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontSize: 14,
                color: isEnabled ? cs.onSurface : cs.onSurface.withOpacity(0.4),
              ),
            ),
          ),
          IosSwitch(
            value: value,
            onChanged: onChanged,
            activeColor: cs.primary,
          ),
        ],
      ),
    );
  }

  // shared widgets and helpers moved to top-level
}

class _ExportedMessageCard extends StatelessWidget {
  const _ExportedMessageCard({
    required this.message,
    required this.title,
    required this.cs,
    required this.chatFontScale,
    this.showThinkingAndToolCards = false,
    this.expandThinkingContent = false,
    this.isDesktop = false,
  });
  final ChatMessage message;
  final String title;
  final ColorScheme cs;
  final double chatFontScale;
  final bool showThinkingAndToolCards;
  final bool expandThinkingContent;
  final bool isDesktop;

  @override
  Widget build(BuildContext context) {
    final isAssistant = message.role == 'assistant';
    final headerFg = cs.onSurface;
    final bubbleBg = cs.primary.withOpacity(0.08);
    final bubbleFg = cs.onSurface;
    final time = DateFormat('yyyy-MM-dd HH:mm').format(message.timestamp);

    // Desktop uses smaller font sizes for better proportions
    final double titleFontSize = isDesktop ? 15.0 : 18.0;
    final double timeFontSize = isDesktop ? 10.0 : 12.0;
    final double contentFontSize = isDesktop ? 13.0 : 15.7;

    // Extract thinking content and tool parts if enabled
    List<Map<String, dynamic>> reasoningSegments = [];
    String messageContent = message.content;
    List<ToolUIPart> toolParts = [];
    AnswerReviewRecord? reviewRecord;

    if (showThinkingAndToolCards && isAssistant) {
      // Get tool events first
      try {
        final chatService = context.read<ChatService>();
        reviewRecord = chatService.getAnswerReview(message.id);
        final events = chatService.getToolEvents(message.id);
        if (events.isNotEmpty) {
          toolParts = events
              .map(
                (e) => ToolUIPart(
                  id: (e['id'] ?? '').toString(),
                  toolName: (e['name'] ?? '').toString(),
                  arguments:
                      (e['arguments'] as Map?)?.cast<String, dynamic>() ??
                      const <String, dynamic>{},
                  content: (e['content']?.toString().isNotEmpty == true)
                      ? e['content'].toString()
                      : null,
                  loading: !(e['content']?.toString().isNotEmpty == true),
                ),
              )
              .toList();
        }
      } catch (_) {}

      // Check if message has reasoningSegmentsJson (multiple thinking segments with toolStartIndex)
      if (message.reasoningSegmentsJson != null &&
          message.reasoningSegmentsJson!.isNotEmpty) {
        try {
          final segments = _deserializeReasoningSegments(
            message.reasoningSegmentsJson!,
          );
          reasoningSegments = segments;
        } catch (_) {}
      }

      // If no segments, fall back to extracting from content or reasoningText
      if (reasoningSegments.isEmpty) {
        // Extract thinking content from <think> tags
        final thinkingMatches = thinkingRegex.allMatches(message.content);
        if (thinkingMatches.isNotEmpty) {
          final texts = thinkingMatches
              .map((m) => (m.group(1) ?? '').trim())
              .where((s) => s.isNotEmpty)
              .toList();
          // Create segments with sequential toolStartIndex
          for (int i = 0; i < texts.length; i++) {
            reasoningSegments.add({
              'text': texts[i],
              'toolStartIndex': 0, // All tools at the end for inline think
            });
          }
          // Remove thinking tags from message content
          messageContent = message.content.replaceAll(thinkingRegex, '').trim();
        }
        // Also check reasoningText field
        else if (message.reasoningText != null &&
            message.reasoningText!.isNotEmpty) {
          reasoningSegments.add({
            'text': message.reasoningText!,
            'toolStartIndex': 0,
          });
        }
      }
    }

    final parsed = _parseContent(messageContent);
    final mdText = StringBuffer();
    if (parsed.text.isNotEmpty) mdText.writeln(_softBreakMd(parsed.text));
    for (final p in parsed.images) {
      mdText.writeln('\n![](${SandboxPathResolver.fix(p)})\n');
    }
    for (final d in parsed.docs) {
      mdText.writeln('\n- ${d.fileName}  `(${d.mime})`');
    }

    final Widget contentWidget = (mdText.toString().trim().isNotEmpty)
        ? DefaultTextStyle.merge(
            style: TextStyle(fontSize: contentFontSize, height: 1.5),
            child: MarkdownSurfaceScope(
              surface: MarkdownSurface.fromColorScheme(cs),
              child: MarkdownWithCodeHighlight(
                text: mdText.toString(),
                renderPolicy: isAssistant
                    ? MarkdownRenderPolicy.full
                    : MarkdownRenderPolicy.standard,
              ),
            ),
          )
        : Text('—', style: TextStyle(color: bubbleFg.withOpacity(0.5)));

    // Desktop uses smaller margins and paddings
    final double containerMargin = isDesktop ? 12.0 : 16.0;
    final double containerPadding = isDesktop ? 12.0 : 16.0;

    return MediaQuery(
      // Respect chat font scale for export rendering
      data: MediaQuery.of(context).copyWith(
        textScaleFactor: MediaQuery.of(context).textScaleFactor * chatFontScale,
      ),
      child: Container(
        margin: EdgeInsets.all(containerMargin),
        padding: EdgeInsets.all(containerPadding),
        decoration: BoxDecoration(
          color: cs.background,
          borderRadius: BorderRadius.circular(16),
          // removed outer border per UX
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Title (no icon, no bordered container)
            Text(
              title,
              style: TextStyle(
                fontSize: titleFontSize,
                fontWeight: FontWeight.w700,
                color: headerFg.withOpacity(0.95),
              ),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
            const SizedBox(height: 2),
            // Timestamp under title, aligned with title
            Text(
              time,
              style: TextStyle(
                fontSize: timeFontSize,
                color: headerFg.withOpacity(0.6),
              ),
            ),
            SizedBox(height: isDesktop ? 10.0 : 12.0),
            // Message body styled like chat
            if (isAssistant) ...[
              _AssistantHeader(message: message, isDesktop: isDesktop),
              const SizedBox(height: 8),
              // Build mixed content: reasoning segments and tool cards按 toolStartIndex 混合显示
              ...() {
                final List<Widget> mixedContent = [];
                if (reasoningSegments.isNotEmpty) {
                  for (int i = 0; i < reasoningSegments.length; i++) {
                    final seg = reasoningSegments[i];
                    final text = seg['text'] as String? ?? '';

                    // Add the reasoning segment (if any text)
                    if (text.isNotEmpty) {
                      mixedContent.add(
                        _ExportThinkingCard(
                          thinkingText: text,
                          cs: cs,
                          expanded: expandThinkingContent,
                          isDesktop: isDesktop,
                        ),
                      );
                      mixedContent.add(SizedBox(height: isDesktop ? 6.0 : 8.0));
                    }

                    // Determine tool range mapped to this segment: [start, end)
                    int start = (seg['toolStartIndex'] as int?) ?? 0;
                    final int end = (i < reasoningSegments.length - 1)
                        ? (reasoningSegments[i + 1]['toolStartIndex']
                                  as int?) ??
                              toolParts.length
                        : toolParts.length;

                    // Clamp to bounds and ensure non-decreasing
                    if (start < 0) start = 0;
                    if (start > toolParts.length) start = toolParts.length;
                    final int clampedEnd = end.clamp(start, toolParts.length);

                    for (int k = start; k < clampedEnd; k++) {
                      // Hide builtin_search tool cards
                      if (toolParts[k].toolName == 'builtin_search') continue;
                      mixedContent.add(
                        _ExportToolCard(
                          part: toolParts[k],
                          cs: cs,
                          isDesktop: isDesktop,
                        ),
                      );
                      mixedContent.add(SizedBox(height: isDesktop ? 6.0 : 8.0));
                    }
                  }
                } else if (toolParts.isNotEmpty) {
                  // No reasoning segments but have tool cards - show all tool cards
                  for (final toolPart in toolParts) {
                    if (toolPart.toolName == 'builtin_search') continue;
                    mixedContent.add(
                      _ExportToolCard(
                        part: toolPart,
                        cs: cs,
                        isDesktop: isDesktop,
                      ),
                    );
                    mixedContent.add(SizedBox(height: isDesktop ? 6.0 : 8.0));
                  }
                }
                if (reviewRecord != null) {
                  mixedContent.add(
                    AnswerReviewCard(
                      data: AnswerReviewViewData(
                        report: reviewRecord!.report,
                        draft: reviewRecord!.draft,
                        finalText: message.content,
                        draftTruncated: reviewRecord!.report.draftTruncated,
                      ),
                      initiallyExpanded: true,
                    ),
                  );
                  mixedContent.add(SizedBox(height: isDesktop ? 6.0 : 8.0));
                }
                return mixedContent;
              }(),
              contentWidget,
            ] else ...[
              Align(
                alignment: Alignment.centerRight,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: isDesktop ? 600.0 : 680.0,
                  ),
                  child: Container(
                    padding: EdgeInsets.all(isDesktop ? 10.0 : 12.0),
                    decoration: BoxDecoration(
                      color: bubbleBg,
                      borderRadius: BorderRadius.circular(
                        isDesktop ? 12.0 : 16.0,
                      ),
                    ),
                    child: contentWidget,
                  ),
                ),
              ),
            ],
            SizedBox(height: isDesktop ? 12.0 : 16.0),
            _ExportDisclaimer(isDesktop: isDesktop),
          ],
        ),
      ),
    );
  }

  // Helper to deserialize reasoning segments
  List<Map<String, dynamic>> _deserializeReasoningSegments(String json) {
    try {
      final decoded = jsonDecode(json);
      if (decoded is List) {
        return decoded.cast<Map<String, dynamic>>();
      }
    } catch (_) {}
    return [];
  }
}

class _ExportedChatImage extends StatelessWidget {
  const _ExportedChatImage({
    required this.conversationTitle,
    required this.cs,
    required this.chatFontScale,
    required this.messages,
    required this.timestamp,
    this.showThinkingAndToolCards = false,
    this.expandThinkingContent = false,
    this.isDesktop = false,
  });
  final String conversationTitle;
  final ColorScheme cs;
  final double chatFontScale;
  final List<ChatMessage> messages;
  final DateTime timestamp;
  final bool showThinkingAndToolCards;
  final bool expandThinkingContent;
  final bool isDesktop;

  @override
  Widget build(BuildContext context) {
    // Desktop uses smaller font sizes for better proportions
    final double titleFontSize = isDesktop ? 15.0 : 18.0;
    final double timeFontSize = isDesktop ? 10.0 : 12.0;
    final double containerMargin = isDesktop ? 5.0 : 6.0;
    final double containerPadding = isDesktop ? 5.0 : 6.0;

    return MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaleFactor: MediaQuery.of(context).textScaleFactor * chatFontScale,
      ),
      child: ClipRect(
        child: Container(
          margin: EdgeInsets.all(containerMargin),
          padding: EdgeInsets.all(containerPadding),
          decoration: BoxDecoration(
            color: cs.background,
            borderRadius: BorderRadius.circular(isDesktop ? 12.0 : 16.0),
            // removed outer border per UX
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Title (no icon, no bordered container)
              Text(
                conversationTitle,
                style: TextStyle(
                  fontSize: titleFontSize,
                  fontWeight: FontWeight.w700,
                  color: cs.onSurface.withOpacity(0.95),
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
              const SizedBox(height: 2),
              // Timestamp under title, aligned with title
              Text(
                DateFormat('yyyy-MM-dd HH:mm').format(timestamp),
                style: TextStyle(
                  fontSize: timeFontSize,
                  color: cs.onSurface.withOpacity(0.6),
                ),
              ),
              SizedBox(height: isDesktop ? 10.0 : 12.0),
              for (final m in messages) ...[
                _ExportedBubble(
                  message: m,
                  cs: cs,
                  showThinkingAndToolCards: showThinkingAndToolCards,
                  expandThinkingContent: expandThinkingContent,
                  isDesktop: isDesktop,
                ),
                SizedBox(height: isDesktop ? 6.0 : 8.0),
              ],
              SizedBox(height: isDesktop ? 10.0 : 12.0),
              _ExportDisclaimer(isDesktop: isDesktop),
            ],
          ),
        ),
      ),
    );
  }
}

class _ExportedBubble extends StatelessWidget {
  const _ExportedBubble({
    required this.message,
    required this.cs,
    this.showThinkingAndToolCards = false,
    this.expandThinkingContent = false,
    this.isDesktop = false,
  });
  final ChatMessage message;
  final ColorScheme cs;
  final bool showThinkingAndToolCards;
  final bool expandThinkingContent;
  final bool isDesktop;

  @override
  Widget build(BuildContext context) {
    final isAssistant = message.role == 'assistant';
    final bubbleBg = cs.primary.withOpacity(0.08);
    final bubbleFg = cs.onSurface;

    // Desktop uses smaller font sizes for better proportions
    final double contentFontSize = isDesktop ? 13.0 : 15.7;

    // Extract thinking content and tool parts if enabled
    List<Map<String, dynamic>> reasoningSegments = [];
    String messageContent = message.content;
    List<ToolUIPart> toolParts = [];
    AnswerReviewRecord? reviewRecord;

    if (showThinkingAndToolCards && isAssistant) {
      // Get tool events first
      try {
        final chatService = context.read<ChatService>();
        reviewRecord = chatService.getAnswerReview(message.id);
        final events = chatService.getToolEvents(message.id);
        if (events.isNotEmpty) {
          toolParts = events
              .map(
                (e) => ToolUIPart(
                  id: (e['id'] ?? '').toString(),
                  toolName: (e['name'] ?? '').toString(),
                  arguments:
                      (e['arguments'] as Map?)?.cast<String, dynamic>() ??
                      const <String, dynamic>{},
                  content: (e['content']?.toString().isNotEmpty == true)
                      ? e['content'].toString()
                      : null,
                  loading: !(e['content']?.toString().isNotEmpty == true),
                ),
              )
              .toList();
        }
      } catch (_) {}

      // Check if message has reasoningSegmentsJson (multiple thinking segments with toolStartIndex)
      if (message.reasoningSegmentsJson != null &&
          message.reasoningSegmentsJson!.isNotEmpty) {
        try {
          final segments = _deserializeReasoningSegments(
            message.reasoningSegmentsJson!,
          );
          reasoningSegments = segments;
        } catch (_) {}
      }

      // If no segments, fall back to extracting from content or reasoningText
      if (reasoningSegments.isEmpty) {
        // Extract thinking content from <think> tags
        final thinkingMatches = thinkingRegex.allMatches(message.content);
        if (thinkingMatches.isNotEmpty) {
          final texts = thinkingMatches
              .map((m) => (m.group(1) ?? '').trim())
              .where((s) => s.isNotEmpty)
              .toList();
          // Create segments with sequential toolStartIndex
          for (int i = 0; i < texts.length; i++) {
            reasoningSegments.add({
              'text': texts[i],
              'toolStartIndex': 0, // All tools at the end for inline think
            });
          }
          // Remove thinking tags from message content
          messageContent = message.content.replaceAll(thinkingRegex, '').trim();
        }
        // Also check reasoningText field
        else if (message.reasoningText != null &&
            message.reasoningText!.isNotEmpty) {
          reasoningSegments.add({
            'text': message.reasoningText!,
            'toolStartIndex': 0,
          });
        }
      }
    }

    final parsed = _parseContent(messageContent);
    final mdText = StringBuffer();
    if (parsed.text.isNotEmpty) mdText.writeln(_softBreakMd(parsed.text));
    for (final p in parsed.images) {
      mdText.writeln('\n![](${SandboxPathResolver.fix(p)})\n');
    }
    for (final d in parsed.docs) {
      mdText.writeln('\n- ${d.fileName}  `(${d.mime})`');
    }
    final Widget contentWidget = (mdText.toString().trim().isNotEmpty)
        ? DefaultTextStyle.merge(
            style: TextStyle(fontSize: contentFontSize, height: 1.5),
            child: MarkdownSurfaceScope(
              surface: MarkdownSurface.fromColorScheme(cs),
              child: MarkdownWithCodeHighlight(
                text: mdText.toString(),
                renderPolicy: isAssistant
                    ? MarkdownRenderPolicy.full
                    : MarkdownRenderPolicy.standard,
              ),
            ),
          )
        : Text('—', style: TextStyle(color: bubbleFg.withOpacity(0.5)));

    if (isAssistant) {
      // Build mixed content: reasoning segments and tool cards按 toolStartIndex 混合显示
      final List<Widget> mixedContent = [];

      if (reasoningSegments.isNotEmpty) {
        for (int i = 0; i < reasoningSegments.length; i++) {
          final seg = reasoningSegments[i];
          final text = seg['text'] as String? ?? '';

          // Add the reasoning segment (if any text)
          if (text.isNotEmpty) {
            mixedContent.add(
              _ExportThinkingCard(
                thinkingText: text,
                cs: cs,
                expanded: expandThinkingContent,
                isDesktop: isDesktop,
              ),
            );
            mixedContent.add(SizedBox(height: isDesktop ? 6.0 : 8.0));
          }

          // Determine tool range mapped to this segment: [start, end)
          int start = (seg['toolStartIndex'] as int?) ?? 0;
          final int end = (i < reasoningSegments.length - 1)
              ? (reasoningSegments[i + 1]['toolStartIndex'] as int?) ??
                    toolParts.length
              : toolParts.length;

          // Clamp to bounds and ensure non-decreasing
          if (start < 0) start = 0;
          if (start > toolParts.length) start = toolParts.length;
          final int clampedEnd = end.clamp(start, toolParts.length);

          for (int k = start; k < clampedEnd; k++) {
            // Hide builtin_search tool cards
            if (toolParts[k].toolName == 'builtin_search') continue;
            mixedContent.add(
              _ExportToolCard(part: toolParts[k], cs: cs, isDesktop: isDesktop),
            );
            mixedContent.add(SizedBox(height: isDesktop ? 6.0 : 8.0));
          }
        }
      } else if (toolParts.isNotEmpty) {
        // No reasoning segments but have tool cards - show all tool cards
        for (final toolPart in toolParts) {
          if (toolPart.toolName == 'builtin_search') continue;
          mixedContent.add(
            _ExportToolCard(part: toolPart, cs: cs, isDesktop: isDesktop),
          );
          mixedContent.add(SizedBox(height: isDesktop ? 6.0 : 8.0));
        }
      }
      if (reviewRecord != null) {
        mixedContent.add(
          AnswerReviewCard(
            data: AnswerReviewViewData(
              report: reviewRecord!.report,
              draft: reviewRecord!.draft,
              finalText: message.content,
              draftTruncated: reviewRecord!.report.draftTruncated,
            ),
            initiallyExpanded: true,
          ),
        );
        mixedContent.add(SizedBox(height: isDesktop ? 6.0 : 8.0));
      }

      return Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: isDesktop ? 680.0 : 780.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _AssistantHeader(message: message, isDesktop: isDesktop),
              SizedBox(height: isDesktop ? 6.0 : 8.0),
              ...mixedContent,
              contentWidget,
            ],
          ),
        ),
      );
    }
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: isDesktop ? 600.0 : 680.0),
        child: Container(
          padding: EdgeInsets.all(isDesktop ? 10.0 : 12.0),
          decoration: BoxDecoration(
            color: bubbleBg,
            borderRadius: BorderRadius.circular(isDesktop ? 12.0 : 16.0),
          ),
          child: contentWidget,
        ),
      ),
    );
  }

  // Helper to deserialize reasoning segments
  List<Map<String, dynamic>> _deserializeReasoningSegments(String json) {
    try {
      final decoded = jsonDecode(json);
      if (decoded is List) {
        return decoded.cast<Map<String, dynamic>>();
      }
    } catch (_) {}
    return [];
  }
}

// Assistant header (icon + name), mirroring chat style
class _AssistantHeader extends StatelessWidget {
  const _AssistantHeader({required this.message, this.isDesktop = false});
  final ChatMessage message;
  final bool isDesktop;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final assistant = context.read<AssistantProvider>().currentAssistant;
    final useAssist = (assistant?.useAssistantAvatar == true);
    final name = () {
      if (useAssist && (assistant?.name.trim().isNotEmpty ?? false)) {
        return assistant!.name.trim();
      }
      return _modelDisplayName(context, message) ??
          AppLocalizations.of(context)!.messageExportSheetAssistant;
    }();

    // Desktop uses smaller icon sizes
    final double iconSize = isDesktop ? 22.0 : 28.0;
    final double nameFontSize = isDesktop ? 11.0 : 13.0;

    final Widget leading = useAssist
        ? _AssistantAvatarSmall(assistant: assistant, size: iconSize)
        : _ModelIconSmall(
            providerKey: message.providerId,
            modelId: message.modelId,
            size: iconSize,
          );

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        leading,
        SizedBox(width: isDesktop ? 6.0 : 8.0),
        Text(
          name,
          style: TextStyle(
            fontSize: nameFontSize,
            fontWeight: FontWeight.w500,
            color: cs.onSurface.withOpacity(0.7),
          ),
        ),
      ],
    );
  }
}

class _ModelIconSmall extends StatelessWidget {
  const _ModelIconSmall({
    required this.providerKey,
    required this.modelId,
    this.size = 28.0,
  });
  final String? providerKey;
  final String? modelId;
  final double size;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (providerKey == null || modelId == null) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: cs.secondary.withOpacity(0.1),
          shape: BoxShape.circle,
        ),
        child: Icon(Lucide.Bot, size: size * 0.64, color: cs.secondary),
      );
    }
    String? asset = BrandAssets.assetForName(modelId!);
    asset ??= BrandAssets.assetForName(providerKey!);
    Widget inner;
    if (asset != null) {
      if (asset.endsWith('.svg')) {
        final isColorful = asset.contains('color');
        final ColorFilter? tint =
            (Theme.of(context).brightness == Brightness.dark && !isColorful)
            ? const ColorFilter.mode(Colors.white, BlendMode.srcIn)
            : null;
        inner = SvgPicture.asset(
          asset,
          width: size * 0.5,
          height: size * 0.5,
          colorFilter: tint,
        );
      } else {
        inner = Image.asset(
          asset,
          width: size * 0.5,
          height: size * 0.5,
          fit: BoxFit.contain,
        );
      }
    } else {
      inner = Text(
        modelId!.isNotEmpty ? modelId!.characters.first.toUpperCase() : '?',
        style: TextStyle(
          color: cs.primary,
          fontWeight: FontWeight.w700,
          fontSize: size * 0.43,
        ),
      );
    }
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? Colors.white10
            : cs.primary.withOpacity(0.1),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: SizedBox(
        width: size * 0.64,
        height: size * 0.64,
        child: Center(
          child: inner is SvgPicture || inner is Image
              ? inner
              : FittedBox(child: inner),
        ),
      ),
    );
  }
}

class _AssistantAvatarSmall extends StatelessWidget {
  const _AssistantAvatarSmall({required this.assistant, this.size = 28.0});
  final Assistant? assistant;
  final double size;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final av = (assistant?.avatar ?? '').trim();
    if (av.isNotEmpty) {
      if (av.startsWith('http')) {
        return FutureBuilder<String?>(
          future: AvatarCache.getPath(av),
          builder: (ctx, snap) {
            final p = snap.data;
            if (p != null && File(p).existsSync()) {
              return ClipOval(
                child: Image.file(
                  File(p),
                  width: size,
                  height: size,
                  fit: BoxFit.cover,
                ),
              );
            }
            return ClipOval(
              child: Image.network(
                av,
                width: size,
                height: size,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) =>
                    _assistantInitial(cs, assistant?.name ?? ''),
              ),
            );
          },
        );
      }
      if (av.startsWith('/') || av.contains(':')) {
        final fixed = SandboxPathResolver.fix(av);
        return ClipOval(
          child: Image.file(
            File(fixed),
            width: size,
            height: size,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) =>
                _assistantInitial(cs, assistant?.name ?? ''),
          ),
        );
      }
      // treat as emoji or single char label
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: cs.primary.withOpacity(0.1),
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Text(
          av.characters.take(1).toString(),
          style: TextStyle(fontSize: size * 0.57),
        ),
      );
    }
    return _assistantInitial(cs, assistant?.name ?? '');
  }

  Widget _assistantInitial(ColorScheme cs, String name) {
    final ch = name.trim().isNotEmpty
        ? name.characters.first.toUpperCase()
        : 'A';
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: cs.primary.withOpacity(0.1),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        ch,
        style: TextStyle(
          color: cs.primary,
          fontWeight: FontWeight.w700,
          fontSize: size * 0.5,
        ),
      ),
    );
  }
}

class _ExportDisclaimer extends StatelessWidget {
  const _ExportDisclaimer({this.isDesktop = false});
  final bool isDesktop;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = AppLocalizations.of(context)!.exportDisclaimerAiGenerated;
    final double fontSize = isDesktop ? 10.0 : 12.0;
    return Center(
      child: Padding(
        padding: EdgeInsets.only(
          top: isDesktop ? 3.0 : 4.0,
          bottom: isDesktop ? 4.0 : 6.0,
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: fontSize,
            color: cs.onSurface.withOpacity(0.5),
          ),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

Future<void> _runWithExportingOverlay(
  BuildContext context,
  Future<void> Function() task, {
  ValueListenable<LongImageProgress?>? progress,
  VoidCallback? onCancel,
}) async {
  final cs = Theme.of(context).colorScheme;
  final l10n = AppLocalizations.of(context)!;
  // Show overlay first
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => Center(
      child: Material(
        color: cs.surface,
        elevation: 6,
        shadowColor: Colors.black.withOpacity(0.2),
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CupertinoActivityIndicator(radius: 16),
              const SizedBox(height: 12),
              Text(
                l10n.messageExportSheetExporting,
                style: TextStyle(
                  fontSize: 14,
                  color: cs.onSurface.withOpacity(0.8),
                ),
              ),
              if (progress != null) ...[
                const SizedBox(height: 10),
                SizedBox(
                  width: 180,
                  child: ValueListenableBuilder<LongImageProgress?>(
                    valueListenable: progress,
                    builder: (_, value, __) => Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        LinearProgressIndicator(
                          value: value?.fraction,
                          minHeight: 4,
                          borderRadius: BorderRadius.circular(2),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '${((value?.fraction ?? 0) * 100).round()}%',
                          style: TextStyle(
                            fontSize: 12,
                            color: cs.onSurface.withOpacity(0.7),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              if (onCancel != null) ...[
                const SizedBox(height: 4),
                TextButton(
                  onPressed: onCancel,
                  child: Text(MaterialLocalizations.of(ctx).cancelButtonLabel),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
  try {
    await task();
  } finally {
    Navigator.of(context, rootNavigator: true).pop();
  }
}

/// Runs an image export with progress/cancel UI and previews the result.
/// Returns true when a preview was opened.
Future<bool> _runImageExport(
  BuildContext context, {
  required Future<LongImageExportResult?> Function(
    LongImageProgressCallback? onProgress,
    bool Function()? isCancelled,
  )
  render,
  Future<void> Function()? beforePreview,
}) async {
  final progress = ValueNotifier<LongImageProgress?>(null);
  final cancel = ValueNotifier<bool>(false);
  LongImageExportResult? result;
  var cancelled = false;
  try {
    await _runWithExportingOverlay(
      context,
      () async {
        result = await render(
          (value) => progress.value = value,
          () => cancel.value,
        );
      },
      progress: progress,
      onCancel: () {
        cancel.value = true;
        progress.value = null; // avoid showing a stale percentage
      },
    );
    cancelled = cancel.value;
  } catch (e) {
    cancelled = cancel.value;
    if (!cancelled) {
      final l10n = AppLocalizations.of(context)!;
      final message = e is LongImageTooLargeException
          ? l10n.messageExportSheetImageTooLarge(e.sizeLabel)
          : l10n.messageExportSheetExportFailed('$e');
      showAppSnackBar(context, message: message, type: NotificationType.error);
    }
    return false;
  } finally {
    progress.dispose();
    cancel.dispose();
  }
  if (cancelled) return false;
  final exportResult = result;
  if (exportResult == null) {
    final l10n = AppLocalizations.of(context)!;
    showAppSnackBar(
      context,
      message: l10n.messageExportSheetExportFailed('render error'),
      type: NotificationType.error,
    );
    return false;
  }
  if (exportResult.wasDownscaled) {
    final l10n = AppLocalizations.of(context)!;
    final ratio = exportResult.effectivePixelRatio!.toStringAsFixed(1);
    showAppSnackBar(
      context,
      message: l10n.messageExportSheetImageDownscaled('${ratio}x'),
      type: NotificationType.info,
    );
  }
  if (beforePreview != null) await beforePreview();
  try {
    await showImagePreviewSheet(
      context,
      file: exportResult.file,
      previewFile: exportResult.previewFile,
    );
  } finally {
    // The preview is only a display cache; the full-resolution file remains.
    final previewFile = exportResult.previewFile;
    if (previewFile != null) {
      try {
        await previewFile.delete();
      } catch (_) {}
    }
  }
  return true;
}

/// Runs a segmented image export and opens the multi-image viewer.
Future<bool> _runSegmentedImageExport(
  BuildContext context, {
  required Future<LongImageSegmentedExportResult?> Function(
    LongImageProgressCallback? onProgress,
    bool Function()? isCancelled,
  )
  render,
  Future<void> Function()? beforePreview,
}) async {
  final progress = ValueNotifier<LongImageProgress?>(null);
  final cancel = ValueNotifier<bool>(false);
  LongImageSegmentedExportResult? result;
  var cancelled = false;
  try {
    await _runWithExportingOverlay(
      context,
      () async {
        result = await render(
          (value) => progress.value = value,
          () => cancel.value,
        );
      },
      progress: progress,
      onCancel: () {
        cancel.value = true;
        progress.value = null;
      },
    );
    cancelled = cancel.value;
  } catch (e) {
    cancelled = cancel.value;
    if (!cancelled) {
      final l10n = AppLocalizations.of(context)!;
      final message = e is LongImageTooLargeException
          ? l10n.messageExportSheetImageTooLarge(e.sizeLabel)
          : l10n.messageExportSheetExportFailed('$e');
      showAppSnackBar(context, message: message, type: NotificationType.error);
    }
    return false;
  } finally {
    progress.dispose();
    cancel.dispose();
  }

  if (cancelled) return false;
  final exportResult = result;
  if (exportResult == null || exportResult.files.isEmpty) {
    final l10n = AppLocalizations.of(context)!;
    showAppSnackBar(
      context,
      message: l10n.messageExportSheetExportFailed('render error'),
      type: NotificationType.error,
    );
    return false;
  }
  if (beforePreview != null) await beforePreview();
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ImageViewerPage(
        images: exportResult.files
            .map((file) => file.path)
            .toList(growable: false),
      ),
    ),
  );
  return true;
}

class _Parsed {
  final String text;
  final List<String> images;
  final List<_DocRef> docs;
  _Parsed(this.text, this.images, this.docs);
}

class _DocRef {
  final String path;
  final String fileName;
  final String mime;
  _DocRef({required this.path, required this.fileName, required this.mime});
}

class _ExportOptionTile extends StatelessWidget {
  const _ExportOptionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final Color base = isDark
        ? cs.primary.withOpacity(0.10)
        : cs.primary.withOpacity(0.06);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: IosCardPress(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        baseColor: base,
        pressedBlendStrength: isDark ? 0.14 : 0.12,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: cs.outlineVariant.withOpacity(0.35)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 22, color: cs.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurface.withOpacity(0.75),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Simple thinking card widget for export
class _ExportThinkingCard extends StatelessWidget {
  const _ExportThinkingCard({
    required this.thinkingText,
    required this.cs,
    required this.expanded,
    this.isDesktop = false,
  });
  final String thinkingText;
  final ColorScheme cs;
  final bool expanded;
  final bool isDesktop;

  String _sanitizeThinkingText(String s) {
    // 统一换行
    s = s.replaceAll('\r\n', '\n');
    s = s.replaceAll('\r', '');

    // 去掉首尾零宽字符（模型有时会插入）
    s = s
        .replaceAll(RegExp(r'^[\u200B\u200C\u200D\uFEFF]+'), '')
        .replaceAll(RegExp(r'[\u200B\u200C\u200D\uFEFF]+$'), '');

    // 去掉**开头**的纯空白行
    s = s.replaceFirst(RegExp(r'^\s*\n+'), '');

    // 去掉**结尾**的纯空白行
    s = s.replaceFirst(RegExp(r'\n+\s*$'), '');

    return s.trim();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = cs.primaryContainer.withOpacity(isDark ? 0.25 : 0.30);
    final l10n = AppLocalizations.of(context)!;
    final cleanedText = _sanitizeThinkingText(thinkingText);

    // Desktop uses smaller sizes
    final double iconSize = isDesktop ? 14.0 : 18.0;
    final double headerFontSize = isDesktop ? 11.0 : 13.0;
    final double contentFontSize = isDesktop ? 10.5 : 12.5;
    final double borderRadius = isDesktop ? 12.0 : 16.0;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      padding: EdgeInsets.symmetric(
        horizontal: isDesktop ? 8.0 : 10.0,
        vertical: isDesktop ? 6.0 : 8.0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: isDesktop ? 6.0 : 8.0,
              vertical: isDesktop ? 4.0 : 6.0,
            ),
            child: Row(
              children: [
                SvgPicture.asset(
                  'assets/icons/deepthink.svg',
                  width: iconSize,
                  height: iconSize,
                  colorFilter: ColorFilter.mode(cs.secondary, BlendMode.srcIn),
                ),
                SizedBox(width: isDesktop ? 6.0 : 8.0),
                Text(
                  l10n.chatMessageWidgetDeepThinking,
                  style: TextStyle(
                    fontSize: headerFontSize,
                    fontWeight: FontWeight.w700,
                    color: cs.secondary,
                  ),
                ),
              ],
            ),
          ),
          // Content (if expanded)
          if (expanded)
            Padding(
              padding: EdgeInsets.fromLTRB(
                isDesktop ? 6.0 : 8.0,
                2,
                isDesktop ? 6.0 : 8.0,
                isDesktop ? 4.0 : 6.0,
              ),
              child: Text(
                cleanedText,
                style: TextStyle(
                  fontSize: contentFontSize,
                  height: 1.32,
                  leadingDistribution: TextLeadingDistribution.proportional,
                ),
                strutStyle: StrutStyle(
                  forceStrutHeight: true,
                  fontSize: contentFontSize,
                  height: 1.32,
                  leading: 0,
                ),
                textHeightBehavior: const TextHeightBehavior(
                  applyHeightToFirstAscent: false,
                  applyHeightToLastDescent: false,
                  leadingDistribution: TextLeadingDistribution.proportional,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// Tool card widget for export
class _ExportToolCard extends StatelessWidget {
  const _ExportToolCard({
    required this.part,
    required this.cs,
    this.isDesktop = false,
  });
  final ToolUIPart part;
  final ColorScheme cs;
  final bool isDesktop;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = cs.primaryContainer.withOpacity(isDark ? 0.25 : 0.30);

    // Desktop uses smaller sizes
    final double iconSize = isDesktop ? 14.0 : 18.0;
    final double fontSize = isDesktop ? 11.0 : 13.0;
    final double borderRadius = isDesktop ? 12.0 : 16.0;

    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      padding: EdgeInsets.fromLTRB(
        isDesktop ? 12.0 : 16.0,
        isDesktop ? 10.0 : 12.0,
        isDesktop ? 10.0 : 12.0,
        isDesktop ? 10.0 : 12.0,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: iconSize,
            height: iconSize,
            child: Center(
              child: Icon(
                toolIcon(part.toolName),
                size: iconSize,
                color: cs.secondary,
              ),
            ),
          ),
          SizedBox(width: isDesktop ? 8.0 : 10.0),
          Expanded(
            child: Text(
              toolDisplayName(AppLocalizations.of(context)!, part.toolName),
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: FontWeight.w700,
                color: cs.secondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Sidebar export: whole conversations (one format, one file per conversation)
// ---------------------------------------------------------------------------

enum _MultiConversationExportFormat { markdown, txt, image }

class _MultiConversationExportPanel extends StatefulWidget {
  const _MultiConversationExportPanel({
    required this.bundles,
    required this.parentContext,
    required this.inSheet,
  });

  final List<ChatExportBundle> bundles;
  final BuildContext parentContext;
  final bool inSheet;

  @override
  State<_MultiConversationExportPanel> createState() =>
      _MultiConversationExportPanelState();
}

class _MultiConversationExportPanelState
    extends State<_MultiConversationExportPanel> {
  bool _exporting = false;
  bool _showThinkingAndToolCards = false;
  bool _expandThinkingContent = false;

  Future<void> _start(_MultiConversationExportFormat format) async {
    if (_exporting) return;
    setState(() => _exporting = true);
    final parentContext = widget.parentContext;
    final bundles = widget.bundles;
    final showThinkingAndToolCards = _showThinkingAndToolCards;
    final expandThinkingContent = _expandThinkingContent;
    // Close the picker before save dialogs / the progress overlay appear.
    if (mounted) {
      final popped = await Navigator.of(context).maybePop();
      if (!popped) {
        if (mounted) setState(() => _exporting = false);
        return;
      }
    }
    await _runMultiConversationExport(
      parentContext,
      bundles,
      format: format,
      showThinkingAndToolCards: showThinkingAndToolCards,
      expandThinkingContent: expandThinkingContent,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(16, widget.inSheet ? 8 : 12, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  l10n.messageExportSheetFormatTitle,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                tooltip: l10n.mcpPageClose,
                icon: Icon(
                  Lucide.X,
                  size: 18,
                  color: cs.onSurface.withOpacity(0.75),
                ),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            l10n.messageExportSheetBatchConversationsTitle(
              widget.bundles.length,
            ),
            style: TextStyle(
              fontSize: 13,
              color: cs.onSurface.withOpacity(0.7),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _ExportOptionTile(
                  icon: Lucide.BookOpenText,
                  title: l10n.messageExportSheetMarkdown,
                  subtitle:
                      l10n.messageExportSheetBatchConversationMarkdownSubtitle,
                  onTap: _exporting
                      ? null
                      : () => _start(_MultiConversationExportFormat.markdown),
                ),
                _ExportOptionTile(
                  icon: Lucide.FileText,
                  title: l10n.messageExportSheetPlainText,
                  subtitle: l10n.messageExportSheetBatchConversationTxtSubtitle,
                  onTap: _exporting
                      ? null
                      : () => _start(_MultiConversationExportFormat.txt),
                ),
                _ExportOptionTile(
                  icon: Lucide.Image,
                  title: l10n.messageExportSheetExportImage,
                  subtitle:
                      l10n.messageExportSheetBatchConversationImageSubtitle,
                  onTap: _exporting
                      ? null
                      : () => _start(_MultiConversationExportFormat.image),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Column(
                    children: [
                      _buildSwitchRow(
                        context,
                        title: l10n.messageExportSheetShowThinkingAndToolCards,
                        value: _showThinkingAndToolCards,
                        onChanged: (v) {
                          setState(() {
                            _showThinkingAndToolCards = v;
                            if (!v) _expandThinkingContent = false;
                          });
                        },
                      ),
                      _buildSwitchRow(
                        context,
                        title: l10n.messageExportSheetShowThinkingContent,
                        value: _expandThinkingContent,
                        onChanged: _showThinkingAndToolCards
                            ? (v) => setState(() => _expandThinkingContent = v)
                            : null,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );

    if (widget.inSheet) {
      return ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
        ),
        child: content,
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(
        minWidth: 480,
        maxWidth: 720,
        maxHeight: 560,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Material(color: cs.surface, child: content),
      ),
    );
  }

  Widget _buildSwitchRow(
    BuildContext context, {
    required String title,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) {
    final cs = Theme.of(context).colorScheme;
    final isEnabled = onChanged != null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontSize: 14,
                color: isEnabled ? cs.onSurface : cs.onSurface.withOpacity(0.4),
              ),
            ),
          ),
          IosSwitch(
            value: value,
            onChanged: onChanged,
            activeColor: cs.primary,
          ),
        ],
      ),
    );
  }
}

Future<void> _runMultiConversationExport(
  BuildContext context,
  List<ChatExportBundle> bundles, {
  required _MultiConversationExportFormat format,
  required bool showThinkingAndToolCards,
  required bool expandThinkingContent,
}) async {
  if (format == _MultiConversationExportFormat.image) {
    await _exportBundlesAsImages(
      context,
      bundles,
      showThinkingAndToolCards: showThinkingAndToolCards,
      expandThinkingContent: expandThinkingContent,
    );
    return;
  }
  await _exportBundlesAsText(context, bundles, format: format);
}

Future<void> _exportBundlesAsText(
  BuildContext context,
  List<ChatExportBundle> bundles, {
  required _MultiConversationExportFormat format,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final isDesktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  final ext = format == _MultiConversationExportFormat.markdown ? 'md' : 'txt';

  // Pick the destination before doing any rendering work.
  String? directory;
  if (isDesktop) {
    try {
      directory = await FilePicker.platform.getDirectoryPath(
        dialogTitle: l10n.messageExportSheetChooseExportFolder,
      );
    } catch (e) {
      if (context.mounted) {
        showAppSnackBar(
          context,
          message: l10n.messageExportSheetExportFailed('$e'),
          type: NotificationType.error,
        );
      }
      return;
    }
    if (directory == null) return; // user cancelled
  }

  showAppSnackBar(
    context,
    message: l10n.messageExportSheetExporting,
    type: NotificationType.info,
  );

  // Build everything before touching the filesystem so a bad message cannot
  // leave a half-written batch behind.
  final payloads = <_ConversationExportPayload>[];
  try {
    for (final bundle in bundles) {
      final content = format == _MultiConversationExportFormat.markdown
          ? await _buildConversationMarkdown(context, bundle)
          : await _buildConversationTxt(context, bundle);
      payloads.add(
        _ConversationExportPayload(
          title: _conversationExportTitle(context, bundle.conversation),
          content: content,
        ),
      );
    }
  } catch (e) {
    if (context.mounted) {
      showAppSnackBar(
        context,
        message: l10n.messageExportSheetExportFailed('$e'),
        type: NotificationType.error,
      );
    }
    return;
  }

  final stamp = _exportFileTimestamp();
  var saved = 0;
  try {
    for (var i = 0; i < payloads.length; i++) {
      final payload = payloads[i];
      final name = '${_sanitizeExportFileName(payload.title)}-$stamp-$i.$ext';
      if (isDesktop && directory != null) {
        final target = File(p.join(directory, name));
        await target.parent.create(recursive: true);
        await target.writeAsString(payload.content);
        saved++;
      } else {
        final savePath = await FilePicker.platform.saveFile(
          dialogTitle: l10n.backupPageExportToFile,
          fileName: name,
          type: FileType.custom,
          allowedExtensions: [ext],
          bytes: Uint8List.fromList(utf8.encode(payload.content)),
        );
        if (savePath != null) saved++;
      }
    }
  } catch (e) {
    if (context.mounted) {
      showAppSnackBar(
        context,
        message: l10n.messageExportSheetExportFailed('$e'),
        type: NotificationType.error,
      );
    }
    return;
  }

  if (context.mounted && saved > 0) {
    showAppSnackBar(
      context,
      message: l10n.messageExportSheetExportedCount(saved),
      type: NotificationType.success,
    );
  }
}

Future<void> _exportBundlesAsImages(
  BuildContext context,
  List<ChatExportBundle> bundles, {
  required bool showThinkingAndToolCards,
  required bool expandThinkingContent,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final settings = context.read<SettingsProvider>();
  final isDesktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  // Pick the destination before rendering so a cancelled picker costs no work.
  String? directory;
  if (isDesktop) {
    try {
      directory = await FilePicker.platform.getDirectoryPath(
        dialogTitle: l10n.messageExportSheetChooseExportFolder,
      );
    } catch (e) {
      if (context.mounted) {
        showAppSnackBar(
          context,
          message: l10n.messageExportSheetExportFailed('$e'),
          type: NotificationType.error,
        );
      }
      return;
    }
    if (directory == null) return; // user cancelled
  }

  final stamp = _exportFileTimestamp();
  final progress = ValueNotifier<LongImageProgress?>(null);
  final cancel = ValueNotifier<bool>(false);
  var saved = 0;
  try {
    await _runWithExportingOverlay(
      context,
      () async {
        for (var i = 0; i < bundles.length; i++) {
          if (cancel.value) break;
          final bundle = bundles[i];
          final result = await _renderAndSaveChatImage(
            context,
            bundle.conversation,
            bundle.messages,
            showThinkingAndToolCards: showThinkingAndToolCards,
            expandThinkingContent: expandThinkingContent,
            tilingEnabled: settings.longImageTilingEnabled,
            onProgress: (value) {
              // Scale each conversation's 0..1 fraction into the batch's
              // overall progress so the overlay does not restart at zero.
              progress.value = LongImageProgress(
                stage: value.stage,
                current: i * 100 + (value.fraction * 100).round(),
                total: bundles.length * 100,
              );
            },
            isCancelled: () => cancel.value,
          );
          if (result == null) continue;
          try {
            final title = _conversationExportTitle(
              context,
              bundle.conversation,
            );
            final name = '${_sanitizeExportFileName(title)}-$stamp-$i.png';
            final bytes = await result.file.readAsBytes();
            if (isDesktop && directory != null) {
              final target = File(p.join(directory, name));
              await target.parent.create(recursive: true);
              await target.writeAsBytes(bytes);
              saved++;
            } else {
              final savePath = await FilePicker.platform.saveFile(
                dialogTitle: l10n.backupPageExportToFile,
                fileName: name,
                type: FileType.custom,
                allowedExtensions: const ['png'],
                bytes: bytes,
              );
              if (savePath != null) saved++;
            }
          } finally {
            try {
              await result.file.delete();
            } catch (_) {}
            final preview = result.previewFile;
            if (preview != null) {
              try {
                await preview.delete();
              } catch (_) {}
            }
          }
        }
      },
      progress: progress,
      onCancel: () {
        cancel.value = true;
        progress.value = null;
      },
    );
  } catch (e) {
    if (!cancel.value && context.mounted) {
      final message = e is LongImageTooLargeException
          ? l10n.messageExportSheetImageTooLarge(e.sizeLabel)
          : l10n.messageExportSheetExportFailed('$e');
      showAppSnackBar(context, message: message, type: NotificationType.error);
    }
    return;
  } finally {
    progress.dispose();
    cancel.dispose();
  }

  if (context.mounted && saved > 0) {
    showAppSnackBar(
      context,
      message: l10n.messageExportSheetExportedCount(saved),
      type: NotificationType.success,
    );
  }
}

class _ConversationExportPayload {
  const _ConversationExportPayload({
    required this.title,
    required this.content,
  });

  final String title;
  final String content;
}

String _conversationExportTitle(
  BuildContext context,
  Conversation conversation,
) {
  final title = conversation.title.trim();
  if (title.isNotEmpty) return title;
  return AppLocalizations.of(context)!.messageExportSheetDefaultTitle;
}

/// Markdown block for one message's persisted answer-review card. Includes
/// the draft and the revision diff by default (the user's export choice).
String _answerReviewMarkdown(
  BuildContext context,
  ChatService service,
  ChatMessage message,
) {
  if (message.role != 'assistant') return '';
  final AnswerReviewRecord? record;
  try {
    record = service.getAnswerReview(message.id);
  } catch (_) {
    return '';
  }
  if (record == null) return '';
  final l10n = AppLocalizations.of(context)!;
  final report = record.report;
  final status = answerReviewStatusLabel(l10n, report.phase);
  final buf = StringBuffer();
  buf.writeln('### ${l10n.chatAnswerReviewCardTitle} · $status');
  buf.writeln('');
  if (report.issues.isNotEmpty) {
    buf.writeln('**${l10n.chatAnswerReviewIssuesTitle}**');
    buf.writeln('');
    for (final issue in report.sortedIssues) {
      buf.writeln(
        '- **${issue.severity}** `${issue.location}` — ${issue.problem}',
      );
      if (issue.fix.isNotEmpty) {
        buf.writeln('  - ${l10n.chatAnswerReviewFix}: ${issue.fix}');
      }
    }
    buf.writeln('');
  }
  final draft = record.draft;
  if (draft != null && draft.isNotEmpty) {
    buf.writeln('**${l10n.chatAnswerReviewDraftTitle}**');
    buf.writeln('');
    buf.writeln(draft);
    if (report.draftTruncated) {
      buf.writeln('');
      buf.writeln('> ${l10n.chatAnswerReviewDraftTruncated}');
    }
    buf.writeln('');
  }
  if (report.phase == AnswerReviewPhase.revised &&
      draft != null &&
      draft.isNotEmpty &&
      !report.draftTruncated) {
    final diff = computeUnifiedDiff(draft, message.content, path: 'answer');
    if (!diff.isEmpty) {
      buf.writeln('**${l10n.chatAnswerReviewDiffTitle}**');
      buf.writeln('');
      buf.writeln('```diff');
      buf.writeln(diff.render());
      buf.writeln('```');
      buf.writeln('');
    }
  }
  return buf.toString();
}

Future<String> _buildConversationMarkdown(
  BuildContext context,
  ChatExportBundle bundle,
) async {
  final l10n = AppLocalizations.of(context)!;
  final service = context.read<ChatService>();
  final title = _conversationExportTitle(context, bundle.conversation);
  final buf = StringBuffer();
  buf.writeln('# $title');
  buf.writeln('');
  for (final msg in bundle.messages) {
    final time = DateFormat(l10n.messageExportSheetDateTimeWithSecondsPattern)
        .format(msg.timestamp);
    buf.writeln('> $time · ${_getRoleName(context, msg)}');
    buf.writeln('');
    final parsed = _parseContent(msg.content);
    if (parsed.text.isNotEmpty) {
      buf.writeln(parsed.text);
      buf.writeln('');
    }
    for (final path in parsed.images) {
      final fixed = SandboxPathResolver.fix(path);
      try {
        final file = File(fixed);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          final b64 = base64Encode(bytes);
          final mime = _guessImageMime(fixed);
          buf.writeln('![](data:$mime;base64,$b64)');
        } else {
          buf.writeln('![image]($fixed)');
        }
      } catch (_) {
        buf.writeln('![image]($fixed)');
      }
      buf.writeln('');
    }
    for (final doc in parsed.docs) {
      buf.writeln('- ${doc.fileName}  `${doc.mime}`');
    }
    final review = _answerReviewMarkdown(context, service, msg);
    if (review.isNotEmpty) buf.writeln(review);
    buf.writeln('\n---\n');
  }
  return buf.toString();
}

Future<String> _buildConversationTxt(
  BuildContext context,
  ChatExportBundle bundle,
) async {
  final l10n = AppLocalizations.of(context)!;
  final service = context.read<ChatService>();
  final title = _conversationExportTitle(context, bundle.conversation);
  final buf = StringBuffer();
  buf.writeln(title);
  buf.writeln('');
  for (final msg in bundle.messages) {
    final time = DateFormat(l10n.messageExportSheetDateTimeWithSecondsPattern)
        .format(msg.timestamp);
    buf.writeln('$time · ${_getRoleName(context, msg)}');
    buf.writeln('');
    final parsed = _parseContent(msg.content);
    if (parsed.text.isNotEmpty) {
      buf.writeln(parsed.text);
      buf.writeln('');
    }
    for (final doc in parsed.docs) {
      buf.writeln('- ${doc.fileName} (${doc.mime})');
    }
    final review = _answerReviewMarkdown(context, service, msg);
    if (review.isNotEmpty) buf.writeln(review);
    buf.writeln('\n---\n');
  }
  return buf.toString();
}

String _exportFileTimestamp() {
  final now = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final millis = now.millisecond.toString().padLeft(3, '0');
  return '${now.year}${two(now.month)}${two(now.day)}-'
      '${two(now.hour)}${two(now.minute)}${two(now.second)}-$millis';
}

String _sanitizeExportFileName(String input) {
  var name = input
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  name = name.replaceAll(RegExp(r'[. ]+$'), '');
  if (name.isEmpty) name = 'chat';
  if (name.length > 60) {
    name = name.substring(0, 60).trim();
  }
  name = name.replaceAll(RegExp(r'[. ]+$'), '');
  if (name.isEmpty) name = 'chat';
  return name;
}
