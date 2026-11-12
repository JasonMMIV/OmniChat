import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import '../../../core/models/assistant.dart';
import '../../../core/models/chat_input_data.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/conversation.dart';
import '../../../core/models/instruction_injection.dart';
import '../../../core/providers/memory_provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/providers/user_provider.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/chat/document_text_extractor.dart';
import '../../../core/services/chat/prompt_transformer.dart';
import '../../../core/services/chat/tool_replay.dart';
import '../../../core/services/chat/todo_models.dart';
import '../../../core/services/instruction_injection_store.dart';
import '../../../core/services/search/search_tool_service.dart';
import '../../../core/models/memory_entry.dart';
import '../../../core/services/memory/memory_block_builder.dart';
import '../../../core/services/logging/flutter_logger.dart';
import '../../../core/providers/instruction_injection_provider.dart';
import '../../../core/services/api/attachment_kind.dart';
import '../../../core/services/api/builtin_tools.dart';
import '../../../core/services/api/native_input_parts.dart';
import '../../../core/services/api/native_input_policy.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../utils/sandbox_path_resolver.dart';
import '../../../core/services/agent/compaction/history_compactor.dart';
import '../../../core/services/agent/compaction/tool_pairing.dart';
import '../../../core/services/agent/compaction/tool_result_pruner.dart';
import '../../../utils/markdown_media_sanitizer.dart';

/// Normalize a stored tool result for model consumption.
///
/// Null/empty results become empty string (providers decide whether to
/// substitute a placeholder such as `(no output)` for Claude). Kept as a
/// top-level function so it can also be shared by other services/tests.
String toolResultContentForModel(String? content) {
  if (content == null) return '';
  return content;
}

/// Appends the P1-3 synthetic trailing todo state pair (§2.3.2 of
/// docs/write_todos_improvement_plan.md): an assistant `write_todos` call
/// plus its full canonical snapshot result, pinned to the conversation tail.
///
/// This REPLACED the old system-prompt injection: dynamic plan state no
/// longer touches the system message, so the cache prefix (system + tools)
/// stays byte-identical across todo updates and only the tail changes.
///
/// - Pair id prefers the latest successful event's real `toolCallId`; an
///   empty or colliding id falls back to a deterministic
///   `todo_state_<hash>` (never a timestamp — retries must keep the id
///   stable so the cache prefix does not churn).
/// - The pair is skipped when the last two messages already are the same
///   state pair (same-turn re-assembly) or when the state carries no
///   explicit `write_todos` event.
///
/// Top-level (not a method) so the injection contract is unit-testable
/// without a provider tree, like [toolResultContentForModel].
void appendTodoStatePair(
  List<Map<String, dynamic>> apiMessages,
  TodoState state,
) {
  if (!state.hasExplicitState) return;
  final items = state.items;
  final hasIncomplete = items.any((t) => !t.isCompleted);

  final argsJson = buildTodoStateArgumentsJson(items);
  final content = buildTodoResultContent(
    items: items,
    changed: false,
    cleared: items.isEmpty,
    includeItems: true,
    notice: items.isEmpty
        ? 'Current plan: cleared. Call write_todos with a complete new list '
              'only if the task still needs tracking.'
        : hasIncomplete
        ? 'Current plan state: the latest write_todos snapshot. If this '
              'request continues the plan, resume from the first unfinished '
              'item; otherwise replace the list with steps for the new task. '
              'After finishing each step, call write_todos again, rewrite ALL '
              'todos with their current statuses, and mark that step completed.'
        : 'Current plan state: all items are completed. No further '
              'write_todos update is needed unless the task changes.',
  );

  var id = (state.sourceToolCallId ?? '').trim();
  if (id.isEmpty || _containsToolCallId(apiMessages, id)) {
    id = todoStateHashId(items, seed: state.sourceMessageId ?? '');
  }
  if (_endsWithTodoStatePair(apiMessages, id)) return;

  apiMessages.addAll(<Map<String, dynamic>>[
    <String, dynamic>{
      'role': 'assistant',
      'content': '\n\n',
      'tool_calls': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': id,
          'type': 'function',
          'function': <String, dynamic>{
            'name': todoToolName,
            'arguments': argsJson,
          },
        },
      ],
    },
    <String, dynamic>{
      'role': 'tool',
      'name': todoToolName,
      'tool_call_id': id,
      'content': content,
    },
  ]);
}

/// Whether the synthetic trailing todo pair may be appended for this request.
///
/// Gemini native built-ins strip every function declaration after assembly, so
/// the pair's `functionCall`/`functionResponse` would reference a tool the
/// model cannot call. The projected plan still reaches the model through the
/// compaction summary, but the state pair must be skipped.
bool shouldAppendTodoStatePair({
  required bool toolHasTodo,
  required bool hasBuiltInSearch,
  required TodoState? state,
}) => toolHasTodo && !hasBuiltInSearch && state != null;

