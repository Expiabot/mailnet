import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:app_links/app_links.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

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
  bool get isStale =>
      DateTime.now().isAfter(expiresAt.subtract(const Duration(minutes: 2)));

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

/// The half-finished state of a sign-in: everything needed to complete the
/// exchange once Google sends the browser back.
///
/// This is written to disk *before* the browser opens. Android kills the app
/// while the consent screen is in front — reproducibly, on Samsung — so the
/// flow has to survive its own process dying.
@immutable
class PendingAuth {
  const PendingAuth({required this.state, required this.codeVerifier});

  final String state;
  final String codeVerifier;

  Map<String, dynamic> toJson() =>
      {'state': state, 'codeVerifier': codeVerifier};

  static PendingAuth? fromJson(Map<String, dynamic> json) {
    final state = json['state'] as String?;
    final verifier = json['codeVerifier'] as String?;
    if (state == null || verifier == null) return null;
    return PendingAuth(state: state, codeVerifier: verifier);
  }
}

/// Signs in to Google and keeps an IMAP-capable access token alive.
///
/// Hand-rolled rather than delegating to AppAuth: AppAuth holds the pending
/// request in memory, so a process death between "open the browser" and "come
/// back" loses it and reports a cancellation the user never made. Here the
/// verifier lives in the keystore and the exchange is a plain HTTPS POST, so
/// the app can be killed and restarted mid-flow without noticing.
class GoogleAuth {
  const GoogleAuth({
    required this.clientId,
    this.httpClient,
    this.launcher,
  });

  /// Supplied at build time: `--dart-define=GOOGLE_CLIENT_ID=...`
  static const configured =
      String.fromEnvironment('GOOGLE_CLIENT_ID', defaultValue: '');

  static final authorizeEndpoint =
      Uri.parse('https://accounts.google.com/o/oauth2/v2/auth');
  static final tokenEndpoint = Uri.parse('https://oauth2.googleapis.com/token');

  /// `mail.google.com` is the only scope that grants IMAP. It is a *restricted*
  /// scope: unlimited use needs Google verification and an annual CASA audit.
  /// Until then the Cloud project stays in testing, capped at 100 declared
  /// accounts.
  static const scopes = 'openid email https://mail.google.com/';

  final String clientId;

  /// Injectable for tests.
  final http.Client? httpClient;
  final Future<bool> Function(Uri uri)? launcher;

  bool get isConfigured => clientId.isNotEmpty;

  /// Google's installed-app redirect: the client id, reversed into a scheme.
  /// Nothing is hosted anywhere — the scheme reopens this app.
  String get redirectUri => '${reverseClientId(clientId)}:/oauth2redirect';

  /// `123-abc.apps.googleusercontent.com` → `com.googleusercontent.apps.123-abc`
  static String reverseClientId(String clientId) {
    const suffix = '.apps.googleusercontent.com';
    final id = clientId.endsWith(suffix)
        ? clientId.substring(0, clientId.length - suffix.length)
        : clientId;
    return 'com.googleusercontent.apps.$id';
  }

  // ---------------------------------------------------------------------
  // Step 1 — open the browser
  // ---------------------------------------------------------------------

  /// Builds the state to persist and the URL to open. The caller must save the
  /// [PendingAuth] *before* launching, or a process death loses the flow.
  (PendingAuth, Uri) beginSignIn({Random? random}) {
    if (!isConfigured) {
      throw const GoogleAuthException(
        "Connexion Google non configurée dans cette version de l'application.",
      );
    }
    final rng = random ?? Random.secure();
    final verifier = _randomString(rng, 64);
    final state = _randomString(rng, 24);
    final challenge = base64Url
        .encode(sha256.convert(ascii.encode(verifier)).bytes)
        .replaceAll('=', '');

    final url = authorizeEndpoint.replace(queryParameters: {
      'client_id': clientId,
      'redirect_uri': redirectUri,
      'response_type': 'code',
      'scope': scopes,
      'code_challenge': challenge,
      'code_challenge_method': 'S256',
      'state': state,
      // Google only returns a refresh token when it re-prompts for consent.
      'prompt': 'consent',
      'access_type': 'offline',
    });

    return (PendingAuth(state: state, codeVerifier: verifier), url);
  }

  Future<void> openBrowser(Uri url) async {
    final open = launcher ??
        (Uri u) => launchUrl(u, mode: LaunchMode.externalApplication);
    if (!await open(url)) {
      throw const GoogleAuthException("Impossible d'ouvrir le navigateur.");
    }
  }

  // ---------------------------------------------------------------------
  // Step 2 — the browser comes back
  // ---------------------------------------------------------------------

  /// Does the redirect belong to us?
  bool isRedirect(Uri uri) =>
      uri.scheme.toLowerCase() == reverseClientId(clientId).toLowerCase();

