import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/models/answer_review.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/features/chat/widgets/answer_review_card.dart';
import 'package:OmniChat/icons/lucide_adapter.dart';
import 'package:OmniChat/l10n/app_localizations.dart';
import 'package:OmniChat/shared/widgets/ios_tactile.dart';
import 'package:OmniChat/shared/widgets/markdown_with_highlight.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('collapsed review card shows title, status and issue count', (
    tester,
  ) async {
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
    expect(find.textContaining('Passed', findRichText: true), findsOneWidget);
    expect(find.textContaining('2 issues', findRichText: true), findsOneWidget);
    // Terminal cards start collapsed: the draft body is not rendered.
    expect(find.text('Draft'), findsNothing);

    // The header follows the process/tool rows: 18px icon, 13px muted text,
    // transparent pressable row with no outer border.
    final icon = tester.widget<Icon>(find.byIcon(Lucide.ScanSearch));
    expect(icon.size, 18);
    expect(icon.color, const Color(0xFF7E7F83));

    final header = tester.widget<Text>(
      find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            widget.textSpan != null &&
            widget.textSpan!.toPlainText().contains('Answer review'),
      ),
    );
    final headerSpans = (header.textSpan! as TextSpan).children!;
    final titleSpan = headerSpans.first as TextSpan;
    expect(titleSpan.style?.fontSize, 13);
    expect(titleSpan.style?.fontWeight, FontWeight.normal);
    expect(titleSpan.style?.color, const Color(0xFF7E7F83));

    final press = tester.widget<IosCardPress>(find.byType(IosCardPress));
    expect(press.border, isNull);
    expect(press.baseColor, Colors.transparent);
  });

  testWidgets('expanded draft uses a gray-black body color', (tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: SettingsProvider(),
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: AnswerReviewCard(
              initiallyExpanded: true,
              data: const AnswerReviewViewData(
                report: AnswerReviewReport(
                  phase: AnswerReviewPhase.revised,
                  verdict: 'revise',
                  parsed: true,
                  reviewed: true,
                  issues: <ReviewIssue>[
                    ReviewIssue(
                      severity: 'major',
                      location: 'intro',
                      problem: 'unsupported claim',
                      fix: 'remove it',
                    ),
                  ],
                ),
                draft: 'The draft answer.',
                finalText: 'The revised answer.',
              ),
            ),
          ),
        ),
      ),
    );

    final markdown = tester.widget<MarkdownWithCodeHighlight>(
      find.byType(MarkdownWithCodeHighlight),
    );
    expect(markdown.baseStyle?.fontSize, 12.5);
    // #4A4A50 in light mode: clearly softer than the final answer's onSurface.
    expect(markdown.baseStyle?.color, const Color(0xFF4A4A50));

    // Markdown headings/block components read onSurface from the theme; the
    // draft-local override keeps them gray as well.
    final draftTheme = tester.widget<Theme>(
      find.byKey(const ValueKey('answer-review-draft-theme')),
    );
    expect(draftTheme.data.colorScheme.onSurface, const Color(0xFF4A4A50));
  });
}
