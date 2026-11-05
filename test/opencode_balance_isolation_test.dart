import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/features/provider/widgets/provider_balance_text.dart';
import 'package:OmniChat/icons/lucide_adapter.dart';

void main() {
  for (final key in const ['OpenCode Zen', 'OpenCode Go']) {
    testWidgets('$key renders no balance row', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});

      await tester.pumpWidget(
        ChangeNotifierProvider<SettingsProvider>.value(
          value: SettingsProvider(),
          child: MaterialApp(
            home: Scaffold(body: ProviderBalanceText(providerKey: key)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Lucide.Banknote), findsNothing);
      expect(find.text('...'), findsNothing);
      expect(find.text('?'), findsNothing);
    });
  }
}
