import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:gpt_markdown/custom_widgets/markdown_config.dart'
    show GptMarkdownConfig;
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/github.dart';
import 'package:flutter_highlight/themes/atom-one-dark-reasonable.dart';
import 'package:highlight/highlight.dart' show highlight, Node;
import '../../icons/lucide_adapter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_gallery_saver_plus/image_gallery_saver_plus.dart';
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;
import '../../utils/sandbox_path_resolver.dart';
import '../../utils/markdown_preview_html.dart';
import '../../features/chat/pages/image_viewer_page.dart';
import '../../features/chat/pages/html_preview_page.dart';
import 'code_block_download_button.dart';
import 'snackbar.dart';
import 'mermaid_bridge.dart';
import 'export_capture_scope.dart';
import 'ios_tactile.dart';
import 'mermaid_image_cache.dart';
import 'plantuml_block.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/app_font_weights.dart';
import '../../theme/theme_factory.dart' show getPlatformFontFallback;
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../core/providers/settings_provider.dart';
import '../../desktop/html_preview_dialog.dart';

/// gpt_markdown with custom code block highlight and inline code styling.
class MarkdownWithCodeHighlight extends StatelessWidget {
  const MarkdownWithCodeHighlight({
    super.key,
    required this.text,
    this.onCitationTap,
    this.baseStyle,
    this.isStreaming = false,
  });

  final String text;
  final void Function(String id)? onCitationTap;
  final TextStyle? baseStyle; // optional override for base markdown text style
  // When true, the widget is owned by an actively streaming message (typewriter
  // updates each chunk). To avoid native resource lifecycle races amplified by
  // the markdown rebuild storm, native-backed code blocks (Mermaid WebView2 /
  // PlantUML, which spawn WebView2) are deferred: while streaming they render as
  // a pure-Dart collapsible code block. Once isStreaming flips to false, a
  // rebuild swaps in the real WebView2 renderer. Backward-compatible default
  // keeps existing static-content call sites unchanged.
  final bool isStreaming;

  // Tunable: list scaling compensation exponent.
  // When chat scale s != 1.0, lists often feel slightly off compared to body.
  // We apply s^(1-k) instead of s to the list rows to gently normalize.
  // Increase k if lists still look larger at small scales; decrease if too small at large scales.
  static const double kMarkdownListScaleCompensation = 0.84;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cs = Theme.of(context).colorScheme;
    final sanitizedText = _sanitizeImageLinks(text);
    final imageUrls = _extractImageUrls(sanitizedText);
    final normalized = preprocessFences(
      sanitizedText,
      enableMath: settings.enableMathRendering,
      enableDollarLatex: settings.enableDollarLatex,
    );
    // Base text style (can be overridden by caller)
    final baseTextStyle = (baseStyle ?? Theme.of(context).textTheme.bodyMedium)
        ?.copyWith(
          fontSize: baseStyle?.fontSize ?? 15.5,
          height: baseStyle?.height ?? 1.55,
          letterSpacing:
              baseStyle?.letterSpacing ?? (_isZh(context) ? 0.0 : 0.05),
          color: null,
        );

    // Replace default components and add our own where needed
    final components = List<MarkdownComponent>.from(
      MarkdownComponent.globalComponents,
    );
    final hrIdx = components.indexWhere((c) => c is HrLine);
    if (hrIdx != -1) components[hrIdx] = SoftHrLine();
    final bqIdx = components.indexWhere((c) => c is BlockQuote);
    if (bqIdx != -1) components[bqIdx] = ModernBlockQuote();
    final cbIdx = components.indexWhere((c) => c is CheckBoxMd);
    if (cbIdx != -1) components[cbIdx] = ModernCheckBoxMd();
    final rbIdx = components.indexWhere((c) => c is RadioButtonMd);
    if (rbIdx != -1) components[rbIdx] = ModernRadioMd();
    // Escape/math-aware table cell splitting so `|` inside $...$ / \(...\) / \|
    // spans is not treated as a column separator (kelivo v1.1.16 port).
    final tableIdx = components.indexWhere((c) => c is TableMd);
    if (tableIdx != -1) components[tableIdx] = EscapeAwareTableMd();
    // Prepend custom renderers in priority order (fence first)
    // Temporarily disable custom bold label line transformer to avoid
    // interfering with block parsing for complex documents.
    // components.insert(0, LabelValueLineMd());
    // Ensure backslash-escaped punctuation renders literally (e.g., \*, \`, \[)
    // Must run before emphasis/links/code parsing to neutralize markers.
    components.insert(0, BackslashEscapeMd());
    // Conditionally add LaTeX/math renderers
    if (settings.enableMathRendering) {
      // Block-level LaTeX (e.g., $$...$$ or \[...\])
      components.insert(0, LatexBlockScrollableMd());
      // Inline LaTeX: $...$ and \(...\)
      if (settings.enableDollarLatex) {
        components.insert(0, InlineLatexParenScrollableMd());
        components.insert(0, InlineLatexDollarScrollableMd());
      } else {
        // Only \(...\) inline
        components.insert(0, InlineLatexParenScrollableMd());
      }
    }
    components.insert(0, AtxHeadingMd());
    // Ensure fenced code blocks take precedence over headings and other blocks
    // so lines like "# comment" inside code fences are not parsed as headings.
    components.insert(0, FencedCodeBlockMd(isStreaming: isStreaming));
    // HTML <details>/<summary> collapsible blocks (kelivo v1.1.13 port).
    // Registered ahead of fences; fenced-code content is protected by the
    // <details>/<summary> tag-start mask applied in preprocessFences.
    components.insert(0, DetailsHtmlMd());
    // Inline components: keep defaults but make link parsing line-scoped
    final inlineComponents = List<MarkdownComponent>.from(
      MarkdownComponent.inlineComponents,
    );
    final linkIdxInline = inlineComponents.indexWhere((c) => c is ATagMd);
    if (linkIdxInline != -1) {
      inlineComponents[linkIdxInline] = LineSafeLinkMd();
    }
    // Raw HTML <a href> anchors (kelivo v1.1.13 port).
    inlineComponents.insert(0, HtmlAnchorMd());
    // codeBuilder handles rendering. A custom BlockMd for fences can
    // interfere with block segmentation in some cases.
    // Resolve user preferred code font family (default to monospace)
    String resolveCodeFont() {
      final fam = settings.codeFontFamily;
      if (fam == null || fam.isEmpty) return 'monospace';
      if (settings.codeFontIsGoogle) {
        try {
          final s = GoogleFonts.getFont(fam);
          return s.fontFamily ?? fam;
        } catch (_) {
          return fam;
        }
      }
      return fam;
    }

    final codeFontFamily = resolveCodeFont();

    // Resolve app font for all markdown text (headings, lists, etc.)
    String resolveAppFont() {
      final fam = settings.appFontFamily;
      if (fam == null || fam.isEmpty) return '';
      if (settings.appFontIsGoogle) {
        try {
          final s = GoogleFonts.getFont(fam);
          return s.fontFamily ?? fam;
        } catch (_) {
          return fam;
        }
      }
      return fam;
    }

    final appFontFamily = resolveAppFont();

