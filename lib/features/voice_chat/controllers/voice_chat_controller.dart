import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/widgets.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:speech_to_text/speech_recognition_error.dart';

import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/providers/tts_provider.dart';
import '../../../core/providers/user_provider.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/chat/chat_turn_service.dart';
import '../../../l10n/app_localizations.dart';
import '../services/platform_audio_setup.dart';
import '../services/stt_locale_resolver.dart';

/// Voice chat 狀態機（唯一來源；自 voice_chat_screen 移入，Phase 3 任務 3.3）。
enum VoiceChatState { listening, thinking, talking }

/// Voice chat 業務邏輯 controller（ChangeNotifier）。
///
/// 承接原 `_VoiceChatScreenViewState` 的全部機制：
/// - 狀態機（listening / thinking / talking）、pause 語義（中斷 LLM stream +
///   停 TTS，Task 2.1）。
/// - X2 不變量：`_resumeLocked`、resume debounce（250ms）、`_consecutiveEmptyResumes`
///   計數與自動暫停（含同步停 mic）、force-cancel 抑制、空結果門控、onResult 防重入、
///   保留 `_isListening` 讓 `stop()` 執行的順序。
/// - X1 不變量：專屬 `SpeechToText.withMethodChannel()` 實例、`_manualStopInProgress`
///   語義。
/// - `_processVoiceInput` / `_sendToLLM` 編排（送訊實體移入 ChatTurnService）、
///   TTS watchdog（120s，Task 2.6）、cleanup 編排（Task 1.4）。
class VoiceChatController extends ChangeNotifier {
  VoiceChatController({
    required ChatService chatService,
    required SettingsProvider settings,
    required AssistantProvider assistantProvider,
    required TtsProvider ttsProvider,
    required UserProvider userProvider,
    required BuildContext context,
    ChatTurnService? turnService,
  })  : _chatService = chatService,
        _settings = settings,
        _assistantProvider = assistantProvider,
        _ttsProvider = ttsProvider,
        _userProvider = userProvider,
        _context = context {
    _turnService = turnService ?? ChatTurnService(chatService: chatService);
    _sttLocaleResolver = SttLocaleResolver(
      speechToText: _speechToText,
      settings: settings,
    );
  }

  final ChatService _chatService;
  final SettingsProvider _settings;
  final AssistantProvider _assistantProvider;
  final TtsProvider _ttsProvider;
  final UserProvider _userProvider;
  final BuildContext _context;
  late final ChatTurnService _turnService;
  late final SttLocaleResolver _sttLocaleResolver;

  // Voice chat state
  VoiceChatState _currentState = VoiceChatState.listening;
  bool _isPaused = false;
  String _currentSubtitle = '';
  String _recognizedText = '';
  bool _hasMicrophonePermission = false;
  bool _micPermanentlyDenied = false;
  bool _isCleaningUp = false;
  bool _disposed = false;

  // Speech recognition
  // X1 不變量：使用專屬 SpeechToText 實例，而非 factory singleton。
  // speech_to_text 的 initialize() 只在首次成功時註冊 onStatus/onError 回呼
  // （_initWorked 為 true 後一律早退），若與其他畫面（如聽寫）共用 singleton，
  // 先初始化的一方會搶走回呼註冊，導致此 controller 的 _handleSpeechStatus /
  // _handleSpeechError 永不生效。withMethodChannel() 建立獨立實例，確保每次
  // 進入畫面都重新註冊自己的 listeners，並讓平台事件導向此實例。
  // ignore: invalid_use_of_visible_for_testing_member
  final SpeechToText _speechToText = SpeechToText.withMethodChannel();
  bool _isListening = false;
  bool _speechEngineReady = false;
  bool _manualStopInProgress = false;
  Map<String, int> _versionSelections = {};

  // Flag to track if we're in the process of handling voice input
  bool _isProcessingVoiceInput = false;

