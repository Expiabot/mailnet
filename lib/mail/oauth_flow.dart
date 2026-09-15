import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

/// Everything that differs between one OAuth provider and another.
@immutable
class OAuthProvider {
  const OAuthProvider({
    required this.id,
    required this.label,
    required this.clientId,
    required this.authorizeEndpoint,
    required this.tokenEndpoint,
    required this.scopes,
    required this.redirectUri,
    required this.imapHost,
    this.imapPort = 993,
    this.extraAuthParams = const {},
  });

  /// Stable key: names the stored session and the pending sign-in.
  final String id;
  final String label;
  final String clientId;
  final Uri authorizeEndpoint;
  final Uri tokenEndpoint;
  final String scopes;
  final String redirectUri;
  final String imapHost;
  final int imapPort;

  /// Provider quirks — Google needs `access_type=offline` to hand back a
  /// refresh token at all; Microsoft gets there through `offline_access`.
  final Map<String, String> extraAuthParams;

  bool get isConfigured => clientId.isNotEmpty;
}

/// A signed-in account. The refresh token is the durable part; the access token
/// is short-lived and renewed on demand.
@immutable
class OAuthSession {
  const OAuthSession({
    required this.providerId,
    required this.email,
    required this.refreshToken,
    required this.accessToken,
    required this.expiresAt,
  });

  final String providerId;
  final String email;
  final String refreshToken;
  final String accessToken;
  final DateTime expiresAt;

  /// Renewed a little early: an hour-long token must not die in the middle of
  /// a long deletion.
  bool get isStale =>
      DateTime.now().isAfter(expiresAt.subtract(const Duration(minutes: 2)));

  OAuthSession copyWith({
    String? refreshToken,
    String? accessToken,
    DateTime? expiresAt,
  }) =>
      OAuthSession(
        providerId: providerId,
        email: email,
        refreshToken: refreshToken ?? this.refreshToken,
        accessToken: accessToken ?? this.accessToken,
        expiresAt: expiresAt ?? this.expiresAt,
      );

  Map<String, dynamic> toJson() => {
        'providerId': providerId,
        'email': email,
        'refreshToken': refreshToken,
        'accessToken': accessToken,
        'expiresAt': expiresAt.toIso8601String(),
      };

  static OAuthSession? fromJson(Map<String, dynamic> json) {
    final email = json['email'] as String?;
    final refresh = json['refreshToken'] as String?;
    if (email == null || refresh == null) return null;
    return OAuthSession(
      providerId: json['providerId'] as String? ?? 'google',
      email: email,
      refreshToken: refresh,
      accessToken: json['accessToken'] as String? ?? '',
      expiresAt:
          DateTime.tryParse(json['expiresAt'] as String? ?? '') ?? DateTime(2000),
    );
  }
}

class OAuthException implements Exception {
  const OAuthException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// The half-finished state of a sign-in: everything needed to complete the
/// exchange once the browser comes back.
///
/// Written to disk *before* the browser opens. Android kills the app while the
/// consent screen is in front — reproducibly on Samsung — so the flow has to
/// survive its own process dying.
@immutable
class PendingAuth {
  const PendingAuth({
    required this.providerId,
    required this.state,
    required this.codeVerifier,
  });

  final String providerId;
  final String state;
  final String codeVerifier;

  Map<String, dynamic> toJson() => {
        'providerId': providerId,
        'state': state,
        'codeVerifier': codeVerifier,
      };

  static PendingAuth? fromJson(Map<String, dynamic> json) {
    final state = json['state'] as String?;
    final verifier = json['codeVerifier'] as String?;
    if (state == null || verifier == null) return null;
    return PendingAuth(
      providerId: json['providerId'] as String? ?? 'google',
      state: state,
      codeVerifier: verifier,
    );
  }
}

/// Authorization-code flow with PKCE, split so it can survive a process death.
///
/// Hand-rolled rather than delegating to AppAuth: AppAuth holds the pending
/// request in memory, so being killed between "open the browser" and "come
/// back" loses it and reports a cancellation the user never made.
class OAuthFlow {
  const OAuthFlow(this.provider, {this.httpClient, this.launcher});

  final OAuthProvider provider;

  /// Injectable for tests.
  final http.Client? httpClient;
  final Future<bool> Function(Uri uri)? launcher;

  // ---------------------------------------------------------------------
  // Step 1 — open the browser
  // ---------------------------------------------------------------------

  /// Builds the state to persist and the URL to open. The caller must save the
  /// [PendingAuth] *before* launching, or a process death loses the flow.
  (PendingAuth, Uri) beginSignIn({Random? random}) {
    if (!provider.isConfigured) {
      throw OAuthException(
        'Connexion ${provider.label} non configurée dans cette version.',
      );
    }
    final rng = random ?? Random.secure();
    final verifier = _randomString(rng, 64);
    final state = _randomString(rng, 24);
    final challenge = base64Url
        .encode(sha256.convert(ascii.encode(verifier)).bytes)
        .replaceAll('=', '');

    final url = provider.authorizeEndpoint.replace(queryParameters: {
      'client_id': provider.clientId,
      'redirect_uri': provider.redirectUri,
      'response_type': 'code',
      'scope': provider.scopes,
      'code_challenge': challenge,
      'code_challenge_method': 'S256',
      'state': state,
      ...provider.extraAuthParams,
    });

    return (
      PendingAuth(
        providerId: provider.id,
        state: state,
        codeVerifier: verifier,
      ),
      url,
    );
  }

