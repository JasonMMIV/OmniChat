import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:permission_handler/permission_handler.dart';
import '../../../core/models/chat_input_data.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/conversation.dart';
import '../../../core/models/quick_phrase.dart';
import '../../../core/models/assistant_regex.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/providers/mcp_provider.dart';
import '../../../core/providers/tts_provider.dart';
import '../../../core/services/tts/tts_text_selection.dart';
import '../../../core/providers/quick_phrase_provider.dart';
import '../../../core/providers/instruction_injection_provider.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/haptics.dart';
import '../../../core/services/screen_wakelock.dart';
import '../../voice_chat/services/stt_locale_resolver.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../utils/platform_utils.dart';
import '../../../utils/assistant_regex.dart';
import '../../chat/models/message_edit_result.dart';
import '../../chat/widgets/chat_message_widget.dart' show ToolUIPart;
import '../../chat/widgets/message_edit_sheet.dart';
import '../../chat/widgets/message_export_sheet.dart';
import '../../../desktop/message_edit_dialog.dart';
import '../../../desktop/hotkeys/chat_action_bus.dart';
import '../../../desktop/hotkeys/sidebar_tab_bus.dart';
import 'chat_controller.dart';
import 'stream_controller.dart' as stream_ctrl;
import 'generation_controller.dart';
import 'scroll_controller.dart' as scroll_ctrl;
import 'home_view_model.dart';
import '../services/message_builder_service.dart';
import '../services/message_generation_service.dart';
import '../services/ocr_service.dart';
import '../services/translation_service.dart';
import '../services/file_upload_service.dart';
import '../widgets/chat_input_bar.dart';
import '../../model/widgets/model_select_sheet.dart';

/// Translation data for UI state (expanded/collapsed).
class TranslationData {
  bool expanded = true; // default to expanded when translation is added
}


/// Controller that manages all state and service wiring for HomePage.
///
/// This controller extracts the non-UI logic from _HomePageState to:
/// - Centralize state management
/// - Make the code more testable
/// - Allow reuse across different page layouts (mobile/tablet/desktop)
/// - Reduce the complexity of the State class
///
/// The HomePage widget now only manages:
/// - Lifecycle (initState, dispose)
/// - Layout selection (mobile vs tablet)
/// - Building the UI tree
class HomePageController extends ChangeNotifier {
  HomePageController({
    required BuildContext context,
    required TickerProvider vsync,
    required GlobalKey<ScaffoldState> scaffoldKey,
    required GlobalKey inputBarKey,
    required FocusNode inputFocus,
    required TextEditingController inputController,
    required ChatInputBarController mediaController,
    required ScrollController scrollController,
  })  : _context = context,
        _vsync = vsync,
        _scaffoldKey = scaffoldKey,
        _inputBarKey = inputBarKey,
        _inputFocus = inputFocus,
        _inputController = inputController,
        _mediaController = mediaController,
        _scrollController = scrollController {
    _initialize();
  }

  // ============================================================================
  // Dependencies (injected)
  // ============================================================================

  final BuildContext _context;
  final TickerProvider _vsync;
  final GlobalKey<ScaffoldState> _scaffoldKey;
  final GlobalKey _inputBarKey;
  final FocusNode _inputFocus;
  final TextEditingController _inputController;
  final ChatInputBarController _mediaController;
  final ScrollController _scrollController;

  // ============================================================================
  // Services & Controllers (created internally)
  // ============================================================================

  late ChatService _chatService;
  late ChatController _chatController;
  late stream_ctrl.StreamController _streamController;
  late GenerationController _generationController;
  late MessageBuilderService _messageBuilderService;
  late MessageGenerationService _messageGenerationService;
  late HomeViewModel _viewModel;
  late OcrService _ocrService;
  late TranslationService _translationService;
  late FileUploadService _fileUploadService;
  late scroll_ctrl.ChatScrollController _scrollCtrl;

  McpProvider? _mcpProvider;
  StreamSubscription<ChatAction>? _chatActionSub;

  // ============================================================================
  // Animation Controllers
  // ============================================================================

  late AnimationController _convoFadeController;
  late Animation<double> _convoFade;

  // ============================================================================
  // State Fields
  // ============================================================================

  // Translations UI state
  final Map<String, TranslationData> _translations = <String, TranslationData>{};

  // Message widget keys for navigation
  final Map<String, GlobalKey> _messageKeys = <String, GlobalKey>{};

  // Selection mode for sharing
  bool _selecting = false;
  final Set<String> _selectedItems = <String>{};

  // Desktop drag-and-drop
  bool _isDragHovering = false;

  // App lifecycle (currently unused but kept for future notification logic)
  // ignore: unused_field
  bool _appInForeground = true;

  // Sidebar state (tablet/desktop)
  bool _tabletSidebarOpen = true;
  bool _rightSidebarOpen = true;
  double _embeddedSidebarWidth = 300;
  double _rightSidebarWidth = 300;
  bool _desktopUiInited = false;

  // Drawer state
  double _lastDrawerValue = 0.0;

  // Inline Dictation State
  bool _isDictating = false;
  bool get isDictating => _isDictating;
  // 暫停狀態：系統語音引擎靜默結束聆聽（無新結果通知）時切為 true，
  // UI 顯示「播放」按鈕，按下後 resumeDictation() 重新開啟聆聽。
  bool _dictationPaused = false;
  bool get dictationPaused => _dictationPaused;
  // 靜音看門狗：每次收到辨識結果即重置；超過平台靜音上限仍無新結果
  // 視為聆聽已靜默結束，自動進入暫停狀態。
  Timer? _dictationWatchdogTimer;
  // Android/iOS 約 7 秒、桌面（Windows/macOS/Linux）約 60 秒。
  static const Duration _dictationSilenceTimeoutMobile =
      Duration(seconds: 7);
  static const Duration _dictationSilenceTimeoutDesktop =
      Duration(seconds: 60);
  stt.SpeechToText? _speechToText;
  SttLocaleResolver? _dictationSttLocaleResolver;
  String _preDictationText = '';
  // 每句話（final result）後重開 session 的進行中旗標（防止重入）。
  bool _dictationRestarting = false;
  // dispose 後到達的異步回調（如重啟中的 await）防護。
  bool _disposed = false;
  // 停止引擎的 in-flight future（去重，供暫停恢復/每句話重啟共用）。
  Future<void>? _dictationStopFuture;

  // Input bar measurement
  double _inputBarHeight = 72;

