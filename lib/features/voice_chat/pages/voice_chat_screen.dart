import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/providers/tts_provider.dart';
import '../../../core/providers/user_provider.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../controllers/voice_chat_controller.dart';

class VoiceChatScreen extends StatelessWidget {
  const VoiceChatScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer5<ChatService, SettingsProvider, AssistantProvider, TtsProvider, UserProvider>(
      builder:
          (context, chatService, settings, assistantProvider, ttsProvider, userProvider, child) {
            return VoiceChatScreenView(
              chatService: chatService,
              settings: settings,
              assistantProvider: assistantProvider,
              ttsProvider: ttsProvider,
              userProvider: userProvider,
            );
          },
    );
  }
}

/// 純 UI：狀態與業務邏輯全部委由 [VoiceChatController]（Phase 3 拆分）。
class VoiceChatScreenView extends StatefulWidget {
  final ChatService chatService;
  final SettingsProvider settings;
  final AssistantProvider assistantProvider;
  final TtsProvider ttsProvider;
  final UserProvider userProvider;

  const VoiceChatScreenView({
    super.key,
    required this.chatService,
    required this.settings,
    required this.assistantProvider,
    required this.ttsProvider,
    required this.userProvider,
  });

  @override
  State<VoiceChatScreenView> createState() => _VoiceChatScreenViewState();
}

class _VoiceChatScreenViewState extends State<VoiceChatScreenView> {
  late final VoiceChatController _controller;
  bool _showSubtitles = true;

  @override
  void initState() {
    super.initState();
    _controller = VoiceChatController(
      chatService: widget.chatService,
      settings: widget.settings,
      assistantProvider: widget.assistantProvider,
      ttsProvider: widget.ttsProvider,
      userProvider: widget.userProvider,
      context: context,
    )..addListener(_onControllerChanged);
    _controller.startUp();
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    super.dispose();
  }

  Future<void> _endVoiceChat() async {
    // Task 2.7: 與中央停止鍵一致，走完整 cleanup
    await _controller.cleanup();
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  void _toggleSubtitle() {
    setState(() {
      _showSubtitles = !_showSubtitles;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (l10n == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      body: Stack(
        children: [
          // Gray-black background
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  const Color(0xFF2C2C2C), // Gray-black at top
                  const Color(0xFF1E1E1E), // Slightly lighter gray-black at bottom
                ],
              ),
            ),
          ),
          // Main content area
          Column(
            children: [
              // Top app bar
              SafeArea(
                bottom: false,
                child: Row(
                  children: [
                    IconButton(
                      onPressed: _endVoiceChat, // Task 2.7: 與中央停止鍵一致，走完整 cleanup
                      icon: Icon(Lucide.X, color: Colors.white),
                    ),
                    const Spacer(),
                    Text(
                      l10n.voiceChatTitle,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                    const Spacer(),
                    const SizedBox(width: 48), // Spacer for alignment
                  ],
                ),
              ),

              // State display (moved just below the app bar)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24.0),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.transparent, // No background to blend with main background
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _getStateText(context),
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: _getStateColor(cs),
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 24),

              // Central area for subtitle display
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24.0),
                  child: Center( // Use Center to keep subtitle centered
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: 600, // Limit max width for better readability on wide screens
                      ),
                      child: SingleChildScrollView(
                        child: Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.transparent, // No background to blend with main background
                            borderRadius: BorderRadius.circular(12),
                          ),
                          // Task 1.2: 字幕開關生效（關閉時保留區塊避免 layout 跳動）
                          child: _showSubtitles
                              ? Text(
                                  _controller.currentSubtitle,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    fontSize: 16,
                                    color: Colors.white,
                                  ),
                                )
                              : const SizedBox.shrink(),
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              // Bottom control buttons - completely transparent without IosCardPress
              Padding(
                padding: const EdgeInsets.all(24.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    // Left: Pause/Play button - no background
                    GestureDetector(
                      onTap: _controller.togglePause,
                      child: Container(
                        width: 60,
                        height: 60,
                        child: Icon(
                          _controller.isPaused ? Lucide.Play : Lucide.Pause,
                          color: Colors.white,
                          size: 24,
                        ),
                      ),
                    ),

                    // Center: End voice chat button - no background, larger and bolder (calls full cleanup with navigation)
                    GestureDetector(
                      onTap: _endVoiceChat, // Perform all cleanup and navigation
                      child: Container(
                        width: 80,
                        height: 80,
                        child: Icon(
                          Lucide.CircleStop,
                          color: Colors.red.shade300,
                          size: 64, // Increased size by 2 times as requested
                        ),
                      ),
                    ),

                    // Right: Subtitle toggle - no background
                    GestureDetector(
                      onTap: _toggleSubtitle,
                      child: Container(
                        width: 60,
                        height: 60,
                        child: Icon(
                          _showSubtitles ? Lucide.Captions : Lucide.CaptionsOff,
                          color: Colors.white,
                          size: 24,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          // Microphone permission overlay if needed
          if (!_controller.hasMicrophonePermission)
            Container(
              color: const Color(0x99000000), // Darker semi-transparent overlay
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Lucide.MicOff,
                      size: 64,
                      color: Colors.red.shade400, // Vibrant red for error icon
                    ),
                    const SizedBox(height: 16),
                    Text(
                      l10n.voiceChatPermissionRequired,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24.0),
                      child: Text(
                        // Task 2.3: 永久拒絕時顯示引導至系統設定的文案
                        _controller.micPermanentlyDenied
                            ? l10n.voiceChatPermissionDeniedSubtitle
                            : l10n.voiceChatPermissionSubtitle,
                        style: const TextStyle(
                          fontSize: 14,
                          color: Colors.white70,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: _controller.micPermanentlyDenied
                          ? _controller.openMicrophoneSettings
                          : _controller.requestMicrophonePermission,
                      child: Text(
                        _controller.micPermanentlyDenied
                            ? l10n.voiceChatPermissionOpenSettings
                            : l10n.voiceChatPermissionButton,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _getStateText(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (_controller.isPaused) {
      return l10n.voiceChatPaused; // Task 2.2 本地化
    }
    switch (_controller.currentState) {
      case VoiceChatState.listening:
        return l10n.voiceChatListening;
      case VoiceChatState.thinking:
        return l10n.voiceChatThinking;
      case VoiceChatState.talking:
        return l10n.voiceChatTalking;
    }
  }

  Color _getStateColor(ColorScheme cs) {
    if (_controller.isPaused) {
      return Colors.grey.shade400;
    }
    switch (_controller.currentState) {
      case VoiceChatState.listening:
        return Colors.green.shade400;
      case VoiceChatState.thinking:
        return Colors.orange.shade400;
      case VoiceChatState.talking:
        return Colors.blue.shade400;
    }
  }
}
