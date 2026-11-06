#!/usr/bin/env bash
# Génère UNE FOIS les secrets du CRM de démo, chiffrés pour la clé age (SOPS),
# dans apps/acrm-demo/acrm-secrets.sops.yaml. Le fichier chiffré est commité :
# chaque reconstruction du cluster le réutilise (mêmes mots de passe, même
# secret JWT), rien à refaire.
#
# Contenu (8 Secret Kubernetes créés par l'opérateur SOPS dans acrm-demo) :
#   acrm-db-admin / acrm-db-app / acrm-db-worker : rôles PostgreSQL (aléatoires)
#   acrm-redis      : mot de passe Redis (aléatoire)
#   acrm-api        : JWT_ACCESS_SECRET (aléatoire)
#   acrm-s3         : clés du bucket des documents (sorties Terraform de asesoria-infra)
#   acrm-demo-seed  : mot de passe des comptes de démo (aléatoire, ou DEMO_PASSWORD)
#   ghcr-pull       : accès en lecture aux images privées de GHCR
#
# Prérequis :
#   - sops et openssl ; terraform si S3_ACCESS_KEY_ID / S3_SECRET_ACCESS_KEY ne sont pas fournis ;
#   - le .env de asesoria-infra/envs/demo-data chargé (le state est dans le bucket OVH) ;
#   - GHCR_USER (ton identifiant GitHub) et un jeton GitHub « classic » limité à read:packages
#     (demandé au clavier, jamais affiché ; ou GHCR_TOKEN dans l'environnement).
# Usage : scripts/acrm-secrets.sh            (refuse d'écraser un fichier existant)
#         scripts/acrm-secrets.sh --force    (ROTATION : nouveaux mots de passe ; voir la doc)
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=apps/acrm-demo/acrm-secrets.sops.yaml
NAMESPACE=acrm-demo
INFRA_DIR="${INFRA_DIR:-$HOME/dev/asesoria-infra/envs/demo-data}"

die() { printf 'ERREUR : %s\n' "$*" >&2; exit 1; }

for tool in sops openssl; do
  command -v "$tool" >/dev/null || die "$tool introuvable (brew install $tool)"
done
if [ -e "$OUT" ] && [ "${1:-}" != "--force" ]; then
  die "$OUT existe déjà. Rien à refaire : il sert à chaque reconstruction. Rotation : --force (voir docs/bootstrap.fr.md)."
fi

# Clés S3 : fournies, ou lues dans le state Terraform de envs/demo-data.
if [ -z "${S3_ACCESS_KEY_ID:-}" ] || [ -z "${S3_SECRET_ACCESS_KEY:-}" ]; then
  command -v terraform >/dev/null || die "terraform introuvable (ou fournir S3_ACCESS_KEY_ID et S3_SECRET_ACCESS_KEY)"
  [ -d "$INFRA_DIR" ] || die "dossier $INFRA_DIR introuvable (variable INFRA_DIR)"
  S3_ACCESS_KEY_ID="$(terraform -chdir="$INFRA_DIR" output -raw documents_access_key_id)" \
    || die "terraform output impossible : .env de envs/demo-data chargé ? apply fait ?"
  S3_SECRET_ACCESS_KEY="$(terraform -chdir="$INFRA_DIR" output -raw documents_secret_access_key)"
fi
[ -n "$S3_ACCESS_KEY_ID" ] && [ -n "$S3_SECRET_ACCESS_KEY" ] || die "clés S3 vides"

: "${GHCR_USER:?GHCR_USER manquant (ton identifiant GitHub, ex. export GHCR_USER=Paul-Leclercq-Dev)}"
if [ -z "${GHCR_TOKEN:-}" ]; then
  read -r -s -p "Jeton GitHub (read:packages), invisible à la saisie : " GHCR_TOKEN; echo
fi
[ -n "$GHCR_TOKEN" ] || die "jeton GitHub vide"

hex() { openssl rand -hex "$1"; }
demo_password="${DEMO_PASSWORD:-$(hex 10)}"
[ "${#demo_password}" -ge 12 ] || die "DEMO_PASSWORD : 12 caractères minimum (politique de l'API)"
# Les valeurs sont écrites entre apostrophes dans le YAML (et en JSON par rebuild-timer.sh).
for value in "$demo_password" "$GHCR_USER" "$GHCR_TOKEN" "$S3_ACCESS_KEY_ID" "$S3_SECRET_ACCESS_KEY"; do
  case "$value" in *"'"* | *'"'* | *\\* | *[[:space:]]*) die "valeur contenant une apostrophe, un guillemet, un antislash ou un espace : refusée" ;; esac
done
ghcr_auth="$(printf '%s:%s' "$GHCR_USER" "$GHCR_TOKEN" | openssl base64 -A)"
dockerconfig="$(printf '{"auths":{"ghcr.io":{"username":"%s","password":"%s","auth":"%s"}}}' "$GHCR_USER" "$GHCR_TOKEN" "$ghcr_auth")"

# Le fichier en clair n'existe que le temps du chiffrement, lisible par toi seul,
# et il est effacé si quoi que ce soit échoue avant la fin.
umask 077
trap 'rm -f "$OUT.tmp.sops.yaml"' EXIT
cat > "$OUT.tmp.sops.yaml" <<YAML
# Secrets du CRM de démo. Généré par scripts/acrm-secrets.sh : ne pas éditer à la
# main (sops edit si vraiment nécessaire). Seules les valeurs sont chiffrées.
apiVersion: isindir.github.com/v1alpha3
kind: SopsSecret
metadata:
  name: acrm-secrets
  namespace: $NAMESPACE
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  secretTemplates:
    - name: acrm-db-admin
      type: kubernetes.io/basic-auth
      stringData:
        username: acrm_admin
        password: '$(hex 24)'
    - name: acrm-db-app
      type: kubernetes.io/basic-auth
      stringData:
        username: acrm_app
        password: '$(hex 24)'
    - name: acrm-db-worker
      type: kubernetes.io/basic-auth
      stringData:
        username: acrm_worker
        password: '$(hex 24)'
    - name: acrm-redis
      stringData:
        password: '$(hex 24)'
    - name: acrm-api
      stringData:
        JWT_ACCESS_SECRET: '$(hex 48)'
    - name: acrm-s3
      stringData:
        S3_ACCESS_KEY_ID: '$S3_ACCESS_KEY_ID'
        S3_SECRET_ACCESS_KEY: '$S3_SECRET_ACCESS_KEY'
    - name: acrm-demo-seed
      stringData:
        SEED_DEMO_PASSWORD: '$demo_password'
    - name: ghcr-pull
      type: kubernetes.io/dockerconfigjson
      stringData:
        .dockerconfigjson: '$dockerconfig'
YAML

# Le nom finit par .sops.yaml : la règle de .sops.yaml (clé publique age) s'applique.
sops encrypt --in-place "$OUT.tmp.sops.yaml"
mv "$OUT.tmp.sops.yaml" "$OUT"
trap - EXIT

scripts/check-encrypted.sh >/dev/null || die "contrôle du chiffrement en échec (scripts/check-encrypted.sh)"
cat <<EOF2
OK : $OUT chiffré ($(grep -c 'ENC\[' "$OUT") valeurs).
Mot de passe des comptes de démo (à ranger dans ton gestionnaire, il ne sera plus affiché) :
  $demo_password
Relire en clair si besoin : sops decrypt $OUT | less
Ensuite : git add $OUT && git commit (voir docs/bootstrap.fr.md, partie 4.2b).
EOF2
