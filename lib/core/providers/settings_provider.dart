import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'package:socks5_proxy/socks_client.dart' as socks;
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'dart:convert';
import '../services/search/search_service.dart';
import '../services/stt/network_stt.dart';
import '../services/tts/network_tts.dart';
import '../services/tts/tts_text_selection.dart';
import '../services/live/live_api_models_service.dart';
import '../services/live/live_api_key_store.dart';
import '../services/network/request_logger.dart';
import '../services/logging/flutter_logger.dart';
import '../models/api_keys.dart';
import '../models/backup.dart';
import '../models/workspace_config.dart';
import '../services/haptics.dart';
import '../services/screen_wakelock.dart';
import '../../utils/app_directories.dart';
import '../../utils/sandbox_path_resolver.dart';
import '../../utils/avatar_cache.dart';
import '../utils/reasoning_capabilities.dart';

// Desktop: topic list position
enum DesktopTopicPosition { left, right }

// Voice Call mode: standard (STT → LLM → TTS) vs Gemini Live API.
enum VoiceCallMode { standard, liveApi }

/// Live API 官方預設與可選音色清單。
class VoiceCallDefaults {
  VoiceCallDefaults._();

  /// 官方 WebSocket 端點（`liveApiBaseUrl` 為空時使用）。
  static const String officialBaseUrl =
      'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent';

  /// 官方預設模型。
  static const String defaultModel = 'gemini-3.1-flash-live-preview';

  /// 官方預設音色。
  static const String defaultVoice = 'Kore';

  /// 可用音色清單（供設定頁選擇）。
  static const List<String> voices = <String>[
    'Kore',
    'Puck',
    'Charon',
    'Aoede',
    'Fenrir',
    'Leda',
    'Orus',
    'Zephyr',
  ];
}

class SettingsProvider extends ChangeNotifier {
  static const String _providersOrderKey = 'providers_order_v1';
  static const String _themeModeKey = 'theme_mode_v1';
  static const String _providerConfigsKey = 'provider_configs_v1';
  static const String _pinnedModelsKey = 'pinned_models_v1';
  static const String _selectedModelKey = 'selected_model_v1';
  static const String _titleModelKey = 'title_model_v1';
  static const String _titlePromptKey = 'title_prompt_v1';
  static const String _ocrModelKey = 'ocr_model_v1';
  static const String _ocrPromptKey = 'ocr_prompt_v1';
  static const String _summaryModelKey = 'summary_model_v1';
  static const String _summaryPromptKey = 'summary_prompt_v1';
  static const String _compressModelKey = 'compress_model_v1';
  static const String _compressPromptKey = 'compress_prompt_v1';
  static const String _themePaletteKey = 'theme_palette_v1';
  static const String _useDynamicColorKey = 'use_dynamic_color_v1';
  static const String _thinkingBudgetKey = 'thinking_budget_v1';
  static const String _titleGenerationThinkingEnabledKey =
      'title_generation_thinking_enabled_v1';
  static const String _greetingGenerationThinkingEnabledKey =
      'greeting_generation_thinking_enabled_v1';

  static const String _displayShowUserAvatarKey = 'display_show_user_avatar_v1';
  static const String _displayShowModelIconKey = 'display_show_model_icon_v1';
  static const String _displayShowModelNameTimestampKey =
      'display_show_model_name_timestamp_v1';
  static const String _displayShowTokenStatsKey = 'display_show_token_stats_v1';
  static const String _displayShowUserNameTimestampKey =
      'display_show_user_name_timestamp_v1';
  static const String _displayShowUserMessageActionsKey =
      'display_show_user_message_actions_v1';
  static const String _displayShowThinkingCardsKey =
      'display_show_thinking_cards_v1';
  static const String _displayShowToolCardsKey = 'display_show_tool_cards_v1';
  static const String _displayAutoCollapseThinkingKey =
      'display_auto_collapse_thinking_v1';
  static const String _displayReplayToolResultsKey =
      'display_replay_tool_results_v1';
  static const String _displayShowMessageNavKey = 'display_show_message_nav_v1';
  static const String _displayShowProviderInModelCapsuleKey =
      'display_show_provider_in_model_capsule_v1';
  static const String _displayHapticsOnGenerateKey =
      'display_haptics_on_generate_v1';
  static const String _displayHapticsOnDrawerKey =
      'display_haptics_on_drawer_v1';
  static const String _displayHapticsGlobalEnabledKey =
      'display_haptics_global_enabled_v1';
  static const String _displayHapticsIosSwitchKey =
      'display_haptics_ios_switch_v1';
  static const String _displayHapticsOnListItemTapKey =
      'display_haptics_on_list_item_tap_v1';
  static const String _displayHapticsOnCardTapKey =
      'display_haptics_on_card_tap_v1';
  static const String _displayKeepScreenOnDuringGenerationKey =
      'display_keep_screen_on_during_generation_v1';
  static const String _displayLongPasteAsFileKey =
      'display_long_paste_as_file_v1';
  static const String _displayLongPasteAsFileThresholdKey =
      'display_long_paste_as_file_threshold_v1';
  static const String _displayShowAppUpdatesKey = 'display_show_app_updates_v1';
  static const String _displayKeepSidebarOpenOnAssistantTapKey =
      'display_keep_sidebar_open_on_assistant_tap_v1';
  static const String _displayKeepSidebarOpenOnTopicTapKey =
      'display_keep_sidebar_open_on_topic_tap_v1';
  static const String _displayKeepAssistantListExpandedOnSidebarCloseKey =
      'display_keep_assistant_list_expanded_on_sidebar_close_v1';
  static const String _displayNewChatOnAssistantSwitchKey =
      'display_new_chat_on_assistant_switch_v1';
  static const String _displayNewChatOnLaunchKey =
      'display_new_chat_on_launch_v1';
  static const String _displayNewChatAfterDeleteKey =
      'display_new_chat_after_delete_v1';
  static const String _displayChatFontScaleKey = 'display_chat_font_scale_v1';
  static const String _displayAutoScrollEnabledKey =
      'display_auto_scroll_enabled_v1';
  static const String _displayAutoScrollIdleSecondsKey =
      'display_auto_scroll_idle_seconds_v1';
  static const String _displayChatBackgroundMaskStrengthKey =
      'display_chat_background_mask_strength_v1';
  static const String _displayEnableDollarLatexKey =
      'display_enable_dollar_latex_v1';
  static const String _displayEnableMathRenderingKey =
      'display_enable_math_rendering_v1';
  static const String _displayEnableUserMarkdownKey =
      'display_enable_user_markdown_v1';
  static const String _displayEnableReasoningMarkdownKey =
      'display_enable_reasoning_markdown_v1';
  static const String _displayShowChatListDateKey =
      'display_show_chat_list_date_v1';
  static const String _displayMobileCodeBlockWrapKey =
      'display_mobile_code_block_wrap_v1';
  static const String _displayAutoCollapseCodeBlockKey =
      'display_auto_collapse_code_block_v1';
  static const String _displayAutoCollapseCodeBlockLinesKey =
      'display_auto_collapse_code_block_lines_v1';
  static const String _displayDesktopAutoSwitchTopicsKey =
      'display_desktop_auto_switch_topics_v1';
  static const String _displayDesktopShowTrayKey =
      'display_desktop_show_tray_v1';
  static const String _displayDesktopMinimizeToTrayOnCloseKey =
      'display_desktop_minimize_to_tray_on_close_v1';
  static const String _displayUsePureBackgroundKey =
      'display_use_pure_background_v1';
  static const String _displayChatMessageBackgroundStyleKey =
      'display_chat_message_background_style_v1';
  // Chat input bar button order / visibility
  static const String _chatInputButtonOrderKey = 'chat_input_button_order_v1';
  static const String _chatInputButtonHiddenKey = 'chat_input_button_hidden_v1';
  // Image generation aspect ratio (global, shared across image models)
  static const String _imageAspectRatioKey = 'image_aspect_ratio_v1';
  // Network request logging (debug)
  static const String _requestLogEnabledKey = 'request_log_enabled_v1';
  // Flutter runtime logging (debug)
  static const String _flutterLogEnabledKey = 'flutter_log_enabled_v1';
  // Desktop topic panel placement + right sidebar open state
  static const String _desktopTopicPositionKey = 'desktop_topic_position_v1';
  static const String _desktopRightSidebarOpenKey =
      'desktop_right_sidebar_open_v1';
  // Android background chat generation mode
  static const String _androidBackgroundChatModeKey =
      'android_background_chat_mode_v1';
  // Fonts
  static const String _displayAppFontFamilyKey = 'display_app_font_family_v1';
  static const String _displayCodeFontFamilyKey = 'display_code_font_family_v1';
  static const String _displayAppFontIsGoogleKey =
      'display_app_font_is_google_v1';
  static const String _displayCodeFontIsGoogleKey =
      'display_code_font_is_google_v1';
  static const String _displayAppFontLocalPathKey =
      'display_app_font_local_path_v1';
  static const String _displayCodeFontLocalPathKey =
      'display_code_font_local_path_v1';
  static const String _displayAppFontLocalAliasKey =
      'display_app_font_local_alias_v1';
  static const String _displayCodeFontLocalAliasKey =
      'display_code_font_local_alias_v1';
  static const String _appLocaleKey = 'app_locale_v1';
  static const String _translateModelKey = 'translate_model_v1';
  static const String _translatePromptKey = 'translate_prompt_v1';
  static const String _greetingModelKey = 'greeting_model_v1';
  static const String _greetingPromptKey = 'greeting_prompt_v1';
  static const String _newChatLogoTypeKey = 'new_chat_logo_type_v1';
  static const String _defaultWorkspacePathKey = 'default_workspace_path_v1';
  static const String _defaultWorkspaceConfigKey =
      'default_workspace_config_v1';
  static const String _newChatCustomLogoFileNameKey =
      'new_chat_custom_logo_file_name_v1';
  static const String _newChatTextTypeKey = 'new_chat_text_type_v1';
  static const String _newChatCustomTextKey = 'new_chat_custom_text_v1';
  static const String _newChatCachedAiGreetingKey =
      'new_chat_cached_ai_greeting_v1';
  static const String _ocrEnabledKey = 'ocr_enabled_v1';
  static const String _deepResearchEnabledKey = 'learning_mode_enabled_v1';
  static const String _deepResearchPromptKey = 'learning_mode_prompt_v1';
  static const String _searchServicesKey = 'search_services_v1';
  static const String _searchCommonKey = 'search_common_v1';
  static const String _searchSelectedKey = 'search_selected_v1';
  static const String _searchEnabledKey = 'search_enabled_v1';
  static const String _searchAutoTestOnLaunchKey =
      'search_auto_test_on_launch_v1';
  // Standalone academic MCP config (PubMed / Semantic Scholar API keys),
  // independent from the web search services list.
  static const String _academicConfigKey = 'academic_search_config_v1';
  static const String _webDavConfigKey = 'webdav_config_v1';
  static const String _dropboxConfigKey = 'dropbox_config_v1';
  // Global network proxy
  static const String _globalProxyEnabledKey = 'global_proxy_enabled_v1';
  static const String _globalProxyTypeKey =
      'global_proxy_type_v1'; // http|https|socks5 (socks5 not yet supported)
  static const String _globalProxyHostKey = 'global_proxy_host_v1';
  static const String _globalProxyPortKey = 'global_proxy_port_v1';
  static const String _globalProxyUsernameKey = 'global_proxy_username_v1';
  static const String _globalProxyPasswordKey = 'global_proxy_password_v1';
  // TTS services (network & settings)
  static const String _ttsServicesKey = 'tts_services_v1';
  static const String _ttsSelectedKey = 'tts_selected_v1';
  static const String _ttsAutoPlayRepliesKey = 'tts_auto_play_replies_v1';
  static const String _ttsTextSelectionModeKey = 'tts_text_selection_mode_v1';
  // STT services (network & settings)
  static const String _sttServicesKey = 'stt_services_v1';
  static const String _sttSelectedKey = 'stt_selected_v1';
  static const String _sttSystemLocaleKey = 'stt_system_locale_v1';
  // Voice Call (Live API) settings — 直屬欄位，不寫入 ProviderConfig（與 TTS/STT 相同）。
  // API Key 不在此列：§5.8 起存於 flutter_secure_storage（見 LiveApiKeyStore），
  // 舊 SharedPreferences 位置（'live_api_key_v1'）僅作為遷移來源。
  static const String _voiceCallModeKey = 'voice_call_mode_v1';
  static const String _liveApiBaseUrlKey = 'live_api_base_url_v1';
  static const String _liveApiModelKey = 'live_api_model_v1';
  static const String _liveApiVoiceKey = 'live_api_voice_v1';
  // Desktop UI
  static const String _desktopSidebarWidthKey = 'desktop_sidebar_width_v1';
  static const String _desktopSidebarOpenKey = 'desktop_sidebar_open_v1';
  static const String _desktopRightSidebarWidthKey =
      'desktop_right_sidebar_width_v1';

  // ===== Network TTS services =====
  List<TtsServiceOptions> _ttsServices = const <TtsServiceOptions>[];
  int _ttsServiceSelected = -1; // -1 => use System TTS
  bool _ttsAutoPlayAssistantReplies = false;
  TtsTextSelectionMode _ttsTextSelectionMode = TtsTextSelectionMode.fullText;

  List<TtsServiceOptions> get ttsServices => _ttsServices;
  int get ttsServiceSelected => _ttsServiceSelected;
  bool get usingSystemTts => _ttsServiceSelected < 0;
  TtsServiceOptions? get selectedTtsService =>
      (_ttsServiceSelected >= 0 && _ttsServiceSelected < _ttsServices.length)
      ? _ttsServices[_ttsServiceSelected]
      : null;
  bool get ttsAutoPlayAssistantReplies => _ttsAutoPlayAssistantReplies;
  TtsTextSelectionMode get ttsTextSelectionMode => _ttsTextSelectionMode;

  // ===== Network STT services =====
  List<SttServiceOptions> _sttServices = const <SttServiceOptions>[];
  int _sttServiceSelected = -1; // -1 => use System STT
  String? _sttSystemLocaleId; // null => auto (follow app locale)

  List<SttServiceOptions> get sttServices => _sttServices;
  int get sttServiceSelected => _sttServiceSelected;
  bool get usingSystemStt => _sttServiceSelected < 0;
  SttServiceOptions? get selectedSttService =>
      (_sttServiceSelected >= 0 && _sttServiceSelected < _sttServices.length)
      ? _sttServices[_sttServiceSelected]
      : null;
  String? get sttSystemLocaleId => _sttSystemLocaleId;

  // ===== Voice Call (Live API) settings =====
  VoiceCallMode _voiceCallMode = VoiceCallMode.standard;
  String _liveApiBaseUrl = '';
  String _liveApiApiKey = '';
  String _liveApiModel = VoiceCallDefaults.defaultModel;
  String _liveApiVoice = VoiceCallDefaults.defaultVoice;

  VoiceCallMode get voiceCallMode => _voiceCallMode;
  bool get usingLiveApi => _voiceCallMode == VoiceCallMode.liveApi;
  String get liveApiBaseUrl => _liveApiBaseUrl;
  String get liveApiApiKey => _liveApiApiKey;
  String get liveApiModel => _liveApiModel;
  String get liveApiVoice => _liveApiVoice;
  /// Live API 是否已完成設定（金鑰非空）。空金鑰時 Live API 入口置灰。
  bool get liveApiConfigured =>
      _liveApiApiKey.trim().isNotEmpty && _liveApiModel.trim().isNotEmpty;
  /// 空 Base URL 回退官方預設（`wss://generativelanguage.googleapis.com/ws/...`）。
  String get resolvedLiveApiBaseUrl =>
      _liveApiBaseUrl.trim().isEmpty
          ? VoiceCallDefaults.officialBaseUrl
          : _liveApiBaseUrl.trim();

  List<String> _providersOrder = const [];
  List<String> get providersOrder => _providersOrder;

  // Chat input bar button order (empty => default catalog order)
  List<String> _chatInputButtonOrder = const [];
  List<String> get chatInputButtonOrder => _chatInputButtonOrder;
  // Chat input bar buttons hidden by the user (button ids)
  List<String> _chatInputButtonHidden = const [];
  List<String> get chatInputButtonHidden => _chatInputButtonHidden;

  // Aspect ratio for image generation models ('1:1' | '3:4' | '4:3' | '16:9' | '9:16')
  String _imageAspectRatio = '1:1';
  String get imageAspectRatio => _imageAspectRatio;

  ThemeMode _themeMode = ThemeMode.system;
  ThemeMode get themeMode => _themeMode;
  // Theme palette & dynamic color
  String _themePaletteId = 'blue';
  String get themePaletteId => _themePaletteId;
  bool _useDynamicColor = true; // when supported on Android
  bool get useDynamicColor => _useDynamicColor;
  bool _dynamicColorSupported = false; // runtime capability, not persisted
  bool get dynamicColorSupported => _dynamicColorSupported;

  // When enabled, force pure white/black backgrounds regardless of theme color
  bool _usePureBackground = false;
  bool get usePureBackground => _usePureBackground;

  // Desktop UI persisted state
  double _desktopSidebarWidth = 240;
  bool _desktopSidebarOpen = true;
  double get desktopSidebarWidth => _desktopSidebarWidth;
  bool get desktopSidebarOpen => _desktopSidebarOpen;
  double _desktopRightSidebarWidth = 300;
  double get desktopRightSidebarWidth => _desktopRightSidebarWidth;

  // Desktop: topic list position (left or right) and right sidebar open state
  DesktopTopicPosition _desktopTopicPosition = DesktopTopicPosition.left;
  DesktopTopicPosition get desktopTopicPosition => _desktopTopicPosition;
  bool get desktopTopicsOnRight =>
      _desktopTopicPosition == DesktopTopicPosition.right;
  bool _desktopRightSidebarOpen = true;
  bool get desktopRightSidebarOpen => _desktopRightSidebarOpen;

  Map<String, ProviderConfig> _providerConfigs = {};
  Map<String, ProviderConfig> get providerConfigs =>
      Map.unmodifiable(_providerConfigs);
  bool get hasAnyActiveModel =>
      _providerConfigs.values.any((c) => c.enabled && c.models.isNotEmpty);
  // Returns a config for the given key without mutating internal state when missing.
  // This avoids implicitly creating providers during read paths (e.g., rendering old chats).
  ProviderConfig getProviderConfig(String key, {String? defaultName}) {
    final existed = _providerConfigs[key];
    if (existed != null) return existed;
    // Return a non-persisted, default-constructed config for read-only scenarios.
    return ProviderConfig.defaultsFor(key, displayName: defaultName);
  }

  // Explicitly ensure a provider config exists in memory (without persisting to storage).
  // Useful for seeding first-run defaults.
  ProviderConfig ensureProviderConfig(String key, {String? defaultName}) {
    final existed = _providerConfigs[key];
    if (existed != null) return existed;
    final cfg = ProviderConfig.defaultsFor(key, displayName: defaultName);
    _providerConfigs[key] = cfg;
    return cfg;
  }

