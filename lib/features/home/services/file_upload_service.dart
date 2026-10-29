import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../l10n/app_localizations.dart';
import '../../../utils/app_directories.dart';
import '../../../utils/platform_utils.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../core/models/chat_input_data.dart';
import '../widgets/chat_input_bar.dart';

/// 文件选取和上传服务
///
/// 负责处理：
/// - 图片选择 (相册/相机)
/// - 文件选择
/// - 桌面拖放处理
/// - 文件复制到应用目录
class FileUploadService {
  FileUploadService({
    required this.mediaController,
    required this.onScrollToBottom,
  });

  /// 媒体控制器，用于添加图片和文件到输入栏
  final ChatInputBarController mediaController;

  /// 滚动到底部的回调
  final VoidCallback onScrollToBottom;

  /// 复制选中的文件到应用上传目录
  ///
  /// [files] 要复制的文件列表；[names] 可逐项指定目的檔名（Android 分享
  /// 匯入用：dart:io 的 `XFile.name` 會被忽略）。
  /// 返回复制后的文件路径列表
  ///
  /// 防止重复附件：同一批次里（相同文件名 + 相同大小）只保留一份（指定目的
  /// 檔名時不做，同名但不同來源的分享檔必須各自保留）；
  /// 文件名冲突时追加序号，避免静默覆盖不同内容。
  Future<List<String>> copyPickedFiles(
    List<XFile> files, {
    List<String>? names,
  }) async {
    final dir = await AppDirectories.getUploadDirectory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final out = <String>[];
    // “原始名|长度” → 已在本批处理过（内容去重）
    final seenKeys = <String>{};
    // 目标目录内已占用的文件名（防止覆盖）
    final usedNames = <String>{};
    for (var index = 0; index < files.length; index++) {
      final f = files[index];
      try {
        final override =
            names != null && index < names.length ? names[index] : null;
        final rawName = override != null && override.isNotEmpty
            ? override
            : (f.name.isNotEmpty
                ? f.name
                : (f.path.split(Platform.pathSeparator).last));
        final name = rawName.split(RegExp(r'[/\\]')).last;
        if (name.isEmpty) continue;
        // 内容去重：同批同文件名且大小一致视为同一附件（指定目的檔名時不做）
        if (override == null) {
          int? length;
          try {
            length = await f.length();
          } catch (_) {
            length = null;
          }
          if (length != null && !seenKeys.add('$name|$length')) continue;
        }
        // 文件名冲突：追加 (n) 后缀而不是覆盖（也不能覆盖舊訊息已引用的附件）
        var destName = name;
        if (usedNames.contains(destName) ||
            await File('${dir.path}/$destName').exists()) {
          final dot = destName.lastIndexOf('.');
          final stem = dot > 0 ? destName.substring(0, dot) : destName;
          final ext = dot > 0 ? destName.substring(dot) : '';
          var n = 1;
          do {
            destName = '$stem ($n)$ext';
            n++;
          } while (usedNames.contains(destName) ||
              await File('${dir.path}/$destName').exists());
        }
        usedNames.add(destName);
        final dest = File('${dir.path}/$destName');
        // 串流複製：分享檔案可達數十 MB，不得整份讀進記憶體
        await f.openRead().cast<List<int>>().pipe(dest.openWrite());
        out.add(dest.path);
      } catch (_) {}
    }
    return out;
  }

  /// 將 Android 分享選單交來的檔案複製進上傳目錄，加入目前草稿（不自動送出）。
  /// 回傳無法匯入的檔案數量。
  Future<int> importSharedFiles(List<Object?> incomingFiles) async {
    final images = <String>[];
    final docs = <DocumentAttachment>[];
    var failed = 0;

    for (final incoming in incomingFiles) {
      if (incoming is! Map) {
        failed++;
        continue;
      }
      final sourcePath = incoming['path']?.toString() ?? '';
      if (sourcePath.isEmpty || !await File(sourcePath).exists()) {
        failed++;
        continue;
      }
      final fileName = sharedFileName(incoming['fileName']?.toString() ?? '');
      final declaredMime = incoming['mime']?.toString() ?? '';

      final saved = await copyPickedFiles(
        [XFile(sourcePath)],
        names: [fileName],
      );
      if (saved.isEmpty) {
        failed++;
        continue;
      }
      final savedPath = saved.single;
      // 分享者宣告的 MIME 不可信：只在具體時採用，否則依副檔名判定
      final mime =
          declaredMime.isEmpty || declaredMime == 'application/octet-stream'
          ? mimeForSharedFile(fileName)
          : declaredMime;
      if (mime.toLowerCase().startsWith('image/') ||
          isImageExtension(fileName)) {
        images.add(savedPath);
      } else {
        docs.add(
          DocumentAttachment(path: savedPath, fileName: fileName, mime: mime),
        );
      }
    }

    if (images.isNotEmpty) mediaController.addImages(images);
    if (docs.isNotEmpty) mediaController.addFiles(docs);
    if (images.isNotEmpty || docs.isNotEmpty) onScrollToBottom();
    return failed;
  }

