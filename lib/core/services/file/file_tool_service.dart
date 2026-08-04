import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import '../../../utils/app_directories.dart';
import '../chat/document_text_extractor.dart';

class FileToolResult {
  const FileToolResult({
    required this.text,
    this.createdOrModifiedFilePath,
    this.fileName,
    this.fileSizeBytes,
  });

  final String text;
  final String? createdOrModifiedFilePath;
  final String? fileName;
  final int? fileSizeBytes;
}

class FileToolSecurityException implements Exception {
  const FileToolSecurityException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Built-in file tools. Every path supplied by an LLM is resolved below the
/// selected workspace before any filesystem operation is performed.
class FileToolService {
  FileToolService._();

  /// Default and hard maximum sizes for one file_read response.
  ///
  /// The API layer also caps tool results by character count, but the file
  /// service must bound the data held by the UI and Hive before that happens.
  // Keep the complete result below ChatApiService's 32K-character tool-result
  // budget even for ASCII-heavy source files. The extra room covers metadata.
  static const int defaultReadBytes = 16 * 1024;
  static const int maxReadBytes = 24 * 1024;
  static const int maxWriteBytes = 512 * 1024;
  static const int maxListedEntries = 1000;
  static const int maxSearchResults = 1000;
  static const int maxSearchEntries = 10000;

  /// Default and hard maximum sizes for one file_extract_text response.
  static const int defaultExtractResultBytes = 16 * 1024;
  static const int maxExtractResultBytes = 24 * 1024;

  /// Maximum source file size accepted by the text extractors.
  static const int maxExtractInputBytes = 16 * 1024 * 1024;

  /// Maximum number of UTF-8 bytes the extractor may accumulate per call.
  static const int maxExtractedTextBytes = 256 * 1024;

  static const Set<String> _blockedExtensions = <String>{
    '.apk',
    '.bat',
    '.cmd',
    '.dll',
    '.exe',
    '.ps1',
    '.sh',
    '.so',
    '.vbs',
  };

  static List<Map<String, dynamic>> getToolDefinitions() {
    Map<String, dynamic> definition(
      String name,
      String description,
      Map<String, dynamic> properties,
      List<String> required,
    ) {
      return {
        'type': 'function',
        'function': {
          'name': name,
          'description': description,
          'parameters': {
            'type': 'object',
            'properties': properties,
            if (required.isNotEmpty) 'required': required,
          },
        },
      };
    }

    const pathProperty = {
      'type': 'string',
      'description': 'Relative path inside the current workspace.',
    };
    const sourceProperty = {
      'type': 'string',
      'description': 'Source relative path inside the current workspace.',
    };
    const destinationProperty = {
      'type': 'string',
      'description': 'Destination relative path inside the current workspace.',
    };

    return <Map<String, dynamic>>[
      definition(
        'file_read',
        'Read a byte range of UTF-8 text from a workspace file. Use the returned next_offset to continue reading large files.',
        {
          'path': pathProperty,
          'offset': {
            'type': 'integer',
            'description':
                'Optional zero-based byte offset. Defaults to 0; use next_offset from the previous result for the next segment.',
          },
          'limit': {
            'type': 'integer',
            'description':
                'Optional number of bytes to read. Defaults to 16384 and is capped at 24576.',
          },
        },
        ['path'],
      ),
      definition(
        'file_write',
        'Create or overwrite a UTF-8 text file in the workspace.',
        {
          'path': pathProperty,
          'content': {
            'type': 'string',
            'description': 'Text content to write.',
          },
        },
        ['path', 'content'],
      ),
      definition(
        'file_append',
        'Append UTF-8 text to an existing workspace file.',
        {
          'path': pathProperty,
          'content': {
            'type': 'string',
            'description': 'Text content to append.',
          },
        },
        ['path', 'content'],
      ),
      definition(
        'file_edit',
        'Replace exact UTF-8 text in one existing workspace file. By default the old text must match exactly once.',
        {
          'path': pathProperty,
          'old_text': {
            'type': 'string',
            'description':
                'Exact text to find. This is not a regular expression.',
          },
          'new_text': {
            'type': 'string',
            'description':
                'Replacement text; an empty string deletes the match.',
          },
          'replace_all': {
            'type': 'boolean',
            'description':
                'Optional. Set true only when every exact occurrence should be replaced.',
          },
        },
        ['path', 'old_text', 'new_text'],
      ),
      definition(
        'file_patch',
        'Apply a single-file unified diff to an existing UTF-8 workspace file. The path argument is authoritative.',
        {
          'path': pathProperty,
          'patch': {
            'type': 'string',
            'description':
                'Unified diff containing one or more hunks for this file. Do not include patches for other files.',
          },
        },
        ['path', 'patch'],
      ),
      definition(
        'file_delete',
        'Delete a file or an empty directory in the workspace.',
        {'path': pathProperty},
        ['path'],
      ),
      definition(
        'file_list',
        'List files and directories in a workspace directory.',
        {
          'path': {
            ...pathProperty,
            'description':
                'Optional directory path. Defaults to the workspace root.',
          },
        },
        const [],
      ),
      definition(
        'file_mkdir',
        'Create a directory and any missing parents in the workspace.',
        {'path': pathProperty},
        ['path'],
      ),
      definition(
        'file_info',
        'Return size, modified time, and type for a workspace entry.',
        {'path': pathProperty},
        ['path'],
      ),
      definition(
        'file_move',
        'Move or rename a file or directory inside the workspace.',
        {'source': sourceProperty, 'destination': destinationProperty},
        ['source', 'destination'],
      ),
      definition(
        'file_copy',
        'Copy a file inside the workspace.',
        {'source': sourceProperty, 'destination': destinationProperty},
        ['source', 'destination'],
      ),
      definition(
        'file_search',
        'Search workspace files by substring or wildcard pattern.',
        {
          'pattern': {
            'type': 'string',
            'description': 'Substring or wildcard such as *.py.',
          },
          'path': {
            ...pathProperty,
            'description': 'Optional directory path from which to search.',
          },
        },
        ['pattern'],
      ),
      definition(
        'file_extract_text',
        'Extract text from a PDF, DOCX, or PPTX file inside the current workspace. Use relative paths only. This tool returns text only and does not perform OCR or preserve document layout.',
        {
          'path': pathProperty,
          'format': {
            'type': 'string',
            'enum': ['auto', 'pdf', 'docx', 'pptx'],
            'description':
                'Optional format override. Defaults to auto-detection from the file extension and file signature.',
          },
          'offset': {
            'type': 'integer',
            'description':
                'Optional zero-based byte offset in the extracted text. Defaults to 0; use next_offset from the previous result to continue.',
          },
          'limit': {
            'type': 'integer',
            'description':
                'Optional number of UTF-8 bytes to return from the extracted text. Defaults to 16384 and is capped at 24576.',
          },
        },
        ['path'],
      ),
    ];
  }

