import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../icons/lucide_adapter.dart' as lucide;
import '../../l10n/app_localizations.dart';
import '../../core/models/backup.dart';
import '../../core/providers/backup_provider.dart';
import '../../core/providers/settings_provider.dart';
import '../../core/services/chat/chat_service.dart';
import '../../core/services/backup/cherry_importer.dart';
import '../../core/services/backup/chatbox_importer.dart';
import '../../core/services/backup/dropbox_auth_service.dart';
import '../../shared/widgets/ios_switch.dart';
import '../../shared/widgets/snackbar.dart';

class DesktopBackupPane extends StatefulWidget {
  const DesktopBackupPane({super.key});
  @override
  State<DesktopBackupPane> createState() => _DesktopBackupPaneState();
}

class _DesktopBackupPaneState extends State<DesktopBackupPane> {
  // Remote list state
  List<BackupFileItem> _remote = const [];
  bool _loadingRemote = false;

  // Local form controllers
  late TextEditingController _url;
  late TextEditingController _username;
  late TextEditingController _password;
  late TextEditingController _path;
  late TextEditingController _dropboxPathController;
  late TextEditingController _dropboxClientIdController;
  bool _includeChats = true;
  bool _includeFiles = true;

  @override
  void initState() {
    super.initState();
    final cfg = context.read<SettingsProvider>().webDavConfig;
    final dropboxCfg = context.read<SettingsProvider>().dropboxConfig;
    _url = TextEditingController(text: cfg.url);
    _username = TextEditingController(text: cfg.username);
    _password = TextEditingController(text: cfg.password);
    _path = TextEditingController(text: cfg.path);
    _dropboxPathController = TextEditingController(text: dropboxCfg.path);
    _dropboxClientIdController = TextEditingController(text: dropboxCfg.clientId);
    _includeChats = cfg.includeChats;
    _includeFiles = cfg.includeFiles;
    _reloadRemote();
  }

  @override
  void dispose() {
    _url.dispose();
    _username.dispose();
    _password.dispose();
    _path.dispose();
    _dropboxPathController.dispose();
    _dropboxClientIdController.dispose();
    super.dispose();
  }

  Future<void> _reloadRemote() async {
    setState(() => _loadingRemote = true);
    try {
      final items = await context.read<BackupProvider>().listRemote();
      if (mounted) setState(() => _remote = items);
    } catch (_) {
      if (mounted) setState(() => _remote = const []);
    } finally {
      if (mounted) setState(() => _loadingRemote = false);
    }
  }

  WebDavConfig _buildConfigFromForm() {
    return WebDavConfig(
      url: _url.text.trim(),
      username: _username.text.trim(),
      password: _password.text,
      path: _path.text.trim().isEmpty ? 'omnichat_backups' : _path.text.trim(),
      includeChats: _includeChats,
      includeFiles: _includeFiles,
    );
  }

  Future<void> _saveConfig() async {
    final cfg = _buildConfigFromForm();
    await context.read<SettingsProvider>().setWebDavConfig(cfg);
    context.read<BackupProvider>().updateConfig(cfg);
  }

  Future<void> _applyPartial({String? url, String? username, String? password, String? path, bool? includeChats, bool? includeFiles}) async {
    final cfg = WebDavConfig(
      url: url ?? _url.text.trim(),
      username: username ?? _username.text.trim(),
      password: password ?? _password.text,
      path: path ?? (_path.text.trim().isEmpty ? 'omnichat_backups' : _path.text.trim()),
      includeChats: includeChats ?? _includeChats,
      includeFiles: includeFiles ?? _includeFiles,
    );
    await context.read<SettingsProvider>().setWebDavConfig(cfg);
    context.read<BackupProvider>().updateConfig(cfg);
  }

