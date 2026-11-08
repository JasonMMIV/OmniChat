// Answer Review v1 — UI state machine + notifier tests (§11.3).
import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/features/home/controllers/answer_review_stream_state.dart';
import 'package:OmniChat/features/home/controllers/streaming_content_notifier.dart';
import 'package:OmniChat/core/services/agent/answer_review.dart';

void main() {
  group('AnswerReviewStreamState', () {
    test('reviewing → revising backs up the draft', () {
      final s = AnswerReviewStreamState();
      s.beginReviewing();
      expect(s.phase, 'reviewing');
      expect(s.needsDraftRestore, isFalse);

      s.beginRevision('the draft');
      expect(s.phase, 'revising');
      expect(s.isRevising, isTrue);
      expect(s.needsDraftRestore, isTrue);
    });

    test('re-entering revising never overwrites the original backup', () {
      final s = AnswerReviewStreamState();
      s.beginRevision('original');
      s.beginRevision('half revised');
      expect(s.takeDraftForRestore(), 'original');
    });

    test('finish(success) clears phase, backup and records the outcome', () {
      final s = AnswerReviewStreamState();
      s.beginRevision('draft');
      s.finish(reviewed: true, reviewTokens: 320);
      expect(s.phase, isNull);
      expect(s.reviewed, isTrue);
      expect(s.reviewTokens, 320);
      expect(s.needsDraftRestore, isFalse);
    });

    test('takeDraftForRestore returns the draft and clears the backup', () {
      final s = AnswerReviewStreamState();
      s.beginRevision('keep me');
      final draft = s.takeDraftForRestore();
      expect(draft, 'keep me');
      expect(s.needsDraftRestore, isFalse);
      expect(s.phase, 'revision_failed');
      // Second restore is a no-op.
      expect(s.takeDraftForRestore(), '');
    });

    test('markRevisionFailed switches the phase without touching backup',
        () {
      final s = AnswerReviewStreamState();
      s.beginRevision('draft');
      s.markRevisionFailed();
      expect(s.phase, 'revision_failed');
      expect(s.isRevising, isFalse);
    });

    test('cancel while only reviewing needs no restore', () {
      final s = AnswerReviewStreamState();
      s.beginReviewing();
      expect(s.needsDraftRestore, isFalse);
      s.finish(reviewed: false);
      expect(s.phase, isNull);
    });

    test('cancel while revising flags the restore', () {
      final s = AnswerReviewStreamState();
      s.beginRevision('draft');
      // Simulated cancel: needsDraftRestore stays true until the restore
      // consumes the backup.
      expect(s.needsDraftRestore, isTrue);
    });
  });

  group('StreamingContentNotifier reviewPhase', () {
    test('updateReviewPhase sets and clears the phase', () {
      final notifier = StreamingContentNotifier();
      const id = 'm1';
      // getNotifier creates the per-message notifier (the real pipeline
      // always materializes it via scheduleThrottledUpdate first).
      notifier.getNotifier(id);
      notifier.updateContent(id, 'hello', 0);
      expect(notifier.getNotifier(id).value.reviewPhase, isNull);

      notifier.updateReviewPhase(id, kReviewPhaseReviewing);
      expect(notifier.getNotifier(id).value.reviewPhase, 'reviewing');

      notifier.updateReviewPhase(id, kReviewPhaseRevising);
      expect(notifier.getNotifier(id).value.reviewPhase, 'revising');

      notifier.updateReviewPhase(id, null);
      expect(notifier.getNotifier(id).value.reviewPhase, isNull);
      notifier.removeNotifier(id);
    });

    test('updateContent preserves reviewPhase', () {
      final notifier = StreamingContentNotifier();
      const id = 'm2';
      notifier.getNotifier(id);
      notifier.updateContent(id, 'draft', 0);
      notifier.updateReviewPhase(id, kReviewPhaseRevising);

      notifier.updateContent(id, '', 100);
      final data = notifier.getNotifier(id).value;
      expect(data.content, '');
      expect(data.totalTokens, 100);
      expect(data.reviewPhase, 'revising');
      notifier.removeNotifier(id);
    });

    test('updateReasoning / updateRetryStatus / updateProposals / '
        'notifyToolPartsUpdated / forceRebuild preserve reviewPhase', () {
      final notifier = StreamingContentNotifier();
      const id = 'm3';
      notifier.getNotifier(id);
      notifier.updateContent(id, 'draft', 0);
      notifier.updateReviewPhase(id, kReviewPhaseReviewing);

      notifier.updateReasoning(id, reasoningText: 'thinking');
      expect(notifier.getNotifier(id).value.reviewPhase, 'reviewing');

      notifier.notifyToolPartsUpdated(id);
      expect(notifier.getNotifier(id).value.reviewPhase, 'reviewing');

      notifier.forceRebuild(id);
      expect(notifier.getNotifier(id).value.reviewPhase, 'reviewing');

      notifier.updateProposals(id, '[]');
      expect(notifier.getNotifier(id).value.reviewPhase, 'reviewing');

      notifier.updateRetryStatus(id, null);
      expect(notifier.getNotifier(id).value.reviewPhase, 'reviewing');

      // Equality / hashCode include reviewPhase.
      final a = notifier.getNotifier(id).value;
      notifier.updateReviewPhase(id, null);
      final b = notifier.getNotifier(id).value;
      expect(a == b, isFalse);
      expect(a.hashCode == b.hashCode, isFalse);
      notifier.removeNotifier(id);
    });
  });
}
