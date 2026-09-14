import 'package:flutter/material.dart';

import '../mail/mail_service.dart';
import '../mail/models.dart';
import '../mail/unsubscribe_action.dart';
import '../platform/background_task.dart';
import '../ui/delete_runner.dart';
import '../ui/format.dart';
import '../ui/theme.dart';

enum _SortBy { count, size }

class SendersScreen extends StatefulWidget {
  const SendersScreen({
    super.key,
    required this.service,
    required this.folder,
    required this.trashPath,
  });

  final MailService service;
  final String folder;
  final String? trashPath;

  @override
  State<SendersScreen> createState() => _SendersScreenState();
}

class _SendersScreenState extends State<SendersScreen> {
  static const _background = BackgroundTask();

  SenderScan? _scan;
  ScanProgress _progress = const ScanProgress(scanned: 0, total: 0);
  bool _scanning = true;
  String? _error;
  _SortBy _sortBy = _SortBy.count;
  final _unsubscribing = <String>{};

  @override
  void initState() {
    super.initState();
    _background.prepare();
    _scan_();
  }

  Future<void> _scan_() async {
    setState(() {
      _scanning = true;
      _error = null;
    });
    try {
      final scan = await widget.service.groupBySender(
        folder: widget.folder,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (!mounted) return;
      setState(() {
        _scan = scan;
        _scanning = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _error = "L'analyse a échoué. $e";
      });
    }
  }

  List<SenderGroup> get _sorted {
    final groups = [...?_scan?.groups];
    groups.sort(
      _sortBy == _SortBy.count
          ? (a, b) => b.count.compareTo(a.count)
          : (a, b) => b.totalSize.compareTo(a.totalSize),
    );
    return groups;
  }

  Future<void> _deleteGroup(SenderGroup group) async {
    final permanent = await showDialog<bool>(
      context: context,
      builder: (_) => _ConfirmSenderDialog(
        group: group,
        hasTrash: widget.trashPath != null,
      ),
    );
    if (permanent == null || !mounted) return;

    await DeleteRunner(widget.service).run(
      context,
      folder: widget.folder,
      permanent: permanent,
      expected: group.count,
      uids: group.uids,
      trashPath: widget.trashPath,
    );
    if (mounted) await _scan_();
  }

  Future<void> _unsubscribe(SenderGroup group) async {
    final info = group.unsubscribe;
    if (info == null) return;

    setState(() => _unsubscribing.add(group.address));
    final outcome = await const UnsubscribeAction().run(info);
    if (!mounted) return;
    setState(() => _unsubscribing.remove(group.address));

    final (message, isError) = switch (outcome) {
      UnsubscribeOutcome.done => (
          'Désabonnement confirmé auprès de ${group.displayName}.',
          false,
        ),
      UnsubscribeOutcome.opened => (
          'Page de désabonnement ouverte — terminez la démarche là-bas.',
          false,
        ),
      UnsubscribeOutcome.failed => (
          "Le lien de désabonnement n'a pas pu être ouvert.",
          true,
        ),
    };

    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(message),
        backgroundColor: isError ? Theme.of(context).colorScheme.error : null,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 5),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final scan = _scan;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Qui vous écrit le plus'),
        actions: [
          if (!_scanning && scan != null)
            PopupMenuButton<_SortBy>(
              icon: const Icon(Icons.sort),
              tooltip: 'Trier',
              initialValue: _sortBy,
              onSelected: (v) => setState(() => _sortBy = v),
              itemBuilder: (_) => const [
                PopupMenuItem(value: _SortBy.count, child: Text('Par nombre')),
                PopupMenuItem(value: _SortBy.size, child: Text('Par taille')),
              ],
            ),
        ],
      ),
      body: switch ((_scanning, _error, scan)) {
        (true, _, _) => _ScanProgressView(progress: _progress),
        (_, final String error, _) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: NoticeBox(
                text: error,
                tone: NoticeTone.danger,
                icon: Icons.error_outline,
              ),
            ),
          ),
        (_, _, final SenderScan s) => _SenderList(
            scan: s,
            groups: _sorted,
            sortBy: _sortBy,
            unsubscribing: _unsubscribing,
            onDelete: _deleteGroup,
            onUnsubscribe: _unsubscribe,
          ),
        _ => Center(
            child: Text(
              'Rien à analyser.',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ),
      },
    );
  }
}

class _ScanProgressView extends StatelessWidget {
  const _ScanProgressView({required this.progress});

