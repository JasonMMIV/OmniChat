import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/core/services/file/file_tool_service.dart';
import 'package:OmniChat/core/services/file/session_outputs.dart';
import 'package:path/path.dart' as p;

void main() {
  group('file_grep', () {
    test('exposes file_grep and file_view_image in the definition list', () {
      final names = FileToolService.getToolDefinitions()
          .map((d) => ((d['function'] as Map)['name'] ?? '').toString())
          .toList();
      expect(names, contains('file_grep'));
      expect(names, contains('file_view_image'));
    });

    test('returns path:line: text rows and skips dot dirs and binaries',
        () async {
      final workspace = await Directory.systemTemp.createTemp('omnichat_grep');
      addTearDown(() => workspace.delete(recursive: true));
      await File(
        '${workspace.path}/a.dart',
      ).writeAsString('hello world\nFoo hello bar\n');
      await File('${workspace.path}/b.txt').writeAsString('say hello once\n');
      await Directory('${workspace.path}/.git').create();
      await File(
        '${workspace.path}/.git/hidden.dart',
      ).writeAsString('hello inside git\n');
      await File(
        '${workspace.path}/bin.dat',
      ).writeAsBytes(<int>[0x00, 0x01, 0x68, 0x69]);

      final result = await FileToolService.execute(
        'file_grep',
        <String, dynamic>{'pattern': 'hello'},
        workspace.path,
      );

      expect(result.text, contains('a.dart:1: hello world'));
      expect(result.text, contains('a.dart:2: Foo hello bar'));
      expect(result.text, contains('b.txt:1: say hello once'));
      expect(result.text, isNot(contains('.git')));
      expect(result.text, isNot(contains('bin.dat')));
    });

    test('supports ignore_case and falls back to literal matching', () async {
      final workspace = await Directory.systemTemp.createTemp('omnichat_grep');
      addTearDown(() => workspace.delete(recursive: true));
      await File(
        '${workspace.path}/note.txt',
      ).writeAsString('func (hello) world\nHello World\n');

      final insensitive = await FileToolService.execute(
        'file_grep',
        <String, dynamic>{'pattern': 'hello world', 'ignore_case': true},
        workspace.path,
      );
      expect(insensitive.text, contains('note.txt:2: Hello World'));

      final invalid = await FileToolService.execute(
        'file_grep',
        <String, dynamic>{'pattern': '(hello'},
        workspace.path,
      );
      expect(invalid.text, contains('note.txt:1: func (hello) world'));
      expect(invalid.text, contains('matched literally'));
    });

    test('honors the limit argument', () async {
      final workspace = await Directory.systemTemp.createTemp('omnichat_grep');
      addTearDown(() => workspace.delete(recursive: true));
      await File(
        '${workspace.path}/log.txt',
      ).writeAsString(List<String>.generate(10, (i) => 'match $i').join('\n'));

      final result = await FileToolService.execute(
        'file_grep',
        <String, dynamic>{'pattern': 'match', 'limit': 3},
        workspace.path,
      );
      expect(result.text, contains('[Warning: results truncated.]'));
      expect(
        result.text
            .split('\n')
            .where((line) => RegExp(r'^log\.txt:\d+: ').hasMatch(line))
            .length,
        3,
      );
    });

    test('searches a single file target', () async {
      final workspace = await Directory.systemTemp.createTemp('omnichat_grep');
      addTearDown(() => workspace.delete(recursive: true));
      await Directory('${workspace.path}/nested').create();
      await File(
        '${workspace.path}/nested/hay.txt',
      ).writeAsString('the needle here\n');

      final result = await FileToolService.execute(
        'file_grep',
        <String, dynamic>{'pattern': 'needle', 'path': 'nested/hay.txt'},
        workspace.path,
      );
      expect(result.text, contains('nested/hay.txt:1: the needle here'));
    });

    test('rejects traversal outside the workspace', () async {
      final workspace = await Directory.systemTemp.createTemp('omnichat_grep');
      addTearDown(() => workspace.delete(recursive: true));
      final result = await FileToolService.execute(
        'file_grep',
        <String, dynamic>{'pattern': 'x', 'path': '../outside.txt'},
        workspace.path,
      );
      expect(result.text, startsWith('Error:'));
    });

    test('searches the read-only session-outputs zone via model paths',
        () async {
      final workspace = await Directory.systemTemp.createTemp('omnichat_grep');
      addTearDown(() => workspace.delete(recursive: true));
      final zone = await Directory.systemTemp.createTemp('omnichat_zone');
      addTearDown(() => zone.delete(recursive: true));
      await Directory('${zone.path}/conv1').create();
      await File('${zone.path}/conv1/out.txt').writeAsString('needle here\n');

      final result = await FileToolService.execute(
        'file_grep',
        <String, dynamic>{
          'pattern': 'needle',
          'path': 'tool_outputs/conv1/out.txt',
        },
        workspace.path,
        sessionOutputsRoot: zone.path,
      );
      expect(
        result.text,
        contains('${SessionOutputs.modelPrefix}conv1/out.txt:1: needle here'),
      );
    });
  });

  group('file_view_image', () {
    test('validates a PNG and reports the absolute path', () async {
      final workspace = await Directory.systemTemp.createTemp(
        'omnichat_view_image',
      );
      addTearDown(() => workspace.delete(recursive: true));
      // Minimal PNG: 8-byte signature + a few more bytes — the service only
      // sniffs magic bytes, it does not decode the image. The service returns
      // the canonical (symlink/separator-resolved) path, so compare with
      // p.equals instead of raw string equality.
      const png = <int>[
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13,
      ];
      final image = File('${workspace.path}/shot.png');
      await image.writeAsBytes(png);

      final result = await FileToolService.execute(
        'file_view_image',
        <String, dynamic>{'path': 'shot.png'},
        workspace.path,
      );
      expect(result.viewedImagePath, isNotNull);
      expect(p.equals(result.viewedImagePath!, image.path), isTrue);
      expect(result.text, startsWith('[image:'));
      expect(result.text, contains('Format: PNG'));
    });

    test('rejects non-images and missing files', () async {
      final workspace = await Directory.systemTemp.createTemp(
        'omnichat_view_image',
      );
      addTearDown(() => workspace.delete(recursive: true));
      await File('${workspace.path}/readme.txt').writeAsString('plain text\n');

      final notImage = await FileToolService.execute(
        'file_view_image',
        <String, dynamic>{'path': 'readme.txt'},
        workspace.path,
      );
      expect(notImage.text, contains('Not a supported image format'));
      expect(notImage.viewedImagePath, isNull);

      final missing = await FileToolService.execute(
        'file_view_image',
        <String, dynamic>{'path': 'nope.png'},
        workspace.path,
      );
      expect(missing.text, contains('File not found'));
    });
  });
}