  static Future<FileToolResult> execute(
    String toolName,
    Map<String, dynamic> args,
    String? workspacePath,
  ) async {
    try {
      final workspace = await _prepareWorkspace(workspacePath);
      switch (toolName) {
        case 'file_read':
          return await _read(args, workspace);
        case 'file_write':
          return await _write(args, workspace, append: false);
        case 'file_append':
          return await _write(args, workspace, append: true);
        case 'file_edit':
          return await _edit(args, workspace);
        case 'file_patch':
          return await _patch(args, workspace);
        case 'file_delete':
          return await _delete(args, workspace);
        case 'file_list':
          return await _list(args, workspace);
        case 'file_mkdir':
          return await _mkdir(args, workspace);
        case 'file_info':
          return await _info(args, workspace);
        case 'file_move':
          return await _moveOrCopy(args, workspace, move: true);
        case 'file_copy':
          return await _moveOrCopy(args, workspace, move: false);
        case 'file_search':
          return await _search(args, workspace);
        case 'file_extract_text':
          return await _extractText(args, workspace);
        default:
          return FileToolResult(text: 'Error: Unknown file tool "$toolName".');
      }
    } on FileToolSecurityException catch (e) {
      return FileToolResult(text: 'Error: ${e.message}');
    } on FileSystemException catch (e) {
      return FileToolResult(text: 'Error: ${e.message}');
    } catch (e) {
      return FileToolResult(text: 'Error: $e');
    }
  }

  /// Public for unit tests and the workspace browser. It rejects absolute
  /// LLM paths and resolves the nearest existing parent for new destinations.
  static String resolveSafePath(String relativePath, String workspaceRoot) {
    if (relativePath.contains('\u0000')) {
      throw const FileToolSecurityException(
        'Path contains an invalid character.',
      );
    }

    final raw = relativePath.trim();
    if (p.isAbsolute(raw)) {
      throw const FileToolSecurityException(
        'Path must be relative to the workspace.',
      );
    }

    if (FileSystemEntity.typeSync(workspaceRoot, followLinks: true) !=
        FileSystemEntityType.directory) {
      throw const FileToolSecurityException(
        'Workspace root must be a directory.',
      );
    }
    final root = _resolveExistingEntity(workspaceRoot);
    final candidate = p.normalize(p.join(root, raw.isEmpty ? '.' : raw));
    final resolved = _resolveExistingOrParent(candidate);
    if (!_isWithin(resolved, root)) {
      throw const FileToolSecurityException('Path out of workspace boundary.');
    }
    return resolved;
  }

  static Future<String> _prepareWorkspace(String? workspacePath) async {
    final raw = workspacePath?.trim();
    final directory = (raw == null || raw.isEmpty)
        ? await AppDirectories.getFileSandboxDirectory()
        : Directory(raw);
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    if (!await directory.exists()) {
      throw FileSystemException('Workspace does not exist.', directory.path);
    }
    if (FileSystemEntity.typeSync(directory.path, followLinks: true) !=
        FileSystemEntityType.directory) {
      throw FileSystemException(
        'Workspace path is not a directory.',
        directory.path,
      );
    }
    return _resolveExistingEntity(directory.path);
  }

  static String _resolveExistingEntity(String value) {
    final type = FileSystemEntity.typeSync(value, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      throw FileSystemException('Workspace path does not exist.', value);
    }
    try {
      if (type == FileSystemEntityType.directory) {
        return Directory(value).resolveSymbolicLinksSync();
      }
      return File(value).resolveSymbolicLinksSync();
    } catch (_) {
      throw FileSystemException('Unable to resolve filesystem path.', value);
    }
  }

