import 'package:flutter/material.dart';

import '../../../core/models/answer_review.dart';
import '../../../core/services/file/unified_diff.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/markdown_with_highlight.dart';

/// Everything the review card needs for one assistant message.
///
/// [live] is true while the message is still streaming (the card follows the
/// process group's live state); [finalText] is the current/final answer and is
/// used only for the revision diff.
class AnswerReviewViewData {
  const AnswerReviewViewData({
    required this.report,
    this.draft,
    this.finalText,
    this.live = false,
    this.draftTruncated = false,
  });

  final AnswerReviewReport report;
  final String? draft;
  final String? finalText;
  final bool live;
  final bool draftTruncated;

  bool get hasDraft => (draft ?? '').trim().isNotEmpty;
}

/// Shared phase→localized-label switch for the chat card, the process-group
/// summary and the export Markdown.
String answerReviewStatusLabel(AppLocalizations l10n, String phase) {
  return switch (phase) {
    AnswerReviewPhase.reviewing => l10n.chatAnswerReviewStatusReviewing,
    AnswerReviewPhase.passed => l10n.chatAnswerReviewStatusPassed,
    AnswerReviewPhase.revising => l10n.chatAnswerReviewStatusRevising,
    AnswerReviewPhase.revised => l10n.chatAnswerReviewStatusRevised,
    AnswerReviewPhase.failedOpen => l10n.chatAnswerReviewStatusFailedOpen,
    AnswerReviewPhase.revisionFailed =>
      l10n.chatAnswerReviewStatusRevisionFailed,
    AnswerReviewPhase.cancelled => l10n.chatAnswerReviewStatusCancelled,
    AnswerReviewPhase.interrupted => l10n.chatAnswerReviewStatusInterrupted,
    _ => l10n.chatAnswerReviewStatusReviewing,
  };
}

/// One collapsible review row. Rendered inside [ProcessGroupCard]'s children
/// (after the thinking/tool rows) so it folds with the process group.
class AnswerReviewCard extends StatefulWidget {
  const AnswerReviewCard({
    super.key,
    required this.data,
    this.initiallyExpanded = false,
  });

  final AnswerReviewViewData data;

  /// Export/print call sites render the card fully expanded; chat keeps the
  /// live-expanded / terminal-collapsed default.
  final bool initiallyExpanded;

  @override
  State<AnswerReviewCard> createState() => _AnswerReviewCardState();
}

class _AnswerReviewCardState extends State<AnswerReviewCard> {
  static const int _draftPreviewChars = 4000;
  static const int _diffPreviewLines = 40;

  bool _expanded = false;
  bool _manualToggle = false;
  bool _draftExpanded = false;
  bool _diffExpanded = false;

  @override
  void initState() {
    super.initState();
    _expanded = widget.initiallyExpanded || widget.data.live;
    // Print/export call sites render the complete draft and diff; the chat
    // card keeps the compact previews until the user expands them.
    _draftExpanded = widget.initiallyExpanded;
    _diffExpanded = widget.initiallyExpanded;
  }

