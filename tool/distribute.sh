#!/usr/bin/env bash
# Compile la version release et l'envoie aux testeurs, en une commande.
#
#   tool/distribute.sh "Ce qui a changé dans cette version"
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

echo "→ Compilation de l'APK universel"
# Universel et non --split-per-abi : on ignore l'architecture des téléphones
# des testeurs, et un APK de la mauvaise architecture échoue à l'installation
# avec un message incompréhensible.
flutter build apk --release \
  --dart-define=GOOGLE_CLIENT_ID="$GOOGLE_ID" \
  --dart-define=MICROSOFT_CLIENT_ID="$MS_ID" \
  --dart-define=MICROSOFT_SIGNATURE_HASH="$MS_HASH"

APK=build/app/outputs/flutter-apk/app-release.apk
echo "→ Envoi de $APK ($(du -m "$APK" | cut -f1) Mo) au groupe « $GROUP »"

firebase appdistribution:distribute "$APK" \
  --app "$APP_ID" \
  --groups "$GROUP" \
  --release-notes "$NOTES"

echo "✓ Distribué. Les testeurs du groupe reçoivent un e-mail."