  static String _resolveExistingOrParent(String candidate) {
    final missing = <String>[];
    var existing = candidate;
    while (FileSystemEntity.typeSync(existing, followLinks: false) ==
        FileSystemEntityType.notFound) {
      final parent = p.dirname(existing);
      if (parent == existing) {
        throw FileSystemException('Unable to resolve path.', candidate);
      }
      missing.add(p.basename(existing));
      existing = parent;
    }

    var resolved = _resolveExistingEntity(existing);
    for (final part in missing.reversed) {
      resolved = p.join(resolved, part);
    }
    return p.normalize(resolved);
  }

  static bool _isWithin(String candidate, String root) {
    String comparable(String value) {
      final normalized = p.normalize(value).replaceAll('\\', '/');
      return Platform.isWindows ? normalized.toLowerCase() : normalized;
    }

    final child = comparable(candidate);
    final parent = comparable(root).replaceFirst(RegExp(r'[/\\]+$'), '');
    final cleanParent = parent.length > 1 && parent.endsWith('/')
        ? parent.substring(0, parent.length - 1)
        : parent;
    if (cleanParent == '/') return child.startsWith('/');
    return child == cleanParent || child.startsWith('$cleanParent/');
  }

  static void _rejectBlockedExtension(String path) {
    if (_blockedExtensions.contains(p.extension(path).toLowerCase())) {
      throw const FileToolSecurityException(
        'This file extension is blocked for safety.',
      );
    }
  }

  static String _requiredString(Map<String, dynamic> args, String key) {
    final value = args[key]?.toString() ?? '';
    if (value.trim().isEmpty)
      throw ArgumentError('Missing required argument: $key');
    return value;
  }

  static String _requiredTextArgument(
    Map<String, dynamic> args,
    String key, {
    bool allowEmpty = true,
  }) {
    final value = args[key];
    if (value is! String || (!allowEmpty && value.isEmpty)) {
      throw ArgumentError(
        'The $key argument is required and must be a string${allowEmpty ? '' : ' with at least one character'}.',
      );
    }
    return value;
  }

  static int _optionalInteger(
    Map<String, dynamic> args,
    String key, {
    required int defaultValue,
  }) {
    final value = args[key];
    if (value == null) return defaultValue;
    if (value is int) return value;
    if (value is num && value.isFinite && value == value.truncate()) {
      return value.toInt();
    }
    throw ArgumentError('The $key argument must be an integer.');
  }

  static Future<FileToolResult> _read(
    Map<String, dynamic> args,
    String workspace,
  ) async {
    final path = resolveSafePath(_requiredString(args, 'path'), workspace);
    final file = File(path);
    if (!await file.exists())
      return FileToolResult(text: 'Error: File not found.');

    final offset = _optionalInteger(args, 'offset', defaultValue: 0);
    final requestedLimit = _optionalInteger(
      args,
      'limit',
      defaultValue: defaultReadBytes,
    );
    if (offset < 0) {
      return const FileToolResult(
        text: 'Error: The offset must be zero or greater.',
      );
    }
    if (requestedLimit <= 0) {
      return const FileToolResult(
        text: 'Error: The limit must be greater than zero.',
      );
    }

    final fileLength = await file.length();
    if (offset > fileLength) {
      return const FileToolResult(
        text: 'Error: The offset is beyond the end of the file.',
      );
    }
    final limit = math.min(requestedLimit, maxReadBytes);
    final capped = requestedLimit > maxReadBytes;
    if (offset == fileLength) {
      final capWarning = capped
          ? '\n[Warning: limit capped at $maxReadBytes bytes.]'
          : '';
      return FileToolResult(
        text:
            '[Read bytes $offset-$offset of $fileLength; next_offset=$offset; has_more=false]\n(empty)$capWarning',
      );
    }

    // Read a few preceding bytes so a segment beginning in the middle of a
    // UTF-8 code point can advance to the next valid boundary.
    final readStart = math.max(0, offset - 3);
    final readLength = math.min(
      fileLength - readStart,
      (offset - readStart) + limit + 4,
    );
    final handle = await file.open();
    late final List<int> bytes;
    try {
      await handle.setPosition(readStart);
      bytes = await handle.read(readLength);
    } finally {
      await handle.close();
    }

    final requestedIndex = offset - readStart;
    final startIndex = _skipUtf8ContinuationBytes(bytes, requestedIndex);
    final endIndex = _takeCompleteUtf8Bytes(
      bytes,
      startIndex,
      math.min(bytes.length, startIndex + limit),
    );
    final actualStart = readStart + startIndex;
    final nextOffset = readStart + endIndex;
    final hasMore = nextOffset < fileLength;
    final text = utf8.decode(
      bytes.sublist(startIndex, endIndex),
      allowMalformed: true,
    );
    final capWarning = capped
        ? '\n[Warning: limit capped at $maxReadBytes bytes.]'
        : '';
    return FileToolResult(
      text:
          '[Read bytes $actualStart-$nextOffset of $fileLength; next_offset=$nextOffset; has_more=$hasMore]\n$text$capWarning',
    );
  }