  Future<void> _chooseRestoreModeAndRun(Future<void> Function(RestoreMode) action) async {
    final l10n = AppLocalizations.of(context)!;
    final mode = await showDialog<RestoreMode>(
      context: context,
      builder: (ctx) => _RestoreModeDialog(),
    );
    if (mode == null) return;
    await action(mode);
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(ctx).colorScheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(l10n.backupPageRestartRequired),
        content: Text(l10n.backupPageRestartContent),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: Text(l10n.backupPageOK)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final settings = context.watch<SettingsProvider>();
    final dropboxCfg = settings.dropboxConfig;
    final busy = context.watch<BackupProvider>().busy;

    return Container(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: CustomScrollView(
            slivers: [
              // Title row
              SliverToBoxAdapter(
                child: SizedBox(
                  height: 36,
                  child: Row(
                    children: [
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            l10n.backupPageTitle,
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w400, color: cs.onSurface.withOpacity(0.9)),
                          ),
                        ),
                      ),
                      if (busy) const SizedBox(width: 8),
                      if (busy) SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.0, color: cs.primary)),
                    ],
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 6)),

              // Section 1: 備份管理 (Backup Management)
              SliverToBoxAdapter(
                child: _sectionCard(children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      l10n.backupPageBackupManagement,
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: cs.onSurface.withOpacity(0.95)),
                    ),
                  ),
                  _ItemRow(
                    label: l10n.backupPageChatsLabel,
                    vpad: 2,
                    trailing: IosSwitch(
                      value: _includeChats,
                      onChanged: busy ? null : (v) async {
                        setState(() => _includeChats = v);
                        await _applyPartial(includeChats: v);
                        final newDb = dropboxCfg.copyWith(includeChats: v);
                        await settings.setDropboxConfig(newDb);
                        if (!mounted) return;
                        context.read<BackupProvider>().updateDropboxConfig(newDb);
                      },
                    ),
                  ),
                  _rowDivider(context),
                  _ItemRow(
                    label: l10n.backupPageFilesLabel,
                    vpad: 2,
                    trailing: IosSwitch(
                      value: _includeFiles,
                      onChanged: busy ? null : (v) async {
                        setState(() => _includeFiles = v);
                        await _applyPartial(includeFiles: v);
                        final newDb = dropboxCfg.copyWith(includeFiles: v);
                        await settings.setDropboxConfig(newDb);
                        if (!mounted) return;
                        context.read<BackupProvider>().updateDropboxConfig(newDb);
                      },
                    ),
                  ),
                ]),
              ),

              const SliverToBoxAdapter(child: SizedBox(height: 10)),

              // Section 2: 本機備份 (Local Backup)
              SliverToBoxAdapter(
                child: _sectionCard(children: [
                  Row(children: [
                    Expanded(child: Text(l10n.backupPageLocalBackup, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600))),
                  ]),
                  const SizedBox(height: 6),
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    _DeskIosButton(label: l10n.backupPageExportToFile, filled: false, dense: true, onTap: () async {
                      await _saveConfig();
                      final file = await context.read<BackupProvider>().exportToFile();
                      String? savePath = await FilePicker.platform.saveFile(
                        dialogTitle: l10n.backupPageExportToFile,
                        fileName: file.uri.pathSegments.last,
                        type: FileType.custom,
                        allowedExtensions: ['zip'],
                      );
                      if (savePath != null) {
                        try {
                          await File(savePath).parent.create(recursive: true);
                          await file.copy(savePath);
                        } catch (_) {}
                      }
                    }),
                    _DeskIosButton(label: l10n.backupPageImportBackupFile, filled: false, dense: true, onTap: () async {
                      final result = await FilePicker.platform.pickFiles(type: FileType.any, allowMultiple: false);
                      final path = result?.files.single.path;
                      if (path == null) return;
                      final f = File(path);
                      await _chooseRestoreModeAndRun((mode) async {
                        await context.read<BackupProvider>().restoreFromLocalFile(f, mode: mode);
                      });
                    }),
                    _DeskIosButton(label: l10n.backupPageImportFromCherryStudio, filled: false, dense: true, onTap: () async {
                      final result = await FilePicker.platform.pickFiles(type: FileType.any, allowMultiple: false);
                      final path = result?.files.single.path;
                      if (path == null) return;
                      final f = File(path);
                      final mode = await showDialog<RestoreMode>(context: context, builder: (_) => _RestoreModeDialog());
                      if (mode == null) return;
                      final settingsProvider = context.read<SettingsProvider>();
                      final chat = context.read<ChatService>();
                      try {
                        await CherryImporter.importFromCherryStudio(file: f, mode: mode, settings: settingsProvider, chatService: chat);
                        await showDialog(context: context, builder: (_) => AlertDialog(
                          backgroundColor: cs.surface,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          title: Text(l10n.backupPageRestartRequired),
                          content: Text(l10n.backupPageRestartContent),
                          actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l10n.backupPageOK))],
                        ));
                      } catch (e) {
                        await showDialog(context: context, builder: (_) => AlertDialog(
                          backgroundColor: cs.surface,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          title: const Text('Error'),
                          content: Text(e.toString()),
                          actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l10n.backupPageOK))],
                        ));
                      }
                    }),
                    _DeskIosButton(label: l10n.backupPageImportFromChatbox, filled: false, dense: true, onTap: () async {
                      final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['json'], allowMultiple: false);
                      final path = result?.files.single.path;
                      if (path == null) return;
                      final f = File(path);
                      final mode = await showDialog<RestoreMode>(context: context, builder: (_) => _RestoreModeDialog());
                      if (mode == null) return;
                      final settingsProvider = context.read<SettingsProvider>();
                      final chat = context.read<ChatService>();
                      try {
                        final res = await ChatboxImporter.importFromChatbox(file: f, mode: mode, settings: settingsProvider, chatService: chat);
                        await showDialog(context: context, builder: (_) => AlertDialog(
                          backgroundColor: cs.surface,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          title: Text(l10n.backupPageRestartRequired),
                          content: Text(
                            '${l10n.backupPageImportFromChatbox}:\n'
                            ' • Providers: ${res.providers}\n'
                            ' • Assistants: ${res.assistants}\n'
                            ' • Conversations: ${res.conversations}\n'
                            ' • Messages: ${res.messages}\n\n'
                            '${l10n.backupPageRestartContent}',
                          ),
                          actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l10n.backupPageOK))],
                        ));
                      } catch (e) {
                        await showDialog(context: context, builder: (_) => AlertDialog(
                          backgroundColor: cs.surface,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          title: const Text('Error'),
                          content: Text(e.toString()),
                          actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l10n.backupPageOK))],
                        ));
                      }
                    }),
                  ]),
                ]),
              ),

              const SliverToBoxAdapter(child: SizedBox(height: 10)),

              // Section 3: Dropbox 備份 (Dropbox Backup)
              SliverToBoxAdapter(
                child: _sectionCard(children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Dropbox 備份',
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: cs.onSurface.withOpacity(0.95)),
                          ),
                        ),
                      ],
                    ),
                  ),
                  _ItemRow(
                    label: 'App Key (Client ID)',
                    trailing: SizedBox(
                      width: 420,
                      child: TextField(
                        controller: _dropboxClientIdController,
                        enabled: !busy && !dropboxCfg.isConnected,
                        style: const TextStyle(fontSize: 14),
                        decoration: _deskInputDecoration(context).copyWith(hintText: '請輸入您的 Dropbox App Key'),
                        onChanged: (v) async {
                          final newCfg = dropboxCfg.copyWith(clientId: v.trim());
                          await settings.setDropboxConfig(newCfg);
                          if (!mounted) return;
                          context.read<BackupProvider>().updateDropboxConfig(newCfg);
                        },
                      ),
                    ),
                  ),
                  _rowDivider(context),
                  _ItemRow(
                    label: '帳號連結',
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (dropboxCfg.isConnected)
                          Padding(
                            padding: const EdgeInsets.only(right: 12),
                            child: Text(
                              dropboxCfg.accountEmail.isNotEmpty ? dropboxCfg.accountEmail : (dropboxCfg.accountName.isNotEmpty ? dropboxCfg.accountName : '已連結'),
                              style: TextStyle(fontSize: 13, color: cs.primary, fontWeight: FontWeight.w600),
                            ),
                          )
                        else
                          Padding(
                            padding: const EdgeInsets.only(right: 12),
                            child: Text(
                              '未連結',
                              style: TextStyle(fontSize: 13, color: cs.onSurface.withOpacity(0.5)),
                            ),
                          ),
                        _DeskIosButton(
                          label: dropboxCfg.isConnected ? '解除連結' : '連結 Dropbox',
                          filled: !dropboxCfg.isConnected,
                          dense: true,
                          onTap: busy
                              ? () {}
                              : () async {
                                  if (dropboxCfg.isConnected) {
                                    final newCfg = const DropboxConfig();
                                    await settings.setDropboxConfig(newCfg);
                                    if (!mounted) return;
                                    context.read<BackupProvider>().updateDropboxConfig(newCfg);
                                    showAppSnackBar(context, message: '已解除 Dropbox 連結', type: NotificationType.info);
                                  } else {
                                    try {
                                      final newCfg = await DropboxAuthService.authenticate(customClientId: dropboxCfg.clientId);
                                      final updatedCfg = newCfg.copyWith(
                                        includeChats: _includeChats,
                                        includeFiles: _includeFiles,
                                      );
                                      await settings.setDropboxConfig(updatedCfg);
                                      if (!mounted) return;
                                      context.read<BackupProvider>().updateDropboxConfig(updatedCfg);
                                      showAppSnackBar(context, message: 'Dropbox 連結成功！', type: NotificationType.success);
                                    } catch (e) {
                                      if (!mounted) return;
                                      showAppSnackBar(context, message: e.toString(), type: NotificationType.error);
                                    }
                                  }
                                },
                        ),
                      ],
                    ),
                  ),
                  _rowDivider(context),
                  _ItemRow(
                    label: l10n.backupPagePath,
                    trailing: SizedBox(
                      width: 420,
                      child: TextField(
                        controller: _dropboxPathController,
                        enabled: !busy,
                        style: const TextStyle(fontSize: 14),
                        decoration: _deskInputDecoration(context).copyWith(hintText: 'omnichat_backups'),
                        onChanged: (v) async {
                          final clean = v.trim().isEmpty ? 'omnichat_backups' : v.trim();
                          final newCfg = dropboxCfg.copyWith(path: clean);
                          await settings.setDropboxConfig(newCfg);
                          if (!mounted) return;
                          context.read<BackupProvider>().updateDropboxConfig(newCfg);
                        },
                      ),
                    ),
                  ),
                  _rowDivider(context),
                  _ItemRow(
                    label: 'Dropbox 操作',
                    trailing: Wrap(spacing: 8, children: [
                      _DeskIosButton(
                        label: l10n.backupPageTestConnection,
                        filled: false,
                        dense: true,
                        onTap: (busy || !dropboxCfg.isConnected)
                            ? () {}
                            : () async {
                                await context.read<BackupProvider>().testDropbox(settings.dropboxConfig);
                                if (!mounted) return;
                                final rawMessage = context.read<BackupProvider>().message;
                                final message = rawMessage ?? l10n.backupPageTestDone;
                                showAppSnackBar(
                                  context,
                                  message: message,
                                  type: rawMessage != null && rawMessage != 'OK'
                                      ? NotificationType.error
                                      : NotificationType.success,
                                );
                              },
                      ),
                      _DeskIosButton(
                        label: l10n.backupPageRestore,
                        filled: false,
                        dense: true,
                        onTap: (busy || !dropboxCfg.isConnected)
                            ? () {}
                            : () => _showRemoteBackupsDialog(context, isDropbox: true),
                      ),
                      _DeskIosButton(
                        label: l10n.backupPageBackupNow,
                        filled: true,
                        dense: true,
                        onTap: (busy || !dropboxCfg.isConnected)
                            ? () {}
                            : () async {
                                await context.read<BackupProvider>().backupDropbox(settings.dropboxConfig);
                                if (!mounted) return;
                                final rawMessage = context.read<BackupProvider>().message;
                                final isSuccess = rawMessage != null && rawMessage.startsWith('OK:');
                                final String message;
                                if (isSuccess) {
                                  final path = rawMessage.substring(3);
                                  message = 'Dropbox 備份上傳成功！檔案已儲存至：$path';
                                } else {
                                  message = rawMessage ?? 'Dropbox 備份失敗';
                                }
                                showAppSnackBar(
                                  context,
                                  message: message,
                                  type: isSuccess ? NotificationType.success : NotificationType.error,
                                );
                              },
                      ),
                    ]),
                  ),
                ]),
              ),

              const SliverToBoxAdapter(child: SizedBox(height: 10)),

              // Section 4: WebDAV 備份 (WebDAV Backup)
              SliverToBoxAdapter(
                child: _sectionCard(children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            l10n.backupPageWebDavServerSettings,
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: cs.onSurface.withOpacity(0.95)),
                          ),
                        ),
                      ],
                    ),
                  ),
                  _ItemRow(
                    label: l10n.backupPageWebDavServerUrl,
                    trailing: SizedBox(
                      width: 420,
                      child: TextField(
                        controller: _url,
                        enabled: !busy,
                        style: const TextStyle(fontSize: 14),
                        decoration: _deskInputDecoration(context).copyWith(hintText: 'https://dav.example.com/remote.php/webdav/'),
                        onChanged: (v) => _applyPartial(url: v),
                      ),
                    ),
                  ),
                  _rowDivider(context),
                  _ItemRow(
                    label: l10n.backupPageUsername,
                    trailing: SizedBox(
                      width: 420,
                      child: TextField(
                        controller: _username,
                        enabled: !busy,
                        style: const TextStyle(fontSize: 14),
                        decoration: _deskInputDecoration(context).copyWith(hintText: l10n.backupPageUsername),
                        onChanged: (v) => _applyPartial(username: v),
                      ),
                    ),
                  ),
                  _rowDivider(context),
                  _ItemRow(
                    label: l10n.backupPagePassword,
                    trailing: SizedBox(
                      width: 420,
                      child: TextField(
                        controller: _password,
                        enabled: !busy,
                        obscureText: true,
                        style: const TextStyle(fontSize: 14),
                        decoration: _deskInputDecoration(context).copyWith(hintText: '••••••••'),
                        onChanged: (v) => _applyPartial(password: v),
                      ),
                    ),
                  ),
                  _rowDivider(context),
                  _ItemRow(
                    label: l10n.backupPagePath,
                    trailing: SizedBox(
                      width: 420,
                      child: TextField(
                        controller: _path,
                        enabled: !busy,
                        style: const TextStyle(fontSize: 14),
                        decoration: _deskInputDecoration(context).copyWith(hintText: 'omnichat_backups'),
                        onChanged: (v) => _applyPartial(path: v),
                      ),
                    ),
                  ),
                  _rowDivider(context),
                  _ItemRow(
                    label: 'WebDAV 操作',
                    trailing: Wrap(spacing: 8, children: [
                      _DeskIosButton(
                        label: l10n.backupPageTestConnection,
                        filled: false,
                        dense: true,
                        onTap: busy ? (){} : () async {
                          await _saveConfig();
                          await context.read<BackupProvider>().test();
                          if (!mounted) return;
                          final rawMessage = context.read<BackupProvider>().message;
                          final message = rawMessage ?? l10n.backupPageTestDone;
                          showAppSnackBar(
                            context,
                            message: message,
                            type: rawMessage != null && rawMessage != 'OK'
                                ? NotificationType.error
                                : NotificationType.success,
                          );
                        },
                      ),
                      _DeskIosButton(
                        label: l10n.backupPageRestore,
                        filled: false,
                        dense: true,
                        onTap: busy ? (){} : () => _showRemoteBackupsDialog(context, isDropbox: false),
                      ),
                      _DeskIosButton(
                        label: l10n.backupPageBackupNow,
                        filled: true,
                        dense: true,
                        onTap: busy ? (){} : () async {
                          await _saveConfig();
                          await context.read<BackupProvider>().backup();
                          if (!mounted) return;
                          final rawMessage = context.read<BackupProvider>().message;
                          final message = rawMessage ?? l10n.backupPageBackupUploaded;
                          showAppSnackBar(
                            context,
                            message: message,
                            type: NotificationType.info,
                          );
                        },
                      ),
                    ]),
                  ),
                ]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RemoteItemCard extends StatefulWidget {
  const _RemoteItemCard({required this.item, required this.onRestore, required this.onDelete});
  final BackupFileItem item;
  final VoidCallback onRestore;
  final VoidCallback onDelete;
  @override
  State<_RemoteItemCard> createState() => _RemoteItemCardState();
}

