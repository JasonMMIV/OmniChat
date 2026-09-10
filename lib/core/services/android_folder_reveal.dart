import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Opens folders in the Android system file manager.
///
/// Android has no generic "show in folder" API. Shared-storage folders can be
/// handed to the system DocumentsUI as a SAF document URI with the directory
/// MIME type; app-private folders live outside every document provider, so no
/// external app can display them and [revealFolder] reports failure instead.
class AndroidFolderReveal {
  AndroidFolderReveal._();

  static const MethodChannel _channel =
      MethodChannel('omnichat/folder_reveal');

  /// Builds the SAF document URI for a shared-storage folder path.
  ///
  /// Returns null when the path cannot be opened by an external app
  /// (app-private directories, relative paths, ...).
  @visibleForTesting
  static Uri? buildFolderUri(String folderPath) {
    final trimmed = folderPath.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.startsWith('content://')) return Uri.tryParse(trimmed);
    final raw =
        trimmed.startsWith('file://') ? trimmed.substring(7) : trimmed;

    const primaryRoot = '/storage/emulated/0';
    const sdcardRoot = '/sdcard';
    final removableVolume =
        RegExp(r'^/storage/([0-9A-Fa-f]{4}-[0-9A-Fa-f]{4})(/.*)?$')
            .firstMatch(raw);

    final String docId;
    if (raw == primaryRoot || raw.startsWith('$primaryRoot/')) {
      docId = 'primary:${_trimSlashes(raw.substring(primaryRoot.length))}';
    } else if (raw == sdcardRoot || raw.startsWith('$sdcardRoot/')) {
      docId = 'primary:${_trimSlashes(raw.substring(sdcardRoot.length))}';
    } else if (removableVolume != null) {
      final volume = removableVolume.group(1);
      final relative = _trimSlashes(removableVolume.group(2) ?? '');
      docId = '$volume:$relative';
    } else {
      return null;
    }

    return Uri.parse(
      'content://com.android.externalstorage.documents/document/'
      '${Uri.encodeComponent(docId)}',
    );
  }

  static String _trimSlashes(String value) {
    var result = value;
    while (result.startsWith('/')) {
      result = result.substring(1);
    }
    while (result.endsWith('/')) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }

  /// Opens [folderPath] in the system file manager.
  /// Returns true only when the folder was actually opened.
  static Future<bool> revealFolder(String folderPath) async {
    if (defaultTargetPlatform != TargetPlatform.android) return false;
    final uri = buildFolderUri(folderPath);
    if (uri == null) return false;
    try {
      final opened = await _channel.invokeMethod<bool>(
        'revealFolder',
        <String, String>{'uri': uri.toString()},
      );
      return opened ?? false;
    } catch (_) {
      return false;
    }
  }
}