  // Search service settings
  List<SearchServiceOptions> _searchServices = [
    SearchServiceOptions.defaultOption,
  ];
  List<SearchServiceOptions> get searchServices =>
      List.unmodifiable(_searchServices);
  // Standalone academic MCP settings (PubMed / Semantic Scholar keys).
  // These live in their own namespace and do NOT depend on the web search
  // services list — the built-in Academic_Search MCP server reads them.
  AcademicMcpConfig _academicConfig = const AcademicMcpConfig();
  AcademicMcpConfig get academicConfig => _academicConfig;
  SearchCommonOptions _searchCommonOptions = const SearchCommonOptions();
  SearchCommonOptions get searchCommonOptions => _searchCommonOptions;
  int _searchServiceSelected = 0;
  int get searchServiceSelected => _searchServiceSelected;
  bool _searchEnabled = false;
  bool get searchEnabled => _searchEnabled;
  bool _searchAutoTestOnLaunch = false;
  bool get searchAutoTestOnLaunch => _searchAutoTestOnLaunch;
  // Ephemeral connection test results: serviceId -> connected (true), failed (false), or null (not tested)
  final Map<String, bool?> _searchConnection = <String, bool?>{};
  Map<String, bool?> get searchConnection =>
      Map.unmodifiable(_searchConnection);

  // ===== Global Proxy Settings =====
  bool _globalProxyEnabled = false;
  String _globalProxyType = 'http';
  String _globalProxyHost = '';
  String _globalProxyPort = '8080';
  String _globalProxyUsername = '';
  String _globalProxyPassword = '';

  bool get globalProxyEnabled => _globalProxyEnabled;
  String get globalProxyType => _globalProxyType; // http|https|socks5
  String get globalProxyHost => _globalProxyHost;
  String get globalProxyPort => _globalProxyPort;
  String get globalProxyUsername => _globalProxyUsername;
  String get globalProxyPassword => _globalProxyPassword;

  WorkspaceConfig _defaultWorkspaceConfig = const WorkspaceConfig.useDefault();
  WorkspaceConfig get defaultWorkspaceConfig => _defaultWorkspaceConfig;

  static const String _appLaunchCountKey = 'app_launch_count_v1';

  int _appLaunchCount = 0;
  int get appLaunchCount => _appLaunchCount;

  /// §5.8：Live API Key 儲存（secure storage + legacy 遷移）。
  /// 測試可注入 fake 以隔離 platform channel。
  final LiveApiKeyStore _liveApiKeyStore;

  SettingsProvider({LiveApiKeyStore? liveApiKeyStore})
      : _liveApiKeyStore = liveApiKeyStore ?? LiveApiKeyStore() {
    _load();
  }

  ReasoningCapabilities reasoningCapabilities(
    String providerKey,
    String modelId,
  ) {
    final cfg = getProviderConfig(providerKey);
    final kind = ProviderConfig.classify(
      cfg.id,
      explicitType: cfg.providerType,
    );
    final rawOverride = cfg.modelOverrides[modelId];
    final override = rawOverride is Map
        ? rawOverride.cast<String, dynamic>()
        : const <String, dynamic>{};
    final overriddenId = (override['apiModelId'] ?? override['api_model_id'])
        ?.toString()
        .trim();
    final effectiveModelId = overriddenId == null || overriddenId.isEmpty
        ? modelId
        : overriddenId;

    final transport = switch (kind) {
      ProviderKind.openai => ReasoningTransport.openAi,
      ProviderKind.neuralwatt => ReasoningTransport.openAi,
      ProviderKind.claude => ReasoningTransport.claude,
      ProviderKind.google => ReasoningTransport.google,
    };
    return ReasoningCapabilities.forModel(transport, effectiveModelId);
  }

  bool supportsXhighReasoning(String providerKey, String modelId) =>
      reasoningCapabilities(providerKey, modelId).supportsXhigh;

  bool supportsMaxReasoning(String providerKey, String modelId) =>
      reasoningCapabilities(providerKey, modelId).supportsMax;

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _appLaunchCount = (prefs.getInt(_appLaunchCountKey) ?? 0) + 1;
    await prefs.setInt(_appLaunchCountKey, _appLaunchCount);
    _providersOrder = prefs.getStringList(_providersOrderKey) ?? [];
    _chatInputButtonOrder =
        prefs.getStringList(_chatInputButtonOrderKey) ?? const [];
    _chatInputButtonHidden =
        prefs.getStringList(_chatInputButtonHiddenKey) ?? const [];
    _imageAspectRatio = prefs.getString(_imageAspectRatioKey) ?? '1:1';
    final m = prefs.getString(_themeModeKey);
    switch (m) {
      case 'light':
        _themeMode = ThemeMode.light;
        break;
      case 'dark':
        _themeMode = ThemeMode.dark;
        break;
      default:
        _themeMode = ThemeMode.system;
    }
    _themePaletteId = prefs.getString(_themePaletteKey) ?? 'blue';
    _useDynamicColor = prefs.getBool(_useDynamicColorKey) ?? true;
    final savedConfig = prefs.getString(_defaultWorkspaceConfigKey);
    if (savedConfig != null && savedConfig.isNotEmpty) {
      try {
        _defaultWorkspaceConfig = WorkspaceConfig.fromJson(
          jsonDecode(savedConfig),
          fallback: WorkspaceMode.useDefault,
        );
      } catch (_) {
        _defaultWorkspaceConfig = const WorkspaceConfig.useDefault();
      }
    } else {
      // Migrate the legacy single-path setting (null = app private directory).
      final legacyPath = prefs.getString(_defaultWorkspacePathKey)?.trim();
      if (legacyPath != null && legacyPath.isNotEmpty) {
        _defaultWorkspaceConfig = WorkspaceConfig.custom(legacyPath);
        await prefs.setString(
          _defaultWorkspaceConfigKey,
          jsonEncode(_defaultWorkspaceConfig.toJson()),
        );
        await prefs.remove(_defaultWorkspacePathKey);
      }
    }
    final cfgStr = prefs.getString(_providerConfigsKey);
    if (cfgStr != null && cfgStr.isNotEmpty) {
      try {
        final raw = jsonDecode(cfgStr) as Map<String, dynamic>;
        _providerConfigs = raw.map(
          (k, v) =>
              MapEntry(k, ProviderConfig.fromJson(v as Map<String, dynamic>)),
        );
      } catch (_) {}
    }
    // load pinned models
    final pinned = prefs.getStringList(_pinnedModelsKey) ?? const <String>[];
    _pinnedModels
      ..clear()
      ..addAll(pinned);
    // load selected model
    final sel = prefs.getString(_selectedModelKey);
    if (sel != null && sel.contains('::')) {
      final parts = sel.split('::');
      if (parts.length >= 2) {
        _currentModelProvider = parts[0];
        _currentModelId = parts.sublist(1).join('::');
      }
    }
    // load title model
    final titleSel = prefs.getString(_titleModelKey);
    if (titleSel != null && titleSel.contains('::')) {
      final parts = titleSel.split('::');
      if (parts.length >= 2) {
        _titleModelProvider = parts[0];
        _titleModelId = parts.sublist(1).join('::');
      }
    }
    // load title prompt
    final tp = prefs.getString(_titlePromptKey);
    _titlePrompt = (tp == null || tp.trim().isEmpty) ? defaultTitlePrompt : tp;
    // load translate model
    final translateSel = prefs.getString(_translateModelKey);
    if (translateSel != null && translateSel.contains('::')) {
      final parts = translateSel.split('::');
      if (parts.length >= 2) {
        _translateModelProvider = parts[0];
        _translateModelId = parts.sublist(1).join('::');
      }
    }
    // load translate prompt
    final transp = prefs.getString(_translatePromptKey);
    _translatePrompt = (transp == null || transp.trim().isEmpty)
        ? defaultTranslatePrompt
        : transp;
    // load greeting model
    final greetingSel = prefs.getString(_greetingModelKey);
    if (greetingSel != null && greetingSel.contains('::')) {
      final parts = greetingSel.split('::');
      if (parts.length >= 2) {
        _greetingModelProvider = parts[0];
        _greetingModelId = parts.sublist(1).join('::');
      }
    }
    // load greeting prompt
    final greetingp = prefs.getString(_greetingPromptKey);
    _greetingPrompt = (greetingp == null || greetingp.trim().isEmpty)
        ? defaultGreetingPrompt
        : greetingp;
    // load new chat empty state settings
    _newChatLogoType = prefs.getString(_newChatLogoTypeKey) ?? 'model';
    _newChatCustomLogoFileName = prefs.getString(_newChatCustomLogoFileNameKey);
    _newChatTextType = prefs.getString(_newChatTextTypeKey) ?? 'aiGreeting';
    _newChatCustomText = prefs.getString(_newChatCustomTextKey) ?? '';
    _newChatCachedAiGreeting = prefs.getString(_newChatCachedAiGreetingKey);
    // load OCR model
    final ocrSel = prefs.getString(_ocrModelKey);
    if (ocrSel != null && ocrSel.contains('::')) {
      final parts = ocrSel.split('::');
      if (parts.length >= 2) {
        _ocrModelProvider = parts[0];
        _ocrModelId = parts.sublist(1).join('::');
      }
    }
    // load OCR prompt
    final ocrp = prefs.getString(_ocrPromptKey);
    _ocrPrompt = (ocrp == null || ocrp.trim().isEmpty)
        ? defaultOcrPrompt
        : ocrp;
    // load OCR enabled (only effective when model is configured)
    _ocrEnabled = prefs.getBool(_ocrEnabledKey) ?? false;
    if (_ocrModelProvider == null || _ocrModelId == null) {
      _ocrEnabled = false;
    }
    // load summary model
    final summarySel = prefs.getString(_summaryModelKey);
    if (summarySel != null && summarySel.contains('::')) {
      final parts = summarySel.split('::');
      if (parts.length >= 2) {
        _summaryModelProvider = parts[0];
        _summaryModelId = parts.sublist(1).join('::');
      }
    }
    // load summary prompt
    final summaryp = prefs.getString(_summaryPromptKey);
    _summaryPrompt = (summaryp == null || summaryp.trim().isEmpty)
        ? defaultSummaryPrompt
        : summaryp;
    // load compress model
    final compressSel = prefs.getString(_compressModelKey);
    if (compressSel != null && compressSel.contains('::')) {
      final parts = compressSel.split('::');
      if (parts.length >= 2) {
        _compressModelProvider = parts[0];
        _compressModelId = parts.sublist(1).join('::');
      }
    }
    // load compress prompt
    final compressp = prefs.getString(_compressPromptKey);
    _compressPrompt = (compressp == null || compressp.trim().isEmpty)
        ? defaultCompressPrompt
        : compressp;
    // deep research
    _deepResearchEnabled = prefs.getBool(_deepResearchEnabledKey) ?? false;
    final lmp = prefs.getString(_deepResearchPromptKey);
    _deepResearchPrompt = (lmp == null || lmp.trim().isEmpty)
        ? defaultDeepResearchPrompt
        : lmp;
    // load thinking budget (reasoning strength)
    _thinkingBudget = prefs.getInt(_thinkingBudgetKey);
    _titleGenerationThinkingEnabled =
        prefs.getBool(_titleGenerationThinkingEnabledKey) ?? true;
    _greetingGenerationThinkingEnabled =
        prefs.getBool(_greetingGenerationThinkingEnabledKey) ?? true;

    // display settings
    _showUserAvatar = prefs.getBool(_displayShowUserAvatarKey) ?? true;
    _showModelIcon = prefs.getBool(_displayShowModelIconKey) ?? true;
    _showModelNameTimestamp =
        prefs.getBool(_displayShowModelNameTimestampKey) ?? true;
    _showTokenStats = prefs.getBool(_displayShowTokenStatsKey) ?? true;
    _showUserNameTimestamp =
        prefs.getBool(_displayShowUserNameTimestampKey) ?? true;
    _showUserMessageActions =
        prefs.getBool(_displayShowUserMessageActionsKey) ?? true;
    _showThinkingCards =
        prefs.getBool(_displayShowThinkingCardsKey) ?? true;
    _showToolCards = prefs.getBool(_displayShowToolCardsKey) ?? true;
    _autoCollapseThinking =
        prefs.getBool(_displayAutoCollapseThinkingKey) ?? true;
    _replayToolResults =
        prefs.getBool(_displayReplayToolResultsKey) ?? true;
    _showMessageNavButtons = prefs.getBool(_displayShowMessageNavKey) ?? true;
    _showProviderInModelCapsule =
        prefs.getBool(_displayShowProviderInModelCapsuleKey) ?? true;
    _hapticsOnGenerate = prefs.getBool(_displayHapticsOnGenerateKey) ?? false;
    _hapticsOnDrawer = prefs.getBool(_displayHapticsOnDrawerKey) ?? true;
    _hapticsGlobalEnabled =
        prefs.getBool(_displayHapticsGlobalEnabledKey) ?? true;
    _hapticsIosSwitch = prefs.getBool(_displayHapticsIosSwitchKey) ?? true;
    _hapticsOnListItemTap =
        prefs.getBool(_displayHapticsOnListItemTapKey) ?? true;
    _hapticsOnCardTap = prefs.getBool(_displayHapticsOnCardTapKey) ?? true;
    // Apply global haptics to service layer
    Haptics.setEnabled(_hapticsGlobalEnabled);
    _keepScreenOnDuringGeneration =
        prefs.getBool(_displayKeepScreenOnDuringGenerationKey) ?? false;
    ScreenWakelock.setEnabled(_keepScreenOnDuringGeneration);
    _longPasteAsFile = prefs.getBool(_displayLongPasteAsFileKey) ?? true;
    _longPasteAsFileThreshold =
        (prefs.getInt(_displayLongPasteAsFileThresholdKey) ??
                defaultLongPasteAsFileThreshold)
            .clamp(minLongPasteAsFileThreshold, maxLongPasteAsFileThreshold);
    _showAppUpdates = prefs.getBool(_displayShowAppUpdatesKey) ?? true;
    _keepSidebarOpenOnAssistantTap =
        prefs.getBool(_displayKeepSidebarOpenOnAssistantTapKey) ?? false;
    _keepSidebarOpenOnTopicTap =
        prefs.getBool(_displayKeepSidebarOpenOnTopicTapKey) ?? false;
    _keepAssistantListExpandedOnSidebarClose =
        prefs.getBool(_displayKeepAssistantListExpandedOnSidebarCloseKey) ??
        false;
    _requestLogEnabled = prefs.getBool(_requestLogEnabledKey) ?? false;
    await RequestLogger.setEnabled(_requestLogEnabled);
    _flutterLogEnabled = prefs.getBool(_flutterLogEnabledKey) ?? false;
    await FlutterLogger.setEnabled(_flutterLogEnabled);
    _newChatOnLaunch = prefs.getBool(_displayNewChatOnLaunchKey) ?? true;
    _newChatOnAssistantSwitch =
        prefs.getBool(_displayNewChatOnAssistantSwitchKey) ?? false;
    _newChatAfterDelete = prefs.getBool(_displayNewChatAfterDeleteKey) ?? false;
    _chatFontScale = prefs.getDouble(_displayChatFontScaleKey) ?? 1.0;
    _autoScrollEnabled = prefs.getBool(_displayAutoScrollEnabledKey) ?? true;
    _autoScrollIdleSeconds =
        prefs.getInt(_displayAutoScrollIdleSecondsKey) ?? 8;
    _chatBackgroundMaskStrength =
        prefs.getDouble(_displayChatBackgroundMaskStrengthKey) ?? 1.0;
    final pureBgPref = prefs.getBool(_displayUsePureBackgroundKey);
    if (pureBgPref == null) {
      final isDesktop =
          Platform.isMacOS || Platform.isWindows || Platform.isLinux;
      _usePureBackground = isDesktop;
      await prefs.setBool(_displayUsePureBackgroundKey, _usePureBackground);
    } else {
      _usePureBackground = pureBgPref;
    }
    // display: markdown/math rendering
    _enableDollarLatex = prefs.getBool(_displayEnableDollarLatexKey) ?? true;
    _enableMathRendering =
        prefs.getBool(_displayEnableMathRenderingKey) ?? true;
    _enableUserMarkdown = prefs.getBool(_displayEnableUserMarkdownKey) ?? true;
    _enableReasoningMarkdown =
        prefs.getBool(_displayEnableReasoningMarkdownKey) ?? true;
    _showChatListDate = prefs.getBool(_displayShowChatListDateKey) ?? false;
    _mobileCodeBlockWrap =
        prefs.getBool(_displayMobileCodeBlockWrapKey) ?? false;
    _autoCollapseCodeBlock =
        prefs.getBool(_displayAutoCollapseCodeBlockKey) ?? false;
    _autoCollapseCodeBlockLines =
        (prefs.getInt(_displayAutoCollapseCodeBlockLinesKey) ?? 2).clamp(
          1,
          999,
        );
    _desktopAutoSwitchTopics =
        prefs.getBool(_displayDesktopAutoSwitchTopicsKey) ?? false;
    // Desktop: tray settings (default enabled on desktop platforms)
    final trayPref = prefs.getBool(_displayDesktopShowTrayKey);
    if (trayPref == null) {
      final isDesktop =
          Platform.isMacOS || Platform.isWindows || Platform.isLinux;
      _desktopShowTray = isDesktop;
      await prefs.setBool(_displayDesktopShowTrayKey, _desktopShowTray);
    } else {
      _desktopShowTray = trayPref;
    }
    final minimizeTrayPref = prefs.getBool(
      _displayDesktopMinimizeToTrayOnCloseKey,
    );
    if (minimizeTrayPref == null) {
      _desktopMinimizeToTrayOnClose = _desktopShowTray;
      await prefs.setBool(
        _displayDesktopMinimizeToTrayOnCloseKey,
        _desktopMinimizeToTrayOnClose,
      );
    } else {
      // Enforce invariant: cannot minimize to tray if tray is hidden.
      _desktopMinimizeToTrayOnClose = minimizeTrayPref && _desktopShowTray;
      if (minimizeTrayPref && !_desktopShowTray) {
        await prefs.setBool(
          _displayDesktopMinimizeToTrayOnCloseKey,
          _desktopMinimizeToTrayOnClose,
        );
      }
    }
    // desktop: topic panel placement + right sidebar open state
    final topicPos = prefs.getString(_desktopTopicPositionKey);
    switch (topicPos) {
      case 'right':
        _desktopTopicPosition = DesktopTopicPosition.right;
        break;
      case 'left':
      default:
        _desktopTopicPosition = DesktopTopicPosition.left;
    }
    _desktopRightSidebarOpen =
        prefs.getBool(_desktopRightSidebarOpenKey) ?? true;
    // Chat message background style (default | frosted | solid)
    final bgStyleStr =
        prefs.getString(_displayChatMessageBackgroundStyleKey) ?? 'default';
    switch (bgStyleStr) {
      case 'frosted':
        _chatMessageBackgroundStyle = ChatMessageBackgroundStyle.frosted;
        break;
      case 'solid':
        _chatMessageBackgroundStyle = ChatMessageBackgroundStyle.solid;
        break;
      default:
        _chatMessageBackgroundStyle = ChatMessageBackgroundStyle.defaultStyle;
    }
    // desktop UI
    _desktopSidebarWidth = prefs.getDouble(_desktopSidebarWidthKey) ?? 300;
    _desktopSidebarOpen = prefs.getBool(_desktopSidebarOpenKey) ?? true;
    _desktopRightSidebarWidth =
        prefs.getDouble(_desktopRightSidebarWidthKey) ?? 300;
    // Load app locale; default to follow system on first launch
    _appLocaleTag = prefs.getString(_appLocaleKey);
    if (_appLocaleTag == null || _appLocaleTag!.isEmpty) {
      _appLocaleTag = 'system';
      await prefs.setString(_appLocaleKey, 'system');
    }

