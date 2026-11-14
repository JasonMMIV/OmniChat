// Display-only presentation for tool calls: icon + human-readable name.
//
// Single source of truth for every surface that names a tool: chat tool rows,
// the tool detail dialog header, exported chat images, approval cards, and the
// workspace tools switchboard. Titles are deliberately name-only (no path,
// query, or command suffix) so a long task reads as a clean list of actions;
// the arguments are still one tap away in the tool detail dialog.
//
// Built-in tools get a localized name. External MCP tools keep their
// server-provided id verbatim — prettifying `browser_take_screenshot` into
// pseudo-English would hide the id users need for the MCP server config.
//
// Adding a built-in tool? Add it here and to the four ARB files.
// `test/tool_presentation_test.dart` fails when a `file_*` definition has no
// display name, so a new tool cannot silently fall back to the raw id.
library;

import 'package:flutter/widgets.dart';

import '../../../core/services/web/web_fetch_tool.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';

/// Icon for a tool call. Unknown (external MCP) tools keep the wrench.
IconData toolIcon(String rawName) {
  final name = WebFetchTool.canonicalToolName(rawName);
  switch (name) {
    // Workspace file tools.
    case 'file_read':
      return Lucide.FileText;
    case 'file_write':
      return Lucide.SquarePen;
    case 'file_append':
      return Lucide.Plus;
    case 'file_edit':
      return Lucide.Pencil;
    case 'file_patch':
      return Lucide.Code;
    case 'file_delete':
      return Lucide.Trash2;
    case 'file_list':
      return Lucide.FolderOpen;
    case 'file_mkdir':
      return Lucide.FolderPlus;
    case 'file_info':
      return Lucide.BadgeInfo;
    case 'file_move':
      return Lucide.ArrowRight;
    case 'file_copy':
      return Lucide.Copy;
    case 'file_search':
      return Lucide.Search;
    case 'file_grep':
      return Lucide.ScanSearch;
    case 'file_view_image':
      return Lucide.Image;
    case 'file_extract_text':
      return Lucide.BookOpenText;
    case 'file_extract_zip':
      return Lucide.Package;
    case 'file_create_pdf':
      return Lucide.Printer;

    // System tools.
    case 'get_console_errors':
      return Lucide.Monitor;
    case 'shell_run':
    case 'shell_exec':
      return Lucide.Terminal;

    // Conversation tools.
    case 'create_memory':
    case 'memory_update':
    case 'memory_edit':
    case 'edit_memory':
      return Lucide.bookHeart;
    case 'memory_read':
      return Lucide.Library;
    case 'memory_delete':
    case 'delete_memory':
      return Lucide.bookDashed;
    case 'search_web':
      return Lucide.Earth;
    case 'web_fetch':
      return Lucide.FileText;
    case 'builtin_search':
      return Lucide.Search;
    case 'spawn_subagent':
    case 'delegate_subagent':
      return Lucide.Bot;
    case 'skill':
      return Lucide.WandSparkles;
    case 'illustrate':
    case 'image_search':
      return Lucide.Image;
    default:
      return Lucide.Wrench;
  }
}

/// Localized tool name used by every UI surface that names a tool.
///
/// Unknown tools (external MCP servers) return the raw id, which is the honest
/// fallback — the id is what the server config and the model both use.
String toolDisplayName(AppLocalizations l10n, String rawName) {
  final name = WebFetchTool.canonicalToolName(rawName);
  switch (name) {
    case 'file_read':
      return l10n.toolNameFileRead;
    case 'file_write':
      return l10n.toolNameFileWrite;
    case 'file_append':
      return l10n.toolNameFileAppend;
    case 'file_edit':
      return l10n.toolNameFileEdit;
    case 'file_patch':
      return l10n.toolNameFilePatch;
    case 'file_delete':
      return l10n.toolNameFileDelete;
    case 'file_list':
      return l10n.toolNameFileList;
    case 'file_mkdir':
      return l10n.toolNameFileMkdir;
    case 'file_info':
      return l10n.toolNameFileInfo;
    case 'file_move':
      return l10n.toolNameFileMove;
    case 'file_copy':
      return l10n.toolNameFileCopy;
    case 'file_search':
      return l10n.toolNameFileSearch;
    case 'file_grep':
      return l10n.toolNameFileGrep;
    case 'file_view_image':
      return l10n.toolNameFileViewImage;
    case 'file_extract_text':
      return l10n.toolNameFileExtractText;
    case 'file_extract_zip':
      return l10n.toolNameFileExtractZip;
    case 'file_create_pdf':
      return l10n.toolNameFileCreatePdf;
    case 'get_console_errors':
      return l10n.toolNameConsoleErrors;
    case 'shell_run':
      return l10n.toolNameShellRun;
    case 'shell_exec':
      return l10n.toolNameShellExec;
    case 'create_memory':
    case 'memory_update':
      return l10n.chatMessageWidgetMemoryUpdate;
    case 'memory_read':
      return l10n.chatMessageWidgetMemoryRead;
    case 'memory_edit':
    case 'edit_memory':
      return l10n.chatMessageWidgetMemoryEdit;
    case 'memory_delete':
    case 'delete_memory':
      return l10n.chatMessageWidgetMemoryDelete;
    case 'search_web':
      return l10n.toolNameSearchWeb;
    case 'web_fetch':
      return l10n.toolNameWebFetch;
    case 'builtin_search':
      return l10n.toolNameBuiltinSearch;
    case 'delegate_subagent':
      return l10n.toolNameDelegateSubagent;
    case 'skill':
      return l10n.toolNameSkill;
    case 'illustrate':
    case 'image_search':
      return l10n.toolNameIllustrate;
    default:
      return rawName;
  }
}

