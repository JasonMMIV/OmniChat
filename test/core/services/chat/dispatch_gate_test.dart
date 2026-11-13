// Dispatch-gate tests (docs/anybuff_queue_sendnow_import_plan.md §3.4/§6.1).
//
// One clear run of facts dispatches; every veto (F1 pending checkpoint, F2
// internal transition, F10 pause, R10 cooldown, single-flight, off-screen
// conversation) blocks on its own.

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/services/chat/turn_queue/dispatch_gate.dart';

void main() {
  bool allows({
    bool inFlight = false,
    bool mailboxActive = false,
    bool queuePaused = false,
    bool internalTransition = false,
    bool checkpointPaused = false,
    bool isCurrentConversation = true,
    bool cooldownActive = false,
    bool hasItems = true,
  }) => canDispatchTurn(
    inFlight: inFlight,
    mailboxActive: mailboxActive,
    queuePaused: queuePaused,
    internalTransition: internalTransition,
    checkpointPaused: checkpointPaused,
    isCurrentConversation: isCurrentConversation,
    cooldownActive: cooldownActive,
    hasItems: hasItems,
  );

  group('canDispatchTurn', () {
    test('all clear dispatches', () {
      expect(allows(), isTrue);
    });

    test('empty queue never dispatches', () {
      expect(allows(hasItems: false), isFalse);
    });

    test('single-flight blocks a second dispatch', () {
      expect(allows(inFlight: true), isFalse);
    });

    test('active steering mailbox blocks dispatch', () {
      expect(allows(mailboxActive: true), isFalse);
    });

    test('paused queue blocks dispatch (F10)', () {
      expect(allows(queuePaused: true), isFalse);
    });

    test('internal transition blocks dispatch (F2/R13)', () {
      expect(allows(internalTransition: true), isFalse);
    });

    test('paused/pending checkpoint blocks dispatch (F1)', () {
      expect(allows(checkpointPaused: true), isFalse);
    });

    test('off-screen conversation never dispatches (v1)', () {
      expect(allows(isCurrentConversation: false), isFalse);
    });

    test('cooldown blocks dispatch (R10)', () {
      expect(allows(cooldownActive: true), isFalse);
    });
  });
}
