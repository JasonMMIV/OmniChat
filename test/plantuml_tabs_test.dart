import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/web/ssrf_guard.dart';
import 'package:OmniChat/icons/lucide_adapter.dart';
import 'package:OmniChat/l10n/app_localizations.dart';
import 'package:OmniChat/shared/widgets/markdown_with_highlight.dart';
import 'package:OmniChat/shared/widgets/plantuml_block.dart';
import 'package:OmniChat/shared/widgets/safe_svg_image.dart';

Future<SettingsProvider> _loadedProvider() async {
  final sp = SettingsProvider();
  final done = Completer<void>();
  void listener() {
    if (!done.isCompleted) done.complete();
  }

  sp.addListener(listener);
  await done.future.timeout(const Duration(seconds: 10));
  sp.removeListener(listener);
  return sp;
}

Future<void> _pumpMd(WidgetTester tester, SettingsProvider sp, String text) async {
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: sp,
      child: MaterialApp(
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(body: MarkdownWithCodeHighlight(text: text)),
      ),
    ),
  );
  await tester.pump();
}

const _puml = '@startuml\nAlice -> Bob: hello\n@enduml';

class _FakeSvgHttpBaseClient extends http.BaseClient {
  _FakeSvgHttpBaseClient({
    this.statusCode = HttpStatus.ok,
    this.body = _FakeSvgResponse.svg,
    this.contentType = 'image/svg+xml',
    this.contentLength,
  });

  final int statusCode;
  final String body;
  final String contentType;
  final int? contentLength;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final bytes = utf8.encode(body);
    final length = contentLength ?? bytes.length;
    return http.StreamedResponse(
      Stream<List<int>>.value(bytes),
      statusCode,
      contentLength: length,
      headers: <String, String>{'content-type': contentType, 'content-length': '$length'},
    );
  }
}

Future<void> _pumpPlantUml(WidgetTester tester, {required String code, required _FakeSvgHttpBaseClient client}) async {
  await tester.pumpWidget(
    MaterialApp(
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: Scaffold(
        body: SingleChildScrollView(
          child: PlantUMLBlock(code: code, guard: SsrfGuard(allowPrivateHosts: true), httpClientFactory: () => client),
        ),
      ),
    ),
  );
  for (var i = 0; i < 20 && find.byIcon(Lucide.ImageOff).evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
}

/// Returns a valid tiny SVG for every request so `SafeSvgImage` can finish
/// loading under flutter test (which otherwise serves HTTP 400).
class _FakeSvgHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => _FakeSvgHttpClient();
}

class _FakeSvgHttpClient implements HttpClient {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _FakeSvgRequest();

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async => _FakeSvgRequest();

  @override
  Future<HttpClientRequest> get(String host, int port, String path) async => _FakeSvgRequest();

  @override
  Future<HttpClientRequest> open(String method, String host, int port, String path) async => _FakeSvgRequest();
}

class _FakeSvgRequest implements HttpClientRequest {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;

  @override
  Future<dynamic> addStream(Stream<List<int>> stream) async {}

  @override
  Future<HttpClientResponse> close() async => _FakeSvgResponse();
}

class _FakeSvgResponse extends Stream<List<int>> implements HttpClientResponse {
  static final Uint8List _bytes = utf8.encode(svg);
  static const svg =
      '<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">'
      '<rect width="100" height="100" fill="red"/></svg>';

  @override
  dynamic noSuchMethod(Invocation invocation) => null;

  @override
  final HttpHeaders headers = _FakeHttpHeaders();

  @override
  int get statusCode => HttpStatus.ok;

  @override
  int get contentLength => _bytes.length;

  @override
  bool get isRedirect => false;

  @override
  List<RedirectInfo> get redirects => const [];

  @override
  bool get persistentConnection => false;

  @override
  String get reasonPhrase => 'OK';

  @override
  HttpClientResponseCompressionState get compressionState => HttpClientResponseCompressionState.notCompressed;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream<List<int>>.value(
      _bytes,
    ).listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }
}

class _FakeHttpHeaders implements HttpHeaders {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;

  @override
  void forEach(void Function(String name, List<String> values) action) {}
}

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    HttpOverrides.global = _FakeSvgHttpOverrides();
  });

  tearDown(() {
    HttpOverrides.global = null;
  });

  testWidgets('renders image/code tabs and header actions', (tester) async {
    final sp = await _loadedProvider();
    await _pumpMd(tester, sp, '```plantuml\n$_puml\n```');

    // Tabs (en locale).
    expect(find.text('Image'), findsOneWidget);
    expect(find.text('Code'), findsOneWidget);
    // Header actions: copy label + download button.
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Download'), findsOneWidget);
    // Image view is the default tab.
    expect(find.byKey(const ValueKey('plantuml-image-body')), findsOneWidget);
    expect(find.byType(SafeSvgImage), findsOneWidget);
    expect(find.byKey(const ValueKey('plantuml-code-body')), findsNothing);
  });

  testWidgets('code tab switches to the source view', (tester) async {
    final sp = await _loadedProvider();
    await _pumpMd(tester, sp, '```plantuml\n$_puml\n```');

    await tester.tap(find.text('Code'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('plantuml-code-body')), findsOneWidget);
    expect(find.textContaining('Alice -> Bob'), findsOneWidget);
  });

  testWidgets('shows the error view for a 404 response', (tester) async {
    await _pumpPlantUml(
      tester,
      code: '${_puml}404',
      client: _FakeSvgHttpBaseClient(statusCode: HttpStatus.notFound),
    );

    expect(tester.takeException(), isNull);
    expect(find.byIcon(Lucide.ImageOff), findsOneWidget);
  });

  testWidgets('shows the error view for an oversized SVG', (tester) async {
    await _pumpPlantUml(
      tester,
      code: '${_puml}oversized',
      client: _FakeSvgHttpBaseClient(body: '<svg/>', contentLength: 2 * 1024 * 1024 + 1),
    );

    expect(tester.takeException(), isNull);
    expect(find.byIcon(Lucide.ImageOff), findsOneWidget);
  });

  testWidgets('shows the error view for a non-SVG response', (tester) async {
    await _pumpPlantUml(
      tester,
      code: '${_puml}html',
      client: _FakeSvgHttpBaseClient(body: '<html>not an svg</html>', contentType: 'text/html'),
    );

    expect(tester.takeException(), isNull);
    expect(find.byIcon(Lucide.ImageOff), findsOneWidget);
  });

  testWidgets('collapsing hides the preview body', (tester) async {
    final sp = await _loadedProvider();
    await _pumpMd(tester, sp, '```plantuml\n$_puml\n```');

    expect(find.byKey(const ValueKey('plantuml-expanded')), findsOneWidget);

    // Tap the collapse chevron (the single AnimatedRotation in the header).
    await tester.tap(find.byType(AnimatedRotation));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('plantuml-collapsed')), findsOneWidget);
  });
}
