// P2-5 §2.8 item 8: host path probe.
//
// The Android shell must not be advertised for a workspace that PRoot cannot
// bind. This probe runs on the host side (Dart) before the first command:
// directory exists → can list → can create/delete a probe file → canonical
// path. A `content://` SAF URI is explicitly rejected (PRoot needs a real
// path). FUSE/noexec is NOT a probe failure: data files remain readable and
// writable; only executing files/symlinks from that workspace is unsupported.
library;

import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

class WorkspacePathProbeResult {
  const WorkspacePathProbeResult({
    required this.ok,
    required this.canonicalPath,
    this.reason,
    this.writable = false,
    this.readable = false,
    this.isDirectory = false,
  });

  final bool ok;

  /// Canonical host path (symlinks resolved) when the path exists.
  final String? canonicalPath;

  /// Stable reason code for the UI/model.
  final String? reason;

  final bool writable;
  final bool readable;
  final bool isDirectory;
}

class WorkspacePathProbe {
  WorkspacePathProbe._();

  static final Random _random = Random.secure();

  /// Probe [rawPath] without throwing. Never creates anything when the path
  /// is missing or is a SAF URI.
  static Future<WorkspacePathProbeResult> probe(String rawPath) async {
    final raw = rawPath.trim();
    if (raw.isEmpty) {
      return const WorkspacePathProbeResult(
        ok: false,
        canonicalPath: null,
        reason: 'empty_path',
      );
    }
    if (raw.startsWith('content://')) {
      return const WorkspacePathProbeResult(
        ok: false,
        canonicalPath: null,
        reason: 'content_uri',
      );
    }
    if (raw.contains('\u0000') || !p.isAbsolute(raw)) {
      return const WorkspacePathProbeResult(
        ok: false,
        canonicalPath: null,
        reason: 'not_absolute',
      );
    }

    final directory = Directory(raw);
    if (!await directory.exists()) {
      return const WorkspacePathProbeResult(
        ok: false,
        canonicalPath: null,
        reason: 'not_found',
      );
    }

    String canonical;
    try {
      canonical = await directory.resolveSymbolicLinks();
    } catch (_) {
      return const WorkspacePathProbeResult(
        ok: false,
        canonicalPath: null,
        reason: 'canonical_failed',
      );
    }

    var readable = false;
    try {
      // Stream.isEmpty consumes the listing without requiring a first entry
      // (an empty directory is still a successful proxy for readability).
      await directory.list(followLinks: false).isEmpty;
      readable = true;
    } catch (_) {
      readable = false;
    }
    if (!readable) {
      return WorkspacePathProbeResult(
        ok: false,
        canonicalPath: canonical,
        reason: 'not_readable',
        readable: false,
        isDirectory: true,
      );
    }

    final suffix = _random.nextInt(1 << 32).toRadixString(16);
    final probeFile = File(p.join(canonical, '.omnichat_probe_$suffix'));
    var writable = false;
    try {
      await probeFile.writeAsString('omnichat', flush: true);
      writable = await probeFile.readAsString() == 'omnichat';
      await probeFile.delete();
    } catch (_) {
      writable = false;
      try {
        if (await probeFile.exists()) await probeFile.delete();
      } catch (_) {}
    }
    if (!writable) {
      return WorkspacePathProbeResult(
        ok: false,
        canonicalPath: canonical,
        reason: 'not_writable',
        readable: true,
        writable: false,
        isDirectory: true,
      );
    }

    return WorkspacePathProbeResult(
      ok: true,
      canonicalPath: canonical,
      readable: true,
      writable: true,
      isDirectory: true,
    );
  }
}