    // Force rebuild of the markdown when key theme colors change to avoid stale styles
    final markdownWidget = GptMarkdown(
      key: ValueKey(
        '${Theme.of(context).brightness.index}-${cs.surface.value}-${cs.onSurface.value}-${cs.primary.value}-${cs.outlineVariant.value}',
      ),
      normalized,
      style: baseTextStyle,
      followLinkColor: true,
      // Disable built-in $...$ LaTeX so our custom scrollable handlers take over
      useDollarSignsForLatex: false,
      onLinkTap: (url, title) => _handleLinkTap(context, url),
      components: components,
      inlineComponents: inlineComponents,
      imageBuilder: (ctx, url, width, height) {
        final imgs = (imageUrls ?? const <String>[]).isNotEmpty
            ? imageUrls!
            : <String>[url];
        final idx = imgs.indexOf(url);
        final initial = idx >= 0 ? idx : 0;
        final provider = _imageProviderFor(url);
        return GestureDetector(
          onTap: () {
            Navigator.of(ctx).push(
              PageRouteBuilder(
                pageBuilder: (_, __, ___) => ImageViewerPage(
                  images: imgs ?? <String>[url],
                  initialIndex: initial,
                ),
                transitionDuration: const Duration(milliseconds: 360),
                reverseTransitionDuration: const Duration(milliseconds: 280),
                transitionsBuilder: (context, anim, sec, child) {
                  final curved = CurvedAnimation(
                    parent: anim,
                    curve: Curves.easeOutCubic,
                    reverseCurve: Curves.easeInCubic,
                  );
                  return FadeTransition(
                    opacity: curved,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0, 0.02),
                        end: Offset.zero,
                      ).animate(curved),
                      child: child,
                    ),
                  );
                },
              ),
            );
          },
          child: LayoutBuilder(
            builder: (context, constraints) {
              return ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: () {
                  if (provider == null) {
                    // Missing or unsupported source: show a broken image indicator
                    return const Icon(Icons.broken_image);
                  }
                  return Image(
                    image: provider,
                    width: constraints.maxWidth,
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stack) =>
                        const Icon(Icons.broken_image),
                  );
                }(),
              );
            },
          ),
        );
      },
      linkBuilder: (ctx, span, url, style) {
        final label = span.toPlainText().trim();
        // Special handling: [citation](index:id)
        if (label.toLowerCase() == 'citation') {
          final parts = url.split(':');
          if (parts.length == 2) {
            final indexText = parts[0].trim();
            final id = parts[1].trim();
            final cs = Theme.of(ctx).colorScheme;
            return GestureDetector(
              onTap: () {
                if (onCitationTap != null && id.isNotEmpty) {
                  onCitationTap!(id);
                } else {
                  // Fallback: do nothing
                }
              },
              child: Container(
                width: 16,
                height: 16,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: cs.primary.withOpacity(0.20),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  indexText,
                  style: const TextStyle(fontSize: 10, height: 1.0),
                ),
              ),
            );
          }
        }
        // Default link appearance
        final cs = Theme.of(ctx).colorScheme;
        return Text(
          span.toPlainText(),
          style: style.copyWith(
            color: cs.primary,
            decoration: TextDecoration.none,
          ),
          textAlign: TextAlign.start,
        );
      },
      orderedListBuilder: (ctx, no, child, cfg) {
        final style = (cfg.style ?? const TextStyle()).copyWith(
          fontWeight: FontWeight.w400,
        );
        // Apply a soft compensation so when chat scale != 100%,
        // list items don't visually feel larger/smaller than body text.
        final double kListComp =
            MarkdownWithCodeHighlight.kMarkdownListScaleCompensation;
        final double s = MediaQuery.of(ctx).textScaleFactor;
        final double comp = math.pow(s == 0 ? 1.0 : s, -kListComp).toDouble();
        final double newScale = (s * comp).clamp(0.5, 3.0);
        return MediaQuery(
          data: MediaQuery.of(ctx).copyWith(textScaleFactor: newScale),
          child: Directionality(
            textDirection: cfg.textDirection,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              textBaseline: TextBaseline.alphabetic,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              children: [
                Padding(
                  padding: const EdgeInsetsDirectional.only(start: 6, end: 6),
                  child: Text("$no.", style: style),
                ),
                // Keep child as-is so it inherits context MediaQuery scaling once
                Flexible(child: child),
              ],
            ),
          ),
        );
      },
      // Note: property name is unOrderedListBuilder (camel-cased with capital O)
      // Signature in gpt_markdown 1.1.4: (BuildContext ctx, Widget child, GptMarkdownConfig cfg) -> Widget
      // We compose the bullet + content here to control scaling/spacing.
      unOrderedListBuilder: (ctx, child, cfg) {
        final style = (cfg.style ?? const TextStyle()).copyWith(
          fontWeight: FontWeight.w400,
        );
        final double kListComp =
            MarkdownWithCodeHighlight.kMarkdownListScaleCompensation;
        final double s = MediaQuery.of(ctx).textScaleFactor;
        final double comp = math.pow(s == 0 ? 1.0 : s, -kListComp).toDouble();
        final double newScale = (s * comp).clamp(0.5, 3.0);
        return MediaQuery(
          data: MediaQuery.of(ctx).copyWith(textScaleFactor: newScale),
          child: Directionality(
            textDirection: cfg.textDirection,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              textBaseline: TextBaseline.alphabetic,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              children: [
                Padding(
                  padding: const EdgeInsetsDirectional.only(start: 6, end: 6),
                  child: Text('•', style: style),
                ),
                // Keep child untouched to follow context scaling exactly once
                Flexible(child: child),
              ],
            ),
          ),
        );
      },
      tableBuilder: (ctx, rows, style, cfg) {
        final cs = Theme.of(ctx).colorScheme;
        final isDark = Theme.of(ctx).brightness == Brightness.dark;
        final borderColor = cs.outlineVariant.withOpacity(isDark ? 0.22 : 0.28);
        // Blend header background with surface so it matches current theme tone
        final headerBg = Color.alphaBlend(
          cs.primary.withOpacity(isDark ? 0.14 : 0.08),
          cs.surface,
        );
        final headerStyle = (style).copyWith(
          fontWeight: FontWeight.w600,
          // Ensure header text adapts to theme changes
          color: cs.onSurface,
        );
        final cellStyle = (style).copyWith(
          // Ensure cell text adapts to theme changes
          color: cs.onSurface,
        );

        // Count max columns to pad missing cells
        int maxCol = 0;
        for (final r in rows) {
          if (r.fields.length > maxCol) maxCol = r.fields.length;
        }

        // Desktop platform detection (for selection + layout)
        final bool isDesktop =
            Platform.isMacOS || Platform.isWindows || Platform.isLinux;

        // Common cell builder
        Widget cell(
          String text,
          TextAlign align, {
          bool header = false,
          bool lastCol = false,
          bool lastRow = false,
        }) {
          // Render inline markdown (bold, code, links) inside table cells
          final innerCfg = cfg.copyWith(
            style: header ? headerStyle : cellStyle,
          );
          final children = MarkdownComponent.generate(
            ctx,
            text,
            innerCfg,
            true,
          );
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Align(
              alignment: () {
                switch (align) {
                  case TextAlign.center:
                    return Alignment.center;
                  case TextAlign.right:
                    return Alignment.centerRight;
                  default:
                    return Alignment.centerLeft;
                }
              }(),
              child: isDesktop
                  ? SelectableText.rich(
                      TextSpan(
                        style: header ? headerStyle : cellStyle,
                        children: children,
                      ),
                      textAlign: align,
                      maxLines: null,
                    )
                  : RichText(
                      text: TextSpan(
                        style: header ? headerStyle : cellStyle,
                        children: children,
                      ),
                      textAlign: align,
                      softWrap: true,
                      maxLines: null,
                      overflow: TextOverflow.visible,
                      textWidthBasis: TextWidthBasis.parent,
                    ),
            ),
          );
        }

        // Build a horizontally scrollable table (mobile) or responsive wrapping table (desktop)
        if (!isDesktop) {
          // Mobile/tablet: keep horizontal scroll to preserve layout
          final table = Table(
            defaultColumnWidth: const IntrinsicColumnWidth(),
            border: TableBorder(
              horizontalInside: BorderSide(color: borderColor, width: 0.5),
              verticalInside: BorderSide(color: borderColor, width: 0.5),
            ),
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            children: [
              if (rows.isNotEmpty)
                TableRow(
                  decoration: BoxDecoration(color: headerBg),
                  children: List.generate(maxCol, (i) {
                    final f = i < rows.first.fields.length
                        ? rows.first.fields[i]
                        : null;
                    final txt = f?.data ?? '';
                    final align = f?.alignment ?? TextAlign.left;
                    return cell(
                      txt,
                      align,
                      header: true,
                      lastCol: i == maxCol - 1,
                      lastRow: false,
                    );
                  }),
                ),
              for (int r = 1; r < rows.length; r++)
                TableRow(
                  children: List.generate(maxCol, (c) {
                    final f = c < rows[r].fields.length
                        ? rows[r].fields[c]
                        : null;
                    final txt = f?.data ?? '';
                    final align = f?.alignment ?? TextAlign.left;
                    return cell(
                      txt,
                      align,
                      lastCol: c == maxCol - 1,
                      lastRow: r == rows.length - 1,
                    );
                  }),
                ),
            ],
          );

          return _wrapTableWithToolbar(
            ctx,
            rows,
            headerBg,
            SelectionContainer.disabled(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                primary: false,
                child: DefaultTextStyle.merge(
                  // Ensure any nested spans fallback to current onSurface instead of stale defaults
                  style: TextStyle(color: cs.onSurface),
                  child: table,
                ),
              ),
            ),
          );
        }

        // Desktop: fit within available width and wrap cell content.
        // Do NOT add an inner SelectionArea here to allow selection to span
        // across the entire message-level SelectionArea wrapper.
        return _wrapTableWithToolbar(
          ctx,
          rows,
          headerBg,
          LayoutBuilder(
            builder: (context, constraints) {
              // Use equal flex for all columns so table width == available width.
              final Map<int, TableColumnWidth> columnWidths = {
              for (int i = 0; i < maxCol; i++) i: const FlexColumnWidth(),
            };

            final table = Table(
              defaultColumnWidth: const FlexColumnWidth(),
              border: TableBorder(
                horizontalInside: BorderSide(color: borderColor, width: 0.5),
                verticalInside: BorderSide(color: borderColor, width: 0.5),
              ),
              columnWidths: columnWidths,
              defaultVerticalAlignment: TableCellVerticalAlignment.middle,
              children: [
                if (rows.isNotEmpty)
                  TableRow(
                    decoration: BoxDecoration(color: headerBg),
                    children: List.generate(maxCol, (i) {
                      final f = i < rows.first.fields.length
                          ? rows.first.fields[i]
                          : null;
                      final txt = f?.data ?? '';
                      final align = f?.alignment ?? TextAlign.left;
                      return cell(
                        txt,
                        align,
                        header: true,
                        lastCol: i == maxCol - 1,
                        lastRow: false,
                      );
                    }),
                  ),
                for (int r = 1; r < rows.length; r++)
                  TableRow(
                    children: List.generate(maxCol, (c) {
                      final f = c < rows[r].fields.length
                          ? rows[r].fields[c]
                          : null;
                      final txt = f?.data ?? '';
                      final align = f?.alignment ?? TextAlign.left;
                      return cell(
                        txt,
                        align,
                        lastCol: c == maxCol - 1,
                        lastRow: r == rows.length - 1,
                      );
                    }),
                  ),
              ],
            );

              return DefaultTextStyle.merge(
                style: TextStyle(color: cs.onSurface),
                child: table,
              );
            },
          ),
        );
      },
      // Inline `code` styling via highlightBuilder in gpt_markdown
      highlightBuilder: (ctx, inline, style) {
        // Restore $ masked by preprocessFences so code content renders literally.
        String softened = _softBreakInline(unmaskCodeDollars(inline));
        final bool isDarkCtx = Theme.of(ctx).brightness == Brightness.dark;
        final csCtx = Theme.of(ctx).colorScheme;
        final bg = isDarkCtx ? Colors.white12 : const Color(0xFFF1F3F5);
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: csCtx.outlineVariant.withOpacity(0.22)),
          ),
          child: Text(
            softened,
            style: TextStyle(
              fontFamily: codeFontFamily,
              fontSize: 13,
              height: 1.4,
            ).copyWith(color: csCtx.onSurface),
            softWrap: true,
            overflow: TextOverflow.visible,
          ),
        );
      },
      // Fenced code block styling via codeBuilder (with collapse/expand)
      codeBuilder: (ctx, name, code, closed) {
        // Restore $ and <details>/<summary masks from preprocessFences so code
        // content renders literally.
        final codeText = unmaskFencedHtmlTagStarts(unmaskCodeDollars(code));
        final lang = name.trim();
        final langLower = lang.toLowerCase();
        // While the owning message is actively streaming, defer native-backed
        // code blocks (Mermaid/PlantUML WebView2) to a pure-Dart collapsible
        // code block. This eliminates WebView2 init/dispose races amplified by
        // the per-chunk markdown rebuild storm (root cause of 0xc0000374 heap
        // corruption observed on Windows). When isStreaming flips to false, the
        // parent rebuild swaps in the real WebView2 renderer.
        if ((langLower == 'mermaid' || langLower == 'plantuml') && isStreaming) {
          return _CollapsibleCodeBlock(language: lang, code: codeText);
        }
        if (langLower == 'mermaid') {
          return _MermaidBlock(code: codeText);
        } else if (langLower == 'plantuml') {
          return PlantUMLBlock(code: codeText);
        }
        return _CollapsibleCodeBlock(language: lang, code: codeText);
      },
    );

    if (appFontFamily.isEmpty) return markdownWidget;
    return DefaultTextStyle.merge(
      style: TextStyle(fontFamily: appFontFamily),
      child: markdownWidget,
    );
  }

  static String _displayLanguage(BuildContext context, String? raw) {
    final zh = _isZh(context);
    final t = raw?.trim();
    if (t != null && t.isNotEmpty) return t;
    return zh ? '代码' : 'Code';
  }

  static bool _isZh(BuildContext context) =>
      Localizations.localeOf(context).languageCode == 'zh';

  static Map<String, TextStyle> _transparentBgTheme(
    Map<String, TextStyle> base,
  ) {
    final m = Map<String, TextStyle>.from(base);
    final root = base['root'];
    if (root != null) {
      m['root'] = root.copyWith(backgroundColor: Colors.transparent);
    } else {
      m['root'] = const TextStyle(backgroundColor: Colors.transparent);
    }
    return m;
  }

  static String? _normalizeLanguage(String? lang) {
    if (lang == null || lang.trim().isEmpty) return null;
    final l = lang.trim().toLowerCase();
    switch (l) {
      case 'js':
      case 'javascript':
        return 'javascript';
      case 'ts':
      case 'typescript':
        return 'typescript';
      case 'sh':
      case 'zsh':
      case 'bash':
      case 'shell':
        return 'bash';
      case 'yml':
        return 'yaml';
      case 'py':
      case 'python':
        return 'python';
      case 'rb':
      case 'ruby':
        return 'ruby';
      case 'kt':
      case 'kotlin':
        return 'kotlin';
      case 'java':
        return 'java';
      case 'c#':
      case 'cs':
      case 'csharp':
        return 'csharp';
      case 'objc':
      case 'objectivec':
        return 'objectivec';
      case 'swift':
        return 'swift';
      case 'go':
      case 'golang':
        return 'go';
      case 'php':
        return 'php';
      case 'dart':
        return 'dart';
      case 'json':
        return 'json';
      case 'html':
        return 'xml';
      case 'md':
      case 'markdown':
        return 'markdown';
      case 'sql':
        return 'sql';
      default:
        return l; // try as-is
    }
  }

  /// Placeholder used to shield `$` characters inside inline code spans and
  /// fenced code blocks from the LaTeX preprocessing ([preprocessFences]).
  /// Restored by [unmaskCodeDollars] in the code render paths
  /// ([highlightBuilder], [codeBuilder] and [FencedCodeBlockMd]).
  /// Mirrors kelivo's "delayed unmask" strategy for the same bug.
  static const String codeDollarMask = '___CODE_DOLLAR_MASK___';

  /// Restores `$` characters that were masked by [codeDollarMask].
  static String unmaskCodeDollars(String s) =>
      s.replaceAll(codeDollarMask, r'$');

  /// Single-char placeholder used to shield `<details` / `</details` /
  /// `<summary` / `</summary` tag starts inside fenced code blocks from the
  /// block-level [DetailsHtmlMd] pattern (kelivo v1.1.17 port).
  static const String fencedHtmlTagStartMask = '\uE002';

  /// True when [input] at [i] begins a `<details` / `</details` / `<summary` /
  /// `</summary` tag (case-insensitive, word-boundary terminated).
  static bool _isFencedHtmlTagStart(String input, int i) {
    if (i >= input.length || input.codeUnitAt(i) != 0x3C /* '<' */) {
      return false;
    }
    var j = i + 1;
    if (j < input.length && input.codeUnitAt(j) == 0x2F /* '/' */) j++;
    final lower = input.substring(j).toLowerCase();
    if (lower.startsWith('details')) {
      j += 'details'.length;
    } else if (lower.startsWith('summary')) {
      j += 'summary'.length;
    } else {
      return false;
    }
    // Word boundary: next char must not continue the tag name.
    if (j < input.length) {
      final c = input.codeUnitAt(j);
      if (_isAsciiLetterOrDigit(c) || c == 0x5F /* '_' */) return false;
    }
    return true;
  }

  /// Restores `<` masked by [fencedHtmlTagStartMask].
  static String unmaskFencedHtmlTagStarts(String s) =>
      s.replaceAll(fencedHtmlTagStartMask, '<');

  /// Replaces every `$` that appears inside an inline code span (`` `...` ``)
  /// or a fenced code block (``` ... ```) with [codeDollarMask] so that
  /// [preprocessFences] never misparses code content as LaTeX math.
  static String _maskDollarsInCode(String input) {
    const dollar = 0x24; // '$'
    final n = input.length;
    final inCode = List<bool>.filled(n, false);
    final inFencePos = List<bool>.filled(n, false);

    // 1) Fenced code blocks: a line starting with ``` (optionally after
    //    whitespace / a list marker) opens or closes a region; an unclosed
    //    region extends to EOF. Mirrors the fence patterns normalized later
    //    in preprocessFences (plain, indented, and list-item fences).
    final fenceLine = RegExp(r'^\s*(?:[*+-]|\d+\.)?\s*```');
    var lineStart = 0;
    var insideFence = false;
    for (final line in input.split('\n')) {
      if (fenceLine.hasMatch(line)) insideFence = !insideFence;
      if (insideFence) {
        for (var j = lineStart; j < lineStart + line.length && j < n; j++) {
          if (input.codeUnitAt(j) == dollar) inCode[j] = true;
          inFencePos[j] = true;
        }
      }
      lineStart += line.length + 1; // +1 for the '\n' separator
    }

    // 2) Inline code spans (single backtick, mirroring gpt_markdown's
    //    HighlightedText). Mask `$` between the delimiting backticks.
    final inlineCodeRe = RegExp(r"`(?!`)(.+?)(?<!`)`(?!`)");
    for (final m in inlineCodeRe.allMatches(input)) {
      final start = m.start + 1; // skip opening backtick
      final end = m.end - 1; // exclude closing backtick
      for (var j = start; j < end; j++) {
        if (input.codeUnitAt(j) == dollar) inCode[j] = true;
      }
    }

    if (!inCode.contains(true) && !inFencePos.contains(true)) return input;
    final buf = StringBuffer();
    for (var i = 0; i < n; i++) {
      if (inCode[i]) {
        buf.write(codeDollarMask);
      } else if (inFencePos[i] && _isFencedHtmlTagStart(input, i)) {
        // Shield <details>/<summary tag starts from DetailsHtmlMd block parsing
        // (kelivo v1.1.17 port); single-char mask preserves string lengths.
        buf.write(fencedHtmlTagStartMask);
      } else {
        buf.write(input[i]);
      }
    }
    return buf.toString();
  }

  static String preprocessFences(
    String input, {
    required bool enableMath,
    required bool enableDollarLatex,
  }) {
    // Normalize newlines to simplify regex handling
    var out = input.replaceAll('\r\n', '\n');

    // 2025-10-23 Fix: Remove title attributes from markdown links to work around gpt_markdown's
    // link regex limitation. The package's regex `[^\s]*` stops at spaces, so
    // [text](url "title") breaks. Strip titles while preserving the URL.
    // Matches: [text](url "title") or [text](url 'title') or [text](url title)
    final linkWithTitle = RegExp(r'\[([^\]]+)\]\(([^\s)]+)\s+[^)]*\)');
    out = out.replaceAllMapped(linkWithTitle, (match) {
      final text = match.group(1);
      final url = match.group(2);
      return '[$text]($url)';
    });

    // Shield `$` inside inline code spans / fenced code blocks from the LaTeX
    // conversions below. Runs unconditionally (also protects the $$ display-math
    // normalization that follows) and is restored at render time via
    // unmaskCodeDollars in the code render paths.
    out = _maskDollarsInCode(out);

    // Normalize inline $...$ math into \( ... \) so it always matches the LaTeX
    // renderer (even when vendors emit single-dollar math mixed with prose).
    // Skips $$...$$ blocks, which are handled separately. Uses a boundary-aware
    // scanner (kelivo v1.1.15/v1.1.16 port) instead of a plain regex so that
    //   - "Price is $5 and total is $10" is NOT parsed as math (closing boundary)
    //   - table rows keep $...$ math intact across cell pipes (per-cell handled)
    //   - CJK/full-width punctuation adjacency works while `abc$x$` stays literal
    //   - body length is capped to avoid UI-thread stalls
    if (enableMath && enableDollarLatex) {
      out = _replaceInlineDollarMath(out);
    }

    // Ensure display-math blocks stay as standalone blocks even when generated inline.
    // Some providers emit "$$...$$" inside list items or paragraphs; without extra
    // newlines gpt_markdown may treat them as plain text. We normalize multi-line
    // display math into its own block to guarantee rendering.
    final inlineDisplayMath = RegExp(r"\$\$([\s\S]*?)\$\$");
    out = out.replaceAllMapped(inlineDisplayMath, (m) {
      final body = (m.group(1) ?? '').trim();
      // Only normalize true display math (multi-line or clearly not inline literals)
      if (body.isEmpty) return m[0]!;
      final hasNewline = body.contains('\n');
      if (!hasNewline && body.length < 12)
        return m[0]!; // looks like inline literal, leave intact
      // Surround with blank lines to force a block; keep existing body trimmed
      final prefix = m.start == 0 || out.substring(0, m.start).endsWith('\n\n')
          ? ''
          : '\n';
      final suffix =
          m.end == out.length || out.substring(m.end).startsWith('\n\n')
          ? ''
          : '\n';
      return '${prefix}\$\$\n$body\n\$\$${suffix}';
    });

    // 1) Move fenced code from list lines to the next line: "* ```lang" -> "*\n```lang"
    final bulletFence = RegExp(
      r"^(\s*(?:[*+-]|\d+\.)\s+)```([^\s`]*)\s*$",
      multiLine: true,
    );
    out = out.replaceAllMapped(bulletFence, (m) => "${m[1]}\n```${m[2]}");

    // 2) Dedent opening fences: leading spaces before ```lang
    final dedentOpen = RegExp(r"^[ \t]+```([^\n`]*)\s*$", multiLine: true);
    out = out.replaceAllMapped(dedentOpen, (m) => "```${m[1]}");

    // 3) Dedent closing fences: leading spaces before ```
    final dedentClose = RegExp(r"^[ \t]+```\s*$", multiLine: true);
    out = out.replaceAllMapped(dedentClose, (m) => "```");

    // 4) Ensure closing fences are on their own line: transform "} ```" or "}```" into "}\n```"
    final inlineClosing = RegExp(r"([^\r\n`])```(?=\s*(?:\r?\n|$))");
    out = out.replaceAllMapped(inlineClosing, (m) => "${m[1]}\n```");

    // 5) Disambiguate Setext vs HR after label-value lines:
    // If a line of only dashes follows a bold label line (e.g., "**作者:** 张三"),
    // insert a blank line so it's treated as an HR, not a Setext heading underline.
    final labelThenDash = RegExp(
      r"^(\*\*[^\n*]+\*\*.*)\n(\s*-{3,}\s*$)",
      multiLine: true,
    );
    out = out.replaceAllMapped(labelThenDash, (m) => "${m[1]}\n\n${m[2]}");

    // 6) Allow ATX headings starting with enumerations like "## 1.引言" or "## 1. 引言"
    // Insert a zero-width non-joiner after the dot to prevent list parsing without changing visual text.
    final atxEnum = RegExp(
      r"^(\s{0,3}#{1,6}\s+\d+)\.(\s*)(\S)",
      multiLine: true,
    );
    out = out.replaceAllMapped(atxEnum, (m) => "${m[1]}.\u200C${m[2]}${m[3]}");

    // 7) Auto-close an unmatched opening code fence at EOF
    final fenceAtBol = RegExp(r"^\s*```", multiLine: true);
    final count = fenceAtBol.allMatches(out).length;
    if (count % 2 == 1) {
      if (!out.endsWith('\n')) out += '\n';
      out += '```';
    }

    // 8) Fix: when multiple markdown links are placed on separate lines using
    //    trailing double-spaces (hard line breaks), gpt_markdown may treat them
    //    as a single paragraph and only render the first link correctly.
    //    To avoid this, convert such lines into separate paragraphs by
    //    inserting an extra blank line after lines that end with a markdown
    //    link and have at least two trailing spaces.
    //    Example affected pattern:
    //      Label：[text](url)  \nNext： [text](url)  \n
    final linkWithTrailingSpaces = RegExp(r"\[[^\]]+\]\([^\)]+\)\s{2,}$");
    final lines = out.split('\n');
    if (lines.length > 1) {
      final buf = StringBuffer();
      for (int i = 0; i < lines.length; i++) {
        final line = lines[i];
        buf.write(line);
        if (i < lines.length - 1) buf.write('\n');
        if (linkWithTrailingSpaces.hasMatch(line)) {
          // Ensure a blank line to break the paragraph for the next line
          buf.write('\n');
        }
      }
      out = buf.toString();
    }

    return out;
  }

  // Safe math renderer that falls back to plain text when parsing fails.
  static Widget _renderMath(
    String tex, {
    TextStyle? style,
    MathStyle mathStyle = MathStyle.text,
  }) {
    final resolved = style ?? const TextStyle();
    try {
      return Math.tex(
        tex,
        mathStyle: mathStyle,
        textStyle: resolved,
        onErrorFallback: (err) => Text(tex, style: resolved),
      );
    } catch (_) {
      return Text(tex, style: resolved);
    }
  }

  static String _softBreakInline(String input) {
    // Insert zero-width break for inline code segments with long tokens.
    if (input.length < 60) return input;
    final buf = StringBuffer();
    for (int i = 0; i < input.length; i++) {
      buf.write(input[i]);
      if ((i + 1) % 24 == 0) buf.write('\u200B');
    }
    return buf.toString();
  }

  Future<void> _handleLinkTap(BuildContext context, String url) async {
    Uri uri;
    try {
      uri = _normalizeUrl(url);
    } catch (_) {
      showAppSnackBar(
        context,
        message: _isZh(context) ? '无效链接' : 'Invalid link',
        type: NotificationType.error,
      );
      return;
    }
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      showAppSnackBar(
        context,
        message: _isZh(context) ? '无法打开链接' : 'Cannot open link',
        type: NotificationType.error,
      );
    }
  }

  Uri _normalizeUrl(String url) {
    var u = url.trim();
    if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:').hasMatch(u)) {
      u = 'https://' + u;
    }
    return Uri.parse(u);
  }

  static List<String> _extractImageUrls(String md) {
    final re = RegExp(r"!\[[^\]]*\]\(([^)\s]+)\)");
    return re
        .allMatches(md)
        .map((m) => (m.group(1) ?? '').trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  static String _sanitizeImageLinks(String input) {
    final re = RegExp(r'!\[([^\]]*)\]\(([^)]+)\)', multiLine: true);
    return input.replaceAllMapped(re, (m) {
      final alt = m.group(1) ?? '';
      final inside = (m.group(2) ?? '').trim();
      if (inside.isEmpty) return m[0]!;

      // Leave remote URLs and data URLs untouched.
      if (inside.startsWith('http://') ||
          inside.startsWith('https://') ||
          inside.startsWith('data:')) {
        return m[0]!;
      }

      final url = inside;
      final isFileUri = url.startsWith('file://');
      final isRemote = url.startsWith('http://') || url.startsWith('https://');
      final isData = url.startsWith('data:');
      final isWindowsAbs = RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(url);
      final isLikelyLocalPath =
          (!isRemote && !isData) &&
          (isFileUri || url.startsWith('/') || isWindowsAbs);

      if (!isLikelyLocalPath || !url.contains(' ')) {
        return m[0]!;
      }

      String safeUrl;
      try {
        if (isFileUri) {
          final uri = Uri.parse(url);
          safeUrl = uri.toString();
        } else {
          // Plain absolute file system path -> file:// URI.
          safeUrl = Uri.file(url).toString();
        }
      } catch (_) {
        // Fallback: minimally escape spaces.
        safeUrl = url.replaceAll(' ', '%20');
      }

      return '![${alt}](${safeUrl})';
    });
  }

  static ImageProvider? _imageProviderFor(String src) {
    if (src.startsWith('http://') || src.startsWith('https://')) {
      return NetworkImage(src);
    }
    if (src.startsWith('data:')) {
      try {
        final base64Marker = 'base64,';
        final idx = src.indexOf(base64Marker);
        if (idx != -1) {
          final b64 = src.substring(idx + base64Marker.length);
          return MemoryImage(base64Decode(b64));
        }
      } catch (_) {}
      return null;
    }
    final fixed = SandboxPathResolver.fix(src);
    final f = File(fixed);
    if (f.existsSync()) {
      return FileImage(f);
    }
    // Missing local file or unsupported scheme
    return null;
  }
}

/// Stable content-addressed key (language + first 16 chars of normalized
/// code) used to remember manual expand/collapse choices across rebuilds
/// (kelivo v1.1.13 port).
String _codeBlockStateKey(String language, String code) {
  final normalizedLanguage = language.trim().toLowerCase();
  final normalizedCode = code.trimLeft().replaceAll(RegExp(r'\s+'), ' ');
  final anchor = normalizedCode.length <= 16
      ? normalizedCode
      : normalizedCode.substring(0, 16);
  return '$normalizedLanguage|$anchor';
}

class _CollapsibleCodeBlock extends StatefulWidget {
  final String language;
  final String code;

  const _CollapsibleCodeBlock({required this.language, required this.code});

  @override
  State<_CollapsibleCodeBlock> createState() => _CollapsibleCodeBlockState();
}

class _CollapsibleCodeBlockState extends State<_CollapsibleCodeBlock> {
  // Content-addressed memory of the user's manual expand/collapse choice
  // (kelivo v1.1.13 port). Survives streaming content changes and widget
  // re-creation (e.g. scroll virtualization) for blocks that were toggled.
  static final Map<String, bool> _manualExpansionByCodeKey = <String, bool>{};
  static const int _maxStoredManualExpansionStates = 80;

  bool _expanded = true;
  bool _manuallyToggled = false;
  late String _stateKey;

  @override
  void initState() {
    super.initState();
    _stateKey = _codeBlockStateKey(widget.language, widget.code);
    _applyInitialAutoCollapse();
  }

  @override
  void didUpdateWidget(covariant _CollapsibleCodeBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncStateKeyForStreamingUpdate();
    _applyAutoCollapseIfNeeded();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _applyAutoCollapseIfNeeded();
  }

  void _applyInitialAutoCollapse() {
    final stored = _manualExpansionByCodeKey[_stateKey];
    if (stored != null) {
      _expanded = stored;
      _manuallyToggled = true;
      return;
    }
    final sp = context.read<SettingsProvider>();
    if (!sp.autoCollapseCodeBlock) return;
    final threshold = sp.autoCollapseCodeBlockLines;
    if (_exceedsLineThreshold(widget.code, threshold)) {
      _expanded = false;
    }
  }

  void _applyAutoCollapseIfNeeded() {
    if (_manuallyToggled) return;
    if (!_expanded) return;
    final sp = context.read<SettingsProvider>();
    if (!sp.autoCollapseCodeBlock) return;
    final threshold = sp.autoCollapseCodeBlockLines;

    if (_exceedsLineThreshold(widget.code, threshold)) {
      setState(() => _expanded = false);
    }
  }

  // If the content this widget renders changed identity (different language or
  // a different 16-char code prefix, e.g. during streaming), persist the
  // user's manual choice under the old key and adopt any stored choice for the
  // new key.
  void _syncStateKeyForStreamingUpdate() {
    final nextKey = _codeBlockStateKey(widget.language, widget.code);
    if (nextKey == _stateKey) return;

    if (_manuallyToggled) {
      _stateKey = nextKey;
      _rememberManualExpansionState();
      return;
    }

    _stateKey = nextKey;
    final stored = _manualExpansionByCodeKey[_stateKey];
    if (stored == null) return;
    _expanded = stored;
    _manuallyToggled = true;
  }

  void _rememberManualExpansionState() {
    _manualExpansionByCodeKey[_stateKey] = _expanded;
    if (_manualExpansionByCodeKey.length <= _maxStoredManualExpansionStates) {
      return;
    }
    _manualExpansionByCodeKey.remove(_manualExpansionByCodeKey.keys.first);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final settings = context.watch<SettingsProvider>();
    String resolveCodeFont() {
      final fam = settings.codeFontFamily;
      if (fam == null || fam.isEmpty) return 'monospace';
      if (settings.codeFontIsGoogle) {
        try {
          final s = GoogleFonts.getFont(fam);
          return s.fontFamily ?? fam;
        } catch (_) {
          return fam;
        }
      }
      return fam;
    }

    final codeFontFamily = resolveCodeFont();

    // Use theme-tinted surfaces so headers follow the current theme color.
    final Color bodyBg = Color.alphaBlend(
      cs.primary.withOpacity(isDark ? 0.06 : 0.03),
      cs.surface,
    );
    final Color headerBg = Color.alphaBlend(
      cs.primary.withOpacity(isDark ? 0.16 : 0.10),
      cs.surface,
    );

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(12)),
      // Clip children to the same radius so they don't overpaint corners
      clipBehavior: Clip.antiAlias,
      // Draw the border on top so it remains visible at corners
      foregroundDecoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant.withOpacity(0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header layout: language (left) + copy action (icon + label) + expand/collapse icon
          Material(
            color: headerBg,
            elevation: 0,
            shadowColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            child: InkWell(
              onTap: () => setState(() {
                _manuallyToggled = true;
                _expanded = !_expanded;
                _rememberManualExpansionState();
              }),
              splashColor: Platform.isIOS ? Colors.transparent : null,
              highlightColor: Platform.isIOS ? Colors.transparent : null,
              hoverColor: Platform.isIOS ? Colors.transparent : null,
              overlayColor: Platform.isIOS
                  ? const MaterialStatePropertyAll(Colors.transparent)
                  : null,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: cs.outlineVariant.withOpacity(0.28),
                      width: 1.0,
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    const SizedBox(width: 2),
                    Text(
                      MarkdownWithCodeHighlight._displayLanguage(
                        context,
                        widget.language,
                      ),
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: cs.onSurface,
                        height: 1.0,
                      ),
                    ),
                    const Spacer(),
                    if (_isPreviewable(widget.language))
                      InkWell(
                        onTap: () async {
                          final l10n = AppLocalizations.of(context)!;
                          final isXml = _isXml(widget.language);
                          // Markdown/CSV/TSV blocks are transformed into
                          // renderable HTML before opening the preview.
                          String html = widget.code;
                          if (_isMarkdown(widget.language)) {
                            try {
                              html =
                                  await MarkdownPreviewHtmlBuilder
                                      .buildFromMarkdown(
                                        context,
                                        widget.code,
                                      );
                            } catch (_) {
                              if (!mounted) return;
                              showAppSnackBar(
                                context,
                                message: l10n.mermaidPreviewOpenFailed,
                                type: NotificationType.error,
                              );
                              return;
                            }
                          } else if (_isTable(widget.language)) {
                            html = _buildTableHtml(
                              widget.code,
                              isTsv: widget.language.trim().toLowerCase() ==
                                  'tsv',
                            );
                          }
                          if (!mounted) return;
                          if (Platform.isAndroid || Platform.isIOS) {
                            // Mobile: navigate to preview page
                            Navigator.of(context).push(
                              PageRouteBuilder(
                                pageBuilder: (_, __, ___) => HtmlPreviewPage(
                                  html: html,
                                  isXml: isXml,
                                ),
                                transitionDuration: const Duration(
                                  milliseconds: 300,
                                ),
                                reverseTransitionDuration: const Duration(
                                  milliseconds: 240,
                                ),
                                transitionsBuilder:
                                    (context, anim, sec, child) {
                                      final curved = CurvedAnimation(
                                        parent: anim,
                                        curve: Curves.easeOutCubic,
                                        reverseCurve: Curves.easeInCubic,
                                      );
                                      return FadeTransition(
                                        opacity: curved,
                                        child: child,
                                      );
                                    },
                              ),
                            );
                          } else if (Platform.isLinux) {
                            // Linux: show not supported
                            showAppSnackBar(
                              context,
                              message: l10n.htmlPreviewNotSupportedOnLinux,
                              type: NotificationType.warning,
                            );
                          } else {
                            // Desktop (macOS/Windows): open dialog
                            try {
                              // Defer import to avoid cycle
                              // ignore: use_build_context_synchronously
                              await showHtmlPreviewDesktopDialog(
                                context,
                                html: html,
                                isXml: isXml,
                              );
                            } catch (_) {}
                          }
                        },
                        splashColor: Platform.isIOS ? Colors.transparent : null,
                        highlightColor: Platform.isIOS
                            ? Colors.transparent
                            : null,
                        hoverColor: Platform.isIOS ? Colors.transparent : null,
                        overlayColor: Platform.isIOS
                            ? const MaterialStatePropertyAll(Colors.transparent)
                            : null,
                        borderRadius: BorderRadius.circular(6),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 6,
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Lucide.Eye,
                                size: 14,
                                color: cs.onSurface.withOpacity(0.6),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                AppLocalizations.of(
                                  context,
                                )!.codeBlockPreviewButton,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: cs.onSurface.withOpacity(0.6),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    // Download action: save the block as a file. Shown on every
                    // code block (the Copy button is always available).
                    CodeBlockDownloadButton(onTap: _downloadCode),
                    // Copy action: icon + label ("复制"/localized)
                    InkWell(
                      onTap: () async {
                        await Clipboard.setData(
                          ClipboardData(text: widget.code),
                        );
                        if (mounted) {
                          showAppSnackBar(
                            context,
                            message: AppLocalizations.of(
                              context,
                            )!.chatMessageWidgetCopiedToClipboard,
                            type: NotificationType.success,
                          );
                        }
                      },
                      splashColor: Platform.isIOS ? Colors.transparent : null,
                      highlightColor: Platform.isIOS
                          ? Colors.transparent
                          : null,
                      hoverColor: Platform.isIOS ? Colors.transparent : null,
                      overlayColor: Platform.isIOS
                          ? const MaterialStatePropertyAll(Colors.transparent)
                          : null,
                      borderRadius: BorderRadius.circular(6),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 6,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Lucide.Copy,
                              size: 14,
                              color: cs.onSurface.withOpacity(0.6),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              AppLocalizations.of(
                                context,
                              )!.shareProviderSheetCopyButton,
                              style: TextStyle(
                                fontSize: 12,
                                color: cs.onSurface.withOpacity(0.6),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    AnimatedRotation(
                      turns: _expanded ? 0.25 : 0.0, // right -> down
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOutCubic,
                      child: Icon(
                        Lucide.ChevronRight,
                        size: 16,
                        color: cs.onSurface.withOpacity(0.7),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: SizeTransition(
                sizeFactor: anim,
                axisAlignment: -1.0,
                child: child,
              ),
            ),
            child: _expanded
                ? Container(
                    key: const ValueKey('code-expanded'),
                    width: double.infinity,
                    color: bodyBg,
                    padding: const EdgeInsets.fromLTRB(10, 6, 6, 10),
                    child: () {
                      // Desktop: enable word wrap, allow selection, no height limit, no scroll
                      // Mobile: horizontal scroll by default, or word wrap if setting enabled
                      final bool isDesktop =
                          Platform.isMacOS ||
                          Platform.isWindows ||
                          Platform.isLinux;

                      if (isDesktop) {
                        // Desktop: auto wrap, selectable, no height limit, no scroll
                        return SelectableHighlightView(
                          _trimTrailingNewlines(widget.code),
                          language:
                              MarkdownWithCodeHighlight._normalizeLanguage(
                                widget.language,
                              ) ??
                              'plaintext',
                          theme: MarkdownWithCodeHighlight._transparentBgTheme(
                            isDark ? atomOneDarkReasonableTheme : githubTheme,
                          ),
                          padding: EdgeInsets.zero,
                          textStyle: TextStyle(
                            fontFamily: codeFontFamily,
                            fontSize: 13,
                            height: 1.5,
                          ),
                        );
                      }

                      // Mobile: check settings for word wrap
                      final bool shouldWrap = settings.mobileCodeBlockWrap;

                      if (shouldWrap) {
                        // Mobile with wrap enabled: selectable, auto wrap
                        return SelectableHighlightView(
                          _trimTrailingNewlines(widget.code),
                          language:
                              MarkdownWithCodeHighlight._normalizeLanguage(
                                widget.language,
                              ) ??
                              'plaintext',
                          theme: MarkdownWithCodeHighlight._transparentBgTheme(
                            isDark ? atomOneDarkReasonableTheme : githubTheme,
                          ),
                          padding: EdgeInsets.zero,
                          textStyle: TextStyle(
                            fontFamily: codeFontFamily,
                            fontSize: 13,
                            height: 1.5,
                          ),
                        );
                      }

                      // Mobile without wrap: horizontal scroll, selectable
                      return SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        primary: false,
                        child: SelectableHighlightView(
                          _trimTrailingNewlines(widget.code),
                          language:
                              MarkdownWithCodeHighlight._normalizeLanguage(
                                widget.language,
                              ) ??
                              'plaintext',
                          theme: MarkdownWithCodeHighlight._transparentBgTheme(
                            isDark ? atomOneDarkReasonableTheme : githubTheme,
                          ),
                          padding: EdgeInsets.zero,
                          textStyle: TextStyle(
                            fontFamily: codeFontFamily,
                            fontSize: 13,
                            height: 1.5,
                          ),
                        ),
                      );
                    }(),
                  )
                : Container(
                    key: const ValueKey('code-collapsed'),
                    width: double.infinity,
                    color: bodyBg,
                    padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                    child: () {
                      final l10n = AppLocalizations.of(context)!;
                      final code = widget.code;
                      final end = _trimTrailingNewlinesEndIndex(code);

                      final preview = <String>[];
                      int totalLines = 0;
                      if (end > 0) {
                        totalLines = 1;
                        int lineStart = 0;
                        for (int i = 0; i < end; i++) {
                          final cu = code.codeUnitAt(i);
                          if (cu == 0x0A /* \n */ || cu == 0x0D /* \r */) {
                            if (preview.length < 2) {
                              preview.add(code.substring(lineStart, i));
                            }
                            totalLines++;
                            if (cu == 0x0D /* \r */ &&
                                i + 1 < end &&
                                code.codeUnitAt(i + 1) == 0x0A /* \n */) {
                              i++;
                            }
                            lineStart = i + 1;
                          }
                        }
                        if (preview.length < 2) {
                          preview.add(code.substring(lineStart, end));
                        }
                      }

                      final hiddenLines =
                          (totalLines - preview.length).clamp(0, 999999);

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final line in preview)
                            Text(
                              line,
                              style: TextStyle(
                                fontFamily: codeFontFamily,
                                fontSize: 13,
                                height: 1.5,
                                color: cs.onSurface,
                              ),
                              softWrap: false,
                              overflow: TextOverflow.ellipsis,
                            ),
                          if (hiddenLines > 0)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                l10n.codeBlockCollapsedLines(hiddenLines),
                                style: TextStyle(
                                  fontSize: 12,
                                  height: 1.4,
                                  color: cs.onSurface.withOpacity(0.55),
                                ),
                                softWrap: false,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                      );
                    }(),
                  ),
          ),
        ],
      ),
    );
  }

  bool _exceedsLineThreshold(String code, int threshold) {
    if (threshold < 1) return true;
    final end = _trimTrailingNewlinesEndIndex(code);
    if (end <= 0) return false;

    int lines = 1;
    for (int i = 0; i < end; i++) {
      final cu = code.codeUnitAt(i);
      if (cu == 0x0A /* \n */) {
        lines++;
        if (lines > threshold) return true;
        continue;
      }
      if (cu == 0x0D /* \r */) {
        lines++;
        if (lines > threshold) return true;
        if (i + 1 < end && code.codeUnitAt(i + 1) == 0x0A) i++;
      }
    }
    return false;
  }

  int _trimTrailingNewlinesEndIndex(String s) {
    int end = s.length;
    while (end > 0) {
      final ch = s.codeUnitAt(end - 1);
      if (ch == 0x0A /* \n */ || ch == 0x0D /* \r */) {
        end--;
        continue;
      }
      break;
    }
    return end;
  }

  // Remove trailing newlines to avoid rendering an extra empty line at the bottom
  String _trimTrailingNewlines(String s) {
    if (s.isEmpty) return s;
    final end = _trimTrailingNewlinesEndIndex(s);
    return end == s.length ? s : s.substring(0, end);
  }

  // Save the code block to a file using the shared export flow.
  Future<void> _downloadCode() => saveCodeBlockToFile(
        context,
        widget.code,
        _downloadExtensionFor(widget.language),
      );
}