  static Future<FileToolResult> _extractText(
    Map<String, dynamic> args,
    String workspace,
  ) async {
    final path = resolveSafePath(_requiredString(args, 'path'), workspace);
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      return const FileToolResult(text: 'Error: File not found.');
    }
    if (type != FileSystemEntityType.file) {
      return const FileToolResult(
        text: 'Error: The path is not a regular file.',
      );
    }

    final format = (args['format'] ?? 'auto').toString().toLowerCase();
    if (format != 'auto' &&
        format != 'pdf' &&
        format != 'docx' &&
        format != 'pptx') {
      return const FileToolResult(
        text: 'Error: Unsupported format. Use auto, pdf, docx, or pptx.',
      );
    }

    final offset = _optionalInteger(args, 'offset', defaultValue: 0);
    final requestedLimit = _optionalInteger(
      args,
      'limit',
      defaultValue: defaultExtractResultBytes,
    );
    if (offset < 0) {
      return const FileToolResult(
        text: 'Error: The offset must be zero or greater.',
      );
    }
    if (requestedLimit <= 0) {
      return const FileToolResult(
        text: 'Error: The limit must be greater than zero.',
      );
    }

    final fileLength = await File(path).length();
    if (fileLength > maxExtractInputBytes) {
      return const FileToolResult(
        text:
            'Error: The file exceeds the 16 MB extraction input limit.',
      );
    }

    final DocumentExtractionResult result;
    try {
      result = await DocumentTextExtractor.extractWorkspaceText(
        safePath: path,
        format: format,
        maxInputBytes: maxExtractInputBytes,
        maxOutputBytes: maxExtractedTextBytes,
      );
    } on DocumentExtractionException catch (e) {
      return FileToolResult(text: 'Error: ${e.message}');
    } catch (_) {
      return const FileToolResult(
        text: 'Error: The document could not be parsed.',
      );
    }

    final bytes = utf8.encode(result.text);
    if (bytes.isEmpty) {
      if (result.truncated) {
        return FileToolResult(
          text:
              '[Extracted format=${result.format}; the document contains text, but extraction was capped before any text could be returned. Try reading again with the same path.]',
        );
      }
      final notice =
          result.notice ?? 'The document contains no extractable text.';
      return FileToolResult(
        text:
            '[Extracted format=${result.format}; no extractable text. $notice]',
      );
    }
    if (offset > bytes.length) {
      return const FileToolResult(
        text: 'Error: The offset is beyond the end of the extracted text.',
      );
    }

    final limit = math.min(requestedLimit, maxExtractResultBytes);
    final capped = requestedLimit > maxExtractResultBytes;
    if (offset == bytes.length) {
      final capWarning = capped
          ? '\n[Warning: limit capped at $maxExtractResultBytes bytes.]'
          : '';
      return FileToolResult(
        text:
            '[Extracted format=${result.format}; bytes $offset-$offset of ${bytes.length}; next_offset=$offset; has_more=false]\n(empty)$capWarning',
      );
    }

    final startIndex = _skipUtf8ContinuationBytes(bytes, offset);
    final endIndex = _takeCompleteUtf8Bytes(
      bytes,
      startIndex,
      math.min(bytes.length, startIndex + limit),
    );
    final nextOffset = endIndex;
    final hasMore = nextOffset < bytes.length;
    final text = utf8.decode(
      bytes.sublist(startIndex, endIndex),
      allowMalformed: true,
    );
    final capWarning = capped
        ? '\n[Warning: limit capped at $maxExtractResultBytes bytes.]'
        : '';
    final truncationWarning = !hasMore && result.truncated
        ? '\n[Warning: extraction capped at $maxExtractedTextBytes bytes; the document contains more text.]'
        : '';
    return FileToolResult(
      text:
          '[Extracted format=${result.format}; bytes $startIndex-$nextOffset of ${bytes.length}; next_offset=$nextOffset; has_more=$hasMore]$truncationWarning\n$text$capWarning',
    );
  }

  static int _skipUtf8ContinuationBytes(List<int> bytes, int start) {
    var index = start;
    while (index < bytes.length && _isUtf8Continuation(bytes[index])) {
      index++;
    }
    return index;
  }

  static bool _isUtf8Continuation(int byte) {
    return byte >= 0x80 && byte <= 0xbf;
  }

  static int _takeCompleteUtf8Bytes(List<int> bytes, int start, int maxEnd) {
    var index = start;
    while (index < maxEnd) {
      final width = _utf8SequenceLength(bytes, index, maxEnd);
      if (width == 0) {
        // The requested byte limit may end in the middle of a code point.
        // Include that complete code point, even if the segment grows by a
        // few bytes, so callers never receive a split UTF-8 sequence.
        final completeWidth = _utf8SequenceLength(bytes, index, bytes.length);
        if (completeWidth == 0) break;
        index += completeWidth;
        break;
      }
      index += width;
    }

    // Make forward progress for malformed input rather than returning the
    // same segment repeatedly.
    if (index == start && start < maxEnd) return start + 1;
    return index;
  }

  static int _utf8SequenceLength(List<int> bytes, int index, int maxEnd) {
    final first = bytes[index];
    final width = first <= 0x7f
        ? 1
        : first >= 0xc2 && first <= 0xdf
        ? 2
        : first >= 0xe0 && first <= 0xef
        ? 3
        : first >= 0xf0 && first <= 0xf4
        ? 4
        : 1;
    if (index + width > maxEnd) return 0;
    for (var i = index + 1; i < index + width; i++) {
      if (!_isUtf8Continuation(bytes[i])) return 1;
    }
    return width;
  }

