// Answer Review cards P3 — persistence / replay-isolation contracts.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/models/answer_review.dart';
import 'package:OmniChat/core/models/chat_message.dart';
import 'package:OmniChat/core/models/conversation.dart';
import 'package:OmniChat/core/services/chat/storage/sqlite_chat_storage.dart';
import 'package:OmniChat/features/chat/widgets/process_group_logic.dart';

AnswerReviewReport _report({
  String phase = AnswerReviewPhase.passed,
  String? verdict = 'pass',
  List<ReviewIssue> issues = const <ReviewIssue>[],
  bool reviewed = true,
}) {
  return AnswerReviewReport(
    phase: phase,
    verdict: verdict,
    parsed: true,
    issues: issues,
    reviewed: reviewed,
    reviewMs: 1200,
    reviewTokens: 321,
    modelId: 'test-model',
    draftChars: 5,
    startedAtMs: 1000,
    finishedAtMs: 2200,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('review report JSON round-trips issues and timings', () {
    final report = _report(
      issues: const <ReviewIssue>[
        ReviewIssue(
          severity: 'major',
          location: 'intro',
          problem: 'unsupported claim',
          fix: 'remove it',
        ),
        ReviewIssue(
          severity: 'minor',
          location: 'tone',
          problem: 'too formal',
          fix: 'soften',
        ),
      ],
    );
    final decoded = AnswerReviewReport.fromJson(report.toJson());
    expect(decoded.phase, report.phase);
    expect(decoded.verdict, 'pass');
    expect(decoded.issues, hasLength(2));
    expect(decoded.issues.first.severity, 'major');
    expect(decoded.reviewTokens, 321);
    expect(decoded.startedAtMs, 1000);
    expect(decoded.finishedAtMs, 2200);
  });

  test(
    'review part survives tool rewrites and never becomes a tool event',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'omnichat_review_persist_',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      var storage = SqliteChatStorage(
        directory: directory,
        appVersion: 'test',
        background: false,
      );
      await storage.initialize();
      addTearDown(() async => storage.dispose());

      await storage.putConversation(
        Conversation(id: 'c1', title: 'Chat', createdAt: DateTime(2026)),
      );
      await storage.appendMessage(
        ChatMessage(
          id: 'm1',
          role: 'assistant',
          content: 'final answer',
          conversationId: 'c1',
        ),
      );
      await storage.upsertToolEvent(
        'm1',
        id: 'call_1',
        name: 'search_web',
        arguments: const <String, dynamic>{'query': 'x'},
        content: 'result',
      );
      await storage.upsertAnswerReviewPart(
        messageId: 'm1',
        report: _report(),
        status: 'completed',
        draft: 'DRAFT_SECRET',
      );

      expect(storage.getAnswerReview('m1')!.draft, 'DRAFT_SECRET');
      expect(storage.getToolEvents('m1'), hasLength(1));

      // A later tool rewrite (regenerate/resume) must not delete the review
      // row: replaceToolEvents only owns kind='tool'.
      await storage.setToolEvents('m1', <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'call_2',
          'name': 'file_read',
          'arguments': const <String, dynamic>{'path': 'b.txt'},
          'content': 'body',
        },
      ]);
      expect(storage.getAnswerReview('m1')!.draft, 'DRAFT_SECRET');
      final events = storage.getToolEvents('m1');
      expect(events, hasLength(1));
      expect(events.single['id'], 'call_2');
      expect(events.any((e) => e['content'] == 'DRAFT_SECRET'), isFalse);

      // Reload: the report and draft are restored with the conversation.
      await storage.dispose();
      storage = SqliteChatStorage(
        directory: directory,
        appVersion: 'test',
        background: false,
      );
      await storage.initialize();
      await storage.ensureConversationLoaded('c1');
      final restored = storage.getAnswerReview('m1');
      expect(restored, isNotNull);
      expect(restored!.draft, 'DRAFT_SECRET');
      expect(restored.report.phase, AnswerReviewPhase.passed);
      expect(restored.report.reviewTokens, 321);
    },
  );

  test('a draft larger than 64k is persisted in full', () async {
    final directory = await Directory.systemTemp.createTemp(
      'omnichat_review_large_draft_',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    var storage = SqliteChatStorage(
      directory: directory,
      appVersion: 'test',
      background: false,
    );
    await storage.initialize();
    addTearDown(() async => storage.dispose());

    await storage.putConversation(
      Conversation(id: 'c1', title: 'Chat', createdAt: DateTime(2026)),
    );
    await storage.appendMessage(
      ChatMessage(
        id: 'm1',
        role: 'assistant',
        content: 'final answer',
        conversationId: 'c1',
      ),
    );
    final bigDraft = 'x' * 70000;
    await storage.upsertAnswerReviewPart(
      messageId: 'm1',
      report: _report(),
      status: 'completed',
      draft: bigDraft,
    );

    final record = storage.getAnswerReview('m1')!;
    expect(record.draft, bigDraft);
    expect(record.draft!.length, 70000);
    expect(record.report.draftTruncated, isFalse);

    await storage.dispose();
    storage = SqliteChatStorage(
      directory: directory,
      appVersion: 'test',
      background: false,
    );
    await storage.initialize();
    await storage.ensureConversationLoaded('c1');
    expect(storage.getAnswerReview('m1')!.draft, bigDraft);
  });

  test('a pending review row is normalized to interrupted on reload', () async {
    final directory = await Directory.systemTemp.createTemp(
      'omnichat_review_pending_',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    var storage = SqliteChatStorage(
      directory: directory,
      appVersion: 'test',
      background: false,
    );
    await storage.initialize();
    addTearDown(() async => storage.dispose());

    await storage.putConversation(
      Conversation(id: 'c1', title: 'Chat', createdAt: DateTime(2026)),
    );
    await storage.appendMessage(
      ChatMessage(
        id: 'm1',
        role: 'assistant',
        content: 'draft',
        conversationId: 'c1',
      ),
    );
    await storage.upsertAnswerReviewPart(
      messageId: 'm1',
      report: const AnswerReviewReport(phase: AnswerReviewPhase.reviewing),
      status: 'pending',
      draft: 'draft',
    );

    await storage.dispose();
    storage = SqliteChatStorage(
      directory: directory,
      appVersion: 'test',
      background: false,
    );
    await storage.initialize();
    await storage.ensureConversationLoaded('c1');
    final restored = storage.getAnswerReview('m1')!;
    expect(restored.status, 'interrupted');
    expect(restored.report.phase, AnswerReviewPhase.interrupted);
    expect(restored.draft, 'draft');
  });

  test('review alone makes the process group visible and live', () {
    final model = buildProcessGroup(
      thoughts: const <ProcessThought>[],
      tools: const <ProcessTool>[],
      isStreaming: true,
      hasAnswerText: true,
      showThinkingCards: true,
      showToolCards: true,
      hasAnswerReview: true,
      answerReviewLive: true,
    );
    expect(model.visible, isTrue);
    expect(model.live, isTrue);
    expect(model.entries, isEmpty);
  });
}
