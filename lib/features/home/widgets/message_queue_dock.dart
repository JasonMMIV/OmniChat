import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../core/services/chat/turn_queue/send_gate.dart';
import '../../../core/services/chat/turn_queue/turn_queue.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';

/// Live turn-queue dock shown above the composer
/// (docs/anybuff_queue_sendnow_import_plan.md §3.2/§4.2).
///
/// Visibility contract:
/// - rendered only for the current conversation while it has queued items;
/// - expanded by default: the header shows the count and tapping it
///   collapses/expands the item list;
/// - item actions: Send now (steer this item into the live turn), inline text
///   edit (tap the preview or the pencil), remove, move to front;
/// - when the queue is paused (Stop / repeated failures) the resume banner is
///   always visible, even while collapsed, so "繼續" stays reachable.
class MessageQueueDock extends StatefulWidget {
  const MessageQueueDock({
    super.key,
    required this.items,
    required this.paused,
    this.runActive = false,
    this.teamActive = false,
    this.onRemove,
    this.onPromote,
    this.onEdit,
    this.onSendNow,
    this.onResume,
  });

  final List<QueuedMessage> items;
  final bool paused;

  /// Whether a turn is currently running (per-item Send now needs a live
  /// steering mailbox).
  final bool runActive;

  /// AI Team never steers (F6/R18).
  final bool teamActive;

  final ValueChanged<String>? onRemove;
  final ValueChanged<String>? onPromote;
  final void Function(String id, String text)? onEdit;

  /// Per-item Send now: steer that item's pure text into the running turn.
  final ValueChanged<String>? onSendNow;
  final VoidCallback? onResume;

  @override
  State<MessageQueueDock> createState() => _MessageQueueDockState();
}

