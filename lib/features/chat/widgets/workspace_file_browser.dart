import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;

import '../../../core/services/file/file_tool_service.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/snackbar.dart';

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
          bType != FileSystemEntityType.directory)
        return -1;
      if (aType != FileSystemEntityType.directory &&
          bType == FileSystemEntityType.directory)
        return 1;
      return p
          .basename(a.path)
          .toLowerCase()
          .compareTo(p.basename(b.path).toLowerCase());
    });
    return entries;
  }

  Future<void> _open(FileSystemEntity entry) async {
    try {
      final relative = p.relative(entry.path, from: widget.workspacePath);
      final safePath = FileToolService.resolveSafePath(
        relative,
        widget.workspacePath,
      );
      final type = FileSystemEntity.typeSync(safePath, followLinks: false);
      if (type == FileSystemEntityType.directory) {
        setState(() {
          _relativePath = relative == '.' ? '' : relative;
          _reload();
        });
        return;
      }
      final result = await OpenFilex.open(safePath);
      if (!mounted || result.type == ResultType.done) return;
      showAppSnackBar(
        context,
        message: result.message,
        type: NotificationType.error,
      );
    } catch (e) {
      if (mounted) {
        showAppSnackBar(
          context,
          message: AppLocalizations.of(
            context,
          )!.workspaceFileBrowserOpenError('$e'),
          type: NotificationType.error,
        );
      }
    }
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
              return ListTile(
                leading: Icon(isDirectory ? Lucide.Folder : Lucide.FileText),
                title: Text(
                  p.basename(entry.path),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: isDirectory ? const Icon(Lucide.ChevronRight) : null,
                onTap: () => _open(entry),
              );
            },
          );
        },
      ),
    );
  }
}