bool _isHtml(String? lang) {
  final l = (lang ?? '').trim().toLowerCase();
  return l == 'html' || l == 'htm' || l == 'rawhtml' || l == 'raw_html';
}

bool _isXml(String? lang) {
  final l = (lang ?? '').trim().toLowerCase();
  const xmlFamily = {
    'xml',
    'svg',
    'xsd',
    'xsl',
    'xslt',
    'rss',
    'atom',
    'plist',
    'xaml',
  };
  return xmlFamily.contains(l);
}

bool _isMarkdown(String? lang) {
  final l = (lang ?? '').trim().toLowerCase();
  return l == 'md' || l == 'markdown' || l == 'mdx';
}

bool _isTable(String? lang) {
  final l = (lang ?? '').trim().toLowerCase();
  return l == 'csv' || l == 'tsv';
}

bool _isPreviewable(String? lang) =>
    _isHtml(lang) || _isXml(lang) || _isMarkdown(lang) || _isTable(lang);

// Map a code block language tag to the file extension used when downloading it.
// Covers the common languages; unknown tags fall back to .txt.
String _downloadExtensionFor(String? lang) {
  switch ((lang ?? '').trim().toLowerCase()) {
    case 'html':
    case 'htm':
    case 'rawhtml':
    case 'raw_html':
      return 'html';
    case 'xml':
      return 'xml';
    case 'svg':
      return 'svg';
    case 'xsd':
      return 'xsd';
    case 'xsl':
      return 'xsl';
    case 'xslt':
      return 'xslt';
    case 'rss':
      return 'rss';
    case 'atom':
      return 'atom';
    case 'plist':
      return 'plist';
    case 'xaml':
      return 'xaml';
    case 'md':
    case 'markdown':
    case 'mdx':
      return 'md';
    case 'csv':
      return 'csv';
    case 'tsv':
      return 'tsv';
    case 'js':
    case 'javascript':
      return 'js';
    case 'jsx':
      return 'jsx';
    case 'ts':
    case 'typescript':
      return 'ts';
    case 'tsx':
      return 'tsx';
    case 'sh':
    case 'zsh':
    case 'bash':
    case 'shell':
      return 'sh';
    case 'yml':
    case 'yaml':
      return 'yml';
    case 'py':
    case 'python':
      return 'py';
    case 'rb':
    case 'ruby':
      return 'rb';
    case 'kt':
    case 'kotlin':
      return 'kt';
    case 'java':
      return 'java';
    case 'c#':
    case 'cs':
    case 'csharp':
      return 'cs';
    case 'c':
      return 'c';
    case 'cpp':
    case 'c++':
    case 'cc':
    case 'hpp':
      return 'cpp';
    case 'h':
      return 'h';
    case 'objc':
    case 'objectivec':
      return 'm';
    case 'swift':
      return 'swift';
    case 'go':
    case 'golang':
      return 'go';
    case 'php':
      return 'php';
    case 'dart':
      return 'dart';
    case 'rust':
    case 'rs':
      return 'rs';
    case 'json':
      return 'json';
    case 'json5':
      return 'json5';
    case 'sql':
      return 'sql';
    case 'css':
      return 'css';
    case 'scss':
      return 'scss';
    case 'sass':
      return 'sass';
    case 'less':
      return 'less';
    case 'vue':
      return 'vue';
    case 'svelte':
      return 'svelte';
    case 'lua':
      return 'lua';
    case 'r':
      return 'r';
    case 'scala':
      return 'scala';
    case 'groovy':
      return 'groovy';
    case 'perl':
    case 'pl':
      return 'pl';
    case 'toml':
      return 'toml';
    case 'ini':
    case 'cfg':
    case 'conf':
      return 'ini';
    case 'diff':
    case 'patch':
      return 'diff';
    case 'txt':
    case 'text':
    case 'plaintext':
      return 'txt';
    case 'dockerfile':
      return 'dockerfile';
    case 'makefile':
      return 'mk';
    case 'gradle':
      return 'gradle';
    case 'cmake':
      return 'cmake';
    case 'ps1':
    case 'powershell':
      return 'ps1';
    case 'bat':
    case 'batch':
      return 'bat';
    case 'mermaid':
      return 'mmd';
    case 'plantuml':
    case 'puml':
      return 'puml';
    default:
      return 'txt';
  }
}