  static Future<FileToolResult> _edit(
    Map<String, dynamic> args,
    String workspace,
  ) async {
    final path = resolveSafePath(_requiredString(args, 'path'), workspace);
    _rejectBlockedExtension(path);
    final file = File(path);
    if (!await file.exists()) {
      return const FileToolResult(text: 'Error: File not found.');
    }

    final oldText = _requiredTextArgument(args, 'old_text', allowEmpty: false);
    final newText = _requiredTextArgument(args, 'new_text');
    final replaceAll = args['replace_all'] ?? false;
    if (replaceAll is! bool) {
      return const FileToolResult(
        text: 'Error: The replace_all argument must be a boolean.',
      );
    }

    if (oldText.length > maxWriteBytes || newText.length > maxWriteBytes) {
      return const FileToolResult(
        text: 'Error: The edit text arguments exceed the 512 KB limit.',
      );
    }
    final oldTextBytes = utf8.encode(oldText);
    final newTextBytes = utf8.encode(newText);
    if (oldTextBytes.length + newTextBytes.length > maxWriteBytes) {
      return const FileToolResult(
        text:
            'Error: The combined edit text arguments exceed the 512 KB limit.',
      );
    }

    final snapshot = await _readMutableFile(file);
    final original = snapshot.content;
    final occurrences = _countOccurrences(original, oldText);
    if (occurrences == 0) {
      return const FileToolResult(
        text: 'Error: The old_text was not found; the file was not changed.',
      );
    }
    if (!replaceAll && occurrences != 1) {
      return FileToolResult(
        text:
            'Error: old_text matched $occurrences times. Provide more context or set replace_all=true.',
      );
    }

    final estimatedSize =
        snapshot.bytes.length +
        (newTextBytes.length - oldTextBytes.length) * occurrences;
    if (estimatedSize > maxWriteBytes) {
      return const FileToolResult(
        text: 'Error: The resulting file would exceed the 512 KB limit.',
      );
    }

    final updated = replaceAll
        ? original.replaceAll(oldText, newText)
        : original.replaceRange(
            original.indexOf(oldText),
            original.indexOf(oldText) + oldText.length,
            newText,
          );
    return await _writeModifiedText(
      path,
      updated,
      action: 'Edited',
      expectedBytes: snapshot.bytes,
    );
  }

  static int _countOccurrences(String source, String needle) {
    var count = 0;
    var start = 0;
    while (true) {
      final index = source.indexOf(needle, start);
      if (index < 0) return count;
      count++;
      start = index + needle.length;
    }
  }

  static Future<FileToolResult> _patch(
    Map<String, dynamic> args,
    String workspace,
  ) async {
    final path = resolveSafePath(_requiredString(args, 'path'), workspace);
    _rejectBlockedExtension(path);
    final patch = _requiredTextArgument(args, 'patch', allowEmpty: false);
    if (utf8.encode(patch).length > maxWriteBytes) {
      return const FileToolResult(
        text: 'Error: The patch exceeds the 512 KB limit.',
      );
    }

    final file = File(path);
    if (!await file.exists()) {
      return const FileToolResult(text: 'Error: File not found.');
    }
    final snapshot = await _readMutableFile(file);
    final parsed = _parseUnifiedPatch(patch);
    final updated = _applyUnifiedPatch(snapshot.content, parsed);
    return await _writeModifiedText(
      path,
      updated,
      action: 'Patched',
      expectedBytes: snapshot.bytes,
    );
  }

  static Future<_MutableFileSnapshot> _readMutableFile(File file) async {
    final type = FileSystemEntity.typeSync(file.path, followLinks: false);
    if (type != FileSystemEntityType.file) {
      throw ArgumentError('The target must be a regular file.');
    }
    final bytes = await file.readAsBytes();
    if (bytes.length > maxWriteBytes) {
      throw ArgumentError('The target file exceeds the 512 KB edit limit.');
    }
    try {
      return _MutableFileSnapshot(
        bytes: bytes,
        content: utf8.decode(bytes, allowMalformed: false),
      );
    } on FormatException {
      throw ArgumentError('The target file is not valid UTF-8 text.');
    }
  }

  static Future<FileToolResult> _writeModifiedText(
    String path,
    String content, {
    required String action,
    required List<int> expectedBytes,
  }) async {
    final bytes = utf8.encode(content);
    if (bytes.length > maxWriteBytes) {
      return const FileToolResult(
        text: 'Error: The resulting file would exceed the 512 KB limit.',
      );
    }
    final file = File(path);
    final currentBytes = await file.readAsBytes();
    if (!_bytesEqual(currentBytes, expectedBytes)) {
      return const FileToolResult(
        text: 'Error: The file changed while editing; no changes were made.',
      );
    }
    await _atomicReplace(file, bytes);
    final size = await file.length();
    return FileToolResult(
      text: '$action ${p.basename(path)} ($size bytes).',
      createdOrModifiedFilePath: path,
      fileName: p.basename(path),
      fileSizeBytes: size,
    );
  }

  static bool _bytesEqual(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    for (var i = 0; i < left.length; i++) {
      if (left[i] != right[i]) return false;
    }
    return true;
  }

