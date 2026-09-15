# Connexion Google — configuration

Le bouton « Se connecter avec Google » reste masqué tant que la compilation ne
porte pas d'identifiant client. Voici comment en obtenir un.

> **Aucune URL de redirection à héberger.** Pour un client Android, Google ne
> demande pas d'adresse web : il vous demande le nom de package et l'empreinte
> du certificat de signature. La redirection est un schéma personnalisé dérivé
> de l'identifiant client, qui rouvre l'application.

---

## 1. Choisir le type d'écran de consentement

C'est la décision structurante — elle détermine qui peut se connecter et si les
autorisations expirent.

| | **Interne** | **Externe + Test** |
|---|---|---|
| Disponible si | Le projet appartient à une organisation Google Workspace | Toujours |
| Qui peut se connecter | Tout le domaine, sans déclaration | 100 comptes déclarés un par un |
| Jeton de rafraîchissement | Pas d'expiration liée au statut | **Expire au bout de 7 jours** |
| Écran « application non validée » | Non | Oui — l'utilisateur passe par « Paramètres avancés » |
| Vérification Google et audit CASA | Jamais requis | Non requis en mode Test |

L'expiration à 7 jours est la contrainte qui surprend : en mode Externe + Test,
vos testeurs devront se reconnecter chaque semaine. L'application le gère
proprement — elle affiche « L'autorisation Google a expiré. Reconnectez-vous. »
— mais prévenez-les.

Ni l'un ni l'autre ne dispense de la vérification et de l'audit CASA le jour où
l'application s'adresse au grand public sur le Play Store.

## 2. Créer le projet et l'écran de consentement

1. [console.cloud.google.com](https://console.cloud.google.com) → nouveau projet
2. **API et services** → **Écran de consentement OAuth** → choisir le type
   décidé ci-dessus
3. Renseigner le nom de l'application, l'adresse d'assistance, et l'URL de la
   politique de confidentialité :
   `https://expiabot.github.io/mailnet/privacy.html`
4. **Ajouter ou supprimer des champs d'application** → saisir manuellement :
   ```
   https://mail.google.com/
   ```
   Google le signale comme **restreint** : c'est normal, c'est le seul champ qui
   donne accès à l'IMAP.
5. En mode Externe : onglet **Utilisateurs test** → ajouter les adresses de vos
   testeurs, une par une.

## 3. Créer le client Android

**API et services** → **Identifiants** → **Créer des identifiants** →
**ID client OAuth** → type **Android**.

| Champ | Valeur |
|---|---|
| Nom du package | `fr.mailnet` |
| Empreinte SHA-1 | celle de votre clé d'envoi |

Pour retrouver l'empreinte :

```bash
keytool -list -v -keystore <votre-keystore>.p12 -alias upload
```

## 4. Renseigner l'identifiant

```bash
cp android/oauth.example.properties android/oauth.properties
# puis coller l'identifiant client dans googleClientId
```

Gradle en déduit le schéma de redirection AppAuth. Le côté Dart le reçoit
séparément, à la compilation :

```bash
flutter build apk --release --split-per-abi \
  --dart-define=GOOGLE_CLIENT_ID=000000000000-exemple.apps.googleusercontent.com
```

Sans `--dart-define`, le bouton reste masqué et seule la connexion par mot de
passe d'application est proposée.

---

## Le piège de la double signature

L'APK que vous distribuez vous-même est signé avec **votre clé d'envoi**. Dès
que l'application passe par le Play Store, Google la resigne avec **sa propre
clé** (Play App Signing, obligatoire) — donc avec une **empreinte SHA-1
différente**.

Résultat : le client OAuth créé à l'étape 3 ne reconnaîtra plus l'application
distribuée par le Play Store, et la connexion Google échouera pour vos
utilisateurs alors qu'elle fonctionnait en test.

**Le remède :** une fois l'application envoyée sur la Play Console, relevez
l'empreinte SHA-1 dans **Configuration → Signature de l'application**, et
**ajoutez un second client OAuth Android** avec cette empreinte. Les deux
peuvent coexister : l'un pour vos compilations locales, l'autre pour les
installations issues du Store.
