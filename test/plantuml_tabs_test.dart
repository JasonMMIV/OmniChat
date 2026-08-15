import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/l10n/app_localizations.dart';
import 'package:OmniChat/shared/widgets/markdown_with_highlight.dart';

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

/// Returns a valid tiny SVG for every request so [SvgPicture.network] can
/// finish loading under flutter test (which otherwise serves HTTP 400).
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
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _FakeSvgRequest();

  @override
  Future<HttpClientRequest> get(String host, int port, String path) async =>
      _FakeSvgRequest();

  @override
  Future<HttpClientRequest> open(
    String method,
    String host,
    int port,
    String path,
  ) async =>
      _FakeSvgRequest();
}

class _FakeSvgRequest implements HttpClientRequest {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;

  @override
  Future<dynamic> addStream(Stream<List<int>> stream) async {}

  @override
  Future<HttpClientResponse> close() async => _FakeSvgResponse();
}

class _FakeSvgResponse extends Stream<List<int>>
    implements HttpClientResponse {
  static final Uint8List _bytes = utf8.encode(_svg);
  static const _svg =
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
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream<List<int>>.value(_bytes).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
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