  final ScanProgress progress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 220,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: progress.total == 0 ? null : progress.fraction,
                  minHeight: 8,
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              progress.total == 0
                  ? 'Recherche des messages…'
                  : '${formatCount(progress.scanned)} / ${formatCount(progress.total)} messages analysés',
              style: const TextStyle(
                fontSize: 14,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'MailNet lit les en-têtes, jamais le contenu de vos messages.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _SenderList extends StatelessWidget {
  const _SenderList({
    required this.scan,
    required this.groups,
    required this.sortBy,
    required this.unsubscribing,
    required this.onDelete,
    required this.onUnsubscribe,
  });

  final SenderScan scan;
  final List<SenderGroup> groups;
  final _SortBy sortBy;
  final Set<String> unsubscribing;
  final void Function(SenderGroup) onDelete;
  final void Function(SenderGroup) onUnsubscribe;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
      itemCount: groups.length + 1,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '${plural(groups.length, 'expéditeur')} · '
                  '${plural(scan.scanned, 'message')} · '
                  '${formatSize(scan.totalSize)}',
                  style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
                ),
                if (scan.capped) ...[
                  const SizedBox(height: 10),
                  NoticeBox(
                    text: 'Boîte très volumineuse : seuls les '
                        '${formatCount(MailService.senderScanCap)} messages les '
                        'plus récents ont été analysés.',
                    tone: NoticeTone.warning,
                    icon: Icons.warning_amber_rounded,
                  ),
                ],
              ],
            ),
          );
        }

        final group = groups[index - 1];
        final busy = unsubscribing.contains(group.address);

        return Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CircleAvatar(
                      radius: 18,
                      backgroundColor: scheme.primaryContainer,
                      child: Text(
                        _initial(group),
                        style: TextStyle(
                          color: scheme.onPrimaryContainer,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            group.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (group.name.isNotEmpty)
                            Text(
                              group.address,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          const SizedBox(height: 4),
                          Text(
                            '${plural(group.count, 'mail')} · ${formatSize(group.totalSize)}',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: scheme.primary,
                              fontFeatures: const [FontFeature.tabularFigures()],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (group.canUnsubscribe)
                      TextButton.icon(
                        onPressed: busy ? null : () => onUnsubscribe(group),
                        icon: busy
                            ? const SizedBox(
                                height: 14,
                                width: 14,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.unsubscribe_outlined, size: 18),
                        label: Text(
                          group.unsubscribe!.oneClick
                              ? 'Se désabonner'
                              : 'Se désabonner…',
                        ),
                      ),
                    TextButton.icon(
                      onPressed: () => onDelete(group),
                      style: TextButton.styleFrom(foregroundColor: scheme.error),
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('Tout supprimer'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  static String _initial(SenderGroup group) {
    final source = group.displayName.trim();
    if (source.isEmpty) return '?';
    return source.characters.first.toUpperCase();
  }
}

class _ConfirmSenderDialog extends StatefulWidget {
  const _ConfirmSenderDialog({required this.group, required this.hasTrash});

  final SenderGroup group;
  final bool hasTrash;

  @override
  State<_ConfirmSenderDialog> createState() => _ConfirmSenderDialogState();
}

class _ConfirmSenderDialogState extends State<_ConfirmSenderDialog> {
  bool _permanent = false;

  @override
  Widget build(BuildContext context) {
    final g = widget.group;
    final overCap = g.count > MailService.deleteHardCap;

    return AlertDialog(
      title: Text(g.displayName, maxLines: 2, overflow: TextOverflow.ellipsis),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.hasTrash && !_permanent
                ? '${plural(g.count, 'mail')} (${formatSize(g.totalSize)}) '
                    'seront déplacés vers la corbeille. Vous pourrez les récupérer.'
                : '${plural(g.count, 'mail')} (${formatSize(g.totalSize)}) '
                    'seront supprimés définitivement. Cette action est irréversible.',
          ),
          if (overCap) ...[
            const SizedBox(height: 12),
            NoticeBox(
              text: 'Opération limitée à '
                  '${formatCount(MailService.deleteHardCap)} mails par lot : '
                  'relancez ensuite pour le reste.',
              tone: NoticeTone.warning,
              icon: Icons.warning_amber_rounded,
            ),
          ],
          if (widget.hasTrash) ...[
            const SizedBox(height: 4),
            CheckboxListTile(
              value: _permanent,
              onChanged: (v) => setState(() => _permanent = v ?? false),
              title: const Text(
                'Supprimer définitivement',
                style: TextStyle(fontSize: 14),
              ),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Annuler'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
          onPressed: () => Navigator.of(context).pop(_permanent),
          child: const Text('Supprimer'),
        ),
      ],
    );
  }
}