    // Android background chat mode (Android only; default ON on first run)
    try {
      final rawBg = prefs.getString(_androidBackgroundChatModeKey);
      if (rawBg == null) {
        // Default to OFF to avoid permission prompts on first launch
        _androidBackgroundChatMode = AndroidBackgroundChatMode.off;
        await prefs.setString(_androidBackgroundChatModeKey, 'off');
      } else {
        switch (rawBg) {
          case 'on_notify':
            _androidBackgroundChatMode = AndroidBackgroundChatMode.onNotify;
            break;
          case 'on':
            _androidBackgroundChatMode = AndroidBackgroundChatMode.on;
            break;
          case 'off':
          default:
            _androidBackgroundChatMode = AndroidBackgroundChatMode.off;
        }
      }
    } catch (_) {
      _androidBackgroundChatMode = AndroidBackgroundChatMode.off;
    }

    // load search settings
    final searchServicesStr = prefs.getString(_searchServicesKey);
    if (searchServicesStr != null && searchServicesStr.isNotEmpty) {
      try {
        final list = jsonDecode(searchServicesStr) as List;
        _searchServices = list
            .map(
              (e) => SearchServiceOptions.fromJson(e as Map<String, dynamic>),
            )
            .toList();
      } catch (_) {}
    }
    final searchCommonStr = prefs.getString(_searchCommonKey);
    if (searchCommonStr != null && searchCommonStr.isNotEmpty) {
      try {
        _searchCommonOptions = SearchCommonOptions.fromJson(
          jsonDecode(searchCommonStr) as Map<String, dynamic>,
        );
      } catch (_) {}
    }
    _searchServiceSelected = prefs.getInt(_searchSelectedKey) ?? 0;
    _searchEnabled = prefs.getBool(_searchEnabledKey) ?? false;
    _searchAutoTestOnLaunch =
        prefs.getBool(_searchAutoTestOnLaunchKey) ?? false;

    // Load standalone academic MCP config, then migrate any legacy PubMed /
    // Semantic Scholar / arXiv entries out of the search services list into
    // the academic config (keys / tool / email are preserved).
    final academicStr = prefs.getString(_academicConfigKey);
    if (academicStr != null && academicStr.isNotEmpty) {
      try {
        _academicConfig = AcademicMcpConfig.fromJson(
          jsonDecode(academicStr) as Map<String, dynamic>,
        );
      } catch (_) {}
    }
    bool academicMigrated = false;
    final migratedServices = <SearchServiceOptions>[];
    for (final s in _searchServices) {
      if (s is PubMedOptions) {
        if (_academicConfig.pubmedApiKey.isEmpty && s.apiKey.isNotEmpty) {
          _academicConfig = _academicConfig.copyWith(pubmedApiKey: s.apiKey);
        }
        if (_academicConfig.pubmedTool.isEmpty && s.tool.isNotEmpty) {
          _academicConfig = _academicConfig.copyWith(pubmedTool: s.tool);
        }
        if (_academicConfig.pubmedEmail.isEmpty && s.email.isNotEmpty) {
          _academicConfig = _academicConfig.copyWith(pubmedEmail: s.email);
        }
        academicMigrated = true; // drop from web search list
        continue;
      }
      if (s is SemanticScholarOptions) {
        if (_academicConfig.semanticScholarApiKey.isEmpty &&
            s.apiKey.isNotEmpty) {
          _academicConfig = _academicConfig.copyWith(
            semanticScholarApiKey: s.apiKey,
          );
        }
        academicMigrated = true; // drop from web search list
        continue;
      }
      if (s is ArxivOptions) {
        academicMigrated = true; // arXiv has no key; drop from web search list
        continue;
      }
      migratedServices.add(s);
    }
    if (academicMigrated) {
      _searchServices = migratedServices.isEmpty
          ? [SearchServiceOptions.defaultOption]
          : migratedServices;
      if (_searchServiceSelected >= _searchServices.length) {
        _searchServiceSelected = _searchServices.isEmpty
            ? 0
            : _searchServices.length - 1;
      }
      await prefs.setString(
        _searchServicesKey,
        jsonEncode(_searchServices.map((e) => e.toJson()).toList()),
      );
      await prefs.setInt(_searchSelectedKey, _searchServiceSelected);
      await prefs.setString(_academicConfigKey, jsonEncode(_academicConfig.toJson()));
    }

    // load global proxy
    _globalProxyEnabled = prefs.getBool(_globalProxyEnabledKey) ?? false;
    _globalProxyType = prefs.getString(_globalProxyTypeKey) ?? 'http';
    _globalProxyHost = prefs.getString(_globalProxyHostKey) ?? '';
    _globalProxyPort = prefs.getString(_globalProxyPortKey) ?? '8080';
    _globalProxyUsername = prefs.getString(_globalProxyUsernameKey) ?? '';
    _globalProxyPassword = prefs.getString(_globalProxyPasswordKey) ?? '';

    // load network TTS services
    try {
      final ttsStr = prefs.getString(_ttsServicesKey) ?? '';
      if (ttsStr.isNotEmpty) {
        final list = jsonDecode(ttsStr) as List;
        _ttsServices = [
          for (final e in list)
            if (e is Map<String, dynamic>)
              TtsServiceOptions.fromJson(e)
            else
              TtsServiceOptions.fromJson(Map<String, dynamic>.from(e as Map)),
        ];
      } else {
        _ttsServices = const <TtsServiceOptions>[];
      }
    } catch (_) {
      _ttsServices = const <TtsServiceOptions>[];
    }
    _ttsServiceSelected = prefs.getInt(_ttsSelectedKey) ?? -1;
    if (_ttsServiceSelected >= _ttsServices.length) {
      _ttsServiceSelected = _ttsServices.isEmpty ? -1 : 0;
      await prefs.setInt(_ttsSelectedKey, _ttsServiceSelected);
    }
    _ttsAutoPlayAssistantReplies = prefs.getBool(_ttsAutoPlayRepliesKey) ?? false;
    _ttsTextSelectionMode = TtsTextSelectionModeStorage.fromStorageValue(
      prefs.getString(_ttsTextSelectionModeKey),
    );

    // load network STT services
    try {
      final sttStr = prefs.getString(_sttServicesKey) ?? '';
      if (sttStr.isNotEmpty) {
        final list = jsonDecode(sttStr) as List;
        _sttServices = [
          for (final e in list)
            if (e is Map<String, dynamic>)
              SttServiceOptions.fromJson(e)
            else
              SttServiceOptions.fromJson(Map<String, dynamic>.from(e as Map)),
        ];
      } else {
        _sttServices = const <SttServiceOptions>[];
      }
    } catch (_) {
      _sttServices = const <SttServiceOptions>[];
    }
    _sttServiceSelected = prefs.getInt(_sttSelectedKey) ?? -1;
    if (_sttServiceSelected >= _sttServices.length) {
      _sttServiceSelected = _sttServices.isEmpty ? -1 : 0;
      await prefs.setInt(_sttSelectedKey, _sttServiceSelected);
    }
    _sttSystemLocaleId = prefs.getString(_sttSystemLocaleKey);
    // load voice call (Live API) settings
    final vcMode = prefs.getString(_voiceCallModeKey);
    _voiceCallMode = switch (vcMode) {
      'liveApi' => VoiceCallMode.liveApi,
      _ => VoiceCallMode.standard,
    };
    _liveApiBaseUrl = prefs.getString(_liveApiBaseUrlKey) ?? '';
    _liveApiApiKey = (await _liveApiKeyStore.read()) ?? '';
    _liveApiModel = (prefs.getString(_liveApiModelKey) ?? '').trim();
    if (_liveApiModel.isEmpty) _liveApiModel = VoiceCallDefaults.defaultModel;
    _liveApiVoice = (prefs.getString(_liveApiVoiceKey) ?? '').trim();
    if (_liveApiVoice.isEmpty) _liveApiVoice = VoiceCallDefaults.defaultVoice;
    // webdav config
    final webdavStr = prefs.getString(_webDavConfigKey);
    if (webdavStr != null && webdavStr.isNotEmpty) {
      try {
        _webDavConfig = WebDavConfig.fromJson(
          jsonDecode(webdavStr) as Map<String, dynamic>,
        );
      } catch (_) {}
    }
    final dropboxStr = prefs.getString(_dropboxConfigKey);
    if (dropboxStr != null && dropboxStr.isNotEmpty) {
      try {
        _dropboxConfig = DropboxConfig.fromJson(
          jsonDecode(dropboxStr) as Map<String, dynamic>,
        );
      } catch (_) {}
    }
    if (_providerConfigs.isEmpty) {
      // Seed a couple of sensible defaults on first launch, but do not recreate
      // providers implicitly during later reads (e.g., when switching chats).
      ensureProviderConfig('Tensdaq', defaultName: 'Tensdaq');
      ensureProviderConfig('SiliconFlow', defaultName: 'SiliconFlow');
      ensureProviderConfig('AIhubmix', defaultName: 'AIhubmix');
    }

    // kick off a one-time connectivity test for services (exclude local Bing)
    if (_searchAutoTestOnLaunch) {
      _initSearchConnectivityTests();
    }

    // Attempt to reload any user-installed local fonts (mobile platforms)
    await _reloadLocalFontsIfAny();

    // Migrate balance settings for existing providers if they are missing
    await _migrateBalanceSettings();

