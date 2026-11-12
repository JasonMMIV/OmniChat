import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/services/api/tool_image_send_status.dart';
import 'package:OmniChat/features/chat/widgets/tool_image_send_badge.dart';
import 'package:OmniChat/l10n/app_localizations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('badge renders the localized title and reason tooltip', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ToolImageSendBadge(
            title: 'Image not sent to model',
            reason: 'This model cannot receive images.',
            color: Colors.grey,
          ),
        ),
      ),
    );

    expect(find.text('Image not sent to model'), findsOneWidget);
    final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
    expect(tooltip.message, 'This model cannot receive images.');
  });

  test('reason mapping distinguishes the actionable causes', () async {
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));

    expect(
      toolImageSendReason(l10n, ToolImageSendState.modelUnsupported),
      'This model cannot receive images.',
    );
    expect(
      toolImageSendReason(l10n, ToolImageSendState.settingOff),
      'Tool image sending is off in settings.',
    );
    expect(
      toolImageSendReason(l10n, ToolImageSendState.providerRejected),
      'The provider rejected the image; retried without it.',
    );
    expect(
      toolImageSendReason(l10n, ToolImageSendState.notFound),
      'The image was missing, changed, or could not be read.',
    );
    expect(toolImageSendReason(l10n, ToolImageSendState.attached), isNull);
  });

  test('static fallback only badges known causes', () {
    expect(
      staticToolImageSendState(
        hasImage: false,
        sendToolImages: false,
        modelSupportsImages: false,
      ),
      isNull,
    );
    expect(
      staticToolImageSendState(
        hasImage: true,
        sendToolImages: false,
        modelSupportsImages: true,
      ),
      ToolImageSendState.settingOff,
    );
    expect(
      staticToolImageSendState(
        hasImage: true,
        sendToolImages: true,
        modelSupportsImages: false,
      ),
      ToolImageSendState.modelUnsupported,
    );
    expect(
      staticToolImageSendState(
        hasImage: true,
        sendToolImages: true,
        modelSupportsImages: null,
      ),
      isNull,
    );
    expect(
      staticToolImageSendState(
        hasImage: true,
        sendToolImages: true,
        modelSupportsImages: true,
      ),
      isNull,
    );
  });
}