  // Task 1.1: 自動恢復聆聽的 debounce 與連續空結果保護（防死循環）
  Timer? _resumeDebounce;
  int _consecutiveEmptyResumes = 0;
  static const int _maxConsecutiveEmptyResumes = 5;

  // X2 不變量：強制 cancel 重啟期間的恢復鎖。_doStartListening 強制 cancel 時
  // 產生的 notListening 狀態事件（Stop + Completed 各送一次）會被忽略，避免觸發
  // resume → 再次 cancel 的無限迴圈（Windows 實測 5~7 秒自動暫停的元凶）。
  // 新 session 收到 listening 狀態（或 listen() 返回/出錯）時解除。
  bool _resumeLocked = false;

  // Task 1.4 + 3.2: 進行中 LLM turn 的取消 handle（pause/cleanup 使用）
  ChatTurnHandle? _turnHandle;

  // ---- UI 讀取 ----
  VoiceChatState get currentState => _currentState;
  bool get isPaused => _isPaused;
  String get currentSubtitle => _currentSubtitle;
  bool get hasMicrophonePermission => _hasMicrophonePermission;
  bool get micPermanentlyDenied => _micPermanentlyDenied;

  /// 仍可安全操作（未在 cleanup 中、未 dispose）。對應原畫面的 `mounted` 檢查
  /// （Task 1.5：setState 前 mounted 檢查）。
  bool get _active => !_isCleaningUp && !_disposed;

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  // ==========================================================================
  // 啟動
  // ==========================================================================

  Future<void> startUp() async {
    if (Platform.isAndroid || Platform.isIOS) {
      await PlatformAudioSetup.initAudioSessionForVoiceChat();
    }
    if (Platform.isAndroid) {
      await PlatformAudioSetup.initBackgroundService();
    }

    // Must initialize speech engine first, then check permission
    // Previously these were running concurrently, causing race condition
    await _initializeSpeechEngine();

    await _checkMicrophonePermission();

    _loadVersionSelections();

    // Initialize call mode (Bluetooth/Speaker handling)
    if (Platform.isAndroid) {
      await PlatformAudioSetup.startCallMode();
    }
  }

  Future<void> _checkMicrophonePermission() async {
    final status = await Permission.microphone.request();
    if (_active) {
      _hasMicrophonePermission = status == PermissionStatus.granted;
      _micPermanentlyDenied = status.isPermanentlyDenied;
      _notify();
    }

    if (_hasMicrophonePermission) {
      _startVoiceRecognition();
    }
  }

  Future<void> _initializeSpeechEngine() async {
    if (_speechEngineReady) {
      return;
    }
    try {
      final ok = await _speechToText.initialize(
        onStatus: _handleSpeechStatus,
        onError: _handleSpeechError,
        debugLogging: kDebugMode, // Enable debug logging in package
      );
      if (ok) {
        if (_active) {
          _speechEngineReady = true;
          _notify();
        }
      } else {
        if (_active) {
          final localization = AppLocalizations.of(_context);
          _currentSubtitle =
              localization?.voiceChatErrorInitFailed ??
              'Failed to initialize voice recognition';
          _notify();
        }
      }
    } catch (_) {
      if (_active) {
        final localization = AppLocalizations.of(_context);
        _currentSubtitle =
            localization?.voiceChatErrorInitFailed ??
            'Failed to initialize voice recognition';
        _notify();
      }
    }
  }

  // ==========================================================================
  // Speech 事件處理（X2 核心）
  // ==========================================================================

  void _handleSpeechStatus(String status) {
    if (_isCleaningUp || _disposed) return;

    // Don't auto-restart if this was a manual stop
    if (_manualStopInProgress) {
      if (status == 'done' || status == 'notListening') {
        _manualStopInProgress = false;
        _isListening = false;
      }
      return;
    }

    if (status == 'notListening' || status == 'done') {
      // X2：強制 cancel 自產的 notListening：忽略，避免 cancel/resume 死循環
      if (_resumeLocked) return;
      _isListening = false;
      // Session 結束（listenFor 總上限 / 原生引擎自動結束），
      // 自動重新聆聽以維持對話循環（Task 1.1）
      _scheduleResumeListening();
    } else if (status == 'listening') {
      // 新 session 確認啟動，解除恢復鎖
      _resumeLocked = false;
    }
  }