  // Animation tuning
  static const Duration _postSwitchScrollDelay = Duration(milliseconds: 220);
  static const double _sidebarMinWidth = 200;
  static const double _sidebarMaxWidth = 360;

  // ============================================================================
  // Public API (Getters)
  // ============================================================================

  Future<void> startDictation() async {
    if (_isDictating) return;

    var status = await Permission.microphone.status;
    if (!status.isGranted) {
      status = await Permission.microphone.request();
      if (!status.isGranted) {
        if (_context.mounted) {
          ScaffoldMessenger.of(_context).showSnackBar(const SnackBar(content: Text('Microphone permission denied.')));
        }
        return;
      }
    }

    // 使用專屬 SpeechToText 實例，而非 factory singleton：SpeechToText 的
    // initialize() 只在首次成功時註冊 onStatus/onError，語音對話與聽寫各自使用
    // withMethodChannel() 建立獨立實例，避免共用 singleton 時 initialize() 早退
    // 導致 listeners 不註冊、或平台事件導向被另一畫面實例持有（X1 教訓）。
    // ignore: invalid_use_of_visible_for_testing_member
    _speechToText = stt.SpeechToText.withMethodChannel();
    // X1 教訓：聽寫使用專屬 STT 實例，不可與 Voice Chat 共用；locale 解析器
    // 同樣綁定此專屬實例（系統語言列表來自同一引擎）。
    _dictationSttLocaleResolver = SttLocaleResolver(
      speechToText: _speechToText!,
      settings: _context.read<SettingsProvider>(),
    );
    final available = await _speechToText!.initialize(
      onError: (val) {
        debugPrint('[OmniChat Dictation] Speech recognition error: ${val.errorMsg}');
      },
      onStatus: (val) {
        debugPrint('[OmniChat Dictation] Speech recognition status: $val');
      },
    );

    if (available) {
      _isDictating = true;
      _preDictationText = _inputController.text;
      notifyListeners();
      await _startDictationListening();
    } else {
      if (_context.mounted) {
        ScaffoldMessenger.of(_context).showSnackBar(const SnackBar(content: Text('Speech recognition not available on this device.')));
      }
    }
  }

  /// 開啟（或重新開啟）聽寫聆聽，並啟動靜音看門狗。
  Future<void> _startDictationListening() async {
    if (_speechToText == null) return;
    _dictationPaused = false;
    // 解析使用者設定的語音辨識語言（顯式指定 > 自動）；解析失敗時回 null
    // （使用平台預設），不阻斷聽寫。
    String? localeId;
    try {
      localeId = await _dictationSttLocaleResolver?.resolve();
    } catch (_) {
      localeId = null;
    }
    // 若在解析期間（async gap）已被暫停或結束，不再啟動聆聽。
    if (!_isDictating || _dictationPaused) return;
    // 看門狗在 listen() 前一刻啟動，避免 async gap 期間誤觸發。
    _restartDictationWatchdog();
    _speechToText!.listen(
      onResult: (val) {
        // 暫停後引擎可能補送 final result（例如 Android stop() 觸發）；
        // 此時文字已完整，忽略以避免重複追加。
        if (_disposed || _dictationPaused) return;
        // 重開 session 的過渡期可能收到舊 session 殘留的 partial，忽略避免疊字。
        if (_dictationRestarting && !val.finalResult) return;
        if (val.recognizedWords.isNotEmpty) {
          final separator = (_preDictationText.isNotEmpty && !_preDictationText.endsWith(' ') && !_preDictationText.endsWith('\n')) ? ' ' : '';
          final newText = _preDictationText + separator + val.recognizedWords;
          _inputController.value = TextEditingValue(
            text: newText,
            selection: TextSelection.collapsed(offset: newText.length),
          );
          // 所有平台處理「每句話重開 session」：Windows 與 Android 引擎皆
          // 每個 session 只輸出第一句話的結果（Android 已裝置實測確認）。
          if (val.finalResult) {
            // 本句已確定：納入接續基底，下一句才不會覆蓋前文。
            _preDictationText = newText;
            // 引擎的連續辨識 session 只會對第一句話輸出結果：第一次 final
            // 送出後引擎不再辨識（session 仍開啟、不送 notListening、麥克風
            // 持續被佔用——所以 UI 顯示聆聽但後續講話沒有文字）。每次產出
            // 文字後立即重開新 session（與 Voice Chat 每句話重啟的模式一致），
            // 讓後續語句持續被辨識。套件在送出第一個 final 後會忽略後續所有
            // 結果（_notifiedFinal），因此 Android stop() 補送的 final 不會
            // 造成重複文字或重複重啟。
            _restartDictationAfterFinal();
          }
        }
        // 任何新結果（partial 或 final）代表使用者仍在說話，重置看門狗。
        _restartDictationWatchdog();
      },
      cancelOnError: true,
      localeId: localeId,
      // partialResults 開啟：長篇聽寫時持續收到 interim 結果以重置看門狗，
      // 避免講話途中被誤判為靜默結束。
      partialResults: true,
      // 不傳 pauseFor（套件預設即 null）：原生引擎自行判斷語音結束（講完話立即送出），
      // 60 秒 listenFor 作為安全網。
      listenFor: const Duration(seconds: 60),
    );
  }

  /// 每句話（非空 final result）結束後重開聆聽 session。
  ///
  /// 先 stop()（等待 plugin 的 m_isListening 歸零，否則 plugin 會以
  /// 「Already listening」忽略接下來的 listen()），再重新 listen() 開啟
  /// 全新 session，下一句話才能被辨識。重啟失敗不影響已產出的文字。
  void _restartDictationAfterFinal() {
    if (_disposed || _dictationRestarting || _dictationPaused || !_isDictating) {
      return;
    }
    _dictationRestarting = true;
    _restartDictationAfterFinalAsync();
  }

  Future<void> _restartDictationAfterFinalAsync() async {
    try {
      await _stopDictationEngine();
      if (_disposed || _dictationPaused || !_isDictating) return;
      await _startDictationListening();
    } catch (_) {
      // 重啟失敗：不影響已產出文字，看門狗仍會接管。
    } finally {
      _dictationRestarting = false;
    }
  }

