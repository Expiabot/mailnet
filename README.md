# 🧹 MailNet

**Faites de la place dans votre boîte mail, depuis votre téléphone.**

MailNet se connecte à votre boîte mail en IMAP pour supprimer des messages en masse.
Il n'y a **aucun serveur** : le téléphone parle directement à votre fournisseur. Aucun
identifiant, aucun message, aucune statistique d'usage ne transite par un tiers — et le
code est ici pour le vérifier.

## Ce que fait l'application

- **Qui vous écrit le plus** — classe un dossier par expéditeur, avec le nombre de mails,
  la place occupée, et le désabonnement quand l'expéditeur en propose un
  (`List-Unsubscribe`, y compris le one-click de la RFC 8058).
- **Filtres** — expéditeur, objet, ancienneté, taille, non lus, pièce jointe.
- **Suppression par lots** — vers la corbeille par défaut, définitive sur demande
  explicite. La progression est réelle et l'opération continue si vous quittez l'écran.

## Confidentialité

- Les identifiants vivent dans le **Keystore Android** / **Trousseau iOS**, jamais ailleurs.
- Seuls les **en-têtes** des messages sont lus, avec `BODY.PEEK` — rien n'est marqué comme lu.
- Aucune dépendance de mesure d'audience. Les seules connexions sortantes sont votre serveur
  IMAP, et le serveur de désabonnement d'un expéditeur lorsque vous appuyez sur le bouton.

La [politique de confidentialité complète](docs/privacy.html) détaille chaque point.

## Développement

```bash
flutter pub get
flutter test        # 58 tests, sans réseau ni boîte mail
flutter run
```

L'architecture sépare la logique IMAP (`lib/mail/`) de l'interface (`lib/screens/`).
`ImapGateway` est une interface : les tests substituent un serveur IMAP en mémoire, ce qui
permet de vérifier les coupures réseau, les suppressions partielles et les plafonds sans
toucher à une vraie boîte.

Pour produire une version signée, placez un fichier `android/key.properties` (voir
`android/app/build.gradle.kts`). Sans lui, la compilation retombe sur la clé de debug.

## Licence

À définir.
