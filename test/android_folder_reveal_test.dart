import 'package:OmniChat/core/services/android_folder_reveal.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AndroidFolderReveal.buildFolderUri', () {
    const String prefix =
        'content://com.android.externalstorage.documents/document/';

    test('maps the primary shared-storage root', () {
      expect(
        AndroidFolderReveal.buildFolderUri('/storage/emulated/0')?.toString(),
        '${prefix}primary%3A',
      );
      expect(
        AndroidFolderReveal.buildFolderUri('/storage/emulated/0/')?.toString(),
        '${prefix}primary%3A',
      );
      expect(
        AndroidFolderReveal.buildFolderUri('/sdcard')?.toString(),
        '${prefix}primary%3A',
      );
    });

    test('maps primary shared-storage subfolders', () {
      expect(
        AndroidFolderReveal.buildFolderUri('/storage/emulated/0/Download')
            ?.toString(),
        '${prefix}primary%3ADownload',
      );
      expect(
        AndroidFolderReveal.buildFolderUri('/storage/emulated/0/Download/')
            ?.toString(),
        '${prefix}primary%3ADownload',
      );
      expect(
        AndroidFolderReveal.buildFolderUri('/sdcard/Android/data')?.toString(),
        '${prefix}primary%3AAndroid%2Fdata',
      );
    });

    test('maps removable-storage volumes', () {
      expect(
        AndroidFolderReveal.buildFolderUri('/storage/1A2B-3C4D/Docs')
            ?.toString(),
        '${prefix}1A2B-3C4D%3ADocs',
      );
      expect(
        AndroidFolderReveal.buildFolderUri('/storage/1A2B-3C4D')?.toString(),
        '${prefix}1A2B-3C4D%3A',
      );
    });

    test('encodes spaces in folder names', () {
      expect(
        AndroidFolderReveal.buildFolderUri('/storage/emulated/0/My Files')
            ?.toString(),
        '${prefix}primary%3AMy%20Files',
      );
    });

    test('accepts file:// and content:// inputs', () {
      expect(
        AndroidFolderReveal.buildFolderUri(
          'file:///storage/emulated/0/Download',
        )?.toString(),
        '${prefix}primary%3ADownload',
      );
      expect(
        AndroidFolderReveal.buildFolderUri('${prefix}primary%3ADownload')
            ?.toString(),
        '${prefix}primary%3ADownload',
      );
    });

    test('rejects app-private and relative paths', () {
      expect(
        AndroidFolderReveal.buildFolderUri(
          '/data/user/0/com.psyche.omnichat/app_flutter/files',
        ),
        isNull,
      );
      expect(AndroidFolderReveal.buildFolderUri('relative/path'), isNull);
      expect(AndroidFolderReveal.buildFolderUri(''), isNull);
      expect(AndroidFolderReveal.buildFolderUri('/storage/emulated'), isNull);
    });
  });
}