  static Future<void> _atomicReplace(File target, List<int> bytes) async {
    final token =
        '${DateTime.now().microsecondsSinceEpoch}_${target.path.hashCode.abs()}';
    final temporary = File('${target.path}.omnichat-tmp-$token');
    final backup = File('${target.path}.omnichat-backup-$token');
    await temporary.writeAsBytes(bytes, flush: true);

    try {
      if (!Platform.isWindows) {
        // A same-directory rename is atomic on the supported desktop/mobile
        // filesystems and replaces the existing file.
        await temporary.rename(target.path);
        return;
      }

      // Windows does not reliably replace an existing file with rename().
      // Keep a recovery copy while swapping the prepared temporary file in.
      await target.rename(backup.path);
      try {
        await temporary.rename(target.path);
      } catch (_) {
        if (!await target.exists() && await backup.exists()) {
          await backup.rename(target.path);
        }
        rethrow;
      }
      try {
        if (await backup.exists()) await backup.delete();
      } catch (_) {
        // The new target is already installed; a stale backup is harmless.
      }
    } finally {
      if (await temporary.exists()) {
        try {
          await temporary.delete();
        } catch (_) {}
      }
      if (Platform.isWindows &&
          !await target.exists() &&
          await backup.exists()) {
        try {
          await backup.rename(target.path);
        } catch (_) {}
      }
    }
  }

  static _ParsedUnifiedPatch _parseUnifiedPatch(String patch) {
    final normalized = patch.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final lines = normalized.split('\n');
    var index = 0;
    final hunks = <_PatchHunk>[];
    var inputHasNoFinalNewline = false;
    var outputHasNoFinalNewline = false;

    // File headers are optional metadata. The explicit tool path remains the
    // only path used by the filesystem operation.
    if (index < lines.length && lines[index].startsWith('--- ')) {
      if (index + 1 >= lines.length || !lines[index + 1].startsWith('+++ ')) {
        throw ArgumentError('Invalid unified patch file headers.');
      }
      index += 2;
    }

    while (index < lines.length) {
      if (lines[index].trim().isEmpty) {
        index++;
        continue;
      }
      final header = lines[index];
      final match = RegExp(
        r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@',
      ).firstMatch(header);
      if (match == null) {
        throw ArgumentError('Invalid unified patch hunk header.');
      }

      final oldStart = int.parse(match.group(1)!);
      final oldCount = int.tryParse(match.group(2) ?? '1')!;
      final newStart = int.parse(match.group(3)!);
      final newCount = int.tryParse(match.group(4) ?? '1')!;
      final patchLines = <_PatchLine>[];
      var oldSeen = 0;
      var newSeen = 0;
      String? previousPrefix;
      index++;

      while (index < lines.length && !lines[index].startsWith('@@ ')) {
        final line = lines[index];
        // split('\n') leaves one empty element when a normal patch ends with
        // a newline. It is framing, not an empty patch hunk line.
        if (line.isEmpty && index == lines.length - 1) {
          index++;
          break;
        }
        if (line == r'\ No newline at end of file') {
          if (previousPrefix == '-' || previousPrefix == ' ') {
            inputHasNoFinalNewline = true;
          }
          if (previousPrefix == '+' || previousPrefix == ' ') {
            outputHasNoFinalNewline = true;
          }
          index++;
          continue;
        }
        if (line.isEmpty ||
            (line[0] != ' ' && line[0] != '+' && line[0] != '-')) {
          throw ArgumentError('Invalid unified patch line.');
        }
        final prefix = line[0];
        final content = line.substring(1);
        if (prefix == ' ' || prefix == '-') oldSeen++;
        if (prefix == ' ' || prefix == '+') newSeen++;
        patchLines.add(_PatchLine(prefix: prefix, content: content));
        previousPrefix = prefix;
        index++;
      }

      if (oldSeen != oldCount || newSeen != newCount) {
        throw ArgumentError(
          'Unified patch hunk line counts do not match its header.',
        );
      }
      hunks.add(
        _PatchHunk(
          oldStart: oldStart,
          oldCount: oldCount,
          newStart: newStart,
          newCount: newCount,
          lines: patchLines,
        ),
      );
    }

    if (hunks.isEmpty) {
      throw ArgumentError('The unified patch contains no hunks.');
    }
    return _ParsedUnifiedPatch(
      hunks: hunks,
      inputHasNoFinalNewline: inputHasNoFinalNewline,
      outputHasNoFinalNewline: outputHasNoFinalNewline,
    );
  }

