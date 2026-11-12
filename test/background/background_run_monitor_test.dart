import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/services/background/background_run_monitor.dart';

void main() {
  final monitor = BackgroundRunMonitor.instance;
  final snapshots = <BackgroundRunSnapshot>[];
  StreamSubscription<BackgroundRunSnapshot>? sub;

  setUp(() {
    monitor.reset();
    snapshots.clear();
    sub = monitor.changes.listen(snapshots.add);
  });

  tearDown(() async {
    await sub?.cancel();
    sub = null;
    monitor.reset();
  });

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  group('BackgroundRunMonitor', () {
    test('starts idle with no active run', () {
      expect(monitor.snapshot.phase, BackgroundRunPhase.idle);
      expect(monitor.snapshot.activeConversationIds, isEmpty);
      expect(monitor.snapshot.hasFinishedRun, isFalse);
      expect(monitor.snapshot.openConversationId, isNull);
    });

    test('begin marks the conversation as running with its title', () async {
      monitor.begin(conversationId: 'c1', title: '  Title A  ');
      await flush();

      final snap = monitor.snapshot;
      expect(snap.phase, BackgroundRunPhase.running);
      expect(snap.activeConversationIds, {'c1'});
      expect(snap.activeTitle, 'Title A');
      expect(snap.isRunning, isTrue);
      expect(snap.openConversationId, 'c1');
      // setUp resets before subscribing, so the only emission is `running`.
      expect(snapshots, hasLength(1));
    });

    test('repeated begin for the same run does not emit again', () async {
      monitor.begin(conversationId: 'c1');
      await flush();
      final before = snapshots.length;

      monitor.begin(conversationId: 'c1');
      await flush();

      expect(snapshots, hasLength(before));
    });

    test(
      'finish moves a successful run to ready and keeps the title',
      () async {
        monitor.begin(conversationId: 'c1', title: 'Plan');
        monitor.finish('c1');
        await flush();

        final snap = monitor.snapshot;
        expect(snap.phase, BackgroundRunPhase.ready);
        expect(snap.isRunning, isFalse);
        expect(snap.lastConversationId, 'c1');
        expect(snap.displayTitle, 'Plan');
        expect(snap.openConversationId, 'c1');
      },
    );

    test('markFailed before finish reports failed', () {
      monitor.begin(conversationId: 'c1');
      monitor.markFailed('c1');
      expect(monitor.snapshot.phase, BackgroundRunPhase.running);

      monitor.finish('c1');

      expect(monitor.snapshot.phase, BackgroundRunPhase.failed);
    });

    test('markStopped before finish reports stopped', () {
      monitor.begin(conversationId: 'c1');
      monitor.markStopped('c1');
      monitor.finish('c1');

      expect(monitor.snapshot.phase, BackgroundRunPhase.stopped);
    });

    test('a late failure cannot overwrite a user stop', () {
      monitor.begin(conversationId: 'c1');
      monitor.markStopped('c1');
      monitor.markFailed('c1');
      monitor.finish('c1');

      expect(monitor.snapshot.phase, BackgroundRunPhase.stopped);
    });

    test('a stop after a recorded failure keeps failed', () {
      monitor.begin(conversationId: 'c1');
      monitor.markFailed('c1');
      monitor.markStopped('c1');
      monitor.finish('c1');

      expect(monitor.snapshot.phase, BackgroundRunPhase.failed);
    });

    test('a repeated begin with a new title refreshes the snapshot', () async {
      monitor.begin(conversationId: 'c1');
      await flush();

      monitor.begin(conversationId: 'c1', title: 'Named later');
      await flush();

      expect(monitor.snapshot.activeTitle, 'Named later');
      expect(monitor.snapshot.activeTitledConversationId, 'c1');
    });

    test('finish on an unknown run is a no-op', () async {
      await flush();
      final before = snapshots.length;

      monitor.finish('missing');
      await flush();

      expect(monitor.snapshot.phase, BackgroundRunPhase.idle);
      expect(monitor.snapshot.hasFinishedRun, isFalse);
      expect(snapshots, hasLength(before));
    });

    test('a stray markFailed cannot fabricate a failure', () {
      monitor.markFailed('missing');
      monitor.finish('missing');

      expect(monitor.snapshot.phase, BackgroundRunPhase.idle);
    });

    test('open target follows the conversation that owns the title', () {
      monitor.begin(conversationId: 'c1');
      monitor.begin(conversationId: 'c2', title: 'Titled');

      final snap = monitor.snapshot;
      expect(snap.activeTitle, 'Titled');
      expect(snap.openConversationId, 'c2');
      expect(snap.openConversationTitle, 'Titled');
    });

    test('open target falls back to start order without a known title', () {
      monitor.begin(conversationId: 'c1');
      monitor.begin(conversationId: 'c2');

      expect(monitor.snapshot.openConversationId, 'c1');
      expect(monitor.snapshot.openConversationTitle, isNull);
    });

    test('concurrent runs stay running until the last one finishes', () {
      monitor.begin(conversationId: 'c1', title: 'One');
      monitor.begin(conversationId: 'c2', title: 'Two');

      monitor.finish('c1');
      expect(monitor.snapshot.phase, BackgroundRunPhase.running);
      expect(monitor.snapshot.activeConversationIds, {'c2'});

      monitor.finish('c2');
      expect(monitor.snapshot.phase, BackgroundRunPhase.ready);
      expect(monitor.snapshot.lastConversationId, 'c2');
    });

    test('reset returns to idle and emits', () async {
      monitor.begin(conversationId: 'c1');
      monitor.finish('c1');
      await flush();
      final before = snapshots.length;

      monitor.reset();
      await flush();

      expect(monitor.snapshot.phase, BackgroundRunPhase.idle);
      expect(monitor.snapshot.lastConversationId, isNull);
      expect(snapshots.length, greaterThan(before));
    });

    test('acknowledgeTerminal clears a finished status', () async {
      monitor.begin(conversationId: 'c1', title: 'Plan');
      monitor.finish('c1');

      monitor.acknowledgeTerminal();

      expect(monitor.snapshot.phase, BackgroundRunPhase.idle);
      expect(monitor.snapshot.lastConversationId, isNull);
      expect(monitor.snapshot.lastTitle, isNull);
    });

    test('acknowledgeTerminal never hides an active run', () async {
      monitor.begin(conversationId: 'c1');

      monitor.acknowledgeTerminal();

      expect(monitor.snapshot.phase, BackgroundRunPhase.running);
      expect(monitor.snapshot.activeConversationIds, {'c1'});
    });

    test('open requests forward non-empty conversation ids', () async {
      final opened = <String>[];
      final openSub = monitor.openRequests.listen(opened.add);
      addTearDown(openSub.cancel);

      monitor.requestOpen(' c9 ');
      monitor.requestOpen('   ');
      await flush();

      expect(opened, ['c9']);
    });

    test('snapshots compare by value', () {
      const a = BackgroundRunSnapshot(
        phase: BackgroundRunPhase.ready,
        activeConversationIds: <String>{'c1'},
        lastConversationId: 'c1',
        lastTitle: 'T',
      );
      const b = BackgroundRunSnapshot(
        phase: BackgroundRunPhase.ready,
        activeConversationIds: <String>{'c1'},
        lastConversationId: 'c1',
        lastTitle: 'T',
      );

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(
        a,
        isNot(
          equals(
            const BackgroundRunSnapshot(
              phase: BackgroundRunPhase.failed,
              activeConversationIds: <String>{'c1'},
              lastConversationId: 'c1',
              lastTitle: 'T',
            ),
          ),
        ),
      );
    });

    test('display title trims and ignores blanks', () {
      const blank = BackgroundRunSnapshot(
        phase: BackgroundRunPhase.ready,
        lastConversationId: 'c1',
        lastTitle: '   ',
      );
      expect(blank.displayTitle, isNull);
    });
  });
}