bool _containsToolCallId(List<Map<String, dynamic>> apiMessages, String id) {
  for (final message in apiMessages) {
    final calls = message['tool_calls'];
    if (calls is! List) continue;
    for (final call in calls) {
      if (call is Map && call['id']?.toString() == id) return true;
    }
  }
  return false;
}

bool _endsWithTodoStatePair(
  List<Map<String, dynamic>> apiMessages,
  String id,
) {
  if (apiMessages.length < 2) return false;
  final tool = apiMessages[apiMessages.length - 1];
  final call = apiMessages[apiMessages.length - 2];
  if (tool['role'] != 'tool' || tool['tool_call_id']?.toString() != id) {
    return false;
  }
  if (call['role'] != 'assistant') return false;
  final calls = call['tool_calls'];
  if (calls is! List) return false;
  return calls.any(
    (c) => c is Map && c['id']?.toString() == id,
  );
}

/// Resolve the text content of a user message after attachment markers were
/// processed.
///
/// - non-empty text wins;
/// - empty text with native parts stays empty (the wire parts carry the turn);
/// - empty text with no native parts gets the localized placeholder, so the
///   request never contains an empty user turn (Gemini `parts: []`, Claude
///   empty content, strict OpenAI validators). Historical turns use the same
///   placeholder: dropping them can leave a leading assistant turn, which
///   Gemini/relays reject.
String resolveUserMessageContent({
  required String content,
  required bool hasNativeParts,
  required String emptyPlaceholder,
}) {
  if (content.isNotEmpty) return content;
  if (hasNativeParts) return '';
  return emptyPlaceholder;
}

/// Service for building API messages from conversation state.
///
/// This service handles:
/// - Building API messages list from chat history
/// - Processing user messages (documents, OCR, templates)
/// - Injecting system prompts
/// - Injecting memory and recent chats context
/// - Injecting search prompts
/// - Injecting instruction prompts
/// - Applying context limits
/// - Inlining local images for model context
class MessageBuilderService {
  MessageBuilderService({
    required this.chatService,
    required this.contextProvider,
    this.ocrHandler,
    this.geminiThoughtSignatureHandler,
  });

  final ChatService chatService;

  /// Build context (used for accessing providers via context.read)
  final BuildContext contextProvider;

  /// OCR handler for processing images (optional, injected from home_page)
  final Future<String?> Function(List<String> imagePaths)? ocrHandler;

  /// OCR text wrapper function
  String Function(String ocrText)? ocrTextWrapper;

  /// Handler to append Gemini thought signatures for API calls
  final String Function(ChatMessage message, String content)?
  geminiThoughtSignatureHandler;

  /// Collapse message versions to show only selected version per group.
  List<ChatMessage> collapseVersions(
    List<ChatMessage> items,
    Map<String, int> versionSelections,
  ) {
    final Map<String, List<ChatMessage>> byGroup =
        <String, List<ChatMessage>>{};
    final List<String> order = <String>[];

    for (final m in items) {
      final gid = (m.groupId ?? m.id);
      final list = byGroup.putIfAbsent(gid, () {
        order.add(gid);
        return <ChatMessage>[];
      });
      list.add(m);
    }

    // Sort each group by version
    for (final e in byGroup.entries) {
      e.value.sort((a, b) => a.version.compareTo(b.version));
    }

    // Select the appropriate version from each group
    final out = <ChatMessage>[];
    for (final gid in order) {
      final vers = byGroup[gid]!;
      final sel = versionSelections[gid];
      final idx = (sel != null && sel >= 0 && sel < vers.length)
          ? sel
          : (vers.length - 1);
      out.add(vers[idx]);
    }

    return out;
  }

