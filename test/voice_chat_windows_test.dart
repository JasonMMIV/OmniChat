import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/features/voice_chat/pages/voice_chat_screen.dart';
import 'package:OmniChat/core/services/chat/chat_service.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/providers/assistant_provider.dart';
import 'package:OmniChat/core/providers/tts_provider.dart';
import 'package:OmniChat/core/providers/user_provider.dart';
import 'package:provider/provider.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

// 使用 Dummy 類別
class DummyChatService extends ChangeNotifier implements ChatService {
  @override
  String? get currentConversationId => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
class DummySettingsProvider extends ChangeNotifier implements SettingsProvider {
  @override
  bool get searchEnabled => false;
  @override
  String? get currentModelProvider => 'openai';
  @override
  String? get currentModelId => 'gpt-3.5-turbo';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
class DummyAssistantProvider extends ChangeNotifier implements AssistantProvider {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
class DummyTtsProvider extends ChangeNotifier implements TtsProvider {
  @override
  Future<void> stop() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
class DummyUserProvider extends ChangeNotifier implements UserProvider {
  @override
  String get name => 'User';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('VoiceChatScreen Windows initialization test', (WidgetTester tester) async {
    // 確保測試環境辨識為 Windows
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;

    final dummyChatService = DummyChatService();
    final dummySettings = DummySettingsProvider();
    final dummyAssistant = DummyAssistantProvider();
    final dummyTts = DummyTtsProvider();
    final dummyUser = DummyUserProvider();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ChatService>.value(value: dummyChatService),
          ChangeNotifierProvider<SettingsProvider>.value(value: dummySettings),
          ChangeNotifierProvider<AssistantProvider>.value(value: dummyAssistant),
          ChangeNotifierProvider<TtsProvider>.value(value: dummyTts),
          ChangeNotifierProvider<UserProvider>.value(value: dummyUser),
        ],
        child: const MaterialApp(
          localizationsDelegates: [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: VoiceChatScreen(),
        ),
      ),
    );

    // 驗證是否成功載入畫面（非崩潰狀態）
    expect(find.byType(VoiceChatScreen), findsOneWidget);
    
    // 處理 dispose 中剩餘的計時器 (拉長等待時間以確保完成)
    await tester.pump(const Duration(seconds: 1));
    
    debugDefaultTargetPlatformOverride = null;
  });
}
