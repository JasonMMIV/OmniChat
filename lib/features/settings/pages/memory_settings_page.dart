import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/memory_entry.dart';
import '../../../core/providers/memory_provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/memory/memory_block_builder.dart';
import '../../../core/services/memory_store.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../model/widgets/model_select_sheet.dart';

class MemorySettingsPage extends StatelessWidget {
  const MemorySettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final settings = context.watch<SettingsProvider>();
    final memory = context.watch<MemoryProvider>();
    try {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        memory.initialize();
      });
    } catch (_) {}

    Widget sectionCard({required Widget child}) => Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? Colors.white10
            : Colors.white.withOpacity(0.96),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: cs.outlineVariant.withOpacity(
            Theme.of(context).brightness == Brightness.dark ? 0.08 : 0.06,
          ),
          width: 0.6,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );

    Widget navRow({
      required IconData icon,
      required String label,
      required String value,
      required VoidCallback onTap,
      Widget? trailing,
    }) => InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        child: Row(
          children: [
            Icon(icon, size: 18, color: cs.primary),
            const SizedBox(width: 10),
            Expanded(child: Text(label, style: const TextStyle(fontSize: 14))),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                value,
                textAlign: TextAlign.end,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  color: cs.onSurface.withOpacity(0.6),
                ),
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 4), trailing],
          ],
        ),
      ),
    );

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Lucide.ArrowLeft),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(l10n.memorySettingsTitle),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 24),
        children: [
          sectionCard(
            child: Column(
              children: [
                navRow(
                  icon: Lucide.Layers,
                  label: l10n.memorySettingsMaxItemsTitle,
                  value: '${settings.memoryInjectionMaxItems}',
                  onTap: () => _pickMaxItems(context, settings, l10n),
                ),
                Divider(
                  height: 1,
                  thickness: 0.6,
                  color: cs.outlineVariant.withOpacity(0.15),
                ),
                navRow(
                  icon: Lucide.WandSparkles,
                  label: l10n.memorySettingsOrganizeModelTitle,
                  value:
                      settings.memoryOrganizeModelId ??
                      l10n.memorySettingsNotSet,
                  onTap: () async {
                    final selection = await showModelSelector(context);
                    if (selection != null) {
                      await settings.setMemoryOrganizeModel(
                        selection.providerKey,
                        selection.modelId,
                      );
                    }
                  },
                  trailing: settings.memoryOrganizeModelId == null
                      ? null
                      : IconButton(
                          tooltip: l10n.memorySettingsReset,
                          icon: const Icon(Lucide.X, size: 16),
                          onPressed: settings.resetMemoryOrganizeModel,
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(42, 0, 14, 10),
                  child: Text(
                    l10n.memorySettingsOrganizeModelSubtitle,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: cs.onSurface.withOpacity(0.55),
                    ),
                  ),
                ),
                SwitchListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                  secondary: Icon(Lucide.Brain, size: 18, color: cs.primary),
                  title: Text(
                    l10n.titleModelThinkingTitle,
                    style: const TextStyle(fontSize: 14),
                  ),
                  value: settings.memoryOrganizeThinkingEnabled,
                  onChanged: (value) =>
                      settings.setMemoryOrganizeThinkingEnabled(value),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
            child: Text(
              l10n.memorySettingsMaxItemsSubtitle(
                settings.memoryInjectionMaxItems,
              ),
              style: TextStyle(
                fontSize: 12,
                color: cs.onSurface.withOpacity(0.55),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
            child: Text(
              l10n.memorySettingsFullInjectionTitle,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final type in MemoryType.values)
                  FilterChip(
                    label: Text(
                      _typeLabel(l10n, type),
                      style: const TextStyle(fontSize: 12),
                    ),
                    selected: settings.memoryFullInjectionTypes.contains(type),
                    onSelected: (selected) {
                      final next = Set<MemoryType>.of(
                        settings.memoryFullInjectionTypes,
                      );
                      if (selected) {
                        next.add(type);
                      } else {
                        next.remove(type);
                      }
                      settings.setMemoryFullInjectionTypes(next);
                    },
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
            child: Text(
              l10n.memorySettingsFullInjectionSubtitle,
              style: TextStyle(
                fontSize: 12,
                color: cs.onSurface.withOpacity(0.55),
              ),
            ),
          ),
          FutureBuilder<int>(
            future: MemoryStore.legacyImportedCount(),
            builder: (context, snapshot) {
              final count = snapshot.data ?? 0;
              if (count <= 0) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: Text(
                  l10n.memorySettingsMigrated(count),
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurface.withOpacity(0.55),
                  ),
                ),
              );
            },
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
            child: Text(
              l10n.memorySettingsGlobalEntriesTitle,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
          ),
          if (memory.globalEntries.where((e) => !e.isArchived).isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                l10n.assistantEditMemoryEmpty,
                style: TextStyle(
                  fontSize: 12,
                  color: cs.onSurface.withOpacity(0.6),
                ),
              ),
            )
          else
            ...memory.globalEntries
                .where((e) => !e.isArchived)
                .map(
                  (e) => sectionCard(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _typeLabel(l10n, e.type),
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                              color: cs.primary,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            e.content,
                            maxLines: 4,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 14),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
        ],
      ),
    );
  }

  Future<void> _pickMaxItems(
    BuildContext context,
    SettingsProvider settings,
    AppLocalizations l10n,
  ) async {
    final cs = Theme.of(context).colorScheme;
    const presets = <int>[5, 10, 20, 30];
    final selected = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: cs.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final value in presets)
              ListTile(
                title: Text('$value'),
                trailing: settings.memoryInjectionMaxItems == value
                    ? Icon(Lucide.Check, size: 18, color: cs.primary)
                    : null,
                onTap: () => Navigator.of(ctx).pop(value),
              ),
            ListTile(
              title: Text(l10n.memorySettingsCustom),
              onTap: () async {
                final custom = await _askCustomValue(context);
                if (ctx.mounted && custom != null) {
                  Navigator.of(ctx).pop(custom);
                }
              },
            ),
          ],
        ),
      ),
    );
    if (selected != null) {
      await settings.setMemoryInjectionMaxItems(selected);
    }
  }

  Future<int?> _askCustomValue(BuildContext context) async {
    final controller = TextEditingController(
      text: '${MemoryBlockBuilder.defaultMaxItemsPerType}',
    );
    final result = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: const InputDecoration(hintText: '3–30'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final value = int.tryParse(controller.text.trim());
              Navigator.of(ctx).pop(value);
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
    if (result == null) return null;
    return MemoryBlockBuilder.clampMaxItems(result);
  }

  static String _typeLabel(AppLocalizations l10n, MemoryType type) =>
      switch (type) {
        MemoryType.identity => l10n.memoryTypeIdentity,
        MemoryType.workflow => l10n.memoryTypeWorkflow,
        MemoryType.voice => l10n.memoryTypeVoice,
        MemoryType.instruction => l10n.memoryTypeInstruction,
      };
}
