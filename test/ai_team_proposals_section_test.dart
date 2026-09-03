import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:OmniChat/features/chat/widgets/ai_team_proposals_section.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('AiTeamProposalsSection uses transparent background, grey text, and non-bold title',
      (WidgetTester tester) async {
    final sampleData = jsonEncode([
      {
        'providerKey': 'openai',
        'modelId': 'gpt-4o',
        'content': 'This is a sample proposal answer.',
        'reasoning': 'This is sample thinking.',
        'toolCalls': [],
      }
    ]);

    final settings = SettingsProvider();

    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: settings,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh', 'TW'),
          theme: ThemeData.light(),
          home: Scaffold(
            body: AiTeamProposalsSection(
              data: sampleData,
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // 1. Check title text exists and is non-bold with grey color
    final titleFinder = find.byWidgetPredicate(
      (w) => w is Text && (w.data == '協作過程' || w.data == '协作过程' || w.data == 'Collaboration Process'),
    );
    expect(titleFinder, findsOneWidget);
    final Text titleText = tester.widget(titleFinder);
    expect(titleText.style?.fontWeight, equals(FontWeight.normal));
    expect(titleText.style?.color, equals(const Color(0xFF7E7F83)));

    // 2. Check main container has transparent background
    final containerFinder = find.byType(Container).first;
    final Container container = tester.widget(containerFinder);
    final decoration = container.decoration as BoxDecoration?;
    expect(decoration?.color, equals(Colors.transparent));
  });
}