class _RemoteItemCardState extends State<_RemoteItemCard> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final baseBg = isDark ? Colors.white10 : Colors.white.withOpacity(0.96);
    final borderColor = _hover
        ? cs.primary.withOpacity(isDark ? 0.35 : 0.45)
        : cs.outlineVariant.withOpacity(isDark ? 0.12 : 0.08);
    final l10n = AppLocalizations.of(context)!;
    final dateStr = widget.item.lastModified?.toLocal().toString().split('.').first ?? '';

    String prettySize(int size) {
      const units = ['B', 'KB', 'MB', 'GB'];
      double s = size.toDouble();
      int u = 0;
      while (s >= 1024 && u < units.length - 1) { s /= 1024; u++; }
      return '${s.toStringAsFixed(s >= 10 || u == 0 ? 0 : 1)} ${units[u]}';
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: Container(
        decoration: BoxDecoration(
          color: baseBg,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: borderColor, width: 1.0),
        ),
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Icon(lucide.Lucide.HardDrive, size: 20, color: cs.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(widget.item.displayName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text('${prettySize(widget.item.size)}${dateStr.isNotEmpty ? ' · $dateStr' : ''}', style: TextStyle(fontSize: 12.5, color: cs.onSurface.withOpacity(0.7))),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Tooltip(message: l10n.backupPageRestoreTooltip, child: _SmallIconBtn(icon: lucide.Lucide.RotateCw, onTap: widget.onRestore)),
            const SizedBox(width: 6),
            Tooltip(message: l10n.backupPageDeleteTooltip, child: _SmallIconBtn(icon: lucide.Lucide.Trash2, onTap: widget.onDelete)),
          ],
        ),
      ),
    );
  }
}