  @override
  void didUpdateWidget(covariant AnswerReviewCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data.live != widget.data.live) {
      if (widget.data.live) {
        _expanded = true;
      } else if (!_manualToggle) {
        _expanded = false;
      }
    }
  }

  void _toggle() {
    setState(() {
      _expanded = !_expanded;
      _manualToggle = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final l10n = AppLocalizations.of(context)!;
    final report = widget.data.report;
    final muted = isDark ? const Color(0xFF9E9EA4) : const Color(0xFF7E7F83);
    final bg = cs.surfaceContainerHighest.withValues(
      alpha: isDark ? 0.18 : 0.42,
    );
    final border = cs.outlineVariant.withValues(alpha: 0.45);
    final statusColor = _statusColor(report, cs);

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 2, bottom: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: border, width: 0.7),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildHeader(context, l10n, report, statusColor, muted),
          AnimatedSize(
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeInOutCubic,
            alignment: Alignment.topCenter,
            child: _expanded
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (report.phase == AnswerReviewPhase.reviewing)
                          _hint(l10n.chatAnswerReviewReviewingHint, muted),
                        if (widget.data.hasDraft) ...[
                          const SizedBox(height: 8),
                          _buildDraft(context, l10n, muted),
                        ],
                        if (report.hasIssues) ...[
                          const SizedBox(height: 10),
                          _buildIssues(context, l10n, report, muted),
                        ] else if (report.phase == AnswerReviewPhase.passed ||
                            report.phase == AnswerReviewPhase.revised) ...[
                          const SizedBox(height: 8),
                          Text(
                            l10n.chatAnswerReviewNoIssues,
                            style: TextStyle(fontSize: 12, color: muted),
                          ),
                        ],
                        if (report.phase == AnswerReviewPhase.revised &&
                            widget.data.finalText != null &&
                            widget.data.hasDraft) ...[
                          const SizedBox(height: 10),
                          _buildDiff(context, l10n, report, muted),
                        ],
                        if (_failReason(l10n, report) != null) ...[
                          const SizedBox(height: 8),
                          _failRow(
                            context,
                            _failReason(l10n, report)!,
                            cs,
                            muted,
                          ),
                        ],
                        const SizedBox(height: 8),
                        _buildMeta(l10n, report, muted),
                      ],
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(
    BuildContext context,
    AppLocalizations l10n,
    AnswerReviewReport report,
    Color statusColor,
    Color muted,
  ) {
    final int issueCount = report.issues.length;
    final int totalMs = report.reviewMs + report.revisionMs;
    final String duration = totalMs > 0
        ? '${(totalMs / 1000).toStringAsFixed(1)}s'
        : '';
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: _toggle,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
        child: Row(
          children: [
            Icon(Lucide.ScanSearch, size: 15, color: muted),
            const SizedBox(width: 7),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: l10n.chatAnswerReviewCardTitle,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    TextSpan(
                      text: ' · ${_statusText(l10n, report)}',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: statusColor,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (issueCount > 0)
                      TextSpan(
                        text:
                            ' · ${l10n.chatAnswerReviewIssueCount(issueCount)}',
                        style: TextStyle(fontSize: 11.5, color: muted),
                      ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (duration.isNotEmpty) ...[
              const SizedBox(width: 8),
              Text(
                duration,
                style: TextStyle(
                  fontSize: 11.5,
                  color: muted.withValues(alpha: 0.9),
                ),
              ),
            ],
            AnimatedRotation(
              turns: _expanded ? 0.25 : 0,
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeInOutCubic,
              child: Icon(Lucide.ChevronRight, size: 16, color: muted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _hint(String text, Color muted) => Padding(
    padding: const EdgeInsets.only(top: 2),
    child: Text(text, style: TextStyle(fontSize: 11.5, color: muted)),
  );

  Widget _buildDraft(BuildContext context, AppLocalizations l10n, Color muted) {
    final draft = widget.data.draft ?? '';
    final truncatedForPreview =
        !_draftExpanded && draft.length > _draftPreviewChars;
    final shown = truncatedForPreview
        ? '${draft.substring(0, _draftPreviewChars)}\n…'
        : draft;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              l10n.chatAnswerReviewDraftTitle,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
                color: muted,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              l10n.chatAnswerReviewDraftChars(draft.length),
              style: TextStyle(fontSize: 11, color: muted),
            ),
            if (widget.data.draftTruncated) ...[
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  l10n.chatAnswerReviewDraftTruncated,
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            ],
            if (draft.length > _draftPreviewChars) ...[
              const Spacer(),
              GestureDetector(
                onTap: () => setState(() => _draftExpanded = !_draftExpanded),
                child: Text(
                  _draftExpanded
                      ? l10n.chatAnswerReviewHideDraft
                      : l10n.chatAnswerReviewShowDraft,
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface
                .withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(7),
          ),
          child: MarkdownWithCodeHighlight(
            text: shown,
            isStreaming: false,
            baseStyle: const TextStyle(fontSize: 12.5, height: 1.45),
          ),
        ),
      ],
    );
  }

  Widget _buildIssues(
    BuildContext context,
    AppLocalizations l10n,
    AnswerReviewReport report,
    Color muted,
  ) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.chatAnswerReviewIssuesTitle,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w500,
            color: muted,
          ),
        ),
        const SizedBox(height: 5),
        for (final issue in report.sortedIssues)
          _IssueTile(issue: issue, l10n: l10n, cs: cs, muted: muted),
      ],
    );
  }

  Widget _buildDiff(
    BuildContext context,
    AppLocalizations l10n,
    AnswerReviewReport report,
    Color muted,
  ) {
    if (widget.data.draftTruncated) {
      return Text(
        l10n.chatAnswerReviewDraftTruncated,
        style: TextStyle(fontSize: 11.5, color: muted),
      );
    }
    final diff = computeUnifiedDiff(
      widget.data.draft ?? '',
      widget.data.finalText ?? '',
      path: 'answer',
    );
    final cs = Theme.of(context).colorScheme;
    final lines = <UnifiedDiffLine>[
      for (final hunk in diff.hunks) ...hunk.lines,
    ];
    final shown = _diffExpanded
        ? lines
        : lines.take(_diffPreviewLines).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              l10n.chatAnswerReviewDiffTitle,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
                color: muted,
              ),
            ),
            const SizedBox(width: 6),
            if (!diff.isEmpty)
              Text(
                l10n.chatAnswerReviewDiffSummary(
                  diff.addedLines,
                  diff.removedLines,
                ),
                style: TextStyle(fontSize: 11, color: muted),
              ),
            if (lines.length > _diffPreviewLines) ...[
              const Spacer(),
              GestureDetector(
                onTap: () => setState(() => _diffExpanded = !_diffExpanded),
                child: Text(
                  _diffExpanded
                      ? l10n.chatAnswerReviewHideDiff
                      : l10n.chatAnswerReviewShowDiff,
                  style: TextStyle(fontSize: 11, color: cs.primary),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 4),
        if (diff.isEmpty)
          Text(
            l10n.chatAnswerReviewDiffNone,
            style: TextStyle(fontSize: 11.5, color: muted),
          )
        else
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: cs.surface.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(7),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final line in shown)
                  Text(
                    '${line.prefix}${line.text}',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11.5,
                      height: 1.35,
                      color: switch (line.kind) {
                        DiffLineKind.added =>
                          isDarkColor(cs)
                              ? const Color(0xFF7ED6A5)
                              : const Color(0xFF1B7F4B),
                        DiffLineKind.removed => cs.error,
                        DiffLineKind.context => muted,
                      },
                    ),
                  ),
                if (!_diffExpanded && lines.length > _diffPreviewLines)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '… ${lines.length - _diffPreviewLines} more lines',
                      style: TextStyle(fontSize: 11, color: muted),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _failRow(
    BuildContext context,
    String text,
    ColorScheme cs,
    Color muted,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Lucide.TriangleAlert, size: 13, color: cs.error),
        const SizedBox(width: 5),
        Expanded(
          child: Text(text, style: TextStyle(fontSize: 11.5, color: muted)),
        ),
      ],
    );
  }

  Widget _buildMeta(
    AppLocalizations l10n,
    AnswerReviewReport report,
    Color muted,
  ) {
    final parts = <String>[
      if (report.reviewMs > 0) l10n.chatAnswerReviewReviewTime(report.reviewMs),
      if (report.revisionMs > 0)
        l10n.chatAnswerReviewRevisionTime(report.revisionMs),
      if (report.reviewTokens > 0)
        l10n.chatAnswerReviewTokens(report.reviewTokens),
      if ((report.modelId ?? '').isNotEmpty) report.modelId!,
    ];
    if (parts.isEmpty) return const SizedBox.shrink();
    return Text(
      parts.join(' · '),
      style: TextStyle(fontSize: 10.5, color: muted.withValues(alpha: 0.9)),
    );
  }

  String? _failReason(AppLocalizations l10n, AnswerReviewReport report) {
    return switch (report.failReason) {
      'timeout' => l10n.chatAnswerReviewFailTimeout,
      'error' => l10n.chatAnswerReviewFailError,
      'empty' => l10n.chatAnswerReviewFailEmpty,
      'malformed' => l10n.chatAnswerReviewFailMalformed,
      'revision_failed' => l10n.chatAnswerReviewFailRevisionFailed,
      'revision_paused' => l10n.chatAnswerReviewFailRevisionPaused,
      'revision_tool_call' => l10n.chatAnswerReviewFailRevisionToolCall,
      'cancelled' => l10n.chatAnswerReviewFailCancelled,
      'interrupted' => l10n.chatAnswerReviewFailInterrupted,
      _ => null,
    };
  }

  String _statusText(AppLocalizations l10n, AnswerReviewReport report) =>
      answerReviewStatusLabel(l10n, report.phase);

  Color _statusColor(AnswerReviewReport report, ColorScheme cs) {
    return switch (report.phase) {
      AnswerReviewPhase.passed || AnswerReviewPhase.revised => cs.primary,
      AnswerReviewPhase.failedOpen ||
      AnswerReviewPhase.revisionFailed ||
      AnswerReviewPhase.cancelled ||
      AnswerReviewPhase.interrupted => cs.error,
      _ => cs.onSurfaceVariant,
    };
  }

  bool isDarkColor(ColorScheme cs) => cs.brightness == Brightness.dark;
}

