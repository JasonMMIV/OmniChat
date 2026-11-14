import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/agent/subagent_profiles.dart';
import 'package:OmniChat/features/chat/widgets/chat_message_widget.dart';
import 'package:OmniChat/icons/lucide_adapter.dart';
import 'package:OmniChat/l10n/app_localizations.dart';

class _FakeSettings extends ChangeNotifier implements SettingsProvider {
  @override
  List<SubagentProfile> get subagentProfiles => SubagentProfiles.builtIns;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('delegated card names the profile and continues its session', (
    tester,
  ) async {
    final settings = _FakeSettings();
    addTearDown(settings.dispose);
    String? continuedProfile;
    String? continuedSession;

    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: settings,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: DelegatedSubagentCard(
              part: const ToolUIPart(
                id: 'delegate-1',
                toolName: 'delegate_subagent',
                arguments: <String, dynamic>{'agent': 'explore'},
                content: '{"type":"subagent_result"}',
                subagentTrace: <String, dynamic>{
                  'status': 'finished',
                  'profile': 'explore',
                  'sessionId': 'session-1',
                  'toolCalls': 1,
                  'items': <Map<String, dynamic>>[
                    {'t': 'file_read', 'ms': 20, 'chars': 40},
                  ],
                },
              ),
              onContinueSubagent: (profile, session) {
                continuedProfile = profile;
                continuedSession = session;
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Delegated to Explore'), findsOneWidget);
    expect(find.text('Continue'), findsOneWidget);
    expect(find.byIcon(Lucide.UsersRoundCollaboration), findsOneWidget);
    expect(find.byIcon(Lucide.CornerDownRight), findsOneWidget);
    expect(find.byIcon(Lucide.Bot), findsNothing);

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(continuedProfile, 'explore');
    expect(continuedSession, 'session-1');
  });
}