// Build a themed HTML table fragment for CSV/TSV code blocks. The fragment is
// embedded into the preview shell, which supplies the theme background/text
// colors, so the styles here only need to be theme-neutral.
String _buildTableHtml(String code, {required bool isTsv}) {
  final delimiter = isTsv ? '\t' : ',';
  final rows = _parseDelimited(code, delimiter);
  if (rows.isEmpty) return '<p>${_escapeHtml(code)}</p>';

  var colCount = 0;
  for (final r in rows) {
    if (r.length > colCount) colCount = r.length;
  }

  final buffer = StringBuffer();
  buffer.write('''
<style>
  .csv-table-wrap { overflow: auto; max-height: 70vh; }
  table.csv-table { border-collapse: collapse; width: 100%; font-size: 13px; }
  table.csv-table th, table.csv-table td {
    border: 1px solid rgba(128, 128, 128, 0.35);
    padding: 6px 10px; text-align: left; vertical-align: top;
    word-break: break-word; white-space: pre-wrap;
  }
  table.csv-table th {
    background: rgba(128, 128, 128, 0.16);
    font-weight: 600; position: sticky; top: 0;
  }
  table.csv-table tbody tr:nth-child(even) td {
    background: rgba(128, 128, 128, 0.06);
  }
</style>
<div class="csv-table-wrap"><table class="csv-table">''');

  // First row is treated as the header.
  final header = rows.first;
  buffer.write('<thead><tr>');
  for (var i = 0; i < colCount; i++) {
    buffer.write(
      '<th>${_escapeHtml(i < header.length ? header[i] : '')}</th>',
    );
  }
  buffer.write('</tr></thead><tbody>');
  for (var r = 1; r < rows.length; r++) {
    final row = rows[r];
    buffer.write('<tr>');
    for (var i = 0; i < colCount; i++) {
      buffer.write(
        '<td>${_escapeHtml(i < row.length ? row[i] : '')}</td>',
      );
    }
    buffer.write('</tr>');
  }
  buffer.write('</tbody></table></div>');
  return buffer.toString();
}

// Minimal CSV/TSV parser: supports double-quoted fields, escaped quotes (""),
// delimiters/newlines inside quotes, and CRLF line endings.
List<List<String>> _parseDelimited(String input, String delimiter) {
  final rows = <List<String>>[];
  var row = <String>[];
  final buf = StringBuffer();
  var inQuotes = false;
  var i = 0;
  final n = input.length;
  while (i < n) {
    final c = input[i];
    if (inQuotes) {
      if (c == '"') {
        if (i + 1 < n && input[i + 1] == '"') {
          buf.write('"');
          i += 2;
          continue;
        }
        inQuotes = false;
        i++;
        continue;
      }
      buf.write(c);
      i++;
      continue;
    }
    if (c == '"') {
      inQuotes = true;
      i++;
      continue;
    }
    if (c == delimiter) {
      row.add(buf.toString());
      buf.clear();
      i++;
      continue;
    }
    if (c == '\r' || c == '\n') {
      row.add(buf.toString());
      buf.clear();
      rows.add(row);
      row = <String>[];
      if (c == '\r' && i + 1 < n && input[i + 1] == '\n') i++;
      i++;
      continue;
    }
    buf.write(c);
    i++;
  }
  if (buf.isNotEmpty || row.isNotEmpty) {
    row.add(buf.toString());
    rows.add(row);
  }
  // Drop fully-empty trailing rows (common trailing newline).
  while (rows.isNotEmpty && rows.last.every((f) => f.trim().isEmpty)) {
    rows.removeLast();
  }
  return rows;
}

