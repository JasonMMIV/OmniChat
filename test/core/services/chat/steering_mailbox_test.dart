// SteeringMailbox tests (docs/anybuff_queue_sendnow_import_plan.md §4.1/§6.1).
//
// Pins the owner-token contract (F5), one-shot drain, echo merge (`\n\n`),
// stale deactivation no-op, and abandon (retract + requeue source).

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/services/chat/turn_queue/steering_mailbox.dart';

void main() {
  group('SteeringMailbox', () {
    test('inactive mailbox rejects pushes and drains nothing', () {
      final mailbox = SteeringMailbox();
      expect(mailbox.isActive('c1'), isFalse);
      expect(mailbox.push('c1', 'hello'), isNull);
      expect(mailbox.drain('c1', 'run1'), isEmpty);
      expect(mailbox.hasPending('c1'), isFalse);
    });

    test('activate claims the mailbox for the run token', () {
      final mailbox = SteeringMailbox();
      mailbox.activate('c1', 'run1');
      expect(mailbox.isActive('c1'), isTrue);
      expect(mailbox.ownerOf('c1'), 'run1');

      final entry = mailbox.push('c1', 'hello');
      expect(entry, isNotNull);
      expect(entry!.text, 'hello');
      expect(mailbox.hasPending('c1'), isTrue);
    });

    test('consecutive pushes merge into one entry with a blank line', () {
      final mailbox = SteeringMailbox();
      mailbox.activate('c1', 'run1');

      final first = mailbox.push('c1', 'one');
      final second = mailbox.push('c1', 'two');
      expect(second, same(first));
      expect(first!.text, 'one\n\ntwo');

      final drained = mailbox.drain('c1', 'run1');
      expect(drained, hasLength(1));
      expect(drained.single.text, 'one\n\ntwo');
    });

    test('blank pushes are rejected', () {
      final mailbox = SteeringMailbox();
      mailbox.activate('c1', 'run1');
      expect(mailbox.push('c1', '   '), isNull);
      expect(mailbox.hasPending('c1'), isFalse);
    });

    test('drain is one-shot', () {
      final mailbox = SteeringMailbox();
      mailbox.activate('c1', 'run1');
      mailbox.push('c1', 'hello');

      expect(mailbox.drain('c1', 'run1'), hasLength(1));
      expect(mailbox.hasPending('c1'), isFalse);
      expect(mailbox.drain('c1', 'run1'), isEmpty);
    });

    test('stale token drains nothing', () {
      final mailbox = SteeringMailbox();
      mailbox.activate('c1', 'run2');
      mailbox.push('c1', 'hello');

      expect(mailbox.drain('c1', 'run1'), isEmpty);
      expect(mailbox.hasPending('c1'), isTrue);
    });

    test('late deactivate from an older run is a no-op (F5)', () {
      final mailbox = SteeringMailbox();
      mailbox.activate('c1', 'run1');
      mailbox.deactivate('c1', 'run0'); // never owned the mailbox
      expect(mailbox.ownerOf('c1'), 'run1');

      mailbox.activate('c1', 'run2');
      mailbox.push('c1', 'hello');
      mailbox.deactivate('c1', 'run1'); // late release from the old run
      expect(mailbox.ownerOf('c1'), 'run2');
      expect(mailbox.hasPending('c1'), isTrue);
    });

    test('re-activation with a new token drops entries from the old run', () {
      final mailbox = SteeringMailbox();
      mailbox.activate('c1', 'run1');
      mailbox.push('c1', 'old run text');

      mailbox.activate('c1', 'run2');
      expect(mailbox.hasPending('c1'), isFalse);
      expect(mailbox.drain('c1', 'run2'), isEmpty);
    });

    test('deactivate clears the owner and pending entries', () {
      final mailbox = SteeringMailbox();
      mailbox.activate('c1', 'run1');
      mailbox.push('c1', 'hello');
      mailbox.deactivate('c1', 'run1');

      expect(mailbox.isActive('c1'), isFalse);
      expect(mailbox.hasPending('c1'), isFalse);
      expect(mailbox.push('c1', 'later'), isNull);
    });

    test('abandon returns the dropped entries and clears the mailbox', () {
      final mailbox = SteeringMailbox();
      mailbox.activate('c1', 'run1');
      final entry = mailbox.push('c1', 'leftover')!;
      entry.echoMessageId = 'msg-echo';

      final dropped = mailbox.abandon('c1');
      expect(dropped, hasLength(1));
      expect(dropped.single.text, 'leftover');
      expect(dropped.single.echoMessageId, 'msg-echo');

      expect(mailbox.isActive('c1'), isFalse);
      expect(mailbox.hasPending('c1'), isFalse);
      expect(mailbox.abandon('c1'), isEmpty);
    });

    test('mailboxes are isolated per conversation', () {
      final mailbox = SteeringMailbox();
      mailbox.activate('c1', 'run1');
      mailbox.activate('c2', 'run2');
      mailbox.push('c1', 'for c1');
      mailbox.push('c2', 'for c2');

      expect(mailbox.ownerOf('c1'), 'run1');
      expect(mailbox.ownerOf('c2'), 'run2');
      expect(mailbox.drain('c1', 'run1').single.text, 'for c1');
      expect(mailbox.drain('c2', 'run2').single.text, 'for c2');
    });
  });
}