  /// 剝除路徑分隔符與控制字元，避免惡意顯示名稱逃出上傳目錄或產生非法檔名。
  String sharedFileName(String rawName) {
    final cleaned = rawName
        .split(RegExp(r'[/\\]'))
        .last
        .replaceAll(RegExp(r'[\u0000-\u001f\u007f]'), '')
        .trim();
    if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') {
      return 'shared_file';
    }
    return cleaned;
  }

  /// 从相册选取图片
  Future<void> onPickPhotos() async {
    try {
      // On desktop, fall back to FilePicker as image_picker is not supported.
      if (PlatformUtils.isDesktopTarget) {
        final res = await FilePicker.platform.pickFiles(
          allowMultiple: true,
          withData: false,
          type: FileType.custom,
          allowedExtensions: const ['png', 'jpg', 'jpeg', 'gif', 'webp', 'heic', 'heif'],
        );
        if (res == null || res.files.isEmpty) return;
        final toCopy = <XFile>[];
        for (final f in res.files) {
          if (f.path != null && f.path!.isNotEmpty) {
            toCopy.add(XFile(f.path!));
          }
        }
        if (toCopy.isEmpty) return;
        final paths = await copyPickedFiles(toCopy);
        if (paths.isNotEmpty) {
          mediaController.addImages(paths);
          onScrollToBottom();
        }
        return;
      }

      final picker = ImagePicker();
      final files = await picker.pickMultiImage();
      if (files.isEmpty) return;
      final paths = await copyPickedFiles(files);
      if (paths.isNotEmpty) {
        mediaController.addImages(paths);
        onScrollToBottom();
      }
    } catch (_) {}
  }

  /// 从相机拍照
  ///
  /// [context] 用于显示权限提示和错误消息
  Future<void> onPickCamera(BuildContext context) async {
    try {
      // Proactive permission check on mobile
      if (PlatformUtils.isMobile) {
        var status = await Permission.camera.status;
        // Request if not determined; otherwise guide user
        if (status.isDenied || status.isRestricted) {
          status = await Permission.camera.request();
        }
        if (!status.isGranted) {
          final l10n = AppLocalizations.of(context)!;
          showAppSnackBar(
            context,
            message: l10n.cameraPermissionDeniedMessage,
            type: NotificationType.error,
            duration: const Duration(seconds: 4),
            actionLabel: l10n.openSystemSettings,
            onAction: () {
              try {
                openAppSettings();
              } catch (_) {}
            },
          );
          return;
        }
      }
      final picker = ImagePicker();
      final file = await picker.pickImage(source: ImageSource.camera);
      if (file == null) return;
      final paths = await copyPickedFiles([file]);
      if (paths.isNotEmpty) {
        mediaController.addImages(paths);
        onScrollToBottom();
      }
    } catch (e) {
      try {
        final l10n = AppLocalizations.of(context)!;
        showAppSnackBar(
          context,
          message: l10n.cameraPermissionDeniedMessage,
          type: NotificationType.error,
          duration: const Duration(seconds: 3),
        );
      } catch (_) {}
    }
  }

  /// 根据文件扩展名推断 MIME 类型
  String inferMimeByExtension(String name) {
    final lower = name.toLowerCase();
    // Video
    if (lower.endsWith('.mp4')) return 'video/mp4';
    if (lower.endsWith('.mpeg') || lower.endsWith('.mpg')) return 'video/mpeg';
    if (lower.endsWith('.mov')) return 'video/quicktime';
    if (lower.endsWith('.avi')) return 'video/x-msvideo';
    if (lower.endsWith('.mkv')) return 'video/x-matroska';
    if (lower.endsWith('.flv')) return 'video/x-flv';
    if (lower.endsWith('.wmv')) return 'video/x-ms-wmv';
    if (lower.endsWith('.webm')) return 'video/webm';
    if (lower.endsWith('.3gp') || lower.endsWith('.3gpp')) return 'video/3gpp';
    // Documents / text
    if (lower.endsWith('.pdf')) return 'application/pdf';
    if (lower.endsWith('.doc')) return 'application/msword';
    if (lower.endsWith('.docx')) {
      return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
    }
    if (lower.endsWith('.xlsx')) {
      return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
    }
    if (lower.endsWith('.xls')) return 'application/vnd.ms-excel';
    if (lower.endsWith('.ppt')) return 'application/vnd.ms-powerpoint';
    if (lower.endsWith('.pptx')) {
      return 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
    }
    if (lower.endsWith('.csv')) return 'text/csv';
    if (lower.endsWith('.json')) return 'application/json';
    if (lower.endsWith('.js')) return 'application/javascript';
    if (lower.endsWith('.txt') || lower.endsWith('.md')) return 'text/plain';
    return 'text/plain';
  }

  /// 分享檔案的 MIME：先判圖片／影音，再交給既有副檔名表；未知二進位檔
  /// 一律回 `application/octet-stream`（不可誤標成 `text/plain`）。
  String mimeForSharedFile(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.heic')) return 'image/heic';
    if (lower.endsWith('.heif')) return 'image/heif';
    if (lower.endsWith('.mp4')) return 'video/mp4';
    if (lower.endsWith('.mov')) return 'video/quicktime';
    if (lower.endsWith('.m4a')) return 'audio/mp4';
    if (lower.endsWith('.mp3')) return 'audio/mpeg';
    if (lower.endsWith('.wav')) return 'audio/wav';
    final inferred = inferMimeByExtension(lower);
    return inferred == 'text/plain' && !_isPlainTextExtension(lower)
        ? 'application/octet-stream'
        : inferred;
  }

  static bool _isPlainTextExtension(String lower) =>
      lower.endsWith('.txt') ||
      lower.endsWith('.md') ||
      lower.endsWith('.log') ||
      lower.endsWith('.yaml') ||
      lower.endsWith('.yml');

  /// 判断文件是否为图片（根据扩展名）
  bool isImageExtension(String name) {
    final lower = name.toLowerCase();
    return lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.heic') ||
        lower.endsWith('.heif');
  }

  /// 选取文件（图片、视频、文档等）
  Future<void> onPickFiles() async {
    try {
      // No extension restriction: the allowlist kept missing common types
      // (xls, xlsx, pptx, csv, svg, archives, source files, ...). Any file is
      // accepted; images vs documents are classified by extension downstream.
      final res = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        withData: false,
        type: FileType.any,
      );
      if (res == null || res.files.isEmpty) return;
      final images = <String>[];
      final docs = <DocumentAttachment>[];

      // Build a flat list preserving order, then map saved -> type
      final toCopy = <XFile>[];
      final kinds = <bool>[]; // true=image, false=document
      final names = <String>[];
      for (final f in res.files) {
        final path = f.path;
        if (path != null && path.isNotEmpty) {
          toCopy.add(XFile(path));
          kinds.add(isImageExtension(f.name));
          names.add(f.name);
        }
      }
      if (toCopy.isEmpty) return;
      final saved = await copyPickedFiles(toCopy);
      for (int i = 0; i < saved.length; i++) {
        final savedPath = saved[i];
        final isImage = kinds[i];
        if (isImage) {
          images.add(savedPath);
        } else {
          final name = names[i];
          final mime = inferMimeByExtension(name);
          docs.add(DocumentAttachment(path: savedPath, fileName: name, mime: mime));
        }
      }
      if (images.isNotEmpty) {
        mediaController.addImages(images);
      }
      if (docs.isNotEmpty) {
        mediaController.addFiles(docs);
      }
      if (images.isNotEmpty || docs.isNotEmpty) {
        onScrollToBottom();
      }
    } catch (_) {}
  }

  /// 处理桌面端拖放的文件 (macOS/Windows/Linux)
  Future<void> onFilesDroppedDesktop(List<XFile> files) async {
    if (files.isEmpty) return;
    try {
      final images = <String>[];
      final docs = <DocumentAttachment>[];
      // Preserve order: copy all, then classify by original names
      final toCopy = <XFile>[];
      final kinds = <bool>[]; // true=image, false=document
      final names = <String>[];
      for (final f in files) {
        final name = (f.name.isNotEmpty ? f.name : (f.path.split(Platform.pathSeparator).last));
        toCopy.add(f);
        kinds.add(isImageExtension(name));
        names.add(name);
      }

      final saved = await copyPickedFiles(toCopy);
      for (int i = 0; i < saved.length; i++) {
        final savedPath = saved[i];
        final isImage = kinds[i];
        if (isImage) {
          images.add(savedPath);
        } else {
          final name = names[i];
          final mime = inferMimeByExtension(name);
          docs.add(DocumentAttachment(path: savedPath, fileName: name, mime: mime));
        }
      }
      if (images.isNotEmpty) mediaController.addImages(images);
      if (docs.isNotEmpty) mediaController.addFiles(docs);
      if (images.isNotEmpty || docs.isNotEmpty) onScrollToBottom();
    } catch (_) {}
  }
}