  static String _applyUnifiedPatch(String source, _ParsedUnifiedPatch patch) {
    final normalizedSource = source
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');
    final sourceHasFinalNewline = normalizedSource.endsWith('\n');
    if (patch.inputHasNoFinalNewline && sourceHasFinalNewline) {
      throw ArgumentError(
        'Patch newline metadata does not match the current file.',
      );
    }
    final newline = source.contains('\r\n') ? '\r\n' : '\n';
    final sourceLines = normalizedSource.isEmpty
        ? <String>[]
        : normalizedSource.split('\n');
    if (sourceHasFinalNewline && sourceLines.isNotEmpty) {
      sourceLines.removeLast();
    }

    final output = <String>[];
    var cursor = 0;
    for (final hunk in patch.hunks) {
      final start = hunk.oldCount == 0 ? hunk.oldStart : hunk.oldStart - 1;
      if (start < cursor || start > sourceLines.length) {
        throw ArgumentError('Patch hunk starts outside the current file.');
      }
      output.addAll(sourceLines.sublist(cursor, start));
      cursor = start;

      for (final line in hunk.lines) {
        if (line.prefix == '+') {
          output.add(line.content);
          continue;
        }
        if (cursor >= sourceLines.length ||
            sourceLines[cursor] != line.content) {
          throw ArgumentError(
            'Patch context did not match; the file was not changed.',
          );
        }
        if (line.prefix == ' ') output.add(line.content);
        cursor++;
      }
    }
    output.addAll(sourceLines.sublist(cursor));

    var result = output.join('\n');
    final patchTouchesOutputEnd = patch.hunks.any((hunk) {
      final outputEnd = hunk.newCount == 0
          ? hunk.newStart - 1
          : hunk.newStart + hunk.newCount - 1;
      return outputEnd == output.length;
    });
    final patchTouchesInputEnd = patch.hunks.any((hunk) {
      final inputEnd = hunk.oldCount == 0
          ? hunk.oldStart - 1
          : hunk.oldStart + hunk.oldCount - 1;
      return inputEnd == sourceLines.length;
    });
    final shouldEndWithNewline =
        !patch.outputHasNoFinalNewline &&
        (sourceHasFinalNewline ||
            patchTouchesOutputEnd ||
            patchTouchesInputEnd);
    if (shouldEndWithNewline && result.isNotEmpty) result += '\n';
    if (newline != '\n') result = result.replaceAll('\n', newline);
    return result;
  }

  static Future<FileToolResult> _write(
    Map<String, dynamic> args,
    String workspace, {
    required bool append,
  }) async {
    final path = resolveSafePath(_requiredString(args, 'path'), workspace);
    _rejectBlockedExtension(path);
    if (!args.containsKey('content') || args['content'] is! String) {
      return const FileToolResult(
        text: 'Error: The content argument is required and must be a string.',
      );
    }
    final content = args['content'] as String;
    final bytes = utf8.encode(content);
    final file = File(path);
    if (append && !await file.exists()) {
      return const FileToolResult(text: 'Error: File not found.');
    }
    final existingLength = append ? await file.length() : 0;
    if (existingLength + bytes.length > maxWriteBytes) {
      return const FileToolResult(
        text: 'Error: File size would exceed the 512 KB limit.',
      );
    }
    await file.parent.create(recursive: true);
    if (append) {
      await file.writeAsBytes(bytes, mode: FileMode.append);
    } else {
      await file.writeAsBytes(bytes, flush: true);
    }
    final size = await file.length();
    return FileToolResult(
      text:
          '${append ? 'Appended to' : 'Wrote'} ${p.basename(path)} ($size bytes).',
      createdOrModifiedFilePath: path,
      fileName: p.basename(path),
      fileSizeBytes: size,
    );
  }