/// One-line behavior summary for the workspace tools switchboard. Only tools
/// whose name does not explain them get a dedicated line; the rest use their
/// group summary. Explicitly *not* a translation of the model-facing schema
/// description — those are a contract for the LLM and may change independently.
String? toolShortDescription(AppLocalizations l10n, String rawName) {
  switch (WebFetchTool.canonicalToolName(rawName)) {
    case 'file_patch':
      return l10n.toolDescFilePatch;
    case 'file_extract_text':
      return l10n.toolDescFileExtractText;
    case 'file_extract_zip':
      return l10n.toolDescFileExtractZip;
    case 'file_create_pdf':
      return l10n.toolDescFileCreatePdf;
    case 'get_console_errors':
      return l10n.toolDescConsoleErrors;
    default:
      return null;
  }
}

/// Switchboard grouping. Order here is the display order on the tools page.
enum WorkspaceToolGroup {
  read,
  write,
  search,
  organize,
  documents,
  system,
  other,
}

WorkspaceToolGroup workspaceToolGroup(String rawName) {
  switch (WebFetchTool.canonicalToolName(rawName)) {
    case 'file_read':
    case 'file_list':
    case 'file_info':
    case 'file_view_image':
      return WorkspaceToolGroup.read;
    case 'file_write':
    case 'file_append':
    case 'file_edit':
    case 'file_patch':
    case 'file_mkdir':
      return WorkspaceToolGroup.write;
    case 'file_search':
    case 'file_grep':
      return WorkspaceToolGroup.search;
    case 'file_delete':
    case 'file_move':
    case 'file_copy':
      return WorkspaceToolGroup.organize;
    case 'file_extract_text':
    case 'file_extract_zip':
    case 'file_create_pdf':
      return WorkspaceToolGroup.documents;
    case 'get_console_errors':
    case 'shell_run':
    case 'shell_exec':
      return WorkspaceToolGroup.system;
    default:
      return WorkspaceToolGroup.other;
  }
}

String workspaceToolGroupLabel(
  AppLocalizations l10n,
  WorkspaceToolGroup group,
) {
  switch (group) {
    case WorkspaceToolGroup.read:
      return l10n.toolGroupRead;
    case WorkspaceToolGroup.write:
      return l10n.toolGroupWrite;
    case WorkspaceToolGroup.search:
      return l10n.toolGroupSearch;
    case WorkspaceToolGroup.organize:
      return l10n.toolGroupOrganize;
    case WorkspaceToolGroup.documents:
      return l10n.toolGroupDocuments;
    case WorkspaceToolGroup.system:
      return l10n.toolGroupSystem;
    case WorkspaceToolGroup.other:
      return l10n.toolGroupOther;
  }
}

String workspaceToolGroupDescription(
  AppLocalizations l10n,
  WorkspaceToolGroup group,
) {
  switch (group) {
    case WorkspaceToolGroup.read:
      return l10n.toolGroupReadDescription;
    case WorkspaceToolGroup.write:
      return l10n.toolGroupWriteDescription;
    case WorkspaceToolGroup.search:
      return l10n.toolGroupSearchDescription;
    case WorkspaceToolGroup.organize:
      return l10n.toolGroupOrganizeDescription;
    case WorkspaceToolGroup.documents:
      return l10n.toolGroupDocumentsDescription;
    case WorkspaceToolGroup.system:
      return l10n.toolGroupSystemDescription;
    case WorkspaceToolGroup.other:
      return l10n.toolGroupOtherDescription;
  }
}