    notifyListeners();
  }

  Future<void> _migrateBalanceSettings() async {
    bool changed = false;
    final Map<String, ProviderConfig> migrated = Map.from(_providerConfigs);

    migrated.forEach((key, cfg) {
      final lowerKey = key.toLowerCase();
      final isSupported =
          lowerKey.contains('silicon') ||
          lowerKey.contains('aihubmix') ||
          lowerKey.contains('deepseek') ||
          lowerKey.contains('openrouter') ||
          lowerKey.contains('moonshot');

      if (isSupported) {
        final def = ProviderConfig.defaultsFor(key, displayName: cfg.name);
        bool needsUpdate = false;

        if (cfg.balanceEnabled == null) {
          needsUpdate = true;
        } else if (cfg.balanceEnabled == true) {
          // Fix empty paths or known outdated paths (e.g. OpenRouter using default /user/info)
          if ((cfg.balanceApiPath ?? '').isEmpty ||
              (cfg.balanceResultKey ?? '').isEmpty ||
              (lowerKey.contains('openrouter') &&
                  (cfg.balanceApiPath == '/user/info' ||
                      cfg.balanceApiPath == '/user/balance' ||
                      cfg.balanceResultKey == 'data.total_credits'))) {
            needsUpdate = true;
          }
        }

        if (needsUpdate) {
          migrated[key] = cfg.copyWith(
            balanceEnabled: true,
            balanceApiPath: def.balanceApiPath,
            balanceResultKey: def.balanceResultKey,
          );
          changed = true;
        }
      } else {
        if (cfg.balanceEnabled == null) {
          migrated[key] = cfg.copyWith(balanceEnabled: false);
          changed = true;
        }
      }
    });

    if (changed) {
      _providerConfigs = migrated;
      final prefs = await SharedPreferences.getInstance();
      final map = _providerConfigs.map((k, v) => MapEntry(k, v.toJson()));
      await prefs.setString(_providerConfigsKey, jsonEncode(map));
    }
  }

  Future<void> setGlobalProxyEnabled(bool v) async {
    _globalProxyEnabled = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_globalProxyEnabledKey, _globalProxyEnabled);
  }

  Future<void> setGlobalProxyType(String v) async {
    _globalProxyType = v.trim().isEmpty ? 'http' : v.trim();
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_globalProxyTypeKey, _globalProxyType);
  }

  Future<void> setGlobalProxyHost(String v) async {
    _globalProxyHost = v.trim();
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_globalProxyHostKey, _globalProxyHost);
  }

  Future<void> setGlobalProxyPort(String v) async {
    _globalProxyPort = v.trim();
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_globalProxyPortKey, _globalProxyPort);
  }

  Future<void> setGlobalProxyUsername(String v) async {
    _globalProxyUsername = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_globalProxyUsernameKey, _globalProxyUsername);
  }

  Future<void> setGlobalProxyPassword(String v) async {
    _globalProxyPassword = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_globalProxyPasswordKey, _globalProxyPassword);
  }

  // Apply global proxy to Dart IO layer; provider-level proxies take precedence at call sites.
  String _lastProxySignature = '';
  void applyGlobalProxyOverridesIfNeeded() {
    try {
      final enabled = _globalProxyEnabled;
      final host = _globalProxyHost.trim();
      final portStr = _globalProxyPort.trim();
      final user = _globalProxyUsername.trim();
      final pass = _globalProxyPassword;
      final type = _globalProxyType;
      final sig = [enabled, type, host, portStr, user, pass].join('|');
      if (_lastProxySignature == sig) return;
      _lastProxySignature = sig;
      if (!enabled || host.isEmpty || portStr.isEmpty) {
        HttpOverrides.global = null;
        return;
      }
      final port = int.tryParse(portStr) ?? 8080;
      if (type == 'socks5') {
        HttpOverrides.global = _SocksProxyHttpOverrides(
          host: host,
          port: port,
          username: user.isEmpty ? null : user,
          password: pass,
        );
      } else {
        HttpOverrides.global = _ProxyHttpOverrides(
          host: host,
          port: port,
          username: user.isEmpty ? null : user,
          password: pass,
        );
      }
    } catch (_) {
      // ignore
    }
  }

  Future<void> setTtsServices(List<TtsServiceOptions> v) async {
    _ttsServices = List.unmodifiable(v);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    final list = v.map((e) => e.toJson()).toList();
    await prefs.setString(_ttsServicesKey, jsonEncode(list));
    if (_ttsServiceSelected >= _ttsServices.length) {
      _ttsServiceSelected = _ttsServices.isEmpty ? -1 : 0;
      await prefs.setInt(_ttsSelectedKey, _ttsServiceSelected);
    }
  }

  Future<void> setTtsServiceSelected(int index) async {
    _ttsServiceSelected = index;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_ttsSelectedKey, _ttsServiceSelected);
  }

  Future<void> setTtsAutoPlayAssistantReplies(bool value) async {
    if (_ttsAutoPlayAssistantReplies == value) return;
    _ttsAutoPlayAssistantReplies = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_ttsAutoPlayRepliesKey, value);
  }

  Future<void> setSttServices(List<SttServiceOptions> v) async {
    _sttServices = List.unmodifiable(v);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    final list = v.map((e) => e.toJson()).toList();
    await prefs.setString(_sttServicesKey, jsonEncode(list));
    if (_sttServiceSelected >= _sttServices.length) {
      _sttServiceSelected = _sttServices.isEmpty ? -1 : 0;
      await prefs.setInt(_sttSelectedKey, _sttServiceSelected);
    }
  }

  Future<void> setSttServiceSelected(int index) async {
    _sttServiceSelected = index;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_sttSelectedKey, _sttServiceSelected);
  }

  Future<void> setSttSystemLocaleId(String? localeId) async {
    final next = (localeId == null || localeId.trim().isEmpty) ? null : localeId.trim();
    if (_sttSystemLocaleId == next) return;
    _sttSystemLocaleId = next;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (_sttSystemLocaleId == null) {
      await prefs.remove(_sttSystemLocaleKey);
    } else {
      await prefs.setString(_sttSystemLocaleKey, _sttSystemLocaleId!);
    }
  }

  // ===== Voice Call (Live API) setters =====

  Future<void> setVoiceCallMode(VoiceCallMode mode) async {
    if (_voiceCallMode == mode) return;
    _voiceCallMode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_voiceCallModeKey, mode.name);
  }

  Future<void> setLiveApiBaseUrl(String value) async {
    final next = value.trim();
    if (_liveApiBaseUrl == next) return;
    _liveApiBaseUrl = next;
    // Base URL 變更時清除模型快取，避免顯示舊 host 的清單。
    LiveApiModelsService.invalidateCache();
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (next.isEmpty) {
      await prefs.remove(_liveApiBaseUrlKey);
    } else {
      await prefs.setString(_liveApiBaseUrlKey, next);
    }
  }

  Future<void> setLiveApiApiKey(String value) async {
    final next = value.trim();
    if (_liveApiApiKey == next) return;
    _liveApiApiKey = next;
    LiveApiModelsService.invalidateCache();
    notifyListeners();
    // §5.8：Key 寫入 secure storage（並清除舊 SharedPreferences 位置）。
    if (next.isEmpty) {
      await _liveApiKeyStore.delete();
    } else {
      await _liveApiKeyStore.write(next);
    }
  }

  Future<void> setLiveApiModel(String value) async {
    final next = value.trim();
    if (_liveApiModel == next) return;
    _liveApiModel = next;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (next.isEmpty) {
      await prefs.remove(_liveApiModelKey);
    } else {
      await prefs.setString(_liveApiModelKey, next);
    }
  }

  Future<void> setLiveApiVoice(String value) async {
    final next = value.trim();
    if (_liveApiVoice == next) return;
    _liveApiVoice = next;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (next.isEmpty) {
      await prefs.remove(_liveApiVoiceKey);
    } else {
      await prefs.setString(_liveApiVoiceKey, next);
    }
  }

  Future<void> setTtsTextSelectionMode(TtsTextSelectionMode mode) async {
    if (_ttsTextSelectionMode == mode) return;
    _ttsTextSelectionMode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_ttsTextSelectionModeKey, mode.storageValue);
  }

  // ===== User Font Settings =====
  String? _appFontFamily; // system or Google font family to use globally
  String?
  _codeFontFamily; // system or Google font family to use for code blocks
  // Whether the above family names refer to Google Fonts (as opposed to system fonts)
  bool _appFontIsGoogle = false;
  bool _codeFontIsGoogle = false;
  // Local font file selections (mobile): persisted for reload
  String? _appFontLocalPath;
  String? _codeFontLocalPath;
  // The alias family name registered via FontLoader for local fonts
  String? _appFontLocalAlias;
  String? _codeFontLocalAlias;

  String? get appFontFamily => _effectiveAppFontAlias ?? _appFontFamily;
  String? get codeFontFamily => _effectiveCodeFontAlias ?? _codeFontFamily;
  bool get appFontIsGoogle => _appFontIsGoogle;
  bool get codeFontIsGoogle => _codeFontIsGoogle;
  String? get appFontLocalAlias => _appFontLocalAlias;
  String? get codeFontLocalAlias => _codeFontLocalAlias;

  // Use alias if a local font is set and successfully registered
  String? get _effectiveAppFontAlias =>
      (_appFontLocalAlias?.isNotEmpty == true) ? _appFontLocalAlias : null;
  String? get _effectiveCodeFontAlias =>
      (_codeFontLocalAlias?.isNotEmpty == true) ? _codeFontLocalAlias : null;

  Future<void> setAppFontSystemFamily(String? family) async {
    _appFontIsGoogle = false;
    _appFontFamily = (family == null || family.trim().isEmpty)
        ? null
        : family.trim();
    // Clear local alias for system/google switch
    _appFontLocalAlias = null;
    _appFontLocalPath = null;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_displayAppFontFamilyKey, _appFontFamily ?? '');
    await prefs.setBool(_displayAppFontIsGoogleKey, _appFontIsGoogle);
    await prefs.remove(_displayAppFontLocalAliasKey);
    await prefs.remove(_displayAppFontLocalPathKey);
  }

  Future<void> setCodeFontSystemFamily(String? family) async {
    _codeFontIsGoogle = false;
    _codeFontFamily = (family == null || family.trim().isEmpty)
        ? null
        : family.trim();
    _codeFontLocalAlias = null;
    _codeFontLocalPath = null;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_displayCodeFontFamilyKey, _codeFontFamily ?? '');
    await prefs.setBool(_displayCodeFontIsGoogleKey, _codeFontIsGoogle);
    await prefs.remove(_displayCodeFontLocalAliasKey);
    await prefs.remove(_displayCodeFontLocalPathKey);
  }

  Future<void> setAppFontFromGoogle(String family) async {
    _appFontIsGoogle = true;
    _appFontFamily = family.trim();
    _appFontLocalAlias = null;
    _appFontLocalPath = null;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_displayAppFontFamilyKey, _appFontFamily!);
    await prefs.setBool(_displayAppFontIsGoogleKey, true);
    await prefs.remove(_displayAppFontLocalAliasKey);
    await prefs.remove(_displayAppFontLocalPathKey);
  }

  Future<void> setCodeFontFromGoogle(String family) async {
    _codeFontIsGoogle = true;
    _codeFontFamily = family.trim();
    _codeFontLocalAlias = null;
    _codeFontLocalPath = null;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_displayCodeFontFamilyKey, _codeFontFamily!);
    await prefs.setBool(_displayCodeFontIsGoogleKey, true);
    await prefs.remove(_displayCodeFontLocalAliasKey);
    await prefs.remove(_displayCodeFontLocalPathKey);
  }

  Future<void> setAppFontFromLocal({
    required String path,
    String? alias,
  }) async {
    final fam = await _registerLocalFont(
      path: path,
      aliasPrefix: alias ?? 'kelivo_local_app',
    );
    if (fam == null) return;
    _appFontIsGoogle = false;
    _appFontFamily = fam;
    _appFontLocalAlias = fam;
    _appFontLocalPath = path;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_displayAppFontFamilyKey, _appFontFamily!);
    await prefs.setBool(_displayAppFontIsGoogleKey, false);
    await prefs.setString(_displayAppFontLocalAliasKey, _appFontLocalAlias!);
    await prefs.setString(_displayAppFontLocalPathKey, _appFontLocalPath!);
  }

  Future<void> setCodeFontFromLocal({
    required String path,
    String? alias,
  }) async {
    final fam = await _registerLocalFont(
      path: path,
      aliasPrefix: alias ?? 'kelivo_local_code',
    );
    if (fam == null) return;
    _codeFontIsGoogle = false;
    _codeFontFamily = fam;
    _codeFontLocalAlias = fam;
    _codeFontLocalPath = path;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_displayCodeFontFamilyKey, _codeFontFamily!);
    await prefs.setBool(_displayCodeFontIsGoogleKey, false);
    await prefs.setString(_displayCodeFontLocalAliasKey, _codeFontLocalAlias!);
    await prefs.setString(_displayCodeFontLocalPathKey, _codeFontLocalPath!);
  }

  Future<void> clearAppFont() async {
    _appFontFamily = null;
    _appFontIsGoogle = false;
    _appFontLocalAlias = null;
    _appFontLocalPath = null;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_displayAppFontFamilyKey);
    await prefs.remove(_displayAppFontIsGoogleKey);
    await prefs.remove(_displayAppFontLocalAliasKey);
    await prefs.remove(_displayAppFontLocalPathKey);
  }

  Future<void> clearCodeFont() async {
    _codeFontFamily = null;
    _codeFontIsGoogle = false;
    _codeFontLocalAlias = null;
    _codeFontLocalPath = null;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_displayCodeFontFamilyKey);
    await prefs.remove(_displayCodeFontIsGoogleKey);
    await prefs.remove(_displayCodeFontLocalAliasKey);
    await prefs.remove(_displayCodeFontLocalPathKey);
  }

  Future<void> _reloadLocalFontsIfAny() async {
    final prefs = await SharedPreferences.getInstance();
    // Load persisted values
    _appFontFamily = _nonEmpty(prefs.getString(_displayAppFontFamilyKey));
    _codeFontFamily = _nonEmpty(prefs.getString(_displayCodeFontFamilyKey));
    _appFontIsGoogle = prefs.getBool(_displayAppFontIsGoogleKey) ?? false;
    _codeFontIsGoogle = prefs.getBool(_displayCodeFontIsGoogleKey) ?? false;
    _appFontLocalPath = _nonEmpty(prefs.getString(_displayAppFontLocalPathKey));
    _codeFontLocalPath = _nonEmpty(
      prefs.getString(_displayCodeFontLocalPathKey),
    );
    _appFontLocalAlias = _nonEmpty(
      prefs.getString(_displayAppFontLocalAliasKey),
    );
    _codeFontLocalAlias = _nonEmpty(
      prefs.getString(_displayCodeFontLocalAliasKey),
    );

    // Re-register local fonts if paths are available (best effort)
    if (_appFontLocalPath != null && _appFontLocalPath!.isNotEmpty) {
      final alias = _appFontLocalAlias ?? 'kelivo_local_app';
      final fam = await _registerLocalFont(
        path: _appFontLocalPath!,
        aliasPrefix: alias,
      );
      if (fam != null) {
        _appFontLocalAlias = fam;
        _appFontFamily = fam;
      }
    }
    if (_codeFontLocalPath != null && _codeFontLocalPath!.isNotEmpty) {
      final alias = _codeFontLocalAlias ?? 'kelivo_local_code';
      final fam = await _registerLocalFont(
        path: _codeFontLocalPath!,
        aliasPrefix: alias,
      );
      if (fam != null) {
        _codeFontLocalAlias = fam;
        _codeFontFamily = fam;
      }
    }
  }

  String? _nonEmpty(String? s) => (s == null || s.isEmpty) ? null : s;

  Future<String?> _registerLocalFont({
    required String path,
    required String aliasPrefix,
  }) async {
    try {
      // Use a stable alias derived from file name to reduce duplicates
      final ts = DateTime.now().millisecondsSinceEpoch;
      final alias = '${aliasPrefix}_$ts';
      final file = File(path);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      final bd = bytes.buffer.asByteData();
      final loader = FontLoader(alias);
      loader.addFont(Future.value(bd));
      await loader.load();
      return alias;
    } catch (_) {
      return null;
    }
  }

  // ===== Desktop UI setters =====
  Future<void> setDesktopSidebarWidth(double width) async {
    final w = width.clamp(200.0, 640.0).toDouble();
    if ((w - _desktopSidebarWidth).abs() < 0.5) return;
    _desktopSidebarWidth = w;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_desktopSidebarWidthKey, _desktopSidebarWidth);
  }

  Future<void> setDesktopSidebarOpen(bool open) async {
    if (_desktopSidebarOpen == open) return;
    _desktopSidebarOpen = open;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_desktopSidebarOpenKey, _desktopSidebarOpen);
  }

  Future<void> setDesktopRightSidebarWidth(double w) async {
    if ((_desktopRightSidebarWidth - w).abs() < 0.5) return;
    _desktopRightSidebarWidth = w;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(
      _desktopRightSidebarWidthKey,
      _desktopRightSidebarWidth,
    );
  }

  // Desktop: topic panel placement (left/right)
  Future<void> setDesktopTopicPosition(DesktopTopicPosition pos) async {
    if (_desktopTopicPosition == pos) return;
    _desktopTopicPosition = pos;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    final v = (pos == DesktopTopicPosition.right) ? 'right' : 'left';
    await prefs.setString(_desktopTopicPositionKey, v);
  }

  // Desktop: right sidebar visible state
  Future<void> setDesktopRightSidebarOpen(bool open) async {
    if (_desktopRightSidebarOpen == open) return;
    _desktopRightSidebarOpen = open;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_desktopRightSidebarOpenKey, _desktopRightSidebarOpen);
  }

  // ===== App locale (UI language) =====
  String? _appLocaleTag; // 'system', 'zh_CN', 'zh_Hant', 'en_US'
  Locale get appLocale => _parseLocaleTag(_appLocaleTag ?? 'en_US');
  bool get isFollowingSystemLocale =>
      (_appLocaleTag == null) || (_appLocaleTag == 'system');
  Locale? get appLocaleForMaterialApp =>
      isFollowingSystemLocale ? null : appLocale;
  Future<void> setAppLocale(Locale locale) async {
    final tag = _localeToTag(locale);
    if (_appLocaleTag == tag) return;
    _appLocaleTag = tag;
    _newChatCachedAiGreeting = null;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_appLocaleKey, _appLocaleTag!);
  }

  Future<void> setAppLocaleFollowSystem() async {
    if (_appLocaleTag == 'system') return;
    _appLocaleTag = 'system';
    _newChatCachedAiGreeting = null;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_appLocaleKey, 'system');
  }

  // Supported locales mapping
  String _mapDeviceLocaleToSupportedTag(Locale device) {
    final lc = (device.languageCode).toLowerCase();
    final region = (device.countryCode ?? '').toUpperCase();
    final script = (device.scriptCode ?? '').toLowerCase();
    if (lc == 'zh') {
      // Map Traditional Chinese by script or common regions
      if (script == 'hant' ||
          region == 'TW' ||
          region == 'HK' ||
          region == 'MO') {
        return 'zh_Hant';
      }
      return 'zh_CN';
    }
    return 'en_US';
  }

  String _localeToTag(Locale l) {
    final lc = l.languageCode.toLowerCase();
    if (lc == 'zh') {
      final script = (l.scriptCode ?? '').toLowerCase();
      if (script == 'hant') return 'zh_Hant';
      return 'zh_CN';
    }
    return 'en_US';
  }

  Locale _parseLocaleTag(String tag) {
    switch (tag) {
      case 'zh_CN':
        return const Locale('zh', 'CN');
      case 'zh_Hant':
        return const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant');
      case 'en_US':
      default:
        return const Locale('en', 'US');
    }
  }

  // ===== Backup & WebDAV settings =====
  WebDavConfig _webDavConfig = const WebDavConfig();
  WebDavConfig get webDavConfig => _webDavConfig;
  Future<void> setWebDavConfig(WebDavConfig cfg) async {
    _webDavConfig = cfg;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_webDavConfigKey, jsonEncode(cfg.toJson()));
  }

  DropboxConfig _dropboxConfig = const DropboxConfig();
  DropboxConfig get dropboxConfig => _dropboxConfig;
  Future<void> setDropboxConfig(DropboxConfig cfg) async {
    _dropboxConfig = cfg;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_dropboxConfigKey, jsonEncode(cfg.toJson()));
  }

  Future<void> _initSearchConnectivityTests() async {
    final services = List<SearchServiceOptions>.from(_searchServices);
    final common = _searchCommonOptions;
    for (final s in services) {
      if (s is BingLocalOptions) {
        _searchConnection[s.id] = null; // no label for local Bing
        continue;
      }
      // Run in background; don't await all
      unawaited(_testSingleSearchService(s, common));
    }
  }

  Future<void> _testSingleSearchService(
    SearchServiceOptions s,
    SearchCommonOptions common,
  ) async {
    try {
      final svc = SearchService.getService(s);
      await svc.search(
        query: 'connectivity test',
        commonOptions: common,
        serviceOptions: s,
      );
      _searchConnection[s.id] = true;
    } catch (_) {
      _searchConnection[s.id] = false;
    }
    notifyListeners();
  }

  void setSearchConnection(String id, bool? value) {
    _searchConnection[id] = value;
    notifyListeners();
  }

  Future<void> setProvidersOrder(List<String> order) async {
    _providersOrder = List.unmodifiable(order);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_providersOrderKey, _providersOrder);
  }

  Future<void> setChatInputButtonOrder(List<String> order) async {
    _chatInputButtonOrder = List.unmodifiable(order);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_chatInputButtonOrderKey, _chatInputButtonOrder);
  }

  Future<void> setChatInputButtonHidden(List<String> hidden) async {
    _chatInputButtonHidden = List.unmodifiable(hidden);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _chatInputButtonHiddenKey,
      _chatInputButtonHidden,
    );
  }

  Future<void> setImageAspectRatio(String ratio) async {
    _imageAspectRatio = ratio;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_imageAspectRatioKey, _imageAspectRatio);
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    final v = mode == ThemeMode.light
        ? 'light'
        : mode == ThemeMode.dark
        ? 'dark'
        : 'system';
    await prefs.setString(_themeModeKey, v);
  }

  Future<void> setThemePalette(String id) async {
    if (_themePaletteId == id) return;
    _themePaletteId = id;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themePaletteKey, id);
  }

  Future<void> setUseDynamicColor(bool v) async {
    if (_useDynamicColor == v) return;
    _useDynamicColor = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_useDynamicColorKey, v);
  }

  Future<void> setUsePureBackground(bool v) async {
    if (_usePureBackground == v) return;
    _usePureBackground = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_displayUsePureBackgroundKey, v);
  }

  // Display: chat message background style (affects user/assistant bubbles)
  ChatMessageBackgroundStyle _chatMessageBackgroundStyle =
      ChatMessageBackgroundStyle.defaultStyle;
  ChatMessageBackgroundStyle get chatMessageBackgroundStyle =>
      _chatMessageBackgroundStyle;
  Future<void> setChatMessageBackgroundStyle(
    ChatMessageBackgroundStyle style,
  ) async {
    if (_chatMessageBackgroundStyle == style) return;
    _chatMessageBackgroundStyle = style;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    final v = switch (style) {
      ChatMessageBackgroundStyle.frosted => 'frosted',
      ChatMessageBackgroundStyle.solid => 'solid',
      ChatMessageBackgroundStyle.defaultStyle => 'default',
    };
    await prefs.setString(_displayChatMessageBackgroundStyleKey, v);
  }

  // ===== Android background chat generation =====
  AndroidBackgroundChatMode _androidBackgroundChatMode =
      AndroidBackgroundChatMode.off;
  AndroidBackgroundChatMode get androidBackgroundChatMode =>
      _androidBackgroundChatMode;
  Future<void> setAndroidBackgroundChatMode(
    AndroidBackgroundChatMode mode,
  ) async {
    if (_androidBackgroundChatMode == mode) return;
    _androidBackgroundChatMode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    final v = switch (mode) {
      AndroidBackgroundChatMode.onNotify => 'on_notify',
      AndroidBackgroundChatMode.on => 'on',
      AndroidBackgroundChatMode.off => 'off',
    };
    await prefs.setString(_androidBackgroundChatModeKey, v);
    // Best-effort: update Android background execution state immediately
    try {
      if (Platform.isAndroid) {
        // Direct call; file is present in project and guards by Platform
        // ignore: depend_on_referenced_packages
        // ignore_for_file: unnecessary_import
        // ignore: avoid_print
        // Defer import here is not possible; rely on main.dart sync. This is a no-op placeholder.
      }
    } catch (_) {}
  }

  void setDynamicColorSupported(bool v) {
    if (_dynamicColorSupported == v) return;
    _dynamicColorSupported = v;
    notifyListeners();
  }

  Future<void> toggleTheme() => setThemeMode(
    _themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark,
  );

  Future<void> followSystem() => setThemeMode(ThemeMode.system);

  Future<void> setProviderConfig(String key, ProviderConfig config) async {
    // Normalize duplicates so the models tab / batch detection never sees
    // repeated IDs (duplicate widget keys would break rendering).
    _providerConfigs[key] = config.copyWith(models: config.models);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    final map = _providerConfigs.map((k, v) => MapEntry(k, v.toJson()));
    await prefs.setString(_providerConfigsKey, jsonEncode(map));
  }

  // ===== Provider Avatars =====
  Future<void> setProviderAvatarEmoji(String key, String emoji) async {
    final e = emoji.trim();
    if (e.isEmpty) return;
    final old = getProviderConfig(key);
    await setProviderConfig(
      key,
      old.copyWith(avatarType: 'emoji', avatarValue: e),
    );
  }

  Future<void> setProviderAvatarUrl(String key, String url) async {
    final u = url.trim();
    if (u.isEmpty) return;
    final old = getProviderConfig(key);
    await setProviderConfig(
      key,
      old.copyWith(avatarType: 'url', avatarValue: u),
    );
    // Prefetch for offline
    try {
      await AvatarCache.getPath(u);
    } catch (_) {}
  }

  Future<void> setProviderAvatarFilePath(String key, String path) async {
    final p = path.trim();
    if (p.isEmpty) return;
    final fixedInput = SandboxPathResolver.fix(p);
    try {
      final src = File(fixedInput);
      if (!await src.exists()) return;
      final avatarsDir = await AppDirectories.getAvatarsDirectory();
      if (!await avatarsDir.exists()) {
        await avatarsDir.create(recursive: true);
      }
      String ext = '';
      final dot = fixedInput.lastIndexOf('.');
      if (dot != -1 && dot < fixedInput.length - 1) {
        ext = fixedInput.substring(dot + 1).toLowerCase();
        if (ext.length > 6) ext = 'jpg';
      } else {
        ext = 'jpg';
      }
      final safeKey = key.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
      final filename =
          'provider_${safeKey}_${DateTime.now().millisecondsSinceEpoch}.$ext';
      final dest = File('${avatarsDir.path}/$filename');
      await src.copy(dest.path);

      // Clean old stored avatar file if under managed avatars folder
      final old = getProviderConfig(key);
      if (old.avatarType == 'file' && (old.avatarValue ?? '').isNotEmpty) {
        try {
          final oldFile = File(old.avatarValue!);
          if ((oldFile.path.contains('/avatars/') ||
                  oldFile.path.contains('\\\\avatars\\\\')) &&
              await oldFile.exists()) {
            await oldFile.delete();
          }
        } catch (_) {}
      }

      await setProviderConfig(
        key,
        old.copyWith(avatarType: 'file', avatarValue: dest.path),
      );
    } catch (_) {
      // Fallback: still save original path
      final old = getProviderConfig(key);
      await setProviderConfig(
        key,
        old.copyWith(avatarType: 'file', avatarValue: fixedInput),
      );
    }
  }

  Future<void> resetProviderAvatar(String key) async {
    final old = getProviderConfig(key);
    // Attempt to remove old local file if we managed it
    if (old.avatarType == 'file' && (old.avatarValue ?? '').isNotEmpty) {
      try {
        final f = File(old.avatarValue!);
        if ((f.path.contains('/avatars/') ||
                f.path.contains('\\\\avatars\\\\')) &&
            await f.exists()) {
          await f.delete();
        }
      } catch (_) {}
    }
    // Best-effort: evict cached URL avatar
    if (old.avatarType == 'url' && (old.avatarValue ?? '').isNotEmpty) {
      try {
        await AvatarCache.evict(old.avatarValue!);
      } catch (_) {}
    }
    await setProviderConfig(
      key,
      old.copyWith(avatarType: null, avatarValue: null),
    );
  }

  /// Clears all global model selections (current, title, translate, OCR) that reference the given provider.
  /// Used when a provider is disabled or deleted.
  Future<void> clearSelectionsForProvider(String providerKey) async {
    final prefs = await SharedPreferences.getInstance();
    bool changed = false;
    if (_currentModelProvider == providerKey) {
      _currentModelProvider = null;
      _currentModelId = null;
      await prefs.remove(_selectedModelKey);
      changed = true;
    }
    if (_titleModelProvider == providerKey) {
      _titleModelProvider = null;
      _titleModelId = null;
      await prefs.remove(_titleModelKey);
      changed = true;
    }
    if (_translateModelProvider == providerKey) {
      _translateModelProvider = null;
      _translateModelId = null;
      await prefs.remove(_translateModelKey);
      changed = true;
    }
    if (_ocrModelProvider == providerKey) {
      _ocrModelProvider = null;
      _ocrModelId = null;
      _ocrEnabled = false;
      await prefs.remove(_ocrModelKey);
      await prefs.setBool(_ocrEnabledKey, false);
      changed = true;
    }
    if (_summaryModelProvider == providerKey) {
      _summaryModelProvider = null;
      _summaryModelId = null;
      await prefs.remove(_summaryModelKey);
      changed = true;
    }
    if (_compressModelProvider == providerKey) {
      _compressModelProvider = null;
      _compressModelId = null;
      await prefs.remove(_compressModelKey);
      changed = true;
    }
    if (changed) notifyListeners();
  }

  /// Clears global model selections that reference a specific model.
  /// Used when a model is deleted from a provider.
  Future<void> clearSelectionsForModel(
    String providerKey,
    String modelId,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    bool changed = false;
    if (_currentModelProvider == providerKey && _currentModelId == modelId) {
      _currentModelProvider = null;
      _currentModelId = null;
      await prefs.remove(_selectedModelKey);
      changed = true;
    }
    if (_titleModelProvider == providerKey && _titleModelId == modelId) {
      _titleModelProvider = null;
      _titleModelId = null;
      await prefs.remove(_titleModelKey);
      changed = true;
    }
    if (_translateModelProvider == providerKey &&
        _translateModelId == modelId) {
      _translateModelProvider = null;
      _translateModelId = null;
      await prefs.remove(_translateModelKey);
      changed = true;
    }
    if (_ocrModelProvider == providerKey && _ocrModelId == modelId) {
      _ocrModelProvider = null;
      _ocrModelId = null;
      _ocrEnabled = false;
      await prefs.remove(_ocrModelKey);
      await prefs.setBool(_ocrEnabledKey, false);
      changed = true;
    }
    if (_summaryModelProvider == providerKey && _summaryModelId == modelId) {
      _summaryModelProvider = null;
      _summaryModelId = null;
      await prefs.remove(_summaryModelKey);
      changed = true;
    }
    if (_compressModelProvider == providerKey && _compressModelId == modelId) {
      _compressModelProvider = null;
      _compressModelId = null;
      await prefs.remove(_compressModelKey);
      changed = true;
    }
    // Also remove from pinned if applicable
    final pinKey = '$providerKey::$modelId';
    if (_pinnedModels.contains(pinKey)) {
      _pinnedModels.remove(pinKey);
      await prefs.setStringList(_pinnedModelsKey, _pinnedModels.toList());
      changed = true;
    }
    if (changed) notifyListeners();
  }

  Future<void> removeProviderConfig(String key) async {
    if (!_providerConfigs.containsKey(key)) return;
    _providerConfigs.remove(key);
    // Remove from order
    _providersOrder = List<String>.from(_providersOrder.where((k) => k != key));

    // Clear selections referencing this provider to avoid re-creating defaults
    final prefs = await SharedPreferences.getInstance();
    if (_currentModelProvider == key) {
      _currentModelProvider = null;
      _currentModelId = null;
      await prefs.remove(_selectedModelKey);
    }
    if (_titleModelProvider == key) {
      _titleModelProvider = null;
      _titleModelId = null;
      await prefs.remove(_titleModelKey);
    }
    if (_translateModelProvider == key) {
      _translateModelProvider = null;
      _translateModelId = null;
      await prefs.remove(_translateModelKey);
    }
    if (_ocrModelProvider == key) {
      _ocrModelProvider = null;
      _ocrModelId = null;
      _ocrEnabled = false;
      await prefs.remove(_ocrModelKey);
      await prefs.setBool(_ocrEnabledKey, false);
    }
    if (_summaryModelProvider == key) {
      _summaryModelProvider = null;
      _summaryModelId = null;
      await prefs.remove(_summaryModelKey);
    }
    if (_compressModelProvider == key) {
      _compressModelProvider = null;
      _compressModelId = null;
      await prefs.remove(_compressModelKey);
    }

    // Remove pinned models for this provider
    final beforePinned = _pinnedModels.length;
    _pinnedModels.removeWhere((entry) => entry.startsWith('$key::'));
    if (_pinnedModels.length != beforePinned) {
      await prefs.setStringList(_pinnedModelsKey, _pinnedModels.toList());
    }

    // Persist updates
    final map = _providerConfigs.map((k, v) => MapEntry(k, v.toJson()));
    await prefs.setString(_providerConfigsKey, jsonEncode(map));
    await prefs.setStringList(_providersOrderKey, _providersOrder);
    notifyListeners();
  }

  // Favorites (pinned models)
  final Set<String> _pinnedModels = <String>{};
  Set<String> get pinnedModels => Set.unmodifiable(_pinnedModels);
  bool isModelPinned(String providerKey, String modelId) =>
      _pinnedModels.contains('$providerKey::$modelId');
  Future<void> togglePinModel(String providerKey, String modelId) async {
    final k = '$providerKey::$modelId';
    if (_pinnedModels.contains(k)) {
      _pinnedModels.remove(k);
    } else {
      _pinnedModels.add(k);
    }
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_pinnedModelsKey, _pinnedModels.toList());
  }

  // Selected model for chat
  String? _currentModelProvider;
  String? _currentModelId;
  String? get currentModelProvider => _currentModelProvider;
  String? get currentModelId => _currentModelId;
  String? get currentModelKey =>
      (_currentModelProvider != null && _currentModelId != null)
      ? '${_currentModelProvider!}::${_currentModelId!}'
      : null;
  Future<void> setCurrentModel(String providerKey, String modelId) async {
    _currentModelProvider = providerKey;
    _currentModelId = modelId;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_selectedModelKey, '$providerKey::$modelId');
  }

  Future<void> resetCurrentModel() async {
    _currentModelProvider = null;
    _currentModelId = null;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_selectedModelKey);
  }

  // Title model and prompt
  String? _titleModelProvider;
  String? _titleModelId;
  String? get titleModelProvider => _titleModelProvider;
  String? get titleModelId => _titleModelId;
  String? get titleModelKey =>
      (_titleModelProvider != null && _titleModelId != null)
      ? '${_titleModelProvider!}::${_titleModelId!}'
      : null;

  static const String defaultTitlePrompt =
      '''I will give you some dialogue content in the `<content>` block.
You need to summarize the conversation between user and assistant into a short title.
1. The title language should be consistent with the user's primary language
2. Do not use punctuation or other special symbols
3. Reply directly with the title
4. Summarize using {locale} language
5. The title should not exceed 10 characters

<content>
{content}
</content>''';

  String _titlePrompt = defaultTitlePrompt;
  String get titlePrompt => _titlePrompt;

  Future<void> setTitleModel(String providerKey, String modelId) async {
    _titleModelProvider = providerKey;
    _titleModelId = modelId;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_titleModelKey, '$providerKey::$modelId');
  }

  Future<void> resetTitleModel() async {
    _titleModelProvider = null;
    _titleModelId = null;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_titleModelKey);
  }

  Future<void> setTitlePrompt(String prompt) async {
    _titlePrompt = prompt.trim().isEmpty ? defaultTitlePrompt : prompt;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_titlePromptKey, _titlePrompt);
  }

  Future<void> resetTitlePrompt() async => setTitlePrompt(defaultTitlePrompt);

  // Translate model and prompt
  String? _translateModelProvider;
  String? _translateModelId;
  String? get translateModelProvider => _translateModelProvider;
  String? get translateModelId => _translateModelId;
  String? get translateModelKey =>
      (_translateModelProvider != null && _translateModelId != null)
      ? '${_translateModelProvider!}::${_translateModelId!}'
      : null;

  static const String defaultTranslatePrompt =
      '''You are a translation expert, skilled in translating various languages, and maintaining accuracy, faithfulness, and elegance in translation.
Next, I will send you text. Please translate it into {target_lang}, and return the translation result directly, without adding any explanations or other content.

Please translate the <source_text> section:
<source_text>
{source_text}
</source_text>''';

  String _translatePrompt = defaultTranslatePrompt;
  String get translatePrompt => _translatePrompt;

  Future<void> setTranslateModel(String providerKey, String modelId) async {
    _translateModelProvider = providerKey;
    _translateModelId = modelId;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_translateModelKey, '$providerKey::$modelId');
  }

  Future<void> resetTranslateModel() async {
    _translateModelProvider = null;
    _translateModelId = null;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_translateModelKey);
  }

  Future<void> setTranslatePrompt(String prompt) async {
    _translatePrompt = prompt.trim().isEmpty ? defaultTranslatePrompt : prompt;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_translatePromptKey, _translatePrompt);
  }

  Future<void> resetTranslatePrompt() async =>
      setTranslatePrompt(defaultTranslatePrompt);

  // Greeting model and prompt
  String? _greetingModelProvider;
  String? _greetingModelId;
  String? get greetingModelProvider => _greetingModelProvider;
  String? get greetingModelId => _greetingModelId;
  String? get greetingModelKey =>
      (_greetingModelProvider != null && _greetingModelId != null)
      ? '${_greetingModelProvider!}::${_greetingModelId!}'
      : null;

  static const String defaultGreetingPromptZhHant =
      '請用台灣繁體中文生成一句簡短、溫馨且親切的AI助理對話開場問候語（10字以內，切勿使用大陸用語如「晚上好」、「下午好」，勿包含引號或說明文字）。';
  static const String defaultGreetingPromptZhHans =
      '请用简短、温馨且亲切的中文生成一句AI助手对话开场问候语（10字以内，勿包含引号或说明文字）。';
  static const String defaultGreetingPromptEn =
      'Generate a short, warm, and friendly AI assistant greeting for starting a conversation (within 10 words, do not include quotes or explanatory text).';

  static String getDefaultGreetingPrompt(Locale? locale) {
    final lang = locale?.languageCode ?? 'zh';
    final script = locale?.scriptCode ?? '';
    final country = locale?.countryCode ?? '';
    if (lang == 'en') return defaultGreetingPromptEn;
    if (lang == 'zh' &&
        (script == 'Hant' || country == 'TW' || country == 'HK')) {
      return defaultGreetingPromptZhHant;
    }
    return defaultGreetingPromptZhHans;
  }

  static const String defaultGreetingPrompt = defaultGreetingPromptZhHant;

  String _greetingPrompt = defaultGreetingPromptZhHant;
  String get greetingPrompt => _greetingPrompt;

  String getGreetingPromptForLocale(Locale? locale) {
    if (_greetingPrompt == defaultGreetingPromptZhHant ||
        _greetingPrompt == defaultGreetingPromptZhHans ||
        _greetingPrompt == defaultGreetingPromptEn) {
      return getDefaultGreetingPrompt(locale);
    }
    return _greetingPrompt;
  }

  Future<void> setGreetingModel(String providerKey, String modelId) async {
    _greetingModelProvider = providerKey;
    _greetingModelId = modelId;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_greetingModelKey, '$providerKey::$modelId');
  }

  Future<void> resetGreetingModel() async {
    _greetingModelProvider = null;
    _greetingModelId = null;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_greetingModelKey);
  }

  Future<void> setGreetingPrompt(String prompt) async {
    final defPrompt = getDefaultGreetingPrompt(appLocale);
    _greetingPrompt = prompt.trim().isEmpty ? defPrompt : prompt;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_greetingPromptKey, _greetingPrompt);
  }

  Future<void> resetGreetingPrompt() async =>
      setGreetingPrompt(getDefaultGreetingPrompt(appLocale));

  // New Chat Page Customization Settings
  String _newChatLogoType = 'model'; // 'omnichat' | 'model' | 'custom' | 'none'
  String get newChatLogoType => _newChatLogoType;

  String? _newChatCustomLogoFileName;
  String? get newChatCustomLogoFileName => _newChatCustomLogoFileName;

  String _newChatTextType =
      'aiGreeting'; // 'presetGreeting' | 'aiGreeting' | 'modelName' | 'none' | 'custom'
  String get newChatTextType => _newChatTextType;

  String _newChatCustomText = '';
  String get newChatCustomText => _newChatCustomText;

  String? _newChatCachedAiGreeting;
  String? get newChatCachedAiGreeting => _newChatCachedAiGreeting;

  Future<void> setNewChatLogoType(String type) async {
    _newChatLogoType = type;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_newChatLogoTypeKey, type);
  }

  Future<void> setNewChatCustomLogoFileName(String? fileName) async {
    _newChatCustomLogoFileName = fileName;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (fileName == null || fileName.isEmpty) {
      await prefs.remove(_newChatCustomLogoFileNameKey);
    } else {
      await prefs.setString(_newChatCustomLogoFileNameKey, fileName);
    }
  }

  Future<void> setNewChatTextType(String type) async {
    _newChatTextType = type;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_newChatTextTypeKey, type);
  }

  Future<void> setNewChatCustomText(String text) async {
    _newChatCustomText = text;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_newChatCustomTextKey, text);
  }

  Future<void> setNewChatCachedAiGreeting(String? greeting) async {
    _newChatCachedAiGreeting = greeting;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (greeting == null) {
      await prefs.remove(_newChatCachedAiGreetingKey);
    } else {
      await prefs.setString(_newChatCachedAiGreetingKey, greeting);
    }
  }

  // OCR model, prompt and toggle
  String? _ocrModelProvider;
  String? _ocrModelId;
  String? get ocrModelProvider => _ocrModelProvider;
  String? get ocrModelId => _ocrModelId;
  String? get ocrModelKey => (_ocrModelProvider != null && _ocrModelId != null)
      ? '${_ocrModelProvider!}::${_ocrModelId!}'
      : null;

  static const String defaultOcrPrompt = '''You are an OCR assistant.

Extract all visible text from the image and also describe any non-text elements (icons, shapes, arrows, objects, symbols, or emojis).

For each element, specify:
- The exact text (for text) or a short description (for non-text).
- For document-type content, please use markdown and latex format.
- If there are objects like buildings or characters, try to identify who they are.
- Its approximate position in the image (e.g., 'top left', 'center right', 'bottom middle').
- Its spatial relationship to nearby elements (e.g., 'above', 'below', 'next to', 'on the left of').

Keep the original reading order and layout structure as much as possible.
Do not interpret or translate—only transcribe and describe what is visually present.''';

  String _ocrPrompt = defaultOcrPrompt;
  String get ocrPrompt => _ocrPrompt;

  bool _ocrEnabled = false;
  bool get ocrEnabled => _ocrEnabled;

  Future<void> setOcrModel(String providerKey, String modelId) async {
    _ocrModelProvider = providerKey;
    _ocrModelId = modelId;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_ocrModelKey, '$providerKey::$modelId');
  }

  Future<void> resetOcrModel() async {
    _ocrModelProvider = null;
    _ocrModelId = null;
    _ocrEnabled = false;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_ocrModelKey);
    await prefs.setBool(_ocrEnabledKey, false);
  }

  Future<void> setOcrPrompt(String prompt) async {
    _ocrPrompt = prompt.trim().isEmpty ? defaultOcrPrompt : prompt;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_ocrPromptKey, _ocrPrompt);
  }

  Future<void> resetOcrPrompt() async => setOcrPrompt(defaultOcrPrompt);

  Future<void> setOcrEnabled(bool value) async {
    // If there is no OCR model configured, force disable.
    if (_ocrModelProvider == null || _ocrModelId == null) {
      value = false;
    }
    if (_ocrEnabled == value) return;
    _ocrEnabled = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_ocrEnabledKey, _ocrEnabled);
  }

  // Summary model and prompt
  String? _summaryModelProvider;
  String? _summaryModelId;
  String? get summaryModelProvider => _summaryModelProvider;
  String? get summaryModelId => _summaryModelId;
  String? get summaryModelKey =>
      (_summaryModelProvider != null && _summaryModelId != null)
      ? '${_summaryModelProvider!}::${_summaryModelId!}'
      : null;

  static const String defaultSummaryPrompt =
      '''I will give you user messages from a conversation in the `<messages>` block.
Generate or update a brief summary of the user's questions and intentions.

1. The summary should be in the same language as the user messages
2. Focus on the user's core questions and intentions
3. Keep it under 100 characters
4. Output the summary directly without any prefix
5. If a previous summary exists, incorporate it with the new messages

<previous_summary>
{previous_summary}
</previous_summary>

<messages>
{user_messages}
</messages>''';

  String _summaryPrompt = defaultSummaryPrompt;
  String get summaryPrompt => _summaryPrompt;

  Future<void> setSummaryModel(String providerKey, String modelId) async {
    _summaryModelProvider = providerKey;
    _summaryModelId = modelId;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_summaryModelKey, '$providerKey::$modelId');
  }

  Future<void> resetSummaryModel() async {
    _summaryModelProvider = null;
    _summaryModelId = null;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_summaryModelKey);
  }

  Future<void> setSummaryPrompt(String prompt) async {
    _summaryPrompt = prompt.trim().isEmpty ? defaultSummaryPrompt : prompt;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_summaryPromptKey, _summaryPrompt);
  }

  Future<void> resetSummaryPrompt() async =>
      setSummaryPrompt(defaultSummaryPrompt);

  // Compress model and prompt
  String? _compressModelProvider;
  String? _compressModelId;
  String? get compressModelProvider => _compressModelProvider;
  String? get compressModelId => _compressModelId;
  String? get compressModelKey =>
      (_compressModelProvider != null && _compressModelId != null)
      ? '${_compressModelProvider!}::${_compressModelId!}'
      : null;

  static const String defaultCompressPrompt =
      '''Provide a detailed summary of the following conversation for continuing in a new session.

The new session will not have access to the original conversation history, so preserve all context needed to continue seamlessly.

Focus on:
- Key topics discussed and why they matter
- Important decisions made and their reasoning
- Current work in progress and its state
- Next steps or open questions to address
- Any relevant technical details, code snippets, or configurations mentioned

Requirements:
1. Write in {locale} language, matching the original conversation language
2. Be concise but complete — do not omit important context
3. Output the summary directly without prefaces or meta-commentary
4. Start with a clear indicator (e.g., "[Summary of previous conversation]" or equivalent)

<conversation>
{content}
</conversation>''';

  String _compressPrompt = defaultCompressPrompt;
  String get compressPrompt => _compressPrompt;

  Future<void> setCompressModel(String providerKey, String modelId) async {
    _compressModelProvider = providerKey;
    _compressModelId = modelId;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_compressModelKey, '$providerKey::$modelId');
  }

  Future<void> resetCompressModel() async {
    _compressModelProvider = null;
    _compressModelId = null;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_compressModelKey);
  }

  Future<void> setCompressPrompt(String prompt) async {
    _compressPrompt = prompt.trim().isEmpty ? defaultCompressPrompt : prompt;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_compressPromptKey, _compressPrompt);
  }

  Future<void> resetCompressPrompt() async =>
      setCompressPrompt(defaultCompressPrompt);

  // Deep Research
  bool _deepResearchEnabled = false;
  bool get deepResearchEnabled => _deepResearchEnabled;
  Future<void> setDeepResearchEnabled(bool v) async {
    if (_deepResearchEnabled == v) return;
    _deepResearchEnabled = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_deepResearchEnabledKey, v);
  }

  static const String defaultDeepResearchPrompt = '''# Role & Persona

You are an advanced Deep Reasoning & Research AI Agent.
Your primary objective is to conduct multi-round, rigorous reasoning integrated with comprehensive research before producing any answer. You think deeply to know what to search for, and search thoroughly to fuel deeper thinking. You value depth of insight, logical validity, and authoritative evidence.

Your purpose is not to validate the first plausible explanation, but to construct the most accurate, well-calibrated, and decision-useful understanding that the available evidence permits.

---

# Epistemic Discipline

Throughout your reasoning and research process, you must maintain a strict distinction between:

1. **Evidence:** Direct observations, data, empirical findings, expert consensus, and other externally checkable claims.
2. **Inference:** Interpretations, causal explanations, generalizations, and conclusions drawn from evidence.
3. **Judgment:** Recommendations, priorities, trade-offs, and value-dependent choices.

Never present an inference as an observed fact. Never present a preference or value judgment as if evidence alone determines it.

---

# Core Protocol

Before formulating your final response, you must strictly follow this iterative process. Execute the following loop repeatedly until the Stop criteria in Step 3 are met:

## Step 1 — Think & Search

Your strategy must evolve across rounds:

- **Round 1 (Frame & Survey):**
  
  - *Think*: Identify the fundamental principles governing this problem. Restate the question sharply. Identify key assumptions, ambiguities, and potential confounders.
  - *Search*: Use broad keywords to build a landscape map of the topic — identify key terms, core debates, the vocabulary of the field, and authoritative sources.
- **Round 2+ (Deepen & Target):**
  
  - *Think*: Challenge your current understanding by applying **one or more** of the most relevant of these **7 Analytical Lenses**:
    
    1. **Adversarial**: Step outside your framing. Steel-man the opposing view — construct it in its strongest form before rebutting. Where are the weakest links — cherry-picked evidence, survivorship bias, unstated assumptions?
    2. **Causal/Structural**: Identify mechanisms, hidden dependencies, feedback loops, second-order effects, and edge cases.
    3. **Comparative**: Compare realistic alternatives, base rates, benchmarks, and opportunity costs.
    4. **Temporal**: Examine trends, time horizons, tipping points, path dependency, and conditions under which findings may no longer hold.
    5. **Stakeholder**: Analyze how incentives, risks, and constraints vary across affected groups.
    6. **Analogical**: Use cross-domain analogies to reveal structure, then explicitly test where the analogy breaks.
    7. **Boundary-Condition**: Identify populations, contexts, scales, thresholds, and definitions under which the conclusion changes.
  - *Search*: Use precise queries driven by your current gaps — combine discovered terminology with target concepts, search for counterevidence and methodology critiques, use quoted phrases from sources you've found, add strict constraints (specific years, "systematic review", "meta-analysis", site:.gov/.edu).
    

*(Language rule: Default to English for scientific/technical topics; use the user's language for local/region-specific matters. If results are poor, try the other language. Beyond search, use other available tools as needed.)*

## Step 2 — Reflect & Consolidate

After each round, perform a rigorous self-audit:

1. **What genuinely shifted?** Identify new insights from both your reasoning and your research — not restatements. Do not silently discard conflicting evidence — flag the tension and investigate it.
  
2. **Where is understanding still fragile?** Pinpoint specific gaps, then convert each into:
  
  - A **reasoning question** for the next Think phase (e.g., "Under what conditions does X fail?")
  - A **search query** for the next Search phase (e.g., "X failure rate meta-analysis 2024")
3. **Belief Calibration:**
  
  - Current conclusion:
  - Main support (note source quality — authoritative vs. weak):
  - Main objections:
  - Still uncertain:
  - Ruled-out hypotheses (and why):
  - Define *under what specific conditions or new evidence* your current conclusion would change or stop applying.

## Step 3 — Decision (Continue or Conclude)

🔴 **CONTINUE if ANY of these apply:**

- Your conclusion rests on unexamined assumptions.
- A plausible competing explanation, strong counterargument, or alternative framing has not been seriously tested.
- The evidence is repetitive, weak, rests on a single line of reasoning, or lacks cross-verification from authoritative sources.
- A targeted additional inquiry could plausibly alter your material conclusion.
- Your subjective sense of certainty exceeds what the evidence supports.

🟢 **STOP if MOST of these apply:**

- Additional rounds produce diminishing returns — refinements, not revisions, and recent rounds yield no meaningful new insight.
  
- You have cross-verified key claims from multiple independent, credible sources.
  
- You have stress-tested your conclusion against serious counterarguments.
  
- You can articulate where experts would disagree, and why.
  
- Remaining uncertainty requires information that is genuinely unavailable, not more reasoning or searching.
  
- **If continuing:** State the specific question or weakness driving the next round. Return to Step 1.
  
- **If stopping:** Proceed to the final response.
  

---

# Output Requirements

Synthesize your reasoning and research into a final response. The structure should adapt to the question's complexity. All responses must follow these principles:

1. **Language:** Respond in the same language the user used.
2. **Cite Material Claims.** Every key factual claim must be backed by traceable sources. Use [numbered references] with a reference list at the end. Never fabricate or misrepresent sources.
3. **Epistemic Honesty (where applicable).** Clearly separate what is well-established, what is a well-supported inference, and what remains unresolved. State assumptions, evidence gaps, and source conflicts explicitly. Use explicit epistemic markers (e.g., "evidence suggests," "we infer," "uncertainty remains").
4. **Present the strongest counter-perspective (where applicable).** Articulate the best opposing argument fairly and explain why your position is more compelling — or why the question remains genuinely open.
5. **Be decision-useful.** If the user is making a decision, provide actionable recommendations. If multiple answers are reasonable, state which is best under which condition.''';

  String _deepResearchPrompt = defaultDeepResearchPrompt;
  String get deepResearchPrompt => _deepResearchPrompt;
  Future<void> setDeepResearchPrompt(String prompt) async {
    _deepResearchPrompt = prompt.trim().isEmpty
        ? defaultDeepResearchPrompt
        : prompt;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_deepResearchPromptKey, _deepResearchPrompt);
  }

  Future<void> resetDeepResearchPrompt() async =>
      setDeepResearchPrompt(defaultDeepResearchPrompt);

  // Reasoning strength / thinking budget
  int?
  _thinkingBudget; // null = not set, use provider defaults; -1 = auto; 0 = off; >0 = budget tokens
  int? get thinkingBudget => _thinkingBudget;
  Future<void> setThinkingBudget(int? budget) async {
    _thinkingBudget = budget;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (budget == null) {
      await prefs.remove(_thinkingBudgetKey);
    } else {
      await prefs.setInt(_thinkingBudgetKey, budget);
    }
  }

  // Title generation thinking toggle. Defaults to true for backward compatibility.
  bool _titleGenerationThinkingEnabled = true;
  bool get titleGenerationThinkingEnabled => _titleGenerationThinkingEnabled;
  Future<void> setTitleGenerationThinkingEnabled(bool enabled) async {
    if (_titleGenerationThinkingEnabled == enabled) return;
    _titleGenerationThinkingEnabled = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_titleGenerationThinkingEnabledKey, enabled);
  }

  Future<void> resetTitleGenerationThinkingEnabled() async =>
      setTitleGenerationThinkingEnabled(true);

  int? titleGenerationThinkingBudgetFor(int? assistantBudget) {
    if (!_titleGenerationThinkingEnabled) return 0;
    return assistantBudget ?? _thinkingBudget;
  }

  // Greeting generation thinking toggle. Defaults to true for backward compatibility.
  bool _greetingGenerationThinkingEnabled = true;
  bool get greetingGenerationThinkingEnabled =>
      _greetingGenerationThinkingEnabled;
  Future<void> setGreetingGenerationThinkingEnabled(bool enabled) async {
    if (_greetingGenerationThinkingEnabled == enabled) return;
    _greetingGenerationThinkingEnabled = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_greetingGenerationThinkingEnabledKey, enabled);
  }

  Future<void> resetGreetingGenerationThinkingEnabled() async =>
      setGreetingGenerationThinkingEnabled(true);

  int? greetingGenerationThinkingBudgetFor() {
    if (!_greetingGenerationThinkingEnabled) return 0;
    return _thinkingBudget;
  }

  // Display settings: user avatar and model icon visibility
  bool _showUserAvatar = true;
  bool get showUserAvatar => _showUserAvatar;
  Future<void> setShowUserAvatar(bool v) async {
    if (_showUserAvatar == v) return;
    _showUserAvatar = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_displayShowUserAvatarKey, v);
  }

  // Display: user name & timestamp (for user messages)
  bool _showUserNameTimestamp = true;
  bool get showUserNameTimestamp => _showUserNameTimestamp;
  Future<void> setShowUserNameTimestamp(bool v) async {
    if (_showUserNameTimestamp == v) return;
    _showUserNameTimestamp = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_displayShowUserNameTimestampKey, v);
  }

  bool _showUserMessageActions = true;
  bool get showUserMessageActions => _showUserMessageActions;
  Future<void> setShowUserMessageActions(bool v) async {
    if (_showUserMessageActions == v) return;
    _showUserMessageActions = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_displayShowUserMessageActionsKey, v);
  }

  bool _showModelIcon = true;
  bool get showModelIcon => _showModelIcon;
  Future<void> setShowModelIcon(bool v) async {
    if (_showModelIcon == v) return;
    _showModelIcon = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_displayShowModelIconKey, v);
  }

  // Display: model name & timestamp (for assistant messages)
  bool _showModelNameTimestamp = true;
  bool get showModelNameTimestamp => _showModelNameTimestamp;
  Future<void> setShowModelNameTimestamp(bool v) async {
    if (_showModelNameTimestamp == v) return;
    _showModelNameTimestamp = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_displayShowModelNameTimestampKey, v);
  }

  // Display: token/context stats
  bool _showTokenStats = true;
  bool get showTokenStats => _showTokenStats;
  Future<void> setShowTokenStats(bool v) async {
    if (_showTokenStats == v) return;
    _showTokenStats = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_displayShowTokenStatsKey, v);
  }

  // Display: auto-collapse reasoning/thinking section
  bool _autoCollapseThinking = true;
  bool get autoCollapseThinking => _autoCollapseThinking;

  // Display: show thinking-process cards in chat (default on)
  bool _showThinkingCards = true;
  bool get showThinkingCards => _showThinkingCards;
  Future<void> setShowThinkingCards(bool v) async {
    if (_showThinkingCards == v) return;
    _showThinkingCards = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_displayShowThinkingCardsKey, v);
  }

  // Display: show tool-use cards in chat (default on)
  bool _showToolCards = true;
  bool get showToolCards => _showToolCards;
  Future<void> setShowToolCards(bool v) async {
    if (_showToolCards == v) return;
    _showToolCards = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_displayShowToolCardsKey, v);
  }

  // Behavior: replay tool results across turns (includeToolMessages)
  bool _replayToolResults = true;
  bool get replayToolResults => _replayToolResults;
  Future<void> setReplayToolResults(bool v) async {
    if (_replayToolResults == v) return;
    _replayToolResults = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_displayReplayToolResultsKey, v);
  }
  Future<void> setAutoCollapseThinking(bool v) async {
    if (_autoCollapseThinking == v) return;
    _autoCollapseThinking = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_displayAutoCollapseThinkingKey, v);
  }

  // Display: show message navigation button
  bool _showMessageNavButtons = true;
  bool get showMessageNavButtons => _showMessageNavButtons;
  Future<void> setShowMessageNavButtons(bool v) async {
    if (_showMessageNavButtons == v) return;
    _showMessageNavButtons = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_displayShowMessageNavKey, v);
  }

  // Display: show provider name in model capsule (desktop header)
  bool _showProviderInModelCapsule = true;
  bool get showProviderInModelCapsule => _showProviderInModelCapsule;
  Future<void> setShowProviderInModelCapsule(bool v) async {
    if (_showProviderInModelCapsule == v) return;
    _showProviderInModelCapsule = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_displayShowProviderInModelCapsuleKey, v);
  }

  // Display: create a new chat on app launch
  bool _newChatOnLaunch = true;
  bool get newChatOnLaunch => _newChatOnLaunch;
  Future<void> setNewChatOnLaunch(bool v) async {
    if (_newChatOnLaunch == v) return;
    _newChatOnLaunch = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_displayNewChatOnLaunchKey, v);
  }

  // Display: create a new chat when switching assistants
  bool _newChatOnAssistantSwitch = false;
  bool get newChatOnAssistantSwitch => _newChatOnAssistantSwitch;
  Future<void> setNewChatOnAssistantSwitch(bool v) async {
    if (_newChatOnAssistantSwitch == v) return;
    _newChatOnAssistantSwitch = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_displayNewChatOnAssistantSwitchKey, v);
  }

  // Display: create a new chat after deleting one
  bool _newChatAfterDelete = false;
  bool get newChatAfterDelete => _newChatAfterDelete;
  Future<void> setNewChatAfterDelete(bool v) async {
    if (_newChatAfterDelete == v) return;
    _newChatAfterDelete = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_displayNewChatAfterDeleteKey, v);
  }

  // Display: chat font scale (0.5 - 1.5, default 1.0)
  double _chatFontScale = 1.0;
  double get chatFontScale => _chatFontScale;
  Future<void> setChatFontScale(double scale) async {
    final s = scale.clamp(0.5, 1.5);
    if (_chatFontScale == s) return;
    _chatFontScale = s;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_displayChatFontScaleKey, _chatFontScale);
  }

  // Display: auto-scroll back to bottom toggle
  bool _autoScrollEnabled = true;
  bool get autoScrollEnabled => _autoScrollEnabled;
  Future<void> setAutoScrollEnabled(bool v) async {
    if (_autoScrollEnabled == v) return;
    _autoScrollEnabled = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_displayAutoScrollEnabledKey, v);
  }

  // Display: auto-scroll back to bottom idle timeout (seconds)
  int _autoScrollIdleSeconds = 8;
  int get autoScrollIdleSeconds => _autoScrollIdleSeconds;
  Future<void> setAutoScrollIdleSeconds(int seconds) async {
    final v = seconds.clamp(2, 64);
    if (_autoScrollIdleSeconds == v) return;
    _autoScrollIdleSeconds = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      _displayAutoScrollIdleSecondsKey,
      _autoScrollIdleSeconds,
    );
  }

  // Display: chat background mask strength (0.0 - 2.0, default 1.0)
  double _chatBackgroundMaskStrength = 1.0;
  double get chatBackgroundMaskStrength => _chatBackgroundMaskStrength;
  Future<void> setChatBackgroundMaskStrength(double strength) async {
    final s = strength.clamp(0.0, 2.0);
    if (_chatBackgroundMaskStrength == s) return;
    _chatBackgroundMaskStrength = s;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(
      _displayChatBackgroundMaskStrengthKey,
      _chatBackgroundMaskStrength,
    );
  }

  // Display: inline $...$ LaTeX rendering
  bool _enableDollarLatex = true;
  bool get enableDollarLatex => _enableDollarLatex;
  Future<void> setEnableDollarLatex(bool v) async {
    if (_enableDollarLatex == v) return;
    _enableDollarLatex = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_displayEnableDollarLatexKey, v);
  }

  // Display: LaTeX math rendering (inline/block)
  bool _enableMathRendering = true;
  bool get enableMathRendering => _enableMathRendering;
  Future<void> setEnableMathRendering(bool v) async {
    if (_enableMathRendering == v) return;
    _enableMathRendering = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_displayEnableMathRenderingKey, v);
  }

  // Display: render user messages with Markdown
  bool _enableUserMarkdown = true;
  bool get enableUserMarkdown => _enableUserMarkdown;
  Future<void> setEnableUserMarkdown(bool v) async {
    if (_enableUserMarkdown == v) return;
    _enableUserMarkdown = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_displayEnableUserMarkdownKey, v);
  }

  // Display: render reasoning (thinking) content with Markdown
  bool _enableReasoningMarkdown = true;
  bool get enableReasoningMarkdown => _enableReasoningMarkdown;
  Future<void> setEnableReasoningMarkdown(bool v) async {
    if (_enableReasoningMarkdown == v) return;
    _enableReasoningMarkdown = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_displayEnableReasoningMarkdownKey, v);
  }

  // Display: show chat list date
  bool _showChatListDate = false;
  bool get showChatListDate => _showChatListDate;
  Future<void> setShowChatListDate(bool v) async {
    if (_showChatListDate == v) return;
    _showChatListDate = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_displayShowChatListDateKey, v);
  }

  // Display: mobile code block word wrap
  bool _mobileCodeBlockWrap = false;
  bool get mobileCodeBlockWrap => _mobileCodeBlockWrap;
  Future<void> setMobileCodeBlockWrap(bool v) async {
    if (_mobileCodeBlockWrap == v) return;
    _mobileCodeBlockWrap = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_displayMobileCodeBlockWrapKey, v);
  }

  // Display: auto-collapse code blocks
  bool _autoCollapseCodeBlock = false;
  bool get autoCollapseCodeBlock => _autoCollapseCodeBlock;
  Future<void> setAutoCollapseCodeBlock(bool v) async {
    if (_autoCollapseCodeBlock == v) return;
    _autoCollapseCodeBlock = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_displayAutoCollapseCodeBlockKey, v);
  }

  // Display: code block auto-collapse threshold (lines)
  int _autoCollapseCodeBlockLines = 2;
  int get autoCollapseCodeBlockLines => _autoCollapseCodeBlockLines;
  Future<void> setAutoCollapseCodeBlockLines(int v) async {
    final next = v.clamp(1, 999);
    if (_autoCollapseCodeBlockLines == next) return;
    _autoCollapseCodeBlockLines = next;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_displayAutoCollapseCodeBlockLinesKey, next);
  }

  // Desktop-only: auto switch to Topics tab when changing assistant
  bool _desktopAutoSwitchTopics = false;
  bool get desktopAutoSwitchTopics => _desktopAutoSwitchTopics;
  Future<void> setDesktopAutoSwitchTopics(bool v) async {
    if (_desktopAutoSwitchTopics == v) return;
    _desktopAutoSwitchTopics = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_displayDesktopAutoSwitchTopicsKey, v);
  }

  // Desktop-only: show system tray icon
  bool _desktopShowTray = false;
  bool get desktopShowTray => _desktopShowTray;
  Future<void> setDesktopShowTray(bool v) async {
    if (_desktopShowTray == v) return;
    _desktopShowTray = v;
    if (!_desktopShowTray && _desktopMinimizeToTrayOnClose) {
      _desktopMinimizeToTrayOnClose = false;
    }
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_displayDesktopShowTrayKey, _desktopShowTray);
    await prefs.setBool(
      _displayDesktopMinimizeToTrayOnCloseKey,
      _desktopMinimizeToTrayOnClose,
    );
  }

  // Desktop-only: minimize to tray when closing window
  bool _desktopMinimizeToTrayOnClose = false;
  bool get desktopMinimizeToTrayOnClose => _desktopMinimizeToTrayOnClose;
  Future<void> setDesktopMinimizeToTrayOnClose(bool v) async {
    final next = _desktopShowTray ? v : false;
    if (_desktopMinimizeToTrayOnClose == next) return;
    _desktopMinimizeToTrayOnClose = next;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(
      _displayDesktopMinimizeToTrayOnCloseKey,
      _desktopMinimizeToTrayOnClose,
    );
  }

  // Display: haptics on message generation
  bool _hapticsOnGenerate = false;
  bool get hapticsOnGenerate => _hapticsOnGenerate;
  Future<void> setHapticsOnGenerate(bool v) async {
    if (_hapticsOnGenerate == v) return;
    _hapticsOnGenerate = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_displayHapticsOnGenerateKey, v);
  }

  // Display: keep screen on while a conversation is generating
  bool _keepScreenOnDuringGeneration = false;
  bool get keepScreenOnDuringGeneration => _keepScreenOnDuringGeneration;
  Future<void> setKeepScreenOnDuringGeneration(bool v) async {
    if (_keepScreenOnDuringGeneration == v) return;
    _keepScreenOnDuringGeneration = v;
    ScreenWakelock.setEnabled(v);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_displayKeepScreenOnDuringGenerationKey, v);
  }

  // Display: convert long pasted text into a file attachment
  static const int defaultLongPasteAsFileThreshold = 5000;
  static const int minLongPasteAsFileThreshold = 1;
  static const int maxLongPasteAsFileThreshold = 999999;

  static int resolveLongPasteAsFileThreshold(
    String raw, {
    required int fallback,
  }) {
    final parsed = int.tryParse(raw.trim());
    if (parsed == null) return fallback;
    return parsed.clamp(
      minLongPasteAsFileThreshold,
      maxLongPasteAsFileThreshold,
    );
  }

  bool _longPasteAsFile = true;
  bool get longPasteAsFile => _longPasteAsFile;
  Future<void> setLongPasteAsFile(bool v) async {
    if (_longPasteAsFile == v) return;
    _longPasteAsFile = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_displayLongPasteAsFileKey, v);
  }

  int _longPasteAsFileThreshold = defaultLongPasteAsFileThreshold;
  int get longPasteAsFileThreshold => _longPasteAsFileThreshold;
  Future<void> setLongPasteAsFileThreshold(int v) async {
    final next = v.clamp(
      minLongPasteAsFileThreshold,
      maxLongPasteAsFileThreshold,
    );
    if (_longPasteAsFileThreshold == next) return;
    _longPasteAsFileThreshold = next;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_displayLongPasteAsFileThresholdKey, next);
  }

  // Display: haptics on drawer open/close
  bool _hapticsOnDrawer = true;
  bool get hapticsOnDrawer => _hapticsOnDrawer;
  Future<void> setHapticsOnDrawer(bool v) async {
    if (_hapticsOnDrawer == v) return;
    _hapticsOnDrawer = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_displayHapticsOnDrawerKey, v);
  }

  // Display: global haptics master switch
  bool _hapticsGlobalEnabled = true;
  bool get hapticsGlobalEnabled => _hapticsGlobalEnabled;
  Future<void> setHapticsGlobalEnabled(bool v) async {
    if (_hapticsGlobalEnabled == v) return;
    _hapticsGlobalEnabled = v;
    // Apply immediately to service
    Haptics.setEnabled(v);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_displayHapticsGlobalEnabledKey, v);
  }

  // Display: iOS-style switch haptics only
  bool _hapticsIosSwitch = true;
  bool get hapticsIosSwitch => _hapticsIosSwitch;
  Future<void> setHapticsIosSwitch(bool v) async {
    if (_hapticsIosSwitch == v) return;
    _hapticsIosSwitch = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_displayHapticsIosSwitchKey, v);
  }

  // Display: list item tap haptics (e.g., rows in settings pages)
  bool _hapticsOnListItemTap = true;
  bool get hapticsOnListItemTap => _hapticsOnListItemTap;
  Future<void> setHapticsOnListItemTap(bool v) async {
    if (_hapticsOnListItemTap == v) return;
    _hapticsOnListItemTap = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_displayHapticsOnListItemTapKey, v);
  }

  // Display: card tap haptics (e.g., Assistant cards etc.)
  bool _hapticsOnCardTap = true;
  bool get hapticsOnCardTap => _hapticsOnCardTap;
  Future<void> setHapticsOnCardTap(bool v) async {
    if (_hapticsOnCardTap == v) return;
    _hapticsOnCardTap = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_displayHapticsOnCardTapKey, v);
  }

  // Display: show app updates notification
  bool _showAppUpdates = true;
  bool get showAppUpdates => _showAppUpdates;
  Future<void> setShowAppUpdates(bool v) async {
    if (_showAppUpdates == v) return;
    _showAppUpdates = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_displayShowAppUpdatesKey, v);
  }

  // Display: keep sidebar open when selecting assistant (mobile)
  bool _keepSidebarOpenOnAssistantTap = false;
  bool get keepSidebarOpenOnAssistantTap => _keepSidebarOpenOnAssistantTap;
  Future<void> setKeepSidebarOpenOnAssistantTap(bool v) async {
    if (_keepSidebarOpenOnAssistantTap == v) return;
    _keepSidebarOpenOnAssistantTap = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_displayKeepSidebarOpenOnAssistantTapKey, v);
  }

  // Display: keep sidebar open when switching topics (mobile)
  bool _keepSidebarOpenOnTopicTap = false;
  bool get keepSidebarOpenOnTopicTap => _keepSidebarOpenOnTopicTap;
  Future<void> setKeepSidebarOpenOnTopicTap(bool v) async {
    if (_keepSidebarOpenOnTopicTap == v) return;
    _keepSidebarOpenOnTopicTap = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_displayKeepSidebarOpenOnTopicTapKey, v);
  }

  // Display: keep assistant list expanded when closing sidebar (mobile)
  bool _keepAssistantListExpandedOnSidebarClose = false;
  bool get keepAssistantListExpandedOnSidebarClose =>
      _keepAssistantListExpandedOnSidebarClose;
  Future<void> setKeepAssistantListExpandedOnSidebarClose(bool v) async {
    if (_keepAssistantListExpandedOnSidebarClose == v) return;
    _keepAssistantListExpandedOnSidebarClose = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_displayKeepAssistantListExpandedOnSidebarCloseKey, v);
  }

  // Network: request logging (debug)
  bool _requestLogEnabled = false;
  bool get requestLogEnabled => _requestLogEnabled;
  Future<void> setRequestLogEnabled(bool v) async {
    if (_requestLogEnabled == v) return;
    _requestLogEnabled = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_requestLogEnabledKey, v);
    await RequestLogger.setEnabled(v);
  }

  // Flutter: runtime logging (debug)
  bool _flutterLogEnabled = false;
  bool get flutterLogEnabled => _flutterLogEnabled;
  Future<void> setFlutterLogEnabled(bool v) async {
    if (_flutterLogEnabled == v) return;
    _flutterLogEnabled = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_flutterLogEnabledKey, v);
    await FlutterLogger.setEnabled(v);
  }

  Future<void> setDefaultWorkspaceConfig(WorkspaceConfig config) async {
    _defaultWorkspaceConfig = config;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _defaultWorkspaceConfigKey,
      jsonEncode(config.toJson()),
    );
    await prefs.remove(_defaultWorkspacePathKey);
  }

  // Search service settings
  Future<void> setSearchServices(List<SearchServiceOptions> services) async {
    _searchServices = List.from(services);
    if (_searchServiceSelected >= _searchServices.length) {
      _searchServiceSelected = _searchServices.isNotEmpty
          ? _searchServices.length - 1
          : 0;
    }
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _searchServicesKey,
      jsonEncode(_searchServices.map((e) => e.toJson()).toList()),
    );
    await prefs.setInt(_searchSelectedKey, _searchServiceSelected);
  }

  Future<void> setSearchCommonOptions(SearchCommonOptions options) async {
    _searchCommonOptions = options;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_searchCommonKey, jsonEncode(options.toJson()));
  }

  Future<void> setSearchServiceSelected(int index) async {
    _searchServiceSelected = index.clamp(
      0,
      _searchServices.isNotEmpty ? _searchServices.length - 1 : 0,
    );
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_searchSelectedKey, _searchServiceSelected);
  }

  Future<void> setSearchEnabled(bool enabled) async {
    _searchEnabled = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_searchEnabledKey, enabled);
  }

  Future<void> setSearchAutoTestOnLaunch(bool enabled) async {
    _searchAutoTestOnLaunch = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_searchAutoTestOnLaunchKey, enabled);
  }

  /// Save the standalone academic MCP configuration (PubMed / Semantic
  /// Scholar API keys). Independent from the web search services list.
  Future<void> setAcademicConfig(AcademicMcpConfig config) async {
    _academicConfig = config;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _academicConfigKey,
      jsonEncode(config.toJson()),
    );
  }

  // Combined update for settings
  Future<void> updateSettings(SettingsProvider newSettings) async {
    if (_academicConfig != newSettings._academicConfig) {
      await setAcademicConfig(newSettings._academicConfig);
    }
    if (!listEquals(_searchServices, newSettings._searchServices)) {
      await setSearchServices(newSettings._searchServices);
    }
    if (_searchCommonOptions != newSettings._searchCommonOptions) {
      await setSearchCommonOptions(newSettings._searchCommonOptions);
    }
    if (_searchServiceSelected != newSettings._searchServiceSelected) {
      await setSearchServiceSelected(newSettings._searchServiceSelected);
    }
    if (_searchEnabled != newSettings._searchEnabled) {
      await setSearchEnabled(newSettings._searchEnabled);
    }
    if (_searchAutoTestOnLaunch != newSettings._searchAutoTestOnLaunch) {
      await setSearchAutoTestOnLaunch(newSettings._searchAutoTestOnLaunch);
    }
  }

  SettingsProvider copyWith({
    AcademicMcpConfig? academicConfig,
    List<SearchServiceOptions>? searchServices,
    SearchCommonOptions? searchCommonOptions,
    int? searchServiceSelected,
    bool? searchEnabled,
    bool? searchAutoTestOnLaunch,
  }) {
    final copy = SettingsProvider();
    copy._academicConfig = academicConfig ?? _academicConfig;
    copy._searchServices = searchServices ?? _searchServices;
    copy._searchCommonOptions = searchCommonOptions ?? _searchCommonOptions;
    copy._searchServiceSelected =
        searchServiceSelected ?? _searchServiceSelected;
    copy._searchEnabled = searchEnabled ?? _searchEnabled;
    copy._searchAutoTestOnLaunch =
        searchAutoTestOnLaunch ?? _searchAutoTestOnLaunch;
    // Copy other fields
    copy._providersOrder = _providersOrder;
    copy._chatInputButtonOrder = _chatInputButtonOrder;
    copy._chatInputButtonHidden = _chatInputButtonHidden;
    copy._themeMode = _themeMode;
    copy._providerConfigs = _providerConfigs;
    copy._pinnedModels.addAll(_pinnedModels);
    copy._currentModelProvider = _currentModelProvider;
    copy._currentModelId = _currentModelId;
    copy._titleModelProvider = _titleModelProvider;
    copy._titleModelId = _titleModelId;
    copy._titlePrompt = _titlePrompt;
    copy._translateModelProvider = _translateModelProvider;
    copy._translateModelId = _translateModelId;
    copy._translatePrompt = _translatePrompt;
    copy._ocrModelProvider = _ocrModelProvider;
    copy._ocrModelId = _ocrModelId;
    copy._ocrPrompt = _ocrPrompt;
    copy._ocrEnabled = _ocrEnabled;
    copy._thinkingBudget = _thinkingBudget;
    copy._showUserAvatar = _showUserAvatar;
    copy._showModelIcon = _showModelIcon;
    copy._showModelNameTimestamp = _showModelNameTimestamp;
    copy._showTokenStats = _showTokenStats;
    copy._showUserNameTimestamp = _showUserNameTimestamp;
    copy._showUserMessageActions = _showUserMessageActions;
    copy._showThinkingCards = _showThinkingCards;
    copy._showToolCards = _showToolCards;
    copy._autoCollapseThinking = _autoCollapseThinking;
    copy._replayToolResults = _replayToolResults;
    copy._showMessageNavButtons = _showMessageNavButtons;
    copy._showProviderInModelCapsule = _showProviderInModelCapsule;
    copy._hapticsOnGenerate = _hapticsOnGenerate;
    copy._keepScreenOnDuringGeneration = _keepScreenOnDuringGeneration;
    copy._hapticsOnDrawer = _hapticsOnDrawer;
    copy._hapticsGlobalEnabled = _hapticsGlobalEnabled;
    copy._hapticsIosSwitch = _hapticsIosSwitch;
    copy._hapticsOnListItemTap = _hapticsOnListItemTap;
    copy._hapticsOnCardTap = _hapticsOnCardTap;
    copy._longPasteAsFile = _longPasteAsFile;
    copy._longPasteAsFileThreshold = _longPasteAsFileThreshold;
    copy._showAppUpdates = _showAppUpdates;
    copy._keepSidebarOpenOnAssistantTap = _keepSidebarOpenOnAssistantTap;
    copy._keepSidebarOpenOnTopicTap = _keepSidebarOpenOnTopicTap;
    copy._keepAssistantListExpandedOnSidebarClose =
        _keepAssistantListExpandedOnSidebarClose;
    copy._requestLogEnabled = _requestLogEnabled;
    copy._flutterLogEnabled = _flutterLogEnabled;
    copy._newChatOnLaunch = _newChatOnLaunch;
    copy._newChatOnAssistantSwitch = _newChatOnAssistantSwitch;
    copy._newChatAfterDelete = _newChatAfterDelete;
    copy._chatFontScale = _chatFontScale;
    copy._autoScrollEnabled = _autoScrollEnabled;
    copy._autoScrollIdleSeconds = _autoScrollIdleSeconds;
    copy._enableDollarLatex = _enableDollarLatex;
    copy._enableMathRendering = _enableMathRendering;
    copy._enableUserMarkdown = _enableUserMarkdown;
    copy._enableReasoningMarkdown = _enableReasoningMarkdown;
    copy._showChatListDate = _showChatListDate;
    copy._autoCollapseCodeBlock = _autoCollapseCodeBlock;
    copy._autoCollapseCodeBlockLines = _autoCollapseCodeBlockLines;
    copy._desktopAutoSwitchTopics = _desktopAutoSwitchTopics;
    copy._desktopShowTray = _desktopShowTray;
    copy._desktopMinimizeToTrayOnClose = _desktopMinimizeToTrayOnClose;
    copy._usePureBackground = _usePureBackground;
    copy._chatMessageBackgroundStyle = _chatMessageBackgroundStyle;
    return copy;
  }
}

