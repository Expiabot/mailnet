import 'package:flutter/material.dart';

import '../mail/mail_filters.dart';
import '../mail/mail_service.dart';
import '../mail/models.dart';
import '../platform/background_task.dart';
import 'format.dart';

/// Runs a deletion the way it must always be run: behind a foreground service,
/// with a blocking progress dialog and an honest report at the end.
///
/// Shared by the results list and the sender list so neither can drift into a
/// version that forgets the service or swallows a partial count.
class DeleteRunner {
  const DeleteRunner(this.service, {this.background = const BackgroundTask()});

  final MailService service;
  final BackgroundTask background;

  Future<DeleteOutcome?> run(
    BuildContext context, {
    required String folder,
    required bool permanent,
    required int expected,
    List<int>? uids,
    MailFilters? filters,
    String? trashPath,
  }) async {
    final progress = ValueNotifier<DeleteProgress>(
      DeleteProgress(deleted: 0, total: expected),
    );
    showProgressDialog(context, progress);
    await background.start(DeleteProgress(deleted: 0, total: expected));

    final DeleteOutcome outcome;
    try {
      outcome = await service.deleteMessages(
        folder: folder,
        permanent: permanent,
        uids: uids,
        filters: filters,
        trashPath: trashPath,
        onProgress: (p) {
          progress.value = p;
          background.update(p);
        },
      );
    } finally {
      // The service must come down even if something unexpected escapes, or
      // the notification and the wake lock outlive the work.
      await background.stop();
      if (context.mounted) Navigator.of(context).pop();
      progress.dispose();
    }

    if (context.mounted) {
      showOutcome(context, outcome, permanent: permanent, hasTrash: trashPath != null);
    }
    return outcome;
  }
}

/// Opens the blocking progress dialog. Not awaited on purpose: the deletion
/// runs alongside it and closes it when finished.
void showProgressDialog(
  BuildContext context,
  ValueNotifier<DeleteProgress> progress, {
  String title = 'Suppression en cours…',
}) {
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
              Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
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
                'Vous pouvez quitter l’application, la suppression continue.',
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

void showOutcome(
  BuildContext context,
  DeleteOutcome outcome, {
  required bool permanent,
  required bool hasTrash,
}) {
  final singular = permanent
      ? 'supprimé définitivement'
      : hasTrash
          ? 'déplacé vers la corbeille'
          : 'supprimé';
  final many = permanent
      ? 'supprimés définitivement'
      : hasTrash
          ? 'déplacés vers la corbeille'
          : 'supprimés';
  final verb = outcome.deleted > 1 ? many : singular;

  final String message;
  final isError = !outcome.succeeded;
  if (isError) {
    message = 'Suppression interrompue : ${plural(outcome.deleted, 'mail')} '
        'sur ${formatCount(outcome.total)} $verb.';
  } else if (outcome.capped) {
    message = '${plural(outcome.deleted, 'mail')} $verb. Limite de '
        '${formatCount(MailService.deleteHardCap)} par opération atteinte — '
        'relancez pour le reste.';
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