class _RemoteBackupsDialog extends StatefulWidget {
  const _RemoteBackupsDialog({this.isDropbox = false});
  final bool isDropbox;
  @override
  State<_RemoteBackupsDialog> createState() => _RemoteBackupsDialogState();
}

class _RemoteBackupsDialogState extends State<_RemoteBackupsDialog> {
  List<BackupFileItem> _items = const [];
  bool _loading = true;
  final ScrollController _controller = ScrollController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final bp = context.read<BackupProvider>();
      final sp = context.read<SettingsProvider>();
      final list = widget.isDropbox
          ? await bp.listDropboxRemote(sp.dropboxConfig)
          : await bp.listRemote();
      list.sort((a, b) {
        final aTime = a.lastModified;
        final bTime = b.lastModified;
        if (aTime != null && bTime != null) return bTime.compareTo(aTime);
        if (aTime == null && bTime == null) return b.displayName.compareTo(a.displayName);
        if (aTime == null) return 1;
        return -1;
      });
      if (mounted) setState(() { _items = list; });
    } catch (_) {
      if (mounted) setState(() { _items = const []; });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _chooseRestoreModeAndRun(Future<void> Function(RestoreMode) action) async {
    final mode = await showDialog<RestoreMode>(context: context, builder: (_) => _RestoreModeDialog());
    if (mode == null) return;
    await action(mode);
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    await showDialog(context: context, builder: (_) => AlertDialog(
      backgroundColor: cs.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(l10n.backupPageRestartRequired),
      content: Text(l10n.backupPageRestartContent),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l10n.backupPageOK))],
    ));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    return Dialog(
      backgroundColor: cs.surface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760, maxHeight: 540),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: Text(widget.isDropbox ? 'Dropbox 備份列表' : l10n.backupPageRemoteBackups, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700))),
                  _SmallIconBtn(icon: lucide.Lucide.RefreshCw, onTap: _loading ? (){} : _load),
                  const SizedBox(width: 6),
                  _SmallIconBtn(icon: lucide.Lucide.X, onTap: () => Navigator.of(context).maybePop()),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: _loading
                    ? const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)))
                    : _items.isEmpty
                        ? Center(child: Text(l10n.backupPageNoBackups, style: TextStyle(color: cs.onSurface.withOpacity(0.7))))
                        : Scrollbar(
                            controller: _controller,
                            child: ListView.separated(
                              controller: _controller,
                              primary: false,
                              itemCount: _items.length,
                              separatorBuilder: (_, __) => const SizedBox(height: 8),
                              itemBuilder: (ctx, i) {
                                final it = _items[i];
                                return _RemoteItemCard(
                                  item: it,
                                  onRestore: () => _chooseRestoreModeAndRun((mode) async {
                                    final bp = context.read<BackupProvider>();
                                    final sp = context.read<SettingsProvider>();
                                    if (widget.isDropbox) {
                                      await bp.restoreDropboxFromItem(sp.dropboxConfig, it, mode: mode);
                                    } else {
                                      await bp.restoreFromItem(it, mode: mode);
                                    }
                                  }),
                                  onDelete: () async {
                                    final bp = context.read<BackupProvider>();
                                    final sp = context.read<SettingsProvider>();
                                    final next = widget.isDropbox
                                        ? await bp.deleteAndReloadDropbox(sp.dropboxConfig, it)
                                        : await bp.deleteAndReload(it);
                                    next.sort((a, b) {
                                      final aTime = a.lastModified;
                                      final bTime = b.lastModified;
                                      if (aTime != null && bTime != null) return bTime.compareTo(aTime);
                                      if (aTime == null && bTime == null) return b.displayName.compareTo(a.displayName);
                                      if (aTime == null) return 1;
                                      return -1;
                                    });
                                    if (mounted) setState(() => _items = next);
                                  },
                                );
                              },
                            ),
                          ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

void _showRemoteBackupsDialog(BuildContext context, {bool isDropbox = false}) {
  showDialog(context: context, builder: (_) => _RemoteBackupsDialog(isDropbox: isDropbox));
}

Widget _rowDivider(BuildContext context) {
  final cs = Theme.of(context).colorScheme;
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return Container(height: 1, color: cs.outlineVariant.withOpacity(isDark ? 0.08 : 0.06));
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({required this.label, required this.trailing, this.vpad = 8});
  final String label; final Widget trailing; final double vpad;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: vpad),
      child: Row(
        children: [
          Expanded(child: Text(label, style: TextStyle(fontSize: 14, color: cs.onSurface.withOpacity(0.88)))),
          const SizedBox(width: 12),
          Align(alignment: Alignment.centerRight, child: trailing),
        ],
      ),
    );
  }
}

