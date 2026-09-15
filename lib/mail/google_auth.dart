import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_appauth/flutter_appauth.dart';

/// What a completed Google sign-in leaves behind.
///
/// The refresh token is the durable part; the access token is short-lived and
/// gets renewed on demand.
@immutable
class GoogleSession {
  const GoogleSession({
    required this.email,
    required this.refreshToken,
    required this.accessToken,
    required this.expiresAt,
  });

  final String email;
  final String refreshToken;
  final String accessToken;
  final DateTime expiresAt;

  /// Renewed a little early: an hour-long token must not die in the middle of
  /// a long deletion.
  bool get isStale => DateTime.now().isAfter(
        expiresAt.subtract(const Duration(minutes: 2)),
      );

  GoogleSession copyWith({
    String? refreshToken,
    String? accessToken,
    DateTime? expiresAt,
  }) =>
      GoogleSession(
        email: email,
        refreshToken: refreshToken ?? this.refreshToken,
        accessToken: accessToken ?? this.accessToken,
        expiresAt: expiresAt ?? this.expiresAt,
      );

  Map<String, dynamic> toJson() => {
        'email': email,
        'refreshToken': refreshToken,
        'accessToken': accessToken,
        'expiresAt': expiresAt.toIso8601String(),
      };

  static GoogleSession? fromJson(Map<String, dynamic> json) {
    final email = json['email'] as String?;
    final refresh = json['refreshToken'] as String?;
    if (email == null || refresh == null) return null;
    return GoogleSession(
      email: email,
      refreshToken: refresh,
      accessToken: json['accessToken'] as String? ?? '',
      expiresAt:
          DateTime.tryParse(json['expiresAt'] as String? ?? '') ?? DateTime(2000),
    );
  }
}

class GoogleAuthException implements Exception {
  const GoogleAuthException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Signs in to Google and keeps an IMAP-capable access token alive.
///
/// The client id is public — Google issues no secret for an installed app, and
/// binds the client to the package name plus the signing certificate instead.
class GoogleAuth {
  const GoogleAuth({required this.clientId, this.appAuth});

  /// Supplied at build time: `--dart-define=GOOGLE_CLIENT_ID=...`
  static const configured =
      String.fromEnvironment('GOOGLE_CLIENT_ID', defaultValue: '');

  static const _issuer = 'https://accounts.google.com';

  /// `mail.google.com` is the only scope that grants IMAP. It is a *restricted*
  /// scope: unlimited use needs Google verification and an annual CASA audit.
  /// Until then the Cloud project stays in testing, capped at 100 declared
  /// accounts.
  static const scopes = ['openid', 'email', 'https://mail.google.com/'];

  final String clientId;

  /// Injectable for tests; the real plugin otherwise.
  final FlutterAppAuth? appAuth;

  bool get isConfigured => clientId.isNotEmpty;

  FlutterAppAuth get _auth => appAuth ?? const FlutterAppAuth();

  /// Google's installed-app redirect: the client id, reversed into a scheme.
  /// Nothing is hosted anywhere — the scheme reopens this app.
  String get redirectUrl => '${reverseClientId(clientId)}:/oauth2redirect';

  /// `123-abc.apps.googleusercontent.com` → `com.googleusercontent.apps.123-abc`
  static String reverseClientId(String clientId) {
    const suffix = '.apps.googleusercontent.com';
    final id = clientId.endsWith(suffix)
        ? clientId.substring(0, clientId.length - suffix.length)
        : clientId;
    return 'com.googleusercontent.apps.$id';
  }

  Future<GoogleSession> signIn() async {
    if (!isConfigured) {
      throw const GoogleAuthException(
        "Connexion Google non configurée dans cette version de l'application.",
      );
    }

    final AuthorizationTokenResponse response;
    try {
      response = await _auth.authorizeAndExchangeCode(
        AuthorizationTokenRequest(
          clientId,
          redirectUrl,
          issuer: _issuer,
          scopes: scopes,
          // Google only returns a refresh token when it re-prompts for consent.
          promptValues: const ['consent'],
          additionalParameters: const {'access_type': 'offline'},
        ),
      );
    } catch (e) {
      throw GoogleAuthException(_friendly(e));
    }

    final refresh = response.refreshToken;
    final access = response.accessToken;
    if (refresh == null || access == null) {
      throw const GoogleAuthException(
        "Google n'a pas renvoyé de jeton utilisable. Réessayez en acceptant "
        "toutes les autorisations demandées.",
      );
    }

    final email = emailFromIdToken(response.idToken);
    if (email == null || email.isEmpty) {
      throw const GoogleAuthException(
        "Google n'a pas renvoyé l'adresse du compte.",
      );
    }

    return GoogleSession(
      email: email,
      refreshToken: refresh,
      accessToken: access,
      expiresAt: response.accessTokenExpirationDateTime ??
          DateTime.now().add(const Duration(minutes: 55)),
    );
  }

  /// Returns a usable session, renewing the access token only when needed.
  Future<GoogleSession> refreshed(GoogleSession session) async {
    if (!session.isStale) return session;
    try {
      final response = await _auth.token(
        TokenRequest(
          clientId,
          redirectUrl,
          issuer: _issuer,
          scopes: scopes,
          refreshToken: session.refreshToken,
          grantType: 'refresh_token',
        ),
      );
      final access = response.accessToken;
      if (access == null) {
        throw const GoogleAuthException('Jeton Google non renouvelé.');
      }
      return session.copyWith(
        accessToken: access,
        // Google usually keeps the same refresh token; honour a new one.
        refreshToken: response.refreshToken,
        expiresAt: response.accessTokenExpirationDateTime ??
            DateTime.now().add(const Duration(minutes: 55)),
      );
    } catch (e) {
      throw GoogleAuthException(_friendly(e));
    }
  }

  /// The id_token comes straight from Google's token endpoint over TLS, so its
  /// claims are read directly for the address to log in with. It never arrives
  /// from the browser and is never used as a trust assertion.
  static String? emailFromIdToken(String? idToken) {
    if (idToken == null) return null;
    try {
      final parts = idToken.split('.');
      if (parts.length < 2) return null;
      final payload = utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
      final claims = jsonDecode(payload) as Map<String, dynamic>;
      return claims['email'] as String?;
    } catch (_) {
      return null;
    }
  }

  static String _friendly(Object error) {
    final text = error.toString().toLowerCase();
    if (text.contains('cancel')) {
      return 'Connexion Google annulée.';
    }
    if (text.contains('invalid_grant') || text.contains('expired')) {
      // Testing-mode refresh tokens die after seven days; this is the message
      // testers will see most often.
      return "L'autorisation Google a expiré. Reconnectez-vous.";
    }
    if (text.contains('network') || text.contains('socket')) {
      return 'Impossible de joindre Google. Vérifiez votre connexion.';
    }
    return 'La connexion Google a échoué.';
  }
}