/// Standalone configuration for the built-in Academic_Search MCP server.
///
/// Kept fully independent from the web-search services list: API keys are
/// entered in the MCP server settings (Basic tab) and persisted here.
class AcademicMcpConfig {
  final String pubmedApiKey;
  final String pubmedTool;
  final String pubmedEmail;
  final String semanticScholarApiKey;

  const AcademicMcpConfig({
    this.pubmedApiKey = '',
    this.pubmedTool = '',
    this.pubmedEmail = '',
    this.semanticScholarApiKey = '',
  });

  bool get hasPubMedKey => pubmedApiKey.trim().isNotEmpty;
  bool get hasSemanticScholarKey => semanticScholarApiKey.trim().isNotEmpty;

  AcademicMcpConfig copyWith({
    String? pubmedApiKey,
    String? pubmedTool,
    String? pubmedEmail,
    String? semanticScholarApiKey,
  }) => AcademicMcpConfig(
    pubmedApiKey: pubmedApiKey ?? this.pubmedApiKey,
    pubmedTool: pubmedTool ?? this.pubmedTool,
    pubmedEmail: pubmedEmail ?? this.pubmedEmail,
    semanticScholarApiKey: semanticScholarApiKey ?? this.semanticScholarApiKey,
  );

  Map<String, dynamic> toJson() => {
    'pubmedApiKey': pubmedApiKey,
    'pubmedTool': pubmedTool,
    'pubmedEmail': pubmedEmail,
    'semanticScholarApiKey': semanticScholarApiKey,
  };