String _escapeHtml(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');

enum _MermaidTab { image, code }

String _mermaidCacheKey(
  String code,
  bool isDark,
  Map<String, String> themeVars,
) {
  final entries = themeVars.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  final themeSig = entries.map((e) => '${e.key}=${e.value}').join('&');
  return '${isDark ? 'dark' : 'light'}|$themeSig|$code';
}

enum MermaidBitmapRenderStatus { success, failed, unsupported }

class MermaidBitmapRenderResult {
  const MermaidBitmapRenderResult._(this.status, [this.bytes]);

  factory MermaidBitmapRenderResult.success(Uint8List bytes) {
    return MermaidBitmapRenderResult._(
      MermaidBitmapRenderStatus.success,
      bytes,
    );
  }

  factory MermaidBitmapRenderResult.failed() {
    return const MermaidBitmapRenderResult._(MermaidBitmapRenderStatus.failed);
  }

  factory MermaidBitmapRenderResult.unsupported() {
    return const MermaidBitmapRenderResult._(
      MermaidBitmapRenderStatus.unsupported,
    );
  }

  final MermaidBitmapRenderStatus status;
  final Uint8List? bytes;
}

class _MermaidBlock extends StatefulWidget {
  final String code;
  const _MermaidBlock({required this.code});

  @override
  State<_MermaidBlock> createState() => _MermaidBlockState();
}

class _MermaidBlockState extends State<_MermaidBlock> {
  static const Duration _settledBitmapRenderDelay = Duration(
    milliseconds: 220,
  );
  static const double _previewHeight = 406;

  bool _expanded = true;
  _MermaidTab _selectedTab = _MermaidTab.image;
  late final ScrollController _vMermaidScrollController;
  OverlayEntry? _renderOverlayEntry;
  bool _renderQueued = false;
  bool _renderingBitmap = false;
  String? _renderKey;
  Uint8List? _lastRenderedBytes;
  Timer? _renderDebounce;
  bool _bitmapRenderingUnsupported = false;
  bool _suppressBitmapLoading = false;
  final Set<String> _failedBitmapRenderKeys = <String>{};

  @override
  void initState() {
    super.initState();
    _vMermaidScrollController = ScrollController();
  }

  @override
  void didUpdateWidget(covariant _MermaidBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.code != widget.code) {
      _renderDebounce?.cancel();
      _renderQueued = false;
      _renderingBitmap = false;
      _removeRenderOverlay();
      _renderKey = null;
      _lastRenderedBytes = null;
      _suppressBitmapLoading = false;
      _bitmapRenderingUnsupported = false;
      _failedBitmapRenderKeys.clear();
      _selectedTab = _MermaidTab.image;
    }
  }

  @override
  void dispose() {
    _renderDebounce?.cancel();
    _removeRenderOverlay();
    _vMermaidScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final l10n = AppLocalizations.of(context)!;

    // Use theme-tinted surfaces so headers follow the current theme color.
    final Color bodyBg = Color.alphaBlend(
      cs.primary.withValues(alpha: isDark ? 0.06 : 0.03),
      cs.surface,
    );
    final Color headerBg = Color.alphaBlend(
      cs.primary.withValues(alpha: isDark ? 0.16 : 0.10),
      cs.surface,
    );
    final palette = _MermaidTabPalette(
      track: Color.alphaBlend(
        cs.primary.withValues(alpha: isDark ? 0.10 : 0.06),
        cs.surface,
      ),
      selected: cs.surface,
      textPrimary: cs.onSurface,
      textSecondary: cs.onSurface.withValues(alpha: 0.6),
    );

    // Build theme variables mapping for Mermaid from Material ColorScheme
    String hex(Color c) {
      final v = c.value & 0xFFFFFFFF;
      final r = (v >> 16) & 0xFF;
      final g = (v >> 8) & 0xFF;
      final b = v & 0xFF;
      return '#'
              '${r.toRadixString(16).padLeft(2, '0')}'
              '${g.toRadixString(16).padLeft(2, '0')}'
              '${b.toRadixString(16).padLeft(2, '0')}'
          .toUpperCase();
    }

    final themeVars = <String, String>{
      'primaryColor': hex(cs.primary),
      'primaryTextColor': hex(cs.onPrimary),
      'primaryBorderColor': hex(cs.primary),
      'secondaryColor': hex(cs.secondary),
      'secondaryTextColor': hex(cs.onSecondary),
      'secondaryBorderColor': hex(cs.secondary),
      'tertiaryColor': hex(cs.tertiary),
      'tertiaryTextColor': hex(cs.onTertiary),
      'tertiaryBorderColor': hex(cs.tertiary),
      'background': hex(cs.background),
      'mainBkg': hex(cs.primaryContainer),
      'secondBkg': hex(cs.secondaryContainer),
      'lineColor': hex(cs.onBackground),
      'textColor': hex(cs.onBackground),
      'nodeBkg': hex(cs.surface),
      'nodeBorder': hex(cs.primary),
      'clusterBkg': hex(cs.surface),
      'clusterBorder': hex(cs.primary),
      'actorBorder': hex(cs.primary),
      'actorBkg': hex(cs.surface),
      'actorTextColor': hex(cs.onBackground),
      'actorLineColor': hex(cs.primary),
      'taskBorderColor': hex(cs.primary),
      'taskBkgColor': hex(cs.primary),
      'taskTextLightColor': hex(cs.onPrimary),
      'taskTextDarkColor': hex(cs.onBackground),
      'labelColor': hex(cs.onBackground),
      'errorBkgColor': hex(cs.error),
      'errorTextColor': hex(cs.onError),
    };

    final exporting = ExportCaptureScope.of(context);
    final cacheKey = _mermaidCacheKey(widget.code, isDark, themeVars);
    final themedCachedBytes = MermaidImageCache.get(cacheKey);
    final legacyCachedBytes = MermaidImageCache.get(widget.code);
    final exactCachedBytes = themedCachedBytes ?? legacyCachedBytes;
    final cachedBytes = exactCachedBytes;
    final displayBytes = cachedBytes ?? _lastRenderedBytes;
    final actionBytes = cachedBytes ?? displayBytes;
    final renderFailedForCurrentCode = _failedBitmapRenderKeys.contains(
      cacheKey,
    );
    final hasRenderableCode = widget.code.trim().isNotEmpty;
    if (!exporting &&
        _expanded &&
        hasRenderableCode &&
        exactCachedBytes == null &&
        !_bitmapRenderingUnsupported &&
        !renderFailedForCurrentCode) {
      _scheduleBitmapRender(
        isDark: isDark,
        themeVars: themeVars,
      );
    }
    final hasImage = displayBytes != null && displayBytes.isNotEmpty;
    final showLoading =
        !hasImage &&
        !_suppressBitmapLoading &&
        !_bitmapRenderingUnsupported &&
        !renderFailedForCurrentCode &&
        (_renderQueued || _renderingBitmap);
    final showError =
        !hasImage &&
        !_bitmapRenderingUnsupported &&
        renderFailedForCurrentCode &&
        _selectedTab == _MermaidTab.image;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.antiAlias,
      foregroundDecoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header: image/code tabs (left) + actions (right)
          Material(
            color: headerBg,
            elevation: 0,
            shadowColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 4),
              decoration: BoxDecoration(
                border: Border(
                  bottom: _expanded
                      ? BorderSide(
                          color: cs.outlineVariant.withValues(alpha: 0.28),
                          width: 1.0,
                        )
                      : BorderSide.none,
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsetsDirectional.only(
                        start: 12,
                        end: 10,
                      ),
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: palette.track,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(2),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _MermaidTabButton(
                                  label: l10n.mermaidImageTab,
                                  selected:
                                      _selectedTab == _MermaidTab.image,
                                  palette: palette,
                                  onTap: () => setState(
                                    () => _selectedTab = _MermaidTab.image,
                                  ),
                                ),
                                _MermaidTabButton(
                                  label: l10n.mermaidCodeTab,
                                  selected: _selectedTab == _MermaidTab.code,
                                  palette: palette,
                                  onTap: () => setState(
                                    () => _selectedTab = _MermaidTab.code,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (!exporting) ...[
                    // Copy action
                    InkWell(
                      onTap: () async {
                        await Clipboard.setData(
                          ClipboardData(text: widget.code),
                        );
                        if (mounted) {
                          showAppSnackBar(
                            context,
                            message: AppLocalizations.of(
                              context,
                            )!.chatMessageWidgetCopiedToClipboard,
                            type: NotificationType.success,
                          );
                        }
                      },
                      splashColor: Platform.isIOS ? Colors.transparent : null,
                      highlightColor: Platform.isIOS
                          ? Colors.transparent
                          : null,
                      hoverColor: Platform.isIOS ? Colors.transparent : null,
                      overlayColor: Platform.isIOS
                          ? const MaterialStatePropertyAll(Colors.transparent)
                          : null,
                      borderRadius: BorderRadius.circular(6),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 6,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Lucide.Copy,
                              size: 14,
                              color: cs.onSurface.withValues(alpha: 0.6),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              l10n.shareProviderSheetCopyButton,
                              style: TextStyle(
                                fontSize: 12,
                                color: cs.onSurface.withValues(alpha: 0.6),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    // Download PNG action (from the cached bitmap)
                    InkWell(
                      onTap:
                          actionBytes == null || actionBytes.isEmpty
                              ? null
                              : () => _saveMermaidBytes(context, actionBytes),
                      splashColor: Platform.isIOS ? Colors.transparent : null,
                      highlightColor: Platform.isIOS
                          ? Colors.transparent
                          : null,
                      hoverColor: Platform.isIOS ? Colors.transparent : null,
                      overlayColor: Platform.isIOS
                          ? const MaterialStatePropertyAll(Colors.transparent)
                          : null,
                      borderRadius: BorderRadius.circular(6),
                      child: Opacity(
                        opacity:
                            actionBytes == null || actionBytes.isEmpty
                            ? 0.4
                            : 1.0,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 6,
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Lucide.Download,
                                size: 14,
                                color: cs.onSurface.withValues(alpha: 0.6),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                l10n.codeBlockDownloadButton,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: cs.onSurface.withValues(alpha: 0.6),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    // Collapse toggle
                    InkWell(
                      onTap: () => setState(() => _expanded = !_expanded),
                      splashColor: Platform.isIOS ? Colors.transparent : null,
                      highlightColor: Platform.isIOS
                          ? Colors.transparent
                          : null,
                      hoverColor: Platform.isIOS ? Colors.transparent : null,
                      overlayColor: Platform.isIOS
                          ? const MaterialStatePropertyAll(Colors.transparent)
                          : null,
                      borderRadius: BorderRadius.circular(6),
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: AnimatedRotation(
                          turns: _expanded ? 0.25 : 0.0,
                          duration: const Duration(milliseconds: 180),
                          curve: Curves.easeOutCubic,
                          child: Icon(
                            Lucide.ChevronRight,
                            size: 16,
                            color: cs.onSurface.withValues(alpha: 0.7),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                ],
              ),
            ),
          ),
          // Content
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: SizeTransition(
                sizeFactor: anim,
                alignment: Alignment.topCenter,
                child: child,
              ),
            ),
            child: _expanded
                ? Container(
                    key: const ValueKey('mermaid-expanded'),
                    width: double.infinity,
                    color: bodyBg,
                    child: SizedBox(
                      key: const ValueKey('mermaid-preview-body'),
                      width: double.infinity,
                      height: _previewHeight,
                      child: ColoredBox(
                        color: bodyBg,
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 180),
                          switchInCurve: Curves.easeOutCubic,
                          switchOutCurve: Curves.easeInCubic,
                          layoutBuilder: (currentChild, previousChildren) {
                            return currentChild ?? const SizedBox.shrink();
                          },
                          child: _buildMermaidBody(
                            context: context,
                            palette: palette,
                            displayBytes: displayBytes,
                            cacheKey: cacheKey,
                            showLoading: showLoading,
                            showError: showError,
                          ),
                        ),
                      ),
                    ),
                  )
                : const SizedBox.shrink(key: ValueKey('mermaid-collapsed')),
          ),
        ],
      ),
    );
  }

  Widget _buildMermaidBody({
    required BuildContext context,
    required _MermaidTabPalette palette,
    required Uint8List? displayBytes,
    required String cacheKey,
    required bool showLoading,
    required bool showError,
  }) {
    if (_selectedTab == _MermaidTab.code ||
        _bitmapRenderingUnsupported ||
        widget.code.trim().isEmpty) {
      return _buildMermaidCodeView(context);
    }

    if (displayBytes != null && displayBytes.isNotEmpty) {
      return Padding(
        key: ValueKey<String>('mermaid-image-$cacheKey'),
        padding: const EdgeInsets.all(8),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _openMermaidImageViewer(context, displayBytes),
            child: Image(
              image: MemoryImage(displayBytes),
              fit: BoxFit.contain,
            ),
          ),
        ),
      );
    }

    if (showLoading) {
      return _MermaidLoadingView(
        key: const ValueKey('mermaid-loading-body'),
        color: palette.textSecondary,
      );
    }

    if (showError) {
      return _MermaidErrorView(
        key: const ValueKey('mermaid-error-body'),
        color: palette.textSecondary,
      );
    }

    return _buildMermaidCodeView(context);
  }

  Widget _buildMermaidCodeView(BuildContext context) {
    return Padding(
      key: const ValueKey('mermaid-code-body'),
      padding: const EdgeInsets.all(12),
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(
          dragDevices: {
            ui.PointerDeviceKind.touch,
            ui.PointerDeviceKind.mouse,
            ui.PointerDeviceKind.stylus,
            ui.PointerDeviceKind.unknown,
          },
        ),
        child: Scrollbar(
          controller: _vMermaidScrollController,
          thumbVisibility: true,
          interactive: true,
          notificationPredicate: (notif) => notif.metrics.axis == Axis.vertical,
          child: SingleChildScrollView(
            controller: _vMermaidScrollController,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SelectableHighlightView(
                widget.code,
                language: 'plaintext',
                theme: MarkdownWithCodeHighlight._transparentBgTheme(
                  Theme.of(context).brightness == Brightness.dark
                      ? atomOneDarkReasonableTheme
                      : githubTheme,
                ),
                padding: EdgeInsets.zero,
                textStyle: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _scheduleBitmapRender({
    required bool isDark,
    required Map<String, String> themeVars,
  }) {
    if (_renderQueued || _renderingBitmap) return;
    _renderQueued = true;
    _renderDebounce?.cancel();
    _renderDebounce = Timer(_settledBitmapRenderDelay, () {
      _renderQueued = false;
      if (!mounted) return;
      _renderBitmap(isDark: isDark, themeVars: themeVars);
    });
  }

  Future<void> _renderBitmap({
    required bool isDark,
    required Map<String, String> themeVars,
  }) async {
    final code = widget.code;
    final cacheKey = _mermaidCacheKey(code, isDark, themeVars);
    if (MermaidImageCache.get(cacheKey) != null) return;
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) {
      _markBitmapRenderingUnsupported(cacheKey);
      return;
    }
    if (!mounted) return;
    setState(() {
      _renderKey = cacheKey;
      _renderingBitmap = true;
    });

    MermaidBitmapRenderResult result = MermaidBitmapRenderResult.failed();
    try {
      result = await _renderMermaidBitmapWithOverlay(
        overlay,
        code,
        isDark,
        themeVars,
      );
      if (!mounted || _renderKey != cacheKey) return;
      final bytes = result.bytes;
      if (result.status == MermaidBitmapRenderStatus.success &&
          bytes != null &&
          bytes.isNotEmpty) {
        MermaidImageCache.put(cacheKey, bytes);
        // Also keep the raw-code entry so export paths keyed by code find it.
        MermaidImageCache.put(code, bytes);
        _failedBitmapRenderKeys.remove(cacheKey);
      }
    } catch (e, st) {
      debugPrint('Mermaid bitmap render failed: $e\n$st');
    } finally {
      if (mounted && _renderKey == cacheKey) {
        _removeRenderOverlay();
        setState(() {
          if (result.status == MermaidBitmapRenderStatus.success &&
              result.bytes != null &&
              result.bytes!.isNotEmpty) {
            _lastRenderedBytes = result.bytes;
          } else if (result.status == MermaidBitmapRenderStatus.unsupported) {
            _bitmapRenderingUnsupported = true;
            _suppressBitmapLoading = true;
          } else {
            _failedBitmapRenderKeys.add(cacheKey);
            _suppressBitmapLoading = true;
          }
          _renderingBitmap = false;
        });
      }
    }
  }

  Future<MermaidBitmapRenderResult> _renderMermaidBitmapWithOverlay(
    OverlayState overlay,
    String code,
    bool isDark,
    Map<String, String> themeVars,
  ) async {
    _removeRenderOverlay();
    final renderKey = GlobalKey();
    final handle = createMermaidView(
      code,
      isDark,
      themeVars: themeVars,
      viewKey: renderKey,
    );
    if (handle == null) return MermaidBitmapRenderResult.unsupported();

    _renderOverlayEntry = OverlayEntry(
      builder: (context) => Positioned(
        left: -10000,
        top: -10000,
        child: ConstrainedBox(
          constraints: const BoxConstraints.tightFor(width: 720, height: 600),
          child: Material(color: Colors.transparent, child: handle.widget),
        ),
      ),
    );
    overlay.insert(_renderOverlayEntry!);

    return _captureMermaidBitmap(handle);
  }

  Future<MermaidBitmapRenderResult> _captureMermaidBitmap(
    MermaidViewHandle handle,
  ) async {
    final exportBytes = handle.exportPngBytes;
    if (exportBytes == null) return MermaidBitmapRenderResult.unsupported();
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 120));
    for (var i = 0; i < 4; i++) {
      try {
        final bytes = await exportBytes().timeout(
          const Duration(milliseconds: 900),
          onTimeout: () => null,
        );
        if (bytes != null && bytes.isNotEmpty) {
          return MermaidBitmapRenderResult.success(bytes);
        }
      } catch (e) {
        if (e is UnsupportedError) {
          return MermaidBitmapRenderResult.unsupported();
        }
        // Mermaid/WebView can report readiness before pixel capture is available.
      }
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    return MermaidBitmapRenderResult.failed();
  }

  void _markBitmapRenderingUnsupported(String cacheKey) {
    if (!mounted) return;
    _renderDebounce?.cancel();
    _removeRenderOverlay();
    setState(() {
      if (_renderKey == null || _renderKey == cacheKey) {
        _renderKey = null;
        _renderQueued = false;
        _renderingBitmap = false;
      }
      _bitmapRenderingUnsupported = true;
    });
  }

  void _removeRenderOverlay() {
    try {
      _renderOverlayEntry?.remove();
    } catch (_) {}
    _renderOverlayEntry = null;
  }

  void _openMermaidImageViewer(BuildContext context, Uint8List bytes) {
    final src = 'data:image/png;base64,${base64Encode(bytes)}';
    Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => ImageViewerPage(images: [src]),
        transitionDuration: const Duration(milliseconds: 300),
        reverseTransitionDuration: const Duration(milliseconds: 240),
        transitionsBuilder: (context, anim, sec, child) {
          final curved = CurvedAnimation(
            parent: anim,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          return FadeTransition(opacity: curved, child: child);
        },
      ),
    );
  }

  Future<void> _saveMermaidBytes(BuildContext context, Uint8List bytes) async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await _saveMermaidPngToDisk(bytes);
    if (!context.mounted) return;
    if (!ok) {
      showAppSnackBar(
        context,
        message: l10n.mermaidExportFailed,
        type: NotificationType.error,
      );
    } else if (Platform.isAndroid || Platform.isIOS) {
      showAppSnackBar(
        context,
        message: l10n.imageViewerPageSaveSuccess,
        type: NotificationType.success,
      );
    }
  }

  Future<bool> _saveMermaidPngToDisk(Uint8List bytes) async {
    try {
      final l10n = AppLocalizations.of(context)!;
      final suggested = 'mermaid_${DateTime.now().millisecondsSinceEpoch}.png';
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        final savePath = await FilePicker.platform.saveFile(
          dialogTitle: l10n.backupPageExportToFile,
          fileName: suggested,
          type: FileType.custom,
          allowedExtensions: const ['png'],
        );
        if (savePath == null || savePath.isEmpty) return false;
        await File(savePath).parent.create(recursive: true);
        await File(savePath).writeAsBytes(bytes);
        return true;
      }
      final result = await ImageGallerySaverPlus.saveImage(
        bytes,
        quality: 100,
        name: 'mermaid-${DateTime.now().millisecondsSinceEpoch}',
      );
      if (result is Map) {
        final isSuccess = result['isSuccess'] == true || result['isSuccess'] == 1;
        final filePath = result['filePath'] ?? result['file_path'];
        return isSuccess || (filePath is String && filePath.isNotEmpty);
      }
    } catch (_) {}
    return false;
  }
}

