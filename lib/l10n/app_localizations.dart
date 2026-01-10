import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh'),
    Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
    Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
  ];

  /// No description provided for @appName.
  ///
  /// In en, this message translates to:
  /// **'OmniChat'**
  String get appName;

  /// No description provided for @settingsPageTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsPageTitle;

  /// No description provided for @settingsPageGeneralSection.
  ///
  /// In en, this message translates to:
  /// **'General'**
  String get settingsPageGeneralSection;

  /// No description provided for @settingsPageColorMode.
  ///
  /// In en, this message translates to:
  /// **'Theme Mode'**
  String get settingsPageColorMode;

  /// No description provided for @settingsPageDarkMode.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get settingsPageDarkMode;

  /// No description provided for @settingsPageLightMode.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get settingsPageLightMode;

  /// No description provided for @settingsPageSystemMode.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get settingsPageSystemMode;

  /// No description provided for @settingsPageDisplay.
  ///
  /// In en, this message translates to:
  /// **'Display Settings'**
  String get settingsPageDisplay;

  /// No description provided for @settingsPageDisplayDescription.
  ///
  /// In en, this message translates to:
  /// **'Customize UI and font'**
  String get settingsPageDisplayDescription;

  /// No description provided for @settingsPageAssistant.
  ///
  /// In en, this message translates to:
  /// **'Assistant Settings'**
  String get settingsPageAssistant;

  /// No description provided for @settingsPageAssistantDescription.
  ///
  /// In en, this message translates to:
  /// **'Configure default parameters'**
  String get settingsPageAssistantDescription;

  /// No description provided for @settingsPageModelsServicesSection.
  ///
  /// In en, this message translates to:
  /// **'Models & Services'**
  String get settingsPageModelsServicesSection;

  /// No description provided for @settingsPageDefaultModel.
  ///
  /// In en, this message translates to:
  /// **'Default Model'**
  String get settingsPageDefaultModel;

  /// No description provided for @settingsPageDefaultModelDescription.
  ///
  /// In en, this message translates to:
  /// **'Select global chat model'**
  String get settingsPageDefaultModelDescription;

  /// No description provided for @settingsPageProviders.
  ///
  /// In en, this message translates to:
  /// **'Model Providers'**
  String get settingsPageProviders;

  /// No description provided for @settingsPageProvidersDescription.
  ///
  /// In en, this message translates to:
  /// **'Manage API keys and models'**
  String get settingsPageProvidersDescription;

  /// No description provided for @settingsPageSearch.
  ///
  /// In en, this message translates to:
  /// **'Search Services'**
  String get settingsPageSearch;

  /// No description provided for @settingsPageSearchDescription.
  ///
  /// In en, this message translates to:
  /// **'Configure search engines'**
  String get settingsPageSearchDescription;

  /// No description provided for @settingsPageTts.
  ///
  /// In en, this message translates to:
  /// **'TTS Services'**
  String get settingsPageTts;

  /// No description provided for @settingsPageTtsDescription.
  ///
  /// In en, this message translates to:
  /// **'Text-to-Speech configuration'**
  String get settingsPageTtsDescription;

  /// No description provided for @settingsPageMcp.
  ///
  /// In en, this message translates to:
  /// **'MCP Server'**
  String get settingsPageMcp;

  /// No description provided for @settingsPageMcpDescription.
  ///
  /// In en, this message translates to:
  /// **'Model Context Protocol'**
  String get settingsPageMcpDescription;

  /// No description provided for @settingsPageQuickPhrase.
  ///
  /// In en, this message translates to:
  /// **'Quick Phrases'**
  String get settingsPageQuickPhrase;

  /// No description provided for @settingsPageQuickPhraseDescription.
  ///
  /// In en, this message translates to:
  /// **'Manage shortcuts'**
  String get settingsPageQuickPhraseDescription;

  /// No description provided for @settingsPageInstructionInjection.
  ///
  /// In en, this message translates to:
  /// **'Instruction Injection'**
  String get settingsPageInstructionInjection;

  /// No description provided for @settingsPageInstructionInjectionDescription.
  ///
  /// In en, this message translates to:
  /// **'System prompts'**
  String get settingsPageInstructionInjectionDescription;

  /// No description provided for @settingsPageNetworkProxy.
  ///
  /// In en, this message translates to:
  /// **'Network Proxy'**
  String get settingsPageNetworkProxy;

  /// No description provided for @settingsPageNetworkProxyDescription.
  ///
  /// In en, this message translates to:
  /// **'Proxy configuration'**
  String get settingsPageNetworkProxyDescription;

  /// No description provided for @settingsPageDataSection.
  ///
  /// In en, this message translates to:
  /// **'Data'**
  String get settingsPageDataSection;

  /// No description provided for @settingsPageBackup.
  ///
  /// In en, this message translates to:
  /// **'Backup & Sync'**
  String get settingsPageBackup;

  /// No description provided for @settingsPageBackupDescription.
  ///
  /// In en, this message translates to:
  /// **'Import/Export data'**
  String get settingsPageBackupDescription;

  /// No description provided for @settingsPageChatStorage.
  ///
  /// In en, this message translates to:
  /// **'Chat Storage'**
  String get settingsPageChatStorage;

  /// No description provided for @settingsPageChatStorageDescription.
  ///
  /// In en, this message translates to:
  /// **'Manage space usage'**
  String get settingsPageChatStorageDescription;

  /// No description provided for @settingsPageAboutSection.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get settingsPageAboutSection;

  /// No description provided for @settingsPageAbout.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get settingsPageAbout;

  /// No description provided for @settingsPageAboutDescription.
  ///
  /// In en, this message translates to:
  /// **'Version info and more'**
  String get settingsPageAboutDescription;

  /// No description provided for @settingsPageBackButton.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get settingsPageBackButton;

  /// No description provided for @settingsPageWarningMessage.
  ///
  /// In en, this message translates to:
  /// **'Please configure at least one model provider to start chatting.'**
  String get settingsPageWarningMessage;

  /// No description provided for @settingsPageCalculating.
  ///
  /// In en, this message translates to:
  /// **'Calculating...'**
  String get settingsPageCalculating;

  /// No description provided for @settingsPageFilesCount.
  ///
  /// In en, this message translates to:
  /// **'{count} files, {size}'**
  String settingsPageFilesCount(int count, String size);

  /// No description provided for @homePageNewChat.
  ///
  /// In en, this message translates to:
  /// **'New Chat'**
  String get homePageNewChat;

  /// No description provided for @homePageSettings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get homePageSettings;

  /// No description provided for @homePageCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get homePageCancel;

  /// No description provided for @homePageConfirm.
  ///
  /// In en, this message translates to:
  /// **'Confirm'**
  String get homePageConfirm;

  /// No description provided for @homePageDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get homePageDelete;

  /// No description provided for @homePageEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get homePageEdit;

  /// No description provided for @homePageRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get homePageRetry;

  /// No description provided for @homePageCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get homePageCopy;

  /// No description provided for @homePageShare.
  ///
  /// In en, this message translates to:
  /// **'Share'**
  String get homePageShare;

  /// No description provided for @sidebarHistory.
  ///
  /// In en, this message translates to:
  /// **'History'**
  String get sidebarHistory;

  /// No description provided for @sidebarAssistants.
  ///
  /// In en, this message translates to:
  /// **'Assistants'**
  String get sidebarAssistants;

  /// No description provided for @sidebarTopics.
  ///
  /// In en, this message translates to:
  /// **'Topics'**
  String get sidebarTopics;

  /// No description provided for @aboutPageVersion.
  ///
  /// In en, this message translates to:
  /// **'Version'**
  String get aboutPageVersion;

  /// No description provided for @aboutPageSystem.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get aboutPageSystem;

  /// No description provided for @aboutPageAppDescription.
  ///
  /// In en, this message translates to:
  /// **'A cross-platform, multi-provider AI chat client.'**
  String get aboutPageAppDescription;

  /// No description provided for @aboutPageLicense.
  ///
  /// In en, this message translates to:
  /// **'License'**
  String get aboutPageLicense;

  /// No description provided for @aboutPagePrivacyPolicy.
  ///
  /// In en, this message translates to:
  /// **'Privacy Policy'**
  String get aboutPagePrivacyPolicy;

  /// No description provided for @aboutPageTermsOfService.
  ///
  /// In en, this message translates to:
  /// **'Terms of Service'**
  String get aboutPageTermsOfService;

  /// No description provided for @aboutPageEasterEggButton.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get aboutPageEasterEggButton;

  /// No description provided for @requestLogSettingTitle.
  ///
  /// In en, this message translates to:
  /// **'Request Logs'**
  String get requestLogSettingTitle;

  /// No description provided for @requestLogSettingSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Log API requests for debugging'**
  String get requestLogSettingSubtitle;

  /// No description provided for @flutterLogSettingTitle.
  ///
  /// In en, this message translates to:
  /// **'App Logs'**
  String get flutterLogSettingTitle;

  /// No description provided for @flutterLogSettingSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Log application events'**
  String get flutterLogSettingSubtitle;

  /// No description provided for @providersPageSiliconFlowName.
  ///
  /// In en, this message translates to:
  /// **'SiliconFlow'**
  String get providersPageSiliconFlowName;

  /// No description provided for @providersPageAliyunName.
  ///
  /// In en, this message translates to:
  /// **'Aliyun (DashScope)'**
  String get providersPageAliyunName;

  /// No description provided for @providersPageZhipuName.
  ///
  /// In en, this message translates to:
  /// **'Zhipu AI'**
  String get providersPageZhipuName;

  /// No description provided for @providersPageByteDanceName.
  ///
  /// In en, this message translates to:
  /// **'Doubao (ByteDance)'**
  String get providersPageByteDanceName;

  /// No description provided for @providerDetailPageApiBaseUrlLabel.
  ///
  /// In en, this message translates to:
  /// **'API Base URL'**
  String get providerDetailPageApiBaseUrlLabel;

  /// No description provided for @providerDetailPageLocationLabel.
  ///
  /// In en, this message translates to:
  /// **'Location'**
  String get providerDetailPageLocationLabel;

  /// No description provided for @providerDetailPageProjectIdLabel.
  ///
  /// In en, this message translates to:
  /// **'Project ID'**
  String get providerDetailPageProjectIdLabel;

  /// No description provided for @providerDetailPageServiceAccountJsonLabel.
  ///
  /// In en, this message translates to:
  /// **'Service Account JSON'**
  String get providerDetailPageServiceAccountJsonLabel;

  /// No description provided for @providerDetailPageImportJsonButton.
  ///
  /// In en, this message translates to:
  /// **'Import JSON File'**
  String get providerDetailPageImportJsonButton;

  /// No description provided for @providerDetailPageApiPathLabel.
  ///
  /// In en, this message translates to:
  /// **'API Path'**
  String get providerDetailPageApiPathLabel;

  /// No description provided for @providerDetailPageBalanceEnabled.
  ///
  /// In en, this message translates to:
  /// **'Enable Balance Check'**
  String get providerDetailPageBalanceEnabled;

  /// No description provided for @providerDetailPageBalanceApiPath.
  ///
  /// In en, this message translates to:
  /// **'Balance API Path'**
  String get providerDetailPageBalanceApiPath;

  /// No description provided for @providerDetailPageBalanceResultKey.
  ///
  /// In en, this message translates to:
  /// **'Balance Result Key'**
  String get providerDetailPageBalanceResultKey;

  /// No description provided for @providerDetailPageModelsTitle.
  ///
  /// In en, this message translates to:
  /// **'Models'**
  String get providerDetailPageModelsTitle;

  /// No description provided for @providerDetailPageFilterHint.
  ///
  /// In en, this message translates to:
  /// **'Filter models...'**
  String get providerDetailPageFilterHint;

  /// No description provided for @providerDetailPageUseStreamingLabel.
  ///
  /// In en, this message translates to:
  /// **'Use Streaming'**
  String get providerDetailPageUseStreamingLabel;

  /// No description provided for @providerDetailPageBatchDetecting.
  ///
  /// In en, this message translates to:
  /// **'Detecting...'**
  String get providerDetailPageBatchDetecting;

  /// No description provided for @providerDetailPageBatchDetectStart.
  ///
  /// In en, this message translates to:
  /// **'Check Connectivity'**
  String get providerDetailPageBatchDetectStart;

  /// No description provided for @providerDetailPageBatchDetectButton.
  ///
  /// In en, this message translates to:
  /// **'Check'**
  String get providerDetailPageBatchDetectButton;

  /// No description provided for @providerDetailPageTestButton.
  ///
  /// In en, this message translates to:
  /// **'Test Connection'**
  String get providerDetailPageTestButton;

  /// No description provided for @providerDetailPageAddNewModelButton.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get providerDetailPageAddNewModelButton;

  /// No description provided for @providerDetailPageApiKeyHint.
  ///
  /// In en, this message translates to:
  /// **'Enter API Key'**
  String get providerDetailPageApiKeyHint;

  /// No description provided for @providerDetailPageManageKeysButton.
  ///
  /// In en, this message translates to:
  /// **'Manage Keys'**
  String get providerDetailPageManageKeysButton;

  /// No description provided for @providerDetailPageDeleteProviderTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete Provider'**
  String get providerDetailPageDeleteProviderTitle;

  /// No description provided for @providerDetailPageDeleteProviderContent.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete this provider configuration?'**
  String get providerDetailPageDeleteProviderContent;

  /// No description provided for @providerDetailPageCancelButton.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get providerDetailPageCancelButton;

  /// No description provided for @providerDetailPageDeleteButton.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get providerDetailPageDeleteButton;

  /// No description provided for @multiKeyPageKey.
  ///
  /// In en, this message translates to:
  /// **'API Key'**
  String get multiKeyPageKey;

  /// No description provided for @addProviderSheetAddButton.
  ///
  /// In en, this message translates to:
  /// **'Add Provider'**
  String get addProviderSheetAddButton;

  /// No description provided for @desktopSidebarTabAssistants.
  ///
  /// In en, this message translates to:
  /// **'Assistants'**
  String get desktopSidebarTabAssistants;

  /// No description provided for @desktopSidebarTabTopics.
  ///
  /// In en, this message translates to:
  /// **'Topics'**
  String get desktopSidebarTabTopics;

  /// No description provided for @desktopAssistantsListTitle.
  ///
  /// In en, this message translates to:
  /// **'Assistants'**
  String get desktopAssistantsListTitle;

  /// No description provided for @desktopAvatarMenuUseEmoji.
  ///
  /// In en, this message translates to:
  /// **'Use Emoji'**
  String get desktopAvatarMenuUseEmoji;

  /// No description provided for @desktopAvatarMenuChangeFromImage.
  ///
  /// In en, this message translates to:
  /// **'Pick Image'**
  String get desktopAvatarMenuChangeFromImage;

  /// No description provided for @desktopAvatarMenuReset.
  ///
  /// In en, this message translates to:
  /// **'Reset Default'**
  String get desktopAvatarMenuReset;

  /// No description provided for @sideDrawerSearchHint.
  ///
  /// In en, this message translates to:
  /// **'Search chats...'**
  String get sideDrawerSearchHint;

  /// No description provided for @sideDrawerSearchAssistantsHint.
  ///
  /// In en, this message translates to:
  /// **'Search assistants...'**
  String get sideDrawerSearchAssistantsHint;

  /// No description provided for @sideDrawerRenameHint.
  ///
  /// In en, this message translates to:
  /// **'Enter new name'**
  String get sideDrawerRenameHint;

  /// No description provided for @sideDrawerCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get sideDrawerCancel;

  /// No description provided for @sideDrawerOK.
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get sideDrawerOK;

  /// No description provided for @sideDrawerSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get sideDrawerSave;

  /// No description provided for @sideDrawerMenuRename.
  ///
  /// In en, this message translates to:
  /// **'Rename'**
  String get sideDrawerMenuRename;

  /// No description provided for @sideDrawerMenuPin.
  ///
  /// In en, this message translates to:
  /// **'Pin'**
  String get sideDrawerMenuPin;

  /// No description provided for @sideDrawerMenuUnpin.
  ///
  /// In en, this message translates to:
  /// **'Unpin'**
  String get sideDrawerMenuUnpin;

  /// No description provided for @sideDrawerMenuRegenerateTitle.
  ///
  /// In en, this message translates to:
  /// **'Regenerate Title'**
  String get sideDrawerMenuRegenerateTitle;

  /// No description provided for @sideDrawerMenuMoveTo.
  ///
  /// In en, this message translates to:
  /// **'Move to...'**
  String get sideDrawerMenuMoveTo;

  /// No description provided for @sideDrawerMenuDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get sideDrawerMenuDelete;

  /// No description provided for @sideDrawerDeleteSnackbar.
  ///
  /// In en, this message translates to:
  /// **'Deleted \"{title}\"'**
  String sideDrawerDeleteSnackbar(String title);

  /// No description provided for @sideDrawerGreetingMorning.
  ///
  /// In en, this message translates to:
  /// **'Good morning'**
  String get sideDrawerGreetingMorning;

  /// No description provided for @sideDrawerGreetingNoon.
  ///
  /// In en, this message translates to:
  /// **'Good afternoon'**
  String get sideDrawerGreetingNoon;

  /// No description provided for @sideDrawerGreetingAfternoon.
  ///
  /// In en, this message translates to:
  /// **'Good afternoon'**
  String get sideDrawerGreetingAfternoon;

  /// No description provided for @sideDrawerGreetingEvening.
  ///
  /// In en, this message translates to:
  /// **'Good evening'**
  String get sideDrawerGreetingEvening;

  /// No description provided for @sideDrawerDateToday.
  ///
  /// In en, this message translates to:
  /// **'Today'**
  String get sideDrawerDateToday;

  /// No description provided for @sideDrawerDateYesterday.
  ///
  /// In en, this message translates to:
  /// **'Yesterday'**
  String get sideDrawerDateYesterday;

  /// No description provided for @sideDrawerDateShortPattern.
  ///
  /// In en, this message translates to:
  /// **'MM-dd'**
  String get sideDrawerDateShortPattern;

  /// No description provided for @sideDrawerDateFullPattern.
  ///
  /// In en, this message translates to:
  /// **'yyyy-MM-dd'**
  String get sideDrawerDateFullPattern;

  /// No description provided for @sideDrawerPinnedLabel.
  ///
  /// In en, this message translates to:
  /// **'Pinned'**
  String get sideDrawerPinnedLabel;

  /// No description provided for @sideDrawerChooseImage.
  ///
  /// In en, this message translates to:
  /// **'Choose Image'**
  String get sideDrawerChooseImage;

  /// No description provided for @sideDrawerChooseEmoji.
  ///
  /// In en, this message translates to:
  /// **'Choose Emoji'**
  String get sideDrawerChooseEmoji;

  /// No description provided for @sideDrawerEnterLink.
  ///
  /// In en, this message translates to:
  /// **'Enter Link'**
  String get sideDrawerEnterLink;

  /// No description provided for @sideDrawerReset.
  ///
  /// In en, this message translates to:
  /// **'Reset Default'**
  String get sideDrawerReset;

  /// No description provided for @sideDrawerEmojiDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Pick an Emoji'**
  String get sideDrawerEmojiDialogTitle;

  /// No description provided for @sideDrawerEmojiDialogHint.
  ///
  /// In en, this message translates to:
  /// **'Type an emoji...'**
  String get sideDrawerEmojiDialogHint;

  /// No description provided for @sideDrawerImageUrlDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Enter Image URL'**
  String get sideDrawerImageUrlDialogTitle;

  /// No description provided for @sideDrawerImageUrlDialogHint.
  ///
  /// In en, this message translates to:
  /// **'https://example.com/avatar.png'**
  String get sideDrawerImageUrlDialogHint;

  /// No description provided for @sideDrawerSetNicknameTitle.
  ///
  /// In en, this message translates to:
  /// **'Set Nickname'**
  String get sideDrawerSetNicknameTitle;

  /// No description provided for @sideDrawerNicknameLabel.
  ///
  /// In en, this message translates to:
  /// **'Nickname'**
  String get sideDrawerNicknameLabel;

  /// No description provided for @sideDrawerNicknameHint.
  ///
  /// In en, this message translates to:
  /// **'Your display name'**
  String get sideDrawerNicknameHint;

  /// No description provided for @sideDrawerGalleryOpenError.
  ///
  /// In en, this message translates to:
  /// **'Could not open gallery.'**
  String get sideDrawerGalleryOpenError;

  /// No description provided for @sideDrawerGeneralImageError.
  ///
  /// In en, this message translates to:
  /// **'Failed to pick image.'**
  String get sideDrawerGeneralImageError;

  /// No description provided for @sideDrawerLinkCopied.
  ///
  /// In en, this message translates to:
  /// **'Link copied to clipboard'**
  String get sideDrawerLinkCopied;

  /// No description provided for @sideDrawerUpdateTitle.
  ///
  /// In en, this message translates to:
  /// **'Update Available: {version}'**
  String sideDrawerUpdateTitle(String version);

  /// No description provided for @sideDrawerUpdateTitleWithBuild.
  ///
  /// In en, this message translates to:
  /// **'Update Available: {version} ({build})'**
  String sideDrawerUpdateTitleWithBuild(String version, int build);

  /// No description provided for @assistantEditPageTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit Assistant'**
  String get assistantEditPageTitle;

  /// No description provided for @assistantEditPageNotFound.
  ///
  /// In en, this message translates to:
  /// **'Assistant not found'**
  String get assistantEditPageNotFound;

  /// No description provided for @assistantEditPageBasicTab.
  ///
  /// In en, this message translates to:
  /// **'Basic'**
  String get assistantEditPageBasicTab;

  /// No description provided for @assistantEditPagePromptsTab.
  ///
  /// In en, this message translates to:
  /// **'Prompts'**
  String get assistantEditPagePromptsTab;

  /// No description provided for @assistantEditPageMemoryTab.
  ///
  /// In en, this message translates to:
  /// **'Memory'**
  String get assistantEditPageMemoryTab;

  /// No description provided for @assistantEditPageMcpTab.
  ///
  /// In en, this message translates to:
  /// **'MCP'**
  String get assistantEditPageMcpTab;

  /// No description provided for @assistantEditPageQuickPhraseTab.
  ///
  /// In en, this message translates to:
  /// **'Phrases'**
  String get assistantEditPageQuickPhraseTab;

  /// No description provided for @assistantEditPageCustomTab.
  ///
  /// In en, this message translates to:
  /// **'Custom'**
  String get assistantEditPageCustomTab;

  /// No description provided for @assistantEditPageRegexTab.
  ///
  /// In en, this message translates to:
  /// **'Regex'**
  String get assistantEditPageRegexTab;

  /// No description provided for @assistantEditMemoryDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit Memory'**
  String get assistantEditMemoryDialogTitle;

  /// No description provided for @assistantEditMemoryDialogHint.
  ///
  /// In en, this message translates to:
  /// **'Enter memory content...'**
  String get assistantEditMemoryDialogHint;

  /// No description provided for @assistantEditEmojiDialogCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get assistantEditEmojiDialogCancel;

  /// No description provided for @assistantEditEmojiDialogSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get assistantEditEmojiDialogSave;

  /// No description provided for @assistantEditMemorySwitchTitle.
  ///
  /// In en, this message translates to:
  /// **'Enable Memory'**
  String get assistantEditMemorySwitchTitle;

  /// No description provided for @assistantEditRecentChatsSwitchTitle.
  ///
  /// In en, this message translates to:
  /// **'Include Recent Chats'**
  String get assistantEditRecentChatsSwitchTitle;

  /// No description provided for @assistantEditManageMemoryTitle.
  ///
  /// In en, this message translates to:
  /// **'Manage Memories'**
  String get assistantEditManageMemoryTitle;

  /// No description provided for @assistantEditAddMemoryButton.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get assistantEditAddMemoryButton;

  /// No description provided for @assistantEditMemoryEmpty.
  ///
  /// In en, this message translates to:
  /// **'No memories yet.'**
  String get assistantEditMemoryEmpty;

  /// No description provided for @assistantEditManageSummariesTitle.
  ///
  /// In en, this message translates to:
  /// **'Conversation Summaries'**
  String get assistantEditManageSummariesTitle;

  /// No description provided for @assistantEditSummaryEmpty.
  ///
  /// In en, this message translates to:
  /// **'No summaries available.'**
  String get assistantEditSummaryEmpty;

  /// No description provided for @assistantEditDeleteSummaryTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete Summary'**
  String get assistantEditDeleteSummaryTitle;

  /// No description provided for @assistantEditDeleteSummaryContent.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete this summary?'**
  String get assistantEditDeleteSummaryContent;

  /// No description provided for @assistantEditClearButton.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get assistantEditClearButton;

  /// No description provided for @assistantEditSummaryDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit Summary'**
  String get assistantEditSummaryDialogTitle;

  /// No description provided for @assistantEditSummaryDialogHint.
  ///
  /// In en, this message translates to:
  /// **'Enter summary...'**
  String get assistantEditSummaryDialogHint;

  /// No description provided for @assistantEditCustomHeadersTitle.
  ///
  /// In en, this message translates to:
  /// **'Custom Headers'**
  String get assistantEditCustomHeadersTitle;

  /// No description provided for @assistantEditCustomHeadersAdd.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get assistantEditCustomHeadersAdd;

  /// No description provided for @assistantEditCustomHeadersEmpty.
  ///
  /// In en, this message translates to:
  /// **'No custom headers.'**
  String get assistantEditCustomHeadersEmpty;

  /// No description provided for @assistantEditCustomBodyTitle.
  ///
  /// In en, this message translates to:
  /// **'Custom Body'**
  String get assistantEditCustomBodyTitle;

  /// No description provided for @assistantEditCustomBodyAdd.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get assistantEditCustomBodyAdd;

  /// No description provided for @assistantEditCustomBodyEmpty.
  ///
  /// In en, this message translates to:
  /// **'No custom body fields.'**
  String get assistantEditCustomBodyEmpty;

  /// No description provided for @assistantEditHeaderNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Header Name'**
  String get assistantEditHeaderNameLabel;

  /// No description provided for @assistantEditHeaderValueLabel.
  ///
  /// In en, this message translates to:
  /// **'Value'**
  String get assistantEditHeaderValueLabel;

  /// No description provided for @assistantEditBodyKeyLabel.
  ///
  /// In en, this message translates to:
  /// **'Key'**
  String get assistantEditBodyKeyLabel;

  /// No description provided for @assistantEditBodyValueLabel.
  ///
  /// In en, this message translates to:
  /// **'Value'**
  String get assistantEditBodyValueLabel;

  /// No description provided for @assistantEditAssistantNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Assistant Name'**
  String get assistantEditAssistantNameLabel;

  /// No description provided for @assistantEditContextMessagesTitle.
  ///
  /// In en, this message translates to:
  /// **'Context Messages'**
  String get assistantEditContextMessagesTitle;

  /// No description provided for @assistantEditContextMessagesDescription.
  ///
  /// In en, this message translates to:
  /// **'Number of previous messages to include'**
  String get assistantEditContextMessagesDescription;

  /// No description provided for @assistantEditThinkingBudgetTitle.
  ///
  /// In en, this message translates to:
  /// **'Thinking Budget'**
  String get assistantEditThinkingBudgetTitle;

  /// No description provided for @assistantEditMaxTokensTitle.
  ///
  /// In en, this message translates to:
  /// **'Max Tokens'**
  String get assistantEditMaxTokensTitle;

  /// No description provided for @assistantEditMaxTokensHint.
  ///
  /// In en, this message translates to:
  /// **'Unlimited'**
  String get assistantEditMaxTokensHint;

  /// No description provided for @assistantEditUseAssistantAvatarTitle.
  ///
  /// In en, this message translates to:
  /// **'Use Assistant Avatar'**
  String get assistantEditUseAssistantAvatarTitle;

  /// No description provided for @assistantEditStreamOutputTitle.
  ///
  /// In en, this message translates to:
  /// **'Stream Output'**
  String get assistantEditStreamOutputTitle;

  /// No description provided for @assistantEditChatModelTitle.
  ///
  /// In en, this message translates to:
  /// **'Chat Model'**
  String get assistantEditChatModelTitle;

  /// No description provided for @assistantEditChatModelSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Override default model'**
  String get assistantEditChatModelSubtitle;

  /// No description provided for @assistantEditModelUseGlobalDefault.
  ///
  /// In en, this message translates to:
  /// **'Use Global Default'**
  String get assistantEditModelUseGlobalDefault;

  /// No description provided for @assistantEditChatBackgroundTitle.
  ///
  /// In en, this message translates to:
  /// **'Chat Background'**
  String get assistantEditChatBackgroundTitle;

  /// No description provided for @assistantEditChatBackgroundDescription.
  ///
  /// In en, this message translates to:
  /// **'Set a custom background for this assistant'**
  String get assistantEditChatBackgroundDescription;

  /// No description provided for @assistantEditChooseImageButton.
  ///
  /// In en, this message translates to:
  /// **'Choose Image'**
  String get assistantEditChooseImageButton;

  /// No description provided for @assistantEditAvatarChooseImage.
  ///
  /// In en, this message translates to:
  /// **'Local Image'**
  String get assistantEditAvatarChooseImage;

  /// No description provided for @assistantEditAvatarChooseEmoji.
  ///
  /// In en, this message translates to:
  /// **'Emoji'**
  String get assistantEditAvatarChooseEmoji;

  /// No description provided for @assistantEditAvatarEnterLink.
  ///
  /// In en, this message translates to:
  /// **'Image URL'**
  String get assistantEditAvatarEnterLink;

  /// No description provided for @assistantEditAvatarReset.
  ///
  /// In en, this message translates to:
  /// **'Reset to Default'**
  String get assistantEditAvatarReset;

  /// No description provided for @assistantEditImageUrlDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Image URL'**
  String get assistantEditImageUrlDialogTitle;

  /// No description provided for @assistantEditImageUrlDialogHint.
  ///
  /// In en, this message translates to:
  /// **'Enter image link'**
  String get assistantEditImageUrlDialogHint;

  /// No description provided for @assistantEditParameterDisabled.
  ///
  /// In en, this message translates to:
  /// **'Not set'**
  String get assistantEditParameterDisabled;

  /// No description provided for @assistantEditParameterDisabled2.
  ///
  /// In en, this message translates to:
  /// **'Default'**
  String get assistantEditParameterDisabled2;

  /// No description provided for @assistantTagsContextMenuEditAssistant.
  ///
  /// In en, this message translates to:
  /// **'Edit Assistant'**
  String get assistantTagsContextMenuEditAssistant;

  /// No description provided for @assistantTagsClearTag.
  ///
  /// In en, this message translates to:
  /// **'Clear Tag'**
  String get assistantTagsClearTag;

  /// No description provided for @assistantTagsContextMenuManageTags.
  ///
  /// In en, this message translates to:
  /// **'Manage Tags'**
  String get assistantTagsContextMenuManageTags;

  /// No description provided for @assistantTagsContextMenuDeleteAssistant.
  ///
  /// In en, this message translates to:
  /// **'Delete Assistant'**
  String get assistantTagsContextMenuDeleteAssistant;

  /// No description provided for @assistantSettingsDeleteDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete Assistant'**
  String get assistantSettingsDeleteDialogTitle;

  /// No description provided for @assistantSettingsDeleteDialogContent.
  ///
  /// In en, this message translates to:
  /// **'Are you sure? This will delete the assistant and its settings.'**
  String get assistantSettingsDeleteDialogContent;

  /// No description provided for @assistantSettingsDeleteDialogCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get assistantSettingsDeleteDialogCancel;

  /// No description provided for @assistantSettingsDeleteDialogConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get assistantSettingsDeleteDialogConfirm;

  /// No description provided for @assistantSettingsAtLeastOneAssistantRequired.
  ///
  /// In en, this message translates to:
  /// **'Cannot delete the last assistant.'**
  String get assistantSettingsAtLeastOneAssistantRequired;

  /// No description provided for @assistantSettingsCopySuccess.
  ///
  /// In en, this message translates to:
  /// **'Assistant copied successfully'**
  String get assistantSettingsCopySuccess;

  /// No description provided for @assistantSettingsNoPromptPlaceholder.
  ///
  /// In en, this message translates to:
  /// **'No system prompt set'**
  String get assistantSettingsNoPromptPlaceholder;

  /// No description provided for @assistantSettingsAddSheetTitle.
  ///
  /// In en, this message translates to:
  /// **'New Assistant'**
  String get assistantSettingsAddSheetTitle;

  /// No description provided for @assistantSettingsAddSheetHint.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get assistantSettingsAddSheetHint;

  /// No description provided for @assistantSettingsAddSheetCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get assistantSettingsAddSheetCancel;

  /// No description provided for @assistantSettingsAddSheetSave.
  ///
  /// In en, this message translates to:
  /// **'Create'**
  String get assistantSettingsAddSheetSave;

  /// No description provided for @assistantSettingsDefaultTag.
  ///
  /// In en, this message translates to:
  /// **'Default'**
  String get assistantSettingsDefaultTag;

  /// No description provided for @backupPageUsername.
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get backupPageUsername;

  /// No description provided for @androidBackgroundNotificationTitle.
  ///
  /// In en, this message translates to:
  /// **'OmniChat is running'**
  String get androidBackgroundNotificationTitle;

  /// No description provided for @androidBackgroundNotificationText.
  ///
  /// In en, this message translates to:
  /// **'Keeping chat alive in background'**
  String get androidBackgroundNotificationText;

  /// No description provided for @chatServiceDefaultConversationTitle.
  ///
  /// In en, this message translates to:
  /// **'New Chat'**
  String get chatServiceDefaultConversationTitle;

  /// No description provided for @userProviderDefaultUserName.
  ///
  /// In en, this message translates to:
  /// **'User'**
  String get userProviderDefaultUserName;

  /// No description provided for @homePageDropToUpload.
  ///
  /// In en, this message translates to:
  /// **'Drop files to upload'**
  String get homePageDropToUpload;

  /// No description provided for @homePageDeleteMessage.
  ///
  /// In en, this message translates to:
  /// **'Delete Message'**
  String get homePageDeleteMessage;

  /// No description provided for @homePageDeleteMessageConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete this message?'**
  String get homePageDeleteMessageConfirm;

  /// No description provided for @desktopTrayMenuShowWindow.
  ///
  /// In en, this message translates to:
  /// **'Show Window'**
  String get desktopTrayMenuShowWindow;

  /// No description provided for @desktopTrayMenuExit.
  ///
  /// In en, this message translates to:
  /// **'Exit'**
  String get desktopTrayMenuExit;

  /// No description provided for @assistantProviderDefaultAssistantName.
  ///
  /// In en, this message translates to:
  /// **'Default Assistant'**
  String get assistantProviderDefaultAssistantName;

  /// No description provided for @assistantProviderSampleAssistantName.
  ///
  /// In en, this message translates to:
  /// **'Sample Assistant'**
  String get assistantProviderSampleAssistantName;

  /// No description provided for @assistantProviderSampleAssistantSystemPrompt.
  ///
  /// In en, this message translates to:
  /// **'You are {model_name}, a helpful AI. Time: {cur_datetime}'**
  String assistantProviderSampleAssistantSystemPrompt(
    String model_name,
    String cur_datetime,
    String locale,
    String timezone,
    String device_info,
    String system_version,
  );

  /// No description provided for @assistantSettingsCopySuffix.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get assistantSettingsCopySuffix;

  /// No description provided for @assistantProviderNewAssistantName.
  ///
  /// In en, this message translates to:
  /// **'New Assistant'**
  String get assistantProviderNewAssistantName;

  /// No description provided for @searchSettingsSheetBuiltinSearchTitle.
  ///
  /// In en, this message translates to:
  /// **'Built-in Search'**
  String get searchSettingsSheetBuiltinSearchTitle;

  /// No description provided for @reasoningBudgetSheetOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get reasoningBudgetSheetOff;

  /// No description provided for @reasoningBudgetSheetAuto.
  ///
  /// In en, this message translates to:
  /// **'Auto'**
  String get reasoningBudgetSheetAuto;

  /// No description provided for @reasoningBudgetSheetLight.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get reasoningBudgetSheetLight;

  /// No description provided for @reasoningBudgetSheetMedium.
  ///
  /// In en, this message translates to:
  /// **'Medium'**
  String get reasoningBudgetSheetMedium;

  /// No description provided for @reasoningBudgetSheetHeavy.
  ///
  /// In en, this message translates to:
  /// **'Heavy'**
  String get reasoningBudgetSheetHeavy;

  /// No description provided for @instructionInjectionDefaultTitle.
  ///
  /// In en, this message translates to:
  /// **'Default'**
  String get instructionInjectionDefaultTitle;

  /// No description provided for @bottomToolsSheetCamera.
  ///
  /// In en, this message translates to:
  /// **'Camera'**
  String get bottomToolsSheetCamera;

  /// No description provided for @bottomToolsSheetPhotos.
  ///
  /// In en, this message translates to:
  /// **'Photos'**
  String get bottomToolsSheetPhotos;

  /// No description provided for @bottomToolsSheetUpload.
  ///
  /// In en, this message translates to:
  /// **'Upload'**
  String get bottomToolsSheetUpload;

  /// No description provided for @instructionInjectionTitle.
  ///
  /// In en, this message translates to:
  /// **'Instruction Injection'**
  String get instructionInjectionTitle;

  /// No description provided for @bottomToolsSheetOcr.
  ///
  /// In en, this message translates to:
  /// **'OCR'**
  String get bottomToolsSheetOcr;

  /// No description provided for @bottomToolsSheetClearContext.
  ///
  /// In en, this message translates to:
  /// **'Clear Context'**
  String get bottomToolsSheetClearContext;

  /// No description provided for @instructionInjectionEditTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get instructionInjectionEditTitle;

  /// No description provided for @instructionInjectionNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get instructionInjectionNameLabel;

  /// No description provided for @instructionInjectionPromptLabel.
  ///
  /// In en, this message translates to:
  /// **'Prompt'**
  String get instructionInjectionPromptLabel;

  /// No description provided for @quickPhraseCancelButton.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get quickPhraseCancelButton;

  /// No description provided for @quickPhraseSaveButton.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get quickPhraseSaveButton;

  /// No description provided for @searchServicesPageConfiguredStatus.
  ///
  /// In en, this message translates to:
  /// **'Configured'**
  String get searchServicesPageConfiguredStatus;

  /// No description provided for @searchServicesPageApiKeyRequiredStatus.
  ///
  /// In en, this message translates to:
  /// **'API Key Required'**
  String get searchServicesPageApiKeyRequiredStatus;

  /// No description provided for @searchServicesPageUrlRequiredStatus.
  ///
  /// In en, this message translates to:
  /// **'URL Required'**
  String get searchServicesPageUrlRequiredStatus;

  /// No description provided for @searchSettingsSheetTitle.
  ///
  /// In en, this message translates to:
  /// **'Search Settings'**
  String get searchSettingsSheetTitle;

  /// No description provided for @searchSettingsSheetWebSearchTitle.
  ///
  /// In en, this message translates to:
  /// **'Web Search'**
  String get searchSettingsSheetWebSearchTitle;

  /// No description provided for @searchSettingsSheetOpenSearchServicesTooltip.
  ///
  /// In en, this message translates to:
  /// **'Open Services'**
  String get searchSettingsSheetOpenSearchServicesTooltip;

  /// No description provided for @searchSettingsSheetNoServicesMessage.
  ///
  /// In en, this message translates to:
  /// **'No services added'**
  String get searchSettingsSheetNoServicesMessage;

  /// No description provided for @modelSelectSheetSearchHint.
  ///
  /// In en, this message translates to:
  /// **'Search models'**
  String get modelSelectSheetSearchHint;

  /// No description provided for @modelSelectSheetFavoritesSection.
  ///
  /// In en, this message translates to:
  /// **'Favorites'**
  String get modelSelectSheetFavoritesSection;

  /// No description provided for @modelSelectSheetFavoriteTooltip.
  ///
  /// In en, this message translates to:
  /// **'Favorite'**
  String get modelSelectSheetFavoriteTooltip;

  /// No description provided for @modelSelectSheetChatType.
  ///
  /// In en, this message translates to:
  /// **'Chat'**
  String get modelSelectSheetChatType;

  /// No description provided for @modelSelectSheetEmbeddingType.
  ///
  /// In en, this message translates to:
  /// **'Embedding'**
  String get modelSelectSheetEmbeddingType;

  /// No description provided for @mcpPageErrorDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'MCP Error'**
  String get mcpPageErrorDialogTitle;

  /// No description provided for @mcpPageErrorNoDetails.
  ///
  /// In en, this message translates to:
  /// **'No details'**
  String get mcpPageErrorNoDetails;

  /// No description provided for @mcpPageClose.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get mcpPageClose;

  /// No description provided for @mcpPageReconnect.
  ///
  /// In en, this message translates to:
  /// **'Reconnect'**
  String get mcpPageReconnect;

  /// No description provided for @mcpPageBackTooltip.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get mcpPageBackTooltip;

  /// No description provided for @mcpTimeoutSettingsTooltip.
  ///
  /// In en, this message translates to:
  /// **'Timeout'**
  String get mcpTimeoutSettingsTooltip;

  /// No description provided for @mcpJsonEditButtonTooltip.
  ///
  /// In en, this message translates to:
  /// **'Edit JSON'**
  String get mcpJsonEditButtonTooltip;

  /// No description provided for @mcpPageAddMcpTooltip.
  ///
  /// In en, this message translates to:
  /// **'Add MCP'**
  String get mcpPageAddMcpTooltip;

  /// No description provided for @mcpPageNoServers.
  ///
  /// In en, this message translates to:
  /// **'No servers'**
  String get mcpPageNoServers;

  /// No description provided for @mcpPageStatusConnected.
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get mcpPageStatusConnected;

  /// No description provided for @mcpPageStatusConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting'**
  String get mcpPageStatusConnecting;

  /// No description provided for @mcpPageStatusDisconnected.
  ///
  /// In en, this message translates to:
  /// **'Disconnected'**
  String get mcpPageStatusDisconnected;

  /// No description provided for @mcpTransportTagInmemory.
  ///
  /// In en, this message translates to:
  /// **'Built-in'**
  String get mcpTransportTagInmemory;

  /// No description provided for @mcpPageToolsCount.
  ///
  /// In en, this message translates to:
  /// **'{enabled}/{total} tools'**
  String mcpPageToolsCount(int enabled, int total);

  /// No description provided for @mcpPageStatusDisabled.
  ///
  /// In en, this message translates to:
  /// **'Disabled'**
  String get mcpPageStatusDisabled;

  /// No description provided for @mcpPageConnectionFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed'**
  String get mcpPageConnectionFailed;

  /// No description provided for @mcpPageDetails.
  ///
  /// In en, this message translates to:
  /// **'Details'**
  String get mcpPageDetails;

  /// No description provided for @mcpPageDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get mcpPageDelete;

  /// No description provided for @mcpPageConfirmDeleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete Server'**
  String get mcpPageConfirmDeleteTitle;

  /// No description provided for @mcpPageConfirmDeleteContent.
  ///
  /// In en, this message translates to:
  /// **'Are you sure?'**
  String get mcpPageConfirmDeleteContent;

  /// No description provided for @mcpPageCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get mcpPageCancel;

  /// No description provided for @mcpPageServerDeleted.
  ///
  /// In en, this message translates to:
  /// **'Deleted'**
  String get mcpPageServerDeleted;

  /// No description provided for @mcpPageUndo.
  ///
  /// In en, this message translates to:
  /// **'Undo'**
  String get mcpPageUndo;

  /// No description provided for @providersPageTitle.
  ///
  /// In en, this message translates to:
  /// **'Providers'**
  String get providersPageTitle;

  /// No description provided for @searchServicesPageDone.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get searchServicesPageDone;

  /// No description provided for @providersPageMultiSelectTooltip.
  ///
  /// In en, this message translates to:
  /// **'Select'**
  String get providersPageMultiSelectTooltip;

  /// No description provided for @providersPageImportTooltip.
  ///
  /// In en, this message translates to:
  /// **'Import'**
  String get providersPageImportTooltip;

  /// No description provided for @providersPageAddTooltip.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get providersPageAddTooltip;

  /// No description provided for @providersPageProviderAddedSnackbar.
  ///
  /// In en, this message translates to:
  /// **'Provider added'**
  String get providersPageProviderAddedSnackbar;

  /// No description provided for @providersPageDeleteSelectedConfirmContent.
  ///
  /// In en, this message translates to:
  /// **'Delete selected?'**
  String get providersPageDeleteSelectedConfirmContent;

  /// No description provided for @providersPageDeleteSelectedSnackbar.
  ///
  /// In en, this message translates to:
  /// **'Deleted'**
  String get providersPageDeleteSelectedSnackbar;

  /// No description provided for @providersPageEnabledStatus.
  ///
  /// In en, this message translates to:
  /// **'Enabled'**
  String get providersPageEnabledStatus;

  /// No description provided for @providersPageDisabledStatus.
  ///
  /// In en, this message translates to:
  /// **'Disabled'**
  String get providersPageDisabledStatus;

  /// No description provided for @providersPageDeleteAction.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get providersPageDeleteAction;

  /// No description provided for @providersPageExportAction.
  ///
  /// In en, this message translates to:
  /// **'Export'**
  String get providersPageExportAction;

  /// No description provided for @providersPageExportSelectedTitle.
  ///
  /// In en, this message translates to:
  /// **'Export {count} items'**
  String providersPageExportSelectedTitle(int count);

  /// No description provided for @providersPageExportCopyButton.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get providersPageExportCopyButton;

  /// No description provided for @providersPageExportCopiedSnackbar.
  ///
  /// In en, this message translates to:
  /// **'Copied'**
  String get providersPageExportCopiedSnackbar;

  /// No description provided for @providersPageExportShareButton.
  ///
  /// In en, this message translates to:
  /// **'Share'**
  String get providersPageExportShareButton;

  /// No description provided for @mcpAssistantSheetTitle.
  ///
  /// In en, this message translates to:
  /// **'MCP Assistant'**
  String get mcpAssistantSheetTitle;

  /// No description provided for @assistantEditMcpNoServersMessage.
  ///
  /// In en, this message translates to:
  /// **'No servers'**
  String get assistantEditMcpNoServersMessage;

  /// No description provided for @assistantEditMcpToolsCountTag.
  ///
  /// In en, this message translates to:
  /// **'{enabled}/{total}'**
  String assistantEditMcpToolsCountTag(String enabled, String total);

  /// No description provided for @quickPhraseBackTooltip.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get quickPhraseBackTooltip;

  /// No description provided for @quickPhraseGlobalTitle.
  ///
  /// In en, this message translates to:
  /// **'Phrases'**
  String get quickPhraseGlobalTitle;

  /// No description provided for @quickPhraseAssistantTitle.
  ///
  /// In en, this message translates to:
  /// **'Assistant Phrases'**
  String get quickPhraseAssistantTitle;

  /// No description provided for @quickPhraseAddTooltip.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get quickPhraseAddTooltip;

  /// No description provided for @quickPhraseEmptyMessage.
  ///
  /// In en, this message translates to:
  /// **'No phrases'**
  String get quickPhraseEmptyMessage;

  /// No description provided for @quickPhraseDeleteButton.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get quickPhraseDeleteButton;

  /// No description provided for @quickPhraseAddTitle.
  ///
  /// In en, this message translates to:
  /// **'Add Phrase'**
  String get quickPhraseAddTitle;

  /// No description provided for @quickPhraseEditTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit Phrase'**
  String get quickPhraseEditTitle;

  /// No description provided for @quickPhraseTitleLabel.
  ///
  /// In en, this message translates to:
  /// **'Title'**
  String get quickPhraseTitleLabel;

  /// No description provided for @quickPhraseContentLabel.
  ///
  /// In en, this message translates to:
  /// **'Content'**
  String get quickPhraseContentLabel;

  /// No description provided for @chatInputBarHint.
  ///
  /// In en, this message translates to:
  /// **'Type a message'**
  String get chatInputBarHint;

  /// No description provided for @chatInputBarInsertNewline.
  ///
  /// In en, this message translates to:
  /// **'Newline'**
  String get chatInputBarInsertNewline;

  /// No description provided for @chatInputBarSelectModelTooltip.
  ///
  /// In en, this message translates to:
  /// **'Select Model'**
  String get chatInputBarSelectModelTooltip;

  /// No description provided for @chatInputBarOnlineSearchTooltip.
  ///
  /// In en, this message translates to:
  /// **'Online Search'**
  String get chatInputBarOnlineSearchTooltip;

  /// No description provided for @chatInputBarReasoningStrengthTooltip.
  ///
  /// In en, this message translates to:
  /// **'Reasoning'**
  String get chatInputBarReasoningStrengthTooltip;

  /// No description provided for @chatInputBarMcpServersTooltip.
  ///
  /// In en, this message translates to:
  /// **'MCP'**
  String get chatInputBarMcpServersTooltip;

  /// No description provided for @chatInputBarQuickPhraseTooltip.
  ///
  /// In en, this message translates to:
  /// **'Phrases'**
  String get chatInputBarQuickPhraseTooltip;

  /// No description provided for @miniMapTooltip.
  ///
  /// In en, this message translates to:
  /// **'Minimap'**
  String get miniMapTooltip;

  /// No description provided for @chatInputBarOcrTooltip.
  ///
  /// In en, this message translates to:
  /// **'OCR'**
  String get chatInputBarOcrTooltip;

  /// No description provided for @chatInputBarMoreTooltip.
  ///
  /// In en, this message translates to:
  /// **'More'**
  String get chatInputBarMoreTooltip;

  /// No description provided for @miniMapTitle.
  ///
  /// In en, this message translates to:
  /// **'Minimap'**
  String get miniMapTitle;

  /// No description provided for @instructionInjectionSheetSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Select prompt'**
  String get instructionInjectionSheetSubtitle;

  /// No description provided for @instructionInjectionEmptyMessage.
  ///
  /// In en, this message translates to:
  /// **'Empty'**
  String get instructionInjectionEmptyMessage;

  /// No description provided for @bottomToolsSheetPrompt.
  ///
  /// In en, this message translates to:
  /// **'Prompt'**
  String get bottomToolsSheetPrompt;

  /// No description provided for @bottomToolsSheetPromptHint.
  ///
  /// In en, this message translates to:
  /// **'Enter prompt'**
  String get bottomToolsSheetPromptHint;

  /// No description provided for @bottomToolsSheetSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get bottomToolsSheetSave;

  /// No description provided for @homePageDone.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get homePageDone;

  /// No description provided for @homePageClearContext.
  ///
  /// In en, this message translates to:
  /// **'Clear Context'**
  String get homePageClearContext;

  /// No description provided for @generationInterrupted.
  ///
  /// In en, this message translates to:
  /// **'Interrupted'**
  String get generationInterrupted;

  /// No description provided for @homePagePleaseSelectModel.
  ///
  /// In en, this message translates to:
  /// **'Select model'**
  String get homePagePleaseSelectModel;

  /// No description provided for @homePageTranslating.
  ///
  /// In en, this message translates to:
  /// **'Translating'**
  String get homePageTranslating;

  /// No description provided for @homePagePleaseSetupTranslateModel.
  ///
  /// In en, this message translates to:
  /// **'Set translation model'**
  String get homePagePleaseSetupTranslateModel;

  /// No description provided for @homePageTranslateFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed: {error}'**
  String homePageTranslateFailed(String error);

  /// No description provided for @desktopTtsPleaseAddProvider.
  ///
  /// In en, this message translates to:
  /// **'Add TTS provider'**
  String get desktopTtsPleaseAddProvider;

  /// No description provided for @homePageSelectMessagesToShare.
  ///
  /// In en, this message translates to:
  /// **'Select messages'**
  String get homePageSelectMessagesToShare;

  /// No description provided for @homePageClearContextWithCount.
  ///
  /// In en, this message translates to:
  /// **'Clear ({actual}/{configured})'**
  String homePageClearContextWithCount(String actual, String configured);

  /// No description provided for @titleForLocale.
  ///
  /// In en, this message translates to:
  /// **'New Chat'**
  String get titleForLocale;

  /// No description provided for @homePageDefaultAssistant.
  ///
  /// In en, this message translates to:
  /// **'Assistant'**
  String get homePageDefaultAssistant;

  /// No description provided for @voiceChatButtonTooltip.
  ///
  /// In en, this message translates to:
  /// **'Voice'**
  String get voiceChatButtonTooltip;

  /// No description provided for @voiceChatErrorInitFailed.
  ///
  /// In en, this message translates to:
  /// **'Init failed'**
  String get voiceChatErrorInitFailed;

  /// No description provided for @voiceChatError.
  ///
  /// In en, this message translates to:
  /// **'Error: {error}'**
  String voiceChatError(String error);

  /// No description provided for @voiceChatProcessing.
  ///
  /// In en, this message translates to:
  /// **'Thinking'**
  String get voiceChatProcessing;

  /// No description provided for @voiceChatErrorApi.
  ///
  /// In en, this message translates to:
  /// **'API: {error}'**
  String voiceChatErrorApi(String error);

  /// No description provided for @voiceChatErrorProcessingResponse.
  ///
  /// In en, this message translates to:
  /// **'Parse error: {error}'**
  String voiceChatErrorProcessingResponse(String error);

  /// No description provided for @voiceChatErrorTts.
  ///
  /// In en, this message translates to:
  /// **'TTS: {error}'**
  String voiceChatErrorTts(String error);

  /// No description provided for @voiceChatErrorNoModel.
  ///
  /// In en, this message translates to:
  /// **'No model'**
  String get voiceChatErrorNoModel;

  /// No description provided for @voiceChatErrorNoConversation.
  ///
  /// In en, this message translates to:
  /// **'No chat'**
  String get voiceChatErrorNoConversation;

  /// No description provided for @voiceChatErrorNoActiveConversation.
  ///
  /// In en, this message translates to:
  /// **'Inactive'**
  String get voiceChatErrorNoActiveConversation;

  /// No description provided for @voiceChatTitle.
  ///
  /// In en, this message translates to:
  /// **'Voice'**
  String get voiceChatTitle;

  /// No description provided for @voiceChatPermissionRequired.
  ///
  /// In en, this message translates to:
  /// **'Permission Required'**
  String get voiceChatPermissionRequired;

  /// No description provided for @voiceChatPermissionSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Microphone access needed'**
  String get voiceChatPermissionSubtitle;

  /// No description provided for @voiceChatPermissionButton.
  ///
  /// In en, this message translates to:
  /// **'Grant'**
  String get voiceChatPermissionButton;

  /// No description provided for @voiceChatListening.
  ///
  /// In en, this message translates to:
  /// **'Listening'**
  String get voiceChatListening;

  /// No description provided for @voiceChatThinking.
  ///
  /// In en, this message translates to:
  /// **'Thinking'**
  String get voiceChatThinking;

  /// No description provided for @voiceChatTalking.
  ///
  /// In en, this message translates to:
  /// **'Talking'**
  String get voiceChatTalking;

  /// No description provided for @defaultModelPagePromptLabel.
  ///
  /// In en, this message translates to:
  /// **'Prompt'**
  String get defaultModelPagePromptLabel;

  /// No description provided for @defaultModelPageOcrPromptHint.
  ///
  /// In en, this message translates to:
  /// **'OCR Prompt'**
  String get defaultModelPageOcrPromptHint;

  /// No description provided for @defaultModelPageResetDefault.
  ///
  /// In en, this message translates to:
  /// **'Reset'**
  String get defaultModelPageResetDefault;

  /// No description provided for @defaultModelPageSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get defaultModelPageSave;

  /// No description provided for @searchServicesPageBackTooltip.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get searchServicesPageBackTooltip;

  /// No description provided for @searchServicesPageTitle.
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get searchServicesPageTitle;

  /// No description provided for @searchServicesPageAddProvider.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get searchServicesPageAddProvider;

  /// No description provided for @searchServicesPageSearchProviders.
  ///
  /// In en, this message translates to:
  /// **'Providers'**
  String get searchServicesPageSearchProviders;

  /// No description provided for @searchServicesPageGeneralOptions.
  ///
  /// In en, this message translates to:
  /// **'General'**
  String get searchServicesPageGeneralOptions;

  /// No description provided for @searchServicesPageAutoTestTitle.
  ///
  /// In en, this message translates to:
  /// **'Auto test'**
  String get searchServicesPageAutoTestTitle;

  /// No description provided for @searchServicesPageMaxResults.
  ///
  /// In en, this message translates to:
  /// **'Max results'**
  String get searchServicesPageMaxResults;

  /// No description provided for @searchServicesPageTimeoutSeconds.
  ///
  /// In en, this message translates to:
  /// **'Timeout'**
  String get searchServicesPageTimeoutSeconds;

  /// No description provided for @searchServicesPageTestingStatus.
  ///
  /// In en, this message translates to:
  /// **'Testing'**
  String get searchServicesPageTestingStatus;

  /// No description provided for @searchServicesPageConnectedStatus.
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get searchServicesPageConnectedStatus;

  /// No description provided for @searchServicesPageFailedStatus.
  ///
  /// In en, this message translates to:
  /// **'Failed'**
  String get searchServicesPageFailedStatus;

  /// No description provided for @searchServicesPageNotTestedStatus.
  ///
  /// In en, this message translates to:
  /// **'Not tested'**
  String get searchServicesPageNotTestedStatus;

  /// No description provided for @searchServicesPageTestConnectionTooltip.
  ///
  /// In en, this message translates to:
  /// **'Test'**
  String get searchServicesPageTestConnectionTooltip;

  /// No description provided for @searchServicesAddDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get searchServicesAddDialogTitle;

  /// No description provided for @searchServiceNameBingLocal.
  ///
  /// In en, this message translates to:
  /// **'Bing'**
  String get searchServiceNameBingLocal;

  /// No description provided for @searchServiceNameDuckDuckGo.
  ///
  /// In en, this message translates to:
  /// **'DuckDuckGo'**
  String get searchServiceNameDuckDuckGo;

  /// No description provided for @searchServiceNameTavily.
  ///
  /// In en, this message translates to:
  /// **'Tavily'**
  String get searchServiceNameTavily;

  /// No description provided for @searchServiceNameExa.
  ///
  /// In en, this message translates to:
  /// **'Exa'**
  String get searchServiceNameExa;

  /// No description provided for @searchServiceNameZhipu.
  ///
  /// In en, this message translates to:
  /// **'Zhipu'**
  String get searchServiceNameZhipu;

  /// No description provided for @searchServiceNameSearXNG.
  ///
  /// In en, this message translates to:
  /// **'SearXNG'**
  String get searchServiceNameSearXNG;

  /// No description provided for @searchServiceNameLinkUp.
  ///
  /// In en, this message translates to:
  /// **'LinkUp'**
  String get searchServiceNameLinkUp;

  /// No description provided for @searchServiceNameBrave.
  ///
  /// In en, this message translates to:
  /// **'Brave'**
  String get searchServiceNameBrave;

  /// No description provided for @searchServiceNameMetaso.
  ///
  /// In en, this message translates to:
  /// **'Metaso'**
  String get searchServiceNameMetaso;

  /// No description provided for @searchServiceNameJina.
  ///
  /// In en, this message translates to:
  /// **'Jina'**
  String get searchServiceNameJina;

  /// No description provided for @searchServiceNameOllama.
  ///
  /// In en, this message translates to:
  /// **'Ollama'**
  String get searchServiceNameOllama;

  /// No description provided for @searchServiceNamePerplexity.
  ///
  /// In en, this message translates to:
  /// **'Perplexity'**
  String get searchServiceNamePerplexity;

  /// No description provided for @searchServiceNameBocha.
  ///
  /// In en, this message translates to:
  /// **'Bocha'**
  String get searchServiceNameBocha;

  /// No description provided for @searchServicesAddDialogAdd.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get searchServicesAddDialogAdd;

  /// No description provided for @searchServicesAddDialogRegionOptional.
  ///
  /// In en, this message translates to:
  /// **'Region'**
  String get searchServicesAddDialogRegionOptional;

  /// No description provided for @searchServicesAddDialogApiKeyRequired.
  ///
  /// In en, this message translates to:
  /// **'Key required'**
  String get searchServicesAddDialogApiKeyRequired;

  /// No description provided for @searchServicesAddDialogInstanceUrl.
  ///
  /// In en, this message translates to:
  /// **'URL'**
  String get searchServicesAddDialogInstanceUrl;

  /// No description provided for @searchServicesAddDialogUrlRequired.
  ///
  /// In en, this message translates to:
  /// **'URL required'**
  String get searchServicesAddDialogUrlRequired;

  /// No description provided for @searchServicesAddDialogEnginesOptional.
  ///
  /// In en, this message translates to:
  /// **'Engines'**
  String get searchServicesAddDialogEnginesOptional;

  /// No description provided for @searchServicesAddDialogLanguageOptional.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get searchServicesAddDialogLanguageOptional;

  /// No description provided for @searchServicesAddDialogUsernameOptional.
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get searchServicesAddDialogUsernameOptional;

  /// No description provided for @searchServicesAddDialogPasswordOptional.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get searchServicesAddDialogPasswordOptional;

  /// No description provided for @searchServicesEditDialogSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get searchServicesEditDialogSave;

  /// No description provided for @searchServicesEditDialogBingLocalNoConfig.
  ///
  /// In en, this message translates to:
  /// **'No config needed'**
  String get searchServicesEditDialogBingLocalNoConfig;

  /// No description provided for @searchServicesEditDialogRegionOptional.
  ///
  /// In en, this message translates to:
  /// **'Region'**
  String get searchServicesEditDialogRegionOptional;

  /// No description provided for @searchServicesEditDialogApiKeyRequired.
  ///
  /// In en, this message translates to:
  /// **'Key required'**
  String get searchServicesEditDialogApiKeyRequired;

  /// No description provided for @searchServicesEditDialogInstanceUrl.
  ///
  /// In en, this message translates to:
  /// **'URL'**
  String get searchServicesEditDialogInstanceUrl;

  /// No description provided for @searchServicesEditDialogUrlRequired.
  ///
  /// In en, this message translates to:
  /// **'URL required'**
  String get searchServicesEditDialogUrlRequired;

  /// No description provided for @searchServicesEditDialogEnginesOptional.
  ///
  /// In en, this message translates to:
  /// **'Engines'**
  String get searchServicesEditDialogEnginesOptional;

  /// No description provided for @searchServicesEditDialogLanguageOptional.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get searchServicesEditDialogLanguageOptional;

  /// No description provided for @searchServicesEditDialogUsernameOptional.
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get searchServicesEditDialogUsernameOptional;

  /// No description provided for @searchServicesEditDialogPasswordOptional.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get searchServicesEditDialogPasswordOptional;

  /// No description provided for @modelDetailSheetCancelButton.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get modelDetailSheetCancelButton;

  /// No description provided for @modelDetailSheetAddModel.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get modelDetailSheetAddModel;

  /// No description provided for @modelDetailSheetEditModel.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get modelDetailSheetEditModel;

  /// No description provided for @modelDetailSheetBasicTab.
  ///
  /// In en, this message translates to:
  /// **'Basic'**
  String get modelDetailSheetBasicTab;

  /// No description provided for @modelDetailSheetAdvancedTab.
  ///
  /// In en, this message translates to:
  /// **'Advanced'**
  String get modelDetailSheetAdvancedTab;

  /// No description provided for @modelDetailSheetBuiltinToolsTab.
  ///
  /// In en, this message translates to:
  /// **'Tools'**
  String get modelDetailSheetBuiltinToolsTab;

  /// No description provided for @modelDetailSheetModelIdLabel.
  ///
  /// In en, this message translates to:
  /// **'ID'**
  String get modelDetailSheetModelIdLabel;

  /// No description provided for @modelDetailSheetModelIdHint.
  ///
  /// In en, this message translates to:
  /// **'Model ID'**
  String get modelDetailSheetModelIdHint;

  /// No description provided for @shareProviderSheetCopyButton.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get shareProviderSheetCopyButton;

  /// No description provided for @shareProviderSheetCopiedMessage.
  ///
  /// In en, this message translates to:
  /// **'Copied'**
  String get shareProviderSheetCopiedMessage;

  /// No description provided for @modelDetailSheetModelNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get modelDetailSheetModelNameLabel;

  /// No description provided for @modelDetailSheetModelTypeLabel.
  ///
  /// In en, this message translates to:
  /// **'Type'**
  String get modelDetailSheetModelTypeLabel;

  /// No description provided for @modelDetailSheetInputModesLabel.
  ///
  /// In en, this message translates to:
  /// **'Input'**
  String get modelDetailSheetInputModesLabel;

  /// No description provided for @modelDetailSheetTextMode.
  ///
  /// In en, this message translates to:
  /// **'Text'**
  String get modelDetailSheetTextMode;

  /// No description provided for @modelDetailSheetImageMode.
  ///
  /// In en, this message translates to:
  /// **'Image'**
  String get modelDetailSheetImageMode;

  /// No description provided for @modelDetailSheetOutputModesLabel.
  ///
  /// In en, this message translates to:
  /// **'Output'**
  String get modelDetailSheetOutputModesLabel;

  /// No description provided for @modelDetailSheetAbilitiesLabel.
  ///
  /// In en, this message translates to:
  /// **'Abilities'**
  String get modelDetailSheetAbilitiesLabel;

  /// No description provided for @modelDetailSheetToolsAbility.
  ///
  /// In en, this message translates to:
  /// **'Tools'**
  String get modelDetailSheetToolsAbility;

  /// No description provided for @modelDetailSheetReasoningAbility.
  ///
  /// In en, this message translates to:
  /// **'Reasoning'**
  String get modelDetailSheetReasoningAbility;

  /// No description provided for @modelDetailSheetProviderOverrideDescription.
  ///
  /// In en, this message translates to:
  /// **'Overrides'**
  String get modelDetailSheetProviderOverrideDescription;

  /// No description provided for @modelDetailSheetAddProviderOverride.
  ///
  /// In en, this message translates to:
  /// **'Add Override'**
  String get modelDetailSheetAddProviderOverride;

  /// No description provided for @modelDetailSheetCustomHeadersTitle.
  ///
  /// In en, this message translates to:
  /// **'Headers'**
  String get modelDetailSheetCustomHeadersTitle;

  /// No description provided for @modelDetailSheetAddHeader.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get modelDetailSheetAddHeader;

  /// No description provided for @modelDetailSheetCustomBodyTitle.
  ///
  /// In en, this message translates to:
  /// **'Body'**
  String get modelDetailSheetCustomBodyTitle;

  /// No description provided for @modelDetailSheetAddBody.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get modelDetailSheetAddBody;

  /// No description provided for @modelDetailSheetBuiltinToolsDescription.
  ///
  /// In en, this message translates to:
  /// **'Built-in'**
  String get modelDetailSheetBuiltinToolsDescription;

  /// No description provided for @modelDetailSheetGeminiCodeExecutionMutuallyExclusiveHint.
  ///
  /// In en, this message translates to:
  /// **'Exclusive'**
  String get modelDetailSheetGeminiCodeExecutionMutuallyExclusiveHint;

  /// No description provided for @modelDetailSheetUrlContextTool.
  ///
  /// In en, this message translates to:
  /// **'URL'**
  String get modelDetailSheetUrlContextTool;

  /// No description provided for @modelDetailSheetUrlContextToolDescription.
  ///
  /// In en, this message translates to:
  /// **'URL Context'**
  String get modelDetailSheetUrlContextToolDescription;

  /// No description provided for @modelDetailSheetCodeExecutionTool.
  ///
  /// In en, this message translates to:
  /// **'Code'**
  String get modelDetailSheetCodeExecutionTool;

  /// No description provided for @modelDetailSheetCodeExecutionToolDescription.
  ///
  /// In en, this message translates to:
  /// **'Execute code'**
  String get modelDetailSheetCodeExecutionToolDescription;

  /// No description provided for @modelDetailSheetYoutubeTool.
  ///
  /// In en, this message translates to:
  /// **'YouTube'**
  String get modelDetailSheetYoutubeTool;

  /// No description provided for @modelDetailSheetYoutubeToolDescription.
  ///
  /// In en, this message translates to:
  /// **'Video context'**
  String get modelDetailSheetYoutubeToolDescription;

  /// No description provided for @modelDetailSheetOpenaiBuiltinToolsResponsesOnlyHint.
  ///
  /// In en, this message translates to:
  /// **'OpenAI only'**
  String get modelDetailSheetOpenaiBuiltinToolsResponsesOnlyHint;

  /// No description provided for @modelDetailSheetOpenaiCodeInterpreterTool.
  ///
  /// In en, this message translates to:
  /// **'Interpreter'**
  String get modelDetailSheetOpenaiCodeInterpreterTool;

  /// No description provided for @modelDetailSheetOpenaiCodeInterpreterToolDescription.
  ///
  /// In en, this message translates to:
  /// **'Code interpreter'**
  String get modelDetailSheetOpenaiCodeInterpreterToolDescription;

  /// No description provided for @modelDetailSheetOpenaiImageGenerationTool.
  ///
  /// In en, this message translates to:
  /// **'Image'**
  String get modelDetailSheetOpenaiImageGenerationTool;

  /// No description provided for @modelDetailSheetOpenaiImageGenerationToolDescription.
  ///
  /// In en, this message translates to:
  /// **'DALL-E'**
  String get modelDetailSheetOpenaiImageGenerationToolDescription;

  /// No description provided for @modelDetailSheetBuiltinToolsUnsupportedHint.
  ///
  /// In en, this message translates to:
  /// **'Unsupported'**
  String get modelDetailSheetBuiltinToolsUnsupportedHint;

  /// No description provided for @modelDetailSheetAddButton.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get modelDetailSheetAddButton;

  /// No description provided for @modelDetailSheetConfirmButton.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get modelDetailSheetConfirmButton;

  /// No description provided for @modelDetailSheetInvalidIdError.
  ///
  /// In en, this message translates to:
  /// **'Invalid ID'**
  String get modelDetailSheetInvalidIdError;

  /// No description provided for @modelDetailSheetHeaderKeyHint.
  ///
  /// In en, this message translates to:
  /// **'Key'**
  String get modelDetailSheetHeaderKeyHint;

  /// No description provided for @modelDetailSheetHeaderValueHint.
  ///
  /// In en, this message translates to:
  /// **'Value'**
  String get modelDetailSheetHeaderValueHint;

  /// No description provided for @modelDetailSheetBodyKeyHint.
  ///
  /// In en, this message translates to:
  /// **'Key'**
  String get modelDetailSheetBodyKeyHint;

  /// No description provided for @modelDetailSheetBodyJsonHint.
  ///
  /// In en, this message translates to:
  /// **'JSON'**
  String get modelDetailSheetBodyJsonHint;

  /// No description provided for @providerDetailPageShareTooltip.
  ///
  /// In en, this message translates to:
  /// **'Share'**
  String get providerDetailPageShareTooltip;

  /// No description provided for @providerDetailPageDeleteProviderTooltip.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get providerDetailPageDeleteProviderTooltip;

  /// No description provided for @providerDetailPageProviderDeletedSnackbar.
  ///
  /// In en, this message translates to:
  /// **'Deleted'**
  String get providerDetailPageProviderDeletedSnackbar;

  /// No description provided for @providerDetailPageConfigTab.
  ///
  /// In en, this message translates to:
  /// **'Config'**
  String get providerDetailPageConfigTab;

  /// No description provided for @providerDetailPageModelsTab.
  ///
  /// In en, this message translates to:
  /// **'Models'**
  String get providerDetailPageModelsTab;

  /// No description provided for @providerDetailPageNetworkTab.
  ///
  /// In en, this message translates to:
  /// **'Network'**
  String get providerDetailPageNetworkTab;

  /// No description provided for @providerDetailPageEnabledTitle.
  ///
  /// In en, this message translates to:
  /// **'Enabled'**
  String get providerDetailPageEnabledTitle;

  /// No description provided for @providerDetailPageManageSectionTitle.
  ///
  /// In en, this message translates to:
  /// **'Manage'**
  String get providerDetailPageManageSectionTitle;

  /// No description provided for @providerDetailPageNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get providerDetailPageNameLabel;

  /// No description provided for @providerDetailPageHideTooltip.
  ///
  /// In en, this message translates to:
  /// **'Hide'**
  String get providerDetailPageHideTooltip;

  /// No description provided for @providerDetailPageShowTooltip.
  ///
  /// In en, this message translates to:
  /// **'Show'**
  String get providerDetailPageShowTooltip;

  /// No description provided for @providerDetailPageProviderRemovedMessage.
  ///
  /// In en, this message translates to:
  /// **'Removed'**
  String get providerDetailPageProviderRemovedMessage;

  /// No description provided for @providerDetailPageNoModelsTitle.
  ///
  /// In en, this message translates to:
  /// **'No models'**
  String get providerDetailPageNoModelsTitle;

  /// No description provided for @providerDetailPageNoModelsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Add models below'**
  String get providerDetailPageNoModelsSubtitle;

  /// No description provided for @providerDetailPageDeleteModelButton.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get providerDetailPageDeleteModelButton;

  /// No description provided for @providerDetailPageConfirmDeleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Confirm'**
  String get providerDetailPageConfirmDeleteTitle;

  /// No description provided for @providerDetailPageConfirmDeleteContent.
  ///
  /// In en, this message translates to:
  /// **'Delete?'**
  String get providerDetailPageConfirmDeleteContent;

  /// No description provided for @providerDetailPageModelDeletedSnackbar.
  ///
  /// In en, this message translates to:
  /// **'Deleted'**
  String get providerDetailPageModelDeletedSnackbar;

  /// No description provided for @providerDetailPageUndoButton.
  ///
  /// In en, this message translates to:
  /// **'Undo'**
  String get providerDetailPageUndoButton;

  /// No description provided for @providerDetailPageFetchModelsButton.
  ///
  /// In en, this message translates to:
  /// **'Fetch'**
  String get providerDetailPageFetchModelsButton;

  /// No description provided for @providerDetailPageEnableProxyTitle.
  ///
  /// In en, this message translates to:
  /// **'Proxy'**
  String get providerDetailPageEnableProxyTitle;

  /// No description provided for @providerDetailPageHostLabel.
  ///
  /// In en, this message translates to:
  /// **'Host'**
  String get providerDetailPageHostLabel;

  /// No description provided for @providerDetailPagePortLabel.
  ///
  /// In en, this message translates to:
  /// **'Port'**
  String get providerDetailPagePortLabel;

  /// No description provided for @providerDetailPageUsernameOptionalLabel.
  ///
  /// In en, this message translates to:
  /// **'User'**
  String get providerDetailPageUsernameOptionalLabel;

  /// No description provided for @providerDetailPagePasswordOptionalLabel.
  ///
  /// In en, this message translates to:
  /// **'Pass'**
  String get providerDetailPagePasswordOptionalLabel;

  /// No description provided for @providerDetailPageEmbeddingsGroupTitle.
  ///
  /// In en, this message translates to:
  /// **'Embeddings'**
  String get providerDetailPageEmbeddingsGroupTitle;

  /// No description provided for @providerDetailPageOtherModelsGroupTitle.
  ///
  /// In en, this message translates to:
  /// **'Other'**
  String get providerDetailPageOtherModelsGroupTitle;

  /// No description provided for @mcpAssistantSheetClearAll.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get mcpAssistantSheetClearAll;

  /// No description provided for @mcpAssistantSheetSelectAll.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get mcpAssistantSheetSelectAll;

  /// No description provided for @modelFetchInvertTooltip.
  ///
  /// In en, this message translates to:
  /// **'Invert'**
  String get modelFetchInvertTooltip;

  /// No description provided for @providerDetailPageRemoveGroupTooltip.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get providerDetailPageRemoveGroupTooltip;

  /// No description provided for @providerDetailPageAddGroupTooltip.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get providerDetailPageAddGroupTooltip;

  /// No description provided for @providerDetailPageDeleteText.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get providerDetailPageDeleteText;

  /// No description provided for @providerDetailPageDetectSuccess.
  ///
  /// In en, this message translates to:
  /// **'Success'**
  String get providerDetailPageDetectSuccess;

  /// No description provided for @providerDetailPageDetectFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed'**
  String get providerDetailPageDetectFailed;

  /// No description provided for @providerDetailPageEditTooltip.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get providerDetailPageEditTooltip;

  /// No description provided for @providerDetailPageTestConnectionTitle.
  ///
  /// In en, this message translates to:
  /// **'Test'**
  String get providerDetailPageTestConnectionTitle;

  /// No description provided for @providerDetailPageTestSuccessMessage.
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get providerDetailPageTestSuccessMessage;

  /// No description provided for @providerDetailPageSelectModelButton.
  ///
  /// In en, this message translates to:
  /// **'Select'**
  String get providerDetailPageSelectModelButton;

  /// No description provided for @providerDetailPageChangeButton.
  ///
  /// In en, this message translates to:
  /// **'Change'**
  String get providerDetailPageChangeButton;

  /// No description provided for @providerDetailPageTestingMessage.
  ///
  /// In en, this message translates to:
  /// **'Testing'**
  String get providerDetailPageTestingMessage;

  /// No description provided for @mcpServerEditSheetEnabledLabel.
  ///
  /// In en, this message translates to:
  /// **'Enabled'**
  String get mcpServerEditSheetEnabledLabel;

  /// No description provided for @mcpServerEditSheetNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get mcpServerEditSheetNameLabel;

  /// No description provided for @mcpServerEditSheetTransportLabel.
  ///
  /// In en, this message translates to:
  /// **'Transport'**
  String get mcpServerEditSheetTransportLabel;

  /// No description provided for @mcpServerEditSheetSseRetryHint.
  ///
  /// In en, this message translates to:
  /// **'Retry SSE'**
  String get mcpServerEditSheetSseRetryHint;

  /// No description provided for @mcpServerEditSheetUrlLabel.
  ///
  /// In en, this message translates to:
  /// **'URL'**
  String get mcpServerEditSheetUrlLabel;

  /// No description provided for @mcpServerEditSheetCustomHeadersTitle.
  ///
  /// In en, this message translates to:
  /// **'Headers'**
  String get mcpServerEditSheetCustomHeadersTitle;

  /// No description provided for @mcpServerEditSheetHeaderNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Key'**
  String get mcpServerEditSheetHeaderNameLabel;

  /// No description provided for @mcpServerEditSheetHeaderNameHint.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get mcpServerEditSheetHeaderNameHint;

  /// No description provided for @mcpServerEditSheetHeaderValueLabel.
  ///
  /// In en, this message translates to:
  /// **'Value'**
  String get mcpServerEditSheetHeaderValueLabel;

  /// No description provided for @mcpServerEditSheetHeaderValueHint.
  ///
  /// In en, this message translates to:
  /// **'Value'**
  String get mcpServerEditSheetHeaderValueHint;

  /// No description provided for @mcpServerEditSheetRemoveHeaderTooltip.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get mcpServerEditSheetRemoveHeaderTooltip;

  /// No description provided for @mcpServerEditSheetAddHeader.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get mcpServerEditSheetAddHeader;

  /// No description provided for @mcpServerEditSheetUrlRequired.
  ///
  /// In en, this message translates to:
  /// **'URL required'**
  String get mcpServerEditSheetUrlRequired;

  /// No description provided for @mcpServerEditSheetTitleEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get mcpServerEditSheetTitleEdit;

  /// No description provided for @mcpServerEditSheetTitleAdd.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get mcpServerEditSheetTitleAdd;

  /// No description provided for @mcpServerEditSheetSyncToolsTooltip.
  ///
  /// In en, this message translates to:
  /// **'Sync'**
  String get mcpServerEditSheetSyncToolsTooltip;

  /// No description provided for @mcpServerEditSheetTabBasic.
  ///
  /// In en, this message translates to:
  /// **'Basic'**
  String get mcpServerEditSheetTabBasic;

  /// No description provided for @mcpServerEditSheetTabTools.
  ///
  /// In en, this message translates to:
  /// **'Tools'**
  String get mcpServerEditSheetTabTools;

  /// No description provided for @mcpServerEditSheetNoToolsHint.
  ///
  /// In en, this message translates to:
  /// **'No tools'**
  String get mcpServerEditSheetNoToolsHint;

  /// No description provided for @mcpServerEditSheetSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get mcpServerEditSheetSave;

  /// No description provided for @mcpJsonEditParseFailed.
  ///
  /// In en, this message translates to:
  /// **'Invalid JSON'**
  String get mcpJsonEditParseFailed;

  /// No description provided for @mcpJsonEditSavedApplied.
  ///
  /// In en, this message translates to:
  /// **'Applied'**
  String get mcpJsonEditSavedApplied;

  /// No description provided for @mcpJsonEditTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit JSON'**
  String get mcpJsonEditTitle;

  /// No description provided for @mcpTimeoutInvalid.
  ///
  /// In en, this message translates to:
  /// **'Invalid'**
  String get mcpTimeoutInvalid;

  /// No description provided for @mcpTimeoutDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Timeout'**
  String get mcpTimeoutDialogTitle;

  /// No description provided for @mcpTimeoutSecondsLabel.
  ///
  /// In en, this message translates to:
  /// **'Seconds'**
  String get mcpTimeoutSecondsLabel;

  /// No description provided for @importProviderSheetTitle.
  ///
  /// In en, this message translates to:
  /// **'Import'**
  String get importProviderSheetTitle;

  /// No description provided for @importProviderSheetScanQrTooltip.
  ///
  /// In en, this message translates to:
  /// **'Scan'**
  String get importProviderSheetScanQrTooltip;

  /// No description provided for @importProviderSheetImportSuccessMessage.
  ///
  /// In en, this message translates to:
  /// **'Imported {count}'**
  String importProviderSheetImportSuccessMessage(int count);

  /// No description provided for @importProviderSheetImportFailedMessage.
  ///
  /// In en, this message translates to:
  /// **'Failed: {error}'**
  String importProviderSheetImportFailedMessage(String error);

  /// No description provided for @importProviderSheetFromGalleryTooltip.
  ///
  /// In en, this message translates to:
  /// **'Gallery'**
  String get importProviderSheetFromGalleryTooltip;

  /// No description provided for @importProviderSheetDescription.
  ///
  /// In en, this message translates to:
  /// **'Paste code'**
  String get importProviderSheetDescription;

  /// No description provided for @importProviderSheetImportButton.
  ///
  /// In en, this message translates to:
  /// **'Import'**
  String get importProviderSheetImportButton;

  /// No description provided for @addProviderSheetEnabledLabel.
  ///
  /// In en, this message translates to:
  /// **'Enabled'**
  String get addProviderSheetEnabledLabel;

  /// No description provided for @addProviderSheetNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get addProviderSheetNameLabel;

  /// No description provided for @addProviderSheetApiPathLabel.
  ///
  /// In en, this message translates to:
  /// **'Path'**
  String get addProviderSheetApiPathLabel;

  /// No description provided for @addProviderSheetVertexAiLocationLabel.
  ///
  /// In en, this message translates to:
  /// **'Location'**
  String get addProviderSheetVertexAiLocationLabel;

  /// No description provided for @addProviderSheetVertexAiProjectIdLabel.
  ///
  /// In en, this message translates to:
  /// **'Project'**
  String get addProviderSheetVertexAiProjectIdLabel;

  /// No description provided for @addProviderSheetVertexAiServiceAccountJsonLabel.
  ///
  /// In en, this message translates to:
  /// **'JSON'**
  String get addProviderSheetVertexAiServiceAccountJsonLabel;

  /// No description provided for @addProviderSheetImportJsonButton.
  ///
  /// In en, this message translates to:
  /// **'Import'**
  String get addProviderSheetImportJsonButton;

  /// No description provided for @addProviderSheetTitle.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get addProviderSheetTitle;

  /// No description provided for @shareProviderSheetTitle.
  ///
  /// In en, this message translates to:
  /// **'Share'**
  String get shareProviderSheetTitle;

  /// No description provided for @shareProviderSheetDescription.
  ///
  /// In en, this message translates to:
  /// **'Provider info'**
  String get shareProviderSheetDescription;

  /// No description provided for @chatMessageWidgetCopiedToClipboard.
  ///
  /// In en, this message translates to:
  /// **'Copied'**
  String get chatMessageWidgetCopiedToClipboard;

  /// No description provided for @messageMoreSheetEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get messageMoreSheetEdit;

  /// No description provided for @messageMoreSheetDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get messageMoreSheetDelete;

  /// No description provided for @chatMessageWidgetFileNotFound.
  ///
  /// In en, this message translates to:
  /// **'Not found: {fileName}'**
  String chatMessageWidgetFileNotFound(String fileName);

  /// No description provided for @chatMessageWidgetCannotOpenFile.
  ///
  /// In en, this message translates to:
  /// **'Error: {message}'**
  String chatMessageWidgetCannotOpenFile(String message);

  /// No description provided for @chatMessageWidgetOpenFileError.
  ///
  /// In en, this message translates to:
  /// **'Error: {error}'**
  String chatMessageWidgetOpenFileError(String error);

  /// No description provided for @chatMessageWidgetThinking.
  ///
  /// In en, this message translates to:
  /// **'Thinking'**
  String get chatMessageWidgetThinking;

  /// No description provided for @chatMessageWidgetTranslation.
  ///
  /// In en, this message translates to:
  /// **'Translation'**
  String get chatMessageWidgetTranslation;

  /// No description provided for @chatMessageWidgetCitationNotFound.
  ///
  /// In en, this message translates to:
  /// **'Not found'**
  String get chatMessageWidgetCitationNotFound;

  /// No description provided for @chatMessageWidgetCannotOpenUrl.
  ///
  /// In en, this message translates to:
  /// **'Error: {url}'**
  String chatMessageWidgetCannotOpenUrl(String url);

  /// No description provided for @chatMessageWidgetOpenLinkError.
  ///
  /// In en, this message translates to:
  /// **'Error'**
  String get chatMessageWidgetOpenLinkError;

  /// No description provided for @chatMessageWidgetCitationsTitle.
  ///
  /// In en, this message translates to:
  /// **'{count} Citations'**
  String chatMessageWidgetCitationsTitle(int count);

  /// No description provided for @chatMessageWidgetCreateMemory.
  ///
  /// In en, this message translates to:
  /// **'Remember'**
  String get chatMessageWidgetCreateMemory;

  /// No description provided for @chatMessageWidgetEditMemory.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get chatMessageWidgetEditMemory;

  /// No description provided for @chatMessageWidgetDeleteMemory.
  ///
  /// In en, this message translates to:
  /// **'Forget'**
  String get chatMessageWidgetDeleteMemory;

  /// No description provided for @chatMessageWidgetWebSearch.
  ///
  /// In en, this message translates to:
  /// **'Search: {query}'**
  String chatMessageWidgetWebSearch(String query);

  /// No description provided for @chatMessageWidgetBuiltinSearch.
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get chatMessageWidgetBuiltinSearch;

  /// No description provided for @chatMessageWidgetToolResult.
  ///
  /// In en, this message translates to:
  /// **'Result: {name}'**
  String chatMessageWidgetToolResult(String name);

  /// No description provided for @chatMessageWidgetToolCall.
  ///
  /// In en, this message translates to:
  /// **'Call: {name}'**
  String chatMessageWidgetToolCall(String name);

  /// No description provided for @chatMessageWidgetNoResultYet.
  ///
  /// In en, this message translates to:
  /// **'Waiting'**
  String get chatMessageWidgetNoResultYet;

  /// No description provided for @chatMessageWidgetArguments.
  ///
  /// In en, this message translates to:
  /// **'Args'**
  String get chatMessageWidgetArguments;

  /// No description provided for @chatMessageWidgetResult.
  ///
  /// In en, this message translates to:
  /// **'Result'**
  String get chatMessageWidgetResult;

  /// No description provided for @chatMessageWidgetCitationsCount.
  ///
  /// In en, this message translates to:
  /// **'{count} citations'**
  String chatMessageWidgetCitationsCount(int count);

  /// No description provided for @chatMessageWidgetDeepThinking.
  ///
  /// In en, this message translates to:
  /// **'Deep thinking'**
  String get chatMessageWidgetDeepThinking;

  /// No description provided for @messageMoreSheetSelectCopy.
  ///
  /// In en, this message translates to:
  /// **'Select'**
  String get messageMoreSheetSelectCopy;

  /// No description provided for @messageMoreSheetRenderWebView.
  ///
  /// In en, this message translates to:
  /// **'Web'**
  String get messageMoreSheetRenderWebView;

  /// No description provided for @messageMoreSheetShare.
  ///
  /// In en, this message translates to:
  /// **'Share'**
  String get messageMoreSheetShare;

  /// No description provided for @messageMoreSheetCreateBranch.
  ///
  /// In en, this message translates to:
  /// **'Branch'**
  String get messageMoreSheetCreateBranch;

  /// No description provided for @messageEditPageTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get messageEditPageTitle;

  /// No description provided for @messageEditPageHint.
  ///
  /// In en, this message translates to:
  /// **'Message'**
  String get messageEditPageHint;

  /// No description provided for @messageExportSheetDateTimeWithSecondsPattern.
  ///
  /// In en, this message translates to:
  /// **'yyyy-MM-dd HH:mm:ss'**
  String get messageExportSheetDateTimeWithSecondsPattern;

  /// No description provided for @backupPageExportToFile.
  ///
  /// In en, this message translates to:
  /// **'Export'**
  String get backupPageExportToFile;

  /// No description provided for @messageExportSheetMarkdown.
  ///
  /// In en, this message translates to:
  /// **'Markdown'**
  String get messageExportSheetMarkdown;

  /// No description provided for @messageExportSheetSingleMarkdownSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Export Markdown'**
  String get messageExportSheetSingleMarkdownSubtitle;

  /// No description provided for @messageExportSheetPlainText.
  ///
  /// In en, this message translates to:
  /// **'Text'**
  String get messageExportSheetPlainText;

  /// No description provided for @messageExportSheetSingleTxtSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Export TXT'**
  String get messageExportSheetSingleTxtSubtitle;

  /// No description provided for @messageExportSheetExportImage.
  ///
  /// In en, this message translates to:
  /// **'Image'**
  String get messageExportSheetExportImage;

  /// No description provided for @messageExportSheetSingleExportImageSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Export Image'**
  String get messageExportSheetSingleExportImageSubtitle;

  /// No description provided for @messageExportSheetShowThinkingAndToolCards.
  ///
  /// In en, this message translates to:
  /// **'Show tools'**
  String get messageExportSheetShowThinkingAndToolCards;

  /// No description provided for @messageExportSheetShowThinkingContent.
  ///
  /// In en, this message translates to:
  /// **'Show thinking'**
  String get messageExportSheetShowThinkingContent;

  /// No description provided for @messageExportSheetBatchMarkdownSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Batch Markdown'**
  String get messageExportSheetBatchMarkdownSubtitle;

  /// No description provided for @messageExportSheetBatchTxtSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Batch TXT'**
  String get messageExportSheetBatchTxtSubtitle;

  /// No description provided for @messageExportSheetBatchExportImageSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Batch Image'**
  String get messageExportSheetBatchExportImageSubtitle;

  /// No description provided for @exportDisclaimerAiGenerated.
  ///
  /// In en, this message translates to:
  /// **'AI Generated'**
  String get exportDisclaimerAiGenerated;

  /// No description provided for @messageExportSheetExporting.
  ///
  /// In en, this message translates to:
  /// **'Exporting'**
  String get messageExportSheetExporting;

  /// No description provided for @messageEditDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit Message'**
  String get messageEditDialogTitle;

  /// No description provided for @cameraPermissionDeniedMessage.
  ///
  /// In en, this message translates to:
  /// **'No camera access'**
  String get cameraPermissionDeniedMessage;

  /// No description provided for @openSystemSettings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get openSystemSettings;

  /// No description provided for @searchProviderBingLocalDescription.
  ///
  /// In en, this message translates to:
  /// **'Bing search'**
  String get searchProviderBingLocalDescription;

  /// No description provided for @searchProviderTavilyDescription.
  ///
  /// In en, this message translates to:
  /// **'Tavily search'**
  String get searchProviderTavilyDescription;

  /// No description provided for @searchProviderExaDescription.
  ///
  /// In en, this message translates to:
  /// **'Exa search'**
  String get searchProviderExaDescription;

  /// No description provided for @searchProviderZhipuDescription.
  ///
  /// In en, this message translates to:
  /// **'Zhipu search'**
  String get searchProviderZhipuDescription;

  /// No description provided for @searchProviderSearXNGDescription.
  ///
  /// In en, this message translates to:
  /// **'SearXNG search'**
  String get searchProviderSearXNGDescription;

  /// No description provided for @searchProviderLinkUpDescription.
  ///
  /// In en, this message translates to:
  /// **'LinkUp search'**
  String get searchProviderLinkUpDescription;

  /// No description provided for @searchProviderBraveDescription.
  ///
  /// In en, this message translates to:
  /// **'Brave search'**
  String get searchProviderBraveDescription;

  /// No description provided for @searchProviderMetasoDescription.
  ///
  /// In en, this message translates to:
  /// **'Metaso search'**
  String get searchProviderMetasoDescription;

  /// No description provided for @searchProviderOllamaDescription.
  ///
  /// In en, this message translates to:
  /// **'Ollama search'**
  String get searchProviderOllamaDescription;

  /// No description provided for @searchProviderJinaDescription.
  ///
  /// In en, this message translates to:
  /// **'Jina search'**
  String get searchProviderJinaDescription;

  /// No description provided for @searchProviderBochaDescription.
  ///
  /// In en, this message translates to:
  /// **'Bocha search'**
  String get searchProviderBochaDescription;

  /// No description provided for @searchProviderPerplexityDescription.
  ///
  /// In en, this message translates to:
  /// **'Perplexity search'**
  String get searchProviderPerplexityDescription;

  /// No description provided for @searchProviderDuckDuckGoDescription.
  ///
  /// In en, this message translates to:
  /// **'DuckDuckGo search'**
  String get searchProviderDuckDuckGoDescription;

  /// No description provided for @selectCopyPageCopiedAll.
  ///
  /// In en, this message translates to:
  /// **'Copied'**
  String get selectCopyPageCopiedAll;

  /// No description provided for @selectCopyPageCopyAll.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get selectCopyPageCopyAll;

  /// No description provided for @selectCopyPageTitle.
  ///
  /// In en, this message translates to:
  /// **'Select'**
  String get selectCopyPageTitle;

  /// No description provided for @messageWebViewRefreshTooltip.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get messageWebViewRefreshTooltip;

  /// No description provided for @messageWebViewForwardTooltip.
  ///
  /// In en, this message translates to:
  /// **'Forward'**
  String get messageWebViewForwardTooltip;

  /// No description provided for @messageWebViewOpenInBrowser.
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get messageWebViewOpenInBrowser;

  /// No description provided for @messageWebViewConsoleLogs.
  ///
  /// In en, this message translates to:
  /// **'Console'**
  String get messageWebViewConsoleLogs;

  /// No description provided for @messageWebViewNoConsoleMessages.
  ///
  /// In en, this message translates to:
  /// **'Empty'**
  String get messageWebViewNoConsoleMessages;

  /// No description provided for @assistantEditPreviewTitle.
  ///
  /// In en, this message translates to:
  /// **'Preview'**
  String get assistantEditPreviewTitle;

  /// No description provided for @imagePreviewSheetSaveSuccess.
  ///
  /// In en, this message translates to:
  /// **'Saved'**
  String get imagePreviewSheetSaveSuccess;

  /// No description provided for @imagePreviewSheetSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed: {error}'**
  String imagePreviewSheetSaveFailed(String error);

  /// No description provided for @settingsPageShare.
  ///
  /// In en, this message translates to:
  /// **'Share'**
  String get settingsPageShare;

  /// No description provided for @imagePreviewSheetSaveImage.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get imagePreviewSheetSaveImage;

  /// No description provided for @languageDisplayTraditionalChinese.
  ///
  /// In en, this message translates to:
  /// **'Traditional Chinese'**
  String get languageDisplayTraditionalChinese;

  /// No description provided for @languageDisplaySimplifiedChinese.
  ///
  /// In en, this message translates to:
  /// **'Simplified Chinese'**
  String get languageDisplaySimplifiedChinese;

  /// No description provided for @languageDisplayEnglish.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get languageDisplayEnglish;

  /// No description provided for @languageDisplayJapanese.
  ///
  /// In en, this message translates to:
  /// **'Japanese'**
  String get languageDisplayJapanese;

  /// No description provided for @languageDisplayKorean.
  ///
  /// In en, this message translates to:
  /// **'Korean'**
  String get languageDisplayKorean;

  /// No description provided for @languageDisplayFrench.
  ///
  /// In en, this message translates to:
  /// **'French'**
  String get languageDisplayFrench;

  /// No description provided for @languageDisplayGerman.
  ///
  /// In en, this message translates to:
  /// **'German'**
  String get languageDisplayGerman;

  /// No description provided for @languageDisplayItalian.
  ///
  /// In en, this message translates to:
  /// **'Italian'**
  String get languageDisplayItalian;

  /// No description provided for @languageDisplaySpanish.
  ///
  /// In en, this message translates to:
  /// **'Spanish'**
  String get languageDisplaySpanish;

  /// No description provided for @languageSelectSheetClearButton.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get languageSelectSheetClearButton;

  /// No description provided for @storageSpaceCategoryImages.
  ///
  /// In en, this message translates to:
  /// **'Images'**
  String get storageSpaceCategoryImages;

  /// No description provided for @storageSpaceCategoryFiles.
  ///
  /// In en, this message translates to:
  /// **'Files'**
  String get storageSpaceCategoryFiles;

  /// No description provided for @storageSpaceCategoryChatData.
  ///
  /// In en, this message translates to:
  /// **'Chat Data'**
  String get storageSpaceCategoryChatData;

  /// No description provided for @storageSpaceCategoryAssistantData.
  ///
  /// In en, this message translates to:
  /// **'Assistants'**
  String get storageSpaceCategoryAssistantData;

  /// No description provided for @storageSpaceCategoryCache.
  ///
  /// In en, this message translates to:
  /// **'Cache'**
  String get storageSpaceCategoryCache;

  /// No description provided for @storageSpaceCategoryLogs.
  ///
  /// In en, this message translates to:
  /// **'Logs'**
  String get storageSpaceCategoryLogs;

  /// No description provided for @storageSpaceCategoryOther.
  ///
  /// In en, this message translates to:
  /// **'Other'**
  String get storageSpaceCategoryOther;

  /// No description provided for @storageSpaceSubChatMessages.
  ///
  /// In en, this message translates to:
  /// **'Messages'**
  String get storageSpaceSubChatMessages;

  /// No description provided for @storageSpaceSubChatConversations.
  ///
  /// In en, this message translates to:
  /// **'Conversations'**
  String get storageSpaceSubChatConversations;

  /// No description provided for @storageSpaceSubChatToolEvents.
  ///
  /// In en, this message translates to:
  /// **'Tools'**
  String get storageSpaceSubChatToolEvents;

  /// No description provided for @storageSpaceSubAssistantAvatars.
  ///
  /// In en, this message translates to:
  /// **'Avatars'**
  String get storageSpaceSubAssistantAvatars;

  /// No description provided for @storageSpaceSubAssistantImages.
  ///
  /// In en, this message translates to:
  /// **'Images'**
  String get storageSpaceSubAssistantImages;

  /// No description provided for @storageSpaceSubCacheAvatars.
  ///
  /// In en, this message translates to:
  /// **'Avatar cache'**
  String get storageSpaceSubCacheAvatars;

  /// No description provided for @storageSpaceSubCacheOther.
  ///
  /// In en, this message translates to:
  /// **'Other cache'**
  String get storageSpaceSubCacheOther;

  /// No description provided for @storageSpaceSubCacheSystem.
  ///
  /// In en, this message translates to:
  /// **'System cache'**
  String get storageSpaceSubCacheSystem;

  /// No description provided for @storageSpaceSubLogsFlutter.
  ///
  /// In en, this message translates to:
  /// **'Flutter logs'**
  String get storageSpaceSubLogsFlutter;

  /// No description provided for @storageSpaceSubLogsRequests.
  ///
  /// In en, this message translates to:
  /// **'API logs'**
  String get storageSpaceSubLogsRequests;

  /// No description provided for @storageSpaceSubLogsOther.
  ///
  /// In en, this message translates to:
  /// **'Other logs'**
  String get storageSpaceSubLogsOther;

  /// No description provided for @storageSpaceClearConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Confirm'**
  String get storageSpaceClearConfirmTitle;

  /// No description provided for @storageSpaceClearConfirmMessage.
  ///
  /// In en, this message translates to:
  /// **'Clear {targetName}?'**
  String storageSpaceClearConfirmMessage(String targetName);

  /// No description provided for @storageSpaceClearButton.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get storageSpaceClearButton;

  /// No description provided for @storageSpaceClearDone.
  ///
  /// In en, this message translates to:
  /// **'Cleared {targetName}'**
  String storageSpaceClearDone(String targetName);

  /// No description provided for @storageSpaceClearFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed: {error}'**
  String storageSpaceClearFailed(String error);

  /// No description provided for @storageSpaceLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to load'**
  String get storageSpaceLoadFailed;

  /// No description provided for @storageSpacePageTitle.
  ///
  /// In en, this message translates to:
  /// **'Storage'**
  String get storageSpacePageTitle;

  /// No description provided for @storageSpaceRefreshTooltip.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get storageSpaceRefreshTooltip;

  /// No description provided for @storageSpaceTotalLabel.
  ///
  /// In en, this message translates to:
  /// **'Total'**
  String get storageSpaceTotalLabel;

  /// No description provided for @storageSpaceClearableLabel.
  ///
  /// In en, this message translates to:
  /// **'Clearable: {size}'**
  String storageSpaceClearableLabel(String size);

  /// No description provided for @storageSpaceClearableHint.
  ///
  /// In en, this message translates to:
  /// **'Clearable: {size}'**
  String storageSpaceClearableHint(String size);

  /// No description provided for @storageSpaceFilesCount.
  ///
  /// In en, this message translates to:
  /// **'{count} files'**
  String storageSpaceFilesCount(int count);

  /// No description provided for @storageSpaceSafeToClearHint.
  ///
  /// In en, this message translates to:
  /// **'Safe'**
  String get storageSpaceSafeToClearHint;

  /// No description provided for @storageSpaceNotSafeToClearHint.
  ///
  /// In en, this message translates to:
  /// **'Caution'**
  String get storageSpaceNotSafeToClearHint;

  /// No description provided for @storageSpaceClearAvatarCacheButton.
  ///
  /// In en, this message translates to:
  /// **'Clear avatars'**
  String get storageSpaceClearAvatarCacheButton;

  /// No description provided for @storageSpaceClearCacheButton.
  ///
  /// In en, this message translates to:
  /// **'Clear cache'**
  String get storageSpaceClearCacheButton;

  /// No description provided for @storageSpaceClearLogsButton.
  ///
  /// In en, this message translates to:
  /// **'Clear logs'**
  String get storageSpaceClearLogsButton;

  /// No description provided for @storageSpaceBreakdownTitle.
  ///
  /// In en, this message translates to:
  /// **'Breakdown'**
  String get storageSpaceBreakdownTitle;

  /// No description provided for @storageSpaceDeleteConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get storageSpaceDeleteConfirmTitle;

  /// No description provided for @storageSpaceDeleteUploadsConfirmMessage.
  ///
  /// In en, this message translates to:
  /// **'Delete {count} items?'**
  String storageSpaceDeleteUploadsConfirmMessage(int count);

  /// No description provided for @storageSpaceDeletedUploadsDone.
  ///
  /// In en, this message translates to:
  /// **'Deleted {count} items'**
  String storageSpaceDeletedUploadsDone(int count);

  /// No description provided for @storageSpaceNoUploads.
  ///
  /// In en, this message translates to:
  /// **'No uploads'**
  String get storageSpaceNoUploads;

  /// No description provided for @storageSpaceClearSelection.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get storageSpaceClearSelection;

  /// No description provided for @storageSpaceSelectAll.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get storageSpaceSelectAll;

  /// No description provided for @storageSpaceSelectedCount.
  ///
  /// In en, this message translates to:
  /// **'{count} selected'**
  String storageSpaceSelectedCount(int count);

  /// No description provided for @storageSpaceUploadsCount.
  ///
  /// In en, this message translates to:
  /// **'{count} items'**
  String storageSpaceUploadsCount(int count);

  /// No description provided for @displaySettingsPageThemeSettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Theme'**
  String get displaySettingsPageThemeSettingsTitle;

  /// No description provided for @displaySettingsPageLanguageTitle.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get displaySettingsPageLanguageTitle;

  /// No description provided for @displaySettingsPageLanguageChineseLabel.
  ///
  /// In en, this message translates to:
  /// **'Chinese'**
  String get displaySettingsPageLanguageChineseLabel;

  /// No description provided for @displaySettingsPageLanguageEnglishLabel.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get displaySettingsPageLanguageEnglishLabel;

  /// No description provided for @displaySettingsPageChatItemDisplayTitle.
  ///
  /// In en, this message translates to:
  /// **'Chat View'**
  String get displaySettingsPageChatItemDisplayTitle;

  /// No description provided for @displaySettingsPageRenderingSettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Rendering'**
  String get displaySettingsPageRenderingSettingsTitle;

  /// No description provided for @displaySettingsPageBehaviorStartupTitle.
  ///
  /// In en, this message translates to:
  /// **'Behavior'**
  String get displaySettingsPageBehaviorStartupTitle;

  /// No description provided for @displaySettingsPageHapticsSettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Haptics'**
  String get displaySettingsPageHapticsSettingsTitle;

  /// No description provided for @displaySettingsPageAndroidBackgroundChatTitle.
  ///
  /// In en, this message translates to:
  /// **'Background'**
  String get displaySettingsPageAndroidBackgroundChatTitle;

  /// No description provided for @androidBackgroundStatusOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get androidBackgroundStatusOff;

  /// No description provided for @androidBackgroundStatusOn.
  ///
  /// In en, this message translates to:
  /// **'On'**
  String get androidBackgroundStatusOn;

  /// No description provided for @androidBackgroundStatusOther.
  ///
  /// In en, this message translates to:
  /// **'Notify'**
  String get androidBackgroundStatusOther;

  /// No description provided for @displaySettingsPageChatMessageBackgroundTitle.
  ///
  /// In en, this message translates to:
  /// **'Background'**
  String get displaySettingsPageChatMessageBackgroundTitle;

  /// No description provided for @displaySettingsPageChatMessageBackgroundFrosted.
  ///
  /// In en, this message translates to:
  /// **'Frosted'**
  String get displaySettingsPageChatMessageBackgroundFrosted;

  /// No description provided for @displaySettingsPageChatMessageBackgroundSolid.
  ///
  /// In en, this message translates to:
  /// **'Solid'**
  String get displaySettingsPageChatMessageBackgroundSolid;

  /// No description provided for @displaySettingsPageChatMessageBackgroundDefault.
  ///
  /// In en, this message translates to:
  /// **'Default'**
  String get displaySettingsPageChatMessageBackgroundDefault;

  /// No description provided for @displaySettingsPageAppFontTitle.
  ///
  /// In en, this message translates to:
  /// **'App Font'**
  String get displaySettingsPageAppFontTitle;

  /// No description provided for @displaySettingsPageFontLocalFileLabel.
  ///
  /// In en, this message translates to:
  /// **'Local'**
  String get displaySettingsPageFontLocalFileLabel;

  /// No description provided for @desktopFontFamilySystemDefault.
  ///
  /// In en, this message translates to:
  /// **'Default'**
  String get desktopFontFamilySystemDefault;

  /// No description provided for @displaySettingsPageCodeFontTitle.
  ///
  /// In en, this message translates to:
  /// **'Code Font'**
  String get displaySettingsPageCodeFontTitle;

  /// No description provided for @desktopFontFamilyMonospaceDefault.
  ///
  /// In en, this message translates to:
  /// **'Mono'**
  String get desktopFontFamilyMonospaceDefault;

  /// No description provided for @displaySettingsPageChatFontSizeTitle.
  ///
  /// In en, this message translates to:
  /// **'Font Size'**
  String get displaySettingsPageChatFontSizeTitle;

  /// No description provided for @displaySettingsPageAutoScrollIdleTitle.
  ///
  /// In en, this message translates to:
  /// **'Auto Scroll'**
  String get displaySettingsPageAutoScrollIdleTitle;

  /// No description provided for @displaySettingsPageAutoScrollDisabledLabel.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get displaySettingsPageAutoScrollDisabledLabel;

  /// No description provided for @displaySettingsPageChatBackgroundMaskTitle.
  ///
  /// In en, this message translates to:
  /// **'Mask'**
  String get displaySettingsPageChatBackgroundMaskTitle;

  /// No description provided for @fontPickerChooseLocalFile.
  ///
  /// In en, this message translates to:
  /// **'Local'**
  String get fontPickerChooseLocalFile;

  /// No description provided for @fontPickerGetFromGoogleFonts.
  ///
  /// In en, this message translates to:
  /// **'Google'**
  String get fontPickerGetFromGoogleFonts;

  /// No description provided for @displaySettingsPageFontResetLabel.
  ///
  /// In en, this message translates to:
  /// **'Reset'**
  String get displaySettingsPageFontResetLabel;

  /// No description provided for @androidBackgroundOptionOn.
  ///
  /// In en, this message translates to:
  /// **'On'**
  String get androidBackgroundOptionOn;

  /// No description provided for @androidBackgroundOptionOnNotify.
  ///
  /// In en, this message translates to:
  /// **'Notify'**
  String get androidBackgroundOptionOnNotify;

  /// No description provided for @androidBackgroundOptionOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get androidBackgroundOptionOff;

  /// No description provided for @displaySettingsPageChatFontSampleText.
  ///
  /// In en, this message translates to:
  /// **'Sample'**
  String get displaySettingsPageChatFontSampleText;

  /// No description provided for @displaySettingsPageAutoScrollEnableTitle.
  ///
  /// In en, this message translates to:
  /// **'Auto Scroll'**
  String get displaySettingsPageAutoScrollEnableTitle;

  /// No description provided for @displaySettingsPageAutoScrollIdleSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Delay'**
  String get displaySettingsPageAutoScrollIdleSubtitle;

  /// No description provided for @displaySettingsPageShowUserAvatarTitle.
  ///
  /// In en, this message translates to:
  /// **'User Avatar'**
  String get displaySettingsPageShowUserAvatarTitle;

  /// No description provided for @displaySettingsPageShowUserNameTimestampTitle.
  ///
  /// In en, this message translates to:
  /// **'User Name'**
  String get displaySettingsPageShowUserNameTimestampTitle;

  /// No description provided for @displaySettingsPageShowUserMessageActionsTitle.
  ///
  /// In en, this message translates to:
  /// **'Actions'**
  String get displaySettingsPageShowUserMessageActionsTitle;

  /// No description provided for @displaySettingsPageChatModelIconTitle.
  ///
  /// In en, this message translates to:
  /// **'Model Icon'**
  String get displaySettingsPageChatModelIconTitle;

  /// No description provided for @displaySettingsPageShowModelNameTimestampTitle.
  ///
  /// In en, this message translates to:
  /// **'Model Name'**
  String get displaySettingsPageShowModelNameTimestampTitle;

  /// No description provided for @displaySettingsPageShowTokenStatsTitle.
  ///
  /// In en, this message translates to:
  /// **'Stats'**
  String get displaySettingsPageShowTokenStatsTitle;

  /// No description provided for @displaySettingsPageEnableDollarLatexTitle.
  ///
  /// In en, this message translates to:
  /// **'Latex'**
  String get displaySettingsPageEnableDollarLatexTitle;

  /// No description provided for @displaySettingsPageEnableMathTitle.
  ///
  /// In en, this message translates to:
  /// **'Math'**
  String get displaySettingsPageEnableMathTitle;

  /// No description provided for @displaySettingsPageEnableUserMarkdownTitle.
  ///
  /// In en, this message translates to:
  /// **'Markdown'**
  String get displaySettingsPageEnableUserMarkdownTitle;

  /// No description provided for @displaySettingsPageEnableReasoningMarkdownTitle.
  ///
  /// In en, this message translates to:
  /// **'Reasoning'**
  String get displaySettingsPageEnableReasoningMarkdownTitle;

  /// No description provided for @displaySettingsPageAutoCollapseCodeBlockTitle.
  ///
  /// In en, this message translates to:
  /// **'Collapse Code'**
  String get displaySettingsPageAutoCollapseCodeBlockTitle;

  /// No description provided for @displaySettingsPageMobileCodeBlockWrapTitle.
  ///
  /// In en, this message translates to:
  /// **'Wrap'**
  String get displaySettingsPageMobileCodeBlockWrapTitle;

  /// No description provided for @displaySettingsPageAutoCollapseCodeBlockLinesTitle.
  ///
  /// In en, this message translates to:
  /// **'Lines'**
  String get displaySettingsPageAutoCollapseCodeBlockLinesTitle;

  /// No description provided for @displaySettingsPageAutoCollapseCodeBlockLinesUnit.
  ///
  /// In en, this message translates to:
  /// **'lines'**
  String get displaySettingsPageAutoCollapseCodeBlockLinesUnit;

  /// No description provided for @displaySettingsPageAutoCollapseThinkingTitle.
  ///
  /// In en, this message translates to:
  /// **'Collapse Thinking'**
  String get displaySettingsPageAutoCollapseThinkingTitle;

  /// No description provided for @displaySettingsPageShowUpdatesTitle.
  ///
  /// In en, this message translates to:
  /// **'Updates'**
  String get displaySettingsPageShowUpdatesTitle;

  /// No description provided for @displaySettingsPageMessageNavButtonsTitle.
  ///
  /// In en, this message translates to:
  /// **'Nav'**
  String get displaySettingsPageMessageNavButtonsTitle;

  /// No description provided for @displaySettingsPageShowChatListDateTitle.
  ///
  /// In en, this message translates to:
  /// **'Dates'**
  String get displaySettingsPageShowChatListDateTitle;

  /// No description provided for @displaySettingsPageKeepSidebarOpenOnAssistantTapTitle.
  ///
  /// In en, this message translates to:
  /// **'Pin Sidebar'**
  String get displaySettingsPageKeepSidebarOpenOnAssistantTapTitle;

  /// No description provided for @displaySettingsPageKeepSidebarOpenOnTopicTapTitle.
  ///
  /// In en, this message translates to:
  /// **'Pin Topics'**
  String get displaySettingsPageKeepSidebarOpenOnTopicTapTitle;

  /// No description provided for @displaySettingsPageKeepAssistantListExpandedOnSidebarCloseTitle.
  ///
  /// In en, this message translates to:
  /// **'Expand'**
  String get displaySettingsPageKeepAssistantListExpandedOnSidebarCloseTitle;

  /// No description provided for @displaySettingsPageNewChatOnAssistantSwitchTitle.
  ///
  /// In en, this message translates to:
  /// **'Auto New Chat'**
  String get displaySettingsPageNewChatOnAssistantSwitchTitle;

  /// No description provided for @displaySettingsPageNewChatAfterDeleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Auto New Chat'**
  String get displaySettingsPageNewChatAfterDeleteTitle;

  /// No description provided for @displaySettingsPageNewChatOnLaunchTitle.
  ///
  /// In en, this message translates to:
  /// **'New Chat on Launch'**
  String get displaySettingsPageNewChatOnLaunchTitle;

  /// No description provided for @displaySettingsPageHapticsGlobalTitle.
  ///
  /// In en, this message translates to:
  /// **'Haptics'**
  String get displaySettingsPageHapticsGlobalTitle;

  /// No description provided for @displaySettingsPageHapticsIosSwitchTitle.
  ///
  /// In en, this message translates to:
  /// **'Haptics'**
  String get displaySettingsPageHapticsIosSwitchTitle;

  /// No description provided for @displaySettingsPageHapticsOnSidebarTitle.
  ///
  /// In en, this message translates to:
  /// **'Sidebar'**
  String get displaySettingsPageHapticsOnSidebarTitle;

  /// No description provided for @displaySettingsPageHapticsOnListItemTapTitle.
  ///
  /// In en, this message translates to:
  /// **'List'**
  String get displaySettingsPageHapticsOnListItemTapTitle;

  /// No description provided for @displaySettingsPageHapticsOnCardTapTitle.
  ///
  /// In en, this message translates to:
  /// **'Card'**
  String get displaySettingsPageHapticsOnCardTapTitle;

  /// No description provided for @displaySettingsPageHapticsOnGenerateTitle.
  ///
  /// In en, this message translates to:
  /// **'Generate'**
  String get displaySettingsPageHapticsOnGenerateTitle;

  /// No description provided for @assistantSettingsPageTitle.
  ///
  /// In en, this message translates to:
  /// **'Assistants'**
  String get assistantSettingsPageTitle;

  /// No description provided for @assistantSettingsCopyButton.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get assistantSettingsCopyButton;

  /// No description provided for @assistantSettingsDeleteButton.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get assistantSettingsDeleteButton;

  /// No description provided for @ttsServicesPageBackButton.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get ttsServicesPageBackButton;

  /// No description provided for @ttsServicesPageTitle.
  ///
  /// In en, this message translates to:
  /// **'TTS'**
  String get ttsServicesPageTitle;

  /// No description provided for @ttsServicesPageAddTooltip.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get ttsServicesPageAddTooltip;

  /// No description provided for @ttsServicesPageSystemTtsTitle.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get ttsServicesPageSystemTtsTitle;

  /// No description provided for @ttsServicesPageSystemTtsAvailableSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Available'**
  String get ttsServicesPageSystemTtsAvailableSubtitle;

  /// No description provided for @ttsServicesPageSystemTtsUnavailableSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Error: {error}'**
  String ttsServicesPageSystemTtsUnavailableSubtitle(String error);

  /// No description provided for @ttsServicesPageSystemTtsUnavailableNotInitialized.
  ///
  /// In en, this message translates to:
  /// **'Not init'**
  String get ttsServicesPageSystemTtsUnavailableNotInitialized;

  /// No description provided for @ttsServicesPageTestSpeechText.
  ///
  /// In en, this message translates to:
  /// **'Test'**
  String get ttsServicesPageTestSpeechText;

  /// No description provided for @ttsServicesPageSystemTtsSettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get ttsServicesPageSystemTtsSettingsTitle;

  /// No description provided for @ttsServicesPageEngineLabel.
  ///
  /// In en, this message translates to:
  /// **'Engine'**
  String get ttsServicesPageEngineLabel;

  /// No description provided for @ttsServicesPageAutoLabel.
  ///
  /// In en, this message translates to:
  /// **'Auto'**
  String get ttsServicesPageAutoLabel;

  /// No description provided for @ttsServicesPageLanguageLabel.
  ///
  /// In en, this message translates to:
  /// **'Lang'**
  String get ttsServicesPageLanguageLabel;

  /// No description provided for @ttsServicesPageSpeechRateLabel.
  ///
  /// In en, this message translates to:
  /// **'Rate'**
  String get ttsServicesPageSpeechRateLabel;

  /// No description provided for @ttsServicesPagePitchLabel.
  ///
  /// In en, this message translates to:
  /// **'Pitch'**
  String get ttsServicesPagePitchLabel;

  /// No description provided for @ttsServicesPageDoneButton.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get ttsServicesPageDoneButton;

  /// No description provided for @ttsServicesPageSettingsSavedMessage.
  ///
  /// In en, this message translates to:
  /// **'Saved'**
  String get ttsServicesPageSettingsSavedMessage;

  /// No description provided for @ttsServicesViewDetailsButton.
  ///
  /// In en, this message translates to:
  /// **'Details'**
  String get ttsServicesViewDetailsButton;

  /// No description provided for @ttsServicesDialogErrorTitle.
  ///
  /// In en, this message translates to:
  /// **'Error'**
  String get ttsServicesDialogErrorTitle;

  /// No description provided for @ttsServicesCloseButton.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get ttsServicesCloseButton;

  /// No description provided for @ttsServicesDialogAddTitle.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get ttsServicesDialogAddTitle;

  /// No description provided for @ttsServicesDialogEditTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get ttsServicesDialogEditTitle;

  /// No description provided for @ttsServicesDialogProviderType.
  ///
  /// In en, this message translates to:
  /// **'Type'**
  String get ttsServicesDialogProviderType;

  /// No description provided for @ttsServicesFieldNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get ttsServicesFieldNameLabel;

  /// No description provided for @ttsServicesFieldApiKeyLabel.
  ///
  /// In en, this message translates to:
  /// **'Key'**
  String get ttsServicesFieldApiKeyLabel;

  /// No description provided for @ttsServicesFieldBaseUrlLabel.
  ///
  /// In en, this message translates to:
  /// **'URL'**
  String get ttsServicesFieldBaseUrlLabel;

  /// No description provided for @ttsServicesFieldModelLabel.
  ///
  /// In en, this message translates to:
  /// **'Model'**
  String get ttsServicesFieldModelLabel;

  /// No description provided for @ttsServicesFieldEmotionLabel.
  ///
  /// In en, this message translates to:
  /// **'Emotion'**
  String get ttsServicesFieldEmotionLabel;

  /// No description provided for @ttsServicesFieldSpeedLabel.
  ///
  /// In en, this message translates to:
  /// **'Speed'**
  String get ttsServicesFieldSpeedLabel;

  /// No description provided for @ttsServicesFieldVoiceLabel.
  ///
  /// In en, this message translates to:
  /// **'Voice'**
  String get ttsServicesFieldVoiceLabel;

  /// No description provided for @ttsServicesFieldVoiceIdLabel.
  ///
  /// In en, this message translates to:
  /// **'ID'**
  String get ttsServicesFieldVoiceIdLabel;

  /// No description provided for @backupPageImportFromCherryStudio.
  ///
  /// In en, this message translates to:
  /// **'Cherry'**
  String get backupPageImportFromCherryStudio;

  /// No description provided for @backupPageCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get backupPageCancel;

  /// No description provided for @backupPageOK.
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get backupPageOK;

  /// No description provided for @backupPageSelectImportMode.
  ///
  /// In en, this message translates to:
  /// **'Mode'**
  String get backupPageSelectImportMode;

  /// No description provided for @backupPageOverwriteMode.
  ///
  /// In en, this message translates to:
  /// **'Overwrite'**
  String get backupPageOverwriteMode;

  /// No description provided for @backupPageOverwriteModeDescription.
  ///
  /// In en, this message translates to:
  /// **'Clear local'**
  String get backupPageOverwriteModeDescription;

  /// No description provided for @backupPageMergeMode.
  ///
  /// In en, this message translates to:
  /// **'Merge'**
  String get backupPageMergeMode;

  /// No description provided for @backupPageMergeModeDescription.
  ///
  /// In en, this message translates to:
  /// **'Smart merge'**
  String get backupPageMergeModeDescription;

  /// No description provided for @backupPageExporting.
  ///
  /// In en, this message translates to:
  /// **'Exporting'**
  String get backupPageExporting;

  /// No description provided for @backupPageTitle.
  ///
  /// In en, this message translates to:
  /// **'Backup'**
  String get backupPageTitle;

  /// No description provided for @backupPageBackupManagement.
  ///
  /// In en, this message translates to:
  /// **'Manage'**
  String get backupPageBackupManagement;

  /// No description provided for @backupPageChatsLabel.
  ///
  /// In en, this message translates to:
  /// **'Chats'**
  String get backupPageChatsLabel;

  /// No description provided for @backupPageFilesLabel.
  ///
  /// In en, this message translates to:
  /// **'Files'**
  String get backupPageFilesLabel;

  /// No description provided for @backupPageWebDavBackup.
  ///
  /// In en, this message translates to:
  /// **'WebDAV'**
  String get backupPageWebDavBackup;

  /// No description provided for @backupPageWebDavServerSettings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get backupPageWebDavServerSettings;

  /// No description provided for @backupPageTestConnection.
  ///
  /// In en, this message translates to:
  /// **'Test'**
  String get backupPageTestConnection;

  /// No description provided for @backupPageTestDone.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get backupPageTestDone;

  /// No description provided for @backupPageRestore.
  ///
  /// In en, this message translates to:
  /// **'Restore'**
  String get backupPageRestore;

  /// No description provided for @backupPageRestartRequired.
  ///
  /// In en, this message translates to:
  /// **'Restart'**
  String get backupPageRestartRequired;

  /// No description provided for @backupPageRestartContent.
  ///
  /// In en, this message translates to:
  /// **'Restart app'**
  String get backupPageRestartContent;

  /// No description provided for @backupPageBackupNow.
  ///
  /// In en, this message translates to:
  /// **'Backup'**
  String get backupPageBackupNow;

  /// No description provided for @backupPageBackupUploaded.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get backupPageBackupUploaded;

  /// No description provided for @backupPageLocalBackup.
  ///
  /// In en, this message translates to:
  /// **'Local'**
  String get backupPageLocalBackup;

  /// No description provided for @backupPageImportBackupFile.
  ///
  /// In en, this message translates to:
  /// **'File'**
  String get backupPageImportBackupFile;

  /// No description provided for @backupPageImportFromChatbox.
  ///
  /// In en, this message translates to:
  /// **'Chatbox'**
  String get backupPageImportFromChatbox;

  /// No description provided for @backupPageRemoteBackups.
  ///
  /// In en, this message translates to:
  /// **'Remote'**
  String get backupPageRemoteBackups;

  /// No description provided for @backupPageNoBackups.
  ///
  /// In en, this message translates to:
  /// **'Empty'**
  String get backupPageNoBackups;

  /// No description provided for @backupPageSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get backupPageSave;

  /// No description provided for @backupPageWebDavServerUrl.
  ///
  /// In en, this message translates to:
  /// **'URL'**
  String get backupPageWebDavServerUrl;

  /// No description provided for @backupPagePassword.
  ///
  /// In en, this message translates to:
  /// **'Pass'**
  String get backupPagePassword;

  /// No description provided for @backupPagePath.
  ///
  /// In en, this message translates to:
  /// **'Path'**
  String get backupPagePath;

  /// No description provided for @instructionInjectionImportSuccess.
  ///
  /// In en, this message translates to:
  /// **'Imported {count}'**
  String instructionInjectionImportSuccess(int count);

  /// No description provided for @instructionInjectionBackTooltip.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get instructionInjectionBackTooltip;

  /// No description provided for @instructionInjectionImportTooltip.
  ///
  /// In en, this message translates to:
  /// **'Import'**
  String get instructionInjectionImportTooltip;

  /// No description provided for @instructionInjectionAddTooltip.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get instructionInjectionAddTooltip;

  /// No description provided for @instructionInjectionAddTitle.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get instructionInjectionAddTitle;

  /// No description provided for @networkProxyEnableLabel.
  ///
  /// In en, this message translates to:
  /// **'Enabled'**
  String get networkProxyEnableLabel;

  /// No description provided for @networkProxyType.
  ///
  /// In en, this message translates to:
  /// **'Type'**
  String get networkProxyType;

  /// No description provided for @networkProxyServerHost.
  ///
  /// In en, this message translates to:
  /// **'Host'**
  String get networkProxyServerHost;

  /// No description provided for @networkProxyPort.
  ///
  /// In en, this message translates to:
  /// **'Port'**
  String get networkProxyPort;

  /// No description provided for @networkProxyUsername.
  ///
  /// In en, this message translates to:
  /// **'User'**
  String get networkProxyUsername;

  /// No description provided for @networkProxyOptionalHint.
  ///
  /// In en, this message translates to:
  /// **'Optional'**
  String get networkProxyOptionalHint;

  /// No description provided for @networkProxyPassword.
  ///
  /// In en, this message translates to:
  /// **'Pass'**
  String get networkProxyPassword;

  /// No description provided for @networkProxyPriorityNote.
  ///
  /// In en, this message translates to:
  /// **'Priority note'**
  String get networkProxyPriorityNote;

  /// No description provided for @networkProxyTestHeader.
  ///
  /// In en, this message translates to:
  /// **'Test'**
  String get networkProxyTestHeader;

  /// No description provided for @networkProxyTestUrlHint.
  ///
  /// In en, this message translates to:
  /// **'URL'**
  String get networkProxyTestUrlHint;

  /// No description provided for @networkProxyTesting.
  ///
  /// In en, this message translates to:
  /// **'Testing'**
  String get networkProxyTesting;

  /// No description provided for @networkProxyTestButton.
  ///
  /// In en, this message translates to:
  /// **'Test'**
  String get networkProxyTestButton;

  /// No description provided for @networkProxyTestSuccess.
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get networkProxyTestSuccess;

  /// No description provided for @networkProxyTestFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed: {error}'**
  String networkProxyTestFailed(String error);

  /// No description provided for @networkProxyNoUrl.
  ///
  /// In en, this message translates to:
  /// **'No URL'**
  String get networkProxyNoUrl;

  /// No description provided for @networkProxyTypeHttps.
  ///
  /// In en, this message translates to:
  /// **'HTTPS'**
  String get networkProxyTypeHttps;

  /// No description provided for @networkProxyTypeSocks5.
  ///
  /// In en, this message translates to:
  /// **'SOCKS5'**
  String get networkProxyTypeSocks5;

  /// No description provided for @networkProxyTypeHttp.
  ///
  /// In en, this message translates to:
  /// **'HTTP'**
  String get networkProxyTypeHttp;

  /// No description provided for @assistantEditRegexDescription.
  ///
  /// In en, this message translates to:
  /// **'Regex rules'**
  String get assistantEditRegexDescription;

  /// No description provided for @assistantEditAddRegexButton.
  ///
  /// In en, this message translates to:
  /// **'Add Regex'**
  String get assistantEditAddRegexButton;

  /// No description provided for @assistantRegexUntitled.
  ///
  /// In en, this message translates to:
  /// **'Untitled'**
  String get assistantRegexUntitled;

  /// No description provided for @assistantRegexDeleteButton.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get assistantRegexDeleteButton;

  /// No description provided for @assistantRegexScopeUser.
  ///
  /// In en, this message translates to:
  /// **'User'**
  String get assistantRegexScopeUser;

  /// No description provided for @assistantRegexScopeAssistant.
  ///
  /// In en, this message translates to:
  /// **'AI'**
  String get assistantRegexScopeAssistant;

  /// No description provided for @assistantRegexScopeVisualOnly.
  ///
  /// In en, this message translates to:
  /// **'Visual'**
  String get assistantRegexScopeVisualOnly;

  /// No description provided for @assistantRegexValidationError.
  ///
  /// In en, this message translates to:
  /// **'Error'**
  String get assistantRegexValidationError;

  /// No description provided for @assistantRegexInvalidPattern.
  ///
  /// In en, this message translates to:
  /// **'Invalid'**
  String get assistantRegexInvalidPattern;

  /// No description provided for @assistantRegexAddTitle.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get assistantRegexAddTitle;

  /// No description provided for @assistantRegexEditTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get assistantRegexEditTitle;

  /// No description provided for @assistantRegexAddAction.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get assistantRegexAddAction;

  /// No description provided for @assistantRegexSaveAction.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get assistantRegexSaveAction;

  /// No description provided for @assistantRegexNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get assistantRegexNameLabel;

  /// No description provided for @assistantRegexPatternLabel.
  ///
  /// In en, this message translates to:
  /// **'Regex'**
  String get assistantRegexPatternLabel;

  /// No description provided for @assistantRegexReplacementLabel.
  ///
  /// In en, this message translates to:
  /// **'Replacement'**
  String get assistantRegexReplacementLabel;

  /// No description provided for @assistantRegexScopeLabel.
  ///
  /// In en, this message translates to:
  /// **'Scope'**
  String get assistantRegexScopeLabel;

  /// No description provided for @assistantRegexCancelButton.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get assistantRegexCancelButton;

  /// No description provided for @themeSettingsPageDynamicColorSection.
  ///
  /// In en, this message translates to:
  /// **'Dynamic'**
  String get themeSettingsPageDynamicColorSection;

  /// No description provided for @themeSettingsPageUseDynamicColorTitle.
  ///
  /// In en, this message translates to:
  /// **'Enabled'**
  String get themeSettingsPageUseDynamicColorTitle;

  /// No description provided for @themeSettingsPageUseDynamicColorSubtitle.
  ///
  /// In en, this message translates to:
  /// **'System color'**
  String get themeSettingsPageUseDynamicColorSubtitle;

  /// No description provided for @themeSettingsPageUsePureBackgroundTitle.
  ///
  /// In en, this message translates to:
  /// **'Pure'**
  String get themeSettingsPageUsePureBackgroundTitle;

  /// No description provided for @themeSettingsPageUsePureBackgroundSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Solid'**
  String get themeSettingsPageUsePureBackgroundSubtitle;

  /// No description provided for @fontPickerFilterHint.
  ///
  /// In en, this message translates to:
  /// **'Filter'**
  String get fontPickerFilterHint;

  /// No description provided for @logViewerTitle.
  ///
  /// In en, this message translates to:
  /// **'Logs'**
  String get logViewerTitle;

  /// No description provided for @logViewerEmpty.
  ///
  /// In en, this message translates to:
  /// **'Empty'**
  String get logViewerEmpty;

  /// No description provided for @logViewerCurrentLog.
  ///
  /// In en, this message translates to:
  /// **'Current'**
  String get logViewerCurrentLog;

  /// No description provided for @logViewerExport.
  ///
  /// In en, this message translates to:
  /// **'Export'**
  String get logViewerExport;

  /// No description provided for @chatHistoryPageTitle.
  ///
  /// In en, this message translates to:
  /// **'History'**
  String get chatHistoryPageTitle;

  /// No description provided for @chatHistoryPageSearchTooltip.
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get chatHistoryPageSearchTooltip;

  /// No description provided for @chatHistoryPageDeleteAllTooltip.
  ///
  /// In en, this message translates to:
  /// **'Delete All'**
  String get chatHistoryPageDeleteAllTooltip;

  /// No description provided for @chatHistoryPageDeleteAllDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get chatHistoryPageDeleteAllDialogTitle;

  /// No description provided for @chatHistoryPageDeleteAllDialogContent.
  ///
  /// In en, this message translates to:
  /// **'Delete all?'**
  String get chatHistoryPageDeleteAllDialogContent;

  /// No description provided for @chatHistoryPageCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get chatHistoryPageCancel;

  /// No description provided for @chatHistoryPageDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get chatHistoryPageDelete;

  /// No description provided for @chatHistoryPageDeletedAllSnackbar.
  ///
  /// In en, this message translates to:
  /// **'Cleared'**
  String get chatHistoryPageDeletedAllSnackbar;

  /// No description provided for @chatHistoryPageSearchHint.
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get chatHistoryPageSearchHint;

  /// No description provided for @chatHistoryPageNoConversations.
  ///
  /// In en, this message translates to:
  /// **'Empty'**
  String get chatHistoryPageNoConversations;

  /// No description provided for @chatHistoryPagePinnedSection.
  ///
  /// In en, this message translates to:
  /// **'Pinned'**
  String get chatHistoryPagePinnedSection;

  /// No description provided for @chatHistoryPagePinned.
  ///
  /// In en, this message translates to:
  /// **'Pinned'**
  String get chatHistoryPagePinned;

  /// No description provided for @chatHistoryPagePin.
  ///
  /// In en, this message translates to:
  /// **'Pin'**
  String get chatHistoryPagePin;

  /// No description provided for @assistantTagsCreateDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Create'**
  String get assistantTagsCreateDialogTitle;

  /// No description provided for @assistantTagsNameHint.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get assistantTagsNameHint;

  /// No description provided for @assistantTagsCreateDialogCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get assistantTagsCreateDialogCancel;

  /// No description provided for @assistantTagsCreateDialogOk.
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get assistantTagsCreateDialogOk;

  /// No description provided for @assistantTagsRenameDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Rename'**
  String get assistantTagsRenameDialogTitle;

  /// No description provided for @assistantTagsRenameDialogOk.
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get assistantTagsRenameDialogOk;

  /// No description provided for @assistantTagsDeleteConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get assistantTagsDeleteConfirmTitle;

  /// No description provided for @assistantTagsDeleteConfirmContent.
  ///
  /// In en, this message translates to:
  /// **'Delete?'**
  String get assistantTagsDeleteConfirmContent;

  /// No description provided for @assistantTagsDeleteConfirmCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get assistantTagsDeleteConfirmCancel;

  /// No description provided for @assistantTagsDeleteConfirmOk.
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get assistantTagsDeleteConfirmOk;

  /// No description provided for @assistantTagsManageTitle.
  ///
  /// In en, this message translates to:
  /// **'Tags'**
  String get assistantTagsManageTitle;

  /// No description provided for @sideDrawerChooseAssistantTitle.
  ///
  /// In en, this message translates to:
  /// **'Choose'**
  String get sideDrawerChooseAssistantTitle;

  /// No description provided for @searchServicesPageAtLeastOneServiceRequired.
  ///
  /// In en, this message translates to:
  /// **'Service required'**
  String get searchServicesPageAtLeastOneServiceRequired;

  /// No description provided for @modelDetailSheetChatType.
  ///
  /// In en, this message translates to:
  /// **'Chat'**
  String get modelDetailSheetChatType;

  /// No description provided for @modelDetailSheetEmbeddingType.
  ///
  /// In en, this message translates to:
  /// **'Embedding'**
  String get modelDetailSheetEmbeddingType;

  /// No description provided for @providerDetailPageMultiKeyModeTitle.
  ///
  /// In en, this message translates to:
  /// **'Multi-Key'**
  String get providerDetailPageMultiKeyModeTitle;

  /// No description provided for @providerDetailPageResponseApiTitle.
  ///
  /// In en, this message translates to:
  /// **'Response API'**
  String get providerDetailPageResponseApiTitle;

  /// No description provided for @providerDetailPageVertexAiTitle.
  ///
  /// In en, this message translates to:
  /// **'Vertex AI'**
  String get providerDetailPageVertexAiTitle;

  /// No description provided for @providerDetailPageAihubmixAppCodeLabel.
  ///
  /// In en, this message translates to:
  /// **'APP-Code'**
  String get providerDetailPageAihubmixAppCodeLabel;

  /// No description provided for @providerDetailPageAihubmixAppCodeHelp.
  ///
  /// In en, this message translates to:
  /// **'Discount code'**
  String get providerDetailPageAihubmixAppCodeHelp;

  /// No description provided for @providerDetailPageProviderTypeTitle.
  ///
  /// In en, this message translates to:
  /// **'Type'**
  String get providerDetailPageProviderTypeTitle;

  /// No description provided for @providerDetailPageDeleteAllModelsWarning.
  ///
  /// In en, this message translates to:
  /// **'Delete all?'**
  String get providerDetailPageDeleteAllModelsWarning;

  /// No description provided for @shareProviderSheetShareButton.
  ///
  /// In en, this message translates to:
  /// **'Share'**
  String get shareProviderSheetShareButton;

  /// No description provided for @assistantEditImageUrlDialogCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get assistantEditImageUrlDialogCancel;

  /// No description provided for @assistantEditImageUrlDialogSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get assistantEditImageUrlDialogSave;

  /// No description provided for @assistantEditQQAvatarDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'QQ Avatar'**
  String get assistantEditQQAvatarDialogTitle;

  /// No description provided for @assistantEditQQAvatarDialogHint.
  ///
  /// In en, this message translates to:
  /// **'QQ Number'**
  String get assistantEditQQAvatarDialogHint;

  /// No description provided for @assistantEditQQAvatarRandomButton.
  ///
  /// In en, this message translates to:
  /// **'Random'**
  String get assistantEditQQAvatarRandomButton;

  /// No description provided for @assistantEditQQAvatarFailedMessage.
  ///
  /// In en, this message translates to:
  /// **'Failed'**
  String get assistantEditQQAvatarFailedMessage;

  /// No description provided for @assistantEditQQAvatarDialogCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get assistantEditQQAvatarDialogCancel;

  /// No description provided for @assistantEditQQAvatarDialogSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get assistantEditQQAvatarDialogSave;

  /// No description provided for @assistantEditGalleryErrorMessage.
  ///
  /// In en, this message translates to:
  /// **'Error'**
  String get assistantEditGalleryErrorMessage;

  /// No description provided for @assistantEditGeneralErrorMessage.
  ///
  /// In en, this message translates to:
  /// **'Error'**
  String get assistantEditGeneralErrorMessage;

  /// No description provided for @assistantEditSystemPromptImportEmpty.
  ///
  /// In en, this message translates to:
  /// **'Empty'**
  String get assistantEditSystemPromptImportEmpty;

  /// No description provided for @assistantEditSystemPromptImportSuccess.
  ///
  /// In en, this message translates to:
  /// **'Success'**
  String get assistantEditSystemPromptImportSuccess;

  /// No description provided for @assistantEditSystemPromptImportFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed: {error}'**
  String assistantEditSystemPromptImportFailed(String error);

  /// No description provided for @assistantEditSampleUser.
  ///
  /// In en, this message translates to:
  /// **'User'**
  String get assistantEditSampleUser;

  /// No description provided for @assistantEditSampleMessage.
  ///
  /// In en, this message translates to:
  /// **'Hello'**
  String get assistantEditSampleMessage;

  /// No description provided for @assistantEditSampleReply.
  ///
  /// In en, this message translates to:
  /// **'Hi'**
  String get assistantEditSampleReply;

  /// No description provided for @assistantEditSystemPromptTitle.
  ///
  /// In en, this message translates to:
  /// **'System Prompt'**
  String get assistantEditSystemPromptTitle;

  /// No description provided for @assistantEditSystemPromptImportButton.
  ///
  /// In en, this message translates to:
  /// **'Import'**
  String get assistantEditSystemPromptImportButton;

  /// No description provided for @assistantEditSystemPromptHint.
  ///
  /// In en, this message translates to:
  /// **'Prompt'**
  String get assistantEditSystemPromptHint;

  /// No description provided for @assistantEditAvailableVariables.
  ///
  /// In en, this message translates to:
  /// **'Variables'**
  String get assistantEditAvailableVariables;

  /// No description provided for @assistantEditVariableDate.
  ///
  /// In en, this message translates to:
  /// **'Date'**
  String get assistantEditVariableDate;

  /// No description provided for @assistantEditVariableTime.
  ///
  /// In en, this message translates to:
  /// **'Time'**
  String get assistantEditVariableTime;

  /// No description provided for @assistantEditVariableDatetime.
  ///
  /// In en, this message translates to:
  /// **'DateTime'**
  String get assistantEditVariableDatetime;

  /// No description provided for @assistantEditVariableModelId.
  ///
  /// In en, this message translates to:
  /// **'Model ID'**
  String get assistantEditVariableModelId;

  /// No description provided for @assistantEditVariableModelName.
  ///
  /// In en, this message translates to:
  /// **'Model Name'**
  String get assistantEditVariableModelName;

  /// No description provided for @assistantEditVariableLocale.
  ///
  /// In en, this message translates to:
  /// **'Locale'**
  String get assistantEditVariableLocale;

  /// No description provided for @assistantEditVariableTimezone.
  ///
  /// In en, this message translates to:
  /// **'Timezone'**
  String get assistantEditVariableTimezone;

  /// No description provided for @assistantEditVariableSystemVersion.
  ///
  /// In en, this message translates to:
  /// **'OS Version'**
  String get assistantEditVariableSystemVersion;

  /// No description provided for @assistantEditVariableDeviceInfo.
  ///
  /// In en, this message translates to:
  /// **'Device'**
  String get assistantEditVariableDeviceInfo;

  /// No description provided for @assistantEditVariableBatteryLevel.
  ///
  /// In en, this message translates to:
  /// **'Battery'**
  String get assistantEditVariableBatteryLevel;

  /// No description provided for @assistantEditVariableNickname.
  ///
  /// In en, this message translates to:
  /// **'Nickname'**
  String get assistantEditVariableNickname;

  /// No description provided for @assistantEditVariableAssistantName.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get assistantEditVariableAssistantName;

  /// No description provided for @assistantEditMessageTemplateTitle.
  ///
  /// In en, this message translates to:
  /// **'Template'**
  String get assistantEditMessageTemplateTitle;

  /// No description provided for @assistantEditVariableRole.
  ///
  /// In en, this message translates to:
  /// **'Role'**
  String get assistantEditVariableRole;

  /// No description provided for @assistantEditVariableMessage.
  ///
  /// In en, this message translates to:
  /// **'Message'**
  String get assistantEditVariableMessage;

  /// No description provided for @assistantEditPresetAddUser.
  ///
  /// In en, this message translates to:
  /// **'Add User'**
  String get assistantEditPresetAddUser;

  /// No description provided for @assistantEditPresetAddAssistant.
  ///
  /// In en, this message translates to:
  /// **'Add AI'**
  String get assistantEditPresetAddAssistant;

  /// No description provided for @assistantEditPresetTitle.
  ///
  /// In en, this message translates to:
  /// **'Preset'**
  String get assistantEditPresetTitle;

  /// No description provided for @assistantEditPresetEmpty.
  ///
  /// In en, this message translates to:
  /// **'Empty'**
  String get assistantEditPresetEmpty;

  /// No description provided for @assistantEditPresetInputHintAssistant.
  ///
  /// In en, this message translates to:
  /// **'AI'**
  String get assistantEditPresetInputHintAssistant;

  /// No description provided for @assistantEditPresetInputHintUser.
  ///
  /// In en, this message translates to:
  /// **'User'**
  String get assistantEditPresetInputHintUser;

  /// No description provided for @assistantEditPresetEditDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get assistantEditPresetEditDialogTitle;

  /// No description provided for @assistantEditMcpConnectedTag.
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get assistantEditMcpConnectedTag;

  /// No description provided for @assistantEditQuickPhraseDescription.
  ///
  /// In en, this message translates to:
  /// **'Quick phrases'**
  String get assistantEditQuickPhraseDescription;

  /// No description provided for @assistantEditAddQuickPhraseButton.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get assistantEditAddQuickPhraseButton;

  /// No description provided for @assistantEditTemperatureTitle.
  ///
  /// In en, this message translates to:
  /// **'Temp'**
  String get assistantEditTemperatureTitle;

  /// No description provided for @assistantEditTopPTitle.
  ///
  /// In en, this message translates to:
  /// **'Top P'**
  String get assistantEditTopPTitle;

  /// No description provided for @mermaidPreviewOpenFailed.
  ///
  /// In en, this message translates to:
  /// **'Open failed'**
  String get mermaidPreviewOpenFailed;

  /// No description provided for @qrScanPageTitle.
  ///
  /// In en, this message translates to:
  /// **'Scan QR'**
  String get qrScanPageTitle;

  /// No description provided for @qrScanPageInstruction.
  ///
  /// In en, this message translates to:
  /// **'Align QR code'**
  String get qrScanPageInstruction;

  /// No description provided for @defaultModelPageBackTooltip.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get defaultModelPageBackTooltip;

  /// No description provided for @defaultModelPageTitle.
  ///
  /// In en, this message translates to:
  /// **'Default Model'**
  String get defaultModelPageTitle;

  /// No description provided for @defaultModelPageTitleVars.
  ///
  /// In en, this message translates to:
  /// **'{contentVar} {localeVar}'**
  String defaultModelPageTitleVars(String contentVar, String localeVar);

  /// No description provided for @defaultModelPageTranslateVars.
  ///
  /// In en, this message translates to:
  /// **'{sourceVar} {targetVar}'**
  String defaultModelPageTranslateVars(String sourceVar, String targetVar);

  /// No description provided for @defaultModelPageSummaryVars.
  ///
  /// In en, this message translates to:
  /// **'{previousSummaryVar} {userMessagesVar}'**
  String defaultModelPageSummaryVars(
    String previousSummaryVar,
    String userMessagesVar,
  );

  /// No description provided for @messageEditPageSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get messageEditPageSave;

  /// No description provided for @chatMessageWidgetTranslating.
  ///
  /// In en, this message translates to:
  /// **'Translating...'**
  String get chatMessageWidgetTranslating;

  /// No description provided for @messageExportSheetAssistant.
  ///
  /// In en, this message translates to:
  /// **'Assistant'**
  String get messageExportSheetAssistant;

  /// No description provided for @messageExportSheetDefaultTitle.
  ///
  /// In en, this message translates to:
  /// **'New Chat'**
  String get messageExportSheetDefaultTitle;

  /// No description provided for @messageExportSheetExportedAs.
  ///
  /// In en, this message translates to:
  /// **'Exported as {filename}'**
  String messageExportSheetExportedAs(String filename);

  /// No description provided for @messageExportSheetExportFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed: {error}'**
  String messageExportSheetExportFailed(String error);

  /// No description provided for @messageExportSheetFormatTitle.
  ///
  /// In en, this message translates to:
  /// **'Format'**
  String get messageExportSheetFormatTitle;

  /// No description provided for @multiKeyPageTitle.
  ///
  /// In en, this message translates to:
  /// **'Keys'**
  String get multiKeyPageTitle;

  /// No description provided for @multiKeyPageDeleteErrorsTooltip.
  ///
  /// In en, this message translates to:
  /// **'Delete errors'**
  String get multiKeyPageDeleteErrorsTooltip;

  /// No description provided for @multiKeyPageDetect.
  ///
  /// In en, this message translates to:
  /// **'Detect'**
  String get multiKeyPageDetect;

  /// No description provided for @multiKeyPageAdd.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get multiKeyPageAdd;

  /// No description provided for @multiKeyPageTotal.
  ///
  /// In en, this message translates to:
  /// **'Total'**
  String get multiKeyPageTotal;

  /// No description provided for @multiKeyPageNormal.
  ///
  /// In en, this message translates to:
  /// **'Normal'**
  String get multiKeyPageNormal;

  /// No description provided for @multiKeyPageError.
  ///
  /// In en, this message translates to:
  /// **'Error'**
  String get multiKeyPageError;

  /// No description provided for @multiKeyPageStrategyPriority.
  ///
  /// In en, this message translates to:
  /// **'Priority'**
  String get multiKeyPageStrategyPriority;

  /// No description provided for @multiKeyPageStrategyLeastUsed.
  ///
  /// In en, this message translates to:
  /// **'Least Used'**
  String get multiKeyPageStrategyLeastUsed;

  /// No description provided for @multiKeyPageStrategyRandom.
  ///
  /// In en, this message translates to:
  /// **'Random'**
  String get multiKeyPageStrategyRandom;

  /// No description provided for @multiKeyPageStrategyRoundRobin.
  ///
  /// In en, this message translates to:
  /// **'Round Robin'**
  String get multiKeyPageStrategyRoundRobin;

  /// No description provided for @multiKeyPageStrategyTitle.
  ///
  /// In en, this message translates to:
  /// **'Strategy'**
  String get multiKeyPageStrategyTitle;

  /// No description provided for @multiKeyPageNoKeys.
  ///
  /// In en, this message translates to:
  /// **'No keys'**
  String get multiKeyPageNoKeys;

  /// No description provided for @multiKeyPageStatusActive.
  ///
  /// In en, this message translates to:
  /// **'Active'**
  String get multiKeyPageStatusActive;

  /// No description provided for @multiKeyPageStatusDisabled.
  ///
  /// In en, this message translates to:
  /// **'Disabled'**
  String get multiKeyPageStatusDisabled;

  /// No description provided for @multiKeyPageStatusError.
  ///
  /// In en, this message translates to:
  /// **'Error'**
  String get multiKeyPageStatusError;

  /// No description provided for @multiKeyPageStatusRateLimited.
  ///
  /// In en, this message translates to:
  /// **'Limited'**
  String get multiKeyPageStatusRateLimited;

  /// No description provided for @multiKeyPageEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get multiKeyPageEdit;

  /// No description provided for @multiKeyPageDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get multiKeyPageDelete;

  /// No description provided for @multiKeyPageDeleteSnackbarDeletedOne.
  ///
  /// In en, this message translates to:
  /// **'Deleted'**
  String get multiKeyPageDeleteSnackbarDeletedOne;

  /// No description provided for @multiKeyPageUndo.
  ///
  /// In en, this message translates to:
  /// **'Undo'**
  String get multiKeyPageUndo;

  /// No description provided for @multiKeyPageUndoRestored.
  ///
  /// In en, this message translates to:
  /// **'Restored'**
  String get multiKeyPageUndoRestored;

  /// No description provided for @multiKeyPageDuplicateKeyWarning.
  ///
  /// In en, this message translates to:
  /// **'Duplicate'**
  String get multiKeyPageDuplicateKeyWarning;

  /// No description provided for @multiKeyPageImportedSnackbar.
  ///
  /// In en, this message translates to:
  /// **'Imported {n}'**
  String multiKeyPageImportedSnackbar(int n);

  /// No description provided for @multiKeyPagePleaseAddModel.
  ///
  /// In en, this message translates to:
  /// **'Add model'**
  String get multiKeyPagePleaseAddModel;

  /// No description provided for @multiKeyPageDeleteErrorsConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete errors'**
  String get multiKeyPageDeleteErrorsConfirmTitle;

  /// No description provided for @multiKeyPageDeleteErrorsConfirmContent.
  ///
  /// In en, this message translates to:
  /// **'Delete all error keys?'**
  String get multiKeyPageDeleteErrorsConfirmContent;

  /// No description provided for @multiKeyPageDeletedErrorsSnackbar.
  ///
  /// In en, this message translates to:
  /// **'Deleted {n}'**
  String multiKeyPageDeletedErrorsSnackbar(int n);

  /// No description provided for @multiKeyPageAlias.
  ///
  /// In en, this message translates to:
  /// **'Alias'**
  String get multiKeyPageAlias;

  /// No description provided for @multiKeyPagePriority.
  ///
  /// In en, this message translates to:
  /// **'Priority'**
  String get multiKeyPagePriority;

  /// No description provided for @multiKeyPageSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get multiKeyPageSave;

  /// No description provided for @multiKeyPageCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get multiKeyPageCancel;

  /// No description provided for @multiKeyPageAddHint.
  ///
  /// In en, this message translates to:
  /// **'Keys'**
  String get multiKeyPageAddHint;

  /// No description provided for @codeBlockPreviewButton.
  ///
  /// In en, this message translates to:
  /// **'Preview'**
  String get codeBlockPreviewButton;

  /// No description provided for @htmlPreviewNotSupportedOnLinux.
  ///
  /// In en, this message translates to:
  /// **'Not on Linux'**
  String get htmlPreviewNotSupportedOnLinux;

  /// No description provided for @codeBlockCollapsedLines.
  ///
  /// In en, this message translates to:
  /// **'{n} lines'**
  String codeBlockCollapsedLines(int n);

  /// No description provided for @mermaidExportFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed'**
  String get mermaidExportFailed;

  /// No description provided for @mermaidPreviewOpen.
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get mermaidPreviewOpen;

  /// No description provided for @imageViewerPageSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed: {error}'**
  String imageViewerPageSaveFailed(String error);

  /// No description provided for @imageViewerPageSaveSuccess.
  ///
  /// In en, this message translates to:
  /// **'Saved'**
  String get imageViewerPageSaveSuccess;

  /// No description provided for @imageViewerPageSaveButton.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get imageViewerPageSaveButton;

  /// No description provided for @imageViewerPageShareFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed: {error}'**
  String imageViewerPageShareFailed(String error);

  /// No description provided for @imageViewerPageShareFailedOpenFile.
  ///
  /// In en, this message translates to:
  /// **'Failed: {message}'**
  String imageViewerPageShareFailedOpenFile(String message);

  /// No description provided for @desktopNavTranslateTooltip.
  ///
  /// In en, this message translates to:
  /// **'Translate'**
  String get desktopNavTranslateTooltip;

  /// No description provided for @translatePagePasteButton.
  ///
  /// In en, this message translates to:
  /// **'Paste'**
  String get translatePagePasteButton;

  /// No description provided for @translatePageCopyResult.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get translatePageCopyResult;

  /// No description provided for @translatePageClearAll.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get translatePageClearAll;

  /// No description provided for @translatePageInputHint.
  ///
  /// In en, this message translates to:
  /// **'Input'**
  String get translatePageInputHint;

  /// No description provided for @translatePageOutputHint.
  ///
  /// In en, this message translates to:
  /// **'Output'**
  String get translatePageOutputHint;

  /// No description provided for @chatMessageWidgetStopTooltip.
  ///
  /// In en, this message translates to:
  /// **'Stop'**
  String get chatMessageWidgetStopTooltip;

  /// No description provided for @chatMessageWidgetTranslateTooltip.
  ///
  /// In en, this message translates to:
  /// **'Translate'**
  String get chatMessageWidgetTranslateTooltip;

  /// No description provided for @assistantEditTemperatureDescription.
  ///
  /// In en, this message translates to:
  /// **'Temp desc'**
  String get assistantEditTemperatureDescription;

  /// No description provided for @assistantEditTopPDescription.
  ///
  /// In en, this message translates to:
  /// **'Top P desc'**
  String get assistantEditTopPDescription;

  /// No description provided for @assistantEditMaxTokensDescription.
  ///
  /// In en, this message translates to:
  /// **'Max tokens desc'**
  String get assistantEditMaxTokensDescription;

  /// No description provided for @defaultModelPageUseCurrentModel.
  ///
  /// In en, this message translates to:
  /// **'Use current'**
  String get defaultModelPageUseCurrentModel;

  /// No description provided for @defaultModelPageChatModelTitle.
  ///
  /// In en, this message translates to:
  /// **'Chat Model'**
  String get defaultModelPageChatModelTitle;

  /// No description provided for @defaultModelPageChatModelSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Default chat model'**
  String get defaultModelPageChatModelSubtitle;

  /// No description provided for @defaultModelPageTitleModelTitle.
  ///
  /// In en, this message translates to:
  /// **'Title Model'**
  String get defaultModelPageTitleModelTitle;

  /// No description provided for @defaultModelPageTitleModelSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Summarize titles'**
  String get defaultModelPageTitleModelSubtitle;

  /// No description provided for @defaultModelPageSummaryModelTitle.
  ///
  /// In en, this message translates to:
  /// **'Summary Model'**
  String get defaultModelPageSummaryModelTitle;

  /// No description provided for @defaultModelPageSummaryModelSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Summarize conversations'**
  String get defaultModelPageSummaryModelSubtitle;

  /// No description provided for @defaultModelPageTranslateModelTitle.
  ///
  /// In en, this message translates to:
  /// **'Translate Model'**
  String get defaultModelPageTranslateModelTitle;

  /// No description provided for @defaultModelPageTranslateModelSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Translation model'**
  String get defaultModelPageTranslateModelSubtitle;

  /// No description provided for @defaultModelPageOcrModelTitle.
  ///
  /// In en, this message translates to:
  /// **'OCR Model'**
  String get defaultModelPageOcrModelTitle;

  /// No description provided for @defaultModelPageOcrModelSubtitle.
  ///
  /// In en, this message translates to:
  /// **'OCR model'**
  String get defaultModelPageOcrModelSubtitle;

  /// No description provided for @defaultModelPageTitlePromptHint.
  ///
  /// In en, this message translates to:
  /// **'Title prompt hint'**
  String get defaultModelPageTitlePromptHint;

  /// No description provided for @defaultModelPageTranslatePromptHint.
  ///
  /// In en, this message translates to:
  /// **'Translate prompt hint'**
  String get defaultModelPageTranslatePromptHint;

  /// No description provided for @defaultModelPageSummaryPromptHint.
  ///
  /// In en, this message translates to:
  /// **'Summary prompt hint'**
  String get defaultModelPageSummaryPromptHint;

  /// No description provided for @assistantEditEmojiDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Emoji'**
  String get assistantEditEmojiDialogTitle;

  /// No description provided for @assistantEditEmojiDialogHint.
  ///
  /// In en, this message translates to:
  /// **'Pick an emoji'**
  String get assistantEditEmojiDialogHint;

  /// No description provided for @importProviderSheetCancelButton.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get importProviderSheetCancelButton;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when language+script codes are specified.
  switch (locale.languageCode) {
    case 'zh':
      {
        switch (locale.scriptCode) {
          case 'Hans':
            return AppLocalizationsZhHans();
          case 'Hant':
            return AppLocalizationsZhHant();
        }
        break;
      }
  }

  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
