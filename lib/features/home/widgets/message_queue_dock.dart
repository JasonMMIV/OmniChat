import 'package:flutter/material.dart';

import '../../../core/services/chat/turn_queue/turn_queue.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';

/// Live turn-queue dock shown above the composer
/// (docs/anybuff_queue_sendnow_import_plan.md §3.2/§4.2).
///
/// Visibility contract:
/// - rendered only for the current conversation while it has queued items;
/// - expanded by default: the header shows the count + auto-send hint and
///   tapping it collapses/expands the item list;
/// - item actions are limited to the v1 ruling (§0.3/§9): edit text, remove,
///   move to front — there is deliberately no per-item Send now;
/// - when the queue is paused (Stop / repeated failures) the resume banner is
///   always visible, even while collapsed, so "繼續" stays reachable.
class MessageQueueDock extends StatefulWidget {
  const MessageQueueDock({
    super.key,
    required this.items,
    required this.paused,
    this.onRemove,
    this.onPromote,
    this.onEdit,
    this.onResume,
  });

  final List<QueuedMessage> items;
  final bool paused;
  final ValueChanged<String>? onRemove;
  final ValueChanged<String>? onPromote;
  final void Function(String id, String text)? onEdit;
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
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                l10n.queueDockTitle(widget.items.length),
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                  color: cs.onSurface.withValues(alpha: 0.85),
                                ),
                              ),
                              const SizedBox(height: 1),
                              Text(
                                widget.paused
                                    ? l10n.queueDockPausedHint
                                    : l10n.queueDockHint,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 10.5,
                                  height: 1.3,
                                  color: cs.onSurface.withValues(
                                    alpha: widget.paused ? 0.6 : 0.5,
                                  ),
                                ),
                              ),
                            ],
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
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                            ),
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
                          item: item,
                          onRemove: widget.onRemove,
                          onPromote: widget.onPromote,
                          onEdit: widget.onEdit,
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

class _QueueDockItemRow extends StatelessWidget {
  const _QueueDockItemRow({
    required this.item,
    this.onRemove,
    this.onPromote,
    this.onEdit,
  });

  final QueuedMessage item;
  final ValueChanged<String>? onRemove;
  final ValueChanged<String>? onPromote;
  final void Function(String id, String text)? onEdit;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final text = item.input.text.trim();
    final attachmentCount =
        item.input.imagePaths.length + item.input.documents.length;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(width: 4),
          Expanded(
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
          IconButton(
            tooltip: l10n.queueDockPromote,
            visualDensity: VisualDensity.compact,
            iconSize: 16,
            onPressed: onPromote == null ? null : () => onPromote!(item.id),
            icon: Icon(
              Icons.vertical_align_top,
              color: cs.onSurface.withValues(alpha: 0.55),
            ),
          ),
          IconButton(
            tooltip: l10n.queueDockEdit,
            visualDensity: VisualDensity.compact,
            iconSize: 16,
            onPressed: onEdit == null ? null : () => _edit(context),
            icon: Icon(
              Icons.edit_outlined,
              color: cs.onSurface.withValues(alpha: 0.55),
            ),
          ),
          IconButton(
            tooltip: l10n.queueDockRemove,
            visualDensity: VisualDensity.compact,
            iconSize: 16,
            onPressed: onRemove == null ? null : () => onRemove!(item.id),
            icon: Icon(
              Icons.close,
              color: cs.onSurface.withValues(alpha: 0.55),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _edit(BuildContext context) async {
    final save = await showDialog<String>(
      context: context,
      builder: (_) => _QueueItemEditDialog(initialText: item.input.text.trim()),
    );
    final trimmed = (save ?? '').trim();
    if (trimmed.isEmpty) return;
    onEdit?.call(item.id, trimmed);
  }
}

/// Text-only edit dialog. Owns its controller so disposal follows the route
/// lifecycle (an eagerly disposed controller breaks the exit animation).
class _QueueItemEditDialog extends StatefulWidget {
  const _QueueItemEditDialog({required this.initialText});

  final String initialText;

  @override
  State<_QueueItemEditDialog> createState() => _QueueItemEditDialogState();
}

class _QueueItemEditDialogState extends State<_QueueItemEditDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialText,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l10n.queueDockEdit),
      content: TextField(
        controller: _controller,
        autofocus: true,
        minLines: 1,
        maxLines: 6,
        decoration: const InputDecoration(border: OutlineInputBorder()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(MaterialLocalizations.of(context).okButtonLabel),
        ),
      ],
    );
  }
}
