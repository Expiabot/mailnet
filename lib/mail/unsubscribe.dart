/// What the `List-Unsubscribe` headers offer for a given sender.
///
/// Parsing is kept pure and separate from the network so it can be tested
/// against the real, messy header shapes senders actually send.
class UnsubscribeInfo {
  const UnsubscribeInfo({this.httpUri, this.mailtoUri, this.oneClick = false});

  /// An https endpoint or unsubscribe page.
  final Uri? httpUri;

  /// A `mailto:` address that unsubscribes when written to.
  final Uri? mailtoUri;

  /// RFC 8058: a single POST to [httpUri] unsubscribes, no page to visit and
  /// no form to fill. This is the only path that can be done silently.
  final bool oneClick;

  bool get isEmpty => httpUri == null && mailtoUri == null;

  /// Reads `List-Unsubscribe` (and `List-Unsubscribe-Post` when present).
  ///
  /// The header holds one or more angle-bracketed URIs separated by commas:
  /// `<https://example.com/u/abc>, <mailto:unsub@example.com>`. Returns null
  /// when nothing usable is in there.
  static UnsubscribeInfo? parse(String? header, {String? postHeader}) {
    if (header == null || header.trim().isEmpty) return null;

    Uri? http;
    Uri? mailto;
    for (final match in RegExp(r'<([^>]+)>').allMatches(header)) {
      final raw = match.group(1)?.trim();
      if (raw == null || raw.isEmpty) continue;
      final uri = Uri.tryParse(raw);
      if (uri == null || !uri.hasScheme) continue;
      switch (uri.scheme.toLowerCase()) {
        case 'https':
        case 'http':
          http ??= uri;
        case 'mailto':
          mailto ??= uri;
      }
    }

    if (http == null && mailto == null) return null;

    // RFC 8058 only allows one-click over https — an http endpoint would leak
    // the unsubscribe token in clear text.
    final oneClick = http != null &&
        http.scheme.toLowerCase() == 'https' &&
        (postHeader ?? '').toLowerCase().contains('one-click');

    return UnsubscribeInfo(httpUri: http, mailtoUri: mailto, oneClick: oneClick);
  }
}
