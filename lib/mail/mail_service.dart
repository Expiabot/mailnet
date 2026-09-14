import 'dart:math';

import 'imap_gateway.dart';
import 'mail_filters.dart';
import 'models.dart';
import 'unsubscribe.dart';

/// Everything MailNet does to a mailbox, ported from the web server.
///
/// Two behaviours carried over deliberately, because both were bugs the web
/// version had to fix and a phone hits them far harder than a desktop:
///
///  * the connection is rebuilt transparently when the provider hangs up
///    (mobile networks drop far more often than a wired desktop), and
///  * a deletion that fails halfway still reports how many messages went away.
class MailService {
  MailService({
    required this.gateway,
    required this.account,
    required this.credentials,
  });

  /// Messages shown in the preview list. Deleting "everything" still applies to
  /// the whole result set, not just what is on screen.
  static const previewLimit = 500;

  /// UIDs per IMAP command. Small enough that a dropped connection costs one
  /// chunk instead of the whole run.
  static const deleteChunk = 200;

  /// Ceiling for a single delete request.
  static const deleteHardCap = 5000;

  /// UIDs per envelope fetch while scanning senders.
  static const senderScanChunk = 500;

  /// Messages examined by a sender scan. Fetching envelopes for a hundred
  /// thousand messages would take many minutes on mobile data; past this the
  /// most recent are scanned and the result is flagged as partial.
  static const senderScanCap = 20000;

  static const _trashHints = ['trash', 'corbeille', 'deleted', 'poubelle'];

  final ImapGateway gateway;
  final MailAccount account;

  /// Re-read on every reconnection, which is what lets an expired OAuth token
  /// be refreshed without the user noticing.
  final Future<MailCredentials> Function() credentials;

  Future<void>? _connecting;

  // ---------------------------------------------------------------------
  // Connection lifecycle
  // ---------------------------------------------------------------------

  /// Reconnects if needed, collapsing concurrent callers onto one attempt.
  Future<void> _ensureConnected() {
    if (gateway.isConnected) return Future.value();
    return _connecting ??= () async {
      try {
        await gateway.disconnect();
        await gateway.connect(account, await credentials());
      } finally {
        _connecting = null;
      }
    }();
  }

  /// Runs an IMAP operation, reconnecting once if the connection died under us.
  ///
  /// [op] must re-select its folder: a reconnect starts from a fresh session
  /// with nothing selected.
  Future<T> _withConnection<T>(Future<T> Function() op) async {
    await _ensureConnected();
    try {
      return await op();
    } on MailConnectionException {
      await gateway.disconnect();
      await _ensureConnected();
      return op();
    }
  }

  Future<void> disconnect() => gateway.disconnect();

  Future<void> keepAlive() async {
    if (!gateway.isConnected) return;
    try {
      await gateway.noop();
    } catch (_) {
      // A failed ping just means the next real operation will reconnect.
    }
  }

  // ---------------------------------------------------------------------
  // Folders
  // ---------------------------------------------------------------------

  Future<FolderListing> loadFolders() => _withConnection(() async {
        final folders = await gateway.listFolders();
        return FolderListing(
          folders: folders,
          trashPath: findTrashPath(folders),
        );
      });

  /// Prefers the server's own \Trash flag and falls back to name matching,
  /// which is what French and other non-English providers need.
  static String? findTrashPath(List<MailFolder> folders) {
    for (final f in folders) {
      if (f.isTrash) return f.path;
    }
    for (final f in folders) {
      final lower = f.path.toLowerCase();
      if (_trashHints.any(lower.contains)) return f.path;
    }
    return null;
  }

  // ---------------------------------------------------------------------
  // Search
  // ---------------------------------------------------------------------

  Future<SearchResult> search({
    required String folder,
    required MailFilters filters,
  }) =>
      _withConnection(() async {
        await gateway.selectFolder(folder);
        final uids = await gateway.searchUids(filters.toSearchCriteria());
        final total = uids.length;

        // Search returns oldest first; preview the most recent matches.
        final shown = uids.sublist(max(0, total - previewLimit));
        final messages =
            shown.isEmpty ? <MessageSummary>[] : await gateway.fetchSummaries(shown);

        // Don't trust the server's fetch order — sort explicitly, newest first.
        final ordered = [...messages]..sort((a, b) => b.uid.compareTo(a.uid));

        return SearchResult(
          total: total,
          messages: ordered,
          truncated: total > ordered.length,
        );
      });

  // ---------------------------------------------------------------------
  // Sender scan
  // ---------------------------------------------------------------------