class _LabeledCheckbox extends StatelessWidget {
  const _LabeledCheckbox({required this.label, required this.value, required this.onChanged});
  final String label; final bool value; final ValueChanged<bool>? onChanged;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return MouseRegion(
      cursor: onChanged != null ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: onChanged != null ? () => onChanged!(!value) : null,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Checkbox(
            value: value,
            onChanged: onChanged == null ? null : (bool? v) => onChanged!(v ?? false),
          ),
          Text(label, style: TextStyle(color: cs.onSurface.withOpacity(0.9))),
        ]),
      ),
    );
  }
}

class _RestoreModeDialog extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    return Dialog(
      backgroundColor: cs.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 320, maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.backupPageSelectImportMode, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(l10n.backupPageSelectImportModeDescription, style: TextStyle(fontSize: 13, color: cs.onSurface.withOpacity(0.8))),
            const SizedBox(height: 12),
            _RestoreModeTile(
              title: l10n.backupPageOverwriteMode,
              subtitle: l10n.backupPageOverwriteModeDescription,
              onTap: () => Navigator.of(context).pop(RestoreMode.overwrite),
            ),
            const SizedBox(height: 8),
            _RestoreModeTile(
              title: l10n.backupPageMergeMode,
              subtitle: l10n.backupPageMergeModeDescription,
              onTap: () => Navigator.of(context).pop(RestoreMode.merge),
            ),
            const SizedBox(height: 12),
            Align(alignment: Alignment.centerRight, child: TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l10n.backupPageCancel))),
          ],
          ),
        ),
      ),
    );
  }
}

