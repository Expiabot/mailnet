import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'unsubscribe.dart';

enum UnsubscribeOutcome {
  /// RFC 8058 one-click: the sender confirmed, nothing else to do.
  done,

  /// The sender's page or mail client was opened; the user finishes there.
  opened,

  failed,
}

/// Carries out an unsubscribe.
///
/// Split from [UnsubscribeInfo] so the parsing stays pure and testable while
/// the network and the platform live here.
class UnsubscribeAction {
  const UnsubscribeAction({this.client, this.launcher});

  /// Injectable for tests; a fresh client is created per call otherwise.
  final http.Client? client;

  /// Injectable for tests; defaults to opening in the browser or mail client.
  final Future<bool> Function(Uri uri)? launcher;

  Future<UnsubscribeOutcome> run(UnsubscribeInfo info) async {
    final oneClickUri = info.httpUri;
    if (info.oneClick && oneClickUri != null) {
      if (await _postOneClick(oneClickUri)) return UnsubscribeOutcome.done;
      // The endpoint refused the POST; the page is still worth offering.
    }

    // Prefer the web page: a mailto needs an outgoing mail account, which is a
    // different thing from the IMAP access MailNet has.
    for (final uri in [info.httpUri, info.mailtoUri]) {
      if (uri == null) continue;
      if (await _open(uri)) return UnsubscribeOutcome.opened;
    }
    return UnsubscribeOutcome.failed;
  }

  Future<bool> _postOneClick(Uri uri) async {
    final httpClient = client ?? http.Client();
    try {
      final response = await httpClient
          .post(
            uri,
            headers: const {
              'Content-Type': 'application/x-www-form-urlencoded',
            },
            body: 'List-Unsubscribe=One-Click',
          )
          .timeout(const Duration(seconds: 15));
      return response.statusCode >= 200 && response.statusCode < 400;
    } catch (e) {
      debugPrint('[mailnet] désabonnement one-click échoué: $e');
      return false;
    } finally {
      if (client == null) httpClient.close();
    }
  }

  Future<bool> _open(Uri uri) async {
    try {
      final open = launcher ??
          (Uri u) => launchUrl(u, mode: LaunchMode.externalApplication);
      return await open(uri);
    } catch (e) {
      debugPrint('[mailnet] ouverture du lien de désabonnement échouée: $e');
      return false;
    }
  }
}