class _IssueTile extends StatelessWidget {
  const _IssueTile({
    required this.issue,
    required this.l10n,
    required this.cs,
    required this.muted,
  });

  final ReviewIssue issue;
  final AppLocalizations l10n;
  final ColorScheme cs;
  final Color muted;

  @override
  Widget build(BuildContext context) {
    final isMinor = issue.severity == 'minor';
    final color = switch (issue.severity) {
      'blocker' => cs.error,
      'major' => cs.tertiary,
      _ => muted,
    };
    final label = switch (issue.severity) {
      'blocker' => l10n.chatAnswerReviewSeverityBlocker,
      'major' => l10n.chatAnswerReviewSeverityMajor,
      _ => l10n.chatAnswerReviewSeverityMinor,
    };
    final body = <Widget>[
      if (issue.location.isNotEmpty) ...[
        _labelValue(
          context,
          l10n.chatAnswerReviewLocation,
          issue.location,
          muted,
          code: true,
        ),
        const SizedBox(height: 3),
      ],
      if (issue.problem.isNotEmpty)
        _labelValue(
          context,
          l10n.chatAnswerReviewProblem,
          issue.problem,
          muted,
        ),
      if (issue.fix.isNotEmpty) ...[
        const SizedBox(height: 3),
        _labelValue(context, l10n.chatAnswerReviewFix, issue.fix, muted),
      ],
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Opacity(
        opacity: isMinor ? 0.72 : 1,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 1),
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: body,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _labelValue(
    BuildContext context,
    String label,
    String value,
    Color muted, {
    bool code = false,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '$label: ',
            style: TextStyle(fontSize: 11, color: muted),
          ),
          TextSpan(
            text: value,
            style: TextStyle(
              fontSize: 11.5,
              color: code ? cs.onSurface : cs.onSurface.withValues(alpha: 0.9),
              fontFamily: code ? 'monospace' : null,
            ),
          ),
        ],
      ),
    );
  }
}
