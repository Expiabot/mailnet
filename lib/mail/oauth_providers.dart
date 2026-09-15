import 'package:app_links/app_links.dart';

import 'oauth_flow.dart';

/// The two providers that refuse passwords, and how each wants to be asked.
///
/// Client ids arrive at build time — they are public (an installed app gets no
/// secret) but per-installation, so they stay out of the repo:
///
/// ```
/// flutter build apk --release \
///   --dart-define=GOOGLE_CLIENT_ID=... \
///   --dart-define=MICROSOFT_CLIENT_ID=...
/// ```
abstract final class OAuthProviders {
  static const googleClientId =
      String.fromEnvironment('GOOGLE_CLIENT_ID', defaultValue: '');
  static const microsoftClientId =
      String.fromEnvironment('MICROSOFT_CLIENT_ID', defaultValue: '');

  /// Must match the signature hash registered on the Entra Android platform.
  static const microsoftSignatureHash =
      String.fromEnvironment('MICROSOFT_SIGNATURE_HASH', defaultValue: '');

  static const androidPackage = 'fr.mailnet';

  /// `mail.google.com` is the only scope that grants IMAP. It is *restricted*:
  /// unlimited use needs Google verification and an annual CASA audit, so until
  /// then the Cloud project stays in testing, capped at 100 declared accounts.
  static final google = OAuthProvider(
    id: 'google',
    label: 'Google',
    clientId: googleClientId,
    authorizeEndpoint:
        Uri.parse('https://accounts.google.com/o/oauth2/v2/auth'),
    tokenEndpoint: Uri.parse('https://oauth2.googleapis.com/token'),
    scopes: 'openid email https://mail.google.com/',
    // Google's installed-app redirect: the client id, reversed into a scheme.
    redirectUri: '${reverseClientId(googleClientId)}:/oauth2redirect',
    imapHost: 'imap.gmail.com',
    // Google hands back a refresh token only when it re-prompts for consent.
    extraAuthParams: const {'prompt': 'consent', 'access_type': 'offline'},
  );

  /// Microsoft asks for no audit and imposes no test-user cap — the contrast
  /// with Google is the reason Outlook accounts are the easier ones to support.
  static final microsoft = OAuthProvider(
    id: 'microsoft',
    label: 'Microsoft',
    clientId: microsoftClientId,
    authorizeEndpoint: Uri.parse(
        'https://login.microsoftonline.com/common/oauth2/v2.0/authorize'),
    tokenEndpoint:
        Uri.parse('https://login.microsoftonline.com/common/oauth2/v2.0/token'),
    scopes: 'openid email offline_access '
        'https://outlook.office.com/IMAP.AccessAsUser.All',
    // Microsoft's Android redirect: package name, then the base64 of the
    // signing certificate's SHA-1 bytes.
    redirectUri:
        'msauth://$androidPackage/${Uri.encodeComponent(microsoftSignatureHash)}',
    imapHost: 'outlook.office365.com',
  );

  static List<OAuthProvider> get configured =>
      [google, microsoft].where((p) => p.isConfigured).toList();

  /// `123-abc.apps.googleusercontent.com` → `com.googleusercontent.apps.123-abc`
  static String reverseClientId(String clientId) {
    const suffix = '.apps.googleusercontent.com';
    final id = clientId.endsWith(suffix)
        ? clientId.substring(0, clientId.length - suffix.length)
        : clientId;
    return 'com.googleusercontent.apps.$id';
  }
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
