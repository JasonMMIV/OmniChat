// TurnQueueStore tests (docs/anybuff_queue_sendnow_import_plan.md §3.4/§4.1).
//
// Pins FIFO order, promote/remove, dispatch-failure fallback (head + cooldown
// + pause after two consecutive failures, R10), single-flight bookkeeping and
// per-conversation cleanup.

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/models/chat_input_data.dart';
import 'package:OmniChat/core/services/chat/turn_queue/turn_queue.dart';

void main() {
  QueuedMessage msg(
    TurnQueueStore store,
    String conversationId,
    String text, {
    DateTime? at,
  }) => QueuedMessage(
    id: store.nextId(),
    conversationId: conversationId,
    input: ChatInputData(text: text),
    createdAt: at ?? DateTime(2026, 11, 13),
  );

  group('FIFO operations', () {
    test('enqueue preserves FIFO order per conversation', () {
      final store = TurnQueueStore();
      final a = msg(store, 'c1', 'a');
      final b = msg(store, 'c1', 'b');
      final other = msg(store, 'c2', 'x');
      store.enqueue(a);
      store.enqueue(b);
      store.enqueue(other);

      expect(store.queueFor('c1').map((m) => m.input.text), ['a', 'b']);
      expect(store.queueFor('c2').map((m) => m.input.text), ['x']);
      expect(store.countFor('c1'), 2);
      expect(store.hasItems('c1'), isTrue);
      expect(store.hasItems('c3'), isFalse);
    });

    test('generated ids are unique', () {
      final store = TurnQueueStore();
      final ids = {for (var i = 0; i < 20; i++) store.nextId()};
      expect(ids, hasLength(20));
    });

    test('remove returns the item and cleans up empty queues', () {
      final store = TurnQueueStore();
      final a = msg(store, 'c1', 'a');
      store.enqueue(a);

      expect(store.remove('c1', a.id), same(a));
      expect(store.hasItems('c1'), isFalse);
      expect(store.remove('c1', a.id), isNull);
      expect(store.remove('c-unknown', 'nope'), isNull);
    });

    test('promote moves an item to the front', () {
      final store = TurnQueueStore();
      final a = msg(store, 'c1', 'a');
      final b = msg(store, 'c1', 'b');
      final c = msg(store, 'c1', 'c');
      store.enqueue(a);
      store.enqueue(b);
      store.enqueue(c);

      expect(store.promote('c1', c.id), isTrue);
      expect(store.queueFor('c1').map((m) => m.input.text), ['c', 'a', 'b']);
      expect(store.promote('c1', 'missing'), isFalse);
    });

    test('moveItem clamps to valid bounds', () {
      final store = TurnQueueStore();
      final a = msg(store, 'c1', 'a');
      final b = msg(store, 'c1', 'b');
      store.enqueue(a);
      store.enqueue(b);

      store.moveItem('c1', a.id, 99);
      expect(store.queueFor('c1').map((m) => m.input.text), ['b', 'a']);
      store.moveItem('c1', a.id, -5);
      expect(store.queueFor('c1').map((m) => m.input.text), ['a', 'b']);
    });

    test('requeueHead puts the item back at the front without duplication', () {
      final store = TurnQueueStore();
      final a = msg(store, 'c1', 'a');
      final b = msg(store, 'c1', 'b');
      store.enqueue(a);
      store.enqueue(b);

      // Simulate dispatch: the head was removed, then failed.
      final head = store.remove('c1', a.id)!;
      store.requeueHead('c1', head);

      expect(store.queueFor('c1').map((m) => m.input.text), ['a', 'b']);
      // Requeueing an item still present must not duplicate it.
      store.requeueHead('c1', head);
      expect(store.queueFor('c1').map((m) => m.input.text), ['a', 'b']);
    });

    test('prependAll keeps leftover order ahead of the queue (block-prepend)', () {
      final store = TurnQueueStore();
      final a = msg(store, 'c1', 'a');
      store.enqueue(a);
      final l1 = msg(store, 'c1', 'leftover-1');
      final l2 = msg(store, 'c1', 'leftover-2');

      store.prependAll('c1', [l1, l2]);
      expect(store.queueFor('c1').map((m) => m.input.text), [
        'leftover-1',
        'leftover-2',
        'a',
      ]);
    });
  });

  group('pause / resume', () {
    test('pause and resume toggle the flag', () {
      final store = TurnQueueStore();
      expect(store.isPaused('c1'), isFalse);
      store.pause('c1');
      expect(store.isPaused('c1'), isTrue);
      store.resume('c1');
      expect(store.isPaused('c1'), isFalse);
    });

    test('resume clears cooldown and failure streaks', () {
      final store = TurnQueueStore();
      store.pause('c1');
      store.markCooldown('c1');
      store.registerFailure('c1', 'm1');
      store.resume('c1');

      expect(store.isCoolingDown('c1'), isFalse);
      expect(store.registerFailure('c1', 'm1'), isFalse);
    });
  });

  group('single-flight', () {
    test('only one dispatch slot at a time', () {
      final store = TurnQueueStore();
      expect(store.tryBeginDispatch('c1'), isTrue);
      expect(store.isInFlight('c1'), isTrue);
      expect(store.tryBeginDispatch('c1'), isFalse);
      store.endDispatch('c1');
      expect(store.isInFlight('c1'), isFalse);
      expect(store.tryBeginDispatch('c1'), isTrue);
    });
  });

  group('failure cooldown (R10)', () {
    test('cooldown expires with the injected clock', () {
      var now = DateTime(2026, 11, 13, 12);
      final store = TurnQueueStore(clock: () => now);

      store.markCooldown('c1', const Duration(milliseconds: 1500));
      expect(store.isCoolingDown('c1'), isTrue);
      now = now.add(const Duration(milliseconds: 1499));
      expect(store.isCoolingDown('c1'), isTrue);
      now = now.add(const Duration(milliseconds: 2));
      expect(store.isCoolingDown('c1'), isFalse);
    });

    test('the same item failing twice pauses the queue', () {
      final store = TurnQueueStore();
      expect(store.registerFailure('c1', 'item-1'), isFalse);
      expect(store.registerFailure('c1', 'item-1'), isTrue);
    });

    test('a different item resets the streak', () {
      final store = TurnQueueStore();
      expect(store.registerFailure('c1', 'item-1'), isFalse);
      expect(store.registerFailure('c1', 'item-2'), isFalse);
      expect(store.registerFailure('c1', 'item-2'), isTrue);
    });

    test('a successful dispatch resets the streak', () {
      final store = TurnQueueStore();
      store.registerFailure('c1', 'item-1');
      store.resetFailure('c1');
      expect(store.registerFailure('c1', 'item-1'), isFalse);
    });
  });

  group('cleanup', () {
    test('clearConversation drops every kind of state', () {
      final store = TurnQueueStore();
      store.enqueue(msg(store, 'c1', 'a'));
      store.pause('c1');
      store.markCooldown('c1');
      store.registerFailure('c1', 'm1');

      store.clearConversation('c1');
      expect(store.hasItems('c1'), isFalse);
      expect(store.isPaused('c1'), isFalse);
      expect(store.isCoolingDown('c1'), isFalse);
      expect(store.registerFailure('c1', 'm1'), isFalse);
    });
  });
}
