import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/models/conversation.dart';
import 'package:OmniChat/core/models/workspace_config.dart';
import 'package:OmniChat/core/providers/assistant_provider.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/chat/chat_service.dart';
import 'package:OmniChat/core/services/chat/storage/hive_chat_storage.dart';
import 'package:OmniChat/desktop/workspace_popover.dart';
import 'package:OmniChat/l10n/app_localizations.dart';

/// The desktop workspace panel is an OverlayEntry inserted above the
/// navigator. A dialog opened while that entry is still mounted renders
/// behind it, so its taps hit the panel's dismiss barrier. The directory
/// picker must close the panel first (same fix as the Add-ons menu) or the
/// chosen folder is discarded when the popover state unmounts.
class _FakeFilePicker extends FilePicker {
  _FakeFilePicker(this.path);

  final String? path;

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    bool lockParentWindow = false,
    String? initialDirectory,
  }) async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets(
    'choosing a folder from the desktop popover persists the directory',
    (tester) async {
      late Directory tempDir;
      late HiveChatStorage storage;
      late ChatService chatService;
      late Conversation conversation;
      late Directory pickedDir;

      // Real file IO and Hive use the root event loop; testWidgets runs in a
      // fake-async zone, so the setup must run through runAsync.
      await tester.runAsync(() async {
        tempDir = await Directory.systemTemp.createTemp('omnichat_ws_');
        pickedDir = Directory('${tempDir.path}/picked');
        await pickedDir.create();

        storage = HiveChatStorage(directory: tempDir);
        chatService = ChatService(storage: storage);
        await chatService.init();
        conversation = await chatService.createConversation(
          title: 'Workspace test',
        );
        await chatService.setConversationWorkspaceConfig(
          conversation.id,
          WorkspaceConfig.custom(tempDir.path),
        );
      });

      FilePicker.platform = _FakeFilePicker(pickedDir.path);

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
                      conversationId: conversation.id,
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
      expect(find.text(l10n.workspaceDirectoryMenu), findsOneWidget);

      // "Preview site" sits directly above the "Files" entry: the menu reads
      // Directory → Tools → Preview site → Files (2026-11-10 reorder).
      expect(find.text(l10n.devPreviewMenuEntry), findsOneWidget);
      expect(
        tester.getTopLeft(find.text(l10n.devPreviewMenuEntry)).dy,
        lessThan(tester.getTopLeft(find.text(l10n.workspaceFiles)).dy),
      );

      await tester.tap(find.text(l10n.workspaceDirectoryMenu));
      await tester.pumpAndSettle();
      expect(find.text(l10n.workspaceChooseFolder), findsOneWidget);

      // Before the fix this tap lands on the popover's full-screen barrier:
      // the popover closes and the picker result is discarded on return.
      await tester.tap(find.text(l10n.workspaceChooseFolder));
      await tester.pumpAndSettle();
      // The workspace panel reopens after the (real-IO) Hive write finishes.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();

      expect(
        chatService.getConversationWorkspaceConfig(conversation.id),
        WorkspaceConfig.custom(pickedDir.path),
      );
      // The directory sheet is gone and the workspace panel is back on the
      // freshly chosen directory — selecting a folder must not drop the user
      // back to the chat.
      expect(find.text(l10n.workspaceEnableToggle), findsOneWidget);
      expect(find.text(l10n.workspaceChooseFolder), findsNothing);

      // Sync-only teardown: real file IO awaited from testWidgets teardown
      // deadlocks in the fake-async zone. The temp tree is left to the OS.
      chatService.dispose();
    },
  );
}