  /// Build API messages list from current conversation state.
  ///
  /// Applies truncation, version collapsing, and strips [image:] / [file:] markers.
  ///
  /// When [includeToolMessages] is true, for each assistant message whose tool
  /// events are all resolved (every call has a result), the tool calls and their
  /// results are replayed as OpenAI-format `tool_calls` / `role:'tool'` messages
  /// right before that assistant's reply text. This lets the model "remember"
  /// what tools did in earlier turns (matches upstream kelivo behavior).
  ///
  /// P1-2 auto-compaction (when [enableAutoCompaction] is true):
  /// - L1: raw messages before `currentConversation.compactBeforeIndex` are
  ///   mechanically rewritten into one deterministic `<conversation_summary>`
  ///   user message at the front (non-destructive — Hive history is never
  ///   rewritten; the summary is recomputed at every assembly).
  /// - L0: every `role:'tool'` result is middle-pruned above the 8192-char
  ///   threshold (4096 head / 1024 tail).
  List<Map<String, dynamic>> buildApiMessages({
    required List<ChatMessage> messages,
    required Map<String, int> versionSelections,
    required Conversation? currentConversation,
    bool includeToolMessages = false,
    bool enableAutoCompaction = false,
    String? compactionNextAction,
    String? compactionTodoSummary,
    bool includeGeminiThoughtSignatures = true,
  }) {
    final tIndex = currentConversation?.truncateIndex ?? -1;
    final List<ChatMessage> sourceAll =
        (tIndex >= 0 && tIndex <= messages.length)
        ? messages.sublist(tIndex)
        : List.of(messages);

    // P1-2 L1 split: [0, compactSplit) of the post-truncate list is the
    // compacted range; the rest stays live. compactBeforeIndex lives in the
    // same raw-index space as truncateIndex.
    List<ChatMessage>? headSource;
    List<ChatMessage> tailSource;
    if (enableAutoCompaction && currentConversation != null) {
      final cIndex = currentConversation.compactBeforeIndex;
      final rawStart = (tIndex >= 0 && tIndex <= messages.length) ? tIndex : 0;
      final compactSplit = cIndex - rawStart;
      if (cIndex > 0 && compactSplit > 0 && compactSplit < sourceAll.length) {
        headSource = collapseVersions(
          sourceAll.sublist(0, compactSplit),
          versionSelections,
        );
        tailSource = collapseVersions(
          sourceAll.sublist(compactSplit),
          versionSelections,
        );
      } else {
        tailSource = collapseVersions(sourceAll, versionSelections);
      }
    } else {
      tailSource = collapseVersions(sourceAll, versionSelections);
    }

    final out = <Map<String, dynamic>>[];
    if (headSource != null && headSource.isNotEmpty) {
      final headApi = neutralMessagesFor(
        headSource,
        includeToolMessages,
        includeGeminiThoughtSignatures: includeGeminiThoughtSignatures,
      );
      final summary = compactHistoryMessages(
        headApi,
        nextActionOverride: compactionNextAction,
        todoSummaryOverride: compactionTodoSummary,
      );
      if (summary != null) out.add(summary);
    }
    out.addAll(
      neutralMessagesFor(
        tailSource,
        includeToolMessages,
        includeGeminiThoughtSignatures: includeGeminiThoughtSignatures,
      ),
    );

    if (enableAutoCompaction) {
      applyToolResultMiddlePrune(out);
    }
    return out;
  }

