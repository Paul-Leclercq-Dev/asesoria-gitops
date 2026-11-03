#!/usr/bin/env bash
# Amorce un cluster NEUF : dépose la clé age (secret zéro), restaure le
# certificat TLS sauvegardé s'il existe, installe Argo CD une fois par Helm,
# puis lui confie tout le reste (application racine, bootstrap/root.yaml).
#
# À lancer depuis le Mac, après `terraform apply` (asesoria-infra) et avec le
# tunnel SSH ouvert vers l'API Kubernetes (docs/bootstrap.fr.md, étape 5).
# Relançable sans risque : chaque étape vérifie ce qui existe déjà.
set -euo pipefail

cd "$(dirname "$0")/.."

AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"
TLS_BACKUP="${TLS_BACKUP:-$HOME/.config/tramelya/tls-backup.sops.yaml}"
# Version du chart lue dans l'Application d'Argo CD : une seule source de vérité.
ARGOCD_CHART_VERSION="$(awk '/chart: argo-cd/{found=1} found && /targetRevision:/{print $2; exit}' clusters/demo/argocd.yaml)"

step() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERREUR : %s\n' "$*" >&2; exit 1; }

for tool in kubectl helm sops; do
  command -v "$tool" >/dev/null || die "$tool introuvable (brew install $tool)"
done
[ -n "$ARGOCD_CHART_VERSION" ] || die "version du chart Argo CD introuvable dans clusters/demo/argocd.yaml"

step "1/5 Le cluster répond-il ? (contexte : $(kubectl config current-context))"
kubectl get nodes -o wide || die "API injoignable : le tunnel SSH est-il ouvert ? KUBECONFIG est-il exporté ?"
kubectl wait --for=condition=Ready node --all --timeout=180s

step "2/5 Clé privée age → secret sops/sops-age-key-file"
[ -r "$AGE_KEY_FILE" ] || die "clé age absente : $AGE_KEY_FILE (docs/bootstrap.fr.md, étape 2)"
kubectl create namespace sops --dry-run=client -o yaml | kubectl apply -f -
# --dry-run=client -o yaml | apply : crée le secret, ou le met à jour s'il existe.
kubectl -n sops create secret generic sops-age-key-file \
  --from-file=key="$AGE_KEY_FILE" --dry-run=client -o yaml | kubectl apply -f -

step "3/5 Certificat TLS sauvegardé (facultatif)"
if [ -r "$TLS_BACKUP" ]; then
  kubectl create namespace acrm-demo --dry-run=client -o yaml | kubectl apply -f -
  sops decrypt "$TLS_BACKUP" | kubectl apply -f -
  echo "Certificat restauré : cert-manager le réutilise au lieu d'en redemander un."
else
  echo "Aucune sauvegarde ($TLS_BACKUP) : cert-manager demandera un certificat neuf."
fi

step "4/5 Argo CD (chart $ARGOCD_CHART_VERSION)"
if kubectl -n argocd get application argocd >/dev/null 2>&1; then
  echo "Argo CD se gère déjà lui-même (Application « argocd ») : on n'y touche pas."
else
  helm repo add argo https://argoproj.github.io/argo-helm --force-update >/dev/null
  helm upgrade --install argocd argo/argo-cd \
    --version "$ARGOCD_CHART_VERSION" \
    --namespace argocd --create-namespace \
    --values bootstrap/argocd-values.yaml \
    --wait --timeout 10m
fi

step "5/5 Application racine (app-of-apps)"
kubectl apply -f bootstrap/root.yaml

cat <<'EOF'

Terminé côté amorçage. Argo CD installe maintenant le reste, vague par vague
(≈ 3 à 5 min). Pour suivre :
  kubectl -n argocd get applications -w      # Ctrl+C pour quitter
Tout est prêt quand chaque ligne affiche « Synced » et « Healthy ».
EOF