  /// Groups a folder by sender: who writes to you most, what it costs, and
  /// whether they offer a way out.
  ///
  /// This is the entry point for someone who does not already know what to
  /// search for — the filters assume they do.
  Future<SenderScan> groupBySender({
    required String folder,
    MailFilters filters = const MailFilters(),
    void Function(ScanProgress)? onProgress,
  }) async {
    final found = await _withConnection(() async {
      await gateway.selectFolder(folder);
      return gateway.searchUids(filters.toSearchCriteria());
    });

    final capped = found.length > senderScanCap;
    // When capped, keep the most recent — those are the senders people recognise.
    final uids = capped ? found.sublist(found.length - senderScanCap) : found;
    final total = uids.length;

    final accumulators = <String, _SenderAccumulator>{};
    onProgress?.call(ScanProgress(scanned: 0, total: total));

    for (var i = 0; i < total; i += senderScanChunk) {
      final chunk = uids.sublist(i, min(i + senderScanChunk, total));
      // Per-chunk, like the delete loop: a dropped connection costs one chunk.
      final summaries = await _withConnection(() async {
        await gateway.selectFolder(folder);
        return gateway.fetchSummaries(chunk);
      });
      for (final message in summaries) {
        final key = _senderKey(message);
        (accumulators[key] ??= _SenderAccumulator(key)).add(message);
      }
      onProgress?.call(
        ScanProgress(scanned: min(i + senderScanChunk, total), total: total),
      );
    }

    final groups = accumulators.values.map((a) => a.build()).toList()
      ..sort((a, b) => b.count.compareTo(a.count));

    return SenderScan(groups: groups, scanned: total, capped: capped);
  }

  /// Senders are matched on the address, case-insensitively — the display name
  /// changes between messages far more often than the address does.
  static String _senderKey(MessageSummary m) {
    final address = m.fromAddress.trim().toLowerCase();
    if (address.isNotEmpty) return address;
    final name = m.fromName.trim().toLowerCase();
    return name.isNotEmpty ? name : '(inconnu)';
  }

  // ---------------------------------------------------------------------
  // Delete
  // ---------------------------------------------------------------------

  /// Deletes either an explicit list of [uids] or everything matching
  /// [filters]. Messages go to [trashPath] unless [permanent] is set.
  ///
  /// [onProgress] fires after every chunk so the UI can show a real bar — a
  /// five-thousand message run takes minutes and cannot look frozen.
  ///
  /// Never throws: a failure comes back as [DeleteState.failed] carrying the
  /// number of messages that were already removed.
  Future<DeleteOutcome> deleteMessages({
    required String folder,
    required bool permanent,
    List<int>? uids,
    MailFilters? filters,
    String? trashPath,
    void Function(DeleteProgress)? onProgress,
  }) async {
    final List<int> targets;
    final bool capped;

    if (uids != null && uids.isNotEmpty) {
      capped = uids.length > deleteHardCap;
      targets = uids.take(deleteHardCap).toList();
    } else {
      final found = await _withConnection(() async {
        await gateway.selectFolder(folder);
        return gateway
            .searchUids((filters ?? const MailFilters()).toSearchCriteria());
      });
      capped = found.length > deleteHardCap;
      targets = found.take(deleteHardCap).toList(); // oldest first
    }

    final total = targets.length;
    var deleted = 0;
    onProgress?.call(DeleteProgress(deleted: 0, total: total));

    final moveToTrash =
        !permanent && trashPath != null && trashPath.isNotEmpty && trashPath != folder;

    try {
      for (var i = 0; i < total; i += deleteChunk) {
        final chunk = targets.sublist(i, min(i + deleteChunk, total));
        await _withConnection(() async {
          await gateway.selectFolder(folder);
          if (moveToTrash) {
            await gateway.moveUids(chunk, trashPath);
          } else {
            await gateway.deleteUids(chunk);
          }
        });
        deleted += chunk.length;
        onProgress?.call(DeleteProgress(deleted: deleted, total: total));
      }
      return DeleteOutcome(
        state: DeleteState.done,
        deleted: deleted,
        total: total,
        capped: capped,
      );
    } catch (e) {
      // `deleted` is reported as-is on purpose: silently losing the count was
      // the bug that made a half-finished run impossible to reason about.
      return DeleteOutcome(
        state: DeleteState.failed,
        deleted: deleted,
        total: total,
        capped: capped,
        detail: e.toString(),
      );
    }
  }

  /// Empties the trash permanently.
  Future<DeleteOutcome> emptyTrash(
    String trashPath, {
    void Function(DeleteProgress)? onProgress,
  }) =>
      deleteMessages(
        folder: trashPath,
        permanent: true,
        filters: const MailFilters(),
        onProgress: onProgress,
      );
}

class _SenderAccumulator {
  _SenderAccumulator(this.key);

  final String key;
  final List<int> uids = [];
  String name = '';
  String address = '';
  int totalSize = 0;
  UnsubscribeInfo? unsubscribe;

  void add(MessageSummary m) {
    uids.add(m.uid);
    totalSize += m.size;
    if (address.isEmpty && m.fromAddress.isNotEmpty) address = m.fromAddress;
    if (name.isEmpty && m.fromName.isNotEmpty) name = m.fromName;
    // One usable unsubscribe link is enough; senders repeat it on every mail.
    unsubscribe ??= m.unsubscribe;
  }

  SenderGroup build() => SenderGroup(
        address: address.isNotEmpty ? address : key,
        name: name,
        uids: uids,
        totalSize: totalSize,
        unsubscribe: unsubscribe,
      );
}
