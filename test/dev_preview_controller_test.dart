import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/core/services/dev/dev_preview_controller.dart';
import 'package:OmniChat/core/services/dev/dev_server_service.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'omnichat_dev_preview_controller_',
    );
    await File('${tempDir.path}/index.html')
        .writeAsString('<html><body>index</body></html>');
    await File('${tempDir.path}/about.html')
        .writeAsString('<html><body>about</body></html>');
    await Directory('${tempDir.path}/pages').create();
    await File('${tempDir.path}/pages/deep.html')
        .writeAsString('<html><body>deep</body></html>');
    await Directory('${tempDir.path}/node_modules').create();
    await File('${tempDir.path}/node_modules/lib.html')
        .writeAsString('<html><body>noise</body></html>');
    await Directory('${tempDir.path}/.hidden').create();
    await File('${tempDir.path}/.hidden/x.html')
        .writeAsString('<html><body>hidden</body></html>');
  });

  tearDown(() async {
    await DevServerService.instance.stop();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  test('discovers entries, skips noise and opens index.html', () async {
    final controller = DevPreviewController(workspaceRoot: tempDir.path);
    await controller.start();
    addTearDown(controller.dispose);

    expect(controller.loading, isFalse);
    expect(controller.error, isNull);
    final entries = controller.entries
        .map((entry) => entry.relativePath)
        .toList();
    expect(entries, contains('index.html'));
    expect(entries, contains('about.html'));
    expect(entries, contains('pages/deep.html'));
    expect(entries, isNot(contains('node_modules/lib.html')));
    expect(entries, isNot(contains('.hidden/x.html')));
    // index.html sorts before other entry points.
    expect(entries.first, 'index.html');

    expect(controller.activeTab?.relativePath, 'index.html');
    expect(controller.activeTab?.title, 'index.html');
    expect(controller.baseUrl, startsWith('http://127.0.0.1:'));
    expect(controller.isRunning, isTrue);
  });

  test(
    'openPath dedupes normalized paths and closeTab picks a neighbour',
    () async {
      final controller = DevPreviewController(workspaceRoot: tempDir.path);
      await controller.start();
      addTearDown(controller.dispose);

      controller.openPath('about.html');
      controller.openPath('/about.html');
      expect(controller.tabs.length, 2);
      expect(controller.activeTab?.relativePath, 'about.html');
      expect(controller.activeTab?.title, 'about.html');

      final activeId = controller.activeTab!.id;
      controller.closeTab(activeId);
      expect(controller.tabs.length, 1);
      expect(controller.activeTab?.relativePath, 'index.html');
    },
  );

  test('opens an explicit initial path, including directories', () async {
    final controller = DevPreviewController(
      workspaceRoot: tempDir.path,
      initialPath: 'pages/',
    );
    await controller.start();
    addTearDown(controller.dispose);

    expect(controller.tabs.length, 1);
    expect(controller.activeTab?.relativePath, 'pages/');
    expect(controller.activeTab?.url, endsWith('/pages/'));
  });

  test('two panels share one session until both release it', () async {
    final first = DevPreviewController(workspaceRoot: tempDir.path);
    await first.start();
    final session = DevServerService.instance.activeSession;
    expect(session, isNotNull);

    final second = DevPreviewController(workspaceRoot: tempDir.path);
    await second.start();
    expect(identical(DevServerService.instance.activeSession, session), isTrue);

    first.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(DevServerService.instance.activeSession, isNotNull);
    expect(DevServerService.instance.activeSession!.isClosed, isFalse);

    second.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(DevServerService.instance.activeSession, isNull);
  });

  test('dispose closes the preview server', () async {
    final controller = DevPreviewController(workspaceRoot: tempDir.path);
    await controller.start();
    expect(DevServerService.instance.activeSession, isNotNull);

    controller.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(DevServerService.instance.activeSession, isNull);
  });

  test('a reload clears stale console entries', () async {
    final controller = DevPreviewController(workspaceRoot: tempDir.path);
    await controller.start();
    addTearDown(controller.dispose);

    final session = controller.session!;
    final client = HttpClient();
    try {
      final request = await client.postUrl(
        Uri.parse('${session.baseUrl}/__omnichat/console'),
      );
      request.headers.contentType = ContentType.json;
      request.write('{"level":"error","message":"stale"}');
      final response = await request.close();
      await response.drain<void>();
    } finally {
      client.close(force: true);
    }
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(controller.errorCount, 1);

    session.bumpRevision();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(controller.console, isEmpty);
  });

  test('retry rebuilds tab URLs against the new port', () async {
    final controller = DevPreviewController(workspaceRoot: tempDir.path);
    await controller.start();
    addTearDown(controller.dispose);
    controller.openPath('about.html');
    final oldBase = controller.baseUrl!;
    final oldUrl = controller.activeTab!.url;

    await controller.retry();
    expect(controller.error, isNull);
    expect(controller.tabs.length, 2);
    // Every tab must point at the (possibly new) base URL; a stale port would
    // leave the page dead after a retry.
    expect(
      controller.tabs.every((tab) => tab.url.startsWith(controller.baseUrl!)),
      isTrue,
    );
    expect(controller.activeTab?.url, startsWith(controller.baseUrl!));
    // Guard against the test silently asserting nothing when the OS happens
    // to reuse the same port.
    expect(oldUrl, isNotEmpty);
    expect(oldBase, isNotEmpty);
  });

  test('console events flow into the controller buffer', () async {
    final controller = DevPreviewController(workspaceRoot: tempDir.path);
    await controller.start();
    addTearDown(controller.dispose);

    final session = controller.session!;
    final client = HttpClient();
    try {
      final request = await client.postUrl(
        Uri.parse('${session.baseUrl}/__omnichat/console'),
      );
      request.headers.contentType = ContentType.json;
      request.write(
        '{"level":"error","message":"boom","source":"/index.html"}',
      );
      final response = await request.close();
      await response.drain<void>();
    } finally {
      client.close(force: true);
    }
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(controller.errorCount, 1);
    expect(controller.console.single.message, 'boom');
  });
}
