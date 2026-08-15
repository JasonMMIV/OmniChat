import 'dart:ui' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../theme/app_font_weights.dart';
import '../../utils/plantuml_encoder.dart';
import '../../icons/lucide_adapter.dart';
import 'package:OmniChat/l10n/app_localizations.dart';
import 'snackbar.dart';
import 'code_block_download_button.dart';
import 'export_capture_scope.dart';
import 'dart:io';

enum _PlantUMLTab { image, code }

class PlantUMLBlock extends StatefulWidget {
  final String code;

  const PlantUMLBlock({super.key, required this.code});

  @override
  State<PlantUMLBlock> createState() => _PlantUMLBlockState();
}

class _PlantUMLBlockState extends State<PlantUMLBlock> {
  static const double _previewHeight = 406;

  bool _expanded = true;
  _PlantUMLTab _selectedTab = _PlantUMLTab.image;
  late final ScrollController _codeScrollController;
  late String _imageUrl;

  @override
  void initState() {
    super.initState();
    _codeScrollController = ScrollController();
    _updateUrl();
  }

  @override
  void didUpdateWidget(covariant PlantUMLBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.code != widget.code) {
      _updateUrl();
      _selectedTab = _PlantUMLTab.image;
    }
  }

  @override
  void dispose() {
    _codeScrollController.dispose();
    super.dispose();
  }

  void _updateUrl() {
    final encoded = PlantUmlEncoder.encode(widget.code);
    _imageUrl = 'https://www.plantuml.com/plantuml/svg/$encoded';
  }

  // Save the diagram source as a .puml file.
  Future<void> _downloadCode() =>
      saveCodeBlockToFile(context, widget.code, 'puml');

  Future<void> _openPlantUMLPreview(BuildContext context) async {
    final failedMessage = AppLocalizations.of(
      context,
    )!.mermaidPreviewOpenFailed;
    try {
      final ok = await launchUrl(
        Uri.parse(_imageUrl),
        mode: LaunchMode.externalApplication,
      );
      if (ok || !context.mounted) return;
    } catch (_) {
      if (!context.mounted) return;
    }
    showAppSnackBar(
      context,
      message: failedMessage,
      type: NotificationType.error,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final l10n = AppLocalizations.of(context)!;
    final exporting = ExportCaptureScope.of(context);

    // Use theme-tinted surfaces so headers follow the current theme color.
    final Color bodyBg = Color.alphaBlend(
      cs.primary.withValues(alpha: isDark ? 0.06 : 0.03),
      cs.surface,
    );
    final Color headerBg = Color.alphaBlend(
      cs.primary.withValues(alpha: isDark ? 0.16 : 0.10),
      cs.surface,
    );
    final palette = _PlantUMLTabPalette(
      track: Color.alphaBlend(
        cs.primary.withValues(alpha: isDark ? 0.10 : 0.06),
        cs.surface,
      ),
      selected: cs.surface,
      textPrimary: cs.onSurface,
      textSecondary: cs.onSurface.withValues(alpha: 0.6),
    );

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
                                _PlantUMLTabButton(
                                  label: l10n.mermaidImageTab,
                                  selected: _selectedTab == _PlantUMLTab.image,
                                  palette: palette,
                                  onTap: () => setState(
                                    () => _selectedTab = _PlantUMLTab.image,
                                  ),
                                ),
                                _PlantUMLTabButton(
                                  label: l10n.mermaidCodeTab,
                                  selected: _selectedTab == _PlantUMLTab.code,
                                  palette: palette,
                                  onTap: () => setState(
                                    () => _selectedTab = _PlantUMLTab.code,
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
                    // Download action: save the .puml source
                    CodeBlockDownloadButton(onTap: _downloadCode),
                    const SizedBox(width: 6),
                    // Open in browser
                    InkWell(
                      onTap: () => _openPlantUMLPreview(context),
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
                        child: Icon(
                          Lucide.Link,
                          size: 14,
                          color: cs.onSurface.withValues(alpha: 0.6),
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
                    key: const ValueKey('plantuml-expanded'),
                    width: double.infinity,
                    color: bodyBg,
                    child: SizedBox(
                      key: const ValueKey('plantuml-preview-body'),
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
                          child: _selectedTab == _PlantUMLTab.code
                              ? _buildCodeView(context, palette)
                              : _buildImageView(bodyBg, palette),
                        ),
                      ),
                    ),
                  )
                : const SizedBox.shrink(key: ValueKey('plantuml-collapsed')),
          ),
        ],
      ),
    );
  }

  Widget _buildImageView(Color bodyBg, _PlantUMLTabPalette palette) {
    return Padding(
      key: const ValueKey('plantuml-image-body'),
      padding: const EdgeInsets.all(8),
      child: SvgPicture.network(
        _imageUrl,
        fit: BoxFit.contain,
        placeholderBuilder: (context) =>
            _PlantUMLLoadingView(textSecondary: palette.textSecondary),
        errorBuilder: (context, error, stackTrace) =>
            _PlantUMLErrorView(textTertiary: palette.textSecondary),
      ),
    );
  }

  Widget _buildCodeView(BuildContext context, _PlantUMLTabPalette palette) {
    return Padding(
      key: const ValueKey('plantuml-code-body'),
      padding: const EdgeInsets.all(12),
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(
          dragDevices: {
            PointerDeviceKind.touch,
            PointerDeviceKind.mouse,
            PointerDeviceKind.stylus,
            PointerDeviceKind.unknown,
          },
        ),
        child: Scrollbar(
          controller: _codeScrollController,
          thumbVisibility: true,
          interactive: true,
          notificationPredicate: (notif) => notif.metrics.axis == Axis.vertical,
          child: SingleChildScrollView(
            controller: _codeScrollController,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SelectableText(
                widget.code,
                style: TextStyle(
                  color: palette.textPrimary,
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
}

class _PlantUMLTabPalette {
  const _PlantUMLTabPalette({
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

class _PlantUMLTabButton extends StatefulWidget {
  const _PlantUMLTabButton({
    required this.label,
    required this.selected,
    required this.palette,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final _PlantUMLTabPalette palette;
  final VoidCallback onTap;

  @override
  State<_PlantUMLTabButton> createState() => _PlantUMLTabButtonState();
}

class _PlantUMLTabButtonState extends State<_PlantUMLTabButton> {
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

class _PlantUMLLoadingView extends StatelessWidget {
  const _PlantUMLLoadingView({required this.textSecondary});

  final Color textSecondary;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: textSecondary,
        ),
      ),
    );
  }
}

class _PlantUMLErrorView extends StatelessWidget {
  const _PlantUMLErrorView({required this.textTertiary});

  final Color textTertiary;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Icon(Lucide.ImageOff, size: 48, color: textTertiary),
    );
  }
}