  void _handleSpeechError(SpeechRecognitionError error) {
    if (_isCleaningUp || _disposed) return;

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
      if (_active && _currentState == VoiceChatState.listening) {
        _currentSubtitle = '';
        _notify();
        // 良性錯誤（speech timeout / no match）：自動重新聆聽（Task 1.1）
        // 空結果計數統一在 _resumeListening 內累加，避免雙重計數
        _scheduleResumeListening();
      }
      return;
    }

    if (_active) {
      final localization = AppLocalizations.of(_context);
      _currentSubtitle =
          localization?.voiceChatError(error.errorMsg) ??
          'Error: ${error.errorMsg}';
      _notify();
    }

    if (!_isPaused &&
        _active &&
        _currentState == VoiceChatState.listening &&
        !_isProcessingVoiceInput) {
      _isPaused = true;
      _notify();
    }
  }

  // ==========================================================================
  // 聆聽控制
  // ==========================================================================

  Future<void> _startVoiceRecognition() async {
    if (!_hasMicrophonePermission || !_speechEngineReady || _isCleaningUp) {
      return;
    }

    // Make sure audio session is active for Bluetooth call simulation (Mobile only)
    if (Platform.isAndroid || Platform.isIOS) {
      await PlatformAudioSetup.activateAudioSession();
    }

    if (!_active) return;
    _currentState = VoiceChatState.listening;
    _currentSubtitle = '';
    _notify();

    // Start the actual listening
    await _doStartListening();
  }

  void _startVoiceRecognitionAfterProcessing() {
    // Reset processing flag before starting recognition again
    _isProcessingVoiceInput = false;
    // Only restart if we're in the listening state
    if (_currentState == VoiceChatState.listening && !_isPaused && _active) {
      _startVoiceRecognition();
    }
  }

  /// Task 1.1: 排程自動恢復聆聽（短 debounce，避免多通道競態重複觸發）
  void _scheduleResumeListening() {
    if (_isCleaningUp || _isPaused || _disposed) return;
    _resumeDebounce?.cancel();
    _resumeDebounce = Timer(
      const Duration(milliseconds: 250),
      _resumeListening,
    );
  }

  /// Task 1.1: 自動恢復聆聽。
  /// 只在聆聽狀態下重啟；連續多次空結果（麥克風故障/引擎異常）時轉為 paused，
  /// 避免死循環。
  void _resumeListening() {
    _resumeDebounce?.cancel();
    _resumeDebounce = null;
    _isProcessingVoiceInput = false;

    if (_isPaused ||
        _isCleaningUp ||
        _disposed ||
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
      if (_active) {
        _isPaused = true;
        _currentSubtitle = '';
        _notify();
      }
      return;
    }
    _startVoiceRecognition();
  }

  /// Actually start the speech recognition
  Future<void> _doStartListening() async {
    if (_isCleaningUp) {
      return;
    }
    if (!_hasMicrophonePermission || !_speechEngineReady) {
      return;
    }
    if (!_active ||
        _isPaused ||
        _currentState != VoiceChatState.listening ||
        _isProcessingVoiceInput) {
      return;
    }

    if (_isListening) {
      return;
    }

    // Attempt to clear any native stuck state before re-engaging
    if (_speechToText.isListening) {
      // X2：鎖定自動恢復：cancel 產生的 notListening 事件必須被忽略，否則會觸發
      // resume → 再次 cancel → 無限迴圈（見 _handleSpeechStatus）
      _resumeLocked = true;
      try {
        await _speechToText.cancel();
      } catch (_) {}
    }

    _isListening = true;
    try {
      // Attempt to resolve the best matching locale for the system（含快取，Task 2.8）
      final selectedLocaleId = await _sttLocaleResolver.resolve();

      await _speechToText.listen(
        onResult: (result) {
          if (_isCleaningUp || _disposed) return;

          final recognizedText = result.recognizedWords;
          if (recognizedText.isNotEmpty) {
            // 有辨識內容 → 重置信號（Task 1.1 防死循環）
            _consecutiveEmptyResumes = 0;
          }
          _currentSubtitle = recognizedText;
          _notify();

          // When we get a final result, restart listening after processing
          if (result.finalResult && recognizedText.isNotEmpty) {
            // 防重入：stop() 可能重送最終結果（尤其 Android），避免重複送 LLM
            if (_isProcessingVoiceInput) return;
            _recognizedText = recognizedText;
            // X2 不變量：不要在此把 _isListening 設為 false——保留 true 讓
            // _processVoiceInput 內部的 stop() 真的執行，否則原生 mic 會在
            // LLM 思考 / TTS 朗讀期間持續收音（Windows tray mic 常亮的元凶），
            // 也導致處理後重啟聆聽時誤判「原生仍在聽」而強制 cancel。
            _isProcessingVoiceInput = true;
            _processVoiceInput(recognizedText);
          } else if (result.finalResult &&
              recognizedText.isEmpty &&
              !_resumeLocked) {
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
      // 正常路徑解除恢復鎖（若 listening 狀態已處理則此為無操作）
      _resumeLocked = false;
    } catch (_) {
      // 錯誤路徑解除恢復鎖，避免後續自動恢復被永久封鎖
      _resumeLocked = false;
      _isListening = false;
      if (!_isPaused && _active) {
        _isPaused = true;
        _notify();
      }
    }
  }

  // ==========================================================================
  // Voice input → LLM 編排
  // ==========================================================================

  Future<void> _processVoiceInput(String text) async {
    if (text.isEmpty) return;

    if (_isListening) {
      _manualStopInProgress = true;
      try {
        await _speechToText.stop();
      } catch (_) {
        // 防卡死：stop() 若拋錯（例如原生引擎狀態異常），不能讓
        // _isProcessingVoiceInput 永久卡住（否則後續語音全被防重入閘門丟棄）。
      }
      _isListening = false;
    }

    // After processing the voice input, ensure we restart listening
    // once the LLM response is complete
    _sendToLLM(text);
  }

  /// 送 LLM：context 組裝交由 ChatTurnService（3.2）。
  Future<void> _sendToLLM(String text) async {
    if (text.isEmpty) return;

    if (_isListening) {
      _manualStopInProgress = true;
      await _speechToText.stop();
      _isListening = false;
    }

    if (!_active) return;
    final localization = AppLocalizations.of(_context);
    _currentState = VoiceChatState.thinking;
    // Keep the recognized text as subtitle during thinking, or show a brief indicator if needed
    _currentSubtitle = _recognizedText.isNotEmpty
        ? _recognizedText
        : (localization?.voiceChatProcessing ?? 'Processing...');
    _notify();

    try {
      final chatService = _chatService;
      final settings = _settings;
      final assistant = _assistantProvider.currentAssistant;

      // Get the current conversation using the currentConversationId
      final currentConversationId = chatService.currentConversationId;
      if (currentConversationId == null) {
        _showErrorAndResume(
          localization?.voiceChatErrorNoActiveConversation ??
              'No active conversation',
        );
        return;
      }
      final currentConversation = chatService.getConversation(
        currentConversationId,
      );
      if (currentConversation == null) {
        _showErrorAndResume(
          localization?.voiceChatErrorNoConversation ?? 'No conversation found',
        );
        return;
      }

      // Add user message to the conversation
      await chatService.addMessage(
        conversationId: currentConversationId,
        role: 'user',
        content: text,
      );

      // Create the streaming assistant placeholder message
      final assistantMessage = await chatService.addMessage(
        conversationId: currentConversationId,
        role: 'assistant',
        content: '',
        isStreaming: true,
      );

      final currentAssistant = _assistantProvider.currentAssistant;
      final providerKey =
          currentAssistant?.chatModelProvider ?? settings.currentModelProvider;
      final modelId =
          currentAssistant?.chatModelId ?? settings.currentModelId;

      if (providerKey == null || modelId == null) {
        _showErrorAndResume(
          localization?.voiceChatErrorNoModel ?? 'No model selected',
        );
        return;
      }

      final request = _turnService.prepareTurnRequest(
        conversation: currentConversation,
        messages: chatService.getMessages(currentConversationId),
        versionSelections: _versionSelections,
        providerKey: providerKey,
        modelId: modelId,
        settings: settings,
        assistant: assistant,
        context: _context,
        userNickname: _userProvider.name,
      );

      final handle = _turnService.startTurn(
        request: request,
        assistantMessageId: assistantMessage.id,
        onChunk: (full) {
          if (_active) {
            _currentSubtitle = full;
            _notify();
          }
        },
        onError: (msg) {
          if (_active) {
            final l = AppLocalizations.of(_context);
            _currentSubtitle =
                l?.voiceChatErrorProcessingResponse(msg) ??
                'Error processing response: $msg';
            _notify();
          }
        },
      );
      _turnHandle = handle;

      // 等待 stream 結束 / 被取消；期間 pause/cleanup 可呼叫 handle.cancel()
      await handle.done;
      _turnHandle = null;
      final fullContent = handle.fullContent;

      // cleanup / pause 已觸發 → 不再進行 TTS/重啟聆聽（Task 2.1）
      if (_isCleaningUp || _disposed || _isPaused) return;

      if (fullContent.isNotEmpty) {
        // Switch to talking state before playing TTS
        if (_active) {
          _currentState = VoiceChatState.talking;
          _currentSubtitle = fullContent; // Show the response during talking state
          _notify();
        }

        try {
          // Play the response using TTS and wait for completion
          // Task 2.6: 引擎卡死 watchdog — 2 分鐘未完成則強制停止並回到聆聽
          await _ttsProvider.speak(fullContent).timeout(
            const Duration(seconds: 120),
            onTimeout: () async {
              await _ttsProvider.stop();
            },
          );

          // After TTS completes, return to listening
          if (_active) {
            _currentState = VoiceChatState.listening;
            _currentSubtitle = ''; // Clear subtitle when returning to listening
            _notify();
          }

          // Only restart listening after TTS completes if we're still in listening state
          if (_currentState == VoiceChatState.listening) {
            _startVoiceRecognitionAfterProcessing();
          }
        } catch (e) {
          // Handle TTS error but stay in talking state briefly before returning to listening
          if (_active) {
            final l = AppLocalizations.of(_context);
            _currentSubtitle =
                l?.voiceChatErrorTts(e.toString()) ?? 'TTS error: ${e.toString()}';
            _notify();
          }

          // Even if TTS fails, we should still return to listening state and restart recognition
          if (_active) {
            _currentState = VoiceChatState.listening;
            _notify();
          }

          if (_currentState == VoiceChatState.listening) {
            _startVoiceRecognitionAfterProcessing();
          }
        }
      } else {
        // If no content, return to listening
        if (_active) {
          _currentState = VoiceChatState.listening;
          _currentSubtitle = ''; // Clear subtitle when returning to listening
          _notify();
        }

        if (_currentState == VoiceChatState.listening) {
          _startVoiceRecognitionAfterProcessing();
        }
      }
    } catch (e) {
      if (_active) {
        final l = AppLocalizations.of(_context);
        _currentState = VoiceChatState.listening;
        _currentSubtitle =
            l?.voiceChatError(e.toString()) ?? 'Error: ${e.toString()}';
        _notify();
      }

      // Restart listening even on error
      if (_currentState == VoiceChatState.listening) {
        _startVoiceRecognitionAfterProcessing();
      }
    }
  }

  /// 顯示錯誤並回到聆聽（Task 1.3：用 AfterProcessing 路徑重置
  /// _isProcessingVoiceInput，避免聽寫永久凍結）。
  void _showErrorAndResume(String message) {
    if (!_active) return;
    _currentState = VoiceChatState.listening;
    _currentSubtitle = message;
    _notify();
    if (_currentState == VoiceChatState.listening) {
      _startVoiceRecognitionAfterProcessing();
    }
  }

  // ==========================================================================
  // 使用者控制
  // ==========================================================================

  /// Task 2.1: 暫停語義 — 中斷 LLM stream + 停 TTS；恢復回 listening 並重啟聆聽。
  void togglePause() {
    if (_disposed) return;
    _isPaused = !_isPaused;
    _notify();

    if (_isPaused) {
      // 先取消 subscription 再完成 completer，避免 cancel 生效前 onData 繼續改動內容
      final handle = _turnHandle;
      _turnHandle = null;
      handle?.cancel();
      _ttsProvider.stop();
      if (_isListening) {
        _manualStopInProgress = true;
        _speechToText.stop();
        _isListening = false;
      }
    } else {
      // 手動恢復時重置信號（Task 1.1）
      _consecutiveEmptyResumes = 0;
      _currentState = VoiceChatState.listening;
      _currentSubtitle = '';
      _notify();
      if (!_isProcessingVoiceInput) {
        _startVoiceRecognition();
      }
    }
  }

  /// Task 2.7: 結束語音對話 — 完整 cleanup（與中央停止鍵一致）。
  Future<void> cleanup() async {
    if (_isCleaningUp) return;
    _isCleaningUp = true;

    try {
      _resumeDebounce?.cancel();
      _resumeDebounce = null;

      // Task 1.4: 停止 TTS 朗讀與取消進行中的 LLM stream
      await _ttsProvider.stop();
      final handle = _turnHandle;
      _turnHandle = null;
      // 讓卡在 await handle.done 的 _sendToLLM 能收尾（DB 寫回 isStreaming: false）
      await handle?.cancel();

      if (_isListening) {
        await _speechToText.stop();
        _isListening = false;
      }

      try {
        await _speechToText.cancel();
      } catch (_) {}

      if (Platform.isAndroid || Platform.isIOS) {
        await PlatformAudioSetup.deactivateAudioSession();
      }

      if (Platform.isAndroid) {
        await PlatformAudioSetup.stopCallMode();
        await PlatformAudioSetup.disableBackgroundExecution();
      }
    } catch (_) {
      // 忽略：資源清理失敗不影響結束語音對話
    }
  }

  // ==========================================================================
  // 權限
  // ==========================================================================

  Future<void> requestMicrophonePermission() async {
    final status = await Permission.microphone.request();
    if (!_active) return;
    _hasMicrophonePermission = status == PermissionStatus.granted;
    _micPermanentlyDenied = status.isPermanentlyDenied;
    _notify();

    if (_hasMicrophonePermission) {
      _startVoiceRecognition();
    }
  }

  /// Task 2.3: 權限永久拒絕時引導至系統設定
  Future<void> openMicrophoneSettings() async {
    await openAppSettings();
  }

  // ==========================================================================
  // 其他
  // ==========================================================================

  void _loadVersionSelections() {
    final cid = _chatService.currentConversationId;
    if (cid == null) {
      _versionSelections = {};
      return;
    }
    try {
      _versionSelections = _chatService.getVersionSelections(cid);
    } catch (_) {
      _versionSelections = {};
    }
  }

  @override
  void dispose() {
    _disposed = true;
    // 若尚未 cleanup（例如系統返回鍵直接 pop），在此觸發完整資源釋放
    cleanup();
    super.dispose();
  }
}
