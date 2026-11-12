// Trusted tool-result image paths (file_view_image Stage 2).
//
// A `[image:<path>]` marker inside tool output is untrusted text: a malicious
// workspace file or shell output could point at an arbitrary local file. The
// path allow-list normally covers workspace / session-outputs / MCP cache, but
// `file_view_image` can also read a path the user explicitly approved outside
// the workspace.
//
// The tool handler records such paths here after the approval has been
// enforced. Replay/restart paths are recovered from the persisted
// `imagePath` tool-event extra instead, so this ledger is deliberately
// process-local and bounded.

import 'dart:collection';
import 'dart:io';

abstract final class ToolImageAccessLedger {
  ToolImageAccessLedger._();

  static const int maxEntries = 256;

  static final LinkedHashSet<String> _paths = LinkedHashSet<String>();

  /// Records a path that a tool already validated (and the user approved, when
  /// outside the workspace). Only tool-handler code should call this.
  static void allow(String path) {
    final normalized = _normalize(path);
    if (normalized.isEmpty) return;
    _paths.remove(normalized);
    _paths.add(normalized);
    while (_paths.length > maxEntries) {
      _paths.remove(_paths.first);
    }
  }

  static bool contains(String path) => _paths.contains(_normalize(path));

  static Set<String> snapshot() => Set<String>.unmodifiable(_paths);

  /// Test seam. Production code never needs to clear the ledger.
  static void clear() => _paths.clear();
  static String _normalize(String value) {
    final normalized = value.trim().replaceAll('\\', '/');
    // Windows paths are case-insensitive; keep the ledger comparison aligned
    // with the planner's canonical-path check.
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }
}
