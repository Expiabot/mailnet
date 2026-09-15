/// The mail providers offered on the login screen, ported from `PROVIDERS` in
/// the web server.
class MailProvider {
  const MailProvider({
    required this.id,
    required this.label,
    required this.host,
    this.port = 993,
    this.hint = '',
    this.requiresOAuth = false,
    this.supportsGoogle = false,
    this.isCustom = false,
  });

  final String id;
  final String label;
  final String host;
  final int port;

  /// Shown under the provider picker — mostly "where do I get an app password".
  final String hint;

  /// Microsoft refuses passwords from third-party apps outright. Until the
  /// OAuth flow ships on mobile, saying so beats letting the login fail.
  final bool requiresOAuth;

  /// Offers "Se connecter avec Google" instead of a password, when the build
  /// carries a client id.
  final bool supportsGoogle;

  final bool isCustom;
}

const kProviders = <MailProvider>[
  MailProvider(
    id: 'gmail',
    label: 'Gmail',
    host: 'imap.gmail.com',
    supportsGoogle: true,
    hint: "Gmail refuse votre mot de passe habituel. Activez la validation en "
        "2 étapes, puis créez un mot de passe d'application de 16 caractères "
        "sur myaccount.google.com/apppasswords (avec ou sans les espaces).",
  ),
  MailProvider(
    id: 'outlook',
    label: 'Outlook / Microsoft 365',
    host: 'outlook.office365.com',
    requiresOAuth: true,
    hint: "Microsoft n'accepte plus de mot de passe dans les applications "
        "externes. La connexion « Se connecter avec Microsoft » arrive dans une "
        "prochaine version ; en attendant, utilisez MailNet sur ordinateur pour "
        "ces comptes.",
  ),
  MailProvider(
    id: 'yahoo',
    label: 'Yahoo Mail',
    host: 'imap.mail.yahoo.com',
    hint: "Créez un mot de passe d'application : Yahoo → Sécurité du compte → "
        "« Générer un mot de passe d'application ».",
  ),
  MailProvider(
    id: 'icloud',
    label: 'iCloud',
    host: 'imap.mail.me.com',
    hint: "Créez un mot de passe d'application sur appleid.apple.com → "
        "Connexion et sécurité → Mots de passe d'application.",
  ),
  MailProvider(
    id: 'free',
    label: 'Free',
    host: 'imap.free.fr',
    hint: 'Utilisez le mot de passe de votre boîte mail Free.',
  ),
  MailProvider(
    id: 'orange',
    label: 'Orange',
    host: 'imap.orange.fr',
    hint: 'Utilisez le mot de passe de votre boîte mail Orange.',
  ),
  MailProvider(
    id: 'laposte',
    label: 'La Poste',
    host: 'imap.laposte.net',
    hint: 'Utilisez le mot de passe de votre boîte mail Laposte.net.',
  ),
  MailProvider(
    id: 'sfr',
    label: 'SFR',
    host: 'imap.sfr.fr',
    hint: 'Utilisez le mot de passe de votre boîte mail SFR.',
  ),
  MailProvider(
    id: 'other',
    label: 'Autre (serveur IMAP personnalisé)',
    host: '',
    isCustom: true,
    hint: "Renseignez le serveur IMAP de votre fournisseur, port 993 en "
        "général. Un mot de passe d'application peut être nécessaire.",
  ),
];

MailProvider providerById(String id) =>
    kProviders.firstWhere((p) => p.id == id, orElse: () => kProviders.first);
