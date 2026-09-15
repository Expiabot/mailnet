import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mailnet/mail/oauth_flow.dart';
import 'package:mailnet/mail/oauth_providers.dart';

String idTokenFor(Map<String, dynamic> claims) {
  final payload = base64Url.encode(utf8.encode(jsonEncode(claims)));
  return 'header.$payload.signature';
}

void main() {
  group('redirection', () {
    test("l'identifiant client est inversé en schéma", () {
      expect(
        OAuthProviders.reverseClientId('123456-abcdef.apps.googleusercontent.com'),
        'com.googleusercontent.apps.123456-abcdef',
      );
    });

    test('un identifiant déjà nu est accepté', () {
      expect(
        OAuthProviders.reverseClientId('123456-abcdef'),
        'com.googleusercontent.apps.123456-abcdef',
      );
    });

    test('sans identifiant, la connexion est desactivee', () {
      final flow = OAuthFlow(_provider(clientId: ''));
      expect(flow.provider.isConfigured, isFalse);
      expect(flow.beginSignIn, throwsA(isA<OAuthException>()));
    });

    test('Google : le schema seul identifie la redirection', () {
      final flow = OAuthFlow(_provider());
      expect(
        flow.isRedirect(Uri.parse(
            'com.googleusercontent.apps.123456-abcdef:/oauth2redirect?code=x')),
        isTrue,
      );
      expect(flow.isRedirect(Uri.parse('https://exemple.fr/callback')), isFalse);
    });

    test('Microsoft : le schema est partage, l hote departage', () {
      final mine = OAuthFlow(_microsoft(package: 'fr.mailnet'));
      expect(mine.isRedirect(Uri.parse('msauth://fr.mailnet/abc?code=x')), isTrue);
      // Meme schema msauth, mais l'application d'a cote.
      expect(
        mine.isRedirect(Uri.parse('msauth://com.autre.app/abc?code=x')),
        isFalse,
      );
    });

    test('PKCE : un verificateur neuf a chaque tentative', () {
      final flow = OAuthFlow(_provider());
      final (first, firstUrl) = flow.beginSignIn();
      final (second, _) = flow.beginSignIn();
      expect(first.codeVerifier, isNot(second.codeVerifier));
      expect(first.state, isNot(second.state));
      expect(firstUrl.queryParameters['code_challenge_method'], 'S256');
      expect(firstUrl.queryParameters['state'], first.state);
      // Le verificateur ne doit jamais partir dans l'URL d'autorisation.
      expect(firstUrl.toString(), isNot(contains(first.codeVerifier)));
    });
  });

  group("lecture de l'id_token", () {
    test('Microsoft renseigne preferred_username plutot que email', () {
      final token = idTokenFor({'preferred_username': 'moi@outlook.com'});
      expect(OAuthFlow.emailFromIdToken(token), 'moi@outlook.com');
    });

    test("l'adresse est extraite des claims", () {
      final token = idTokenFor({'email': 'moi@gmail.com', 'sub': '42'});
      expect(OAuthFlow.emailFromIdToken(token), 'moi@gmail.com');
    });

    test('base64url sans remplissage', () {
      // Google omet souvent le « = » final ; le décodage doit le tolérer.
      final token = idTokenFor({'email': 'a@b.fr'});
      expect(token.split('.')[1].endsWith('='), isFalse);
      expect(OAuthFlow.emailFromIdToken(token), 'a@b.fr');
    });

    test('jeton absent ou malformé', () {
      expect(OAuthFlow.emailFromIdToken(null), isNull);
      expect(OAuthFlow.emailFromIdToken('pas-un-jwt'), isNull);
      expect(OAuthFlow.emailFromIdToken('a.!!!.c'), isNull);
    });

    test("claims sans adresse", () {
      expect(OAuthFlow.emailFromIdToken(idTokenFor({'sub': '42'})), isNull);
    });
  });

  group('cycle de vie du jeton', () {
    OAuthSession sessionExpiringIn(Duration delta) => OAuthSession(
          providerId: 'google',
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
      final s = OAuthSession(
        providerId: 'google',
        email: 'moi@gmail.com',
        refreshToken: 'refresh-1',
        accessToken: 'access-1',
        expiresAt: DateTime.parse('2026-09-15T10:00:00.000Z'),
      );
      final back = OAuthSession.fromJson(s.toJson())!;
      expect(back.email, s.email);
      expect(back.refreshToken, s.refreshToken);
      expect(back.expiresAt, s.expiresAt);
    });

    test('une entrée sans jeton de rafraîchissement est ignorée', () {
      expect(OAuthSession.fromJson({'email': 'a@b.fr'}), isNull);
      expect(OAuthSession.fromJson({'refreshToken': 'x'}), isNull);
    });

    test('une date illisible ne fait pas échouer la lecture', () {
      final s = OAuthSession.fromJson({
        'email': 'a@b.fr',
        'refreshToken': 'x',
        'expiresAt': 'n’importe quoi',
      })!;
      // Périmée plutôt qu'absente : la prochaine action renouvellera.
      expect(s.isStale, isTrue);
    });
  });
}

OAuthProvider _provider({
  String clientId = '123456-abcdef.apps.googleusercontent.com',
}) =>
    OAuthProvider(
      id: 'google',
      label: 'Google',
      clientId: clientId,
      authorizeEndpoint: Uri.parse('https://accounts.google.com/o/oauth2/v2/auth'),
      tokenEndpoint: Uri.parse('https://oauth2.googleapis.com/token'),
      scopes: 'openid email https://mail.google.com/',
      redirectUri: '${OAuthProviders.reverseClientId(clientId)}:/oauth2redirect',
      imapHost: 'imap.gmail.com',
    );

OAuthProvider _microsoft({required String package}) => OAuthProvider(
      id: 'microsoft',
      label: 'Microsoft',
      clientId: 'un-guid',
      authorizeEndpoint: Uri.parse(
          'https://login.microsoftonline.com/common/oauth2/v2.0/authorize'),
      tokenEndpoint: Uri.parse(
          'https://login.microsoftonline.com/common/oauth2/v2.0/token'),
      scopes: 'openid email offline_access',
      redirectUri: 'msauth://$package/hash',
      imapHost: 'outlook.office365.com',
    );
