// Build the bundled OpenCode catalog overlay.
//
//   dart run tool/build_opencode_catalog.dart
//
// Downloads https://models.opencode.ai/api.json (a models.dev-compatible
// payload), prunes it with the same rules as the runtime path, keeps only the
// `opencode` / `opencode-go` providers, and writes:
//   assets/model_catalog/opencode.json
//
// The overlay is merged over the models.dev snapshot at runtime so OpenCode's
// Console/Zen/Go models win without replacing the global catalog.
import 'dart:convert';
import 'dart:io';

import 'package:OmniChat/core/services/model_catalog/model_catalog.dart'
    show ensureCatalogProviderAlias, filterCatalogProviders, pruneCatalogJson;

const String _sourceUrl = 'https://models.opencode.ai/api.json';
const String _defaultOutput = 'assets/model_catalog/opencode.json';
const String _defaultNotice = 'assets/model_catalog/opencode.NOTICE.md';
const Set<String> _providers = <String>{'opencode', 'opencode-go'};

Future<void> main(List<String> args) async {
  final outputPath = args.isNotEmpty ? args[0] : _defaultOutput;
  final noticePath = args.length > 1 ? args[1] : _defaultNotice;

  stdout.writeln('Fetching $_sourceUrl ...');
  final client = HttpClient();
  final String body;
  try {
    final request = await client.getUrl(Uri.parse(_sourceUrl));
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final response = await request.close();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      stderr.writeln('HTTP ${response.statusCode}');
      exitCode = 1;
      return;
    }
    body = await response.transform(utf8.decoder).join();
  } finally {
    client.close(force: true);
  }

  final String overlay;
  try {
    overlay = ensureCatalogProviderAlias(
      filterCatalogProviders(pruneCatalogJson(body), _providers),
      alias: 'opencode',
      source: 'opencode-go',
    );
  } on FormatException {
    stderr.writeln('Unexpected payload: expected a provider map.');
    exitCode = 1;
    return;
  }

  final dynamic decoded = jsonDecode(overlay);
  if (decoded is! Map || decoded.isEmpty) {
    stderr.writeln('No OpenCode providers found.');
    exitCode = 1;
    return;
  }
  final modelCount = decoded.values.fold<int>(0, (sum, provider) {
    if (provider is! Map) return sum;
    final models = provider['models'];
    return sum + (models is Map ? models.length : 0);
  });

  final file = File(outputPath);
  await file.parent.create(recursive: true);
  await file.writeAsString(overlay, flush: true);

  final now = DateTime.now().toUtc();
  final date = now.toIso8601String().split('T').first;
  await File(noticePath).writeAsString(_notice(date), flush: true);

  final bytes = await file.length();
  stdout.writeln(
    'Wrote $outputPath: ${decoded.length} providers, $modelCount models, '
    '${(bytes / 1024).toStringAsFixed(0)} KB',
  );
  stdout.writeln('Wrote $noticePath (extracted $date)');
}String _notice(String date) => '''# OpenCode catalog overlay snapshot

- Source: $_sourceUrl
- Extracted: $date
- License: see the upstream source's terms
- Generator: `dart run tool/build_opencode_catalog.dart`

This directory contains a pruned copy of the OpenCode catalog used as an
overlay on top of the models.dev snapshot. Only the `opencode` and
`opencode-go` provider entries are kept; the runtime merge lets OpenCode's
Console/Zen/Go models win over models.dev while retaining models.dev-only
entries.

The snapshot is a build artifact. Do not edit `opencode.json` by hand — rerun
the generator instead. The app refresh path downloads the same upstream file
at runtime and prunes/filters it with the same rules.
''';
