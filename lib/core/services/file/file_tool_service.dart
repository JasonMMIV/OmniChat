import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../utils/app_directories.dart';

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

  static const int maxReadBytes = 1024 * 1024;
  static const int maxWriteBytes = 512 * 1024;
  static const int maxListedEntries = 1000;
  static const int maxSearchResults = 1000;
  static const int maxSearchEntries = 10000;

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
        'Read UTF-8 text from a workspace file.',
        {'path': pathProperty},
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

  static Future<FileToolResult> _read(
    Map<String, dynamic> args,
    String workspace,
  ) async {
    final path = resolveSafePath(_requiredString(args, 'path'), workspace);
    final file = File(path);
    if (!await file.exists())
      return FileToolResult(text: 'Error: File not found.');
    final handle = await file.open();
    late final List<int> bytes;
    try {
      // Read one extra byte so truncation can be reported without loading the
      // whole file into memory.
      bytes = await handle.read(maxReadBytes + 1);
    } finally {
      await handle.close();
    }
    final truncated = bytes.length > maxReadBytes;
    final text = utf8.decode(
      truncated ? bytes.sublist(0, maxReadBytes) : bytes,
      allowMalformed: true,
    );
    return FileToolResult(
      text: truncated ? '$text\n[Warning: output truncated at 1 MB.]' : text,
    );
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
