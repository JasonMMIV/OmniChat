/// Schemes allowed for raw HTML `<a href="...">` links.
///
/// App schemes (including `omnichat:`) are deliberately excluded: a generated
/// `<a href="com.psyche.omnichat://oauth-callback?...">` must not be able to
/// trigger an in-app OAuth callback. `javascript:`, `data:` and `file:` are
/// also rejected.
const Set<String> kAllowedHtmlLinkSchemes = <String>{'http', 'https', 'mailto', 'tel'};

bool isSafeHtmlLink(String url) {
  final trimmed = url.trim();
  if (trimmed.isEmpty) return false;
  final uri = Uri.tryParse(trimmed);
  if (uri == null) return false;
  return kAllowedHtmlLinkSchemes.contains(uri.scheme.toLowerCase());
}
