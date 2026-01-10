// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appName => 'OmniChat';

  @override
  String get settingsPageTitle => 'Settings';

  @override
  String get settingsPageGeneralSection => 'General';

  @override
  String get settingsPageColorMode => 'Theme Mode';

  @override
  String get settingsPageDarkMode => 'Dark';

  @override
  String get settingsPageLightMode => 'Light';

  @override
  String get settingsPageSystemMode => 'System';

  @override
  String get settingsPageDisplay => 'Display Settings';

  @override
  String get settingsPageDisplayDescription => 'Customize UI and font';

  @override
  String get settingsPageAssistant => 'Assistant Settings';

  @override
  String get settingsPageAssistantDescription => 'Configure default parameters';

  @override
  String get settingsPageModelsServicesSection => 'Models & Services';

  @override
  String get settingsPageDefaultModel => 'Default Model';

  @override
  String get settingsPageDefaultModelDescription => 'Select global chat model';

  @override
  String get settingsPageProviders => 'Model Providers';

  @override
  String get settingsPageProvidersDescription => 'Manage API keys and models';

  @override
  String get settingsPageSearch => 'Search Services';

  @override
  String get settingsPageSearchDescription => 'Configure search engines';

  @override
  String get settingsPageTts => 'TTS Services';

  @override
  String get settingsPageTtsDescription => 'Text-to-Speech configuration';

  @override
  String get settingsPageMcp => 'MCP Server';

  @override
  String get settingsPageMcpDescription => 'Model Context Protocol';

  @override
  String get settingsPageQuickPhrase => 'Quick Phrases';

  @override
  String get settingsPageQuickPhraseDescription => 'Manage shortcuts';

  @override
  String get settingsPageInstructionInjection => 'Instruction Injection';

  @override
  String get settingsPageInstructionInjectionDescription => 'System prompts';

  @override
  String get settingsPageNetworkProxy => 'Network Proxy';

  @override
  String get settingsPageNetworkProxyDescription => 'Proxy configuration';

  @override
  String get settingsPageDataSection => 'Data';

  @override
  String get settingsPageBackup => 'Backup & Sync';

  @override
  String get settingsPageBackupDescription => 'Import/Export data';

  @override
  String get settingsPageChatStorage => 'Chat Storage';

  @override
  String get settingsPageChatStorageDescription => 'Manage space usage';

  @override
  String get settingsPageAboutSection => 'About';

  @override
  String get settingsPageAbout => 'About';

  @override
  String get settingsPageAboutDescription => 'Version info and more';

  @override
  String get settingsPageBackButton => 'Back';

  @override
  String get settingsPageWarningMessage =>
      'Please configure at least one model provider to start chatting.';

  @override
  String get settingsPageCalculating => 'Calculating...';

  @override
  String settingsPageFilesCount(int count, String size) {
    return '$count files, $size';
  }

  @override
  String get homePageNewChat => 'New Chat';

  @override
  String get homePageSettings => 'Settings';

  @override
  String get homePageCancel => 'Cancel';

  @override
  String get homePageConfirm => 'Confirm';

  @override
  String get homePageDelete => 'Delete';

  @override
  String get homePageEdit => 'Edit';

  @override
  String get homePageRetry => 'Retry';

  @override
  String get homePageCopy => 'Copy';

  @override
  String get homePageShare => 'Share';

  @override
  String get sidebarHistory => 'History';

  @override
  String get sidebarAssistants => 'Assistants';

  @override
  String get sidebarTopics => 'Topics';

  @override
  String get aboutPageVersion => 'Version';

  @override
  String get aboutPageSystem => 'System';

  @override
  String get aboutPageAppDescription =>
      'A cross-platform, multi-provider AI chat client.';

  @override
  String get aboutPageLicense => 'License';

  @override
  String get aboutPagePrivacyPolicy => 'Privacy Policy';

  @override
  String get aboutPageTermsOfService => 'Terms of Service';

  @override
  String get aboutPageEasterEggButton => 'Close';

  @override
  String get requestLogSettingTitle => 'Request Logs';

  @override
  String get requestLogSettingSubtitle => 'Log API requests for debugging';

  @override
  String get flutterLogSettingTitle => 'App Logs';

  @override
  String get flutterLogSettingSubtitle => 'Log application events';

  @override
  String get providersPageSiliconFlowName => 'SiliconFlow';

  @override
  String get providersPageAliyunName => 'Aliyun (DashScope)';

  @override
  String get providersPageZhipuName => 'Zhipu AI';

  @override
  String get providersPageByteDanceName => 'Doubao (ByteDance)';

  @override
  String get providerDetailPageApiBaseUrlLabel => 'API Base URL';

  @override
  String get providerDetailPageLocationLabel => 'Location';

  @override
  String get providerDetailPageProjectIdLabel => 'Project ID';

  @override
  String get providerDetailPageServiceAccountJsonLabel =>
      'Service Account JSON';

  @override
  String get providerDetailPageImportJsonButton => 'Import JSON File';

  @override
  String get providerDetailPageApiPathLabel => 'API Path';

  @override
  String get providerDetailPageBalanceEnabled => 'Enable Balance Check';

  @override
  String get providerDetailPageBalanceApiPath => 'Balance API Path';

  @override
  String get providerDetailPageBalanceResultKey => 'Balance Result Key';

  @override
  String get providerDetailPageModelsTitle => 'Models';

  @override
  String get providerDetailPageFilterHint => 'Filter models...';

  @override
  String get providerDetailPageUseStreamingLabel => 'Use Streaming';

  @override
  String get providerDetailPageBatchDetecting => 'Detecting...';

  @override
  String get providerDetailPageBatchDetectStart => 'Check Connectivity';

  @override
  String get providerDetailPageBatchDetectButton => 'Check';

  @override
  String get providerDetailPageTestButton => 'Test Connection';

  @override
  String get providerDetailPageAddNewModelButton => 'Add';

  @override
  String get providerDetailPageApiKeyHint => 'Enter API Key';

  @override
  String get providerDetailPageManageKeysButton => 'Manage Keys';

  @override
  String get providerDetailPageDeleteProviderTitle => 'Delete Provider';

  @override
  String get providerDetailPageDeleteProviderContent =>
      'Are you sure you want to delete this provider configuration?';

  @override
  String get providerDetailPageCancelButton => 'Cancel';

  @override
  String get providerDetailPageDeleteButton => 'Delete';

  @override
  String get multiKeyPageKey => 'API Key';

  @override
  String get addProviderSheetAddButton => 'Add Provider';

  @override
  String get desktopSidebarTabAssistants => 'Assistants';

  @override
  String get desktopSidebarTabTopics => 'Topics';

  @override
  String get desktopAssistantsListTitle => 'Assistants';

  @override
  String get desktopAvatarMenuUseEmoji => 'Use Emoji';

  @override
  String get desktopAvatarMenuChangeFromImage => 'Pick Image';

  @override
  String get desktopAvatarMenuReset => 'Reset Default';

  @override
  String get sideDrawerSearchHint => 'Search chats...';

  @override
  String get sideDrawerSearchAssistantsHint => 'Search assistants...';

  @override
  String get sideDrawerRenameHint => 'Enter new name';

  @override
  String get sideDrawerCancel => 'Cancel';

  @override
  String get sideDrawerOK => 'OK';

  @override
  String get sideDrawerSave => 'Save';

  @override
  String get sideDrawerMenuRename => 'Rename';

  @override
  String get sideDrawerMenuPin => 'Pin';

  @override
  String get sideDrawerMenuUnpin => 'Unpin';

  @override
  String get sideDrawerMenuRegenerateTitle => 'Regenerate Title';

  @override
  String get sideDrawerMenuMoveTo => 'Move to...';

  @override
  String get sideDrawerMenuDelete => 'Delete';

  @override
  String sideDrawerDeleteSnackbar(String title) {
    return 'Deleted \"$title\"';
  }

  @override
  String get sideDrawerGreetingMorning => 'Good morning';

  @override
  String get sideDrawerGreetingNoon => 'Good afternoon';

  @override
  String get sideDrawerGreetingAfternoon => 'Good afternoon';

  @override
  String get sideDrawerGreetingEvening => 'Good evening';

  @override
  String get sideDrawerDateToday => 'Today';

  @override
  String get sideDrawerDateYesterday => 'Yesterday';

  @override
  String get sideDrawerDateShortPattern => 'MM-dd';

  @override
  String get sideDrawerDateFullPattern => 'yyyy-MM-dd';

  @override
  String get sideDrawerPinnedLabel => 'Pinned';

  @override
  String get sideDrawerChooseImage => 'Choose Image';

  @override
  String get sideDrawerChooseEmoji => 'Choose Emoji';

  @override
  String get sideDrawerEnterLink => 'Enter Link';

  @override
  String get sideDrawerReset => 'Reset Default';

  @override
  String get sideDrawerEmojiDialogTitle => 'Pick an Emoji';

  @override
  String get sideDrawerEmojiDialogHint => 'Type an emoji...';

  @override
  String get sideDrawerImageUrlDialogTitle => 'Enter Image URL';

  @override
  String get sideDrawerImageUrlDialogHint => 'https://example.com/avatar.png';

  @override
  String get sideDrawerSetNicknameTitle => 'Set Nickname';

  @override
  String get sideDrawerNicknameLabel => 'Nickname';

  @override
  String get sideDrawerNicknameHint => 'Your display name';

  @override
  String get sideDrawerGalleryOpenError => 'Could not open gallery.';

  @override
  String get sideDrawerGeneralImageError => 'Failed to pick image.';

  @override
  String get sideDrawerLinkCopied => 'Link copied to clipboard';

  @override
  String sideDrawerUpdateTitle(String version) {
    return 'Update Available: $version';
  }

  @override
  String sideDrawerUpdateTitleWithBuild(String version, int build) {
    return 'Update Available: $version ($build)';
  }

  @override
  String get assistantEditPageTitle => 'Edit Assistant';

  @override
  String get assistantEditPageNotFound => 'Assistant not found';

  @override
  String get assistantEditPageBasicTab => 'Basic';

  @override
  String get assistantEditPagePromptsTab => 'Prompts';

  @override
  String get assistantEditPageMemoryTab => 'Memory';

  @override
  String get assistantEditPageMcpTab => 'MCP';

  @override
  String get assistantEditPageQuickPhraseTab => 'Phrases';

  @override
  String get assistantEditPageCustomTab => 'Custom';

  @override
  String get assistantEditPageRegexTab => 'Regex';

  @override
  String get assistantEditMemoryDialogTitle => 'Edit Memory';

  @override
  String get assistantEditMemoryDialogHint => 'Enter memory content...';

  @override
  String get assistantEditEmojiDialogCancel => 'Cancel';

  @override
  String get assistantEditEmojiDialogSave => 'Save';

  @override
  String get assistantEditMemorySwitchTitle => 'Enable Memory';

  @override
  String get assistantEditRecentChatsSwitchTitle => 'Include Recent Chats';

  @override
  String get assistantEditManageMemoryTitle => 'Manage Memories';

  @override
  String get assistantEditAddMemoryButton => 'Add';

  @override
  String get assistantEditMemoryEmpty => 'No memories yet.';

  @override
  String get assistantEditManageSummariesTitle => 'Conversation Summaries';

  @override
  String get assistantEditSummaryEmpty => 'No summaries available.';

  @override
  String get assistantEditDeleteSummaryTitle => 'Delete Summary';

  @override
  String get assistantEditDeleteSummaryContent =>
      'Are you sure you want to delete this summary?';

  @override
  String get assistantEditClearButton => 'Clear';

  @override
  String get assistantEditSummaryDialogTitle => 'Edit Summary';

  @override
  String get assistantEditSummaryDialogHint => 'Enter summary...';

  @override
  String get assistantEditCustomHeadersTitle => 'Custom Headers';

  @override
  String get assistantEditCustomHeadersAdd => 'Add';

  @override
  String get assistantEditCustomHeadersEmpty => 'No custom headers.';

  @override
  String get assistantEditCustomBodyTitle => 'Custom Body';

  @override
  String get assistantEditCustomBodyAdd => 'Add';

  @override
  String get assistantEditCustomBodyEmpty => 'No custom body fields.';

  @override
  String get assistantEditHeaderNameLabel => 'Header Name';

  @override
  String get assistantEditHeaderValueLabel => 'Value';

  @override
  String get assistantEditBodyKeyLabel => 'Key';

  @override
  String get assistantEditBodyValueLabel => 'Value';

  @override
  String get assistantEditAssistantNameLabel => 'Assistant Name';

  @override
  String get assistantEditContextMessagesTitle => 'Context Messages';

  @override
  String get assistantEditContextMessagesDescription =>
      'Number of previous messages to include';

  @override
  String get assistantEditThinkingBudgetTitle => 'Thinking Budget';

  @override
  String get assistantEditMaxTokensTitle => 'Max Tokens';

  @override
  String get assistantEditMaxTokensHint => 'Unlimited';

  @override
  String get assistantEditUseAssistantAvatarTitle => 'Use Assistant Avatar';

  @override
  String get assistantEditStreamOutputTitle => 'Stream Output';

  @override
  String get assistantEditChatModelTitle => 'Chat Model';

  @override
  String get assistantEditChatModelSubtitle => 'Override default model';

  @override
  String get assistantEditModelUseGlobalDefault => 'Use Global Default';

  @override
  String get assistantEditChatBackgroundTitle => 'Chat Background';

  @override
  String get assistantEditChatBackgroundDescription =>
      'Set a custom background for this assistant';

  @override
  String get assistantEditChooseImageButton => 'Choose Image';

  @override
  String get assistantEditAvatarChooseImage => 'Local Image';

  @override
  String get assistantEditAvatarChooseEmoji => 'Emoji';

  @override
  String get assistantEditAvatarEnterLink => 'Image URL';

  @override
  String get assistantEditAvatarReset => 'Reset to Default';

  @override
  String get assistantEditImageUrlDialogTitle => 'Image URL';

  @override
  String get assistantEditImageUrlDialogHint => 'Enter image link';

  @override
  String get assistantEditParameterDisabled => 'Not set';

  @override
  String get assistantEditParameterDisabled2 => 'Default';

  @override
  String get assistantTagsContextMenuEditAssistant => 'Edit Assistant';

  @override
  String get assistantTagsClearTag => 'Clear Tag';

  @override
  String get assistantTagsContextMenuManageTags => 'Manage Tags';

  @override
  String get assistantTagsContextMenuDeleteAssistant => 'Delete Assistant';

  @override
  String get assistantSettingsDeleteDialogTitle => 'Delete Assistant';

  @override
  String get assistantSettingsDeleteDialogContent =>
      'Are you sure? This will delete the assistant and its settings.';

  @override
  String get assistantSettingsDeleteDialogCancel => 'Cancel';

  @override
  String get assistantSettingsDeleteDialogConfirm => 'Delete';

  @override
  String get assistantSettingsAtLeastOneAssistantRequired =>
      'Cannot delete the last assistant.';

  @override
  String get assistantSettingsCopySuccess => 'Assistant copied successfully';

  @override
  String get assistantSettingsNoPromptPlaceholder => 'No system prompt set';

  @override
  String get assistantSettingsAddSheetTitle => 'New Assistant';

  @override
  String get assistantSettingsAddSheetHint => 'Name';

  @override
  String get assistantSettingsAddSheetCancel => 'Cancel';

  @override
  String get assistantSettingsAddSheetSave => 'Create';

  @override
  String get assistantSettingsDefaultTag => 'Default';

  @override
  String get backupPageUsername => 'Username';

  @override
  String get androidBackgroundNotificationTitle => 'OmniChat is running';

  @override
  String get androidBackgroundNotificationText =>
      'Keeping chat alive in background';

  @override
  String get chatServiceDefaultConversationTitle => 'New Chat';

  @override
  String get userProviderDefaultUserName => 'User';

  @override
  String get homePageDropToUpload => 'Drop files to upload';

  @override
  String get homePageDeleteMessage => 'Delete Message';

  @override
  String get homePageDeleteMessageConfirm => 'Delete this message?';

  @override
  String get desktopTrayMenuShowWindow => 'Show Window';

  @override
  String get desktopTrayMenuExit => 'Exit';

  @override
  String get assistantProviderDefaultAssistantName => 'Default Assistant';

  @override
  String get assistantProviderSampleAssistantName => 'Sample Assistant';

  @override
  String assistantProviderSampleAssistantSystemPrompt(
    String model_name,
    String cur_datetime,
    String locale,
    String timezone,
    String device_info,
    String system_version,
  ) {
    return 'You are $model_name, a helpful AI. Time: $cur_datetime';
  }

  @override
  String get assistantSettingsCopySuffix => 'Copy';

  @override
  String get assistantProviderNewAssistantName => 'New Assistant';

  @override
  String get searchSettingsSheetBuiltinSearchTitle => 'Built-in Search';

  @override
  String get reasoningBudgetSheetOff => 'Off';

  @override
  String get reasoningBudgetSheetAuto => 'Auto';

  @override
  String get reasoningBudgetSheetLight => 'Light';

  @override
  String get reasoningBudgetSheetMedium => 'Medium';

  @override
  String get reasoningBudgetSheetHeavy => 'Heavy';

  @override
  String get instructionInjectionDefaultTitle => 'Default';

  @override
  String get bottomToolsSheetCamera => 'Camera';

  @override
  String get bottomToolsSheetPhotos => 'Photos';

  @override
  String get bottomToolsSheetUpload => 'Upload';

  @override
  String get instructionInjectionTitle => 'Instruction Injection';

  @override
  String get bottomToolsSheetOcr => 'OCR';

  @override
  String get bottomToolsSheetClearContext => 'Clear Context';

  @override
  String get instructionInjectionEditTitle => 'Edit';

  @override
  String get instructionInjectionNameLabel => 'Name';

  @override
  String get instructionInjectionPromptLabel => 'Prompt';

  @override
  String get quickPhraseCancelButton => 'Cancel';

  @override
  String get quickPhraseSaveButton => 'Save';

  @override
  String get searchServicesPageConfiguredStatus => 'Configured';

  @override
  String get searchServicesPageApiKeyRequiredStatus => 'API Key Required';

  @override
  String get searchServicesPageUrlRequiredStatus => 'URL Required';

  @override
  String get searchSettingsSheetTitle => 'Search Settings';

  @override
  String get searchSettingsSheetWebSearchTitle => 'Web Search';

  @override
  String get searchSettingsSheetOpenSearchServicesTooltip => 'Open Services';

  @override
  String get searchSettingsSheetNoServicesMessage => 'No services added';

  @override
  String get modelSelectSheetSearchHint => 'Search models';

  @override
  String get modelSelectSheetFavoritesSection => 'Favorites';

  @override
  String get modelSelectSheetFavoriteTooltip => 'Favorite';

  @override
  String get modelSelectSheetChatType => 'Chat';

  @override
  String get modelSelectSheetEmbeddingType => 'Embedding';

  @override
  String get mcpPageErrorDialogTitle => 'MCP Error';

  @override
  String get mcpPageErrorNoDetails => 'No details';

  @override
  String get mcpPageClose => 'Close';

  @override
  String get mcpPageReconnect => 'Reconnect';

  @override
  String get mcpPageBackTooltip => 'Back';

  @override
  String get mcpTimeoutSettingsTooltip => 'Timeout';

  @override
  String get mcpJsonEditButtonTooltip => 'Edit JSON';

  @override
  String get mcpPageAddMcpTooltip => 'Add MCP';

  @override
  String get mcpPageNoServers => 'No servers';

  @override
  String get mcpPageStatusConnected => 'Connected';

  @override
  String get mcpPageStatusConnecting => 'Connecting';

  @override
  String get mcpPageStatusDisconnected => 'Disconnected';

  @override
  String get mcpTransportTagInmemory => 'Built-in';

  @override
  String mcpPageToolsCount(int enabled, int total) {
    return '$enabled/$total tools';
  }

  @override
  String get mcpPageStatusDisabled => 'Disabled';

  @override
  String get mcpPageConnectionFailed => 'Failed';

  @override
  String get mcpPageDetails => 'Details';

  @override
  String get mcpPageDelete => 'Delete';

  @override
  String get mcpPageConfirmDeleteTitle => 'Delete Server';

  @override
  String get mcpPageConfirmDeleteContent => 'Are you sure?';

  @override
  String get mcpPageCancel => 'Cancel';

  @override
  String get mcpPageServerDeleted => 'Deleted';

  @override
  String get mcpPageUndo => 'Undo';

  @override
  String get providersPageTitle => 'Providers';

  @override
  String get searchServicesPageDone => 'Done';

  @override
  String get providersPageMultiSelectTooltip => 'Select';

  @override
  String get providersPageImportTooltip => 'Import';

  @override
  String get providersPageAddTooltip => 'Add';

  @override
  String get providersPageProviderAddedSnackbar => 'Provider added';

  @override
  String get providersPageDeleteSelectedConfirmContent => 'Delete selected?';

  @override
  String get providersPageDeleteSelectedSnackbar => 'Deleted';

  @override
  String get providersPageEnabledStatus => 'Enabled';

  @override
  String get providersPageDisabledStatus => 'Disabled';

  @override
  String get providersPageDeleteAction => 'Delete';

  @override
  String get providersPageExportAction => 'Export';

  @override
  String providersPageExportSelectedTitle(int count) {
    return 'Export $count items';
  }

  @override
  String get providersPageExportCopyButton => 'Copy';

  @override
  String get providersPageExportCopiedSnackbar => 'Copied';

  @override
  String get providersPageExportShareButton => 'Share';

  @override
  String get mcpAssistantSheetTitle => 'MCP Assistant';

  @override
  String get assistantEditMcpNoServersMessage => 'No servers';

  @override
  String assistantEditMcpToolsCountTag(String enabled, String total) {
    return '$enabled/$total';
  }

  @override
  String get quickPhraseBackTooltip => 'Back';

  @override
  String get quickPhraseGlobalTitle => 'Phrases';

  @override
  String get quickPhraseAssistantTitle => 'Assistant Phrases';

  @override
  String get quickPhraseAddTooltip => 'Add';

  @override
  String get quickPhraseEmptyMessage => 'No phrases';

  @override
  String get quickPhraseDeleteButton => 'Delete';

  @override
  String get quickPhraseAddTitle => 'Add Phrase';

  @override
  String get quickPhraseEditTitle => 'Edit Phrase';

  @override
  String get quickPhraseTitleLabel => 'Title';

  @override
  String get quickPhraseContentLabel => 'Content';

  @override
  String get chatInputBarHint => 'Type a message';

  @override
  String get chatInputBarInsertNewline => 'Newline';

  @override
  String get chatInputBarSelectModelTooltip => 'Select Model';

  @override
  String get chatInputBarOnlineSearchTooltip => 'Online Search';

  @override
  String get chatInputBarReasoningStrengthTooltip => 'Reasoning';

  @override
  String get chatInputBarMcpServersTooltip => 'MCP';

  @override
  String get chatInputBarQuickPhraseTooltip => 'Phrases';

  @override
  String get miniMapTooltip => 'Minimap';

  @override
  String get chatInputBarOcrTooltip => 'OCR';

  @override
  String get chatInputBarMoreTooltip => 'More';

  @override
  String get miniMapTitle => 'Minimap';

  @override
  String get instructionInjectionSheetSubtitle => 'Select prompt';

  @override
  String get instructionInjectionEmptyMessage => 'Empty';

  @override
  String get bottomToolsSheetPrompt => 'Prompt';

  @override
  String get bottomToolsSheetPromptHint => 'Enter prompt';

  @override
  String get bottomToolsSheetSave => 'Save';

  @override
  String get homePageDone => 'Done';

  @override
  String get homePageClearContext => 'Clear Context';

  @override
  String get generationInterrupted => 'Interrupted';

  @override
  String get homePagePleaseSelectModel => 'Select model';

  @override
  String get homePageTranslating => 'Translating';

  @override
  String get homePagePleaseSetupTranslateModel => 'Set translation model';

  @override
  String homePageTranslateFailed(String error) {
    return 'Failed: $error';
  }

  @override
  String get desktopTtsPleaseAddProvider => 'Add TTS provider';

  @override
  String get homePageSelectMessagesToShare => 'Select messages';

  @override
  String homePageClearContextWithCount(String actual, String configured) {
    return 'Clear ($actual/$configured)';
  }

  @override
  String get titleForLocale => 'New Chat';

  @override
  String get homePageDefaultAssistant => 'Assistant';

  @override
  String get voiceChatButtonTooltip => 'Voice';

  @override
  String get voiceChatErrorInitFailed => 'Init failed';

  @override
  String voiceChatError(String error) {
    return 'Error: $error';
  }

  @override
  String get voiceChatProcessing => 'Thinking';

  @override
  String voiceChatErrorApi(String error) {
    return 'API: $error';
  }

  @override
  String voiceChatErrorProcessingResponse(String error) {
    return 'Parse error: $error';
  }

  @override
  String voiceChatErrorTts(String error) {
    return 'TTS: $error';
  }

  @override
  String get voiceChatErrorNoModel => 'No model';

  @override
  String get voiceChatErrorNoConversation => 'No chat';

  @override
  String get voiceChatErrorNoActiveConversation => 'Inactive';

  @override
  String get voiceChatTitle => 'Voice';

  @override
  String get voiceChatPermissionRequired => 'Permission Required';

  @override
  String get voiceChatPermissionSubtitle => 'Microphone access needed';

  @override
  String get voiceChatPermissionButton => 'Grant';

  @override
  String get voiceChatListening => 'Listening';

  @override
  String get voiceChatThinking => 'Thinking';

  @override
  String get voiceChatTalking => 'Talking';

  @override
  String get defaultModelPagePromptLabel => 'Prompt';

  @override
  String get defaultModelPageOcrPromptHint => 'OCR Prompt';

  @override
  String get defaultModelPageResetDefault => 'Reset';

  @override
  String get defaultModelPageSave => 'Save';

  @override
  String get searchServicesPageBackTooltip => 'Back';

  @override
  String get searchServicesPageTitle => 'Search';

  @override
  String get searchServicesPageAddProvider => 'Add';

  @override
  String get searchServicesPageSearchProviders => 'Providers';

  @override
  String get searchServicesPageGeneralOptions => 'General';

  @override
  String get searchServicesPageAutoTestTitle => 'Auto test';

  @override
  String get searchServicesPageMaxResults => 'Max results';

  @override
  String get searchServicesPageTimeoutSeconds => 'Timeout';

  @override
  String get searchServicesPageTestingStatus => 'Testing';

  @override
  String get searchServicesPageConnectedStatus => 'Connected';

  @override
  String get searchServicesPageFailedStatus => 'Failed';

  @override
  String get searchServicesPageNotTestedStatus => 'Not tested';

  @override
  String get searchServicesPageTestConnectionTooltip => 'Test';

  @override
  String get searchServicesAddDialogTitle => 'Add';

  @override
  String get searchServiceNameBingLocal => 'Bing';

  @override
  String get searchServiceNameDuckDuckGo => 'DuckDuckGo';

  @override
  String get searchServiceNameTavily => 'Tavily';

  @override
  String get searchServiceNameExa => 'Exa';

  @override
  String get searchServiceNameZhipu => 'Zhipu';

  @override
  String get searchServiceNameSearXNG => 'SearXNG';

  @override
  String get searchServiceNameLinkUp => 'LinkUp';

  @override
  String get searchServiceNameBrave => 'Brave';

  @override
  String get searchServiceNameMetaso => 'Metaso';

  @override
  String get searchServiceNameJina => 'Jina';

  @override
  String get searchServiceNameOllama => 'Ollama';

  @override
  String get searchServiceNamePerplexity => 'Perplexity';

  @override
  String get searchServiceNameBocha => 'Bocha';

  @override
  String get searchServicesAddDialogAdd => 'Add';

  @override
  String get searchServicesAddDialogRegionOptional => 'Region';

  @override
  String get searchServicesAddDialogApiKeyRequired => 'Key required';

  @override
  String get searchServicesAddDialogInstanceUrl => 'URL';

  @override
  String get searchServicesAddDialogUrlRequired => 'URL required';

  @override
  String get searchServicesAddDialogEnginesOptional => 'Engines';

  @override
  String get searchServicesAddDialogLanguageOptional => 'Language';

  @override
  String get searchServicesAddDialogUsernameOptional => 'Username';

  @override
  String get searchServicesAddDialogPasswordOptional => 'Password';

  @override
  String get searchServicesEditDialogSave => 'Save';

  @override
  String get searchServicesEditDialogBingLocalNoConfig => 'No config needed';

  @override
  String get searchServicesEditDialogRegionOptional => 'Region';

  @override
  String get searchServicesEditDialogApiKeyRequired => 'Key required';

  @override
  String get searchServicesEditDialogInstanceUrl => 'URL';

  @override
  String get searchServicesEditDialogUrlRequired => 'URL required';

  @override
  String get searchServicesEditDialogEnginesOptional => 'Engines';

  @override
  String get searchServicesEditDialogLanguageOptional => 'Language';

  @override
  String get searchServicesEditDialogUsernameOptional => 'Username';

  @override
  String get searchServicesEditDialogPasswordOptional => 'Password';

  @override
  String get modelDetailSheetCancelButton => 'Cancel';

  @override
  String get modelDetailSheetAddModel => 'Add';

  @override
  String get modelDetailSheetEditModel => 'Edit';

  @override
  String get modelDetailSheetBasicTab => 'Basic';

  @override
  String get modelDetailSheetAdvancedTab => 'Advanced';

  @override
  String get modelDetailSheetBuiltinToolsTab => 'Tools';

  @override
  String get modelDetailSheetModelIdLabel => 'ID';

  @override
  String get modelDetailSheetModelIdHint => 'Model ID';

  @override
  String get shareProviderSheetCopyButton => 'Copy';

  @override
  String get shareProviderSheetCopiedMessage => 'Copied';

  @override
  String get modelDetailSheetModelNameLabel => 'Name';

  @override
  String get modelDetailSheetModelTypeLabel => 'Type';

  @override
  String get modelDetailSheetInputModesLabel => 'Input';

  @override
  String get modelDetailSheetTextMode => 'Text';

  @override
  String get modelDetailSheetImageMode => 'Image';

  @override
  String get modelDetailSheetOutputModesLabel => 'Output';

  @override
  String get modelDetailSheetAbilitiesLabel => 'Abilities';

  @override
  String get modelDetailSheetToolsAbility => 'Tools';

  @override
  String get modelDetailSheetReasoningAbility => 'Reasoning';

  @override
  String get modelDetailSheetProviderOverrideDescription => 'Overrides';

  @override
  String get modelDetailSheetAddProviderOverride => 'Add Override';

  @override
  String get modelDetailSheetCustomHeadersTitle => 'Headers';

  @override
  String get modelDetailSheetAddHeader => 'Add';

  @override
  String get modelDetailSheetCustomBodyTitle => 'Body';

  @override
  String get modelDetailSheetAddBody => 'Add';

  @override
  String get modelDetailSheetBuiltinToolsDescription => 'Built-in';

  @override
  String get modelDetailSheetGeminiCodeExecutionMutuallyExclusiveHint =>
      'Exclusive';

  @override
  String get modelDetailSheetUrlContextTool => 'URL';

  @override
  String get modelDetailSheetUrlContextToolDescription => 'URL Context';

  @override
  String get modelDetailSheetCodeExecutionTool => 'Code';

  @override
  String get modelDetailSheetCodeExecutionToolDescription => 'Execute code';

  @override
  String get modelDetailSheetYoutubeTool => 'YouTube';

  @override
  String get modelDetailSheetYoutubeToolDescription => 'Video context';

  @override
  String get modelDetailSheetOpenaiBuiltinToolsResponsesOnlyHint =>
      'OpenAI only';

  @override
  String get modelDetailSheetOpenaiCodeInterpreterTool => 'Interpreter';

  @override
  String get modelDetailSheetOpenaiCodeInterpreterToolDescription =>
      'Code interpreter';

  @override
  String get modelDetailSheetOpenaiImageGenerationTool => 'Image';

  @override
  String get modelDetailSheetOpenaiImageGenerationToolDescription => 'DALL-E';

  @override
  String get modelDetailSheetBuiltinToolsUnsupportedHint => 'Unsupported';

  @override
  String get modelDetailSheetAddButton => 'Add';

  @override
  String get modelDetailSheetConfirmButton => 'Save';

  @override
  String get modelDetailSheetInvalidIdError => 'Invalid ID';

  @override
  String get modelDetailSheetHeaderKeyHint => 'Key';

  @override
  String get modelDetailSheetHeaderValueHint => 'Value';

  @override
  String get modelDetailSheetBodyKeyHint => 'Key';

  @override
  String get modelDetailSheetBodyJsonHint => 'JSON';

  @override
  String get providerDetailPageShareTooltip => 'Share';

  @override
  String get providerDetailPageDeleteProviderTooltip => 'Delete';

  @override
  String get providerDetailPageProviderDeletedSnackbar => 'Deleted';

  @override
  String get providerDetailPageConfigTab => 'Config';

  @override
  String get providerDetailPageModelsTab => 'Models';

  @override
  String get providerDetailPageNetworkTab => 'Network';

  @override
  String get providerDetailPageEnabledTitle => 'Enabled';

  @override
  String get providerDetailPageManageSectionTitle => 'Manage';

  @override
  String get providerDetailPageNameLabel => 'Name';

  @override
  String get providerDetailPageHideTooltip => 'Hide';

  @override
  String get providerDetailPageShowTooltip => 'Show';

  @override
  String get providerDetailPageProviderRemovedMessage => 'Removed';

  @override
  String get providerDetailPageNoModelsTitle => 'No models';

  @override
  String get providerDetailPageNoModelsSubtitle => 'Add models below';

  @override
  String get providerDetailPageDeleteModelButton => 'Delete';

  @override
  String get providerDetailPageConfirmDeleteTitle => 'Confirm';

  @override
  String get providerDetailPageConfirmDeleteContent => 'Delete?';

  @override
  String get providerDetailPageModelDeletedSnackbar => 'Deleted';

  @override
  String get providerDetailPageUndoButton => 'Undo';

  @override
  String get providerDetailPageFetchModelsButton => 'Fetch';

  @override
  String get providerDetailPageEnableProxyTitle => 'Proxy';

  @override
  String get providerDetailPageHostLabel => 'Host';

  @override
  String get providerDetailPagePortLabel => 'Port';

  @override
  String get providerDetailPageUsernameOptionalLabel => 'User';

  @override
  String get providerDetailPagePasswordOptionalLabel => 'Pass';

  @override
  String get providerDetailPageEmbeddingsGroupTitle => 'Embeddings';

  @override
  String get providerDetailPageOtherModelsGroupTitle => 'Other';

  @override
  String get mcpAssistantSheetClearAll => 'Clear';

  @override
  String get mcpAssistantSheetSelectAll => 'All';

  @override
  String get modelFetchInvertTooltip => 'Invert';

  @override
  String get providerDetailPageRemoveGroupTooltip => 'Remove';

  @override
  String get providerDetailPageAddGroupTooltip => 'Add';

  @override
  String get providerDetailPageDeleteText => 'Delete';

  @override
  String get providerDetailPageDetectSuccess => 'Success';

  @override
  String get providerDetailPageDetectFailed => 'Failed';

  @override
  String get providerDetailPageEditTooltip => 'Edit';

  @override
  String get providerDetailPageTestConnectionTitle => 'Test';

  @override
  String get providerDetailPageTestSuccessMessage => 'OK';

  @override
  String get providerDetailPageSelectModelButton => 'Select';

  @override
  String get providerDetailPageChangeButton => 'Change';

  @override
  String get providerDetailPageTestingMessage => 'Testing';

  @override
  String get mcpServerEditSheetEnabledLabel => 'Enabled';

  @override
  String get mcpServerEditSheetNameLabel => 'Name';

  @override
  String get mcpServerEditSheetTransportLabel => 'Transport';

  @override
  String get mcpServerEditSheetSseRetryHint => 'Retry SSE';

  @override
  String get mcpServerEditSheetUrlLabel => 'URL';

  @override
  String get mcpServerEditSheetCustomHeadersTitle => 'Headers';

  @override
  String get mcpServerEditSheetHeaderNameLabel => 'Key';

  @override
  String get mcpServerEditSheetHeaderNameHint => 'Name';

  @override
  String get mcpServerEditSheetHeaderValueLabel => 'Value';

  @override
  String get mcpServerEditSheetHeaderValueHint => 'Value';

  @override
  String get mcpServerEditSheetRemoveHeaderTooltip => 'Remove';

  @override
  String get mcpServerEditSheetAddHeader => 'Add';

  @override
  String get mcpServerEditSheetUrlRequired => 'URL required';

  @override
  String get mcpServerEditSheetTitleEdit => 'Edit';

  @override
  String get mcpServerEditSheetTitleAdd => 'Add';

  @override
  String get mcpServerEditSheetSyncToolsTooltip => 'Sync';

  @override
  String get mcpServerEditSheetTabBasic => 'Basic';

  @override
  String get mcpServerEditSheetTabTools => 'Tools';

  @override
  String get mcpServerEditSheetNoToolsHint => 'No tools';

  @override
  String get mcpServerEditSheetSave => 'Save';

  @override
  String get mcpJsonEditParseFailed => 'Invalid JSON';

  @override
  String get mcpJsonEditSavedApplied => 'Applied';

  @override
  String get mcpJsonEditTitle => 'Edit JSON';

  @override
  String get mcpTimeoutInvalid => 'Invalid';

  @override
  String get mcpTimeoutDialogTitle => 'Timeout';

  @override
  String get mcpTimeoutSecondsLabel => 'Seconds';

  @override
  String get importProviderSheetTitle => 'Import';

  @override
  String get importProviderSheetScanQrTooltip => 'Scan';

  @override
  String importProviderSheetImportSuccessMessage(int count) {
    return 'Imported $count';
  }

  @override
  String importProviderSheetImportFailedMessage(String error) {
    return 'Failed: $error';
  }

  @override
  String get importProviderSheetFromGalleryTooltip => 'Gallery';

  @override
  String get importProviderSheetDescription => 'Paste code';

  @override
  String get importProviderSheetImportButton => 'Import';

  @override
  String get addProviderSheetEnabledLabel => 'Enabled';

  @override
  String get addProviderSheetNameLabel => 'Name';

  @override
  String get addProviderSheetApiPathLabel => 'Path';

  @override
  String get addProviderSheetVertexAiLocationLabel => 'Location';

  @override
  String get addProviderSheetVertexAiProjectIdLabel => 'Project';

  @override
  String get addProviderSheetVertexAiServiceAccountJsonLabel => 'JSON';

  @override
  String get addProviderSheetImportJsonButton => 'Import';

  @override
  String get addProviderSheetTitle => 'Add';

  @override
  String get shareProviderSheetTitle => 'Share';

  @override
  String get shareProviderSheetDescription => 'Provider info';

  @override
  String get chatMessageWidgetCopiedToClipboard => 'Copied';

  @override
  String get messageMoreSheetEdit => 'Edit';

  @override
  String get messageMoreSheetDelete => 'Delete';

  @override
  String chatMessageWidgetFileNotFound(String fileName) {
    return 'Not found: $fileName';
  }

  @override
  String chatMessageWidgetCannotOpenFile(String message) {
    return 'Error: $message';
  }

  @override
  String chatMessageWidgetOpenFileError(String error) {
    return 'Error: $error';
  }

  @override
  String get chatMessageWidgetThinking => 'Thinking';

  @override
  String get chatMessageWidgetTranslation => 'Translation';

  @override
  String get chatMessageWidgetCitationNotFound => 'Not found';

  @override
  String chatMessageWidgetCannotOpenUrl(String url) {
    return 'Error: $url';
  }

  @override
  String get chatMessageWidgetOpenLinkError => 'Error';

  @override
  String chatMessageWidgetCitationsTitle(int count) {
    return '$count Citations';
  }

  @override
  String get chatMessageWidgetCreateMemory => 'Remember';

  @override
  String get chatMessageWidgetEditMemory => 'Edit';

  @override
  String get chatMessageWidgetDeleteMemory => 'Forget';

  @override
  String chatMessageWidgetWebSearch(String query) {
    return 'Search: $query';
  }

  @override
  String get chatMessageWidgetBuiltinSearch => 'Search';

  @override
  String chatMessageWidgetToolResult(String name) {
    return 'Result: $name';
  }

  @override
  String chatMessageWidgetToolCall(String name) {
    return 'Call: $name';
  }

  @override
  String get chatMessageWidgetNoResultYet => 'Waiting';

  @override
  String get chatMessageWidgetArguments => 'Args';

  @override
  String get chatMessageWidgetResult => 'Result';

  @override
  String chatMessageWidgetCitationsCount(int count) {
    return '$count citations';
  }

  @override
  String get chatMessageWidgetDeepThinking => 'Deep thinking';

  @override
  String get messageMoreSheetSelectCopy => 'Select';

  @override
  String get messageMoreSheetRenderWebView => 'Web';

  @override
  String get messageMoreSheetShare => 'Share';

  @override
  String get messageMoreSheetCreateBranch => 'Branch';

  @override
  String get messageEditPageTitle => 'Edit';

  @override
  String get messageEditPageHint => 'Message';

  @override
  String get messageExportSheetDateTimeWithSecondsPattern =>
      'yyyy-MM-dd HH:mm:ss';

  @override
  String get backupPageExportToFile => 'Export';

  @override
  String get messageExportSheetMarkdown => 'Markdown';

  @override
  String get messageExportSheetSingleMarkdownSubtitle => 'Export Markdown';

  @override
  String get messageExportSheetPlainText => 'Text';

  @override
  String get messageExportSheetSingleTxtSubtitle => 'Export TXT';

  @override
  String get messageExportSheetExportImage => 'Image';

  @override
  String get messageExportSheetSingleExportImageSubtitle => 'Export Image';

  @override
  String get messageExportSheetShowThinkingAndToolCards => 'Show tools';

  @override
  String get messageExportSheetShowThinkingContent => 'Show thinking';

  @override
  String get messageExportSheetBatchMarkdownSubtitle => 'Batch Markdown';

  @override
  String get messageExportSheetBatchTxtSubtitle => 'Batch TXT';

  @override
  String get messageExportSheetBatchExportImageSubtitle => 'Batch Image';

  @override
  String get exportDisclaimerAiGenerated => 'AI Generated';

  @override
  String get messageExportSheetExporting => 'Exporting';

  @override
  String get messageEditDialogTitle => 'Edit Message';

  @override
  String get cameraPermissionDeniedMessage => 'No camera access';

  @override
  String get openSystemSettings => 'Settings';

  @override
  String get searchProviderBingLocalDescription => 'Bing search';

  @override
  String get searchProviderTavilyDescription => 'Tavily search';

  @override
  String get searchProviderExaDescription => 'Exa search';

  @override
  String get searchProviderZhipuDescription => 'Zhipu search';

  @override
  String get searchProviderSearXNGDescription => 'SearXNG search';

  @override
  String get searchProviderLinkUpDescription => 'LinkUp search';

  @override
  String get searchProviderBraveDescription => 'Brave search';

  @override
  String get searchProviderMetasoDescription => 'Metaso search';

  @override
  String get searchProviderOllamaDescription => 'Ollama search';

  @override
  String get searchProviderJinaDescription => 'Jina search';

  @override
  String get searchProviderBochaDescription => 'Bocha search';

  @override
  String get searchProviderPerplexityDescription => 'Perplexity search';

  @override
  String get searchProviderDuckDuckGoDescription => 'DuckDuckGo search';

  @override
  String get selectCopyPageCopiedAll => 'Copied';

  @override
  String get selectCopyPageCopyAll => 'All';

  @override
  String get selectCopyPageTitle => 'Select';

  @override
  String get messageWebViewRefreshTooltip => 'Refresh';

  @override
  String get messageWebViewForwardTooltip => 'Forward';

  @override
  String get messageWebViewOpenInBrowser => 'Open';

  @override
  String get messageWebViewConsoleLogs => 'Console';

  @override
  String get messageWebViewNoConsoleMessages => 'Empty';

  @override
  String get assistantEditPreviewTitle => 'Preview';

  @override
  String get imagePreviewSheetSaveSuccess => 'Saved';

  @override
  String imagePreviewSheetSaveFailed(String error) {
    return 'Failed: $error';
  }

  @override
  String get settingsPageShare => 'Share';

  @override
  String get imagePreviewSheetSaveImage => 'Save';

  @override
  String get languageDisplayTraditionalChinese => 'Traditional Chinese';

  @override
  String get languageDisplaySimplifiedChinese => 'Simplified Chinese';

  @override
  String get languageDisplayEnglish => 'English';

  @override
  String get languageDisplayJapanese => 'Japanese';

  @override
  String get languageDisplayKorean => 'Korean';

  @override
  String get languageDisplayFrench => 'French';

  @override
  String get languageDisplayGerman => 'German';

  @override
  String get languageDisplayItalian => 'Italian';

  @override
  String get languageDisplaySpanish => 'Spanish';

  @override
  String get languageSelectSheetClearButton => 'Clear';

  @override
  String get storageSpaceCategoryImages => 'Images';

  @override
  String get storageSpaceCategoryFiles => 'Files';

  @override
  String get storageSpaceCategoryChatData => 'Chat Data';

  @override
  String get storageSpaceCategoryAssistantData => 'Assistants';

  @override
  String get storageSpaceCategoryCache => 'Cache';

  @override
  String get storageSpaceCategoryLogs => 'Logs';

  @override
  String get storageSpaceCategoryOther => 'Other';

  @override
  String get storageSpaceSubChatMessages => 'Messages';

  @override
  String get storageSpaceSubChatConversations => 'Conversations';

  @override
  String get storageSpaceSubChatToolEvents => 'Tools';

  @override
  String get storageSpaceSubAssistantAvatars => 'Avatars';

  @override
  String get storageSpaceSubAssistantImages => 'Images';

  @override
  String get storageSpaceSubCacheAvatars => 'Avatar cache';

  @override
  String get storageSpaceSubCacheOther => 'Other cache';

  @override
  String get storageSpaceSubCacheSystem => 'System cache';

  @override
  String get storageSpaceSubLogsFlutter => 'Flutter logs';

  @override
  String get storageSpaceSubLogsRequests => 'API logs';

  @override
  String get storageSpaceSubLogsOther => 'Other logs';

  @override
  String get storageSpaceClearConfirmTitle => 'Confirm';

  @override
  String storageSpaceClearConfirmMessage(String targetName) {
    return 'Clear $targetName?';
  }

  @override
  String get storageSpaceClearButton => 'Clear';

  @override
  String storageSpaceClearDone(String targetName) {
    return 'Cleared $targetName';
  }

  @override
  String storageSpaceClearFailed(String error) {
    return 'Failed: $error';
  }

  @override
  String get storageSpaceLoadFailed => 'Failed to load';

  @override
  String get storageSpacePageTitle => 'Storage';

  @override
  String get storageSpaceRefreshTooltip => 'Refresh';

  @override
  String get storageSpaceTotalLabel => 'Total';

  @override
  String storageSpaceClearableLabel(String size) {
    return 'Clearable: $size';
  }

  @override
  String storageSpaceClearableHint(String size) {
    return 'Clearable: $size';
  }

  @override
  String storageSpaceFilesCount(int count) {
    return '$count files';
  }

  @override
  String get storageSpaceSafeToClearHint => 'Safe';

  @override
  String get storageSpaceNotSafeToClearHint => 'Caution';

  @override
  String get storageSpaceClearAvatarCacheButton => 'Clear avatars';

  @override
  String get storageSpaceClearCacheButton => 'Clear cache';

  @override
  String get storageSpaceClearLogsButton => 'Clear logs';

  @override
  String get storageSpaceBreakdownTitle => 'Breakdown';

  @override
  String get storageSpaceDeleteConfirmTitle => 'Delete';

  @override
  String storageSpaceDeleteUploadsConfirmMessage(int count) {
    return 'Delete $count items?';
  }

  @override
  String storageSpaceDeletedUploadsDone(int count) {
    return 'Deleted $count items';
  }

  @override
  String get storageSpaceNoUploads => 'No uploads';

  @override
  String get storageSpaceClearSelection => 'Clear';

  @override
  String get storageSpaceSelectAll => 'All';

  @override
  String storageSpaceSelectedCount(int count) {
    return '$count selected';
  }

  @override
  String storageSpaceUploadsCount(int count) {
    return '$count items';
  }

  @override
  String get displaySettingsPageThemeSettingsTitle => 'Theme';

  @override
  String get displaySettingsPageLanguageTitle => 'Language';

  @override
  String get displaySettingsPageLanguageChineseLabel => 'Chinese';

  @override
  String get displaySettingsPageLanguageEnglishLabel => 'English';

  @override
  String get displaySettingsPageChatItemDisplayTitle => 'Chat View';

  @override
  String get displaySettingsPageRenderingSettingsTitle => 'Rendering';

  @override
  String get displaySettingsPageBehaviorStartupTitle => 'Behavior';

  @override
  String get displaySettingsPageHapticsSettingsTitle => 'Haptics';

  @override
  String get displaySettingsPageAndroidBackgroundChatTitle => 'Background';

  @override
  String get androidBackgroundStatusOff => 'Off';

  @override
  String get androidBackgroundStatusOn => 'On';

  @override
  String get androidBackgroundStatusOther => 'Notify';

  @override
  String get displaySettingsPageChatMessageBackgroundTitle => 'Background';

  @override
  String get displaySettingsPageChatMessageBackgroundFrosted => 'Frosted';

  @override
  String get displaySettingsPageChatMessageBackgroundSolid => 'Solid';

  @override
  String get displaySettingsPageChatMessageBackgroundDefault => 'Default';

  @override
  String get displaySettingsPageAppFontTitle => 'App Font';

  @override
  String get displaySettingsPageFontLocalFileLabel => 'Local';

  @override
  String get desktopFontFamilySystemDefault => 'Default';

  @override
  String get displaySettingsPageCodeFontTitle => 'Code Font';

  @override
  String get desktopFontFamilyMonospaceDefault => 'Mono';

  @override
  String get displaySettingsPageChatFontSizeTitle => 'Font Size';

  @override
  String get displaySettingsPageAutoScrollIdleTitle => 'Auto Scroll';

  @override
  String get displaySettingsPageAutoScrollDisabledLabel => 'Off';

  @override
  String get displaySettingsPageChatBackgroundMaskTitle => 'Mask';

  @override
  String get fontPickerChooseLocalFile => 'Local';

  @override
  String get fontPickerGetFromGoogleFonts => 'Google';

  @override
  String get displaySettingsPageFontResetLabel => 'Reset';

  @override
  String get androidBackgroundOptionOn => 'On';

  @override
  String get androidBackgroundOptionOnNotify => 'Notify';

  @override
  String get androidBackgroundOptionOff => 'Off';

  @override
  String get displaySettingsPageChatFontSampleText => 'Sample';

  @override
  String get displaySettingsPageAutoScrollEnableTitle => 'Auto Scroll';

  @override
  String get displaySettingsPageAutoScrollIdleSubtitle => 'Delay';

  @override
  String get displaySettingsPageShowUserAvatarTitle => 'User Avatar';

  @override
  String get displaySettingsPageShowUserNameTimestampTitle => 'User Name';

  @override
  String get displaySettingsPageShowUserMessageActionsTitle => 'Actions';

  @override
  String get displaySettingsPageChatModelIconTitle => 'Model Icon';

  @override
  String get displaySettingsPageShowModelNameTimestampTitle => 'Model Name';

  @override
  String get displaySettingsPageShowTokenStatsTitle => 'Stats';

  @override
  String get displaySettingsPageEnableDollarLatexTitle => 'Latex';

  @override
  String get displaySettingsPageEnableMathTitle => 'Math';

  @override
  String get displaySettingsPageEnableUserMarkdownTitle => 'Markdown';

  @override
  String get displaySettingsPageEnableReasoningMarkdownTitle => 'Reasoning';

  @override
  String get displaySettingsPageAutoCollapseCodeBlockTitle => 'Collapse Code';

  @override
  String get displaySettingsPageMobileCodeBlockWrapTitle => 'Wrap';

  @override
  String get displaySettingsPageAutoCollapseCodeBlockLinesTitle => 'Lines';

  @override
  String get displaySettingsPageAutoCollapseCodeBlockLinesUnit => 'lines';

  @override
  String get displaySettingsPageAutoCollapseThinkingTitle =>
      'Collapse Thinking';

  @override
  String get displaySettingsPageShowUpdatesTitle => 'Updates';

  @override
  String get displaySettingsPageMessageNavButtonsTitle => 'Nav';

  @override
  String get displaySettingsPageShowChatListDateTitle => 'Dates';

  @override
  String get displaySettingsPageKeepSidebarOpenOnAssistantTapTitle =>
      'Pin Sidebar';

  @override
  String get displaySettingsPageKeepSidebarOpenOnTopicTapTitle => 'Pin Topics';

  @override
  String get displaySettingsPageKeepAssistantListExpandedOnSidebarCloseTitle =>
      'Expand';

  @override
  String get displaySettingsPageNewChatOnAssistantSwitchTitle =>
      'Auto New Chat';

  @override
  String get displaySettingsPageNewChatAfterDeleteTitle => 'Auto New Chat';

  @override
  String get displaySettingsPageNewChatOnLaunchTitle => 'New Chat on Launch';

  @override
  String get displaySettingsPageHapticsGlobalTitle => 'Haptics';

  @override
  String get displaySettingsPageHapticsIosSwitchTitle => 'Haptics';

  @override
  String get displaySettingsPageHapticsOnSidebarTitle => 'Sidebar';

  @override
  String get displaySettingsPageHapticsOnListItemTapTitle => 'List';

  @override
  String get displaySettingsPageHapticsOnCardTapTitle => 'Card';

  @override
  String get displaySettingsPageHapticsOnGenerateTitle => 'Generate';

  @override
  String get assistantSettingsPageTitle => 'Assistants';

  @override
  String get assistantSettingsCopyButton => 'Copy';

  @override
  String get assistantSettingsDeleteButton => 'Delete';

  @override
  String get ttsServicesPageBackButton => 'Back';

  @override
  String get ttsServicesPageTitle => 'TTS';

  @override
  String get ttsServicesPageAddTooltip => 'Add';

  @override
  String get ttsServicesPageSystemTtsTitle => 'System';

  @override
  String get ttsServicesPageSystemTtsAvailableSubtitle => 'Available';

  @override
  String ttsServicesPageSystemTtsUnavailableSubtitle(String error) {
    return 'Error: $error';
  }

  @override
  String get ttsServicesPageSystemTtsUnavailableNotInitialized => 'Not init';

  @override
  String get ttsServicesPageTestSpeechText => 'Test';

  @override
  String get ttsServicesPageSystemTtsSettingsTitle => 'Settings';

  @override
  String get ttsServicesPageEngineLabel => 'Engine';

  @override
  String get ttsServicesPageAutoLabel => 'Auto';

  @override
  String get ttsServicesPageLanguageLabel => 'Lang';

  @override
  String get ttsServicesPageSpeechRateLabel => 'Rate';

  @override
  String get ttsServicesPagePitchLabel => 'Pitch';

  @override
  String get ttsServicesPageDoneButton => 'Done';

  @override
  String get ttsServicesPageSettingsSavedMessage => 'Saved';

  @override
  String get ttsServicesViewDetailsButton => 'Details';

  @override
  String get ttsServicesDialogErrorTitle => 'Error';

  @override
  String get ttsServicesCloseButton => 'Close';

  @override
  String get ttsServicesDialogAddTitle => 'Add';

  @override
  String get ttsServicesDialogEditTitle => 'Edit';

  @override
  String get ttsServicesDialogProviderType => 'Type';

  @override
  String get ttsServicesFieldNameLabel => 'Name';

  @override
  String get ttsServicesFieldApiKeyLabel => 'Key';

  @override
  String get ttsServicesFieldBaseUrlLabel => 'URL';

  @override
  String get ttsServicesFieldModelLabel => 'Model';

  @override
  String get ttsServicesFieldEmotionLabel => 'Emotion';

  @override
  String get ttsServicesFieldSpeedLabel => 'Speed';

  @override
  String get ttsServicesFieldVoiceLabel => 'Voice';

  @override
  String get ttsServicesFieldVoiceIdLabel => 'ID';

  @override
  String get backupPageImportFromCherryStudio => 'Cherry';

  @override
  String get backupPageCancel => 'Cancel';

  @override
  String get backupPageOK => 'OK';

  @override
  String get backupPageSelectImportMode => 'Mode';

  @override
  String get backupPageOverwriteMode => 'Overwrite';

  @override
  String get backupPageOverwriteModeDescription => 'Clear local';

  @override
  String get backupPageMergeMode => 'Merge';

  @override
  String get backupPageMergeModeDescription => 'Smart merge';

  @override
  String get backupPageExporting => 'Exporting';

  @override
  String get backupPageTitle => 'Backup';

  @override
  String get backupPageBackupManagement => 'Manage';

  @override
  String get backupPageChatsLabel => 'Chats';

  @override
  String get backupPageFilesLabel => 'Files';

  @override
  String get backupPageWebDavBackup => 'WebDAV';

  @override
  String get backupPageWebDavServerSettings => 'Settings';

  @override
  String get backupPageTestConnection => 'Test';

  @override
  String get backupPageTestDone => 'Done';

  @override
  String get backupPageRestore => 'Restore';

  @override
  String get backupPageRestartRequired => 'Restart';

  @override
  String get backupPageRestartContent => 'Restart app';

  @override
  String get backupPageBackupNow => 'Backup';

  @override
  String get backupPageBackupUploaded => 'Done';

  @override
  String get backupPageLocalBackup => 'Local';

  @override
  String get backupPageImportBackupFile => 'File';

  @override
  String get backupPageImportFromChatbox => 'Chatbox';

  @override
  String get backupPageRemoteBackups => 'Remote';

  @override
  String get backupPageNoBackups => 'Empty';

  @override
  String get backupPageSave => 'Save';

  @override
  String get backupPageWebDavServerUrl => 'URL';

  @override
  String get backupPagePassword => 'Pass';

  @override
  String get backupPagePath => 'Path';

  @override
  String instructionInjectionImportSuccess(int count) {
    return 'Imported $count';
  }

  @override
  String get instructionInjectionBackTooltip => 'Back';

  @override
  String get instructionInjectionImportTooltip => 'Import';

  @override
  String get instructionInjectionAddTooltip => 'Add';

  @override
  String get instructionInjectionAddTitle => 'Add';

  @override
  String get networkProxyEnableLabel => 'Enabled';

  @override
  String get networkProxyType => 'Type';

  @override
  String get networkProxyServerHost => 'Host';

  @override
  String get networkProxyPort => 'Port';

  @override
  String get networkProxyUsername => 'User';

  @override
  String get networkProxyOptionalHint => 'Optional';

  @override
  String get networkProxyPassword => 'Pass';

  @override
  String get networkProxyPriorityNote => 'Priority note';

  @override
  String get networkProxyTestHeader => 'Test';

  @override
  String get networkProxyTestUrlHint => 'URL';

  @override
  String get networkProxyTesting => 'Testing';

  @override
  String get networkProxyTestButton => 'Test';

  @override
  String get networkProxyTestSuccess => 'OK';

  @override
  String networkProxyTestFailed(String error) {
    return 'Failed: $error';
  }

  @override
  String get networkProxyNoUrl => 'No URL';

  @override
  String get networkProxyTypeHttps => 'HTTPS';

  @override
  String get networkProxyTypeSocks5 => 'SOCKS5';

  @override
  String get networkProxyTypeHttp => 'HTTP';

  @override
  String get assistantEditRegexDescription => 'Regex rules';

  @override
  String get assistantEditAddRegexButton => 'Add Regex';

  @override
  String get assistantRegexUntitled => 'Untitled';

  @override
  String get assistantRegexDeleteButton => 'Delete';

  @override
  String get assistantRegexScopeUser => 'User';

  @override
  String get assistantRegexScopeAssistant => 'AI';

  @override
  String get assistantRegexScopeVisualOnly => 'Visual';

  @override
  String get assistantRegexValidationError => 'Error';

  @override
  String get assistantRegexInvalidPattern => 'Invalid';

  @override
  String get assistantRegexAddTitle => 'Add';

  @override
  String get assistantRegexEditTitle => 'Edit';

  @override
  String get assistantRegexAddAction => 'Add';

  @override
  String get assistantRegexSaveAction => 'Save';

  @override
  String get assistantRegexNameLabel => 'Name';

  @override
  String get assistantRegexPatternLabel => 'Regex';

  @override
  String get assistantRegexReplacementLabel => 'Replacement';

  @override
  String get assistantRegexScopeLabel => 'Scope';

  @override
  String get assistantRegexCancelButton => 'Cancel';

  @override
  String get themeSettingsPageDynamicColorSection => 'Dynamic';

  @override
  String get themeSettingsPageUseDynamicColorTitle => 'Enabled';

  @override
  String get themeSettingsPageUseDynamicColorSubtitle => 'System color';

  @override
  String get themeSettingsPageUsePureBackgroundTitle => 'Pure';

  @override
  String get themeSettingsPageUsePureBackgroundSubtitle => 'Solid';

  @override
  String get fontPickerFilterHint => 'Filter';

  @override
  String get logViewerTitle => 'Logs';

  @override
  String get logViewerEmpty => 'Empty';

  @override
  String get logViewerCurrentLog => 'Current';

  @override
  String get logViewerExport => 'Export';

  @override
  String get chatHistoryPageTitle => 'History';

  @override
  String get chatHistoryPageSearchTooltip => 'Search';

  @override
  String get chatHistoryPageDeleteAllTooltip => 'Delete All';

  @override
  String get chatHistoryPageDeleteAllDialogTitle => 'Clear';

  @override
  String get chatHistoryPageDeleteAllDialogContent => 'Delete all?';

  @override
  String get chatHistoryPageCancel => 'Cancel';

  @override
  String get chatHistoryPageDelete => 'Delete';

  @override
  String get chatHistoryPageDeletedAllSnackbar => 'Cleared';

  @override
  String get chatHistoryPageSearchHint => 'Search';

  @override
  String get chatHistoryPageNoConversations => 'Empty';

  @override
  String get chatHistoryPagePinnedSection => 'Pinned';

  @override
  String get chatHistoryPagePinned => 'Pinned';

  @override
  String get chatHistoryPagePin => 'Pin';

  @override
  String get assistantTagsCreateDialogTitle => 'Create';

  @override
  String get assistantTagsNameHint => 'Name';

  @override
  String get assistantTagsCreateDialogCancel => 'Cancel';

  @override
  String get assistantTagsCreateDialogOk => 'OK';

  @override
  String get assistantTagsRenameDialogTitle => 'Rename';

  @override
  String get assistantTagsRenameDialogOk => 'OK';

  @override
  String get assistantTagsDeleteConfirmTitle => 'Delete';

  @override
  String get assistantTagsDeleteConfirmContent => 'Delete?';

  @override
  String get assistantTagsDeleteConfirmCancel => 'Cancel';

  @override
  String get assistantTagsDeleteConfirmOk => 'OK';

  @override
  String get assistantTagsManageTitle => 'Tags';

  @override
  String get sideDrawerChooseAssistantTitle => 'Choose';

  @override
  String get searchServicesPageAtLeastOneServiceRequired => 'Service required';

  @override
  String get modelDetailSheetChatType => 'Chat';

  @override
  String get modelDetailSheetEmbeddingType => 'Embedding';

  @override
  String get providerDetailPageMultiKeyModeTitle => 'Multi-Key';

  @override
  String get providerDetailPageResponseApiTitle => 'Response API';

  @override
  String get providerDetailPageVertexAiTitle => 'Vertex AI';

  @override
  String get providerDetailPageAihubmixAppCodeLabel => 'APP-Code';

  @override
  String get providerDetailPageAihubmixAppCodeHelp => 'Discount code';

  @override
  String get providerDetailPageProviderTypeTitle => 'Type';

  @override
  String get providerDetailPageDeleteAllModelsWarning => 'Delete all?';

  @override
  String get shareProviderSheetShareButton => 'Share';

  @override
  String get assistantEditImageUrlDialogCancel => 'Cancel';

  @override
  String get assistantEditImageUrlDialogSave => 'Save';

  @override
  String get assistantEditQQAvatarDialogTitle => 'QQ Avatar';

  @override
  String get assistantEditQQAvatarDialogHint => 'QQ Number';

  @override
  String get assistantEditQQAvatarRandomButton => 'Random';

  @override
  String get assistantEditQQAvatarFailedMessage => 'Failed';

  @override
  String get assistantEditQQAvatarDialogCancel => 'Cancel';

  @override
  String get assistantEditQQAvatarDialogSave => 'Save';

  @override
  String get assistantEditGalleryErrorMessage => 'Error';

  @override
  String get assistantEditGeneralErrorMessage => 'Error';

  @override
  String get assistantEditSystemPromptImportEmpty => 'Empty';

  @override
  String get assistantEditSystemPromptImportSuccess => 'Success';

  @override
  String assistantEditSystemPromptImportFailed(String error) {
    return 'Failed: $error';
  }

  @override
  String get assistantEditSampleUser => 'User';

  @override
  String get assistantEditSampleMessage => 'Hello';

  @override
  String get assistantEditSampleReply => 'Hi';

  @override
  String get assistantEditSystemPromptTitle => 'System Prompt';

  @override
  String get assistantEditSystemPromptImportButton => 'Import';

  @override
  String get assistantEditSystemPromptHint => 'Prompt';

  @override
  String get assistantEditAvailableVariables => 'Variables';

  @override
  String get assistantEditVariableDate => 'Date';

  @override
  String get assistantEditVariableTime => 'Time';

  @override
  String get assistantEditVariableDatetime => 'DateTime';

  @override
  String get assistantEditVariableModelId => 'Model ID';

  @override
  String get assistantEditVariableModelName => 'Model Name';

  @override
  String get assistantEditVariableLocale => 'Locale';

  @override
  String get assistantEditVariableTimezone => 'Timezone';

  @override
  String get assistantEditVariableSystemVersion => 'OS Version';

  @override
  String get assistantEditVariableDeviceInfo => 'Device';

  @override
  String get assistantEditVariableBatteryLevel => 'Battery';

  @override
  String get assistantEditVariableNickname => 'Nickname';

  @override
  String get assistantEditVariableAssistantName => 'Name';

  @override
  String get assistantEditMessageTemplateTitle => 'Template';

  @override
  String get assistantEditVariableRole => 'Role';

  @override
  String get assistantEditVariableMessage => 'Message';

  @override
  String get assistantEditPresetAddUser => 'Add User';

  @override
  String get assistantEditPresetAddAssistant => 'Add AI';

  @override
  String get assistantEditPresetTitle => 'Preset';

  @override
  String get assistantEditPresetEmpty => 'Empty';

  @override
  String get assistantEditPresetInputHintAssistant => 'AI';

  @override
  String get assistantEditPresetInputHintUser => 'User';

  @override
  String get assistantEditPresetEditDialogTitle => 'Edit';

  @override
  String get assistantEditMcpConnectedTag => 'Connected';

  @override
  String get assistantEditQuickPhraseDescription => 'Quick phrases';

  @override
  String get assistantEditAddQuickPhraseButton => 'Add';

  @override
  String get assistantEditTemperatureTitle => 'Temp';

  @override
  String get assistantEditTopPTitle => 'Top P';

  @override
  String get mermaidPreviewOpenFailed => 'Open failed';

  @override
  String get qrScanPageTitle => 'Scan QR';

  @override
  String get qrScanPageInstruction => 'Align QR code';

  @override
  String get defaultModelPageBackTooltip => 'Back';

  @override
  String get defaultModelPageTitle => 'Default Model';

  @override
  String defaultModelPageTitleVars(String contentVar, String localeVar) {
    return '$contentVar $localeVar';
  }

  @override
  String defaultModelPageTranslateVars(String sourceVar, String targetVar) {
    return '$sourceVar $targetVar';
  }

  @override
  String defaultModelPageSummaryVars(
    String previousSummaryVar,
    String userMessagesVar,
  ) {
    return '$previousSummaryVar $userMessagesVar';
  }

  @override
  String get messageEditPageSave => 'Save';

  @override
  String get chatMessageWidgetTranslating => 'Translating...';

  @override
  String get messageExportSheetAssistant => 'Assistant';

  @override
  String get messageExportSheetDefaultTitle => 'New Chat';

  @override
  String messageExportSheetExportedAs(String filename) {
    return 'Exported as $filename';
  }

  @override
  String messageExportSheetExportFailed(String error) {
    return 'Failed: $error';
  }

  @override
  String get messageExportSheetFormatTitle => 'Format';

  @override
  String get multiKeyPageTitle => 'Keys';

  @override
  String get multiKeyPageDeleteErrorsTooltip => 'Delete errors';

  @override
  String get multiKeyPageDetect => 'Detect';

  @override
  String get multiKeyPageAdd => 'Add';

  @override
  String get multiKeyPageTotal => 'Total';

  @override
  String get multiKeyPageNormal => 'Normal';

  @override
  String get multiKeyPageError => 'Error';

  @override
  String get multiKeyPageStrategyPriority => 'Priority';

  @override
  String get multiKeyPageStrategyLeastUsed => 'Least Used';

  @override
  String get multiKeyPageStrategyRandom => 'Random';

  @override
  String get multiKeyPageStrategyRoundRobin => 'Round Robin';

  @override
  String get multiKeyPageStrategyTitle => 'Strategy';

  @override
  String get multiKeyPageNoKeys => 'No keys';

  @override
  String get multiKeyPageStatusActive => 'Active';

  @override
  String get multiKeyPageStatusDisabled => 'Disabled';

  @override
  String get multiKeyPageStatusError => 'Error';

  @override
  String get multiKeyPageStatusRateLimited => 'Limited';

  @override
  String get multiKeyPageEdit => 'Edit';

  @override
  String get multiKeyPageDelete => 'Delete';

  @override
  String get multiKeyPageDeleteSnackbarDeletedOne => 'Deleted';

  @override
  String get multiKeyPageUndo => 'Undo';

  @override
  String get multiKeyPageUndoRestored => 'Restored';

  @override
  String get multiKeyPageDuplicateKeyWarning => 'Duplicate';

  @override
  String multiKeyPageImportedSnackbar(int n) {
    return 'Imported $n';
  }

  @override
  String get multiKeyPagePleaseAddModel => 'Add model';

  @override
  String get multiKeyPageDeleteErrorsConfirmTitle => 'Delete errors';

  @override
  String get multiKeyPageDeleteErrorsConfirmContent => 'Delete all error keys?';

  @override
  String multiKeyPageDeletedErrorsSnackbar(int n) {
    return 'Deleted $n';
  }

  @override
  String get multiKeyPageAlias => 'Alias';

  @override
  String get multiKeyPagePriority => 'Priority';

  @override
  String get multiKeyPageSave => 'Save';

  @override
  String get multiKeyPageCancel => 'Cancel';

  @override
  String get multiKeyPageAddHint => 'Keys';

  @override
  String get codeBlockPreviewButton => 'Preview';

  @override
  String get htmlPreviewNotSupportedOnLinux => 'Not on Linux';

  @override
  String codeBlockCollapsedLines(int n) {
    return '$n lines';
  }

  @override
  String get mermaidExportFailed => 'Failed';

  @override
  String get mermaidPreviewOpen => 'Open';

  @override
  String imageViewerPageSaveFailed(String error) {
    return 'Failed: $error';
  }

  @override
  String get imageViewerPageSaveSuccess => 'Saved';

  @override
  String get imageViewerPageSaveButton => 'Save';

  @override
  String imageViewerPageShareFailed(String error) {
    return 'Failed: $error';
  }

  @override
  String imageViewerPageShareFailedOpenFile(String message) {
    return 'Failed: $message';
  }

  @override
  String get desktopNavTranslateTooltip => 'Translate';

  @override
  String get translatePagePasteButton => 'Paste';

  @override
  String get translatePageCopyResult => 'Copy';

  @override
  String get translatePageClearAll => 'Clear';

  @override
  String get translatePageInputHint => 'Input';

  @override
  String get translatePageOutputHint => 'Output';

  @override
  String get chatMessageWidgetStopTooltip => 'Stop';

  @override
  String get chatMessageWidgetTranslateTooltip => 'Translate';

  @override
  String get assistantEditTemperatureDescription => 'Temp desc';

  @override
  String get assistantEditTopPDescription => 'Top P desc';

  @override
  String get assistantEditMaxTokensDescription => 'Max tokens desc';

  @override
  String get defaultModelPageUseCurrentModel => 'Use current';

  @override
  String get defaultModelPageChatModelTitle => 'Chat Model';

  @override
  String get defaultModelPageChatModelSubtitle => 'Default chat model';

  @override
  String get defaultModelPageTitleModelTitle => 'Title Model';

  @override
  String get defaultModelPageTitleModelSubtitle => 'Summarize titles';

  @override
  String get defaultModelPageSummaryModelTitle => 'Summary Model';

  @override
  String get defaultModelPageSummaryModelSubtitle => 'Summarize conversations';

  @override
  String get defaultModelPageTranslateModelTitle => 'Translate Model';

  @override
  String get defaultModelPageTranslateModelSubtitle => 'Translation model';

  @override
  String get defaultModelPageOcrModelTitle => 'OCR Model';

  @override
  String get defaultModelPageOcrModelSubtitle => 'OCR model';

  @override
  String get defaultModelPageTitlePromptHint => 'Title prompt hint';

  @override
  String get defaultModelPageTranslatePromptHint => 'Translate prompt hint';

  @override
  String get defaultModelPageSummaryPromptHint => 'Summary prompt hint';

  @override
  String get assistantEditEmojiDialogTitle => 'Emoji';

  @override
  String get assistantEditEmojiDialogHint => 'Pick an emoji';

  @override
  String get importProviderSheetCancelButton => 'Cancel';
}
