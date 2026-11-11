import 'dart:io';

import 'package:file_picker/file_picker.dart';
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
import 'package:OmniChat/features/chat/widgets/workspace_sheet.dart';
import 'package:OmniChat/l10n/app_localizations.dart';

/// On mobile the workspace menu is a modal bottom sheet. Subpages are pushed
/// on top of it instead of replacing it, so back returns to the workspace
/// menu; choosing a directory also keeps the sheet open.
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

  testWidgets('workspace subpages and directory picking return to the sheet', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late Directory tempDir;
    late HiveChatStorage storage;
    late ChatService chatService;
    late String conversationId;
    late Directory pickedDir;

    // Real file IO and Hive use the root event loop; testWidgets runs in a
    // fake-async zone, so the setup must run through runAsync.
    await tester.runAsync(() async {
      tempDir = await Directory.systemTemp.createTemp('omnichat_ws_sheet_');
      pickedDir = Directory('${tempDir.path}/picked');
      await pickedDir.create();

      storage = HiveChatStorage(directory: tempDir);
      chatService = ChatService(storage: storage);
      await chatService.init();
      final conversation = await chatService.createConversation(
        title: 'Workspace sheet test',
      );
      conversationId = conversation.id;
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
                  onPressed: () => showWorkspaceSheet(
                    context,
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

    // Tools page → back → workspace sheet.
    await tester.tap(find.text(l10n.workspaceToolsMenu));
    await tester.pumpAndSettle();
    expect(find.text(l10n.workspaceToolsDescription), findsOneWidget);
    expect(find.text(l10n.workspaceEnableToggle), findsNothing);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text(l10n.workspaceToolsDescription), findsNothing);
    expect(find.text(l10n.workspaceEnableToggle), findsOneWidget);

    // Directory picker → back → workspace sheet, showing the new path.
    await tester.tap(find.text(l10n.workspaceDirectoryMenu));
    await tester.pumpAndSettle();
    expect(find.text(l10n.workspaceChooseFolder), findsOneWidget);

    await tester.tap(find.text(l10n.workspaceChooseFolder));
    await tester.pumpAndSettle();
    // Let the real Hive write finish so the refreshed sheet can be pumped.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();

    expect(find.text(l10n.workspaceEnableToggle), findsOneWidget);
    expect(find.text(l10n.workspaceChooseFolder), findsNothing);
    expect(find.text(pickedDir.path), findsNWidgets(2));

    // Sync-only teardown: real file IO awaited from testWidgets teardown
    // deadlocks in the fake-async zone. The temp tree is left to the OS.
    chatService.dispose();
  });
}
