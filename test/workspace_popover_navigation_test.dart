import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/models/workspace_config.dart';
import 'package:OmniChat/core/providers/assistant_provider.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/chat/chat_service.dart';
import 'package:OmniChat/core/services/chat/storage/hive_chat_storage.dart';
import 'package:OmniChat/desktop/workspace_popover.dart';
import 'package:OmniChat/l10n/app_localizations.dart';

/// The desktop workspace panel closes while a subpage is open (it is an
/// OverlayEntry above the navigator). Closing the subpage must reopen the
/// panel, so "back" lands on the workspace menu instead of the chat.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('back from the tools page reopens the workspace panel', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late Directory tempDir;
    late HiveChatStorage storage;
    late ChatService chatService;
    late String conversationId;

    // Real file IO and Hive use the root event loop; testWidgets runs in a
    // fake-async zone, so the setup must run through runAsync.
    await tester.runAsync(() async {
      tempDir = await Directory.systemTemp.createTemp('omnichat_ws_nav_');
      storage = HiveChatStorage(directory: tempDir);
      chatService = ChatService(storage: storage);
      await chatService.init();
      final conversation = await chatService.createConversation(
        title: 'Workspace navigation test',
      );
      conversationId = conversation.id;
      await chatService.setConversationWorkspaceConfig(
        conversation.id,
        WorkspaceConfig.custom(tempDir.path),
      );
    });

    final assistants = AssistantProvider();
    final settings = SettingsProvider();
    addTearDown(assistants.dispose);
    addTearDown(settings.dispose);

    final anchorKey = GlobalKey();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ChatService>.value(value: chatService),
          ChangeNotifierProvider<AssistantProvider>.value(value: assistants),
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Center(
              child: Builder(
                builder: (context) => TextButton(
                  key: anchorKey,
                  onPressed: () => showDesktopWorkspacePopover(
                    context,
                    anchorKey: anchorKey,
                    conversationId: conversationId,
                  ),
                  child: const Text('workspace'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final l10n = await AppLocalizations.delegate.load(const Locale('en'));

    await tester.tap(find.text('workspace'));
    await tester.pumpAndSettle();
    expect(find.text(l10n.workspaceEnableToggle), findsOneWidget);

    await tester.tap(find.text(l10n.workspaceToolsMenu));
    await tester.pumpAndSettle();
    expect(find.text(l10n.workspaceToolsDescription), findsOneWidget);
    expect(find.text(l10n.workspaceEnableToggle), findsNothing);

    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.text(l10n.workspaceToolsDescription), findsNothing);
    expect(find.text(l10n.workspaceEnableToggle), findsOneWidget);

    // Sync-only teardown: real file IO awaited from testWidgets teardown
    // deadlocks in the fake-async zone. The temp tree is left to the OS.
    chatService.dispose();
  });
}
