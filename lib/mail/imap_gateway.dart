import 'models.dart';

/// The IMAP operations MailNet needs, and nothing more.
///
/// [MailService] talks only to this, so the deletion logic can be tested
/// without a network, a mailbox, or a phone. The real implementation lives in
/// `enough_mail_gateway.dart`; it is also the only place that decides what
/// counts as a [MailConnectionException].
abstract class ImapGateway {
  bool get isConnected;

  Future<void> connect(MailAccount account, MailCredentials credentials);

  /// Closes the connection. Must not throw — it is called on paths that are
  /// already handling a failure.
  Future<void> disconnect();

  Future<List<MailFolder>> listFolders();

  Future<void> selectFolder(String path);

  /// UIDs matching an IMAP SEARCH argument, ascending (oldest first).
  Future<List<int>> searchUids(String criteria);

  Future<List<MessageSummary>> fetchSummaries(List<int> uids);

  Future<void> moveUids(List<int> uids, String targetPath);

  /// Flags as deleted and expunges — gone for good.
  Future<void> deleteUids(List<int> uids);

  /// Keeps the connection alive between two user actions.
  Future<void> noop();
}
