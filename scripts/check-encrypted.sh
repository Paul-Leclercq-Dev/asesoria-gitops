#!/usr/bin/env bash
# Garde-fou (CI et local) : aucun secret en clair ne doit arriver dans Git.
# - Tout fichier *.sops.yaml doit être chiffré (métadonnées sops + valeurs ENC[…]).
# - Aucun autre fichier YAML ne doit déclarer un Secret Kubernetes ou un SopsSecret.
set -euo pipefail
cd "$(dirname "$0")/.."

status=0
fail() { printf 'ÉCHEC : %s\n' "$*" >&2; status=1; }

while IFS= read -r -d '' f; do
  grep -q '^sops:' "$f" || fail "$f : pas de bloc « sops: » (fichier non chiffré ?)"
  # La ligne « mac: ENC[…] » est le code de contrôle de sops, pas un secret :
  # il faut au moins une AUTRE valeur chiffrée (sinon on a chiffré du vide).
  grep -v '^[[:space:]]*mac:' "$f" | grep -q 'ENC\[' || fail "$f : aucune valeur chiffrée ENC[…] (variable vide au chiffrement ?)"
  if grep -Eq ':[[:space:]]*null[[:space:]]*$' "$f"; then
    fail "$f : valeur null (rien n'a été chiffré à cet endroit)"
  fi
  if grep -q 'COLLER_ICI' "$f"; then fail "$f : valeur du modèle non remplacée"; fi
done < <(find . -path ./.git -prune -o -name '*.sops.yaml' ! -name '.sops.yaml' -print0)

while IFS= read -r -d '' f; do
  case "$f" in *.sops.yaml) continue ;; esac
  if grep -Eq '^kind:[[:space:]]*(Secret|SopsSecret)[[:space:]]*$' "$f"; then
    fail "$f : Secret ou SopsSecret hors d'un fichier *.sops.yaml"
  fi
done < <(find . -path ./.git -prune -o \( -name '*.yaml' -o -name '*.yml' \) -print0)

if grep -q 'REMPLACER_PAR_LA_CLE_PUBLIQUE_AGE' .sops.yaml; then
  echo "Note : .sops.yaml contient encore le marqueur de clé age (étape 2 du runbook)."
fi

[ "$status" -eq 0 ] && echo "OK : aucun secret en clair."
exit "$status"