  Future<void> openBrowser(Uri url) async {
    final open = launcher ??
        (Uri u) => launchUrl(u, mode: LaunchMode.externalApplication);
    if (!await open(url)) {
      throw const OAuthException("Impossible d'ouvrir le navigateur.");
    }
  }

  // ---------------------------------------------------------------------
  // Step 2 — the browser comes back
  // ---------------------------------------------------------------------

  /// Does this redirect belong to this provider?
  bool isRedirect(Uri uri) {
    final expected = Uri.parse(provider.redirectUri);
    if (uri.scheme.toLowerCase() != expected.scheme.toLowerCase()) return false;
    // Google's scheme is unique per client, so the scheme alone identifies it.
    // Microsoft shares `msauth` across apps and puts the package in the host.
    if (expected.host.isEmpty) return true;
    return uri.host.toLowerCase() == expected.host.toLowerCase();
  }

  /// Completes the exchange from the redirect the provider sent back.
  Future<OAuthSession> completeSignIn(Uri redirect, PendingAuth pending) async {
    final error = redirect.queryParameters['error'];
    if (error != null) {
      throw OAuthException(
        error == 'access_denied'
            ? "Vous avez refusé l'accès à votre messagerie."
            : '${provider.label} a refusé la demande ($error).',
      );
    }

    if (redirect.queryParameters['state'] != pending.state) {
      throw const OAuthException(
        'Réponse inattendue du fournisseur. Relancez la connexion.',
      );
    }

    final code = redirect.queryParameters['code'];
    if (code == null) {
      throw OAuthException("${provider.label} n'a pas renvoyé de code.");
    }

    final tokens = await _post({
      'client_id': provider.clientId,
      'code': code,
      'code_verifier': pending.codeVerifier,
      'grant_type': 'authorization_code',
      'redirect_uri': provider.redirectUri,
    });

    final refresh = tokens['refresh_token'] as String?;
    final access = tokens['access_token'] as String?;
    if (refresh == null || access == null) {
      throw const OAuthException(
        "Aucun jeton utilisable n'a été renvoyé. Réessayez en acceptant "
        'toutes les autorisations demandées.',
      );
    }

    final email = emailFromIdToken(tokens['id_token'] as String?);
    if (email == null || email.isEmpty) {
      throw OAuthException(
        "${provider.label} n'a pas renvoyé l'adresse du compte.",
      );
    }

    return OAuthSession(
      providerId: provider.id,
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
  Future<OAuthSession> refreshed(OAuthSession session) async {
    if (!session.isStale) return session;
    final tokens = await _post({
      'client_id': provider.clientId,
      'refresh_token': session.refreshToken,
      'grant_type': 'refresh_token',
      // Microsoft wants the scopes again on refresh; Google ignores them.
      'scope': provider.scopes,
    });
    final access = tokens['access_token'] as String?;
    if (access == null) {
      throw const OAuthException('Jeton non renouvelé.');
    }
    return session.copyWith(
      accessToken: access,
      // Usually the same refresh token comes back; honour a new one.
      refreshToken: tokens['refresh_token'] as String?,
      expiresAt: _expiry(tokens),
    );
  }

  Future<Map<String, dynamic>> _post(Map<String, String> body) async {
    final client = httpClient ?? http.Client();
    try {
      final response = await client
          .post(provider.tokenEndpoint, body: body)
          .timeout(const Duration(seconds: 30));
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode >= 400) {
        final code = decoded['error'] as String? ?? 'erreur';
        if (code == 'invalid_grant') {
          // Google's testing-mode refresh tokens die after seven days; this is
          // the message testers will see most often.
          throw const OAuthException(
            "L'autorisation a expiré. Reconnectez-vous.",
          );
        }
        throw OAuthException('${provider.label} a refusé la demande ($code).');
      }
      return decoded;
    } on OAuthException {
      rethrow;
    } catch (e) {
      debugPrint('[mailnet] échange de jeton ${provider.id}: $e');
      throw OAuthException(
        'Impossible de joindre ${provider.label}. Vérifiez votre connexion.',
      );
    } finally {
      if (httpClient == null) client.close();
    }
  }

  static DateTime _expiry(Map<String, dynamic> tokens) {
    final seconds = tokens['expires_in'];
    final value =
        seconds is int ? seconds : int.tryParse('${seconds ?? ''}') ?? 3300;
    return DateTime.now().add(Duration(seconds: value));
  }

  /// The id_token comes straight from the token endpoint over TLS, so its
  /// claims are read directly for the address to log in with. It never arrives
  /// from the browser and is never used as a trust assertion.
  ///
  /// Google puts the address in `email`; Microsoft usually in
  /// `preferred_username`.
  static String? emailFromIdToken(String? idToken) {
    if (idToken == null) return null;
    try {
      final parts = idToken.split('.');
      if (parts.length < 2) return null;
      final payload =
          utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
      final claims = jsonDecode(payload) as Map<String, dynamic>;
      for (final key in ['email', 'preferred_username', 'upn']) {
        final value = claims[key];
        if (value is String && value.contains('@')) return value;
      }
      return null;
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
