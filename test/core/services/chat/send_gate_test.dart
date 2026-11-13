// Composer send-gate tests (docs/anybuff_queue_sendnow_import_plan.md §3.1/§6.1).
//
// Pins: attachment-only can queue; attachments cannot steer; `/`-prefixed
// text queues instead of steering; blank input never qualifies; leftover
// block-prepend keeps FIFO.

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/services/chat/turn_queue/send_gate.dart';

void main() {
  group('canQueueChatInput', () {
    test('idle conversation never queues', () {
      expect(
        canQueueChatInput(loading: false, text: 'hello'),
        isFalse,
      );
    });

    test('running conversation queues plain text', () {
      expect(canQueueChatInput(loading: true, text: 'hello'), isTrue);
    });

    test('running conversation queues attachments without text (F9)', () {
      expect(
        canQueueChatInput(loading: true, text: '', imageCount: 1),
        isTrue,
      );
      expect(
        canQueueChatInput(loading: true, text: '', documentCount: 2),
        isTrue,
      );
    });

    test('blank input never queues', () {
      expect(canQueueChatInput(loading: true, text: '   '), isFalse);
    });
  });

  group('canSteerChatInput', () {
    test('pure text steers while running', () {
      expect(canSteerChatInput(loading: true, text: 'steer me'), isTrue);
    });

    test('idle conversation never steers', () {
      expect(canSteerChatInput(loading: false, text: 'hi'), isFalse);
    });

    test('attachments cannot steer', () {
      expect(
        canSteerChatInput(loading: true, text: 'hi', imageCount: 1),
        isFalse,
      );
      expect(
        canSteerChatInput(loading: true, text: 'hi', documentCount: 1),
        isFalse,
      );
    });

    test('slash commands cannot steer', () {
      expect(canSteerChatInput(loading: true, text: '/skill foo'), isFalse);
      expect(canSteerChatInput(loading: true, text: '  /skill foo'), isFalse);
    });

    test('blank text cannot steer', () {
      expect(canSteerChatInput(loading: true, text: '  '), isFalse);
    });
  });

  group('sendNowBlockReason', () {
    test('allowed for pure text while running', () {
      expect(
        sendNowBlockReason(loading: true, text: 'hi'),
        SendNowBlockReason.none,
      );
    });

    test('inactive when idle or blank', () {
      expect(
        sendNowBlockReason(loading: false, text: 'hi'),
        SendNowBlockReason.inactive,
      );
      expect(
        sendNowBlockReason(loading: true, text: '   '),
        SendNowBlockReason.inactive,
      );
    });

    test('attachments win over every other hint', () {
      expect(
        sendNowBlockReason(
          loading: true,
          text: '/skill',
          imageCount: 1,
          teamActive: true,
        ),
        SendNowBlockReason.attachments,
      );
    });

    test('team hint beats the command hint', () {
      expect(
        sendNowBlockReason(loading: true, text: '/skill', teamActive: true),
        SendNowBlockReason.team,
      );
      expect(
        sendNowBlockReason(loading: true, text: 'hi', teamActive: true),
        SendNowBlockReason.team,
      );
    });

    test('slash text reports the command hint', () {
      expect(
        sendNowBlockReason(loading: true, text: '/skill foo'),
        SendNowBlockReason.command,
      );
    });
  });
}
