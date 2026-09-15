import 'dart:async';

import 'package:flutter/material.dart';

import '../mail/enough_mail_gateway.dart';
import '../mail/oauth_flow.dart';
import '../mail/oauth_providers.dart';
import '../mail/mail_service.dart';
import '../mail/models.dart';
import '../providers.dart';
import '../storage/account_store.dart';
import '../ui/theme.dart';
import 'filters_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _host = TextEditingController();
  final _port = TextEditingController(text: '993');
  final _store = AccountStore();

  String _providerId = 'gmail';
  bool _remember = true;
  bool _obscure = true;
  bool _busy = false;
  String? _error;
  String? _errorDetail;
  bool _restoring = true;

  MailProvider get _provider => providerById(_providerId);

  /// The OAuth provider matching the picked mail provider, when the build
  /// carries a client id for it.
  OAuthProvider? get _oauth {
    final id = _provider.oauthProviderId;
    if (id == null) return null;
    for (final candidate in OAuthProviders.configured) {
      if (candidate.id == id) return candidate;
    }
    return null;
  }

  final _redirects = RedirectListener();
  StreamSubscription<Uri>? _redirectSub;

  @override
  void initState() {
    super.initState();
    _restore();
    _watchForRedirect();
  }

  Future<void> _watchForRedirect() async {
    _redirectSub = _redirects.links.listen(_completeOAuth);
    // The app may have been killed during consent and relaunched *by* the
    // redirect; that arrives here rather than on the stream.
    final initial = await _redirects.initialLink();
    if (initial != null) await _completeOAuth(initial);
  }

  Future<void> _restore() async {
    // A remembered OAuth account skips the browser entirely: the refresh token
    // in the keystore is enough to mint a new access token.
    final session = await _store.readOAuth();
    if (session != null && await _resumeOAuth(session)) return;

    final saved = await _store.read();
    if (!mounted) return;
    setState(() {
      if (saved != null) {
        _providerId = saved.providerId;
        _email.text = saved.email;
        _password.text = saved.password;
        _host.text = saved.host;
        _port.text = saved.port.toString();
      }
      _restoring = false;
    });
  }

  /// Reopens a remembered OAuth mailbox without any user interaction.
  ///
  /// Returns false when the stored authorisation is no longer usable — which
  /// is what happens every seven days while the Google project sits in testing
  /// mode, since a refresh token cannot itself be refreshed.
  Future<bool> _resumeOAuth(OAuthSession session) async {
    OAuthProvider? provider;
    for (final candidate in OAuthProviders.configured) {
      if (candidate.id == session.providerId) provider = candidate;
    }
    if (provider == null) return false;

    final flow = OAuthFlow(provider);
    final gateway = EnoughMailGateway();
    try {
      var live = await flow.refreshed(session);
      await _store.saveOAuth(live);

      final service = MailService(
        gateway: gateway,
        account: MailAccount(
          host: provider.imapHost,
          port: provider.imapPort,
          user: live.email,
        ),
        credentials: () async {
          live = await flow.refreshed(live);
          await _store.saveOAuth(live);
          return OAuthCredentials(live.accessToken);
        },
      );

      final folders = await service.loadFolders();
      if (!mounted) return false;
      setState(() => _restoring = false);

      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => FiltersScreen(
            service: service,
            email: live.email,
            listing: folders,
          ),
        ),
      );
      await service.disconnect();
      return true;
    } catch (e) {
      debugPrint('[mailnet] session ${session.providerId} non reprise: $e');
      await gateway.disconnect();
      // The stored authorisation is spent; make the user sign in again rather
      // than retrying it on every launch.
      await _store.clearOAuth();
      if (!mounted) return false;
      setState(() {
        _restoring = false;
        _providerId = session.providerId == 'microsoft' ? 'outlook' : 'gmail';
        _error = e is OAuthException
            ? e.message
            : "La connexion mémorisée n'est plus valide. Reconnectez-vous.";
      });
      return true;
    }
  }

  @override
  void dispose() {
    _redirectSub?.cancel();
    _email.dispose();
    _password.dispose();
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();

    final provider = _provider;
    final host = provider.isCustom ? _host.text.trim() : provider.host;
    final port = provider.isCustom ? int.tryParse(_port.text) ?? 993 : provider.port;
    final email = _email.text.trim();

    // App passwords are shown in groups of four; people paste them with the
    // spaces. Try it as typed, then without — same trick as the web version.
    final typed = _password.text;
    final attempts = <String>[
      typed,
      if (typed.contains(RegExp(r'\s'))) typed.replaceAll(RegExp(r'\s+'), ''),
    ];

    setState(() {
      _busy = true;
      _error = null;
      _errorDetail = null;
    });

    Object? lastError;
    for (final password in attempts) {
      final gateway = EnoughMailGateway();
      final service = MailService(
        gateway: gateway,
        account: MailAccount(host: host, port: port, user: email),
        credentials: () async => PasswordCredentials(password),
      );
      try {
        final folders = await service.loadFolders();
        if (_remember) {
          await _store.save(SavedAccount(
            providerId: _providerId,
            host: host,
            port: port,
            email: email,
            password: password,
          ));
        } else {
          await _store.clear();
        }
        if (!mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => FiltersScreen(
              service: service,
              email: email,
              listing: folders,
            ),
          ),
        );
        await service.disconnect();
        if (mounted) setState(() => _busy = false);
        return;
      } catch (e) {
        // The server's own words are what actually diagnose a refused login;
        // they reach logcat as well as the screen.
        debugPrint('[mailnet] échec de connexion: $e');
        lastError = e;
        await gateway.disconnect();
      }
    }

    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = _friendlyError(lastError);
      _errorDetail = lastError?.toString();
    });
  }

  /// Starts the Google flow: persist what is needed to finish, then hand over
  /// to the browser.
  ///
  /// Nothing is awaited here. Android kills this app while the consent screen
  /// is in front, so the second half runs in [_completeOAuth] — possibly in a
  /// brand-new process.
  Future<void> _startOAuth() async {
    final oauth = _oauth;
    if (oauth == null) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
      _errorDetail = null;
    });
    try {
      final (pending, url) = OAuthFlow(oauth).beginSignIn();
      await _store.savePending(pending);
      await OAuthFlow(oauth).openBrowser(url);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e is OAuthException ? e.message : _friendlyError(e);
        _errorDetail = e.toString();
      });
    }
  }

  /// Second half of the flow, triggered by the redirect — on a fresh launch or
  /// while the app is still running.
  Future<void> _completeOAuth(Uri redirect) async {
    final pending = await _store.readPending();
    OAuthProvider? matched;
    for (final candidate in OAuthProviders.configured) {
      if (OAuthFlow(candidate).isRedirect(redirect)) matched = candidate;
    }
    if (matched == null) return;
    final flow = OAuthFlow(matched);
    if (pending == null || pending.providerId != matched.id) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Connexion ${matched!.label} interrompue. Réessayez.';
      });
      return;
    }
    await _store.clearPending();
    if (!mounted) return;
    setState(() => _busy = true);

    final gateway = EnoughMailGateway();
    try {
      var session = await flow.completeSignIn(redirect, pending);

      final service = MailService(
        gateway: gateway,
        account: MailAccount(
          host: matched.imapHost,
          port: matched.imapPort,
          user: session.email,
        ),
        // A callback, not a fixed token: every reconnection re-reads it, so a
        // token expiring mid-deletion is renewed without the user noticing.
        credentials: () async {
          session = await flow.refreshed(session);
          await _store.saveOAuth(session);
          return OAuthCredentials(session.accessToken);
        },
      );

      final folders = await service.loadFolders();
      if (_remember) {
        await _store.saveOAuth(session);
      } else {
        await _store.clearOAuth();
      }
      if (!mounted) return;

      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => FiltersScreen(
            service: service,
            email: session.email,
            listing: folders,
          ),
        ),
      );
      await service.disconnect();
      if (mounted) setState(() => _busy = false);
    } catch (e) {
      debugPrint('[mailnet] échec de connexion ${matched.id}: \$e');
      await gateway.disconnect();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e is OAuthException ? e.message : _friendlyError(e);
        _errorDetail = e.toString();
      });
    }
  }

  static String _friendlyError(Object? error) {
    final text = error.toString().toLowerCase();
    if (error is MailAuthException ||
        text.contains('invalid credentials') ||
        text.contains('authenticationfail') ||
        text.contains('login failed')) {
      return "Identifiants refusés par le serveur. Pour Gmail, Yahoo ou iCloud, "
          "il faut un mot de passe d'application, pas votre mot de passe habituel.";
    }
    if (text.contains('socket') ||
        text.contains('timeout') ||
        text.contains('failed host lookup') ||
        text.contains('network')) {
      return 'Impossible de joindre le serveur. Vérifiez le nom du serveur IMAP '
          'et votre connexion internet.';
    }
    return 'La connexion au serveur de messagerie a échoué.';
  }

  @override
  Widget build(BuildContext context) {
    final provider = _provider;
    final blocked = provider.requiresOAuth;

    return Scaffold(
      body: SafeArea(
        child: _restoring
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
                children: [
                  const _Header(),
                  const SizedBox(height: 28),
                  Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const _Label('Fournisseur'),
                        DropdownButtonFormField<String>(
                          initialValue: _providerId,
                          isExpanded: true,
                          items: [
                            for (final p in kProviders)
                              DropdownMenuItem(value: p.id, child: Text(p.label)),
                          ],
                          onChanged: _busy
                              ? null
                              : (value) => setState(() {
                                    _providerId = value ?? 'gmail';
                                    _error = null;
                                  }),
                        ),
                        if (provider.isCustom) ...[
                          const SizedBox(height: 16),
                          const _Label('Serveur IMAP'),
                          TextFormField(
                            controller: _host,
                            decoration: const InputDecoration(
                              hintText: 'imap.exemple.fr',
                            ),
                            autocorrect: false,
                            validator: (v) => (v == null || v.trim().isEmpty)
                                ? 'Serveur requis'
                                : null,
                          ),
                          const SizedBox(height: 16),
                          const _Label('Port'),
                          TextFormField(
                            controller: _port,
                            keyboardType: TextInputType.number,
                          ),
                        ],
                        const SizedBox(height: 16),
                        const _Label('Adresse e-mail'),
                        TextFormField(
                          controller: _email,
                          keyboardType: TextInputType.emailAddress,
                          autocorrect: false,
                          decoration: const InputDecoration(
                            hintText: 'vous@exemple.fr',
                          ),
                          validator: (v) => (v == null || !v.contains('@'))
                              ? 'Adresse e-mail invalide'
                              : null,
                        ),
                        const SizedBox(height: 16),
                        const _Label('Mot de passe'),
                        TextFormField(
                          controller: _password,
                          obscureText: _obscure,
                          autocorrect: false,
                          enableSuggestions: false,
                          decoration: InputDecoration(
                            hintText: "Mot de passe ou mot de passe d'application",
                            suffixIcon: IconButton(
                              icon: Icon(_obscure
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined),
                              tooltip: _obscure ? 'Afficher' : 'Masquer',
                              onPressed: () =>
                                  setState(() => _obscure = !_obscure),
                            ),
                          ),
                          validator: (v) => (v == null || v.isEmpty)
                              ? 'Mot de passe requis'
                              : null,
                        ),
                        if (_oauth != null) ...[
                          const SizedBox(height: 20),
                          _OAuthButton(
                            provider: _oauth!,
                            onPressed: _busy ? null : _startOAuth,
                          ),
                          const SizedBox(height: 18),
                          Row(
                            children: [
                              const Expanded(child: Divider()),
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 12),
                                child: Text(
                                  'ou avec un mot de passe',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                                ),
                              ),
                              const Expanded(child: Divider()),
                            ],
                          ),
                        ],
                        if (provider.hint.isNotEmpty) ...[
                          const SizedBox(height: 16),
                          NoticeBox(
                            text: provider.hint,
                            tone: blocked
                                ? NoticeTone.warning
                                : NoticeTone.info,
                            icon: blocked
                                ? Icons.warning_amber_rounded
                                : Icons.info_outline,
                          ),
                        ],
                        const SizedBox(height: 4),
                        SwitchListTile(
                          value: _remember,
                          onChanged: _busy
                              ? null
                              : (v) => setState(() => _remember = v),
                          title: const Text('Mémoriser ce compte'),
                          subtitle: const Text(
                            'Conservé chiffré sur le téléphone uniquement',
                            style: TextStyle(fontSize: 12),
                          ),
                          contentPadding: EdgeInsets.zero,
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: 8),
                          NoticeBox(
                            text: _error!,
                            tone: NoticeTone.danger,
                            icon: Icons.error_outline,
                          ),
                          if (_errorDetail != null)
                            _TechnicalDetail(text: _errorDetail!),
                        ],
                        const SizedBox(height: 20),
                        FilledButton(
                          onPressed: (_busy || blocked) ? null : _connect,
                          child: _busy
                              ? const SizedBox(
                                  height: 22,
                                  width: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                    color: Colors.white,
                                  ),
                                )
                              : const Text('Se connecter'),
                        ),
                        const SizedBox(height: 20),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.lock_outline,
                                size: 15,
                                color: Theme.of(context).colorScheme.outline),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                'Votre téléphone parle directement à votre '
                                'fournisseur. Aucun identifiant, aucun message '
                                'ne transite par un de nos serveurs.',
                                style: TextStyle(
                                  fontSize: 12,
                                  height: 1.4,
                                  color: Theme.of(context).colorScheme.outline,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                Icons.cleaning_services_outlined,
                color: Theme.of(context).colorScheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(width: 12),
            Text(
              'MailNet',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          'Faites de la place dans votre boîte mail.',
          style: TextStyle(
            fontSize: 15,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// Both providers ask for a white button carrying their own mark and the
/// wording their brand guidelines require.
class _OAuthButton extends StatelessWidget {
  const _OAuthButton({required this.provider, required this.onPressed});

  final OAuthProvider provider;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => FilledButton.icon(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: Colors.white,
          foregroundColor: const Color(0xFF1F1F1F),
          disabledBackgroundColor: Colors.white70,
        ),
        icon: provider.id == 'microsoft'
            ? const _MicrosoftMark()
            : const _GoogleMark(),
        label: Text('Se connecter avec ${provider.label}'),
      );
}

/// Microsoft's four squares, drawn rather than bundled.
class _MicrosoftMark extends StatelessWidget {
  const _MicrosoftMark();

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 20,
        height: 20,
        child: GridView.count(
          crossAxisCount: 2,
          mainAxisSpacing: 2,
          crossAxisSpacing: 2,
          physics: const NeverScrollableScrollPhysics(),
          children: const [
            ColoredBox(color: Color(0xFFF25022)),
            ColoredBox(color: Color(0xFF7FBA00)),
            ColoredBox(color: Color(0xFF00A4EF)),
            ColoredBox(color: Color(0xFFFFB900)),
          ],
        ),
      );
}

/// Drawn rather than fetched: the app must keep working with no outside
/// request, and a bundled logo would be one more asset to license.
class _GoogleMark extends StatelessWidget {
  const _GoogleMark();

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 20,
        height: 20,
        child: CustomPaint(painter: _GoogleMarkPainter()),
      );
}

