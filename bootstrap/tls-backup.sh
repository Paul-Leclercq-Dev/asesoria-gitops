#!/usr/bin/env bash
# Sauvegarde CHIFFRÉE du certificat TLS de app.tramelya.es, à lancer AVANT
# d'éteindre le serveur (`terraform apply -var server_enabled=false`).
# Au prochain démarrage, bootstrap/install.sh le restaure : cert-manager le
# réutilise au lieu d'en redemander un à Let's Encrypt, ce qui évite la
# limite de 5 certificats identiques par semaine.
#
# Le fichier est écrit HORS du dépôt et chiffré pour votre clé age : la clé
# privée du certificat n'est jamais en clair sur le disque.
set -euo pipefail

AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"
TLS_BACKUP="${TLS_BACKUP:-$HOME/.config/tramelya/tls-backup.sops.yaml}"
NAMESPACE=acrm-demo
SECRET=app-tramelya-es-tls

die() { printf 'ERREUR : %s\n' "$*" >&2; exit 1; }

for tool in kubectl jq sops; do
  command -v "$tool" >/dev/null || die "$tool introuvable (brew install $tool)"
done
[ -r "$AGE_KEY_FILE" ] || die "clé age absente : $AGE_KEY_FILE"
RECIPIENT="$(awk '/public key:/{print $NF; exit}' "$AGE_KEY_FILE")"
[ -n "$RECIPIENT" ] || die "clé publique introuvable dans $AGE_KEY_FILE"

mkdir -p "$(dirname "$TLS_BACKUP")"
umask 077
# On ne garde que ce qui sert à recréer le secret (pas d'uid, de version…),
# puis on chiffre directement depuis l'entrée standard.
kubectl -n "$NAMESPACE" get secret "$SECRET" -o json \
  | jq '{apiVersion, kind, type, data,
         metadata: {name: .metadata.name, namespace: .metadata.namespace,
                    labels: .metadata.labels, annotations: .metadata.annotations}}' \
  | sops encrypt --filename-override tls-backup.sops.yaml \
      --input-type json --output-type yaml \
      --encrypted-regex '^data$' --age "$RECIPIENT" \
  > "$TLS_BACKUP.tmp"
mv "$TLS_BACKUP.tmp" "$TLS_BACKUP"

echo "Sauvegardé (chiffré) : $TLS_BACKUP"
kubectl -n "$NAMESPACE" get certificate -o wide 2>/dev/null || true
