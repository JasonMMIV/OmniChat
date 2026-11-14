import '../../../core/services/dev/dev_preview_tools.dart';
import '../../../core/services/file/file_tool_service.dart';
import '../../../core/services/shell/android/android_shell_service.dart';
import '../../../core/services/shell/shell_run_service.dart';

/// Built-in workspace tool names, derived from the definitions themselves so
/// the `[File Workspace]` prompt can never drift from the real tool set.
final Set<String> _workspaceToolNames = _buildWorkspaceToolNames();

Set<String> _buildWorkspaceToolNames() {
  final names = <String>{};
  for (final def in FileToolService.getToolDefinitions()) {
    final name = _toolDefinitionName(def);
    if (name != null) names.add(name);
  }
  names.add(devConsoleErrorsToolName);
  names.add(ShellRunService.toolName);
  names.add(AndroidShellService.toolName);
  return names;
}

String? _toolDefinitionName(Map<String, dynamic> def) {
  final function = def['function'];
  if (function is! Map) return null;
  final name = (function['name'] ?? '').toString().trim();
  return name.isEmpty ? null : name;
}

/// Builds the `[File Workspace]` block from the tools actually advertised in
/// [toolDefs]. Returns null when the workspace is unavailable or no
/// file/console/shell tool made it into this request.
///
/// The block intentionally describes only tools present in [toolDefs]: a
/// disabled `file_patch` or `file_create_pdf` must not be advertised, while
/// `file_grep`, `file_view_image`, `get_console_errors` and `shell_run` must
/// appear when they are actually offered.
String? buildFileWorkspacePrompt(
  String? workspacePath,
  Iterable<Map<String, dynamic>> toolDefs,
) {
  final path = workspacePath?.trim();
  if (path == null || path.isEmpty) return null;

  final names = <String>[];
  final seen = <String>{};
  for (final def in toolDefs) {
    final name = _toolDefinitionName(def);
    if (name == null || !_workspaceToolNames.contains(name)) continue;
    if (seen.add(name)) names.add(name);
  }
  if (names.isEmpty) return null;

  final enabled = names.toSet();
  final hasFileTools = names.any((name) => name.startsWith('file_'));
  // Keep the prose limits in sync with the authoritative service constants.
  final maxGrepMb = FileToolService.maxGrepFileBytes ~/ (1024 * 1024);
  final maxImageMb = FileToolService.maxViewImageBytes ~/ (1024 * 1024);
  final paragraphs = <String>[
    '[File Workspace]',
    'The active workspace is: $path',
    if (hasFileTools)
      'Use relative paths for all file operations. Available tools: '
          '${names.join(', ')}.'
    else
      'Available tools: ${names.join(', ')}.',
  ];

  if (enabled.contains('file_read')) {
    paragraphs.add(
      'file_read reads UTF-8 text with byte-based offset and limit '
      'parameters; use the returned next_offset to continue. It is not for '
      'PDF/DOCX/PPTX/XLSX binary files.',
    );
  }
  if (enabled.contains('file_edit')) {
    paragraphs.add(
      'file_edit matches exact text first; if the exact text is missing, it '
      'falls back to indentation-tolerant line matching. By default old_text '
      'must match exactly once.',
    );
  }
  if (enabled.contains('file_patch')) {
    paragraphs.add(
      'file_patch applies a single-file unified diff containing one or more '
      'hunks.',
    );
  }
  if (enabled.contains('file_grep')) {
    paragraphs.add(
      'file_grep searches file contents with a regular expression and returns '
      'path:line: text; binary files, files over $maxGrepMb MB, symlinks, '
      'and dot directories are skipped.',
    );
  }
  if (enabled.contains('file_view_image')) {
    paragraphs.add(
      'file_view_image previews PNG, JPEG, GIF, WebP, or BMP images up to '
      '$maxImageMb MB; the preview appears in the chat and the tool result '
      'includes the image path.',
    );
  }
  if (enabled.contains('get_console_errors')) {
    paragraphs.add(
      'get_console_errors reads console errors and warnings captured by the '
      'live site preview; the preview panel must be open.',
    );
  }
  if (enabled.contains('shell_run')) {
    paragraphs.add(
      'shell_run runs one desktop shell command in the workspace (builds, '
      'tests, git, package managers). Commands start in the workspace; this '
      'is not a security sandbox.',
    );
  }
  if (enabled.contains('shell_exec')) {
    paragraphs.add(
      'shell_exec runs one foreground command inside the Android PRoot '
      'sandbox (Ubuntu base). Its current directory is the guest path '
      '/workspace, which maps to the active workspace above; file tools still '
      'use workspace-relative host paths. External shared-storage workspaces '
      'do not support executable bits or symlinks. This is not a security '
      'sandbox, and background jobs are not supported.',
    );
  }
  if (enabled.contains('file_extract_text')) {
    paragraphs.add(
      'file_extract_text extracts readable text from PDF, DOCX, PPTX, and '
      'XLSX files inside the workspace (workspace-relative path only; other '
      'formats are not supported). It returns text without OCR, so scanned '
      'PDFs may yield no text. Tables in DOCX, PPTX, and XLSX are returned as '
      'Markdown tables (| col1 | col2 |) with a header separator; XLSX '
      'worksheets are marked with --- Sheet N (name) ---. Dates appear as '
      'raw values and formulas as cached results. Large documents must be '
      'read incrementally: use the returned next_offset with the offset '
      'parameter to continue.',
    );
  }
  if (enabled.contains('file_extract_zip')) {
    paragraphs.add(
      'file_extract_zip extracts a .zip archive into the workspace; the '
      'destination defaults to a folder named after the archive. Archive '
      'entry paths are validated against the workspace boundary; total '
      'decompressed size and file count are capped.',
    );
  }
  if (enabled.contains('file_create_pdf')) {
    paragraphs.add(
      'file_create_pdf writes a .pdf file from Markdown text (headings, '
      'paragraphs, bold, italic, lists, tables, code blocks, page numbers). '
      'Prefer it over writing the same content as plain text when the user '
      'wants a formatted PDF report.',
    );
  }

  return paragraphs.join('\n\n');
}