class _MermaidTabPalette {
  const _MermaidTabPalette({
    required this.track,
    required this.selected,
    required this.textPrimary,
    required this.textSecondary,
  });

  final Color track;
  final Color selected;
  final Color textPrimary;
  final Color textSecondary;
}

class _MermaidTabButton extends StatefulWidget {
  const _MermaidTabButton({
    required this.label,
    required this.selected,
    required this.palette,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final _MermaidTabPalette palette;
  final VoidCallback onTap;

  @override
  State<_MermaidTabButton> createState() => _MermaidTabButtonState();
}

class _MermaidTabButtonState extends State<_MermaidTabButton> {
  bool _pressed = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final baseColor = widget.selected
        ? widget.palette.selected
        : Colors.transparent;
    final hoverColor = Color.alphaBlend(
      widget.palette.textPrimary.withValues(alpha: _pressed ? 0.10 : 0.06),
      baseColor,
    );
    final bg = widget.selected || _pressed || _hovered
        ? hoverColor
        : Colors.transparent;

    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.label,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() {
          _hovered = false;
          _pressed = false;
        }),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapCancel: () => setState(() => _pressed = false),
          onTapUp: (_) => setState(() => _pressed = false),
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(6),
            ),
            child: SelectionContainer.disabled(
              child: Text(
                widget.label,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.35,
                  fontWeight: widget.selected
                      ? AppFontWeights.semibold
                      : AppFontWeights.medium,
                  color: widget.selected
                      ? widget.palette.textPrimary
                      : widget.palette.textSecondary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MermaidLoadingView extends StatelessWidget {
  const _MermaidLoadingView({super.key, required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(strokeWidth: 2, color: color),
      ),
    );
  }
}

class _MermaidErrorView extends StatelessWidget {
  const _MermaidErrorView({super.key, required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Center(child: Icon(Lucide.ImageOff, size: 48, color: color));
  }
}


// Full-width horizontal rule with softer color
class SoftHrLine extends BlockMd {
  @override
  String get expString => (r"^\s*(?:-{3,}|⸻)\s*$");

  @override
  Widget build(BuildContext context, String text, GptMarkdownConfig config) {
    final cs = Theme.of(context).colorScheme;
    final color = cs.outlineVariant.withOpacity(0.4);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Container(
        width: double.infinity,
        height: 1,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(1),
        ),
      ),
    );
  }
}

// Robust fenced code block that takes precedence over other blocks
// ---------------------------------------------------------------------------
// Boundary-aware inline dollar math scanning + escape-aware table splitting
// (kelivo v1.1.15/v1.1.16 port)
// ---------------------------------------------------------------------------

/// Hard cap on inline math body length: scanning for the closing `$` is
/// bounded so pathological long `$...$` spans never stall the UI thread.
const int _maxInlineMathBodyLength = 512;

/// Converts inline `$...$` math into `\(...\)` with boundary-aware scanning:
/// `$` may open only next to whitespace / ASCII punctuation / Unicode
/// punctuation / CJK text, closes only at a valid boundary, never crosses a
/// newline, respects backslash escapes, skips `$$...$$`, and leaves
/// pipe-containing bodies alone outside table rows (those are handled
/// per-cell by [EscapeAwareTableMd]).
String _replaceInlineDollarMath(String input) {
  final buf = StringBuffer();
  var i = 0;
  var previousDollarWasInlineClose = false;
  while (i < input.length) {
    if (input.codeUnitAt(i) == 0x24 && // '$'
        !_isEscaped(input, i) &&
        _canOpenDollarMath(
          input,
          i,
          allowAdjacentOpen: previousDollarWasInlineClose,
        )) {
      final close = _findClosingDollarMath(input, i + 1);
      if (close != -1) {
        final body = input.substring(i + 1, close);
        buf
          ..write(r'\(')
          ..write(body)
          ..write(r'\)');
        i = close + 1;
        previousDollarWasInlineClose = true;
        continue;
      }
    }
    buf.writeCharCode(input.codeUnitAt(i));
    previousDollarWasInlineClose = false;
    i++;
  }
  return buf.toString();
}

int _findClosingDollarMath(String input, int start) {
  final end = math.min(input.length, start + _maxInlineMathBodyLength + 1);
  final allowUnescapedPipes = !_isDollarMathOnMarkdownTableRow(
    input,
    start - 1,
  );
  for (var i = start; i < end; i++) {
    final ch = input.codeUnitAt(i);
    if (ch == 0x0A) return -1;
    if (ch == 0x5C) {
      i++;
      continue;
    }
    if (ch != 0x24) continue;

    final body = input.substring(start, i);
    if (_isValidDollarMathBody(
          body,
          allowUnescapedPipes: allowUnescapedPipes,
        ) &&
        _canCloseDollarMath(input, i)) {
      return i;
    }
    return -1;
  }
  return -1;
}

bool _isValidDollarMathBody(String body, {bool allowUnescapedPipes = false}) {
  if (body.isEmpty) return false;
  if (body.length > _maxInlineMathBodyLength) return false;
  if (_isWhitespaceCodeUnit(body.codeUnitAt(0))) return false;
  if (_isWhitespaceCodeUnit(body.codeUnitAt(body.length - 1))) return false;
  return allowUnescapedPipes || !_containsUnescapedPipe(body);
}

bool _isDollarMathOnMarkdownTableRow(String input, int dollarIndex) {
  final lineStart = input.lastIndexOf('\n', dollarIndex);
  final lineEnd = input.indexOf('\n', dollarIndex);
  final start = lineStart == -1 ? 0 : lineStart + 1;
  final end = lineEnd == -1 ? input.length : lineEnd;
  return _looksLikeTableRowStart(input.substring(start, end));
}

bool _looksLikeTableRowStart(String line) {
  return line.trimLeft().startsWith('|');
}

bool _containsUnescapedPipe(String input) {
  for (var i = 0; i < input.length; i++) {
    final ch = input.codeUnitAt(i);
    if (ch == 0x5C) {
      i++;
      continue;
    }
    if (ch == 0x7C) return true;
  }
  return false;
}

bool _canOpenDollarMath(
  String input,
  int index, {
  bool allowAdjacentOpen = false,
}) {
  if (index + 1 >= input.length) return false;
  final next = input.codeUnitAt(index + 1);
  if (!_canStartDollarMathBody(next)) return false;
  if (index == 0) return true;
  final prev = input.codeUnitAt(index - 1);
  if (prev == 0x24) {
    return allowAdjacentOpen && _canStartAdjacentDollarMathBody(next);
  }
  return _isWhitespaceCodeUnit(prev) || _isDollarMathBoundary(prev);
}

bool _canCloseDollarMath(String input, int index) {
  if (index == 0 || _isWhitespaceCodeUnit(input.codeUnitAt(index - 1))) {
    return false;
  }
  final nextIndex = index + 1;
  if (nextIndex >= input.length) return true;
  final next = input.codeUnitAt(nextIndex);
  if (next == 0x24) return true;
  return next != 0x24 &&
      (_isWhitespaceCodeUnit(next) || _isDollarMathBoundary(next));
}

bool _isDollarMathBoundary(int codeUnit) {
  return _isAsciiPunctuation(codeUnit) ||
      _isUnicodePunctuation(codeUnit) ||
      _isCjkCodeUnit(codeUnit);
}

bool _canStartDollarMathBody(int codeUnit) {
  if (_isWhitespaceCodeUnit(codeUnit) || codeUnit == 0x24) return false;
  if (_isAsciiLetterOrDigit(codeUnit) || codeUnit == 0x5C) return true;
  if (codeUnit == 0x28 || codeUnit == 0x5B || codeUnit == 0x7B) return true;
  if (codeUnit == 0x2B || codeUnit == 0x2D) return true;
  if (codeUnit == 0x7C) return true; // |
  return !_isClosingOrSentencePunctuation(codeUnit);
}

bool _canStartAdjacentDollarMathBody(int codeUnit) {
  if (_isAsciiLetterOrDigit(codeUnit) || codeUnit == 0x5C) return true;
  if (codeUnit == 0x28 || codeUnit == 0x5B || codeUnit == 0x7B) return true;
  return codeUnit == 0x2B ||
      codeUnit == 0x2D ||
      codeUnit == 0x2A ||
      codeUnit == 0x2F ||
      codeUnit == 0x3C ||
      codeUnit == 0x3D ||
      codeUnit == 0x3E ||
      codeUnit == 0x5E ||
      codeUnit == 0x5F ||
      codeUnit == 0x7C;
}

bool _isEscaped(String input, int index) {
  var backslashes = 0;
  for (var i = index - 1; i >= 0 && input.codeUnitAt(i) == 0x5C; i--) {
    backslashes++;
  }
  return backslashes.isOdd;
}

bool _isWhitespaceCodeUnit(int codeUnit) {
  return codeUnit == 0x20 ||
      codeUnit == 0x09 ||
      codeUnit == 0x0A ||
      codeUnit == 0x0D;
}

bool _isAsciiDigit(int codeUnit) {
  return codeUnit >= 0x30 && codeUnit <= 0x39;
}

bool _isAsciiLetterOrDigit(int codeUnit) {
  return _isAsciiDigit(codeUnit) ||
      (codeUnit >= 0x41 && codeUnit <= 0x5A) ||
      (codeUnit >= 0x61 && codeUnit <= 0x7A);
}

bool _isAsciiPunctuation(int codeUnit) {
  return (codeUnit >= 0x21 && codeUnit <= 0x2F) ||
      (codeUnit >= 0x3A && codeUnit <= 0x40) ||
      (codeUnit >= 0x5B && codeUnit <= 0x60) ||
      (codeUnit >= 0x7B && codeUnit <= 0x7E);
}

bool _isUnicodePunctuation(int codeUnit) {
  return (codeUnit >= 0x2000 && codeUnit <= 0x206F) ||
      (codeUnit >= 0x3000 && codeUnit <= 0x303F) ||
      (codeUnit >= 0xFE10 && codeUnit <= 0xFE1F) ||
      (codeUnit >= 0xFE30 && codeUnit <= 0xFE4F) ||
      (codeUnit >= 0xFF01 && codeUnit <= 0xFF0F) ||
      (codeUnit >= 0xFF1A && codeUnit <= 0xFF20) ||
      (codeUnit >= 0xFF3B && codeUnit <= 0xFF40) ||
      (codeUnit >= 0xFF5B && codeUnit <= 0xFF65);
}

bool _isCjkCodeUnit(int codeUnit) {
  return (codeUnit >= 0x3400 && codeUnit <= 0x4DBF) ||
      (codeUnit >= 0x4E00 && codeUnit <= 0x9FFF) ||
      (codeUnit >= 0xF900 && codeUnit <= 0xFAFF);
}

bool _isClosingOrSentencePunctuation(int codeUnit) {
  return codeUnit == 0x21 ||
      codeUnit == 0x22 ||
      codeUnit == 0x27 ||
      codeUnit == 0x29 ||
      codeUnit == 0x2C ||
      codeUnit == 0x2E ||
      codeUnit == 0x3A ||
      codeUnit == 0x3B ||
      codeUnit == 0x3F ||
      codeUnit == 0x5D ||
      codeUnit == 0x7D ||
      _isUnicodePunctuation(codeUnit);
}

// ---------------------------------------------------------------------------
// Markdown table toolbar (styled to match code block headers; desktop and
// mobile both show it, with CSV download and copy actions)
// ---------------------------------------------------------------------------

/// Wraps a rendered markdown table with its toolbar (copy/download CSV
/// actions), matching the code block header and container style.
Widget _wrapTableWithToolbar(
  BuildContext ctx,
  List<CustomTableRow> rows,
  Color headerBg,
  Widget table,
) {
  final cs = Theme.of(ctx).colorScheme;
  return Container(
    width: double.infinity,
    margin: const EdgeInsets.symmetric(vertical: 6),
    decoration: BoxDecoration(
      color: cs.surface,
      borderRadius: BorderRadius.circular(12),
    ),
    clipBehavior: Clip.antiAlias,
    foregroundDecoration: BoxDecoration(
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: cs.outlineVariant.withOpacity(0.2)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _MarkdownTableToolbar(
          backgroundColor: headerBg,
          onCopy: () => _copyTableMarkdown(ctx, rows),
          onExport: () => _exportTableCsv(ctx, rows),
        ),
        table,
      ],
    ),
  );
}

class _MarkdownTableToolbar extends StatelessWidget {
  const _MarkdownTableToolbar({
    required this.backgroundColor,
    required this.onCopy,
    required this.onExport,
  });

  final Color backgroundColor;
  final VoidCallback onCopy;
  final VoidCallback onExport;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final l10n = AppLocalizations.of(context)!;

