import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/core/services/file/workspace_disk_usage.dart';
import 'package:OmniChat/features/chat/widgets/workspace_disk_usage_card.dart';
import 'package:OmniChat/l10n/app_localizations.dart';

void main() {
  Widget wrap(Widget child) {
    return MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    );
  }

  const usage = WorkspaceDiskUsage(
    totalBytes: 1024,
    fileCount: 1,
    directoryCount: 2,
    scannedEntryCount: 49999,
    truncated: true,
  );

  testWidgets('shows the visited-entry count for a partial scan', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        WorkspaceDiskUsageCard(
          workspacePath: '/tmp/workspace',
          loadUsage: (_) async => usage,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Partial scan: stopped after 49999 entries.'),
      findsOneWidget,
    );
  });

  testWidgets('shows the workspace-files hint without an exclusion claim', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        WorkspaceDiskUsageCard(
          workspacePath: '/tmp/workspace',
          loadUsage: (_) async => const WorkspaceDiskUsage(
            totalBytes: 1024,
            fileCount: 1,
            directoryCount: 0,
            scannedEntryCount: 1,
            truncated: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Workspace files only.'), findsOneWidget);
    expect(find.textContaining('.omnichat'), findsNothing);
  });

  testWidgets('shows an error when the workspace cannot be measured', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        WorkspaceDiskUsageCard(
          workspacePath: '/tmp/workspace',
          loadUsage: (_) async => null,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Unable to measure this workspace.'), findsOneWidget);
  });

  testWidgets('refreshes the measurement', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      wrap(
        WorkspaceDiskUsageCard(
          workspacePath: '/tmp/workspace',
          loadUsage: (_) async {
            calls++;
            return usage;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(calls, 1);

    await tester.tap(find.byTooltip('Refresh disk usage'));
    await tester.pumpAndSettle();
    expect(calls, 2);
  });
}
