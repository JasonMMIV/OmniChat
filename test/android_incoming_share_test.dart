// Android share intake: the MethodChannel bridge must degrade to an empty
// queue whenever the platform side is absent (desktop, tests), and the
// composer import must sanitize hostile names, never overwrite an existing
// attachment, and count unreadable files instead of dropping the whole share.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/features/home/services/android_incoming_share.dart';
import 'package:OmniChat/features/home/services/file_upload_service.dart';
import 'package:OmniChat/features/home/widgets/chat_input_bar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const shareChannel = MethodChannel('omnichat/incoming_share');
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  late Directory dataDirectory;

  FileUploadService createService() => FileUploadService(
    mediaController: ChatInputBarController(),
    onScrollToBottom: () {},
  );

  setUp(() async {
    dataDirectory = await Directory.systemTemp.createTemp('omnichat_share_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
          if (call.method == 'getApplicationDocumentsDirectory' ||
              call.method == 'getApplicationSupportDirectory') {
            return dataDirectory.path;
          }
          return null;
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(shareChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    if (await dataDirectory.exists()) {
      await dataDirectory.delete(recursive: true);
    }
  });

  group('AndroidIncomingShare bridge', () {
    test('getPendingShares normalizes method-channel maps', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(shareChannel, (call) async {
            if (call.method != 'getPendingShares') return null;
            return <Object?>[
              <Object?, Object?>{
                'id': 'share-1',
                'text': 'hello',
                'failedFiles': 1,
                'files': <Object?>[
                  <Object?, Object?>{
                    'path': '/tmp/a.png',
                    'fileName': 'a.png',
                    'mime': 'image/png',
                  },
                ],
              },
            ];
          });

      final shares = await AndroidIncomingShare.getPendingShares();

      expect(shares, hasLength(1));
      expect(shares.single['id'], 'share-1');
      expect(shares.single['text'], 'hello');
      expect(shares.single['failedFiles'], 1);
      final files = shares.single['files'] as List<Object?>;
      expect((files.single as Map<Object?, Object?>)['fileName'], 'a.png');
    });

    test('platform failures degrade to an empty queue', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(shareChannel, (call) async {
            throw PlatformException(code: 'boom');
          });

      expect(await AndroidIncomingShare.getPendingShares(), isEmpty);
      expect(await AndroidIncomingShare.acknowledge('share-1'), isFalse);
    });
  });

  group('FileUploadService.importSharedFiles', () {
    test(
      'copies readable files under their own name and counts failures',
      () async {
        final source = File('${dataDirectory.path}/note.txt')
          ..writeAsStringSync('shared body');
        final service = createService();

        final failed = await service.importSharedFiles([
          {'path': source.path, 'fileName': 'note.txt', 'mime': 'text/plain'},
          {
            'path': '${dataDirectory.path}/missing.txt',
            'fileName': 'missing.txt',
            'mime': 'text/plain',
          },
          'not-a-map',
        ]);

        expect(failed, 2);
        final copied = File('${dataDirectory.path}/upload/note.txt');
        expect(copied.existsSync(), isTrue);
        expect(copied.readAsStringSync(), 'shared body');
      },
    );

    test('sanitizes hostile names and never overwrites a draft', () async {
      final source = File('${dataDirectory.path}/payload.bin')
        ..writeAsBytesSync(List<int>.filled(8, 7));
      final service = createService();

      final first = await service.importSharedFiles([
        {'path': source.path, 'fileName': '../../evil.png', 'mime': ''},
      ]);
      final second = await service.importSharedFiles([
        {'path': source.path, 'fileName': 'evil.png', 'mime': ''},
      ]);

      expect(first, 0);
      expect(second, 0);
      final names = Directory('${dataDirectory.path}/upload')
          .listSync()
          .whereType<File>()
          .map((file) => file.uri.pathSegments.last)
          .toSet();
      expect(names, contains('evil.png'));
      expect(names, contains('evil (1).png'));
      expect(names.any((name) => name.contains('..')), isFalse);
    });

    test('sharedFileName strips separators and control characters', () {
      final service = createService();

      expect(service.sharedFileName(r'..\..\evil.txt'), 'evil.txt');
      expect(service.sharedFileName('a\u0000b.txt'), 'ab.txt');
      expect(service.sharedFileName('   '), 'shared_file');
      expect(service.sharedFileName('..'), 'shared_file');
    });

    test('mimeForSharedFile keeps office types and never guesses text/plain', () {
      final service = createService();

      expect(service.mimeForSharedFile('photo.png'), 'image/png');
      expect(
        service.mimeForSharedFile('deck.pptx'),
        'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      );
      expect(service.mimeForSharedFile('brief.doc'), 'application/msword');
      expect(
        service.mimeForSharedFile('archive.zip'),
        'application/octet-stream',
      );
      expect(service.mimeForSharedFile('notes.md'), 'text/plain');
    });
  });

  group('AndroidIncomingShare.mergeShareText', () {
    test('appends to the draft instead of overwriting it', () {
      expect(AndroidIncomingShare.mergeShareText('', 'hello'), 'hello');
      expect(
        AndroidIncomingShare.mergeShareText('draft', 'hello'),
        'draft\nhello',
      );
      expect(
        AndroidIncomingShare.mergeShareText('draft\n', 'hello'),
        'draft\nhello',
      );
      expect(AndroidIncomingShare.mergeShareText('draft', ''), 'draft');
    });
  });
}
