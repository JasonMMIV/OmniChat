import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:OmniChat/core/models/file_record.dart';
import 'package:OmniChat/core/services/chat/chat_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dataDirectory;
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() async {
    dataDirectory = await Directory.systemTemp.createTemp(
      'omnichat_chat_service_',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
          if (call.method == 'getApplicationSupportDirectory' ||
              call.method == 'getApplicationDocumentsDirectory') {
            return dataDirectory.path;
          }
          return null;
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    await Hive.close();
    if (await dataDirectory.exists()) {
      await dataDirectory.delete(recursive: true);
    }
  });

  test('persists a file record for an assistant message', () async {
    final service = ChatService();
    await service.init();

    const messageId = 'assistant-message';
    final record = FileRecord(
      path: r'C:\workspace\notes.md',
      fileName: 'notes.md',
      sizeBytes: 12,
      createdAt: DateTime(2026, 8, 3),
    );

    await service.addMessageFileRecord(messageId, record);

    final stored = service.getMessageFileRecords(messageId);
    expect(stored, hasLength(1));
    expect(stored.single.path, record.path);
    expect(stored.single.fileName, record.fileName);
    expect(stored.single.sizeBytes, record.sizeBytes);
    final boxFile = File('${dataDirectory.path}/message_file_records_v1.hive');
    expect(await boxFile.length(), greaterThan(0));
  });

  test(
    'bounds persisted file-read results and tolerates legacy content types',
    () async {
      final service = ChatService();
      await service.init();

      final content =
          'header\n' * (ChatService.maxPersistedFileReadResultChars + 100);
      await service.setToolEvents('large-tool-result', [
        {
          'id': 'read-1',
          'name': 'file_read',
          'arguments': <String, dynamic>{},
          'content': content,
        },
      ]);
      final stored = service.getToolEvents('large-tool-result');
      final storedContent = stored.single['content'] as String;
      expect(
        storedContent.length,
        lessThanOrEqualTo(ChatService.maxPersistedFileReadResultChars),
      );
      expect(storedContent, contains('persisted preview'));

      await service.setToolEvents('legacy-tool-result', [
        {
          'id': 'legacy-1',
          'name': 'file_read',
          'arguments': <String, dynamic>{},
          'content': <String, dynamic>{'unexpected': true},
        },
      ]);
      expect(
        service.getToolEvents('legacy-tool-result').single['content'],
        isNull,
      );
    },
  );
}