  /// Build the neutral OpenAI-format message list for a slice of raw chat
  /// messages, replaying resolved tool events before each assistant reply
  /// when [includeToolMessages] is set.
  List<Map<String, dynamic>> neutralMessagesFor(
    List<ChatMessage> source,
    bool includeToolMessages, {
    bool includeGeminiThoughtSignatures = true,
  }) {
    final out = <Map<String, dynamic>>[];
    for (final m in source) {
      if (includeToolMessages && m.role == 'assistant') {
        // §9.5.2: replay only completed/denied pairs. Pending and interrupted
        // events are omitted as a pair; a pending approval-protocol payload
        // is never mistaken for a tool result. `denied` replays its denial
        // JSON, which is the one approval shape the model should see.
        final pairs = buildToolReplayPairs(
          chatService.getToolEvents(m.id),
          messageId: m.id,
        );
        if (pairs.isNotEmpty) {
          final calls = <Map<String, dynamic>>[];
          final toolMessages = <Map<String, dynamic>>[];
          // Pairs that actually produced a replayed call/result — used below
          // to gather the persisted reasoning-echo extras.
          for (final pair in pairs) {
            Map<String, dynamic> args = const <String, dynamic>{};
            final a = pair.event['arguments'];
            if (a is Map) {
              args = a.map((k, v) => MapEntry(k.toString(), v));
            }
            String argumentsJson = '{}';
            try {
              argumentsJson = jsonEncode(args);
            } catch (_) {}

            calls.add({
              'id': pair.toolCallId,
              'type': 'function',
              'function': {'name': pair.toolName, 'arguments': argumentsJson},
            });
            final imageSha256 = pair.event['imageSha256'];
            toolMessages.add({
              'role': 'tool',
              'name': pair.toolName,
              'tool_call_id': pair.toolCallId,
              'content': toolResultContentForModel(pair.content),
              // Stage 2: snapshot hash persisted by the tool handler. The
              // image path itself is NOT trusted from persisted extras (an
              // imported backup could forge it); outside-workspace approvals
              // travel through the live in-memory ledger instead.
              if (imageSha256 is String && imageSha256.trim().isNotEmpty)
                '_tool_image_sha256': imageSha256,
            });
          }

          // P1-3 fix: re-attach the reasoning-echo fields persisted on the
          // tool events. DeepSeek (and Zhipu/Kimi/Mimo) thinking-mode
          // endpoints reject a conversation whose assistant `tool_calls`
          // message does not carry `reasoning_content` back (HTTP 400:
          // "The reasoning_content in the thinking mode must be passed
          // back to the API"). Providers that do not understand the field
          // strip it at conversion time (ChatApiService), so a plain
          // passthrough here is safe.
          String? reasoningContent;
          final reasoningDetails = <dynamic>[];
          for (final pair in pairs) {
            final rc = pair.event['reasoning_content'];
            if (reasoningContent == null && rc is String && rc.isNotEmpty) {
              reasoningContent = rc;
            }
            final rd = pair.event['reasoning_details'];
            // First-wins (matching reasoningContent): the write side
            // persists the round's echo onto every placeholder event, so a
            // multi-call round would otherwise duplicate the same details
            // list N times.
            if (reasoningDetails.isEmpty && rd is List && rd.isNotEmpty) {
              reasoningDetails.addAll(rd);
            }
          }
          // P1-3 fix (2026-09-11): heal pre-fix history — when the events
          // carry no echo, fall back to this assistant message's own
          // reasoningText. It is the same reasoning stream the transport
          // echoes back to the provider, so the replay stays faithful while
          // satisfying DeepSeek's "reasoning_content must be passed back"
          // requirement on the resumed request.
          if (reasoningContent == null && (m.reasoningText ?? '').isNotEmpty) {
            reasoningContent = m.reasoningText;
          }
          out.add(<String, dynamic>{
            'role': 'assistant',
            'content': '\n\n',
            'tool_calls': calls,
            if (reasoningContent != null) 'reasoning_content': reasoningContent,
            if (reasoningDetails.isNotEmpty)
              'reasoning_details': reasoningDetails,
          });
          out.addAll(toolMessages);
        }
      }

      var content = m.content;
      if (m.role == 'assistant' &&
          includeGeminiThoughtSignatures &&
          geminiThoughtSignatureHandler != null) {
        content = geminiThoughtSignatureHandler!(m, content);
      }
      if (content.isEmpty) continue;
      out.add(<String, dynamic>{
        'role': m.role == 'assistant' ? 'assistant' : 'user',
        'content': content,
        // Provenance for Gemini thought-signature isolation (G2): only an
        // assistant message produced by the same Google endpoint may replay
        // its signature. Internal key; every non-Google transport rebuilds
        // its wire maps from role/content and never forwards it.
        if (includeGeminiThoughtSignatures &&
            m.role == 'assistant' &&
            (m.providerId ?? '').trim().isNotEmpty)
          '_provider_id': m.providerId,
      });
    }
    return out;
  }

  /// Parse input data from raw message content (extracts images and documents).
  ChatInputData parseInputFromRaw(
    String raw, {
    bool includeMediaFilePathsAsImages = true,
  }) {
    final imgRe = RegExp(r"\[image:(.+?)\]");
    final fileRe = RegExp(r"\[file:(.+?)\|(.+?)\|(.+?)\]");
    final images = <String>[];
    final docs = <DocumentAttachment>[];
    final buffer = StringBuffer();
    int idx = 0;
    while (idx < raw.length) {
      final imgMatch = imgRe.matchAsPrefix(raw, idx);
      final fileMatch = fileRe.matchAsPrefix(raw, idx);
      if (imgMatch != null) {
        final p = imgMatch.group(1)?.trim();
        if (p != null && p.isNotEmpty) images.add(p);
        idx = imgMatch.end;
        continue;
      }
      if (fileMatch != null) {
        final path = fileMatch.group(1)?.trim() ?? '';
        final name = fileMatch.group(2)?.trim() ?? 'file';
        final mime = fileMatch.group(3)?.trim() ?? 'text/plain';
        final doc = DocumentAttachment(path: path, fileName: name, mime: mime);
        docs.add(doc);
        // Treat video attachments as image-style attachments for downstream APIs (e.g., Qwen video_url).
        if (includeMediaFilePathsAsImages &&
            mime.toLowerCase().startsWith('video/') &&
            path.isNotEmpty) {
          images.add(path);
        }

        idx = fileMatch.end;
        continue;
      }
      buffer.write(raw[idx]);
      idx++;
    }
    return ChatInputData(
      text: buffer.toString().trim(),
      imagePaths: images,
      documents: docs,
    );
  }

