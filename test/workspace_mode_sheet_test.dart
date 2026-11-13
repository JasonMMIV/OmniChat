import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/models/workspace_config.dart';
import 'package:OmniChat/features/chat/widgets/workspace_settings_dialog.dart';
import 'package:OmniChat/l10n/app_localizations.dart';

void main() {
  testWidgets(
    'workspace directory sheet offers App private first without the default-directory gear',
    (tester) async {
      WorkspaceConfig? result;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () async {
                    result = await showConversationWorkspaceModeSheet(
                      context,
                      initial: const WorkspaceConfig.useDefault(),
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      final appPrivate = find.text(l10n.workspaceUseAppPrivateDirectory);
      final useDefault = find.text(l10n.workspaceUseDefaultDirectory);

      expect(appPrivate, findsOneWidget);
      expect(useDefault, findsOneWidget);
      expect(
        tester.getTopLeft(appPrivate).dy,
        lessThan(tester.getTopLeft(useDefault).dy),
      );
      expect(
        find.byTooltip(l10n.workspaceDefaultDirectorySettings),
        findsNothing,
      );

      await tester.tap(appPrivate);
      await tester.pumpAndSettle();
      expect(result, const WorkspaceConfig.appPrivate());
    },
  );

  testWidgets(
    'project workspace sheet keeps disable first and puts App private second',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showProjectWorkspaceSettingsSheet(
                    context,
                    initial: const WorkspaceConfig.useDefault(),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      final appPrivate = find.text(l10n.workspaceUseAppPrivateDirectory);
      final useDefault = find.text(l10n.workspaceUseDefaultDirectory);
      final disabled = find.text(l10n.workspaceDoNotUse);

      expect(appPrivate, findsOneWidget);
      expect(useDefault, findsOneWidget);
      expect(disabled, findsOneWidget);
      expect(
        tester.getTopLeft(disabled).dy,
        lessThan(tester.getTopLeft(appPrivate).dy),
      );
      expect(
        tester.getTopLeft(appPrivate).dy,
        lessThan(tester.getTopLeft(useDefault).dy),
      );
    },
  );
}
