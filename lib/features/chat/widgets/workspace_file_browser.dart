import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../../../core/services/file/file_tool_service.dart';
import '../../../desktop/desktop_context_menu.dart';
import '../../../desktop/html_preview_dialog.dart';
import '../../../desktop/menu_anchor.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../utils/markdown_preview_html.dart';
import '../../../utils/sandbox_path_resolver.dart';
import '../pages/html_preview_page.dart';
import '../pages/image_viewer_page.dart';

class WorkspaceFileBrowser extends StatefulWidget {
  const WorkspaceFileBrowser({
    super.key,
    required this.workspacePath,
    this.initialRelativePath = '',
  });

  final String workspacePath;
  final String initialRelativePath;

  @override
  State<WorkspaceFileBrowser> createState() => _WorkspaceFileBrowserState();
}

class _WorkspaceFileBrowserState extends State<WorkspaceFileBrowser> {
  late String _relativePath;
  Future<List<FileSystemEntity>>? _entries;

  static const Set<String> _previewableImageExts = {
    'png',
    'jpg',
    'jpeg',
    'gif',
    'webp',
    'bmp',
  };

  static const Set<String> _previewableTextExts = {
    'md',
    'markdown',
    'txt',
    'text',
    'json',
    'csv',
    'tsv',
    'html',
    'htm',
    'xml',
    'svg',
    'yaml',
    'yml',
    'log',
    'ini',
    'conf',
    'cfg',
    'toml',
    'css',
    'js',
    'jsx',
    'ts',
    'tsx',
    'py',
    'dart',
    'java',
    'c',
    'cpp',
    'h',
    'hpp',
    'go',
    'rs',
    'sh',
    'bat',
    'ps1',
    'sql',
    'php',
    'rb',
    'kt',
    'swift',
  };

  static const int _previewMaxTextBytes = 2 * 1024 * 1024; // 2MB

  @override
  void initState() {
    super.initState();
    _relativePath = widget.initialRelativePath;
    _reload();
  }

  void _reload() {
    _entries = _readEntries();
  }

  Future<List<FileSystemEntity>> _readEntries() async {
    final path = FileToolService.resolveSafePath(
      _relativePath,
      widget.workspacePath,
    );
    final directory = Directory(path);
    if (!await directory.exists()) return const <FileSystemEntity>[];
    final entries = directory.listSync(followLinks: false);
    entries.sort((a, b) {
      final aType = FileSystemEntity.typeSync(a.path, followLinks: false);
      final bType = FileSystemEntity.typeSync(b.path, followLinks: false);
      if (aType == FileSystemEntityType.directory &&
          bType != FileSystemEntityType.directory) {
        return -1;
      }
      if (aType != FileSystemEntityType.directory &&
          bType == FileSystemEntityType.directory) {
        return 1;
      }
      return p
          .basename(a.path)
          .toLowerCase()
          .compareTo(p.basename(b.path).toLowerCase());
    });
    return entries;
  }

