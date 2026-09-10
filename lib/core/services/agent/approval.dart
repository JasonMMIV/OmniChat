// P1-1 approval engine (IMPORT_PLAN_COWORK.md P1-1; ADR-A5/A8/A9).
//
// Pure Dart: the five-state machine, the approval decision, the policy
// source the engine currently ships (file out-of-workspace → ask; the
// `shell_run` allowlist source arrives with P1-6), and the structured
// tool-result JSON that feeds the model after a denial or an
// approval-required timeout.
//
// 2026-09-10: the MCP policy source (MCP tools → default ask) was REMOVED.
// Real-world testing showed per-call MCP approval is unnecessary (MCP tool
// calls are high-frequency JSON-RPC calls the user opted into by enabling
// the server) and the mechanism was broken in practice (the approve path
// never actually executed the call; persisted "always allow" overrides were
// never read by the policy layer). MCP tools execute directly now.
//
// Semantics (ADR-A5): approval = loop pause, not a blocking wait. A tool
// call classified as `ask` returns the `approval_required` error JSON
// WITHOUT executing; the tool event is persisted with
// `approvalState: pending`; the run breaks; the user's decision resumes
// generation (approve → execute once against the approved path, deny →
// denial JSON as the result).
library;

import 'dart:convert';

/// Tool event `approvalState` values (persisted in `tool_events_v1`).
const String approvalStateAuto = 'auto'; // ran without approval
const String approvalStatePending = 'pending'; // awaiting user decision
const String approvalStateApproved = 'approved'; // approved, executed
const String approvalStateDenied = 'denied'; // denied, error JSON returned
const String approvalStateAnswered = 'answered'; // answered (ask_user mode)

/// Structured content marker for an approval-required tool result.
const String approvalRequiredType = 'approval_required';

/// Structured content marker for a denied tool result.
const String approvalDeniedType = 'approval_denied';

/// How long a Pending card may sit before the model is told approval is
/// required (CLI v4 §三.3; enforced lazily at resume time).
const Duration approvalPendingTimeout = Duration(minutes: 5);

/// The per-call approval decision produced by the policy engine.
enum ApprovalDecision {
  /// Execute immediately, no user interaction.
  allow,

  /// Surface a Pending card; do not execute until the user decides.
  ask,

  /// Refuse outright without a card (user-configured deny / hard floor).
  deny,
}

/// What the policy engine needs to classify one tool call. Populated by the
/// tool handler before execution; every field is optional so the engine
/// degrades gracefully.
class ApprovalContext {
  const ApprovalContext({
    this.isWorkspaceTool = false,
    this.pathInsideWorkspace = true,
    this.resolvedPath,
    this.alwaysAllowedKeys = const <String>{},
    this.strictMode = false,
  });

  /// File/workspace tool (`file_*`).
  final bool isWorkspaceTool;

  /// Whether the call's resolved path stays inside the workspace sandbox
  /// (`true` when not applicable).
  final bool pathInsideWorkspace;

  /// The resolved absolute path shown on the approval card when the call is
  /// out of bounds (ADR-A8: the user approves a concrete absolute path, not
  /// a relative string). The same path is handed to the executor when an
  /// out-of-bounds call is approved.
  final String? resolvedPath;

  /// Persisted "always allow" override keys captured at generation-prep
  /// time (policy snapshot; ADR-A9).
  final Set<String> alwaysAllowedKeys;

  /// strict mode toggle: every `ask` degrades to `deny` (v1.5).
  final bool strictMode;
}

/// Classify one tool call. Order matters:
/// 1. persisted "always allow" override → allow (user's explicit prior
///    consent, same storage as the future shell allowlist);
/// 2. workspace tools inside the sandbox → allow;
/// 3. workspace tools with a path outside the sandbox → ask (ADR-A8;
///    type/size hard floors are enforced later by FileToolService itself
///    and are NOT relaxed by approval);
/// 4. everything else (MCP, search, memory, todo, ask_user, …) → allow.
///    MCP tools are deliberately ungated (2026-09-10: the black-box ask
///    policy source was removed).
ApprovalDecision decideApproval(ApprovalContext ctx) {
  if (ctx.strictMode) {
    // Strict mode degrades every would-be ask to deny (v1.5).
    final ask = _wouldAsk(ctx);
    if (ask) return ApprovalDecision.deny;
  }
  if (_wouldAsk(ctx)) return ApprovalDecision.ask;
  return ApprovalDecision.allow;
}

bool _wouldAsk(ApprovalContext ctx) {
  // 1. Persisted per-path override wins.
  if (ctx.isWorkspaceTool && !ctx.pathInsideWorkspace) {
    final pathKey = _workspaceOutKey(ctx.resolvedPath);
    if (ctx.alwaysAllowedKeys.contains(pathKey)) return false;
    return true;
  }
  return false;
}

/// "Always allow" key for an out-of-workspace absolute path.
String _workspaceOutKey(String? resolvedPath) =>
    'workspace-out:${resolvedPath ?? '*'}';

