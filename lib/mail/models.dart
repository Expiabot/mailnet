import 'unsubscribe.dart';

/// Where and how to reach a mailbox. Credentials are deliberately kept out of
/// this object so it can be logged or persisted without leaking anything.
class MailAccount {
  const MailAccount({
    required this.host,
    required this.port,
    required this.user,
  });

  final String host;
  final int port;
  final String user;
}

/// How to authenticate. Microsoft (and later Google) hand out access tokens
/// instead of accepting a password, so both forms have to be first class.
sealed class MailCredentials {
  const MailCredentials();
}

class PasswordCredentials extends MailCredentials {
  const PasswordCredentials(this.password);
  final String password;
}

class OAuthCredentials extends MailCredentials {
  const OAuthCredentials(this.accessToken);
  final String accessToken;
}

/// Thrown by a gateway when the connection itself failed rather than the
/// command. The service reconnects and retries once on these, and on nothing
/// else — a rejected password must never look like a dropped socket.
class MailConnectionException implements Exception {
  const MailConnectionException(this.message);
  final String message;

  @override
  String toString() => 'MailConnectionException: $message';
}

/// Raised when the server refuses the credentials.
class MailAuthException implements Exception {
  const MailAuthException(this.message);
  final String message;

  @override
  String toString() => 'MailAuthException: $message';
}

class MailFolder {
  const MailFolder({
    required this.path,
    required this.name,
    this.isTrash = false,
    this.isSent = false,
    this.isDrafts = false,
    this.isJunk = false,
    this.isInbox = false,
  });

  final String path;
  final String name;
  final bool isTrash;
  final bool isSent;
  final bool isDrafts;
  final bool isJunk;
  final bool isInbox;
}

class FolderListing {
  const FolderListing({required this.folders, this.trashPath});

  final List<MailFolder> folders;
  final String? trashPath;
}

class MessageSummary {
  const MessageSummary({
    required this.uid,
    this.date,
    this.fromName = '',
    this.fromAddress = '',
    this.subject = '',
    this.size = 0,
    this.unsubscribe,
  });

  final int uid;
  final DateTime? date;
  final String fromName;
  final String fromAddress;
  final String subject;
  final int size;

  /// Read from the List-Unsubscribe headers when the sender provides them.
  final UnsubscribeInfo? unsubscribe;

  String get displayFrom {
    if (fromName.isNotEmpty) return fromName;
    if (fromAddress.isNotEmpty) return fromAddress;
    return '—';
  }
}

class SearchResult {
  const SearchResult({
    required this.total,
    required this.messages,
    required this.truncated,
  });

  /// Every matching message in the folder, not just the ones previewed.
  final int total;

  /// The most recent matches, newest first, capped at [MailService.previewLimit].
  final List<MessageSummary> messages;

  final bool truncated;
}

/// Every message from one sender, with what it costs to keep them.
class SenderGroup {
  const SenderGroup({
    required this.address,
    required this.name,
    required this.uids,
    required this.totalSize,
    this.unsubscribe,
  });

  final String address;
  final String name;

  /// Every matching UID from this sender, so deleting the group needs no
  /// second search.
  final List<int> uids;

  final int totalSize;
  final UnsubscribeInfo? unsubscribe;

  int get count => uids.length;

  String get displayName => name.isNotEmpty ? name : address;

  bool get canUnsubscribe => unsubscribe != null && !unsubscribe!.isEmpty;
}

class SenderScan {
  const SenderScan({
    required this.groups,
    required this.scanned,
    required this.capped,
  });

  /// Senders, heaviest first by whatever the caller sorted on.
  final List<SenderGroup> groups;

  /// Messages actually examined.
  final int scanned;

  /// The mailbox was larger than [MailService.senderScanCap] and only the most
  /// recent messages were examined.
  final bool capped;

  int get totalSize =>
      groups.fold(0, (sum, g) => sum + g.totalSize);
}

class ScanProgress {
  const ScanProgress({required this.scanned, required this.total});

  final int scanned;
  final int total;

  double get fraction => total == 0 ? 0 : scanned / total;
}

class DeleteProgress {
  const DeleteProgress({required this.deleted, required this.total});

  final int deleted;
  final int total;

  double get fraction => total == 0 ? 0 : deleted / total;
}

enum DeleteState { done, failed }

class DeleteOutcome {
  const DeleteOutcome({
    required this.state,
    required this.deleted,
    required this.total,
    required this.capped,
    this.detail,
  });

  final DeleteState state;

  /// How many messages actually went away. Kept on failure too: the user needs
  /// to know what happened before it stopped.
  final int deleted;
  final int total;

  /// The request exceeded [MailService.deleteHardCap] and was trimmed.
  final bool capped;

  /// Technical message when [state] is [DeleteState.failed].
  final String? detail;

  bool get succeeded => state == DeleteState.done;
}