  String _fileExtension(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot == -1 || dot == fileName.length - 1) return '';
    return fileName.substring(dot + 1).toLowerCase();
  }

  String _escapeHtml(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
  }

  void _openDirectory(FileSystemEntity entry) {
    final relative = p.relative(entry.path, from: widget.workspacePath);
    setState(() {
      _relativePath = relative == '.' ? '' : relative;
      _reload();
    });
  }

  Future<void> _previewFile(FileSystemEntity entry) async {
    final l10n = AppLocalizations.of(context)!;
    final fixed = SandboxPathResolver.fix(entry.path);
    final file = File(fixed);
    if (!await file.exists()) {
      if (mounted) {
        showAppSnackBar(
          context,
          message: l10n.chatMessageWidgetFileNotFound(p.basename(entry.path)),
          type: NotificationType.error,
        );
      }
      return;
    }

    final fileName = p.basename(entry.path);
    final ext = _fileExtension(fileName);

    if (_previewableImageExts.contains(ext)) {
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ImageViewerPage(images: [fixed], initialIndex: 0),
        ),
      );
      return;
    }

    if (_previewableTextExts.contains(ext)) {
      try {
        final length = await file.length();
        if (length > _previewMaxTextBytes) {
          await _openFileExternally(entry);
          return;
        }
        final content = await file.readAsString();
        if (!mounted) return;
        await _pushTextPreview(content, ext);
        return;
      } catch (_) {
        if (!mounted) return;
        await _openFileExternally(entry);
        return;
      }
    }

    await _openFileExternally(entry);
  }

  Future<void> _pushTextPreview(String content, String ext) async {
    String html;
    var isXml = false;
    if (ext == 'md' || ext == 'markdown') {
      html = await MarkdownPreviewHtmlBuilder.buildFromMarkdown(
        context,
        content,
      );
    } else if (ext == 'xml' || ext == 'svg') {
      html = content;
      isXml = true;
    } else if (ext == 'html' || ext == 'htm') {
      html = content;
    } else {
      html =
          '<pre style="white-space: pre-wrap; word-break: break-word;">'
          '${_escapeHtml(content)}</pre>';
    }
    if (!mounted) return;
    final isDesktop =
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux;
    if (isDesktop) {
      await showHtmlPreviewDesktopDialog(context, html: html, isXml: isXml);
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => HtmlPreviewPage(html: html, isXml: isXml),
      ),
    );
  }

  Future<void> _openFileExternally(FileSystemEntity entry) async {
    final l10n = AppLocalizations.of(context)!;
    try {
      final result = await OpenFilex.open(entry.path);
      if (!mounted || result.type == ResultType.done) return;
      showAppSnackBar(
        context,
        message: l10n.chatMessageWidgetCannotOpenFile(result.message),
        type: NotificationType.error,
      );
    } catch (e) {
      if (mounted) {
        showAppSnackBar(
          context,
          message: l10n.workspaceFileBrowserOpenError('$e'),
          type: NotificationType.error,
        );
      }
    }
  }

  Future<void> _showInFolder(FileSystemEntity entry) async {
    final file = File(entry.path);
    if (!await file.exists() && !await Directory(entry.path).exists()) {
      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        showAppSnackBar(
          context,
          message: l10n.chatMessageWidgetFileNotFound(p.basename(entry.path)),
          type: NotificationType.error,
        );
      }
      return;
    }
    if (Platform.isWindows) {
      await Process.run('explorer', [
        '/select,',
        entry.path.replaceAll('/', '\\'),
      ]);
      return;
    }
    if (Platform.isMacOS) {
      await Process.run('open', ['-R', entry.path]);
      return;
    }
    if (Platform.isLinux) {
      await Process.run('xdg-open', [entry.parent.path]);
      return;
    }
    await OpenFilex.open(entry.parent.path);
  }

  Future<void> _downloadFile(FileSystemEntity entry) async {
    final l10n = AppLocalizations.of(context)!;
    final file = File(entry.path);
    final fileName = p.basename(entry.path);
    if (!await file.exists()) {
      if (mounted) {
        showAppSnackBar(
          context,
          message: l10n.chatMessageWidgetFileNotFound(fileName),
          type: NotificationType.error,
        );
      }
      return;
    }
    try {
      final isDesktop =
          defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.linux;
      if (isDesktop) {
        final savePath = await FilePicker.platform.saveFile(
          dialogTitle: l10n.backupPageExportToFile,
          fileName: fileName,
        );
        if (savePath == null) return;
        await File(savePath).parent.create(recursive: true);
        await file.copy(savePath);
      } else {
        await Share.shareXFiles([XFile(file.path)], text: fileName);
      }
      if (mounted) {
        showAppSnackBar(
          context,
          message: l10n.messageExportSheetExportedAs(fileName),
          type: NotificationType.success,
        );
      }
    } catch (e) {
      if (mounted) {
        showAppSnackBar(
          context,
          message: l10n.messageExportSheetExportFailed('$e'),
          type: NotificationType.error,
        );
      }
    }
  }

  Future<void> _showFileContextMenu(
    FileSystemEntity entry, [
    Offset? globalPosition,
  ]) async {
    final l10n = AppLocalizations.of(context)!;
    final isDesktop =
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux;

    final items = <DesktopContextMenuItem>[
      DesktopContextMenuItem(
        icon: Lucide.FolderOpen,
        label: l10n.chatMessageWidgetShowInFolder,
        onTap: () => _showInFolder(entry),
      ),
      DesktopContextMenuItem(
        icon: Lucide.ExternalLink,
        label: l10n.chatMessageWidgetOpenExternally,
        onTap: () => _openFileExternally(entry),
      ),
      DesktopContextMenuItem(
        icon: Lucide.Download,
        label: l10n.chatMessageWidgetDownload,
        onTap: () => _downloadFile(entry),
      ),
    ];

    if (isDesktop) {
      await showDesktopContextMenuAt(
        context,
        globalPosition:
            globalPosition ?? DesktopMenuAnchor.positionOrCenter(context),
        items: items,
      );
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final item in items)
              ListTile(
                leading: item.icon == null ? null : Icon(item.icon),
                title: Text(item.label),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  item.onTap?.call();
                },
              ),
          ],
        ),
      ),
    );
  }

  void _goUp() {
    if (_relativePath.isEmpty) return;
    setState(() {
      _relativePath = p.dirname(_relativePath);
      if (_relativePath == '.') _relativePath = '';
      _reload();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _relativePath.isEmpty
              ? l10n.workspaceFiles
              : p.basename(_relativePath),
        ),
        leading: _relativePath.isEmpty
            ? null
            : IconButton(icon: const Icon(Lucide.ArrowLeft), onPressed: _goUp),
        actions: [
          IconButton(
            icon: const Icon(Lucide.RefreshCw),
            onPressed: () => setState(_reload),
          ),
        ],
      ),
      body: FutureBuilder<List<FileSystemEntity>>(
        future: _entries,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Text(
                l10n.workspaceFileBrowserReadError('${snapshot.error}'),
              ),
            );
          }
          final entries = snapshot.data ?? const <FileSystemEntity>[];
          if (entries.isEmpty) {
            return Center(
              child: Text(
                l10n.workspaceFileBrowserEmpty,
                style: theme.textTheme.bodyMedium,
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: entries.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final entry = entries[index];
              final isDirectory =
                  FileSystemEntity.typeSync(entry.path, followLinks: false) ==
                  FileSystemEntityType.directory;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onSecondaryTapDown: isDirectory
                    ? null
                    : (details) =>
                        _showFileContextMenu(entry, details.globalPosition),
                child: ListTile(
                  leading: Icon(isDirectory ? Lucide.Folder : Lucide.FileText),
                  title: Text(
                    p.basename(entry.path),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: isDirectory
                      ? const Icon(Lucide.ChevronRight)
                      : null,
                  onTap: () {
                    if (isDirectory) {
                      _openDirectory(entry);
                    } else {
                      _previewFile(entry);
                    }
                  },
                  onLongPress: isDirectory
                      ? null
                      : () => _showFileContextMenu(entry),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
