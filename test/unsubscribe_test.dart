import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mailnet/mail/unsubscribe.dart';
import 'package:mailnet/mail/unsubscribe_action.dart';

void main() {
  group('lecture de List-Unsubscribe', () {
    test('en-tête absent ou vide', () {
      expect(UnsubscribeInfo.parse(null), isNull);
      expect(UnsubscribeInfo.parse('   '), isNull);
    });

    test('lien https seul', () {
      final info = UnsubscribeInfo.parse('<https://exemple.fr/desabo?t=abc>')!;
      expect(info.httpUri.toString(), 'https://exemple.fr/desabo?t=abc');
      expect(info.mailtoUri, isNull);
      expect(info.oneClick, isFalse);
    });

    test('mailto seul', () {
      final info = UnsubscribeInfo.parse('<mailto:stop@exemple.fr>')!;
      expect(info.mailtoUri!.scheme, 'mailto');
      expect(info.httpUri, isNull);
    });

    test('les deux, dans n’importe quel ordre', () {
      const header = '<mailto:stop@exemple.fr>, <https://exemple.fr/u/1>';
      final info = UnsubscribeInfo.parse(header)!;
      expect(info.httpUri.toString(), 'https://exemple.fr/u/1');
      expect(info.mailtoUri.toString(), 'mailto:stop@exemple.fr');
    });

    test('espaces et retours à la ligne dans l’en-tête replié', () {
      const header = '<https://exemple.fr/u/1>,\r\n <mailto:stop@exemple.fr>';
      final info = UnsubscribeInfo.parse(header)!;
      expect(info.httpUri, isNotNull);
      expect(info.mailtoUri, isNotNull);
    });

    test('one-click reconnu quand l’en-tête Post est présent', () {
      final info = UnsubscribeInfo.parse(
        '<https://exemple.fr/u/1>',
        postHeader: 'List-Unsubscribe=One-Click',
      )!;
      expect(info.oneClick, isTrue);
    });

    test('one-click refusé en http : le jeton passerait en clair', () {
      final info = UnsubscribeInfo.parse(
        '<http://exemple.fr/u/1>',
        postHeader: 'List-Unsubscribe=One-Click',
      )!;
      expect(info.oneClick, isFalse);
    });

    test('one-click refusé sans lien web', () {
      final info = UnsubscribeInfo.parse(
        '<mailto:stop@exemple.fr>',
        postHeader: 'List-Unsubscribe=One-Click',
      )!;
      expect(info.oneClick, isFalse);
    });

    test('contenu non exploitable', () {
      expect(UnsubscribeInfo.parse('désabonnez-vous en bas de page'), isNull);
      expect(UnsubscribeInfo.parse('<pas-une-uri>'), isNull);
    });
  });

  group('action de désabonnement', () {
    test('one-click : un POST suffit, rien ne s’ouvre', () async {
      final opened = <Uri>[];
      final action = UnsubscribeAction(
        client: _fakeClient(status: 200),
        launcher: (uri) async {
          opened.add(uri);
          return true;
        },
      );

      final outcome = await action.run(UnsubscribeInfo.parse(
        '<https://exemple.fr/u/1>',
        postHeader: 'List-Unsubscribe=One-Click',
      )!);

      expect(outcome, UnsubscribeOutcome.done);
      expect(opened, isEmpty, reason: 'aucune page à ouvrir');
    });

    test('one-click refusé par le serveur : on retombe sur la page', () async {
      final opened = <Uri>[];
      final action = UnsubscribeAction(
        client: _fakeClient(status: 500),
        launcher: (uri) async {
          opened.add(uri);
          return true;
        },
      );

      final outcome = await action.run(UnsubscribeInfo.parse(
        '<https://exemple.fr/u/1>',
        postHeader: 'List-Unsubscribe=One-Click',
      )!);

      expect(outcome, UnsubscribeOutcome.opened);
      expect(opened.single.toString(), 'https://exemple.fr/u/1');
    });

    test('sans one-click, la page web est préférée au mailto', () async {
      final opened = <Uri>[];
      final action = UnsubscribeAction(
        launcher: (uri) async {
          opened.add(uri);
          return true;
        },
      );

      final outcome = await action.run(UnsubscribeInfo.parse(
        '<mailto:stop@exemple.fr>, <https://exemple.fr/u/1>',
      )!);

      expect(outcome, UnsubscribeOutcome.opened);
      expect(opened.single.scheme, 'https');
    });

    test('mailto quand c’est tout ce qu’il y a', () async {
      final opened = <Uri>[];
      final action = UnsubscribeAction(
        launcher: (uri) async {
          opened.add(uri);
          return true;
        },
      );

      await action.run(UnsubscribeInfo.parse('<mailto:stop@exemple.fr>')!);

      expect(opened.single.scheme, 'mailto');
    });

    test('rien ne s’ouvre : échec signalé, pas d’exception', () async {
      final action = UnsubscribeAction(launcher: (uri) async => false);
      final outcome =
          await action.run(UnsubscribeInfo.parse('<https://exemple.fr/u/1>')!);
      expect(outcome, UnsubscribeOutcome.failed);
    });
  });
}

/// Answers every POST with the given status; nothing else is ever called.
MockClient _fakeClient({required int status}) =>
    MockClient((request) async => http.Response('', status));