  /// 停止 STT 引擎（去重：多次呼叫共用同一個 in-flight future）。
  ///
  /// plugin 的 m_isListening 只有在 StopAsync 完成後才會歸零；若在停止完成
  /// 前就呼叫 listen()，plugin 會以「Already listening」忽略（log 中可見
  /// Listen called 之後沒有 StartListeningAsync——暫停後快速恢復的「沒反應」
  /// 即由此而來）。所有「先停再聽」的路徑（暫停恢復、每句話重啟）都 await
  /// 此 future，確保先停完再聽。
  Future<void> _stopDictationEngine() {
    final inFlight = _dictationStopFuture;
    if (inFlight != null) return inFlight;
    final fut = _speechToText?.stop();
    if (fut == null) return Future.value();
    _dictationStopFuture = fut.whenComplete(() => _dictationStopFuture = null);
    return _dictationStopFuture!;
  }

  /// 靜音看門狗：超過平台靜音上限無新結果，視為聆聽已靜默結束 → 自動暫停。
  void _restartDictationWatchdog() {
    _cancelDictationWatchdog();
    if (!_isDictating || _dictationPaused) return;
    final timeout = isDesktopPlatform
        ? _dictationSilenceTimeoutDesktop
        : _dictationSilenceTimeoutMobile;
    _dictationWatchdogTimer = Timer(timeout, () {
      _dictationWatchdogTimer = null;
      if (!_isDictating || _dictationPaused) return;
      pauseDictation();
    });
  }

  void _cancelDictationWatchdog() {
    _dictationWatchdogTimer?.cancel();
    _dictationWatchdogTimer = null;
  }

  /// 暫停聽寫：停止收音（麥克風釋放），保留已辨識文字，UI 顯示「播放」。
  void pauseDictation() {
    if (!_isDictating || _dictationPaused) return;
    _cancelDictationWatchdog();
    // 捕捉目前文字作為 resume 後的接續基底，避免新語音覆蓋既有內容。
    _preDictationText = _inputController.text;
    _stopDictationEngine();
    _dictationPaused = true;
    notifyListeners();
  }

  /// 從暫停狀態重新開啟聆聽。
  void resumeDictation() {
    if (!_isDictating || !_dictationPaused) return;
    _resumeDictationAsync();
  }

  Future<void> _resumeDictationAsync() async {
    try {
      // 等上一個 stop() 真正完成（m_isListening 歸零）再 listen()，
      // 避免 plugin 忽略 Listen（「暫停後馬上恢復沒反應」的成因）。
      await _stopDictationEngine();
      if (_disposed || !_isDictating || !_dictationPaused) return;
      await _startDictationListening();
      // 此處才通知 UI（_startDictationListening 已同步把 _dictationPaused
      // 設為 false），避免輸入列按鈕停留在「播放/暫停」狀態。
      notifyListeners();
    } catch (_) {
      // 恢復失敗：維持暫停狀態，使用者可再按播放重試。
    }
  }

  void toggleDictationPause() {
    if (_dictationPaused) {
      resumeDictation();
    } else {
      pauseDictation();
    }
  }

  void stopDictation() {
    if (!_isDictating) return;
    _cancelDictationWatchdog();
    _stopDictationEngine();
    _isDictating = false;
    _dictationPaused = false;
    notifyListeners();
  }

  GlobalKey<ScaffoldState> get scaffoldKey => _scaffoldKey;
  GlobalKey get inputBarKey => _inputBarKey;
  FocusNode get inputFocus => _inputFocus;
  TextEditingController get inputController => _inputController;
  ChatInputBarController get mediaController => _mediaController;
  ScrollController get scrollController => _scrollController;
  Animation<double> get convoFade => _convoFade;
  AnimationController get convoFadeController => _convoFadeController;

  ChatMessage? _editingMessage;
  ChatMessage? get editingMessage => _editingMessage;

  Map<String, TranslationData> get translations => _translations;
  Map<String, GlobalKey> get messageKeys => _messageKeys;
  bool get selecting => _selecting;
  Set<String> get selectedItems => _selectedItems;

  bool get isDragHovering => _isDragHovering;
  bool get tabletSidebarOpen => _tabletSidebarOpen;
  bool get rightSidebarOpen => _rightSidebarOpen;
  double get embeddedSidebarWidth => _embeddedSidebarWidth;
  double get rightSidebarWidth => _rightSidebarWidth;
  double get inputBarHeight => _inputBarHeight;
  bool get desktopUiInited => _desktopUiInited;

  static double get sidebarMinWidth => _sidebarMinWidth;
  static double get sidebarMaxWidth => _sidebarMaxWidth;

  // Delegate to ChatController
  Conversation? get currentConversation => _chatController.currentConversation;
  List<ChatMessage> get messages => _chatController.messages;
  Map<String, int> get versionSelections => _chatController.versionSelections;
  Set<String> get loadingConversationIds => _chatController.loadingConversationIds;
  Map<String, StreamSubscription<dynamic>> get conversationStreams => _chatController.conversationStreams;

  // Delegate to StreamController
  Map<String, stream_ctrl.ReasoningData> get reasoning => _streamController.reasoning;
  Map<String, List<stream_ctrl.ReasoningSegmentData>> get reasoningSegments => _streamController.reasoningSegments;
  Map<String, List<ToolUIPart>> get toolParts => _streamController.toolParts;

  /// Lightweight notifier for streaming content updates.
  /// Use this with ValueListenableBuilder in MessageListView to avoid full page rebuilds.
  stream_ctrl.StreamingContentNotifier get streamingContentNotifier =>
      _streamController.streamingContentNotifier;

  // Delegate to scroll controller
  scroll_ctrl.ChatScrollController get scrollCtrl => _scrollCtrl;

  bool get isDesktopPlatform => PlatformUtils.isDesktopTarget;

  bool get isCurrentConversationLoading {
    final cid = currentConversation?.id;
    if (cid == null) return false;
    return loadingConversationIds.contains(cid);
  }

  // ============================================================================
  // Initialization
  // ============================================================================

  void _initialize() {
    _initializeAnimations();
    _initializeScrollController();
    _initializeControllers();
    _initializeServices();
    _initializeViewModel();
    _wireViewModelCallbacks();
    _initializeProviders();
    _setupKeyboardListeners();
    _setupDesktopFeatures();
  }

  void _initializeAnimations() {
    _convoFadeController = AnimationController(vsync: _vsync, duration: const Duration(milliseconds: 180));
    _convoFade = CurvedAnimation(parent: _convoFadeController, curve: Curves.easeOutCubic);
    _convoFadeController.value = 1.0;
  }

  void _initializeControllers() {
    _chatService = _context.read<ChatService>();
    _chatController = ChatController(chatService: _chatService);
    _streamController = stream_ctrl.StreamController(
      chatService: _chatService,
      onStateChanged: () => notifyListeners(),
      getSettingsProvider: () => _context.read<SettingsProvider>(),
      getCurrentConversationId: () => currentConversation?.id,
      onStreamTick: () => _scrollCtrl.autoScrollToBottomIfNeeded(),
    );
  }

