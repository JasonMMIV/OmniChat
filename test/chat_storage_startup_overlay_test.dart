import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:OmniChat/core/services/chat/chat_service.dart';
import 'package:OmniChat/core/services/chat/storage/chat_storage_startup_status.dart';
import 'package:OmniChat/features/home/widgets/chat_storage_startup_overlay.dart';
import 'package:OmniChat/l10n/app_localizations.dart';

class _FakeChatService extends ChatService {
  _FakeChatService(this.status);

  ChatStorageInitStatus status;

  @override
  ChatStorageInitStatus get storageInitStatus => status;

  void updateStatus(ChatStorageInitStatus next) {
    if (status == next) return;
    status = next;
    notifyListeners();
  }
}

Widget _app(
  ChatService service, {
  Future<void> Function()? onRetry,
  Widget? background,
}) {
  return MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: ChangeNotifierProvider<ChatService>.value(
      value: service,
      child: Scaffold(
        body: Stack(
          children: [
            background ?? const Center(child: Text('chat surface')),
            ChatStorageStartupOverlay(onRetry: onRetry),
          ],
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('ordinary SQLite startup uses only an invisible barrier', (
    tester,
  ) async {
    var tapped = false;
    final service = _FakeChatService(
      const ChatStorageInitStatus(phase: ChatStorageInitPhase.checking),
    );

    await tester.pumpWidget(
      _app(
        service,
        background: Center(
          child: ElevatedButton(
            onPressed: () => tapped = true,
            child: const Text('under overlay'),
          ),
        ),
      ),
    );

    expect(find.text('Preparing chat storage'), findsNothing);
    expect(find.text('under overlay'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await tester.tap(find.text('under overlay'), warnIfMissed: false);
    expect(tapped, isFalse);
  });

  testWidgets('ordinary opening without counts stays quiet', (tester) async {
    final service = _FakeChatService(
      const ChatStorageInitStatus(
        phase: ChatStorageInitPhase.opening,
        stage: 'opening',
      ),
    );

    await tester.pumpWidget(_app(service));

    expect(find.text('Preparing chat storage'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('migration panel persists through opening until ready', (
    tester,
  ) async {
    final service = _FakeChatService(
      const ChatStorageInitStatus(
        phase: ChatStorageInitPhase.backingUp,
        stage: 'backing-up',
      ),
    );

    await tester.pumpWidget(_app(service));
    expect(find.text('Preparing chat storage'), findsOneWidget);

    service.updateStatus(
      const ChatStorageInitStatus(
        phase: ChatStorageInitPhase.migrating,
        stage: 'migrating',
      ),
    );
    await tester.pump();
    expect(find.text('Preparing chat storage'), findsOneWidget);

    service.updateStatus(
      const ChatStorageInitStatus(
        phase: ChatStorageInitPhase.validating,
        stage: 'validating',
        conversations: 12,
        messages: 345,
      ),
    );
    await tester.pump();
    expect(find.text('Preparing chat storage'), findsOneWidget);

    service.updateStatus(
      const ChatStorageInitStatus(
        phase: ChatStorageInitPhase.opening,
        stage: 'opening',
        conversations: 12,
        messages: 345,
        cutoverStarted: true,
      ),
    );
    await tester.pump();
    expect(find.text('Preparing chat storage'), findsOneWidget);
    expect(find.text('Opening chat storage…'), findsOneWidget);

    service.updateStatus(
      const ChatStorageInitStatus(phase: ChatStorageInitPhase.ready),
    );
    await tester.pump();
    expect(find.text('Preparing chat storage'), findsNothing);
  });

  testWidgets('empty migration still blocks at opening', (tester) async {
    final service = _FakeChatService(
      const ChatStorageInitStatus(
        phase: ChatStorageInitPhase.opening,
        stage: 'opening',
        cutoverStarted: true,
      ),
    );

    await tester.pumpWidget(_app(service));

    expect(find.text('Preparing chat storage'), findsOneWidget);
    expect(find.text('Opening chat storage…'), findsOneWidget);
  });

  testWidgets('opening after a migration keeps the blocking panel', (
    tester,
  ) async {
    final service = _FakeChatService(
      const ChatStorageInitStatus(
        phase: ChatStorageInitPhase.opening,
        stage: 'opening',
        conversations: 12,
        messages: 345,
        cutoverStarted: true,
      ),
    );

    await tester.pumpWidget(_app(service));

    expect(find.text('Preparing chat storage'), findsOneWidget);
    expect(find.text('Opening chat storage…'), findsOneWidget);
  });

  testWidgets('shows the migration stage and destination counts', (
    tester,
  ) async {
    final service = _FakeChatService(
      const ChatStorageInitStatus(
        phase: ChatStorageInitPhase.validating,
        stage: 'validating',
        conversations: 12,
        messages: 345,
        quarantined: 2,
      ),
    );

    await tester.pumpWidget(_app(service));

    expect(find.text('Preparing chat storage'), findsOneWidget);
    expect(find.text('Validating the migrated data…'), findsOneWidget);
    expect(find.text('12 chats · 345 messages'), findsOneWidget);
    expect(find.text('2 items need review'), findsOneWidget);
    expect(find.text('chat surface'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('a failed retry stays settled and keeps the diagnostic', (
    tester,
  ) async {
    final service = _FakeChatService(
      const ChatStorageInitStatus(
        phase: ChatStorageInitPhase.failed,
        message: 'HiveOpenException: messages.hive is corrupt',
        canRetry: true,
      ),
    );

    await tester.pumpWidget(
      _app(
        service,
        onRetry: () async {
          throw StateError('retry failed again');
        },
      ),
    );

    await tester.tap(find.text('Retry'));
    await tester.pump();

    expect(find.text('Chat storage did not start'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keeps failures visible and retries through the caller', (
    tester,
  ) async {
    var retries = 0;
    final service = _FakeChatService(
      const ChatStorageInitStatus(
        phase: ChatStorageInitPhase.failed,
        message: 'HiveOpenException: messages.hive is corrupt',
        canRetry: true,
      ),
    );

    await tester.pumpWidget(
      _app(
        service,
        onRetry: () async {
          retries++;
        },
      ),
    );

    expect(find.text('Chat storage did not start'), findsOneWidget);
    expect(
      find.text('HiveOpenException: messages.hive is corrupt'),
      findsOneWidget,
    );

    await tester.tap(find.text('Retry'));
    await tester.pump();

    expect(retries, 1);
  });
}
