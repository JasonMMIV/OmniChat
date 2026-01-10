import 'dart:io';
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
  bool _isCleaningUp = false;

  // Speech recognition
  final SpeechToText _speechToText = SpeechToText();
  bool _isListening = false;
  bool _speechEngineReady = false;
  bool _manualStopInProgress = false;
  Map<String, int> _versionSelections = {};

  // Timer to restart listening if it stops unexpectedly
  Timer? _restartListeningTimer;
  Timer? _listeningWatchdog;

  // Flag to track if we're in the process of handling voice input
  bool _isProcessingVoiceInput = false;

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
    _startUp();
  }

  Future<void> _startUp() async {
    print('[OmniChat Dart] _startUp: Starting...');
    if (Platform.isAndroid || Platform.isIOS) {
      await _initAudioSessionForVoiceChat();
    }
    if (Platform.isAndroid) {
      await _initBackgroundService();
    }

    // Must initialize speech engine first, then check permission
    // Previously these were running concurrently, causing race condition
    print('[OmniChat Dart] _startUp: Initializing speech engine...');
    await _initializeSpeechEngine();
    print('[OmniChat Dart] _startUp: Speech engine initialized. Ready: $_speechEngineReady');
    
    print('[OmniChat Dart] _startUp: Checking microphone permission...');
    await _checkMicrophonePermission();
    print('[OmniChat Dart] _startUp: Permission checked. Granted: $_hasMicrophonePermission');

    _loadVersionSelections();

    // Initialize call mode (Bluetooth/Speaker handling)
    if (Platform.isAndroid) {
      await _initializeCallMode();
    }
    print('[OmniChat Dart] _startUp: Completed.');
  }

  Future<void> _checkMicrophonePermission() async {
    print('[OmniChat Dart] _checkMicrophonePermission: Requesting permission...');
    final status = await Permission.microphone.request();
    print('[OmniChat Dart] _checkMicrophonePermission: Status: $status');
    if (mounted) {
      setState(() {
        _hasMicrophonePermission = status == PermissionStatus.granted;
      });
    }

    if (_hasMicrophonePermission) {
      print('[OmniChat Dart] _checkMicrophonePermission: Permission granted, starting recognition...');
      _startVoiceRecognition();
    } else {
      print('[OmniChat Dart] _checkMicrophonePermission: Permission denied.');
    }
  }

  Future<void> _initializeSpeechEngine() async {
    if (_speechEngineReady) {
        print('[OmniChat Dart] _initializeSpeechEngine: Already ready.');
        return;
    }
    try {
      print('[OmniChat Dart] _initializeSpeechEngine: Calling speechToText.initialize()...');
      final ok = await _speechToText.initialize(
        onStatus: _handleSpeechStatus,
        onError: _handleSpeechError,
        debugLogging: true, // Enable debug logging in package
      );
      print('[OmniChat Dart] _initializeSpeechEngine: initialize returned: $ok');
      if (ok) {
        if (mounted) {
          setState(() {
            _speechEngineReady = true;
          });
        }
      } else {
        if (mounted) {
          setState(() {
            final localization = AppLocalizations.of(context);
            _currentSubtitle = localization?.voiceChatErrorInitFailed ?? 'Failed to initialize voice recognition';
          });
        }
      }
    } catch (e) {
      print('[OmniChat Dart] _initializeSpeechEngine: Exception: $e');
      if (mounted) {
        setState(() {
          final localization = AppLocalizations.of(context);
          _currentSubtitle = localization?.voiceChatErrorInitFailed ?? 'Failed to initialize voice recognition';
        });
      }
    }
  }

  void _handleSpeechStatus(String status) {
    if (_isCleaningUp) return;

    // Don't restart if this was a manual stop
    if (_manualStopInProgress) {
      if (status == 'done' || status == 'notListening') {
        _manualStopInProgress = false;
        _isListening = false;
      }
      return;
    }

    if (status == 'done' || status == 'notListening') {
      _isListening = false;
      // Always try to restart if we were listening and not paused
      if (!_isPaused && mounted && _currentState == VoiceChatState.listening && !_isProcessingVoiceInput) {
        _scheduleRestart(const Duration(milliseconds: 100));
      }
    }
  }

  void _handleSpeechError(SpeechRecognitionError error) {
    if (_isCleaningUp) return;

    _isListening = false;

    // Don't restart if this was a manual stop
    if (_manualStopInProgress) {
      _manualStopInProgress = false;
      return;
    }

    // Don't show error for common timeout errors, just restart
    final errorMsg = error.errorMsg.toLowerCase();
    if (errorMsg.contains('no match') ||
        errorMsg.contains('speech timeout') ||
        errorMsg.contains('no speech') ||
        errorMsg.contains('error_speech_timeout') ||
        errorMsg.contains('error_no_match') ||
        errorMsg.contains('listening cancelled') ||
        errorMsg.contains('error_interruption') ||
        errorMsg.contains('error_client') ||
        errorMsg.contains('error_recognizer_busy')) {
      if (!_isPaused && mounted && _currentState == VoiceChatState.listening && !_isProcessingVoiceInput) {
        _scheduleRestart(const Duration(milliseconds: 100));
      }
      return;
    }

    setState(() {
      final localization = AppLocalizations.of(context);
      _currentSubtitle = localization?.voiceChatError(error.errorMsg) ?? 'Error: ${error.errorMsg}';
    });

    if (!_isPaused && mounted && _currentState == VoiceChatState.listening && !_isProcessingVoiceInput) {
      _scheduleRestart(const Duration(milliseconds: 500));
    }
  }

  void _scheduleRestart(Duration delay) {
    if (_isCleaningUp) return;
    
    print('Scheduling restart in ${delay.inMilliseconds}ms'); // Debug print
    _restartListeningTimer?.cancel();
    _restartListeningTimer = Timer(delay, () {
      if (_isCleaningUp) return;
      
      print('Restart timer executed, mounted=$mounted, paused=$_isPaused, currentState=$_currentState'); // Debug print
      // Check if mounted, not paused, AND in listening state
      if (mounted && !_isPaused && _currentState == VoiceChatState.listening && !_isProcessingVoiceInput) {
        print('Attempting to restart listening'); // Debug print
        _doStartListening();
      }
    });
  }

  Future<void> _startVoiceRecognition() async {
    print('[OmniChat Dart] _startVoiceRecognition: checking preconditions...');
    if (!_hasMicrophonePermission || !_speechEngineReady || _isCleaningUp) {
      print('[OmniChat Dart] _startVoiceRecognition: Aborted. perm=$_hasMicrophonePermission, ready=$_speechEngineReady, cleanup=$_isCleaningUp');
      return;
    }

    // Cancel any existing restart timer
    _restartListeningTimer?.cancel();

    // Make sure audio session is active for Bluetooth call simulation (Mobile only)
    if (Platform.isAndroid || Platform.isIOS) {
      try {
        final session = await AudioSession.instance;
        await session.setActive(true);
      } catch (_) {}
    }

    setState(() {
      _currentState = VoiceChatState.listening;
      _currentSubtitle = '';
    });

    // Start the actual listening
    print('[OmniChat Dart] _startVoiceRecognition: calling _doStartListening...');
    await _doStartListening();
  }

  void _startVoiceRecognitionAfterProcessing() {
    print('[OmniChat Dart] _startVoiceRecognitionAfterProcessing called');
    // Reset processing flag before starting recognition again
    _isProcessingVoiceInput = false;
    // Only restart if we're in the listening state
    if (_currentState == VoiceChatState.listening && !_isPaused && mounted) {
      _startVoiceRecognition();
    }
  }

  /// Actually start the speech recognition
  Future<void> _doStartListening() async {
    print('[OmniChat Dart] _doStartListening: Begin');
    if (_isCleaningUp) { print('[OmniChat Dart] _doStartListening: Cleaning up, abort'); return; }
    if (!_hasMicrophonePermission || !_speechEngineReady) { print('[OmniChat Dart] _doStartListening: Not ready/perm, abort'); return; }
    if (!mounted || _isPaused || _currentState != VoiceChatState.listening || _isProcessingVoiceInput) {
       print('[OmniChat Dart] _doStartListening: State check failed. mounted=$mounted, paused=$_isPaused, state=$_currentState, proc=$_isProcessingVoiceInput');
       return;
    }

    _isListening = true;
    try {
      // Attempt to resolve the best matching locale for the system
      String? selectedLocaleId;

      try {
        print('[OmniChat Dart] _doStartListening: Fetching locales...');
        final systemLocales = await _speechToText.locales();
        print('[OmniChat Dart] _doStartListening: Locales fetched: ${systemLocales.length}');

        if (systemLocales.isNotEmpty) {
           // Use the app's configured locale from SettingsProvider, not the localization locale
           final settingsLocale = widget.settings.appLocale;
           final localeTag = '${settingsLocale.languageCode}${settingsLocale.scriptCode != null ? '_${settingsLocale.scriptCode}' : ''}${settingsLocale.countryCode != null ? '_${settingsLocale.countryCode}' : ''}';

           // Also check if following system locale
           final isSystemLocale = widget.settings.isFollowingSystemLocale;

           // Normalize app locale to lower case with hyphens for comparison
           // e.g., zh_Hant -> zh-hant, zh_CN -> zh-cn
           final normalizedAppLocale = localeTag.toLowerCase().replaceAll('_', '-');

           print('[OmniChat Dart] Settings locale: $settingsLocale (tag: $localeTag), isSystemLocale: $isSystemLocale');
           print('[OmniChat Dart] Normalized app locale: $normalizedAppLocale');
           print('[OmniChat Dart] Available system locales: ${systemLocales.map((l) => l.localeId).toList()}');

           // 1. Try exact match (insensitive)
           try {
             selectedLocaleId = systemLocales.firstWhere(
               (l) => l.localeId.toLowerCase().replaceAll('_', '-') == normalizedAppLocale
             ).localeId;
             print('[OmniChat Dart] Exact match found: $selectedLocaleId');
           } catch (_) {
             // 2. Special mapping for Chinese variants (common issue on Windows)
             if (normalizedAppLocale.startsWith('zh')) {
               if (normalizedAppLocale.contains('hant') || normalizedAppLocale.contains('tw') || normalizedAppLocale.contains('hk')) {
                 // Traditional: try TW, HK
                 try {
                   selectedLocaleId = systemLocales.firstWhere(
                     (l) {
                       final lid = l.localeId.toLowerCase();
                       return lid.contains('zh-tw') || lid.contains('zh-hk') || lid.contains('tw') || lid.contains('hk');
                     }
                   ).localeId;
                   print('[OmniChat Dart] Chinese Traditional match found: $selectedLocaleId');
                 } catch (_) {
                   // If no Traditional, try any Chinese
                   try {
                     selectedLocaleId = systemLocales.firstWhere(
                       (l) => l.localeId.toLowerCase().startsWith('zh')
                     ).localeId;
                     print('[OmniChat Dart] Chinese fallback match found: $selectedLocaleId');
                   } catch (_) {}
                 }
               } else {
                 // Simplified: try CN first, then any Chinese
                 try {
                   selectedLocaleId = systemLocales.firstWhere(
                     (l) => l.localeId.toLowerCase().contains('zh-cn') || l.localeId.toLowerCase().contains('cn')
                   ).localeId;
                   print('[OmniChat Dart] Chinese Simplified match found: $selectedLocaleId');
                 } catch (_) {
                   // If no Simplified, try any Chinese
                   try {
                     selectedLocaleId = systemLocales.firstWhere(
                       (l) => l.localeId.toLowerCase().startsWith('zh')
                     ).localeId;
                     print('[OmniChat Dart] Chinese fallback match found: $selectedLocaleId');
                   } catch (_) {}
                 }
               }
             }

             // 3. General language match (e.g. en_US -> en_GB if US not found)
             if (selectedLocaleId == null) {
               final appLang = normalizedAppLocale.split('-')[0];
               try {
                 selectedLocaleId = systemLocales.firstWhere(
                   (l) => l.localeId.toLowerCase().startsWith(appLang)
                 ).localeId;
                 print('[OmniChat Dart] Language fallback match found: $selectedLocaleId');
               } catch (_) {}
             }
           }
        }
        
        // 4. Force fallback if still null (Best Effort)
        // This handles cases where systemLocales list is incomplete (e.g. Windows WinRT restriction)
        // but the language pack is actually installed.
        if (selectedLocaleId == null) {
           final settingsLocale = widget.settings.appLocale;
           final localeTag = '${settingsLocale.languageCode}${settingsLocale.scriptCode != null ? '_${settingsLocale.scriptCode}' : ''}${settingsLocale.countryCode != null ? '_${settingsLocale.countryCode}' : ''}';
           final normalizedAppLocale = localeTag.toLowerCase().replaceAll('_', '-');
           
           if (normalizedAppLocale.contains('zh')) {
             if (normalizedAppLocale.contains('hant') || normalizedAppLocale.contains('tw') || normalizedAppLocale.contains('hk')) {
               selectedLocaleId = 'zh-TW';
             } else {
               selectedLocaleId = 'zh-CN';
             }
           } else {
             // For other languages, use the standard tag (e.g. ja-JP, ko-KR)
             // Best effort: construct a valid BCP-47 tag
             if (settingsLocale.countryCode != null) {
               selectedLocaleId = '${settingsLocale.languageCode}-${settingsLocale.countryCode}';
             } else {
               selectedLocaleId = settingsLocale.languageCode;
             }
           }
           print('[OmniChat Dart] Forced fallback locale: $selectedLocaleId');
        }

      } catch (e) {
        print('[OmniChat Dart] Error getting locales: $e');
      }

      print('[OmniChat Dart] Final selected locale: $selectedLocaleId');
      print('[OmniChat Dart] Calling _speechToText.listen()...');

      await _speechToText.listen(
        onResult: (result) {
          if (_isCleaningUp) return;

          final recognizedText = result.recognizedWords;
          setState(() {
            _currentSubtitle = recognizedText;
          });

          // When we get a final result, restart listening after processing
          if (result.finalResult && recognizedText.isNotEmpty) {
            _recognizedText = recognizedText;
            _isListening = false;
            _isProcessingVoiceInput = true;
            _processVoiceInput(recognizedText);
          } else if (result.finalResult && recognizedText.isEmpty) {
            _isListening = false;
          }
        },
        listenMode: ListenMode.dictation,
        localeId: selectedLocaleId,
        cancelOnError: false,
        partialResults: true,
      );
      print('[OmniChat Dart] _speechToText.listen() returned.');
    } catch (e) {
      print('[OmniChat Dart] _doStartListening Exception: $e');
      _isListening = false;
      if (!_isPaused && mounted) {
        _scheduleRestart(const Duration(milliseconds: 500));
      }
    }
  }

  Future<void> _processVoiceInput(String text) async {
    print('[OmniChat Dart] _processVoiceInput: $text');
    if (text.isEmpty) return;

    if (_isListening) {
      _manualStopInProgress = true;
      await _speechToText.stop();
      _isListening = false;
      _restartListeningTimer?.cancel();
    }

    // After processing the voice input, ensure we restart listening
    // once the LLM response is complete
    _sendToLLM(text);
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
              _startVoiceRecognitionAfterProcessing();
              return;
            }

            String fullContent = '';
            try {
              await for (final chunk in stream) {
                // Add the chunk content to full content
                fullContent += chunk.content ?? '';
                // Update subtitle with partial content
                if (mounted) {
                  setState(() {
                    _currentSubtitle = fullContent;
                  });
                }

                // Update the assistant message with the streamed content
                await chatService.updateMessage(assistantMessage.id, content: fullContent);
              }
            } catch (chunkError) {
              if (mounted) {
                setState(() {
                  final localization = AppLocalizations.of(context);
                  _currentSubtitle = localization?.voiceChatErrorProcessingResponse(chunkError.toString()) ?? 'Error processing response: ${chunkError.toString()}';
                });
              }
            }

            // Finish the assistant message
            await chatService.updateMessage(
              assistantMessage.id,
              content: fullContent,
              isStreaming: false,
            );

            if (fullContent.isNotEmpty) {
              // Switch to talking state before playing TTS
              if (mounted) {
                setState(() {
                  _currentState = VoiceChatState.talking;
                  _currentSubtitle = fullContent; // Show the response during talking state
                });
              }

              try {
                // Play the response using TTS and wait for completion
                await widget.ttsProvider.speak(fullContent);

                // After TTS completes, return to listening
                if (mounted) {
                  setState(() {
                    _currentState = VoiceChatState.listening;
                    _currentSubtitle = ''; // Clear subtitle when returning to listening
                  });
                }

                // Only restart listening after TTS completes if we're still in listening state
                if (_currentState == VoiceChatState.listening) {
                  _startVoiceRecognitionAfterProcessing();
                }
              } catch (e) {
                // Handle TTS error but stay in talking state briefly before returning to listening
                if (mounted) {
                  setState(() {
                    final localization = AppLocalizations.of(context);
                    _currentSubtitle = localization?.voiceChatErrorTts(e.toString()) ?? 'TTS error: ${e.toString()}';
                  });
                }

                // Even if TTS fails, we should still return to listening state and restart recognition
                if (mounted) {
                  setState(() {
                    _currentState = VoiceChatState.listening;
                  });
                }

                if (_currentState == VoiceChatState.listening) {
                  _startVoiceRecognitionAfterProcessing();
                }
              }
            } else {
              // If no content, return to listening
              if (mounted) {
                setState(() {
                  _currentState = VoiceChatState.listening;
                  _currentSubtitle = ''; // Clear subtitle when returning to listening
                });
              }

              if (_currentState == VoiceChatState.listening) {
                _startVoiceRecognitionAfterProcessing();
              }
            }
          } else {
            // No provider/model set, show error and return to listening
            if (mounted) {
              setState(() {
                _currentState = VoiceChatState.listening;
                final localization = AppLocalizations.of(context);
                _currentSubtitle = localization?.voiceChatErrorNoModel ?? 'No model selected';
              });
            }

            if (_currentState == VoiceChatState.listening) {
              _startVoiceRecognitionAfterProcessing();
            }
          }
        } else {
          // Conversation not found, show error
          if (mounted) {
            setState(() {
              _currentState = VoiceChatState.listening;
              final localization = AppLocalizations.of(context);
              _currentSubtitle = localization?.voiceChatErrorNoConversation ?? 'No conversation found';
            });
          }

          if (_currentState == VoiceChatState.listening) {
            _startVoiceRecognitionAfterProcessing();
          }
        }
      } else {
        // If no current conversation, show error
        if (mounted) {
          setState(() {
            _currentState = VoiceChatState.listening;
            final localization = AppLocalizations.of(context);
            _currentSubtitle = localization?.voiceChatErrorNoActiveConversation ?? 'No active conversation';
          });
        }

        if (_currentState == VoiceChatState.listening) {
          _startVoiceRecognition();
        }
      }

    } catch (e) {
      if (mounted) {
        setState(() {
          _currentState = VoiceChatState.listening;
          final localization = AppLocalizations.of(context);
          _currentSubtitle = localization?.voiceChatError(e.toString()) ?? 'Error: ${e.toString()}';
        });
      }

      // Restart listening even on error
      if (_currentState == VoiceChatState.listening) {
        _startVoiceRecognitionAfterProcessing();
      }
    }
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
      }
    } else {
      // Only restart if we're in listening state and not processing voice input
      if (_currentState == VoiceChatState.listening && !_isProcessingVoiceInput) {
        _startVoiceRecognition();
      }
    }
  }

  void _endVoiceChat() async {
    // Perform cleanup before navigating back to ensure resources (mic) are released
    await _cleanup();
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  void _toggleSubtitle() {
    setState(() {
      _showSubtitles = !_showSubtitles;
    });
  }

  Future<void> _initAudioSessionForVoiceChat() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
        avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.allowBluetooth | AVAudioSessionCategoryOptions.defaultToSpeaker,
        avAudioSessionMode: AVAudioSessionMode.voiceChat,
        avAudioSessionRouteSharingPolicy: AVAudioSessionRouteSharingPolicy.defaultPolicy,
        androidAudioAttributes: const AndroidAudioAttributes(
          contentType: AndroidAudioContentType.speech,
          flags: AndroidAudioFlags.none,
          usage: AndroidAudioUsage.voiceCommunication,
        ),
        androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
        androidWillPauseWhenDucked: true,
      ));
    } catch (e) {
      print('Error initializing audio session: $e');
    }
  }

  Future<void> _initBackgroundService() async {
    try {
      if (Platform.isAndroid) {
        final androidConfig = FlutterBackgroundAndroidConfig(
          notificationTitle: "OmniChat Voice Chat",
          notificationText: "Voice chat is active",
          notificationImportance: AndroidNotificationImportance.normal,
          notificationIcon: const AndroidResource(name: 'ic_launcher', defType: 'mipmap'),
        );
        await FlutterBackground.initialize(androidConfig: androidConfig);
        await FlutterBackground.enableBackgroundExecution();
      }
    } catch (e) {
      print('Error initializing background service: $e');
    }
  }

  void _loadVersionSelections() {
    final cid = widget.chatService.currentConversationId;
    if (cid == null) {
      _versionSelections = {};
      return;
    }
    try {
      _versionSelections = widget.chatService.getVersionSelections(cid);
    } catch (_) {
      _versionSelections = {};
    }
  }

  Future<void> _initializeCallMode() async {
    try {
      await _callModeChannel.invokeMethod('startCallMode');
    } catch (e) {
      print('Error initializing call mode: $e');
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

  Future<void> _cleanup() async {
    if (_isCleaningUp) return;
    _isCleaningUp = true;
    
    print('[OmniChat Dart] _cleanup: Starting cleanup...');
    
    try {
      _restartListeningTimer?.cancel();
      _listeningWatchdog?.cancel();
      _voiceStopTimer?.cancel();
      
      if (_isListening) {
        await _speechToText.stop();
        _isListening = false;
      }
      
      try {
        await _speechToText.cancel();
      } catch (e) {
        print('[OmniChat Dart] _cleanup speechToText.cancel error: $e');
      }
      
      if (Platform.isAndroid || Platform.isIOS) {
        try {
          final session = await AudioSession.instance;
          await session.setActive(false);
        } catch (_) {}
      }
      
      if (Platform.isAndroid) {
        try {
          await _callModeChannel.invokeMethod('stopCallMode');
        } catch (_) {}
        try {
          await FlutterBackground.disableBackgroundExecution();
        } catch (_) {}
      }
    } catch (e) {
      print('[OmniChat Dart] _cleanup error: $e');
    } finally {
      print('[OmniChat Dart] _cleanup: Done.');
    }
  }

  @override
  void dispose() {
    _cleanup();
    super.dispose();
  }
}

enum VoiceChatState { listening, thinking, talking }