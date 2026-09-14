# Formulaire Data Safety — réponses

Ce que déclarer dans la Play Console → **Contenu de l'application** → **Sécurité des données**.
Les réponses ci-dessous décrivent le comportement réel de l'application, vérifié dans le code.

> Google recoupe ces réponses avec le comportement observé de l'APK. Une déclaration inexacte
> fait rejeter la mise à jour, parfois plusieurs jours après la soumission.

---

## Collecte et partage

| Question | Réponse | Justification |
|---|---|---|
| Votre application collecte-t-elle ou partage-t-elle des types de données utilisateur requis ? | **Non** | Aucune donnée ne quitte l'appareil vers l'éditeur ou un tiers. Il n'existe aucun serveur MailNet. |
| Les données sont-elles chiffrées en transit ? | **Oui** | IMAP sur TLS, port 993, exclusivement. |
| Proposez-vous un moyen de demander la suppression des données ? | **Oui** | Désactiver « Mémoriser ce compte », ou désinstaller. Rien n'est conservé hors de l'appareil. |

### Le point qui prête à confusion

Google distingue **collecte** (les données quittent l'appareil vers *vous* ou un tiers) et
**traitement local**. MailNet lit des identifiants et des en-têtes de messages, mais :

- ils transitent uniquement vers **le serveur du fournisseur choisi par l'utilisateur**, ce qui
  n'est pas de la collecte au sens de Google ;
- ils sont stockés uniquement dans le **Keystore de l'appareil**.

C'est pourquoi la réponse est « Non » à la collecte. Si un examinateur le conteste, la réponse
est dans le code : aucune dépendance de mesure d'audience, aucune adresse réseau codée en dur.

### La seule exception à documenter

L'action **« Se désabonner »** envoie une requête au serveur de l'expéditeur (en-tête
`List-Unsubscribe`). Ce n'est ni une collecte par l'éditeur ni un partage vers un tiers choisi
par nous : c'est une action déclenchée explicitement par l'utilisateur vers un destinataire
qu'il a lui-même reçu dans son courrier. À mentionner en clair si un formulaire le permet —
mieux vaut l'avoir écrit que d'avoir à s'en expliquer.

---

## Section « Autorisations sensibles »

| Autorisation | Déclaration |
|---|---|
| `FOREGROUND_SERVICE_DATA_SYNC` | Poursuivre une suppression en masse lorsque l'application passe en arrière-plan. Sans elle, l'opération s'interrompt et l'utilisateur perd le suivi de ce qui a été supprimé. |
| `POST_NOTIFICATIONS` | Afficher la progression de la suppression. Facultative : le refus n'empêche pas l'application de fonctionner. |

Aucune autorisation de la catégorie « à usage restreint » n'est demandée : ni localisation,
ni SMS, ni journal d'appels, ni accès à tous les fichiers.

---

## Fiche du Store

| Champ | Valeur |
|---|---|
| Politique de confidentialité | `https://<votre-domaine>/privacy.html` — doit être **publique et accessible sans connexion** |
| Catégorie | Outils / Productivité |
| Icône | `assets/icon/play_store_512.png` (512 × 512) |
| Bandeau | 1024 × 500, à produire |
| Captures d'écran | Minimum 2, format téléphone. Les trois écrans — connexion, filtres, expéditeurs — suffisent |

---

## Avant de soumettre

- [ ] La politique de confidentialité est en ligne et s'ouvre en navigation privée
- [ ] Les mentions `[Nom ou raison sociale]` et `[adresse postale]` de `privacy.html` sont remplies
- [ ] L'adresse de contact existe vraiment et est relevée — Google y écrit
- [ ] L'AAB est signé avec la clé d'envoi (voir le keystore hors dépôt)
- [ ] Le test fermé est lancé avec le nombre de testeurs requis