  /// Process user messages in apiMessages: extract documents, apply OCR, inject file prompts.
  ///
  /// Returns the image paths from the last user message (for API call).
  Future<List<String>> processUserMessagesForApi(
    List<Map<String, dynamic>> apiMessages,
    SettingsProvider settings,
    Assistant? assistant, {
    NativeInputPolicy? nativePolicy,
  }) async {
    final bool ocrActive =
        settings.ocrEnabled &&
        settings.ocrModelProvider != null &&
        settings.ocrModelId != null;

    List<String>? lastUserImagePaths;

    // Find last user message index
    int lastUserIdx = -1;
    for (int i = apiMessages.length - 1; i >= 0; i--) {
      if (apiMessages[i]['role'] == 'user') {
        lastUserIdx = i;
        break;
      }
    }

    final Map<String, String?> docTextCache = <String, String?>{};
    Future<String?> readDocument(DocumentAttachment d) async {
      if (docTextCache.containsKey(d.path)) return docTextCache[d.path];
      try {
        final text = await DocumentTextExtractor.extract(
          path: d.path,
          mime: d.mime,
        );
        docTextCache[d.path] = text;
        return text;
      } catch (_) {
        docTextCache[d.path] = null;
        return null;
      }
    }

    for (int i = 0; i < apiMessages.length; i++) {
      if (apiMessages[i]['role'] != 'user') continue;
      final rawUser = (apiMessages[i]['content'] ?? '').toString();
      final parsedUser = parseInputFromRaw(rawUser);

      // Capture image paths from last user message
      if (i == lastUserIdx &&
          lastUserImagePaths == null &&
          parsedUser.imagePaths.isNotEmpty) {
        lastUserImagePaths = List<String>.of(parsedUser.imagePaths);
      }

      final videoPaths = <String>{
        for (final d in parsedUser.documents)
          if (d.mime.toLowerCase().startsWith('video/')) d.path.trim(),
      }..removeWhere((p) => p.isEmpty);

      String cleanedUser = rawUser
          .replaceAll(RegExp(r"\[file:.*?\]"), '')
          .trim();
      if (ocrActive) {
        cleanedUser = cleanedUser.replaceAll(RegExp(r"\[image:.*?\]"), '');
      }

      // Native audio/PDF profile (multimodal plan B1). Only the last user
      // message is sent natively; historical attachments keep the existing
      // text-extraction path. Video is deliberately excluded — it already
      // travels through `userImagePaths` and would otherwise be sent twice
      // (§7 F5).
      final nativeTargets = <NativeAttachment>[];
      final nativePaths = <String>{};
      if (nativePolicy != null &&
          nativePolicy.enabled &&
          i == lastUserIdx) {
        for (final d in parsedUser.documents) {
          final kind = attachmentKindFor(d.mime, d.fileName);
          final wantsAudio =
              kind == AttachmentKind.audio && nativePolicy.nativeAudio;
          final wantsPdf =
              kind == AttachmentKind.pdf && nativePolicy.nativePdf;
          if (!wantsAudio && !wantsPdf) continue;
          nativePaths.add(d.path);
          nativeTargets.add(
            NativeAttachment(
              path: d.path,
              name: d.fileName,
              mime: attachmentMimeFor(d.mime, d.fileName),
              kind: kind,
            ),
          );
        }
      }

      final filePrompts = StringBuffer();
      for (final d in parsedUser.documents) {
        // Video is handled by the multimodal image/video path; audio has no
        // textual representation. Extracting either used to UTF-8 decode the
        // binary into mojibake and replay it on every turn (§7 F2).
        // Skips audio/video (no text representation) and native PDFs
        // (already travelling as a document block — plan B5).
        if (!shouldExtractAttachmentText(
          path: d.path,
          mime: d.mime,
          name: d.fileName,
          nativePaths: nativePaths,
        )) {
          continue;
        }
        final text = await readDocument(d);
        if (text == null || text.trim().isEmpty) continue;
        filePrompts.writeln('## user sent a file: ${d.fileName}');
        filePrompts.writeln('<content>');
        filePrompts.writeln('```');
        filePrompts.writeln(text);
        filePrompts.writeln('```');
        filePrompts.writeln('</content>');
        filePrompts.writeln();
      }

      String merged = (filePrompts.toString() + cleanedUser).trim();

      if (ocrActive && ocrHandler != null) {
        final ocrTargets = parsedUser.imagePaths
            .map((p) => p.trim())
            .where((p) => p.isNotEmpty && !videoPaths.contains(p))
            .toSet()
            .toList();
        if (ocrTargets.isNotEmpty) {
          final ocrText = await ocrHandler!(ocrTargets);
          if (ocrText != null && ocrText.trim().isNotEmpty) {
            final wrapped = ocrTextWrapper != null
                ? ocrTextWrapper!(ocrText)
                : _defaultWrapOcrBlock(ocrText);
            merged = (wrapped + merged).trim();
          }
        }
      }

      apiMessages[i]['content'] = resolveUserMessageContent(
        content: merged.isEmpty ? cleanedUser : merged,
        hasNativeParts: nativeTargets.isNotEmpty,
        emptyPlaceholder: _emptyUserMessagePlaceholder(),
      );

      if (nativeTargets.isNotEmpty) {
        final built = await NativeInputParts.build(
          protocol: nativePolicy!.protocol,
          attachments: nativeTargets,
          baseUrl: nativePolicy.baseUrl,
          fixPath: SandboxPathResolver.fix,
        );
        if (built.parts.isEmpty) {
          // The only content was a native attachment that failed the guard
          // (too large / unreadable). Keep the turn non-empty so the request
          // stays valid on Gemini/Claude while the snackbar explains why.
          apiMessages[i]['content'] = resolveUserMessageContent(
            content: (apiMessages[i]['content'] ?? '').toString(),
            hasNativeParts: false,
            emptyPlaceholder: _emptyUserMessagePlaceholder(),
          );
        }
        if (built.parts.isNotEmpty) {
          apiMessages[i]['_native_input'] = <String, dynamic>{
            'protocol': nativePolicy.protocol.name,
            'parts': built.parts,
          };
          // Neutral attachment profile kept alongside the wire parts so a
          // future image-context governor has one hook (plan §2.6). Transport
          // code reads only `_native_input`; this key is never serialized.
          apiMessages[i]['_attachments'] = <Map<String, dynamic>>[
            for (final a in nativeTargets) a.toMap(),
          ];
        }
        if (built.hasErrors) {
          FlutterLogger.log(
            'Native attachment skipped: '
            '${built.errors.map((e) => e.toString()).join('; ')}',
            tag: 'multimodal',
          );
          if (contextProvider.mounted) {
            final l10n = AppLocalizations.of(contextProvider);
            final first = built.errors.first;
            showAppSnackBar(
              contextProvider,
              message: l10n == null
                  ? first.toString()
                  : _attachmentErrorText(l10n, first),
              type: NotificationType.warning,
            );
          }
        }
      }
    }

    // Apply message template to last user message. A native-only turn has an
    // empty text body — wrapping the template around it would inject
    // boilerplate before/after the audio/PDF parts.
    if (lastUserIdx != -1 &&
        (apiMessages[lastUserIdx]['content'] ?? '').toString().isNotEmpty) {
      final userText = (apiMessages[lastUserIdx]['content'] ?? '').toString();
      final templ =
          (assistant?.messageTemplate ?? '{{ message }}').trim().isEmpty
          ? '{{ message }}'
          : (assistant!.messageTemplate);
      final templated = PromptTransformer.applyMessageTemplate(
        templ,
        role: 'user',
        message: userText,
        now: DateTime.now(),
      );
      apiMessages[lastUserIdx]['content'] = templated;
    }

    return lastUserImagePaths ?? <String>[];
  }