class _RestoreModeTile extends StatefulWidget {
  const _RestoreModeTile({required this.title, required this.subtitle, required this.onTap});
  final String title; final String subtitle; final VoidCallback onTap;
  @override State<_RestoreModeTile> createState() => _RestoreModeTileState();
}

class _RestoreModeTileState extends State<_RestoreModeTile> {
  bool _hover = false; bool _pressed = false;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme; final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = _hover ? (isDark ? Colors.white.withOpacity(0.06) : Colors.black.withOpacity(0.04)) : Colors.transparent;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _pressed ? 0.98 : 1.0,
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOutCubic,
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12), border: Border.all(color: cs.outlineVariant.withOpacity(0.12), width: 0.6)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(widget.title, style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text(widget.subtitle, style: TextStyle(fontSize: 13, color: cs.onSurface.withOpacity(0.8))),
            ]),
          ),
        ),
      ),
    );
  }
}

class _SmallIconBtn extends StatefulWidget {
  const _SmallIconBtn({required this.icon, required this.onTap});
  final IconData icon; final VoidCallback onTap;
  @override State<_SmallIconBtn> createState() => _SmallIconBtnState();
}

class _SmallIconBtnState extends State<_SmallIconBtn> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme; final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = _hover ? (isDark ? Colors.white.withOpacity(0.06) : Colors.black.withOpacity(0.05)) : Colors.transparent;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 28, height: 28,
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
          alignment: Alignment.center,
          child: Icon(widget.icon, size: 18, color: cs.onSurface),
        ),
      ),
    );
  }
}

