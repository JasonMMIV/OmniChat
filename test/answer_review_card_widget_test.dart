import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/models/answer_review.dart';
import 'package:OmniChat/features/chat/widgets/answer_review_card.dart';
import 'package:OmniChat/l10n/app_localizations.dart';

void main() {
  testWidgets('collapsed review card shows title, status and issue count',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: AnswerReviewCard(
            data: const AnswerReviewViewData(
              report: AnswerReviewReport(
                phase: AnswerReviewPhase.passed,
                verdict: 'pass',
                parsed: true,
                reviewed: true,
                issues: <ReviewIssue>[
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
                reviewMs: 1200,
                reviewTokens: 321,
              ),
              draft: 'draft',
              finalText: 'final',
            ),
          ),
        ),
      ),
    );

    expect(
      find.textContaining('Answer review', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining('Passed', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining('2 issues', findRichText: true),
      findsOneWidget,
    );
    // Terminal cards start collapsed: the draft body is not rendered.
    expect(find.text('Draft'), findsNothing);
  });
}