  static Future<FileToolResult> _delete(
    Map<String, dynamic> args,
    String workspace,
  ) async {
    final path = resolveSafePath(_requiredString(args, 'path'), workspace);
    if (_samePath(path, workspace)) {
      return const FileToolResult(
        text: 'Error: The workspace root cannot be deleted.',
      );
    }
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      return const FileToolResult(text: 'Error: Path not found.');
    }
    if (type == FileSystemEntityType.directory) {
      await Directory(path).delete();
    } else {
      await File(path).delete();
    }
    return FileToolResult(text: 'Deleted ${p.basename(path)}.');
  }

  static Future<FileToolResult> _list(
    Map<String, dynamic> args,
    String workspace,
  ) async {
    final path = resolveSafePath((args['path'] ?? '').toString(), workspace);
    final directory = Directory(path);
    if (!await directory.exists())
      return const FileToolResult(text: 'Error: Directory not found.');
    final entries = <FileSystemEntity>[];
    await for (final entry in directory.list(followLinks: false)) {
      entries.add(entry);
      if (entries.length > maxListedEntries) break;
    }
    entries.sort(
      (a, b) => p
          .basename(a.path)
          .toLowerCase()
          .compareTo(p.basename(b.path).toLowerCase()),
    );
    final lines = <String>[];
    for (final entry in entries.take(maxListedEntries)) {
      final type = FileSystemEntity.typeSync(entry.path, followLinks: false);
      final marker = type == FileSystemEntityType.directory
          ? '[dir]'
          : '[file]';
      lines.add('$marker ${p.relative(entry.path, from: workspace)}');
    }
    if (entries.length > maxListedEntries)
      lines.add('[Warning: listing truncated.]');
    return FileToolResult(text: lines.isEmpty ? '(empty)' : lines.join('\n'));
  }

  static Future<FileToolResult> _mkdir(
    Map<String, dynamic> args,
    String workspace,
  ) async {
    final path = resolveSafePath(_requiredString(args, 'path'), workspace);
    await Directory(path).create(recursive: true);
    return FileToolResult(text: 'Created directory ${p.basename(path)}.');
  }

  static Future<FileToolResult> _info(
    Map<String, dynamic> args,
    String workspace,
  ) async {
    final path = resolveSafePath(_requiredString(args, 'path'), workspace);
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.notFound)
      return const FileToolResult(text: 'Error: Path not found.');
    final stat = await FileStat.stat(path);
    return FileToolResult(
      text: jsonEncode({
        'path': p.relative(path, from: workspace),
        'type': type == FileSystemEntityType.directory ? 'directory' : 'file',
        'sizeBytes': stat.size,
        'modifiedAt': stat.modified.toIso8601String(),
      }),
    );
  }

  static Future<FileToolResult> _moveOrCopy(
    Map<String, dynamic> args,
    String workspace, {
    required bool move,
  }) async {
    final source = resolveSafePath(_requiredString(args, 'source'), workspace);
    final destination = resolveSafePath(
      _requiredString(args, 'destination'),
      workspace,
    );
    _rejectBlockedExtension(destination);
    final sourceType = FileSystemEntity.typeSync(source, followLinks: false);
    if (sourceType == FileSystemEntityType.notFound)
      return const FileToolResult(text: 'Error: Source not found.');
    if (FileSystemEntity.typeSync(destination, followLinks: false) !=
        FileSystemEntityType.notFound) {
      return const FileToolResult(text: 'Error: Destination already exists.');
    }

    await Directory(destination).parent.create(recursive: true);
    if (!move && sourceType == FileSystemEntityType.directory) {
      return const FileToolResult(
        text: 'Error: file_copy only supports files.',
      );
    }
    if (move) {
      if (sourceType == FileSystemEntityType.directory) {
        await Directory(source).rename(destination);
      } else {
        await File(source).rename(destination);
      }
    } else {
      await File(source).copy(destination);
    }
    final size = sourceType == FileSystemEntityType.directory
        ? null
        : await File(destination).length();
    return FileToolResult(
      text:
          '${move ? 'Moved' : 'Copied'} ${p.basename(source)} to ${p.relative(destination, from: workspace)}.',
      createdOrModifiedFilePath: size == null ? null : destination,
      fileName: size == null ? null : p.basename(destination),
      fileSizeBytes: size,
    );
  }

  static Future<FileToolResult> _search(
    Map<String, dynamic> args,
    String workspace,
  ) async {
    final pattern = _requiredString(args, 'pattern');
    final start = resolveSafePath((args['path'] ?? '').toString(), workspace);
    final directory = Directory(start);
    if (!await directory.exists())
      return const FileToolResult(text: 'Error: Directory not found.');
    final wildcard = pattern.contains('*') || pattern.contains('?');
    final regex = wildcard ? _wildcardRegex(pattern) : null;
    final matches = <String>[];
    var visitedEntries = 0;
    var scanTruncated = false;
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      visitedEntries += 1;
      final relative = p
          .relative(entity.path, from: start)
          .replaceAll('\\', '/');
      final name = p.basename(entity.path);
      final matched = wildcard
          ? regex!.hasMatch(name) || regex.hasMatch(relative)
          : relative.toLowerCase().contains(pattern.toLowerCase());
      if (matched) {
        matches.add(p.relative(entity.path, from: workspace));
        if (matches.length >= maxSearchResults) {
          scanTruncated = true;
          break;
        }
      }
      if (visitedEntries >= maxSearchEntries) {
        scanTruncated = true;
        break;
      }
    }
    if (matches.isEmpty) {
      return FileToolResult(
        text: scanTruncated
            ? 'No matching files found in the first $maxSearchEntries entries.\n[Warning: search scan truncated.]'
            : 'No matching files found.',
      );
    }
    final text = matches.join('\n');
    return FileToolResult(
      text: scanTruncated ? '$text\n[Warning: results truncated.]' : text,
    );
  }

  static RegExp _wildcardRegex(String pattern) {
    final out = StringBuffer('^');
    for (final rune in pattern.runes) {
      final char = String.fromCharCode(rune);
      if (char == '*') {
        out.write('.*');
      } else if (char == '?') {
        out.write('.');
      } else {
        out.write(RegExp.escape(char));
      }
    }
    out.write(r'$');
    return RegExp(out.toString(), caseSensitive: false);
  }

  static bool _samePath(String left, String right) {
    final a = p.normalize(left).replaceAll('\\', '/');
    final b = p.normalize(right).replaceAll('\\', '/');
    return Platform.isWindows ? a.toLowerCase() == b.toLowerCase() : a == b;
  }
}

class _PatchLine {
  const _PatchLine({required this.prefix, required this.content});

  final String prefix;
  final String content;
}

class _PatchHunk {
  const _PatchHunk({
    required this.oldStart,
    required this.oldCount,
    required this.newStart,
    required this.newCount,
    required this.lines,
  });

  final int oldStart;
  final int oldCount;
  final int newStart;
  final int newCount;
  final List<_PatchLine> lines;
}

class _ParsedUnifiedPatch {
  const _ParsedUnifiedPatch({
    required this.hunks,
    required this.inputHasNoFinalNewline,
    required this.outputHasNoFinalNewline,
  });

  final List<_PatchHunk> hunks;
  final bool inputHasNoFinalNewline;
  final bool outputHasNoFinalNewline;
}

class _MutableFileSnapshot {
  const _MutableFileSnapshot({required this.bytes, required this.content});

  final List<int> bytes;
  final String content;
}