  /// Placeholder used when the current user turn has no text and no sendable
  /// native attachment. Keeping a non-empty turn prevents provider 400s while
  /// the gate/snackbar already told the user the attachment was not sent.
  String _emptyUserMessagePlaceholder() {
    return AppLocalizations.of(contextProvider)?.attachmentOmittedPlaceholder ??
        '(attachment omitted)';
  }

  /// Localized, human-readable reason for a skipped native attachment.
  String _attachmentErrorText(AppLocalizations l10n, NativeInputError error) {
    final reason = switch (error.code) {
      NativeInputError.tooLarge => l10n.attachmentErrorTooLarge,
      NativeInputError.unavailable => l10n.attachmentErrorUnavailable,
      NativeInputError.unsupportedFormat => l10n.attachmentErrorUnsupportedFormat,
      NativeInputError.unsupportedProvider => l10n.attachmentErrorUnsupportedProvider,
      _ => error.detail,
    };
    return l10n.attachmentSkippedNotice(error.fileName, reason);
  }

  /// Default OCR text wrapper
  String _defaultWrapOcrBlock(String ocrText) {
    final buf = StringBuffer();
    buf.writeln(
      "The image_file_ocr tag contains a description of an image that the user uploaded to you, not the user's prompt.",
    );
    buf.writeln('<image_file_ocr>');
    buf.writeln(ocrText.trim());
    buf.writeln('</image_file_ocr>');
    buf.writeln();
    return buf.toString();
  }

  /// Inject the assistant system prompt into apiMessages.
  ///
  /// The `[File Workspace]` block is appended separately after tool
  /// definitions are assembled, so it lists only the tools actually
  /// advertised in the request.
  void injectSystemPrompt(
    List<Map<String, dynamic>> apiMessages,
    Assistant? assistant,
    String modelId,
  ) {
    String? systemText;
    if ((assistant?.systemPrompt.trim().isNotEmpty ?? false)) {
      final vars = PromptTransformer.buildPlaceholders(
        context: contextProvider,
        assistant: assistant!,
        modelId: modelId,
        modelName: modelId,
        userNickname: contextProvider.read<UserProvider>().name,
      );
      systemText = PromptTransformer.replacePlaceholders(
        assistant.systemPrompt,
        vars,
      );
    }

    if (systemText != null && systemText.trim().isNotEmpty) {
      apiMessages.insert(0, {'role': 'system', 'content': systemText.trim()});
    }
  }

