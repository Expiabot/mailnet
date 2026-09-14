import 'dart:io';

// enough_mail ships its own MailAccount; ours is the one this app means.
import 'package:enough_mail/enough_mail.dart' hide MailAccount;

import 'imap_gateway.dart';
import 'models.dart';
import 'unsubscribe.dart';

/// The real IMAP connection, on top of `enough_mail`.
///
/// This is the only file that knows about `enough_mail`, and the only one that
/// decides whether a failure is a dead connection or a refused command — the
/// distinction the retry logic in [MailService] depends on.
class EnoughMailGateway implements ImapGateway {
  ImapClient? _client;

  @override
  bool get isConnected => _client?.isLoggedIn ?? false;

  @override
  Future<void> connect(MailAccount account, MailCredentials credentials) async {
    final client = ImapClient(isLogEnabled: false);
    try {
      await client.connectToServer(account.host, account.port, isSecure: true);
      switch (credentials) {
        case PasswordCredentials(:final password):
          await client.login(account.user, password);
        case OAuthCredentials(:final accessToken):
          await client.authenticateWithOAuth2(account.user, accessToken);
      }
      _client = client;
    } catch (e) {
      try {
        await client.disconnect();
      } catch (_) {
        // already gone
      }
      _client = null;
      throw _classify(e);
    }
  }

  @override
  Future<void> disconnect() async {
    final client = _client;
    _client = null;
    if (client == null) return;
    try {
      await client.logout();
    } catch (_) {
      // The socket may already be gone; nothing useful to do about it.
    }
  }

  @override
  Future<List<MailFolder>> listFolders() => _guard(() async {
        final boxes = await _require().listMailboxes(recursive: true);
        return boxes
            .where((b) => b.path.isNotEmpty && !b.isNotSelectable)
            .map(
              (b) => MailFolder(
                path: b.path,
                name: b.name.isNotEmpty ? b.name : b.path,
                isTrash: b.isTrash,
                isSent: b.isSent,
                isDrafts: b.isDrafts,
                isJunk: b.isJunk,
                isInbox: b.isInbox,
              ),
            )
            .toList();
      });

  @override
  Future<void> selectFolder(String path) =>
      _guard(() => _require().selectMailboxByPath(path));

  @override
  Future<List<int>> searchUids(String criteria) => _guard(() async {
        final result =
            await _require().uidSearchMessages(searchCriteria: criteria);
        final ids = result.matchingSequence?.toList() ?? const <int>[];
        return [...ids]..sort();
      });

  @override
  Future<List<MessageSummary>> fetchSummaries(List<int> uids) => _guard(() async {
        if (uids.isEmpty) return const <MessageSummary>[];
        final result = await _require().uidFetchMessages(
          MessageSequence.fromIds(uids, isUid: true),
          // PEEK so scanning never marks anything as read.
          '(UID ENVELOPE RFC822.SIZE BODY.PEEK[HEADER.FIELDS '
              '(LIST-UNSUBSCRIBE LIST-UNSUBSCRIBE-POST)])',
        );
        return result.messages.map(_toSummary).toList();
      });

  @override
  Future<void> moveUids(List<int> uids, String targetPath) => _guard(
        () => _require().uidMove(
          MessageSequence.fromIds(uids, isUid: true),
          targetMailboxPath: targetPath,
        ),
      );

  @override
  Future<void> deleteUids(List<int> uids) => _guard(() async {
        final client = _require();
        final sequence = MessageSequence.fromIds(uids, isUid: true);
        await client.uidMarkDeleted(sequence);
        await client.expunge();
      });

  @override
  Future<void> noop() => _guard(() => _require().noop());

  // ---------------------------------------------------------------------

  ImapClient _require() {
    final client = _client;
    if (client == null) {
      throw const MailConnectionException('Aucune connexion IMAP ouverte.');
    }
    return client;
  }

  Future<T> _guard<T>(Future<T> Function() op) async {
    try {
      return await op();
    } catch (e) {
      throw _classify(e);
    }
  }

  static MessageSummary _toSummary(MimeMessage m) {
    final envelope = m.envelope;
    final from = (envelope?.from?.isNotEmpty ?? false) ? envelope!.from!.first : null;
    return MessageSummary(
      uid: m.uid ?? 0,
      date: envelope?.date,
      fromName: from?.personalName ?? '',
      fromAddress: from?.email ?? '',
      subject: envelope?.subject ?? '(sans objet)',
      size: m.size ?? 0,
      unsubscribe: UnsubscribeInfo.parse(
        m.getHeaderValue('list-unsubscribe'),
        postHeader: m.getHeaderValue('list-unsubscribe-post'),
      ),
    );
  }

  /// A dead socket must not look like a bad password, and vice versa — the
  /// service retries one and never the other.
  static Object _classify(Object error) {
    if (error is MailConnectionException || error is MailAuthException) {
      return error;
    }
    if (error is SocketException || error is HandshakeException) {
      return MailConnectionException(error.toString());
    }
    if (error is ImapException) {
      final text = error.toString().toLowerCase();
      if (text.contains('authenticationfail') ||
          text.contains('invalid credentials') ||
          text.contains('login failed') ||
          text.contains('authenticate failed')) {
        return MailAuthException(error.toString());
      }
      if (text.contains('socket') ||
          text.contains('closed') ||
          text.contains('not connected') ||
          text.contains('timeout') ||
          text.contains('reset')) {
        return MailConnectionException(error.toString());
      }
    }
    return error;
  }
}
