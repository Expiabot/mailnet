import 'package:mailnet/mail/imap_gateway.dart';
import 'package:mailnet/mail/models.dart';

/// An in-memory IMAP server good enough to exercise the deletion logic:
/// no network, no mailbox, no phone.
class FakeImapGateway implements ImapGateway {
  FakeImapGateway({this.folders = const []});

  List<MailFolder> folders;

  /// UIDs any search returns.
  List<int> searchResult = [];

  /// Sender address per UID; anything unlisted gets a unique one.
  Map<int, String> senderOf = {};

  /// Drops the connection after this many fetches, once.
  int? dropAfterFetches;
  int _fetches = 0;

  /// Latency per command, so progress callbacks are observable.
  Duration latency = Duration.zero;

  // --- observed calls ---
  int connectCount = 0;
  int disconnectCount = 0;
  final List<MailCredentials> credentialsUsed = [];
  final List<String> selectedFolders = [];
  final List<String> searchCriteria = [];
  final List<int> moved = [];
  final List<int> deleted = [];
  String? lastMoveTarget;

  // --- fault injection ---
  /// Operation index (counting move/delete calls) → error to throw once.
  final Map<int, Object> failures = {};
  int _opIndex = 0;
  Object? connectError;

  bool _connected = false;

  /// Simulates the provider hanging up while nobody was looking.
  void dropConnection() => _connected = false;

  @override
  bool get isConnected => _connected;

  @override
  Future<void> connect(MailAccount account, MailCredentials credentials) async {
    connectCount++;
    credentialsUsed.add(credentials);
    final error = connectError;
    if (error != null) {
      connectError = null;
      throw error;
    }
    _connected = true;
  }

  @override
  Future<void> disconnect() async {
    if (_connected) disconnectCount++;
    _connected = false;
  }

  @override
  Future<List<MailFolder>> listFolders() async {
    _requireConnection();
    return folders;
  }

  @override
  Future<void> selectFolder(String path) async {
    _requireConnection();
    selectedFolders.add(path);
  }

  @override
  Future<List<int>> searchUids(String criteria) async {
    _requireConnection();
    searchCriteria.add(criteria);
    return List<int>.from(searchResult);
  }

  @override
  Future<List<MessageSummary>> fetchSummaries(List<int> uids) async {
    _requireConnection();
    if (dropAfterFetches != null && _fetches == dropAfterFetches) {
      dropAfterFetches = null;
      _connected = false;
      throw const MailConnectionException('Connexion fermée par le serveur.');
    }
    _fetches++;
    return uids
        .map((uid) => MessageSummary(
              uid: uid,
              date: DateTime(2026, 1, 1).add(Duration(days: uid)),
              fromAddress: senderOf[uid] ?? 'expediteur$uid@exemple.fr',
              subject: 'Message $uid',
              size: 10,
            ))
        .toList();
  }

  @override
  Future<void> moveUids(List<int> uids, String targetPath) async {
    await _operation();
    lastMoveTarget = targetPath;
    moved.addAll(uids);
  }

  @override
  Future<void> deleteUids(List<int> uids) async {
    await _operation();
    deleted.addAll(uids);
  }

  @override
  Future<void> noop() async => _requireConnection();

  Future<void> _operation() async {
    _requireConnection();
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    final error = failures.remove(_opIndex++);
    if (error != null) {
      if (error is MailConnectionException) _connected = false;
      throw error;
    }
  }

  void _requireConnection() {
    if (!_connected) {
      throw const MailConnectionException('Connexion fermée par le serveur.');
    }
  }
}
