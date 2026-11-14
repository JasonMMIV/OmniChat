import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/services/agent/subagent_profiles.dart';
import 'package:OmniChat/icons/lucide_adapter.dart';
import 'package:OmniChat/shared/widgets/subagent_profile_icon.dart';

void main() {
  test('built-in profiles keep distinct role icons', () {
    expect(subagentProfileIcon('general'), Lucide.UserRoundCheck);
    expect(subagentProfileIcon('explore'), Lucide.Compass);
    expect(subagentProfileIcon('reviewer'), Lucide.Eye);
    expect(subagentProfileIcon('researcher'), Lucide.UserRoundSearch);
    expect(subagentProfileIcon('coder'), Lucide.Code);
    expect(subagentProfileIcon('my-custom'), Lucide.ContactRound);
  });

  test('every built-in profile has its own icon, never the robot', () {
    for (final profile in SubagentProfiles.builtIns) {
      final icon = subagentProfileIcon(profile.id);
      expect(icon, isNot(Lucide.Bot));
      // A renamed built-in id would silently fall back to the custom icon;
      // this catches that regression in the mapping test.
      expect(icon, isNot(Lucide.ContactRound));
    }
  });

  testWidgets('read-only profiles get the lock badge', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SubagentProfileIcon(
            profile: SubagentProfiles.builtIn('explore'),
            size: 20,
          ),
        ),
      ),
    );

    expect(find.byIcon(Lucide.Compass), findsOneWidget);
    expect(find.byIcon(Lucide.Lock), findsOneWidget);
  });

  testWidgets('writable profiles have no lock badge', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SubagentProfileIcon(
            profile: SubagentProfiles.builtIn('general'),
            size: 20,
          ),
        ),
      ),
    );

    expect(find.byIcon(Lucide.UserRoundCheck), findsOneWidget);
    expect(find.byIcon(Lucide.Lock), findsNothing);
  });
}
