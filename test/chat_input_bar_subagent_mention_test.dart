import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/providers/assistant_provider.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/features/home/widgets/chat_input_bar.dart';
import 'package:OmniChat/l10n/app_localizations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('inserting a profile mention puts @id at the cursor', (
    tester,
  ) async {
    final text = TextEditingController();
    final media = ChatInputBarController();
    addTearDown(text.dispose);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => SettingsProvider()),
          ChangeNotifierProvider(create: (_) => AssistantProvider()),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ChatInputBar(
              controller: text,
              mediaController: media,
              loading: false,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    media.insertSubagentMention('explore');
    await tester.pump();

    expect(text.text, '@explore ');
    expect(text.selection.baseOffset, '@explore '.length);
  });

  testWidgets('inserting another profile replaces the leading mention', (
    tester,
  ) async {
    final text = TextEditingController(text: '@explore old task');
    final media = ChatInputBarController();
    addTearDown(text.dispose);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => SettingsProvider()),
          ChangeNotifierProvider(create: (_) => AssistantProvider()),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ChatInputBar(
              controller: text,
              mediaController: media,
              loading: false,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    media.insertSubagentMention('reviewer');
    await tester.pump();

    expect(text.text, '@reviewer old task');
  });

  testWidgets('inserting the same mention twice does not duplicate it', (
    tester,
  ) async {
    final text = TextEditingController();
    final media = ChatInputBarController();
    addTearDown(text.dispose);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => SettingsProvider()),
          ChangeNotifierProvider(create: (_) => AssistantProvider()),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ChatInputBar(
              controller: text,
              mediaController: media,
              loading: false,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    media.insertSubagentMention('explore');
    media.insertSubagentMention('explore');
    await tester.pump();

    expect(text.text, '@explore ');
  });
}