class _MessageQueueDockState extends State<MessageQueueDock> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final hasItems = widget.items.isNotEmpty;
    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      alignment: Alignment.bottomCenter,
      child: hasItems
          ? _buildDock(context)
          : const SizedBox(width: double.infinity),
    );
  }

  Widget _buildDock(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Material(
            color: isDark
                ? Colors.white.withValues(alpha: 0.06)
                : Colors.black.withValues(alpha: 0.035),
            borderRadius: BorderRadius.circular(14),
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                InkWell(
                  onTap: () => setState(() => _expanded = !_expanded),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 9, 8, 9),
                    child: Row(
                      children: [
                        Icon(
                          Lucide.ListPlus,
                          size: 18,
                          color: cs.onSurface.withValues(alpha: 0.6),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            l10n.queueDockTitle(widget.items.length),
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: cs.onSurface.withValues(alpha: 0.85),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Icon(
                          _expanded ? Icons.expand_less : Icons.expand_more,
                          size: 18,
                          color: cs.onSurface.withValues(alpha: 0.5),
                        ),
                      ],
                    ),
                  ),
                ),
                if (widget.paused)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 8, 6),
                    child: Row(
                      children: [
                        Icon(
                          Icons.pause_circle_outline,
                          size: 16,
                          color: cs.onSurface.withValues(alpha: 0.55),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            l10n.queueDockPausedHint,
                            style: TextStyle(
                              fontSize: 10.5,
                              color: cs.onSurface.withValues(alpha: 0.6),
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: widget.onResume,
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                          ),
                          child: Text(
                            l10n.queueDockResume,
                            style: const TextStyle(fontSize: 11.5),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (_expanded)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 220),
                    child: ListView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                      itemCount: widget.items.length,
                      itemBuilder: (context, index) {
                        final item = widget.items[index];
                        return _QueueDockItemRow(
                          key: ValueKey(item.id),
                          item: item,
                          runActive: widget.runActive,
                          teamActive: widget.teamActive,
                          onRemove: widget.onRemove,
                          onPromote: widget.onPromote,
                          onEdit: widget.onEdit,
                          onSendNow: widget.onSendNow,
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _QueueDockItemRow extends StatefulWidget {
  const _QueueDockItemRow({
    super.key,
    required this.item,
    required this.runActive,
    required this.teamActive,
    this.onRemove,
    this.onPromote,
    this.onEdit,
    this.onSendNow,
  });

  final QueuedMessage item;
  final bool runActive;
  final bool teamActive;
  final ValueChanged<String>? onRemove;
  final ValueChanged<String>? onPromote;
  final void Function(String id, String text)? onEdit;
  final ValueChanged<String>? onSendNow;

  @override
  State<_QueueDockItemRow> createState() => _QueueDockItemRowState();
}

class _QueueDockItemRowState extends State<_QueueDockItemRow> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _editorFocus = FocusNode(debugLabel: 'queue-item-editor');
  bool _editing = false;
  bool _closing = false;

  @override
  void dispose() {
    _editorFocus.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final item = widget.item;
    final text = item.input.text.trim();
    final attachmentCount =
        item.input.imagePaths.length + item.input.documents.length;

    // Same gate as the composer: pure text, no slash command, live run, and
    // no AI Team. Attachments take precedence in the reason order.
    final reason = sendNowBlockReason(
      loading: widget.runActive,
      text: text,
      imageCount: item.input.imagePaths.length,
      documentCount: item.input.documents.length,
      teamActive: widget.teamActive,
    );
    final canSendNow =
        reason == SendNowBlockReason.none && widget.onSendNow != null;
    final sendNowTooltip = switch (reason) {
      SendNowBlockReason.attachments => l10n.composerSendNowAttachmentsHint,
      SendNowBlockReason.command => l10n.composerSendNowCommandHint,
      SendNowBlockReason.delegation => l10n.composerSendNowDelegationHint,
      SendNowBlockReason.team => l10n.composerSendNowTeamHint,
      SendNowBlockReason.inactive => l10n.queueDockSendNowIdle,
      SendNowBlockReason.none => l10n.queueDockSendNow,
    };
    final sendNowColor = canSendNow
        ? cs.primary
        : cs.onSurface.withValues(alpha: 0.3);

    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const SizedBox(width: 4),
        Expanded(
          child: _editing
              ? _buildEditor(context)
              : _buildPreview(cs, l10n, text, attachmentCount),
        ),
        if (_editing)
          ..._buildEditorActions(context, l10n)
        else ...[
          if (widget.onSendNow != null)
            IconButton(
              key: ValueKey('queue-send-now-${item.id}'),
              tooltip: sendNowTooltip,
              visualDensity: VisualDensity.compact,
              onPressed: canSendNow ? () => widget.onSendNow!(item.id) : null,
              icon: SvgPicture.asset(
                'assets/icons/send_now.svg',
                width: 16,
                height: 16,
                colorFilter: ColorFilter.mode(sendNowColor, BlendMode.srcIn),
              ),
            ),
          IconButton(
            tooltip: l10n.queueDockPromote,
            visualDensity: VisualDensity.compact,
            iconSize: 16,
            onPressed: widget.onPromote == null
                ? null
                : () => widget.onPromote!(item.id),
            icon: Icon(
              Icons.vertical_align_top,
              color: cs.onSurface.withValues(alpha: 0.55),
            ),
          ),
          IconButton(
            tooltip: l10n.queueDockEdit,
            visualDensity: VisualDensity.compact,
            iconSize: 16,
            onPressed: widget.onEdit == null ? null : _startEditing,
            icon: Icon(
              Icons.edit_outlined,
              color: cs.onSurface.withValues(alpha: 0.55),
            ),
          ),
          IconButton(
            tooltip: l10n.queueDockRemove,
            visualDensity: VisualDensity.compact,
            iconSize: 16,
            onPressed: widget.onRemove == null
                ? null
                : () => widget.onRemove!(item.id),
            icon: Icon(
              Icons.close,
              color: cs.onSurface.withValues(alpha: 0.55),
            ),
          ),
        ],
      ],
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      // While editing, keep taps on the save/cancel buttons inside the text
      // field's tap region so they don't trigger an "outside" save.
      child: _editing ? TextFieldTapRegion(child: row) : row,
    );
  }

  Widget _buildPreview(
    ColorScheme cs,
    AppLocalizations l10n,
    String text,
    int attachmentCount,
  ) {
    final canEdit = widget.onEdit != null;
    return ConstrainedBox(
      // Keep the tap target comfortable even for a single short line.
      constraints: const BoxConstraints(minHeight: 32),
      child: Semantics(
        button: canEdit ? true : null,
        hint: canEdit ? l10n.queueDockEdit : null,
        child: InkWell(
          key: ValueKey('queue-item-text-${widget.item.id}'),
          borderRadius: BorderRadius.circular(6),
          mouseCursor: canEdit ? SystemMouseCursors.text : MouseCursor.defer,
          onTap: canEdit ? _startEditing : null,
          child: Container(
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: text.isNotEmpty
                ? Text(
                    text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.3,
                      color: cs.onSurface.withValues(alpha: 0.8),
                    ),
                  )
                : Row(
                    children: [
                      Icon(
                        Icons.attach_file,
                        size: 14,
                        color: cs.onSurface.withValues(alpha: 0.55),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '$attachmentCount',
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurface.withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildEditor(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Focus(
      onKeyEvent: _handleEditorKeyEvent,
      child: TextField(
        key: ValueKey('queue-edit-field-${widget.item.id}'),
        controller: _controller,
        focusNode: _editorFocus,
        minLines: 1,
        maxLines: 4,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) {
          final composing = _controller.value.composing;
          if (composing.isValid && !composing.isCollapsed) return;
          _commitEditing();
        },
        onTapOutside: (_) => _commitEditing(),
        style: TextStyle(
          fontSize: 12,
          height: 1.3,
          color: cs.onSurface.withValues(alpha: 0.9),
        ),
        cursorColor: cs.primary,
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: isDark
              ? Colors.white.withValues(alpha: 0.05)
              : Colors.black.withValues(alpha: 0.04),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 8,
            vertical: 8,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(
              color: cs.outlineVariant.withValues(alpha: isDark ? 0.35 : 0.5),
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(
              color: cs.primary.withValues(alpha: 0.8),
              width: 1.2,
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildEditorActions(
    BuildContext context,
    AppLocalizations l10n,
  ) {
    final cs = Theme.of(context).colorScheme;
    return [
      IconButton(
        key: ValueKey('queue-edit-save-${widget.item.id}'),
        tooltip: l10n.queueDockEditSave,
        visualDensity: VisualDensity.compact,
        iconSize: 18,
        onPressed: _commitEditing,
        icon: Icon(Icons.check, color: cs.primary),
      ),
      IconButton(
        key: ValueKey('queue-edit-cancel-${widget.item.id}'),
        tooltip: MaterialLocalizations.of(context).cancelButtonLabel,
        visualDensity: VisualDensity.compact,
        iconSize: 16,
        onPressed: _cancelEditing,
        icon: Icon(Icons.close, color: cs.onSurface.withValues(alpha: 0.55)),
      ),
    ];
  }

  void _startEditing() {
    if (widget.onEdit == null) return;
    if (_editing) {
      _editorFocus.requestFocus();
      return;
    }
    final current = widget.item.input.text.trim();
    _controller.value = TextEditingValue(
      text: current,
      selection: TextSelection.collapsed(offset: current.length),
    );
    setState(() {
      _editing = true;
      _closing = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _editing) _editorFocus.requestFocus();
    });
  }

  void _finishEditing() {
    if (!_editing) return;
    _closing = true;
    setState(() => _editing = false);
    _editorFocus.unfocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _closing = false;
    });
  }

  void _commitEditing() {
    if (!_editing || _closing) return;
    final trimmed = _controller.text.trim();
    final current = widget.item.input.text.trim();
    _finishEditing();
    if (trimmed.isEmpty || trimmed == current) return;
    widget.onEdit?.call(widget.item.id, trimmed);
  }

  void _cancelEditing() {
    if (!_editing || _closing) return;
    _finishEditing();
  }

  KeyEventResult _handleEditorKeyEvent(FocusNode node, KeyEvent event) {
    final composing = _controller.value.composing;
    final composingActive = composing.isValid && !composing.isCollapsed;

    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (event is KeyDownEvent) {
        // Esc cancels the IME composition first when one is active.
        if (composingActive) return KeyEventResult.ignored;
        _cancelEditing();
      }
      return KeyEventResult.handled;
    }

    final isEnter =
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (!isEnter) return KeyEventResult.ignored;
    if (event is! KeyDownEvent) return KeyEventResult.handled;

    // Let the IME own Enter while composing (Chinese/Japanese input).
    if (composingActive) return KeyEventResult.ignored;
    if (HardwareKeyboard.instance.isShiftPressed) {
      _insertNewlineAtCursor();
    } else {
      _commitEditing();
    }
    return KeyEventResult.handled;
  }

  void _insertNewlineAtCursor() {
    final value = _controller.value;
    final selection = value.selection;
    final text = value.text;
    if (!selection.isValid) {
      _controller.text = '$text\n';
      _controller.selection = TextSelection.collapsed(
        offset: _controller.text.length,
      );
      return;
    }
    final newText = text.replaceRange(selection.start, selection.end, '\n');
    _controller.value = value.copyWith(
      text: newText,
      selection: TextSelection.collapsed(offset: selection.start + 1),
      composing: TextRange.empty,
    );
  }
}