  factory AcademicMcpConfig.fromJson(Map<String, dynamic> json) =>
      AcademicMcpConfig(
        pubmedApiKey: json['pubmedApiKey'] ?? '',
        pubmedTool: json['pubmedTool'] ?? '',
        pubmedEmail: json['pubmedEmail'] ?? '',
        semanticScholarApiKey: json['semanticScholarApiKey'] ?? '',
      );

  @override
  bool operator ==(Object other) =>
      other is AcademicMcpConfig &&
      other.pubmedApiKey == pubmedApiKey &&
      other.pubmedTool == pubmedTool &&
      other.pubmedEmail == pubmedEmail &&
      other.semanticScholarApiKey == semanticScholarApiKey;

  @override
  int get hashCode => Object.hash(
    pubmedApiKey,
    pubmedTool,
    pubmedEmail,
    semanticScholarApiKey,
  );
}

class _ProxyHttpOverrides extends HttpOverrides {
  final String host;
  final int port;
  final String? username;
  final String? password;
  _ProxyHttpOverrides({
    required this.host,
    required this.port,
    this.username,
    this.password,
  });
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = (_) => 'PROXY $host:$port';
    if (username != null && username!.isNotEmpty) {
      client.addProxyCredentials(
        host,
        port,
        '',
        HttpClientBasicCredentials(username!, password ?? ''),
      );
    }
    return client;
  }
}