  void _initializeServices() {
    _ocrService = OcrService();
    _translationService = TranslationService(
      chatService: _chatService,
      contextProvider: _context,
    );
    _fileUploadService = FileUploadService(
      mediaController: _mediaController,
      onScrollToBottom: () => _scrollToBottomSoon(),
    );
    _messageBuilderService = MessageBuilderService(
      chatService: _chatService,
      contextProvider: _context,
      ocrHandler: (imagePaths) => _ocrService.getOcrTextForImages(imagePaths, _context),
      geminiThoughtSignatureHandler: _appendGeminiThoughtSignatureForApi,
    );
    _messageBuilderService.ocrTextWrapper = _ocrService.wrapOcrBlock;
    _generationController = GenerationController(
      chatService: _chatService,
      chatController: _chatController,
      streamController: _streamController,
      messageBuilderService: _messageBuilderService,
      contextProvider: _context,
      onStateChanged: () => notifyListeners(),
      getTitleForLocale: _titleForLocale,
    );
    _messageGenerationService = MessageGenerationService(
      chatService: _chatService,
      messageBuilderService: _messageBuilderService,
      generationController: _generationController,
      streamController: _streamController,
      contextProvider: _context,
    );
  }

  void _initializeViewModel() {
    _viewModel = HomeViewModel(
      chatService: _chatService,
      messageBuilderService: _messageBuilderService,
      messageGenerationService: _messageGenerationService,
      generationController: _generationController,
      streamController: _streamController,
      chatController: _chatController,
      contextProvider: _context,
      getTitleForLocale: _titleForLocale,
    );
  }

  void _wireViewModelCallbacks() {
    _viewModel.onError = (error) {
      final l10n = AppLocalizations.of(_context)!;
      showAppSnackBar(_context, message: '${l10n.generationInterrupted}: $error', type: NotificationType.error);
    };
    _viewModel.onRetry =
        (attempt, maxAttempts, errorKind, conversationId) {
      // L1 retry in progress. Show a brief info snackbar so the user
      // knows we are reconnecting instead of silently failing.
      //
      // Guard: ignore retries for conversations the user has since
      // navigated away from. The retry chunk may still be in flight
      // after a conversation switch, and we don't want stale snackbars
      // to pop over the new conversation's content.
      if (conversationId.isNotEmpty &&
          currentConversation?.id != conversationId) {
        return;
      }
      final l10n = AppLocalizations.of(_context)!;
      final isSilent = errorKind == 'silent_interrupt_retry';
      final message = isSilent
          ? l10n.streamRetrySilentInProgress(attempt, maxAttempts)
          : l10n.streamRetryInProgress(attempt, maxAttempts);
      showAppSnackBar(
        _context,
        message: message,
        type: NotificationType.info,
        duration: const Duration(seconds: 2),
      );
    };
    _viewModel.onWarning = (warning) {
      final l10n = AppLocalizations.of(_context)!;
      if (warning == 'no_model') {
        showAppSnackBar(_context, message: l10n.homePagePleaseSelectModel, type: NotificationType.warning);
      }
    };
    _viewModel.onScrollToBottom = () => _scrollToBottomSoon();
    _viewModel.onHapticFeedback = () {
      try {
        final settings = _context.read<SettingsProvider>();
        if (settings.hapticsOnGenerate) Haptics.light();
      } catch (_) {}
    };
    _viewModel.onScheduleImageSanitize = (messageId, content, {bool immediate = false}) {
      _scheduleInlineImageSanitize(messageId, latestContent: content, immediate: immediate);
    };
    _viewModel.onConversationSwitched = () {
      _restoreMessageUiState();
      _scrollToBottom(animate: false);
    };
    _viewModel.onStreamFinished = () {
      // Trigger UI update when streaming finishes
      notifyListeners();
      try {
        final sp = _context.read<SettingsProvider>();
        if (sp.ttsAutoPlayAssistantReplies && messages.isNotEmpty) {
          final lastMsg = messages.last;
          if (lastMsg.role == 'assistant' && lastMsg.content.trim().isNotEmpty) {
            final tts = _context.read<TtsProvider>();
            final text = TtsTextSelection.apply(
              lastMsg.content,
              mode: sp.ttsTextSelectionMode,
            );
            if (text.isNotEmpty && !tts.isSpeaking) {
              tts.speak(text);
            }
          }
        }
      } catch (_) {}
    };
  }

  void _initializeScrollController() {
    _scrollCtrl = scroll_ctrl.ChatScrollController(
      scrollController: _scrollController,
      onStateChanged: () => notifyListeners(),
      getAutoScrollEnabled: () => _context.read<SettingsProvider>().autoScrollEnabled,
      getAutoScrollIdleSeconds: () => _context.read<SettingsProvider>().autoScrollIdleSeconds,
    );
  }

  void _initializeProviders() {
    Future.microtask(() async {
      try {
        await _context.read<QuickPhraseProvider>().initialize();
      } catch (_) {}
    });
    Future.microtask(() async {
      try {
        await _context.read<InstructionInjectionProvider>().initialize();
      } catch (_) {}
    });
    try {
      _mcpProvider = _context.read<McpProvider>();
      _mcpProvider!.addListener(_onMcpChanged);
    } catch (_) {}
  }

  void _setupKeyboardListeners() {
    _inputFocus.addListener(() {
      if (_inputFocus.hasFocus && !isDesktopPlatform) {
        Future.delayed(const Duration(milliseconds: 300), () {
          _scrollCtrl.scrollToBottom();
        });
      }
    });
  }

