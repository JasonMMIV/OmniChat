import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../logging/flutter_logger.dart';
import 'dev_mime.dart';
import 'dev_server_service.dart';

/// One open preview tab (a page or a directory listing).
class DevPreviewTab {
  const DevPreviewTab({
    required this.id,
    required this.relativePath,
    required this.title,
    required this.url,
  });

  final int id;

  /// Workspace-relative path, `/`-separated; empty means the workspace root.
  final String relativePath;

  final String title;
  final String url;
}

/// One HTML entry point discovered in the workspace.
class DevPreviewEntry {
  const DevPreviewEntry({required this.relativePath, required this.title});

  final String relativePath;
  final String title;
}

/// State for one open preview panel.
///
/// The controller owns the loopback server session: `start()` binds it and
/// `dispose()` closes it. Tabs, console entries and entry-point discovery live
/// here so the panel widget stays a thin view (and the logic is unit-testable).
class DevPreviewController extends ChangeNotifier {
  DevPreviewController({required String workspaceRoot, String? initialPath})
    : workspaceRoot = workspaceRoot,
      _initialPath = initialPath;

  final String workspaceRoot;
  final String? _initialPath;

  DevServerSession? _session;
  StreamSubscription<DevServerEvent>? _subscription;
  Timer? _consoleNotify;
  Timer? _entriesRefresh;
  bool _disposed = false;

  final List<DevPreviewTab> _tabs = <DevPreviewTab>[];
  final List<DevPreviewEntry> _entries = <DevPreviewEntry>[];
  final List<DevConsoleEntry> _console = <DevConsoleEntry>[];

  int _activeTabId = 0;
  int _sequence = 0;
  bool _loading = true;
  String? _error;

  static const int _maxEntries = 80;
  static const int _maxConsoleEntries = 300;
  static const Set<String> _skipDirectories = <String>{
    'node_modules',
    '.git',
    '.dart_tool',
    '.idea',
    '.vscode',
    'build',
    'dist',
    'coverage',
    '.omnichat',
  };

  List<DevPreviewTab> get tabs => List<DevPreviewTab>.unmodifiable(_tabs);
  List<DevPreviewEntry> get entries =>
      List<DevPreviewEntry>.unmodifiable(_entries);
  List<DevConsoleEntry> get console =>
      List<DevConsoleEntry>.unmodifiable(_console);

  bool get loading => _loading;
  String? get error => _error;
  DevServerSession? get session => _session;
  String? get baseUrl => _session?.baseUrl;

  int get errorCount =>
      _console.where((entry) => entry.level == 'error').length;
  int get warningCount =>
      _console.where((entry) => entry.level == 'warn').length;

  DevPreviewTab? get activeTab {
    if (_tabs.isEmpty) return null;
    for (final tab in _tabs) {
      if (tab.id == _activeTabId) return tab;
    }
    return _tabs.last;
  }

  bool get isRunning => _session != null && !_session!.isClosed;

