import 'package:flutter_test/flutter_test.dart';
import 'package:mailnet/mail/mail_filters.dart';
import 'package:mailnet/mail/mail_service.dart';
import 'package:mailnet/mail/models.dart';

import 'fake_imap_gateway.dart';

void main() {
  late FakeImapGateway gateway;
  late MailService service;
  late List<MailCredentials> handedOut;

  setUp(() {
    gateway = FakeImapGateway(
      folders: const [
        MailFolder(path: 'INBOX', name: 'INBOX', isInbox: true),
        MailFolder(path: 'Corbeille', name: 'Corbeille', isTrash: true),
        MailFolder(path: 'Envoyes', name: 'Envoyés', isSent: true),
      ],
    );
    handedOut = [];
    service = MailService(
      gateway: gateway,
      account: const MailAccount(
        host: 'imap.exemple.fr',
        port: 993,
        user: 'moi@exemple.fr',
      ),
      credentials: () async {
        const c = PasswordCredentials('secret');
        handedOut.add(c);
        return c;
      },
    );
  });

  List<int> uids(int count) => List.generate(count, (i) => i + 1);

  Future<DeleteOutcome> deleteAll({
    String folder = 'INBOX',
    bool permanent = false,
    String? trashPath = 'Corbeille',
    void Function(DeleteProgress)? onProgress,
  }) =>
      service.deleteMessages(
        folder: folder,
        permanent: permanent,
        trashPath: trashPath,
        filters: const MailFilters(),
        onProgress: onProgress,
      );

  group('connexion', () {
    test('se connecte à la demande, une seule fois', () async {
      await service.loadFolders();
      await service.loadFolders();
      expect(gateway.connectCount, 1);
    });

    test('les identifiants sont relus à chaque reconnexion', () async {
      await service.loadFolders();
      gateway.dropConnection();
      await service.loadFolders();
      // Deux lectures = un jeton OAuth expiré peut être renouvelé au passage.
      expect(handedOut.length, 2);
    });

    test('reconnexion transparente après une coupure', () async {
      await service.loadFolders();
      gateway.dropConnection();

      gateway.searchResult = [1, 2, 3];
      final result = await service.search(
        folder: 'INBOX',
        filters: const MailFilters(),
      );

      expect(result.total, 3);
      expect(gateway.connectCount, 2);
    });

    test('une erreur non liée au réseau ne déclenche pas de reconnexion', () async {
      await service.loadFolders();
      gateway.searchResult = uids(10);
      gateway.failures[0] = StateError('le serveur refuse la commande MOVE');

      final before = gateway.connectCount;
      final outcome = await deleteAll();

      expect(outcome.state, DeleteState.failed);
      expect(gateway.connectCount, before);
    });
  });

  group('dossiers', () {
    test('détecte la corbeille par son attribut serveur', () async {
      final listing = await service.loadFolders();
      expect(listing.trashPath, 'Corbeille');
    });

    test('détecte la corbeille par son nom quand le serveur ne la marque pas', () {
      const folders = [
        MailFolder(path: 'INBOX', name: 'INBOX'),
        MailFolder(path: '[Gmail]/Corbeille', name: 'Corbeille'),
      ];
      expect(MailService.findTrashPath(folders), '[Gmail]/Corbeille');
    });

    test('renvoie null quand il n’y a pas de corbeille', () {
      const folders = [MailFolder(path: 'INBOX', name: 'INBOX')];
      expect(MailService.findTrashPath(folders), isNull);
    });
  });

  group('recherche', () {
    test('aperçu limité aux 500 plus récents, total complet conservé', () async {
      gateway.searchResult = uids(1200);

      final result = await service.search(
        folder: 'INBOX',
        filters: const MailFilters(),
      );

      expect(result.total, 1200);
      expect(result.messages.length, MailService.previewLimit);
      expect(result.truncated, isTrue);
      // Les 500 plus récents, pas les 500 plus anciens.
      expect(result.messages.first.uid, 1200);
      expect(result.messages.last.uid, 701);
    });

    test('les messages sortent du plus récent au plus ancien', () async {
      gateway.searchResult = [4, 1, 3, 2];

      final result = await service.search(
        folder: 'INBOX',
        filters: const MailFilters(),
      );

      expect(result.messages.map((m) => m.uid), [4, 3, 2, 1]);
      expect(result.truncated, isFalse);
    });

    test('un dossier vide ne déclenche aucun fetch', () async {
      gateway.searchResult = [];

      final result = await service.search(
        folder: 'INBOX',
        filters: const MailFilters(),
      );

      expect(result.total, 0);
      expect(result.messages, isEmpty);
    });
  });

  group('regroupement par expéditeur', () {
    test('additionne les mails et la taille par adresse', () async {
      gateway.searchResult = [1, 2, 3, 4, 5];
      gateway.senderOf = {
        1: 'promo@amazon.fr',
        2: 'promo@amazon.fr',
        3: 'promo@amazon.fr',
        4: 'info@sncf.fr',
        5: 'promo@amazon.fr',
      };

      final scan = await service.groupBySender(folder: 'INBOX');

      expect(scan.groups.first.address, 'promo@amazon.fr');
      expect(scan.groups.first.count, 4);
      expect(scan.groups.first.uids, [1, 2, 3, 5]);
      expect(scan.groups.last.count, 1);
      expect(scan.scanned, 5);
      expect(scan.capped, isFalse);
    });

    test('la casse de l’adresse ne sépare pas un expéditeur en deux', () async {
      gateway.searchResult = [1, 2];
      gateway.senderOf = {1: 'Promo@Amazon.fr', 2: 'promo@amazon.fr'};

      final scan = await service.groupBySender(folder: 'INBOX');

      expect(scan.groups, hasLength(1));
      expect(scan.groups.single.count, 2);
    });

    test('les expéditeurs sortent du plus bavard au moins bavard', () async {
      gateway.searchResult = [1, 2, 3];
      gateway.senderOf = {1: 'a@x.fr', 2: 'b@x.fr', 3: 'b@x.fr'};

      final scan = await service.groupBySender(folder: 'INBOX');

      expect(scan.groups.map((g) => g.address), ['b@x.fr', 'a@x.fr']);
    });

    test('la progression avance par lots', () async {
      gateway.searchResult = uids(1200);

      final steps = <int>[];
      await service.groupBySender(
        folder: 'INBOX',
        onProgress: (p) => steps.add(p.scanned),
      );

      expect(steps, [0, 500, 1000, 1200]);
    });

    test('au-delà du plafond, seuls les plus récents sont analysés', () async {
      gateway.searchResult = uids(25000);

      final scan = await service.groupBySender(folder: 'INBOX');

      expect(scan.capped, isTrue);
      expect(scan.scanned, MailService.senderScanCap);
      // Les plus récents, pas les plus anciens.
      final all = scan.groups.expand((g) => g.uids);
      expect(all.reduce((a, b) => a < b ? a : b), 5001);
    });

    test('une coupure pendant l’analyse est rattrapée', () async {
      gateway.searchResult = uids(1200);
      gateway.dropAfterFetches = 1;

      final scan = await service.groupBySender(folder: 'INBOX');

      expect(scan.scanned, 1200);
      expect(scan.groups.fold<int>(0, (n, g) => n + g.count), 1200);
    });

    test('dossier vide', () async {
      gateway.searchResult = [];
      final scan = await service.groupBySender(folder: 'INBOX');
      expect(scan.groups, isEmpty);
      expect(scan.scanned, 0);
    });
  });

  group('suppression', () {
    test('déplace vers la corbeille par défaut', () async {
      gateway.searchResult = uids(450);

      final outcome = await deleteAll();

      expect(outcome.state, DeleteState.done);
      expect(outcome.deleted, 450);
      expect(gateway.moved.length, 450);
      expect(gateway.moved.toSet().length, 450, reason: 'aucun doublon');
      expect(gateway.lastMoveTarget, 'Corbeille');
      expect(gateway.deleted, isEmpty);
    });

    test('supprime définitivement quand on le demande', () async {
      gateway.searchResult = uids(250);

      final outcome = await deleteAll(permanent: true);

      expect(outcome.deleted, 250);
      expect(gateway.deleted.length, 250);
      expect(gateway.moved, isEmpty);
    });

    test('supprime sur place quand la corbeille est le dossier courant', () async {
      gateway.searchResult = uids(10);

      await deleteAll(folder: 'Corbeille', trashPath: 'Corbeille');

      expect(gateway.deleted.length, 10);
      expect(gateway.moved, isEmpty);
    });

    test('découpe en lots de 200', () async {
      gateway.searchResult = uids(450);

      final steps = <int>[];
      await deleteAll(onProgress: (p) => steps.add(p.deleted));

      expect(steps, [0, 200, 400, 450]);
    });

    test('une liste explicite de UID court-circuite la recherche', () async {
      gateway.searchResult = uids(1000);

      final outcome = await service.deleteMessages(
        folder: 'INBOX',
        permanent: false,
        uids: const [7, 8, 9],
        trashPath: 'Corbeille',
      );

      expect(outcome.deleted, 3);
      expect(gateway.moved, [7, 8, 9]);
      expect(gateway.searchCriteria, isEmpty);
    });

    test('plafonne à 5 000 et le signale', () async {
      gateway.searchResult = uids(6000);

      final outcome = await deleteAll();

      expect(outcome.capped, isTrue);
      expect(outcome.total, MailService.deleteHardCap);
      expect(outcome.deleted, MailService.deleteHardCap);
    });

    test('ne signale pas de plafond en dessous de la limite', () async {
      gateway.searchResult = uids(100);
      expect((await deleteAll()).capped, isFalse);
    });

    test('conserve le compteur partiel quand ça casse en cours de route', () async {
      gateway.searchResult = uids(450);
      gateway.failures[1] = StateError('le serveur a refusé le MOVE');

      final outcome = await deleteAll();

      expect(outcome.state, DeleteState.failed);
      expect(outcome.deleted, 200, reason: 'le premier lot est bien parti');
      expect(outcome.total, 450);
      expect(outcome.detail, contains('MOVE'));
    });

    test('une coupure en cours de route est rattrapée sans perte', () async {
      gateway.searchResult = uids(450);
      gateway.failures[1] =
          const MailConnectionException('Connexion fermée par le serveur.');

      final outcome = await deleteAll();

      expect(outcome.state, DeleteState.done);
      expect(outcome.deleted, 450);
      expect(gateway.moved.length, 450);
      expect(gateway.moved.toSet().length, 450, reason: 'aucun doublon');
      expect(gateway.connectCount, 2);
    });

    test('la progression est observable pendant une suppression lente', () async {
      gateway.searchResult = uids(600);
      gateway.latency = const Duration(milliseconds: 10);

      final seen = <double>[];
      await deleteAll(onProgress: (p) => seen.add(p.fraction));

      expect(seen.first, 0);
      expect(seen.last, 1);
      expect(seen.length, greaterThan(2));
    });

    test('ne lève jamais : un échec revient comme un résultat', () async {
      gateway.searchResult = uids(10);
      gateway.failures[0] = Exception('boum');

      await expectLater(deleteAll(), completes);
    });

    test('vider la corbeille supprime définitivement', () async {
      gateway.searchResult = uids(30);

      final outcome = await service.emptyTrash('Corbeille');

      expect(outcome.deleted, 30);
      expect(gateway.deleted.length, 30);
      expect(gateway.moved, isEmpty);
    });

    test('vider la corbeille remonte aussi la progression', () async {
      gateway.searchResult = uids(450);

      final steps = <int>[];
      await service.emptyTrash('Corbeille', onProgress: (p) => steps.add(p.deleted));

      expect(steps, [0, 200, 400, 450]);
    });

    test('supprimer sur une recherche vide ne fait rien', () async {
      gateway.searchResult = [];

      final outcome = await deleteAll();

      expect(outcome.state, DeleteState.done);
      expect(outcome.deleted, 0);
      expect(gateway.moved, isEmpty);
    });
  });
}