class _SocksProxyHttpOverrides extends HttpOverrides {
  final String host;
  final int port;
  final String? username;
  final String? password;
  _SocksProxyHttpOverrides({
    required this.host,
    required this.port,
    this.username,
    this.password,
  });
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    try {
      final List<socks.ProxySettings> proxies = [
        socks.ProxySettings(
          InternetAddress(host),
          port,
          username: username,
          password: password,
        ),
      ];
      socks.SocksTCPClient.assignToHttpClient(client, proxies);
    } catch (_) {}
    return client;
  }
}

enum ProviderKind { openai, google, claude, neuralwatt }

// Background rendering mode for chat message bubbles
enum ChatMessageBackgroundStyle { defaultStyle, frosted, solid }

enum AndroidBackgroundChatMode { off, on, onNotify }

class ProviderConfig {
  final String id;
  final bool enabled;
  final String name;
  final String apiKey;
  final String baseUrl;
  final ProviderKind?
  providerType; // Explicit provider type to avoid misclassification
  final String? chatPath; // openai only
  final bool? useResponseApi; // openai only
  final bool? vertexAI; // google only
  final String? location; // google vertex ai only
  final String? projectId; // google vertex ai only
  // Google Vertex AI via service account JSON (paste or import)
  final String? serviceAccountJson; // google vertex ai only
  final List<String> models; // placeholder for future model management
  // Per-model overrides (by logical model key).
  // Each entry may point to an upstream/vendor model id via `apiModelId` so that
  // multiple logical models can share the same backend model with different params.
  // {'<key>': {'apiModelId': String?, 'name': String?, 'type': 'chat'|'embedding', 'input': ['text','image'], 'output': [...], 'abilities': ['tool','reasoning']}}
  final Map<String, dynamic> modelOverrides;
  // Per-provider proxy
  final bool? proxyEnabled;
  final String? proxyHost;
  final String? proxyPort;
  final String? proxyUsername;
  final String? proxyPassword;
  // Custom provider avatar (same scheme as user: emoji | url | file)
  final String? avatarType; // 'emoji' | 'url' | 'file'
  final String? avatarValue;
  // Multi-key mode
  final bool? multiKeyEnabled; // default false
  final List<ApiKeyConfig>? apiKeys; // when enabled
  final KeyManagementConfig? keyManagement;
  // AIhubmix promo header opt-in
  final bool? aihubmixAppCodeEnabled;
  // Account balance settings
  final bool? balanceEnabled;
  final String? balanceApiPath;
  final String? balanceResultKey;
  // Anthropic/OpenRouter Claude prompt caching for stable system prompts.
  final bool? claudePromptCachingEnabled;
  final String? claudePromptCachingTtl;

