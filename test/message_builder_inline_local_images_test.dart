import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/services/chat/chat_service.dart';
import 'package:OmniChat/features/home/services/message_builder_service.dart';

/// 1x1 transparent PNG.
const String _onePixelPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';

/// MessageBuilderService only needs the context; the inliner does not touch
/// ChatService, so the stub forwards everything to noSuchMethod.
class _StubChatService extends ChangeNotifier implements ChatService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<BuildContext> _pumpContext(WidgetTester tester) async {
  late BuildContext captured;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) {
          captured = context;
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  return captured;
}

void main() {
  testWidgets('inlineLocalImages skips tool results and structured content', (
    tester,
  ) async {
    final context = await _pumpContext(tester);

    await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('omni_inline_builder_');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final file = File('${dir.path}${Platform.pathSeparator}pic.png');
      await file.writeAsBytes(base64Decode(_onePixelPng));

      final service = MessageBuilderService(
        chatService: _StubChatService(),
        contextProvider: context,
      );
      const protocolRelative =
          '![x](//thumb.wikimedia.org/wikipedia/commons/a.png)';
      final localInTool = '![x](${file.path})';
      final structured = <dynamic>[
        <String, dynamic>{'type': 'text', 'text': 'hello'},
      ];
      final apiMessages = <Map<String, dynamic>>[
        <String, dynamic>{'role': 'tool', 'content': protocolRelative},
        <String, dynamic>{'role': 'tool', 'content': localInTool},
        <String, dynamic>{'role': 'user', 'content': '![x](${file.path})'},
        <String, dynamic>{'role': 'user', 'content': structured},
      ];

      await service.inlineLocalImages(apiMessages);

      // Tool results are model-facing text: never inline, never touch UNC.
      expect(apiMessages[0]['content'], protocolRelative);
      expect(apiMessages[1]['content'], localInTool);
      // Real user images still work.
      expect(
        apiMessages[2]['content'],
        contains('data:image/png;base64,'),
      );
      expect(apiMessages[2]['content'], isNot(contains(file.path)));
      // Structured multimodal content is left as-is.
      expect(identical(apiMessages[3]['content'], structured), isTrue);
    });
  });
}