class _DeskIosButton extends StatefulWidget {
  const _DeskIosButton({required this.label, required this.filled, required this.dense, required this.onTap});
  final String label; final bool filled; final bool dense; final VoidCallback onTap;
  @override State<_DeskIosButton> createState() => _DeskIosButtonState();
}

class _DeskIosButtonState extends State<_DeskIosButton> {
  bool _hover = false; bool _pressed = false;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme; final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = widget.filled ? Colors.white : cs.onSurface.withOpacity(0.9);
    final bg = widget.filled
        ? (_hover ? cs.primary.withOpacity(0.92) : cs.primary)
        : (_hover ? (isDark ? Colors.white.withOpacity(0.06) : Colors.black.withOpacity(0.05)) : Colors.transparent);
    final borderColor = widget.filled ? Colors.transparent : cs.outlineVariant.withOpacity(isDark ? 0.22 : 0.18);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _pressed ? 0.98 : 1.0,
          duration: const Duration(milliseconds: 110),
          curve: Curves.easeOutCubic,
          child: Container(
            padding: EdgeInsets.symmetric(vertical: widget.dense ? 8 : 12, horizontal: 12),
            alignment: Alignment.center,
            decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12), border: Border.all(color: borderColor)),
            child: Text(widget.label, style: TextStyle(color: textColor, fontWeight: FontWeight.w600, fontSize: widget.dense ? 13 : 14)),
          ),
        ),
      ),
    );
  }
}

Widget _sectionCard({required List<Widget> children}) {
  return Builder(builder: (context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final baseBg = isDark ? Colors.white10 : Colors.white.withOpacity(0.96);
    return Container(
      decoration: BoxDecoration(
        color: baseBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: cs.outlineVariant.withOpacity(isDark ? 0.12 : 0.08), width: 0.8),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
    );
  });
}

InputDecoration _deskInputDecoration(BuildContext context) {
  // Match provider dialog style (compact), but slightly shorter height and 14px font hint
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final cs = Theme.of(context).colorScheme;
  return InputDecoration(
    isDense: true,
    filled: true,
    fillColor: isDark ? Colors.white10 : const Color(0xFFF7F7F9),
    hintStyle: TextStyle(fontSize: 14, color: cs.onSurface.withOpacity(0.5)),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(color: cs.outlineVariant.withOpacity(0.12), width: 0.6),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(color: cs.outlineVariant.withOpacity(0.12), width: 0.6),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(color: cs.primary.withOpacity(0.35), width: 0.8),
    ),
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
  );
}