  Future<void> start() async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final session = await DevServerService.instance.start(
        workspaceRoot: workspaceRoot,
      );
      if (_disposed) {
        await DevServerService.instance.stop(session);
        return;
      }
      _session = session;
      _subscription = session.events.listen(_onSessionEvent);
      _console
        ..clear()
        ..addAll(session.consoleEntries);
      // A retry binds a new random port; existing tabs must follow it or they
      // would keep pointing at the dead session.
      if (_tabs.isNotEmpty) {
        final rebuilt = <DevPreviewTab>[
          for (final tab in _tabs)
            DevPreviewTab(
              id: tab.id,
              relativePath: tab.relativePath,
              title: tab.title,
              url: session.urlFor(tab.relativePath),
            ),
        ];
        _tabs
          ..clear()
          ..addAll(rebuilt);
      }
      await refreshEntries();
      if (_disposed) return;
      final initial = (_initialPath ?? '').trim();
      if (initial.isNotEmpty) {
        openPath(initial);
      } else {
        DevPreviewEntry? index;
        for (final entry in _entries) {
          if (entry.relativePath.toLowerCase() == 'index.html') {
            index = entry;
            break;
          }
        }
        if (index != null) openPath(index.relativePath);
      }
    } catch (e) {
      // Details go to the debug log; the panel shows a localized message.
      FlutterLogger.log('Dev preview failed to start: $e', tag: 'dev-preview');
      _error = '$e';
    } finally {
      if (!_disposed) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  /// Re-binds after a failure (button in the error state).
  Future<void> retry() async {
    await _teardownSession();
    await start();
  }

  void openPath(String relativePath) {
    final normalized = _normalize(relativePath);
    for (final tab in _tabs) {
      if (tab.relativePath == normalized) {
        _activeTabId = tab.id;
        notifyListeners();
        return;
      }
    }
    final session = _session;
    if (session == null || session.isClosed) return;
    final tab = DevPreviewTab(
      id: ++_sequence,
      relativePath: normalized,
      title: _titleFor(normalized),
      url: session.urlFor(normalized),
    );
    _tabs.add(tab);
    _activeTabId = tab.id;
    notifyListeners();
  }

  void openEntry(DevPreviewEntry entry) => openPath(entry.relativePath);

  void selectTab(int id) {
    if (_activeTabId == id) return;
    _activeTabId = id;
    notifyListeners();
  }

  void closeTab(int id) {
    final index = _tabs.indexWhere((tab) => tab.id == id);
    if (index < 0) return;
    _tabs.removeAt(index);
    if (_tabs.isEmpty) {
      _activeTabId = 0;
    } else if (_activeTabId == id) {
      _activeTabId = _tabs[index.clamp(0, _tabs.length - 1)].id;
    }
    notifyListeners();
  }

  void clearConsole() {
    _console.clear();
    notifyListeners();
  }

  Future<void> refreshEntries() async {
    final found = <DevPreviewEntry>[];
    Future<void> walk(Directory directory, int depth) async {
      if (found.length >= _maxEntries || depth > 3) return;
      List<FileSystemEntity> children;
      try {
        children = await directory.list(followLinks: false).toList();
      } catch (_) {
        return;
      }
      children.sort((a, b) => a.path.compareTo(b.path));
      for (final child in children) {
        if (found.length >= _maxEntries) return;
        final name = p.basename(child.path);
        if (name.isEmpty || name.startsWith('.')) continue;
        final type = FileSystemEntity.typeSync(child.path, followLinks: false);
        if (type == FileSystemEntityType.directory) {
          if (_skipDirectories.contains(name)) continue;
          await walk(Directory(child.path), depth + 1);
        } else if (type == FileSystemEntityType.file && devIsHtmlPath(name)) {
          final relative = p
              .relative(child.path, from: workspaceRoot)
              .replaceAll('\\', '/');
          found.add(DevPreviewEntry(relativePath: relative, title: relative));
        }
      }
    }

    try {
      await walk(Directory(workspaceRoot), 0);
    } catch (_) {}
    found.sort((a, b) {
      final aIndex = p.basename(a.relativePath).toLowerCase() == 'index.html'
          ? 0
          : 1;
      final bIndex = p.basename(b.relativePath).toLowerCase() == 'index.html'
          ? 0
          : 1;
      if (aIndex != bIndex) return aIndex - bIndex;
      final aDepth = '/'.allMatches(a.relativePath).length;
      final bDepth = '/'.allMatches(b.relativePath).length;
      if (aDepth != bDepth) return aDepth - bDepth;
      return a.relativePath.toLowerCase().compareTo(
        b.relativePath.toLowerCase(),
      );
    });
    _entries
      ..clear()
      ..addAll(found);
    if (!_disposed) notifyListeners();
  }

  void _onSessionEvent(DevServerEvent event) {
    if (_disposed) return;
    switch (event) {
      case DevServerConsoleEvent(:final entry):
        _console.add(entry);
        if (_console.length > _maxConsoleEntries) {
          _console.removeRange(0, _console.length - _maxConsoleEntries);
        }
        _consoleNotify ??= Timer(const Duration(milliseconds: 80), () {
          _consoleNotify = null;
          if (!_disposed) notifyListeners();
        });
      case DevServerConsoleClearedEvent():
        _console.clear();
        notifyListeners();
      case DevServerReloadEvent():
        // The model may have just created a new HTML file; refresh the entry
        // list without making the user press Rescan.
        _entriesRefresh?.cancel();
        _entriesRefresh = Timer(
          const Duration(milliseconds: 500),
          () => unawaited(refreshEntries()),
        );
    }
  }

  Future<void> _teardownSession() async {
    await _subscription?.cancel();
    _subscription = null;
    final session = _session;
    _session = null;
    if (session != null) {
      await DevServerService.instance.stop(session);
    }
  }

  static String _normalize(String path) {
    final cleaned = path.trim().replaceAll('\\', '/');
    final segments = cleaned.split('/').where((segment) => segment.isNotEmpty);
    final trailingSlash = cleaned.endsWith('/');
    final normalized = segments.join('/');
    if (normalized.isEmpty) return '';
    return trailingSlash ? '$normalized/' : normalized;
  }

  static String _titleFor(String relativePath) {
    final trimmed = relativePath.endsWith('/')
        ? relativePath.substring(0, relativePath.length - 1)
        : relativePath;
    if (trimmed.isEmpty) return '/';
    final name = p.basename(trimmed);
    return name.isEmpty ? trimmed : name;
  }

  @override
  void dispose() {
    _disposed = true;
    _consoleNotify?.cancel();
    _consoleNotify = null;
    _entriesRefresh?.cancel();
    _entriesRefresh = null;
    final subscription = _subscription;
    _subscription = null;
    unawaited(subscription?.cancel());
    final session = _session;
    _session = null;
    if (session != null) {
      unawaited(DevServerService.instance.stop(session));
    }
    super.dispose();
  }
}
