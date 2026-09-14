import 'package:flutter/material.dart';

import '../mail/mail_filters.dart';
import '../mail/mail_service.dart';
import '../mail/models.dart';
import '../platform/background_task.dart';
import '../ui/delete_runner.dart';
import '../ui/format.dart';
import '../ui/theme.dart';

class ResultsScreen extends StatefulWidget {
  const ResultsScreen({
    super.key,
    required this.service,
    required this.folder,
    required this.filters,
    required this.initialResult,
    required this.trashPath,
  });

  final MailService service;
  final String folder;
  final MailFilters filters;
  final SearchResult initialResult;
  final String? trashPath;

  @override
  State<ResultsScreen> createState() => _ResultsScreenState();
}

class _ResultsScreenState extends State<ResultsScreen> {
  static const _background = BackgroundTask();

  late SearchResult _result;
  late Set<int> _selected;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _result = widget.initialResult;
    _selected = _result.messages.map((m) => m.uid).toSet();
    // Ask now rather than mid-deletion, when a system prompt would land on top
    // of the progress dialog.
    _background.prepare();
  }

  /// True when the user kept every previewed message *and* there are more
  /// beyond the preview — then the delete targets the whole search, not just
  /// the rows on screen.
  bool get _wholeSearch =>
      _result.truncated && _selected.length == _result.messages.length;

  int get _targetCount => _wholeSearch ? _result.total : _selected.length;

  Future<void> _confirmAndDelete() async {
    final permanent = await showDialog<bool>(
      context: context,
      builder: (_) => _ConfirmDialog(
        count: _targetCount,
        hasTrash: widget.trashPath != null,
        overCap: _targetCount > MailService.deleteHardCap,
      ),
    );
    if (permanent == null || !mounted) return;

    setState(() => _busy = true);
    await DeleteRunner(widget.service).run(
      context,
      folder: widget.folder,
      permanent: permanent,
      expected: _targetCount,
      uids: _wholeSearch ? null : _selected.toList(),
      filters: widget.filters,
      trashPath: widget.trashPath,
    );
    if (!mounted) return;
    await _refresh();
  }

  void _showOutcome(DeleteOutcome outcome, {required bool permanent}) {
    final where = permanent
        ? 'supprimé définitivement'
        : widget.trashPath != null
            ? 'déplacé vers la corbeille'
            : 'supprimé';
    final wherePlural = permanent
        ? 'supprimés définitivement'
        : widget.trashPath != null
            ? 'déplacés vers la corbeille'
            : 'supprimés';
    final verb = outcome.deleted > 1 ? wherePlural : where;

    final String message;
    final bool isError = !outcome.succeeded;
    if (isError) {
      message = 'Suppression interrompue : '
          '${plural(outcome.deleted, 'mail')} sur ${formatCount(outcome.total)} '
          '$verb.';
    } else if (outcome.capped) {
      message = '${plural(outcome.deleted, 'mail')} $verb. '
          'Limite de ${formatCount(MailService.deleteHardCap)} par opération '
          'atteinte — relancez pour le reste.';
    } else {
      message = '${plural(outcome.deleted, 'mail')} $verb.';
    }

    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(message),
        backgroundColor: isError ? Theme.of(context).colorScheme.error : null,
        duration: const Duration(seconds: 6),
        behavior: SnackBarBehavior.floating,
      ));
  }

  Future<void> _refresh() async {
    setState(() => _busy = true);
    try {
      final fresh = await widget.service.search(
        folder: widget.folder,
        filters: widget.filters,
      );
      if (!mounted) return;
      setState(() {
        _result = fresh;
        _selected = fresh.messages.map((m) => m.uid).toSet();
        _busy = false;
      });
    } catch (_) {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final allSelected = _selected.length == _result.messages.length &&
        _result.messages.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Vérifiez, puis supprimez'),
        actions: [
          if (widget.trashPath != null)
            IconButton(
              tooltip: 'Vider la corbeille',
              onPressed: _busy ? null : _emptyTrash,
              icon: const Icon(Icons.delete_sweep_outlined),
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (widget.filters.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: NoticeBox(
                      text: 'Aucun filtre actif : tous les mails du dossier '
                          'sont concernés.',
                      tone: NoticeTone.warning,
                      icon: Icons.warning_amber_rounded,
                    ),
                  ),
                RichText(
                  text: TextSpan(
                    style: TextStyle(fontSize: 14, color: scheme.onSurface),
                    children: [
                      TextSpan(
                        text: formatCount(_result.total),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      TextSpan(
                        text: _result.total > 1
                            ? ' mails correspondent'
                            : ' mail correspond',
                      ),
                      if (_result.truncated)
                        TextSpan(
                          text: ' — aperçu des '
                              '${formatCount(_result.messages.length)} plus récents',
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (_result.messages.isNotEmpty)
            CheckboxListTile(
              value: allSelected,
              tristate: _selected.isNotEmpty && !allSelected,
              onChanged: _busy
                  ? null
                  : (v) => setState(() {
                        _selected = (v ?? false)
                            ? _result.messages.map((m) => m.uid).toSet()
                            : <int>{};
                      }),
              dense: true,
              title: Text(
                allSelected ? 'Tout décocher' : 'Tout cocher',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            ),
          const Divider(height: 1),
          Expanded(
            child: _result.messages.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.inbox_outlined,
                              size: 48, color: scheme.outline),
                          const SizedBox(height: 12),
                          Text(
                            'Aucun mail ne correspond à ces filtres.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView.separated(
                    itemCount: _result.messages.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final m = _result.messages[i];
                      final checked = _selected.contains(m.uid);
                      return CheckboxListTile(
                        value: checked,
                        onChanged: _busy
                            ? null
                            : (v) => setState(() {
                                  if (v ?? false) {
                                    _selected.add(m.uid);
                                  } else {
                                    _selected.remove(m.uid);
                                  }
                                }),
                        controlAffinity: ListTileControlAffinity.leading,
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 16),
                        title: Text(
                          m.displayFrom,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              m.subject,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${formatDate(m.date)}  ·  ${formatSize(m.size)}',
                              style: TextStyle(
                                fontSize: 11,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      bottomNavigationBar: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          10,
          20,
          16 + MediaQuery.of(context).padding.bottom,
        ),
        child: FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: scheme.error,
            foregroundColor: scheme.onError,
          ),
          onPressed:
              (_busy || _selected.isEmpty) ? null : _confirmAndDelete,
          icon: const Icon(Icons.delete_outline),
          label: Text(
            _selected.isEmpty
                ? 'Supprimer'
                : 'Supprimer ${plural(_targetCount, 'mail')}',
          ),
        ),
      ),
    );
  }

  Future<void> _emptyTrash() async {
    final trash = widget.trashPath;
    if (trash == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Vider la corbeille'),
        content: const Text(
          'Tout le contenu de la corbeille sera supprimé définitivement. '
          'Cette action est irréversible.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Vider'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final progress = ValueNotifier<DeleteProgress>(
      const DeleteProgress(deleted: 0, total: 0),
    );
    unawaitedDialog(context, progress);
    setState(() => _busy = true);
    await _background.start(const DeleteProgress(deleted: 0, total: 0));

    final DeleteOutcome outcome;
    try {
      outcome = await widget.service.emptyTrash(
        trash,
        onProgress: (p) {
          progress.value = p;
          _background.update(p);
        },
      );
    } finally {
      await _background.stop();
    }

    if (mounted) Navigator.of(context).pop();
    progress.dispose();
    if (!mounted) return;
    setState(() => _busy = false);
    _showOutcome(outcome, permanent: true);
  }
}

/// Opens the blocking progress dialog. Not awaited on purpose: the delete runs
/// alongside it and closes it when finished.
void unawaitedDialog(
  BuildContext context,
  ValueNotifier<DeleteProgress> progress,
) {
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: ValueListenableBuilder<DeleteProgress>(
          valueListenable: progress,
          builder: (context, value, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Suppression en cours…',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 14),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: value.total == 0 ? null : value.fraction,
                  minHeight: 8,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                value.total == 0
                    ? 'Préparation…'
                    : '${formatCount(value.deleted)} / ${formatCount(value.total)}',
                style: const TextStyle(
                  fontSize: 13,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Gardez l’application ouverte.',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _ConfirmDialog extends StatefulWidget {
  const _ConfirmDialog({
    required this.count,
    required this.hasTrash,
    required this.overCap,
  });

  final int count;
  final bool hasTrash;
  final bool overCap;

  @override
  State<_ConfirmDialog> createState() => _ConfirmDialogState();
}

class _ConfirmDialogState extends State<_ConfirmDialog> {
  bool _permanent = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Confirmer la suppression'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.hasTrash && !_permanent
                ? '${plural(widget.count, 'mail')} seront déplacés vers la '
                    'corbeille. Vous pourrez les récupérer.'
                : '${plural(widget.count, 'mail')} seront supprimés '
                    'définitivement. Cette action est irréversible.',
          ),
          if (widget.overCap) ...[
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
              subtitle: const Text(
                'Sans passer par la corbeille',
                style: TextStyle(fontSize: 12),
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
          child: const Text('Oui, supprimer'),
        ),
      ],
    );
  }
}