    return Material(
      color: backgroundColor,
      elevation: 0,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: cs.outlineVariant.withOpacity(isDark ? 0.22 : 0.28),
              width: 1.0,
            ),
          ),
        ),
        child: Row(
          children: [
            const Spacer(),
            CodeBlockDownloadButton(onTap: onExport),
            const SizedBox(width: 6),
            InkWell(
              onTap: onCopy,
              splashColor: Platform.isIOS ? Colors.transparent : null,
              highlightColor: Platform.isIOS ? Colors.transparent : null,
              hoverColor: Platform.isIOS ? Colors.transparent : null,
              overlayColor: Platform.isIOS
                  ? const MaterialStatePropertyAll(Colors.transparent)
                  : null,
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Lucide.Copy,
                      size: 14,
                      color: cs.onSurface.withOpacity(0.6),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      l10n.shareProviderSheetCopyButton,
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurface.withOpacity(0.6),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Rebuilds a markdown table (including the `---` separator row) from the
/// parsed rows so it can be copied or exported as a `.md` file.
String _rowsToMarkdown(List<CustomTableRow> rows) {
  if (rows.isEmpty) return '';
  var columnCount = 0;
  for (final r in rows) {
    if (r.fields.length > columnCount) columnCount = r.fields.length;
  }
  if (columnCount == 0) return '';

  String cellText(String value) => value
      .trim()
      .replaceAll('\\', r'\\')
      .replaceAll('|', r'\|')
      .replaceAll('\r\n', '<br>')
      .replaceAll('\n', '<br>')
      .replaceAll('\r', '<br>');

  String line(List<String> cells) => '| ${cells.join(' | ')} |';

  final buffer = StringBuffer();
  buffer.writeln(
    line(
      List.generate(
        columnCount,
        (i) => i < rows.first.fields.length
            ? cellText(rows.first.fields[i].data)
            : '',
      ),
    ),
  );
  buffer.writeln(line(List.filled(columnCount, '---')));
  for (final r in rows.skip(1)) {
    buffer.writeln(
      line(
        List.generate(
          columnCount,
          (i) =>
              i < r.fields.length ? cellText(r.fields[i].data) : '',
        ),
      ),
    );
  }
  return buffer.toString().trimRight();
}

Future<void> _copyTableMarkdown(
  BuildContext ctx,
  List<CustomTableRow> rows,
) async {
  await Clipboard.setData(ClipboardData(text: _rowsToMarkdown(rows)));
  if (!ctx.mounted) return;
  showAppSnackBar(
    ctx,
    message: AppLocalizations.of(ctx)!.chatMessageWidgetCopiedToClipboard,
    type: NotificationType.success,
  );
}

Future<void> _exportTableCsv(
  BuildContext ctx,
  List<CustomTableRow> rows,
) async {
  await saveCodeBlockToFile(
    ctx,
    _rowsToCsv(rows),
    'csv',
    filename: 'omnichat-table-${DateTime.now().millisecondsSinceEpoch}.csv',
  );
}

/// Converts parsed table rows to standard RFC 4180 CSV format.
String _rowsToCsv(List<CustomTableRow> rows) {
  if (rows.isEmpty) return '';
  var columnCount = 0;
  for (final r in rows) {
    if (r.fields.length > columnCount) columnCount = r.fields.length;
  }
  if (columnCount == 0) return '';

  String escapeCsvCell(String value) {
    var text = value.trim();
    text = text.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
    if (text.contains('"') ||
        text.contains(',') ||
        text.contains('\n') ||
        text.contains('\r')) {
      return '"${text.replaceAll('"', '""')}"';
    }
    return text;
  }

  final buffer = StringBuffer();
  for (final r in rows) {
    final cells = List.generate(
      columnCount,
      (i) => i < r.fields.length ? escapeCsvCell(r.fields[i].data) : '',
    );
    buffer.writeln(cells.join(','));
  }
  return buffer.toString().trimRight();
}

/// Table block that splits cells with math/escape awareness so `|` inside
/// `$...$`, `\(...\)` or `\|` spans is not treated as a column separator.
class EscapeAwareTableMd extends TableMd {
  @override
  Widget build(BuildContext context, String text, GptMarkdownConfig config) {
    final value = text
        .trim()
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .map<Map<int, String>>(
          (line) => _splitMarkdownTableLine(line.trim()).asMap(),
        )
        .toList();

    if (value.isEmpty) return Text('', style: config.style);

    final hasHeader = value.length >= 2;
    final columnAlignments = <TextAlign>[];

    if (hasHeader) {
      final separatorRow = value[1];
      for (var index = 0; index < separatorRow.length; index++) {
        final separator = (separatorRow[index] ?? '').trim();
        final hasLeftColon = separator.startsWith(':');
        final hasRightColon = separator.endsWith(':');

        if (hasLeftColon && hasRightColon) {
          columnAlignments.add(TextAlign.center);
        } else if (hasRightColon) {
          columnAlignments.add(TextAlign.right);
        } else {
          columnAlignments.add(TextAlign.left);
        }
      }
    }

    var maxCol = 0;
    for (final row in value) {
      if (maxCol < row.length) maxCol = row.length;
    }
    if (maxCol == 0) return Text('', style: config.style);

    while (columnAlignments.length < maxCol) {
      columnAlignments.add(TextAlign.left);
    }

    final tableBuilder = config.tableBuilder;
    if (tableBuilder == null) {
      return super.build(context, text, config);
    }

    final customTable = List<CustomTableRow?>.generate(value.length, (
      rowIndex,
    ) {
      if (hasHeader && rowIndex == 1) return null;
      final row = value[rowIndex];
      if (row.isEmpty) return null;

      final fields = List<CustomTableField>.generate(maxCol, (fieldIndex) {
        return CustomTableField(
          data: row[fieldIndex] ?? '',
          alignment: columnAlignments[fieldIndex],
        );
      });
      return CustomTableRow(isHeader: rowIndex == 0, fields: fields);
    }).nonNulls.toList();

    return tableBuilder(
      context,
      customTable,
      config.style ?? const TextStyle(),
      config,
    );
  }
}

List<String> _splitMarkdownTableLine(String line) {
  var trimmed = line.trim();
  if (trimmed.startsWith('|')) trimmed = trimmed.substring(1);
  if (trimmed.endsWith('|') && !_isEscaped(trimmed, trimmed.length - 1)) {
    trimmed = trimmed.substring(0, trimmed.length - 1);
  }

  final cells = <String>[];
  final cell = StringBuffer();
  var dollarMathEnd = -1;
  var parenMathEnd = -1;

  for (var i = 0; i < trimmed.length; i++) {
    final ch = trimmed.codeUnitAt(i);

    if (i > dollarMathEnd && i > parenMathEnd) {
      if (ch == 0x24 && !_isEscaped(trimmed, i)) {
        final close = _findClosingDollarMathInTableCell(trimmed, i + 1);
        if (close != -1) dollarMathEnd = close;
      } else if (ch == 0x5C && i + 1 < trimmed.length) {
        final next = trimmed.codeUnitAt(i + 1);
        if (next == 0x28) {
          final close = _findClosingParenMathInTableCell(trimmed, i + 2);
          if (close != -1) parenMathEnd = close + 1;
        }
      }
    }

    if (ch == 0x7C && // '|'
        !_isEscaped(trimmed, i) &&
        i > dollarMathEnd &&
        i > parenMathEnd) {
      cells.add(cell.toString());
      cell.clear();
      continue;
    }

    cell.writeCharCode(ch);
  }
  cells.add(cell.toString());
  return cells;
}

int _findClosingDollarMathInTableCell(String input, int start) {
  final end = math.min(input.length, start + _maxInlineMathBodyLength + 1);
  for (var i = start; i < end; i++) {
    final ch = input.codeUnitAt(i);
    if (ch == 0x0A) return -1;
    if (ch == 0x5C) {
      i++;
      continue;
    }
    if (ch != 0x24) continue;

    final body = input.substring(start, i);
    if (_isValidDollarMathBody(body, allowUnescapedPipes: true) &&
        _canCloseDollarMath(input, i)) {
      return i;
    }
    return -1;
  }
  return -1;
}

int _findClosingParenMathInTableCell(String input, int start) {
  final end = math.min(input.length, start + _maxInlineMathBodyLength + 2);
  for (var i = start; i < end - 1; i++) {
    final ch = input.codeUnitAt(i);
    if (ch == 0x0A) return -1;
    if (ch == 0x5C && input.codeUnitAt(i + 1) == 0x29) return i;
  }
  return -1;
}

class FencedCodeBlockMd extends BlockMd {
  FencedCodeBlockMd({this.isStreaming = false});

  // When true, the owning message is actively streaming. Mermaid/PlantUML
  // (WebView2-backed) blocks are deferred to a pure-Dart collapsible code block
  // to avoid init/dispose races amplified by per-chunk markdown rebuild storms.
  final bool isStreaming;

  @override
  // Match ```lang\n...\n``` at line starts. Non-greedy to stop at first closing fence.
  String get expString => (r"^\s*```([^\n`]*)\s*\n([\s\S]*?)\n```$");

  @override
  Widget build(BuildContext context, String text, GptMarkdownConfig config) {
    final m = exp.firstMatch(text);
    if (m == null) return const SizedBox.shrink();
    final lang = (m.group(1) ?? '').trim();
    // Restore $ and <details>/<summary masks from preprocessFences so code
    // content renders literally.
    final code = MarkdownWithCodeHighlight.unmaskFencedHtmlTagStarts(
      MarkdownWithCodeHighlight.unmaskCodeDollars(m.group(2) ?? ''),
    );
    final langLower = lang.toLowerCase();
    if ((langLower == 'mermaid' || langLower == 'plantuml') && isStreaming) {
      return _CollapsibleCodeBlock(language: lang, code: code);
    }
    if (langLower == 'mermaid') {
      return _MermaidBlock(code: code);
    } else if (langLower == 'plantuml') {
      return PlantUMLBlock(code: code);
    }
    return _CollapsibleCodeBlock(language: lang, code: code);
  }
}

/// Scrollable LaTeX block to prevent overflow when equations are very wide
class LatexBlockScrollableMd extends BlockMd {
  @override
  // Match either $$...$$ or \[...\] as standalone block
  String get expString =>
      (r"^(?:\s*\$\$([\s\S]*?)\$\$\s*|\s*\\\[([\s\S]*?)\\\]\s*)$");

  @override
  Widget build(BuildContext context, String text, GptMarkdownConfig config) {
    final m = exp.firstMatch(text.trim());
    if (m == null) return const SizedBox.shrink();
    final body = ((m.group(1) ?? m.group(2) ?? '')).trim();
    if (body.isEmpty) return const SizedBox.shrink();

    final math = MarkdownWithCodeHighlight._renderMath(
      body,
      style: config.style,
      mathStyle: MathStyle.display,
    );
    // Wrap in horizontal scroll to avoid overflow and center within available width
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SelectionContainer.disabled(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              primary: false,
              child: ConstrainedBox(
                constraints: BoxConstraints(minWidth: constraints.maxWidth),
                child: Center(child: math),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Inline LaTeX `$...$` rendered in a horizontally scrollable bubble to avoid line overflow
class InlineLatexScrollableMd extends InlineMd {
  @override
  // Match single-dollar $...$ or \(...\) inline math (avoid $$ block)
  RegExp get exp =>
      RegExp(r"(?:(?<!\$)\$([^\$\n]+?)\$(?!\$)|\\\(([^\n]+?)\\\))");

  @override
  InlineSpan span(BuildContext context, String text, GptMarkdownConfig config) {
    final m = exp.firstMatch(text);
    if (m == null) return TextSpan(text: text, style: config.style);
    final body = ((m.group(1) ?? m.group(2) ?? '')).trim();
    if (body.isEmpty) return TextSpan(text: text, style: config.style);
    final math = MarkdownWithCodeHighlight._renderMath(
      body,
      mathStyle: MathStyle.text,
      style: () {
        final base = (config.style ?? const TextStyle());
        final baseSize = base.fontSize ?? 15.5;
        // Slightly enlarge inline math for readability
        return base.copyWith(fontSize: baseSize * 1.2);
      }(),
    );
    // Wrap in horizontal scroll to prevent line overflow; no extra background
    final w = LayoutBuilder(
      builder: (context, constraints) {
        return SelectionContainer.disabled(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            primary: false,
            child: math,
          ),
        );
      },
    );

    return WidgetSpan(
      alignment: PlaceholderAlignment.baseline,
      baseline: TextBaseline.alphabetic,
      child: w,
    );
  }
}

/// Inline LaTeX for dollar delimiters only: `$...$`
class InlineLatexDollarScrollableMd extends InlineMd {
  // Boundary-aware render-time fallback (kelivo v1.1.16 port): `$` must be
  // preceded by start/space/tab/newline/(, be unescaped, have a body capped at
  // 512 chars, and close before a non-alphanumeric boundary. This prevents
  // currency spans like "$5 and total is $10" and "abc$x$" from being parsed
  // as math even when the preprocess scanner left them untouched. Raw `|` is
  // allowed in the body so table-cell math (split by EscapeAwareTableMd) still
  // renders.
  @override
  RegExp get exp => RegExp(
    r"(^|[ \t\r\n(])(?<!\\)(?<!\$)\$((?:\\.|[^\$\\\n]){1,"
    "$_maxInlineMathBodyLength"
    r"})\$(?!\$)(?![A-Za-z0-9])",
  );

  @override
  InlineSpan span(BuildContext context, String text, GptMarkdownConfig config) {
    final m = exp.firstMatch(text);
    if (m == null) return TextSpan(text: text, style: config.style);
    final prefix = m.group(1) ?? '';
    final body = (m.group(2) ?? '').trim();
    if (body.isEmpty) return TextSpan(text: text, style: config.style);
    // Reject empty / over-length / edge-whitespace bodies (regex already caps
    // length; this adds leading/trailing whitespace checks). Pipes are allowed
    // so per-cell table math keeps working.
    if (!_isValidDollarMathBody(
      m.group(2) ?? '',
      allowUnescapedPipes: true,
    )) {
      return TextSpan(text: text, style: config.style);
    }
    final math = MarkdownWithCodeHighlight._renderMath(
      body,
      mathStyle: MathStyle.text,
      style: () {
        final base = (config.style ?? const TextStyle());
        final baseSize = base.fontSize ?? 15.5;
        return base.copyWith(fontSize: baseSize * 1.2);
      }(),
    );
    final w = LayoutBuilder(
      builder: (context, constraints) {
        return SelectionContainer.disabled(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            primary: false,
            child: math,
          ),
        );
      },
    );
    return TextSpan(
      style: config.style,
      children: [
        if (prefix.isNotEmpty) TextSpan(text: prefix, style: config.style),
        WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: w,
        ),
      ],
    );
  }
}

/// Inline LaTeX for parenthesis delimiters only: `\(...\)`
class InlineLatexParenScrollableMd extends InlineMd {
  @override
  RegExp get exp => RegExp(
    r"(?:\\\(([^\n]{1,"
    "$_maxInlineMathBodyLength"
    r"}?)\\\))",
  );

  @override
  InlineSpan span(BuildContext context, String text, GptMarkdownConfig config) {
    final m = exp.firstMatch(text);
    if (m == null) return TextSpan(text: text, style: config.style);
    final body = (m.group(1) ?? '').trim();
    if (body.isEmpty) return TextSpan(text: text, style: config.style);
    final math = MarkdownWithCodeHighlight._renderMath(
      body,
      mathStyle: MathStyle.text,
      style: () {
        final base = (config.style ?? const TextStyle());
        final baseSize = base.fontSize ?? 15.5;
        return base.copyWith(fontSize: baseSize * 1.2);
      }(),
    );
    final w = LayoutBuilder(
      builder: (context, constraints) {
        return SelectionContainer.disabled(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            primary: false,
            child: math,
          ),
        );
      },
    );
    return WidgetSpan(
      alignment: PlaceholderAlignment.baseline,
      baseline: TextBaseline.alphabetic,
      child: w,
    );
  }
}

// Balanced ATX-style headings (#, ##, ###, …) with consistent spacing and typography
/// Block renderer for HTML `<details>/<summary>` collapsible sections, with
/// nested details support (depth 6) and `open` attribute handling (kelivo
/// v1.1.13 port).
class DetailsHtmlMd extends BlockMd {
  @override
  RegExp get exp => RegExp(
    r'^\ *?(?:' + expString + r")$",
    dotAll: true,
    multiLine: true,
    caseSensitive: false,
  );

  @override
  String get expString => _detailsPattern(6);

  @override
  Widget build(BuildContext context, String text, GptMarkdownConfig config) {
    final match = RegExp(
      r"^<details(?<attrs>[^>]*)>\s*<summary(?:\s+[^>]*)?>(?<summary>[\s\S]*?)<\/summary>(?<body>[\s\S]*)<\/details>$",
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(text.trim());

    if (match == null) {
      return config.getRich(TextSpan(text: text, style: config.style));
    }

    final attrs = match.namedGroup('attrs') ?? '';
    final summary = _plainHtmlText(match.namedGroup('summary') ?? '').trim();
    final body = (match.namedGroup('body') ?? '').trim();
    final initiallyExpanded = RegExp(
      r"(?:^|\s)open(?:\s|$|=)",
      caseSensitive: false,
    ).hasMatch(attrs);

    return _DetailsHtmlBlock(
      summary: summary,
      body: body,
      initiallyExpanded: initiallyExpanded,
      config: config,
    );
  }

  static String _detailsPattern(int depth) {
    final open = r"<details(?:\s+[^>]*)?>";
    final summary = r"\s*<summary(?:\s+[^>]*)?>[\s\S]*?<\/summary>";
    if (depth <= 1) {
      return '$open$summary(?:(?!<details\\b|<\\/details>)[\\s\\S])*<\\/details>';
    }
    final nested = _detailsPattern(depth - 1);
    return '$open$summary(?:(?!<details\\b|<\\/details>)[\\s\\S]|$nested)*<\\/details>';
  }

  static String _plainHtmlText(String input) {
    return input
        .replaceAll(RegExp(r"<br\s*/?>", caseSensitive: false), '\n')
        .replaceAll(RegExp(r"<[^>]+>"), '')
        .trim();
  }
}

class _DetailsHtmlBlock extends StatefulWidget {
  const _DetailsHtmlBlock({
    required this.summary,
    required this.body,
    required this.initiallyExpanded,
    required this.config,
  });

  final String summary;
  final String body;
  final bool initiallyExpanded;
  final GptMarkdownConfig config;

  @override
  State<_DetailsHtmlBlock> createState() => _DetailsHtmlBlockState();
}

class _DetailsHtmlBlockState extends State<_DetailsHtmlBlock> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surface = Color.alphaBlend(
      cs.onSurface.withValues(alpha: isDark ? 0.05 : 0.025),
      cs.surface,
    );
    final borderColor = cs.outlineVariant.withValues(
      alpha: isDark ? 0.18 : 0.30,
    );
    final summaryStyle = (widget.config.style ?? const TextStyle()).copyWith(
      color: cs.onSurface,
      fontWeight: FontWeight.w500,
    );
    final bodyStyle = (widget.config.style ?? const TextStyle()).copyWith(
      color: cs.onSurface,
    );
    final bodyConfig = widget.config.copyWith(style: bodyStyle);

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor, width: 0.8),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          IosCardPress(
            onTap: () => setState(() => _expanded = !_expanded),
            baseColor: Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            haptics: false,
            child: Row(
              children: [
                AnimatedRotation(
                  turns: _expanded ? 0.25 : 0.0,
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOutCubic,
                  child: Icon(
                    Lucide.ChevronRight,
                    size: 15,
                    color: cs.onSurfaceVariant.withValues(alpha: 0.78),
                  ),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    widget.summary,
                    style: summaryStyle,
                    softWrap: true,
                  ),
                ),
              ],
            ),
          ),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            layoutBuilder: (currentChild, previousChildren) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ...previousChildren,
                  if (currentChild != null) currentChild,
                ],
              );
            },
            transitionBuilder: (child, animation) {
              return FadeTransition(
                opacity: animation,
                child: SizeTransition(
                  sizeFactor: animation,
                  alignment: Alignment.topCenter,
                  child: child,
                ),
              );
            },
            child: _expanded && widget.body.isNotEmpty
                ? Container(
                    key: const ValueKey('details-expanded'),
                    width: double.infinity,
                    decoration: BoxDecoration(
                      border: Border(
                        top: BorderSide(color: borderColor, width: 0.8),
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                      child: widget.config.getRich(
                        TextSpan(
                          style: bodyStyle,
                          children: MarkdownComponent.generate(
                            context,
                            widget.body,
                            bodyConfig,
                            true,
                          ),
                        ),
                      ),
                    ),
                  )
                : const SizedBox.shrink(key: ValueKey('details-collapsed')),
          ),
        ],
      ),
    );
  }
}

