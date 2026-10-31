import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:OmniChat/core/services/chat/chat_service.dart';
import 'package:OmniChat/core/services/chat/storage/chat_storage.dart';
import 'package:OmniChat/features/settings/pages/chat_storage_page.dart';
import 'package:OmniChat/l10n/app_localizations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dataDirectory;
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  const packageInfoChannel = MethodChannel(
    'dev.fluttercommunity.plus/package_info',
  );

  setUp(() async {
    dataDirectory = await Directory.systemTemp.createTemp(
      'omnichat_chat_storage_page_',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
          if (call.method == 'getApplicationSupportDirectory' ||
              call.method == 'getApplicationDocumentsDirectory') {
            return dataDirectory.path;
          }
          return null;
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(packageInfoChannel, (call) async {
          if (call.method == 'getAll') {
            return <String, dynamic>{
              'appName': 'OmniChat',
              'packageName': 'com.psyche.omnichat',
              'version': '1.0.0',
              'buildNumber': '1',
            };
          }
          return null;
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(packageInfoChannel, null);
    if (await dataDirectory.exists()) {
      await dataDirectory.delete(recursive: true);
    }
  });

  testWidgets('renders the SQLite and legacy sections', (tester) async {
    final chatService = ChatService(backend: ChatStorageBackend.hive);
    addTearDown(chatService.dispose);

    // ChatStorageInfoService probes the real filesystem; widget tests run in a
    // fake-async zone, so allow the page's I/O to complete first.
    await tester.runAsync(() async {
      await tester.pumpWidget(
        ChangeNotifierProvider<ChatService>.value(
          value: chatService,
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const ChatStoragePage(),
          ),
        ),
      );
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
        await tester.pump();
      }
    });
    await tester.pump();

    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(l10n.chatStorageSqliteSection), findsOneWidget);
    expect(find.text(l10n.chatStorageLegacySection), findsOneWidget);
    expect(find.text(l10n.chatStorageNoLegacyFiles), findsOneWidget);
    expect(find.text(l10n.chatStorageOptimize), findsWidgets);
  });
}
