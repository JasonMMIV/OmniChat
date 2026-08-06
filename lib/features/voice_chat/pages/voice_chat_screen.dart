import 'dart:io';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_background/flutter_background.dart';
import 'package:audio_session/audio_session.dart';
import '../../../l10n/app_localizations.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/providers/tts_provider.dart';
import '../../../core/utils/app_logger.dart';
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
  bool _hasMicrophonePermission = false;
  bool _micPermanentlyDenied = false;
  bool _isCleaningUp = false;

  // Speech recognition
  // 使用專屬 SpeechToText 實例，而非 factory singleton：speech_to_text 的
  // initialize() 只在首次成功時註冊 onStatus/onError 回呼（_initWorked 為 true
  // 後一律早退），而 app 啟動時 VoiceChatProvider 已先以「無 listener」的方式
  // 初始化過 singleton，導致此畫面的 _handleSpeechStatus/_handleSpeechError 永遠
  // 不會被註冊（Task 1.1 靜音自動恢復因此失效）。withMethodChannel() 建立獨立
  // 實例，確保每次進入畫面都重新註冊自己的 listeners，並讓平台事件導向此實例。
  // ignore: invalid_use_of_visible_for_testing_member
  final SpeechToText _speechToText = SpeechToText.withMethodChannel();
  bool _isListening = false;
  bool _speechEngineReady = false;
  bool _manualStopInProgress = false;
  Map<String, int> _versionSelections = {};

  // Task 1.1: 靜音/session 結束後自動恢復聆聽（見 _scheduleResumeListening）

  // Flag to track if we're in the process of handling voice input
  bool _isProcessingVoiceInput = false;

  // Task 1.1: 自動恢復聆聽的 debounce 與連續空結果保護（防死循環）
  Timer? _resumeDebounce;
  int _consecutiveEmptyResumes = 0;
  static const int _maxConsecutiveEmptyResumes = 5;

  // 強制 cancel 重啟期間的恢復鎖：_doStartListening 強制 cancel 時產生的
  // notListening 狀態事件（Stop + Completed 各送一次）會被忽略，避免觸發
  // resume → 再次 cancel 的無限迴圈（Windows 實測 5~7 秒自動暫停的元凶）。
  // 新 session 收到 listening 狀態（或 listen() 返回/出錯）時解除。
  bool _resumeLocked = false;

  // Task 1.4: 進行中 LLM stream 的取消 handle（cleanup 時使用）
  StreamSubscription<dynamic>? _streamSub;
  Completer<void>? _streamDone;

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
    AppLog.d('_startUp: Starting...');
    if (Platform.isAndroid || Platform.isIOS) {
      await _initAudioSessionForVoiceChat();
    }
    if (Platform.isAndroid) {
      await _initBackgroundService();
    }

    // Must initialize speech engine first, then check permission
    // Previously these were running concurrently, causing race condition
    AppLog.d('_startUp: Initializing speech engine...');
    await _initializeSpeechEngine();
    AppLog.d('_startUp: Speech engine initialized. Ready: $_speechEngineReady');
    
    AppLog.d('_startUp: Checking microphone permission...');
    await _checkMicrophonePermission();
    AppLog.d('_startUp: Permission checked. Granted: $_hasMicrophonePermission');

    _loadVersionSelections();

    // Initialize call mode (Bluetooth/Speaker handling)
    if (Platform.isAndroid) {
      await _initializeCallMode();
    }
    AppLog.d('_startUp: Completed.');
  }

  Future<void> _checkMicrophonePermission() async {
    AppLog.d('_checkMicrophonePermission: Requesting permission...');
    final status = await Permission.microphone.request();
    AppLog.d('_checkMicrophonePermission: Status: $status');
    if (mounted) {
      setState(() {
        _hasMicrophonePermission = status == PermissionStatus.granted;
        _micPermanentlyDenied = status.isPermanentlyDenied;
      });
    }

    if (_hasMicrophonePermission) {
      AppLog.d('_checkMicrophonePermission: Permission granted, starting recognition...');
      _startVoiceRecognition();
    } else {
      AppLog.d('_checkMicrophonePermission: Permission denied.');
    }
  }

  Future<void> _initializeSpeechEngine() async {
    if (_speechEngineReady) {
        AppLog.d('_initializeSpeechEngine: Already ready.');
        return;
    }
    try {
      AppLog.d('_initializeSpeechEngine: Calling speechToText.initialize()...');
      final ok = await _speechToText.initialize(
        onStatus: _handleSpeechStatus,
        onError: _handleSpeechError,
        debugLogging: kDebugMode, // Enable debug logging in package
      );
      AppLog.d('_initializeSpeechEngine: initialize returned: $ok');
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
      AppLog.e('_initializeSpeechEngine: Exception: $e');
      if (mounted) {
        setState(() {
          final localization = AppLocalizations.of(context);
          _currentSubtitle = localization?.voiceChatErrorInitFailed ?? 'Failed to initialize voice recognition';
        });
      }
    }
  }

  void _handleSpeechStatus(String status) {
    if (_isCleaningUp || !mounted) return;

    // Don't auto-restart if this was a manual stop
    if (_manualStopInProgress) {
      if (status == 'done' || status == 'notListening') {
        _manualStopInProgress = false;
        _isListening = false;
      }
      return;
    }

    if (status == 'notListening' || status == 'done') {
      // 強制 cancel 自產的 notListening：忽略，避免 cancel/resume 死循環
      if (_resumeLocked) return;
      _isListening = false;
      // Session 結束（pauseFor 到期 / listenFor 總上限 / 原生引擎自動結束），
      // 自動重新聆聽以維持對話循環（Task 1.1）
      _scheduleResumeListening();
    } else if (status == 'listening') {
      // 新 session 確認啟動，解除恢復鎖
      _resumeLocked = false;
    }
  }

  void _handleSpeechError(SpeechRecognitionError error) {
    if (_isCleaningUp || !mounted) return;

    _isListening = false;

    // Don't auto-pause if this was a manual stop
    if (_manualStopInProgress) {
      _manualStopInProgress = false;
      return;
    }

    // Android timeout/no-match callbacks are not reliable enough to drive UI state.
    // Keep voice chat under explicit user control instead of auto-pausing.
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
      if (mounted && _currentState == VoiceChatState.listening) {
        setState(() {
          _currentSubtitle = '';
        });
        // 良性錯誤（speech timeout / no match）：自動重新聆聽（Task 1.1）
        // 空結果計數統一在 _resumeListening 內累加，避免雙重計數
        _scheduleResumeListening();
      }
      return;
    }

    if (mounted) {
      setState(() {
        final localization = AppLocalizations.of(context);
        _currentSubtitle = localization?.voiceChatError(error.errorMsg) ?? 'Error: ${error.errorMsg}';
      });
    }

    if (!_isPaused && mounted && _currentState == VoiceChatState.listening && !_isProcessingVoiceInput) {
      setState(() {
        _isPaused = true;
      });
    }
  }

  Future<void> _startVoiceRecognition() async {
    AppLog.d('_startVoiceRecognition: checking preconditions...');
    if (!_hasMicrophonePermission || !_speechEngineReady || _isCleaningUp) {
      AppLog.d('_startVoiceRecognition: Aborted. perm=$_hasMicrophonePermission, ready=$_speechEngineReady, cleanup=$_isCleaningUp');
      return;
    }

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
    AppLog.d('_startVoiceRecognition: calling _doStartListening...');
    await _doStartListening();
  }

  void _startVoiceRecognitionAfterProcessing() {
    AppLog.d('_startVoiceRecognitionAfterProcessing called');
    // Reset processing flag before starting recognition again
    _isProcessingVoiceInput = false;
    // Only restart if we're in the listening state
    if (_currentState == VoiceChatState.listening && !_isPaused && mounted) {
      _startVoiceRecognition();
    }
  }

  /// Task 1.1: 排程自動恢復聆聽（短 debounce，避免多通道競態重複觸發）
  void _scheduleResumeListening() {
    if (_isCleaningUp || _isPaused || !mounted) return;
    _resumeDebounce?.cancel();
    _resumeDebounce =
        Timer(const Duration(milliseconds: 250), _resumeListening);
  }

  /// Task 1.1: 自動恢復聆聽。
  /// 只在聆聽狀態下重啟；連續多次空結果（麥克風故障/引擎異常）時轉為 paused，避免死循環。
  void _resumeListening() {
    _resumeDebounce?.cancel();
    _resumeDebounce = null;
    _isProcessingVoiceInput = false;

    if (_isPaused || _isCleaningUp || !mounted ||
        _currentState != VoiceChatState.listening) {
      return;
    }

    _consecutiveEmptyResumes++;
    if (_consecutiveEmptyResumes >= _maxConsecutiveEmptyResumes) {
      _consecutiveEmptyResumes = 0;
      // 自動暫停時同步停止原生聆聽：避免 UI 顯示「已暫停」但麥克風仍在收音
      // （Windows 實測：原生 session 可能仍在持續，system tray mic 圖示仍亮著）
      _isListening = false;
      if (_speechToText.isListening) {
        _speechToText.stop();
      }
      if (mounted) {
        setState(() {
          _isPaused = true;
          _currentSubtitle = '';
        });
      }
      return;
    }
    _startVoiceRecognition();
  }

  /// Actually start the speech recognition
  Future<void> _doStartListening() async {
    AppLog.d('_doStartListening: Begin');
    if (_isCleaningUp) { AppLog.d('_doStartListening: Cleaning up, abort'); return; }
    if (!_hasMicrophonePermission || !_speechEngineReady) { AppLog.d('_doStartListening: Not ready/perm, abort'); return; }
    if (!mounted || _isPaused || _currentState != VoiceChatState.listening || _isProcessingVoiceInput) {
       AppLog.d('_doStartListening: State check failed. mounted=$mounted, paused=$_isPaused, state=$_currentState, proc=$_isProcessingVoiceInput');
       return;
    }

    if (_isListening) {
      AppLog.d('_doStartListening: Already flagged as listening, aborting to prevent overlap.');
      return;
    }

    // Attempt to clear any native stuck state before re-engaging
    if (_speechToText.isListening) {
      AppLog.d('_doStartListening: Native engine thinks it is listening. Forcing cancel.');
      // 鎖定自動恢復：cancel 產生的 notListening 事件必須被忽略，否則會觸發
      // resume → 再次 cancel → 無限迴圈（見 _handleSpeechStatus）
      _resumeLocked = true;
      try { await _speechToText.cancel(); } catch (_) {}
    }

    _isListening = true;
    try {
      // Attempt to resolve the best matching locale for the system（含快取，Task 2.8）
      final selectedLocaleId = await _resolveSttLocale();

      AppLog.d('Calling _speechToText.listen()...');

      await _speechToText.listen(
        onResult: (result) {
          if (_isCleaningUp || !mounted) return;

          final recognizedText = result.recognizedWords;
          if (recognizedText.isNotEmpty) {
            // 有辨識內容 → 重置信號（Task 1.1 防死循環）
            _consecutiveEmptyResumes = 0;
          }
          setState(() {
            _currentSubtitle = recognizedText;
          });

          // When we get a final result, restart listening after processing
          if (result.finalResult && recognizedText.isNotEmpty) {
            // 防重入：stop() 可能重送最終結果（尤其 Android），避免重複送 LLM
            if (_isProcessingVoiceInput) return;
            _recognizedText = recognizedText;
            // 注意：不要在此把 _isListening 設為 false——保留 true 讓
            // _processVoiceInput 內部的 stop() 真的執行，否則原生 mic 會在
            // LLM 思考 / TTS 朗讀期間持續收音（Windows tray mic 常亮的元凶），
            // 也導致處理後重啟聆聽時誤判「原生仍在聽」而強制 cancel。
            _isProcessingVoiceInput = true;
            _processVoiceInput(recognizedText);
          } else if (result.finalResult && recognizedText.isEmpty && !_resumeLocked) {
            // 空最終結果（純靜音 / no match）：自動重新聆聽（Task 1.1）
            // 空結果計數統一在 _resumeListening 內累加，避免雙重計數
            // _resumeLocked 期間（強制 cancel 產生的空結果）忽略，避免翻轉
            // _isListening 並觸發多餘 resume（與 _handleSpeechStatus 同步一致）
            _isListening = false;
            _scheduleResumeListening();
          }
        },
        listenMode: ListenMode.dictation,
        localeId: selectedLocaleId,
        cancelOnError: true,
        partialResults: true,
        // 不傳 pauseFor（套件預設即 null）：Windows 與 Android 的原生引擎都能自行
        // 判斷語音結束（實測：講完話立即辨識送出，無需 7 秒強制送出）；
        // 60 秒 listenFor 作為安全網。
        listenFor: const Duration(seconds: 60),
      );
      AppLog.d('_speechToText.listen() returned.');
      // 正常路徑解除恢復鎖（若 listening 狀態已處理則此為無操作）
      _resumeLocked = false;
    } catch (e) {
      AppLog.e('_doStartListening Exception: $e');
      // 錯誤路徑解除恢復鎖，避免後續自動恢復被永久封鎖
      _resumeLocked = false;
      _isListening = false;
      if (!_isPaused && mounted) {
        setState(() {
          _isPaused = true;
        });
      }
    }
  }

  // Task 2.8: Locale 解析（含快取）。僅當 appLocale / isFollowingSystemLocale 變更時重新解析。
  String? _cachedSttLocale;
  Locale? _cachedSttLocaleKey;
  bool? _cachedSttSystemFlag;

  Future<String?> _resolveSttLocale() async {
    final settingsLocale = widget.settings.appLocale;
    final isSystemLocale = widget.settings.isFollowingSystemLocale;

    if (_cachedSttLocale != null &&
        _cachedSttLocaleKey == settingsLocale &&
        _cachedSttSystemFlag == isSystemLocale) {
      AppLog.d('Locale cache hit: $_cachedSttLocale');
      return _cachedSttLocale;
    }

    String? selectedLocaleId;
    try {
      AppLog.d('Fetching locales...');
      final systemLocales = await _speechToText.locales();
      AppLog.d('Locales fetched: ${systemLocales.length}');

      if (systemLocales.isNotEmpty) {
        final localeTag = '${settingsLocale.languageCode}${settingsLocale.scriptCode != null ? '_${settingsLocale.scriptCode}' : ''}${settingsLocale.countryCode != null ? '_${settingsLocale.countryCode}' : ''}';

        // Normalize app locale to lower case with hyphens for comparison
        // e.g., zh_Hant -> zh-hant, zh_CN -> zh-cn
        final normalizedAppLocale = localeTag.toLowerCase().replaceAll('_', '-');

        AppLog.d('Settings locale: $settingsLocale (tag: $localeTag), isSystemLocale: $isSystemLocale');
        AppLog.d('Available system locales: ${systemLocales.map((l) => l.localeId).toList()}');

        // 1. Try exact match (insensitive)
        try {
          selectedLocaleId = systemLocales.firstWhere(
            (l) => l.localeId.toLowerCase().replaceAll('_', '-') == normalizedAppLocale
          ).localeId;
          AppLog.d('Exact match found: $selectedLocaleId');
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
                AppLog.d('Chinese Traditional match found: $selectedLocaleId');
              } catch (_) {
                // If no Traditional, try any Chinese
                try {
                  selectedLocaleId = systemLocales.firstWhere(
                    (l) => l.localeId.toLowerCase().startsWith('zh')
                  ).localeId;
                  AppLog.d('Chinese fallback match found: $selectedLocaleId');
                } catch (_) {}
              }
            } else {
              // Simplified: try CN first, then any Chinese
              try {
                selectedLocaleId = systemLocales.firstWhere(
                  (l) => l.localeId.toLowerCase().contains('zh-cn') || l.localeId.toLowerCase().contains('cn')
                ).localeId;
                AppLog.d('Chinese Simplified match found: $selectedLocaleId');
              } catch (_) {
                // If no Simplified, try any Chinese
                try {
                  selectedLocaleId = systemLocales.firstWhere(
                    (l) => l.localeId.toLowerCase().startsWith('zh')
                  ).localeId;
                  AppLog.d('Chinese fallback match found: $selectedLocaleId');
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
              AppLog.d('Language fallback match found: $selectedLocaleId');
            } catch (_) {}
          }
        }
      }

      // 4. Force fallback if still null (Best Effort)
      // This handles cases where systemLocales list is incomplete (e.g. Windows WinRT restriction)
      // but the language pack is actually installed.
      if (selectedLocaleId == null) {
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
        AppLog.d('Forced fallback locale: $selectedLocaleId');
      }
    } catch (e) {
      AppLog.e('Error getting locales: $e');
    }

    _cachedSttLocale = selectedLocaleId;
    _cachedSttLocaleKey = settingsLocale;
    _cachedSttSystemFlag = isSystemLocale;
    return selectedLocaleId;
  }

  Future<void> _processVoiceInput(String text) async {
    AppLog.d('_processVoiceInput: $text');
    if (text.isEmpty) return;

    if (_isListening) {
      _manualStopInProgress = true;
      await _speechToText.stop();
      _isListening = false;
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
            // Task 1.4: 持有 StreamSubscription 以便 cleanup 時取消
            final streamDone = Completer<void>();
            _streamDone = streamDone;
            try {
              _streamSub = stream.listen(
                cancelOnError: true,
                (chunk) async {
                  try {
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
                  } catch (chunkError) {
                    if (mounted) {
                      setState(() {
                        final localization = AppLocalizations.of(context);
                        _currentSubtitle = localization?.voiceChatErrorProcessingResponse(chunkError.toString()) ?? 'Error processing response: ${chunkError.toString()}';
                      });
                    }
                    if (!streamDone.isCompleted) streamDone.complete();
                  }
                },
                onError: (Object chunkError) {
                  if (mounted) {
                    setState(() {
                      final localization = AppLocalizations.of(context);
                      _currentSubtitle = localization?.voiceChatErrorProcessingResponse(chunkError.toString()) ?? 'Error processing response: ${chunkError.toString()}';
                    });
                  }
                  if (!streamDone.isCompleted) streamDone.complete();
                },
                onDone: () {
                  if (!streamDone.isCompleted) streamDone.complete();
                },
              );
            } catch (e) {
              if (mounted) {
                setState(() {
                  final localization = AppLocalizations.of(context);
                  _currentSubtitle = localization?.voiceChatErrorProcessingResponse(e.toString()) ?? 'Error processing response: ${e.toString()}';
                });
              }
              if (!streamDone.isCompleted) streamDone.complete();
            }
            await streamDone.future;
            _streamSub = null;
            _streamDone = null;

            // Finish the assistant message（含 cancel 路徑，確保 DB 收尾）
            await chatService.updateMessage(
              assistantMessage.id,
              content: fullContent,
              isStreaming: false,
            );

            // cleanup / pause 已觸發 → 不再進行 TTS/重啟聆聽（Task 2.1）
            if (_isCleaningUp || !mounted || _isPaused) return;

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
                // Task 2.6: 引擎卡死 watchdog — 2 分鐘未完成則強制停止並回到聆聽
                await widget.ttsProvider.speak(fullContent).timeout(
                  const Duration(seconds: 120),
                  onTimeout: () async {
                    await widget.ttsProvider.stop();
                  },
                );

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

        // Task 1.3: 用 AfterProcessing 路徑重置 _isProcessingVoiceInput，避免聽寫永久凍結
        if (_currentState == VoiceChatState.listening) {
          _startVoiceRecognitionAfterProcessing();
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
                      onPressed: _endVoiceChat, // Task 2.7: 與中央停止鍵一致，走完整 cleanup
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
                          // Task 1.2: 字幕開關生效（關閉時保留區塊避免 layout 跳動）
                          child: _showSubtitles
                              ? Text(
                                  _currentSubtitle,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
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
                        // Task 2.3: 永久拒絕時顯示引導至系統設定的文案
                        _micPermanentlyDenied
                            ? l10n.voiceChatPermissionDeniedSubtitle
                            : l10n.voiceChatPermissionSubtitle,
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.white70,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: _micPermanentlyDenied
                          ? _openMicrophoneSettings
                          : _requestMicrophonePermission,
                      child: Text(_micPermanentlyDenied
                          ? l10n.voiceChatPermissionOpenSettings
                          : l10n.voiceChatPermissionButton),
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
    if (_isPaused) {
      return l10n.voiceChatPaused; // Task 2.2 本地化
    }
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
    if (_isPaused) {
      return Colors.grey.shade400;
    }
    switch (_currentState) {
      case VoiceChatState.listening:
        return Colors.green.shade400;
      case VoiceChatState.thinking:
        return Colors.orange.shade400;
      case VoiceChatState.talking:
        return Colors.blue.shade400;
    }
  }

  Future<void> _requestMicrophonePermission() async {
    final status = await Permission.microphone.request();
    if (!mounted) return;
    setState(() {
      _hasMicrophonePermission = status == PermissionStatus.granted;
      _micPermanentlyDenied = status.isPermanentlyDenied;
    });

    if (_hasMicrophonePermission) {
      _startVoiceRecognition();
    }
  }

  /// Task 2.3: 權限永久拒絕時引導至系統設定
  Future<void> _openMicrophoneSettings() async {
    await openAppSettings();
  }

  void _togglePause() {
    setState(() {
      _isPaused = !_isPaused;
    });

    if (_isPaused) {
      // Task 2.1: 暫停時一併中斷 LLM stream 與 TTS 朗讀
      // 先取消 subscription 再完成 completer，避免 cancel 生效前 onData 繼續改動內容
      _streamSub?.cancel();
      _streamSub = null;
      if (_streamDone != null && !_streamDone!.isCompleted) {
        _streamDone!.complete();
      }
      widget.ttsProvider.stop();
      if (_isListening) {
        _manualStopInProgress = true;
        _speechToText.stop();
        _isListening = false;
      }
    } else {
      // Task 2.1: 恢復時回到 listening 狀態
      _consecutiveEmptyResumes = 0; // 手動恢復時重置信號（Task 1.1）
      setState(() {
        _currentState = VoiceChatState.listening;
        _currentSubtitle = '';
      });
      if (!_isProcessingVoiceInput) {
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
      AppLog.e('Error initializing audio session: $e');
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
      AppLog.e('Error initializing background service: $e');
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
      AppLog.e('Error initializing call mode: $e');
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
    
    AppLog.d('_cleanup: Starting cleanup...');
    
    try {
      _resumeDebounce?.cancel();
      _resumeDebounce = null;

      // Task 1.4: 停止 TTS 朗讀與取消進行中的 LLM stream
      await widget.ttsProvider.stop();
      await _streamSub?.cancel();
      _streamSub = null;
      // 讓卡在 await streamDone.future 的 _sendToLLM 能收尾（DB 寫回 isStreaming: false）
      if (_streamDone != null && !_streamDone!.isCompleted) {
        _streamDone!.complete();
      }
      _streamDone = null;

      if (_isListening) {
        await _speechToText.stop();
        _isListening = false;
      }
      
      try {
        await _speechToText.cancel();
      } catch (e) {
        AppLog.e('_cleanup speechToText.cancel error: $e');
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
      AppLog.e('_cleanup error: $e');
    } finally {
      AppLog.d('_cleanup: Done.');
    }
  }

  @override
  void dispose() {
    _cleanup();
    super.dispose();
  }
}

enum VoiceChatState { listening, thinking, talking }
