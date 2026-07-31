import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/models/conversation.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../utils/app_directories.dart';
import '../services/greeting_service.dart';
import '../utils/model_display_helper.dart';
import 'model_icon.dart';

/// Widget displayed when a new chat has no messages.
/// Renders customized Logo (Omnichat, Model, Custom image, or None)
/// and Text (Preset Greetings, AI Greetings, Model Name, Custom, or None).
class NewChatEmptyState extends StatefulWidget {
  const NewChatEmptyState({
    super.key,
    this.currentConversation,
  });

  final Conversation? currentConversation;

  @override
  State<NewChatEmptyState> createState() => _NewChatEmptyStateState();
}

class _NewChatEmptyStateState extends State<NewChatEmptyState> {
  File? _customLogoFile;

  @override
  void initState() {
    super.initState();
    _loadCustomLogoFile();
    _fetchAiGreetingIfNeeded();
  }

  @override
  void didUpdateWidget(covariant NewChatEmptyState oldWidget) {
    super.didUpdateWidget(oldWidget);
    _loadCustomLogoFile();
    _fetchAiGreetingIfNeeded();
  }

  Future<void> _loadCustomLogoFile() async {
    final settings = context.read<SettingsProvider>();
    final fileName = settings.newChatCustomLogoFileName;
    if (fileName != null && fileName.isNotEmpty) {
      final dir = await AppDirectories.getImagesDirectory();
      final file = File('${dir.path}/$fileName');
      if (await file.exists()) {
        if (mounted) setState(() => _customLogoFile = file);
        return;
      }
    }
    if (mounted && _customLogoFile != null) {
      setState(() => _customLogoFile = null);
    }
  }

  void _fetchAiGreetingIfNeeded() {
    final settings = context.read<SettingsProvider>();
    if (settings.newChatTextType == 'aiGreeting') {
      GreetingService.fetchAiGreetingInBackground(settings);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final settings = context.watch<SettingsProvider>();
    final assistant = context.watch<AssistantProvider>().currentAssistant;
    final modelInfo = getModelDisplayInfo(settings, assistant: assistant);

    final logoType = settings.newChatLogoType;
    final textType = settings.newChatTextType;

    final providerKey = modelInfo.providerKey;
    final modelId = modelInfo.modelId;
    final modelDisplay = modelInfo.modelDisplay;

    const logoSize = 100.0;

    Widget? logoWidget;
    switch (logoType) {
      case 'omnichat':
        logoWidget = Image.asset(
          'assets/app_icon.png',
          width: logoSize,
          height: logoSize,
          fit: BoxFit.contain,
        );
        break;
      case 'model':
        logoWidget = CurrentModelIcon(
          providerKey: providerKey,
          modelId: modelId,
          size: logoSize,
        );
        break;
      case 'custom':
        if (_customLogoFile != null) {
          logoWidget = ClipRRect(
            borderRadius: BorderRadius.circular(22),
            child: Image.file(
              _customLogoFile!,
              width: logoSize,
              height: logoSize,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Image.asset('assets/app_icon.png', width: logoSize, height: logoSize),
            ),
          );
        } else {
          logoWidget = Image.asset('assets/app_icon.png', width: logoSize, height: logoSize);
        }
        break;
      case 'none':
      default:
        logoWidget = null;
        break;
    }

    final locale = Localizations.localeOf(context);

    String? textContent;
    switch (textType) {
      case 'presetGreeting':
        textContent = GreetingService.getPresetGreeting(locale: locale);
        break;
      case 'aiGreeting':
        textContent = (settings.newChatCachedAiGreeting != null && settings.newChatCachedAiGreeting!.isNotEmpty)
            ? settings.newChatCachedAiGreeting
            : GreetingService.getPresetGreeting(locale: locale);
        break;
      case 'modelName':
        textContent = modelDisplay ?? modelId ?? 'OmniChat';
        break;
      case 'custom':
        textContent = settings.newChatCustomText;
        break;
      case 'none':
      default:
        textContent = null;
        break;
    }

    if (logoWidget == null && (textContent == null || textContent.trim().isEmpty)) {
      return const SizedBox.shrink();
    }

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (logoWidget != null) ...[
              logoWidget,
              if (textContent != null && textContent.trim().isNotEmpty) const SizedBox(height: 22),
            ],
            if (textContent != null && textContent.trim().isNotEmpty)
              Text(
                textContent,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: cs.onSurface.withOpacity(0.9),
                  height: 1.4,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