class _GoogleMarkPainter extends CustomPainter {
  static const _blue = Color(0xFF4285F4);
  static const _red = Color(0xFFEA4335);
  static const _yellow = Color(0xFFFBBC05);
  static const _green = Color(0xFF34A853);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final stroke = size.width * 0.26;
    final inner = rect.deflate(stroke / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.butt;

    // Four arcs of the ring, then the bar that closes the G.
    const quarter = 1.5707963;
    for (final (start, colour) in [
      (-quarter * 0.35, _red),
      (quarter * 0.75, _green),
      (quarter * 2.1, _yellow),
      (quarter * 3.2, _blue),
    ]) {
      canvas.drawArc(inner, start, quarter * 0.95, false, paint..color = colour);
    }
    canvas.drawRect(
      Rect.fromLTRB(size.width * 0.52, size.height * 0.40,
          size.width * 1.0, size.height * 0.60),
      Paint()..color = _blue,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// The server's verbatim reply, folded away until tapped. Ugly on purpose —
/// it is the only thing that tells a refused password from a blocked port.
class _TechnicalDetail extends StatelessWidget {
  const _TechnicalDetail({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 8),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        title: Text(
          'Détail technique',
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
        children: [
          SelectableText(
            text,
            style: TextStyle(
              fontSize: 11,
              fontFamily: 'monospace',
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
}
