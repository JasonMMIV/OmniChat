// Multimodal plan C2/C3: missing attachment files must degrade to a visible
// unavailable state instead of throwing or opening a non-existent file.

import 'dart:io';

import 'package:OmniChat/features/chat/widgets/user_attachment_card.dart';
import 'package:OmniChat/l10n/app_localizations.dart';
import 'package:OmniChat/shared/widgets/audio_clip_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Widget child) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: Center(child: child)),
);

Future<void> _pumpUntil(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 30; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    if (finder.evaluate().isNotEmpty) return;
  }
}

void main() {
  late String missingPath;

  setUp(() {
    missingPath = '${Directory.systemTemp.path}/omnichat-missing-attachment'
        '.${DateTime.now().microsecondsSinceEpoch}.bin';
  });

  testWidgets('document card shows the unavailable state', (tester) async {
    await tester.pumpWidget(
      _app(
        UserAttachmentCard(
          path: missingPath,
          fileName: 'brief.pdf',
          mime: 'application/pdf',
        ),
      ),
    );
    await _pumpUntil(tester, find.text('Attachment unavailable'));
    expect(find.text('brief.pdf'), findsOneWidget);
    expect(find.text('Attachment unavailable'), findsOneWidget);
  });

  testWidgets('audio player shows the unavailable state', (tester) async {
    await tester.pumpWidget(
      _app(AudioClipPlayer(path: missingPath, fileName: 'voice.mp3')),
    );
    await _pumpUntil(tester, find.text('Attachment unavailable'));
    expect(find.text('voice.mp3'), findsOneWidget);
    expect(find.text('Attachment unavailable'), findsOneWidget);
  });

  testWidgets('composer-style compact audio player also degrades', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        AudioClipPlayer(
          path: missingPath,
          fileName: 'voice.mp3',
          compact: true,
        ),
      ),
    );
    await _pumpUntil(tester, find.text('Attachment unavailable'));
    expect(find.text('Attachment unavailable'), findsOneWidget);
  });
}