/// Build the structured tool-result JSON persisted while a decision is
/// pending. The approval card renders from this payload; `requested_at`
/// (epoch ms) drives the lazy timeout check at resume time.
String buildApprovalPendingContent({
  required String toolName,
  String? resolvedPath,
  bool outsideWorkspace = false,
  Map<String, dynamic> arguments = const {},
  DateTime? requestedAt,
  String? previewDiff,
}) {
  return jsonEncode(<String, dynamic>{
    'type': approvalRequiredType,
    'tool': toolName,
    if (resolvedPath != null) 'resolved_path': resolvedPath,
    'outside_workspace': outsideWorkspace,
    'arguments': arguments,
    'requested_at': (requestedAt ?? DateTime.now()).millisecondsSinceEpoch,
    if (previewDiff != null && previewDiff.isNotEmpty)
      'preview_diff': previewDiff,
  });
}

/// Whether a pending approval has exceeded [timeout] since [requestedAtMs]
/// (epoch ms stored on the pending payload). Null/invalid timestamps never
/// time out (legacy events stay resolvable).
bool isApprovalTimedOut(Object? requestedAtMs, {Duration? timeout}) {
  final ms = requestedAtMs is num ? requestedAtMs.toInt() : null;
  if (ms == null || ms <= 0) return false;
  final requested = DateTime.fromMillisecondsSinceEpoch(ms);
  return DateTime.now().difference(requested) >
      (timeout ?? approvalPendingTimeout);
}

/// Build a minimal unified diff from the `file_edit` argument shape
/// (`old_text` → `new_text`). Rendered on the approval card before the call
/// executes (RikkaHub `WorkspaceToolUIs.diffOf` preview mode). Deterministic
/// line-based LCS-free form: header + `-` old lines + `+` new lines —
/// enough for a human to judge the change without a full diff algorithm.
String? buildEditPreviewDiff(Map<String, dynamic> args) {
  final oldText = (args['old_text'] ?? '').toString();
  final newText = (args['new_text'] ?? '').toString();
  if (oldText.isEmpty && newText.isEmpty) return null;
  if (oldText == newText) return null;
  final oldLines = oldText.split('\n');
  final newLines = newText.split('\n');
  final buf = StringBuffer()
    ..writeln('--- a/old')
    ..writeln('+++ b/new');
  for (final l in oldLines) {
    buf.writeln('-$l');
  }
  for (final l in newLines) {
    buf.writeln('+$l');
  }
  return buf.toString().trimRight();
}

/// Build the structured tool-result JSON returned to the model when the user
/// denies the call (ADR-A5: Denied → structured error JSON; the model can
/// adjust course instead of blindly retrying).
String buildApprovalDeniedContent({required String toolName}) {
  return jsonEncode(<String, dynamic>{
    'type': approvalDeniedType,
    'tool': toolName,
    'error': 'approval_denied',
    'message':
        'The user denied this tool call. Do not retry the same call; adjust your approach or ask the user how to proceed.',
    'tool_name': toolName,
  });
}

/// Build the structured tool-result JSON returned when a Pending card timed
/// out without a decision (CLI v4: ask 逾時 → approval-required error; the
/// tool is NOT executed).
String buildApprovalTimeoutContent({required String toolName}) {
  return jsonEncode(<String, dynamic>{
    'type': approvalRequiredType,
    'tool': toolName,
    'error': 'approval_timeout',
    'message':
        'No approval decision was made in time. The tool was not executed. Ask the user again if this step is still needed.',
    'tool_name': toolName,
  });
}

/// Parse a tool-event content string into its approval protocol type.
/// Returns `{type, tool?, ...}` or null for non-approval content.
Map<String, dynamic>? parseApprovalContent(String? content) {
  if (content == null || content.trim().isEmpty) return null;
  try {
    final obj = jsonDecode(content);
    if (obj is! Map) return null;
    final type = (obj['type'] ?? '').toString();
    if (type != approvalRequiredType && type != approvalDeniedType) {
      return null;
    }
    return Map<String, dynamic>.from(obj);
  } catch (_) {
    return null;
  }
}

/// Normalize an approvalState value read from storage.
String normalizeApprovalState(Object? raw) {
  switch (raw) {
    case approvalStatePending:
      return approvalStatePending;
    case approvalStateApproved:
      return approvalStateApproved;
    case approvalStateDenied:
      return approvalStateDenied;
    case approvalStateAnswered:
      return approvalStateAnswered;
    default:
      return approvalStateAuto;
  }
}

/// The kind of a persisted "always allow" override key. Only workspace-out
/// paths exist today (the MCP key kinds were removed 2026-09-10); the enum
/// stays for forward compatibility with later policy sources (e.g. the
/// shell allowlist in P1-6).
enum ApprovalOverrideKind { workspaceOut }

/// A decoded "always allow" override key, for the settings UI list.
class ApprovalOverrideKey {
  const ApprovalOverrideKey({
    required this.kind,
    required this.rawKey,
    this.resolvedPath,
  });

  final ApprovalOverrideKind kind;
  final String rawKey;
  final String? resolvedPath;
}

/// Decode a persisted "always allow" override key back into its parts.
/// Unknown shapes return null (forward compatibility: new key kinds added by
/// later policy sources — e.g. shell allowlist — surface as unknown and are
/// skipped by the settings list rather than crashing it).
ApprovalOverrideKey? decodeApprovalOverrideKey(String key) {
  if (key.startsWith('workspace-out:')) {
    return ApprovalOverrideKey(
      kind: ApprovalOverrideKind.workspaceOut,
      rawKey: key,
      resolvedPath: key.substring(14),
    );
  }
  return null;
}
