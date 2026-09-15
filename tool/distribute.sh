#!/usr/bin/env bash
# Compile la version release et l'envoie aux testeurs, en une commande.
#
#   tool/distribute.sh "Ce qui a changé dans cette version"
#
# Le numéro de build est incrémenté automatiquement : deux versions portant le
# même numéro apparaissent identiques aux testeurs, et Android refuse de mettre
# à jour sans numéro supérieur.
#
# Prérequis, une seule fois :
#   npm install -g firebase-tools
#   firebase login
set -euo pipefail

cd "$(dirname "$0")/.."

# L'App ID n'est pas un secret — il identifie la destination, pas un droit
# d'accès : la distribution exige d'être authentifié auprès de Firebase.
APP_ID="${FIREBASE_APP_ID:-1:919040158841:android:c1cc7d2cdc9a57621038a8}"

# Groupe de testeurs créé dans la console Firebase.
GROUP="${FIREBASE_GROUP:-testeurs}"

NOTES="${1:-}"
if [ -z "$NOTES" ]; then
  echo "Indiquez ce qui a changé : tool/distribute.sh \"...\"" >&2
  exit 1
fi

CONFIG=android/oauth.properties
if [ ! -f "$CONFIG" ]; then
  echo "Absent : $CONFIG — voir docs/google-oauth.md" >&2
  exit 1
fi

# Une seule source de vérité : les identifiants viennent du même fichier que
# celui lu par Gradle, pour que le manifeste et le code Dart ne puissent pas
# diverger.
read_prop() { grep "^$1=" "$CONFIG" | cut -d= -f2- | tr -d '\r\n'; }

GOOGLE_ID=$(read_prop googleClientId)
MS_ID=$(read_prop microsoftClientId)
MS_HASH=$(read_prop microsoftSignatureHash)

# --- numéro de build ------------------------------------------------------
# `version: 1.0.0+7` — le nom reste, seul le numéro après le + augmente.
CURRENT=$(grep -m1 '^version:' pubspec.yaml | sed 's/.*+//' | tr -d '\r\n')
if ! [[ "$CURRENT" =~ ^[0-9]+$ ]]; then
  echo "Numéro de build illisible dans pubspec.yaml : « $CURRENT »" >&2
  exit 1
fi
NEXT=$((CURRENT + 1))
NAME=$(grep -m1 '^version:' pubspec.yaml | sed 's/^version: *//; s/+.*//' | tr -d '\r\n')

# sed -i laisse un fichier de sauvegarde sur Git Bash ; on écrit à côté.
sed "s/^version: .*/version: $NAME+$NEXT/" pubspec.yaml > pubspec.yaml.tmp
mv pubspec.yaml.tmp pubspec.yaml
echo "→ Version $NAME+$NEXT (précédente : +$CURRENT)"

restore_version() {
  sed "s/^version: .*/version: $NAME+$CURRENT/" pubspec.yaml > pubspec.yaml.tmp
  mv pubspec.yaml.tmp pubspec.yaml
  echo "  numéro de build remis à +$CURRENT" >&2
}

echo "→ Compilation de l'APK universel"
# Universel et non --split-per-abi : on ignore l'architecture des téléphones
# des testeurs, et un APK de la mauvaise architecture échoue à l'installation
# avec un message incompréhensible.
if ! flutter build apk --release \
  --dart-define=GOOGLE_CLIENT_ID="$GOOGLE_ID" \
  --dart-define=MICROSOFT_CLIENT_ID="$MS_ID" \
  --dart-define=MICROSOFT_SIGNATURE_HASH="$MS_HASH"; then
  # Rien n'est parti : ne pas laisser un numéro consommé pour rien.
  restore_version
  exit 1
fi

APK=build/app/outputs/flutter-apk/app-release.apk
echo "→ Envoi de $APK ($(du -m "$APK" | cut -f1) Mo) au groupe « $GROUP »"

if ! firebase appdistribution:distribute "$APK" \
  --app "$APP_ID" \
  --groups "$GROUP" \
  --release-notes "$NOTES"; then
  restore_version
  exit 1
fi

# Le numéro n'est gravé qu'une fois la version réellement partie, sinon
# l'historique du dépôt annoncerait des versions qui n'existent nulle part.
if git diff --quiet -- pubspec.yaml; then
  echo "✓ Distribué."
else
  git add pubspec.yaml
  git commit -q -m "Version $NAME+$NEXT distribuée aux testeurs

$NOTES

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
  echo "✓ Distribué et version $NAME+$NEXT enregistrée dans le dépôt."
fi

echo "  Les testeurs du groupe reçoivent un e-mail."
