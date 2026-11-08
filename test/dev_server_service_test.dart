import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/core/services/dev/dev_server_service.dart';

class _HttpResult {
  const _HttpResult({
    required this.status,
    required this.body,
    required this.contentType,
    required this.cacheControl,
    this.location,
  });

  final int status;
  final String body;
  final String? contentType;
  final String? cacheControl;
  final String? location;
}

void main() {
  late Directory tempDir;
  late Directory outsideDir;
  late DevServerSession session;

  Future<_HttpResult> get(String path, {bool followRedirects = true}) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse('${session.baseUrl}$path'));
      request.followRedirects = followRedirects;
      final response = await request.close();
      final bytes = await response.fold<List<int>>(
        <int>[],
        (acc, chunk) => acc..addAll(chunk),
      );
      return _HttpResult(
        status: response.statusCode,
        body: utf8.decode(bytes, allowMalformed: true),
        contentType: response.headers.contentType?.toString(),
        cacheControl: response.headers.value('cache-control'),
        location: response.headers.value('location'),
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<_HttpResult> postConsole(
    Map<String, dynamic> payload, {
    String? origin,
  }) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(
        Uri.parse('${session.baseUrl}/__omnichat/console'),
      );
      request.headers.contentType = ContentType.json;
      if (origin != null) request.headers.set('origin', origin);
      request.write(jsonEncode(payload));
      final response = await request.close();
      final bytes = await response.fold<List<int>>(
        <int>[],
        (acc, chunk) => acc..addAll(chunk),
      );
      return _HttpResult(
        status: response.statusCode,
        body: utf8.decode(bytes, allowMalformed: true),
        contentType: response.headers.contentType?.toString(),
        cacheControl: response.headers.value('cache-control'),
      );
    } finally {
      client.close(force: true);
    }
  }

  /// Raw socket request: `HttpClient` normalizes dot segments, which would
  /// hide the traversal cases this server must reject.
  Future<String> rawGet(String target) async {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      session.port,
    );
    try {
      socket.write(
        'GET $target HTTP/1.1\r\n'
        'Host: 127.0.0.1:${session.port}\r\n'
        'Connection: close\r\n\r\n',
      );
      await socket.flush();
      return await utf8.decoder
          .bind(socket)
          .join()
          .timeout(const Duration(seconds: 5));
    } finally {
      socket.destroy();
    }
  }

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'omnichat_dev_server_test_',
    );
    outsideDir = await Directory.systemTemp.createTemp(
      'omnichat_dev_server_outside_',
    );
    await File('${outsideDir.path}/outside.txt')
        .writeAsString('TOP_SECRET_OUTSIDE');
    await File('${tempDir.path}/index.html').writeAsString(
      '<!doctype html><html><head><title>Home</title></head>'
      '<body><h1>home</h1></body></html>',
    );
    await File('${tempDir.path}/style.css').writeAsString('body{color:red}');
    await File('${tempDir.path}/app.js').writeAsString("console.log('x');");
    await File('${tempDir.path}/pixel.png')
        .writeAsBytes(<int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
    await File('${tempDir.path}/.env').writeAsString('SECRET_TOKEN_123');
    await Directory('${tempDir.path}/sub').create();
    await File('${tempDir.path}/sub/index.html')
        .writeAsString('<html><body>sub page</body></html>');
    await Directory('${tempDir.path}/listing').create();
    await File('${tempDir.path}/listing/one.txt').writeAsString('one');
    await Directory('${tempDir.path}/spaced dir').create();
    await File('${tempDir.path}/spaced dir/a b.txt').writeAsString('spaced');
    await File('${tempDir.path}/listing/two.html')
        .writeAsString('<html><body>two</body></html>');
    session = await DevServerSession.start(workspaceRoot: tempDir.path);
  });

  tearDownAll(() async {
    await session.close();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
    try {
      await outsideDir.delete(recursive: true);
    } catch (_) {}
  });

  group('static serving', () {
    test('serves index.html with the injected bridge and no-store', () async {
      final result = await get('/');
      expect(result.status, 200);
      expect(result.contentType, contains('text/html'));
      expect(result.cacheControl, 'no-store');
      expect(result.body, contains('data-omnichat-dev-bridge="1"'));
      expect(result.body, contains('/__omnichat/reload'));
      expect(result.body, contains('/__omnichat/console'));
      // The bridge must run before page scripts in <head>.
      expect(
        result.body.indexOf('data-omnichat-dev-bridge'),
        lessThan(result.body.indexOf('<title>')),
      );
    });

    test('serves the right MIME types', () async {
      final css = await get('/style.css');
      expect(css.status, 200);
      expect(css.contentType, contains('text/css'));
      expect(css.body, 'body{color:red}');

      final js = await get('/app.js');
      expect(js.contentType, contains('text/javascript'));

      final png = await get('/pixel.png');
      expect(png.status, 200);
      expect(png.contentType, 'image/png');
    });

    test('resolves nested index.html and injects after <html>', () async {
      final result = await get('/sub/');
      expect(result.status, 200);
      expect(result.body, contains('sub page'));
      expect(result.body, contains('data-omnichat-dev-bridge="1"'));
    });

    test('directory list escapes names and supports redirect', () async {
      final listing = await get('/listing/');
      expect(listing.status, 200);
      expect(listing.body, contains('one.txt'));
      expect(listing.body, contains('two.html'));
      expect(listing.body, contains('data-omnichat-dev-bridge="1"'));

      final redirect = await get('/listing', followRedirects: false);
      expect(redirect.status, 302);
      expect(redirect.location, '/listing/');
    });

    test('directory links stay encoded for spaces', () async {
      final listing = await get('/spaced%20dir/');
      expect(listing.status, 200);
      // Hrefs must be percent-encoded; display text stays readable.
      expect(listing.body, contains('a%20b.txt'));
      expect(listing.body, contains('a b.txt'));
      expect(listing.body, contains('href="/"'));
    });

    test('404s unknown files and dotfiles without leaking content', () async {
      final missing = await get('/nope.html');
      expect(missing.status, 404);

      final dotfile = await get('/.env');
      expect(dotfile.status, 404);
      expect(dotfile.body, isNot(contains('SECRET_TOKEN_123')));
    });

    test('rejects dot segments, encoded traversal and backslashes', () async {
      // Uri normalizes a literal `/../`; either way the request must never
      // reach the file outside the workspace.
      final direct = await rawGet('/../outside.txt');
      expect(direct, isNot(contains(' 200 ')));
      expect(direct, isNot(contains('TOP_SECRET_OUTSIDE')));

      final encoded = await rawGet('/%2e%2e/outside.txt');
      expect(encoded, isNot(contains('TOP_SECRET_OUTSIDE')));
      expect(encoded, isNot(contains(' 200 ')));

      final backslash = await rawGet('/..%5coutside.txt');
      expect(backslash, isNot(contains('TOP_SECRET_OUTSIDE')));
      expect(backslash, isNot(contains(' 200 ')));
    });

    test('rejects symlinks that escape the workspace', () async {
      final linkPath = '${tempDir.path}/outside_link';
      try {
        await Link(linkPath).create(outsideDir.path);
      } catch (_) {
        // Windows without developer mode cannot create symlinks; the
        // resolver itself is covered by file_tool_service tests.
        return;
      }
      final result = await get('/outside_link/outside.txt');
      expect(result.status, isNot(200));
      expect(result.body, isNot(contains('TOP_SECRET_OUTSIDE')));
    });
  });

  group('console capture', () {
    test('stores entries and filters by level', () async {
      session.clearConsole();
      final error = await postConsole(<String, dynamic>{
        'level': 'error',
        'message': 'ReferenceError: x is not defined',
        'source': '/app.js',
        'line': 12,
      });
      expect(error.status, 204);

      final warn = await postConsole(<String, dynamic>{
        'level': 'warn',
        'message': 'deprecated API',
      });
      expect(warn.status, 204);

      final log = await postConsole(<String, dynamic>{
        'level': 'log',
        'message': 'hello',
      });
      expect(log.status, 204);

      expect(session.consoleEntries.length, 3);
      final errorsJson = jsonDecode(
        session.consoleErrorsJson(levels: 'errors'),
      ) as Map<String, dynamic>;
      expect(errorsJson['counts']['error'], 1);
      expect(errorsJson['counts']['warn'], 1);
      expect((errorsJson['entries'] as List).length, 1);
      expect(
        (errorsJson['entries'] as List).single['message'],
        contains('ReferenceError'),
      );

      final allJson = jsonDecode(
        session.consoleErrorsJson(levels: 'all'),
      ) as Map<String, dynamic>;
      expect((allJson['entries'] as List).length, 3);
    });

    test('rejects cross-origin posts', () async {
      final result = await postConsole(<String, dynamic>{
        'level': 'error',
        'message': 'csrf',
      }, origin: 'http://evil.example');
      expect(result.status, 403);
    });

    test('rejects malformed payloads', () async {
      final client = HttpClient();
      try {
        final request = await client.postUrl(
          Uri.parse('${session.baseUrl}/__omnichat/console'),
        );
        request.headers.contentType = ContentType.json;
        request.write('not json');
        final response = await request.close();
        await response.drain<void>();
        expect(response.statusCode, 400);
      } finally {
        client.close(force: true);
      }
    });

    test('consoleErrorsJson keeps only the newest N entries', () {
      final entries = <DevConsoleEntry>[
        for (var i = 0; i < 5; i++)
          DevConsoleEntry(level: 'error', message: 'error $i'),
      ];
      final decoded = jsonDecode(
        DevServerSession.buildConsoleErrorsJson(
          entries: entries,
          levels: 'errors',
          limit: 2,
        ),
      ) as Map<String, dynamic>;
      expect(decoded['returned'], 2);
      expect(decoded['omitted'], 3);
      final messages = (decoded['entries'] as List)
          .map((entry) => entry['message'])
          .toList();
      expect(messages, <String>['error 3', 'error 4']);
    });

    test('consoleErrorsJson explains a just-reloaded empty buffer', () {
      final decoded = jsonDecode(
        DevServerSession.buildConsoleErrorsJson(
          entries: const <DevConsoleEntry>[],
          levels: 'errors',
          limit: 20,
          revision: 7,
          awaitingReload: true,
        ),
      ) as Map<String, dynamic>;
      expect(decoded['revision'], 7);
      expect(decoded['note'], contains('reloaded (revision 7)'));
      expect(decoded['note'], contains('wait'));
    });

    test('consoleErrorsJson explains an empty buffer', () {
      final decoded = jsonDecode(
        DevServerSession.buildConsoleErrorsJson(
          entries: const <DevConsoleEntry>[],
          levels: 'errors',
          limit: 20,
        ),
      ) as Map<String, dynamic>;
      expect(decoded['returned'], 0);
      expect(decoded['note'], isNotEmpty);
    });
  });

  group('live reload', () {
    test('SSE stream emits a reload event after bumpRevision', () async {
      final client = HttpClient();
      final request = await client.getUrl(
        Uri.parse('${session.baseUrl}/__omnichat/reload'),
      );
      final response = await request.close();
      expect(response.statusCode, 200);
      expect(response.headers.contentType?.mimeType, 'text/event-stream');

      final chunks = <String>[];
      final subscription = response
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(chunks.add);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(chunks.join(), contains('event: hello'));

      session.bumpRevision();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(chunks.join(), contains('event: reload'));

      await subscription.cancel();
      client.close(force: true);
    });

    test('a reload clears stale console entries', () async {
      session.clearConsole();
      await postConsole(<String, dynamic>{
        'level': 'error',
        'message': 'stale error from the previous revision',
      });
      expect(session.consoleEntries, isNotEmpty);
      session.bumpRevision();
      expect(session.consoleEntries, isEmpty);
      expect(session.revision, greaterThan(0));
    });
  });

  group('bridge injection', () {
    test('injects after <head> regardless of case', () {
      final html = DevServerSession.injectBridge(
        '<!doctype html><HTML><HEAD><meta charset="utf-8"></HEAD></HTML>',
      );
      expect(html, contains('data-omnichat-dev-bridge'));
      expect(
        html.indexOf('data-omnichat-dev-bridge'),
        lessThan(html.toLowerCase().indexOf('</head>')),
      );
    });

    test('does not mistake <header> for <head>', () {
      final html = DevServerSession.injectBridge(
        '<!doctype html><html><body><header>h</header></body></html>',
      );
      expect(html, contains('<head><script'));
      expect(html.indexOf('<head><script'), lessThan(html.indexOf('<header>')));
    });

    test('wraps head-less documents without breaking doctype quirks mode', () {
      final html = DevServerSession.injectBridge(
        '<!doctype html><html><body>x</body></html>',
      );
      expect(html, startsWith('<!doctype html>'));
      expect(html, contains('<head><script'));
      expect(html, contains('data-omnichat-dev-bridge'));
    });

    test('prepends when the document is a fragment', () {
      final html = DevServerSession.injectBridge('<p>fragment</p>');
      expect(html, startsWith('<script'));
      expect(html, contains('<p>fragment</p>'));
    });
  });

  group('lifecycle', () {
    test('concurrent starts share one session (single-flight)', () async {
      final dir = await Directory.systemTemp.createTemp(
        'omnichat_dev_singleflight_',
      );
      try {
        final results = await Future.wait(<Future<DevServerSession>>[
          DevServerService.instance.start(workspaceRoot: dir.path),
          DevServerService.instance.start(workspaceRoot: dir.path),
          DevServerService.instance.start(workspaceRoot: dir.path),
        ]);
        expect(identical(results[0], results[1]), isTrue);
        expect(identical(results[1], results[2]), isTrue);
      } finally {
        await DevServerService.instance.stop();
      }
      expect(DevServerService.instance.activeSession, isNull);
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    test('close() releases the port', () async {
      final dir = await Directory.systemTemp.createTemp('omnichat_dev_close_');
      final local = await DevServerSession.start(workspaceRoot: dir.path);
      final port = local.port;
      expect(port, greaterThan(0));
      await local.close();
      expect(local.isClosed, true);
      await expectLater(
        Socket.connect(InternetAddress.loopbackIPv4, port).then((socket) {
          socket.destroy();
        }),
        throwsA(isA<SocketException>()),
      );
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });
  });
}
