import 'dart:convert';
import 'preset_message.dart';
import 'assistant_regex.dart';
import 'workspace_config.dart';

class Assistant {
  final String id;
  final String name;
  final String? avatar; // path/url/base64, null for initial-letter avatar
  final bool
  useAssistantAvatar; // replace model icon in chat with assistant avatar
  final String? chatModelProvider; // null -> use global default
  final String? chatModelId; // null -> use global default
  final double? temperature; // null to disable; else 0.0 - 2.0
  final double? topP; // null to disable; else 0.0 - 1.0
  final int contextMessageSize; // number of previous messages to include
  final bool limitContextMessages; // whether to enforce contextMessageSize
  final bool streamOutput; // streaming responses
  final int?
  thinkingBudget; // null = use global/default; 0=off; >0 tokens budget
  final int? maxTokens; // null = unlimited
  final String systemPrompt;
  final String messageTemplate; // e.g. "{{ message }}"
  final List<String> mcpServerIds; // bound MCP server IDs
  final WorkspaceConfig workspace;
  final String? background; // chat background (color/image ref)
  final bool deletable; // can be deleted by user
  // Custom request overrides (per assistant)
  final List<Map<String, String>>
  customHeaders; // [{name:'X-Header', value:'v'}]
  final List<Map<String, String>> customBody; // [{key:'foo', value:'{"a":1}'}]
  // Memory features
  final bool enableMemory; // assistant memory feature switch
  final bool enableRecentChatsReference; // include recent chat titles in prompt
  // Preset conversation messages (ordered)
  final List<PresetMessage> presetMessages;
  // Regex replacement rules (per assistant)
  final List<AssistantRegex> regexRules;

  const Assistant({
    required this.id,
    required this.name,
    this.avatar,
    this.useAssistantAvatar = false,
    this.chatModelProvider,
    this.chatModelId,
    this.temperature,
    this.topP,
    this.contextMessageSize = 64,
    this.limitContextMessages = false,
    this.streamOutput = true,
    this.thinkingBudget,
    this.maxTokens,
    this.systemPrompt = '',
    this.messageTemplate = '{{ message }}',
    this.mcpServerIds = const <String>[],
    this.workspace = const WorkspaceConfig.useDefault(),
    this.background,
    this.deletable = true,
    this.customHeaders = const <Map<String, String>>[],
    this.customBody = const <Map<String, String>>[],
    this.enableMemory = false,
    this.enableRecentChatsReference = false,
    this.presetMessages = const <PresetMessage>[],
    this.regexRules = const <AssistantRegex>[],
  });