  /// Inject the long-term memory block and the recent-chats reference into
  /// apiMessages.
  ///
  /// Deterministic block assembly (M2-3): the injected text only changes when
  /// a memory changes, never per turn. Tool instructions are only appended
  /// when the target model supports tools (M1-3) — the memory body itself is
  /// still injected as reference data.
  Future<void> injectMemoryAndRecentChats(
    List<Map<String, dynamic>> apiMessages,
    Assistant? assistant, {
    String? currentConversationId,
    SettingsProvider? settings,
    bool supportsTools = false,
  }) async {
    if (assistant?.enableMemory == true) {
      try {
        final mp = contextProvider.read<MemoryProvider>();
        // P0-1: a cold start that goes straight to chat must still inject
        // persisted memories. initialize() is single-flight and cached.
        await mp.initialize();
        SettingsProvider? effectiveSettings = settings;
        if (effectiveSettings == null) {
          try {
            effectiveSettings = contextProvider.read<SettingsProvider>();
          } catch (_) {}
        }
        final block = MemoryBlockBuilder.build(
          entries: mp.visibleFor(assistant!.id),
          maxItemsPerType: effectiveSettings?.memoryInjectionMaxItems ??
              MemoryBlockBuilder.defaultMaxItemsPerType,
          fullInjectionTypes:
              effectiveSettings?.memoryFullInjectionTypes ??
              const <MemoryType>{},
          // Fail-closed: callers must opt in explicitly; a forgotten argument
          // must never advertise tools to a non-tool model.
          includeToolInstructions: supportsTools,
        );
        if (block.isNotEmpty) {
          appendToSystemMessage(apiMessages, block);
        }
      } catch (e, st) {
        FlutterLogger.log(
          'Memory injection failed: $e\n$st',
          tag: 'memory-injection',
        );
      }
    }
    if (assistant?.enableRecentChatsReference == true) {
      try {
        final chats = chatService.getAllConversations();
        final relevantChats = chats
            .where(
              (c) =>
                  c.assistantId == assistant!.id &&
                  c.id != currentConversationId,
            )
            .where((c) => c.title.trim().isNotEmpty)
            .take(10)
            .toList();
        if (relevantChats.isNotEmpty) {
          final sb = StringBuffer();
          sb.writeln('<recent_chats>');
          sb.writeln('这是用户最近的一些对话标题和摘要，你可以参考这些内容了解用户偏好和关注点');
          for (final c in relevantChats) {
            sb.writeln('<conversation>');
            // Format: timestamp: title || summary
            final timestamp = c.updatedAt.toIso8601String().substring(0, 10);
            final title = c.title.trim();
            final summary = (c.summary ?? '').trim();
            if (summary.isNotEmpty) {
              sb.writeln('  $timestamp: $title || $summary');
            } else {
              sb.writeln('  $timestamp: $title');
            }
            sb.writeln('</conversation>');
          }
          sb.writeln('</recent_chats>');
          appendToSystemMessage(apiMessages, sb.toString());
        }
      } catch (e, st) {
        FlutterLogger.log(
          'Recent chats injection failed: $e\n$st',
          tag: 'memory-injection',
        );
      }
    }
  }

  /// Inject search tool usage prompt into apiMessages.
  void injectSearchPrompt(
    List<Map<String, dynamic>> apiMessages,
    SettingsProvider settings,
    bool hasBuiltInSearch,
  ) {
    if (settings.searchEnabled && !hasBuiltInSearch) {
      final prompt = SearchToolService.getSystemPrompt();
      appendToSystemMessage(apiMessages, prompt);
    }
  }

  /// Inject instruction injection prompts into apiMessages.
  Future<void> injectInstructionPrompts(
    List<Map<String, dynamic>> apiMessages,
    String? assistantId,
  ) async {
    try {
      List<InstructionInjection> actives = const <InstructionInjection>[];
      try {
        final ip = contextProvider.read<InstructionInjectionProvider>();
        actives = ip.activesFor(assistantId);
        if (actives.isEmpty) {
          actives = await InstructionInjectionStore.getActives(
            assistantId: assistantId,
          );
        }
      } catch (_) {
        actives = await InstructionInjectionStore.getActives(
          assistantId: assistantId,
        );
      }
      final prompts = actives
          .map((e) => e.prompt.trim())
          .where((p) => p.isNotEmpty)
          .toList(growable: false);
      if (prompts.isNotEmpty) {
        final lp = prompts.join('\n\n');
        appendToSystemMessage(apiMessages, lp);
      }
    } catch (_) {}
  }