  static const String claudePromptCachingTtl5m = '5m';
  static const String claudePromptCachingTtl1h = '1h';

  static String resolveClaudePromptCachingTtl(String? value) {
    switch (value?.trim().toLowerCase()) {
      case claudePromptCachingTtl1h:
        return claudePromptCachingTtl1h;
      case claudePromptCachingTtl5m:
      default:
        return claudePromptCachingTtl5m;
    }
  }

  static Map<String, dynamic> claudePromptCacheControl(String? ttl) {
    final cacheControl = <String, dynamic>{'type': 'ephemeral'};
    if (resolveClaudePromptCachingTtl(ttl) == claudePromptCachingTtl1h) {
      cacheControl['ttl'] = claudePromptCachingTtl1h;
    }
    return cacheControl;
  }

  ProviderConfig({
    required this.id,
    required this.enabled,
    required this.name,
    required this.apiKey,
    required this.baseUrl,
    this.providerType,
    this.chatPath,
    this.useResponseApi,
    this.vertexAI,
    this.location,
    this.projectId,
    this.serviceAccountJson,
    this.models = const [],
    this.modelOverrides = const {},
    this.proxyEnabled,
    this.proxyHost,
    this.proxyPort,
    this.proxyUsername,
    this.proxyPassword,
    this.avatarType,
    this.avatarValue,
    this.multiKeyEnabled,
    this.apiKeys,
    this.keyManagement,
    this.aihubmixAppCodeEnabled,
    this.balanceEnabled,
    this.balanceApiPath,
    this.balanceResultKey,
    this.claudePromptCachingEnabled = false,
    this.claudePromptCachingTtl = claudePromptCachingTtl5m,
  });

  // Sentinel for copyWith nullability control (allow explicit null set)
  static const Object _sentinel = Object();

  ProviderConfig copyWith({
    String? id,
    bool? enabled,
    String? name,
    String? apiKey,
    String? baseUrl,
    ProviderKind? providerType,
    String? chatPath,
    bool? useResponseApi,
    bool? vertexAI,
    String? location,
    String? projectId,
    String? serviceAccountJson,
    List<String>? models,
    Map<String, dynamic>? modelOverrides,
    bool? proxyEnabled,
    String? proxyHost,
    String? proxyPort,
    String? proxyUsername,
    String? proxyPassword,
    Object? avatarType = _sentinel,
    Object? avatarValue = _sentinel,
    bool? multiKeyEnabled,
    List<ApiKeyConfig>? apiKeys,
    KeyManagementConfig? keyManagement,
    bool? aihubmixAppCodeEnabled,
    bool? balanceEnabled,
    String? balanceApiPath,
    String? balanceResultKey,
    bool? claudePromptCachingEnabled,
    String? claudePromptCachingTtl,
  }) => ProviderConfig(
    id: id ?? this.id,
    enabled: enabled ?? this.enabled,
    name: name ?? this.name,
    apiKey: apiKey ?? this.apiKey,
    baseUrl: baseUrl ?? this.baseUrl,
    providerType: providerType ?? this.providerType,
    chatPath: chatPath ?? this.chatPath,
    useResponseApi: useResponseApi ?? this.useResponseApi,
    vertexAI: vertexAI ?? this.vertexAI,
    location: location ?? this.location,
    projectId: projectId ?? this.projectId,
    serviceAccountJson: serviceAccountJson ?? this.serviceAccountJson,
    models: models != null
        ? uniqueModels(models)
        : uniqueModels(this.models),
    modelOverrides: modelOverrides ?? this.modelOverrides,
    proxyEnabled: proxyEnabled ?? this.proxyEnabled,
    proxyHost: proxyHost ?? this.proxyHost,
    proxyPort: proxyPort ?? this.proxyPort,
    proxyUsername: proxyUsername ?? this.proxyUsername,
    proxyPassword: proxyPassword ?? this.proxyPassword,
    avatarType: (identical(avatarType, _sentinel))
        ? this.avatarType
        : (avatarType as String?),
    avatarValue: (identical(avatarValue, _sentinel))
        ? this.avatarValue
        : (avatarValue as String?),
    multiKeyEnabled: multiKeyEnabled ?? this.multiKeyEnabled,
    apiKeys: apiKeys ?? this.apiKeys,
    keyManagement: keyManagement ?? this.keyManagement,
    aihubmixAppCodeEnabled:
        aihubmixAppCodeEnabled ?? this.aihubmixAppCodeEnabled,
    balanceEnabled: balanceEnabled ?? this.balanceEnabled,
    balanceApiPath: balanceApiPath ?? this.balanceApiPath,
    balanceResultKey: balanceResultKey ?? this.balanceResultKey,
    claudePromptCachingEnabled:
        claudePromptCachingEnabled ?? this.claudePromptCachingEnabled,
    claudePromptCachingTtl:
        claudePromptCachingTtl ?? this.claudePromptCachingTtl,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'enabled': enabled,
    'name': name,
    'apiKey': apiKey,
    'baseUrl': baseUrl,
    'providerType': providerType?.name,
    'chatPath': chatPath,
    'useResponseApi': useResponseApi,
    'vertexAI': vertexAI,
    'location': location,
    'projectId': projectId,
    'serviceAccountJson': serviceAccountJson,
    'models': models,
    'modelOverrides': modelOverrides,
    'proxyEnabled': proxyEnabled,
    'proxyHost': proxyHost,
    'proxyPort': proxyPort,
    'proxyUsername': proxyUsername,
    'proxyPassword': proxyPassword,
    'avatarType': avatarType,
    'avatarValue': avatarValue,
    'multiKeyEnabled': multiKeyEnabled,
    'apiKeys': apiKeys?.map((e) => e.toJson()).toList(),
    'keyManagement': keyManagement?.toJson(),
    'aihubmixAppCodeEnabled': aihubmixAppCodeEnabled,
    'balanceEnabled': balanceEnabled,
    'balanceApiPath': balanceApiPath,
    'balanceResultKey': balanceResultKey,
    'claudePromptCachingEnabled': claudePromptCachingEnabled,
    'claudePromptCachingTtl': resolveClaudePromptCachingTtl(
      claudePromptCachingTtl,
    ),
  };

  /// Returns [ids] with duplicates removed, preserving first-occurrence order.
  /// Duplicate model IDs break the models tab (duplicate widget keys) and
  /// batch detection; callers normalize (trim) IDs before they reach here.
  static List<String> uniqueModels(Iterable<String> ids) {
    final seen = <String>{};
    return [
      for (final id in ids)
        if (seen.add(id)) id,
    ];
  }

  factory ProviderConfig.fromJson(Map<String, dynamic> json) => ProviderConfig(
    id: json['id'] as String? ?? (json['name'] as String? ?? ''),
    enabled: json['enabled'] as bool? ?? true,
    name: json['name'] as String? ?? '',
    apiKey: json['apiKey'] as String? ?? '',
    baseUrl: json['baseUrl'] as String? ?? '',
    providerType: json['providerType'] != null
        ? ProviderKind.values.firstWhere(
            (e) => e.name == json['providerType'],
            orElse: () => classify(json['id'] as String? ?? ''),
          )
        : null,
    chatPath: json['chatPath'] as String?,
    useResponseApi: json['useResponseApi'] as bool?,
    vertexAI: json['vertexAI'] as bool?,
    location: json['location'] as String?,
    projectId: json['projectId'] as String?,
    serviceAccountJson: json['serviceAccountJson'] as String?,
    models: uniqueModels(
      (json['models'] as List?)?.map((e) => e.toString()) ?? const [],
    ),
    modelOverrides:
        (json['modelOverrides'] as Map?)?.map(
          (k, v) => MapEntry(k.toString(), v),
        ) ??
        const {},
    proxyEnabled: json['proxyEnabled'] as bool?,
    proxyHost: json['proxyHost'] as String?,
    proxyPort: json['proxyPort'] as String?,
    proxyUsername: json['proxyUsername'] as String?,
    proxyPassword: json['proxyPassword'] as String?,
    avatarType: json['avatarType'] as String?,
    avatarValue: json['avatarValue'] as String?,
    multiKeyEnabled: json['multiKeyEnabled'] as bool?,
    apiKeys: (json['apiKeys'] as List?)
        ?.whereType<Map>()
        .map((e) => ApiKeyConfig.fromJson(e.cast<String, dynamic>()))
        .toList(),
    keyManagement: KeyManagementConfig.fromJson(
      (json['keyManagement'] as Map?)?.cast<String, dynamic>(),
    ),
    aihubmixAppCodeEnabled: json['aihubmixAppCodeEnabled'] as bool?,
    balanceEnabled: json['balanceEnabled'] as bool?,
    balanceApiPath: json['balanceApiPath'] as String?,
    balanceResultKey: json['balanceResultKey'] as String?,
    claudePromptCachingEnabled:
        json['claudePromptCachingEnabled'] as bool? ?? false,
    claudePromptCachingTtl: resolveClaudePromptCachingTtl(
      json['claudePromptCachingTtl'] as String?,
    ),
  );

  static ProviderKind classify(String key, {ProviderKind? explicitType}) {
    // If an explicit type is provided, use it
    if (explicitType != null) return explicitType;

    // Otherwise, infer from the key
    final k = key.toLowerCase();
    if (k.contains('neuralwatt')) return ProviderKind.neuralwatt;
    if (k.contains('gemini') || k.contains('google'))
      return ProviderKind.google;
    if (k.contains('claude') || k.contains('anthropic'))
      return ProviderKind.claude;
    return ProviderKind.openai;
  }

  static String _defaultBase(String key) {
    final k = key.toLowerCase();
    if (k.contains('tensdaq')) return 'https://tensdaq-api.x-aio.com/v1';
    if (k.contains('neuralwatt')) return 'https://api.neuralwatt.com/v1';
    if (k.contains('openrouter')) return 'https://openrouter.ai/api/v1';
    if (k.contains('aihubmix')) return 'https://aihubmix.com/v1';
    if (RegExp(r'qwen|aliyun|dashscope').hasMatch(k))
      return 'https://dashscope.aliyuncs.com/compatible-mode/v1';
    if (RegExp(r'bytedance|doubao|volces|ark').hasMatch(k))
      return 'https://ark.cn-beijing.volces.com/api/v3';
    if (k.contains('silicon')) return 'https://api.siliconflow.cn/v1';
    if (k.contains('grok') || k.contains('x.ai') || k.contains('xai'))
      return 'https://api.x.ai/v1';
    if (k.contains('deepseek')) return 'https://api.deepseek.com/v1';
    if (RegExp(r'zhipu|智谱|glm').hasMatch(k))
      return 'https://open.bigmodel.cn/api/paas/v4';
    if (k.contains('gemini') || k.contains('google'))
      return 'https://generativelanguage.googleapis.com/v1beta';
    if (k.contains('claude') || k.contains('anthropic'))
      return 'https://api.anthropic.com/v1';
    return 'https://api.openai.com/v1';
  }

  static ProviderConfig defaultsFor(String key, {String? displayName}) {
    bool _defaultEnabled(String k) {
      final s = k.toLowerCase();
      if (s.contains('tensdaq')) return true;
      if (s.contains('openai')) return true;
      if (s.contains('gemini') || s.contains('google')) return true;
      if (s.contains('silicon')) return true;
      if (s.contains('openrouter')) return true;
      if (s.contains('neuralwatt')) return true;
      return false; // others disabled by default
    }

    final kind = classify(key);
    final lowerKey = key.toLowerCase();
    switch (kind) {
      case ProviderKind.google:
        return ProviderConfig(
          id: key,
          enabled: _defaultEnabled(key),
          name: displayName ?? key,
          apiKey: '',
          baseUrl: _defaultBase(key),
          providerType: ProviderKind.google,
          vertexAI: false,
          location: '',
          projectId: '',
          serviceAccountJson: '',
          models: const [],
          modelOverrides: const {},
          proxyEnabled: false,
          proxyHost: '',
          proxyPort: '8080',
          proxyUsername: '',
          proxyPassword: '',
          multiKeyEnabled: false,
          apiKeys: const [],
          keyManagement: const KeyManagementConfig(),
          aihubmixAppCodeEnabled: false,
          balanceEnabled: false,
          balanceApiPath: '/user/info',
          balanceResultKey: 'data.totalBalance',
          claudePromptCachingEnabled: false,
        );
      case ProviderKind.claude:
        return ProviderConfig(
          id: key,
          enabled: _defaultEnabled(key),
          name: displayName ?? key,
          apiKey: '',
          baseUrl: _defaultBase(key),
          providerType: ProviderKind.claude,
          models: const [],
          modelOverrides: const {},
          proxyEnabled: false,
          proxyHost: '',
          proxyPort: '8080',
          proxyUsername: '',
          proxyPassword: '',
          multiKeyEnabled: false,
          apiKeys: const [],
          keyManagement: const KeyManagementConfig(),
          aihubmixAppCodeEnabled: false,
          balanceEnabled: false,
          balanceApiPath: '',
          balanceResultKey: '',
          claudePromptCachingEnabled: false,
        );
      case ProviderKind.neuralwatt:
        return ProviderConfig(
          id: key,
          enabled: _defaultEnabled(key),
          name: displayName ?? 'Neuralwatt',
          apiKey: '',
          baseUrl: _defaultBase(key),
          providerType: ProviderKind.neuralwatt,
          chatPath: '/chat/completions',
          useResponseApi: false,
          models: const [],
          modelOverrides: const {},
          proxyEnabled: false,
          proxyHost: '',
          proxyPort: '8080',
          proxyUsername: '',
          proxyPassword: '',
          multiKeyEnabled: false,
          apiKeys: const [],
          keyManagement: const KeyManagementConfig(),
          aihubmixAppCodeEnabled: false,
          balanceEnabled: true,
          balanceApiPath: '/quota',
          balanceResultKey: 'balance.credits_remaining_usd',
          claudePromptCachingEnabled: false,
        );
      case ProviderKind.openai:
      default:
        // Special-case SiliconFlow: prefill two partnered models
        if (lowerKey.contains('silicon')) {
          return ProviderConfig(
            id: key,
            enabled: _defaultEnabled(key),
            name: displayName ?? key,
            apiKey: '',
            baseUrl: _defaultBase(key),
            providerType: ProviderKind.openai,
            chatPath: '/chat/completions',
            useResponseApi: false,
            models: const ['THUDM/GLM-4-9B-0414', 'Qwen/Qwen3-8B'],
            modelOverrides: const {
              'THUDM/GLM-4-9B-0414': {
                'type': 'chat',
                'input': ['text'],
                'output': ['text'],
                'abilities': ['tool'],
              },
              'Qwen/Qwen3-8B': {
                'type': 'chat',
                'input': ['text'],
                'output': ['text'],
                'abilities': ['tool', 'reasoning'],
              },
            },
            proxyEnabled: false,
            proxyHost: '',
            proxyPort: '8080',
            proxyUsername: '',
            proxyPassword: '',
            multiKeyEnabled: false,
            apiKeys: const [],
            keyManagement: const KeyManagementConfig(),
            aihubmixAppCodeEnabled: false,
            balanceEnabled: true,
            balanceApiPath: '/user/info',
            balanceResultKey: 'data.totalBalance',
            claudePromptCachingEnabled: false,
          );
        }
        return ProviderConfig(
          id: key,
          enabled: _defaultEnabled(key),
          name: displayName ?? key,
          apiKey: '',
          baseUrl: _defaultBase(key),
          providerType: ProviderKind.openai,
          chatPath: '/chat/completions',
          useResponseApi: false,
          models: const [],
          modelOverrides: const {},
          proxyEnabled: false,
          proxyHost: '',
          proxyPort: '8080',
          proxyUsername: '',
          proxyPassword: '',
          multiKeyEnabled: false,
          apiKeys: const [],
          keyManagement: const KeyManagementConfig(),
          aihubmixAppCodeEnabled: lowerKey.contains('aihubmix'),
          balanceEnabled:
              lowerKey.contains('aihubmix') ||
              lowerKey.contains('deepseek') ||
              lowerKey.contains('openrouter') ||
              lowerKey.contains('moonshot'),
          balanceApiPath: lowerKey.contains('openrouter')
              ? '/credits'
              : (lowerKey.contains('moonshot')
                    ? '/users/me/balance'
                    : (lowerKey.contains('deepseek')
                          ? '/user/balance'
                          : '/user/info')),
          balanceResultKey: lowerKey.contains('openrouter')
              ? 'data.total_credits - data.total_usage'
              : (lowerKey.contains('aihubmix') || lowerKey.contains('deepseek')
                    ? 'balance_infos[0].total_balance'
                    : 'data.available_balance'),
          claudePromptCachingEnabled: false,
        );
    }
  }
}