  Assistant copyWith({
    String? id,
    String? name,
    String? avatar,
    bool? useAssistantAvatar,
    String? chatModelProvider,
    String? chatModelId,
    double? temperature,
    double? topP,
    int? contextMessageSize,
    bool? limitContextMessages,
    bool? streamOutput,
    int? thinkingBudget,
    int? maxTokens,
    String? systemPrompt,
    String? messageTemplate,
    List<String>? mcpServerIds,
    WorkspaceConfig? workspace,
    String? background,
    bool? deletable,
    List<Map<String, String>>? customHeaders,
    List<Map<String, String>>? customBody,
    bool? enableMemory,
    bool? enableRecentChatsReference,
    List<PresetMessage>? presetMessages,
    List<AssistantRegex>? regexRules,
    bool clearChatModel = false,
    bool clearAvatar = false,
    bool clearThinkingBudget = false,
    bool clearBackground = false,
  }) {
    return Assistant(
      id: id ?? this.id,
      name: name ?? this.name,
      avatar: clearAvatar ? null : (avatar ?? this.avatar),
      useAssistantAvatar: useAssistantAvatar ?? this.useAssistantAvatar,
      chatModelProvider: clearChatModel
          ? null
          : (chatModelProvider ?? this.chatModelProvider),
      chatModelId: clearChatModel ? null : (chatModelId ?? this.chatModelId),
      temperature: temperature ?? this.temperature,
      topP: topP ?? this.topP,
      contextMessageSize: contextMessageSize ?? this.contextMessageSize,
      limitContextMessages: limitContextMessages ?? this.limitContextMessages,
      streamOutput: streamOutput ?? this.streamOutput,
      thinkingBudget: clearThinkingBudget
          ? null
          : (thinkingBudget ?? this.thinkingBudget),
      maxTokens: maxTokens ?? this.maxTokens,
      systemPrompt: systemPrompt ?? this.systemPrompt,
      messageTemplate: messageTemplate ?? this.messageTemplate,
      mcpServerIds: mcpServerIds ?? this.mcpServerIds,
      workspace: workspace ?? this.workspace,
      background: clearBackground ? null : (background ?? this.background),
      deletable: deletable ?? this.deletable,
      customHeaders: customHeaders ?? this.customHeaders,
      customBody: customBody ?? this.customBody,
      enableMemory: enableMemory ?? this.enableMemory,
      enableRecentChatsReference:
          enableRecentChatsReference ?? this.enableRecentChatsReference,
      presetMessages: presetMessages ?? this.presetMessages,
      regexRules: regexRules ?? this.regexRules,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'avatar': avatar,
    'useAssistantAvatar': useAssistantAvatar,
    'chatModelProvider': chatModelProvider,
    'chatModelId': chatModelId,
    'temperature': temperature,
    'topP': topP,
    'contextMessageSize': contextMessageSize,
    'limitContextMessages': limitContextMessages,
    'streamOutput': streamOutput,
    'thinkingBudget': thinkingBudget,
    'maxTokens': maxTokens,
    'systemPrompt': systemPrompt,
    'messageTemplate': messageTemplate,
    'mcpServerIds': mcpServerIds,
    'workspace': workspace.toJson(),
    'background': background,
    'deletable': deletable,
    'customHeaders': customHeaders,
    'customBody': customBody,
    'enableMemory': enableMemory,
    'enableRecentChatsReference': enableRecentChatsReference,
    'presetMessages': PresetMessage.encodeList(presetMessages),
    'regexRules': AssistantRegex.encodeList(regexRules),
  };

  /// 2026-10：這批進階選項已自專案設定頁移除（溫度 / Top-p / 上下文訊息數量 /
  /// 最大 Token 數 / 串流輸出）。欄位與 JSON 鍵保留（備份、第三方匯入的形狀
  /// 相容），但一律以預設值解讀，舊存值不再生效——載入即視為已重設。這裡
  /// 刻意不傳這些參數：建構子預設（`temperature`/`topP`/`maxTokens` = null、
  /// `contextMessageSize` 64、`limitContextMessages` false、`streamOutput`
  /// true）就是還原值的唯一真相來源。
  /// `thinkingBudget` 不在此列：聊天頁「推理設定」仍寫入它，須正常持久化。
  static Assistant fromJson(Map<String, dynamic> json) => Assistant(
    id: json['id'] as String,
    name: (json['name'] as String?) ?? '',
    avatar: json['avatar'] as String?,
    useAssistantAvatar: json['useAssistantAvatar'] as bool? ?? false,
    chatModelProvider: json['chatModelProvider'] as String?,
    chatModelId: json['chatModelId'] as String?,
    thinkingBudget: (json['thinkingBudget'] as num?)?.toInt(),
    systemPrompt: (json['systemPrompt'] as String?) ?? '',
    messageTemplate: (json['messageTemplate'] as String?) ?? '{{ message }}',
    mcpServerIds:
        (json['mcpServerIds'] as List?)?.cast<String>() ?? const <String>[],
    workspace: WorkspaceConfig.fromJson(
      json['workspace'],
      fallback: WorkspaceMode.useDefault,
    ),
    background: json['background'] as String?,
    deletable: json['deletable'] as bool? ?? true,
    customHeaders: (() {
      final raw = json['customHeaders'];
      if (raw is List) {
        return raw
            .whereType<Map>()
            .map(
              (e) => {
                'name': (e['name'] ?? e['key'] ?? '').toString(),
                'value': (e['value'] ?? '').toString(),
              },
            )
            .toList();
      }
      return const <Map<String, String>>[];
    })(),
    customBody: (() {
      final raw = json['customBody'];
      if (raw is List) {
        return raw
            .whereType<Map>()
            .map(
              (e) => {
                'key': (e['key'] ?? e['name'] ?? '').toString(),
                'value': (e['value'] ?? '').toString(),
              },
            )
            .toList();
      }
      return const <Map<String, String>>[];
    })(),
    enableMemory: json['enableMemory'] as bool? ?? false,
    enableRecentChatsReference:
        json['enableRecentChatsReference'] as bool? ?? false,
    presetMessages: (() {
      try {
        return PresetMessage.decodeList(json['presetMessages']);
      } catch (_) {
        return const <PresetMessage>[];
      }
    })(),
    regexRules: (() {
      try {
        return AssistantRegex.decodeList(json['regexRules']);
      } catch (_) {
        return const <AssistantRegex>[];
      }
    })(),
  );

  static String encodeList(List<Assistant> list) =>
      jsonEncode(list.map((e) => e.toJson()).toList());
  static List<Assistant> decodeList(String raw) {
    try {
      final arr = jsonDecode(raw) as List<dynamic>;
      return [
        for (final e in arr) Assistant.fromJson(e as Map<String, dynamic>),
      ];
    } catch (_) {
      return const <Assistant>[];
    }
  }
}