  /// Helper to append content to the system message (or create one if missing).
  void appendToSystemMessage(
    List<Map<String, dynamic>> apiMessages,
    String content,
  ) {
    if (apiMessages.isNotEmpty && apiMessages.first['role'] == 'system') {
      final existing = (apiMessages[0]['content'] ?? '') as String;
      apiMessages[0]['content'] = '$existing\n\n$content';
    } else {
      apiMessages.insert(0, {'role': 'system', 'content': content});
    }
  }

  /// Apply context message limit based on assistant settings.
  ///
  /// 2026-10 dormancy: the 專案設定 entry that toggled
  /// `limitContextMessages` was removed and `Assistant.fromJson` now resets
  /// it to false on load, so this count-based cut is unreachable from the
  /// UI. Kept as a dormant, pairing-safe contract for directly-constructed
  /// assistants (and the tests that pin the cut semantics).
  ///
  /// The P1-2 `<conversation_summary>` message (if present right after the
  /// system area) is exempt: dropping the summary while keeping the newer
  /// live messages would strand the compaction marker's memory.
  ///
  /// The count-based cut is pairing-safe (shared counter, §3.14 切點安全):
  /// a kept tail may never START on a `role:'tool'` result whose assistant
  /// `tool_calls` message fell behind the cut — strict OpenAI-compatible
  /// validators reject such orphaned tool messages (HTTP 400 "Messages with
  /// role 'tool' must be a response to a preceding message with
  /// 'tool_calls'"; DeepSeek v4 wire-capture 2026-09-13, replayed tool
  /// history + count-based trim). The cut advances past dangling tool
  /// results, dropping them from the kept count; when only tool results
  /// would remain, the list is left untrimmed (an unsplittable pair beats
  /// an unsendable request).
  void applyContextLimit(
    List<Map<String, dynamic>> apiMessages,
    Assistant? assistant,
  ) {
    if ((assistant?.limitContextMessages ?? false) &&
        (assistant?.contextMessageSize ?? 0) > 0) {
      final int keep = (assistant!.contextMessageSize).clamp(1, 4096);
      int startIdx = 0;
      if (apiMessages.isNotEmpty && apiMessages.first['role'] == 'system') {
        startIdx = 1;
      }
      if (startIdx < apiMessages.length &&
          (apiMessages[startIdx]['content'] ?? '').toString().startsWith(
            summaryContentPrefix,
          )) {
        startIdx++;
      }
      final tail = apiMessages.sublist(startIdx);
      if (tail.length > keep) {
        var cut = tail.length - keep;
        // Pairing safety: advance past dangling tool results whose call
        // would stay behind the cut.
        cut = firstLegalTailStart(tail, cut);
        if (cut >= tail.length) return;
        final trimmed = tail.sublist(cut);
        apiMessages
          ..removeRange(startIdx, apiMessages.length)
          ..addAll(trimmed);
      }
    }
  }

  /// Convert local Markdown image links to inline base64 for model context.
  ///
  /// Tool results are skipped: they are model-facing text (web_fetch pages,
  /// search results) that often contains protocol-relative image URLs
  /// (`//host/...`). Treating those as local paths made Windows resolve them
  /// as UNC shares and blocked the UI isolate for 10-25s per host. They are
  /// also the largest messages, so skipping them keeps assembly cheap.
  Future<void> inlineLocalImages(List<Map<String, dynamic>> apiMessages) async {
    for (final message in apiMessages) {
      if (message['role'] == 'tool') continue;
      final content = message['content'];
      // Only string content can contain Markdown image links; leave structured
      // multimodal content untouched.
      if (content is! String || content.isEmpty) continue;
      // Skip the P1-2 summary: its text quotes old history and must never
      // have stale image references re-inlined as base64 blobs.
      if (content.startsWith(summaryContentPrefix)) continue;
      message['content'] =
          await MarkdownMediaSanitizer.inlineLocalImagesToBase64(content);
    }
  }

  /// Check if Gemini built-in search is enabled for the given provider/model.
  bool hasGeminiBuiltInTools(
    SettingsProvider settings,
    String providerKey,
    String modelId,
  ) {
    try {
      final cfg = settings.getProviderConfig(providerKey);
      if (cfg.providerType != ProviderKind.google) return false;
      final rawOv = cfg.modelOverrides[modelId];
      final ov = rawOv is Map ? rawOv : null;
      final builtIns = BuiltInToolNames.parseAndNormalize(ov?['builtInTools']);
      // Gemini drops function declarations whenever any provider-side tool is
      // active, not only google_search. url_context / code_execution must
      // suppress the client search and fetch tools too.
      return builtIns.contains(BuiltInToolNames.search) ||
          builtIns.contains(BuiltInToolNames.urlContext) ||
          builtIns.contains(BuiltInToolNames.codeExecution) ||
          builtIns.contains(BuiltInToolNames.youtube);
    } catch (_) {
      return false;
    }
  }
}
