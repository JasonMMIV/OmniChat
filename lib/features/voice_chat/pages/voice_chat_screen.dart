import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_background/flutter_background.dart';
import 'package:audio_session/audio_session.dart';
import '../../../l10n/app_localizations.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/providers/tts_provider.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/models/chat_message.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import '../../../core/services/api/chat_api_service.dart';
import '../../../core/services/search/search_tool_service.dart';
import '../../../core/providers/model_provider.dart';
import '../../../core/providers/user_provider.dart';
import '../../../core/services/chat/prompt_transformer.dart';

class VoiceChatScreen extends StatelessWidget {
  const VoiceChatScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer5<ChatService, SettingsProvider, AssistantProvider, TtsProvider, UserProvider>(
      builder: (context, chatService, settings, assistantProvider, ttsProvider, userProvider, child) {
        return VoiceChatScreenView(
          chatService: chatService,
          settings: settings,
          assistantProvider: assistantProvider,
          ttsProvider: ttsProvider,
          userProvider: userProvider,
        );
      }
    );
  }
}

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
  static const MethodChannel _callModeChannel = MethodChannel('omnichat/call_mode');

  // Voice chat state: listening, thinking, talking
  VoiceChatState _currentState = VoiceChatState.listening;
  bool _isPaused = false;
  bool _showSubtitles = true;
  String _currentSubtitle = '';
  String _recognizedText = '';
  Timer? _voiceStopTimer;
  bool _hasMicrophonePermission = false;

  // Speech recognition
  final SpeechToText _speechToText = SpeechToText();
  bool _isListening = false;
  bool _speechEngineReady = false;
  bool _manualStopInProgress = false;

  // Timer to restart listening if it stops unexpectedly
  Timer? _restartListeningTimer;
  Timer? _listeningWatchdog;

  bool _isToolModel(String providerKey, String modelId) {
    final settings = widget.settings;
    final cfg = settings.getProviderConfig(providerKey);
    final ov = cfg.modelOverrides[modelId] as Map?;
    if (ov != null) {
      final abilities = (ov['abilities'] as List?)?.map((e) => e.toString()).toList() ?? const [];
      if (abilities.map((e) => e.toLowerCase()).contains('tool')) return true;
    }
    final inferred = ModelRegistry.infer(ModelInfo(id: modelId, displayName: modelId));
    return inferred.abilities.contains(ModelAbility.tool);
  }

  @override
  void initState() {
    super.initState();
    _initAudioSessionForVoiceChat();
    _initBackgroundService();
    _initializeSpeechEngine();
    _enterCallMode();
    _checkMicrophonePermission();
    _loadVersionSelections();
  }

  Future<void> _initBackgroundService() async {
    const androidConfig = FlutterBackgroundAndroidConfig(
      notificationTitle: "OmniChat Voice Chat",
      notificationText: "Voice chat is active.",
      notificationIcon: AndroidResource(name: 'ic_launcher', defType: 'mipmap'),
    );
    await FlutterBackground.initialize(androidConfig: androidConfig);
    await FlutterBackground.enableBackgroundExecution();
  }

  Future<void> _enterCallMode() async {
    try {
      await _callModeChannel.invokeMethod('startCallMode');
    } catch (e) {
      print('Failed to enter call mode: $e');
    }
  }

  Future<void> _exitCallMode() async {
    try {
      await _callModeChannel.invokeMethod('stopCallMode');
    } catch (e) {
      print('Failed to exit call mode: $e');
    }
  }

  Future<void> _initAudioSessionForVoiceChat() async {
    final session = await AudioSession.instance;
    await session.configure(AudioSessionConfiguration(
      avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
      avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.allowBluetooth |
          AVAudioSessionCategoryOptions.mixWithOthers,
      avAudioSessionMode: AVAudioSessionMode.voiceChat,
      androidAudioAttributes: AndroidAudioAttributes(
        contentType: AndroidAudioContentType.speech,
        flags: AndroidAudioFlags.none,
        usage: AndroidAudioUsage.voiceCommunication,
      ),
      androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
      androidWillPauseWhenDucked: false,
    ));

    // Activate the session to ensure proper audio routing
    await session.setActive(true);
  }

  Map<String, int> _versionSelections = <String, int>{};

  void _loadVersionSelections() {
    final cid = widget.chatService.currentConversationId;
    if (cid == null) {
      _versionSelections = <String, int>{};
      return;
    }
    try {
      _versionSelections = widget.chatService.getVersionSelections(cid);
    } catch (_) {
      _versionSelections = <String, int>{};
    }
  }

  List<ChatMessage> _collapseVersions(List<ChatMessage> items) {
    final Map<String, List<ChatMessage>> byGroup = <String, List<ChatMessage>>{};
    final List<String> order = <String>[];
    for (final m in items) {
      final gid = (m.groupId ?? m.id);
      final list = byGroup.putIfAbsent(gid, () {
        order.add(gid);
        return <ChatMessage>[];
      });
      list.add(m);
    }
    for (final e in byGroup.entries) {
      e.value.sort((a, b) => a.version.compareTo(b.version));
    }
    final out = <ChatMessage>[];
    for (final gid in order) {
      final vers = byGroup[gid]!;
      final sel = _versionSelections[gid];
      final idx = (sel != null && sel >= 0 && sel < vers.length) ? sel : (vers.length - 1);
      out.add(vers[idx]);
    }
    return out;
  }

  @override
  void dispose() {
    // Cancel all timers
    _voiceStopTimer?.cancel();
    _restartListeningTimer?.cancel();
    _listeningWatchdog?.cancel();

    // Stop speech recognition
    if (_isListening) {
      _speechToText.stop();
    }

    // Stop TTS
    widget.ttsProvider.stop();

    // Exit call mode (stops SCO keep-alive and Bluetooth SCO)
    _exitCallMode();

    // Deactivate audio session and background execution after a short delay
    // to ensure navigation completes first
    Future.delayed(const Duration(milliseconds: 100), () {
      AudioSession.instance.then((session) {
        session.setActive(false);
      });
      FlutterBackground.disableBackgroundExecution();
    });

    super.dispose();
  }

  Future<void> _checkMicrophonePermission() async {
    final status = await Permission.microphone.request();
    setState(() {
      _hasMicrophonePermission = status == PermissionStatus.granted;
    });

    if (_hasMicrophonePermission) {
      _startVoiceRecognition();
    } else {
      // Show permission request overlay
    }
  }

  Future<void> _initializeSpeechEngine() async {
    if (_speechEngineReady) return;
    try {
      final ok = await _speechToText.initialize(
        onStatus: _handleSpeechStatus,
        onError: _handleSpeechError,
      );
      if (ok) {
        setState(() {
          _speechEngineReady = true;
        });
      }
    } catch (e) {
      setState(() {
        final localization = AppLocalizations.of(context);
        _currentSubtitle = localization?.voiceChatErrorInitFailed ?? 'Failed to initialize voice recognition';
      });
    }
  }

  void _handleSpeechStatus(String status) {
    // Ignore status updates if we're not supposed to be listening
    if (_currentState != VoiceChatState.listening || _isPaused) return;

    if (status == 'done' || status == 'notListening') {
      if (_manualStopInProgress) {
        _manualStopInProgress = false;
        return;
      }
      // System-initiated stop - restart quickly
      _isListening = false;
      _scheduleRestart(const Duration(milliseconds: 150));
    }
  }

  void _handleSpeechError(SpeechRecognitionError error) {
    // Ignore errors if we're not supposed to be listening
    if (_currentState != VoiceChatState.listening || _isPaused) return;

    // Don't show error for common timeout errors, just restart
    final errorMsg = error.errorMsg.toLowerCase();
    if (errorMsg.contains('no match') || errorMsg.contains('speech timeout') || errorMsg.contains('no speech')) {
      // These are expected when user is silent, just restart
      _isListening = false;
      _scheduleRestart(const Duration(milliseconds: 200));
      return;
    }

    // For other errors, show briefly then restart
    setState(() {
      final localization = AppLocalizations.of(context);
      _currentSubtitle = localization?.voiceChatError(error.errorMsg) ?? 'Error: ${error.errorMsg}';
    });
    _isListening = false;
    _scheduleRestart(const Duration(milliseconds: 500));
  }

  void _scheduleRestart(Duration delay) {
    _restartListeningTimer?.cancel();
    _restartListeningTimer = Timer(delay, () {
      if (!mounted || _currentState != VoiceChatState.listening || _isPaused) return;
      _doStartListening();
    });
  }

  Future<void> _startVoiceRecognition() async {
    if (!_hasMicrophonePermission || !_speechEngineReady) {
      return;
    }

    // Cancel any existing timers
    _restartListeningTimer?.cancel();
    _listeningWatchdog?.cancel();

    // Make sure audio session is active for Bluetooth call simulation
    try {
      final session = await AudioSession.instance;
      await session.setActive(true);
    } catch (e) {
      print('Could not activate audio session: $e');
    }

    // Start the actual listening
    await _doStartListening();

    // Set up a watchdog that proactively restarts listening every 4 seconds
    // This beats Android's ~6 second timeout by restarting before it triggers
    _listeningWatchdog = Timer.periodic(const Duration(seconds: 4), (timer) {
      if (!mounted || _currentState != VoiceChatState.listening || _isPaused) {
        timer.cancel();
        return;
      }
      // Proactively stop and restart to prevent Android timeout
      _forceRestartListening();
    });

    setState(() {
      _currentState = VoiceChatState.listening;
      _currentSubtitle = '';
    });
  }

  /// Force restart listening - stops current session and starts a new one
  Future<void> _forceRestartListening() async {
    if (!mounted || _currentState != VoiceChatState.listening || _isPaused) return;

    // Stop current listening session without triggering manual stop flag
    try {
      await _speechToText.stop();
    } catch (e) {
      print('Error stopping speech: $e');
    }

    // Small delay to allow the engine to reset
    await Future.delayed(const Duration(milliseconds: 100));

    // Start listening again
    if (mounted && _currentState == VoiceChatState.listening && !_isPaused) {
      await _doStartListening();
    }
  }

  /// Actually start the speech recognition
  Future<void> _doStartListening() async {
    if (!_hasMicrophonePermission || !_speechEngineReady) return;
    if (!mounted || _isPaused) return;

    _isListening = true;
    try {
      await _speechToText.listen(
        onResult: (result) {
          final recognizedText = result.recognizedWords;
          setState(() {
            _currentSubtitle = recognizedText;
          });

          if (result.finalResult && recognizedText.isNotEmpty) {
            _recognizedText = recognizedText;
            _processVoiceInput(recognizedText);
          }
        },
        listenMode: ListenMode.dictation,
        pauseFor: const Duration(seconds: 30),
        cancelOnError: false,
        listenFor: const Duration(minutes: 10),
        partialResults: true,
      );
    } catch (e) {
      print('Error starting speech recognition: $e');
      _isListening = false;
      // Try to restart after a short delay
      _scheduleRestart(const Duration(milliseconds: 500));
    }
  }

  Future<void> _processVoiceInput(String text) async {
    if (text.isEmpty) return;

    if (_isListening) {
      _manualStopInProgress = true;
      await _speechToText.stop();
      _isListening = false;
      _restartListeningTimer?.cancel();
      _listeningWatchdog?.cancel();
    }

    Future.delayed(Duration.zero, () {
      _sendToLLM(text);
    });
  }

  // Send the recognized text to LLM using providers from context
  Future<void> _sendToLLM(String text) async {
    if (text.isEmpty) return;

    if (_isListening) {
      _manualStopInProgress = true;
      await _speechToText.stop();
      _isListening = false;
      _restartListeningTimer?.cancel();
      _listeningWatchdog?.cancel();
    }

    final localization = AppLocalizations.of(context);
    setState(() {
      _currentState = VoiceChatState.thinking;
      // Keep the recognized text as subtitle during thinking, or show a brief indicator if needed
      _currentSubtitle = _recognizedText.isNotEmpty ? _recognizedText : (localization?.voiceChatProcessing ?? 'Processing...');
    });

    try {
      // Use the widget's properties instead of reading from context
      final chatService = widget.chatService;
      final settings = widget.settings;
      final assistantProvider = widget.assistantProvider;
      final assistant = assistantProvider.currentAssistant;

      // Preserve assistant system prompt and conversation context
      final voiceChatText = text;

      // Get the current conversation using the currentConversationId
      final currentConversationId = chatService.currentConversationId;
      if (currentConversationId != null) {
        // Get the current conversation
        final currentConversation = chatService.getConversation(currentConversationId);
        if (currentConversation != null) {
          // Add user message to the conversation
          await chatService.addMessage(
            conversationId: currentConversationId,
            role: 'user',
            content: voiceChatText,
          );

          // Add to local messages list too if needed
          // Generate the assistant response by calling home page's _sendMessage equivalent logic
          // Since we can't directly access the home page's logic, we'll need to create the assistant message
          final assistantMessage = await chatService.addMessage(
            conversationId: currentConversationId,
            role: 'assistant',
            content: '',
            isStreaming: true,
          );

          // Update UI state
          final localization = AppLocalizations.of(context);
          setState(() {
            _currentState = VoiceChatState.thinking;
            // Keep the recognized text as subtitle during thinking
            _currentSubtitle = _recognizedText.isNotEmpty ? _recognizedText : (localization?.voiceChatProcessing ?? 'Processing...');
          });

          // Get settings and assistant from widget properties
          final currentSettings = widget.settings;
          final currentAssistant = widget.assistantProvider.currentAssistant;

          // Send message using the API service (following similar pattern to home page)
          final providerKey = currentAssistant?.chatModelProvider ?? currentSettings.currentModelProvider;
          final modelId = currentAssistant?.chatModelId ?? currentSettings.currentModelId;

          if (providerKey != null && modelId != null) {
            final config = currentSettings.getProviderConfig(providerKey);

            // --- CONTEXT BUILDING ---
            final allMessages = chatService.getMessages(currentConversationId);
            final messagesForContext = [...allMessages];

            final tIndex = currentConversation.truncateIndex;
            final List<ChatMessage> sourceAll = (tIndex >= 0 && tIndex < messagesForContext.length)
                ? messagesForContext.sublist(tIndex)
                : List.of(messagesForContext);

            final List<ChatMessage> source = _collapseVersions(sourceAll);

            var apiMessages = source
                .where((m) => m.content.isNotEmpty)
                .map((m) {
                  return {
                    'role': m.role == 'assistant' ? 'assistant' : 'user',
                    'content': m.content,
                  };
                })
                .toList();

            // Inject system prompt
            if ((assistant?.systemPrompt.trim().isNotEmpty ?? false)) {
              final vars = PromptTransformer.buildPlaceholders(
                context: context,
                assistant: assistant!,
                modelId: modelId,
                modelName: modelId,
                userNickname: widget.userProvider.name,
              );
              final sys = PromptTransformer.replacePlaceholders(assistant.systemPrompt, vars);
              apiMessages.insert(0, {'role': 'system', 'content': sys});
            }
            // --- END CONTEXT BUILDING ---

            final supportsTools = _isToolModel(providerKey, modelId);
            final hasBuiltInSearch = (providerKey == 'google' && (modelId.contains('1.5') || modelId.contains('gemini-pro')));

            if (settings.searchEnabled && !hasBuiltInSearch) {
              final prompt = SearchToolService.getSystemPrompt();
              if (apiMessages.isNotEmpty && apiMessages.first['role'] == 'system') {
                apiMessages[0]['content'] = '${apiMessages[0]['content'] ?? ''}\n\n$prompt';
              } else {
                apiMessages.insert(0, {'role': 'system', 'content': prompt});
              }
            }

            final List<Map<String, dynamic>> toolDefs = <Map<String, dynamic>>[];
            Future<String> Function(String, Map<String, dynamic>)? onToolCall;

            if (settings.searchEnabled && !hasBuiltInSearch && supportsTools) {
              toolDefs.add(SearchToolService.getToolDefinition());
            }

            if (toolDefs.isNotEmpty) {
              onToolCall = (name, args) async {
                if (name == SearchToolService.toolName && settings.searchEnabled) {
                  final q = (args['query'] ?? '').toString();
                  return await SearchToolService.executeSearch(q, settings);
                }
                return '';
              };
            }

            // Create stream for response
            Stream<dynamic> stream;
            try {
              stream = await ChatApiService.sendMessageStream(
                config: config,
                modelId: modelId,
                messages: apiMessages,
                userImagePaths: const [],
                thinkingBudget: currentAssistant?.thinkingBudget ?? currentSettings.thinkingBudget,
                temperature: currentAssistant?.temperature,
                topP: currentAssistant?.topP,
                maxTokens: currentAssistant?.maxTokens,
                tools: toolDefs.isEmpty ? null : toolDefs,
                onToolCall: onToolCall,
                extraHeaders: null,
                extraBody: null,
                stream: true,
              );
            } catch (apiError) {
              if (mounted) {
                setState(() {
                  final localization = AppLocalizations.of(context);
                  _currentSubtitle = localization?.voiceChatErrorApi(apiError.toString()) ?? 'API error: ${apiError.toString()}';
                });
              }
              _startVoiceRecognition();
              return;
            }

            String fullContent = '';
            try {
              await for (final chunk in stream) {
                // Add the chunk content to full content
                fullContent += chunk.content ?? '';
                // Update subtitle with partial content
                setState(() {
                  _currentSubtitle = fullContent;
                });

                // Update the assistant message with the streamed content
                await chatService.updateMessage(assistantMessage.id, content: fullContent);
              }
            } catch (chunkError) {
              setState(() {
                final localization = AppLocalizations.of(context);
                _currentSubtitle = localization?.voiceChatErrorProcessingResponse(chunkError.toString()) ?? 'Error processing response: ${chunkError.toString()}';
              });
            }

            // Finish the assistant message
            await chatService.updateMessage(
              assistantMessage.id,
              content: fullContent,
              isStreaming: false,
            );

            if (fullContent.isNotEmpty) {
              // Switch to talking state before playing TTS
              setState(() {
                _currentState = VoiceChatState.talking;
                _currentSubtitle = fullContent; // Show the response during talking state
              });

              try {
                // Play the response using TTS and wait for completion
                await widget.ttsProvider.speak(fullContent);

                // After TTS completes, return to listening
                setState(() {
                  _currentState = VoiceChatState.listening;
                  _currentSubtitle = ''; // Clear subtitle when returning to listening
                });
              } catch (e) {
                // Handle TTS error but stay in talking state briefly before returning to listening
                setState(() {
                  final localization = AppLocalizations.of(context);
                  _currentSubtitle = localization?.voiceChatErrorTts(e.toString()) ?? 'TTS error: ${e.toString()}';
                });
              }

              // Restart listening
              _startVoiceRecognition();
            } else {
              // If no content, return to listening
              setState(() {
                _currentState = VoiceChatState.listening;
                _currentSubtitle = ''; // Clear subtitle when returning to listening
              });

              _startVoiceRecognition();
            }
          } else {
            // No provider/model set, show error and return to listening
            setState(() {
              final localization = AppLocalizations.of(context);
              _currentSubtitle = localization?.voiceChatErrorNoModel ?? 'No model selected';
            });

            _startVoiceRecognition();
          }
        } else {
          // Conversation not found, show error
          setState(() {
            final localization = AppLocalizations.of(context);
            _currentSubtitle = localization?.voiceChatErrorNoConversation ?? 'No conversation found';
          });

          _startVoiceRecognition();
        }
      } else {
        // If no current conversation, show error
        setState(() {
          final localization = AppLocalizations.of(context);
          _currentSubtitle = localization?.voiceChatErrorNoActiveConversation ?? 'No active conversation';
        });

        _startVoiceRecognition();
      }

    } catch (e) {
      setState(() {
        final localization = AppLocalizations.of(context);
        _currentSubtitle = localization?.voiceChatError(e.toString()) ?? 'Error: ${e.toString()}';
      });

      // Restart listening even on error
      _startVoiceRecognition();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
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
                      onPressed: () => Navigator.of(context).pop(),
                      icon: Icon(Lucide.X, color: Colors.white),
                    ),
                    const Spacer(),
                    Text(
                      l10n.voiceChatTitle,
                      style: TextStyle(
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
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
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
                          child: Text(
                            _currentSubtitle,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 16,
                              color: Colors.white,
                            ),
                          ),
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
                      onTap: _togglePause,
                      child: Container(
                        width: 60,
                        height: 60,
                        child: Icon(
                          _isPaused ? Lucide.Play : Lucide.Pause,
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
          if (!_hasMicrophonePermission)
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
                      style: TextStyle(
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
                        l10n.voiceChatPermissionSubtitle,
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.white70,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: _requestMicrophonePermission,
                      child: Text(l10n.voiceChatPermissionButton),
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
    switch (_currentState) {
      case VoiceChatState.listening:
        return l10n.voiceChatListening;
      case VoiceChatState.thinking:
        return l10n.voiceChatThinking;
      case VoiceChatState.talking:
        return l10n.voiceChatTalking;
    }
  }

  Color _getStateColor(ColorScheme cs) {
    switch (_currentState) {
      case VoiceChatState.listening:
        return Colors.green.shade400;
      case VoiceChatState.thinking:
        return Colors.orange.shade400;
      case VoiceChatState.talking:
        return Colors.blue.shade400;
    }
  }

  void _requestMicrophonePermission() async {
    final status = await Permission.microphone.request();
    setState(() {
      _hasMicrophonePermission = status == PermissionStatus.granted;
    });

    if (_hasMicrophonePermission) {
      _startVoiceRecognition();
    }
  }

  void _togglePause() {
    setState(() {
      _isPaused = !_isPaused;
    });

    if (_isPaused) {
      if (_isListening) {
        _manualStopInProgress = true;
        _speechToText.stop();
        _isListening = false;
        _restartListeningTimer?.cancel();
        _listeningWatchdog?.cancel();
      }
    } else {
      if (_currentState == VoiceChatState.listening) {
        _startVoiceRecognition();
      }
    }
  }

  void _endVoiceChat() {
    // Simply navigate back - all cleanup will be handled by dispose()
    Navigator.of(context).pop();
  }

  void _toggleSubtitle() {
    setState(() {
      _showSubtitles = !_showSubtitles;
    });
  }
}

enum VoiceChatState { listening, thinking, talking }

