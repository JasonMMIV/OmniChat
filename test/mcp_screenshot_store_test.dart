import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:OmniChat/core/services/mcp/mcp_screenshot_store.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.path);

  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;

  @override
  Future<String?> getApplicationSupportPath() async => path;

  @override
  Future<String?> getApplicationCachePath() async => '$path/cache';

  @override
  Future<String?> getTemporaryPath() async => '$path/tmp';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late PathProviderPlatform previous;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('omnichat_mcp_shots_');
    previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
  });

  tearDown(() async {
    PathProviderPlatform.instance = previous;
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Directory shotsDir() => Directory('${tempDir.path}/cache/mcp_screenshots');

  group('McpScreenshotStore.save', () {
    test('writes decodable payloads under the app cache dir (.png)', () async {
      final bytes = utf8.encode('fake-png-bytes');
      final path = await McpScreenshotStore.save(
        mimeType: 'image/png',
        base64Data: base64.encode(bytes),
      );

      expect(path, isNotNull);
      final file = File(path!);
      expect(await file.exists(), isTrue);
      expect(await file.parent.path, shotsDir().path);
      expect(file.path.endsWith('.png'), isTrue);
      expect(await file.readAsBytes(), bytes);
    });

    test('maps jpeg mime to the .jpg extension', () async {
      final path = await McpScreenshotStore.save(
        mimeType: 'image/jpeg',
        base64Data: base64.encode(utf8.encode('jpeg-bytes')),
      );
      expect(path, isNotNull);
      expect(File(path!).path.endsWith('.jpg'), isTrue);
    });

    test('accepts an explicit target directory', () async {
      final target = Directory('${tempDir.path}/custom');
      final path = await McpScreenshotStore.save(
        mimeType: 'image/webp',
        base64Data: base64.encode(utf8.encode('webp')),
        into: target,
      );
      expect(path, isNotNull);
      expect(File(path!).path.startsWith(target.path), isTrue);
      expect(File(path).path.endsWith('.webp'), isTrue);
    });

    test('invalid or empty payloads return null instead of throwing', () async {
      expect(
        await McpScreenshotStore.save(
          mimeType: 'image/png',
          base64Data: 'not-base64!!!',
        ),
        isNull,
      );
      expect(
        await McpScreenshotStore.save(mimeType: 'image/png', base64Data: ''),
        isNull,
      );
      expect(
        await McpScreenshotStore.save(
          mimeType: 'image/png',
          base64Data: base64.encode(<int>[]),
        ),
        isNull,
      );
    });
  });

  group('McpScreenshotStore.prune', () {
    test('keeps only the newest files', () async {
      await shotsDir().create(recursive: true);
      for (var i = 0; i < 5; i++) {
        final f = File('${shotsDir().path}/shot_$i.png');
        await f.writeAsString('x$i');
        await f.setLastModified(DateTime(2026, 1, 1).add(Duration(days: i)));
      }
      await McpScreenshotStore.prune(keep: 2);

      final remaining = shotsDir()
          .listSync()
          .whereType<File>()
          .map((f) => f.uri.pathSegments.last)
          .toSet();
      expect(remaining, hasLength(2));
      expect(remaining, containsAll(<String>['shot_3.png', 'shot_4.png']));
    });

    test('missing directory is a no-op', () async {
      await McpScreenshotStore.prune(keep: 2);
      expect(shotsDir().existsSync(), isFalse);
    });
  });
}