  void _setupDesktopFeatures() {
    if (isDesktopPlatform) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _inputFocus.requestFocus();
      });
    }
    _chatActionSub = ChatActionBus.instance.stream.listen((action) async {
      switch (action) {
        case ChatAction.newTopic:
          await createNewConversationAnimated();
          break;
        case ChatAction.toggleLeftPanelTopics:
        case ChatAction.toggleLeftPanelAssistants:
          final sp = _context.read<SettingsProvider>();
          if (sp.desktopTopicPosition != DesktopTopicPosition.left) return;
          final wantAssistants = (action == ChatAction.toggleLeftPanelAssistants);
          if (!_tabletSidebarOpen) {
            _tabletSidebarOpen = true;
            notifyListeners();
            try { _context.read<SettingsProvider>().setDesktopSidebarOpen(true); } catch (_) {}
          }
          if (wantAssistants) {
            DesktopSidebarTabBus.instance.switchToAssistants();
          } else {
            DesktopSidebarTabBus.instance.switchToTopics();
          }
          break;
        case ChatAction.focusInput:
          if (isDesktopPlatform) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _inputFocus.requestFocus();
            });
          }
          break;
        case ChatAction.switchModel:
          await showModelSelectSheet(_context);
          break;
      }
    });
  }

  Future<void> initChat() async {
    await _chatService.init();
    final prefs = _context.read<SettingsProvider>();
    if (prefs.newChatOnLaunch) {
      await _createNewConversation();
    } else {
      final conversations = _chatService.getAllConversations();
      if (conversations.isNotEmpty) {
        final recent = conversations.first;
        if ((recent.assistantId ?? '').isNotEmpty) {
          try { await _context.read<AssistantProvider>().setCurrentAssistant(recent.assistantId!); } catch (_) {}
        }
        _chatService.setCurrentConversation(recent.id);
        _chatController.setCurrentConversation(recent);
        _streamController.clearGeminiThoughtSigs();
        _restoreMessageUiState();
        notifyListeners();
        _scrollToBottomSoon(animate: false);
      }
    }
  }

  void initDesktopUi() {
    if (PlatformUtils.isDesktopTarget && !_desktopUiInited) {
      _desktopUiInited = true;
      try {
        final sp = _context.read<SettingsProvider>();
        _embeddedSidebarWidth = sp.desktopSidebarWidth.clamp(_sidebarMinWidth, _sidebarMaxWidth);
        _tabletSidebarOpen = sp.desktopSidebarOpen;
        _rightSidebarOpen = sp.desktopRightSidebarOpen;
        _rightSidebarWidth = sp.desktopRightSidebarWidth.clamp(_sidebarMinWidth, _sidebarMaxWidth);
      } catch (_) {}
    }
  }

  // ============================================================================
  // Public Methods - Message Actions
  // ============================================================================

  Future<void> sendMessage(ChatInputData input) async {
    if (_editingMessage != null) {
      final content = input.text.trim();
      if (content.isEmpty && input.imagePaths.isEmpty && input.documents.isEmpty) return;

      final targetMsg = _editingMessage!;
      _editingMessage = null;

      final imageMarkers = input.imagePaths.map((p) => '\n[image:$p]').join();
      final docMarkers = input.documents.map((d) => '\n[file:${d.path}|${d.fileName}|${d.mime}]').join();
      final nextContent = content + imageMarkers + docMarkers;

      _inputController.clear();
      _mediaController.clearImages();
      _mediaController.clearFiles();

      final newMsg = await _chatService.appendMessageVersion(messageId: targetMsg.id, content: nextContent);
      if (newMsg == null) return;

      messages.add(newMsg);
      final gid = (newMsg.groupId ?? newMsg.id);
      versionSelections[gid] = newMsg.version;
      notifyListeners();

      if (currentConversation != null) {
        try {
          await _chatService.setSelectedVersion(currentConversation!.id, gid, newMsg.version);
        } catch (_) {}
      }

      if (targetMsg.role == 'assistant') {
        await regenerateAtMessage(newMsg, assistantAsNewReply: true);
      } else {
        await regenerateAtMessage(newMsg);
      }
      return;
    }

    final content = input.text.trim();
    if (content.isEmpty && input.imagePaths.isEmpty && input.documents.isEmpty) return;
    if (currentConversation == null) await _createNewConversation();

    final success = await _viewModel.sendMessage(input);
    if (success) {
      notifyListeners();
    }
  }

  void startEditingMessage(ChatMessage message) {
    _editingMessage = message;
    final parsedInput = _messageBuilderService.parseInputFromRaw(message.content);
    _inputController.text = parsedInput.text;
    _inputController.selection = TextSelection.fromPosition(TextPosition(offset: parsedInput.text.length));
    _mediaController.clearImages();
    _mediaController.clearFiles();
    if (parsedInput.imagePaths.isNotEmpty) {
      _mediaController.addImages(parsedInput.imagePaths);
    }
    if (parsedInput.documents.isNotEmpty) {
      _mediaController.addFiles(parsedInput.documents);
    }
    _inputFocus.requestFocus();
    notifyListeners();
  }

  void cancelEditingMessage() {
    if (_editingMessage == null) return;
    _editingMessage = null;
    _inputController.clear();
    _mediaController.clearImages();
    _mediaController.clearFiles();
    notifyListeners();
  }

  Future<void> regenerateAtMessage(ChatMessage message, {bool assistantAsNewReply = false}) async {
    if (currentConversation == null) return;

    final versioning = _messageGenerationService.calculateRegenerationVersioning(
      message: message,
      messages: messages,
      assistantAsNewReply: assistantAsNewReply,
    );
    if (versioning.lastKeep >= 0 && versioning.lastKeep < messages.length - 1) {
      for (int i = versioning.lastKeep + 1; i < messages.length; i++) {
        _translations.remove(messages[i].id);
      }
    }

    final success = await _viewModel.regenerateAtMessage(
      message,
      assistantAsNewReply: assistantAsNewReply,
    );
    if (success) {
      notifyListeners();
    }
  }

  Future<void> cancelStreaming() async {
    await _viewModel.cancelStreaming();
    notifyListeners();
  }

  // ============================================================================
  // Public Methods - Conversation Management
  // ============================================================================

  Future<void> switchConversationAnimated(String id) async {
    cancelEditingMessage();
    try { await _viewModel.flushCurrentConversationProgress(); } catch (_) {}
    if (currentConversation?.id == id) return;
    if (!isDesktopPlatform) {
      try { await _convoFadeController.reverse(); } catch (_) {}
    } else {
      try { _convoFadeController.stop(); _convoFadeController.value = 1.0; } catch (_) {}
    }

    await _viewModel.switchConversation(id);
    notifyListeners();
    try { await WidgetsBinding.instance.endOfFrame; } catch (_) {}
    _scrollToBottom(animate: false);

    if (!isDesktopPlatform) {
      try { await _convoFadeController.forward(); } catch (_) {}
    }
    if (isDesktopPlatform) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _inputFocus.requestFocus();
      });
    }
  }

  Future<void> createNewConversationAnimated() async {
    cancelEditingMessage();
    try { await _viewModel.flushCurrentConversationProgress(); } catch (_) {}
    if (!isDesktopPlatform) {
      try { await _convoFadeController.reverse(); } catch (_) {}
    }
    await _createNewConversation();
    if (!isDesktopPlatform) {
      try { await _convoFadeController.forward(); } catch (_) {}
    }
    if (isDesktopPlatform) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _inputFocus.requestFocus();
      });
    }
  }

  Future<void> _createNewConversation() async {
    cancelEditingMessage();
    _translations.clear();
    await _viewModel.createNewConversation();
    notifyListeners();
    _scrollToBottomSoon(animate: false);
  }

  Future<void> clearContext() async {
    await _viewModel.clearContext();
    notifyListeners();
  }

  /// Compress context: summarize via LLM, create new conversation.
  /// Returns null on success, or an error string on failure.
  Future<String?> compressContext({
    required CompressContextOptions options,
  }) async {
    final result = await _viewModel.compressContext(options: options);
    if (result == null) {
      // Success - switched to new conversation
      _translations.clear();
      notifyListeners();
      _scrollToBottomSoon(animate: false);
    }
    return result;
  }

  // ============================================================================
  // Public Methods - Message Operations
  // ============================================================================

  Future<void> deleteMessage({
    required ChatMessage message,
    required Map<String, List<ChatMessage>> byGroup,
  }) async {
    _translations.remove(message.id);
    await _viewModel.deleteMessage(message: message, byGroup: byGroup);
    notifyListeners();
  }

  Future<void> forkConversation(ChatMessage message) async {
    if (currentConversation == null) return;
    if (!isDesktopPlatform) {
      await _convoFadeController.reverse();
    }

    await _viewModel.forkConversation(message);
    notifyListeners();
    try { await WidgetsBinding.instance.endOfFrame; } catch (_) {}
    _scrollToBottom(animate: false);
    if (!isDesktopPlatform) {
      await _convoFadeController.forward();
    }
  }

  Future<void> editMessage(ChatMessage message) async {
    startEditingMessage(message);
  }

  Future<void> translateMessage(ChatMessage message) async {
    final l10n = AppLocalizations.of(_context)!;

    final result = await _translationService.translateMessage(
      message: message,
      onTranslationStarted: () {
        final loadingMessage = message.copyWith(translation: l10n.homePageTranslating);
        final index = messages.indexWhere((m) => m.id == message.id);
        if (index != -1) {
          messages[index] = loadingMessage;
        }
        _translations[message.id] = TranslationData();
        notifyListeners();
      },
      onTranslationUpdate: (translation) {
        final updatingMessage = message.copyWith(translation: translation);
        final index = messages.indexWhere((m) => m.id == message.id);
        if (index != -1) {
          messages[index] = updatingMessage;
        }
        notifyListeners();
      },
      onTranslationCleared: () {
        final clearedMessage = message.copyWith(translation: '');
        final index = messages.indexWhere((m) => m.id == message.id);
        if (index != -1) {
          messages[index] = clearedMessage;
        }
        _translations.remove(message.id);
        notifyListeners();
      },
    );

    if (result.isCancelled) return;

    if (result.type == TranslationResultType.noModelConfigured) {
      showAppSnackBar(
        _context,
        message: l10n.homePagePleaseSetupTranslateModel,
        type: NotificationType.warning,
      );
      return;
    }

    if (result.type == TranslationResultType.error) {
      showAppSnackBar(
        _context,
        message: l10n.homePageTranslateFailed(result.errorMessage ?? ''),
        type: NotificationType.error,
      );
    }
  }

  Future<void> speakMessage(ChatMessage message) async {
    await _speakAssistantMessage(message, autoPlay: false);
  }

  Future<void> _speakAssistantMessage(
    ChatMessage message, {
    required bool autoPlay,
  }) async {
    final tts = _context.read<TtsProvider>();
    if (!autoPlay && tts.playbackState.isActive) {
      await tts.stop();
      return;
    }

    if (PlatformUtils.isDesktopTarget) {
      final sp = _context.read<SettingsProvider>();
      final hasNetworkTts = sp.selectedTtsService != null;
      if (!hasNetworkTts && !tts.isAvailable) {
        showAppSnackBar(
          _context,
          message: AppLocalizations.of(_context)!.desktopTtsPleaseAddProvider,
          type: NotificationType.warning,
        );
        return;
      }
    }

    final sp = _context.read<SettingsProvider>();
    final text = TtsTextSelection.apply(
      message.content,
      mode: sp.ttsTextSelectionMode,
    );
    if (text.trim().isEmpty) return;
    await tts.speak(text);
  }

  void shareMessage(int messageIndex, List<ChatMessage> messageList) {
    startMessageSelection(
      messageIndex: messageIndex,
      messageList: messageList,
    );
  }

  void startMessageSelection({
    required int messageIndex,
    required List<ChatMessage> messageList,
  }) {
    dismissKeyboard();
    _selecting = true;
    _selectedItems.clear();
    for (int i = 0; i <= messageIndex && i < messageList.length; i++) {
      final m = messageList[i];
      final enabled = (m.role == 'user' || m.role == 'assistant');
      if (enabled) _selectedItems.add(m.id);
    }
    notifyListeners();
  }

  Future<void> confirmSelection() async {
    final convo = currentConversation;
    if (convo == null) return;
    final collapsed = collapseVersions(messages);
    final selected = <ChatMessage>[];
    for (final m in collapsed) {
      if (_selectedItems.contains(m.id)) selected.add(m);
    }
    if (selected.isEmpty) {
      final l10n = AppLocalizations.of(_context)!;
      showAppSnackBar(
        _context,
        message: l10n.homePageSelectMessagesToShare,
        type: NotificationType.info,
      );
      return;
    }
    _selecting = false;
    notifyListeners();
    await showChatExportSheet(_context, conversation: convo, selectedMessages: selected);
    _selectedItems.clear();
    notifyListeners();
  }

  void cancelSelection() {
    _selecting = false;
    _selectedItems.clear();
    notifyListeners();
  }


  void toggleSelection(String messageId, bool selected) {
    if (selected) {
      _selectedItems.add(messageId);
    } else {
      _selectedItems.remove(messageId);
    }
    notifyListeners();
  }

  // ============================================================================
  // Public Methods - Version Management
  // ============================================================================

  Future<void> setSelectedVersion(String groupId, int version) async {
    versionSelections[groupId] = version;
    await _chatService.setSelectedVersion(currentConversation!.id, groupId, version);
    notifyListeners();
  }

  List<ChatMessage> collapseVersions(List<ChatMessage> items) {
    return _chatController.collapseVersions(items);
  }

  // ============================================================================
  // Public Methods - UI State
  // ============================================================================

  void toggleReasoning(String messageId) {
    final r = reasoning[messageId];
    if (r != null) {
      r.expanded = !r.expanded;
      // Check if reasoning is still loading (finishedAt == null means streaming)
      // This is O(1) - no list traversal needed
      final isStillStreaming = r.finishedAt == null && r.text.isNotEmpty;
      if (isStillStreaming && streamingContentNotifier.hasNotifier(messageId)) {
        // For actively streaming messages, use lightweight notifier update
        streamingContentNotifier.forceRebuild(messageId);
      } else {
        // For non-streaming messages, trigger full page rebuild
        notifyListeners();
      }
    }
  }

  void toggleTranslation(String messageId) {
    final t = _translations[messageId];
    if (t != null) {
      t.expanded = !t.expanded;
      notifyListeners();
    }
  }

  void toggleReasoningSegment(String messageId, int segmentIndex) {
    final segments = reasoningSegments[messageId];
    if (segments != null && segmentIndex < segments.length) {
      final seg = segments[segmentIndex];
      seg.expanded = !seg.expanded;
      // Check if this segment is still loading (finishedAt == null means streaming)
      // This is O(1) - no list traversal needed
      final isStillStreaming = seg.finishedAt == null && seg.text.isNotEmpty;
      if (isStillStreaming && streamingContentNotifier.hasNotifier(messageId)) {
        // For actively streaming messages, use lightweight notifier update
        streamingContentNotifier.forceRebuild(messageId);
      } else {
        // For non-streaming messages, trigger full page rebuild
        notifyListeners();
      }
    }
  }

  void setDragHovering(bool hovering) {
    _isDragHovering = hovering;
    notifyListeners();
  }

  // ============================================================================
  // Public Methods - Sidebar Management
  // ============================================================================

  void toggleTabletSidebar() {
    dismissKeyboard();
    try {
      if (_context.read<SettingsProvider>().hapticsOnDrawer) {
        Haptics.drawerPulse();
      }
    } catch (_) {}
    _tabletSidebarOpen = !_tabletSidebarOpen;
    notifyListeners();
    try { _context.read<SettingsProvider>().setDesktopSidebarOpen(_tabletSidebarOpen); } catch (_) {}
  }

  void toggleRightSidebar() {
    dismissKeyboard();
    try {
      if (_context.read<SettingsProvider>().hapticsOnDrawer) {
        Haptics.drawerPulse();
      }
    } catch (_) {}
    _rightSidebarOpen = !_rightSidebarOpen;
    notifyListeners();
    try { _context.read<SettingsProvider>().setDesktopRightSidebarOpen(_rightSidebarOpen); } catch (_) {}
  }

  void updateSidebarWidth(double dx) {
    _embeddedSidebarWidth = (_embeddedSidebarWidth + dx).clamp(_sidebarMinWidth, _sidebarMaxWidth);
    notifyListeners();
  }

  void saveSidebarWidth() {
    try { _context.read<SettingsProvider>().setDesktopSidebarWidth(_embeddedSidebarWidth); } catch (_) {}
  }

  void updateRightSidebarWidth(double dx) {
    _rightSidebarWidth = (_rightSidebarWidth - dx).clamp(_sidebarMinWidth, _sidebarMaxWidth);
    notifyListeners();
  }

  void saveRightSidebarWidth() {
    try { _context.read<SettingsProvider>().setDesktopRightSidebarWidth(_rightSidebarWidth); } catch (_) {}
  }

  // ============================================================================
  // Public Methods - Drawer
  // ============================================================================

  void onDrawerValueChanged(double value) {
    if (_lastDrawerValue <= 0.01 && value > 0.01) {
      dismissKeyboard();
    }
    if (_lastDrawerValue < 0.95 && value >= 0.95) {
      try {
        if (_context.read<SettingsProvider>().hapticsOnDrawer) {
          Haptics.drawerPulse();
        }
      } catch (_) {}
    }
    if (_lastDrawerValue > 0.05 && value <= 0.05) {
      try {
        if (_context.read<SettingsProvider>().hapticsOnDrawer) {
          Haptics.drawerPulse();
        }
      } catch (_) {}
    }
    _lastDrawerValue = value;
  }

  // ============================================================================
  // Public Methods - Input
  // ============================================================================

  void dismissKeyboard() {
    _inputFocus.unfocus();
    FocusManager.instance.primaryFocus?.unfocus();
    try { SystemChannels.textInput.invokeMethod('TextInput.hide'); } catch (_) {}
  }

  void measureInputBar() {
    try {
      final ctx = _inputBarKey.currentContext;
      if (ctx == null) return;
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null) return;
      final h = box.size.height;
      if ((_inputBarHeight - h).abs() > 1.0) {
        _inputBarHeight = h;
        notifyListeners();
      }
    } catch (_) {}
  }

  // ============================================================================
  // Public Methods - Quick Phrases
  // ============================================================================

  Future<void> handleQuickPhraseSelection(QuickPhrase? selected) async {
    if (selected == null) return;
    final text = _inputController.text;
    final selection = _inputController.selection;
    final start = (selection.start >= 0 && selection.start <= text.length)
        ? selection.start
        : text.length;
    final end = (selection.end >= 0 && selection.end <= text.length && selection.end >= start)
        ? selection.end
        : start;

    final newText = text.replaceRange(start, end, selected.content);
    _inputController.value = _inputController.value.copyWith(
      text: newText,
      selection: TextSelection.collapsed(offset: start + selected.content.length),
      composing: TextRange.empty,
    );
    notifyListeners();
  }

  // ============================================================================
  // Public Methods - File Upload
  // ============================================================================

  Future<void> onPickPhotos() => _fileUploadService.onPickPhotos();
  Future<void> onPickCamera() => _fileUploadService.onPickCamera(_context);
  Future<void> onPickFiles() => _fileUploadService.onPickFiles();
  Future<void> onFilesDroppedDesktop(List<XFile> files) => _fileUploadService.onFilesDroppedDesktop(files);

  // ============================================================================
  // Public Methods - Scroll
  // ============================================================================

  void scrollToBottom({bool animate = true}) => _scrollToBottom(animate: animate);
  void forceScrollToBottom() => _scrollCtrl.forceScrollToBottom();
  void forceScrollToBottomSoon({bool animate = true}) => _scrollCtrl.forceScrollToBottomSoon(
    animate: animate,
    postSwitchDelay: _postSwitchScrollDelay,
  );

  Future<void> scrollToMessageId(String targetId) async {
    final collapsed = collapseVersions(messages);
    await _scrollCtrl.scrollToMessageId(
      targetId: targetId,
      messages: collapsed,
      messageKeys: _messageKeys,
      getViewportBounds: _getViewportBounds,
      getViewHeight: () => MediaQuery.sizeOf(_context).height,
    );
  }

  Future<void> jumpToPreviousQuestion() async {
    final collapsed = collapseVersions(messages);
    await _scrollCtrl.jumpToPreviousQuestion(
      messages: collapsed,
      messageKeys: _messageKeys,
      getViewportBounds: _getViewportBounds,
    );
  }

  Future<void> jumpToNextQuestion() async {
    final collapsed = collapseVersions(messages);
    await _scrollCtrl.jumpToNextQuestion(
      messages: collapsed,
      messageKeys: _messageKeys,
      getViewportBounds: _getViewportBounds,
    );
  }

  void scrollToTop({bool animate = true}) {
    _scrollCtrl.scrollToTop(animate: animate);
  }

  // ============================================================================
  // Public Methods - Model Checks
  // ============================================================================

  bool isReasoningModel(String providerKey, String modelId) {
    return _generationController.isReasoningModel(providerKey, modelId);
  }

  bool isToolModel(String providerKey, String modelId) {
    return _generationController.isToolModel(providerKey, modelId);
  }

  bool isReasoningEnabled(int? budget) {
    if (budget == null) return true;
    if (budget == -1) return true;
    return budget >= 1024;
  }

  // ============================================================================
  // Public Methods - Helpers
  // ============================================================================

  String titleForLocale() => _titleForLocale(_context);

  String clearContextLabel() {
    final l10n = AppLocalizations.of(_context)!;
    return _viewModel.getClearContextLabel(
      (actual, configured) => l10n.homePageClearContextWithCount(actual, configured),
      l10n.homePageClearContext,
    );
  }

  String? currentStreamingMessageId() {
    for (int i = messages.length - 1; i >= 0; i--) {
      final m = messages[i];
      if (m.role == 'assistant' && m.isStreaming) return m.id;
    }
    return null;
  }

  bool shouldPinStreamingIndicator(String? messageId) {
    if (messageId == null) return false;
    if (_scrollCtrl.isUserScrolling) return false;
    if (!_scrollCtrl.hasEnoughContentToScroll(56.0)) return false;
    if (!_scrollCtrl.isNearBottom(48)) return false;
    return true;
  }

  /// Transform raw content using assistant regexes.
  String transformAssistantContent(stream_ctrl.StreamingState state, [String? raw]) {
    return applyAssistantRegexes(
      raw ?? state.fullContentRaw,
      assistant: state.ctx.assistant,
      scope: AssistantRegexScope.assistant,
      visual: false,
    );
  }

  // ============================================================================
  // Lifecycle Management
  // ============================================================================

  void onAppLifecycleStateChanged(AppLifecycleState state) {
    _appInForeground = (state == AppLifecycleState.resumed);
    if (state == AppLifecycleState.resumed) {
      ScreenWakelock.reassert();
    }
  }

  void onDidPopNext() {
    if (isDesktopPlatform) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _inputFocus.requestFocus();
      });
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => dismissKeyboard());
    }
  }

  void onDidPushNext() {
    dismissKeyboard();
  }

  // ============================================================================
  // Private Methods
  // ============================================================================

  String _titleForLocale(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return l10n.titleForLocale;
  }

  void _scrollToBottom({bool animate = true}) => _scrollCtrl.scrollToBottom(animate: animate);
  void _scrollToBottomSoon({bool animate = true}) => _scrollCtrl.scrollToBottomSoon(animate: animate);

  (double, double) _getViewportBounds() {
    final size = MediaQuery.sizeOf(_context);
    final padding = MediaQuery.paddingOf(_context);
    final double listTop = kToolbarHeight + padding.top;
    final double listBottom = size.height - padding.bottom - _inputBarHeight - 8;
    return (listTop, listBottom);
  }

  void _restoreMessageUiState() {
    for (int i = 0; i < messages.length; i++) {
      final m = messages[i];
      if (m.role == 'assistant') {
        _streamController.restoreMessageUiState(
          m,
          getToolEventsFromDb: (id) => _chatService.getToolEvents(id),
          getGeminiThoughtSigFromDb: (id) => _chatService.getGeminiThoughtSignature(id),
        );

        final cleanedContent = _streamController.captureGeminiThoughtSignature(m.content, m.id);
        if (cleanedContent != m.content) {
          final updated = m.copyWith(content: cleanedContent);
          messages[i] = updated;
          unawaited(_chatService.updateMessage(m.id, content: cleanedContent));
        }

        _scheduleInlineImageSanitize(m.id, latestContent: messages[i].content, immediate: true);
      }

      if (m.translation != null && m.translation!.isNotEmpty) {
        final td = TranslationData();
        td.expanded = false;
        _translations[m.id] = td;
      }
    }
  }

  void _scheduleInlineImageSanitize(String messageId, {String? latestContent, bool immediate = false}) {
    final snapshot = latestContent ??
        (() {
          final idx = messages.indexWhere((m) => m.id == messageId);
          return idx == -1 ? '' : messages[idx].content;
        })();
    if (snapshot.isEmpty || !snapshot.contains('data:image') || !snapshot.contains('base64,')) {
      return;
    }

    _streamController.scheduleInlineImageSanitize(
      messageId,
      latestContent: snapshot,
      immediate: immediate,
      onSanitized: (id, sanitized) async {
        await _chatService.updateMessage(id, content: sanitized);
        final i = messages.indexWhere((m) => m.id == id);
        if (i != -1) {
          messages[i] = messages[i].copyWith(content: sanitized);
        }
        notifyListeners();
      },
    );
  }

  String _appendGeminiThoughtSignatureForApi(ChatMessage message, String content) {
    return _streamController.appendGeminiThoughtSignatureForApi(message, content);
  }

  Future<void> _onMcpChanged() async {
    // Kept for potential future use
  }

  // ============================================================================
  // Disposal
  // ============================================================================

  @override
  void dispose() {
    _disposed = true;
    _cancelDictationWatchdog();
    // 若仍在聽寫（含暫停以外的聆聽中狀態），釋放麥克風。
    _stopDictationEngine();
    _convoFadeController.dispose();
    _mcpProvider?.removeListener(_onMcpChanged);
    _scrollCtrl.dispose();
    try { _chatActionSub?.cancel(); } catch (_) {}
    _chatController.dispose();
    _streamController.dispose();
    super.dispose();
  }
}