/// Inline renderer for raw HTML `<a href="...">text</a>` anchors (kelivo
/// v1.1.13 port).
class HtmlAnchorMd extends InlineMd {
  @override
  RegExp get exp => RegExp(
    r'''<a\s+[^>]*href\s*=\s*(['"])(.*?)\1[^>]*>([\s\S]*?)<\/a>''',
    caseSensitive: false,
    dotAll: true,
  );

  @override
  InlineSpan span(BuildContext context, String text, GptMarkdownConfig config) {
    final match = exp.firstMatch(text);
    if (match == null) return TextSpan(text: text, style: config.style);

    final url = (match.group(2) ?? '').trim();
    final linkText = _stripTags(match.group(3) ?? '');
    final cs = Theme.of(context).colorScheme;

    return WidgetSpan(
      baseline: TextBaseline.alphabetic,
      alignment: PlaceholderAlignment.baseline,
      child: GestureDetector(
        onTap: url.isEmpty ? null : () => config.onLinkTap?.call(url, linkText),
        child: Text(
          linkText,
          style: (config.style ?? const TextStyle()).copyWith(
            color: cs.primary,
            decoration: TextDecoration.none,
          ),
        ),
      ),
    );
  }

  static String _stripTags(String input) =>
      input.replaceAll(RegExp(r"<[^>]+>"), '').trim();
}

class AtxHeadingMd extends BlockMd {
  @override
  // Restrict heading content to a single line to avoid swallowing
  // subsequent blocks (e.g., fenced code) when the engine builds
  // the regex with dotAll=true. Using [^\n]+ keeps it line-bound.
  String get expString => (r"^\s{0,3}(#{1,6})\s+([^\n]+?)(?:\s+#+\s*)?$");

  @override
  Widget build(BuildContext context, String text, GptMarkdownConfig config) {
    final m = exp.firstMatch(text.trim());
    if (m == null) return const SizedBox.shrink();
    final hashes = m.group(1) ?? '#';
    final raw = (m.group(2) ?? '').trim();
    final lvl = hashes.length;
    final level = lvl < 1 ? 1 : (lvl > 6 ? 6 : lvl);

    final innerCfg = config.copyWith(style: const TextStyle());
    final inner = TextSpan(
      children: MarkdownComponent.generate(context, raw, innerCfg, true),
    );
    final style = _headingTextStyle(context, config, level);
    // Slightly tighter spacing between headings and body
    final top = switch (level) {
      1 => 2.0,
      2 => 2.0,
      _ => 2.0,
    };
    final bottom = switch (level) {
      1 => 2.0,
      2 => 2.0,
      3 => 2.0,
      _ => 2.0,
    };

    return Padding(
      padding: EdgeInsets.only(top: top, bottom: bottom),
      child: DefaultTextStyle.merge(
        // Use selection-aware renderer from config so headings can be selected/copied
        style: style,
        child: config.getRich(inner),
      ),
    );
  }

  TextStyle _headingTextStyle(
    BuildContext ctx,
    GptMarkdownConfig cfg,
    int level,
  ) {
    final t = Theme.of(ctx).textTheme;
    final cs = Theme.of(ctx).colorScheme;
    final isZh = MarkdownWithCodeHighlight._isZh(ctx);
    final settings = ctx.read<SettingsProvider>();
    String? appFamily;
    if ((settings.appFontFamily ?? '').isNotEmpty) {
      appFamily = settings.appFontFamily;
      if (settings.appFontIsGoogle) {
        try {
          final s = GoogleFonts.getFont(appFamily!);
          appFamily = s.fontFamily ?? appFamily;
        } catch (_) {}
      }
    }
    // Start from Material styles but tighten sizes for balance with body text
    TextStyle base;
    // Explicit sizes ensure visible contrast over the body (16.0)
    switch (level) {
      case 1:
        base = const TextStyle(fontSize: 24);
        break;
      case 2:
        base = const TextStyle(fontSize: 20);
        break;
      case 3:
        base = const TextStyle(fontSize: 18);
        break;
      case 4:
        base = const TextStyle(fontSize: 16);
        break;
      case 5:
        base = const TextStyle(fontSize: 15);
        break;
      default:
        base = const TextStyle(fontSize: 14);
    }
    final weight = switch (level) {
      1 => FontWeight.w700,
      2 => FontWeight.w600,
      3 => FontWeight.w600,
      _ => FontWeight.w500,
    };
    final ls = switch (level) {
      1 => isZh ? 0.0 : 0.1,
      2 => isZh ? 0.0 : 0.08,
      _ => isZh ? 0.0 : 0.05,
    };
    final h = switch (level) {
      1 => 1.25,
      2 => 1.3,
      _ => 1.35,
    };
    return base.copyWith(
      fontWeight: weight,
      height: h,
      letterSpacing: ls,
      color: cs.onSurface,
      fontFamily: appFamily,
      fontFamilyFallback: getPlatformFontFallback(),
    );
  }
}

// Setext-style headings (underlines with === or ---)
class SetextHeadingMd extends BlockMd {
  @override
  String get expString => (r"^(.+?)\n(=+|-+)\s*$");

  @override
  Widget build(BuildContext context, String text, GptMarkdownConfig config) {
    final m = exp.firstMatch(text.trimRight());
    if (m == null) return const SizedBox.shrink();
    final title = (m.group(1) ?? '').trim();
    final underline = (m.group(2) ?? '').trim();
    final level = underline.startsWith('=') ? 1 : 2;

    final innerCfg = config.copyWith(style: const TextStyle());
    final inner = TextSpan(
      children: MarkdownComponent.generate(context, title, innerCfg, true),
    );
    final style = AtxHeadingMd()._headingTextStyle(context, config, level);
    // Match the tighter spacing used in ATX headings
    final top = level == 1 ? 10.0 : 9.0;
    final bottom = 6.0;

    return Padding(
      padding: EdgeInsets.only(top: top, bottom: bottom),
      child: DefaultTextStyle.merge(
        // Use selection-aware renderer from config so headings can be selected/copied
        style: style,
        child: config.getRich(inner),
      ),
    );
  }
}

// Label-value strong lines like "**作者:** 张三" should not render as heading-sized text
class LabelValueLineMd extends InlineMd {
  @override
  // Treat this as an inline transform so it only affects the matched
  // line segment and does not interfere with block parsing.
  bool get inline => false;

  @override
  // 同时匹配两种写法：
  // 1) **标签:** 值   （冒号在加粗内）
  // 2) **标签**: 值   （冒号在加粗外）
  // 支持半角/全角冒号
  RegExp get exp =>
      RegExp(r"(?:(?:^|\n)\*\*([^*]+?)\*\*\s*[：:]?\s+(.+)$)", multiLine: true);

  @override
  InlineSpan span(BuildContext context, String text, GptMarkdownConfig config) {
    final match = exp.firstMatch(text);
    if (match == null) return TextSpan(text: text, style: config.style);

    // 提取并规范化标签与值
    var rawLabel = (match.group(1) ?? '').trim();
    final value = (match.group(2) ?? '').trim();
    // 如果标签末尾自带冒号，去掉以避免重复
    rawLabel = rawLabel.replaceFirst(RegExp(r"[：:]+$"), '');

    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    // 继承基础样式，确保字间距/行高一致
    final base =
        (config.style ?? t.bodyMedium ?? const TextStyle(fontSize: 14));
    final labelStyle = base.copyWith(
      fontWeight: FontWeight.w700, // 与 ** 加粗视觉一致
      color: cs.onSurface,
    );
    final valueStyle = base.copyWith(
      fontWeight: FontWeight.w400,
      color: cs.onSurface.withOpacity(0.92),
    );

    // 将值部分继续按 markdown 解析，保证链接/引用等语法正常
    final valueChildren = MarkdownComponent.generate(
      context,
      value,
      config.copyWith(style: valueStyle),
      true,
    );

    // 返回 TextSpan（而非 WidgetSpan）以保证在外层 RichText/SelectionArea 中可选择复制
    return TextSpan(
      children: [
        TextSpan(text: rawLabel, style: labelStyle),
        const TextSpan(text: '： '),
        ...valueChildren,
      ],
    );
  }
}

// Modern, app-styled block quote with soft background and accent border
class ModernBlockQuote extends InlineMd {
  @override
  bool get inline => false;

  @override
  RegExp get exp => RegExp(
    r"^[ \t]*>[^\n]*(?:\n[ \t]*>[^\n]*)*",
    multiLine: true,
  );

  @override
  InlineSpan span(BuildContext context, String text, GptMarkdownConfig config) {
    final match = exp.firstMatch(text);
    final m = match?[0] ?? '';
    final sb = StringBuffer();
    for (final line in m.split('\n')) {
      if (RegExp(r'^\ *>').hasMatch(line)) {
        var sub = line.trimLeft();
        sub = sub.substring(1); // remove '>'
        if (sub.startsWith(' ')) sub = sub.substring(1);
        sb.writeln(sub);
      } else {
        sb.writeln(line);
      }
    }
    final data = sb.toString().trim();
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = cs.primaryContainer.withOpacity(isDark ? 0.18 : 0.12);
    final accent = cs.primary.withOpacity(isDark ? 0.90 : 0.80);

    final inner = TextSpan(
      children: MarkdownComponent.generate(context, data, config, true),
    );
    final child = Directionality(
      textDirection: config.textDirection,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
          border: Border(left: BorderSide(color: accent, width: 3)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          child: config.getRich(inner),
        ),
      ),
    );

    return WidgetSpan(
      alignment: PlaceholderAlignment.baseline,
      baseline: TextBaseline.alphabetic,
      child: child,
    );
  }
}

// Modern task checkbox: square with subtle border, primary check on done
class ModernCheckBoxMd extends BlockMd {
  @override
  String get expString => (r"\[((?:\x|\ ))\]\ (\S[^\n]*?)$");

  @override
  Widget build(BuildContext context, String text, GptMarkdownConfig config) {
    final match = exp.firstMatch(text.trim());
    final checked = (match?[1] == 'x');
    final content = match?[2] ?? '';
    final cs = Theme.of(context).colorScheme;

    final contentStyle = (config.style ?? const TextStyle()).copyWith(
      decoration: checked ? TextDecoration.lineThrough : null,
      color: (config.style?.color ?? cs.onSurface).withOpacity(
        checked ? 0.75 : 1.0,
      ),
    );

    final child = MdWidget(
      context,
      content,
      false,
      config: config.copyWith(style: contentStyle),
    );

    return Directionality(
      textDirection: config.textDirection,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        textBaseline: TextBaseline.alphabetic,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 6, end: 8),
            child: Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(5),
                border: Border.all(
                  color: cs.outlineVariant.withOpacity(0.8),
                  width: 1,
                ),
                color: checked
                    ? cs.primary.withOpacity(0.12)
                    : Colors.transparent,
              ),
              child: checked
                  ? Icon(Icons.check, size: 14, color: cs.primary)
                  : null,
            ),
          ),
          Flexible(child: child),
        ],
      ),
    );
  }
}

// Modern radio (optional): circle with primary dot when selected
class ModernRadioMd extends BlockMd {
  @override
  String get expString => (r"\(((?:\x|\ ))\)\ (\S[^\n]*)$");

  @override
  Widget build(BuildContext context, String text, GptMarkdownConfig config) {
    final match = exp.firstMatch(text.trim());
    final selected = (match?[1] == 'x');
    final content = match?[2] ?? '';
    final cs = Theme.of(context).colorScheme;

    final contentStyle = (config.style ?? const TextStyle()).copyWith(
      color: (config.style?.color ?? cs.onSurface).withOpacity(
        selected ? 0.95 : 1.0,
      ),
    );

    final child = MdWidget(
      context,
      content,
      false,
      config: config.copyWith(style: contentStyle),
    );

    return Directionality(
      textDirection: config.textDirection,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        textBaseline: TextBaseline.alphabetic,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 6, end: 8),
            child: Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: cs.outlineVariant.withOpacity(0.8),
                  width: 1,
                ),
              ),
              child: selected
                  ? Center(
                      child: Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: cs.primary,
                          shape: BoxShape.circle,
                        ),
                      ),
                    )
                  : null,
            ),
          ),
          Flexible(child: child),
        ],
      ),
    );
  }
}

// Prevent link regex from spanning across lines (dotAll=true in engine).
class LineSafeLinkMd extends ATagMd {
  @override
  RegExp get exp => RegExp(r"(?<!\!)\[[^\]\n]+\]\([^\s]*\)");
}

/// Treat backslash-escaped punctuation as a literal character, so that
/// sequences like `\*text\*`, `\`code\``, `\[label\]`, and `\# heading`
/// do not trigger emphasis, inline code, links, or headings.
///
/// We intentionally DO NOT consume `\(` and `\)` here to avoid interfering
/// with inline LaTeX parsing handled by InlineLatexParenScrollableMd.
class BackslashEscapeMd extends InlineMd {
  @override
  // CommonMark escape set (subset), excluding parentheses to keep LaTeX intact.
  // Matches a backslash followed by one escapable punctuation character.
  RegExp get exp => RegExp(r"\\([\\`*_{}\[\]#+\-.!])");

  @override
  InlineSpan span(BuildContext context, String text, GptMarkdownConfig config) {
    final m = exp.firstMatch(text);
    if (m == null) return TextSpan(text: text, style: config.style);
    final ch = m.group(1) ?? '';
    // Render only the escaped character (drop the backslash)
    return TextSpan(text: ch, style: config.style);
  }
}

/// A selectable version of HighlightView that allows users to select
/// and copy portions of the code instead of just the entire block.
class SelectableHighlightView extends StatelessWidget {
  const SelectableHighlightView(
    this.source, {
    super.key,
    this.language,
    this.theme = const {},
    this.padding,
    this.textStyle,
  });

  final String source;
  final String? language;
  final Map<String, TextStyle> theme;
  final EdgeInsetsGeometry? padding;
  final TextStyle? textStyle;

  /// Converts a highlight Node tree to a TextSpan tree with appropriate styling
  List<TextSpan> _convertNodes(List<Node> nodes) {
    final List<TextSpan> spans = [];

    for (final node in nodes) {
      if (node.value != null) {
        // Leaf node with text content
        spans.add(TextSpan(text: node.value, style: theme[node.className]));
      } else if (node.children != null) {
        // Node with children - recurse
        spans.add(
          TextSpan(
            children: _convertNodes(node.children!),
            style: theme[node.className],
          ),
        );
      }
    }

    return spans;
  }

  @override
  Widget build(BuildContext context) {
    final result = highlight.parse(source, language: language);
    final codeTextSpans = _convertNodes(result.nodes ?? []);

    return SelectableText.rich(
      TextSpan(
        style: textStyle,
        children: codeTextSpans.isEmpty
            ? [TextSpan(text: source)]
            : codeTextSpans,
      ),
    );
  }
}
