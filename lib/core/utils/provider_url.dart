/// Pure URL helpers for the provider editor's request preview and for
/// connection tests. The wire builders keep their existing call sites; this
/// function mirrors their shape so the preview and the test URL stay honest.
library;

class ProviderRequestUrl {
  const ProviderRequestUrl({required this.url, this.addedVersion});

  final String url;

  /// Non-null when [resolveProviderRequestUrl] appended the provider's API
  /// version because the base URL had no version segment.
  final String? addedVersion;
}

String providerApiVersion(String providerType) {
  return providerType.trim().toLowerCase() == 'google' ? 'v1beta' : 'v1';
}

/// Removes a pasted endpoint suffix and trailing slashes. A base URL is the
/// prefix the transport appends its path to; keeping `/chat/completions` there
/// produces `/chat/completions/chat/completions`.
String normalizeProviderBaseUrl(String raw) {
  var value = raw.trim();
  if (value.isEmpty) return value;
  var lower = value.toLowerCase();
  const suffixes = <String>[
    '/chat/completions',
    '/responses',
    '/messages',
    ':streamgeneratecontent',
    ':generatecontent',
  ];
  var changed = true;
  while (changed) {
    changed = false;
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
      lower = value.toLowerCase();
      changed = true;
    }
    for (final suffix in suffixes) {
      if (lower.endsWith(suffix)) {
        value = value.substring(0, value.length - suffix.length);
        lower = value.toLowerCase();
        changed = true;
      }
    }
  }
  return value;
}

bool hasProviderApiVersion(String baseUrl) {
  final uri = Uri.tryParse(baseUrl);
  final path = uri?.path ?? baseUrl;
  return RegExp(
    r'(^|/)v\d+(?:beta|alpha)?(?:/|$)',
    caseSensitive: false,
  ).hasMatch(path);
}

/// Appends `/v1` (or `/v1beta` for Google) when the base URL has no version
/// segment. Known endpoint suffixes are stripped first.
ProviderRequestUrl ensureProviderApiVersion(
  String raw, {
  required String providerType,
}) {
  final base = normalizeProviderBaseUrl(raw);
  if (base.isEmpty) {
    return const ProviderRequestUrl(url: '');
  }
  if (hasProviderApiVersion(base)) {
    return ProviderRequestUrl(url: base);
  }
  final version = providerApiVersion(providerType);
  final uri = Uri.tryParse(base);
  if (uri == null) {
    return ProviderRequestUrl(url: '$base/$version', addedVersion: version);
  }
  final path = uri.path.endsWith('/') ? uri.path : '${uri.path}/';
  final next = uri.replace(path: '$path$version');
  return ProviderRequestUrl(url: next.toString(), addedVersion: version);
}

/// Resolves the exact endpoint a chat/test request will hit.
///
/// [providerType] is a `ProviderKind.name` value (`openai`, `claude`,
/// `google`, `neuralwatt`, ...). [modelId] should be the upstream/API model id
/// when an override maps it.
ProviderRequestUrl resolveProviderRequestUrl({
  required String baseUrl,
  required String providerType,
  required String modelId,
  String? chatPath,
  bool useResponses = false,
  bool vertexAI = false,
  String? location,
  String? projectId,
  bool isStream = false,
}) {
  final kind = providerType.trim().toLowerCase();
  final id = modelId.trim();
  if (kind == 'google') {
    if (vertexAI &&
        (location ?? '').trim().isNotEmpty &&
        (projectId ?? '').trim().isNotEmpty) {
      final endpoint = isStream ? 'streamGenerateContent' : 'generateContent';
      final url =
          'https://aiplatform.googleapis.com/v1/projects/${projectId!.trim()}'
          '/locations/${location!.trim()}/publishers/google/models/$id:$endpoint';
      return ProviderRequestUrl(url: isStream ? '$url?alt=sse' : url);
    }
    final base = normalizeProviderBaseUrl(baseUrl);
    final path =
        '/models/$id:${isStream ? 'streamGenerateContent' : 'generateContent'}';
    return ProviderRequestUrl(
      url: _appendPath(
        base,
        path,
        query: isStream ? const {'alt': 'sse'} : null,
      ),
    );
  }

  final base = normalizeProviderBaseUrl(baseUrl);
  if (kind == 'claude') {
    return ProviderRequestUrl(url: _appendPath(base, '/messages'));
  }
  final path = useResponses
      ? '/responses'
      : (chatPath == null ? '/chat/completions' : chatPath.trim());
  // An explicitly empty chatPath means the base URL is the endpoint
  // (legacy behaviour); null means the OpenAI default.
  if (path.isEmpty) return ProviderRequestUrl(url: base);
  return ProviderRequestUrl(url: _appendPath(base, path));
}

/// Appends [relative] without letting a query string on [base] swallow the
/// path (`https://host/gemini?key=x` + `/models/...`).
String _appendPath(String base, String relative, {Map<String, String>? query}) {
  final cleanBase = base.endsWith('/')
      ? base.substring(0, base.length - 1)
      : base;
  final rel = relative.startsWith('/') ? relative.substring(1) : relative;
  final uri = Uri.tryParse(cleanBase);
  if (uri != null && (uri.hasQuery || uri.hasFragment)) {
    final prefix = uri.path.isEmpty
        ? ''
        : (uri.path.endsWith('/') ? uri.path : '${uri.path}/');
    final merged = <String, String>{...uri.queryParameters, ...?query};
    return uri
        .replace(
          path: '$prefix$rel',
          queryParameters: merged.isEmpty ? null : merged,
        )
        .toString();
  }
  final queryString = query == null || query.isEmpty
      ? ''
      : '?${Uri(queryParameters: query).query}';
  return '$cleanBase/$rel$queryString';
}
