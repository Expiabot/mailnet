import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mailnet/mail/google_auth.dart';

String idTokenFor(Map<String, dynamic> claims) {
  final payload = base64Url.encode(utf8.encode(jsonEncode(claims)));
  return 'header.$payload.signature';
}

void main() {
  group('redirection', () {
    test("l'identifiant client est inversé en schéma", () {
      expect(
        GoogleAuth.reverseClientId('123456-abcdef.apps.googleusercontent.com'),
        'com.googleusercontent.apps.123456-abcdef',
      );
    });

    test('un identifiant déjà nu est accepté', () {
      expect(
        GoogleAuth.reverseClientId('123456-abcdef'),
        'com.googleusercontent.apps.123456-abcdef',
      );
    });

    test("l'URL de redirection complète", () {
      const auth = GoogleAuth(
        clientId: '123456-abcdef.apps.googleusercontent.com',
      );
      expect(
        auth.redirectUri,
        'com.googleusercontent.apps.123456-abcdef:/oauth2redirect',
      );
    });

    test('sans identifiant, la connexion Google est désactivée', () {
      const auth = GoogleAuth(clientId: '');
      expect(auth.isConfigured, isFalse);
      expect(auth.beginSignIn, throwsA(isA<GoogleAuthException>()));
    });

    test('une redirection est reconnue, une autre non', () {
      const auth = GoogleAuth(
        clientId: '123456-abcdef.apps.googleusercontent.com',
      );
      expect(
        auth.isRedirect(
          Uri.parse('com.googleusercontent.apps.123456-abcdef:/oauth2redirect?code=x'),
        ),
        isTrue,
      );
      expect(auth.isRedirect(Uri.parse('https://exemple.fr/callback')), isFalse);
    });
  });

  group("lecture de l'id_token", () {
    test("l'adresse est extraite des claims", () {
      final token = idTokenFor({'email': 'moi@gmail.com', 'sub': '42'});
      expect(GoogleAuth.emailFromIdToken(token), 'moi@gmail.com');
    });

    test('base64url sans remplissage', () {
      // Google omet souvent le « = » final ; le décodage doit le tolérer.
      final token = idTokenFor({'email': 'a@b.fr'});
      expect(token.split('.')[1].endsWith('='), isFalse);
      expect(GoogleAuth.emailFromIdToken(token), 'a@b.fr');
    });

    test('jeton absent ou malformé', () {
      expect(GoogleAuth.emailFromIdToken(null), isNull);
      expect(GoogleAuth.emailFromIdToken('pas-un-jwt'), isNull);
      expect(GoogleAuth.emailFromIdToken('a.!!!.c'), isNull);
    });

    test("claims sans adresse", () {
      expect(GoogleAuth.emailFromIdToken(idTokenFor({'sub': '42'})), isNull);
    });
  });

  group('cycle de vie du jeton', () {
    GoogleSession sessionExpiringIn(Duration delta) => GoogleSession(
          email: 'moi@gmail.com',
          refreshToken: 'refresh-1',
          accessToken: 'access-1',
          expiresAt: DateTime.now().add(delta),
        );

    test('un jeton encore valable une heure est réutilisé tel quel', () {
      expect(sessionExpiringIn(const Duration(hours: 1)).isStale, isFalse);
    });

    test('un jeton qui expire dans une minute est déjà considéré périmé', () {
      // Renouvelé en avance : il ne doit pas mourir en pleine suppression.
      expect(sessionExpiringIn(const Duration(minutes: 1)).isStale, isTrue);
    });

    test('un jeton expiré est périmé', () {
      expect(sessionExpiringIn(const Duration(minutes: -5)).isStale, isTrue);
    });

    test('copyWith conserve les champs non fournis', () {
      final s = sessionExpiringIn(const Duration(hours: 1));
      final renewed = s.copyWith(accessToken: 'access-2');
      expect(renewed.accessToken, 'access-2');
      expect(renewed.refreshToken, 'refresh-1');
      expect(renewed.email, 'moi@gmail.com');
    });
  });

  group('persistance', () {
    test('aller-retour JSON', () {
      final s = GoogleSession(
        email: 'moi@gmail.com',
        refreshToken: 'refresh-1',
        accessToken: 'access-1',
        expiresAt: DateTime.parse('2026-09-15T10:00:00.000Z'),
      );
      final back = GoogleSession.fromJson(s.toJson())!;
      expect(back.email, s.email);
      expect(back.refreshToken, s.refreshToken);
      expect(back.expiresAt, s.expiresAt);
    });

    test('une entrée sans jeton de rafraîchissement est ignorée', () {
      expect(GoogleSession.fromJson({'email': 'a@b.fr'}), isNull);
      expect(GoogleSession.fromJson({'refreshToken': 'x'}), isNull);
    });

    test('une date illisible ne fait pas échouer la lecture', () {
      final s = GoogleSession.fromJson({
        'email': 'a@b.fr',
        'refreshToken': 'x',
        'expiresAt': 'n’importe quoi',
      })!;
      // Périmée plutôt qu'absente : la prochaine action renouvellera.
      expect(s.isStale, isTrue);
    });
  });
}
