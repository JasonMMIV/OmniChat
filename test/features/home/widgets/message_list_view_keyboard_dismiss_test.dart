import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/models/chat_message.dart';
import 'package:OmniChat/core/providers/assistant_provider.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/providers/user_provider.dart';
import 'package:OmniChat/core/services/chat/chat_service.dart';
import 'package:OmniChat/features/home/widgets/message_list_view.dart';
import 'package:OmniChat/l10n/app_localizations.dart';

/// kelivo v1.1.17 移植（upstream commit 97912775）：
/// 桌面版（macOS/Windows/Linux）訊息列表在捲動時不得觸發 keyboard-dismiss
/// （unfocus），否則文字選取會隨捲動消失；行動版維持 onDrag（捲動收起鍵盤）。
void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pumpListView(WidgetTester tester, TargetPlatform platform) async {
    debugDefaultTargetPlatformOverride = platform;

    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);

    // 以 .value 注入 providers（.value 不會在 tree 解構時 dispose 它們），
    // 並以 pump 推進 fake time 讓 SharedPreferences mock 的 _load 在 tree 存活期間完成。
    final settings = SettingsProvider();
    final assistant = AssistantProvider();
    final user = UserProvider();
    final chat = ChatService();
    addTearDown(() {
      settings.dispose();
      assistant.dispose();
      user.dispose();
      chat.dispose();
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
          ChangeNotifierProvider<AssistantProvider>.value(value: assistant),
          ChangeNotifierProvider<UserProvider>.value(value: user),
          ChangeNotifierProvider<ChatService>.value(value: chat),
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: MessageListView(
              scrollController: scrollController,
              messages: [
                ChatMessage(
                  role: 'user',
                  content: 'hi',
                  conversationId: 'c1',
                ),
              ],
              versionSelections: const {},
              currentConversation: null,
              messageKeys: <String, GlobalKey>{},
              reasoning: const {},
              reasoningSegments: const {},
              toolParts: const {},
              translations: const {},
              selecting: false,
              selectedItems: const {},
              dividerPadding: EdgeInsets.zero,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    // 推進 fake time，讓 providers 的非同步 _load 完成（避免測試尾聲才 notifyListeners）。
    await tester.pump(const Duration(milliseconds: 50));
    // 必須在測試 body 內重置（framework 的 invariant check 在 teardown 之前執行）。
    debugDefaultTargetPlatformOverride = null;
  }

  testWidgets('macOS 訊息列表捲動不主動清除文字選取焦點（manual）', (tester) async {
    await pumpListView(tester, TargetPlatform.macOS);

    final listView = tester.widget<ListView>(find.byType(ListView));
    expect(listView.keyboardDismissBehavior, ScrollViewKeyboardDismissBehavior.manual);
  });

  testWidgets('Windows 訊息列表捲動不主動清除文字選取焦點（manual）', (tester) async {
    await pumpListView(tester, TargetPlatform.windows);

    final listView = tester.widget<ListView>(find.byType(ListView));
    expect(listView.keyboardDismissBehavior, ScrollViewKeyboardDismissBehavior.manual);
  });

  testWidgets('Linux 訊息列表捲動不主動清除文字選取焦點（manual）', (tester) async {
    await pumpListView(tester, TargetPlatform.linux);

    final listView = tester.widget<ListView>(find.byType(ListView));
    expect(listView.keyboardDismissBehavior, ScrollViewKeyboardDismissBehavior.manual);
  });

  testWidgets('Android 訊息列表捲動仍然收起鍵盤（onDrag）', (tester) async {
    await pumpListView(tester, TargetPlatform.android);

    final listView = tester.widget<ListView>(find.byType(ListView));
    expect(listView.keyboardDismissBehavior, ScrollViewKeyboardDismissBehavior.onDrag);
  });
}
