// Build the bundled models.dev catalog snapshot.
//
//   dart run tool/build_model_catalog.dart
//
// Downloads https://models.dev/api.json, keeps only the fields OmniChat
// consumes, and writes:
//   assets/model_catalog/models_dev.json   (compact JSON, source of truth)
//   assets/model_catalog/NOTICE.md         (source, date, license)
//
// The snapshot is a build artifact — never edit it by hand. models.dev data
// is MIT licensed (see NOTICE.md).
import 'dart:convert';
import 'dart:io';

import 'package:OmniChat/core/services/model_catalog/model_catalog.dart'
    show pruneCatalogJson;

const String _sourceUrl = 'https://models.dev/api.json';
const String _defaultOutput = 'assets/model_catalog/models_dev.json';
const String _defaultNotice = 'assets/model_catalog/NOTICE.md';

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

  final String pruned;
  try {
    pruned = pruneCatalogJson(body);
  } on FormatException {
    stderr.writeln('Unexpected payload: expected a provider map.');
    exitCode = 1;
    return;
  }

  final dynamic providers = jsonDecode(pruned);
  final providerCount = providers is Map ? providers.length : 0;
  var modelCount = 0;
  if (providers is Map) {
    for (final provider in providers.values) {
      if (provider is! Map) continue;
      final models = provider['models'];
      if (models is Map) modelCount += models.length;
    }
  }

  final file = File(outputPath);
  await file.parent.create(recursive: true);
  await file.writeAsString(pruned, flush: true);

  final now = DateTime.now().toUtc();
  final date = now.toIso8601String().split('T').first;
  await File(noticePath).writeAsString(_notice(date), flush: true);

  final bytes = await file.length();
  stdout.writeln(
    'Wrote $outputPath: $providerCount providers, $modelCount models, '
    '${(bytes / 1024).toStringAsFixed(0)} KB',
  );
  stdout.writeln('Wrote $noticePath (extracted $date)');
}

String _notice(String date) => '''# models.dev catalog snapshot

- Source: $_sourceUrl
- Extracted: $date
- License: MIT (https://github.com/sst/models.dev/blob/dev/LICENSE)
- Generator: `dart run tool/build_model_catalog.dart`

This directory contains a pruned copy of the models.dev catalog used as the
default data layer for context windows and model capabilities (model catalog
plan, batch 1). Only the fields OmniChat consumes are kept; names,
descriptions, families, pricing and release metadata are discarded.

The snapshot is a build artifact. Do not edit `models_dev.json` by hand — rerun
the generator instead. The app refresh path downloads the same upstream file
at runtime and prunes it with the same rules.
''';
