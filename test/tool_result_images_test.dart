import 'dart:io';

import 'package:OmniChat/core/services/api/tool_image_codec.dart';
import 'package:OmniChat/core/services/api/tool_result_images.dart';
import 'package:OmniChat/core/services/agent/compaction/tool_result_pruner.dart';
import 'package:OmniChat/core/services/file/tool_image_access_ledger.dart';
import 'package:OmniChat/core/services/tools/tool_result_caps.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

void main() {
  setUp(ToolImageCache.clear);
  tearDown(ToolImageCache.clear);

  group('tool result marker survival', () {
    test('tool caps keep head and tail image markers', () {
      final content = '[image:C:/a.png]\n${'x' * 40000}\n[image:C:/b.png]';
      final capped = ToolResultCaps.cap(
        toolName: 'file_view_image',
        result: content,
      );
      expect(capped, contains('[image:C:/a.png]'));
      expect(capped, contains('[image:C:/b.png]'));

      final pruned = pruneToolResultText(
        '[image:C:/a.png]\n${'x' * 9000}\n[image:C:/b.png]',
      );
      expect(pruned, isNotNull);
      expect(pruned, contains('[image:C:/a.png]'));
      expect(pruned, contains('[image:C:/b.png]'));
    });
  });

  group('tool result marker extraction', () {
    test('extracts local markers and skips remote/data placeholders', () {
      final markers = extractMarkers(
        'a\n[image:C:/work/a.png]\n'
        '[image:https://example.com/b.png]\n'
        '[image:data:image/png;base64,AAAA]\n'
        '[image:<absolute-path>]\n'
        '[image:C:/work/c.jpg]\n',
      );
      expect(markers.map((m) => m.path), ['C:/work/a.png', 'C:/work/c.jpg']);
    });

    test('skips protocol-relative and UNC network paths', () {
      final markers = extractMarkers(
        <String>[
          '[image://host/share/a.png]',
          r'[image:\\host\share\b.png]',
          '[image:file://host/share/c.png]',
          '[image:C:/work/d.png]',
        ].join('\n'),
      );

      expect(markers.map((m) => m.path), ['C:/work/d.png']);
    });
  });

  group('tool image plan', () {
    late Directory workspace;
    late String imagePath;

    setUp(() async {
      workspace = await Directory.systemTemp.createTemp('omnichat_tool_img');
      imagePath = p.join(workspace.path, 'shot.png');
      await File(imagePath).writeAsBytes(_pngBytes());
    });

    tearDown(() async {
      await workspace.delete(recursive: true);
    });

    ResolvedToolImagePolicy policyFor(Directory dir) =>
        ToolImagePolicy(workspaceRoot: dir.path)
            .resolve(systemRoots: const <String>[]);

    test(
      'attaches a workspace image and removes its marker for Claude',
      () async {
        final plan = await ToolImagePlan.build(
          messages: [
            {'role': 'user', 'content': 'inspect this'},
            {
              'role': 'tool',
              'name': 'file_view_image',
              'tool_call_id': 'call_1',
              'content': '[image:$imagePath]\nFormat: PNG; Size: 1 KB',
            },
          ],
          policy: policyFor(workspace),
          target: ToolImageTarget.claude,
          canImageInput: true,
        );

        expect(plan.totalImages, 1);
        final resolution = plan.byMessageIndex[1]!;
        expect(resolution.images, hasLength(1));
        expect(resolution.images.single.mime, 'image/jpeg');
        expect(resolution.images.single.bytes, isNotEmpty);
        expect(resolution.cleanText, isNot(contains('[image:')));
        expect(resolution.cleanText, contains('Format: PNG'));
      },
    );

    test('network-shaped markers stay text and produce no error', () async {
      final plan = await ToolImagePlan.build(
        messages: [
          {'role': 'user', 'content': 'inspect this'},
          {
            'role': 'tool',
            'name': 'file_view_image',
            'tool_call_id': 'call_1',
            'content': '[image://host/share/a.png]\nFormat: PNG',
          },
        ],
        policy: policyFor(workspace),
        target: ToolImageTarget.claude,
        canImageInput: true,
      );

      expect(plan.totalImages, 0);
      expect(plan.byMessageIndex, isEmpty);
      expect(plan.errors, isEmpty);
    });

    test('rejects an image outside the allowed roots', () async {
      final outside = await Directory.systemTemp.createTemp(
        'omnichat_tool_img_outside',
      );
      addTearDown(() => outside.delete(recursive: true));
      final outsideImage = p.join(outside.path, 'secret.png');
      await File(outsideImage).writeAsBytes(_pngBytes());

      final plan = await ToolImagePlan.build(
        messages: [
          {
            'role': 'tool',
            'name': 'file_view_image',
            'tool_call_id': 'call_1',
            'content': '[image:$outsideImage]',
          },
        ],
        policy: policyFor(workspace),
        target: ToolImageTarget.claude,
        canImageInput: true,
      );

      expect(plan.totalImages, 0);
      expect(plan.byMessageIndex, isEmpty);
      expect(plan.errors.single.code, 'image_outside_workspace');
    });

    test(
      'persisted allowed-path extras cannot grant an outside path',
      () async {
        final outside = await Directory.systemTemp.createTemp(
          'omnichat_tool_img_forged',
        );
        addTearDown(() => outside.delete(recursive: true));
        final outsideImage = p.join(outside.path, 'forged.png');
        await File(outsideImage).writeAsBytes(_pngBytes());

        final plan = await ToolImagePlan.build(
          messages: [
            {
              'role': 'tool',
              'name': 'file_view_image',
              'tool_call_id': 'call_1',
              'content': '[image:$outsideImage]',
              // Simulates a crafted backup/imported chat: the extra says the
              // path is trusted, but only the in-memory ledger may do that.
              '_tool_image_allowed_paths': <String>[outsideImage],
            },
          ],
          policy: policyFor(workspace),
          target: ToolImageTarget.claude,
          canImageInput: true,
        );

        expect(plan.totalImages, 0);
        expect(plan.errors.single.code, 'image_outside_workspace');
      },
    );

    test('missing files degrade to a typed error', () async {
      final missing = p.join(workspace.path, 'missing.png');
      final plan = await ToolImagePlan.build(
        messages: [
          {
            'role': 'tool',
            'name': 'file_view_image',
            'tool_call_id': 'call_1',
            'content': '[image:$missing]',
          },
        ],
        policy: policyFor(workspace),
        target: ToolImageTarget.claude,
        canImageInput: true,
      );

      expect(plan.totalImages, 0);
      expect(plan.errors.single.code, 'image_not_found');
    });

    test('accepts a matching snapshot hash', () async {
      final digest = sha256.convert(await File(imagePath).readAsBytes());
      final plan = await ToolImagePlan.build(
        messages: [
          {
            'role': 'tool',
            'name': 'file_view_image',
            'tool_call_id': 'call_1',
            'content': '[image:$imagePath]',
            '_tool_image_sha256': digest.toString(),
          },
        ],
        policy: policyFor(workspace),
        target: ToolImageTarget.claude,
        canImageInput: true,
      );

      expect(plan.totalImages, 1);
    });

    test('trusted-path ledger allows a live approved image', () async {
      final outside = await Directory.systemTemp.createTemp(
        'omnichat_tool_img_ledger',
      );
      addTearDown(() => outside.delete(recursive: true));
      final outsideImage = p.join(outside.path, 'ledger.png');
      await File(outsideImage).writeAsBytes(_pngBytes());
      ToolImageAccessLedger.allow(outsideImage);
      addTearDown(ToolImageAccessLedger.clear);

      final plan = await ToolImagePlan.build(
        messages: [
          {
            'role': 'tool',
            'name': 'file_view_image',
            'tool_call_id': 'call_1',
            'content': '[image:$outsideImage]',
          },
        ],
        policy: ToolImagePolicy(workspaceRoot: workspace.path)
            .resolve(trustedPaths: ToolImageAccessLedger.snapshot()),
        target: ToolImageTarget.claude,
        canImageInput: true,
      );

      expect(plan.totalImages, 1);
    });

    test(
      'marker removal preserves unrelated whitespace and JSON text',
      () async {
        final goodPath = p.join(workspace.path, 'good.png');
        await File(goodPath).writeAsBytes(_pngBytes());
        const body = '{"text":"line1\\n\\n\\nline2  \\n"}';
        final plan = await ToolImagePlan.build(
          messages: [
            {
              'role': 'tool',
              'name': 'mcp_tool',
              'tool_call_id': 'call_1',
              'content': '[image:$goodPath]\n$body',
            },
          ],
          policy: policyFor(workspace),
          target: ToolImageTarget.claude,
          canImageInput: true,
        );

        final clean = plan.byMessageIndex[0]!.cleanText;
        expect(clean, contains(body));
        expect(clean, isNot(contains('[image:')));
      },
    );

    test('a failed duplicate marker is not silently removed', () async {
      final badPath = imagePath;
      final goodPath = p.join(workspace.path, 'good.png');
      await File(goodPath).writeAsBytes(_pngBytes());
      final badKey = Platform.isWindows
          ? p.normalize(badPath).replaceAll('\\', '/').toLowerCase()
          : p.normalize(badPath).replaceAll('\\', '/');
      final content = '[image:$badPath]\n[image:$badPath]\n[image:$goodPath]';

      final plan = await ToolImagePlan.build(
        messages: [
          {
            'role': 'tool',
            'name': 'file_view_image',
            'tool_call_id': 'call_1',
            'content': content,
            // Only the first path is hash-rejected; the second path succeeds.
            '_tool_image_sha256': <String, String>{badKey: 'wrong-hash'},
          },
        ],
        policy: policyFor(workspace),
        target: ToolImageTarget.claude,
        canImageInput: true,
      );

      expect(plan.totalImages, 1);
      final clean = plan.byMessageIndex[0]!.cleanText;
      // The failed duplicate markers stay; only the good marker is removed.
      expect(RegExp(r'\[image:').allMatches(clean).length, 2);
      expect(RegExp(r'\[image:').allMatches(content).length, 3);
    });

    test('rejects a symlink that escapes the workspace', () async {
      final outside = await Directory.systemTemp.createTemp(
        'omnichat_tool_img_symlink',
      );
      addTearDown(() => outside.delete(recursive: true));
      final outsideImage = p.join(outside.path, 'outside.png');
      await File(outsideImage).writeAsBytes(_pngBytes());
      final linkPath = p.join(workspace.path, 'link.png');
      try {
        await Link(linkPath).create(outsideImage);
      } catch (_) {
        // Creating symlinks may require Developer Mode/admin on Windows.
        return;
      }

      final plan = await ToolImagePlan.build(
        messages: [
          {
            'role': 'tool',
            'name': 'file_view_image',
            'tool_call_id': 'call_1',
            'content': '[image:$linkPath]',
          },
        ],
        policy: policyFor(workspace),
        target: ToolImageTarget.claude,
        canImageInput: true,
      );

      expect(plan.totalImages, 0);
      expect(plan.errors.single.code, 'image_outside_workspace');
    });

    test('rejects a changed file when a snapshot hash is present', () async {
      final plan = await ToolImagePlan.build(
        messages: [
          {
            'role': 'tool',
            'name': 'file_view_image',
            'tool_call_id': 'call_1',
            'content': '[image:$imagePath]',
            '_tool_image_sha256': 'not-the-real-hash',
          },
        ],
        policy: policyFor(workspace),
        target: ToolImageTarget.claude,
        canImageInput: true,
      );

      expect(plan.totalImages, 0);
      expect(plan.errors.single.code, 'image_changed');
    });

    test('Chat Completions only attaches the final tool group', () async {
      final plan = await ToolImagePlan.build(
        messages: [
          {'role': 'user', 'content': 'inspect this'},
          {
            'role': 'tool',
            'name': 'file_view_image',
            'tool_call_id': 'old',
            'content': '[image:$imagePath]',
          },
          {'role': 'user', 'content': 'and this'},
          {
            'role': 'tool',
            'name': 'file_view_image',
            'tool_call_id': 'new',
            'content': '[image:$imagePath]',
          },
        ],
        policy: policyFor(workspace),
        target: ToolImageTarget.openAiChat,
        canImageInput: true,
      );

      expect(plan.totalImages, 1);
      expect(plan.tailUserImages, hasLength(1));
      expect(plan.byMessageIndex, isEmpty);
    });

    test(
      'Chat Completions does nothing when the last message is not a tool',
      () async {
        final plan = await ToolImagePlan.build(
          messages: [
            {
              'role': 'tool',
              'name': 'file_view_image',
              'tool_call_id': 'old',
              'content': '[image:$imagePath]',
            },
            {'role': 'user', 'content': 'follow-up'},
          ],
          policy: policyFor(workspace),
          target: ToolImageTarget.openAiChat,
          canImageInput: true,
        );

        expect(plan.totalImages, 0);
        expect(plan.tailUserImages, isEmpty);
      },
    );

    test('non-vision models report modelUnsupported status', () async {
      final plan = await ToolImagePlan.build(
        messages: [
          {
            'role': 'tool',
            'name': 'file_view_image',
            'tool_call_id': 'call_1',
            'content': '[image:$imagePath]',
          },
        ],
        policy: policyFor(workspace),
        target: ToolImageTarget.claude,
        canImageInput: false,
      );

      expect(plan.isEmpty, isTrue);
      expect(
        plan.statusesByToolCallId['call_1']?.state,
        ToolImageSendState.modelUnsupported,
      );
    });

    test(
      'disabled policy reports settingOff without reading the file',
      () async {
        final plan = await ToolImagePlan.build(
          messages: [
            {
              'role': 'tool',
              'name': 'file_view_image',
              'tool_call_id': 'call_off',
              'content': '[image:$imagePath]',
            },
          ],
          policy: ToolImagePolicy(
            workspaceRoot: workspace.path,
            enabled: false,
          ).resolve(),
          target: ToolImageTarget.claude,
          canImageInput: true,
        );

        expect(plan.totalImages, 0);
        expect(
          plan.statusesByToolCallId['call_off']?.state,
          ToolImageSendState.settingOff,
        );
      },
    );

    test('skipped() reports transportUnsupported for marker-bearing tools', () {
      final plan = ToolImagePlan.skipped(
        messages: [
          {
            'role': 'tool',
            'tool_call_id': 'call_transport',
            'content': '[image:$imagePath]',
          },
        ],
        state: ToolImageSendState.transportUnsupported,
      );

      expect(
        plan.statusesByToolCallId['call_transport']?.state,
        ToolImageSendState.transportUnsupported,
      );
    });

    test('status distinguishes attached images from missing files', () async {
      final attached = await ToolImagePlan.build(
        messages: [
          {
            'role': 'tool',
            'tool_call_id': 'call_attached',
            'content': '[image:$imagePath]',
          },
        ],
        policy: policyFor(workspace),
        target: ToolImageTarget.claude,
        canImageInput: true,
      );
      expect(
        attached.statusesByToolCallId['call_attached']?.state,
        ToolImageSendState.attached,
      );

      final missing = await ToolImagePlan.build(
        messages: [
          {
            'role': 'tool',
            'tool_call_id': 'call_missing',
            'content': '[image:${p.join(workspace.path, 'nope.png')}]',
          },
        ],
        policy: policyFor(workspace),
        target: ToolImageTarget.claude,
        canImageInput: true,
      );
      expect(
        missing.statusesByToolCallId['call_missing']?.state,
        ToolImageSendState.notFound,
      );
    });

    test('policy remembers a provider rejection for the run', () {
      final policy = ToolImagePolicy(workspaceRoot: workspace.path);
      expect(policy.providerRejectedThisRun, isFalse);
      policy.markProviderRejected();
      expect(policy.providerRejectedThisRun, isTrue);
    });

    test('skipped statuses are capped for long histories', () {
      final plan = ToolImagePlan.skipped(
        messages: [
          for (var i = 0; i < 40; i++)
            {
              'role': 'tool',
              'tool_call_id': 'call_$i',
              'content': '[image:/tmp/$i.png]',
            },
        ],
        state: ToolImageSendState.settingOff,
      );

      expect(plan.statusesByToolCallId.length, ToolImagePlan.maxStatusMessages);
    });

    test('marks older tool images when the per-request cap is hit', () async {
      final messages = <Map<String, dynamic>>[];
      for (var i = 0; i < 9; i++) {
        final path = p.join(workspace.path, 'cap_$i.png');
        await File(path).writeAsBytes(_pngBytes());
        messages.add({
          'role': 'tool',
          'tool_call_id': 'call_$i',
          'content': '[image:$path]',
        });
      }

      final plan = await ToolImagePlan.build(
        messages: messages,
        policy: policyFor(workspace),
        target: ToolImageTarget.claude,
        canImageInput: true,
      );

      expect(plan.totalImages, 8);
      expect(
        plan.statusesByToolCallId['call_0']?.state,
        ToolImageSendState.limitReached,
      );
      expect(
        plan.statusesByToolCallId['call_8']?.state,
        ToolImageSendState.attached,
      );
    });

    test('image fallback only retries an image-bearing non-overflow 400', () {
      expect(
        shouldRetryToolImagesWithoutImages(
          statusCode: 400,
          isContextOverflow: false,
          alreadyTried: false,
          yieldedAnything: false,
          receivedReasoning: false,
          attachedImageCount: 1,
        ),
        isTrue,
      );
      expect(
        shouldRetryToolImagesWithoutImages(
          statusCode: 400,
          isContextOverflow: true,
          alreadyTried: false,
          yieldedAnything: false,
          receivedReasoning: false,
          attachedImageCount: 1,
        ),
        isFalse,
      );
      expect(
        shouldRetryToolImagesWithoutImages(
          statusCode: 400,
          isContextOverflow: false,
          alreadyTried: true,
          yieldedAnything: false,
          receivedReasoning: false,
          attachedImageCount: 1,
        ),
        isFalse,
      );
      expect(
        shouldRetryToolImagesWithoutImages(
          statusCode: 400,
          isContextOverflow: false,
          alreadyTried: false,
          yieldedAnything: true,
          receivedReasoning: false,
          attachedImageCount: 1,
        ),
        isFalse,
      );
      expect(
        shouldRetryToolImagesWithoutImages(
          statusCode: 400,
          isContextOverflow: false,
          alreadyTried: false,
          yieldedAnything: false,
          receivedReasoning: true,
          attachedImageCount: 1,
        ),
        isFalse,
      );
    });
  });

  group('tool image codec', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('omnichat_codec');
    });

    tearDown(() async {
      await dir.delete(recursive: true);
    });

    test(
      'downscales to the Claude long-edge limit and re-encodes JPEG',
      () async {
        final path = p.join(dir.path, 'large.png');
        final image = img.Image(width: 3000, height: 1000, numChannels: 3);
        img.fill(image, color: img.ColorRgb8(20, 40, 60));
        await File(path).writeAsBytes(img.encodePng(image));

        final encoded = await const ToolImageCodec().normalize(
          path: path,
          target: ToolImageTarget.claude,
        );

        expect(encoded.width, lessThanOrEqualTo(1568));
        expect(encoded.height, lessThanOrEqualTo(1568));
        expect(encoded.mime, 'image/jpeg');
        expect(encoded.bytes, isNotEmpty);
      },
    );

    test('keeps alpha images as PNG', () async {
      final path = p.join(dir.path, 'alpha.png');
      final image = img.Image(width: 32, height: 32, numChannels: 4);
      img.fill(image, color: img.ColorRgba8(10, 20, 30, 128));
      await File(path).writeAsBytes(img.encodePng(image));

      final encoded = await const ToolImageCodec().normalize(
        path: path,
        target: ToolImageTarget.responses,
      );

      expect(encoded.mime, 'image/png');
    });

    test('rejects corrupt bytes', () async {
      final path = p.join(dir.path, 'corrupt.png');
      await File(path).writeAsBytes(<int>[1, 2, 3, 4, 5]);

      expect(
        () => const ToolImageCodec().normalize(
          path: path,
          target: ToolImageTarget.claude,
        ),
        throwsA(
          isA<ToolImageCodecException>().having(
            (e) => e.code,
            'code',
            'image_unsupported_format',
          ),
        ),
      );
    });

    test('rejects files over the raw budget', () async {
      final path = p.join(dir.path, 'big.png');
      await File(path).writeAsBytes(List<int>.filled(128, 0));

      expect(
        () => const ToolImageCodec().normalize(
          path: path,
          target: ToolImageTarget.claude,
          maxRawBytes: 64,
        ),
        throwsA(
          isA<ToolImageCodecException>().having(
            (e) => e.code,
            'code',
            'image_too_large',
          ),
        ),
      );
    });
  });
}

List<int> _pngBytes() {
  final image = img.Image(width: 24, height: 16, numChannels: 3);
  img.fill(image, color: img.ColorRgb8(200, 30, 40));
  return img.encodePng(image);
}
