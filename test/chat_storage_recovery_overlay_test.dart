import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/services/chat/storage/chat_storage_startup_status.dart';
import 'package:OmniChat/features/home/widgets/chat_storage_recovery_overlay.dart';
import 'package:OmniChat/l10n/app_localizations.dart';

Widget _app({
  required ChatStorageInitStatus status,
  bool hasLegacyHive = true,
  Future<bool> Function()? onRestore,
  Future<void> Function()? onRebuild,
  Future<void> Function()? onReset,
  Future<void> Function()? onContinueLegacy,
}) {
  return MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: Stack(
        children: [
          ChatStorageRecoveryOverlay(
            status: status,
            hasLegacyHive: hasLegacyHive,
            onRestoreBackup: onRestore ?? () async => true,
            onRebuildFromHive: onRebuild ?? () async {},
            onReset: onReset ?? () async {},
            onContinueLegacy: onContinueLegacy ?? () async {},
          ),
        ],
      ),
    ),
  );
}

void main() {
  const status = ChatStorageInitStatus(
    phase: ChatStorageInitPhase.restoreRequired,
    message: 'A prior installation was recorded but chat_v2.sqlite is missing.',
  );

  testWidgets('shows restore, rebuild, reset, and explicit legacy choices', (
    tester,
  ) async {
    await tester.pumpWidget(_app(status: status));

    expect(find.text('Chat storage needs attention'), findsOneWidget);
    expect(find.text('Restore from backup'), findsOneWidget);
    expect(find.text('Rebuild from legacy Hive'), findsOneWidget);
    expect(find.text('Reset chat storage'), findsOneWidget);
    expect(find.text('Continue with the legacy store for now'), findsOneWidget);
    expect(
      find.text(
        'A prior installation was recorded but chat_v2.sqlite is missing.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('hides rebuild when no Hive artifacts exist', (tester) async {
    await tester.pumpWidget(_app(status: status, hasLegacyHive: false));

    expect(find.text('Restore from backup'), findsOneWidget);
    expect(find.text('Rebuild from legacy Hive'), findsNothing);
  });

  testWidgets('reset requires confirmation and stays visible on failure', (
    tester,
  ) async {
    var resets = 0;
    await tester.pumpWidget(
      _app(
        status: status,
        onReset: () async {
          resets++;
          throw StateError('reset failed');
        },
      ),
    );

    await tester.tap(find.text('Reset chat storage'));
    await tester.pumpAndSettle();
    expect(find.text('Reset chat storage?'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Reset chat storage'));
    await tester.pumpAndSettle();

    expect(resets, 1);
    expect(find.text('Recovery failed'), findsOneWidget);
    expect(find.text('Chat storage needs attention'), findsOneWidget);
  });
}