  /// Completes the exchange from the redirect Google sent back.
  ///
  /// Throws [GoogleAuthException] with a message fit to show the user.
  Future<GoogleSession> completeSignIn(Uri redirect, PendingAuth pending) async {
    final error = redirect.queryParameters['error'];
    if (error != null) {
      throw GoogleAuthException(
        error == 'access_denied'
            ? "Vous avez refusé l'accès à Gmail."
            : 'Google a refusé la demande ($error).',
      );
    }

    final returnedState = redirect.queryParameters['state'];
    if (returnedState != pending.state) {
      throw const GoogleAuthException(
        'Réponse Google inattendue. Relancez la connexion.',
      );
    }

    final code = redirect.queryParameters['code'];
    if (code == null) {
      throw const GoogleAuthException("Google n'a pas renvoyé de code.");
    }

    final tokens = await _post({
      'client_id': clientId,
      'code': code,
      'code_verifier': pending.codeVerifier,
      'grant_type': 'authorization_code',
      'redirect_uri': redirectUri,
    });

    final refresh = tokens['refresh_token'] as String?;
    final access = tokens['access_token'] as String?;
    if (refresh == null || access == null) {
      throw const GoogleAuthException(
        "Google n'a pas renvoyé de jeton utilisable. Réessayez en acceptant "
        "toutes les autorisations demandées.",
      );
    }

    final email = emailFromIdToken(tokens['id_token'] as String?);
    if (email == null || email.isEmpty) {
      throw const GoogleAuthException(
        "Google n'a pas renvoyé l'adresse du compte.",
      );
    }

    return GoogleSession(
      email: email,
      refreshToken: refresh,
      accessToken: access,
      expiresAt: _expiry(tokens),
    );
  }

  // ---------------------------------------------------------------------
  // Keeping it alive
  // ---------------------------------------------------------------------

  /// Returns a usable session, renewing the access token only when needed.
  Future<GoogleSession> refreshed(GoogleSession session) async {
    if (!session.isStale) return session;
    final tokens = await _post({
      'client_id': clientId,
      'refresh_token': session.refreshToken,
      'grant_type': 'refresh_token',
    });
    final access = tokens['access_token'] as String?;
    if (access == null) {
      throw const GoogleAuthException('Jeton Google non renouvelé.');
    }
    return session.copyWith(
      accessToken: access,
      // Google usually keeps the same refresh token; honour a new one.
      refreshToken: tokens['refresh_token'] as String?,
      expiresAt: _expiry(tokens),
    );
  }

  Future<Map<String, dynamic>> _post(Map<String, String> body) async {
    final client = httpClient ?? http.Client();
    try {
      final response = await client
          .post(tokenEndpoint, body: body)
          .timeout(const Duration(seconds: 30));
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode >= 400) {
        final code = decoded['error'] as String? ?? 'erreur';
        if (code == 'invalid_grant') {
          // Testing-mode refresh tokens die after seven days; this is the
          // message testers will see most often.
          throw const GoogleAuthException(
            "L'autorisation Google a expiré. Reconnectez-vous.",
          );
        }
        throw GoogleAuthException('Google a refusé la demande ($code).');
      }
      return decoded;
    } on GoogleAuthException {
      rethrow;
    } catch (e) {
      debugPrint('[mailnet] échange de jeton Google: $e');
      throw const GoogleAuthException(
        'Impossible de joindre Google. Vérifiez votre connexion.',
      );
    } finally {
      if (httpClient == null) client.close();
    }
  }

  static DateTime _expiry(Map<String, dynamic> tokens) {
    final seconds = tokens['expires_in'];
    final value = seconds is int
        ? seconds
        : int.tryParse('${seconds ?? ''}') ?? 3300;
    return DateTime.now().add(Duration(seconds: value));
  }

  /// The id_token comes straight from Google's token endpoint over TLS, so its
  /// claims are read directly for the address to log in with. It never arrives
  /// from the browser and is never used as a trust assertion.
  static String? emailFromIdToken(String? idToken) {
    if (idToken == null) return null;
    try {
      final parts = idToken.split('.');
      if (parts.length < 2) return null;
      final payload =
          utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
      return (jsonDecode(payload) as Map<String, dynamic>)['email'] as String?;
    } catch (_) {
      return null;
    }
  }

  static const _alphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';

  static String _randomString(Random rng, int length) => List.generate(
        length,
        (_) => _alphabet[rng.nextInt(_alphabet.length)],
      ).join();
}

/// Watches for the browser handing control back, whether the app stayed alive
/// or was killed and restarted.
class RedirectListener {
  RedirectListener([AppLinks? links]) : _links = links ?? AppLinks();

  final AppLinks _links;

  /// The link the app was *launched* with, when Android restarted it to deliver
  /// the redirect. This is the case AppAuth could not handle.
  Future<Uri?> initialLink() => _links.getInitialLink();

  /// Redirects arriving while the app is already running.
  Stream<Uri> get links => _links.uriLinkStream;
}
