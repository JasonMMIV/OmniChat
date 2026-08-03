import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/providers/settings_provider.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../core/services/haptics.dart';
import '../../home/utils/chat_input_button_catalog.dart';

/// Mobile settings page for customizing chat input bar button order/visibility.
class ChatInputButtonOrderPage extends StatelessWidget {
  const ChatInputButtonOrderPage({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        leading: Tooltip(
          message: l10n.settingsPageBackButton,
          child: IconButton(
            icon: Icon(Lucide.ArrowLeft, color: cs.onSurface, size: 22),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ),
        title: Text(l10n.chatInputButtonOrderTitle),
        actions: [
          IconButton(
            tooltip: l10n.chatInputButtonOrderReset,
            icon: Icon(Lucide.RotateCcw, color: cs.onSurface, size: 20),
            onPressed: () {
              Haptics.light();
              final sp = context.read<SettingsProvider>();
              sp.setChatInputButtonOrder(const []);
              sp.setChatInputButtonHidden(const []);
            },
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: const ChatInputButtonOrderPanel(),
    );
  }
}

/// Reorder + visibility list shared by the mobile page and the desktop dialog.
class ChatInputButtonOrderPanel extends StatelessWidget {
  const ChatInputButtonOrderPanel({super.key});

  void _reorder(BuildContext context, int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex -= 1;
    final settings = context.read<SettingsProvider>();
    final order = chatInputButtonEffectiveOrder(
      settings.chatInputButtonOrder,
    );
    final id = order.removeAt(oldIndex);
    order.insert(newIndex, id);
    settings.setChatInputButtonOrder(order);
  }

  void _toggleHidden(BuildContext context, String id, bool hidden) {
    Haptics.light();
    final settings = context.read<SettingsProvider>();
    final hiddenList = List<String>.from(settings.chatInputButtonHidden);
    if (hidden) {
      if (!hiddenList.contains(id)) hiddenList.add(id);
    } else {
      hiddenList.remove(id);
    }
    settings.setChatInputButtonHidden(hiddenList);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final settings = context.watch<SettingsProvider>();
    final hidden = settings.chatInputButtonHidden.toSet();
    final order = chatInputButtonEffectiveOrder(
      settings.chatInputButtonOrder,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(
            l10n.chatInputButtonOrderHint,
            style: TextStyle(
              fontSize: 13,
              color: cs.onSurface.withOpacity(0.6),
            ),
          ),
        ),
        Expanded(
          child: ReorderableListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            itemCount: order.length,
            buildDefaultDragHandles: false,
            proxyDecorator: (child, index, animation) {
              return AnimatedBuilder(
                animation: animation,
                builder: (context, _) {
                  final t = Curves.easeOut.transform(animation.value);
                  return Transform.scale(
                    scale: 0.98 + 0.02 * t,
                    child: Material(
                      color: Colors.transparent,
                      child: child,
                    ),
                  );
                },
              );
            },
            onReorder: (oldIndex, newIndex) =>
                _reorder(context, oldIndex, newIndex),
            itemBuilder: (context, index) {
              final id = order[index];
              final spec = chatInputButtonSpecById(id);
              if (spec == null) return const SizedBox.shrink();
              final isHidden = hidden.contains(id);
              return KeyedSubtree(
                key: ValueKey('chat-input-button-$id'),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Container(
                    decoration: BoxDecoration(
                      color: cs.surface,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: cs.outline.withOpacity(0.18),
                      ),
                    ),
                    child: Row(
                      children: [
                        ReorderableDragStartListener(
                          index: index,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 14,
                            ),
                            child: Icon(
                              Lucide.GripVertical,
                              size: 18,
                              color: cs.onSurface.withOpacity(0.4),
                            ),
                          ),
                        ),
                        Icon(
                          spec.icon,
                          size: 20,
                          color: isHidden
                              ? cs.onSurface.withOpacity(0.35)
                              : cs.onSurface.withOpacity(0.85),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            spec.label(l10n),
                            style: TextStyle(
                              fontSize: 15,
                              color: isHidden
                                  ? cs.onSurface.withOpacity(0.4)
                                  : cs.onSurface,
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Switch(
                            value: !isHidden,
                            onChanged: (v) =>
                                _toggleHidden(context, id, !v),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