/// P0-3: brief injected into a helper's system prompt.
///
/// The helper cannot see the parent conversation, so it receives the same
/// workspace coordinates the parent got (path + the tools it ACTUALLY has),
/// the already-rendered workspace file map, and the parent assistant's standing
/// instructions. Memory blocks are deliberately excluded (A4).
///
/// Fail-open by contract: the caller may wrap this in try/catch and spawn
/// without a brief. Total length is capped (assistant instructions are clipped
/// first, then the file map, then the whole brief).
String buildSubagentBrief({
  String? workspacePath,
  required Iterable<Map<String, dynamic>> childTools,
  String? projectInstructions,
  String? workspaceFileMap,
  int maxChars = 14000,
}) {
  final tools = childTools.toList(growable: false);
  final workspace = buildFileWorkspacePrompt(workspacePath, tools);

  // The file map is only useful when the helper can actually list files —
  // the same gating the parent assembly uses (§P0-3 item 3).
  final advertisesFileList = tools.any((def) {
    final name = _toolDefinitionName(def);
    return name == 'file_list';
  });
  var map = (workspaceFileMap ?? '').trim();
  if (!advertisesFileList) map = '';

  var instructions = (projectInstructions ?? '').trim();
  if (instructions.length > 6000) {
    instructions = instructions.substring(0, 6000);
  }
  if (instructions.isNotEmpty) {
    instructions =
        '$instructions\n\n'
        'If any instruction above refers to tools you were not given, ignore '
        'that part: your own tool list wins.';
  }

  var truncated = false;

  String render() {
    final blocks = <String>[
      if (workspace != null && workspace.isNotEmpty) workspace,
      if (map.isNotEmpty) '[Workspace file map]\n$map',
      if (instructions.isNotEmpty)
        '[Parent assistant standing instructions]\n$instructions',
    ];
    return blocks.join('\n\n');
  }

  var text = render();
  // Shrink the most expendable block first: assistant instructions, then the
  // file map (the helper can always call file_list).
  if (text.length > maxChars && instructions.isNotEmpty) {
    final overflow = text.length - maxChars;
    final keep = instructions.length - overflow - 1;
    instructions = keep > 0 ? instructions.substring(0, keep) : '';
    truncated = true;
    text = render();
  }
  if (text.length > maxChars && map.isNotEmpty) {
    final overflow = text.length - maxChars;
    final keep = map.length - overflow - 1;
    map = keep > 0 ? map.substring(0, keep) : '';
    truncated = true;
    text = render();
  }
  if (text.length > maxChars) {
    text = text.substring(0, maxChars);
    truncated = true;
  }
  if (truncated) text = '$text\n\n[... brief truncated ...]';
  return text.trim();
}
